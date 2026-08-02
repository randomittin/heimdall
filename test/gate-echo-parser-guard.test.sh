#!/usr/bin/env bash
#
# gate-echo-parser-guard.test.sh — CLASS-LEVEL structural guard.
#
# WHY THIS FILE EXISTS
# --------------------
# `echo` is not byte-exact. On macOS /bin/sh is bash 3.2 in POSIX/sh-compat mode,
# where the `echo` builtin EXPANDS backslash escapes (dash, the /bin/sh of most
# Linux distros, does the same). So:
#
#     echo "$INPUT" | jq -r '.tool_input.command'
#
# turns the two characters \ n — legal, ESCAPED, inside a JSON string — into a raw
# 0x0A byte inside that same string, and jq rejects the whole document:
#
#     jq: parse error: Invalid string: control characters from U+0000 through
#     U+001F must be escaped
#
# jq exits 5, the command substitution yields EMPTY, and the guard that was meant
# to run skips ITSELF via its own `if [ -n "$VAR" ]`. No error. No log. No warning.
# The gate reports success by saying nothing at all — it fails OPEN.
#
# Measured blast radius when this regressed (one live session transcript):
#   215 of 312 PreToolUse:Bash invocations died on that parse error. With the
#   command string empty, `grep -qE '^git\s+push'` never matched, so the ENTIRE
#   pre-push chain silently no-opped: quality gates, secret scan, full-history
#   selfscan, oracle falsifiability, corpus regression, and the pre-commit
#   gitleaks scan. Every one of them reported nothing and blocked nothing.
#
# `printf '%s'` is byte-exact and performs no escape processing. That is the fix.
# test/hook-payload-escaping.test.sh proves it BEHAVIOURALLY for hooks.json.
# THIS file proves it STRUCTURALLY, across every file that can fail open — so the
# next gate added to the chain cannot reintroduce the silent skip.
#
# SCOPE — and why it is exactly this set
# --------------------------------------
# Scanned: the fail-open surface only. hooks.json commands (the harness runs them
# under /bin/sh, so they are ALWAYS escape-expanding), the git hooks, and the
# pre-push chain binaries.
#
# NOT scanned: ordinary bash scripts. Under an explicit `#!/usr/bin/env bash`
# the echo builtin does NOT expand escapes, so `echo "$x" | jq` there is not the
# defect — rewriting those ~180 call sites would be pure churn, and churn hides
# real fixes. The gate set below is already 100% clean, so enforcing the strict
# discipline over exactly this set costs zero changes today and locks the door
# permanently. Defense in depth is warranted here specifically because these
# files fail OPEN: a gate is one `sh gate-file` invocation, or one shebang edit,
# away from silently passing everything.
#
# ANTI-VACUOUS DESIGN
# -------------------
# Five gates in this repo were proven VACUOUSLY GREEN on 2026-08-03 — a scan of
# zero files reporting "clean" is the exact failure mode this guard must not have.
# So this file asserts, as real test cases:
#   * a non-zero floor of files actually scanned,
#   * every named gate file EXISTS (a renamed/deleted gate FAILS; it never skips),
#   * a POSITIVE CONTROL: the detector is run against a synthetic known-bad
#     fixture and must FIRE. A detector that cannot detect makes every green
#     result meaningless.
#
# Usage:  bash test/gate-echo-parser-guard.test.sh   (exit 0 = invariant holds)
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SELF_DIR/.." && pwd)"
HOOKS="$REPO/hooks/hooks.json"

PASS=0; FAIL=0
ok()   { printf '  \033[32mPASS\033[0m %s\n' "$1"; PASS=$((PASS+1)); }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAIL=$((FAIL+1)); }
# Skips are LOUD and count as failures: a gate that cannot be checked is a gate
# that is not proven, and this suite exists precisely because unproven read green.
skip() { printf '  \033[31mSKIP-AS-FAIL\033[0m %s\n' "$1"; FAIL=$((FAIL+1)); }

echo "gate-echo-parser-guard  repo=$REPO"
echo "--------------------------------------------------------------------"

if ! command -v jq >/dev/null 2>&1; then
  echo "  jq is required for this test" >&2
  exit 1
fi

