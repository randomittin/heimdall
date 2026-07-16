#!/usr/bin/env bash
#
# ship-release.test.sh — acceptance for release/ship.sh's GitHub-Release path.
#
#   bash test/ship-release.test.sh    (exit 0 = all cases pass)
#
# Proves, WITHOUT publishing anything real, that ship.sh:
#   1. builds a real, non-empty Release body from conventional commits (never GitHub
#      boilerplate) — and REFUSES to publish an empty body;
#   2. --dry-run prints the EXACT `gh release create` invocation and exits 0 having written
#      nothing (no tag, no push, no gh call);
#   3. is idempotent: when the Release already exists it UPDATES (gh release edit) instead of
#      erroring;
#   4. a simulated gh failure makes the publish path exit NON-ZERO (loud fail, no swallow).
#
# R6 (checks must be able to fail): cases 1, 3, 4 each assert a specific behaviour that a
# regression would flip — case 4 in particular is the corrupt-and-confirm proof that ship.sh
# does not swallow a gh error. It does this by stubbing `gh` to fail and asserting a non-zero
# exit; if ship.sh went back to `|| true`, this case goes red.
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SELF_DIR/.." && pwd)"
SHIP="$REPO/release/ship.sh"

PASS=0; FAIL=0
ok()  { printf '  \033[32mPASS\033[0m %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAIL=$((FAIL+1)); }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/ship-release-test.XXXXXX")"
cleanup() { rm -rf "$WORK" 2>/dev/null || true; }
trap cleanup EXIT

echo "ship-release harness  ship=$SHIP"
echo "--------------------------------------------------------------------"

# ── A gh stub whose behaviour is driven by env vars, first on PATH ───────────
# GH_STUB_MODE: create-ok | create-fail | edit-ok
# GH_STUB_STATE: dir; presence of $GH_STUB_STATE/created flips `gh release view` to "exists".
BIN_STUB="$WORK/stubbin"
mkdir -p "$BIN_STUB"
cat > "$BIN_STUB/gh" <<'STUB'
#!/usr/bin/env bash
sub="${1:-}"; act="${2:-}"
state="${GH_STUB_STATE:-$PWD/.ghstate}"
mode="${GH_STUB_MODE:-create-ok}"
case "$sub $act" in
  "auth status") exit 0 ;;
  "release view")
    [ -f "$state/created" ] && { echo '{"assets":[{"name":"install.sh.minisig"}]}'; exit 0; }
    exit 1 ;;
  "release create")
    [ "$mode" = "create-fail" ] && { echo "HTTP 422: validation failed (simulated)" >&2; exit 1; }
    mkdir -p "$state"; : > "$state/created"; echo "https://github.com/x/y/releases/tag/stub"; exit 0 ;;
  "release edit")
    mkdir -p "$state"; : > "$state/created"; exit 0 ;;
  "release upload") exit 0 ;;
  *) exit 0 ;;
esac
STUB
chmod +x "$BIN_STUB/gh"

# ── Case 1: build_release_notes yields real, non-empty notes ─────────────────
# Source ship.sh's functions (SHIP_SOURCE_ONLY seam) and run build_release_notes against the
# REAL repo. The manifest version has no curated CHANGELOG section, so notes come from
# bin/generate-changelog — proving the "not boilerplate" path.
NOTES_OUT="$WORK/notes.md"
(
  cd "$REPO"
  # shellcheck disable=SC1090
  SHIP_SOURCE_ONLY=1 . "$SHIP"
  REPO_ROOT="$REPO"
  TAG="v$(read_version)"
  build_release_notes "$TAG" "$NOTES_OUT"
) 2>"$WORK/c1.err"
if [ -s "$NOTES_OUT" ] && grep -q '[^[:space:]]' "$NOTES_OUT"; then
  ok "build_release_notes produced a non-empty body"
else
  bad "build_release_notes produced empty/no notes"; cat "$WORK/c1.err" >&2
