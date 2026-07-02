#!/usr/bin/env python3
"""Replay a captured /v1/messages request byte-for-byte to warm its prompt cache.

Usage: warm-replay.py <capture.json> [<capture.hdrs.json>]

Sends the EXACT captured body bytes (no parse/re-serialize) with the captured
headers (auth replaced with a fresh OAuth token from ~/.claude/.credentials.json).
Streaming responses are consumed; usage is read from the message_start event.
Prints one JSON line: {http, cache_read, cache_creation, input_tokens, output_tokens}.
"""
import json, os, sys, urllib.request, io

def main():
    body_path = sys.argv[1]
    hdrs_path = sys.argv[2] if len(sys.argv) > 2 else body_path.replace('.json', '.hdrs.json')
    body = open(body_path, 'rb').read()
    meta = json.load(open(hdrs_path))
    creds = os.path.expanduser('~/.claude/.credentials.json')
    tok = json.load(open(creds))['claudeAiOauth']['accessToken']

    # Strip hop-by-hop + stale-length headers; keep the semantic set (betas,
    # version, user-agent, x-app, x-claude-code-session-id). Retry telemetry is
    # reset so scheduled warms don't masquerade as SDK retries.
    drop = ('host', 'content-length', 'connection', 'accept-encoding', 'keep-alive',
            'transfer-encoding', 'te', 'trailer', 'upgrade', 'proxy-authorization',
            'proxy-authenticate', 'x-stainless-retry-count')
    headers = {k: v for k, v in meta['headers'].items() if k.lower() not in drop}
    headers['x-stainless-retry-count'] = '0'
    headers['Authorization'] = f'Bearer {tok}'
    headers['accept-encoding'] = 'identity'

    req = urllib.request.Request('https://api.anthropic.com' + meta['url'],
                                 data=body, headers=headers, method='POST')
    try:
        with urllib.request.urlopen(req, timeout=180) as r:
            usage, out_tokens = None, None
            ctype = r.headers.get('content-type', '')
            if 'text/event-stream' in ctype:
                for raw in io.TextIOWrapper(r, encoding='utf-8'):
                    line = raw.strip()
                    if not line.startswith('data:'):
                        continue
                    try:
                        ev = json.loads(line[5:].strip())
                    except json.JSONDecodeError:
                        continue
                    if ev.get('type') == 'message_start':
                        usage = ev['message'].get('usage', {})
                    elif ev.get('type') == 'message_delta':
                        out_tokens = ev.get('usage', {}).get('output_tokens', out_tokens)
            else:
                resp = json.load(r)
                usage = resp.get('usage', {})
                out_tokens = usage.get('output_tokens')
            u = usage or {}
            print(json.dumps({
                'http': r.status,
                'cache_read': u.get('cache_read_input_tokens', 0),
                'cache_creation': u.get('cache_creation_input_tokens', 0),
                'input_tokens': u.get('input_tokens', 0),
                'output_tokens': out_tokens,
            }))
    except urllib.error.HTTPError as e:
        print(json.dumps({'http': e.code, 'error': e.read().decode()[:400]}))
        sys.exit(1)

if __name__ == '__main__':
    main()
