#!/usr/bin/env bash
#
# runhmd-wrapper.test.sh — acceptance for packages/runhmd, the `npx runhmd` front door.
#
#   bash test/runhmd-wrapper.test.sh    (exit 0 = every case passes)
#
# `runhmd <path>` must run `hmd attack <path>`, `runhmd <known-subcommand> …` must reach hmd
# untouched, and the wrapper must never run an install script whose bytes it has not hashed
# against the pin baked into its package.json. Proved offline and hermetically — a throwaway
# HOME, a scrubbed environment, a stand-in hmd and a stand-in install.sh (test/lib/
# runhmd-fixtures.sh); the suite never runs a real hmd, a real installer, or the network:
#
#   A. package  `npm pack --dry-run` lists ONLY the intended files; package.json carries a
#               well-formed pin and the default command
#   B. local    --version / --help answer from the wrapper itself — no install, no hmd
#   C. routing  a bare path / URL / flag becomes `hmd attack …`; a known subcommand passes
#               through verbatim; hmd's exit code is runhmd's exit code
#   D. pin      a sha256 mismatch REFUSES: the install script never runs and hmd is never
#               run — not even a stale one that happens to be installed
#   E. install  a missing or too-old hmd triggers the verified installer; a current one never
#               does; an installer that leaves hmd missing or still too old is refused
#   F. fetch    redirects are followed; HTTP errors and redirect loops refuse
#
# R6 (a check must be able to fail): every refusal case asserts all three of "exit non-zero",
# "the install script did not run" and "hmd did not run" — a wrapper that verified the digest
# but ran the script anyway, or refused but fell back to the installed hmd, goes red.
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SELF_DIR/.." && pwd)"
PKG_DIR="$REPO/packages/runhmd"
WRAP="$PKG_DIR/bin/runhmd.js"
FAKE_HTTPS="$SELF_DIR/lib/runhmd-fake-https.js"
FIXTURES="$SELF_DIR/lib/runhmd-fixtures.sh"

