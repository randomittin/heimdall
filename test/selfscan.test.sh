#!/usr/bin/env bash
#
# selfscan.test.sh — scope + allowlist proofs for bin/heimdall-selfscan.
#
# heimdall-selfscan is the SHARED pre-push gate. It must police HEIMDALL's own
# history (secrets + identity allowlist + landmine lint) — and ONLY heimdall's.
# Two coupled defects this harness fences against:
#
#   BUG 1 — SCOPING. The gate is wired via core.hooksPath = a RELATIVE path, so
#   the native pre-push hook fires in EVERY repo that inherits that config. When
#   it fires while pushing an UNRELATED repo, the gate must NOT apply heimdall's
#   identity allowlist / secret rules to that foreign repo. It must detect that
#   it is not in the heimdall repo and stand down (exit 0) — the foreign repo's
#   own gates police the foreign repo.
#
#   BUG 2 — ALLOWLIST PARITY. heimdall ships its OWN secret-shaped detection
#   fixtures (the secret-scan corpus, the demo's runtime sk_live_, landmine test
#   strings). Bare `gitleaks detect` honors the repo's .gitleaks.toml allowlist
#   and reports those as 0 leaks. selfscan must scan the SAME way — honoring the
#   repo-top .gitleaks.toml — so the two AGREE. A config-blind selfscan reports
#   the fixtures as false-positive leaks and blocks every push.
#
#   BUG 3 — TREE BLINDNESS. The gate scanned HISTORY only. History mode and tree
#   mode see different surfaces, so a credential in a working-tree file could be
#   invisible to a gate that reported clean. Proof E fences that (full rationale
#   at the E block below).
#
#   BUG 4 — TREE OVER-REACH, the failure mode the fix for BUG 3 walked straight
#   into. `gitleaks --no-git` walks the FILESYSTEM, not the repo, so it also
#   reads untracked and .gitignored paths — none of which a push can carry. On a
#   real working copy that blocks every push on the developer's own local
#   credential, which gets the gate disabled and reopens BUG 3. The tree pass must
#   scan the PUSHABLE set. Proof F fences that (full rationale at the F block).
#
# Six proofs, all runnable, none skippable:
#
#   A. PARITY — bare `gitleaks detect --log-opts=--all` over heimdall's history
#      and `heimdall-selfscan` AGREE: both exit 0 (clean). selfscan must not
#      invent findings bare gitleaks does not see.
#
#   B. SCOPING — run the gate from an UNRELATED throwaway repo (foreign author,
#      benign content). The gate must NOT block on heimdall's internals: it must
#      recognize it is not the heimdall repo and exit 0.
#
#   C. STILL-DETECTS — under the SHIPPED .gitleaks.toml (the exact config the
#      gate honors), prove BOTH halves of "the allowlist is a scalpel, not a
#      blanket": (i) the SAME secret committed to a NON-fixture path (src/) IS
#      flagged (detection intact, allowlist narrow), AND (ii) a committed COPY of
#      that secret in an allowlisted fixture path is NOT flagged (the allowlist
#      works). The secret must be one gitleaks' DEFAULT ruleset actually fires on:
#      note AWS's canonical doc key AKIA…EXAMPLE is excluded by gitleaks' OWN
#      built-in example filter regardless of config, so committing it proves
#      nothing about our allowlist. We use a live Stripe-shaped token (rule
#      stripe-access-token), assembled at runtime so this file carries no
#      contiguous literal.
#
#   D. ALLOWLIST-IS-NARROW — the shipped .gitleaks.toml must NOT globally disable
#      any rule; it may only allowlist by PATH/regex. A real secret in a
#      non-fixture path must still fire.
#
# Exit 0 = every proof holds. Nonzero = a proof failed (prints which).

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SELF_DIR/.." && pwd)"
SELFSCAN="$REPO/bin/heimdall-selfscan"

