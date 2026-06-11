# Backlog

Deferred improvements from the 2026-06-11 GPT-5.5 Pro review
(`reviews/gpt-5.5-pro-review-2026-06-11.md`):

- **Env replication**: replicate a safe allowlist of prefix-affecting env vars
  from `/proc/<pid>/environ` of the live process instead of hardcoding the
  TTL var; log a prefix-config hash per warm. (v0.3.1 fails closed on
  prefix-affecting *flags*; env vars and the binary version are still
  unreplicated — record claude version/mtime at discovery and skip on change.)
- **PTY redesign over tmux**: replace screen-scraping readiness/verification
  with a pseudo-terminal wrapper + JSONL marker detection (P2 from both reviews).
- **Compaction-aware baseline**: detect a compact boundary after the last
  assistant turn so a recently-compacted session isn't false-`short_request`'d.
- **PTY redesign**: replace tmux screen-scraping with a pseudo-terminal
  wrapper + JSONL marker detection (tmux as process sandbox only).
- **Test suite + CI**: JSONL fixtures (user activity, fork usage, malformed
  records), shell tests (path spaces, corrupt state, ambiguous forks),
  shellcheck/shfmt in CI.
- **SECURITY.md** with explicit threat model; compatibility matrix
  (distro / Bash / tmux / Claude Code versions).
- **measure-ttl.py filters**: `--since`, `--model`, `--project`; exclude
  archived fork logs; per-model bucketing; sparse-sample warnings.
- **install.sh**: resolve absolute tool paths into the unit (systemd PATH
  differs from interactive shells); escape ExecStart for exotic repo paths.
- **Structured receipts**: append per-warm JSON receipts (sid, nonce, usage,
  outcome) to a receipts file for analysis.
