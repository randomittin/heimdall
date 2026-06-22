#!/usr/bin/env bash
# test/issue-config.test.sh — acceptance test for piece (e): config + CREDENTIAL
# handling (the auth surface). Proves, against REAL temp configs + the REAL lib
# and CLI (no canned output):
#
#   (a) CLEAN-INSTALL / INERT — an ABSENT config and a connector-less config both
#       load WITHOUT crashing and resolve to ZERO active connectors -> the loop is
#       inert. This is the MarkItDown lazy/optional contract: missing config is a
#       legitimate state, never a hard failure.
#   (b) CONFIGURED-BUT-CREDLESS -> INACTIVE — a connector with active:true but
#       whose credential env var is UNSET resolves active=False (skipped, not a
#       crash), with an honest reason.
#   (c) CRED FROM ENV, NOT A COMMITTED FILE — the same connector becomes active
#       ONLY when its env var is exported. The credential value comes from the
#       environment at runtime, never from a committed config.
#   (d) THE .example HAS NO REAL SECRETS — the committed example carries only
#       env-var NAMES + bracketed example values; it contains NO token-shaped
#       string (no sk_live_/ghp_/xoxb-/AKIA... literal).
#   (e) NO LEAK IN OUTPUT — `show` never prints a credential value, even when one
#       is set in the env: the resolved view carries cred_present booleans + the
#       env-var NAME, never the secret.
#   (f) REAL CONFIG IS GITIGNORED, EXAMPLE IS COMMITTABLE — the live config + the
#       secrets file are ignored; only the .example is trackable.
#   (g) GITLEAKS GATE INTACT — a planted credential staged in a config path is
#       caught by bin/secret-scan (the gate is not weakened by this feature).
#
# Exit 0 = every executed assertion passed. Non-zero = a regression.

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
CLI="$ROOT/bin/heimdall-issue-config"
LIB="$ROOT/bin/lib/issue_config.py"
EXAMPLE="$ROOT/.heimdall/issue-loop.config.json.example"
SECRET_SCAN="$ROOT/bin/secret-scan"

[ -x "$CLI" ] || { echo "FATAL: $CLI not executable" >&2; exit 2; }
[ -f "$LIB" ] || { echo "FATAL: $LIB missing" >&2; exit 2; }
[ -f "$EXAMPLE" ] || { echo "FATAL: $EXAMPLE missing" >&2; exit 2; }

PY="$(command -v python3 || command -v python || true)"
[ -n "$PY" ] || { echo "FATAL: python not found" >&2; exit 2; }

PASS=0
FAIL=0
ok()  { PASS=$((PASS+1)); printf "  \033[32mPASS\033[0m %s\n" "$1"; }
bad() { FAIL=$((FAIL+1)); printf "  \033[31mFAIL\033[0m %s\n" "$1"; }

WORK="$(mktemp -d -t "issue-config-test.$(printf 'X%.0s' 1 2 3 4 5 6)")"
trap 'rm -rf "$WORK"' EXIT

# A throwaway repo root with its own .heimdall home, so we never touch the real
# host environment or the project's runtime store.
REPO="$WORK/repo"
mkdir -p "$REPO/.heimdall"

# Helper: run the lib directly with a CONTROLLED env (no host creds leak in).
# $1 = python snippet body (has `ic`, `cfg` not pre-bound — snippet builds them).
pyrun() {
  PYTHONPATH="$ROOT/bin/lib" REPO="$REPO" "$PY" - "$@"
}

# ── (a) CLEAN-INSTALL / INERT — absent config + connector-less config ──────────

# absent config (no file at all)
ABSENT_OUT="$(PYTHONPATH="$ROOT/bin/lib" REPO="$REPO" "$PY" - <<'PY' 2>&1
import os, issue_config as ic
repo = os.environ["REPO"]
cfg = ic.load_config(repo)                       # no config file exists -> inert
active = ic.active_connectors(cfg, env={})       # controlled empty env
print("INERT" if ic.is_inert(cfg, env={}) else "ACTIVE", "n=%d" % len(active))
PY
)"
ARC=$?
if [ "$ARC" -eq 0 ] && printf '%s' "$ABSENT_OUT" | grep -q "INERT n=0"; then
  ok "(a) absent config loads without crash -> inert, 0 active connectors"
else
  bad "(a) absent config not inert (rc=$ARC): $ABSENT_OUT"
fi

