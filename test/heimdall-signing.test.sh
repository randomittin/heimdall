#!/usr/bin/env bash
# heimdall-signing.test.sh — THE RELEASE-SIGNING TRUST ROOT falsifier.
#
# The whole security story of auto-update rests on ONE guarantee: bin/heimdall-autoupdate
# APPLIES a release ONLY when its install.sh carries a minisign signature that verifies
# against the in-repo public key (release/heimdall-signing.pub). A compromised channel that
# swaps install.sh — or drops the signature — must be REFUSED, and the client stays put.
#
# HERMETIC. A THROWAWAY minisign keypair is generated in-test (passwordless, -W) and lives
# only in a temp dir — NEVER a real signing key, never the network. We drive:
#   verify lib (bin/lib/heimdall-verify.sh):
#     L1 valid sig → ACCEPT (rc 0)                         [both minisign + python backends]
#     L2 TAMPER one byte → REFUSE (rc 6)  ← the falsifier
#     L3 WRONG key → REFUSE (rc 6)
#     L4 MISSING sig → REFUSE (rc 2)  ← cardinal: unsigned is not applied
#     L5 MISSING pubkey (no trust root) → REFUSE (rc 3)
#   updater (bin/heimdall-autoupdate, verify seam — NO network, NO exec):
#     U1 valid sig → the updater VERIFIES + would apply (log 'verified', prints verified)
#     U2 TAMPER → REFUSE, stay on current (log 'refuse', exit 0)  ← falsifier
#     U3 WRONG key → REFUSE
#     U4 MISSING sig → REFUSE  ← cardinal
#   ship.sh (release/ship.sh signing step, sourced in isolation):
#     S1 NO signing key → WARN + release UNSIGNED (returns 0, NOT a hard block; no sig made)
#     S2 key present → produces a valid install.sh.minisig + uploads it via gh (stubbed)
#   syntax: bash -n over ship.sh + autoupdate + the verify lib.
#
# Requires the minisign binary to MINT the throwaway keypair — SKIP cleanly if absent.
# Exit 0 = every proof holds.

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SELF_DIR/.." && pwd)"
LIB="$REPO/bin/lib/heimdall-verify.sh"
UPDATER="$REPO/bin/heimdall-autoupdate"
SHIP="$REPO/release/ship.sh"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf "  \033[32mPASS\033[0m %s\n" "$1"; }
bad() { FAIL=$((FAIL+1)); printf "  \033[31mFAIL\033[0m %s\n" "$1"; }

[ -f "$LIB" ]      || { echo "FATAL: verify lib missing: $LIB" >&2; exit 2; }
[ -x "$UPDATER" ]  || { echo "FATAL: updater missing/not executable: $UPDATER" >&2; exit 2; }
[ -f "$SHIP" ]     || { echo "FATAL: ship.sh missing: $SHIP" >&2; exit 2; }

if ! command -v minisign >/dev/null 2>&1; then
  echo "  SKIP no minisign binary — cannot mint a throwaway keypair (brew install minisign)."
  echo "── heimdall-signing: 0 passed, 0 failed (SKIPPED — no minisign) ──"
  exit 0
fi

# ── syntax gate ─────────────────────────────────────────────────────────────────
bash -n "$SHIP"     && ok "bash -n release/ship.sh"            || bad "ship.sh has a syntax error"
bash -n "$UPDATER"  && ok "bash -n bin/heimdall-autoupdate"    || bad "autoupdate has a syntax error"
bash -n "$LIB"      && ok "bash -n bin/lib/heimdall-verify.sh" || bad "verify lib has a syntax error"

# ── hermetic keypair(s) + fixture ─────────────────────────────────────────────────
WORK="$(mktemp -d -t hmd-signing.XXXXXX)"
cleanup() { rm -rf "$WORK" 2>/dev/null || true; }
trap cleanup EXIT

PUB_A="$WORK/keyA.pub"; SEC_A="$WORK/keyA.key"
PUB_B="$WORK/keyB.pub"; SEC_B="$WORK/keyB.key"
minisign -G -W -f -p "$PUB_A" -s "$SEC_A" >/dev/null 2>&1 || { echo "FATAL: keygen A failed" >&2; exit 2; }
minisign -G -W -f -p "$PUB_B" -s "$SEC_B" >/dev/null 2>&1 || { echo "FATAL: keygen B failed" >&2; exit 2; }

ARTIFACT="$WORK/install.sh"
printf '#!/usr/bin/env bash\n# throwaway release fixture — %s\necho heimdall-fixture\n' "$RANDOM$RANDOM" > "$ARTIFACT"

SIG_A="$WORK/install.sh.minisig"        # good sig by key A
SIG_B="$WORK/install.sh.b.minisig"      # sig by key B (wrong key vs pub A)
minisign -Sq -s "$SEC_A" -m "$ARTIFACT" -x "$SIG_A" -c "heimdall test" -t "heimdall release test A" >/dev/null 2>&1 \
  || { echo "FATAL: sign A failed" >&2; exit 2; }
