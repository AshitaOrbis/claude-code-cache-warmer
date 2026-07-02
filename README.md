# claude-code-cache-warmer

> **⚠ v2 (fork-based, this README) is BROKEN on Claude Code ≥ 2.1.198** — the
> system prompt now embeds a session-specific scratchpad path, so a fork's
> prefix can never match its parent's and every warm pays a full cache write
> for zero hits. **Use v3 (replay-based) instead**: `prefix-proxy.js` +
> `replay-warmer.sh` + `warm-replay.py`, which replays each session's own
> captured request byte-for-byte (verified: `cache_read=71383,
> cache_creation=0`). Diagnosis + v3 architecture: [docs/V3-DIAGNOSIS.md](docs/V3-DIAGNOSIS.md).
>
> **Status: experimental.** v2 was built and verified on Claude Code v2.1.173 /
> GNU Linux, 2026-06-11; v3 on v2.1.198, 2026-07-02. Both couple to Claude
> Code internals that can change between versions. Disabled by default; read
> this whole README before enabling.

Keep long Claude Code sessions warm in the Anthropic prompt cache — **without
modifying the sessions**. When an idle session approaches cache expiry, the
warmer opens a disposable *fork* of it (`claude --resume <sid> --fork-session`)
in a hidden tmux window, sends one nonce-tagged keepalive into the fork,
verifies the cache hit from the fork's own usage record, and archives the
fork. The live session's transcript is left untouched (observed byte-identical
before/after on v2.1.173); its next real turn lands on a hot cache.

Real receipts: a 700k-token session warmed organically at 46 minutes idle
(v0.2.x format), and a v0.3.0 verification run with prefix classification:

```
[13:33:36] RESULT sid=31e0bcba WARMED cache_read=701051 cache_creation=914 (request served from cache; TTL re-armed)
[14:17:10] RESULT sid=c2251586 WARMED class=verified_full_hit cache_read=68277 cache_creation=7653 expected=75875 nonce=58b6b941
```

Every warm logs a `RESULT` line with the measured `cache_read` token count
from the API's usage accounting, classified against the live session's
expected prefix size (`verified_full_hit` / `partial_hit` / `short_request` /
`cold_or_mismatch`). A receipt is **evidence**, not an absolute guarantee —
but a `verified_full_hit` means the fork's request read ≥80% of the live
session's prefix volume from cache, which is what re-arms the TTL on those
blocks. Anything else is loud and auto-contained (see below).

## Why

Anthropic's prompt cache makes long agentic sessions affordable: cached prefix
tokens cost 0.1× on read, but expire after a TTL — 5 minutes by default, or
1 hour with the extended TTL (`ENABLE_PROMPT_CACHING_1H=1`, Claude Code
v2.1.108+). When the cache expires on a long session, your next message pays a
**full cache re-write at 1.25–2× base input price** on the entire context.

For a 700k-token session, that's the difference between ~70k token-equivalents
(warm resume) and ~1,400k token-equivalents (cold resume at 2×) — roughly
**20×**. One keepalive per ~50 minutes, only while you're plausibly coming
back, keeps the session hot.

## Why the obvious approaches don't work

All tested empirically before settling on the fork design:

1. **`claude -p` pings do not refresh a session's cache.** Print mode builds a
   *different* prompt prefix than the interactive TUI. A
   `claude -p --resume <sid> --fork-session` keepalive measured
   `cache_read=0` and paid a full parallel cache write — it warms nothing the
   live session uses. The cache is keyed on exact prefix bytes; only an
   interactive resume reproduces them.
2. **Anything that doesn't reach the API does nothing.** The TTL clock lives
   server-side and resets only when a request containing the cached prefix is
   served. Local heartbeat files, status-line tricks, or touching the session
   file have no effect.
3. **Typing keepalives into the live session works but pollutes it** — every
   ping becomes a permanent transcript entry. That was v1 of this tool; the
   fork design replaced it.

