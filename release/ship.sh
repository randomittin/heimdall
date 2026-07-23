#!/usr/bin/env bash
# ship.sh — bump, scan, push, verify, and release in one step ("step 1", automated).
#
# Runs the full routine you've been doing by hand:
#   0. VERSION BUMP — bump .claude-plugin/plugin.json (default: patch), commit it.
#      This is what makes auto-update fire: bin/heimdall-autoupdate compares the
#      installed plugin.json version to the GitHub releases/latest tag, so a ship
#      MUST advance the version + publish a Release or no client rolls forward.
#   1. preview the commits about to ship (origin/BRANCH..HEAD)
#   2. local gitleaks scan over FULL history — stop & do NOT push if anything is found
#   3. git push origin BRANCH  (the repo's own pre-push guard also fires here)
#   4. R9 — independent verify from a FRESH clone of origin:
#        (a) gitleaks clean on the pushed history
#        (b) every author+committer email is on the identity allowlist
#        (c) origin HEAD matches local HEAD
#   5. TAG + GitHub RELEASE (only AFTER R9 passes — release only verified-clean
#      history): git tag vX.Y.Z, push the tag, publish a Release whose notes are
#      DERIVED from this repo's conventional commits (bin/generate-changelog), and
#      attach the minisign signature of install.sh.
#   6. NPM PUBLISH — publish the npx wrapper (packages/runheimdall) to the registry, so
#      `npx runheimdall` resolves to the version this ship just cut. Publishing used to live
#      OUTSIDE this script as a human step, and the human forgot: npm sat at 2.0.5 while the
#      plugin shipped 2.2.6. Same disease as the orphaned Releases, same cure.
#
# Stops at the first failure. Nothing is pushed if the local scan finds leaks.
# Exit 0 = everything green — INCLUDING that the Release is live on GitHub and the wrapper is
# live on npm. A run that cannot publish fails non-zero; it never prints a green banner over an
# unpublished release.
#
# Usage:
#   release/ship.sh            full: patch-bump -> scan -> push -> R9 -> tag+release -> npm
#   release/ship.sh --minor    bump the minor version instead of patch
#   release/ship.sh --major    bump the major version
#   release/ship.sh --version X.Y.Z   set an explicit version
#   release/ship.sh --no-bump  ship without bumping (no new version/tag/release)
#   release/ship.sh --print-next   print the next version per the bump flag, exit (no mutation)
#   release/ship.sh --check    local scan + pending-commit preview, do NOT push/bump
#   release/ship.sh --dry-run  print the exact `gh release` + `npm publish` commands, publish NOTHING
#   release/ship.sh --release-only  publish the manifest's current version (orphan recovery)
#   release/ship.sh --npm-only publish the manifest's current version to npm ONLY (npm drift recovery)
#   release/ship.sh --no-npm   ship without publishing to npm
#   release/ship.sh -h         this help

set -euo pipefail

# ── Config (edit if the repo's facts change) ─────────────────────────────────
BRANCH="main"
# The npx wrapper published to npm. Its package.json version is NOT a second source of truth:
# release/sync-release.sh re-points it FROM the plugin manifest on every release sync, and
# publish_npm refuses to publish if the two ever disagree.
NPM_PKG_DIR="packages/runheimdall"
# The author/committer identity allowlist is NOT duplicated here — R9 (b) below
# delegates to bin/heimdall-check-identities, the single source of truth shared
# with the native pre-push hook, so the release gate and pre-push gate can never
# drift apart. (See release/ship.sh R9 step 3(b).)

# ── Output helpers (TTY-gated: plain when piped, no ANSI garbage in logs) ─────
if [ -t 1 ]; then
  R=$'\033[0m'; B=$'\033[1m'; G=$'\033[32m'; RED=$'\033[31m'; Y=$'\033[33m'; D=$'\033[2m'
else
  R=""; B=""; G=""; RED=""; Y=""; D=""
fi
ok()   { printf '  %s✓%s %s\n' "$G" "$R" "$*"; }
warn() { printf '  %s!%s %s\n' "$Y" "$R" "$*"; }
step() { printf '\n%s▸ %s%s\n' "$B" "$*" "$R"; }
die()  { printf '\n  %s✗ %s%s\n' "$RED" "$*" "$R" >&2; exit 1; }

usage() {
  cat <<'USAGE'
ship.sh — bump, scan, push, verify, and release in one step.

  release/ship.sh              patch-bump -> scan -> push -> R9 verify -> tag + release -> npm
  release/ship.sh --minor      bump minor instead of patch
  release/ship.sh --major      bump major
  release/ship.sh --version X.Y.Z   set an explicit version
  release/ship.sh --no-bump    ship without a version bump (no tag/release)
  release/ship.sh --print-next print the next version (no mutation), exit
  release/ship.sh --check      local secret scan + show pending commits, do NOT push/bump
  release/ship.sh --dry-run    print the EXACT gh release + npm publish commands, publish NOTHING
  release/ship.sh --release-only  publish the version already in the manifest (recover a
                               ship that died between the bump commit and the tag)
  release/ship.sh --npm-only   publish the version already in the manifest to npm ONLY —
                               no bump, no tag, no push (recover npm drift, e.g. npm stuck
                               at 2.0.5 while the manifest ships 2.2.6)
  release/ship.sh --no-npm     ship without publishing to npm
  release/ship.sh -h           this help

Stops at the first failure. Nothing is pushed if the local scan finds leaks.
A run that CANNOT publish a release or publish to npm fails loudly in preflight — it
never bumps, warns, and exits 0 (that silent skip is what stranded v2.2.3/v2.0.17/v2.0.13
as unreleased tags, and what let npm drift 20 patch versions behind the repo).
USAGE
}

# ── Version helpers ──────────────────────────────────────────────────────────
PLUGIN_MANIFEST=".claude-plugin/plugin.json"   # the SOLE authoritative plugin version (audit 6634)

read_version() {  # echo the current plugin.json version (X.Y.Z); die on a non-semver value
  local v
  v="$(sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([0-9]*\.[0-9]*\.[0-9]*\)".*/\1/p' "$PLUGIN_MANIFEST" | head -1)"
  printf '%s' "$v" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$' || die "plugin.json version not semver: '${v:-<none>}'"
  printf '%s' "$v"
}

compute_next() {  # $1=current X.Y.Z, $2=kind(patch|minor|major|explicit), $3=explicit value
  local cur="$1" kind="$2" explicit="${3:-}"
  local MA MI PA; IFS=. read -r MA MI PA <<<"$cur"
  case "$kind" in
    patch)    printf '%s.%s.%s' "$MA" "$MI" "$((PA+1))" ;;
    minor)    printf '%s.%s.0'  "$MA" "$((MI+1))" ;;
    major)    printf '%s.0.0'   "$((MA+1))" ;;
    explicit) printf '%s' "$explicit" ;;
  esac
}

write_version() {  # $1=new version — rewrite plugin.json's version field in place (atomic)
  local new="$1" tmp="${PLUGIN_MANIFEST}.bump.$$"
  sed "s/\(\"version\"[[:space:]]*:[[:space:]]*\"\)[0-9]*\.[0-9]*\.[0-9]*\(\"\)/\1${new}\2/" \
    "$PLUGIN_MANIFEST" > "$tmp" || { rm -f "$tmp"; die "version rewrite failed"; }
  grep -Eq "\"version\"[[:space:]]*:[[:space:]]*\"${new}\"" "$tmp" \
    || { rm -f "$tmp"; die "version rewrite did not take (manifest format unexpected)"; }
  mv "$tmp" "$PLUGIN_MANIFEST"
}

