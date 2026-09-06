#!/usr/bin/env python3
"""Classify cache CREATE-vs-READ transitions across Claude Code transcripts.

Companion to measure_context_slices.py (same streaming / O(1)-memory /
message.id-dedup pattern), built to answer one question honestly:
what actually triggers a cache CREATE, and how much of it is avoidable?

For every unique request (deduped by message.id, in file order) this script
classifies the request's usage block as:
  - CREATE_ONLY : cache_creation_input_tokens > 0, cache_read_input_tokens == 0
  - READ_ONLY   : cache_read_input_tokens > 0, cache_creation_input_tokens == 0
  - MIXED       : both > 0 -- the expected steady-state shape (read the prior
                  cached prefix, create a new entry for what's new since).
  - NEITHER     : both 0

It then buckets CREATE-bearing requests (CREATE_ONLY or MIXED) by whether
they are plausibly explained by a 5-minute TTL expiry:
  - first_in_thread   : position 1 in the file -- no prior cache could exist.
                         Always unavoidable, never a bug.
  - ttl_expiry        : gap since the previous unique request >= --ttl-seconds
                         (default 300s = the 5-minute ephemeral TTL). The
                         entry plausibly aged out on its own.
  - unexplained       : NOT first, gap < ttl-seconds, and CREATE_ONLY (no
                         accompanying read at all). This is the anomalous
                         bucket: something invalidated the *entire* prior
                         cache well within its TTL window -- a prefix
                         rewrite, a tool-schema/model change, or (per
                         shared/prompt-caching.md's "healthy-loop signature")
                         a bug, not routine incremental growth.
  - incremental       : NOT first, gap < ttl-seconds, but MIXED (read
                         succeeded on the prior prefix; the create is just
                         the normal cost of new content appended this turn).
                         This is unavoidable by design, not churn.

Usage:
    python3 measure_cache_transitions.py TRANSCRIPT.jsonl [MORE.jsonl ...]
    python3 measure_cache_transitions.py --ttl-seconds 300 --per-file *.jsonl
    python3 measure_cache_transitions.py --json TRANSCRIPT.jsonl
"""
import argparse
import json
import os
from collections import Counter, defaultdict
from datetime import datetime, timezone


def iter_lines(path, max_lines):
    with open(path, "r", encoding="utf-8", errors="replace") as fh:
        for i, line in enumerate(fh):
            if max_lines is not None and i >= max_lines:
                return
            line = line.strip()
            if not line:
                continue
            yield line


def parse_ts(ts_raw):
    try:
        return datetime.strptime(ts_raw, "%Y-%m-%dT%H:%M:%S.%fZ").replace(tzinfo=timezone.utc)
    except (ValueError, TypeError):
        return None


def classify(usage):
    c = usage.get("cache_creation_input_tokens", 0) or 0
    r = usage.get("cache_read_input_tokens", 0) or 0
    if c > 0 and r > 0:
        return "MIXED"
    if c > 0:
        return "CREATE_ONLY"
    if r > 0:
        return "READ_ONLY"
    return "NEITHER"


def collect_requests(path, max_lines=None):
    """One row per unique message.id, in file order, with gap-since-previous."""
    seen_ids = set()
    rows = []
    malformed = 0
    lines_seen = 0
    prev_ts = None
    position = 0

    for raw in iter_lines(path, max_lines):
        lines_seen += 1
        try:
            rec = json.loads(raw)
        except (json.JSONDecodeError, ValueError):
            malformed += 1
            continue
        message = rec.get("message") if isinstance(rec, dict) else None
        if not isinstance(message, dict):
            continue
        msg_id = message.get("id")
        usage = message.get("usage")
        if not (isinstance(usage, dict) and msg_id is not None):
            continue
        if msg_id in seen_ids:
            continue
        seen_ids.add(msg_id)
        position += 1

        ts_raw = rec.get("timestamp")
        ts = parse_ts(ts_raw) if ts_raw else None
        gap = (ts - prev_ts).total_seconds() if (ts is not None and prev_ts is not None) else None
        if ts is not None:
            prev_ts = ts

        rows.append({
            "position": position,
            "timestamp": ts_raw,
            "gap_seconds": gap,
            "class": classify(usage),
            "input_tokens": usage.get("input_tokens", 0) or 0,
            "cache_read_input_tokens": usage.get("cache_read_input_tokens", 0) or 0,
            "cache_creation_input_tokens": usage.get("cache_creation_input_tokens", 0) or 0,
            "output_tokens": usage.get("output_tokens", 0) or 0,
        })

    return rows, lines_seen, malformed


