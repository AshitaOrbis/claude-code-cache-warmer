#!/usr/bin/env node
// Logging reverse proxy for Anthropic API — captures /v1/messages request
// BODIES (system prompt + tools + messages) so replay-warmer.sh can re-warm
// prompt caches byte-exactly. Auth headers are forwarded but NEVER persisted.
//
// Hardening (2026-07-02 GPT-5.5-Pro review):
//  - Captures are written as pending-* temps and PROMOTED to warmable req-*
//    files only after the upstream responds 2xx — an unauthenticated local
//    POST can no longer seed the warm queue.
//  - GET /warmer-health serves a per-start nonce (mirrored in a 0600 file) so
//    the .bashrc export can verify it is talking to THIS proxy, not a squatter.
//  - Response streaming is piped (SSE-safe); upstream is aborted if the
//    client disconnects.
//
// Retention (2026-08-21, bq-314): capture bodies are full conversations, so
// retention CANNOT depend on the warmer running. replay-warmer.sh only pruned
// after its `ENABLED != 1` early exit and only matched `req-*`, so a disabled
// or crashed warmer left promoted captures AND `pending-*` crash leftovers on
// disk forever. The proxy — the component that creates them — now prunes both
// prefixes in its own active store at startup and every PRUNE_INTERVAL, and
// re-asserts the 0700 store mode even when the directory already existed.
//
// Capture store + health (2026-08-21, bq-318): the store location is now ONE
// setting shared with replay-warmer.sh (argv[3] > CW_CAPTURE_DIR >
// ~/.cache/prefix-proxy). The two halves used to default independently — the
// proxy to /tmp/prefix-proxy, the warmer to ~/.cache/prefix-proxy — so both
// could report success while the warmer scanned a directory nothing wrote to.
// Startup now PROVES the store is writable instead of discovering it per
// request, write failures are logged rather than swallowed, and health carries
// capture state.
//
// Usage: node prefix-proxy.js [port] [logdir]
//   CW_CAPTURE_DIR  capture store (same knob replay-warmer.sh reads)
//   CW_PRUNE_HOURS  capture retention window (default 6, matches config)
'use strict';
const http = require('http');
const https = require('https');
const fs = require('fs');
const path = require('path');
const crypto = require('crypto');
const os = require('os');

const DEFAULT_PRUNE_HOURS = 6;
const PRUNE_INTERVAL_MS = 10 * 60 * 1000;
// Both the promoted (`req-`) and the crash-leftover (`pending-`) prefixes.
// Anchored: only files this proxy created are ever removed.
const CAPTURE_RE = /^(req|pending)-/;

function defaultLogdir() {
  return path.join(os.homedir(), '.cache', 'prefix-proxy');
}

// One resolution order, mirrored by replay-warmer.sh's CAP_DIR.
function resolveLogdir(argv, env) {
  return argv[3] || env.CW_CAPTURE_DIR || defaultLogdir();
}

function pruneHours(env) {
  const raw = env.CW_PRUNE_HOURS;
  if (raw === undefined || raw === '') return DEFAULT_PRUNE_HOURS;
  const n = Number(raw);
  if (!Number.isFinite(n) || n < 0) {
    throw new Error(`CW_PRUNE_HOURS must be a non-negative number (got '${raw}')`);
  }
  return n;
}

// Create the store if absent and enforce 0700 EVERY start — mkdir's `mode`
// is ignored when the directory already exists, so a store created once with
// a loose umask stayed loose forever.
function ensureStore(logdir) {
  fs.mkdirSync(logdir, { recursive: true, mode: 0o700 });
  fs.chmodSync(logdir, 0o700);
  // Prove writability NOW and fail startup if it is not there. Discovering it
  // per-request meant every capture silently failed while the proxy went on
  // forwarding traffic and reporting itself healthy (bq-318).
  const probe = path.join(logdir, `.write-probe-${process.pid}`);
  fs.writeFileSync(probe, 'x', { mode: 0o600 });
  fs.unlinkSync(probe);
  return logdir;
}

// Delete capture body/header pairs older than maxAgeMs from THIS proxy's
// active store. Returns the number of files removed. Never throws: retention
// runs on a timer inside a long-lived server, and one unreadable entry must
// not take the proxy down.
function pruneCaptures(logdir, maxAgeMs, now = Date.now()) {
  let removed = 0;
  let names;
  try {
    names = fs.readdirSync(logdir);
  } catch {
    return 0;
  }
  for (const name of names) {
    if (!CAPTURE_RE.test(name)) continue;
    const p = path.join(logdir, name);
    try {
      if (now - fs.statSync(p).mtimeMs <= maxAgeMs) continue;
      fs.unlinkSync(p);
      removed++;
    } catch {
      /* raced with promote()/another prune, or unreadable — skip */
    }
  }
  return removed;
}

// Health state. `captures` counts PROMOTED message captures — promotion only
// happens after the upstream answered 2xx, so a non-zero count is proof that a
// real, authenticated request was captured, not that a local POST arrived.
function newHealthState() {
  return { captures: 0, lastCaptureAt: null, writeErrors: 0, lastError: null };
}

function healthReport(state) {
  if (state.writeErrors > 0) return { status: 'degraded', reason: 'capture_write_failed' };
  if (state.captures === 0) return { status: 'degraded', reason: 'no_capture_yet' };
  return { status: 'ok', reason: null };
}

