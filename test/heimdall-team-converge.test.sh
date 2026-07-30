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
export LIB REPO CONVERGE_CLI

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

# ── BACKEND TRANSPARENCY: banner prints the RESOLVED backend (LOCAL) + loud warning ──────────────
if grep -q "backend: LOCAL" "$EXT/dryrun.out"; then
  ok "banner prints resolved backend (backend: LOCAL) with home path"
else
  bad "banner did not print 'backend: LOCAL'"; cat "$EXT/dryrun.out"
fi
if grep -qi "NOT prod Firestore" "$EXT/dryrun.out"; then
  ok "loud local-store warning printed (NOT prod Firestore)"
else
  bad "no loud local-store warning on the LOCAL backend"; cat "$EXT/dryrun.out"
fi

# ── LOCAL GUARD: a real EXECUTE against local WITHOUT --allow-local must REFUSE (nonzero) ─────────
"$CONVERGE_CLI" >"$EXT/guard.out" 2>&1
GUARD_RC=$?
if [ "$GUARD_RC" -ne 0 ] && grep -q "REFUSING to EXECUTE against the LOCAL store" "$EXT/guard.out"; then
  ok "execute against local WITHOUT --allow-local refused (rc=$GUARD_RC + guard message)"
else
  bad "local execute without --allow-local was NOT refused (rc=$GUARD_RC)"; cat "$EXT/guard.out"
fi
# the refusal must have written NOTHING (fixture still split).
[ "$(team_of "$HAID3")" = "$TEAM_B" ] \
  && ok "refused execute wrote NOTHING (haid3 still teamB)" \
  || bad "refused execute mutated state (must exit before any write)"

# ── FIRESTORE banner string (unit; no live firestore connection) ─────────────────────────────────
if "$PY" - <<'PY'
import os, sys, importlib.util, importlib.machinery
sys.path.insert(0, os.environ["LIB"])
os.environ["HEIMDALL_STATE_BACKEND"] = "firestore"
os.environ["GOOGLE_CLOUD_PROJECT"] = "prod-proj-xyz"
for k in ("HEIMDALL_FIRESTORE_PROJECT", "HEIMDALL_FIRESTORE_ROOT", "HEIMDALL_FIRESTORE_DATABASE"):
    os.environ.pop(k, None)
# The CLI is extensionless — load it via an explicit SourceFileLoader (no suffix-based loader).
loader = importlib.machinery.SourceFileLoader("converge_mod", os.environ["CONVERGE_CLI"])
spec = importlib.util.spec_from_loader("converge_mod", loader)
mod = importlib.util.module_from_spec(spec)
loader.exec_module(mod)                            # top-level import must NOT need the firestore dep
name, banner = mod._backend_banner(None)          # pure string build — no client, no network
assert name == "firestore", name
for frag in ("backend: firestore", "project=prod-proj-xyz", "root=heimdall_cp", "database=(default)"):
    assert frag in banner, (frag, banner)
print("firestore-banner-ok")
PY
then
  ok "firestore banner resolves project/root/database from env (no live connection)"
else
  bad "firestore banner string builder wrong"
fi

# ── FIRESTORE PREFLIGHT: no-ADC → banner then FAST nonzero with the exact fix (no live GCP) ───────
# The ADC probe + broken-transport detector are module-level seams, so a hermetic test forces the
# firestore preflight path WITHOUT a live google-auth install or any network: monkeypatch the probe
# to report MISSING ADC and assert converge() prints the banner then fails fast with the fix command.
if "$PY" - <<'PY'
import io, os, sys, importlib.util, importlib.machinery
sys.path.insert(0, os.environ["LIB"])
os.environ["HEIMDALL_STATE_BACKEND"] = "firestore"
os.environ["GOOGLE_CLOUD_PROJECT"] = "prod-proj-xyz"
loader = importlib.machinery.SourceFileLoader("converge_mod", os.environ["CONVERGE_CLI"])
spec = importlib.util.spec_from_loader("converge_mod", loader)
mod = importlib.util.module_from_spec(spec); loader.exec_module(mod)
# Force the ADC-probe path without a live dep; simulate MISSING Application Default Credentials.
mod._google_auth_available = lambda: True
mod._detect_broken_transport = lambda: None
mod._probe_adc = lambda timeout: ("no_adc", RuntimeError("Could not automatically determine credentials"))
buf = io.StringIO()
rc = mod.converge(home=None, dry_run=True, out=buf, err=buf)
s = buf.getvalue()
assert rc != 0, ("expected nonzero exit on missing ADC", rc, s)
assert "backend: firestore" in s, ("banner must print BEFORE the fast fail", s)
assert "application-default login" in s and "set-quota-project" in s, ("exact ADC fix missing", s)
print("no-adc-ok")
PY
then
  ok "firestore no-ADC: banner then fast nonzero exit with the exact ADC fix (no hang)"
