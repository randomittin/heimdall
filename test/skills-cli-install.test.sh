#!/usr/bin/env bash
# test/skills-cli-install.test.sh -- bin/lib/skills_cli_install.py: `hmd skills suggest | install | consent | allow`
# (3.x M1 plan, task T4.2: docs/superpowers/plans/2026-11-12-3x-m1-skill-registry.md, "CLI surface" and "Consent model").
#
# `install` is the single consented install path: it asks the consent gate (bin/lib/skills_consent.sh) and only then runs
# the receipted install functions (bin/lib/install-receipt.sh), which refuse a marketplace that is not on the allow-list.
# `suggest` only prints. `consent` and `allow` read and write $HEIMDALL_HOME/skills-config.json.
#
# THE CONTRACT UNDER TEST
#   A  usage: no command, no id, an id AND --recommended, an unknown command are exit 2
#   B  suggest never installs (no `claude`/`git` call, no lock written); it lists the recommended entries that are not
#      installed plus the detected ones whose files are in THIS project; installed, declined, install:false, bundled,
#      on-demand and community entries are not listed; --reset asks again about the declined ones
#   C  install: no tty and no --yes is exit 3 with no call and a `suggested` row; --yes is ONE install from the allow-listed
#      marketplace, a receipt line and a lock row `consent: yes-flag`; an install that fails is exit 1 and a `failed` row;
#      an entry hmd does not install (an unlisted marketplace, bundled, unknown) is exit 2 with no call; consent auto and
#      allowlist install without --yes; the prompt (Install now / Not now / Never ask again) decides on a terminal;
#      a github skill is cloned through the receipted helper; --recommended; a community entry is asked EVERY time
#   D  consent and allow: read, write, persist, refuse what is not allowed
#   E  a REAL pty (`script -q`, no seam): on a terminal the menu opens and the answer decides
#   H  the suite can go RED: one-line breaks of the module, each caught by the check that guards it
#
# HERMETIC. HOME, HEIMDALL_HOME and the project are throwaway directories, `claude` and `git` are PATH fakes that log their
# calls, no network, nothing outside $TMP is touched. The terminal cases use the library's documented seam
# (HMD_SKILLS_ASSUME=tty plus keys on stdin: k = up, j = down, Enter confirms; the menu opens on Not now); the real pty
# detection is proven by test/skills-consent-gate.test.sh. EXIT: 0 = every assertion passes; 1 = any FAIL.
# shellcheck disable=SC2016  # single quotes hold literal python and shell snippets for the child process on purpose
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLI="$REPO/bin/lib/skills_cli_install.py"
LOCKPY="$REPO/bin/lib/skills_lock.py"
CFGPY="$REPO/bin/lib/skills_config.py"

PASS=0
FAIL=0
ok()   { PASS=$((PASS + 1)); printf '  \033[32mPASS\033[0m %s\n' "$1"; }
bad()  { FAIL=$((FAIL + 1)); printf '  \033[31mFAIL\033[0m %s\n' "$1"; if [ -n "${2:-}" ]; then printf '       %s\n' "$2"; fi; }
eq()   { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected [$2], got [$3]"; fi; }
has()  { if grep -qF -- "$3" <<<"$2"; then ok "$1"; else bad "$1" "[$3] is not in [$2]"; fi; }
lacks() { if grep -qF -- "$3" <<<"$2"; then bad "$1" "[$3] is in [$2]"; else ok "$1"; fi; }
finish() { echo; echo "skills-cli-install: $PASS passed, $FAIL failed"; [ "$FAIL" -eq 0 ] && [ "$PASS" -gt 0 ]; }

echo "skills-cli-install"

command -v python3 >/dev/null 2>&1 || { echo "FATAL: python3 is required"; exit 1; }
if [ ! -f "$CLI" ]; then
  bad "0. bin/lib/skills_cli_install.py is missing"
  finish
  exit 1
fi

# ── sandbox ──────────────────────────────────────────────────────────────────────────────────────────────────────
TMP="$(mktemp -d /tmp/test-skills-cli-install-XXXXXX)" || exit 1
trap 'chmod -R u+rwx "$TMP" 2>/dev/null; rm -rf "$TMP"' EXIT
# The REAL interpreter first on PATH: a version-manager shim costs ~0.4 s a call and the gate starts python several times.
REALPY="$(python3 -I -c 'import sys; print(sys.executable)' 2>/dev/null)"
[ -x "${REALPY:-}" ] || { echo "FATAL: no usable python3"; exit 1; }
mkdir -p "$TMP/pybin" "$TMP/fakebin"
ln -s "$REALPY" "$TMP/pybin/python3"
PATH="$TMP/pybin:$PATH"; export PATH
CALLS="$TMP/calls.log"; : > "$CALLS"
GPATH="$TMP/pybin:$TMP/fakebin:/usr/bin:/bin:/usr/sbin:/sbin"

# The fake `claude`: logs every call, keeps its state in $FAKE_STATE (installed plugins, registered marketplaces).
# FAKE_FAIL_RE makes `plugins install <ref>` fail for a ref that matches.
cat > "$TMP/fakebin/claude" <<'EOF'
#!/bin/sh
echo "claude $*" >> "$FAKE_CALLS"
case "$1 $2 $3" in
  "plugins install "*)
    if [ -n "${FAKE_FAIL_RE:-}" ] && printf '%s' "$3" | grep -Eq "$FAKE_FAIL_RE"; then
      echo "boom: the marketplace is unreachable" >&2
      exit 1
    fi
    echo "$3" >> "$FAKE_STATE/installed"
    echo "installed $3"
    exit 0 ;;
  "plugins list --json")
    echo '['
    if [ -f "$FAKE_STATE/installed" ]; then
      while IFS= read -r id; do
        printf '  {\n    "id": "%s",\n    "version": "5.0.7"\n  },\n' "$id"
      done < "$FAKE_STATE/installed"
    fi
    echo ']'
    exit 0 ;;
  "plugins marketplace list") cat "$FAKE_STATE/markets" 2>/dev/null; exit 0 ;;
  "plugins marketplace add") echo "$4" >> "$FAKE_STATE/markets"; exit 0 ;;
