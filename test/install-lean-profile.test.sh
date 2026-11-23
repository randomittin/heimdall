#!/usr/bin/env bash
# test/install-lean-profile.test.sh -- the install profile at the installer's door (3.x lean-core plan, T3.4: docs/superpowers/plans/2026-11-12-3x-lean-core.md;
# invariants in .planning/lean-core/INVARIANTS.md: INV-L2, INV-L7, INV-L8, INV-L12, and INV-L3 for what a lean tree must still hold).
#
# Journeys, each walked through the real install.sh of the tree under test, offline, in the use-case sandbox of test/use-cases/lib.sh (a private HOME under a
# private temp root, `env -i`, a fake `claude` and `security`, HEIMDALL_REPO a local git snapshot, so the one network call of an install never leaves the machine):
#   1. a developer installs hmd on a clean machine: nothing says they have used it before, so the install is LEAN (the decision is recorded once in
#      <runtime home>/profile.json): the tree has what runs and lacks test/, .planning/ and the on-demand cut (the five skills and commands/designmatch.md),
#      while every object is still in .git. The hmd launcher still runs and still wraps claude as before; no proxy and no Headroom is installed or routed
#      (INV-L12).
#   2. the same developer upgrades (install.sh again, no flag) after a new release, and has launched hmd in between (the setup marker now exists): the RECORDED
#      profile is re-applied, never reset and never re-decided (INV-L2, INV-L7), and the new release's new runtime file is on disk (the lean set is re-derived).
#   3. an install whose runtime home already holds the setup marker, or a skills-config.json that says `grandfathered`, is FULL: the tree on disk is `git ls-files`.
#   4. a plain re-run over an install that has NO record (everything installed before this step existed) writes nothing and changes nothing (INV-L8): no
#      profile.json, no sparse config, the full tree as it was. (The whole-state guard of that invariant is test/install-noflag-identical.test.sh.)
#   5. lean must never cost an install: a ref whose lean set cannot be derived (no release/runtime-files.txt) installs the full tree, exits 0 and says so on
#      stderr (the next run tries again); a ref older than the profile libraries installs exactly as before, with no record and no noise.
# The runtime home is the launcher's rule (HEIMDALL_HOME, else ~/.heimdall); scenarios 3-5 point it elsewhere through the environment so the marker or the
# config can exist BEFORE the first clone (a clone into ~/.heimdall itself would replace them).
#
# budget: 150 -- about 120 s solo: seven real install.sh runs (a local clone, python and git starts, the doctor, the fake claude), one launcher run, and a
# tracked-versus-disk comparison of ~2300 files per scenario. Nothing in it waits on a clock: no sleep, no timing assertion.
# shellcheck disable=SC2088  # the ~ in the check names is prose for the user's home, never a path this script expands
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=use-cases/lib.sh
. "$HERE/use-cases/lib.sh"
uc_begin install_lean_profile
uc_need_node
uc_need_crypto
uc_tree
uc_fakebin

# lp_missing CLONE -- the tracked paths that are not on disk, one per line: empty = the work tree holds every file `git ls-files` names.
lp_missing() {
  git -C "$1" -c core.quotepath=false ls-files | LC_ALL=C sort > "$UC_ROOT/lp-tracked.txt"
  ( cd "$1" && find . -path ./.git -prune -o \( -type f -o -type l \) -print | sed 's|^\./||' | LC_ALL=C sort ) > "$UC_ROOT/lp-disk.txt"
  LC_ALL=C comm -23 "$UC_ROOT/lp-tracked.txt" "$UC_ROOT/lp-disk.txt"
}

