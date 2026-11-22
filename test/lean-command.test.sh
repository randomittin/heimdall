#!/usr/bin/env bash
# lean-command.test.sh -- proves bin/heimdall-lean (T4.1 of the 3.x lean-core plan, docs/superpowers/plans/2026-11-12-3x-lean-core.md): `hmd lean status|on|off`,
# the one command that moves an install between the lean and the full profile and shows what the move costs, and (`restore DIR`) puts back the backup that
# `install.sh --reset` took first. Invariants (.planning/lean-core/INVARIANTS.md): INV-L6 (off restores the full tree, idempotent), INV-L9 (restore returns the
# backed-up files byte for byte, and a refused backup changes nothing), INV-L12 (lean keeps the claude wrapper and never touches Headroom), and INV-L3 / INV-L10
# for what a switch must leave alone. The command is a thin sequence over three tested helpers (bin/lib/hmd_profile.py, bin/lib/lean_sparse.sh, bin/heimdall-footprint), so this
# suite proves the sequence, the output and the failure behaviour, not the helpers again.
#
#   A. THE JOURNEY, every run inside a session routed through Headroom (ANTHROPIC_BASE_URL on its port, a shell rc that wraps `claude`, fake headroom / hmd / claude on
#      PATH): usage errors write nothing; `status` on a full clone reads and creates nothing; `off` on a clone that never was lean touches nothing; `on` narrows the
#      clone (test/, docs/, .planning/ and the on-demand skills go, every bin/ and hooks/ file stays), records `lean` and prints the footprint before and after,
#      exactly the five numbers bin/heimdall-footprint reports for the tree before and after; `status` then says lean; `off` brings the full tree back byte for byte
#      (INV-L6) and records `full`; a second `off` changes nothing; a profile that disagrees with the tree is said, with the command that settles it.
#   B. NOTHING ELSE MOVES (INV-L12, INV-L10): the shell rc, ~/.claude, and the untracked ledger / receipts / memory / team / data of the install are byte for byte what
#      they were after every switch, and none of headroom, hmd or claude was ever run.
#   C. FAILURE IS ATOMIC: a lean set that cannot be derived exits 1 and leaves the profile and the tree as they were; a profile.json that cannot be used stops `on`
#      BEFORE the tree is touched, while `off` still brings the full tree back (it is the way out) and then says the profile could not be recorded (exit 1).
#   D. THE MUTANTS: the command with one behaviour broken (the tree step, the way back, the profile record, the put-back after a failed apply, the table, a call to
#      `hmd headroom off`) goes RED on the check that guards that behaviour.
#   E. RESTORE (INV-L9): `restore DIR` of the backup a reset took first puts skills-config.json and the settings.json slice back byte for byte, drops the profile record
#      the backup did not have, brings the full tree back and removes the unfinished-reset record; the backup of a lean install gets its lean profile record AND its lean
#      tree back; a second restore changes nothing; a tampered backup, and a directory that is no backup, are refused (exit 1) with the tree, the profile, the files and the
#      record exactly as they were; four mutants of it (the helper skipped, the record kept, the refusal ignored, the tree not following the record) go RED.
#
# Hermetic: HOME, HEIMDALL_HOME and the git config are the test's own, the environment of every run is cleared (env -i), no network, nothing outside $T is read or
# written. HMD_LEAN_BIN points the suite at another copy of the command. bash 3.2 compatible.
#
# budget: 200 -- sections A-D measured 70 s with the machine under load (load average 22): 24 runs of the command, the dearest starting five python processes and a git
# sparse-checkout, one fixture clone per scenario and per mutant; section E adds about 20 runs of the command (each a footprint meter before and after, a backup helper,
# a git sparse-checkout) and one fixture per scenario and per mutant. Nothing in it waits on a clock: no sleep, no timing assertion.
#
# Usage:  bash test/lean-command.test.sh
# shellcheck disable=SC2016  # the rc line and the shim bodies are single-quoted on purpose: their $-words are for the shell that sources / runs them later
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SELF_DIR/.." && pwd)"
CLI="${HMD_LEAN_BIN:-$REPO/bin/heimdall-lean}"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; }
finish() { printf '\nlean-command: %s passed, %s failed\n' "$PASS" "$FAIL"; [ "$FAIL" -eq 0 ]; }

unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR GIT_PREFIX GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES HEIMDALL_HOME CLAUDE_PLUGIN_ROOT
T="$(mktemp -d "${TMPDIR:-/tmp}/lean-command.XXXXXX")" || exit 1; T="$(cd "$T" && pwd -P)"
cleanup() { chmod -R u+rwX "$T" 2>/dev/null; rm -rf "$T"; }
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null GIT_TERMINAL_PROMPT=0
export GIT_AUTHOR_NAME=lean-command-test GIT_AUTHOR_EMAIL=test@example.invalid GIT_COMMITTER_NAME=lean-command-test GIT_COMMITTER_EMAIL=test@example.invalid

echo "lean-command (bin/heimdall-lean: status, on, off, restore, the footprint before and after, atomic failure, mutants)"
if [ ! -f "$CLI" ]; then bad "bin/heimdall-lean is missing: $CLI"; finish; exit 1; fi

# ── the fixture: a tiny plugin laid out like this one, whose clone sits at ~/.heimdall the way install.sh puts it ──────────────────────────────────────────
BODY="$(printf -- '---\nname: n\ndescription: d\n---\n'; head -c 400 /dev/zero | tr '\0' x)"
put() { mkdir -p "$(dirname "$1/$2")"; printf '%s\n' "$BODY" > "$1/$2"; }      # put DIR PATH
mk_origin() {   # mk_origin DIR [nolist] -- the fixture repository, one commit; with `nolist` HEAD has no release/runtime-files.txt, so no lean set can be derived
  local o="$1" f
  mkdir -p "$o" && git -C "$o" init -q || return 1
  for f in LICENSE .mcp.json .claude-plugin/plugin.json agents/main.md commands/c.md hooks/guard.sh bin/heimdall skills/heimdall/SKILL.md \
           skills/stacks/SKILL.md skills/stacks/fastapi/PACK.md skills/designmatch/SKILL.md skills/self-improve/SKILL.md skills/system-health/SKILL.md \
           skills/mac-deep-clean/SKILL.md docs/guide.md .planning/STATE.md test/a.test.sh evals/other/x.json; do
    put "$o" "$f"
  done
  printf '{"agent": "main"}\n' > "$o/settings.json"
  printf '%s\n' '{"hooks": {"SessionStart": [{"hooks": [{"type": "command", "command": "true"}]}], "PreToolUse": [{"matcher": "Bash", "hooks": [{"type": "command", "command": "hooks/guard.sh"}, {"type": "command", "command": "true"}]}]}}' > "$o/hooks/hooks.json"
  mkdir -p "$o/bin/lib" "$o/release"
  cp "$CLI" "$o/bin/heimdall-lean"; cp "$REPO/bin/heimdall-footprint" "$o/bin/heimdall-footprint"
  cp "$REPO/bin/lib/hmd_profile.py" "$REPO/bin/lib/lean_sparse.sh" "$REPO/bin/lib/lean_backup.py" "$o/bin/lib/"
  chmod +x "$o/bin/heimdall" "$o/bin/heimdall-lean" "$o/bin/heimdall-footprint" "$o/hooks/guard.sh"
  if [ "${2:-}" != nolist ]; then
    printf '%s\n' bin/heimdall bin/heimdall-footprint bin/heimdall-lean bin/lib/hmd_profile.py bin/lib/lean_sparse.sh bin/lib/lean_backup.py hooks/guard.sh hooks/hooks.json \
      release/runtime-files.txt skills/heimdall/SKILL.md skills/stacks/SKILL.md skills/stacks/fastapi/PACK.md skills/designmatch/SKILL.md \
      skills/self-improve/SKILL.md skills/system-health/SKILL.md skills/mac-deep-clean/SKILL.md > "$o/release/runtime-files.txt"
  fi
  git -C "$o" add -A >/dev/null && git -C "$o" commit -q -m fixture
}
ORIGIN="$T/origin"; ORIGIN_NL="$T/origin-nolist"
if ! mk_origin "$ORIGIN" || ! mk_origin "$ORIGIN_NL" nolist; then bad "the fixture repositories could not be made"; finish; exit 1; fi

# fake headroom / hmd / claude: a call to any of them is logged to $T/shim.log (INV-L12: the command never makes one)
mkdir -p "$T/fakebin"
for n in headroom hmd claude; do
  cat > "$T/fakebin/$n" <<EOF
#!/bin/sh
echo "$n \$*" >> "$T/shim.log"
EOF
  chmod +x "$T/fakebin/$n"
done

