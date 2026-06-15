#!/usr/bin/env bash
#
# install-stranger.sh — stranger-environment acceptance harness for install.sh
#
# Reproduces a clean curl-install in a stripped env (a fresh $HOME, a minimal
# PATH carrying only claude/node/git) and asserts the four launch-blocking
# guarantees a real first-time user depends on:
#
#   1. COMPONENT RESOLUTION — after install, `hmd demo` finds heimdall-demo, and
#      the launcher resolves EVERY sibling it touches (face, state, city, …).
#      A dev repo with all components already on PATH hides this bug; only a
#      stripped env exposes it.
#   2. DYNAMIC VERSION — the success card shows the ACTUAL installed version
#      (resolved from the fetched ref/tag), never a hardcoded literal.
#   3. CONSISTENT PATH — the card's stated install location matches where things
#      were actually placed (no "~/.heimdall" vs "~/.local/bin" contradiction).
#   4. PATH SETUP — `hmd` is reachable after install: the installer appends the
#      bin dir to the user's shell profile, idempotently (a second run must not
#      double-append), so the headline `hmd demo` actually runs.
#
# Usage:
#   test/install-stranger.sh                 # uses repo of this checkout @ HEAD
#   REPO=/path REF=<sha|tag> test/install-stranger.sh
#
# Exit 0 = all guarantees hold. Non-zero = a guarantee regressed (prints which).
set -uo pipefail

# ── Resolve the repo + ref under test (this working tree by default) ──────────
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="${REPO:-$(cd "$SELF_DIR/.." && pwd)}"
REF="${REF:-$(git -C "$REPO" rev-parse HEAD)}"

# ── Resolve tool dirs for the stripped PATH (claude/node/git must be findable) ─
need() { command -v "$1" >/dev/null 2>&1 || { echo "FATAL: $1 not found on host PATH"; exit 2; }; }
need claude; need git
CLAUDE_BIN="$(cd "$(dirname "$(command -v claude)")" && pwd)"
GIT_BIN="$(cd "$(dirname "$(command -v git)")" && pwd)"
# node may be an nvm shell function; resolve the real binary dir.
NODE_REAL="$(bash -lc 'command -v node' 2>/dev/null || true)"
if [ -z "$NODE_REAL" ] || [ "$NODE_REAL" = "node" ]; then
  if [ -d "$HOME/.nvm/versions/node" ]; then
    _lv="$(ls "$HOME/.nvm/versions/node" 2>/dev/null | sed 's/^v//' | sort -t. -k1,1n -k2,2n -k3,3n | tail -1)"
    NODE_REAL="$HOME/.nvm/versions/node/v${_lv}/bin/node"
  fi
fi
NODE_BIN="$(cd "$(dirname "$NODE_REAL")" && pwd 2>/dev/null || echo /usr/bin)"
STRANGER_PATH="$CLAUDE_BIN:$NODE_BIN:$GIT_BIN:/usr/bin:/bin"

PASS=0; FAIL=0
ok()   { printf '  \033[32mPASS\033[0m %s\n' "$1"; PASS=$((PASS+1)); }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAIL=$((FAIL+1)); }

run_install() {  # $1=HOME
  env -i HOME="$1" TERM="dumb" PATH="$STRANGER_PATH" \
    HEIMDALL_REPO="$REPO" HEIMDALL_REF="$REF" HEIMDALL_NO_COLOR=1 \
    bash "$REPO/install.sh" 2>&1
}
in_stranger() { # $1=HOME, rest=cmd — run a command as the stranger would
  local h="$1"; shift
  env -i HOME="$h" TERM="dumb" PATH="$STRANGER_PATH" "$@" 2>&1
}

TMPH="$(mktemp -d)"
trap 'rm -rf "$TMPH"' EXIT

echo "stranger-install harness  repo=$REPO  ref=${REF:0:12}  HOME=$TMPH"
echo "--------------------------------------------------------------------"

# ── Fresh install ─────────────────────────────────────────────────────────────
CARD="$(run_install "$TMPH")"

# Expected version: what `git describe --tags` reports in the installed clone —
# the SAME source the launcher's heimdall_version() trusts first.
EXPECT_VER="$(git -C "$TMPH/.heimdall" describe --tags --abbrev=0 2>/dev/null \
  | sed -E 's/^v?([0-9]+\.[0-9]+\.[0-9]+).*/\1/')"
[ -n "$EXPECT_VER" ] || EXPECT_VER="$(git -C "$REPO" describe --tags --abbrev=0 2>/dev/null | sed -E 's/^v?([0-9]+\.[0-9]+\.[0-9]+).*/\1/')"

# (2) DYNAMIC VERSION — card must show the real version, not a stale literal.
if printf '%s' "$CARD" | grep -qE "Heimdall v${EXPECT_VER}([^0-9]|\$)"; then
  ok "card shows dynamic version v$EXPECT_VER"
else
  bad "card version is not the installed v$EXPECT_VER — got: $(printf '%s' "$CARD" | grep -iE 'Heimdall v[0-9]' | head -1 | sed 's/^ *//')"
fi

# (3) CONSISTENT PATH — the card must not claim a single install path that
# contradicts where the launchers actually went. If the card prints a path
# line, every path it names must be a real, populated location.
LAUNCHER="$TMPH/.local/bin/hmd"
[ -e "$LAUNCHER" ] || LAUNCHER="$TMPH/.local/bin/heimdall"
if printf '%s' "$CARD" | grep -qE 'path:.*\.heimdall' \
   && ! printf '%s' "$CARD" | grep -qE 'local/bin|launchers?|hmd, heimdall'; then
  bad "card states 'path: ~/.heimdall' only — contradicts launchers placed in ~/.local/bin"
else
  ok "card install location is consistent with what was placed"