# ── Release notes + publication ──────────────────────────────────────────────
# WHY THIS IS NOT `--generate-notes`: every published Release carried an 83-byte
# GitHub-boilerplate body ("Full Changelog: <compare-link>") — technically a release, but it
# told a reader nothing about what shipped. Notes are now derived from the repo's OWN
# conventional-commit history via bin/generate-changelog, which is the same generator
# CHANGELOG.md uses, so the Release body and the changelog can never tell different stories.

# prev_release_tag — the tag the notes range starts from: the newest vX.Y.Z tag that is an
# ANCESTOR of HEAD and is not $1 itself. Prints nothing when there is no prior tag (the
# caller then falls back to the full history), which is the correct first-release behaviour.
prev_release_tag() {
  local exclude="$1"
  git tag --list 'v[0-9]*.[0-9]*.[0-9]*' --sort=-v:refname --merged HEAD 2>/dev/null \
    | grep -Fxv "$exclude" | head -1
}

# build_release_notes <tag> <outfile> — write the Release body for <tag> to <outfile>.
# Source of truth, in order:
#   1. CHANGELOG.md — if it carries a section for THIS exact version, that hand-curated
#      prose wins (a human wrote something better than a commit list).
#   2. bin/generate-changelog — conventional commits since the previous tag.
# Hard-fails rather than publishing an empty body: a Release with no notes is the boilerplate
# no-op this function exists to end.
build_release_notes() {
  local tag="$1" out="$2" version="${1#v}" prev notes_body=""

  # (1) A curated CHANGELOG.md section for this exact version, if one exists.
  if [ -f "$REPO_ROOT/CHANGELOG.md" ]; then
    notes_body="$(awk -v v="$version" '
      $0 ~ "^## \\[" v "\\]" { grab = 1; next }
      grab && /^## / { exit }
      grab { print }
    ' "$REPO_ROOT/CHANGELOG.md" 2>/dev/null || true)"
    # Strip to nothing if the section held only blank lines.
    printf '%s' "$notes_body" | grep -q '[^[:space:]]' || notes_body=""
  fi

  # (2) Otherwise derive from conventional commits since the previous tag.
  if [ -z "$notes_body" ]; then
    prev="$(prev_release_tag "$tag")"
    local gen="$REPO_ROOT/bin/generate-changelog"
    if [ -x "$gen" ]; then
      if [ -n "$prev" ]; then
        notes_body="$("$gen" --since "$prev" --version "$version" 2>/dev/null || true)"
      else
        notes_body="$("$gen" --version "$version" 2>/dev/null || true)"
      fi
      # generate-changelog emits its own "## [version] - date" heading; drop it so the
      # Release title is not duplicated inside the body.
      notes_body="$(printf '%s\n' "$notes_body" | sed '1{/^## \[/d;}')"
    fi
  fi

  # (3) Last resort: a plain commit list. Still real content, never boilerplate.
  if ! printf '%s' "$notes_body" | grep -q '[^[:space:]]'; then
    prev="$(prev_release_tag "$tag")"
    if [ -n "$prev" ]; then
      notes_body="$(git log --no-merges --pretty=format:'- %s' "${prev}..HEAD" 2>/dev/null || true)"
    else
      notes_body="$(git log --no-merges --pretty=format:'- %s' HEAD 2>/dev/null || true)"
    fi
  fi

  printf '%s' "$notes_body" | grep -q '[^[:space:]]' \
    || die "release notes for $tag came out EMPTY — refusing to publish a boilerplate Release"

  prev="$(prev_release_tag "$tag")"
  {
    printf '%s\n' "$notes_body"
    printf '\n'
    if [ -n "$prev" ]; then
      printf '**Full changelog**: https://github.com/randomittin/heimdall/compare/%s...%s\n' "$prev" "$tag"
    fi
    printf '\nInstall/upgrade:\n\n```bash\ncurl -fsSL https://raw.githubusercontent.com/randomittin/heimdall/%s/install.sh | bash\n```\n' "$tag"
    printf '\n`install.sh.minisig` is the detached minisign signature of this release'\''s `install.sh`; `bin/heimdall-autoupdate` verifies it against `release/heimdall-signing.pub` before applying.\n'
  } > "$out" || die "could not write release notes to $out"
}

# publish_release <tag> <notes-file> — create the GitHub Release, or UPDATE it if it already
# exists. IDEMPOTENT by design: a re-run after a partial ship must converge, not error out
# ambiguously. Every gh invocation is exit-checked and dies loudly — no `|| true`, no
# `2>/dev/null` swallowing the reason. gh's stderr is captured and REPRINTED on failure so
# the operator sees what GitHub actually said.
publish_release() {
  local tag="$1" notes="$2" out rc

  # NOTE: `if out="$(cmd)"` — not `out="$(cmd)"; rc=$?`. Under this script's `set -e`, a
  # failing command-substitution in a bare assignment aborts the shell BEFORE the next line,
  # so the recovery `die` message would never print (a loud failure turned silent). An if-
  # condition is exempt from set -e and still captures stdout+stderr into $out.
  if gh release view "$tag" >/dev/null 2>&1; then
    warn "Release $tag already exists — updating its notes + title in place (idempotent re-run)"
    if ! out="$(gh release edit "$tag" --notes-file "$notes" --title "$tag" 2>&1)"; then
      rc=$?; printf '%s\n' "$out" >&2
      die "gh release edit $tag failed (exit $rc) — see gh output above"
    fi
    ok "updated GitHub Release $tag"
  else
    if ! out="$(gh release create "$tag" --notes-file "$notes" --title "$tag" 2>&1)"; then
      rc=$?; printf '%s\n' "$out" >&2
      die "gh release create $tag failed (exit $rc) — the tag is pushed; re-run release/ship.sh --release-only after fixing the cause"
    fi
    ok "published GitHub Release $tag — auto-update's releases/latest now advances"
  fi

  # A Release that GitHub did not actually record is a silent no-op. Read it back.
  gh release view "$tag" >/dev/null 2>&1 \
    || die "post-publish readback failed: GitHub does not report a Release at $tag"
}

# ── Release signing (minisign) ───────────────────────────────────────────────
# After a Release is published, sign the artifact clients auto-update from (install.sh) and
# upload the DETACHED signature (install.sh.minisig) as a Release asset. bin/heimdall-autoupdate
# verifies that signature against the in-repo public key (release/heimdall-signing.pub) BEFORE
# it ever runs the downloaded install.sh — so an unsigned/tampered release is refused.
#
# RJ holds the SECRET key OUTSIDE the repo (default: ~/.heimdall/signing/heimdall-signing.key,
# override with HEIMDALL_SIGNING_KEY). If minisign is not installed OR the secret key is absent,
# we WARN and release UNSIGNED — we do NOT hard-block RJ. (Clients that verify will then REFUSE
# that release until it is signed; that is the point.) See SIGNING.md for key generation + rotation.
DEFAULT_SIGNING_KEY="$HOME/.heimdall/signing/heimdall-signing.key"