new_install() {   # new_install NAME [ORIGIN] -- sets HOME_DIR HH CL: a sandbox HOME, ~/.heimdall a depth-1 clone, the operator's own state beside the tracked files
  HOME_DIR="$T/$1"; HH="$HOME_DIR/.heimdall"; CL="$HH"
  mkdir -p "$HOME_DIR"
  if ! git clone -q --depth 1 "file://${2:-$ORIGIN}" "$CL" 2> "$T/clone.err"; then bad "the fixture clone $1 could not be made: $(head -c 200 "$T/clone.err")"; finish; exit 1; fi
  mkdir -p "$HH/ledger" "$HH/receipts" "$HH/memory" "$HH/data" "$HOME_DIR/.claude"
  printf 'row 1\n' > "$HH/ledger/l.ndjson"; printf '{"ok": true}\n' > "$HH/receipts/r.json"; printf 'a memory\n' > "$HH/memory/m.md"
  printf 'team secret\n' > "$HH/team.json"; printf 'blob\n' > "$HH/data/d.bin"
  printf 'claude() { hmd route claude "$@"; }\n' > "$HOME_DIR/.zshrc"
  printf '{"env": {"ANTHROPIC_BASE_URL": "http://127.0.0.1:8787"}}\n' > "$HOME_DIR/.claude/settings.json"
}

RC=0
lean() {   # lean ARGS... -- bin/heimdall-lean of the current install, inside a session routed through Headroom: stdout $T/out, stderr $T/err, status RC
  env -i HOME="$HOME_DIR" HEIMDALL_HOME="$HH" PATH="$T/fakebin:$PATH" LC_ALL=C GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null GIT_TERMINAL_PROMPT=0 \
    ANTHROPIC_BASE_URL=http://127.0.0.1:8787 HEADROOM_PORT=8787 HTTPS_PROXY=http://127.0.0.1:8787 "$CL/bin/heimdall-lean" "$@" > "$T/out" 2> "$T/err"; RC=$?
}

# ── helpers: independent of the command under test (the real profile library, the real meter, git, find) ─────────────────────────────────────────────────
show_run()    { printf 'rc=%s out=[%s] err=[%s]' "$RC" "$(head -c 300 "$T/out" | tr '\n' '|')" "$(head -c 300 "$T/err" | tr '\n' '|')"; }
profile_get() { HEIMDALL_HOME="$HH" python3 -I "$REPO/bin/lib/hmd_profile.py" get 2>/dev/null; }
ondisk()      { ( cd "$1" && find . -path ./.git -prune -o \( -type f -o -type l \) -print | sed 's|^\./||' | LC_ALL=C sort ); }
treehash()    { ( cd "$1" && find . -path ./.git -prune -o -name profile.json -prune -o \( -type f -o -type l \) -print | LC_ALL=C sort | xargs shasum -a 256 | shasum -a 256 | cut -c1-64 ); }
hash_of()     { ( cd "$1" && shift && find "$@" \( -type f -o -type l \) -print | LC_ALL=C sort | xargs shasum -a 256 | shasum -a 256 | cut -c1-64 ); }   # hash_of DIR PATH...
sq_has()      { tr -s ' ' < "$T/out" | grep -qxF -- "$1"; }          # a line of stdout, runs of spaces squeezed to one
tracked_clean() { [ -z "$(git -C "$1" status --porcelain --untracked-files=no)" ]; }
is_full() {   # every tracked path is on disk, none skipped, git sees no change
  git -C "$1" -c core.quotepath=false ls-files | LC_ALL=C sort > "$T/tracked"; ondisk "$1" > "$T/disk"
  [ -z "$(LC_ALL=C comm -23 "$T/tracked" "$T/disk")" ] && [ "$(git -C "$1" ls-files -v | grep -c '^[Ss]')" = 0 ] && tracked_clean "$1"
}
is_lean() {   # a sparse checkout is on, nothing that only a test or a doc needs is on disk, everything that runs is, git sees no change
  local p
  [ "$(git -C "$1" config --bool --get core.sparseCheckout 2>/dev/null)" = true ] || return 1
  for p in test docs .planning evals skills/stacks skills/designmatch skills/self-improve skills/system-health skills/mac-deep-clean; do [ ! -e "$1/$p" ] || return 1; done
  git -C "$1" ls-files -- bin hooks agents commands .claude-plugin skills/heimdall settings.json .mcp.json LICENSE release/runtime-files.txt > "$T/must"
  [ -s "$T/must" ] || return 1
  while IFS= read -r p; do [ -f "$1/$p" ] || return 1; done < "$T/must"
  tracked_clean "$1"
}
fpnums() {   # fpnums CLONE -- "disk bytes, disk files, session start bytes, session start tokens, hooks" as bin/heimdall-footprint of THIS repository reports them
  python3 -I "$REPO/bin/heimdall-footprint" --root "$1" --json | python3 -I -c '
import json, sys
d = json.load(sys.stdin)
print(d["disk"]["total_bytes"], d["disk"]["total_files"], d["context"]["session_start_bytes"], d["context"]["session_start_tokens_est"], d["hooks_total"])'
}
expect_table() {   # expect_table "<fpnums before>" "<fpnums after>" -- the printed table is the meter's five numbers before and after, and their differences
  python3 -I -c '
import sys
labels = ("disk bytes", "disk files", "session start bytes", "session start tokens", "hooks registered")
for label, a, b in zip(labels, sys.argv[1].split(), sys.argv[2].split()):
    d = int(b) - int(a)
    print(" %s %s %s %s" % (label, format(int(a), ","), format(int(b), ","), format(d, "+,") if d else "0"))' "$1" "$2" > "$T/want.rows"
  [ "$(tr -s ' ' < "$T/out" | grep -cxFf "$T/want.rows")" = 5 ] && sq_has " before after change"
}
expect_status() {   # expect_status "<fpnums>" -- status carries the meter's disk, session-start and hook numbers for the tree
  python3 -I -c '
import sys
b, f, sb, st, h = (int(x) for x in sys.argv[1].split())
print("disk %s B in %s files" % (format(b, ","), format(f, ",")))
print("session %s B at session start (~%s tokens, an estimate)" % (format(sb, ","), format(st, ",")))
print("hooks %d registered" % h)' "$1" > "$T/want.status"
  [ "$(tr -s ' ' < "$T/out" | grep -cxFf "$T/want.status")" = 3 ]
}
no_shim_calls() { [ ! -s "$T/shim.log" ]; }

