#!/usr/bin/env bash
#
# install-crypto-backend.test.sh — acceptance harness for install.sh's Ed25519
# PKI-crypto-backend guarantee (the fix for the multi-hour teammate-presence outage).
#
# THE BUG (root cause of an invisible-teammate outage — akshat + madhavan lost hours):
#   A fresh curl|bash install of v2.0.21 had NO working presence because the python
#   interpreter hmd invokes for heimdall-presence had NEITHER `cryptography` NOR
#   `pynacl`. Chain: heimdall-presence beat → cp_auth.generate_keypair() raised
#   AuthError('crypto_unavailable') → the beat swallowed it → no enroll → no signing
#   seed → unsigned beats dropped → the teammate was INVISIBLE on the wall, SILENTLY.
#
# THE FIX (proven here): install.sh now ENSURES the SAME interpreter heimdall-presence
# uses (PY="$(command -v python3 || command -v python)") can do Ed25519 — or SHOUTS.
# It is idempotent (silent ✓ when the backend already imports), PEP-668-aware
# (pip --user, then --break-system-packages), and NON-FATAL + LOUD on failure (never
# leaves presence silently broken — it prints the exact manual fix command).
#
# THE PROOFS (all hermetic — `claude` + `python3` are controlled PATH fakes; the
# python fake delegates every NON-crypto heredoc to the real interpreter so the rest
# of the install still runs, and reports the crypto import + pip outcome per env):
#   A. BACKEND MISSING, pip CANNOT fix → the install step DETECTS it, ATTEMPTS the
#      pip install, and emits the LOUD warning naming presence + the manual command.
#      (RED on the pre-fix installer: NO crypto step, NO warning, NO pip attempt.)
#   B. BACKEND PRESENT → silent ✓ no-op: NO pip attempt (idempotent), NO warning.
#   C. BACKEND MISSING, pip FIXES it → the step installs cryptography, re-checks, and
#      reports success (✓ installed) with NO warning.
#
# The crucial anti-regression: the "silent broken presence" can no longer happen —
# the install either fixes the backend or shouts.
#
# Usage:  test/install-crypto-backend.test.sh
#   CRYPTO_INSTALLER=/path/to/old/install.sh test/install-crypto-backend.test.sh   # RED run
# Exit 0 = all guarantees hold. Non-zero = a guarantee regressed (prints which).
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SELF_DIR/.." && pwd)"
REF="$(git -C "$REPO" rev-parse HEAD)"
INSTALLER="${CRYPTO_INSTALLER:-$REPO/install.sh}"   # overridable for a RED run

need() { command -v "$1" >/dev/null 2>&1 || { echo "FATAL: $1 not found on host PATH"; exit 2; }; }
need git; need python3; need claude

# The REAL python the fake delegates to — resolved on the HOST before we build the
# controlled PATH, so the fake (first on PATH) never recurses into itself.
REAL_PY="$(command -v python3)"

# ── Hermeticity guard (mirrors install-cp-endpoint.test.sh) ───────────────────
# Run install.sh under a CONTROLLED PATH so `command -v hmd` finds nothing to touch,
# and a tripwire that RESTORES + fails loudly if any tracked bin/ file changed. The
# fake python3 dir goes FIRST so BOTH install.sh's crypto step and (hypothetically)
# heimdall-presence resolve the SAME controlled interpreter — the whole point.
SYS="$(dirname "$(command -v git)"):/usr/bin:/bin"

PASS=0; FAIL=0
ok()  { printf '  \033[32mPASS\033[0m %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAIL=$((FAIL+1)); }

# ── Fake `claude`: satisfy install's preflight + plugin steps with no network ──
FAKE_DIR="$(mktemp -d)"
cat > "$FAKE_DIR/claude" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
  --version) echo "1.5.0 (Claude Code)"; exit 0 ;;
  plugins)   exit 0 ;;
  *)         exit 0 ;;
esac
EOF
chmod +x "$FAKE_DIR/claude"

# ── Fake `python3`: the controlled presence interpreter ───────────────────────
# It emulates the two things the crypto step probes, and delegates EVERYTHING else
# to the real interpreter so the rest of install.sh (statusline / cp-endpoint / team
# / telemetry heredocs + -c calls) still runs for real:
#   - an Ed25519 import CHECK (a heredoc mentioning ed25519/nacl) → importable iff
#     FAKE_CRYPTO_OK=1 OR a prior pip install "succeeded" (marker file);
#   - `-m pip install …` → record the attempt; "succeed" iff FAKE_PIP_OK=1 (and then
#     mark the backend importable), else fail (drives the LOUD-warning path).
# The pip-attempt marker lives under $HMD_CRYPTO_MARKER (per-scenario, exported).
cat > "$FAKE_DIR/python3" <<EOF
#!/usr/bin/env bash
REAL="$REAL_PY"
MARK="\${HMD_CRYPTO_MARKER:-/dev/null}"
if [ "\${1:-}" = "-m" ] && [ "\${2:-}" = "pip" ]; then
  echo "pip \$*" >> "\$MARK"
  if [ "\${FAKE_PIP_OK:-0}" = "1" ]; then : > "\$MARK.installed"; exit 0; fi
  exit 1