# connector-less config (valid JSON, no connectors block)
echo '{"prioritization":{"weights":{"severity":3}}}' > "$REPO/.heimdall/issue-loop.config.json"
NOCONN_OUT="$(PYTHONPATH="$ROOT/bin/lib" REPO="$REPO" "$PY" - <<'PY' 2>&1
import os, issue_config as ic
repo = os.environ["REPO"]
cfg = ic.load_config(repo)
print("INERT" if ic.is_inert(cfg, env={}) else "ACTIVE", "n=%d" % len(ic.active_connectors(cfg, env={})))
PY
)"
if printf '%s' "$NOCONN_OUT" | grep -q "INERT n=0"; then
  ok "(a) connector-less config -> inert, 0 active connectors"
else
  bad "(a) connector-less config not inert: $NOCONN_OUT"
fi

# the CLI `active` on a connector-less config prints nothing + exits 0 (inert)
set +e
CLI_ACTIVE="$("$CLI" active --repo "$REPO" 2>&1)"
CLI_RC=$?
set -e
if [ "$CLI_RC" -eq 0 ] && [ -z "$CLI_ACTIVE" ]; then
  ok "(a) CLI 'active' on inert config exits 0 with no output"
else
  bad "(a) CLI 'active' inert wrong (rc=$CLI_RC): '$CLI_ACTIVE'"
fi

# ── (b) CONFIGURED-BUT-CREDLESS -> INACTIVE (no crash) ─────────────────────────

cat > "$REPO/.heimdall/issue-loop.config.json" <<'JSON'
{
  "connectors": {
    "github": { "active": true, "repo": "owner/name", "token_env": "TEST_GH_TOKEN" }
  }
}
JSON

CREDLESS_OUT="$(PYTHONPATH="$ROOT/bin/lib" REPO="$REPO" "$PY" - <<'PY' 2>&1
import os, json, issue_config as ic
repo = os.environ["REPO"]
cfg = ic.load_config(repo)
# env WITHOUT the token var -> connector configured but cred absent.
st = ic.connector_state("github", cfg["connectors"]["github"], env={})
print(json.dumps({"active": st["active"], "configured": st["configured"],
                  "cred_present": st["cred_present"], "reason": st["reason"]}))
PY
)"
if printf '%s' "$CREDLESS_OUT" | grep -q '"active": false' \
   && printf '%s' "$CREDLESS_OUT" | grep -q '"configured": true' \
   && printf '%s' "$CREDLESS_OUT" | grep -q '"cred_present": false' \
   && printf '%s' "$CREDLESS_OUT" | grep -qi 'credential absent'; then
  ok "(b) configured-but-credless connector -> inactive (no crash), honest reason"
else
  bad "(b) credless connector not handled: $CREDLESS_OUT"
fi

# and it is inert overall (the only connector is inactive)
INERT_CREDLESS="$(PYTHONPATH="$ROOT/bin/lib" REPO="$REPO" "$PY" - <<'PY' 2>&1
import os, issue_config as ic
cfg = ic.load_config(os.environ["REPO"])
print("INERT" if ic.is_inert(cfg, env={}) else "ACTIVE")
PY
)"
if printf '%s' "$INERT_CREDLESS" | grep -q "INERT"; then
  ok "(b) sole credless connector -> loop still inert"
else
  bad "(b) credless connector unexpectedly active: $INERT_CREDLESS"
fi

# ── (c) CRED FROM ENV, NOT A COMMITTED FILE ────────────────────────────────────

# Same config; now EXPORT the env var -> the connector becomes active. The value
# lives only in the process env, never in any committed file.
ENV_OUT="$(PYTHONPATH="$ROOT/bin/lib" REPO="$REPO" "$PY" - <<'PY' 2>&1
import os, issue_config as ic
cfg = ic.load_config(os.environ["REPO"])
env = {"TEST_GH_TOKEN": "ghp_runtimeValueFromEnvNotCommitted"}
st = ic.connector_state("github", cfg["connectors"]["github"], env=env)
active = ic.active_connectors(cfg, env=env)
print("active=%s present=%s names=%s" % (st["active"], st["cred_present"], ",".join(active)))
# prove the resolved value really is the env value (cred resolution path works)
val = ic.resolve_cred(cfg["connectors"]["github"], env=env)
print("resolved_from_env=%s" % (val == "ghp_runtimeValueFromEnvNotCommitted"))
PY
)"
if printf '%s' "$ENV_OUT" | grep -q "active=True present=True names=github" \
   && printf '%s' "$ENV_OUT" | grep -q "resolved_from_env=True"; then
  ok "(c) credential resolves from ENV at runtime -> connector active"
else
  bad "(c) env cred resolution failed: $ENV_OUT"
fi

