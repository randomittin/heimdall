#!/usr/bin/env bash
# test/brief-fail-closed.test.sh — ONE brief assembler, ONE failure semantics.
#
# WHY THIS EXISTS. Heimdall shipped TWO brief assemblers with OPPOSITE failure
# semantics:
#
#   bin/heimdall-brief      refuses (exit 1) on an unresolvable ref and prints
#                           THIS BRIEF IS INCOMPLETE.
#   sentinels/lib/brief.sh  degraded gracefully and NEVER failed — it printed
#                           "(unavailable: ... — skipped)" and returned 0.
#
# bin/heimdall-spawn called the second one, so every spawn routed through the
# real spawn path got a silently-thin brief. That is strictly worse than a fat
# brief: the agent cannot tell context is missing, so it produces confidently
# wrong work and every downstream gate sees a green run. Same defect class as
# bin/heimdall-dream-permission reading a completed run as a granted one —
# completion is not evidence of success, and degradation is not resolution.
#
# The second assembler also read capsules from $root/capsules/ while
# bin/heimdall-capsule writes $PLANNING_DIR/protocol/capsules/. A store nothing
# ever writes to is empty forever and looks fine.
#
# COVERED — Hole 1 (unified assembler):
#   (a1) the spawn path REFUSES an unresolvable capsule ref instead of skipping
#   (a2) a refused brief means the sentinel never runs and writes no report
#   (a3) both entry points return the SAME verdict on the SAME ref (drift guard)
#   (a4) capsules resolve from the CANONICAL store (bin/lib/protocol.sh's
#        CAPSULE_DIR); the old $root/capsules/ path is no longer consulted
#   (a5) EMPTY store (legitimate, exit 0/1) is distinguishable from UNREACHABLE
#        store (NON_VERIFIED, exit 3) — an unreachable verifier is never OPEN
#   (a6) STRUCTURAL: both assemblers source the one shared resolution+refusal
#        core, so their failure behaviour cannot fork again
#
# COVERED — Hole 2 (invariants ref validated, not echoed):
#   (b1) a ref whose file AND anchor resolve is reported as verified, exit 0
#   (b2) FALSIFIABLE: delete the file  -> refuses, exit 1, names FILE MISSING
#   (b3) FALSIFIABLE: delete the anchor-> refuses, exit 1, names ANCHOR MISSING
#   (b4) a malformed ref               -> refuses, exit 1, names MALFORMED
#   (b5) the three diagnoses are DISTINCT — each is a different repair
#   (b6) the anchor resolver can go dark: the same anchor passes, then the
#        heading is removed and it fails. A checker that always says yes is not
#        a check.
#   (b7) the spawn path validates context.invariants with the same semantics
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
BRIEF="$ROOT/bin/heimdall-brief"
SPAWN="$ROOT/bin/heimdall-spawn"
CAPSULE="$ROOT/bin/heimdall-capsule"
CORE="$ROOT/bin/lib/brief-core.sh"
HYDRATOR="$ROOT/sentinels/lib/brief.sh"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf "  \033[32mPASS\033[0m %s\n" "$1"; }
bad() { FAIL=$((FAIL+1)); printf "  \033[31mFAIL\033[0m %s\n" "$1"; }

command -v jq >/dev/null 2>&1 || { echo "FATAL: jq required" >&2; exit 2; }
for f in "$BRIEF" "$SPAWN" "$CAPSULE"; do
  [ -x "$f" ] || { echo "FATAL: $f not executable" >&2; exit 2; }
done

WORK="$(mktemp -d -t "brieffc.$(printf 'X%.0s' 1 2 3 4 5 6)")"
trap 'chmod -R u+rwX "$WORK" 2>/dev/null || true; rm -rf "$WORK"' EXIT

REPO="$WORK/proj"; mkdir -p "$REPO/lib"
# Both caches relocate into the temp tree — never the developer's real state.
export HEIMDALL_HOME="$WORK/home"
export HEIMDALL_PLANNING_DIR="$WORK/planning"

cat > "$REPO/lib/core.py" <<'EOF'
"""Seeded module so symbol resolution is not the thing under test here."""


def leaf_target(x):
    return x + 1
EOF

