#!/usr/bin/env bash
# RELEASE GATE — the one v3 check that CANNOT be run offline (bq-315).
#
# tests/run-v3.sh proves warm-replay.py caps `max_tokens` by a byte-surgical
# edit and leaves every other byte of the capture alone. What it CANNOT prove
# is the thing that actually matters: that a capped replay still reads the
# whole cached prefix from Anthropic's cache rather than paying a fresh write.
# `max_tokens` is not supposed to participate in the cache key — but v3 already
# learned once, expensively, that "supposed to" is not measurement
# (docs/V3-DIAGNOSIS.md, "Why replay had to be byte- and header-exact":
# re-serializing the body dropped a full hit to cache_read=23,720 /
# creation=47,428).
#
# So this is a MANUAL gate. It spends real tokens on a real account and must be
# run by a human against a real capture before the capping path is trusted in
# production.
#
#   CW_LIVE=1 tests/live-replay-gate.sh ~/.cache/prefix-proxy/req-…-msg.json
#
# PASS requires >=80% cached input and a measured, non-aborted completion
# within a positive integer cap. FAIL includes inconclusive receipts; it does
# not by itself prove that capping perturbed the cache key.
#
# Second, separate gate, NOT automated here: Anthropic's billing behaviour for
# a client disconnect mid-stream. The abort path bounds wall-clock and bytes on
# the wire; whether it bounds BILLED output tokens is unmeasured. Until someone
# measures it against a usage report, no fixed per-warm output-token figure
# belongs in the docs.
set -euo pipefail

if [[ ${CW_LIVE:-0} != 1 ]]; then
  echo "refusing to run: this gate makes a REAL API call on a REAL account." >&2
  echo "re-run with CW_LIVE=1 and a capture path if that is what you want." >&2
  exit 2
fi

CAPTURE=${1:?usage: CW_LIVE=1 tests/live-replay-gate.sh <capture-msg.json>}
[[ -f $CAPTURE ]] || { echo "no such capture: $CAPTURE" >&2; exit 2; }
HDRS="${CAPTURE%.json}.hdrs.json"
[[ -f $HDRS ]] || { echo "no header sidecar: $HDRS" >&2; exit 2; }

REPO_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

echo "replaying $(basename "$CAPTURE") against the LIVE API…"
result=$(python3 "$REPO_DIR/warm-replay.py" "$CAPTURE" "$HDRS")
echo "$result"

# The production full-hit threshold is 80% of read + creation + uncached input.
# Aborted receipts can establish cache evidence, but cannot pass this cap gate.
if jq -L "$REPO_DIR/lib" -e 'include "receipt"; full_hit(80) and capped_completion' \
  <<<"$result" >/dev/null; then
  echo "PASS: capped replay still reads the full prefix (coverage >= 80%, measured output within positive cap)"
else
  echo "FAIL: partial or inconclusive cache/capped-completion evidence"
  exit 1
fi
