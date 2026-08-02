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

# ═════════════════════════════════════════════════════════════════════════════
# BLOCK 3 — READ-PATH WIRED  (SI-1 capsule surfaces git-verified memory, dossier §6 D)
# ═════════════════════════════════════════════════════════════════════════════
# The cross-piece seam: heimdall-comprehend recall reads the SAME store (via
# HEIMDALL_HOME) that heimdall-memory wrote, and surfaces each remembered claim WITH its
# git-verified status — LIVE shown live, STALE shown stale (NEVER served as live). Read-
# time re-verification runs inside the read path, so the now-stale Postgres claim is
# surfaced stale and the live MySQL claim is surfaced live. And the no-regression half:
# an ABSENT store → recall is identical to today (a clean install is unaffected).
echo "BLOCK 3 — READ-PATH WIRED (heimdall-comprehend recall surfaces verified memory):"

# 3a. recall --json over the populated, shared store → available, with the live/stale
# partition computed at READ time (disjoint by construction).
recall --json
B3_AVAIL="$(jget "['available']")"
B3_LIVE_N="$(jget "['counts']['live']")"
B3_STALE_N="$(jget "['counts']['stale']")"
B3_LIVE_SYM="$(jget "['live'][0]['refs'][0]['symbol']")"
B3_LIVE_STATUS="$(jget "['live'][0]['status']")"
B3_STALE_STATUS="$(jget "['stale'][0]['status']")"
[ "$RC" -eq 0 ] && ok "recall exit 0 over the shared store" || bad "recall exit $RC (want 0)"
[ "$B3_AVAIL" = "True" ] && ok "recall available=True (the seam: comprehend resolved the memory CLI's store via HEIMDALL_HOME)" || bad "recall available=$B3_AVAIL (want True — the seam did not connect)"
[ "$B3_LIVE_N" = "1" ] && ok "1 live entry surfaced (the MySQL claim, git-confirmed)" || bad "live count=$B3_LIVE_N (want 1)"
[ "$B3_STALE_N" = "1" ] && ok "1 stale entry surfaced MARKED stale (the displaced Postgres claim)" || bad "stale count=$B3_STALE_N (want 1)"
[ "$B3_LIVE_SYM" = "MySQLStore" ] && ok "the live-set entry targets the git-live MySQLStore" || bad "live entry symbol=$B3_LIVE_SYM (want MySQLStore)"
[ "$B3_LIVE_STATUS" = "live" ] && ok "live entry shown WITH status=live (read-time readout)" || bad "live entry status=$B3_LIVE_STATUS (want live)"
[ "$B3_STALE_STATUS" = "stale" ] && ok "stale entry shown WITH status=stale — never promoted into the live set (disjoint by construction)" || bad "stale entry status=$B3_STALE_STATUS (want stale)"

# 3b. the rendered capsule block (text mode) visibly separates LIVE from STALE so the
# agent treats a stale memory as stale (verify against ground truth before acting).
recall
B3_TEXT="$OUT"
printf '%s' "$B3_TEXT" | grep -q "LIVE — git-confirmed" && ok "capsule block renders a LIVE section (git-confirmed survivors)" || bad "capsule block missing the LIVE section"
printf '%s' "$B3_TEXT" | grep -q "do NOT act on them" && ok "capsule block renders the STALE warning (do NOT act on stale memory)" || bad "capsule block missing the STALE warning"
printf '%s' "$B3_TEXT" | grep -qi "MySQLStore" && ok "capsule surfaces the live MySQL claim by its ref" || bad "capsule does not surface the live MySQL ref"

