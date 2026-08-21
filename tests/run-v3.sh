#!/usr/bin/env bash
# Test runner for the v3 REPLAY engine — prefix-proxy.js, replay-warmer.sh,
# warm-replay.py. tests/run.sh covers the v2 fork engine only (BACKLOG: "Tests/CI
# for replay-warmer.sh gating + warm-replay.py"), which is why every v3 finding
# in the 2026-08-12 GPT-Pro dive landed unguarded.
#
# Everything here is hermetic: a temp HOME, a temp capture store, a stub
# warm-replay.py that records its invocations instead of calling Anthropic, and
# a local fake SSE server for the real warm-replay.py. No network, no API
# credentials, no systemd, and install.sh is never executed.
#
#   tests/run-v3.sh
set -euo pipefail

TESTS_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_DIR=$(cd "$TESTS_DIR/.." && pwd)

PASS=0
FAIL=0

describe() { printf '\n# %s\n' "$1"; }

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

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# ---------------------------------------------------------------------------
# Fixture builders
# ---------------------------------------------------------------------------

# make_capture <capture-dir> <stem> <sid> <age-minutes> [body-json]
# Writes the promoted body+headers pair the warmer expects, back-dated so the
# age gates can be exercised without waiting.
make_capture() {
  local dir=$1 stem=$2 sid=$3 age=$4 body=${5:-}
  mkdir -p "$dir"
  if [[ -z $body ]]; then
    body=$(jq -nc --arg sp "/tmp/claude-1000/proj/$sid/scratchpad" '{
      model: "claude-opus-5",
      max_tokens: 32000,
      system: [{type: "text", text: ("Scratchpad Directory\n" + $sp)}],
      messages: [
        {role: "user",      content: "one"},
        {role: "assistant", content: "two"},
        {role: "user",      content: "three"}
      ]
    }')
  fi
  printf '%s' "$body" > "$dir/$stem.json"
  jq -nc '{url: "/v1/messages?beta=true", headers: {"anthropic-version": "2023-06-01"}}' \
    > "$dir/$stem.hdrs.json"
  touch -d "$age minutes ago" "$dir/$stem.json" "$dir/$stem.hdrs.json"
}

# stub_warm_replay <bindir> <result-json>
# A warm-replay.py stand-in that appends its argv to $bindir/calls.log and
# prints a canned result — so "did the warmer dispatch?" is observable without
# any network call.
stub_warm_replay() {
  local dir=$1 result=$2
  mkdir -p "$dir"
  cat > "$dir/warm-replay.py" <<PYEOF
import sys, pathlib
pathlib.Path(__file__).with_name("calls.log").open("a").write(" ".join(sys.argv[1:]) + "\n")
print('''$result''')
PYEOF
}

# run_warmer <home> <capture-dir> [args...]
# Runs replay-warmer.sh against a hermetic HOME with the given CW_* knobs
# already exported by the caller.
run_warmer() {
  local home=$1
  shift
  HOME="$home" bash "$REPO_DIR/replay-warmer.sh" "$@"
}