INV="$REPO/INVARIANTS.md"
write_invariants() {
  cat > "$INV" <<'EOF'
# Project Invariants

## Code Quality — Zero Tolerance

No stub, placeholder or TODO code ships.

## Fail Closed

An unreachable verifier is NON_VERIFIED, never OPEN.
EOF
}
write_invariants
# GitHub-slug of "## Code Quality — Zero Tolerance": the em dash is punctuation
# and is dropped, leaving the two spaces around it as two hyphens.
ANCHOR_OK="code-quality--zero-tolerance"

OUT=""; RC=0
run_brief() {
  set +e
  OUT="$("$BRIEF" "$@" --repo "$REPO" 2>&1)"
  RC=$?
  set -e
}

# The spawn entry point. Writes a spawn json carrying the given context object.
SJ="$WORK/spawn.json"
spawn_json() { # spawn_json <context-json>
  jq -n --argjson ctx "$1" \
    '{haid:"haid:test", kind:"sanity", trigger:"watch", context:$ctx,
      budget_tokens:100, timeout_min:1, lane:"background"}' > "$SJ"
}
run_spawn_brief() {
  set +e
  OUT="$(perl -e 'alarm 60; exec @ARGV' bash "$SPAWN" brief "$SJ" --repo "$REPO" 2>&1)"
  RC=$?
  set -e
}

echo "── Hole 1: one assembler, one failure semantics ──"

# ── (a1) the spawn path REFUSES an unresolvable capsule ref ──────────────────
spawn_json '{"capsules":["no_such_capsule"]}'
run_spawn_brief
if [ "$RC" -eq 1 ] && grep -q "INCOMPLETE" <<<"$OUT"; then
  ok "(a1) spawn brief REFUSES a missing capsule (exit 1, says INCOMPLETE)"
else
  bad "(a1) spawn brief degraded instead of refusing (rc=$RC, want 1)"
  printf '%s\n' "$OUT" | sed 's/^/      /'
fi
if grep -qi "skipped" <<<"$OUT"; then
  bad "(a1) the brief still says 'skipped' — silent degradation survives"
else
  ok "(a1) no 'skipped' degradation marker — the ref is refused, not glossed"
fi

# ── (a2) a refused brief means the sentinel never runs ───────────────────────
rm -rf "$REPO/.planning/spawns/reports"
set +e
ROUT="$(perl -e 'alarm 120; exec @ARGV' bash "$SPAWN" run "$SJ" --repo "$REPO" 2>&1)"
RRC=$?
set -e
if [ "$RRC" -ne 0 ] && grep -q "INCOMPLETE" <<<"$ROUT"; then
  ok "(a2) spawn run aborts on an incomplete brief, naming it (rc=$RRC)"
else
  bad "(a2) spawn run proceeded on an incomplete brief (rc=$RRC)"
  printf '%s\n' "$ROUT" | sed 's/^/      /'
fi
# PROOF THE SENTINEL NEVER RAN, not merely that it left nothing behind. $REPO is
# deliberately not a git repo, so sentinels/sanity.sh — the kind this spawn
# dispatches — announces "not a git repo" as its FIRST act. Before the fix that
# string was present: the brief degraded and the sentinel ran anyway. Its
# absence is the dispatch never happening, which "no report file" alone cannot
# distinguish from "ran and crashed early".
if grep -q "not a git repo" <<<"$ROUT"; then
  bad "(a2) the sentinel WAS dispatched on a thin brief (it reached its own repo check)"
else
  ok "(a2) the sentinel was never dispatched — refusal happens before any work"
fi
if [ -z "$(ls -A "$REPO/.planning/spawns/reports" 2>/dev/null)" ]; then
  ok "(a2) and no report was written, so nothing downstream can read a verdict"
else
  bad "(a2) a report exists: the sentinel ran despite an incomplete brief"
fi

# ── (a3) both entry points, same ref, same verdict ───────────────────────────
run_brief build --task T1 --spec "cite a ghost" --capsules no_such_capsule
DIRECT_RC="$RC"; DIRECT_OUT="$OUT"
spawn_json '{"capsules":["no_such_capsule"]}'
run_spawn_brief
if [ "$DIRECT_RC" -eq "$RC" ]; then
  ok "(a3) DRIFT GUARD: both entry points agree on the exit code ($RC)"
