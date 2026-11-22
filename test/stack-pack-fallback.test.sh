#!/usr/bin/env bash
# stack-pack-fallback.test.sh -- proves bin/stack-pack reads the stack packs through bin/lib/skills_packs.py (3.x lean-core plan T3.1,
# docs/superpowers/plans/2026-11-12-3x-lean-core.md; INV-L5 of .planning/lean-core/INVARIANTS.md: "pack with hash mismatch or missing => bundled copy, silent,
# never an error; a bundled copy is never deleted"). `stack-pack load` prints the base pack of each detected stack from the INSTALLED PACK
# ($HEIMDALL_HOME/packs/stacks, the build bin/heimdall-pack-build makes) when the machine lock ($HEIMDALL_HOME/skills.lock) pins exactly that build, and from the
# BUNDLED <plugin root>/skills/stacks in every other state.
#
#   A. PACK       the pinned pack wins: from a lean plugin root that holds no bundled copy (so the pack is the only source) and from a root that holds one; the four
#                 stacks, a two-stack tree (detect order), repo refinements layered on top (glob order), a tree with no signal.
#   B. BUNDLED    no pack: the bundled copy, the path exactly as before the resolver existed (the full profile is unchanged), whatever HEIMDALL_HOME is.
#   C. INV-L5     each defect alone: the bundled copy, exit 0, nothing on stderr. Pack: a changed byte, SHA256SUMS missing, the pack missing, an unlisted file added.
#                 Lock: missing, no row for the id, a row declined, the hash off by one digit. Resolver: a python3 that fails, one that answers a relative path, one
#                 that fails after printing a path, no resolver file beside stack-pack. A lean root with a defective pack prints nothing: no pack is a valid state.
#   D. COST       python starts only once a stack was detected, and once per load: `detect` (what the SessionStart hook runs) and a tree with no signal never start it.
#   E. READ-ONLY  a load changes nothing under the home or the plugin root.
#   F. PARITY     the T1.3 shadow harness (bin/lib/skills_shadow.py --package-home) over its 8 fixtures: the real pack against the bundled copy is identical for the
#                 four stacks, the monorepo, the refined tree and the two empty ones; a verified pack that differs by one line is FAIL on exactly the fixtures that
#                 resolve it.
#   G. HELP       --help names the installed pack.
#
# Fixtures are built here: the pack by the real bin/heimdall-pack-build (its hash cross-checked with shasum, by the rule the builder documents), the lock row by the
# real lock writer (bin/lib/skills_lock.py), the projects by hand. Every expectation is derived independently of stack-pack (cmp, wc -c, the paths the fixtures are
# built at), never read back from it. HMD_STACK_PACK_BIN points the suite at another copy of stack-pack (a mutated one, to watch an assertion go red; the copy needs
# lib/ and stack-detect beside it). bash 3.2 compatible. About 40 stack-pack runs and two shadow-harness runs.
#
# Usage:  bash test/stack-pack-fallback.test.sh
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SELF_DIR/.." && pwd)"
REPO_P="$(cd "$REPO" && pwd -P)"
SP="${HMD_STACK_PACK_BIN:-$REPO/bin/stack-pack}"
BUILDER="$REPO/bin/heimdall-pack-build"
LOCK_LIB="$REPO/bin/lib/skills_lock.py"
SHADOW="$REPO/bin/lib/skills_shadow.py"
STACKS="$REPO/skills/stacks"
PASS=0; FAIL=0
ok()     { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad()    { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; }
finish() { printf '\nstack-pack-fallback: %s passed, %s failed\n' "$PASS" "$FAIL"; [ "$FAIL" -eq 0 ]; exit $?; }

echo "stack-pack-fallback (the installed pack when the lock pins it, else the bundled copy, silently)"

echo "-- 0. the tools exist --"
MISSING=""
for f in "$SP" "$BUILDER" "$REPO/bin/stack-detect"; do [ -x "$f" ] || MISSING="$MISSING $f"; done
for f in "$LOCK_LIB" "$SHADOW" "$REPO/bin/lib/skills_packs.py" "$STACKS/nextjs/PACK.md"; do [ -f "$f" ] || MISSING="$MISSING $f"; done
if [ -z "$MISSING" ]; then ok "stack-pack, stack-detect, the resolver, the pack builder, the lock writer, the shadow harness and the bundled packs exist"; else bad "missing:$MISSING"; finish; fi

# nothing of the caller's environment may steer a run: every call below builds its own
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR GIT_PREFIX CLAUDE_PLUGIN_ROOT HEIMDALL_HOME HMD_PYTHON
T="$(mktemp -d "${TMPDIR:-/tmp}/stack-pack-fallback-test.XXXXXX")" || exit 2; T="$(cd "$T" && pwd -P)"
cleanup() { chmod -R u+rwX "$T" 2>/dev/null; rm -rf "$T"; }
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
mkdir -p "$T/tmp" "$T/hh" "$T/cases"

PY="$(command -v python3 || true)"
[ -n "$PY" ] || { echo "FATAL: python3 not found"; exit 2; }
# the real interpreter, not a version-manager shim
REALPY="$("$PY" -I -c 'import sys; print(sys.executable)' 2>/dev/null)"
case "$REALPY" in /*) ;; *) REALPY="" ;; esac
[ -n "$REALPY" ] && [ -x "$REALPY" ] || { echo "FATAL: cannot resolve the interpreter behind $PY"; exit 2; }

# ── helpers ────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
# run_sp ROOT HOME PROJECT [VAR=value ...]   `stack-pack load PROJECT` (SPCMD names another command, SPRUN another script) from inside PROJECT, in an environment
# built from nothing: PATH, a private HOME, LC_ALL=C, CLAUDE_PLUGIN_ROOT=ROOT, HEIMDALL_HOME=HOME; the VAR=value pairs come last and win. Sets OUT ERR RC.
run_sp() {
  local root="$1" home="$2" project="$3"; shift 3
  (cd "$project" && env -i PATH="$PATH" HOME="$T/hh" LC_ALL=C CLAUDE_PLUGIN_ROOT="$root" HEIMDALL_HOME="$home" "$@" "${SPRUN:-$SP}" "${SPCMD:-load}" "$project" >"$T/out" 2>"$T/err")
  RC=$?
  OUT="$(cat "$T/out")"; ERR="$(cat "$T/err")"
}
# loads LABEL ROOT HOME PROJECT WANT [VAR=value ...]   the load exits 0, says nothing on stderr and prints exactly WANT (lines, or nothing)
loads() {
  local label="$1" root="$2" home="$3" project="$4" want="$5"; shift 5
  run_sp "$root" "$home" "$project" "$@"
  if [ "$RC" -eq 0 ] && [ -z "$ERR" ] && [ "$OUT" = "$want" ]; then ok "$label"; else bad "$label (rc=$RC err=[$ERR] out=[$OUT]; wanted [$want])"; fi
}
# base_lines DIR ID...   the lines a load prints for those stack ids when the stacks directory is DIR
base_lines() { local dir="$1" id; shift; for id in "$@"; do printf '%s/%s/PACK.md\n' "$dir" "$id"; done; }
# mkproj NAME FILE CONTENT [FILE CONTENT ...]   a project tree under $T/proj/NAME
mkproj() {
  local dir="$T/proj/$1"; shift; mkdir -p "$dir"
  while [ "$#" -ge 2 ]; do mkdir -p "$(dirname "$dir/$1")"; printf '%s\n' "$2" > "$dir/$1"; shift 2; done
}
# lockrow HOME ID HASH   record "ID is installed, its pack's content hash is HASH" in HOME/skills.lock with the real lock writer
lockrow() {
  HEIMDALL_HOME="$1" "$REALPY" -B -I "$LOCK_LIB" record --scope machine --id "$2" --state installed --kind bundled --content-hash "$3" --rule fixture --via stack-pack-fallback.test > /dev/null
}
# lockedit FILE PYTHON   edit the machine lock FILE in place (PYTHON sees the stacks row as `e`, the whole lock as `d`); the result is still valid JSON
lockedit() {
  "$REALPY" -I -c 'import json, sys; p = sys.argv[1]; d = json.load(open(p)); e = [r for r in d["entries"] if r["id"] == "stacks"][0]; exec(sys.argv[2]); json.dump(d, open(p, "w"), indent=2)' "$1" "$2"
}
# flip FILE   overwrite the first byte of FILE with 0xff (never a valid first byte of a text file): exactly one byte changes
flip() { printf '\377' | dd of="$1" bs=1 seek=0 conv=notrunc 2>/dev/null; }
# newhome NAME   a fresh copy of the pristine home under cases/NAME; sets CH
newhome() { CH="$T/cases/$1"; cp -R "$H" "$CH"; }
# mkstub NAME BODY   a directory $T/py-NAME holding a python3 that runs BODY instead of python (put it first on PATH)
mkstub() { mkdir -p "$T/py-$1"; printf '#!/bin/sh\n%s\n' "$2" > "$T/py-$1/python3"; chmod +x "$T/py-$1/python3"; }
# fp DIR   one number for everything under DIR: names, modes, inodes, link targets, sizes and mtimes (find -ls)
fp() { ( cd "$1" && find . -ls | cksum ); }
sizeof() { wc -c < "$1" | tr -d ' '; }
rc_of() { cat "$T/$1.rc" 2>/dev/null; }
out_has() { grep -qF -- "$2" "$T/$1.out" 2>/dev/null; }
show() { printf 'rc=%s out=[%s] err=[%s]' "$(rc_of "$1")" "$(head -c 600 "$T/$1.out" 2>/dev/null)" "$(head -c 600 "$T/$1.err" 2>/dev/null)"; }
# shadow_run NAME HOME   the T1.3 harness over the real stack-pack: this repo's bundled copy against a lean package root plus the installed pack of HOME
shadow_run() {
  (cd "$T" && TMPDIR="$T/tmp" "$REALPY" -B -I "$SHADOW" --bundled "$REPO" --package "$LEAN" --package-home "$2" --stack-pack "$SP" >"$T/$1.out" 2>"$T/$1.err")
  echo $? >"$T/$1.rc"
}

# ── fixtures ───────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
NEXT_JSON='{"name": "t", "dependencies": {"next": "14.2.0", "react": "18.3.0"}}'
FASTAPI_REQ=$'fastapi==0.110.0\nuvicorn==0.29.0'
GRADLE=$'plugins {\n    id \'org.springframework.boot\' version \'3.2.4\'\n    id \'java\'\n}'
mkproj nextjs package.json "$NEXT_JSON"
mkproj react-native package.json '{"name": "t", "dependencies": {"react": "18.2.0", "react-native": "0.74.0"}}'
mkproj fastapi requirements.txt "$FASTAPI_REQ"
mkproj spring-boot build.gradle "$GRADLE"
mkproj monorepo package.json "$NEXT_JSON" requirements.txt "$FASTAPI_REQ"
mkproj refined package.json "$NEXT_JSON" .planning/skills/api.md '# API refinement' .planning/skills/ui.md '# UI refinement'
mkproj nosignal README.md '# no stack signal'
mkproj nextjs-rel package.json "$NEXT_JSON" decoy-rel/nextjs/PACK.md '# decoy, reached only through a relative path'
mkdir -p "$T/decoy-stacks/nextjs"; printf '# decoy, reached only through a resolver that failed\n' > "$T/decoy-stacks/nextjs/PACK.md"

LEAN="$T/lean-root"; mkdir -p "$LEAN"                                          # a lean plugin root: no skills/ at all
B="$T/bundled-root"; mkdir -p "$B/skills"; cp -R "$STACKS" "$B/skills/stacks"  # a full plugin root: the bundled copy
H="$T/home"; mkdir -p "$H/packs"                                               # a heimdall home: the installed pack and the lock row that pins it
BUILT="$("$BUILDER" build --out "$H/packs/stacks" 2>"$T/build.err")"
SUMHASH="$(shasum -a 256 < "$H/packs/stacks/SHA256SUMS" 2>/dev/null | cut -d' ' -f1)"
if [ -n "$BUILT" ] && [ "$BUILT" = "$SUMHASH" ]; then ok "fixture: bin/heimdall-pack-build makes the pack; the hash it prints is the sha256 of the pack's SHA256SUMS (shasum)"; else bad "fixture: builder printed [$BUILT], shasum of SHA256SUMS is [$SUMHASH] ($(cat "$T/build.err"))"; finish; fi
lockrow "$H" stacks "$BUILT" || { bad "fixture: the lock writer failed"; finish; }
SAME=1
for s in nextjs react-native fastapi spring-boot; do cmp -s "$H/packs/stacks/$s/PACK.md" "$STACKS/$s/PACK.md" || SAME=0; done
if [ "$SAME" = 1 ]; then ok "fixture: the pack's four PACK.md files are the bundled ones, byte for byte (cmp)"; else bad "fixture: the built pack differs from skills/stacks"; fi
# a second home whose pack differs from the bundled one by one line, built from a doctored source and pinned by its own hash: a VERIFIED pack with other text
cp -R "$STACKS" "$T/src-doctored"; printf '\n<!-- doctored -->\n' >> "$T/src-doctored/nextjs/PACK.md"
HD="$T/home-doctored"; mkdir -p "$HD/packs"
BUILT_D="$("$BUILDER" build --src "$T/src-doctored" --out "$HD/packs/stacks" 2>/dev/null)"
lockrow "$HD" stacks "$BUILT_D" || { bad "fixture: the lock writer failed for the doctored home"; finish; }
# the resolvers that misbehave, each a python3 for the front of PATH; a copy of stack-pack with no lib/ beside it
mkstub fail 'echo "python3: boom" >&2; exit 3'
mkstub rel 'echo decoy-rel'
mkstub abs "echo '$T/decoy-stacks'; exit 1"
mkstub log "echo called >> '$T/py-calls'; exec '$REALPY' \"\$@\""
mkdir -p "$T/nolib/bin"; cp "$SP" "$T/nolib/bin/stack-pack"; chmod +x "$T/nolib/bin/stack-pack"; ln -s "$REPO/bin/stack-detect" "$T/nolib/bin/stack-detect"

# ═ A ═══════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════
echo "-- A. the pinned pack wins (a lean root holds no bundled copy: the pack is the only source) --"
for s in nextjs react-native fastapi spring-boot; do
  loads "A: $s: the base pack is the installed pack's" "$LEAN" "$H" "$T/proj/$s" "$H/packs/stacks/$s/PACK.md"
done
loads "A: a two-stack tree: both base packs from the installed pack, in detect order" "$LEAN" "$H" "$T/proj/monorepo" "$(base_lines "$H/packs/stacks" nextjs fastapi)"
loads "A: repo refinements layer on top of the installed base pack, in glob order" "$LEAN" "$H" "$T/proj/refined" \
  "$(base_lines "$H/packs/stacks" nextjs; printf '%s\n' "$T/proj/refined/.planning/skills/api.md" "$T/proj/refined/.planning/skills/ui.md")"
loads "A: a tree with no stack signal prints nothing" "$LEAN" "$H" "$T/proj/nosignal" ""
loads "A: with a bundled copy beside it, the pinned pack still wins" "$B" "$H" "$T/proj/nextjs" "$H/packs/stacks/nextjs/PACK.md"

# ═ B ═══════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════
echo "-- B. no pack: the bundled copy, the path exactly as before --"
for s in nextjs react-native fastapi spring-boot; do
  loads "B: $s: the base pack is the bundled one" "$B" "$T/nohome" "$T/proj/$s" "$B/skills/stacks/$s/PACK.md"
done
loads "B: a two-stack tree: both bundled base packs, in detect order" "$B" "$T/nohome" "$T/proj/monorepo" "$(base_lines "$B/skills/stacks" nextjs fastapi)"
loads "B: repo refinements layer on top of the bundled base pack, in glob order" "$B" "$T/nohome" "$T/proj/refined" \
  "$(base_lines "$B/skills/stacks" nextjs; printf '%s\n' "$T/proj/refined/.planning/skills/api.md" "$T/proj/refined/.planning/skills/ui.md")"
loads "B: HEIMDALL_HOME empty (so ~/.heimdall of the private HOME, which holds nothing): the bundled copy" "$B" "" "$T/proj/nextjs" "$B/skills/stacks/nextjs/PACK.md"
if [ "$SP" = "$REPO/bin/stack-pack" ]; then
  loads "B: no CLAUDE_PLUGIN_ROOT: the bundled copy is the one of the tree stack-pack lives in" "" "$T/nohome" "$T/proj/nextjs" "$REPO_P/skills/stacks/nextjs/PACK.md"
fi

# ═ C ═══════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════
echo "-- C. INV-L5: every defect alone falls back to the bundled copy, silently --"
WANT="$B/skills/stacks/nextjs/PACK.md"
echo "   the pack side"
newhome c-control; lockedit "$CH/skills.lock" 'None'
loads "C: control: the lock rewritten unchanged still resolves the pack (each edit below breaks one thing)" "$B" "$CH" "$T/proj/nextjs" "$CH/packs/stacks/nextjs/PACK.md"
newhome c-byte;   flip "$CH/packs/stacks/nextjs/PACK.md"
loads "C: one byte of the nextjs pack changed" "$B" "$CH" "$T/proj/nextjs" "$WANT"
newhome c-nosums; rm "$CH/packs/stacks/SHA256SUMS"
loads "C: SHA256SUMS missing" "$B" "$CH" "$T/proj/nextjs" "$WANT"
newhome c-nopack; rm -rf "$CH/packs/stacks"
loads "C: no pack for the id, though the lock pins one" "$B" "$CH" "$T/proj/nextjs" "$WANT"
newhome c-extra;  printf 'x\n' > "$CH/packs/stacks/EXTRA.md"
loads "C: a file added that SHA256SUMS does not list" "$B" "$CH" "$T/proj/nextjs" "$WANT"
echo "   the lock side"
newhome c-nolock; rm "$CH/skills.lock"
loads "C: no lock" "$B" "$CH" "$T/proj/nextjs" "$WANT"
newhome c-norow;  lockedit "$CH/skills.lock" 'd["entries"].remove(e)'
loads "C: a lock with no row for the id" "$B" "$CH" "$T/proj/nextjs" "$WANT"
newhome c-declined; lockedit "$CH/skills.lock" 'e["state"] = "declined"'
loads "C: a row that is declined, not installed" "$B" "$CH" "$T/proj/nextjs" "$WANT"
newhome c-hash;   lockedit "$CH/skills.lock" 'e["content_hash"] = ("0" if e["content_hash"][0] != "0" else "1") + e["content_hash"][1:]'
loads "C: the pinned hash differs from the pack's by one digit" "$B" "$CH" "$T/proj/nextjs" "$WANT"
echo "   a lean root: no bundled copy to fall back on"
newhome c-lean;   flip "$CH/packs/stacks/nextjs/PACK.md"
loads "C: a lean root with a changed pack: no base pack, exit 0, nothing on stderr (no pack is a valid state, never an error)" "$LEAN" "$CH" "$T/proj/nextjs" ""
echo "   the resolver side"
loads "C: a python3 that fails (exit 3, a message on stderr) while a valid pack is pinned" "$B" "$H" "$T/proj/nextjs" "$WANT" PATH="$T/py-fail:$PATH"
loads "C: a python3 that answers a relative path (never used: it would be read from the project)" "$B" "$H" "$T/proj/nextjs-rel" "$B/skills/stacks/nextjs/PACK.md" PATH="$T/py-rel:$PATH"
loads "C: a python3 that prints an absolute path and then fails (the path is not used)" "$B" "$H" "$T/proj/nextjs" "$WANT" PATH="$T/py-abs:$PATH"
SPRUN="$T/nolib/bin/stack-pack" loads "C: no resolver file beside stack-pack (no lib/)" "$B" "$H" "$T/proj/nextjs" "$WANT"

# ═ D ═══════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════
echo "-- D. python starts only once a stack was detected, and once per load --"
rm -f "$T/py-calls"
SPCMD=detect run_sp "$B" "$H" "$T/proj/nextjs" PATH="$T/py-log:$PATH"
if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -q '"nextjs"' && [ ! -e "$T/py-calls" ]; then ok "D: detect (what the SessionStart hook runs) starts no python"; else bad "D: detect: rc=$RC out=[$OUT] python calls=[$(cat "$T/py-calls" 2>/dev/null)]"; fi
run_sp "$B" "$H" "$T/proj/nosignal" PATH="$T/py-log:$PATH"
if [ "$RC" -eq 0 ] && [ -z "$OUT" ] && [ ! -e "$T/py-calls" ]; then ok "D: a load of a tree with no stack signal starts no python"; else bad "D: no signal: rc=$RC out=[$OUT] python calls=[$(cat "$T/py-calls" 2>/dev/null)]"; fi
rm -f "$T/py-calls"
run_sp "$B" "$H" "$T/proj/monorepo" PATH="$T/py-log:$PATH"
CALLS="$(wc -l < "$T/py-calls" 2>/dev/null | tr -d ' ')"
if [ "$RC" -eq 0 ] && [ "${CALLS:-0}" = 1 ] && [ "$OUT" = "$(base_lines "$H/packs/stacks" nextjs fastapi)" ]; then ok "D: a load of a two-stack tree starts python once, not once per stack (the logging stub is the python that ran)"; else bad "D: two stacks: rc=$RC calls=[${CALLS:-none}] out=[$OUT]"; fi

# ═ E ═══════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════
echo "-- E. read-only --"
BEFORE="$(fp "$H")|$(fp "$B")"
run_sp "$B" "$H" "$T/proj/refined"
AFTER="$(fp "$H")|$(fp "$B")"
if [ "$RC" -eq 0 ] && [ "$(printf '%s\n' "$OUT" | head -1)" = "$H/packs/stacks/nextjs/PACK.md" ] && [ "$BEFORE" = "$AFTER" ]; then ok "E: a load that reads the installed pack changes nothing under the home or the plugin root"; else bad "E: rc=$RC out=[$OUT] before=$BEFORE after=$AFTER"; fi

# ═ F ═══════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════
echo "-- F. parity with the shadow harness: the installed pack against the bundled copy, over the 8 fixtures --"
N_PACKS="$(ls "$STACKS"/*/PACK.md | wc -l | tr -d ' ')"
shadow_run f1 "$H"
if [ "$(rc_of f1)" = 0 ] && [ ! -s "$T/f1.err" ]; then ok "F: the harness exits 0 with nothing on stderr (the package root is lean: every pack it read came from the installed pack)"; else bad "F: real pack: $(show f1)"; fi
PARITY=1
for s in nextjs react-native fastapi spring-boot; do
  out_has f1 "  PASS $s: identical ('$s/PACK.md'; $(sizeof "$STACKS/$s/PACK.md") bytes)" || PARITY=0