fi
if [ "\${1:-}" = "-" ]; then
  src="\$(cat)"
  case "\$src" in
    *ed25519*|*nacl*)
      if [ "\${FAKE_CRYPTO_OK:-0}" = "1" ] || [ -f "\$MARK.installed" ]; then exit 0; fi
      exit 1 ;;
    *) printf '%s' "\$src" | "\$REAL" - ;;
  esac
  exit \$?
fi
exec "\$REAL" "\$@"
EOF
chmod +x "$FAKE_DIR/python3"
# `python` too — heimdall-presence falls back to it, and the crypto step mirrors that.
ln -s "$FAKE_DIR/python3" "$FAKE_DIR/python"

FAKE_PATH="$FAKE_DIR:$SYS"

TMP_ROOT="$(mktemp -d)"
cleanup() {
  sleep 1
  chmod -R u+w "$TMP_ROOT" 2>/dev/null || true
  rm -rf "$FAKE_DIR" "$TMP_ROOT" 2>/dev/null || true
}
trap cleanup EXIT

# ── THE CLOBBER TARGET: a PRIVATE source checkout ─────────────────────────────
# The guarantee under test is "install.sh, pointed at a LOCAL checkout, never writes
# into that checkout's bin/" (install.sh pins it via SOURCE_GUARD_ROOTS, keyed on
# HEIMDALL_REPO). This test used to point the installer at the DEVELOPER'S OWN worktree
# and diff `git status --porcelain -- bin/` before/after. That was unsound twice over:
#   - FALSE REDS: the snapshot spans the whole ~30s run, so ANY concurrent edit to bin/
#     by a teammate or a parallel agent was misattributed to install.sh. Reproduced
#     verbatim as the board's red: "9 passed, 1 failed / install run MUTATED tracked
#     bin/ (non-hermetic):  M bin/heimdall-presence".
#   - DESTRUCTIVE: on mismatch the cleanup trap ran `git checkout -- bin/` against that
#     SHARED tree, discarding a teammate's uncommitted work to "restore" it.
# The installer now gets its own private clone, so the clobber target cannot be touched
# by anyone else. The guarantee is unchanged; the measurement is now deterministic and
# no shared tree is ever written to or reverted.
SRC="$TMP_ROOT/src"
git clone --quiet "$REPO" "$SRC" 2>/dev/null \
  || { echo "FATAL: could not create the private source clone of $REPO"; exit 2; }

# Content manifest of bin/: sha256 of every file plus the set of executables. STRICTLY
# STRONGER than the old `git status --porcelain -- bin/`, which reports only files git
# tracks — a write to a gitignored or untracked path under bin/ was invisible to it and
# is caught here.
bin_manifest() {
  find "$1/bin" -type f -print0 2>/dev/null | LC_ALL=C sort -z \
    | xargs -0 shasum -a 256 2>/dev/null
  find "$1/bin" -type f -perm -u+x -print 2>/dev/null | LC_ALL=C sort
}
BIN_GUARD_BEFORE="$(bin_manifest "$SRC")"
# Anti-vacuous: an empty manifest would make the clobber assertion pass trivially.
[ -n "$BIN_GUARD_BEFORE" ] \
  || { echo "FATAL: private clone has no bin/ files — the clobber guard would be vacuous"; exit 2; }

# Run the installer under test in a fresh HOME with the controlled PATH. Extra env
# ($4…) tunes the fake python3 (FAKE_CRYPTO_OK / FAKE_PIP_OK). stdin /dev/null so the
# TTY-gated CP prompt is never taken (mirrors curl|bash / CI).
run_install() { # $1=HOME  $2=MARKER  rest=extra env assignments (KEY=VAL)
  local home="$1" marker="$2"; shift 2
  env -i HOME="$home" TERM="dumb" PATH="$FAKE_PATH" \
    HEIMDALL_NO_COLOR=1 HEIMDALL_REPO="$SRC" HEIMDALL_REF="$REF" \
    HMD_CRYPTO_MARKER="$marker" "$@" \
    bash "$INSTALLER" </dev/null 2>&1
}

echo "install-crypto-backend harness  repo=$REPO  ref=${REF:0:12}"
echo "  installer=$INSTALLER"
echo "--------------------------------------------------------------------"

