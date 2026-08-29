#!/usr/bin/env bash
#
# paste-secret-filter.test.sh — pins bin/heimdall-secret-filter.
#
# WHAT THIS GUARDS
# A pasted credential must never reach the model. Because no Claude Code hook can
# rewrite prompt text (measured, see docs/secret-paste-filter.md), the only
# mechanism available is refusal — so the guarantees worth pinning are:
#   1. every credential shape we claim to detect IS detected,
#   2. ordinary code and prose do NOT trip it,
#   3. the vault is 0600 and gitignored,
#   4. no secret value ever reaches stdout, stderr, or any file but the vault,
#   5. the cheap pre-filter is a strict SUPERSET of the classifier.
#
# (2) matters more than (1). A detector that fires on ordinary code gets switched
# off by its user, and then it protects nothing at all. The false-positive suite
# is therefore the large one, and it is drawn from real code shapes: base64 image
# blobs, UUIDs, git SHAs, hex digests, env-var references, function calls,
# placeholders and prose.
#
# FALSIFIABILITY
# Assertions that cannot fail prove nothing, so this suite runs itself against
# two deliberately broken detectors and requires both to be caught:
#   RED-PROOF 1  a no-op detector (detect() -> []) must break the positive suite.
#   RED-PROOF 2  a plain-entropy detector (any 16+ char token over 3.5 bits/char,
#                no key name required, no exclusions) must break the FP suite.
# If either mutant survives, the corresponding assertions are decorative and this
# suite fails.
#
# HERMETIC. $TMPDIR only. Every credential fixture is FAKE and is assembled at
# runtime from a prefix plus a body, so no complete credential-shaped literal
# exists in this file — otherwise the repo's own gitleaks pre-commit gate would,
# correctly, refuse to commit a test suite full of key-shaped strings.
#
# Usage: test/paste-secret-filter.test.sh   (exit 0 = all guarantees hold)
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SELF_DIR/.." && pwd)"
FILTER="$REPO/bin/heimdall-secret-filter"
LIB="$REPO/bin/lib/paste_secret_filter.py"

PASS=0; FAIL=0
ok()  { printf '  \033[32mPASS\033[0m %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAIL=$((FAIL+1)); }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
VAULT_DIR="$TMP/vault"; mkdir -p "$VAULT_DIR"

echo "paste-secret-filter harness  repo=$REPO"
echo "--------------------------------------------------------------------"

if ! command -v python3 >/dev/null 2>&1; then
  printf '  \033[31mFAIL\033[0m python3 is required to run this suite\n'
  printf 'RESULT: 0 passed, 1 failed\n'
  exit 1
fi

[ -x "$FILTER" ] && ok "bin/heimdall-secret-filter is executable" \
  || bad "bin/heimdall-secret-filter missing or not executable"

# ── FAKE fixtures, assembled at runtime ─────────────────────────────────────
# Split so that neither half matches a credential regex on its own.
P_SK='sk-'; P_GH='gh'; P_GHP='git'; P_AK='AK'; P_AI='AI'; P_XO='xo'; P_EY='ey'
F_ANTHROPIC="${P_SK}ant-api03-QQvbPtRk7wLmXn2yZa8FcJdE4hUgS1oI9pTrNbVxKwMyAeCzDfGhJkLnPqRsTuVwXyZaBcDeFgHiJkLmNoPq"
F_OPENAI_PROJ="${P_SK}proj-7fKq2mWzXcVbNjHgTrEdYuIoPaSdFgHjKlZxCvBnMq"
F_OPENAI_BARE="${P_SK}7fKq2mWzXcVbNjHgTrEdYuIoPaSdFgHjKlZxCvBn"
F_GITHUB="${P_GH}p_A1b2C3d4E5f6G7h8I9j0K1l2M3n4O5p6Q7r8"
F_GITHUB_PAT="${P_GHP}hub_pat_11ABCDE0zQwErTyUiOpAsDfGhJkLzXcVbNm1234567890qwertyuiopasdfghjklzxcvb"
F_AWS_ID="${P_AK}IA3TZ7QW9LMNBVCXZQ"
F_GOOGLE="${P_AI}zaSyC8kFq2mWzXcVbNjHgTrEdYuIoPaSdFgHj"
F_SLACK="${P_XO}xb-2837465192-8374651920-QwErTyUiOpAsDfGhJkLzXc"
F_JWT="${P_EY}JhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.${P_EY}JzdWIiOiIxMjM0NTY3ODkwIiwibmFtZSI6IkZBS0UifQ.QWERTYuiopASDFGHjklZXCVBNm"
F_PEM="$(printf -- '-----BEGIN RSA PRIVATE KEY-----\nMIIBOgIBAAJBAKj34GkxFhD90vcNLYLInFEX6Ppy1tPf9Cnzj4p4WGeKLs1Pt8Qu\nKUpRKfFLfRYC9AIKjbJTWit+CqvjWYzvQwECAwEAAQJAIJLixBy2qpFoS4DSmoEm\n-----END RSA PRIVATE KEY-----\n')"
F_AWS_SECRET='wJalrXUtnFEMI/K7MDENG/bPxRfiCYzQ8kLmNpVx'
F_DB_PASS='Xk9mPq2wLz7vNb4tRc8yHj3s'

scan_shapes() { # stdin = text -> shapes found, one per line
  HEIMDALL_HOME="$VAULT_DIR" python3 "$LIB" scan 2>/dev/null | cut -f1
}

expect_detect() { # label, expected-shape, text
  local got
  got="$(printf '%s' "$3" | scan_shapes | sort -u | tr '\n' ' ')"
  case " $got " in
    *" $2 "*) ok "detects $2 — $1" ;;
    *)        bad "MISSED $2 — $1 (fired: '${got:-nothing}')" ;;
  esac
}

