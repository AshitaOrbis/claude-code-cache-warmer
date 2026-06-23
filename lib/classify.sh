# shellcheck shell=bash
# Pure classification logic for cache-warmer.sh, extracted so it can be unit
# tested without forking a live session (BACKLOG cw-4). No side effects, no
# globals — reads its inputs as args, prints "<class> <rc> <strike>".
#
# Source this file, then call:
#   read -r klass rc strike < <(classify_warm "$c_read" "$c_create" "$c_in" "$expected")
#
# Classification matches the original inline block in warm_by_fork exactly:
#   rc=0  -> verified warm (cache TTL re-armed); strike=0
#   rc=1  -> not a clean warm; strike=1 contributes to the mismatch blacklist
#
# Args: cache_read cache_creation input_tokens expected
#   expected = the LIVE session's post-compaction prefix size (0 = no baseline)
classify_warm() {
  local c_read=$1 c_create=$2 c_in=$3 expected=$4
  local total klass rc=1 strike=0
  total=$((c_read + c_create + c_in))
  [[ $expected =~ ^[0-9]+$ ]] || expected=0
  if ((expected <= 0)); then
    # No baseline available; fall back to the request-relative check.
    if ((total > 0 && c_read * 2 >= total)); then
      klass=verified_hit_no_baseline
      rc=0
    else
      klass=mismatch_no_baseline
      strike=1
    fi
  elif ((total * 2 < expected)); then
    # Fork request is far smaller than the live prefix — it did not replay the
    # same context (wrong session, heavy divergence, or fork-side compaction).
    # TTL on the live prefix was NOT meaningfully re-armed.
    klass=short_request
    strike=1
  elif ((c_read * 10 >= expected * 8)); then
    klass=verified_full_hit
    rc=0
  elif ((c_read * 5 >= expected)); then
    # Matched the first part of the prefix, diverged mid-way. The matched depth
    # is re-armed, the tail is not. Deterministic — will recur.
    klass=partial_hit
    strike=1
  else
    # Near-zero read with a full-size request: prefix diverged at the root, or
    # the cache was already cold. Either way, treat as a strike.
    klass=cold_or_mismatch
    strike=1
  fi
  printf '%s %s %s\n' "$klass" "$rc" "$strike"
}