else
  bad "firestore no-ADC preflight did not fast-fail with the fix"
fi

# ── FIRESTORE PREFLIGHT: a STALLED probe ABORTS within the timeout with the urllib3 diagnostic ────
# Simulate the real incident (google-auth token refresh wedged in a broken urllib3): the probe
# reports a stall AND the broken-transport detector names the versions. converge() must ABORT
# nonzero with the urllib3 diagnostic + the clean-venv fix — NOT hang. (The watchdog itself is
# exercised separately below with a real slow fn to prove it enforces the wall clock.)
if "$PY" - <<'PY'
import io, os, sys, importlib.util, importlib.machinery
sys.path.insert(0, os.environ["LIB"])
os.environ["HEIMDALL_STATE_BACKEND"] = "firestore"
os.environ["GOOGLE_CLOUD_PROJECT"] = "prod-proj-xyz"
loader = importlib.machinery.SourceFileLoader("converge_mod", os.environ["CONVERGE_CLI"])
spec = importlib.util.spec_from_loader("converge_mod", loader)
mod = importlib.util.module_from_spec(spec); loader.exec_module(mod)
mod._google_auth_available = lambda: True
mod._detect_broken_transport = lambda: ("2.6.3", "2.28.1")   # the RequestsDependencyWarning combo
mod._urllib3_version = lambda: "2.6.3"
mod._probe_adc = lambda timeout: ("stall", None)             # the token-refresh wedge
buf = io.StringIO()
rc = mod.converge(home=None, dry_run=True, out=buf, err=buf)
s = buf.getvalue()
assert rc != 0, ("a stall must ABORT nonzero, never hang", rc, s)
assert "backend: firestore" in s, ("banner must print before the abort", s)
assert "STALLED" in s and "urllib3" in s and "2.6.3" in s, ("stall diagnostic must name broken urllib3", s)
assert "hmdconv" in s, ("clean-venv fix must be offered", s)
assert "RequestsDependencyWarning" in s, ("up-front broken-transport WARNING must be printed", s)
print("stall-ok")
PY
then
  ok "firestore stall: aborts nonzero within timeout with the urllib3 diagnostic + venv fix (no hang)"
else
  bad "firestore stalled probe did not abort with the urllib3 diagnostic"
fi

# ── WATCHDOG: a genuinely slow fn is cut off at the wall clock (proves the hard timeout is real) ──
# Feed _run_in_watchdog a fn that would sleep far past the timeout; it must return ("timeout", None)
# in ~the timeout window, NOT block for the full sleep — the mechanism behind the stall abort.
if "$PY" - <<'PY'
import os, sys, time, importlib.util, importlib.machinery
sys.path.insert(0, os.environ["LIB"])
loader = importlib.machinery.SourceFileLoader("converge_mod", os.environ["CONVERGE_CLI"])
spec = importlib.util.spec_from_loader("converge_mod", loader)
mod = importlib.util.module_from_spec(spec); loader.exec_module(mod)
t0 = time.time()
status, payload = mod._run_in_watchdog(lambda: time.sleep(30), 0.5)   # would sleep 30s
elapsed = time.time() - t0
assert status == "timeout", ("a slow fn must time out", status)
assert elapsed < 5, ("watchdog must return at the wall clock, not wait out the sleep", elapsed)
# and a fast fn returns its result normally.
status2, payload2 = mod._run_in_watchdog(lambda: 42, 5)
assert status2 == "ok" and payload2 == 42, (status2, payload2)
# and a raising fn is classified as an error carrying the exception.
status3, payload3 = mod._run_in_watchdog(lambda: (_ for _ in ()).throw(ValueError("boom")), 5)
assert status3 == "error" and isinstance(payload3, ValueError), (status3, payload3)
print("watchdog-ok")
PY
then
  ok "watchdog cuts off a slow probe at the wall clock (ok/error/timeout classified)"
else
  bad "watchdog did not enforce the hard timeout"
fi

