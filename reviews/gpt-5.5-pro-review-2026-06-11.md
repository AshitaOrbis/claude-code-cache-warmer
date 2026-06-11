# GPT-5.5 Pro Review — claude-code-cache-warmer

- **Reviewer**: GPT-5.5 Pro (ChatGPT Pro, browser session)
- **Date**: 2026-06-11
- **Elapsed**: ~20 min reasoning. Note: the chatgpt-pro MCP's completion detector fired at 5m07s on an interim narration (376 chars) and closed its tab — the full review below was recovered by reopening the conversation via CDP and waiting for true completion.

---

Baseline check

The pricing premise in the README is broadly aligned with current Anthropic documentation: cache reads are priced at 0.1× base input tokens, 5-minute cache writes at 1.25×, and 1-hour cache writes at 2×. 
Claude API Docs
 The 1-hour cache duration is also now generally available in the Anthropic API docs. 
Claude API Docs
 For Claude Code deployments, Anthropic’s own docs still describe ENABLE_PROMPT_CACHING_1H=1 as the opt-in/request mechanism for 1-hour prompt-cache TTL. 
Claude API Docs
+1

That said: I would not ship this as a safe public installable tool yet. The fork idea is plausible, but the current implementation has at least two blocker-class problems: it can delete the wrong Claude session log, and the installed systemd service likely does not inherit the 1-hour cache environment the README tells users to put in their shell profile.

P0 blockers
P0 — Fork JSONL identification can delete a real user session log

Quoted lines:

