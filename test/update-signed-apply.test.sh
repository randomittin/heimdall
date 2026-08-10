#!/usr/bin/env bash
# update-signed-apply.test.sh — the SIGNED-APPLY correctness + manual-update falsifiers.
#
# Two bugs this suite pins RED-without-fix:
#   BUG-A  auto-update FIRES but installs the WRONG version. apply_update ran the verified
#          install.sh WITHOUT pinning HEIMDALL_REF, so install.sh's baked DEFAULT_REF (a
#          stale v2.0.5) won — every "upgrade" silently DOWNGRADED, then re-triggered forever.
#          Fix: apply pins HEIMDALL_REF=v<latest> so the EXACT resolved+verified version installs.
#   BUG-B  `hmd --update` was a git-branch reset (`git reset --hard origin/main`) with ZERO
#          signature verification — fail-OPEN, wrong channel (branch tip, not the signed
#          release). Fix: `hmd --update` delegates to `heimdall-autoupdate update`, a foreground,
#          LOUD, fail-CLOSED signed apply (verify against the in-tree pubkey, refuse tamper).
#
# WHAT IT PROVES (each a falsifier — a wrong build goes RED):
#   A  apply installs the RESOLVED version: a stub install.sh records $HEIMDALL_REF; a valid
#      signed foreground apply with latest=vX must hand the stub HEIMDALL_REF=vX (NOT a
#      DEFAULT_REF / empty).                                             ← BUG-A falsifier
#   B  `update` (manual) valid+newer → applies (stub ran) + exit 0.
#   C  `update` (manual) TAMPERED+newer → REFUSES, stub NEVER runs, exit NON-zero, loud stderr.
#                                                                        ← BUG-B fail-closed
#   D  `update` (manual) already-current (latest==installed) → "already", stub not run, exit 0.
#   E  static: bin/heimdall's `--update` no longer does `git reset --hard origin/main` and DOES
#      route through `heimdall-autoupdate` (the signed path).            ← BUG-B channel
#
# A/B/C/D need the minisign binary to MINT a throwaway keypair — SKIP cleanly if absent.
# E is static (no minisign) and always runs. Exit 0 = every proof holds.

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SELF_DIR/.." && pwd)"
UPDATER="$REPO/bin/heimdall-autoupdate"
LAUNCHER="$REPO/bin/heimdall"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf "  \033[32mPASS\033[0m %s\n" "$1"; }
bad() { FAIL=$((FAIL+1)); printf "  \033[31mFAIL\033[0m %s\n" "$1"; }

[ -x "$UPDATER" ]  || { echo "FATAL: updater missing/not executable: $UPDATER" >&2; exit 2; }
[ -f "$LAUNCHER" ] || { echo "FATAL: launcher missing: $LAUNCHER" >&2; exit 2; }

