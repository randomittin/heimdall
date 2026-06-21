#!/usr/bin/env bash
# test/si-2-attest.test.sh — SI-2 commit-time attestation acceptance proof.
#
# SI-2 emits ONE structured record per commit/task — { claims, contracts,
# evidence, reuse, risk } — that every downstream feature (F2 Checker, F3 Redum,
# F4 Collision, F5 Debloat, F6 Team-mode) READS so none re-analyzes the diff.
# This test proves the emitter (bin/heimdall-attest + bin/lib/attestation.py)
# against the REAL interface, on a REAL temp git repo, with NO model spend and
# NO token cost — fully deterministic, CI-free.
#
# Acceptance asserted here:
#   (1) A real diff (an added unit that CALLS an existing repo symbol) emits a
#       record with ALL FIVE fields present and populated.
#   (2) The `reuse` field is the S-6 record: units_total, reuse_pct,
#       reused_symbols, suspected_duplicates, and an `engine` tag (treesitter
#       when available, heuristic on fallback). On the call-existing-symbol diff
#       reuse_pct > 0 and the reused symbol is named.
#   (3) `evidence` is RUNNABLE proof, not self-report: it records real commands
#       with their real exit codes — a passing command (exit 0) and a failing
#       command (exit non-zero) are both faithfully recorded, never a prose claim.
#   (4) `claims` and `contracts` are derived from the diff (claims = what
#       changed; contracts = the touched/added exported symbols). `risk` exists
#       (a derived flag list, possibly empty).
#   (5) Readers API round-trip: emit -> get <id> returns the SAME record, and a
#       commit-sha id is gettable by its short sha.
#   (6) Graceful partial: an unsupported-language diff still emits a record (with
#       an honest reuse_pct=null), exits 0, and never crashes/blocks a commit.
#   (7) Engine agreement: tree-sitter and heuristic reach the SAME reuse verdict
#       on the call-existing-symbol diff (mirrors reuse-mini-git's substrate-swap
#       guarantee at the attestation layer).
#
# WHY a fixed REFERENCE diff and not a live `hmd "task"`:
#   A live agent run needs a model call (tokens, non-deterministic). SI-2's gated
#   assertion uses a deterministic reference diff so it runs free + repeatably.

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
ATTEST="$ROOT/bin/heimdall-attest"

PASS=0
FAIL=0
ok()  { PASS=$((PASS+1)); printf "  \033[32mPASS\033[0m %s\n" "$1"; }
bad() { FAIL=$((FAIL+1)); printf "  \033[31mFAIL\033[0m %s\n" "$1"; }

command -v jq >/dev/null 2>&1 || { echo "FATAL: jq required for the JSON assertions" >&2; exit 2; }
[ -x "$ATTEST" ] || { echo "FATAL: emitter not executable at $ATTEST" >&2; exit 2; }
PY="$(command -v python3 || command -v python || true)"
[ -n "$PY" ] || { echo "FATAL: python3 required" >&2; exit 2; }

WORK="$(mktemp -d -t "si2-attest.$(printf 'X%.0s' 1 2 3 4 5 6)")"
trap 'rm -rf "$WORK"' EXIT

# ── scaffold a small repo with a pre-existing symbol to reuse ─────────────────
REPO="$WORK/repo"
mkdir -p "$REPO/lib" "$REPO/api"
git -C "$REPO" init -q
git -C "$REPO" config user.email "test@runheimdall.dev"
git -C "$REPO" config user.name "si2-attest"

cat > "$REPO/lib/format.js" <<'EOF'
// pre-existing helper — the capability the change CALLS instead of rewriting.
export function formatUser(user) {
  return user.first + " " + user.last + " <" + user.email + ">";
}
export function validateUser(user) {
  return Boolean(user && user.email);
}
EOF

git -C "$REPO" add -A
git -C "$REPO" commit -qm "base: existing format helpers"
BASE="$(git -C "$REPO" rev-parse HEAD)"

# Keep all attestation records inside the temp repo's gitignored runtime store.
export HEIMDALL_HOME="$REPO/.heimdall"