expect_clean() { # label, text
  local got
  got="$(printf '%s' "$2" | scan_shapes | sort -u | tr '\n' ' ')"
  if [ -z "${got// /}" ]; then ok "no false positive — $1"
  else bad "FALSE POSITIVE — $1 (fired: $got)"; fi
}

# ── 1. EVERY CLAIMED SHAPE IS DETECTED ──
echo ""
echo "[1] credential shapes are detected"
expect_detect "anthropic key"      anthropic-api-key  "here is my key $F_ANTHROPIC ok?"
expect_detect "openai project key" openai-api-key     "OPENAI: $F_OPENAI_PROJ"
expect_detect "openai bare key"    openai-api-key     "use $F_OPENAI_BARE please"
expect_detect "github token"       github-token       "token is $F_GITHUB"
expect_detect "github fine-grained pat" github-pat    "pat: $F_GITHUB_PAT"
expect_detect "aws access key id"  aws-access-key-id  "aws id $F_AWS_ID"
expect_detect "google api key"     google-api-key     "maps key $F_GOOGLE"
expect_detect "slack token"        slack-token        "slack $F_SLACK"
expect_detect "jwt"                jwt                "Authorization: Bearer $F_JWT"
expect_detect "pem private key"    private-key-pem    "$F_PEM"
expect_detect "aws secret via assignment" generic-assignment "AWS_SECRET_ACCESS_KEY=$F_AWS_SECRET"
expect_detect "db password via assignment" generic-assignment "DATABASE_PASSWORD=\"$F_DB_PASS\""
expect_detect "key inside a larger paste" anthropic-api-key \
  "$(printf 'def main():\n    client = Anthropic(api_key="%s")\n    return client\n' "$F_ANTHROPIC")"

# ── 2. FALSE-POSITIVE SUITE (the one that matters) ──
echo ""
echo "[2] ordinary code and prose do not trip it"
expect_clean "base64 png data-uri" \
  '<img src="data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==" alt="dot" />'
expect_clean "bare long base64 blob" \
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg=='
expect_clean "uuid assigned to an id" 'const requestId = "550e8400-e29b-41d4-a716-446655440000";'
expect_clean "uuid assigned to a token name" 'TOKEN_ID=550e8400-e29b-41d4-a716-446655440000'
expect_clean "git sha in a command" 'git checkout adcf77e8b3c1d4f5a6b7c8d9e0f1a2b3c4d5e6f7'
expect_clean "sha256 digest" 'sha256 = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"'
expect_clean "hex digest under a token key name" \
  'TOKEN_HASH=e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855'
expect_clean "lorem ipsum paragraph" \
  'Lorem ipsum dolor sit amet, consectetur adipiscing elit, sed do eiusmod tempor incididunt ut labore et dolore magna aliqua. Ut enim ad minim veniam, quis nostrud exercitation ullamco laboris nisi ut aliquip ex ea commodo consequat. Duis aute irure dolor in reprehenderit in voluptate velit esse cillum.'
