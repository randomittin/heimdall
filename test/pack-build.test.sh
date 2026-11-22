#!/usr/bin/env bash
# pack-build.test.sh -- proves bin/heimdall-pack-build (T2.2 of the 3.x lean-core plan, docs/superpowers/plans/2026-11-12-3x-lean-core.md): it builds the @runhmd/stacks pack
# directory from skills/stacks and prints the content hash that skills.manifest.json and the lock will pin. A pin is worth something only if two builds of one tree agree.
#
#   1. DETERMINISM  on the real skills/stacks: `hash` twice, then `build` twice (the second from another cwd, under umask 077, another TZ, into a directory whose parents
#                   do not exist yet) print ONE 64-hex hash; the two built trees are `diff -r` identical; files are 0644 and directories 0755 whatever the umask; the
#                   source tree is byte for byte what it was.
#   2. LAYOUT       every source file is copied verbatim, the only additions are hmd.skill.yaml and SHA256SUMS, the yaml names the pack, a semver and the stack ids found
#                   in the tree, and carries no clock and no path; SHA256SUMS is the format sha256sum -c reads.
#   3. THE HASH     re-derived here, independently of the tool, from the documented rule: sha256 of SHA256SUMS, which is every other file's `<sha256>  <path>` line in
#                   bytewise path order. A fixture whose names sort one way bytewise and another under a locale pins the order literally.
#   4. SENSITIVITY  the falsifiability half: one changed byte, an added file, a deleted file and a renamed file each change the hash; an mtime, a file mode, the name
#                   of the source directory and a .DS_Store do not.
#   5. REFUSALS     a symlink, an executable, a name outside [A-Za-z0-9._-], a reserved name, no SKILL.md, a missing source, an output that is not an absent or empty
#                   directory, an output inside the source, a parent that cannot be made and a write that fails midway are each exit 2 with nothing on stdout and nothing
#                   left behind (no half-written pack, no staging directory); usage errors are exit 2 too.
#
# Every expected value is derived here (find, cmp, python3 hashlib), never read back from the tool. HMD_PACK_BUILD_BIN points the suite at another copy of the tool
# (a mutated copy, to watch an assertion go red). bash 3.2 compatible; about 45 runs of a 50 ms tool, a few seconds.
#
# Usage:  bash test/pack-build.test.sh
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SELF_DIR/.." && pwd)"
CLI="${HMD_PACK_BUILD_BIN:-$REPO/bin/heimdall-pack-build}"
SRC_REAL="$REPO/skills/stacks"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; }

# nothing of the caller's environment may leak into a case
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR GIT_PREFIX HEIMDALL_HOME CLAUDE_PLUGIN_ROOT

T="$(mktemp -d "${TMPDIR:-/tmp}/pack-build.XXXXXX")" || exit 1; T="$(cd "$T" && pwd -P)"
cleanup() { chmod -R u+rwX "$T" 2>/dev/null; rm -rf "$T"; }
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

echo "pack-build (heimdall-pack-build: the @runhmd/stacks pack, deterministic, and its content hash)"

# ── helpers: every run writes $T/<name>.{out,err,rc} ───────────────────────────────────────────────────────────────────────────────────
run() { local n="$1"; shift; "$CLI" "$@" >"$T/$n.out" 2>"$T/$n.err"; echo $? >"$T/$n.rc"; }
rc() { cat "$T/$1.rc" 2>/dev/null; }
show() { printf 'rc=%s out=[%s] err=[%s]' "$(rc "$1")" "$(head -c 300 "$T/$1.out" 2>/dev/null)" "$(head -c 300 "$T/$1.err" 2>/dev/null)"; }
eo() { [ -f "$T/$1.out" ] && [ ! -s "$T/$1.out" ]; }                 # stdout of run $1 is empty
ge() { grep -qF -- "$2" "$T/$1.err" 2>/dev/null; }                    # stderr of run $1 contains $2
hashof() { head -n 1 "$T/$1.out" 2>/dev/null; }                       # first stdout line of run $1
is_hash() { printf '%s' "$1" | grep -Eq '^[0-9a-f]{64}$'; }
tree_sig() { ( cd "$1" 2>/dev/null && find . | LC_ALL=C sort && find . -type f | LC_ALL=C sort | while IFS= read -r f; do cksum < "$f"; done ); }   # names + cksum of every file

