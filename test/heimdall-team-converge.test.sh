#!/usr/bin/env bash
# heimdall-team-converge.test.sh — HERMETIC gate for the converge-forward migration tool
# (bin/heimdall-team-converge, TEAM-FIX-PLAN.md §4 / §6-Wave-3). No network, no prod CP, no live
# creds — a temp HEIMDALL_HOME seeded with a SPLIT repo drives the LOCAL state backend only.
#
# THE FIXTURE (the split the tool must heal):
#   * one repo_slug `randomittin/rally` (presence project github.com/randomittin/rally) split
#     across TWO team_ids — 3 registered HAIDs: haid1+haid2 on teamA, haid3 on teamB, with
#     enrolled_at stamps so teamA (earliest) is the canonical elected when NO repo->team binding
#     exists (exercises the earliest-enrolled_at election + bind_repo_team CAS + bind_haid_to_team).
#   * a NON-GITHUB (truly-local) project `localonly-tool` with its own HAID — repo_slug is None,
#     so the tool must LEAVE IT ALONE (its team_id never moves).
#   * a HAID present in the presence tree but ABSENT from the key registry — it cannot be
#     re-pointed (bind_haid_to_team fail-closes on no pubkey), so it must be SKIPPED, never crash.
#
# PROOFS (exit 0 = all hold):
#   1. CONVERGE   — after `heimdall-team-converge`, all 3 rally HAIDs point to ONE canonical team.
#   2. IDEMPOTENT — a second run is a no-op: keys.json AND the ledger are byte-unchanged.
#   3. DRY-RUN    — `--dry-run` writes NOTHING (the whole HEIMDALL_HOME tree digest is unchanged)
#                   and leaves the split intact.
#   4. NON-GITHUB — the truly-local project's HAID keeps its original team_id (left alone).
#   5. REGISTRY-MISSING — the tree-only HAID is skipped; the tool exits 0 (no crash).

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SELF_DIR/.." && pwd)"
LIB="$REPO/bin/lib"
CONVERGE_CLI="$REPO/bin/heimdall-team-converge"
export LIB REPO

for f in cp_auth cp_presence cp_repoteam cp_state; do
  [ -f "$LIB/$f.py" ] || { echo "FATAL: $LIB/$f.py missing" >&2; exit 2; }
done
[ -x "$CONVERGE_CLI" ] || { echo "FATAL: $CONVERGE_CLI not executable" >&2; exit 2; }

PY="$(command -v python3 || command -v python || true)"
[ -n "$PY" ] || { echo "FATAL: python not found" >&2; exit 2; }

PASS=0
FAIL=0
ok()  { PASS=$((PASS+1)); printf "  \033[32mPASS\033[0m %s\n" "$1"; }
bad() { FAIL=$((FAIL+1)); printf "  \033[31mFAIL\033[0m %s\n" "$1"; }

EXT="$(mktemp -d -t "hmd-team-converge.XXXXXX")"
export HEIMDALL_HOME="$EXT/home"
mkdir -p "$HEIMDALL_HOME"
cleanup() { rm -rf "$EXT"; }
trap cleanup EXIT

# Fixed identifiers used by the seed AND the assertions (32-hex team ids; haid:human.machine-hash4).
TEAM_A="aaaa0000aaaa0000aaaa0000aaaa0000"
TEAM_B="bbbb1111bbbb1111bbbb1111bbbb1111"
TEAM_L="cccc2222cccc2222cccc2222cccc2222"
PROJECT="github.com/randomittin/rally"
LOCAL_PROJECT="localonly-tool"
HAID1="haid:alice.mba-0a0a"
HAID2="haid:bob.mbp-0b0b"
HAID3="haid:carol.linux-0c0c"
HAID4="haid:dave.local-0d0d"          # non-github project member (must be left alone)
HAID_MISSING="haid:ghost.void-0e0e"   # in the tree, NOT in the registry (must be skipped)
export TEAM_A TEAM_B TEAM_L PROJECT LOCAL_PROJECT HAID1 HAID2 HAID3 HAID4 HAID_MISSING

# ── seed the LOCAL backend: registry bindings + durable presence records ────────────────────────
"$PY" - <<'PY' || { echo "FATAL: seed failed" >&2; exit 2; }
import os, sys
sys.path.insert(0, os.environ["LIB"])
import cp_auth, cp_presence, cp_state