# ══════════════════════════════════════════════════════════════════════════════
# HERMETIC SANDBOX FOR THE MACHINE-SCOPED SURFACES — read this before editing.
#
# THE INCIDENT THIS PREVENTS (it happened, to this suite, on a developer's machine).
# Cases A/B/G below drive a FOREGROUND signed apply. apply_update ends by calling
# heimdall-autoupdate's reassert_dream_schedule, which runs the REAL
# bin/heimdall-dream-schedule install — three hops from anything this file names.
# That helper writes ~/Library/LaunchAgents/com.heimdall.dream.plist and stages its
# runner into $HEIMDALL_HOME/bin. This suite set HEIMDALL_HOME to a bare `mktemp -d`
# and set nothing else, so the developer's live nightly LaunchAgent was OVERWRITTEN
# with a plist whose ProgramArguments[0] pointed at /var/folders/…/tmp.*/bin — a
# directory reaped minutes later. The nightly job was left pinned to a path that no
# longer existed: no error, dreams simply stopped arriving.
#
# WHY $HOME IS NOT THE ANSWER. Setting HOME=$(mktemp -d) would isolate WHERE the
# plist lands but NOT which launchd hears about it — `launchctl` targets the
# logged-in user's GUI session domain (gui/<uid>), which no environment variable
# reaches. bin/lib/real-home.sh documents that floor in full. So each machine-scoped
# surface is redirected at ITS OWN seam, and the passwd-DB floor is driven too.
#
# FOUR SEAMS, EACH INDEPENDENTLY SUFFICIENT (defence in depth, deliberately):
#   HEIMDALL_REAL_HOME         → the passwd floor. Makes heimdall_home_is_real FALSE,
#                                so require_real_launchd_domain REFUSES outright and
#                                nothing is written even into the sandbox. This is the
#                                seam that needs no cooperation from future callers.
#   HEIMDALL_LAUNCH_AGENTS_DIR → if that refusal is ever removed, the plist still
#                                lands here, inside the sandbox, not in ~/Library.
#   LAUNCHCTL                  → the launchd domain itself. A shim records calls, so
#                                the real per-user launchd is never contacted.
#   HEIMDALL_HOME              → the staged runner + logs land here, not in ~/.heimdall.
#
# This mirrors test/heimdall-dream-schedule.test.sh, which established the pattern.
# NOTHING about the signed-apply proofs below changes: A–H still exercise the real
# signature-verification and ref-pinning behaviour, only against a sandbox.
# ══════════════════════════════════════════════════════════════════════════════
SANDBOX="$(mktemp -d -t hmd-apply-sandbox.XXXXXX)"
trap 'rm -rf "$SANDBOX" 2>/dev/null || true' EXIT

SB_LA="$SANDBOX/LaunchAgents"          # stand-in for ~/Library/LaunchAgents
SB_HOME="$SANDBOX/heimdall-home"       # stand-in for ~/.heimdall
SB_REAL="$SANDBOX/passwd-home"         # a passwd home that is provably NOT $HOME
SB_CALLS="$SANDBOX/launchctl-calls"    # every launchctl invocation, one per line
mkdir -p "$SB_LA" "$SB_HOME" "$SB_REAL"

SB_LAUNCHCTL="$SANDBOX/mock-launchctl"
cat > "$SB_LAUNCHCTL" <<EOF
#!/usr/bin/env bash
# Records the call and succeeds. The real launchd domain is never reached.
echo "\$@" >> "$SB_CALLS"
exit 0
EOF
chmod +x "$SB_LAUNCHCTL"

export HEIMDALL_LAUNCH_AGENTS_DIR="$SB_LA"
export LAUNCHCTL="$SB_LAUNCHCTL"
export HEIMDALL_HOME="$SB_HOME"
export HEIMDALL_REAL_HOME="$SB_REAL"

echo "── update-signed-apply ──"

# ── syntax ────────────────────────────────────────────────────────────────────
bash -n "$UPDATER"  && ok "bash -n bin/heimdall-autoupdate" || bad "autoupdate syntax error"
bash -n "$LAUNCHER" && ok "bash -n bin/heimdall"            || bad "heimdall syntax error"

# ── E. static: manual update routes through the SIGNED path, not an unsigned git reset ──
# Isolate the `--update` block so an unrelated `git reset` elsewhere can't mask the change.
# Strip whole-line comments first: a comment that MENTIONS the old reset (documentation) must
# not fail the check — only an EXECUTABLE `git reset --hard origin/main` is the regression.
UPD_BLOCK="$(awk '/^# --update: pull latest/,/^# --reinstall:/' "$LAUNCHER" | grep -vE '^[[:space:]]*#')"
if ! grep -q 'reset --hard origin/main' <<<"$UPD_BLOCK" \
   && grep -q 'heimdall-autoupdate' <<<"$UPD_BLOCK"; then
  ok "E hmd --update routes through heimdall-autoupdate (no unsigned 'git reset --hard origin/main')"
else
  bad "E --update still does an unsigned git reset OR does not delegate to heimdall-autoupdate"
fi

