#!/usr/bin/env bash
# Keep long Claude Code contexts warm in the Anthropic prompt cache — WITHOUT
# touching the live sessions. For each idle session nearing cache expiry,
# spawn a disposable FORK (`claude --resume <sid> --fork-session`) in a hidden
# tmux window, send a keepalive there, then discard the fork. The fork's API
# request carries the identical prefix, so reading it re-arms the live
# session's cache TTL; the live session's transcript is never modified
# (verified byte-identical, 2026-06-11).
#
# Designed for the 1-hour extended prompt-cache TTL (set
# ENABLE_PROMPT_CACHING_1H=1 in the shell that launches your Claude sessions;
# Claude Code v2.1.108+). Measure your own effective TTL with measure-ttl.py
# and tune WARM_MIN_AGE/WARM_MAX_AGE accordingly. See README.md.
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
# direct evidence the warm worked (cache_read ≈ full prefix = success).

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
CONFIG_FILE="$SCRIPT_DIR/config"
LOG_DIR="$HOME/.claude/logs"
LOG_FILE="$LOG_DIR/cache-warmer.log"
STATE_DIR="$HOME/.cache/cache-warmer"
FORK_TMUX_SESSION="cache-warmer-forks"
mkdir -p "$LOG_DIR" "$STATE_DIR"

# Defaults; config overrides.
ENABLED=0
WARM_MIN_AGE=45
WARM_MAX_AGE=58
MAX_USER_IDLE_MIN=240
MIN_USER_MSGS=2
RATELIMIT_MIN=30
EXCLUDE_SIDS=''
INCLUDE_ONLY_SIDS=''
KEEPALIVE_TEXT='[cache-warmer keepalive] No action needed — reply with only: ok'
FORK_SPAWN_TIMEOUT=180   # seconds to wait for the fork TUI's input prompt (huge sessions take >60s to restore)
FORK_REPLY_TIMEOUT=120   # seconds to wait for the fork's keepalive turn
# shellcheck disable=SC1090
[[ -f $CONFIG_FILE ]] && source "$CONFIG_FILE"

DRY_RUN=0
case "${1:-}" in
  --dry-run) DRY_RUN=1 ;;
  --help|-h) sed -n '2,22p' "$0"; exit 0 ;;
esac

