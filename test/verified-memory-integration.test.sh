#!/usr/bin/env bash
# verified-memory-integration.test.sh — the Verified-Memory END-TO-END INTEGRATION
# GATE (VM piece E, dossier §7). Where the unit tests prove each engine in isolation,
# THIS gate drives the REAL wired system across every piece at once — the actual
# bin/heimdall-* CLIs over their real store resolution, NOT a unit-only re-call of one
# function (the metering lesson: a gate that mocks the seam proves nothing about the
# seam). The arc:
#
#   heimdall-memory write  ─┐                       (piece B: store + lifecycle)
#                           ├─► entries.ndjson ◄─┐  (the ONE gitleaks-native store)
#   a REAL git mutation  ───┘   │                │
#                               ▼                │
#   heimdall-memory get  ──────► read-time re-verify against git  (piece A: vmg.verify)
#   heimdall-comprehend recall ► SI-1 read-path surfaces it       (piece D: vm_readpath)
#   heimdall-memory reconcile ─► git decides the winner           (piece A: vmg.reconcile)
#   heimdall-vm-bench run  ────► the honest measured metrics table (piece C: vm_bench)
#
# The cross-piece seam that makes this an INTEGRATION (not a unit) test: the memory
# CLI writes the store under an explicit --home; heimdall-comprehend resolves the SAME
# store via HEIMDALL_HOME (issue_queue.heimdall_home). Pointing both at one isolated
# home is how a write on the memory CLI becomes visible to the comprehend read path —
# the real wiring, exercised, not stubbed.
#
# THE SIX BLOCKS (dossier §7 integration-gate plan + the spec-acceptance→assertion map),
# each committed in-worktree the moment it goes green (infra has killed long agents this
# session — the in-worktree commit is the source of truth):
#
#   1. WRITE→STALE→READ (THE CORE) — write an entry live against HEAD, MUTATE git (a
#      real commit: PostgresStore → MySQLStore), then GET the SAME id with NO re-write.
#      It is returned MARKED stale (read-time re-verification caught it against git).
#      CARDINAL + FALSIFIABLE: a stale entry served as live reds the gate.
#   2. RECONCILE→GIT-WINS — two conflicting entries (one now-stale, one live) →
#      reconcile → git decides the winner, decided_by=git, the stale one demoted.
#   3. READ-PATH WIRED — heimdall-comprehend recall (SI-1 capsule) surfaces the verified
#      memory with git-verified status (live shown live, stale shown stale); an ABSENT
#      store → recall identical to today (no regression on a clean install).
#   4. BENCH HONEST — heimdall-vm-bench produces the measured metrics table; assert NO
#      fabricated number (a baseless figure renders '—'/est., never invented); the
#      win/tie/null verdict is printed honestly. CARDINAL: no-fabricated-number.
#   5. PRIVACY — a RUNTIME-assembled secret in a claim field is REJECTED at write, is
#      ABSENT from the store, and the store is gitleaks-clean. CARDINAL: secret-absent.
#   6. WEIGHT = READOUT — a stored weight that disagrees with git is OVERRIDDEN by the
#      read-time git-readout (stale → 0), never the stored lie.
#
# Everything runs in a throwaway git repo + an isolated HEIMDALL_HOME under a unique
# work dir, removed on exit (trap). No network, no shared state, never touches the real
# repo or the real .heimdall store. Exit 0 = every block holds; nonzero = a block failed.

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SELF_DIR/.." && pwd)"
MEM="$REPO/bin/heimdall-memory"
COMPREHEND="$REPO/bin/heimdall-comprehend"
BENCH="$REPO/bin/heimdall-vm-bench"

command -v python3 >/dev/null 2>&1 || { echo "FATAL: python3 required" >&2; exit 2; }
command -v git     >/dev/null 2>&1 || { echo "FATAL: git required" >&2; exit 2; }
[ -x "$MEM" ]        || { echo "FATAL: heimdall-memory missing/not-exec at $MEM" >&2; exit 2; }
[ -x "$COMPREHEND" ] || { echo "FATAL: heimdall-comprehend missing/not-exec at $COMPREHEND" >&2; exit 2; }
[ -x "$BENCH" ]      || { echo "FATAL: heimdall-vm-bench missing/not-exec at $BENCH" >&2; exit 2; }

