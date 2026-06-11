# Adversarial Pre-Release Review — claude-code-cache-warmer v0.3.0

**Reviewer:** Claude Fable 5 (max effort)
**Date:** 2026-06-11
**Repo version:** v0.3.0 (HEAD)
**Scope:** README.md, cache-warmer.sh, config.example, install.sh, measure-ttl.py, CHANGELOG.md, BACKLOG.md, .gitignore, LICENSE. Independent review; no prior reviews consulted.
**Method:** line-by-line audit of shell/python, plus empirical verification on a machine that has actually run the tool (project-dir naming scheme, archived fork transcript contents, `claude --help` flag forms). Empirical observations are labeled as such.

---

## Summary

The core mechanism is sound and the v0.2 hardening shows: transcript identification is content-based, the keepalive is verify-then-commit, archive identity checks are genuinely careful, and every spend is receipt-logged. I found **no path by which the tool corrupts or deletes a real user session, and no path by which it types into a user-owned pane** — the file-moving and tmux-targeting logic held up under adversarial reading.

What did not hold up: (1) the fork is a fully-armed Claude agent running with the live session's permissions — including `bypassPermissions`, which the author's own archived forks confirm — and nothing in the README says so; (2) several deterministic prefix-divergence sources (date rollover, auto-updated binary, `=`-form flags, unreplicated flags) each cost two full cache writes and then a **permanent** blacklist of a healthy session; (3) a confirmed bug in the project-dir mapping silently disables the tool for any path containing a `.`; (4) stray fork transcripts — full copies of the parent history — can re-enter the candidate pool and be warmed as if they were real sessions.

**0 × P0, 6 × P1, 17 × P2.** Not ready for public release as-is; one more focused iteration away.

---

## P1 findings

### P1-1. The fork is an armed agent: it executes tools with the live session's permissions, including bypass mode

**Lines (cache-warmer.sh 212–218):**
```bash
[[ $args == *"--dangerously-skip-permissions"* ]] && out+=" --dangerously-skip-permissions"
...
if [[ $args =~ --permission-mode[[:space:]]+([^[:space:]]+) ]] && ... out+=" --permission-mode ${BASH_REMATCH[1]}"
```

**Empirical:** every archived fork transcript on the dev machine carries `{"type":"permission-mode","permissionMode":"bypassPermissions",...}` as its third record. This is the live configuration, not a hypothetical.

**Failure scenario:** A live session sits idle mid-task; its last assistant message ends "I'll continue with the migration next." The fork resumes that full context in bypass mode, headless, in the user's real working directory, and receives "[cache-warmer keepalive] No action needed — reply with only: ok". Most of the time the model replies "ok". Occasionally — and this tool rolls that die every ~50 minutes per idle session, unattended, indefinitely — the model decides to continue the task. In bypass mode its first response can be a `tool_use` (Edit, Bash, git push) that **executes immediately with no approval gate**. The reply-polling loop only notices the first assistant record on a 5-second cadence and then kills the window — an Edit or `rm` completes long before that. Result: uncommanded modifications to the user's working tree from a hidden tmux window the user never sees.

The README's "Safety mechanics" section covers transcript safety exhaustively and says nothing about this. That omission is the worst part: a user reading "the keepalive is typed only into the disposable fork" will reasonably conclude the fork is inert. It is not — it is the same agent, with the same tools, in the same cwd.

**Severity note:** rated P1 rather than P0 because it requires the model to disregard an explicit instruction, which is rare per-event. For users who run bypass-permission sessions routinely (the author does), it borders P0 by accumulation.

**Fix direction:** (a) document this prominently in Safety mechanics and Caveats; (b) add a config gate (default on?) that refuses to warm sessions running `--dangerously-skip-permissions`; (c) investigate whether any tool-restriction flag (`--disallowedTools`?) leaves the prompt prefix untouched — if none does, state the cache-identity-vs-fork-safety tension explicitly in the README; (d) tighten the reply poll to 1s to shrink the action window after a first tool call appears.

### P1-2. Stray fork transcripts are fully-qualified warm candidates — the warmer can end up warming its own dead forks

