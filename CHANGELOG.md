# Changelog

## Unreleased — v3 hardening (GPT-5.6-Pro review, 2026-08-12)

Eight findings against the v3 replay engine. The engine had **no tests at all**
before this pass — `tests/run.sh` covers the v2 fork engine only — which is why
every one of these landed unguarded. `tests/run-v3.sh` (104 assertions,
hermetic: temp HOME, temp capture store, a local fake api.anthropic.com, a stub
replay; no network, no credentials, and it never runs `install.sh`) now runs in
CI alongside shellcheck for `replay-warmer.sh` and `lib/units.sh`.

- **The published install path shipped the broken engine.** The README said v2
  was dead on Claude Code ≥ 2.1.198 and to use v3; the only install command was
  `./install.sh`, which hard-coded `cache-warmer.sh`. `install.sh` now installs
  the v3 stack by default — `prefix-proxy.service` (supervised) plus the timer
  pointed at `replay-warmer.sh`, with `node` in the dependency check and one
  shared capture directory named in both units — and refuses `--engine v2` on an
  affected version without `--force-v2`. Unit rendering and version gating moved
  to `lib/units.sh` so they are testable without installing anything.
- **Capture retention no longer depends on the warmer.** Full conversation
  bodies were pruned only after `replay-warmer.sh`'s `ENABLED != 1` early exit,
  and only for `req-*` — so the shipped default (`ENABLED=0`) and any proxy
  crash left prompts on disk indefinitely. `prefix-proxy.js` now prunes both
  `req-*` and `pending-*` in its own store at startup and every 10 min, and
  re-asserts mode 0700 on a directory that already exists.
- **Replay warms are output-capped.** A replay resent the capture's own
  `max_tokens`, thinking budget and task, then consumed the entire regenerated
  answer. `warm-replay.py` now caps `max_tokens` with a byte-surgical edit that
  leaves every cache-key-bearing byte untouched (ambiguous bodies are refused,
  not guessed), and aborts the stream at `message_start` when the cap alone
  cannot bound generation. Uncappable and unabortable ⇒ refused. The unmeasured
  "~30–40 output tokens" cost claim is **withdrawn** pending
  `tests/live-replay-gate.sh`.
- **A malformed `EXCLUDE_SIDS` fails closed.** Bash returns status 2 for a
  regex that does not compile and 1 for one that does not match; inside an `if`
  both read as false, so a typo silently excluded nothing and the warmer
  replayed sessions the operator had ruled out. Both regex knobs are now
  compile-checked at startup, before pruning or replaying.
- **Time gates are re-read per candidate.** A run-wide `now` aged every session
  as of run start while an earlier candidate could hold the loop for jitter plus
  a 180 s socket timeout. The clock is re-read per candidate and again after the
  jitter, the dispatch is aborted if the window closed, and `last_attempt`
  records the actual dispatch time. Jitter is now a knob (`MAX_JITTER`).
- **The proxy and warmer can no longer both claim success while capturing
  nothing.** One shared capture-directory setting; the proxy proves the store is
  writable at startup and exits if not; write failures are logged instead of
  swallowed; `/warmer-health` 503s on capture failure and
  `/warmer-health/json` reports capture state; the warmer exits nonzero when its
  store is unreadable or when recent captures exist but none are usable.
- **`MIN_MSGS` counts human turns.** It counted the raw API message array, so a
  headless `claude -p` job that made two tool calls cleared the gate that is
  documented as filtering exactly those. It now mirrors `lib/jsonl.py`'s
  real-user predicate.
Five further defects were found by a GPT-5.6-Sol review OF this pass, and each
one was a fix reintroducing a version of the problem it closed:

- **The `.bashrc` guard failed OPEN.** It compared `curl` output against `cat`
  output; with the proxy down curl prints nothing, and with the nonce file
  absent or relocated cat prints nothing, so empty matched empty and every
  session in that shell was pointed at a dead proxy. It is now `shell-guard.sh`
  — a tested file, not a README snippet — and requires a non-empty nonce.
