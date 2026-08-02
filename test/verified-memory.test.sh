#!/usr/bin/env bash
# verified-memory.test.sh — acceptance for the Verified-Memory lib + CLI (VM piece
# B, bin/lib/verified_memory.py + bin/heimdall-memory). Piece B is the STORE +
# lifecycle that binds to the piece-A git-check engine. Every assertion is
# mechanical + falsifiable: an entry that SHOULD read stale but reads live reds the
# test — a false-live is the exact failure mode verified-memory exists to kill.
#
# All work happens in a throwaway git repo + an isolated HEIMDALL_HOME under a
# unique work dir, removed on exit (trap). No network, no shared state, no touching
# the real repo or the real .heimdall store.
#
# The proofs (dossier §2/§3/§7):
#   A. WRITE-TIME VERIFY — write an entry whose claim matches HEAD → the stored
#      entry is verified live at write time (status=live, weight>0).
#   B. READ → LIVE — get the entry back; with no git change it re-verifies live.
#   C. READ-TIME RE-VERIFICATION (THE CORE) — MUTATE git so the claim no longer
#      holds (PostgresStore → MySQLStore), then GET the SAME entry with NO re-write:
#      it is returned MARKED stale (status=stale, weight=0). Staleness detected at
#      RETRIEVAL by the git re-check, not by time. Falsifiable: a stale-that-reads-
#      live reds the test.
#   D. LIST --live-only — the stale entry is FILTERED from the served-context view
#      (never leaked as usable); it still appears in the full list marked stale.
#   E. RECONCILE → GIT WINS — two conflicting entries on a shared ref, one stale +
#      one live → reconcile picks the git-live survivor, decided_by=git.
#   F. WEIGHT IS A READ-TIME READOUT — a stored weight that disagrees with git is
#      OVERRIDDEN by the read-time readout (a stale entry reads weight 0 regardless
#      of the stored number; a live entry reads a fresh readout, not the stored one).
#   G. GITLEAKS-CLEAN STORE — a runtime-assembled secret-shaped claim is REJECTED at
#      write (exit 3) and is ABSENT from the store; gitleaks/secret-scan over the
#      store exits clean.
#
# Exit 0 = every proof holds. Nonzero = a proof failed (prints which).

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SELF_DIR/.." && pwd)"
CLI="$REPO/bin/heimdall-memory"

command -v python3 >/dev/null 2>&1 || { echo "FATAL: python3 required" >&2; exit 2; }
[ -x "$CLI" ] || { echo "FATAL: CLI missing/not-exec at $CLI" >&2; exit 2; }