**Lines:** candidate gates at 414–469 contain no exclusion for fork artifacts; archive-failure paths at 386–389:
```bash
log "note: could not archive fork transcript $fork_jsonl (left in place)"
...
log "note: fork transcript identity not certain ($fork_jsonl) — left in place, NOT touched"
```
and the no-identification path (`fork_jsonl` never set when `match_count != 1`) leaves the file in the project dir with no archive attempt at all.

**Empirical:** archived fork `f3deac86…jsonl` is 3.7 MB / 1,299 lines and contains **25 real user messages** — `--fork-session` copies the parent's full history, with original timestamps, into the new file. Such a file passes `MIN_USER_MSGS=2` trivially, and `user_activity` reads the *copied* recent user timestamps, so it passes the idle gate exactly as long as its parent does.

**Failure scenario:** any archive failure (mv error, identity-uncertain branch, `match_count` ≠ 1, or the P1-4 mapping bug stranding the fork in a directory the warmer searched wrongly) leaves a full-copy fork jsonl in the project dir with a fresh mtime. On the next run it is one of the 10 newest files, passes every gate, and gets warmed on its own 45–58 min cycle — paying real cache-read (or, mismatched, cache-write) costs for a transcript nobody will ever resume. If the original failure cause persists, its forks fail the same way and the pile grows. There is **no global per-run or per-day warm cap** to backstop this; the only bounds are the per-sid gates.

