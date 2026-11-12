#!/usr/bin/env bash
# test/skills-consent-gate.test.sh -- bin/lib/skills_consent.sh, the consent gate for NEW skill installs
# (3.x M1 plan, task T3.5: docs/superpowers/plans/2026-11-12-3x-m1-skill-registry.md, "Consent model").
#
# hmd_skills_consent <id> <via> is asked before an install call site installs a recommended skill. It answers with
# a status: 0 install now, 10 defer (a `suggested` lock row and ONE stderr line), 11 declined (a `declined` row).
#
# THE CONTRACT UNDER TEST
#   A  mode x via x tty matrix: ask / allowlist (hit, miss) / auto (grandfathered, chosen) x first-run /
#      prompt-preinstall / hmd-skills-install x no tty / tty. The lock row lands in the right scope (first-run ->
#      machine lock, every other via -> project lock) with the manifest's kind, ref and source
#   B  the prompt (Install now / Not now / Never ask again): the choices, ESC, the lock row each one leaves
#   C  a decline is remembered: an automatic via is not asked again (11), an explicit `hmd skills install` is, and a
#      deferred explicit attempt never turns `declined` back into `suggested`
#   D  settings that cannot be read: the setup marker decides -- marker present => install (a legacy install is never
#      turned into a defer), marker absent => defer; a typo'd value never moves toward install; python3 missing
#   E  HMD_SKILLS_YES=1 (exactly 1) and the HMD_SKILLS_CONSENT environment override
#   F  malformed ids, an id the manifest does not list, a damaged lock, the evidence cap, `set -euo pipefail` callers,
#      sourcing twice, and the gate never installs anything itself (fake `claude` / `git` see no call)
#   G  a REAL pty (`script -q`, no seam): the tty gate itself opens the prompt; HMD_SKILLS_ASSUME=notty closes it
#   H  the suite can go RED: ten one-line breaks of the library, each caught by the check that guards it
#
# THE TTY SEAM. Every tty case but G runs without a terminal: HMD_SKILLS_ASSUME=tty makes the gate behave as if both
# stdin and stdout were a terminal, and keys are piped to the menu (k = up, j = down, Enter confirms; the menu opens
# on "Not now"). G proves the seam is a convenience and not the feature: with a real pty and no seam the prompt opens.
#
# HERMETIC. HOME, HEIMDALL_HOME and the project are throwaway directories, `claude` and `git` are PATH fakes that log
# their calls, no network, nothing outside $TMP is touched. EXIT: 0 = every assertion passes; 1 = any FAIL.
# shellcheck disable=SC2016  # single quotes hold literal library text and shell snippets for the child bash on purpose
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$REPO/bin/lib/skills_consent.sh"
LOCKPY="$REPO/bin/lib/skills_lock.py"

