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

This is a heuristic: by default it pools all models/providers/versions. The TTL
is per-context, so for a sharper reading filter to one model (--model) and/or
one project (--project), or use --by-model to split the table per model.

Usage:
  python3 measure-ttl.py                     # 300 most recent sessions, pooled
  python3 measure-ttl.py --since 7d          # only turns in the last 7 days
  python3 measure-ttl.py --since 2026-06-01  # only turns on/after a date
  python3 measure-ttl.py --model opus        # only turns whose model matches
  python3 measure-ttl.py --project sourcecash  # only sessions under matching cwd
  python3 measure-ttl.py --by-model          # one table per model (per-context)
"""

import argparse
import datetime
import glob
import json
import os
import re
import statistics

BUCKETS = [
    (0.5, 4), (4, 10), (10, 30), (30, 40), (40, 50), (50, 55),
    (55, 60), (60, 65), (65, 70), (70, 80), (80, 120), (120, float("inf")),
]
MIN_PREFIX_TOKENS = 20_000  # ignore tiny turns; cache effects are noise there
SPARSE_BUCKET = 5           # warn when a non-empty bucket has fewer than this
SPARSE_TOTAL = 30           # warn when a whole population has fewer than this
FORK_ARCHIVE_DIR = os.path.expanduser("~/.cache/cache-warmer/forks")


def _safe_mtime(p):
    try:
        return os.path.getmtime(p)
    except OSError:
        return 0.0


def parse_since(s):
    """Accept an ISO date/datetime or a relative span like '7d', '24h', '90m'.

    Returns a timezone-aware UTC datetime cutoff, or None on empty input.
    """
    if not s:
        return None
    m = re.fullmatch(r"(\d+)\s*([dhm])", s.strip(), re.IGNORECASE)
    if m:
        n, unit = int(m.group(1)), m.group(2).lower()
        delta = {"d": datetime.timedelta(days=n),
                 "h": datetime.timedelta(hours=n),
                 "m": datetime.timedelta(minutes=n)}[unit]
        return datetime.datetime.now(datetime.timezone.utc) - delta
    try:
        dt = datetime.datetime.fromisoformat(s.replace("Z", "+00:00"))
    except ValueError:
        raise SystemExit(f"--since: not an ISO date/datetime or N[d|h|m]: {s!r}")
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=datetime.timezone.utc)
    return dt


def collect(max_files, since=None, model_filter=None, project_filter=None):
    """Return (rows, n_files_scanned). rows = list of (gap_min, hit_ratio, model)."""
    rows = []
    files = sorted(
        glob.glob(os.path.expanduser("~/.claude/projects/*/*.jsonl")),
        key=_safe_mtime,        # files can be deleted between glob and sort
        reverse=True,
    )[:max_files]
    scanned = 0
    for path in files:
        # Archived cache-warmer fork transcripts live outside the projects tree,
        # but guard anyway: never count them (they'd inflate the apparent TTL).
        if os.path.realpath(path).startswith(os.path.realpath(FORK_ARCHIVE_DIR) + os.sep):
            continue
        # --project filters on the mangled project dir name (which encodes cwd).
        if project_filter and project_filter not in os.path.dirname(path):
            continue
        prev_ts = None
        try:
            with open(path) as fh:
                head = fh.read(4096)
                # Exclude cache-warmer fork transcripts: once the warmer runs,
                # they would inflate the apparent TTL. (Re-armed LIVE sessions
                # do NOT carry the marker — only the disposable forks do.)
                # Measure with the warmer DISABLED for the truest reading.
                if "[cache-warmer keepalive]" in head:
                    continue
                fh.seek(0)
                scanned += 1
                for line in fh:
                    try:
                        rec = json.loads(line)
                    except Exception:
                        continue
                    if rec.get("type") != "assistant":
                        continue
                    msg = rec.get("message") or {}
                    model = msg.get("model") or "unknown"
                    # Skip synthetic assistant turns (no real cache request).
                    if model == "<synthetic>":
                        prev_ts = None
                        continue
                    usage = msg.get("usage") or {}
                    cr = usage.get("cache_read_input_tokens", 0) or 0
                    cc = usage.get("cache_creation_input_tokens", 0) or 0
                    it = usage.get("input_tokens", 0) or 0
                    ts = rec.get("timestamp")
                    if not ts:
                        continue
                    try:
                        t = datetime.datetime.fromisoformat(ts.replace("Z", "+00:00"))
                    except ValueError:
                        continue
                    total = cr + cc + it
                    if (prev_ts is not None and total > MIN_PREFIX_TOKENS
                            and (since is None or t >= since)
                            and (not model_filter or model_filter in model)):
                        gap_min = (t - prev_ts).total_seconds() / 60
                        if gap_min > 0.5:
                            rows.append((gap_min, cr / total, model))
                    prev_ts = t
        except OSError:
            continue
    return rows, scanned


def print_table(rows, label=None):
    if label:
        print(f"\n=== {label} ===")
    if not rows:
        print("  (no samples)")
        return
    print(f"{'gap since prev turn':<22}{'n':>5}{'median hit':>13}{'mean':>9}{'hits>50%':>11}")
    sparse = []
    for lo, hi in BUCKETS:
        vals = [h for g, h, _m in rows if lo <= g < hi]
        blabel = f"{lo:g}-{hi:g} min" if hi != float("inf") else f"{lo:g}+ min"
        if not vals:
            print(f"{blabel:<22}{0:>5}")
            continue
        frac = sum(1 for v in vals if v > 0.5) / len(vals)
        print(f"{blabel:<22}{len(vals):>5}{statistics.median(vals):>12.1%}"
              f"{statistics.mean(vals):>9.1%}{frac:>10.0%}")
        if len(vals) < SPARSE_BUCKET:
            sparse.append(blabel)
    if sparse:
        print(f"  ! sparse buckets (n<{SPARSE_BUCKET}, treat as noise): {', '.join(sparse)}")
    if len(rows) < SPARSE_TOTAL:
        print(f"  ! only {len(rows)} samples total (<{SPARSE_TOTAL}); widen --files / --since "
              "for a reliable cliff.")


def main():
    ap = argparse.ArgumentParser(
        formatter_class=argparse.RawDescriptionHelpFormatter, description=__doc__)
    ap.add_argument("--files", type=int, default=300,
                    help="number of recent session files to scan (default 300)")
    ap.add_argument("--since", default=None,
                    help="only count turns on/after this time: ISO date/datetime or N[d|h|m]")
    ap.add_argument("--model", default=None,
                    help="only count turns whose model contains this substring (e.g. opus)")
    ap.add_argument("--project", default=None,
                    help="only scan sessions whose project dir contains this substring")
    ap.add_argument("--by-model", action="store_true",
                    help="print one table per model (per-context TTL) instead of pooled")
    args = ap.parse_args()

    since = parse_since(args.since)
    rows, nfiles = collect(args.files, since=since,
                           model_filter=args.model, project_filter=args.project)

    filt = []
    if args.since:
        filt.append(f"since={args.since}")
    if args.model:
        filt.append(f"model~{args.model}")
    if args.project:
        filt.append(f"project~{args.project}")
    filt_str = f" [{', '.join(filt)}]" if filt else ""
    print(f"samples: {len(rows)} turns with >{MIN_PREFIX_TOKENS // 1000}k-token prefixes "
          f"(from {nfiles} scanned session files){filt_str}")

    if args.by_model:
        models = sorted({m for _g, _h, m in rows})
        if not models:
            print("\n(no samples)")
        for m in models:
            mrows = [(g, h, mm) for g, h, mm in rows if mm == m]
            print_table(mrows, label=f"{m}  (n={len(mrows)})")
    else:
        print_table(rows)

    print("\nThe gap bucket where median hit collapses to ~0% is your cache-expiry cliff.")


if __name__ == "__main__":
    main()
