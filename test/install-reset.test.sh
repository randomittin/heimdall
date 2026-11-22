#!/usr/bin/env bash
# test/install-reset.test.sh -- `install.sh --reset`: an EXISTING install becomes lean, in place, and can be put back (3.x lean-core plan, T4.4:
# docs/superpowers/plans/2026-11-12-3x-lean-core.md; invariants in .planning/lean-core/INVARIANTS.md: INV-L9, INV-L11, INV-L12; INV-L8 is
# test/install-noflag-identical.test.sh, INV-L10 is test/install-reset-userdata.test.sh).
#
# The journey, walked through the real install.sh of the tree under test, offline, in the use-case sandbox of test/use-cases/lib.sh (a private HOME under a
# private temp root, `env -i`, a fake `claude` and `security`, HEIMDALL_REPO a local git snapshot, so the one network call never leaves the machine; the
# keychain, ~/.heimdall and ~/.claude of the operator are never read or written). Given a developer who already has hmd installed (a full tree made by the
# install.sh that predates the lean profile, the launcher's setup marker, a grandfathered skills-config.json, a `claude` wrapper in their .zshrc):
#   1. `install.sh --reset` makes the install lean (profile lean, consent ask, grandfathered false, a sparse tree), takes a 0700 backup of what it changes
#      FIRST, switches Headroom off for the next session through the Headroom CLI's `off --next-session`, leaves the shell rc and the `claude` wrapper alone
#      (INV-L12), skips the lean prompt with ONE line while no green prompt-parity receipt ships with the release, and prints the undo command, which works:
#      run as printed it returns skills-config.json byte for byte, drops the profile record and brings the full tree back (INV-L9).
#   2. when the session is routed through Headroom (the guard says defer, INV-L11) the lean tree and the Headroom switch are PENDING: named on stdout and
#      recorded, the headroom CLI is not called, the route the session reads (settings env) is not edited; the next `--reset`, with no route, finishes both and
#      keeps the FIRST backup, so the undo still returns the install to what it was before the reset began.
#   3. a guard that cannot tell (a route that is not a host and port) refuses: nothing changes, no backup, exit 1.
#   4. an install without the Headroom CLI gets exactly one warning on stderr and no switch; everything else happens.
#   5. the lean prompt is selected (agent hmd:heimdall-lean, in the USER settings, indent and other keys kept) only against a GREEN receipt that names the
#      sha256 of that very prompt; a red receipt, a stale hash and a user's own `agent` each skip it with one line and change nothing.
# The Headroom CLI is another subsystem and acts on launchd: the releases and clones used here carry a RECORDING stand-in at bin/heimdall-headroom (it logs
# how it was called and changes nothing), so the real one is never run; one check pins that the real CLI still documents the `off [--next-session]` call.
# Scenarios 1 and 2 run the real `install.sh --reset` (the flag parse and the call site); 3-5 call the same lean_reset function through the installer's
# HEIMDALL_INSTALL_SOURCE_ONLY seam, in a copy of the same existing install, so each costs seconds, not an installer run.
#
# budget: 260 -- about 190 s solo: one existing install by the pinned installer, three real install.sh --reset runs (a local fetch, python and git starts, the
# doctor, a sparse apply of ~2300 files, the fake claude), two `hmd lean restore` undo runs (the printed command, through the installed launcher), and eight
# lean_reset calls through the seam. No sleep, no timing
# assertion: the only clock is the hang watchdog of the harness.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../bin/lib/lean_install_fixture.sh
. "$HERE/../bin/lib/lean_install_fixture.sh"
BASELINE="$HERE/../evals/lean/install-baseline.json"
uc_begin install_reset
uc_need_node
uc_need_crypto
uc_tree
uc_fakebin
[ -f "$BASELINE" ] || uc_fatal "missing $BASELINE"

# ir_release NAME TAG CMD... -- a copy of the tree under test with ONE more commit (CMD runs in the copy), tagged TAG: a release the installer can be pointed at.
ir_release() {
  local name="$1" tag="$2" dir="$UC_ROOT/rel-$1"
  shift 2
  git clone -q --no-hardlinks "$UC_TREE" "$dir" || uc_fatal "cannot copy the tree under test for the $name release"
  ( cd "$dir" && "$@" ) || uc_fatal "the $name release edit failed"
  git -c core.hooksPath=/dev/null -C "$dir" add -A -f || uc_fatal "cannot stage the $name release"
  git -c core.hooksPath=/dev/null -c commit.gpgsign=false -c user.email=use-case@example.invalid -c user.name=use-case \
    -C "$dir" commit -q --no-verify -m "$name release" || uc_fatal "cannot commit the $name release"
  git -c tag.gpgsign=false -C "$dir" tag "$tag" || uc_fatal "cannot tag the $name release"
  IR_REL="$dir"
}

