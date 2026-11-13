#!/usr/bin/env bash
# test/hmd-update-pending.test.sh
#
# bin/heimdall-update-pending answers ONE question for the seamless-restart feature (docs/superpowers/plans/2026-11-13-seamless-update-restart.md,
# Task W1-hmd-pending): is a newer claude, or a newer hmd, installed than the one this session started with? The Stop hook and the restart gate ask it
# before anything else, and a wrong "yes" ends a running session, so it fails CLOSED: any input it cannot read means exit 1 and no output.
#
# This drives the REAL launcher and the REAL helper (bin/lib/hmd_update_pending.py) against throwaway plugin trees (a real git repo, a real tag, a real
# .claude-plugin/plugin.json) and fake `heimdall-cc-selfheal pending` commands, and pins:
#   * the hmd half: newer, same, downgraded (not pending); each canonical version source on its own (git describe, plugin.json); no source; the two sources
#     disagreeing; a garbled manifest
#   * the claude half: passed through from the cc command, --pid forwarded; a command that crashes, prints garbage, prints something a hook must not echo
#     (metacharacters), is missing, or hangs is "unreadable" -- and an unreadable half vetoes the whole answer, hmd half included
#   * "fully installed" means the update FINISHED, not that its files are on disk: bin/heimdall-autoupdate runs the verified installer inside a
#     ${TMPDIR:-/tmp}/heimdall-apply.* workdir and removes it only after the installer exits (the one completion marker that updater has), and install.sh
#     updates with `git checkout`, which holds .git/index.lock while the manifest is already new and HEAD still old (measured)
#   * the same precedence and the same flags as bin/heimdall-autoupdate's installed_version (a tripwire: the two files cannot drift apart unnoticed)
#   * the usage: --json, argument errors, a GIT_DIR inherited from a parent process never redirects the answer
#   * the suite can go RED: four one-line breaks of the helper each make a case give the wrong answer
set -u

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="$REPO/bin/heimdall-update-pending"
LIB="$REPO/bin/lib/hmd_update_pending.py"
AUTOUPDATE="$REPO/bin/heimdall-autoupdate"
PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; [ -n "${2:-}" ] && printf '       %s\n' "$2"; }

# what the operator exports in their own shell never changes a case; a case that needs a setting passes it
unset HMD_UPDATE_PLUGIN_DIR HMD_UPDATE_CC_PENDING_CMD HMD_UPDATE_CMD_TIMEOUT_S HMD_UPDATE_PENDING_DEBUG GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE

TMPROOT="$(mktemp -d)" || exit 1
trap 'rm -rf "$TMPROOT"' EXIT

echo "hmd-update-pending"

command -v python3 >/dev/null 2>&1 || { bad "0. python3 is required"; exit 1; }
command -v git >/dev/null 2>&1 || { bad "0. git is required"; exit 1; }
[ -x "$BIN" ] || { bad "0. bin/heimdall-update-pending is missing or not executable"; exit 1; }
[ -f "$LIB" ] || { bad "0. bin/lib/hmd_update_pending.py is missing"; exit 1; }
if bash -n "$BIN" 2>/dev/null; then ok "0. bin/heimdall-update-pending parses"; else bad "0. bin/heimdall-update-pending does not parse"; fi
if python3 -I -c 'import py_compile, sys; py_compile.compile(sys.argv[1], cfile=sys.argv[2], doraise=True)' "$LIB" "$TMPROOT/lib.pyc" 2>/dev/null; then
  ok "0. bin/lib/hmd_update_pending.py compiles"
else
  bad "0. bin/lib/hmd_update_pending.py does not compile"
fi

# python3 straight to the real interpreter first on PATH: a version-manager shim (pyenv) costs ~0.4s a call, and this suite starts python for every case
PYREAL="$(python3 -I -c 'import sys; print(sys.executable)' 2>/dev/null)"
mkdir -p "$TMPROOT/pybin"
if [ -n "$PYREAL" ] && [ -x "$PYREAL" ]; then ln -s "$PYREAL" "$TMPROOT/pybin/python3"; fi
export PATH="$TMPROOT/pybin:$PATH"

