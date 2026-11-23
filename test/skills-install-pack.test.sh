#!/usr/bin/env bash
# test/skills-install-pack.test.sh -- bin/lib/skills_cli_install.py: `hmd skills install ID` for a BUNDLED entry that a lean tree leaves out
# (3.x lean-core plan, task T3.2: docs/superpowers/plans/2026-11-12-3x-lean-core.md; invariants: .planning/lean-core/INVARIANTS.md, INV-L1 and INV-L4).
#
# A lean install is the plugin clone narrowed by a sparse checkout (bin/lib/lean_sparse.sh). For a bundled skill the manifest names the tree paths that bring it
# back: `on_demand_paths`, and `pack.paths` for a pack (rules SM12 and SM13 of bin/lib/skills_manifest.py). `install ID` for such an entry asks the SAME consent gate
# as every install, then runs `lean_sparse.sh add PATH` for each path (from the objects the clone already holds: no network) and writes ONE machine-lock row.
#
# THE CONTRACT UNDER TEST
#   A  consent: no terminal and no --yes is exit 3 (consent required) with nothing put back, no machine row and the gate's `suggested` project row; "Never ask
#      again" is exit 4 and a declined row; "Install now" goes on
#   B  a pack entry (stacks): --yes puts its directory back and nothing else, with every git transport refused and no `claude` call; ONE machine-lock row:
#      installed, bundled, the pack's version, the pack's FULL sha256 as content_hash (the pin bin/lib/skills_packs.py reads), consent yes-flag, why.via
#      hmd-skills-install, why.rule explicit; the clone records the path for its next re-apply; a second install is "already installed" and runs nothing
#   C  an on_demand_paths entry (designmatch): a directory AND a file come back, in order, behind ONE row that has no content hash (it has no pack)
#   D  failures: a path HEAD does not track is exit 1 with the script's reason on stderr and a `failed` machine row (a path put back before it stays); a plugin
#      directory that is not a clone is exit 1 the same way; neither ever leaves an `installed` row
#   E  a full tree: exit 0, the row is written and the tree and .git/config are byte for byte what they were (INV-L1)
#   F  unchanged: a bundled entry that names no path is refused (exit 2), so is an install:false plugin
#   H  the suite can go RED: one-line breaks of a copy of the module, each caught by the check that guards it
#
# The manifest is the test's own: the real one with `pack` and `on_demand_paths` set on five bundled entries (the real values are another task's), so nothing here
# depends on them. It is committed INTO the fixture repository: the lean cut is read from the manifest at HEAD (bin/lib/lean_sparse.sh refuses a clone whose HEAD has
# none), and the fixture's runtime list names it so it stays on disk, where the CLI looks. HERMETIC: HOME, HEIMDALL_HOME, the project and the plugin clone are throwaway
# directories; the clone is a depth-1 clone of a fixture repository
# whose origin URL is unreachable, and every CLI call runs with every git transport refused and git's own trace on (the method of test/lean-sparse.test.sh), so a
# network use is a failure. `claude` is a PATH fake that logs its calls: none is expected. Nothing outside $TMP is touched. EXIT: 0 = every assertion passes; 1 = any FAIL.
# shellcheck disable=SC2016,SC2086  # single quotes hold literal python for the child process; the NAME=value and file lists are split on purpose
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIBDIR="$REPO/bin/lib"
LOCKPY="$LIBDIR/skills_lock.py"
LIBS="skills_cli_install.py hmd_profile.py skills_config.py skills_lock.py skills_manifest.py skills_resolver.py skills_consent.sh select.sh install-receipt.sh lean_sparse.sh"

