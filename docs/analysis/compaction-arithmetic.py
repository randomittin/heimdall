#!/usr/bin/env python3
"""Measure the compaction arithmetic from Claude Code JSONL transcripts.

    compaction frequency = (threshold - post-compact baseline) / per-turn additions

Both terms are read out of the transcript store. Nothing here is estimated unless it
says so.

THE FOUR FIELDS EVERYTHING RESTS ON
-----------------------------------
    ctx(request) = usage.input_tokens
                 + usage.cache_creation_input_tokens
                 + usage.cache_read_input_tokens          # exact prompt size
    compactMetadata.preTokens / .postTokens               # exact, written by the harness

    post-compact BASELINE = ctx of the first request after a compact_boundary
    STANDING overhead     = BASELINE - postTokens
    PER-TURN addition     = ctx(N+1) - ctx(N)

STANDING is the system preamble + tool definitions + the CLAUDE.md stack + skills prose.
None of it appears in the transcript, so it is obtained by subtraction of two exact
numbers rather than by adding up guesses.

WHAT CANNOT BE MEASURED HERE, AND IS REPORTED AS SUCH
-----------------------------------------------------
  * `thinking` block text is empty in every persisted block (only the ~2.3KB signature
    is stored). Thinking tokens are real and occupy context; their bytes do not exist on
    disk. They are counted as BLOCKS and, where a fit is possible, priced per block.
  * Images are base64 in the transcript but priced by dimensions, so they are counted as
    ITEMS, never by byte length.
  * The internal split of the STANDING block (preamble vs tool defs vs CLAUDE.md vs
    skills) is not in the transcript at all. This tool reports the total and refuses to
    apportion it.

SOURCE ATTRIBUTION
------------------
Per-turn token deltas are exact; the split of a delta across its sources is not directly
observable. Bytes per source ARE observable. So per-source token density is MEASURED by
non-negative least squares over every turn in the corpus (tokens ~ bytes per bucket, plus
a per-turn intercept for harness-injected system reminders that never reach disk), and
the fit quality is published alongside. With too few turns to determine the fit, the tool
says so instead of inventing coefficients.

Usage:
    python3 docs/analysis/compaction-arithmetic.py [PROJECT_DIR_OR_FILE ...] [--json]

With no path arguments it reads the heimdall project transcript dir. It opens every file
read-only and writes nothing anywhere.
"""
import collections
import glob
import importlib.util
import json
import os
import statistics
import sys

HOME = os.path.expanduser('~')
HERE = os.path.dirname(os.path.abspath(__file__))
DEFAULT_ROOTS = [os.path.join(HOME, '.claude/projects/-Users-rj-Downloads-heimdall')]

# Named tools get their own column; everything else collapses so the fit stays determined.
NAMED_TOOLS = {'Bash', 'Agent', 'Read', 'Edit', 'Write', 'Grep', 'Glob',
               'SendMessage', 'Skill', 'TaskStop', 'WebFetch', 'WebSearch', 'TodoWrite'}
HOOK_ATTACHMENTS = {'hook_success', 'hook_additional_context',
                    'async_hook_response', 'hook_system_message'}
TASK_NOTIFICATION = '<task-notification>'
# Fit needs this many turns per free parameter before its coefficients mean anything.
ROWS_PER_COLUMN = 10


def load_forensics():
    """Import the sibling forensics parser. Two parsers that can disagree is the failure
    class this repo keeps hitting, so the request count is cross-checked against it."""
    path = os.path.join(HERE, 'token-spend-forensics.py')
    spec = importlib.util.spec_from_file_location('token_spend_forensics', path)
    if spec is None or spec.loader is None:
        raise SystemExit(f'cannot load the shared transcript parser at {path}')
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def blen(obj):
    """Bytes of model-facing payload. Strings measure directly; structures measure as the
    JSON the harness would serialise."""
    if obj is None:
        return 0
    if isinstance(obj, str):
        return len(obj)
    return len(json.dumps(obj, ensure_ascii=False))


