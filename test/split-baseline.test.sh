#!/usr/bin/env bash
#
# split-baseline.test.sh -- T0.1 of docs/superpowers/plans/2026-11-22-split-skills-statusline-repos.md: the recording of what the skills and
# statusline files and renders were BEFORE the repo split (evals/split/baseline.json, written and checked by bin/lib/split_baseline.py).
#
# The later waves mirror the files into two new repos and prove, against this recording, that no byte moved (INV-S1), that the registered entry points
# are where they were (INV-S2) and that the renderers print the same bytes (INV-S3). A recording is worth something only if it is the right one and
# its check can go RED, so:
#   A. the recording is the plan's inventory: 101 paths in four groups (skills 21, statusline runtime 18, conformance 26, suites 36) whose byte totals
#      are the numbers the plan measured (skills 163,291 B; hooks 2,775; bin 63,077; sentinels 323,741), every suite of the 36 has a host-call row,
#      and the host calls are the real ones (agent-pool.json is a data file, not a call of bin/agent-pool; prose "heimdall" is not bin/heimdall).
#      The recording stays whole after T3.2 moved 41 of those files out of heimdall (24 renderer-only suites, 17 conformance files that are not a sigil
#      golden; they live in hmd-statusline at v1.0.0): it is the record of the tree BEFORE the split, so all 41 are still in it.
#   B. the renders were not made up: the 21 recorded density and sigil renders are, byte for byte, the goldens committed under conformance/statusline.
#   C. the tool reproduces the recording: `check` on this tree is green (60 recorded files here and equal, 41 gone), and `record` writes the committed
#      file byte for byte (the 41 gone entries carried over from the previous baseline: they cannot be measured here any more).
#   D. every check can go RED. Each runs on a throwaway copy of the recorded files that are still in heimdall (a control run of the same copy is green
#      first): one flipped byte of the same size, a deleted file, a dropped exec bit, a link where hooks/statusline.sh belongs, a doctored baseline (a
#      hash, a dropped entry, a host call, a moved path or its host-call row), a suite that gains or loses a host call, a moved file that comes back, and
#      for the renders a doctored hash and a real change of the sigil renderer (one glyph). What must NOT count is proven as well: a host path in a
#      comment, a data file, prose.
#   E. what is not a recording is a usage error or a refusal, never a pass: a malformed or missing baseline, a --match that selects nothing, a
#      --root that is no directory, `record` on a tree without the host files, from a baseline that lost a moved path, or on a tree where a moved file
#      came back (it writes nothing).
# budget: ~12 s solo: the renderers are really run (32 fixtures, up to 8 workers): `record` renders twice, `check` once, plus a few single-fixture runs.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
TOOL="$ROOT/bin/lib/split_baseline.py"
BASE="$ROOT/evals/split/baseline.json"

pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n' "$1"; }

