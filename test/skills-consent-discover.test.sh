#!/usr/bin/env bash
# test/skills-consent-discover.test.sh -- bin/discover-skills `install` asks before it clones
# (3.x M1 plan, task T5.2: docs/superpowers/plans/2026-11-12-3x-m1-skill-registry.md, "Consent model").
#
# `discover-skills install` is what an agent runs mid-session when it needs a skill, and it used to clone whatever it was told to, at once.
# A NEW install now asks bin/lib/skills_consent.sh first (hmd_skills_consent <name> discover-skills):
#   ask (the default of a new install), no terminal, no yes   -> nothing is cloned, the skill becomes a `suggested` lock row, exit 3
#                                                                "consent required" (so the agent relays the question to the person)
#   HMD_SKILLS_YES=1, consent auto, grandfathered, allowlisted, "Install now"
#                                                             -> cloned and receipted as before, plus a lock row `installed` with its consent basis
#   "Never ask again"                                         -> a `declined` row, exit 4, and the person is not asked again
#
# THE CONTRACT UNDER TEST
#   A  ask, no terminal, no yes: exit 3, "consent required", no clone, no skill directory, no receipt, a `suggested` row in the PROJECT lock
#   B  yes (HMD_SKILLS_YES=1): the three stdout lines the command always printed, the one clone, a generated SKILL.md, a receipt line and an
#      `installed` row (consent yes-flag, why rule / evidence / via, the commit as content_hash) in the SAME project lock the deferral wrote to,
#      so the suggested row moves to installed and the machine lock has nothing
#   C  consent auto (environment, settings file) and a grandfathered install (setup marker, no settings file) install, with the basis recorded
#   D  allowlist: a listed skill installs, any other one is deferred
#   E  the prompt (HMD_SKILLS_ASSUME seam of the gate): Install now, Not now, Never ask again, and a decline is remembered
#   F  nothing to ask is never asked: an installed skill, a name the registry does not know
#   G  `install owner/repo`, a repository the registry does not list, is gated like every other install
#   H  a plugin tree without the gate (the partial trees of older suites) installs as it always did, said on stderr; a gate that cannot load defers
#   I  SKILL.md generation no longer uses sed '1{/re/d}', which BSD sed (macOS) rejects: this suite's sed rejects it too, so B4 can go RED
#   J  an approval by NAME (an allowlisted name, consent auto, an install that predates the model: C, D) counts only for the repository
#      skills.manifest.json lists for that name. Any other repository (`install attacker/frontend-design` with frontend-design allowlisted, the
#      one-argument and the two-argument form) is asked like consent=ask: exit 3 without a terminal, the menu with one, a yes still installs it. A manifest
#      that cannot vouch for a repository (not valid, or the module that reads it missing) approves nothing
#
# HERMETIC. HOME, HEIMDALL_HOME and the project are throwaway directories, `git` is a PATH fake (it logs `clone` and makes the files a skill has),
# the plugin tree is a copy of bin/discover-skills and the libraries a consented install reads, there is no network, nothing outside $WORK is touched.
# EXIT: 0 = every assertion passes; 1 = any FAIL.
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SELF_DIR/.." && pwd)"
DISCOVER="$REPO/bin/discover-skills"
LOCKPY="$REPO/bin/lib/skills_lock.py"
PASS=0
FAIL=0
ok()    { PASS=$((PASS + 1)); printf '  \033[32mPASS\033[0m %s\n' "$1"; }
bad()   { FAIL=$((FAIL + 1)); printf '  \033[31mFAIL\033[0m %s\n' "$1"; if [ -n "${2:-}" ]; then printf '       %s\n' "$2"; fi; }
eq()    { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected [$2], got [$3]"; fi; }
has()   { if grep -qF -- "$3" <<<"$2"; then ok "$1"; else bad "$1" "[$3] is not in [$2]"; fi; }
lacks() { if grep -qF -- "$3" <<<"$2"; then bad "$1" "[$3] is in [$2]"; else ok "$1"; fi; }

echo "skills-consent-discover"

command -v python3 >/dev/null 2>&1 || { echo "FATAL: python3 is required"; exit 2; }
for f in "$DISCOVER" "$LOCKPY" "$REPO/bin/lib/skills_consent.sh" "$REPO/bin/lib/skills_config.py" "$REPO/bin/lib/select.sh" \
         "$REPO/bin/lib/install-receipt.sh" "$REPO/bin/lib/skills_manifest.py" "$REPO/skills.manifest.json" "$SELF_DIR/lib/py-pin.sh"; do
  [ -f "$f" ] || { echo "FATAL: $f is missing"; exit 2; }
done

WORK="$(mktemp -d /tmp/test-skills-consent-discover-XXXXXX)" || exit 1
trap 'rm -rf "$WORK"' EXIT
# python3 straight to the real interpreter: a version-manager shim costs ~0.4 s a call and an install starts python a handful of times
# shellcheck source=lib/py-pin.sh disable=SC1091
. "$SELF_DIR/lib/py-pin.sh" && hmd_test_pin_python3 "$WORK/pybin"

FAKEBIN="$WORK/fakebin"
GIT_LOG="$WORK/git.log"
KEYS="$WORK/keys"
OUT="$WORK/out"
ERR="$WORK/err"
NL=$'\n'
mkdir -p "$FAKEBIN"

# git: `clone` is logged and made (a CLAUDE.md and a skill.json: what makes install_skill write a SKILL.md); `git -C DIR rev-parse` answers a commit.
cat > "$FAKEBIN/git" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  clone)
    echo "git $*" >> "$FAKE_GIT_LOG"
    dest=""
    for a in "$@"; do dest="$a"; done
    mkdir -p "$dest"
    printf '# CLAUDE.md\nSkill body line\n' > "$dest/CLAUDE.md"
    printf '{"description": "A test skill"}' > "$dest/skill.json" ;;
  -C) printf 'abcdef123456\n' ;;