# ── F. ship.sh bumps install.sh DEFAULT_REF to the release tag (RC3 falsifier) ─
# A fresh `curl|bash` install fetches DEFAULT_REF; a stale default (historically v2.0.5)
# shipped a year-old build to every new teammate. ship.sh must rewrite it on release.
SHIP="$REPO/release/ship.sh"
if [ -f "$SHIP" ]; then
  FWORK="$(mktemp -d)"; cp "$REPO/install.sh" "$FWORK/install.sh"
  SHIP_SOURCE_ONLY=1 bash -c '
    . "'"$SHIP"'" || true
    SHIP_INSTALL_SH="'"$FWORK"'/install.sh" REPO_ROOT="'"$FWORK"'" bump_default_ref v9.9.9
  ' >/dev/null 2>&1
  if grep -q 'local DEFAULT_REF="v9.9.9"' "$FWORK/install.sh" 2>/dev/null; then
    ok "F ship.sh bump_default_ref rewrites install.sh DEFAULT_REF to the release tag"
  else
    bad "F bump_default_ref did NOT pin DEFAULT_REF (got: $(grep DEFAULT_REF "$FWORK/install.sh" 2>/dev/null | head -1))"
  fi
  rm -rf "$FWORK"
else
  bad "F release/ship.sh missing"
fi

# Also assert the committed install.sh is not stuck on the ancient stale default.
if grep -Eq 'local DEFAULT_REF="v2\.0\.[0-4]"' "$REPO/install.sh"; then
  bad "F2 committed install.sh DEFAULT_REF is still a stale pre-v2.0.5 default"
else
  ok "F2 committed install.sh DEFAULT_REF is not the stale downgrade default"
fi

# ── minisign gate for the live-apply proofs ───────────────────────────────────
if ! command -v minisign >/dev/null 2>&1; then
  echo "  SKIP no minisign binary — cannot mint a throwaway keypair for A–D (brew install minisign)."
  echo ""
  echo "── update-signed-apply: $PASS passed, $FAIL failed (A–D skipped — no minisign) ──"
  [ "$FAIL" -eq 0 ] || exit 1
  exit 0
fi

WORK="$(mktemp -d -t hmd-apply.XXXXXX)"
# Replaces the SANDBOX-only trap installed above; both trees must still be reclaimed.
cleanup() { rm -rf "$WORK" "$SANDBOX" 2>/dev/null || true; }
trap cleanup EXIT

PUB="$WORK/key.pub"; SEC="$WORK/key.key"
minisign -G -W -f -p "$PUB" -s "$SEC" >/dev/null 2>&1 || { echo "FATAL: keygen failed" >&2; exit 2; }

# The stub "install.sh": on run it records the HEIMDALL_REF it was handed (proves the pin)
# and that it executed at all (proves apply reached exec). Writes to $HMD_TEST_RECORD.
ARTIFACT="$WORK/install.sh"
cat > "$ARTIFACT" <<'STUB'
#!/usr/bin/env bash
# throwaway release fixture — records the ref it was pinned to.
printf '%s' "${HEIMDALL_REF:-<UNSET>}" > "${HMD_TEST_RECORD:-/dev/null}"
STUB

SIG="$WORK/install.sh.minisig"
minisign -Sq -s "$SEC" -m "$ARTIFACT" -x "$SIG" -c "heimdall test" -t "apply test" >/dev/null 2>&1 \
  || { echo "FATAL: sign failed" >&2; exit 2; }

TAMPERED="$WORK/install.tampered.sh"
cp "$ARTIFACT" "$TAMPERED"; printf '\n# tamper\n' >> "$TAMPERED"   # sig no longer matches

# Installed version drives the semver decision; pick a strictly-greater "latest".
INSTALLED="$("$UPDATER" status 2>/dev/null | sed -n 's/^installed:[[:space:]]*//p' | head -1)"
[ -n "$INSTALLED" ] || { echo "FATAL: could not resolve installed version" >&2; exit 2; }
IFS=. read -r _MA _MI _PA <<EOF
$INSTALLED
EOF
NEWER="${_MA}.${_MI}.$((_PA + 1))"