# ── LOCAL SKIP: the firestore preflight NEVER runs on the LOCAL backend (hermetic path unchanged) ─
# A booby-trapped _preflight_firestore that raises if called proves a LOCAL dry-run never touches it.
if "$PY" - <<'PY'
import io, os, sys, tempfile, importlib.util, importlib.machinery
sys.path.insert(0, os.environ["LIB"])
os.environ.pop("HEIMDALL_STATE_BACKEND", None)   # default → local
loader = importlib.machinery.SourceFileLoader("converge_mod", os.environ["CONVERGE_CLI"])
spec = importlib.util.spec_from_loader("converge_mod", loader)
mod = importlib.util.module_from_spec(spec); loader.exec_module(mod)
def _boom(*a, **k):
    raise AssertionError("firestore preflight ran on the LOCAL backend")
mod._preflight_firestore = _boom
buf = io.StringIO()
rc = mod.converge(home=tempfile.mkdtemp(prefix="hmd-skip-"), dry_run=True, out=buf, err=buf)
s = buf.getvalue()
assert rc == 0, ("local dry-run must exit 0", rc, s)
assert "backend: LOCAL" in s, ("local banner expected", s)
print("local-skip-ok")
PY
then
  ok "LOCAL backend skips the firestore preflight entirely (hermetic path unchanged)"
else
  bad "firestore preflight leaked into the LOCAL path"
fi

# ── EXECUTE the migration (local store: --allow-local is the deliberate opt-in) ───────────────────
"$CONVERGE_CLI" --allow-local >"$EXT/run1.out" 2>&1
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
"$CONVERGE_CLI" --allow-local >"$EXT/run2.out" 2>&1
RUN2_RC=$?
KEYS_AFTER="$("$PY" -c 'import hashlib,sys;print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$KEYS")"
LEDGER_AFTER="$("$PY" -c 'import hashlib,sys;print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$LEDGER")"
if [ "$RUN2_RC" -eq 0 ] && [ "$KEYS_BEFORE" = "$KEYS_AFTER" ] && [ "$LEDGER_BEFORE" = "$LEDGER_AFTER" ]; then
  ok "second run is a byte-identical no-op (keys.json + ledger unchanged)"
else
  bad "second run mutated state (rc=$RUN2_RC keys:$KEYS_BEFORE/$KEYS_AFTER ledger:$LEDGER_BEFORE/$LEDGER_AFTER)"
fi

# ── EMPTY LOCAL STORE: banner + warning + 0-groups hint, exit 0 (dry-run needs no flag) ──────────
EMPTY_HOME="$EXT/empty-home"; mkdir -p "$EMPTY_HOME"
HEIMDALL_HOME="$EMPTY_HOME" "$CONVERGE_CLI" --dry-run >"$EXT/empty.out" 2>&1
EMPTY_RC=$?
if [ "$EMPTY_RC" -eq 0 ] \
   && grep -q "backend: LOCAL" "$EXT/empty.out" \
   && grep -q "0 repo_slug group" "$EXT/empty.out" \
   && grep -qi "empty LOCAL store" "$EXT/empty.out"; then
  ok "empty local dry-run: banner + 0 groups + firestore hint, exit 0"
else
  bad "empty local dry-run missing banner/hint (rc=$EMPTY_RC)"; cat "$EXT/empty.out"
fi

# ══ CROSS-REPO-SHARED TEAM COLLISION (the fail-closed guard) ════════════════════════════════════
# THE BUG (from a real prod --dry-run): a single team_id can beat under MULTIPLE projects (a reused/
# default/maintainer team). The presence-tree grouping then lands that SAME team_id in MULTIPLE
# repo_slug groups — elected canonical in one, superseded in another. Re-pointing its members toward
# ONE repo YANKS them out of the others (a HAID has exactly ONE registered_team). The tool MUST
# fail-closed: never re-point a cross-repo team, never elect it as an absorbing canonical, report it.
#
# FIXTURE (its OWN HEIMDALL_HOME so it is independent of the split fixture above). Mirrors the prod
# collision EXACTLY — a shared team that is elected canonical in one repo but SUPERSEDED in another
# (the path that actually corrupts membership):
#   * T_SHARED beats under TWO projects — sole team under owner/repo-a (would be its canonical), AND
#     present under owner/repo-b ALONGSIDE an EXCLUSIVE team T_B that is EARLIER (T_B wins repo-b's
#     election). WITHOUT the guard, repo-b elects T_B and re-points HS2 (a T_SHARED member) onto T_B
#     — YANKING it out of T_SHARED where its teammate HS1 still lives. That is the corruption.
#   * owner/repo-c is a GENUINE split with two EXCLUSIVE teams T_C1 (earliest→canonical) + T_C2 —
#     the SAFE path that must still converge untouched.
COL_HOME="$EXT/collision-home"; mkdir -p "$COL_HOME"
export HEIMDALL_HOME="$COL_HOME"        # team_of/tree_digest read HEIMDALL_HOME at call time.