sign_release_artifact() {  # $1 = tag (vX.Y.Z). Best-effort: WARN + return 0 when it cannot sign.
  local tag="$1"
  local artifact="${SHIP_ARTIFACT:-${REPO_ROOT:-$PWD}/install.sh}"
  # Resolve the key at CALL time so `HEIMDALL_SIGNING_KEY=... ship.sh` and the sourced test seam
  # both take effect (a source-time global would freeze the default before the env is set).
  local seckey="${HEIMDALL_SIGNING_KEY:-$DEFAULT_SIGNING_KEY}"

  if [ ! -f "$artifact" ]; then
    warn "signing: artifact not found ($artifact) — releasing $tag UNSIGNED."
    return 0
  fi
  if ! command -v minisign >/dev/null 2>&1; then
    warn "signing: minisign not installed — releasing $tag UNSIGNED. Clients that verify will REFUSE it."
    warn "  install:  brew install minisign   (or see SIGNING.md), then re-sign:"
    warn "  re-sign:  minisign -Sm '$artifact' -x install.sh.minisig && gh release upload $tag install.sh.minisig --clobber"
    return 0
  fi
  if [ ! -f "$seckey" ]; then
    warn "signing: no signing key at $seckey — releasing $tag UNSIGNED (RJ holds the key)."
    warn "  generate once (see SIGNING.md): minisign -G -W -f -s '$seckey' -p '${REPO_ROOT:-.}/release/heimdall-signing.pub'"
    return 0
  fi

  local sigdir sig
  sigdir="$(mktemp -d "${TMPDIR:-/tmp}/heimdall-sign.XXXXXX")" || { warn "signing: mktemp failed — releasing $tag UNSIGNED."; return 0; }
  sig="$sigdir/install.sh.minisig"   # basename becomes the Release asset name
  if ! minisign -S -s "$seckey" -m "$artifact" -x "$sig" \
        -c "heimdall $tag install.sh" \
        -t "heimdall release $tag — signed $(date -u +%Y-%m-%dT%H:%M:%SZ)" >/dev/null 2>&1; then
    warn "signing: minisign -S failed (bad/locked key?) — releasing $tag UNSIGNED."
    rm -rf "$sigdir"; return 0
  fi
  ok "signed install.sh → install.sh.minisig ($tag)"

  # Past THIS point the artifact IS signed, so a failure to attach is NOT a soft condition:
  # the Release would ship with no signature and every verifying client would REFUSE it.
  # We hold the key, we produced the sig — dropping it silently is the failure mode this
  # whole signing model exists to prevent. Loud failure > quiet skip.
  local out rc
  # if-condition capture (set -e safe — see publish_release for why bare `out=$(...)` aborts).
  if ! out="$(gh release upload "$tag" "$sig" --clobber 2>&1)"; then
    rc=$?; printf '%s\n' "$out" >&2
    rm -rf "$sigdir"
    die "gh release upload failed (exit $rc) — $tag is published but UNSIGNED; verifying clients will REFUSE it. Attach it with: minisign -Sm install.sh -x install.sh.minisig && gh release upload $tag install.sh.minisig --clobber"
  fi
  ok "uploaded install.sh.minisig to Release $tag — auto-update can now VERIFY this release"

  # Read the asset back: an upload that reports success but leaves no asset is the silent
  # no-op class this ship is being fixed for.
  gh release view "$tag" --json assets --jq '.assets[].name' 2>/dev/null | grep -Fxq 'install.sh.minisig' \
    || { rm -rf "$sigdir"; die "post-upload readback failed: Release $tag carries no install.sh.minisig asset"; }
  ok "verified install.sh.minisig is attached to $tag"

  rm -rf "$sigdir"
}

# bump_default_ref — pin install.sh's `local DEFAULT_REF="vX.Y.Z"` to $1 (a vX.Y.Z tag) and
# `git add` it. Idempotent; a no-op (returns 0) if the file or the line is absent so a repo
# layout change never hard-blocks a release. This is what keeps fresh installs off a stale ref.
bump_default_ref() {
  local tag="$1"
  local file="${SHIP_INSTALL_SH:-${REPO_ROOT:-$PWD}/install.sh}"
  printf '%s' "$tag" | grep -Eq '^v[0-9]+\.[0-9]+\.[0-9]+$' || { warn "bump_default_ref: '$tag' is not a vX.Y.Z tag — skipping"; return 0; }
  [ -f "$file" ] || { warn "bump_default_ref: $file not found — skipping"; return 0; }
  grep -Eq 'local DEFAULT_REF="v[0-9]+\.[0-9]+\.[0-9]+"' "$file" || { warn "bump_default_ref: no DEFAULT_REF line in $file — skipping"; return 0; }
  sed -E -i.bak "s/(local DEFAULT_REF=\")v[0-9]+\.[0-9]+\.[0-9]+(\")/\1${tag}\2/" "$file" \
    && rm -f "$file.bak"
  git add "$file" 2>/dev/null || true
  ok "pinned install.sh DEFAULT_REF → $tag"
}

# render_version_surfaces — RENDER (not hand-patch) the manifest-derived version surfaces:
# the repo-root VERSION mirror and README's generated HEIMDALL:VERSION region. Delegates to
# bin/heimdall-render-version, the single renderer, so ship.sh and the drift gate can never
# disagree about what a surface should say. HARD-fails: a release commit carrying a stale
# README/VERSION is precisely the drift test/version-drift.test.sh exists to catch, so
# discovering it at ship time and warning would just push a known-red commit.
render_version_surfaces() {
  local new="$1"
  local renderer="${SHIP_RENDERER:-${REPO_ROOT:-$PWD}/bin/heimdall-render-version}"
  [ -x "$renderer" ] || die "render_version_surfaces: $renderer missing/not executable — cannot render version surfaces for $new"
  "$renderer" || die "render_version_surfaces: rendering failed for $new"
  git add "${REPO_ROOT:-$PWD}/VERSION" "${REPO_ROOT:-$PWD}/README.md" 2>/dev/null || true
  ok "rendered version surfaces (VERSION, README region) → $new"
}

# sync_release_artifacts — re-point the TAG-derived artifacts at $1 via release/sync-release.sh:
# the npx wrapper (packages/runheimdall/package.json version/tag/url/sha256), and the vanity
# 302 targets (vercel.json, _redirects). That script also ASSERTS the wrapper's baked sha256
# equals the digest of the install.sh this tag will serve, so `npx runheimdall` and
# runheimdall.dev/install provably resolve to byte-identical bytes.
#
# This call is why the wrapper stopped drifting: sync-release.sh existed but NOTHING invoked
# it, so the wrapper sat at v2.0.5 while the plugin shipped 2.2.6 — `npx runheimdall`
# installed a months-stale Heimdall and no gate was red. HARD-fails for the same reason
# render_version_surfaces does.
sync_release_artifacts() {
  local tag="$1"
  local sync="${SHIP_SYNC_RELEASE:-${REPO_ROOT:-$PWD}/release/sync-release.sh}"
  [ -x "$sync" ] || [ -f "$sync" ] || die "sync_release_artifacts: $sync not found — cannot sync release artifacts for $tag"
  bash "$sync" "$tag" || die "sync_release_artifacts: release/sync-release.sh $tag failed — artifacts would drift from the tag"
  git add "${REPO_ROOT:-$PWD}/packages/runheimdall/package.json" \
          "${REPO_ROOT:-$PWD}/vercel.json" \
          "${REPO_ROOT:-$PWD}/_redirects" \
          "${REPO_ROOT:-$PWD}/install.sh" \
          "$PLUGIN_MANIFEST" 2>/dev/null || true
  ok "synced release artifacts (npx wrapper, vanity 302) → $tag"
}