# ── A. apply pins HEIMDALL_REF to the RESOLVED version (BUG-A falsifier) ───────
H="$(mktemp -d)"; REC="$H/ref.rec"; : > "$REC"
HEIMDALL_HOME="$H" HMD_TEST_RECORD="$REC" \
  HEIMDALL_LATEST_OVERRIDE="$NEWER" HEIMDALL_APPLY_FOREGROUND=1 \
  HEIMDALL_INSTALL_ARTIFACT="$ARTIFACT" HEIMDALL_INSTALL_SIG="$SIG" \
  HEIMDALL_SIGNING_PUBKEY="$PUB" "$UPDATER" --force >/dev/null 2>&1
GOT="$(cat "$REC" 2>/dev/null)"
if [ "$GOT" = "v$NEWER" ]; then
  ok "A apply pins HEIMDALL_REF to the resolved version (installs v$NEWER, not a stale DEFAULT_REF)"
else
  bad "A apply did NOT pin the ref — stub saw HEIMDALL_REF='$GOT' (expected 'v$NEWER')"
fi
rm -rf "$H"

# ── B. manual `update` valid+newer → applies (stub ran) + exit 0 ──────────────
H="$(mktemp -d)"; REC="$H/ref.rec"; : > "$REC"
HEIMDALL_HOME="$H" HMD_TEST_RECORD="$REC" \
  HEIMDALL_LATEST_OVERRIDE="$NEWER" \
  HEIMDALL_INSTALL_ARTIFACT="$ARTIFACT" HEIMDALL_INSTALL_SIG="$SIG" \
  HEIMDALL_SIGNING_PUBKEY="$PUB" "$UPDATER" update >/dev/null 2>&1
rc=$?
if [ "$rc" -eq 0 ] && [ "$(cat "$REC" 2>/dev/null)" = "v$NEWER" ]; then
  ok "B manual 'update' valid+newer → verifies + applies foreground (exit 0, stub ran)"
else
  bad "B manual update should apply (rc=$rc rec='$(cat "$REC" 2>/dev/null)')"
fi
rm -rf "$H"

# ── C. manual `update` TAMPERED → REFUSE, stub never runs, exit non-zero, loud ─
H="$(mktemp -d)"; REC="$H/ref.rec"; : > "$REC"
ERR="$(HEIMDALL_HOME="$H" HMD_TEST_RECORD="$REC" \
  HEIMDALL_LATEST_OVERRIDE="$NEWER" \
  HEIMDALL_INSTALL_ARTIFACT="$TAMPERED" HEIMDALL_INSTALL_SIG="$SIG" \
  HEIMDALL_SIGNING_PUBKEY="$PUB" "$UPDATER" update 2>&1 >/dev/null)"
rc=$?
if [ "$rc" -ne 0 ] && [ -z "$(cat "$REC" 2>/dev/null)" ] \
   && grep -qi 'refus' <<<"$ERR"; then
  ok "C manual 'update' TAMPERED → REFUSES fail-closed (exit $rc, stub NOT run, loud stderr)"
else
  bad "C tamper should refuse loudly + nonzero + no exec (rc=$rc rec='$(cat "$REC" 2>/dev/null)' err='$ERR')"
fi
rm -rf "$H"

# ── D. manual `update` already-current → 'already', stub not run, exit 0 ───────
H="$(mktemp -d)"; REC="$H/ref.rec"; : > "$REC"
OUT="$(HEIMDALL_HOME="$H" HMD_TEST_RECORD="$REC" \
  HEIMDALL_LATEST_OVERRIDE="$INSTALLED" \
  HEIMDALL_INSTALL_ARTIFACT="$ARTIFACT" HEIMDALL_INSTALL_SIG="$SIG" \
  HEIMDALL_SIGNING_PUBKEY="$PUB" "$UPDATER" update 2>&1)"
rc=$?
if [ "$rc" -eq 0 ] && [ -z "$(cat "$REC" 2>/dev/null)" ] \
   && grep -qi 'latest' <<<"$OUT"; then
  ok "D manual 'update' already-current → no apply, says 'latest', exit 0"
else
  bad "D already-current should no-op cleanly (rc=$rc rec='$(cat "$REC" 2>/dev/null)' out='$OUT')"
fi
rm -rf "$H"