Bash
# cache-warmer.sh:159-161
# Snapshot existing jsonls so the fork's new file is identifiable.
local before_list
before_list=$(ls -1 "$project_dir"/*.jsonl 2>/dev/null || true)
Bash
# cache-warmer.sh:203-210
# Identify the fork jsonl (new file in the project dir) and await its reply.
waited=0
local fork_jsonl="" usage=""
...
fork_jsonl=$(comm -13 <(printf '%s\n' "$before_list" | sort) \
                          <(ls -1 "$project_dir"/*.jsonl 2>/dev/null | sort) | head -1 || true)
Bash
# cache-warmer.sh:237-239
# The fork served its purpose; remove its jsonl so it never pollutes
# discovery or /resume listings.
[[ -n ${fork_jsonl:-} && -f ${fork_jsonl:-} ]] && rm -f "$fork_jsonl"

This is the most serious bug. The script decides “the fork log” by taking the first JSONL that appeared after a directory snapshot, then deletes it. That is not a safe identity proof.

Normal ways this can go wrong:

A user starts another Claude session in the same project while the warmer is running.

Claude Code itself creates another session/fork/compaction/session file.

Another tool writes a JSONL into the project dir.

The fork JSONL is not alphabetically first among new files.

A previous stale file appears because of sync/restore/rename behavior.

In those cases, head -1 can select a real session log. Then rm -f "$fork_jsonl" deletes user data. This is especially bad because the README promises “without modifying the sessions.”

Fix direction:

Use a per-run nonce in KEEPALIVE_TEXT, for example [cache-warmer keepalive run=<uuid>].

Identify the fork log only by parsing JSONL content and finding that exact nonce in a user message, followed by the assistant response whose usage is being measured.

Reject ambiguity. If zero or multiple files contain the nonce, do not delete anything.

Do not use head -1 as an identity decision.

Do not delete immediately. Move verified fork logs to ~/.cache/cache-warmer/forks/ first, or retain for audit with a cleanup TTL.

Before any deletion, validate: regular file, under the expected project dir, basename matches a strict Claude session UUID pattern, contains the nonce, and was created after the fork start.

This alone is enough to block public release.

P0 — The installed fork process probably does not request the 1-hour TTL

Quoted lines:

Markdown
# README.md:58-60
- The 1-hour extended cache TTL: `export ENABLE_PROMPT_CACHING_1H=1` in the
  shell profile that launches your Claude sessions. (Without it the default
  TTL is ~5 minutes and pre-expiry warming is not practical — a fork takes
INI
# install.sh:35-37
[Service]
Type=oneshot
ExecStart=$REPO_DIR/cache-warmer.sh
Bash
# cache-warmer.sh:165
"env -u CLAUDECODE -u CLAUDE_CODE_ENTRYPOINT -u CLAUDE_CODE_SSE_PORT claude --resume $sid --fork-session$flags"
Bash
# cache-warmer.sh:168
"env -u CLAUDECODE -u CLAUDE_CODE_ENTRYPOINT -u CLAUDE_CODE_SSE_PORT claude --resume $sid --fork-session$flags"

The README tells users to put ENABLE_PROMPT_CACHING_1H=1 in the shell profile that launches their normal Claude sessions. But the warmer fork is launched by a systemd user service, not by that interactive shell profile. The generated unit does not set Environment=ENABLE_PROMPT_CACHING_1H=1, and the tmux command does not set it either.

That creates a silent failure mode:

The live Claude session may have a 1-hour cache.

The fork launched by systemd may request the default 5-minute cache behavior.

The fork can still log a cache read, so the warmer records WARMED.

The script writes last_warm.

The next timer run skips because the state says the session is fresh.

But the fork’s refresh may only be useful for ~5 minutes, not the intended ~1 hour.

A user returning at minute 55 could still pay a full rewrite despite a recent WARMED log.

Anthropic’s Claude Code docs explicitly document ENABLE_PROMPT_CACHING_1H=1 as the way to request the 1-hour cache TTL in Claude Code provider environments. 
Claude API Docs
+1

Fix direction:

Add Environment=ENABLE_PROMPT_CACHING_1H=1 to the generated systemd unit, or make it an explicit config variable rendered into the unit.

At runtime, fail closed unless the fork environment has the expected cache TTL setting.

Log the fork environment cache mode on every warm attempt.

Consider reading /proc/$pid/environ for the live Claude process and safely replicating a strict allowlist of prefix-affecting env vars.

The README must say that both the live sessions and the warmer service/fork need the same cache TTL behavior.

P1 should-fix before public release
P1 — Usage verification is not tied to the keepalive turn

Quoted lines:

Python
Run
# cache-warmer.sh:113-130
# Usage of the LAST assistant message in a fork jsonl: "read creation input".
fork_last_usage() {
  python3 - "$1" <<'PY'
...
            if rec.get("type") == "assistant":
                u = (rec.get("message") or {}).get("usage") or {}
...
if u is not None:
    print(u.get("cache_read_input_tokens", 0), u.get("cache_creation_input_tokens", 0), u.get("input_tokens", 0))
Bash
# cache-warmer.sh:212-214
if [[ -n $fork_jsonl && -f $fork_jsonl ]]; then
  usage=$(fork_last_usage "$fork_jsonl" || true)
  [[ -n $usage ]] && break
fi

This reads the last assistant usage in whatever file was identified. It does not prove that the usage belongs to the cache-warmer keepalive.

If Claude Code’s fork JSONL contains copied prior transcript entries, fork_last_usage can return a historical assistant usage before the keepalive reply completes. If the JSONL identification race selects another session, it can read that session’s last assistant usage. If background title generation or another assistant-like record lands later, it can measure the wrong thing.

Fix direction:

Generate a unique nonce per warm.

Wait for a user record containing that nonce.

Then wait for the next assistant record after that nonce.

Use only that assistant record’s usage.

Record the fork session id and nonce in the log.

P1 — The script warms stale/unrelated sessions in any active project directory

Quoted lines:

Markdown
# README.md:84-85
Every 10 minutes, for every session jsonl in the project dirs of running
Claude TUI processes:
Bash
# cache-warmer.sh:327-332
cwd=$(readlink "/proc/$pid/cwd" 2>/dev/null || true)
[[ -n $cwd ]] || continue
project_dir="$HOME/.claude/projects/${cwd//\//-}"
[[ -d $project_dir ]] || continue
DIR_CWD[$project_dir]=$cwd
DIR_ARGS[$project_dir]=$args
Bash
# cache-warmer.sh:351-354
for project_dir in "${!DIR_CWD[@]}"; do
  mapfile -t candidates < <(ls -1 "$project_dir"/*.jsonl 2>/dev/null || true)
  for jsonl in "${candidates[@]}"; do
    process_candidate "$jsonl" "${DIR_CWD[$project_dir]}" "${DIR_ARGS[$project_dir]}"

The discovery model is too broad. If one Claude TUI is running in a project, the script considers every JSONL in that project directory. That can include old sessions, unrelated sessions, test sessions, forks, copied sessions, or sessions created by other Claude invocations.

This also becomes incorrect when multiple live Claude processes share a project directory but use different models, permission modes, environment, or flags. DIR_ARGS[$project_dir]=$args is “last process wins,” and then those args are used for every candidate JSONL in that project.

Impact:

Can spend quota warming sessions the user is not returning to.

Can cause prefix mismatches because the wrong live args are used.

Can blacklist sessions incorrectly.

Can contradict the user-facing “only while you’re plausibly coming back” cost story.

Fix direction:

Prefer only authoritative session IDs from live processes.

If the current session ID cannot be determined, skip rather than scanning the whole project directory.

If project-dir scanning remains as a fallback, make it opt-in and very loud in dry-run output.

Track active session identity via Claude Code env, argv, debug files, current JSONL append activity, or another reliable source rather than “all JSONLs in cwd’s project dir.”

P1 — Shell command construction is unsafe and underquoted

Quoted lines:

Bash
# cache-warmer.sh:139-147
local args=$1 out=""
[[ $args == *"--dangerously-skip-permissions"* ]] && out+=" --dangerously-skip-permissions"
if [[ $args =~ --model[[:space:]]+([^[:space:]]+) ]]; then
  out+=" --model ${BASH_REMATCH[1]}"
fi
if [[ $args =~ --permission-mode[[:space:]]+([^[:space:]]+) ]]; then
  out+=" --permission-mode ${BASH_REMATCH[1]}"
fi
echo "$out"
Bash
# cache-warmer.sh:165
"env -u CLAUDECODE -u CLAUDE_CODE_ENTRYPOINT -u CLAUDE_CODE_SSE_PORT claude --resume $sid --fork-session$flags"
Bash
# cache-warmer.sh:168
"env -u CLAUDECODE -u CLAUDE_CODE_ENTRYPOINT -u CLAUDE_CODE_SSE_PORT claude --resume $sid --fork-session$flags"

The command passed to tmux is a shell string. $sid and $flags are interpolated unquoted. replicated_flags extracts values from ps output and appends them as raw shell text.

Session IDs are expected to be UUID-ish, and model names are usually benign, but this is still not acceptable for a public tool that will be run every 10 minutes. A malformed JSONL filename, strange model value, future Claude flag syntax, or user-supplied config can turn into shell syntax.

Fix direction:

Validate sid with a strict regex before use, for example ^[0-9a-fA-F-]{20,}$ or whatever Claude actually guarantees.

Do not assemble a shell command by string concatenation.

Use a wrapper script generated with safely quoted argv, or use printf '%q' for every dynamic shell token.

Maintain flags as an array internally.

Replicate only validated flag values.

P1 — last_warm is written before the warm succeeds

Quoted lines:

Bash
# cache-warmer.sh:300-305
log "WARM sid=${sid:0:8} age=${age_min}m user-idle=${user_idle_min}m msgs=${user_count} (fork-resume, live session untouched)"
if (( DRY_RUN )); then
  return 0
fi
echo "$NOW" > "$state_file"
warm_by_fork "$sid" "$cwd" "$live_args" || true

This marks a session fresh before the fork has spawned, before the keepalive was sent, before a reply was received, and before cache usage was verified.

Impact:

A transient tmux/Claude failure can suppress retries for the warm window.

The script can believe a session is fresh when the cache was never refreshed.

The next real user message may pay the full cold-write cost.

The state should distinguish last_attempt from last_success.

Fix direction:

Write last_warm only after warm_by_fork returns success.

Use atomic state writes: tmp=$(mktemp) then mv.

Optionally keep last_attempt separately for short backoff.

Use date +%s at success time, not the single NOW from the start of a potentially long run.

P1 — Low cache_read is not necessarily a prefix mismatch; high cache_read is not proof of full correctness

Quoted lines:

Bash
# cache-warmer.sh:225-233
total=$(( c_read + c_create + c_in ))
if (( total > 0 && c_read * 2 >= total )); then
  log "RESULT sid=${sid:0:8} WARMED cache_read=$c_read cache_creation=$c_create (prefix refreshed)"
  rc=0
else
  # Prefix mismatch: the fork paid a full cache write and refreshed nothing.
  # Blacklist this sid so we never repeat the cost; loud log for diagnosis.
  log "RESULT sid=${sid:0:8} MISMATCH cache_read=$c_read cache_creation=$c_create — fork prefix did not match; blacklisting sid"
  touch "$STATE_DIR/${sid}.fork_mismatch"
Markdown
# README.md:98-101
Safety: the keepalive is typed only into the disposable fork, with
verify-then-commit (text confirmed intact in the input box before Enter); a
flock prevents overlapping runs; a session whose fork shows a prefix mismatch
(`cache_read` < 50%) is blacklisted so the cost is never paid twice.

cache_read < 50% can mean at least two different things:

The fork prefix did not match the live prefix.

The cache was already cold or had a shorter TTL than expected.

Those have different implications. If the prefix matched but was cold, the fork may have paid a full write and actually warmed the cache, just expensively. Blacklisting the session forever is the wrong response.

Conversely, cache_read >= 50% is too weak to prove that the full live session prefix was reproduced. It may only prove that a large stable system/tool prefix was cached while part of the conversation was re-created.

Fix direction:

Compare against an expected prefix token count from the live session’s recent assistant usage.

Classify results as verified_full_hit, partial_hit, cold_rewrite, mismatch, and unknown.

Treat one mismatch as a warning, not a permanent blacklist.

Add TTL to blacklist files or require repeated mismatches.

Do not say “prefix refreshed” unless the measured read is close to the expected live prefix size.

P1 — Startup cleanup can kill an unrelated tmux session

Quoted lines:

Bash
# cache-warmer.sh:308-312
# Kill any orphaned fork session left over from a crashed previous run.
if tmux has-session -t "$FORK_TMUX_SESSION" 2>/dev/null; then
  log "note: found leftover $FORK_TMUX_SESSION tmux session; killing it"
  tmux kill-session -t "$FORK_TMUX_SESSION" 2>/dev/null || true
fi

The session name is fixed:

Bash
# cache-warmer.sh:33
FORK_TMUX_SESSION="cache-warmer-forks"

If the user has a tmux session with that name, or if they attached to a previous warmer session and did anything useful in it, the next run kills it. Public tools should not unconditionally kill user tmux sessions by name.

Fix direction:

Use a unique name, for example cache-warmer-forks-$UID.

Set a tmux user option marker when creating the session, such as @cache-warmer-owner.

Before killing, verify the marker and maybe the command of panes.

Even better: create one fork session per run, with a nonce in the name, and clean only panes/windows recorded in the current state file.

P1 — Auto-accepting the folder-trust dialog is a security footgun

Quoted lines:

Bash
# cache-warmer.sh:180-182
# auto-accept the folder-trust dialog if it appears
if printf '%s\n' "$pane_txt" | grep -q "trust this folder"; then
  tmux send-keys -t "$win" Enter 2>/dev/null || true
Markdown
# README.md:135-136
- Works only for sessions launched from trusted directories (the fork
  auto-accepts the folder-trust dialog for dirs you've already trusted).

The code does not verify that the directory is already trusted. It just sends Enter if the phrase appears. That can turn a safety prompt into an automatic approval.

Even if Claude Code only shows this dialog for directories the user previously trusted, the script should not rely on UI text for a security decision. The safer behavior is to fail loudly and tell the user to manually trust the directory in Claude Code.

Fix direction:

Remove auto-accept.

If trust UI appears, kill the fork and log FAIL ... directory trust prompt appeared.

Document the manual fix.

Only proceed when trust can be verified from a stable Claude Code trust store, if such a store exists.

P1 — No signal trap means forks can run after the parent exits

Quoted lines:

Bash
# cache-warmer.sh:163-168
if tmux has-session -t "$FORK_TMUX_SESSION" 2>/dev/null; then
  tmux new-window -d -t "$FORK_TMUX_SESSION" -n "w$$-${sid:0:8}" -c "$cwd" \
    "env -u CLAUDECODE -u CLAUDE_CODE_ENTRYPOINT -u CLAUDE_CODE_SSE_PORT claude --resume $sid --fork-session$flags"
else
  tmux new-session -d -s "$FORK_TMUX_SESSION" -n "w$$-${sid:0:8}" -c "$cwd" \
Bash
# cache-warmer.sh:218
tmux kill-window -t "$win" 2>/dev/null || true

Cleanup happens only on the normal path. If the script is killed by systemd, logout, reboot, SIGTERM, or an unhandled shell error, the fork tmux pane can survive. The next run tries to kill the whole fixed-name session, but that is a delayed and blunt cleanup strategy.

Fix direction:

Install a trap immediately after creating a fork window.

Track current fork target in a variable.

On EXIT, INT, TERM, and HUP, kill only that verified window.

Do not rely on the next timer run.

P1 — Install enables an active spending tool before measurement/tuning

Quoted lines:

Bash
# config.example:4-5
# Master switch. 0 = script exits immediately (timer keeps firing but does nothing).
ENABLED=1
Bash
# install.sh:24-27
if [[ ! -f "$REPO_DIR/config" ]]; then
  cp "$REPO_DIR/config.example" "$REPO_DIR/config"
  echo "Created $REPO_DIR/config from config.example (ENABLED=1 by default — edit to tune)."
fi
Bash
# install.sh:59-60
systemctl --user daemon-reload
systemctl --user enable --now cache-warmer.timer
Markdown
# README.md:71-80
Verify your actual cache TTL first (uses your existing session history; costs
nothing):
...
Look for the gap bucket where the median cache-hit ratio collapses to ~0% —
that's your expiry cliff. The default warm window (45–58 min) assumes a ~60-min
cliff; tune `WARM_MIN_AGE`/`WARM_MAX_AGE` in `config` if yours differs.

The README says users should verify TTL first, but the install path creates an enabled config and starts the timer immediately.

Fix direction:

Make config.example default to ENABLED=0.

Make install create the timer but not start it until the user runs measure-ttl.py and --dry-run.

Add ./install.sh --enable or a separate explicit enable step.

At minimum, ask the user to edit config before enabling.

P1 — systemd PATH and repo paths are fragile

Quoted lines:

Bash
# install.sh:20-21
for dep in tmux python3 claude; do
  command -v "$dep" >/dev/null || { echo "ERROR: '$dep' not found in PATH" >&2; exit 1; }
INI
# install.sh:37
ExecStart=$REPO_DIR/cache-warmer.sh

The dependency check runs in the installer’s interactive shell, but the service runs in systemd’s user-service environment. Those PATHs often differ. claude installed via npm, pnpm, mise, asdf, Homebrew-on-Linux, or a shell profile may be visible in the terminal but invisible to systemd.

Also, ExecStart=$REPO_DIR/cache-warmer.sh is not escaped for spaces or systemd-special characters in the repository path.

Fix direction:

Resolve absolute paths during install: CLAUDE_BIN=$(command -v claude), TMUX_BIN=$(command -v tmux), PYTHON_BIN=$(command -v python3).

Write those into config or the unit.

Escape ExecStart correctly or call /usr/bin/env bash with a safely escaped script path.

Add an install-time check that systemctl --user show-environment contains the required env and PATH.

P1 — TUI readiness and input verification are too brittle for a quota-spending tool

Quoted lines:

Bash
# cache-warmer.sh:177-179
# NB: the empty input line is "❯" + U+00A0 (no-break space), which
# [[:space:]] does not match — include the literal NBSP in the bracket.
if printf '%s\n' "$pane_txt" | grep -qE $'^❯[ \t ]*$'; then ready=1; break; fi
Bash
# cache-warmer.sh:193-197
# Verify-then-commit the keepalive into OUR fork pane.
tmux send-keys -t "$win" -l "$KEEPALIVE_TEXT"
sleep 0.5
if ! tmux capture-pane -t "$win" -p 2>/dev/null | grep -qF 'cache-warmer keepalive'; then
Markdown
# README.md:126-130
- **TUI coupling**: readiness detection reads the fork's tmux pane. Claude
  Code TUI renders change between versions (e.g. the empty input line is `❯`
  followed by a no-break space, which `[[:space:]]` does not match). If a
  Claude Code update breaks detection, warms fail loudly (`FAIL` log lines)
  and cost nothing — they don't misfire into your sessions.

The README acknowledges this is TUI-coupled, but the current verification is weaker than the docs imply. The grep checks the whole captured pane, not the input box. If the marker appears in the transcript, status area, previous content, or wrapped text, verification can pass even if the text was not actually staged in the input box.

Also, “cost nothing” is too strong. A readiness failure before Enter probably costs nothing, but a render change after send, an unexpected key mode, or a wrong parsed fork log can still create an API request or a full cache write.

Fix direction:

Stop using screen scrape as the source of truth.

Use a pseudo-terminal wrapper plus JSONL marker detection.

Treat tmux as a process sandbox only, not a UI parser.

If screen scraping remains, verify the marker appears on the actual prompt line, not anywhere in the pane.

P1 — Prefix-affecting live environment and flags are under-replicated

Quoted lines:

Bash
# cache-warmer.sh:134-137
# Replicate only prefix-relevant flags from the live process's cmdline. The
# fork's system prompt must reconstruct identically or the cache misses; the
# permission mode is part of that. Deliberately NOT replicated: --remote-control
# (engages RC needlessly), --resume/--continue (we supply our own).
Bash
# cache-warmer.sh:140-145
[[ $args == *"--dangerously-skip-permissions"* ]] && out+=" --dangerously-skip-permissions"
if [[ $args =~ --model[[:space:]]+([^[:space:]]+) ]]; then
  out+=" --model ${BASH_REMATCH[1]}"
fi
if [[ $args =~ --permission-mode[[:space:]]+([^[:space:]]+) ]]; then

The code assumes only a few flags matter. In practice, the prompt prefix can be affected by model/provider env, settings files, MCP/tool configuration, add-dir behavior, permission mode, feature flags, tool-search behavior, project trust, CLAUDE.md, and provider-specific configuration. The 1-hour TTL env issue is the most obvious example, but not the only one.

Fix direction:

Document a strict compatibility matrix.

Replicate a safe allowlist of env vars from /proc/$pid/environ.

Include a “prefix config hash” in logs if possible.

Fail closed when live process configuration cannot be reproduced.

Do not claim “identical prefix” as a general guarantee unless the tool can verify it.

P2 nice-to-have / robustness / documentation
P2 — user_activity parsing is brittle and can silently skip valid sessions

Quoted lines:

Python
Run
# cache-warmer.sh:85
if '"type":"user"' not in line and '"type": "user"' not in line:
    continue
Python
Run
# cache-warmer.sh:91-108
if rec.get("type") != "user" or rec.get("isMeta") or "toolUseResult" in rec:
    continue
...
ts = rec.get("timestamp")
if ts:
    last, count = ts, count + 1
...
if last:
    epoch = int(datetime.datetime.fromisoformat(last.replace("Z", "+00:00")).timestamp())

This depends on exact JSON formatting before parsing JSON. It misses valid JSON with different spacing or key order. Timestamp parsing happens after the broad try, so a malformed last timestamp can crash the Python snippet and cause the shell to treat activity as empty.

Fix direction:

Remove the string prefilter.

Parse JSON first.

Catch timestamp parsing errors per record.

Keep the latest valid timestamp rather than the last syntactic record.

Add fixtures for Claude Code JSONL variants.

P2 — Corrupt state files can kill the whole run under set -u

Quoted lines:

Bash
# cache-warmer.sh:271-273
[[ -f $state_file ]] && last_warm=$(cat "$state_file" 2>/dev/null || echo 0)
fresh=$(( mtime > last_warm ? mtime : last_warm ))
age_min=$(( (NOW - fresh) / 60 ))

If ~/.cache/cache-warmer/<sid>.last_warm contains abc, Bash arithmetic with set -u can error out. A partial write, manual edit, or sync corruption can stop all warming.

Fix direction:

Validate with [[ $last_warm =~ ^[0-9]+$ ]] || last_warm=0.

Write state atomically.

Log and quarantine corrupt state.

P2 — measure-ttl.py can mix incompatible populations

Quoted lines:

Python
Run
# measure-ttl.py:36-40
files = sorted(
    glob.glob(os.path.expanduser("~/.claude/projects/*/*.jsonl")),
    key=os.path.getmtime,
    reverse=True,
)[:max_files]
Python
Run
# measure-ttl.py:60-64
total = cr + cc + it
if prev_ts is not None and total > MIN_PREFIX_TOKENS:
    gap_min = (t - prev_ts).total_seconds() / 60
    if gap_min > 0.5:
        rows.append((gap_min, cr / total))