# oracle DIR: the content hash re-derived from the files in DIR by the documented rule; exit 1 when SHA256SUMS is not exactly the listing the rule produces
oracle() {
  python3 -I -c '
import hashlib, os, sys
root = sys.argv[1]
rels = []
for base, _dirs, names in os.walk(root):
    for name in names:
        rels.append(os.path.relpath(os.path.join(base, name), root).replace(os.sep, "/"))
listing = ""
for rel in sorted(r for r in rels if r != "SHA256SUMS"):
    with open(os.path.join(root, rel), "rb") as handle:
        listing += "%s  %s\n" % (hashlib.sha256(handle.read()).hexdigest(), rel)
with open(os.path.join(root, "SHA256SUMS"), "rb") as handle:
    recorded = handle.read()
print(hashlib.sha256(listing.encode("utf-8")).hexdigest())
sys.exit(0 if recorded == listing.encode("utf-8") else 1)
' "$1" 2>/dev/null
}

# mkfx DIR: a stacks-shaped tree whose names sort one way bytewise and another under a locale; alpha/PACK.md is 4 KiB (the one file ulimit -f 1 cannot write)
mkfx() {
  mkdir -p "$1/alpha" "$1/a" "$1/a-b"
  printf -- '---\nname: fx\ndescription: fixture pack\n---\n\n# fx\n' > "$1/SKILL.md"
  printf '# fixture readme\n' > "$1/README.md"
  printf 'bee\n' > "$1/B.md"
  printf '# a\n' > "$1/a/PACK.md"
  printf '# a-b\n' > "$1/a-b/PACK.md"
  head -c 4096 /dev/zero | tr '\0' 'x' > "$1/alpha/PACK.md"
}

echo "-- 0. the tool exists, runs and prints its usage --"
if [ -x "$CLI" ]; then ok "bin/heimdall-pack-build exists and is executable"; else bad "$CLI is missing or not executable"; fi
run help --help
if [ "$(rc help)" = 0 ] && grep -q 'build' "$T/help.out" && grep -q 'hash' "$T/help.out" && [ ! -s "$T/help.err" ]; then ok "--help: exit 0, on stdout, names build and hash, nothing on stderr"; else bad "--help: $(show help)"; fi
run u1
run u2 build --src "$T"
run u3 hash --bogus
run u4 frobnicate
if [ "$(rc u1)" = 2 ] && [ "$(rc u2)" = 2 ] && [ "$(rc u3)" = 2 ] && [ "$(rc u4)" = 2 ] && eo u1 && eo u2 && eo u3 && eo u4 && ge u2 '--out' && ge u3 '--bogus'; then ok "no command, build without --out, an unknown flag and an unknown command are each exit 2 with nothing on stdout"; else bad "usage errors: $(show u1) / $(show u2) / $(show u3) / $(show u4)"; fi

