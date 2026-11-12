#!/usr/bin/env bash
#
# skills-session-nudge.test.sh -- 3.x M1, T7.1: a launch tells an operator at a terminal, at most once a day, that recommended skills are not installed.
#
#   bash test/skills-session-nudge.test.sh
#
# Plan: docs/superpowers/plans/2026-11-12-3x-m1-skill-registry.md (T7.1, "Consent model"). bin/heimdall prints ONE line after the banner:
# `N recommended skills not installed - hmd skills suggest`, only when consent is not `auto`, N > 0, the stamp $HEIMDALL_HOME/skills-nudge-stamp
# is not today's date, and a person is at the terminal (the consent gate's rule: a terminal on stdin and stdout, or the HMD_SKILLS_ASSUME seam).
# N is what `skills_cli_install.py suggest` counts (no `claude` call); the call is bounded and every failure of it is silence, never a blocked launch.
#
#   A. static: the launcher parses; the nudge is defined and called ONCE, after the banner and the update check and before the checkpoint load; its code
#      makes no `claude` call.
#   B. the nudge function, cut out of the launcher and run under `set -euo pipefail` in throwaway HOME / HEIMDALL_HOME / project dirs with a recording fake
#      of `claude` and a `python3` wrapper that can make `suggest` hang, fail or answer nonsense: shown once per day (the stamp), shown again the next
#      day, absent for a grandfathered `auto` (the launcher's own init) and for HMD_SKILLS_CONSENT=auto, shown for allowlist, absent when everything is
#      installed, absent and process-free off a terminal, silent and bounded when the count hangs, fails or is unreadable, silent when the consent
#      read fails; N is the manifest's own count, singular for one; no `claude` call ever.
#   C. the REAL launcher (HEIMDALL_TRACE_ORDER short-circuits just before the `claude` exec): at a terminal (the seam) the line follows the banner and
#      the launch still reaches `launch:task`; off a terminal (plain redirected stdio, no seam) nothing is printed and no stamp is written.
#
# SKILLS_SESSION_NUDGE_LAUNCHER=<path> points the suite at another copy of bin/heimdall (how the RED run against the pre-change launcher is made).
# Exit: 0 every check passed, 1 a check failed, 2 this machine cannot run the suite.
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SELF_DIR/.." && pwd)"
LAUNCHER="${SKILLS_SESSION_NUDGE_LAUNCHER:-$REPO/bin/heimdall}"
PASS=0; FAIL=0
ok()  { printf '  \033[32mPASS\033[0m %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAIL=$((FAIL + 1)); }
finish() {
  echo "--------------------------------------------------------------------"
  printf 'skills-session-nudge: %d passed, %d failed\n' "$PASS" "$FAIL"
  [ "$FAIL" -eq 0 ] || exit 1
  exit 0
}

PY="$(command -v python3 || true)"
[ -n "$PY" ] || { echo "FATAL: python3 not found"; exit 2; }
# the real interpreter, not a version-manager shim: the python3 wrapper below execs it
REALPY="$("$PY" -I -c 'import sys; print(sys.executable)' 2>/dev/null)"
case "$REALPY" in /*) ;; *) REALPY="" ;; esac
[ -n "$REALPY" ] && [ -x "$REALPY" ] || { echo "FATAL: cannot resolve the interpreter behind $PY"; exit 2; }
for f in "$LAUNCHER" "$REPO/skills.manifest.json" "$REPO/bin/lib/skills_consent.sh" "$REPO/bin/lib/skills_config.py" "$REPO/bin/lib/skills_cli_install.py"; do
  [ -f "$f" ] || { echo "FATAL: $f is missing"; exit 2; }
done
WORK="$(mktemp -d)" || { echo "FATAL: cannot make a temp dir"; exit 2; }
trap 'rm -rf "$WORK"' EXIT

echo "A. static"
if bash -n "$LAUNCHER" 2>"$WORK/syntax.err"; then ok "bin/heimdall parses (bash -n)"; else bad "bin/heimdall does not parse: $(head -c 300 "$WORK/syntax.err")"; fi
body() { sed -n "/^$1() {/,/^}/p" "$LAUNCHER"; }
line_of() { grep -n -x -m1 "$1" "$LAUNCHER" | cut -d: -f1; }
if [ "$(grep -c '^hmd_skills_nudge() {$' "$LAUNCHER")" -eq 1 ]; then ok "hmd_skills_nudge() is defined exactly once"; else bad "hmd_skills_nudge() is not defined exactly once"; fi
if [ "$(grep -c '^hmd_skills_nudge$' "$LAUNCHER")" -eq 1 ]; then ok "hmd_skills_nudge is called exactly once"; else bad "hmd_skills_nudge is not called exactly once"; fi
L_SETUP="$(line_of 'complete_first_run_setup "$@"')"; L_BANNER="$(line_of 'print_banner')"; L_UPDATE="$(line_of 'check_for_update')"
L_NUDGE="$(line_of 'hmd_skills_nudge')"; L_CKPT="$(line_of 'load_checkpoint_context')"
if [ -n "$L_NUDGE" ] && [ -n "$L_SETUP" ] && [ -n "$L_BANNER" ] && [ -n "$L_UPDATE" ] && [ -n "$L_CKPT" ] \
   && [ "$L_SETUP" -lt "$L_BANNER" ] && [ "$L_BANNER" -lt "$L_UPDATE" ] && [ "$L_UPDATE" -lt "$L_NUDGE" ] && [ "$L_NUDGE" -lt "$L_CKPT" ]; then
  ok "the call sits after the setup, the banner and the update check, before the checkpoint load"
else
  bad "the call is not between check_for_update and load_checkpoint_context (setup $L_SETUP banner $L_BANNER update $L_UPDATE nudge $L_NUDGE checkpoint $L_CKPT)"
fi
CODE="$(body hmd_skills_nudge | grep -v '^[[:space:]]*#')"
if [ -n "$CODE" ] && ! printf '%s\n' "$CODE" | grep -q 'claude'; then ok "the nudge code never calls claude"; else bad "the nudge code is missing or mentions claude"; fi
if printf '%s\n' "$CODE" | grep -q 'skills_config\.py.* get consent' && printf '%s\n' "$CODE" | grep -q 'skills_cli_install\.py'; then
  ok "consent is read with skills_config.py get consent and the count comes from skills_cli_install.py"
else
  bad "the nudge does not read consent with skills_config.py get consent / count with skills_cli_install.py"
fi

echo "B-C. behaviour"
FAKEBIN="$WORK/fakebin"; mkdir -p "$FAKEBIN"
# python3 wrapper: records every call; makes the `suggest` count (or the consent read) hang / fail / answer nonsense / answer a number on request
cat > "$FAKEBIN/python3" <<'SH'
#!/bin/sh
echo "python3 $*" >> "${NUDGE_PY_CALLS:-/dev/null}"
case "$*" in
  *"skills_config.py get consent"*)
    if [ "${NUDGE_CONSENT:-}" = fail ]; then echo "boom" >&2; exit 1; fi ;;
  *"skills_cli_install.py suggest"*)
    case "${NUDGE_SUGGEST:-}" in
      hang) exec sleep 30 ;;
      fail) echo "boom" >&2; exit 1 ;;
      garbage) echo "not a count"; exit 0 ;;
      count:*) echo "${NUDGE_SUGGEST#count:} skill(s) suggested for this project (this command installs nothing):"; exit 0 ;;
    esac ;;
esac
exec "$NUDGE_REAL_PY" "$@"
SH
# a recording fake of the Claude CLI: the nudge must never call it; the real launcher run only asks --version
cat > "$FAKEBIN/claude" <<'SH'
#!/bin/sh
echo "claude $*" >> "${NUDGE_CLAUDE_CALLS:-/dev/null}"
[ "${1:-}" = "--version" ] && { echo "1.99.0 (Claude Code)"; exit 0; }
exit 0
SH
chmod +x "$FAKEBIN/python3" "$FAKEBIN/claude"
# the harness: the two pieces of the launcher the nudge needs, cut out of the file under test, run under the launcher's own `set -euo pipefail`
HARNESS="$WORK/harness.sh"
cat > "$HARNESS" <<'SH'
set -euo pipefail
PLUGIN_DIR="$PLUGIN_DIR_UNDER_TEST"; HEIMDALL_HOME_DIR="$HEIMDALL_HOME"; HEIMDALL_TEARDOWN=0
eval "$(sed -n '/^_heimdall_home_ensure() {/,/^}/p' "$LAUNCHER_UNDER_TEST")"
eval "$(sed -n '/^hmd_skills_nudge() {/,/^}/p' "$LAUNCHER_UNDER_TEST")"
# shellcheck disable=SC1091
. "$PLUGIN_DIR/bin/lib/skills_consent.sh"
hmd_skills_nudge
SH
export NUDGE_REAL_PY="$REALPY"

new_case() { local d="$WORK/$1"; mkdir -p "$d/home" "$d/hh" "$d/proj"; : > "$d/py.calls"; : > "$d/claude.calls"; printf '%s' "$d"; }
# the launcher's own `init`: --marker-absent is a new install (consent ask), --marker-present a grandfathered one (consent auto)
init_cfg() { HEIMDALL_HOME="$1/hh" HOME="$1/home" "$REALPY" -I "$REPO/bin/lib/skills_config.py" init "$2" >/dev/null 2>&1; }
# nudge DIR [VAR=value ...]: the cut-out function in DIR/proj; stdout, stderr and the exit status land in DIR/out, DIR/err, DIR/rc
nudge() {
  local d="$1"; shift
  ( cd "$d/proj" && env HOME="$d/home" HEIMDALL_HOME="$d/hh" PATH="$FAKEBIN:$PATH" NUDGE_PY_CALLS="$d/py.calls" NUDGE_CLAUDE_CALLS="$d/claude.calls" \
      HMD_SKILLS_ASSUME=tty LAUNCHER_UNDER_TEST="$LAUNCHER" PLUGIN_DIR_UNDER_TEST="$REPO" "$@" bash "$HARNESS" </dev/null >"$d/out" 2>"$d/err"; echo $? > "$d/rc" )
}
# launch DIR [VAR=value ...]: the real launcher, short-circuited just before the claude exec by HEIMDALL_TRACE_ORDER; same DIR/out, err, rc, plus DIR/trace
launch() {
  local d="$1"; shift
  ( cd "$d/proj" && env HOME="$d/home" HEIMDALL_HOME="$d/hh" PATH="$FAKEBIN:$PATH" NUDGE_CLAUDE_CALLS="$d/claude.calls" ANTHROPIC_API_KEY=probe \
      HEIMDALL_TRACE_ORDER="$d/trace" HEIMDALL_NO_UPDATE_CHECK=1 "$@" bash "$LAUNCHER" "nudge wiring probe words" </dev/null >"$d/out" 2>"$d/err"; echo $? > "$d/rc" )
}
plain() { LC_ALL=C sed -e $'s/\033\\[[0-9;]*m//g' "$1"; }
TODAY="$(date +%Y-%m-%d)"
# the independent count: the manifest's recommended, installable entries (an empty project fires no `detected` entry)
EXPECT="$("$REALPY" -I -c 'import json, sys
doc = json.load(open(sys.argv[1]))
print(sum(1 for e in doc["entries"] if e["tier"] == "recommended" and e["install"] is True and e["kind"] in ("plugin", "github-skill")))' "$REPO/skills.manifest.json")"
case "$EXPECT" in ''|*[!0-9]*|0) echo "FATAL: the manifest holds no recommended installable entry ($EXPECT)"; exit 2 ;; esac
# silent DIR LABEL: nothing on stdout or stderr, exit 0, no claude call
silent() {
  if [ "$(cat "$1/rc" 2>/dev/null)" = 0 ] && [ ! -s "$1/out" ] && [ ! -s "$1/err" ] && [ ! -s "$1/claude.calls" ]; then ok "$2"
  else bad "$2 (rc $(cat "$1/rc" 2>/dev/null) out: $(head -c 200 "$1/out") err: $(head -c 200 "$1/err"))"; fi
}
# shown DIR COUNT SUFFIX LABEL: exactly one non-empty line, the banner text, exit 0, no claude call
shown() {
  local want="  ▸ $2 recommended skill$3 not installed - hmd skills suggest"
  if [ "$(cat "$1/rc" 2>/dev/null)" = 0 ] && [ "$(plain "$1/out" | grep -c .)" = 1 ] && plain "$1/out" | grep -qxF "$want" && [ ! -s "$1/err" ] && [ ! -s "$1/claude.calls" ]; then ok "$4"
  else bad "$4 (rc $(cat "$1/rc" 2>/dev/null) wanted: '$want' got: $(plain "$1/out" | head -c 300) err: $(head -c 200 "$1/err"))"; fi
}
stamped() { [ -f "$1/hh/skills-nudge-stamp" ] && [ "$(cat "$1/hh/skills-nudge-stamp")" = "$2" ]; }

# the slow runs go first, in the background: two real launches (about six seconds each) and the hanging count (three seconds, its bound)
CA="$(new_case launch-tty)";  init_cfg "$CA" --marker-absent; : > "$CA/hh/setup-done"
CB="$(new_case launch-notty)"; init_cfg "$CB" --marker-absent; : > "$CB/hh/setup-done"
CH="$(new_case hang)";        init_cfg "$CH" --marker-absent
( launch "$CA" HMD_SKILLS_ASSUME=tty ) &
( launch "$CB" ) &
( START=$SECONDS; nudge "$CH" NUDGE_SUGGEST=hang; echo $((SECONDS - START)) > "$CH/secs" ) &

# 1. a new install at a terminal with skills to suggest: one line, the manifest's count, today's stamp, no claude call
D="$(new_case shown)"; init_cfg "$D" --marker-absent; nudge "$D"
shown "$D" "$EXPECT" s "ask + terminal + recommended skills missing -> one line, N = the manifest's $EXPECT recommended skills"
if stamped "$D" "$TODAY"; then ok "the stamp holds today's date ($TODAY)"; else bad "the stamp is missing or not today's date: $(cat "$D/hh/skills-nudge-stamp" 2>/dev/null)"; fi
# 2. the same day again: silent, the stamp untouched
: > "$D/py.calls"; nudge "$D"
silent "$D" "the second launch of the same day is silent"
if [ ! -s "$D/py.calls" ]; then ok "a same-day launch starts no python at all"; else bad "a same-day launch still ran python: $(head -c 200 "$D/py.calls")"; fi
# 3. another day: shown again, stamp moves to today
printf '2000-01-01\n' > "$D/hh/skills-nudge-stamp"; nudge "$D"
shown "$D" "$EXPECT" s "a stamp from another day -> shown again"
if stamped "$D" "$TODAY"; then ok "the stamp moves to today"; else bad "the stamp did not move to today: $(cat "$D/hh/skills-nudge-stamp" 2>/dev/null)"; fi
printf 'garbage that is not a date' > "$D/hh/skills-nudge-stamp"; nudge "$D"
shown "$D" "$EXPECT" s "an unreadable stamp counts as not today -> shown"
# 4. grandfathered auto (the launcher's own init with the setup marker present): silent, no stamp, and the same by the operator's environment
D="$(new_case auto)"; init_cfg "$D" --marker-present; nudge "$D"
silent "$D" "consent auto (grandfathered by the launcher's init) -> silent"
if [ ! -e "$D/hh/skills-nudge-stamp" ]; then ok "auto writes no stamp"; else bad "auto wrote a stamp"; fi
D="$(new_case env-auto)"; init_cfg "$D" --marker-absent; nudge "$D" HMD_SKILLS_CONSENT=auto
silent "$D" "HMD_SKILLS_CONSENT=auto beats the config file's ask -> silent"
# 5. allowlist: shown
D="$(new_case allowlist)"; init_cfg "$D" --marker-absent; HEIMDALL_HOME="$D/hh" HOME="$D/home" "$REALPY" -I "$REPO/bin/lib/skills_config.py" set consent allowlist >/dev/null 2>&1
nudge "$D"
shown "$D" "$EXPECT" s "consent allowlist -> shown"
# 6. everything installed: the plugins enabled in ~/.claude/settings.json, the github skills in ~/.claude/skills -> silent, no stamp
D="$(new_case installed)"; init_cfg "$D" --marker-absent; mkdir -p "$D/home/.claude/skills"
"$REALPY" -I -c 'import json, os, sys
doc, home = json.load(open(sys.argv[1])), sys.argv[2]
rec = [e for e in doc["entries"] if e["tier"] == "recommended" and e["install"] is True]
json.dump({"enabledPlugins": {e["ref"]: True for e in rec if e["kind"] == "plugin"}}, open(os.path.join(home, ".claude", "settings.json"), "w"))
for e in rec:
    if e["kind"] == "github-skill":
        os.makedirs(os.path.join(home, ".claude", "skills", e["id"]), exist_ok=True)' "$REPO/skills.manifest.json" "$D/home"
nudge "$D"
silent "$D" "every recommended skill installed -> silent"
if [ ! -e "$D/hh/skills-nudge-stamp" ]; then ok "nothing to show writes no stamp"; else bad "a stamp was written with nothing to show"; fi
# 7. off a terminal: the seam and plain redirected stdio; no python start, no stamp
D="$(new_case notty)"; init_cfg "$D" --marker-absent; nudge "$D" HMD_SKILLS_ASSUME=notty
silent "$D" "HMD_SKILLS_ASSUME=notty -> silent"
if [ ! -s "$D/py.calls" ] && [ ! -e "$D/hh/skills-nudge-stamp" ]; then ok "off a terminal no python starts and no stamp is written"; else bad "off a terminal the nudge ran python or wrote a stamp"; fi
D="$(new_case redirected)"; init_cfg "$D" --marker-absent; nudge "$D" HMD_SKILLS_ASSUME=
silent "$D" "stdin and stdout redirected, no seam -> silent"
# 8. the count fails or is unreadable: silent, the launch goes on (exit 0 under set -e), no stamp, so tomorrow tries again
for mode in fail garbage; do
  D="$(new_case "suggest-$mode")"; init_cfg "$D" --marker-absent; nudge "$D" NUDGE_SUGGEST=$mode
  silent "$D" "suggest $mode -> silent, exit 0"
  if [ ! -e "$D/hh/skills-nudge-stamp" ]; then ok "suggest $mode -> no stamp"; else bad "suggest $mode wrote a stamp"; fi
done
D="$(new_case consent-fail)"; init_cfg "$D" --marker-absent; nudge "$D" NUDGE_CONSENT=fail
silent "$D" "an unreadable consent mode -> silent (never read as ask), exit 0"
# 9. N is read from the count's own first line; one skill is singular
D="$(new_case one)"; init_cfg "$D" --marker-absent; nudge "$D" NUDGE_SUGGEST=count:1
shown "$D" 1 "" "a count of 1 -> '1 recommended skill not installed'"
D="$(new_case zero)"; init_cfg "$D" --marker-absent; nudge "$D" NUDGE_SUGGEST=count:0
silent "$D" "a count of 0 -> silent"

wait
# the hanging count: bounded (3 s) and silent, no stamp; the launcher would go on
SECS="$(cat "$CH/secs" 2>/dev/null || echo 99)"
silent "$CH" "suggest that hangs -> silent, exit 0"
if [ "$SECS" -le 8 ]; then ok "a hanging suggest is cut off (${SECS}s <= 8s bound)"; else bad "a hanging suggest held the launch ${SECS}s"; fi
if [ ! -e "$CH/hh/skills-nudge-stamp" ]; then ok "a hanging suggest writes no stamp"; else bad "a hanging suggest wrote a stamp"; fi
# the real launcher
if [ "$(cat "$CA/rc" 2>/dev/null)" = 0 ] && grep -q '^launch:task$' "$CA/trace" 2>/dev/null; then ok "the real launcher at a terminal still reaches the launch (exit 0, launch:task)"
else bad "the real launcher at a terminal did not reach the launch (rc $(cat "$CA/rc" 2>/dev/null) trace: $(tr '\n' ' ' < "$CA/trace" 2>/dev/null) err: $(head -c 300 "$CA/err"))"; fi
# the launcher writes the project's CLAUDE.md before the nudge runs, which can fire a `detected` entry: the count is what `suggest` says in that same project
REAL_N="$(cd "$CA/proj" && HOME="$CA/home" HEIMDALL_HOME="$CA/hh" "$REALPY" -I "$REPO/bin/lib/skills_cli_install.py" suggest 2>/dev/null | sed -n 's/^\([0-9][0-9]*\) skill.*/\1/p' | head -1)"
case "$REAL_N" in ''|*[!0-9]*) REAL_N=0 ;; esac
if [ "$REAL_N" -ge "$EXPECT" ]; then ok "the launch project's suggest count ($REAL_N) holds the $EXPECT recommended skills"; else bad "the launch project's suggest count is $REAL_N, below the $EXPECT recommended skills"; fi
NL="$(plain "$CA/out" | grep -n -x -F "  ▸ $REAL_N recommended skills not installed - hmd skills suggest" | head -1 | cut -d: -f1)"
CWDL="$(plain "$CA/out" | grep -n 'cwd:' | head -1 | cut -d: -f1)"
if [ -n "$NL" ] && [ -n "$CWDL" ] && [ "$NL" -gt "$CWDL" ] && [ "$(plain "$CA/out" | grep -c 'recommended skills not installed')" = 1 ]; then ok "the real launcher prints the line once, after the banner (line $NL, banner ends at $CWDL)"
else bad "the real launcher's output lacks the nudge after the banner (nudge line '${NL}' cwd line '${CWDL}'): $(plain "$CA/out" | tail -5 | head -c 400)"; fi
if stamped "$CA" "$TODAY"; then ok "the real launcher wrote today's stamp"; else bad "the real launcher left no stamp for today"; fi
if [ "$(cat "$CB/rc" 2>/dev/null)" = 0 ] && grep -q '^launch:task$' "$CB/trace" 2>/dev/null && ! plain "$CB/out" | grep -q 'recommended skill' && ! grep -q 'recommended skill' "$CB/err" && [ ! -e "$CB/hh/skills-nudge-stamp" ]; then
  ok "the real launcher off a terminal prints no nudge and writes no stamp (and still launches)"
else bad "the real launcher off a terminal showed the nudge, wrote a stamp or did not launch (rc $(cat "$CB/rc" 2>/dev/null))"; fi
finish
