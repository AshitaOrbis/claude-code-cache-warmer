# v3 diagnosis — why fork-warming died on Claude Code ≥2.1.198, and the replay fix

*(Findings from the 2026-07-02 debug session on the maintainer's box; lightly
edited for publication. Empirical numbers are from a real Max-plan account.)*

## Root cause of fork-warming breakage (definitive)

Byte-level capture of /v1/messages request bodies via a local logging proxy
(`prefix-proxy.js`, `ANTHROPIC_BASE_URL` redirection) shows:

- **The system prompt embeds the session-specific scratchpad path**
  (`/tmp/claude-1000/<project>/<SESSION-UUID>/scratchpad`) in the "Scratchpad
  Directory" section — char ~26,730 of the ~28k-char main system block on this
  workspace. A `--fork-session` process gets a new UUID → new path → the system
  block's cache breakpoint misses → `cache_read=0`. fork1-vs-fork2 and
  parent-vs-fork diffs are otherwise IDENTICAL (tools, skills, MCP schemas all
  deterministic on this box). The binary computes the path as
  `join(tmpBase, sessionId, "scratchpad")` — no env/setting override exists.
- The scratchpad section is a "dynamic section"; `excludeDynamicSections`
  exists but only as an Agent SDK `systemPrompt: {type:"preset"}` option — not
  reachable for interactive TUI sessions, so it cannot align a fork with a
  live TUI session.
- `attribution.sessionUrl` (my prior suspect) is NOT in local sessions'
  prompts — fork1-vs-fork2 showed no session-URL text. It presumably applies
  to web/RC sessions only (per the schema description). Untested for RC.
- Secondary shape difference: the fork replays the last user message as a
  plain string, while the live request used a content-block array with
  `cache_control` — irrelevant once replay-warming is used.
- v2 fork-warming worked on v2.1.173 (2026-06-11) — the scratchpad section
  (or its sid-embedding) arrived between 2.1.173 and 2.1.198.

## The fix: replay warming (v3) — deployed + verified

Don't reconstruct the prefix — **replay the session's own last request**:

1. `prefix-proxy.service` (node, 127.0.0.1:8377) forwards to
   api.anthropic.com and captures each /v1/messages request body + headers
   (Authorization/cookie/x-api-key never persisted) to `~/.cache/prefix-proxy/`
   (mode 600/700, pruned after 48h).
2. Sessions opt in via `ANTHROPIC_BASE_URL=http://127.0.0.1:8377` — exported
   by `~/.bashrc` only when the proxy port answers (fail-open if down).
3. `replay-warmer.sh` (cache-warmer.service now points here) groups captures
   by conversation sid — recovered from the scratchpad path *inside the body*,
   the very string that broke fork-warming — and replays the newest capture
   byte-for-byte with a fresh OAuth token (`warm-replay.py`). The exact-prefix
   read (0.1×) refreshes the 1h TTL. Same gating as v2: warm window 45–58 min,
   240 min max capture age, 30 min rate limit, 2-strike blacklist, MIN_MSGS=3
   filters one-shot `claude -p` captures.

### Why replay had to be byte- and header-exact (measured)

- Guessed beta headers + JSON re-serialization → partial hit
  (`cache_read=23,720 / creation=47,428`).
- Exact captured headers + raw bytes → **full hit
  (`cache_read=71,410 / creation=0`)**. The real header set includes
  `prompt-caching-scope-2026-01-05` and `x-claude-code-session-id` — replay
  must reuse them verbatim (only the Authorization token is fresh).

### Verification (2026-07-02 01:49–01:50)

Two consecutive production warms of the soak session `149d1e07` through the
full pipeline: `WARMED cache_read=71383 cache_creation=0` twice. Gate from
freeze-protocol §5 satisfied → `ENABLED=1`, `cache-warmer.timer` restarted.
Overnight soak: the timer warms `149d1e07` on its natural 45–58 min window.

## Cost per warm (v3)

`0.1 × prefix + ~30–40 output tokens` — same economics as the freeze-protocol
model (§4), now with zero mismatch risk: a replay can only read the cache its
own original request wrote (or re-write it if expired — bounded by the same
window gating that prevents warming cold sessions).

## Limitations / open items

- Only sessions launched AFTER the bashrc wiring (with the proxy up) are
  warmable. Pre-existing sessions (including the orchestration hub) have no
  captures and age out as before.
- Proxy downtime while a proxied session is mid-conversation → API errors
  until systemd restarts it (Restart=always, 2 s). Sessions launched while the
  proxy is down run direct (guard in bashrc) and are simply unwarmable.
- `x-claude-code-session-id` ≠ conversation sid (it's some per-process id);
  replay reuses the captured value — works. Semantics of
  `prompt-caching-scope-2026-01-05` unconfirmed.
- RC sessions' prompts may contain the claude.ai session URL
  (attribution.sessionUrl) — irrelevant to v3 (replay is exact), but relevant
  if anyone revives fork-based approaches.

## Convergent prior art

After the fix was deployed, web research (GPT-5.5 Pro) surfaced an open
proposal in `claude-code-cache-fix` for a proxy-level warmer that captures the
real request prefix and replays a minimal payload — independently converging
on the same architecture. Two additional levers worth knowing:

- `--exclude-dynamic-system-prompt-sections` (CLI flag) moves per-machine
  sections — including, presumably, the scratchpad path — out of the system
  prompt into the first user message, which forks replay verbatim. Untested
  here, but it may make fork-warming viable again IF every live session is
  also launched with it.
- `OTEL_LOG_RAW_API_BODIES=file:<dir>` natively dumps untruncated request
  bodies, which could replace the capture proxy (headers would still need a
  separate source — replay requires the exact `anthropic-beta` list and
  `x-claude-code-session-id`).
