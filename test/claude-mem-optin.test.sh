#!/usr/bin/env bash
#
# claude-mem-optin.test.sh — proves claude-mem is NOT installed by default.
#
# CONTEXT: install.sh used to run `claude plugins marketplace add thedotmack/claude-mem
# && claude plugins install claude-mem@thedotmack` unconditionally on every install.
# Measured: zero invocations across ~40 spawns, its "98% savings" figure is a
# compression ratio, not session savings (falsified — see
# docs/analysis/2026-08-22-reasoning-bank-wiring-decision.md), and its Chroma index
# bloated to 30GB and blocked a build. That is ongoing harm, not one-time setup pain,
# so `ensure_claude_mem` (install.sh) now DECLINES by default and only touches the
# `claude` CLI when a user opts in with HEIMDALL_INSTALL_CLAUDE_MEM=1. The plugin stays
# a one-command manual install either way (the printed fix).
#
# WHAT IT PROVES (RED without the gate, GREEN with it):
#   A. DEFAULT, not present     -> state=declined, ZERO marketplace/install CLI calls,
#                                   the printed step names the opt-in var.
#   B. OPTED IN, not present    -> state=configured, the marketplace+install calls DO
#                                   fire (the opt-in path still works — reversible).
#   C. DEFAULT, already present -> state=present (idempotent: the presence check still
#                                   runs BEFORE the opt-in gate; a prior manual install
#                                   is never touched, let alone reinstalled).
#
# HERMETIC: `claude` + `python3` are controlled PATH fakes; install.sh runs against a
# PRIVATE CLONE of this repo (mirrors test/install-validate.test.sh's run_install() /
# private-clone pattern, lines ~135-137 and ~270-277). No network, no mutation of the
# developer's own tree.
#
# Usage:  test/claude-mem-optin.test.sh
# Exit 0 = all guarantees hold. Non-zero = a guarantee regressed (prints which).
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SELF_DIR/.." && pwd)"
REF="$(git -C "$REPO" rev-parse HEAD)"
INSTALLER="$REPO/install.sh"

need() { command -v "$1" >/dev/null 2>&1 || { echo "FATAL: $1 not found on host PATH"; exit 2; }; }
need git; need python3
REAL_PY="$(command -v python3)"

SYS="$(dirname "$(command -v git)"):/usr/bin:/bin"

PASS=0; FAIL=0
ok()  { printf '  \033[32mPASS\033[0m %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAIL=$((FAIL+1)); }

FAKE_DIR="$(mktemp -d)"
TMP_ROOT="$(mktemp -d)"

# Fake `claude`: logs every invocation (CLAUDE_CALL_LOG) and tracks plugin state via
# marker files, so a test can assert exactly which subcommands fired. Extends the
# no-op `plugins) exit 0` fake in test/install-validate.test.sh:58-77 with real
# plugins-subcommand fidelity, since THIS suite's assertion is about which plugins
# calls happen — a blanket no-op would hide the very thing under test. The
# marketplace-add/install branches discriminate by the ACTUAL plugin/marketplace
# argument (claude-mem/thedotmack only): install.sh separately registers ITSELF
# (`claude plugins install hmd@heimdall`) on every single run regardless of this
# gate, and a fake that marks the claude-mem marker on ANY install call would
# misreport that unrelated, always-happens self-install as claude-mem being
# installed — which is exactly the false RED this suite hit before the fix.
# `-f /dev/null` is always false (a char device, never a regular file), so every
# marker var defaults safely to "absent" when a test doesn't care about it.
cat > "$FAKE_DIR/claude" <<'EOF'
#!/usr/bin/env bash
LOG="${CLAUDE_CALL_LOG:-/dev/null}"
printf '%s\n' "$*" >> "$LOG"
case "${1:-}" in
  --version) echo "1.5.0 (Claude Code)"; exit 0 ;;
  plugins)
    case "${2:-}" in
      list)
        if [ -f "${CM_PRESENT_MARK:-/dev/null}" ] || [ -f "${CM_INSTALLED_MARK:-/dev/null}" ]; then
          echo "claude-mem@thedotmack  enabled"
        fi
        exit 0 ;;
      marketplace)
        case "${3:-}" in
          add)
            case "${4:-}" in
              *claude-mem*|*thedotmack*) : > "${CM_MKT_MARK:-/dev/null}" ;;
            esac
            exit 0 ;;
          *) exit 0 ;;
        esac ;;
      install)
        case "${3:-}" in
          *claude-mem*) : > "${CM_INSTALLED_MARK:-/dev/null}" ;;
        esac
        exit 0 ;;
      *) exit 0 ;;
    esac ;;
  *) exit 0 ;;
esac
EOF
chmod +x "$FAKE_DIR/claude"

# Fake `python3`: this suite exercises the claude-mem step, not the crypto probe, so
# just delegate to the real interpreter — the real Ed25519 backend answers for itself.
cat > "$FAKE_DIR/python3" <<EOF
#!/usr/bin/env bash
exec "$REAL_PY" "\$@"
EOF
chmod +x "$FAKE_DIR/python3"
ln -s "$FAKE_DIR/python3" "$FAKE_DIR/python"
FAKE_PATH="$FAKE_DIR:$SYS"

