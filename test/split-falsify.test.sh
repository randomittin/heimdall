#!/usr/bin/env bash
#
# split-falsify.test.sh -- T4.1 of docs/superpowers/plans/2026-11-22-split-skills-statusline-repos.md (section 4 "Oracle gate", section 6 wave 4): the gates of
# the repo split can go RED.
#
# The split is guarded by gates that are silent while they are green: `bin/heimdall-vendor verify --all` (the mirror hashes to the lock), `bash
# test/vendor-parity.test.sh` (lock and mirror equal the recording of the tree before the split, evals/split/baseline.json) and `bash test/split-baseline.test.sh`
# (the recording is whole, and what its tool measures is what it says). A gate only ever seen green has not been shown to work. So this suite breaks the split
# the five ways the plan lists, each a patch file of evals/split/mutants/ applied to its OWN COPY of the tracked tree, and runs the gates on every copy:
#
#   M1  one byte of a mirrored file changes, the size does not     skills/mac-deep-clean/SKILL.md ("du -sh" becomes "du -sk")
#   M2  the lock's tree_sha256 of hmd-statusline flips one hex digit
#   M3  a moved path leaves the lock's list (hooks/statusline.sh; the file stays in the tree, tree_sha256 is untouched)
#   M4  hooks/statusline.sh is renamed (INV-S2: users' settings.json names that path)
#   M5  a conformance golden changes                                conformance/statusline/goldens/sigil/rj_M_256.txt
#
# THE GOLDEN. The same gates first run on an unmutated copy and must all be green: a gate that is red on its own tree would make every mutant "red" for nothing,
# so a red golden voids the score. The golden is also the plan's render-parity row (split-falsify + goldens): the nine sigil goldens are what
# sentinels/hmd_sigil.py prints, byte for byte.
#
# KILLED. A mutant is killed when every gate it is designated for goes RED, and RED is the gate's own report of that defect (exit 1 and the line that names it),
# not a crash, a skip or a failure somewhere else. A gate that stays green is a survivor and a finding: the suite fails and names it, it never relaxes the mutant.
# A patch that no longer applies, or changes something other than it says, is a failure of this suite and never a kill.
#
#   gate                       M1    M2    M3    M4    M5
#   verify --all               RED   RED   RED   RED   RED
#   vendor-parity suite        RED   RED   RED   RED   RED    (its recording check, section B, also names the path in every one but M2)
#   split-baseline suite       RED    -     -    RED   RED    (the recording never reads the lock, so a mutant that only touches the lock is not its business)
#   sigil goldens vs render     -     -     -     -    RED    (rj_M_256 drifts, the other eight stay the renderer's bytes)
#
# The copy is made here from the files on disk (git ls-files names them) and the patches are applied there: the real tree is never written, and the suite checks
# that at the end. No network: section C of the vendor-parity suite (the pin is the tag, checked against local clones) is switched off here, no mutant touches
# what it reads. The five jobs and the golden run side by side; each gate runs inside its own copy, so it reads that copy's tools, lock, recording and files.
#
# score = killed / 5, printed as `score 1.0` when every mutant is killed and the golden is green.
#
# budget: 120 -- about 45 s solo, no assertion depends on speed: six copies of the tracked tree (about 35 MB each, 0.4 s apiece), then up to six runs of the
# vendor-parity suite (a few seconds each) and four of the split-baseline suite (about 12 s each, the renderers really run: 32 fixtures, 3 workers apiece),
# all side by side, plus nine sigil renders for the two copies that need them. A failure that only shows under load gets ONE solo re-run.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
MUT="$ROOT/evals/split/mutants"
MUTANTS="M1 M2 M3 M4 M5"
TOTAL=5

