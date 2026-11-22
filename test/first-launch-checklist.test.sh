#!/usr/bin/env bash
# test/first-launch-checklist.test.sh -- a fresh hmd SHOWS its skills on the first launch, to be added by the person; nothing is installed unasked.
#
#   bash test/first-launch-checklist.test.sh
#
# The real launcher (`hmd --setup` runs first_run_setup exactly as a first launch does) from a LEAN clone of this checkout (bin/lib/lean_sparse.sh apply lean:
# the five on-demand bundled skills are really off the disk), in a HOME of its own, with the recording fake of the coding agent's CLI of test/use-cases/lib.sh.
# Nothing of the operator's machine is read or written. A person at a terminal is a python pty driver: it waits for the question, then types the answer.
#
#   A. numbers (a recommended plugin, a bundled skill the lean clone left out, and superpowers): ONE checklist lists every recommended and every left-out entry with
#      its why and never names the coding agent; exactly the picks are added through the consented install path (their lock rows, the bundled skill back on disk),
#      the first-run set follows superpowers as before, everything else is not touched
#   B. Enter: nothing is added, superpowers is on the lock as suggested, the way back (`hmd skills suggest`) is said
#   C. n: nothing is added, every listed skill is declined (held back from `hmd skills suggest`, which says so)
#   D. no terminal: no question (it would hang), nothing added, one line points to `hmd skills suggest`, the rows are the ones the launcher always wrote
#   E. setup already done (the marker): nothing is shown again
#   F. consent auto (an install that predates the consent model): no checklist, the first-run set installs as before
#   G. `hmd skills suggest` lists the bundled skills a lean install left out (not the one put back), and lists none on a full install
#
# Mutants this must fail: the checklist installs what was not picked; Enter or n installs; the picks skip `hmd skills install`; the call sits above the marker guard;
# the left-out group is not listed on a lean install; the list names the coding agent.
# Exit: 0 every check passed, 1 a check failed, 2 this machine cannot run the suite.
# budget: 90 -- one snapshot of the checkout and a lean clone of it, then six real launcher starts (each starts python a dozen times) and the skills calls they make.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=use-cases/lib.sh
. "$HERE/use-cases/lib.sh"
uc_begin first-launch-checklist
uc_tree
uc_fakebin
# shellcheck disable=SC2034  # read by uc_run (test/use-cases/lib.sh): a launcher start that has not ended by then is hung
UC_TIMEOUT_S=150

"$UC_PY" -I -c 'import pty; pty.openpty()' >/dev/null 2>&1 || uc_fatal "no pseudo-terminal can be opened here: the checklist is only asked at a terminal"

# a person at a terminal: the child gets a pty for stdin, stdout and stderr; once WAIT shows on the screen the driver types the answer (a literal, or the numbers
# of the listed ids, read off the screen) and keeps reading to the end. The screen goes to stdout, the child's status is the driver's.
DRIVER="$UC_ROOT/pty_drive.py"
cat > "$DRIVER" <<'PYEOF'
import os, pty, re, select, signal, sys, time

argv = sys.argv[1:]
cut = argv.index("--")
opts, cmd = argv[:cut], argv[cut + 1:]
wait = send = pick = None
for flag, value in zip(opts[::2], opts[1::2]):
    if flag == "--wait":
        wait = value
    elif flag == "--send":
        send = value
    elif flag == "--pick":
        pick = value
limit = int("@LIMIT@")
pid, fd = pty.fork()
if pid == 0:
    try:
        os.execvp(cmd[0], cmd)
    finally:
        os._exit(127)
