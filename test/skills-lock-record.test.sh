#!/usr/bin/env bash
# test/skills-lock-record.test.sh -- the install sites record what they install in skills.lock (3.x M1 plan, task T4.3).
#
# bin/lib/install-receipt.sh already writes ONE receipt line per install attempt. T4.3 adds the durable half: after a
# SUCCESSFUL hmd_plugin_install / hmd_skill_install the lib calls bin/lib/skills_lock.py, so the lock says what hmd put on
# the machine and why. Two promises shape every case below: the receipt line stays byte-for-byte what it was (the Run
# Receipt and test/plugin-install-receipt.test.sh read it), and the lock is bookkeeping that can never change an install's
# own status (the callers are fail-open launchers running under set -e).
#
# THE CONTRACT UNDER TEST
#   A  the receipt is byte-identical to the run without the lock tool (same lines, same stderr), and pinned literally
#   B  the row: the manifest id (not plugin@marketplace), kind, ref, version, source, pin, content_hash, why.via, why.run
#   C  scope: first-run* and install.sh -> the machine lock; a project-triggered install -> the project's lock ($WORK_DIR);
#      no project known -> the machine lock, and the working directory is never written to
#   D  containment: a corrupt lock, a lock another writer holds, a crashing interpreter -> ONE stderr line, the install's own
#      status, the receipt line already written; a failed install records nothing and says nothing extra; a tree without
#      the lock tool records nothing, silently
#   E  INV-S6: receipt `ok` lines (plugin, skill) == lock `installed` rows, and `skills_lock.py verify` accepts both files
#   F  why: HMD_INSTALL_WHY_RULE / HMD_INSTALL_WHY_EVIDENCE land in why.rule / why.evidence; a value starting with '-' is
#      data, never a flag; evidence is cut to 64 characters and loses its control characters (INV-S10)
#   G  consent: HMD_SKILLS_CONSENT_BASIS is the row's consent; a value that is no consent is ignored without a word; n/a is
#      "no decision" and never overwrites an earlier one
#   H  a suggested / declined row becomes installed and keeps the why that triggered it
#   I  the suite can go RED: six one-line breaks of the lib are each caught by the property that guards them
#
# HERMETIC. env -i, throwaway HOME / HEIMDALL_HOME / project / working directory; `claude` and `git` are PATH fakes;
# nothing is installed, no network, no real lock is touched.
# EXIT: 0 = every assertion passes; 1 = any FAIL.
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$REPO/bin/lib"
TOOL="$LIB/skills_lock.py"

PASS=0
FAIL=0
WHY=""
ok()    { PASS=$((PASS + 1)); printf '  \033[32mPASS\033[0m %s\n' "$1"; }
bad()   { FAIL=$((FAIL + 1)); printf '  \033[31mFAIL\033[0m %s\n' "$1"; if [ -n "${2:-}" ]; then printf '       %s\n' "$2"; fi; }
eq()    { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "want: $2"; printf '       got:  %s\n' "$3"; fi; }
has()   { case "$3" in *"$2"*) ok "$1" ;; *) bad "$1" "want '$2' in: $3" ;; esac; }
check() { if "$2"; then ok "$1"; else bad "$1" "$WHY"; fi; }   # check NAME PROPERTY: the property returns 0 when it holds

echo "skills-lock-record"

command -v python3 >/dev/null 2>&1 || { echo "FATAL: python3 is required"; exit 1; }
if [ ! -f "$TOOL" ]; then
  bad "0. bin/lib/skills_lock.py is missing"
  echo; echo "skills-lock-record: $PASS passed, $FAIL failed"
  exit 1
fi

# ── sandbox ──────────────────────────────────────────────────────────────────────────────────────────────────────
TMP="$(mktemp -d /tmp/test-skills-lock-record-XXXXXX)" || exit 1
HOLDER_PID=""
release() {  # let go of the lock a `hold` took: kill its holder
  if [ -n "$HOLDER_PID" ]; then kill "$HOLDER_PID" 2>/dev/null; wait "$HOLDER_PID" 2>/dev/null; HOLDER_PID=""; fi
  return 0
}
trap 'release; rm -rf "$TMP"' EXIT

