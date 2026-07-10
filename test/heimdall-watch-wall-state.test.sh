#!/usr/bin/env bash
# heimdall-watch-wall-state.test.sh — FALSIFIER: the WALL renders ACTIVE vs IDLE distinctly.
#
# THE MODEL (wave 1 render side). The server now derives a per-dev `state` ("active"/"idle") on
# every roster view (cp_presence.roster). The `hmd watch` WALL must render those two states
# DISTINCTLY — ● for an active teammate, ○ for an idle one — so a glance at the wall separates
# "working right now" from "here but idle". A legacy roster row with NO `state` key falls back
# to a verdict-based guess (watching/idle => idle, else active), so old caches still render.
#
# RED-WITHOUT-FIX: render_wall currently emits the same glyph regardless of state, and there is
# no member_state() helper. The proofs assert the ● (active) and ○ (idle) badges appear on the
# right rows and that member_state() maps the state field + the verdict fallback — all absent on
# the pre-fix renderer => the greps FAIL.
#
# LOCAL-ONLY (mirrors heimdall-watch): imports bin/lib/watch_data.py, renders in-process, no
# network, no textual. Exit 0 = every proof holds.

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SELF_DIR/.." && pwd)"
LIB="$REPO/bin/lib"
export LIB REPO
[ -f "$LIB/watch_data.py" ] || { echo "FATAL: watch_data.py missing" >&2; exit 2; }

PY="$(command -v python3 || command -v python || true)"
[ -n "$PY" ] || { echo "FATAL: python not found" >&2; exit 2; }

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf "  \033[32mPASS\033[0m %s\n" "$1"; }
bad() { FAIL=$((FAIL+1)); printf "  \033[31mFAIL\033[0m %s\n" "$1"; }

echo "============================================================"
echo "WATCH WALL-STATE falsifier — ● active vs ○ idle render"
echo "============================================================"
echo

OUT="$("$PY" - <<'PYEOF' 2>/dev/null
import importlib.util, os
spec = importlib.util.spec_from_file_location("watch_data", os.path.join(os.environ["LIB"], "watch_data.py"))
wd = importlib.util.module_from_spec(spec); spec.loader.exec_module(wd)

members = [
    {"handle": "act",  "haid": "haid:a", "verdict": "PASS",     "state": "active"},
    {"handle": "idl",  "haid": "haid:b", "verdict": "IDLE",     "state": "idle"},
    # legacy row: NO state key -> fall back to the verdict (watching => idle).
    {"handle": "leg",  "haid": "haid:c", "verdict": "watching"},
    # legacy row: NO state key, a live verdict => active fallback.
    {"handle": "legw", "haid": "haid:d", "verdict": "working"},
]
lines = wd.render_wall(members, caps=None, sig=None)
# print each row prefixed by its handle so the harness can grep per-row.
for ln in lines:
    print(ln)
print("---STATES---")
print("act=%s"  % wd.member_state(members[0]))
print("idl=%s"  % wd.member_state(members[1]))
print("leg=%s"  % wd.member_state(members[2]))
print("legw=%s" % wd.member_state(members[3]))
PYEOF
)"

# The active row carries ● ; the idle row carries ○.
act_line="$(printf '%s\n' "$OUT" | grep 'act ' | head -1)"
idl_line="$(printf '%s\n' "$OUT" | grep 'idl ' | head -1)"
printf '%s' "$act_line" | grep -q '●' \
  && ok "A active teammate row renders the ● active badge" \
  || bad "A active row missing ● (line: $act_line)"
printf '%s' "$idl_line" | grep -q '○' \
  && ok "B idle teammate row renders the ○ idle badge" \
  || bad "B idle row missing ○ (line: $idl_line)"

# Distinctness: the active glyph and idle glyph are NOT the same character.
if printf '%s' "$act_line" | grep -q '●' && ! printf '%s' "$act_line" | grep -q '○'; then
  ok "C active vs idle are rendered DISTINCTLY (● != ○)"
else
  bad "C active row is not distinct from idle (line: $act_line)"
fi

# member_state(): the state field wins; a legacy row falls back to the verdict.
printf '%s' "$OUT" | grep -q 'act=active'  && ok "D member_state honors state=active" || bad "D state=active not honored"
printf '%s' "$OUT" | grep -q 'idl=idle'    && ok "E member_state honors state=idle"   || bad "E state=idle not honored"
printf '%s' "$OUT" | grep -q 'leg=idle'    && ok "F legacy row (no state, verdict=watching) => idle fallback" || bad "F watching fallback wrong"
printf '%s' "$OUT" | grep -q 'legw=active' && ok "G legacy row (no state, verdict=working) => active fallback" || bad "G working fallback wrong"

echo
echo "============================================================"
printf "heimdall-watch-wall-state: %d passed, %d failed\n" "$PASS" "$FAIL"
echo "============================================================"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
