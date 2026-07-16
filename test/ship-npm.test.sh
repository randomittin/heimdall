#!/usr/bin/env bash
#
# ship-npm.test.sh — acceptance for release/ship.sh's npm-publish path.
#
#   bash test/ship-npm.test.sh    (exit 0 = all cases pass)
#
# Proves, WITHOUT publishing anything real to the registry, that ship.sh:
#   1. --dry-run prints the EXACT `npm publish --access public` invocation, the resolved dir,
#      the resolved version and the `files` allowlist — and publishes NOTHING;
#   2. is idempotent: a version already on the registry is a LOUD skip, exit 0 (never an
#      ambiguous E403 "cannot publish over previously published version");
#   3. a simulated npm-publish failure makes the publish path exit NON-ZERO and REPRINTS
#      npm's own error (loud fail, no swallow);
#   4. preflight HARD-FAILS (non-zero) when npm is unauthenticated — it does not warn and
#      exit 0, which is the bug that let ship.sh print "✓ Shipped & verified" having
#      published nothing;
#   5. a package.json/manifest version mismatch is REFUSED rather than published;
#   6. the happy path publishes and then READS THE VERSION BACK off the registry.
#
# R6 (checks must be able to fail): every case asserts a behaviour a regression would flip.
# Case 3 and case 4 are the corrupt-and-confirm proofs — they stub npm to fail and assert a
# non-zero exit. If ship.sh regressed to `|| true` / warn-and-continue, they go red.
#
# WHY A STUB AND NOT THE REAL REGISTRY: an npm publish is effectively irreversible (unpublish
# is blocked after 72h, and a version number can never be reused). The publish path must
# therefore be provable without ever exercising it for real.
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SELF_DIR/.." && pwd)"
SHIP="$REPO/release/ship.sh"

PASS=0; FAIL=0
ok()  { printf '  \033[32mPASS\033[0m %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAIL=$((FAIL+1)); }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/ship-npm-test.XXXXXX")"
cleanup() { rm -rf "$WORK" 2>/dev/null || true; }
trap cleanup EXIT

echo "ship-npm harness  ship=$SHIP"
echo "--------------------------------------------------------------------"

# ── An npm stub whose behaviour is driven by env vars, first on PATH ─────────
# NPM_STUB_MODE:  publish-ok | publish-fail | already-published | not-authed | not-owner
# NPM_STUB_STATE: dir; a $NPM_STUB_STATE/published-<version> marker == "that version is live".
# NPM_STUB_USER:  the identity `npm whoami` reports (default: rj).
BIN_STUB="$WORK/stubbin"
mkdir -p "$BIN_STUB"
cat > "$BIN_STUB/npm" <<'STUB'
#!/usr/bin/env bash
sub="${1:-}"
state="${NPM_STUB_STATE:-$PWD/.npmstate}"
mode="${NPM_STUB_MODE:-publish-ok}"
user="${NPM_STUB_USER:-rj}"

# Positional args with flags (--prefer-online, --access public) stripped, so the stub reads
# the same whether or not ship.sh passes cache/access flags.
args=(); skip=0
for a in "$@"; do
  [ "$skip" = "1" ] && { skip=0; continue; }
  case "$a" in
    --access) skip=1 ;;
    --*) ;;
    *) args+=("$a") ;;
  esac
done

case "$sub" in
  whoami)
    [ "$mode" = "not-authed" ] && { echo "npm ERR! code ENEEDAUTH (simulated)" >&2; exit 1; }
    echo "$user"; exit 0 ;;
  view)
    spec="${args[1]:-}"
    case "$spec" in
      *@*)  # pkg@version — is that EXACT version live?
        ver="${spec##*@}"
        [ "$mode" = "already-published" ] && { echo "$ver"; exit 0; }
        [ -f "$state/published-$ver" ] && { echo "$ver"; exit 0; }
        echo "npm ERR! code E404 (simulated: $spec is not in the registry)" >&2; exit 1 ;;
      *)    # bare pkg — does the package exist at all?
        [ "${NPM_STUB_PKG_EXISTS:-1}" = "1" ] || { echo "npm ERR! code E404 (simulated)" >&2; exit 1; }
        echo "${NPM_STUB_LATEST:-2.0.5}"; exit 0 ;;
    esac ;;
  owner)
    [ "$mode" = "not-owner" ] && { echo "someone-else <nope@example.com>"; exit 0; }
    echo "$user <$user@example.com>"; exit 0 ;;
  publish)
    [ "$mode" = "publish-fail" ] && {
      echo "npm ERR! code E403" >&2
      echo "npm ERR! 403 Forbidden - PUT https://registry.npmjs.org/runheimdall (simulated)" >&2
      exit 1; }
    ver="$(sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' ./package.json | head -1)"
    mkdir -p "$state"; : > "$state/published-$ver"
    echo "+ runheimdall@$ver"; exit 0 ;;
  *) exit 0 ;;
esac
STUB
chmod +x "$BIN_STUB/npm"

