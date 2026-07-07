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
#      history): git tag vX.Y.Z, push the tag, gh release create --generate-notes.
#
# Stops at the first failure. Nothing is pushed if the local scan finds leaks.
# Exit 0 = everything green.
#
# Usage:
#   release/ship.sh            full: patch-bump -> scan -> push -> R9 -> tag+release
#   release/ship.sh --minor    bump the minor version instead of patch
#   release/ship.sh --major    bump the major version
#   release/ship.sh --version X.Y.Z   set an explicit version
#   release/ship.sh --no-bump  ship without bumping (no new version/tag/release)
#   release/ship.sh --print-next   print the next version per the bump flag, exit (no mutation)
#   release/ship.sh --check    local scan + pending-commit preview, do NOT push/bump
#   release/ship.sh -h         this help

set -euo pipefail

# ── Config (edit if the repo's facts change) ─────────────────────────────────
BRANCH="main"
ALLOWED_IDENTITIES=("rj@runheimdall.dev" "noreply@anthropic.com")

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

  release/ship.sh              patch-bump -> scan -> push -> R9 verify -> tag + GitHub release
  release/ship.sh --minor      bump minor instead of patch
  release/ship.sh --major      bump major
  release/ship.sh --version X.Y.Z   set an explicit version
  release/ship.sh --no-bump    ship without a version bump (no tag/release)
  release/ship.sh --print-next print the next version (no mutation), exit
  release/ship.sh --check      local secret scan + show pending commits, do NOT push/bump
  release/ship.sh -h           this help

Stops at the first failure. Nothing is pushed if the local scan finds leaks.
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

  if command -v gh >/dev/null 2>&1; then
    if gh release upload "$tag" "$sig" --clobber >/dev/null 2>&1; then
      ok "uploaded install.sh.minisig to Release $tag — auto-update can now VERIFY this release"
    else
      warn "signing: gh release upload failed — the sig was NOT attached to $tag. Attach it with:"
      warn "  gh release upload $tag '$sig' --clobber"
      return 0
    fi
  else
    warn "signing: gh CLI absent — sig created at $sig but NOT uploaded. Attach it with:"
    warn "  gh release upload $tag '$sig' --clobber"
    return 0
  fi
  rm -rf "$sigdir"
}

# Test/introspection seam: `SHIP_SOURCE_ONLY=1 . release/ship.sh` defines the functions above
# (read_version, sign_release_artifact, …) WITHOUT running the release flow. Executed normally
# the variable is unset and we fall through to the real pipeline below.
if [ "${SHIP_SOURCE_ONLY:-0}" = "1" ]; then
  return 0 2>/dev/null || exit 0
fi

# ── Args (multi-flag: parse every argument, not just $1) ─────────────────────
CHECK_ONLY=0; BUMP_KIND="patch"; EXPLICIT_VERSION=""; DO_BUMP=1; PRINT_NEXT=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --check|--check-only) CHECK_ONLY=1 ;;
    --minor) BUMP_KIND="minor" ;;
    --major) BUMP_KIND="major" ;;
    --no-bump) DO_BUMP=0 ;;
    --print-next) PRINT_NEXT=1 ;;
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

# ── 0. Version bump (skipped on --check / --no-bump) ─────────────────────────
# Runs BEFORE the scan/push so the bump commit ships and is R9-verified. The TAG +
# GitHub Release come AFTER R9 (only verified-clean history is released). This is
# what advances releases/latest so bin/heimdall-autoupdate rolls clients forward.
NEW_VERSION=""; TAG=""
if [ "$CHECK_ONLY" -eq 0 ] && [ "$DO_BUMP" -eq 1 ]; then
  step "Version bump"
  CUR_VERSION="$(read_version)"
  NEW_VERSION="$(compute_next "$CUR_VERSION" "$BUMP_KIND" "$EXPLICIT_VERSION")"
  TAG="v$NEW_VERSION"
  [ "$NEW_VERSION" = "$CUR_VERSION" ] && die "next version equals current ($CUR_VERSION) — nothing to bump"
  if git rev-parse -q --verify "refs/tags/$TAG" >/dev/null 2>&1 \
     || git ls-remote --exit-code --tags origin "refs/tags/$TAG" >/dev/null 2>&1; then
    die "tag $TAG already exists (local or origin) — refusing to re-release $NEW_VERSION"
  fi
  write_version "$NEW_VERSION"
  git add "$PLUGIN_MANIFEST"
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

# (b) identity allowlist — every author+committer email must be allowed
IDENTITIES="$( ( cd "$CLONE_DIR" && git log --all --format='%ae%n%ce' ) | sort -u | sed '/^$/d' )"
BAD=""
while IFS= read -r email; do
  [ -z "$email" ] && continue
  allowed=0
  for a in "${ALLOWED_IDENTITIES[@]}"; do
    if [ "$email" = "$a" ]; then allowed=1; break; fi
  done
  [ "$allowed" -eq 0 ] && BAD="$BAD $email"
done <<< "$IDENTITIES"
[ -z "$BAD" ] || die "R9: non-allowlisted identity in history:$BAD"
ok "R9 identities: $(printf '%s' "$IDENTITIES" | tr '\n' ' ')"

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
  if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
    gh release create "$TAG" --generate-notes --title "$TAG" \
      || die "gh release create $TAG failed — tag is pushed; run: gh release create $TAG --generate-notes --title $TAG"
    ok "published GitHub Release $TAG — auto-update's releases/latest now advances"
    # Sign install.sh + attach install.sh.minisig so clients can VERIFY this release before
    # applying it. Best-effort: WARNS + releases UNSIGNED if no minisign/key (never blocks RJ).
    sign_release_artifact "$TAG"
  else
    warn "gh CLI absent or unauthenticated — tag $TAG is pushed but the GitHub RELEASE was NOT published."
    warn "auto-update reads releases/latest, so it will LAG until you run:"
    warn "  gh release create $TAG --generate-notes --title $TAG"
  fi
fi
