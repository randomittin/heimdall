#!/usr/bin/env bash
#
# heimdall-hmd-shadow.test.sh — locks down the installer bug that silently
# stranded teammates on an OLD version despite reinstalling.
#
# THE BUG (live evidence, Madhavan's reinstall):
#   install.sh reported "Heimdall v2.0.21 installed" but `hmd --version` = v2.0.5.
#   Root cause: a LEGACY superx-era `hmd` at ~/.superx/bin/hmd sat EARLIER on PATH
#   than the new ~/.local/bin/hmd. The old installer's rule was "if any hmd already
#   exists, refuse to touch it (install `heimdall` only) unless HEIMDALL_FORCE_HMD=1".
#   So the stale hmd kept answering `hmd` → the user THOUGHT they upgraded but ran
#   the old binary forever.
#
# THE FIX (proven here):
#   The installer distinguishes OUR OWN stale binary (heimdall/superx-owned — safe
#   to overwrite) from a genuinely FOREIGN `hmd` (e.g. PyPI hmd-cli-app — never
#   clobber without the force flag). Detection signal: the binary/symlink-target
#   lives under a ~/.heimdall or ~/.superx tree, OR its body carries a
#   heimdall/superx marker.
#
# THE PROOFS (all hermetic — `claude` is a recording PATH fake; the plugin tree is
# cloned from THIS working tree; no network):
#   A. OURS stale hmd, shadowing from an earlier PATH dir → OVERWRITTEN IN PLACE.
#      The resulting `hmd` on PATH resolves to the NEW launcher, not the stale one.
#      (RED on the pre-fix installer: the stale binary survives.)
#   B. FOREIGN hmd, no force → PRESERVED byte-for-byte; canonical hmd NOT installed;
#      guidance + force hint printed.
#   C. FOREIGN hmd, HEIMDALL_FORCE_HMD=1 → canonical hmd IS installed, yet the
#      foreign binary is STILL preserved (never clobbered — data-loss safety).
#
# Exit 0 = every proof holds. Nonzero = a proof regressed (prints which).
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SELF_DIR/.." && pwd)"
REF="$(git -C "$REPO" rev-parse HEAD)"
INSTALLER="${HMD_SHADOW_INSTALLER:-$REPO/install.sh}"   # overridable for a RED run

PASS=0; FAIL=0
ok()  { printf '  \033[32mPASS\033[0m %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAIL=$((FAIL+1)); }

need() { command -v "$1" >/dev/null 2>&1 || { echo "FATAL: $1 not found on PATH"; exit 2; }; }
need git; need python3; need readlink

[ -x "$REPO/bin/heimdall" ] || { echo "FATAL: bin/heimdall not executable"; exit 2; }
[ -f "$INSTALLER" ]         || { echo "FATAL: installer not found: $INSTALLER"; exit 2; }

# ── Recording fake `claude`: satisfies the installer's preflight + plugin steps
#    with no network and no real Claude Code. ─────────────────────────────────
FAKE_DIR="$(mktemp -d)"
cat > "$FAKE_DIR/claude" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
  --version) echo "1.5.0 (Claude Code)"; exit 0 ;;
  *)         exit 0 ;;
esac
EOF
chmod +x "$FAKE_DIR/claude"

TMP_ROOT="$(mktemp -d)"
# Cleanup: the installer spawns a fire-and-forget `heimdall-funnel` that may still
# be writing under $HOME/.heimdall when we tear down — settle briefly, force-writable,
# then remove tolerantly so no stray `rm: Directory not empty` noise leaks to stderr.
cleanup() {
  sleep 1
  chmod -R u+w "$TMP_ROOT" 2>/dev/null || true
  rm -rf "$FAKE_DIR" "$TMP_ROOT" 2>/dev/null || true
}
trap cleanup EXIT

SYS="$(dirname "$(command -v python3)"):$(dirname "$(command -v git)"):/usr/bin:/bin"