PASS=0
FAIL=0
ok()   { PASS=$((PASS + 1)); printf '  \033[32mPASS\033[0m %s\n' "$1"; }
bad()  { FAIL=$((FAIL + 1)); printf '  \033[31mFAIL\033[0m %s\n' "$1"; if [ -n "${2:-}" ]; then printf '       %s\n' "$2"; fi; }
skip() { printf '  \033[33mSKIP\033[0m %s\n' "$1"; }
eq()   { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected [$2], got [$3]"; fi; }
has()  { if grep -qF -- "$3" <<<"$2"; then ok "$1"; else bad "$1" "[$3] is not in [$2]"; fi; }
lacks() { if grep -qF -- "$3" <<<"$2"; then bad "$1" "[$3] is in [$2]"; else ok "$1"; fi; }
finish() { echo; echo "skills-consent-gate: $PASS passed, $FAIL failed"; [ "$FAIL" -eq 0 ] && [ "$PASS" -gt 0 ]; }

echo "skills-consent-gate"

command -v python3 >/dev/null 2>&1 || { echo "FATAL: python3 is required"; exit 1; }
if [ ! -f "$LIB" ]; then
  bad "0. bin/lib/skills_consent.sh is missing"
  finish
  exit 1
fi

# ── sandbox ──────────────────────────────────────────────────────────────────────────────────────────────────────
TMP="$(mktemp -d /tmp/test-skills-consent-XXXXXX)" || exit 1
trap 'chmod -R u+rwx "$TMP" 2>/dev/null; rm -rf "$TMP"' EXIT
# The REAL interpreter first on PATH: a version-manager shim costs ~0.4 s a call and the gate starts python several times.
REALPY="$(python3 -I -c 'import sys; print(sys.executable)' 2>/dev/null)"
[ -x "${REALPY:-}" ] || { echo "FATAL: no usable python3"; exit 1; }
mkdir -p "$TMP/pybin" "$TMP/fakebin" "$TMP/emptybin" "$TMP/home"
ln -s "$REALPY" "$TMP/pybin/python3"
PATH="$TMP/pybin:$PATH"; export PATH
CALLS="$TMP/calls.log"; : > "$CALLS"
for tool in claude git; do   # an install, if the gate ever made one, would show up here
  printf '#!/bin/sh\necho "%s $*" >> "%s"\nexit 0\n' "$tool" "$CALLS" > "$TMP/fakebin/$tool"
  chmod +x "$TMP/fakebin/$tool"
done
GPATH="$TMP/pybin:$TMP/fakebin:/usr/bin:/bin:/usr/sbin:/sbin"
HOME_DIR="$TMP/home"
NONROOT=0; [ "$(id -u)" -ne 0 ] && NONROOT=1

# The driver: source the library into a FRESH bash, ask once, print the status and the basis it left behind.
cat > "$TMP/drv.sh" <<'EOF'
if [ "${HMD_TEST_STRICT:-}" = 1 ]; then set -euo pipefail; fi
. "$1" || exit 99
rc=0
hmd_skills_consent "$2" "$3" || rc=$?
printf 'RESULT rc=%s basis=%s\n' "$rc" "${HMD_SKILLS_CONSENT_BASIS-unset}"
EOF

# ── helpers ──────────────────────────────────────────────────────────────────────────────────────────────────────
XENV=""   # extra NAME=value words (no spaces inside a value) for the next gate calls; "" = none
HH=""; PROJ=""; N=0
RC=""; BASIS=""; ERR=""
newcase() { N=$((N + 1)); HH="$TMP/hh.$N"; PROJ="$TMP/proj.$N"; mkdir -p "$PROJ"; XENV=""; }   # a fresh HEIMDALL_HOME and project
setcfg()  { mkdir -p "$HH"; printf '%s\n' "$1" > "$HH/skills-config.json"; }
marker()  { mkdir -p "$HH"; : > "$HH/setup-done"; }

# gate ID VIA [KEYS] -> RC BASIS ERR. The library runs in a clean environment, in the project dir; stdin is a FILE holding KEYS
# (never a terminal), so the gate only prompts through the HMD_SKILLS_ASSUME seam.
gate() {
  local id="$1" via="$2" keys="${3-}" raw res
  printf '%b' "$keys" > "$TMP/keys"
  # shellcheck disable=SC2086  # XENV is a list of NAME=value words on purpose
  raw="$(cd "$PROJ" && env -i HOME="$HOME_DIR" HEIMDALL_HOME="$HH" PATH="$GPATH" TERM=dumb HMD_RUN_ID=run-test $XENV \
    "$BASH" "$TMP/drv.sh" "$LIB" "$id" "$via" < "$TMP/keys" 2> "$TMP/stderr")"
  ERR="$(cat "$TMP/stderr")"
  res="$(grep '^RESULT ' <<<"$raw" | tail -n 1)"
  RC="${res#RESULT rc=}"; RC="${RC%% *}"
  BASIS="${res##* basis=}"
  if [ -z "$res" ]; then RC=none; BASIS=none; fi
}

prow() { python3 -I "$LOCKPY" read --scope project --project-dir "$PROJ" --id "$1" 2>/dev/null; }
mrow() { HEIMDALL_HOME="$HH" python3 -I "$LOCKPY" read --scope machine --id "$1" 2>/dev/null; }
# jf ROW EXPR: EXPR (always a literal written in THIS file) evaluated with r = the lock row; `no-row` when there is none
jf() {
  if [ -z "$1" ]; then echo no-row; return 0; fi
  python3 -I -c 'import json, sys
r = json.loads(sys.argv[1])
print(eval(sys.argv[2]))' "$1" "$2"
}
# lockinfo ID SCOPE -> state|why.via|kind|consent|source|ref of the row in that scope's lock
lockinfo() {
  local row
  if [ "$2" = machine ]; then row="$(mrow "$1")"; else row="$(prow "$1")"; fi
  jf "$row" 'r["state"] + "|" + r["why"]["via"] + "|" + r["kind"] + "|" + r["consent"] + "|" + r["source"] + "|" + r["ref"]'
}
state_of() {  # state_of ID -> the state of ID's row in the project lock
  jf "$(prow "$1")" 'r["state"]'
}
nlines() { grep -c . <<<"$1"; }

[ -f "$REPO/skills.manifest.json" ] || { echo "FATAL: skills.manifest.json missing"; exit 1; }
MARKET=anthropics/claude-plugins-official

# ── 0. the library itself ────────────────────────────────────────────────────────────────────────────────────────
echo "0. the library"
if [ "$(head -n 80 "$LIB" | grep -c 'HMD_SKILLS_ASSUME')" -ge 1 ]; then ok "0. the HMD_SKILLS_ASSUME test seam is documented in the library header"; else bad "0. HMD_SKILLS_ASSUME is not documented in the first 80 lines of the library"; fi
out="$(env -i PATH="$GPATH" "$BASH" -c '. "$1"; . "$1"; type -t hmd_skills_consent' _ "$LIB" 2>&1)"
eq "0. sourcing (twice) prints nothing and defines hmd_skills_consent" "function" "$out"

# ╔═ A. mode x via x tty ═══════════════════════════════════════════════════════════════════════════════════════════╗
echo "A. mode x via x tty"
for via in first-run prompt-preinstall hmd-skills-install; do
  if [ "$via" = first-run ]; then id=superpowers; scope=machine; other=project; else id=frontend-design; scope=project; other=machine; fi
  ref="$id@claude-plugins-official"
  want_row="suggested|$via|plugin|n/a|$MARKET|$ref"
  tag="A/$via"

  newcase; setcfg '{"consent": "ask", "grandfathered": false}'
  gate "$id" "$via"
  eq "$tag ask, no tty: 10, nothing to install with" "10|n/a" "$RC|$BASIS"
  eq "$tag ask, no tty: a suggested row in the $scope lock, with the manifest's plugin, source and ref" "$want_row" "$(lockinfo "$id" "$scope")"
  eq "$tag ask, no tty: the $other lock is untouched" "no-row" "$(lockinfo "$id" "$other")"
  eq "$tag ask, no tty: ONE stderr line" "1" "$(nlines "$ERR")"
  has "$tag ask, no tty: ... that names the skill" "$ERR" "$id"
  has "$tag ask, no tty: ... and the command" "$ERR" "hmd skills suggest"
  lacks "$tag ask, no tty: no menu is drawn" "$ERR" "hmd: install skill"

  newcase; setcfg '{"consent": "allowlist", "allowlist": ["slack", "frontend-design", "superpowers"]}'
  gate "$id" "$via"
  eq "$tag allowlist hit: 0, basis allowlist, silent" "0|allowlist|" "$RC|$BASIS|$ERR"
  eq "$tag allowlist hit: no lock row (the caller records installed)" "no-row" "$(lockinfo "$id" "$scope")"

  newcase; setcfg '{"consent": "allowlist", "allowlist": ["slack"]}'
  gate "$id" "$via"
  eq "$tag allowlist miss, no tty: 10 and a suggested row" "10|n/a|$want_row" "$RC|$BASIS|$(lockinfo "$id" "$scope")"

  newcase; setcfg '{"consent": "auto", "grandfathered": true}'
  gate "$id" "$via"
  eq "$tag auto (grandfathered): 0, basis auto-legacy, silent, no row" "0|auto-legacy||no-row" "$RC|$BASIS|$ERR|$(lockinfo "$id" "$scope")"

  newcase; setcfg '{"consent": "auto", "grandfathered": false}'
  gate "$id" "$via"
  eq "$tag auto (chosen by the operator): 0, basis explicit, silent" "0|explicit|" "$RC|$BASIS|$ERR"

  newcase; setcfg '{"consent": "ask"}'; XENV="HMD_SKILLS_ASSUME=tty"
  gate "$id" "$via" '\n'
  eq "$tag ask, tty, Enter: the menu opens on Not now: 10 and a suggested row" "10|n/a|$want_row" "$RC|$BASIS|$(lockinfo "$id" "$scope")"
  has "$tag ask, tty: the menu names the skill, its ref and its source" "$ERR" "hmd: install skill $id ($ref, from $MARKET)?"
  has "$tag ask, tty: ... offers Install now" "$ERR" "Install now"

  newcase; setcfg '{"consent": "allowlist", "allowlist": ["nothing-here"]}'; XENV="HMD_SKILLS_ASSUME=tty"
  gate "$id" "$via" '\n'
  eq "$tag allowlist miss, tty: the person is asked (10 on Enter)" "10" "$RC"
  has "$tag allowlist miss, tty: the menu opens" "$ERR" "hmd: install skill $id"
done

newcase; setcfg '{"consent": "auto", "grandfathered": true}'; XENV="HMD_SKILLS_ASSUME=tty"
gate frontend-design prompt-preinstall 'k\n'
eq "A/tty auto: installs without a question" "0|auto-legacy|" "$RC|$BASIS|$ERR"
newcase; setcfg '{"consent": "allowlist", "allowlist": ["frontend-design"]}'; XENV="HMD_SKILLS_ASSUME=tty"
gate frontend-design prompt-preinstall 'j\n'
eq "A/tty allowlist hit: installs without a question" "0|allowlist|" "$RC|$BASIS|$ERR"
newcase; setcfg '{"consent": "ask"}'
gate ui-ux-pro-max prompt-preinstall
eq "A/github-skill: the row says github-skill, its repo and github.com source" "suggested|prompt-preinstall|github-skill|n/a|github.com/nextlevelbuilder/ui-ux-pro-max-skill|nextlevelbuilder/ui-ux-pro-max-skill" "$(lockinfo ui-ux-pro-max project)"

# ╔═ B. the prompt ═════════════════════════════════════════════════════════════════════════════════════════════════╗
echo "B. the prompt"
newcase; setcfg '{"consent": "ask"}'; XENV="HMD_SKILLS_ASSUME=tty"
gate frontend-design prompt-preinstall 'k\n'
eq "B: up + Enter = Install now: 0, basis prompt" "0|prompt" "$RC|$BASIS"
eq "B: ... no row from the gate (the caller records installed)" "no-row" "$(lockinfo frontend-design project)"
has "B: ... the menu said why the skill is offered" "$ERR" "design guidance"
newcase; setcfg '{"consent": "ask"}'; XENV="HMD_SKILLS_ASSUME=tty"
gate frontend-design prompt-preinstall 'j\n'
eq "B: down + Enter = Never ask again: 11 and a declined row" "11|n/a|declined" "$RC|$BASIS|$(state_of frontend-design)"
lacks "B: ... no deferral line (a decline is not a nag)" "$ERR" "hmd skills suggest"
newcase; setcfg '{"consent": "ask"}'; XENV="HMD_SKILLS_ASSUME=tty"
gate frontend-design prompt-preinstall '\033'
eq "B: ESC aborts to the safe answer: 10 and a suggested row" "10|suggested" "$RC|$(state_of frontend-design)"
newcase; setcfg '{"consent": "ask"}'; XENV="HMD_SKILLS_ASSUME=tty"
gate frontend-design prompt-preinstall
eq "B: keys that never come (EOF) confirm the safe answer: 10" "10" "$RC"

# ╔═ C. a decline is remembered ════════════════════════════════════════════════════════════════════════════════════╗
echo "C. declines"
newcase; setcfg '{"consent": "ask"}'; XENV="HMD_SKILLS_ASSUME=tty"
gate frontend-design prompt-preinstall 'j\n'
gate frontend-design prompt-preinstall 'k\n'
eq "C: an automatic via is not asked again after a decline (Install keys are ignored): 11" "11" "$RC"
lacks "C: ... and no menu is drawn" "$ERR" "hmd: install skill"
gate frontend-design hmd-skills-install 'k\n'
eq "C: an explicit hmd skills install asks again, and Install wins: 0, basis prompt" "0|prompt" "$RC|$BASIS"
newcase; setcfg '{"consent": "ask"}'; XENV="HMD_SKILLS_ASSUME=tty"
gate frontend-design prompt-preinstall 'j\n'
XENV=""
gate frontend-design hmd-skills-install
eq "C: a deferred explicit attempt (no tty, no --yes) is 10 ..." "10" "$RC"
eq "C: ... and leaves the decline in place" "declined" "$(state_of frontend-design)"
newcase; setcfg '{"consent": "ask"}'; XENV="HMD_SKILLS_ASSUME=tty"
gate superpowers first-run 'j\n'
XENV=""
gate superpowers first-run
eq "C: first-run declines live in the machine lock and are honoured there: 11" "11|declined" "$RC|$(jf "$(mrow superpowers)" 'r["state"]')"

# ╔═ D. settings that cannot be read ═══════════════════════════════════════════════════════════════════════════════╗
echo "D. unreadable settings: the setup marker decides"
broken_case() {  # broken_case KIND WITH_MARKER(0|1) -> a fresh case whose settings file is broken in the KIND way
  newcase; mkdir -p "$HH"
  case "$1" in
    corrupt)   printf '{not json' > "$HH/skills-config.json" ;;
    notobject) printf '[1, 2]' > "$HH/skills-config.json" ;;
    dir)       mkdir "$HH/skills-config.json" ;;
    chmod)     printf '{"consent": "auto"}' > "$HH/skills-config.json"; chmod 000 "$HH/skills-config.json" ;;
  esac
  if [ "$2" = 1 ]; then marker; fi
}
for kind in corrupt dir chmod notobject; do
  if [ "$kind" = chmod ] && [ "$NONROOT" -eq 0 ]; then skip "D/chmod: running as root, a mode 000 file is still readable"; continue; fi
  if [ "$kind" != notobject ]; then
    broken_case "$kind" 1
    gate frontend-design prompt-preinstall
    eq "D/$kind + setup marker: INSTALL (a legacy install is never turned into a defer), basis auto-legacy" "0|auto-legacy" "$RC|$BASIS"
    eq "D/$kind + setup marker: no lock row" "no-row" "$(lockinfo frontend-design project)"
  fi
  broken_case "$kind" 0
  gate frontend-design prompt-preinstall
  eq "D/$kind + no marker: DEFER, nothing installed" "10|n/a" "$RC|$BASIS"
  has "D/$kind + no marker: the one line says the settings were unreadable" "$ERR" "consent settings unreadable"
  eq "D/$kind + no marker: a suggested row" "suggested" "$(state_of frontend-design)"