minisign -Sq -s "$SEC_B" -m "$ARTIFACT" -x "$SIG_B" -c "heimdall test" -t "heimdall release test B" >/dev/null 2>&1 \
  || { echo "FATAL: sign B failed" >&2; exit 2; }

TAMPERED="$WORK/install.tampered.sh"
cp "$ARTIFACT" "$TAMPERED"; printf '# tamper\n' >> "$TAMPERED"   # sig no longer matches the bytes

# ── L. verify lib (source it; assert distinct return codes) ────────────────────────
# shellcheck source=/dev/null
. "$LIB"

heimdall_verify_release "$ARTIFACT" "$SIG_A" "$PUB_A"; rc=$?
[ "$rc" -eq 0 ] && ok "L1 valid sig ACCEPTED (rc 0)" || bad "L1 valid sig should accept (rc=$rc)"

heimdall_verify_release "$TAMPERED" "$SIG_A" "$PUB_A"; rc=$?
[ "$rc" -eq 6 ] && ok "L2 FALSIFIER: tampered artifact REFUSED (rc 6 invalid)" || bad "L2 tamper must be rc 6 (got $rc)"

heimdall_verify_release "$ARTIFACT" "$SIG_B" "$PUB_A"; rc=$?
[ "$rc" -eq 6 ] && ok "L3 wrong-key sig REFUSED (rc 6)" || bad "L3 wrong key must be rc 6 (got $rc)"

heimdall_verify_release "$ARTIFACT" "$WORK/nope.minisig" "$PUB_A"; rc=$?
[ "$rc" -eq 2 ] && ok "L4 CARDINAL: missing sig REFUSED (rc 2 — unsigned not applied)" || bad "L4 missing sig must be rc 2 (got $rc)"

heimdall_verify_release "$ARTIFACT" "$SIG_A" "$WORK/nope.pub"; rc=$?
[ "$rc" -eq 3 ] && ok "L5 missing pubkey (no trust root) REFUSED (rc 3)" || bad "L5 missing pubkey must be rc 3 (got $rc)"

# L6/L7 — the BUNDLED python verifier is a real, independent backend (clients without the
# minisign binary still verify). Force it and re-prove accept + tamper.
HEIMDALL_VERIFY_BACKEND=python heimdall_verify_release "$ARTIFACT" "$SIG_A" "$PUB_A"; rc=$?
[ "$rc" -eq 0 ] && ok "L6 python backend ACCEPTS a valid sig (rc 0)" || bad "L6 python backend should accept (rc=$rc)"

HEIMDALL_VERIFY_BACKEND=python heimdall_verify_release "$TAMPERED" "$SIG_A" "$PUB_A"; rc=$?
[ "$rc" -eq 6 ] && ok "L7 python backend REFUSES a tampered artifact (rc 6)" || bad "L7 python backend should refuse tamper (rc=$rc)"

# ── U. updater refusal falsifiers (verify seam: no network, no exec) ───────────────
# Installed version drives the semver decision; pick a strictly-greater "latest" so
# apply_update is reached. VERIFY_ONLY stops before executing anything.
INSTALLED="$("$UPDATER" status 2>/dev/null | sed -n 's/^installed:[[:space:]]*//p' | head -1)"
[ -n "$INSTALLED" ] || { echo "FATAL: could not resolve installed version" >&2; exit 2; }
IFS=. read -r _MA _MI _PA <<EOF
$INSTALLED
EOF
NEWER="${_MA}.${_MI}.$((_PA + 1))"

last_log() { tail -1 "$1/autoupdate.log" 2>/dev/null || true; }

# U1 valid → verified, would-apply (no refuse).
H="$(mktemp -d)"
OUT="$(HEIMDALL_HOME="$H" HEIMDALL_LATEST_OVERRIDE="$NEWER" HEIMDALL_VERIFY_ONLY=1 \
  HEIMDALL_INSTALL_ARTIFACT="$ARTIFACT" HEIMDALL_INSTALL_SIG="$SIG_A" \
  HEIMDALL_SIGNING_PUBKEY="$PUB_A" "$UPDATER" --force 2>/dev/null)"
if grep -q "verified $NEWER" <<<"$OUT" && grep -q 'verified' "$H/autoupdate.log" 2>/dev/null \
   && ! grep -q 'refuse' "$H/autoupdate.log" 2>/dev/null; then
  ok "U1 valid sig → updater VERIFIES + would apply (no refuse)"
else
  bad "U1 expected verified, got out='$OUT' log='$(last_log "$H")'"
fi
rm -rf "$H"

# U2 tamper → REFUSE, stay (exit 0).
H="$(mktemp -d)"
HEIMDALL_HOME="$H" HEIMDALL_LATEST_OVERRIDE="$NEWER" HEIMDALL_VERIFY_ONLY=1 \
  HEIMDALL_INSTALL_ARTIFACT="$TAMPERED" HEIMDALL_INSTALL_SIG="$SIG_A" \
  HEIMDALL_SIGNING_PUBKEY="$PUB_A" "$UPDATER" --force >/dev/null 2>&1