- **An upstream stream error crashed the proxy.** `pres.pipe(res)` had no
  `error` listener, and an `error` event without one is an uncaught exception in
  a long-lived server.
- **The degraded latch could not clear.** `/warmer-health` 503s on write
  failure, the guard then stops routing sessions, so no capture is produced and
  `writeErrors` never resets — the same deadlock the design already rejected for
  `no_capture_yet`. A writability probe on the retention timer clears it.
- **`Environment=` values were unquoted.** systemd splits that directive on
  whitespace, so a capture directory containing a space became a truncated
  assignment plus a stray token — reintroducing the proxy/warmer divergence.
- **The human-turn count accepted a non-array.** jq iterates an object's values,
  so `{"messages":{...}}` counted three turns off a body with no messages array.

- **Strict argument parsing.** `--dryrun`, `--dry-run=true` or any other typo
  ran a LIVE warm; even the correct flag pruned captures before printing
  anything. Unknown arguments now exit 2 before any side effect, and a valid
  `--dry-run` mutates nothing.

## v0.4.1 — 2026-07-02

- **Fix: a transient replay failure no longer permanently breaks a session's
  warm chain.** A failed replay (401/5xx/network) never touched the cache,
  but it still burned `RATELIMIT_MIN` — pushing the retry past `WARM_MAX_AGE`,
  so one blip inside the ~13-min warm window silently ended TTL refresh for
  that session. Observed in production: OAuth access tokens live 8 h and
  Claude Code refreshes them lazily, so a fully idle box sat unauthenticated
  for ~45 min overnight and the two sids whose windows landed in the gap
  dropped out of rotation. Failures now roll back `last_attempt` so the next
  timer tick can retry inside the still-open window — at most 2 rollbacks per
  failure streak (`<sid>.fail_count`), reset on any HTTP 200.
- **Sync the externally-reviewed hardening** that was live in production but
  missed the v0.4.0 push:
  - `prefix-proxy.js`: captures land as `pending-*` temps and are promoted to
    warmable `req-*` files only after upstream responds 2xx (an
    unauthenticated local POST can no longer seed the warm queue);
    `GET /warmer-health` serves a per-start nonce (mirrored 0600) so shell
    init can verify it is talking to this proxy; broader credential-header
    scrub (auth/token/secret/cookie/api-key/jwt/bearer); 0700 capture dir;
    SSE-safe piping with upstream abort on client disconnect.
  - `replay-warmer.sh`: refuse to replay captures declaring server-executed
    tools (web_search / web_fetch / code_execution / hosted MCP — a replay
    would re-run them on Anthropic infra); 0–44 s jitter between warms;
    `PRUNE_HOURS` default 48 → 6.
  - `warm-replay.py`: strip hop-by-hop + proxy-auth headers and reset
    `x-stainless-retry-count` so warms don't masquerade as SDK retries.
- config.example: document the v3 knobs (`MAX_CAPTURE_AGE_MIN`, `MIN_MSGS`,
  `PRUNE_HOURS`).

## v0.4.0 — 2026-07-02

- **v2 fork-warming declared broken on Claude Code ≥ 2.1.198**: the system
  prompt embeds a session-specific scratchpad path
  (`/tmp/claude-<uid>/<project>/<SESSION-UUID>/scratchpad`), so a
  `--fork-session` prefix can never match its parent's. Byte-level diff of
  captured request bodies in docs/V3-DIAGNOSIS.md.
- **New v3 replay architecture**: `prefix-proxy.js` (localhost logging proxy
  on `ANTHROPIC_BASE_URL`, auth never persisted) + `replay-warmer.sh`
  (replays each session's newest captured request byte-and-header-exact with
  a fresh OAuth token) + `warm-replay.py`. Verified two consecutive warms:
  `cache_read=71383, cache_creation=0`.
