#!/usr/bin/env bash
#
# install-cp-endpoint.test.sh — acceptance harness for install.sh's per-dev
# control-plane endpoint step (zero-touch team-presence enrollment).
#
# Proves the four guarantees a real team install depends on:
#
#   1. ENV-DRIVEN WRITE — a scripted install with HEIMDALL_CP_URL +
#      HEIMDALL_ENROLL_TOKEN writes $HOME/.heimdall/cp-endpoint.json with BOTH
#      values, mode 0600, inside a 0700 .heimdall, beside a 0700 pki/ seed dir.
#   2. NON-INTERACTIVE CLEAN SKIP — with NO env and stdin not a TTY (curl|bash /
#      CI), install NEVER hangs, writes no config, and exits 0 with guidance.
#   3. NO SECRET LEAK — the enroll token never appears in any tracked file (it
#      lives 0600 in $HOME only); the committed .example carries shape, not a token.
#   4. NO GCLOUD — install.sh never shells out to gcloud / Secret Manager; the URL
#      comes from the installing env or a prompt, never a cloud-creds path.
#
# Usage:  test/install-cp-endpoint.test.sh
# Exit 0 = all guarantees hold. Non-zero = a guarantee regressed (prints which).
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SELF_DIR/.." && pwd)"
REF="$(git -C "$REPO" rev-parse HEAD)"

# A unique, obviously-fake token so the "no leak" grep is meaningful — it must
# never appear in the repo tree, only in the throwaway $HOME under test.
CP_URL="https://heimdall-cp-test.example.run.app"
CP_TOKEN="TESTENROLLTOKEN-deadbeef-NEVER-COMMIT-0xCAFEBABE"

PASS=0; FAIL=0
ok()  { printf '  \033[32mPASS\033[0m %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAIL=$((FAIL+1)); }

# ── Fake `claude`: satisfy install's preflight + plugin steps with no network ──
FAKE_DIR="$(mktemp -d)"
cat > "$FAKE_DIR/claude" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
  --version) echo "1.5.0 (Claude Code)"; exit 0 ;;
  plugins)   exit 0 ;;
  *)         exit 0 ;;
esac
EOF
chmod +x "$FAKE_DIR/claude"

TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$FAKE_DIR" "$TMP_ROOT"' EXIT

# Owner perm bits of a path, portable across macOS (stat -f) and Linux (stat -c).
mode_of() { stat -f '%Lp' "$1" 2>/dev/null || stat -c '%a' "$1" 2>/dev/null; }

# Run install.sh from THIS working tree (the installer under test) against a fresh
# HOME, with a fake claude on PATH and the real environment's secrets unset so the
# run can never touch the developer's real ~/.claude or CP config. stdin is /dev/null
# so the TTY-gated prompt path is NOT taken (mirrors curl|bash / CI).
run_install() { # $1=HOME  $2=CP_URL (may be empty)  $3=CP_TOKEN (may be empty)
  env -u CLAUDE_CONFIG_DIR -u HEIMDALL_HOME -u HEIMDALL_FORCE \
      -u HEIMDALL_CP_PKI_KEY -u PKI_SEED -u BASE_URL \
      HOME="$1" TERM="dumb" HEIMDALL_NO_COLOR=1 \
      HEIMDALL_REPO="$REPO" HEIMDALL_REF="$REF" \
      HEIMDALL_CP_URL="$2" HEIMDALL_ENROLL_TOKEN="$3" \
      PATH="$FAKE_DIR:$PATH" \
      bash "$REPO/install.sh" </dev/null 2>&1
}

# Run a command with a hard wall-clock cap; return 124 if it had to be killed (hung).
run_capped() { # $1=secs  $2=outfile  rest=cmd…
  local secs="$1" out="$2"; shift 2
  "$@" > "$out" 2>&1 &
  local pid=$! i=0
  while kill -0 "$pid" 2>/dev/null; do
    sleep 1; i=$((i+1))
    if [ "$i" -ge "$secs" ]; then
      kill -9 "$pid" 2>/dev/null; wait "$pid" 2>/dev/null; return 124
    fi
  done
  wait "$pid"; return $?
}

echo "install-cp-endpoint harness  repo=$REPO  ref=${REF:0:12}"
echo "--------------------------------------------------------------------"

# ── (4) NO GCLOUD (static — independent of any install run) ────────────────────
# Strip full-line comments first: the constraint bars an actual gcloud INVOCATION,
# not the word appearing in a "no gcloud" note in the header.
if grep -vE '^[[:space:]]*#' "$REPO/install.sh" | grep -q 'gcloud'; then
  bad "install.sh invokes gcloud — the URL must come from env/prompt, never a cloud-creds path"
else
  ok  "install.sh never calls gcloud (URL is env/prompt-supplied)"
fi

# ── gitignore correctness: the real config + seeds are ignored, the .example is NOT
( cd "$REPO"
  # Probe concrete file paths (a trailing-slash dir pattern like /pki/ only matches
  # an existing directory, so test a seed file INSIDE pki/, not the bare name).
  for p in cp-endpoint.json identity.json pki/dev.seed .heimdall/cp-endpoint.json .heimdall/pki/dev.seed; do
    if git check-ignore -q "$p"; then :; else echo "LEAK:$p"; fi
  done
  # The committed template MUST be track-able (un-ignored by the ! exception).
  if git check-ignore -q ".heimdall/cp-endpoint.json.example"; then echo "BLOCKED:example"; fi
) > "$TMP_ROOT/ignore.out" 2>/dev/null
if grep -q '^LEAK:' "$TMP_ROOT/ignore.out"; then
  bad "a real CP secret path is NOT gitignored: $(grep '^LEAK:' "$TMP_ROOT/ignore.out" | tr '\n' ' ')"