else
  bad "(a3) DRIFT: heimdall-brief rc=$DIRECT_RC but the spawn path rc=$RC"
fi
if grep -q "THIS BRIEF IS INCOMPLETE" <<<"$DIRECT_OUT" \
   && grep -q "THIS BRIEF IS INCOMPLETE" <<<"$OUT"; then
  ok "(a3) DRIFT GUARD: both refuse with the same canonical refusal line"
else
  bad "(a3) DRIFT: the two entry points refuse in different words"
fi

# ── (a4) capsules resolve from the CANONICAL store only ──────────────────────
"$CAPSULE" write realcap --what "a real capsule in the canonical store" >/dev/null
spawn_json '{"capsules":["realcap"]}'
run_spawn_brief
if [ "$RC" -eq 0 ] && grep -q "a real capsule in the canonical store" <<<"$OUT"; then
  ok "(a4) the spawn path reads the canonical store (\$PLANNING_DIR/protocol/capsules)"
else
  bad "(a4) canonical-store capsule did not hydrate on the spawn path (rc=$RC)"
  printf '%s\n' "$OUT" | sed 's/^/      /'
fi
# The abandoned path must be dead: a capsule that exists ONLY at $root/capsules/
# must NOT resolve, or the two stores are both live and can disagree.
mkdir -p "$REPO/capsules"
printf -- '---\nid: legacycap\ndepends:\nts: x\n---\nWHAT: only in the old place\n' \
  > "$REPO/capsules/legacycap.md"
spawn_json '{"capsules":["legacycap"]}'
run_spawn_brief
if [ "$RC" -eq 1 ] && ! grep -q "only in the old place" <<<"$OUT"; then
  ok "(a4) the abandoned \$root/capsules/ path is dead — one store, not two"
else
  bad "(a4) the legacy capsule path still resolves (rc=$RC) — two stores can drift"
fi

# ── (a5) EMPTY store is not UNREACHABLE store ────────────────────────────────
EMPTY_PLANNING="$WORK/empty-planning"
if [ "$(HEIMDALL_PLANNING_DIR="$EMPTY_PLANNING" "$BRIEF" build --task T2 \
        --spec "no refs at all" --repo "$REPO" >/dev/null 2>&1; echo $?)" -eq 0 ]; then
  ok "(a5) an EMPTY capsule store is a legitimate state — a ref-free brief passes"
else
  bad "(a5) an empty store broke a brief that referenced no capsules"
fi
set +e
EOUT="$(HEIMDALL_PLANNING_DIR="$EMPTY_PLANNING" "$BRIEF" build --task T2 \
        --spec "cite a ghost" --capsules ghost --repo "$REPO" 2>&1)"
ERC=$?
set -e
if [ "$ERC" -eq 1 ]; then
  ok "(a5) empty store + a referenced capsule = INCOMPLETE (exit 1), a real absence"
else
  bad "(a5) empty store + missing capsule gave rc=$ERC (want 1)"
fi

# UNREACHABLE: a planning dir whose parent is a FILE can never be created or
# read, by any user including root. Nobody looked, so nothing may be reported
# absent — that is NON_VERIFIED, exit 3.
BLOCKER="$WORK/blocker"
printf 'not a directory\n' > "$BLOCKER"
set +e
UOUT="$(HEIMDALL_PLANNING_DIR="$BLOCKER/planning" "$BRIEF" build --task T3 \
        --spec "store is unreachable" --capsules anything --repo "$REPO" 2>&1)"
URC=$?
set -e
if [ "$URC" -eq 3 ]; then
  ok "(a5) an UNREACHABLE capsule store is NON_VERIFIED (exit 3), never absent"
else
  bad "(a5) unreachable store returned rc=$URC (want 3 — nobody looked, so nothing is absent)"
  printf '%s\n' "$UOUT" | sed 's/^/      /'
fi
if grep -q "NON_VERIFIED" <<<"$UOUT"; then
  ok "(a5) and it SAYS NON_VERIFIED, so the repair is not confused with a bad ref"
else
  bad "(a5) the unreachable store did not name itself NON_VERIFIED"
fi
if [ "$ERC" -ne "$URC" ]; then
  ok "(a5) empty ($ERC) and unreachable ($URC) are genuinely different verdicts"
else
  bad "(a5) empty and unreachable collapsed to the same exit code $ERC"