esac
exit 0
EOF
# The fake `git`: `clone --depth 1 URL DEST` makes DEST, `-C DEST rev-parse ...` answers a commit id.
cat > "$TMP/fakebin/git" <<'EOF'
#!/bin/sh
echo "git $*" >> "$FAKE_CALLS"
case "$1" in
  clone) mkdir -p "$5"; exit 0 ;;
  -C) if [ "$3" = rev-parse ]; then echo 0123456789ab; fi; exit 0 ;;
esac
exit 0
EOF
chmod +x "$TMP/fakebin/claude" "$TMP/fakebin/git"

# A sandbox copy of the libraries beside a manifest with one community entry that needs an explicit yes every time
# (INV-S9, manifest rule SM6): the CLI, the consent gate and the lock all find the manifest two levels above their own file.
SBX="$TMP/sbx"; mkdir -p "$SBX/bin/lib"
for f in skills_cli_install.py hmd_profile.py skills_config.py skills_lock.py skills_manifest.py skills_resolver.py skills_consent.sh select.sh install-receipt.sh; do
  cp "$REPO/bin/lib/$f" "$SBX/bin/lib/$f"
done
# The copy must stand on its own: a library the module imports that this list lacks would fail every sandbox case with a traceback and make every H break look caught.
python3 -I -B -c 'import sys; sys.path.insert(0, sys.argv[1]); import skills_cli_install' "$SBX/bin/lib" 2> "$TMP/sbx-import.err" \
  || { echo "FATAL: the sandbox copy of the module cannot be imported (a library it needs is not in the copy list): $(tail -n 1 "$TMP/sbx-import.err")"; exit 1; }
python3 -I -c 'import copy, json, sys
doc = json.load(open(sys.argv[1]))
extra = copy.deepcopy(next(e for e in doc["entries"] if e["id"] == "slack"))
extra.update(id="zz-community", ref="zz-community@claude-plugins-official", tier="community", explicit_consent=True,
             why="fixture: a community plugin that needs an explicit yes every time",
             legacy=[{"mechanism": "heimdall-skills.json", "path": "on_demand"}])
for key in ("activate", "triggers"):
    extra.pop(key, None)
doc["entries"].append(extra)
json.dump(doc, open(sys.argv[2], "w"), indent=2)' "$REPO/skills.manifest.json" "$SBX/skills.manifest.json" \
  || { echo "FATAL: cannot build the sandbox manifest"; exit 1; }

# ── helpers ──────────────────────────────────────────────────────────────────────────────────────────────────────
XENV=""      # extra NAME=value words (no spaces inside a value) for the next calls; "" = none
CLIPATH=""   # the module to run; "" = the repository's
HH=""; PROJ=""; HOME_DIR=""; FS=""; N=0
RC=""; OUT=""; ERR=""
newcase() {   # a fresh HEIMDALL_HOME, HOME, project and fake state; an empty call log and no keys on stdin
  N=$((N + 1)); HH="$TMP/hh.$N"; PROJ="$TMP/proj.$N"; HOME_DIR="$TMP/home.$N"; FS="$TMP/fs.$N"
  mkdir -p "$PROJ" "$HOME_DIR" "$FS"; XENV=""; CLIPATH=""; : > "$CALLS"; : > "$TMP/stdin"
}
keys() { printf '%b' "$1" > "$TMP/stdin"; }