# The REAL interpreter on the fakes' PATH: a version-manager shim costs ~0.4 s a call and this suite starts python ~50 times.
REALPY="$(python3 -I -c 'import sys; print(sys.executable)' 2>/dev/null)"
if [ -z "$REALPY" ] || [ ! -x "$REALPY" ]; then echo "FATAL: no usable python3"; exit 1; fi
FAKEBIN="$TMP/fakebin"
mkdir -p "$FAKEBIN" "$TMP/crashpy" "$TMP/bare"
ln -s "$REALPY" "$FAKEBIN/python3"

cat >"$TMP/crashpy/python3" <<'SH'
#!/bin/sh
echo "python3: noise on the first line" >&2
echo "python3: the interpreter died" >&2
exit 5
SH
chmod +x "$TMP/crashpy/python3"

cat >"$FAKEBIN/claude" <<'SH'
#!/usr/bin/env bash
# `claude plugins ...`: install records the id (FAKE_FAIL_RE fails a matching plugin name), list prints every installed id
# at version ${FAKE_VERSION:-5.0.7}, marketplace list/add read and write $FAKE_STATE/markets.
case "${1:-}" in plugin|plugins) ;; *) exit 0 ;; esac
case "${2:-}" in
  install)
    id="${3:-}"; name="${id%%@*}"
    if [ -n "${FAKE_FAIL_RE:-}" ] && printf '%s' "$name" | grep -Eq "$FAKE_FAIL_RE"; then
      printf '%s\n' "✘ Failed to install plugin \"$id\": plugin not found in marketplace" >&2
      exit 1
    fi
    echo "$id" >>"$FAKE_STATE/installed"
    echo "Successfully installed plugin: $id (scope: user)"
    exit 0 ;;
  list)
    printf '['; n=0
    while IFS= read -r id; do
      [ -n "$id" ] || continue
      [ "$n" -eq 0 ] || printf ','
      n=1
      printf '\n  {\n    "id": "%s",\n    "version": "%s",\n    "scope": "user",\n    "enabled": true\n  }' "$id" "${FAKE_VERSION:-5.0.7}"
    done <"$FAKE_STATE/installed"
    printf '\n]\n'
    exit 0 ;;
  marketplace)
    case "${3:-}" in
      list) cat "$FAKE_STATE/markets"; exit 0 ;;
      add)  echo "${4##*/}" >>"$FAKE_STATE/markets"; exit 0 ;;
    esac ;;
esac
exit 0
SH
cat >"$FAKEBIN/git" <<'SH'
#!/usr/bin/env bash
# clone creates the destination (and fails when FAKE_GIT_FAIL_RE matches the url); -C <dir> rev-parse prints a commit id.
case "${1:-}" in
  clone)
    dest="${@: -1}"; url="${@: -2:1}"
    if [ -n "${FAKE_GIT_FAIL_RE:-}" ] && printf '%s' "$url" | grep -Eq "$FAKE_GIT_FAIL_RE"; then
      echo "fatal: unable to access '$url'" >&2
      exit 128
    fi
    mkdir -p "$dest/.git"
    exit 0 ;;
  -C) shift 2; if [ "${1:-}" = "rev-parse" ]; then echo "abc1234def56"; exit 0; fi ;;
esac
exit 0
SH
chmod +x "$FAKEBIN/claude" "$FAKEBIN/git"

# The bare tree: the receipt lib with NO lock tool beside it -- what a tree without the registry runs.
cp "$LIB/install-receipt.sh" "$TMP/bare/install-receipt.sh"

cat >"$TMP/rowf.py" <<'PY'
import json, sys
path, rid, field = sys.argv[1:4]
try:
    doc = json.load(open(path))
except FileNotFoundError:
    print("<no-file>")
    sys.exit(0)
rows = [row for row in doc["entries"] if row["id"] == rid]
if not rows:
    print("<no-row>")
    sys.exit(0)
value = rows[0]
for part in field.split("."):
    value = value[part]
print(json.dumps(value))
PY

# ── helpers ──────────────────────────────────────────────────────────────────────────────────────────────────────
OFFSRC=anthropics/claude-plugins-official
LIBDIR="$LIB"      # the lib under test; the mutants swap it
WORKD=""           # the launcher's $WORK_DIR for the next probe ("" = unset)
PROBE_PATH=""      # PATH override for the next probe
CASE_N=0
HH=""; HOMED=""; PROJ=""; CWD=""; STATE=""; PROJ_LOCK=""; MACH_LOCK=""; RECEIPT=""
RC=0; OUT=""; ERR=""

