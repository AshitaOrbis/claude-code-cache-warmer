#!/usr/bin/env bash
# Offline regressions for the merged 2026-08 burn-queue defects. No test here
# opens a socket, reads a real transcript, or invokes a live Claude process.
set -euo pipefail

TESTS_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_DIR=$(cd "$TESTS_DIR/.." && pwd)
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

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
    printf '  FAIL %s\n       expected: [%s]\n       actual:   [%s]\n' \
      "$desc" "$want" "$got"
  fi
}

run_cache_helper() {
  local code=$1
  CACHE_WARMER_SOURCE_ONLY=1 HOME="$WORK/cache-home" \
    PATH="$WORK/cache-home/.local/bin:$PATH" bash -c '
    source "$1"
    eval "$2"
  ' _ "$REPO_DIR/cache-warmer.sh" "$code" 2>/dev/null || true
}

describe "bq-1021/1318: discovery binds configuration to authoritative session IDs"
got=$(run_cache_helper "
  record_authoritative_process 101 /work/shared 'ANTHROPIC_MODEL=opus' \
    claude --resume 11111111-1111-1111-1111-111111111111 --dangerously-skip-permissions --model opus
  record_authoritative_process 202 /work/shared 'ANTHROPIC_MODEL=sonnet' \
    claude --resume 22222222-2222-2222-2222-222222222222 --permission-mode default --model sonnet
  if [[ \${RESUME_SID_ARGS[11111111-1111-1111-1111-111111111111]} == *dangerously-skip-permissions* \
        && \${RESUME_SID_ARGS[11111111-1111-1111-1111-111111111111]} != *sonnet* \
        && \${RESUME_SID_ARGS[22222222-2222-2222-2222-222222222222]} == *sonnet* \
        && \${RESUME_SID_ARGS[22222222-2222-2222-2222-222222222222]} != *dangerously-skip-permissions* ]]; then
    if declare -p DIR_ARGS >/dev/null 2>&1; then printf fallback; else printf isolated; fi
  fi
")
assert_eq "two TUIs in one cwd retain their own flags and no directory fallback exists" isolated "$got"

got=$(run_cache_helper "
  record_authoritative_process 303 /work/shared '' \
    claude --resume 33333333-3333-3333-3333-333333333333 \
    'explain --dangerously-skip-permissions and --model opus'
  record_authoritative_process 404 /work/shared '' \
    claude --resume 44444444-4444-4444-4444-444444444444 \
    --dangerously-skip-permissions --model sonnet
  record_authoritative_process 405 /work/shared '' \
    claude --resume 45555555-5555-5555-5555-555555555555 \
    --model 'provider:model'
  record_authoritative_process 406 /work/shared '' \
    claude --resume 46666666-6666-6666-6666-666666666666 \
    --model=--dangerously-skip-permissions
  if declare -p RESUME_SID_FLAGS >/dev/null 2>&1 \
     && [[ -z \${RESUME_SID_FLAGS[33333333-3333-3333-3333-333333333333]:-} \
           && \${RESUME_SID_BYPASS[33333333-3333-3333-3333-333333333333]:-1} == 0 \
           && \${RESUME_SID_FLAGS[44444444-4444-4444-4444-444444444444]:-} == *dangerously-skip-permissions* \
           && \${RESUME_SID_FLAGS[44444444-4444-4444-4444-444444444444]:-} == *sonnet* \
           && \${RESUME_SID_UNREPLICABLE[45555555-5555-5555-5555-555555555555]:-0} == 1 \
           && \${RESUME_SID_UNREPLICABLE[46666666-6666-6666-6666-666666666666]:-0} == 1 ]]; then
    printf token-safe
  fi
")
assert_eq "prompt text cannot be reinterpreted as permission/model flags" token-safe "$got"

describe "bq-1022/1201/1324: transcript lookup does not reconstruct a lossy cwd path"
DOTTED_ROOT="$WORK/projects/-work-app-web"
mkdir -p "$DOTTED_ROOT"
: >"$DOTTED_ROOT/11111111-1111-1111-1111-111111111111.jsonl"
assert_eq "SID lookup finds a transcript inside a dotted-path project directory" \
  "$DOTTED_ROOT/11111111-1111-1111-1111-111111111111.jsonl" \
  "$(run_cache_helper "find_session_jsonl 11111111-1111-1111-1111-111111111111 '$WORK/projects' && printf %s \"\$FOUND_SESSION_JSONL\"")"

describe "bq-1202/1321: binary drift stays blocked until organic transcript activity"
got=$(run_cache_helper '
  if binary_drift_blocks 1000 900 old-fingerprint new-fingerprint \
     && binary_drift_blocks 1000 900 old-fingerprint new-fingerprint \
     && ! binary_drift_blocks 1000 1001 old-fingerprint new-fingerprint; then
    printf persistent
  fi
')
assert_eq "a skipped tick cannot clear drift; newer live mtime can" persistent "$got"

describe "bq-1323: process identity is executable/token exact"
got=$(run_cache_helper '
  mkdir -p "$HOME/.local/bin" "$HOME/.local/share/claude/versions"
  : >"$HOME/.local/share/claude/versions/2.1.999"
  chmod +x "$HOME/.local/share/claude/versions/2.1.999"
  ln -s "$HOME/.local/share/claude/versions/2.1.999" "$HOME/.local/bin/claude"
  if is_known_claude_process "$HOME/.local/share/claude/versions/2.1.999" \
          "$HOME/.local/bin/claude" --resume x \
     && is_known_claude_process /usr/bin/node node /opt/node_modules/@anthropic-ai/claude-code/cli.js \
     && ! is_known_claude_process /usr/bin/tail tail -f /tmp/claude.log \
     && ! is_known_claude_process /usr/bin/claude-helper claude-helper \
     && ! is_known_claude_process /usr/bin/node node /tmp/worker.js \
          /opt/node_modules/@anthropic-ai/claude-code/cli.js; then
    printf exact
  fi
')
assert_eq "direct, native-versioned, and JS installs match without substring false positives" exact "$got"

describe "bq-1257: hosted-MCP bearer tokens never reach capture storage"
proxy_result=$(node - "$REPO_DIR/prefix-proxy.js" "$WORK/proxy-secret" <<'NODE' 2>/dev/null || true
const fs = require('fs');
const proxy = require(process.argv[2]);
const dir = process.argv[3];
fs.mkdirSync(dir, { recursive: true });
const secretBody = Buffer.from(JSON.stringify({
  mcp_servers: [{ type: 'url', authorization_token: 'TEST-ONLY-BEARER' }],
  messages: [],
}));
const safeMcpBody = Buffer.from(JSON.stringify({
  mcp_servers: [{ type: 'url', url: 'https://mcp.invalid' }],
  messages: [],
}));
const malformedSecretBody = Buffer.from(
  '{"mcp_servers":[{"authorization_token":"MALFORMED-SECRET"}]',
);
const duplicateSecretBody = Buffer.from(
  '{"mcp_servers":[{"authorization_token":"DUPLICATE-SECRET"}],"mcp_servers":[]}',
);
const refused = proxy.persistPendingCapture(
  dir, 'req-1000-000-msg', '/v1/messages', { authorization: 'TEST-HEADER' }, secretBody,
);
const accepted = proxy.persistPendingCapture(
  dir, 'req-1001-000-msg', '/v1/messages', { authorization: 'TEST-HEADER' }, safeMcpBody,
);
const malformedRefused = proxy.persistPendingCapture(
  dir, 'req-1002-000-msg', '/v1/messages', {}, malformedSecretBody,
);
const duplicateRefused = proxy.persistPendingCapture(
  dir, 'req-1003-000-msg', '/v1/messages', {}, duplicateSecretBody,
);
const files = fs.readdirSync(dir);
const bytes = files.map((name) => fs.readFileSync(`${dir}/${name}`)).join('\n');
console.log(JSON.stringify({
  refused: refused === null,
  accepted: accepted !== null,
  malformedRefused: malformedRefused === null,
  duplicateRefused: duplicateRefused === null,
  noSecret: !bytes.includes('TEST-ONLY-BEARER') && !bytes.includes('TEST-HEADER')
    && !bytes.includes('MALFORMED-SECRET') && !bytes.includes('DUPLICATE-SECRET'),
}));
NODE
)
assert_eq "authorization_token request is refused before its first write" true \
  "$(jq -r '.refused // false' <<<"$proxy_result" 2>/dev/null || echo false)"
assert_eq "mcp_servers without authorization_token is still capturable" true \
  "$(jq -r '.accepted // false' <<<"$proxy_result" 2>/dev/null || echo false)"
assert_eq "malformed JSON is refused rather than risking a body credential write" true \
  "$(jq -r '.malformedRefused // false' <<<"$proxy_result" 2>/dev/null || echo false)"
assert_eq "duplicate top-level mcp_servers cannot hide an earlier bearer" true \
  "$(jq -r '.duplicateRefused // false' <<<"$proxy_result" 2>/dev/null || echo false)"
assert_eq "neither body bearer nor auth header appears on disk" true \
  "$(jq -r '.noSecret // false' <<<"$proxy_result" 2>/dev/null || echo false)"

describe "bq-1018/1198/1258/1392: proxy retention sweep shares initialized health state"
retention_result=$(node - "$REPO_DIR/prefix-proxy.js" "$WORK/proxy-retention" <<'NODE' 2>/dev/null || true
const fs = require('fs');
const proxy = require(process.argv[2]);
const dir = process.argv[3];
fs.mkdirSync(dir, { recursive: true });
fs.writeFileSync(`${dir}/pending-req-old-000-msg.json`, 'body');
fs.utimesSync(`${dir}/pending-req-old-000-msg.json`, new Date(0), new Date(0));
const state = proxy.newHealthState();
state.writeErrors = 1;
const sweep = proxy.createRetentionSweep(dir, 1, state);
sweep();
console.log(JSON.stringify({
  pendingGone: !fs.existsSync(`${dir}/pending-req-old-000-msg.json`),
  recovered: state.writeErrors === 0,
}));
NODE
)
retention_result=${retention_result##*$'\n'}
assert_eq "startup/timer sweep runs without an undefined-state crash" true \
  "$(jq -r '(.pendingGone and .recovered) // false' <<<"$retention_result" 2>/dev/null || echo false)"

make_capture() {
  local dir=$1 stem=$2 sid=$3 age=$4 tool_type=${5:-}
  local body
  mkdir -p "$dir"
  body=$(jq -nc --arg sp "/tmp/claude-1000/proj/$sid/scratchpad" --arg typ "$tool_type" '
    {model:"claude-test",max_tokens:32000,
     system:[{type:"text",text:("Scratchpad Directory\n"+$sp)}],
     messages:[{role:"user",content:"one"},{role:"assistant",content:"a"},
               {role:"user",content:"two"},{role:"assistant",content:"b"},
               {role:"user",content:"three"}]}
    + (if $typ == "" then {tools:[{name:"local",input_schema:{type:"object"}}]}
       else {tools:[{name:"fixture",type:$typ,input_schema:{type:"object"}}]} end)')
  printf '%s' "$body" >"$dir/$stem.json"
  jq -nc '{url:"/v1/messages",headers:{"anthropic-version":"2023-06-01"}}' \
    >"$dir/$stem.hdrs.json"
  touch -d "$age minutes ago" "$dir/$stem.json" "$dir/$stem.hdrs.json"
}

stage_warmer() {
  local stage=$1 result=${2:-'{"http":200,"cache_read":900,"cache_creation":0,"input_tokens":100,"output_tokens":1,"cap":1}'}
  mkdir -p "$stage"
  cp "$REPO_DIR/replay-warmer.sh" "$stage/replay-warmer.sh"
  sed "s|RESULT_JSON|$result|" >"$stage/warm-replay.py" <<'PY'
#!/usr/bin/env python3
import pathlib
import sys

pathlib.Path(__file__).with_name("calls.log").open("a").write(" ".join(sys.argv[1:]) + "\n")
print('RESULT_JSON')
PY
  chmod +x "$stage/warm-replay.py"
}

run_warmer() {
  local stage=$1 home=$2 config=$3
  shift 3
  HOME="$home" CW_CONFIG="$config" CW_JITTER_SECONDS=0 \
    bash "$stage/replay-warmer.sh" "$@"
}

describe "bq-1393: an explicit empty argv is not the no-argument live mode"
H="$WORK/argv-home"; STAGE="$WORK/argv-stage"
printf 'ENABLED=0\n' >"$WORK/argv-config"
stage_warmer "$STAGE"
argv_status=0
HOME="$H" CW_CONFIG="$WORK/argv-config" bash "$STAGE/replay-warmer.sh" "" \
  >/dev/null 2>&1 || argv_status=$?
assert_eq "an explicit empty argument is rejected before side effects" 2 "$argv_status"
assert_eq "argument rejection does not create the state directory" no \
  "$([[ -d $H/.cache/cache-warmer-v3 ]] && echo yes || echo no)"

describe "bq-1020: transient failure retries in-process before the window closes"
H="$WORK/retry-home"; CAP="$H/.cache/prefix-proxy"; STAGE="$WORK/retry-stage"
make_capture "$CAP" req-1000-000-msg 33333333-3333-3333-3333-333333333333 50
printf 'ENABLED=1\n' >"$WORK/retry-config"
mkdir -p "$STAGE"; cp "$REPO_DIR/replay-warmer.sh" "$STAGE/replay-warmer.sh"
cat >"$STAGE/warm-replay.py" <<'PY'
#!/usr/bin/env python3
import pathlib
import sys
p = pathlib.Path(__file__).with_name('attempts')
n = int(p.read_text()) + 1 if p.exists() else 1
p.write_text(str(n))
if n == 1:
    print('{"http":503,"error":"fixture transient"}')
    sys.exit(1)
print('{"http":200,"cache_read":900,"cache_creation":0,"input_tokens":100,"output_tokens":1,"cap":1}')
PY
chmod +x "$STAGE/warm-replay.py"
run_warmer "$STAGE" "$H" "$WORK/retry-config" 2>/dev/null || true
assert_eq "one transient failure is retried without waiting for another timer tick" 2 \
  "$(cat "$STAGE/attempts" 2>/dev/null || echo 0)"

describe "bq-1255/1388/1199: server and unknown typed tools fail closed"
H="$WORK/tools-home"; CAP="$H/.cache/prefix-proxy"; STAGE="$WORK/tools-stage"
printf 'ENABLED=1\n' >"$WORK/tools-config"
stage_warmer "$STAGE"
make_capture "$CAP" req-1100-000-msg 41000000-0000-0000-0000-000000000000 50
tool_types=(advisor_20260301 tool_search_tool_regex tool_search_tool_regex_20251119 \
  tool_search_tool_bm25 tool_search_tool_bm25_20251119)
i=1
for typ in "${tool_types[@]}"; do
  printf -v sid '41%06d-0000-0000-0000-000000000000' "$i"
  make_capture "$CAP" "req-11${i}0-000-msg" "$sid" 50 "$typ"
  i=$((i + 1))
done
run_warmer "$STAGE" "$H" "$WORK/tools-config" 2>/dev/null || true
assert_eq "untyped client tool remains eligible" yes \
  "$(grep -q 'req-1100-000-msg' "$STAGE/calls.log" 2>/dev/null && echo yes || echo no)"
i=1
for typ in "${tool_types[@]}"; do
  assert_eq "$typ is refused" no \
    "$(grep -q "req-11${i}0-000-msg" "$STAGE/calls.log" 2>/dev/null && echo yes || echo no)"
  i=$((i + 1))
done

describe "bq-1256/1319/1390: full-hit classification includes uncached input"
H="$WORK/partial-home"; CAP="$H/.cache/prefix-proxy"; STAGE="$WORK/partial-stage"
SID=50000000-0000-0000-0000-000000000000
make_capture "$CAP" req-1200-000-msg "$SID" 50
printf 'ENABLED=1\n' >"$WORK/partial-config"
stage_warmer "$STAGE" '{"http":200,"cache_read":1,"cache_creation":0,"input_tokens":100000,"output_tokens":1,"cap":1}'
run_warmer "$STAGE" "$H" "$WORK/partial-config" 2>/dev/null || true
assert_eq "one cached token out of 100001 never advances last_warm" no \
  "$([[ -f $H/.cache/cache-warmer-v3/$SID.last_warm ]] && echo yes || echo no)"
assert_eq "the result is reported as partial rather than warmed" yes \
  "$(grep -q 'RESULT sid=.* PARTIAL' "$H/.claude/logs/cache-warmer.log" 2>/dev/null && echo yes || echo no)"

describe "bq-1200: filename timestamp and sequence break same-second ties"
H="$WORK/order-home"; CAP="$H/.cache/prefix-proxy"; STAGE="$WORK/order-stage"
SID=60000000-0000-0000-0000-000000000000
make_capture "$CAP" req-1700000000000-000-msg "$SID" 50
make_capture "$CAP" req-1700000000000-001-msg "$SID" 50
same_time=$(( $(date +%s) - 50 * 60 ))
touch -d "@$same_time" "$CAP"/*
printf 'ENABLED=1\n' >"$WORK/order-config"
stage_warmer "$STAGE"
ORDER_BIN="$WORK/order-bin"
mkdir -p "$ORDER_BIN"
cat >"$ORDER_BIN/find" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
previous=""
for argument in "$@"; do
  if [[ $previous == -name && $argument == 'req-*-msg.json' ]]; then
    printf '%s\n%s\n' "$CW_FIND_LOW" "$CW_FIND_HIGH"
    exit 0
  fi
  previous=$argument
done
exec "$CW_REAL_FIND" "$@"
SH
chmod +x "$ORDER_BIN/find"
REAL_FIND=$(command -v find)
PATH="$ORDER_BIN:$PATH" CW_REAL_FIND="$REAL_FIND" \
  CW_FIND_LOW="$CAP/req-1700000000000-000-msg.json" \
  CW_FIND_HIGH="$CAP/req-1700000000000-001-msg.json" \
  run_warmer "$STAGE" "$H" "$WORK/order-config" 2>/dev/null || true
assert_eq "higher same-millisecond sequence is selected" yes \
  "$(grep -q '1700000000000-001-msg' "$STAGE/calls.log" 2>/dev/null && echo yes || echo no)"

describe "bq-315/1389/1259: abort-only output bounds require real SSE"
output_probe=$(python3 - "$REPO_DIR/warm-replay.py" <<'PY' 2>/dev/null || true
import importlib.util
import json
import sys

spec = importlib.util.spec_from_file_location('warm_replay', sys.argv[1])
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)

class NonStreaming:
    headers = {'content-type': 'application/json'}
    read_called = False
    def read(self, *args):
        self.read_called = True
        return b'{"usage":{"output_tokens":32000}}'

resp = NonStreaming()
refused = False
try:
    mod.read_usage(resp, True)
except mod.ReplayRefused:
    refused = True

class MissingStart:
    headers = {'content-type': 'text/event-stream'}
    seen = 0
    def readline(self, limit=-1):
        if self.seen >= 10000:
            return b''
        self.seen += 1
        return b'data: {"type":"ping"}\n'
    def __iter__(self):
        while True:
            line = self.readline()
            if not line:
                return
            yield line

class OversizedStart:
    headers = {'content-type': 'text/event-stream'}
    consumed = 0
    def readline(self, limit=-1):
        size = 1024 * 1024 if limit < 0 else min(limit, 1024 * 1024)
        self.consumed += size
        return b'x' * size
    def __iter__(self):
        yield self.readline()

missing_start = MissingStart()
missing_start_refused = False
try:
    mod.read_usage(missing_start, True)
except mod.ReplayRefused:
    missing_start_refused = True

oversized_start = OversizedStart()
oversized_start_refused = False
try:
    mod.read_usage(oversized_start, True)
except mod.ReplayRefused:
    oversized_start_refused = True

try:
    mod.output_bound_plan(32001, False, 64)
    disabled_abort_refused = False
except (mod.ReplayRefused, AttributeError):
    disabled_abort_refused = hasattr(mod, 'output_bound_plan')

try:
    mod.output_bound_plan(32001, True, 100000)
    unsafe_threshold_refused = False
except (mod.ReplayRefused, AttributeError):
    unsafe_threshold_refused = hasattr(mod, 'output_bound_plan')

receipt = mod.usage_receipt({'cache_read_input_tokens': 1})
print(json.dumps({
    'requestRefused': not mod.request_is_streaming(b'{"stream":false,"messages":[]}'),
    'responseRefused': refused,
    'responseUnread': not resp.read_called,
    'missingStartRefused': missing_start_refused and missing_start.seen < 10000,
    'oversizedStartBounded': oversized_start_refused and oversized_start.consumed <= 65537,
    'disabledAbortRefused': disabled_abort_refused,
    'unsafeThresholdRefused': unsafe_threshold_refused,
    'missingInput': receipt['input_tokens'] is None,
}))
PY
)
assert_eq "an uncappable non-streaming request has no abort fallback" true \
  "$(jq -r '.requestRefused // false' <<<"$output_probe" 2>/dev/null || echo false)"
assert_eq "a non-SSE response is refused before its full body is drained" true \
  "$(jq -r '(.responseRefused and .responseUnread) // false' <<<"$output_probe" 2>/dev/null || echo false)"
assert_eq "abort-disabled cannot drain an extended-thinking-sized cap" true \
  "$(jq -r '.disabledAbortRefused // false' <<<"$output_probe" 2>/dev/null || echo false)"
assert_eq "an unsafe abort threshold override is refused" true \
  "$(jq -r '.unsafeThresholdRefused // false' <<<"$output_probe" 2>/dev/null || echo false)"
assert_eq "abort-only SSE without message_start fails within a bounded prelude" true \
  "$(jq -r '.missingStartRefused // false' <<<"$output_probe" 2>/dev/null || echo false)"
assert_eq "one oversized SSE line is never read beyond the hard prelude bound" true \
  "$(jq -r '.oversizedStartBounded // false' <<<"$output_probe" 2>/dev/null || echo false)"
assert_eq "missing usage counters remain ambiguous nulls" true \
  "$(jq -r '.missingInput // false' <<<"$output_probe" 2>/dev/null || echo false)"

describe "bq-1023/1322: keepalive detection scans the complete transcript"
ttl_probe=$(python3 - "$REPO_DIR/measure-ttl.py" "$WORK/long-fork.jsonl" <<'PY' 2>/dev/null || true
import importlib.util
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[2])
path.write_text(
    json.dumps({'type': 'user', 'message': {'content': 'x' * 5000}}) + '\n' +
    json.dumps({'type': 'user', 'message': {'content': '[cache-warmer keepalive] synthetic'}}) + '\n'
)
spec = importlib.util.spec_from_file_location('measure_ttl', sys.argv[1])
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
print('yes' if mod.is_keepalive_transcript(path) else 'no')
PY
)
assert_eq "marker after byte 4096 excludes the fork transcript" yes "$ttl_probe"

printf '\n----------------------------------------\n'
printf 'burn-queue: Passed: %d   Failed: %d\n' "$PASS" "$FAIL"
((FAIL == 0))