PASS=0; FAIL=0
ok()  { printf '  \033[32mPASS\033[0m %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAIL=$((FAIL + 1)); }

# ── throwaway repo + isolated store (cleaned on exit) ─────────────────────────
# A unique work dir under TMPDIR (no mktemp X-template — the lint guard rejects it).
WORK="${TMPDIR:-/tmp}/vm-integration.$$.${RANDOM}"
mkdir -p "$WORK"
trap 'rm -rf "$WORK"' EXIT
GR="$WORK/repo"             # the throwaway git repo that is ground truth
H="$WORK/home"             # the isolated HEIMDALL_HOME — the ONE store both pieces share
CACHE="$WORK/cache"
mkdir -p "$GR" "$H"
git -C "$GR" init -q
git -C "$GR" config user.email "test@vm.local"
git -C "$GR" config user.name "vm-int-test"

STORE="$H/memory/entries.ndjson"   # the gitleaks-native NDJSON store both pieces resolve to

# commit a file body under the repo; echo the new HEAD sha. A real git operation —
# staleness in this gate is induced by a real commit, never a flag flip.
gitcommit() { # rel body msg → echoes the new commit sha
  local rel="$1" body="$2" msg="$3"
  mkdir -p "$GR/$(dirname "$rel")"
  printf '%s\n' "$body" > "$GR/$rel"
  git -C "$GR" add -A
  git -C "$GR" commit -q -m "$msg"
  git -C "$GR" rev-parse HEAD
}

# mem SUB ARGS... → run the memory CLI, capture JSON in OUT + exit in RC. Always pins
# the isolated --repo / --home / --cache-dir so nothing touches the real store. This is
# the WRITE/RECONCILE side of the seam.
mem() {
  OUT="$("$MEM" "$1" --repo "$GR" --home "$H" --cache-dir "$CACHE" "${@:2}" 2>/dev/null)"
  RC=$?
}

# recall FMT → run heimdall-comprehend recall over the SAME store via HEIMDALL_HOME
# (the cross-piece seam), capturing its output in OUT + exit in RC. FMT is "" (text) or
# "--json". This is the READ-PATH side of the seam — the real SI-1 capsule read.
recall() {
  if [ "${1:-}" = "--json" ]; then
    OUT="$(HEIMDALL_HOME="$H" "$COMPREHEND" recall "$GR" --json 2>/dev/null)"; RC=$?
  else
    OUT="$(HEIMDALL_HOME="$H" "$COMPREHEND" recall "$GR" 2>/dev/null)"; RC=$?
  fi
}

# pull a value out of the captured JSON (OUT) by python index expression. The index
# strings below are static literals authored in THIS file over trusted CLI JSON output
# (no external input) — the eval mirrors the established harness in
# test/verified-memory.test.sh:75; it is a test-only JSON accessor, not a code path.
jget() { printf '%s' "$OUT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(eval('d'+sys.argv[1]))" "$1" 2>/dev/null; }

# ── seed the live fixture: commit P (the Postgres adapter) ────────────────────
# db/store.py declares PostgresStore — the symbol the first claim's ref targets. At P,
# a claim about PostgresStore is git-true LIVE.
P_SHA="$(gitcommit db/store.py "class PostgresStore:
    def connect(self):
        return 'postgres'

    def query(self, sql):
        return self.connect() + ':' + sql" "P: postgres adapter")"

# ═════════════════════════════════════════════════════════════════════════════
# BLOCK 1 — WRITE→STALE→READ  (THE CARDINAL CORE; falsifiable: stale-detected-at-read)
# ═════════════════════════════════════════════════════════════════════════════
# Write an entry that matches HEAD (live), then MUTATE git with a REAL commit so the
# claim no longer holds, then GET the SAME id with NO re-write between. Read-time
# re-verification must catch the staleness against git and return the entry MARKED
# stale — never served as live. A stale-that-reads-live REDS the gate (the exact
# false-live failure mode verified-memory exists to kill).
echo "BLOCK 1 — WRITE→STALE→READ (read-time re-verification, the core):"

# 1a. WRITE — claim matches HEAD at P → stored live, weight>0, verified at WRITE time.
mem write --claim "datastore is Postgres, touches db/store.py:PostgresStore" \
          --commit "$P_SHA" --ref "db/store.py:PostgresStore:class"
B1_OK="$(jget "['ok']")"
E1_ID="$(jget "['entry']['id']")"
B1_WSTATUS="$(jget "['entry']['status']")"
B1_WWEIGHT="$(jget "['entry']['weight']")"
[ "$B1_OK" = "True" ] && ok "write ok=True, persisted to the shared store" || bad "write ok=$B1_OK (want True)"
[ "$RC" -eq 0 ] && ok "write exit 0" || bad "write exit $RC (want 0)"
[ "$B1_WSTATUS" = "live" ] && ok "write-time status=live (verified against git AT WRITE)" || bad "write-time status=$B1_WSTATUS (want live)"
awk "BEGIN{exit !($B1_WWEIGHT > 0)}" && ok "write-time weight=$B1_WWEIGHT (>0 readout)" || bad "write-time weight=$B1_WWEIGHT (want >0)"
[ -f "$STORE" ] && ok "store NDJSON created at the isolated home (the seam's shared store)" || bad "store not created at $STORE"

# 1b. READ before mutation — get the same id; with NO git change it re-verifies live.
mem get --id "$E1_ID"
B1_R0_STATUS="$(jget "['status']")"
[ "$B1_R0_STATUS" = "live" ] && ok "read before mutation → live (claim still matches HEAD)" || bad "pre-mutation read status=$B1_R0_STATUS (want live)"

# 1c. MUTATE git — a REAL commit advances db/store.py: PostgresStore → MySQLStore. The
# claim's ref symbol is now GONE at HEAD. This is a real git operation, not a flag flip.
M_SHA="$(gitcommit db/store.py "class MySQLStore:
    def connect(self):
        return 'mysql'

    def query(self, sql):
        return self.connect() + ':' + sql" "M: mysql adapter (PostgresStore gone)")"
[ "$M_SHA" != "$P_SHA" ] && ok "git mutated by a REAL commit (HEAD advanced P→M)" || bad "git did not advance (M_SHA==P_SHA)"

# 1d. READ after mutation, NO re-write — read-time re-verification must mark it stale.
# This is the CARDINAL, FALSIFIABLE assertion: the SAME entry, no write between, must
# come back stale because git says PostgresStore is gone — detected AT READ.
mem get --id "$E1_ID"
B1_R1_STATUS="$(jget "['status']")"
B1_R1_WEIGHT="$(jget "['weight']")"
B1_R1_REASON="$(jget "['reason']")"
[ "$B1_R1_STATUS" = "stale" ] \
  && ok "CARDINAL: read-time re-verify → status=stale (PostgresStore gone at HEAD); a stale entry served as LIVE would RED the gate" \
  || bad "CARDINAL FAIL: post-mutation read status=$B1_R1_STATUS (want stale) — a stale entry was served as live"
awk "BEGIN{exit !($B1_R1_WEIGHT == 0)}" && ok "read-time weight=0 because git says stale (not because time passed)" || bad "post-mutation weight=$B1_R1_WEIGHT (want 0)"
case "$B1_R1_REASON" in *PostgresStore*|*"no longer"*|*absent*) ok "stale reason cites the git evidence: $B1_R1_REASON";; *) bad "stale reason does not cite git evidence: $B1_R1_REASON";; esac