newcase() {  # a fresh home, project, working directory and fake-CLI state; every path below is set here
  CASE_N=$((CASE_N + 1))
  local base="$TMP/case$CASE_N"
  HOMED="$base/home"; HH="$HOMED/.heimdall"; PROJ="$base/proj"; CWD="$base/cwd"; STATE="$base/state"
  mkdir -p "$HH" "$PROJ" "$CWD" "$STATE"
  : >"$STATE/installed"
  printf 'claude-plugins-official\nheimdall-marketplace\n' >"$STATE/markets"
  PROJ_LOCK="$PROJ/.planning/skills.lock"; MACH_LOCK="$HH/skills.lock"; RECEIPT="$HH/receipts/installs-run-t.ndjson"
}

# probe BODY [VAR=value ...] -> RC OUT ERR. BODY runs under `set -euo pipefail` (as in the launcher) after the lib under test is
# sourced; $WORK_DIR is a plain shell variable there, not exported, exactly as bin/heimdall has it.
probe() {
  local body="$1"; shift
  ( cd "$CWD" && env -i PATH="${PROBE_PATH:-$FAKEBIN:/usr/bin:/bin}" HOME="$HOMED" HEIMDALL_HOME="$HH" HMD_RUN_ID=run-t \
      FAKE_STATE="$STATE" LIBDIR="$LIBDIR" PROBE_WORK_DIR="$WORKD" "$@" \
      bash -c 'set -euo pipefail; if [ -n "$PROBE_WORK_DIR" ]; then WORK_DIR="$PROBE_WORK_DIR"; fi; . "$LIBDIR/install-receipt.sh"; '"$body" \
  ) >"$TMP/out" 2>"$TMP/err" </dev/null
  RC=$?; OUT="$(cat "$TMP/out")"; ERR="$(cat "$TMP/err")"
}

# Body fragments: each install is followed by its own status, so a lock problem that leaked into it shows.
inst_plugin() { printf 'rc=0; %s hmd_plugin_install %s@claude-plugins-official %s none %s || rc=$?; echo "rc=$rc"' "${3:-}" "$1" "$OFFSRC" "$2"; }
inst_skill()  { printf 'rc=0; hmd_skill_install %s %s "$HOME/skills/%s" %s || rc=$?; echo "rc=$rc"' "$1" "$2" "$1" "$3"; }
BODY=""
add() { BODY="$BODY$1"$'\n'; }

nlines() { if [ -z "$1" ]; then echo 0; else printf '%s\n' "$1" | wc -l | tr -d ' '; fi; }
norm()   { sed -E 's/"ts":"[^"]*"/"ts":"T"/' "$1"; }
rowf()   { python3 -I "$TMP/rowf.py" "$@"; }   # rowf LOCK ID FIELD -> the field as JSON, <no-file> or <no-row>
rowline() {  # rowline LOCK ID -> the row's own line of the lock (one row per line) with `at` replaced by T, else <no-row>
  local l
  l="$(grep -F "\"id\": \"$2\"," "$1" 2>/dev/null | head -n 1)" || true
  if [ -z "$l" ]; then printf '<no-row>'; return 0; fi
  printf '%s' "$l" | sed -e 's/^ *//' -e 's/,$//' -e 's/"at": "[^"]*"/"at": "T"/'
}
count_ok()   { norm "$1" | grep -c -E '"kind":"(plugin|skill)".*"result":"ok"' || true; }
count_inst() { local n; n="$(grep -c '"state": "installed"' "$1" 2>/dev/null || true)"; echo "${n:-0}"; }

hold() {  # hold DIR SECONDS: a background process takes DIR's advisory lock (the one skills_lock.py waits on) and keeps it
  local fifo="$TMP/ready.$$"
  mkfifo "$fifo"
  python3 -I -c 'import fcntl, os, sys, time
fd = os.open(sys.argv[1], os.O_RDONLY)
fcntl.flock(fd, fcntl.LOCK_EX)
sys.stdout.write("locked\n")
sys.stdout.flush()
time.sleep(float(sys.argv[2]))' "$1" "$2" >"$fifo" &
  HOLDER_PID=$!
  read -r _ <"$fifo"
  rm -f "$fifo"
}