echo "-- A. the journey, inside a session routed through Headroom --"
new_install a
FRESH="$(treehash "$CL")"; CFG0="$(cat "$CL/.git/config")"
DATA0="$(hash_of "$HH" ledger receipts memory data team.json)"; OUT0="$(hash_of "$HOME_DIR" .zshrc .claude)"
FP0="$(fpnums "$CL")"
if [ "$(printf '%s\n' "$FP0" | wc -w | tr -d ' ')" != 5 ]; then bad "A: the meter did not report the fixture: [$FP0]"; finish; exit 1; fi
read -r B0 F0 SB0 _ H0 <<< "$FP0"

for args in "" "bogus" "on now" "status -v" "--frobnicate" "restore" "restore a b"; do
  # shellcheck disable=SC2086  # the word list is the point
  lean $args
  if [ "$RC" = 2 ] && [ ! -s "$T/out" ] && grep -q '^usage:' "$T/err"; then ok "A: usage error [$args] exits 2, usage line on stderr, nothing on stdout"; else bad "A: usage error [$args]: $(show_run)"; fi
done
lean --help
if [ "$RC" = 0 ] && grep -q 'heimdall-lean status' "$T/out" && grep -q 'heimdall-lean on' "$T/out" && grep -q 'heimdall-lean off' "$T/out" && grep -q 'heimdall-lean restore DIR' "$T/out"; then ok "A: --help prints the four commands, exit 0"; else bad "A: --help: $(show_run)"; fi
if [ ! -e "$HH/profile.json" ] && [ "$(treehash "$CL")" = "$FRESH" ]; then ok "A: usage errors and --help wrote nothing"; else bad "A: a usage error or --help changed the install"; fi

lean status
if [ "$RC" = 0 ] && sq_has "profile full" && sq_has "tree full" && expect_status "$FP0"; then ok "A: status on a full clone: profile full (the default), tree full, the meter's numbers"; else bad "A: status on a full clone: $(show_run)"; fi
if [ ! -e "$HH/profile.json" ] && [ "$(treehash "$CL")" = "$FRESH" ]; then ok "A: status creates and changes nothing (no profile.json)"; else bad "A: status wrote something"; fi

lean off
if [ "$RC" = 0 ] && [ "$(treehash "$CL")" = "$FRESH" ] && [ "$(cat "$CL/.git/config")" = "$CFG0" ] && is_full "$CL" && [ "$(profile_get)" = full ] && expect_table "$FP0" "$FP0"; then
  ok "A: off on a clone that never was lean touches no tracked file and not .git/config, records full, prints an all-zero table"