echo "-- 1. determinism on the real skills/stacks --"
SIG0="$(tree_sig "$SRC_REAL")"
run h1 hash --src "$SRC_REAL"
run h2 hash --src "$SRC_REAL"
H="$(hashof h1)"
if [ "$(rc h1)" = 0 ] && is_hash "$H" && [ "$(cat "$T/h1.out")" = "$H" ] && [ "$(cat "$T/h2.out")" = "$H" ]; then ok "hash prints exactly one 64-hex line, the same on two runs ($H)"; else bad "hash: $(show h1) / $(show h2)"; fi
run b1 build --src "$SRC_REAL" --out "$T/real1"
( cd "$T" && umask 077 && TZ=Pacific/Kiritimati "$CLI" build --src "$SRC_REAL" --out "$T/nested/deeper/real2" >"$T/b2.out" 2>"$T/b2.err"; echo $? >"$T/b2.rc" )
if [ "$(rc b1)" = 0 ] && [ "$(rc b2)" = 0 ] && [ "$(cat "$T/b1.out")" = "$H" ] && [ "$(cat "$T/b2.out")" = "$H" ]; then ok "two builds print exactly the hash that hash printed (the second: another cwd, umask 077, another TZ, parents that did not exist)"; else bad "builds: $(show b1) / $(show b2)"; fi
if diff -r "$T/real1" "$T/nested/deeper/real2" >/dev/null 2>&1; then ok "the two built trees are diff -r identical"; else bad "the two built trees differ (or one is missing)"; fi
if [ -d "$T/nested/deeper/real2" ] && [ -z "$(find "$T/nested/deeper/real2" -type f ! -perm 0644)" ] && [ -z "$(find "$T/nested/deeper/real2" -type d ! -perm 0755)" ]; then ok "built under umask 077, every file is 0644 and every directory 0755"; else bad "modes under umask 077: $(find "$T/nested/deeper/real2" ! -perm 0644 ! -perm 0755 2>/dev/null | head -n 3 | tr '\n' ' ')"; fi
if [ "$(tree_sig "$SRC_REAL")" = "$SIG0" ]; then ok "the source tree is byte for byte what it was after four runs"; else bad "skills/stacks changed while the tool ran"; fi
if [ -n "${HMD_PACK_BUILD_BIN:-}" ]; then
  ok "(a mutated copy is under test: the default --src is only checked on the real script)"
else
  run hdef hash
  if [ "$(rc hdef)" = 0 ] && [ "$(cat "$T/hdef.out")" = "$H" ]; then ok "with no --src the tool reads the skills/stacks next to it"; else bad "hash with no --src: $(show hdef)"; fi
fi

echo "-- 2. the built layout --"
SRC_LIST="$(cd "$SRC_REAL" && find . -type f ! -name .DS_Store | LC_ALL=C sort)"
OUT_LIST="$(cd "$T/real1" 2>/dev/null && find . -type f ! -name hmd.skill.yaml ! -name SHA256SUMS | LC_ALL=C sort)"
NSRC="$(printf '%s\n' "$SRC_LIST" | wc -l | tr -d ' ')"
NOUT="$(find "$T/real1" -type f 2>/dev/null | wc -l | tr -d ' ')"
if [ -n "$SRC_LIST" ] && [ "$SRC_LIST" = "$OUT_LIST" ] && [ -f "$T/real1/hmd.skill.yaml" ] && [ -f "$T/real1/SHA256SUMS" ] && [ "$NOUT" = "$((NSRC+2))" ]; then ok "the pack holds every file of skills/stacks ($NSRC), hmd.skill.yaml and SHA256SUMS, and nothing else"; else bad "file lists differ: source [$(printf '%s' "$SRC_LIST" | tr '\n' ' ')] built [$(printf '%s' "$OUT_LIST" | tr '\n' ' ')] ($NOUT files)"; fi
DIFFS=""
while IFS= read -r f; do [ -n "$f" ] || continue; cmp -s "$SRC_REAL/$f" "$T/real1/$f" || DIFFS="$DIFFS $f"; done <<EOF
$SRC_LIST
EOF
if [ -z "$DIFFS" ] && [ -n "$SRC_LIST" ]; then ok "every source file is copied byte for byte"; else bad "copies that differ from their source:${DIFFS:- (none built)}"; fi
if ge b1 '@runhmd/stacks'; then ok "build says on stderr which pack it built"; else bad "build stderr: $(head -c 200 "$T/b1.err")"; fi
Y="$T/real1/hmd.skill.yaml"
SIGNALS="$(cd "$SRC_REAL" && for d in */; do [ -f "${d}PACK.md" ] && printf '%s\n' "${d%/}"; done | LC_ALL=C sort | paste -sd, - | sed 's/,/, /g')"
if grep -qxF 'id: runhmd/stacks' "$Y" 2>/dev/null && grep -Eqx 'version: [0-9]+\.[0-9]+\.[0-9]+' "$Y" && grep -qxF "  signals: [$SIGNALS]" "$Y" && grep -qxF '  network: none' "$Y" && grep -Eq '^summary: ".+"$' "$Y"; then ok "hmd.skill.yaml names runhmd/stacks, a semver, the stack ids found in the tree (signals: [$SIGNALS]) and no network"; else bad "yaml: $(head -c 500 "$Y" 2>&1)"; fi
if [ -f "$Y" ] && ! grep -Eq '[0-9]{4}-[0-9]{2}-[0-9]{2}|[0-9]{2}:[0-9]{2}:[0-9]{2}' "$Y" && ! grep -qF "$T" "$Y" && ! grep -qF "$REPO" "$Y"; then ok "hmd.skill.yaml carries no date, no time and no path of this machine"; else bad "the yaml has a clock or a path in it, or is missing"; fi
SUMS="$T/real1/SHA256SUMS"
if [ -f "$SUMS" ] && [ "$(wc -l < "$SUMS" | tr -d ' ')" = "$((NSRC+1))" ] && ! grep -Evq '^[0-9a-f]{64}  [A-Za-z0-9][A-Za-z0-9._/-]*$' "$SUMS"; then ok "SHA256SUMS has one '<sha256>  <path>' line per file but itself ($((NSRC+1)))"; else bad "SHA256SUMS: $(head -c 300 "$SUMS" 2>&1)"; fi
if command -v sha256sum >/dev/null 2>&1; then CHK="sha256sum -c"; elif command -v shasum >/dev/null 2>&1; then CHK="shasum -a 256 -c"; else CHK=""; fi
if [ -z "$CHK" ]; then ok "(neither sha256sum nor shasum is installed: the -c check is skipped)"
elif [ -f "$SUMS" ] && ( cd "$T/real1" && $CHK SHA256SUMS >/dev/null 2>&1 ); then ok "$CHK reads SHA256SUMS and every listed file matches"; else bad "$CHK did not accept SHA256SUMS"; fi

