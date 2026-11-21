#!/usr/bin/env bash
#
# heimdall-vendor.test.sh -- T1.1 of docs/superpowers/plans/2026-11-22-split-skills-statusline-repos.md: bin/heimdall-vendor (the logic is bin/lib/vendor_lock.py),
# the tool that keeps heimdall's mirror of the split-out skills and statusline repos equal to the tag vendor/vendor.lock.json pins (INV-S1).
#
# The tool is worth something only if a drift cannot go unseen and a bad tag cannot be written, so every claim is a GREEN control next to a RED mutation
# of one thing, run against throwaway repositories (every source is a local path: no network):
#   A. the hash is the documented one: the lock is written with a tree_sha256 and a commit computed by SHELL (shasum, sort, printf, git rev-parse: not the
#      tool's code) and `verify` agrees. The plan's accept: the launcher is executable and `verify --help` names tree_sha256.
#   B. verify is RED (exit 1, naming the file where it can) for an edited file (same size), a missing file, a dropped exec bit, a link, a directory in a file's
#      place, a link in a parent directory, a path dropped from the lock, a path added to it, a flipped tree_sha256; one repository drifting under --all makes
#      the run RED while the other is still reported ok.
#   C. a tampered or invalid lock is exit 1, never a traceback (bad JSON, a duplicate or unknown key, bad hashes, a `..`, absolute, `.git` or backslash path,
#      a path or name listed twice, a repo or tag that could be an option, a link for a lock, an empty `repos`, a missing lock); a bad command line is exit 2.
#   D. sync restores edited, missing, exec-dropped and deleted-directory files byte for byte (exec bit from the tag); a second sync writes nothing (same inodes);
#      it REFUSES, and writes nothing, for a tag that moved (even to identical content), a lock whose tree_sha256 is not the tag's, a tag that does not exist, a
#      source that cannot be read and a tag whose file is a link; it never writes through a linked directory; a failed write leaves no temp file.
#   E. diff shows a hand edit as a unified diff of the pinned file against the mirror; a missing file, a mode change, a binary change and a moved tag are named.
#   F. verify --upstream is green for the pinned tag and RED for a moved one; the environment a git hook gives (GIT_DIR, GIT_INDEX_FILE, GIT_OBJECT_DIRECTORY)
#      does not redirect the temporary repository the tool fetches into.
#   G. the assertions have teeth: three one-line breaks of a COPY of the tool (the exec flag dropped from the hash, the content left out of it, the commit check
#      removed) turn the matching case from RED to green.
# budget: ~10 s of CPU (user+sys, measured; wall time is 2-3x that on a busy machine): ~95 runs of python3, ~30 of them with a git fetch, over a few-byte fixture, no network.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
TOOL="$ROOT/bin/heimdall-vendor"

pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n' "$1"; }

skip() { echo "SKIP: $1"; echo "heimdall-vendor: 0 passed, 0 failed (SKIPPED: $1)"; exit 0; }
for need in python3 git jq; do command -v "$need" >/dev/null 2>&1 || skip "$need unavailable"; done
if command -v shasum >/dev/null 2>&1; then sha256() { shasum -a 256 | cut -d' ' -f1; }
elif command -v sha256sum >/dev/null 2>&1; then sha256() { sha256sum | cut -d' ' -f1; }
else skip "no shasum or sha256sum"; fi
if [ ! -x "$TOOL" ] || [ ! -f "$ROOT/bin/lib/vendor_lock.py" ]; then
  echo "FATAL: $TOOL is missing or not executable, or bin/lib/vendor_lock.py is missing"; echo "heimdall-vendor: 0 passed, 1 failed"; exit 1
fi

WORK="$(mktemp -d)" || { echo "FATAL: cannot make a temp dir"; exit 1; }
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/home"
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_COMMON_DIR GIT_NAMESPACE GIT_PREFIX GIT_QUARANTINE_PATH
export HOME="$WORK/home" XDG_CONFIG_HOME="$WORK/home/.config" GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null GIT_TERMINAL_PROMPT=0

G() { git -c user.name=vendor-test -c user.email=vendor-test@example.invalid -c commit.gpgsign=false -c tag.gpgsign=false -c init.defaultBranch=main "$@"; }