# The rows a clean run must write, `at` normalised (the tool writes one row per line, keys in a fixed order).
WANT_FD_ROW='{"id": "frontend-design", "kind": "plugin", "ref": "frontend-design@claude-plugins-official", "state": "installed", "version": "5.0.7", "source": "anthropics/claude-plugins-official", "pin": "none", "content_hash": null, "consent": "n/a", "at": "T", "why": {"entry": "frontend-design", "rule": "unspecified", "evidence": null, "via": "prompt-preinstall", "run": "run-t"}}'
WANT_SKILL_ROW='{"id": "ui-ux-pro-max", "kind": "github-skill", "ref": "nextlevelbuilder/ui-ux-pro-max-skill", "state": "installed", "version": "abc1234def56", "source": "github.com/nextlevelbuilder/ui-ux-pro-max-skill", "pin": "none", "content_hash": "abc1234def56", "consent": "n/a", "at": "T", "why": {"entry": "ui-ux-pro-max", "rule": "unspecified", "evidence": null, "via": "discover_skills", "run": "run-t"}}'
WANT_SP_ROW='{"id": "superpowers", "kind": "plugin", "ref": "superpowers@claude-plugins-official", "state": "installed", "version": "5.0.7", "source": "anthropics/claude-plugins-official", "pin": "none", "content_hash": null, "consent": "n/a", "at": "T", "why": {"entry": "superpowers", "rule": "unspecified", "evidence": null, "via": "first-run", "run": "run-t"}}'
WANT_HMD_ROW='{"id": "hmd", "kind": "plugin", "ref": "hmd@heimdall", "state": "installed", "version": "5.0.7", "source": "/some/clone", "pin": "v9.9.9", "content_hash": null, "consent": "n/a", "at": "T", "why": {"entry": "hmd", "rule": "unspecified", "evidence": null, "via": "install.sh", "run": "run-t"}}'

# ── properties: each returns 0 when it holds for $LIBDIR (the real lib above, a one-line break in section I) ────────
prop_contained() {  # a corrupt project lock: the install keeps its status, ONE stderr line, the receipt is written, the lock is untouched
  newcase; WORKD="$PROJ"
  mkdir -p "$PROJ/.planning"
  printf 'not json {\n' >"$PROJ_LOCK"
  probe "$(inst_plugin frontend-design prompt-preinstall)"
  WHY="status/output [$OUT], stderr [$ERR]"
  [ "$OUT" = "rc=0" ] || return 1
  [ "$(nlines "$ERR")" = 1 ] || return 1
  case "$ERR" in *"could not record frontend-design in the skills lock (project)"*) ;; *) return 1 ;; esac
  [ "$(cat "$PROJ_LOCK")" = 'not json {' ] || { WHY="the corrupt lock was rewritten"; return 1; }
  grep -q '"result":"ok"' "$RECEIPT" 2>/dev/null || { WHY="the receipt line is missing"; return 1; }
  return 0
}
prop_installsh_machine() {  # install.sh installs are machine rows even when a project dir is known, and never touch the project
  newcase; WORKD="$PROJ"
  probe 'rc=0; hmd_plugin_install hmd@heimdall /some/clone v9.9.9 install.sh || rc=$?; echo "rc=$rc"'
  WHY="output [$OUT], stderr [$ERR], machine row [$(rowline "$MACH_LOCK" hmd)]"
  [ "$OUT" = "rc=0" ] || return 1
  [ "$(rowline "$MACH_LOCK" hmd)" = "$WANT_HMD_ROW" ] || return 1
  [ ! -e "$PROJ/.planning" ] || { WHY=".planning/ appeared in the project"; return 1; }
  return 0
}
prop_consent() {  # the basis the consent gate left becomes the row's consent
  newcase; WORKD="$PROJ"
  probe "$(inst_plugin frontend-design prompt-preinstall)" HMD_SKILLS_CONSENT_BASIS=prompt
  WHY="consent [$(rowf "$PROJ_LOCK" frontend-design consent)], stderr [$ERR]"
  [ "$(rowf "$PROJ_LOCK" frontend-design consent)" = '"prompt"' ]
}
prop_plugin_row() {  # the plugin row is keyed by the manifest id and carries every field
  newcase; WORKD="$PROJ"
  probe "$(inst_plugin frontend-design prompt-preinstall)"
  WHY="row [$(rowline "$PROJ_LOCK" frontend-design)], stderr [$ERR]"
  [ "$(rowline "$PROJ_LOCK" frontend-design)" = "$WANT_FD_ROW" ]
}
prop_hostile_why() {  # a rule or evidence that starts with '-' is data, not a flag
  newcase; WORKD="$PROJ"
  probe "$(inst_plugin slack prompt-preinstall)" HMD_INSTALL_WHY_RULE=-x HMD_INSTALL_WHY_EVIDENCE=--state=failed
  WHY="row [$(rowline "$PROJ_LOCK" slack)], stderr [$ERR]"
  [ "$(rowf "$PROJ_LOCK" slack why.rule)" = '"-x"' ] || return 1
  [ "$(rowf "$PROJ_LOCK" slack why.evidence)" = '"--state=failed"' ] || return 1
  [ "$(rowf "$PROJ_LOCK" slack state)" = '"installed"' ]
}