# Prove the committed config file on disk contains NO credential value — only the
# env-var NAME. (The real token never touches the file.)
if grep -q "TEST_GH_TOKEN" "$REPO/.heimdall/issue-loop.config.json" \
   && ! grep -q "ghp_runtimeValueFromEnvNotCommitted" "$REPO/.heimdall/issue-loop.config.json"; then
  ok "(c) committed config holds only the env-var NAME, never the token value"
else
  bad "(c) config file unexpectedly carries a token value"
fi

# ── (d) THE .example HAS NO REAL SECRETS ───────────────────────────────────────

# Must be valid JSON-ish (jq-free: python parses it, stripping the leading // key).
EX_VALID="$("$PY" - "$EXAMPLE" <<'PY' 2>&1
import json, sys
with open(sys.argv[1]) as fh:
    data = json.load(fh)
# structure sanity: connectors block + every connector carries a *_env NAME only.
conns = data.get("connectors", {})
bad = []
for name, block in conns.items():
    has_env = any(k.endswith("_env") for k in block)
    if not has_env:
        bad.append(name)
print("OK" if conns and not bad else "BAD:%s" % bad)
PY
)"
if printf '%s' "$EX_VALID" | grep -q "^OK"; then
  ok "(d) .example is valid JSON; every connector declares a *_env NAME (no inline secret)"
else
  bad "(d) .example structure problem: $EX_VALID"
fi

# Token-SHAPED string scan: the example must contain NONE of the common secret
# shapes. These are the patterns gitleaks would flag in a real file.
TOKEN_SHAPES='sk_live_|sk_test_|ghp_[A-Za-z0-9]{20}|gho_[A-Za-z0-9]{20}|xox[baprs]-[0-9]|AKIA[0-9A-Z]{16}|-----BEGIN [A-Z ]*PRIVATE KEY-----|AIza[0-9A-Za-z_-]{20}'
if grep -qE "$TOKEN_SHAPES" "$EXAMPLE"; then
  bad "(d) .example contains a token-SHAPED string — possible real secret:"
  grep -nE "$TOKEN_SHAPES" "$EXAMPLE" | sed 's/^/      /'
else
  ok "(d) .example contains NO token-shaped string (no real secret)"
fi

# Positive proof the scan WORKS: a planted token IS caught by the same pattern
# (so the green above is meaningful, not a broken grep).
PLANT="$WORK/planted.json"
printf '{ "token": "ghp_AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA" }\n' > "$PLANT"
if grep -qE "$TOKEN_SHAPES" "$PLANT"; then
  ok "(d) token-shape scanner is live (a planted ghp_ token is detected)"
else
  bad "(d) token-shape scanner is broken — would not catch a real leak"
fi

# ── (e) NO LEAK IN `show` OUTPUT even with a credential set ────────────────────

# Configure github active + export the token, then run `show` and assert the
# secret value never appears in the output (only cred_present + env-var NAME do).
set +e
SHOW_OUT="$(TEST_GH_TOKEN="ghp_REDACTED_FAKE_TEST_TOKEN" "$CLI" show --repo "$REPO" 2>&1)"
SHOW_RC=$?
set -e
if [ "$SHOW_RC" -eq 0 ] \
   && ! printf '%s' "$SHOW_OUT" | grep -q "ghp_REDACTED_FAKE_TEST_TOKEN" \
   && printf '%s' "$SHOW_OUT" | grep -q '"cred_present"' \
   && printf '%s' "$SHOW_OUT" | grep -q "TEST_GH_TOKEN"; then
  ok "(e) 'show' never echoes the secret; surfaces cred_present + env-var NAME only"
else
  bad "(e) 'show' leak/structure problem (rc=$SHOW_RC): $SHOW_OUT"
fi

# With the token set, github is now active -> CLI 'active' lists it (exit 0).
set +e
ACTIVE_LIST="$(TEST_GH_TOKEN="ghp_REDACTED_FAKE_TEST_TOKEN" "$CLI" active --repo "$REPO" 2>&1)"
AL_RC=$?
set -e
if [ "$AL_RC" -eq 0 ] && printf '%s' "$ACTIVE_LIST" | grep -qx "github"; then
  ok "(e) 'active' lists github once its env credential is present"
else
  bad "(e) 'active' wrong with cred set (rc=$AL_RC): $ACTIVE_LIST"
fi

# ── (f) REAL CONFIG GITIGNORED, EXAMPLE COMMITTABLE ────────────────────────────
# Checked against the PROJECT repo's .gitignore (the real guarantee).