# lp_release NAME TAG CMD... -- a copy of the tree under test with ONE more commit (CMD runs in the copy), tagged TAG: a release the installer can be pointed at.
lp_release() {
  local name="$1" tag="$2" dir="$UC_ROOT/rel-$1"
  shift 2
  git clone -q --no-hardlinks "$UC_TREE" "$dir" || uc_fatal "cannot copy the tree under test for the $name release"
  ( cd "$dir" && "$@" ) || uc_fatal "the $name release edit failed"
  git -c core.hooksPath=/dev/null -C "$dir" add -A -f || uc_fatal "cannot stage the $name release"
  git -c core.hooksPath=/dev/null -c commit.gpgsign=false -c user.email=use-case@example.invalid -c user.name=use-case \
    -C "$dir" commit -q --no-verify -m "$name release" || uc_fatal "cannot commit the $name release"
  git -c tag.gpgsign=false -C "$dir" tag "$tag" || uc_fatal "cannot tag the $name release"
  LP_REL="$dir"
}

lp_edit_next_release() {
  printf '#!/usr/bin/env bash\necho probe\n' > bin/lib/lean_probe.sh
  chmod +x bin/lib/lean_probe.sh
  printf 'bin/lib/lean_probe.sh\n' >> release/runtime-files.txt
  printf '#!/usr/bin/env bash\nexit 0\n' > test/lean-probe-suite.test.sh
}
lp_edit_no_runtime_list() { git rm -q release/runtime-files.txt; }
lp_edit_no_profile_lib()  { git rm -q bin/lib/hmd_profile.py; }

# lp_full_tree LABEL CLONE -- the work tree is `git ls-files`: nothing tracked is missing, git has no sparse checkout on.
lp_full_tree() {
  local miss
  miss="$(lp_missing "$2")"
  if [ -z "$miss" ]; then uc_ok "$1: the tree on disk is git ls-files (every tracked file is there)"; else uc_bad "$1: $(printf '%s\n' "$miss" | wc -l | tr -d ' ') tracked files are missing" "$(printf '%s\n' "$miss" | head -3 | tr '\n' ' ')"; fi
  if [ "$(git -C "$2" config --bool --get core.sparseCheckout 2>/dev/null || true)" != true ]; then uc_ok "$1: git has no sparse checkout on"; else uc_bad "$1: core.sparseCheckout is true"; fi
}

# ---------------------------------------------------------------------------------------------------------------------------------------------------------
# 1. a clean machine: the install is lean
uc_sandbox lean
printf '# my zshrc\nexport EDITOR=vim\n' > "$UC_HOME/.zshrc"
mkdir -p "$UC_HOME/.claude"
printf '{"theme":"dark"}\n' > "$UC_HOME/.claude/settings.json"
CLONE="$UC_HOME/.heimdall"

uc_install "$UC_HOME" "$UC_WORK" SHELL=/bin/zsh
cp "$UC_OUT" "$UC_ROOT/lean-1.out"
uc_rc "1. a fresh install.sh finishes" 0
uc_has "the installer says it applied the lean profile" "$UC_ROOT/lean-1.out" 'Applying lean profile'
uc_jq "the lean profile is recorded once, in the runtime home (~/.heimdall/profile.json)" '.profile == "lean"' "$CLONE/profile.json"
if [ "$(git -C "$CLONE" config --bool --get core.sparseCheckout 2>/dev/null || true)" = true ]; then uc_ok "the clone is a sparse checkout"; else uc_bad "the clone is not a sparse checkout"; fi
for p in test .planning skills/stacks skills/designmatch skills/mac-deep-clean skills/system-health commands/designmatch.md; do
  if [ ! -e "$CLONE/$p" ]; then uc_ok "lean: $p is not on disk"; else uc_bad "lean: $p is on disk"; fi
done
for p in bin/heimdall hooks/hooks.json agents/heimdall.md skills/heimdall/SKILL.md .claude-plugin/plugin.json settings.json .mcp.json LICENSE \
         release/runtime-files.txt fixtures/attack/buggy-webhook/webhook.mjs; do
  if [ -e "$CLONE/$p" ]; then uc_ok "lean keeps $p"; else uc_bad "lean lost $p"; fi