elif grep -q '^BLOCKED:example' "$TMP_ROOT/ignore.out"; then
  bad ".heimdall/cp-endpoint.json.example is gitignored — the committed template can never land"
else
  ok  "gitignore: real config + pki seeds ignored; .example template committable"
fi

# ── (1) ENV-DRIVEN WRITE ───────────────────────────────────────────────────────
H1="$TMP_ROOT/home-env"; mkdir -p "$H1"
run_install "$H1" "$CP_URL" "$CP_TOKEN" > "$TMP_ROOT/env.out" 2>&1
CFG="$H1/.heimdall/cp-endpoint.json"
if [ -f "$CFG" ]; then
  GOT="$(HMD_F="$CFG" python3 - <<'PY' 2>/dev/null
import json, os
d = json.load(open(os.environ["HMD_F"]))
print("%s\t%s" % (d.get("url",""), d.get("enroll_token","")))
PY
)"
  GOT_URL="${GOT%%	*}"; GOT_TOK="${GOT##*	}"
  if [ "$GOT_URL" = "$CP_URL" ] && [ "$GOT_TOK" = "$CP_TOKEN" ]; then
    ok "env install wrote cp-endpoint.json with url + enroll_token"
  else
    bad "cp-endpoint.json contents wrong — url='$GOT_URL' token-match=$([ "$GOT_TOK" = "$CP_TOKEN" ] && echo yes || echo no)"
  fi
  M="$(mode_of "$CFG")"
  [ "$M" = "600" ] && ok "cp-endpoint.json is mode 0600" || bad "cp-endpoint.json mode is $M, want 600"
else
  bad "env install did NOT write $CFG"
fi
HD_M="$(mode_of "$H1/.heimdall")"
[ "$HD_M" = "700" ] && ok ".heimdall dir is mode 0700" || bad ".heimdall dir mode is $HD_M, want 700"
if [ -d "$H1/.heimdall/pki" ]; then
  PKI_M="$(mode_of "$H1/.heimdall/pki")"
  [ "$PKI_M" = "700" ] && ok "pki/ seed dir is mode 0700" || bad "pki/ mode is $PKI_M, want 700"
else
  bad "pki/ seed dir was not created"
fi

# ── (2) NON-INTERACTIVE CLEAN SKIP (no env, stdin not a TTY, must not hang) ─────
H2="$TMP_ROOT/home-noenv"; mkdir -p "$H2"
run_capped 90 "$TMP_ROOT/noenv.out" run_install "$H2" "" ""
RC=$?
if [ "$RC" -eq 124 ]; then
  bad "non-interactive install HUNG (no env, stdin /dev/null) — killed after 90s"
elif [ "$RC" -ne 0 ]; then
  bad "non-interactive install exited $RC (want 0 — a missing CP endpoint is a clean skip)"
elif [ -f "$H2/.heimdall/cp-endpoint.json" ]; then
  bad "non-interactive install wrote a cp-endpoint.json with no values supplied"
else
  ok "non-interactive install: no hang, no config written, exit 0"
fi
if grep -qi 'control-plane endpoint' "$TMP_ROOT/noenv.out" \
   && grep -qi 'presence stays offline\|HEIMDALL_ENROLL_TOKEN' "$TMP_ROOT/noenv.out"; then
  ok "skip path prints how-to-configure guidance"
else
  bad "skip path did not print configuration guidance"
fi

# ── (3) NO SECRET LEAK — the token must appear in NO tracked file, NO .example ──
# Exclude THIS test's own file: CP_TOKEN is an obviously-fake fixture literal defined
# here; the assertion is that install/.example/cp-endpoint.json never carry it, not that
# the test fixture can't name its own value. (secret-scan stays clean — it's not real.)
SELF="test/install-cp-endpoint.test.sh"
LEAK_TRACKED="$(cd "$REPO" && git grep -lF "$CP_TOKEN" -- $(git ls-files) 2>/dev/null | grep -vxF "$SELF")"
LEAK_EXAMPLE="$(grep -lF "$CP_TOKEN" "$REPO/.heimdall/cp-endpoint.json.example" 2>/dev/null || true)"
# Generic guard: the example must not carry anything that smells like a real token
# (a long opaque alnum run) — only the bracketed example shape.
if [ -n "$LEAK_TRACKED" ] || [ -n "$LEAK_EXAMPLE" ]; then
  bad "enroll token leaked into a tracked/committed file: $LEAK_TRACKED $LEAK_EXAMPLE"
elif grep -Eq '"enroll_token"[[:space:]]*:[[:space:]]*"[A-Za-z0-9+/_-]{20,}"' "$REPO/.heimdall/cp-endpoint.json.example"; then
  bad ".heimdall/cp-endpoint.json.example carries a real-looking enroll_token value"
else
  ok "enroll token never appears in any tracked file; .example is example-only"
fi

# ── Tally ──────────────────────────────────────────────────────────────────────
echo "--------------------------------------------------------------------"
echo "  $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
