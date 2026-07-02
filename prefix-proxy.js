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
// Usage: node prefix-proxy.js <port> <logdir>
'use strict';
const http = require('http');
const https = require('https');
const fs = require('fs');
const path = require('path');
const crypto = require('crypto');

const port = Number(process.argv[2] || 8377);
const logdir = process.argv[3] || '/tmp/prefix-proxy';
fs.mkdirSync(logdir, { recursive: true, mode: 0o700 });

const nonce = crypto.randomBytes(16).toString('hex');
fs.writeFileSync(path.join(logdir, '.health-nonce'), nonce, { mode: 0o600 });
let n = 0;

http.createServer((req, res) => {
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
}).listen(port, '127.0.0.1', () => {
  console.log(`prefix-proxy listening on 127.0.0.1:${port} -> api.anthropic.com, logging to ${logdir}`);
});
