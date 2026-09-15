#!/usr/bin/env bash
# Install (or remove) the cache-warmer systemd user units.
#
#   ./install.sh                 # install the v3 REPLAY engine (default)
#   ./install.sh --engine v2     # install the legacy v2 FORK engine
#   ./install.sh --defer-restart # stage updates; leave an active proxy running
#   ./install.sh --uninstall     # stop + remove units (repo files untouched)
#
# v3 (default) installs TWO units:
#   prefix-proxy.service   node prefix-proxy.js — captures request prefixes
#   cache-warmer.timer     -> cache-warmer.service -> replay-warmer.sh
# They share one capture directory, passed explicitly to both so the two halves
# can never disagree about where captures live.
#
# v2 is the fork-based engine. It is BROKEN on Claude Code >= 2.1.198: the
# system prompt embeds a session-specific scratchpad path, so a fork's prefix
# can never match its parent's and every "warm" pays a full cache WRITE for
# zero hits (docs/V3-DIAGNOSIS.md). Installing it there is a spend regression,
# so this script refuses unless --force-v2 is passed. Before bq-313, ./install.sh
# — the only command in the README — silently installed exactly that.

set -euo pipefail

REPO_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
UNIT_DIR="$HOME/.config/systemd/user"
# shellcheck source=lib/units.sh
source "$REPO_DIR/lib/units.sh"

ENGINE=v3
FORCE_V2=0
DEFER_RESTART=0

usage() {
  sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'
}

# Strict argument parsing — an unrecognised flag must never fall through into
# "install the default engine" (the v3 warmer learned the same lesson about
# --dry-run in bq-320).
while (($#)); do
  case $1 in
    --uninstall)
      systemctl --user disable --now cache-warmer.timer 2>/dev/null || true
      systemctl --user disable --now prefix-proxy.service 2>/dev/null || true
      rm -f "$UNIT_DIR/cache-warmer.service" "$UNIT_DIR/cache-warmer.timer" \
        "$UNIT_DIR/prefix-proxy.service" "$UNIT_DIR/prefix-proxy.applied" \
        "$UNIT_DIR/prefix-proxy.settings"
      systemctl --user daemon-reload 2>/dev/null ||
        echo "WARNING: user systemd daemon-reload failed (units removed anyway)"
      echo "cache-warmer units removed."
      exit 0
      ;;
    --engine)
      ENGINE=${2:?--engine needs a value: v2 or v3}
      shift 2
      continue
      ;;
    --engine=*) ENGINE=${1#*=} ;;
    --force-v2) FORCE_V2=1 ;;
    --defer-restart) DEFER_RESTART=1 ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      echo "ERROR: unknown argument '$1'" >&2
      usage >&2
      exit 2
      ;;
  esac
  shift
done

case $ENGINE in
  v2 | v3) ;;
  *)
    echo "ERROR: --engine must be v2 or v3 (got '$ENGINE')" >&2
    exit 2
    ;;
esac

# Resolve absolute tool paths NOW, in the installer's interactive shell. The
# service runs in systemd's user-service environment, whose PATH usually differs
# from an interactive login shell (claude/node installed via npm/pnpm/mise/asdf/
# Homebrew-on-Linux is commonly visible here but invisible to systemd). Bake the
# resolved paths into the unit so the service finds the same binaries we checked.
declare -A TOOL_BIN
deps=(python3 jq claude)
[[ $ENGINE == v3 ]] && deps+=(node) || deps+=(tmux)
# v3 verifies the running proxy's nonce over HTTP after (re)starting it (bq-1997).
[[ $ENGINE != v3 ]] || deps+=(curl)
for dep in "${deps[@]}"; do
  bin=$(command -v "$dep") || {
    echo "ERROR: '$dep' not found in PATH" >&2
    [[ $dep == node ]] && echo "       v3 captures prefixes with a small Node proxy; install Node >= 18." >&2
    exit 1
  }
  TOOL_BIN[$dep]=$bin
done

CC_VERSION=$(claude_version "${TOOL_BIN[claude]}")
if [[ $ENGINE == v2 ]] && ! v2_supported "$CC_VERSION" && ((FORCE_V2 == 0)); then
  cat >&2 <<MSG
ERROR: refusing to install the v2 fork engine.

  Claude Code version: ${CC_VERSION:-unknown}
  v2 is broken from:   $V2_BROKEN_FROM

Since $V2_BROKEN_FROM the system prompt embeds a session-specific scratchpad
path, so a forked session's prefix can never match its parent's: every warm
pays a full cache WRITE and reads nothing (docs/V3-DIAGNOSIS.md). Installing it
here would cost you money and warm nothing.