# cli ARGS... -> RC OUT ERR. A clean environment, the project as working directory, stdin a FILE (never a terminal).
cli() {
  # shellcheck disable=SC2086  # XENV is a list of NAME=value words on purpose
  ( cd "$PROJ" && exec env -i HOME="$HOME_DIR" HEIMDALL_HOME="$HH" PATH="$GPATH" TERM=dumb HMD_RUN_ID=run-test \
      FAKE_CALLS="$CALLS" FAKE_STATE="$FS" $XENV "$TMP/pybin/python3" -I "${CLIPATH:-$CLI}" "$@" \
      < "$TMP/stdin" > "$TMP/out" 2> "$TMP/err" )
  RC=$?; OUT="$(cat "$TMP/out")"; ERR="$(cat "$TMP/err")"
}

prow()  { python3 -I "$LOCKPY" read --scope project --project-dir "$PROJ" --id "$1" 2>/dev/null; }
pall()  { python3 -I "$LOCKPY" read --scope project --project-dir "$PROJ" 2>/dev/null; }
cfg()   { HEIMDALL_HOME="$HH" python3 -I "$CFGPY" get "$1" 2>/dev/null; }
# jf ROW EXPR: EXPR (always a literal written in THIS file) evaluated with r = the lock row; `no-row` when there is none
jf() {
  if [ -z "$1" ]; then echo no-row; return 0; fi
  python3 -I -c 'import json, sys
r = json.loads(sys.argv[1])
print(eval(sys.argv[2]))' "$1" "$2"
}
# rowinfo ID -> state|consent|why.via|kind|source|ref|version|pin|why.rule of the row in the project lock
rowinfo() {
  jf "$(prow "$1")" 'r["state"] + "|" + r["consent"] + "|" + r["why"]["via"] + "|" + r["kind"] + "|" + r["source"] + "|" + r["ref"] + "|" + r["version"] + "|" + r["pin"] + "|" + r["why"]["rule"]'
}
state_of() { jf "$(prow "$1")" 'r["state"]'; }
count_rows() { grep -c "\"state\": \"$1\"" <<<"$(pall)" || true; }
# rcpt EXPR: EXPR evaluated over rs, the records of this case's install receipt
rcpt() {
  python3 -I -c 'import json, sys
rs = [json.loads(line) for line in open(sys.argv[1]) if line.strip()]
print(eval(sys.argv[2]))' "$HH/receipts/installs-run-test.ndjson" "$1" 2>&1 | tail -n 1
}
plugin_installs() { sed -n 's/^claude plugins install \([^ ]*\).*/\1/p' "$CALLS" | LC_ALL=C sort | tr '\n' ' '; }
n_installs() { grep -c '^claude plugins install ' "$CALLS" || true; }
listed() { if grep -q "^  $1 " <<<"$OUT"; then echo yes; else echo no; fi; }   # does the last OUT have an entry line for ID
enable() {    # enable REF...: this case's ~/.claude/settings.json knows those plugins (false = paused, still installed)
  mkdir -p "$HOME_DIR/.claude"
  python3 -I -c 'import json, sys; json.dump({"enabledPlugins": {ref: False for ref in sys.argv[2:]}}, open(sys.argv[1], "w"))' \
    "$HOME_DIR/.claude/settings.json" "$@"
}
RECOMMENDED="api-design database-toolkit devops-toolkit frontend-design mcp-server-dev security-scanner seo slack superpowers"
MKT=anthropics/claude-plugins-official

# ╔═ A. usage ══════════════════════════════════════════════════════════════════════════════════════════════════════╗
echo "A. usage"
newcase
cli
eq "A: no command is exit 2" "2" "$RC"
has "A: ... with the usage on stderr" "$ERR" "usage"
cli bogus
eq "A: an unknown command is exit 2" "2" "$RC"
cli install
eq "A: install without an id or --recommended is exit 2" "2" "$RC"
cli install frontend-design --recommended
eq "A: an id AND --recommended is exit 2" "2" "$RC"
cli allow
eq "A: allow without an id is exit 2" "2" "$RC"
eq "A: none of it touched claude or git" "0" "$(wc -c < "$CALLS" | tr -d ' ')"