# ═ A-E. one realistic run: 5 installs succeed, a plugin and a skill fail ═════════════════════════════════════════════
echo "  -- a mixed run: receipt, rows, scope, INV-S6"
newcase; WORKD="$PROJ"; BODY=""
add "$(inst_plugin frontend-design prompt-preinstall)"
add "$(inst_plugin slack prompt-preinstall)"
add "$(inst_plugin devops-toolkit prompt-preinstall)"
add 'rc=0; hmd_install_known_plugin superpowers claude-plugins-official first-run || rc=$?; echo "rc=$rc"'
add "$(inst_skill ui-ux-pro-max nextlevelbuilder/ui-ux-pro-max-skill discover_skills)"
add "$(inst_skill claude-seo AgriciDaniel/claude-seo discover_skills)"
add 'rc=0; hmd_plugin_install hmd@heimdall /some/clone v9.9.9 install.sh || rc=$?; echo "rc=$rc"'
MIXED="$BODY"
probe "$MIXED" FAKE_FAIL_RE='^devops-toolkit$' FAKE_GIT_FAIL_RE='claude-seo'
T_OUT="$OUT"; T_ERR="$ERR"; T_RECEIPT="$(norm "$RECEIPT")"
eq "D: every install returns its own status: 0 0 CLI-1 0 0 git-128 0" "$(printf 'rc=0\nrc=0\nrc=1\nrc=0\nrc=0\nrc=128\nrc=0')" "$T_OUT"
eq "D: a clean run adds nothing to stderr: only the two install-failed lines" 2 "$(nlines "$T_ERR")"
eq "A: the plugin receipt line is byte-for-byte what it was" \
  '{"ts":"T","run":"run-t","kind":"plugin","name":"frontend-design@claude-plugins-official","version":"5.0.7","source":"anthropics/claude-plugins-official","pin":"none","result":"ok","via":"prompt-preinstall"}' \
  "$(printf '%s\n' "$T_RECEIPT" | sed -n 1p)"
eq "A: the skill receipt line is byte-for-byte what it was" \
  '{"ts":"T","run":"run-t","kind":"skill","name":"ui-ux-pro-max","version":"abc1234def56","source":"github.com/nextlevelbuilder/ui-ux-pro-max-skill","pin":"none","result":"ok","via":"discover_skills"}' \
  "$(printf '%s\n' "$T_RECEIPT" | sed -n 5p)"
