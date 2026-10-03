#!/usr/bin/env bash
# test/companion-cc-login-vectors.test.sh -- the two gates of remote Claude Code login (login-v1):
# which authorize URL hmd may publish to the phone (validate_url) and which pasted code hmd may type
# into `claude auth login` (normalize_code). See hmdapp's docs/HANDOFF-TO-HEIMDALL-remote-cc-login.md
# RL1/RL6 and docs/superpowers/specs/2026-10-03-remote-cc-login.md sections 3.2 / 4.4.
#
# The oracle is external to the code under test: docs/samples/login/{allowlist,url-vectors,
# code-vectors}.json. They are heimdall-authored stand-ins until the app's wave-0 fixtures exist; each
# is checksum-pinned below so a changed fixture is a loud, deliberate act (vendor the app's file over
# it, then re-pin). Every url vector goes through validate_url, every code vector through
# normalize_code, and the expected reason strings must match exactly.
#
# Falsifiable by construction: the module is mutated one guard at a time (the handoff's six -- drop the
# host check, drop the redirect_uri check, allow http, accept xn--, accept a second #, accept a CR --
# and more) and the vectors must go red on every mutant. The mutant score is printed and must be 1.0.
set -u

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MOD="$REPO/bin/lib/companion_cc_login.py"
CHECK="$REPO/test/lib/cc_login_vectors_check.py"
FIX="$REPO/docs/samples/login"

# sha256 of the vendored fixtures. Re-pin when the app's wave-0 files replace the stand-ins.
PIN_ALLOWLIST="884bb1014a8df257e07c7f4adfede46f3f9f727a06c776e1256f9b5bb0760cfb"
PIN_URL_VECTORS="5e9c8dae88598d68b028a18d61b18671a819b3385a3920be0eb87f77b5b97197"
PIN_CODE_VECTORS="789a421cfeab46a60daa26fa07620041db93c2bc917f20dbc87c3ce61a4540e8"

PASS=0
FAIL=0
N=0
ok()  { N=$((N + 1)); PASS=$((PASS + 1)); printf '  ok   %d. %s\n' "$N" "$1"; }
bad() { N=$((N + 1)); FAIL=$((FAIL + 1)); printf '  FAIL %d. %s\n' "$N" "$1"; }

echo "companion-cc-login-vectors (validate_url / normalize_code vs the shared vectors, plus mutants)"

for f in "$CHECK" "$FIX/allowlist.json" "$FIX/url-vectors.json" "$FIX/code-vectors.json"; do
  if [ ! -e "$f" ]; then
    printf 'FATAL: required file missing: %s\n' "$f" >&2
    printf '\n0 passed, 1 failed\n'
    exit 1
  fi
done
if ! command -v python3 >/dev/null 2>&1; then
  printf 'FATAL: python3 missing\n' >&2
  printf '\n0 passed, 1 failed\n'
  exit 1
fi

TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT

sha256_of() { python3 -c 'import hashlib,sys; print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$1"; }

# ── 1. the fixtures are the pinned, well-formed ones ──────────────────────────
for pair in "allowlist.json:$PIN_ALLOWLIST" "url-vectors.json:$PIN_URL_VECTORS" "code-vectors.json:$PIN_CODE_VECTORS"; do
  name="${pair%%:*}"
  want="${pair#*:}"
  if ! python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$FIX/$name" 2>/dev/null; then
    bad "$name does not parse as JSON"
    continue
  fi
  got="$(sha256_of "$FIX/$name")"
  if [ "$got" = "$want" ]; then
    ok "$name parses and matches its pinned checksum"
  else
    bad "$name checksum drifted (pinned $want, now $got) -- vendoring a new fixture? re-pin it here on purpose"
  fi
done

n_url="$(python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1]))["vectors"]))' "$FIX/url-vectors.json")"
n_code="$(python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1]))["vectors"]))' "$FIX/code-vectors.json")"
if [ "${n_url:-0}" -ge 40 ]; then ok "url-vectors.json carries $n_url vectors (spec 10.1 asks for at least 40)"; else bad "url-vectors.json has only ${n_url:-0} vectors"; fi
if [ "${n_code:-0}" -ge 30 ]; then ok "code-vectors.json carries $n_code vectors"; else bad "code-vectors.json has only ${n_code:-0} vectors"; fi

# ── 2. the real module agrees with every vector ───────────────────────────────
if [ ! -f "$MOD" ]; then
  bad "bin/lib/companion_cc_login.py is absent"
else
  OUT="$TMPROOT/real.out"
  python3 "$CHECK" --module "$MOD" >"$OUT" 2>&1
  rc=$?
  tally="$(grep -E '^[0-9]+ passed, [0-9]+ failed$' "$OUT" | tail -1)"
  if [ "$rc" -eq 0 ] && [ -n "$tally" ]; then
    ok "every url vector, code vector and boundary length agrees with the module: $tally"
  else
    bad "the module disagrees with the vectors (exit $rc, tally '${tally:-none}')"
    grep -E '  FAIL |Traceback|Error' -A1 "$OUT" | head -30
  fi
fi

# ── 3. module surface and the small pure helpers ──────────────────────────────
PRELUDE='
import hashlib, json, os, sys
from importlib.util import module_from_spec, spec_from_file_location
MOD, REPO = sys.argv[1], sys.argv[2]
_spec = spec_from_file_location("companion_cc_login", MOD)
m = module_from_spec(_spec)
_spec.loader.exec_module(m)
'

py_case() {
  local desc="$1" out
  if { printf '%s\n' "$PRELUDE"; cat; } | python3 - "$MOD" "$REPO" >"$TMPROOT/case.out" 2>"$TMPROOT/case.err"; then
    out="$(tail -n 1 "$TMPROOT/case.out")"
    if [ -n "$out" ]; then ok "$desc ($out)"; else ok "$desc"; fi
  else
    bad "$desc:"
    sed 's/^/       | /' "$TMPROOT/case.err"
  fi
}

py_case "surface: loadable by path, the contract names exist, the cap is login-v1, the allowlist is the vendored file" <<'PYEOF'
assert callable(m.validate_url) and callable(m.normalize_code) and callable(m.mask_account) and callable(m.identity_fingerprint)
assert isinstance(m.LoginError, type) and issubclass(m.LoginError, Exception)
assert hasattr(m, "LoginManager") and hasattr(m.LoginManager, "start") and hasattr(m.LoginManager, "submit_code")
assert hasattr(m.LoginManager, "cancel") and hasattr(m.LoginManager, "probe") and hasattr(m.LoginManager, "snapshot") and hasattr(m.LoginManager, "shutdown") and hasattr(m.LoginManager, "enabled")
assert m.CAP_LOGIN == "login-v1", m.CAP_LOGIN
assert set(m.ACTIONS) == {"login_start", "login_code", "login_cancel"}, m.ACTIONS
assert os.path.realpath(m.ALLOWLIST_PATH) == os.path.realpath(os.path.join(REPO, "docs", "samples", "login", "allowlist.json")), m.ALLOWLIST_PATH
e = m.LoginError("bad-url", "why")
assert e.code == "bad-url" and "why" in str(e)
PYEOF

py_case "mask_account: first character of the local part, an ellipsis, @, the domain; anything else is None" <<'PYEOF'
assert m.mask_account("r@example.test") == "r…@example.test"
assert m.mask_account("alice.b@sub.example.test") == "a…@sub.example.test"
for junk in (None, "", "no-at-sign", "a@b@c", "@example.test", "local@", "a b@example.test", "a@exa mple", 7, ["a@b.c"]):
    assert m.mask_account(junk) is None, repr(junk)
PYEOF

py_case "identity_fingerprint: sha256 of email + org id only; case-insensitive; None when signed out or unidentifiable" <<'PYEOF'
base = {"loggedIn": True, "authMethod": "claude.ai", "email": "Owner@Example.test", "orgId": "11111111-2222-3333-4444-555555555555", "orgName": "Org One"}
fp = m.identity_fingerprint(base)
assert isinstance(fp, str) and len(fp) == 64 and all(c in "0123456789abcdef" for c in fp), fp
assert "owner" not in fp and "example" not in fp, "the fingerprint must not carry the raw email"
assert m.identity_fingerprint(dict(base, email="owner@example.test")) == fp, "email case must not matter"
assert m.identity_fingerprint(dict(base, orgName="Renamed Org", subscriptionType="max")) == fp, "org name is display text, not identity"
assert m.identity_fingerprint(dict(base, authMethod="api_key", apiKeySource="/login managed key")) == fp, "same account via the console login is the same identity"
assert m.identity_fingerprint(dict(base, orgId="99999999-2222-3333-4444-555555555555")) != fp
assert m.identity_fingerprint(dict(base, email="someone-else@example.test")) != fp
for junk in (None, [], "x", {}, {"loggedIn": False, "email": "a@b.c"}, {"loggedIn": True}, {"loggedIn": True, "email": ""},
             {"loggedIn": True, "email": 7}, {"loggedIn": "yes", "email": "a@b.c"}):
    assert m.identity_fingerprint(junk) is None, repr(junk)
PYEOF

# ── 4. falsifiability: every mutant must turn the vectors red ─────────────────
cat >"$TMPROOT/mutate.py" <<'PYEOF'
"""Applies one guard-removing mutation at a time to a private copy of the module (and its allowlist),
runs the vector checker against the copy and reports whether the vectors noticed."""
import json, os, shutil, subprocess, sys, tempfile

mod_src, allow_src, checker, vectors = sys.argv[1:5]

# (name, text in the module source, replacement)
SOURCE = [
    ("drop-host-check", 'r["host"] == authority and ', ""),
    ("drop-redirect-uri-check", 'if params.get("redirect_uri") != row["redirect_uri"]:', "if False:"),
    ("allow-http", 'scheme != "https"', 'scheme not in ("https", "http")'),
    ("accept-punycode-host", ' or "xn--" in authority', ""),
    ("accept-upper-case-host", "authority != authority.lower() or ", ""),
    ("drop-userinfo-check", ' or "@" in authority', ""),
    ("drop-port-check", ' or ":" in authority', ""),
    ("drop-backslash-check", ' or "\\\\" in url', ""),
    ("drop-printable-ascii-check", "_PRINTABLE_ASCII.fullmatch(url) is None or ", ""),
    ("drop-fragment-check", "if hash_sep:", "if False:"),
    ("drop-duplicate-key-check", "if key in params:", "if False:"),
    ("drop-length-cap", 'if len(url) > allow["max_url_length"]:', "if False:"),
    ("drop-kind-check", 'if row["kind"] != kind:', "if False:"),
    ("drop-required-query-check", "if params.get(key) != want:", "if False:"),
    ("drop-pkce-shape-check", 'if allow["pkce_re"].fullmatch(params.get(key, "")) is None:', "if False:"),
    ("drop-client-id-check", "if not params.get(key):", "if False:"),
    ("trim-unicode-whitespace-from-codes", "raw.strip(ASCII_WHITESPACE)", "raw.strip()"),
]


def allow_second_hash(a):
    a["code_regex"] = a["code_regex"].replace("[A-Za-z0-9._~-]", "[A-Za-z0-9._~#-]")


def allow_carriage_return(a):
    a["code_regex"] = a["code_regex"].replace("[A-Za-z0-9._~-]", "[A-Za-z0-9._~\\r-]")


def allow_any_pkce_shape(a):
    a["pkce_regex"] = "^.*$"


def allow_evil_row(a):
    a["rows"].append({"kind": "claudeai", "host": "claude.com.evil.example", "path": "/cai/oauth/authorize",
                      "redirect_uri": a["rows"][0]["redirect_uri"], "source": "mutant"})


def allow_no_challenge_method(a):
    a["required_query"].pop("code_challenge_method")


def allow_long_urls(a):
    a["max_url_length"] = 4096


ALLOW = [
    ("accept-a-second-hash-in-codes", allow_second_hash),
    ("accept-a-carriage-return-in-codes", allow_carriage_return),
    ("accept-any-pkce-shape", allow_any_pkce_shape),
    ("allowlist-gains-an-evil-host", allow_evil_row),
    ("allowlist-drops-the-challenge-method", allow_no_challenge_method),
    ("allowlist-lifts-the-length-cap", allow_long_urls),
]


def run(name, mutate_tree):
    tree = tempfile.mkdtemp(prefix="mutant-")
    try:
        mpath = os.path.join(tree, "bin", "lib", "companion_cc_login.py")
        apath = os.path.join(tree, "docs", "samples", "login", "allowlist.json")
        os.makedirs(os.path.dirname(mpath))
        os.makedirs(os.path.dirname(apath))
        shutil.copy(mod_src, mpath)
        shutil.copy(allow_src, apath)
        mutate_tree(mpath, apath)
        p = subprocess.run([sys.executable, checker, "--module", mpath, "--vectors", vectors],
                           capture_output=True, text=True, timeout=300)
        fails = [ln for ln in p.stdout.splitlines() if ln.startswith("  FAIL ")]
        if "module loaded" not in p.stdout:
            state = "invalid"   # the mutant did not even import: that proves nothing
        elif p.returncode != 0 and fails:
            state = "caught"
        else:
            state = "survived"
        print("MUTANT %s %s (%d vectors red)" % (name, state, len(fails)))
    finally:
        shutil.rmtree(tree, ignore_errors=True)


def source_mutation(old, new):
    def apply(mpath, _apath):
        with open(mpath, encoding="utf-8") as f:
            text = f.read()
        if old not in text:
            raise SystemExit("mutation anchor not found in the module: %r" % old)
        with open(mpath, "w", encoding="utf-8") as f:
            f.write(text.replace(old, new, 1))
    return apply


def allowlist_mutation(fn):
    def apply(_mpath, apath):
        with open(apath, encoding="utf-8") as f:
            a = json.load(f)
        fn(a)
        with open(apath, "w", encoding="utf-8") as f:
            json.dump(a, f)
    return apply


for name, old, new in SOURCE:
    run(name, source_mutation(old, new))
for name, fn in ALLOW:
    run(name, allowlist_mutation(fn))
PYEOF

if [ -f "$MOD" ]; then
  python3 "$TMPROOT/mutate.py" "$MOD" "$FIX/allowlist.json" "$CHECK" "$FIX" >"$TMPROOT/mutants.out" 2>"$TMPROOT/mutants.err"
  mrc=$?
  total="$(grep -c '^MUTANT ' "$TMPROOT/mutants.out")"
  caught="$(grep -c '^MUTANT .* caught ' "$TMPROOT/mutants.out")"
  if [ "$mrc" -ne 0 ] || [ "${total:-0}" -eq 0 ]; then
    bad "the mutation run itself failed (exit $mrc)"
    sed 's/^/       | /' "$TMPROOT/mutants.err" | head -10
  else
    while IFS= read -r line; do
      case "$line" in
        MUTANT*" caught "*) ok "mutant turns the vectors red: ${line#MUTANT }" ;;
        MUTANT*)            bad "mutant NOT caught: ${line#MUTANT }" ;;
      esac
    done <"$TMPROOT/mutants.out"
    score="$(python3 -c 'import sys; c,t=int(sys.argv[1]),int(sys.argv[2]); print("%.1f" % (c/t))' "$caught" "$total")"
    if [ "$caught" = "$total" ]; then ok "mutant score $caught/$total = $score"; else bad "mutant score $caught/$total = $score (must be 1.0)"; fi
  fi
else
  bad "no module to mutate"
fi

echo ""
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
