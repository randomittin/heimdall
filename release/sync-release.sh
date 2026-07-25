#!/usr/bin/env bash
#
# sync-release.sh — sync the Heimdall release artifacts to one tag.
#
#   release/sync-release.sh <TAG> [--dry]
#
# One tag in, five artifacts re-pointed/re-rendered so they resolve to
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
#   5. Netlify:   heimdall-site/netlify.toml  ->  /install 302 pinned to <TAG>
#                 (the LIVE runheimdall.dev/install redirect, in the SEPARATE
#                 randomittin/heimdall-site repo — bumped, committed, and pushed
#                 in lockstep so the vanity URL never drifts to a stale tag; a
#                 missing site checkout WARNs, never fails the release. See
#                 release/HOSTING.md and test/ship-netlify.test.sh)
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

# 4. README version pins -> TAG. Three anchored rewrites, each keyed on surrounding text so
#    only the intended spot moves (never a blind s/<oldver>/<newver>/g that would clobber a
#    historical version reference):
#      a) the raw-URL install tags   /heimdall/<oldtag>/install.sh -> /heimdall/<TAG>/install.sh
#      b) the "Pinned to the `vX.Y.Z` tag" prose
#      c) the releases/download/vX.Y.Z/install.sh.minisig asset URL
#    (b) and (c) live OUTSIDE the raw-URL pattern and outside bin/heimdall-render-version's
#    HEIMDALL:VERSION markers; keeping them here makes this sync self-consistent (the step-5
#    copy to packages/runheimdall/README.md is then correct even if this script runs on its
#    own), and bin/heimdall-render-version renders the SAME two spots from plugin.json so the
#    ship.sh render-then-sync order can never disagree.
T="$(mktemp)"
sed -E \
  -e "s|(${RAW_BASE//\//\\/}/)v[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.]+)?(/install\.sh)|\1${TAG}\3|g" \
  -e "s|(Pinned to the \`)v[0-9]+\.[0-9]+\.[0-9]+(\` tag)|\1${TAG}\2|g" \
  -e "s|(releases/download/)v[0-9]+\.[0-9]+\.[0-9]+(/install\.sh\.minisig)|\1${TAG}\2|g" \
  "$README" > "$T"
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

# ── 8. Netlify vanity redirect (runheimdall.dev/install) — SEPARATE site repo ──
# runheimdall.dev is served by Netlify from randomittin/heimdall-site, NOT this
# plugin repo. Its /install 302 lives in heimdall-site/netlify.toml and pins a
# release tag in the `to` URL; that tag drifts to a stale release unless bumped
# every ship. We bump it HERE, in lockstep, reusing THIS release's ${TAG} and the
# already-computed ${NEW_SHA} (never recomputed — the site can't disagree with the
# wrapper). The site checkout is OPTIONAL: a missing ../heimdall-site must NEVER
# fail a plugin release, so absent -> WARN + the exact manual bump+push + continue.
echo "sync-release.sh: syncing the Netlify vanity redirect (heimdall-site)"

# Locate the site. An EXPLICIT HEIMDALL_SITE_DIR is authoritative — if it is set we
# use it as-is and NEVER fall through to another candidate: silently retargeting the
# real production site when the operator named a (mistyped) override would be a
# dangerous surprise (a wrong override -> WARN below, not a push to a different site).
# Only when the override is UNSET do we auto-discover: the sibling ../heimdall-site
# of this plugin repo, then the known local checkout.
SITE_DIR=""
if [ -n "${HEIMDALL_SITE_DIR:-}" ]; then
  SITE_DIR="$HEIMDALL_SITE_DIR"
elif [ -d "$ROOT/../heimdall-site" ]; then
  SITE_DIR="$(cd "$ROOT/../heimdall-site" && pwd)"
elif [ -d "${HOME}/Downloads/heimdall-site" ]; then
  SITE_DIR="${HOME}/Downloads/heimdall-site"
fi
SITE_TOML="${SITE_DIR:+$SITE_DIR/netlify.toml}"