# ── Case 1: --dry-run prints the exact invocation and publishes NOTHING ──────
DRY="$WORK/dry.out"
DRY_STATE="$WORK/c1state"; mkdir -p "$DRY_STATE"
(
  cd "$REPO"
  export NPM_STUB_STATE="$DRY_STATE" NPM_STUB_MODE="publish-ok"
  PATH="$BIN_STUB:$PATH" "$SHIP" --dry-run
) >"$DRY" 2>&1
dry_rc=$?
NEXT="$( cd "$REPO" && "$SHIP" --print-next )"
PKG_DIR="$REPO/packages/runheimdall"

if [ "$dry_rc" -eq 0 ]; then ok "--dry-run exits 0"; else bad "--dry-run exit=$dry_rc"; sed 's/^/    /' "$DRY" >&2; fi

if grep -Fq "cd $PKG_DIR && npm publish --access public" "$DRY"; then
  ok "--dry-run prints the exact 'cd <dir> && npm publish --access public' command"
else
  bad "--dry-run did not print the exact npm publish command"; sed 's/^/    /' "$DRY" >&2
fi

if grep -Eq "publish version : ${NEXT}" "$DRY"; then
  ok "--dry-run prints the resolved publish version ($NEXT)"
else
  bad "--dry-run did not print the resolved version $NEXT"; sed 's/^/    /' "$DRY" >&2
fi

# The `files` allowlist is what actually lands in the tarball — dry-run must show it.
files_shown=1
while IFS= read -r f; do
  grep -Fq -- "- $f" "$DRY" || { files_shown=0; echo "    missing from dry-run output: $f" >&2; }
done < <(jq -r '.files[]? // empty' "$PKG_DIR/package.json")
if [ "$files_shown" -eq 1 ]; then
  ok "--dry-run prints the files allowlist contents"
else
  bad "--dry-run omitted files allowlist entries"
fi

# Nothing was published: the stub records every publish as a marker file.
if ! ls "$DRY_STATE"/published-* >/dev/null 2>&1; then
  ok "--dry-run published NOTHING (no publish reached the stub)"
else
  bad "--dry-run actually invoked npm publish"; ls "$DRY_STATE" >&2
fi

# The pending-positioning notice must be loud at the npm stage (RJ publishes twice otherwise).
if grep -q 'npm positioning is PENDING' "$DRY"; then
  ok "--dry-run surfaces the pending §3 positioning decision"
else
  bad "--dry-run did not surface the pending positioning notice"; sed 's/^/    /' "$DRY" >&2
fi

# ── Case 2: already published -> LOUD skip, exit 0 (idempotent re-run) ───────
C2="$WORK/c2.out"
(
  cd "$REPO"
  export NPM_STUB_STATE="$WORK/c2state" NPM_STUB_MODE="already-published"
  PATH="$BIN_STUB:$PATH"
  # shellcheck disable=SC1090
  SHIP_SOURCE_ONLY=1 . "$SHIP"
  REPO_ROOT="$REPO"
  publish_npm "$(read_version)"
) >"$C2" 2>&1
c2_rc=$?
if [ "$c2_rc" -eq 0 ] && grep -q 'ALREADY published — skipping' "$C2"; then
  ok "publish_npm SKIPS an already-published version LOUDLY (idempotent, exit 0)"
else
  bad "publish_npm did not take the idempotent skip path (rc=$c2_rc)"; sed 's/^/    /' "$C2" >&2
fi
if ! ls "$WORK/c2state"/published-* >/dev/null 2>&1; then
  ok "the idempotent skip did not re-invoke npm publish"
else
  bad "the skip path published anyway"
fi

# ── Case 3: a simulated npm publish failure exits NON-ZERO ───────────────────
# THE anti-silent-swallow assertion. If ship.sh ever regresses to `|| true` or a warn, this
# case goes red — which is the whole point of it existing.
C3="$WORK/c3.out"
(
  cd "$REPO"
  export NPM_STUB_STATE="$WORK/c3state" NPM_STUB_MODE="publish-fail"
  PATH="$BIN_STUB:$PATH"
  # shellcheck disable=SC1090
  SHIP_SOURCE_ONLY=1 . "$SHIP"
  REPO_ROOT="$REPO"
  publish_npm "$(read_version)"
) >"$C3" 2>&1
c3_rc=$?
if [ "$c3_rc" -ne 0 ]; then
  ok "publish_npm exits NON-ZERO on an npm publish failure (rc=$c3_rc — no silent swallow)"
else
  bad "publish_npm SWALLOWED an npm publish failure and exited 0"; sed 's/^/    /' "$C3" >&2
fi
if grep -q '403 Forbidden' "$C3"; then
  ok "npm's stderr is REPRINTED on failure (operator sees the reason)"
else
  bad "npm failure reason was not surfaced"; sed 's/^/    /' "$C3" >&2
fi
if grep -q -- '--npm-only' "$C3"; then
  ok "the failure names the recovery path (release/ship.sh --npm-only)"
else
  bad "the failure did not name a recovery path"; sed 's/^/    /' "$C3" >&2