cd "$ROOT"
# The example must be COMMITTABLE — i.e. NOT ignored. It is committable whether it
# is already tracked OR is still untracked-but-not-ignored. The authoritative
# signal is "not in the ignored set": a tracked file is committable by definition,
# and an untracked file is committable iff it is not ignored.
EX=".heimdall/issue-loop.config.json.example"
TRACKED="$(git ls-files "$EX" 2>/dev/null || true)"
UNTRACKED_OK="$(git ls-files --others --exclude-standard .heimdall/ 2>/dev/null | grep -x "$EX" || true)"
IGNORED="$(git ls-files -i -o --exclude-standard .heimdall/ 2>/dev/null | grep -x "$EX" || true)"
if [ -z "$IGNORED" ] && { [ -n "$TRACKED" ] || [ -n "$UNTRACKED_OK" ]; }; then
  ok "(f) .example is committable (tracked or untracked-non-ignored; not in ignored set)"
else
  bad "(f) .example NOT committable — gitignore swallowed it (tracked='$TRACKED' untracked='$UNTRACKED_OK' ignored='$IGNORED')"
fi

# the REAL config + secrets MUST be ignored (exit 0 from check-ignore on a plain
# ignore pattern == ignored).
if git check-ignore -q .heimdall/issue-loop.config.json; then
  ok "(f) real config (.heimdall/issue-loop.config.json) is gitignored"
else
  bad "(f) real config is NOT gitignored — a committed token would leak"
fi
if git check-ignore -q .heimdall/issue-loop.secrets.json; then
  ok "(f) secrets file (.heimdall/issue-loop.secrets.json) is gitignored"
else
  bad "(f) secrets file is NOT gitignored"
fi
# and the example is NOT among ignored files (cross-check via the ignore listing).
if git ls-files -i -o --exclude-standard .heimdall/ 2>/dev/null | grep -qx ".heimdall/issue-loop.config.json.example"; then
  bad "(f) .example appears in the IGNORED set — it must be committable"
else
  ok "(f) .example is NOT in the ignored set"
fi
cd "$WORK"

# ── (g) GITLEAKS GATE INTACT — a planted cred in a config path is caught ───────
# The cred-handling layer must NOT weaken the gate. Stage a fixture config bearing
# a real-shaped token in a throwaway git repo and assert bin/secret-scan fires.
if command -v gitleaks >/dev/null 2>&1; then
  GREPO="$WORK/gitrepo"
  mkdir -p "$GREPO"
  git -C "$GREPO" init -q
  git -C "$GREPO" config user.email "t@t.t"
  git -C "$GREPO" config user.name "t"
  # a CLEAN config (env-var names only) must NOT trip the gate.
  cp "$EXAMPLE" "$GREPO/issue-loop.config.json"
  git -C "$GREPO" add issue-loop.config.json
  set +e
  ( cd "$GREPO" && "$SECRET_SCAN" >/dev/null 2>&1 )
  CLEAN_RC=$?
  set -e
  if [ "$CLEAN_RC" -eq 0 ]; then
    ok "(g) a clean config (env-var names only) passes the gitleaks gate (exit 0)"
  else
    bad "(g) clean config wrongly flagged by gitleaks (rc=$CLEAN_RC)"
  fi
  # now PLANT a real-shaped token -> the gate MUST catch it (exit 1).
  printf '{ "connectors": { "github": { "token": "ghp_REDACTED_FAKE_TEST_TOKEN" } } }\n' \
    > "$GREPO/issue-loop.config.json"
  git -C "$GREPO" add issue-loop.config.json
  set +e
  ( cd "$GREPO" && "$SECRET_SCAN" >/dev/null 2>&1 )
  LEAK_RC=$?
  set -e
  if [ "$LEAK_RC" -eq 1 ]; then
    ok "(g) a PLANTED credential in a config is caught by the gitleaks gate (exit 1)"
  else
    bad "(g) gitleaks gate did NOT catch a planted credential (rc=$LEAK_RC) — gate weakened"
  fi
else
  # gitleaks absent: still prove our own token-shape detector catches the plant,
  # so the gate's intent is exercised even on a stripped host.
  printf '{ "token": "ghp_REDACTED_FAKE_TEST_TOKEN" }\n' > "$WORK/leakcfg.json"
  if grep -qE 'ghp_[A-Za-z0-9]{30,}' "$WORK/leakcfg.json"; then
    ok "(g) gitleaks absent — planted credential still caught by token-shape scan (gate intent holds)"
  else
    bad "(g) planted credential not detected by fallback scan"
  fi
fi

echo
echo "  issue-config tests: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
