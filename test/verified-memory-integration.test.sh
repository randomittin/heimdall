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

# pull a value out of the captured JSON (OUT) by python index expression.
jget() { printf '%s' "$OUT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(eval('d'+sys.argv[1]))" "$1" 2>/dev/null; }