# ── the fail-open surface ────────────────────────────────────────────────────
# Every entry is a gate, guard, hook, or security scan whose silent no-op lets
# something unproven through. Membership is explicit, never a glob, so that a
# DELETED gate surfaces as a failure instead of quietly shrinking the scan.
GATE_FILES="
hooks/git/pre-push
hooks/statusline.sh
bin/secret-scan
bin/heimdall-selfscan
bin/falsify
bin/corpus
bin/heimdall-stamp
bin/heimdall-state
bin/bloat-gate
"

# Parsers whose input must be byte-exact. Feeding any of these a mangled string
# makes the consumer silently see the wrong thing (or nothing at all).
PARSERS='jq|grep|sed|awk|python3|python|cut|tr|xargs|base64|wc|read|head|tail|sort|uniq|md5|shasum|sha256sum'

# The unsafe shapes, as an ERE:
#   echo "$VAR" | parser      echo $VAR | parser      echo "${VAR}" | parser
#   echo "$(cmd)" | parser
# `[^|;&]*` deliberately refuses to cross a statement boundary, so a benign
# `... || echo unknown); NEXT=$(printf '%s' "$X" | jq ...)` is NOT matched. That
# false positive is real: a looser regex reported hooks.json dirty when it was
# clean, and a guard that cries wolf gets muted, which is how gates die.
UNSAFE_RE="echo[[:space:]]+[^|;&]*(\\\$\\{?[A-Za-z_][A-Za-z0-9_]*\\}?|\\\$\\()[^|;&]*\\|[[:space:]]*($PARSERS)([[:space:]]|\$)"

# scan_text <label> — reads text on stdin, prints one "label:line" per unsafe hit.
scan_text() {
  grep -nE "$UNSAFE_RE" 2>/dev/null | sed "s|^|$1:|"
}

SCANNED=0
HITS=""

# ── 1. shell gate files ──────────────────────────────────────────────────────
MISSING=""
for rel in $GATE_FILES; do
  f="$REPO/$rel"
  if [ ! -f "$f" ]; then
    MISSING="$MISSING $rel"
    continue
  fi
  SCANNED=$((SCANNED + 1))
  found=$(scan_text "$rel" < "$f")
  [ -n "$found" ] && HITS="$HITS$found"$'\n'
done

if [ -n "$MISSING" ]; then
  # NOT a skip. A gate file that vanished is either a rename this guard must be
  # taught, or a gate that silently stopped existing — both need a human.
  bad "gate file(s) missing from the repo — guard is stale or a gate was deleted:$MISSING"
else
  ok "every named gate file exists ($(printf '%s' "$GATE_FILES" | grep -c '[^[:space:]]') declared)"
fi

# ── 2. hooks.json command strings (ALWAYS /bin/sh — the confirmed defect site) ─
HOOK_CMD_COUNT=0
if [ ! -f "$HOOKS" ]; then
  bad "missing $HOOKS — the primary fail-open surface is unscanned"
else
  HOOK_CMD_COUNT=$(jq -r '[ .hooks[][] | .hooks[]? | .command // empty ] | length' "$HOOKS" 2>/dev/null || echo 0)
  if [ "${HOOK_CMD_COUNT:-0}" -lt 1 ]; then
    bad "hooks.json yielded 0 command strings — the scan would be vacuous"
  else
    SCANNED=$((SCANNED + HOOK_CMD_COUNT))
    found=$(jq -r '.hooks[][] | .hooks[]? | .command // empty' "$HOOKS" 2>/dev/null | scan_text "hooks.json")
    [ -n "$found" ] && HITS="$HITS$found"$'\n'
    ok "hooks.json exposed $HOOK_CMD_COUNT hook command string(s) to the scan"
  fi
fi

# ── 3. THE INVARIANT ─────────────────────────────────────────────────────────
CLEAN_HITS=$(printf '%s' "$HITS" | grep -c '[^[:space:]]' || true)
if [ "${CLEAN_HITS:-0}" -eq 0 ]; then
  ok "no gate/hook/guard file pipes a variable into a parser via echo"
else
  bad "$CLEAN_HITS unsafe echo-into-parser site(s) in the fail-open surface:"
  printf '%s\n' "$HITS" | grep '[^[:space:]]' | sed 's/^/         /'
  printf '         \033[33mfix: printf %%s (byte-exact) — or printf %%s\\\\n where a trailing newline is required\033[0m\n'
fi

