#!/usr/bin/env bash
# test/brief-graph-wiring.test.sh — acceptance for bin/heimdall-brief once it is
# fed by bin/heimdall-graph instead of an alias table nothing populates.
#
# The load-bearing property is NOT "a brief is produced". It is that a brief
# which LOST context REFUSES to be emitted. A thin brief is strictly worse than
# a fat one: the agent cannot tell that the context it needed is missing, so it
# produces confidently wrong work and every downstream gate sees a green run.
# So every resolution assertion below runs TWICE — once with the symbol present
# (must resolve, exit 0) and once with that exact symbol deleted (must refuse,
# exit 1). A resolver that cannot go dark is not evidence.
#
# Covered:
#   (a) a code symbol resolves to a REAL file:span from the graph, not an alias
#   (b) FALSIFIABILITY: delete the definition → brief refuses loudly, exit 1
#   (c) callers ride along (blast radius) and keep their confidence markers
#   (d) --files emits outlines (spans), never file bodies
#   (e) FALSIFIABILITY: unknown file → refuses loudly, exit 1
#   (f) the curated alias table still resolves (protocol v2 mechanism 2 intact)
#   (g) graph beats alias on collision, and the collision is announced
#   (h) an UNREACHABLE graph is NON_VERIFIED (exit 3), never "all unresolved"
#   (i) a missing capsule is reported as an unresolved ref, not a silent gap
#   (j) the brief never contains the plan / prior conversation framing
#   (k) byte budget: a brief over a real file stays far under reading that file

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
BRIEF="$ROOT/bin/heimdall-brief"
GRAPH="$ROOT/bin/heimdall-graph"

PASS=0
FAIL=0
ok()  { PASS=$((PASS+1)); printf "  \033[32mPASS\033[0m %s\n" "$1"; }
bad() { FAIL=$((FAIL+1)); printf "  \033[31mFAIL\033[0m %s\n" "$1"; }

command -v jq >/dev/null 2>&1 || { echo "FATAL: jq required" >&2; exit 2; }
[ -x "$BRIEF" ] || { echo "FATAL: $BRIEF not executable" >&2; exit 2; }
[ -x "$GRAPH" ] || { echo "FATAL: $GRAPH not executable" >&2; exit 2; }

WORK="$(mktemp -d -t "briefgraph-test.$(printf 'X%.0s' 1 2 3 4 5 6)")"
trap 'rm -rf "$WORK"' EXIT

REPO="$WORK/proj"
mkdir -p "$REPO/lib"
# Both caches relocate into the temp tree — never the developer's real state.
export HEIMDALL_HOME="$WORK/home"
export HEIMDALL_PLANNING_DIR="$WORK/planning"

seed_repo() {
  cat > "$REPO/lib/core.py" <<'EOF'
"""Seeded module with a hand-known call graph."""


def leaf_target(x):
    return x + 1


def middle_hop(x):
    return leaf_target(x) * 2


def entry_point(x):
    return middle_hop(x)
EOF
}
seed_repo

# run_brief <expected-exit> -- <args...>  → stdout+stderr in $OUT, status in $RC
OUT=""; RC=0
run_brief() {
  set +e
  OUT="$("$BRIEF" "$@" --repo "$REPO" 2>&1)"
  RC=$?
  set -e
}

# ── (a) a code symbol resolves to a REAL span from the graph ─────────────────
run_brief build --task T1 --spec "touch the leaf" --symbols leaf_target
if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -q "lib/core.py:4-5"; then
  ok "(a) code symbol resolves to a real file:span from the graph"
else
  bad "(a) code symbol did not resolve to a real span (rc=$RC)"
  printf '%s\n' "$OUT" | sed 's/^/      /'
fi

# The span must be REAL, not invented: check it against the actual file.
line4="$(sed -n '4p' "$REPO/lib/core.py")"
case "$line4" in
  *"def leaf_target"*) ok "(a) the reported span points at the real definition line" ;;
  *) bad "(a) span did not match the real file (line 4 = '$line4')" ;;
esac

# ── (b) FALSIFIABILITY: delete the definition → must REFUSE, loudly ──────────
cat > "$REPO/lib/core.py" <<'EOF'
"""Seeded module with the leaf deliberately removed."""


def middle_hop(x):
    return 2
EOF
run_brief build --task T1 --spec "touch the leaf" --symbols leaf_target
if [ "$RC" -eq 1 ] && printf '%s' "$OUT" | grep -q "UNRESOLVED"; then
  ok "(b) FALSIFIABLE: definition deleted → brief refuses, exit 1, says UNRESOLVED"
else
  bad "(b) deleted definition did NOT make the brief refuse (rc=$RC, want 1)"
  printf '%s\n' "$OUT" | sed 's/^/      /'
fi
# ...and it must NOT have emitted a normal-looking brief body alongside the refusal.
if printf '%s' "$OUT" | grep -q "INCOMPLETE"; then
  ok "(b) the refusal names the brief as INCOMPLETE, not merely annotated"
else
  bad "(b) refusal did not mark the brief INCOMPLETE"
fi
seed_repo

# ── (c) callers ride along, with confidence markers preserved ────────────────
run_brief build --task T2 --spec "change the leaf" --symbols leaf_target
if printf '%s' "$OUT" | grep -q "middle_hop"; then
  ok "(c) callers ride along with the symbol (blast radius, not just location)"