# 3c. NO-REGRESSION — an ABSENT store → recall behaves EXACTLY as today (a clean install
# is unaffected). Point HEIMDALL_HOME at an empty home with no memory store: available
# must be False and the text block the honest one-line 'none' note, exit 0 (no crash).
EMPTY_HOME="$WORK/empty-home"
mkdir -p "$EMPTY_HOME"
B3_ABS_JSON="$(HEIMDALL_HOME="$EMPTY_HOME" "$COMPREHEND" recall "$GR" --json 2>/dev/null)"; B3_ABS_RC=$?
B3_ABS_AVAIL="$(printf '%s' "$B3_ABS_JSON" | python3 -c "import sys,json;print(json.load(sys.stdin)['available'])" 2>/dev/null)"
B3_ABS_TEXT="$(HEIMDALL_HOME="$EMPTY_HOME" "$COMPREHEND" recall "$GR" 2>/dev/null)"
[ "$B3_ABS_RC" -eq 0 ] && ok "absent-store recall exit 0 (no crash on a clean install)" || bad "absent-store recall exit $B3_ABS_RC (want 0)"
[ "$B3_ABS_AVAIL" = "False" ] && ok "absent store → available=False (identical to today, no regression)" || bad "absent-store available=$B3_ABS_AVAIL (want False)"
printf '%s' "$B3_ABS_TEXT" | grep -q "none" && ok "absent store → the honest one-line 'none' block (additive note, not a section)" || bad "absent store did not render the 'none' note"

# ═════════════════════════════════════════════════════════════════════════════
# BLOCK 4 — BENCH HONEST  (the measured metrics table; CARDINAL: no fabricated number)
# ═════════════════════════════════════════════════════════════════════════════
# heimdall-vm-bench builds a REAL throwaway 3-commit fixture repo and scores all four
# methods (verified-memory vs decay / llm-judge / drift) against the SAME git-true
# labels. Two honesty properties are gated:
#   • every comparison figure carries a provenance tag (measured | estimated | blank);
#     the llm-judge arm is a labeled DOUBLE → its delta renders `est.` + basis, NEVER a
#     bare measured number; a value with NO provenance is STRUCTURALLY REFUSED to '—'
#     (require_provenance) — a fabricated number cannot print. THIS is the cardinal.
#   • the win/tie/null verdict is printed HONESTLY: verified-memory ties the llm-judge
#     double at stale-retrieval (does not strictly beat every baseline) → the run flags
#     a NULL result, reported as a finding, not buried (dossier §4).
echo "BLOCK 4 — BENCH HONEST (measured table; CARDINAL: no fabricated number):"

B4_JSON="$("$BENCH" run --json 2>/dev/null)"; B4_RC=$?
B4_TABLE="$("$BENCH" run 2>/dev/null)"
[ "$B4_RC" -eq 0 ] && ok "bench run exit 0 (built the fixture repo, scored all 4 methods)" || bad "bench run exit $B4_RC (want 0)"

# 4a. the measured table renders: header + a row per method, over real built commits.
printf '%s' "$B4_TABLE" | grep -q "Verified-Memory BENCHMARK" && ok "metrics table header rendered" || bad "metrics table header missing"
printf '%s' "$B4_TABLE" | grep -q "built commits:" && ok "table cites the REAL built fixture commits (staleness from a real git op, not a flag flip)" || bad "table missing the built-commits line"
for m in verified-memory decay llm-judge drift; do
  printf '%s' "$B4_TABLE" | grep -q "$m" && ok "table has the $m row" || bad "table missing the $m row"
done

# 4b. CARDINAL — NO FABRICATED NUMBER. Two falsifiable proofs:
#   (i) the llm-judge arm is a labeled estimate → its rendered delta carries `est.`,
#       NEVER a bare measured number. A bare llm-judge delta would mean an estimate was
#       passed off as measured (a fabrication) → reds the gate.
B4_LLM_PROV="$(printf '%s' "$B4_JSON" | python3 -c "import sys,json;print(json.load(sys.stdin)['deltas']['llm-judge']['stale_retrieval']['provenance'])" 2>/dev/null)"
B4_LLM_RENDERED="$(printf '%s' "$B4_JSON" | python3 -c "import sys,json;print(json.load(sys.stdin)['deltas']['llm-judge']['stale_retrieval_rendered'])" 2>/dev/null)"
[ "$B4_LLM_PROV" = "estimated" ] && ok "llm-judge delta provenance=estimated (a labeled double, never a measured LLM run)" || bad "llm-judge provenance=$B4_LLM_PROV (want estimated)"
case "$B4_LLM_RENDERED" in *est.*) ok "CARDINAL: llm-judge delta renders WITH 'est.' + basis — an estimate is never shown bare ($B4_LLM_RENDERED)";; *) bad "CARDINAL FAIL: llm-judge delta rendered without 'est.': $B4_LLM_RENDERED — an estimate passed off as measured";; esac

