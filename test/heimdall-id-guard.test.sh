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
#   6. PRE-PUSH STDIN MODE — the mode the native hook feeds: a range holding the
#      leak blocks; a deletion line is a clean no-op.
#   7. SYNTAX — `bash -n` on the helper AND the native pre-push hook.
#   8. IMPORTED RELAY HISTORY — rj@superpe.in, the author+committer of the history
#      imported with the hmdapp relay (merge eb5360e4, operator decision A,
#      2026-10-03), is allowlisted; lookalikes of it and strangers still block.
#   9. ALLOWLIST PARITY — this helper and bin/heimdall-selfscan hard-code the SAME
#      list (and the helper's remediation hint names every entry of it).
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
echo "8. IMPORTED RELAY HISTORY (rj@superpe.in allowlisted; lookalikes still block):"
# Operator decision A, 2026-10-03: the hmdapp relay history imported by merge
# eb5360e4 is authored AND committed as rj@superpe.in. The entry is an EXACT match —
# it must admit that one address and nothing that merely resembles it.
RELAY="rj@superpe.in"
C5="$(commit "$RELAY" "$RELAY" "c5 imported relay history")"
if ( cd "$SEED" && "$GUARD" "$C4..$C5" ) >/dev/null 2>&1; then
  ok "author+committer $RELAY -> exit 0 (the imported history's exact shape)"
else
  bad "author+committer $RELAY must be allowlisted but the guard blocked"
fi
# Each unlisted address goes in as the AUTHOR on its own commit; the commit message
# deliberately does not repeat it, so "the output names it" cannot be satisfied by the
# subject line alone.
PREV="$C5"
for NOPE in "rj@superpe.in.evil.test" "xrj@superpe.in" "stranger@example.com"; do
  CN="$(commit "$NOPE" "$GOOD" "c6 unlisted address")"
  OUTN="$( ( cd "$SEED" && "$GUARD" "$PREV..$CN" ) 2>&1 )" && RCN=0 || RCN=$?
  if [ "$RCN" -ne 0 ] && grep -Fq "$NOPE" <<<"$OUTN" && grep -Fq "${CN:0:7}" <<<"$OUTN"; then
    ok "unlisted $NOPE still blocks, named with ${CN:0:7} (exit $RCN)"
  else
    bad "unlisted $NOPE must block and be named with ${CN:0:7} (exit $RCN)"
  fi
  PREV="$CN"
done

# ─────────────────────────────────────────────────────────────────────────────
echo
echo "9. ALLOWLIST PARITY (this helper and bin/heimdall-selfscan hard-code ONE list):"
SELFSCAN="$REPO/bin/heimdall-selfscan"
[ -f "$SELFSCAN" ] || { echo "FATAL: heimdall-selfscan not found at $SELFSCAN"; exit 2; }
# Both gates hard-code the allowlist on purpose (a configurable one is an escape hatch),
# so this proof is all that stops them drifting. Drift is a push that is green at one
# layer and red at the next: the pre-push range check admits an identity the
# full-history sweep then blocks, or the reverse.
allowlist_of() { # allowlist_of <script> -> its ALLOWED_IDENTITIES literal, one email per line, sorted
  sed -n '/^ALLOWED_IDENTITIES="/,/"$/{s/^ALLOWED_IDENTITIES="//;s/"$//;p;}' "$1" | sort
}
GUARD_LIST="$(allowlist_of "$GUARD")"
SCAN_LIST="$(allowlist_of "$SELFSCAN")"
# ANTI-VACUOUS: two empty or garbled extractions would compare equal. Both must be
# non-empty and every line must be a bare email.
SHAPE_OK=1
for L in "$GUARD_LIST" "$SCAN_LIST"; do
  [ -n "$L" ] || SHAPE_OK=0
  while IFS= read -r E; do
    grep -Eq '^[^[:space:]@"]+@[^[:space:]@"]+$' <<<"$E" || SHAPE_OK=0
  done <<<"$L"
done
if [ "$SHAPE_OK" -eq 1 ]; then
  ok "both literals extracted, every line a bare email (helper: $(printf '%s' "$GUARD_LIST" | tr '\n' ' ') | selfscan: $(printf '%s' "$SCAN_LIST" | tr '\n' ' '))"
else
  bad "could not extract a well-formed ALLOWED_IDENTITIES literal from one of the gates — the comparison below would be vacuous"
fi
if [ "$GUARD_LIST" = "$SCAN_LIST" ]; then
  ok "the two allowlists are identical"
else
  bad "allowlist DRIFT between heimdall-check-identities and heimdall-selfscan:"
  diff <(printf '%s\n' "$GUARD_LIST") <(printf '%s\n' "$SCAN_LIST") | sed 's/^/      /'
fi
# FALSIFIABLE: one extra address in a copy of selfscan's literal must read as drift.
DRIFT="$WORK/selfscan.drift"
awk '{ print } /^ALLOWED_IDENTITIES="/ { print "drift@example.com" }' "$SELFSCAN" > "$DRIFT"
if [ "$(allowlist_of "$DRIFT")" != "$SCAN_LIST" ]; then
  ok "falsifier: one extra address in a copy of selfscan's literal is seen as drift"
else
  bad "falsifier: the comparison did not notice an extra address — the identical-lists proof is vacuous"
fi
# The remediation hint (the git filter-repo callback in the BLOCKED output) lists the
# allowlist by hand. A stale one would tell the operator to rewrite commits that are
# allowlisted — so it must name every entry. $OUT2 is the BLOCKED output of proof 2.
HINT_TUPLE="$(sed -n 's/.*email not in (\(.*\)) else email.*/\1/p' <<<"$OUT2")"
HINT_MISSING=""
while IFS= read -r E; do
  grep -Fq "b\"$E\"" <<<"$HINT_TUPLE" || HINT_MISSING="$HINT_MISSING $E"
done <<<"$GUARD_LIST"
if [ -n "$HINT_TUPLE" ] && [ -z "$HINT_MISSING" ]; then
  ok "the filter-repo remediation hint names every allowlisted address"
else
  bad "the filter-repo remediation hint is missing:${HINT_MISSING:- (no hint tuple found in the BLOCKED output)}"
fi

# ─────────────────────────────────────────────────────────────────────────────
echo
echo "──────────────────────────────────────────"
printf 'RESULT: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