**Fix direction:** in `process_candidate`, skip (and optionally quarantine-archive) any candidate file containing the keepalive marker — one cheap `grep -qF` closes the loop. Note the dependency: this only works if the marker survives config edits (see P2-15 — the author's own test keepalive, visible in archived forks, *omitted* the marker). A spawned-fork-sid ledger in `$STATE_DIR` would be marker-independent. Also add a global per-run warm cap.

### P1-3. `NOW` is captured once per run; multi-warm runs evaluate later candidates with stale ages, defeating the cold-session gate and feeding wrongful permanent blacklists

**Lines:** 410 `NOW=$(date +%s)`, consumed at 442 (`age_min`), 449 (rate limit), 465 (`user_idle_min`). Each warm can take ~3–6 minutes (`FORK_SPAWN_TIMEOUT=180` + reply wait + sleeps).

**Failure scenario:** three sessions are in the warm window at tick time (plausible for the multi-session tmux users this tool targets). The first two warms consume ~12 minutes. The third candidate's age was computed as 50 at run start; it is actually 62 — past `WARM_MAX_AGE` and past the ~60-min cliff. The fork resumes a **cold** prefix and pays a full cache write at 2× (the exact cost the window gate exists to prevent), and the result is classified `cold_or_mismatch` → strike. The same scheduling pattern recurs the next idle cycle → second strike → `touch "$STATE_DIR/${sid}.fork_mismatch"` → a perfectly healthy session is **permanently** blacklisted because of run-internal latency. The logged `age=` value is also wrong, so the receipt actively misleads diagnosis.

**Fix direction:** recompute the timestamp inside `process_candidate`, immediately before the window/rate/idle gates. One `date +%s` per candidate is free.

### P1-4. Project-dir mapping replaces only `/`; Claude Code also maps `.` (confirmed) and likely other characters — silent no-op for dotted paths, double-spend for `--resume` ones

**Lines (226, 494):**
```bash
local project_dir="$HOME/.claude/projects/${cwd//\//-}"
```

**Empirical (confirmed):** `~/.claude/projects/` on the dev machine contains `-home-ashita--claude-plugins-marketplaces-claude-plugins-official`, i.e. `/home/ashita/.claude/plugins/...` with `.` → `-`. Additionally, zero of 100+ project dir names contain `_` while underscore paths exist in the workspace — Claude Code almost certainly sanitizes every non-alphanumeric character to `-`, not just `/`.

**Failure scenario A (dir-scan candidates):** a user works in `/home/u/myapp.web`. The computed `project_dir` does not exist, `[[ -d $project_dir ]]` (line 495) fails, and the session is silently never discovered. The tool quietly does nothing for every dotted project — a very common path shape — with no log line.

**Failure scenario B (`--resume` candidates, worse):** the jsonl is found by `find` (509–511) so the warm proceeds, the fork spawns and **spends a real request** — but the nonce search at 299 looks in the nonexistent computed directory, never identifies the transcript, logs `FAIL ... no nonce-matched fork reply`, never writes `last_warm`, and re-attempts once more inside the window. Recurring unverified spend, every idle cycle, plus the fork transcript is stranded in the *real* project dir → feeds P1-2.

**Fix direction:** for fork identification, stop recomputing the directory from cwd: use `dirname "$live_jsonl"` (correct by construction for both candidate paths). For discovery, replicate Claude Code's actual sanitization (replace every char outside `[A-Za-z0-9]` with `-`) and verify the mapping against a known dir at install time.

### P1-5. `replicated_flags` misses `--model=value` form and ignores every other prefix-affecting flag — deterministic 2-full-writes-then-permanent-blacklist for affected launch styles

**Lines (213–218):**
```bash
if [[ $args =~ --model[[:space:]]+([^[:space:]]+) ]] && ...
```

**Empirical:** `claude --help` shows commander-style `--model <model>` options; commander accepts `--model=opus`, which this regex (requiring whitespace) never matches.

**Failure scenario:** a user always launches `claude --model=opus`. The fork runs the default model. The prompt cache is model-keyed, so the fork pays a **full cache write of the entire prefix into a parallel namespace** (~700k × 1.25–2× for the README's flagship session), classified `cold_or_mismatch`; the second warm repeats it; then the session is permanently blacklisted. This repeats for *every session this user ever starts* — a deterministic ~2M-token-equivalent tax per session, loudly logged but easy to not watch. The identical failure class applies to unreplicated `--append-system-prompt`, `--settings`, `--add-dir`, `--agent`, `--mcp-config`, `--allowedTools`, `--betas`, etc., all of which can alter the system prompt.

**Fix direction:** support `=` forms; more fundamentally, fail closed — keep an explicit list of known-prefix-affecting flags and *skip with a log line* any session whose args contain one the warmer cannot replicate, instead of paying two full writes to discover the divergence empirically.

### P1-6. Deterministic prefix drift between live request and fork: date rollover, auto-updated binary, CLAUDE.md churn — each guaranteed mismatch, made sticky by the permanent blacklist

**Lines:** the whole `warm_by_fork` design assumes the fork rebuilds the live session's prefix byte-identically; classification (336–357) detects divergence but each detection costs a full cache write and a strike, and `${sid}.fork_mismatch` (368) never expires.

**Failure scenarios (all deterministic, none documented):**
- **Midnight:** the prompt context embeds the current date (certainly for any setup whose CLAUDE.md/memory carries a date — including the author's, updated daily by automation; very likely for vanilla Claude Code too). Session idle at 23:30, warm fires at 00:15 → root divergence → full write + strike. Night-owl users hit this nightly.
- **Auto-update:** Claude Code auto-updates by default. The live TUI keeps running the old binary; the fork spawns the *new* one, whose system prompt differs. Every session alive across an update window mismatches deterministically.
- **CLAUDE.md / MCP drift:** any edit to CLAUDE.md, rules, or MCP tool schemas between the live session's last request and the warm changes the rebuilt prefix.

In each case the containment works, but the outcome is 2 full prefix writes and a **permanent** blacklist of a session that would have warmed fine the next day on the next launch of the same context.

**Fix direction:** skip warming when the calendar date differs from `date(fresh)` (one-line guard, eliminates the most common case); record the claude binary version/mtime at discovery and skip on change; convert the blacklist from permanent to a cooldown (expire the `.fork_mismatch` file after N days); enumerate these drift sources in the README's caveats.

---

## P2 findings

### P2-1. Blacklist is permanent, undocumented, and "consecutive" is misleading
Line 368 `touch "$STATE_DIR/${sid}.fork_mismatch"` — never expires; no documented reset (the answer is `rm` of an undocumented state file). The counter (363–365) is only reset by a verified success, so "2nd consecutive occurrence" can be two mismatches days apart with many non-strike FAILs between. Amplifies P1-3/5/6. **Fix:** expiry + a documented `--unblacklist <sid>` or README note.

### P2-2. The "wait for the fork process to fully exit" loop checks the *window*, not the process — the v0.2.1 stub-recreation fix doesn't do what the changelog says
Lines 317–321:
```bash
while (( dead_wait < 10 )); do
    tmux list-panes -t "$win" >/dev/null 2>&1 || break
```
`kill-window` destroys the window immediately, so `list-panes` fails on the first iteration and the loop is a no-op; the real guard is the single `sleep 1` at line 322. A slow claude shutdown (>~1–3 s flush after SIGHUP, plausible for huge sessions) can still recreate a stub jsonl after the archive `mv` — the exact bug CHANGELOG v0.2.1 claims fixed. **Fix:** capture the pane PID (`tmux display -p '#{pane_pid}'`) before killing and poll `/proc/<pid>` for exit.

### P2-3. `live_expected_tokens` does not exclude sidechain records — a subagent's small usage can become the denominator, producing a false `verified_full_hit` that resets the strike counter
Lines 183–203 take the *last* assistant record with positive usage; Claude Code stores subagent (sidechain) turns in the same jsonl with small per-subagent contexts. If the session's final flushed assistant record is a sidechain turn (user walked away mid-/post-subagent), `expected` might be 20k while the real prefix is 700k; a fork that diverged early and read only 16k then satisfies `c_read*10 >= expected*8` → classified `verified_full_hit`, `last_warm` written, mismatch counter wiped — a false green receipt. **Fix:** skip records with `isSidechain` true in both `live_expected_tokens` and `fork_usage_for_nonce`.

### P2-4. Compaction in the live session produces false `short_request` strikes
If the user compacts (or auto-compact fires) and walks away before the next turn, the last assistant usage record reflects the huge *pre-compact* prefix while the fork resumes the small *post-compact* state → `total * 2 < expected` (line 339) → strike, twice → blacklist of a healthy, recently-compacted session. **Fix:** detect a compact-boundary record after the last assistant turn and recompute/skip the baseline.

### P2-5. Invalid `EXCLUDE_SIDS` / `INCLUDE_ONLY_SIDS` regexes fail open
Lines 424–428: `[[ $sid =~ $EXCLUDE_SIDS ]]` with a syntactically invalid regex returns 2, which the `if` treats as false — a broken *blocklist* silently warms the sessions the user explicitly excluded, and a broken *allowlist* (the "controlled testing" mechanism) silently warms everything. Bash's stderr complaint goes to the journal nobody watches. **Fix:** validate both regexes once at startup (`[[ "" =~ $re ]]`; exit status 2 → abort with a clear error).

### P2-6. Stated Bash requirement (4+) is wrong: needs 4.4
`"${candidates[@]}"` (line 522) and `"${!RESUME_SID_ARGS[@]}"` (509) on **empty** arrays under `set -u` are fatal "unbound variable" errors on Bash 4.0–4.3 (CentOS 7, Debian 8); `$' '` (256) needs ≥4.2. On Bash 4.3 the script dies on any run with no resume candidates. **Fix:** require Bash 4.4+ in README, or add a version check at startup.

### P2-7. Unknown CLI argument silently runs for real
Lines 59–62: the `case` has no default; `./cache-warmer.sh --dryrun` (typo) or `--dry_run` performs a full warming run with real spend. **Fix:** `*) echo "unknown arg" >&2; exit 2 ;;` for any non-empty unrecognized argument.

### P2-8. `--dry-run` is not side-effect-free
Lines 396 (archive prune `-delete`) and 400–408 (orphan tmux `kill-session`) execute regardless of `DRY_RUN`. A user previewing decisions can have a leftover fork session killed and week-old audit archives deleted. README/usage promise "log decisions, spawn nothing". **Fix:** gate both blocks on `(( ! DRY_RUN ))`.

### P2-9. Trust-prompt detection string likely doesn't match the actual TUI text
Line 258 `grep -q "trust this folder"` — Claude Code's prompt reads (in versions I know) "Do you trust the files in this folder?", which does **not** contain the substring "trust this folder". Unverified against v2.1.173, but if mismatched, the trust case degrades from an immediate, correctly-diagnosed failure to a 180 s timeout with a generic "fork TUI not ready" message (still never auto-accepted — fails safe). **Fix:** verify the literal text on the pinned version; match a more robust substring ("trust the files" / "trust").

### P2-10. A candidate jsonl vanishing mid-run aborts the entire run via `set -e`
Line 439 `mtime=$(stat -c %Y "$jsonl")` — `process_candidate` runs with `set -e` active when invoked from the discovery loops (511, 523). The `[[ -f $jsonl ]]` guard at 416 leaves a TOCTOU window (candidates are processed sequentially and earlier warms take minutes; Claude Code's `cleanupPeriodDays` reaper or a user deletion can remove a file in between). One vanished file kills the whole run, skipping all remaining candidates. **Fix:** `mtime=$(stat -c %Y "$jsonl" 2>/dev/null) || return 0`.

### P2-11. tmux target prefix-matching and rename-hostile configs; renamed fork windows become unreapable idle Claude processes
All `-t "$FORK_TMUX_SESSION"` usages rely on tmux's prefix/fnmatch session matching (`=` exact-match prefix not used), and window targeting by name breaks if the window is renamed. With `set -g allow-rename on` (non-default but real) the fork window gets retitled; `capture-pane`/`kill-window`/the EXIT trap all miss it, and the next-run cleanup (402) sees a name not matching `^w[0-9]+-[0-9a-f]{8}$` and deliberately "leaves it alone" — an idle Claude process with a restored 700k session (hundreds of MB RSS) orphaned per attempt, accumulating across days. No API spend (nothing was typed), but a real resource leak that the conservative cleanup can never collect. **Fix:** use `-t "=$FORK_TMUX_SESSION"` everywhere; set `allow-rename off` / `automatic-rename off` on the created window explicitly; track the pane PID for cleanup instead of the window name.

### P2-12. Process discovery misses legitimate TUIs and over-excludes on substring matches
Line 506 matches `comm == claude` — wrapper-launched instances (`npx claude`, shell aliases execing node directly) report `comm=node` and are silently invisible (tool no-ops with no log). Line 487–489 `case " $args " in *" -p "*` excludes any TUI whose *prompt argument text* contains " -p " (e.g. `claude "fix the -p flag handling"`). Both are conservative (miss, never mis-warm) but silent. **Fix:** also match `args` containing `/claude` for discovery; anchor the `-p` check to pre-`--` argument positions or accept the documented limitation in README.

### P2-13. Each warm boots the full MCP stack and auxiliary model calls — side effects and costs the README doesn't count
The fork is a complete Claude Code instance: it starts every configured MCP server (stateful servers — log writers, agent-registry buses, browser daemons — fire their startup side effects on every warm, headless), and the archived forks show `"type":"ai-title"` records, i.e. an auxiliary title-generation model call per fork. MCP tool-schema drift between live launch and warm is also another silent prefix-divergence source (joins P1-6). The README's "fails loudly before the keepalive is sent and cost nothing" and the cost model ignore all of this. **Fix:** document; consider `--strict-mcp-config` only if it is prefix-neutral (it likely is not — verify).

### P2-14. measure-ttl.py: crash on deleted files, and self-contamination once the warmer is enabled
Line 37–40: `key=os.path.getmtime` raises `OSError` if a file is deleted between `glob` and `sorted` (Claude Code's transcript reaper does delete old jsonls) — unhandled, full traceback. Separately: once the warmer runs, live sessions show high hit ratios at 60+ min gaps *because the warmer re-armed them*, so re-running measure-ttl.py reports a longer TTL than real — a user "verifying" post-enable could widen the window onto the cliff. Sidechain turns also pollute buckets (partly acknowledged in BACKLOG). **Fix:** wrap the sort key; exclude marker-containing files and document "measure only with the warmer disabled".

### P2-15. Config-as-code footguns beyond the documented ones
`KEEPALIVE_TEXT` containing an embedded newline makes `send-keys -l` submit a partial message without the nonce (unverifiable turn, stray fork artifacts → P1-2); **removing the `[cache-warmer keepalive]` marker breaks any marker-based exclusion** — empirically the author's own archived test forks contain a marker-less keepalive ("Reply with the single word: ready"), which `user_activity` counted as a *real user message*; non-numeric `FORK_SPAWN_TIMEOUT` et al. crash the arithmetic under `set -e`. **Fix:** validate config values after sourcing (numeric checks, single-line keepalive, marker present), abort with a clear message.

### P2-16. Deployment environment gaps (partly BACKLOG-acknowledged)
(a) systemd user units stop at logout without lingering — users who SSH in, detach tmux, and log out get **no warming**, silently; needs a README note (`loginctl enable-linger`). (b) `ExecStart=$REPO_DIR/cache-warmer.sh` (install.sh 38) breaks for repo paths with spaces (acknowledged). (c) When the warmer itself starts the tmux server (no user server running), the pane's PATH is systemd's minimal one and `claude` may not resolve → every warm fails "not ready" (BACKLOG-adjacent; resolve absolute claude path into `spawn_cmd`). Also note: a tmux server started inside the oneshot unit's cgroup is killed when the unit deactivates — surprising but currently harmless.

### P2-17. `fork_usage_for_nonce` fragilities
Lines 169–172: after the nonce, it `break`s at the **first** assistant record even if that record has no usage (e.g. an error turn) — a subsequent successful retry turn is never read, converting a recoverable warm into a FAIL. It also doesn't skip `isSidechain` records, and `u.get(..., 0)` returns `None` (printed literally, silently treated as 0 by bash arithmetic) if the API ever emits an explicit null. **Fix:** skip usage-less and sidechain assistant records; coerce with `or 0`.

---

## Classification-threshold audit (warm_by_fork, lines 336–357)

The arithmetic is **correct** and integer-safe:
- `(( c_read * 10 >= expected * 8 ))` ⇔ c_read ≥ 0.8·expected → `verified_full_hit`. Matches the README's "read ≥80% of the live session's prefix volume" exactly. No overflow risk (values ≤ ~10⁷ against 64-bit arithmetic).
- `(( total * 2 < expected ))` ⇔ total < 0.5·expected → `short_request`; checked first, correctly, so a half-size request can't masquerade as a partial hit.
- `(( c_read * 5 >= expected ))` ⇔ c_read ≥ 0.2·expected → `partial_hit`; else `cold_or_mismatch`. Branch ordering and boundary inclusivity (≥) are sensible.
- No-baseline fallback `(( c_read * 2 >= total ))` is the weakest gate (a 60%-depth divergence passes as `verified_hit_no_baseline` and writes `last_warm`), but it only fires when the live file yields no usage at all — acceptable, worth a comment.

The **semantics are honest** with three caveats: (1) a `verified_full_hit` at exactly 0.8 leaves up to 20% of the prefix tail un-re-armed while logging WARMED and *resetting the mismatch counter* — persistent sub-threshold divergence is invisible by design (bounded, but the README could say "≥80%" more loudly than the one mention it gets); (2) the denominator can be silently wrong in both directions — sidechain-skewed low (P2-3, false green) and compaction-skewed high (P2-4, false strike); (3) `expected` is read at classification time from a file that hasn't changed since the gates ran, so no TOCTOU there — fine.

## Design soundness (fork-warming mechanism)

The mechanism is sound *in principle*: an interactive `--resume --fork-session` is the only client path that reproduces the live prefix bytes; a cache read re-arms the TTL on the blocks read (matches Anthropic's documented refresh-on-read behavior); verification from the fork's own usage record is the right evidence source; and the empirical groundwork (print-mode pings measured at `cache_read=0`, byte-identical live transcript) is exactly the right way to have built this.

The invisible assumptions, ranked by fragility:
1. **Byte-identical prefix reconstruction** — broken deterministically by date rollover, binary auto-update, CLAUDE.md/MCP drift, and unreplicated flags (P1-5/P1-6). The classification *detects* all of these, but detection costs 2 full writes + permanent blacklist each. The design treats divergence as an anomaly; several divergence sources are *scheduled events*.
2. **The fork is inert** — it isn't (P1-1). This is the one assumption the README actively (if unintentionally) misrepresents.
3. **Fork artifacts stay out of the candidate pool** — only via the archive happy path (P1-2).
4. **TUI rendering stability** — acknowledged honestly in the README; the verify-then-commit pattern makes essentially all rendering drift fail closed and pre-spend. This part of the design is genuinely good.
5. **Timer cadence vs. window width** — a long run holding the flock can starve another session's entire 13-min window (missed warm, no spend — fail-quiet, acceptable, worth a sentence).

README accuracy: mostly admirably honest (receipts-as-evidence framing, version-stamping, the discovery limitation). Overclaims/omissions: "a mismatch costs one cache write before containment" — it's two (warning strike + blacklisting strike); "cost nothing" pre-send ignores MCP startup side effects; "Bash 4+" should be 4.4+; bypass-mode forks, vim-mode (untested; verify-then-commit should fail it closed, but say so), blacklist reset, and the linger requirement are undocumented.

## Verified sound (checked, no finding)

- Archive identity validation (378–391): glob-anchored path check, UUID basename, `!= sid`, nonce re-grep — no path to moving a live session. The `${base} != ${sid}` guard plus nonce content requirement also covers other live sessions in the dir.
- tmux orphan cleanup (400–408): the every-window-must-match-pattern guard correctly refuses repurposed sessions.
- flock fd inheritance: tmux's server calls `closefrom()` after daemonizing, so the lock is not leaked into the server; spawned forks don't hold it.
- `env -u CLAUDECODE … ENABLE_PROMPT_CACHING_1H=1 claude …` is pure env(1) syntax — works under fish/csh default-shells, not just POSIX shells. Nested-session guard unsetting is a nice touch.
- `--resume` arg extraction: a pathological match like `--resume --f` is rejected by the UUID gate.
- systemd oneshot: `TimeoutStartSec` defaults to infinity for `Type=oneshot`, so multi-warm runs are not killed at 90 s; timer + flock double-protect against overlap.
- `ls -1t … | head -10 || true` under pipefail, mapfile from process substitution, `grep -c . || true` count handling — all correct.
- README cost arithmetic (0.1× reads, 1.25–2× writes, the 20× example, ~4–5 warms per 4 h) checks out.
- `.gitignore` correctly excludes the live `config`; install.sh chmod 600 on it; no secrets in repo.

---

## (a) Finding counts

| Severity | Count |
|---|---|
| **P0** | 0 |
| **P1** | 6 |
| **P2** | 17 |

## (b) Verdict on public-release readiness

**Not ready as published — one focused iteration away.** The data-safety core (the part that could destroy user sessions) survived adversarial review intact, and the receipts/containment philosophy is the right architecture. But P1-1 (undisclosed armed fork, empirically running `bypassPermissions`) is a disclosure blocker for a tool that leads with "Safety mechanics"; P1-4 is a confirmed correctness bug that silently disables or double-charges common path shapes; P1-5/P1-6 turn scheduled, predictable events into 2-full-writes-plus-permanent-blacklist penalties that contradict the cost-model section's framing; and P1-2's self-warming loop violates the tool's own "every spend is bounded" promise. All six P1s have cheap fix directions (a grep, a date guard, a `dirname`, a fail-closed flag list, a doc section, a re-`date`); none requires redesign. Fix those, bump to v0.3.1, and this is publishable as the experimental tool it honestly labels itself to be.

## (c) Three findings a previous reviewer most likely missed

1. **P1-2 — stray fork transcripts re-entering the candidate pool.** It requires connecting three distant facts: the archive-failure branches deliberately leave files in place, `--fork-session` copies the full parent history with original timestamps (only visible by opening an actual fork artifact — 25 real user messages in one), and the candidate gates have no fork-artifact exclusion. Each piece looks safe locally; the loop only appears when you compose them.
2. **P2-3 — sidechain records skewing `live_expected_tokens` into false `verified_full_hit`s that reset the strike counter.** It depends on a jsonl-schema detail (subagent turns share the session file with small per-turn usage) that nothing in this repo mentions, and it corrupts the *verification* layer — the part of the system every reviewer is told to trust.
3. **P1-1's empirical sharpening — the fork inherits `bypassPermissions` in actual operation.** A code-only reviewer can flag the flag-replication line as a theoretical concern; the archived fork transcripts on the dev machine show it is the *standing configuration*, which moves "model might act on a keepalive" from thought-experiment to an unattended dice-roll every 50 minutes — and it is the one risk the Safety mechanics section's framing actively obscures.