done
broken_case corrupt 0; XENV="HMD_SKILLS_ASSUME=tty"
gate frontend-design prompt-preinstall 'k\n'
eq "D/corrupt + no marker + tty: still DEFER, no menu (the Install key is never read)" "10" "$RC"
lacks "D/corrupt + no marker + tty: ... and no menu is drawn" "$ERR" "hmd: install skill"

newcase; setcfg '{"consent": "autp"}'; marker
gate frontend-design prompt-preinstall
eq "D/typo: a value that is not allowed reads as the restrictive default even with the marker: 10" "10" "$RC"
newcase; setcfg '{}'; marker
gate frontend-design prompt-preinstall
eq "D/empty object + marker: the default is ask: 10" "10" "$RC"
newcase; marker
gate frontend-design prompt-preinstall
eq "D/no settings file + marker: the grandfather rule, applied in memory: 0, auto-legacy" "0|auto-legacy" "$RC|$BASIS"
eq "D/... and the gate wrote no settings file" "no" "$([ -e "$HH/skills-config.json" ] && echo yes || echo no)"
newcase
gate frontend-design prompt-preinstall
eq "D/no settings file + no marker: ask, so 10" "10|n/a" "$RC|$BASIS"
has "D/... with consent=ask in the line" "$ERR" "consent=ask"