# the GOOD diff: a new unit that imports + CALLS the pre-existing formatUser.
write_good_diff() {
  cat > "$REPO/api/users.js" <<'EOF'
import { formatUser } from "../lib/format.js";

// reuses the pre-existing formatter instead of re-implementing it.
export function userEndpoint(req, res) {
  res.send(formatUser(req.user));
}
EOF
}

# ─────────────────────────────────────────────────────────────────────────────
# (1)+(2)+(3)+(4) Emit on the call-existing-symbol diff, with runnable evidence.
# ─────────────────────────────────────────────────────────────────────────────
write_good_diff

# Two runnable evidence commands the EMITTER executes: one that PASSES (exit 0)
# and one that FAILS (exit 7). The recorded exits must reflect REAL runs.
"$ATTEST" emit --repo "$REPO" --base "$BASE" --id good \
  --evidence "true" \
  --evidence "bash -c 'exit 7'" \
  --quiet >/dev/null

REC="$("$ATTEST" get good --repo "$REPO")"

# (1) all five fields present + populated.
if printf '%s' "$REC" | jq -e '
    .claims and .contracts and .evidence and .reuse and .risk
    and (.claims.file_count > 0) and (.reuse.units_total > 0)
  ' >/dev/null; then
  ok "(1) record has all five fields (claims, contracts, evidence, reuse, risk) populated"
else
  bad "(1) one of the five fields is missing/empty"; printf '%s' "$REC" | jq '{claims:.claims.file_count, reuse:.reuse.units_total}'
fi

# (2) reuse field matches the S-6 definition: required keys + engine tag.
if printf '%s' "$REC" | jq -e '
    .reuse
    | has("units_total") and has("reuse_pct") and has("reused_symbols")
      and has("suspected_duplicates") and has("engine")
  ' >/dev/null; then
  ok "(2a) reuse carries the S-6 shape (units_total, reuse_pct, reused_symbols, suspected_duplicates, engine)"
else
  bad "(2a) reuse missing an S-6 field"; printf '%s' "$REC" | jq '.reuse | keys'
fi

# engine tag is one of the two valid backends; treesitter when the backend loads.
TS_AVAIL="$("$PY" -c "import sys; sys.path.insert(0,'$ROOT/bin/lib'); import reuse_analyzer as r; m=r._ts_module(); print('yes' if (m is not None and getattr(m,'backend_available',lambda:False)()) else 'no')")"
ENGINE="$(printf '%s' "$REC" | jq -r '.reuse.engine')"
if [ "$TS_AVAIL" = "yes" ]; then
  if [ "$ENGINE" = "treesitter" ]; then
    ok "(2b) reuse engine=treesitter (AST backend available + used)"
  else
    bad "(2b) tree-sitter backend available but engine=$ENGINE (expected treesitter)"
  fi
else
  if [ "$ENGINE" = "heuristic" ]; then
    ok "(2b) reuse engine=heuristic (AST backend unavailable, honest fallback)"
  else
    bad "(2b) tree-sitter unavailable but engine=$ENGINE (expected heuristic)"
  fi
fi

# reuse_pct > 0 and formatUser named in reused_symbols on the call-existing diff.
if printf '%s' "$REC" | jq -e '
    (.reuse.reuse_pct > 0)
    and ((.reuse.reused_symbols | map(.symbol)) | index("formatUser"))
  ' >/dev/null; then
  GP="$(printf '%s' "$REC" | jq -r '.reuse.reuse_pct')"
  ok "(2c) reuse_pct=$GP > 0 and the reused symbol formatUser is named"
else
  bad "(2c) expected reuse_pct>0 with formatUser in reused_symbols"; printf '%s' "$REC" | jq '{pct:.reuse.reuse_pct, reused:.reuse.reused_symbols}'
fi

# (3) evidence is runnable proof: real exit codes, not a prose claim.
if printf '%s' "$REC" | jq -e '
    (.evidence.ran == 2)
    and (.evidence.all_passed == false)
    and ([.evidence.checks[] | select(.cmd == "true") | .exit] == [0])
    and ([.evidence.checks[] | select(.cmd | test("exit 7")) | .exit] == [7])
    and (.evidence.checks | all(has("exit") and has("ok")))
  ' >/dev/null; then
  ok "(3a) evidence records REAL exit codes (true->0, exit-7->7), all_passed=false — runnable, not self-report"
