#!/usr/bin/env bash
# cache-warmer v3 — REPLAY-based prompt-cache warmer.
#
# v2 (fork-based, cache-warmer.sh) died on Claude Code v2.1.198: the system
# prompt embeds the session-specific scratchpad path, so a fork's prefix can
# never match its parent's (diagnosis: debug-20260702/, freeze-protocol.md §5).
#
# v3 removes the fork entirely. Sessions launched with
# ANTHROPIC_BASE_URL=http://127.0.0.1:8377 pass through prefix-proxy.js
# (systemd: prefix-proxy.service), which captures each /v1/messages request
# body + headers (auth NEVER persisted) to ~/.cache/prefix-proxy/. To warm a
# session, this script replays its latest captured request BYTE-FOR-BYTE
# (warm-replay.py) with a fresh OAuth token — the exact prefix reads from
# cache (0.1x) and the read refreshes the TTL. No tmux, no TUI automation, no
# fork divergence; immune to config churn and date boundaries by construction.
# Verified 2026-07-02: replay of a 71k-token prefix -> cache_read=71410,
# cache_creation=0.
#
# The conversation session id is recovered from the scratchpad path embedded
# in the captured body — the same string that broke fork-warming.
#
# Config: shares ./config with v2 (ENABLED, WARM_MIN_AGE, WARM_MAX_AGE,
# RATELIMIT_MIN, EXCLUDE_SIDS, INCLUDE_ONLY_SIDS, MISMATCH_COOLDOWN_DAYS).
# v3-specific knobs (config or CW_*-prefixed env overrides for testing):
#   MAX_CAPTURE_AGE_MIN (240)  stop warming once the last real request is old
#   MIN_MSGS (3)               skip one-shot `claude -p` captures
#   PRUNE_HOURS (48)           delete captures older than this
#
# Usage: replay-warmer.sh [--dry-run]
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
CONFIG_FILE="$SCRIPT_DIR/config"
LOG_FILE="$HOME/.claude/logs/cache-warmer.log"
STATE_DIR="$HOME/.cache/cache-warmer-v3"
CAP_DIR="$HOME/.cache/prefix-proxy"
UUID_RE='[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}'
mkdir -p "$STATE_DIR" "$(dirname "$LOG_FILE")"

ENABLED=0
WARM_MIN_AGE=45
WARM_MAX_AGE=58
RATELIMIT_MIN=30
MISMATCH_COOLDOWN_DAYS=3
EXCLUDE_SIDS=''
INCLUDE_ONLY_SIDS=''
MAX_CAPTURE_AGE_MIN=240
MIN_MSGS=3
PRUNE_HOURS=48
# shellcheck disable=SC1090
[[ -f $CONFIG_FILE ]] && source "$CONFIG_FILE"
# Env overrides (testing): CW_<KNOB>
for _n in ENABLED WARM_MIN_AGE WARM_MAX_AGE RATELIMIT_MIN MISMATCH_COOLDOWN_DAYS \
          MAX_CAPTURE_AGE_MIN MIN_MSGS PRUNE_HOURS; do
  _o="CW_$_n"
  [[ -n ${!_o:-} ]] && declare "$_n=${!_o}"
  [[ ${!_n} =~ ^[0-9]+$ ]] || { echo "config error: $_n must be an integer (got '${!_n}')" >&2; exit 2; }
done
[[ -n ${CW_INCLUDE_ONLY_SIDS:-} ]] && INCLUDE_ONLY_SIDS=$CW_INCLUDE_ONLY_SIDS

DRY=0; [[ ${1:-} == --dry-run ]] && DRY=1
log() { printf '[%s] %s\n' "$(date '+%F %T')" "$*" >> "$LOG_FILE"; }

if (( ENABLED != 1 )); then exit 0; fi

# Prune old captures (bodies hold conversation content — keep the window short).
find "$CAP_DIR" -maxdepth 1 -name 'req-*' -mmin +$(( PRUNE_HOURS * 60 )) -delete 2>/dev/null || true

now=$(date +%s)
declare -A NEWEST_FILE NEWEST_MTIME

# Group captures by conversation sid (scratchpad path inside the body).
while IFS= read -r f; do
  [[ $f == *.hdrs.json ]] && continue
  sid=$(grep -aoE "[0-9a-f-]{36}/scratchpad" "$f" 2>/dev/null | head -1 | cut -d/ -f1) || sid=""
  [[ $sid =~ ^${UUID_RE}$ ]] || continue
  [[ -f ${f%.json}.hdrs.json ]] || continue
  m=$(stat -c %Y "$f" 2>/dev/null) || continue
  if [[ -z ${NEWEST_MTIME[$sid]:-} ]] || (( m > NEWEST_MTIME[$sid] )); then
    NEWEST_FILE[$sid]=$f; NEWEST_MTIME[$sid]=$m
  fi