# ---------------------------------------------------------------------------
describe "bq-314 proxy retention: prunes promoted AND pending pairs, spares the rest"
D="$WORK/prune"
mkdir -p "$D"
: > "$D/req-old-000-msg.json";        touch -d '10 hours ago' "$D/req-old-000-msg.json"
: > "$D/req-old-000-msg.hdrs.json";   touch -d '10 hours ago' "$D/req-old-000-msg.hdrs.json"
: > "$D/pending-req-crash-001-msg.json"; touch -d '10 hours ago' "$D/pending-req-crash-001-msg.json"
: > "$D/pending-req-crash-001-msg.hdrs.json"; touch -d '10 hours ago' "$D/pending-req-crash-001-msg.hdrs.json"
: > "$D/req-fresh-002-msg.json";      touch -d '1 hour ago' "$D/req-fresh-002-msg.json"
: > "$D/.health-nonce";               touch -d '10 hours ago' "$D/.health-nonce"
removed=$(node -e '
  const p = require(process.argv[1]);
  console.log(p.pruneCaptures(process.argv[2], 6 * 3600 * 1000));
' "$REPO_DIR/prefix-proxy.js" "$D")
assert_eq "removes 4 stale capture files (2 promoted + 2 crash leftovers)" "4" "$removed"
assert_eq "fresh capture survives" "yes" "$([[ -f $D/req-fresh-002-msg.json ]] && echo yes || echo no)"
assert_eq "stale promoted body gone" "no" "$([[ -f $D/req-old-000-msg.json ]] && echo yes || echo no)"
assert_eq "stale pending body gone (crash leftover)" "no" \
  "$([[ -f $D/pending-req-crash-001-msg.json ]] && echo yes || echo no)"
assert_eq "non-capture file untouched (.health-nonce)" "yes" \
  "$([[ -f $D/.health-nonce ]] && echo yes || echo no)"

describe "bq-314 proxy retention: store mode is re-asserted on an existing dir"
E="$WORK/store"
mkdir -p "$E"; chmod 0755 "$E"
node -e 'require(process.argv[1]).ensureStore(process.argv[2])' "$REPO_DIR/prefix-proxy.js" "$E"
assert_eq "pre-existing 0755 store is forced back to 0700" "700" "$(stat -c %a "$E")"

describe "bq-314 warmer retention: prunes even when ENABLED=0 (disabled-warmer operation)"
H="$WORK/home-disabled"
CAP="$H/.cache/prefix-proxy"
make_capture "$CAP" "req-stale-000-msg" 11111111-1111-1111-1111-111111111111 600
: > "$CAP/pending-req-stale-001-msg.json"; touch -d '10 hours ago' "$CAP/pending-req-stale-001-msg.json"
make_capture "$CAP" "req-recent-002-msg" 22222222-2222-2222-2222-222222222222 50
printf 'ENABLED=0\n' > "$WORK/config-disabled"
CW_CONFIG="$WORK/config-disabled" run_warmer "$H"
assert_eq "stale capture pruned with warming disabled" "no" \
  "$([[ -f $CAP/req-stale-000-msg.json ]] && echo yes || echo no)"
assert_eq "stale pending leftover pruned with warming disabled" "no" \
  "$([[ -f $CAP/pending-req-stale-001-msg.json ]] && echo yes || echo no)"
assert_eq "in-window capture retained" "yes" \
  "$([[ -f $CAP/req-recent-002-msg.json ]] && echo yes || echo no)"

# ---------------------------------------------------------------------------
# bq-315 — replay must not regenerate the original completion uncapped.
# Driven against a LOCAL fake api.anthropic.com (tests/fake_anthropic.py):
# no network, no credentials, no cache. What the live API does with a
# mid-stream disconnect is a separate, un-run release gate — see
# tests/live-replay-gate.sh.
# ---------------------------------------------------------------------------
FAKE_CREDS="$WORK/creds.json"
jq -nc '{claudeAiOauth: {accessToken: "test-token-not-a-real-credential"}}' > "$FAKE_CREDS"

# start_fake <outdir> -> exports FAKE_URL, sets FAKE_PID
start_fake() {
  local out=$1
  mkdir -p "$out"
  python3 "$TESTS_DIR/fake_anthropic.py" "$out" &
  FAKE_PID=$!
  local i=0
  while [[ ! -f $out/port ]]; do
    sleep 0.05
    i=$((i + 1))
    ((i < 100)) || { echo "fake server never bound a port" >&2; return 1; }
  done
  FAKE_URL="http://127.0.0.1:$(cat "$out/port")"
}
stop_fake() { kill "$FAKE_PID" 2>/dev/null || true; wait "$FAKE_PID" 2>/dev/null || true; }

# replay <capture-json> -> stdout is warm-replay.py's JSON line
replay() {
  CW_CREDENTIALS="$FAKE_CREDS" CW_REPLAY_ENDPOINT="$FAKE_URL" \
    python3 "$REPO_DIR/warm-replay.py" "$1" "${1%.json}.hdrs.json"
}

describe "bq-315 cap: a plain capture is sent with max_tokens=1, prefix bytes untouched"
S="$WORK/fake-plain"; start_fake "$S"
CAPD="$WORK/cap-plain"
make_capture "$CAPD" "req-1-msg" 33333333-3333-3333-3333-333333333333 5
out=$(replay "$CAPD/req-1-msg.json")
assert_eq "reported cap is 1" "1" "$(jq -r '.cap' <<<"$out")"
assert_eq "stream consumed, not aborted (cap already tiny)" "false" "$(jq -r '.aborted' <<<"$out")"
assert_eq "usage still read from message_start" "71410" "$(jq -r '.cache_read' <<<"$out")"
assert_eq "server received max_tokens=1" "1" "$(jq -r '.max_tokens' "$S/body.bin")"
assert_eq "system block byte-identical" \
  "$(jq -cS '.system' "$CAPD/req-1-msg.json")" "$(jq -cS '.system' "$S/body.bin")"
assert_eq "messages byte-identical" \
  "$(jq -cS '.messages' "$CAPD/req-1-msg.json")" "$(jq -cS '.messages' "$S/body.bin")"
assert_eq "ONLY max_tokens differs from the capture" "{}" \
  "$(jq -n --slurpfile a "$CAPD/req-1-msg.json" --slurpfile b "$S/body.bin" \
      '($a[0]|del(.max_tokens)) as $x | ($b[0]|del(.max_tokens)) as $y
       | if $x == $y then {} else {differs: true} end' | jq -c .)"
stop_fake

describe "bq-315 cap: extended thinking floors at budget+1, so the stream is ABORTED"
S="$WORK/fake-think"; start_fake "$S"
CAPD="$WORK/cap-think"
think_body=$(jq -nc --arg sp "/tmp/claude-1000/proj/44444444-4444-4444-4444-444444444444/scratchpad" '{
  model: "claude-opus-5", max_tokens: 32000,
  thinking: {type: "enabled", budget_tokens: 1024},
  system: [{type: "text", text: ("Scratchpad Directory\n" + $sp)}],
  messages: [{role: "user", content: "one"}, {role: "assistant", content: "two"}, {role: "user", content: "three"}]
}')
make_capture "$CAPD" "req-1-msg" 44444444-4444-4444-4444-444444444444 5 "$think_body"
out=$(replay "$CAPD/req-1-msg.json")
assert_eq "cap is budget_tokens+1 (the API's floor)" "1025" "$(jq -r '.cap' <<<"$out")"
assert_eq "warm-replay reports it aborted" "true" "$(jq -r '.aborted' <<<"$out")"
assert_eq "server saw the capped value" "1025" "$(jq -r '.max_tokens' "$S/body.bin")"
assert_eq "thinking block preserved (cache key)" "1024" "$(jq -r '.thinking.budget_tokens' "$S/body.bin")"
sleep 0.4
assert_eq "server observed the client hang up mid-stream" "client_disconnected" "$(cat "$S/result")"
stop_fake

describe "bq-315 cap: an AMBIGUOUS max_tokens is never guessed at — body sent verbatim, aborted"
S="$WORK/fake-ambig"; start_fake "$S"
CAPD="$WORK/cap-ambig"
ambig_body=$(jq -nc --arg sp "/tmp/claude-1000/proj/55555555-5555-5555-5555-555555555555/scratchpad" '{
  model: "claude-opus-5", max_tokens: 32000,
  tools: [{name: "summarize", input_schema: {type: "object", properties: {max_tokens: {type: "integer"}}}}],
  system: [{type: "text", text: ("Scratchpad Directory\n" + $sp)}],
  messages: [{role: "user", content: "one"}, {role: "assistant", content: "two"}, {role: "user", content: "three"}]
}')
# The tool schema mentions max_tokens but carries no NUMBER, so make it one that does.
ambig_body=${ambig_body/\"type\":\"integer\"/\"type\":\"integer\",\"max_tokens\":4096}
make_capture "$CAPD" "req-1-msg" 55555555-5555-5555-5555-555555555555 5 "$ambig_body"
out=$(replay "$CAPD/req-1-msg.json")
assert_eq "no cap claimed" "null" "$(jq -r '.cap' <<<"$out")"
assert_eq "reason names the ambiguity" "yes" \
  "$(jq -r '.cap_reason' <<<"$out" | grep -q '^ambiguous' && echo yes || echo no)"
assert_eq "abort is the fallback bound" "true" "$(jq -r '.aborted' <<<"$out")"
assert_eq "body reached the server byte-identical" "same" \
  "$(cmp -s "$CAPD/req-1-msg.json" "$S/body.bin" && echo same || echo differs)"
stop_fake

describe "bq-315 refuse: uncappable AND abort disabled -> exit 3, request never sent"
S="$WORK/fake-refuse"; start_fake "$S"
set +e
out=$(CW_CREDENTIALS="$FAKE_CREDS" CW_REPLAY_ENDPOINT="$FAKE_URL" CW_REPLAY_ABORT=0 \
        python3 "$REPO_DIR/warm-replay.py" "$WORK/cap-ambig/req-1-msg.json" \
        "$WORK/cap-ambig/req-1-msg.hdrs.json")
rc=$?
set -e
assert_eq "exit 3 (refused, not a transient failure)" "3" "$rc"
assert_eq "error is uncapped_refused" "uncapped_refused" "$(jq -r '.error' <<<"$out")"
assert_eq "nothing was sent upstream" "no" "$([[ -f $S/requests ]] && echo yes || echo no)"
stop_fake

describe "bq-315 warmer: an exit-3 refusal is logged REFUSED and does NOT roll back last_attempt"
H="$WORK/home-refuse"
CAP="$H/.cache/prefix-proxy"
SID=66666666-6666-6666-6666-666666666666
make_capture "$CAP" "req-1-msg" "$SID" 50
BIN="$WORK/bin-refuse"
mkdir -p "$BIN"
cat > "$BIN/warm-replay.py" <<'PYSTUB'
import json, sys
print(json.dumps({"http": 0, "error": "uncapped_refused", "cap_reason": "ambiguous: 2 max_tokens occurrences in the raw body"}))
sys.exit(3)
PYSTUB
# Run the real script but with a refusing warm-replay.py beside it.
STAGE="$WORK/stage-refuse"
mkdir -p "$STAGE"
cp "$REPO_DIR/replay-warmer.sh" "$STAGE/"
cp "$BIN/warm-replay.py" "$STAGE/"
printf 'ENABLED=1\n' > "$WORK/config-refuse"
mkdir -p "$H/.cache/cache-warmer-v3"
printf '0' > "$H/.cache/cache-warmer-v3/$SID.last_attempt"
CW_CONFIG="$WORK/config-refuse" CW_MAX_CAPTURE_AGE_MIN=240 \
  HOME="$H" bash "$STAGE/replay-warmer.sh"
LOG="$H/.claude/logs/cache-warmer.log"
assert_eq "warmer logged REFUSED uncapped" "yes" \
  "$(grep -q 'REFUSED uncapped' "$LOG" && echo yes || echo no)"
assert_eq "last_attempt kept (no retry-rollback for a permanent refusal)" "yes" \
  "$([[ $(cat "$H/.cache/cache-warmer-v3/$SID.last_attempt") != 0 ]] && echo yes || echo no)"
assert_eq "no failure streak recorded" "no" \
  "$([[ -f $H/.cache/cache-warmer-v3/$SID.fail_count ]] && echo yes || echo no)"

# ---------------------------------------------------------------------------
printf '\n----------------------------------------\n'
printf 'v3: Passed: %d   Failed: %d\n' "$PASS" "$FAIL"
((FAIL == 0))
