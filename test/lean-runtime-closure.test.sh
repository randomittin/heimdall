#!/usr/bin/env bash
# lean-runtime-closure.test.sh -- proves bin/heimdall-runtime-closure and its committed answer, release/runtime-files.txt (T0.2 of the 3.x lean-core plan,
# docs/superpowers/plans/2026-11-12-3x-lean-core.md). The lean install is a sparse checkout, so a file the code needs and the list lacks is a run-time break.
#
#   1. THE RULES, on a fixture repository (a temp git index, no commit: the tool reads what is staged): every kind of reference reaches its file (shell `.`, `$PLUGIN_DIR/x`,
#      `"$HERE/../x"`, a hook command in hooks.json, a Python import, a Python os.path.join of separate literals, a JSON manifest string, a chain of three hops), a directory
#      named by its literal prefix is kept WHOLE (the unknown dynamic path stays included), and what only SAYS a path (echo text, a comment, a docstring, a bare `docs/` word)
#      names nothing; test/, .planning/ and evals/effort-ab/ are never runtime even when code names them (a bare run.sh in bin/ names EVERY run.sh of the repository,
#      the effort harness's among them, and its fixtures, patches and results would ride along), and `explain` says why.
#   2. BREAK IT: delete one reference from the fixture and the file it reached drops out of the list.
#   3. `check`: an equal list passes; a list missing a path, carrying a stray path, or unreadable fails (1, 1, 2) and the first two name the path.
#   4. THE REAL REPOSITORY: the plan's acceptance (evals/oracles/registry.json in, nothing from test/), the committed release/runtime-files.txt IS the computed list, every root
#      is in it, every line is a tracked path, it is sorted and unique, and it is smaller than the tracked set.
#   5. THE MUTANT the plan asks for: the committed list minus one referenced file fails `check` and the failure names that file.
#
# bash 3.2 compatible. The real repository is read twice (about 5 s each); the fixture runs are instant.
#
# Usage:  bash test/lean-runtime-closure.test.sh
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SELF_DIR/.." && pwd)"
TOOL="$REPO/bin/heimdall-runtime-closure"
LIST="$REPO/release/runtime-files.txt"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; }

T="$(mktemp -d "${TMPDIR:-/tmp}/lean-runtime-closure.XXXXXX")" || exit 1; T="$(cd "$T" && pwd -P)"
cleanup() { rm -rf "$T"; }
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

echo "lean-runtime-closure (heimdall-runtime-closure: the rules on a fixture, check, and the committed list of the real repository)"

# run NAME CMD...: stdout, stderr and the exit status of CMD in $T/NAME.{out,err,rc}
run() { local n="$1"; shift; "$@" >"$T/$n.out" 2>"$T/$n.err"; echo $? > "$T/$n.rc"; }
RC() { cat "$T/$1.rc" 2>/dev/null; }
go() { grep -qF -- "$2" "$T/$1.out" 2>/dev/null; }
show() { printf 'rc=%s out=[%s] err=[%s]' "$(RC "$1")" "$(head -c 500 "$T/$1.out" 2>/dev/null)" "$(head -c 300 "$T/$1.err" 2>/dev/null)"; }

echo "-- 0. the tool exists, runs and prints its usage --"
if [ -x "$TOOL" ]; then ok "bin/heimdall-runtime-closure exists and is executable"; else bad "bin/heimdall-runtime-closure is missing or not executable"; fi
run help "$TOOL" --help
if [ "$(RC help)" = 0 ] && go help "check" && go help "explain"; then ok "--help exits 0 and lists check and explain"; else bad "--help: $(show help)"; fi

# ── the fixture: a tiny plugin laid out like this one, staged and never committed ────────────────────────────────────────────────────────────────────
FX="$T/fx"
mkdir -p "$FX" && git -C "$FX" init -q || { echo "cannot create the fixture repository"; exit 1; }
put() { mkdir -p "$(dirname "$FX/$1")"; cat > "$FX/$1"; }
stage() { git -C "$FX" add -A >/dev/null 2>&1; }

