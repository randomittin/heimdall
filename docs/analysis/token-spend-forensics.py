#!/usr/bin/env python3
"""Reproduce the figures in token-spend-forensics.md from Claude Code JSONL transcripts.

Usage:
    python3 docs/analysis/token-spend-forensics.py [PROJECT_DIR ...]

With no arguments it scans the heimdall project dir plus every worktree-agent dir under
~/.claude/projects/. Prints summary numbers only — it never emits transcript content, so
it is safe to run from inside an agent session.

CORRECTNESS NOTE: one API request is written as MULTIPLE jsonl lines (one per content
block), and every one of those lines repeats the SAME message.usage object. Summing usage
per line overstates every figure by ~2.3x. Usage is therefore counted once per message.id;
records whose id is null cannot be collapsed safely and are treated as distinct.
"""
import collections
import glob
import json
import os
import statistics
import sys

# Anthropic first-party list prices, USD per million tokens.
# Opus 5 / 4.8 / 4.7 all share this tier, so the corpus blend is exact.
PRICE_INPUT = 5.00
PRICE_OUTPUT = 25.00
PRICE_CACHE_READ = PRICE_INPUT * 0.10   # 0.50
PRICE_CACHE_WRITE_5M = PRICE_INPUT * 1.25   # 6.25
PRICE_CACHE_WRITE_1H = PRICE_INPUT * 2.00   # 10.00

HOME = os.path.expanduser('~')
DEFAULT_ROOTS = (
    [os.path.join(HOME, '.claude/projects/-Users-rj-Downloads-heimdall')]
    + sorted(glob.glob(os.path.join(
        HOME, '.claude/projects/-Users-rj-Downloads-heimdall--claude-worktrees-agent-*')))
)


def iter_requests(path):
    """Yield one (usage, timestamp) pair per distinct API request in a transcript."""
    seen = set()
    with open(path, errors='replace') as handle:
        for line in handle:
            try:
                record = json.loads(line)
            except ValueError:
                continue
            if record.get('type') != 'assistant':
                continue
            message = record.get('message') or {}
            usage = message.get('usage') or {}
            if not usage:
                continue
            message_id = message.get('id')
            if message_id is not None:
                if message_id in seen:
                    continue
                seen.add(message_id)
            yield usage, record.get('timestamp'), message.get('model')


def tally(usage):
    creation = usage.get('cache_creation') or {}
    return {
        'input': usage.get('input_tokens') or 0,
        'output': usage.get('output_tokens') or 0,
        'cache_read': usage.get('cache_read_input_tokens') or 0,
        'cache_create': usage.get('cache_creation_input_tokens') or 0,
        'cache_create_1h': creation.get('ephemeral_1h_input_tokens') or 0,
        'cache_create_5m': creation.get('ephemeral_5m_input_tokens') or 0,
    }


def cost(totals):
    return (
        totals['cache_read'] * PRICE_CACHE_READ
        + totals['cache_create_1h'] * PRICE_CACHE_WRITE_1H
        + totals['cache_create_5m'] * PRICE_CACHE_WRITE_5M
        + totals['input'] * PRICE_INPUT
        + totals['output'] * PRICE_OUTPUT
    ) / 1e6


def scan(roots):
    totals = collections.Counter()
    contexts = []
    per_session = {}
    per_model = collections.Counter()
    for root in roots:
        for path in sorted(glob.glob(os.path.join(root, '*.jsonl'))):
            session = collections.Counter()
            for usage, _timestamp, model in iter_requests(path):
                counts = tally(usage)
                for key, value in counts.items():
                    totals[key] += value
                    session[key] += value
                totals['requests'] += 1
                session['requests'] += 1
                context = counts['input'] + counts['cache_create'] + counts['cache_read']
                contexts.append(context)
                session['peak'] = max(session['peak'], context)
                per_model[model or '?'] += context + counts['output']
            if session['requests']:
                per_session[path] = session
    return totals, contexts, per_session, per_model


def main():
    roots = sys.argv[1:] or DEFAULT_ROOTS
    totals, contexts, per_session, per_model = scan(roots)
    if not per_session:
        print('no transcripts with usage found', file=sys.stderr)
        return 1

    grand = totals['input'] + totals['output'] + totals['cache_read'] + totals['cache_create']
    input_side = totals['input'] + totals['cache_read'] + totals['cache_create']

    print(f'sessions {len(per_session)}  requests {totals["requests"]:,}  '
          f'tokens {grand:,}  cost ${cost(totals):,.2f}')
    print(f'  cache-read {100 * totals["cache_read"] / input_side:.2f}%  '
          f'cache-create {100 * totals["cache_create"] / input_side:.2f}%  '
          f'uncached {100 * totals["input"] / input_side:.4f}%')
    print(f'  mean context/request {input_side / totals["requests"]:,.0f}')

    print('\ncost lines')
    lines = [
        ('cache read', totals['cache_read'] * PRICE_CACHE_READ / 1e6),
        ('cache create 1h', totals['cache_create_1h'] * PRICE_CACHE_WRITE_1H / 1e6),
        ('cache create 5m', totals['cache_create_5m'] * PRICE_CACHE_WRITE_5M / 1e6),
        ('output', totals['output'] * PRICE_OUTPUT / 1e6),
        ('uncached input', totals['input'] * PRICE_INPUT / 1e6),
    ]
    total_cost = cost(totals)
    for label, amount in sorted(lines, key=lambda row: -row[1]):
        print(f'  {label:18s} ${amount:>9,.2f}  {100 * amount / total_cost:5.1f}%')

    print('\ncontext distribution')
    ordered = sorted(contexts)
    for pct in (50, 75, 90, 95, 99):
        print(f'  p{pct} {ordered[int(len(ordered) * pct / 100) - 1]:,}')

    print('\ncounterfactual context caps (cache-read only; cache-create held constant)')
    actual = sum(contexts)
    for cap in (100_000, 150_000, 200_000):
        capped = sum(min(value, cap) for value in contexts)
        saved = (actual - capped) * PRICE_CACHE_READ / 1e6
        print(f'  cap {cap:>7,}: input {capped:>15,} ({100 * capped / actual:4.1f}%)  '
              f'saves ${saved:,.2f}')

    print('\ntop sessions by cost')
    ranked = sorted(per_session.items(), key=lambda kv: -cost(kv[1]))
    for path, session in ranked[:8]:
        print(f'  ${cost(session):>9,.2f}  {session["requests"]:>5,} reqs  '
              f'peak {session["peak"]:>9,}  {os.path.basename(path)[:36]}')

    print('\nspend by model')
    model_total = sum(per_model.values())
    for model, value in per_model.most_common(6):
        print(f'  {model:24s} {value:>15,}  {100 * value / model_total:5.1f}%')

    print('\npreamble (first request per session)')
    opening = []
    for path in per_session:
        for usage, _timestamp, _model in iter_requests(path):
            counts = tally(usage)
            opening.append(counts['input'] + counts['cache_create'] + counts['cache_read'])
            break
    print(f'  median {statistics.median(opening):,.0f}  mean {statistics.mean(opening):,.0f}  '
          f'min {min(opening):,}  max {max(opening):,}')
    return 0


if __name__ == '__main__':
    sys.exit(main())
