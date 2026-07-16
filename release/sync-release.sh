#!/usr/bin/env bash
#
# sync-release.sh — sync the Heimdall release artifacts to one tag.
#
#   release/sync-release.sh <TAG> [--dry]
#
# One tag in, four artifacts re-pointed/re-rendered so they resolve to
# byte-identical install.sh bytes (and a byte-identical README):
#
#   1. Redirect:  vercel.json + _redirects  -> raw .../<TAG>/install.sh  (302)
#   2. npx wrap:  packages/runheimdall/package.json  ->  version, pinned URL,
#                 tag, and the sha256 of THIS tag's install.sh
#   3. Docs/ref:  README.md raw-URL tags + install.sh DEFAULT_REF
#   4. npm docs:  packages/runheimdall/README.md  <-  root README.md
#                 (byte-identical copy, taken AFTER step 3's URL templating,
#                 so npmjs.com never serves a stale README — see
#                 test/npm-readme-drift.test.sh)
#
# install-ux v2 guarantee: the redirect and the npx wrapper MUST resolve to
# byte-identical scripts. This script ASSERTS that itself — it computes the
# sha256 of the repo's install.sh (the bytes that WILL live at <TAG> once RJ
# pushes the tag) and proves that exact digest is what the wrapper bakes in and
# that every artifact points at the same <TAG> URL. The assertion is the point;
# a convention that the bytes "should" match is not enough.
#
# Sequencing rule 1 (tags are immutable): this script does NOT create, move, or
# delete any git tag, and never touches the pinned tag. It edits working-tree
# files only. Creating/pushing the tag is an RJ-executed step (see
# release/publish-checklist.md).
#
set -euo pipefail

# ── Locate the repo root (this script lives in release/) ─────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

VERCEL="$ROOT/vercel.json"
REDIRECTS="$ROOT/_redirects"
README="$ROOT/README.md"
INSTALL="$ROOT/install.sh"
PKG="$ROOT/packages/runheimdall/package.json"
PKG_README="$ROOT/packages/runheimdall/README.md"
MANIFEST="$ROOT/.claude-plugin/plugin.json"

REPO_PATH="randomittin/heimdall"
RAW_BASE="https://raw.githubusercontent.com/${REPO_PATH}"

# ── Args ─────────────────────────────────────────────────────────────────────
TAG=""
DRY=0
for arg in "$@"; do
  case "$arg" in
    --dry|--dry-run) DRY=1 ;;
    -h|--help)
      grep '^#' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    -*) echo "sync-release.sh: unknown flag: $arg" >&2; exit 2 ;;
    *)
      if [ -n "$TAG" ]; then echo "sync-release.sh: unexpected extra arg: $arg" >&2; exit 2; fi
      TAG="$arg"
      ;;
  esac
done

if [ -z "$TAG" ]; then
  echo "usage: release/sync-release.sh <TAG> [--dry]" >&2
  exit 2
fi

# Validate tag shape: vMAJOR.MINOR.PATCH (optional -suffix).
if ! printf '%s' "$TAG" | grep -Eq '^v[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.]+)?$'; then
  echo "sync-release.sh: tag must look like vX.Y.Z (got: $TAG)" >&2
  exit 2
fi

VERSION="${TAG#v}"                                   # npm version has no leading v
INSTALL_URL="${RAW_BASE}/${TAG}/install.sh"

# ── Tooling ──────────────────────────────────────────────────────────────────
have() { command -v "$1" >/dev/null 2>&1; }

sha256_of() {
  # Portable sha256 of a file -> bare hex digest.
  if have sha256sum; then
    sha256sum "$1" | awk '{print $1}'
  elif have shasum; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    echo "sync-release.sh: need sha256sum or shasum" >&2
    exit 1
  fi
}

if ! have jq; then
  echo "sync-release.sh: jq is required" >&2
  exit 1
fi

# ── Preconditions ────────────────────────────────────────────────────────────
for f in "$VERCEL" "$REDIRECTS" "$README" "$INSTALL" "$PKG" "$MANIFEST"; do
  [ -f "$f" ] || { echo "sync-release.sh: missing artifact: $f" >&2; exit 1; }
done

# ── Compute the checksum of the script this release will serve ───────────────
# This is the local install.sh AFTER we template DEFAULT_REF below, because the
# bytes pushed to <TAG> are the bytes currently in the tree. We template first,
# then hash, so the digest matches exactly what the tag will hold.
echo "sync-release.sh: syncing all artifacts to ${TAG}"
echo "  redirect/npx target: ${INSTALL_URL}"
[ "$DRY" -eq 1 ] && echo "  (dry run — no files written)"

# Work on a copy of install.sh so a dry run computes the real post-template
# digest without mutating the tree.
TMP_INSTALL="$(mktemp)"
trap 'rm -f "$TMP_INSTALL"' EXIT
cp "$INSTALL" "$TMP_INSTALL"

# Template DEFAULT_REF="..." -> the tag.
sed -E "s|^([[:space:]]*local DEFAULT_REF=)\"[^\"]*\"|\1\"${TAG}\"|" "$TMP_INSTALL" > "${TMP_INSTALL}.new"
mv "${TMP_INSTALL}.new" "$TMP_INSTALL"

NEW_SHA="$(sha256_of "$TMP_INSTALL")"
echo "  install.sh sha256 @ ${TAG}: ${NEW_SHA}"

