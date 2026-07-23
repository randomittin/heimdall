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
# NPM_STUB_MODE:  publish-ok | publish-ok-lag | publish-fail | already-published | not-authed | not-owner
#   publish-ok-lag: the publish SUCCEEDS (prints `+ pkg@ver`) but the version is NEVER recorded
#   as visible — `npm view pkg@ver` keeps returning E404. Simulates npm's read-replica
#   propagation lag: a genuinely-published version a read replica has not yet caught up to.
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
    # publish-ok-lag: publish succeeds but the write is NOT made visible to `npm view` — the
    # read replica lags. Every other ok mode records the marker so readback sees it immediately.
    [ "$mode" = "publish-ok-lag" ] || { mkdir -p "$state"; : > "$state/published-$ver"; }
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

# §3 positioning is DECIDED (candidate A — "Nothing ships unproven." + 12 keywords, committed
# 0185059). A decided §3 must NOT cry wolf on every ship, so the notice is now SILENT here.
# (The notice is authoritatively unit-tested BOTH ways — decided-silent and undecided-loud — in
# Case 9; this only guards that a decided ship does not re-surface the PENDING warning.)
if ! grep -q 'npm positioning is PENDING' "$DRY"; then
  ok "--dry-run does NOT cry wolf on the (decided) §3 positioning"
else
  bad "--dry-run still surfaced the PENDING §3 notice though §3 is decided"; sed 's/^/    /' "$DRY" >&2
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

# ── Case 7: the real publish runs on the TTY, NOT wrapped in command-substitution ──
# ROOT-CAUSE GUARD for the EOTP dead-end. RJ's npm 2FA is a passkey/WebAuthn — it emits no
# typed OTP, so npm must use its browser/web auth, which only runs when `npm publish` is
# attached to a real TTY. Wrapping the publish in $(...) (or piping/tee'ing it) hands npm a
# non-TTY stdout → npm abandons web auth → demands a typed --otp → `npm error code EOTP`, a
# dead-end for a passkey. This case goes red if that regression ever returns.
# Strip full-line comments first: ship.sh's own comment ILLUSTRATES the broken $(...) form on
# purpose (so a reader sees what not to do), and only executable lines can actually regress.
if grep -vE '^[[:space:]]*#' "$SHIP" | grep -Eq '\$\([^)]*npm publish'; then
  bad "regression: 'npm publish' is wrapped in command-substitution \$(...) — kills TTY web auth (EOTP for passkey 2FA)"
  grep -vE '^[[:space:]]*#' "$SHIP" | grep -nE '\$\([^)]*npm publish' | sed 's/^/    /' >&2
else
  ok "'npm publish' is NOT captured in \$(...) — it runs on the terminal, so npm web/passkey auth works"
fi
if grep -Fq '( cd "$dir" && npm publish --access public --auth-type=web )' "$SHIP"; then
  ok "the real publish runs directly (inherits ship.sh's TTY) with --auth-type=web pinned"
else
  bad "could not find the direct, TTY-attached 'npm publish --access public --auth-type=web' invocation"
fi

# ── Case 8: a LAGGING post-publish readback is NON-FATAL (publish already succeeded) ──
# ROOT-CAUSE GUARD for the false-negative that failed the real v2.3.1 ship: npm returned
# `+ runheimdall@2.3.1` (publish SUCCEEDED) but the post-publish readback polled a read replica
# that had not yet propagated the write, and ship.sh DIED — reporting a succeeded ship as failed.
# npm's read replicas lag a write by 30s–several minutes, so the readback must POLL patiently and,
# on timeout, WARN and exit 0 — never die. A REAL publish failure is a separate path (Case 3,
# still dies). SHIP_READBACK_MAX_TRIES/DELAY are overridden here so the loop times out instantly.
FIX8="$WORK/pkglag"; mkdir -p "$FIX8"
printf '{"name":"runheimdall","version":"2.2.6","files":["bin/runheimdall.js"]}\n' > "$FIX8/package.json"
C8="$WORK/c8.out"
(
  cd "$REPO"
  export NPM_STUB_STATE="$WORK/c8state" NPM_STUB_MODE="publish-ok-lag" SHIP_NPM_DIR="$FIX8"
  export SHIP_READBACK_MAX_TRIES=2 SHIP_READBACK_DELAY=0
  PATH="$BIN_STUB:$PATH"
  # shellcheck disable=SC1090
  SHIP_SOURCE_ONLY=1 . "$SHIP"
  REPO_ROOT="$REPO"
  publish_npm "2.2.6"
) >"$C8" 2>&1
c8_rc=$?
if [ "$c8_rc" -eq 0 ]; then
  ok "publish_npm treats a LAGGING readback as NON-FATAL (exit 0 — a succeeded publish is not failed by a slow replica)"