# 1e. PROVENANCE OF THE STALENESS — the on-disk store STILL holds the original live
# snapshot. So the stale verdict came from the READ-TIME re-check, not a stored value
# (the stored status is never trusted). This is what makes #1 an integration proof, not
# a stored-flag read.
grep -q '"status":"live"' "$STORE" \
  && ok "stored snapshot still says live → the stale verdict is from the READ re-check, not the store" \
  || bad "store no longer holds the original live snapshot (cannot prove read-time derivation)"

# ═════════════════════════════════════════════════════════════════════════════
# BLOCK 2 — RECONCILE→GIT-WINS  (conflict resolved by ground truth, dossier §3)
# ═════════════════════════════════════════════════════════════════════════════
# Two entries on the shared db/store.py ref: the now-stale Postgres entry (E1, from
# block 1) and a fresh live MySQL entry (E2). reconcile must let GIT decide: the lone
# git-live entry (MySQL) wins, decided_by=git, the stale one demoted — no human, no
# vote. This is the §3 auto-resolve (all-but-one stale → git decides). Genuine intent
# (>=2 mutually-live) is the only thing that escalates, which §3 reserves for humans.
echo "BLOCK 2 — RECONCILE→GIT-WINS (conflict decided by git, not a vote):"

# write E2 on the NOW-live MySQL symbol at M → verified live at write.
mem write --claim "datastore is MySQL, touches db/store.py:MySQLStore" \
          --commit "$M_SHA" --ref "db/store.py:MySQLStore:class"
E2_ID="$(jget "['entry']['id']")"
B2_E2_STATUS="$(jget "['entry']['status']")"
[ "$B2_E2_STATUS" = "live" ] && ok "fresh MySQL entry written live at M" || bad "MySQL write status=$B2_E2_STATUS (want live)"

# reconcile the stale Postgres entry (E1) against the live MySQL entry (E2). git wins.
mem reconcile --id "$E1_ID" --id "$E2_ID"
B2_VERDICT="$(jget "['verdict']")"
B2_DECIDED="$(jget "['decided_by']")"
B2_WINNER_SYM="$(jget "['winner']['refs'][0]['symbol']")"
B2_WINNER_ID="$(jget "['winner']['id']")"
B2_STALE_N="$(jget "['stale'].__len__()")"
[ "$B2_VERDICT" = "auto-resolved" ] && ok "verdict=auto-resolved (all-but-one stale → git decides, no human)" || bad "verdict=$B2_VERDICT (want auto-resolved)"
[ "$B2_DECIDED" = "git" ] && ok "decided_by=git (ground truth, not a vote / not an LLM)" || bad "decided_by=$B2_DECIDED (want git)"
[ "$B2_WINNER_SYM" = "MySQLStore" ] && ok "winner is the git-live MySQL entry (Postgres demoted)" || bad "winner symbol=$B2_WINNER_SYM (want MySQLStore)"
[ "$B2_WINNER_ID" = "$E2_ID" ] && ok "winner id is E2 (the live entry), not the stale E1" || bad "winner id=$B2_WINNER_ID (want E2 $E2_ID)"
[ "$B2_STALE_N" = "1" ] && ok "exactly one entry demoted to stale (the displaced Postgres claim)" || bad "stale set size=$B2_STALE_N (want 1)"
