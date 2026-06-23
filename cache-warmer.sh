#!/usr/bin/env bash
# Keep long Claude Code contexts warm in the Anthropic prompt cache — WITHOUT
# touching the live sessions. For each idle session nearing cache expiry,
# spawn a disposable FORK (`claude --resume <sid> --fork-session`) in a hidden
# tmux window, send a nonce-tagged keepalive there, verify the cache hit from
# the fork's own usage record, then archive the fork. The fork's API request
# carries the live session's prefix, so reading it re-arms the cache TTL; the
# live session's transcript is never modified (observed byte-identical on
# Claude Code v2.1.173, 2026-06-11).
#
# Designed for the 1-hour extended prompt-cache TTL. The fork environment
# sets ENABLE_PROMPT_CACHING_1H=1 explicitly; your live sessions need it too
# (shell profile). Measure your effective TTL with measure-ttl.py and tune
# WARM_MIN_AGE/WARM_MAX_AGE accordingly. See README.md.
#
# Candidates: every session jsonl in the project dirs of currently-running
# Claude TUI processes, gated by warm window, ≥MIN_USER_MSGS real user
# messages (filters one-shot `claude -p` cron sessions), and user-idle bound.
#
# Usage:
#   cache-warmer.sh            # normal run (systemd timer entry point)
#   cache-warmer.sh --dry-run  # log decisions, spawn nothing
#
# Every warm logs a RESULT line with the measured cache_read tokens — the
# evidence receipt for that warm (cache_read ≈ full request = prefix served
# from cache). Fork transcripts are archived under ~/.cache/cache-warmer/forks/
# for audit (7-day retention), never deleted on the spot.

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
CONFIG_FILE="$SCRIPT_DIR/config"
LIB_DIR="$SCRIPT_DIR/lib"
JSONL_PY="$LIB_DIR/jsonl.py"   # JSONL transcript parsers (see lib/jsonl.py)
# Pure warm-result classifier, extracted for unit testing (see lib/classify.sh).
# shellcheck source=lib/classify.sh
source "$LIB_DIR/classify.sh"
LOG_DIR="$HOME/.claude/logs"
LOG_FILE="$LOG_DIR/cache-warmer.log"
STATE_DIR="$HOME/.cache/cache-warmer"
FORK_ARCHIVE_DIR="$STATE_DIR/forks"
RECEIPTS_FILE="$STATE_DIR/receipts.jsonl"   # structured per-warm receipts (jsonl)
FORK_TMUX_SESSION="cache-warmer-forks-$(id -u)"
UUID_RE='^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
SAFE_VALUE_RE='^[A-Za-z0-9._-]+$'
mkdir -p "$LOG_DIR" "$STATE_DIR" "$FORK_ARCHIVE_DIR"

# Defaults; config overrides.
ENABLED=0
WARM_MIN_AGE=45
WARM_MAX_AGE=58
MAX_USER_IDLE_MIN=240
MIN_USER_MSGS=2
RATELIMIT_MIN=30
MISMATCH_COOLDOWN_DAYS=3   # blacklist a repeatedly-mismatching sid for this long, then retry
WARM_BYPASS_SESSIONS=1     # warm sessions launched with --dangerously-skip-permissions? (see README "Armed forks")
EXCLUDE_SIDS=''
INCLUDE_ONLY_SIDS=''
KEEPALIVE_TEXT='[cache-warmer keepalive] Automated cache keepalive. Do NOT take any action, run any tool, or continue prior work. Reply with exactly: ok'
FORK_SPAWN_TIMEOUT=180   # seconds to wait for the fork TUI's input prompt (huge sessions take >60s to restore)
FORK_REPLY_TIMEOUT=120   # seconds to wait for the fork's keepalive turn
FORK_RETENTION_DAYS=7    # archived fork transcripts older than this are pruned
# shellcheck disable=SC1090
[[ -f $CONFIG_FILE ]] && source "$CONFIG_FILE"

# Validate config: numeric knobs must be integers; regexes must compile; the
# keepalive must be single-line and carry the marker (used to exclude forks).
for _n in WARM_MIN_AGE WARM_MAX_AGE MAX_USER_IDLE_MIN MIN_USER_MSGS RATELIMIT_MIN \
          MISMATCH_COOLDOWN_DAYS FORK_SPAWN_TIMEOUT FORK_REPLY_TIMEOUT FORK_RETENTION_DAYS; do
  [[ ${!_n} =~ ^[0-9]+$ ]] || { echo "config error: $_n must be an integer (got '${!_n}')" >&2; exit 2; }
done
for _re in EXCLUDE_SIDS INCLUDE_ONLY_SIDS; do
  # A malformed regex makes =~ return status 2; a valid regex that simply
  # doesn't match returns 1. Only status 2 is a config error. The `|| _st=$?`
  # both captures the status and keeps set -e from firing on the no-match case.
  if [[ -n ${!_re} ]]; then
    _st=0
    # SC2319: capturing the [[ ]] regex-compile status is exactly the intent —
    # status 2 means the regex itself is invalid (vs 1 = valid but no match).
    # shellcheck disable=SC2319
    [[ "x" =~ ${!_re} ]] || _st=$?
    (( _st >= 2 )) && { echo "config error: $_re is not a valid regex" >&2; exit 2; }
  fi