eq "B: the plugin row: manifest id, kind, ref, version, source, pin, consent, why.via, why.run" "$WANT_FD_ROW" "$(rowline "$PROJ_LOCK" frontend-design)"
eq "B: the skill row adds the commit as content_hash" "$WANT_SKILL_ROW" "$(rowline "$PROJ_LOCK" ui-ux-pro-max)"
eq "B/C: a project-triggered plugin is a project row too (slack)" '"installed"' "$(rowf "$PROJ_LOCK" slack state)"
eq "C: first-run installs are machine rows" "$WANT_SP_ROW" "$(rowline "$MACH_LOCK" superpowers)"
eq "C: install.sh installs are machine rows, with the installer's pin" "$WANT_HMD_ROW" "$(rowline "$MACH_LOCK" hmd)"
eq "C: the project lock holds no machine row (superpowers)" "<no-row>" "$(rowline "$PROJ_LOCK" superpowers)"
eq "C: the project lock holds no machine row (hmd)" "<no-row>" "$(rowline "$PROJ_LOCK" hmd)"
eq "C: the machine lock holds no project row (frontend-design)" "<no-row>" "$(rowline "$MACH_LOCK" frontend-design)"
eq "D: a failed plugin install records no row" "<no-row>" "$(rowline "$PROJ_LOCK" devops-toolkit)"
eq "D: a failed skill clone records no row" "<no-row>" "$(rowline "$PROJ_LOCK" claude-seo)"
eq "E: INV-S6: receipt ok lines (plugin, skill) == lock installed rows (5 == 3 project + 2 machine)" \
  "$(count_ok "$RECEIPT")" "$(( $(count_inst "$PROJ_LOCK") + $(count_inst "$MACH_LOCK") ))"
eq "E: the receipt has five ok lines" 5 "$(count_ok "$RECEIPT")"
VP="$(python3 -I "$TOOL" verify --scope project --project-dir "$PROJ" 2>&1)"; VPRC=$?
VM="$(python3 -I "$TOOL" verify --scope machine 2>&1)"; VMRC=$?
if [ "$VPRC" -eq 0 ] && [ "$VMRC" -eq 0 ]; then ok "E: skills_lock.py verify accepts both files the run wrote"; else bad "E: verify rejected a lock the run wrote" "$VP / $VM"; fi

# ═ A. the same run in a tree without the lock tool: byte-identical receipt and stderr, no lock anywhere ═════════════
echo "  -- the same run without the lock tool"
newcase; WORKD="$PROJ"; LIBDIR="$TMP/bare"
probe "$MIXED" FAKE_FAIL_RE='^devops-toolkit$' FAKE_GIT_FAIL_RE='claude-seo'
LIBDIR="$LIB"
eq "A: the receipt is byte-identical to the run that records locks (timestamps aside)" "$T_RECEIPT" "$(norm "$RECEIPT")"
eq "A: so are the statuses and stderr" "$T_OUT"$'\n'"$T_ERR" "$OUT"$'\n'"$ERR"
if [ ! -e "$PROJ/.planning" ] && [ ! -e "$MACH_LOCK" ]; then ok "D: a tree without the lock tool records nothing, silently"; else bad "D: a lock appeared without the tool"; fi

# ═ C. no project known ═════════════════════════════════════════════════════════════════════════════════════════════
echo "  -- scope without a project"
newcase; WORKD=""
probe "$(inst_plugin frontend-design prompt-preinstall)"
eq "C: a project-triggered install with no project known is a machine row" "$WANT_FD_ROW" "$(rowline "$MACH_LOCK" frontend-design)"
eq "C: the working directory is never written to" "" "$(ls -A "$CWD")"

# ═ D. containment ══════════════════════════════════════════════════════════════════════════════════════════════════
echo "  -- containment"
check "D: a corrupt lock: install status kept, ONE stderr line, receipt written, lock untouched" prop_contained
newcase; WORKD="$PROJ"
mkdir -p "$PROJ/.planning"
hold "$PROJ/.planning" 30
probe "$(inst_plugin frontend-design prompt-preinstall)" HMD_SKILLS_LOCK_WAIT_S=0.3
release
eq "D: a lock another writer holds: the install still returns its own status" "rc=0" "$OUT"
eq "D: ... with ONE stderr line saying so" 1 "$(nlines "$ERR")"
has "D: ... naming the id and the scope" "could not record frontend-design in the skills lock (project)" "$ERR"
has "D: ... and the lock's own reason" "locked by another writer" "$ERR"
eq "D: ... the receipt line is written (1 ok line) and no row is" "1|<no-row>" "$(grep -c '"result":"ok"' "$RECEIPT")|$(rowline "$PROJ_LOCK" frontend-design)"
newcase; WORKD="$PROJ"; PROBE_PATH="$TMP/crashpy:$FAKEBIN:/usr/bin:/bin"
probe "$(inst_plugin frontend-design prompt-preinstall)"
PROBE_PATH=""
eq "D: an interpreter that dies with noise: the install still returns its own status" "rc=0" "$OUT"
eq "D: ... and the noise is reduced to ONE stderr line" 1 "$(nlines "$ERR")"
has "D: ... that carries the last of it" "the interpreter died" "$ERR"
newcase; WORKD="$PROJ"
probe "$(inst_plugin devops-toolkit prompt-preinstall)" FAKE_FAIL_RE='^devops-toolkit$'
eq "D: a failed install keeps the CLI's status" "rc=1" "$OUT"
eq "D: ... and says only that it failed (one stderr line)" 1 "$(nlines "$ERR")"
has "D: ... in the receipt's own words" "install failed, continuing without devops-toolkit@claude-plugins-official" "$ERR"
if [ ! -e "$PROJ/.planning" ] && [ ! -e "$MACH_LOCK" ]; then ok "D: ... and creates no lock at all"; else bad "D: a failed install touched a lock"; fi