T_SHARED="dddd3333dddd3333dddd3333dddd3333"
T_B="9999bbbb9999bbbb9999bbbb9999bbbb"     # exclusive to repo-b, earlier → repo-b's canonical
T_C1="eeee4444eeee4444eeee4444eeee4444"
T_C2="ffff5555ffff5555ffff5555ffff5555"
REPO_A="github.com/owner/repo-a"
REPO_B="github.com/owner/repo-b"
REPO_C="github.com/owner/repo-c"
HS1="haid:sam.a-1a1a"    # T_SHARED under repo-a (canonical there)
HS2="haid:sue.b-2b2b"    # T_SHARED under repo-b — the member a broken run would YANK onto T_B
HB1="haid:ben.b-5b5b"    # T_B under repo-b (earliest in repo-b → its canonical)
HC1="haid:cid.c-3c3c"    # T_C1 under repo-c (earliest → canonical)
HC2="haid:cad.c-4c4c"    # T_C2 under repo-c (superseded → repointed to T_C1)
export T_SHARED T_B T_C1 T_C2 REPO_A REPO_B REPO_C HS1 HS2 HB1 HC1 HC2

"$PY" - <<'PY' || { echo "FATAL: collision seed failed" >&2; exit 2; }
import os, sys
sys.path.insert(0, os.environ["LIB"])
import cp_auth, cp_presence, cp_state
home = os.environ["HEIMDALL_HOME"]
backend = cp_state.get_backend(home=home)
PK = "QUJDREVGR0hJSktMTU5PUFFSU1RVVldYWVowMTIzNDU2Nzg5"
def reg(haid, team, enrolled):
    assert cp_auth.register_key(haid, PK, team_id=team, enrolled_at=enrolled, home=home)
def pres(project, team, haid):
    rec = cp_presence.build_record(haid, project=project, handle="h")
    assert backend.put_record(cp_presence._record_rel(project, team, haid), rec)
reg(os.environ["HS1"], os.environ["T_SHARED"], 500)
reg(os.environ["HB1"], os.environ["T_B"], 600)      # earliest in repo-b → repo-b's canonical
reg(os.environ["HS2"], os.environ["T_SHARED"], 900) # later than T_B so T_B wins repo-b's election
reg(os.environ["HC1"], os.environ["T_C1"], 700)
reg(os.environ["HC2"], os.environ["T_C2"], 800)
pres(os.environ["REPO_A"], os.environ["T_SHARED"], os.environ["HS1"])
pres(os.environ["REPO_B"], os.environ["T_SHARED"], os.environ["HS2"])
pres(os.environ["REPO_B"], os.environ["T_B"], os.environ["HB1"])
pres(os.environ["REPO_C"], os.environ["T_C1"], os.environ["HC1"])
pres(os.environ["REPO_C"], os.environ["T_C2"], os.environ["HC2"])
print("collision-seeded")
PY

# DRY-RUN zero-write on the collision fixture: writes NOTHING and reports the cross-repo team.
COL_BEFORE="$(tree_digest)"
"$CONVERGE_CLI" --dry-run >"$EXT/col-dry.out" 2>&1
COL_DRY_RC=$?
COL_AFTER="$(tree_digest)"
if [ "$COL_DRY_RC" -eq 0 ] && [ "$COL_BEFORE" = "$COL_AFTER" ]; then
  ok "collision --dry-run wrote NOTHING (tree digest unchanged)"
else
  bad "collision --dry-run mutated state (rc=$COL_DRY_RC)"; cat "$EXT/col-dry.out"
fi
if grep -q "CROSS-REPO TEAMS (skipped" "$EXT/col-dry.out" && grep -q "$T_SHARED" "$EXT/col-dry.out"; then
  ok "collision --dry-run reports T_SHARED under CROSS-REPO TEAMS (skipped)"
else
  bad "collision --dry-run did not report the cross-repo team"; cat "$EXT/col-dry.out"
fi

# EXECUTE the collision convergence (local store opt-in).
"$CONVERGE_CLI" --allow-local >"$EXT/col-run1.out" 2>&1
COL_RUN1_RC=$?
[ "$COL_RUN1_RC" -eq 0 ] && ok "collision converge run exited 0" \
  || { bad "collision converge run exited $COL_RUN1_RC"; cat "$EXT/col-run1.out"; }