def payload(record, toolnames):
    """Bucketed model-facing content of one record: [(bucket, bytes_or_count), ...].

    Buckets ending in '#' are ITEM COUNTS, not bytes — used where byte length does not
    predict tokens (images, thinking blocks whose text is not persisted)."""
    out = []
    kind = record.get('type')
    if kind == 'assistant':
        for block in ((record.get('message') or {}).get('content') or []):
            if not isinstance(block, dict):
                continue
            btype = block.get('type')
            if btype == 'text':
                out.append(('model:text', blen(block.get('text'))))
            elif btype == 'thinking':
                # .thinking is '' in every persisted block; only .signature survives.
                out.append(('model:thinking#', 1))
            elif btype == 'tool_use':
                toolnames[block.get('id')] = block.get('name')
                out.append(('model:tool_use', blen(block.get('input'))))
    elif kind == 'user':
        content = (record.get('message') or {}).get('content')
        text_bucket = 'compact_summary' if record.get('isCompactSummary') else 'user:prompt'
        if isinstance(content, str):
            # A background agent's handback reaches the orchestrator as a plain user
            # string, not as a tool result. Counting only tool:Agent understates by
            # exactly this bucket, which is the term B3 proposes to cap.
            if not record.get('isCompactSummary') and content.lstrip().startswith(TASK_NOTIFICATION):
                out.append(('user:task_notification', blen(content)))
            else:
                out.append((text_bucket, blen(content)))
        elif isinstance(content, list):
            for block in content:
                if not isinstance(block, dict):
                    continue
                btype = block.get('type')
                if btype == 'tool_result':
                    name = toolnames.get(block.get('tool_use_id'))
                    if name in NAMED_TOOLS:
                        bucket = 'tool:' + name
                    elif str(name).startswith('mcp__'):
                        bucket = 'tool:mcp'
                    else:
                        bucket = 'tool:other'
                    out.append((bucket, blen(block.get('content'))))
                elif btype == 'text':
                    out.append((text_bucket, blen(block.get('text'))))
                elif btype == 'image':
                    out.append(('user:image#', 1))
    elif kind == 'attachment':
        attachment = record.get('attachment') or {}
        atype = attachment.get('type')
        if atype in HOOK_ATTACHMENTS:
            hook = attachment.get('hookName') or attachment.get('hookEvent') or 'unnamed'
            out.append(('hook:' + str(hook), blen(attachment.get('content'))))
        else:
            out.append(('attach:' + str(atype), blen(attachment)))
    return [(bucket, value) for bucket, value in out if value]


def read_records(path):
    """Ordered records of one transcript. Unparseable lines are kept as placeholders so
    line indices stay meaningful, and are counted."""
    records = []
    bad = 0
    with open(path, errors='replace') as handle:
        for line in handle:
            line = line.strip()
            if not line:
                continue
            try:
                records.append(json.loads(line))
            except ValueError:
                records.append({'type': '_unparseable'})
                bad += 1
    return records, bad


def requests_of(records):
    """One entry per distinct API request, in file order.

    Deduped by message.id: one request is written as multiple lines (one per content
    block) and every line repeats the same usage object. Summing per line overstates by
    ~2.3x — the trap documented in token-spend-forensics.md."""
    seen = set()
    out = []
    for index, record in enumerate(records):
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
        ctx = ((usage.get('input_tokens') or 0)
               + (usage.get('cache_creation_input_tokens') or 0)
               + (usage.get('cache_read_input_tokens') or 0))
        out.append({
            'line': index,
            'ctx': ctx,
            'cache_create': usage.get('cache_creation_input_tokens') or 0,
            'cache_read': usage.get('cache_read_input_tokens') or 0,
            'output': usage.get('output_tokens') or 0,
            'model': message.get('model'),
            'timestamp': record.get('timestamp'),
        })
    return out