done
[[ $KEEPALIVE_TEXT == *$'\n'* ]] && { echo "config error: KEEPALIVE_TEXT must be single-line" >&2; exit 2; }
[[ $KEEPALIVE_TEXT == *'[cache-warmer keepalive]'* ]] || { echo "config error: KEEPALIVE_TEXT must contain the '[cache-warmer keepalive]' marker (fork-exclusion depends on it)" >&2; exit 2; }

DRY_RUN=0
case "${1:-}" in
  --dry-run) DRY_RUN=1 ;;
  --help|-h) sed -n '2,27p' "$0"; exit 0 ;;
  "") ;;
  *) echo "unknown argument: $1 (use --dry-run or --help)" >&2; exit 2 ;;
esac

log() {
  local tag=""
  (( DRY_RUN )) && tag=" [dry-run]"
  echo "[$(date '+%Y-%m-%d %H:%M:%S')]${tag} $*" >> "$LOG_FILE"
}

# Read a state file that must contain an integer; corrupt -> 0.
read_int_state() {
  local f=$1 v=0
  [[ -f $f ]] && v=$(cat "$f" 2>/dev/null || echo 0)
  [[ $v =~ ^[0-9]+$ ]] || v=0
  echo "$v"
}

# Atomic state write.
write_state() {
  local f=$1 v=$2 tmp
  tmp=$(mktemp "$STATE_DIR/.tmp.XXXXXX")
  printf '%s\n' "$v" > "$tmp" && mv "$tmp" "$f"
}

# Append a structured per-warm JSON receipt (one object per line) to
# RECEIPTS_FILE. Args: sid nonce outcome class cache_read cache_creation
# input_tokens expected. Built with jq so values are always valid JSON (no
# string-concatenation). Numeric fields default to 0; non-integers are coerced.
# Never aborts the run on failure — a receipt is an audit aid, not load-bearing.
write_receipt() {
  local sid=$1 nonce=$2 outcome=$3 klass=$4 c_read=${5:-0} c_create=${6:-0} c_in=${7:-0} expected=${8:-0}
  for _v in c_read c_create c_in expected; do
    [[ ${!_v} =~ ^[0-9]+$ ]] || printf -v "$_v" '%s' 0
  done
  jq -cn \
    --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg sid "$sid" \
    --arg nonce "$nonce" \
    --arg outcome "$outcome" \
    --arg class "$klass" \
    --argjson cache_read "$c_read" \
    --argjson cache_creation "$c_create" \
    --argjson input_tokens "$c_in" \
    --argjson expected "$expected" \
    '{timestamp:$ts, sid:$sid, nonce:$nonce, outcome:$outcome, class:$class,
      cache_read:$cache_read, cache_creation:$cache_creation,
      input_tokens:$input_tokens, expected:$expected}' \
    >> "$RECEIPTS_FILE" 2>/dev/null || log "note: sid=${sid:0:8} could not append receipt"
}

if [[ ${ENABLED:-0} != 1 ]]; then
  exit 0
fi

# Single-instance lock: a run warming several large sessions can outlast the
# 10-min timer interval; overlapping runs would fight over fork windows.
exec 9>"$STATE_DIR/run.lock"
if ! flock -n 9; then
  log "skip run: another instance holds the lock"
  exit 0
fi

# Kill the current fork window if the script dies mid-warm (systemd stop,
# logout, error) instead of leaving an orphaned Claude process running.
CURRENT_WIN=""
cleanup_current_win() {
  [[ -n $CURRENT_WIN ]] && tmux kill-window -t "$CURRENT_WIN" 2>/dev/null || true
}
trap cleanup_current_win EXIT INT TERM HUP

# Last real-user-message epoch + count for a session jsonl. Real = type=user,
# not a tool result, not meta, not a keepalive. Prints "epoch count".
# (Logic in lib/jsonl.py so it can be unit tested against fixtures.)
user_activity() {
  python3 "$JSONL_PY" user-activity "$1"
}

# Usage of the assistant turn that ANSWERS our nonce-tagged keepalive.
# Prints "read creation input" only when that causal pair exists.
fork_usage_for_nonce() {
  python3 "$JSONL_PY" fork-usage "$1" "$2"
}

# Deterministic submit proof (BACKLOG cw-2): a real user record carrying the
# nonce means Claude Code accepted the keepalive as a turn — independent of any
# TUI rendering. Exit 0 if confirmed, 1 otherwise.
submit_confirmed() {
  python3 "$JSONL_PY" submit-confirmed "$1" "$2"
}

# Expected prefix size (tokens) = total input of the LIVE session's last
# assistant turn AFTER the most recent compaction boundary. Used as the
# denominator to classify fork warm results.
#
# Compaction-aware (see BACKLOG "Compaction-aware baseline"): when Claude Code
# compacts, it writes an `isCompactSummary` user record and the prefix collapses
# from the full history (~160k+) to the compaction summary (~60-80k). A fork
# resuming a just-compacted session replays the SMALL compacted prefix. If we
# kept the last PRE-compaction assistant turn as the baseline, that small fork
# request would be mis-flagged `short_request` (request*2 < expected) and struck
# unfairly. So we reset the baseline at every compaction boundary: only
# post-compaction assistant turns count. If the session was compacted but has no
# post-compaction assistant turn with usage yet, exp stays 0 → the classifier
# falls back to the request-relative check (no false strike).
live_expected_tokens() {
  python3 "$JSONL_PY" expected-tokens "$1"
}