## Requirements

- **GNU/Linux** with **systemd user services** and **tmux** (also assumes
  `/proc`, GNU `stat`/`ps`/`date`, `flock`, **Bash 4.4+**). macOS, minimal
  containers, and BusyBox systems are not supported. If you SSH in, detach
  tmux, and log out, enable `loginctl enable-linger $USER` or the timer stops
  at logout.
- **Claude Code** (developed against v2.1.173) and **python3**
- The 1-hour extended cache TTL enabled in **both** places:
  - your shell profile (`export ENABLE_PROMPT_CACHING_1H=1`) for live sessions
  - the warmer's fork environment — handled automatically (the systemd unit
    and the fork spawn both set it explicitly, since systemd user services
    never source shell profiles)

  Without the 1h TTL the default is ~5 minutes and pre-expiry warming is not
  practical (a fork takes 10s–3min to spawn).

## Install

```bash
git clone https://github.com/AshitaOrbis/claude-code-cache-warmer
cd claude-code-cache-warmer
./install.sh        # installs a 10-min systemd timer — INERT until you enable it
```

The tool ships **disabled** (`ENABLED=0` in `config`). Before enabling:

```bash
python3 measure-ttl.py        # verify your cache TTL from existing history (free)
./cache-warmer.sh --dry-run   # preview exactly what it would warm right now
$EDITOR config                # set ENABLED=1
```

`measure-ttl.py` buckets cache-hit ratios against idle gaps across your recent
sessions. It's a heuristic (it pools models/providers/versions together), but
the expiry cliff — the gap bucket where median hits collapse to ~0% — is
usually unmistakable. The default warm window (45–58 min) assumes a ~60-min
cliff; tune `WARM_MIN_AGE`/`WARM_MAX_AGE` if yours differs.

## How it decides what to warm

Every 10 minutes, candidates are the explicit `--resume` session IDs of
running Claude TUI processes, plus the 10 most-recent session logs in each
running TUI's project directory. Each candidate must pass ALL gates:

| Gate | Default | Why |
|---|---|---|
| Cache freshness 45–58 min | `WARM_MIN_AGE`/`WARM_MAX_AGE` | younger = still warm; older = already cold (re-warming would pay a full write for a session nobody may resume) |
| Last *human* message < 4 h | `MAX_USER_IDLE_MIN=240` | caps spend at ~4–5 warms after you walk away |
| ≥ 2 real user messages | `MIN_USER_MSGS=2` | filters one-shot `claude -p` cron sessions sharing the project dir |
| ≥ 30 min since last attempt | `RATELIMIT_MIN=30` | failures don't fake freshness, but can't be hammered either |

**Known limitation**: when a session ID can't be read from the process's
arguments, project-directory scanning cannot prove which log belongs to which
live TUI — so the warmer may occasionally warm a recently-active session in
the same directory that nobody returns to. The gates above bound that cost,
and every spend is visible as a RESULT line. Use `EXCLUDE_SIDS` /
`INCLUDE_ONLY_SIDS` for precise control.

## Safety mechanics

- The keepalive is typed **only into the disposable fork**, never a live
  session — and only after the text is verified intact on the fork's input
  line (verify-then-commit).
- Each warm carries a unique **nonce**; the fork's transcript is identified by
  *content* (the file containing that nonce), never by directory-diff
  guesswork, and the measured usage is taken from the assistant turn that
  directly answers the nonce-tagged message.
- Fork transcripts are **archived** to `~/.cache/cache-warmer/forks/` (7-day
  retention) — never deleted on the spot, and never touched at all if their
  identity isn't certain.
- A folder-trust prompt in the fork **fails the warm loudly** — it is never
  auto-accepted.
- Any result class other than `verified_full_hit` logs a warning first and
  blacklists the session only on the second consecutive occurrence; the
  `class=` field says *why* (mid-prefix divergence vs. short request vs.
  root-divergence/cold).