buf = bytearray()
answered = False
status = None
deadline = time.time() + limit
while True:
    if time.time() > deadline:
        os.kill(pid, signal.SIGKILL)
        os.waitpid(pid, 0)
        sys.stdout.write(buf.decode("utf-8", "replace") + "\n[pty driver: no end after %d s]\n" % limit)
        sys.exit(124)
    if status is None:
        done, found = os.waitpid(pid, os.WNOHANG)
        if done:
            status = found
    ready, _, _ = select.select([fd], [], [], 0.2)
    if not ready:
        if status is not None:
            break  # the command is gone and nothing is left to read: a process it started may still hold the terminal open, and is not waited for
        continue
    try:
        data = os.read(fd, 4096)
    except OSError:
        break
    if not data:
        break
    buf += data
    if not answered and wait and wait.encode() in buf:
        answered = True
        if send is None:
            screen = buf.decode("utf-8", "replace")
            found = [re.search(r"^\s*(\d+)\)\s+%s\s" % re.escape(name), screen, re.M) for name in (pick or "").split(",")]
            send = " ".join(m.group(1) for m in found if m)
        os.write(fd, (send + "\n").encode())
if status is None:
    _, status = os.waitpid(pid, 0)
sys.stdout.write(buf.decode("utf-8", "replace"))
sys.exit(os.WEXITSTATUS(status) if os.WIFEXITED(status) else 128 + os.WTERMSIG(status))
PYEOF
# how long the driver waits for a command to end (a hang detector, never a speed assertion); PTY_LIMIT shortens it for a run against code that cannot answer
sed "s/@LIMIT@/${PTY_LIMIT:-40}/" "$DRIVER" > "$DRIVER.tmp" && mv "$DRIVER.tmp" "$DRIVER"

# the lean clone the launcher runs from: the snapshot of this checkout, narrowed by the real lean script
bash "$UC_TREE/bin/lib/lean_sparse.sh" apply lean "$UC_TREE" > "$UC_ROOT/lean.out" 2>&1 || uc_fatal "lean_sparse.sh apply lean failed: $(head -c 300 "$UC_ROOT/lean.out")"
HMD="$UC_TREE/bin/heimdall"
MANIFEST="$UC_TREE/skills.manifest.json"
if [ ! -e "$UC_TREE/skills/stacks" ] && [ ! -e "$UC_TREE/skills/mac-deep-clean" ] && [ -f "$UC_TREE/skills/heimdall/SKILL.md" ]; then
  uc_ok "(setup) the clone is lean: the bundled stacks and mac-deep-clean skills are off the disk, the orchestrator skill is on it"
else
  uc_bad "(setup) the clone is not lean"
fi

KEY=ANTHROPIC_API_KEY=sk-test-not-a-real-key
SCREEN=""
# new_box NAME PROFILE -- a fresh HOME and project with the install profile recorded (hmd_profile.py, the file the installer's init writes), an empty agent log,
# and no pre-migration marker left in the plugin dir by an earlier box
new_box() {
  uc_sandbox "$1"
  HH="$UC_HOME/.heimdall"
  PROJ="$UC_WORK/proj"
  mkdir -p "$PROJ"
  : > "$UC_CLAUDE_LOG"
  rm -f "$UC_TREE/.setup-done"
  uc_run "$UC_HOME" "$PROJ" -- "$UC_PY" -I "$UC_TREE/bin/lib/hmd_profile.py" set "$2"
  uc_rc "(setup) box $1 runs the $2 profile" 0
}
# keep_screen NAME -- the last run's output with the terminal's carriage returns dropped
keep_screen() { SCREEN="$UC_ROOT/screen-$1.txt"; LC_ALL=C tr -d '\r' < "$UC_OUT" > "$SCREEN"; }
installs() { grep -c '^claude plugins install ' "$UC_CLAUDE_LOG" 2>/dev/null; }

# ---------------------------------------------------------------- A. numbers
new_box pick lean
uc_run "$UC_HOME" "$PROJ" "$KEY" -- "$UC_PY" -I "$DRIVER" --wait 'never ask:' --pick superpowers,frontend-design,stacks -- "$HMD" --setup
uc_rc "A: the first launch at a terminal, answered with numbers" 0
keep_screen pick
BLOCK="$UC_ROOT/block-pick.txt"
sed -n '/Add skills to hmd/,/never ask:/p' "$SCREEN" > "$BLOCK"
uc_has "A: ONE checklist is shown, with the question" "$BLOCK" 'never ask:'
MISSING=""
while IFS="$(printf '\t')" read -r id why; do
  [ -n "$id" ] || continue
  if grep -Eq "^ *[0-9]+\) $id  " "$BLOCK" && grep -Fq -- "$why" "$BLOCK"; then :; else MISSING="$MISSING $id"; fi