esac
exit 0
SH

# sed: rejects the one script GNU sed accepts and BSD sed (macOS) does not, with BSD's own words; every other call is the system sed.
cat > "$FAKEBIN/sed" <<'SH'
#!/bin/sh
real=/usr/bin/sed
[ -x "$real" ] || real=/bin/sed
for a in "$@"; do
  case "$a" in
    '1{/'*'/d}') echo "sed: 1: \"$a\": extra characters at the end of d command" >&2; exit 1 ;;
  esac
done
exec "$real" "$@"
SH
chmod +x "$FAKEBIN/git" "$FAKEBIN/sed"

# The registry names two skills the manifest lists, with the repositories the manifest gives them, so the gate's `suggested` row and the
# install's `installed` row are about the same repo.
repo_of() {
  python3 -I -c 'import json, sys
doc = json.load(open(sys.argv[1], encoding="utf-8"))
print(next((e["repo"] for e in doc["entries"] if e["id"] == sys.argv[2]), ""))' "$REPO/skills.manifest.json" "$1"
}
UI_REPO="$(repo_of ui-ux-pro-max)"
GODO_REPO="$(repo_of godogen)"
[ -n "$UI_REPO" ] && [ -n "$GODO_REPO" ] || { echo "FATAL: skills.manifest.json does not list ui-ux-pro-max and godogen"; exit 2; }
printf '{"version": "test", "skills": [\n  {"name": "ui-ux-pro-max", "repo": "%s", "description": "UI work", "category": "design", "keywords": ["ui"]},\n  {"name": "godogen", "repo": "%s", "description": "Godot games", "category": "gamedev", "keywords": ["godot"]}\n]}\n' \
  "$UI_REPO" "$GODO_REPO" > "$WORK/registry.json"