PASS=0; FAIL=0
ok()  { printf '  \033[32mPASS\033[0m %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAIL=$((FAIL + 1)); }

[ -x "$SELFSCAN" ] || { echo "FATAL: selfscan not executable at $SELFSCAN"; exit 2; }
command -v gitleaks >/dev/null 2>&1 || { echo "FATAL: gitleaks not installed — cannot prove parity"; exit 2; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# ─────────────────────────────────────────────────────────────────────────────
# A. PARITY — bare gitleaks history scan == selfscan, both clean.
# ─────────────────────────────────────────────────────────────────────────────
echo "A. PARITY (bare gitleaks history == selfscan):"
bare_rc=0
( cd "$REPO" && gitleaks detect --source . --log-opts="--all" --no-banner ) >/dev/null 2>&1 || bare_rc=$?
self_rc=0
( cd "$REPO" && "$SELFSCAN" ) >/dev/null 2>&1 || self_rc=$?
if [ "$bare_rc" -eq 0 ]; then
  ok "bare gitleaks over heimdall history is clean (rc=0)"
else
  bad "bare gitleaks over heimdall history is NOT clean (rc=$bare_rc) — history regression, fix that first"
fi
if [ "$self_rc" -eq 0 ]; then
  ok "selfscan over heimdall history is clean (rc=0)"
else
  bad "selfscan reports findings/identity/landmine bare gitleaks does not (rc=$self_rc)"
fi
if [ "$bare_rc" -eq "$self_rc" ]; then
  ok "bare gitleaks and selfscan AGREE (both rc=$self_rc)"
else
  bad "DISAGREEMENT — bare=$bare_rc selfscan=$self_rc (the 14-false-positive class)"
fi

# ─────────────────────────────────────────────────────────────────────────────
# B. SCOPING — gate run from an UNRELATED repo must stand down (exit 0).
# ─────────────────────────────────────────────────────────────────────────────
echo "B. SCOPING (foreign repo not blocked on heimdall internals):"
FOREIGN="$WORK/foreign"
mkdir -p "$FOREIGN"
(
  cd "$FOREIGN"
  git init -q
  git config user.email "someone@example.com"
  git config user.name "Some One"
  echo "hello world" > readme.txt
  git add readme.txt
  git commit -q -m "init unrelated repo"
)
foreign_rc=0
( cd "$FOREIGN" && "$SELFSCAN" ) >/dev/null 2>&1 || foreign_rc=$?
if [ "$foreign_rc" -eq 0 ]; then
  ok "gate stands down in an unrelated repo (rc=0) — does not apply heimdall's allowlist"
else
  bad "gate BLOCKED an unrelated repo (rc=$foreign_rc) — it scanned the wrong repo / applied heimdall rules"
fi

# ─────────────────────────────────────────────────────────────────────────────
# C. STILL-DETECTS — a real-shaped committed secret in the heimdall repo's scope
#    is still caught by the config-honoring history scan. We assemble the secret
#    at runtime (so this test file is not itself a literal) and commit it into a
#    clone of the repo top's scan, then prove gitleaks-with-config still fires.
# ─────────────────────────────────────────────────────────────────────────────
echo "C. STILL-DETECTS (allowlist does not weaken real detection):"
DETECT="$WORK/detect"
mkdir -p "$DETECT"
# Use the repo's own .gitleaks.toml so we test the EXACT config selfscan honors.
CFG="$REPO/.gitleaks.toml"
[ -f "$CFG" ] || { bad "C — .gitleaks.toml missing at repo top; selfscan has no allowlist to honor"; CFG=""; }
# A real-shaped Stripe live token (rule: stripe-access-token) — one gitleaks'
# DEFAULT ruleset actually fires on. Assembled from parts so this script carries
# no contiguous literal. (AWS's AKIA…EXAMPLE doc key is gitleaks-allowlisted by
# its own built-in example filter, so it can never prove our allowlist's narrowness.)
sk="sk_live_""4eC39HqLyjWDarjtT1zdp7dc"
# The non-fixture path the secret must STILL be caught in.
LEAK_PATH="src/leak.js"
# An allowlisted fixture path from the shipped .gitleaks.toml — a COPY of the
# same secret here must NOT be flagged (proves the allowlist actually allowlists).
FIXTURE_PATH="bin/heimdall-demo"
(
  cd "$DETECT"
  git init -q
  git config user.email "rj@runheimdall.dev"
  git config user.name "RJ"
  mkdir -p "$(dirname "$LEAK_PATH")" "$(dirname "$FIXTURE_PATH")"
  printf 'const key = "%s";\n' "$sk" > "$LEAK_PATH"
  printf 'demo_runtime_key="%s"\n' "$sk" > "$FIXTURE_PATH"
  git add -A
  git commit -q -m "real Stripe secret: one in src/ (must fire), one in an allowlisted fixture path (must not)"
)
if [ -n "$CFG" ]; then
  # Capture which files the SHIPPED config flags over committed history. Write the
  # JSON report to a real file (gitleaks' /dev/stdout report path is unreliable —
  # the findings can be swallowed), then read back the flagged File paths.
  RPT="$WORK/detect-report.json"
  ( cd "$DETECT" && gitleaks detect --source . --config "$CFG" --log-opts="--all" --no-banner --report-format json --report-path "$RPT" ) >/dev/null 2>&1
  FOUND_FILES="$( [ -f "$RPT" ] && cat "$RPT" || echo '[]' )"
  # (i) detection intact: the non-fixture src/ path MUST be flagged.
  if printf '%s' "$FOUND_FILES" | grep -Fq "$LEAK_PATH"; then
    ok "real Stripe secret in $LEAK_PATH still CAUGHT under heimdall's shipped config"
  else
    bad "real secret in $LEAK_PATH NOT caught — detection weakened / config too broad"
  fi
  # (ii) allowlist narrow + actually works: the SAME secret in the allowlisted
  # fixture path must NOT be flagged.
  if printf '%s' "$FOUND_FILES" | grep -Fq "$FIXTURE_PATH"; then
    bad "allowlisted fixture path $FIXTURE_PATH was FLAGGED — the path allowlist is not taking effect"
  else
    ok "identical secret in allowlisted $FIXTURE_PATH NOT flagged (allowlist works, scoped to the fixture)"
  fi
fi

# ─────────────────────────────────────────────────────────────────────────────
# D. ALLOWLIST-IS-NARROW — the shipped config must not nuke whole rules.
# ─────────────────────────────────────────────────────────────────────────────
echo "D. ALLOWLIST-IS-NARROW (no global rule disable):"
if [ -n "$CFG" ]; then
  # useDefault=true (or extend of default) keeps the full ruleset on. A config
  # that sets useDefault=false or strips rules to silence fixtures is a FAILURE.
  if grep -Eq 'useDefault[[:space:]]*=[[:space:]]*true' "$CFG"; then
    ok "config extends the DEFAULT ruleset (useDefault = true)"
  else
    bad "config does not extend the default ruleset — real detection may be disabled"
  fi
  if grep -Eq 'useDefault[[:space:]]*=[[:space:]]*false' "$CFG"; then
    bad "config sets useDefault = false — the full ruleset is OFF, real secrets slip"
  else
    ok "config does not turn the default ruleset off"
  fi
fi

# ─────────────────────────────────────────────────────────────────────────────
# E. TREE-MODE — the gate must also scan the files as they are ON DISK.
#
#    The blind spot this fences: gitleaks history mode and tree mode do not see
#    the same surface, and .gitleaksignore entries are COMMIT-scoped
#    (commit:file:rule:line). A benign fixture silenced there is silenced in the
#    history walk permanently — the walk only re-reports a line against the
#    commit that introduced it — while the live on-disk copy has fingerprint
#    (file:rule:line), a different namespace entirely. Two real findings in this
#    repo were visible to `--no-git` and invisible to `--log-opts=--all` for
#    exactly that reason. A credential in a working-tree file could therefore
#    sail past a pre-push gate that reported clean.
#
#    Four coupled proofs, run against a throwaway clone so the real repo is never
#    touched. The clone must be FULL, never shallow: `--depth 1` re-materializes
#    the entire tree as one fresh commit whose SHA matches none of the
#    .gitleaksignore fingerprints (they are commit-scoped), so every benign
#    historical fixture resurfaces and the history pass blocks for the wrong
#    reason — proof E would then "fail" without the tree pass ever being at fault.
#    Uncommitted tracked changes are applied on top, so the gate under test is the
#    one about to be pushed rather than the last-committed one.
#      (i)   TRUE NEGATIVE + ANTI-VACUOUS — a pristine clone scans clean, AND the
#            gate reports a plausible scanned volume. "0 findings" is meaningless
#            without "over this much"; a clean verdict over ~0 bytes is refused.
#      (ii)  BLINDNESS — the planted secret is invisible to the history-only scan.
#            This is what earns the new step its place.
#      (iii) TRUE POSITIVE — the full gate BLOCKS on it.
#      (iv)  FALSIFIABILITY — strip the tree pass and the SAME secret sails
#            through (RED); restore it and the block returns (GREEN).
# ─────────────────────────────────────────────────────────────────────────────
echo "E. TREE-MODE (on-disk secret blocks; history-only cannot see it):"
CLONE="$WORK/treeclone"
if ! git clone -q "$REPO" "$CLONE" 2>/dev/null; then
  bad "E — could not clone $REPO into a throwaway; the tree-mode proofs did NOT run"
else
  # Carry over uncommitted tracked edits so the gate under test is the one about
  # to be pushed, not the last-committed one. Empty diff -> nothing to apply.
  WT_DIFF="$WORK/worktree.patch"
  ( cd "$REPO" && git diff HEAD --binary ) > "$WT_DIFF" 2>/dev/null || : > "$WT_DIFF"
  if [ -s "$WT_DIFF" ]; then
    ( cd "$CLONE" && git apply "$WT_DIFF" ) 2>/dev/null \
      || bad "E — could not apply the working-tree diff to the clone; proofs below test the COMMITTED gate, not the pending one"
  fi
  chmod +x "$CLONE/bin/heimdall-selfscan"

  # (i) TRUE NEGATIVE + ANTI-VACUOUS.
  clean_rc=0
  ( cd "$CLONE" && ./bin/heimdall-selfscan ) >"$WORK/e-clean.err" 2>&1 || clean_rc=$?
  if [ "$clean_rc" -eq 0 ]; then
    ok "pristine clone scans CLEAN through the full gate (rc=0)"
  else
    bad "pristine clone was BLOCKED (rc=$clean_rc) — false positive in the new tree pass"
    sed 's/^/      /' "$WORK/e-clean.err" | tail -20
  fi
  # The gate prints `tree=0/<bytes>B`; a clean verdict over a trivial volume means
  # the scan never reached the tree (wrong --source, empty checkout).
  TREE_B="$(sed -n 's/.*tree=0\/\([0-9][0-9]*\)B.*/\1/p' "$WORK/e-clean.err" | tail -1)"
  if [ -n "$TREE_B" ] && [ "$TREE_B" -gt 100000 ]; then
    ok "tree pass examined a plausible volume (${TREE_B} bytes) — the clean verdict is non-vacuous"
  else
    bad "tree pass reported no/implausible scanned volume (${TREE_B:-none}) — a clean verdict here proves nothing"
  fi

  # Plant a real-shaped credential in a WORKING-TREE file. Never committed: that
  # is precisely the surface the history walk cannot reach. Reuses the runtime-
  # assembled Stripe token from proof C, so this file still carries no literal.
  mkdir -p "$CLONE/src"
  printf 'const stripeKey = "%s";\n' "$sk" > "$CLONE/src/tree-leak.js"

  # (ii) BLINDNESS — history-only must NOT see it.
  hist_only_rc=0
  ( cd "$CLONE" && gitleaks detect --source . --config .gitleaks.toml --log-opts="--all" --no-banner --no-color ) >/dev/null 2>&1 || hist_only_rc=$?
  if [ "$hist_only_rc" -eq 0 ]; then
    ok "history-only scan is BLIND to the working-tree secret (rc=0) — blind spot reproduced"
  else
    bad "history scan flagged an uncommitted file (rc=$hist_only_rc) — proof E's premise is wrong, re-derive it"
  fi

  # (iii) TRUE POSITIVE — the full gate must block, and say why.
  planted_rc=0
  ( cd "$CLONE" && ./bin/heimdall-selfscan ) >"$WORK/e-planted.err" 2>&1 || planted_rc=$?
  if [ "$planted_rc" -ne 0 ] && grep -q "WORKING TREE" "$WORK/e-planted.err"; then
    ok "gate BLOCKS the working-tree secret (rc=$planted_rc) and names the working tree"
  else
    bad "gate did NOT block a planted working-tree secret (rc=$planted_rc) — the blind spot is still open"
  fi

  # (iv) FALSIFIABILITY — remove the tree pass; the same secret must sail through.
  MUT="$CLONE/bin/heimdall-selfscan"
  cp "$MUT" "$WORK/selfscan.orig"
  sed '/# --- scan the WORKING TREE for secrets/,/# --- identity allowlist over the FULL history/{
         /# --- identity allowlist over the FULL history/!d
       }' "$WORK/selfscan.orig" > "$MUT"
  chmod +x "$MUT"
  # The mutation must be REAL — otherwise the RED below is meaningless theatre.
  # Match the INVOCATION, not the flag anywhere: the header comment documents
  # `--no-git` in prose and legitimately survives the excision, so a bare
  # `grep -- --no-git` would report a false "mutation failed".
  if grep -q 'gitleaks detect.*--no-git' "$WORK/selfscan.orig" \
     && ! grep -q 'gitleaks detect.*--no-git' "$MUT"; then
    ok "mutation is real (tree-scan invocation present in the original, absent in the mutant)"
  else
    bad "mutation did not strip the tree-scan invocation — the RED below would prove nothing"
  fi
  mut_rc=0
  ( cd "$CLONE" && ./bin/heimdall-selfscan ) >/dev/null 2>&1 || mut_rc=$?
  if [ "$mut_rc" -eq 0 ]; then
    ok "WITHOUT the tree pass the same secret sails through (rc=0) — the step earns its place"
  else
    bad "mutant still blocked (rc=$mut_rc) — proof (iii) is not attributable to the tree pass"
  fi
  # Restore -> the block must come back (RED -> GREEN round trip closed).
  cp "$WORK/selfscan.orig" "$MUT"
  chmod +x "$MUT"
  restored_rc=0
  ( cd "$CLONE" && ./bin/heimdall-selfscan ) >"$WORK/e-restored.err" 2>&1 || restored_rc=$?
  # Must block for the RIGHT reason. A nonzero exit alone would also be produced by
  # a history/identity/landmine failure, which would make this a vacuous green.
  if [ "$restored_rc" -ne 0 ] && grep -q "WORKING TREE" "$WORK/e-restored.err"; then
    ok "restoring the tree pass blocks again on the WORKING TREE (rc=$restored_rc) — RED->GREEN round trip closed"
  else
    bad "restored gate did not block on the working tree (rc=$restored_rc) — restore did not take, or it blocked for an unrelated reason"
  fi
fi

# ─────────────────────────────────────────────────────────────────────────────
# F. TREE SCOPE — the tree pass must scan what a PUSH CAN CARRY, and only that.
#
#    `gitleaks --no-git` walks the FILESYSTEM, which is strictly wider than the
#    repo: it also reads untracked and .gitignored paths. Pointed at a real
#    working copy that is not a stricter gate, it is a BROKEN one. It reports
#    findings that are unpushable by construction — stale agent worktrees under
#    .claude/, the developer's own .heimdall/team.json bearer credential, ignored
#    scratch docs. A pre-push gate that blocks every push on a local credential
#    the push cannot carry gets disabled within a day, and the blind spot proof E
#    just closed reopens behind it.
#
#    Why this needs its OWN proof: the defect is INVISIBLE to a clean checkout. A
#    fresh clone — and a fresh CI runner — has no ignored files at all, so proofs
#    A–E pass identically whether the scope is right or wrong. That is exactly
#    how a gate that blocked every real push still produced "15 passed, 0
#    failed". So this proof MANUFACTURES the pollution rather than hoping to
#    encounter it.
#
#    Three coupled assertions, a complete truth table over the pushable set:
#      (i)   IGNORED IS OUT — secrets in .gitignored paths must NOT block.
#      (ii)  FALSIFIABILITY — repoint the scan at the raw filesystem (the pre-fix
#            behaviour) and the SAME pollution MUST block. Without this, the
#            green in (i) is indistinguishable from "the planted secrets were
#            never detectable in the first place".
#      (iii) TRACKED IS IN — with the pollution still present, an uncommitted
#            edit to a TRACKED file must still block. This is the case
#            `--cached` + working-tree content exists to cover, and it proves the
#            scoping did not blind the gate.
#    The third pushable class, untracked-but-not-ignored, is covered by E(iii),
#    which plants exactly that and requires a block — so all three classes hold.
# ─────────────────────────────────────────────────────────────────────────────
echo "F. TREE SCOPE (pushable set only — ignored paths must not block a push):"
SCOPE="$WORK/scopeclone"
if ! git clone -q "$REPO" "$SCOPE" 2>/dev/null; then
  bad "F — could not clone $REPO into a throwaway; the scope proofs did NOT run"
else
  # Same rationale as E: test the gate that is about to be pushed, not the last
  # committed one. A full (never shallow) clone keeps .gitleaksignore fingerprints
  # valid, so the history pass cannot block for an unrelated reason.
  WT_DIFF_F="$WORK/worktree-f.patch"
  ( cd "$REPO" && git diff HEAD --binary ) > "$WT_DIFF_F" 2>/dev/null || : > "$WT_DIFF_F"
  if [ -s "$WT_DIFF_F" ]; then
    ( cd "$SCOPE" && git apply "$WT_DIFF_F" ) 2>/dev/null \
      || bad "F — could not apply the working-tree diff to the clone; proofs below test the COMMITTED gate, not the pending one"
  fi
  chmod +x "$SCOPE/bin/heimdall-selfscan"

  # Manufacture the exact pollution that made the gate unshippable: a real-shaped
  # credential in three .gitignored locations, mirroring the three real classes
  # (agent worktree copy / local team credential / ignored analysis doc).
  # $sk is the runtime-assembled Stripe token from proof C — never a real
  # credential. The developer's actual .heimdall/team.json is never read, copied,
  # or referenced by this suite; only a throwaway clone is written to.
  POLLUTED=".claude/worktrees/stale-agent/fixture.js .heimdall/team.json docs/analysis/scratch-triage.md"
  for p in $POLLUTED; do
    mkdir -p "$SCOPE/$(dirname "$p")"
    printf 'const k = "%s";\n' "$sk" > "$SCOPE/$p"
  done
  # The proof only means anything if git genuinely treats these as unpushable.
  # Assert the premise explicitly, so a .gitignore change surfaces as "the premise
  # moved" rather than as a confusing detection regression further down.
  ignored_all=1
  for p in $POLLUTED; do
    if ! ( cd "$SCOPE" && git check-ignore -q "$p" ); then
      ignored_all=0
      bad "F — $p is NOT gitignored in the clone; this proof's premise no longer holds"
    fi
  done
  if [ "$ignored_all" -eq 1 ]; then
    ok "premise: all 3 planted paths are .gitignored (no push can carry them)"
  fi

  # (i) IGNORED IS OUT — the gate must stay clean.
  scoped_rc=0
  ( cd "$SCOPE" && ./bin/heimdall-selfscan ) >"$WORK/f-ignored.err" 2>&1 || scoped_rc=$?
  if [ "$scoped_rc" -eq 0 ]; then
    ok "secrets in .gitignored paths do NOT block (rc=0) — no wolf-crying on unpushable files"
  else
    bad "gate BLOCKED on .gitignored, unpushable files (rc=$scoped_rc) — the every-push-is-blocked failure"
    grep -iE 'BLOCKED|File:' "$WORK/f-ignored.err" | sed 's/^/      /' | head -8
  fi

  # (ii) FALSIFIABILITY — repoint the tree scan at the raw filesystem (pre-fix).
  SMUT="$SCOPE/bin/heimdall-selfscan"
  cp "$SMUT" "$WORK/selfscan.scoped"
  sed 's|--source "$TREE_TMP"|--source "$HEIMDALL_TOP"|g' "$WORK/selfscan.scoped" > "$SMUT"
  chmod +x "$SMUT"
  if grep -q -- '--source "$TREE_TMP"' "$WORK/selfscan.scoped" \
     && ! grep -q -- '--source "$TREE_TMP"' "$SMUT"; then
    ok "mutation is real (scoped --source in the original, raw-filesystem --source in the mutant)"
  else
    bad "mutation did not repoint the tree scan — the RED below would prove nothing"
  fi
  unscoped_rc=0
  ( cd "$SCOPE" && ./bin/heimdall-selfscan ) >"$WORK/f-unscoped.err" 2>&1 || unscoped_rc=$?
  if [ "$unscoped_rc" -ne 0 ] && grep -q "WORKING TREE" "$WORK/f-unscoped.err"; then
    ok "WITHOUT the scoping the same ignored files DO block (rc=$unscoped_rc) — the scoping earns its place"
  else
    bad "unscoped gate did not block on the ignored pollution (rc=$unscoped_rc) — (i) is vacuous; the planted secrets may not be detectable at all"
  fi

  # (iii) TRACKED IS IN — restore the scoped gate, keep the pollution, and make an
  # UNCOMMITTED edit to a tracked, non-allowlisted file. It must block.
  cp "$WORK/selfscan.scoped" "$SMUT"
  chmod +x "$SMUT"
  TRACKED_VICTIM="README.md"
  if [ ! -f "$SCOPE/$TRACKED_VICTIM" ]; then
    bad "F — $TRACKED_VICTIM missing from the clone; cannot prove tracked files stay in scope"
  else
    printf 'const stripeKey = "%s";\n' "$sk" >> "$SCOPE/$TRACKED_VICTIM"
    tracked_rc=0
    ( cd "$SCOPE" && ./bin/heimdall-selfscan ) >"$WORK/f-tracked.err" 2>&1 || tracked_rc=$?
    if [ "$tracked_rc" -ne 0 ] && grep -q "WORKING TREE" "$WORK/f-tracked.err"; then
      ok "an UNCOMMITTED edit to tracked $TRACKED_VICTIM still BLOCKS (rc=$tracked_rc) — scoping did not blind the gate"
    else
      bad "tracked-file secret did NOT block (rc=$tracked_rc) — the scope is too narrow, real secrets now slip"
    fi
  fi
fi

echo ""
echo "selfscan.test.sh: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