# ir_edit_double -- (in a tree) replace the Headroom CLI by a recording stand-in: it appends its arguments to $IR_HEADROOM_LOG and changes nothing
ir_edit_double() {
  cat > bin/heimdall-headroom <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${IR_HEADROOM_LOG:-/dev/null}"
echo "headroom double: $*"
EOF
  chmod +x bin/heimdall-headroom
}

# ir_copy NAME [double] -- UC_HOME, UC_WORK and CLONE are a copy of the base existing install; `double` also puts the recording Headroom stand-in in its work tree
ir_copy() {
  uc_sandbox "$1"
  rmdir "$UC_HOME" && cp -Rp "$BASE_HOME" "$UC_HOME" || uc_fatal "cannot copy the base install for $1"
  # the base install wrote its own HOME into the profile (the PATH line names ~/.local/bin by absolute path, and a re-run greps for it): the copy is the
  # same machine at another path, so the profile is re-homed, or the installer would append a second PATH line that has nothing to do with the reset
  sed "s|$BASE_HOME|$UC_HOME|g" "$UC_HOME/.zshrc" > "$UC_HOME/.zshrc.copy" && mv "$UC_HOME/.zshrc.copy" "$UC_HOME/.zshrc" || uc_fatal "cannot re-home the .zshrc of the copy"
  CLONE="$UC_HOME/.heimdall"
  # ...and so are the launcher links the installer put in ~/.local/bin (absolute symlinks into the BASE clone): the printed undo is `hmd lean restore <dir>`, and
  # the `hmd` a shell finds on its PATH has to be the one of THIS copy
  for n in hmd heimdall; do ln -sf "$CLONE/bin/heimdall" "$UC_HOME/.local/bin/$n" || uc_fatal "cannot re-home the $n launcher link of the copy"; done
  [ "${2:-}" != double ] || ( cd "$CLONE" && ir_edit_double )
  : > "$UC_ROOT/headroom.log"
}

# ir_reset NAME REL TAG [VAR=val...] -- the real install.sh --reset of the tree under test, upgrading the current copy to release REL at TAG; output kept in $UC_ROOT/NAME.out/.err
ir_reset() {
  local name="$1" rel="$2" tag="$3"
  shift 3
  uc_run "$UC_HOME" "$UC_WORK" HEIMDALL_REPO="$rel" HEIMDALL_REF="$tag" SHELL=/bin/zsh IR_HEADROOM_LOG="$UC_ROOT/headroom.log" HEADROOM_PORT=9 "$@" \
    -- bash "$UC_TREE/install.sh" --reset
  cp "$UC_OUT" "$UC_ROOT/$name.out"
  cp "$UC_ERR" "$UC_ROOT/$name.err"
}

# ir_call [VAR=val...] -- lean_reset of the tree's install.sh against the current copy, through the source-only seam; prints `lean_reset: <status>` on stdout
ir_call() {
  uc_run "$UC_HOME" "$UC_WORK" HEIMDALL_INSTALL_SOURCE_ONLY=1 IR_HEADROOM_LOG="$UC_ROOT/headroom.log" HEADROOM_PORT=9 "$@" \
    -- bash -c '. "$1"; if lean_reset "$2" "$2"; then echo "lean_reset: 0"; else echo "lean_reset: $?"; fi' _ "$UC_TREE/install.sh" "$CLONE"
}

