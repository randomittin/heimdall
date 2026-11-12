#!/usr/bin/env bash
# test/guardrail-off-bash.test.sh -- the operator switches of the RECOMMENDED guards in bin/heimdall-precheck-bash (task T6.1 of
# docs/superpowers/plans/2026-11-12-3x-m1-skill-registry.md). ci-waste-guard, disk-floor, sweep-guard and wait-guard each ask
# bin/lib/hmd_guardrail_enabled.sh, once their own pre-filter matched and before their helper runs, whether the operator switched them off
# (`hmd guardrails off <id>` -> a line in $HEIMDALL_HOME/guardrails-off). Proven through the REAL hook, libs and manifest in a throwaway plugin root:
#   INV-G2  no guardrails-off file: each of the four denies its canonical bad command, as before
#   INV-G3  one id in the file: that command is allowed, silently; the other three still deny theirs
#   INV-G1  core ids in the file change nothing; a manifest that calls a guard core keeps it on; with EVERY id listed the kill guard and the commit
#           secret scan (core, no switch) still deny; the hook asks the switch for exactly the four ids, never a core one
#   INV-G5  any doubt keeps the guard on: no lib, no manifest, a lib with no function, an answer that is not exactly 1 (0, 2, 127)
#   INV-G7  a relative HEIMDALL_HOME (the cwd: a repository could ship the file) is no switch; with HEIMDALL_HOME empty the operator's ~/.heimdall is
# INV-G6 (the env overrides keep their semantics) is the guards' own suites: test/ci-waste-guard, disk-floor, sweep-guard and wait-guard.test.sh.
set -u

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOOK="$REPO/bin/heimdall-precheck-bash"
MANIFEST="$REPO/guardrails.manifest.json"
LIBS=(hmd_guardrail_enabled.sh hmd_ci_guard.py hmd_kill_guard.py hmd_push_target.py hmd_repo_receipt.py hmd_disk_floor.sh hmd_sweep_guard.py hmd_wait_guard.py hook-owned-path.sh)
SWITCHED=(ci-waste-guard disk-floor sweep-guard wait-guard)
PASS=0
FAIL=0
N=0
ok()  { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; [ -n "${2:-}" ] && printf '       %s\n' "$2"; }

# what the operator exports in their own shell never changes a case; a case that needs a setting passes it
unset HMD_CI_RERUN_ALLOW HMD_SWEEP_ALLOW HMD_WAIT_ALLOW HMD_KILL_GUARD HMD_MIN_FREE_PCT HMD_GUARDRAILS_MANIFEST HMD_COLD HOOK_CWD \
  HMD_CI_GUARD_TIMEOUT_S HMD_SWEEP_GUARD_TIMEOUT_S HMD_WAIT_GUARD_TIMEOUT_S FAKE_SCAN_RC STUB_RC

TMPROOT="$(mktemp -d)" || exit 1
trap 'rm -rf "$TMPROOT"' EXIT

echo "guardrail-off-bash"

command -v jq >/dev/null 2>&1 || { bad "0. jq is required: the hook parses its payload with it"; exit 1; }
command -v python3 >/dev/null 2>&1 || { bad "0. python3 is required: the guards' helpers are python"; exit 1; }
if bash -n "$HOOK" 2>/dev/null; then ok "0. bin/heimdall-precheck-bash parses"; else bad "0. bin/heimdall-precheck-bash does not parse"; fi