done < <(find "$CAP_DIR" -maxdepth 1 -name 'req-*-msg.json' 2>/dev/null)

for sid in "${!NEWEST_FILE[@]}"; do
  f=${NEWEST_FILE[$sid]}; cap_mtime=${NEWEST_MTIME[$sid]}

  if [[ -n $INCLUDE_ONLY_SIDS && ! $sid =~ $INCLUDE_ONLY_SIDS ]]; then continue; fi
  if [[ -n $EXCLUDE_SIDS && $sid =~ $EXCLUDE_SIDS ]]; then continue; fi

  bl="$STATE_DIR/${sid}.mismatch"
  if [[ -f $bl ]]; then
    bl_age=$(( (now - $(stat -c %Y "$bl" 2>/dev/null || echo "$now")) / 86400 ))
    (( bl_age < MISMATCH_COOLDOWN_DAYS )) && continue
    rm -f "$bl" "$STATE_DIR/${sid}.mismatch_count"
  fi

  cap_age_min=$(( (now - cap_mtime) / 60 ))
  if (( cap_age_min > MAX_CAPTURE_AGE_MIN )); then continue; fi

  # One-shot `claude -p` captures have a single message — not worth warming.
  msgs=$(jq -r '.messages | length' "$f" 2>/dev/null) || msgs=0
  if (( msgs < MIN_MSGS )); then continue; fi

  last_warm=0; [[ -f $STATE_DIR/${sid}.last_warm ]] && last_warm=$(<"$STATE_DIR/${sid}.last_warm")
  [[ $last_warm =~ ^[0-9]+$ ]] || last_warm=0
  last_attempt=0; [[ -f $STATE_DIR/${sid}.last_attempt ]] && last_attempt=$(<"$STATE_DIR/${sid}.last_attempt")
  [[ $last_attempt =~ ^[0-9]+$ ]] || last_attempt=0

  fresh=$(( cap_mtime > last_warm ? cap_mtime : last_warm ))
  age_min=$(( (now - fresh) / 60 ))
  if (( age_min < WARM_MIN_AGE || age_min >= WARM_MAX_AGE )); then continue; fi
  if (( now - last_attempt < RATELIMIT_MIN * 60 )); then continue; fi

  if (( DRY )); then
    log "[dry-run] would replay-warm sid=${sid:0:8} age=${age_min}m cap-age=${cap_age_min}m msgs=$msgs"
    continue
  fi

  printf '%s' "$now" > "$STATE_DIR/${sid}.last_attempt"
  log "WARM sid=${sid:0:8} age=${age_min}m cap-age=${cap_age_min}m msgs=$msgs (replay $(basename "$f"))"
  result=$(python3 "$SCRIPT_DIR/warm-replay.py" "$f" "${f%.json}.hdrs.json" 2>>"$LOG_FILE") || {
    log "RESULT sid=${sid:0:8} FAIL: $(printf '%s' "$result" | head -c 300)"
    continue
  }
  http=$(jq -r '.http // 0' <<<"$result")
  c_read=$(jq -r '.cache_read // 0' <<<"$result")
  c_create=$(jq -r '.cache_creation // 0' <<<"$result")
  if (( http == 200 && c_read > 0 && c_create * 4 < c_read )); then
    printf '%s' "$(date +%s)" > "$STATE_DIR/${sid}.last_warm"
    rm -f "$STATE_DIR/${sid}.mismatch_count"
    log "RESULT sid=${sid:0:8} WARMED cache_read=$c_read cache_creation=$c_create (replay)"
  elif (( http == 200 )); then
    cnt=0; [[ -f $STATE_DIR/${sid}.mismatch_count ]] && cnt=$(<"$STATE_DIR/${sid}.mismatch_count")
    cnt=$((cnt + 1)); printf '%s' "$cnt" > "$STATE_DIR/${sid}.mismatch_count"
    if (( cnt >= 2 )); then
      touch "$bl"
      log "RESULT sid=${sid:0:8} MISMATCH cache_read=$c_read cache_creation=$c_create (2nd) — blacklisting"
    else
      log "RESULT sid=${sid:0:8} MISMATCH cache_read=$c_read cache_creation=$c_create (1st — replay should never mismatch; investigate)"
    fi
  else
    log "RESULT sid=${sid:0:8} FAIL http=$http: $(printf '%s' "$result" | head -c 300)"
  fi
done
