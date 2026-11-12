#!/usr/bin/env bash
# test/heimdall-skills-dispatch.test.sh -- `hmd skills`, `hmd guardrails` and the receipted `hmd --skills install`
# (3.x M1 plan docs/superpowers/plans/2026-11-12-3x-m1-skill-registry.md, task T6.3 cli-wiring).
#
# THE DEFECT CLASS. Both CLIs existed as tools (bin/lib/skills_cli_read.py, bin/lib/skills_cli_install.py, bin/heimdall-guardrails) that
# nothing dispatched: `hmd skills list` and `hmd guardrails list` are two words, so bin/heimdall read them as a TASK PROMPT and started a
# Claude run with "skills list" as the task. And `hmd --skills install owner/repo` ran a bare `git clone`: a skill landed on the machine with
# no receipt line and no lock row, the one install path the M0 transparency work never reached.
#
# THE CONTRACT UNDER TEST
#   A  hmd skills: --help, bare and help print the usage (exit 0); an unknown command is exit 2 with the usage, the typed word shown printable;
#      each of the seven commands reaches the module that owns it (list, why, lock: the read side; suggest, install, consent, allow: the
#      install side) and that module's exit code comes back unchanged
#   B  hmd guardrails: list / why / off / on reach bin/heimdall-guardrails with their arguments verbatim and its exit codes (a core id is
#      refused with 2 and nothing is written); bare and help print the usage
#   C  neither CLI ever starts a Claude run: the launcher's launch trace stays empty and the only `claude` call is `plugins list --json`
#      (the fake environment lets an unrouted word reach the launch point, so the trace CAN fill: the proof is not vacuous)
#   D  the dispatch-name suggester offers both (`hmd skils` -> skills, `hmd guardrail` -> guardrails) and packages/runhmd/subcommands.txt
#      lists both (an unlisted word would reach `runhmd` as `hmd attack <word>`)
#   E  hmd --skills install, by repo and by registry name: ONE receipt line (kind skill, source, commit, via) and one lock row (installed,
#      consent explicit); a skill already on disk is not cloned twice; a failed clone is a non-zero exit, a `failed` receipt line, a
#      message on stderr and no "Installed" claim
#   G  a tool that is missing (the arm's target, or a module beside the dispatcher) is exit 1 and a not-found message, never the launch path
#   F  bin/heimdall and bin/heimdall-skills parse (bash -n)
#
# HERMETIC. HOME, HEIMDALL_HOME, the project and the receipts directory are throwaway; `claude` and `git` are PATH fakes that record their
# argv (git never touches the network: a clone makes the directory); nothing reads the operator's machine. The launcher under test is the
# real bin/heimdall of this checkout, run in place.
# budget: about 12 s solo: roughly forty launches of bin/heimdall, each a bash start plus at most one python module. No network.
# EXIT: 0 = every assertion passes; 1 = any FAIL.
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HMD="$REPO/bin/heimdall"

PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); printf '  \033[32mPASS\033[0m %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  \033[31mFAIL\033[0m %s\n' "$1"; if [ -n "${2:-}" ]; then printf '       %s\n' "$2"; fi; }
# t NAME [DETAIL]: the verdict of the command just before it. DETAIL is single-quoted at the call and expanded only on a failure: a
# command substitution in an argument would run BEFORE this function and replace the status it is about to read.
t() {
  local status=$?
  if [ "$status" -eq 0 ]; then ok "$1"; else eval "bad \"\$1\" \"${2:-}\""; fi
}

echo "heimdall-skills-dispatch"

command -v python3 >/dev/null 2>&1 || { echo "FATAL: python3 is required"; exit 1; }

