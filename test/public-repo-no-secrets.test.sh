#!/usr/bin/env bash
#
# public-repo-no-secrets.test.sh — the public-repo secret-artifact gate.
#
# Heimdall's repo is PUBLIC. Its multi-tenant presence system keeps its live
# credentials in RUNTIME-ONLY files that must NEVER be tracked in git:
#
#   - <repo>/.heimdall/team.json           the per-repo team secret (bearer cap)
#   - $HOME/.heimdall/cp-endpoint.json     the control-plane enroll_token (secret)
#   - $HOME/.heimdall/pki/<haid>.seed      the per-dev Ed25519 signing seed
#   - anything under a pki/ dir             signing material
#
# install.sh writes these outside any repo (mode 0600); .gitignore keeps them
# out. This test is the STANDING proof that they never slipped in anyway — it is
# a filename/path gate on the tracked tree, not a content entropy scan (real
# secret-SHAPED strings are gitleaks' job; see bin/heimdall-selfscan + the
# fixture-secret convention). It complements, not duplicates, that scan.
#
# Two proofs, both runnable, neither skippable:
#
#   A. ARTIFACT NAMES — zero tracked files are one of the runtime secret
#      artifacts above. Patterns are ANCHORED so they catch the real bearer and
#      NOT the committed *.example templates or code that merely has "token" in
#      its name (bin/heimdall-*-token scripts, TOKEN-METRIC.md — all legit).
#
#   B. CONFIG PLACEHOLDERS — the committed *.example config artifacts
#      (cp-endpoint.json*, team.json*) carry ONLY placeholder secret values
#      (<...>), never a real enroll_token / team_secret. This is scoped to the
#      config artifacts themselves so it can never be fooled into flagging a
#      test fixture's obviously-fake sentinel elsewhere in the tree.
#
# Exit 0 = the tree is clean. Nonzero = a secret artifact is tracked (prints it).

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SELF_DIR/.." && pwd)"
cd "$REPO"

PASS=0; FAIL=0
ok()  { printf '  \033[32mPASS\033[0m %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAIL=$((FAIL + 1)); }

echo "public-repo-no-secrets: scanning tracked tree at $REPO"

# ── Proof A — no runtime secret ARTIFACT is tracked ──────────────────────────
# team.json / cp-endpoint.json : anchored $ so *.example templates DON'T match.
# *.seed and pki/               : signing material — never any legit tracked copy.
# *.token / *.tok               : raw token dumps ( bin/*-token scripts end in
#                                 "-token", not ".token", so they do NOT match ).
ARTIFACT_RE='(^|/)team\.json$|\.seed$|(^|/)pki/|(^|/)cp-endpoint\.json$|\.token$|\.tok$'
HITS="$(git ls-files | grep -iE "$ARTIFACT_RE" || true)"
if [ -z "$HITS" ]; then
  ok "A: no tracked runtime secret artifact (team.json / *.seed / pki/ / cp-endpoint.json / *.token)"
else
  bad "A: tracked SECRET ARTIFACT(S) found — remove + rotate before this ships public:"
  printf '       %s\n' $HITS
fi

# ── Proof B — committed config artifacts carry placeholders only ─────────────
CONFIGS="$(git ls-files | grep -iE '(cp-endpoint|team)\.json' || true)"
LEAKED=""
for f in $CONFIGS; do
  # a secret-key line whose value is NOT a <placeholder> is a real leak
  if grep -nIiE '"(enroll_token|team_secret|team_key)"[[:space:]]*:' "$f" \
       | grep -vE '"<[^"]*>"' >/dev/null 2>&1; then
    LEAKED="$LEAKED $f"
  fi
done
if [ -z "$LEAKED" ]; then
  ok "B: committed config artifacts carry only <placeholder> secret values (${CONFIGS:-none tracked})"
else
  bad "B: config artifact(s) carry a NON-placeholder secret value:"
  for f in $LEAKED; do
    grep -nIiE '"(enroll_token|team_secret|team_key)"[[:space:]]*:' "$f" | grep -vE '"<[^"]*>"'
    printf '       ^^ in %s\n' "$f"
  done
fi

echo
echo "  public-repo-no-secrets tests: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
