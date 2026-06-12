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
LOG_DIR="$HOME/.claude/logs"
LOG_FILE="$LOG_DIR/cache-warmer.log"
STATE_DIR="$HOME/.cache/cache-warmer"
FORK_ARCHIVE_DIR="$STATE_DIR/forks"
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
    _st=0; [[ "x" =~ ${!_re} ]] || _st=$?
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
user_activity() {
  python3 - "$1" <<'PY'
import json, sys, datetime
marker = "[cache-warmer keepalive]"
last, count = None, 0
try:
    with open(sys.argv[1]) as fh:
        for line in fh:
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
            if not ts:
                continue
            try:
                datetime.datetime.fromisoformat(ts.replace("Z", "+00:00"))
            except Exception:
                continue
            last, count = ts, count + 1
except Exception:
    pass
if last:
    epoch = int(datetime.datetime.fromisoformat(last.replace("Z", "+00:00")).timestamp())
    print(epoch, count)
PY
}

# Usage of the assistant turn that ANSWERS our nonce-tagged keepalive.
# Prints "read creation input" only when that causal pair exists.
fork_usage_for_nonce() {
  python3 - "$1" "$2" <<'PY'
import json, sys
path, nonce = sys.argv[1], sys.argv[2]
seen_nonce = False
u = None
try:
    with open(path) as fh:
        for line in fh:
            try:
                rec = json.loads(line)
            except Exception:
                continue
            if not seen_nonce:
                if rec.get("type") != "user" or "toolUseResult" in rec:
                    continue
                content = (rec.get("message") or {}).get("content")
                text = content if isinstance(content, str) else " ".join(
                    b.get("text", "") for b in (content or []) if isinstance(b, dict))
                if nonce in (text or ""):
                    seen_nonce = True
            else:
                # First real assistant turn after the nonce with usable usage.
                # Skip sidechain turns and usage-less records (e.g. an error
                # turn before a successful retry).
                if rec.get("type") == "assistant" and not rec.get("isSidechain"):
                    cand = (rec.get("message") or {}).get("usage") or {}
                    if any(cand.get(k) for k in ("cache_read_input_tokens",
                                                 "cache_creation_input_tokens", "input_tokens")):
                        u = cand
                        break
except Exception:
    pass
if u:
    print(u.get("cache_read_input_tokens", 0) or 0,
          u.get("cache_creation_input_tokens", 0) or 0,
          u.get("input_tokens", 0) or 0)
PY
}