PASS=0; FAIL=0
ok()  { printf '  \033[32mPASS\033[0m %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAIL=$((FAIL + 1)); }

# ── throwaway repo + isolated store (cleaned on exit) ─────────────────────────
# A unique work dir under TMPDIR (no mktemp X-template — the lint guard rejects it).
WORK="${TMPDIR:-/tmp}/vm-memory.$$.${RANDOM}"
mkdir -p "$WORK"
trap 'rm -rf "$WORK"' EXIT
GR="$WORK/repo"
HOME_DIR="$WORK/home"        # an isolated HEIMDALL_HOME — the store lives here
CACHE="$WORK/cache"
mkdir -p "$GR" "$HOME_DIR"
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

# mem ARGS... → run the CLI, capture JSON in OUT, exit in RC. Always pins the
# isolated --repo / --home / --cache-dir so nothing touches the real store.
mem() {
  OUT="$("$CLI" "$1" --repo "$GR" --home "$HOME_DIR" --cache-dir "$CACHE" "${@:2}" 2>/dev/null)"
  RC=$?
}
jget() { printf '%s' "$OUT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(eval('d'+sys.argv[1]))" "$1" 2>/dev/null; }

STORE="$HOME_DIR/memory/entries.ndjson"

# the Postgres adapter — the symbol PostgresStore is the claim's ref target.
P_SHA="$(mkrepo_commit db/store.py "class PostgresStore:
    def connect(self):
        return 'postgres'" "P: postgres adapter")"

# ─────────────────────────────────────────────────────────────────────────────
echo "A. WRITE-TIME VERIFY — claim matches HEAD → stored live, weight>0:"
mem write --claim "datastore is Postgres, touches db/store.py:PostgresStore" \
          --commit "$P_SHA" --ref "db/store.py:PostgresStore:class"
A_OK="$(jget "['ok']")"; A_STATUS="$(jget "['entry']['status']")"; A_WEIGHT="$(jget "['entry']['weight']")"
E1_ID="$(jget "['entry']['id']")"
[ "$A_OK" = "True" ] && ok "write ok=True (persisted)" || bad "write ok=$A_OK (want True)"
[ "$A_STATUS" = "live" ] && ok "write-time status=live (verified against git at write)" || bad "status=$A_STATUS (want live)"
awk "BEGIN{exit !($A_WEIGHT > 0)}" && ok "write-time weight=$A_WEIGHT (>0 readout)" || bad "weight=$A_WEIGHT (want >0)"
[ "$RC" -eq 0 ] && ok "write exit 0" || bad "write exit $RC (want 0)"
[ -f "$STORE" ] && ok "store NDJSON created at the isolated home" || bad "store not created at $STORE"

# ─────────────────────────────────────────────────────────────────────────────
echo "B. READ → LIVE — get the entry back; no git change → still live:"
mem get --id "$E1_ID"
B_STATUS="$(jget "['status']")"; B_WEIGHT="$(jget "['weight']")"
[ "$B_STATUS" = "live" ] && ok "read-time status=live (claim still matches HEAD)" || bad "status=$B_STATUS (want live)"
awk "BEGIN{exit !($B_WEIGHT > 0)}" && ok "read-time weight=$B_WEIGHT (>0)" || bad "weight=$B_WEIGHT (want >0)"

# ─────────────────────────────────────────────────────────────────────────────
echo "C. READ-TIME RE-VERIFICATION (THE CORE) — mutate git, NO re-write → stale:"
# advance git: PostgresStore -> MySQLStore. The claim's ref symbol is now gone.
M_SHA="$(mkrepo_commit db/store.py "class MySQLStore:
    def connect(self):
        return 'mysql'" "M: mysql adapter")"
# GET the SAME entry id — no write between. Read-time verify must catch the staleness.
mem get --id "$E1_ID"
C_STATUS="$(jget "['status']")"; C_WEIGHT="$(jget "['weight']")"
[ "$C_STATUS" = "stale" ] && ok "READ-TIME re-verify → status=stale (PostgresStore gone at HEAD) — FALSE-LIVE is the failure mode" || bad "status=$C_STATUS (want stale) — a stale entry read as LIVE reds the test"
awk "BEGIN{exit !($C_WEIGHT == 0)}" && ok "read-time weight=0 because git says stale (not because time passed)" || bad "weight=$C_WEIGHT (want 0)"
# the store on disk STILL holds the old live snapshot — proving the staleness comes
# from the READ-TIME re-check, not a stored value (the stored status is not trusted).
grep -q '"status":"live"' "$STORE" && ok "stored snapshot still says live → staleness is from the READ re-check, not the store" || bad "store no longer holds the original live snapshot (cannot prove read-time derivation)"

# ─────────────────────────────────────────────────────────────────────────────
echo "D. LIST --live-only — the stale entry is FILTERED from served context:"
mem list --live-only
D_LIVE_COUNT="$(jget "['count']")"
[ "$D_LIVE_COUNT" = "0" ] && ok "live-only list drops the now-stale entry (0 served)" || bad "live-only count=$D_LIVE_COUNT (want 0 — a stale entry leaked into served context)"
mem list
D_FULL_COUNT="$(jget "['count']")"
D_FULL_STATUS="$(jget "['entries'][0]['status']")"
[ "$D_FULL_COUNT" = "1" ] && ok "full list still surfaces the entry (1), MARKED stale" || bad "full list count=$D_FULL_COUNT (want 1)"
[ "$D_FULL_STATUS" = "stale" ] && ok "full-list entry carries the read-time stale status" || bad "full-list status=$D_FULL_STATUS (want stale)"

# ─────────────────────────────────────────────────────────────────────────────
echo "E. RECONCILE → GIT WINS — one stale + one live on a shared ref:"
# write a fresh entry on the NOW-live MySQL symbol (verified live at write).
mem write --claim "datastore is MySQL, touches db/store.py:MySQLStore" \
          --commit "$M_SHA" --ref "db/store.py:MySQLStore:class"
E2_ID="$(jget "['entry']['id']")"
[ "$(jget "['entry']['status']")" = "live" ] && ok "MySQL entry written live at M" || bad "MySQL write status=$(jget "['entry']['status']") (want live)"
# reconcile the stale Postgres entry against the live MySQL entry.
mem reconcile --id "$E1_ID" --id "$E2_ID"
E_VERDICT="$(jget "['verdict']")"; E_DECIDED="$(jget "['decided_by']")"
E_WINNER_SYM="$(jget "['winner']['refs'][0]['symbol']")"
[ "$E_VERDICT" = "auto-resolved" ] && ok "verdict=auto-resolved (all-but-one stale → git decides)" || bad "verdict=$E_VERDICT (want auto-resolved)"
[ "$E_DECIDED" = "git" ] && ok "decided_by=git (truth, not a vote)" || bad "decided_by=$E_DECIDED (want git)"
[ "$E_WINNER_SYM" = "MySQLStore" ] && ok "git-live MySQL entry wins (Postgres demoted)" || bad "winner symbol=$E_WINNER_SYM (want MySQLStore)"

# ─────────────────────────────────────────────────────────────────────────────
echo "F. WEIGHT IS A READ-TIME READOUT — stored number overridden by the git-check:"
# Hand-author a store line whose stored weight is a deliberate lie (0.99) and stored
# status a lie (live), pointing at a symbol that is GONE at HEAD. The read-time
# re-verify must OVERRIDE both: stale + weight 0, never the stored 0.99.
LIE_ID="vm-liedweight0001"
python3 - "$STORE" "$M_SHA" "$LIE_ID" <<'PY'
import json, sys
store, commit, lid = sys.argv[1], sys.argv[2], sys.argv[3]
line = json.dumps({
    "id": lid,
    "claim": "a stored weight is a guess until the git-check recomputes it at read",
    "commit_ref": commit,
    "refs": [{"path": "db/store.py", "symbol": "PostgresStore", "kind": "class"}],
    "weight": 0.99,                       # the deliberate lie
    "verified_at": "2020-01-01T00:00:00+00:00",
    "status": "live",                     # the deliberate lie
    "provenance": "measured",
    "schema_version": "vm-1.0",
}, sort_keys=True, separators=(",", ":"))
with open(store, "a", encoding="utf-8") as fh:
    fh.write(line + "\n")
PY
mem get --id "$LIE_ID"
F_STATUS="$(jget "['status']")"; F_WEIGHT="$(jget "['weight']")"
[ "$F_STATUS" = "stale" ] && ok "stored status='live' OVERRIDDEN to stale by the read-time git-check" || bad "status=$F_STATUS (stored opinion leaked through)"
awk "BEGIN{exit !($F_WEIGHT == 0 && $F_WEIGHT != 0.99)}" && ok "weight=$F_WEIGHT is the read-time readout (0), not the stored 0.99" || bad "weight=$F_WEIGHT (stored number was not recomputed)"

# ─────────────────────────────────────────────────────────────────────────────
echo "G. GITLEAKS-CLEAN STORE — runtime-assembled secret claim REJECTED + absent:"
# Assemble a GitHub-PAT-shaped secret at RUNTIME (never a static literal in this
# file — so the test source itself stays gitleaks-clean). The write must be REJECTED
# by the telemetry _scrub gate (exit 3) and the secret must be ABSENT from the store.
SECRET="ghp_$(printf 'a%.0s' $(seq 1 36))"   # ghp_ + 36 chars → GitHub PAT shape
mem write --claim "leaked token is $SECRET in db/store.py" \
          --commit "$M_SHA" --ref "db/store.py:MySQLStore:class"
G_OK="$(jget "['ok']")"; G_REASON="$(jget "['reason']")"
[ "$G_OK" = "False" ] && ok "secret-shaped claim REJECTED (ok=False)" || bad "secret claim ok=$G_OK (want False — a credential entered the store)"
[ "$RC" -eq 3 ] && ok "exit 3 (honest secret/shape-gate refusal, not a crash)" || bad "exit $RC (want 3 for a gate rejection)"
case "$G_REASON" in *gate*) ok "reason names the secret/shape gate";; *) bad "reason=$G_REASON (want a gate reason)";; esac
# the secret must NOT appear anywhere in the store.
if grep -q "$SECRET" "$STORE" 2>/dev/null; then
  bad "the secret token IS present in the store — gitleaks would fire"
