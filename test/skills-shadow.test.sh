#!/usr/bin/env bash
# skills-shadow.test.sh -- proves bin/lib/skills_shadow.py (3.x lean-core plan T1.3, docs/superpowers/plans/2026-11-12-3x-lean-core.md; spec section 5 Stage 2:
# "shadow mode: run both package and bundled versions on the same tasks, compare outcomes, promote only if identical"): the harness that resolves the stack packs from
# TWO roots over the same stack-detect fixtures, through the real bin/stack-pack, and diffs the pack text the agents would read.
#
#   A. IDENTICAL   the bundled tree against an exact copy of its skills/stacks: exit 0, every fixture PASS, the bytes it reports are the files' own size (wc -c), the layering
#                  order (base packs in detect order, then .planning/skills refinements) is the resolver's, every shipped pack is exercised, the roots are only read, and the
#                  caller's CLAUDE_PLUGIN_ROOT / HEIMDALL_HOME (decoys, set for the whole suite) steer nothing. A custom resolver over two tiny roots is honoured too.
#   B. THE MUTANT  the plan's: ONE byte changed in the package copy turns exactly the fixtures that resolve that pack RED and names the pack, the first differing byte (checked
#                  against cmp) and a diff; a byte that is not UTF-8 in two more packs, a pack removed and a pack added (section C, the same run) turn each stack's own fixture RED
#                  (every stack is live), without a crash.
#   C. PRESENCE    a pack missing from the package, and a pack only the package has (a stack the bundled tree does not ship), are differences.
#   D. OUTCOME     a package-side resolver that reorders its answer, exits non-zero or writes to stderr differs (INV-L5: the fallback is silent); its HEIMDALL_HOME is a fresh
#                  empty one, never the caller's.
#   E. NO VERDICT  exit 2 with nothing on stdout, never a pass: a shipped pack no fixture resolves, a resolver that resolves nothing, a bundled root with no pack, a bundled
#                  side that fails, a resolved path that is not a file / is outside its root / leaves it by a symlink / is over the size cap, a resolver that hangs.
#   F. USAGE       bad arguments, the same directory for both roots, a resolver that is not executable, --help.
#
# Every expectation is derived independently of the harness (wc -c, cmp, the copied files), never read back from it. HMD_SHADOW_BIN points the suite at another copy of the
# harness (a mutated copy, to watch an assertion go red). bash 3.2 compatible. Cost is process spawns, not Python: four runs
# drive the real bin/stack-pack (8 fixtures x 2 sides, in parallel, about 40 processes a call), the other twenty use stub resolvers.
#
# Usage:  bash test/skills-shadow.test.sh
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SELF_DIR/.." && pwd)"
SHADOW="${HMD_SHADOW_BIN:-$REPO/bin/lib/skills_shadow.py}"
SP="$REPO/bin/stack-pack"
STACKS="$REPO/skills/stacks"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; }
finish() { printf '\nskills-shadow: %s passed, %s failed\n' "$PASS" "$FAIL"; [ "$FAIL" -eq 0 ]; exit $?; }

echo "skills-shadow (the stack packs resolved from two roots over the same fixtures, the pack text diffed)"

echo "-- 0. the harness exists --"
if [ -f "$SHADOW" ]; then ok "bin/lib/skills_shadow.py exists"; else bad "bin/lib/skills_shadow.py is missing (T1.3 creates it)"; finish; fi
if [ -x "$SP" ] && [ -d "$STACKS" ]; then ok "bin/stack-pack and skills/stacks exist (the real resolver and the bundled packs)"; else bad "bin/stack-pack or skills/stacks is missing"; finish; fi

# nothing of the caller's environment may steer a run: a decoy plugin root and a decoy heimdall home are set for every run below
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR GIT_PREFIX

T="$(mktemp -d "${TMPDIR:-/tmp}/skills-shadow-test.XXXXXX")" || exit 2; T="$(cd "$T" && pwd -P)"
cleanup() { chmod -R u+rwX "$T" 2>/dev/null; rm -rf "$T"; }
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
mkdir -p "$T/tmp" "$T/decoy-home"
: > "$T/decoy-home/skills.lock"
export CLAUDE_PLUGIN_ROOT="$T/decoy-root"
export HEIMDALL_HOME="$T/decoy-home"