# make_plugin DIR GATE: a plugin tree holding the real script and the libraries it reads. GATE: yes (the real consent gate and what it reads),
# no (a tree that predates the consent model), broken (a gate file that defines nothing).
make_plugin() {
  mkdir -p "$1/bin/lib"
  cp "$DISCOVER" "$1/bin/discover-skills"
  chmod +x "$1/bin/discover-skills"
  cp "$REPO/bin/lib/install-receipt.sh" "$LOCKPY" "$1/bin/lib/"
  cp "$WORK/registry.json" "$1/skills-registry.json"
  case "$2" in
    yes)
      cp "$REPO/bin/lib/skills_consent.sh" "$REPO/bin/lib/skills_config.py" "$REPO/bin/lib/skills_manifest.py" "$REPO/bin/lib/select.sh" "$1/bin/lib/"
      cp "$REPO/skills.manifest.json" "$1/skills.manifest.json" ;;
    broken)
      : > "$1/bin/lib/skills_consent.sh" ;;
  esac
}
PLUG="$WORK/plugin"; make_plugin "$PLUG" yes
PLUG_NOGATE="$WORK/plugin-nogate"; make_plugin "$PLUG_NOGATE" no
PLUG_BROKEN="$WORK/plugin-broken"; make_plugin "$PLUG_BROKEN" broken

# ── harness ──────────────────────────────────────────────────────────────────────────────────────────────────────
N=0; HH=""; PROJ=""; HOMEDIR=""; XENV=""; DSP=""; RC=""
newcase() {   # a fresh HEIMDALL_HOME, HOME and project, no extra environment, nothing typed
  N=$((N + 1)); HH="$WORK/hh.$N"; PROJ="$WORK/proj.$N"; HOMEDIR="$WORK/home.$N"
  mkdir -p "$PROJ" "$HOMEDIR"
  XENV=""; DSP=""
  : > "$GIT_LOG"; : > "$KEYS"
}
setcfg() { mkdir -p "$HH"; printf '%s\n' "$1" > "$HH/skills-config.json"; }
marker() { mkdir -p "$HH"; : > "$HH/setup-done"; }
keys()   { printf '%b' "$1" > "$KEYS"; }
skill_dir() { printf '%s/.claude/skills/%s' "$HOMEDIR" "$1"; }
receipt()   { cat "$HH/receipts/installs-run-test.ndjson" 2>/dev/null; }

# ds ARGS... -> RC OUT ERR: bin/discover-skills of the plugin tree $DSP (default the full one), from the project, in the throwaway HOME. Its stdin is
# the file $KEYS and its stdout a file, so there is never a terminal unless the HMD_SKILLS_ASSUME seam says so.
ds() {
  # shellcheck disable=SC2086  # XENV is a list of NAME=value words on purpose
  ( cd "$PROJ" && env -i PATH="$FAKEBIN:$PATH" HOME="$HOMEDIR" HEIMDALL_HOME="$HH" LC_ALL=C TERM=dumb HMD_RUN_ID=run-test FAKE_GIT_LOG="$GIT_LOG" $XENV \
      "${DSP:-$PLUG}/bin/discover-skills" "$@" ) <"$KEYS" >"$OUT" 2>"$ERR"
  RC=$?
}

prow() { python3 -I "$LOCKPY" read --scope project --project-dir "$PROJ" --id "$1" 2>/dev/null; }
mrow() { HEIMDALL_HOME="$HH" python3 -I "$LOCKPY" read --scope machine --id "$1" 2>/dev/null; }
# lockinfo ROW -> state|consent|why.rule|why.evidence|why.via|content_hash|kind|ref of a lock row; `no-row` when there is none
lockinfo() {
  if [ -z "$1" ]; then echo no-row; return 0; fi
  python3 -I -c 'import json, sys
r = json.loads(sys.argv[1])
print(r["state"] + "|" + r["consent"] + "|" + r["why"]["rule"] + "|" + str(r["why"]["evidence"]) + "|" + r["why"]["via"] + "|" + str(r["content_hash"]) + "|" + r["kind"] + "|" + r["ref"])' "$1"
}
state_consent() { lockinfo "$(prow "$1")" | cut -d'|' -f1,2; }   # state_consent ID -> state|consent of the row in the project lock

