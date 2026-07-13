#!/usr/bin/env bash
# test/heimdall-status-json.test.sh — acceptance for the LEDGER STATUS PRODUCER:
# bin/heimdall-status-json writes ~/.heimdall/ledger/status.json for the statusline
# (HMD Statusline Spec v1 §6) from REAL sources, plus bin/heimdall-gate-run's minimal
# per-gate recording that feeds it.
#
# Hermetic: every source is driven through an env seam — the roster JSON is injected
# (no network, no presence beat), the verdict file is a throwaway fixture, the keeper
# pidfile dir is a temp dir, and the output path is a temp file. Nothing here touches
# a live control plane, a real keeper, or the user's ~/.heimdall.
#
# FALSIFIABLE claims proven:
#   (1) SCHEMA — the writer emits exactly {daemon, gates[], verdict{}, team[]}, valid JSON.
#   (2) DAEMON LIVENESS is REAL — a live keeper pidfile => daemon "watching"; a dead/absent
#       pidfile => daemon "down" (not fabricated: a bogus pid reads down).
#   (3) GATES are READ from the recorded verdict.json (.gates), never invented — the exact
#       ids/states/details injected come back out.
#   (4) VERDICT maps the recorded overall verdict (pass->GENERALIZES / deny->BLOCKED /
#       absent->PENDING).
#   (5) TEAM maps the REAL roster: user<-handle, sigil<-glyph_color hex (matches the sigil
#       core), state<-roster state, ts reconstructed from age_seconds. Branch honest-null
#       (presence does not broadcast a branch).
#   (6) HONEST-EMPTY / NO-CRASH — daemon down + empty roster + no verdict yields a VALID file
#       (daemon:"down", gates:[], team:[], verdict pending), exit 0, never a partial/garbage file.
#   (7) ATOMIC — after a write no .tmp sibling is left behind; the output is always complete JSON.
#   (8) gate-run RECORDS gates[] — a real (hermetic) gate-run in a throwaway repo persists a
#       verdict.json that now carries a gates array (empty when no oracle/corpus gate ran).
#   (9) SYNTAX — bash -n on the writer, py_compile of the sigil core it imports.

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
WRITER="$ROOT/bin/heimdall-status-json"
GATE_RUN="$ROOT/bin/heimdall-gate-run"
SIGIL_PY="$ROOT/sentinels/hmd_sigil.py"

PASS=0
FAIL=0
ok()  { PASS=$((PASS+1)); printf "  \033[32mPASS\033[0m %s\n" "$1"; }
bad() { FAIL=$((FAIL+1)); printf "  \033[31mFAIL\033[0m %s\n" "$1"; }

command -v jq >/dev/null 2>&1 || { echo "FATAL: jq required" >&2; exit 2; }
PY="$(command -v python3 || command -v python)"
[ -x "$WRITER" ]   || { echo "FATAL: $WRITER not executable" >&2; exit 2; }
[ -x "$GATE_RUN" ] || { echo "FATAL: $GATE_RUN not executable" >&2; exit 2; }

WORK="$(mktemp -d -t "status-json-test.$(printf 'X%.0s' 1 2 3 4 5 6)")"
trap 'rm -rf "$WORK"' EXIT

# The deterministic sigil hue for a seed, formatted as the writer formats it (#RRGGBB).
sigil_hex() {
  SIGIL_CORE_DIR="$(dirname "$SIGIL_PY")" "$PY" - "$1" <<'PYEOF'
import sys, os
sys.path.insert(0, os.environ["SIGIL_CORE_DIR"])
import hmd_sigil
r, g, b = hmd_sigil.glyph_color(sys.argv[1])
print("#%02X%02X%02X" % (r, g, b))
PYEOF
}

# ── (1)(3)(4)(5) full happy path: live daemon, gates recorded, real roster ────
echo "-- (1)(3)(4)(5) schema + gates + verdict + team from real sources ------------"
KDIR="$WORK/keeper"; mkdir -p "$KDIR"
# a LIVE keeper: a pidfile naming a process that is actually alive (this shell's bg sleep).
sleep 60 & LIVE_PID=$!
printf '%s\n' "$LIVE_PID" > "$KDIR/proj__sess.pid"

VFILE="$WORK/verdict.json"
jq -n '{verdict:"pass", phase:"pre-push", ts:"2026-07-13T00:00:00Z", gate:"", file:"cards.ts",
        reasons:[], gates:[{id:"secrets",state:"pass",detail:"0"},
                           {id:"tests",state:"pass",detail:"41/41"},
                           {id:"designmatch",state:"pass",detail:".91"}]}' > "$VFILE"

HAID="haid:mira.9f3c1a"
NOW=1752403600
AGE=600
ROSTER="$(jq -cn --arg h "$HAID" --argjson age "$AGE" \
  '[{haid:$h, handle:"mira", verdict:"pass", file:"gate.ts", age_seconds:$age, state:"active"}]')"