else
  bad "(3a) evidence did not record real exit codes"; printf '%s' "$REC" | jq '.evidence'
fi

# evidence carries an exit-coded result, NOT a free-text pass/fail assertion: each
# check has a numeric `exit` and a boolean `ok` derived from it (ok == exit==0).
if printf '%s' "$REC" | jq -e '
    .evidence.checks
    | all((.exit | type == "number") and (.ok == (.exit == 0)))
  ' >/dev/null; then
  ok "(3b) every evidence check is exit-coded (numeric exit, ok derived from it) — no prose claims"
else
  bad "(3b) an evidence check is not exit-coded"; printf '%s' "$REC" | jq '.evidence.checks'
fi

# (4) claims + contracts derived from the diff; risk present.
if printf '%s' "$REC" | jq -e '
    ((.claims.files | map(.path)) | index("api/users.js"))
    and ((.claims.files[] | select(.path=="api/users.js") | .units) | index("userEndpoint"))
    and (.claims.files[] | select(.path=="api/users.js") | .status == "A")
  ' >/dev/null; then
  ok "(4a) claims derived from diff: api/users.js added (status A) introducing unit userEndpoint"
else
  bad "(4a) claims do not reflect the diff"; printf '%s' "$REC" | jq '.claims'
fi

if printf '%s' "$REC" | jq -e '
    (.contracts.surface | map(.name)) | index("userEndpoint")
  ' >/dev/null; then
  ok "(4b) contracts surface the added exported symbol userEndpoint"
else
  bad "(4b) contracts missing the exported symbol userEndpoint"; printf '%s' "$REC" | jq '.contracts'
fi

# risk present as a field; may be empty-flagged but must have an overall + flags list.
if printf '%s' "$REC" | jq -e '
    (.risk | has("overall")) and (.risk.flags | type == "array")
  ' >/dev/null; then
  ok "(4c) risk present (overall=$(printf '%s' "$REC" | jq -r '.risk.overall'), flags is a list)"
else
  bad "(4c) risk field malformed"; printf '%s' "$REC" | jq '.risk'
fi

# ─────────────────────────────────────────────────────────────────────────────
# (5) Readers API round-trip: emit -> get returns the SAME record; commit id
#     gettable by short sha.
# ─────────────────────────────────────────────────────────────────────────────
# 5a: emit -> get -> same bytes (idempotent reader over the same id).
REC2="$("$ATTEST" get good --repo "$REPO")"
if [ "$REC" = "$REC2" ]; then
  ok "(5a) readers round-trip: get good returns the identical emitted record"
else
  bad "(5a) get returned a different record than emit wrote"
fi

# 5b: a committed change attests under its commit sha and is gettable by short sha.
git -C "$REPO" add -A
git -C "$REPO" commit -qm "feat: add userEndpoint reusing formatUser"
AFTER="$(git -C "$REPO" rev-parse HEAD)"
ASHORT="$(git -C "$REPO" rev-parse --short HEAD)"
"$ATTEST" emit --repo "$REPO" --range "$BASE..$AFTER" --evidence "true" --quiet >/dev/null
if "$ATTEST" get "$ASHORT" --repo "$REPO" >/dev/null 2>&1; then
  COMMIT_FIELD="$("$ATTEST" get "$ASHORT" --repo "$REPO" | jq -r '.commit')"
  if [ "$COMMIT_FIELD" = "$ASHORT" ]; then
    ok "(5b) commit-sha record gettable by short sha ($ASHORT) and self-identifies it"
  else
    bad "(5b) record for $ASHORT reports commit=$COMMIT_FIELD"
  fi
else
  bad "(5b) could not get the commit-sha record by short sha $ASHORT"
fi

# 5c: list surfaces the stored ids.
if "$ATTEST" list --repo "$REPO" | grep -qx "good" && "$ATTEST" list --repo "$REPO" | grep -qx "$ASHORT"; then
  ok "(5c) list surfaces the stored attestation ids (good + $ASHORT)"