done
if [ "$PARITY" = 1 ]; then ok "F: the four stacks are identical, each at the bundled pack's own size (wc -c): nextjs, react-native, fastapi, spring-boot"; else bad "F: the four stacks: $(show f1)"; fi
if out_has f1 "  PASS monorepo: identical" && out_has f1 "  PASS refined: identical" && out_has f1 "  PASS go-no-pack: identical (no pack resolved)" && out_has f1 "  PASS no-signal: identical (no pack resolved)"; then ok "F: the monorepo, the refined tree and the two empty trees are identical too"; else bad "F: the other fixtures: $(show f1)"; fi
if out_has f1 "skills-shadow: 8 fixtures, 8 identical, 0 different; all $N_PACKS shipped packs exercised"; then ok "F: the summary: 8 fixtures, 8 identical, all $N_PACKS shipped packs exercised"; else bad "F: summary: $(show f1)"; fi
shadow_run f2 "$HD"
if [ "$(rc_of f2)" = 1 ] && out_has f2 "  FAIL nextjs: " && out_has f2 "  FAIL monorepo: " && out_has f2 "  FAIL refined: " \
   && out_has f2 "  PASS react-native: " && out_has f2 "  PASS fastapi: " && out_has f2 "  PASS spring-boot: " && out_has f2 "  PASS go-no-pack: " && out_has f2 "  PASS no-signal: "; then
  ok "F: a verified pack with one extra line is FAIL on exactly the fixtures that resolve nextjs (nextjs, monorepo, refined), PASS on the other five: the harness reads the pack's text"
else bad "F: doctored pack: $(show f2)"; fi
if out_has f2 "file 1 'nextjs/PACK.md': $(sizeof "$STACKS/nextjs/PACK.md") vs $(sizeof "$T/src-doctored/nextjs/PACK.md") bytes"; then ok "F: the report names the pack and both sizes (the bundled one and the doctored one)"; else bad "F: report: $(show f2)"; fi

# ═ G ═══════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════
echo "-- G. help --"
HELP="$("$SP" --help 2>&1)"
if printf '%s' "$HELP" | grep -q 'packs/stacks' && printf '%s' "$HELP" | grep -q 'skills.lock'; then ok "G: --help names the installed pack and the lock that pins it"; else bad "G: --help does not describe the installed pack: [$HELP]"; fi

finish