# ── plugin roots: the REAL hook, libs and manifest; a tracker that prints nothing; a commit secret scan steered by FAKE_SCAN_RC ───────────────────────────
mkroot() {  # mkroot <dir>
  local d="$1" f
  mkdir -p "$d/bin/lib"
  cp "$HOOK" "$d/bin/heimdall-precheck-bash"
  for f in "${LIBS[@]}"; do cp "$REPO/bin/lib/$f" "$d/bin/lib/$f" || return 1; done
  cp "$MANIFEST" "$d/guardrails.manifest.json"
  printf '#!/bin/sh\nexit 0\n' >"$d/bin/parallelism-tracker"
  printf '#!/bin/sh\n[ "${FAKE_SCAN_RC:-0}" = 0 ] && exit 0\necho "fake finding in the staged diff" >&2\nexit "$FAKE_SCAN_RC"\n' >"$d/bin/secret-scan"
  chmod +x "$d/bin/heimdall-precheck-bash" "$d/bin/parallelism-tracker" "$d/bin/secret-scan"
}
PLUGIN="$TMPROOT/plugin"; mkroot "$PLUGIN" || { bad "0. could not build the plugin root"; exit 1; }
NOLIB="$TMPROOT/plugin-nolib"; mkroot "$NOLIB"; rm -f "$NOLIB/bin/lib/hmd_guardrail_enabled.sh"
NOMANIFEST="$TMPROOT/plugin-nomanifest"; mkroot "$NOMANIFEST"; rm -f "$NOMANIFEST/guardrails.manifest.json"
NOFUNC="$TMPROOT/plugin-nofunc"; mkroot "$NOFUNC"; printf '# a lib that defines nothing\n' >"$NOFUNC/bin/lib/hmd_guardrail_enabled.sh"
STUB="$TMPROOT/plugin-stub"; mkroot "$STUB"; printf 'hmd_guardrail_enabled() { return "${STUB_RC:-0}"; }\n' >"$STUB/bin/lib/hmd_guardrail_enabled.sh"
CORED="$TMPROOT/plugin-cored"; mkroot "$CORED"
jq '(.guardrails[] | select(.id == "wait-guard") | .tier) = "core"' "$MANIFEST" >"$CORED/guardrails.manifest.json"

# the sweep guard's records: a script to run and, in HEIMDALL_HOME/receipts, a lock naming a live pid (this shell's): "a sweep is already running"
FX="$TMPROOT/fx"
HH="$TMPROOT/hh"
mkdir -p "$FX/test" "$HH/receipts" "$TMPROOT/home"
printf '#!/bin/sh\nexit 0\n' >"$FX/test/run-all.sh"
printf '#!/bin/sh\nexit 0\n' >"$FX/test/x.test.sh"
printf 'pid=%s\nrepo=%s\nstarted=2026-11-12T00:00:00+0000\n' "$$" "$FX" >"$HH/receipts/sweep.lock"

canon() {  # the canonical bad command of each switched guard
  case $1 in
    ci-waste-guard) printf '%s' 'gh run rerun 12345' ;;
    disk-floor) printf '%s' 'bash test/x.test.sh' ;;
    sweep-guard) printf '%s' 'bash test/run-all.sh' ;;
    wait-guard) printf '%s' 'sleep 600' ;;
  esac
}
verdict() {  # the start of each guard's deny
  case $1 in
    ci-waste-guard) printf '%s' 'BLOCKED: hmd CI waste guard: ' ;;
    disk-floor) printf '%s' 'BLOCKED: disk floor: ' ;;
    sweep-guard) printf '%s' 'BLOCKED: hmd sweep guard: ' ;;
    wait-guard) printf '%s' 'BLOCKED: hmd wait guard: ' ;;
  esac
}
floor() {  # the disk floor's own cases ask for 100% free, which every disk is under; every other case turns the floor off, so only the guard under test can answer
  if [ "$1" = disk-floor ]; then printf '100'; else printf '0'; fi
}