The script buckets all recent sessions together. That can mix different Claude versions, providers, models, TTL settings, fork logs, and experiments. The output may still be useful, but it should be described as a heuristic, not a precise TTL measurement.

Fix direction:

Group by model/provider if available.

Exclude cache-warmer fork logs by nonce or metadata.

Show sample counts and confidence warnings.

Warn when samples are too sparse.

Add --since, --model, and --project filters.

P2 — GNU/Linux assumptions are broader than the docs/checks admit

Quoted lines:

Bash
# cache-warmer.sh:69-70
exec 9>"$STATE_DIR/run.lock"
if ! flock -n 9; then
Bash
# cache-warmer.sh:268
mtime=$(stat -c %Y "$jsonl")
Bash
# cache-warmer.sh:327
cwd=$(readlink "/proc/$pid/cwd" 2>/dev/null || true)
Bash
# cache-warmer.sh:341
done < <(ps -eo pid=,tty=,comm=,args= --no-headers | awk ...

The README says Linux with systemd and tmux, but the script also assumes GNU stat, GNU-ish ps, /proc, flock, Bash 4 associative arrays, and a Claude process whose comm is exactly claude.

Fix direction:

Add dependency checks for flock, GNU stat, Bash version, and /proc.

Say “GNU/Linux with systemd user services” rather than just “Linux.”

Mention unsupported environments: macOS, WSL variants unless tested, BusyBox/Alpine minimal systems, containers without user systemd.

P2 — README sample contradicts the configured warm window

Quoted lines:

Markdown
# README.md:11
[12:44:20] WARM sid=710b813c age=11m user-idle=12m msgs=3 (fork-resume, live session untouched)
Markdown
# README.md:89
| Cache freshness 45–58 min | `WARM_MIN_AGE`/`WARM_MAX_AGE` | younger = still warm; older = already cold (re-warming would pay a full write for a session nobody may resume) |

A WARM age=11m line should not happen under the default 45–58 minute gate. This is small, but it undermines trust in the examples.

Fix direction:

Use an example with age=50m, or explain if the sample is from a non-default config.

P2 — README overclaims what the receipts prove

Quoted lines:

Markdown
# README.md:15-16
Every warm logs a `RESULT` line with the measured `cache_read` token count from
the API's own usage accounting — ground-truth proof the warm worked.
Markdown
# README.md:49-52
The interactive fork is the only mechanism found that reproduces the exact
prefix (verified: a fork's keepalive turn read 100% of the live session's
prefix from cache) while leaving the original session untouched (verified:
byte-identical session file before/after).

The cache_read number proves that some prefix was read from cache for some request. It does not, by itself, prove the live session’s exact prefix was reproduced, that the 1-hour TTL was refreshed, or that the next live turn will hit hot cache.

Fix direction:

Rephrase to “evidence” or “receipt,” not “ground-truth proof.”

Publish the empirical methodology: Claude Code version, provider, model, env, before/after hashes, transcript hash comparison, sample JSONL usage lines, and failure cases.

Say “observed on v2.1.173” rather than implying a stable invariant.

P2 — Deleting fork logs removes the audit trail

Quoted lines:

Markdown
# README.md:133-134
- The keepalive instructs the fork to reply with a bare "ok"; the fork's
  jsonl is deleted afterward, so `/resume` listings stay clean.
Bash
# cache-warmer.sh:237-239
# discovery or /resume listings.
[[ -n ${fork_jsonl:-} && -f ${fork_jsonl:-} ]] && rm -f "$fork_jsonl"

For a tool whose core safety story depends on measured usage receipts, deleting the underlying log immediately is not ideal. It also makes incident diagnosis harder.

Fix direction:

Move fork logs to ~/.cache/cache-warmer/forks/ with restricted permissions.

Keep them for a short retention period.

Provide cache-warmer cleanup if /resume pollution matters.

At minimum, archive the relevant usage record in a structured receipt file before deletion.

P2 — install.sh --uninstall can fail on non-working user systemd

Quoted lines:

Bash
# install.sh:12-16
if [[ ${1:-} == --uninstall ]]; then
  systemctl --user disable --now cache-warmer.timer 2>/dev/null || true
  rm -f "$UNIT_DIR/cache-warmer.service" "$UNIT_DIR/cache-warmer.timer"
  systemctl --user daemon-reload
  echo "cache-warmer timer removed."

The first systemctl is guarded, but daemon-reload is not. On systems without a working user bus, uninstall can exit after removing files but before printing success.

Fix direction:

Guard daemon-reload too, or print a clear warning.

Check systemctl --user availability during install and uninstall.

P2 — Config is executable shell code but docs present it like data

Quoted lines:

Bash
# cache-warmer.sh:49
[[ -f $CONFIG_FILE ]] && source "$CONFIG_FILE"
Bash
# config.example:1-2
# cache-warmer configuration
# Copy to `config` next to cache-warmer.sh and edit. Sourced on every run.

The comment says “Sourced,” but most users will still treat config as a data file. Since it is executed every 10 minutes, any compromise or accidental shell syntax in config becomes code execution.

Fix direction:

Either parse KEY=value data manually, or make the README explicitly warn: “config is shell code.”

Keep the config file mode private: chmod 600 config.

Reject unsafe variable names and unexpected lines if using a parser.

Design critique

The fork mechanism is clever and may be the least-bad available workaround if Claude Code offers no official “refresh prompt cache without transcript mutation” command. But in its current form it depends on several unstable internals at once: Claude Code’s TUI rendering, --fork-session behavior, JSONL schema, process argv shape, project-dir naming, systemd environment, and tmux behavior.

The strongest design improvement would be to stop treating tmux screen text and directory diffs as authoritative. The durable source of truth should be the fork JSONL content, with a unique nonce, parsed causally: nonce user message → following assistant usage → measured cache hit. Even then, the tool needs to reproduce the live environment and args much more faithfully.

The ideal upstream alternative would be a Claude Code command like:

Bash
claude --resume <sid> --fork-session --no-transcript --message '[keepalive]' --print-usage-json

or an official claude cache warm <sid> that serializes the same prefix Claude Code would use for the next interactive turn, sends a minimal request, returns usage, and does not add a transcript entry. Until something like that exists, this tool should present itself as experimental and opt-in, not “safe by default.”

Packaging/docs gaps

The public repo currently shows only .gitignore, LICENSE, README.md, cache-warmer.sh, config.example, install.sh, and measure-ttl.py. 
GitHub
 For a quota-spending tool that manipulates tmux and deletes Claude session logs, I would add before wider release:

SECURITY.md with threat model, responsible disclosure, and explicit “do not run in untrusted multi-user environments” language.

A CHANGELOG.md and version tags.

A test suite with JSONL fixtures for user activity, fork usage parsing, malformed JSON, mixed tool results, and copied fork transcripts.

Shell tests for path spaces, invalid state files, stale tmux sessions, and ambiguous fork JSONLs.

CI running shellcheck, shfmt, and the Python tests.

A compatibility matrix: distro, Bash version, tmux version, Claude Code version, provider, model, and whether ENABLE_PROMPT_CACHING_1H was verified in both live and fork environments.

A “dry-run first” install flow.

A documented cleanup command for state, fork logs, and mismatch blacklists.

Overall verdict

Not safe and not quite honest enough for public “install and run” use right now.

As a personal experimental script by someone who understands the internals and watches the logs, the idea is promising. As a public tool, the current version has blocker issues:

It can delete the wrong JSONL session log.

It likely does not propagate the 1-hour TTL env into the systemd-launched fork.

It can warm unrelated/stale sessions in the same project directory.

It treats weak cache-read evidence as proof of exact prefix refresh.

It auto-accepts a trust prompt.

It enables itself immediately by default.

I would publish only after changing the default to disabled, removing automatic JSONL deletion, proving fork identity with a nonce, passing/validating the 1-hour cache env, limiting candidates to known active session IDs, and downgrading the README claims from guarantees to versioned empirical observations.