# ╔═ B. suggest ════════════════════════════════════════════════════════════════════════════════════════════════════╗
echo "B. suggest"
newcase
mkdir -p "$PROJ/.github/workflows"
: > "$PROJ/Dockerfile"; : > "$PROJ/playwright.config.ts"; : > "$PROJ/CLAUDE.md"; : > "$PROJ/app.py"; : > "$PROJ/App.tsx"
: > "$PROJ/.github/workflows/ci.yml"
cli suggest
eq "B: exit 0" "0" "$RC"
for id in $RECOMMENDED; do eq "B: $id (recommended, not installed) is listed" "yes" "$(listed "$id")"; done
for id in playwright pr-review-toolkit claude-md-management code-review security-guidance; do
  eq "B: $id (detected: its files are in this project) is listed" "yes" "$(listed "$id")"
done
for id in design-for-ai caveman heimdall skill-creator ui-ux-pro-max; do
  eq "B: $id (install:false, bundled, on-demand or keyword-only) is not listed" "no" "$(listed "$id")"
done
has "B: the line says why" "$OUT" "UI and frontend work gets design guidance"
has "B: ... and what fired for a detected entry" "$OUT" "detected: playwright"
eq "B: suggest made no claude or git call" "0" "$(wc -c < "$CALLS" | tr -d ' ')"
eq "B: ... and wrote no lock" "absent" "$([ -e "$PROJ/.planning/skills.lock" ] && echo present || echo absent)"

newcase
cli suggest
eq "B: a project with none of the files: detected entries are not listed" "no|no|no" "$(listed playwright)|$(listed code-review)|$(listed claude-md-management)"
eq "B: ... the recommended ones still are" "yes|yes" "$(listed superpowers)|$(listed devops-toolkit)"

newcase
enable superpowers@claude-plugins-official
python3 -I "$LOCKPY" record --scope project --project-dir "$PROJ" --id frontend-design --state installed --kind plugin \
  --ref frontend-design@claude-plugins-official --via test >/dev/null 2>&1
python3 -I "$LOCKPY" record --scope project --project-dir "$PROJ" --id seo --state declined --kind plugin \
  --ref seo@claude-plugins-official --via prompt-preinstall >/dev/null 2>&1
cli suggest
eq "B: a plugin the settings know (even paused) is not listed" "no" "$(listed superpowers)"
eq "B: a lock row installed is not listed" "no" "$(listed frontend-design)"
eq "B: a declined entry is not listed" "no" "$(listed seo)"
has "B: ... and the output counts the declined ones and names the way back" "$OUT" "1 declined (hmd skills suggest --reset"
eq "B: the others are" "yes|yes" "$(listed devops-toolkit)|$(listed slack)"
cli suggest --reset
eq "B: --reset exit 0" "0" "$RC"
has "B: ... says what it reset" "$OUT" "reset 1 declined"
eq "B: ... the entry is listed again" "yes" "$(listed seo)"
eq "B: ... its row moved to suggested" "suggested" "$(state_of seo)"
cli suggest
eq "B: ... and it stays listed" "yes" "$(listed seo)"

newcase
HEIMDALL_HOME="$HH" python3 -I "$LOCKPY" record --scope machine --id superpowers --state declined --kind plugin \
  --ref superpowers@claude-plugins-official --via first-run >/dev/null 2>&1
cli suggest
eq "B: a row declined in the machine lock (a first-run decline) is held back too" "no|yes" "$(listed superpowers)|$(grep -q '1 declined' <<<"$OUT" && echo yes || echo no)"
cli suggest --reset
eq "B: --reset reaches the machine lock" "yes|suggested" "$(listed superpowers)|$(jf "$(HEIMDALL_HOME="$HH" python3 -I "$LOCKPY" read --scope machine --id superpowers 2>/dev/null)" 'r["state"]')"

newcase
CLIPATH="$SBX/bin/lib/skills_cli_install.py"
cli suggest
eq "B/INV-S9: a community entry is never suggested" "no" "$(listed zz-community)"
eq "B/INV-S9: ... though it is not installed and the manifest lists it" "yes" "$(listed devops-toolkit)"