# bump_readme_sha — SHA-pin README's install one-liner(s) to $1 (a 40-hex commit SHA) and
# `git add` it. Tags are FORCE-MOVABLE; a full commit SHA is immutable, so a fresh
# `curl|bash` fetches EXACTLY the reviewed bytes (supply-chain hardening). Rewrites EVERY
# raw.githubusercontent .../install.sh ref (the one-liner AND the inspect-first fetch),
# matching whatever ref is currently pinned (tag OR a prior SHA) → idempotent. No-op
# (returns 0) if the file or a matching URL is absent so a layout change never blocks release.
bump_readme_sha() {
  local sha="$1"
  local file="${SHIP_README:-${REPO_ROOT:-$PWD}/README.md}"
  printf '%s' "$sha" | grep -Eq '^[0-9a-f]{40}$' || { warn "bump_readme_sha: '$sha' is not a 40-hex SHA — skipping"; return 0; }
  [ -f "$file" ] || { warn "bump_readme_sha: $file not found — skipping"; return 0; }
  grep -Eq 'raw\.githubusercontent\.com/randomittin/heimdall/[^/]+/install\.sh' "$file" \
    || { warn "bump_readme_sha: no install URL in $file — skipping"; return 0; }
  sed -E -i.bak "s#(raw\.githubusercontent\.com/randomittin/heimdall/)[^/]+(/install\.sh)#\1${sha}\2#g" "$file" \
    && rm -f "$file.bak"
  git add "$file" 2>/dev/null || true
  ok "SHA-pinned README install URL → ${sha:0:12}…"
}

# ── npm publication (the npx wrapper) ────────────────────────────────────────
# ROOT CAUSE (the npm-drift defect): `npm view runheimdall version` said 2.0.5 while the repo
# shipped 2.2.6 — twenty patch releases of drift — because `npm publish` lived OUTSIDE this
# script as a human step, and a human step that is not on the critical path is a step that gets
# forgotten. That is the SAME disease that stranded v2.2.3/v2.0.17/v2.0.13 as orphaned
# Releases: the version bump was committed in one place and the artifact published (or, in
# practice, not) somewhere else. It gets the SAME cure as publish_release:
#   * prove the prerequisites BEFORE any mutation      (preflight_npm_prereqs)
#   * publish inside the ship stage, never beside it   (publish_npm, called from the flow)
#   * exit-check every call, reprint the registry's own words, never `|| true`
#   * be idempotent so a re-run converges               (already-published -> loud skip)
#   * give the operator a recovery flag for drift that already exists   (--npm-only)

npm_pkg_dir() { printf '%s' "${SHIP_NPM_DIR:-${REPO_ROOT:-$PWD}/$NPM_PKG_DIR}"; }

npm_pkg_field() {  # $1=field — read a top-level string field out of the wrapper's package.json
  local field="$1" file v
  file="$(npm_pkg_dir)/package.json"
  [ -f "$file" ] || die "npm: $file not found — cannot resolve .$field"
  v="$(jq -r --arg f "$field" '.[$f] // empty' "$file" 2>/dev/null)" \
    || die "npm: could not parse $file (invalid JSON?)"
  [ -n "$v" ] || die "npm: $file has no .$field"
  printf '%s' "$v"
}

# npm_version_published <pkg> <version> — 0 when that EXACT version is already on the registry.
# `npm view pkg@ver version` prints the version on a hit and exits non-zero (E404) on a miss:
# the registry's own answer to "is this published?". --prefer-online defeats npm's local
# metadata cache, which would otherwise let a stale cache claim a live version is missing.
npm_version_published() {
  local pkg="$1" version="$2" out
  out="$(npm view --prefer-online "${pkg}@${version}" version 2>/dev/null)" || return 1
  [ "$out" = "$version" ]
}

# preflight_npm_prereqs — prove we CAN publish to npm BEFORE the bump mutates a single file.
# Mirrors preflight_release_prereqs, and for the identical reason: a bump we cannot follow
# through with is what strands a version. Every failure here is a HARD, non-zero die. There is
# deliberately NO warn-and-continue branch — a warn-and-exit-0 is exactly what let ship.sh
# print "✓ Shipped & verified" having published nothing. npm's stderr is REPRINTED, never
# swallowed by 2>/dev/null, so the operator sees what the registry actually said.
preflight_npm_prereqs() {
  local dir pkg who out rc
  command -v npm >/dev/null 2>&1 \
    || die "npm not found — the npx wrapper cannot be published. Install Node/npm, or re-run with --no-npm to ship without publishing to npm."
  command -v jq >/dev/null 2>&1 \
    || die "jq not found — cannot read $NPM_PKG_DIR/package.json. Install it (brew install jq), or re-run with --no-npm."
  dir="$(npm_pkg_dir)"
  [ -f "$dir/package.json" ] || die "npm: $dir/package.json not found — there is nothing to publish."
  pkg="$(npm_pkg_field name)"

  # if-condition capture (set -e safe — see publish_release for why bare `out=$(...)` aborts).
  if ! who="$(npm whoami 2>&1)"; then
    rc=$?; printf '%s\n' "$who" >&2
    die "npm is not authenticated (npm whoami exit $rc) — '$pkg' cannot be published. Run 'npm login', or re-run with --no-npm to ship without publishing to npm."
  fi
  ok "npm prereqs: authenticated as $who"

  # Publish RIGHTS on the package. Only checkable when the package already exists — a package
  # that is not on the registry yet is a first publish, which any authenticated user may do.
  if npm view --prefer-online "$pkg" version >/dev/null 2>&1; then
    if ! out="$(npm owner ls "$pkg" 2>&1)"; then
      rc=$?; printf '%s\n' "$out" >&2
      die "npm: could not read the owners of '$pkg' (npm owner ls exit $rc) — publish rights cannot be proven. See npm's output above."
    fi
    if ! printf '%s\n' "$out" | grep -Fq "$who"; then
      printf '%s\n' "$out" >&2
      die "npm: '$who' is NOT an owner of '$pkg' — the publish would be REJECTED *after* the version bump commit was already made. Owners are listed above. Get publish rights, or re-run with --no-npm."
    fi
    ok "npm prereqs: '$who' has publish rights on '$pkg'"
  else
    warn "npm: '$pkg' is not on the registry yet — this would be its FIRST publish"
  fi
}

# npm_positioning_notice — SURFACE an UNDECIDED §3 positioning, stay SILENT once it is decided.
# package.json's .description and .keywords are what npmjs.com renders as the package's page
# subtitle and search result, and npm versions are IMMUTABLE — publishing pre-launch placeholder
# words means burning a whole version number later to fix them. So while §3 is undecided we warn
# loudly at the npm stage. §3 is DECIDED once .description carries the canonical launch tagline
# "Nothing ships unproven." (candidate A — 12-term keyword list, committed 0185059). The tagline
# in the SHIPPED words is the robust signal: it is exactly what a real ship publishes, so it can
# never drift out of sync with a separate marker file. Decided → silent (no more crying wolf on
# every ship); undecided → still loud. Decision history: .planning/A3-PENDING-POSITIONING.md.
NPM_POSITIONING_TAGLINE="Nothing ships unproven."
npm_positioning_notice() {
  local dir desc
  dir="$(npm_pkg_dir)"
  desc="$(jq -r '.description // empty' "$dir/package.json" 2>/dev/null || true)"
  case "$desc" in
    *"$NPM_POSITIONING_TAGLINE"*) return 0 ;;   # §3 decided — publish the right words, say nothing
  esac
  warn "npm positioning is PENDING RJ's canonical §3 decision:"
  warn "  .description / .keywords in $NPM_PKG_DIR/package.json are still pre-launch text."
  warn "  npm versions are IMMUTABLE — publishing now means publishing AGAIN to fix the words."
  warn "  Decide first (candidates A/B/C): .planning/A3-PENDING-POSITIONING.md"
}