def bucket_label(row, ttl_seconds):
    """Classify a single CREATE-bearing row into its explanatory bucket.
    Caller must already have checked cache_creation_input_tokens > 0."""
    if row["position"] == 1:
        return "first_in_thread"
    if row["gap_seconds"] is None:
        return "unknown_gap"  # missing/unparseable timestamp -- never silently folded into a real bucket
    if row["gap_seconds"] >= ttl_seconds:
        return "ttl_expiry"
    if row["class"] == "CREATE_ONLY":
        return "unexplained"
    return "incremental"  # MIXED, gap < ttl


def bucket_creates(rows, ttl_seconds):
    """Bucket every CREATE-bearing row into exactly one explanatory bucket."""
    buckets = Counter()
    bucket_tokens = Counter()
    for row in rows:
        if row["cache_creation_input_tokens"] <= 0:
            continue
        b = bucket_label(row, ttl_seconds)
        buckets[b] += 1
        bucket_tokens[b] += row["cache_creation_input_tokens"]
    return buckets, bucket_tokens


def find_unexplained(path, ttl_seconds, max_lines=None):
    """Full row detail for the 'unexplained' bucket only (small by construction)."""
    rows, _, _ = collect_requests(path, max_lines=max_lines)
    return [
        r for r in rows
        if r["cache_creation_input_tokens"] > 0 and bucket_label(r, ttl_seconds) == "unexplained"
    ]


def measure(paths, max_lines=None, ttl_seconds=300):
    per_file = {}
    all_rows = []
    total_malformed = 0
    total_lines = 0

    for path in paths:
        rows, lines_seen, malformed = collect_requests(path, max_lines=max_lines)
        total_lines += lines_seen
        total_malformed += malformed
        class_counts = Counter(r["class"] for r in rows)
        class_tokens = defaultdict(lambda: Counter())
        for r in rows:
            class_tokens[r["class"]]["input_tokens"] += r["input_tokens"]
            class_tokens[r["class"]]["cache_read_input_tokens"] += r["cache_read_input_tokens"]
            class_tokens[r["class"]]["cache_creation_input_tokens"] += r["cache_creation_input_tokens"]
            class_tokens[r["class"]]["output_tokens"] += r["output_tokens"]
        create_buckets, create_bucket_tokens = bucket_creates(rows, ttl_seconds)
        per_file[path] = {
            "requests": len(rows),
            "class_counts": dict(class_counts),
            "class_tokens": {k: dict(v) for k, v in class_tokens.items()},
            "create_buckets": dict(create_buckets),
            "create_bucket_tokens": dict(create_bucket_tokens),
        }
        all_rows.extend(rows)

    combined_class_counts = Counter()
    combined_class_tokens = defaultdict(lambda: Counter())
    for r in all_rows:
        combined_class_counts[r["class"]] += 1
        combined_class_tokens[r["class"]]["input_tokens"] += r["input_tokens"]
        combined_class_tokens[r["class"]]["cache_read_input_tokens"] += r["cache_read_input_tokens"]
        combined_class_tokens[r["class"]]["cache_creation_input_tokens"] += r["cache_creation_input_tokens"]
        combined_class_tokens[r["class"]]["output_tokens"] += r["output_tokens"]
    combined_buckets, combined_bucket_tokens = bucket_creates(all_rows, ttl_seconds)

    return {
        "files_seen": len(paths),
        "lines_seen": total_lines,
        "malformed_lines": total_malformed,
        "total_requests": len(all_rows),
        "ttl_seconds": ttl_seconds,
        "combined": {
            "class_counts": dict(combined_class_counts),
            "class_tokens": {k: dict(v) for k, v in combined_class_tokens.items()},
            "create_buckets": dict(combined_buckets),
            "create_bucket_tokens": dict(combined_bucket_tokens),
        },
        "per_file": per_file,
    }


