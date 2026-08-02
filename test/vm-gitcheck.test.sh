#!/usr/bin/env bash
# vm-gitcheck.test.sh — acceptance for the Verified-Memory git-check engine (VM
# piece A, bin/lib/vm_gitcheck.py). This is the BLOCKING foundation: staleness is
# DETECTED by re-checking a MemoryEntry's claim against git ground truth, never
# inferred from age. Every assertion is mechanical + falsifiable — an entry that
# SHOULD be stale but returns live reds the test.
#
# All work happens in a throwaway git repo created under a unique work dir and
# removed on exit (trap). No network, no shared state, no touching the real repo.
#
# The proofs (dossier §2):
#   A. LIVE — an entry whose commit_ref exists AND whose file/symbol refs are
#      still declared at HEAD → verify → status=live, weight>0.
#   B. STALE-by-mutation (the core) — MUTATE git so the referenced symbol vanishes
#      (PostgresStore → MySQLStore) → re-verify the SAME entry → status=stale,
#      weight=0. Staleness DETECTED by the git re-check, not by time.
#   C. STALE — a commit_ref that does not exist in the repo → stale (fail-safe).
#   D. STALE — a referenced file that has been deleted → stale.
#   E. CONFLICT reconciles toward git — two entries on a shared {path,symbol}, one
#      live + one stale → reconcile picks the git-live survivor, demotes the stale.
#   F. READ-TIME CACHE — repeated verify at the same HEAD returns identical status
#      from cache; advancing HEAD INVALIDATES the cache (re-derives live->stale).
#   G. FAIL-SAFE — a forced check timeout degrades to stale, NEVER live. A
#      falsely-live entry is the failure mode we eliminate.
#   H. WEIGHT IS A READOUT — weight is recomputed from the git-check each call, not
#      a stored decaying number; a stale entry's weight is 0 *because git says so*.
#
# Exit 0 = every proof holds. Nonzero = a proof failed (prints which).

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SELF_DIR/.." && pwd)"
ENGINE="$REPO/bin/lib/vm_gitcheck.py"

command -v python3 >/dev/null 2>&1 || { echo "FATAL: python3 required" >&2; exit 2; }
[ -f "$ENGINE" ] || { echo "FATAL: engine missing at $ENGINE" >&2; exit 2; }