expect_clean "shell env-var reference"   'API_KEY=${OPENAI_API_KEY}'
expect_clean "bare shell var reference"  'export AUTH_TOKEN=$CI_AUTH_TOKEN_VALUE_LONG'
expect_clean "python env lookup"         'api_key = os.environ["ANTHROPIC_API_KEY"]'
expect_clean "python getenv"             'secret = os.getenv("DJANGO_SECRET_KEY_NAME")'
expect_clean "node env lookup"           'const token = process.env.GITHUB_TOKEN_FOR_CI;'
expect_clean "vite env lookup"           'const apiKey = import.meta.env.VITE_PUBLIC_API_KEY;'
expect_clean "docs placeholder"          'ANTHROPIC_API_KEY=your-api-key-here'
expect_clean "angle-bracket placeholder" 'apiKey: "<YOUR_API_KEY_GOES_HERE>"'
expect_clean "changeme placeholder"      'password: "changeme-before-deploying"'
expect_clean "x-run placeholder"         'SECRET_TOKEN=xxxxxxxxxxxxxxxxxxxxxxxx'
expect_clean "short password"            'password=hunter2'
expect_clean "snake_case identifier value" "const AUTH_TOKEN_KEY = 'auth_token_storage_key';"
expect_clean "function call value"       'private_key = rsa.generate_private_key(public_exponent=65537)'
expect_clean "secrets module call"       'SECRET_KEY = secrets.token_urlsafe(32)'
expect_clean "guard clause mentioning secret" 'if (!process.env.SECRET) throw new Error("missing secret");'
expect_clean "prose about key prefixes"  'OpenAI keys use the sk- prefix and Anthropic uses sk-ant- instead.'
expect_clean "anthropic docs placeholder" 'export ANTHROPIC_API_KEY=sk-ant-api03-YOUR-KEY-HERE'
expect_clean "file path value"           'SECRET_PATH=/etc/secrets/app-credentials.json'
expect_clean "url value"                 'AUTH_TOKEN_URL=https://auth.example.com/oauth/token'
expect_clean "template placeholder"      'api_token: {{ vault_api_token }}'
expect_clean "numeric value"             'ACCESS_TOKEN_TTL=3600000000000000'
expect_clean "semver"                    'TOKEN_LIB_VERSION=1.24.7-beta.3+build'
expect_clean "prose asking about tokens" 'How do I rotate the token and the client secret for staging?'
expect_clean "sql column names"          'SELECT api_key, secret, access_token FROM credentials WHERE id = 42;'
expect_clean "typescript interface"      'interface Creds { apiKey: string; accessToken: string; clientSecret: string; }'
expect_clean "dotted base64 without jwt payload" \
  'checksum: YWJjZGVmZ2hpamtsbW5vcA.cXJzdHV2d3h5emFiY2RlZg.Z2hpamtsbW5vcHFyc3R1dg'

# ── 3. THE PRE-FILTER IS A STRICT SUPERSET OF THE CLASSIFIER ──
# The hook skips the classifier entirely when the cheap grep misses. If that grep
# is not a superset, the fast path silently drops real detections — the worst
# possible failure for this feature, and an invisible one.
echo ""
echo "[3] the cheap pre-filter never misses what the classifier catches"
COARSE="$(sed -n "s/^COARSE='\(.*\)'$/\1/p" "$FILTER")"
if [ -n "$COARSE" ]; then
  ok "extracted the live COARSE regex from the filter (no drifting copy)"
  superset_ok=1
  for fx in "$F_ANTHROPIC" "$F_OPENAI_PROJ" "$F_OPENAI_BARE" "$F_GITHUB" "$F_GITHUB_PAT" \
            "$F_AWS_ID" "$F_GOOGLE" "$F_SLACK" "$F_JWT" "$F_PEM" \
            "AWS_SECRET_ACCESS_KEY=$F_AWS_SECRET" "DATABASE_PASSWORD=$F_DB_PASS"; do
    printf '%s' "$fx" | LC_ALL=C grep -qiE "$COARSE" || { superset_ok=0; bad "pre-filter MISSES a detected fixture"; }
  done
  [ "$superset_ok" = 1 ] && ok "every positive fixture also passes the pre-filter"
else
  bad "could not extract COARSE from $FILTER — the superset property is unpinned"
fi