else bad "A: off on a never-lean clone: $(show_run)"; fi

lean on
FP1="$(fpnums "$CL")"; read -r B1 F1 SB1 _ H1 <<< "$FP1"
if [ "$RC" = 0 ] && is_lean "$CL" && [ "$(profile_get)" = lean ] && grep -q '^heimdall-lean: lean is on' "$T/out"; then ok "A: on narrows the clone to what runs (no test/, docs/, .planning/, on-demand skills; every bin/ and hooks/ file stays) and records lean"; else bad "A: on: $(show_run)"; fi
if expect_table "$FP0" "$FP1"; then ok "A: on prints the footprint before and after: the meter's own numbers for the tree before and after, and the differences"; else bad "A: the table is not the meter's numbers (before [$FP0] after [$FP1]): $(show_run)"; fi
if [ "${B1:-0}" -lt "$B0" ] && [ "${F1:-0}" -lt "$F0" ] && [ "${SB1:-0}" -lt "$SB0" ] && [ "${H1:-x}" = "$H0" ]; then ok "A: the saving is real: fewer bytes, fewer files, a smaller session start ($SB0 -> $SB1 B), the same $H0 hooks"; else bad "A: the footprint did not shrink as expected: [$FP0] -> [$FP1]"; fi

lean status
if [ "$RC" = 0 ] && sq_has "profile lean" && tr -s ' ' < "$T/out" | grep -q '^tree lean (sparse checkout' && expect_status "$FP1"; then ok "A: status after on: profile lean, tree lean (sparse checkout), the numbers of the narrowed tree"; else bad "A: status after on: $(show_run)"; fi

lean off
FP2="$(fpnums "$CL")"
if [ "$RC" = 0 ] && is_full "$CL" && [ "$(treehash "$CL")" = "$FRESH" ] && [ "$(profile_get)" = full ] && [ "$FP2" = "$FP0" ] && expect_table "$FP1" "$FP2" && grep -q '^heimdall-lean: the full tree is back' "$T/out"; then
  ok "A: INV-L6: off brings back every tracked file byte for byte what a fresh clone has, none skipped, records full, and the meter is back to its first numbers"
else bad "A: off after on: $(show_run)"; fi
lean off
if [ "$RC" = 0 ] && is_full "$CL" && [ "$(treehash "$CL")" = "$FRESH" ] && [ "$(profile_get)" = full ] && expect_table "$FP2" "$FP2"; then ok "A: INV-L6: a second off is a no-op that still exits 0 (idempotent), table all zero"; else bad "A: the second off: $(show_run)"; fi

HEIMDALL_HOME="$HH" python3 -I "$REPO/bin/lib/hmd_profile.py" set lean
lean status
if [ "$RC" = 0 ] && sq_has "profile lean" && sq_has "tree full" && grep -q 'profile says lean but the tree is full' "$T/out" && grep -q 'hmd lean on' "$T/out"; then ok "A: a profile that disagrees with the tree is said, with the command that settles it"; else bad "A: the disagreement note: $(show_run)"; fi

echo "-- B. nothing else moves (INV-L12, INV-L10) --"
if [ "$(hash_of "$HH" ledger receipts memory data team.json)" = "$DATA0" ]; then ok "B: the ledger, receipts, memory, team and data files are byte for byte what they were after every switch"; else bad "B: user data changed"; fi
if [ "$(hash_of "$HOME_DIR" .zshrc .claude)" = "$OUT0" ]; then ok "B: the shell rc (the claude wrapper) and ~/.claude/settings.json (the Headroom route) are byte for byte what they were"; else bad "B: the rc or the claude settings changed"; fi
if no_shim_calls; then ok "B: headroom, hmd and claude were never run: lean routes nothing and turns nothing off"; else bad "B: a route tool was run: $(head -c 200 "$T/shim.log" | tr '\n' '|')"; fi

