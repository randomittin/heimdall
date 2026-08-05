#!/usr/bin/env bash
# test/reuse-metric.test.sh — S-6 C1 acceptance test for the reuse analyzer.
#
# Proves, against REAL temp git repos and REAL diffs (no canned numbers):
#   (a) a unit that CALLS an existing repo symbol counts as reusing,
#   (b) a unit that REIMPLEMENTS an existing capability without calling it counts
#       as reinventing AND appears in suspected_duplicates,
#   (c) the emitted JSON record is well-formed (`jq -e .`) with every required
#       field present,
#   (d) reuse_pct is computed correctly on a known mix.
# Plus: the analyzer degrades safely (never nonzero) on an unsupported language,
# and emits an honest null record rather than a fabricated percentage.

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
METRIC="$ROOT/bin/heimdall-reuse-metric"
ANALYZER="$ROOT/bin/lib/reuse_analyzer.py"

PASS=0
FAIL=0
ok()   { PASS=$((PASS+1)); printf "  \033[32mPASS\033[0m %s\n" "$1"; }
bad()  { FAIL=$((FAIL+1)); printf "  \033[31mFAIL\033[0m %s\n" "$1"; }

command -v jq >/dev/null 2>&1 || { echo "FATAL: jq required for the JSON-shape assertions" >&2; exit 2; }
PY="$(command -v python3 || command -v python)"

WORK="$(mktemp -d -t "reuse-test.$(printf 'X%.0s' 1 2 3 4 5 6)")"
trap 'rm -rf "$WORK"' EXIT

# HERMETIC: anything that reaches the metric emitter or dream also reaches their
# relocated state dir under $HEIMDALL_HOME (bin/lib/dream_data.py). Redirect it at the
# throwaway tree so no case here can write to the operator's real ~/.heimdall.
export HEIMDALL_HOME="$WORK/heimdall-home"
mkdir -p "$HEIMDALL_HOME"

# ── build a base repo with pre-existing capability ────────────────────────────
REPO="$WORK/repo"
mkdir -p "$REPO/utils" "$REPO/db" "$REPO/api"
git -C "$REPO" init -q
git -C "$REPO" config user.email "test@runheimdall.dev"
git -C "$REPO" config user.name "reuse-test"

cat > "$REPO/utils/format.js" <<'EOF'
// pre-existing utility — the capability a reuse-friendly task should CALL.
export function formatUser(user) {
  return user.first + " " + user.last + " <" + user.email + ">";
}
export function slugify(s) {
  return String(s).toLowerCase().replace(/\s+/g, "-");
}
EOF

cat > "$REPO/db/client.js" <<'EOF'
// pre-existing db accessor.
export function getUser(id) {
  return { id: id, first: "Ada", last: "Lovelace", email: "ada@x.io" };
}
EOF

git -C "$REPO" add -A
git -C "$REPO" commit -qm "base: existing format + db utilities"
BASE="$(git -C "$REPO" rev-parse HEAD)"

emit_for() {
  # $1 run-id ; record path echoed on stdout. Runs analyzer over working tree vs BASE.
  local rid="$1"
  "$METRIC" --repo "$REPO" --base "$BASE" --task "$rid" --run-id "$rid" --quiet >/dev/null
  echo "$REPO/.planning/reuse/$rid.json"
}

# ── (a) REUSE: new endpoint CALLS the existing formatUser + getUser ───────────
cat > "$REPO/api/users.js" <<'EOF'
import { formatUser } from "../utils/format.js";
import { getUser } from "../db/client.js";

// reuses pre-existing repo code: calls getUser + formatUser, does not rewrite.
export function userEndpoint(req, res) {
  const u = getUser(req.params.id);
  res.send(formatUser(u));
}
EOF
REC_A="$(emit_for reuse-a)"
if jq -e '.units_reusing >= 1 and (.reused_symbols | map(.symbol) | index("formatUser"))' "$REC_A" >/dev/null; then
  ok "(a) unit calling existing formatUser counts as reusing"
else
  bad "(a) reuse not detected for formatUser/getUser call"; jq . "$REC_A" 2>/dev/null || cat "$REC_A"
fi
git -C "$REPO" checkout -q -- . 2>/dev/null; rm -f "$REPO/api/users.js"

