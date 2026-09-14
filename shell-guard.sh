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
# echo that exact value. A failed check withdraws a route this guard exported
# (it sets CW_GUARD_ENDPOINT beside it as the ownership marker), including one
# inherited from a parent shell or left on an old port, and leaves every other
# ANTHROPIC_BASE_URL alone (bq-1998).

cache_warmer_proxy_answers() {
  local dir=$1 port=$2 nonce live
  nonce=$(cat "$dir/.health-nonce" 2>/dev/null) || return 1
  # An empty nonce can never authenticate anything. This single test is the
  # difference between the old fail-open and fail-closed.
  [ -n "$nonce" ] || return 1
  live=$(curl -fs --max-time 1 "http://127.0.0.1:${port}/warmer-health" 2>/dev/null) || return 1
  [ -n "$live" ] || return 1
  [ "$live" = "$nonce" ]
}

cache_warmer_guard() {
  local port="${CW_PROXY_PORT:-8377}"
  local dir="${CW_CAPTURE_DIR:-$HOME/.cache/prefix-proxy}"
  local endpoint="http://127.0.0.1:${port}" unmarked=0

  # Withdraw our own route before checking again. Ownership needs the marker: a
  # matching URL alone could equally be a different local provider on this port.
  if [ -n "${CW_GUARD_ENDPOINT:-}" ] && [ "${ANTHROPIC_BASE_URL:-}" = "$CW_GUARD_ENDPOINT" ]; then
    unset ANTHROPIC_BASE_URL
  elif [ -z "${CW_GUARD_ENDPOINT:-}" ] && [ "${ANTHROPIC_BASE_URL:-}" = "$endpoint" ]; then
    unmarked=1
  fi
  unset CW_GUARD_ENDPOINT

  if cache_warmer_proxy_answers "$dir" "$port"; then
    export ANTHROPIC_BASE_URL="$endpoint"
    export CW_GUARD_ENDPOINT="$endpoint"
  elif [ "$unmarked" = 1 ]; then
    echo "cache-warmer guard: the capture proxy did not answer, but ANTHROPIC_BASE_URL=$endpoint was not set by this guard (no CW_GUARD_ENDPOINT), so it was left in place; unset it if it came from an older guard." >&2
  fi
  return 0
}

cache_warmer_guard