echo "-- C. failure is atomic --"
new_install nl "$ORIGIN_NL"
lean on
if [ "$RC" = 1 ] && grep -q 'runtime-files.txt' "$T/err" && [ "$(profile_get)" = full ] && is_full "$CL"; then ok "C: a lean set that cannot be derived: exit 1, the helper's reason on stderr, profile still full, tree untouched"; else bad "C: on with no runtime list: $(show_run) profile=$(profile_get)"; fi
new_install bad1
printf 'not json\n' > "$HH/profile.json"
lean on
if [ "$RC" = 1 ] && grep -q 'profile.json' "$T/err" && is_full "$CL" && [ "$(cat "$HH/profile.json")" = "not json" ]; then ok "C: a profile.json that cannot be used stops on before the tree is touched, and the file is left alone"; else bad "C: on with a corrupt profile.json: $(show_run)"; fi
new_install bad2
lean on
printf 'not json\n' > "$HH/profile.json"
lean off
if [ "$RC" = 1 ] && is_full "$CL" && grep -q 'profile.json' "$T/err" && grep -q '^heimdall-lean: the full tree is back' "$T/out" && [ "$(cat "$HH/profile.json")" = "not json" ]; then ok "C: off is the way out: with a corrupt profile.json the full tree still comes back, exit 1 says the profile could not be recorded"; else bad "C: off with a corrupt profile.json: $(show_run)"; fi

echo "-- D. the mutants: one behaviour broken, its check goes RED --"
mutant() {   # mutant NAME OLD NEW -- $T/NAME.py: the command with the one line OLD (exactly one occurrence) replaced by NEW
  python3 -I - "$CLI" "$T/$1.py" "$2" "$3" <<'PY' || { bad "D: mutant $1 did not apply (its anchor moved or is not unique)"; return 1; }
import sys
src, dst, old, new = sys.argv[1:]
text = open(src, encoding="utf-8").read()
if text.count(old) != 1:
    sys.exit(1)
with open(dst, "w", encoding="utf-8") as handle:
    handle.write(text.replace(old, new))
PY
}
mutant_install() {   # mutant_install NAME [ORIGIN] -- a fresh install whose command is the mutant
  new_install "$1" "${2:-$ORIGIN}"; cp "$T/$1.py" "$CL/bin/heimdall-lean"; chmod +x "$CL/bin/heimdall-lean"
}
if mutant m1 '    return helper(["bash", SPARSE_LIB, "apply", value, ROOT])[0] == 0' '    return True'; then
  mutant_install m1; lean on
  if [ "$RC" = 0 ] && ! is_lean "$CL"; then ok "D: an on that never touches the tree leaves it full: the lean-tree check goes RED"; else bad "D: the tree-step mutant was not caught ($(show_run))"; fi
fi
if mutant m2 '"apply", value, ROOT' '"apply", "lean", ROOT'; then
  mutant_install m2; lean on; lean off
  if ! is_full "$CL"; then ok "D: an off that applies lean again leaves the tree sparse: the INV-L6 full-tree check goes RED"; else bad "D: the way-back mutant was not caught"; fi
fi
if mutant m3 '    return helper([sys.executable, "-I", PROFILE_LIB, "set", value])[0] == 0' '    return True'; then
  mutant_install m3; lean on
  if [ "$(profile_get)" != lean ]; then ok "D: an on that never records the profile leaves it full: the recorded-profile check goes RED"; else bad "D: the profile mutant was not caught"; fi
fi
if mutant m4 '        restored = previous is not None and record_profile(previous)' '        restored = True'; then
  mutant_install m4 "$ORIGIN_NL"; lean on
  if [ "$(profile_get)" = lean ]; then ok "D: without the put-back a failed on leaves profile lean over a full tree: the atomicity check goes RED"; else bad "D: the put-back mutant was not caught"; fi
fi
if mutant m5 '    after = footprint()' '    after = before'; then
  mutant_install m5; lean on; FPM="$(fpnums "$CL")"
  if ! expect_table "$FP0" "$FPM"; then ok "D: a table whose after column is the before column: the meter-numbers check goes RED"; else bad "D: the table mutant was not caught"; fi
fi
if mutant m6 '    previous = recorded_profile()' '    previous = recorded_profile(); subprocess.run(["hmd", "headroom", "off", "--next-session"])'; then
  rm -f "$T/shim.log"; mutant_install m6; lean on
  if ! no_shim_calls; then ok "D: an on that calls hmd headroom off is seen in the shim log: the INV-L12 check goes RED"; else bad "D: the headroom mutant was not caught"; fi
fi