# ── (b) REINVENTION: redefine formatUser locally, never call the existing one ─
cat > "$REPO/api/dup.js" <<'EOF'
// reinvents an existing capability: re-implements formatUser instead of importing
// the one in utils/format.js. No call to the pre-existing symbol.
export function formatUser(user) {
  return user.first + " " + user.last;
}
EOF
REC_B="$(emit_for reinvent-b)"
if jq -e '.units_reinventing >= 1 and (.suspected_duplicates | map(.duplicates) | index("formatUser"))' "$REC_B" >/dev/null; then
  ok "(b) re-implementing formatUser counts as reinventing + suspected_duplicate"
else
  bad "(b) reinvention/suspected_duplicate not detected"; jq . "$REC_B" 2>/dev/null || cat "$REC_B"
fi
rm -f "$REPO/api/dup.js"

# ── (c) JSON record is well-formed with all required fields ───────────────────
cat > "$REPO/api/mix.js" <<'EOF'
import { getUser } from "../db/client.js";
export function reuseOne(id) { return getUser(id); }      // reuses getUser
export function slugify(s) { return s.toLowerCase(); }     // reinvents existing slugify
export function brandNew(a, b) { return a * b + 7; }       // genuinely novel
EOF
REC_C="$(emit_for shape-c)"
REQUIRED='["task","units_total","units_reusing","units_reinventing","reuse_pct","reused_symbols","suspected_duplicates"]'
if jq -e --argjson req "$REQUIRED" '. as $r | ($req | all(. as $k | ($r | has($k))))' "$REC_C" >/dev/null \
   && jq -e . "$REC_C" >/dev/null; then
  ok "(c) JSON record is well-formed (jq -e .) with all required fields"
else
  bad "(c) JSON record missing required fields or malformed"; cat "$REC_C"
fi

# ── (d) reuse_pct computed correctly on a known mix ───────────────────────────
# mix.js: 3 units — reuseOne (reuses getUser), slugify (reinvents), brandNew (novel).
# Expected: units_total=3, units_reusing=1, reuse_pct=0.3333, units_reinventing=1.
GOT_TOTAL="$(jq -r '.units_total' "$REC_C")"
GOT_REUSE="$(jq -r '.units_reusing' "$REC_C")"
GOT_PCT="$(jq -r '.reuse_pct' "$REC_C")"
GOT_REINV="$(jq -r '.units_reinventing' "$REC_C")"
EXPECT_PCT="$("$PY" -c 'print(round(1/3,4))')"
if [ "$GOT_TOTAL" = "3" ] && [ "$GOT_REUSE" = "1" ] && [ "$GOT_REINV" = "1" ] && [ "$GOT_PCT" = "$EXPECT_PCT" ]; then
  ok "(d) reuse_pct correct on known mix: $GOT_REUSE/$GOT_TOTAL = $GOT_PCT (reinventing=$GOT_REINV)"
else
  bad "(d) reuse_pct wrong: total=$GOT_TOTAL reusing=$GOT_REUSE pct=$GOT_PCT (expected 3/1/$EXPECT_PCT) reinv=$GOT_REINV"
  cat "$REC_C"
fi
rm -f "$REPO/api/mix.js"

# ── (e) degraded safety: unsupported language => null pct, exit 0, honest reason
cat > "$REPO/api/thing.rb" <<'EOF'
def format_user(u)
  "#{u[:first]} #{u[:last]}"
end
EOF
set +e
"$METRIC" --repo "$REPO" --base "$BASE" --task unsupported-e --run-id unsupported-e --quiet >/dev/null
RC=$?
set -e
REC_E="$REPO/.planning/reuse/unsupported-e.json"
if [ "$RC" -eq 0 ] && jq -e '.reuse_pct == null and (.reason | test("unsupported|no-code"))' "$REC_E" >/dev/null; then
  ok "(e) unsupported language degrades to null pct (exit 0, honest reason)"
else
  bad "(e) unsupported-language handling wrong (rc=$RC)"; cat "$REC_E" 2>/dev/null
fi
rm -f "$REPO/api/thing.rb"

# ── (f) Python + shell coverage: a py unit calling an existing py symbol ──────
mkdir -p "$REPO/pylib"
cat > "$REPO/pylib/core.py" <<'EOF'
def normalize(s):
    return s.strip().lower()
EOF
git -C "$REPO" add -A; git -C "$REPO" commit -qm "add pylib/core" >/dev/null
BASE2="$(git -C "$REPO" rev-parse HEAD)"
cat > "$REPO/pylib/use.py" <<'EOF'
from pylib.core import normalize