# ╔═ C. install ════════════════════════════════════════════════════════════════════════════════════════════════════╗
echo "C. install"
newcase
cli install frontend-design
eq "C: no tty and no --yes: exit 3, consent required" "3" "$RC"
has "C: ... says so, for this skill" "$ERR" "consent required to install frontend-design"
has "C: ... and what to do (so an agent can relay the question)" "$ERR" "--yes"
eq "C: ... nothing was run" "0" "$(wc -c < "$CALLS" | tr -d ' ')"
eq "C: ... the row is suggested, asked by name (rule explicit), via hmd-skills-install" "suggested|n/a|hmd-skills-install|plugin|$MKT|frontend-design@claude-plugins-official|unknown|none|explicit" "$(rowinfo frontend-design)"
eq "C: ... and no receipt was written" "absent" "$([ -e "$HH/receipts" ] && echo present || echo absent)"
cli install frontend-design --yes
eq "C: --yes: exit 0" "0" "$RC"
has "C: ... says what it installed" "$OUT" "installed frontend-design"
eq "C: ... exactly one plugin install, from the allow-listed marketplace" "frontend-design@claude-plugins-official " "$(plugin_installs)"
eq "C: ... and the only marketplace registered is the listed one" "claude plugins marketplace add $MKT" "$(grep '^claude plugins marketplace add ' "$CALLS")"
eq "C: ... no git call" "0" "$(grep -c '^git ' "$CALLS" || true)"
eq "C: ... the lock row: installed, consent yes-flag, the version the CLI resolved, the suggestion's rule kept" "installed|yes-flag|hmd-skills-install|plugin|$MKT|frontend-design@claude-plugins-official|5.0.7|none|explicit" "$(rowinfo frontend-design)"
eq "C: ... the receipt has the plugin line (ok, via hmd-skills-install, the same version)" "[('plugin', 'frontend-design@claude-plugins-official', 'ok', 'hmd-skills-install', '5.0.7')]" "$(rcpt '[(r["kind"], r["name"], r["result"], r["via"], r["version"]) for r in rs if r["kind"] == "plugin"]')"
cli install frontend-design --yes
eq "C: installing it again: exit 0, already installed" "0|yes" "$RC|$(grep -q 'already installed' <<<"$OUT" && echo yes || echo no)"
eq "C: ... and no second install" "1" "$(n_installs)"

newcase
cli install seo --yes
eq "C: --yes with no row yet: a row with rule explicit and consent yes-flag" "installed|yes-flag|hmd-skills-install|plugin|$MKT|seo@claude-plugins-official|5.0.7|none|explicit" "$(rowinfo seo)"

newcase
cli install design-for-ai --yes
eq "C: an entry with install:false (marketplace rtd is not listed): exit 2" "2" "$RC"
has "C: ... says hmd does not install it" "$ERR" "does not install design-for-ai"
eq "C: ... and claude was never invoked" "0" "$(wc -c < "$CALLS" | tr -d ' ')"
eq "C: ... no row" "no-row" "$(rowinfo design-for-ai)"
cli install caveman --yes
eq "C: caveman (install:false) is refused too" "2" "$RC"
cli install heimdall --yes
eq "C: a bundled entry: exit 2, it ships with hmd" "2|yes" "$RC|$(grep -q 'ships with hmd' <<<"$ERR" && echo yes || echo no)"
cli install no-such-skill --yes
eq "C: an unknown id: exit 2" "2" "$RC"
has "C: ... says so" "$ERR" "unknown skill id no-such-skill"
cli install '../etc/passwd' --yes
eq "C: a path-shaped id is refused as unknown: exit 2" "2" "$RC"
eq "C: none of those reached claude or git" "0" "$(wc -c < "$CALLS" | tr -d ' ')"

newcase
cli consent auto
cli install seo
eq "C: consent auto: install without --yes works, basis explicit (the operator chose auto)" "0|installed|explicit" "$RC|$(state_of seo)|$(jf "$(prow seo)" 'r["consent"]')"

newcase
cli consent allowlist
cli allow frontend-design
cli install frontend-design
eq "C: allowlist, id on the list: installs without --yes, consent allowlist" "0|installed|allowlist" "$RC|$(state_of frontend-design)|$(jf "$(prow frontend-design)" 'r["consent"]')"
cli install seo
eq "C: allowlist, id not on the list: exit 3 and a suggested row" "3|suggested" "$RC|$(state_of seo)"
eq "C: ... only the listed one was installed" "frontend-design@claude-plugins-official " "$(plugin_installs)"

newcase; XENV="HMD_SKILLS_ASSUME=tty"; keys 'k\n'
cli install frontend-design
eq "C/tty: up + Enter = Install now: exit 0, consent prompt" "0|installed|prompt" "$RC|$(state_of frontend-design)|$(jf "$(prow frontend-design)" 'r["consent"]')"
has "C/tty: the menu showed the plan (skill, ref, source)" "$ERR" "hmd: install skill frontend-design (frontend-design@claude-plugins-official, from $MKT)?"
eq "C/tty: ... one install" "1" "$(n_installs)"
newcase; XENV="HMD_SKILLS_ASSUME=tty"; keys '\n'
cli install frontend-design
eq "C/tty: Enter on the default (Not now): exit 3, nothing installed, a suggested row" "3|0|suggested" "$RC|$(n_installs)|$(state_of frontend-design)"
newcase; XENV="HMD_SKILLS_ASSUME=tty"; keys 'j\n'
cli install frontend-design
eq "C/tty: down + Enter = Never ask again: exit 4, nothing installed, a declined row" "4|0|declined" "$RC|$(n_installs)|$(state_of frontend-design)"
has "C/tty: ... says it was declined and how to be asked again" "$ERR" "hmd skills suggest --reset"
keys 'k\n'
cli install frontend-design
eq "C/tty: a person typing the command again is asked again (declined -> installed)" "0|installed" "$RC|$(state_of frontend-design)"

