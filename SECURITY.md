# Security

`claude-code-cache-warmer` is an **experimental** tool that spawns disposable
forks of your live Claude Code sessions to keep their prompt cache warm. A fork
is **not an inert sandbox** — it is a full Claude Code agent. Read this before
running it, especially on any machine that is shared, runs bypass-permission
sessions, or holds sensitive code.

## Threat model

### What the warmer does (attack surface)

On every timer fire (default every 10 minutes) the warmer, running as your user:

1. Reads the process table (`ps`) and `/proc/<pid>/cwd` + `/proc/<pid>/environ`
   of running `claude` processes to discover candidate sessions.
2. Reads Claude Code session transcripts under `~/.claude/projects/`.
3. Spawns a hidden `tmux` window running
   `claude --resume <sid> --fork-session` in the live session's working
   directory, replicating the live session's prefix-affecting flags and a
   small allowlist of prefix-affecting environment variables.
4. Types a fixed keepalive message into that fork's input box and submits it.
5. Reads the fork's transcript to verify the cache hit, then kills the fork and
   archives its transcript to `~/.cache/cache-warmer/forks/`.

It never writes to a live session transcript; the live session is observed
byte-identical before/after.

### Primary risk: armed forks inherit live-session permissions

To reproduce the cache prefix, the fork **must** match the live session's
configuration. That includes `--dangerously-skip-permissions`: **if your live
session runs with permissions bypassed, so does the fork** (see
`replicated_flags` in `cache-warmer.sh`, and the "Armed forks" section of the
README).

Consequences in bypass mode:

- The fork is the same agent, with the same tools and MCP servers, resumed in
  your **real working tree**, in a hidden tmux window you never see.
- The keepalive explicitly instructs the model to take **no action** and reply
  only `ok`. But a model is not guaranteed to obey. If it chooses to act, its
  tool calls execute **with no approval gate** — file writes, shell commands,
  network calls — unattended, once per idle session per ~50 minutes.
- This is a real risk surface, not a hypothetical. The fork is killed promptly
  after it replies, which bounds (does not eliminate) the window.

**Mitigations available to you:**

| Mitigation | Effect |
|---|---|
| `WARM_BYPASS_SESSIONS=0` in `config` | Skip bypass-permission sessions entirely (they will not be warmed). |
| `EXCLUDE_SIDS` / `INCLUDE_ONLY_SIDS` | Restrict warming to an explicit allow/deny list of session IDs. |
| Run only on single-user, trusted machines | See "Out of scope" below. |
| `ENABLED=0` (default) | The tool ships inert; you opt in deliberately. |

If you run bypass sessions and are not comfortable with the above, set
`WARM_BYPASS_SESSIONS=0` or do not run this tool.

### Other risks and how they are contained

- **Deleting the wrong session log.** A prior design risk. The fork transcript
  is now identified only by **content** (a per-warm UUID nonce present in the
  file), and is **archived, never deleted**, and never touched at all unless its
  identity is certain (regular file, inside the project dir, UUID basename, not
  the live session, contains the nonce). Directory-diff guesswork is not used.
- **Warming an unrelated session.** When a session ID cannot be read from a live
  process's argv, the warmer falls back to scanning the 10 newest transcripts in
  that project dir and cannot prove which belongs to which live TUI. The
  `MIN_USER_MSGS`, `MAX_USER_IDLE_MIN`, warm-window, and rate-limit gates bound
  the cost; every spend is logged as a `RESULT`/receipt line. Use
  `INCLUDE_ONLY_SIDS` for precise control.
- **`config` is shell code.** It is `source`d on every run. A writable or
  attacker-controlled `config` is arbitrary code execution as your user. Keep it
  `chmod 600` and treat it like a script. `install.sh` creates it `600`.
- **Folder-trust prompt is never auto-accepted.** If a fork hits the
  "trust this folder" dialog, the warm **fails loudly** and tells you to trust
  the directory manually in Claude Code. Trust is a security decision the tool
  refuses to make for you.
