#!/usr/bin/env bash
# test/symbol-graph.test.sh — acceptance for bin/heimdall-graph, the symbol-graph
# navigator that lets an agent answer "who calls this / what breaks if I change
# it" without reading whole files.
#
# The load-bearing property here is NOT coverage, it is FALSIFIABILITY. A graph
# that reports a caller no matter what you feed it is a false green: an agent
# would run `impact` and conclude a change is safe when it is not. So every
# edge-finding assertion below is run TWICE — once with the caller present
# (must be found) and once with that exact caller deleted (must NOT be found).
# A query path that cannot go dark is not evidence.
#
# Covered:
#   (a) index builds; --json is well-formed; stats are real
#   (b) FALSIFIABILITY, python: seed caller → found; delete caller → gone
#   (c) FALSIFIABILITY, shell:  seed caller → found; delete caller → gone
#   (d) def / outline report REAL line ranges (checked against real repo files)
#   (e) refs reports every site as file:line
#   (f) callees = one hop out, resolved vs external
#   (g) impact = TRANSITIVE callers, and carries the honest-limitation notice
#       (worded "known callers", naming what the index cannot see)
#   (h) result cap: "N more" indicator, and --limit 0 returns everything
#   (i) freshness: an edit is never answered from a stale index
#   (j) unknown symbol / unknown file → clean exit 4, no crash, no fake answer
#   (k) HEIMDALL_HOME relocates the index cache (no baked path)

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
CMD="$ROOT/bin/heimdall-graph"

PASS=0
FAIL=0
ok()  { PASS=$((PASS+1)); printf "  \033[32mPASS\033[0m %s\n" "$1"; }
bad() { FAIL=$((FAIL+1)); printf "  \033[31mFAIL\033[0m %s\n" "$1"; }

command -v jq >/dev/null 2>&1 || { echo "FATAL: jq required for the JSON-shape assertions" >&2; exit 2; }
[ -x "$CMD" ] || { echo "FATAL: $CMD not executable" >&2; exit 2; }

WORK="$(mktemp -d -t "symgraph-test.$(printf 'X%.0s' 1 2 3 4 5 6)")"
trap 'rm -rf "$WORK"' EXIT

REPO="$WORK/proj"
mkdir -p "$REPO/lib" "$REPO/bin"
# The index cache must live inside the temp tree, never in the developer's repo.
export HEIMDALL_HOME="$WORK/home"

# ── seed a repo with a KNOWN call graph ───────────────────────────────────────
# python:  entry_point -> middle_hop -> leaf_target
#          stray_caller -> leaf_target      (this one gets deleted in (b))
cat > "$REPO/lib/core.py" <<'EOF'
"""Seeded python module with a hand-known call graph."""


def leaf_target(x):
    return x + 1


def middle_hop(x):
    return leaf_target(x) * 2


def entry_point(x):
    return middle_hop(x)


def stray_caller(x):
    return leaf_target(x)


class Holder:
    def method_caller(self, x):
        return middle_hop(x)
EOF

# shell:  sh_entry -> sh_middle -> sh_leaf
#         sh_stray -> sh_leaf              (deleted in (c))
cat > "$REPO/bin/tool.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

sh_leaf() {
  printf 'leaf %s\n' "$1"
}

sh_middle() {
  sh_leaf "$1"
}

sh_entry() {
  sh_middle "$1"
}

sh_stray() {
  sh_leaf "stray"
}

sh_entry "$@"
EOF
chmod +x "$REPO/bin/tool.sh"

# ── (a) index builds, --json well-formed, stats real ──────────────────────────
IDX_JSON="$("$CMD" index --repo "$REPO" --json 2>/dev/null || true)"
if printf '%s' "$IDX_JSON" | jq -e . >/dev/null 2>&1 \
   && printf '%s' "$IDX_JSON" | jq -e '.stats.files >= 2 and .stats.symbols >= 8 and .stats.edges >= 4' >/dev/null 2>&1 \
   && printf '%s' "$IDX_JSON" | jq -e '.languages.python and .languages.shell' >/dev/null 2>&1 \
   && printf '%s' "$IDX_JSON" | jq -e '.stamp | type == "string" and (length > 0)' >/dev/null 2>&1; then
  ok "(a) index builds over python+shell, --json well-formed with real stats + a repo-state stamp"
else
  bad "(a) index/--json malformed"; printf '%s\n' "$IDX_JSON" | head -20
fi