# ── sandbox ──────────────────────────────────────────────────────────────────────────────────────────────────────
TMP="$(mktemp -d /tmp/test-heimdall-skills-dispatch-XXXXXX)" || exit 1
trap 'chmod -R u+rwx "$TMP" 2>/dev/null; rm -rf "$TMP"' EXIT
FAKEBIN="$TMP/bin"; HOME_DIR="$TMP/home"; HH="$TMP/hh"; PROJ="$TMP/proj"; RECEIPTS="$TMP/receipts"
mkdir -p "$FAKEBIN" "$HOME_DIR" "$HH" "$PROJ" "$RECEIPTS"
chmod 700 "$HH"                      # bin/heimdall-guardrails writes only under a home nobody else can write to
touch "$HH/setup-done"               # a word that fell through to the launcher (the defect) would then skip first-run setup
CLAUDE_LOG="$TMP/claude.log"; GIT_LOG="$TMP/git.log"; TRACE="$TMP/trace"
: >"$CLAUDE_LOG"; : >"$GIT_LOG"; : >"$TRACE"
RECEIPT="$RECEIPTS/installs-run-dispatch.ndjson"

cat >"$FAKEBIN/claude" <<'SH'
#!/bin/sh
# fake claude: records its argv; `plugins list --json` answers an empty list; anything else would be a Claude run
printf '%s\n' "$*" >>"$FAKE_CLAUDE_LOG"
case "$*" in
  "--version") echo "1.99.0 (Claude Code)" ;;
  "plugins list --json") echo "[]" ;;
esac
exit 0
SH
cat >"$FAKEBIN/git" <<'SH'
#!/usr/bin/env bash
# fake git: `clone ... URL DEST` records the URL and makes DEST (a URL matching FAKE_GIT_FAIL_RE fails); `-C DIR rev-parse ...` names a commit
case "${1:-}" in
  clone)
    dest="${@: -1}"; url="${@: -2:1}"
    printf 'clone %s\n' "$url" >>"$FAKE_GIT_LOG"
    if [ -n "${FAKE_GIT_FAIL_RE:-}" ] && printf '%s' "$url" | grep -Eq "$FAKE_GIT_FAIL_RE"; then
      echo "fatal: unable to access '$url': Could not resolve host" >&2
      exit 128
    fi
    mkdir -p "$dest/.git"
    exit 0 ;;
  -C) shift 2; if [ "${1:-}" = "rev-parse" ]; then echo "abc1234def56"; exit 0; fi ;;
esac
exit 0
SH
chmod +x "$FAKEBIN/claude" "$FAKEBIN/git"

# What the operator's environment could bend: none of it may reach the launcher or the tools behind it.
unset HMD_SKILLS_REGISTRY HMD_SKILLS_CONSENT HMD_SKILLS_YES HMD_SKILLS_ASSUME HMD_SKILLS_CONSENT_BASIS HMD_GUARDRAILS_MANIFEST \
      HMD_HOOKS_METADATA HMD_PYTHON HMD_INSTALL_WHY_RULE HMD_INSTALL_WHY_EVIDENCE CLAUDE_PLUGIN_ROOT WORK_DIR FAKE_GIT_FAIL_RE
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 GIT_TERMINAL_PROMPT=0