# ═ F. why ═══════════════════════════════════════════════════════════════════════════════════════════════════════════
echo "  -- why"
newcase; WORKD="$PROJ"
probe "$(inst_plugin frontend-design prompt-preinstall)" HMD_INSTALL_WHY_RULE=prompt_ere HMD_INSTALL_WHY_EVIDENCE=react
eq "F: HMD_INSTALL_WHY_RULE lands in why.rule" '"prompt_ere"' "$(rowf "$PROJ_LOCK" frontend-design why.rule)"
eq "F: HMD_INSTALL_WHY_EVIDENCE lands in why.evidence" '"react"' "$(rowf "$PROJ_LOCK" frontend-design why.evidence)"
check "F: a rule or evidence starting with '-' is recorded as data and the state stays installed" prop_hostile_why
probe "$(inst_plugin slack prompt-preinstall)" HMD_INSTALL_WHY_EVIDENCE="$(printf 'a%.0s' {1..100})"
eq "F: INV-S10: evidence is cut to 64 characters" "\"$(printf 'a%.0s' {1..64})\"" "$(rowf "$PROJ_LOCK" slack why.evidence)"
probe "$(inst_plugin mcp-server-dev prompt-preinstall)" HMD_INSTALL_WHY_EVIDENCE=$'ab\x01cd'
eq "F: INV-S10: evidence loses its control characters" '"abcd"' "$(rowf "$PROJ_LOCK" mcp-server-dev why.evidence)"

# ═ G. consent ═══════════════════════════════════════════════════════════════════════════════════════════════════════
echo "  -- consent"
check "G: the basis the consent gate left is the row's consent" prop_consent
newcase; WORKD="$PROJ"; BODY=""
add "$(inst_plugin cp-prompt prompt-preinstall HMD_SKILLS_CONSENT_BASIS=prompt)"
add "$(inst_plugin cp-yes prompt-preinstall HMD_SKILLS_CONSENT_BASIS=yes-flag)"
add "$(inst_plugin cp-allow prompt-preinstall HMD_SKILLS_CONSENT_BASIS=allowlist)"
add "$(inst_plugin cp-explicit prompt-preinstall HMD_SKILLS_CONSENT_BASIS=explicit)"
add "$(inst_plugin cp-legacy prompt-preinstall HMD_SKILLS_CONSENT_BASIS=auto-legacy)"
add "$(inst_plugin cp-bogus prompt-preinstall HMD_SKILLS_CONSENT_BASIS=bogus)"
add "$(inst_plugin cp-na prompt-preinstall HMD_SKILLS_CONSENT_BASIS=n/a)"
add "$(inst_plugin cp-unset prompt-preinstall)"
probe "$BODY"
for pair in cp-prompt:prompt cp-yes:yes-flag cp-allow:allowlist cp-explicit:explicit cp-legacy:auto-legacy cp-bogus:n/a cp-na:n/a cp-unset:n/a; do
  eq "G: basis for ${pair%%:*} -> consent ${pair#*:}" "\"${pair#*:}\"" "$(rowf "$PROJ_LOCK" "${pair%%:*}" consent)"
done
eq "G: a basis that is no consent is ignored without a word: every install still 0, stderr empty" \
  "$(printf 'rc=0\nrc=0\nrc=0\nrc=0\nrc=0\nrc=0\nrc=0\nrc=0')|" "$OUT|$ERR"