PASS=0; FAIL=0
ok()  { printf '  \033[32mPASS\033[0m %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAIL=$((FAIL+1)); }

[ -r "$FIXTURES" ] || { echo "FATAL: shared fixtures missing: $FIXTURES" >&2; exit 2; }
. "$FIXTURES"
for t in node jq shasum; do
  command -v "$t" >/dev/null 2>&1 || { echo "FATAL: $t is required" >&2; exit 2; }
done

WORK="$(mktemp -d "${TMPDIR:-/tmp}/runhmd-wrapper-test.XXXXXX")"
[ -n "$WORK" ] || { echo "FATAL: WORK path empty (mktemp failed)" >&2; exit 2; }
cleanup() { rm -rf "$WORK" 2>/dev/null || true; }
trap cleanup EXIT
mkdir -p "$WORK/tmp"

# The wrapper runs under a scrubbed environment (env -i) with a PATH that holds node and the
# system tools only — never the developer's own ~/.local/bin, where a real hmd may live.
NODE_BIN="$(command -v node)"
BASE_PATH="$(dirname "$NODE_BIN"):/usr/bin:/bin"
if [ -n "$(env -i PATH="$BASE_PATH" /usr/bin/which hmd 2>/dev/null)" ]; then
  echo "FATAL: a real hmd is reachable on the hermetic PATH ($BASE_PATH) — refusing to run" >&2
  exit 2
fi

echo "runhmd-wrapper harness  wrapper=$WRAP"
echo "--------------------------------------------------------------------"

HMD_TEMPLATE="$WORK/hmd-template";      rf_make_hmd_template "$HMD_TEMPLATE"
INSTALLER="$WORK/install-fixture.sh";   rf_make_installer "$INSTALLER"
INSTALLER_SHA="$(rf_sha256 "$INSTALLER")"
WRONG_SHA="$(rf_bend_digest "$INSTALLER_SHA")"
NEAR_SHA="${INSTALLER_SHA%?}$(printf '%s' "${INSTALLER_SHA#${INSTALLER_SHA%?}}" | tr '0123456789abcdef' '1234567890badcfe')"
UPPER_SHA="$(printf '%s' "$INSTALLER_SHA" | tr 'abcdef' 'ABCDEF')"

PKG_VER="$(jq -r '.version // empty' "$PKG_DIR/package.json" 2>/dev/null || true)"
PKG_TAG="$(jq -r '.heimdall.tag // empty' "$PKG_DIR/package.json" 2>/dev/null || true)"
PKG_SHA="$(jq -r '.heimdall.sha256 // empty' "$PKG_DIR/package.json" 2>/dev/null || true)"

# ── Case plumbing ────────────────────────────────────────────────────────────
CASE=0; H=""; LOG=""; MARK=""; OUT=""; ERR=""; RC=0
WRAP_UNDER_TEST="$WRAP"

new_case() {  # a fresh HOME with nothing installed, a fresh argv log, install marker and output files
  CASE=$((CASE+1))
  H="$WORK/home$CASE"
  mkdir -p "$H/.local/bin"
  LOG="$WORK/hmd$CASE.log"; : > "$LOG"
  MARK="$WORK/install$CASE.mark"
  OUT="$WORK/out$CASE"; ERR="$WORK/err$CASE"
  WRAP_UNDER_TEST="$WRAP"
}

install_stub_hmd() {  # <version the installed stand-in hmd reports>
  cp "$HMD_TEMPLATE" "$H/.local/bin/hmd"
  chmod +x "$H/.local/bin/hmd"
  printf '%s\n' "$1" > "$H/.local/bin/.hmd-version"
}

# wrap_run [VAR=value ...] -- [wrapper args ...]
# Defaults point the wrapper at the stand-in installer with its CORRECT digest; extra VAR=value
# pairs come last, so they override the defaults.
wrap_run() {
  local extra=()
  while [ "$#" -gt 0 ] && [ "$1" != "--" ]; do extra+=("$1"); shift; done
  [ "$#" -gt 0 ] && shift
  env -i HOME="$H" PATH="$BASE_PATH" TMPDIR="$WORK/tmp" \
    STUB_HMD_LOG="$LOG" STUB_INSTALL_MARK="$MARK" STUB_HMD_TEMPLATE="$HMD_TEMPLATE" \
    RUNHMD_INSTALL_SCRIPT="$INSTALLER" RUNHMD_SHA256="$INSTALLER_SHA" \
    ${extra[@]+"${extra[@]}"} \
    "$NODE_BIN" "$WRAP_UNDER_TEST" "$@" >"$OUT" 2>"$ERR"
  RC=$?
}

dump() { sed 's/^/    | /' "$ERR" >&2; }

assert_argv() {  # <label> <expected argv...> — hmd ran exactly once, with exactly this argv
  local label="$1"; shift
  local want got
  want="$(printf 'ARGC=%s\n' "$#"; for a in "$@"; do printf 'ARG=%s\n' "$a"; done)"
  got="$(cat "$LOG" 2>/dev/null || true)"
  if [ "$got" = "$want" ]; then
    ok "$label"
  else
    bad "$label"
    printf '    want: %s\n    got:  %s\n' "$(printf '%s' "$want" | tr '\n' '|')" "$(printf '%s' "$got" | tr '\n' '|')" >&2
    dump
  fi
}

assert_refused() {  # <label> — non-zero exit, install script did NOT run, hmd did NOT run
  local label="$1" why=""
  [ "$RC" -ne 0 ]  || why="$why exited-0;"
  [ ! -e "$MARK" ] || why="$why install-script-ran;"
  [ ! -s "$LOG" ]  || why="$why hmd-ran;"
  if [ -z "$why" ]; then ok "$label"; else bad "$label —$why"; dump; fi
}

assert_refused_after_install() {  # <label> — the installer DID run, yet the wrapper must still refuse and not run hmd
  local label="$1" why=""
  [ "$RC" -ne 0 ] || why="$why exited-0;"
  [ -e "$MARK" ]  || why="$why installer-did-not-run;"
  [ ! -s "$LOG" ] || why="$why hmd-ran;"
  if [ -z "$why" ]; then ok "$label"; else bad "$label —$why"; dump; fi
}

assert_stderr_has() {  # <label> <fixed string>
  if grep -Fq -- "$2" "$ERR" 2>/dev/null; then ok "$1"; else bad "$1 (stderr lacks: $2)"; dump; fi
}

assert_no_side_effects() {  # <label> — no install script, no hmd, exit 0
  local label="$1" why=""
  [ "$RC" -eq 0 ]  || why="$why exit=$RC;"
  [ ! -e "$MARK" ] || why="$why install-script-ran;"
  [ ! -s "$LOG" ]  || why="$why hmd-ran;"
  if [ -z "$why" ]; then ok "$label"; else bad "$label —$why"; dump; fi
}

make_pkg_copy() {  # <dest> [jq filter applied to package.json] — a package dir the wrapper can run from
  local dest="$1" filter="${2:-.}"
  mkdir -p "$dest/bin"
  cp "$WRAP" "$dest/bin/runhmd.js" 2>/dev/null || true
  cp "$PKG_DIR/subcommands.txt" "$dest/subcommands.txt" 2>/dev/null || true
  jq "$filter" "$PKG_DIR/package.json" > "$dest/package.json" 2>/dev/null || true
}

# ── A. package ───────────────────────────────────────────────────────────────
echo "A. package"

if jq -e --arg tag "v$PKG_VER" '
     .name == "runhmd"
     and .bin == {"runhmd": "bin/runhmd.js"}
     and (.version | test("^[0-9]+\\.[0-9]+\\.[0-9]+$"))
     and .heimdall.tag == $tag
     and .heimdall.defaultCommand == "attack"
     and (.heimdall.sha256 | test("^[0-9a-f]{64}$"))
     and (.heimdall.installScriptUrl | startswith("https://raw.githubusercontent.com/randomittin/heimdall/"))
     and (.heimdall.installScriptUrl | endswith("/" + $tag + "/install.sh"))
     and (.engines.node | startswith(">="))
   ' "$PKG_DIR/package.json" >/dev/null 2>&1; then
  ok "package.json: name runhmd, bin runhmd -> bin/runhmd.js, default command attack, well-formed pin (tag/url/sha256)"
else
  bad "package.json is missing, or lacks the runhmd name / bin / default command / well-formed pin"
fi

if [ -x "$WRAP" ] && [ "$(head -1 "$WRAP" 2>/dev/null)" = "#!/usr/bin/env node" ]; then
  ok "bin/runhmd.js is executable and carries the node shebang"
else
  bad "bin/runhmd.js is missing, not executable, or has no '#!/usr/bin/env node' shebang"
fi

if [ -f "$PKG_DIR/subcommands.txt" ] \
   && grep -v '^[[:space:]]*#' "$PKG_DIR/subcommands.txt" | grep -qx 'attack'; then
  ok "subcommands.txt exists and lists the default command (attack) as a known subcommand"
else
  bad "subcommands.txt is missing or does not list 'attack' — 'runhmd attack .' would become 'hmd attack attack .'"
fi

if command -v npm >/dev/null 2>&1 && [ -f "$PKG_DIR/package.json" ]; then
  PACKED="$( cd "$PKG_DIR" && npm pack --dry-run --json --ignore-scripts 2>/dev/null | jq -r '.[0].files[].path' 2>/dev/null | LC_ALL=C sort | tr '\n' ' ' )"
  WANT_PACKED="README.md bin/runhmd.js package.json subcommands.txt "
  if [ "$PACKED" = "$WANT_PACKED" ]; then
    ok "npm pack --dry-run lists ONLY the intended files ($WANT_PACKED)"
  else
    bad "npm pack --dry-run file list is wrong — want [$WANT_PACKED] got [$PACKED]"
  fi
else
  echo "  SKIP npm pack --dry-run check (npm not found, or packages/runhmd/package.json missing)"
fi

# ── B. local flags ───────────────────────────────────────────────────────────
echo "B. local flags — answered by the wrapper itself"

# No hmd installed, and a digest that would REFUSE if it were ever consulted: --version and
# --help must not care, because they run nothing.
new_case
wrap_run RUNHMD_SHA256="$WRONG_SHA" -- --version
assert_no_side_effects "--version exits 0 with no install and no hmd run (even with no hmd installed and a bad digest)"
if grep -Fq "runhmd $PKG_VER" "$OUT" && grep -Fq "$PKG_TAG" "$OUT" && grep -Fq "${PKG_SHA:0:12}" "$OUT"; then
  ok "--version prints the package version, the pinned hmd release and the pinned digest prefix"
else
  bad "--version output lacks 'runhmd $PKG_VER' / '$PKG_TAG' / '${PKG_SHA:0:12}'"; sed 's/^/    | /' "$OUT" >&2
fi

for flag in -v -V; do
  new_case
  wrap_run -- "$flag"
  if [ "$RC" -eq 0 ] && grep -Fq "runhmd $PKG_VER" "$OUT" && [ ! -e "$MARK" ] && [ ! -s "$LOG" ]; then
    ok "$flag is --version"
  else
    bad "$flag is not handled as --version (rc=$RC)"; dump
  fi
done

for flag in --help -h; do
  new_case
  wrap_run -- "$flag"
  if [ "$RC" -eq 0 ] && grep -Fiq 'usage' "$OUT" && grep -Fq 'hmd attack' "$OUT" \
     && [ ! -e "$MARK" ] && [ ! -s "$LOG" ]; then
    ok "$flag prints usage naming 'hmd attack' — no install, no hmd run"
  else
    bad "$flag did not print usage with 'hmd attack' cleanly (rc=$RC)"; dump
  fi
done

# ── C. routing ───────────────────────────────────────────────────────────────
echo "C. routing — hmd is installed at the pinned release, so the installer must never run"

route_case() {  # <label> <expected hmd argv...>   (wrapper args come from ROUTE_ARGS)
  local label="$1"; shift
  new_case
  install_stub_hmd "$PKG_VER"
  wrap_run -- ${ROUTE_ARGS[@]+"${ROUTE_ARGS[@]}"}
  if [ -e "$MARK" ]; then bad "$label — the installer ran although hmd is current"; else assert_argv "$label" "$@"; fi
}

ROUTE_ARGS=(.);                                   route_case "runhmd .                      -> hmd attack ." attack .
ROUTE_ARGS=(/some/abs/path);                      route_case "runhmd /some/abs/path         -> hmd attack /some/abs/path" attack /some/abs/path
ROUTE_ARGS=(https://github.com/o/r/pull/7);       route_case "runhmd <pr-url>               -> hmd attack <pr-url>" attack https://github.com/o/r/pull/7
ROUTE_ARGS=(attack .);                            route_case "runhmd attack .               -> hmd attack .  (not doubled)" attack .
ROUTE_ARGS=(attack . --json --yes);               route_case "runhmd attack . --json --yes  -> verbatim" attack . --json --yes
ROUTE_ARGS=(--json .);                            route_case "runhmd --json .               -> hmd attack --json ." attack --json .
ROUTE_ARGS=(--max-usd 2 .);                       route_case "runhmd --max-usd 2 .          -> hmd attack --max-usd 2 ." attack --max-usd 2 .
ROUTE_ARGS=();                                    route_case "runhmd (no args)              -> hmd attack" attack
ROUTE_ARGS=(prove --json);                        route_case "runhmd prove --json           -> passes through" prove --json
ROUTE_ARGS=(demo --offline);                      route_case "runhmd demo --offline         -> passes through" demo --offline
ROUTE_ARGS=(team show --json);                    route_case "runhmd team show --json       -> passes through" team show --json
ROUTE_ARGS=(update);                              route_case "runhmd update                 -> passes through" update
ROUTE_ARGS=(./team);                              route_case "runhmd ./team                 -> hmd attack ./team  (a path named like a subcommand)" attack ./team
ROUTE_ARGS=("my dir/x y");                        route_case "runhmd 'my dir/x y'           -> argv kept intact (spaces)" attack "my dir/x y"
ROUTE_ARGS=(typo-cmd);                            route_case "runhmd typo-cmd               -> hmd attack typo-cmd  (an unknown word is a target)" attack typo-cmd

new_case; install_stub_hmd "$PKG_VER"
wrap_run -- .
if grep -Fq 'hmd-stub-ran' "$OUT"; then ok "hmd's stdout reaches the caller (stdio is inherited)"; else bad "hmd's stdout was swallowed"; fi

for code in 0 1 2 3 4 5; do
  new_case; install_stub_hmd "$PKG_VER"
  wrap_run STUB_HMD_EXIT="$code" -- .
  if [ "$RC" -eq "$code" ]; then ok "hmd exit code $code is runhmd's exit code"; else bad "hmd exited $code but runhmd exited $RC"; fi
done

# ── D. the pin ───────────────────────────────────────────────────────────────
echo "D. pin — a mismatch refuses; nothing unverified ever runs"

new_case
wrap_run RUNHMD_SHA256="$WRONG_SHA" -- .
assert_refused "no hmd installed + wrong digest: refused"
assert_stderr_has "the refusal says 'checksum mismatch — refusing to run'" "checksum mismatch — refusing to run"
if grep -Fq "expected: $WRONG_SHA" "$ERR" && grep -Fq "actual:   $INSTALLER_SHA" "$ERR"; then
  ok "the refusal prints both digests (expected = the pin, actual = what was fetched)"
else
  bad "the refusal does not show expected/actual digests"; dump
fi

new_case
wrap_run RUNHMD_SHA256="$NEAR_SHA" -- .
assert_refused "a digest that differs only in its LAST nibble is refused (full-length compare)"

new_case; install_stub_hmd "0.0.1"
wrap_run RUNHMD_SHA256="$WRONG_SHA" -- .
assert_refused "stale hmd installed + wrong digest: refused, and the STALE hmd is not run as a fallback"

new_case; install_stub_hmd "$PKG_VER"
wrap_run RUNHMD_SHA256="$WRONG_SHA" -- .
if [ ! -e "$MARK" ] && [ "$RC" -eq 0 ]; then
  assert_argv "current hmd installed + wrong digest: no install is needed, so nothing is fetched or verified — hmd just runs" attack .
else
  bad "a current hmd should run without consulting the digest (rc=$RC)"; dump
fi

new_case
wrap_run RUNHMD_SHA256="$UPPER_SHA" -- .
assert_argv "an UPPERCASE form of the correct digest is accepted (the pin is compared case-insensitively)" attack .

new_case
wrap_run RUNHMD_SHA256="abc123" -- .
assert_refused "a malformed digest (not 64 hex) is refused"
assert_stderr_has "…naming the problem" "not a 64-char hex digest"

new_case; install_stub_hmd "$PKG_VER"
wrap_run RUNHMD_SHA256="abc123" -- .
assert_refused "a malformed digest is refused even when no install would be needed (the package is not trusted at all)"

new_case; make_pkg_copy "$WORK/pkg-sentinel" '.heimdall.sha256 = "REPLACE_AT_PUBLISH"'
WRAP_UNDER_TEST="$WORK/pkg-sentinel/bin/runhmd.js"
wrap_run RUNHMD_SHA256= -- .
assert_refused "a wrapper not built by release/sync-release.sh (placeholder digest) is refused"
assert_stderr_has "…saying no checksum is baked in" "no published checksum baked in"

new_case
wrap_run RUNHMD_INSTALL_SCRIPT="$WORK/does-not-exist.sh" -- .
assert_refused "a RUNHMD_INSTALL_SCRIPT pointing at a missing file is refused"
assert_stderr_has "…naming the missing file" "points at a missing file"

new_case; make_pkg_copy "$WORK/pkg-nolist"; rm -f "$WORK/pkg-nolist/subcommands.txt"
WRAP_UNDER_TEST="$WORK/pkg-nolist/bin/runhmd.js"; install_stub_hmd "$PKG_VER"
wrap_run -- .
assert_refused "a package without subcommands.txt is refused (it cannot tell a subcommand from a path)"
assert_stderr_has "…naming subcommands.txt" "subcommands.txt"

new_case; make_pkg_copy "$WORK/pkg-nodefault" 'del(.heimdall.defaultCommand)'
WRAP_UNDER_TEST="$WORK/pkg-nodefault/bin/runhmd.js"; install_stub_hmd "$PKG_VER"
wrap_run -- .
assert_refused "a package without heimdall.defaultCommand is refused"
assert_stderr_has "…naming defaultCommand" "defaultCommand"

# ── E. install ───────────────────────────────────────────────────────────────
echo "E. install — the verified installer runs only when hmd is missing or too old"

new_case
wrap_run -- attack . --json
if [ "$RC" -eq 0 ] && [ "$(sed -n 1p "$MARK" 2>/dev/null)" = "ran" ]; then
  ok "no hmd installed: the pinned installer ran"
else
  bad "no hmd installed: the installer did not run cleanly (rc=$RC)"; dump
fi
if [ "$(sed -n 2p "$MARK" 2>/dev/null)" = "0" ]; then
  ok "the installer was given NO arguments (the user's args are for hmd, not for install.sh)"
else
  bad "the installer received arguments: argc=$(sed -n 2p "$MARK" 2>/dev/null)"
fi
assert_argv "…and then hmd ran with the routed argv" attack . --json
assert_stderr_has "stderr says hmd is not installed" "hmd is not installed"
if grep -Fq "verified install.sh" "$ERR" && grep -Fq "${INSTALLER_SHA:0:12}" "$ERR"; then
  ok "stderr reports the verified digest prefix before running the installer"
else
  bad "stderr does not report the verification"; dump
fi

new_case; install_stub_hmd "0.0.1"
wrap_run -- .
if [ -e "$MARK" ] && [ "$RC" -eq 0 ]; then ok "hmd older than the pin: the pinned installer ran"; else bad "an older hmd did not trigger the installer (rc=$RC)"; dump; fi
assert_argv "…and the upgraded hmd then ran" attack .
assert_stderr_has "stderr says the installed hmd is older" "older than"

new_case; install_stub_hmd "$PKG_VER"
wrap_run -- .
if [ ! -e "$MARK" ]; then ok "hmd exactly at the pin: no installer"; else bad "hmd at the pin still triggered the installer"; fi
assert_argv "…and that hmd ran" attack .

new_case; install_stub_hmd "999.0.0"
wrap_run -- .
if [ ! -e "$MARK" ]; then ok "hmd NEWER than the pin: no installer (a newer hmd is never downgraded)"; else bad "a newer hmd triggered the installer — that would downgrade it"; fi
assert_argv "…and the newer hmd ran" attack .

new_case; install_stub_hmd "?"
wrap_run -- .
if [ -e "$MARK" ] && [ "$RC" -eq 0 ]; then ok "hmd whose version cannot be read: treated as too old, the installer ran"; else bad "an unreadable hmd version was trusted (rc=$RC)"; dump; fi

new_case; install_stub_hmd "0.0.1"
wrap_run STUB_INSTALL_MODE=stale -- .
assert_refused_after_install "installer ran but hmd is STILL older than the pin: refused, hmd not run"
assert_stderr_has "…saying why" "refusing to run"

new_case
wrap_run STUB_INSTALL_MODE=fail -- .
assert_refused_after_install "installer exits non-zero: refused, hmd not run"
assert_stderr_has "…reporting the installer's exit status" "installer exited with status 7"

new_case
wrap_run STUB_INSTALL_MODE=no-hmd -- .
assert_refused_after_install "installer succeeded but left no hmd anywhere: refused"
assert_stderr_has "…saying no hmd was found" "no hmd was found"

# ── F. fetch ─────────────────────────────────────────────────────────────────
echo "F. fetch — the network path, driven through a scripted fake https"

FETCH_URL="https://example.invalid/runhmd/install.sh"
fetch_run() {  # <plan json> [wrapper args...] — no local override: the wrapper must fetch
  local plan="$1"; shift
  wrap_run RUNHMD_INSTALL_SCRIPT= RUNHMD_INSTALL_URL="$FETCH_URL" \
    NODE_OPTIONS="--require=$FAKE_HTTPS" FAKE_HTTPS_PLAN="$plan" FAKE_HTTPS_LOG="$WORK/fetch$CASE.log" -- "$@"
}

new_case
PLAN="$(jq -c -n --rawfile body "$INSTALLER" '[{status:302, location:"/runhmd/real/install.sh"},{status:200, body:$body}]')"
fetch_run "$PLAN" .
assert_argv "a 302 with a RELATIVE Location is followed, the body verified, the installer run, hmd run" attack .
if [ "$(sed -n 2p "$WORK/fetch$CASE.log" 2>/dev/null)" = "https://example.invalid/runhmd/real/install.sh" ]; then
  ok "the redirect target was resolved against the request URL"
else
  bad "the redirect was not resolved correctly: $(tr '\n' ' ' < "$WORK/fetch$CASE.log" 2>/dev/null)"; dump
fi

new_case
fetch_run '[{"status":404}]' .
assert_refused "HTTP 404 on the install script: refused"
assert_stderr_has "…naming the status" "HTTP 404"

new_case
fetch_run '[{"status":302,"location":"/a"},{"status":302,"location":"/b"},{"status":302,"location":"/c"},{"status":302,"location":"/d"},{"status":302,"location":"/e"},{"status":302,"location":"/f"},{"status":302,"location":"/g"}]' .
assert_refused "a redirect loop is refused"
assert_stderr_has "…saying too many redirects" "too many redirects"

new_case
PLAN="$(jq -c -n --arg body "#!/usr/bin/env bash
echo tampered" '[{status:200, body:$body}]')"
fetch_run "$PLAN" .
assert_refused "fetched bytes that do not match the pin (a tampered CDN) are refused"

echo ""
echo "runhmd-wrapper.test.sh: $PASS passed, $FAIL failed."
[ "$FAIL" -eq 0 ] || exit 1
exit 0