RC=0
run_hook() {  # run_hook <plugin root> <command> [VAR=val ...] -> RC, $TMPROOT/out (stdout), $TMPROOT/err (stderr); run from $HOOK_CWD, default the fixture
  local root="$1" cmd="$2"
  shift 2
  printf '%s' "$cmd" >"$TMPROOT/cmd.txt"
  jq -nc --rawfile c "$TMPROOT/cmd.txt" --arg cwd "$FX" '{tool_name: "Bash", cwd: $cwd, tool_input: {command: $c}}' \
    | ( cd "${HOOK_CWD:-$FX}" && env HOME="$TMPROOT/home" HEIMDALL_HOME="$HH" HMD_MIN_FREE_PCT=0 CLAUDE_PLUGIN_ROOT="$root" "$@" bash "$root/bin/heimdall-precheck-bash" ) \
      >"$TMPROOT/out" 2>"$TMPROOT/err"
  RC=$?
}
denies() {  # denies <root> <guard id> <label> [VAR=val ...]: exit 2 and THAT guard's {"error": ...} on stdout
  local root="$1" id="$2" label="$3"
  shift 3
  N=$((N + 1))
  run_hook "$root" "$(canon "$id")" HMD_MIN_FREE_PCT="$(floor "$id")" "$@"
  if [ "$RC" = 2 ] && jq -e --arg p "$(verdict "$id")" '.error | startswith($p)' "$TMPROOT/out" >/dev/null 2>&1; then
    ok "$N. $label"
  else
    bad "$N. $label" "rc=$RC stdout=$(head -c 200 "$TMPROOT/out") stderr=$(head -c 200 "$TMPROOT/err")"
  fi
}
allows() {  # allows <root> <guard id> <label> [VAR=val ...]: exit 0 and silent, as the guard's env override is
  local root="$1" id="$2" label="$3"
  shift 3
  N=$((N + 1))
  run_hook "$root" "$(canon "$id")" HMD_MIN_FREE_PCT="$(floor "$id")" "$@"
  if [ "$RC" = 0 ] && [ ! -s "$TMPROOT/out" ] && [ ! -s "$TMPROOT/err" ]; then
    ok "$N. $label"
  else
    bad "$N. $label" "rc=$RC stdout=$(head -c 200 "$TMPROOT/out") stderr=$(head -c 200 "$TMPROOT/err")"
  fi
}
off() { printf '%s\n' "$@" >"$HH/guardrails-off"; }

echo "-- 1. INV-G2: no guardrails-off file, each guard denies its canonical command --"
rm -f "$HH/guardrails-off"
for id in "${SWITCHED[@]}"; do denies "$PLUGIN" "$id" "no file: '$(canon "$id")' is denied by $id"; done

echo "-- 2. INV-G3: one id in the file allows that guard's command, silently; the other three still deny --"
for o in "${SWITCHED[@]}"; do
  off "$o"
  for id in "${SWITCHED[@]}"; do
    if [ "$id" = "$o" ]; then allows "$PLUGIN" "$id" "$o off: '$(canon "$id")' is allowed, silently"; else denies "$PLUGIN" "$id" "$o off: $id still denies"; fi
  done
done

echo "-- 3. INV-G1: core is never switched --"
jq -r '.guardrails[] | select(.tier == "core") | .id' "$MANIFEST" >"$HH/guardrails-off"
if grep -qx bash-gate-chain "$HH/guardrails-off" && grep -qx kill-guard "$HH/guardrails-off" && grep -qx commit-secret-scan "$HH/guardrails-off"; then
  ok "core ids listed: $(wc -l <"$HH/guardrails-off" | tr -d ' ') of them, bash-gate-chain, kill-guard and commit-secret-scan among them"
else
  bad "the manifest's core ids are not what this case lists" "$(tr '\n' ' ' <"$HH/guardrails-off")"
