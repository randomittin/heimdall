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

# ── THE DETECTORS ────────────────────────────────────────────────────────────
# One implementation each, used by BOTH the real sweep (A/B) and the falsifiability
# mutation (C) — so C proves the *shipping* detector fires, never a lookalike.
#
# team.json / cp-endpoint.json : anchored $ so *.example templates DON'T match.
# *.seed and pki/               : signing material — never any legit tracked copy.
# *.token / *.tok               : raw token dumps ( bin/*-token scripts end in
#                                 "-token", not ".token", so they do NOT match ).
ARTIFACT_RE='(^|/)team\.json$|\.seed$|(^|/)pki/|(^|/)cp-endpoint\.json$|\.token$|\.tok$'
SECRET_KEY_RE='"(enroll_token|team_secret|team_key)"[[:space:]]*:'

# reads a newline-separated PATH LIST on stdin -> prints the offending paths.
artifact_hits() { grep -iE "$ARTIFACT_RE" || true; }
# $1 = a file -> prints its secret-key lines whose value is NOT a <placeholder>.
secret_value_hits() { grep -nIiE "$SECRET_KEY_RE" "$1" 2>/dev/null | grep -vE '"<[^"]*>"' || true; }
# counts non-empty lines (bash 3.2: `printf '%s\n' ""` emits ONE empty line, so a
# naive `wc -l` would report 1 for "nothing"). `grep -c .` counts only real lines.
count_lines() { printf '%s\n' "$1" | grep -c . || true; }

# ── Proof A — no runtime secret ARTIFACT is tracked ──────────────────────────
# ANTI-VACUOUS: a scan that examined ZERO tracked files reports the same "no hits"
# as a genuinely clean tree. That silent-green failure mode is the whole risk here
# (this gate runs from agent worktrees under .claude/worktrees/ as well as from the
# primary checkout), so the file count is asserted BEFORE the emptiness of HITS is
# read as good news. Same idea as SITE_FILES in test/truth-pass-claims.test.sh.
TRACKED="$(git ls-files)"
TRACKED_N="$(count_lines "$TRACKED")"
if [ "$TRACKED_N" -eq 0 ]; then
  bad "A: the tracked-file scan examined 0 files — this gate is INERT, not clean.
       (git ls-files returned nothing at $REPO; a 'clean' verdict here would be vacuous)"
else
  HITS="$(printf '%s\n' "$TRACKED" | artifact_hits)"
  if [ -z "$HITS" ]; then
    ok "A: no tracked runtime secret artifact in $TRACKED_N tracked files (team.json / *.seed / pki/ / cp-endpoint.json / *.token)"
  else
    bad "A: tracked SECRET ARTIFACT(S) found — remove + rotate before this ships public:"
    printf '       %s\n' $HITS
  fi
fi

# ── Proof B — committed config artifacts carry placeholders only ─────────────
# ANTI-VACUOUS: this proof is ABOUT the committed *.example config templates. If the
# tracked set is empty the loop body never runs and LEAKED stays "" — a PASS that
# examined nothing. Those templates are permanent by design (install-cp-endpoint.test.sh
# asserts .heimdall/cp-endpoint.json.example is NOT gitignored so it can land), so zero
# tracked config artifacts is a REGRESSION in this gate's subject, not a legitimate skip.
CONFIGS="$(printf '%s\n' "$TRACKED" | grep -iE '(cp-endpoint|team)\.json' || true)"
CONFIG_N="$(count_lines "$CONFIGS")"
if [ "$CONFIG_N" -eq 0 ]; then
  bad "B: ZERO tracked config artifacts to check — this proof examined nothing, so it proves nothing.
       Expected at least .heimdall/cp-endpoint.json.example (a committed template).
       If the templates were deliberately renamed, update this gate's pattern — do not let it idle green."