#  (ii) the structural REFUSAL itself: feed require_provenance/render_figure a figure
#       carrying a VALUE but NO provenance (a fabricated number) — the engine MUST
#       render it '—', never the bare number. This proves a baseless figure cannot
#       print as a fact (the honesty guard is structural, not cosmetic).
B4_REFUSE="$(python3 - "$REPO" <<'PY'
import sys, os
sys.path.insert(0, os.path.join(sys.argv[1], "bin", "lib"))
import vm_bench as B
fabricated = {"value": 0.42, "provenance": None, "basis": None, "band": None}  # a baseless number
prov, val = B.require_provenance(fabricated)
rendered = B.render_figure(fabricated)
# also confirm a properly-measured figure DOES render its number (the guard is not just
# blanking everything — it refuses ONLY the unprovenanced).
import holdout
measured = {"value": 0.8, "provenance": holdout.COST_MEASURED, "basis": "m", "band": None}
print("%s|%s|%s|%s" % (prov, val, rendered, B.render_figure(measured)))
PY
)"
B4_REFUSE_PROV="${B4_REFUSE%%|*}"
B4_REFUSE_RENDERED="$(printf '%s' "$B4_REFUSE" | cut -d'|' -f3)"
B4_MEASURED_RENDERED="$(printf '%s' "$B4_REFUSE" | cut -d'|' -f4)"
[ "$B4_REFUSE_PROV" = "None" ] && ok "require_provenance REFUSES a value with no provenance (returns None — a fabricated delta is not render-eligible)" || bad "require_provenance returned prov=$B4_REFUSE_PROV for an unprovenanced value (want None)"
[ "$B4_REFUSE_RENDERED" = "—" ] && ok "CARDINAL: a baseless figure renders '—', NEVER the invented number 0.42 (structural honesty guard)" || bad "CARDINAL FAIL: a baseless figure rendered '$B4_REFUSE_RENDERED' (a fabricated number printed)"
[ "$B4_MEASURED_RENDERED" = "0.8" ] && ok "a genuinely-measured figure still renders its number (the guard refuses ONLY the unprovenanced, not everything)" || bad "a measured figure rendered '$B4_MEASURED_RENDERED' (want 0.8 — the guard over-blanked)"

# 4c. the verdict is printed HONESTLY (win/tie/null). On this fixture verified-memory
# TIES the llm-judge double at stale-retrieval (both 0.0) → it does NOT strictly beat
# every baseline → the run flags a NULL result, surfaced as a finding, not buried.
B4_NULL="$(printf '%s' "$B4_JSON" | python3 -c "import sys,json;print(json.load(sys.stdin)['headline']['null_result'])" 2>/dev/null)"
B4_LLM_VERDICT="$(printf '%s' "$B4_JSON" | python3 -c "import sys,json;print(json.load(sys.stdin)['deltas']['llm-judge']['verdict'])" 2>/dev/null)"
B4_DECAY_VERDICT="$(printf '%s' "$B4_JSON" | python3 -c "import sys,json;print(json.load(sys.stdin)['deltas']['decay']['verdict'])" 2>/dev/null)"
[ "$B4_NULL" = "True" ] && ok "headline null_result=True printed honestly (ties llm-judge → not a clean sweep) — reported, not buried" || bad "null_result=$B4_NULL (want True on this fixture)"
[ "$B4_LLM_VERDICT" = "null-tie" ] && ok "llm-judge verdict=null-tie (honest: verified-memory ties, does not beat, the double here)" || bad "llm-judge verdict=$B4_LLM_VERDICT (want null-tie)"
[ "$B4_DECAY_VERDICT" = "verified-memory-wins" ] && ok "decay verdict=verified-memory-wins (a measured, real win where it exists)" || bad "decay verdict=$B4_DECAY_VERDICT (want verified-memory-wins)"
printf '%s' "$B4_TABLE" | grep -q "NULL NOTE" && ok "the table prints the NULL NOTE — the honest finding is surfaced in the human output" || bad "table did not print the NULL NOTE"

