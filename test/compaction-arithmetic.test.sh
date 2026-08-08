#!/usr/bin/env bash
# compaction-arithmetic.test.sh — acceptance for docs/analysis/compaction-arithmetic.py.
#
# WHAT THIS MEASURES, AND WHY IT NEEDS A TEST
# -------------------------------------------
# compaction frequency = (threshold - post-compact baseline) / per-turn additions.
# Both terms are read out of the Claude Code JSONL transcript store. Every number the
# report publishes is an arithmetic consequence of four fields:
#
#   usage.input_tokens + usage.cache_creation_input_tokens + usage.cache_read_input_tokens
#     = the exact prompt size of one API request  (call it ctx)
#   compactMetadata.postTokens
#     = the exact size of the message array Claude Code retained through a compact
#
#   post-compact BASELINE  = ctx of the first request after a compact_boundary
#   STANDING overhead      = BASELINE - postTokens   (system preamble + tool defs +
#                            CLAUDE.md stack + skills prose — never in the transcript)
#   PER-TURN addition      = ctx(N+1) - ctx(N)
#
# Get any one of those wrong and the ranking that the whole compaction diet executes
# from is wrong. So this file pins the arithmetic against a fixture whose every token
# count is known by construction — no live transcript, no drift, no network.
#
# THE TRAP THIS GUARDS (inherited from token-spend-forensics.md)
#   One API request is written as MULTIPLE jsonl lines, one per content block, and each
#   line REPEATS the same message.usage object. Summing per line overstates by ~2.3x.
#   Proof D below feeds a duplicated-id record and demands the request count stay put.
#
# PROOFS
#   A. RUNS AT ALL           — script exists, is valid python, exits 0 on the fixture.
#   B. COMPACT ACCOUNTING    — finds the boundary, reports trigger/pre/post verbatim.
#   C. THE THREE TERMS       — baseline, standing, per-turn deltas are exactly right.
#   D. THE 2.3x TRAP         — usage deduped by message.id.
#   E. CACHE-CREATE WITNESS  — delta-ctx is cross-checked against cache_creation.
#   F. SOURCE ATTRIBUTION    — injected bytes at the boundary are bucketed by source.
#   G. HONEST ABOUT GAPS     — an un-fittable corpus reports that, never a fake number.
#   H. READ-ONLY             — the fixture is byte-identical after the run. The real
#      transcript store is irreplaceable; a measurement tool that can write to it is a
#      hazard regardless of whether it happens to today.
#
# Usage:  bash test/compaction-arithmetic.test.sh    (exit 0 = every proof holds)

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SELF_DIR/.." && pwd)"
SCRIPT="$REPO/docs/analysis/compaction-arithmetic.py"