# Expected prefix size (tokens) = total input of the LIVE session's last
# assistant turn. Used as the denominator to classify fork warm results.
live_expected_tokens() {
  python3 - "$1" <<'PY'
import json, sys
exp = 0
try:
    with open(sys.argv[1]) as fh:
        for line in fh:
            try:
                rec = json.loads(line)
            except Exception:
                continue
            # Skip subagent (sidechain) turns: they share the session file but
            # carry small per-subagent contexts that would skew the baseline.
            if rec.get("type") == "assistant" and not rec.get("isSidechain"):
                u = (rec.get("message") or {}).get("usage") or {}
                t = (u.get("cache_read_input_tokens", 0) or 0) + \
                    (u.get("cache_creation_input_tokens", 0) or 0) + \
                    (u.get("input_tokens", 0) or 0)
                if t > 0:
                    exp = t
except Exception:
    pass
print(exp)
PY
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

# Warm one session by fork. Args: sid, cwd, live_args, live_jsonl. Returns 0
# on verified warm, 1 otherwise. Logs RESULT/FAIL lines itself.
warm_by_fork() {
  local sid=$1 cwd=$2 live_args=$3 live_jsonl=$4
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

  # The fork must request the same cache TTL as the live session. systemd
  # user services do not source shell profiles, so set it explicitly here.
  local spawn_cmd
  spawn_cmd="env -u CLAUDECODE -u CLAUDE_CODE_ENTRYPOINT -u CLAUDE_CODE_SSE_PORT ENABLE_PROMPT_CACHING_1H=1 claude --resume $sid --fork-session$flags"

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

  # Identify the fork jsonl by CONTENT: exactly one file in the project dir,
  # created/modified after spawn, containing our nonce. Directory-diff
  # heuristics can misidentify a real user session — never trust them.
  waited=0
  local fork_jsonl="" usage="" matches match_count
  while (( waited < FORK_REPLY_TIMEOUT )); do
    sleep 5; waited=$((waited+5))
    if [[ -z $fork_jsonl ]]; then
      matches=$(find "$project_dir" -maxdepth 1 -name '*.jsonl' -newermt "@$spawn_epoch" \
                  -exec grep -l -F "run=${nonce}" {} + 2>/dev/null || true)
      match_count=$(printf '%s\n' "$matches" | grep -c . || true)
      if [[ $match_count -eq 1 ]]; then
        fork_jsonl=$matches
      fi
    fi
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
  else
    # Classify against the LIVE session's expected prefix size, not just the
    # fork request's own total — this distinguishes a diverged prefix from a
    # request that simply didn't carry the full history.
    local c_read c_create c_in total expected klass strike=0
    read -r c_read c_create c_in <<< "$usage"
    total=$(( c_read + c_create + c_in ))
    expected=$(live_expected_tokens "$live_jsonl" || echo 0)
    [[ $expected =~ ^[0-9]+$ ]] || expected=0
    if (( expected <= 0 )); then
      # No baseline available; fall back to the request-relative check.
      if (( total > 0 && c_read * 2 >= total )); then klass=verified_hit_no_baseline; rc=0; else klass=mismatch_no_baseline; strike=1; fi
    elif (( total * 2 < expected )); then
      # Fork request is far smaller than the live prefix — it did not replay
      # the same context (wrong session, heavy divergence, or fork-side
      # compaction). TTL on the live prefix was NOT meaningfully re-armed.
      klass=short_request; strike=1
    elif (( c_read * 10 >= expected * 8 )); then
      klass=verified_full_hit; rc=0
    elif (( c_read * 5 >= expected )); then
      # Matched the first part of the prefix, diverged mid-way. The matched
      # depth is re-armed, the tail is not. Deterministic — will recur.
      klass=partial_hit; strike=1
    else
      # Near-zero read with a full-size request: either the prefix diverged
      # at the root, or the cache was already cold (shouldn't happen inside
      # the warm window if the TTL model is right). Either way the live
      # prefix is now written warm by this fork only if the prefixes match —
      # which we can't confirm, so treat as a strike.
      klass=cold_or_mismatch; strike=1
    fi
    if (( rc == 0 )); then
      log "RESULT sid=${sid:0:8} WARMED class=$klass cache_read=$c_read cache_creation=$c_create expected=$expected nonce=${nonce:0:8}"
      rm -f "$mismatch_file"
    else
      local miss_n
      miss_n=$(read_int_state "$mismatch_file")
      miss_n=$((miss_n + 1))
      write_state "$mismatch_file" "$miss_n"
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

# Evaluate one candidate session; warm it if due. Args: jsonl, cwd, live_args.
declare -A SEEN_SID
process_candidate() {
  local jsonl=$1 cwd=$2 live_args=$3
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

  log "WARM sid=${sid:0:8} age=${age_min}m user-idle=${user_idle_min}m msgs=${user_count} (fork-resume, live session untouched)"
  if (( DRY_RUN )); then
    return 0
  fi
  write_state "$STATE_DIR/${sid}.last_attempt" "$(date +%s)"
  if warm_by_fork "$sid" "$cwd" "$live_args" "$jsonl"; then
    write_state "$STATE_DIR/${sid}.last_warm" "$(date +%s)"
  fi
}

# Discover project dirs of running Claude TUI processes (and authoritative
# --resume sids). Forks and -p/--print processes are never candidates.
declare -A DIR_CWD DIR_ARGS RESUME_SID_ARGS RESUME_SID_CWD
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
  DIR_CWD[$project_dir]=$cwd
  DIR_ARGS[$project_dir]=$args

  if [[ $args == *"--resume "* ]]; then
    rsid=$(printf '%s\n' "$args" | grep -oE -- '--resume [0-9a-f-]+' | awk '{print $2}' | head -1 || true)
    if [[ -n $rsid && $rsid =~ $UUID_RE ]]; then
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

# Then recent sessions in each active project dir (snapshot the list up front
# so fork jsonls created mid-run are never scanned; cap at the 10 newest to
# bound cost). NOTE: this is heuristic — the warmer cannot prove which jsonl
# belongs to which live TUI, so it may warm a recently-active session in the
# same dir that no one returns to. The MIN_USER_MSGS, user-idle, and
# warm-window gates bound that cost; RESULT receipts make it visible.
for project_dir in "${!DIR_CWD[@]}"; do
  mapfile -t candidates < <(ls -1t "$project_dir"/*.jsonl 2>/dev/null | head -10 || true)
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