put bin/main <<'EOF'
#!/usr/bin/env bash
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/lib/util.sh"
cat "$PLUGIN_DIR/data/conf.json" >/dev/null
python3 "$PLUGIN_DIR/tools/helper.py"
exec "$HERE/../sentinels/ui.sh"
echo "see docs/guide.md for help"
# docs/commented-out.md is only a comment
ls docs/other/ >/dev/null
[ -f "$REPO/test/run-all.sh" ] && bash "$REPO/test/run-all.sh"
cat "$ROOT/.planning/STATE.md" >/dev/null
EOF
put bin/lib/util.sh <<'EOF'
echo util
EOF
put bin/lib/dyn.sh <<'EOF'
ls "$PLUGIN_DIR/modules/$id/manifest.json" >/dev/null
EOF
put bin/pytool <<'EOF'
#!/usr/bin/env python3
"""A docstring that names docs/py-doc.md and means nothing."""
import os
import helperlib
PLUGIN_DIR = os.environ.get("PLUGIN_DIR", ".")
icon = open(os.path.join(PLUGIN_DIR, "assets", "icon.txt")).read()   # see docs/py-comment.md
EOF
put tools/helper.py <<'EOF'
import os
PLUGIN_DIR = os.environ.get("PLUGIN_DIR", ".")
second = open(os.path.join(PLUGIN_DIR, "data", "second.json")).read()
EOF
put tools/helperlib.py <<'EOF'
VALUE = 1
EOF
put data/conf.json <<'EOF'
{"next": "data/leaf.txt", "note": "prose that names nothing tracked"}
EOF
put data/second.json <<'EOF'
{"deeper": "data/deeper.txt"}
EOF
put data/leaf.txt <<'EOF'
leaf
EOF
put data/deeper.txt <<'EOF'
deeper
EOF
put assets/icon.txt <<'EOF'
icon
EOF
put sentinels/ui.sh <<'EOF'
echo ui
EOF
put modules/alpha/manifest.json <<'EOF'
{"name": "alpha"}
EOF
put modules/beta/manifest.json <<'EOF'
{"name": "beta"}
EOF
put hooks/hooks.json <<'EOF'
{"hooks": {"SessionStart": [{"hooks": [{"type": "command", "command": "\"${CLAUDE_PLUGIN_ROOT}/hooks/guard.sh\" run"}]}]}}
EOF
put hooks/guard.sh <<'EOF'
echo guard
EOF
put install.sh <<'EOF'
cp "$PLUGIN_DIR/templates/settings.tpl" "$HOME/settings.copy"
EOF
put templates/settings.tpl <<'EOF'
template
EOF
put bin/runner <<'EOF'
#!/usr/bin/env bash
bash "$PLUGIN_DIR/evals/gates/$gate/run.sh"
EOF
put evals/gates/g1/run.sh <<'EOF'
echo gate
EOF
put evals/effort-ab/run.sh <<'EOF'
exec python3 "$HERE/run.py"
EOF
put evals/effort-ab/run.py <<'EOF'
import os
HERE = os.path.dirname(os.path.realpath(__file__))
TASKS = os.path.join(HERE, "tasks")
EOF
put evals/effort-ab/tasks/t1.txt <<'EOF'
task
EOF
for f in docs/guide.md docs/commented-out.md docs/py-comment.md docs/py-doc.md docs/other/x.md evals/other/x.json relay/src/x.ts test/main.test.sh test/run-all.sh .planning/STATE.md; do
  printf 'not runtime\n' | put "$f"
done
stage

EXPECT_RUNTIME="assets/icon.txt
bin/lib/dyn.sh
bin/lib/util.sh
bin/main
bin/pytool
bin/runner
data/conf.json
data/deeper.txt
data/leaf.txt
data/second.json
evals/gates/g1/run.sh
hooks/guard.sh
hooks/hooks.json
install.sh
modules/alpha/manifest.json
modules/beta/manifest.json
release/runtime-files.txt
sentinels/ui.sh
templates/settings.tpl
tools/helper.py
tools/helperlib.py"
EXPECT_OTHER=".planning/STATE.md
docs/commented-out.md
docs/guide.md
docs/other/x.md
docs/py-comment.md
docs/py-doc.md
evals/effort-ab/run.py
evals/effort-ab/run.sh
evals/effort-ab/tasks/t1.txt
evals/other/x.json
relay/src/x.ts
test/main.test.sh
test/run-all.sh"

echo "-- 1. the rules, on a fixture --"
run fxlist "$TOOL" --repo "$FX" list
if [ "$(RC fxlist)" = 0 ] && [ "$(cat "$T/fxlist.out")" = "$EXPECT_RUNTIME" ]; then
  ok "list = roots + shell \`.\`/\$PLUGIN_DIR/\$HERE/.., hooks.json, python import and os.path.join, a JSON manifest string, a 3-hop chain, the whole modules/ dir (dynamic prefix), and the list itself"
else
  bad "fixture list differs: $(diff <(printf '%s\n' "$EXPECT_RUNTIME") "$T/fxlist.out" 2>&1 | head -12 | tr '\n' '|') $(show fxlist | head -c 200)"
