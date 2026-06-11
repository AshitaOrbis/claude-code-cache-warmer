# Changelog

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