pass=0; fail=0
ok()    { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad()   { fail=$((fail+1)); printf '  FAIL %s\n' "$1"; }
skip()  { echo "SKIP: $1"; echo "split-falsify: 0 passed, 0 failed (SKIPPED: $1)"; exit 0; }
fatal() { echo "FATAL: $1"; echo "split-falsify: $pass passed, $((fail+1)) failed"; exit 1; }

# ---- the tables: for each case the patch, what it changes, the gates it must turn red, and what each red gate says ------------------------------------------
patch_of() {
  case "$1" in
    M1) echo "M1-flip-one-byte-of-a-mirrored-file.patch" ;;
    M2) echo "M2-flip-a-lock-tree-sha256.patch" ;;
    M3) echo "M3-drop-a-moved-path-from-the-lock.patch" ;;
    M4) echo "M4-rename-the-statusline-hook.patch" ;;
    M5) echo "M5-change-a-sigil-golden.patch" ;;
    *) echo "" ;;
  esac
}
# touched_of <id>: the paths the patch changes (relative to the tree), nothing else may differ from the staged copy
touched_of() {
  case "$1" in
    M1) echo "skills/mac-deep-clean/SKILL.md" ;;
    M2|M3) echo "vendor/vendor.lock.json" ;;
    M4) echo "hooks/statusline.sh hooks/statusline-renamed.sh" ;;
    M5) echo "conformance/statusline/goldens/sigil/rj_M_256.txt" ;;
    *) echo "" ;;
  esac
}
# gates_of <id>: verify, parity (test/vendor-parity.test.sh), baseline (test/split-baseline.test.sh), goldens (the nine sigil goldens against the renderer)
gates_of() {
  case "$1" in
    golden|M5) echo "verify parity baseline goldens" ;;
    M1|M4) echo "verify parity baseline" ;;
    M2|M3) echo "verify parity" ;;
    *) echo "" ;;
  esac
}
# verify_says <id>: the line bin/heimdall-vendor verify --all prints for this defect
verify_says() {
  case "$1" in
    M1) echo "FAIL hmd-skills: tree_sha256 differs" ;;
    M2|M3|M5) echo "FAIL hmd-statusline: tree_sha256 differs" ;;
    M4) echo "FAIL hmd-statusline hooks/statusline.sh: missing" ;;
    *) echo "" ;;
  esac
}
# parity_names <id>: what the vendor-parity suite's recording check (section B) must name; nothing for M2, because the recording holds no hash of the lock
parity_names() {
  case "$1" in
    M1) echo "skills/mac-deep-clean/SKILL.md" ;;
    M3) echo "in the recording, not pinned: hooks/statusline.sh" ;;
    M4) echo "hooks/statusline.sh" ;;
    M5) echo "conformance/statusline/goldens/sigil/rj_M_256.txt" ;;
    *) echo "" ;;
  esac
}

for need in python3 jq git tar cmp diff awk; do command -v "$need" >/dev/null 2>&1 || skip "$need unavailable"; done
if ! command -v shasum >/dev/null 2>&1 && ! command -v sha256sum >/dev/null 2>&1; then skip "no shasum or sha256sum"; fi
for need in bin/heimdall-vendor bin/lib/vendor_lock.py bin/lib/split_baseline.py vendor/vendor.lock.json evals/split/baseline.json test/vendor-parity.test.sh \
            test/split-baseline.test.sh sentinels/hmd_sigil.py; do
  [ -f "$ROOT/$need" ] || fatal "$ROOT/$need is missing"
done
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_COMMON_DIR GIT_NAMESPACE GIT_PREFIX GIT_QUARANTINE_PATH

WORK="$(mktemp -d)" || fatal "cannot make a temp dir"
WORK="$(cd "$WORK" && pwd -P)"
trap 'rm -rf "$WORK"' EXIT
trap 'exit 130' INT TERM
mkdir -p "$WORK/res" "$WORK/home"

echo "split-falsify"
echo "== the five patches =="
NPATCH="$(find "$MUT" -maxdepth 1 -name '*.patch' 2>/dev/null | grep -c .)"
MISSING=""
for id in $MUTANTS; do [ -f "$MUT/$(patch_of "$id")" ] || MISSING="$MISSING $(patch_of "$id")"; done
if [ "$NPATCH" = "$TOTAL" ] && [ -z "$MISSING" ]; then ok "evals/split/mutants holds the plan's five patches, M1 to M5, and no other"
else bad "evals/split/mutants has $NPATCH patches ($TOTAL wanted, M1 to M5)${MISSING:+, missing:$MISSING}"; fi

# ---- the staged tree: the tracked files as they are on disk (one tracked but deleted is skipped), copied once and cloned for every case ------------------------
git -C "$ROOT" ls-files -z > "$WORK/tracked.z" 2> "$WORK/ls-files.err" || fatal "git ls-files failed in $ROOT: $(head -1 "$WORK/ls-files.err")"
cat > "$WORK/stage.py" <<'PY'
import os
import shutil
import sys

src, dst, listing = sys.argv[1:4]
count = 0
with open(listing, "rb") as handle:
    names = handle.read().split(b"\0")
