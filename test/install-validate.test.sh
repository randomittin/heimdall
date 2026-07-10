#!/usr/bin/env bash
#
# install-validate.test.sh — acceptance harness for the POST-INSTALL VALIDATION GATE
# (bin/heimdall-doctor-install) and install.sh's ready-gate + headless first-run verify.
#
# WHAT IT PROVES (RJ's directive: a fresh install must never leave the dev in a
# silently-broken state, and CC must not run interactively before validation passes):
#
#   HARNESS (bin/heimdall-doctor-install) — RED without a fix, GREEN with one:
#     A. GREEN            — every part healthy → "all systems go", exit 0.
#     B. RED crypto       — Ed25519 backend missing → ✗ crypto + the pip fix, exit 1.
#     C. RED statusline   — HUD unregistered → ✗ statusline + the register fix, exit 1.
#     D. RED claude-mem   — plugin misconfigured → ✗ claude-mem + the register fix, exit 1.
#
#   FIRST-RUN = HEADLESS, BACKGROUND, BOUNDED (--cc-verify):
#     E. BOUNDED          — a hung first-cc (sleeps forever) is KILLED at the deadline;
#                           the harness does NOT hang, and the run was HEADLESS (no TTY).
#     F. GATES-READY      — a first-cc that EXITS NONZERO → ✗ runtime → exit 1 (its
#                           result gates the ready message).
#
#   INSTALL.SH READY-GATE:
#     G. GREEN install    — validation passes → "all systems go" + the `demo` go-ahead.
#     H. RED install      — a broken part → the installer DOES NOT declare ready
#                           (no `Run: … demo` go-ahead), prints NOT READY, and the
#                           install is still NON-FATAL (the success card renders).
#
# HERMETIC: `claude` + `python3` are controlled PATH fakes; install.sh runs under a
# controlled PATH with a tripwire that RESTORES + fails loudly if any tracked bin/
# file changed (mirrors install-crypto-backend.test.sh). git checkout -- bin/ on exit.
#
# Usage:  test/install-validate.test.sh
# Exit 0 = all guarantees hold. Non-zero = a guarantee regressed (prints which).
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SELF_DIR/.." && pwd)"
REF="$(git -C "$REPO" rev-parse HEAD)"
DOCTOR="$REPO/bin/heimdall-doctor-install"
INSTALLER="$REPO/install.sh"

need() { command -v "$1" >/dev/null 2>&1 || { echo "FATAL: $1 not found on host PATH"; exit 2; }; }
need git; need python3; need jq
REAL_PY="$(command -v python3)"

SYS="$(dirname "$(command -v git)"):/usr/bin:/bin"
BIN_GUARD_BEFORE="$(git -C "$REPO" status --porcelain -- bin/ 2>/dev/null)"

PASS=0; FAIL=0
ok()  { printf '  \033[32mPASS\033[0m %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAIL=$((FAIL+1)); }

# ── Fakes ─────────────────────────────────────────────────────────────────────
FAKE_DIR="$(mktemp -d)"
TMP_ROOT="$(mktemp -d)"

# Fake `claude`: preflight + plugins no-op; `-p` honours FAKE_CC_MODE (ok|slow|fail)
# and records whether it was invoked HEADLESS (no controlling TTY on stdin).
cat > "$FAKE_DIR/claude" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
  --version) echo "1.5.0 (Claude Code)"; exit 0 ;;
  plugins)   exit 0 ;;
  -p)
    # Record headless-ness for the test's assertion.
    if [ -n "${CC_MARK:-}" ]; then
      if [ -t 0 ]; then echo "TTY" >> "$CC_MARK"; else echo "NOTTY -p" >> "$CC_MARK"; fi
    fi
    case "${FAKE_CC_MODE:-ok}" in
      slow) sleep 120 ;;                 # hangs → the harness must kill it at the bound
      fail) exit 7 ;;                    # a real startup error → runtime ✗ (gates ready)
      *)    echo "OK"; exit 0 ;;
    esac
    ;;
  *) exit 0 ;;
esac
EOF
chmod +x "$FAKE_DIR/claude"

# Fake `python3`: emulates the Ed25519 import probe (importable iff FAKE_CRYPTO_OK=1
# or a prior pip install "succeeded"), records pip attempts, and delegates every
# other invocation to the real interpreter so the rest runs for real.
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
ln -s "$FAKE_DIR/python3" "$FAKE_DIR/python"
FAKE_PATH="$FAKE_DIR:$SYS"