- README banner warns v2 users; v3 install/tests/CI integration tracked in
  BACKLOG.

## v0.3.3 — 2026-06-11

- **Defensive keepalive re-submit** for busy / remote-control (`/rc`) sessions.
  Forking an actively-reconnecting session can swallow the keepalive's Enter
  (the text lands in the input box but never submits → no reply → timeout).
  After the initial Enter, if the nonce is still on the input line, press Enter
  again (and up to 3 more times during the reply wait, only while no fork jsonl
  has appeared). Harmless on the happy path (Enter on an empty prompt is a
  no-op). Verified: clean warm-cache MCP session still `verified_full_hit` at
  ~99.99% cache_read.

  Context: empirically confirmed the core path works on a normal warm-cache MCP
  session (cache_read 86793/86795). The prior failures were unrepresentative
  subjects — an aborted 0-message session, a 6.4h-cold session (cache already
  expired → cache_read=0, correct), and an actively-orchestrating /rc session
  (this fix).

## v0.3.2 — 2026-06-11

**Fixes the main real-world failure: forks of large/old/MCP sessions never warmed.**
Root cause: a fork resuming a substantial session hits an interactive startup
prompt before the input line, so the readiness check timed out at 180s and the
session was never warmed (no spend, but no warm either — and these are exactly
the high-value sessions). Two prompts handled in the readiness loop:

- **Resume-from-summary** (old/large sessions: "Resume from summary /
  Resume full session as-is"): the warmer now selects **full resume** (option
  2). Critically, a *summary* resume would build a different, smaller prefix
  that wouldn't match — or re-arm — the live session's cache. (Reproduced and
  verified: fork reaches the input line in ~10s instead of timing out.)