# Flags that change the prompt prefix but that we do NOT replicate. If a live
# session was launched with any of these, the fork's prefix would diverge and
# the warm would pay a full cache write to discover it — so we skip instead
# (see prefix_unreplicable). --model and --permission-mode ARE replicated.
PREFIX_AFFECTING_UNREPLICATED='--append-system-prompt|--system-prompt|--settings|--add-dir|--agents?|--mcp-config|--strict-mcp-config|--allowed-?[Tt]ools|--disallowed-?[Tt]ools|--betas?'

# True if the live args contain a prefix-affecting flag we can't reproduce.
prefix_unreplicable() {
  [[ $1 =~ $PREFIX_AFFECTING_UNREPLICATED ]]
}

# Replicate only prefix-relevant, value-validated flags from the live
# process's cmdline. The fork's system prompt must reconstruct identically or
# the cache misses; permission mode is part of that. Handles both space and
# '=' flag forms. Deliberately NOT replicated: --remote-control,
# --resume/--continue (we supply our own).
replicated_flags() {
  local args=$1 out=""
  [[ $args == *"--dangerously-skip-permissions"* ]] && out+=" --dangerously-skip-permissions"
  if [[ $args =~ --model[[:space:]=]+([^[:space:]]+) ]] && [[ ${BASH_REMATCH[1]} =~ $SAFE_VALUE_RE ]]; then
    out+=" --model ${BASH_REMATCH[1]}"
  fi
  if [[ $args =~ --permission-mode[[:space:]=]+([^[:space:]]+) ]] && [[ ${BASH_REMATCH[1]} =~ $SAFE_VALUE_RE ]]; then
    out+=" --permission-mode ${BASH_REMATCH[1]}"
  fi
  echo "$out"
}

# Env vars that change the prompt prefix (model selection, system-prompt
# behavior, cache TTL). A fork that doesn't replicate the live session's value
# for these builds a different prefix and misses the cache. We read them from
# the LIVE process's /proc/<pid>/environ and replay them into the fork — an
# allowlist, never the whole environment (replaying secrets/PATH/etc. is both
# unsafe and prefix-irrelevant). Anchored, exact names only.
PREFIX_AFFECTING_ENV_RE='^(ANTHROPIC_MODEL|ANTHROPIC_SMALL_FAST_MODEL|ANTHROPIC_DEFAULT_HAIKU_MODEL|ANTHROPIC_DEFAULT_SONNET_MODEL|ANTHROPIC_DEFAULT_OPUS_MODEL|CLAUDE_CODE_SUBAGENT_MODEL|ENABLE_PROMPT_CACHING_1H|CLAUDE_CODE_MAX_OUTPUT_TOKENS|MAX_THINKING_TOKENS|CLAUDE_CODE_SIMPLE|DISABLE_PROMPT_CACHING)$'