done <<EOF
$(jq -r '.entries[] | select(.tier == "recommended") | .id + "\t" + (.why | split("; ")[0])' "$MANIFEST")
EOF
if [ -z "$MISSING" ]; then uc_ok "A: every recommended entry is listed, numbered, with its one-line why"; else uc_bad "A: not listed with their why:$MISSING"; fi
MISSING=""
while IFS="$(printf '\t')" read -r id why; do
  [ -n "$id" ] || continue
  if grep -Eq "^ *[0-9]+\) $id  " "$BLOCK" && grep -Fq -- "$why" "$BLOCK"; then :; else MISSING="$MISSING $id"; fi
done <<EOF
$(jq -r '.entries[] | select(.kind == "bundled" and (has("on_demand_paths") or has("pack"))) | .id + "\t" + (.why | split("; ")[0] | gsub("Claude "; ""))' "$MANIFEST")
EOF
if [ -z "$MISSING" ]; then uc_ok "A: every bundled skill the lean install left out (stacks, designmatch, mac-deep-clean, system-health, self-improve) is listed with its why"; else uc_bad "A: not listed with their why:$MISSING"; fi
uc_has "A: the left-out ones are a group of their own" "$BLOCK" 'Left out of this lean install'
uc_lacks "A: the checklist never names the coding agent underneath" "$BLOCK" '[Cc]laude|[Aa]nthropic'
uc_lacks "A: the heimdall orchestrator skill (already on the disk) is not offered" "$BLOCK" '[0-9]\) heimdall '
uc_has "A: the agent was asked to install superpowers (the first-run set follows the pick)" "$UC_CLAUDE_LOG" '^claude plugins install superpowers@claude-plugins-official'
uc_has "A: …and the heimdall marketplace is registered as before" "$UC_CLAUDE_LOG" '^claude plugins marketplace add randomittin/heimdall-marketplace'
uc_has "A: the picked plugin went through hmd skills install" "$UC_CLAUDE_LOG" '^claude plugins install frontend-design@claude-plugins-official'
if [ "$(installs)" = 2 ]; then uc_ok "A: exactly the two picked plugins were installed, no other"; else uc_bad "A: $(installs) plugin installs, want 2" "$(grep '^claude plugins install ' "$UC_CLAUDE_LOG" | head -5 | LC_ALL=C tr '\n' '|')"; fi
uc_jq "A: the picked bundled skill is on the machine lock, installed, with the pick as its consent" '[.entries[] | select(.id == "stacks")][0] | .state == "installed" and .kind == "bundled" and .consent == "yes-flag"' "$HH/skills.lock"
uc_jq "A: superpowers is on the machine lock, installed with consent given at a prompt" '[.entries[] | select(.id == "superpowers")][0] | .state == "installed" and .consent == "prompt"' "$HH/skills.lock"
uc_jq "A: the picked plugin is on the project lock, installed with the pick as its consent" '[.entries[] | select(.id == "frontend-design")][0] | .state == "installed" and .consent == "yes-flag"' "$PROJ/.planning/skills.lock"
if jq -s -e '[.[].entries[] | select(.state == "installed") | .id] | unique == ["frontend-design", "stacks", "superpowers"]' "$HH/skills.lock" "$PROJ/.planning/skills.lock" >/dev/null 2>&1; then uc_ok "A: nothing that was not picked is installed on either lock (machine and project)"; else uc_bad "A: the locks hold installs beyond the three picks"; fi
uc_jq "A: …the project lock holds only the picked plugin" '[.entries[].id] == ["frontend-design"]' "$PROJ/.planning/skills.lock"
if [ -f "$UC_TREE/skills/stacks/SKILL.md" ]; then uc_ok "A: the picked bundled skill is back on the disk"; else uc_bad "A: skills/stacks is still off the disk"; fi
if [ ! -e "$UC_TREE/skills/mac-deep-clean" ]; then uc_ok "A: …and the ones not picked stay off it"; else uc_bad "A: skills/mac-deep-clean came back without a pick"; fi
if [ -f "$HH/setup-done" ]; then uc_ok "A: setup is recorded, so the checklist is not asked again"; else uc_bad "A: no setup marker"; fi
# G (part): the one put back is not suggested again, the others still are
uc_run "$UC_HOME" "$PROJ" -- bash "$UC_TREE/bin/heimdall-skills" suggest
uc_rc "G: hmd skills suggest after the pick" 0
uc_has "G: suggest lists a bundled skill the lean install left out" "$UC_OUT" '^  mac-deep-clean  \[on demand\]  '
uc_lacks "G: …but not the one that was put back" "$UC_OUT" '^  stacks  '
uc_has "G: …and the recommended ones that were not picked" "$UC_OUT" '^  devops-toolkit  \[recommended\]  '
uc_lacks "G: suggest never names the coding agent in the bundled lines" "$UC_OUT" '^  (designmatch|stacks|self-improve|system-health|mac-deep-clean)  .*[Cc]laude'
uc_has "G: the first line still counts the project's suggestions (what the session nudge reads)" "$UC_OUT" '^[0-9]+ skill\(s\) suggested for this project'

