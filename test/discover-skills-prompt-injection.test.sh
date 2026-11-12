#!/usr/bin/env bash
# shellcheck disable=SC2016,SC2015  # SC2016: the hostile prompts and payloads below are literal text, $(...) and backticks must NOT expand here. SC2015: ok() always returns 0, so `A && ok || bad` is an if/else
# test/discover-skills-prompt-injection.test.sh
#
# A task prompt is DATA to the launcher, never program text.
#
# The defect (security): bin/heimdall's discover_skills spliced the user's prompt into the SOURCE of a python program --
#     python3 -c "... prompt = '''$prompt_lower''' ..."
# A prompt holding ''' ended that literal and the rest of the prompt was python: a crafted one ran arbitrary code
# (''' + __import__('os').system('touch PWNED') + '''), and an unlucky one (''' alone, a trailing backslash, a prompt wrapped in
# single quotes) was a SyntaxError that, under the launcher's set -e, aborted the launch. Prompts reach the launcher from the
# paired phone, so this was code execution on the dev machine. The registry path went into the same source, and six more sites
# in the file spliced a path or a name into python the same way (HOME, the working directory, `--skills install NAME`, the
# plugin directory).
#
# The contract proven here:
#   A. a normal prompt matches exactly what it matched before -- names, repos, order, word boundaries, the install call, the
#      "already installed" skip -- and a corpus over the REAL registry is byte-identical to the pre-fix function (kept below as
#      a fixture): the fix changed the channel, not the matching;
#   B. a hostile prompt -- ''' , """ , a trailing backslash, backslash escapes, $(...) and backticks, newlines, the PWNED
#      payloads, option-looking words, unicode, 300 KB -- neither crashes the launcher nor runs anything, and the keywords around
#      it still match;
#   C. the registry path is data too (a plugin directory named with quotes and a payload);
#   D. the other sites: HOME (heimdall_is_authed, apply_heimdall_theme), the working directory (--resume goal restore), the
#      skill name and the plugin directory (--skills install, --skills);
#   E. no python3 -c "..." in the launcher splices a shell expansion into program text, and no heredoc into python is unquoted;
#   V. control: the same payloads DO hurt the interpolating shape (the pre-fix function), so a clean run in A-D is not vacuous.
# Hermetic: HOME, the plugin tree, the working directory and `git` are throwaway dirs and fakes; no network, no real clone.
# Exemplar for cutting a function out of bin/heimdall and running it under the launcher's own set -euo pipefail:
# test/plugin-install-receipt.test.sh (run_fn).
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SELF_DIR/.." && pwd)"
LAUNCHER="$REPO/bin/heimdall"
# The consent gate discover_skills asks before every clone (T5.1; it needs its settings tool, bin/lib/skills_config.py, beside it).
# The harnesses below source it next to the function they cut out, and pin HMD_SKILLS_CONSENT=auto, the legacy behaviour that clones:
# this suite is about the prompt being data, not about when a NEW install is asked first (test/skills-consent-discover.test.sh).
CONSENT_LIB="$REPO/bin/lib/skills_consent.sh"
PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; [ -n "${2:-}" ] && printf '       %s\n' "$2"; }

command -v python3 >/dev/null 2>&1 || { echo "FATAL: python3 not found"; exit 2; }
[ -f "$LAUNCHER" ] || { echo "FATAL: $LAUNCHER is missing"; exit 2; }
for f in "$CONSENT_LIB" "$REPO/bin/lib/skills_config.py"; do
  [ -f "$f" ] || { echo "FATAL: $f is missing"; exit 2; }
done

WORK="$(mktemp -d)" || exit 1
trap 'rm -rf "$WORK"' EXIT
# python3 straight to the real interpreter: a version-manager shim costs ~0.4 s a call and this suite starts python ~80 times
# shellcheck source=lib/py-pin.sh disable=SC1091
. "$SELF_DIR/lib/py-pin.sh" && hmd_test_pin_python3 "$WORK/pybin"

PLUGIN="$WORK/plugin"
HOMEDIR="$WORK/home"
CWD="$WORK/cwd"
FAKEBIN="$WORK/fakebin"
INSTALL_LOG="$WORK/installs.log"
GIT_LOG="$WORK/git.log"
OUT="$WORK/out"
ERR="$WORK/err"
TWIN="$WORK/pre-fix-discover-skills.sh"
SRC=""
PROMPT_FILE=""
mkdir -p "$PLUGIN" "$FAKEBIN"

