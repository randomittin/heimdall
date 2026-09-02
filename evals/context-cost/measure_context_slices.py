#!/usr/bin/env python3
"""Measure context-slice composition of a Claude Code session transcript (JSONL).

Streams the transcript line-by-line (O(1) memory regardless of file size) and
reports:
  - token totals (input/cache_read/cache_creation/output), deduped by
    message.id per the method documented in
    docs/analysis/token-spend-forensics.md ("every request emits multiple
    JSONL lines -- one per content block -- and every line repeats the same
    message.usage object; summing per-line inflates every figure by ~2.3x").
  - tool_result / text / thinking / tool_use block counts and total
    character length, cross-checkable against independently-measured
    session totals when available.

Does NOT attempt to recover the system-prompt / tool-schema / CLAUDE.md
block size: Claude Code transcripts do not re-serialize that block on every
line, so this script reports it as not-measurable-from-this-artifact rather
than guessing. Use docs/analysis/compaction-arithmetic-findings.md's
~55,247-token standing-overhead measurement as the best available same-repo
proxy instead.

Usage:
    python3 measure_context_slices.py TRANSCRIPT.jsonl [TRANSCRIPT2.jsonl ...]
    python3 measure_context_slices.py --max-lines 50000 TRANSCRIPT.jsonl
    python3 measure_context_slices.py --json TRANSCRIPT.jsonl
"""
import argparse
import json
from collections import Counter


def iter_lines(path, max_lines):
    with open(path, "r", encoding="utf-8", errors="replace") as fh:
        for i, line in enumerate(fh):
            if max_lines is not None and i >= max_lines:
                return
            line = line.strip()
            if not line:
                continue
            yield line


def _tool_result_text(block):
    text_val = block.get("text")
    if text_val is not None:
        return text_val
    cv = block.get("content")
    if isinstance(cv, str):
        return cv
    if isinstance(cv, list):
        return "".join(
            c.get("text", "") for c in cv
            if isinstance(c, dict) and c.get("type") == "text"
        )
    return None


def measure(paths, max_lines=None):
    seen_message_ids = set()
    usage_totals = Counter()
    block_type_counts = Counter()
    block_type_chars = Counter()
    malformed = 0
    lines_seen = 0

    for path in paths:
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
            if isinstance(usage, dict) and msg_id is not None:
                if msg_id not in seen_message_ids:
                    seen_message_ids.add(msg_id)
                    usage_totals["input_tokens"] += usage.get("input_tokens", 0) or 0
                    usage_totals["cache_read_input_tokens"] += usage.get("cache_read_input_tokens", 0) or 0
                    usage_totals["cache_creation_input_tokens"] += usage.get("cache_creation_input_tokens", 0) or 0
                    usage_totals["output_tokens"] += usage.get("output_tokens", 0) or 0

            content = message.get("content")
            if isinstance(content, list):
                for block in content:
                    if not isinstance(block, dict):
                        continue
                    btype = block.get("type", "unknown")
                    block_type_counts[btype] += 1
                    if btype == "tool_result":
                        text_val = _tool_result_text(block)
                    elif btype == "thinking":
                        # Claude API thinking blocks carry content under
                        # "thinking", not "text" -- {"type":"thinking",
                        # "thinking":"...","signature":"..."}.
                        text_val = block.get("thinking")
                    else:
                        text_val = block.get("text")
                    if isinstance(text_val, str):
                        block_type_chars[btype] += len(text_val)

    return {
        "lines_seen": lines_seen,
        "malformed_lines": malformed,
        "unique_messages": len(seen_message_ids),
        "usage_totals": dict(usage_totals),
        "block_type_counts": dict(block_type_counts),
        "block_type_chars": dict(block_type_chars),
    }


def format_report(stats):
    lines = []
    lines.append("=== Context-slice measurement ===")
    lines.append(
        f"lines_seen={stats['lines_seen']} malformed={stats['malformed_lines']} "
        f"unique_messages={stats['unique_messages']}"
    )
    u = stats["usage_totals"]
    total = sum(u.values())
    lines.append("--- token totals (deduped by message.id) ---")
    for k in ("input_tokens", "cache_read_input_tokens", "cache_creation_input_tokens", "output_tokens"):
        v = u.get(k, 0)
        pct = (100.0 * v / total) if total else 0.0
        lines.append(f"{k:32s} {v:>15,d}  ({pct:6.3f}%)")
    lines.append(f"{'total':32s} {total:>15,d}")
    lines.append("--- content block chars (tool_result cross-checks external measurement) ---")
    for btype in sorted(stats["block_type_counts"]):
        cnt = stats["block_type_counts"][btype]
        chars = stats["block_type_chars"].get(btype, 0)
        lines.append(f"{btype:16s} blocks={cnt:>8,d} chars={chars:>12,d}")
    lines.append("--- NOT measurable from this artifact ---")
    lines.append(
        "system_prompt/tool_schema/CLAUDE.md block size: not re-serialized per "
        "line in Claude Code transcripts; use "
        "docs/analysis/compaction-arithmetic-findings.md's ~55,247-token "
        "standing-overhead figure as the best available same-repo proxy "
        "instead of guessing here."
    )
    return "\n".join(lines)


def main():
    ap = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    ap.add_argument("transcripts", nargs="+", help="one or more Claude Code .jsonl transcript files")
    ap.add_argument(
        "--max-lines", type=int, default=None,
        help="stop after N lines per file (safety bound for a first pass on a large/unknown file)",
    )
    ap.add_argument("--json", action="store_true", help="emit machine-readable JSON instead of the text report")
    args = ap.parse_args()

    stats = measure(args.transcripts, max_lines=args.max_lines)
    if args.json:
        print(json.dumps(stats, indent=2, sort_keys=True))
    else:
        print(format_report(stats))


if __name__ == "__main__":
    main()
