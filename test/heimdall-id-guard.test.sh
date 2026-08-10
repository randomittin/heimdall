#!/usr/bin/env bash
#
# heimdall-id-guard.test.sh — acceptance harness for the pre-push committer /
# author identity allowlist guard.
#
# Why this exists: v2.2.0's release TRIPPED R9 (the fresh-clone verify inside
# release/ship.sh) because 3 commits carried the committer email rj@superpe.co —
# leaked from agent commits made in scratchpad worktrees. R9 caught it AFTER the
# push. The root-cause fix is a PRE-push gate so a non-allowlisted identity can
# NEVER reach origin: bin/heimdall-check-identities (the single source of truth
# for the allowlist check, reused by ship.sh + the native pre-push hook).
#
# Proofs (all runnable, none skippable):
#
#   1. ALL-ALLOWLISTED — a range whose every author+committer email is on the
#      allowlist exits 0.
#   2. BAD COMMITTER BLOCKED — the exact incident: a commit whose COMMITTER email
#      is rj@superpe.co (author allowlisted) exits nonzero AND names the offender
#      (the email + the short sha).
#   3. BAD AUTHOR BLOCKED — a commit whose AUTHOR email is off-allowlist also
#      exits nonzero (author is checked too, not just committer).
#   4. RANGE SCOPING — a range that EXCLUDES the bad commit exits 0; a range that
#      INCLUDES it exits nonzero. The guard checks exactly the commits in range.
#   5. ESCAPE HATCH — HEIMDALL_SKIP_ID_GUARD=1 turns a would-block into exit 0
#      (documented emergency bypass) and says so on stderr.
#   6. SYNTAX — `bash -n` on the helper AND the native pre-push hook.
#
# Exit 0 = every proof holds. Nonzero = a proof failed (prints which).

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SELF_DIR/.." && pwd)"
GUARD="$REPO/bin/heimdall-check-identities"
HOOK="$REPO/hooks/git/pre-push"

