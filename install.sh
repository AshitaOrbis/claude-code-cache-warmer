#!/usr/bin/env bash
# Install (or remove) the cache-warmer systemd user timer.
#
#   ./install.sh             # install + enable timer (every 10 min)
#   ./install.sh --uninstall # stop + remove units (repo files untouched)

set -euo pipefail

REPO_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
UNIT_DIR="$HOME/.config/systemd/user"

if [[ ${1:-} == --uninstall ]]; then
  systemctl --user disable --now cache-warmer.timer 2>/dev/null || true
  rm -f "$UNIT_DIR/cache-warmer.service" "$UNIT_DIR/cache-warmer.timer"
  systemctl --user daemon-reload 2>/dev/null || echo "WARNING: user systemd daemon-reload failed (units removed anyway)"
  echo "cache-warmer timer removed."
  exit 0
fi

# Resolve absolute tool paths NOW, in the installer's interactive shell. The
# service runs in systemd's user-service environment, whose PATH usually differs
# from an interactive login shell (claude installed via npm/pnpm/mise/asdf/
# Homebrew-on-Linux is commonly visible here but invisible to systemd). Bake the
# resolved paths into the unit so the service finds the same binaries we checked.
declare -A TOOL_BIN
for dep in tmux python3 claude jq; do
  bin=$(command -v "$dep") || { echo "ERROR: '$dep' not found in PATH" >&2; exit 1; }
  TOOL_BIN[$dep]=$bin
done

if [[ ! -f "$REPO_DIR/config" ]]; then
  cp "$REPO_DIR/config.example" "$REPO_DIR/config"
  chmod 600 "$REPO_DIR/config"
  echo "Created $REPO_DIR/config (ENABLED=0 — the timer runs but does nothing yet)."
fi

mkdir -p "$UNIT_DIR"

# The warmer invokes claude/tmux/python3 as bare names (PATH lookup). Prepend
# the directories of the binaries we resolved above to the unit's PATH so the
# service resolves them identically, regardless of systemd's default PATH.
unit_path=""
for dep in claude tmux python3 jq; do
  dir=$(dirname "${TOOL_BIN[$dep]}")
  case ":$unit_path:" in
    *":$dir:"*) ;;                       # already present, skip dupes
    *) unit_path="${unit_path:+$unit_path:}$dir" ;;
  esac
done
unit_path="$unit_path:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

# Escape the script path for systemd's ExecStart. systemd splits ExecStart on
# whitespace unless arguments are double-quoted, and inside double quotes only
# `\` and `"` are special — so a repo path with spaces, quotes, or other shell
# metacharacters is safe once those two are backslash-escaped and the whole
# path is wrapped in double quotes. Call the resolved bash explicitly rather
# than relying on the script's shebang + execute bit.
script_path="$REPO_DIR/cache-warmer.sh"
escaped_script=${script_path//\\/\\\\}    # backslash first
escaped_script=${escaped_script//\"/\\\"} # then double-quote
bash_bin=$(command -v bash)

cat > "$UNIT_DIR/cache-warmer.service" << EOF
[Unit]
Description=Claude Code prompt-cache warmer (fork-based keepalive before cache expiry)
After=default.target

[Service]
Type=oneshot
ExecStart=$bash_bin "$escaped_script"
Environment=ENABLE_PROMPT_CACHING_1H=1
Environment=PATH=$unit_path
Nice=10
IOSchedulingClass=best-effort
IOSchedulingPriority=7

[Install]
WantedBy=default.target
EOF

cat > "$UNIT_DIR/cache-warmer.timer" << 'EOF'
[Unit]
Description=Run cache-warmer every 10 minutes

[Timer]
OnBootSec=5min
OnUnitActiveSec=10min
AccuracySec=1min

[Install]
WantedBy=timers.target
EOF

systemctl --user daemon-reload
systemctl --user enable --now cache-warmer.timer
echo "cache-warmer timer installed (every 10 min) — currently INERT (ENABLED=0)."
echo
echo "Before enabling:"
echo "  1. python3 $REPO_DIR/measure-ttl.py     # verify your cache TTL cliff"
echo "  2. $REPO_DIR/cache-warmer.sh --dry-run  # preview what it would warm"
echo "  3. set ENABLED=1 in $REPO_DIR/config"
echo
echo "Observe:  tail -f ~/.claude/logs/cache-warmer.log"
echo "Disable:  systemctl --user disable --now cache-warmer.timer"
echo
echo "Reminder: the 1-hour cache TTL requires ENABLE_PROMPT_CACHING_1H=1 in the"
echo "shell that launches your LIVE Claude Code sessions too (see README)."