ir_missing() {   # CLONE -- the tracked paths that are not on disk, one per line
  git -C "$1" -c core.quotepath=false ls-files | LC_ALL=C sort > "$UC_ROOT/ir-tracked.txt"
  ( cd "$1" && find . -path ./.git -prune -o \( -type f -o -type l \) -print | sed 's|^\./||' | LC_ALL=C sort ) > "$UC_ROOT/ir-disk.txt"
  LC_ALL=C comm -23 "$UC_ROOT/ir-tracked.txt" "$UC_ROOT/ir-disk.txt"
}
ir_is_full() {   # LABEL CLONE -- every tracked file is on disk and git has no sparse checkout on
  local miss
  miss="$(ir_missing "$2")"
  if [ -z "$miss" ]; then uc_ok "$1: the tree is full (every tracked file is on disk)"; else uc_bad "$1: $(printf '%s\n' "$miss" | wc -l | tr -d ' ') tracked files are missing" "$(printf '%s\n' "$miss" | head -3 | tr '\n' ' ')"; fi
  if [ "$(git -C "$2" config --bool --get core.sparseCheckout 2>/dev/null || true)" != true ]; then uc_ok "$1: git has no sparse checkout on"; else uc_bad "$1: core.sparseCheckout is true"; fi
}
ir_is_lean() {   # LABEL CLONE -- sparse checkout on, test/ .planning/ and the on-demand skills off disk, what runs on disk
  local p bad=""
  if [ "$(git -C "$2" config --bool --get core.sparseCheckout 2>/dev/null || true)" = true ]; then uc_ok "$1: the clone is a sparse checkout"; else uc_bad "$1: the clone is not a sparse checkout"; fi
  for p in test .planning skills/stacks skills/designmatch; do [ ! -e "$2/$p" ] || bad="$bad $p"; done
  if [ -z "$bad" ]; then uc_ok "$1: test/, .planning/ and the on-demand skills are off disk"; else uc_bad "$1: still on disk:$bad"; fi
  bad=""
  for p in bin/heimdall bin/heimdall-lean bin/lib/lean_backup.py hooks/hooks.json agents/heimdall.md skills/heimdall/SKILL.md .claude-plugin/plugin.json release/runtime-files.txt; do
    [ -e "$2/$p" ] || bad="$bad $p"
  done
  if [ -z "$bad" ]; then uc_ok "$1: what runs is on disk"; else uc_bad "$1: lost:$bad"; fi
}
ir_backups() { ls -1 "$1/backups" 2>/dev/null | grep -v -e '^lean-reset-pending$' -e '^\.partial' || true; }
ir_sha() { shasum -a 256 < "$1" | cut -c1-64; }
ir_mode() { perl -e 'printf "%o\n", (stat $ARGV[0])[2] & 07777' "$1"; }
ir_line() { sed -n "s/^   $1: //p" "$2" | head -1; }   # NAME FILE -- the text after "   N/8 key: " of a step line

# ---------------------------------------------------------------------------------------------------------------------------------------------------------
# 0. the existing install: made by the install.sh the baseline names (it predates the lean profile), then the launcher's first run (marker + grandfathering)
uc_sandbox base
BASE_HOME="$UC_HOME"
lean_fx_baseline_installer "$BASELINE" "$UC_ROOT/baseline-installer/install.sh" 2>"$UC_ROOT/baseline-installer.err" \
  || uc_fatal "the install.sh the baseline was recorded from is not available: $(head -c 400 "$UC_ROOT/baseline-installer.err" | LC_ALL=C tr '\n' ' ')"
printf '# my zshrc\nexport EDITOR=vim\nclaude() { hmd route claude "$@"; }\n' > "$UC_HOME/.zshrc"
mkdir -p "$UC_HOME/.claude"
printf '{"theme":"dark","env":{"ANTHROPIC_BASE_URL":"http://127.0.0.1:9"}}\n' > "$UC_HOME/.claude/settings.json"
uc_run "$UC_HOME" "$UC_WORK" HEIMDALL_REPO="$UC_TREE" HEIMDALL_REF="$UC_REF" SHELL=/bin/zsh -- bash "$UC_ROOT/baseline-installer/install.sh"
uc_rc "0. the existing install (the installer that predates the lean profile) finishes" 0
: > "$BASE_HOME/.heimdall/setup-done"
uc_run "$BASE_HOME" "$UC_WORK" HEIMDALL_HOME="$BASE_HOME/.heimdall" -- python3 -I "$BASE_HOME/.heimdall/bin/lib/skills_config.py" init --marker-present
uc_rc "...and the launcher's first run records the grandfathering" 0
uc_jq "the existing install is grandfathered with consent auto" '.grandfathered == true and .consent == "auto"' "$BASE_HOME/.heimdall/skills-config.json"
if [ ! -e "$BASE_HOME/.heimdall/profile.json" ]; then uc_ok "the existing install has no profile record"; else uc_bad "the existing install already has a profile record"; fi
ir_missing "$BASE_HOME/.heimdall" > "$UC_ROOT/base-missing.txt"
if [ ! -s "$UC_ROOT/base-missing.txt" ]; then uc_ok "the existing install is a full tree"; else uc_bad "the existing install is not a full tree"; fi
# the contract with the Headroom CLI, read from the REAL one: `off [--next-session]` is what the reset calls
if grep -Fq -- 'hmd headroom off [--next-session]' "$UC_TREE/bin/heimdall-headroom" && grep -Fq -- '--next-session changes configuration only' "$UC_TREE/bin/heimdall-headroom"; then
  uc_ok "the real Headroom CLI documents off --next-session as a configuration-only switch"