home = os.environ["HEIMDALL_HOME"]
backend = cp_state.get_backend(home=home)
PK = "QUJDREVGR0hJSktMTU5PUFFSU1RVVldYWVowMTIzNDU2Nzg5"  # dummy but truthy base64 pubkey

# key-registry bindings (raw haid keyed) with enrolled_at stamps: teamA earliest -> canonical.
def reg(haid, team, enrolled):
    assert cp_auth.register_key(haid, PK, team_id=team, enrolled_at=enrolled, home=home)

reg(os.environ["HAID1"], os.environ["TEAM_A"], 1000)
reg(os.environ["HAID2"], os.environ["TEAM_A"], 1500)
reg(os.environ["HAID3"], os.environ["TEAM_B"], 2000)
reg(os.environ["HAID4"], os.environ["TEAM_L"], 1200)   # non-github member
# HAID_MISSING is DELIBERATELY not registered.

# durable presence records at presence/<project>/<team_id>/<haid>.json (the grouping source).
def pres(project, team, haid):
    rec = cp_presence.build_record(haid, project=project, handle="h")
    assert backend.put_record(cp_presence._record_rel(project, team, haid), rec)

pres(os.environ["PROJECT"], os.environ["TEAM_A"], os.environ["HAID1"])
pres(os.environ["PROJECT"], os.environ["TEAM_A"], os.environ["HAID2"])
pres(os.environ["PROJECT"], os.environ["TEAM_B"], os.environ["HAID3"])
pres(os.environ["PROJECT"], os.environ["TEAM_B"], os.environ["HAID_MISSING"])  # tree-only
pres(os.environ["LOCAL_PROJECT"], os.environ["TEAM_L"], os.environ["HAID4"])   # non-github
print("seeded")
PY

# helper: the RAW stored team_id for a haid (None-safe), via the SAME accessor the tool re-points.
team_of() {
  "$PY" - "$1" <<'PY'
import os, sys
sys.path.insert(0, os.environ["LIB"])
import cp_auth
print(cp_auth.registered_team_field(sys.argv[1], os.environ["HEIMDALL_HOME"]) or "")
PY
}

# helper: a stable digest of the WHOLE HEIMDALL_HOME tree (path+size+sha) — the dry-run zero-write proof.
tree_digest() {
  "$PY" - <<'PY'
import hashlib, os
root = os.environ["HEIMDALL_HOME"]
h = hashlib.sha256()
for dp, _, fns in sorted(os.walk(root)):
    for fn in sorted(fns):
        p = os.path.join(dp, fn)
        rel = os.path.relpath(p, root)
        with open(p, "rb") as fh:
            data = fh.read()
        h.update(rel.encode()); h.update(b"\0"); h.update(hashlib.sha256(data).digest())
print(h.hexdigest())
PY
}

echo "heimdall-team-converge — hermetic converge/idempotency/dry-run gate"

# sanity: the fixture really is SPLIT before we start.
[ "$(team_of "$HAID1")" = "$TEAM_A" ] && [ "$(team_of "$HAID3")" = "$TEAM_B" ] \
  && ok "fixture is split (haid1=teamA, haid3=teamB)" \
  || bad "fixture did not seed a split"

# ── PROOF 3: --dry-run writes NOTHING (tree digest unchanged) and leaves the split intact ────────
BEFORE_DIGEST="$(tree_digest)"
"$CONVERGE_CLI" --dry-run >"$EXT/dryrun.out" 2>&1
DRY_RC=$?
AFTER_DIGEST="$(tree_digest)"
if [ "$DRY_RC" -eq 0 ] && [ "$BEFORE_DIGEST" = "$AFTER_DIGEST" ]; then
  ok "--dry-run wrote NOTHING (HEIMDALL_HOME tree digest unchanged)"
else
  bad "--dry-run mutated state (rc=$DRY_RC) or tree digest changed"
fi
if grep -q "randomittin/rally" "$EXT/dryrun.out"; then
  ok "--dry-run printed a per-slug plan for randomittin/rally"
else
  bad "--dry-run did not print the rally plan"; cat "$EXT/dryrun.out"
