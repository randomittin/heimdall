#!/usr/bin/env bash
#
# release-manifest.test.sh — release/sync-release.sh emits release-manifest.json.
#
#   bash test/release-manifest.test.sh    (exit 0 = every case passes)
#
# The manifest is the release asset the site's CI reads
# (https://github.com/randomittin/heimdall/releases/latest/download/release-manifest.json) so the
# marketing site renders its version and installer digest from the release instead of by hand:
#   {"tag":"vX.Y.Z","install_sha256":"<64 hex>","install_url":"…/vX.Y.Z/install.sh","minisig_url":"…/vX.Y.Z/install.sh.minisig"}
# This proves, in a throwaway fake plugin repo (the real tree is never written), that sync-release.sh:
#   1. writes exactly those four keys, in that order, for the tag it was given;
#   2. computes install_sha256 from the SAME bytes the npx wrapper bakes in (never recomputed apart);
#   3. writes nothing under --dry;
#   4. defaults to the ignored build-output path .heimdall/release/ (so the version sweeps never read
#      it as a hand-typed pin) and honours RELEASE_MANIFEST_OUT;
#   5. DIES when its own manifest would disagree with the release — three mutants of the script
#      (wrong digest, tag without the leading v, manifest step deleted) must each be caught.
# And that the human path is wired: release/ship.sh uploads the asset, publish-checklist.md names it.
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SELF_DIR/.." && pwd)"
SYNC_SRC="$REPO/release/sync-release.sh"