Use the replay engine instead:   ./install.sh
Override anyway (not advised):   ./install.sh --engine v2 --force-v2
MSG
  exit 1
fi

if [[ ! -f "$REPO_DIR/config" ]]; then
  cp "$REPO_DIR/config.example" "$REPO_DIR/config"
  chmod 600 "$REPO_DIR/config"
  echo "Created $REPO_DIR/config (ENABLED=0 — the timer runs but does nothing yet)."
fi

# The shared settings come from the same trusted shell config the warmer
# sources, but it is read in a subshell: nothing it assigns (ENGINE, UNIT_DIR,
# DEFER_RESTART, ...) can overwrite a decision this installer already made.
# Only the four shared settings cross back, one per line, and explicit CW_*
# overrides still win (bq-1996).
read_shared_settings() {
  (
    ENABLED=0
    CAPTURE_DIR="$HOME/.cache/prefix-proxy"
    PRUNE_HOURS=6
    PROXY_PORT=8377
    # shellcheck disable=SC1091
    source "$REPO_DIR/config" >/dev/null || exit 1
    printf '%s\0' "$ENABLED" "$CAPTURE_DIR" "$PRUNE_HOURS" "$PROXY_PORT"
  )
}
# NUL-separated through a file: command substitution would drop NULs and strip
# trailing newlines, losing an empty value or splitting one that spans lines
# before an explicit override had the chance to replace it.
settings_file=$(mktemp)
if ! read_shared_settings >"$settings_file"; then
  rm -f "$settings_file"
  echo "ERROR: could not read the shared settings from $REPO_DIR/config" >&2
  exit 2
