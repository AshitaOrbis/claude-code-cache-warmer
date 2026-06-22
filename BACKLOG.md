# Backlog

Deferred improvements from the 2026-06-11 GPT-5.5 Pro review
(`reviews/gpt-5.5-pro-review-2026-06-11.md`):

- [x] **Env replication** (cw-1): replicate a safe allowlist of prefix-affecting
  env vars from `/proc/<pid>/environ` of the live process instead of hardcoding
  the TTL var; record claude version/mtime at discovery and skip on drift.
  (`replicated_env` + `claude_binary_fingerprint`; binary-drift skip in
  `process_candidate`; fork env logged per warm.)
- [ ] **PTY redesign over tmux**: replace screen-scraping readiness/verification
  with a pseudo-terminal wrapper + JSONL marker detection (P2 from both reviews).
- [x] **Compaction-aware baseline** (cw-3): `live_expected_tokens` resets the
  baseline at every `isCompactSummary` boundary, so a just-compacted session is
  no longer false-`short_request`'d (falls back to the no-baseline check when no
  post-compaction usage turn exists yet).
- [ ] **PTY redesign**: replace tmux screen-scraping with a pseudo-terminal
  wrapper + JSONL marker detection (tmux as process sandbox only).
- [ ] **Test suite + CI**: JSONL fixtures (user activity, fork usage, malformed
  records), shell tests (path spaces, corrupt state, ambiguous forks),
  shellcheck/shfmt in CI.
- [x] **SECURITY.md** (cw-5): threat model (armed-fork permission inheritance,
  config-as-code, candidate-discovery ambiguity) + compatibility matrix
  (distro / Bash / tmux / Claude Code / python3 / jq / systemd).
- [x] **measure-ttl.py filters** (cw-6): `--since` (ISO or N[d|h|m]), `--model`,
  `--project`, `--by-model` per-context bucketing; excludes archived/marker fork
  logs and `<synthetic>` turns; sparse-sample warnings.
- [x] **install.sh** (cw-7): resolves absolute tool paths into the unit `PATH=`
  (systemd PATH differs from interactive shells); `ExecStart` calls `bash` with
  the script path double-quote-escaped for exotic repo paths.
- [x] **Structured receipts** (cw-8): appends per-warm JSON receipts (ts, sid,
  nonce, usage tokens, outcome, class, expected) to
  `~/.cache/cache-warmer/receipts.jsonl` via `jq`.