OUT=""; RC=0
# run <tool args>: OUT is stdout and stderr, RC the exit status
run() { OUT="$("$TOOL" "$@" 2>&1)"; RC=$?; }
# contains <text> <needle>: a literal substring test in the shell itself (no grep process: ~100 assertions)
contains() { [[ "$1" == *"$2"* ]]; }
# green <label> <needle> <tool args>: exit 0 and the output names <needle>
green() {
  local label="$1" needle="$2"; shift 2
  run "$@"
  if [ "$RC" = 0 ] && contains "$OUT" "$needle"; then ok "$label"; else bad "$label (exit $RC, wanted 0 naming '$needle'): $(head -3 <<<"$OUT")"; fi
}
# red <label> <needle> <tool args>: exit 1, the output names <needle>, and it is a report, not a traceback
red() {
  local label="$1" needle="$2"; shift 2
  run "$@"
  if [ "$RC" = 1 ] && contains "$OUT" "$needle" && ! contains "$OUT" Traceback; then ok "$label"; else bad "$label (exit $RC, wanted 1 naming '$needle'): $(head -3 <<<"$OUT")"; fi
}
# usage_error <label> <tool args>: exit 2
usage_error() {
  local label="$1"; shift
  run "$@"
  if [ "$RC" = 2 ] && ! contains "$OUT" Traceback; then ok "$label"; else bad "$label (exit $RC, wanted 2): $(head -2 <<<"$OUT")"; fi
}
# has <label> <needle>: the last run's output names <needle>
has() { if contains "$OUT" "$2"; then ok "$1"; else bad "$1: the output lacks '$2': $(head -3 <<<"$OUT")"; fi; }
# check <label> <command...>: the command succeeds
check() { local label="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$label"; else bad "$label"; fi; }

# tree_hash <dir> <path>...: the documented tree_sha256 of those files, by shell (plan section 3; the same recipe `heimdall-vendor --help` prints)
tree_hash() {
  local dir="$1" p; shift
  { printf 'heimdall-vendor tree/1\n'
    for p in $(printf '%s\n' "$@" | LC_ALL=C sort); do
      printf '%s %s %s\n' "$(sha256 < "$dir/$p")" "$([ -x "$dir/$p" ] && echo x || echo -)" "$p"
    done
  } | sha256
}

# ---- fixtures: two upstream repositories (an annotated and a lightweight tag), the lock over them, and a mirror equal to both ---------------------------
S1="$WORK/hmd-skills.src"
mkdir -p "$S1/skills/demo/scripts" "$S1/skills/demo/references" "$S1/skills/demo/assets" "$S1/scripts"
printf '# Demo skill\n\nline two\nline three\n' > "$S1/skills/demo/SKILL.md"
printf '#!/bin/sh\necho demo\n' > "$S1/skills/demo/scripts/run.sh"; chmod +x "$S1/skills/demo/scripts/run.sh"
printf 'notes one\nnotes two\n' > "$S1/skills/demo/references/notes.md"
printf '\000\001\002binary\377\n' > "$S1/skills/demo/assets/icon.bin"
printf 'not mirrored\n' > "$S1/README.md"
printf '#!/bin/sh\n' > "$S1/scripts/lint.sh"
P1="skills/demo/SKILL.md skills/demo/scripts/run.sh skills/demo/references/notes.md skills/demo/assets/icon.bin"
( cd "$S1" && G init -q && G add -A && G commit -q -m "v1 content" && G tag -a v1.0.0 -m "demo 1.0.0" ) >/dev/null 2>&1

S2="$WORK/hmd-statusline.src"
mkdir -p "$S2/hooks" "$S2/sentinels"
printf '#!/bin/sh\nexec true\n' > "$S2/hooks/statusline.sh"; chmod +x "$S2/hooks/statusline.sh"
printf 'print("hud")\n' > "$S2/sentinels/render.py"
P2="hooks/statusline.sh sentinels/render.py"
( cd "$S2" && G init -q && G add -A && G commit -q -m "v1 content" && G tag v1.0.0 ) >/dev/null 2>&1