def analyse(path):
    records, bad_lines = read_records(path)
    requests = requests_of(records)
    if not requests:
        return None

    boundaries = [i for i, r in enumerate(records)
                  if r.get('subtype') == 'compact_boundary' and r.get('compactMetadata')]

    toolnames = {}
    # Resolve tool_use ids across the whole file first, so a tool_result whose tool_use
    # was written earlier in an unscanned region still resolves to its tool name.
    for record in records:
        if record.get('type') != 'assistant':
            continue
        for block in ((record.get('message') or {}).get('content') or []):
            if isinstance(block, dict) and block.get('type') == 'tool_use':
                toolnames[block.get('id')] = block.get('name')

    def bucket_span(start, stop):
        agg = collections.Counter()
        for j in range(start, stop):
            for bucket, value in payload(records[j], toolnames):
                agg[bucket] += value
        return agg

    # A human turn: a user record carrying prose the operator typed. Tool results, agent
    # handbacks and the compact summary all ride the same record type and are not turns.
    def is_human_prompt(record):
        if record.get('type') != 'user' or record.get('isCompactSummary') or record.get('isMeta'):
            return False
        content = (record.get('message') or {}).get('content')
        return isinstance(content, str) and not content.lstrip().startswith(TASK_NOTIFICATION)

    human_prompt_lines = [i for i, r in enumerate(records) if is_human_prompt(r)]

    # ── compacts ────────────────────────────────────────────────────────────────────
    compacts = []
    previous_baseline = requests[0]['ctx'] if requests[0]['ctx'] else None
    for order, line in enumerate(boundaries, start=1):
        meta = records[line]['compactMetadata']
        before = [r for r in requests if r['line'] < line]
        # The first request after a boundary may be an API-error placeholder carrying an
        # all-zero usage object. That is not a prompt, and mistaking it for the baseline
        # produces a negative STANDING figure.
        after = [r for r in requests if r['line'] > line]
        skipped = 0
        first_after = None
        for candidate in after:
            if candidate['ctx'] > 0:
                first_after = candidate
                break
            skipped += 1
        previous_line = boundaries[order - 2] if order >= 2 else -1
        between = [r for r in requests if previous_line < r['line'] < line]
        baseline = first_after['ctx'] if first_after else None
        pre = meta.get('preTokens')
        entry = {
            'index': order,
            'boundary_line': line,
            'trigger': meta.get('trigger'),
            'pre_tokens': pre,
            'post_tokens': meta.get('postTokens'),
            'cumulative_dropped_tokens': meta.get('cumulativeDroppedTokens'),
            'duration_ms': meta.get('durationMs'),
            'preserved_messages': len((meta.get('preservedMessages') or {}).get('uuids') or []),
            'baseline_tokens': baseline,
            'baseline_model': first_after['model'] if first_after else None,
            'baseline_timestamp': first_after['timestamp'] if first_after else None,
            'zero_context_records_skipped': skipped,
            'standing_tokens': (baseline - meta['postTokens'])
                               if baseline is not None and meta.get('postTokens') is not None
                               else None,
            # How far context climbed from the last baseline before this compact fired.
            'tokens_since_previous_baseline': (pre - previous_baseline)
                                              if pre is not None and previous_baseline else None,
            # What the compact bought: room between the new baseline and the threshold
            # this compact just demonstrated.
            'headroom_tokens': (pre - baseline) if pre is not None and baseline else None,
            'requests_since_previous': len(between),
            'human_prompts_since_previous': sum(1 for i in human_prompt_lines
                                                if previous_line < i < line),
            'last_ctx_before': before[-1]['ctx'] if before else None,
            'injected_bytes': dict(bucket_span(line, first_after['line'])) if first_after else {},
            'injected_records': (first_after['line'] - line) if first_after else 0,
        }
        if baseline:
            previous_baseline = baseline
        compacts.append(entry)

    boundary_lines = {r['boundary_line'] for r in compacts}

    # ── per-turn deltas ─────────────────────────────────────────────────────────────
    # A pair is in-lineage when no compact fell between the two requests and the context
    # actually grew. Context DROPS (harness-side microcompaction, or a rewind) are counted
    # and excluded rather than silently absorbed into a neighbouring turn.
    turns = []
    dropped_pairs = 0
    cold_pairs = 0
    spanning_pairs = 0
    exact = within20 = offby = 0
    for prev, cur in zip(requests, requests[1:]):
        if any(prev['line'] < b <= cur['line'] for b in boundary_lines):
            spanning_pairs += 1
            continue
        if prev['ctx'] == 0 or cur['ctx'] == 0:
            cold_pairs += 1
            continue
        delta = cur['ctx'] - prev['ctx']
        if delta <= 0:
            dropped_pairs += 1
            continue
        if delta == cur['cache_create']:
            exact += 1
        elif abs(delta - cur['cache_create']) <= 20:
            within20 += 1
        else:
            offby += 1
        turns.append({'tokens': delta, 'buckets': bucket_span(prev['line'], cur['line'])})

    deltas = [t['tokens'] for t in turns]
    bucket_bytes = collections.Counter()
    for turn in turns:
        bucket_bytes.update(turn['buckets'])

    thinking_blocks = sum(
        1 for r in records if r.get('type') == 'assistant'
        for b in ((r.get('message') or {}).get('content') or [])
        if isinstance(b, dict) and b.get('type') == 'thinking')
    thinking_sig_bytes = sum(
        len(b.get('signature') or '') for r in records if r.get('type') == 'assistant'
        for b in ((r.get('message') or {}).get('content') or [])
        if isinstance(b, dict) and b.get('type') == 'thinking')
    images = sum(
        1 for r in records if r.get('type') == 'user'
        for b in ((r.get('message') or {}).get('content') or [])
        if isinstance(b, dict) and b.get('type') == 'image')

    session = {
        'path': path,
        'session_id': os.path.basename(path)[:-6],
        'requests': len(requests),
        'human_prompts': len(human_prompt_lines),
        'unparseable_lines': bad_lines,
        'first_request_ctx': requests[0]['ctx'],
        'peak_ctx': max(r['ctx'] for r in requests),
        'first_timestamp': requests[0]['timestamp'],
        'last_timestamp': requests[-1]['timestamp'],
        'compacts': compacts,
        'turns': {
            'count': len(deltas),
            'total_tokens': sum(deltas),
            'median_tokens': int(statistics.median(deltas)) if deltas else 0,
            'mean_tokens': round(statistics.mean(deltas), 1) if deltas else 0,
            'p90_tokens': sorted(deltas)[int(len(deltas) * 0.9) - 1] if deltas else 0,
            'max_tokens': max(deltas) if deltas else 0,
            'excluded_context_drops': dropped_pairs,
            'excluded_cold_cache': cold_pairs,
            'excluded_across_compact': spanning_pairs,
        },
        'delta_vs_cache_create': {'pairs': len(deltas), 'exact': exact,
                                  'within_20': within20, 'off': offby},
        'bucket_bytes': dict(bucket_bytes),
        'unmeasurable': {
            'thinking_blocks': thinking_blocks,
            'thinking_signature_bytes': thinking_sig_bytes,
            'thinking_text_bytes_on_disk': 0,
            'images': images,
        },
    }
    return session, turns