# FALSIFIABLE CORE: the shared team was NOT re-pointed under either repo (both HAIDs keep T_SHARED).
if [ "$(team_of "$HS1")" = "$T_SHARED" ] && [ "$(team_of "$HS2")" = "$T_SHARED" ]; then
  ok "cross-repo team NOT re-pointed (HS1+HS2 still T_SHARED after a real run)"
else
  bad "cross-repo team WAS re-pointed (HS1=$(team_of "$HS1") HS2=$(team_of "$HS2")) — membership corruption"
fi

# the shared team was NEVER elected as a repo->team canonical (no absorbing bind under repo-a/repo-b).
BOUND_A="$("$PY" - <<'PY'
import os, sys
sys.path.insert(0, os.environ["LIB"])
import cp_repoteam
print(cp_repoteam.get_team_for_repo(os.environ["REPO_A"], home=os.environ["HEIMDALL_HOME"]) or "")
PY
)"
BOUND_B="$("$PY" - <<'PY'
import os, sys
sys.path.insert(0, os.environ["LIB"])
import cp_repoteam
print(cp_repoteam.get_team_for_repo(os.environ["REPO_B"], home=os.environ["HEIMDALL_HOME"]) or "")
PY
)"
# repo-a (T_SHARED its only/elected team) is SKIPPED → left UNBOUND; repo-b safely converges its
# EXCLUSIVE canonical T_B (a cross-repo MEMBER in the group never blocks the exclusive election).
if [ -z "$BOUND_A" ] && [ "$BOUND_B" = "$T_B" ]; then
  ok "cross-repo team not elected (repo-a left UNBOUND, repo-b safely bound to exclusive T_B)"
else
  bad "wrong canonical binding (a='$BOUND_A' want empty; b='$BOUND_B' want $T_B)"
fi

# the CONFLICTS LEDGER records T_SHARED and BOTH repo_slugs it spans.
CONFLICTS="$HEIMDALL_HOME/control-plane/migration/team-converge/_conflicts.json"
if "$PY" - "$CONFLICTS" <<'PY'
import json, os, sys
d = json.load(open(sys.argv[1]))
rows = {c["team_id"]: set(c["repo_slugs"]) for c in d["conflicts"]}
t = os.environ["T_SHARED"]
assert t in rows, ("T_SHARED absent from conflicts ledger", d)
assert rows[t] == {"owner/repo-a", "owner/repo-b"}, rows[t]
print("conflicts-ledger-ok")
PY
then
  ok "conflicts ledger records T_SHARED spanning both repo_slugs"
else
  bad "conflicts ledger missing/incorrect ($CONFLICTS)"; cat "$CONFLICTS" 2>/dev/null
fi

# THE SAFE PATH IS UNAFFECTED: repo-c's two EXCLUSIVE teams still converge onto T_C1.
if [ "$(team_of "$HC1")" = "$T_C1" ] && [ "$(team_of "$HC2")" = "$T_C1" ]; then
  ok "genuinely-split repo-c converged its two EXCLUSIVE teams onto T_C1 (safe path intact)"
else
  bad "repo-c did not converge (HC1=$(team_of "$HC1") HC2=$(team_of "$HC2"))"
fi

# IDEMPOTENT: a second collision run is a byte-identical no-op (keys + conflicts + repo-c ledger).
COL_KEYS="$HEIMDALL_HOME/control-plane/auth/keys.json"
COL_LEDGER="$(ls "$HEIMDALL_HOME"/control-plane/migration/team-converge/*.json 2>/dev/null)"
sha() { "$PY" -c 'import hashlib,sys;print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$1"; }
COL_K_BEFORE="$(sha "$COL_KEYS")"; COL_C_BEFORE="$(sha "$CONFLICTS")"
"$CONVERGE_CLI" --allow-local >"$EXT/col-run2.out" 2>&1
COL_RUN2_RC=$?
COL_K_AFTER="$(sha "$COL_KEYS")"; COL_C_AFTER="$(sha "$CONFLICTS")"
if [ "$COL_RUN2_RC" -eq 0 ] && [ "$COL_K_BEFORE" = "$COL_K_AFTER" ] && [ "$COL_C_BEFORE" = "$COL_C_AFTER" ]; then
  ok "collision second run is a byte-identical no-op (keys.json + _conflicts.json unchanged)"
else
  bad "collision second run mutated state (rc=$COL_RUN2_RC keys:$COL_K_BEFORE/$COL_K_AFTER conflicts:$COL_C_BEFORE/$COL_C_AFTER)"
fi

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