def handle(value):
    return normalize(value) + "!"
EOF
"$METRIC" --repo "$REPO" --base "$BASE2" --task py-f --run-id py-f --quiet >/dev/null
REC_F="$REPO/.planning/reuse/py-f.json"
if jq -e '.units_reusing >= 1 and (.languages | index("py"))' "$REC_F" >/dev/null; then
  ok "(f) Python unit calling existing normalize counts as reusing"
else
  bad "(f) Python reuse not detected"; cat "$REC_F"
fi

# ── (g) DIFF-SCOPE regression (S-6 C3 Defect 3) ───────────────────────────────
# THE BUG: reuse was measured against a WHOLE-REPO symbol table that swept the
# repo's own test fixtures. A task that changed ONE production function whose body
# happened to call generic names (check_id, dataset) that ALSO exist as TEST
# FIXTURES got those fixture names credited as "reused repo symbols" — when the
# only real pre-existing symbol the unit reuses is the production helper.
#
# This builds a repo with a LARGE existing codebase + a test file packed with
# fixtures (Cheese, check_id, _reduce_datetimes, dataset, normalize_record), then
# changes ONE production function that calls ONE existing production helper plus
# the generic names. The fix must:
#   - count exactly ONE changed unit (units_total=1) — the production function,
#     not any of the repo's existing test fixtures,
#   - put ONLY the production helper in reused_symbols,
#   - NEVER surface Cheese / check_id / _reduce_datetimes / dataset (test-fixture
#     symbols are not pre-existing *repo* code that production should reuse).
DSREPO="$WORK/dsrepo"
mkdir -p "$DSREPO/src" "$DSREPO/tests"
git -C "$DSREPO" init -q
git -C "$DSREPO" config user.email "test@runheimdall.dev"
git -C "$DSREPO" config user.name "reuse-diffscope"

# real production helper the task legitimately reuses
cat > "$DSREPO/src/helpers.py" <<'PYEOF'
def normalize_record(rec):
    return {k.lower(): v for k, v in rec.items()}

def archive(rec):
    return dict(rec)
PYEOF
# a LARGE test file full of FIXTURE names (the exact ones the bug leaked)
cat > "$DSREPO/tests/test_records.py" <<'PYEOF'
class Cheese:
    name = "gouda"
def check_id(x):
    return x
def _reduce_datetimes(row):
    return row
def dataset():
    return []
def normalize_record(rec):
    return rec
PYEOF
git -C "$DSREPO" add -A
git -C "$DSREPO" commit -qm "base: production helpers + a fat test-fixture file" >/dev/null
DSBASE="$(git -C "$DSREPO" rev-parse HEAD)"

# TASK: change ONE production function. It reuses the production helper
# normalize_record and also calls generic names that COLLIDE with test fixtures.
cat > "$DSREPO/src/records.py" <<'PYEOF'
from src.helpers import normalize_record

def build_record(raw):
    rid = check_id(raw)
    rows = dataset()
    return normalize_record(raw)
PYEOF
"$METRIC" --repo "$DSREPO" --base "$DSBASE" --task diffscope-g --run-id diffscope-g --quiet >/dev/null
REC_G="$DSREPO/.planning/reuse/diffscope-g.json"

# units_total reflects ONLY the changed production unit (not repo fixtures).
G_TOTAL="$(jq -r '.units_total' "$REC_G")"
# reused_symbols must be EXACTLY the production helper — no test-fixture names.
G_HAS_HELPER="$(jq -r '(.reused_symbols | map(.symbol) | index("normalize_record")) != null' "$REC_G")"
G_LEAKS="$(jq -r '
    (.reused_symbols | map(.symbol)) as $s
    | [ "Cheese","check_id","_reduce_datetimes","dataset" ]
      | map(. as $f | ($s | index($f)) != null) | any' "$REC_G")"
if [ "$G_TOTAL" = "1" ] && [ "$G_HAS_HELPER" = "true" ] && [ "$G_LEAKS" = "false" ]; then
  ok "(g) diff-scoped: units_total=1, reused_symbols=[normalize_record] only — no test fixtures leaked"
else
  bad "(g) diff scope leaked: units_total=$G_TOTAL has_helper=$G_HAS_HELPER fixtures_leaked=$G_LEAKS"
  jq '{units_total, reused_symbols}' "$REC_G"
fi

echo
echo "  reuse-metric tests: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
