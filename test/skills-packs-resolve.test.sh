#!/usr/bin/env bash
# skills-packs-resolve.test.sh -- proves bin/lib/skills_packs.py (3.x lean-core plan T2.1, docs/superpowers/plans/2026-11-12-3x-lean-core.md; INV-L5 of
# .planning/lean-core/INVARIANTS.md: "pack with hash mismatch or missing => bundled copy, silent, never an error; a bundled copy is never deleted"):
# `skills_packs.py resolve ID` names the directory hmd reads a skill from, the installed pack or the bundled copy.
#
# The contract it implements is the pack format of bin/heimdall-pack-build (T2.2): an installed pack is $HEIMDALL_HOME/packs/<id>/, a copy of skills/<id> plus
# hmd.skill.yaml plus SHA256SUMS (every other file's "<sha256>  <path>" line, bytewise path order), and its content hash is the sha256 of SHA256SUMS. The pin is the
# machine lock, $HEIMDALL_HOME/skills.lock: the row of the id, installed, with that hash as its content_hash. To verify, the resolver recomputes the lines from the
# files on disk and requires them to equal SHA256SUMS, and requires sha256(SHA256SUMS) to equal the pin: SHA256SUMS alone says nothing about a file edited after the
# build, the files alone say nothing about which build they came from. The fixtures are built here with shasum, by the rule written above, never by the code under
# test; their lock rows are written by the real lock writer (bin/lib/skills_lock.py).
#
#   A. PACK       an installed pack that matches the pin wins; another skill has its own pack and its own row; an id nobody pinned, and a skill with no pack, are bundled;
#                 .DS_Store files, an empty directory and an exec bit are not part of the pin; a symlinked or non-ASCII HEIMDALL_HOME works.
#   B. INV-L5     each defect alone falls back to the bundled copy: exit 0, nothing on stderr, that path and nothing else on stdout.
#                 Pack: no packs dir, no pack for the id, a file where the pack should be, SHA256SUMS missing or a link; a file edited after the build, emptied, missing,
#                 a directory, a link, an unlisted file added; a rebuild after an edit (files and SHA256SUMS agree, the hash is not the pinned one); a name the builder
#                 would refuse, even with files, SHA256SUMS and lock all agreeing.
#                 Lock: missing, not JSON, another schema, a link, unreadable; no row for the id; a row declined; the hash differs, is null, or is only a prefix.
#   C. LEAN       a lean tree (the bundled copy sparse-removed) is still answered with the bundled path, and nothing is created.
#   D. ROOTS      the bundled root is CLAUDE_PLUGIN_ROOT, else the tree the resolver lives in; the home is HEIMDALL_HOME, else ~/.heimdall (unset or empty); relative
#                 roots come back absolute; a repository in the working directory (its lock, its packs, planted json.py / skills_lock.py) steers nothing.
#   E. API        resolve() returns (path, source) and rejects a bad id.
#   F. REAL DATA  the real skills/stacks as a pack (hashed here); and, when bin/heimdall-pack-build is in the tree, the pack THAT builds, pinned by the hash it prints.
#   G. USAGE      bad arguments exit 2 with a usage line and nothing on stdout, and create nothing; --help exits 0.
#
# Every call also proves the resolver is read-only: a fingerprint of everything under the case's directory (names, modes, inodes, links, sizes, mtimes) is equal before
# and after. Hermetic: each call runs under env -i with a private HOME, no network, python3 -B -I -S. HMD_PACKS_BIN points the suite at another copy of the resolver
# (a mutated one, to watch an assertion go red; its skills_lock.py must sit beside it). bash 3.2 compatible. About 70 process spawns of a stdlib-only script: a few
# seconds.
#
# Usage:  bash test/skills-packs-resolve.test.sh
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SELF_DIR/.." && pwd)"
LIB="${HMD_PACKS_BIN:-$REPO/bin/lib/skills_packs.py}"
LOCK_LIB="$REPO/bin/lib/skills_lock.py"
BUILDER="$REPO/bin/heimdall-pack-build"
PASS=0; FAIL=0
ok()     { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad()    { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; }
skip()   { printf '  skip %s\n' "$1"; }
finish() { printf '\nskills-packs-resolve: %s passed, %s failed\n' "$PASS" "$FAIL"; [ "$FAIL" -eq 0 ]; exit $?; }

echo "skills-packs-resolve (the installed pack when it is what the lock pins, else the bundled copy, silently)"

echo "-- 0. the resolver and the lock writer exist --"
if [ -f "$LIB" ]; then ok "the resolver exists ($LIB)"; else bad "the resolver is missing ($LIB; T2.1 creates bin/lib/skills_packs.py)"; finish; fi
if [ -f "$LOCK_LIB" ]; then ok "bin/lib/skills_lock.py exists (the lock the pin is read from)"; else bad "bin/lib/skills_lock.py is missing"; finish; fi

# nothing of the caller's environment may steer a run: every call below builds its own
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR GIT_PREFIX CLAUDE_PLUGIN_ROOT HEIMDALL_HOME
T="$(mktemp -d "${TMPDIR:-/tmp}/skills-packs-test.XXXXXX")" || exit 2; T="$(cd "$T" && pwd -P)"
cleanup() { chmod -R u+rwX "$T" 2>/dev/null; rm -rf "$T"; }
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

PY="$(command -v python3 || true)"
[ -n "$PY" ] || { echo "FATAL: python3 not found"; exit 2; }
# the real interpreter, not a version-manager shim (0.3 s a call, and this suite starts about 80 of them)
REALPY="$("$PY" -I -c 'import sys; print(sys.executable)' 2>/dev/null)"
case "$REALPY" in /*) ;; *) REALPY="" ;; esac
[ -n "$REALPY" ] && [ -x "$REALPY" ] || { echo "FATAL: cannot resolve the interpreter behind $PY"; exit 2; }
NONROOT=0; [ "$(id -u)" -ne 0 ] && NONROOT=1

CASE_DIR=""   # the directory of the current case: the fingerprint covers it, and it holds the plugin root, the home and the private HOME
CWD=""        # working directory of the next call; empty = CASE_DIR
LIBRUN=""     # the resolver the next call runs; empty = $LIB
P=""; H=""; LOCK=""

# ── helpers ────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
# run [VAR=value ...] -- ARGS...   run the resolver with ARGS in an environment built from nothing (PATH, a private HOME, and the VAR=value given); sets OUT ERR RC.
run() {
  local assign=(PATH="$PATH" HOME="${CASE_DIR:-$T}/hh")
  while [ "$#" -gt 0 ] && [ "$1" != "--" ]; do assign+=("$1"); shift; done
  shift
  (cd "${CWD:-${CASE_DIR:-$T}}" && env -i "${assign[@]}" "$REALPY" -B -I -S "${LIBRUN:-$LIB}" "$@" >"$T/out" 2>"$T/err")
  RC=$?
  OUT="$(cat "$T/out")"; ERR="$(cat "$T/err")"
}
# fp DIR   one number for everything under DIR: names, modes, inodes (a replaced file has a new one), link targets, sizes and mtimes (find -ls)
fp() { ( cd "$1" && find . -ls | cksum ); }
# answers LABEL WANT [VAR=value ...] -- ARGS...   the call prints exactly WANT and a newline, exits 0, says nothing on stderr and changes nothing under CASE_DIR
answers() {
  local label="$1" want="$2" before after; shift 2
  before="$(fp "$CASE_DIR")"
  run "$@"
  after="$(fp "$CASE_DIR")"
  printf '%s\n' "$want" > "$T/want"
  if [ "$RC" -ne 0 ] || [ -n "$ERR" ] || ! cmp -s "$T/out" "$T/want"; then
    bad "$label (rc=$RC out=[$OUT] err=[$ERR]; wanted [$want])"
  elif [ "$before" != "$after" ]; then
    bad "$label (the call changed something under $CASE_DIR)"
  else
    ok "$label"
  fi
}
# expect LABEL pack|bundled ID   `resolve ID` against the case's plugin root and heimdall home names that copy of the skill
expect() {
  local want="$P/skills/$3"
  [ "$2" = pack ] && want="$H/packs/$3"
  answers "$1" "$want" CLAUDE_PLUGIN_ROOT="$P" HEIMDALL_HOME="$H" -- resolve "$3"
}
# usage_error LABEL ARGS...   exits 2, nothing on stdout, a usage line (no traceback) on stderr, nothing changed under CASE_DIR
usage_error() {
  local label="$1" before after; shift
  before="$(fp "$CASE_DIR")"
  run CLAUDE_PLUGIN_ROOT="$P" HEIMDALL_HOME="$H" -- "$@"
  after="$(fp "$CASE_DIR")"
  if [ "$RC" -eq 2 ] && [ -z "$OUT" ] && printf '%s' "$ERR" | grep -qi 'usage' && ! printf '%s' "$ERR" | grep -q Traceback && [ "$before" = "$after" ]; then
    ok "$label"
  else
    bad "$label (rc=$RC out=[$OUT] err=[$ERR])"
  fi
}
# mksums DIR   write DIR/SHA256SUMS as bin/heimdall-pack-build documents it (one "<sha256>  <path>" line per file but SHA256SUMS, bytewise path order), with shasum,
# and print the pack's content hash, the sha256 of that file
mksums() {
  ( cd "$1" || exit 1
    rm -f SHA256SUMS
    find . -type f -print0 | LC_ALL=C sort -z | xargs -0 shasum -a 256 | sed 's|  \./|  |' > "$T/sums.tmp"
    mv "$T/sums.tmp" SHA256SUMS
    shasum -a 256 < SHA256SUMS | cut -d' ' -f1 )
}
# lockrow HOME ID HASH   record "ID is installed, its pack's content hash is HASH" in HOME/skills.lock with the real lock writer
lockrow() {
  HEIMDALL_HOME="$1" "$REALPY" -B -I "$LOCK_LIB" record --scope machine --id "$2" --state installed --kind bundled --content-hash "$3" --rule fixture --via skills-packs-resolve.test > /dev/null
}
# lockedit FILE PYTHON   edit the machine lock FILE in place (PYTHON sees the stacks row as `e`, the whole lock as `d`); the result is still valid JSON
lockedit() {
  "$REALPY" -I -c 'import json, sys; p = sys.argv[1]; d = json.load(open(p)); e = [r for r in d["entries"] if r["id"] == "stacks"][0]; exec(sys.argv[2]); json.dump(d, open(p, "w"), indent=2)' "$1" "$2"
}
# put ROOT REL [MODE]   write ROOT/REL (parents made) holding its own relative path; MODE defaults to 644
put() { mkdir -p "$(dirname "$1/$2")" && printf 'fixture file %s\n' "$2" > "$1/$2" && chmod "${3:-644}" "$1/$2"; }
# flip FILE   overwrite the first byte of FILE with 0xff (never a valid first byte of a text file): exactly one byte changes
flip() { printf '\377' | dd of="$1" bs=1 seek=0 conv=notrunc 2>/dev/null; }
# newcase NAME   a fresh copy of the pristine fixture under cases/NAME; sets CASE_DIR, P (plugin root, the bundled copies), H (heimdall home: packs/ and skills.lock), LOCK
newcase() {
  CASE_DIR="$T/cases/$1"; mkdir -p "$CASE_DIR"; cp -R "$FX/." "$CASE_DIR/"
  P="$CASE_DIR/plugin"; H="$CASE_DIR/home dir"; LOCK="$H/skills.lock"
}

# ── the pristine fixture: bundled stacks, system-health and heimdall; the installed packs of stacks and system-health; the lock rows pinning those two ──────────────
FX="$T/fx"
STACK_FILES="SKILL.md README.md fastapi/PACK.md nextjs/PACK.md"
for rel in $STACK_FILES; do put "$FX/plugin/skills/stacks" "$rel"; put "$FX/home dir/packs/stacks" "$rel"; done
put "$FX/plugin/skills/system-health" SKILL.md; put "$FX/home dir/packs/system-health" SKILL.md
put "$FX/plugin/skills/heimdall" SKILL.md
for id in stacks system-health; do
  printf 'id: fixture/%s\nversion: 1.0.0\n' "$id" > "$FX/home dir/packs/$id/hmd.skill.yaml"
  lockrow "$FX/home dir" "$id" "$(mksums "$FX/home dir/packs/$id")"
done

# ═ A ═══════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════
echo "-- A. the installed pack wins when it is what the lock pins --"
newcase a
expect "A: stacks resolves to its installed pack" pack stacks
expect "A: system-health resolves to its own installed pack" pack system-health
expect "A: heimdall (no pack, no row) resolves to the bundled copy" bundled heimdall
expect "A: an id nobody pinned (stack, not stacks) is bundled" bundled stack
expect "A: an id no tree ships is its bundled path, not an error" bundled nosuchskill
newcase a-noise
printf 'x\n' > "$H/packs/stacks/.DS_Store"; printf 'x\n' > "$H/packs/stacks/fastapi/.DS_Store"; mkdir "$H/packs/stacks/empty"; chmod 755 "$H/packs/stacks/SKILL.md"
expect "A: .DS_Store files, an empty directory and an exec bit are not part of the pin" pack stacks
newcase a-link
mv "$H" "$CASE_DIR/real-home"; ln -s "$CASE_DIR/real-home" "$H"
expect "A: a HEIMDALL_HOME that is a symlink (the install lives on another volume) still resolves its pack" pack stacks
newcase a-unicode
mv "$H" "$CASE_DIR/$(printf 'h\303\251llo dir')"; H="$CASE_DIR/$(printf 'h\303\251llo dir')"
expect "A: a non-ASCII HEIMDALL_HOME is printed byte for byte" pack stacks

# ═ B ═══════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════
echo "-- B. INV-L5: every defect alone falls back to the bundled copy, silently --"
echo "   the pack side"
newcase b-nopacks;   rm -rf "$H/packs"
expect "B: a HEIMDALL_HOME without a packs directory" bundled stacks
newcase b-nopack;    rm -rf "$H/packs/stacks"
expect "B: no pack for the id (the lock pins one)" bundled stacks
expect "B: ... while another skill's pack is untouched" pack system-health
newcase b-packfile;  rm -rf "$H/packs/stacks"; : > "$H/packs/stacks"
expect "B: a regular file where the pack directory should be" bundled stacks
newcase b-nosums;    rm "$H/packs/stacks/SHA256SUMS"
expect "B: SHA256SUMS missing" bundled stacks
newcase b-sumslink;  cp "$H/packs/stacks/SHA256SUMS" "$H/sums.real"; rm "$H/packs/stacks/SHA256SUMS"; ln -s "$H/sums.real" "$H/packs/stacks/SHA256SUMS"
expect "B: SHA256SUMS a link to the same bytes" bundled stacks
newcase b-edited;    printf 'x' >> "$H/packs/stacks/README.md"
expect "B: a file edited after the build (SHA256SUMS untouched)" bundled stacks
newcase b-byte;      flip "$H/packs/stacks/fastapi/PACK.md"
expect "B: one byte of a pack file changed" bundled stacks
newcase b-empty;     : > "$H/packs/stacks/README.md"
expect "B: a pack file truncated to nothing" bundled stacks
newcase b-missing;   rm "$H/packs/stacks/fastapi/PACK.md"
expect "B: a listed file missing from the pack" bundled stacks
newcase b-dir;       rm "$H/packs/stacks/README.md"; mkdir "$H/packs/stacks/README.md"
expect "B: a directory where a listed file should be" bundled stacks
newcase b-filelink;  mv "$H/packs/stacks/README.md" "$H/readme.real"; ln -s "$H/readme.real" "$H/packs/stacks/README.md"
expect "B: a listed file replaced by a link to the same bytes" bundled stacks
newcase b-dirlink;   mv "$H/packs/stacks/fastapi" "$H/fastapi.real"; ln -s "$H/fastapi.real" "$H/packs/stacks/fastapi"
expect "B: a directory of the pack replaced by a link to the same files" bundled stacks
newcase b-extra;     put "$H/packs/stacks" EXTRA.md
expect "B: a file added that SHA256SUMS does not list" bundled stacks
newcase b-rebuilt;   printf 'x' >> "$H/packs/stacks/README.md"; mksums "$H/packs/stacks" > /dev/null
expect "B: a rebuild after an edit (files and SHA256SUMS agree) is not the pinned build" bundled stacks
newcase b-name;      put "$H/packs/stacks" "my file.md"; lockedit "$LOCK" "e['content_hash'] = '$(mksums "$H/packs/stacks")'"
grep -q '  my file\.md$' "$H/packs/stacks/SHA256SUMS" || bad "B: fixture: SHA256SUMS does not list the file with the space in its name"
expect "B: a name the builder refuses (a space), though files, SHA256SUMS and lock agree" bundled stacks

echo "   the lock side"
newcase b-lock-control; lockedit "$LOCK" 'None'
expect "B: control: the lock rewritten unchanged still resolves the pack (each edit below breaks one thing)" pack stacks
newcase b-nolock;    rm "$LOCK"
expect "B: no lock" bundled stacks
newcase b-garbage;   printf '{not json' > "$LOCK"
expect "B: a lock that is not JSON" bundled stacks
newcase b-schema;    printf '{"schema": 2, "manifest_sha256": null, "entries": []}\n' > "$LOCK"
expect "B: a lock of another schema" bundled stacks
newcase b-locklink;  mv "$LOCK" "$H/lock.real"; ln -s "$H/lock.real" "$LOCK"
expect "B: a lock that is a link" bundled stacks
if [ "$NONROOT" -eq 1 ]; then
  newcase b-lockperm; chmod 000 "$LOCK"
  expect "B: an unreadable lock" bundled stacks
else
  skip "B: unreadable-lock case (running as root: chmod 000 does not stop root)"
fi
newcase b-norow;     lockedit "$LOCK" 'd["entries"].remove(e)'
expect "B: a lock with no row for the id" bundled stacks
expect "B: ... while another skill's row still pins its pack" pack system-health
newcase b-declined;  lockedit "$LOCK" 'e["state"] = "declined"'
expect "B: a row that is declined, not installed" bundled stacks
newcase b-hash;      lockedit "$LOCK" 'e["content_hash"] = ("0" if e["content_hash"][0] != "0" else "1") + e["content_hash"][1:]'
expect "B: the pinned hash differs from the pack's by one digit" bundled stacks
newcase b-null;      lockedit "$LOCK" 'e["content_hash"] = None'
expect "B: a row with no content hash" bundled stacks
newcase b-prefix;    lockedit "$LOCK" 'e["content_hash"] = e["content_hash"][:12]'
expect "B: a row whose hash is only a prefix of the pack's (a short hash is not a pin)" bundled stacks

# ═ C ═══════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════
echo "-- C. a lean tree: the bundled copy may be absent; it is still named, never created --"
newcase c-lean;      rm -rf "$P/skills/stacks" "$H"
expect "C: no bundled copy and no pack: the bundled path is the answer and nothing is created" bundled stacks
newcase c-lean-pack; rm -rf "$P/skills/stacks"
expect "C: no bundled copy but a pinned pack: the pack is the answer and the rest of the tree is untouched" pack stacks

# ═ D ═══════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════
echo "-- D. where the roots come from --"
newcase d-self
SELF="$CASE_DIR/selfroot"; mkdir -p "$SELF/bin/lib" "$SELF/skills/stacks"
cp "$LIB" "$SELF/bin/lib/skills_packs.py"; cp "$LOCK_LIB" "$SELF/bin/lib/skills_lock.py"
LIBRUN="$SELF/bin/lib/skills_packs.py"
answers "D: no CLAUDE_PLUGIN_ROOT: the bundled copy is the one of the tree the resolver lives in" "$SELF/skills/stacks" HEIMDALL_HOME="$CASE_DIR/nohome" -- resolve stacks
answers "D: CLAUDE_PLUGIN_ROOT wins over the tree the resolver lives in" "$P/skills/stacks" CLAUDE_PLUGIN_ROOT="$P" HEIMDALL_HOME="$CASE_DIR/nohome" -- resolve stacks
answers "D: the pack does not depend on the plugin root: no CLAUDE_PLUGIN_ROOT, a pinned pack" "$H/packs/stacks" HEIMDALL_HOME="$H" -- resolve stacks
LIBRUN=""
newcase d-home
mkdir -p "$CASE_DIR/hh/.heimdall"; mv "$H/packs" "$H/skills.lock" "$CASE_DIR/hh/.heimdall/"
answers "D: HEIMDALL_HOME unset: \$HOME/.heimdall holds the packs and the lock" "$CASE_DIR/hh/.heimdall/packs/stacks" CLAUDE_PLUGIN_ROOT="$P" -- resolve stacks
answers "D: HEIMDALL_HOME empty: the same fallback" "$CASE_DIR/hh/.heimdall/packs/stacks" CLAUDE_PLUGIN_ROOT="$P" HEIMDALL_HOME= -- resolve stacks
newcase d-relative
CWD="$CASE_DIR"
answers "D: a relative HEIMDALL_HOME comes back as an absolute pack path" "$H/packs/stacks" CLAUDE_PLUGIN_ROOT=plugin HEIMDALL_HOME="home dir" -- resolve stacks
answers "D: a relative CLAUDE_PLUGIN_ROOT comes back as an absolute bundled path" "$P/skills/heimdall" CLAUDE_PLUGIN_ROOT=plugin HEIMDALL_HOME="home dir" -- resolve heimdall
CWD=""
newcase d-repo
DECOY="$CASE_DIR/project"
mkdir -p "$DECOY/.planning" "$DECOY/.heimdall"
cp -R "$H/packs" "$DECOY/packs"; cp -R "$H/packs" "$DECOY/.heimdall/packs"
cp "$LOCK" "$DECOY/skills.lock"; cp "$LOCK" "$DECOY/.planning/skills.lock"; cp "$LOCK" "$DECOY/.heimdall/skills.lock"
for m in json skills_lock skills_packs; do printf 'import sys\nsys.exit(97)\n' > "$DECOY/$m.py"; done
rm -rf "$H/packs/stacks"
CWD="$DECOY"
answers "D: a repository in the working directory steers nothing: its valid pack and lock row are not read" "$P/skills/stacks" CLAUDE_PLUGIN_ROOT="$P" HEIMDALL_HOME="$H" -- resolve stacks
CWD=""

# ═ E ═══════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════
echo "-- E. the Python API --"
newcase e
api="$(cd "$CASE_DIR" && env -i PATH="$PATH" HOME="$CASE_DIR/hh" "$REALPY" -B -I -S -c '
import sys
sys.path.insert(0, sys.argv[1])
import skills_packs
root, home = sys.argv[2], sys.argv[3]
for skill in ("stacks", "heimdall"):
    got = skills_packs.resolve(skill, plugin_root=root, heimdall_home=home)
    print(got.source, got.path)
try:
    skills_packs.resolve("../x", plugin_root=root, heimdall_home=home)
    print("accepted")
except ValueError:
    print("ValueError")
' "$(dirname "$LIB")" "$P" "$H" 2>&1)"
want_api="$(printf 'pack %s\nbundled %s\nValueError' "$H/packs/stacks" "$P/skills/heimdall")"
if [ "$api" = "$want_api" ]; then ok "E: resolve() returns (path, source) for a pack and a bundled skill, and raises ValueError for a bad id"; else bad "E: the API answered [$api], wanted [$want_api]"; fi

# ═ F ═══════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════
echo "-- F. real data: the real skills/stacks as a pack, and the pack the real builder makes --"
newcase f-real
rm -rf "$H/packs/stacks"; mkdir -p "$H/packs/stacks"; cp -R "$REPO/skills/stacks/." "$H/packs/stacks/"
printf 'id: fixture/stacks\nversion: 1.0.0\n' > "$H/packs/stacks/hmd.skill.yaml"
lockedit "$LOCK" "e['content_hash'] = '$(mksums "$H/packs/stacks")'"
expect "F: the real skills/stacks files, listed and pinned: the pack wins" pack stacks
flip "$H/packs/stacks/$(cd "$REPO/skills/stacks" && git ls-files | grep / | head -1)"
expect "F: ... and one changed byte in one of its files sends it back to the bundled copy" bundled stacks
if [ -x "$BUILDER" ]; then
  newcase f-builder
  rm -rf "$H/packs/stacks"
  built="$("$BUILDER" build --out "$H/packs/stacks" 2>/dev/null)"
  lockedit "$LOCK" "e['content_hash'] = '$built'"
  answers "F: the pack bin/heimdall-pack-build makes, pinned by the hash it prints, is accepted" "$H/packs/stacks" CLAUDE_PLUGIN_ROOT="$P" HEIMDALL_HOME="$H" -- resolve stacks
  flip "$H/packs/stacks/SKILL.md"
  expect "F: ... and one changed byte of the builder's pack is not" bundled stacks
  rm -rf "$H/packs/stacks" "$CASE_DIR/src"; mkdir -p "$CASE_DIR/src"; cp -R "$REPO/skills/stacks/." "$CASE_DIR/src/"; printf 'x' >> "$CASE_DIR/src/README.md"
  "$BUILDER" build --src "$CASE_DIR/src" --out "$H/packs/stacks" > /dev/null 2>&1
  expect "F: a pack built from an edited source (its own files and SHA256SUMS agree) is not the build the lock pins" bundled stacks
else
  skip "F: bin/heimdall-pack-build is not in this tree (T2.2 lands beside this task): the builder interop cases run once it is"
fi

# ═ G ═══════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════
echo "-- G. usage --"
newcase g
usage_error "G: no arguments"
usage_error "G: an id without the command" stacks
usage_error "G: resolve without an id" resolve
usage_error "G: resolve with two ids" resolve stacks system-health
usage_error "G: an unknown command" frob stacks
usage_error "G: an id that climbs out of the tree" resolve ../x
usage_error "G: an id with a slash" resolve a/b
usage_error "G: an empty id" resolve ''
usage_error "G: an id that starts with a dot" resolve .hidden
usage_error "G: an id that looks like an option" resolve -x
usage_error "G: an overlong id" resolve "$(printf 'a%.0s' $(seq 1 70))"
run -- --help
if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -qi 'usage' && [ -z "$ERR" ]; then ok "G: --help prints the usage on stdout and exits 0"; else bad "G: --help (rc=$RC out=[$OUT] err=[$ERR])"; fi

finish