# ── (b) FALSIFIABILITY, python ────────────────────────────────────────────────
# stray_caller calls leaf_target. Present → must be reported. Deleted → must not.
CALLERS_BEFORE="$("$CMD" callers leaf_target --repo "$REPO" 2>/dev/null || true)"
HAS_STRAY_BEFORE=no
printf '%s' "$CALLERS_BEFORE" | grep -q 'stray_caller' && HAS_STRAY_BEFORE=yes

python3 - "$REPO/lib/core.py" <<'PYEOF'
import re, sys
p = sys.argv[1]
src = open(p).read()
out = src.replace('def stray_caller(x):\n    return leaf_target(x)\n\n\n', '')
assert out != src, "fixture surgery failed — stray_caller block not found"
open(p, 'w').write(out)
PYEOF

CALLERS_AFTER="$("$CMD" callers leaf_target --repo "$REPO" 2>/dev/null || true)"
HAS_STRAY_AFTER=no
printf '%s' "$CALLERS_AFTER" | grep -q 'stray_caller' && HAS_STRAY_AFTER=yes
# middle_hop still calls leaf_target — the query must stay ALIVE, not go blank.
STILL_ALIVE=no
printf '%s' "$CALLERS_AFTER" | grep -q 'middle_hop' && STILL_ALIVE=yes

if [ "$HAS_STRAY_BEFORE" = yes ] && [ "$HAS_STRAY_AFTER" = no ] && [ "$STILL_ALIVE" = yes ]; then
  ok "(b) FALSIFIABLE (python): stray_caller found while present, GONE once deleted, middle_hop still found"
else
  bad "(b) python falsifiability broken: before=$HAS_STRAY_BEFORE after=$HAS_STRAY_AFTER alive=$STILL_ALIVE"
  printf 'before:\n%s\nafter:\n%s\n' "$CALLERS_BEFORE" "$CALLERS_AFTER"
fi

# ── (c) FALSIFIABILITY, shell ─────────────────────────────────────────────────
SH_BEFORE="$("$CMD" callers sh_leaf --repo "$REPO" 2>/dev/null || true)"
SH_HAS_STRAY_BEFORE=no
printf '%s' "$SH_BEFORE" | grep -q 'sh_stray' && SH_HAS_STRAY_BEFORE=yes

python3 - "$REPO/bin/tool.sh" <<'PYEOF'
import sys
p = sys.argv[1]
src = open(p).read()
out = src.replace('sh_stray() {\n  sh_leaf "stray"\n}\n\n', '')
assert out != src, "fixture surgery failed — sh_stray block not found"
open(p, 'w').write(out)
PYEOF

SH_AFTER="$("$CMD" callers sh_leaf --repo "$REPO" 2>/dev/null || true)"
SH_HAS_STRAY_AFTER=no
printf '%s' "$SH_AFTER" | grep -q 'sh_stray' && SH_HAS_STRAY_AFTER=yes
SH_STILL_ALIVE=no
printf '%s' "$SH_AFTER" | grep -q 'sh_middle' && SH_STILL_ALIVE=yes

if [ "$SH_HAS_STRAY_BEFORE" = yes ] && [ "$SH_HAS_STRAY_AFTER" = no ] && [ "$SH_STILL_ALIVE" = yes ]; then
  ok "(c) FALSIFIABLE (shell): sh_stray found while present, GONE once deleted, sh_middle still found"
else
  bad "(c) shell falsifiability broken: before=$SH_HAS_STRAY_BEFORE after=$SH_HAS_STRAY_AFTER alive=$SH_STILL_ALIVE"
  printf 'before:\n%s\nafter:\n%s\n' "$SH_BEFORE" "$SH_AFTER"
fi

# ── (d) def / outline report REAL line ranges — checked against the REAL repo ──
# Precision proof: the reported span must match what grep/sed say is actually
# there, on this repo's own source, not a synthetic fixture.
DEF_OUT="$("$CMD" def pad_or_truncate --repo "$ROOT" 2>/dev/null || true)"
DEF_SPAN="$(printf '%s' "$DEF_OUT" | grep -o 'sentinels/hmd_layout\.py:[0-9]*-[0-9]*' | head -1)"
DEF_START="$(printf '%s' "$DEF_SPAN" | sed 's/.*://; s/-.*//')"
DEF_END="$(printf '%s' "$DEF_SPAN" | sed 's/.*-//')"
REAL_START="$(grep -n '^def pad_or_truncate' "$ROOT/sentinels/hmd_layout.py" | head -1 | cut -d: -f1)"
# The line AT the reported start must be the def; the line after the reported
# end must NOT still be inside the function (i.e. it is column-0 or EOF).
LINE_AT_START="$(sed -n "${DEF_START}p" "$ROOT/sentinels/hmd_layout.py" 2>/dev/null || true)"
LINE_AFTER_END="$(sed -n "$((DEF_END + 1))p" "$ROOT/sentinels/hmd_layout.py" 2>/dev/null || true)"
SPAN_OK=no
case "$LINE_AT_START" in
  "def pad_or_truncate"*)
    case "$LINE_AFTER_END" in
      " "*|$'\t'*) SPAN_OK=no ;;
      *)           SPAN_OK=yes ;;
    esac
    ;;