RC=0; OUT=""; ERR=""
hmd() {  # hmd ARGS... -> RC, OUT, ERR: the real launcher, from a throwaway project, with the fakes first on PATH.
  # ANTHROPIC_API_KEY passes the launcher's sign-in gate, so a word that is NOT routed reaches the launch point (and the trace).
  OUT="$(cd "$PROJ" && PATH="$FAKEBIN:$PATH" HOME="$HOME_DIR" HEIMDALL_HOME="$HH" HMD_RECEIPTS_DIR="$RECEIPTS" HMD_RUN_ID=run-dispatch \
         ANTHROPIC_API_KEY=sk-test-not-a-key FAKE_CLAUDE_LOG="$CLAUDE_LOG" FAKE_GIT_LOG="$GIT_LOG" HEIMDALL_TRACE_ORDER="$TRACE" \
         HEIMDALL_NO_INTRO=1 HEIMDALL_NO_UPDATE_CHECK=1 bash "${LAUNCHER:-$HMD}" "$@" 2>"$TMP/stderr" </dev/null)"; RC=$?
  ERR="$(cat "$TMP/stderr")"
}
has()    { printf '%s\n' "$OUT" | grep -qF -- "$1"; }
errhas() { printf '%s\n' "$ERR" | grep -qF -- "$1"; }
claude_launched() {  # a launch trace line, or a `claude` call that is not the plugin query
  [ -s "$TRACE" ] && return 0
  grep -qvx 'plugins list --json' "$CLAUDE_LOG" 2>/dev/null
}
rf() {  # rf N FIELD: the field FIELD of line N (1-based) of the run's receipt, '' when there is none
  python3 -I -c 'import json, sys
try:
    lines = [ln for ln in open(sys.argv[1]).read().splitlines() if ln.strip()]
    print(json.loads(lines[int(sys.argv[2]) - 1])[sys.argv[3]])
except Exception:
    pass' "$RECEIPT" "$1" "$2"
}
valid_json() { printf '%s' "$OUT" | python3 -I -c 'import json, sys; json.load(sys.stdin)' 2>/dev/null; }
# one-line views for the failure details
out3()           { printf '%s' "$OUT" | head -3 | tr '\n' ' '; }
out160()         { printf '%s' "$OUT" | head -c 160 | tr '\n' ' '; }
calls()          { tr '\n' ';' <"$CLAUDE_LOG"; }
trace()          { tr '\n' ';' <"$TRACE"; }
receipt_lines()  { grep -c . "$RECEIPT" 2>/dev/null; }
clones()         { grep -c '^clone ' "$GIT_LOG" 2>/dev/null; }
lockdump()       { head -c 400 "$PROJ/.planning/skills.lock" 2>/dev/null | tr '\n' ' '; }

# ── A. hmd skills ────────────────────────────────────────────────────────────────────────────────────────────────
hmd skills --help; USAGE="$OUT"
[ "$RC" -eq 0 ] && [ -n "$USAGE" ]; t "A1 hmd skills --help prints the usage and exits 0" 'rc=$RC out=$(out3) err=$ERR'
GAPS=""
for verb in list why lock suggest install consent allow; do
  printf '%s\n' "$USAGE" | grep -Eq "^  $verb( |\$)" || GAPS="$GAPS $verb"
done
[ -z "$GAPS" ]; t "A2 the usage lists all seven commands" 'missing:$GAPS'
hmd skills; BARE="$OUT"; BARE_RC=$RC
hmd skills help
[ "$BARE_RC" -eq 0 ] && [ "$RC" -eq 0 ] && [ -n "$USAGE" ] && [ "$BARE" = "$USAGE" ] && [ "$OUT" = "$USAGE" ]
t "A3 bare 'hmd skills' and 'hmd skills help' print the same usage and exit 0" 'bare rc=$BARE_RC help rc=$RC'
hmd skills bogus
[ "$RC" -eq 2 ] && [ -z "$OUT" ] && errhas "unknown command: bogus" && errhas "Usage: hmd skills"
t "A4 hmd skills bogus: exit 2, usage and the word on stderr, nothing on stdout" 'rc=$RC out=$(out3) err=$ERR'
ESC="$(printf '\033')"
hmd skills "x${ESC}[2Jy"
if [ "$RC" -eq 2 ] && ! printf '%s' "$ERR" | LC_ALL=C grep -q "$ESC"; then
  ok "A5 a typed command word is printed printable: an escape sequence cannot reach the terminal"
else
  bad "A5 an escape sequence in the typed word reached stderr (or the exit was not 2)" "rc=$RC"
fi

hmd skills list
if [ "$RC" -eq 0 ] && printf '%s\n' "$OUT" | head -1 | grep -q '^registry:' && printf '%s\n' "$OUT" | grep -Eq '^superpowers +plugin +recommended +no '; then
  ok "A6 hmd skills list reaches the read side (real manifest, the registry/consent line, installed read from the fake claude)"