newcase; marker; XENV="PATH=$TMP/emptybin"
gate frontend-design prompt-preinstall
eq "D/python3 missing + marker: INSTALL" "0|auto-legacy" "$RC|$BASIS"
newcase; XENV="PATH=$TMP/emptybin"
gate frontend-design prompt-preinstall
eq "D/python3 missing + no marker: DEFER" "10|n/a" "$RC|$BASIS"
has "D/python3 missing + no marker: the line says the settings were unreadable" "$ERR" "consent settings unreadable"

# ╔═ E. HMD_SKILLS_YES and the environment override ════════════════════════════════════════════════════════════════╗
echo "E. HMD_SKILLS_YES and HMD_SKILLS_CONSENT"
newcase; setcfg '{"consent": "ask"}'; XENV="HMD_SKILLS_YES=1"
gate frontend-design hmd-skills-install
eq "E: HMD_SKILLS_YES=1 installs under ask: 0, basis yes-flag" "0|yes-flag|" "$RC|$BASIS|$ERR"
broken_case corrupt 0; XENV="HMD_SKILLS_YES=1"
gate frontend-design hmd-skills-install
eq "E: ... even when the settings cannot be read" "0|yes-flag" "$RC|$BASIS"
newcase; setcfg '{"consent": "ask"}'; XENV="HMD_SKILLS_YES=true"
gate frontend-design hmd-skills-install
eq "E: only exactly 1 counts (HMD_SKILLS_YES=true is not a yes)" "10" "$RC"
newcase; setcfg '{"consent": "ask"}'; XENV="HMD_SKILLS_CONSENT=auto"
gate frontend-design prompt-preinstall
eq "E: HMD_SKILLS_CONSENT=auto beats a file that says ask" "0|explicit" "$RC|$BASIS"
newcase; setcfg '{"consent": "auto", "grandfathered": true}'; marker; XENV="HMD_SKILLS_CONSENT=ask"
gate frontend-design prompt-preinstall
eq "E: HMD_SKILLS_CONSENT=ask beats a file that says auto, marker or not" "10" "$RC"
newcase; marker; XENV="HMD_SKILLS_CONSENT=autp"
gate frontend-design prompt-preinstall
eq "E: a typo'd HMD_SKILLS_CONSENT never moves toward install, marker or not" "10" "$RC"
newcase; setcfg '{"consent": "ask"}'; XENV="HMD_SKILLS_CONSENT=allowlist"
gate frontend-design prompt-preinstall
eq "E: allowlist by environment with an empty allowlist: nothing is on it: 10" "10" "$RC"