echo "-- 3. the hash, re-derived independently --"
OH="$(oracle "$T/real1")"; ORC=$?
if [ "$ORC" = 0 ] && [ "$OH" = "$H" ]; then ok "sha256 over the sorted '<sha256>  <path>' lines of the built files equals the printed hash, and those lines are SHA256SUMS' bytes"; else bad "independent derivation: rc=$ORC [$OH] against printed [$H]"; fi
FXA="$T/fxa"; mkfx "$FXA"
FXSIG="$(tree_sig "$FXA")"
run fa hash --src "$FXA"
run fb build --src "$FXA" --out "$T/fxa-out"
FA="$(hashof fa)"
OH2="$(oracle "$T/fxa-out")"; ORC2=$?
if [ "$(rc fa)" = 0 ] && [ "$(rc fb)" = 0 ] && is_hash "$FA" && [ "$(cat "$T/fb.out")" = "$FA" ] && [ "$ORC2" = 0 ] && [ "$OH2" = "$FA" ]; then ok "the fixture: hash and build agree with the independent derivation ($FA)"; else bad "fixture: $(show fa) / $(show fb) / oracle rc=$ORC2 [$OH2]"; fi
ORDER="$(cut -c 67- "$T/fxa-out/SHA256SUMS" 2>/dev/null | paste -sd' ' -)"
if [ "$ORDER" = "B.md README.md SKILL.md a-b/PACK.md a/PACK.md alpha/PACK.md hmd.skill.yaml" ]; then ok "paths are in bytewise order: B.md before README.md, a-b/PACK.md before a/PACK.md (a locale would interleave them)"; else bad "listing order: [$ORDER]"; fi
if grep -qxF '  signals: [a, a-b, alpha]' "$T/fxa-out/hmd.skill.yaml" 2>/dev/null; then ok "signals are the directories holding a PACK.md, in bytewise order (a, a-b, alpha; B.md and README.md are not stacks)"; else bad "signals: $(grep -n signals "$T/fxa-out/hmd.skill.yaml" 2>&1)"; fi
mkdir "$T/emptyout"
run eo1 build --src "$FXA" --out "$T/emptyout"
if [ "$(rc eo1)" = 0 ] && [ "$(cat "$T/eo1.out")" = "$FA" ] && diff -r "$T/emptyout" "$T/fxa-out" >/dev/null 2>&1; then ok "an existing EMPTY output directory is accepted and receives the same pack"; else bad "build into an empty directory: $(show eo1)"; fi

