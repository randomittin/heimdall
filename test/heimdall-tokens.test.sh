#!/usr/bin/env bash
# test/heimdall-tokens.test.sh — heimdall-tokens GENERAL token-meter acceptance.
#
# Proves the model-token accounting tool end-to-end on SYNTHETIC FIXTURES ONLY —
# NO real model call, NO network, NO token spend, NO real ~/.claude transcript.
# Every fixture is built inline with KNOWN usage numbers so the sums are exactly
# predictable; the test asserts the tool reports them faithfully and degrades
# (never crashes) on malformed input.
#
# Asserted:
#   (a) session mode sums input/output/cache_creation/cache_read across EVERY
#       assistant turn of a 3-turn transcript, total_tokens = the four summed,
#       and reports turns + session_id. User/system turns contribute nothing.
#   (b) total_tokens == the four summed components (the conservative cap figure).
#   (c) total_cost_usd: no per-turn cost => null + a note (never fabricated).
#   (c2) per-turn cost present => summed into total_cost_usd.
#   (d) json mode parses a `claude --output-format json` blob's top-level
#       .usage + .total_cost_usd into the same record shape.
#   (e) json mode reads from STDIN as well as a file path.
#   (f) a MALFORMED transcript yields a DEGRADED record (zeros + an error note),
#       exit 0 — never a crash (the sweep consumer must fail-open).
#   (g) a MISSING file yields a degraded record, exit 0.
#   (h) --cwd <dir> resolves the NEWEST session JSONL under the cwd-slug dir and
#       sums it (the sweep's resolution path), against a synthetic projects root.

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
TOK="$ROOT/bin/heimdall-tokens"

PASS=0
FAIL=0
ok()  { PASS=$((PASS+1)); printf "  \033[32mPASS\033[0m %s\n" "$1"; }
bad() { FAIL=$((FAIL+1)); printf "  \033[31mFAIL\033[0m %s\n" "$1"; }

command -v jq >/dev/null 2>&1 || { echo "FATAL: jq required for the JSON assertions" >&2; exit 2; }
[ -x "$TOK" ] || { echo "FATAL: heimdall-tokens not executable at $TOK" >&2; exit 2; }

WORK="$(mktemp -d -t "tokens-test.$(printf 'X%.0s' 1 2 3 4 5 6)")"
trap 'rm -rf "$WORK"' EXIT

# ── (a)(b)(c) SYNTHETIC 3-turn transcript (nested message.usage — real shape) ──
# Three assistant turns with KNOWN usage, plus a user turn and a system turn that
# carry NO usage (must contribute zero). NO per-turn cost here → cost is null+note.
#   turn1: in=100 out=10  cc=1000 cr=5000
#   turn2: in=200 out=20  cc=0    cr=8000
#   turn3: in=300 out=30  cc=2000 cr=9000
#   ─────────────────────────────────────
#   sum:   in=600 out=60  cc=3000 cr=22000  total=25660  turns=3
SESS="$WORK/session-known.jsonl"
SID="sess-fixture-0001"
{
  printf '%s\n' "{\"type\":\"user\",\"sessionId\":\"$SID\",\"message\":{\"role\":\"user\",\"content\":\"hi\"}}"
  printf '%s\n' "{\"type\":\"assistant\",\"sessionId\":\"$SID\",\"message\":{\"role\":\"assistant\",\"usage\":{\"input_tokens\":100,\"output_tokens\":10,\"cache_creation_input_tokens\":1000,\"cache_read_input_tokens\":5000}}}"
  printf '%s\n' "{\"type\":\"system\",\"sessionId\":\"$SID\",\"subtype\":\"info\"}"
  printf '%s\n' "{\"type\":\"assistant\",\"sessionId\":\"$SID\",\"message\":{\"role\":\"assistant\",\"usage\":{\"input_tokens\":200,\"output_tokens\":20,\"cache_creation_input_tokens\":0,\"cache_read_input_tokens\":8000}}}"
  printf '%s\n' "{\"type\":\"assistant\",\"sessionId\":\"$SID\",\"message\":{\"role\":\"assistant\",\"usage\":{\"input_tokens\":300,\"output_tokens\":30,\"cache_creation_input_tokens\":2000,\"cache_read_input_tokens\":9000}}}"
} > "$SESS"