# ╔═ A. ask, no terminal, no yes ═══════════════════════════════════════════════════════════════════════════════════╗
echo "A. ask (the default of a new install), no terminal, no yes: nothing is installed"
newcase; ds install ui-ux-pro-max
eq  "A1 exit 3: consent required" 3 "$RC"
has "A2 stdout says so and names the skill and its repo" "$(cat "$OUT")" "consent required: ui-ux-pro-max ($UI_REPO) was not installed"
has "A3 stderr carries the gate's one line" "$(cat "$ERR")" "hmd: recommended skill ui-ux-pro-max not installed"
eq  "A4 no clone was made" "" "$(cat "$GIT_LOG")"
if [ ! -e "$(skill_dir ui-ux-pro-max)" ]; then ok "A5 no skill directory was created"; else bad "A5 the skill directory exists"; fi
if [ ! -e "$HH/receipts/installs-run-test.ndjson" ]; then ok "A6 no receipt line: no install was attempted"; else bad "A6 a receipt was written" "$(receipt)"; fi
eq  "A7 a suggested row in the project lock: why = explicit / the repo / discover-skills, kind from the manifest" \
    "suggested|n/a|explicit|$UI_REPO|discover-skills|None|github-skill|$UI_REPO" "$(lockinfo "$(prow ui-ux-pro-max)")"

# ╔═ B. the person says yes ════════════════════════════════════════════════════════════════════════════════════════╗
echo "B. HMD_SKILLS_YES=1 (the case continues in the same project): cloned, receipted, and the lock row moves to installed"
XENV="HMD_SKILLS_YES=1"; ds install ui-ux-pro-max
D="$(skill_dir ui-ux-pro-max)"
eq  "B1 exit 0" 0 "$RC"
eq  "B2 stdout is what it always was" "INSTALLING: ui-ux-pro-max from $UI_REPO...${NL}OK: Installed ui-ux-pro-max to $D${NL}OK: Generated SKILL.md for Claude Code discovery" "$(cat "$OUT")"
eq  "B3 exactly one clone, of the registry's repo, into the skills directory" "git clone --depth 1 https://github.com/$UI_REPO.git $D" "$(cat "$GIT_LOG")"
eq  "B4 SKILL.md is generated from skill.json and CLAUDE.md without its '# CLAUDE.md' header line (the sed of this suite rejects 1{/re/d} like macOS's)" \
    "$(printf -- '---\nname: ui-ux-pro-max\ndescription: A test skill\n---\n\nSkill body line')" "$(cat "$D/SKILL.md" 2>/dev/null)"
has "B5 the receipt line names the skill and the commit cloned" "$(receipt)" '"kind":"skill","name":"ui-ux-pro-max","version":"abcdef123456"'
has "B6 ... and says it worked, via discover-skills" "$(receipt)" '"result":"ok","via":"discover-skills"'
eq  "B7 the project row is installed: yes-flag, the same why, the commit as content_hash" \
    "installed|yes-flag|explicit|$UI_REPO|discover-skills|abcdef123456|github-skill|$UI_REPO" "$(lockinfo "$(prow ui-ux-pro-max)")"
eq  "B8 the machine lock has no row: one skill, one lock" no-row "$(lockinfo "$(mrow ui-ux-pro-max)")"