PASS=0; FAIL=0
ok()  { printf '  \033[32mPASS\033[0m %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAIL=$((FAIL + 1)); }

# ── throwaway repo scaffolding (isolated, cleaned on exit) ─────────────────────
# A unique work dir under TMPDIR (no mktemp X-template — the lint guard rejects it).
WORK="${TMPDIR:-/tmp}/vm-gitcheck.$$.${RANDOM}"
mkdir -p "$WORK"
trap 'rm -rf "$WORK"' EXIT
GR="$WORK/repo"
mkdir -p "$GR"
git -C "$GR" init -q
git -C "$GR" config user.email "test@vm.local"
git -C "$GR" config user.name "vm-test"

mkrepo_commit() { # path content msg → echoes the new commit sha
  local rel="$1" body="$2" msg="$3"
  mkdir -p "$GR/$(dirname "$rel")"
  printf '%s\n' "$body" > "$GR/$rel"
  git -C "$GR" add -A
  git -C "$GR" commit -q -m "$msg"
  git -C "$GR" rev-parse HEAD
}

# the Postgres adapter — the symbol PostgresStore is the refs target.
P_SHA="$(mkrepo_commit db/store.py "class PostgresStore:
    def connect(self):
        return 'postgres'" "P: postgres adapter")"

# vmq ARGS... → run the engine CLI, capture JSON in REC, exit in RC.
vmq() {
  REC="$(python3 "$ENGINE" "$@" 2>/dev/null)"; RC=$?
}
jget() { printf '%s' "$REC" | python3 -c "import sys,json; d=json.load(sys.stdin); print(eval('d'+sys.argv[1]))" "$1" 2>/dev/null; }

# A MemoryEntry JSON helper: claim, commit_ref, one {path,symbol,kind} ref.
entry_json() { # commit_ref path symbol → entry on stdout
  python3 - "$1" "$2" "$3" <<'PY'
import json, sys
commit, path, sym = sys.argv[1], sys.argv[2], sys.argv[3]
print(json.dumps({
    "id": "vm-test0001",
    "claim": "datastore claim touches %s:%s" % (path, sym),
    "commit_ref": commit,
    "refs": [{"path": path, "symbol": sym, "kind": "class"}],
    "weight": 0.0,
    "verified_at": "2026-06-24T00:00:00+00:00",
    "status": "live",
    "provenance": "measured",
    "schema_version": "vm-1.0",
}))
PY
}

# ─────────────────────────────────────────────────────────────────────────────
echo "A. LIVE — claim matches HEAD (commit live + symbol present):"
E1="$WORK/e1.json"; entry_json "$P_SHA" "db/store.py" "PostgresStore" > "$E1"
vmq verify --repo "$GR" --entry "$E1"
A_STATUS="$(jget "['status']")"; A_WEIGHT="$(jget "['weight']")"
[ "$A_STATUS" = "live" ] && ok "status=live when commit + symbol present" || bad "status=$A_STATUS (want live)"
awk "BEGIN{exit !($A_WEIGHT > 0)}" && ok "weight=$A_WEIGHT (>0 for a live survivor)" || bad "weight=$A_WEIGHT (want >0)"
[ "$RC" -eq 0 ] && ok "verify exit 0 on a live entry" || bad "verify exit $RC (want 0)"

# ─────────────────────────────────────────────────────────────────────────────
echo "B. STALE-by-mutation (the core) — symbol vanishes, SAME entry goes stale:"
# advance git: PostgresStore -> MySQLStore (the symbol the claim depends on is gone)
M_SHA="$(mkrepo_commit db/store.py "class MySQLStore:
    def connect(self):
        return 'mysql'" "M: mysql adapter")"
vmq verify --repo "$GR" --entry "$E1"
B_STATUS="$(jget "['status']")"; B_WEIGHT="$(jget "['weight']")"
[ "$B_STATUS" = "stale" ] && ok "status=stale — PostgresStore gone at HEAD (detected by git)" || bad "status=$B_STATUS (want stale) — FALSE-LIVE is the failure mode"
awk "BEGIN{exit !($B_WEIGHT == 0)}" && ok "weight=0 because git says stale (not because time passed)" || bad "weight=$B_WEIGHT (want 0)"

# the falsifiability check: a fresh entry on the NOW-live MySQL symbol is live
E2="$WORK/e2.json"; entry_json "$M_SHA" "db/store.py" "MySQLStore" > "$E2"
vmq verify --repo "$GR" --entry "$E2"
[ "$(jget "['status']")" = "live" ] && ok "MySQL entry live at M (the check tracks ground truth both ways)" || bad "MySQL entry status=$(jget "['status']") (want live)"

# ─────────────────────────────────────────────────────────────────────────────
echo "C. STALE — a commit_ref that does not exist → fail-safe stale:"
E3="$WORK/e3.json"; entry_json "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef" "db/store.py" "MySQLStore" > "$E3"
vmq verify --repo "$GR" --entry "$E3"
[ "$(jget "['status']")" = "stale" ] && ok "missing commit_ref → stale" || bad "status=$(jget "['status']") (want stale)"

# ─────────────────────────────────────────────────────────────────────────────
echo "D. STALE — a referenced file deleted → stale:"
git -C "$GR" rm -q db/store.py
git -C "$GR" commit -q -m "D: drop store"
vmq verify --repo "$GR" --entry "$E2"
[ "$(jget "['status']")" = "stale" ] && ok "deleted file → stale" || bad "status=$(jget "['status']") (want stale)"
# restore the store for later sections (reconcile needs a live ref)
R_SHA="$(mkrepo_commit db/store.py "class MySQLStore:
    def connect(self):
        return 'mysql'" "R: restore mysql store")"

# ─────────────────────────────────────────────────────────────────────────────
echo "E. CONFLICT reconciles toward git — git-live survivor wins, stale demoted:"
# E1 (Postgres) is now provably stale; a fresh MySQL entry is live. Same path.
E2b="$WORK/e2b.json"; entry_json "$R_SHA" "db/store.py" "MySQLStore" > "$E2b"
vmq reconcile --repo "$GR" --entries "$E1" "$E2b"
E_VERDICT="$(jget "['verdict']")"
E_WINNER="$(jget "['winner']['refs'][0]['symbol']")"
E_DECIDED="$(jget "['decided_by']")"
[ "$E_VERDICT" = "auto-resolved" ] && ok "verdict=auto-resolved (all-but-one stale → git decides)" || bad "verdict=$E_VERDICT (want auto-resolved)"
[ "$E_WINNER" = "MySQLStore" ] && ok "git-live MySQL entry wins (Postgres demoted)" || bad "winner symbol=$E_WINNER (want MySQLStore)"
[ "$E_DECIDED" = "git" ] && ok "decided_by=git (truth, not a vote)" || bad "decided_by=$E_DECIDED (want git)"
# the demoted survivors carry status=stale
E_LOSER_STATUS="$(jget "['stale'][0]['status']")"
[ "$E_LOSER_STATUS" = "stale" ] && ok "the displaced Postgres entry is marked stale" || bad "loser status=$E_LOSER_STATUS (want stale)"

# ─────────────────────────────────────────────────────────────────────────────
echo "F. READ-TIME CACHE — keyed on (commit_ref + HEAD); invalidates when HEAD moves:"
# Two consecutive verifies at the SAME HEAD: second must be a cache hit, same
# status. A shared cache dir persists the cache across the separate CLI runs.
CACHE="$WORK/cache"
vmq verify --repo "$GR" --entry "$E2b" --cache-stats --cache-dir "$CACHE"
F1_STATUS="$(jget "['status']")"; F1_HIT="$(jget "['cache']['hit']")"
vmq verify --repo "$GR" --entry "$E2b" --cache-stats --cache-dir "$CACHE"
F2_STATUS="$(jget "['status']")"; F2_HIT="$(jget "['cache']['hit']")"
[ "$F1_STATUS" = "$F2_STATUS" ] && ok "cache returns consistent status across reads ($F1_STATUS)" || bad "status drifted $F1_STATUS->$F2_STATUS"
[ "$F1_HIT" = "False" ] && ok "first read is a cache MISS (cold)" || bad "first read hit=$F1_HIT (want False)"
[ "$F2_HIT" = "True" ] && ok "second read is a cache HIT (cheap at read time)" || bad "second read hit=$F2_HIT (want True)"
# advance HEAD: the cache key (HEAD sha) changes → MUST re-derive, not serve a hit.
git -C "$GR" rm -q db/store.py
git -C "$GR" commit -q -m "G: remove store again"
vmq verify --repo "$GR" --entry "$E2b" --cache-stats --cache-dir "$CACHE"
F3_STATUS="$(jget "['status']")"; F3_HIT="$(jget "['cache']['hit']")"
[ "$F3_HIT" = "False" ] && ok "HEAD moved → cache INVALIDATED (miss, re-derived)" || bad "cached hit served after HEAD move (hit=$F3_HIT)"
[ "$F3_STATUS" = "stale" ] && ok "re-derived status=stale (symbol gone at new HEAD)" || bad "status=$F3_STATUS (want stale after HEAD move)"

# ─────────────────────────────────────────────────────────────────────────────
echo "G. FAIL-SAFE — a forced check timeout degrades to stale, NEVER live:"
# restore a live ref so a NON-timed-out check WOULD say live — proving the timeout
# (not the git state) is what forces stale.
T_SHA="$(mkrepo_commit db/store.py "class MySQLStore:
    def connect(self):
        return 'mysql'" "T: restore for timeout test")"
ET="$WORK/et.json"; entry_json "$T_SHA" "db/store.py" "MySQLStore" > "$ET"
vmq verify --repo "$GR" --entry "$ET"
[ "$(jget "['status']")" = "live" ] && ok "sanity: entry IS live with no timeout forced" || bad "sanity status=$(jget "['status']") (want live)"
# force the timeout (impossible 0 budget) → must fail SAFE to stale
vmq verify --repo "$GR" --entry "$ET" --timeout 0
G_STATUS="$(jget "['status']")"; G_REASON="$(jget "['reason']")"
[ "$G_STATUS" = "stale" ] && ok "forced timeout → status=stale (fail-safe, never asserts live)" || bad "status=$G_STATUS (want stale on timeout — FALSE-LIVE)"
case "$G_REASON" in *timeout*) ok "reason names the timeout ($G_REASON)";; *) bad "reason=$G_REASON (want a timeout reason)";; esac
[ "$RC" -eq 0 ] && ok "verify never raises on timeout (graceful-degrade, exit 0)" || bad "verify exit $RC on timeout (want 0, never crash)"

