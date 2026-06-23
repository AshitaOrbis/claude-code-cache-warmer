#!/usr/bin/env bash
# Self-contained test runner for cache-warmer's core logic. No external test
# framework — just assert helpers — so CI needs only bash + python3 + jq
# (the same deps the tool itself requires). Exercises the parsing/classification
# logic that decides whether to fork a live session and how to score the result;
# it never spawns a real Claude session (that path is integration-only).
#
#   tests/run.sh          # run all tests, exit non-zero on any failure
set -euo pipefail

TESTS_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_DIR=$(cd "$TESTS_DIR/.." && pwd)
LIB_DIR="$REPO_DIR/lib"
JSONL_PY="$LIB_DIR/jsonl.py"
FIX="$TESTS_DIR/fixtures"

# shellcheck source=../lib/classify.sh
source "$LIB_DIR/classify.sh"

PASS=0
FAIL=0

# Group label printed before a block of assertions.
describe() {
  printf '\n# %s\n' "$1"
}

# assert_eq <description> <expected> <actual>
assert_eq() {
  local desc=$1 want=$2 got=$3
  if [[ $want == "$got" ]]; then
    PASS=$((PASS + 1))
    printf '  ok   %s\n' "$desc"
  else
    FAIL=$((FAIL + 1))
    printf '  FAIL %s\n       expected: [%s]\n       actual:   [%s]\n' "$desc" "$want" "$got"
  fi
}

# assert_status <description> <expected_exit> <cmd...>
assert_status() {
  local desc=$1 want=$2
  shift 2
  local got=0
  "$@" >/dev/null 2>&1 || got=$?
  if [[ $want == "$got" ]]; then
    PASS=$((PASS + 1))
    printf '  ok   %s\n' "$desc"
  else
    FAIL=$((FAIL + 1))
    printf '  FAIL %s\n       expected exit: %s, actual: %s\n' "$desc" "$want" "$got"
  fi
}

ua() { python3 "$JSONL_PY" user-activity "$1"; }
fu() { python3 "$JSONL_PY" fork-usage "$1" "$2"; }
exp() { python3 "$JSONL_PY" expected-tokens "$1"; }
sc() { python3 "$JSONL_PY" submit-confirmed "$1" "$2"; }

epoch_of() {
  python3 -c "import datetime,sys;print(int(datetime.datetime.fromisoformat(sys.argv[1]).timestamp()))" "$1"
}

# ---------------------------------------------------------------------------
describe "user-activity: counts real user messages, skips meta/tool/keepalive"
assert_eq "live: epoch+count of last real user msg" \
  "$(epoch_of 2026-06-22T10:06:00+00:00) 2" "$(ua "$FIX/live_session.jsonl")"
assert_eq "headless one-shot: single real user msg" \
  "$(epoch_of 2026-06-22T11:00:00+00:00) 1" "$(ua "$FIX/headless_oneshot.jsonl")"
assert_eq "keepalive-only fork artifact: no real user msgs (empty)" \
  "" "$(ua "$FIX/keepalive_only.jsonl")"
assert_eq "malformed: 2 valid msgs, garbage/bad-timestamp lines skipped" \
  "$(epoch_of 2026-06-22T10:10:00+00:00) 2" "$(ua "$FIX/malformed.jsonl")"

# ---------------------------------------------------------------------------
describe "expected-tokens: compaction-aware prefix baseline"
assert_eq "live: last assistant total (48000+2000+80)" \
  "50080" "$(exp "$FIX/live_session.jsonl")"
assert_eq "compacted: post-compaction baseline (60000+5000+100), not pre" \
  "65100" "$(exp "$FIX/compacted_session.jsonl")"
assert_eq "compacted w/ no post turn: 0 (caller falls back, no false strike)" \
  "0" "$(exp "$FIX/compacted_no_post_turn.jsonl")"
assert_eq "missing file: 0 (fail-soft)" \
  "0" "$(exp "$FIX/does_not_exist.jsonl")"

# ---------------------------------------------------------------------------
describe "fork-usage: usage of the assistant turn answering OUR nonce"
assert_eq "clean: answer to keepalive, not an earlier turn" \
  "49500 500 30" "$(fu "$FIX/fork_clean.jsonl" 11111111-2222-3333-4444-555555555555)"
assert_eq "sidechain before reply: skip subagent turn" \
  "51000 0 25" "$(fu "$FIX/fork_sidechain_then_reply.jsonl" aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee)"
assert_eq "usage-less error turn before reply: skip to the real reply" \
  "52000 0 20" "$(fu "$FIX/fork_errorturn_then_reply.jsonl" 99999999-8888-7777-6666-555555555555)"
assert_eq "wrong nonce: no causal pair (empty)" \
  "" "$(fu "$FIX/fork_clean.jsonl" 00000000-0000-0000-0000-000000000000)"

# ---------------------------------------------------------------------------
describe "submit-confirmed: deterministic submit proof (cw-2)"
assert_status "correct nonce present -> exit 0" 0 sc "$FIX/fork_clean.jsonl" 11111111-2222-3333-4444-555555555555
assert_status "wrong nonce absent -> exit 1" 1 sc "$FIX/fork_clean.jsonl" deadbeef-0000-0000-0000-000000000000
assert_status "missing file -> exit 1 (fail-soft, no traceback)" 1 sc "$FIX/does_not_exist.jsonl" 11111111-2222-3333-4444-555555555555

# ---------------------------------------------------------------------------
describe "classify_warm: warm-result scoring (rc=0 warm, rc=1 strike)"
assert_eq "verified_full_hit: cache_read covers >=80% of baseline" \
  "verified_full_hit 0 0" "$(classify_warm 49000 500 100 50000)"
assert_eq "partial_hit: matched first part of prefix, diverged mid-way" \
  "partial_hit 1 1" "$(classify_warm 30000 0 0 50000)"
assert_eq "short_request: fork replayed far less than the live prefix" \
  "short_request 1 1" "$(classify_warm 200 100 50 50000)"
assert_eq "cold_or_mismatch: full-size request, near-zero read" \
  "cold_or_mismatch 1 1" "$(classify_warm 5000 30000 100 50000)"
assert_eq "no baseline + good read ratio: verified_hit_no_baseline" \
  "verified_hit_no_baseline 0 0" "$(classify_warm 49000 500 100 0)"
assert_eq "no baseline + poor read ratio: mismatch_no_baseline" \
  "mismatch_no_baseline 1 1" "$(classify_warm 100 49000 500 0)"
assert_eq "no baseline + zero usage: mismatch_no_baseline" \
  "mismatch_no_baseline 1 1" "$(classify_warm 0 0 0 0)"
assert_eq "non-numeric expected coerced to 0 (no-baseline path)" \
  "verified_hit_no_baseline 0 0" "$(classify_warm 49000 500 100 garbage)"

# ---------------------------------------------------------------------------
printf '\n----------------------------------------\n'
printf 'Passed: %d   Failed: %d\n' "$PASS" "$FAIL"
((FAIL == 0))