def solve(matrix, vector):
    """Gaussian elimination with partial pivoting. Returns None for a singular system."""
    n = len(vector)
    aug = [list(matrix[i]) + [vector[i]] for i in range(n)]
    for col in range(n):
        pivot = max(range(col, n), key=lambda r: abs(aug[r][col]))
        if abs(aug[pivot][col]) < 1e-12:
            return None
        aug[col], aug[pivot] = aug[pivot], aug[col]
        inv = 1.0 / aug[col][col]
        for row in range(n):
            if row == col:
                continue
            factor = aug[row][col] * inv
            if factor:
                for k in range(col, n + 1):
                    aug[row][k] -= factor * aug[col][k]
    return [aug[i][n] / aug[i][i] for i in range(n)]


def nnls(ata, aty, iterations=500):
    """Lawson-Hanson non-negative least squares on the normal equations.

    Non-negativity is the point: a source cannot contribute a negative number of tokens,
    and an unconstrained fit happily assigns one to soak up collinearity."""
    n = len(aty)
    x = [0.0] * n
    passive = [False] * n
    for _ in range(iterations):
        residual = [aty[i] - sum(ata[i][k] * x[k] for k in range(n)) for i in range(n)]
        best, best_value = -1, 1e-8
        for i in range(n):
            if not passive[i] and residual[i] > best_value:
                best, best_value = i, residual[i]
        if best < 0:
            break
        passive[best] = True
        for _ in range(200):
            idx = [i for i in range(n) if passive[i]]
            sub = solve([[ata[i][j] for j in idx] for i in idx], [aty[i] for i in idx])
            if sub is None:
                passive[best] = False
                break
            s = [0.0] * n
            for pos, i in enumerate(idx):
                s[i] = sub[pos]
            if all(s[i] > 0 for i in idx):
                x = s
                break
            alpha = min(x[i] / (x[i] - s[i]) for i in idx if s[i] <= 0 and x[i] != s[i])
            x = [x[i] + alpha * (s[i] - x[i]) for i in range(n)]
            for i in range(n):
                if passive[i] and x[i] <= 1e-12:
                    passive[i] = False
        else:
            break
    return x


