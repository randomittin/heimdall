#!/usr/bin/env bash
#
# heimdall-tier-agents.test.sh — acceptance for `heimdall-tier agents`, the
# per-agent tier/model/override report.
#
# WHY: model routing is invisible today. heimdall-self-improve writes
# .planning/routing-overrides.json, and nothing in the selection path reads it
# — the actual decision is each agents/*.md template's `tier:`/`model:`
# frontmatter. `heimdall-tier agents --json` is the ONE machine-readable report
# of that reality, reusing read_frontmatter()/load_table() (the same parser
# `heimdall-tier check` already uses) rather than standing up a second parser
# that could quietly disagree with it. sentinels/hmd-statusline.py's swarm
# block caches this command's --json output to put per-agent tier on the
# statusline without ever reading agents/*.md on the render path itself.
#
# Guarantees proved:
#   1. `heimdall-tier agents` is reachable (subcommand exists, --json works).
#   2. On a fixture repo, a plain agent (no override) reports its declared
#      tier/model/class and a null override.
#   3. When routing-overrides.json carries an override for that agent's CLASS,
#      the report surfaces it — but the row's declared_tier is UNCHANGED and
#      the override is marked NOT in effect. An override must never be
#      rendered as though it were the tier that actually runs.
#   4. A missing routing-overrides.json degrades to "no override" (null),
#      never an error — the file is optional, written by an unrelated
#      pipeline.
#   5. A CORRUPT routing-overrides.json (bad JSON) degrades the same way —
#      never a crash.
#   6. An unmapped agent name (no entry in tier-table.json's agents map)
#      reports class=null rather than raising.
#   7. This is a REPORT, not a gate: unlike `heimdall-tier check`, an EMPTY
#      agents/ dir returns exit 0 with an empty list — it must never block a
#      statusline render just because a fixture/worktree has no templates yet.
#   8. The shipped repo itself parses cleanly under `agents --json` (real
#      agents/*.md, real tier-table.json).
#
# FALSIFIER: comment out the override cross-check in cmd_agents and case 3
# goes RED (override becomes null); make cmd_agents call class_tier() instead
# of echoing fields.get('tier') and case 2/3's declared_tier assertions go RED.
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SELF_DIR/.." && pwd)"
TIER="$REPO/bin/heimdall-tier"

