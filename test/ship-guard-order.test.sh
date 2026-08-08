#!/usr/bin/env bash
#
# ship-guard-order.test.sh — acceptance for release/ship.sh's guard ORDERING.
#
#   bash test/ship-guard-order.test.sh    (exit 0 = all cases pass)
#
# THE DEFECT this locks in the fix for: ship.sh used to bump + commit the version FIRST and
# run the release-blocking guards (the local gitleaks scan, and the pre-push guard's gitleaks
# + heimdall-landmine-lint) AFTERWARD. When a guard blocked the push — e.g. a landmine in a
# release script — the "chore(release): vX.Y.Z" bump commit was left DANGLING in history with
# no tag, no Release, no npm, and the next ship skipped the orphan forever. RJ's rule: the
# version bump only happens at the END, once every guard is green.
#
# This proves, WITHOUT a real release, that:
#   1. STATIC ORDER — in ship.sh, preflight_push_guards is invoked BEFORE the
#      `git commit … chore(release)` line (the guards run pre-bump).
#   2. GITLEAKS FAILURE — a failing gitleaks guard aborts with ZERO new commits: no
#      chore(release) commit, HEAD unchanged, and the working tree is clean/restorable.
#   3. LANDMINE FAILURE — a failing heimdall-landmine-lint guard aborts the SAME way (still
#      no dangling bump), proving it is not gitleaks-specific.
#
# R6 (checks must be able to fail): cases 2 and 3 force a specific guard to fail and assert
# that NO bump commit exists afterward. If ship.sh regressed to bump-then-guard, the
# chore(release) commit would be present and both cases go red.
#
# Hermetic: a throwaway fake plugin repo carries copies of ship.sh + sync-release.sh and the
# minimal artifacts preflight needs; gh/gitleaks/npm are stubbed on PATH; the bump-blocking
# guard is forced to fail. Nothing touches the developer's real repo, and no push/gh/npm runs.
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SELF_DIR/.." && pwd)"
SHIP="$REPO/release/ship.sh"
SYNC="$REPO/release/sync-release.sh"

PASS=0; FAIL=0
ok()  { printf '  \033[32mPASS\033[0m %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAIL=$((FAIL+1)); }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/ship-guard-order-test.XXXXXX")"
[ -n "$WORK" ] || { echo "FATAL: WORK path empty (mktemp failed)" >&2; exit 2; }
cleanup() { rm -rf "$WORK" 2>/dev/null || true; }
trap cleanup EXIT

echo "ship-guard-order harness  ship=$SHIP"
echo "--------------------------------------------------------------------"

# ── Case 1: STATIC — guards are invoked BEFORE the bump commit ────────────────
GUARD_LINE="$(grep -n '^preflight_push_guards$' "$SHIP" | head -1 | cut -d: -f1)"
COMMIT_LINE="$(grep -n 'git commit .* -m "chore(release): \$TAG"' "$SHIP" | head -1 | cut -d: -f1)"
if [ -n "$GUARD_LINE" ] && [ -n "$COMMIT_LINE" ] && [ "$GUARD_LINE" -lt "$COMMIT_LINE" ]; then
  ok "preflight_push_guards (line $GUARD_LINE) runs BEFORE the chore(release) commit (line $COMMIT_LINE)"
else
  bad "guard/commit ordering wrong (guard=$GUARD_LINE commit=$COMMIT_LINE) — the bump must come AFTER the guards"
fi

# ── A fake heimdall plugin repo carrying only what ship.sh's preflight needs ──
make_fake_repo() {  # $1 = dest dir
  local d="$1" bare="$1.git"
  mkdir -p "$d/release" "$d/bin" "$d/.claude-plugin"
  cp "$SHIP" "$d/release/ship.sh"
  cp "$SYNC" "$d/release/sync-release.sh"
  chmod +x "$d/release/ship.sh"
  printf '{\n  "name": "heimdall",\n  "version": "9.9.9"\n}\n' > "$d/.claude-plugin/plugin.json"
  # preflight_release_prereqs requires an executable notes generator.
  printf '#!/usr/bin/env bash\necho "- real changelog line"\n' > "$d/bin/generate-changelog"
  chmod +x "$d/bin/generate-changelog"
  git init -q "$d"
  git -C "$d" config user.email "rj@runheimdall.dev"
  git -C "$d" config user.name "RJ"
  git -C "$d" add -A
  git -C "$d" commit -q -m "initial fake plugin"
  git -C "$d" branch -M main
  git init -q --bare "$bare"
  git -C "$d" remote add origin "$bare"
  git -C "$d" push -q -u origin main
}

# Stub bin: gh always authenticates; gitleaks + landmine behaviour is env-driven.
#   GUARD_GITLEAKS_RC : exit code the gitleaks stub returns (default 0 = clean)
STUB="$WORK/stubbin"; mkdir -p "$STUB"
cat > "$STUB/gh" <<'S'
#!/usr/bin/env bash
case "$1 $2" in "auth status") exit 0 ;; *) exit 0 ;; esac
S
cat > "$STUB/gitleaks" <<'S'
#!/usr/bin/env bash
# Fail only for the FULL-history detect the pre-bump guard runs when asked to.
exit "${GUARD_GITLEAKS_RC:-0}"
S
chmod +x "$STUB/gh" "$STUB/gitleaks"

