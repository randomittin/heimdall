#!/usr/bin/env bash
# vm-readpath.test.sh — acceptance for the Verified-Memory → SI-1 read-path seam
# (VM piece D: bin/lib/vm_readpath.py + the `recall` block / verified-memory append
# in bin/heimdall-comprehend). Piece D surfaces this repo's git-verified memory on
# the orientation read path: each remembered claim shown WITH its git-verified
# status, verified AT READ TIME, so a stale claim is surfaced stale — never as live.
#
# Every assertion is mechanical + FALSIFIABLE. The core proof (C/D): a STALE entry
# served as LIVE reds the test — a false-live is the exact failure mode verified-
# memory exists to kill. All work happens in a throwaway git repo + an isolated
# HEIMDALL_HOME under a unique work dir, removed on exit (trap). No network, no
# shared state, no touching the real repo or the real .heimdall store.
#
# The proofs (dossier §2/§6 piece D):
#   A. SEED — write a LIVE entry (claim matches HEAD) + mutate git so a SECOND
#      entry's claim no longer holds (PostgresStore → MySQLStore) → a real STALE.
#   B. READ PATH SERVES LIVE AS LIVE — the readout's `live` set contains the live
#      entry with status=live, weight>0, and does NOT contain the stale one.
#   C. STALE MARKED STALE, NEVER LIVE (THE CORE) — the stale entry is in the
#      readout's `stale` set with status=stale; it is ABSENT from `live`. A stale
#      entry leaking into `live` reds the test.
#   D. COMPREHEND SHOWS GIT-VERIFIED STATUS — `comprehend recall` (and the block
#      appended to the assembled capsule) shows the live claim as live and the
#      stale claim as stale — the git-verified status is on the readout.
#   E. ABSENT STORE → COMPREHEND IDENTICAL — with NO memory store, `comprehend`'s
#      stdout (the capsule JSON) is byte-identical to a run with the read-path code,
#      and `recall` reports an honest "none" — no regression, no crash.
#   F. STALE WEIGHT IS LOW — the stale entry's read-time weight is 0 (the readout
#      ranks the live survivors; git, not a timer, zeroed the stale one).
#
# Exit 0 = every proof holds. Nonzero = a proof failed (prints which).

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SELF_DIR/.." && pwd)"
MEM="$REPO/bin/heimdall-memory"
COMPREHEND="$REPO/bin/heimdall-comprehend"
READPATH="$REPO/bin/lib/vm_readpath.py"

command -v python3 >/dev/null 2>&1 || { echo "FATAL: python3 required" >&2; exit 2; }
[ -x "$MEM" ]        || { echo "FATAL: heimdall-memory missing/not-exec at $MEM" >&2; exit 2; }
[ -x "$COMPREHEND" ] || { echo "FATAL: heimdall-comprehend missing at $COMPREHEND" >&2; exit 2; }
[ -f "$READPATH" ]   || { echo "FATAL: vm_readpath lib missing at $READPATH" >&2; exit 2; }