else
  uc_bad "the real Headroom CLI no longer documents off [--next-session]: the reset's call would be wrong"
fi
ir_release double "v$UC_VERSION-reset-double" ir_edit_double
IR_DOUBLE="$IR_REL"; IR_DOUBLE_TAG="v$UC_VERSION-reset-double"

# ---------------------------------------------------------------------------------------------------------------------------------------------------------
# 1. the happy path, through the real flag
ir_copy happy
cp "$UC_HOME/.zshrc" "$UC_ROOT/happy-zshrc.before"
cp "$CLONE/skills-config.json" "$UC_ROOT/happy-skills-config.before"
ir_reset happy "$IR_DOUBLE" "$IR_DOUBLE_TAG"
uc_rc "1. install.sh --reset over the existing install finishes" 0
uc_has "...as an upgrade of the existing clone first" "$UC_ROOT/happy.out" 'Updating Heimdall'
uc_has "1/8 the route guard says ok" "$UC_ROOT/happy.out" '1/8 route guard: ok:'
uc_has "2/8 a backup is taken" "$UC_ROOT/happy.out" '2/8 backup: .*/backups/'
uc_has "3/8 consent ask, not grandfathered" "$UC_ROOT/happy.out" '3/8 consent: ask, not grandfathered'
uc_has "4/8 profile lean" "$UC_ROOT/happy.out" '4/8 profile: lean'
uc_has "5/8 the lean tree is applied" "$UC_ROOT/happy.out" '5/8 lean tree: applied'
uc_has "6/8 the lean prompt is skipped, in one line, for want of a green receipt" "$UC_ROOT/happy.out" '6/8 lean prompt: skipped, this release has no green prompt-parity receipt'
uc_has "7/8 Headroom is off for the next session" "$UC_ROOT/happy.out" '7/8 headroom: off for the next session'
uc_has "8/8 the undo command is printed: the one short command, hmd lean restore <backup>" "$UC_ROOT/happy.out" '8/8 to undo: hmd lean restore .*/backups/'
uc_jq "consent is ask and the install is no longer grandfathered" '.consent == "ask" and .grandfathered == false' "$CLONE/skills-config.json"
uc_jq "the lean profile is recorded in the runtime home" '.profile == "lean"' "$CLONE/profile.json"
ir_is_lean "after the reset" "$CLONE"
if [ "$(cat "$UC_ROOT/headroom.log")" = "off --next-session" ]; then uc_ok "the Headroom CLI was called once, with off --next-session"; else uc_bad "the Headroom CLI was not called exactly once with off --next-session" "$(head -c 200 "$UC_ROOT/headroom.log" | tr '\n' '|')"; fi
if [ ! -e "$CLONE/backups/lean-reset-pending" ]; then uc_ok "nothing is pending: no unfinished-reset record"; else uc_bad "a finished reset left an unfinished-reset record"; fi
HAPPY_BACKUP="$(ir_line '2\/8 backup' "$UC_ROOT/happy.out")"
if [ -f "$HAPPY_BACKUP/manifest.json" ] && [ "$(ir_backups "$CLONE" | wc -l | tr -d ' ')" = 1 ]; then uc_ok "exactly one backup exists and the printed path is it"; else uc_bad "the backup is not where the output says: $HAPPY_BACKUP"; fi
if [ "$(ir_mode "$HAPPY_BACKUP")" = 700 ] && [ "$(ir_mode "$CLONE/backups")" = 700 ]; then uc_ok "INV-L9: the backup directory is mode 0700"; else uc_bad "INV-L9: the backup directory is not 0700 ($(ir_mode "$HAPPY_BACKUP"))"; fi
if [ "$(jq -r '.entries[] | select(.id == "home/skills-config.json") | .sha256' "$HAPPY_BACKUP/manifest.json")" = "$(ir_sha "$UC_ROOT/happy-skills-config.before")" ]; then
  uc_ok "INV-L9: the backup holds skills-config.json as it was BEFORE the reset"