echo "-- 4. what changes the hash, and what does not --"
# probe NAME EXPECT DESC SCRIPT: a fresh copy of the fixture (directory p-NAME, so the source directory's name differs every time), SCRIPT run inside it, then hash
probe() {
  local name="$1" expect="$2" desc="$3" script="$4" got
  rm -rf "$T/p-$name"; cp -R "$FXA" "$T/p-$name"
  ( cd "$T/p-$name" && eval "$script" ) >/dev/null 2>&1
  run "p-$name" hash --src "$T/p-$name"
  got="$(hashof "p-$name")"
  if [ "$(rc "p-$name")" != 0 ] || ! is_hash "$got"; then bad "$desc: $(show "p-$name")"; return; fi
  if [ "$expect" = differs ] && [ "$got" != "$FA" ]; then ok "$desc: the hash changes"
  elif [ "$expect" = same ] && [ "$got" = "$FA" ]; then ok "$desc: the hash does not change"
  else bad "$desc: expected the hash to be $expect, got $got against $FA"; fi
}
probe byte differs "one changed byte (B.md)" "printf 'bed\n' > B.md"
probe add differs "an added file" "printf 'x\n' > alpha/extra.md"
probe del differs "a deleted file" "rm B.md"
probe ren differs "a renamed file (same bytes, new name)" "mv B.md C.md"
probe mtime same "a file's mtime" "touch -t 200001010000 B.md alpha/PACK.md"
probe mode same "file modes (0600, 0664)" "chmod 600 B.md; chmod 664 SKILL.md"
probe ds same ".DS_Store files, at the top and inside a stack" "printf junk > .DS_Store; printf junk > alpha/.DS_Store"
run dsb build --src "$T/p-ds" --out "$T/p-ds-out"
if [ "$(rc dsb)" = 0 ] && [ -d "$T/p-ds-out" ] && [ -z "$(find "$T/p-ds-out" -name .DS_Store)" ] && [ "$(cat "$T/dsb.out")" = "$FA" ]; then ok "a .DS_Store is neither copied into the pack nor listed in it"; else bad "build over .DS_Store: $(show dsb)"; fi