echo "-- E. restore: hmd lean restore DIR undoes install.sh --reset (INV-L9) --"
CFG_PRE='{"consent":"auto","grandfathered":true}'    # skills-config.json before the reset
CFG_POST='{"consent":"ask","grandfathered":false}'   # ...and as the reset leaves it
SET_PRE=$'{\n  "env": {\n    "ANTHROPIC_BASE_URL": "http://127.0.0.1:8787"\n  },\n  "theme": "dark"\n}\n'      # the user settings before: the Headroom route, in a file with an indent
SET_POST=$'{\n  "env": {},\n  "theme": "dark",\n  "agent": "hmd:heimdall-lean"\n}\n'                          # ...and after: the route switched off, the lean prompt selected
printf '%s' "$SET_PRE" > "$T/settings.pre"; printf '%s' "$SET_POST" > "$T/settings.post"
rm -f "$T/shim.log"

backup_now() {   # the backup install.sh --reset takes first, by the real helper as it calls it: prints the backup dir
  env -i HOME="$HOME_DIR" HEIMDALL_HOME="$HH" PATH="$PATH" python3 -I "$CL/bin/lib/lean_backup.py" backup
}
light_fixture() {   # light_fixture NAME [MUTANT] -- an install as it was before a reset, its backup (BK), then what a reset leaves in the files and the record (the tree stays full)
  new_install "$1"
  [ -z "${2:-}" ] || cp "$T/$2.py" "$CL/bin/heimdall-lean"
  printf '%s' "$SET_PRE" > "$HOME_DIR/.claude/settings.json"; printf '%s\n' "$CFG_PRE" > "$HH/skills-config.json"
  DATA_R="$(hash_of "$HH" ledger receipts memory data team.json)"
  BK="$(backup_now)"
  if [ ! -f "$BK/manifest.json" ]; then bad "E: the backup of $1 could not be taken"; finish; exit 1; fi
  BASE_R="$(treehash "$CL")"
  printf '%s\n' "$CFG_POST" > "$HH/skills-config.json"; printf '%s' "$SET_POST" > "$HOME_DIR/.claude/settings.json"
  printf 'backup=%s\npending=lean-tree\n' "$BK" > "$HH/backups/lean-reset-pending"
}
reset_fixture() {   # reset_fixture NAME -- light_fixture plus the lean tree and the lean profile record the reset made (this very command's `on`: install.sh --reset runs the same helpers)
  light_fixture "$1"
  lean on
  if [ "$RC" != 0 ] || ! is_lean "$CL"; then bad "E: the lean tree of $1 could not be made: $(show_run)"; finish; exit 1; fi
}
lean_record_case() {   # lean_record_case NAME [MUTANT] -- a LEAN install is backed up (its backup holds a lean profile record), switched off, then restored from that backup
  new_install "$1"
  [ -z "${2:-}" ] || cp "$T/$2.py" "$CL/bin/heimdall-lean"
  printf '%s' "$SET_PRE" > "$HOME_DIR/.claude/settings.json"; printf '%s\n' "$CFG_PRE" > "$HH/skills-config.json"
  lean on
  BK="$(backup_now)"; cp "$HH/profile.json" "$T/profile.lean"
  lean off
  lean restore "$BK"
}
cfg_restored() { [ "$(cat "$HH/skills-config.json")" = "$CFG_PRE" ]; }
lean_tree_on() { [ "$(git -C "$CL" config --bool --get core.sparseCheckout 2>/dev/null)" = true ]; }

reset_fixture r1
FPL="$(fpnums "$CL")"
lean restore "$BK"
FPF="$(fpnums "$CL")"
if [ "$RC" = 0 ] && cfg_restored && cmp -s "$T/settings.pre" "$HOME_DIR/.claude/settings.json"; then ok "E: restore puts skills-config.json and the settings.json slice back byte for byte (the agent key goes, the route comes back)"; else bad "E: restore: $(show_run)"; fi
if [ ! -e "$HH/profile.json" ] && [ "$(profile_get)" = full ]; then ok "E: the profile record the backup did not have is gone: the install reads full again"; else bad "E: profile.json is still there after the restore of a pre-lean backup"; fi
if is_full "$CL" && [ "$(treehash "$CL")" = "$BASE_R" ]; then ok "E: the full tree is back and everything under the install is byte for byte what it was before the reset"; else bad "E: the tree after the restore is not the pre-reset tree"; fi
if [ ! -e "$HH/backups/lean-reset-pending" ] && [ -f "$BK/manifest.json" ]; then ok "E: the unfinished-reset record is removed and the backup itself is kept"; else bad "E: the record or the backup: $(ls "$HH/backups" | tr '\n' ' ')"; fi
if grep -q '^heimdall-lean: restored from .*: profile full, tree full' "$T/out" && expect_table "$FPL" "$FPF"; then ok "E: restore says what it did and prints the footprint before and after: the meter's own numbers"; else bad "E: the restore output: $(show_run)"; fi
if [ "$(hash_of "$HH" ledger receipts memory data team.json)" = "$DATA_R" ] && [ "$(cat "$HOME_DIR/.zshrc")" = 'claude() { hmd route claude "$@"; }' ] && no_shim_calls; then ok "E: INV-L10 and INV-L12: user data and the shell rc are untouched, and headroom, hmd and claude were never run"; else bad "E: restore moved user data or the rc, or ran a route tool"; fi
lean restore "$BK"
if [ "$RC" = 0 ] && grep -q 'restored 0, removed 0' "$T/out" && cfg_restored && [ "$(treehash "$CL")" = "$BASE_R" ]; then ok "E: a second restore of the same backup changes nothing and still exits 0"; else bad "E: the second restore: $(show_run)"; fi