command -v python3 >/dev/null 2>&1 || { echo "SKIP: python3 unavailable"; echo "split-baseline: 0 passed, 0 failed (SKIPPED: python3 unavailable)"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq unavailable"; echo "split-baseline: 0 passed, 0 failed (SKIPPED: jq unavailable)"; exit 0; }
[ -f "$TOOL" ] || { echo "FATAL: $TOOL missing"; echo "split-baseline: 0 passed, 1 failed"; exit 1; }
[ -f "$BASE" ] || { echo "FATAL: $BASE missing"; echo "split-baseline: 0 passed, 1 failed"; exit 1; }

WORK="$(mktemp -d)" || { echo "FATAL: cannot make a temp dir"; exit 1; }
trap 'rm -rf "$WORK"' EXIT
OUT=""; RC=0

# run <tool args>: OUT is stdout and stderr, RC the exit status
run() { OUT="$(python3 -I "$TOOL" "$@" 2>&1)"; RC=$?; }
# green <label> <tool args>: exit 0 and "no difference"
green() {
  local label="$1"; shift
  run "$@"
  if [ "$RC" = 0 ] && grep -qF 'no difference' <<<"$OUT"; then ok "$label"; else bad "$label (exit $RC): $(tail -3 <<<"$OUT")"; fi
}
# red <label> <needle> <tool args>: exit 1 and the report names <needle>
red() {
  local label="$1" needle="$2"; shift 2
  run "$@"
  if [ "$RC" = 1 ] && grep -qF -- "$needle" <<<"$OUT"; then ok "$label"; else bad "$label (exit $RC, wanted 1 naming '$needle'): $(head -3 <<<"$OUT")"; fi
}
# usage_error <label> <tool args>: exit 2
usage_error() {
  local label="$1"; shift
  run "$@"
  if [ "$RC" = 2 ]; then ok "$label"; else bad "$label (exit $RC, wanted 2): $(head -2 <<<"$OUT")"; fi
}
# jqok <label> <filter>: the recording satisfies the filter
jqok() { if jq -e "$2" "$BASE" >/dev/null 2>&1; then ok "$1"; else bad "$1"; fi; }
# fresh <dir>: a clean copy of the recorded files that are still in heimdall and nothing else (modes and links kept)
fresh() {
  rm -rf "$1"; mkdir -p "$1"
  (cd "$ROOT" && tar -cf - -T "$WORK/kept.list") | tar -xf - -C "$1"
}

# T3.2: the 41 recorded files that left heimdall for hmd-statusline (v1.0.0): the 24 suites that call only the renderer, and every conformance file that
# is not a sigil golden (test/heimdall-sigil-render.test.sh, which stays, compares against those 9). Written out here, not read from the tool, so the
# tool's own list is held to this one.
GONE_SUITES="sigil-cache sigil-custom sigil-detailed sigil-eyestrip-mini sigil-micro sigil-png sigil-sprites sigil-team-mini
  statusline-agents-cache statusline-cc-columns statusline-cc-region-reserve statusline-cols-detect statusline-crossbranch statusline-density
  statusline-eyestrip statusline-fullbleed statusline-gauge statusline-host-boundary statusline-identity-flip statusline-panel-floor
  statusline-perf-budget statusline-register-cursor statusline-terminals statusline-width"
{ for s in $GONE_SUITES; do echo "test/heimdall-$s.test.sh"; done
  jq -r '.paths[].path | select(startswith("conformance/statusline/") and (startswith("conformance/statusline/goldens/sigil/") | not))' "$BASE"; } | LC_ALL=C sort > "$WORK/gone.list"
jq -r '.paths[].path' "$BASE" | grep -vxFf "$WORK/gone.list" > "$WORK/kept.list"

echo "== A) the recording is the plan's inventory =="
jqok "the plan's accept: at least 60 paths" '.paths|length>=60'
jqok "101 paths: skills 21, statusline-runtime 18, statusline-conformance 26, statusline-tests 36" \
  '(.paths|length)==101 and ([.paths[]|select(.group=="skills")]|length)==21 and ([.paths[]|select(.group=="statusline-runtime")]|length)==18
   and ([.paths[]|select(.group=="statusline-conformance")]|length)==26 and ([.paths[]|select(.group=="statusline-tests")]|length)==36'
jqok "every path appears once, with a sha256 and a positive byte count" \
  'all(.paths[]; (.sha256|test("^[0-9a-f]{64}$")) and .bytes>0) and ((.paths|map(.path)|unique|length)==(.paths|length))'
jqok "skills total 163291 bytes (plan 1a)" '[.paths[]|select(.group=="skills")|.bytes]|add==163291'
jqok "hooks 2775, the five bin files 63077, the seven measured sentinels 323741 bytes (plan 1b)" \
  '([.paths[]|select(.path|startswith("hooks/"))|.bytes]|add)==2775
   and ([.paths[]|select(.group=="statusline-runtime" and (.path|startswith("bin/")))|.bytes]|add)==63077
   and ([.paths[]|select(.group=="statusline-runtime" and (.path|startswith("sentinels/")) and (.path|test("hmd_(layout|termcaps|ledger|wall)")|not))|.bytes]|add)==323741'
jqok "a host-call row for each of the 36 suites, and no other" \
  '([.paths[]|select(.group=="statusline-tests")|.path]|sort)==(.host_calls|keys|sort)'
if jq -e --rawfile gone "$WORK/gone.list" '[.paths[].path] as $p | .host_calls as $h | ($gone | split("\n") | map(select(length > 0))) as $g
     | ($g | length) == 41 and all($g[]; . as $x | $p | index($x) != null) and all($g[] | select(startswith("test/")); . as $x | $h | has($x))' "$BASE" >/dev/null 2>&1
then ok "the 41 files that left heimdall (24 suites, 17 conformance files) are all still recorded, each suite with its host-call row"
else bad "the recording lost one of the 41 files that left heimdall, or a suite's host-call row"; fi
jqok "host calls are the real ones: bin/heimdall-identity, -agents, -ctx-meter, hooks/hooks.json, bin/heimdall" \
  '.host_calls["test/heimdall-statusline-identity-flip.test.sh"]==["bin/heimdall-identity"]
   and .host_calls["test/heimdall-statusline-agents-cache.test.sh"]==["bin/heimdall-agents"]
   and .host_calls["test/heimdall-statusline-parity.test.sh"]==["bin/heimdall-ctx-meter"]
   and .host_calls["test/heimdall-statusline-portability.test.sh"]==["hooks/hooks.json"]
   and .host_calls["test/heimdall-sigil-render.test.sh"]==["bin/heimdall"]'
jqok "agent-pool.json is not a call of bin/agent-pool; prose and JSON 'heimdall' are not bin/heimdall" \
  '.host_calls["test/heimdall-statusline-agent-tiers.test.sh"]==["bin/heimdall-tier"] and .host_calls["test/heimdall-statusline-density.test.sh"]==[]'
jqok "32 renders: density 12, sigil 9, hyphen twin 3, sigil CLI 1, entry points 5, subagent 2" \
  '(.renders|length)==32 and ([.renders[].id|select(startswith("density:"))]|length)==12 and ([.renders[].id|select(test("^sigil:"))]|length)==9
   and ([.renders[].id|select(startswith("sigil-twin:"))]|length)==3 and ([.renders[].id|select(startswith("sigil-cli:"))]|length)==1
   and ([.renders[].id|select(startswith("entry:"))]|length)==5 and ([.renders[].id|select(startswith("subagent:"))]|length)==2'

echo "== B) the recorded renders are the committed goldens, byte for byte =="
VERDICTS="$(jq -r '. as $d | ($d.renders[] | select(.id|test("^(density|sigil):"))) as $r | ($r.id|split(":")) as $f
  | ("conformance/statusline/goldens/" + $f[0] + "/rj_" + $f[1] + "_" + $f[2] + ".txt") as $p | ($d.paths[] | select(.path==$p)) as $g
  | "\($r.sha256==$g.sha256 and $r.bytes==$g.bytes)"' "$BASE")"
T="$(grep -c '^true$' <<<"$VERDICTS")"; F="$(grep -vc '^true$' <<<"$VERDICTS")"
if [ "$T" = 21 ] && [ "$F" = 0 ]; then ok "all 21 recorded density and sigil renders equal their committed golden"
else bad "recorded renders vs committed goldens: $T equal, $F not (want 21 and 0)"; fi

echo "== C) the tool reproduces the recording =="
green "check: this tree is the recorded tree (60 recorded files here and equal, 41 gone; 12 suites here, 24 gone; 32 renders)" check
run record --out "$WORK/rec.json"
if [ "$RC" = 0 ] && cmp -s "$WORK/rec.json" "$BASE"; then ok "record writes the committed baseline byte for byte (the 41 gone entries carried over, two renders of each fixture agree)"
else bad "record: exit $RC, $(cmp "$WORK/rec.json" "$BASE" 2>&1 | head -1)"; fi

echo "== D) every check can go RED =="
M="$WORK/tree"
NKEPT="$(grep -c . "$WORK/kept.list")"
if [ "$NKEPT" = 60 ] && [ "$(grep -c . "$WORK/gone.list")" = 41 ]; then ok "the 101 recorded paths are the 60 that stay in heimdall and the 41 that left"
else bad "the recorded paths split into $NKEPT that stay and $(grep -c . "$WORK/gone.list") that left (want 60 and 41)"; fi
fresh "$M"
green "control: a clean copy of the $NKEPT recorded files that stay passes the paths and host-calls checks (the 41 that left are absent)" check --root "$M" --only paths --only host-calls

fresh "$M"; printf 'X' | dd of="$M/skills/stacks/SKILL.md" bs=1 count=1 conv=notrunc 2>/dev/null
red "one byte of skills/stacks/SKILL.md flipped (same size): the sha256 differs" "FAIL paths skills/stacks/SKILL.md: sha256" check --root "$M" --only paths
if grep 'skills/stacks/SKILL.md' <<<"$OUT" | grep -qF 'bytes'; then bad "a same-size flip is reported as a size change: the hash is not what is compared"; else ok "the same-size flip is caught by the hash, not by the size"; fi

fresh "$M"; rm "$M/skills/self-improve/SKILL.md"
red "skills/self-improve/SKILL.md deleted" "FAIL paths skills/self-improve/SKILL.md: cannot read" check --root "$M" --only paths

fresh "$M"; chmod -x "$M/bin/heimdall-statusline"
red "bin/heimdall-statusline loses its exec bit" "FAIL paths bin/heimdall-statusline: exec True -> False" check --root "$M" --only paths

fresh "$M"; rm "$M/hooks/statusline.sh"; ln -s ../bin/heimdall-statusline "$M/hooks/statusline.sh"
red "hooks/statusline.sh (INV-S2) replaced by a link" "FAIL paths hooks/statusline.sh: not a regular file" check --root "$M" --only paths

fresh "$M"
FIRST="$(jq -r '.paths[0].path' "$BASE")"
jq 'def flip: if .[0:1]=="0" then "1"+.[1:] else "0"+.[1:] end; .paths[0].sha256 |= flip' "$BASE" > "$WORK/bad-sha.json"
red "a baseline whose recorded hash is off by one digit" "FAIL paths $FIRST: sha256" check --root "$M" --baseline "$WORK/bad-sha.json" --only paths
DROPPED="$(jq -r '.paths[5].path' "$BASE")"
jq 'del(.paths[5])' "$BASE" > "$WORK/short.json"
red "a baseline that lost one of the moved paths" "FAIL paths $DROPPED: measured, but the baseline does not list it" check --root "$M" --baseline "$WORK/short.json" --only paths
jq '.host_calls["test/heimdall-statusline-member-age.test.sh"] += ["bin/falsify"]' "$BASE" > "$WORK/bad-calls.json"
red "a baseline that records a host call the suite does not make" "FAIL host-calls test/heimdall-statusline-member-age.test.sh: no longer names bin/falsify" \
  check --root "$M" --baseline "$WORK/bad-calls.json" --only host-calls

fresh "$M"; printf '"$ROOT/bin/heimdall-presence" --help\n' >> "$M/test/heimdall-statusline-member-age.test.sh"
red "a suite gains a call of bin/heimdall-presence" "FAIL host-calls test/heimdall-statusline-member-age.test.sh: now also names bin/heimdall-presence" \
  check --root "$M" --only host-calls

fresh "$M"; grep -v 'heimdall-ctx-meter' "$M/test/heimdall-statusline-parity.test.sh" > "$WORK/parity.sh"; cp "$WORK/parity.sh" "$M/test/heimdall-statusline-parity.test.sh"
red "a suite stops calling bin/heimdall-ctx-meter" "FAIL host-calls test/heimdall-statusline-parity.test.sh: no longer names bin/heimdall-ctx-meter" \
  check --root "$M" --only host-calls

fresh "$M"; printf '%s\n' '# bin/heimdall-presence is only named in a comment' 'echo "the heimdall falsify words are prose"' 'AP=".heimdall/agent-pool.json"' \
  >> "$M/test/heimdall-statusline-member-age.test.sh"
green "a host path in a comment, prose and a data file are not calls" check --root "$M" --only host-calls

fresh "$M"
while read -r p; do mkdir -p "$M/$(dirname "$p")"; : > "$M/$p"; done < "$WORK/gone.list"
run check --root "$M" --only paths
if [ "$RC" = 1 ] && [ "$(grep -c 'moved to hmd-statusline, but it is still in this tree' <<<"$OUT")" = 41 ] \
   && grep -qF 'FAIL paths test/heimdall-statusline-gauge.test.sh: moved to hmd-statusline, but it is still in this tree' <<<"$OUT" \
   && grep -qF 'FAIL paths conformance/statusline/goldens/density/rj_mid_256.txt: moved to hmd-statusline, but it is still in this tree' <<<"$OUT"; then
  ok "all 41 moved files restored in a copy: each is named (a restored copy is one nobody pins)"
else bad "the 41 moved files restored: exit $RC, $(grep -c 'still in this tree' <<<"$OUT") named (want 41): $(head -2 <<<"$OUT")"; fi
run record --root "$M" --out "$WORK/never-restored.json"
if [ "$RC" = 1 ] && [ ! -e "$WORK/never-restored.json" ] \
   && grep -qF 'FAIL paths test/heimdall-statusline-gauge.test.sh: moved to hmd-statusline, but it is still in this tree' <<<"$OUT"; then
  ok "record on a tree where a moved file came back refuses and writes nothing"
else bad "record with a moved file restored: exit $RC, file written: $([ -e "$WORK/never-restored.json" ] && echo yes || echo no)"; fi

fresh "$M"
jq 'del(.paths[] | select(.path == "test/heimdall-statusline-gauge.test.sh"))' "$BASE" > "$WORK/no-gauge.json"
red "a baseline that lost a moved path" "FAIL paths test/heimdall-statusline-gauge.test.sh: moved to hmd-statusline, but the baseline has no record of it" \
  check --root "$M" --baseline "$WORK/no-gauge.json" --only paths
jq 'del(.host_calls["test/heimdall-statusline-gauge.test.sh"])' "$BASE" > "$WORK/no-gauge-calls.json"
red "a baseline that lost a moved suite's host-call row" "FAIL host-calls test/heimdall-statusline-gauge.test.sh: moved to hmd-statusline, but the baseline has no record of it" \
  check --root "$M" --baseline "$WORK/no-gauge-calls.json" --only host-calls

jq 'def flip: if .[0:1]=="0" then "1"+.[1:] else "0"+.[1:] end; (.renders[]|select(.id=="sigil:M:256")|.sha256) |= flip' "$BASE" > "$WORK/bad-render.json"
green "control: sigil:M:256 renders as recorded" check --only renders --match sigil:M:256
red "a baseline whose sigil:M:256 hash is off by one digit" "FAIL renders sigil:M:256: sha256" check --only renders --match sigil:M:256 --baseline "$WORK/bad-render.json"
fresh "$M"
green "control: the same render from a clean copy of the recorded files that stay" check --root "$M" --only renders --match sigil:M:256
if python3 -I - "$M/sentinels/hmd_sigil.py" <<'PY'
import sys
path = sys.argv[1]
text = open(path, encoding="utf-8").read()
old = "+ '▄' +"
if text.count(old) != 1:
    sys.exit("mutation site not found exactly once")
open(path, "w", encoding="utf-8").write(text.replace(old, "+ '▀' +"))
PY
then red "the sigil renderer changes one glyph (a copy of sentinels/hmd_sigil.py): the render differs" "FAIL renders sigil:M:256: sha256" \
       check --root "$M" --only renders --match sigil:M:256
else bad "the sigil renderer mutation did not apply (hmd_sigil.py moved on?)"; fi

echo "== E) what is not a recording is a usage error or a refusal, never a pass =="
printf '{"schema":1}\n' > "$WORK/malformed.json"
usage_error "a malformed baseline" check --baseline "$WORK/malformed.json" --only paths
usage_error "a missing baseline" check --baseline "$WORK/none.json" --only paths
usage_error "a --match that selects no fixture" check --only renders --match no-such-fixture
usage_error "a --root that is not a directory" check --root "$WORK/none" --only paths
run record --root "$M" --out "$WORK/never.json"
if [ "$RC" = 1 ] && [ ! -e "$WORK/never.json" ] && grep -qF 'FAIL host-paths bin/heimdall-status-json' <<<"$OUT"; then ok "record on a tree without the host files refuses and writes nothing"
else bad "record on a partial tree: exit $RC, file written: $([ -e "$WORK/never.json" ] && echo yes || echo no)"; fi
run record --out "$WORK/never-nogauge.json" --baseline "$WORK/no-gauge.json"
if [ "$RC" = 1 ] && [ ! -e "$WORK/never-nogauge.json" ] \
   && grep -qF 'FAIL paths test/heimdall-statusline-gauge.test.sh: moved to hmd-statusline, but the baseline has no record of it' <<<"$OUT"; then
  ok "record from a baseline that lost a moved path refuses and writes nothing (it cannot carry an entry that is not there)"
else bad "record from a baseline without a moved path: exit $RC, file written: $([ -e "$WORK/never-nogauge.json" ] && echo yes || echo no)"; fi
usage_error "record from a baseline that is missing" record --out "$WORK/never-nobase.json" --baseline "$WORK/none.json"
if [ ! -e "$WORK/never-nobase.json" ]; then ok "... and it writes nothing"; else bad "record from a missing baseline wrote a file"; fi

echo
echo "split-baseline: $pass passed, $fail failed"
[ "$fail" -eq 0 ] || exit 1