PASS=0; FAIL=0
ok()  { printf '  \033[32mPASS\033[0m %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAIL=$((FAIL + 1)); }
sec() { printf '\n%s\n' "$1"; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
FIX="$TMP/store/fixture-session.jsonl"
mkdir -p "$TMP/store"

# ── the fixture: every token count below is chosen, not observed ──────────────────
#
#   req m1  ctx =     2 +  50000 +      0 =  50,002      (cold cache)
#   req m2  ctx =     2 +   1000 +  50000 =  51,002      delta = 1,000 == cache_create
#   -- compact_boundary: trigger auto, preTokens 51,002, postTokens 9,000 --
#   req m3  ctx =     2 +  40000 +      0 =  40,002      BASELINE
#                                                        STANDING = 40,002 - 9,000 = 31,002
#   req m4  ctx =     2 +    500 +  40000 =  40,502      delta =   500 == cache_create
#
#   m3 is emitted TWICE with the same message.id (the 2.3x trap) and must count once.
python3 - "$FIX" <<'PYFIX'
import json, sys

def usage(inp, cc, cr):
    return {"input_tokens": inp, "output_tokens": 7,
            "cache_creation_input_tokens": cc, "cache_read_input_tokens": cr,
            "cache_creation": {"ephemeral_1h_input_tokens": cc, "ephemeral_5m_input_tokens": 0}}

def asst(mid, u, content, ts):
    return {"type": "assistant", "uuid": mid + "-u", "isSidechain": False, "timestamp": ts,
            "sessionId": "fixture-session",
            "message": {"id": mid, "role": "assistant", "model": "claude-opus-5",
                        "usage": u, "content": content}}

rows = [
    asst("m1", usage(2, 50000, 0),
         [{"type": "thinking", "thinking": "", "signature": "s" * 64},
          {"type": "tool_use", "id": "t1", "name": "Bash", "input": {"command": "echo hi"}}],
         "2026-08-07T00:00:00.000Z"),
    {"type": "user", "uuid": "u1", "isSidechain": False, "timestamp": "2026-08-07T00:00:05.000Z",
     "sessionId": "fixture-session",
     "message": {"role": "user", "content": [
         {"type": "tool_result", "tool_use_id": "t1", "content": "B" * 400}]}},
    asst("m2", usage(2, 1000, 50000), [{"type": "text", "text": "T" * 120}],
         "2026-08-07T00:00:09.000Z"),
    {"type": "system", "subtype": "compact_boundary", "uuid": "cb1", "isSidechain": False,
     "timestamp": "2026-08-07T00:01:00.000Z", "sessionId": "fixture-session",
     "content": "Conversation compacted", "level": "info",
     "compactMetadata": {"trigger": "auto", "preTokens": 51002, "postTokens": 9000,
                         "cumulativeDroppedTokens": 42002, "durationMs": 90000}},
    {"type": "user", "uuid": "u2", "isSidechain": False, "isCompactSummary": True,
     "timestamp": "2026-08-07T00:01:01.000Z", "sessionId": "fixture-session",
     "message": {"role": "user", "content": "S" * 5000}},
    {"type": "attachment", "uuid": "a1", "isSidechain": False,
     "timestamp": "2026-08-07T00:01:02.000Z", "sessionId": "fixture-session",
     "attachment": {"type": "hook_success", "hookName": "SessionStart:compact",
                    "hookEvent": "SessionStart", "content": "I" * 17000,
                    "stdout": "I" * 17000, "stderr": "", "exitCode": 0}},
    {"type": "attachment", "uuid": "a2", "isSidechain": False,
     "timestamp": "2026-08-07T00:01:03.000Z", "sessionId": "fixture-session",
     "attachment": {"type": "agent_listing_delta", "addedTypes": ["x"],
                    "addedBlocks": ["G" * 16000]}},
    # an API-error placeholder: real message.id, zero usage, zero context. It is NOT the
    # post-compact baseline, and treating it as one yields a negative STANDING figure.
    {"type": "assistant", "uuid": "msyn-u", "isSidechain": False,
     "timestamp": "2026-08-07T00:01:05.000Z", "sessionId": "fixture-session",
     "message": {"id": "msyn", "role": "assistant", "model": "<synthetic>",
                 "usage": usage(0, 0, 0), "stop_reason": "stop_sequence",
                 "content": [{"type": "text", "text": "API Error: Connection closed"}]}},
    asst("m3", usage(2, 40000, 0), [{"type": "text", "text": "post"}],
         "2026-08-07T00:01:10.000Z"),
    # the 2.3x trap: same message.id, second content block, usage repeated verbatim
    asst("m3", usage(2, 40000, 0), [{"type": "tool_use", "id": "t2", "name": "Agent",
                                     "input": {"prompt": "P" * 200}}],
         "2026-08-07T00:01:10.000Z"),
    {"type": "user", "uuid": "u3", "isSidechain": False, "timestamp": "2026-08-07T00:01:20.000Z",
     "sessionId": "fixture-session",
     "message": {"role": "user", "content": [
         {"type": "tool_result", "tool_use_id": "t2", "content": "A" * 900}]}},
    # a background-agent handback. It arrives as a plain user string, NOT as a tool
    # result, so counting only tool:Agent understates what agents put into context.
    {"type": "user", "uuid": "u4", "isSidechain": False, "timestamp": "2026-08-07T00:01:22.000Z",
     "sessionId": "fixture-session",
     "message": {"role": "user",
                 "content": "<task-notification>\n<task-id>abc</task-id>\n" + "N" * 300 +
                            "\n</task-notification>"}},
    {"type": "user", "uuid": "u5", "isSidechain": False, "timestamp": "2026-08-07T00:01:23.000Z",
     "sessionId": "fixture-session",
     "message": {"role": "user", "content": "carry on"}},
    asst("m4", usage(2, 500, 40000), [{"type": "text", "text": "done"}],
         "2026-08-07T00:01:25.000Z"),
]
with open(sys.argv[1], "w") as fh:
    for r in rows:
        fh.write(json.dumps(r) + "\n")
PYFIX

FIX_SUM_BEFORE="$(shasum "$FIX" | awk '{print $1}')"

sec "A. THE SCRIPT RUNS:"
if [ -f "$SCRIPT" ]; then ok "docs/analysis/compaction-arithmetic.py exists"
else bad "docs/analysis/compaction-arithmetic.py missing"
     printf '\ncompaction-arithmetic.test.sh: %s passed, %s failed.\n' "$PASS" "$((FAIL+1))"; exit 1; fi

python3 -c "import ast,sys; ast.parse(open(sys.argv[1]).read())" "$SCRIPT" 2>/dev/null \
  && ok "parses as valid python3" || bad "python3 syntax error"

RC=0
J="$(python3 "$SCRIPT" --json "$TMP/store" 2>"$TMP/err.txt")" || RC=$?
[ "$RC" = 0 ] && ok "exits 0 on the fixture store" || bad "exit $RC; stderr: $(cat "$TMP/err.txt")"

# every later proof reads this JSON, so bail loudly if it is not JSON at all
if ! printf '%s' "$J" | jq -e . >/dev/null 2>&1; then
  bad "--json did not emit parseable JSON: $(printf '%s' "$J" | head -c 400)"
  printf '\ncompaction-arithmetic.test.sh: %s passed, %s failed.\n' "$PASS" "$FAIL"; exit 1
fi
ok "--json emits parseable JSON"

q() { printf '%s' "$J" | jq -r "$1" 2>/dev/null; }
eq() { # <jq-path> <expected> <label>
  local got; got="$(q "$1")"
  [ "$got" = "$2" ] && ok "$3 = $2" || bad "$3: expected $2, got $got"
}

sec "B. COMPACT ACCOUNTING (the boundary is found and reported verbatim):"
eq '.corpus.compacts' 1 "compacts found"
eq '.sessions[0].compacts[0].trigger' auto "trigger"
eq '.sessions[0].compacts[0].pre_tokens' 51002 "preTokens (reported, not recomputed)"
eq '.sessions[0].compacts[0].post_tokens' 9000 "postTokens (reported, not recomputed)"

sec "C. THE THREE TERMS OF THE ARITHMETIC:"
# BASELINE is the real prompt size of the first request after the boundary — 40,002,
# NOT the 9,000 postTokens advertises. The gap between them is the whole point.
eq '.sessions[0].compacts[0].baseline_tokens' 40002 "post-compact BASELINE"
eq '.sessions[0].compacts[0].standing_tokens' 31002 "STANDING overhead (baseline - postTokens)"
eq '.sessions[0].turns.count' 2 "per-turn deltas measured"
eq '.sessions[0].turns.total_tokens' 1500 "per-turn additions total (1000 + 500)"
eq '.sessions[0].turns.median_tokens' 750 "median per-turn addition"
# a zero-context API-error placeholder sits between the boundary and m3; if it were
# mistaken for the baseline, STANDING would come out as 0 - 9,000 = -9,000.
eq '.sessions[0].compacts[0].zero_context_records_skipped' 1 "zero-context placeholders skipped"
STANDING="$(q '.sessions[0].compacts[0].standing_tokens')"
[ "${STANDING:-0}" -gt 0 ] 2>/dev/null && ok "STANDING is positive (a negative one is always a bug)" \
                                       || bad "STANDING came out $STANDING"

sec "C2. TOKENS BETWEEN COMPACTS AND HEADROOM:"
# climb = how far context rose from the previous baseline before this compact fired.
# There is no previous compact here, so the session's first request is the origin:
# 51,002 - 50,002 = 1,000, which is exactly the one turn that happened.
eq '.sessions[0].compacts[0].tokens_since_previous_baseline' 1000 "tokens between compacts"
# headroom = what this compact actually bought: 51,002 - 40,002.
eq '.sessions[0].compacts[0].headroom_tokens' 11000 "headroom after the compact"

sec "D. THE 2.3x TRAP (usage deduped by message.id):"
# 6 assistant lines carry usage; m3 appears twice with an identical usage object.
eq '.sessions[0].requests' 5 "requests (6 assistant lines, 5 distinct message.id)"

sec "D2. AGENT HANDBACKS ARRIVE AS USER STRINGS, NOT ONLY TOOL RESULTS:"
TN="$(q '.sessions[0].bucket_bytes["user:task_notification"] // 0')"
[ "${TN:-0}" -ge 300 ] 2>/dev/null && ok "task-notification handback bucketed separately ($TN B)" \
                                   || bad "task notification not separated: got ${TN:-<none>}"
eq '.sessions[0].bucket_bytes["user:prompt"]' 8 "human prompt bytes (\"carry on\") kept separate"

sec "E. CACHE-CREATE WITNESS (delta-ctx cross-checked, never asserted alone):"
eq '.corpus.delta_vs_cache_create.pairs' 2 "in-lineage request pairs"
eq '.corpus.delta_vs_cache_create.exact' 2 "pairs where delta == cache_creation"

sec "F. SOURCE ATTRIBUTION AT THE BOUNDARY (bytes, measured per source):"
eq '.sessions[0].compacts[0].injected_bytes["hook:SessionStart:compact"]' 17000 "SessionStart:compact hook bytes"
eq '.sessions[0].compacts[0].injected_bytes["compact_summary"]' 5000 "compact summary bytes"
GOT_AGENT="$(q '.sessions[0].compacts[0].injected_bytes["attach:agent_listing_delta"]')"
[ "${GOT_AGENT:-0}" -ge 16000 ] 2>/dev/null \
  && ok "agent_listing_delta bytes >= 16000 (got $GOT_AGENT)" \
  || bad "agent_listing_delta not attributed: got ${GOT_AGENT:-<none>}"
# the summary must NOT be silently folded into ordinary user prompt text
UP="$(q '.sessions[0].compacts[0].injected_bytes["user:prompt"] // 0')"
[ "$UP" = "0" ] || [ "$UP" = "null" ] \
  && ok "compact summary is not miscounted as a user prompt" \
  || bad "compact summary leaked into user:prompt ($UP bytes)"

sec "G. HONEST ABOUT WHAT IT CANNOT MEASURE:"
# 2 turns cannot support a 10-column fit. It must SAY so, not invent coefficients.
FITTED="$(q '.fit.available')"
[ "$FITTED" = "false" ] && ok "declines to fit a 2-turn corpus (fit.available=false)" \
                        || bad "claimed a fit on 2 turns (fit.available=$FITTED)"
REASON="$(q '.fit.reason // ""')"
[ -n "$REASON" ] && ok "states why: $REASON" || bad "no reason given for the absent fit"
# thinking text is empty in every persisted block; the tool must never price it by bytes
THINK="$(q '.sessions[0].unmeasurable.thinking_blocks')"
[ "$THINK" = "1" ] && ok "counts thinking blocks as unmeasurable (text is not persisted)" \
                   || bad "thinking blocks not reported as unmeasurable (got $THINK)"

sec "H. READ-ONLY ON THE TRANSCRIPT STORE:"
FIX_SUM_AFTER="$(shasum "$FIX" | awk '{print $1}')"
[ "$FIX_SUM_BEFORE" = "$FIX_SUM_AFTER" ] \
  && ok "fixture transcript is byte-identical after the run" \
  || bad "the fixture transcript was MODIFIED — the tool writes to the store"
NEW="$(find "$TMP/store" -newer "$SCRIPT" -type f 2>/dev/null | grep -v 'fixture-session.jsonl' | head -1)"
[ -z "$NEW" ] && ok "no new files created inside the store" || bad "created $NEW inside the store"
grep -qE "open\([^)]*,[[:space:]]*['\"][wa]" "$SCRIPT" \
  && bad "script contains a write-mode open() — it can write" \
  || ok "no write-mode open() anywhere in the script"

printf '\ncompaction-arithmetic.test.sh: %s passed, %s failed.\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