esac
SH_DEF="$("$CMD" def acquire_lock --repo "$ROOT" 2>/dev/null || true)"
SH_DEF_LINE="$(printf '%s' "$SH_DEF" | grep -o 'bin/heimdall-state:[0-9]*' | head -1 | sed 's/.*://')"
SH_REAL_LINE="$(grep -n '^acquire_lock() {' "$ROOT/bin/heimdall-state" | head -1 | cut -d: -f1)"

if [ -n "$DEF_START" ] && [ "$DEF_START" = "$REAL_START" ] && [ "$SPAN_OK" = yes ] \
   && [ -n "$SH_DEF_LINE" ] && [ "$SH_DEF_LINE" = "$SH_REAL_LINE" ]; then
  ok "(d) def spans are REAL on this repo: python ${DEF_SPAN}, shell bin/heimdall-state:${SH_DEF_LINE} (verified vs grep/sed)"
else
  bad "(d) def spans wrong: py span=$DEF_SPAN (grep says start=$REAL_START, span_ok=$SPAN_OK) sh=$SH_DEF_LINE (grep says $SH_REAL_LINE)"
  printf '%s\n%s\n' "$DEF_OUT" "$SH_DEF"
fi

# outline must list a file's symbols with ranges and NOT dump the file body.
OUTLINE="$("$CMD" outline sentinels/hmd_layout.py --repo "$ROOT" --limit 0 2>/dev/null || true)"
OUTLINE_N="$(printf '%s\n' "$OUTLINE" | grep -c '^[0-9]*-[0-9]*' || true)"
REAL_DEFS="$(grep -c '^\(def \|class \)' "$ROOT/sentinels/hmd_layout.py" || true)"
if [ "$OUTLINE_N" -ge "$REAL_DEFS" ] && printf '%s' "$OUTLINE" | grep -q 'pad_or_truncate'; then
  ok "(d2) outline lists $OUTLINE_N symbols with line ranges (>= $REAL_DEFS top-level defs) instead of the file body"
else
  bad "(d2) outline wrong: got $OUTLINE_N ranges, expected >= $REAL_DEFS"; printf '%s\n' "$OUTLINE" | head -10
fi

# ── (e) refs reports every site as file:line ──────────────────────────────────
REFS="$("$CMD" refs leaf_target --repo "$REPO" --limit 0 2>/dev/null || true)"
REFS_N="$(printf '%s\n' "$REFS" | grep -c 'lib/core\.py:[0-9]' || true)"
# after (b) removed stray_caller there are 2 sites left: the def and middle_hop's call
if [ "$REFS_N" -ge 1 ] && printf '%s' "$REFS" | grep -qE 'lib/core\.py:[0-9]+'; then
  ok "(e) refs reports $REFS_N site(s) as file:line"
else
  bad "(e) refs did not report file:line sites"; printf '%s\n' "$REFS" | head -10
fi

# ── (f) callees = one hop out, resolved vs external ───────────────────────────
CALLEES="$("$CMD" callees middle_hop --repo "$REPO" --limit 0 2>/dev/null || true)"
if printf '%s' "$CALLEES" | grep -q 'leaf_target'; then
  ok "(f) callees middle_hop → leaf_target (one hop out)"
else
  bad "(f) callees missed the direct callee"; printf '%s\n' "$CALLEES" | head -10
fi