# ---- fixtures -------------------------------------------------------------------------------------------------------------------------------------
g() { git -c user.email=fixture@example.invalid -c user.name=fixture -c commit.gpgsign=false -c core.hooksPath=/dev/null "$@"; }
mkplug() {  # mkplug <dir> <manifest version | -> <git tag version | ->: a plugin tree whose two canonical version sources are the given ones
  local d="$1" mv="$2" tv="$3"
  mkdir -p "$d"
  if [ "$mv" != "-" ]; then mkdir -p "$d/.claude-plugin"; printf '{"name":"hmd","version":"%s"}\n' "$mv" >"$d/.claude-plugin/plugin.json"; fi
  if [ "$tv" != "-" ]; then
    printf 'fixture\n' >"$d/README"
    ( cd "$d" && g init -q . && g add -A && g commit -q -m fixture && g tag "v$tv" ) >/dev/null 2>&1
  fi
}
P_NEW="$TMPROOT/p-new";           mkplug "$P_NEW" 2.4.2 2.4.2         # on disk now: 2.4.2, both sources agree
P_MANIFEST="$TMPROOT/p-manifest"; mkplug "$P_MANIFEST" 2.4.2 -        # no repository (a tarball install): plugin.json alone
P_GIT="$TMPROOT/p-git";           mkplug "$P_GIT" - 2.4.2             # no manifest: the tag alone
P_NONE="$TMPROOT/p-none";         mkplug "$P_NONE" - -                # neither source
P_DISAGREE="$TMPROOT/p-disagree"; mkplug "$P_DISAGREE" 2.4.5 2.4.2    # manifest new, HEAD's tag old: what git checkout leaves while it is still writing
P_GARBLED="$TMPROOT/p-garbled";   mkplug "$P_GARBLED" - 2.4.2; mkdir -p "$P_GARBLED/.claude-plugin"; printf '{' >"$P_GARBLED/.claude-plugin/plugin.json"
P_OTHER="$TMPROOT/p-other";       mkplug "$P_OTHER" - 2.4.9           # some OTHER repository, for the inherited-GIT_DIR case
if [ "$(g -C "$P_NEW" describe --tags --abbrev=0 --match 'v[0-9]*' 2>/dev/null)" = "v2.4.2" ]; then ok "0. fixture: the throwaway plugin tree is a repository tagged v2.4.2"; else bad "0. fixture: git could not tag the throwaway plugin tree"; exit 1; fi

# fake `heimdall-cc-selfheal pending`: what each prints and exits with
mkdir -p "$TMPROOT/cc"
mkfake() { printf '#!/bin/sh\n%s\n' "$2" >"$TMPROOT/cc/$1"; chmod +x "$TMPROOT/cc/$1"; }
mkfake pending  'printf "claude 2.1.319 2.1.322\n"; exit 0'
mkfake current  'exit 1'
mkfake crash    'echo boom >&2; exit 2'
mkfake garbage  'printf "not a pending line\n"; exit 0'
mkfake inject   'printf "claude 2.1.319 2.1.322;touch '"$TMPROOT"'/pwned\n"; exit 0'
mkfake hang     'exec sleep 30'
mkfake recorder 'printf "%s\n" "$*" >'"$TMPROOT"'/cc.args; printf "claude 2.1.319 2.1.322\n"; exit 0'
CC_PENDING="'$TMPROOT/cc/pending'"
CC_CURRENT="'$TMPROOT/cc/current'"
mkdir -p "$TMPROOT/fakegit"
printf '#!/bin/sh\nexec sleep 30\n' >"$TMPROOT/fakegit/git"; chmod +x "$TMPROOT/fakegit/git"

APPLY_TMP="$TMPROOT/apply-tmp"; mkdir -p "$APPLY_TMP"   # the TMPDIR the helper sees: where it looks for a running installer's heimdall-apply.* workdir
BIN_UNDER_TEST="$BIN"
DBG="HMD_UPDATE_PENDING_DEBUG=1"
PLUG="$P_NEW"
CC="$CC_CURRENT"
OUT=""; ERR=""; RC=0