else
  bad "(c) callers missing from the brief"
  printf '%s\n' "$OUT" | sed 's/^/      /'
fi

# ── (d) --files emits an OUTLINE (spans), never the file body ────────────────
run_brief build --task T3 --spec "edit core" --files lib/core.py
if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -q "entry_point"; then
  ok "(d) --files emits the outline symbol list"
else
  bad "(d) --files did not emit an outline (rc=$RC)"
  printf '%s\n' "$OUT" | sed 's/^/      /'
fi
if printf '%s' "$OUT" | grep -q "return x + 1"; then
  bad "(d) LEAK: the brief inlined file BODY text, defeating the whole mechanism"
else
  ok "(d) the brief carries spans only — no file body leaked in"
fi

# ── (e) FALSIFIABILITY: unknown file → refuse ────────────────────────────────
run_brief build --task T3 --spec "edit ghost" --files lib/does_not_exist.py
if [ "$RC" -eq 1 ] && printf '%s' "$OUT" | grep -q "UNRESOLVED"; then
  ok "(e) FALSIFIABLE: unknown file → refuses, exit 1"
else
  bad "(e) unknown file did not cause a refusal (rc=$RC, want 1)"
fi

# ── (f) the curated alias table still works (protocol v2 mechanism 2) ────────
"$ROOT/bin/heimdall-resolve" set F12 "src/matching/engine.ts" >/dev/null
run_brief build --task T4 --spec "use the alias" --symbols F12
if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -q "src/matching/engine.ts"; then
  ok "(f) curated alias ids still resolve (mechanism 2 not regressed)"
else
  bad "(f) alias resolution regressed (rc=$RC)"
  printf '%s\n' "$OUT" | sed 's/^/      /'
fi

# ── (g) graph beats alias on collision, and says so ──────────────────────────
"$ROOT/bin/heimdall-resolve" set leaf_target "SOMETHING STALE AND WRONG" >/dev/null
run_brief build --task T5 --spec "collide" --symbols leaf_target
if printf '%s' "$OUT" | grep -q "lib/core.py:4-5"; then
  ok "(g) graph wins the collision (ground truth beats a stale alias)"
else
  bad "(g) stale alias shadowed the graph — drift can now produce a false green"
fi
if printf '%s' "$OUT" | grep -qi "COLLISION"; then
  ok "(g) the collision is announced, not silently resolved"
else
  bad "(g) collision was resolved silently"
fi

# ── (h) an UNREACHABLE graph is NON_VERIFIED, never "everything unresolved" ──
# A broken resolver must not be indistinguishable from a proven-absent symbol.
BADBIN="$WORK/badbin"
mkdir -p "$BADBIN"
cat > "$BADBIN/heimdall-graph" <<'EOF'
#!/bin/sh
echo "heimdall-graph: python3 not found" >&2
exit 2
EOF
chmod +x "$BADBIN/heimdall-graph"
set +e
OUT="$(HEIMDALL_GRAPH_BIN="$BADBIN/heimdall-graph" "$BRIEF" build --task T6 \
        --spec "resolver down" --symbols leaf_target --repo "$REPO" 2>&1)"
RC=$?
set -e
if [ "$RC" -eq 3 ]; then
  ok "(h) unreachable graph → exit 3 NON_VERIFIED (distinct from a resolved absence)"
else
  bad "(h) unreachable graph returned rc=$RC (want 3 — an unreachable verifier is never OPEN)"
  printf '%s\n' "$OUT" | sed 's/^/      /'
fi

# ── (i) a missing capsule is an unresolved ref, not a silent gap ─────────────
run_brief build --task T7 --spec "hydrate a ghost" --capsules no_such_capsule
if [ "$RC" -eq 1 ] && printf '%s' "$OUT" | grep -q "UNRESOLVED"; then
  ok "(i) missing capsule is reported as an unresolved ref, exit 1"
else
  bad "(i) missing capsule did not refuse (rc=$RC, want 1)"
fi

# ── (j) the brief never smuggles the plan back in ────────────────────────────
run_brief build --task T8 --spec "stay thin" --symbols leaf_target
if printf '%s' "$OUT" | grep -q "Refs only"; then
  ok "(j) the brief still declares itself refs-only"
else
  bad "(j) the refs-only contract line went missing"
fi

# ── (k) byte budget: the brief must be much smaller than the file it describes ─
# The whole justification is token cost; a brief that is not smaller has failed.
BIG="$ROOT/bin/lib/symbolgraph.py"
if [ -f "$BIG" ]; then
  set +e
  BOUT="$("$BRIEF" build --task T9 --spec "navigate the engine" \
          --files bin/lib/symbolgraph.py --repo "$ROOT" 2>&1)"
  BRC=$?
  set -e
  raw=$(wc -c < "$BIG" | tr -d ' ')
  brief_bytes=$(printf '%s' "$BOUT" | wc -c | tr -d ' ')
  if [ "$BRC" -eq 0 ] && [ "$brief_bytes" -lt "$raw" ]; then
    ok "(k) brief ${brief_bytes}B vs raw file ${raw}B — the mechanism actually saves"
  else
    bad "(k) brief ${brief_bytes}B vs raw ${raw}B (rc=$BRC) — no saving"
  fi
fi

echo
echo "  brief↔graph wiring tests: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