# ╔═ F. robustness ═════════════════════════════════════════════════════════════════════════════════════════════════╗
echo "F. robustness"
for badid in '' 'a b' '../x' 'x*' '-lead' 'a;b'; do
  newcase; setcfg '{"consent": "auto", "grandfathered": true}'
  gate "$badid" prompt-preinstall
  eq "F: the malformed id [$badid] is deferred (10), never installed, even under auto" "10|n/a" "$RC|$BASIS"
done
eq "F: ... and a malformed id writes no lock" "no" "$([ -e "$PROJ/.planning" ] && echo yes || echo no)"
newcase; setcfg '{"consent": "ask"}'
gate no-such-skill prompt-preinstall
eq "F: an id the manifest does not list still defers (10) ..." "10" "$RC"
eq "F: ... without writing a row it cannot describe" "no" "$([ -e "$PROJ/.planning/skills.lock" ] && echo yes || echo no)"
newcase; setcfg '{"consent": "ask"}'; mkdir -p "$PROJ/.planning"; printf '{garbage' > "$PROJ/.planning/skills.lock"
gate frontend-design prompt-preinstall
eq "F: a damaged lock never changes the decision (10) ..." "10" "$RC"
has "F: ... it is the lock tool's own line that says so" "$ERR" "skills-lock"
eq "F: ... and the damaged file is left as it was" "{garbage" "$(cat "$PROJ/.planning/skills.lock")"
XENV="HMD_SKILLS_ASSUME=tty"
gate frontend-design prompt-preinstall 'k\n'
eq "F: a damaged lock does not block an Install answer either (0)" "0|prompt" "$RC|$BASIS"
newcase; setcfg '{"consent": "ask"}'; XENV="HMD_INSTALL_WHY_RULE=prompt_ere HMD_INSTALL_WHY_EVIDENCE=$(printf 'e%.0s' $(seq 1 100))"
gate frontend-design prompt-preinstall
eq "F: the caller's rule is the row's why.rule" "prompt_ere" "$(jf "$(prow frontend-design)" 'r["why"]["rule"]')"
eq "F: the caller's evidence is cut to 64 characters by the lock" "64" "$(jf "$(prow frontend-design)" 'len(r["why"]["evidence"])')"
newcase; setcfg '{"consent": "auto"}'; XENV="HMD_TEST_STRICT=1"
gate frontend-design prompt-preinstall
eq "F: set -euo pipefail caller, auto: the gate returns 0 instead of aborting the caller" "0" "$RC"
newcase; setcfg '{"consent": "ask"}'; XENV="HMD_TEST_STRICT=1"
gate frontend-design prompt-preinstall
eq "F: set -euo pipefail caller, ask, no tty: 10 reaches the caller" "10" "$RC"
newcase; setcfg '{"consent": "ask"}'; XENV="HMD_TEST_STRICT=1 HMD_SKILLS_ASSUME=tty"
gate frontend-design prompt-preinstall 'k\n'
eq "F: set -euo pipefail caller, the menu: Install reaches the caller (0)" "0|prompt" "$RC|$BASIS"
newcase; setcfg '{"consent": "ask"}'; XENV="HMD_TEST_STRICT=1 HMD_SKILLS_ASSUME=tty"
gate frontend-design prompt-preinstall 'j\n'
eq "F: set -euo pipefail caller, the menu: Never reaches the caller (11)" "11" "$RC"
eq "F: the gate never installs: the fake claude and git saw no call, whatever the answer" "0" "$(wc -l < "$CALLS" | tr -d ' ')"