# A small registry with known keywords: the golden cases do not move when skills-registry.json gains a skill.
cat > "$PLUGIN/skills-registry.json" <<'JSON'
{"version": "test", "skills": [
  {"name": "ui-ux-pro-max", "repo": "owner/ui-ux-pro-max-skill", "description": "UI work",     "keywords": ["ui", "react", "tailwind", "landing page", "dashboard"]},
  {"name": "oh-my-mermaid", "repo": "owner/oh-my-mermaid",       "description": "Diagrams",    "keywords": ["diagram", "mermaid"]},
  {"name": "claude-seo",    "repo": "owner/claude-seo",          "description": "SEO work",    "keywords": ["seo", "sitemap"]},
  {"name": "godogen",       "repo": "owner/godogen",             "description": "Godot games", "keywords": ["godot", "game"]}
]}
JSON

# `git clone` is recorded, never made: the launcher's `--skills install` runs `git clone --depth 1 URL DEST`.
cat > "$FAKEBIN/git" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" = clone ] || exit 0
echo "git $*" >> "$FAKE_GIT_LOG"
last=""
for a in "$@"; do last="$a"; done
mkdir -p "$last"
SH
chmod +x "$FAKEBIN/git"

# The pre-fix discover_skills, verbatim: the control for section V and the reference for the byte-for-byte corpus in A10.
# It is a FIXTURE of the vulnerable shape, never run by the product.
cat > "$TWIN" <<'TWINFN'
discover_skills() {
  # Auto-install skills from registry based on task prompt keywords
  [ $# -eq 0 ] && return 0
  local prompt_lower skills_dir registry
  prompt_lower=$(echo "$*" | tr '[:upper:]' '[:lower:]')
  skills_dir="$HOME/.claude/skills"
  registry="$PLUGIN_DIR/skills-registry.json"

  [ -f "$registry" ] || return 0
  command -v python3 &>/dev/null || return 0

  # Match prompt against registry keywords, return repos to install
  local matches
  matches=$(python3 -c "
import json, re, sys
prompt = '''$prompt_lower'''
with open('$registry') as f:
    reg = json.load(f)
for skill in reg.get('skills', []):
    for kw in skill.get('keywords', []):
        if re.search(r'\b' + re.escape(kw) + r'\b', prompt):
            print(skill['name'] + '|' + skill['repo'])
            break
" 2>/dev/null)

  [ -z "$matches" ] && return 0

  while IFS='|' read -r name repo; do
    local skill_path="$skills_dir/$name"
    if [ -d "$skill_path" ]; then
      continue  # already installed
    fi
    printf "  \033[38;2;0;212;255m▸ Installing skill: %s\033[0m (%s)\n" "$name" "$repo"
    mkdir -p "$skills_dir"
    # Receipted; a failed clone is reported on stderr by the helper and the launch goes on without the skill.
    hmd_skill_install "$name" "$repo" "$skill_path" discover_skills || true
  done <<< "$matches"
}
TWINFN

# ── harness ──
# run_fn FUNC ARGS... : FUNC is cut out of $SRC (default: the real launcher) and run the way the launcher runs it -- bash,
# set -euo pipefail -- in the throwaway HOME, with cwd = $CWD (a payload that runs leaves its file there). The install itself is a
# recording stub. ANTHROPIC_API_KEY is dropped so heimdall_is_authed answers from the file. PROMPT_FILE, when set, supplies the
# one argument from a file (a prompt too big to pass through argv).
run_fn() {
  local fn="$1"; shift
  ( cd "$CWD" && env -u ANTHROPIC_API_KEY LC_ALL=C HOME="$HOMEDIR" PLUGIN_DIR="$PLUGIN" WORK_DIR="$CWD" FN="$fn" SRC="${SRC:-$LAUNCHER}" \
      HMD_SKILLS_CONSENT=auto CONSENT_LIB="$CONSENT_LIB" INSTALL_LOG="$INSTALL_LOG" PROMPT_FILE="$PROMPT_FILE" bash -c '
        set -euo pipefail
        . "$CONSENT_LIB"
        hmd_skill_install() { printf "%s|%s|%s|%s\n" "$1" "$2" "$3" "$4" >> "$INSTALL_LOG"; mkdir -p "$3"; }
        eval "$(sed -n "/^${FN}()/,/^}/p" "$SRC")"
        if [ -n "$PROMPT_FILE" ]; then set -- "$(cat "$PROMPT_FILE")"; fi
        "$FN" "$@"
      ' _ "$@" ) </dev/null >"$OUT" 2>"$ERR"
}

# run_goal DIR : the --resume goal-restore block of the launcher, with WORK_DIR=DIR; the restored goal is left in $OUT.
run_goal() {
  ( cd "$CWD" && env -u ANTHROPIC_API_KEY LC_ALL=C HOME="$HOMEDIR" WORKD="$1" SRC="$LAUNCHER" bash -c '
        set -euo pipefail
        WORK_DIR="$WORKD"
        eval "$(sed -n "/^  # Restore active goal from state or checkpoint/,/^  # Write preamble for resume/p" "$SRC")"
        printf "%s" "$GOAL_CONDITION"
      ' ) </dev/null >"$OUT" 2>"$ERR"
}

# run_launcher ARGS... : the REAL launcher, copied into the plugin tree $LPLUG, with a fake git first on PATH.
run_launcher() {
  ( cd "$CWD" && env -u ANTHROPIC_API_KEY LC_ALL=C PATH="$FAKEBIN:$PATH" HOME="$HOMEDIR" HEIMDALL_HOME="$WORK/hh" FAKE_GIT_LOG="$GIT_LOG" \
      HEIMDALL_NO_UPDATE_CHECK=1 HEIMDALL_NO_INTRO=1 "$LPLUG/bin/heimdall" "$@" ) </dev/null >"$OUT" 2>"$ERR"
}

# run_corpus SRC PLUGIN_ROOT PROMPTS : every prompt line through discover_skills from SRC; everything it prints, in one stream.
run_corpus() {
  ( cd "$CWD" && env -u ANTHROPIC_API_KEY LC_ALL=C HOME="$HOMEDIR" PLUGIN_DIR="$2" SRC="$1" PROMPTS="$3" \
      HMD_SKILLS_CONSENT=auto CONSENT_LIB="$CONSENT_LIB" bash -c '
        set -euo pipefail
        . "$CONSENT_LIB"
        hmd_skill_install() { printf "stub %s|%s|%s|%s\n" "$1" "$2" "$3" "$4"; mkdir -p "$3"; }
        eval "$(sed -n "/^discover_skills()/,/^}/p" "$SRC")"
        while IFS= read -r p; do
          rm -rf "$HOME/.claude/skills"
          printf "== %s\n" "$p"
          discover_skills "$p"
          printf "rc=%s\n" "$?"
        done < "$PROMPTS"
      ' ) </dev/null 2>&1
}

clean() { rm -rf "$HOMEDIR" "$CWD" "$WORK/PWNED_ABS"; mkdir -p "$HOMEDIR" "$CWD"; : > "$INSTALL_LOG"; : > "$GIT_LOG"; }
stray() { ls -A "$CWD"; [ ! -e "$WORK/PWNED_ABS" ] || echo PWNED_ABS; }   # whatever a payload left behind
installs() { cut -d'|' -f1 "$INSTALL_LOG" | tr '\n' ',' | sed 's/,$//'; }

# discover_case LABEL WANT ARGS... : discover_skills ARGS exits 0, installs exactly WANT ("a,b"; "" = nothing) and leaves nothing behind.
discover_case() {
  local label="$1" want="$2" rc got s; shift 2
  clean; run_fn discover_skills "$@"; rc=$?
  got="$(installs)"; s="$(stray | tr '\n' ' ')"
  if [ "$rc" -eq 0 ] && [ "$got" = "$want" ] && [ -z "$s" ]; then ok "$label"
  else bad "$label" "rc=$rc installs=[$got] want=[$want] stray=[$s] stderr=[$(head -c 160 "$ERR" | tr '\n' ' ')]"; fi
}

Q="'"
TQ="$Q$Q$Q"

echo "discover-skills-prompt-injection"

for fn in discover_skills heimdall_is_authed apply_heimdall_theme; do
  if [ -n "$(sed -n "/^${fn}()/,/^}/p" "$LAUNCHER")" ]; then ok "0. $fn is in bin/heimdall (the harness can cut it out)"; else bad "0. $fn is not in bin/heimdall"; fi
done
if [ -n "$(sed -n "/^  # Restore active goal from state or checkpoint/,/^  # Write preamble for resume/p" "$LAUNCHER")" ]; then
  ok "0. the --resume goal-restore block is in bin/heimdall"; else bad "0. the --resume goal-restore block is not in bin/heimdall"; fi

# ╔═ A. normal prompts: what they matched before ═══════════════════════════════════════════════════════════════════╗
echo "A. a normal prompt matches what it always matched"
clean; run_fn discover_skills "design a React dashboard with Tailwind"; rc=$?
want_log="ui-ux-pro-max|owner/ui-ux-pro-max-skill|$HOMEDIR/.claude/skills/ui-ux-pro-max|discover_skills"
if [ "$rc" -eq 0 ] && [ "$(cat "$INSTALL_LOG")" = "$want_log" ] && grep -q 'Installing skill: ui-ux-pro-max.*(owner/ui-ux-pro-max-skill)' "$OUT"; then
  ok "A1 'design a React dashboard with Tailwind': one install -- name, repo, destination, via -- announced on stdout"
else bad "A1 design a React dashboard with Tailwind" "rc=$rc log=[$(cat "$INSTALL_LOG")] out=[$(head -c 200 "$OUT")]"; fi
discover_case "A2 two skills, in registry order"                   "oh-my-mermaid,claude-seo" "build a diagram of the architecture and fix the SEO sitemap"
discover_case "A3 'ui' is a word, not a substring (build, guild, fruit)" ""                   "build the guild a fruit guide"
discover_case "A4 a two-word keyword"                              "ui-ux-pro-max"            "make a landing page"
discover_case "A5 case is folded"                                  "godogen"                  "GODOT GAME"
discover_case "A6 ordinary punctuation, quotes, \$ and backticks"  "oh-my-mermaid,claude-seo" "don't use \"sitemap.xml\" — it's \$HOME/seo; \`diagram\` (mermaid) & more"
discover_case "A7 several arguments are one prompt"                "ui-ux-pro-max"            react dashboard "for me"
discover_case "A8 no arguments: nothing, quietly"                  ""
clean; mkdir -p "$HOMEDIR/.claude/skills/ui-ux-pro-max"; run_fn discover_skills "react and godot"; rc=$?
[ "$rc" -eq 0 ] && [ "$(installs)" = "godogen" ] && ok "A9 an already installed skill is skipped" || bad "A9 an installed skill was installed again" "rc=$rc installs=[$(installs)]"

# A10: the pre-fix function (the fixture) and the real one, over the REAL registry, byte for byte.
CORPUS="$WORK/corpus.txt"
cat > "$CORPUS" <<'CORPUS'
build a landing page for a bakery
Design a React dashboard with Tailwind and a dark mode
draw a mermaid diagram of the architecture
fix the SEO meta tags and the sitemap
make a 2D game in Godot
don't break the build; it's "urgent" ($50 budget) -- see `notes` {a,b} 100% [ok] <b> a|b
refactor the guild module
ADVERTISING CAMPAIGN FOR GOOGLE ADS
fix the login bug
CORPUS
python3 -I - "$REPO/skills-registry.json" >> "$CORPUS" <<'PY'
import json, sys
for skill in json.load(open(sys.argv[1]))["skills"]:
    words = skill["keywords"]
    print("please help with %s and the %s side of it" % (words[0], words[-1].upper()))
PY
clean
run_corpus "$TWIN" "$REPO" "$CORPUS" > "$WORK/corpus.pre-fix"
run_corpus "$LAUNCHER" "$REPO" "$CORPUS" > "$WORK/corpus.fixed"
NSTUB="$(grep -c '^stub ' "$WORK/corpus.fixed")"
if cmp -s "$WORK/corpus.pre-fix" "$WORK/corpus.fixed" && [ "$NSTUB" -ge 5 ]; then
  ok "A10 $(wc -l < "$CORPUS" | tr -d ' ') normal prompts over the real registry: the output is byte-identical to the pre-fix function's ($NSTUB installs)"
else bad "A10 corpus output differs from the pre-fix function's (installs: $NSTUB)" "$(diff "$WORK/corpus.pre-fix" "$WORK/corpus.fixed" | head -6 | tr '\n' '~')"; fi

# ╔═ B. hostile prompts ════════════════════════════════════════════════════════════════════════════════════════════╗
echo "B. a hostile prompt neither crashes the launcher nor runs anything, and the keywords around it still match"
# LABEL @@ skills that must be installed @@ the prompt, literally (@NL@ is a newline)
NL=$'\n'
while IFS= read -r line; do
  [ -n "$line" ] || continue
  label="${line%% @@ *}"; rest="${line#* @@ }"; want="${rest%% @@ *}"; prompt="${rest#* @@ }"
  discover_case "B. $label" "$want" "${prompt//@NL@/$NL}"
done <<'TABLE'
''' then a keyword @@ ui-ux-pro-max @@ ''' react
a lone ''' @@  @@ '''
""" then a keyword @@ ui-ux-pro-max @@ """ react """
a prompt wrapped in single quotes (ends in ') @@ ui-ux-pro-max @@ 'build a react app'
a keyword glued to ''' @@ ui-ux-pro-max @@ react'''dashboard
a trailing backslash @@ ui-ux-pro-max @@ react \
backslash escapes (\t \n \x41 \\) @@ ui-ux-pro-max @@ c:\temp\new\x41\\ react
the task payload, alone @@  @@ ''' + __import__('os').system('touch PWNED') + '''
a payload that still evaluates, around keywords @@ ui-ux-pro-max @@ react ''' + str(__import__('os').system('touch PWNED')) + ''' dashboard
a payload written as statements @@  @@ x''' ; import os ; os.system('touch PWNED') ; y='''
a payload after a closing ''' and a newline @@ ui-ux-pro-max @@ react@NL@'''@NL@import os@NL@os.system("touch PWNED")@NL@'''@NL@dashboard
$( ) and backticks stay text @@ ui-ux-pro-max @@ react $(touch PWNED_SUBST) `touch PWNED_TICK` dashboard
format and brace characters @@ ui-ux-pro-max @@ react {0} %s %(x)s {{}} ${HOME} \N{DIGIT ONE}
a prompt that looks like an option: -c @@  @@ -c
a prompt that looks like an option: --help @@  @@ --help
a prompt that looks like an option: -I @@  @@ -I
unicode around the keywords @@ ui-ux-pro-max @@ 'réact' “dashboard” ✔ ‘’
TABLE
discover_case "B. the payload with an absolute path, around a keyword" "ui-ux-pro-max" \
  "react ${TQ} + str(__import__(${Q}os${Q}).system(${Q}touch $WORK/PWNED_ABS${Q})) + ${TQ} dashboard"
PROMPT_FILE="$WORK/big-prompt"
{ head -c 300000 /dev/zero | tr '\0' 'x'; printf ' react\n'; } > "$PROMPT_FILE"
discover_case "B. a 300 KB prompt (past any single-argument limit) with a keyword at the end" "ui-ux-pro-max" ""
PROMPT_FILE=""

# ╔═ C. the registry path is data too ══════════════════════════════════════════════════════════════════════════════╗
echo "C. the registry path is data too"
HOSTILE_PLUGIN="$WORK/p'+__import__('os').system('touch PWNED_PLUGIN')+'x"
APOSTROPHE_PLUGIN="$WORK/o'brien's ''' plugin"
mkdir -p "$HOSTILE_PLUGIN" "$APOSTROPHE_PLUGIN"
cp "$PLUGIN/skills-registry.json" "$HOSTILE_PLUGIN/"
cp "$PLUGIN/skills-registry.json" "$APOSTROPHE_PLUGIN/"
SAVED_PLUGIN="$PLUGIN"
PLUGIN="$HOSTILE_PLUGIN";    discover_case "C1 a plugin directory named with a payload still matches, runs nothing" "ui-ux-pro-max" "build a react app"
PLUGIN="$APOSTROPHE_PLUGIN"; discover_case "C2 a plugin directory with ' and ''' in its name still matches"          "ui-ux-pro-max" "build a react app"
PLUGIN="$SAVED_PLUGIN"

# ╔═ D. the other sites ════════════════════════════════════════════════════════════════════════════════════════════╗
echo "D. the other sites that spliced a path or a name into python source"
HOSTILE_HOME="$WORK/h'+__import__('os').system('touch PWNED_HOME')+'x"
HOMEDIR="$HOSTILE_HOME"; clean
printf '{"oauthAccount":{"accountUuid":"u-1"}}' > "$HOMEDIR/.claude.json"
run_fn heimdall_is_authed; rc=$?; s="$(stray | tr '\n' ' ')"
[ "$rc" -eq 0 ] && [ -z "$s" ] && ok "D1 heimdall_is_authed: a HOME named with a payload still finds the account and runs nothing" \
  || bad "D1 heimdall_is_authed under a hostile HOME" "rc=$rc stray=[$s]"
printf '{"oauthAccount":{}}' > "$HOMEDIR/.claude.json"
run_fn heimdall_is_authed; rc=$?; s="$(stray | tr '\n' ' ')"
[ "$rc" -eq 1 ] && [ -z "$s" ] && ok "D1 heimdall_is_authed: an account-less file is not authed (the answer follows the file)" \
  || bad "D1 heimdall_is_authed without an account" "rc=$rc stray=[$s]"
printf '{"theme":"light","keep":1}' > "$HOMEDIR/.claude.json"
run_fn apply_heimdall_theme; rc=$?; s="$(stray | tr '\n' ' ')"
theme="$(python3 -I -c 'import json, sys; d = json.load(open(sys.argv[1])); print(d.get("theme"), d.get("keep"))' "$HOMEDIR/.claude.json" 2>&1)"
[ "$rc" -eq 0 ] && [ "$theme" = "dark 1" ] && [ -z "$s" ] && ok "D2 apply_heimdall_theme: a hostile HOME still gets theme=dark, the rest of the file kept, nothing run" \
  || bad "D2 apply_heimdall_theme under a hostile HOME" "rc=$rc theme=[$theme] stray=[$s]"
HOMEDIR="$WORK/home"; clean

HOSTILE_WD="$WORK/w'+__import__('os').system('touch PWNED_WORKDIR')+'x"
mkdir -p "$HOSTILE_WD/.planning"
printf '{"goal":{"condition":"ship the release"}}' > "$HOSTILE_WD/heimdall-state.json"
run_goal "$HOSTILE_WD"; got="$(cat "$OUT")"; s="$(stray | tr '\n' ' ')"
[ "$got" = "ship the release" ] && [ -z "$s" ] && ok "D3 --resume: the goal is restored from heimdall-state.json in a directory named with a payload, nothing run" \
  || bad "D3 --resume goal from heimdall-state.json" "goal=[$got] stray=[$s] stderr=[$(head -c 160 "$ERR" | tr '\n' ' ')]"
printf '{}' > "$HOSTILE_WD/heimdall-state.json"
printf '{"goal":{"condition":"from settings"}}' > "$HOSTILE_WD/.planning/settings.json"
run_goal "$HOSTILE_WD"; got="$(cat "$OUT")"; s="$(stray | tr '\n' ' ')"
[ "$got" = "from settings" ] && [ -z "$s" ] && ok "D3 --resume: with no goal in the state file it is restored from .planning/settings.json, nothing run" \
  || bad "D3 --resume goal from .planning/settings.json" "goal=[$got] stray=[$s]"

LPLUG="$WORK/lp'+__import__('os').system('touch PWNED_LAUNCHER')+'x"
mkdir -p "$LPLUG/bin/lib"
cp "$LAUNCHER" "$LPLUG/bin/heimdall"
chmod +x "$LPLUG/bin/heimdall"
cp "$PLUGIN/skills-registry.json" "$LPLUG/skills-registry.json"
for lib in select.sh real-home.sh install-receipt.sh; do
  if [ -f "$REPO/bin/lib/$lib" ]; then cp "$REPO/bin/lib/$lib" "$LPLUG/bin/lib/$lib"; fi
done
clean; run_launcher --skills install ui-ux-pro-max; rc=$?
want_clone="git clone --depth 1 https://github.com/owner/ui-ux-pro-max-skill.git $HOMEDIR/.claude/skills/ui-ux-pro-max"
[ "$rc" -eq 0 ] && [ "$(cat "$GIT_LOG")" = "$want_clone" ] && [ -z "$(stray)" ] \
  && ok "D4 --skills install NAME: a plugin directory named with a payload still resolves NAME to its repo and clones it, nothing run" \
  || bad "D4 --skills install ui-ux-pro-max" "rc=$rc git=[$(cat "$GIT_LOG")] stray=[$(stray | tr '\n' ' ')] stderr=[$(head -c 160 "$ERR" | tr '\n' ' ')]"
clean; run_launcher --skills install "x' or __import__('os').system('touch PWNED_NAME') or 'y"; rc=$?
[ "$rc" -eq 1 ] && [ ! -s "$GIT_LOG" ] && [ -z "$(stray)" ] && grep -q 'not found in registry' "$OUT" \
  && ok "D5 --skills install: a skill NAME holding quotes and a payload is just an unknown name -- not found, nothing cloned, nothing run" \
  || bad "D5 --skills install with a hostile name" "rc=$rc git=[$(cat "$GIT_LOG")] stray=[$(stray | tr '\n' ' ')] out=[$(head -c 160 "$OUT" | tr '\n' ' ')]"
clean; run_launcher --skills; rc=$?
LISTED="$(grep -c -E '(ui-ux-pro-max|oh-my-mermaid|claude-seo|godogen)' "$OUT")"
[ "$rc" -eq 0 ] && [ "$LISTED" -eq 4 ] && [ -z "$(stray)" ] \
  && ok "D6 --skills: the registry listing prints all 4 skills from a plugin directory named with a payload, nothing run" \
  || bad "D6 --skills listing" "rc=$rc listed=$LISTED stray=[$(stray | tr '\n' ' ')] stderr=[$(head -c 160 "$ERR" | tr '\n' ' ')]"

# ╔═ E. the whole file: no shell expansion spliced into python source ═══════════════════════════════════════════════╗
echo "E. no python in bin/heimdall is built by splicing shell expansions into its source"
scan_launcher() {
  python3 -I - "$1" <<'PY'
import re, sys

lines = open(sys.argv[1], encoding="utf-8").read().split("\n")
src = "\n".join("" if ln.lstrip().startswith("#") else ln for ln in lines)   # comments talk ABOUT forms; they are not forms
found = []
# python3 -c "...": bash expands a double-quoted program first, so a $ or a backtick in it is a shell value spliced into the source
for m in re.finditer(r'\bpython3?(?:[ \t]+-[A-Za-z]+)*[ \t]+-c[ \t]+"', src):
    j = m.end()
    while j < len(src) and src[j] != '"':
        j += 2 if src[j] == "\\" else 1
    body = re.sub(r"\\.", "", src[m.end():j], flags=re.S)
    if "$" in body or "`" in body:
        found.append("line %d: python3 -c \"...\" splices a shell expansion into program text" % (src.count("\n", 0, m.start()) + 1))
# a heredoc into python whose delimiter is not quoted is expanded the same way
for m in re.finditer(r"\bpython3?\b[^\n]*<<-?[ \t]*[A-Za-z_]", src):
    found.append("line %d: heredoc into python3 with an unquoted delimiter" % (src.count("\n", 0, m.start()) + 1))
print("\n".join(found))
PY
}
SCAN="$(scan_launcher "$LAUNCHER" 2>&1)"
if [ -z "$SCAN" ]; then ok "E1 no python3 -c \"...\" with a shell expansion in it, no unquoted heredoc into python3"; else bad "E1 python source built from shell text" "$(echo "$SCAN" | tr '\n' '~')"; fi

# ╔═ V. control: the pre-fix shape IS vulnerable ═══════════════════════════════════════════════════════════════════╗
echo "V. control: the same payloads hurt the pre-fix shape, so the clean runs above mean something"
SRC="$TWIN"
clean; run_fn discover_skills "react ${TQ} + str(__import__(${Q}os${Q}).system(${Q}touch PWNED${Q})) + ${TQ} dashboard"; rc=$?
[ -n "$(stray)" ] && ok "V1 pre-fix: the payload runs -- it left $(stray | tr '\n' ' ')behind (the prompt is lowercased first; rc=$rc)" || bad "V1 pre-fix: the payload did not run, so the checks above prove nothing" "rc=$rc"
clean; run_fn discover_skills "$TQ"; rc=$?
[ "$rc" -ne 0 ] && ok "V2 pre-fix: a prompt of ''' aborts the launcher (rc=$rc)" || bad "V2 pre-fix: ''' did not abort" "rc=$rc"
clean; run_fn discover_skills "'build a react app'"; rc=$?
[ "$rc" -ne 0 ] && ok "V3 pre-fix: a prompt wrapped in single quotes aborts the launcher (rc=$rc)" || bad "V3 pre-fix: a quote-wrapped prompt did not abort" "rc=$rc"
clean; PLUGIN="$HOSTILE_PLUGIN"; run_fn discover_skills "build a react app"; rc=$?; PLUGIN="$SAVED_PLUGIN"
[ -n "$(stray)" ] && ok "V4 pre-fix: a payload in the registry path runs too (it left $(stray | tr '\n' ' '))" || bad "V4 pre-fix: the registry-path payload did not run" "rc=$rc"
SRC=""

echo "--------------------------------------------------------------------"
printf 'discover-skills-prompt-injection: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