runp() {  # runp [VAR=value ...] -- <heimdall-update-pending args>: sets OUT ERR RC; PLUG and CC are the case's plugin tree and fake claude command
  local envs=()
  while [ "$#" -gt 0 ] && [ "$1" != "--" ]; do envs+=("$1"); shift; done
  [ "$#" -gt 0 ] && shift
  OUT="$(env HMD_UPDATE_PLUGIN_DIR="$PLUG" HMD_UPDATE_CC_PENDING_CMD="$CC" TMPDIR="$APPLY_TMP" ${envs[@]+"${envs[@]}"} "$BIN_UNDER_TEST" "$@" 2>"$TMPROOT/err")"
  RC=$?
  ERR="$(cat "$TMPROOT/err")"
}
expect() {  # expect <name> <exit status> <stdout> [text that must be in stderr]
  local name="$1" rc="$2" out="$3" why="${4:-}"
  if [ "$RC" != "$rc" ] || [ "$OUT" != "$out" ]; then bad "$name" "want rc=$rc out=[$out]; got rc=$RC out=[$OUT] err=[$ERR]"; return; fi
  if [ -n "$why" ] && ! printf '%s' "$ERR" | grep -qF -- "$why"; then bad "$name" "exit and output are right but stderr lacks [$why]: [$ERR]"; return; fi
  ok "$name"
}
PEND_C='claude 2.1.319 2.1.322'

# ---- 1. the hmd half --------------------------------------------------------------------------------------------------------------------------------
PLUG="$P_NEW"; CC="$CC_CURRENT"
runp -- --launcher-start-hmd 2.4.1;  expect "1. hmd newer than at launcher start: one hmd line" 0 'hmd 2.4.1 2.4.2'
runp -- --launcher-start-hmd 2.4.2;  expect "1. hmd the same as at launcher start: nothing" 1 ''
runp -- --launcher-start-hmd 2.4.3;  expect "1. hmd downgraded since launcher start: not pending, nothing" 1 ''
runp -- --launcher-start-hmd v2.4.1; expect "1. a leading v on the launcher's version is accepted" 0 'hmd 2.4.1 2.4.2'
runp -- --launcher-start-hmd 2.4.9;  expect "1. 2.4.9 -> 2.4.10 compares numerically, not as text" 1 ''
PLUG="$TMPROOT/p-ten"; mkplug "$PLUG" 2.4.10 2.4.10
runp -- --launcher-start-hmd 2.4.9;  expect "1. 2.4.9 -> 2.4.10 is pending" 0 'hmd 2.4.9 2.4.10'

# ---- 2. the claude half and both -------------------------------------------------------------------------------------------------------------------
PLUG="$P_NEW"; CC="$CC_PENDING"
runp -- --launcher-start-hmd 2.4.2;  expect "2. claude only (hmd unchanged): one claude line" 0 "$PEND_C"
runp -- --launcher-start-hmd 2.4.1;  expect "2. both pending: claude line first, then hmd" 0 "$PEND_C"$'\n''hmd 2.4.1 2.4.2'
runp -- --launcher-start-hmd 2.4.1 --json;  expect "2. --json both: one object a hook can embed as its pending field" 0 '{"claude":["2.1.319","2.1.322"],"hmd":["2.4.1","2.4.2"]}'
runp -- --launcher-start-hmd 2.4.2 --json;  expect "2. --json claude only: the other half is absent" 0 '{"claude":["2.1.319","2.1.322"]}'
CC="$CC_CURRENT"
runp -- --launcher-start-hmd 2.4.1 --json;  expect "2. --json hmd only: the other half is absent" 0 '{"hmd":["2.4.1","2.4.2"]}'
runp -- --launcher-start-hmd 2.4.2 --json;  expect "2. --json nothing pending: no output, exit 1" 1 ''

