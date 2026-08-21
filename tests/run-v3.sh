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
printf '\n----------------------------------------\n'
printf 'v3: Passed: %d   Failed: %d\n' "$PASS" "$FAIL"
((FAIL == 0))