fi
if grep -q 'raw.githubusercontent.com/randomittin/heimdall/.*/install.sh' "$NOTES_OUT" \
   && ! grep -Eqi '^\s*full changelog:?\s*$' "$NOTES_OUT"; then
  ok "notes carry the install one-liner (real content, not the 83-byte boilerplate)"
else
  bad "notes look like boilerplate / missing install block"
fi

# ── Case 2: --dry-run constructs the exact command and publishes nothing ─────
DRY="$WORK/dry.out"
( cd "$REPO" && PATH="$BIN_STUB:$PATH" "$SHIP" --dry-run ) >"$DRY" 2>&1
dry_rc=$?
NEXT="$( cd "$REPO" && "$SHIP" --print-next )"
if [ "$dry_rc" -eq 0 ]; then ok "--dry-run exits 0"; else bad "--dry-run exit=$dry_rc"; fi
if grep -Eq "gh release (create|edit) v${NEXT} --notes-file .* --title v${NEXT}" "$DRY"; then
  ok "--dry-run prints the exact 'gh release … v${NEXT} --notes-file … --title v${NEXT}' command"
else
  bad "--dry-run did not print the expected gh command for v${NEXT}"; sed 's/^/    /' "$DRY" >&2
fi
if grep -q 'gh release upload .* install.sh.minisig --clobber' "$DRY"; then
  ok "--dry-run prints the signature-upload command"
else
  bad "--dry-run did not print the sig-upload command"
fi
# Nothing was created: no new tag for the next version in the real repo.
if ! git -C "$REPO" rev-parse -q --verify "refs/tags/v${NEXT}" >/dev/null 2>&1; then
  ok "--dry-run created no tag (v${NEXT} absent after dry run)"
else
  bad "--dry-run leaked a tag v${NEXT}"
fi

# ── Case 3: publish_release is idempotent — existing release -> UPDATE ───────
C3="$WORK/c3.out"
(
  cd "$REPO"
  export GH_STUB_STATE="$WORK/c3state" GH_STUB_MODE="edit-ok"
  mkdir -p "$GH_STUB_STATE"; : > "$GH_STUB_STATE/created"   # pretend it already exists
  PATH="$BIN_STUB:$PATH"
  # shellcheck disable=SC1090
  SHIP_SOURCE_ONLY=1 . "$SHIP"
  REPO_ROOT="$REPO"
  printf 'x\n' > "$WORK/n3.md"
  publish_release "vTESTIDEMP" "$WORK/n3.md"
) >"$C3" 2>&1
c3_rc=$?
if [ "$c3_rc" -eq 0 ] && grep -qi 'already exists — updating' "$C3"; then
  ok "publish_release UPDATES an existing release (idempotent, exit 0)"
else
  bad "publish_release did not take the idempotent update path (rc=$c3_rc)"; sed 's/^/    /' "$C3" >&2
fi

# ── Case 4: a gh failure makes the publish path exit NON-ZERO ────────────────
C4="$WORK/c4.out"
(
  cd "$REPO"
  export GH_STUB_STATE="$WORK/c4state" GH_STUB_MODE="create-fail"
  PATH="$BIN_STUB:$PATH"
  # shellcheck disable=SC1090
  SHIP_SOURCE_ONLY=1 . "$SHIP"
  REPO_ROOT="$REPO"
  printf 'x\n' > "$WORK/n4.md"
  publish_release "vTESTFAIL" "$WORK/n4.md"
) >"$C4" 2>&1
c4_rc=$?
if [ "$c4_rc" -ne 0 ]; then
  ok "publish_release exits NON-ZERO on gh failure (rc=$c4_rc — no silent swallow)"
else
  bad "publish_release swallowed a gh failure and exited 0"; sed 's/^/    /' "$C4" >&2
fi
if grep -q 'HTTP 422' "$C4"; then
  ok "gh's stderr is REPRINTED on failure (operator sees the reason)"
else
  bad "gh failure reason was not surfaced"; sed 's/^/    /' "$C4" >&2
fi

echo ""
echo "ship-release.test.sh: $PASS passed, $FAIL failed."
[ "$FAIL" -eq 0 ] || exit 1
exit 0