# ── 4. VAULT: 0600, GITIGNORED, AND THE VALUE IS RECOVERABLE ──
echo ""
echo "[4] the local vault"
V2="$TMP/vault2"; mkdir -p "$V2"
printf '%s' "paste $F_ANTHROPIC here" | HEIMDALL_HOME="$V2" python3 "$LIB" scan >/dev/null 2>&1
VFILE="$V2/secret-vault.ndjson"
if [ -f "$VFILE" ]; then
  ok "vault file is created on first detection"
  MODE="$(stat -f '%Lp' "$VFILE" 2>/dev/null || stat -c '%a' "$VFILE" 2>/dev/null)"
  [ "$MODE" = "600" ] && ok "vault file mode is 0600 (got $MODE)" || bad "vault mode is $MODE, expected 600"
else
  bad "vault file was not created at $VFILE"
fi

# The real repo path must be ignored — verified against git, not assumed.
if git -C "$REPO" check-ignore -q ".heimdall/secret-vault.ndjson"; then
  ok ".heimdall/secret-vault.ndjson is gitignored (git check-ignore agrees)"
else
  bad ".heimdall/secret-vault.ndjson is NOT gitignored — the vault could be committed"
fi

# Round-trip: the reference resolves back to the exact value, locally.
GOT="$(HEIMDALL_HOME="$V2" python3 "$LIB" get '{{HMD_SECRET_1}}' 2>/dev/null)"
[ "$GOT" = "$F_ANTHROPIC" ] && ok "get resolves the reference back to the exact value" \
  || bad "get did not round-trip the value"

# exec injects into the child environment without printing the value.
EXEC_OUT="$(HEIMDALL_HOME="$V2" python3 "$LIB" exec '{{HMD_SECRET_1}}' MY_KEY -- \
  sh -c 'test "$MY_KEY" = "$1" && printf INJECTED' _ "$F_ANTHROPIC" 2>&1)"
[ "$EXEC_OUT" = "INJECTED" ] && ok "exec injects the value into the child environment only" \
  || bad "exec did not inject the value (got: '$EXEC_OUT')"

# list must never print a value.
LIST_OUT="$(HEIMDALL_HOME="$V2" python3 "$LIB" list 2>&1)"
case "$LIST_OUT" in
  *"$F_ANTHROPIC"*) bad "list printed the secret value" ;;
  *"{{HMD_SECRET_1}}"*) ok "list shows the reference and never the value" ;;
  *) bad "list did not show the reference (got: $LIST_OUT)" ;;
esac

# ── 5. END-TO-END HOOK: BLOCKS, AND LEAKS THE VALUE NOWHERE ──
echo ""
echo "[5] hook mode blocks and never emits the value"
if command -v jq >/dev/null 2>&1; then
  V3="$TMP/vault3"; mkdir -p "$V3"
  PAYLOAD="$(printf '%s' "please deploy with $F_ANTHROPIC thanks" | jq -Rs '{prompt: ., hook_event_name: "UserPromptSubmit"}')"
  printf '%s' "$PAYLOAD" | HEIMDALL_HOME="$V3" "$FILTER" >"$TMP/out.txt" 2>"$TMP/err.txt"
  RC=$?
  [ "$RC" = 2 ] && ok "hook exits 2 (prompt refused) when a credential is present" \
    || bad "hook exited $RC, expected 2"

  grep -qF -- "$F_ANTHROPIC" "$TMP/out.txt" && bad "SECRET LEAKED to stdout" \
    || ok "secret bytes absent from stdout"
  grep -qF -- "$F_ANTHROPIC" "$TMP/err.txt" && bad "SECRET LEAKED to stderr" \
    || ok "secret bytes absent from stderr"
  grep -qF -- '{{HMD_SECRET_1}}' "$TMP/err.txt" \
    && ok "block message names the reference to re-send with" \
    || bad "block message does not name the reference"

  # Byte-absence across every file the hook touched, except the vault itself
  # (which stores it base64-encoded, never in plaintext).
  LEAKED=""
  for f in $(find "$V3" -type f 2>/dev/null); do
    grep -qF -- "$F_ANTHROPIC" "$f" && LEAKED="$LEAKED $f"
  done
  [ -z "$LEAKED" ] && ok "plaintext value appears in no file, not even the vault (stored base64)" \
    || bad "plaintext value found in:$LEAKED"

  # A clean prompt must pass straight through.
  CLEAN="$(printf '%s' 'refactor the parser and add a test' | jq -Rs '{prompt: ., hook_event_name: "UserPromptSubmit"}')"
  printf '%s' "$CLEAN" | HEIMDALL_HOME="$V3" "$FILTER" >"$TMP/clean-out.txt" 2>"$TMP/clean-err.txt"
  CRC=$?
  [ "$CRC" = 0 ] && ok "a clean prompt passes through (exit 0)" || bad "clean prompt exited $CRC"
  [ -s "$TMP/clean-out.txt" ] && bad "clean path wrote to stdout (would become model context)" \
    || ok "clean path writes nothing to stdout"

  # The documented off-switch must actually switch it off.
  printf '%s' "$PAYLOAD" | HMD_SECRET_FILTER=off HEIMDALL_HOME="$V3" "$FILTER" >/dev/null 2>&1
  [ $? = 0 ] && ok "HMD_SECRET_FILTER=off bypasses the filter as documented" \
    || bad "HMD_SECRET_FILTER=off did not bypass"
