#!/usr/bin/env bash
# cache-warmer v3 — REPLAY-based prompt-cache warmer.
#
# v2 (fork-based, cache-warmer.sh) died on Claude Code v2.1.198: the system
# prompt embeds the session-specific scratchpad path, so a fork's prefix can
# never match its parent's (diagnosis: debug-20260702/, freeze-protocol.md §5).
#
# v3 removes the fork entirely. Sessions launched with
# ANTHROPIC_BASE_URL=http://127.0.0.1:8377 pass through prefix-proxy.js
# (systemd: prefix-proxy.service), which captures eligible /v1/messages request
# bodies + headers to ~/.cache/prefix-proxy/; credential-looking transport
# headers and mcp_servers[].authorization_token are never persisted. To warm a
# session, this script replays its latest capture with a fresh OAuth token while
# preserving cache-key-bearing prefix bytes (warm-replay.py) — the prefix reads from
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
#   MIN_CACHE_READ_PCT (80)     minimum cached share of total request input
#   REPLAY_RETRIES (2)          bounded retries after a non-refusal replay failure
#   RETRY_BACKOFF_SECONDS (2)   delay before each in-process retry
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
if (($# > 1)); then
  echo "replay-warmer.sh: too many arguments (got $#)" >&2
  usage >&2
  exit 2
fi
if (($# == 1)); then
  case $1 in
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
MIN_CACHE_READ_PCT=80
REPLAY_RETRIES=2
RETRY_BACKOFF_SECONDS=2
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
          MAX_CAPTURE_AGE_MIN MIN_MSGS PRUNE_HOURS MAX_JITTER MIN_CACHE_READ_PCT \
          REPLAY_RETRIES RETRY_BACKOFF_SECONDS; do
  _o="CW_$_n"
  [[ -n ${!_o:-} ]] && declare "$_n=${!_o}"
  [[ ${!_n} =~ ^[0-9]+$ ]] || { echo "config error: $_n must be an integer (got '${!_n}')" >&2; exit 2; }
  # Decimal, always. Bash arithmetic reads a leading zero as octal while jq's
  # --argjson reads the same text as decimal, so MIN_CACHE_READ_PCT=0120 passed
  # the range check below as 80 and then failed every receipt as 120.
  declare "$_n=$((10#${!_n}))"
done
(( MIN_CACHE_READ_PCT >= 80 && MIN_CACHE_READ_PCT <= 100 )) \
  || { echo "config error: MIN_CACHE_READ_PCT must be between 80 and 100" >&2; exit 2; }
(( REPLAY_RETRIES <= 2 )) \
  || { echo "config error: REPLAY_RETRIES must be between 0 and 2" >&2; exit 2; }
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

# A failed replay (non-200/network) did not produce a verified warm, so counting it
# against RATELIMIT_MIN pushes the retry past WARM_MAX_AGE and permanently
# breaks the sid's TTL chain (debug-20260702/FINDINGS.md, "Incident: 04:24
# 401s"). Restore the pre-attempt last_attempt so an immediate in-process retry
# remains eligible while the warm window is still open — at most 2 rollbacks
# per persisted failure streak; the counter resets on any HTTP 200.
note_fail() {
  local sid=$1 prev=$2 fails=0
  [[ -f $STATE_DIR/$sid.fail_count ]] && fails=$(<"$STATE_DIR/$sid.fail_count")
  [[ $fails =~ ^[0-9]+$ ]] || fails=0
  fails=$((fails + 1)); printf '%s' "$fails" > "$STATE_DIR/$sid.fail_count"
  if (( fails <= 2 )); then
    printf '%s' "$prev" > "$STATE_DIR/$sid.last_attempt"
    log "RETRY sid=${sid:0:8}: rolled back last_attempt (fail #$fails) — immediate retry remains eligible"
  else
    log "GIVEUP sid=${sid:0:8}: fail #$fails — keeping rate-limit cooldown"
  fi
  FAIL_STREAK=$fails
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
declare -A NEWEST_FILE NEWEST_MTIME NEWEST_ORDER_MS NEWEST_ORDER_SEQ NEWEST_ORDER_NAME

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
  # Capture filenames carry millisecond time plus a per-process sequence. `%Y`
  # has only whole-second resolution, so it cannot order a fast pair reliably
  # (bq-1200). Legacy names fall back to mtime with a zero sequence.
  name=$(basename "$f")
  order_ms=$((m * 1000)); order_seq=0
  if [[ $name =~ ^req-([0-9]{1,16})-([0-9]{1,9})-msg\.json$ ]]; then
    order_ms=$((10#${BASH_REMATCH[1]}))
    order_seq=$((10#${BASH_REMATCH[2]}))
  fi
  if [[ -z ${NEWEST_ORDER_MS[$sid]:-} ]] \
    || (( order_ms > NEWEST_ORDER_MS[$sid] )) \
    || { (( order_ms == NEWEST_ORDER_MS[$sid] && order_seq > NEWEST_ORDER_SEQ[$sid] )); } \
    || { (( order_ms == NEWEST_ORDER_MS[$sid] && order_seq == NEWEST_ORDER_SEQ[$sid] )) \
         && [[ $name > ${NEWEST_ORDER_NAME[$sid]} ]]; }; then
    NEWEST_FILE[$sid]=$f
    NEWEST_MTIME[$sid]=$m
    NEWEST_ORDER_MS[$sid]=$order_ms
    NEWEST_ORDER_SEQ[$sid]=$order_seq
    NEWEST_ORDER_NAME[$sid]=$name
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
  # The array type-check is load-bearing: jq iterates an OBJECT's values too, so
  # `{"messages":{"a":{"role":"user"...},"b":...}}` counted three human turns off
  # a body that has no messages array at all (Sol review, 2026-08-21).
  msgs=$(jq -r '
      if (.messages | type) != "array" then 0 else
      [ .messages[]
        | select(type == "object" and .role == "user")
        | select((.content | type) == "string"
                 or ([ (.content // [])[]
                       | select(type == "object" and .type == "tool_result") ] | length) == 0)
      ] | length end' "$f" 2>/dev/null) || msgs=0
  [[ $msgs =~ ^[0-9]+$ ]] || msgs=0
  if (( msgs < MIN_MSGS )); then continue; fi

  # Typed tools fail closed. Untyped user-defined tools and the exact known
  # client-executed built-ins are safe because no client tool loop runs here;
  # every server/unknown type (including advisor and tool-search families) is
  # refused rather than maintained as a porous substring denylist (bq-1255).
  server_tools=$(jq -r '
      ([ (.tools // [])
         | if type != "array" then error("tools is not an array") else .[] end
         | if type != "object" then error("tool is not an object")
           elif has("type") | not then empty
           else .type as $tool_type
             | select(($tool_type | type) != "string"
                      or (["bash_20241022", "bash_20250124",
                           "computer_20241022", "computer_20250124", "computer_20251124",
                           "text_editor_20241022", "text_editor_20250124",
                           "text_editor_20250429", "text_editor_20250728",
                           "memory_20250818"] | index($tool_type)) == null)
           end ] | length)
      + (if has("mcp_servers") then 1 else 0 end)' "$f" 2>/dev/null) || server_tools=1
  if [[ ! $server_tools =~ ^[0-9]+$ ]] || (( server_tools > 0 )); then
    log "skip sid=${sid:0:8}: capture declares server-side or unknown typed tools (replay refused)"
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

  # A 10-minute timer cannot provide a second chance near the far edge of a
  # 13-minute warm window. Retry non-refusal failures in-process, bounded by both
  # a three-failure streak and a fresh deadline check before every request
  # (bq-1020).
  attempt=0
  replay_succeeded=0
  replay_refused=0
  while (( attempt <= REPLAY_RETRIES )); do
    if (( attempt > 0 )); then sleep "$RETRY_BACKOFF_SECONDS"; fi

    now=$(date +%s)
    age_min=$(( (now - fresh) / 60 ))
    if (( age_min < WARM_MIN_AGE || age_min >= WARM_MAX_AGE )); then
      log "skip sid=${sid:0:8}: retry window closed before dispatch (age=${age_min}m, attempt=$((attempt + 1)))"
      break
    fi

    printf '%s' "$now" > "$STATE_DIR/${sid}.last_attempt"
    log "WARM sid=${sid:0:8} age=${age_min}m cap-age=${cap_age_min}m msgs=$msgs jitter=${jitter}s attempt=$((attempt + 1))/$((REPLAY_RETRIES + 1)) (replay $(basename "$f"))"
    rc=0
    result=$(python3 "$SCRIPT_DIR/warm-replay.py" "$f" "${f%.json}.hdrs.json" 2>>"$LOG_FILE") || rc=$?
    if (( rc == 3 )); then
      # Request or response shape could not prove a bounded completion. Do not
      # retry it in this run, and do not mislabel a capped response refusal as
      # "uncapped" (bq-315/1259/1389).
      refusal=$(jq -r '[.error // "output_bound_refused", .detail // .cap_reason // "?"] | @tsv' \
        <<<"$result" 2>/dev/null) || refusal="output_bound_refused\t?"
      log "RESULT sid=${sid:0:8} REFUSED output-bound: $refusal"
      replay_refused=1
      break
    fi

    http=$(jq -r 'if (.http | type) == "number" and .http == (.http | floor) then .http else 0 end' \
      <<<"$result" 2>/dev/null) || http=0
    if (( rc == 0 && http == 200 )); then
      rm -f "$STATE_DIR/${sid}.fail_count"
      replay_succeeded=1
      break
    fi

    if (( rc != 0 )); then
      log "RESULT sid=${sid:0:8} FAIL: $(printf '%s' "$result" | head -c 300)"
    else
      log "RESULT sid=${sid:0:8} FAIL http=$http: $(printf '%s' "$result" | head -c 300)"
    fi
    note_fail "$sid" "$last_attempt"
    (( FAIL_STREAK >= 3 || attempt >= REPLAY_RETRIES )) && break
    log "RETRY sid=${sid:0:8}: retrying in ${RETRY_BACKOFF_SECONDS}s while the warm window remains open"
    attempt=$((attempt + 1))
  done

  (( replay_refused )) && continue
  (( replay_succeeded )) || continue

  # Missing/malformed counters are -1, never an optimistic zero. Limit values
  # to JSON's exact-integer range so the Bash ratio arithmetic cannot overflow.
  usage_tsv=$(jq -L "$SCRIPT_DIR/lib" -r 'include "receipt"; usage_counters | @tsv' \
    <<<"$result" 2>/dev/null) || usage_tsv=$'-1\t-1\t-1'
  IFS=$'\t' read -r c_read c_create input_tokens <<<"$usage_tsv"
  total_input=$((c_read + c_create + input_tokens))
  coverage_pct=0
  (( total_input > 0 && c_read >= 0 )) && coverage_pct=$((c_read * 100 / total_input))

  # Match v2's verified-full-hit rule: cached tokens must cover at least 80% of
  # ALL input (read + creation + uncached). A one-token read beside a huge cold
  # input is PARTIAL and must never advance freshness (bq-1256/1319/1390).
  if jq -L "$SCRIPT_DIR/lib" -e --argjson threshold "$MIN_CACHE_READ_PCT" \
    'include "receipt"; full_hit($threshold)' <<<"$result" >/dev/null; then
    printf '%s' "$(date +%s)" > "$STATE_DIR/${sid}.last_warm"
    rm -f "$STATE_DIR/${sid}.mismatch_count"
    log "RESULT sid=${sid:0:8} WARMED coverage=${coverage_pct}% cache_read=$c_read cache_creation=$c_create input_tokens=$input_tokens out=$(jq -r '.output_tokens // "aborted"' <<<"$result") cap=$(jq -r '.cap // "none"' <<<"$result") (replay)"
  else
    cnt=0; [[ -f $STATE_DIR/${sid}.mismatch_count ]] && cnt=$(<"$STATE_DIR/${sid}.mismatch_count")
    [[ $cnt =~ ^[0-9]+$ ]] || cnt=0
    cnt=$((cnt + 1)); printf '%s' "$cnt" > "$STATE_DIR/${sid}.mismatch_count"
    result_class=MISMATCH
    (( c_read > 0 && c_create >= 0 && input_tokens >= 0 && total_input > 0 )) \
      && result_class=PARTIAL
    if (( cnt >= 2 )); then
      touch "$bl"
      log "RESULT sid=${sid:0:8} $result_class coverage=${coverage_pct}% threshold=${MIN_CACHE_READ_PCT}% cache_read=$c_read cache_creation=$c_create input_tokens=$input_tokens (2nd) — blacklisting"
    else
      log "RESULT sid=${sid:0:8} $result_class coverage=${coverage_pct}% threshold=${MIN_CACHE_READ_PCT}% cache_read=$c_read cache_creation=$c_create input_tokens=$input_tokens (1st — freshness NOT advanced)"
    fi
  fi
done