def format_report(stats, per_file=False):
    lines = []
    lines.append("=== Cache CREATE/READ transition measurement ===")
    lines.append(
        f"files={stats['files_seen']} lines_seen={stats['lines_seen']} "
        f"malformed={stats['malformed_lines']} unique_requests={stats['total_requests']} "
        f"ttl_seconds={stats['ttl_seconds']}"
    )

    c = stats["combined"]
    lines.append("--- request class counts (combined) ---")
    for cls in ("CREATE_ONLY", "READ_ONLY", "MIXED", "NEITHER"):
        n = c["class_counts"].get(cls, 0)
        pct = (100.0 * n / stats["total_requests"]) if stats["total_requests"] else 0.0
        tok = c["class_tokens"].get(cls, {})
        lines.append(
            f"{cls:12s} n={n:>7,d} ({pct:5.1f}%)  "
            f"cache_read={tok.get('cache_read_input_tokens', 0):>14,d}  "
            f"cache_creation={tok.get('cache_creation_input_tokens', 0):>14,d}"
        )

    lines.append("--- CREATE-bearing requests, bucketed by cause (combined) ---")
    total_create_events = sum(c["create_buckets"].values())
    total_create_tokens = sum(c["create_bucket_tokens"].values())
    for b in ("first_in_thread", "ttl_expiry", "incremental", "unexplained", "unknown_gap"):
        n = c["create_buckets"].get(b, 0)
        tok = c["create_bucket_tokens"].get(b, 0)
        pct_n = (100.0 * n / total_create_events) if total_create_events else 0.0
        pct_tok = (100.0 * tok / total_create_tokens) if total_create_tokens else 0.0
        lines.append(
            f"{b:16s} events={n:>7,d} ({pct_n:5.1f}%)  "
            f"create_tokens={tok:>14,d} ({pct_tok:5.1f}%)"
        )
    lines.append(
        "  'unexplained' = NOT first request, gap < ttl_seconds, no accompanying "
        "read -- a full-prefix invalidation the 5-min TTL cannot explain. This is "
        "the bucket to investigate for a real, addressable bug."
    )

    if per_file:
        lines.append("--- per-file breakdown ---")
        for path, pf in stats["per_file"].items():
            cc = pf["class_tokens"]
            read_tok = sum(v.get("cache_read_input_tokens", 0) for v in cc.values())
            create_tok = sum(v.get("cache_creation_input_tokens", 0) for v in cc.values())
            ratio = (create_tok / read_tok) if read_tok else float("inf") if create_tok else 0.0
            first_tok = pf["create_bucket_tokens"].get("first_in_thread", 0)
            first_share = (100.0 * first_tok / create_tok) if create_tok else 0.0
            lines.append(
                f"{os.path.basename(path):40s} requests={pf['requests']:>5,d}  "
                f"read={read_tok:>12,d}  create={create_tok:>12,d}  "
                f"create:read={ratio:6.3f}  first_in_thread_share_of_create={first_share:5.1f}%"
            )

    return "\n".join(lines)


def main():
    ap = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    ap.add_argument("transcripts", nargs="+", help="one or more Claude Code .jsonl transcript files")
    ap.add_argument("--max-lines", type=int, default=None, help="stop after N lines per file")
    ap.add_argument("--ttl-seconds", type=int, default=300, help="cache TTL to test gaps against (default 300 = 5min ephemeral)")
    ap.add_argument("--per-file", action="store_true", help="include a per-file breakdown (for comparing e.g. subagent transcripts to the main thread)")
    ap.add_argument("--list-unexplained", action="store_true", help="print position/timestamp/gap/tokens for every 'unexplained' CREATE event (no aggregate report)")
    ap.add_argument("--json", action="store_true", help="emit machine-readable JSON instead of the text report")
    args = ap.parse_args()

    if args.list_unexplained:
        rows = []
        for path in args.transcripts:
            for r in find_unexplained(path, args.ttl_seconds, max_lines=args.max_lines):
                r = dict(r, path=path)
                rows.append(r)
        if args.json:
            print(json.dumps(rows, indent=2, sort_keys=True))
        else:
            print(f"=== {len(rows)} unexplained CREATE event(s) (gap < {args.ttl_seconds}s, not first-in-thread, no accompanying read) ===")
            for r in rows:
                print(
                    f"{os.path.basename(r['path']):40s} pos={r['position']:>5,d} "
                    f"ts={r['timestamp']} gap={r['gap_seconds']:.1f}s "
                    f"create_tokens={r['cache_creation_input_tokens']:>10,d}"
                )
        return

    stats = measure(args.transcripts, max_lines=args.max_lines, ttl_seconds=args.ttl_seconds)
    if args.json:
        print(json.dumps(stats, indent=2, sort_keys=True))
    else:
        print(format_report(stats, per_file=args.per_file))


if __name__ == "__main__":
    main()