# ── (A) BACKEND MISSING + pip CANNOT fix → detect, attempt, LOUD warning ───────
HA="$TMP_ROOT/home-missing"; mkdir -p "$HA"
MARK_A="$TMP_ROOT/mark-a"
OUT_A="$(run_install "$HA" "$MARK_A" FAKE_CRYPTO_OK=0 FAKE_PIP_OK=0)"
# The step must have ATTEMPTED a pip install into the presence interpreter…
if [ -s "$MARK_A" ] && grep -q 'pip .*install' "$MARK_A"; then
  ok "backend-missing: install ATTEMPTED to install cryptography into the presence interpreter"
else
  bad "backend-missing: install made NO attempt to install the crypto backend (pip never invoked)"
fi
# …and, unable to, emitted the LOUD warning that would have saved hours: it must name
# PRESENCE as broken AND print the manual pip fix command (never a silent pass).
if grep -qiE 'presence' <<<"$OUT_A" \
   && grep -qiE 'pip install .*cryptography' <<<"$OUT_A"; then
  ok "backend-missing: LOUD warning names presence + prints the manual pip fix command"
else
  bad "backend-missing: NO loud warning about broken presence — the SILENT failure can still ship (out: $(grep -iE 'presence|crypto|pki|ed25519' <<<"$OUT_A" | tr '\n' ' ' | cut -c1-200))"
fi
# The install must still COMPLETE (non-fatal) — the success card renders.
if grep -qiE 'Heimdall v[0-9].* installed' <<<"$OUT_A"; then
  ok "backend-missing: crypto failure is NON-FATAL — the install still completes"
else
  bad "backend-missing: crypto failure ABORTED the install (must be non-fatal)"
fi

# ── (B) BACKEND PRESENT → silent ✓ no-op (idempotent), NO pip attempt ──────────
HB="$TMP_ROOT/home-present"; mkdir -p "$HB"
MARK_B="$TMP_ROOT/mark-b"
OUT_B="$(run_install "$HB" "$MARK_B" FAKE_CRYPTO_OK=1)"
if [ ! -s "$MARK_B" ]; then
  ok "backend-present: idempotent — the step made NO pip install attempt"
else
  bad "backend-present: the step ran pip even though the backend already imports ($(cat "$MARK_B" | tr '\n' ' '))"
fi
if grep -qiE 'PKI crypto backend|Ed25519' <<<"$OUT_B"; then
  ok "backend-present: the step reports the PKI backend status (the ✓ signal that would have flagged the outage)"
else
  bad "backend-present: no PKI-backend status line in the install output"
fi
# A healthy backend must NOT print the broken-presence warning.
if grep -qiE 'presence will be silently broken|presence will not work|crypto backend MISSING' <<<"$OUT_B"; then
  bad "backend-present: install printed a broken-presence warning despite a working backend"
else
  ok "backend-present: no false broken-presence warning"
fi

# ── (C) BACKEND MISSING + pip FIXES it → install cryptography, re-check, succeed ─
HC="$TMP_ROOT/home-fix"; mkdir -p "$HC"
MARK_C="$TMP_ROOT/mark-c"
OUT_C="$(run_install "$HC" "$MARK_C" FAKE_CRYPTO_OK=0 FAKE_PIP_OK=1)"
if [ -s "$MARK_C" ] && grep -q 'pip .*install' "$MARK_C"; then
  ok "backend-fixable: install attempted the pip install"
else
  bad "backend-fixable: install made no pip attempt"
fi
# After a successful install the re-check passes → NO broken-presence warning.
if grep -qiE 'presence will be silently broken|crypto backend MISSING|presence will not work' <<<"$OUT_C"; then
  bad "backend-fixable: install still warned of broken presence after a SUCCESSFUL backend install (re-check missing?)"
else
  ok "backend-fixable: after installing the backend the re-check passes — no broken-presence warning"
fi
if grep -qiE 'Heimdall v[0-9].* installed' <<<"$OUT_C"; then
  ok "backend-fixable: install completes and reports success"
else
  bad "backend-fixable: install did not complete"
fi

# ── (D) HERMETIC — the 3 install runs left the source checkout's bin/ pristine ─
# Byte-for-byte over EVERY file under bin/ (not just the git-tracked ones), against a
# private clone no other process can touch — so a mismatch here can only have been
# caused by install.sh itself.
BIN_GUARD_AFTER="$(bin_manifest "$SRC")"
if [ "$BIN_GUARD_AFTER" = "$BIN_GUARD_BEFORE" ]; then
  ok "hermetic: install runs never mutated the source checkout's bin/ (no clobber)"
else
  bad "install run MUTATED the source checkout's bin/ (non-hermetic): $(
    diff <(printf '%s\n' "$BIN_GUARD_BEFORE") <(printf '%s\n' "$BIN_GUARD_AFTER") \
      | grep -E '^[<>]' | head -4 | tr '\n' ' ')"
fi

echo "--------------------------------------------------------------------"
echo "  $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