cleanup() {
  chmod -R u+w "$TMP_ROOT" 2>/dev/null || true
  rm -rf "$FAKE_DIR" "$TMP_ROOT" 2>/dev/null || true
}
trap cleanup EXIT

# Private clone — install.sh never touches the developer's own tree (mirrors
# test/install-validate.test.sh:135-137).
SRC="$TMP_ROOT/src"
git clone --quiet "$REPO" "$SRC" 2>/dev/null \
  || { echo "FATAL: could not create the private source clone of $REPO"; exit 2; }

run_install() { # $1=HOME  rest=extra env (VAR=val ...)
  local home="$1"; shift
  mkdir -p "$home/.heimdall" "$home/.claude"
  : > "$home/.heimdall/presence-off"   # global presence kill switch → offline beat
  env -i HOME="$home" TERM="dumb" PATH="$FAKE_PATH" \
    HEIMDALL_NO_COLOR=1 HEIMDALL_REPO="$SRC" HEIMDALL_REF="$REF" \
    CLAUDE_CONFIG_DIR="$home/.claude" HMD_DOCTOR_CLAUDE="$FAKE_DIR/claude" \
    HMD_DOCTOR_CC_TIMEOUT=10 FAKE_CRYPTO_OK=1 "$@" \
    bash "$INSTALLER" </dev/null 2>&1
}

echo "claude-mem-optin harness  repo=$REPO  ref=${REF:0:12}"
echo "--------------------------------------------------------------------"

# ══ A. DEFAULT, not present — declined, ZERO marketplace/install calls ═══════
HA="$TMP_ROOT/A"; LOGA="$TMP_ROOT/log-a"
OUTA="$(run_install "$HA" CLAUDE_CALL_LOG="$LOGA" \
          CM_PRESENT_MARK="$TMP_ROOT/present-a" CM_INSTALLED_MARK="$TMP_ROOT/installed-a")"
if ! grep -qiE 'claude-mem|thedotmack' "$LOGA" 2>/dev/null; then
  ok "DEFAULT: zero claude-mem/thedotmack CLI calls (hmd's own unrelated self-install is untouched by this check)"
else
  bad "DEFAULT: claude-mem was touched WITHOUT opt-in: $(grep -iE 'claude-mem|thedotmack' "$LOGA" | tr '\n' ' ')"
fi
if grep -qi 'not installed by default' <<<"$OUTA" && grep -qi 'HEIMDALL_INSTALL_CLAUDE_MEM' <<<"$OUTA"; then
  ok "DEFAULT: the printed step names the opt-in var"
else
  bad "DEFAULT: no self-serve opt-in instructions in the output: $(grep -iE 'claude-mem' <<<"$OUTA" | tr '\n' ' ' | cut -c1-200)"
fi

# ══ B. OPTED IN, not present — configured, the marketplace+install calls DO fire ══
HB="$TMP_ROOT/B"; LOGB="$TMP_ROOT/log-b"
OUTB="$(run_install "$HB" CLAUDE_CALL_LOG="$LOGB" HEIMDALL_INSTALL_CLAUDE_MEM=1 \
          CM_PRESENT_MARK="$TMP_ROOT/present-b" CM_INSTALLED_MARK="$TMP_ROOT/installed-b" \
          CM_MKT_MARK="$TMP_ROOT/mkt-b")"
if grep -qF 'plugins marketplace add thedotmack/claude-mem' "$LOGB" 2>/dev/null \
   && grep -qF 'plugins install claude-mem@thedotmack' "$LOGB" 2>/dev/null; then
  ok "OPT-IN: HEIMDALL_INSTALL_CLAUDE_MEM=1 still drives the real marketplace+install calls"
else
  bad "OPT-IN: opting in did not reach the install calls: $(cat "$LOGB" 2>/dev/null | tr '\n' ' ' | cut -c1-200)"
fi
if grep -qi 'plugin registered' <<<"$OUTB"; then
  ok "OPT-IN: reports 'plugin registered' (configured state reachable)"
else
  bad "OPT-IN: did not reach the configured state: $(grep -iE 'claude-mem' <<<"$OUTB" | tr '\n' ' ' | cut -c1-200)"
fi

# ══ C. DEFAULT, already present — idempotent: present, still ZERO calls ══════
HC="$TMP_ROOT/C"; LOGC="$TMP_ROOT/log-c"; : > "$TMP_ROOT/present-c"
OUTC="$(run_install "$HC" CLAUDE_CALL_LOG="$LOGC" \
          CM_PRESENT_MARK="$TMP_ROOT/present-c" CM_INSTALLED_MARK="$TMP_ROOT/installed-c")"
if grep -qi 'already enabled' <<<"$OUTC"; then
  ok "DEFAULT + already present: reports 'already enabled' (not re-declined)"
else
  bad "DEFAULT + already present: did not detect the existing install: $(grep -iE 'claude-mem' <<<"$OUTC" | tr '\n' ' ' | cut -c1-200)"
fi
if ! grep -qiE 'claude-mem|thedotmack' "$LOGC" 2>/dev/null; then
  ok "DEFAULT + already present: still zero claude-mem/thedotmack CLI calls (idempotent)"
else
  bad "DEFAULT + already present: touched claude-mem despite an existing install: $(grep -iE 'claude-mem|thedotmack' "$LOGC" | tr '\n' ' ')"
fi

echo "--------------------------------------------------------------------"
echo "  $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