def fit_density(all_turns):
    """MEASURE tokens-per-byte per source across every turn in the corpus.

    Columns are per-source bytes (or item counts for images / thinking blocks) plus a
    constant. The constant absorbs whatever the harness injects per turn that never
    reaches disk — system reminders, tool-result envelopes — and is reported openly
    rather than smeared across the named sources."""
    columns = sorted({b for turn in all_turns for b in turn['buckets']}) + ['per_turn_constant']
    n = len(columns)
    if len(all_turns) < ROWS_PER_COLUMN * n:
        return {'available': False,
                'reason': (f'{len(all_turns)} turns for {n} free parameters; '
                           f'needs >= {ROWS_PER_COLUMN * n} '
                           f'({ROWS_PER_COLUMN} rows per parameter) for the coefficients '
                           f'to be determined'),
                'rows': len(all_turns), 'columns': n}

    ata = [[0.0] * n for _ in range(n)]
    aty = [0.0] * n
    yty = 0.0
    ysum = 0.0
    totals = [0.0] * n
    for turn in all_turns:
        row = [float(turn['buckets'].get(c, 0)) for c in columns[:-1]] + [1.0]
        y = float(turn['tokens'])
        for i in range(n):
            if row[i]:
                aty[i] += row[i] * y
                totals[i] += row[i]
                for j in range(i, n):
                    if row[j]:
                        ata[i][j] += row[i] * row[j]
        yty += y * y
        ysum += y
    for i in range(n):
        for j in range(i):
            ata[i][j] = ata[j][i]

    coef = nnls(ata, aty)
    rows = len(all_turns)
    ss_tot = yty - ysum * ysum / rows
    ax = [sum(ata[i][j] * coef[j] for j in range(n)) for i in range(n)]
    ss_res = yty - 2 * sum(coef[i] * aty[i] for i in range(n)) + sum(coef[i] * ax[i] for i in range(n))
    attributed = {columns[i]: coef[i] * totals[i] for i in range(n)}
    return {
        'available': True,
        'rows': rows,
        'columns': n,
        'r2': round(1 - ss_res / ss_tot, 4) if ss_tot > 0 else None,
        'total_tokens': round(ysum),
        'coefficients': {columns[i]: round(coef[i], 6) for i in range(n)},
        'bytes_per_token': {columns[i]: (round(1 / coef[i], 2) if coef[i] > 1e-9 else None)
                            for i in range(n) if not columns[i].endswith('#')
                            and columns[i] != 'per_turn_constant'},
        'observed_totals': {columns[i]: round(totals[i]) for i in range(n)},
        'attributed_tokens': {k: round(v) for k, v in attributed.items()},
    }


def expand(paths):
    files = []
    for path in paths:
        if os.path.isdir(path):
            files.extend(sorted(glob.glob(os.path.join(path, '*.jsonl'))))
        else:
            files.append(path)
    return files