PY="$(command -v python3 || true)"
[ -n "$PY" ] || { echo "FATAL: python3 not found"; exit 2; }
# the real interpreter, not a version-manager shim (0.3 s a call, and this suite starts about 30 of them)
REALPY="$("$PY" -I -c 'import sys; print(sys.executable)' 2>/dev/null)"
case "$REALPY" in /*) ;; *) REALPY="" ;; esac
[ -n "$REALPY" ] && [ -x "$REALPY" ] || { echo "FATAL: cannot resolve the interpreter behind $PY"; exit 2; }

# ── helpers: every run writes $T/<name>.{out,err,rc}; TMPDIR is private, so what a run leaves behind can be counted ────────────────────────
# run_default: the harness's own defaults. run: the real resolver named explicitly, because a mutated copy of the harness lives elsewhere.
run_default() { local n="$1"; shift; TMPDIR="$T/tmp" "$REALPY" -B -I "$SHADOW" "$@" >"$T/$n.out" 2>"$T/$n.err"; echo $? >"$T/$n.rc"; }
run() { local n="$1"; shift; TMPDIR="$T/tmp" "$REALPY" -B -I "$SHADOW" --stack-pack "$SP" "$@" >"$T/$n.out" 2>"$T/$n.err"; echo $? >"$T/$n.rc"; }
rc() { cat "$T/$1.rc" 2>/dev/null; }
out_has() { grep -qF -- "$2" "$T/$1.out" 2>/dev/null; }            # stdout of run $1 contains the fixed string $2
err_has() { grep -qF -- "$2" "$T/$1.err" 2>/dev/null; }            # stderr of run $1 contains the fixed string $2
show() { printf 'rc=%s out=[%s] err=[%s]' "$(rc "$1")" "$(head -c 500 "$T/$1.out" 2>/dev/null)" "$(head -c 500 "$T/$1.err" 2>/dev/null)"; }
no_stdout() { [ -f "$T/$1.out" ] && [ ! -s "$T/$1.out" ]; }
no_stderr() { [ -f "$T/$1.err" ] && [ ! -s "$T/$1.err" ]; }
sizeof() { wc -c < "$1" | tr -d ' '; }
tree_hash() { (cd "$1" && find . -type f | LC_ALL=C sort | xargs shasum | shasum | cut -d' ' -f1); }
# pkg NAME: a package root that is an exact copy of the bundled stacks (prints its path); tiny NAME: a root with one pack, "a"
pkg() { mkdir -p "$T/$1/skills" && cp -R "$STACKS" "$T/$1/skills/stacks" && printf '%s' "$T/$1"; }
tiny() { mkdir -p "$T/$1/skills/stacks/a" && printf '# pack a\n' > "$T/$1/skills/stacks/a/PACK.md"; }
# flip FILE OFFSET PRINTF-FORMAT: overwrite exactly one byte (the format is 'e' or '\377')
# shellcheck disable=SC2059
flip() { printf "$3" | dd of="$1" bs=1 seek="$2" conv=notrunc 2>/dev/null; }
one_byte() { [ "$(cmp -l "$1" "$2" | wc -l | tr -d ' ')" = 1 ] && [ "$(sizeof "$1")" = "$(sizeof "$2")" ]; }   # the two files differ in exactly one byte
pass_line() { grep -q "^  PASS $2: " "$T/$1.out"; }
fail_line() { grep -q "^  FAIL $2: " "$T/$1.out"; }
# split_ok RUN "FIXTURES": every fixture in the list has a FAIL line in run RUN, every other fixture a PASS line
split_ok() {
  local f
  for f in $FIXTURES; do
    case " $2 " in
      *" $f "*) fail_line "$1" "$f" || return 1 ;;
      *) pass_line "$1" "$f" || return 1 ;;
    esac
  done
}
FIXTURES="nextjs react-native fastapi spring-boot monorepo refined go-no-pack no-signal"
N_FIXTURES=8
N_PACKS="$(ls "$STACKS"/*/PACK.md | wc -l | tr -d ' ')"
NEXT_SIZE="$(sizeof "$STACKS/nextjs/PACK.md")"
FAST_SIZE="$(sizeof "$STACKS/fastapi/PACK.md")"
SPRING_SIZE="$(sizeof "$STACKS/spring-boot/PACK.md")"

