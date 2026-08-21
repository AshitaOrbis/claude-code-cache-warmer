#!/usr/bin/env bash
# Unit-file rendering + version gating for install.sh.
#
# Extracted from install.sh so it can be TESTED. install.sh itself installs
# systemd units and must never run inside a test suite, but the decisions it
# makes — which engine is even legal on this Claude Code version, what the
# generated units say, how a path with spaces is escaped — are exactly the
# parts worth guarding (bq-313). Sourcing this file has no side effects.

# The release where the system prompt began embedding a session-specific
# scratchpad path, which is what killed fork-warming: a fork gets a new UUID,
# so its prefix can never match its parent's (docs/V3-DIAGNOSIS.md).
V2_BROKEN_FROM=2.1.198

# version_ge <a> <b> -> 0 when a >= b, comparing dotted numeric components.
# Missing components count as 0, so 2.1 < 2.1.198.
version_ge() {
  local a=$1 b=$2 i
  local -a av bv
  IFS=. read -r -a av <<<"$a"
  IFS=. read -r -a bv <<<"$b"
  for i in 0 1 2; do
    local x=${av[i]:-0} y=${bv[i]:-0}
    [[ $x =~ ^[0-9]+$ ]] || x=0
    [[ $y =~ ^[0-9]+$ ]] || y=0
    ((x > y)) && return 0
    ((x < y)) && return 1
  done
  return 0
}

# claude_version <claude-binary> -> the dotted version, or empty if unreadable.
claude_version() {
  local bin=$1 out
  out=$("$bin" --version 2>/dev/null) || return 0
  grep -oE '[0-9]+\.[0-9]+\.[0-9]+' <<<"$out" | head -1
}

# v2_supported <version> -> 0 when the fork engine can still work there.
# An unknown/empty version is treated as UNSUPPORTED: refusing to install a
# known-broken engine is the safe default when we cannot tell.
v2_supported() {
  local v=$1
  [[ -n $v ]] || return 1
  version_ge "$v" "$V2_BROKEN_FROM" && return 1
  return 0
}

# systemd_quote <path> -> the path with the two characters systemd treats as
# special inside double quotes escaped, so ExecStart can wrap it in quotes and
# survive spaces and metacharacters.
systemd_quote() {
  local p=$1
  p=${p//\\/\\\\} # backslash first
  p=${p//\"/\\\"} # then double-quote
  printf '%s' "$p"
}

# render_proxy_unit <node-bin> <script> <port> <capture-dir> <prune-hours>
render_proxy_unit() {
  local node_bin=$1 script=$2 port=$3 capdir=$4 prune=$5
  cat <<UNIT
[Unit]
Description=Claude Code prefix-capture proxy (cache-warmer v3)
After=default.target

[Service]
Type=simple
ExecStart=$node_bin "$(systemd_quote "$script")" $port "$(systemd_quote "$capdir")"
Environment=CW_PRUNE_HOURS=$prune
Restart=always
RestartSec=2
Nice=5

[Install]
WantedBy=default.target
UNIT
}

# render_warmer_service <bash-bin> <script> <unit-path> [engine]
render_warmer_service() {
  local bash_bin=$1 script=$2 unit_path=$3 engine=${4:-v3}
  local desc="Claude Code prompt-cache warmer (v3 replay)"
  [[ $engine == v2 ]] && desc="Claude Code prompt-cache warmer (v2 fork-based keepalive)"
  cat <<UNIT
[Unit]
Description=$desc
After=default.target

[Service]
Type=oneshot
ExecStart=$bash_bin "$(systemd_quote "$script")"
Environment=ENABLE_PROMPT_CACHING_1H=1
Environment=PATH=$unit_path
Nice=10
IOSchedulingClass=best-effort
IOSchedulingPriority=7

[Install]
WantedBy=default.target
UNIT
}

render_timer() {
  cat <<'UNIT'
[Unit]
Description=Run cache-warmer every 10 minutes

[Timer]
OnBootSec=5min
OnUnitActiveSec=10min
AccuracySec=1min

[Install]
WantedBy=timers.target
UNIT
}