done
lp_missing "$CLONE" > "$UC_ROOT/lean-missing.txt"
if [ -s "$UC_ROOT/lean-missing.txt" ]; then uc_ok "the lean tree is narrower than git ls-files"; else uc_bad "nothing was narrowed: the lean tree equals git ls-files"; fi
# The runtime list is "reachable", not "lean": it still names the cut (bin/designmatch names skills/designmatch/, bin/detect-skills names skills/, and skills.manifest.json
# names commands/designmatch.md as an on_demand_path). The cut is the real manifest's, written out here on purpose as test/lean-sparse.test.sh does: a path added to it has
# to be added here too (test/skills-manifest-pack-values.test.sh pins the manifest side), and nothing else may be missing.
LC_ALL=C comm -12 "$UC_ROOT/lean-missing.txt" <(git -C "$CLONE" cat-file blob HEAD:release/runtime-files.txt | LC_ALL=C sort -u) \
  | grep -Ev '^(skills/(stacks|designmatch|self-improve|system-health|mac-deep-clean)/|commands/designmatch\.md$)' > "$UC_ROOT/lean-lost-runtime.txt"
if [ ! -s "$UC_ROOT/lean-lost-runtime.txt" ]; then uc_ok "INV-L3: every file the runtime list names is on disk, the on-demand cut apart"; else uc_bad "lean lost runtime files" "$(head -3 "$UC_ROOT/lean-lost-runtime.txt" | tr '\n' ' ')"; fi
if [ "$(git -C "$CLONE" status --porcelain 2>/dev/null | grep -c '^.D')" = 0 ]; then uc_ok "git sees no deleted file (the missing paths are skipped, not removed)"; else uc_bad "git reports tracked files as deleted"; fi
if git -C "$CLONE" cat-file -e 'HEAD:skills/stacks/SKILL.md' 2>/dev/null; then uc_ok "what the lean tree lacks is still in .git, one local add away"; else uc_bad "skills/stacks/SKILL.md is not in the clone's objects"; fi

# INV-L12: the launcher is installed and wraps claude as before; no proxy, no Headroom
for name in hmd heimdall; do
  link="$UC_HOME/.local/bin/$name"
  if [ -L "$link" ] && [ "$(readlink -f "$link")" = "$(cd "$CLONE/bin" && pwd -P)/heimdall" ]; then uc_ok "~/.local/bin/$name is a symlink to the installed launcher"; else uc_bad "~/.local/bin/$name is not a symlink into ~/.heimdall/bin/heimdall"; fi
done
uc_run "$UC_HOME" "$UC_WORK" SHELL=/bin/zsh -- bash -c '. "$HOME/.zshrc"; hmd version'
uc_rc "INV-L12: hmd runs from the lean tree" 0
uc_has "...and reports this version" "$UC_OUT" "Heimdall v$UC_VERSION"
uc_jq "INV-L12: no proxy route was written into ~/.claude/settings.json" '(.env // {}) | keys | map(select(test("ANTHROPIC_BASE_URL|HEADROOM|PROXY"; "i"))) | length == 0' "$UC_HOME/.claude/settings.json"
uc_jq "...and their own settings key is still there" '.theme == "dark"' "$UC_HOME/.claude/settings.json"
if ! grep -qi headroom "$UC_HOME/.zshrc" "$UC_HOME/.claude/settings.json" "$UC_CLAUDE_LOG" "$UC_ROOT/lean-1.out" 2>/dev/null; then uc_ok "INV-L12: nothing named headroom was installed, routed or run"; else uc_bad "headroom appears in what the lean install wrote or ran"; fi
if [ ! -s "$UC_SECURITY_LOG" ]; then uc_ok "the keychain was never asked"; else uc_bad "the installer asked the keychain" "$(head -c 200 "$UC_SECURITY_LOG")"; fi