# the stub resolvers: scripts the harness runs as `FILE load PROJECT`, each misbehaving in one named way
{ printf '#!/usr/bin/env bash\nREAL=%q\n' "$SP"; cat <<'EOF'
# the real stack-pack, except in a root that holds a DEGRADED file: there it answers the two-stack tree and the refined tree with their files in reverse
# order (the bundled answer, turned around), nothing for the others, says it fell back on stderr and exits 3
if [ -f "$CLAUDE_PLUGIN_ROOT/DEGRADED" ]; then
  case "$(basename "$2")" in
    monorepo) printf '%s\n' "$CLAUDE_PLUGIN_ROOT/skills/stacks/fastapi/PACK.md" "$CLAUDE_PLUGIN_ROOT/skills/stacks/nextjs/PACK.md" ;;
    refined) printf '%s\n' "$2/.planning/skills/ui.md" "$2/.planning/skills/api.md" "$CLAUDE_PLUGIN_ROOT/skills/stacks/nextjs/PACK.md" ;;
  esac
  echo "fell back [home=$HEIMDALL_HOME]" >&2
  exit 3
fi
exec "$REAL" "$@"
EOF
} > "$T/stub-sp"
printf '#!/bin/sh\nexit 0\n' > "$T/stub-none"
printf '#!/bin/sh\necho "no" >&2\nexit 3\n' > "$T/stub-fail"
printf '#!/bin/sh\nexec sleep 30\n' > "$T/stub-hang"
printf '#!/bin/sh\nprintf "%%s\\n" "$CLAUDE_PLUGIN_ROOT/skills/stacks/a/PACK.md"\n' > "$T/stub-a"
printf '#!/bin/sh\nprintf "%%s\\n" "$CLAUDE_PLUGIN_ROOT/skills/stacks/ghost/PACK.md"\n' > "$T/stub-ghost"
printf 'outside the roots\n' > "$T/outside.md"
printf '#!/bin/sh\nprintf "%%s\\n" %q\n' "$T/outside.md" > "$T/stub-outside"
printf 'not executable\n' > "$T/not-exec"
chmod +x "$T/stub-sp" "$T/stub-none" "$T/stub-fail" "$T/stub-hang" "$T/stub-a" "$T/stub-ghost" "$T/stub-outside"

echo "-- A. identical roots --"
P0="$(pkg identical)"
BEFORE="$(tree_hash "$STACKS")|$(tree_hash "$P0/skills/stacks")"
if [ -z "${HMD_SHADOW_BIN:-}" ]; then run_default a --bundled "$REPO" --package "$P0"; else run a --bundled "$REPO" --package "$P0"; fi
if [ "$(rc a)" = 0 ] && no_stderr a; then ok "the bundled tree against an exact copy of its stacks: exit 0, nothing on stderr (with decoy CLAUDE_PLUGIN_ROOT and HEIMDALL_HOME set)"; else bad "identical roots: $(show a)"; fi
if split_ok a ""; then ok "all $N_FIXTURES fixtures PASS: $FIXTURES"; else bad "a fixture is not PASS: $(show a)"; fi
if out_has a "PASS nextjs: identical ('nextjs/PACK.md'; $NEXT_SIZE bytes)" && out_has a "PASS spring-boot: identical ('spring-boot/PACK.md'; $SPRING_SIZE bytes)"; then ok "the bytes reported are the packs' own size (wc -c): nextjs $NEXT_SIZE, spring-boot $SPRING_SIZE"; else bad "reported sizes: $(show a)"; fi
if out_has a "PASS monorepo: identical ('nextjs/PACK.md', 'fastapi/PACK.md'; $((NEXT_SIZE + FAST_SIZE)) bytes)"; then ok "a two-stack tree resolves the base packs in detect order (nextjs, then fastapi)"; else bad "monorepo order or size: $(show a)"; fi
if out_has a "PASS refined: identical ('nextjs/PACK.md', 'skills/api.md', 'skills/ui.md'; "; then ok "repo refinements layer on top of the base pack, in glob order"; else bad "refined layering: $(show a)"; fi
if out_has a "PASS go-no-pack: identical (no pack resolved)" && out_has a "PASS no-signal: identical (no pack resolved)"; then ok "a detected stack with no pack, and a tree with no signal, resolve nothing on both sides"; else bad "empty fixtures: $(show a)"; fi
if out_has a "skills-shadow: $N_FIXTURES fixtures, $N_FIXTURES identical, 0 different; all $N_PACKS shipped packs exercised"; then ok "the summary counts $N_FIXTURES fixtures and all $N_PACKS shipped packs exercised"; else bad "summary: $(show a)"; fi
AFTER="$(tree_hash "$STACKS")|$(tree_hash "$P0/skills/stacks")"
if [ "$BEFORE" = "$AFTER" ]; then ok "both roots are only read: their trees hash the same after the run"; else bad "a root changed during the run"; fi