else
  bad "jq is required for the end-to-end hook test"
fi

# ── 6. RED-PROOF 1 — a no-op detector must break the positive suite ──
echo ""
echo "[6] RED-PROOF 1: no-op detector must fail the positive assertions"
cat > "$TMP/mutant_noop.py" <<PY
import sys
sys.path.insert(0, "$REPO/bin/lib")
import paste_secret_filter as m
m.detect = lambda text: []          # the mutation: detect nothing, ever
sys.exit(m.main(sys.argv[1:]))
PY
NOOP_DETECTED=0
for fx in "$F_ANTHROPIC" "$F_OPENAI_PROJ" "$F_GITHUB" "$F_AWS_ID" "$F_GOOGLE" \
          "$F_SLACK" "$F_JWT" "AWS_SECRET_ACCESS_KEY=$F_AWS_SECRET"; do
  out="$(printf '%s' "$fx" | HEIMDALL_HOME="$TMP/vmut" python3 "$TMP/mutant_noop.py" scan 2>/dev/null)"
  [ -n "$out" ] && NOOP_DETECTED=$((NOOP_DETECTED+1))
done
if [ "$NOOP_DETECTED" = 0 ]; then
  ok "no-op detector finds 0/8 fixtures — the positive suite would go RED (has teeth)"
else
  bad "no-op detector still 'found' $NOOP_DETECTED fixtures — positive assertions are decorative"
fi

# ── 7. RED-PROOF 2 — a plain-entropy detector must break the FP suite ──
echo ""
echo "[7] RED-PROOF 2: over-eager entropy detector must fail the FP assertions"
cat > "$TMP/mutant_entropy.py" <<PY
import re, sys
sys.path.insert(0, "$REPO/bin/lib")
import paste_secret_filter as m

def naive(text):
    # The mutation: entropy as the SOLE signal. No key name required, none of
    # the UUID / hex / template / charset exclusions. This is exactly the
    # "just threshold the entropy" design the real detector rejects.
    out = []
    for tok in re.findall(r"[A-Za-z0-9+/=_.:-]{16,}", text):
        if m.shannon_entropy(tok) >= 3.5:
            out.append(("generic-assignment", tok))
    return out

m.detect = naive
sys.exit(m.main(sys.argv[1:]))
PY
FP_CASES=(
  '<img src="data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==" />'
  'const requestId = "550e8400-e29b-41d4-a716-446655440000";'
  'git checkout adcf77e8b3c1d4f5a6b7c8d9e0f1a2b3c4d5e6f7'
  'sha256 = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"'
  'API_KEY=${OPENAI_API_KEY}'
)
ENTROPY_FPS=0
for fx in "${FP_CASES[@]}"; do
  out="$(printf '%s' "$fx" | HEIMDALL_HOME="$TMP/vmut2" python3 "$TMP/mutant_entropy.py" scan 2>/dev/null)"
  [ -n "$out" ] && ENTROPY_FPS=$((ENTROPY_FPS+1))
done
if [ "$ENTROPY_FPS" -ge 3 ]; then
  ok "plain-entropy detector false-positives on $ENTROPY_FPS/5 clean cases — FP suite has teeth"
else
  bad "plain-entropy detector only tripped $ENTROPY_FPS/5 — the FP assertions prove little"
fi

# And the real detector must be clean on those very same cases.
REAL_FPS=0
for fx in "${FP_CASES[@]}"; do
  out="$(printf '%s' "$fx" | HEIMDALL_HOME="$TMP/vreal" python3 "$LIB" scan 2>/dev/null)"
  [ -n "$out" ] && REAL_FPS=$((REAL_FPS+1))
done
[ "$REAL_FPS" = 0 ] && ok "the real detector is clean on all 5 cases the mutant trips" \
  || bad "the real detector false-positived on $REAL_FPS/5 cases"

echo ""
printf 'RESULT: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