fi

# ── (a6) STRUCTURAL: one shared core, so the two cannot fork again ───────────
if [ -f "$CORE" ]; then
  ok "(a6) the shared resolution+refusal core exists: bin/lib/brief-core.sh"
else
  bad "(a6) no shared core — the two assemblers are still independent code"
fi
for f in "$BRIEF" "$HYDRATOR"; do
  if grep -q "brief-core.sh" "$f"; then
    ok "(a6) $(basename "$f") sources the shared core"
  else
    bad "(a6) $(basename "$f") does NOT source the shared core — drift is possible again"
  fi
done

echo
echo "── Hole 2: the invariants ref is validated, not echoed ──"

# ── (b1) a fully resolvable ref is reported as verified ─────────────────────
run_brief build --task I1 --spec "inherit the rules" --invariants "INVARIANTS.md#$ANCHOR_OK"
if [ "$RC" -eq 0 ] && grep -q "INVARIANTS REF" <<<"$OUT"; then
  ok "(b1) a ref whose file and anchor both resolve is accepted (exit 0)"
else
  bad "(b1) a valid invariants ref was rejected (rc=$RC)"
  printf '%s\n' "$OUT" | sed 's/^/      /'
fi
if grep -qi "verified" <<<"$OUT"; then
  ok "(b1) and the brief SAYS it verified the ref, rather than echoing it"
else
  bad "(b1) the ref was passed through with no evidence it was checked"
  printf '%s\n' "$OUT" | sed 's/^/      /'
fi

# ── (b2) FALSIFIABLE: the file is gone ───────────────────────────────────────
run_brief build --task I2 --spec "inherit the rules" --invariants "GONE.md#$ANCHOR_OK"
MSG_FILE="$OUT"
if [ "$RC" -eq 1 ] && grep -q "UNRESOLVED" <<<"$OUT"; then
  ok "(b2) FALSIFIABLE: a ref to a missing FILE refuses, exit 1"
else
  bad "(b2) a dangling file ref passed silently (rc=$RC, want 1)"
  printf '%s\n' "$OUT" | sed 's/^/      /'
fi
if grep -qi "no such file" <<<"$OUT"; then
  ok "(b2) the diagnosis names the FILE as the missing thing"
else
  bad "(b2) the diagnosis does not name a missing file"
fi

# ── (b3) FALSIFIABLE: the file is there, the anchor is not ───────────────────
run_brief build --task I3 --spec "inherit the rules" --invariants "INVARIANTS.md#no-such-anchor"
MSG_ANCHOR="$OUT"
if [ "$RC" -eq 1 ] && grep -qi "anchor" <<<"$OUT"; then
  ok "(b3) FALSIFIABLE: a ref to a missing ANCHOR refuses, exit 1, names the anchor"
else
  bad "(b3) a dangling anchor passed silently (rc=$RC, want 1)"
  printf '%s\n' "$OUT" | sed 's/^/      /'
fi
if grep -qF "$ANCHOR_OK" <<<"$OUT"; then
  ok "(b3) and it offers the anchors that DO exist, so the repair is one step"
else
  bad "(b3) no candidate anchors offered — the operator has to go hunting"
fi

# ── (b4) a malformed ref is its own diagnosis ────────────────────────────────
run_brief build --task I4 --spec "inherit the rules" --invariants "#anchor-with-no-file"
MSG_MALFORMED="$OUT"
if [ "$RC" -eq 1 ] && grep -qi "malformed" <<<"$OUT"; then
  ok "(b4) a malformed ref refuses, exit 1, and says MALFORMED"
else
  bad "(b4) a malformed ref was not caught as malformed (rc=$RC)"
  printf '%s\n' "$OUT" | sed 's/^/      /'
fi
run_brief build --task I5 --spec "inherit the rules" --invariants "a.md#b#c"
if [ "$RC" -eq 1 ] && grep -qi "malformed" <<<"$OUT"; then
  ok "(b4) a ref with two anchors is malformed too, not silently truncated"
else
  bad "(b4) a two-anchor ref was not rejected (rc=$RC)"
fi

