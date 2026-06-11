# Changelog

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
