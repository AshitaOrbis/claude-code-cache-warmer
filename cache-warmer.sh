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
# Candidates: authoritative --resume session IDs from running Claude TUI
# processes, joined to transcripts by SID rather than a lossy cwd mapping, then
# gated by warm window, ≥MIN_USER_MSGS real user messages, and user-idle bound.
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
PROC_ROOT=${CW_PROC_ROOT:-/proc}   # override only for hermetic discovery tests
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
if [[ ${CACHE_WARMER_SOURCE_ONLY:-0} != 1 ]]; then
  case "${1:-}" in
    --dry-run) DRY_RUN=1 ;;
    --help|-h) sed -n '2,27p' "$0"; exit 0 ;;
    "") ;;
    *) echo "unknown argument: $1 (use --dry-run or --help)" >&2; exit 2 ;;
  esac
fi

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

# Kill the current fork window if the script dies mid-warm (systemd stop,
# logout, error) instead of leaving an orphaned Claude process running.
CURRENT_WIN=""
cleanup_current_win() {
  [[ -n $CURRENT_WIN ]] && tmux kill-window -t "$CURRENT_WIN" 2>/dev/null || true
}

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

# True if the live argv contains a prefix-affecting option we cannot reproduce.
# Match complete tokens only and stop at `--`; prompt text is data, not flags.
prefix_unreplicable() {
  local -a argv=("$@")
  local i token name value
  for ((i = 1; i < ${#argv[@]}; i++)); do
    token=${argv[$i]}
    [[ $token == -- ]] && break
    case "$token" in
      --model|--permission-mode)
        # A present option we cannot reproduce exactly is a mismatch, not an
        # excuse to silently launch with the fork's default value.
        ((i + 1 < ${#argv[@]})) || return 0
        value=${argv[$((i + 1))]}
        [[ $value != --* && $value =~ $SAFE_VALUE_RE ]] || return 0
        i=$((i + 1))
        ;;
      --model=*|--permission-mode=*)
        value=${token#*=}
        [[ $value != --* && $value =~ $SAFE_VALUE_RE ]] || return 0
        ;;
      *)
        name=${token%%=*}
        case "$name" in
          --append-system-prompt|--system-prompt|--settings|--add-dir|--agent|--agents|\
          --mcp-config|--strict-mcp-config|--allowed-tools|--allowedTools|\
          --disallowed-tools|--disallowedTools|--beta|--betas)
            return 0
            ;;
        esac
        ;;
    esac
  done
  return 1
}

# Replicate only prefix-relevant, value-validated flags from the live
# process's cmdline. The fork's system prompt must reconstruct identically or
# the cache misses; permission mode is part of that. Handles both space and
# '=' flag forms. Deliberately NOT replicated: --remote-control,
# --resume/--continue (we supply our own).
replicated_flags() {
  local -a argv=("$@")
  local i token value out=""
  for ((i = 1; i < ${#argv[@]}; i++)); do
    token=${argv[$i]}
    [[ $token == -- ]] && break
    case "$token" in
      --dangerously-skip-permissions)
        out+=" --dangerously-skip-permissions"
        ;;
      --model|--permission-mode)
        ((i + 1 < ${#argv[@]})) || continue
        value=${argv[$((i + 1))]}
        [[ $value != --* && $value =~ $SAFE_VALUE_RE ]] || continue
        out+=" $token $value"
        i=$((i + 1))
        ;;
      --model=*|--permission-mode=*)
        value=${token#*=}
        [[ $value != --* && $value =~ $SAFE_VALUE_RE ]] || continue
        out+=" ${token%%=*} $value"
        ;;
    esac
  done
  printf '%s\n' "$out"
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
  local environ="$PROC_ROOT/$pid/environ"
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

# Discovery keeps argv as NUL-delimited tokens until it has proved process
# identity. A flattened `ps ... args` substring is not evidence that a command
# is Claude: `tail -f ~/.claude/logs/...` contains the same word (bq-1323).
PROCESS_EXE=""
declare -a PROCESS_ARGV=()
declare -A RESUME_SID_ARGS RESUME_SID_FLAGS RESUME_SID_UNREPLICABLE \
  RESUME_SID_BYPASS RESUME_SID_CWD RESUME_SID_PID RESUME_SID_ENV \
  RESUME_SID_AMBIGUOUS

read_process_exe() {
  local pid=$1
  PROCESS_EXE=$(readlink -f "$PROC_ROOT/$pid/exe" 2>/dev/null || true)
  [[ -n $PROCESS_EXE ]]
}

read_process_argv() {
  local pid=$1 token
  PROCESS_ARGV=()
  [[ -r $PROC_ROOT/$pid/cmdline ]] || return 1
  while IFS= read -r -d '' token; do
    PROCESS_ARGV+=("$token")
  done < "$PROC_ROOT/$pid/cmdline"
  (( ${#PROCESS_ARGV[@]} > 0 ))
}

is_known_claude_process() {
  local exe=$1 base installed="" entrypoint=""
  shift
  base=$(basename "$exe")

  # The native installer exposes ~/.local/bin/claude as a symlink to a
  # version-named ELF, so /proc/<pid>/exe ends in (for example) `2.1.261`.
  # Authenticate direct/native processes against the exact installed binary;
  # a different executable merely named `claude` is not authoritative. Do not
  # depend on argv[0]: native launchers may preserve the symlink name or replace
  # it with the versioned executable path.
  installed=$(command -v claude 2>/dev/null || true)
  installed=$(readlink -f "$installed" 2>/dev/null || true)
  [[ -n $installed && $installed == "$exe" ]] && return 0

  case "$base" in
    node|nodejs|bun)
      # For JS installs the CLI must be argv[1], not an arbitrary data token.
      entrypoint=${2:-}
      case "$entrypoint" in
        */@anthropic-ai/claude-code/cli.js|*/@anthropic-ai/claude-code/cli.mjs|*/claude-code/cli.js|*/claude-code/cli.mjs)
          return 0
          ;;
      esac
      ;;
  esac
  return 1
}

argv_has_exact() {
  local wanted=$1 token
  shift
  for token in "$@"; do
    [[ $token == -- ]] && break
    [[ $token == "$wanted" ]] && return 0
  done
  return 1
}

argv_to_shell_words() {
  local token quoted out=""
  for token in "$@"; do
    printf -v quoted '%q' "$token"
    out+="${out:+ }$quoted"
  done
  printf '%s\n' "$out"
}

resume_sid_from_argv() {
  local token sid="" wants_value=0
  for token in "$@"; do
    [[ $token == -- ]] && break
    if (( wants_value )); then sid=$token; break; fi
    case "$token" in
      --resume) wants_value=1 ;;
      --resume=*) sid=${token#--resume=}; break ;;
    esac
  done
  [[ $sid =~ $UUID_RE ]] || return 1
  printf '%s\n' "$sid"
}

# Bind a process configuration to its explicit SID, never to its cwd. Multiple
# TUIs in one directory therefore cannot donate flags/env to each other's
# transcripts; conflicting claims for the same SID are refused (bq-1021/1318).
record_authoritative_process() {
  local pid=$1 cwd=$2 live_env=$3 sid args flags unreplicable=0 bypass=0
  shift 3
  sid=$(resume_sid_from_argv "$@") || return 1
  args=$(argv_to_shell_words "$@")
  flags=$(replicated_flags "$@")
  prefix_unreplicable "$@" && unreplicable=1
  # Classification consumes the same validated, normalized options as the fork.
  local -a fork_options=()
  local i
  read -r -a fork_options <<< "$flags"
  for ((i = 0; i < ${#fork_options[@]}; i++)); do
    case ${fork_options[$i]} in
      --dangerously-skip-permissions) bypass=1 ;;
      --permission-mode|--model)
        if [[ ${fork_options[$i]} == --permission-mode && ${fork_options[$((i + 1))]:-} == bypassPermissions ]]; then
          bypass=1
        fi
        i=$((i + 1))
        ;;
    esac
  done
  [[ -z ${RESUME_SID_AMBIGUOUS[$sid]:-} ]] || return 1
  if [[ -n ${RESUME_SID_ARGS[$sid]+x} ]]; then
    if [[ ${RESUME_SID_CWD[$sid]} != "$cwd" || ${RESUME_SID_ARGS[$sid]} != "$args" \
          || ${RESUME_SID_ENV[$sid]} != "$live_env" ]]; then
      RESUME_SID_AMBIGUOUS[$sid]=1
      unset 'RESUME_SID_ARGS[$sid]' 'RESUME_SID_FLAGS[$sid]' \
        'RESUME_SID_UNREPLICABLE[$sid]' 'RESUME_SID_BYPASS[$sid]' \
        'RESUME_SID_CWD[$sid]' 'RESUME_SID_PID[$sid]' 'RESUME_SID_ENV[$sid]'
      return 1
    fi
    return 0
  fi
  RESUME_SID_ARGS[$sid]=$args
  RESUME_SID_FLAGS[$sid]=$flags
  RESUME_SID_UNREPLICABLE[$sid]=$unreplicable
  RESUME_SID_BYPASS[$sid]=$bypass
  RESUME_SID_CWD[$sid]=$cwd
  RESUME_SID_PID[$sid]=$pid
  RESUME_SID_ENV[$sid]=$live_env
}

# Locate by authoritative SID across the projects tree. Reconstructing the
# project directory from cwd is lossy because Claude maps '.', '_', and other
# characters to '-' as well as '/', and collisions are possible. Exactly one
# match is required; zero or duplicates fail closed (bq-1022/1201/1324).
FOUND_SESSION_JSONL=""
FOUND_SESSION_COUNT=0
find_session_jsonl() {
  local sid=$1 projects_root=${2:-"$HOME/.claude/projects"}
  local -a matches=()
  FOUND_SESSION_JSONL=""
  FOUND_SESSION_COUNT=0
  [[ $sid =~ $UUID_RE && -d $projects_root ]] || return 1
  mapfile -d '' -t matches < <(find "$projects_root" -type f -name "${sid}.jsonl" -print0 2>/dev/null)
  FOUND_SESSION_COUNT=${#matches[@]}
  (( FOUND_SESSION_COUNT == 1 )) || return 1
  FOUND_SESSION_JSONL=${matches[0]}
}

# A fingerprint mismatch remains true on every timer tick while the transcript
# has not advanced beyond the prior warm. The guard itself never updates the
# stored fingerprint; only an organic write followed by a successful warm may
# do that (bq-1202/1321).
binary_drift_blocks() {
  local last_warm=$1 live_mtime=$2 recorded_fp=$3 current_fp=$4
  (( last_warm >= live_mtime )) && [[ -n $recorded_fp && $recorded_fp != "$current_fp" ]]
}

# Tests source the pure discovery/guard helpers without entering runtime
# discovery or touching any real process/session.
if [[ ${CACHE_WARMER_SOURCE_ONLY:-0} == 1 ]]; then
  return 0 2>/dev/null || exit 0
fi

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
trap cleanup_current_win EXIT INT TERM HUP

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

# Warm one session by fork. Args: sid, cwd, replicated_flags, live_jsonl, live_pid,
# live_env. Returns 0 on verified warm, 1 otherwise. Logs RESULT/FAIL itself.
warm_by_fork() {
  local sid=$1 cwd=$2 flags=$3 live_jsonl=$4 live_pid=${5:-} live_env=${6:-}
  # Derive the project dir from the live jsonl itself — Claude Code mangles
  # more than just '/' in the cwd→dir mapping (e.g. '.' also becomes '-'), so
  # recomputing it from cwd is unreliable. The fork's jsonl lands beside the
  # live one, so dirname is correct by construction.
  local project_dir
  project_dir=$(dirname "$live_jsonl")
  local win rc=1 nonce spawn_epoch pane_pid=""
  [[ $sid =~ $UUID_RE ]] || { log "FAIL sid=${sid:0:8}: not a valid session UUID, refusing to fork"; return 1; }
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

# Evaluate one candidate session; warm it if due. Args: jsonl, cwd,
# replicated_flags, has_unreplicable_flag, has_bypass_flag, live_pid, live_env.
declare -A SEEN_SID
process_candidate() {
  local jsonl=$1 cwd=$2 live_flags=$3 live_unreplicable=$4 live_bypass=$5 \
    live_pid=${6:-} live_env=${7:-}
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
  if [[ $live_unreplicable == 1 ]]; then
    log "skip sid=${sid:0:8}: live args use a prefix-affecting flag the warmer can't replicate (would mismatch)"
    return 0
  fi

  # The fork is a fully-armed Claude agent in the live session's cwd; with
  # --dangerously-skip-permissions it could act on the keepalive without an
  # approval gate. Opt-out gate (default warms them — the prefix must match,
  # so bypass mode has to be replicated; see README "Armed forks").
  if [[ $WARM_BYPASS_SESSIONS != 1 && $live_bypass == 1 ]]; then
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
  if [[ -f $bin_file ]]; then
    local warm_fp
    warm_fp=$(cat "$bin_file" 2>/dev/null || true)
    if binary_drift_blocks "$last_warm" "$mtime" "$warm_fp" "$CLAUDE_FP_NOW"; then
      log "skip sid=${sid:0:8} age=${age_min}m: claude binary drifted since last warm (${warm_fp%%|*} → ${CLAUDE_FP_NOW%%|*}); waiting for newer live activity"
      return 0
    fi
  fi

  log "WARM sid=${sid:0:8} age=${age_min}m user-idle=${user_idle_min}m msgs=${user_count} (fork-resume, live session untouched)"
  if (( DRY_RUN )); then
    return 0
  fi
  write_state "$STATE_DIR/${sid}.last_attempt" "$(date +%s)"
  if warm_by_fork "$sid" "$cwd" "$live_flags" "$jsonl" "$live_pid" "$live_env"; then
    write_state "$STATE_DIR/${sid}.last_warm" "$(date +%s)"
    write_state "$bin_file" "$CLAUDE_FP_NOW"
  fi
}

# Discover exact Claude TUI processes from /proc argv/executable identity.
# Forks and -p/--print processes are never candidates. The live pid and a
# snapshot of its prefix-affecting env are captured here so the fork can
# replicate them even if the live process exits before the warm runs.
while read -r pid tty _comm; do
  [[ $tty != "?" ]] || continue
  read_process_exe "$pid" || continue
  read_process_argv "$pid" || continue
  is_known_claude_process "$PROCESS_EXE" "${PROCESS_ARGV[@]}" || continue
  argv_has_exact -p "${PROCESS_ARGV[@]}" && continue
  argv_has_exact --print "${PROCESS_ARGV[@]}" && continue
  argv_has_exact --fork-session "${PROCESS_ARGV[@]}" && continue

  cwd=$(readlink "$PROC_ROOT/$pid/cwd" 2>/dev/null || true)
  [[ -n $cwd ]] || continue
  live_env=$(replicated_env "$pid")

  rsid=$(resume_sid_from_argv "${PROCESS_ARGV[@]}" 2>/dev/null || true)
  if [[ -z $rsid ]]; then
    log "skip pid=$pid: Claude TUI has no authoritative --resume session id; directory fallback is disabled"
    continue
  fi
  if ! record_authoritative_process "$pid" "$cwd" "$live_env" "${PROCESS_ARGV[@]}"; then
    log "skip sid=${rsid:0:8}: multiple live processes claim it with conflicting cwd, flags, or environment"
  fi
done < <(ps -eo pid=,tty=,comm= --no-headers)

# Join each process to exactly one transcript by SID, independent of cwd's
# lossy project-directory encoding.
for rsid in "${!RESUME_SID_ARGS[@]}"; do
  if find_session_jsonl "$rsid"; then
    process_candidate "$FOUND_SESSION_JSONL" "${RESUME_SID_CWD[$rsid]}" \
      "${RESUME_SID_FLAGS[$rsid]}" "${RESUME_SID_UNREPLICABLE[$rsid]}" \
      "${RESUME_SID_BYPASS[$rsid]}" "${RESUME_SID_PID[$rsid]}" "${RESUME_SID_ENV[$rsid]}"
  else
    log "skip sid=${rsid:0:8}: authoritative SID matched ${FOUND_SESSION_COUNT} transcript files (need exactly one)"
  fi
done

# If our fork session is now empty, remove it.
if tmux has-session -t "$FORK_TMUX_SESSION" 2>/dev/null; then
  if [[ -z $(tmux list-windows -t "$FORK_TMUX_SESSION" -F '#{window_name}' 2>/dev/null) ]]; then
    tmux kill-session -t "$FORK_TMUX_SESSION" 2>/dev/null || true
  fi
fi