# ---- 3. each canonical version source, and what an unreadable one does -----------------------------------------------------------------------------
CC="$CC_PENDING"
PLUG="$P_MANIFEST"; runp -- --launcher-start-hmd 2.4.1; expect "3. plugin.json alone (no repository) is the fallback source" 0 "$PEND_C"$'\n''hmd 2.4.1 2.4.2'
PLUG="$P_GIT";      runp -- --launcher-start-hmd 2.4.1; expect "3. git describe alone (no manifest) is read" 0 "$PEND_C"$'\n''hmd 2.4.1 2.4.2'
PLUG="$P_NONE";     runp "$DBG" -- --launcher-start-hmd 2.4.1; expect "3. no version source at all: nothing, even though claude is pending (fail closed)" 1 '' "no version source"
PLUG="$P_DISAGREE"; runp "$DBG" -- --launcher-start-hmd 2.4.1; expect "3. git describe 2.4.2 vs plugin.json 2.4.5: an error, nothing, even though claude is pending" 1 '' "plugin.json says 2.4.5"
PLUG="$P_GARBLED";  runp "$DBG" -- --launcher-start-hmd 2.4.1; expect "3. a manifest that is not JSON: nothing, even though claude is pending" 1 '' "plugin.json"
PLUG="$P_DISAGREE"; runp -- --launcher-start-hmd 2.4.1;        expect "3. without HMD_UPDATE_PENDING_DEBUG a refusal is silent on stderr too" 1 ''
if [ -z "$ERR" ]; then ok "3. ... and stderr is empty"; else bad "3. stderr is empty without the debug seam" "got [$ERR]"; fi

# ---- 4. fully installed: the update finished -------------------------------------------------------------------------------------------------------
PLUG="$P_NEW"; CC="$CC_PENDING"
AD="$APPLY_TMP/heimdall-apply.Ab12Cd"
mkdir -p "$AD"; : >"$AD/install.sh"
runp "$DBG" -- --launcher-start-hmd 2.4.1; expect "4. a fresh heimdall-apply.* workdir (installer still running): nothing, claude pending or not" 1 '' "installer is still running"
touch -t 202001010000 "$AD"
runp -- --launcher-start-hmd 2.4.1;        expect "4. a workdir hours old (installer killed, never cleaned up) is abandoned: pending again" 0 "$PEND_C"$'\n''hmd 2.4.1 2.4.2'
rm -rf "$AD"; mkdir -p "$AD"
runp "$DBG" -- --launcher-start-hmd 2.4.1; expect "4. a fresh workdir again: nothing" 1 '' "installer is still running"
rm -rf "$AD"
runp -- --launcher-start-hmd 2.4.1;        expect "4. the installer finished and removed its workdir: pending" 0 "$PEND_C"$'\n''hmd 2.4.1 2.4.2'
mkdir -p "$APPLY_TMP/heimdall-apply-other"; : >"$APPLY_TMP/heimdall-apply.file"
runp -- --launcher-start-hmd 2.4.1;        expect "4. a differently named dir and a plain FILE named like the workdir are no running installer" 0 "$PEND_C"$'\n''hmd 2.4.1 2.4.2'
rm -rf "$APPLY_TMP/heimdall-apply-other" "$APPLY_TMP/heimdall-apply.file"
: >"$P_NEW/.git/index.lock"
runp "$DBG" -- --launcher-start-hmd 2.4.1; expect "4. .git/index.lock (git checkout mid-flight: manifest already new, HEAD still old): nothing" 1 '' "index.lock"
rm -f "$P_NEW/.git/index.lock"
runp -- --launcher-start-hmd 2.4.1;        expect "4. the checkout finished and the lock is gone: pending" 0 "$PEND_C"$'\n''hmd 2.4.1 2.4.2'