# ---------------------------------------------------------------------------------------------------------------------------------------------------------
# 2. the upgrade: the recorded profile is re-applied, the new release's runtime file arrives, nothing flips
: > "$CLONE/setup-done"                 # the launcher wrote its first-run marker: marker present must NOT turn the recorded lean into full
cp "$CLONE/profile.json" "$UC_ROOT/profile-before.json"
lp_release next "v$UC_VERSION-lean-next" lp_edit_next_release
NEXT_SHA="$(git -C "$LP_REL" rev-parse HEAD)"
uc_install "$UC_HOME" "$UC_WORK" SHELL=/bin/zsh HEIMDALL_REPO="$LP_REL" HEIMDALL_REF="v$UC_VERSION-lean-next"
cp "$UC_OUT" "$UC_ROOT/lean-2.out"
uc_rc "2. install.sh again, after a new release, finishes" 0
uc_has "...as an upgrade" "$UC_ROOT/lean-2.out" 'Updating Heimdall'
if [ "$(git -C "$CLONE" rev-parse HEAD)" = "$NEXT_SHA" ]; then uc_ok "the clone moved to the new release"; else uc_bad "the clone is not at the new release"; fi
uc_jq "INV-L7: the recorded profile is still lean" '.profile == "lean"' "$CLONE/profile.json"
if cmp -s "$CLONE/profile.json" "$UC_ROOT/profile-before.json"; then uc_ok "INV-L2: the record was not rewritten (decided once)"; else uc_bad "the upgrade rewrote profile.json"; fi
if [ ! -e "$CLONE/test" ]; then uc_ok "INV-L7: the upgraded tree is still lean (test/ is not on disk)"; else uc_bad "the upgrade brought test/ back"; fi
if [ ! -e "$CLONE/test/lean-probe-suite.test.sh" ]; then uc_ok "the new release's non-runtime file stays off disk"; else uc_bad "the new release's test file is on disk"; fi
if [ -x "$CLONE/bin/lib/lean_probe.sh" ]; then uc_ok "the new release's new runtime file is on disk and executable (the lean set was re-derived)"; else uc_bad "bin/lib/lean_probe.sh, new in this release, is missing from the lean tree"; fi
if [ "$(git -C "$CLONE" config --bool --get core.sparseCheckout 2>/dev/null || true)" = true ]; then uc_ok "the clone is still a sparse checkout"; else uc_bad "the upgrade left the sparse checkout"; fi

# ---------------------------------------------------------------------------------------------------------------------------------------------------------
# 3. marker present, or grandfathered: the install is full
uc_sandbox marker
RT="$UC_ROOT/marker/runtime-home"; mkdir -p "$RT"; : > "$RT/setup-done"
CLONE="$UC_HOME/.heimdall"
uc_install "$UC_HOME" "$UC_WORK" SHELL=/bin/zsh HEIMDALL_HOME="$RT"
uc_rc "3. a fresh install.sh whose runtime home holds the setup marker finishes" 0
uc_jq "the profile recorded is full" '.profile == "full"' "$RT/profile.json"
lp_full_tree "marker present" "$CLONE"
if ! grep -q 'Applying lean profile' "$UC_OUT"; then uc_ok "marker present: the installer applied nothing"; else uc_bad "the installer applied the lean profile over a marker"; fi

uc_sandbox grandfathered
RT="$UC_ROOT/grandfathered/runtime-home"; mkdir -p "$RT"
printf '{"consent":"auto","grandfathered":true}\n' > "$RT/skills-config.json"
CLONE="$UC_HOME/.heimdall"
uc_install "$UC_HOME" "$UC_WORK" SHELL=/bin/zsh HEIMDALL_HOME="$RT"
uc_rc "a fresh install.sh whose skills-config.json says grandfathered finishes" 0
uc_jq "the profile recorded is full" '.profile == "full"' "$RT/profile.json"
lp_full_tree "grandfathered" "$CLONE"