# ── (g) impact is TRANSITIVE and carries the honest-limitation notice ─────────
IMPACT="$("$CMD" impact leaf_target --repo "$REPO" --limit 0 2>/dev/null || true)"
HAS_DIRECT=no;  printf '%s' "$IMPACT" | grep -q 'middle_hop'   && HAS_DIRECT=yes
HAS_TRANS=no;   printf '%s' "$IMPACT" | grep -q 'entry_point'  && HAS_TRANS=yes
HAS_TRANS2=no;  printf '%s' "$IMPACT" | grep -q 'method_caller' && HAS_TRANS2=yes
# the warning must reach the agent making the decision — in the output, not just docs
HAS_KNOWN=no;   printf '%s' "$IMPACT" | grep -qi 'known callers' && HAS_KNOWN=yes
HAS_BLIND=no
if printf '%s' "$IMPACT" | grep -qi 'dynamic dispatch' \
   && printf '%s' "$IMPACT" | grep -qi 'eval' \
   && printf '%s' "$IMPACT" | grep -qi 'not exhaustive'; then
  HAS_BLIND=yes
fi
if [ "$HAS_DIRECT" = yes ] && [ "$HAS_TRANS" = yes ] && [ "$HAS_TRANS2" = yes ] \
   && [ "$HAS_KNOWN" = yes ] && [ "$HAS_BLIND" = yes ]; then
  ok "(g) impact is transitive (leaf←middle←entry, leaf←middle←method_caller) AND prints 'known callers' + named blind spots"
else
  bad "(g) impact wrong: direct=$HAS_DIRECT trans=$HAS_TRANS trans2=$HAS_TRANS2 known=$HAS_KNOWN blind=$HAS_BLIND"
  printf '%s\n' "$IMPACT"
fi

# impact must ALSO be falsifiable: delete the transitive hop, lose the reach.
cp "$REPO/lib/core.py" "$WORK/core.py.bak"
python3 - "$REPO/lib/core.py" <<'PYEOF'
import sys
p = sys.argv[1]
src = open(p).read()
out = src.replace('def entry_point(x):\n    return middle_hop(x)\n\n\n', '')
assert out != src, "fixture surgery failed — entry_point block not found"
open(p, 'w').write(out)
PYEOF
IMPACT2="$("$CMD" impact leaf_target --repo "$REPO" --limit 0 2>/dev/null || true)"
GONE=no; printf '%s' "$IMPACT2" | grep -q 'entry_point' || GONE=yes
KEPT=no; printf '%s' "$IMPACT2" | grep -q 'middle_hop'  && KEPT=yes
if [ "$GONE" = yes ] && [ "$KEPT" = yes ]; then
  ok "(g2) impact is FALSIFIABLE: deleting entry_point drops it from the transitive set, middle_hop survives"
else
  bad "(g2) impact not falsifiable: gone=$GONE kept=$KEPT"; printf '%s\n' "$IMPACT2"
fi
cp "$WORK/core.py.bak" "$REPO/lib/core.py"

# ── (h) result cap: "N more" indicator, --limit 0 returns everything ──────────
python3 - "$REPO/lib/many.py" <<'PYEOF'
import sys
p = sys.argv[1]
lines = ["from core import leaf_target", ""]
for i in range(50):
    lines.append("def caller_%02d(x):" % i)
    lines.append("    return leaf_target(x)")
    lines.append("")
open(p, "w").write("\n".join(lines) + "\n")
PYEOF
CAPPED="$("$CMD" callers leaf_target --repo "$REPO" 2>/dev/null || true)"
CAPPED_N="$(printf '%s\n' "$CAPPED" | grep -c 'caller_' || true)"
UNCAPPED="$("$CMD" callers leaf_target --repo "$REPO" --limit 0 2>/dev/null || true)"
UNCAPPED_N="$(printf '%s\n' "$UNCAPPED" | grep -c 'caller_' || true)"
HAS_MORE=no
printf '%s' "$CAPPED" | grep -qE '\+[0-9]+ more \(use --limit 0 for all\)' && HAS_MORE=yes
SMALL_HAS_MORE=yes
printf '%s' "$UNCAPPED" | grep -q 'more (use --limit 0 for all)' || SMALL_HAS_MORE=no
if [ "$CAPPED_N" -lt "$UNCAPPED_N" ] && [ "$UNCAPPED_N" -ge 50 ] \
   && [ "$HAS_MORE" = yes ] && [ "$SMALL_HAS_MORE" = no ]; then
  ok "(h) result cap holds: default showed $CAPPED_N of $UNCAPPED_N with a '+N more' indicator; --limit 0 shows all, no indicator"
else
  bad "(h) cap wrong: capped=$CAPPED_N uncapped=$UNCAPPED_N more_marker=$HAS_MORE marker_when_uncapped=$SMALL_HAS_MORE"
  printf '%s\n' "$CAPPED" | tail -4
fi

