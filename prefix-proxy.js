#!/usr/bin/env node
// Logging reverse proxy for Anthropic API — captures /v1/messages request
// BODIES (system prompt + tools + messages) so replay-warmer.sh can preserve
// cache-key-bearing prefix bytes. Credential-looking transport headers and
// mcp_servers[].authorization_token are forwarded but never persisted.
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

function sanitizeCaptureHeaders(headers) {
  const safe = { ...headers };
  for (const name of Object.keys(safe)) {
    if (/auth|token|secret|credential|cookie|api-?key|jwt|bearer/i.test(name)
        && name.toLowerCase() !== 'x-claude-code-session-id') delete safe[name];
  }
  return safe;
}

function jsonStringEnd(text, start) {
  if (text[start] !== '"') return -1;
  let escaped = false;
  for (let i = start + 1; i < text.length; i += 1) {
    if (escaped) { escaped = false; continue; }
    if (text[i] === '\\') { escaped = true; continue; }
    if (text[i] === '"') return i + 1;
  }
  return -1;
}

function jsonValueEnd(text, start) {
  let depth = 0;
  let inString = false;
  let escaped = false;
  for (let i = start; i < text.length; i += 1) {
    const char = text[i];
    if (inString) {
      if (escaped) escaped = false;
      else if (char === '\\') escaped = true;
      else if (char === '"') inString = false;
      continue;
    }
    if (char === '"') { inString = true; continue; }
    if (char === '{' || char === '[') { depth += 1; continue; }
    if (char === '}' || char === ']') {
      if (depth === 0) return i;
      depth -= 1;
      continue;
    }
    if (char === ',' && depth === 0) return i;
  }
  return text.length;
}

// JSON.parse keeps only the last duplicate key. Scan the already-validated
// top-level object as well so an earlier credential-bearing mcp_servers value
// cannot be hidden by a later duplicate (bq-1257).
function topLevelJsonValues(text, wantedKey) {
  const values = [];
  const skipSpace = (at) => { let i = at; while (/\s/.test(text[i] || '')) i += 1; return i; };
  let i = skipSpace(0);
  if (text[i] !== '{') return values;
  i += 1;
  while (i < text.length) {
    i = skipSpace(i);
    if (text[i] === '}') return values;
    const keyStart = i;
    const keyEnd = jsonStringEnd(text, keyStart);
    if (keyEnd < 0) return null;
    let key;
    try { key = JSON.parse(text.slice(keyStart, keyEnd)); } catch { return null; }
    i = skipSpace(keyEnd);
    if (text[i] !== ':') return null;
    i = skipSpace(i + 1);
    const valueEnd = jsonValueEnd(text, i);
    if (valueEnd <= i) return null;
    if (key === wantedKey) {
      try { values.push(JSON.parse(text.slice(i, valueEnd))); } catch { return null; }
    }
    i = skipSpace(valueEnd);
    if (text[i] === ',') { i += 1; continue; }
    if (text[i] === '}') return values;
    return null;
  }
  return null;
}

// Hosted-MCP OAuth is carried inside the Messages JSON rather than a header.
// Refuse only that documented credential-bearing location: rejecting every
// request with mcp_servers would conflate capture safety with replay's separate
// server-tool gate, while a generic "token" key scan would reject harmless
// tool schemas and conversation text. Malformed/ambiguous JSON has no replay
// value and fails closed before any body byte is written (bq-1257).
function bodyHasHostedMcpAuthorizationToken(body) {
  const text = Buffer.isBuffer(body) ? body.toString('utf8') : String(body);
  try {
    JSON.parse(text);
  } catch {
    return true;
  }
  const serverLists = topLevelJsonValues(text, 'mcp_servers');
  if (serverLists === null) return true;
  return serverLists.some((servers) => Array.isArray(servers)
    && servers.some((server) => server !== null && typeof server === 'object'
      && Object.prototype.hasOwnProperty.call(server, 'authorization_token')));
}