# ╔═ G. a real pty ═════════════════════════════════════════════════════════════════════════════════════════════════╗
echo "G. a real pty (script -q), no seam"
PTY_OK=0
if command -v script >/dev/null 2>&1 && command -v perl >/dev/null 2>&1; then
  probe="$(perl -e 'alarm 30; exec @ARGV or exit 127' -- script -q /dev/null "$BASH" -c '[ -t 0 ] && [ -t 1 ] && echo PTY_OK' </dev/null 2>&1 | tr -d '\r')"
  case "$probe" in *PTY_OK*) PTY_OK=1 ;; esac
fi
pty_run() {  # pty_run KEYS ID VIA [NAME=value ...] -> PTYOUT: the driver under a pty on both descriptors, nothing seamed
  local keys="$1" id="$2" via="$3"; shift 3
  printf '%b' "$keys" > "$TMP/ptykeys"
  PTYOUT="$(cd "$PROJ" && perl -e 'alarm 60; exec @ARGV or exit 127' -- env -i HOME="$HOME_DIR" HEIMDALL_HOME="$HH" PATH="$GPATH" \
    TERM=dumb HMD_RUN_ID=run-test "$@" script -q /dev/null "$BASH" "$TMP/drv.sh" "$LIB" "$id" "$via" < "$TMP/ptykeys" 2>&1 | tr -d '\r')"
}
if [ "$PTY_OK" -eq 1 ]; then
  newcase; setcfg '{"consent": "ask"}'
  pty_run '\n' frontend-design prompt-preinstall
  has "G: ask on a real pty opens the menu with no seam set" "$PTYOUT" "hmd: install skill frontend-design"
  has "G: ... and Enter on its default is Not now (10)" "$PTYOUT" "RESULT rc=10"
  newcase; setcfg '{"consent": "ask"}'
  pty_run '\n' frontend-design prompt-preinstall HMD_SKILLS_ASSUME=notty
  lacks "G: HMD_SKILLS_ASSUME=notty closes the menu even on a real pty" "$PTYOUT" "hmd: install skill"
  has "G: ... and defers (10)" "$PTYOUT" "RESULT rc=10"
  newcase; setcfg '{"consent": "auto", "grandfathered": true}'
  pty_run '' frontend-design prompt-preinstall
  lacks "G: auto on a real pty asks nothing" "$PTYOUT" "hmd: install skill"
  has "G: ... and installs (0)" "$PTYOUT" "RESULT rc=0"