REC="$("$TOK" session "$SESS")"
if printf '%s' "$REC" | jq -e . >/dev/null 2>&1; then
  IN="$(printf '%s' "$REC" | jq -r '.input_tokens')"
  OUT="$(printf '%s' "$REC" | jq -r '.output_tokens')"
  CC="$(printf '%s' "$REC" | jq -r '.cache_creation_tokens')"
  CR="$(printf '%s' "$REC" | jq -r '.cache_read_tokens')"
  TT="$(printf '%s' "$REC" | jq -r '.total_tokens')"
  TURNS="$(printf '%s' "$REC" | jq -r '.turns')"
  RSID="$(printf '%s' "$REC" | jq -r '.session_id')"
  if [ "$IN" = 600 ] && [ "$OUT" = 60 ] && [ "$CC" = 3000 ] && [ "$CR" = 22000 ] \
     && [ "$TT" = 25660 ] && [ "$TURNS" = 3 ] && [ "$RSID" = "$SID" ]; then
    ok "(a) session sums all 4 components over 3 assistant turns (total=$TT, turns=$TURNS, sid=$RSID)"
  else
    bad "(a) session sums wrong (in=$IN out=$OUT cc=$CC cr=$CR total=$TT turns=$TURNS sid=$RSID)"
    printf '%s\n' "$REC"
  fi
else
  bad "(a) session mode did not emit valid JSON"; printf '%s\n' "$REC"
fi

# total_tokens MUST equal the four summed components (the cap-enforced figure).
if printf '%s' "$REC" | jq -e '.total_tokens == (.input_tokens + .output_tokens + .cache_creation_tokens + .cache_read_tokens)' >/dev/null 2>&1; then
  ok "(b) total_tokens == input+output+cache_creation+cache_read (the conservative cap figure)"
else
  bad "(b) total_tokens != sum of the four components"; printf '%s\n' "$REC"
fi

# no per-turn cost in this fixture → total_cost_usd is null with a note, NOT a
# fabricated number.
COST="$(printf '%s' "$REC" | jq -r '.total_cost_usd')"
NOTE="$(printf '%s' "$REC" | jq -r '.note // ""')"
if [ "$COST" = "null" ] && [ -n "$NOTE" ]; then
  ok "(c) no per-turn cost => total_cost_usd null + a note (never fabricated)"
else
  bad "(c) cost not honestly null+note (cost=$COST note='$NOTE')"; printf '%s\n' "$REC"
fi

# ── (c2) a transcript WITH per-turn cost => cost is summed, not null ───────────
SESSC="$WORK/session-costed.jsonl"
SIDC="sess-costed-0002"
{
  printf '%s\n' "{\"type\":\"assistant\",\"sessionId\":\"$SIDC\",\"message\":{\"role\":\"assistant\",\"usage\":{\"input_tokens\":100,\"output_tokens\":10,\"cache_creation_input_tokens\":0,\"cache_read_input_tokens\":0}},\"costUSD\":0.0125}"
  printf '%s\n' "{\"type\":\"assistant\",\"sessionId\":\"$SIDC\",\"message\":{\"role\":\"assistant\",\"usage\":{\"input_tokens\":200,\"output_tokens\":20,\"cache_creation_input_tokens\":0,\"cache_read_input_tokens\":0}},\"costUSD\":0.0375}"
} > "$SESSC"
RECC="$("$TOK" session "$SESSC")"
COSTC="$(printf '%s' "$RECC" | jq -r '.total_cost_usd')"
if printf '%s' "$RECC" | jq -e '.total_cost_usd == 0.05' >/dev/null 2>&1; then
  ok "(c2) per-turn costUSD summed into total_cost_usd ($COSTC)"
else
  bad "(c2) per-turn cost not summed (got $COSTC, expected 0.05)"; printf '%s\n' "$RECC"
fi