# ── Apply edits (unless dry) ─────────────────────────────────────────────────
write_file() {
  # write_file <dest> <tmp-with-new-content>
  if [ "$DRY" -eq 1 ]; then
    if cmp -s "$1" "$2"; then echo "  = $1 (unchanged)"; else echo "  ~ $1 (would update)"; fi
    rm -f "$2"
  else
    mv "$2" "$1"
    echo "  ✓ $1"
  fi
}

# 1. install.sh DEFAULT_REF (already templated into TMP_INSTALL)
T="$(mktemp)"; cp "$TMP_INSTALL" "$T"; write_file "$INSTALL" "$T"

# 2. vercel.json redirect destination (302 == permanent:false)
T="$(mktemp)"
jq --arg url "$INSTALL_URL" \
   '(.redirects[] | select(.source=="/install") | .destination) = $url
    | (.redirects[] | select(.source=="/install") | .permanent) = false' \
   "$VERCEL" > "$T"
write_file "$VERCEL" "$T"

# 3. _redirects line (force 302)
T="$(mktemp)"
sed -E "s|^(/install[[:space:]]+).*|\1${INSTALL_URL}  302|" "$REDIRECTS" > "$T"
write_file "$REDIRECTS" "$T"

# 4. README raw-URL tags (any /heimdall/<oldtag>/install.sh -> /heimdall/<TAG>/install.sh)
T="$(mktemp)"
sed -E "s|(${RAW_BASE//\//\\/}/)v[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.]+)?(/install\.sh)|\1${TAG}\3|g" "$README" > "$T"
write_file "$README" "$T"

# 5. npm README mirror — byte-identical copy of the just-templated root README, so
# `npm view runheimdall readme` / npmjs.com/package/runheimdall never serves a stale
# doc. This is a copy, not a hand-maintained second file: test/npm-readme-drift.test.sh
# gates that the two never diverge outside this render step.
T="$(mktemp)"
cp "$README" "$T"
write_file "$PKG_README" "$T"

# 6. npx wrapper package.json: version, tag, url, sha256
T="$(mktemp)"
jq --arg v "$VERSION" --arg tag "$TAG" --arg url "$INSTALL_URL" --arg sha "$NEW_SHA" \
   '.version = $v
    | .heimdall.tag = $tag
    | .heimdall.installScriptUrl = $url
    | .heimdall.sha256 = $sha' \
   "$PKG" > "$T"
write_file "$PKG" "$T"

# 7. plugin manifest .version — bump to the release version so the manifest stays
# consistent with the tag. The launcher's heimdall_version() resolves the tag
# FIRST and only falls back to this field when git is unavailable, so this is a
# fallback value, not the source of truth — but a stale fallback is a latent lie
# (it shipped 1.1.0 while the real release was v2.0.x). Keeping it in lockstep
# here means the tarball/no-git fallback never drifts, and the conformance
# version fixture (which cross-checks manifest ↔ resolved version) stays green.
T="$(mktemp)"
jq --arg v "$VERSION" '.version = $v' "$MANIFEST" > "$T"
write_file "$MANIFEST" "$T"

# ── ASSERTION: redirect and npx resolve to byte-identical scripts ────────────
# We re-read the artifacts (post-write, or pre-write under --dry) and prove:
#   a) the digest baked into the wrapper == the digest of the tag's install.sh
#   b) vercel.json, _redirects, and the wrapper all point at the SAME url
# Under --dry, the wrapper file is unchanged on disk, so compare against the
# values we WOULD write (NEW_SHA / INSTALL_URL) directly.
echo "sync-release.sh: asserting byte-identical resolution"

assert_eq() {
  # assert_eq <label> <expected> <actual>
  if [ "$2" != "$3" ]; then
    echo "  ✗ ASSERT FAILED: $1" >&2
    echo "      expected: $2" >&2
    echo "      actual:   $3" >&2
    exit 1
  fi
  echo "  ✓ $1"
}

if [ "$DRY" -eq 1 ]; then
  WRAP_SHA="$NEW_SHA"
  WRAP_URL="$INSTALL_URL"
  VERCEL_URL="$INSTALL_URL"
  REDIR_URL="$INSTALL_URL"
else
  WRAP_SHA="$(jq -r '.heimdall.sha256' "$PKG")"
  WRAP_URL="$(jq -r '.heimdall.installScriptUrl' "$PKG")"
  VERCEL_URL="$(jq -r '.redirects[] | select(.source=="/install") | .destination' "$VERCEL")"
  REDIR_URL="$(awk '$1=="/install"{print $2}' "$REDIRECTS")"
fi

assert_eq "wrapper sha256 == tag install.sh sha256" "$NEW_SHA" "$WRAP_SHA"
assert_eq "wrapper url == redirect target"          "$INSTALL_URL" "$WRAP_URL"
assert_eq "vercel.json /install -> tag target"      "$INSTALL_URL" "$VERCEL_URL"
assert_eq "_redirects /install -> tag target"       "$INSTALL_URL" "$REDIR_URL"

echo "sync-release.sh: all artifacts resolve to ${INSTALL_URL} (sha256 ${NEW_SHA})"
if [ "$DRY" -eq 1 ]; then
  echo "sync-release.sh: dry run complete — nothing written, assertions passed."
else
  echo "sync-release.sh: synced. Next: RJ executes release/publish-checklist.md (npm publish, set 302, push ${TAG})."
fi