# Landmine stub used only for the landmine-failure case (SHIP_LANDMINE_LINT points here).
LANDMINE_FAIL="$WORK/landmine-fail"
printf '#!/usr/bin/env bash\necho "landmine: simulated strict-mode landmine" >&2\nexit 1\n' > "$LANDMINE_FAIL"
chmod +x "$LANDMINE_FAIL"

# assert_no_dangling_bump <label> <repo-dir> <baseline-HEAD>
assert_no_dangling_bump() {
  local label="$1" d="$2" base="$3" head_now dirty
  head_now="$(git -C "$d" rev-parse HEAD)"
  if [ "$head_now" = "$base" ]; then
    ok "$label: HEAD unchanged — no new commit ($base)"
  else
    bad "$label: HEAD MOVED $base -> $head_now (a dangling bump commit was created)"
  fi
  # Match WITHOUT a `git … | grep -q` pipe: under `set -o pipefail`, grep -q exits on first
  # match and SIGPIPEs git, making the pipeline non-zero even on a hit (a false negative). A
  # `case` glob on the captured log has no pipe and cannot misfire.
  local log; log="$(git -C "$d" log --oneline)"
  case "$log" in
    *"chore(release)"*) bad "$label: a 'chore(release)' commit exists after the failed guard (the exact dangling-bump defect)" ;;
    *)                  ok  "$label: no 'chore(release)' commit exists after the failed guard" ;;
  esac
  # The tree must be clean/restorable: nothing was written before the guard failed, and
  # `git checkout -- .` restores whatever a partial render might have left.
  git -C "$d" checkout -- . 2>/dev/null || true
  dirty="$(git -C "$d" status --porcelain)"
  if [ -z "$dirty" ]; then
    ok "$label: working tree is clean/restorable (git checkout -- . leaves nothing dirty)"
  else
    bad "$label: working tree still dirty after restore:"; printf '%s\n' "$dirty" | sed 's/^/      /' >&2
  fi
}

# ── Case 2: a FAILING gitleaks guard leaves ZERO new commits ─────────────────
PLUG2="$WORK/plug2"; make_fake_repo "$PLUG2"
BASE2="$(git -C "$PLUG2" rev-parse HEAD)"
C2="$WORK/c2.out"
(
  cd "$PLUG2"
  export GUARD_GITLEAKS_RC=1
  PATH="$STUB:$PATH" bash "$PLUG2/release/ship.sh" --no-npm
) >"$C2" 2>&1
c2_rc=$?
if [ "$c2_rc" -ne 0 ]; then
  ok "gitleaks-fail: ship.sh exits NON-ZERO (rc=$c2_rc — the guard blocked the release)"
else
  bad "gitleaks-fail: ship.sh exited 0 despite a failing gitleaks guard"; sed 's/^/    /' "$C2" >&2
fi
if grep -q 'gitleaks found leaks' "$C2"; then
  ok "gitleaks-fail: the failure names the gitleaks guard"
else
  bad "gitleaks-fail: gitleaks failure reason not surfaced"; sed 's/^/    /' "$C2" >&2
fi
assert_no_dangling_bump "gitleaks-fail" "$PLUG2" "$BASE2"