# ---------------------------------------------------------------- B. Enter
new_box none lean
uc_run "$UC_HOME" "$PROJ" "$KEY" -- "$UC_PY" -I "$DRIVER" --wait 'never ask:' --send '' -- "$HMD" --setup
uc_rc "B: the first launch at a terminal, answered with Enter" 0
keep_screen none
uc_has "B: the checklist was shown" "$SCREEN" 'Add skills to hmd'
if [ "$(installs)" = 0 ] && ! grep -q 'marketplace add' "$UC_CLAUDE_LOG"; then uc_ok "B: nothing was installed and no marketplace was added"; else uc_bad "B: the agent was asked to add something" "$(grep -E '^claude plugins (install|marketplace add)' "$UC_CLAUDE_LOG" | head -3 | LC_ALL=C tr '\n' '|')"; fi
uc_jq "B: superpowers is on the machine lock as suggested" '[.entries[] | select(.id == "superpowers")][0].state == "suggested"' "$HH/skills.lock"
uc_has "B: the way back is said" "$SCREEN" 'hmd skills suggest'
if [ -f "$HH/setup-done" ]; then uc_ok "B: setup is recorded"; else uc_bad "B: no setup marker"; fi

# ---------------------------------------------------------------- C. n
new_box never lean
uc_run "$UC_HOME" "$PROJ" "$KEY" -- "$UC_PY" -I "$DRIVER" --wait 'never ask:' --send n -- "$HMD" --setup
uc_rc "C: the first launch at a terminal, answered n" 0
keep_screen never
if [ "$(installs)" = 0 ] && ! grep -q 'marketplace add' "$UC_CLAUDE_LOG"; then uc_ok "C: nothing was installed and no marketplace was added"; else uc_bad "C: the agent was asked to add something"; fi
uc_jq "C: every listed skill is declined on the machine lock (a recommended plugin, a left-out bundled skill and superpowers)" \
  '[.entries[] | select(.state == "declined") | .id] | (index("superpowers") != null) and (index("frontend-design") != null) and (index("stacks") != null) and (index("mac-deep-clean") != null)' "$HH/skills.lock"
uc_has "C: the way back is said" "$SCREEN" 'suggest --reset'
uc_run "$UC_HOME" "$PROJ" -- bash "$UC_TREE/bin/heimdall-skills" suggest
uc_lacks "C: hmd skills suggest holds the declined ones back" "$UC_OUT" '^  (stacks|frontend-design|mac-deep-clean)  '
uc_has "C: …and says how many, and how to ask again" "$UC_OUT" 'declined \(hmd skills suggest --reset asks again\)'