newcase; XENV="FAKE_FAIL_RE=frontend-design"
cli install frontend-design --yes
eq "C: an install that fails: exit 1" "1" "$RC"
has "C: ... reported on stderr" "$ERR" "install failed"
eq "C: ... a failed row that still says how it was agreed to" "failed|yes-flag|hmd-skills-install|plugin" "$(rowinfo frontend-design | cut -d'|' -f1-4)"
eq "C: ... the receipt has the failure" "[('frontend-design@claude-plugins-official', 'failed')]" "$(rcpt '[(r["name"], r["result"]) for r in rs if r["kind"] == "plugin"]')"
cli suggest
eq "C: ... and it is suggested again" "yes" "$(listed frontend-design)"

newcase
cli install ui-ux-pro-max --yes
SKILLREPO=nextlevelbuilder/ui-ux-pro-max-skill
eq "C/github skill: exit 0 and the receipted clone" "0|git clone --depth 1 https://github.com/$SKILLREPO.git $HOME_DIR/.claude/skills/ui-ux-pro-max" "$RC|$(grep '^git clone' "$CALLS")"
eq "C/github skill: ... the lock row (kind, source, repo as ref, commit as version)" "installed|yes-flag|hmd-skills-install|github-skill|github.com/$SKILLREPO|$SKILLREPO|0123456789ab|none|explicit" "$(rowinfo ui-ux-pro-max)"
eq "C/github skill: ... the commit is the content hash" "0123456789ab" "$(jf "$(prow ui-ux-pro-max)" 'r["content_hash"]')"
eq "C/github skill: ... no claude call" "0" "$(grep -c '^claude ' "$CALLS" || true)"
cli install ui-ux-pro-max --yes
eq "C/github skill: again: already installed, no second clone" "0|1" "$RC|$(grep -c '^git clone' "$CALLS" || true)"

newcase
cli install --recommended --yes
eq "C/--recommended --yes: exit 0" "0" "$RC"
has "C/--recommended: ... and a summary" "$OUT" "9 installed, 0 already installed, 0 need consent, 0 declined, 0 failed"
eq "C/--recommended: exactly the recommended set was installed" "$(printf '%s@claude-plugins-official ' $RECOMMENDED)" "$(plugin_installs)"
eq "C/--recommended: the marketplace was registered once" "1" "$(grep -c '^claude plugins marketplace add ' "$CALLS" || true)"
eq "C/--recommended: no github skill, no git call" "0" "$(grep -c '^git ' "$CALLS" || true)"
eq "C/INV-S6: receipt ok lines == lock installed rows" "9|9" "$(rcpt 'sum(1 for r in rs if r["result"] == "ok" and r["kind"] == "plugin")')|$(count_rows installed)"
cli suggest
eq "C/--recommended: suggest then lists none of them" "no|no" "$(listed superpowers)|$(listed mcp-server-dev)"
cli install --recommended --yes
eq "C/--recommended: again installs nothing" "0|9" "$RC|$(n_installs)"

newcase
enable superpowers@claude-plugins-official
cli install --recommended
eq "C/--recommended, no tty, no --yes: exit 3" "3" "$RC"
eq "C/--recommended: nothing was installed" "0" "$(n_installs)"
eq "C/--recommended: the 8 that are not installed are suggested rows, the installed one has none" "8|no-row" "$(count_rows suggested)|$(rowinfo superpowers)"

newcase
CLIPATH="$SBX/bin/lib/skills_cli_install.py"
enable $(printf '%s@claude-plugins-official ' $RECOMMENDED)
cli consent auto
eq "C/explicit_consent: (the sandbox manifest) consent auto" "0" "$RC"
cli install --recommended --yes
eq "C/explicit_consent: --recommended never picks the community entry" "0" "$(n_installs)"
cli install zz-community
eq "C/explicit_consent: asked EVERY time, even in consent auto: exit 3, not installed" "3|0" "$RC|$(n_installs)"
cli install zz-community --yes
eq "C/explicit_consent: --yes installs it, consent yes-flag" "0|zz-community@claude-plugins-official |installed|yes-flag" "$RC|$(plugin_installs)|$(state_of zz-community)|$(jf "$(prow zz-community)" 'r["consent"]')"