// Return null without writing a byte for hosted-MCP auth or malformed/
// ambiguous JSON. Otherwise return the paths used by promote()/discard().
function persistPendingCapture(logdir, stem, url, headers, body) {
  if (bodyHasHostedMcpAuthorizationToken(body)) return null;
  const tb = path.join(logdir, `pending-${stem}.json`);
  const th = path.join(logdir, `pending-${stem}.hdrs.json`);
  try {
    fs.writeFileSync(tb, body, { mode: 0o600 });
    fs.writeFileSync(
      th,
      JSON.stringify({ url, headers: sanitizeCaptureHeaders(headers) }, null, 1),
      { mode: 0o600 },
    );
  } catch (error) {
    try { fs.unlinkSync(tb); } catch {}
    try { fs.unlinkSync(th); } catch {}
    throw error;
  }
  return [tb, th, path.join(logdir, `${stem}.json`), path.join(logdir, `${stem}.hdrs.json`)];
}

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
// Non-throwing writability probe, used both at startup and by the recovery
// sweep. Separate from ensureStore because the sweep must never throw.
function storeWritable(logdir) {
  const probe = path.join(logdir, `.write-probe-${process.pid}`);
  try {
    fs.writeFileSync(probe, 'x', { mode: 0o600 });
    fs.unlinkSync(probe);
    return true;
  } catch {
    return false;
  }
}

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

// Build the startup/timer sweep around the SAME health state the server uses.
// The first bq-314 implementation referenced an undeclared `state` here and
// crashed during its startup sweep, so neither retention nor proxying ran.
function createRetentionSweep(logdir, maxAgeMs, state) {
  return () => {
    const removed = pruneCaptures(logdir, maxAgeMs);
    if (removed) {
      console.log(`prefix-proxy: pruned ${removed} capture file(s) older than ${maxAgeMs / 3600000}h`);
    }
    if (state.writeErrors > 0 && storeWritable(logdir)) {
      console.log('prefix-proxy: capture store is writable again — clearing degraded state');
      state.writeErrors = 0;
      state.lastError = null;
    }
  };
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
        try {
          pending = persistPendingCapture(logdir, stem, req.url, req.headers, body);
          if (pending === null) {
            console.warn('prefix-proxy: capture skipped — hosted-MCP authorization or malformed/ambiguous JSON');
          }
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
          // An 'error' event with no listener is an UNCAUGHT exception, and this
          // process is a long-lived server: an upstream reset mid-response took
          // the whole proxy down, which takes every routed session with it
          // (Sol review, 2026-08-21). Headers are already sent by here, so the
          // only honest move is to drop the connection.
          pres.on('error', (e) => {
            console.error(`prefix-proxy: upstream stream error: ${e.message}`);
            res.destroy(e);
          });
          pres.pipe(res);
        }
      );
      preq.on('error', (e) => {
        discard();
        try { res.writeHead(502, { 'content-type': 'text/plain' }); res.end('proxy error: ' + e.message); } catch {}
      });
      res.on('error', (e) => {
        console.error(`prefix-proxy: client stream error: ${e.message}`);
        preq.destroy();
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
  const state = newHealthState();

  // Retention runs here, in the always-on component, and is deliberately
  // independent of the warmer's ENABLED switch (bq-314).
  const sweep = createRetentionSweep(logdir, maxAgeMs, state);
  sweep();
  setInterval(sweep, PRUNE_INTERVAL_MS);

  createProxyServer(logdir, nonce, state).listen(port, '127.0.0.1', () => {
    console.log(`prefix-proxy listening on 127.0.0.1:${port} -> api.anthropic.com, logging to ${logdir}`);
  });
}

module.exports = {
  defaultLogdir, resolveLogdir, pruneHours, ensureStore, storeWritable,
  sanitizeCaptureHeaders, bodyHasHostedMcpAuthorizationToken, persistPendingCapture,
  pruneCaptures, createRetentionSweep, createProxyServer, newHealthState,
  healthReport, CAPTURE_RE,
};

if (require.main === module) main(process.argv, process.env);