def build(paths):
    forensics = load_forensics()
    sessions = []
    all_turns = []
    crosscheck_ok = True
    for path in expand(paths):
        result = analyse(path)
        if result is None:
            continue
        session, turns = result
        reference = sum(1 for _ in forensics.iter_requests(path))
        session['crosscheck_forensics_requests'] = reference
        if reference != session['requests']:
            crosscheck_ok = False
        # A session that compacts gets its own fit: the ranking that matters is the one
        # for the content mix that actually filled the window, not a corpus average.
        if session['compacts']:
            session['fit'] = fit_density(turns)
        sessions.append(session)
        all_turns.extend(turns)

    sessions.sort(key=lambda s: (-len(s['compacts']), -s['requests']))
    report = {
        'corpus': {
            'sessions': len(sessions),
            'requests': sum(s['requests'] for s in sessions),
            'compacts': sum(len(s['compacts']) for s in sessions),
            'turns': sum(s['turns']['count'] for s in sessions),
            'crosscheck_vs_token_spend_forensics': {
                'agrees': crosscheck_ok,
                'requests': sum(s['crosscheck_forensics_requests'] for s in sessions),
            },
            'delta_vs_cache_create': {
                'pairs': sum(s['delta_vs_cache_create']['pairs'] for s in sessions),
                'exact': sum(s['delta_vs_cache_create']['exact'] for s in sessions),
                'within_20': sum(s['delta_vs_cache_create']['within_20'] for s in sessions),
                'off': sum(s['delta_vs_cache_create']['off'] for s in sessions),
            },
        },
        'sessions': sessions,
        'fit': fit_density(all_turns) if all_turns else
               {'available': False, 'reason': 'no in-lineage turns found', 'rows': 0},
    }
    return report


def human(report):
    corpus = report['corpus']
    out = []
    add = out.append
    add(f"sessions {corpus['sessions']}  requests {corpus['requests']:,}  "
        f"compacts {corpus['compacts']}  turns {corpus['turns']:,}")
    check = corpus['crosscheck_vs_token_spend_forensics']
    add(f"  cross-check vs token-spend-forensics.py: {check['requests']:,} requests, "
        f"{'AGREE' if check['agrees'] else 'DISAGREE — investigate before trusting anything below'}")
    dvc = corpus['delta_vs_cache_create']
    if dvc['pairs']:
        add(f"  delta-ctx vs cache_creation witness: {dvc['exact']:,}/{dvc['pairs']:,} exact "
            f"({100 * dvc['exact'] / dvc['pairs']:.1f}%), {dvc['within_20']:,} within 20, {dvc['off']:,} off")

    for session in report['sessions']:
        if not session['compacts']:
            continue
        add('')
        add(f"=== {session['session_id']}  {session['requests']:,} requests  "
            f"peak ctx {session['peak_ctx']:,}  {session['first_timestamp']} -> {session['last_timestamp']}")
        add('  compacts:')
        add(f"    {'#':>2} {'trig':<6} {'preTokens':>10} {'postTok':>8} "
            f"{'BASELINE':>9} {'STANDING':>9} {'headroom':>9} {'climb':>9} {'reqs':>5} {'prompts':>7}  when")
        for compact in session['compacts']:
            add(f"    {compact['index']:>2} {str(compact['trigger']):<6} "
                f"{compact['pre_tokens'] or 0:>10,} {compact['post_tokens'] or 0:>8,} "
                f"{compact['baseline_tokens'] or 0:>9,} {compact['standing_tokens'] or 0:>9,} "
                f"{compact['headroom_tokens'] or 0:>9,} "
                f"{compact['tokens_since_previous_baseline'] or 0:>9,} "
                f"{compact['requests_since_previous']:>5,} "
                f"{compact['human_prompts_since_previous']:>7,}  {compact['baseline_timestamp']}")
        # preTokens IS the observed auto-compact threshold. It is not constant across a
        # long session; grouping shows when the window itself changed underneath.
        autos = [c for c in session['compacts'] if c['trigger'] == 'auto' and c['pre_tokens']]
        if autos:
            regimes = collections.defaultdict(list)
            for compact in autos:
                regimes[round(compact['pre_tokens'], -5)].append(compact)
            add('  observed auto-compact threshold (preTokens), grouped:')
            for _, group in sorted(regimes.items()):
                pres = [c['pre_tokens'] for c in group]
                bases = [c['baseline_tokens'] for c in group if c['baseline_tokens']]
                mean_base = sum(bases) / len(bases) if bases else 0
                add(f"    {len(group)} compacts  threshold {min(pres):,}-{max(pres):,}  "
                    f"mean baseline {mean_base:,.0f}  "
                    f"usable headroom {sum(pres) / len(pres) - mean_base:,.0f}  "
                    f"baseline is {100 * mean_base / (sum(pres) / len(pres)):.0f}% of the window")
        add('  re-injected at each boundary (measured bytes):')
        by_source = collections.Counter()
        for compact in session['compacts']:
            by_source.update(compact['injected_bytes'])
        count = len(session['compacts'])
        for source, total in by_source.most_common(10):
            add(f"    {source:<38} {total:>9,} B total  {total // count:>8,} B/compact")
        turns = session['turns']
        add(f"  per-turn additions: n={turns['count']:,}  total {turns['total_tokens']:,}  "
            f"median {turns['median_tokens']:,}  mean {turns['mean_tokens']:,}  "
            f"p90 {turns['p90_tokens']:,}  max {turns['max_tokens']:,}")
        add(f"    excluded: {turns['excluded_across_compact']} across a compact, "
            f"{turns['excluded_context_drops']} context drops, {turns['excluded_cold_cache']} cold-cache")
        unmeasurable = session['unmeasurable']
        add(f"  NOT MEASURABLE from disk: {unmeasurable['thinking_blocks']:,} thinking blocks "
            f"(text 0 B on disk, {unmeasurable['thinking_signature_bytes']:,} B of signatures), "
            f"{unmeasurable['images']} images (priced by dimensions, not bytes)")
        if session.get('fit'):
            add('')
            add('  PER-TURN SOURCES, this session:')
            out.extend('  ' + line for line in fit_table(session['fit']))

    add('')
    add('CORPUS-WIDE per-turn sources (all sessions pooled):')
    out.extend(fit_table(report['fit']))
    return '\n'.join(out)


