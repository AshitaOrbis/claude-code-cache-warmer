#!/usr/bin/env python3
"""Replay a captured /v1/messages request to warm its prompt cache.

Usage: warm-replay.py <capture.json> [<capture.hdrs.json>]

Sends a prefix-preserving, output-bounded form of the captured body with the
cache-relevant headers (auth replaced with a fresh OAuth token from
~/.claude/.credentials.json). Prints one JSON line:
{http, cache_read, cache_creation, input_tokens, output_tokens, cap, aborted}.

OUTPUT CAPPING (bq-315)
-----------------------
A warm only needs the server to READ the cached prefix; the completion it
generates afterwards is pure waste, and until now the replay resent the
original request verbatim — original `max_tokens`, original thinking budget,
original task — and then consumed the whole regenerated answer. A warm of a
long coding turn could bill tens of thousands of output tokens.

Two bounds, applied together:

1. `max_tokens` is capped to the smallest legal value by a BYTE-SURGICAL edit:
   only the digits of the single top-level `"max_tokens": N` are rewritten, so
   every cache-key-bearing byte (system, tools, messages) is untouched — the
   byte-exactness that made v3 hit at all (docs/V3-DIAGNOSIS.md, "Why replay
   had to be byte- and header-exact"). If `"max_tokens"` appears more than once
   in the raw bytes (e.g. a tool schema declares a field of that name) the edit
   is AMBIGUOUS and is refused rather than guessed.
   With extended thinking enabled the API requires max_tokens > budget_tokens,
   so the floor is `budget_tokens + 1` — which is not small, hence:

2. The SSE stream is ABORTED as soon as `message_start` arrives. That event
   already carries the usage this tool reports (cache_read / cache_creation),
   so nothing is lost by hanging up, and the generation stops at the
   disconnect. Abort is used whenever the cap alone cannot bound output
   (thinking budgets, un-cappable bodies) and skipped when the cap is small
   enough to just read the tiny response — which is also how output_tokens
   gets measured at all.

If a completion cannot stay below the hard non-abort ceiling, or its required
abort path is disabled/not explicitly streaming, the replay is REFUSED with
exit 3. An abort-only non-SSE response (or one with no timely `message_start`)
is likewise refused without an unbounded drain — an uncapped replay is the
defect, not the fallback.

RELEASE GATE (unverified here): Anthropic's server-side billing behaviour for a
client disconnect mid-stream is NOT measured. Until it is, treat the abort path
as bounding wall-clock and network, not as a proven billing bound.

Env overrides (testing): CW_REPLAY_ENDPOINT, CW_CREDENTIALS, CW_REPLAY_ABORT,
CW_REPLAY_ABORT_ABOVE.
"""
import json, os, re, sys, urllib.request, urllib.error

# Consume the response instead of aborting when the cap got max_tokens down to
# at most this many tokens — cheap enough to read, and the only way to actually
# MEASURE output_tokens per warm.
DEFAULT_ABORT_ABOVE = 64
MAX_SSE_PRELUDE_BYTES = 65536

MAX_TOKENS_RE = re.compile(rb'"max_tokens"\s*:\s*(\d+)')


class ReplayRefused(Exception):
    """The requested replay cannot be bounded safely."""


def output_bound_plan(cap, abort_enabled, abort_above):
    """Return whether SSE abort is required, or refuse an unsafe plan."""
    if not isinstance(abort_above, int) or not 0 <= abort_above <= DEFAULT_ABORT_ABOVE:
        raise ReplayRefused(
            "abort threshold must be between 0 and %d" % DEFAULT_ABORT_ABOVE
        )
    needs_abort = cap is None or cap > abort_above
    if needs_abort and not abort_enabled:
        raise ReplayRefused("completion exceeds the hard non-abort output bound")
    return needs_abort


def request_is_streaming(body):
    """Return true only when the request explicitly asks for SSE streaming."""
    try:
        obj = json.loads(body)
    except Exception:
        return False
    return isinstance(obj, dict) and obj.get("stream") is True


def usage_receipt(usage):
    """Keep absent counters as null so callers cannot mistake them for zero."""
    value = usage if isinstance(usage, dict) else {}
    return {
        'cache_read': value.get('cache_read_input_tokens'),
        'cache_creation': value.get('cache_creation_input_tokens'),
        'input_tokens': value.get('input_tokens'),
    }


def plan_minimal_body(body):
    """Return (body_bytes, cap_or_None, reason).

    cap is the effective max_tokens after the edit (or the original value when
    it was already minimal). None means output is NOT capped and the caller
    must fall back to aborting the stream.
    """
    try:
        obj = json.loads(body)
    except Exception:
        return body, None, "body is not JSON"
    if not isinstance(obj, dict) or not isinstance(obj.get("max_tokens"), int):
        return body, None, "no top-level integer max_tokens"

    floor = 1
    thinking = obj.get("thinking")
    if isinstance(thinking, dict) and thinking.get("type") == "enabled":
        budget = thinking.get("budget_tokens")
        if not isinstance(budget, int) or budget < 1:
            return body, None, "thinking enabled with unreadable budget_tokens"
        floor = budget + 1  # the API rejects max_tokens <= budget_tokens

    current = obj["max_tokens"]
    if current < 1:
        # A nonsensical value is not a cap. Reporting it as one would leave
        # `cap` set, which suppresses the abort fallback — so a malformed body
        # would be replayed with NEITHER bound. The API rejects it anyway, but
        # "we have a cap" must never be true when we do not.
        return body, None, "max_tokens is not a positive integer (%r)" % (current,)
    if current <= floor:
        return body, current, "already minimal"

    spans = list(MAX_TOKENS_RE.finditer(body))
    if len(spans) != 1:
        return body, None, "ambiguous: %d max_tokens occurrences in the raw body" % len(spans)

    m = spans[0]
    edited = body[:m.start(1)] + str(floor).encode() + body[m.end(1):]

    # Post-conditions: the edit must have changed exactly one number and
    # nothing else. Cheap to check, and the cost of being wrong is a silently
    # cache-missing warm that still bills a full prefix write.
    try:
        after = json.loads(edited)
    except Exception:
        return body, None, "rewrite produced unparseable JSON"
    if after.get("max_tokens") != floor:
        return body, None, "rewrite did not land on the top-level max_tokens"
    lhs, rhs = dict(obj), dict(after)
    lhs.pop("max_tokens"), rhs.pop("max_tokens")
    if lhs != rhs:
        return body, None, "rewrite changed a field other than max_tokens"
    return edited, floor, "capped %d -> %d" % (current, floor)