# ═════════════════════════════════════════════════════════════════════════════
# BLOCK 5 — PRIVACY  (no-secret-by-construction; CARDINAL: secret-absent from the store)
# ═════════════════════════════════════════════════════════════════════════════
# A credential must not enter the memory store BY CONSTRUCTION (dossier §7): every claim
# field passes the telemetry _scrub shape gate at write, so a secret-shaped claim is
# REJECTED (exit 3), never stored. The planted token is RUNTIME-ASSEMBLED from
# individually-non-matching fragments (heimdall-fixture-secret-convention.md) so THIS
# test source + git history stay gitleaks-clean while the runtime value is a real match
# the gate must catch.
echo "BLOCK 5 — PRIVACY (runtime-assembled secret REJECTED + absent; CARDINAL secret-absent):"

# RUNTIME-ASSEMBLE a GitHub-PAT-shaped token (ghp_ + 36 chars). No fragment is itself a
# gitleaks match; only the concatenation forms the detectable token. Never a static
# literal in source (the convention's gate-proof pattern).
_GP_PRE="ghp_"; _GP_A="0123456789abcdefghij"; _GP_B="klmnopqrstuvwxyz0123"
SECRET="${_GP_PRE}${_GP_A}${_GP_B}"   # ghp_ + 40 chars assembled at runtime → a real PAT match

# the store byte-length BEFORE the planted write — to prove nothing was appended.
B5_BEFORE_BYTES="$(wc -c < "$STORE" 2>/dev/null | tr -d ' ')"

# attempt to write a claim carrying the secret — the _scrub gate must REJECT it (exit 3).
mem write --claim "leaked deploy token is $SECRET embedded in db/store.py" \
          --commit "$M_SHA" --ref "db/store.py:MySQLStore:class"
B5_OK="$(jget "['ok']")"
B5_REASON="$(jget "['reason']")"
[ "$B5_OK" = "False" ] && ok "secret-shaped claim REJECTED (ok=False) — not stored with the secret quietly removed" || bad "secret claim ok=$B5_OK (want False — a credential entered the store)"
[ "$RC" -eq 3 ] && ok "exit 3 (the honest secret/shape-gate refusal, distinct from a disk error's exit 2)" || bad "exit $RC (want 3 for a gate rejection)"
case "$B5_REASON" in *gate*) ok "rejection reason names the secret/shape gate";; *) bad "reason=$B5_REASON (want a gate reason)";; esac

# CARDINAL — the secret is ABSENT from the store. The grep is the hard assertion.
if grep -q "$SECRET" "$STORE" 2>/dev/null; then
  bad "CARDINAL FAIL: the secret token IS present in the store — gitleaks would fire"
else
  ok "CARDINAL: the secret token is ABSENT from the store (no-secret-by-construction)"
fi

# the rejected write appended NOTHING — the store is byte-identical to before.
B5_AFTER_BYTES="$(wc -c < "$STORE" 2>/dev/null | tr -d ' ')"
[ "$B5_BEFORE_BYTES" = "$B5_AFTER_BYTES" ] && ok "the rejected write appended ZERO bytes (store unchanged: $B5_AFTER_BYTES)" || bad "store grew on a rejected write ($B5_BEFORE_BYTES → $B5_AFTER_BYTES)"

# belt-and-braces: a real secret scanner over the store exits clean. Prefer the repo
# scanner, fall back to gitleaks, skip honestly if neither is installed (the grep above
# is the hard gate; the scanner is the confirmation).
B5_SCANNED="no"
if [ -x "$REPO/bin/secret-scan" ]; then
  if "$REPO/bin/secret-scan" "$STORE" >/dev/null 2>&1; then ok "bin/secret-scan over the store exits clean"; else bad "bin/secret-scan flagged the store"; fi
  B5_SCANNED="yes"
fi
if [ "$B5_SCANNED" = "no" ] && command -v gitleaks >/dev/null 2>&1; then
  if gitleaks detect --no-git --source "$STORE" >/dev/null 2>&1; then ok "gitleaks detect over the store exits clean"; else bad "gitleaks detect flagged the store"; fi
  B5_SCANNED="yes"
fi
[ "$B5_SCANNED" = "no" ] && ok "(no secret scanner installed — the grep-absence assertion above is the hard gate)"