fi
for id in "${SWITCHED[@]}"; do denies "$PLUGIN" "$id" "every core id listed: $id still denies"; done
off wait-guard
denies "$CORED" wait-guard "a manifest that calls wait-guard core keeps it on with wait-guard listed (the tier is read from the manifest, not trusted from the file)"
jq -r '.guardrails[].id' "$MANIFEST" >"$HH/guardrails-off"
# The kill payload is built at runtime, from fragments that never form a literal (the runtime-assembly convention of
# docs/superpowers/specs/heimdall-fixture-secret-convention.md): the "no committed test, helper or bin script pattern-kills an hmd server" case of
# test/hmd-server-kill-guard.test.sh fails on any committed line that runs the by-name kill verb against an hmd server, and this file is not on its
# exclusion list. The hook still gets the whole command, so the guard is graded on exactly what it denies.
KILL_VERB='pkill'
KILL_FLAG='-f'
KILL_TARGET='heimdall-relay-client'
N=$((N + 1)); run_hook "$PLUGIN" "$KILL_VERB $KILL_FLAG $KILL_TARGET"
if [ "$RC" = 2 ] && jq -e '.error | startswith("BLOCKED: hmd kill guard")' "$TMPROOT/out" >/dev/null 2>&1; then ok "$N. every id listed: the kill guard (core, no switch) still denies"; else bad "$N. every id listed: the kill guard did not deny" "rc=$RC $(head -c 200 "$TMPROOT/out")"; fi
N=$((N + 1)); run_hook "$PLUGIN" 'git commit -m x' FAKE_SCAN_RC=1
if [ "$RC" = 2 ] && jq -e '.error | startswith("BLOCKED: secret detected")' "$TMPROOT/out" >/dev/null 2>&1; then ok "$N. every id listed: the commit secret scan (core, no switch) still denies"; else bad "$N. every id listed: the commit secret scan did not deny" "rc=$RC $(head -c 200 "$TMPROOT/out")"; fi
CODE="$(grep -v '^[[:space:]]*#' "$HOOK")"  # the hook without its comment lines: what runs, not what is described
ASKED="$(grep -o 'gp_guard_on [a-z-]*' <<<"$CODE" | sed '/gp_guard_on $/d; s/^gp_guard_on //' | LC_ALL=C sort -u | tr '\n' ' ')"
WANT="$(printf '%s\n' "${SWITCHED[@]}" | LC_ALL=C sort | tr '\n' ' ')"
if [ "$ASKED" = "$WANT" ]; then ok "the hook asks the switch for exactly: $ASKED"; else bad "the hook asks the switch for [$ASKED], want [$WANT]"; fi
NOT_REC=""
for id in "${SWITCHED[@]}"; do
  [ "$(jq -r --arg id "$id" '[.guardrails[] | select(.id == $id)] | if length == 1 then .[0].tier else "missing" end' "$MANIFEST")" = recommended ] || NOT_REC="$NOT_REC $id"
done
if [ -z "$NOT_REC" ]; then ok "each of the four is ONE recommended row of guardrails.manifest.json (a mistyped id would be a switch that never works)"; else bad "not one recommended manifest row:$NOT_REC"; fi
CALLS="$(grep -c 'hmd_guardrail_enabled "' <<<"$CODE")"
if [ "$CALLS" = 1 ] && ! grep -q '! *hmd_guardrail_enabled' <<<"$CODE" && grep -q '\[ "\$?" -ne 1 \]' <<<"$CODE"; then
  ok "the lib is asked in ONE place, and only its exit 1 means off (never ! hmd_guardrail_enabled)"
else
  bad "the hook asks hmd_guardrail_enabled $CALLS times, or negates it, or does not test for exactly 1"
fi

echo "-- 4. INV-G5: any doubt keeps the guard on (all four ids listed) --"
off "${SWITCHED[@]}"
for id in "${SWITCHED[@]}"; do denies "$NOLIB" "$id" "no bin/lib/hmd_guardrail_enabled.sh: $id still denies"; done
for id in "${SWITCHED[@]}"; do denies "$NOMANIFEST" "$id" "no guardrails.manifest.json: $id still denies"; done
denies "$NOFUNC" wait-guard "a lib that defines no hmd_guardrail_enabled: wait-guard still denies"
for rc in 0 2 127; do denies "$STUB" wait-guard "the lib answers $rc: wait-guard still denies (only exactly 1 is off)" STUB_RC=$rc; done
allows "$STUB" wait-guard "the lib answers 1: wait-guard is off" STUB_RC=1

echo "-- 5. INV-G7: whose file it is --"
mkdir -p "$TMPROOT/clone/.heimdall"
printf 'wait-guard\n' >"$TMPROOT/clone/.heimdall/guardrails-off"
rm -f "$HH/guardrails-off"
HOOK_CWD="$TMPROOT/clone" denies "$PLUGIN" wait-guard "HEIMDALL_HOME=.heimdall (relative: the cwd's, a repository could ship it) switches nothing" HEIMDALL_HOME=.heimdall
mkdir -p "$TMPROOT/home/.heimdall"
printf 'wait-guard\n' >"$TMPROOT/home/.heimdall/guardrails-off"
allows "$PLUGIN" wait-guard "HEIMDALL_HOME empty: the operator's ~/.heimdall/guardrails-off is the switch" HEIMDALL_HOME=

echo
echo "guardrail-off-bash: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