# ---- 5. a claude half that cannot be read vetoes everything ----------------------------------------------------------------------------------------
PLUG="$P_NEW"
CC="'$TMPROOT/cc/crash'";   runp "$DBG" -- --launcher-start-hmd 2.4.1; expect "5. cc command crashes (exit 2): nothing, hmd's own pending line included" 1 '' "(exit 2)"
CC="'$TMPROOT/cc/garbage'"; runp "$DBG" -- --launcher-start-hmd 2.4.1; expect "5. cc command prints something that is not a claude line: nothing" 1 '' "not a pending line"
CC="'$TMPROOT/cc/inject'";  runp "$DBG" -- --launcher-start-hmd 2.4.1; expect "5. a claude line with shell metacharacters is never echoed: nothing" 1 '' "answered"
if [ ! -e "$TMPROOT/pwned" ]; then ok "5. ... and nothing was executed from that line"; else bad "5. the metacharacter line was executed"; fi
CC="'$TMPROOT/cc/nonexistent'"; runp "$DBG" -- --launcher-start-hmd 2.4.1; expect "5. cc command does not exist: nothing" 1 '' "cannot start"
CC="'$TMPROOT/cc/hang'";    runp "$DBG" HMD_UPDATE_CMD_TIMEOUT_S=1 -- --launcher-start-hmd 2.4.1; expect "5. cc command hangs: killed at the timeout, nothing" 1 '' "did not answer within 1s"
CC="'$TMPROOT/cc/recorder' pending"; rm -f "$TMPROOT/cc.args"
runp -- --launcher-start-hmd 2.4.2 --pid 4242; expect "5. --pid is forwarded to the cc command" 0 "$PEND_C"
if [ "$(cat "$TMPROOT/cc.args" 2>/dev/null)" = "pending --pid 4242" ]; then ok "5. ... as its own --pid argument"; else bad "5. the cc command was called with [$(cat "$TMPROOT/cc.args" 2>/dev/null)]"; fi
rm -f "$TMPROOT/cc.args"
runp -- --launcher-start-hmd 2.4.2; expect "5. without --pid none is forwarded" 0 "$PEND_C"
if [ "$(cat "$TMPROOT/cc.args" 2>/dev/null)" = "pending" ]; then ok "5. ... the cc command got just its subcommand"; else bad "5. the cc command was called with [$(cat "$TMPROOT/cc.args" 2>/dev/null)]"; fi

# ---- 6. the arguments, and the environment the helper runs in --------------------------------------------------------------------------------------
PLUG="$P_NEW"; CC="$CC_PENDING"
runp --;                                           expect "6. no arguments: a usage error (exit 2), nothing on stdout" 2 ''
runp -- --bogus;                                   expect "6. an unknown option is a usage error (exit 2)" 2 ''
runp "$DBG" -- --launcher-start-hmd abc;           expect "6. a launcher version that is not X.Y.Z: nothing, fail closed" 1 '' "launcher-start-hmd"
runp "$DBG" -- --launcher-start-hmd '';            expect "6. an EMPTY launcher version (unset variable): nothing, fail closed" 1 '' "launcher-start-hmd"
runp "$DBG" -- --launcher-start-hmd 2.4.1 --pid abc; expect "6. a --pid that is no number: nothing" 1 '' "--pid"
CC="$CC_CURRENT"
runp "GIT_DIR=$P_OTHER/.git" -- --launcher-start-hmd 2.4.1; expect "6. a GIT_DIR inherited from a parent process (another repo, tag v2.4.9) does not redirect git" 0 'hmd 2.4.1 2.4.2'
runp "PATH=$TMPROOT/fakegit:$PATH" "$DBG" HMD_UPDATE_CMD_TIMEOUT_S=1 -- --launcher-start-hmd 2.4.1; expect "6. a git that hangs is killed at the timeout: nothing" 1 '' "did not answer within 1s"