# ╔═ C. consent auto, grandfathered ════════════════════════════════════════════════════════════════════════════════╗
echo "C. consent auto and grandfathered installs: today's behaviour, with the basis recorded"
newcase; XENV="HMD_SKILLS_CONSENT=auto"; ds install ui-ux-pro-max
eq "C1 HMD_SKILLS_CONSENT=auto: exit 0, installed, consent explicit" "0 installed|explicit" "$RC $(state_consent ui-ux-pro-max)"
eq "C2 ... and it cloned" "git clone --depth 1 https://github.com/$UI_REPO.git $(skill_dir ui-ux-pro-max)" "$(cat "$GIT_LOG")"
newcase; setcfg '{"consent": "auto", "grandfathered": false}'; ds install ui-ux-pro-max
eq "C3 consent auto in skills-config.json: exit 0, installed, consent explicit" "0 installed|explicit" "$RC $(state_consent ui-ux-pro-max)"
newcase; marker; ds install ui-ux-pro-max
eq "C4 an install that predates the model (setup marker, no settings file): exit 0, installed, consent auto-legacy" "0 installed|auto-legacy" "$RC $(state_consent ui-ux-pro-max)"

# ╔═ D. allowlist ══════════════════════════════════════════════════════════════════════════════════════════════════╗
echo "D. allowlist: a listed skill installs, any other one is asked like ask"
newcase; setcfg '{"consent": "allowlist", "allowlist": ["ui-ux-pro-max"]}'
ds install ui-ux-pro-max
eq "D1 a listed skill: exit 0, installed, consent allowlist" "0 installed|allowlist" "$RC $(state_consent ui-ux-pro-max)"
ds install godogen
eq    "D2 an unlisted one, no terminal: exit 3 and a suggested row" "3 suggested|n/a" "$RC $(state_consent godogen)"
lacks "D3 ... and only the listed one was cloned" "$(cat "$GIT_LOG")" "godogen"

# ╔═ E. the prompt ═════════════════════════════════════════════════════════════════════════════════════════════════╗
echo "E. the prompt (HMD_SKILLS_ASSUME=tty: keys come from stdin; the menu opens on Not now; k = up, j = down, Enter confirms)"
newcase; XENV="HMD_SKILLS_ASSUME=tty"; keys 'k\n'; ds install ui-ux-pro-max
eq "E1 Install now: exit 0, installed, consent prompt, cloned" "0 installed|prompt 1" "$RC $(state_consent ui-ux-pro-max) $(grep -c clone "$GIT_LOG")"
newcase; XENV="HMD_SKILLS_ASSUME=tty"; keys '\n'; ds install ui-ux-pro-max
eq "E2 Not now (the default): exit 3, suggested, no clone" "3 suggested|n/a 0" "$RC $(state_consent ui-ux-pro-max) $(grep -c clone "$GIT_LOG")"
newcase; XENV="HMD_SKILLS_ASSUME=tty"; keys 'j\n'; ds install ui-ux-pro-max
eq  "E3 Never ask again: exit 4, declined, no clone" "4 declined|n/a 0" "$RC $(state_consent ui-ux-pro-max) $(grep -c clone "$GIT_LOG")"
has "E4 ... and stdout says declined, and how to be asked again" "$(cat "$OUT")" "declined: ui-ux-pro-max was declined earlier"
keys 'k\n'; ds install ui-ux-pro-max
eq    "E5 a decline is remembered: keys that would install are not even read, exit 4, still no clone" "4 0" "$RC $(grep -c clone "$GIT_LOG")"
lacks "E6 ... and no menu is drawn" "$(cat "$ERR")" "hmd: install skill"