cleanup() {
  local after; after="$(git -C "$REPO" status --porcelain -- bin/ 2>/dev/null)"
  if [ "$after" != "$BIN_GUARD_BEFORE" ]; then
    printf '\n\033[31mFATAL\033[0m test mutated tracked bin/ — restoring:\n%s\n' "$after" >&2
    git -C "$REPO" checkout -- bin/ 2>/dev/null || true
  fi
  chmod -R u+w "$TMP_ROOT" 2>/dev/null || true
  rm -rf "$FAKE_DIR" "$TMP_ROOT" 2>/dev/null || true
}
trap cleanup EXIT

# Seed a fresh HOME with a Claude settings.json. Flags: $2 statusline(y/n), $3
# claude-mem(enabled|misconfigured|absent). Presence is forced OFF (offline) so the
# beat/roster roundtrip is a fast, network-free WARN (non-gating), keeping the run
# hermetic + quick.
seed_home() { # $1=HOME  $2=sl(y|n)  $3=cm(enabled|misconfigured|absent)
  local home="$1" sl="$2" cm="$3"
  mkdir -p "$home/.claude" "$home/.heimdall"
  : > "$home/.heimdall/presence-off"   # global presence kill switch → offline beat
  local sljson="" cmjson=""
  if [ "$sl" = "y" ]; then
    sljson="\"statusLine\":{\"type\":\"command\",\"command\":\"bash -c '[ -x \\\"$REPO/hooks/statusline.sh\\\" ] && exec bash \\\"$REPO/hooks/statusline.sh\\\"; exit 0'\"},"
  fi
  case "$cm" in
    enabled)       cmjson="\"enabledPlugins\":{\"claude-mem@thedotmack\":true}" ;;
    misconfigured) cmjson="\"extraKnownMarketplaces\":{\"thedotmack\":{\"source\":{\"source\":\"github\",\"repo\":\"thedotmack/claude-mem\"}}},\"enabledPlugins\":{}" ;;
    absent)        cmjson="\"enabledPlugins\":{}" ;;
  esac
  printf '{%s%s}\n' "$sljson" "$cmjson" > "$home/.claude/settings.json"
}