tiny t-a; tiny t-b
run a2 --stack-pack "$T/stub-a" --bundled "$T/t-a" --package "$T/t-b"
if [ "$(rc a2)" = 0 ] && split_ok a2 "" && out_has a2 "all 1 shipped packs exercised"; then ok "a custom resolver over two tiny roots is honoured: identical, exit 0 (the roots need not be this repo)"; else bad "custom resolver: $(show a2)"; fi

echo "-- B. the mutant: one byte --"
P1="$(pkg mut-one)"; NEXT="$P1/skills/stacks/nextjs/PACK.md"
ORIG="$(dd if="$NEXT" bs=1 skip=100 count=1 2>/dev/null)"
if [ "$ORIG" = "e" ]; then NEWB=f; else NEWB=e; fi
flip "$NEXT" 100 "$NEWB"
OFF1="$(cmp -l "$STACKS/nextjs/PACK.md" "$NEXT" | awk 'NR==1 {print $1}')"
if one_byte "$STACKS/nextjs/PACK.md" "$NEXT" && [ "${OFF1:-0}" = 101 ]; then ok "the mutant is exactly one byte of the nextjs pack (cmp: byte 101 counting from 1, same size)"; else bad "the mutation helper did not change exactly one byte (cmp offset '${OFF1:-none}')"; fi
run b --bundled "$REPO" --package "$P1"
if [ "$(rc b)" = 1 ]; then ok "one byte changed in the package copy: exit 1"; else bad "one-byte mutant: $(show b)"; fi
if split_ok b "nextjs monorepo refined"; then ok "exactly the fixtures that resolve the nextjs pack go FAIL (nextjs, monorepo, refined); the other five stay PASS"; else bad "which fixtures failed: $(show b)"; fi
if out_has b "file 1 'nextjs/PACK.md': $NEXT_SIZE vs $NEXT_SIZE bytes, first difference at byte $((${OFF1:-0} - 1)) (0x"; then ok "the report names the pack, both sizes and the first differing byte (cmp's offset minus one, counting from 0)"; else bad "report of the byte: $(show b)"; fi
if grep -qE '^ +--- bundled$' "$T/b.out" && grep -qE '^ +\+\+\+ package$' "$T/b.out" && [ "$(grep -E '^ +[-+]' "$T/b.out" | grep -vcE '^ +(--- bundled|\+\+\+ package)$')" -ge 2 ]; then ok "the report carries a unified diff of the changed line (the two headers and a - and a + line)"; else bad "no diff in the report: $(show b)"; fi

P2="$(pkg mut-presence)"
flip "$P2/skills/stacks/react-native/PACK.md" 50 '\377'
flip "$P2/skills/stacks/spring-boot/PACK.md" 333 '\377'
rm "$P2/skills/stacks/fastapi/PACK.md"; mkdir "$P2/skills/stacks/go"; printf '# Go stack pack\n' > "$P2/skills/stacks/go/PACK.md"
if one_byte "$STACKS/react-native/PACK.md" "$P2/skills/stacks/react-native/PACK.md" && one_byte "$STACKS/spring-boot/PACK.md" "$P2/skills/stacks/spring-boot/PACK.md"; then ok "the second mutant: one byte (0xff, not UTF-8) in each of react-native and spring-boot, the fastapi pack removed, a go pack added"; else bad "the second mutation helper did not change exactly one byte per pack"; fi
run b2 --bundled "$REPO" --package "$P2"
if [ "$(rc b2)" = 1 ] && no_stderr b2 && ! grep -q Traceback "$T/b2.out"; then ok "bytes that are not UTF-8 are compared and shown without a crash: exit 1, nothing on stderr"; else bad "second mutant: $(show b2)"; fi
if split_ok b2 "react-native spring-boot fastapi monorepo go-no-pack"; then ok "every stack's own fixture goes FAIL (react-native, spring-boot by a byte; fastapi and the monorepo that holds it by a missing pack; go-no-pack by an extra pack); nextjs, refined and no-signal stay PASS"; else bad "which fixtures failed: $(show b2)"; fi
if [ "$(grep -c 'vs 0xff)' "$T/b2.out")" -ge 2 ]; then ok "each byte report gives the byte pair (the bundled byte vs 0xff)"; else bad "byte pairs: $(show b2)"; fi