else
  uc_bad "INV-L9: the backup's skills-config.json is not the pre-reset file"
fi
uc_jq "the backup records the profile as absent (the install had none)" '.entries[] | select(.id == "home/profile.json") | .state == "absent"' "$HAPPY_BACKUP/manifest.json"
# INV-L12: the launcher and its wrapper are kept, nothing routes or installs a proxy
if cmp -s "$UC_ROOT/happy-zshrc.before" "$UC_HOME/.zshrc"; then uc_ok "INV-L12: the .zshrc is byte for byte what it was"; else uc_bad "INV-L12: the reset changed the .zshrc"; fi
uc_has "INV-L12: the claude wrapper is still in the .zshrc" "$UC_HOME/.zshrc" '^claude\(\) \{ hmd route claude'
uc_jq "the user's settings key and the route entry they had are untouched, and no agent was selected" '.theme == "dark" and .env.ANTHROPIC_BASE_URL == "http://127.0.0.1:9" and (has("agent") | not)' "$UC_HOME/.claude/settings.json"
if [ ! -s "$UC_SECURITY_LOG" ]; then uc_ok "the keychain was never asked"; else uc_bad "the reset asked the keychain"; fi
# the undo, as printed
UNDO="$(ir_line '8\/8 to undo' "$UC_ROOT/happy.out")"
if [ "$UNDO" = "hmd lean restore $(printf '%q' "$HAPPY_BACKUP")" ]; then uc_ok "INV-L9: the printed undo is exactly hmd lean restore <the backup dir>, and nothing else"; else uc_bad "INV-L9: the printed undo is not hmd lean restore <the backup dir>" "$UNDO"; fi
uc_run "$UC_HOME" "$UC_WORK" SHELL=/bin/zsh PATH="$UC_HOME/.local/bin:$UC_PATH" -- bash -c "$UNDO"   # hmd as a shell finds it: ~/.local/bin is where the installer put it
uc_rc "the printed undo command runs" 0
if cmp -s "$UC_ROOT/happy-skills-config.before" "$CLONE/skills-config.json"; then uc_ok "INV-L9: the undo returns skills-config.json byte for byte"; else uc_bad "INV-L9: skills-config.json is not what it was before the reset"; fi
if [ ! -e "$CLONE/profile.json" ]; then uc_ok "the undo drops the profile record the reset made"; else uc_bad "the undo left a profile record"; fi
ir_is_full "after the undo" "$CLONE"
if cmp -s "$UC_ROOT/happy-zshrc.before" "$UC_HOME/.zshrc"; then uc_ok "the .zshrc is still what it was"; else uc_bad "the undo changed the .zshrc"; fi
if [ -f "$HAPPY_BACKUP/manifest.json" ]; then uc_ok "the backup itself is kept after the undo"; else uc_bad "the undo removed the backup"; fi