def fit_table(fit):
    """Render one measured density fit. Sources contributing 0 tokens are listed by name
    rather than dropped — a source the fit priced at zero is a finding, not an absence."""
    if not fit.get('available'):
        return [f"density fit UNAVAILABLE — {fit['reason']}"]
    lines = [f"MEASURED by NNLS over {fit['rows']:,} turns ({fit['columns']} parameters), "
             f"R2={fit['r2']}, total {fit['total_tokens']:,} tokens",
             f"  {'source':<26} {'tok/unit':>9} {'B/tok':>7} {'observed':>13} {'tokens':>12} {'share':>7}"]
    grand = sum(fit['attributed_tokens'].values()) or 1
    zeros = []
    for source, tokens in sorted(fit['attributed_tokens'].items(), key=lambda kv: -kv[1]):
        if tokens <= 0:
            zeros.append(f"{source} ({fit['observed_totals'][source]:,})")
            continue
        coefficient = fit['coefficients'][source]
        per_token = fit['bytes_per_token'].get(source)
        unit = 'items' if source.endswith('#') else ('turns' if source == 'per_turn_constant' else 'B')
        lines.append(f"  {source:<26} {coefficient:>9.4f} "
                     f"{(f'{per_token:.2f}' if per_token else '-'):>7} "
                     f"{fit['observed_totals'][source]:>9,} {unit:<5} {tokens:>12,} "
                     f"{100 * tokens / grand:>6.1f}%")
    if zeros:
        lines.append(f"  priced at ZERO tokens (observed bytes in parens): {', '.join(zeros)}")
    return lines


def main():
    args = [a for a in sys.argv[1:] if a != '--json']
    report = build(args or DEFAULT_ROOTS)
    if not report['sessions']:
        print('no transcripts with usage found', file=sys.stderr)
        return 1
    if '--json' in sys.argv[1:]:
        print(json.dumps(report, indent=2))
    else:
        print(human(report))
    return 0


if __name__ == '__main__':
    sys.exit(main())