# publish_npm <version> — publish the npx wrapper at <version> to the registry.
# IDEMPOTENT by design, exactly like publish_release: a re-run after a partial ship must
# converge, not error out ambiguously. We ask the registry FIRST rather than letting a
# duplicate publish fail, because npm's own duplicate error (E403 "cannot publish over
# previously published version") is indistinguishable at a glance from a real permissions
# failure — so we say plainly which case this is.
publish_npm() {
  local version="$1" dir pkg pkg_version rc tries
  dir="$(npm_pkg_dir)"
  pkg="$(npm_pkg_field name)"

  # The manifest is the SOLE source of version truth; the wrapper's package.json is a rendered
  # surface that release/sync-release.sh re-points from it. If they disagree, the sync did not
  # run and publishing would put a mislabelled tarball on an immutable registry.
  pkg_version="$(npm_pkg_field version)"
  [ "$pkg_version" = "$version" ] \
    || die "npm: $NPM_PKG_DIR/package.json is at $pkg_version but this ship is publishing $version — release/sync-release.sh did not re-point the wrapper. Refusing to publish a mismatched version."

  if npm_version_published "$pkg" "$version"; then
    warn "npm: ${pkg}@${version} is ALREADY published — skipping the publish (idempotent re-run)"
    ok "npm: ${pkg}@${version} is live on the registry"
    return 0
  fi

  npm_positioning_notice

  # PUBLISH ON THE REAL TTY — deliberately NOT wrapped in $(...) capture (nor piped/tee'd).
  # WHY: RJ's npm 2FA is a passkey/WebAuthn (Apple Keychain). It produces NO typed TOTP code,
  # so npm's ONLY viable second factor here is its browser/web flow: npm prints
  # "Authenticate your account at: https://www.npmjs.com/auth/cli/<uuid>" and opens the browser
  # for the passkey. That interactive web auth runs ONLY when npm's stdout is a real TTY. The
  # moment `npm publish` is captured in a command-substitution (or piped through `tee`), npm
  # sees a non-TTY stdout, abandons web auth, and falls back to DEMANDING a typed `--otp` —
  # which for a passkey can never be satisfied → `npm error code EOTP`, a hard dead-end. The
  # broken scripted path did exactly this: `out="$(cd "$dir" && npm publish … 2>&1)"`. The
  # working manual path was a bare `npm publish --access public` on the terminal. So the publish
  # now INHERITS ship.sh's stdio (the operator's terminal) and we capture only its exit code;
  # npm's own output streams straight to the terminal, so the operator sees the auth URL live
  # and, on failure, the reason. `--auth-type=web` pins the browser flow explicitly instead of
  # trusting npm's version default. CI/automation publishes with an npm AUTOMATION TOKEN, which
  # bypasses 2FA entirely (no prompt, no TTY needed), so this identical line is correct headless.
  rc=0
  ( cd "$dir" && npm publish --access public --auth-type=web ) || rc=$?
  if [ "$rc" -ne 0 ]; then
    die "npm publish failed (exit $rc) for ${pkg}@${version} — see npm's output above. The version bump is already committed and the Release is published; recover with:  release/ship.sh --npm-only"
  fi
  ok "published ${pkg}@${version} to npm — 'npx runheimdall' now resolves to $version"

  # Post-publish readback — CONFIRM the write is visible on a read replica. This is NOT the
  # gate that catches a failed publish: a real publish failure already died above (npm publish
  # returned non-zero). By the time we reach here npm printed `+ ${pkg}@${version}`, so the
  # publish SUCCEEDED. npm's registry read replicas lag a write by 30s–several minutes, so a
  # miss here is PROPAGATION LAG, not a lost publish. Therefore we poll patiently and, on
  # timeout, WARN and exit SUCCESS — a slow read replica must never report a succeeded ship as
  # failed (the false-negative that failed the real v2.3.1 ship: `+ runheimdall@2.3.1` printed,
  # yet 5 fast attempts × 2s could not outrun the replica lag and the ship was declared dead).
  # Defaults (~13 tries × 14s ≈ 3 min total budget) are overridable for tests via env.
  local rb_max="${SHIP_READBACK_MAX_TRIES:-13}" rb_delay="${SHIP_READBACK_DELAY:-14}"
  tries=0
  until npm_version_published "$pkg" "$version"; do
    tries=$((tries+1))
    if [ "$tries" -ge "$rb_max" ]; then
      warn "npm post-publish readback still lagging after $tries attempts — this read replica has not yet propagated ${pkg}@${version}."
      warn "  This is NOT a failed publish: npm printed '+ ${pkg}@${version}' above, so the publish SUCCEEDED. npm read replicas lag a write by 30s–a few minutes."
      warn "  Verify propagation shortly with:  npm view ${pkg} version   (expect ${version})"
      return 0
    fi
    sleep "$rb_delay"
  done
  ok "verified ${pkg}@${version} is live on the registry"
}

# Test/introspection seam: `SHIP_SOURCE_ONLY=1 . release/ship.sh` defines the functions above
# (read_version, sign_release_artifact, publish_npm, …) WITHOUT running the release flow.
# Executed normally the variable is unset and we fall through to the real pipeline below.
if [ "${SHIP_SOURCE_ONLY:-0}" = "1" ]; then
  return 0 2>/dev/null || exit 0
fi

# ── Args (multi-flag: parse every argument, not just $1) ─────────────────────
CHECK_ONLY=0; BUMP_KIND="patch"; EXPLICIT_VERSION=""; DO_BUMP=1; PRINT_NEXT=0
DRY_RUN=0; RELEASE_ONLY=0; NPM_ONLY=0; DO_NPM=1
while [ "$#" -gt 0 ]; do
  case "$1" in
    --check|--check-only) CHECK_ONLY=1 ;;
    --minor) BUMP_KIND="minor" ;;
    --major) BUMP_KIND="major" ;;
    --no-bump) DO_BUMP=0 ;;
    --print-next) PRINT_NEXT=1 ;;
    --dry-run) DRY_RUN=1 ;;
    --release-only) RELEASE_ONLY=1; DO_BUMP=0 ;;
    --npm-only) NPM_ONLY=1; DO_BUMP=0 ;;
    --no-npm) DO_NPM=0 ;;
    --version) BUMP_KIND="explicit"; EXPLICIT_VERSION="${2:-}"; shift
               printf '%s' "$EXPLICIT_VERSION" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$' \
                 || die "--version needs X.Y.Z (got '${EXPLICIT_VERSION:-}')" ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown arg: $1  (try -h)" ;;
  esac
  shift
done

# --print-next: compute + print, mutate NOTHING.
if [ "$PRINT_NEXT" -eq 1 ]; then
  _root="$(git rev-parse --show-toplevel 2>/dev/null)" || die "not in a git repo"
  cd "$_root"; compute_next "$(read_version)" "$BUMP_KIND" "$EXPLICIT_VERSION"; echo; exit 0
fi

# ── Preflight ────────────────────────────────────────────────────────────────
command -v git      >/dev/null 2>&1 || die "git not found"
command -v gitleaks >/dev/null 2>&1 || die "gitleaks not found — install it first"

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || die "not inside a git repository"
cd "$REPO_ROOT"

