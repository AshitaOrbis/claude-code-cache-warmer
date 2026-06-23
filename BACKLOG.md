# Backlog

Deferred improvements from the 2026-06-11 GPT-5.5 Pro review
(`reviews/gpt-5.5-pro-review-2026-06-11.md`):

- [x] **Env replication** (cw-1): replicate a safe allowlist of prefix-affecting
  env vars from `/proc/<pid>/environ` of the live process instead of hardcoding
  the TTL var; record claude version/mtime at discovery and skip on drift.
  (`replicated_env` + `claude_binary_fingerprint`; binary-drift skip in
  `process_candidate`; fork env logged per warm.)
- [x] **PTY redesign over tmux** (cw-2): the keepalive *submission* is now
  confirmed deterministically from the fork's own JSONL transcript
  (`submit-confirmed`: a real `user` record carrying the run-nonce proves Claude
  Code committed the turn), not by screen-scraping the pane. The JSONL is the
  source of truth; the pane is only a secondary "still un-sent?" signal for the
  bounded Enter-resubmit, and once the JSONL confirms submission we never nudge
  Enter again (no duplicate turns). Pre-submit TUI-dialog handling (folder-trust
  / resume-summary / MCP-approval) stays pane-based by necessity — those dialogs
  have no JSONL representation before the first turn. JSONL parsers extracted to
  `lib/jsonl.py` (testable); fallback path preserved.
- [x] **Compaction-aware baseline** (cw-3): `live_expected_tokens` resets the
  baseline at every `isCompactSummary` boundary, so a just-compacted session is
  no longer false-`short_request`'d (falls back to the no-baseline check when no
  post-compaction usage turn exists yet).
- [x] **PTY redesign** (cw-2, duplicate of the entry above): JSONL-marker submit
  detection replaces pane-scrape-as-truth; tmux is the process sandbox + the
  pre-submit dialog handler only. See the cw-2 entry above for detail.
- [x] **Test suite + CI** (cw-4): `tests/` with JSONL fixtures (real user
  activity, headless one-shot, keepalive-only fork artifact, compacted /
  no-post-turn baselines, fork reply with sidechain / usage-less error turns,
  malformed records) and `tests/run.sh` (23 assertions) exercising the
  parsing/classification/submit-detection logic — the core that decides whether
  to fork a live session and how to score the result. Testable logic extracted
  to `lib/jsonl.py` + `lib/classify.sh`. CI (`.github/workflows/ci.yml`) runs
  shellcheck (`--severity=warning -x`), shfmt format-check (lib/ + tests/),
  `py_compile`, and the test suite. shellcheck/shfmt verified clean locally.
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
