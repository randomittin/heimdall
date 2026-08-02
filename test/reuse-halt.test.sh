#!/usr/bin/env bash
# test/reuse-halt.test.sh — S-6 C4 acceptance: the halt-if-low-reuse rule.
#
# Proves the REAL `check_reuse_halt` function shipped in bin/heimdall fires and
# fails-open correctly. We do NOT run a live `hmd "task"` (that needs a model
# call); instead we EXTRACT the exact `check_reuse_halt` function definition from
# bin/heimdall and drive it against REAL reuse records produced by the real
# bin/heimdall-reuse-metric over a real temp git repo. This is the same controlled
# mini-repo C2 uses (good vs reinvention reference diffs), so the fire / no-fire
# cases are grounded in measured reuse, never canned.
#
# C4 acceptance proven here:
#   (1) FIRES (rc 7 + signal) on a reuse-HOSTILE run (reuse < 0.30: the C2
#       reinvention diff), naming the suspected_duplicates.
#   (2) does NOT fire on the reuse-FRIENDLY run (>= 0.60: the C2 good diff).
#   (3) does NOT fire when reuse_pct == null (unsupported language) — no signal is
#       not a low-reuse signal.
#   (4) does NOT fire on a degraded analyzer record (fail-open on metric error).
#   (5) --force / HEIMDALL_FORCE=1 overrides a genuine low-reuse fire.
#   (6) HEIMDALL_NO_REUSE_METRIC=1 disables the check entirely.

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
HEIMDALL="$ROOT/bin/heimdall"
METRIC="$ROOT/bin/heimdall-reuse-metric"

PASS=0
FAIL=0
ok()  { PASS=$((PASS+1)); printf "  \033[32mPASS\033[0m %s\n" "$1"; }
bad() { FAIL=$((FAIL+1)); printf "  \033[31mFAIL\033[0m %s\n" "$1"; }

command -v jq >/dev/null 2>&1 || { echo "FATAL: jq required" >&2; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "FATAL: python3 required" >&2; exit 2; }
[ -x "$HEIMDALL" ] || { echo "FATAL: bin/heimdall not executable" >&2; exit 2; }
[ -x "$METRIC" ]   || { echo "FATAL: bin/heimdall-reuse-metric not executable" >&2; exit 2; }

WORK="$(mktemp -d -t "reuse-halt.$(printf 'X%.0s' 1 2 3 4 5 6)")"
trap 'rm -rf "$WORK"' EXIT