- **MCP server-approval** ("[✔] server … Enter to confirm · Esc to reject
  all"): the warmer confirms the pre-selected servers (Enter), never rejects —
  rejecting would drop tools from the prefix and force a mismatch.

Note: Claude Code auto-updated 2.1.173→2.1.174 during testing, which shifted
which prompt a given fork shows — an instance of the binary-drift risk noted in
BACKLOG. The handlers cover both; unrecognized prompts still fail safe (timeout,
no spend).

## v0.3.1 — 2026-06-11

Hardening from a second independent adversarial review (Claude Fable 5, max
effort; full text in `reviews/fable-5-max-review-2026-06-11.md`). That review
found 0 P0 / 6 P1 / 17 P2 against v0.3.0; the data-safety core held, but the
P1s were all real (three empirically confirmed on the dev machine). Fixes:

- **Armed-fork disclosure** (P1-1): README now documents that the fork runs
  with the live session's permissions (incl. `--dangerously-skip-permissions`);
  the keepalive is an explicit do-not-act instruction; new
  `WARM_BYPASS_SESSIONS=0` skips bypass-permission sessions.
- **Stray-fork recursion** (P1-2): candidates containing the keepalive marker
  are skipped — a `--fork-session` copy carries the parent's full history and
  would otherwise pass every gate and get warmed as a phantom session.
- **Stale clock** (P1-3): the freshness/idle/rate timestamp is recomputed per
  candidate, not once per run — a multi-warm run no longer mis-ages later
  sessions into cold warms and false strikes.
- **Project-dir mapping bug** (P1-4): fork identification uses `dirname` of the
  live jsonl instead of recomputing the dir from cwd (Claude Code maps `.`→`-`
  too, so the old computation silently failed for dotted paths).
- **Flag replication** (P1-5): handle `--model=value` form; fail *closed*
  (skip + log) on prefix-affecting flags that can't be replicated, instead of
  paying two full writes to discover the divergence.
- **Scheduled drift** (P1-6): skip warms whose freshness reference crosses a
  calendar-day boundary (date-in-prefix divergence); the mismatch blacklist is
  now a `MISMATCH_COOLDOWN_DAYS` cooldown, not permanent.
- Plus: real process-exit wait via pane PID (P2-2, the v0.2.1 fix was a no-op);
  sidechain-aware expected-prefix + usage parsing (P2-3, P2-17); regex-validity
  and numeric/marker config validation (P2-5, P2-15); unknown-arg rejection
  (P2-7); dry-run is now side-effect-free (P2-8); `stat` TOCTOU guard (P2-10);
  exact-match (`=`) tmux targeting + pinned window names (P2-11); wrapper-launch
  process discovery (P2-12); measure-ttl.py deleted-file + fork-exclusion
  guards (P2-14). README: Bash 4.4+, linger note, drift/MCP caveats.

## v0.3.0 — 2026-06-11

- Warm results are now classified against the LIVE session's expected prefix
  size (its last assistant turn's total input): `verified_full_hit`
  (cache_read ≥ 80% of expected), `partial_hit` (mid-prefix divergence),
  `short_request` (fork didn't replay the full context), `cold_or_mismatch`
  (root divergence or expired cache), plus `*_no_baseline` fallbacks. RESULT
  lines carry `class=` and `expected=` fields. Only `verified_full_hit`
  counts as a successful warm; all other classes feed the two-strike
  blacklist.

## v0.2.1 — 2026-06-11

Fixes found by end-to-end testing of v0.2.0:

- The NBSP in the readiness regex is now written as the `\u00a0` ANSI-C
  escape — a literal no-break space character in the source was silently
  normalized to a plain space during editing, breaking readiness detection.
- Verify-then-commit scans the whole input area (last `❯`-line to pane end):
  the nonce-tagged keepalive is long enough to wrap onto continuation lines.
- After killing the fork window, wait for the process to fully exit before
  archiving its transcript — Claude flushes a final record on shutdown, which
  previously re-created a small stub in the project dir after the archive mv.

## v0.2.0 — 2026-06-11

Hardening release responding to an external adversarial review (GPT-5.5 Pro;
full text in `reviews/gpt-5.5-pro-review-2026-06-11.md`).

**Blocker fixes**
- Fork transcript identification is now content-based (per-warm nonce), never
  directory-diff. Transcripts are archived to `~/.cache/cache-warmer/forks/`
  (7-day retention) instead of deleted, and never touched when identity is
  uncertain. Eliminates the path where a concurrent new session log could be
  misidentified and removed.
- The fork environment now sets `ENABLE_PROMPT_CACHING_1H=1` explicitly, and
  the systemd unit carries `Environment=ENABLE_PROMPT_CACHING_1H=1` — systemd
  user services don't source shell profiles, so the previous version could
  silently warm with a 5-minute TTL.

**Other fixes**
- Usage verification is tied causally to the nonce-tagged keepalive turn, not
  "last assistant message in the file".
- Session IDs validated against a strict UUID regex before any use; replicated
  flag values validated against a safe character set.
- `last_warm` is written only after a verified successful warm; rate limiting
  uses a separate `last_attempt` timestamp. State writes are atomic; corrupt
  state files read as 0 instead of aborting the run.
- Folder-trust prompts are never auto-accepted — the warm fails loudly.
- First low-cache-read result is a warning; blacklist only on the second
  consecutive occurrence.
- Fork tmux session is namespaced per-UID; orphan cleanup refuses to kill a
  session containing windows it didn't create; an exit trap reaps the
  in-flight fork window on SIGTERM/exit.
- Per-directory candidate scan capped at the 10 newest session logs.
- `config.example` ships `ENABLED=0`; install flow directs users through
  `measure-ttl.py` and `--dry-run` before enabling.
- README rewritten to present receipts as evidence (not proof), version-stamp
  the empirical claims, state GNU/Linux assumptions, and document the
  candidate-discovery limitation.

## v0.1.0 — 2026-06-11

Initial release: fork-based warming, RESULT receipts, measure-ttl.py,
systemd timer install.