# three more upstreams, copies of the first with one change each: a tag moved to other content, a tag moved to the SAME content, a tag whose file is a link
M="$WORK/s1.moved"; cp -Rp "$S1" "$M"
( cd "$M" && printf 'upstream change\n' >> skills/demo/SKILL.md && G commit -q -am "change" && G tag -f -a v1.0.0 -m moved ) >/dev/null 2>&1
M2="$WORK/s1.same"; cp -Rp "$S1" "$M2"
( cd "$M2" && C="$(G commit-tree 'HEAD^{tree}' -p HEAD -m same)" && G tag -f v1.0.0 "$C" ) >/dev/null 2>&1
M3="$WORK/s1.link"; cp -Rp "$S1" "$M3"
( cd "$M3" && rm skills/demo/references/notes.md && ln -s ../SKILL.md skills/demo/references/notes.md && G add -A && G commit -q -m link && G tag v1.0.1 ) >/dev/null 2>&1

entry() { # entry <name> <repo> <tag> <srcdir> <paths...>: one lock entry, hashes by shell and git
  local name="$1" repo="$2" tag="$3" src="$4"; shift 4
  jq -n --arg name "$name" --arg repo "$repo" --arg tag "$tag" --arg commit "$(git -C "$src" rev-parse "$tag^{commit}")" \
    --arg tree "$(tree_hash "$src" "$@")" '{name:$name,repo:$repo,tag:$tag,commit:$commit,tree_sha256:$tree,paths:$ARGS.positional}' --args "$@"
}
PRISTINE="$WORK/pristine"; mkdir -p "$PRISTINE/vendor"
for p in $P1; do mkdir -p "$PRISTINE/$(dirname "$p")"; cp -p "$S1/$p" "$PRISTINE/$p"; done
for p in $P2; do mkdir -p "$PRISTINE/$(dirname "$p")"; cp -p "$S2/$p" "$PRISTINE/$p"; done
jq -n --argjson a "$(entry hmd-skills "$S1" v1.0.0 "$S1" $P1)" --argjson b "$(entry hmd-statusline "$S2" v1.0.0 "$S2" $P2)" \
  '{schema:1,repos:[$a,$b]}' > "$PRISTINE/vendor/vendor.lock.json"
T="$WORK/tree"
LOCK="$T/vendor/vendor.lock.json"
fresh() { rm -rf "$T"; cp -Rp "$PRISTINE" "$T"; }   # a clean mirror and its lock
FLIP='(if .[0:1]=="0" then "1"+.[1:] else "0"+.[1:] end)'

check "fixture: the lock names two repositories and the moved tags are other commits (with the same content for s1.same)" bash -c '
  [ "$(jq ".repos|length" "$1")" = 2 ] &&
  [ "$(git -C "$2" rev-parse "v1.0.0^{commit}")" != "$(git -C "$3" rev-parse "v1.0.0^{commit}")" ] &&
  [ "$(git -C "$4" rev-parse "v1.0.0^{commit}")" != "$(git -C "$3" rev-parse "v1.0.0^{commit}")" ] &&
  [ "$(git -C "$4" rev-parse "v1.0.0^{tree}")" = "$(git -C "$3" rev-parse "v1.0.0^{tree}")" ] &&
  [ "$(git -C "$5" rev-parse "v1.0.1^{commit}")" != "" ]' _ "$PRISTINE/vendor/vendor.lock.json" "$M" "$S1" "$M2" "$M3"

echo "== A) the launcher, and the hash is the documented one =="
check "bin/heimdall-vendor is executable (the plan's accept)" test -x "$TOOL"
check "verify --help names tree_sha256 (the plan's accept)" bash -c '"$0" verify --help | grep -q tree_sha256' "$TOOL"
run --help
if [ "$RC" = 0 ] && grep -qw sync <<<"$OUT" && grep -qw verify <<<"$OUT" && grep -qw diff <<<"$OUT"; then ok "--help lists sync, verify and diff"
else bad "--help (exit $RC): $(head -3 <<<"$OUT")"; fi
fresh
green "control: a clean mirror verifies, against a hash and a commit that shell and git computed" "ok hmd-skills" verify hmd-skills --root "$T"
green "--all verifies both repositories" "ok hmd-statusline" verify --all --root "$T"
has "--all names the first repository too" "ok hmd-skills"
ln -s "$TOOL" "$WORK/vendor-link"
OUT="$("$WORK/vendor-link" verify --all --root "$T" 2>&1)"; RC=$?
if [ "$RC" = 0 ] && grep -qF "ok hmd-skills" <<<"$OUT"; then ok "the launcher works through a symlink"; else bad "launcher through a symlink (exit $RC): $(head -3 <<<"$OUT")"; fi