for raw in names:
    if not raw:
        continue
    rel = os.fsdecode(raw)
    path = os.path.join(src, rel)
    if not os.path.lexists(path):
        continue
    target = os.path.join(dst, rel)
    os.makedirs(os.path.dirname(target), exist_ok=True)
    if os.path.islink(path):
        os.symlink(os.readlink(path), target)
    elif os.path.isdir(path):
        os.makedirs(target, exist_ok=True)
    else:
        shutil.copy2(path, target)
        count += 1
print(count)
PY
NSTAGED="$(python3 -I "$WORK/stage.py" "$ROOT" "$WORK/base" "$WORK/tracked.z")" || fatal "cannot copy the tracked tree of $ROOT"

# render_goldens <dir>: one line per sigil golden, "same" or "DRIFT", of what the copy's renderer prints against the copy's golden; exit 0 only when all nine are the same
render_goldens() {
  local dir="$1" size tier drift=0 pybin
  pybin="$(dirname "$(command -v python3)")"
  for size in S M L; do
    for tier in 16 256 truecolor; do
      if env -i PATH="$pybin:/usr/bin:/bin" HOME="$WORK/home" LANG=en_US.UTF-8 python3 "$dir/sentinels/hmd_sigil.py" --seed rj --size "$size" --tier "$tier" 2>/dev/null \
           | cmp -s - "$dir/conformance/statusline/goldens/sigil/rj_${size}_${tier}.txt"; then
        echo "same rj_${size}_${tier}"
      else
        echo "DRIFT rj_${size}_${tier}"; drift=$((drift+1))
      fi
    done
  done
  [ "$drift" -eq 0 ]
}
# run_gate <id> <gate> <dir>: the gate runs inside the copy; its output and exit status go to $WORK/res/<id>/<gate>.out and .rc
run_gate() {
  local id="$1" gate="$2" dir="$3"
  case "$gate" in
    verify)   ( cd "$dir" && bin/heimdall-vendor verify --all ) ;;
    parity)   ( cd "$dir" && HMD_SPLIT_REPOS_DIR="$WORK/no-clones" bash test/vendor-parity.test.sh ) ;;
    baseline) ( cd "$dir" && SPLIT_BASELINE_JOBS=3 bash test/split-baseline.test.sh ) ;;
    goldens)  render_goldens "$dir" ;;
  esac > "$WORK/res/$id/$gate.out" 2>&1
  echo $? > "$WORK/res/$id/$gate.rc"
}
# job <id> <patch file, or empty for the golden>: a copy of the staged tree, the patch applied to it, a record of what the patch changed, then the designated gates
job() {
  local id="$1" patch="$2" dir="$WORK/copy-$1" res="$WORK/res/$1" gate
  mkdir -p "$res"
  if ! cp -R "$WORK/base" "$dir" > "$res/copy.out" 2>&1; then echo 1 > "$res/apply.rc"; return 0; fi
  if [ -n "$patch" ]; then
    ( cd "$dir" && GIT_CEILING_DIRECTORIES="$WORK" GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null git apply --whitespace=nowarn "$MUT/$patch" ) > "$res/apply.out" 2>&1
    echo $? > "$res/apply.rc"
    [ "$(cat "$res/apply.rc")" = 0 ] || return 0
  else
    echo 0 > "$res/apply.rc"
  fi
  diff -rq "$WORK/base" "$dir" > "$res/delta.txt" 2>&1
  for gate in $(gates_of "$id"); do run_gate "$id" "$gate" "$dir"; done
  return 0
}

echo "== $NSTAGED tracked files staged; the gates run on a copy each for the golden and M1 to M5, side by side =="
for id in golden $MUTANTS; do job "$id" "$(patch_of "$id")" & done
wait

rc_of() { cat "$WORK/res/$1/$2.rc" 2>/dev/null || echo none; }
# suite_line <out file> <suite name> <passed pattern> <failed pattern>: the suite's last report, "<name>: N passed, M failed"
suite_line() { grep -Eq "^$2: $3 passed, $4 failed\$" "$1"; }
WHY=""

