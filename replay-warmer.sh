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
#   PRUNE_HOURS (6)            delete captures older than this (also
#                              enforced by prefix-proxy.js, independent of ENABLED)
#
# Usage: replay-warmer.sh [--dry-run]
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# CW_CONFIG lets the test suite point at a hermetic config instead of the
# maintainer's real one (which is gitignored and box-specific).
CONFIG_FILE=${CW_CONFIG:-"$SCRIPT_DIR/config"}
LOG_FILE="$HOME/.claude/logs/cache-warmer.log"
STATE_DIR="$HOME/.cache/cache-warmer-v3"
UUID_RE='[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}'

usage() {
  cat <<'USAGE'
Usage: replay-warmer.sh [--dry-run]

  (no argument)  warm eligible sessions
  --dry-run      report what WOULD be warmed; touch nothing
  -h, --help     this text
USAGE
}

# Strict argument parsing, BEFORE any side effect (bq-320). The old test was
# `[[ ${1:-} == --dry-run ]] && DRY=1` with no rejection, so `--dryrun`,
# `--dry-run=true`, or any other typo silently fell through to a LIVE run —
# the exact opposite of what the operator asked for, on a tool that spends
# money. Anything not recognised exits 2 before a single file is touched.
DRY=0
case ${1:-} in
  '') ;;
  --dry-run) DRY=1 ;;
  -h | --help)
    usage
    exit 0
    ;;
  *)
    echo "replay-warmer.sh: unknown argument '$1'" >&2
    usage >&2
    exit 2
    ;;