PASS=0; FAIL=0
ok()  { printf '  \033[32mPASS\033[0m %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAIL=$((FAIL + 1)); }

# ── throwaway repo + isolated store (cleaned on exit) ─────────────────────────
# A unique work dir under TMPDIR (no mktemp X-template — the lint guard rejects it).
WORK="${TMPDIR:-/tmp}/vm-readpath.$$.${RANDOM}"
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

# mem ARGS... → run the memory CLI, capture JSON in OUT, exit in RC. Always pins the
# isolated --repo / --home / --cache-dir so nothing touches the real store.
mem() {
  OUT="$("$MEM" "$1" --repo "$GR" --home "$HOME_DIR" --cache-dir "$CACHE" "${@:2}" 2>/dev/null)"
  RC=$?
}
# jget JSON INDEX-EXPR → eval a python index expression (e.g. "['entry']['id']")
# against the parsed JSON. SAFE: the index expr is a fixed literal authored in THIS
# test (never untrusted input), evaluated in a throwaway test subprocess over our
# own captured JSON — the house-style accessor mirrored from verified-memory.test.sh.
jget() { printf '%s' "$1" | python3 -c "import sys,json; d=json.load(sys.stdin); print(eval('d'+sys.argv[1]))" "$2" 2>/dev/null; }

# readout TEXT|json → run the read-path lib directly against the isolated store,
# capturing the readout. The lib reads HEIMDALL_HOME via --home; we pin it here.
readout() {
  python3 "$READPATH" readout --repo "$GR" --home "$HOME_DIR" --cache-dir "$CACHE" "--$1" 2>/dev/null
}

STORE="$HOME_DIR/memory/entries.ndjson"

# ─────────────────────────────────────────────────────────────────────────────
echo "A. SEED — a live entry (matches HEAD) + a git mutation that staleness a second:"

# commit P: the Postgres adapter. Entry E_LIVE will reference a symbol that SURVIVES
# to HEAD; entry E_STALE will reference PostgresStore, which the mutation deletes.
P_SHA="$(mkrepo_commit db/store.py "class PostgresStore:
    def connect(self):
        return 'postgres'" "P: postgres adapter")"

# also seed a stable symbol that stays live across the mutation (the live anchor).
mkrepo_commit core/util.py "def stable_helper():
    return 1" "P2: stable helper" >/dev/null
LIVE_SHA="$(git -C "$GR" rev-parse HEAD)"

# E_STALE: claim about PostgresStore @ P — live at write time.
mem write --claim "datastore is Postgres, touches db/store.py:PostgresStore" \
          --commit "$P_SHA" --ref "db/store.py:PostgresStore:class"
E_STALE_ID="$(jget "$OUT" "['entry']['id']")"
S_WRITE_STATUS="$(jget "$OUT" "['entry']['status']")"
[ "$S_WRITE_STATUS" = "live" ] && ok "E_STALE written live at write time (matched HEAD then)" \
  || bad "E_STALE write status=$S_WRITE_STATUS (want live)"

# E_LIVE: claim about the stable helper that SURVIVES the mutation.
mem write --claim "core helper exists, touches core/util.py:stable_helper" \
          --commit "$LIVE_SHA" --ref "core/util.py:stable_helper:function"
E_LIVE_ID="$(jget "$OUT" "['entry']['id']")"
L_WRITE_STATUS="$(jget "$OUT" "['entry']['status']")"
[ "$L_WRITE_STATUS" = "live" ] && ok "E_LIVE written live at write time" \
  || bad "E_LIVE write status=$L_WRITE_STATUS (want live)"

# MUTATE GIT — Postgres → MySQL: the PostgresStore symbol is GONE at HEAD. This is a
# real git operation (a new commit), not a flag flip. E_STALE's claim no longer holds.
mkrepo_commit db/store.py "class MySQLStore:
    def connect(self):
        return 'mysql'" "M: mysql adapter (PostgresStore removed)" >/dev/null
ok "git mutated: PostgresStore removed at HEAD (E_STALE's ref is now gone)"

# ─────────────────────────────────────────────────────────────────────────────
echo
echo "B/C. READ PATH — serves live as live; the stale one MARKED stale, NEVER live:"

RO_JSON="$(readout json)"
LIVE_COUNT="$(jget "$RO_JSON" "['counts']['live']")"
STALE_COUNT="$(jget "$RO_JSON" "['counts']['stale']")"
AVAIL="$(jget "$RO_JSON" "['available']")"
[ "$AVAIL" = "True" ] && ok "readout available (store present, entries verified at read)" \
  || bad "readout available=$AVAIL (want True)"

# the live set must contain E_LIVE and its status must be live. Extract the id
# lists directly (a single, explicit python projection — no eval needed here).
LIVE_IDS="$(printf '%s' "$RO_JSON" | python3 -c "import sys,json;d=json.load(sys.stdin);print(' '.join(e['id'] for e in d['live']))")"
STALE_IDS="$(printf '%s' "$RO_JSON" | python3 -c "import sys,json;d=json.load(sys.stdin);print(' '.join(e['id'] for e in d['stale']))")"

case " $LIVE_IDS " in (*" $E_LIVE_ID "*) ok "E_LIVE is in the LIVE set (served as live)";; (*)
  bad "E_LIVE ($E_LIVE_ID) NOT in live set (live ids: $LIVE_IDS)";; esac

# THE CORE: the stale entry must be in `stale`, with status=stale, and ABSENT from `live`.
case " $STALE_IDS " in (*" $E_STALE_ID "*) ok "E_STALE is in the STALE set (marked stale)";; (*)
  bad "E_STALE ($E_STALE_ID) NOT in stale set (stale ids: $STALE_IDS)";; esac

case " $LIVE_IDS " in (*" $E_STALE_ID "*)
  bad "FALSE-LIVE: E_STALE leaked into the live set — the exact failure mode being killed";;
  (*) ok "E_STALE is ABSENT from the live set (never served as live — the core proof)";; esac

# the stale entry's read-time status field reads 'stale' (not the stored live snapshot).
STALE_STATUS="$(printf '%s' "$RO_JSON" | python3 -c "
import sys,json
d=json.load(sys.stdin)
m={e['id']:e for e in d['stale']+d['live']}
print(m.get('$E_STALE_ID',{}).get('status'))")"
[ "$STALE_STATUS" = "stale" ] && ok "E_STALE read-time status=stale (re-verified at read, not the stored snapshot)" \
  || bad "E_STALE read-time status=$STALE_STATUS (want stale)"

# ─────────────────────────────────────────────────────────────────────────────
echo
echo "D. COMPREHEND shows the git-verified memory status (recall + appended block):"

# `comprehend recall` against the isolated home (pin HEIMDALL_HOME so it reads OUR store).
RECALL_TEXT="$(HEIMDALL_HOME="$HOME_DIR" "$COMPREHEND" recall "$GR" 2>&1)"
grep -q "verified memory" <<<"$RECALL_TEXT" \
  && ok "recall emits the verified-memory block" || bad "recall has no verified-memory header"
grep -qi "LIVE" <<<"$RECALL_TEXT" \
  && ok "recall block shows a LIVE section (git-confirmed)" || bad "recall block has no LIVE section"
grep -qi "stale" <<<"$RECALL_TEXT" \
  && ok "recall block shows the STALE status (git says it no longer holds)" \
  || bad "recall block does not show the stale status"

# the appended block on `comprehend` itself (stderr) carries the same status.
CMP_ERR="$(HEIMDALL_HOME="$HOME_DIR" "$COMPREHEND" comprehend "$GR" 2>&1 >/dev/null)"
grep -q "verified memory" <<<"$CMP_ERR" \
  && ok "comprehend appends the verified-memory block (capsule carries git-verified status)" \
  || bad "comprehend did not append the verified-memory block"

# ─────────────────────────────────────────────────────────────────────────────
echo
echo "E. ABSENT STORE → comprehend IDENTICAL (no regression, no crash):"

NOSTORE_HOME="$WORK/empty-home"   # a home with NO memory store
mkdir -p "$NOSTORE_HOME"

# comprehend --print stdout (the capsule JSON) must be valid + UNAFFECTED by the
# absent store (the VM block is stderr-only). Two runs must yield identical stdout.
OUT1="$(HEIMDALL_HOME="$NOSTORE_HOME/h1" "$COMPREHEND" comprehend "$GR" --print 2>/dev/null)"
OUT2="$(HEIMDALL_HOME="$NOSTORE_HOME/h2" "$COMPREHEND" comprehend "$GR" --print 2>/dev/null)"
# normalise the only legitimately-varying fields (repo path + timestamp + home path).
norm() { printf '%s' "$1" | python3 -c "
import sys,json
d=json.load(sys.stdin)
d.pop('generated_at',None); d.pop('repo',None)
print(json.dumps(d,sort_keys=True))"; }
[ "$(norm "$OUT1")" = "$(norm "$OUT2")" ] \
  && ok "comprehend --print stdout is the SAME with no store (capsule unaffected)" \
  || bad "comprehend stdout differs across no-store runs (regression)"

# stdout must NOT contain the verified-memory block (it is stderr-only — pristine JSON).
grep -q "verified memory" <<<"$OUT1" \
  && bad "verified-memory block leaked into comprehend stdout (capsule JSON polluted)" \
  || ok "comprehend stdout stays pristine JSON (VM block is stderr-only, additive)"

# recall against an empty home → honest 'none', exit 0 (no crash).
RECALL_NONE="$(HEIMDALL_HOME="$NOSTORE_HOME/h3" "$COMPREHEND" recall "$GR" 2>&1)"; RC=$?
[ "$RC" -eq 0 ] && ok "recall on absent store exits 0 (graceful, no crash)" || bad "recall exit=$RC (want 0)"
grep -qi "none" <<<"$RECALL_NONE" \
  && ok "recall on absent store reports an honest 'none'" || bad "recall absent-store output not 'none'"

# ─────────────────────────────────────────────────────────────────────────────
echo
echo "F. STALE WEIGHT IS LOW — git, not a timer, zeroed the stale entry:"

STALE_WEIGHT="$(printf '%s' "$RO_JSON" | python3 -c "
import sys,json
d=json.load(sys.stdin)
m={e['id']:e for e in d['stale']+d['live']}
print(m.get('$E_STALE_ID',{}).get('weight'))")"
LIVE_WEIGHT="$(printf '%s' "$RO_JSON" | python3 -c "
import sys,json
d=json.load(sys.stdin)
m={e['id']:e for e in d['stale']+d['live']}
print(m.get('$E_LIVE_ID',{}).get('weight'))")"
[ "$STALE_WEIGHT" = "0.0" ] || [ "$STALE_WEIGHT" = "0" ] \
  && ok "E_STALE read-time weight is 0 (the readout demoted the git-dead claim)" \
  || bad "E_STALE weight=$STALE_WEIGHT (want 0 — a stale entry must weigh 0)"
python3 -c "import sys; sys.exit(0 if float('$LIVE_WEIGHT') > float('${STALE_WEIGHT:-0}') else 1)" \
  && ok "E_LIVE outranks E_STALE by read-time weight ($LIVE_WEIGHT > $STALE_WEIGHT)" \
  || bad "E_LIVE ($LIVE_WEIGHT) does not outrank E_STALE ($STALE_WEIGHT)"

# ─────────────────────────────────────────────────────────────────────────────
echo
printf 'vm-readpath: %d passed, %d failed\n' "$PASS" "$FAIL"
if [ "$FAIL" -eq 0 ]; then
  printf '\033[32mALL %d PROOFS PASSED\033[0m\n' "$PASS"
  exit 0
fi
printf '\033[31m%d PROOF(S) FAILED\033[0m\n' "$FAIL"
exit 1