fi
run fxother "$TOOL" --repo "$FX" non-runtime
if [ "$(RC fxother)" = 0 ] && [ "$(cat "$T/fxother.out")" = "$(printf '%s\n' "$EXPECT_OTHER" | LC_ALL=C sort)" ]; then
  ok "non-runtime = what only echo text, a comment, a docstring, a bare docs/ word or a policy tree names, and what nothing names"
else
  bad "fixture non-runtime differs: $(diff <(printf '%s\n' "$EXPECT_OTHER" | LC_ALL=C sort) "$T/fxother.out" 2>&1 | head -10 | tr '\n' '|')"
fi
run fxwhy "$TOOL" --repo "$FX" explain data/deeper.txt
if [ "$(RC fxwhy)" = 0 ] && go fxwhy "data/deeper.txt: runtime" && go fxwhy "data/second.json" && go fxwhy "tools/helper.py" && go fxwhy "bin/main [root"; then ok "explain walks the whole chain: data/deeper.txt <- data/second.json <- tools/helper.py <- bin/main (root)"; else bad "explain chain: $(show fxwhy)"; fi
run fxpol "$TOOL" --repo "$FX" explain test/run-all.sh
if [ "$(RC fxpol)" = 0 ] && go fxpol "non-runtime by policy" && go fxpol "bin/main"; then ok "explain: test/run-all.sh is non-runtime by policy, and says bin/main named it"; else bad "explain policy: $(show fxpol)"; fi
run fxpl "$TOOL" --repo "$FX" explain .planning/STATE.md
if [ "$(RC fxpl)" = 0 ] && go fxpl "non-runtime by policy"; then ok "explain: .planning/STATE.md is non-runtime by policy"; else bad "explain .planning: $(show fxpl)"; fi
run fxeff "$TOOL" --repo "$FX" explain evals/effort-ab/run.sh
if [ "$(RC fxeff)" = 0 ] && go fxeff "non-runtime by policy" && go fxeff "bin/runner"; then ok "explain: evals/effort-ab/run.sh is non-runtime by policy, and says bin/runner named it (a bare run.sh names every run.sh); the other run.sh stays runtime"; else bad "explain effort-ab: $(show fxeff)"; fi
run fxno "$TOOL" --repo "$FX" explain docs/guide.md
if [ "$(RC fxno)" = 0 ] && go fxno "nothing reachable"; then ok "explain: docs/guide.md is non-runtime because nothing names it"; else bad "explain unreferenced: $(show fxno)"; fi
run fxbad "$TOOL" --repo "$FX" explain no/such/file
if [ "$(RC fxbad)" = 2 ] && go fxbad "not a tracked path"; then ok "explain of an untracked path exits 2"; else bad "explain untracked: $(show fxbad)"; fi

echo "-- 2. break it: one reference removed, its file leaves the list --"
grep -v 'sentinels/ui.sh' "$FX/bin/main" > "$T/main.cut" && cp "$T/main.cut" "$FX/bin/main" && stage
run fxcut "$TOOL" --repo "$FX" list
if [ "$(RC fxcut)" = 0 ] && ! grep -qx 'sentinels/ui.sh' "$T/fxcut.out" && grep -qx 'bin/main' "$T/fxcut.out" && grep -qx 'tools/helper.py' "$T/fxcut.out"; then
  ok "without the exec line, sentinels/ui.sh is non-runtime and the other references still hold"
else
  bad "after removing the reference: $(show fxcut | head -c 300)"
fi

echo "-- 3. check --"
"$TOOL" --repo "$FX" list > "$T/fx.list" 2>/dev/null
run chk_same "$TOOL" --repo "$FX" check --list "$T/fx.list"
if [ "$(RC chk_same)" = 0 ] && [ ! -s "$T/chk_same.out" ]; then ok "check passes (0, silent) on the list it computed"; else bad "check on an equal list: $(show chk_same)"; fi
grep -vx 'data/leaf.txt' "$T/fx.list" > "$T/fx.missing"
run chk_miss "$TOOL" --repo "$FX" check --list "$T/fx.missing"
if [ "$(RC chk_miss)" = 1 ] && go chk_miss "missing  data/leaf.txt" && go chk_miss "regenerate:"; then ok "check fails (1) on a list missing a referenced path, names it and says how to regenerate"; else bad "check on a list missing a path: $(show chk_miss)"; fi
{ cat "$T/fx.list"; echo ghost/file; } > "$T/fx.extra"
run chk_extra "$TOOL" --repo "$FX" check --list "$T/fx.extra"
if [ "$(RC chk_extra)" = 1 ] && go chk_extra "extra    ghost/file"; then ok "check fails (1) on a stray path and names it"; else bad "check on a list with a stray path: $(show chk_extra)"; fi
run chk_gone "$TOOL" --repo "$FX" check --list "$T/no-such.list"
if [ "$(RC chk_gone)" = 2 ]; then ok "check exits 2 when the list cannot be read"; else bad "check on an unreadable list: $(show chk_gone)"; fi
run chk_repo "$TOOL" --repo "$T" list
if [ "$(RC chk_repo)" = 2 ]; then ok "a directory outside any repository exits 2"; else bad "outside a repository: $(show chk_repo)"; fi