echo "== B) verify is RED for each drift =="
fresh; printf 'X' | dd of="$T/skills/demo/SKILL.md" bs=1 count=1 conv=notrunc 2>/dev/null
red "an edited file (one byte flipped, same size)" "tree_sha256 differs" verify hmd-skills --root "$T"
run verify --all --root "$T"
if [ "$RC" = 1 ] && grep -qF "FAIL hmd-skills" <<<"$OUT" && grep -qF "ok hmd-statusline" <<<"$OUT"; then ok "--all with one drifted repository is RED and still reports the other as ok"
else bad "--all with one drift (exit $RC): $(head -3 <<<"$OUT")"; fi
fresh; rm "$T/skills/demo/references/notes.md"
red "a missing file, named" "FAIL hmd-skills skills/demo/references/notes.md: missing" verify hmd-skills --root "$T"
fresh; chmod -x "$T/skills/demo/scripts/run.sh"
red "a dropped exec bit (hooks/statusline.sh must stay executable)" "tree_sha256 differs" verify hmd-skills --root "$T"
fresh; rm "$T/skills/demo/SKILL.md"; ln -s "$S1/skills/demo/SKILL.md" "$T/skills/demo/SKILL.md"
red "a link to a file with the SAME bytes" "a link" verify hmd-skills --root "$T"
fresh; rm "$T/skills/demo/SKILL.md"; mkdir "$T/skills/demo/SKILL.md"
red "a directory where a file belongs" "not a regular file" verify hmd-skills --root "$T"
fresh; mv "$T/skills/demo" "$T/skills/real"; ln -s real "$T/skills/demo"
red "a link where a parent directory belongs" "parent directory is a link" verify hmd-skills --root "$T"
fresh; jq 'del(.repos[0].paths[1])' "$LOCK" > "$LOCK.new" && mv "$LOCK.new" "$LOCK"
red "a path dropped from the lock" "tree_sha256 differs" verify hmd-skills --root "$T"
fresh; jq '.repos[0].paths += ["skills/demo/ghost.md"]' "$LOCK" > "$LOCK.new" && mv "$LOCK.new" "$LOCK"
red "a path added to the lock that is not in the mirror" "skills/demo/ghost.md: missing" verify hmd-skills --root "$T"
fresh; jq ".repos[0].tree_sha256 |= $FLIP" "$LOCK" > "$LOCK.new" && mv "$LOCK.new" "$LOCK"
red "a tree_sha256 off by one digit" "tree_sha256 differs" verify hmd-skills --root "$T"
has "the report prints both hashes, so a pin can be corrected" "mirror $(tree_hash "$S1" $P1)"