- **MCP / startup side effects.** Each fork boots a full Claude Code instance,
  which starts your configured MCP servers (their startup side effects fire,
  headless) and may make an auxiliary title-generation call. Forks of
  large/MCP sessions auto-confirm the **pre-selected** MCP servers (the live
  session already has them in its prefix); they never press "reject all".
- **Env replication is an allowlist.** Only a fixed set of prefix-affecting
  variables (model selection, cache-TTL, output/thinking-token, and simple-mode
  flags) is copied from `/proc/<pid>/environ` into the fork. Secrets, `PATH`,
  credentials, and everything else are **not** replicated.
- **Quota spend.** A successful warm costs ~0.1× the prefix in cache-read
  tokens against your plan quota; a mismatch can cost up to two full cache
  writes before the two-strike cooldown blacklist trips. See the README "Cost
  model" section. This is a financial, not a confidentiality, risk — but it is
  real and unattended.

### Out of scope / explicitly unsupported

- **Untrusted multi-user machines.** The warmer reads other-process metadata
  (`/proc`), types into tmux panes, and spawns agents in your working tree. Do
  **not** run it where you do not trust every user who can reach your session,
  your `config`, or your `~/.cache/cache-warmer/` and `~/.claude/` trees.
- **Sandboxing the fork.** The tool does not (and cannot, by design) sandbox the
  fork — sandboxing would change the prefix and defeat the purpose.
- **Non-Linux environments.** See the compatibility matrix below.

## Compatibility matrix

The tool couples to Claude Code internals (TUI rendering, `--fork-session`
behavior, session-log JSONL schema, process argv shape, project-dir naming)
that change between versions. It is not version-pinned and can break silently
when any of these shift. Failures generally fail closed (a `FAIL` log line, no
spend), but a TUI-render change *after* the keepalive is sent can cost one fork
request.

| Component | Verified | Notes |
|---|---|---|
| OS | GNU/Linux, Ubuntu 24.04 (kernel 6.17) | Requires `/proc`, GNU `stat`/`ps`/`date`/`readlink`, `flock`. macOS, BusyBox/Alpine, and minimal containers are **not supported**. |
| Bash | 5.2.x (requires **4.4+**) | Uses associative arrays, `[[ =~ ]]`, `printf -v`, `printf %q`. |
| tmux | 3.4 | Readiness/input handling parses pane text; older/newer tmux render differences can break detection. |
| Claude Code | developed against **v2.1.173/174**; the README/CHANGELOG note binary drift across 2.1.173→174 shifting fork prompts | A binary update shifts the system-prompt prefix; the warmer records the `claude` version+mtime at warm time and **skips on drift** rather than warming against a mismatched cache (see `claude_binary_fingerprint`). |
| python3 | 3.12 | Used for all JSONL parsing. |
| jq | 1.7 | Used to emit structured per-warm receipts; absence degrades gracefully (a `note:` log line, no receipt). |
| systemd | user services + lingering | `loginctl enable-linger $USER` is needed if you SSH in, detach tmux, and log out, or the timer stops at logout. |
| Provider | Anthropic first-party (1-hour extended TTL via `ENABLE_PROMPT_CACHING_1H=1`) | Other providers / TTL behaviors are untested. |

"Verified" means observed working on the listed version on the developer's
machine, not a guarantee for other versions.

## Reporting a vulnerability

This is a personal, experimental project with no formal support channel. If you
find a security issue, open an issue on the GitHub repository describing the
problem and the impact. Do not include secrets, real session transcripts, or
private paths in a public issue.

## Hardening checklist before enabling

1. `python3 measure-ttl.py` — confirm your TTL cliff (free, no spend).
2. `./cache-warmer.sh --dry-run` — see exactly what it would warm.
3. Decide on `WARM_BYPASS_SESSIONS` (set `0` if you run bypass sessions and are
   not comfortable with armed forks).
4. Confirm `config` is `chmod 600` and on a filesystem only you can write.
5. Set `ENABLED=1` only after the above.
6. Watch `~/.claude/logs/cache-warmer.log` and
   `~/.cache/cache-warmer/receipts.jsonl` for the first few runs.