- A flock prevents overlapping runs; an exit trap kills the in-flight fork
  window if the script dies mid-warm; orphaned fork tmux sessions are removed
  only when every window matches the warmer's naming pattern.
- `config` is **sourced as shell code** — keep it `chmod 600` and treat it
  like a script.

## Armed forks (read this before enabling)

The fork is **not an inert sandbox** — it is the same Claude Code agent, with
the same tools, MCP servers, and permission mode as your live session, resumed
in the same working directory. To reproduce the cache prefix it *must* match
the live configuration, so if your live session runs
`--dangerously-skip-permissions`, **so does the fork**.

That means: in bypass mode, if the model chooses to act on the keepalive
instead of just replying `ok` (rare, but this rolls the dice every ~50 minutes
per idle session, unattended), its tool calls execute with no approval gate,
in your real working tree, from a hidden tmux window you never see. The
keepalive text explicitly instructs the fork to take no action, and the fork
is killed as soon as it replies — but this is a real risk surface, not a
hypothetical.

Mitigations in the tool: the keepalive is a do-not-act instruction; the reply
loop kills the fork window promptly; `WARM_BYPASS_SESSIONS=0` skips
bypass-permission sessions entirely (at the cost of not warming them). If you
run bypass sessions and aren't comfortable with the above, set that to `0`.

## Cost model (be deliberate about this)

A successful warm costs ~0.1× of the session's prefix in cache-read tokens
plus a tiny completion, charged against your plan quota. Warming a 500k-token
session for the full 4-hour idle window ≈ 4 warms ≈ ~200k token-equivalents.
That's the premium you pay for the *option* of a cheap, fast resume. A
mismatch costs up to two full cache writes on the fork's prefix before the
two-strike blacklist trips (then a `MISMATCH_COOLDOWN_DAYS` cooldown). If you
rarely return to sessions within a few hours, lower `MAX_USER_IDLE_MIN` — or
don't run this tool.

## Observe

```bash
tail -f ~/.claude/logs/cache-warmer.log     # decisions + RESULT receipts
./cache-warmer.sh --dry-run                 # what would happen right now
grep -E 'RESULT|FAIL' ~/.claude/logs/cache-warmer.log | tail
```

Disable: set `ENABLED=0` in `config` (soft), or
`systemctl --user disable --now cache-warmer.timer` (hard), or
`./install.sh --uninstall`.

## Caveats

- **TUI coupling**: readiness detection reads the fork's tmux pane, and
  Claude Code TUI renders change between versions (e.g. the empty input line
  is `❯` followed by a no-break space, which `[[:space:]]` does not match).
  If an update breaks detection, warms fail loudly *before* the keepalive is
  sent and cost nothing; failures after send are bounded to one fork request.
- Each warm briefly runs a second Claude process (the fork). Large sessions
  take 1–3 minutes to restore; the spawn timeout is 180 s.
- Forks work only in directories you have already trusted in Claude Code.
- Not for untrusted multi-user machines: the warmer reads process lists and
  session logs, and types into tmux panes it owns.
- **Deterministic prefix drift skips, not warms**: if the cache-freshness
  reference and now fall on different calendar days, or the live session was
  launched with a prefix-affecting flag the warmer can't replicate
  (`--append-system-prompt`, `--mcp-config`, `--settings`, `--add-dir`, …),
  the session is *skipped* (logged) rather than warmed-and-mismatched. A
  Claude Code auto-update or a CLAUDE.md/MCP edit between the live session's
  last turn and the warm can still cause a one-off mismatch; that's contained
  by the two-strike cooldown blacklist.
- Each warm boots a full Claude Code instance, which starts your configured
  MCP servers (their startup side effects fire, headless) and may make an
  auxiliary title-generation call. Factor that into "cost nothing" expectations.
- The honest upstream fix would be a first-class Claude Code command that
  refreshes a session's cache without a transcript entry. Until then, this is
  a careful workaround, not a guarantee.

## License

MIT