# ── G. THE MARQUEE FALSIFIER: a MUCH-older install climbs to the current release ──
# installed=v2.0.5 (akshat) + latest=v2.0.20 signed → foreground apply pins
# HEIMDALL_REF=v2.0.20 and the stub RUNS. Proves v2.0.20's updater reliably climbs
# from an ARBITRARY old version (the exact akshat/Madhavan bootstrap-then-climb case),
# not merely installed+1. RED without the HEIMDALL_INSTALLED_OVERRIDE seam or a broken pin.
H="$(mktemp -d)"; REC="$H/ref.rec"; : > "$REC"
HEIMDALL_HOME="$H" HMD_TEST_RECORD="$REC" \
  HEIMDALL_INSTALLED_OVERRIDE="2.0.5" HEIMDALL_LATEST_OVERRIDE="2.0.20" \
  HEIMDALL_INSTALL_ARTIFACT="$ARTIFACT" HEIMDALL_INSTALL_SIG="$SIG" \
  HEIMDALL_SIGNING_PUBKEY="$PUB" "$UPDATER" update >/dev/null 2>&1
rc=$?
if [ "$rc" -eq 0 ] && [ "$(cat "$REC" 2>/dev/null)" = "v2.0.20" ]; then
  ok "G climb v2.0.5 → v2.0.20: signed apply pins HEIMDALL_REF=v2.0.20 (exact release installs, not DEFAULT_REF)"
else
  bad "G old-install climb failed (rc=$rc rec='$(cat "$REC" 2>/dev/null)' expected 'v2.0.20')"
fi
rm -rf "$H"

# ── H. same big jump, TAMPERED release → REFUSE fail-closed, stub NEVER runs ──────
H="$(mktemp -d)"; REC="$H/ref.rec"; : > "$REC"
ERR="$(HEIMDALL_HOME="$H" HMD_TEST_RECORD="$REC" \
  HEIMDALL_INSTALLED_OVERRIDE="2.0.5" HEIMDALL_LATEST_OVERRIDE="2.0.20" \
  HEIMDALL_INSTALL_ARTIFACT="$TAMPERED" HEIMDALL_INSTALL_SIG="$SIG" \
  HEIMDALL_SIGNING_PUBKEY="$PUB" "$UPDATER" update 2>&1 >/dev/null)"
rc=$?
if [ "$rc" -ne 0 ] && [ -z "$(cat "$REC" 2>/dev/null)" ] \
   && grep -qi 'refus' <<<"$ERR"; then
  ok "H climb v2.0.5 → v2.0.20 TAMPERED → REFUSES fail-closed (exit $rc, stub NOT run)"
else
  bad "H tampered big-jump should refuse loudly + nonzero + no exec (rc=$rc rec='$(cat "$REC" 2>/dev/null)' err='$ERR')"
fi
rm -rf "$H"

# ── I. SANDBOX INTEGRITY: the machine-scoped seams survived every case above ──────
# The apply cases each export their own per-case env. A future case that forgot to
# carry a seam through — or unset one — would silently re-open the exact hole that
# overwrote a developer's live LaunchAgent. This asserts, AFTER all of A–H have run,
# that every seam still resolves INSIDE the sandbox. It is the cheap tripwire that
# makes the isolation above self-verifying rather than merely intended.
SB_LEAK=""
for _sv in HEIMDALL_LAUNCH_AGENTS_DIR LAUNCHCTL HEIMDALL_HOME HEIMDALL_REAL_HOME; do
  eval "_svv=\${$_sv:-}"
  case "$_svv" in
    "$SANDBOX"/*) : ;;
    *) SB_LEAK="$SB_LEAK $_sv=${_svv:-<UNSET>}" ;;
  esac
done
if [ -z "$SB_LEAK" ]; then
  ok "I sandbox intact — every machine-scoped seam still points inside \$SANDBOX"
else
  bad "I MACHINE-SCOPED SEAM ESCAPED the sandbox:$SB_LEAK"
fi

echo ""
echo "── update-signed-apply: $PASS passed, $FAIL failed ──"
[ "$FAIL" -eq 0 ] || exit 1
