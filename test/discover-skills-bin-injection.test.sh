#!/usr/bin/env bash
# shellcheck disable=SC2016,SC2015,SC2086  # SC2016: the hostile payloads below are literal text, $(...) and backticks must NOT expand here. SC2015: ok() always returns 0, so `A && ok || bad` is an if/else. SC2086: ${PANE_PATH:+VAR=value} is one env word on purpose
# test/discover-skills-bin-injection.test.sh
#
# What a prompt, a skill name, a directory name or a task holds is DATA to bin/discover-skills, bin/session-fork and `heimdall --team`;
# it is never program text and never keystrokes.
#
# The defects (security), all of one class -- data reaching an interpreter as SOURCE:
#   bin/discover-skills  put the task prompt (prompt = '''$prompt_lower'''), the registry path, a skill domain, a skill name and a
#                        skill directory into the source of five `python3 -c "..."` programs. A prompt holding ''' ended the literal and
#                        the rest ran as python; `install owner/x'+...+'x` ran the name; a stray quote was a SyntaxError that aborted
#                        the script under set -e.
#   bin/session-fork     ran its four `python3 -c "..."` programs from the caller's working directory without -I, so a project that
#                        ships a json.py had it imported (code execution on the first `session-fork wave`).
#   heimdall --team      TYPED the working directory, the plugin directory and the task into a tmux pane with `tmux send-keys`. A shell
#                        reads typed text twice: a line editor (readline/ZLE: ^U kills the line typed so far) and then its parser, so
#                        a `;` or `$( )` in a task typed in while claude was not the foreground process ran; a task such as
#                        `<^U>touch X; echo '` defeats even quoting; and `Enter` / `C-c` were read as tmux key names.
#
# The contract proven here:
#   A. normal use is unchanged, byte for byte: detect, detect-file, gaps and install print what they printed (an em dash included),
#      session-fork forks the same argv, `--team` starts the same claude commands in the same directory;
#   B. a hostile prompt -- ''' , """ , a trailing backslash, $(...), backticks, newlines, the PWNED payloads, option-looking words --
#      neither crashes discover-skills nor runs anything, and the keywords around it still match;
#   C. the registry path is data too (a plugin directory named with quotes and a payload);
#   D. the other discover-skills sites: a skill name, a skill directory, a skill domain, and a planted json.py in the working directory;
#   E. session-fork: hostile ids, roles and prompts reach hmd-exec verbatim and run nothing; a planted json.py is never imported;
#   F. heimdall --team: a hostile working directory, plugin directory or task runs nothing and reaches claude as exact argv, under
#      sh, bash and zsh, with claude present and with claude failing to start; what tmux is TYPED holds none of it and no control
#      character; a directory name with a control character is refused;
#   G. no python in the two scripts is built by splicing a shell expansion into its source, and every one runs under -I;
#   V. control: the same payloads DO hurt the pre-fix shapes (kept below as fixtures), so a clean run in A-G is not vacuous.
# Hermetic: HOME, the plugin trees, the working directory, `git`, `tmux`, `claude` and `hmd-exec` are throwaway dirs and recording fakes;
# a payload only ever `touch`es a PWNED* file inside the sandbox. No network, no real clone, no real tmux.
# Exemplars: test/discover-skills-prompt-injection.test.sh (the same fix for bin/heimdall), test/session-fork-role.test.sh (the
# session-fork fixture), test/heimdall-cli-routing.test.sh section 8e (the real launcher with a stub tmux).
# budget: 45 -- ~39 s solo: ~100 hermetic launches of the real scripts (a few process spawns each), about 50 of them through a fake tmux that runs a real pane shell (sh, bash, zsh).
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SELF_DIR/.." && pwd)"
DISCOVER="$REPO/bin/discover-skills"
FORK="$REPO/bin/session-fork"
LAUNCHER="$REPO/bin/heimdall"
PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; [ -n "${2:-}" ] && printf '       %s\n' "$2"; }

command -v python3 >/dev/null 2>&1 || { echo "FATAL: python3 not found"; exit 2; }
for f in "$DISCOVER" "$FORK" "$LAUNCHER" "$REPO/bin/lib/install-receipt.sh" "$SELF_DIR/lib/py-pin.sh"; do
  [ -f "$f" ] || { echo "FATAL: $f is missing"; exit 2; }
done

WORK="$(mktemp -d)" || exit 1
trap 'rm -rf "$WORK"' EXIT
# python3 straight to the real interpreter: a version-manager shim costs ~0.4 s a call and this suite starts python ~100 times
# shellcheck source=lib/py-pin.sh disable=SC1091
. "$SELF_DIR/lib/py-pin.sh" && hmd_test_pin_python3 "$WORK/pybin"

HOMEDIR="$WORK/home"
CWD="$WORK/cwd"
FAKEBIN="$WORK/fakebin"
OUT="$WORK/out"
ERR="$WORK/err"
GIT_LOG="$WORK/git.log"
DSPLUG="$WORK/ds-plugin"        # a plugin tree holding a copy of bin/discover-skills
FORKPLUG="$WORK/fork-plugin"    # a plugin tree holding a copy of bin/session-fork and a recording hmd-exec
FORKRES="$WORK/fork-results"
FORKLOG="$WORK/fork-calls"
TMUXD="$WORK/tmux-state"
CLAUDED="$WORK/claude-calls"
mkdir -p "$FAKEBIN"

# A small registry with known keywords, categories and an em dash: the golden cases do not move when skills-registry.json gains a skill.
cat > "$WORK/registry.json" <<'JSON'
{"version": "test", "skills": [
  {"name": "ui-ux-pro-max", "repo": "owner/ui-ux-pro-max-skill", "description": "UI work — pro", "category": "design",        "keywords": ["ui", "react", "tailwind", "landing page", "dashboard"]},
  {"name": "oh-my-mermaid", "repo": "owner/oh-my-mermaid",       "description": "Diagrams",      "category": "documentation", "keywords": ["diagram", "mermaid"]},
  {"name": "claude-seo",    "repo": "owner/claude-seo",          "description": "SEO work",      "category": "marketing",     "keywords": ["seo", "sitemap"]},
  {"name": "godogen",       "repo": "owner/godogen",             "description": "Godot games",   "category": "gamedev",       "keywords": ["godot", "game"]}
]}
JSON

# `git clone` is recorded and made: the destination gets a CLAUDE.md and a skill.json, which is what makes install_skill write a SKILL.md.
cat > "$FAKEBIN/git" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" = clone ] || exit 0
echo "git $*" >> "$FAKE_GIT_LOG"
dest=""
for a in "$@"; do dest="$a"; done
mkdir -p "$dest"
printf '# CLAUDE.md\nSkill body line\n' > "$dest/CLAUDE.md"
printf '{"description": "A test skill"}' > "$dest/skill.json"
SH

# sed: bin/discover-skills appends a CLAUDE.md with sed '1{/^# CLAUDE\.md$/d}', which GNU sed accepts and BSD sed (macOS) rejects
# ("extra characters at the end of d command"), aborting the install under set -e. That pre-existing portability gap is not what this
# suite is about, so the sandbox's sed accepts the one script; every other call is the system sed.
cat > "$FAKEBIN/sed" <<'SH'
#!/bin/sh
real=/usr/bin/sed
[ -x "$real" ] || real=/bin/sed
if [ "${1:-}" = '1{/^# CLAUDE\.md$/d}' ]; then shift; exec "$real" '1{/^# CLAUDE\.md$/d;}' "$@"; fi
exec "$real" "$@"
SH

# claude: records its argv (NUL separated) and its directory, then exits at once -- a claude that is not the foreground process any more
cat > "$FAKEBIN/claude" <<'SH'
#!/usr/bin/env bash
d="${FAKE_CLAUDE_DIR:?}"
n=$(( $(cat "$d/n" 2>/dev/null || echo 0) + 1 ))
echo "$n" > "$d/n"
printf '%s\0' "$@" > "$d/$n.argv"
pwd -P > "$d/$n.cwd"
exit 0
SH