log() {
  local tag=""
  (( DRY_RUN )) && tag=" [dry-run]"
  echo "[$(date '+%Y-%m-%d %H:%M:%S')]${tag} $*" >> "$LOG_FILE"
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

# Last real-user-message epoch + count for a session jsonl. Real = type=user,
# not a tool result, not meta, not a keepalive. Prints "epoch count".
user_activity() {
  python3 - "$1" <<'PY'
import json, sys, datetime
marker = "[cache-warmer keepalive]"
last, count = None, 0
try:
    with open(sys.argv[1]) as fh:
        for line in fh:
            if '"type":"user"' not in line and '"type": "user"' not in line:
                continue
            try:
                rec = json.loads(line)
            except Exception:
                continue
            if rec.get("type") != "user" or rec.get("isMeta") or "toolUseResult" in rec:
                continue
            content = (rec.get("message") or {}).get("content")
            if isinstance(content, list):
                if any(b.get("type") == "tool_result" for b in content if isinstance(b, dict)):
                    continue
                text = " ".join(b.get("text", "") for b in content if isinstance(b, dict))
            else:
                text = content or ""
            if marker in text:
                continue
            ts = rec.get("timestamp")
            if ts:
                last, count = ts, count + 1
except Exception:
    pass
if last:
    epoch = int(datetime.datetime.fromisoformat(last.replace("Z", "+00:00")).timestamp())
    print(epoch, count)
PY
}

# Usage of the LAST assistant message in a fork jsonl: "read creation input".
fork_last_usage() {
  python3 - "$1" <<'PY'
import json, sys
u = None
try:
    with open(sys.argv[1]) as fh:
        for line in fh:
            try:
                rec = json.loads(line)
            except Exception:
                continue
            if rec.get("type") == "assistant":
                u = (rec.get("message") or {}).get("usage") or {}
except Exception:
    pass
if u is not None:
    print(u.get("cache_read_input_tokens", 0), u.get("cache_creation_input_tokens", 0), u.get("input_tokens", 0))
PY
}

# Replicate only prefix-relevant flags from the live process's cmdline. The
# fork's system prompt must reconstruct identically or the cache misses; the
# permission mode is part of that. Deliberately NOT replicated: --remote-control
# (engages RC needlessly), --resume/--continue (we supply our own).
replicated_flags() {
  local args=$1 out=""
  [[ $args == *"--dangerously-skip-permissions"* ]] && out+=" --dangerously-skip-permissions"
  if [[ $args =~ --model[[:space:]]+([^[:space:]]+) ]]; then
    out+=" --model ${BASH_REMATCH[1]}"
  fi
  if [[ $args =~ --permission-mode[[:space:]]+([^[:space:]]+) ]]; then
    out+=" --permission-mode ${BASH_REMATCH[1]}"
  fi
  echo "$out"
}

# Warm one session by fork. Args: sid, cwd, live_args. Returns 0 on verified
# warm, 1 otherwise. Logs RESULT/FAIL lines itself.
warm_by_fork() {
  local sid=$1 cwd=$2 live_args=$3
  local project_dir="$HOME/.claude/projects/${cwd//\//-}"
  local flags win rc=1
  flags=$(replicated_flags "$live_args")
  win="$FORK_TMUX_SESSION:w$$-${sid:0:8}"

  # Snapshot existing jsonls so the fork's new file is identifiable.
  local before_list
  before_list=$(ls -1 "$project_dir"/*.jsonl 2>/dev/null || true)

  if tmux has-session -t "$FORK_TMUX_SESSION" 2>/dev/null; then
    tmux new-window -d -t "$FORK_TMUX_SESSION" -n "w$$-${sid:0:8}" -c "$cwd" \
      "env -u CLAUDECODE -u CLAUDE_CODE_ENTRYPOINT -u CLAUDE_CODE_SSE_PORT claude --resume $sid --fork-session$flags"
  else
    tmux new-session -d -s "$FORK_TMUX_SESSION" -n "w$$-${sid:0:8}" -c "$cwd" \
      "env -u CLAUDECODE -u CLAUDE_CODE_ENTRYPOINT -u CLAUDE_CODE_SSE_PORT claude --resume $sid --fork-session$flags"
  fi

  # Wait for the fork TUI's empty input prompt. Large sessions take minutes
  # to restore; that's fine, the slow path is exactly the valuable one.
  local waited=0 pane_txt="" ready=0
  while (( waited < FORK_SPAWN_TIMEOUT )); do
    sleep 5; waited=$((waited+5))
    pane_txt=$(tmux capture-pane -t "$win" -p 2>/dev/null || true)
    # NB: the empty input line is "❯" + U+00A0 (no-break space), which
    # [[:space:]] does not match — include the literal NBSP in the bracket.
    if printf '%s\n' "$pane_txt" | grep -qE $'^❯[ \t\u00a0]*$'; then ready=1; break; fi
    # auto-accept the folder-trust dialog if it appears
    if printf '%s\n' "$pane_txt" | grep -q "trust this folder"; then
      tmux send-keys -t "$win" Enter 2>/dev/null || true
    fi
  done
  if (( ! ready )); then
    local tail_snip
    tail_snip=$(printf '%s\n' "$pane_txt" | grep -vE '^[[:space:]]*$' | tail -2 | tr '\n' '|' | head -c 160)
    log "FAIL sid=${sid:0:8}: fork TUI not ready after ${FORK_SPAWN_TIMEOUT}s; pane tail: ${tail_snip:-empty}"
    tmux kill-window -t "$win" 2>/dev/null || true
    return 1
  fi

  # Verify-then-commit the keepalive into OUR fork pane.
  tmux send-keys -t "$win" -l "$KEEPALIVE_TEXT"
  sleep 0.5
  if ! tmux capture-pane -t "$win" -p 2>/dev/null | grep -qF 'cache-warmer keepalive'; then
    log "FAIL sid=${sid:0:8}: keepalive text did not land in fork input box"
    tmux kill-window -t "$win" 2>/dev/null || true
    return 1
  fi
  tmux send-keys -t "$win" Enter

  # Identify the fork jsonl (new file in the project dir) and await its reply.
  waited=0
  local fork_jsonl="" usage=""
  while (( waited < FORK_REPLY_TIMEOUT )); do
    sleep 5; waited=$((waited+5))
    if [[ -z $fork_jsonl ]]; then
      fork_jsonl=$(comm -13 <(printf '%s\n' "$before_list" | sort) \
                            <(ls -1 "$project_dir"/*.jsonl 2>/dev/null | sort) | head -1 || true)
    fi
    if [[ -n $fork_jsonl && -f $fork_jsonl ]]; then
      usage=$(fork_last_usage "$fork_jsonl" || true)
      [[ -n $usage ]] && break
    fi
  done

  tmux kill-window -t "$win" 2>/dev/null || true

  if [[ -z $usage ]]; then
    log "FAIL sid=${sid:0:8}: no fork reply within ${FORK_REPLY_TIMEOUT}s (fork_jsonl=${fork_jsonl:-none})"
  else
    local c_read c_create c_in total
    read -r c_read c_create c_in <<< "$usage"
    total=$(( c_read + c_create + c_in ))
    if (( total > 0 && c_read * 2 >= total )); then
      log "RESULT sid=${sid:0:8} WARMED cache_read=$c_read cache_creation=$c_create (prefix refreshed)"
      rc=0
    else
      # Prefix mismatch: the fork paid a full cache write and refreshed nothing.
      # Blacklist this sid so we never repeat the cost; loud log for diagnosis.
      log "RESULT sid=${sid:0:8} MISMATCH cache_read=$c_read cache_creation=$c_create — fork prefix did not match; blacklisting sid"
      touch "$STATE_DIR/${sid}.fork_mismatch"
    fi
  fi

  # The fork served its purpose; remove its jsonl so it never pollutes
  # discovery or /resume listings.
  [[ -n ${fork_jsonl:-} && -f ${fork_jsonl:-} ]] && rm -f "$fork_jsonl"
  return $rc
}

# Evaluate one candidate session; warm it if due. Args: jsonl, cwd, live_args.
declare -A SEEN_SID
process_candidate() {
  local jsonl=$1 cwd=$2 live_args=$3
  [[ -f $jsonl ]] || return 0
  local sid
  sid=$(basename "$jsonl" .jsonl)

  [[ -z ${SEEN_SID[$sid]:-} ]] || return 0
  SEEN_SID[$sid]=1

  if [[ -n $INCLUDE_ONLY_SIDS && ! $sid =~ $INCLUDE_ONLY_SIDS ]]; then
    return 0
  fi
  if [[ -n $EXCLUDE_SIDS && $sid =~ $EXCLUDE_SIDS ]]; then
    return 0
  fi
  if [[ -f "$STATE_DIR/${sid}.fork_mismatch" ]]; then
    return 0   # previously measured prefix mismatch; warming wastes a full cache write
  fi

  # Cache freshness = most recent of (live API activity, our last fork-warm).
  # Fork warms re-arm the cache without touching the live jsonl, so mtime
  # alone would over-age warmed sessions.
  local mtime state_file last_warm fresh age_min
  mtime=$(stat -c %Y "$jsonl")
  state_file="$STATE_DIR/${sid}.last_warm"
  last_warm=0
  [[ -f $state_file ]] && last_warm=$(cat "$state_file" 2>/dev/null || echo 0)
  fresh=$(( mtime > last_warm ? mtime : last_warm ))
  age_min=$(( (NOW - fresh) / 60 ))

  if (( age_min < WARM_MIN_AGE || age_min >= WARM_MAX_AGE )); then
    return 0   # comfortably warm, or past the window (cold) — quiet skip
  fi
  if (( NOW - last_warm < RATELIMIT_MIN * 60 )); then
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
  user_idle_min=$(( (NOW - user_epoch) / 60 ))
  if (( user_idle_min > MAX_USER_IDLE_MIN )); then
    log "skip sid=${sid:0:8} age=${age_min}m user-idle=${user_idle_min}m > ${MAX_USER_IDLE_MIN}m: letting cache lapse"
    return 0
  fi

  log "WARM sid=${sid:0:8} age=${age_min}m user-idle=${user_idle_min}m msgs=${user_count} (fork-resume, live session untouched)"
  if (( DRY_RUN )); then
    return 0
  fi
  echo "$NOW" > "$state_file"
  warm_by_fork "$sid" "$cwd" "$live_args" || true
}

# Kill any orphaned fork session left over from a crashed previous run.
if tmux has-session -t "$FORK_TMUX_SESSION" 2>/dev/null; then
  log "note: found leftover $FORK_TMUX_SESSION tmux session; killing it"
  tmux kill-session -t "$FORK_TMUX_SESSION" 2>/dev/null || true
fi

NOW=$(date +%s)

# Discover project dirs of running Claude TUI processes (and authoritative
# --resume sids). Forks and -p/--print processes are never candidates.
declare -A DIR_CWD DIR_ARGS RESUME_SID_ARGS RESUME_SID_CWD
while IFS=$'\t' read -r pid tty comm args; do
  [[ $comm == claude ]] || continue
  [[ $tty != "?" ]] || continue
  case " $args " in
    *" -p "*|*" --print "*) continue ;;
  esac
  [[ $args == *"--fork-session"* ]] && continue

  cwd=$(readlink "/proc/$pid/cwd" 2>/dev/null || true)
  [[ -n $cwd ]] || continue
  project_dir="$HOME/.claude/projects/${cwd//\//-}"
  [[ -d $project_dir ]] || continue
  DIR_CWD[$project_dir]=$cwd
  DIR_ARGS[$project_dir]=$args

  if [[ $args == *"--resume "* ]]; then
    rsid=$(printf '%s\n' "$args" | grep -oE -- '--resume [0-9a-f-]+' | awk '{print $2}' | head -1 || true)
    if [[ -n $rsid ]]; then
      RESUME_SID_ARGS[$rsid]=$args
      RESUME_SID_CWD[$rsid]=$cwd
    fi
  fi
done < <(ps -eo pid=,tty=,comm=,args= --no-headers | awk '{pid=$1; tty=$2; comm=$3; $1=$2=$3=""; sub(/^ +/,""); print pid "\t" tty "\t" comm "\t" $0}')

# Authoritative --resume sessions first (their jsonl may sit outside the cwd dir).
for rsid in "${!RESUME_SID_ARGS[@]}"; do
  jsonl=$(find "$HOME/.claude/projects" -maxdepth 3 -name "${rsid}.jsonl" 2>/dev/null | head -1 || true)
  [[ -n $jsonl ]] && process_candidate "$jsonl" "${RESUME_SID_CWD[$rsid]}" "${RESUME_SID_ARGS[$rsid]}"
done

# Then every session in each active project dir (snapshot the list up front so
# fork jsonls created mid-run are never scanned).
for project_dir in "${!DIR_CWD[@]}"; do
  mapfile -t candidates < <(ls -1 "$project_dir"/*.jsonl 2>/dev/null || true)
  for jsonl in "${candidates[@]}"; do
    process_candidate "$jsonl" "${DIR_CWD[$project_dir]}" "${DIR_ARGS[$project_dir]}"
  done
done

# If our fork session is now empty, remove it.
if tmux has-session -t "$FORK_TMUX_SESSION" 2>/dev/null; then
  if [[ -z $(tmux list-windows -t "$FORK_TMUX_SESSION" -F '#{window_name}' 2>/dev/null) ]]; then
    tmux kill-session -t "$FORK_TMUX_SESSION" 2>/dev/null || true
  fi
fi