# ── (b5) the three diagnoses are distinct — each is a different repair ───────
# The per-ref diagnosis lines, not the shared INCOMPLETE banner (which is
# identical by design). Each names WHICH repair the operator has to make.
d_file="$(grep "!! invariants" <<<"$MSG_FILE" | head -1)"
d_anch="$(grep "!! invariants" <<<"$MSG_ANCHOR" | head -1)"
d_malf="$(grep "!! invariants" <<<"$MSG_MALFORMED" | head -1)"
if [ -n "$d_file" ] && [ -n "$d_anch" ] && [ -n "$d_malf" ] \
   && [ "$d_file" != "$d_anch" ] && [ "$d_anch" != "$d_malf" ] && [ "$d_file" != "$d_malf" ]; then
  ok "(b5) missing-file, missing-anchor and malformed are three distinct diagnoses"
else
  bad "(b5) the diagnoses collapse: file='$d_file' anchor='$d_anch' malformed='$d_malf'"
fi

# ── (b6) the anchor resolver can go dark ─────────────────────────────────────
# Same ref, twice: once with the heading present (must pass), once with that
# exact heading removed (must fail). A checker that cannot go red is decoration.
run_brief build --task I6 --spec "before" --invariants "INVARIANTS.md#fail-closed"
BEFORE_RC="$RC"
grep -v '^## Fail Closed$' "$INV" > "$INV.tmp" && mv "$INV.tmp" "$INV"
run_brief build --task I6 --spec "after" --invariants "INVARIANTS.md#fail-closed"
AFTER_RC="$RC"
if [ "$BEFORE_RC" -eq 0 ] && [ "$AFTER_RC" -eq 1 ]; then
  ok "(b6) FALSIFIABLE: remove the heading and the same ref flips 0 -> 1"
else
  bad "(b6) the anchor check does not track the file (before=$BEFORE_RC after=$AFTER_RC)"
fi
write_invariants

# ── (b7) the spawn path validates context.invariants identically ─────────────
spawn_json '{"invariants":"GONE.md"}'
run_spawn_brief
if [ "$RC" -eq 1 ] && grep -q "INCOMPLETE" <<<"$OUT"; then
  ok "(b7) the spawn path refuses a dangling context.invariants ref too"
else
  bad "(b7) the spawn path still echoes a dangling invariants ref (rc=$RC)"
  printf '%s\n' "$OUT" | sed 's/^/      /'
fi
spawn_json "$(jq -nc --arg a "INVARIANTS.md#$ANCHOR_OK" '{invariants:$a}')"
run_spawn_brief
if [ "$RC" -eq 0 ]; then
  ok "(b7) and it accepts a ref that genuinely resolves — not a blanket refusal"
else
  bad "(b7) the spawn path rejected a valid invariants ref (rc=$RC)"
  printf '%s\n' "$OUT" | sed 's/^/      /'
fi

# ── (b8) the refs the DOCS hand out must themselves resolve ─────────────────
# Both PROTOCOL.md and the agent-template a spawning agent copies from used to
# print `--invariants INVARIANTS.md`, and that file has never existed at the
# repo root. Documentation is a call site: a ref pasted from it is a ref an
# agent believes it was given. So every invariants ref the docs publish is run
# against the real repo here, and a doc that drifts off a real anchor fails.
doc_refs_resolve() {
  local doc="$1" ref found=0
  [ -f "$ROOT/$doc" ] || { bad "(b8) doc missing: $doc"; return; }
  while IFS= read -r ref; do
    [ -n "$ref" ] || continue
    found=1
    if (cd "$ROOT" && HEIMDALL_PLANNING_DIR="$WORK/docs-planning" \
         "$BRIEF" build --task DOC --spec "doc ref" --invariants "$ref" >/dev/null 2>&1); then
      ok "(b8) $doc publishes a ref that resolves: $ref"
    else
      bad "(b8) $doc publishes a DANGLING invariants ref: $ref"
    fi
  done <<EOF
$(sed -n "s/.*--invariants[ ]*'\{0,1\}\([^ '\\\\]*\)'\{0,1\}.*/\1/p" "$ROOT/$doc" | grep -v '^<' || true)
EOF
  [ "$found" -eq 1 ] || bad "(b8) no --invariants example found in $doc — the check went blind"
}
doc_refs_resolve "PROTOCOL.md"
doc_refs_resolve "skills/heimdall/references/agent-templates.md"

echo
echo "  brief fail-closed tests: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
