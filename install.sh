#!/usr/bin/env bash
# Install (or remove) the cache-warmer systemd user units.
#
#   ./install.sh                 # install the v3 REPLAY engine (default)
#   ./install.sh --engine v2     # install the legacy v2 FORK engine
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
PROXY_PORT=${CW_PROXY_PORT:-8377}
CAPTURE_DIR=${CW_CAPTURE_DIR:-$HOME/.cache/prefix-proxy}
PRUNE_HOURS=${CW_PRUNE_HOURS:-6}

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
        "$UNIT_DIR/prefix-proxy.service"
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

if [[ $ENGINE == v3 ]]; then
  # One capture directory, created here and named explicitly in BOTH units.
  # The two halves defaulting independently is its own finding (bq-318).
  mkdir -p "$CAPTURE_DIR"
  chmod 700 "$CAPTURE_DIR"

  render_proxy_unit "${TOOL_BIN[node]}" "$REPO_DIR/prefix-proxy.js" \
    "$PROXY_PORT" "$CAPTURE_DIR" "$PRUNE_HOURS" >"$UNIT_DIR/prefix-proxy.service"
  render_warmer_service "$bash_bin" "$REPO_DIR/replay-warmer.sh" "$unit_path" v3 "$CAPTURE_DIR" \
    >"$UNIT_DIR/cache-warmer.service"
else
  render_warmer_service "$bash_bin" "$REPO_DIR/cache-warmer.sh" "$unit_path" v2 \
    >"$UNIT_DIR/cache-warmer.service"
fi

render_timer >"$UNIT_DIR/cache-warmer.timer"

systemctl --user daemon-reload
if [[ $ENGINE == v3 ]]; then
  systemctl --user enable --now prefix-proxy.service
fi
systemctl --user enable --now cache-warmer.timer

if [[ $ENGINE == v3 ]]; then
  echo "cache-warmer v3 installed — currently INERT (ENABLED=0)."
  echo "  prefix-proxy.service  capturing to $CAPTURE_DIR (retention ${PRUNE_HOURS}h)"
  echo "  cache-warmer.timer    replay-warmer.sh every 10 min"
  echo
  echo "Before enabling:"
  echo "  1. curl -fs http://127.0.0.1:$PROXY_PORT/warmer-health   # proxy answers with its nonce"
  echo "  2. route your sessions through it: export ANTHROPIC_BASE_URL=http://127.0.0.1:$PROXY_PORT"
  echo "     (see README — the guard only exports it when the port answers)"
  echo "  3. $REPO_DIR/replay-warmer.sh --dry-run   # preview what it would warm"
  echo "  4. set ENABLED=1 in $REPO_DIR/config"
else
  echo "cache-warmer v2 (fork engine) installed — currently INERT (ENABLED=0)."
  echo
  echo "Before enabling:"
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