OUT="$WORK/status.json"
env HMD_STATUS_OUT="$OUT" \
    HEIMDALL_KEEPER_DIR="$KDIR" \
    HMD_STATUS_VERDICT_FILE="$VFILE" \
    HMD_STATUS_ROSTER_JSON="$ROSTER" \
    HMD_STATUS_NOW="$NOW" \
    "$WRITER" >/dev/null 2>&1
rc=$?
[ "$rc" -eq 0 ] && ok "writer exits 0 on the happy path" || bad "writer exit $rc"
[ -f "$OUT" ] && jq -e . "$OUT" >/dev/null 2>&1 && ok "output is a single valid JSON file" || bad "output missing/invalid"

# schema — exactly the four top-level keys the statusline reads
KEYS="$(jq -r 'keys | join(",")' "$OUT" 2>/dev/null)"
[ "$KEYS" = "daemon,gates,team,verdict" ] && ok "schema: top-level keys = daemon,gates,team,verdict" || bad "schema keys wrong: $KEYS"

[ "$(jq -r '.daemon' "$OUT")" = "watching" ] && ok "(2) live keeper -> daemon watching" || bad "daemon not watching ($(jq -r '.daemon' "$OUT"))"

# (3) gates read verbatim from the recorded verdict.json
G="$(jq -c '.gates' "$OUT")"
[ "$(jq -r '.gates | length' "$OUT")" = "3" ] && ok "(3) gates length = 3 (from verdict.json)" || bad "gates length $(jq -r '.gates|length' "$OUT")"
[ "$(jq -r '.gates[1].id' "$OUT")" = "tests" ] && [ "$(jq -r '.gates[1].detail' "$OUT")" = "41/41" ] \
  && ok "(3) gate[1] = tests 41/41 (verbatim)" || bad "gate[1] wrong: $G"
[ "$(jq -r '.gates[2].state' "$OUT")" = "pass" ] && ok "(3) gate states preserved" || bad "gate state wrong"

# (4) verdict mapping pass -> GENERALIZES
[ "$(jq -r '.verdict.state' "$OUT")" = "pass" ] && [ "$(jq -r '.verdict.label' "$OUT")" = "GENERALIZES" ] \
  && ok "(4) verdict pass -> {pass, GENERALIZES}" || bad "verdict mapping wrong: $(jq -c .verdict "$OUT")"

# (5) team mapping
[ "$(jq -r '.team | length' "$OUT")" = "1" ] && ok "(5) team length = 1 (from roster)" || bad "team length wrong"
[ "$(jq -r '.team[0].user' "$OUT")" = "mira" ] && ok "(5) team user <- handle" || bad "team user wrong"
[ "$(jq -r '.team[0].state' "$OUT")" = "active" ] && ok "(5) team state <- roster state" || bad "team state wrong"
# ts reconstructed from age_seconds: now - age
[ "$(jq -r '.team[0].ts' "$OUT")" = "$((NOW - AGE))" ] && ok "(5) team ts reconstructed (now - age_seconds)" || bad "team ts wrong: $(jq -r '.team[0].ts' "$OUT")"
# sigil hex matches the sigil core's glyph_color for the HAID (honest, deterministic)
EXP_HEX="$(sigil_hex "$HAID")"
GOT_HEX="$(jq -r '.team[0].sigil' "$OUT")"
[ "$GOT_HEX" = "$EXP_HEX" ] && ok "(5) team sigil = glyph_color hex ($EXP_HEX)" || bad "team sigil $GOT_HEX != $EXP_HEX"
# branch is honest-null (presence does not broadcast a branch)
[ "$(jq -r '.team[0].branch' "$OUT")" = "null" ] && ok "(5) team branch honest-null" || bad "team branch not null"

# (7) atomic: no .tmp sibling left behind
if ls "$WORK"/status.json.tmp* >/dev/null 2>&1; then bad "(7) a .tmp sibling was left behind"; else ok "(7) atomic: no .tmp file left"; fi

{ kill "$LIVE_PID" && wait "$LIVE_PID"; } 2>/dev/null || true

# ── (2) daemon down: a bogus (dead) pid must read down, not watching ──────────
echo "-- (2) daemon liveness is real (dead pid -> down) ---------------------------"
KDIR2="$WORK/keeper2"; mkdir -p "$KDIR2"
printf '%s\n' "999999" > "$KDIR2/dead.pid"   # a pid that is virtually never alive
OUT2="$WORK/status2.json"
env HMD_STATUS_OUT="$OUT2" HEIMDALL_KEEPER_DIR="$KDIR2" \
    HMD_STATUS_VERDICT_FILE="$VFILE" HMD_STATUS_ROSTER_JSON='[]' HMD_STATUS_NOW="$NOW" \
    "$WRITER" >/dev/null 2>&1
[ "$(jq -r '.daemon' "$OUT2")" = "down" ] && ok "(2) dead keeper pid -> daemon down" || bad "(2) dead pid not down"