echo "-- 5. what it refuses, and that it leaves nothing behind --"
# refuse NAME NEEDLE DESC SCRIPT [hash]: SCRIPT breaks a fresh copy of the fixture, then build (or hash) must be exit 2, NEEDLE on stderr, nothing on stdout, no output, no staging
refuse() {
  local name="$1" needle="$2" desc="$3" script="$4" cmd="${5:-build}"
  rm -rf "$T/r-$name" "$T/o-$name"; cp -R "$FXA" "$T/r-$name"
  ( cd "$T/r-$name" && eval "$script" ) >/dev/null 2>&1
  if [ "$cmd" = build ]; then run "r-$name" build --src "$T/r-$name" --out "$T/o-$name/pack"; else run "r-$name" hash --src "$T/r-$name"; fi
  if [ "$(rc "r-$name")" = 2 ] && eo "r-$name" && ge "r-$name" "$needle" && [ ! -e "$T/o-$name/pack" ] && [ -z "$(ls -A "$T/o-$name" 2>/dev/null)" ]; then ok "$desc: exit 2, '$needle' on stderr, nothing on stdout, nothing left behind"; else bad "$desc: $(show "r-$name")"; fi
}
refuse symfile "symbolic link" "a symlink to a file" "ln -s B.md link.md"
refuse symdir "symbolic link" "a symlink to a directory" "ln -s alpha linked"
refuse exec "executable" "an executable file" "chmod 755 B.md"
refuse space "[A-Za-z0-9._-]" "a name with a space" "cp B.md 'has space.md'"
refuse newline "[A-Za-z0-9._-]" "a name with a newline (it would forge a SHA256SUMS line)" "cp B.md \$'two\nlines.md'"
refuse hidden "[A-Za-z0-9._-]" "a hidden file other than .DS_Store" "cp B.md .hidden"
refuse rsums "reserved" "a source file named SHA256SUMS" "printf x > SHA256SUMS"
refuse ryaml "reserved" "a source file named hmd.skill.yaml" "printf x > hmd.skill.yaml"
refuse noskill "SKILL.md" "a tree without SKILL.md" "rm SKILL.md"
refuse hashsym "symbolic link" "hash refuses what build refuses (a symlink)" "ln -s B.md link.md" hash
run nosrc build --src "$T/does-not-exist" --out "$T/o-nosrc/pack"
run filesrc hash --src "$T/h1.out"
if [ "$(rc nosrc)" = 2 ] && [ "$(rc filesrc)" = 2 ] && eo nosrc && eo filesrc && ge nosrc 'not a directory' && ge filesrc 'not a directory' && [ ! -e "$T/o-nosrc" ]; then ok "a missing source and a source that is a file: exit 2, 'not a directory', nothing on stdout, nothing created"; else bad "bad sources: $(show nosrc) / $(show filesrc)"; fi
SIGR="$(tree_sig "$T/real1")"
printf x > "$T/afile"
run onon build --src "$FXA" --out "$T/real1"
run ofile build --src "$FXA" --out "$T/afile"
run oin build --src "$FXA" --out "$FXA/pack-here"
run opar build --src "$FXA" --out "$T/afile/sub/pack"
if [ "$(rc onon)" = 2 ] && eo onon && ge onon 'not an empty directory' && [ "$(tree_sig "$T/real1")" = "$SIGR" ]; then ok "an output directory that already holds a pack is refused and left exactly as it was (builds never overwrite)"; else bad "output not empty: $(show onon)"; fi
if [ "$(rc ofile)" = 2 ] && eo ofile && ge ofile 'not an empty directory' && [ "$(cat "$T/afile")" = x ]; then ok "an output path that is a file is refused and the file is untouched"; else bad "output is a file: $(show ofile)"; fi
if [ "$(rc oin)" = 2 ] && eo oin && ge oin 'inside the source' && [ ! -e "$FXA/pack-here" ]; then ok "an output inside the source is refused (the source is never written to)"; else bad "output inside source: $(show oin)"; fi
if [ "$(rc opar)" = 2 ] && eo opar && ge opar 'cannot write' && [ "$(cat "$T/afile")" = x ]; then ok "an output whose parent cannot be made (a file in the way) is exit 2, 'cannot write'"; else bad "unmakeable parent: $(show opar)"; fi
rm -rf "$T/o-wf"
( ulimit -f 1 && "$CLI" build --src "$FXA" --out "$T/o-wf/pack" >"$T/wf.out" 2>"$T/wf.err"; echo $? >"$T/wf.rc" )
if [ "$(rc wf)" = 2 ] && eo wf && ge wf 'cannot write' && [ ! -e "$T/o-wf/pack" ] && [ -z "$(ls -A "$T/o-wf" 2>/dev/null)" ]; then ok "a write that fails midway (ulimit -f 1: alpha/PACK.md is 4 KiB) is exit 2 and leaves no pack and no staging directory"; else bad "failed write: $(show wf) leftovers: $(ls -A "$T/o-wf" 2>&1 | tr '\n' ' ')"; fi
if [ "$(tree_sig "$FXA")" = "$FXSIG" ]; then ok "the fixture source is byte for byte what it was after every build, hash and refusal above"; else bad "the fixture source changed while the tool ran"; fi

printf '\npack-build: %s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