# run_install HOME SHADOW_DIR [extra env assignments…]
#   Runs the installer under test against a fresh $HOME, with a fake claude and a
#   caller-chosen SHADOW_DIR placed FIRST on PATH (so a planted hmd there shadows
#   the canonical ~/.local/bin/hmd — exactly the live bug's PATH ordering). $HOME's
#   own ~/.local/bin is deliberately NOT added to PATH so the shadow wins, mirroring
#   a machine where ~/.superx/bin precedes ~/.local/bin. stdin is /dev/null (curl|bash).
run_install() {
  local home="$1" shadow="$2"; shift 2
  env -u CLAUDE_CONFIG_DIR -u HEIMDALL_HOME -u HEIMDALL_FORCE -u HEIMDALL_FORCE_HMD \
      -u HEIMDALL_CP_URL -u HEIMDALL_ENROLL_TOKEN \
      HOME="$home" TERM="dumb" HEIMDALL_NO_COLOR=1 \
      HEIMDALL_REPO="$REPO" HEIMDALL_REF="$REF" \
      PATH="$shadow:$FAKE_DIR:$SYS" \
      "$@" \
      bash "$INSTALLER" </dev/null 2>&1
}

# real_target PATH — the fully-resolved real file `hmd` points to (symlinks followed).
real_target() { readlink -f "$1" 2>/dev/null || readlink "$1" 2>/dev/null || printf '%s' "$1"; }

echo "heimdall-hmd-shadow harness  installer=$(printf '%s' "$INSTALLER" | sed "s|$REPO/||")  ref=${REF:0:12}"
echo "--------------------------------------------------------------------"

# ══ (A) OURS stale hmd shadows the new install → overwritten in place ═════════
HA="$TMP_ROOT/home-ours"; mkdir -p "$HA"
SUPERX_BIN="$HA/.superx/bin"; mkdir -p "$SUPERX_BIN"
STALE_HMD="$SUPERX_BIN/hmd"
# A legacy superx-era launcher: a regular file carrying the "superx" marker, living
# under a /.superx/ tree — both ownership signals fire. Its body is a unique sentinel
# so we can prove it was actually replaced (not merely still present).
cat > "$STALE_HMD" <<'EOF'
#!/usr/bin/env bash
# superx legacy launcher — STALE-SENTINEL-v2.0.5
echo "stale superx hmd v2.0.5"
EOF
chmod +x "$STALE_HMD"

OUT_A="$TMP_ROOT/ours.out"
run_install "$HA" "$SUPERX_BIN" > "$OUT_A" 2>&1

CANON_A="$HA/.local/bin/hmd"
NEW_LAUNCHER="$HA/.heimdall/bin/heimdall"

# A1: the shadowing binary now resolves to the NEW launcher (overwritten in place).
if [ -L "$STALE_HMD" ] && [ "$(real_target "$STALE_HMD")" = "$(real_target "$NEW_LAUNCHER")" ]; then
  ok "OURS: shadowing ~/.superx/bin/hmd overwritten in place → resolves to the new launcher"
else
  bad "OURS: ~/.superx/bin/hmd still stale — resolves to $(real_target "$STALE_HMD") (want $NEW_LAUNCHER)"
fi
# A2: the stale sentinel is GONE from what `hmd` runs (belt-and-suspenders vs A1).
if grep -q 'STALE-SENTINEL' "$(real_target "$STALE_HMD")" 2>/dev/null; then
  bad "OURS: `hmd` STILL runs the stale superx binary (sentinel present)"
else
  ok "OURS: stale sentinel no longer on the resolved hmd — the old version is superseded"
fi
# A3: canonical ~/.local/bin/hmd was also linked to the new launcher.
if [ -L "$CANON_A" ] && [ "$(real_target "$CANON_A")" = "$(real_target "$NEW_LAUNCHER")" ]; then
  ok "OURS: canonical ~/.local/bin/hmd also linked to the new launcher"
else
  bad "OURS: canonical ~/.local/bin/hmd not linked (got $(real_target "$CANON_A"))"
fi
# A4: the install narrated the replacement.
if grep -qi 'replacing stale heimdall hmd' "$OUT_A"; then
  ok "OURS: install printed 'replacing stale heimdall hmd …'"
else
  bad "OURS: install did NOT narrate the stale-hmd replacement"
fi