# ── (6) honest-empty / no-crash: down + empty roster + NO verdict file ────────
echo "-- (6) honest-empty + no-crash (down, empty roster, no verdict) --------------"
KDIR3="$WORK/keeper3"; mkdir -p "$KDIR3"   # empty: no pidfiles at all
OUT3="$WORK/status3.json"
env HMD_STATUS_OUT="$OUT3" HEIMDALL_KEEPER_DIR="$KDIR3" \
    HMD_STATUS_VERDICT_FILE="$WORK/does-not-exist.json" HMD_STATUS_ROSTER_JSON='[]' HMD_STATUS_NOW="$NOW" \
    "$WRITER" >/dev/null 2>&1
rc3=$?
[ "$rc3" -eq 0 ] && ok "(6) exits 0 with empty sources" || bad "(6) exit $rc3"
if jq -e . "$OUT3" >/dev/null 2>&1; then ok "(6) valid JSON with empty sources"; else bad "(6) invalid JSON"; fi
[ "$(jq -r '.daemon' "$OUT3")" = "down" ] && ok "(6) daemon down" || bad "(6) daemon not down"
[ "$(jq -c '.gates' "$OUT3")" = "[]" ] && ok "(6) gates honest-empty []" || bad "(6) gates not []"
[ "$(jq -c '.team' "$OUT3")" = "[]" ] && ok "(6) team honest-empty []" || bad "(6) team not []"
[ "$(jq -r '.verdict.state' "$OUT3")" = "pending" ] && ok "(6) verdict pending (no gated run yet)" || bad "(6) verdict not pending"

# ── (6b) a malformed roster must degrade to [] (never crash / never fabricate) ─
echo "-- (6b) malformed roster degrades to empty team -----------------------------"
OUT4="$WORK/status4.json"
env HMD_STATUS_OUT="$OUT4" HEIMDALL_KEEPER_DIR="$KDIR3" \
    HMD_STATUS_VERDICT_FILE="$VFILE" HMD_STATUS_ROSTER_JSON='not json at all {' HMD_STATUS_NOW="$NOW" \
    "$WRITER" >/dev/null 2>&1
rc4=$?
[ "$rc4" -eq 0 ] && jq -e . "$OUT4" >/dev/null 2>&1 && [ "$(jq -c '.team' "$OUT4")" = "[]" ] \
  && ok "(6b) malformed roster -> valid file, empty team" || bad "(6b) malformed roster not handled"

# ── (8) gate-run records a gates[] array (hermetic throwaway repo, no oracles) ─
echo "-- (8) gate-run persists a gates[] array in verdict.json --------------------"
REPO="$WORK/repo"; mkdir -p "$REPO"
git -C "$REPO" init -q
git -C "$REPO" config user.email "test@runheimdall.dev"
git -C "$REPO" config user.name "test"
printf 'x\n' > "$REPO/a.txt"; git -C "$REPO" add -A; git -C "$REPO" commit -qm seed
( cd "$REPO" && "$GATE_RUN" --phase pre-commit >/dev/null 2>&1 )
GV="$REPO/.heimdall/verdict.json"
[ -f "$GV" ] && ok "(8) gate-run wrote verdict.json" || bad "(8) no verdict.json"
if jq -e 'has("gates")' "$GV" >/dev/null 2>&1; then ok "(8) verdict.json carries a gates key"; else bad "(8) no gates key"; fi
[ "$(jq -r '.gates | type' "$GV")" = "array" ] && ok "(8) gates is an array (empty with no oracle/corpus gate)" || bad "(8) gates not an array"
# no oracle/corpus in a bare repo -> honest empty gates + pass verdict
[ "$(jq -r '.verdict' "$GV")" = "pass" ] && ok "(8) bare repo -> verdict pass (no gate red)" || bad "(8) verdict not pass"

# The writer then reads THAT gate-run output end-to-end (no fabrication).
OUT5="$WORK/status5.json"
env HMD_STATUS_OUT="$OUT5" HEIMDALL_KEEPER_DIR="$KDIR3" \
    HMD_STATUS_VERDICT_FILE="$GV" HMD_STATUS_ROSTER_JSON='[]' HMD_STATUS_NOW="$NOW" \
    "$WRITER" >/dev/null 2>&1
[ "$(jq -r '.verdict.state' "$OUT5")" = "pass" ] && [ "$(jq -c '.gates' "$OUT5")" = "[]" ] \
  && ok "(8) writer consumes real gate-run output (pass, gates [])" || bad "(8) end-to-end read failed"

# ── (9) syntax ───────────────────────────────────────────────────────────────
echo "-- (9) syntax ---------------------------------------------------------------"
bash -n "$WRITER" 2>/dev/null && ok "(9) bash -n writer clean" || bad "(9) bash -n writer FAILED"
bash -n "$GATE_RUN" 2>/dev/null && ok "(9) bash -n gate-run clean" || bad "(9) bash -n gate-run FAILED"
"$PY" -m py_compile "$SIGIL_PY" 2>/dev/null && ok "(9) py_compile sigil core clean" || bad "(9) py_compile FAILED"

echo ""
echo "  ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ] || exit 1