# ---------------------------------------------------------------- D. no terminal
new_box pipe lean
uc_run "$UC_HOME" "$PROJ" "$KEY" -- "$HMD" --setup
uc_rc "D: the first launch with no terminal finishes (nothing waits on a question nobody can answer)" 0
keep_screen pipe
uc_lacks "D: no checklist is drawn" "$SCREEN" 'Add skills to hmd'
uc_has "D: ONE line points to hmd skills suggest" "$SCREEN" '^  No terminal to ask on, so no skills were added\. See what is available: hmd skills suggest$'
if [ "$(grep -c 'No terminal to ask on' "$SCREEN")" = 1 ]; then uc_ok "D: …said once"; else uc_bad "D: the pointer line is said $(grep -c 'No terminal to ask on' "$SCREEN") times"; fi
if [ "$(installs)" = 0 ] && ! grep -q 'marketplace add' "$UC_CLAUDE_LOG"; then uc_ok "D: nothing was installed and no marketplace was added"; else uc_bad "D: the agent was asked to add something"; fi
uc_jq "D: superpowers is on the machine lock as suggested, as the launcher always wrote it" '[.entries[] | select(.id == "superpowers")][0].state == "suggested"' "$HH/skills.lock"
uc_has "D: …and the deferral is still said on stderr" "$UC_ERR" 'recommended skill superpowers not installed'
if [ -f "$HH/setup-done" ]; then uc_ok "D: setup is recorded"; else uc_bad "D: no setup marker"; fi

# ---------------------------------------------------------------- E. setup already done
new_box warm lean
: > "$HH/setup-done"
LAUNCHER_FN='. "$1/bin/lib/skills_consent.sh"; . "$1/bin/lib/first_launch_checklist.sh"; SETUP_MARKER="$2"; eval "$(sed -n "/^first_run_setup()/,/^}/p" "$1/bin/heimdall")"; first_run_setup; echo "first_run_setup rc=$?"'
uc_run "$UC_HOME" "$PROJ" "$KEY" -- "$UC_PY" -I "$DRIVER" --wait 'never ask:' --send '' -- bash -c "$LAUNCHER_FN" hmd "$UC_TREE" "$HH/setup-done"
uc_rc "E: first_run_setup at a terminal with the marker present" 0
keep_screen warm
uc_has "E: (control) the real first_run_setup ran and returned" "$SCREEN" 'first_run_setup rc=0'
uc_lacks "E: it shows nothing: no checklist, no first-run banner" "$SCREEN" 'Add skills to hmd|First run'

# ---------------------------------------------------------------- F. consent auto
new_box auto lean
uc_run "$UC_HOME" "$PROJ" "$KEY" HMD_SKILLS_CONSENT=auto -- "$UC_PY" -I "$DRIVER" --wait 'never ask:' --send '' -- "$HMD" --setup
uc_rc "F: the first launch at a terminal with consent auto" 0
keep_screen auto
uc_lacks "F: no checklist" "$SCREEN" 'Add skills to hmd'
uc_has "F: the first-run set installs as before: superpowers" "$UC_CLAUDE_LOG" '^claude plugins install superpowers@claude-plugins-official'
uc_has "F: …and the heimdall marketplace" "$UC_CLAUDE_LOG" '^claude plugins marketplace add randomittin/heimdall-marketplace'

# ---------------------------------------------------------------- G. a full install lists none of the left-out ones
new_box full full
uc_run "$UC_HOME" "$PROJ" -- bash "$UC_TREE/bin/heimdall-skills" suggest
uc_rc "G: hmd skills suggest on a full install" 0
uc_has "G: (control) the recommended ones are suggested" "$UC_OUT" '^  superpowers  \[recommended\]  '
uc_lacks "G: no bundled skill is suggested: nothing was left out" "$UC_OUT" '^  (stacks|designmatch|self-improve|system-health|mac-deep-clean)  '
uc_lacks "G: …and no left-out group is drawn" "$UC_OUT" 'lean install leaves out'

if [ ! -s "$UC_SECURITY_LOG" ]; then uc_ok "the keychain was never asked"; else uc_bad "a launch asked the keychain" "$(head -c 200 "$UC_SECURITY_LOG")"; fi
uc_finish