PASS=0; FAIL=0
ok()  { printf '  \033[32mPASS\033[0m %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAIL=$((FAIL+1)); }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/release-manifest-test.XXXXXX")"
[ -n "$WORK" ] || { echo "FATAL: mktemp failed" >&2; exit 2; }
trap 'rm -rf "$WORK" 2>/dev/null || true' EXIT

echo "release-manifest harness  sync=$SYNC_SRC"
echo "--------------------------------------------------------------------"

OLD_TAG="v0.0.1"; NEW_TAG="v9.9.9"
RAW="https://raw.githubusercontent.com/randomittin/heimdall"
OLD_SHA="0000000000000000000000000000000000000000000000000000000000000000"

make_fake_plugin() {  # $1 = dest dir, $2 = sync script to install as release/sync-release.sh
  local d="$1"
  mkdir -p "$d/release" "$d/packages/runheimdall" "$d/packages/runhmd" "$d/.claude-plugin"
  cp "$2" "$d/release/sync-release.sh"
  printf '{"redirects":[{"source":"/install","destination":"%s/%s/install.sh","permanent":true}]}\n' "$RAW" "$OLD_TAG" > "$d/vercel.json"
  printf '/install  %s/%s/install.sh  301\n' "$RAW" "$OLD_TAG" > "$d/_redirects"
  printf '# Heimdall\n\nInstall: %s/%s/install.sh\n' "$RAW" "$OLD_TAG" > "$d/README.md"
  printf '#!/usr/bin/env bash\ninstall() {\n  local DEFAULT_REF="%s"\n  echo "$DEFAULT_REF"\n}\n' "$OLD_TAG" > "$d/install.sh"
  printf '{"version":"0.0.1","heimdall":{"tag":"%s","installScriptUrl":"%s/%s/install.sh","sha256":"%s"}}\n' "$OLD_TAG" "$RAW" "$OLD_TAG" "$OLD_SHA" > "$d/packages/runheimdall/package.json"
  printf '{"version":"0.0.1","heimdall":{"tag":"%s","installScriptUrl":"%s/%s/install.sh","sha256":"%s","defaultCommand":"attack"}}\n' "$OLD_TAG" "$RAW" "$OLD_TAG" "$OLD_SHA" > "$d/packages/runhmd/package.json"
  printf '{"version":"0.0.1"}\n' > "$d/.claude-plugin/plugin.json"
}

# run_sync <plugin-dir> [args...] — sync-release.sh with the sibling site pointed nowhere (a WARN, never a push).
run_sync() {
  local d="$1"; shift
  HEIMDALL_SITE_DIR="$WORK/no-such-site" bash "$d/release/sync-release.sh" "$@" 2>&1
}

# ── 1+2. a real run writes the four keys, in order, from the wrapper's own digest ──
P1="$WORK/p1"; make_fake_plugin "$P1" "$SYNC_SRC"
OUT1="$WORK/out1/release-manifest.json"
if RELEASE_MANIFEST_OUT="$OUT1" run_sync "$P1" "$NEW_TAG" >"$WORK/run1.log"; then ok "sync-release.sh $NEW_TAG exits 0 in a fake plugin repo"; else bad "sync-release.sh $NEW_TAG failed: $(tail -3 "$WORK/run1.log")"; fi
if [ -f "$OUT1" ]; then ok "release-manifest.json written to RELEASE_MANIFEST_OUT"; else bad "no manifest at $OUT1"; fi
[ "$(jq -c 'keys_unsorted' "$OUT1" 2>/dev/null)" = '["tag","install_sha256","install_url","minisig_url"]' ] \
  && ok "keys are exactly tag, install_sha256, install_url, minisig_url, in that order" || bad "key set/order wrong: $(jq -c 'keys_unsorted' "$OUT1" 2>/dev/null)"
jq -e --arg t "$NEW_TAG" --arg raw "$RAW" \
   '.tag==$t and .install_url==($raw+"/"+$t+"/install.sh") and .minisig_url==("https://github.com/randomittin/heimdall/releases/download/"+$t+"/install.sh.minisig") and (.install_sha256|test("^[0-9a-f]{64}$"))' \
   "$OUT1" >/dev/null 2>&1 && ok "tag, install_url, minisig_url and a 64-hex install_sha256 for $NEW_TAG" || bad "manifest fields do not describe $NEW_TAG"
TAG_BYTES_SHA="$(shasum -a 256 "$P1/install.sh" | awk '{print $1}')"
[ "$(jq -r '.install_sha256' "$OUT1" 2>/dev/null)" = "$TAG_BYTES_SHA" ] \
  && ok "install_sha256 == sha256 of the templated install.sh the tag will hold" || bad "install_sha256 is not the digest of the tag's install.sh"
[ "$(jq -r '.install_sha256' "$OUT1" 2>/dev/null)" = "$(jq -r '.heimdall.sha256' "$P1/packages/runhmd/package.json")" ] \
  && ok "install_sha256 == the digest the npx wrapper bakes in" || bad "manifest digest disagrees with the wrapper's"

# ── 3. --dry writes nothing ──
P2="$WORK/p2"; make_fake_plugin "$P2" "$SYNC_SRC"
OUT2="$WORK/out2/release-manifest.json"
RELEASE_MANIFEST_OUT="$OUT2" run_sync "$P2" "$NEW_TAG" --dry >"$WORK/run2.log"
[ ! -e "$OUT2" ] && ok "--dry writes no manifest" || bad "--dry wrote $OUT2"
grep -q 'would write' "$WORK/run2.log" && ok "--dry says it would write the manifest" || bad "--dry did not mention the manifest"

# ── 4. the default path is the ignored build-output dir ──
P3="$WORK/p3"; make_fake_plugin "$P3" "$SYNC_SRC"
run_sync "$P3" "$NEW_TAG" >/dev/null
[ -f "$P3/.heimdall/release/release-manifest.json" ] && ok "default output is .heimdall/release/release-manifest.json" || bad "no manifest at the default path"

# ── 5. mutants of the script: each must be caught by sync-release.sh's own assertion or by this suite ──
mutant_dies() {  # <label> <sed-expr>
  local label="$1" expr="$2" d="$WORK/m-$RANDOM" msrc="$WORK/m-src-$RANDOM.sh"
  sed -E "$expr" "$SYNC_SRC" > "$msrc"
  make_fake_plugin "$d" "$msrc"
  if RELEASE_MANIFEST_OUT="$d/out.json" run_sync "$d" "$NEW_TAG" >"$d.log"; then
    bad "mutant not caught: $label (sync-release.sh exited 0)"
  else
    ok "mutant caught: $label"
  fi
}
mutant_dies "manifest digest wrong" 's|--arg sha "\$NEW_SHA" --arg url "\$INSTALL_URL" --arg sig|--arg sha "0000000000000000000000000000000000000000000000000000000000000001" --arg url "$INSTALL_URL" --arg sig|'
mutant_dies "manifest tag without the leading v" 's|jq -n --arg tag "\$TAG"|jq -n --arg tag "$VERSION"|'

DM="$WORK/m-nostep"; MSRC="$WORK/m-nostep.sh"
awk '/^# ── 9\. release-manifest.json/{skip=1} skip&&/^fi$/{skip=0; next} !skip{print}' "$SYNC_SRC" > "$MSRC"
make_fake_plugin "$DM" "$MSRC"
RELEASE_MANIFEST_OUT="$DM/out.json" run_sync "$DM" "$NEW_TAG" >/dev/null
[ ! -f "$DM/out.json" ] && ok "mutant caught: with the manifest step deleted no file appears, and the assertions above would fail" || bad "the step-deleted mutant still produced a manifest (the cases above are vacuous)"

# ── the human path is wired ──
grep -q 'release-manifest.json' "$REPO/release/ship.sh" && ok "release/ship.sh attaches release-manifest.json to the Release" || bad "release/ship.sh never mentions release-manifest.json"
grep -q 'release-manifest.json' "$REPO/release/publish-checklist.md" && ok "release/publish-checklist.md names the manifest asset" || bad "publish-checklist.md never mentions release-manifest.json"

echo ""
echo "release-manifest.test.sh: $PASS passed, $FAIL failed."
[ "$FAIL" -eq 0 ]
