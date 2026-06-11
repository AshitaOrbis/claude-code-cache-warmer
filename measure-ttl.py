#!/usr/bin/env python3
"""Measure your effective Anthropic prompt-cache TTL from Claude Code history.

Every assistant message in ~/.claude/projects/*/*.jsonl records per-turn cache
usage (cache_read_input_tokens / cache_creation_input_tokens). By bucketing
the gap between consecutive turns against the fraction of the prompt prefix
served from cache, the cache-expiry cliff becomes directly visible — no API
spend required.

Interpreting output:
  - High median hit ratios up to some gap, then a collapse to ~0%, marks the
    effective TTL. With ENABLE_PROMPT_CACHING_1H=1 the cliff sits ~55-65 min;
    with the default 5-minute TTL it sits just past 5 min.
  - Set cache-warmer's WARM_MIN_AGE/WARM_MAX_AGE comfortably inside the cliff
    (e.g. 45/58 for a ~60-min TTL).

Usage: python3 measure-ttl.py [--files N]   (default: 300 most recent sessions)
"""

import argparse
import datetime
import glob
import json
import os
import statistics

BUCKETS = [
    (0.5, 4), (4, 10), (10, 30), (30, 40), (40, 50), (50, 55),
    (55, 60), (60, 65), (65, 70), (70, 80), (80, 120), (120, float("inf")),
]
MIN_PREFIX_TOKENS = 20_000  # ignore tiny turns; cache effects are noise there


def _safe_mtime(p):
    try:
        return os.path.getmtime(p)
    except OSError:
        return 0.0


def collect(max_files: int):
    rows = []
    files = sorted(
        glob.glob(os.path.expanduser("~/.claude/projects/*/*.jsonl")),
        key=_safe_mtime,        # files can be deleted between glob and sort
        reverse=True,
    )[:max_files]
    for path in files:
        prev_ts = None
        try:
            with open(path) as fh:
                head = fh.read(4096)
                # Exclude cache-warmer fork transcripts: once the warmer runs,
                # they (and re-armed live sessions) would inflate the apparent
                # TTL. Measure with the warmer DISABLED for a true reading.
                if "[cache-warmer keepalive]" in head:
                    continue
                fh.seek(0)
                for line in fh:
                    try:
                        rec = json.loads(line)
                    except Exception:
                        continue
                    if rec.get("type") != "assistant":
                        continue
                    usage = (rec.get("message") or {}).get("usage") or {}
                    cr = usage.get("cache_read_input_tokens", 0)
                    cc = usage.get("cache_creation_input_tokens", 0)
                    it = usage.get("input_tokens", 0)
                    ts = rec.get("timestamp")
                    if not ts:
                        continue
                    t = datetime.datetime.fromisoformat(ts.replace("Z", "+00:00"))
                    total = cr + cc + it
                    if prev_ts is not None and total > MIN_PREFIX_TOKENS:
                        gap_min = (t - prev_ts).total_seconds() / 60
                        if gap_min > 0.5:
                            rows.append((gap_min, cr / total))
                    prev_ts = t
        except OSError:
            continue
    return rows, len(files)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--files", type=int, default=300, help="number of recent session files to scan")
    args = ap.parse_args()

    rows, nfiles = collect(args.files)
    print(f"samples: {len(rows)} turns with >{MIN_PREFIX_TOKENS // 1000}k-token prefixes "
          f"(from {nfiles} recent session files)\n")
    print(f"{'gap since prev turn':<22}{'n':>5}{'median hit':>13}{'mean':>9}{'hits>50%':>11}")
    for lo, hi in BUCKETS:
        vals = [h for g, h in rows if lo <= g < hi]
        label = f"{lo:g}-{hi:g} min" if hi != float("inf") else f"{lo:g}+ min"
        if not vals:
            print(f"{label:<22}{0:>5}")
            continue
        frac = sum(1 for v in vals if v > 0.5) / len(vals)
        print(f"{label:<22}{len(vals):>5}{statistics.median(vals):>12.1%}"
              f"{statistics.mean(vals):>9.1%}{frac:>10.0%}")
    print("\nThe gap bucket where median hit collapses to ~0% is your cache-expiry cliff.")


if __name__ == "__main__":
    main()