# Read the allowlisted prefix-affecting env vars from a live pid's environ and
# emit them as `env`-ready, shell-quoted KEY=VALUE tokens (printf %q). Values
# are passed through %q so a value with spaces/metacharacters survives the
# shell string the fork is spawned through. Prints nothing if the pid is gone.
replicated_env() {
  local pid=$1
  [[ $pid =~ ^[0-9]+$ ]] || return 0
  local environ="/proc/$pid/environ"
  [[ -r $environ ]] || return 0
  local kv name val out=""
  while IFS= read -r -d '' kv; do
    name=${kv%%=*}
    [[ $name == "$kv" ]] && continue          # no '=' → not a real var
    [[ $name =~ $PREFIX_AFFECTING_ENV_RE ]] || continue
    val=${kv#*=}
    out+=" $(printf '%s=%q' "$name" "$val")"
  done < "$environ"
  echo "$out"
}

# Fingerprint of the `claude` binary: "version|mtime". A binary update shifts
# the system-prompt prefix (observed across 2.1.173→174), so a fork built with
# a newer binary than the one that wrote the live cache would diverge. Recorded
# at discovery; compared against the warm baseline to skip on drift.
claude_binary_fingerprint() {
  local bin ver="" mt=""
  bin=$(command -v claude 2>/dev/null) || { echo "unknown"; return 0; }
  bin=$(readlink -f "$bin" 2>/dev/null || echo "$bin")
  mt=$(stat -c %Y "$bin" 2>/dev/null || echo 0)
  # `claude --version` is the authoritative prefix-affecting identity; mtime is
  # a cheap fallback that also catches same-version rebuilds. Strip whitespace.
  ver=$(claude --version 2>/dev/null | tr -d '[:space:]' || true)
  echo "${ver:-noversion}|${mt:-0}"
}

# Warm one session by fork. Args: sid, cwd, live_args, live_jsonl, live_pid,
# live_env. Returns 0 on verified warm, 1 otherwise. Logs RESULT/FAIL itself.
warm_by_fork() {
  local sid=$1 cwd=$2 live_args=$3 live_jsonl=$4 live_pid=${5:-} live_env=${6:-}
  # Derive the project dir from the live jsonl itself — Claude Code mangles
  # more than just '/' in the cwd→dir mapping (e.g. '.' also becomes '-'), so
  # recomputing it from cwd is unreliable. The fork's jsonl lands beside the
  # live one, so dirname is correct by construction.
  local project_dir
  project_dir=$(dirname "$live_jsonl")
  local flags win rc=1 nonce spawn_epoch pane_pid=""
  [[ $sid =~ $UUID_RE ]] || { log "FAIL sid=${sid:0:8}: not a valid session UUID, refusing to fork"; return 1; }
  flags=$(replicated_flags "$live_args")
  nonce=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || date +%s%N)
  local keepalive="$KEEPALIVE_TEXT [run=${nonce}]"
  win="$FORK_TMUX_SESSION:w$$-${sid:0:8}"
  spawn_epoch=$(date +%s)

  # Replicate the live session's prefix-affecting env (allowlist from
  # /proc/<pid>/environ) so the fork's prompt prefix reconstructs identically.
  # If the live process is gone or set none, fall back to ENABLE_PROMPT_CACHING_1H=1
  # only — the cache TTL the warm window assumes. systemd user services do not
  # source shell profiles, so the cache-TTL var must be set explicitly here.
  local repl_env
  repl_env=$(replicated_env "$live_pid")
  [[ -n $live_env ]] && repl_env="$live_env"   # caller-captured snapshot wins (pid may be gone now)
  [[ $repl_env == *"ENABLE_PROMPT_CACHING_1H="* ]] || repl_env+=" ENABLE_PROMPT_CACHING_1H=1"
  local spawn_cmd
  spawn_cmd="env -u CLAUDECODE -u CLAUDE_CODE_ENTRYPOINT -u CLAUDE_CODE_SSE_PORT$repl_env claude --resume $sid --fork-session$flags"
  log "note: sid=${sid:0:8} fork env:${repl_env}"

  if tmux has-session -t "=$FORK_TMUX_SESSION" 2>/dev/null; then
    tmux new-window -d -t "=$FORK_TMUX_SESSION" -n "w$$-${sid:0:8}" -c "$cwd" "$spawn_cmd"
  else
    tmux new-session -d -s "$FORK_TMUX_SESSION" -n "w$$-${sid:0:8}" -c "$cwd" "$spawn_cmd"
  fi
  CURRENT_WIN="$win"
  # Pin the window name and capture the pane PID so cleanup/exit-wait track the
  # process, not a name a rename-on config could change out from under us.
  tmux set-window-option -t "$win" automatic-rename off 2>/dev/null || true
  tmux set-window-option -t "$win" allow-rename off 2>/dev/null || true
  pane_pid=$(tmux list-panes -t "$win" -F '#{pane_pid}' 2>/dev/null | head -1 || true)

  # Wait for the fork TUI's empty input prompt. Large sessions take minutes
  # to restore; that's fine, the slow path is exactly the valuable one. Along
  # the way, dismiss startup prompts that must be answered to preserve the live
  # prefix (resume-from-summary, MCP approval) — otherwise the fork never
  # reaches the input line and times out.
  local waited=0 pane_txt="" ready=0 handled_summary=0 handled_mcp=0
  while (( waited < FORK_SPAWN_TIMEOUT )); do
    sleep 5; waited=$((waited+5))
    pane_txt=$(tmux capture-pane -t "$win" -p 2>/dev/null || true)
    # NB: the empty input line is "❯" + U+00A0 (no-break space), which
    # [[:space:]] does not match — use the \u00a0 escape (a literal NBSP
    # char gets silently normalized to a plain space by some editors).
    if printf '%s\n' "$pane_txt" | grep -qE $'^❯[ \t\u00a0]*$'; then ready=1; break; fi
    # A folder-trust prompt is a security decision — never auto-accept it.
    if printf '%s\n' "$pane_txt" | grep -q "trust this folder"; then
      log "FAIL sid=${sid:0:8}: folder-trust prompt appeared for $cwd — trust the directory manually in Claude Code first"
      tmux kill-window -t "$win" 2>/dev/null || true
      CURRENT_WIN=""
      return 1
    fi
    # Resume-from-summary prompt (old/large sessions): pick "Resume full session
    # as-is" (option 2). A SUMMARY resume builds a different, smaller prefix that
    # would NOT match — and would not re-arm — the live session's cache. This was
    # the main reason large/MCP sessions failed to warm.
    if (( ! handled_summary )) && printf '%s\n' "$pane_txt" | grep -qiE 'Resume full session as-is|Resume from summary'; then
      tmux send-keys -t "$win" "2"; sleep 0.4; tmux send-keys -t "$win" Enter
      handled_summary=1; sleep 3; continue
    fi
    # MCP server-approval prompt ("[✔] server … Enter to confirm · Esc to reject
    # all"): confirm the PRE-SELECTED servers (Enter). The live session has these
    # tools in its prefix; rejecting would drop them and force a mismatch. Never
    # press Esc.
    if (( ! handled_mcp )) && printf '%s\n' "$pane_txt" | grep -qE 'Enter to confirm.*([Ee]sc to reject|reject all)'; then
      tmux send-keys -t "$win" Enter
      handled_mcp=1; sleep 3; continue
    fi
  done
  if (( ! ready )); then
    local tail_snip
    tail_snip=$(printf '%s\n' "$pane_txt" | grep -vE '^[[:space:]]*$' | tail -2 | tr '\n' '|' | head -c 160)
    log "FAIL sid=${sid:0:8}: fork TUI not ready after ${FORK_SPAWN_TIMEOUT}s; pane tail: ${tail_snip:-empty}"
    tmux kill-window -t "$win" 2>/dev/null || true
    CURRENT_WIN=""
    return 1
  fi

  # Verify-then-commit the keepalive into OUR fork pane: the text must land
  # intact in the input area before Enter is pressed. Long input wraps onto
  # continuation lines below the ❯, so scan from the LAST ❯-line to pane end.
  tmux send-keys -t "$win" -l "$keepalive"
  sleep 0.5
  local input_region
  input_region=$(tmux capture-pane -t "$win" -p 2>/dev/null | \
    awk '/^❯/{i=NR} {l[NR]=$0} END{if(i) for(n=i;n<=NR;n++) print l[n]}' || true)
  if ! printf '%s\n' "$input_region" | grep -qF "run=${nonce}"; then
    log "FAIL sid=${sid:0:8}: keepalive text did not land on the fork input line"
    tmux send-keys -t "$win" Escape 2>/dev/null || true
    tmux kill-window -t "$win" 2>/dev/null || true
    CURRENT_WIN=""
    return 1
  fi
  tmux send-keys -t "$win" Enter

  # Submission + reply loop. SOURCE OF TRUTH is the fork JSONL, not the pane
  # (BACKLOG cw-2): a real user record carrying the nonce is deterministic proof
  # Claude Code accepted the keepalive as a turn and sent it to the model —
  # independent of any TUI render change. The pane is used only as a SECONDARY
  # signal to decide whether an un-submitted keepalive needs another Enter.
  #
  # The fork's keepalive turn is committed exactly once: the instant
  # submit_confirmed sees the user record we STOP nudging Enter — a second Enter
  # then would create a duplicate turn. Until that proof exists, on a
  # busy/remote-control session the fork can swallow the first Enter while
  # mid-bridge-reconnect, so if the keepalive is still sitting on the input line
  # we press Enter again (bounded). This replaces the old pane-scrape-as-truth
  # resubmit, which could misread submission state from wrapped/redrawn panes.
  #
  # pane_has_unsent_keepalive: nonce still visible from the last ❯-line to pane
  # end (i.e. typed but not yet submitted). Kept as the fallback nudge trigger.
  pane_has_unsent_keepalive() {
    tmux capture-pane -t "$win" -p 2>/dev/null | \
      awk '/^❯/{i=NR} {l[NR]=$0} END{if(i) for(n=i;n<=NR;n++) print l[n]}' | \
      grep -qF "run=${nonce}"
  }

  waited=0
  local fork_jsonl="" usage="" matches match_count resubmits=0 submitted=0
  while (( waited < FORK_REPLY_TIMEOUT )); do
    sleep 5; waited=$((waited+5))
    # Identify the fork jsonl by CONTENT: exactly one file in the project dir,
    # created/modified after spawn, containing our nonce. Directory-diff
    # heuristics can misidentify a real user session — never trust them.
    if [[ -z $fork_jsonl ]]; then
      matches=$(find "$project_dir" -maxdepth 1 -name '*.jsonl' -newermt "@$spawn_epoch" \
                  -exec grep -l -F "run=${nonce}" {} + 2>/dev/null || true)
      match_count=$(printf '%s\n' "$matches" | grep -c . || true)
      [[ $match_count -eq 1 ]] && fork_jsonl=$matches
    fi
    # Deterministic submit confirmation: once the JSONL holds the user record,
    # the turn is committed for good — never nudge Enter again.
    if (( ! submitted )) && [[ -n $fork_jsonl && -f $fork_jsonl ]] \
         && submit_confirmed "$fork_jsonl" "$nonce"; then
      submitted=1
    fi
    # Fallback nudge: not yet confirmed submitted, and the keepalive is still
    # unsent on the input line → press Enter again as the session finishes
    # reconnecting (bounded to 3 retries). Harmless once submitted (guarded out).
    if (( ! submitted && resubmits < 3 )) && pane_has_unsent_keepalive; then
      tmux send-keys -t "$win" Enter; resubmits=$((resubmits+1))
    fi
    # Read the answering assistant turn's usage once the fork jsonl is known.
    if [[ -n $fork_jsonl && -f $fork_jsonl ]]; then
      usage=$(fork_usage_for_nonce "$fork_jsonl" "$nonce" || true)
      [[ -n $usage ]] && break
    fi
  done

  tmux kill-window -t "$win" 2>/dev/null || true
  CURRENT_WIN=""
  # Wait for the fork PROCESS to fully exit — killing the window is async, and
  # claude flushes a final write to its jsonl moments after SIGHUP, which would
  # re-create the file after we archive it. Poll the actual pane PID (checking
  # the window name is a no-op: kill-window destroys it on the first probe).
  if [[ -n $pane_pid ]]; then
    local dead_wait=0
    while (( dead_wait < 15 )) && kill -0 "$pane_pid" 2>/dev/null; do
      sleep 1; dead_wait=$((dead_wait+1))
    done
  fi
  sleep 1

  local mismatch_file="$STATE_DIR/${sid}.mismatch_count"
  if [[ -z $usage ]]; then
    log "FAIL sid=${sid:0:8}: no nonce-matched fork reply within ${FORK_REPLY_TIMEOUT}s (fork_jsonl=${fork_jsonl:-unidentified})"
    write_receipt "$sid" "$nonce" no_reply none 0 0 0 0
  else
    # Classify against the LIVE session's expected prefix size, not just the
    # fork request's own total — this distinguishes a diverged prefix from a
    # request that simply didn't carry the full history. The arithmetic lives
    # in lib/classify.sh (classify_warm) so it can be unit tested in isolation.
    local c_read c_create c_in expected klass strike
    read -r c_read c_create c_in <<< "$usage"
    expected=$(live_expected_tokens "$live_jsonl" || echo 0)
    read -r klass rc strike < <(classify_warm "$c_read" "$c_create" "$c_in" "$expected")
    if (( rc == 0 )); then
      log "RESULT sid=${sid:0:8} WARMED class=$klass cache_read=$c_read cache_creation=$c_create expected=$expected nonce=${nonce:0:8}"
      write_receipt "$sid" "$nonce" warmed "$klass" "$c_read" "$c_create" "$c_in" "$expected"
      rm -f "$mismatch_file"
    else
      local miss_n
      miss_n=$(read_int_state "$mismatch_file")
      miss_n=$((miss_n + 1))
      write_state "$mismatch_file" "$miss_n"
      write_receipt "$sid" "$nonce" mismatch "$klass" "$c_read" "$c_create" "$c_in" "$expected"
      if (( miss_n >= 2 )); then
        log "RESULT sid=${sid:0:8} MISMATCH class=$klass cache_read=$c_read cache_creation=$c_create expected=$expected (2nd consecutive) — blacklisting sid"
        touch "$STATE_DIR/${sid}.fork_mismatch"
      else
        log "RESULT sid=${sid:0:8} MISMATCH class=$klass cache_read=$c_read cache_creation=$c_create expected=$expected (1st — warning only; will blacklist on repeat)"
      fi
    fi
  fi

  # Archive the fork transcript for audit instead of deleting it. Validate
  # identity hard before moving: regular file, inside the project dir, UUID
  # basename, not the live session, contains the nonce.
  if [[ -n ${fork_jsonl:-} && -f ${fork_jsonl:-} ]]; then
    local base
    base=$(basename "$fork_jsonl" .jsonl)
    if [[ $fork_jsonl == "$project_dir"/*.jsonl && $base =~ $UUID_RE && $base != "$sid" ]] \
       && grep -qF "run=${nonce}" "$fork_jsonl" 2>/dev/null; then
      if mv "$fork_jsonl" "$FORK_ARCHIVE_DIR/${base}.jsonl" 2>/dev/null; then
        log "note: fork transcript archived to forks/${base}.jsonl"
      else
        log "note: could not archive fork transcript $fork_jsonl (left in place)"
      fi
    else
      log "note: fork transcript identity not certain ($fork_jsonl) — left in place, NOT touched"
    fi
  fi
  return $rc
}

# Side-effecting maintenance — skipped in dry-run (which must observe only).
if (( ! DRY_RUN )); then
  # Prune old archived fork transcripts (ours only).
  find "$FORK_ARCHIVE_DIR" -maxdepth 1 -name '*.jsonl' -mtime +"$FORK_RETENTION_DAYS" -delete 2>/dev/null || true

  # Clean up an orphaned fork session from a crashed run — but only if every
  # window matches our naming pattern; never kill a session a user repurposed.
  if tmux has-session -t "=$FORK_TMUX_SESSION" 2>/dev/null; then
    win_names=$(tmux list-windows -t "=$FORK_TMUX_SESSION" -F '#{window_name}' 2>/dev/null || true)
    if [[ -z $win_names ]] || ! printf '%s\n' "$win_names" | grep -qvE '^w[0-9]+-[0-9a-f]{8}$'; then
      log "note: removing leftover $FORK_TMUX_SESSION tmux session"
      tmux kill-session -t "=$FORK_TMUX_SESSION" 2>/dev/null || true
    else
      log "note: $FORK_TMUX_SESSION exists with unexpected windows — leaving it alone"
    fi
  fi
fi

# Current `claude` binary fingerprint, captured once per run. Used to skip
# warming a session whose last warm was built by a different binary (a Claude
# Code update shifts the system-prompt prefix — see claude_binary_fingerprint).
CLAUDE_FP_NOW=$(claude_binary_fingerprint)

# Evaluate one candidate session; warm it if due. Args: jsonl, cwd, live_args,
# live_pid, live_env.
declare -A SEEN_SID
process_candidate() {
  local jsonl=$1 cwd=$2 live_args=$3 live_pid=${4:-} live_env=${5:-}
  # Recompute now — a multi-warm run can take many minutes, and a stale `now`
  # would mis-age later candidates (warming a cold session, false strikes).
  local now; now=$(date +%s)
  [[ -f $jsonl ]] || return 0
  local sid
  sid=$(basename "$jsonl" .jsonl)
  [[ $sid =~ $UUID_RE ]] || return 0

  [[ -z ${SEEN_SID[$sid]:-} ]] || return 0
  SEEN_SID[$sid]=1

  if [[ -n $INCLUDE_ONLY_SIDS && ! $sid =~ $INCLUDE_ONLY_SIDS ]]; then
    return 0
  fi
  if [[ -n $EXCLUDE_SIDS && $sid =~ $EXCLUDE_SIDS ]]; then
    return 0
  fi
  # Repeated measured prefix mismatch → cooldown (not permanent): many
  # mismatch causes are transient (binary update, CLAUDE.md churn, a one-off
  # cold cache), so a session that mismatched days ago deserves a retry.
  local bl="$STATE_DIR/${sid}.fork_mismatch"
  if [[ -f $bl ]]; then
    local bl_age=$(( (now - $(stat -c %Y "$bl" 2>/dev/null || echo "$now")) / 86400 ))
    if (( bl_age < MISMATCH_COOLDOWN_DAYS )); then
      return 0
    fi
    rm -f "$bl" "$STATE_DIR/${sid}.mismatch_count"   # cooldown elapsed; give it another chance
  fi

  # Never warm a fork artifact: --fork-session copies the parent's full history
  # (including our keepalive marker) into a new file that would otherwise pass
  # every gate and get warmed as if it were a live session.
  if grep -qaF '[cache-warmer keepalive]' "$jsonl" 2>/dev/null; then
    return 0
  fi

  # Fail closed on prefix-affecting flags we can't reproduce — replaying them
  # wrong pays a full cache write per attempt. Better to skip and say so.
  if prefix_unreplicable "$live_args"; then
    log "skip sid=${sid:0:8}: live args use a prefix-affecting flag the warmer can't replicate (would mismatch)"
    return 0
  fi

  # The fork is a fully-armed Claude agent in the live session's cwd; with
  # --dangerously-skip-permissions it could act on the keepalive without an
  # approval gate. Opt-out gate (default warms them — the prefix must match,
  # so bypass mode has to be replicated; see README "Armed forks").
  if [[ $WARM_BYPASS_SESSIONS != 1 && $live_args == *"--dangerously-skip-permissions"* ]]; then
    log "skip sid=${sid:0:8}: session runs --dangerously-skip-permissions and WARM_BYPASS_SESSIONS=0"
    return 0
  fi

  # Cache freshness = most recent of (live API activity, our last SUCCESSFUL
  # fork-warm). Fork warms re-arm the cache without touching the live jsonl,
  # so warm state is tracked separately.
  local mtime last_warm last_attempt fresh age_min
  mtime=$(stat -c %Y "$jsonl" 2>/dev/null) || return 0   # file vanished mid-run
  last_warm=$(read_int_state "$STATE_DIR/${sid}.last_warm")
  last_attempt=$(read_int_state "$STATE_DIR/${sid}.last_attempt")
  fresh=$(( mtime > last_warm ? mtime : last_warm ))
  age_min=$(( (now - fresh) / 60 ))

  if (( age_min < WARM_MIN_AGE || age_min >= WARM_MAX_AGE )); then
    return 0   # comfortably warm, or past the window (cold) — quiet skip
  fi
  # Skip if the cache freshness reference is on a different calendar day than
  # now: the prompt prefix typically embeds the current date, so a fork across
  # a midnight boundary diverges deterministically (full write + false strike).
  if [[ $(date -d "@$fresh" +%Y-%m-%d 2>/dev/null) != $(date -d "@$now" +%Y-%m-%d 2>/dev/null) ]]; then
    log "skip sid=${sid:0:8} age=${age_min}m: warm window crosses a date boundary (prefix would diverge)"
    return 0
  fi
  # Rate-limit on ATTEMPTS (not successes) so a failing session can't be
  # hammered, while failures don't fake freshness.
  if (( now - last_attempt < RATELIMIT_MIN * 60 )); then
    return 0
  fi

  # Bound runaway warming: require recent, non-trivial REAL user activity.
  # MIN_USER_MSGS filters one-shot `claude -p` cron sessions sharing the dir.
  local activity user_epoch user_count user_idle_min
  activity=$(user_activity "$jsonl" || true)
  if [[ -z $activity ]]; then
    return 0
  fi
  read -r user_epoch user_count <<< "$activity"
  if (( user_count < MIN_USER_MSGS )); then
    log "skip sid=${sid:0:8} age=${age_min}m: only ${user_count} real user msg(s) (< ${MIN_USER_MSGS}; likely headless run)"
    return 0
  fi
  user_idle_min=$(( (now - user_epoch) / 60 ))
  if (( user_idle_min > MAX_USER_IDLE_MIN )); then
    log "skip sid=${sid:0:8} age=${age_min}m user-idle=${user_idle_min}m > ${MAX_USER_IDLE_MIN}m: letting cache lapse"
    return 0
  fi

  # Binary-drift guard: if the freshness reference is a prior fork-warm (not new
  # live activity) and the `claude` binary has changed since that warm, the
  # cached prefix was built by the old binary and a new-binary fork would
  # diverge. Skip and refresh the baseline so the live session can re-arm
  # organically before we warm against the new binary. (When live activity is
  # newer than our last warm, the live session itself rebuilt the prefix with
  # the current binary, so no drift concern.)
  local bin_file="$STATE_DIR/${sid}.warm_binary"
  if (( last_warm >= mtime )) && [[ -f $bin_file ]]; then
    local warm_fp
    warm_fp=$(cat "$bin_file" 2>/dev/null || true)
    if [[ -n $warm_fp && $warm_fp != "$CLAUDE_FP_NOW" ]]; then
      log "skip sid=${sid:0:8} age=${age_min}m: claude binary drifted since last warm (${warm_fp%%|*} → ${CLAUDE_FP_NOW%%|*}); refreshing baseline"
      (( DRY_RUN )) || write_state "$bin_file" "$CLAUDE_FP_NOW"
      return 0
    fi
  fi

  log "WARM sid=${sid:0:8} age=${age_min}m user-idle=${user_idle_min}m msgs=${user_count} (fork-resume, live session untouched)"
  if (( DRY_RUN )); then
    return 0
  fi
  write_state "$STATE_DIR/${sid}.last_attempt" "$(date +%s)"
  if warm_by_fork "$sid" "$cwd" "$live_args" "$jsonl" "$live_pid" "$live_env"; then
    write_state "$STATE_DIR/${sid}.last_warm" "$(date +%s)"
    write_state "$bin_file" "$CLAUDE_FP_NOW"
  fi
}

# Discover project dirs of running Claude TUI processes (and authoritative
# --resume sids). Forks and -p/--print processes are never candidates. The
# live pid and a snapshot of its prefix-affecting env are captured here so the
# fork can replicate them even if the live process exits before the warm runs.
declare -A DIR_CWD DIR_ARGS DIR_PID DIR_ENV RESUME_SID_ARGS RESUME_SID_CWD RESUME_SID_PID RESUME_SID_ENV
while IFS=$'\t' read -r pid tty comm args; do
  # Match both direct `claude` and wrapper-launched instances (npx/node execing
  # the CLI) whose argv still names the claude entrypoint.
  [[ $comm == claude || $args == *"claude"* ]] || continue
  [[ $tty != "?" ]] || continue
  case " $args " in
    *" -p "*|*" --print "*) continue ;;
  esac
  [[ $args == *"--fork-session"* ]] && continue

  cwd=$(readlink "/proc/$pid/cwd" 2>/dev/null || true)
  [[ -n $cwd ]] || continue
  project_dir="$HOME/.claude/projects/${cwd//\//-}"
  [[ -d $project_dir ]] || continue
  live_env=$(replicated_env "$pid")
  DIR_CWD[$project_dir]=$cwd
  DIR_ARGS[$project_dir]=$args
  DIR_PID[$project_dir]=$pid
  DIR_ENV[$project_dir]=$live_env

  if [[ $args == *"--resume "* ]]; then
    rsid=$(printf '%s\n' "$args" | grep -oE -- '--resume [0-9a-f-]+' | awk '{print $2}' | head -1 || true)
    if [[ -n $rsid && $rsid =~ $UUID_RE ]]; then
      RESUME_SID_ARGS[$rsid]=$args
      RESUME_SID_CWD[$rsid]=$cwd
      RESUME_SID_PID[$rsid]=$pid
      RESUME_SID_ENV[$rsid]=$live_env
    fi
  fi
done < <(ps -eo pid=,tty=,comm=,args= --no-headers | awk '{pid=$1; tty=$2; comm=$3; $1=$2=$3=""; sub(/^ +/,""); print pid "\t" tty "\t" comm "\t" $0}')

# Authoritative --resume sessions first (their jsonl may sit outside the cwd dir).
for rsid in "${!RESUME_SID_ARGS[@]}"; do
  jsonl=$(find "$HOME/.claude/projects" -maxdepth 3 -name "${rsid}.jsonl" 2>/dev/null | head -1 || true)
  [[ -n $jsonl ]] && process_candidate "$jsonl" "${RESUME_SID_CWD[$rsid]}" "${RESUME_SID_ARGS[$rsid]}" \
    "${RESUME_SID_PID[$rsid]}" "${RESUME_SID_ENV[$rsid]}"
done

# Then recent sessions in each active project dir (snapshot the list up front
# so fork jsonls created mid-run are never scanned; cap at the 10 newest to
# bound cost). NOTE: this is heuristic — the warmer cannot prove which jsonl
# belongs to which live TUI, so it may warm a recently-active session in the
# same dir that no one returns to. The MIN_USER_MSGS, user-idle, and
# warm-window gates bound that cost; RESULT receipts make it visible.
for project_dir in "${!DIR_CWD[@]}"; do
  mapfile -t candidates < <(ls -1t "$project_dir"/*.jsonl 2>/dev/null | head -10 || true)
  for jsonl in "${candidates[@]}"; do
    process_candidate "$jsonl" "${DIR_CWD[$project_dir]}" "${DIR_ARGS[$project_dir]}" \
      "${DIR_PID[$project_dir]}" "${DIR_ENV[$project_dir]}"
  done
done

# If our fork session is now empty, remove it.
if tmux has-session -t "$FORK_TMUX_SESSION" 2>/dev/null; then
  if [[ -z $(tmux list-windows -t "$FORK_TMUX_SESSION" -F '#{window_name}' 2>/dev/null) ]]; then
    tmux kill-session -t "$FORK_TMUX_SESSION" 2>/dev/null || true
  fi
fi