function createProxyServer(logdir, nonce, state = newHealthState()) {
  let n = 0;
  return http.createServer((req, res) => {
    // GET /warmer-health is the anti-squatter liveness check the shell guard
    // uses to decide whether to route sessions here; it answers with the nonce.
    // It 503s when captures are FAILING — routing sessions through a proxy that
    // cannot capture is worse than not routing them at all. It deliberately
    // does NOT 503 on `no_capture_yet`: sessions only produce captures by being
    // routed here, so gating the route on a prior capture would deadlock the
    // documented bootstrap. That state is reported by /warmer-health/json,
    // which is what an operator or a monitor should read.
    if (req.method === 'GET' && req.url === '/warmer-health') {
      const h = healthReport(state);
      res.writeHead(h.reason === 'capture_write_failed' ? 503 : 200,
                    { 'content-type': 'text/plain' });
      res.end(nonce);
      return;
    }
    if (req.method === 'GET' && req.url === '/warmer-health/json') {
      const h = healthReport(state);
      res.writeHead(h.status === 'ok' ? 200 : 503, { 'content-type': 'application/json' });
      res.end(JSON.stringify({
        ...h,
        logdir,
        captures: state.captures,
        lastCaptureAt: state.lastCaptureAt,
        writeErrors: state.writeErrors,
        lastError: state.lastError,
      }));
      return;
    }
    const chunks = [];
    req.on('data', (c) => chunks.push(c));
    req.on('end', () => {
      const body = Buffer.concat(chunks);
      let pending = null; // [tmpBody, tmpHdrs, finalBody, finalHdrs]
      if (req.method === 'POST' && req.url.startsWith('/v1/messages')) {
        const kind = req.url.includes('count_tokens') ? 'count' : 'msg';
        const stem = `req-${String(Date.now())}-${String(n++).padStart(3, '0')}-${kind}`;
        const hdrs = { ...req.headers };
        for (const k of Object.keys(hdrs)) {
          if (/auth|token|secret|credential|cookie|api-?key|jwt|bearer/i.test(k)
              && k.toLowerCase() !== 'x-claude-code-session-id') delete hdrs[k];
        }
        try {
          const tb = path.join(logdir, `pending-${stem}.json`);
          const th = path.join(logdir, `pending-${stem}.hdrs.json`);
          fs.writeFileSync(tb, body, { mode: 0o600 });
          fs.writeFileSync(th, JSON.stringify({ url: req.url, headers: hdrs }, null, 1), { mode: 0o600 });
          pending = [tb, th, path.join(logdir, `${stem}.json`), path.join(logdir, `${stem}.hdrs.json`)];
        } catch (e) {
          // Swallowing this is what let the proxy report success while
          // producing nothing usable (bq-318).
          state.writeErrors++;
          state.lastError = String(e && e.message ? e.message : e);
          console.error(`prefix-proxy: capture write FAILED in ${logdir}: ${state.lastError}`);
          pending = null;
        }
      }
      const discard = () => {
        if (!pending) return;
        try { fs.unlinkSync(pending[0]); } catch {}
        try { fs.unlinkSync(pending[1]); } catch {}
        pending = null;
      };
      const promote = () => {
        if (!pending) return;
        try {
          fs.renameSync(pending[0], pending[2]);
          fs.renameSync(pending[1], pending[3]);
          if (pending[2].endsWith('-msg.json')) {
            state.captures++;
            state.lastCaptureAt = new Date().toISOString();
            state.writeErrors = 0; // a success clears the degraded latch
            state.lastError = null;
          }
        } catch (e) {
          state.writeErrors++;
          state.lastError = String(e && e.message ? e.message : e);
          console.error(`prefix-proxy: capture promote FAILED in ${logdir}: ${state.lastError}`);
        }
        pending = null;
      };
      const headers = { ...req.headers, host: 'api.anthropic.com' };
      delete headers['content-length'];
      headers['content-length'] = String(body.length);
      const preq = https.request(
        { host: 'api.anthropic.com', port: 443, path: req.url, method: req.method, headers },
        (pres) => {
          if (pres.statusCode >= 200 && pres.statusCode < 300) promote(); else discard();
          res.writeHead(pres.statusCode, pres.headers);
          pres.pipe(res);
        }
      );
      preq.on('error', (e) => {
        discard();
        try { res.writeHead(502, { 'content-type': 'text/plain' }); res.end('proxy error: ' + e.message); } catch {}
      });
      res.on('close', () => { if (pending) discard(); preq.destroy(); });
      preq.end(body);
    });
  });
}

function main(argv, env) {
  const port = Number(argv[2] || 8377);
  const logdir = resolveLogdir(argv, env);
  const maxAgeMs = pruneHours(env) * 3600 * 1000;

  try {
    ensureStore(logdir);
  } catch (e) {
    console.error(`prefix-proxy: cannot use capture store ${logdir}: ${e.message}`);
    console.error('refusing to start — a proxy that cannot capture warms nothing.');
    process.exit(1);
  }
  const nonce = crypto.randomBytes(16).toString('hex');
  fs.writeFileSync(path.join(logdir, '.health-nonce'), nonce, { mode: 0o600 });

  // Retention runs here, in the always-on component, and is deliberately
  // independent of the warmer's ENABLED switch (bq-314).
  const sweep = () => {
    const removed = pruneCaptures(logdir, maxAgeMs);
    if (removed) console.log(`prefix-proxy: pruned ${removed} capture file(s) older than ${maxAgeMs / 3600000}h`);
  };
  sweep();
  setInterval(sweep, PRUNE_INTERVAL_MS);

  createProxyServer(logdir, nonce, newHealthState()).listen(port, '127.0.0.1', () => {
    console.log(`prefix-proxy listening on 127.0.0.1:${port} -> api.anthropic.com, logging to ${logdir}`);
  });
}

module.exports = {
  defaultLogdir, resolveLogdir, pruneHours, ensureStore, pruneCaptures,
  createProxyServer, newHealthState, healthReport, CAPTURE_RE,
};

if (require.main === module) main(process.argv, process.env);