lean_record_case r2
if [ "$RC" = 0 ] && cmp -s "$T/profile.lean" "$HH/profile.json" && [ "$(profile_get)" = lean ] && is_lean "$CL" && grep -q '^heimdall-lean: restored from .*: profile lean, tree lean' "$T/out"; then
  ok "E: the backup of a lean install brings back its lean profile record byte for byte AND its lean tree: the tree follows the restored record"
else bad "E: the restore of a lean backup: $(show_run) profile=$(profile_get)"; fi

reset_fixture r3
printf 'x' >> "$BK/files/000"
lean restore "$BK"
if [ "$RC" = 1 ] && grep -q 'tampered or damaged' "$T/err" && grep -q 'was not restored' "$T/err" && ! grep -q 'restored from' "$T/out"; then ok "E: a tampered backup is refused: exit 1, the reason and 'was not restored' on stderr, nothing reported as done"; else bad "E: the tampered backup: $(show_run)"; fi
if is_lean "$CL" && [ "$(profile_get)" = lean ] && [ "$(cat "$HH/skills-config.json")" = "$CFG_POST" ] && cmp -s "$T/settings.post" "$HOME_DIR/.claude/settings.json" && [ -f "$HH/backups/lean-reset-pending" ]; then
  ok "E: ...and nothing changed: the lean tree, the lean profile, skills-config.json, settings.json and the unfinished-reset record are as the reset left them"
else bad "E: a refused restore changed something"; fi
lean restore "$T/not-a-backup"
if [ "$RC" = 1 ] && grep -q 'not a backup directory' "$T/err" && is_lean "$CL" && [ -f "$HH/backups/lean-reset-pending" ] && no_shim_calls; then ok "E: a directory that is no backup is refused the same way and the tree stays lean"; else bad "E: a directory that is no backup: $(show_run)"; fi

if mutant mr1 '    status, _ = helper([sys.executable, "-I", BACKUP_LIB, "restore", directory])' '    status = 0'; then
  light_fixture mr1 mr1; lean restore "$BK"
  if ! cfg_restored; then ok "E: a restore that never runs the backup helper leaves skills-config.json as the reset made it: the byte-for-byte check goes RED"; else bad "E: the helper-skipped mutant was not caught"; fi
fi
if mutant mr2 '    dropped = drop_pending_record()' '    dropped = True'; then
  light_fixture mr2 mr2; lean restore "$BK"
  if [ -e "$HH/backups/lean-reset-pending" ]; then ok "E: a restore that keeps the unfinished-reset record leaves it on disk: the record check goes RED"; else bad "E: the record mutant was not caught"; fi
fi
if mutant mr3 '    if status != 0:' '    if status < 0:'; then
  light_fixture mr3 mr3; printf 'x' >> "$BK/files/000"; lean restore "$BK"
  if [ "$RC" = 0 ] && [ ! -e "$HH/backups/lean-reset-pending" ]; then ok "E: a restore that ignores the helper's refusal exits 0 and drops the record over a tampered backup: the refusal check goes RED"; else bad "E: the refusal mutant was not caught: $(show_run)"; fi
fi
if mutant mr4 '    if not apply_tree(profile):' '    if not apply_tree("full"):'; then
  lean_record_case mr4 mr4
  if ! lean_tree_on; then ok "E: a restore that always applies the full tree loses the lean tree of a lean backup: the tree-follows-the-record check goes RED"; else bad "E: the tree-step mutant was not caught"; fi
fi

finish