echo "== C) a tampered or invalid lock is exit 1 and never a traceback; a bad command line is exit 2 =="
tampered() { # tampered <label> <needle> <jq filter>: the lock changed by the filter is exit 1 naming <needle>
  local label="$1" needle="$2" filter="$3"
  fresh; jq "$filter" "$LOCK" > "$LOCK.new" && mv "$LOCK.new" "$LOCK"
  red "$label" "$needle" verify --all --root "$T"
}
fresh; printf '{' > "$LOCK";                                  red "a lock that is not JSON" "not valid JSON" verify --all --root "$T"
fresh; printf '{"schema":1,"schema":1,"repos":[]}' > "$LOCK"; red "a lock with a duplicate key" "duplicate key" verify --all --root "$T"
fresh; printf '[]' > "$LOCK";                                 red "a lock that is not an object" "not an object" verify --all --root "$T"
fresh; rm "$LOCK";                                            red "no lock at all" "no lock at" verify --all --root "$T"
fresh; mv "$LOCK" "$T/vendor/real.json"; ln -s real.json "$LOCK"; red "a lock that is a symbolic link" "symbolic link" verify --all --root "$T"
fresh; rm "$LOCK"; mkdir "$LOCK";                             red "a lock that is a directory" "not a regular file" verify --all --root "$T"
tampered "an unknown top-level key" "unexpected key" '.extra=1'
tampered "an unknown key in a repository" "unexpected key" '.repos[0].note="x"'
tampered "a repository without paths" "missing key" 'del(.repos[0].paths)'
tampered "schema 2" "schema" '.schema=2'
tampered "schema true (a bool is not 1)" "schema" '.schema=true'
tampered "a commit that is not hex" "commit" '.repos[0].commit="xyz"'
tampered "an upper-case tree_sha256" "tree_sha256" '.repos[0].tree_sha256 |= ascii_upcase'
tampered "paths that are a string" "paths" '.repos[0].paths="skills/demo/SKILL.md"'
tampered "repos that are an object" "repos" '.repos={}'
tampered "a path with .." "unsafe component" '.repos[0].paths[0]="skills/../../etc/passwd"'
tampered "an absolute path" "unsafe component" '.repos[0].paths[0]="/etc/passwd"'
tampered "a .git component" "unsafe component" '.repos[0].paths[0]="skills/.git/config"'
tampered "a .gitattributes file" "unsafe component" '.repos[0].paths[0]=".gitattributes"'
tampered "a backslash path" "unsafe component" '.repos[0].paths[0]="skills\\demo"'
tampered "a path listed twice" "duplicate path" '.repos[0].paths += [.repos[0].paths[0]]'
tampered "a path listed by two repositories" "duplicate path" '.repos[1].paths += [.repos[0].paths[0]]'
tampered "a path that differs only in case (one file on macOS)" "duplicate path" '.repos[0].paths += ["SKILLS/demo/skill.md"]'
tampered "a name used twice" "duplicate name" '.repos[1].name = .repos[0].name'
tampered "a tag that looks like an option" "tag" '.repos[0].tag="-x"'
tampered "a repo that looks like an option" "repo" '.repos[0].repo="--upload-pack=x"'
tampered "a repo with an ext:: transport" "repo" '.repos[0].repo="ext::sh -c id"'
fresh; jq '.repos=[]' "$LOCK" > "$LOCK.new" && mv "$LOCK.new" "$LOCK"
red "--all over a lock with no repositories verifies nothing, so it fails" "lists no repositories" verify --all --root "$T"
usage_error "no command"
usage_error "an unknown command" bogus
fresh
usage_error "verify without NAME or --all" verify --root "$T"
usage_error "a NAME the lock does not list" verify nosuch --root "$T"
has "the error lists the names the lock has" "hmd-skills"
usage_error "NAME together with --all" verify hmd-skills --all --root "$T"
usage_error "--source with --all (it names one clone)" sync --all --source "$S1" --root "$T"
usage_error "verify --source without --upstream" verify hmd-skills --source "$S1" --root "$T"
usage_error "a --source that looks like an option" sync hmd-skills --source=--upload-pack=x --root "$T"
usage_error "a --root that is not a directory" verify --all --root "$WORK/none"

echo "== D) sync restores the mirror from the pinned tag, and refuses what the lock does not pin =="
fresh
printf 'HAND EDIT\n' >> "$T/skills/demo/SKILL.md"; rm "$T/skills/demo/references/notes.md"; chmod -x "$T/skills/demo/scripts/run.sh"; rm -rf "$T/skills/demo/assets"
red "control: the drifted mirror is RED before the sync" "FAIL hmd-skills" verify hmd-skills --root "$T"
run sync hmd-skills --root "$T"
if [ "$RC" = 0 ] && grep -qF "synced hmd-skills: 4 of 4 files written" <<<"$OUT"; then ok "sync rewrites the edited, missing, exec-dropped and deleted-directory files"
else bad "sync (exit $RC): $(head -3 <<<"$OUT")"; fi
green "after the sync verify is green" "ok hmd-skills" verify hmd-skills --root "$T"
same=1; for p in $P1; do cmp -s "$S1/$p" "$T/$p" || same=0; done
if [ "$same" = 1 ]; then ok "every synced file equals the pinned tag's, byte for byte"; else bad "a synced file differs from the tag's"; fi
if [ -x "$T/skills/demo/scripts/run.sh" ] && [ ! -x "$T/skills/demo/SKILL.md" ]; then ok "the exec bit comes from the tag"; else bad "the exec bits after the sync are wrong"; fi
inodes() { local p; for p in $P1; do ls -i "$T/$p" | awk '{print $1}'; done | tr '\n' ' '; }
before="$(inodes)"
run sync hmd-skills --root "$T"
if [ "$RC" = 0 ] && grep -qF "already in sync hmd-skills" <<<"$OUT" && [ "$before" = "$(inodes)" ]; then ok "a second sync is idempotent: it says so and rewrites no file (same inodes)"
else bad "second sync (exit $RC): $(head -3 <<<"$OUT")"; fi
green "sync --all on a clean mirror: both already in sync" "already in sync hmd-statusline" sync --all --root "$T"