# Run the doctor directly against the REPO tree in a controlled HOME/PATH.
run_doctor() { # $1=HOME  rest=extra env + doctor args after `--`
  local home="$1"; shift
  local envs=() args=()
  while [ $# -gt 0 ] && [ "$1" != "--" ]; do envs+=("$1"); shift; done
  [ "${1:-}" = "--" ] && shift
  args=("$@")
  # ${arr[@]+…} guards an EMPTY array under `set -u` on macOS bash 3.2.
  env -i HOME="$home" TERM="dumb" PATH="$FAKE_PATH" HEIMDALL_NO_COLOR=1 \
    CLAUDE_CONFIG_DIR="$home/.claude" HMD_DOCTOR_CLAUDE="$FAKE_DIR/claude" \
    ${envs[@]+"${envs[@]}"} \
    bash "$DOCTOR" --plugin-dir "$REPO" ${args[@]+"${args[@]}"} </dev/null 2>&1
}

echo "install-validate harness  repo=$REPO  ref=${REF:0:12}"
echo "  doctor=$DOCTOR"
echo "--------------------------------------------------------------------"

# ══ A. GREEN — everything healthy → all systems go, exit 0 ════════════════════
HA="$TMP_ROOT/A"; seed_home "$HA" y enabled
OUT="$(run_doctor "$HA" FAKE_CRYPTO_OK=1 --)"; RC=$?
if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -qi 'all systems go'; then
  ok "GREEN: healthy install validates clean (exit 0, 'all systems go')"
else
  bad "GREEN: healthy install did not validate (rc=$RC): $(printf '%s' "$OUT" | grep -iE '✗|NOT READY' | tr '\n' ' ' | cut -c1-160)"
fi

# ══ B. RED crypto — Ed25519 missing → ✗ crypto + pip fix, exit 1 ══════════════
HB="$TMP_ROOT/B"; seed_home "$HB" y enabled
OUT="$(run_doctor "$HB" FAKE_CRYPTO_OK=0 --)"; RC=$?
if [ "$RC" -ne 0 ] \
   && printf '%s' "$OUT" | grep -qiE '✗ *crypto|crypto .*NOT importable' \
   && printf '%s' "$OUT" | grep -qi 'pip install .*cryptography'; then
  ok "RED crypto: detected, exits nonzero, prints the actionable pip fix"
else
  bad "RED crypto: not detected/gated (rc=$RC): $(printf '%s' "$OUT" | grep -iE 'crypto' | tr '\n' ' ' | cut -c1-160)"
fi

# ══ C. RED statusline — HUD unregistered → ✗ statusline + register fix, exit 1 ═
HC="$TMP_ROOT/C"; seed_home "$HC" n enabled
OUT="$(run_doctor "$HC" FAKE_CRYPTO_OK=1 --)"; RC=$?
if [ "$RC" -ne 0 ] \
   && printf '%s' "$OUT" | grep -qiE 'statusline' \
   && printf '%s' "$OUT" | grep -qi 'heimdall-statusline-register'; then
  ok "RED statusline: detected, exits nonzero, prints the register fix"
else
  bad "RED statusline: not detected/gated (rc=$RC): $(printf '%s' "$OUT" | grep -iE 'statusline' | tr '\n' ' ' | cut -c1-160)"
fi

# ══ D. RED claude-mem — misconfigured (mkt known, plugin not enabled) → ✗ ═════
HD="$TMP_ROOT/D"; seed_home "$HD" y misconfigured
OUT="$(run_doctor "$HD" FAKE_CRYPTO_OK=1 --)"; RC=$?
if [ "$RC" -ne 0 ] \
   && printf '%s' "$OUT" | grep -qiE 'claude-mem .*MISCONFIGURED' \
   && printf '%s' "$OUT" | grep -qi 'claude plugins install claude-mem@thedotmack'; then
  ok "RED claude-mem: misconfig detected, exits nonzero, prints the register+install fix"
else
  bad "RED claude-mem: not detected/gated (rc=$RC): $(printf '%s' "$OUT" | grep -iE 'claude-mem' | tr '\n' ' ' | cut -c1-160)"
fi

# ══ E. BOUNDED + HEADLESS — a hung first-cc is killed at the deadline ══════════
HE="$TMP_ROOT/E"; seed_home "$HE" y enabled
CC_MARK_E="$TMP_ROOT/cc-e.mark"
t0=$(date +%s)
OUT="$(run_doctor "$HE" FAKE_CRYPTO_OK=1 FAKE_CC_MODE=slow CC_MARK="$CC_MARK_E" \
        HMD_DOCTOR_CC_TIMEOUT=3 -- --cc-verify)"; RC=$?
t1=$(date +%s); ELAPSED=$(( t1 - t0 ))
# It must NOT hang (killed near the 3s bound — allow generous slack for the other
# bounded checks, but far below the fake's 120s sleep).
if [ "$ELAPSED" -lt 60 ]; then
  ok "BOUNDED: hung first-cc killed at the deadline — harness did not hang (${ELAPSED}s < 120s sleep)"
else
  bad "BOUNDED: harness hung ${ELAPSED}s (the bound did not fire)"
fi
# The kill is NON-fatal (runtime ⚠, not ✗) so a slow-but-healthy install still passes.
if printf '%s' "$OUT" | grep -qiE 'first-run hit the .*bound|killed'; then
  ok "BOUNDED: timeout is reported as a non-fatal ⚠ (bounded, not a hard fail)"
else
  bad "BOUNDED: no bounded-timeout report: $(printf '%s' "$OUT" | grep -iE 'runtime' | tr '\n' ' ' | cut -c1-160)"
fi
# The first run was HEADLESS: invoked with -p and NO controlling TTY on stdin.
if [ -f "$CC_MARK_E" ] && grep -q 'NOTTY -p' "$CC_MARK_E"; then
  ok "HEADLESS: the first cc run was invoked with -p and no TTY (never interactive)"
else
  bad "HEADLESS: could not confirm the first cc run was headless ($(cat "$CC_MARK_E" 2>/dev/null | tr '\n' ' '))"
fi

# ══ F. GATES-READY — a first-cc that exits nonzero → ✗ runtime → exit 1 ═══════
HF="$TMP_ROOT/F"; seed_home "$HF" y enabled
OUT="$(run_doctor "$HF" FAKE_CRYPTO_OK=1 FAKE_CC_MODE=fail HMD_DOCTOR_CC_TIMEOUT=10 -- --cc-verify)"; RC=$?
if [ "$RC" -ne 0 ] && printf '%s' "$OUT" | grep -qiE 'runtime.*exited|could not start cleanly'; then
  ok "GATES-READY: a failing headless first-cc → ✗ runtime → exit 1 (result gates ready)"
else
  bad "GATES-READY: a failing first-cc did not gate (rc=$RC): $(printf '%s' "$OUT" | grep -iE 'runtime' | tr '\n' ' ' | cut -c1-160)"
fi

# ── install.sh ready-gate (runs the REAL installer from a clone of REF) ─────────
run_install() { # $1=HOME  $2=MARKER  rest=extra env
  local home="$1" marker="$2"; shift 2
  env -i HOME="$home" TERM="dumb" PATH="$FAKE_PATH" \
    HEIMDALL_NO_COLOR=1 HEIMDALL_REPO="$REPO" HEIMDALL_REF="$REF" \
    CLAUDE_CONFIG_DIR="$home/.claude" HMD_DOCTOR_CLAUDE="$FAKE_DIR/claude" \
    HMD_CRYPTO_MARKER="$marker" HMD_DOCTOR_CC_TIMEOUT=10 "$@" \
    bash "$INSTALLER" </dev/null 2>&1
}

# ══ G. GREEN install — validation passes → ready go-ahead shown ═══════════════
HG="$TMP_ROOT/G"; mkdir -p "$HG/.heimdall"; : > "$HG/.heimdall/presence-off"
OUTG="$(run_install "$HG" "$TMP_ROOT/mark-g" FAKE_CRYPTO_OK=1)"
if printf '%s' "$OUTG" | grep -qiE 'Heimdall v[0-9].* installed'; then
  ok "GREEN install: the success card renders"
else
  bad "GREEN install: no success card"
fi
if printf '%s' "$OUTG" | grep -qi 'all systems go' \
   && printf '%s' "$OUTG" | grep -qiE 'Run:.*demo'; then
  ok "GREEN install: validation passed → the 'Run: … demo' go-ahead is shown"
else
  bad "GREEN install: ready go-ahead withheld on a healthy install: $(printf '%s' "$OUTG" | grep -iE 'systems go|NOT READY|Run:' | tr '\n' ' ' | cut -c1-160)"
fi

# ══ H. RED install — broken crypto → NOT READY, NO go-ahead, still non-fatal ═══
HH="$TMP_ROOT/H"; mkdir -p "$HH/.heimdall"; : > "$HH/.heimdall/presence-off"
OUTH="$(run_install "$HH" "$TMP_ROOT/mark-h" FAKE_CRYPTO_OK=0 FAKE_PIP_OK=0)"
# The install still COMPLETES (non-fatal) — the success card renders.
if printf '%s' "$OUTH" | grep -qiE 'Heimdall v[0-9].* installed'; then
  ok "RED install: a broken part is NON-FATAL — the success card still renders"
else
  bad "RED install: the broken part aborted the install (must be non-fatal)"
fi
# …but the installer does NOT declare ready: NO 'Run: … demo' go-ahead.
if printf '%s' "$OUTH" | grep -qiE 'NOT READY' \
   && ! printf '%s' "$OUTH" | grep -qiE 'Run:.*demo'; then
  ok "RED install: installer WITHHELD ready — 'NOT READY' shown, no 'Run: … demo' go-ahead"
else
  bad "RED install: still declared ready despite a broken part: $(printf '%s' "$OUTH" | grep -iE 'NOT READY|Run:.*demo' | tr '\n' ' ' | cut -c1-160)"
fi

# ══ HERMETIC — the install/doctor runs left tracked bin/ pristine ═════════════
BIN_GUARD_AFTER="$(git -C "$REPO" status --porcelain -- bin/ 2>/dev/null)"
if [ "$BIN_GUARD_AFTER" = "$BIN_GUARD_BEFORE" ]; then
  ok "hermetic: runs never mutated the repo's tracked bin/ (no clobber)"
else
  bad "runs MUTATED tracked bin/ (non-hermetic): $BIN_GUARD_AFTER"
fi

echo "--------------------------------------------------------------------"
echo "  $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