fi
# the split must still be intact after a dry-run (no re-point happened).
[ "$(team_of "$HAID3")" = "$TEAM_B" ] \
  && ok "--dry-run left the split intact (haid3 still teamB)" \
  || bad "--dry-run re-pointed a HAID (must not write)"

# ── EXECUTE the migration ────────────────────────────────────────────────────────────────────────
"$CONVERGE_CLI" >"$EXT/run1.out" 2>&1
RUN1_RC=$?
[ "$RUN1_RC" -eq 0 ] && ok "converge run exited 0" || { bad "converge run exited $RUN1_RC"; cat "$EXT/run1.out"; }

# ── PROOF 1: all 3 rally HAIDs converged onto ONE canonical team (teamA, the earliest-enrolled) ──
C1="$(team_of "$HAID1")"; C2="$(team_of "$HAID2")"; C3="$(team_of "$HAID3")"
if [ -n "$C1" ] && [ "$C1" = "$C2" ] && [ "$C2" = "$C3" ]; then
  ok "all 3 rally HAIDs point to ONE team ($C1)"
else
  bad "rally HAIDs did NOT converge (haid1=$C1 haid2=$C2 haid3=$C3)"
fi
[ "$C1" = "$TEAM_A" ] \
  && ok "canonical is the earliest-enrolled team (teamA)" \
  || bad "canonical was $C1, expected earliest-enrolled teamA"

# the /team/auto repo->team binding was written by bind_repo_team (CAS) at the canonical.
BOUND="$("$PY" - <<'PY'
import os, sys
sys.path.insert(0, os.environ["LIB"])
import cp_repoteam
print(cp_repoteam.get_team_for_repo("randomittin/rally", home=os.environ["HEIMDALL_HOME"]) or "")
PY
)"
[ "$BOUND" = "$TEAM_A" ] \
  && ok "repo->team binding created at canonical (bind_repo_team CAS)" \
  || bad "repo->team binding is '$BOUND', expected teamA"

# the superseded ledger was written for the slug.
if ls "$HEIMDALL_HOME"/control-plane/migration/team-converge/*.json >/dev/null 2>&1; then
  ok "superseded ledger written under migration/team-converge/"
else
  bad "no ledger record written"
fi

# ── PROOF 4: the non-github (truly-local) project's HAID was LEFT ALONE ──────────────────────────
[ "$(team_of "$HAID4")" = "$TEAM_L" ] \
  && ok "non-github project HAID left alone (haid4 still teamL)" \
  || bad "non-github project HAID was re-pointed (must be left alone)"

# ── PROOF 5: the registry-missing HAID was skipped (tool still exited 0; noted in the plan) ──────
if [ "$RUN1_RC" -eq 0 ] && grep -q "skipped=" "$EXT/run1.out"; then
  ok "registry-missing HAID skipped, tool exited 0 (no crash)"
else
  bad "registry-missing HAID not skipped cleanly (rc=$RUN1_RC)"; cat "$EXT/run1.out"
fi

# ── PROOF 2: a second run is a byte-identical no-op (idempotent) ─────────────────────────────────
KEYS="$HEIMDALL_HOME/control-plane/auth/keys.json"
LEDGER="$(ls "$HEIMDALL_HOME"/control-plane/migration/team-converge/*.json 2>/dev/null | head -1)"
KEYS_BEFORE="$("$PY" -c 'import hashlib,sys;print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$KEYS")"
LEDGER_BEFORE="$("$PY" -c 'import hashlib,sys;print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$LEDGER")"
"$CONVERGE_CLI" >"$EXT/run2.out" 2>&1
RUN2_RC=$?
KEYS_AFTER="$("$PY" -c 'import hashlib,sys;print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$KEYS")"
LEDGER_AFTER="$("$PY" -c 'import hashlib,sys;print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$LEDGER")"
if [ "$RUN2_RC" -eq 0 ] && [ "$KEYS_BEFORE" = "$KEYS_AFTER" ] && [ "$LEDGER_BEFORE" = "$LEDGER_AFTER" ]; then
  ok "second run is a byte-identical no-op (keys.json + ledger unchanged)"
else
  bad "second run mutated state (rc=$RUN2_RC keys:$KEYS_BEFORE/$KEYS_AFTER ledger:$LEDGER_BEFORE/$LEDGER_AFTER)"
fi

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