# ── 4. ANTI-VACUOUS: the scan actually examined something ────────────────────
# A scan of zero files reporting clean is the failure mode that made five gates
# read green today. The floor is the count of declared shell gates; it can only
# be met by really opening them.
FLOOR=$(printf '%s' "$GATE_FILES" | grep -c '[^[:space:]]')
if [ "$SCANNED" -ge "$FLOOR" ] && [ "$SCANNED" -gt 0 ]; then
  ok "anti-vacuous: scanned $SCANNED unit(s) — at or above the floor of $FLOOR"
else
  bad "anti-vacuous FAILED: scanned only $SCANNED unit(s), floor is $FLOOR — this run proved nothing"
fi

# ── 5. ANTI-VACUOUS: POSITIVE CONTROL — the detector must actually detect ────
# Built at runtime so this file never itself contains the banned shape (which
# would make the guard flag its own source if the scope ever widened).
BAITS_OK=0; BAITS_TOTAL=0
BAIT_DIR="$(mktemp -d "${TMPDIR:-/tmp}/gate-echo-guard.XXXXXX")"
trap 'rm -rf "$BAIT_DIR"' EXIT
E=$(printf 'ech'; printf 'o')
for bait in \
  "CMD=\$($E \"\$INPUT\" | jq -r '.tool_input.command')" \
  "$E \"\$CMD\" | grep -qE '^git push'" \
  "$E \$CMD | sed 's/a/b/'" \
  "$E \"\${PAYLOAD}\" | python3 -c 'import sys'" \
  "$E \"\$(cat f)\" | awk '{print}'" ; do
  BAITS_TOTAL=$((BAITS_TOTAL + 1))
  if printf '%s\n' "$bait" | scan_text "bait" | grep -q .; then
    BAITS_OK=$((BAITS_OK + 1))
  else
    bad "positive control MISSED an unsafe shape: $bait"
  fi
done
if [ "$BAITS_OK" -eq "$BAITS_TOTAL" ] && [ "$BAITS_TOTAL" -gt 0 ]; then
  ok "positive control: detector fires on all $BAITS_TOTAL known-bad shapes"
fi

# ── 6. ANTI-VACUOUS: NEGATIVE CONTROL — the detector must not cry wolf ───────
# The correct form, and the benign `|| echo word;` boundary case that a looser
# regex false-positived on. A guard with false positives gets muted.
NEG_OK=0; NEG_TOTAL=0
for good in \
  "CMD=\$(printf '%s' \"\$INPUT\" | jq -r '.tool_input.command')" \
  "printf '%s\\n' \"\$CMD\" | grep -qE '^git push'" \
  "TOOL=\$(printf '%s' \"\$I\" | jq -r .t || $E unknown); N=\$(printf '%s' \"\$I\" | jq -r .n)" \
  "$E \"static literal text\" | grep -q x" ; do
  NEG_TOTAL=$((NEG_TOTAL + 1))
  if printf '%s\n' "$good" | scan_text "neg" | grep -q .; then
    bad "negative control: detector FALSE-POSITIVED on a safe form: $good"
  else
    NEG_OK=$((NEG_OK + 1))
  fi
done
if [ "$NEG_OK" -eq "$NEG_TOTAL" ] && [ "$NEG_TOTAL" -gt 0 ]; then
  ok "negative control: detector stays silent on all $NEG_TOTAL safe forms"
fi

# ── 7. the platform fact this whole guard rests on ──────────────────────────
# Informational but LOUD: documents WHY printf is mandatory, and would announce
# a platform where the premise no longer holds. Never silently absent.
SH_PROBE='{"c":"a\nb"}'
if printf '%s' "$SH_PROBE" | /bin/sh -c 'read -r L; echo "$L" | jq -r .c' >/dev/null 2>&1; then
  printf '  \033[33mNOTE\033[0m  /bin/sh echo did NOT corrupt here — premise is platform-specific,\n'
  printf '        but the printf discipline stays mandatory (macOS sh + dash DO corrupt).\n'
else
  ok "platform fact confirmed: /bin/sh echo corrupts an escape-carrying payload"
fi

echo "--------------------------------------------------------------------"
echo "  $PASS passed, $FAIL failed   (scanned $SCANNED units across the fail-open surface)"
[ "$FAIL" -eq 0 ]