else
  bad "A6 hmd skills list" "rc=$RC out=$(out3) err=$ERR"
fi
hmd skills list --json
[ "$RC" -eq 0 ] && valid_json; t "A7 hmd skills list --json forwards the flag: valid JSON" 'rc=$RC out=$(out160)'
hmd skills why superpowers
[ "$RC" -eq 0 ] && has superpowers; t "A8 hmd skills why <manifest id> reaches the read side (exit 0)" 'rc=$RC err=$ERR'
hmd skills why nonesuch
[ "$RC" -eq 4 ]; t "A9 hmd skills why <unknown id>: the read side's exit 4 comes back unchanged" 'rc=$RC err=$ERR'
hmd skills lock --verify
[ "$RC" -eq 0 ] && [ ! -e "$HH/skills.lock" ]; t "A10 hmd skills lock --verify reaches the read side: nothing installed, nothing written" 'rc=$RC err=$ERR'

hmd skills suggest
[ "$RC" -eq 0 ]; t "A11 hmd skills suggest reaches the install side (exit 0, prints, installs nothing)" 'rc=$RC err=$ERR'
hmd skills install
[ "$RC" -eq 2 ] && errhas "install takes one skill id"; t "A12 hmd skills install with no id: the install side's usage error, exit 2" 'rc=$RC err=$ERR'
hmd skills consent allowlist
[ "$RC" -eq 0 ] && has "consent: allowlist" && [ -f "$HH/skills-config.json" ]
t "A13 hmd skills consent allowlist writes the operator's skills-config.json" 'rc=$RC out=$OUT err=$ERR'
hmd skills consent
[ "$RC" -eq 0 ] && has "consent: allowlist"; t "A14 hmd skills consent reads it back" 'rc=$RC out=$OUT'
hmd skills allow superpowers
[ "$RC" -eq 0 ] && has "allowed: superpowers"; t "A15 hmd skills allow <id> adds it to the allowlist" 'rc=$RC out=$OUT err=$ERR'
hmd skills allow nonesuch
[ "$RC" -eq 2 ]; t "A16 hmd skills allow <unknown id>: exit 2" 'rc=$RC err=$ERR'
! claude_launched; t "C1 no hmd skills command started a Claude run (launch trace empty, the only claude call is 'plugins list --json')" 'trace=$(trace) claude=$(calls)'

# ── B. hmd guardrails ────────────────────────────────────────────────────────────────────────────────────────────
: >"$CLAUDE_LOG"
hmd guardrails list
[ "$RC" -eq 0 ] && has "ci-waste-guard" && has "always on"; t "B1 hmd guardrails list reaches bin/heimdall-guardrails (recommended and core rows)" 'rc=$RC out=$(out3) err=$ERR'
hmd guardrails list --json
[ "$RC" -eq 0 ] && valid_json; t "B2 hmd guardrails list --json forwards the flag: valid JSON" 'rc=$RC out=$(out160)'
hmd guardrails; GBARE="$OUT"; GBARE_RC=$RC
hmd guardrails help
[ "$GBARE_RC" -eq 0 ] && [ "$RC" -eq 0 ] && [ "$GBARE" = "$OUT" ] && has "list"
t "B3 bare 'hmd guardrails' and 'hmd guardrails help' print the same usage and exit 0" 'bare rc=$GBARE_RC help rc=$RC out=$(out3)'
hmd guardrails why git-guard
[ "$RC" -eq 0 ] && has "core"; t "B4 hmd guardrails why <id> forwards the id" 'rc=$RC out=$(out3) err=$ERR'
hmd guardrails off git-guard
[ "$RC" -eq 2 ] && [ ! -e "$HH/guardrails-off" ]; t "B5 hmd guardrails off <core id>: exit 2 comes back unchanged and nothing is written" 'rc=$RC err=$ERR'
hmd guardrails off nonesuch
[ "$RC" -eq 1 ]; t "B6 hmd guardrails off <unknown id>: exit 1" 'rc=$RC err=$ERR'
hmd guardrails off ci-waste-guard
[ "$RC" -eq 0 ] && grep -qxF ci-waste-guard "$HH/guardrails-off" 2>/dev/null; t "B7 hmd guardrails off <recommended id> writes the operator's guardrails-off" 'rc=$RC err=$ERR'
hmd guardrails on ci-waste-guard
[ "$RC" -eq 0 ] && ! grep -qxF ci-waste-guard "$HH/guardrails-off" 2>/dev/null; t "B8 hmd guardrails on <id> takes it out again" 'rc=$RC err=$ERR'
hmd guardrails bogus
[ "$RC" -eq 2 ]; t "B9 hmd guardrails bogus: the tool's usage error, exit 2" 'rc=$RC err=$ERR'
[ ! -s "$CLAUDE_LOG" ] && [ ! -s "$TRACE" ]; t "C2 no hmd guardrails command touched claude or started a Claude run" 'trace=$(trace) claude=$(calls)'