PASS=0; FAIL=0
ok()  { printf '  \033[32mPASS\033[0m %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAIL=$((FAIL + 1)); }

[ -x "$GUARD" ] || { echo "FATAL: heimdall-check-identities not executable at $GUARD"; exit 2; }
[ -f "$HOOK" ]  || { echo "FATAL: pre-push hook not found at $HOOK"; exit 2; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Seed a throwaway repo with a controllable commit history. Each commit's author
# AND committer email are pinned via env so we can plant a bad identity exactly.
SEED="$WORK/repo"
mkdir -p "$SEED"
git -C "$SEED" init -q
git -C "$SEED" config commit.gpgsign false

commit() { # commit <author_email> <committer_email> <message>
  local ae="$1" ce="$2" msg="$3"
  echo "$msg" >> "$SEED/log.txt"
  git -C "$SEED" add -A
  GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL="$ae" \
  GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL="$ce" \
    git -C "$SEED" commit -q -m "$msg"
  git -C "$SEED" rev-parse HEAD
}

GOOD="rj@runheimdall.dev"
BOT="noreply@anthropic.com"
LEAK="rj@superpe.co"   # the exact v2.2.0 R9 offender

C1="$(commit "$GOOD" "$GOOD" "c1 good")"
C2="$(commit "$BOT"  "$BOT"  "c2 bot")"

# ─────────────────────────────────────────────────────────────────────────────
echo "1. ALL-ALLOWLISTED (--all over a clean history exits 0):"
if ( cd "$SEED" && "$GUARD" --all ) >/dev/null 2>&1; then
  ok "clean history -> exit 0"
else
  bad "clean history should exit 0 but the guard blocked"
fi

# Plant the incident: an allowlisted AUTHOR but a leaked COMMITTER.
C3="$(commit "$GOOD" "$LEAK" "c3 leaked committer")"

echo
echo "2. BAD COMMITTER BLOCKED (committer $LEAK -> nonzero + names offender):"
OUT2="$( ( cd "$SEED" && "$GUARD" --all ) 2>&1 )" && RC2=0 || RC2=$?
if [ "$RC2" -ne 0 ]; then
  ok "leaked committer -> nonzero (exit $RC2)"
else
  bad "leaked committer should block (got exit 0)"
fi
if grep -Fq "$LEAK" <<<"$OUT2"; then
  ok "output names the offending email ($LEAK)"
else
  bad "output must name the offending email $LEAK"
fi
if grep -Fq "${C3:0:7}" <<<"$OUT2"; then
  ok "output names the offending short sha (${C3:0:7})"
else
  bad "output must name the offending commit ${C3:0:7}"
fi

# ─────────────────────────────────────────────────────────────────────────────
echo
echo "3. BAD AUTHOR BLOCKED (author off-allowlist also blocks):"
C4="$(commit "$LEAK" "$GOOD" "c4 leaked author")"
if ( cd "$SEED" && "$GUARD" --all ) >/dev/null 2>&1; then
  bad "leaked author should block (got exit 0)"
else
  ok "leaked author -> nonzero"
fi

# ─────────────────────────────────────────────────────────────────────────────
echo
echo "4. RANGE SCOPING (excluding the bad commits exits 0; including blocks):"
# C1..C2 is entirely clean (excludes C3/C4).
if ( cd "$SEED" && "$GUARD" "$C1..$C2" ) >/dev/null 2>&1; then
  ok "clean range ${C1:0:7}..${C2:0:7} -> exit 0"
else
  bad "clean range ${C1:0:7}..${C2:0:7} should exit 0"
fi
# C2..C3 includes the leaked committer commit.
if ( cd "$SEED" && "$GUARD" "$C2..$C3" ) >/dev/null 2>&1; then
  bad "range ${C2:0:7}..${C3:0:7} includes the leak -> should block"
else
  ok "range ${C2:0:7}..${C3:0:7} includes the leak -> nonzero"
fi

# ─────────────────────────────────────────────────────────────────────────────
echo
echo "5. ESCAPE HATCH (HEIMDALL_SKIP_ID_GUARD=1 forces exit 0 + says so):"
OUT5="$( ( cd "$SEED" && HEIMDALL_SKIP_ID_GUARD=1 "$GUARD" --all ) 2>&1 )" && RC5=0 || RC5=$?
if [ "$RC5" -eq 0 ]; then
  ok "escape hatch on a dirty history -> exit 0"
else
  bad "escape hatch should force exit 0 (got exit $RC5)"
fi
if grep -Fq "HEIMDALL_SKIP_ID_GUARD" <<<"$OUT5"; then
  ok "escape-hatch bypass is announced on stderr"
else
  bad "escape-hatch bypass must be announced on stderr"
fi

# ─────────────────────────────────────────────────────────────────────────────
echo
echo "6. PRE-PUSH STDIN MODE (the mode the native hook feeds):"
Z="0000000000000000000000000000000000000000"
# Existing-ref update whose range includes the leaked-committer commit -> block.
if printf 'refs/heads/main %s refs/heads/main %s\n' "$C3" "$C2" \
     | ( cd "$SEED" && "$GUARD" --pre-push ) >/dev/null 2>&1; then
  bad "--pre-push over a range containing the leak should block"
else
  ok "--pre-push (existing ref, range ${C2:0:7}..${C3:0:7}) blocks the leak"
fi
# A deletion line (local sha all-zero) is a no-op -> exit 0.
if printf 'refs/heads/gone %s refs/heads/gone %s\n' "$Z" "$C4" \
     | ( cd "$SEED" && "$GUARD" --pre-push ) >/dev/null 2>&1; then
  ok "--pre-push deletion line (zero local sha) is a clean no-op"
else
  bad "--pre-push deletion line should be a clean no-op (exit 0)"
fi

echo
echo "7. SYNTAX (bash -n on the helper + the native pre-push hook):"
if bash -n "$GUARD" 2>/dev/null; then ok "bash -n: heimdall-check-identities"; else bad "bash -n failed: $GUARD"; fi
if bash -n "$HOOK"  2>/dev/null; then ok "bash -n: hooks/git/pre-push";       else bad "bash -n failed: $HOOK"; fi

# ─────────────────────────────────────────────────────────────────────────────
echo
echo "──────────────────────────────────────────"
printf 'RESULT: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
