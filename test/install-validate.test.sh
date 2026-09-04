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
# controlled PATH against a PRIVATE CLONE of the repo, and the clobber assertion is a
# sha256 content manifest of that clone's bin/ (mirrors install-crypto-backend.test.sh).
# Nothing in the developer's own tree is ever written to or reverted.
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

# Cleanup touches ONLY this suite's own temp dirs. It deliberately does NOT revert
# anything in the developer's tree — see the $SRC note below for why that reverting
# tripwire was removed.
cleanup() {
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
#     by a teammate or a parallel agent was misattributed to install.sh (run-all.sh runs
#     suites in PARALLEL, so this was not hypothetical).
#   - DESTRUCTIVE: on mismatch the cleanup trap ran `git checkout -- bin/` against that
#     SHARED tree, discarding a teammate's uncommitted work to "restore" it. Measured:
#     a landed bin/heimdall-modules change was silently reverted mid-session.
# The installer now gets its own private clone, so the clobber target cannot be touched
# by anyone else. The guarantee is unchanged; the measurement is now deterministic and
# no shared tree is ever written to or reverted.
#
# The DOCTOR still runs against $REPO — that is a READ-ONLY view: heimdall-doctor-install
# validates and never writes into --plugin-dir, and it pins HEIMDALL_TEAM_DIR to $HOME
# so its synthetic beat cannot mint a team.json into the checkout
# (bin/heimdall-doctor-install:197-207). Only install.sh, which CAN write, is redirected.
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
if [ "$RC" -eq 0 ] && grep -qi 'all systems go' <<<"$OUT"; then
  ok "GREEN: healthy install validates clean (exit 0, 'all systems go')"
else
  bad "GREEN: healthy install did not validate (rc=$RC): $(grep -iE '✗|NOT READY' <<<"$OUT" | tr '\n' ' ' | cut -c1-160)"
fi

# ══ B. RED crypto — Ed25519 missing → ✗ crypto + pip fix, exit 1 ══════════════
HB="$TMP_ROOT/B"; seed_home "$HB" y enabled
OUT="$(run_doctor "$HB" FAKE_CRYPTO_OK=0 --)"; RC=$?
if [ "$RC" -ne 0 ] \
   && grep -qiE '✗ *crypto|crypto .*NOT importable' <<<"$OUT" \
   && grep -qi 'pip install .*cryptography' <<<"$OUT"; then
  ok "RED crypto: detected, exits nonzero, prints the actionable pip fix"
else
  bad "RED crypto: not detected/gated (rc=$RC): $(grep -iE 'crypto' <<<"$OUT" | tr '\n' ' ' | cut -c1-160)"
fi

# ══ C. RED statusline — HUD unregistered → ✗ statusline + register fix, exit 1 ═
HC="$TMP_ROOT/C"; seed_home "$HC" n enabled
OUT="$(run_doctor "$HC" FAKE_CRYPTO_OK=1 --)"; RC=$?
if [ "$RC" -ne 0 ] \
   && grep -qiE 'statusline' <<<"$OUT" \
   && grep -qi 'heimdall-statusline-register' <<<"$OUT"; then
  ok "RED statusline: detected, exits nonzero, prints the register fix"
else
  bad "RED statusline: not detected/gated (rc=$RC): $(grep -iE 'statusline' <<<"$OUT" | tr '\n' ' ' | cut -c1-160)"
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
if grep -qiE 'first-run hit the .*bound|killed' <<<"$OUT"; then
  ok "BOUNDED: timeout is reported as a non-fatal ⚠ (bounded, not a hard fail)"
else
  bad "BOUNDED: no bounded-timeout report: $(grep -iE 'runtime' <<<"$OUT" | tr '\n' ' ' | cut -c1-160)"
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
if [ "$RC" -ne 0 ] && grep -qiE 'runtime.*exited|could not start cleanly' <<<"$OUT"; then
  ok "GATES-READY: a failing headless first-cc → ✗ runtime → exit 1 (result gates ready)"
else
  bad "GATES-READY: a failing first-cc did not gate (rc=$RC): $(grep -iE 'runtime' <<<"$OUT" | tr '\n' ' ' | cut -c1-160)"
fi

# ── install.sh ready-gate (runs the REAL installer against the PRIVATE clone) ───
run_install() { # $1=HOME  $2=MARKER  rest=extra env
  local home="$1" marker="$2"; shift 2
  env -i HOME="$home" TERM="dumb" PATH="$FAKE_PATH" \
    HEIMDALL_NO_COLOR=1 HEIMDALL_REPO="$SRC" HEIMDALL_REF="$REF" \
    CLAUDE_CONFIG_DIR="$home/.claude" HMD_DOCTOR_CLAUDE="$FAKE_DIR/claude" \
    HMD_CRYPTO_MARKER="$marker" HMD_DOCTOR_CC_TIMEOUT=10 "$@" \
    bash "$INSTALLER" </dev/null 2>&1
}

# ══ G. GREEN install — validation passes → ready go-ahead shown ═══════════════
HG="$TMP_ROOT/G"; mkdir -p "$HG/.heimdall"; : > "$HG/.heimdall/presence-off"
OUTG="$(run_install "$HG" "$TMP_ROOT/mark-g" FAKE_CRYPTO_OK=1)"
if grep -qiE 'Heimdall v[0-9].* installed' <<<"$OUTG"; then
  ok "GREEN install: the success card renders"
else
  bad "GREEN install: no success card"
fi
if grep -qi 'all systems go' <<<"$OUTG" \
   && grep -qiE 'Run:.*demo' <<<"$OUTG"; then
  ok "GREEN install: validation passed → the 'Run: … demo' go-ahead is shown"
else
  bad "GREEN install: ready go-ahead withheld on a healthy install: $(grep -iE 'systems go|NOT READY|Run:' <<<"$OUTG" | tr '\n' ' ' | cut -c1-160)"
fi

# ══ H. RED install — broken crypto → NOT READY, NO go-ahead, still non-fatal ═══
HH="$TMP_ROOT/H"; mkdir -p "$HH/.heimdall"; : > "$HH/.heimdall/presence-off"
OUTH="$(run_install "$HH" "$TMP_ROOT/mark-h" FAKE_CRYPTO_OK=0 FAKE_PIP_OK=0)"
# The install still COMPLETES (non-fatal) — the success card renders.
if grep -qiE 'Heimdall v[0-9].* installed' <<<"$OUTH"; then
  ok "RED install: a broken part is NON-FATAL — the success card still renders"
else
  bad "RED install: the broken part aborted the install (must be non-fatal)"
fi
# …but the installer does NOT declare ready: NO 'Run: … demo' go-ahead.
if grep -qiE 'NOT READY' <<<"$OUTH" \
   && ! grep -qiE 'Run:.*demo' <<<"$OUTH"; then
  ok "RED install: installer WITHHELD ready — 'NOT READY' shown, no 'Run: … demo' go-ahead"
else
  bad "RED install: still declared ready despite a broken part: $(grep -iE 'NOT READY|Run:.*demo' <<<"$OUTH" | tr '\n' ' ' | cut -c1-160)"
fi

# ══ HERMETIC — the install runs left the source checkout's bin/ pristine ══════
# Byte-for-byte over EVERY file under bin/ (not just the git-tracked ones), against a
# private clone no other process can touch — so a mismatch here can only have been
# caused by install.sh itself.
BIN_GUARD_AFTER="$(bin_manifest "$SRC")"
if [ "$BIN_GUARD_AFTER" = "$BIN_GUARD_BEFORE" ]; then
  ok "hermetic: runs never mutated the source checkout's bin/ (no clobber)"
else
  bad "runs MUTATED the source checkout's bin/ (non-hermetic): $(
    diff <(printf '%s\n' "$BIN_GUARD_BEFORE") <(printf '%s\n' "$BIN_GUARD_AFTER") \
      | grep -E '^[<>]' | head -4 | tr '\n' ' ')"
fi

echo "--------------------------------------------------------------------"
echo "  $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