def read_usage(resp, abort_after_start):
    """Drain (or abort) the response, returning (usage, output_tokens, aborted)."""
    usage, out_tokens, aborted = None, None, False
    if "text/event-stream" not in resp.headers.get("content-type", ""):
        if abort_after_start:
            # message_start does not exist in a single JSON response. Draining
            # it would resurrect the full-regeneration defect this abort path
            # is meant to bound (bq-315/1259/1389).
            raise ReplayRefused("abort-only replay received a non-streaming response")
        body = json.load(resp)
        usage = body.get("usage", {})
        return usage, usage.get("output_tokens"), False
    prelude_bytes = 0
    while True:
        if abort_after_start and usage is None:
            remaining = MAX_SSE_PRELUDE_BYTES - prelude_bytes
            if remaining <= 0:
                raise ReplayRefused("message_start exceeded bounded SSE prelude")
            # HTTPResponse iteration uses an unbounded readline internally.
            # Bound the read itself (+1 detects overflow) so one newline-free
            # SSE field cannot allocate/drain an arbitrarily large response.
            raw = resp.readline(remaining + 1)
            if len(raw) > remaining:
                raise ReplayRefused("message_start exceeded bounded SSE prelude")
            prelude_bytes += len(raw)
        else:
            raw = resp.readline()
        if not raw:
            break
        line = raw.decode("utf-8", "replace").strip()
        if not line.startswith("data:"):
            continue
        try:
            ev = json.loads(line[5:].strip())
        except json.JSONDecodeError:
            continue
        if ev.get("type") == "message_start":
            usage = ev["message"].get("usage", {})
            if abort_after_start:
                aborted = True
                break
        elif ev.get("type") == "message_delta":
            out_tokens = ev.get("usage", {}).get("output_tokens", out_tokens)
    if abort_after_start and usage is None:
        raise ReplayRefused("abort-only SSE ended before message_start")
    return usage, out_tokens, aborted


def main():
    body_path = sys.argv[1]
    hdrs_path = sys.argv[2] if len(sys.argv) > 2 else body_path.replace('.json', '.hdrs.json')
    body = open(body_path, 'rb').read()
    meta = json.load(open(hdrs_path))
    creds = os.environ.get('CW_CREDENTIALS') or os.path.expanduser('~/.claude/.credentials.json')
    tok = json.load(open(creds))['claudeAiOauth']['accessToken']

    body, cap, cap_reason = plan_minimal_body(body)
    abort_enabled = os.environ.get('CW_REPLAY_ABORT', '1') != '0'
    try:
        abort_above = int(os.environ.get('CW_REPLAY_ABORT_ABOVE', DEFAULT_ABORT_ABOVE))
        # The test override may make the abort threshold stricter, never looser
        # than the hard 64-token drain ceiling (bq-315/1259/1389).
        abort_after_start = output_bound_plan(cap, abort_enabled, abort_above)
    except (ValueError, ReplayRefused) as error:
        print(json.dumps({
            'http': 0,
            'error': 'uncapped_refused',
            'cap': cap,
            'cap_reason': cap_reason,
            'detail': str(error),
        }))
        sys.exit(3)
    if abort_after_start and not request_is_streaming(body):
        print(json.dumps({
            'http': 0,
            'error': 'uncapped_non_streaming_refused',
            'cap': cap,
            'cap_reason': cap_reason,
        }))
        sys.exit(3)

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

    endpoint = os.environ.get('CW_REPLAY_ENDPOINT', 'https://api.anthropic.com')
    req = urllib.request.Request(endpoint + meta['url'],
                                 data=body, headers=headers, method='POST')
    try:
        with urllib.request.urlopen(req, timeout=180) as r:
            usage, out_tokens, aborted = read_usage(r, abort_after_start)
            print(json.dumps({
                'http': r.status,
                **usage_receipt(usage),
                'output_tokens': out_tokens,
                'cap': cap,
                'cap_reason': cap_reason,
                'aborted': aborted,
            }))
    except ReplayRefused as e:
        print(json.dumps({
            'http': 0,
            'error': 'non_streaming_response_refused',
            'cap': cap,
            'cap_reason': cap_reason,
            'detail': str(e),
        }))
        sys.exit(3)
    except urllib.error.HTTPError as e:
        print(json.dumps({'http': e.code, 'error': e.read().decode()[:400]}))
        sys.exit(1)


if __name__ == '__main__':
    main()