echo "== the golden: the unmutated copy =="
GOLDEN_OK=1
if [ "$(rc_of golden apply)" = 0 ] && [ ! -s "$WORK/res/golden/delta.txt" ]; then ok "the copy of the tree is byte for byte the staged tree"
else bad "the golden copy differs from the staged tree: $(head -2 "$WORK/res/golden/delta.txt" 2>/dev/null | tr '\n' ' ')"; GOLDEN_OK=0; fi
for gate in verify parity baseline goldens; do
  out="$WORK/res/golden/$gate.out"; rc="$(rc_of golden "$gate")"; good=0
  if [ "$rc" = 0 ]; then
    case "$gate" in
      verify)   grep -qF 'ok hmd-skills' "$out" && grep -qF 'ok hmd-statusline' "$out" && good=1; WHY="exit 0, both repositories ok" ;;
      parity)   suite_line "$out" vendor-parity '[1-9][0-9]*' 0 && ! grep -qF SKIPPED "$out" && good=1; WHY="$(grep -E '^vendor-parity: ' "$out" | tail -1)" ;;
      baseline) suite_line "$out" split-baseline '[1-9][0-9]*' 0 && ! grep -qF SKIPPED "$out" && good=1; WHY="$(grep -E '^split-baseline: ' "$out" | tail -1)" ;;
      goldens)  [ "$(grep -c '^same ' "$out")" = 9 ] && good=1; WHY="all nine sigil goldens are what sentinels/hmd_sigil.py prints" ;;
    esac
  fi
  if [ "$good" = 1 ]; then ok "golden $gate is green ($WHY)"
  else bad "golden $gate is not green (exit $rc): $(tail -3 "$out" 2>/dev/null | tr '\n' ' ')"; GOLDEN_OK=0; fi
done

# verdict <id> <gate>: 0 when the gate is RED the way this mutant must make it, 1 when it stayed green (a survivor), 2 when it is red for another reason; WHY says what was seen
verdict() {
  local id="$1" gate="$2" rc out need
  rc="$(rc_of "$id" "$gate")"; out="$WORK/res/$id/$gate.out"; WHY=""
  if [ "$rc" = 0 ]; then WHY="the gate exited 0: $(tail -1 "$out" 2>/dev/null)"; return 1; fi
  if [ "$rc" != 1 ]; then WHY="the gate exited $rc, not 1 (a stop, not a report): $(tail -2 "$out" 2>/dev/null | tr '\n' ' ')"; return 2; fi
  if grep -Eq 'Traceback|FATAL|SKIPPED' "$out"; then WHY="the gate stopped instead of reporting: $(grep -E 'Traceback|FATAL|SKIPPED' "$out" | head -1)"; return 2; fi
  case "$gate" in
    verify)
      need="$(verify_says "$id")"
      if ! grep -qF -- "$need" "$out"; then WHY="exit 1, but never '$need': $(head -2 "$out" | tr '\n' ' ')"; return 2; fi
      WHY="exit 1, '$need'" ;;
    parity)
      if ! suite_line "$out" vendor-parity '[0-9]+' '[1-9][0-9]*'; then WHY="exit 1 without a 'vendor-parity: N passed, M failed' report"; return 2; fi
      if ! grep -qF 'verify --all on the real tree' "$out"; then WHY="red, but not at 'verify --all on the real tree': $(grep -F 'FAIL' "$out" | head -1)"; return 2; fi
      need="$(parity_names "$id")"
      if [ -n "$need" ]; then
        if ! grep -qF 'the tree, the lock and the recording disagree' "$out" || ! grep -qF -- "$need" "$out"; then
          WHY="red at verify --all, but its recording check did not name '$need'"; return 2
        fi
        WHY="exit 1 at verify --all and at the recording check, which names $need"
      else
        WHY="exit 1 at verify --all (the recording holds no hash of the lock)"
      fi ;;
    baseline)
      if ! suite_line "$out" split-baseline '[0-9]+' '[1-9][0-9]*'; then WHY="exit 1 without a 'split-baseline: N passed, M failed' report"; return 2; fi
      if ! grep -qF 'check: this tree is the recorded tree' "$out"; then WHY="red, but not at 'check: this tree is the recorded tree': $(grep -F 'FAIL' "$out" | head -1)"; return 2; fi
      WHY="exit 1 at 'check: this tree is the recorded tree'" ;;
    goldens)
      if ! grep -qF 'DRIFT rj_M_256' "$out" || [ "$(grep -c '^same ' "$out")" != 8 ]; then WHY="exit 1, but not exactly rj_M_256 drifting: $(tr '\n' ' ' < "$out")"; return 2; fi
      WHY="rj_M_256 drifts, the other eight goldens are what the renderer prints" ;;
  esac
  return 0
}