else
  skip "G: no usable script(1) pty here; section A covered the tty column through the seam"
fi

# ╔═ H. the suite can go RED ═══════════════════════════════════════════════════════════════════════════════════════╗
echo "H. one-line breaks of the library are each caught"
ck_yes()          { newcase; setcfg '{"consent": "ask"}'; XENV="HMD_SKILLS_YES=1"; gate frontend-design prompt-preinstall; [ "$RC|$BASIS" = "0|yes-flag" ]; }
ck_marker()       { broken_case corrupt 1; gate frontend-design prompt-preinstall; [ "$RC|$BASIS" = "0|auto-legacy" ]; }
ck_allow_miss()   { newcase; setcfg '{"consent": "allowlist", "allowlist": ["slack"]}'; gate frontend-design prompt-preinstall; [ "$RC" = 10 ]; }
ck_decline_row()  { newcase; setcfg '{"consent": "ask"}'; XENV="HMD_SKILLS_ASSUME=tty"; gate frontend-design prompt-preinstall 'j\n'
                    [ "$RC" = 11 ] && [ "$(state_of frontend-design)" = declined ]; }
ck_defer_rc()     { newcase; setcfg '{"consent": "ask"}'; gate frontend-design prompt-preinstall
                    [ "$RC|$BASIS" = "10|n/a" ] && [ "$(state_of frontend-design)" = suggested ]; }
ck_scope()        { newcase; setcfg '{"consent": "ask"}'; gate superpowers first-run
                    [ "$RC" = 10 ] && [ "$(jf "$(mrow superpowers)" 'r["state"]')" = suggested ] && [ -z "$(prow superpowers)" ]; }
