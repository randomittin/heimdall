#!/usr/bin/env bash
# ship.sh — scan, push, and verify origin in one step ("step 1", automated).
#
# Runs the full routine you've been doing by hand:
#   1. preview the commits about to ship (origin/BRANCH..HEAD)
#   2. local gitleaks scan over FULL history — stop & do NOT push if anything is found
#   3. git push origin BRANCH  (the repo's own pre-push guard also fires here)
#   4. R9 — independent verify from a FRESH clone of origin:
#        (a) gitleaks clean on the pushed history
#        (b) every author+committer email is on the identity allowlist
#        (c) origin HEAD matches local HEAD
#
# Stops at the first failure. Nothing is pushed if the local scan finds leaks.
# Exit 0 = everything green.
#
# Usage:
#   release/ship.sh            full: scan -> push -> R9 verify
#   release/ship.sh --check    local scan + pending-commit preview, do NOT push
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
ship.sh — scan, push, and verify in one step.

  release/ship.sh           full: local secret scan -> push origin -> R9 fresh-clone verify
  release/ship.sh --check   local secret scan + show pending commits, do NOT push
  release/ship.sh -h        this help

Stops at the first failure. Nothing is pushed if the local scan finds leaks.
USAGE
}

# ── Args ─────────────────────────────────────────────────────────────────────
CHECK_ONLY=0
case "${1:-}" in
  --check|--check-only) CHECK_ONLY=1 ;;
  -h|--help) usage; exit 0 ;;
  "") : ;;
  *) die "unknown arg: ${1:-}  (try --check or -h)" ;;
esac

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