fi

# ── Case 4: unauthenticated npm HARD-FAILS in preflight (never warn-and-exit-0) ──
C4="$WORK/c4.out"
(
  cd "$REPO"
  export NPM_STUB_STATE="$WORK/c4state" NPM_STUB_MODE="not-authed"
  PATH="$BIN_STUB:$PATH"
  # shellcheck disable=SC1090
  SHIP_SOURCE_ONLY=1 . "$SHIP"
  REPO_ROOT="$REPO"
  preflight_npm_prereqs
) >"$C4" 2>&1
c4_rc=$?
if [ "$c4_rc" -ne 0 ]; then
  ok "preflight_npm_prereqs HARD-FAILS when npm is unauthenticated (rc=$c4_rc)"
else
  bad "preflight_npm_prereqs warned and exited 0 on an unauthenticated npm"; sed 's/^/    /' "$C4" >&2
fi
if grep -q 'ENEEDAUTH' "$C4"; then
  ok "npm whoami's stderr is REPRINTED (not 2>/dev/null'd away)"
else
  bad "npm whoami failure reason was swallowed"; sed 's/^/    /' "$C4" >&2
fi
# The exit code alone is NOT enough to prove the auth check is a hard gate: if the die were
# downgraded to a warn, preflight would fall through and still exit non-zero later — on the
# OWNERSHIP check, because the un-authed `whoami` output is not in the owner list. That is a
# pass for the wrong reason. The discriminator is that the auth SUCCESS line must never be
# reached: a warn-and-continue prints "authenticated as npm ERR! …", a die does not print it.
if ! grep -q 'npm prereqs: authenticated as' "$C4"; then
  ok "the auth failure STOPS preflight (never reports success on an un-authed npm)"
else
  bad "preflight warned and CONTINUED past an un-authed npm (reported it as authenticated)"
  sed 's/^/    /' "$C4" >&2
fi

# ── Case 5: a version mismatch is REFUSED, not published ─────────────────────
# package.json is a RENDERED surface (sync-release.sh re-points it from the manifest). If it
# disagrees with the version being shipped, the sync did not run — publishing a mislabelled
# tarball to an immutable registry is unrecoverable, so refuse.
FIX="$WORK/pkgfix"; mkdir -p "$FIX"
printf '{"name":"runheimdall","version":"0.0.1","files":["bin/runheimdall.js"]}\n' > "$FIX/package.json"
C5="$WORK/c5.out"
(
  cd "$REPO"
  export NPM_STUB_STATE="$WORK/c5state" NPM_STUB_MODE="publish-ok" SHIP_NPM_DIR="$FIX"
  PATH="$BIN_STUB:$PATH"
  # shellcheck disable=SC1090
  SHIP_SOURCE_ONLY=1 . "$SHIP"
  REPO_ROOT="$REPO"
  publish_npm "2.2.6"
) >"$C5" 2>&1
c5_rc=$?
if [ "$c5_rc" -ne 0 ] && grep -q 'Refusing to publish a mismatched version' "$C5"; then
  ok "publish_npm REFUSES a package.json/manifest version mismatch (rc=$c5_rc)"
else
  bad "publish_npm did not refuse a version mismatch (rc=$c5_rc)"; sed 's/^/    /' "$C5" >&2
fi
if ! ls "$WORK/c5state"/published-* >/dev/null 2>&1; then
  ok "the mismatch refusal published nothing"
else
  bad "the mismatch path published anyway"
fi

# ── Case 6: happy path publishes, then READS THE VERSION BACK ────────────────
FIX6="$WORK/pkgok"; mkdir -p "$FIX6"
printf '{"name":"runheimdall","version":"2.2.6","files":["bin/runheimdall.js"]}\n' > "$FIX6/package.json"
C6="$WORK/c6.out"
(
  cd "$REPO"
  export NPM_STUB_STATE="$WORK/c6state" NPM_STUB_MODE="publish-ok" SHIP_NPM_DIR="$FIX6"
  PATH="$BIN_STUB:$PATH"
  # shellcheck disable=SC1090
  SHIP_SOURCE_ONLY=1 . "$SHIP"
  REPO_ROOT="$REPO"
  publish_npm "2.2.6"
) >"$C6" 2>&1
c6_rc=$?
if [ "$c6_rc" -eq 0 ] && grep -q 'published runheimdall@2.2.6 to npm' "$C6"; then
  ok "publish_npm publishes on the happy path (exit 0)"
else
  bad "publish_npm happy path failed (rc=$c6_rc)"; sed 's/^/    /' "$C6" >&2
fi
if grep -q 'verified runheimdall@2.2.6 is live on the registry' "$C6"; then
  ok "publish_npm READS THE VERSION BACK off the registry (no silent no-op)"
else
  bad "publish_npm did not read the published version back"; sed 's/^/    /' "$C6" >&2
fi

echo ""
echo "ship-npm.test.sh: $PASS passed, $FAIL failed."
[ "$FAIL" -eq 0 ] || exit 1
exit 0