# ── D. the dispatch-name suggester and the runhmd list ───────────────────────────────────────────────────────────
hmd skils
[ "$RC" -eq 2 ] && errhas "did you mean 'skills'?"; t "D1 'hmd skils' is rejected with: did you mean 'skills'?" 'rc=$RC err=$ERR'
hmd guardrail
[ "$RC" -eq 2 ] && errhas "did you mean 'guardrails'?"; t "D2 'hmd guardrail' is rejected with: did you mean 'guardrails'?" 'rc=$RC err=$ERR'
grep -qx skills "$REPO/packages/runhmd/subcommands.txt" && grep -qx guardrails "$REPO/packages/runhmd/subcommands.txt"
t "D3 packages/runhmd/subcommands.txt lists skills and guardrails"
[ ! -s "$TRACE" ]; t "D4 a mistyped command word never reaches the launcher" 'trace=$(trace)'

# ── E. hmd --skills install is receipted ─────────────────────────────────────────────────────────────────────────
hmd --skills install owner/repo
[ "$RC" -eq 0 ] && has "Installed to" && [ -d "$HOME_DIR/.claude/skills/repo/.git" ]; t "E1 hmd --skills install owner/repo clones the skill and says so" 'rc=$RC out=$OUT err=$ERR'
GOT="$(rf 1 kind)|$(rf 1 name)|$(rf 1 source)|$(rf 1 result)|$(rf 1 version)"
[ "$GOT" = "skill|repo|github.com/owner/repo|ok|abc1234def56" ] && [ -n "$(rf 1 via)" ]
t "E2 it wrote a receipt line: kind, name, source, result and the cloned commit, and who installed it" 'got: $GOT via=$(rf 1 via)'
[ "$(receipt_lines)" = 1 ]; t "E3 the receipt holds exactly that one line" 'lines=$(receipt_lines)'
python3 -I -c '
import sys
sys.path.insert(0, sys.argv[1])
import skills_lock
rows = skills_lock.load(sys.argv[2])["entries"]
row = next((r for r in rows if r["id"] == "repo"), None)
ok = row is not None and row["state"] == "installed" and row["consent"] == "explicit" and row["why"]["rule"] == "explicit" and row["why"]["via"] == sys.argv[3]
sys.exit(0 if ok else 1)' "$REPO/bin/lib" "$PROJ/.planning/skills.lock" "$(rf 1 via)" 2>/dev/null
t "E4 it recorded the lock row: installed, consent explicit, why.rule explicit, the receipt's own via" 'lock: $(lockdump)'
hmd --skills install owner/repo
[ "$RC" -eq 0 ] && has "already installed" && [ "$(clones)" = 1 ] && [ "$(receipt_lines)" = 1 ]
t "E5 a skill already on disk is not cloned again and adds no receipt line" 'rc=$RC out=$OUT clones=$(clones) receipt lines=$(receipt_lines)'

