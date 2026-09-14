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
#
# Fail-closed was only half of it. A HEALTHY proxy used to take the route
# whatever it found there (GPT-Pro review 2026-09-14, bq-2472): a shell that had
# deliberately selected another provider survived a failed check and lost the
# route to a successful one, silently. This proxy forwards what it receives —
# and the authentication headers that came with it — to api.anthropic.com, so
# the cost of taking a route that is not ours is a provider and its credentials,
# against a warm. Selection now happens only when nothing else has selected.

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
  # Where install.sh publishes the capture directory and port it VERIFIED a
  # running proxy against (bq-2473). Without it this guard resolved its own
  # defaults, so the documented install-then-source-guard path lost every
  # custom setting between its two entry points: installation confirmed the
  # right proxy and the next shell routed to a different one, or to nothing.
  local record="$HOME/.config/systemd/user/prefix-proxy.settings"
  local installed_dir="" installed_port="" line key value cr
  cr=$(printf '\r')
  # Read, never sourced. This runs in the user's interactive shell, where
  # sourcing a settings file would hand it that shell, and every value is
  # re-validated here: a record left behind by an older install, or edited by
  # hand, must not be able to point the route somewhere unverified.
  #
  # A REGULAR file, too. This guard is sourced from ~/.bashrc, and opening a
  # FIFO left at this path would block every new shell before any check runs.
  if [ -f "$record" ] && [ -r "$record" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
      key=${line%%=*}
      value=${line#*=}
      [ "$key" != "$line" ] || continue
      case $key in
        CAPTURE_DIR)
          case $value in
            *"$cr"*) ;; # install.sh refuses a CR, so this is not a record it wrote
            /*) installed_dir=$value ;;
          esac
          ;;
        PROXY_PORT)
          # Empty, non-numeric, zero-prefixed or longer than a port can be. The
          # last two matter because `[ 08377 -ge 1 ]` and a forty-digit value
          # both make the shell print an arithmetic error at a login prompt.
          case $value in
            '' | *[!0-9]* | 0* | ??????*) ;;
            *) [ "$value" -le 65535 ] && installed_port=$value ;;
          esac
          ;;
      esac
    done <"$record"
  fi

  # An explicit CW_* in this shell is still the override of record; the
  # installer's verified settings come next; the built-in defaults last.
  local port="${CW_PROXY_PORT:-${installed_port:-8377}}"
  local dir="${CW_CAPTURE_DIR:-${installed_dir:-$HOME/.cache/prefix-proxy}}"
  local endpoint="http://127.0.0.1:${port}" unmarked=0 healthy=0

  # Withdraw our own route before checking again. Ownership needs the marker: a
  # matching URL alone could equally be a different local provider on this port.
  if [ -n "${CW_GUARD_ENDPOINT:-}" ] && [ "${ANTHROPIC_BASE_URL:-}" = "$CW_GUARD_ENDPOINT" ]; then
    unset ANTHROPIC_BASE_URL
  fi
  unset CW_GUARD_ENDPOINT
  # Whatever survived that and equals our endpoint is an unclaimed matching
  # route, whichever marker it was sitting beside. Deciding this BEFORE the
  # withdrawal missed a route replaced by hand next to a marker for another
  # port, and then told that shell it would not be captured while it was.
  [ "${ANTHROPIC_BASE_URL:-}" != "$endpoint" ] || unmarked=1

  cache_warmer_proxy_answers "$dir" "$port" && healthy=1

  # Anything still standing after that withdrawal belongs to someone else: a
  # provider this shell chose, or the unmarked URL we are documented to leave
  # alone. Either way this guard stands aside and says so once (bq-2472).
  # NEITHER notice interpolates a URL — a base URL can carry credentials in its
  # userinfo, an unvalidated CW_PROXY_PORT lands inside our own endpoint, and
  # these lines go to a terminal that gets logged.
  if [ -n "${ANTHROPIC_BASE_URL:-}" ]; then
    if [ "$healthy" = 1 ]; then
      [ "$unmarked" = 1 ] ||
        echo "cache-warmer guard: the capture proxy answered, but this shell already has an ANTHROPIC_BASE_URL this guard did not set, so it was left alone and these sessions will not be captured; unset it before sourcing the guard to route through the proxy." >&2
    elif [ "$unmarked" = 1 ]; then
      echo "cache-warmer guard: the capture proxy did not answer, but this shell's ANTHROPIC_BASE_URL matches this guard's endpoint and was not set by this guard (no CW_GUARD_ENDPOINT), so it was left in place; unset it if it came from an older guard." >&2
    fi
    return 0
  fi

  if [ "$healthy" = 1 ]; then
    export ANTHROPIC_BASE_URL="$endpoint"
    export CW_GUARD_ENDPOINT="$endpoint"
  fi
  return 0
}

cache_warmer_guard