drift_mirror() { fresh; printf 'HAND EDIT\n' >> "$T/skills/demo/SKILL.md"; chmod -x "$T/skills/demo/scripts/run.sh"; }
snap() { # a checksum of every file under the tree, with its path and exec bit (cksum: cheap, and not the tool's hash)
  ( cd "$T" && find . -type f | LC_ALL=C sort | while read -r f; do printf '%s %s ' "$f" "$([ -x "$f" ] && echo x || echo -)"; cksum < "$f"; done ) | cksum
}
refuses() { # refuses <label> <needle> <jq filter on the lock> <sync args...>: exit 1 naming <needle> and the drifted mirror is byte for byte what it was
  local label="$1" needle="$2" filter="$3" before; shift 3
  drift_mirror
  jq "$filter" "$LOCK" > "$LOCK.new" && mv "$LOCK.new" "$LOCK"
  before="$(snap)"
  red "$label" "$needle" sync "$@" --root "$T"
  if [ "$(snap)" = "$before" ]; then ok "$label: nothing was written"; else bad "$label: the mirror changed"; fi
}
refuses "a tag that moved to other content" "the lock pins" '.' hmd-skills --source "$M"
refuses "a tag that moved to a commit with IDENTICAL content" "the lock pins" '.' hmd-skills --source "$M2"
refuses "a lock whose tree_sha256 is not the tag's" "tree_sha256" ".repos[0].tree_sha256 |= $FLIP" hmd-skills
refuses "a tag that does not exist" "cannot fetch tag v9.9.9" '.repos[0].tag="v9.9.9"' hmd-skills
refuses "a source that cannot be read" "cannot fetch tag v1.0.0" '.' hmd-skills --source "$WORK/does-not-exist"
refuses "a tag whose file is a link" "a link or a submodule" '.repos[0].tag="v1.0.1"' hmd-skills --source "$M3"

fresh; rm "$T/skills/demo/references/notes.md"; mkdir -p "$T/skills/demo/references/notes.md/sub"
red "a directory where a mirrored file belongs: sync fails naming the file" "skills/demo/references/notes.md: cannot write" sync hmd-skills --root "$T"
LEFT="$(find "$T" -name '.heimdall-vendor.*' | head -1)"
if [ -z "$LEFT" ]; then ok "a failed write leaves no temp file behind"; else bad "temp file left behind: $LEFT"; fi
fresh; mv "$T/skills/demo" "$T/skills/real"; ln -s real "$T/skills/demo"; printf 'HAND EDIT\n' >> "$T/skills/real/SKILL.md"
red "a link where a mirrored directory belongs: sync refuses to write through it" "is a link or not a directory" sync hmd-skills --root "$T"
if grep -qF 'HAND EDIT' "$T/skills/real/SKILL.md"; then ok "nothing was written through the link"; else bad "sync wrote through a linked directory"; fi

echo "== E) diff shows what differs from the pinned tag =="
fresh
green "no drift: nothing to show" "no difference hmd-skills" diff hmd-skills --root "$T"
printf 'HAND EDIT\n' >> "$T/skills/demo/SKILL.md"
run diff hmd-skills --root "$T"
if [ "$RC" = 1 ] && grep -qF "changed hmd-skills skills/demo/SKILL.md" <<<"$OUT" && grep -qxF '+HAND EDIT' <<<"$OUT"; then ok "a hand edit is shown as a unified diff (+HAND EDIT) naming the file"
else bad "diff of a hand edit (exit $RC): $(head -5 <<<"$OUT")"; fi
fresh; rm "$T/skills/demo/references/notes.md"
red "a missing file is named" "changed hmd-skills skills/demo/references/notes.md: missing" diff hmd-skills --root "$T"
fresh; chmod -x "$T/skills/demo/scripts/run.sh"
red "a mode change is named" "mode executable (tag) -> not executable (mirror)" diff hmd-skills --root "$T"
fresh; printf 'x' >> "$T/skills/demo/assets/icon.bin"
red "a binary change is reported without printing the bytes" "binary or non-UTF-8" diff hmd-skills --root "$T"
fresh
red "a moved tag: diff names the lock and shows what the new tag changes" "the lock pins" diff hmd-skills --source "$M" --root "$T"
has "and the file the new tag changed" "changed hmd-skills skills/demo/SKILL.md"
fresh; printf 'HAND EDIT\n' >> "$T/skills/demo/SKILL.md"
red "--all with a drift in one repository is RED" "no difference hmd-statusline" diff --all --root "$T"

