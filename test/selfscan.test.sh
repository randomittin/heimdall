#!/usr/bin/env bash
#
# selfscan.test.sh — scope + allowlist proofs for bin/heimdall-selfscan.
#
# heimdall-selfscan is the SHARED pre-push gate. It must police HEIMDALL's own
# history (secrets + identity allowlist + landmine lint) — and ONLY heimdall's.
# Two coupled defects this harness fences against:
#
#   BUG 1 — SCOPING. The gate is wired via core.hooksPath = a RELATIVE path, so
#   the native pre-push hook fires in EVERY repo that inherits that config. When
#   it fires while pushing an UNRELATED repo, the gate must NOT apply heimdall's
#   identity allowlist / secret rules to that foreign repo. It must detect that
#   it is not in the heimdall repo and stand down (exit 0) — the foreign repo's
#   own gates police the foreign repo.
#
#   BUG 2 — ALLOWLIST PARITY. heimdall ships its OWN secret-shaped detection
#   fixtures (the secret-scan corpus, the demo's runtime sk_live_, landmine test
#   strings). Bare `gitleaks detect` honors the repo's .gitleaks.toml allowlist
#   and reports those as 0 leaks. selfscan must scan the SAME way — honoring the
#   repo-top .gitleaks.toml — so the two AGREE. A config-blind selfscan reports
#   the fixtures as false-positive leaks and blocks every push.
#
# Four proofs, all runnable, none skippable:
#
#   A. PARITY — bare `gitleaks detect --log-opts=--all` over heimdall's history
#      and `heimdall-selfscan` AGREE: both exit 0 (clean). selfscan must not
#      invent findings bare gitleaks does not see.
#
#   B. SCOPING — run the gate from an UNRELATED throwaway repo (foreign author,
#      benign content). The gate must NOT block on heimdall's internals: it must
#      recognize it is not the heimdall repo and exit 0.
#
#   C. STILL-DETECTS — under the SHIPPED .gitleaks.toml (the exact config the
#      gate honors), prove BOTH halves of "the allowlist is a scalpel, not a
#      blanket": (i) the SAME secret committed to a NON-fixture path (src/) IS
#      flagged (detection intact, allowlist narrow), AND (ii) a committed COPY of
#      that secret in an allowlisted fixture path is NOT flagged (the allowlist
#      works). The secret must be one gitleaks' DEFAULT ruleset actually fires on:
#      note AWS's canonical doc key AKIA…EXAMPLE is excluded by gitleaks' OWN
#      built-in example filter regardless of config, so committing it proves
#      nothing about our allowlist. We use a live Stripe-shaped token (rule
#      stripe-access-token), assembled at runtime so this file carries no
#      contiguous literal.
#
#   D. ALLOWLIST-IS-NARROW — the shipped .gitleaks.toml must NOT globally disable
#      any rule; it may only allowlist by PATH/regex. A real secret in a
#      non-fixture path must still fire.
#
# Exit 0 = every proof holds. Nonzero = a proof failed (prints which).

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SELF_DIR/.." && pwd)"
SELFSCAN="$REPO/bin/heimdall-selfscan"