# ── extract the REAL check_reuse_halt (+ its threshold default) from bin/heimdall
# We source the exact shipped definition so this test exercises production code,
# not a copy. The block is `REUSE_HALT_THRESHOLD=...` through the function's body.
FUNC_SRC="$WORK/check_reuse_halt.sh"
awk '
  /^REUSE_HALT_THRESHOLD=/ { capture=1 }
  capture { print }
  capture && /^}/ && seen_open { capture=0 }
  capture && /^check_reuse_halt\(\) \{/ { seen_open=1 }
' "$HEIMDALL" > "$FUNC_SRC"

# sanity: the extraction must contain the function definition + its return paths.
if ! grep -q '^check_reuse_halt() {' "$FUNC_SRC" || ! grep -q 'return 7' "$FUNC_SRC"; then
  echo "FATAL: failed to extract check_reuse_halt from $HEIMDALL" >&2
  echo "---extracted---" >&2; cat "$FUNC_SRC" >&2
  exit 2
fi

# ── build the same controlled mini-repo C2 uses ───────────────────────────────
REPO="$WORK/repo"
mkdir -p "$REPO/utils" "$REPO/db" "$REPO/models" "$REPO/api"
git -C "$REPO" init -q
git -C "$REPO" config user.email "test@runheimdall.dev"
git -C "$REPO" config user.name "reuse-halt"

cat > "$REPO/utils/format.js" <<'EOF'
export function formatUser(user) {
  return user.first + " " + user.last + " <" + user.email + ">";
}
export function validateUser(user) {
  return Boolean(user && user.email);
}
export function serializeUser(user) {
  return JSON.stringify({ name: user.first + " " + user.last });
}
EOF
cat > "$REPO/db/client.js" <<'EOF'
export const db = {
  rows: { 1: { id: 1, first: "Ada", last: "Lovelace", email: "ada@x.io" } },
};
export function getUser(id) {
  return db.rows[id];
}
EOF
cat > "$REPO/models/user.js" <<'EOF'
export class User {
  constructor(row) {
    this.first = row.first;
    this.last = row.last;
    this.email = row.email;
  }
}
EOF
git -C "$REPO" add -A
git -C "$REPO" commit -qm "base: existing format helper, db client, User model"
BASE="$(git -C "$REPO" rev-parse HEAD)"

emit() {
  # $1 run-id ; echoes the record path. Real metric over working tree vs BASE.
  local rid="$1"
  "$METRIC" --repo "$REPO" --base "$BASE" --task "$rid" --run-id "$rid" --quiet >/dev/null
  echo "$REPO/.planning/reuse/$rid.json"
}
reset_tree() {
  git -C "$REPO" checkout -q -- . 2>/dev/null || true
  git -C "$REPO" clean -fdq -- api 2>/dev/null || true
  mkdir -p "$REPO/api"   # clean removes the untracked api/ dir; re-create it.
}

# run_halt RECORD FORCE NOMETRIC -> echoes the rc, captures stderr to $LAST_ERR.
# Drives the EXTRACTED real check_reuse_halt in a clean subshell with the inputs
# the production caller sets (REUSE_RECORD, REUSE_FORCE, HEIMDALL_NO_REUSE_METRIC).
LAST_ERR="$WORK/last.err"
run_halt() {
  local rec="$1" force="$2" nometric="$3" rc
  (
    set +e
    REUSE_FORCE="$force"
    HEIMDALL_NO_REUSE_METRIC="$nometric"
    REUSE_RECORD="$rec"
    # shellcheck disable=SC1090
    . "$FUNC_SRC"
    check_reuse_halt
    exit $?
  ) 2>"$LAST_ERR"
  rc=$?
  echo "$rc"
}

# ── good (reuse-friendly) reference diff: every unit reuses pre-existing code ──
cat > "$REPO/api/users.js" <<'EOF'
import { getUser } from "../db/client.js";
import { formatUser } from "../utils/format.js";
import { User } from "../models/user.js";
export function loadUser(id) { return getUser(id); }
export function toUserModel(row) { return new User(row); }
export function userEndpoint(req, res) {
  const model = toUserModel(loadUser(req.params.id));
  res.send(formatUser(model));
}
EOF
REC_GOOD="$(emit good)"
GOOD_PCT="$(jq -r '.reuse_pct' "$REC_GOOD")"
reset_tree

# ── reinvention (reuse-hostile) reference diff: reimplements the helpers inline ─
# Four duplicated capabilities + one consumer => 1/5 = 0.20 reuse (< 0.30 floor).
# See test/reuse-mini-git.test.sh for why the consumer is credited as the lone reuse.
cat > "$REPO/api/users.js" <<'EOF'
export function formatUser(user) { return user.first + " " + user.last; }
export function getUser(id) {
  const rows = { 1: { id: 1, first: "Ada", last: "Lovelace" } };
  return rows[id];
}
export function validateUser(user) { return user != null && user.email != null; }
export function serializeUser(user) { return JSON.stringify({ name: user.first }); }
export function userEndpoint(req, res) {
  const u = getUser(req.params.id);
  res.send(formatUser(u));
}
EOF
REC_REINV="$(emit reinvent)"
REINV_PCT="$(jq -r '.reuse_pct' "$REC_REINV")"
reset_tree

# ── null-pct record: only an unsupported-language file changed ────────────────
cat > "$REPO/api/thing.rb" <<'EOF'
def format_user(u)
  "#{u[:first]} #{u[:last]}"
end
EOF
REC_NULL="$(emit nulllang)"
NULL_PCT="$(jq -r '.reuse_pct' "$REC_NULL")"
rm -f "$REPO/api/thing.rb"

# ── degraded record: hand-craft an analyzer-error record (fail-open case) ──────
REC_DEGRADED="$REPO/.planning/reuse/degraded.json"
cat > "$REC_DEGRADED" <<'EOF'
{
  "task": "broken-analysis",
  "units_total": 0,
  "units_reusing": 0,
  "units_reinventing": 0,
  "reuse_pct": null,
  "reused_symbols": [],
  "suspected_duplicates": [],
  "degraded": true,
  "reason": "analyzer-error-rc-1"
}
EOF

echo "C4 halt-if-low-reuse:"
echo "    measured: good=$GOOD_PCT  reinvent=$REINV_PCT  null=$NULL_PCT"

# (1) FIRES on the reuse-hostile run (rc 7) and names the duplicates.
RC="$(run_halt "$REC_REINV" 0 0)"
if [ "$RC" -eq 7 ] && grep -q "Low reuse" "$LAST_ERR" && grep -Eq "formatUser|getUser" "$LAST_ERR"; then
  ok "(1) halt FIRES on reuse-hostile run (rc 7, names suspected_duplicates)"
else
  bad "(1) expected rc 7 + signal on reinvention (got rc=$RC)"; cat "$LAST_ERR"
fi

# (2) does NOT fire on the reuse-friendly run.
RC="$(run_halt "$REC_GOOD" 0 0)"
if [ "$RC" -eq 0 ]; then
  ok "(2) halt does NOT fire on reuse-friendly run (rc 0, reuse=$GOOD_PCT)"
else
  bad "(2) halt fired on the friendly run (rc=$RC, reuse=$GOOD_PCT)"; cat "$LAST_ERR"
fi

# (3) does NOT fire when reuse_pct == null (unsupported language).
if [ "$NULL_PCT" = "null" ]; then
  RC="$(run_halt "$REC_NULL" 0 0)"
  if [ "$RC" -eq 0 ]; then
    ok "(3) halt does NOT fire on reuse_pct=null (no signal != low reuse)"
  else
    bad "(3) halt fired on a null-pct record (rc=$RC)"; cat "$LAST_ERR"
  fi
else
  bad "(3) expected reuse_pct=null for the unsupported-language record (got $NULL_PCT)"
fi

# (4) does NOT fire on a degraded analyzer record (fail-open on metric error).
RC="$(run_halt "$REC_DEGRADED" 0 0)"
if [ "$RC" -eq 0 ]; then
  ok "(4) halt does NOT fire on a degraded record (fail-open on analyzer error)"
else
  bad "(4) halt fired on a degraded record (rc=$RC)"; cat "$LAST_ERR"
fi

# (5) --force / HEIMDALL_FORCE overrides a genuine low-reuse fire.
RC="$(run_halt "$REC_REINV" 1 0)"
if [ "$RC" -eq 0 ]; then
  ok "(5) --force / HEIMDALL_FORCE overrides the low-reuse fire (rc 0)"
else
  bad "(5) --force did not override the fire (rc=$RC)"; cat "$LAST_ERR"
fi

# (6) HEIMDALL_NO_REUSE_METRIC=1 disables the check entirely.
RC="$(run_halt "$REC_REINV" 0 1)"
if [ "$RC" -eq 0 ]; then
  ok "(6) HEIMDALL_NO_REUSE_METRIC=1 disables the check (rc 0)"
else
  bad "(6) check ran despite HEIMDALL_NO_REUSE_METRIC=1 (rc=$RC)"; cat "$LAST_ERR"
fi

# (7) a missing/empty record => fail-open (no record to measure).
RC="$(run_halt "" 0 0)"
if [ "$RC" -eq 0 ]; then
  ok "(7) empty record path => fail-open (rc 0)"
else
  bad "(7) fired with no record (rc=$RC)"; cat "$LAST_ERR"
fi

echo
echo "  reuse-halt (C4): $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