# ╔═ F. nothing to ask ═════════════════════════════════════════════════════════════════════════════════════════════╗
echo "F. a skill that is already installed, a name nobody knows: no question"
newcase; mkdir -p "$(skill_dir ui-ux-pro-max)"; ds install ui-ux-pro-max
eq "F1 an installed skill is left alone: exit 0, ALREADY INSTALLED" "0 ALREADY INSTALLED: ui-ux-pro-max at $(skill_dir ui-ux-pro-max)" "$RC $(cat "$OUT")"
eq "F2 ... the gate was not asked: nothing on stderr, no lock row" "|no-row" "$(cat "$ERR")|$(lockinfo "$(prow ui-ux-pro-max)")"
newcase; ds install nosuch
eq "F3 an unknown name is the usual error, not a consent question: exit 1" "1 ERROR: Skill 'nosuch' not in registry. Use: discover-skills install owner/repo" "$RC $(cat "$OUT")"
eq "F4 ... nothing cloned, nothing on stderr, no lock row" "||no-row" "$(cat "$GIT_LOG")|$(cat "$ERR")|$(lockinfo "$(prow nosuch)")"

# ╔═ G. owner/repo ═════════════════════════════════════════════════════════════════════════════════════════════════╗
echo "G. install owner/repo: a repository nobody listed is gated like every other install"
newcase; ds install owner/plain-skill
eq "G1 no terminal, no yes: exit 3, nothing cloned, no directory" "3 0 absent" "$RC $(grep -c clone "$GIT_LOG") $([ -e "$(skill_dir plain-skill)" ] && echo present || echo absent)"
XENV="HMD_SKILLS_YES=1"; ds install owner/plain-skill
eq "G2 with a yes: cloned into a directory named after the repo, an installed row recording it" \
   "0 installed|yes-flag|explicit|owner/plain-skill|discover-skills|abcdef123456|github-skill|owner/plain-skill" "$RC $(lockinfo "$(prow plain-skill)")"

# ╔═ H. the gate is missing, the gate does not load ════════════════════════════════════════════════════════════════╗
echo "H. a plugin tree without the gate installs as it always did, said on stderr; a gate that cannot load installs nothing"
newcase; DSP="$PLUG_NOGATE"; ds install ui-ux-pro-max
eq  "H1 no skills_consent.sh (a tree that predates the model): exit 0 and the clone is made" "0 1" "$RC $(grep -c clone "$GIT_LOG")"
has "H2 ... and stderr says it was not asked" "$(cat "$ERR")" "skills_consent.sh is missing; installing ui-ux-pro-max without a consent check"
newcase; DSP="$PLUG_BROKEN"; ds install ui-ux-pro-max
eq  "H3 a skills_consent.sh that defines no gate: exit 3 and no clone" "3 0" "$RC $(grep -c clone "$GIT_LOG")"
has "H4 ... and stdout says why" "$(cat "$OUT")" "cannot load the consent gate"

# ╔═ I. the portable sed ═══════════════════════════════════════════════════════════════════════════════════════════╗
echo "I. the sed this suite puts on PATH rejects 1{/re/d} the way BSD sed does, so B4 proves the portable form"
printf '# CLAUDE.md\nbody\n' > "$WORK/claude.md"
PATH="$FAKEBIN:$PATH" sed '1{/^# CLAUDE\.md$/d}' "$WORK/claude.md" >/dev/null 2>&1; rc=$?
if [ "$rc" -ne 0 ]; then ok "I1 sed '1{/re/d}' fails under the suite's sed (exit $rc)"; else bad "I1 the suite's sed accepted sed '1{/re/d}', so B4 proves nothing"; fi
eq "I2 the same sed still does ordinary work" "body" "$(PATH="$FAKEBIN:$PATH" sed 1d "$WORK/claude.md")"

# ╔═ J. an approval by name is not an approval of a repository ═════════════════════════════════════════════════════╗
echo "J. an allowlisted name or consent auto approves the repository the manifest lists for that name, and no other: any other one is asked"
FOREIGN_FD="attacker/frontend-design"   # frontend-design is a manifest id (a plugin): the finding's own example
FOREIGN_UI="attacker/ui-ux-pro-max"     # ui-ux-pro-max is a manifest github-skill whose repository is $UI_REPO
newcase; setcfg '{"consent": "allowlist", "allowlist": ["frontend-design"]}'; ds install "$FOREIGN_FD"
eq  "J1 frontend-design allowlisted, attacker/frontend-design asked for: exit 3, nothing cloned, no skill directory" "3 0 absent" \
    "$RC $(grep -c clone "$GIT_LOG") $([ -e "$(skill_dir frontend-design)" ] && echo present || echo absent)"
