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
// Usage: node prefix-proxy.js [port] [logdir]
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

function createProxyServer(logdir, nonce) {
  let n = 0;
  return http.createServer((req, res) => {
    if (req.method === 'GET' && req.url === '/warmer-health') {
      res.writeHead(200, { 'content-type': 'text/plain' });
      res.end(nonce);
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
        } catch { pending = null; }
      }
      const discard = () => {
        if (!pending) return;
        try { fs.unlinkSync(pending[0]); } catch {}
        try { fs.unlinkSync(pending[1]); } catch {}
        pending = null;
      };
      const promote = () => {
        if (!pending) return;
        try { fs.renameSync(pending[0], pending[2]); fs.renameSync(pending[1], pending[3]); } catch {}
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
  const logdir = argv[3] || defaultLogdir();
  const maxAgeMs = pruneHours(env) * 3600 * 1000;

  ensureStore(logdir);
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

  createProxyServer(logdir, nonce).listen(port, '127.0.0.1', () => {
    console.log(`prefix-proxy listening on 127.0.0.1:${port} -> api.anthropic.com, logging to ${logdir}`);
  });
}

module.exports = { defaultLogdir, pruneHours, ensureStore, pruneCaptures, createProxyServer, CAPTURE_RE };

if (require.main === module) main(process.argv, process.env);