# ---------------------------------------------------------------------------------------------------------------------------------------------------------
# 2. a session routed through Headroom: steps 5 and 7 are pending, never silently skipped; the next run finishes them and keeps the first backup
ir_copy defer
cp "$CLONE/skills-config.json" "$UC_ROOT/defer-skills-config.before"
ir_reset defer "$IR_DOUBLE" "$IR_DOUBLE_TAG" ANTHROPIC_BASE_URL=http://127.0.0.1:9
uc_rc "2. install.sh --reset inside a session routed through Headroom finishes" 0
uc_has "1/8 the route guard says defer" "$UC_ROOT/defer.out" '1/8 route guard: defer:'
uc_has "3/8 consent is still changed" "$UC_ROOT/defer.out" '3/8 consent: ask, not grandfathered'
uc_has "4/8 the profile is still recorded" "$UC_ROOT/defer.out" '4/8 profile: lean'
uc_has "5/8 the lean tree is named as PENDING" "$UC_ROOT/defer.out" '5/8 lean tree: PENDING'
uc_has "7/8 the Headroom switch is named as PENDING" "$UC_ROOT/defer.out" '7/8 headroom: PENDING'
uc_has "both pending steps are listed together with where they are noted" "$UC_ROOT/defer.out" 'unfinished: lean-tree headroom-off \(noted in .*lean-reset-pending'
ir_is_full "while pending" "$CLONE"
if [ ! -s "$UC_ROOT/headroom.log" ]; then uc_ok "INV-L11: the Headroom CLI was not called for the live session"; else uc_bad "INV-L11: the Headroom CLI was called while the session is routed" "$(head -c 200 "$UC_ROOT/headroom.log")"; fi
uc_jq "INV-L11: the route the session reads (settings env) is not edited" '.env.ANTHROPIC_BASE_URL == "http://127.0.0.1:9"' "$UC_HOME/.claude/settings.json"
uc_jq "consent is ask and the install is not grandfathered" '.consent == "ask" and .grandfathered == false' "$CLONE/skills-config.json"
uc_has "the record names the backup" "$CLONE/backups/lean-reset-pending" '^backup=.*/backups/'
uc_has "the record names the lean tree" "$CLONE/backups/lean-reset-pending" '^pending=lean-tree$'
uc_has "the record names the Headroom switch" "$CLONE/backups/lean-reset-pending" '^pending=headroom-off$'
FIRST_BACKUP="$(sed -n 's/^backup=//p' "$CLONE/backups/lean-reset-pending")"
if [ -f "$FIRST_BACKUP/manifest.json" ] && [ "$(ir_backups "$CLONE" | wc -l | tr -d ' ')" = 1 ]; then uc_ok "one backup exists and the record points at it"; else uc_bad "the record's backup is not the one backup taken"; fi
# the next session: no route, the same command
ir_reset defer-next "$IR_DOUBLE" "$IR_DOUBLE_TAG"
uc_rc "the next --reset, with no route, finishes" 0
uc_has "1/8 the route guard says ok now" "$UC_ROOT/defer-next.out" '1/8 route guard: ok:'
uc_has "2/8 it keeps the backup of the unfinished reset" "$UC_ROOT/defer-next.out" "2/8 backup: kept from the unfinished reset: $FIRST_BACKUP"
uc_has "5/8 the lean tree is applied" "$UC_ROOT/defer-next.out" '5/8 lean tree: applied'
uc_has "7/8 Headroom is off for the next session" "$UC_ROOT/defer-next.out" '7/8 headroom: off for the next session'
ir_is_lean "after the second run" "$CLONE"
if [ "$(cat "$UC_ROOT/headroom.log")" = "off --next-session" ]; then uc_ok "the Headroom CLI was called once, now"; else uc_bad "the Headroom CLI was not called exactly once" "$(head -c 200 "$UC_ROOT/headroom.log" | tr '\n' '|')"; fi
if [ ! -e "$CLONE/backups/lean-reset-pending" ]; then uc_ok "the unfinished-reset record is gone"; else uc_bad "the record is still there after the reset finished"; fi
if [ "$(ir_backups "$CLONE" | wc -l | tr -d ' ')" = 1 ]; then uc_ok "no second backup was taken"; else uc_bad "a second backup was taken over the half-reset install"; fi
UNDO="$(ir_line '8\/8 to undo' "$UC_ROOT/defer-next.out")"
case "$UNDO" in *"$FIRST_BACKUP"*) uc_ok "the undo points at the FIRST backup" ;; *) uc_bad "the undo does not point at the first backup" "$UNDO" ;; esac
uc_run "$UC_HOME" "$UC_WORK" SHELL=/bin/zsh PATH="$UC_HOME/.local/bin:$UC_PATH" -- bash -c "$UNDO"
uc_rc "the undo of the resumed reset runs" 0
if cmp -s "$UC_ROOT/defer-skills-config.before" "$CLONE/skills-config.json"; then uc_ok "the undo returns the install to what it was before the FIRST run began"; else uc_bad "the undo did not return skills-config.json to its original"; fi
ir_is_full "after the undo of the resumed reset" "$CLONE"