# ---- 7. the same sources and the same precedence as bin/heimdall-autoupdate's installed_version ----------------------------------------------------
SH_BODY="$(awk '/^installed_version\(\)/{f=1} f{print} f&&/^}/{exit}' "$AUTOUPDATE")"
PY_BODY="$(awk '/^def resolve_hmd_version\(/{f=1;print;next} f&&/^def /{exit} f{print}' "$LIB")"
line_of() { printf '%s\n' "$2" | grep -n -F -- "$1" | head -1 | cut -d: -f1; }
SH_G="$(line_of 'describe' "$SH_BODY")"; SH_M="$(line_of 'plugin.json' "$SH_BODY")"
PY_G="$(line_of 'describe_version(' "$PY_BODY")"; PY_M="$(line_of 'manifest_version(' "$PY_BODY")"
if [ -n "$SH_G" ] && [ -n "$SH_M" ] && [ "$SH_G" -lt "$SH_M" ]; then ok "7. installed_version reads git describe before plugin.json"; else bad "7. could not read installed_version's source order" "describe line [$SH_G] plugin.json line [$SH_M]"; fi
if [ -n "$PY_G" ] && [ -n "$PY_M" ] && [ "$PY_G" -lt "$PY_M" ]; then ok "7. the helper reads git describe before plugin.json, in the same order"; else bad "7. the helper's source order differs from installed_version" "describe line [$PY_G] manifest line [$PY_M]"; fi
if grep -qF "describe --tags --abbrev=0 --match 'v[0-9]*'" "$AUTOUPDATE" && grep -qF 'DESCRIBE = ("describe", "--tags", "--abbrev=0", "--match", "v[0-9]*")' "$LIB"; then ok "7. git describe is called with the same flags in both"; else bad "7. the git describe flags differ between installed_version and the helper"; fi
if grep -qF 'v?([0-9]+\.[0-9]+\.[0-9]+)' "$AUTOUPDATE" && grep -qF 'v?([0-9]+\.[0-9]+\.[0-9]+)' "$LIB"; then ok "7. a version is normalised with the same pattern in both (norm_semver)"; else bad "7. the version pattern differs between norm_semver and the helper"; fi
if grep -qF 'heimdall-apply.' "$AUTOUPDATE" && grep -qF 'APPLY_DIR_PREFIX = "heimdall-apply."' "$LIB" && grep -qF "rm -rf '\$workdir'" "$AUTOUPDATE"; then
  ok "7. the completion marker the helper reads (heimdall-apply.* removed after the installer) is still what the updater writes"
else
  bad "7. the updater's workdir marker and the helper's no longer match"
fi

# ---- 8. the suite can go RED: one-line breaks of the helper must each change an answer --------------------------------------------------------------
MUT="$TMPROOT/mut"; mkdir -p "$MUT/bin/lib"
cp "$BIN" "$MUT/bin/heimdall-update-pending"; chmod +x "$MUT/bin/heimdall-update-pending"
mutate() {  # mutate <sed expression>: the helper with one line broken, at $MUT; false when the break did not change the file
  sed -e "$1" "$LIB" >"$MUT/bin/lib/hmd_update_pending.py"
  ! cmp -s "$LIB" "$MUT/bin/lib/hmd_update_pending.py"
}
caught() {  # caught <name> <sed expression>: the case just set up (PLUG, CC, an optional fixture state, start 2.4.1 unless START) must now answer differently
  local name="$1"
  if ! mutate "$2"; then bad "8. $name: the break did not apply (the helper's line changed)"; return; fi
  BIN_UNDER_TEST="$MUT/bin/heimdall-update-pending"
  runp -- --launcher-start-hmd "${START:-2.4.1}"
  BIN_UNDER_TEST="$BIN"
  if [ "$RC" = 1 ] && [ -z "$OUT" ]; then bad "8. $name: the broken helper still gave the right answer"; else ok "8. $name: caught (the broken helper answered rc=$RC out=[$OUT])"; fi
}
CC="$CC_CURRENT"
PLUG="$P_NEW";      START=2.4.2 caught "'newer' compared with >= instead of >" 's/if version_tuple(now) > version_tuple(start):/if version_tuple(now) >= version_tuple(start):/'
PLUG="$P_DISAGREE"; caught "the two-source disagreement no longer vetoes" 's/from_git != from_manifest/False/'
mkdir -p "$AD"
PLUG="$P_NEW";      caught "a running installer is no longer noticed" 's/if apply_in_flight():/if False:/'
rm -rf "$AD"
: >"$P_NEW/.git/index.lock"
caught "git's index.lock is no longer noticed" 's/if lock and os.path.lexists(lock):/if False:/'
rm -f "$P_NEW/.git/index.lock"

echo
printf '%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