rc=$?
if [ "$rc" -eq 0 ] && grep -q 'refuse' "$H/autoupdate.log" 2>/dev/null \
   && ! grep -q 'verified' "$H/autoupdate.log" 2>/dev/null; then
  ok "U2 FALSIFIER: tampered install.sh → updater REFUSES, stays on current (exit 0)"
else
  bad "U2 tamper should refuse (rc=$rc log='$(last_log "$H")')"
fi
rm -rf "$H"

# U3 wrong key → REFUSE.
H="$(mktemp -d)"
HEIMDALL_HOME="$H" HEIMDALL_LATEST_OVERRIDE="$NEWER" HEIMDALL_VERIFY_ONLY=1 \
  HEIMDALL_INSTALL_ARTIFACT="$ARTIFACT" HEIMDALL_INSTALL_SIG="$SIG_B" \
  HEIMDALL_SIGNING_PUBKEY="$PUB_A" "$UPDATER" --force >/dev/null 2>&1
if grep -q 'refuse' "$H/autoupdate.log" 2>/dev/null && ! grep -q 'verified' "$H/autoupdate.log" 2>/dev/null; then
  ok "U3 wrong-key sig → updater REFUSES"
else
  bad "U3 wrong key should refuse (log='$(last_log "$H")')"
fi
rm -rf "$H"

# U4 missing sig → REFUSE (cardinal).
H="$(mktemp -d)"
HEIMDALL_HOME="$H" HEIMDALL_LATEST_OVERRIDE="$NEWER" HEIMDALL_VERIFY_ONLY=1 \
  HEIMDALL_INSTALL_ARTIFACT="$ARTIFACT" HEIMDALL_INSTALL_SIG="" \
  HEIMDALL_SIGNING_PUBKEY="$PUB_A" "$UPDATER" --force >/dev/null 2>&1
if grep -q 'refuse' "$H/autoupdate.log" 2>/dev/null && ! grep -q 'verified' "$H/autoupdate.log" 2>/dev/null; then
  ok "U4 CARDINAL: missing signature → updater REFUSES (unsigned never applied)"
else
  bad "U4 missing sig should refuse (log='$(last_log "$H")')"
fi
rm -rf "$H"

# ── S. ship.sh signing step (sourced in isolation — no push, no release) ───────────
# S1 — no signing key present → WARN + UNSIGNED, and the function returns 0 (NOT a die).
OUT="$(SHIP_SOURCE_ONLY=1 bash -c '
  . "'"$SHIP"'" || true
  set +e +o pipefail
  HEIMDALL_SIGNING_KEY="'"$WORK"'/does-not-exist.key" SHIP_ARTIFACT="'"$ARTIFACT"'" \
    sign_release_artifact v9.9.9
  echo "RC=$?"
' 2>&1)"
if grep -qi 'UNSIGNED' <<<"$OUT" && grep -q 'RC=0' <<<"$OUT"; then
  ok "S1 no signing key → ship WARNS + releases UNSIGNED (returns 0, not a hard block)"
else
  bad "S1 missing-key path wrong: $OUT"
fi

# S2 — key present + a stubbed gh → a real install.sh.minisig is produced and uploaded,
# and it verifies against the matching public key.
STUBDIR="$WORK/stub"; mkdir -p "$STUBDIR"
GH_ASSET="$WORK/uploaded.minisig"
cat > "$STUBDIR/gh" <<STUB
#!/usr/bin/env bash
# fake gh: record the uploaded asset so the test can verify it. Never touches the network.
for a in "\$@"; do
  case "\$a" in
    *install.sh.minisig*) cp "\${a%%#*}" "$GH_ASSET" 2>/dev/null || true ;;
  esac
done
exit 0
STUB
chmod +x "$STUBDIR/gh"
SHIP_SOURCE_ONLY=1 PATH="$STUBDIR:$PATH" bash -c '
  . "'"$SHIP"'" || true
  set +e +o pipefail
  HEIMDALL_SIGNING_KEY="'"$SEC_A"'" SHIP_ARTIFACT="'"$ARTIFACT"'" \
    sign_release_artifact v9.9.9
' >/dev/null 2>&1
if [ -s "$GH_ASSET" ] && minisign -Vq -p "$PUB_A" -m "$ARTIFACT" -x "$GH_ASSET" >/dev/null 2>&1; then
  ok "S2 key present → ship produces a valid install.sh.minisig and uploads it (gh stub)"
else
  bad "S2 signing/upload path did not produce a verifiable sig (asset='$GH_ASSET')"
fi

# ── tally ──────────────────────────────────────────────────────────────────────
echo ""
echo "── heimdall-signing: $PASS passed, $FAIL failed ──"
[ "$FAIL" -eq 0 ] || exit 1