PASS=0; FAIL=0
ok()  { printf '  \033[32mPASS\033[0m %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAIL=$((FAIL + 1)); }

[ -x "$SELFSCAN" ] || { echo "FATAL: selfscan not executable at $SELFSCAN"; exit 2; }
command -v gitleaks >/dev/null 2>&1 || { echo "FATAL: gitleaks not installed — cannot prove parity"; exit 2; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# ─────────────────────────────────────────────────────────────────────────────
# A. PARITY — bare gitleaks history scan == selfscan, both clean.
# ─────────────────────────────────────────────────────────────────────────────
echo "A. PARITY (bare gitleaks history == selfscan):"
bare_rc=0
( cd "$REPO" && gitleaks detect --source . --log-opts="--all" --no-banner ) >/dev/null 2>&1 || bare_rc=$?
self_rc=0
( cd "$REPO" && "$SELFSCAN" ) >/dev/null 2>&1 || self_rc=$?
if [ "$bare_rc" -eq 0 ]; then
  ok "bare gitleaks over heimdall history is clean (rc=0)"
else
  bad "bare gitleaks over heimdall history is NOT clean (rc=$bare_rc) — history regression, fix that first"
fi
if [ "$self_rc" -eq 0 ]; then
  ok "selfscan over heimdall history is clean (rc=0)"
else
  bad "selfscan reports findings/identity/landmine bare gitleaks does not (rc=$self_rc)"
fi
if [ "$bare_rc" -eq "$self_rc" ]; then
  ok "bare gitleaks and selfscan AGREE (both rc=$self_rc)"
else
  bad "DISAGREEMENT — bare=$bare_rc selfscan=$self_rc (the 14-false-positive class)"
fi

# ─────────────────────────────────────────────────────────────────────────────
# B. SCOPING — gate run from an UNRELATED repo must stand down (exit 0).
# ─────────────────────────────────────────────────────────────────────────────
echo "B. SCOPING (foreign repo not blocked on heimdall internals):"
FOREIGN="$WORK/foreign"
mkdir -p "$FOREIGN"
(
  cd "$FOREIGN"
  git init -q
  git config user.email "someone@example.com"
  git config user.name "Some One"
  echo "hello world" > readme.txt
  git add readme.txt
  git commit -q -m "init unrelated repo"
)
foreign_rc=0
( cd "$FOREIGN" && "$SELFSCAN" ) >/dev/null 2>&1 || foreign_rc=$?
if [ "$foreign_rc" -eq 0 ]; then
  ok "gate stands down in an unrelated repo (rc=0) — does not apply heimdall's allowlist"
else
  bad "gate BLOCKED an unrelated repo (rc=$foreign_rc) — it scanned the wrong repo / applied heimdall rules"
fi

# ─────────────────────────────────────────────────────────────────────────────
# C. STILL-DETECTS — a real-shaped committed secret in the heimdall repo's scope
#    is still caught by the config-honoring history scan. We assemble the secret
#    at runtime (so this test file is not itself a literal) and commit it into a
#    clone of the repo top's scan, then prove gitleaks-with-config still fires.
# ─────────────────────────────────────────────────────────────────────────────
echo "C. STILL-DETECTS (allowlist does not weaken real detection):"
DETECT="$WORK/detect"
mkdir -p "$DETECT"
# Use the repo's own .gitleaks.toml so we test the EXACT config selfscan honors.
CFG="$REPO/.gitleaks.toml"
[ -f "$CFG" ] || { bad "C — .gitleaks.toml missing at repo top; selfscan has no allowlist to honor"; CFG=""; }
# A real-shaped Stripe live token (rule: stripe-access-token) — one gitleaks'
# DEFAULT ruleset actually fires on. Assembled from parts so this script carries
# no contiguous literal. (AWS's AKIA…EXAMPLE doc key is gitleaks-allowlisted by
# its own built-in example filter, so it can never prove our allowlist's narrowness.)
sk="sk_live_""4eC39HqLyjWDarjtT1zdp7dc"
# The non-fixture path the secret must STILL be caught in.
LEAK_PATH="src/leak.js"
# An allowlisted fixture path from the shipped .gitleaks.toml — a COPY of the
# same secret here must NOT be flagged (proves the allowlist actually allowlists).
FIXTURE_PATH="bin/heimdall-demo"
(
  cd "$DETECT"
  git init -q
  git config user.email "rj@runheimdall.dev"
  git config user.name "RJ"
  mkdir -p "$(dirname "$LEAK_PATH")" "$(dirname "$FIXTURE_PATH")"
  printf 'const key = "%s";\n' "$sk" > "$LEAK_PATH"
  printf 'demo_runtime_key="%s"\n' "$sk" > "$FIXTURE_PATH"
  git add -A
  git commit -q -m "real Stripe secret: one in src/ (must fire), one in an allowlisted fixture path (must not)"
)
if [ -n "$CFG" ]; then
  # Capture which files the SHIPPED config flags over committed history. Write the
  # JSON report to a real file (gitleaks' /dev/stdout report path is unreliable —
  # the findings can be swallowed), then read back the flagged File paths.
  RPT="$WORK/detect-report.json"
  ( cd "$DETECT" && gitleaks detect --source . --config "$CFG" --log-opts="--all" --no-banner --report-format json --report-path "$RPT" ) >/dev/null 2>&1
  FOUND_FILES="$( [ -f "$RPT" ] && cat "$RPT" || echo '[]' )"
  # (i) detection intact: the non-fixture src/ path MUST be flagged.
  if printf '%s' "$FOUND_FILES" | grep -Fq "$LEAK_PATH"; then
    ok "real Stripe secret in $LEAK_PATH still CAUGHT under heimdall's shipped config"
  else
    bad "real secret in $LEAK_PATH NOT caught — detection weakened / config too broad"
  fi
  # (ii) allowlist narrow + actually works: the SAME secret in the allowlisted
  # fixture path must NOT be flagged.
  if printf '%s' "$FOUND_FILES" | grep -Fq "$FIXTURE_PATH"; then
    bad "allowlisted fixture path $FIXTURE_PATH was FLAGGED — the path allowlist is not taking effect"
  else
    ok "identical secret in allowlisted $FIXTURE_PATH NOT flagged (allowlist works, scoped to the fixture)"
  fi
fi

# ─────────────────────────────────────────────────────────────────────────────
# D. ALLOWLIST-IS-NARROW — the shipped config must not nuke whole rules.
# ─────────────────────────────────────────────────────────────────────────────
echo "D. ALLOWLIST-IS-NARROW (no global rule disable):"
if [ -n "$CFG" ]; then
  # useDefault=true (or extend of default) keeps the full ruleset on. A config
  # that sets useDefault=false or strips rules to silence fixtures is a FAILURE.
  if grep -Eq 'useDefault[[:space:]]*=[[:space:]]*true' "$CFG"; then
    ok "config extends the DEFAULT ruleset (useDefault = true)"
  else
    bad "config does not extend the default ruleset — real detection may be disabled"
  fi
  if grep -Eq 'useDefault[[:space:]]*=[[:space:]]*false' "$CFG"; then
    bad "config sets useDefault = false — the full ruleset is OFF, real secrets slip"
  else
    ok "config does not turn the default ruleset off"
  fi
fi

echo ""
echo "selfscan.test.sh: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