# ---------------------------------------------------------------------------------------------------------------------------------------------------------
# 3. a guard that cannot tell refuses: nothing changes
ir_copy refuse double
cp "$CLONE/skills-config.json" "$UC_ROOT/refuse-skills-config.before"
ir_call ANTHROPIC_BASE_URL=http://
cp "$UC_OUT" "$UC_ROOT/refuse.out"
cp "$UC_ERR" "$UC_ROOT/refuse.err"
uc_has "3. lean_reset reports a stop (status 1)" "$UC_ROOT/refuse.out" '^lean_reset: 1$'
uc_has "the refusal names the cause" "$UC_ROOT/refuse.err" 'refused, nothing was changed: refuse: ANTHROPIC_BASE_URL holds a value that is not a host and port'
if [ ! -e "$CLONE/backups" ]; then uc_ok "no backup was taken"; else uc_bad "a refused reset still took a backup"; fi
if cmp -s "$UC_ROOT/refuse-skills-config.before" "$CLONE/skills-config.json" && [ ! -e "$CLONE/profile.json" ]; then uc_ok "skills-config.json and the profile are untouched"; else uc_bad "a refused reset changed the consent or the profile"; fi
ir_is_full "after the refusal" "$CLONE"
if [ ! -s "$UC_ROOT/headroom.log" ]; then uc_ok "the Headroom CLI was not called"; else uc_bad "the Headroom CLI was called by a refused reset"; fi

# ---------------------------------------------------------------------------------------------------------------------------------------------------------
# 4. no Headroom CLI in the install: one warning, no switch, the rest happens
ir_drop_headroom() {   # (the clone of the copy) a release state that does not ship the Headroom CLI, its runtime list kept consistent: what an older ref looks like
  git -C "$CLONE" rm -q bin/heimdall-headroom || uc_fatal "cannot remove the Headroom CLI from the copy"
  grep -vx 'bin/heimdall-headroom' "$CLONE/release/runtime-files.txt" > "$CLONE/release/runtime-files.new" || true
  mv "$CLONE/release/runtime-files.new" "$CLONE/release/runtime-files.txt"
  git -C "$CLONE" add release/runtime-files.txt || uc_fatal "cannot stage the runtime list"
  git -c core.hooksPath=/dev/null -c commit.gpgsign=false -c user.email=use-case@example.invalid -c user.name=use-case \
    -C "$CLONE" commit -q --no-verify -m "a release without the Headroom CLI" || uc_fatal "cannot commit the release without the Headroom CLI"
}
ir_copy absent
ir_drop_headroom
ir_call
cp "$UC_OUT" "$UC_ROOT/absent.out"
cp "$UC_ERR" "$UC_ROOT/absent.err"
uc_has "4. lean_reset still finishes (status 0)" "$UC_ROOT/absent.out" '^lean_reset: 0$'
if [ "$(grep -c 'heimdall-headroom is not in this install' "$UC_ROOT/absent.err")" = 1 ]; then uc_ok "exactly one warning on stderr names the missing Headroom CLI"; else uc_bad "the missing Headroom CLI did not draw exactly one warning" "$(head -c 300 "$UC_ROOT/absent.err")"; fi
uc_has "7/8 says skipped, not in this install" "$UC_ROOT/absent.out" '7/8 headroom: skipped, not in this install'
uc_has "5/8 the lean tree is applied" "$UC_ROOT/absent.out" '5/8 lean tree: applied'
uc_jq "the lean profile is recorded" '.profile == "lean"' "$CLONE/profile.json"
if [ ! -e "$CLONE/backups/lean-reset-pending" ]; then uc_ok "an absent CLI is not a pending step (nothing to finish)"; else uc_bad "an absent Headroom CLI was recorded as pending"; fi