else
  bad "(5c) list did not surface the stored ids"; "$ATTEST" list --repo "$REPO"
fi

# reset the working tree for the partial-diff case (api/users.js is now committed).
git -C "$REPO" checkout -q -- . 2>/dev/null || true

# ─────────────────────────────────────────────────────────────────────────────
# (6) Graceful partial: an unsupported-language diff still emits an honest
#     record (reuse_pct=null), exits 0, never crashes/blocks.
# ─────────────────────────────────────────────────────────────────────────────
PREPO="$WORK/prepo"
mkdir -p "$PREPO"
git -C "$PREPO" init -q
git -C "$PREPO" config user.email "test@runheimdall.dev"
git -C "$PREPO" config user.name "si2-attest"
echo "seed" > "$PREPO/seed.txt"
git -C "$PREPO" add -A
git -C "$PREPO" commit -qm "base"
PBASE="$(git -C "$PREPO" rev-parse HEAD)"
# a language the reuse analyzer does not support (.rs) — has an extension so it is
# NOT treated as a no-extension script; reuse must degrade to null, not crash.
cat > "$PREPO/thing.rs" <<'EOF'
fn main() {
    println!("unsupported by the reuse substrate");
}
EOF

set +e
HEIMDALL_HOME="$PREPO/.heimdall" "$ATTEST" emit --repo "$PREPO" --base "$PBASE" --id partial --quiet >/dev/null 2>&1
PRC=$?
set -e
if [ "$PRC" -eq 0 ]; then
  ok "(6a) emit on an unsupported-language diff exits 0 (never blocks a commit)"
else
  bad "(6a) emit exited $PRC on an unsupported-language diff (must be 0)"
fi

PREC="$(HEIMDALL_HOME="$PREPO/.heimdall" "$ATTEST" get partial --repo "$PREPO")"
if printf '%s' "$PREC" | jq -e '
    .claims and .contracts and .evidence and .reuse and .risk
    and (.reuse.reuse_pct == null)
  ' >/dev/null; then
  ok "(6b) partial record still has all five fields with an HONEST reuse_pct=null (not a fabricated number)"
else
  bad "(6b) partial record malformed or reuse_pct not null"; printf '%s' "$PREC" | jq '{reuse_pct:.reuse.reuse_pct, reason:.reuse.reason}'
fi

# ─────────────────────────────────────────────────────────────────────────────
# (7) Engine agreement at the attestation layer: tree-sitter and heuristic reach
#     the SAME reuse verdict on the call-existing-symbol diff (formatUser reused,
#     reuse_pct > 0 under both). Mirrors reuse-mini-git's substrate-swap proof.
# ─────────────────────────────────────────────────────────────────────────────
verdict_under() {
  # $1 engine -> echoes "yes" if the good diff classifies as reuse-of-formatUser.
  local eng="$1" rec
  write_good_diff
  "$ATTEST" emit --repo "$REPO" --base "$BASE" --id "agree-$eng" \
    --engine "$eng" --evidence "true" --quiet >/dev/null
  rec="$("$ATTEST" get "agree-$eng" --repo "$REPO")"
  printf '%s' "$rec" | jq -r '
    (((.reuse.reused_symbols | map(.symbol)) | index("formatUser"))
     and (.reuse.reuse_pct > 0)) // false
    | if . then "yes" else "no" end'
  git -C "$REPO" checkout -q -- . 2>/dev/null || true
  git -C "$REPO" clean -fdq -- api 2>/dev/null || true
  mkdir -p "$REPO/api"
}

V_TS="$(verdict_under treesitter)"
V_HE="$(verdict_under heuristic)"
if [ "$V_TS" = "yes" ] && [ "$V_HE" = "yes" ]; then
  ok "(7) AST + heuristic AGREE: the diff classifies as reuse-of-formatUser under both engines"
else
  bad "(7) engines disagree (treesitter=$V_TS heuristic=$V_HE)"
fi

echo
echo "  si-2-attest acceptance: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