else
  ok "the secret token is ABSENT from the store (gitleaks-clean by construction)"
fi
# a real secret scanner over the store exits clean (prefer the repo scanner; fall
# back to gitleaks; skip honestly if neither is installed — the grep above is the
# hard assertion, the scanner is the belt-and-braces confirmation).
SCANNED="no"
if [ -x "$REPO/bin/secret-scan" ]; then
  if "$REPO/bin/secret-scan" "$STORE" >/dev/null 2>&1; then ok "bin/secret-scan over the store exits clean"; SCANNED="yes"; else bad "bin/secret-scan flagged the store"; SCANNED="yes"; fi
fi
if [ "$SCANNED" = "no" ] && command -v gitleaks >/dev/null 2>&1; then
  if gitleaks detect --no-git --source "$STORE" >/dev/null 2>&1; then ok "gitleaks detect over the store exits clean"; else bad "gitleaks detect flagged the store"; fi
  SCANNED="yes"
fi
[ "$SCANNED" = "no" ] && ok "(no secret scanner installed — grep-absence assertion above is the hard gate)"

# ─────────────────────────────────────────────────────────────────────────────
echo
if [ "$FAIL" -eq 0 ]; then
  printf '\033[32mALL %d PROOFS PASSED\033[0m\n' "$PASS"
  # Machine-readable roll-up for test/run-all.sh. Printed LAST on BOTH paths so an
  # unparseable-but-green suite (indistinguishable from an empty one) is impossible.
  printf 'verified-memory: %d passed, %d failed\n' "$PASS" "$FAIL"
  exit 0
fi
printf '\033[31m%d/%d PROOFS FAILED\033[0m\n' "$FAIL" "$((PASS + FAIL))"
printf 'verified-memory: %d passed, %d failed\n' "$PASS" "$FAIL"
exit 1