# ── (i) freshness: an edit is never answered from a stale index ───────────────
STAMP1="$("$CMD" status --repo "$REPO" --json 2>/dev/null | jq -r '.stamp' 2>/dev/null || true)"
printf '\n\ndef late_arrival(x):\n    return leaf_target(x)\n' >> "$REPO/lib/core.py"
FRESH="$("$CMD" callers leaf_target --repo "$REPO" --limit 0 2>/dev/null || true)"
STAMP2="$("$CMD" status --repo "$REPO" --json 2>/dev/null | jq -r '.stamp' 2>/dev/null || true)"
SAW_NEW=no; printf '%s' "$FRESH" | grep -q 'late_arrival' && SAW_NEW=yes
if [ "$SAW_NEW" = yes ] && [ -n "$STAMP1" ] && [ "$STAMP1" != "$STAMP2" ]; then
  ok "(i) freshness: a post-index edit is seen immediately (late_arrival found) and the repo stamp changed"
else
  bad "(i) stale answer served: saw_new=$SAW_NEW stamp1=$STAMP1 stamp2=$STAMP2"
fi

# a deletion must also invalidate — removing a file cannot leave phantom symbols
rm -f "$REPO/lib/many.py"
PHANTOM="$("$CMD" callers leaf_target --repo "$REPO" --limit 0 2>/dev/null || true)"
if ! printf '%s' "$PHANTOM" | grep -q 'caller_00'; then
  ok "(i2) freshness: deleting a file drops its symbols (no phantom callers)"
else
  bad "(i2) phantom callers survived a file deletion"; printf '%s\n' "$PHANTOM" | head -5
fi

# ── (j) unknown symbol / unknown file → clean exit 4, no crash, no fake answer ─
set +e
UNK_OUT="$("$CMD" def definitely_not_a_real_symbol_xyz --repo "$REPO" 2>&1)"
UNK_RC=$?
UNKF_OUT="$("$CMD" outline lib/nope.py --repo "$REPO" 2>&1)"
UNKF_RC=$?
IMPACT_UNK_OUT="$("$CMD" impact definitely_not_a_real_symbol_xyz --repo "$REPO" 2>&1)"
IMPACT_UNK_RC=$?
set -e
if [ "$UNK_RC" -eq 4 ] && [ "$UNKF_RC" -eq 4 ] && [ "$IMPACT_UNK_RC" -eq 4 ] \
   && printf '%s' "$UNK_OUT" | grep -qi 'not in index' \
   && ! printf '%s' "$UNK_OUT" | grep -qi 'traceback'; then
  ok "(j) unknown symbol and unknown file → exit 4 'not in index', never a crash or an invented answer"
else
  bad "(j) unknown handling wrong: sym_rc=$UNK_RC file_rc=$UNKF_RC impact_rc=$IMPACT_UNK_RC"
  printf '%s\n%s\n' "$UNK_OUT" "$UNKF_OUT"
fi

# ── (k) HEIMDALL_HOME relocates the index cache (no baked path) ───────────────
ALT="$WORK/alt-home"
HEIMDALL_HOME="$ALT" "$CMD" index --repo "$REPO" >/dev/null 2>&1
CACHE_PATH="$(HEIMDALL_HOME="$ALT" "$CMD" status --repo "$REPO" --json 2>/dev/null | jq -r '.cache' 2>/dev/null || true)"
if [ -f "$ALT/symbolgraph.json" ] && [ "$CACHE_PATH" = "$ALT/symbolgraph.json" ]; then
  ok "(k) HEIMDALL_HOME relocates the index cache to $ALT/symbolgraph.json (no baked path)"
else
  bad "(k) relocation failed: cache=$CACHE_PATH exists=$([ -f "$ALT/symbolgraph.json" ] && echo yes || echo no)"
fi

# ── (l) usage errors are exit 2, and --help works ─────────────────────────────
set +e
"$CMD" --help >/dev/null 2>&1; HELP_RC=$?
"$CMD" bogus-subcommand >/dev/null 2>&1; BOGUS_RC=$?
"$CMD" def >/dev/null 2>&1; NOARG_RC=$?
set -e
if [ "$HELP_RC" -eq 0 ] && [ "$BOGUS_RC" -eq 2 ] && [ "$NOARG_RC" -eq 2 ]; then
  ok "(l) --help exits 0; unknown subcommand and missing arg exit 2"
else
  bad "(l) exit codes wrong: help=$HELP_RC bogus=$BOGUS_RC noarg=$NOARG_RC"
fi

echo
echo "  symbol-graph tests: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