echo "-- C. presence (the same run) --"
if out_has b2 "file 1: only in bundled: 'fastapi/PACK.md'" && out_has b2 "file 2: only in bundled: 'fastapi/PACK.md'"; then ok "a pack missing from the package is reported as only in bundled, at position 1 (fastapi) and 2 (monorepo)"; else bad "missing pack report: $(show b2)"; fi
if out_has b2 "file 1: only in package: 'go/PACK.md'"; then ok "a pack only the package has (a stack the bundled tree does not ship) is reported as only in package"; else bad "extra pack report: $(show b2)"; fi

echo "-- D. outcome --"
P5="$(pkg degraded)"; : > "$P5/DEGRADED"
run d --stack-pack "$T/stub-sp" --bundled "$REPO" --package "$P5"
if [ "$(rc d)" = 1 ] && split_ok d "$FIXTURES"; then ok "a package-side resolver that reverses its answer, writes to stderr and exits 3: exit 1, every fixture FAILs"; else bad "degraded resolver: $(show d)"; fi
if out_has d "file 1: bundled resolves 'nextjs/PACK.md', package resolves 'fastapi/PACK.md'" && out_has d "package resolves 'skills/ui.md'"; then ok "order is part of the answer: the monorepo and the refined tree name the files that swapped places"; else bad "order report: $(show d)"; fi
if out_has d "exit status: bundled 0, package 3" && out_has d "stderr: bundled '', package 'fell back [home="; then ok "the exit status and the stderr are compared (INV-L5: a fallback is silent)"; else bad "status or stderr report: $(show d)"; fi
if out_has d "home=" && out_has d "skills-shadow." && ! out_has d "decoy-home"; then ok "the resolver's HEIMDALL_HOME is the harness's own empty directory, not the caller's"; else bad "HEIMDALL_HOME leaked or is not private: $(show d)"; fi