# effective <id>: the patched copy differs from the staged tree in the files the mutant names, as it says, and nowhere else; on success WHAT says how
effective() {
  local id="$1" b="$WORK/base" d="$WORK/copy-$1" delta="$WORK/res/$1/delta.txt" want rel dl expect
  want="$(touched_of "$id")"; WHAT=""
  case "$id" in
    M4) expect="$(printf '%s\n%s\n' "Only in $b/hooks: statusline.sh" "Only in $d/hooks: statusline-renamed.sh")" ;;
    *)  expect="Files $b/$want and $d/$want differ" ;;
  esac
  if [ "$(sort "$delta")" != "$(printf '%s\n' "$expect" | sort)" ]; then
    bad "$id: the patch changes more, or other, than it documents ($want): $(head -3 "$delta" | tr '\n' ' ')"; return 1
  fi
  case "$id" in
    M1|M2|M5)
      rel="$want"
      if [ "$(wc -c < "$b/$rel" | tr -d ' ')" != "$(wc -c < "$d/$rel" | tr -d ' ')" ] || [ "$(cmp -l "$b/$rel" "$d/$rel" | grep -c .)" != 1 ]; then
        bad "$id: $rel does not differ in exactly one byte at the same size"; return 1
      fi
      WHAT="one byte of $rel differs, the size is the same" ;;
    M3)
      dl="$(diff "$b/vendor/vendor.lock.json" "$d/vendor/vendor.lock.json")"
      if [ "$(grep -c '^<' <<<"$dl")" != 1 ] || [ "$(grep -c '^>' <<<"$dl")" != 0 ] || ! grep -qF '"hooks/statusline.sh",' <<<"$dl"; then
        bad "$id: the lock does not differ in exactly the one line naming hooks/statusline.sh: $dl"; return 1
      fi
      WHAT="the one line naming hooks/statusline.sh is gone from the lock, the file is still in the tree" ;;
    M4)
      if [ -e "$d/hooks/statusline.sh" ] || [ ! -x "$d/hooks/statusline-renamed.sh" ] || ! cmp -s "$b/hooks/statusline.sh" "$d/hooks/statusline-renamed.sh"; then
        bad "$id: hooks/statusline.sh is not renamed with its bytes and exec bit kept"; return 1
      fi
      WHAT="hooks/statusline.sh is gone from its path; its bytes and exec bit are at hooks/statusline-renamed.sh" ;;
  esac
  return 0
}

echo "== the mutants: every designated gate must go RED =="
KILLED=0
if [ "$GOLDEN_OK" != 1 ]; then
  echo "score void: the golden is not green, so a red gate proves nothing (every case below would be red for the golden's own reason)"
  bad "the golden is not green: no mutant was graded"
else
  for id in $MUTANTS; do
    killed=1; row=""
    echo "-- $id: $(patch_of "$id")"
    if [ "$(rc_of "$id" apply)" != 0 ]; then
      bad "$id: the patch does not apply to this tree ($(head -2 "$WORK/res/$id/apply.out" 2>/dev/null | tr '\n' ' ')): the pin moved? make the same edit in a copy and keep git diff"
      continue
    fi
    if ! effective "$id"; then continue; fi
    ok "$id applied: $WHAT"
    for gate in $(gates_of "$id"); do
      verdict "$id" "$gate"
      case $? in
        0) ok "$id $gate: RED -- $WHY"; row="$row $gate=RED" ;;
        1) bad "$id SURVIVED $gate: $WHY"; killed=0; row="$row $gate=GREEN" ;;
        *) bad "$id $gate: red, but not for the reason this mutant is built for: $WHY"; killed=0; row="$row $gate=red-elsewhere" ;;
      esac
    done
    echo "   $id:$row"
    [ "$killed" = 1 ] && KILLED=$((KILLED+1))
  done
  SCORE="$(awk -v k="$KILLED" -v t="$TOTAL" 'BEGIN { printf "%.1f", k / t }')"
  echo "mutants: $KILLED/$TOTAL killed, the golden green"
  echo "score $SCORE"
  [ "$SCORE" = "1.0" ] || bad "score $SCORE: a mutant survived or did not apply"
fi

echo "== the real tree was not written =="
TOUCHED=""
for id in $MUTANTS; do
  for rel in $(touched_of "$id"); do
    case "$id:$rel" in
      M4:hooks/statusline-renamed.sh) [ ! -e "$ROOT/$rel" ] || TOUCHED="$TOUCHED $rel" ;;
      *) cmp -s "$ROOT/$rel" "$WORK/base/$rel" || TOUCHED="$TOUCHED $rel" ;;
    esac
  done
done
if [ -z "$TOUCHED" ]; then ok "every file a mutant changes is, in the real tree, what it was when the copies were made"
else bad "the real tree differs from the staged copy in:$TOUCHED"; fi

echo
echo "elapsed: ${SECONDS}s"
echo "split-falsify: $pass passed, $fail failed"
[ "$fail" -eq 0 ] || exit 1