# ══ (B) FOREIGN hmd, no force → preserved; canonical hmd NOT installed ════════
HB="$TMP_ROOT/home-foreign"; mkdir -p "$HB"
FOREIGN_BIN="$HB/opt/tools/bin"; mkdir -p "$FOREIGN_BIN"
FOREIGN_HMD="$FOREIGN_BIN/hmd"
# The real collider: PyPI hmd-cli-app. NOT under a heimdall/superx tree and NO
# heimdall/superx marker in its body → classified FOREIGN.
cat > "$FOREIGN_HMD" <<'EOF'
#!/usr/bin/env python3
"""hmd-cli-app — data management command line, unrelated third-party tool."""
print("hmd-cli-app 1.4.2")
EOF
chmod +x "$FOREIGN_HMD"
FOREIGN_SUM_BEFORE="$(python3 -c 'import hashlib,sys;print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$FOREIGN_HMD")"

OUT_B="$TMP_ROOT/foreign.out"
run_install "$HB" "$FOREIGN_BIN" > "$OUT_B" 2>&1

FOREIGN_SUM_AFTER="$(python3 -c 'import hashlib,sys;print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$FOREIGN_HMD")"
# B1: foreign binary preserved byte-for-byte (not a symlink, content identical).
if [ ! -L "$FOREIGN_HMD" ] && [ "$FOREIGN_SUM_BEFORE" = "$FOREIGN_SUM_AFTER" ]; then
  ok "FOREIGN(no force): third-party hmd preserved byte-for-byte"
else
  bad "FOREIGN(no force): third-party hmd was modified/clobbered (symlink=$([ -L "$FOREIGN_HMD" ] && echo yes || echo no))"
fi
# B2: canonical hmd NOT installed (heimdall entry only).
if [ ! -e "$HB/.local/bin/hmd" ]; then
  ok "FOREIGN(no force): canonical ~/.local/bin/hmd NOT created (heimdall entry only)"
else
  bad "FOREIGN(no force): installer created ~/.local/bin/hmd despite a foreign collider"
fi
# B3: guidance + force hint printed.
if grep -qi 'installed .*heimdall.* only' "$OUT_B" && grep -q 'HEIMDALL_FORCE_HMD=1' "$OUT_B"; then
  ok "FOREIGN(no force): printed 'installed heimdall only' + HEIMDALL_FORCE_HMD hint"
else
  bad "FOREIGN(no force): missing the foreign-collider guidance/force hint"
fi

# ══ (C) FOREIGN hmd, HEIMDALL_FORCE_HMD=1 → canonical installed, foreign kept ══
HC="$TMP_ROOT/home-foreign-force"; mkdir -p "$HC"
FBIN_C="$HC/opt/tools/bin"; mkdir -p "$FBIN_C"
FHMD_C="$FBIN_C/hmd"
cat > "$FHMD_C" <<'EOF'
#!/usr/bin/env python3
"""hmd-cli-app — data management command line, unrelated third-party tool."""
print("hmd-cli-app 1.4.2")
EOF
chmod +x "$FHMD_C"
FSUM_C_BEFORE="$(python3 -c 'import hashlib,sys;print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$FHMD_C")"

OUT_C="$TMP_ROOT/foreign-force.out"
run_install "$HC" "$FBIN_C" HEIMDALL_FORCE_HMD=1 > "$OUT_C" 2>&1

CANON_C="$HC/.local/bin/hmd"
NEW_LAUNCHER_C="$HC/.heimdall/bin/heimdall"
FSUM_C_AFTER="$(python3 -c 'import hashlib,sys;print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$FHMD_C")"
# C1: forced → canonical hmd installed, linked to the new launcher.
if [ -L "$CANON_C" ] && [ "$(real_target "$CANON_C")" = "$(real_target "$NEW_LAUNCHER_C")" ]; then
  ok "FOREIGN(force): canonical ~/.local/bin/hmd installed → new launcher"
else
  bad "FOREIGN(force): canonical hmd not installed under force (got $(real_target "$CANON_C"))"
fi
# C2: SAFETY — the foreign binary is STILL preserved (force takes the name, not the file).
if [ ! -L "$FHMD_C" ] && [ "$FSUM_C_BEFORE" = "$FSUM_C_AFTER" ]; then
  ok "FOREIGN(force): third-party hmd STILL preserved byte-for-byte (no data loss)"
else
  bad "FOREIGN(force): third-party hmd was clobbered — force must take the name, not destroy the file"
fi

echo "--------------------------------------------------------------------"
printf '  %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