else
  LEAKED=""
  for f in $CONFIGS; do
    # a secret-key line whose value is NOT a <placeholder> is a real leak
    if [ -n "$(secret_value_hits "$f")" ]; then
      LEAKED="$LEAKED $f"
    fi
  done
  if [ -z "$LEAKED" ]; then
    ok "B: all $CONFIG_N committed config artifact(s) carry only <placeholder> secret values ($(printf '%s' "$CONFIGS" | tr '\n' ' '))"
  else
    bad "B: config artifact(s) carry a NON-placeholder secret value:"
    for f in $LEAKED; do
      secret_value_hits "$f"
      printf '       ^^ in %s\n' "$f"
    done
  fi
fi

# ── Proof C — FALSIFIABILITY: both detectors demonstrably CAN fire ───────────
# A/B only ever report "clean" on this repo. Without a measured delta, a detector
# that silently matches nothing (a broken regex, a filter that swallows every hit)
# would read as PASS forever. C plants the exact defects A and B exist to catch, in
# a throwaway fixture, and runs the SAME functions the real sweep uses.
FIX="$(mktemp -d -t pubreposecrets)"
trap 'rm -rf "$FIX"' EXIT

# C1 — the ARTIFACT detector: the legit names stay clean, the real artifacts are caught.
SAFE_PATHS='bin/heimdall-cp-token
docs/TOKEN-METRIC.md
.heimdall/cp-endpoint.json.example
.heimdall/team.json.example'
BAD_PATHS='.heimdall/team.json
home/.heimdall/pki/haid-abc.seed
secrets/prod.token'
SAFE_N="$(count_lines "$(printf '%s\n' "$SAFE_PATHS" | artifact_hits)")"
BAD_N="$(count_lines "$(printf '%s\n' "$BAD_PATHS" | artifact_hits)")"
printf "  \033[90mmeasured: safe_paths_flagged=%s bad_paths_flagged=%s (want 0 / 3)\033[0m\n" "$SAFE_N" "$BAD_N"
if [ "$SAFE_N" -eq 0 ] && [ "$BAD_N" -eq 3 ]; then
  ok "C1 the artifact detector flags team.json/*.seed/pki/*.token and NOT bin/*-token, TOKEN-METRIC.md, *.example"
else
  bad "C1 the artifact detector cannot discriminate (safe=$SAFE_N want 0, bad=$BAD_N want 3) — Proof A would never catch the real defect"
fi

# C2 — the SECRET-VALUE detector: a <placeholder> is clean, a real value is caught.
cat >"$FIX/placeholder.json" <<'JSON'
{ "cp_url": "https://example.invalid", "enroll_token": "<your-enroll-token>", "team_secret": "<team-secret>" }
JSON
# The "leaked" value must be NON-<placeholder> (so secret_value_hits fires) but
# must NOT be a gitleaks match: this detector keys off the JSON KEY NAME, not the
# value's entropy, so a high-entropy literal buys the proof nothing and costs the
# history a permanent generic-api-key finding. Convention case 1 (token-shaped
# input -> obviously-fake, non-matching sentinel):
# docs/superpowers/specs/heimdall-fixture-secret-convention.md
cat >"$FIX/leaked.json" <<'JSON'
{ "cp_url": "https://example.invalid", "enroll_token": "REDACTED_SENTINEL_not_a_real_token" }
JSON
PH_N="$(count_lines "$(secret_value_hits "$FIX/placeholder.json")")"
LK_N="$(count_lines "$(secret_value_hits "$FIX/leaked.json")")"
printf "  \033[90mmeasured: placeholder_flagged=%s leaked_flagged=%s delta=%s\033[0m\n" "$PH_N" "$LK_N" "$((LK_N - PH_N))"
if [ "$PH_N" -eq 0 ] && [ "$LK_N" -gt 0 ]; then
  ok "C2 the secret-value detector passes <placeholder> values and CATCHES a real one -> delta $((LK_N - PH_N))"
else
  bad "C2 NO measured delta (placeholder=$PH_N leaked=$LK_N) — Proof B is vacuous and proves nothing"
fi

echo
echo "  public-repo-no-secrets tests: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