# ── (d)(e) json mode: a `claude --output-format json` blob ────────────────────
# top-level .usage + .total_cost_usd (the single-shot path's record shape).
BLOB="$WORK/claude-json.json"
cat > "$BLOB" <<'EOF'
{
  "type": "result",
  "session_id": "json-fixture-9001",
  "total_cost_usd": 0.1234,
  "usage": {
    "input_tokens": 111,
    "output_tokens": 22,
    "cache_creation_input_tokens": 3333,
    "cache_read_input_tokens": 44444
  },
  "modelUsage": {}
}
EOF
JREC="$("$TOK" json "$BLOB")"
if printf '%s' "$JREC" | jq -e '
    .input_tokens == 111 and .output_tokens == 22
    and .cache_creation_tokens == 3333 and .cache_read_tokens == 44444
    and .total_tokens == 47910
    and .total_cost_usd == 0.1234
    and .session_id == "json-fixture-9001"
  ' >/dev/null 2>&1; then
  ok "(d) json mode extracts .usage + .total_cost_usd into the record (total=47910)"
else
  bad "(d) json mode extraction wrong"; printf '%s\n' "$JREC"
fi

# json mode via STDIN (the pipe path).
JREC2="$("$TOK" json - < "$BLOB")"
if printf '%s' "$JREC2" | jq -e '.total_tokens == 47910 and .total_cost_usd == 0.1234' >/dev/null 2>&1; then
  ok "(e) json mode reads from STDIN (-) identically"
else
  bad "(e) json mode STDIN path failed"; printf '%s\n' "$JREC2"
fi