# Self-heal a STALE .git/index.lock left by an INTERRUPTED prior run (the recurring
# "Unable to create '.git/index.lock': File exists" at ship time — an aborted release or a
# racing autocommit that died mid-write). heimdall-git-guard clears ONLY an ownerless lock
# (waits out any LIVE git op, never removes a lock a running op holds). Best-effort.
[ -x "$REPO_ROOT/bin/heimdall-git-guard" ] && "$REPO_ROOT/bin/heimdall-git-guard" "$REPO_ROOT" || true

CUR_BRANCH="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo '?')"
if [ "$CUR_BRANCH" != "$BRANCH" ]; then
  warn "on branch '$CUR_BRANCH', not '$BRANCH' — will operate on '$CUR_BRANCH'"
  BRANCH="$CUR_BRANCH"
fi

REMOTE_URL="$(git remote get-url origin 2>/dev/null)" || die "no 'origin' remote configured"
printf '%srepo:   %s%s\n' "$D" "$REPO_ROOT" "$R"
printf '%sbranch: %s%s\n' "$D" "$BRANCH" "$R"
printf '%sorigin: %s%s\n' "$D" "$REMOTE_URL" "$R"

# Refresh the remote ref so the pending-commit preview is accurate (non-fatal).
git fetch origin "$BRANCH" --quiet 2>/dev/null || true

# ── Release preflight — check the RELEASE prerequisites BEFORE mutating anything ──
# ROOT CAUSE (the orphaned-version defect): the version bump was committed in step 0, but the
# tag + Release only happened at the very end, AFTER the push and the three R9 gates. Any
# failure in between left the bump commit in history with NO tag and NO Release — and the next
# ship read the bumped manifest, computed the NEXT version, and skipped the orphan FOREVER.
# That is exactly how v2.2.3 (f6c5f10), v2.0.17 and v2.0.13 became versions that exist in
# plugin.json history and are installable, but have no tag and no GitHub Release.
# Separately, the release step was gated behind `if command -v gh && gh auth status`, whose
# else-branch merely WARNed — so a gh-absent/unauthenticated run printed the green
# "✓ Shipped & verified" banner and EXITED 0 having published nothing.
#
# Both are fixed the same way: the things a release REQUIRES are proven up front, and a
# release-capable run that cannot release is a HARD failure, never a warn-and-exit-0.
preflight_release_prereqs() {
  command -v gh >/dev/null 2>&1 \
    || die "gh CLI not found — a release cannot be published. Install it (brew install gh) or re-run with --no-bump to ship without a release."
  gh auth status >/dev/null 2>&1 \
    || die "gh is not authenticated — a release cannot be published. Run 'gh auth login', or re-run with --no-bump to ship without a release."
  [ -x "$REPO_ROOT/bin/generate-changelog" ] \
    || die "bin/generate-changelog missing/not executable — release notes cannot be derived."
  ok "release prereqs: gh present + authenticated, notes generator present"
}

# reconcile_orphan_release — the recovery path the old flow never had. If the CURRENT manifest
# version has no tag and no Release, a prior ship died between the bump commit and the tag.
# Bumping past it would orphan it permanently (the v2.2.3 defect). Refuse, and name the fix.
reconcile_orphan_release() {
  local cur_tag="v$1"
  git rev-parse -q --verify "refs/tags/$cur_tag" >/dev/null 2>&1 && return 0
  git ls-remote --exit-code --tags origin "refs/tags/$cur_tag" >/dev/null 2>&1 && return 0
  # No tag anywhere for the version currently in the manifest. Was it ever released?
  if git log --oneline -1 --grep="chore(release): $cur_tag" >/dev/null 2>&1 \
     && [ -n "$(git log --oneline --grep="chore(release): $cur_tag" 2>/dev/null)" ]; then
    die "orphaned release detected: the manifest is at $1 and a 'chore(release): $cur_tag' commit exists, but $cur_tag has NO tag and NO GitHub Release — a prior ship died between the bump and the tag. Bumping past it would strand $1 forever. Finish it first:  release/ship.sh --release-only"
  fi
  return 0
}

# ── --dry-run: prove the release WITHOUT publishing ──────────────────────────
# Prints the EXACT gh and npm invocations that would run and the EXACT notes body that would
# be posted, then exits 0 having mutated nothing (no bump, no commit, no tag, no push, no gh
# write, no npm publish). This is how both publish paths are proven without ever creating a
# real Release or putting a real tarball on an immutable registry —
# test/ship-release.test.sh and test/ship-npm.test.sh assert against this output.
if [ "$DRY_RUN" -eq 1 ]; then
  step "Dry run — nothing will be bumped, committed, tagged, pushed, or published"
  if [ "$RELEASE_ONLY" -eq 1 ] || [ "$NPM_ONLY" -eq 1 ]; then
    DRY_VERSION="$(read_version)"
  else
    DRY_VERSION="$(compute_next "$(read_version)" "$BUMP_KIND" "$EXPLICIT_VERSION")"
  fi
  DRY_TAG="v$DRY_VERSION"
  TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/heimdall-dry.XXXXXX")" || die "mktemp failed"
  trap 'rm -rf "$TMP_DIR" 2>/dev/null || true' EXIT

  if [ "$NPM_ONLY" -eq 0 ]; then
    DRY_NOTES="$TMP_DIR/notes.md"
    build_release_notes "$DRY_TAG" "$DRY_NOTES"

    DRY_PREV="$(prev_release_tag "$DRY_TAG")"
    printf '  current version : %s\n' "$(read_version)"
    printf '  release version : %s (tag %s)\n' "$DRY_VERSION" "$DRY_TAG"
    printf '  notes range     : %s..HEAD\n' "${DRY_PREV:-<first release: full history>}"
    printf '  gh authed       : %s\n' "$(gh auth status >/dev/null 2>&1 && echo yes || echo 'NO — a real run would HARD-FAIL in preflight')"
    if gh release view "$DRY_TAG" >/dev/null 2>&1; then
      printf '  existing release: YES — a real run would UPDATE it (idempotent)\n'
      DRY_VERB="edit"
    else
      printf '  existing release: no — a real run would CREATE it\n'
      DRY_VERB="create"
    fi

    step "Exact command that would run"
    printf '  gh release %s %s --notes-file %s --title %s\n' "$DRY_VERB" "$DRY_TAG" "$DRY_NOTES" "$DRY_TAG"
    printf '  gh release upload %s install.sh.minisig --clobber\n' "$DRY_TAG"

    step "Exact release notes that would be posted"
    sed 's/^/  | /' "$DRY_NOTES"
  fi

  # ── npm stage (dry) ────────────────────────────────────────────────────────
  if [ "$DO_NPM" -eq 1 ]; then
    step "npm publish (dry)"
    if ! command -v npm >/dev/null 2>&1; then
      warn "npm not found — a real run would HARD-FAIL in preflight (or use --no-npm)"
    elif ! command -v jq >/dev/null 2>&1; then
      warn "jq not found — a real run would HARD-FAIL in preflight (or use --no-npm)"
    else
      DRY_NPM_DIR="$(npm_pkg_dir)"
      DRY_NPM_PKG="$(npm_pkg_field name)"
      DRY_NPM_PKGVER="$(npm_pkg_field version)"
      printf '  package         : %s\n' "$DRY_NPM_PKG"
      printf '  package dir     : %s\n' "$DRY_NPM_DIR"
      printf '  publish version : %s\n' "$DRY_VERSION"
      printf '  package.json ver: %s' "$DRY_NPM_PKGVER"
      if [ "$DRY_NPM_PKGVER" = "$DRY_VERSION" ]; then
        printf '  (matches)\n'
      else
        printf '  (release/sync-release.sh re-points this to %s during the bump)\n' "$DRY_VERSION"
      fi
      printf '  npm authed      : %s\n' "$(npm whoami 2>/dev/null || echo 'NO — a real run would HARD-FAIL in preflight')"
      printf '  registry now at : %s\n' "$(npm view --prefer-online "$DRY_NPM_PKG" version 2>/dev/null || echo '<unreachable or unpublished>')"
      if npm_version_published "$DRY_NPM_PKG" "$DRY_VERSION"; then
        printf '  already on npm  : YES — a real run would SKIP the publish (idempotent)\n'
      else
        printf '  already on npm  : no — a real run would PUBLISH it\n'
      fi

      printf '  files allowlist :\n'
      jq -r '.files[]? // empty' "$DRY_NPM_DIR/package.json" | while IFS= read -r f; do
        if [ -e "$DRY_NPM_DIR/$f" ]; then
          printf '    - %s (present)\n' "$f"
        else
          printf '    - %s (MISSING — the tarball would not carry it)\n' "$f"
        fi
      done

      step "Exact npm command that would run"
      # Runs attached to the terminal (no $(...) capture) so npm's browser/web 2FA works for a
      # passkey/WebAuthn account; --auth-type=web pins that flow. See publish_npm for the full why.
      printf '  cd %s && npm publish --access public --auth-type=web\n' "$DRY_NPM_DIR"

      npm_positioning_notice
    fi
  fi

  printf '\n%s%sDry run complete%s — nothing was published. Re-run without --dry-run to release.\n' "$G" "$B" "$R"
  exit 0