echo "-- E. no verdict --"
tiny t-ar; mkdir "$T/t-ar/skills/stacks/ruby"; printf '# Ruby stack pack\n' > "$T/t-ar/skills/stacks/ruby/PACK.md"
run e1 --stack-pack "$T/stub-a" --bundled "$T/t-ar" --package "$T/t-b"
if [ "$(rc e1)" = 2 ] && no_stdout e1 && err_has e1 "no fixture resolves the bundled pack(s) ruby:"; then ok "a shipped pack no fixture resolves (ruby, while pack a is reached): exit 2 with nothing on stdout, and only ruby is named"; else bad "uncovered pack: $(show e1)"; fi
run e2 --stack-pack "$T/stub-none" --bundled "$REPO" --package "$P0"
NAMED=1
for p in "$STACKS"/*/PACK.md; do id="$(basename "$(dirname "$p")")"; err_has e2 "$id" || NAMED=0; done
if [ "$(rc e2)" = 2 ] && no_stdout e2 && [ "$NAMED" = 1 ]; then ok "a resolver that resolves nothing is not 'identical': exit 2, every shipped pack named as unchecked"; else bad "vacuous run: $(show e2)"; fi
mkdir -p "$T/nopacks/skills/stacks"
run e3 --bundled "$T/nopacks" --package "$P0"
if [ "$(rc e3)" = 2 ] && no_stdout e3 && err_has e3 "ships no pack"; then ok "a bundled root with no pack: exit 2, nothing to shadow"; else bad "no packs: $(show e3)"; fi
run e4 --stack-pack "$T/stub-ghost" --bundled "$T/t-a" --package "$T/t-b"
if [ "$(rc e4)" = 2 ] && no_stdout e4 && err_has e4 "not a regular file"; then ok "a resolved path that does not exist: exit 2 (not a regular file)"; else bad "ghost path: $(show e4)"; fi
run e5 --stack-pack "$T/stub-outside" --bundled "$T/t-a" --package "$T/t-b"
if [ "$(rc e5)" = 2 ] && no_stdout e5 && err_has e5 "outside its root"; then ok "a resolved path outside its root and the project: exit 2"; else bad "outside path: $(show e5)"; fi
tiny t-link; rm "$T/t-link/skills/stacks/a/PACK.md"; ln -s "$T/outside.md" "$T/t-link/skills/stacks/a/PACK.md"
run e6 --stack-pack "$T/stub-a" --bundled "$T/t-a" --package "$T/t-link"
if [ "$(rc e6)" = 2 ] && no_stdout e6 && err_has e6 "outside its root"; then ok "a pack that is a symlink out of its root: exit 2 (the file behind it is never read)"; else bad "symlink escape: $(show e6)"; fi
tiny t-big; head -c 5000000 /dev/zero | tr '\0' x > "$T/t-big/skills/stacks/a/PACK.md"
run e7 --stack-pack "$T/stub-a" --bundled "$T/t-a" --package "$T/t-big"
if [ "$(rc e7)" = 2 ] && no_stdout e7 && err_has e7 "too big"; then ok "a 5 MB pack is over the size cap: exit 2"; else bad "oversized pack: $(show e7)"; fi
run e8 --stack-pack "$T/stub-hang" --timeout 0.5 --bundled "$T/t-a" --package "$T/t-b"
if [ "$(rc e8)" = 2 ] && no_stdout e8 && err_has e8 "did not answer within 0.5s"; then ok "a resolver that hangs is cut at --timeout: exit 2"; else bad "hang: $(show e8)"; fi
run e9 --stack-pack "$T/stub-fail" --bundled "$T/t-a" --package "$T/t-b"
if [ "$(rc e9)" = 2 ] && no_stdout e9 && err_has e9 "bundled side" && err_has e9 "exited 3"; then ok "a bundled side that fails has no reference answer: exit 2, not 'both sides identical'"; else bad "failing reference: $(show e9)"; fi

echo "-- F. usage --"
run_default f1
if [ "$(rc f1)" = 2 ] && no_stdout f1 && err_has f1 "usage:"; then ok "no arguments: exit 2 with the usage on stderr"; else bad "no arguments: $(show f1)"; fi
run f2 --bundled "$REPO"
if [ "$(rc f2)" = 2 ] && no_stdout f2 && err_has f2 "--package"; then ok "a missing --package: exit 2, named"; else bad "missing --package: $(show f2)"; fi
run f3 --bundled "$REPO" --package "$P0" --bogus
if [ "$(rc f3)" = 2 ] && no_stdout f3; then ok "an unknown option: exit 2"; else bad "unknown option: $(show f3)"; fi
run f4 --bundled "$T/no-such-dir" --package "$P0"
if [ "$(rc f4)" = 2 ] && no_stdout f4 && err_has f4 "not a directory"; then ok "a root that is not a directory: exit 2"; else bad "missing root: $(show f4)"; fi
ln -s "$P0" "$T/alias"
run f5 --bundled "$P0" --package "$T/alias"
if [ "$(rc f5)" = 2 ] && no_stdout f5 && err_has f5 "same directory"; then ok "the same directory twice (here through a symlink): exit 2, a tree is not compared with itself"; else bad "same root: $(show f5)"; fi
run f6 --stack-pack "$T/not-exec" --bundled "$T/t-a" --package "$T/t-b"
if [ "$(rc f6)" = 2 ] && no_stdout f6 && err_has f6 "not an executable file"; then ok "a resolver that is not executable: exit 2"; else bad "non-executable resolver: $(show f6)"; fi
run f7 --timeout 0 --bundled "$T/t-a" --package "$T/t-b"
run f7b --timeout abc --bundled "$T/t-a" --package "$T/t-b"
if [ "$(rc f7)" = 2 ] && [ "$(rc f7b)" = 2 ] && err_has f7 "--timeout" && err_has f7b "--timeout"; then ok "--timeout 0 and --timeout abc: exit 2, named"; else bad "timeout values: $(show f7) $(show f7b)"; fi
run_default f8 --help
if [ "$(rc f8)" = 0 ] && out_has f8 "--bundled" && out_has f8 "--package" && out_has f8 "--stack-pack"; then ok "--help: exit 0, names --bundled, --package and --stack-pack on stdout"; else bad "--help: $(show f8)"; fi

echo "-- G. hygiene --"
LEFT="$(ls -A "$T/tmp")"
if [ -z "$LEFT" ]; then ok "no work directory is left behind by any run (identical, different, no verdict, timeout)"; else bad "left in TMPDIR: $LEFT"; fi

finish