echo "== F) verify --upstream, and a git hook's environment =="
fresh
green "the pinned tag upstream is the pinned commit and tree" "tag checked upstream" verify --all --upstream --root "$T"
red "a moved tag upstream is RED even though the mirror still matches the lock" "the lock pins" verify hmd-skills --upstream --source "$M" --root "$T"
red "an unreadable source is RED, not silently skipped" "cannot fetch tag v1.0.0" verify hmd-skills --upstream --source "$WORK/does-not-exist" --root "$T"
drift_mirror
OUT="$(GIT_DIR="$WORK/none/.git" GIT_INDEX_FILE="$WORK/none/index" GIT_OBJECT_DIRECTORY="$WORK/none/objects" GIT_WORK_TREE="$WORK/none" "$TOOL" sync hmd-skills --root "$T" 2>&1)"; RC=$?
if [ "$RC" = 0 ] && [ ! -e "$WORK/none" ] && grep -qF "synced hmd-skills" <<<"$OUT"; then ok "with GIT_DIR, GIT_INDEX_FILE, GIT_OBJECT_DIRECTORY and GIT_WORK_TREE set (a git hook) sync still works and writes into no other repository"
else bad "sync under a hook's git environment (exit $RC): $(head -3 <<<"$OUT")"; fi

echo "== G) the assertions have teeth: a COPY of the tool with one line broken =="
MUT="$WORK/mut/bin/heimdall-vendor"
mutant() { # mutant <label> <old> <new>: a copy of the tool whose vendor_lock.py has <old> (found exactly once) replaced by <new>
  rm -rf "$WORK/mut"; mkdir -p "$WORK/mut/bin/lib"
  cp "$ROOT/bin/heimdall-vendor" "$WORK/mut/bin/"; cp "$ROOT/bin/lib/vendor_lock.py" "$WORK/mut/bin/lib/"
  if python3 -I - "$WORK/mut/bin/lib/vendor_lock.py" "$2" "$3" <<'PY'
import sys
path, old, new = sys.argv[1:4]
text = open(path, encoding="utf-8").read()
if text.count(old) != 1:
    sys.exit("mutation site %r found %d times" % (old, text.count(old)))
open(path, "w", encoding="utf-8").write(text.replace(old, new))
PY
  then return 0; else bad "$1: the mutation did not apply (vendor_lock.py moved on?)"; return 1; fi
}
run_mut() { OUT="$("$MUT" "$@" 2>&1)"; RC=$?; }
fresh
if mutant "exec flag" '"x" if executable else "-"' '"-"'; then
  run_mut verify hmd-skills --root "$T"
  if [ "$RC" = 1 ] && grep -qF "tree_sha256 differs" <<<"$OUT"; then ok "a hash without the exec flag no longer agrees with the documented one (the clean control goes RED)"
  else bad "mutant: exec flag left out of the hash (exit $RC) was not caught by the clean control"; fi
fi
if mutant "content" 'return hashlib.sha256(data).hexdigest()' 'return hashlib.sha256(b"").hexdigest()'; then
  run_mut verify hmd-skills --root "$T"
  if [ "$RC" = 1 ] && grep -qF "tree_sha256 differs" <<<"$OUT"; then ok "a hash that leaves the file bytes out no longer agrees with the documented one (the clean control goes RED)"
  else bad "mutant: file bytes left out of the hash (exit $RC) was not caught by the clean control"; fi
fi
if mutant "commit check" 'if commit != entry["commit"]:' 'if False:'; then
  run_mut sync hmd-skills --source "$M2" --root "$T"
  if [ "$RC" = 0 ]; then ok "without the commit check the re-tagged commit is synced: the refusal in D is that check and nothing else"
  else bad "mutant: commit check removed still refused (exit $RC): $(head -2 <<<"$OUT")"; fi
fi

echo
echo "heimdall-vendor: $pass passed, $fail failed"
[ "$fail" -eq 0 ] || exit 1
