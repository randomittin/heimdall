#!/usr/bin/env bash
#
# banner-version.test.sh — acceptance for the STARTUP BANNER version string.
#
# The banner printed a STALE v2.0.18 while the shipped manifest read 2.1.0: the
# resolver put the git tag FIRST, so an installed plugin clone whose nearest
# reachable tag lagged the manifest shadowed the truth. The fix makes the banner
# authoritative on .claude-plugin/plugin.json (the manifest ships WITH the code),
# with the git tag as a manifest-unreadable fallback only.
#
# Guarantees proved (white-box: banner_version() is extracted + sourced):
#   1. MANIFEST IS SOURCE OF TRUTH — banner_version() returns the plugin.json
#      .version, prefixed v, for the REAL repo (== 2.1.0 today).
#   2. NOT SHADOWED BY A STALE TAG — with a manifest reading a synthetic 9.9.9 the
#      resolver returns v9.9.9 EVEN IF a nearest git tag says otherwise.
#   3. FALLBACK — with NO manifest, it defers to heimdall_version() (git-tag) and
#      still yields a truthful semver rather than nothing.
#   4. WIRED — print_banner() calls banner_version(), NOT the git-first
#      heimdall_version(), for its version line.
#   5. hmd version UNCHANGED — the `version` subcommand still resolves git-tag
#      first (heimdall_version), so its conformance contract is untouched.
#
# Usage:  test/banner-version.test.sh   (exit 0 = all guarantees hold)
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SELF_DIR/.." && pwd)"
BIN="$REPO/bin/heimdall"
MANIFEST_VER="$(jq -r '.version // empty' "$REPO/.claude-plugin/plugin.json" 2>/dev/null)"

PASS=0; FAIL=0
ok()  { printf '  \033[32mPASS\033[0m %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAIL=$((FAIL+1)); }

# Extract a top-level bash function body (opening `name() {` .. first col-0 `}`).
extract_fn() { sed -n "/^$1() {/,/^}/p" "$BIN"; }

echo "banner-version harness  repo=$REPO  manifest=$MANIFEST_VER"
echo "--------------------------------------------------------------------"

[ -n "$MANIFEST_VER" ] && ok "plugin.json .version is readable ($MANIFEST_VER)" || bad "could not read plugin.json .version"

FN_HV="$(extract_fn heimdall_version)"
FN_BV="$(extract_fn banner_version)"
[ -n "$FN_BV" ] && ok "banner_version() exists in bin/heimdall" || bad "banner_version() not found — banner still uses the git-first resolver"

# ── 1. MANIFEST IS SOURCE OF TRUTH (real repo) ──
GOT="$(PLUGIN_DIR="$REPO" bash -c "$FN_HV; $FN_BV; banner_version" 2>/dev/null)"
[ "$GOT" = "v${MANIFEST_VER#v}" ] \
  && ok "banner_version() == manifest version ($GOT)" \
  || bad "banner_version() returned '$GOT', expected 'v${MANIFEST_VER#v}'"

# ── 2. NOT SHADOWED BY A STALE TAG ──
# A fake plugin root whose manifest reads 9.9.9. Even inside THIS git repo (whose
# real tag is NOT 9.9.9), the manifest must win.
FAKE="$(mktemp -d)"; mkdir -p "$FAKE/.claude-plugin"
printf '{"version":"9.9.9"}\n' > "$FAKE/.claude-plugin/plugin.json"
GOT2="$(PLUGIN_DIR="$FAKE" bash -c "cd '$REPO'; $FN_HV; $FN_BV; banner_version" 2>/dev/null)"
[ "$GOT2" = "v9.9.9" ] \
  && ok "manifest wins over any git tag (got v9.9.9)" \
  || bad "manifest NOT authoritative — got '$GOT2', expected v9.9.9"

# ── 3. FALLBACK when manifest is absent ──
# Model the real fallback: PLUGIN_DIR is a git repo WITH a tag but NO manifest.
# banner_version() must then defer to heimdall_version() (git-tag) and yield it.
EMPTY="$(mktemp -d)"
( cd "$EMPTY" && git init -q && git config user.email t@t && git config user.name t \
  && git commit -q --allow-empty -m init && git tag v3.4.5 ) >/dev/null 2>&1
GOT3="$(PLUGIN_DIR="$EMPTY" bash -c "$FN_HV; $FN_BV; banner_version" 2>/dev/null)"
[ "$GOT3" = "v3.4.5" ] \
  && ok "no manifest -> git-tag fallback yields the tag ($GOT3)" \
  || bad "fallback did not defer to the git tag (got '$GOT3', expected v3.4.5)"
rm -rf "$FAKE" "$EMPTY"

# ── 4. WIRED — print_banner uses banner_version, not heimdall_version ──
PB="$(sed -n '/^print_banner() {/,/^}/p' "$BIN")"
grep -q 'banner_version' <<<"$PB" \
  && ok "print_banner() wires banner_version()" \
  || bad "print_banner() does not call banner_version()"
grep -qE '_ver="\$\(heimdall_version\)"' <<<"$PB" \
  && bad "print_banner() still calls the git-first heimdall_version() for its version line" \
  || ok "print_banner() no longer uses the git-first heimdall_version() for its version line"

# ── 5. hmd version UNCHANGED (still git-tag first via heimdall_version) ──
VER_ARM="$(sed -n '/version|--version|-v|-V)/,/;;/p' "$BIN")"
grep -q 'heimdall_version' <<<"$VER_ARM" \
  && ok "hmd version still resolves via heimdall_version() (git-tag first)" \
  || bad "hmd version arm no longer uses heimdall_version() — conformance contract broken"

echo ""
echo "banner-version.test.sh: $PASS passed, $FAIL failed."
[ "$FAIL" -eq 0 ] || exit 1
exit 0