# ─────────────────────────────────────────────────────────────────────────────
echo "H. WEIGHT IS A READOUT — recomputed from the git-check, not a stored number:"
# the stored entry weight is a deliberate lie; a LIVE verify must OVERRIDE it to a
# fresh readout, and a STALE verify must force 0 regardless of any stored value.
H1="$WORK/h1.json"
python3 - "$T_SHA" > "$H1" <<'PY'
import json, sys
print(json.dumps({
    "id": "vm-test0009",
    "claim": "the stored weight is a guess until the git-check recomputes it",
    "commit_ref": sys.argv[1],
    "refs": [{"path": "db/store.py", "symbol": "MySQLStore", "kind": "class"}],
    "weight": 0.99,
    "verified_at": "2020-01-01T00:00:00+00:00",
    "status": "stale",
    "provenance": "measured",
    "schema_version": "vm-1.0",
}))
PY
vmq verify --repo "$GR" --entry "$H1"
H_STATUS="$(jget "['status']")"; H_WEIGHT="$(jget "['weight']")"
[ "$H_STATUS" = "live" ] && ok "stored status='stale' OVERRIDDEN to live by the git-check" || bad "status=$H_STATUS (stored opinion leaked through)"
awk "BEGIN{exit !($H_WEIGHT > 0 && $H_WEIGHT != 0.99)}" && ok "weight=$H_WEIGHT is a fresh readout, not the stored 0.99" || bad "weight=$H_WEIGHT (stored number was not recomputed)"

# ─────────────────────────────────────────────────────────────────────────────
echo
if [ "$FAIL" -eq 0 ]; then
  printf '\033[32mALL %d PROOFS PASSED\033[0m\n' "$PASS"
  # Machine-readable roll-up for test/run-all.sh. Printed LAST on BOTH paths so an
  # unparseable-but-green suite (indistinguishable from an empty one) is impossible.
  printf 'vm-gitcheck: %d passed, %d failed\n' "$PASS" "$FAIL"
  exit 0
fi
printf '\033[31m%d/%d PROOFS FAILED\033[0m\n' "$FAIL" "$((PASS + FAIL))"
printf 'vm-gitcheck: %d passed, %d failed\n' "$PASS" "$FAIL"
exit 1