newcase
: > "$PROJ/.planning"   # a file where the lock's directory should be
cli install seo --yes
eq "C: a lock that cannot be written: the install result stands (exit 0, one install)" "0|1" "$RC|$(n_installs)"
has "C: ... and the lock failure is said on stderr" "$ERR" "lock row for seo"

newcase
rm -rf "$TMP/nogate"; cp -R "$SBX" "$TMP/nogate"; rm -f "$TMP/nogate/bin/lib/skills_consent.sh"
CLIPATH="$TMP/nogate/bin/lib/skills_cli_install.py"
cli install seo --yes
eq "C: no consent gate on disk: nothing is installed (fail closed), exit 1" "1|0" "$RC|$(n_installs)"
has "C: ... and it says why" "$ERR" "consent gate"

newcase; XENV="HMD_INSTALL_WHY_RULE=files HMD_INSTALL_WHY_EVIDENCE=Dockerfile"
cli install devops-toolkit --yes
eq "C: the caller's trigger (HMD_INSTALL_WHY_RULE and _EVIDENCE) is the row's why" "installed|files|Dockerfile" "$(state_of devops-toolkit)|$(jf "$(prow devops-toolkit)" 'r["why"]["rule"]')|$(jf "$(prow devops-toolkit)" 'r["why"]["evidence"]')"

# ╔═ D. consent and allow ══════════════════════════════════════════════════════════════════════════════════════════╗
echo "D. consent and allow"
newcase
cli consent
eq "D: consent with no argument prints the mode (ask by default)" "0|consent: ask" "$RC|$OUT"
cli consent auto
eq "D: consent auto: exit 0" "0" "$RC"
eq "D: ... persists in skills-config.json" "auto" "$(cfg consent)"
eq "D: ... and the file says so" "yes" "$(grep -q '"consent": "auto"' "$HH/skills-config.json" && echo yes || echo no)"
cli consent
eq "D: ... and is read back" "consent: auto" "$OUT"
cli consent bogus
eq "D: a mode that is not allowed is exit 2, the file keeps its value" "2|auto" "$RC|$(cfg consent)"
cli consent ask
eq "D: back to ask" "0|ask" "$RC|$(cfg consent)"
XENV="HMD_SKILLS_CONSENT=ask"
cli consent auto
eq "D: the operator's environment beats the file: said on stderr" "0|yes" "$RC|$(grep -q 'HMD_SKILLS_CONSENT' <<<"$ERR" && echo yes || echo no)"

newcase
cli allow frontend-design
eq "D: allow ID: exit 0" "0" "$RC"
eq "D: ... the allowlist holds it" "frontend-design" "$(cfg allowlist)"
has "D: ... and a hint that the list applies in allowlist mode (the mode is ask)" "$ERR" "allowlist mode"
cli allow frontend-design
eq "D: allowing it again changes nothing" "0|frontend-design" "$RC|$(cfg allowlist)"
cli allow seo
eq "D: a second id is added after the first" "frontend-design seo" "$(cfg allowlist | tr '\n' ' ' | sed 's/ $//')"
cli allow no-such-skill
eq "D: an id the manifest does not list is exit 2, the list is unchanged" "2|frontend-design seo" "$RC|$(cfg allowlist | tr '\n' ' ' | sed 's/ $//')"
cli consent allowlist
cli allow slack
eq "D: in allowlist mode there is no hint" "0|no" "$RC|$(grep -q 'allowlist mode' <<<"$ERR" && echo yes || echo no)"
cli consent
eq "D: consent shows the mode and the allowlist" "consent: allowlist
allowlist: frontend-design seo slack" "$OUT"

# ╔═ E. a real pty ═════════════════════════════════════════════════════════════════════════════════════════════════╗
echo "E. a real pty (script -q), no seam"
PTY_OK=0
if command -v script >/dev/null 2>&1 && command -v perl >/dev/null 2>&1; then
  probe="$(perl -e 'alarm 30; exec @ARGV or exit 127' -- script -q /dev/null "$BASH" -c '[ -t 0 ] && [ -t 1 ] && echo PTY_OK' </dev/null 2>&1 | tr -d '\r')"
  case "$probe" in *PTY_OK*) PTY_OK=1 ;; esac