echo "-- 4. the real repository --"
run real "$TOOL" --repo "$REPO" list
if [ "$(RC real)" = 0 ] && [ -s "$T/real.out" ]; then ok "list runs on the repository (exit 0, non-empty)"; else bad "list on the real repository: $(show real)"; fi
if grep -qx 'evals/oracles/registry.json' "$T/real.out"; then ok "plan acceptance: evals/oracles/registry.json is runtime"; else bad "evals/oracles/registry.json is missing from the computed list"; fi
if ! grep -q '^test/' "$T/real.out"; then ok "plan acceptance: nothing under test/ is runtime"; else bad "test/ paths in the computed list: $(grep '^test/' "$T/real.out" | head -3 | tr '\n' ' ')"; fi
if [ -f "$LIST" ] && cmp -s "$T/real.out" "$LIST"; then ok "release/runtime-files.txt is exactly the computed list"; else bad "release/runtime-files.txt is missing or stale: regenerate it with bin/heimdall-runtime-closure list > release/runtime-files.txt"; fi
if [ -f "$LIST" ] && grep -q '^release/runtime-files.txt$' "$LIST"; then ok "the list names itself (the lean sparse apply reads it from the checkout it applies to)"; else bad "release/runtime-files.txt does not list itself"; fi
git -C "$REPO" ls-files > "$T/tracked.txt"
MISSING_ROOTS="$(cat <(grep '^bin/' "$T/tracked.txt") <(printf 'hooks/hooks.json\ninstall.sh\n') | grep -vxFf "$LIST" 2>/dev/null | head -3 | tr '\n' ' ')"
if [ -f "$LIST" ] && [ -z "$MISSING_ROOTS" ]; then ok "every tracked bin/ file, hooks/hooks.json and install.sh are in the list"; else bad "roots missing from the list: $MISSING_ROOTS"; fi
NOT_TRACKED="$(grep -vxFf "$T/tracked.txt" "$LIST" 2>/dev/null | grep -vx 'release/runtime-files.txt' | head -3 | tr '\n' ' ')"
if [ -f "$LIST" ] && [ -z "$NOT_TRACKED" ]; then ok "every line of the list is a tracked path"; else bad "lines that are no tracked path: $NOT_TRACKED"; fi
if [ -f "$LIST" ] && LC_ALL=C sort -c -u "$LIST" 2>/dev/null; then ok "the list is sorted and has no repeated or blank-looking lines"; else bad "the list is not sorted-unique"; fi
if [ -f "$LIST" ] && [ "$(grep -c '' "$LIST")" -lt "$(grep -c '' "$T/tracked.txt")" ] && [ "$(grep -c '' "$LIST")" -gt 100 ]; then ok "the list is a real subset: $(grep -c '' "$LIST") of $(grep -c '' "$T/tracked.txt") tracked files"; else bad "the list is not a proper subset of the tracked files"; fi
if [ -f "$LIST" ] && ! grep -q '^\.planning/' "$LIST"; then ok "nothing under .planning/ is runtime"; else bad ".planning/ paths in the list"; fi
if ! grep -q '^evals/effort-ab/' "$T/real.out" && { [ ! -f "$LIST" ] || ! grep -q '^evals/effort-ab/' "$LIST"; }; then ok "nothing under evals/effort-ab/ is runtime, computed or committed (bin/corpus names a bare run.sh, which names every run.sh)"; else bad "evals/effort-ab/ paths in the list: $(grep -c '^evals/effort-ab/' "$T/real.out") computed, $(grep -c '^evals/effort-ab/' "$LIST" 2>/dev/null) committed"; fi

echo "-- 5. the mutant: a referenced file removed from the committed list --"
if [ -f "$LIST" ]; then
  grep -vx 'evals/oracles/registry.json' "$LIST" > "$T/real.mutant"
  run mut "$TOOL" --repo "$REPO" check --list "$T/real.mutant"
  if [ "$(RC mut)" = 1 ] && go mut "missing  evals/oracles/registry.json"; then ok "check goes RED (1) on the committed list minus evals/oracles/registry.json, and names it"; else bad "the mutant list was not caught: $(show mut)"; fi
else
  bad "no committed list to mutate"
fi

printf '\nlean-runtime-closure: %s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