REG="$(python3 -I -c 'import json, sys; s = json.load(open(sys.argv[1]))["skills"][0]; print(s["name"] + " " + s["repo"])' "$REPO/skills-registry.json")"
REG_NAME="${REG%% *}"; REG_REPO="${REG#* }"
hmd --skills install "$REG_NAME"
[ "$RC" -eq 0 ] && grep -qxF "clone https://github.com/$REG_REPO.git" "$GIT_LOG" && [ "$(rf 2 name)|$(rf 2 result)|$(rf 2 source)" = "$REG_NAME|ok|github.com/$REG_REPO" ]
t "E6 by registry name: the registry's repo is cloned and receipted under that name" 'rc=$RC err=$ERR line 2: $(rf 2 name)|$(rf 2 result)|$(rf 2 source)'

export FAKE_GIT_FAIL_RE='acme/broken'
hmd --skills install acme/broken
unset FAKE_GIT_FAIL_RE
[ "$RC" -ne 0 ] && ! has "Installed to" && [ ! -d "$HOME_DIR/.claude/skills/broken" ]; t "E7 a failed clone is a non-zero exit, no 'Installed' claim and no directory" 'rc=$RC out=$OUT'
errhas "install failed, continuing without broken"; t "E8 the failure is said on stderr, not swallowed" 'err=$ERR'
[ "$(rf 3 name)|$(rf 3 result)" = "broken|failed" ]; t "E9 the failure is receipted as a failed line" 'line 3: $(rf 3 name)|$(rf 3 result)'

# ── G. a missing tool is a plain error, never the launch path ────────────────────────────────────────────────────
PLUG="$TMP/plugin"; mkdir -p "$PLUG/bin"
cp "$HMD" "$PLUG/bin/heimdall"       # a launcher whose PLUGIN_DIR holds no tool at all
: >"$TRACE"
LAUNCHER="$PLUG/bin/heimdall" hmd skills list
[ "$RC" -eq 1 ] && errhas "heimdall-skills not found" && [ ! -s "$TRACE" ]
t "G1 hmd skills with bin/heimdall-skills missing: exit 1 and a not-found error, no launch" 'rc=$RC err=$ERR trace=$(trace)'
LAUNCHER="$PLUG/bin/heimdall" hmd guardrails list
[ "$RC" -eq 1 ] && errhas "heimdall-guardrails not found" && [ ! -s "$TRACE" ]
t "G2 hmd guardrails with bin/heimdall-guardrails missing: exit 1 and a not-found error, no launch" 'rc=$RC err=$ERR trace=$(trace)'
cp "$REPO/bin/heimdall-skills" "$PLUG/bin/heimdall-skills"       # the dispatcher with no lib/ beside it
ERR="$(bash "$PLUG/bin/heimdall-skills" list 2>&1 >/dev/null </dev/null)"; RC=$?
[ "$RC" -eq 1 ] && errhas "skills_cli_read.py not found"; t "G3 bin/heimdall-skills without its read module: exit 1 and a not-found error" 'rc=$RC err=$ERR'
ERR="$(bash "$PLUG/bin/heimdall-skills" install owner/repo 2>&1 >/dev/null </dev/null)"; RC=$?
[ "$RC" -eq 1 ] && errhas "skills_cli_install.py not found"; t "G4 bin/heimdall-skills without its install module: exit 1 and a not-found error" 'rc=$RC err=$ERR'

# ── F. syntax ────────────────────────────────────────────────────────────────────────────────────────────────────
bash -n "$HMD" 2>/dev/null; t "F1 bin/heimdall passes bash -n"
bash -n "$REPO/bin/heimdall-skills" 2>/dev/null; t "F2 bin/heimdall-skills passes bash -n"

echo
echo "heimdall-skills-dispatch: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