# ═════════════════════════════════════════════════════════════════════════════
# BLOCK 6 — WEIGHT = READOUT  (a stored weight disagreeing with git is overridden, §1)
# ═════════════════════════════════════════════════════════════════════════════
# weight is a READOUT of the git-check, recomputed at READ — never a stored decaying
# number (dossier §1). Hand-author a store line whose stored weight is a deliberate lie
# (0.99) and stored status a lie (live), pointing at a symbol that is GONE at HEAD
# (PostgresStore, removed by the block-1 mutation). The read-time re-verify must OVERRIDE
# both: status→stale, weight→0 — never the stored 0.99. A deliberately-wrong stored
# weight cannot leak through the read path.
echo "BLOCK 6 — WEIGHT = READOUT (stored weight overridden by the read-time git-readout):"

# append a lie line directly to the store: stored weight 0.99 + stored status live, on a
# symbol git proves gone. (A direct store write — the point is the READ ignores it.)
LIE_ID="vm-storedweightlie01"
python3 - "$STORE" "$M_SHA" "$LIE_ID" <<'PY'
import json, sys
store, commit, lid = sys.argv[1], sys.argv[2], sys.argv[3]
line = json.dumps({
    "id": lid,
    "claim": "a stored weight is a guess until the git-check recomputes it at read",
    "commit_ref": commit,
    "refs": [{"path": "db/store.py", "symbol": "PostgresStore", "kind": "class"}],  # GONE at HEAD
    "weight": 0.99,                       # the deliberate lie
    "verified_at": "2020-01-01T00:00:00+00:00",
    "status": "live",                     # the deliberate lie
    "provenance": "measured",
    "schema_version": "vm-1.0",
}, sort_keys=True, separators=(",", ":"))
with open(store, "a", encoding="utf-8") as fh:
    fh.write(line + "\n")
PY

# 6a. via the memory CLI get: the read-time readout overrides the stored lie.
mem get --id "$LIE_ID"
B6_STATUS="$(jget "['status']")"
B6_WEIGHT="$(jget "['weight']")"
[ "$B6_STATUS" = "stale" ] && ok "stored status='live' OVERRIDDEN to stale by the read-time git-check (the stored opinion is never trusted)" || bad "status=$B6_STATUS (the stored 'live' leaked through)"
awk "BEGIN{exit !($B6_WEIGHT == 0 && $B6_WEIGHT != 0.99)}" && ok "weight=$B6_WEIGHT is the read-time readout (0 because git says stale), NOT the stored lie 0.99" || bad "weight=$B6_WEIGHT (the stored 0.99 was not recomputed)"

# 6b. and through the WIRED read path (comprehend recall) the lie is surfaced stale,
# never ranked among the live — the override holds across the seam, not just in the CLI.
recall --json
B6_R_STALE_SYMS="$(printf '%s' "$OUT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(','.join((e.get('refs') or [{}])[0].get('symbol','') for e in d['stale']))" 2>/dev/null)"
B6_R_LIVE_SYMS="$(printf '%s' "$OUT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(','.join((e.get('refs') or [{}])[0].get('symbol','') for e in d['live']))" 2>/dev/null)"
case "$B6_R_STALE_SYMS" in *PostgresStore*) ok "the lie surfaces in the STALE set via the read path (PostgresStore is gone at HEAD)";; *) bad "the lie did not appear stale in recall (stale syms: $B6_R_STALE_SYMS)";; esac
case "$B6_R_LIVE_SYMS" in *PostgresStore*) bad "the lie leaked into the LIVE set via the read path (stored 0.99 was honored)";; *) ok "the lie is NOT in the live set — a deliberately-wrong stored weight cannot leak through the seam";; esac

# ═════════════════════════════════════════════════════════════════════════════
# FOOTER — the gate verdict (exit 0 iff every block held)
# ═════════════════════════════════════════════════════════════════════════════
echo
if [ "$FAIL" -eq 0 ]; then
  printf '\033[32mINTEGRATION GATE PASSED — all %d assertions across the 6 wired blocks\033[0m\n' "$PASS"
  # Machine-readable roll-up for test/run-all.sh. Printed LAST on BOTH paths so an
  # unparseable-but-green suite (indistinguishable from an empty one) is impossible.
  printf 'verified-memory-integration: %d passed, %d failed\n' "$PASS" "$FAIL"
  exit 0
fi
printf '\033[31mINTEGRATION GATE FAILED — %d/%d assertions failed\033[0m\n' "$FAIL" "$((PASS + FAIL))"
printf 'verified-memory-integration: %d passed, %d failed\n' "$PASS" "$FAIL"
exit 1
