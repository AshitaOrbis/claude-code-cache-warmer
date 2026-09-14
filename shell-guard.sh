#!/usr/bin/env bash
# Decide whether THIS shell should route Claude Code through the capture proxy.
#
#   # ~/.bashrc
#   source /path/to/claude-code-cache-warmer/shell-guard.sh
#
# This used to be a snippet pasted into the README, and it shipped a fail-OPEN
# bug (Sol review, 2026-08-21):
#
#     if [ "$(curl -fs .../warmer-health)" = "$(cat ~/.cache/prefix-proxy/.health-nonce)" ]
#
# With the proxy DOWN, curl prints nothing. With the nonce file absent — or
# simply somewhere else, because CW_CAPTURE_DIR is configurable and the snippet
# hard-coded the default path — cat prints nothing. Empty equals empty, so the
# guard fired and every session in that shell was pointed at a dead proxy and
# could not reach the API at all. The check meant to be a safety net was the
# outage.
#
# It is a FILE now, and not a snippet, because that is what makes it testable:
# tests/run-v3.sh runs it against a down proxy, a missing nonce, a squatter on
# the port, and a healthy proxy.
#
# Fail-closed by construction: the nonce must be non-empty AND the proxy must
# echo that exact value. Failed checks clear inherited guard-managed routes;
# unrelated provider URLs are preserved.

cache_warmer_guard() {
  local port="${CW_PROXY_PORT:-8377}"
  local dir="${CW_CAPTURE_DIR:-$HOME/.cache/prefix-proxy}"
  local nonce live endpoint="http://127.0.0.1:${port}"

  # Clear our previous route before checking, including across port changes.
  if [[ ${ANTHROPIC_BASE_URL:-} == "${CW_GUARD_ENDPOINT:-$endpoint}" ]]; then
    unset ANTHROPIC_BASE_URL
  fi
  unset CW_GUARD_ENDPOINT

  nonce=$(cat "$dir/.health-nonce" 2>/dev/null) || return 0
  # An empty nonce can never authenticate anything. This single test is the
  # difference between the old fail-open and fail-closed.
  [ -n "$nonce" ] || return 0

  live=$(curl -fs --max-time 1 "http://127.0.0.1:${port}/warmer-health" 2>/dev/null) || return 0
  [ -n "$live" ] || return 0
  [ "$live" = "$nonce" ] || return 0

  export ANTHROPIC_BASE_URL="$endpoint"
  export CW_GUARD_ENDPOINT="$endpoint"
}

cache_warmer_guard