PASS=0; FAIL=0
ok()  { printf '  \033[32mPASS\033[0m %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAIL=$((FAIL+1)); }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/tier-agents.XXXXXX")"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

echo "heimdall-tier-agents harness  repo=$REPO"
echo "--------------------------------------------------------------------"

# ── 1. REACHABILITY ──
"$TIER" agents --json --repo "$REPO" >/dev/null 2>"$TMP/reach.err"; rc=$?
[ "$rc" -eq 0 ] \
  && ok "heimdall-tier agents --json is reachable and exits 0" \
  || bad "heimdall-tier agents --json failed (rc=$rc): $(cat "$TMP/reach.err")"

mk_agent() {
  # mk_agent <fixture-dir> <name> <model> [tier] [reason]
  local dir="$1/agents" name="$2" model="$3" tier="${4:-}" reason="${5:-}"
  mkdir -p "$dir"
  {
    printf '%s\n' '---'
    printf 'name: %s\n' "$name"
    printf 'description: fixture template for the tier-agents report\n'
    [ -n "$model" ]  && printf 'model: %s\n' "$model"
    [ -n "$tier" ]   && printf 'tier: %s\n' "$tier"
    [ -n "$reason" ] && printf 'tier_reason: %s\n' "$reason"
    printf '%s\n' '---'
    printf '\n%s\n' 'Fixture body.'
  } > "$dir/$name.md"
}

extract() {
  # extract <json-file> <python-expr-suffix-on-loaded-dict>  (prints repr)
  python3 -c "
import json,sys
with open('$1') as f: d = json.load(f)
print($2)
"
}

# ── 2. PLAIN AGENT, NO OVERRIDE ──
FIX_PLAIN="$TMP/fix-plain"; mk_agent "$FIX_PLAIN" coder sonnet sonnet
"$TIER" agents --json --repo "$FIX_PLAIN" > "$TMP/plain.json" 2>"$TMP/plain.err"; rc=$?
if [ "$rc" -eq 0 ] && python3 -c "import json; json.load(open('$TMP/plain.json'))" 2>/dev/null; then
  ok "plain fixture: agents --json emits valid JSON (rc=0)"
else
  bad "plain fixture: agents --json rc=$rc invalid/missing JSON: $(cat "$TMP/plain.err")"
fi
ROW_TIER="$(extract "$TMP/plain.json" "next(r['declared_tier'] for r in d['agents'] if r['agent']=='coder')" 2>/dev/null)"
ROW_CLASS="$(extract "$TMP/plain.json" "next(r['class'] for r in d['agents'] if r['agent']=='coder')" 2>/dev/null)"
ROW_OV="$(extract "$TMP/plain.json" "next(r['override'] for r in d['agents'] if r['agent']=='coder')" 2>/dev/null)"
[ "$ROW_TIER" = "sonnet" ] \
  && ok "plain fixture: coder reports declared_tier=sonnet" \
  || bad "plain fixture: coder declared_tier='$ROW_TIER' (expected sonnet)"
[ "$ROW_CLASS" = "coder" ] \
  && ok "plain fixture: coder maps to class=coder" \
  || bad "plain fixture: coder class='$ROW_CLASS' (expected coder)"
[ "$ROW_OV" = "None" ] \
  && ok "plain fixture: no routing-overrides.json -> override is null" \
  || bad "plain fixture: override='$ROW_OV' (expected None with no overrides file)"

# ── 3. OVERRIDE EXISTS BUT NOT APPLIED ──
FIX_OV="$TMP/fix-override"; mk_agent "$FIX_OV" coder sonnet sonnet
mkdir -p "$FIX_OV/.planning"
cat > "$FIX_OV/.planning/routing-overrides.json" <<'JSON'
{"schema":"heimdall.routing-overrides/1","overrides":{"coder":{"model":"opus","reason":"self-improve experiment (unvalidated)","experiment":"exp-1","status":"open","applied":"2026-08-20T00:00:00Z"}},"updated":"2026-08-20T00:00:00Z"}
JSON
"$TIER" agents --json --repo "$FIX_OV" > "$TMP/ov.json" 2>"$TMP/ov.err"; rc=$?
[ "$rc" -eq 0 ] \
  && ok "override fixture: agents --json still exits 0" \
  || bad "override fixture: agents --json failed (rc=$rc): $(cat "$TMP/ov.err")"
OV_MODEL="$(extract "$TMP/ov.json" "next(r['override']['model'] for r in d['agents'] if r['agent']=='coder')" 2>/dev/null)"
OV_EFFECT="$(extract "$TMP/ov.json" "next(r['override']['in_effect'] for r in d['agents'] if r['agent']=='coder')" 2>/dev/null)"
OV_DECLARED="$(extract "$TMP/ov.json" "next(r['declared_tier'] for r in d['agents'] if r['agent']=='coder')" 2>/dev/null)"
[ "$OV_MODEL" = "opus" ] \
  && ok "override fixture: the pending override (opus) is surfaced" \
  || bad "override fixture: override model='$OV_MODEL' (expected opus)"
[ "$OV_EFFECT" = "False" ] \
  && ok "override fixture: override is explicitly marked NOT in effect" \
  || bad "override fixture: override.in_effect='$OV_EFFECT' (expected False — must never look active)"
[ "$OV_DECLARED" = "sonnet" ] \
  && ok "override fixture: declared_tier stays sonnet — override never substituted as the active tier" \
  || bad "override fixture: declared_tier='$OV_DECLARED' (expected sonnet unchanged — the honesty requirement)"

# ── 4. MISSING overrides file (repeat of case 2's shape, named for clarity) ──
[ "$ROW_OV" = "None" ] \
  && ok "missing routing-overrides.json degrades to null override, not an error" \
  || bad "missing routing-overrides.json did not degrade cleanly"

# ── 5. CORRUPT overrides file ──
FIX_BADOV="$TMP/fix-badov"; mk_agent "$FIX_BADOV" coder sonnet sonnet
mkdir -p "$FIX_BADOV/.planning"
printf '{ this is not json' > "$FIX_BADOV/.planning/routing-overrides.json"
"$TIER" agents --json --repo "$FIX_BADOV" > "$TMP/badov.json" 2>"$TMP/badov.err"; rc=$?
if [ "$rc" -eq 0 ] && python3 -c "import json; json.load(open('$TMP/badov.json'))" 2>/dev/null; then
  ok "corrupt routing-overrides.json: still exits 0 with valid JSON (no crash)"
else
  bad "corrupt routing-overrides.json crashed the report (rc=$rc): $(cat "$TMP/badov.err")"
fi

# ── 6. UNMAPPED agent name ──
FIX_UNMAPPED="$TMP/fix-unmapped"; mk_agent "$FIX_UNMAPPED" totally-unknown-agent sonnet sonnet
"$TIER" agents --json --repo "$FIX_UNMAPPED" > "$TMP/unmapped.json" 2>"$TMP/unmapped.err"; rc=$?
UM_CLASS="$(extract "$TMP/unmapped.json" "next(r['class'] for r in d['agents'] if r['agent']=='totally-unknown-agent')" 2>/dev/null)"
if [ "$rc" -eq 0 ] && [ "$UM_CLASS" = "None" ]; then
  ok "unmapped agent name reports class=null instead of raising"
else
  bad "unmapped agent name mishandled (rc=$rc class='$UM_CLASS')"
fi

# ── 7. EMPTY agents/ dir — a REPORT, not a gate: exit 0, empty list ──
FIX_EMPTY="$TMP/fix-empty"; mkdir -p "$FIX_EMPTY/agents"
"$TIER" agents --json --repo "$FIX_EMPTY" > "$TMP/empty.json" 2>"$TMP/empty.err"; rc=$?
EMPTY_LEN="$(extract "$TMP/empty.json" "len(d['agents'])" 2>/dev/null)"
if [ "$rc" -eq 0 ] && [ "$EMPTY_LEN" = "0" ]; then
  ok "empty agents/ dir: exit 0 with an empty list (never blocks a render)"
else
  bad "empty agents/ dir mishandled (rc=$rc len='$EMPTY_LEN') — this is a report, not check's fail-closed gate"
fi

# ── 8. SHIPPED repo parses cleanly ──
"$TIER" agents --json --repo "$REPO" > "$TMP/real.json" 2>"$TMP/real.err"; rc=$?
REAL_LEN="$(extract "$TMP/real.json" "len(d['agents'])" 2>/dev/null)"
if [ "$rc" -eq 0 ] && [ -n "$REAL_LEN" ] && [ "$REAL_LEN" -gt 0 ] 2>/dev/null; then
  ok "shipped repo: agents --json reports $REAL_LEN real templates"
else
  bad "shipped repo: agents --json failed or reported none (rc=$rc len='$REAL_LEN'): $(cat "$TMP/real.err")"
fi

echo ""
echo "heimdall-tier-agents.test.sh: $PASS passed, $FAIL failed."
[ "$FAIL" -eq 0 ] || exit 1
exit 0