ck_new_broken()   { broken_case corrupt 0; gate frontend-design prompt-preinstall; local first="$RC"; XENV="HMD_SKILLS_ASSUME=tty"
                    gate frontend-design prompt-preinstall 'k\n'; [ "$first" = 10 ] && [ "$RC" = 10 ]; }
ck_memo()         { newcase; setcfg '{"consent": "ask"}'; XENV="HMD_SKILLS_ASSUME=tty"; gate frontend-design prompt-preinstall 'j\n'
                    gate frontend-design prompt-preinstall 'k\n'; [ "$RC" = 11 ]; }
ck_explicit()     { newcase; setcfg '{"consent": "ask"}'; XENV="HMD_SKILLS_ASSUME=tty"; gate frontend-design prompt-preinstall 'j\n'
                    gate frontend-design hmd-skills-install 'k\n'; [ "$RC|$BASIS" = "0|prompt" ]; }
ck_keep_decline() { newcase; setcfg '{"consent": "ask"}'; XENV="HMD_SKILLS_ASSUME=tty"; gate frontend-design prompt-preinstall 'j\n'; XENV=""
                    gate frontend-design hmd-skills-install; [ "$RC" = 10 ] && [ "$(state_of frontend-design)" = declined ]; }

# mutant NAME OLD NEW CHECK: copy the library with its sibling tools and the manifest, change the ONE occurrence of OLD
# into NEW (a refactor that moves OLD is a FAIL here, never a quiet pass), then CHECK must pass on the pristine copy
# and fail on the broken one.
mutant() {
  local name="$1" old="$2" new="$3" check="$4" dir="$TMP/mut/$1" real="$LIB"
  mkdir -p "$dir/bin/lib"
  cp "$REPO/bin/lib/skills_consent.sh" "$REPO/bin/lib/skills_config.py" "$REPO/bin/lib/skills_lock.py" "$REPO/bin/lib/select.sh" "$dir/bin/lib/"
  cp "$REPO/skills.manifest.json" "$dir/skills.manifest.json"
  LIB="$dir/bin/lib/skills_consent.sh"
  if ! "$check" >/dev/null 2>&1; then bad "H/$name: the check does not pass on an unbroken copy"; LIB="$real"; return; fi
  if ! python3 -I -c 'import sys
path, old, new = sys.argv[1:4]
text = open(path, encoding="utf-8").read()
sys.exit(1) if text.count(old) != 1 else open(path, "w", encoding="utf-8").write(text.replace(old, new))' "$LIB" "$old" "$new"; then
    bad "H/$name: the line to break is not in the library exactly once"; LIB="$real"; return
  fi
  if "$check" >/dev/null 2>&1; then bad "H/$name: the break SURVIVED"; else ok "H/$name: the break is caught"; fi
  LIB="$real"
}
mutant yes-ignored       '[ "${HMD_SKILLS_YES:-}" = 1 ]'                              '[ "${HMD_SKILLS_YES:-}" = 0 ]'     ck_yes
mutant marker-ignored    '[ -f "$home/setup-done" ] && _HMD_SC_MARKER=1'              '[ -f "$home/setup-done" ] && _HMD_SC_MARKER=0' ck_marker
mutant allowlist-anyone  '*"$nl$1$nl"*) return 0 ;;'                                  '*) return 0 ;;'                    ck_allow_miss
mutant decline-mislabeled '2) _hmd_sc_record "$id" "$via" declined; return 11 ;;'     '2) _hmd_sc_record "$id" "$via" suggested; return 11 ;;' ck_decline_row
mutant defer-status      '"$1" "$3" >&2
  return 10'                                                                          '"$1" "$3" >&2
  return 11'                                                                          ck_defer_rc
mutant first-run-scope   'first-run*) _HMD_SC_SCOPE=machine ;;'                       'first-run*) _HMD_SC_SCOPE=project ;;' ck_scope
mutant new-broken-installs '_HMD_SC_BROKEN=1'                                          '_HMD_SC_MODE=auto'                 ck_new_broken
mutant memo-forgotten    'if [ "$was_declined" = 1 ] && [ "$explicit" = 0 ]; then return 11; fi' 'if false; then return 11; fi' ck_memo
mutant explicit-not-asked ' && [ "$explicit" = 0 ]; then return 11; fi'               '; then return 11; fi'              ck_explicit
mutant decline-overwritten '[ "$4" = 1 ] || _hmd_sc_record "$1" "$2" suggested'        '_hmd_sc_record "$1" "$2" suggested' ck_keep_decline

finish