# ── (f) malformed transcript => degraded record (zeros + error), exit 0 ───────
BADSESS="$WORK/garbage.jsonl"
printf '%s\n' 'this is not json at all {{{' '<<<also broken' > "$BADSESS"
set +e
BADREC="$("$TOK" session "$BADSESS" 2>/dev/null)"; BADRC=$?
set -e
if [ "$BADRC" -eq 0 ] && printf '%s' "$BADREC" | jq -e '
    .total_tokens == 0 and (.error // "" | length > 0)
  ' >/dev/null 2>&1; then
  ok "(f) malformed transcript => degraded record (zeros + error note), exit 0 (fail-open)"
else
  bad "(f) malformed transcript not degraded cleanly (rc=$BADRC)"; printf '%s\n' "$BADREC"
fi

# ── (g) missing file => degraded record, exit 0 ───────────────────────────────
set +e
MISSREC="$("$TOK" session "$WORK/does-not-exist.jsonl" 2>/dev/null)"; MISSRC=$?
set -e
if [ "$MISSRC" -eq 0 ] && printf '%s' "$MISSREC" | jq -e '
    .total_tokens == 0 and (.error // "" | length > 0)
  ' >/dev/null 2>&1; then
  ok "(g) missing transcript => degraded record, exit 0 (never crash)"
else
  bad "(g) missing transcript not handled fail-open (rc=$MISSRC)"; printf '%s\n' "$MISSREC"
fi

# ── (h) --cwd resolves the NEWEST session JSONL under the cwd-slug dir ─────────
# Build a SYNTHETIC projects root mimicking ~/.claude/projects/<slug>/. The slug
# is every non-alphanumeric char of the cwd path replaced with '-'. We point the
# tool at our synthetic root via --projects-root so NO real ~/.claude is touched.
FAKE_CWD="/tmp/heimdall/some-run-dir"
SLUG="$(printf '%s' "$FAKE_CWD" | sed 's/[^A-Za-z0-9]/-/g')"
PROOT="$WORK/projects"
SDIR="$PROOT/$SLUG"
mkdir -p "$SDIR"
# an OLDER session (should be ignored — only the newest is summed).
OLDSESS="$SDIR/old-session.jsonl"
printf '%s\n' "{\"type\":\"assistant\",\"sessionId\":\"old\",\"message\":{\"role\":\"assistant\",\"usage\":{\"input_tokens\":1,\"output_tokens\":1,\"cache_creation_input_tokens\":0,\"cache_read_input_tokens\":0}}}" > "$OLDSESS"
# the NEWEST session with known usage in=7 out=3 cc=0 cr=0 total=10.
NEWSESS="$SDIR/new-session.jsonl"
printf '%s\n' "{\"type\":\"assistant\",\"sessionId\":\"newest\",\"message\":{\"role\":\"assistant\",\"usage\":{\"input_tokens\":7,\"output_tokens\":3,\"cache_creation_input_tokens\":0,\"cache_read_input_tokens\":0}}}" > "$NEWSESS"
# make the new one strictly newer by mtime.
touch -t 202001010000 "$OLDSESS"
touch -t 202601010000 "$NEWSESS"
CREC="$("$TOK" session --cwd "$FAKE_CWD" --projects-root "$PROOT")"
if printf '%s' "$CREC" | jq -e '.total_tokens == 10 and .session_id == "newest"' >/dev/null 2>&1; then
  ok "(h) --cwd resolves the NEWEST session JSONL under the slug dir (total=10, sid=newest)"
else
  bad "(h) --cwd resolution did not pick the newest session"; printf '%s\n' "$CREC"
fi

# ── (i) emitted mode: normalize the SOURCE record hmd writes (the locked schema) ─
# A synthetic emitted record carrying the short cache_* names + session_id + cost +
# model + usage_available. emitted mode must return the same normalized record
# shape, re-deriving total_tokens from the four components.
#   in=10 out=5 cc=100 cr=900  => total=1015
EMITTED="$WORK/emitted-known.json"
cat > "$EMITTED" <<'EOF'
{
  "session_id": "emit-fixture-7001",
  "input_tokens": 10,
  "output_tokens": 5,
  "cache_creation_tokens": 100,
  "cache_read_tokens": 900,
  "total_tokens": 1015,
  "total_cost_usd": 0.0421,
  "model": "claude-opus-4-8",
  "usage_available": true
}
EOF
EREC="$("$TOK" emitted "$EMITTED")"
if printf '%s' "$EREC" | jq -e '
    .input_tokens == 10 and .output_tokens == 5
    and .cache_creation_tokens == 100 and .cache_read_tokens == 900
    and .total_tokens == 1015
    and .total_cost_usd == 0.0421
    and .session_id == "emit-fixture-7001"
    and .model == "claude-opus-4-8"
    and .usage_available == true
  ' >/dev/null 2>&1; then
  ok "(i) emitted mode normalizes the source record (total=1015, cost=0.0421, sid+model carried)"
else
  bad "(i) emitted mode normalization wrong"; printf '%s\n' "$EREC"
fi

# total_tokens must be RE-DERIVED from the four components, not trusted from the
# source: feed a record whose stated total is WRONG and assert the meter recomputes.
EMITTED_BADTOTAL="$WORK/emitted-badtotal.json"
cat > "$EMITTED_BADTOTAL" <<'EOF'
{
  "session_id": "emit-fixture-7002",
  "input_tokens": 10,
  "output_tokens": 5,
  "cache_creation_tokens": 100,
  "cache_read_tokens": 900,
  "total_tokens": 999999,
  "total_cost_usd": null,
  "model": "claude-opus-4-8",
  "usage_available": true
}
EOF
EREC2="$("$TOK" emitted "$EMITTED_BADTOTAL")"
if printf '%s' "$EREC2" | jq -e '.total_tokens == 1015' >/dev/null 2>&1; then
  ok "(j) emitted mode RE-DERIVES total_tokens from components (ignores a tampered source total)"
else
  bad "(j) emitted total not re-derived"; printf '%s\n' "$EREC2"
fi

# a malformed / missing emitted record => degraded zeros record, exit 0 (fail-open).
set +e
EBADREC="$("$TOK" emitted "$WORK/no-such-emitted.json" 2>/dev/null)"; EBADRC=$?
set -e
if [ "$EBADRC" -eq 0 ] && printf '%s' "$EBADREC" | jq -e '
    .total_tokens == 0 and (.error // "" | length > 0)
  ' >/dev/null 2>&1; then
  ok "(k) emitted mode missing record => degraded zeros record, exit 0 (fail-open)"
else
  bad "(k) emitted missing record not handled fail-open (rc=$EBADRC)"; printf '%s\n' "$EBADREC"
fi

echo
echo "  heimdall-tokens tests: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