fi
mapfile -d '' -t shared <"$settings_file"
rm -f "$settings_file"
if ((${#shared[@]} != 4)); then
  echo "ERROR: could not read the shared settings from $REPO_DIR/config" >&2
  exit 2
fi
ENABLED=${shared[0]}
CAPTURE_DIR=${CW_CAPTURE_DIR-${shared[1]}}
PRUNE_HOURS=${CW_PRUNE_HOURS-${shared[2]}}
PROXY_PORT=${CW_PROXY_PORT-${shared[3]}}
if [[ $CAPTURE_DIR != /* || $CAPTURE_DIR == *$'\n'* || $CAPTURE_DIR == *$'\r'* \
      || ! $PRUNE_HOURS =~ ^[1-9][0-9]*$ || ! $PROXY_PORT =~ ^[1-9][0-9]{0,4}$ \
      || ! $ENABLED =~ ^[01]$ ]] || ((PROXY_PORT > 65535)); then
  echo "ERROR: CAPTURE_DIR must be absolute, PRUNE_HOURS positive integer, PROXY_PORT 1-65535, ENABLED 0 or 1" >&2
  exit 2
fi

mkdir -p "$UNIT_DIR"

# The warmer invokes its tools as bare names (PATH lookup). Prepend the
# directories of the binaries we resolved above to the unit's PATH so the
# service resolves them identically, regardless of systemd's default PATH.
unit_path=""
for dep in "${deps[@]}"; do
  dir=$(dirname "${TOOL_BIN[$dep]}")
  case ":$unit_path:" in
    *":$dir:"*) ;; # already present, skip dupes
    *) unit_path="${unit_path:+$unit_path:}$dir" ;;
  esac
done
unit_path="$unit_path:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

bash_bin=$(command -v bash)

# Pause scheduling while the units and the running proxy change (bq-1997). From
# here until scheduling is restored, any unsuccessful exit says the timer is
# still stopped instead of leaving that to be discovered.
timer_paused=0
# Both of these are read by the EXIT trap below, so both are set BEFORE it is
# installed: an inherited environment variable of the same name would otherwise
# be treated as a temporary file this run created, and deleted on the way out.
settings_tmp=""
report_paused_timer() {
  local status=$?
  # A settings record half-published below leaves its temporary file behind.
  # Only ever the path mktemp handed THIS run: the variable starts empty and is
  # cleared again the moment the record is published.
  [[ -z $settings_tmp ]] || rm -f "$settings_tmp"
  if ((status != 0 && timer_paused)); then
    echo "NOTE: this install stopped cache-warmer.timer and it is still stopped." >&2
    echo "      Fix the error above, then re-run ./install.sh to verify the proxy and restore it." >&2
  fi
}
trap report_paused_timer EXIT
if systemctl --user is-active --quiet cache-warmer.timer; then
  systemctl --user stop cache-warmer.timer
  timer_paused=1
fi

if [[ $ENGINE == v3 ]]; then
  # prefix-proxy.applied names the code and settings the RUNNING proxy was
  # verified to have. It is withdrawn here, before any unit file changes, and
  # written back only after verification below. Anything that stops this run in
  # between (a failed reload or enable, an interrupt, a deferral) therefore
  # leaves no fingerprint, and the next install restarts and verifies the proxy
  # rather than trusting a match with what it last verified, which a proxy
  # restarted by systemd from the new unit would no longer be running.
  applied=""
  [[ ! -f $UNIT_DIR/prefix-proxy.applied ]] || applied=$(<"$UNIT_DIR/prefix-proxy.applied")
  rm -f "$UNIT_DIR/prefix-proxy.applied"

  # One capture directory, created here and named explicitly in BOTH units.
  # The two halves defaulting independently is its own finding (bq-318).
  mkdir -p "$CAPTURE_DIR"
  chmod 700 "$CAPTURE_DIR"

  render_proxy_unit "${TOOL_BIN[node]}" "$REPO_DIR/prefix-proxy.js" \
    "$PROXY_PORT" "$CAPTURE_DIR" "$PRUNE_HOURS" >"$UNIT_DIR/prefix-proxy.service"
  render_warmer_service "$bash_bin" "$REPO_DIR/replay-warmer.sh" "$unit_path" v3 "$CAPTURE_DIR" "$PRUNE_HOURS" \
    >"$UNIT_DIR/cache-warmer.service"
else
  # v2 forks sessions and has no capture proxy, so what a previous v3 install
  # left running has to be withdrawn here, not merely described as gone
  # (bq-2558). Removing the settings record alone withdrew nothing: a missing
  # record tells the shell guard to try the default directory and port, a proxy
  # still running there passes its nonce check, and so even a fresh shell went
  # on routing through it and having its requests captured.
  rm -f "$UNIT_DIR/prefix-proxy.settings" "$UNIT_DIR/prefix-proxy.applied"
  # Enabled counts even when nothing in $UNIT_DIR names the unit: a proxy enabled
  # from another user unit directory is not running now, but it starts at the
  # next login and the guard would route to it again.
  proxy_enabled() {
    [[ $(systemctl --user is-enabled prefix-proxy.service 2>/dev/null) == enabled* ]]
  }
  if [[ -e $UNIT_DIR/prefix-proxy.service ]] || systemctl --user is-active --quiet prefix-proxy.service ||
    proxy_enabled; then
    # Stopped and disabled are checked, not assumed: a transition that could not
    # withdraw the proxy is not a completed one, and the exit trap says the timer
    # is still stopped.
    if ! systemctl --user disable --now prefix-proxy.service ||
      systemctl --user is-active --quiet prefix-proxy.service || proxy_enabled; then
      echo "ERROR: could not stop and disable prefix-proxy.service, the v3 capture proxy; it may still be capturing the sessions routed through it. Stop it with 'systemctl --user disable --now prefix-proxy.service', then re-run this install." >&2
      exit 1
    fi
    rm -f "$UNIT_DIR/prefix-proxy.service"
    echo "NOTE: stopped and disabled the v3 capture proxy (prefix-proxy.service)." >&2
    echo "      A shell that was already routed through it keeps ANTHROPIC_BASE_URL pointing at the stopped" >&2
    echo "      listener, and Claude Code started there cannot reach the API. Sourcing shell-guard.sh again" >&2
    echo "      withdraws a route the guard exported; any other route to the listener (set by hand, left by" >&2
    echo "      an older guard, or spelled differently) must be unset or replaced. A session running through" >&2
    echo "      it has lost its connection." >&2
  fi
  render_warmer_service "$bash_bin" "$REPO_DIR/cache-warmer.sh" "$unit_path" v2 \
    >"$UNIT_DIR/cache-warmer.service"
fi

render_timer >"$UNIT_DIR/cache-warmer.timer"

systemctl --user daemon-reload
if [[ $ENGINE == v3 ]]; then
  fingerprint=$(cat "$UNIT_DIR/prefix-proxy.service" "$REPO_DIR/prefix-proxy.js" | sha256sum)
  if systemctl --user is-active --quiet prefix-proxy.service; then
    # Active is not enabled: a proxy started by hand would not come back at the
    # next login, while the timer enabled below would.
    systemctl --user enable prefix-proxy.service
    if [[ $fingerprint != "$applied" ]]; then
      if ((DEFER_RESTART)); then
        timer_paused=0 # the message says so
        echo "restart required: proxy updates staged; cache-warmer.timer stopped. Re-run ./install.sh when in-flight requests can be interrupted."
        exit 0
      fi
      systemctl --user restart prefix-proxy.service
    fi
  else
    systemctl --user enable --now prefix-proxy.service
  fi
  verified=0
  # Up to 25 probes, each allowed 1s plus a 0.2s pause (~30s worst case).
  for ((attempt = 0; attempt < 25; attempt++)); do
    nonce=$(cat "$CAPTURE_DIR/.health-nonce" 2>/dev/null) || nonce=""
    live=$(curl -fs --max-time 1 "http://127.0.0.1:$PROXY_PORT/warmer-health" 2>/dev/null) || live=""
    if [[ -n $nonce && $nonce == "$live" ]]; then
      verified=1
      break
    fi
    sleep 0.2
  done
  if ((verified == 0)); then
    timer_paused=0 # the message says so
    # The proxy we just started did not answer for these settings, so the
    # settings on file describe nothing that was verified. Withdraw them rather
    # than leave the shell guard routing at a proxy we could not confirm.
    rm -f "$UNIT_DIR/prefix-proxy.settings"
    echo "ERROR: proxy nonce verification failed; cache-warmer.timer remains stopped; re-run ./install.sh" >&2
    exit 1
  fi
  printf '%s\n' "$fingerprint" > "$UNIT_DIR/prefix-proxy.applied"
  # The third consumer of these settings is the shell guard, and it is the one
  # that used to resolve them independently (bq-2473). Publish the values this
  # proxy was just verified against, so a fresh shell routes to the same place.
  # Only HERE: a staged --defer-restart leaves the previously verified proxy
  # running and its record untouched, and a failed verification withdraws it —
  # what is published has always been checked against a live nonce.
  # mktemp, not a name built from $$: a pathname that already exists would be
  # truncated rather than created, keeping whatever mode it had, and a symlink
  # left there would be followed — writing through it and then publishing the
  # link itself as the record. Exclusive creation at mode 600 avoids both.
  if [[ -d $UNIT_DIR/prefix-proxy.settings ]]; then
    echo "ERROR: $UNIT_DIR/prefix-proxy.settings is a directory; remove it and re-run ./install.sh" >&2
    exit 2
  fi
  settings_tmp=$(umask 077 && mktemp "$UNIT_DIR/.prefix-proxy.settings.XXXXXX")
  printf 'CAPTURE_DIR=%s\nPROXY_PORT=%s\n' "$CAPTURE_DIR" "$PROXY_PORT" >"$settings_tmp"
  chmod 600 "$settings_tmp"
  # -T so the destination is a name to replace, never a directory to move into:
  # the check above cannot cover a directory created between it and this line,
  # and without -T that race publishes no record and hides the temporary file
  # inside it. Failing here is right; the exit trap removes the temporary file.
  mv -fT -- "$settings_tmp" "$UNIT_DIR/prefix-proxy.settings"
  settings_tmp=""
fi
systemctl --user enable --now cache-warmer.timer
timer_paused=0

warming_state=disabled
[[ $ENABLED != 1 ]] || warming_state=enabled

if [[ $ENGINE == v3 ]]; then
  echo "cache-warmer v3 installed — scheduled warming $warming_state (ENABLED=$ENABLED)."
  echo "  prefix-proxy.service  ACTIVE; capturing eligible requests to $CAPTURE_DIR (retention ${PRUNE_HOURS}h)"
  echo "  cache-warmer.timer    replay-warmer.sh every 10 min"
  echo
  echo "Next steps (before enabling a new config):"
  echo "  1. curl -fs http://127.0.0.1:$PROXY_PORT/warmer-health   # proxy answers with its nonce"
  echo "  2. route your sessions through it: export ANTHROPIC_BASE_URL=http://127.0.0.1:$PROXY_PORT"
  echo "     (see README — the guard only exports it when the port answers)"
  echo "  3. $REPO_DIR/replay-warmer.sh --dry-run   # preview what it would warm"
  echo "  4. set ENABLED=1 in $REPO_DIR/config"
else
  echo "cache-warmer v2 (fork engine) installed — scheduled warming $warming_state (ENABLED=$ENABLED)."
  echo
  echo "Next steps (before enabling a new config):"
  echo "  1. python3 $REPO_DIR/measure-ttl.py     # verify your cache TTL cliff"
  echo "  2. $REPO_DIR/cache-warmer.sh --dry-run  # preview what it would warm"
  echo "  3. set ENABLED=1 in $REPO_DIR/config"
fi
echo
echo "Observe:  tail -f ~/.claude/logs/cache-warmer.log"
echo "Remove:   $REPO_DIR/install.sh --uninstall"
echo
echo "Reminder: the 1-hour cache TTL requires ENABLE_PROMPT_CACHING_1H=1 in the"
echo "shell that launches your LIVE Claude Code sessions too (see README)."