# ---------------------------------------------------------------------------------------------------------------------------------------------------------
# 4. INV-L8: a plain re-run over an install with no record writes nothing and changes nothing
uc_sandbox norecord
RT="$UC_ROOT/norecord/runtime-home"; mkdir -p "$RT"; : > "$RT/setup-done"
CLONE="$UC_HOME/.heimdall"
uc_install "$UC_HOME" "$UC_WORK" SHELL=/bin/zsh HEIMDALL_HOME="$RT"
uc_rc "4. the first install.sh run (marker present) finishes" 0
rm -f "$RT/profile.json" "$RT/setup-done"    # an install that predates the record, and a marker that is gone: nothing may read that as a fresh install
git -C "$CLONE" config --local --list | LC_ALL=C sort > "$UC_ROOT/norecord-config-before.txt"
uc_install "$UC_HOME" "$UC_WORK" SHELL=/bin/zsh HEIMDALL_HOME="$RT"
cp "$UC_OUT" "$UC_ROOT/norecord-2.out"
uc_rc "the plain re-run finishes" 0
uc_has "...as an upgrade of the existing clone" "$UC_ROOT/norecord-2.out" 'Updating Heimdall'
if [ ! -e "$RT/profile.json" ] && [ ! -e "$CLONE/profile.json" ] && [ ! -e "$UC_HOME/.heimdall/.heimdall/profile.json" ]; then uc_ok "INV-L8: no profile.json was written anywhere"; else uc_bad "the plain re-run wrote a profile record"; fi
lp_full_tree "plain re-run" "$CLONE"
git -C "$CLONE" config --local --list | LC_ALL=C sort > "$UC_ROOT/norecord-config-after.txt"
if cmp -s "$UC_ROOT/norecord-config-before.txt" "$UC_ROOT/norecord-config-after.txt"; then uc_ok "INV-L8: the clone's git config is byte-identical"; else uc_bad "the plain re-run changed the clone's git config"; fi
if ! grep -Eq '[Ll]ean profile' "$UC_ROOT/norecord-2.out" "$UC_ERR"; then uc_ok "INV-L8: the plain re-run says nothing about profiles"; else uc_bad "the plain re-run mentions the lean profile"; fi

# ---------------------------------------------------------------------------------------------------------------------------------------------------------
# 5. lean never costs an install
uc_sandbox nolist
CLONE="$UC_HOME/.heimdall"
lp_release nolist "v$UC_VERSION-lean-nolist" lp_edit_no_runtime_list
uc_install "$UC_HOME" "$UC_WORK" SHELL=/bin/zsh HEIMDALL_REPO="$LP_REL" HEIMDALL_REF="v$UC_VERSION-lean-nolist"
uc_rc "5. a ref with no release/runtime-files.txt still installs" 0
uc_has "...and says on stderr that the lean profile was not applied" "$UC_ERR" 'lean profile not applied'
lp_full_tree "no runtime list" "$CLONE"
uc_jq "...the decision stays recorded, so the next run tries again" '.profile == "lean"' "$CLONE/profile.json"

uc_sandbox oldref
CLONE="$UC_HOME/.heimdall"
lp_release oldref "v$UC_VERSION-lean-oldref" lp_edit_no_profile_lib
uc_install "$UC_HOME" "$UC_WORK" SHELL=/bin/zsh HEIMDALL_REPO="$LP_REL" HEIMDALL_REF="v$UC_VERSION-lean-oldref"
uc_rc "a ref older than the profile library installs as before" 0
if [ ! -e "$CLONE/profile.json" ]; then uc_ok "...with no record written"; else uc_bad "a record was written without the library"; fi
lp_full_tree "old ref" "$CLONE"
if ! grep -Eq '[Ll]ean profile' "$UC_OUT" "$UC_ERR"; then uc_ok "...and no noise about profiles"; else uc_bad "an old ref install mentions the lean profile"; fi

uc_finish