PASS=0
FAIL=0
ok()   { PASS=$((PASS + 1)); printf '  \033[32mPASS\033[0m %s\n' "$1"; }
bad()  { FAIL=$((FAIL + 1)); printf '  \033[31mFAIL\033[0m %s\n' "$1"; if [ -n "${2:-}" ]; then printf '       %s\n' "$2"; fi; }
eq()   { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected [$2], got [$3]"; fi; }
has()  { if grep -qF -- "$3" <<<"$2"; then ok "$1"; else bad "$1" "[$3] is not in [$2]"; fi; }
finish() { echo; echo "skills-install-pack: $PASS passed, $FAIL failed"; [ "$FAIL" -eq 0 ] && [ "$PASS" -gt 0 ]; }

echo "skills-install-pack"

command -v python3 >/dev/null 2>&1 || { echo "FATAL: python3 is required"; exit 1; }
command -v git >/dev/null 2>&1 || { echo "FATAL: git is required"; exit 1; }
for f in $LIBS; do
  if [ ! -f "$LIBDIR/$f" ]; then
    bad "0. bin/lib/$f is missing"
    finish
    exit 1
  fi
done

# ── sandbox ──────────────────────────────────────────────────────────────────────────────────────────────────────
TMP="$(mktemp -d "${TMPDIR:-/tmp}/test-skills-install-pack-XXXXXX")" || exit 1
TMP="$(cd "$TMP" && pwd -P)"
trap 'chmod -R u+rwx "$TMP" 2>/dev/null; rm -rf "$TMP"' EXIT
# The REAL interpreter first on PATH: a version-manager shim costs ~0.4 s a call and the gate starts python several times.
REALPY="$(python3 -I -c 'import sys; print(sys.executable)' 2>/dev/null)"
[ -x "${REALPY:-}" ] || { echo "FATAL: no usable python3"; exit 1; }
mkdir -p "$TMP/pybin" "$TMP/fakebin"
ln -s "$REALPY" "$TMP/pybin/python3"
PATH="$TMP/pybin:$PATH"; export PATH
GPATH="$TMP/pybin:$TMP/fakebin:/usr/bin:/bin:/usr/sbin:/sbin"
CALLS="$TMP/calls.log"; : > "$CALLS"
TRACE="$TMP/trace.json"

# The fake `claude`: logs every call. A put-back must never reach it.
cat > "$TMP/fakebin/claude" <<'EOF'
#!/bin/sh
echo "claude $*" >> "$FAKE_CALLS"
exit 0
EOF
chmod +x "$TMP/fakebin/claude"

# git for the fixture: the test's own identity and config, nothing of the machine's.
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null GIT_TERMINAL_PROMPT=0
export GIT_AUTHOR_NAME=skills-install-pack-test GIT_AUTHOR_EMAIL=test@example.invalid GIT_COMMITTER_NAME=skills-install-pack-test GIT_COMMITTER_EMAIL=test@example.invalid
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR GIT_PREFIX GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES

# ── the fixture: a tiny plugin laid out like this one ────────────────────────────────────────────────────────────
put() { mkdir -p "$(dirname "$1/$2")"; printf 'content of %s\n' "$2" > "$1/$2"; }   # put DIR PATH
mk_origin() {   # mk_origin DIR -- the fixture repository, one commit: the fixture manifest (the lean cut is read from HEAD's), a runtime list that names it and the on-demand skills (the cut drops those), docs/ and test/ outside it
  local o="$1" f
  mkdir -p "$o" && git -C "$o" init -q || return 1
  for f in .claude-plugin/plugin.json .mcp.json settings.json LICENSE agents/a.md commands/c.md hooks/hooks.json bin/tool skills/heimdall/SKILL.md \
           skills/stacks/SKILL.md skills/stacks/fastapi/PACK.md skills/designmatch/SKILL.md skills/system-health/SKILL.md docs/guide.md test/run.test.sh; do
    put "$o" "$f"
  done
  cp "$FIXTURE_MANIFEST" "$o/skills.manifest.json" || return 1
  mkdir -p "$o/release"
  printf '%s\n' bin/tool release/runtime-files.txt skills.manifest.json skills/heimdall/SKILL.md skills/stacks/SKILL.md skills/stacks/fastapi/PACK.md \
    skills/designmatch/SKILL.md skills/system-health/SKILL.md > "$o/release/runtime-files.txt"
  git -C "$o" add -A >/dev/null && git -C "$o" commit -q -m fixture
}
# what a lean tree of the fixture holds: the list minus the on-demand skills, plus the convention-loaded core
LEAN_FILES=".claude-plugin/plugin.json .mcp.json LICENSE agents/a.md bin/tool commands/c.md hooks/hooks.json release/runtime-files.txt settings.json skills.manifest.json skills/heimdall/SKILL.md"
STACKS_FILES="skills/stacks/SKILL.md skills/stacks/fastapi/PACK.md"
PACK_SHA="$(python3 -I -c 'import hashlib; print(hashlib.sha256(b"fixture stacks pack").hexdigest())')"

# The fixture manifest, built and validated BEFORE the repository: mk_origin commits it. bin/lib/lean_sparse.sh takes the lean cut from the manifest at HEAD and refuses a clone whose HEAD has none.
FIXTURE_MANIFEST="$TMP/fixture.skills.manifest.json"
python3 -I -c 'import json, sys
doc = json.load(open(sys.argv[1]))
by_id = {entry["id"]: entry for entry in doc["entries"]}
for ident in ("stacks", "designmatch", "system-health", "mac-deep-clean", "heimdall"):
    by_id[ident].pop("pack", None)
    by_id[ident].pop("on_demand_paths", None)
by_id["stacks"]["pack"] = {"name": "@runhmd/stacks", "version": "1.0.0", "sha256": sys.argv[3], "paths": ["skills/stacks"]}
by_id["designmatch"]["on_demand_paths"] = ["skills/designmatch", "docs/guide.md"]
by_id["system-health"]["on_demand_paths"] = ["skills/system-health"]
by_id["mac-deep-clean"]["on_demand_paths"] = ["skills/system-health", "skills/mac-deep-clean"]
json.dump(doc, open(sys.argv[2], "w"), indent=2)' "$REPO/skills.manifest.json" "$FIXTURE_MANIFEST" "$PACK_SHA" \
  || { echo "FATAL: cannot build the fixture manifest"; exit 1; }
python3 -I "$LIBDIR/skills_manifest.py" validate "$FIXTURE_MANIFEST" > /dev/null 2> "$TMP/validate.err" \
  || { echo "FATAL: the fixture manifest is not valid: $(head -c 300 "$TMP/validate.err")"; exit 1; }

ORIGIN="$TMP/origin"; BASE="$TMP/base"
if ! { mk_origin "$ORIGIN" && git clone -q --depth 1 "file://$ORIGIN" "$BASE" 2> "$TMP/clone.err"; }; then
  echo "FATAL: the fixture clone could not be made: $(head -c 300 "$TMP/clone.err")"
  exit 1
fi
# The libraries sit in the clone UNTRACKED (a sparse checkout never touches an untracked file), the way the CLI finds them: two levels below the manifest.
mkdir -p "$BASE/bin/lib"
for f in $LIBS; do cp "$LIBDIR/$f" "$BASE/bin/lib/$f"; done
# The copy must stand on its own: a library the module imports that LIBS lacks would fail every case below with a traceback and make every H break look caught.
python3 -I -B -c 'import sys; sys.path.insert(0, sys.argv[1]); import skills_cli_install' "$BASE/bin/lib" 2> "$TMP/import.err" \
  || { echo "FATAL: the fixture copy of the module cannot be imported (a library it needs is not in LIBS): $(tail -n 1 "$TMP/import.err")"; exit 1; }
bash "$BASE/bin/lib/lean_sparse.sh" apply lean "$BASE" > /dev/null 2> "$TMP/apply.err" || { echo "FATAL: the fixture clone cannot be made lean: $(head -c 300 "$TMP/apply.err")"; exit 1; }
git -C "$BASE" remote set-url origin "https://127.0.0.1:9/never.git"

# ── helpers ──────────────────────────────────────────────────────────────────────────────────────────────────────
XENV=""      # extra NAME=value words (no spaces inside a value) for the next calls; "" = none
HH=""; PROJ=""; HOME_DIR=""; PLUG=""; N=0
RC=""; OUT=""; ERR=""
# Every transport refused, a dead proxy, git's own trace of what it ran: a put-back that needs the network cannot pass.
OFFLINE="GIT_ALLOW_PROTOCOL=none http_proxy=http://127.0.0.1:9 https_proxy=http://127.0.0.1:9 ALL_PROXY=http://127.0.0.1:9 GIT_TRACE2_EVENT=$TRACE GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null ${DEVELOPER_DIR:+DEVELOPER_DIR=$DEVELOPER_DIR}"
newcase() {   # a fresh HEIMDALL_HOME, HOME, project and lean plugin clone (a copy of the prepared one), no keys on stdin
  N=$((N + 1)); HH="$TMP/hh.$N"; PROJ="$TMP/proj.$N"; HOME_DIR="$TMP/home.$N"; PLUG="$TMP/plugin.$N"
  mkdir -p "$PROJ" "$HOME_DIR"; cp -R "$BASE" "$PLUG"; XENV=""; : > "$CALLS"; : > "$TMP/stdin"; rm -f "$TRACE"
}
keys() { printf '%b' "$1" > "$TMP/stdin"; }

# cli ARGS... -> RC OUT ERR. A clean environment, the project as working directory, stdin a FILE (never a terminal), the module of this case's clone.
cli() {
  ( cd "$PROJ" && exec env -i HOME="$HOME_DIR" HEIMDALL_HOME="$HH" PATH="$GPATH" TERM=dumb HMD_RUN_ID=run-test FAKE_CALLS="$CALLS" $OFFLINE $XENV \
      "$TMP/pybin/python3" -I "$PLUG/bin/lib/skills_cli_install.py" "$@" < "$TMP/stdin" > "$TMP/out" 2> "$TMP/err" )
  RC=$?; OUT="$(cat "$TMP/out")"; ERR="$(cat "$TMP/err")"
}

mrow() { HEIMDALL_HOME="$HH" python3 -I "$LOCKPY" read --scope machine --id "$1" 2>/dev/null; }
prow() { python3 -I "$LOCKPY" read --scope project --project-dir "$PROJ" --id "$1" 2>/dev/null; }
nrows() { HEIMDALL_HOME="$HH" python3 -I "$LOCKPY" read --scope machine 2>/dev/null | grep -c '"id"' || true; }
# jrow ROW FIELD... -> the named fields of a lock row (JSON text) joined by `|`; a name starting with why. is a field of the row's why; `no-row` when there is none
jrow() {
  local row="$1"; shift
  if [ -z "$row" ]; then echo no-row; return 0; fi
  python3 -I -c 'import json, sys
row = json.loads(sys.argv[1])
print("|".join(str((row["why"] if name.startswith("why.") else row)[name.split(".")[-1]]) for name in sys.argv[2:]))' "$row" "$@"
}
# minfo ID -> state|kind|ref|version|source|pin|content_hash|consent|why.via|why.rule of the row in the machine lock
minfo() { jrow "$(mrow "$1")" state kind ref version source pin content_hash consent why.via why.rule; }
set_of()      { printf '%s\n' "$@" | LC_ALL=C sort | tr '\n' ' '; }
present_set() { git -C "$1" -c core.quotepath=false ls-files -v | sed -n 's/^H //p' | LC_ALL=C sort | tr '\n' ' '; }   # the tracked files ON DISK (skipped ones are marked S)
trace_has()   { if [ -s "$TRACE" ] && grep -q "$1" "$TRACE"; then echo yes; else echo no; fi; }
offline_ok()  {   # git ran a sparse-checkout (so the check is not blind) and no fetch / pull / clone / ls-remote / push / remote helper
  if [ -s "$TRACE" ] && grep -q 'sparse-checkout' "$TRACE" && ! grep -Eq '"(fetch|pull|clone|ls-remote|push|remote-https?|remote-ssh|remote-ext)"|git-remote-' "$TRACE"; then echo yes; else echo no; fi
}
treehash() {   # sha256 over every file of DIR but .git: its name and its bytes
  python3 -I -c 'import hashlib, os, sys
h = hashlib.sha256()
for root, dirs, files in os.walk(sys.argv[1]):
    dirs[:] = sorted(d for d in dirs if d != ".git")
    for name in sorted(files):
        path = os.path.join(root, name)
        h.update(os.path.relpath(path, sys.argv[1]).encode() + b"\0" + open(path, "rb").read() + b"\0")
print(h.hexdigest())' "$1"
}

eq "0. the prepared clone is lean: the on-demand skills, docs/ and test/ are out, the core is in" "$(set_of $LEAN_FILES)" "$(present_set "$BASE")"

# ╔═ A. consent ════════════════════════════════════════════════════════════════════════════════════════════════════╗
echo "A. consent"
newcase
cli install stacks
eq "A: no terminal and no --yes: exit 3, consent required" "3" "$RC"
has "A: ... says so, for this skill" "$ERR" "consent required to install stacks"
has "A: ... and what to run once the person said yes (so an agent can relay the question)" "$ERR" "hmd skills install stacks --yes"
eq "A: ... nothing was put back" "$(set_of $LEAN_FILES)" "$(present_set "$PLUG")"
eq "A: ... git ran no sparse-checkout" "no" "$(trace_has sparse-checkout)"
eq "A: ... no machine-lock row, and the gate's suggested project row" "no-row|suggested" "$(minfo stacks)|$(jrow "$(prow stacks)" state)"

newcase; XENV="HMD_SKILLS_ASSUME=tty"; keys 'j\n'
cli install stacks
eq "A/tty: down + Enter = Never ask again: exit 4, nothing put back, a declined project row, no machine row" "4|$(set_of $LEAN_FILES)|declined|no-row" \
  "$RC|$(present_set "$PLUG")|$(jrow "$(prow stacks)" state)|$(minfo stacks)"
has "A/tty: ... says it was declined and how to be asked again" "$ERR" "hmd skills suggest --reset"

# ╔═ B. a pack entry ═══════════════════════════════════════════════════════════════════════════════════════════════╗
echo "B. a pack entry (stacks)"
newcase
cli install stacks --yes
eq "B: --yes: exit 0" "0" "$RC"
has "B: ... says what it installed" "$OUT" "installed stacks (skills/stacks, consent yes-flag)"
eq "B: ... exactly the pack's directory is back, nothing else moved" "$(set_of $LEAN_FILES $STACKS_FILES)" "$(present_set "$PLUG")"
eq "B: ... byte for byte what HEAD holds" "content of skills/stacks/SKILL.md|content of skills/stacks/fastapi/PACK.md" "$(cat "$PLUG/skills/stacks/SKILL.md")|$(cat "$PLUG/skills/stacks/fastapi/PACK.md")"
eq "B: ... the clone recorded the path for its next re-apply (an upgrade keeps it)" "skills/stacks/" "$(cat "$PLUG/.git/info/hmd-lean-on-demand")"
eq "B: ... the machine row: installed, bundled, the entry's ref, the pack's version, source bundled, the pack's FULL sha256 as content hash, yes-flag, via, rule" \
  "installed|bundled|skills/stacks|1.0.0|bundled|none|$PACK_SHA|yes-flag|hmd-skills-install|explicit" "$(minfo stacks)"
eq "B: ... it is the only row, and the project lock has none for it" "1|no-row" "$(nrows)|$(jrow "$(prow stacks)" state)"
eq "B: INV-L4: git ran the sparse update and no transport, with every transport refused" "yes" "$(offline_ok)"
eq "B: ... and claude was never called" "0" "$(wc -c < "$CALLS" | tr -d ' ')"
rm -f "$TRACE"
cli install stacks --yes
eq "B: installing it again: exit 0, already installed, git ran nothing" "0|yes|no" "$RC|$(grep -q 'already installed' <<<"$OUT" && echo yes || echo no)|$(trace_has sparse-checkout)"
eq "B: ... and still one row" "1" "$(nrows)"

# ╔═ C. an on_demand_paths entry ═══════════════════════════════════════════════════════════════════════════════════╗
echo "C. an on_demand_paths entry (designmatch): a directory and a file"
newcase; XENV="HMD_SKILLS_ASSUME=tty"; keys 'k\n'
cli install designmatch
eq "C/tty: up + Enter = Install now: exit 0, consent prompt" "0|prompt" "$RC|$(jrow "$(mrow designmatch)" consent)"
has "C/tty: ... the menu named the skill and its path" "$ERR" "hmd: install skill designmatch (skills/designmatch)?"
eq "C: ... the directory AND the file are back, nothing else" "$(set_of $LEAN_FILES skills/designmatch/SKILL.md docs/guide.md)" "$(present_set "$PLUG")"
eq "C: ... both recorded, in the manifest's order" "skills/designmatch/|docs/guide.md" "$(paste -sd'|' "$PLUG/.git/info/hmd-lean-on-demand")"
eq "C: ... ONE row, with no content hash (the entry has no pack) and version unknown" "installed|bundled|skills/designmatch|unknown|bundled|none|None|prompt|hmd-skills-install|explicit" "$(minfo designmatch)"
eq "C: ... the only row" "1" "$(nrows)"

# ╔═ D. failures ═══════════════════════════════════════════════════════════════════════════════════════════════════╗
echo "D. failures"
newcase
cli install mac-deep-clean --yes
eq "D: a path HEAD does not track: exit 1" "1" "$RC"
has "D: ... the script's reason reaches stderr" "$ERR" "is not a tracked file or directory at HEAD"
has "D: ... and the install says it failed" "$ERR" "install failed for mac-deep-clean"
eq "D: ... the path put back before the failing one stays, and nothing else moved" "$(set_of $LEAN_FILES skills/system-health/SKILL.md)" "$(present_set "$PLUG")"
eq "D: ... the machine row is failed (never installed), with the consent it had" "failed|bundled|skills/mac-deep-clean|unknown|bundled|none|None|yes-flag|hmd-skills-install|explicit" "$(minfo mac-deep-clean)"
newcase; rm -rf "$PLUG/.git"
cli install stacks --yes
eq "D: a plugin directory that is not a clone: exit 1" "1" "$RC"
has "D: ... the script says why" "$ERR" "lean_sparse"
eq "D: ... the machine row is failed" "failed" "$(jrow "$(mrow stacks)" state)"

# ╔═ E. a full tree ════════════════════════════════════════════════════════════════════════════════════════════════╗
echo "E. a full tree"
newcase; bash "$PLUG/bin/lib/lean_sparse.sh" apply full "$PLUG" > /dev/null 2>&1
BEFORE="$(treehash "$PLUG")|$(cat "$PLUG/.git/config")"
cli install stacks --yes
eq "E: exit 0 and the row is written, with the pack's hash" "0|installed|$PACK_SHA" "$RC|$(jrow "$(mrow stacks)" state)|$(jrow "$(mrow stacks)" content_hash)"
has "E: ... the script says the path is already on disk" "$OUT" "already on disk"
eq "E: INV-L1: every file and .git/config are byte for byte what they were" "$BEFORE" "$(treehash "$PLUG")|$(cat "$PLUG/.git/config")"

# ╔═ F. what stays refused ═════════════════════════════════════════════════════════════════════════════════════════╗
echo "F. unchanged refusals"
newcase
cli install heimdall --yes
eq "F: a bundled entry that names no path: exit 2, it ships with hmd" "2|yes" "$RC|$(grep -q 'ships with hmd' <<<"$ERR" && echo yes || echo no)"
cli install design-for-ai --yes
eq "F: an install:false plugin: exit 2, hmd does not install it" "2|yes" "$RC|$(grep -q 'does not install design-for-ai' <<<"$ERR" && echo yes || echo no)"
eq "F: ... neither touched the tree, the lock, claude or git" "$(set_of $LEAN_FILES)|0|0|no" "$(present_set "$PLUG")|$(nrows)|$(wc -c < "$CALLS" | tr -d ' ')|$(trace_has sparse-checkout)"

# ╔═ H. the suite can go RED ═══════════════════════════════════════════════════════════════════════════════════════╗
# A one-line break of this case's copy of the module (the text must occur exactly once, so a refactor that moves it fails here instead of skipping the check),
# then the call the matching check above makes: it must no longer give the right answer.
echo "H. one-line breaks of the module"
mutate() {   # mutate OLD NEW -> the module of the current case's clone has OLD replaced by NEW
  if python3 -I -c 'import sys
path, old, new = sys.argv[1:4]
text = open(path, encoding="utf-8").read()
if text.count(old) != 1:
    sys.exit("the text to break is not there exactly once: " + old)
open(path, "w", encoding="utf-8").write(text.replace(old, new))' "$PLUG/bin/lib/skills_cli_install.py" "$1" "$2" 2> "$TMP/mutate.err"; then
    return 0
  fi
  bad "H: cannot apply the break [$1]" "$(head -c 200 "$TMP/mutate.err")"
  return 1
}
caught() { if [ "$2" != "$3" ]; then ok "H: $1 is caught"; else bad "H: $1 went unnoticed" "still [$3]"; fi; }

newcase; if mutate 'exec bash "$1" add "$2"' 'exec true "$1" add "$2"'; then
  cli install stacks --yes
  caught "a put-back that puts nothing back" "$(set_of $LEAN_FILES $STACKS_FILES)" "$(present_set "$PLUG")"
fi
newcase; if mutate 'argv.append("--content-hash=" + pack["sha256"])' 'pass'; then
  cli install stacks --yes
  caught "a row that loses the pack's hash" "$PACK_SHA" "$(jrow "$(mrow stacks)" content_hash)"
fi
newcase; if mutate 'scope = MACHINE if sparse_paths(entry) else SCOPE' 'scope = SCOPE'; then
  cli install stacks --yes
  caught "a row written to the project lock" "installed" "$(jrow "$(mrow stacks)" state)"
fi
newcase; if mutate 'if outcome != "proceed":' 'if False:'; then
  cli install stacks
  caught "a put-back that ignores the consent gate" "3|$(set_of $LEAN_FILES)" "$RC|$(present_set "$PLUG")"
fi
newcase; if mutate '        if status:' '        if False:'; then
  cli install mac-deep-clean --yes
  caught "a failed add that is ignored" "1|failed" "$RC|$(jrow "$(mrow mac-deep-clean)" state)"
fi
newcase; if mutate 'for path in sparse_paths(entry):' 'for path in sparse_paths(entry)[:1]:'; then
  cli install designmatch --yes
  caught "a put-back that stops after the first path" "$(set_of $LEAN_FILES skills/designmatch/SKILL.md docs/guide.md)" "$(present_set "$PLUG")"
fi
newcase; if mutate 'if entry["kind"] == "bundled" and not sparse_paths(entry):' 'if entry["kind"] == "bundled":'; then
  cli install stacks --yes
  caught "a bundled entry that is refused although its manifest names paths" "0" "$RC"
fi

finish