# ── Case 3: a FAILING landmine-lint guard leaves ZERO new commits ────────────
PLUG3="$WORK/plug3"; make_fake_repo "$PLUG3"
BASE3="$(git -C "$PLUG3" rev-parse HEAD)"
C3="$WORK/c3.out"
(
  cd "$PLUG3"
  export GUARD_GITLEAKS_RC=0 SHIP_LANDMINE_LINT="$LANDMINE_FAIL"
  PATH="$STUB:$PATH" bash "$PLUG3/release/ship.sh" --no-npm
) >"$C3" 2>&1
c3_rc=$?
if [ "$c3_rc" -ne 0 ]; then
  ok "landmine-fail: ship.sh exits NON-ZERO (rc=$c3_rc — the landmine guard blocked the release)"
else
  bad "landmine-fail: ship.sh exited 0 despite a failing landmine guard"; sed 's/^/    /' "$C3" >&2
fi
if grep -q 'landmine' "$C3"; then
  ok "landmine-fail: the failure names the landmine guard"
else
  bad "landmine-fail: landmine failure reason not surfaced"; sed 's/^/    /' "$C3" >&2
fi
assert_no_dangling_bump "landmine-fail" "$PLUG3" "$BASE3"

# ── Case 4: guards PASS -> the bump commit IS created, and AFTER the guards ──────
# The complement of cases 2/3: prove the reorder did not accidentally skip the bump. With
# every guard green (gitleaks rc=0, landmine ok) the flow must reach write_version + the
# chore(release) commit. The render/sync steps are stubbed via ship.sh's own SHIP_RENDERER /
# SHIP_SYNC_RELEASE seams so the bump commits without a full artifact render; the run then
# dies later at R9 (bin/heimdall-check-identities is absent in the fake repo) — but by then
# the bump commit already exists, which is exactly what this case asserts.
PLUG4="$WORK/plug4"; make_fake_repo "$PLUG4"
BASE4="$(git -C "$PLUG4" rev-parse HEAD)"
NOOP="$WORK/noop"; printf '#!/usr/bin/env bash\nexit 0\n' > "$NOOP"; chmod +x "$NOOP"
LANDMINE_OK="$WORK/landmine-ok"; printf '#!/usr/bin/env bash\nexit 0\n' > "$LANDMINE_OK"; chmod +x "$LANDMINE_OK"
C4="$WORK/c4.out"
(
  cd "$PLUG4"
  export GUARD_GITLEAKS_RC=0 SHIP_LANDMINE_LINT="$LANDMINE_OK"
  export SHIP_RENDERER="$NOOP" SHIP_SYNC_RELEASE="$NOOP"
  PATH="$STUB:$PATH" bash "$PLUG4/release/ship.sh" --no-npm
) >"$C4" 2>&1
# The bump commit must exist now (the run may exit non-zero later at R9 — that is expected).
# `case` glob, not `git … | grep -q`: pipefail + grep -q's early exit SIGPIPEs git and would
# report a false negative on a real match.
LOG4="$(git -C "$PLUG4" log --oneline)"
case "$LOG4" in
  *"chore(release)"*) ok "guards-pass: the chore(release) bump commit IS created once every guard is green" ;;
  *) bad "guards-pass: no bump commit was created even though the guards passed"; sed 's/^/    /' "$C4" >&2 ;;
esac
# ...and it landed AFTER the guards ran: the guard success lines precede the bump line in output.
gl_ln="$(grep -n 'no leaks in local history' "$C4" | head -1 | cut -d: -f1)"
bump_ln="$(grep -n 'Version bump (v.*guards green' "$C4" | head -1 | cut -d: -f1)"
if [ -n "$gl_ln" ] && [ -n "$bump_ln" ] && [ "$gl_ln" -lt "$bump_ln" ]; then
  ok "guards-pass: the guards ran BEFORE the version bump (gitleaks ok @L$gl_ln, bump @L$bump_ln)"
else
  bad "guards-pass: could not confirm guards-before-bump ordering in the run output (gl=$gl_ln bump=$bump_ln)"; sed 's/^/    /' "$C4" >&2
fi

echo ""
echo "ship-guard-order.test.sh: $PASS passed, $FAIL failed."
[ "$FAIL" -eq 0 ] || exit 1
exit 0