# ---------------------------------------------------------------------------------------------------------------------------------------------------------
# 5. the lean prompt: only against a GREEN receipt for THAT prompt; the user's settings are merged into, never replaced
ir_receipt() {   # VERDICT SHA -- commit evals/lean/prompt-parity.receipt.json in the clone (a full tree here): lean_reset reads HEAD, not the work tree
  mkdir -p "$CLONE/evals/lean"
  printf '{"verdict":"%s","lean_prompt_sha256":"%s"}\n' "$1" "$2" > "$CLONE/evals/lean/prompt-parity.receipt.json"
  git -C "$CLONE" add -f evals/lean/prompt-parity.receipt.json || uc_fatal "cannot stage the receipt"
  git -c core.hooksPath=/dev/null -c commit.gpgsign=false -c user.email=use-case@example.invalid -c user.name=use-case \
    -C "$CLONE" commit -q --no-verify -m "receipt $1" || uc_fatal "cannot commit the receipt"
}
ir_prompt_case() {   # NAME SETTINGS-TEXT VERDICT SHA -- a copy with the receipt committed and the user's settings.json written, then lean_reset; sets PROMPT_LINE
  ir_copy "$1" double
  ir_receipt "$3" "$4"
  printf '%b' "$2" > "$UC_HOME/.claude/settings.json"
  cp "$UC_HOME/.claude/settings.json" "$UC_ROOT/$1-settings.before"
  ir_call
  PROMPT_LINE="$(sed -n 's/^   6\/8 lean prompt: //p' "$UC_OUT" | head -1)"
}
PROMPT_SHA="$(ir_sha "$UC_TREE/agents/heimdall-lean.md")"
SKIPPED_RED='skipped, this release has no green prompt-parity receipt for it'

ir_prompt_case own '{\n    "agent": "my-own-agent",\n    "theme": "dark"\n}\n' green "$PROMPT_SHA"
if [ "$PROMPT_LINE" = 'skipped, the user settings already name another agent (kept)' ]; then uc_ok "5a. a green receipt does not override the user's own agent"; else uc_bad "5a. the user's own agent was not kept" "$PROMPT_LINE"; fi
uc_jq "...and their agent key is as they wrote it" '.agent == "my-own-agent"' "$UC_HOME/.claude/settings.json"

ir_prompt_case red '{\n    "theme": "dark"\n}\n' red "$PROMPT_SHA"
if [ "$PROMPT_LINE" = "$SKIPPED_RED" ]; then uc_ok "5b. a red receipt skips the lean prompt, in one line"; else uc_bad "5b. a red receipt did not skip it" "$PROMPT_LINE"; fi
if cmp -s "$UC_ROOT/red-settings.before" "$UC_HOME/.claude/settings.json"; then uc_ok "...and the user's settings.json is byte for byte what it was"; else uc_bad "5b. a skipped prompt still changed settings.json"; fi

ir_prompt_case stale '{\n    "theme": "dark"\n}\n' green 0000000000000000000000000000000000000000000000000000000000000000
if [ "$PROMPT_LINE" = "$SKIPPED_RED" ]; then uc_ok "5c. a green receipt for another prompt (stale hash) skips it"; else uc_bad "5c. a stale green receipt was accepted" "$PROMPT_LINE"; fi
uc_jq "...and no agent key was written" 'has("agent") | not' "$UC_HOME/.claude/settings.json"

ir_prompt_case green '{\n    "theme": "dark"\n}\n' green "$PROMPT_SHA"
if [ "$PROMPT_LINE" = 'selected (agent hmd:heimdall-lean in the user settings, from the next session)' ]; then uc_ok "5d. a green receipt for THIS prompt selects it"; else uc_bad "5d. the lean prompt was not selected" "$PROMPT_LINE"; fi
uc_jq "the agent key is hmd:heimdall-lean and their own key is kept" '.agent == "hmd:heimdall-lean" and .theme == "dark"' "$UC_HOME/.claude/settings.json"
uc_has "their 4-space indent is kept" "$UC_HOME/.claude/settings.json" '^    "agent": '
GREEN_BACKUP="$(ir_line '2\/8 backup' "$UC_OUT")"
ir_call
PROMPT_LINE="$(sed -n 's/^   6\/8 lean prompt: //p' "$UC_OUT" | head -1)"
if [ "$PROMPT_LINE" = 'already selected' ]; then uc_ok "5e. a second run finds it already selected"; else uc_bad "5e. a second run did not say already selected" "$PROMPT_LINE"; fi
# the backup taken BEFORE the key was written holds the settings slice without it: restoring that backup takes the key out again, byte for byte
uc_run "$UC_HOME" "$UC_WORK" -- python3 -I "$CLONE/bin/lib/lean_backup.py" restore "$GREEN_BACKUP"
uc_rc "restoring the backup taken before the agent key was written runs" 0
if cmp -s "$UC_ROOT/green-settings.before" "$UC_HOME/.claude/settings.json"; then uc_ok "INV-L9: the restore takes the agent key out again, settings.json is byte for byte what it was"; else uc_bad "INV-L9: settings.json is not what it was before the reset selected the prompt"; fi

uc_finish