fi

# (1) COMPONENT RESOLUTION — the headline command must resolve its runner.
DEMO_OUT="$(in_stranger "$TMPH" "$LAUNCHER" demo --dry 2>&1)"
if printf '%s' "$DEMO_OUT" | grep -qi 'demo runner not found'; then
  bad "hmd demo: $(printf '%s' "$DEMO_OUT" | grep -i 'not found' | head -1 | sed 's/^ *//')"
else
  ok "hmd demo resolves heimdall-demo (no 'not found')"
fi

# (1b) COMPONENT RESOLUTION (real task path) — prove the launcher resolves every
# sibling a real `hmd "task"` touches WITHOUT a model call. `hmd version` runs
# the same $0→readlink→PLUGIN_DIR resolution; then we directly probe that each
# component the task path invokes exists beside the resolved launcher.
VER_OUT="$(in_stranger "$TMPH" "$LAUNCHER" version 2>&1)"
VER_LINE="$(printf '%s' "$VER_OUT" | grep -iE 'Heimdall v[0-9]' | head -1 | sed 's/^ *//')"
# TIGHTENED (was: merely asserts it RUNS). `hmd version` must report the EXACT
# release version the launcher resolves (git-describe of the installed tree →
# manifest fallback) — the SAME value the success card shows. It previously read
# plugin.json directly and reported a hardcoded "Heimdall v1.1.0" for the entire
# v2.0.x line; this gate makes that drift impossible to re-ship.
if [ -z "$VER_LINE" ]; then
  bad "hmd version failed to run through the launcher: $VER_OUT"
elif printf '%s' "$VER_OUT" | grep -qE "Heimdall v${EXPECT_VER}([^0-9]|\$)"; then
  # Equals the installed release version. Also explicitly reject the stale 1.1.0
  # whenever the release has moved past it (defense in depth — if EXPECT_VER ever
  # mis-resolves, a literal 1.1.0 still fails loudly here).
  if [ "$EXPECT_VER" != "1.1.0" ] && printf '%s' "$VER_OUT" | grep -qE 'Heimdall v1\.1\.0([^0-9]|$)'; then
    bad "hmd version reports stale hardcoded 1.1.0 (expected v$EXPECT_VER) — plugin.json drift"
  else
    ok "hmd version reports release version v$EXPECT_VER (not stale 1.1.0): $VER_LINE"
  fi
else
  bad "hmd version is not the installed release v$EXPECT_VER — got: $VER_LINE"
fi
# Resolve PLUGIN_DIR exactly as the launcher does (readlink -f $0 → dirname/..)
REAL_LAUNCHER="$(in_stranger "$TMPH" /usr/bin/readlink -f "$LAUNCHER" 2>/dev/null || echo "$LAUNCHER")"
RESOLVED_PLUGIN="$(cd "$(dirname "$REAL_LAUNCHER")/.." && pwd)"
MISSING=""
for comp in heimdall-demo heimdall-face heimdall-city heimdall-state \
            heimdall-selfscan skill-manager discover-skills summary-card; do
  [ -x "$RESOLVED_PLUGIN/bin/$comp" ] || MISSING="$MISSING $comp"
done
if [ -z "$MISSING" ]; then
  ok "all task-path components resolve beside launcher ($RESOLVED_PLUGIN/bin)"
else
  bad "components NOT beside resolved launcher ($RESOLVED_PLUGIN/bin):$MISSING"
fi

# (4) PATH SETUP — installer must put the bin dir on PATH via a shell profile,
# idempotently. Detect which profile it wrote, count the lines mentioning the
# bin dir; a fresh install adds exactly one.
PROFILE=""
for p in "$TMPH/.zshrc" "$TMPH/.bashrc" "$TMPH/.profile" "$TMPH/.bash_profile"; do
  if [ -f "$p" ] && grep -qE '\.local/bin' "$p"; then PROFILE="$p"; break; fi
done
if [ -n "$PROFILE" ]; then
  N1="$(grep -cE '\.local/bin' "$PROFILE")"
  ok "PATH export written to $(basename "$PROFILE") ($N1 line)"
else
  bad "no shell profile gained a ~/.local/bin PATH export — hmd stays command-not-found"
fi

# After sourcing the written profile, `hmd` must resolve by bare name on PATH.
if [ -n "$PROFILE" ]; then
  WHICH="$(env -i HOME="$TMPH" TERM="dumb" PATH="/usr/bin:/bin" \
    bash -c "source '$PROFILE' >/dev/null 2>&1; command -v hmd || command -v heimdall" 2>&1)"
  if printf '%s' "$WHICH" | grep -q '/.local/bin/'; then
    ok "after sourcing profile, hmd/heimdall resolves on PATH ($WHICH)"
  else
    bad "after sourcing profile, hmd not on PATH (got: ${WHICH:-<empty>})"
  fi
fi

# ── Idempotency: a second install in the SAME HOME must not double-append ──────
run_install "$TMPH" >/dev/null 2>&1
if [ -n "$PROFILE" ]; then
  N2="$(grep -cE '\.local/bin' "$PROFILE")"
  if [ "$N2" = "${N1:-0}" ]; then
    ok "second install is idempotent — PATH line count unchanged ($N2)"
  else
    bad "second install double-appended PATH (was ${N1:-?}, now $N2)"
  fi
fi
# And the launcher must still resolve its demo runner after the re-install.
DEMO2="$(in_stranger "$TMPH" "$LAUNCHER" demo --dry 2>&1)"
if printf '%s' "$DEMO2" | grep -qi 'demo runner not found'; then
  bad "after re-install, hmd demo regressed to 'not found'"
else
  ok "after re-install, hmd demo still resolves"
fi

echo "--------------------------------------------------------------------"
echo "  $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