fi
pty_cli() {   # pty_cli KEYS ARGS... -> PTYOUT: the CLI under a pty on both descriptors, nothing seamed
  local keys="$1"; shift
  printf '%b' "$keys" > "$TMP/ptykeys"
  PTYOUT="$(cd "$PROJ" && perl -e 'alarm 60; exec @ARGV or exit 127' -- env -i HOME="$HOME_DIR" HEIMDALL_HOME="$HH" PATH="$GPATH" \
    TERM=dumb HMD_RUN_ID=run-test FAKE_CALLS="$CALLS" FAKE_STATE="$FS" script -q /dev/null "$TMP/pybin/python3" -I "${CLIPATH:-$CLI}" "$@" \
    < "$TMP/ptykeys" 2>&1 | tr -d '\r')"
}
if [ "$PTY_OK" -eq 1 ]; then
  newcase; pty_cli 'k\n' install frontend-design
  has "E: on a real terminal the menu shows the plan (skill, ref, source)" "$PTYOUT" "hmd: install skill frontend-design (frontend-design@claude-plugins-official, from $MKT)?"
  eq "E: ... up + Enter (Install now) installs it, consent prompt" "installed|prompt|1" "$(state_of frontend-design)|$(jf "$(prow frontend-design)" 'r["consent"]')|$(n_installs)"
  newcase; pty_cli '\n' install frontend-design
  eq "E: ... Enter on the default (Not now) installs nothing and leaves a suggested row" "suggested|0" "$(state_of frontend-design)|$(n_installs)"
else
  echo "  SKIP E: no usable script(1) pty here; section C covered the terminal through the seam"
fi

# ╔═ H. the suite can go RED ═══════════════════════════════════════════════════════════════════════════════════════╗
# A one-line break of a copy of the module (the text must occur exactly once, so a refactor that moves it fails here
# instead of skipping the check), then the call the matching check above makes: it must no longer give the right answer.
echo "H. one-line breaks of the module"
mutate() {   # mutate OLD NEW -> CLIPATH is a fresh copy of the sandbox whose module has OLD replaced by NEW
  rm -rf "$TMP/mut"; cp -R "$SBX" "$TMP/mut"
  if python3 -I -c 'import sys
path, old, new = sys.argv[1:4]
text = open(path, encoding="utf-8").read()
if text.count(old) != 1:
    sys.exit("the text to break is not there exactly once: " + old)
open(path, "w", encoding="utf-8").write(text.replace(old, new))' "$TMP/mut/bin/lib/skills_cli_install.py" "$1" "$2"; then
    CLIPATH="$TMP/mut/bin/lib/skills_cli_install.py"
  else
    bad "H: cannot apply the break [$1]"
    return 1
  fi
}
caught() { if [ "$2" != "$3" ]; then ok "H: $1 is caught"; else bad "H: $1 went unnoticed" "still [$3]"; fi; }

newcase; if mutate 'if outcome != "proceed":' 'if False:'; then
  cli install frontend-design
  caught "an install that ignores the gate's deferral" "3|0" "$RC|$(n_installs)"
fi
newcase; if mutate 'env["HMD_SKILLS_YES"] = "1"' 'env["HMD_SKILLS_YES"] = "0"'; then
  cli install frontend-design --yes
  caught "--yes that never reaches the gate" "0" "$RC"
fi
newcase; if mutate 'if not installable(entry):' 'if False:'; then
  cli install design-for-ai --yes
  caught "an install:false entry that goes on to the install" "2" "$RC"
fi
newcase; if mutate 'env["HMD_SKILLS_CONSENT"] = "ask"' 'pass'; then
  cli consent auto
  cli install zz-community
  caught "an explicit_consent entry that auto approves" "3" "$RC"
fi
newcase; if mutate 'if entry["tier"] == "recommended":' 'if entry["tier"] in ("recommended", "community"):'; then
  cli suggest
  caught "a community entry in the suggestions" "no" "$(listed zz-community)"
fi
newcase; if mutate '"--consent=" + basis' '"--consent=n/a"'; then
  cli install frontend-design --yes
  caught "a lock row that loses the consent basis" "yes-flag" "$(jf "$(prow frontend-design)" 'r["consent"]')"
fi
newcase; if mutate 'if entry["kind"] == "plugin" and entry["ref"] in enabled:' 'if False:'; then
  enable superpowers@claude-plugins-official
  cli suggest
  caught "a plugin the settings know that is suggested anyway" "no" "$(listed superpowers)"
fi
newcase; if mutate 'if ident in present:' 'if False:'; then
  cli install frontend-design --yes
  cli install frontend-design --yes
  caught "an installed entry that is installed again" "1" "$(n_installs)"
fi
newcase; if mutate 'status = skills_config.cmd_set("consent", args.mode)' 'status = 0'; then
  cli consent auto
  caught "a consent mode that is not persisted" "auto" "$(cfg consent)"
fi
if [ "$PTY_OK" -eq 1 ]; then
  newcase; if mutate 'stdout=subprocess.PIPE if capture else None' 'stdout=subprocess.PIPE'; then
    pty_cli 'k\n' install frontend-design
    caught "a gate that loses the terminal (its stdout captured)" "installed" "$(state_of frontend-design)"
  fi
fi

finish