probe "$(inst_plugin cp-prompt prompt-preinstall HMD_SKILLS_CONSENT_BASIS=n/a)"
eq "G: n/a is no decision: it never overwrites an earlier consent" '"prompt"' "$(rowf "$PROJ_LOCK" cp-prompt consent)"

# ═ H. suggested / declined -> installed ═════════════════════════════════════════════════════════════════════════════
echo "  -- suggested and declined rows"
newcase; WORKD="$PROJ"
python3 -I "$TOOL" record --scope project --project-dir "$PROJ" --id slack --state suggested --kind plugin \
  --ref slack@claude-plugins-official --source "$OFFSRC" --rule=prompt_ere --evidence=slack --via=prompt-preinstall --run=run-0 >/dev/null 2>&1
python3 -I "$TOOL" record --scope project --project-dir "$PROJ" --id seo --state declined --kind plugin \
  --ref seo@claude-plugins-official --source "$OFFSRC" --rule=prompt_ere --evidence=seo --via=prompt-preinstall --run=run-0 >/dev/null 2>&1
BODY=""
add "$(inst_plugin slack prompt-preinstall)"
add "$(inst_plugin seo prompt-preinstall)"
probe "$BODY" HMD_SKILLS_CONSENT_BASIS=prompt
eq "H: a suggested row becomes installed" '"installed"' "$(rowf "$PROJ_LOCK" slack state)"
eq "H: ... keeps the rule that triggered the suggestion" '"prompt_ere"' "$(rowf "$PROJ_LOCK" slack why.rule)"
eq "H: ... and the evidence" '"slack"' "$(rowf "$PROJ_LOCK" slack why.evidence)"
eq "H: ... and records how the install was agreed to" '"prompt"' "$(rowf "$PROJ_LOCK" slack consent)"
eq "H: ... in the run that installed it" '"run-t"' "$(rowf "$PROJ_LOCK" slack why.run)"
eq "H: a declined row becomes installed too (a person typed the command)" '"installed"' "$(rowf "$PROJ_LOCK" seo state)"

# ═ I. the suite can go RED ══════════════════════════════════════════════════════════════════════════════════════════
echo "  -- one-line breaks of the lib"
mutant() {  # mutant NAME PROPERTY SED-ARGS... : the property holds for the real lib, so it must FAIL for the lib the edit breaks
  local name="$1" prop="$2" dir="$TMP/mut-$1"; shift 2
  mkdir -p "$dir"
  cp "$TOOL" "$dir/skills_lock.py"
  sed "$@" "$LIB/install-receipt.sh" >"$dir/install-receipt.sh"
  if cmp -s "$LIB/install-receipt.sh" "$dir/install-receipt.sh"; then bad "I: mutant $name: the edit matched nothing"; return 0; fi
  LIBDIR="$dir"
  if "$prop"; then bad "I: mutant $name: $prop still holds, so the suite cannot see this break"; else ok "I: mutant $name is caught by $prop"; fi
  LIBDIR="$LIB"
}
mutant lock-status-leaks prop_contained \
  -e '/^_hmd_ir_lock()/,/^}/ s/^  return 0$/  return "${rc:-0}"/' \
  -e 's/^\(    _hmd_ir_lock .*\) || true$/\1 || return "$?"/'
mutant lock-failure-silent prop_contained -e '/could not record/ s/ >&2$/ >\/dev\/null/'
mutant install-sh-is-project prop_installsh_machine -e 's/first-run\*|install\.sh)/first-run*)/'
mutant consent-dropped prop_consent -e 's/"--consent=\$HMD_SKILLS_CONSENT_BASIS"/"--consent=n\/a"/'
mutant id-keeps-marketplace prop_plugin_row -e 's/_hmd_ir_lock plugin "${id%@\*}"/_hmd_ir_lock plugin "$id"/'
mutant evidence-as-separate-arg prop_hostile_why -e 's/"--evidence=\$HMD_INSTALL_WHY_EVIDENCE"/--evidence "$HMD_INSTALL_WHY_EVIDENCE"/'

echo "--------------------------------------------------------------------"
printf 'skills-lock-record: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