fi

# ── --release-only: finish an ORPHANED version (the v2.2.3 recovery path) ────
# Releases the version ALREADY in the manifest: tag it, publish real notes, sign, attach.
# This is the path that did not exist when v2.2.3/v2.0.17/v2.0.13 were stranded — the only
# way to recover was to bump past them, which is what made the hole permanent.
if [ "$RELEASE_ONLY" -eq 1 ]; then
  step "Release-only — publishing the version already in the manifest"
  preflight_release_prereqs
  RO_VERSION="$(read_version)"
  TAG="v$RO_VERSION"
  TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/heimdall-ro.XXXXXX")" || die "mktemp failed"
  trap 'rm -rf "$TMP_DIR" 2>/dev/null || true' EXIT

  if ! git rev-parse -q --verify "refs/tags/$TAG" >/dev/null 2>&1; then
    git tag "$TAG" || die "git tag $TAG failed"
    ok "tagged $TAG"
  else
    ok "tag $TAG already exists locally"
  fi
  git push origin "$TAG" 2>/dev/null || warn "tag $TAG already on origin (or push skipped) — continuing"

  RO_NOTES="$TMP_DIR/notes.md"
  build_release_notes "$TAG" "$RO_NOTES"
  publish_release "$TAG" "$RO_NOTES"
  sign_release_artifact "$TAG"
  printf '\n%s%s✓ Released %s%s — https://github.com/randomittin/heimdall/releases/tag/%s\n' \
    "$G" "$B" "$TAG" "$R" "$TAG"
  exit 0
fi

# ── --npm-only: reconcile npm to the manifest's CURRENT version (npm-drift recovery) ──
# The npm analogue of --release-only, with the same semantics: publish the version ALREADY in
# the manifest, cut NO new version, tag nothing, push nothing, touch no file. This is the path
# that did not exist while `npm view runheimdall version` reported 2.0.5 and the repo shipped
# 2.2.6 — the only way to "fix" npm was to cut a fresh release, which is precisely what let the
# gap grow to twenty patch versions instead of closing it.
if [ "$NPM_ONLY" -eq 1 ]; then
  step "npm-only — publishing the version already in the manifest to npm"
  preflight_npm_prereqs
  NPM_ONLY_VERSION="$(read_version)"
  publish_npm "$NPM_ONLY_VERSION"
  printf '\n%s%s✓ npm reconciled to %s%s — https://www.npmjs.com/package/%s\n' \
    "$G" "$B" "$NPM_ONLY_VERSION" "$R" "$(npm_pkg_field name)"
  exit 0
fi

# ── 0. Version bump (skipped on --check / --no-bump) ─────────────────────────
# Runs BEFORE the scan/push so the bump commit ships and is R9-verified. The TAG +
# GitHub Release come AFTER R9 (only verified-clean history is released). This is
# what advances releases/latest so bin/heimdall-autoupdate rolls clients forward.
NEW_VERSION=""; TAG=""
if [ "$CHECK_ONLY" -eq 0 ] && [ "$DO_BUMP" -eq 1 ]; then
  step "Version bump"
  # Prove we CAN release before we mutate a single file. A bump we cannot follow through
  # with is what strands a version (see preflight_release_prereqs above). npm is proven here
  # for the same reason and at the same moment: an unauthenticated npm discovered at the END
  # of a ship leaves a bumped, tagged, released version that `npx runheimdall` cannot install.
  preflight_release_prereqs
  if [ "$DO_NPM" -eq 1 ]; then
    preflight_npm_prereqs
  else
    warn "--no-npm: this ship will NOT publish the npx wrapper to npm"
  fi
  CUR_VERSION="$(read_version)"
  reconcile_orphan_release "$CUR_VERSION"
  NEW_VERSION="$(compute_next "$CUR_VERSION" "$BUMP_KIND" "$EXPLICIT_VERSION")"
  TAG="v$NEW_VERSION"
  [ "$NEW_VERSION" = "$CUR_VERSION" ] && die "next version equals current ($CUR_VERSION) — nothing to bump"
  if git rev-parse -q --verify "refs/tags/$TAG" >/dev/null 2>&1 \
     || git ls-remote --exit-code --tags origin "refs/tags/$TAG" >/dev/null 2>&1; then
    die "tag $TAG already exists (local or origin) — refusing to re-release $NEW_VERSION"
  fi
  # A non-fast-forward push is what killed the v2.2.3 ship: main had diverged from origin,
  # the push at step 2 was rejected, and the bump commit was already made. Catch the
  # divergence BEFORE the bump so the operator merges first and no orphan is created.
  if git rev-parse -q --verify "origin/$BRANCH" >/dev/null 2>&1; then
    if ! git merge-base --is-ancestor "origin/$BRANCH" HEAD 2>/dev/null; then
      die "origin/$BRANCH has commits HEAD does not contain — the release push would be REJECTED and the bump commit would be stranded (this is the v2.2.3 defect). Merge/rebase origin/$BRANCH first, then re-run."
    fi
  fi
  write_version "$NEW_VERSION"
  git add "$PLUGIN_MANIFEST"
  # Pin install.sh's DEFAULT_REF to THIS tag so a fresh `curl|bash` install and hmd --update's
  # reinstall fallback fetch this release, not a stale default (the historical v2.0.5 downgrade
  # bug). Folded into the release commit so main + the tag always carry a current default.
  bump_default_ref "$TAG"
  # Single-source the version: RENDER every version surface from the manifest rather than
  # hand-patching each one. bin/heimdall-render-version owns VERSION + the README generated
  # region; release/sync-release.sh owns the tag-derived artifacts (the npx wrapper's
  # version/tag/url/sha256 and the vanity 302 targets). Both are idempotent and both are
  # gated by test/version-drift.test.sh, so the release commit cannot carry a stale surface.
  render_version_surfaces "$NEW_VERSION"
  sync_release_artifacts "$TAG"
  # SHA-pin README's install one-liner to the CURRENT verified HEAD (tags are force-movable; a
  # full commit SHA is immutable). That is the last R9-verified commit — the release commit has
  # no SHA until AFTER this commit is made (chicken-and-egg), and pinning fresh installs to
  # already-verified history is the safer supply-chain choice. Folded into the release commit.
  bump_readme_sha "$(git rev-parse HEAD)"
  git commit --no-verify -q -m "chore(release): $TAG" || die "bump commit failed"
  ok "bumped $CUR_VERSION → $NEW_VERSION (commit $(git rev-parse --short HEAD))"