has "J2 ... stdout names the repository a yes would install" "$(cat "$OUT")" "consent required: frontend-design (attacker/frontend-design) was not installed"
has "J3 ... and stderr says why the allowlist did not apply" "$(cat "$ERR")" "attacker/frontend-design is not the repository the skills manifest lists for frontend-design"
newcase; setcfg '{"consent": "allowlist", "allowlist": ["ui-ux-pro-max"]}'; ds install "$FOREIGN_UI"
eq "J4 ui-ux-pro-max allowlisted, attacker/ui-ux-pro-max asked for: exit 3, nothing cloned, a suggested row" "3 0 suggested|n/a" "$RC $(grep -c clone "$GIT_LOG") $(state_consent ui-ux-pro-max)"
ds install ui-ux-pro-max "$FOREIGN_UI"
eq "J5 the two-argument form (NAME REPO) is bound the same way: exit 3, nothing cloned" "3 0" "$RC $(grep -c clone "$GIT_LOG")"
newcase; setcfg '{"consent": "allowlist", "allowlist": ["ui-ux-pro-max", "godogen"]}'; ds install ui-ux-pro-max "$UI_REPO"
eq "J6 the repository the manifest lists, named in the two-argument form: exit 0, installed, consent allowlist" "0 installed|allowlist" "$RC $(state_consent ui-ux-pro-max)"
ds install "$GODO_REPO"
eq "J7 ... and as owner/repo, where the repository's name is the id: exit 0, installed, consent allowlist" "0 installed|allowlist" "$RC $(state_consent godogen)"
newcase; XENV="HMD_SKILLS_CONSENT=auto"; ds install "$FOREIGN_UI"
eq "J8 consent auto does not approve another repository either: exit 3, nothing cloned" "3 0" "$RC $(grep -c clone "$GIT_LOG")"
newcase; marker; ds install owner/plain-skill
eq "J9 nor does an install that predates the model (setup marker, no settings file), for a repository the manifest does not list: exit 3, nothing cloned" "3 0" "$RC $(grep -c clone "$GIT_LOG")"
newcase; setcfg '{"consent": "allowlist", "allowlist": ["frontend-design"]}'; XENV="HMD_SKILLS_YES=1"; ds install "$FOREIGN_FD"
eq "J10 the person's yes still installs it: exit 0, installed, consent yes-flag" "0 installed|yes-flag" "$RC $(state_consent frontend-design)"
newcase; setcfg '{"consent": "allowlist", "allowlist": ["frontend-design"]}'; XENV="HMD_SKILLS_ASSUME=tty"; keys 'k\n'; ds install "$FOREIGN_FD"
eq "J11 on a terminal the same install is the menu, not a refusal: Install now installs it, consent prompt" "0 installed|prompt" "$RC $(state_consent frontend-design)"
PLUG_BADMAN="$WORK/plugin-badmanifest"; make_plugin "$PLUG_BADMAN" yes; printf '{}\n' > "$PLUG_BADMAN/skills.manifest.json"
newcase; setcfg '{"consent": "allowlist", "allowlist": ["ui-ux-pro-max"]}'; DSP="$PLUG_BADMAN"; ds install ui-ux-pro-max
eq  "J12 a manifest that is not valid vouches for nothing, the registry's repository included: exit 3, nothing cloned" "3 0" "$RC $(grep -c clone "$GIT_LOG")"
has "J13 ... and stderr says the manifest could not be used" "$(cat "$ERR")" "the skills manifest cannot vouch for a repository"

echo
echo "skills-consent-discover: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && [ "$PASS" -gt 0 ]
