# claude-code-cache-warmer

Keep long Claude Code sessions warm in the Anthropic prompt cache — **without
modifying the sessions**. When an idle session approaches cache expiry, the
warmer opens a disposable *fork* of it (`claude --resume <sid> --fork-session`)
in a hidden tmux window, sends one keepalive message into the fork, verifies
the cache hit, and throws the fork away. The live session's transcript stays
byte-identical; its next real turn lands on a hot cache.

```
[12:44:20] WARM sid=710b813c age=11m user-idle=12m msgs=3 (fork-resume, live session untouched)
[12:44:30] RESULT sid=710b813c WARMED cache_read=67697 cache_creation=7626 (prefix refreshed)
```

Every warm logs a `RESULT` line with the measured `cache_read` token count from
the API's own usage accounting — ground-truth proof the warm worked.

## Why

Anthropic's prompt cache makes long agentic sessions affordable: cached prefix
tokens cost 0.1× on read, but expire after a TTL — 5 minutes by default, or
1 hour with the extended TTL (`ENABLE_PROMPT_CACHING_1H=1`, Claude Code
v2.1.108+). When the cache expires on a long session, your next message pays a
**full cache re-write at 1.25–2× base input price** on the entire context.

For a 500k-token session, that's the difference between ~50k token-equivalents
(warm resume) and ~1,000k token-equivalents (cold resume) — roughly **20×**.
One keepalive per ~50 minutes, only while you're plausibly coming back, keeps
the session hot.

## Why the obvious approaches don't work

Both were tested empirically before settling on the fork design:

1. **`claude -p` pings do not refresh a session's cache.** Print mode builds a
   *different* prompt prefix than the interactive TUI (different system prompt
   payload). A `claude -p --resume <sid> --fork-session` keepalive measured
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

The interactive fork is the only mechanism found that reproduces the exact
prefix (verified: a fork's keepalive turn read 100% of the live session's
prefix from cache) while leaving the original session untouched (verified:
byte-identical session file before/after).

## Requirements

- Linux with **systemd** (user units) and **tmux**
- **Claude Code** (tested on v2.1.173) and **python3**
- The 1-hour extended cache TTL: `export ENABLE_PROMPT_CACHING_1H=1` in the
  shell profile that launches your Claude sessions. (Without it the default
  TTL is ~5 minutes and pre-expiry warming is not practical — a fork takes
  10s–3min to spawn.)

## Install

```bash
git clone https://github.com/AshitaOrbis/claude-code-cache-warmer
cd claude-code-cache-warmer
./install.sh        # creates config from config.example, enables a 10-min systemd timer
```

Verify your actual cache TTL first (uses your existing session history; costs
nothing):

```bash
python3 measure-ttl.py
```

Look for the gap bucket where the median cache-hit ratio collapses to ~0% —
that's your expiry cliff. The default warm window (45–58 min) assumes a ~60-min
cliff; tune `WARM_MIN_AGE`/`WARM_MAX_AGE` in `config` if yours differs.

## How it decides what to warm

Every 10 minutes, for every session jsonl in the project dirs of running
Claude TUI processes:

| Gate | Default | Why |
|---|---|---|
| Cache freshness 45–58 min | `WARM_MIN_AGE`/`WARM_MAX_AGE` | younger = still warm; older = already cold (re-warming would pay a full write for a session nobody may resume) |
| Last *human* message < 4 h | `MAX_USER_IDLE_MIN=240` | caps spend at ~4–5 warms after you walk away |
| ≥ 2 real user messages | `MIN_USER_MSGS=2` | filters one-shot `claude -p` cron sessions sharing the project dir |
| ≥ 30 min since last warm | `RATELIMIT_MIN=30` | defense in depth |

Freshness counts both live API activity *and* previous fork-warms (forks never
touch the live session file, so warm state is tracked separately in
`~/.cache/cache-warmer/`).

Safety: the keepalive is typed only into the disposable fork, with
verify-then-commit (text confirmed intact in the input box before Enter); a
flock prevents overlapping runs; a session whose fork shows a prefix mismatch
(`cache_read` < 50%) is blacklisted so the cost is never paid twice.

## Cost model (be deliberate about this)

A warm costs ~0.1× of the session's prefix in cache-read tokens plus a tiny
completion, charged against your plan quota. Warming a 500k-token session for
the full 4-hour idle window ≈ 4 warms ≈ ~200k token-equivalents. That's the
premium you pay for the *option* of a cheap, fast resume. If you rarely return
to sessions within a few hours, lower `MAX_USER_IDLE_MIN` — or don't run this
tool.

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

- **TUI coupling**: readiness detection reads the fork's tmux pane. Claude
  Code TUI renders change between versions (e.g. the empty input line is `❯`
  followed by a no-break space, which `[[:space:]]` does not match). If a
  Claude Code update breaks detection, warms fail loudly (`FAIL` log lines)
  and cost nothing — they don't misfire into your sessions.
- Each warmed session briefly runs a second Claude process (the fork). Large
  sessions take 1–3 minutes to restore; the spawn timeout is 180 s.
- The keepalive instructs the fork to reply with a bare "ok"; the fork's
  jsonl is deleted afterward, so `/resume` listings stay clean.
- Works only for sessions launched from trusted directories (the fork
  auto-accepts the folder-trust dialog for dirs you've already trusted).

## License

MIT