esac
if (($# > 1)); then
  echo "replay-warmer.sh: too many arguments (got $#)" >&2
  usage >&2
  exit 2
fi

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
MAX_JITTER=45  # seconds; 0..MAX_JITTER of jitter between warms in one run
# ONE capture-store setting, shared with prefix-proxy.js (bq-318). The two
# halves used to default independently — the proxy to /tmp/prefix-proxy, this
# script to ~/.cache/prefix-proxy — so both could report success while the
# warmer scanned a directory nothing had ever written to.
CAPTURE_DIR="$HOME/.cache/prefix-proxy"
PRUNE_HOURS=6   # captures are only warm-eligible for MAX_CAPTURE_AGE_MIN; don't retain bodies longer
# shellcheck disable=SC1090
[[ -f $CONFIG_FILE ]] && source "$CONFIG_FILE"
# Env overrides (testing): CW_<KNOB>
for _n in ENABLED WARM_MIN_AGE WARM_MAX_AGE RATELIMIT_MIN MISMATCH_COOLDOWN_DAYS \
          MAX_CAPTURE_AGE_MIN MIN_MSGS PRUNE_HOURS MAX_JITTER; do
  _o="CW_$_n"
  [[ -n ${!_o:-} ]] && declare "$_n=${!_o}"
  [[ ${!_n} =~ ^[0-9]+$ ]] || { echo "config error: $_n must be an integer (got '${!_n}')" >&2; exit 2; }
done
[[ -n ${CW_INCLUDE_ONLY_SIDS:-} ]] && INCLUDE_ONLY_SIDS=$CW_INCLUDE_ONLY_SIDS
CAP_DIR=${CW_CAPTURE_DIR:-$CAPTURE_DIR}
[[ -n ${CW_EXCLUDE_SIDS:-} ]] && EXCLUDE_SIDS=$CW_EXCLUDE_SIDS

# Validate both session-id regexes at startup, exactly as the v2 engine does
# (cache-warmer.sh:72-83), and BEFORE pruning or replaying anything (bq-316).
# Bash's `=~` returns status 2 when the pattern does not COMPILE and 1 when it
# compiles but does not match. Inside `if [[ ... ]]` both read as "false", so a
# malformed EXCLUDE_SIDS silently became "excludes nothing" and the warmer
# replayed the very sessions the operator had ruled out — a fail-OPEN on a knob
# whose only purpose is to keep a session's conversation off the wire.
for _re in EXCLUDE_SIDS INCLUDE_ONLY_SIDS; do
  if [[ -n ${!_re} ]]; then
    _st=0
    # SC2319: capturing the [[ ]] regex-compile status is exactly the intent —
    # status 2 means the regex itself is invalid (vs 1 = valid but no match).
    # shellcheck disable=SC2319
    [[ "x" =~ ${!_re} ]] || _st=$?
    (( _st >= 2 )) && { echo "config error: $_re is not a valid regex" >&2; exit 2; }
  fi
done

log() { printf '[%s] %s\n' "$(date '+%F %T')" "$*" >> "$LOG_FILE"; }

# A failed replay (401/5xx/network) never touched the cache, so counting it
# against RATELIMIT_MIN pushes the retry past WARM_MAX_AGE and permanently
# breaks the sid's TTL chain (debug-20260702/FINDINGS.md, "Incident: 04:24
# 401s"). Restore the pre-attempt last_attempt so the next timer tick can
# retry while the warm window is still open — at most 2 rollbacks per failure
# streak; the counter resets on any HTTP 200.
note_fail() {
  local sid=$1 prev=$2 fails=0
  [[ -f $STATE_DIR/$sid.fail_count ]] && fails=$(<"$STATE_DIR/$sid.fail_count")
  [[ $fails =~ ^[0-9]+$ ]] || fails=0
  fails=$((fails + 1)); printf '%s' "$fails" > "$STATE_DIR/$sid.fail_count"
  if (( fails <= 2 )); then
    printf '%s' "$prev" > "$STATE_DIR/$sid.last_attempt"
    log "RETRY sid=${sid:0:8}: rolled back last_attempt (fail #$fails) — next tick may retry"
  else
    log "GIVEUP sid=${sid:0:8}: fail #$fails — keeping rate-limit cooldown"
  fi
}

# Prune old captures (bodies hold conversation content — keep the window
# short). This runs BEFORE the ENABLED gate and matches BOTH capture prefixes:
# promoted `req-*` and crash-leftover `pending-*` (bq-314). Retention that only
# ran when warming was enabled left full conversations on disk indefinitely on
# any box where the operator set ENABLED=0. prefix-proxy.js sweeps the same
# store on its own timer, so retention survives this script never running at
# all; this pass is the belt to the proxy's braces.
prune_captures() {
  find "$CAP_DIR" -maxdepth 1 \( -name 'req-*' -o -name 'pending-*' \) \
    -mmin +$(( PRUNE_HOURS * 60 )) -delete 2>/dev/null || true
}
# --dry-run means "change nothing", and pruning is a deletion (bq-320).
(( DRY )) || prune_captures

if (( ENABLED != 1 )); then exit 0; fi

# An enabled warmer that cannot read its store is NOT a quiet no-op (bq-318):
# it used to exit 0 having done nothing, so a store/proxy mismatch looked
# exactly like "no sessions were due".
if [[ ! -d $CAP_DIR || ! -r $CAP_DIR ]]; then
  log "DEGRADED: capture store $CAP_DIR is missing or unreadable — is prefix-proxy.service writing somewhere else?"
  echo "replay-warmer.sh: capture store $CAP_DIR is missing or unreadable" >&2
  exit 1
fi

now=$(date +%s)
declare -A NEWEST_FILE NEWEST_MTIME

# Group captures by conversation sid (scratchpad path inside the body), while
# counting how many RECENT captures exist versus how many are actually usable —
# a capture with no recoverable sid or no header sidecar cannot be replayed, and
# silently skipping every one of them is indistinguishable from having nothing
# to do (bq-318).
recent_caps=0
attributable=0
while IFS= read -r f; do
  [[ $f == *.hdrs.json ]] && continue
  m=$(stat -c %Y "$f" 2>/dev/null) || continue
  recent=0
  (( (now - m) / 60 <= MAX_CAPTURE_AGE_MIN )) && recent=1
  (( recent )) && recent_caps=$((recent_caps + 1))
  sid=$(grep -aoE "[0-9a-f-]{36}/scratchpad" "$f" 2>/dev/null | head -1 | cut -d/ -f1) || sid=""
  [[ $sid =~ ^${UUID_RE}$ ]] || continue
  [[ -f ${f%.json}.hdrs.json ]] || continue
  (( recent )) && attributable=$((attributable + 1))
  if [[ -z ${NEWEST_MTIME[$sid]:-} ]] || (( m > NEWEST_MTIME[$sid] )); then
    NEWEST_FILE[$sid]=$f; NEWEST_MTIME[$sid]=$m
  fi
done < <(find "$CAP_DIR" -maxdepth 1 -name 'req-*-msg.json' 2>/dev/null)

if (( recent_caps > 0 && attributable == 0 )); then
  log "DEGRADED: $recent_caps recent capture(s) in $CAP_DIR but NONE readable+attributable (no session id recovered, or no .hdrs.json sidecar) — nothing can be warmed"
  echo "replay-warmer.sh: $recent_caps recent capture(s) in $CAP_DIR, none usable" >&2
  exit 1
fi

for sid in "${!NEWEST_FILE[@]}"; do
  f=${NEWEST_FILE[$sid]}; cap_mtime=${NEWEST_MTIME[$sid]}

  # Re-read the clock for EVERY candidate (bq-317). One run-wide `now` aged
  # every session as of run start, but a single earlier candidate can hold the
  # loop for up to MAX_JITTER seconds of jitter plus a replay that may block on
  # warm-replay.py's 180 s socket timeout — so by the time a later candidate is
  # evaluated, the timestamp it is judged against can be minutes stale.
  now=$(date +%s)

  if [[ -n $INCLUDE_ONLY_SIDS && ! $sid =~ $INCLUDE_ONLY_SIDS ]]; then continue; fi
  if [[ -n $EXCLUDE_SIDS && $sid =~ $EXCLUDE_SIDS ]]; then continue; fi

  bl="$STATE_DIR/${sid}.mismatch"
  if [[ -f $bl ]]; then
    bl_age=$(( (now - $(stat -c %Y "$bl" 2>/dev/null || echo "$now")) / 86400 ))
    (( bl_age < MISMATCH_COOLDOWN_DAYS )) && continue
    (( DRY )) || rm -f "$bl" "$STATE_DIR/${sid}.mismatch_count"
  fi

  cap_age_min=$(( (now - cap_mtime) / 60 ))
  if (( cap_age_min > MAX_CAPTURE_AGE_MIN )); then continue; fi

  # Count HUMAN turns, not API messages (bq-319). `.messages | length` counted
  # the whole array — assistant tool_use turns and the user-role tool_result
  # turns that answer them included — so a one-shot `claude -p` job that made
  # two tool calls presented as five messages and sailed straight through the
  # gate that docs/V3-DIAGNOSIS.md claims filters exactly those captures. The
  # predicate mirrors lib/jsonl.py's `_is_real_user_text`: role user, and
  # content that is either plain text or a block list carrying no tool_result.
  msgs=$(jq -r '
      [ (.messages // [])[]
        | select(.role == "user")
        | select((.content | type) == "string"
                 or ([ (.content // [])[]
                       | select(type == "object" and .type == "tool_result") ] | length) == 0)
      ] | length' "$f" 2>/dev/null) || msgs=0
  [[ $msgs =~ ^[0-9]+$ ]] || msgs=0
  if (( msgs < MIN_MSGS )); then continue; fi

  # SERVER-executed tools (web_search, web_fetch, code_execution, hosted MCP)
  # would be re-run on Anthropic's infrastructure by a replay — refuse to warm
  # such captures (GPT-5.5-Pro review P0).
  server_tools=$(jq -r '
      ([.tools // [] | .[] | .type // ""]
       | map(select(test("web_search|web_fetch|code_execution")))
       | length)
      + (if .mcp_servers then 1 else 0 end)' "$f" 2>/dev/null) || server_tools=1
  if [[ ! $server_tools =~ ^[0-9]+$ ]] || (( server_tools > 0 )); then
    log "skip sid=${sid:0:8}: capture declares server-side tools (replay would re-execute them)"
    continue
  fi

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

  # Jitter FIRST, then re-check the window and stamp last_attempt with the
  # actual dispatch time (bq-317). The old order slept up to 45 s after passing
  # the gate and then dispatched unconditionally, so a warm could leave at an
  # age the gate would have rejected — and recorded the run-start timestamp as
  # its attempt time, which makes the RATELIMIT_MIN spacing wrong in the
  # permissive direction by however long the run took.
  jitter=${CW_JITTER_SECONDS:-$(( RANDOM % (MAX_JITTER + 1) ))}
  [[ $jitter =~ ^[0-9]+$ ]] || jitter=0
  sleep "$jitter"   # so multi-session warms don't fire as a burst

  now=$(date +%s)
  age_min=$(( (now - fresh) / 60 ))
  if (( age_min < WARM_MIN_AGE || age_min >= WARM_MAX_AGE )); then
    log "skip sid=${sid:0:8}: warm window closed during the run (age=${age_min}m, jitter=${jitter}s)"
    continue
  fi

  printf '%s' "$now" > "$STATE_DIR/${sid}.last_attempt"
  log "WARM sid=${sid:0:8} age=${age_min}m cap-age=${cap_age_min}m msgs=$msgs jitter=${jitter}s (replay $(basename "$f"))"
  rc=0
  result=$(python3 "$SCRIPT_DIR/warm-replay.py" "$f" "${f%.json}.hdrs.json" 2>>"$LOG_FILE") || rc=$?
  if (( rc == 3 )); then
    # warm-replay refused to send an UNCAPPED replay (bq-315). That is a
    # property of this capture's body, not a transient failure — retrying it
    # inside the warm window would refuse identically, so do NOT roll back
    # last_attempt the way note_fail does for 401/5xx blips.
    log "RESULT sid=${sid:0:8} REFUSED uncapped: $(jq -r '.cap_reason // "?"' <<<"$result" 2>/dev/null)"
    continue
  fi
  if (( rc != 0 )); then
    log "RESULT sid=${sid:0:8} FAIL: $(printf '%s' "$result" | head -c 300)"
    note_fail "$sid" "$last_attempt"
    continue
  fi
  http=$(jq -r '.http // 0' <<<"$result")
  (( http == 200 )) && rm -f "$STATE_DIR/${sid}.fail_count"
  c_read=$(jq -r '.cache_read // 0' <<<"$result")
  c_create=$(jq -r '.cache_creation // 0' <<<"$result")
  if (( http == 200 && c_read > 0 && c_create * 4 < c_read )); then
    printf '%s' "$(date +%s)" > "$STATE_DIR/${sid}.last_warm"
    rm -f "$STATE_DIR/${sid}.mismatch_count"
    log "RESULT sid=${sid:0:8} WARMED cache_read=$c_read cache_creation=$c_create out=$(jq -r '.output_tokens // "aborted"' <<<"$result") cap=$(jq -r '.cap // "none"' <<<"$result") (replay)"
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
    note_fail "$sid" "$last_attempt"
  fi
done
