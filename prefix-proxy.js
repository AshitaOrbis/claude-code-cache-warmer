#!/usr/bin/env node
// Logging reverse proxy for Anthropic API — captures /v1/messages request
// BODIES (system prompt + tools + messages) to diagnose fork-prefix variance.
// Auth headers are forwarded but NEVER written to disk.
// Usage: node prefix-proxy.js <port> <logdir>
'use strict';
const http = require('http');
const https = require('https');
const fs = require('fs');
const path = require('path');

const port = Number(process.argv[2] || 8377);
const logdir = process.argv[3] || '/tmp/prefix-proxy';
fs.mkdirSync(logdir, { recursive: true });
let n = 0;

http.createServer((req, res) => {
  const chunks = [];
  req.on('data', (c) => chunks.push(c));
  req.on('end', () => {
    const body = Buffer.concat(chunks);
    if (req.method === 'POST' && req.url.startsWith('/v1/messages')) {
      const kind = req.url.includes('count_tokens') ? 'count' : 'msg';
      const stem = `req-${String(Date.now())}-${String(n++).padStart(3, '0')}-${kind}`;
      fs.writeFileSync(path.join(logdir, `${stem}.json`), body, { mode: 0o600 });
      // Headers enable faithful replay — auth material is never persisted.
      const hdrs = { ...req.headers };
      for (const k of Object.keys(hdrs)) {
        if (/authorization|cookie|x-api-key/i.test(k)) delete hdrs[k];
      }
      fs.writeFileSync(path.join(logdir, `${stem}.hdrs.json`),
        JSON.stringify({ url: req.url, headers: hdrs }, null, 1), { mode: 0o600 });
    }
    const headers = { ...req.headers, host: 'api.anthropic.com' };
    delete headers['content-length'];
    headers['content-length'] = String(body.length);
    const preq = https.request(
      { host: 'api.anthropic.com', port: 443, path: req.url, method: req.method, headers },
      (pres) => {
        res.writeHead(pres.statusCode, pres.headers);
        pres.pipe(res);
      }
    );
    preq.on('error', (e) => {
      try { res.writeHead(502, { 'content-type': 'text/plain' }); res.end('proxy error: ' + e.message); } catch {}
    });
    preq.end(body);
  });
}).listen(port, '127.0.0.1', () => {
  console.log(`prefix-proxy listening on 127.0.0.1:${port} -> api.anthropic.com, logging to ${logdir}`);
});