elif [ "$DO_BUMP" -eq 0 ]; then
  warn "--no-bump: shipping without a version bump (no tag/release)"
fi

# ── Preview what will ship ───────────────────────────────────────────────────
step "Pending commits (origin/$BRANCH..HEAD)"
PENDING="$(git log --oneline "origin/$BRANCH..HEAD" 2>/dev/null || true)"
if [ -z "$PENDING" ]; then
  warn "nothing to push — HEAD matches origin/$BRANCH (verify will still run)"
else
  printf '%s\n' "$PENDING" | sed 's/^/  /'
fi

# ── 1. Local full-history secret scan ────────────────────────────────────────
step "Local gitleaks scan (full history)"
GL_RC=0
gitleaks detect --log-opts=--all || GL_RC=$?
[ "$GL_RC" -eq 0 ] || die "gitleaks found leaks (exit $GL_RC) — NOT pushing. Scrub history, then retry."
ok "no leaks in local history"

if [ "$CHECK_ONLY" -eq 1 ]; then
  printf '\n%s%sCheck complete%s — local scan clean. (--check: did not push.)\n' "$G" "$B" "$R"
  exit 0
fi

# ── 2. Push (repo's own pre-push guard fires here too) ───────────────────────
LOCAL_HEAD="$(git rev-parse HEAD)"
step "Push to origin/$BRANCH"
if [ -z "$PENDING" ]; then
  warn "already up to date — skipping push, proceeding to verify"
else
  git push origin "$BRANCH" || die "push failed — the pre-push guard may have blocked it (read above)"
  ok "pushed"
fi

# ── 3. R9 — verify from a fresh clone ────────────────────────────────────────
step "R9 verify (fresh clone of origin)"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/heimdall-r9.XXXXXX")"
cleanup() { rm -rf "$TMP_DIR" 2>/dev/null || true; }
trap cleanup EXIT
CLONE_DIR="$TMP_DIR/clone"
git clone --quiet "$REMOTE_URL" "$CLONE_DIR" || die "R9 clone failed"

# (a) gitleaks on the fresh clone
R9_GL_RC=0
( cd "$CLONE_DIR" && gitleaks detect --log-opts=--all ) >/dev/null 2>&1 || R9_GL_RC=$?
[ "$R9_GL_RC" -eq 0 ] || die "R9: gitleaks found leaks in the pushed history (exit $R9_GL_RC)"
ok "R9 gitleaks: clean"

# (b) identity allowlist — every author+committer email must be allowed. This
# delegates to bin/heimdall-check-identities, the SINGLE source of truth for the
# allowlist check (the SAME script the native pre-push hook runs), so the release
# gate and the pre-push gate can never disagree. It scans --all over the FRESH
# clone. The escape hatch is intentionally NOT honored here: a release verify runs
# with HEIMDALL_SKIP_ID_GUARD unset so R9 is unbypassable.
IDCHECK="$REPO_ROOT/bin/heimdall-check-identities"
[ -x "$IDCHECK" ] || die "R9: bin/heimdall-check-identities missing/not executable at $IDCHECK"
if ! ( cd "$CLONE_DIR" && HEIMDALL_SKIP_ID_GUARD= "$IDCHECK" --all ); then
  die "R9: non-allowlisted author/committer identity in pushed history (see above)"
fi
ok "R9 identities: all author+committer emails allowlisted"

# (c) HEAD match
CLONE_HEAD="$( cd "$CLONE_DIR" && git rev-parse HEAD )"
[ "$CLONE_HEAD" = "$LOCAL_HEAD" ] || die "R9: HEAD mismatch — local $LOCAL_HEAD vs origin $CLONE_HEAD"
ok "R9 HEAD matches: $LOCAL_HEAD"

printf '\n%s%s✓ Shipped & verified%s — pushed origin/%s, R9 clean (gitleaks 0, identities ok, HEAD matched).\n' \
  "$G" "$B" "$R" "$BRANCH"

# ── 5. Tag + GitHub Release (ONLY after R9 passed — release verified-clean history) ──
# This advances GitHub releases/latest, which is what bin/heimdall-autoupdate reads
# to roll clients forward. Without a published Release the version lags and no client
# updates — so a gh-absent run WARNS loudly with the exact command, never silently skips.
if [ -n "$TAG" ]; then
  step "Tag + GitHub Release ($TAG)"
  git tag "$TAG" || die "git tag $TAG failed"
  git push origin "$TAG" || die "pushing tag $TAG failed"
  ok "tagged + pushed $TAG"

  # gh presence/auth was PROVEN in preflight before anything was mutated, so there is no
  # warn-and-exit-0 branch here any more: reaching this point and failing to publish is a
  # hard, non-zero failure. Real notes → create-or-update → sign → attach, each exit-checked.
  NOTES_FILE="$TMP_DIR/release-notes-$TAG.md"
  build_release_notes "$TAG" "$NOTES_FILE"
  ok "built release notes for $TAG ($(wc -l < "$NOTES_FILE" | tr -d ' ') lines, from conventional commits)"
  publish_release "$TAG" "$NOTES_FILE"

  # Sign install.sh + attach install.sh.minisig so clients can VERIFY this release before
  # applying it. Key-absent is a documented WARN (RJ holds the key offline); a failure to
  # attach a sig we DID produce is a hard failure — see sign_release_artifact.
  sign_release_artifact "$TAG"

  printf '\n%s%s✓ Released %s%s — https://github.com/randomittin/heimdall/releases/tag/%s\n' \
    "$G" "$B" "$TAG" "$R" "$TAG"

  # ── 6. npm publish (the npx wrapper) ───────────────────────────────────────
  # ORDERING — this is LAST, after the tag is pushed and the Release is live, on purpose. The
  # wrapper's package.json bakes in installScriptUrl = raw.../<TAG>/install.sh and that tag's
  # sha256; publishing to npm BEFORE the tag exists on origin would put a package on the
  # registry whose install URL 404s. npm publishes are effectively IRREVERSIBLE (unpublish is
  # blocked after 72h and a version number can never be reused), whereas a missing Release can
  # be published after the fact with --release-only. So the recoverable step goes first and the
  # unrecoverable one goes last. npm's presence, auth, and publish rights were already PROVEN
  # in preflight before anything was mutated, so reaching this point and failing to publish is
  # a hard, non-zero failure with a named recovery path — never a warn-and-exit-0.
  if [ "$DO_NPM" -eq 1 ]; then
    step "npm publish ($(npm_pkg_field name)@$NEW_VERSION)"
    publish_npm "$NEW_VERSION"
    printf '\n%s%s✓ Published %s@%s%s — https://www.npmjs.com/package/%s\n' \
      "$G" "$B" "$(npm_pkg_field name)" "$NEW_VERSION" "$R" "$(npm_pkg_field name)"
  fi
fi