# tmux: logs every call and plays the panes. State in $FAKE_TMUX_DIR:
#   typed.nul  everything send-keys typed, one NUL-terminated record per argument (Enter is the record <Enter>)
#   exec.nul   every line a pane shell was asked to run, NUL-terminated
#   pN.line    the line pane N is typing; pN.cwd its start directory; pN.out what its shell printed
# A pane shell is FAKE_PANE_SHELL (sh | bash | zsh) run as `SHELL -c LINE` -- what an interactive shell does with a typed line, minus the
# prompt -- after the few things a line editor does with the control characters it reads: ^U kills the line, ^C abandons it, DEL
# erases a character, ESC is swallowed. FAKE_PANE_PATH, when set, is that shell's PATH (a PATH without claude is a claude that
# failed to start). A tmux command or flag the launcher has no business using is an error, so a changed launcher cannot pass by luck.
cat > "$FAKEBIN/tmux" <<'SH'
#!/usr/bin/env bash
export LC_ALL=C
D="${FAKE_TMUX_DIR:?}"
cmd="${1:-}"; shift

feed() {   # PANE TEXT
  local p="$1" t="$2" line c i=0
  printf '%s\0' "$t" >> "$D/typed.nul"
  line="$(cat "$D/p$p.line"; printf x)"; line="${line%x}"
  case "$t" in
    *[[:cntrl:]]*)
      while [ "$i" -lt "${#t}" ]; do
        c="${t:$i:1}"; i=$((i + 1))
        case "$c" in
          $'\025') case "$line" in *$'\n'*) line="${line%$'\n'*}"$'\n' ;; *) line="" ;; esac ;;
          $'\003') line="" ;;
          $'\177'|$'\010') line="${line%?}" ;;
          $'\033') ;;
          *) line="$line$c" ;;
        esac
      done ;;
    *) line="$line$t" ;;
  esac
  printf '%s' "$line" > "$D/p$p.line"
}

run_line() {   # PANE LINE : the pane's shell reads one complete line
  local p="$1" line="$2" sh_cmd
  printf '%s\0' "$line" >> "$D/exec.nul"
  case "${FAKE_PANE_SHELL:-sh}" in bash) sh_cmd="bash --noprofile --norc" ;; zsh) sh_cmd="zsh -f" ;; *) sh_cmd="sh" ;; esac
  ( cd "$(cat "$D/p$p.cwd")" 2>/dev/null || cd /
    [ -z "${FAKE_PANE_PATH:-}" ] || PATH="$FAKE_PANE_PATH"
    exec $sh_cmd -c "$line" ) >> "$D/p$p.out" 2>&1 < /dev/null
  return 0
}

submit() {   # PANE : Enter
  local p="$1" line
  printf '<Enter>\0' >> "$D/typed.nul"
  line="$(cat "$D/p$p.line"; printf x)"; line="${line%x}"
  : > "$D/p$p.line"
  run_line "$p" "$line"
}

resolve() { case "$1" in *:*.[0-9]*) printf '%s' "${1##*.}" ;; *) cat "$D/active" ;; esac; }
unsupported() { echo "fake tmux: unsupported: $*" >&2; echo "$*" >> "$D/errors.log"; exit 1; }

opt_t=""; opt_c=""; flag_d=0; literal=0; R=()
parse_flags() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --) shift; break ;;
      -t) opt_t="$2"; shift 2 ;;
      -c) opt_c="$2"; shift 2 ;;
      -s|-n) shift 2 ;;
      -d) flag_d=1; shift ;;
      -h|-v) shift ;;
      -l) literal=1; shift ;;
      -*) unsupported "$cmd $1" ;;
      *) break ;;
    esac
  done
  R=("$@")
}

case "$cmd" in
  new-session)
    parse_flags "$@"
    echo 1 > "$D/n"; echo 0 > "$D/active"; : > "$D/p0.line"
    if [ -n "$opt_c" ]; then printf '%s' "$opt_c" > "$D/p0.cwd"; else pwd > "$D/p0.cwd"; fi
    if [ ${#R[@]} -gt 0 ]; then unsupported "$cmd with a command"; fi ;;
  split-window)
    parse_flags "$@"
    a="$(cat "$D/active")"; i="$(cat "$D/n")"; echo $((i + 1)) > "$D/n"; : > "$D/p$i.line"
    if [ -n "$opt_c" ]; then printf '%s' "$opt_c" > "$D/p$i.cwd"; else cp "$D/p$a.cwd" "$D/p$i.cwd"; fi
    [ "$flag_d" = 1 ] || echo "$i" > "$D/active"
    if [ ${#R[@]} -gt 0 ]; then unsupported "$cmd with a command"; fi ;;
  send-keys)
    parse_flags "$@"
    pane="$(resolve "$opt_t")"
    for key in "${R[@]}"; do
      if [ "$literal" = 1 ]; then feed "$pane" "$key"
      else
        case "$key" in
          Enter|C-m|C-j) submit "$pane" ;;
          Space) feed "$pane" " " ;;
          Tab) feed "$pane" $'\t' ;;
          C-c) feed "$pane" $'\003' ;;
          C-u) feed "$pane" $'\025' ;;
          Escape) feed "$pane" $'\033' ;;
          BSpace) feed "$pane" $'\177' ;;
          *) feed "$pane" "$key" ;;
        esac
      fi
    done ;;
  select-layout) : ;;
  attach|attach-session) exit 0 ;;
  *) unsupported "$cmd" ;;
esac
exit 0
SH

# hmd-exec for the session-fork fixture: records its argv (NUL separated) in a file of its own, prints a fixed answer
mkdir -p "$FORKPLUG/bin"
cat > "$FORKPLUG/bin/hmd-exec" <<'SH'
#!/usr/bin/env bash
printf '%s\0' "$@" > "${FORK_LOG:?}/$$.argv"
echo "FAKE-OK"
SH
chmod +x "$FAKEBIN/git" "$FAKEBIN/sed" "$FAKEBIN/claude" "$FAKEBIN/tmux" "$FORKPLUG/bin/hmd-exec"
cp "$FORK" "$FORKPLUG/bin/session-fork"
chmod +x "$FORKPLUG/bin/session-fork"