else
  bad "publish_npm DIED on a lagging readback (rc=$c8_rc) — false-negative regression"; sed 's/^/    /' "$C8" >&2
fi
if grep -q 'readback still lagging' "$C8" && grep -q 'npm view runheimdall version' "$C8"; then
  ok "the lagging readback WARNS and names the manual verification (npm view runheimdall version)"
else
  bad "the lagging readback did not warn / name the manual verify"; sed 's/^/    /' "$C8" >&2
fi
# A lag is downstream of a REAL, successful publish — the '+ pkg@ver' publish must have run.
if grep -q 'published runheimdall@2.2.6 to npm' "$C8"; then
  ok "the publish itself still ran (the lag is a read-replica delay, not a no-op publish)"
else
  bad "publish did not run before the readback"; sed 's/^/    /' "$C8" >&2
fi
# The lag path must NOT falsely claim the registry-confirmed line — that is reserved for a real hit.
if ! grep -q 'verified runheimdall@2.2.6 is live on the registry' "$C8"; then
  ok "the lag path does NOT falsely claim registry-confirmed liveness (only a real hit prints that)"
else
  bad "the lag path printed the registry-confirmed line without an actual readback hit"; sed 's/^/    /' "$C8" >&2
fi

# ── Case 9: §3 positioning notice — SILENT when decided, LOUD when genuinely undecided ──
# BUG: ship.sh kept crying "npm positioning is PENDING RJ's canonical §3 decision" on every ship
# even though §3 is DECIDED (candidate A — description ends "Nothing ships unproven." + the
# 12-term keyword list, committed 0185059). The notice now keys on the canonical tagline in
# package.json .description: present → decided → SILENT; absent → undecided → still LOUD (npm
# versions are immutable, so an undecided ship genuinely must warn). Both directions asserted.
C9D="$WORK/c9d.out"
(
  cd "$REPO"
  PATH="$BIN_STUB:$PATH"
  # shellcheck disable=SC1090
  SHIP_SOURCE_ONLY=1 . "$SHIP"
  REPO_ROOT="$REPO"
  npm_positioning_notice           # the REAL wrapper package.json — §3 is decided
) >"$C9D" 2>&1
if [ ! -s "$C9D" ] || ! grep -q 'PENDING' "$C9D"; then
  ok "npm_positioning_notice is SILENT once §3 is decided (description carries \"Nothing ships unproven.\")"
else
  bad "npm_positioning_notice STILL warns PENDING though §3 is decided"; sed 's/^/    /' "$C9D" >&2
fi
# Genuinely undecided: a package.json whose .description lacks the canonical tagline.
UND="$WORK/pkgundecided"; mkdir -p "$UND"
printf '{"name":"runheimdall","version":"2.2.6","description":"pre-launch placeholder text","files":["bin/runheimdall.js"]}\n' > "$UND/package.json"
C9U="$WORK/c9u.out"
(
  cd "$REPO"
  export SHIP_NPM_DIR="$UND"
  PATH="$BIN_STUB:$PATH"
  # shellcheck disable=SC1090
  SHIP_SOURCE_ONLY=1 . "$SHIP"
  REPO_ROOT="$REPO"
  npm_positioning_notice
) >"$C9U" 2>&1
if grep -q 'npm positioning is PENDING' "$C9U"; then
  ok "npm_positioning_notice STILL warns when §3 is genuinely undecided (pre-launch description)"
else
  bad "npm_positioning_notice went silent on a genuinely undecided §3 — the warning was lost, not fixed"; sed 's/^/    /' "$C9U" >&2
fi

echo ""
echo "ship-npm.test.sh: $PASS passed, $FAIL failed."
[ "$FAIL" -eq 0 ] || exit 1
exit 0