netlify_manual_hint() {
  # A skipped auto-sync must never be a silent drift — print the exact by-hand fix.
  cat >&2 <<HINT
  ! runheimdall.dev/install was NOT auto-bumped. Do it by hand so it doesn't drift:
      In randomittin/heimdall-site/netlify.toml, set the /install redirect to:
        to = "${INSTALL_URL}"
      and update the sha256 in the comment above it to:
        ${NEW_SHA}
      then, from the heimdall-site checkout:
        git add netlify.toml
        git commit -m "chore(netlify): pin /install -> ${TAG}"
        git push origin main
      Tip: set HEIMDALL_SITE_DIR=/path/to/heimdall-site to automate this next release.
HINT
}

if [ -z "$SITE_DIR" ] || [ ! -f "$SITE_TOML" ]; then
  echo "  ! heimdall-site checkout not found (set HEIMDALL_SITE_DIR, or place it at ../heimdall-site)" >&2
  netlify_manual_hint
else
  echo "  site: $SITE_TOML"
  # Rewrite, in one pass: the pinned tag in the /install `to` URL, the
  # "Current release: vX.Y.Z" comment, and the "install.sh sha256 <hex>" comment
  # — all to THIS release's tag + digest. Untouched lines pass through unchanged,
  # so re-running the SAME tag is a byte no-op (idempotent).
  T="$(mktemp)"
  sed -E \
    -e "s|(${RAW_BASE//\//\\/}/)v[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.]+)?(/install\.sh)|\1${TAG}\3|g" \
    -e "s|(Current release: )v[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.]+)?|\1${TAG}|g" \
    -e "s|(install\.sh sha256 )[0-9a-f]{64}|\1${NEW_SHA}|g" \
    "$SITE_TOML" > "$T"

  # ASSERT the rewrite produced the release tag BEFORE writing anything. Unlike the
  # missing-dir case (a soft WARN), a present-but-unpinnable netlify.toml is a REAL
  # drift bug (malformed toml / no /install redirect), so this dies — mirroring the
  # byte-identical resolution gate the plugin artifacts pass above.
  NETLIFY_TAG_NEW="$(sed -nE 's|.*'"${RAW_BASE//\//\\/}"'/(v[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.]+)?)/install\.sh.*|\1|p' "$T" | head -1)"
  assert_eq "netlify.toml /install -> tag target" "$TAG" "$NETLIFY_TAG_NEW"

  # Apply (dry-aware): write_file mv's on a real run, discards + reports on --dry.
  write_file "$SITE_TOML" "$T"

  # Commit ONLY netlify.toml and push to trigger Netlify's auto-deploy. Real runs
  # only. Idempotent: an unchanged file -> no commit. The commit is PATH-SCOPED to
  # netlify.toml so we never bundle the site owner's OTHER staged work; a push
  # failure (offline / no creds) WARNs with the manual command, it does NOT die.
  if [ "$DRY" -eq 0 ]; then
    if ! git -C "$SITE_DIR" rev-parse --git-dir >/dev/null 2>&1; then
      echo "  ! $SITE_DIR is not a git repo — bumped the file but cannot commit/push it" >&2
      netlify_manual_hint
    elif git -C "$SITE_DIR" diff --quiet HEAD -- netlify.toml 2>/dev/null; then
      echo "  = netlify.toml already pinned to ${TAG} (no site commit needed)"
    else
      git -C "$SITE_DIR" add netlify.toml
      if git -C "$SITE_DIR" commit -q -m "chore(netlify): pin /install -> ${TAG}" -- netlify.toml; then
        echo "  ✓ committed heimdall-site netlify.toml -> ${TAG}"
        PUSH_RC=0
        git -C "$SITE_DIR" push origin main || PUSH_RC=$?
        if [ "$PUSH_RC" -eq 0 ]; then
          echo "  ✓ pushed heimdall-site (Netlify will auto-deploy /install -> ${TAG})"
        else
          echo "  ! git push origin main in $SITE_DIR failed (offline/no creds?) — the commit is local." >&2
          echo "    push it manually to trigger the Netlify deploy:  git -C $SITE_DIR push origin main" >&2
        fi
      else
        echo "  ! git commit in $SITE_DIR failed — netlify.toml bumped but not committed" >&2
        netlify_manual_hint
      fi
    fi
  fi
fi

if [ "$DRY" -eq 1 ]; then
  echo "sync-release.sh: dry run complete — nothing written, assertions passed."
else
  echo "sync-release.sh: synced. Next: RJ executes release/publish-checklist.md (npm publish, set 302, push ${TAG})."
fi