# ── the pre-fix shapes, verbatim: the controls of section V and the byte reference of A/F. FIXTURES of the vulnerable code, never run
#    by the product ──
cat > "$WORK/pre-fix-detect.sh" <<'TWIN'
cmd_detect() {
  # Detect skill gaps from prompt keywords
  local prompt="$*"
  [ -z "$prompt" ] && { echo "Usage: discover-skills detect <prompt or description>"; return 1; }

  local prompt_lower
  prompt_lower=$(echo "$prompt" | tr '[:upper:]' '[:lower:]')

  [ -f "$REGISTRY" ] || { echo "No registry found"; return 0; }
  command -v python3 &>/dev/null || { echo "python3 required"; return 0; }

  local gaps
  gaps=$(python3 -c "
import json, re, os
prompt = '''${prompt_lower}'''
with open('$REGISTRY') as f:
    reg = json.load(f)
skills_dir = os.path.expanduser('~/.claude/skills')
found = []
for skill in reg.get('skills', []):
    if os.path.isdir(os.path.join(skills_dir, skill['name'])):
        continue
    for kw in skill.get('keywords', []):
        if re.search(r'\b' + re.escape(kw) + r'\b', prompt):
            found.append(skill)
            break
for s in found:
    print(f\"MISSING: {s['name']} ({s['repo']}) — {s['description']}\")
    print(f\"  Install: discover-skills install {s['name']}\")
if not found:
    print('No skill gaps detected.')
" 2>/dev/null)

  echo "$gaps"
}
TWIN

cat > "$WORK/pre-fix-team.sh" <<'TWIN'
if [[ "${1:-}" == "--team" ]]; then
  ensure_node_path
  ensure_claude
  first_run_setup
  ensure_auth
  apply_heimdall_theme 2>/dev/null || true
  print_banner 2>/dev/null || true

  TEAM_SIZE="${2:-3}"
  shift 2 || shift 1
  TASK="${*:-}"

  if ! command -v tmux &>/dev/null; then
    echo "  tmux not found. Install: brew install tmux (macOS) / apt install tmux (Linux)"
    exit 1
  fi

  SESSION="heimdall-team-$$"
  echo "  Spawning $TEAM_SIZE workers in tmux session: $SESSION"

  tmux new-session -d -s "$SESSION" -n "lead"
  # Lead worker gets the task
  tmux send-keys -t "$SESSION:lead" "cd $WORK_DIR && claude --agent heimdall $PERMISSION_FLAG --plugin-dir $PLUGIN_DIR" Enter

  # Spawn additional worker panes
  for i in $(seq 2 "$TEAM_SIZE"); do
    tmux split-window -t "$SESSION" -h
    tmux send-keys -t "$SESSION" "cd $WORK_DIR && claude --agent heimdall $PERMISSION_FLAG --plugin-dir $PLUGIN_DIR" Enter
    tmux select-layout -t "$SESSION" tiled
  done

  if [ -n "$TASK" ]; then
    sleep 2
    tmux send-keys -t "$SESSION:lead.0" "$TASK" Enter
  fi

  echo "  Attach: tmux attach -t $SESSION"
  echo "  Detach: Ctrl+B then D"
  exec tmux attach -t "$SESSION"
fi
TWIN

# The --team block of $SRC, run the way bin/heimdall reaches it: its own strict mode, WORK_DIR = the cwd, PLUGIN_DIR from the
# environment, the launcher's helpers stubbed (not under test), and no sleep.
cat > "$WORK/team-harness.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
WORK_DIR="$(pwd)"
PERMISSION_FLAG="--dangerously-skip-permissions"
ensure_node_path() { :; }; ensure_claude() { :; }; first_run_setup() { :; }; ensure_auth() { :; }
apply_heimdall_theme() { :; }; print_banner() { :; }; sleep() { :; }
start="$(grep -nF 'if [[ "${1:-}" == "--team" ]]; then' "$SRC" | head -1 | cut -d: -f1)"
[ -n "$start" ] || { echo "no --team block in $SRC" >&2; exit 99; }
eval "$(sed -n "${start},\$p" "$SRC" | sed '/^fi$/q')"
SH

# ── harness ──
clean() { rm -rf "$HOMEDIR" "$CWD" "$WORK/hh"; mkdir -p "$HOMEDIR" "$CWD"; : > "$GIT_LOG"; find "$WORK" -type f -iname 'pwned*' -delete 2>/dev/null; return 0; }
stray() { find "$WORK" -type f -iname 'pwned*' 2>/dev/null | sed "s|^$WORK/||" | sort | tr '\n' ' '; }   # whatever a payload left behind

make_ds_plugin() {   # DIR : a plugin tree whose bin/discover-skills is the real script
  mkdir -p "$1/bin/lib"
  cp "$DISCOVER" "$1/bin/discover-skills"; chmod +x "$1/bin/discover-skills"
  cp "$REPO/bin/lib/install-receipt.sh" "$1/bin/lib/install-receipt.sh"
  cp "$WORK/registry.json" "$1/skills-registry.json"
}
make_ds_plugin "$DSPLUG"

# run_ds ARGS... : bin/discover-skills out of the plugin tree $DSP (default $DSPLUG), in the throwaway HOME, cwd $CWD
run_ds() {
  ( cd "$CWD" && env -i PATH="$FAKEBIN:$PATH" HOME="$HOMEDIR" HEIMDALL_HOME="$WORK/hh" LC_ALL=C FAKE_GIT_LOG="$GIT_LOG" \
      "${DSP:-$DSPLUG}/bin/discover-skills" "$@" ) </dev/null >"$OUT" 2>"$ERR"
}

# run_ds_fn FUNC ARGS... : one function cut out of $SRC (default the real script), run under the script's own `set -eo pipefail`
run_ds_fn() {
  ( cd "$CWD" && env -i PATH="$FAKEBIN:$PATH" HOME="$HOMEDIR" LC_ALL=C REGISTRY="$DSPLUG/skills-registry.json" SRC="${SRC:-$DISCOVER}" \
      bash -c 'set -eo pipefail; fn="$1"; shift; eval "$(sed -n "/^${fn}()/,/^}/p" "$SRC")"; "$fn" "$@"' _ "$@" ) </dev/null >"$OUT" 2>"$ERR"
}

# ds_out LABEL WANT_RC WANT_STDOUT ARGS... : discover-skills ARGS exits WANT_RC, prints exactly WANT_STDOUT and a newline, leaves nothing behind
ds_out() {
  local label="$1" want_rc="$2" want="$3" rc s; shift 3
  run_ds "$@"; rc=$?
  printf '%s\n' "$want" > "$WORK/want.out"; s="$(stray)"
  if [ "$rc" -eq "$want_rc" ] && cmp -s "$WORK/want.out" "$OUT" && [ -z "$s" ]; then ok "$label"
  else bad "$label" "rc=$rc (want $want_rc) stray=[$s] out=[$(head -c 300 "$OUT" | tr '\n' '~')] err=[$(head -c 120 "$ERR" | tr '\n' ' ')]"; fi
}

# detect_case LABEL WANT ARGS... : `detect ARGS` exits 0, names exactly WANT ("a,b"; "" = "No skill gaps detected.") and leaves nothing behind
detect_case() {
  local label="$1" want="$2" rc got s good=0; shift 2
  clean; run_ds detect "$@"; rc=$?
  got="$(sed -n 's/^MISSING: \([^ ]*\) .*/\1/p' "$OUT" | tr '\n' ',' | sed 's/,$//')"
  s="$(stray)"
  if [ -z "$want" ]; then [ "$(cat "$OUT")" = "No skill gaps detected." ] && good=1
  else [ "$got" = "$want" ] && good=1; fi
  if [ "$rc" -eq 0 ] && [ "$good" = 1 ] && [ -z "$s" ]; then ok "$label"
  else bad "$label" "rc=$rc names=[$got] want=[$want] stray=[$s] out=[$(head -c 160 "$OUT" | tr '\n' '~')] err=[$(head -c 160 "$ERR" | tr '\n' ' ')]"; fi
}

Q="'"
TQ="$Q$Q$Q"
NL=$'\n'
SKILL_UI="MISSING: ui-ux-pro-max (owner/ui-ux-pro-max-skill) — UI work — pro${NL}  Install: discover-skills install ui-ux-pro-max"

echo "discover-skills-bin-injection"

# ╔═ A. discover-skills: normal use is unchanged ═══════════════════════════════════════════════════════════════════╗
echo "A. discover-skills: normal use prints what it always printed, byte for byte"
clean; ds_out "A1 detect: one skill, announced with its repo, an em dash twice" 0 "$SKILL_UI" detect "design a React dashboard with Tailwind"
clean; ds_out "A2 detect: two skills, in registry order" 0 "$SKILL_UI${NL}MISSING: godogen (owner/godogen) — Godot games${NL}  Install: discover-skills install godogen" \
  detect "Make a Landing Page and a GAME"
clean; ds_out "A3 detect: 'ui' is a word, not a substring (build, guild, fruit)" 0 "No skill gaps detected." detect "build the guild a fruit guide"
clean; mkdir -p "$HOMEDIR/.claude/skills/ui-ux-pro-max"
ds_out "A4 detect: an installed skill is not reported" 0 "MISSING: godogen (owner/godogen) — Godot games${NL}  Install: discover-skills install godogen" detect "react and godot"
clean; ds_out "A5 detect: several arguments are one prompt" 0 "$SKILL_UI" detect react dashboard "for me"
clean; ds_out "A6 detect: no argument is a usage error" 1 "Usage: discover-skills detect <prompt or description>" detect
clean; printf 'export const A = 1;\n' > "$CWD/app.tsx"
ds_out "A7 detect-file: a .tsx file is the design domain, its skills listed" 0 \
  "Domain detected: design (from app.tsx)${NL}${NL}Relevant skills:${NL}  ⚠ ui-ux-pro-max — UI work — pro${NL}    Install: discover-skills install ui-ux-pro-max" detect-file app.tsx
clean; printf 'export const A = 1;\n' > "$CWD/app.tsx"; mkdir -p "$HOMEDIR/.claude/skills/ui-ux-pro-max"
ds_out "A8 detect-file: an installed skill is marked, not offered" 0 \
  "Domain detected: design (from app.tsx)${NL}${NL}Relevant skills:${NL}  ✔ ui-ux-pro-max — UI work — pro" detect-file app.tsx
clean; printf 'flowchart TD\n  A --> B\n' > "$CWD/notes.txt"
ds_out "A9 detect-file: the domain can come from the content" 0 \
  "Domain detected: documentation (from notes.txt)${NL}${NL}Relevant skills:${NL}  ⚠ oh-my-mermaid — Diagrams${NL}    Install: discover-skills install oh-my-mermaid" detect-file notes.txt
clean; printf 'nothing to see\n' > "$CWD/plain.txt"; ds_out "A10 detect-file: no domain" 0 "No skill domain detected for plain.txt" detect-file plain.txt
GAPS="Skill gaps (not installed):${NL}"
for row in "ui-ux-pro-max|UI work — pro" "oh-my-mermaid|Diagrams" "claude-seo|SEO work" "godogen|Godot games"; do
  GAPS="$GAPS${NL}$(printf '  ⚠ %-25s %s' "${row%%|*}" "${row#*|}")${NL}    Install: discover-skills install ${row%%|*}"
done
clean; ds_out "A11 gaps: every uninstalled skill, padded to 25, and the count" 0 "$GAPS${NL}${NL}  4 skill(s) not installed." gaps
clean; for s in ui-ux-pro-max oh-my-mermaid claude-seo godogen; do mkdir -p "$HOMEDIR/.claude/skills/$s"; done
ds_out "A12 gaps: all installed" 0 "Skill gaps (not installed):${NL}${NL}  All registry skills installed!" gaps

clean; run_ds install ui-ux-pro-max; rc=$?
WANT_SKILL="$HOMEDIR/.claude/skills/ui-ux-pro-max"
printf '%s\n' "INSTALLING: ui-ux-pro-max from owner/ui-ux-pro-max-skill..." "OK: Installed ui-ux-pro-max to $WANT_SKILL" \
  "OK: Generated SKILL.md for Claude Code discovery" > "$WORK/want.out"
printf -- '---\nname: ui-ux-pro-max\ndescription: A test skill\n---\n\nSkill body line\n' > "$WORK/want.skill"
if [ "$rc" -eq 0 ] && cmp -s "$WORK/want.out" "$OUT" && cmp -s "$WORK/want.skill" "$WANT_SKILL/SKILL.md" \
   && [ "$(cat "$GIT_LOG")" = "git clone --depth 1 https://github.com/owner/ui-ux-pro-max-skill.git $WANT_SKILL" ] && [ -z "$(stray)" ]; then
  ok "A13 install NAME: the registry's repo is cloned, SKILL.md is generated from the cloned skill.json and CLAUDE.md"
else bad "A13 install ui-ux-pro-max" "rc=$rc out=[$(head -c 300 "$OUT" | tr '\n' '~')] git=[$(cat "$GIT_LOG")] skill.md=[$(head -c 200 "$WANT_SKILL/SKILL.md" 2>&1 | tr '\n' '~')]"; fi
run_ds install ui-ux-pro-max; rc=$?
[ "$rc" -eq 0 ] && [ "$(cat "$OUT")" = "ALREADY INSTALLED: ui-ux-pro-max at $WANT_SKILL" ] && ok "A14 install NAME: an installed skill is left alone" || bad "A14 install twice" "rc=$rc out=[$(cat "$OUT")]"
clean; ds_out "A15 install NAME: a name the registry does not know is an error" 1 "ERROR: Skill 'nosuch' not in registry. Use: discover-skills install owner/repo" install nosuch
clean; run_ds install owner/plain-skill; rc=$?
[ "$rc" -eq 0 ] && [ -f "$HOMEDIR/.claude/skills/plain-skill/SKILL.md" ] && grep -q '^name: plain-skill$' "$HOMEDIR/.claude/skills/plain-skill/SKILL.md" \
  && ok "A16 install owner/repo: the directory is named after the repo" || bad "A16 install owner/plain-skill" "rc=$rc out=[$(head -c 200 "$OUT" | tr '\n' '~')]"

# ╔═ B. hostile prompts ════════════════════════════════════════════════════════════════════════════════════════════╗
echo "B. discover-skills: a hostile prompt neither crashes it nor runs anything, and the keywords around it still match"
# LABEL @@ skills that must be named @@ the prompt, literally (@NL@ is a newline)
while IFS= read -r line; do
  [ -n "$line" ] || continue
  label="${line%% @@ *}"; rest="${line#* @@ }"; want="${rest%% @@ *}"; prompt="${rest#* @@ }"
  detect_case "B. $label" "$want" "${prompt//@NL@/$NL}"
done <<'TABLE'
''' then a keyword @@ ui-ux-pro-max @@ ''' react
a lone ''' @@  @@ '''
""" then a keyword @@ ui-ux-pro-max @@ """ react """
a prompt wrapped in single quotes @@ ui-ux-pro-max @@ 'build a react app'
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
unicode around the keywords @@ ui-ux-pro-max @@ 'réact' “dashboard” ✔ ‘’
TABLE
detect_case "B. the payload with an absolute path, around a keyword" "ui-ux-pro-max" \
  "react ${TQ} + str(__import__(${Q}os${Q}).system(${Q}touch $WORK/PWNED_ABS${Q})) + ${TQ} dashboard"

# ╔═ C. the registry path is data too ══════════════════════════════════════════════════════════════════════════════╗
echo "C. discover-skills: the registry path is data too"
HOSTILE_PLUGIN="$WORK/p'+__import__('os').system('touch PWNED_PLUGIN')+'x"
APOSTROPHE_PLUGIN="$WORK/o'brien's ''' \"plugin\""
make_ds_plugin "$HOSTILE_PLUGIN"; make_ds_plugin "$APOSTROPHE_PLUGIN"
for p in "$HOSTILE_PLUGIN" "$APOSTROPHE_PLUGIN"; do
  case "$p" in "$HOSTILE_PLUGIN") tag="a plugin directory named with a payload" ;; *) tag="a plugin directory with ' ''' and \" in its name" ;; esac
  DSP="$p"
  clean; ds_out "C. detect under $tag" 0 "$SKILL_UI" detect "build a react app"
  clean; ds_out "C. gaps under $tag" 0 "$GAPS${NL}${NL}  4 skill(s) not installed." gaps
  clean; printf 'x\n' > "$CWD/app.tsx"; run_ds detect-file app.tsx; rc=$?
  [ "$rc" -eq 0 ] && grep -q '^  ⚠ ui-ux-pro-max — UI work — pro$' "$OUT" && [ -z "$(stray)" ] && ok "C. detect-file under $tag" || bad "C. detect-file under $tag" "rc=$rc stray=[$(stray)] out=[$(head -c 200 "$OUT" | tr '\n' '~')]"
  clean; run_ds install ui-ux-pro-max; rc=$?
  [ "$rc" -eq 0 ] && [ -f "$HOMEDIR/.claude/skills/ui-ux-pro-max/SKILL.md" ] && [ -z "$(stray)" ] && ok "C. install under $tag" || bad "C. install under $tag" "rc=$rc stray=[$(stray)] out=[$(head -c 200 "$OUT" | tr '\n' '~')]"
done
DSP=""

# ╔═ D. the other sites ════════════════════════════════════════════════════════════════════════════════════════════╗
echo "D. discover-skills: a skill name, a skill directory, a skill domain and the working directory are data too"
clean; run_ds install "x' or __import__('os').system('touch PWNED_NAME') or 'y"; rc=$?
[ "$rc" -eq 1 ] && [ ! -s "$GIT_LOG" ] && [ -z "$(stray)" ] && grep -q "^ERROR: Skill 'x' or .* not in registry" "$OUT" \
  && ok "D1 install: a skill NAME holding quotes and a payload is just an unknown name -- not found, nothing cloned, nothing run" \
  || bad "D1 install with a hostile name" "rc=$rc git=[$(cat "$GIT_LOG")] stray=[$(stray)] out=[$(head -c 160 "$OUT" | tr '\n' '~')]"
clean; EVIL="x'+__import__('os').system('touch PWNED_SKILL')+'x"
run_ds install "owner/$EVIL"; rc=$?
if [ "$rc" -eq 0 ] && [ -z "$(stray)" ] && grep -q '^description: A test skill$' "$HOMEDIR/.claude/skills/$EVIL/SKILL.md" 2>/dev/null; then
  ok "D2 install owner/REPO: a directory named with a payload still gets its SKILL.md from the cloned skill.json, nothing run"
else bad "D2 install owner/<payload>" "rc=$rc stray=[$(stray)] out=[$(head -c 200 "$OUT" | tr '\n' '~')] skill.md=[$(head -c 120 "$HOMEDIR/.claude/skills/$EVIL/SKILL.md" 2>&1 | tr '\n' '~')]"; fi
clean; run_ds_fn find_skills_for_domain "x' or __import__('os').system('touch PWNED_DOMAIN') or 'y"; rc=$?
[ "$rc" -eq 0 ] && [ ! -s "$OUT" ] && [ -z "$(stray)" ] && ok "D3 find_skills_for_domain: a domain holding quotes and a payload matches nothing and runs nothing" \
  || bad "D3 find_skills_for_domain with a hostile domain" "rc=$rc stray=[$(stray)] out=[$(head -c 160 "$OUT" | tr '\n' '~')]"
clean; run_ds_fn find_skills_for_domain design; rc=$?
[ "$rc" -eq 0 ] && [ "$(cat "$OUT")" = "ui-ux-pro-max|owner/ui-ux-pro-max-skill|NOT INSTALLED|UI work — pro" ] \
  && ok "D4 find_skills_for_domain: a real domain still lists its skills" || bad "D4 find_skills_for_domain design" "rc=$rc out=[$(cat "$OUT")]"

# a project that ships a json.py: the working directory must never be on sys.path of a discover-skills program
planted_json() { printf 'open("PWNED_JSON", "w").close()\nraise ImportError("the planted json.py was imported")\n' > "$CWD/json.py"; }
clean; planted_json; printf 'x\n' > "$CWD/app.tsx"
run_ds detect "design a React dashboard"; rc1=$?; c1="$(cat "$OUT")"
run_ds gaps; rc2=$?
run_ds detect-file app.tsx; rc3=$?
run_ds install ui-ux-pro-max; rc4=$?
if [ "$rc1$rc2$rc3$rc4" = "0000" ] && [ "$c1" = "$SKILL_UI" ] && [ -z "$(stray)" ] && [ -f "$HOMEDIR/.claude/skills/ui-ux-pro-max/SKILL.md" ]; then
  ok "D5 a json.py planted in the working directory is imported by none of detect, gaps, detect-file, install"
else bad "D5 a planted json.py was imported (or broke discover-skills)" "rc=$rc1/$rc2/$rc3/$rc4 stray=[$(stray)] detect=[$c1]"; fi

# ╔═ E. session-fork ═══════════════════════════════════════════════════════════════════════════════════════════════╗
echo "E. session-fork: tasks reach hmd-exec verbatim, nothing is run, and the working directory's json.py is not imported"
clean_fork() { rm -rf "$FORKRES" "$FORKLOG"; mkdir -p "$FORKLOG"; }
# run_fork ARGS... : the copy of bin/session-fork in the fixture, cwd = the project the user is in ($CWD)
run_fork() {
  ( cd "$CWD" && env -i PATH="$PATH" HOME="$HOMEDIR" LC_ALL=C HEIMDALL_FORK_DIR="$FORKRES" HEIMDALL_WORK_DIR="$CWD" HEIMDALL_MODEL=test-model \
      FORK_LOG="$FORKLOG" "$FORKPLUG/bin/session-fork" "$@" ) </dev/null >"$OUT" 2>"$ERR"
}
norm_out() { sed 's/pid=[0-9]*/pid=N/' "$OUT"; }
# has_call ARGS... : some recorded hmd-exec call was made with exactly these arguments
has_call() {
  local f
  printf '%s\0' "$@" > "$WORK/want.argv"
  for f in "$FORKLOG"/*.argv; do [ -f "$f" ] && cmp -s "$f" "$WORK/want.argv" && return 0; done
  return 1
}
n_calls() { find "$FORKLOG" -type f -name '*.argv' 2>/dev/null | wc -l | tr -d ' '; }

WAVE='[{"id": "w1", "prompt": "hello world"}, {"id": "w2", "prompt": "second task", "role": "hmd:coder"}]'
WANT_WAVE_OUT="$(printf '%s\n' "wave: 2 tasks, max_parallel=10" "forked: w1 (pid=N, model=test-model)" "forked: w2 (pid=N, model=test-model)" \
  "wave: waiting for all tasks..." "wave: complete")"
clean; clean_fork; run_fork wave "$WAVE"; rc=$?
if [ "$rc" -eq 0 ] && [ "$(norm_out)" = "$WANT_WAVE_OUT" ] && [ "$(n_calls)" = 2 ] \
   && has_call run -p "hello world" --model test-model --output-format text \
   && has_call --role hmd:coder run -p "second task" --model test-model --output-format text \
   && [ "$(cat "$FORKRES/outputs/w1.txt")" = "FAKE-OK" ] && [ "$(cat "$FORKRES/status/w2")" = "done" ]; then
  ok "E1 wave: the same banner, the same two hmd-exec calls (one with --role), the same outputs and status files"
else bad "E1 wave" "rc=$rc out=[$(norm_out | tr '\n' '~')] calls=$(n_calls) err=[$(head -c 160 "$ERR" | tr '\n' ' ')]"; fi

RUN='[[{"id": "a", "prompt": "first"}], [{"id": "b", "prompt": "second", "depends": ["a"]}]]'
clean; clean_fork; run_fork run "$RUN"; rc=$?
printf '%s\n' "run: 2 wave(s)" "run: starting wave 0" "forked: a (pid=N, model=test-model)" "run: waiting for wave 0..." "run: wave 0 complete" \
  "run: starting wave 1" "forked: b (pid=N, model=test-model)" "run: waiting for wave 1..." "run: wave 1 complete" "run: all waves complete" > "$WORK/want.out"
WANT_B="$(printf 'Context from prior tasks:\n\n--- Result from a ---\nFAKE-OK\n---\n\n\nTask: second')"
if [ "$rc" -eq 0 ] && [ "$(norm_out)" = "$(cat "$WORK/want.out")" ] && has_call run -p "first" --model test-model --output-format text \
   && has_call run -p "$WANT_B" --model test-model --output-format text; then
  ok "E2 run: two waves, and the second task is handed the first one's result as context, exactly as before"
else bad "E2 run" "rc=$rc out=[$(norm_out | tr '\n' '~')] calls=$(n_calls)"; fi

# hostile ids, roles and prompts, one wave: every task reaches hmd-exec exactly, nothing runs
HOSTILE_WAVE="$(python3 -I - <<'PY'
import json
payloads = [
    "''' + __import__('os').system('touch PWNED') + '''",
    'x""" ; import os ; os.system("touch PWNED") ; y="""',
    "react $(touch PWNED_SUBST) `touch PWNED_TICK` dashboard",
    "a trailing backslash \\",
    "format {0} %s %(x)s {{}} ${HOME} \\N{DIGIT ONE} \\x41",
    "unicode ✔ é — “quoted” ‘’",
    "-c --help -I",
]
tasks = [{"id": "h%d" % i, "prompt": p} for i, p in enumerate(payloads)]
tasks.append({"id": "role'; touch PWNED_ROLE; '", "role": "r$(touch PWNED_ROLE2)", "prompt": "carrier"})
print(json.dumps(tasks))
PY
)"
clean; clean_fork; run_fork wave "$HOSTILE_WAVE"; rc=$?
missing=""
while IFS= read -r p; do
  has_call run -p "$p" --model test-model --output-format text || missing="${missing}[$p]"
done <<'PROMPTS'
''' + __import__('os').system('touch PWNED') + '''
x""" ; import os ; os.system("touch PWNED") ; y="""
react $(touch PWNED_SUBST) `touch PWNED_TICK` dashboard
a trailing backslash \
format {0} %s %(x)s {{}} ${HOME} \N{DIGIT ONE} \x41
unicode ✔ é — “quoted” ‘’
-c --help -I
PROMPTS
has_call --role 'r$(touch PWNED_ROLE2)' run -p carrier --model test-model --output-format text || missing="${missing}[role carrier]"
if [ "$rc" -eq 0 ] && [ -z "$missing" ] && [ "$(n_calls)" = 8 ] && [ -z "$(stray)" ]; then
  ok "E3 wave: 8 hostile tasks (payloads, \$( ), a trailing backslash, braces, unicode, option words, a hostile id and role) arrive verbatim, nothing runs"
else bad "E3 hostile wave" "rc=$rc calls=$(n_calls) missing=$missing stray=[$(stray)] err=[$(head -c 200 "$ERR" | tr '\n' ' ')]"; fi

# newlines in a prompt: nothing runs and nothing crashes (the line-oriented hand-off from python to bash is not what this suite changes)
NLWAVE="$(python3 -I -c 'import json, sys; print(json.dumps([{"id": "nl", "prompt": sys.argv[1]}]))' $'first line\n$(touch PWNED_NL)\n\'\'\'\nimport os; os.system("touch PWNED_NL2")\n\'\'\'')"
clean; clean_fork; run_fork wave "$NLWAVE"; rc=$?
[ "$rc" -eq 0 ] && [ -z "$(stray)" ] && has_call run -p "first line" --model test-model --output-format text \
  && ok "E4 wave: a prompt with newlines, \$( ) and ''' runs nothing and does not crash session-fork" \
  || bad "E4 newline prompt" "rc=$rc stray=[$(stray)] calls=$(n_calls) err=[$(head -c 200 "$ERR" | tr '\n' ' ')]"

# a project that ships a json.py: session-fork runs from the project's directory, so it must not import it
clean; clean_fork; planted_json; run_fork wave "$WAVE"; rc1=$?; o1="$(norm_out)"; c1="$(n_calls)"
clean_fork; run_fork run "$RUN"; rc2=$?; c2="$(n_calls)"
if [ "$rc1" -eq 0 ] && [ "$rc2" -eq 0 ] && [ -z "$(stray)" ] && [ "$o1" = "$WANT_WAVE_OUT" ] && [ "$c1" = 2 ] && [ "$c2" = 2 ]; then
  ok "E5 a json.py planted in the project directory is imported by neither wave nor run, and both still fork their tasks"
else bad "E5 a planted json.py was imported (or broke session-fork)" "rc=$rc1/$rc2 stray=[$(stray)] wave=[$o1] calls=$c1/$c2"; fi

# ╔═ F. heimdall --team ════════════════════════════════════════════════════════════════════════════════════════════╗
echo "F. heimdall --team: a hostile directory or task runs nothing and reaches claude as exact argv; nothing of it is typed"
run_team() {   # SRC CWD PLUGIN ARGS... : the --team block of SRC, cwd CWD, in the sandbox (PANE_SHELL, PANE_PATH choose the pane shell and its PATH)
  local src="$1" cwd="$2" plugin="$3"; shift 3
  rm -rf "$TMUXD" "$CLAUDED"; mkdir -p "$TMUXD" "$CLAUDED"
  ( cd "$cwd" && env -i PATH="$FAKEBIN:$PATH" HOME="$HOMEDIR" LC_ALL=C SRC="$src" PLUGIN_DIR="$plugin" FAKE_TMUX_DIR="$TMUXD" \
      FAKE_CLAUDE_DIR="$CLAUDED" FAKE_PANE_SHELL="${PANE_SHELL:-sh}" ${PANE_PATH:+FAKE_PANE_PATH="$PANE_PATH"} \
      bash "$WORK/team-harness.sh" --team "$@" ) </dev/null >"$OUT" 2>"$ERR"
}
phys() { ( cd "$1" && pwd -P ); }
typed_all() { LC_ALL=C tr -d '\0' < "$TMUXD/typed.nul"; }
typed_ctl() { LC_ALL=C tr -d '\0' < "$TMUXD/typed.nul" | LC_ALL=C tr -cd '[:cntrl:]' | wc -c | tr -d ' '; }

# typed_clean : nothing of the TASK was typed (its marker is absent) and nothing typed is a control character
typed_clean() {
  local t; t="$(typed_all)"
  [ "$(typed_ctl)" = 0 ] || return 1
  case "$t" in *ZZTASKZZ*) return 1 ;; esac
  return 0
}

# check_team LABEL RC TASK PLUGIN CWD : after run_team of the fixed launcher with a 2-pane team: exit 0, nothing left behind, the lead got
# the task after `--` and the worker none, both in CWD, and nothing of the data was typed
check_team() {
  local label="$1" rc="$2" task="$3" plugin="$4" cwd="$5" want_task s why="" tf
  want_task="$(printf '%s' "$task")"      # a command substitution drops trailing newlines: so does the pane's shell
  s="$(stray)"
  [ "$rc" -eq 0 ] || why="$why rc=$rc;"
  [ -z "$s" ] || why="$why stray=[$s];"
  [ "$(cat "$CLAUDED/n" 2>/dev/null)" = 2 ] || why="$why claude calls=$(cat "$CLAUDED/n" 2>/dev/null || echo 0);"
  if [ -n "$task" ]; then printf '%s\0' --agent heimdall --dangerously-skip-permissions --plugin-dir "$plugin" -- "$want_task" > "$WORK/want.lead"
  else printf '%s\0' --agent heimdall --dangerously-skip-permissions --plugin-dir "$plugin" > "$WORK/want.lead"; fi
  printf '%s\0' --agent heimdall --dangerously-skip-permissions --plugin-dir "$plugin" > "$WORK/want.worker"
  cmp -s "$WORK/want.lead" "$CLAUDED/1.argv" 2>/dev/null || why="$why lead argv=[$(tr '\0' '~' < "$CLAUDED/1.argv" 2>/dev/null | head -c 200)];"
  cmp -s "$WORK/want.worker" "$CLAUDED/2.argv" 2>/dev/null || why="$why worker argv=[$(tr '\0' '~' < "$CLAUDED/2.argv" 2>/dev/null | head -c 200)];"
  [ "$(cat "$CLAUDED/1.cwd" 2>/dev/null)" = "$(phys "$cwd")" ] && [ "$(cat "$CLAUDED/2.cwd" 2>/dev/null)" = "$(phys "$cwd")" ] || why="$why cwd=[$(cat "$CLAUDED/1.cwd" 2>/dev/null)];"
  typed_clean || why="$why typed=[$(typed_all | head -c 200)] ctl=$(typed_ctl);"
  tf="$(tr '\0' '\n' < "$TMUXD/exec.nul" | grep -o '/tmp/heimdall-team-[A-Za-z0-9]*' | head -1)"
  [ -z "$tf" ] || [ ! -e "$tf" ] || why="$why task file $tf was left behind;"
  [ ! -e "$TMUXD/errors.log" ] || why="$why tmux: $(cat "$TMUXD/errors.log");"
  if [ -z "$why" ]; then ok "$label"; else bad "$label" "$why"; fi
}

TEAMDIR="$WORK/teamdir"; TEAMPLUG="$WORK/team-plugin"
clean; mkdir -p "$TEAMDIR" "$TEAMPLUG"
run_team "$LAUNCHER" "$TEAMDIR" "$TEAMPLUG" 2 "build a todo app with tests"; rc=$?
check_team "F1 a normal 2-pane team: lead gets the task as its prompt, worker none, both start in the working directory" "$rc" "build a todo app with tests" "$TEAMPLUG" "$TEAMDIR"
run_team "$LAUNCHER" "$TEAMDIR" "$TEAMPLUG" 2; rc=$?
check_team "F2 no task: nothing is passed after the plugin directory" "$rc" "" "$TEAMPLUG" "$TEAMDIR"
run_team "$LAUNCHER" "$TEAMDIR" "$TEAMPLUG" 2 "   "; rc=$?
check_team "F3 a task of only blanks is no task" "$rc" "" "$TEAMPLUG" "$TEAMDIR"
run_team "$LAUNCHER" "$TEAMDIR" "$TEAMPLUG" 4 "four panes"; rc=$?
[ "$rc" -eq 0 ] && [ "$(cat "$CLAUDED/n" 2>/dev/null)" = 4 ] && [ ! -e "$TMUXD/errors.log" ] && ok "F4 a 4-pane team starts four claudes" \
  || bad "F4 a 4-pane team" "rc=$rc claude calls=$(cat "$CLAUDED/n" 2>/dev/null)"

# the pre-fix block on the same normal input: the worker's argv is the same, the lead's is the same up to the task, which used to be typed later
run_team "$WORK/pre-fix-team.sh" "$TEAMDIR" "$TEAMPLUG" 2 "build a todo app with tests"; rc=$?
cp "$CLAUDED/1.argv" "$WORK/pre.lead"; cp "$CLAUDED/2.argv" "$WORK/pre.worker"
printf '%s\0' --agent heimdall --dangerously-skip-permissions --plugin-dir "$TEAMPLUG" > "$WORK/want.pre"
if [ "$rc" -eq 0 ] && cmp -s "$WORK/pre.lead" "$WORK/want.pre" && cmp -s "$WORK/pre.worker" "$WORK/want.pre"; then
  ok "F5 the pre-fix launcher started claude with the same arguments (its task was typed in two seconds later), so F1 changed only how the task arrives"
else bad "F5 the pre-fix reference run" "rc=$rc lead=[$(tr '\0' '~' < "$WORK/pre.lead")]"; fi

# hostile TASKs: one fixed run each, sh as the pane shell, claude present
TASK_LONG="ZZTASKZZ $(head -c 6000 /dev/zero | tr '\0' 'x') end"
while IFS= read -r line; do
  [ -n "$line" ] || continue
  label="${line%% @@ *}"; task="${line#* @@ }"; task="${task//@NL@/$NL}"; task="${task//@ESC@/$'\033'}"; task="${task//@KU@/$'\025'}"; task="${task//@KC@/$'\003'}"; task="${task//@DEL@/$'\177'}"
  clean; mkdir -p "$TEAMDIR"
  run_team "$LAUNCHER" "$TEAMDIR" "$TEAMPLUG" 2 "$task"; rc=$?
  check_team "F6 task: $label" "$rc" "$task" "$TEAMPLUG" "$TEAMDIR"
done <<'TABLE'
a quote and a command @@ x'; touch PWNED_T1; echo 'ZZTASKZZ
the shell's metacharacters @@ ZZTASKZZ $(touch PWNED_T2) `touch PWNED_T2b` "; touch PWNED_T2c; " | & > < \ ! # ~ * ?
newlines, a command on its own line, an unbalanced quote @@ ZZTASKZZ line one@NL@touch PWNED_T3@NL@'; touch PWNED_T3b; '
an option-looking task is the prompt @@ --dangerously-skip-permissions ZZTASKZZ
the option terminator itself @@ --
a lone dash @@ -
a tmux key name: Enter @@ Enter
a tmux key name: C-c @@ C-c
^U (kill line) and a balanced quote @@ ZZTASKZZ@KU@touch PWNED_T4; echo '
^C and DEL @@ ZZTASKZZ@KC@touch PWNED_T5@DEL@@DEL@;@KC@
ESC sequences @@ ZZTASKZZ@ESC@[200~touch PWNED_T6@ESC@[201~
trailing newlines @@ ZZTASKZZ line@NL@@NL@
unicode @@ ZZTASKZZ ✔ é — “quoted” ‘’ 日本語 🚀
TABLE
clean; mkdir -p "$TEAMDIR"
run_team "$LAUNCHER" "$TEAMDIR" "$TEAMPLUG" 2 "$TASK_LONG"; rc=$?
check_team "F6 task: 6000 characters (no length is typed)" "$rc" "$TASK_LONG" "$TEAMPLUG" "$TEAMDIR"
clean; mkdir -p "$TEAMDIR"
run_team "$LAUNCHER" "$TEAMDIR" "$TEAMPLUG" 2 "multi" "word" "task ZZTASKZZ; touch PWNED_T7"; rc=$?
check_team "F6 task: several arguments are one task, joined with spaces" "$rc" "multi word task ZZTASKZZ; touch PWNED_T7" "$TEAMPLUG" "$TEAMDIR"

# hostile WORKING directories and PLUGIN directories (the task is plain)
HOSTILE_DIRS="$WORK/dirs"; mkdir -p "$HOSTILE_DIRS"
D_QUOTE="$HOSTILE_DIRS/w'; touch PWNED_W1; 'x"
D_SUBST="$HOSTILE_DIRS/w \$(touch PWNED_W2) \`touch PWNED_W2b\` \"q\" \\ & | > < #(touch PWNED_W2c) #{x} ~ *"
D_SPACE="$HOSTILE_DIRS/a b  c — ✔ é"
D_TRIPLE="$HOSTILE_DIRS/t''' \"\"\" x"
D_SEMI="$HOSTILE_DIRS/w;touch PWNED_W9;x"
for d in "$D_QUOTE" "$D_SUBST" "$D_SPACE" "$D_TRIPLE" "$D_SEMI"; do mkdir -p "$d"; done
for d in "$D_QUOTE" "$D_SUBST" "$D_SPACE" "$D_TRIPLE" "$D_SEMI"; do
  clean; mkdir -p "$TEAMDIR"
  run_team "$LAUNCHER" "$d" "$TEAMPLUG" 2 "plain task"; rc=$?
  check_team "F7 working directory: ${d#"$HOSTILE_DIRS/"}" "$rc" "plain task" "$TEAMPLUG" "$d"
  clean
  run_team "$LAUNCHER" "$TEAMDIR" "$d" 2 "plain task"; rc=$?
  check_team "F8 plugin directory: ${d#"$HOSTILE_DIRS/"}" "$rc" "plain task" "$d" "$TEAMDIR"
done

# control characters in a directory name are refused (they would reach the pane's line editor), before anything is started
for ctl in $'\025' $'\003' $'\033' $'\t' $'\n' $'\177'; do
  d="$HOSTILE_DIRS/c${ctl}d; touch PWNED_CTL"; mkdir -p "$d"
  clean; run_team "$LAUNCHER" "$d" "$TEAMPLUG" 2 "plain task"; rc=$?; r1="$rc"; s1="$(stray)"; n1="$(cat "$CLAUDED/n" 2>/dev/null || echo 0)"; t1="$(wc -c < "$TMUXD/typed.nul" 2>/dev/null | tr -d ' ')"
  run_team "$LAUNCHER" "$TEAMDIR" "$d" 2 "plain task"; rc=$?
  if [ "$r1" -ne 0 ] && [ "$rc" -ne 0 ] && [ -z "$s1" ] && [ "$n1" = 0 ] && [ "${t1:-0}" = 0 ] && [ "$(cat "$CLAUDED/n" 2>/dev/null || echo 0)" = 0 ] && grep -q 'control character' "$ERR"; then
    ok "F9 a working or plugin directory with byte $(printf '%s' "$ctl" | od -An -tx1 | tr -d ' \n') in its name is refused: exit $r1/$rc, nothing typed, nothing started"
  else bad "F9 a directory with byte $(printf '%s' "$ctl" | od -An -tx1 | tr -d ' \n') in its name" "rc=$r1/$rc stray=[$s1] claude=$n1 typed=$t1 err=[$(head -c 160 "$ERR" | tr '\n' ' ')]"; fi
done

# the same payloads under other pane shells, and with a claude that fails to start (the shell regains control, the case that used to run the typed task)
SHELLS="bash"; command -v zsh >/dev/null 2>&1 && SHELLS="bash zsh"
HOSTILE_TASK="x'; touch PWNED_S1; echo \"ZZTASKZZ \$(touch PWNED_S2) \`touch PWNED_S3\`${NL}touch PWNED_S4${NL}${TQ}${NL}"
for sh_name in $SHELLS; do
  PANE_SHELL="$sh_name"
  clean; mkdir -p "$TEAMDIR"; run_team "$LAUNCHER" "$TEAMDIR" "$TEAMPLUG" 2 "$HOSTILE_TASK"; rc=$?
  check_team "F10 pane shell $sh_name: a hostile task reaches claude exactly and runs nothing" "$rc" "$HOSTILE_TASK" "$TEAMPLUG" "$TEAMDIR"
  clean; run_team "$LAUNCHER" "$D_QUOTE" "$D_SUBST" 2 "plain task"; rc=$?
  check_team "F10 pane shell $sh_name: hostile working AND plugin directories" "$rc" "plain task" "$D_SUBST" "$D_QUOTE"
done
PANE_SHELL=""
PANE_PATH="/usr/bin:/bin"
for sh_name in sh bash; do
  PANE_SHELL="$sh_name"
  clean; mkdir -p "$TEAMDIR"; run_team "$LAUNCHER" "$TEAMDIR" "$TEAMPLUG" 2 "$HOSTILE_TASK"; rc=$?
  if [ "$rc" -eq 0 ] && [ -z "$(stray)" ] && [ "$(cat "$CLAUDED/n" 2>/dev/null || echo 0)" = 0 ] && typed_clean; then
    ok "F11 pane shell $sh_name, claude not found: the hostile task is not run by the shell that regained control"
  else bad "F11 pane shell $sh_name without claude" "rc=$rc stray=[$(stray)] typed=[$(typed_all | head -c 200)]"; fi
done
PANE_PATH=""; PANE_SHELL=""

# the real launcher, copied into a plugin tree whose name is hostile, with its whole preamble (ensure_claude, auth, first-run setup, banner)
LPLUG="$WORK/lp'; touch PWNED_LAUNCHER; 'x"
mkdir -p "$LPLUG/bin/lib" "$WORK/hh-real"
cp "$LAUNCHER" "$LPLUG/bin/heimdall"; chmod +x "$LPLUG/bin/heimdall"
for lib in select.sh real-home.sh install-receipt.sh; do [ -f "$REPO/bin/lib/$lib" ] && cp "$REPO/bin/lib/$lib" "$LPLUG/bin/lib/$lib"; done
touch "$WORK/hh-real/setup-done"
clean; mkdir -p "$TEAMDIR"; printf '{"oauthAccount":{"accountUuid":"u-1"}}' > "$HOMEDIR/.claude.json"
rm -rf "$TMUXD" "$CLAUDED"; mkdir -p "$TMUXD" "$CLAUDED"
( cd "$TEAMDIR" && env -i PATH="$FAKEBIN:$PATH" HOME="$HOMEDIR" TERM=dumb LC_ALL=C HEIMDALL_HOME="$WORK/hh-real" HEIMDALL_NO_INTRO=1 HEIMDALL_NO_UPDATE_CHECK=1 \
    FAKE_TMUX_DIR="$TMUXD" FAKE_CLAUDE_DIR="$CLAUDED" FAKE_PANE_SHELL=sh "$LPLUG/bin/heimdall" --team 2 "fix the login bug; touch PWNED_REAL" ) </dev/null >"$OUT" 2>"$ERR"; rc=$?
printf '%s\0' --agent heimdall --dangerously-skip-permissions --plugin-dir "$(phys "$LPLUG")" -- "fix the login bug; touch PWNED_REAL" > "$WORK/want.lead"
printf '%s\0' --agent heimdall --dangerously-skip-permissions --plugin-dir "$(phys "$LPLUG")" > "$WORK/want.worker"
if [ "$rc" -eq 0 ] && cmp -s "$WORK/want.lead" "$CLAUDED/1.argv" && cmp -s "$WORK/want.worker" "$CLAUDED/2.argv" && [ -z "$(stray)" ] \
   && [ "$(cat "$CLAUDED/1.cwd")" = "$(phys "$TEAMDIR")" ] && ! grep -q -- '--model' "$CLAUDED/1.argv"; then
  ok "F12 the real bin/heimdall, whole preamble included, in a plugin directory named with a payload: the same two claude commands"
else bad "F12 the real launcher --team" "rc=$rc stray=[$(stray)] lead=[$(tr '\0' '~' < "$CLAUDED/1.argv" 2>/dev/null | head -c 240)] err=[$(head -c 200 "$ERR" | tr '\n' ' ')]"; fi

# ╔═ G. the whole files ════════════════════════════════════════════════════════════════════════════════════════════╗
echo "G. no python in bin/discover-skills or bin/session-fork is built by splicing shell text into its source; all of it runs under -I"
scan_py() {
  python3 -I - "$1" <<'PY'
import re, sys

lines = open(sys.argv[1], encoding="utf-8").read().split("\n")
src = "\n".join("" if ln.lstrip().startswith("#") else ln for ln in lines)   # comments talk ABOUT forms; they are not forms
found = []
def where(pos):
    return src.count("\n", 0, pos) + 1
# python3 -c "...": bash expands a double-quoted program first, so a $ or a backtick in it is a shell value spliced into the source
for m in re.finditer(r'\bpython3?(?:[ \t]+-[A-Za-z]+)*[ \t]+-c[ \t]+"', src):
    j = m.end()
    while j < len(src) and src[j] != '"':
        j += 2 if src[j] == "\\" else 1
    body = re.sub(r"\\.", "", src[m.end():j], flags=re.S)
    if "$" in body or "`" in body:
        found.append("line %d: python3 -c \"...\" splices a shell expansion into program text" % where(m.start()))
# a heredoc into python whose delimiter is not quoted is expanded the same way
for m in re.finditer(r"\bpython3?\b[^\n]*<<-?[ \t]*[A-Za-z_]", src):
    found.append("line %d: heredoc into python3 with an unquoted delimiter" % where(m.start()))
# a python3 COMMAND (after a pipe, ;, &, (, {, $( or at the start of a line) must run isolated: the working directory is any project
for m in re.finditer(r"(?:^|[|;&(`{]|\$\()[ \t]*python3?\b(?![ \t]+-I\b)", src, re.M):
    found.append("line %d: python3 without -I (a json.py in the working directory would be imported)" % where(m.start()))
print("\n".join(found))
PY
}
printf 'x=$(python3 -c "import os; print(\\"$HOME\\")")\npython3 - "$f" <<EOF\nEOF\n  python3 -c "print(1)"\n' > "$WORK/known-bad.sh"
BADSCAN="$(scan_py "$WORK/known-bad.sh" 2>&1)"
[ "$(printf '%s\n' "$BADSCAN" | grep -c '^line')" = 5 ] && ok "G0 the scanner flags a known-bad snippet (a spliced \$HOME, an unquoted heredoc, three python3 without -I)" \
  || bad "G0 the scanner missed a known-bad snippet" "$(printf '%s' "$BADSCAN" | tr '\n' '~')"
for f in "$DISCOVER" "$FORK"; do
  SCAN="$(scan_py "$f" 2>&1)"
  if [ -z "$SCAN" ]; then ok "G1 $(basename "$f"): no spliced python source, no unquoted heredoc, every python3 is -I"
  else bad "G1 $(basename "$f"): python source built from shell text, or not isolated" "$(printf '%s' "$SCAN" | tr '\n' '~')"; fi
done

# ╔═ V. control: the pre-fix shapes ARE vulnerable ═════════════════════════════════════════════════════════════════╗
echo "V. control: the same payloads hurt the pre-fix shapes, so the clean runs above mean something"
SRC="$WORK/pre-fix-detect.sh"
clean; run_ds_fn cmd_detect "react ${TQ} + str(__import__(${Q}os${Q}).system(${Q}touch PWNED${Q})) + ${TQ} dashboard"
[ -n "$(stray)" ] && ok "V1 pre-fix cmd_detect: the payload runs -- it left $(stray)behind (the prompt is lowercased first)" || bad "V1 pre-fix cmd_detect: the payload did not run, so B proves nothing"
clean; run_ds_fn cmd_detect "$TQ"; rc=$?
[ "$rc" -ne 0 ] && ok "V2 pre-fix cmd_detect: a prompt of ''' aborts the script (rc=$rc)" || bad "V2 pre-fix cmd_detect: ''' did not abort" "rc=$rc"
SRC=""
clean; planted_json; ( cd "$CWD" && python3 -c 'import json' ) >/dev/null 2>&1
[ -n "$(stray)" ] && ok "V3 python3 -c imports the working directory's json.py (it left $(stray)behind)" || bad "V3 python3 -c did not import the planted json.py, so D5 and E5 prove nothing"
clean; planted_json; ( cd "$CWD" && python3 -I -c 'import json' ) >/dev/null 2>&1
[ -z "$(stray)" ] && ok "V4 python3 -I -c does not" || bad "V4 python3 -I -c imported the planted json.py" "$(stray)"
clean; mkdir -p "$TEAMDIR"
run_team "$WORK/pre-fix-team.sh" "$TEAMDIR" "$TEAMPLUG" 2 "x; touch PWNED_V5 ZZTASKZZ"; rc=$?
[ -n "$(stray)" ] && ! typed_clean && ok "V5 pre-fix --team: a task typed into a pane whose claude is gone runs (it left $(stray)behind) and is in the typed text" \
  || bad "V5 pre-fix --team: the task did not run, so F proves nothing" "rc=$rc stray=[$(stray)] typed=[$(typed_all | head -c 120)]"
clean; mkdir -p "$D_SEMI"
run_team "$WORK/pre-fix-team.sh" "$D_SEMI" "$TEAMPLUG" 2 ""; rc=$?
[ -n "$(stray)" ] && ok "V6 pre-fix --team: a working directory named with a command runs it (it left $(stray)behind)" || bad "V6 pre-fix --team: the directory name did not run" "rc=$rc"
clean; mkdir -p "$TEAMDIR"
run_team "$WORK/pre-fix-team.sh" "$TEAMDIR" "$TEAMPLUG" 2 "plain task"; enters_plain="$(tr '\0' '\n' < "$TMUXD/typed.nul" | grep -c '^<Enter>')"
run_team "$WORK/pre-fix-team.sh" "$TEAMDIR" "$TEAMPLUG" 2 "Enter"; enters_key="$(tr '\0' '\n' < "$TMUXD/typed.nul" | grep -c '^<Enter>')"
[ "$enters_plain" = 3 ] && [ "$enters_key" = 4 ] && ok "V7 pre-fix --team: the task 'Enter' was sent as the Enter KEY ($enters_key <Enter> against $enters_plain for a plain task)" \
  || bad "V7 pre-fix --team: 'Enter' was not read as a key name" "enters plain=$enters_plain key=$enters_key"

echo "--------------------------------------------------------------------"
printf 'discover-skills-bin-injection: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
