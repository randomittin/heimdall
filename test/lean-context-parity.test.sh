#!/usr/bin/env bash
# lean-context-parity.test.sh -- proves bin/lib/lean_context_parity.py (lean-core plan T1.2, docs/superpowers/plans/2026-11-12-3x-lean-core.md):
# the INDEPENDENT reference for INV-L1 -- with profile `full`, every byte hmd injects into a session is today's.
#
#   1. RECORD     measure / record / check over a tiny committed fixture plugin root: every file under agents/ commands/ skills/ is hashed
#                 (sha256 + bytes, plus the frontmatter span of a markdown file), settings.json is read for the `agent` it selects, hooks.json
#                 is hashed and counted per event, the caveman tool's rules and level are captured, and each SessionStart / UserPromptSubmit
#                 hook is either RUN in a sandbox (its stdout hashed) or skipped with a stated reason. Every expected value is derived here
#                 (python hashlib, printf | wc -c, constants of the construction), never read back from the tool.
#   2. FALSIFY    one injected defect per claim (a byte of an agent body, a frontmatter line, a new / removed file, the settings agent, hooks.json,
#                 the caveman rules, a hook that prints something else) turns `check` RED and names the item; OS cruft does not; a restore is green.
#   3. HERMETIC   a hook sees a throwaway HOME / project / tmp and none of the caller's environment, a hook that is not vetted is not executed,
#                 a hook that reaches for the Keychain or the network, or hangs, makes the run exit 2 with nothing on stdout, and the real
#                 tree's run leaves the caller's HOME and the repo untouched.
#   4. TRUST      a baseline that is missing, malformed, hand-edited (digest) or of another schema is exit 2, never a pass; `record` refuses a
#                 dirty or non-git tree and writes nothing.
#   5. THE REAL TREE   the shipped evals/lean/context-baseline.json matches this tree (`check` exit 0: the gate), accounts for every hook of the
#                 two context events, agrees with independent hashes, and a copy of the real tree at another path is as green as the tree.
#
# HMD_PARITY_BIN points the suite at another copy of the tool (a mutated copy, to watch an assertion go red). bash 3.2 compatible.
# budget: 90 -- measured 59 to 81 s with the machine at a load average of 60 (11 to 26 s of it the real-tree check, which runs 17 hooks and the caveman tool in a sandbox; the fixture cases are about a dozen more runs); far less on an idle box
#
# Usage:  bash test/lean-context-parity.test.sh
# shellcheck disable=SC2016  # the jq programs are single-quoted on purpose: their $vars are jq variables bound with --arg, not shell variables
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SELF_DIR/.." && pwd)"
MOD="${HMD_PARITY_BIN:-$REPO/bin/lib/lean_context_parity.py}"
SHIPPED="$REPO/evals/lean/context-baseline.json"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; }

command -v jq >/dev/null 2>&1 || { echo "lean-context-parity: jq is required"; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "lean-context-parity: python3 is required"; exit 1; }

# nothing of the caller's environment may leak into a case
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR GIT_PREFIX HEIMDALL_HOME CLAUDE_PLUGIN_ROOT CLAUDE_PROJECT_DIR CANARY_LEAK HMD_PARITY_HOOK_TIMEOUT_S
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1

T="$(mktemp -d "${TMPDIR:-/tmp}/lean-ctx-parity.XXXXXX")" || exit 1; T="$(cd "$T" && pwd -P)"
cleanup() { chmod -R u+rwX "$T" 2>/dev/null; rm -rf "$T"; }
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

echo "lean-context-parity (the INV-L1 reference: hashes of every injected file, the settings, hooks.json, the caveman rules, hook stdout)"

# ── helpers: every run writes $T/<name>.{out,err,rc} ───────────────────────────────────────────────────────────────────────────────────
LASTRUN=""
par() { python3 -I "$MOD" "$@"; }
run() { local n="$1"; shift; LASTRUN="$n"; par "$@" >"$T/$n.out" 2>"$T/$n.err"; echo $? >"$T/$n.rc"; }
rc() { cat "$T/$1.rc" 2>/dev/null; }
show() { printf 'rc=%s out=[%s] err=[%s]' "$(rc "$1")" "$(head -c 500 "$T/$1.out" 2>/dev/null)" "$(head -c 500 "$T/$1.err" 2>/dev/null)"; }
chk() { local d="$1"; shift; if "$@"; then ok "$d"; else bad "$d ($(show "$LASTRUN"))"; fi; }
not() { ! "$@"; }
rc_is() { [ "$(rc "$1")" = "$2" ]; }
oh() { grep -qF -- "$2" "$T/$1.out" 2>/dev/null; }              # stdout of run $1 contains $2
eh() { grep -qF -- "$2" "$T/$1.err" 2>/dev/null; }              # stderr of run $1 contains $2
eo() { [ -f "$T/$1.out" ] && [ ! -s "$T/$1.out" ]; }              # stdout of run $1 is empty
lineof() { grep -F -- "$2" "$T/$1.out" 2>/dev/null | head -1; }  # the first stdout line of run $1 naming $2
jqe() { local n="$1"; shift; jq -e "$@" "$T/$n.out" >/dev/null 2>&1; }   # stdout of run $n satisfies a jq expression
jqf() { local f="$1"; shift; jq -e "$@" "$f" >/dev/null 2>&1; }         # file $f satisfies a jq expression
sha_of() { printf '%s' "$1" | python3 -I -c 'import hashlib,sys; print(hashlib.sha256(sys.stdin.buffer.read()).hexdigest())'; }
sha_file() { python3 -I -c 'import hashlib,sys; print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$1"; }
size_of() { wc -c < "$1" | tr -d ' '; }
snap() {   # one hash over every path and byte under $1: a directory that must come out of a run exactly as it went in
  python3 -I - "$1" <<'PY'
import hashlib, os, sys
h = hashlib.sha256()
for dirpath, dirnames, filenames in os.walk(sys.argv[1]):
    dirnames.sort()
    for name in sorted(dirnames + filenames):
        path = os.path.join(dirpath, name)
        h.update(os.path.relpath(path, sys.argv[1]).encode() + b"\0")
        if os.path.isfile(path):
            h.update(open(path, "rb").read())
print(h.hexdigest())
PY
}

echo "-- 0. the tool and its record exist --"
if [ -f "$MOD" ]; then ok "bin/lib/lean_context_parity.py exists"; else bad "$MOD is missing"; fi
refs_footprint() {   # exit 0 when the code of $1 refers to the footprint meter: an import, a name, an attribute or a string literal (a docstring may name it)
  python3 -I - "$1" <<'PY'
import ast, sys
tree = ast.parse(open(sys.argv[1]).read())
skip = set()
if tree.body and isinstance(tree.body[0], ast.Expr) and isinstance(tree.body[0].value, ast.Constant):
    skip = {id(tree.body[0]), id(tree.body[0].value)}
hits = []
for node in ast.walk(tree):
    if id(node) in skip:
        continue
    if isinstance(node, ast.Constant) and isinstance(node.value, str):
        text = node.value
    elif isinstance(node, ast.Name):
        text = node.id
    elif isinstance(node, ast.Attribute):
        text = node.attr
    elif isinstance(node, (ast.Import, ast.ImportFrom)):
        text = " ".join([a.name for a in node.names] + [getattr(node, "module", None) or ""])
    else:
        continue
    if "footprint" in text.lower():
        hits.append(text)
sys.exit(0 if hits else 1)
PY
}
if [ -f "$MOD" ] && ! refs_footprint "$MOD"; then ok "independent reference: no import, name or literal of the tool refers to the footprint meter"; else bad "the tool is missing or its code refers to the footprint meter"; fi
if [ -f "$MOD" ]; then
  cp "$MOD" "$T/mutant.py"; printf 'METER = "bin/heimdall-footprint"\n' >> "$T/mutant.py"
  if refs_footprint "$T/mutant.py"; then ok "the independence check goes RED on a mutant that names the meter"; else bad "the independence check missed a mutant that names the meter"; fi
fi
if [ -f "$SHIPPED" ]; then ok "evals/lean/context-baseline.json exists"; else bad "$SHIPPED is missing"; fi

echo "-- 1. usage errors are exit 2 --"
run noargs
chk "no subcommand: exit 2" rc_is noargs 2
run bogus bogus
chk "unknown subcommand: exit 2" rc_is bogus 2
run badsec check --sections nonsense --baseline "$SHIPPED"
chk "unknown section: exit 2, nothing on stdout, the name is said" rc_is badsec 2
chk "unknown section: stdout empty" eo badsec
chk "unknown section: stderr names it" eh badsec nonsense

# ── the fixture: a committed plugin root whose every number is known by construction ───────────────────────────────────────────────────
write_caveman() {   # write_caveman DIR VERSION -- the caveman tool the fixture's hooks and the tool's caveman section call
  cat > "$1/bin/heimdall-caveman" <<EOF
#!/bin/sh
case "\$1" in
  rules) printf 'CAVEMAN RULES $2\n' ;;
  get) printf 'ultra\n' ;;
esac
EOF
  chmod +x "$1/bin/heimdall-caveman"
}
write_probe() {   # write_probe DIR NAME BODY -- an executable the fixture's hooks call
  printf '#!/bin/sh\n%s\n' "$3" > "$1/bin/$2"
  chmod +x "$1/bin/$2"
}
mkfx() {   # mkfx DIR
  local d="$1"
  mkdir -p "$d/agents" "$d/commands" "$d/skills/s1/refs" "$d/hooks" "$d/bin"
  printf -- '---\nname: main\ndescription: Main agent\n---\nmain prompt body\n' > "$d/agents/main.md"
  printf -- '---\nname: helper\ndescription: Helper agent\n---\nhelper body\n' > "$d/agents/helper.md"
  printf -- '---\nname: c1\ndescription: First command\n---\ncommand body\n' > "$d/commands/c1.md"
  printf 'a command with no frontmatter at all\n' > "$d/commands/c0.md"
  printf -- '---\nname: s1\ndescription: The only skill\n---\nskill body\n' > "$d/skills/s1/SKILL.md"
  printf 'reference text\n' > "$d/skills/s1/refs/r.md"
  printf '{"agent": "main"}\n' > "$d/settings.json"
  printf 'notice v1' > "$d/bin/notice.txt"
  write_caveman "$d" v1
  write_probe "$d" probe-notice 'printf "N=%s" "$(cat "$CLAUDE_PLUGIN_ROOT/bin/notice.txt")"'
  write_probe "$d" probe-env 'printf "HOME=%s HH=%s CAL=%s CPD=%s" "$HOME" "${HEIMDALL_HOME:-}" "${CANARY_LEAK:-unset}" "$CLAUDE_PROJECT_DIR"; sed -n "s/.*\"source\":\"\([a-z]*\)\".*/ S=\1/p" | tr -d "\n"'
  write_probe "$d" probe-source 'sed -n "s/.*\"source\":\"\([a-z]*\)\".*/S=\1/p" | tr -d "\n"'
  write_probe "$d" probe-event 'sed -n "s/.*\"hook_event_name\":\"\([A-Za-z]*\)\".*/E=\1/p" | tr -d "\n"'
  write_probe "$d" probe-level 'printf "level=%s" "$("$CLAUDE_PLUGIN_ROOT/bin/heimdall-caveman" get)"'
  jq -n --arg marker "$T/not-vetted-ran" '
    {hooks: {
      SessionStart: [
        {hooks: [{type: "command", command: ": hmd_hook_enabled caveman-rules; ${CLAUDE_PLUGIN_ROOT}/bin/heimdall-caveman rules"}]},
        {hooks: [{type: "command", command: (": hmd_hook_enabled presence-keeper-start; echo ran > " + $marker)}]},
        {hooks: [{type: "command", command: ": hmd_hook_enabled dream-notice; ${CLAUDE_PLUGIN_ROOT}/bin/probe-notice"}]},
        {hooks: [{type: "command", command: ": hmd_hook_enabled resume-probe; ${CLAUDE_PLUGIN_ROOT}/bin/probe-env"}]},
        {matcher: "compact", hooks: [{type: "command", command: ": hmd_hook_enabled continue-inject; ${CLAUDE_PLUGIN_ROOT}/bin/probe-source"}]}
      ],
      UserPromptSubmit: [
        {hooks: [{type: "command", command: ": hmd_hook_enabled caveman-level-context; ${CLAUDE_PLUGIN_ROOT}/bin/probe-level"}]},
        {hooks: [{type: "command", command: ": hmd_hook_enabled ctx-meter-notice; ${CLAUDE_PLUGIN_ROOT}/bin/probe-event"}]}
      ]
    }}' > "$d/hooks/hooks.json"
}
add_hook() {   # add_hook DIR EVENT COMMAND -- append one command hook to a fixture
  jq --arg e "$2" --arg c "$3" '.hooks[$e] += [{hooks: [{type: "command", command: $c}]}]' "$1/hooks/hooks.json" > "$1/hooks/hooks.json.new" \
    && mv "$1/hooks/hooks.json.new" "$1/hooks/hooks.json"
}

FX="$T/fx"
mkfx "$FX"
git init -q "$FX" && git -C "$FX" add -A \
  && git -C "$FX" -c user.name=fixture -c user.email=fixture@example.invalid -c commit.gpgsign=false -c core.hooksPath=/dev/null commit -q -m fixture

echo "-- 2. measure: what is recorded, derived independently --"
( export CANARY_LEAK=leaked HEIMDALL_HOME="$T/caller-home" CLAUDE_PROJECT_DIR="$T/caller-project"; run fxm measure --root "$FX" )   # the caller's env must not reach a hook
LASTRUN=fxm
chk "measure exits 0 with a JSON document of the five sections" jqe fxm '.schema == 1 and ((.sections|keys) == ["caveman","files","hook_stdout","hooks_json","settings"])'
chk "files: exactly the six files under agents/ commands/ skills/" jqe fxm '(.sections.files|keys|join(" ")) == "agents/helper.md agents/main.md commands/c0.md commands/c1.md skills/s1/SKILL.md skills/s1/refs/r.md"'
chk "files: sha256 and bytes of a file are the independent hash and size" \
  jqe fxm --arg s "$(sha_file "$FX/agents/main.md")" --argjson b "$(size_of "$FX/agents/main.md")" '.sections.files["agents/main.md"] | .sha256 == $s and .bytes == $b'
chk "files: the frontmatter span (both --- lines) is hashed on its own" \
  jqe fxm --arg s "$(sha_of $'---\nname: main\ndescription: Main agent\n---\n')" --argjson b "$(printf -- '---\nname: main\ndescription: Main agent\n---\n' | wc -c | tr -d ' ')" \
  '.sections.files["agents/main.md"].frontmatter | .sha256 == $s and .bytes == $b'
chk "files: a file without frontmatter has no frontmatter entry" jqe fxm '.sections.files["commands/c0.md"] | has("frontmatter") | not'
chk "settings: the agent it selects is read, the file is hashed" \
  jqe fxm --arg s "$(sha_file "$FX/settings.json")" '.sections.settings["settings.json"] | .agent == "main" and .sha256 == $s'
chk "hooks_json: hash of the file and the hook count per event" \
  jqe fxm --arg s "$(sha_file "$FX/hooks/hooks.json")" '.sections.hooks_json["hooks/hooks.json"] | .sha256 == $s and .events == {"SessionStart": 5, "UserPromptSubmit": 2}'
chk "caveman: the rules are the independent hash of what the tool prints" jqe fxm --arg s "$(sha_of $'CAVEMAN RULES v1\n')" '.sections.caveman.rules | .sha256 == $s and .bytes == 17 and .exit == 0'
chk "caveman: the level is what the get subcommand prints" jqe fxm '.sections.caveman.level.value == "ultra"'
chk "hook_stdout: every hook of the two events has an entry, keyed event/index-id" \
  jqe fxm '[.sections.hook_stdout|keys[]] == ["SessionStart/00-caveman-rules","SessionStart/01-presence-keeper-start","SessionStart/02-dream-notice","SessionStart/03-resume-probe","SessionStart/04-continue-inject","UserPromptSubmit/00-caveman-level-context","UserPromptSubmit/01-ctx-meter-notice"]'
hsha() { jq -r --arg k "$1" '.sections.hook_stdout[$k].stdout.sha256' "$T/fxm.out"; }
chk "hook_stdout: a SessionStart hook's stdout is hashed (caveman rules)" [ "$(hsha SessionStart/00-caveman-rules)" = "$(sha_of $'CAVEMAN RULES v1\n')" ]
chk "hook_stdout: a hook reading a file under the plugin root" [ "$(hsha SessionStart/02-dream-notice)" = "$(sha_of 'N=notice v1')" ]
chk "hook_stdout: HOME, HEIMDALL_HOME and the project are the sandbox's, the caller's env is absent, stdin carries source=startup" \
  [ "$(hsha SessionStart/03-resume-probe)" = "$(sha_of 'HOME=<SANDBOX>/home HH=<SANDBOX>/home/.heimdall CAL=unset CPD=<SANDBOX>/project S=startup')" ]
chk "hook_stdout: a compact-matcher hook is fed source=compact" [ "$(hsha SessionStart/04-continue-inject)" = "$(sha_of 'S=compact')" ]
chk "hook_stdout: a UserPromptSubmit hook runs through the caveman tool" [ "$(hsha UserPromptSubmit/00-caveman-level-context)" = "$(sha_of 'level=ultra')" ]
chk "hook_stdout: a UserPromptSubmit hook is fed hook_event_name=UserPromptSubmit" [ "$(hsha UserPromptSubmit/01-ctx-meter-notice)" = "$(sha_of 'E=UserPromptSubmit')" ]
chk "hook_stdout: a run hook records its exit code, id and the hash of its command" \
  jqe fxm --arg c "$(jq -r '.hooks.SessionStart[0].hooks[0].command' "$FX/hooks/hooks.json")" '.sections.hook_stdout["SessionStart/00-caveman-rules"] | .run == true and .exit == 0 and .id == "caveman-rules"'
chk "hook_stdout: a hook that is not vetted is skipped with a reason" jqe fxm '.sections.hook_stdout["SessionStart/01-presence-keeper-start"] | .run == false and (.skipped|length) > 0'
chk "hook_stdout: a hook that is not vetted was never executed" not test -e "$T/not-vetted-ran"

echo "-- 3. hermetic: a hook that reaches for the Keychain, the network or a long wait is exit 2 --"
cp -R "$FX" "$T/fx-deny"
add_hook "$T/fx-deny" SessionStart ': hmd_hook_enabled ai-select; security find-generic-password -s hmd-parity; echo reached'
run deny measure --root "$T/fx-deny" --sections hook_stdout
chk "a hook that calls security: exit 2" rc_is deny 2
chk "a hook that calls security: nothing on stdout" eo deny
chk "a hook that calls security: stderr names the tool" eh deny security
cp -R "$FX" "$T/fx-net"
add_hook "$T/fx-net" UserPromptSubmit ': hmd_hook_enabled inbox-deliver-prompt; curl -s http://example.invalid/'
run net measure --root "$T/fx-net" --sections hook_stdout
chk "a hook that calls curl: exit 2 naming curl" rc_is net 2
chk "a hook that calls curl: stderr names the tool" eh net curl
cp -R "$FX" "$T/fx-slow"
add_hook "$T/fx-slow" UserPromptSubmit ': hmd_hook_enabled finished-agents-prompt; sleep 30'
( export HMD_PARITY_HOOK_TIMEOUT_S=1; run slow measure --root "$T/fx-slow" --sections hook_stdout )
LASTRUN=slow
chk "a hook that hangs is cut at the timeout: exit 2" rc_is slow 2
chk "a hook that hangs: stderr says it timed out" eh slow 'timed out'
chk "a hook that hangs: nothing on stdout" eo slow

echo "-- 4. record and check over the fixture --"
FXB="$T/fx-baseline.json"
run rec record --root "$FX" --baseline "$FXB"
chk "record exits 0 and writes the baseline" rc_is rec 0
chk "baseline: schema 1, a 64-hex digest, the git trees it was recorded from" \
  jqf "$FXB" '.schema == 1 and (.digest|test("^[0-9a-f]{64}$")) and ([.info.git_trees[]|select(test("^[0-9a-f]{40}$"))]|length) == 5'
chk "baseline: the six files and seven hooks are in it" jqf "$FXB" '(.sections.files|length) == 6 and (.sections.hook_stdout|length) == 7'
run fxc check --root "$FX" --baseline "$FXB"
chk "check of the recorded tree: exit 0, PASS" rc_is fxc 0
chk "check of the recorded tree: says PASS" oh fxc 'lean-context-parity: PASS'

MX="$T/mx"
restore_mx() { rm -rf "$MX"; cp -R "$FX" "$MX"; rm -rf "$MX/.git"; }

echo "-- 5. falsify: one injected defect per claim --"
restore_mx; printf -- '---\nname: main\ndescription: Main agent\n---\nmain prompt body CHANGED\n' > "$MX/agents/main.md"
run m1 check --root "$MX" --baseline "$FXB" --sections files
chk "a byte of an agent body: exit 1" rc_is m1 1
chk "a byte of an agent body: the file is named as changed" oh m1 'changed  files  agents/main.md'
case "$(lineof m1 'agents/main.md')" in
  *frontmatter*) bad "a body-only change must not be blamed on the frontmatter" ;;
  *sha256*) ok "a body-only change names the file hash, not the frontmatter" ;;
  *) bad "a body-only change names no hash: $(show m1)" ;;
esac

restore_mx; printf -- '---\nname: helper\ndescription: Helper agent CHANGED\n---\nhelper body\n' > "$MX/agents/helper.md"
run m2 check --root "$MX" --baseline "$FXB" --sections files
chk "a frontmatter line: exit 1, the file named" rc_is m2 1
case "$(lineof m2 'agents/helper.md')" in
  *frontmatter*) ok "a frontmatter change is named as such" ;;
  *) bad "a frontmatter change is not named as frontmatter: $(show m2)" ;;
esac

restore_mx; printf 'x' > "$MX/commands/c9.md"
run m3 check --root "$MX" --baseline "$FXB" --sections files
chk "a new command file: exit 1, reported as extra" rc_is m3 1
chk "a new command file: named" oh m3 'extra  files  commands/c9.md'

restore_mx; rm "$MX/skills/s1/refs/r.md"
run m4 check --root "$MX" --baseline "$FXB" --sections files
chk "a removed skill file: exit 1, reported as missing" rc_is m4 1
chk "a removed skill file: named" oh m4 'missing  files  skills/s1/refs/r.md'

restore_mx; printf '{"agent": "other"}\n' > "$MX/settings.json"
run m5 check --root "$MX" --baseline "$FXB" --sections settings
chk "the settings agent: exit 1" rc_is m5 1
case "$(lineof m5 'settings.json')" in
  *agent*) ok "the settings agent change is named: agent main -> other" ;;
  *) bad "the settings change does not name the agent: $(show m5)" ;;
esac

restore_mx; jq -c . "$MX/hooks/hooks.json" > "$MX/hooks/hooks.json.new" && mv "$MX/hooks/hooks.json.new" "$MX/hooks/hooks.json"
run m6 check --root "$MX" --baseline "$FXB" --sections hooks_json
chk "hooks.json bytes (same hooks, other bytes): exit 1" rc_is m6 1
chk "hooks.json bytes: named" oh m6 'changed  hooks_json  hooks/hooks.json'
case "$(lineof m6 'hooks/hooks.json')" in
  *events*) bad "same hooks must not change the event counts: $(show m6)" ;;
  *) ok "hooks.json bytes: the event counts are not blamed" ;;
esac

restore_mx; write_caveman "$MX" v2
run m7 check --root "$MX" --baseline "$FXB" --sections caveman
chk "the caveman rules: exit 1" rc_is m7 1
chk "the caveman rules: named" oh m7 'changed  caveman  rules'

restore_mx; printf 'notice v2' > "$MX/bin/notice.txt"
run m8 check --root "$MX" --baseline "$FXB"
chk "a hook that prints something else (hooks.json untouched): exit 1" rc_is m8 1
chk "a hook that prints something else: the hook is named" oh m8 'changed  hook_stdout  SessionStart/02-dream-notice'
chk "a hook that prints something else: nothing else is blamed" not grep -qE 'changed  (files|settings|hooks_json|caveman)' "$T/m8.out"

restore_mx; printf 'junk' > "$MX/agents/.DS_Store"; mkdir -p "$MX/skills/s1/__pycache__"; printf 'x' > "$MX/skills/s1/__pycache__/a.pyc"; printf 'x' > "$MX/skills/s1/b.pyc"
run m9 check --root "$MX" --baseline "$FXB" --sections files
chk "OS and bytecode cruft is not part of the tree: exit 0" rc_is m9 0

restore_mx
run m10 check --root "$MX" --baseline "$FXB"
chk "a restored copy at another path is green again (the defects were the cause)" rc_is m10 0

echo "-- 6. trust: a baseline that cannot be believed is exit 2 --"
jq '.sections.files["agents/main.md"].sha256 = "0000000000000000000000000000000000000000000000000000000000000000"' "$FXB" > "$T/bad-digest.json"
run t1 check --root "$FX" --baseline "$T/bad-digest.json"
chk "a hand-edited hash (digest no longer matches): exit 2" rc_is t1 2
chk "a hand-edited hash: nothing on stdout, digest named" eo t1
chk "a hand-edited hash: stderr names the digest" eh t1 digest
printf '{' > "$T/malformed.json"
run t2 check --root "$FX" --baseline "$T/malformed.json"
chk "a malformed baseline: exit 2" rc_is t2 2
run t3 check --root "$FX" --baseline "$T/does-not-exist.json"
chk "a missing baseline: exit 2" rc_is t3 2
jq '.schema = 99' "$FXB" > "$T/schema.json"
run t4 check --root "$FX" --baseline "$T/schema.json"
chk "another schema: exit 2" rc_is t4 2
cp -R "$FX" "$T/fx-dirty"
printf 'dirty\n' >> "$T/fx-dirty/agents/main.md"
run t5 record --root "$T/fx-dirty" --baseline "$T/dirty.json"
chk "record of a dirty tree: exit 2" rc_is t5 2
chk "record of a dirty tree: writes nothing" not test -e "$T/dirty.json"
chk "record of a dirty tree: says uncommitted" eh t5 uncommitted
run t6 record --root "$MX" --baseline "$T/nogit.json"
chk "record of a tree that is not a git work tree: exit 2" rc_is t6 2
chk "record of a non-git tree: writes nothing" not test -e "$T/nogit.json"

echo "-- 7. the real tree --"
chk "the shipped baseline is a schema-1 record with a digest and all five sections" \
  jqf "$SHIPPED" '.schema == 1 and (.digest|test("^[0-9a-f]{64}$")) and ((.sections|keys) == ["caveman","files","hook_stdout","hooks_json","settings"])'
chk "the shipped baseline pins the main-session agent: settings.json selects heimdall" jqf "$SHIPPED" '.sections.settings["settings.json"].agent == "heimdall"'
chk "the shipped baseline holds the sixteen agents, the twenty commands and the skills" \
  jqf "$SHIPPED" '([.sections.files|keys[]|select(test("^agents/[^/]+[.]md$"))]|length) >= 16 and ([.sections.files|keys[]|select(test("^commands/[^/]+[.]md$"))]|length) >= 20 and ([.sections.files|keys[]|select(test("^skills/[^/]+/SKILL[.]md$"))]|length) >= 6'
for ev in SessionStart UserPromptSubmit; do
  n_json="$(jq "[.hooks.$ev[].hooks[]] | length" "$REPO/hooks/hooks.json" 2>/dev/null)"
  n_base="$(jq "[.sections.hook_stdout | keys[] | select(startswith(\"$ev/\"))] | length" "$SHIPPED" 2>/dev/null)"
  if [ -n "$n_json" ] && [ "$n_json" = "$n_base" ]; then ok "every $ev hook of hooks/hooks.json is accounted for in the baseline ($n_json)"; else bad "$ev hooks: hooks.json has ${n_json:-?}, the baseline has ${n_base:-?}"; fi
done
chk "every hook the baseline did not run says why" jqf "$SHIPPED" '[.sections.hook_stdout[] | select(.run == false) | select((.skipped|type) != "string" or (.skipped|length) == 0)] | length == 0'
chk "the caveman hooks are among the ones that ran" jqf "$SHIPPED" '[.sections.hook_stdout | to_entries[] | select(.key|test("-(caveman-rules|caveman-level-context)$")) | select(.value.run == true)] | length == 2'
chk "an agent file's baseline hash is the independent hash of the file" [ "$(jq -r '.sections.files["agents/heimdall.md"].sha256' "$SHIPPED" 2>/dev/null)" = "$(sha_file "$REPO/agents/heimdall.md")" ]
CAN="$T/canary"; mkdir -p "$CAN/.heimdall"; printf 'ledger-row\n' > "$CAN/.heimdall/ledger.db"; printf 'keep\n' > "$CAN/note"
rules_independent="$(env -i PATH="$PATH" HOME="$CAN" HEIMDALL_HOME="$CAN/.heimdall" "$REPO/bin/heimdall-caveman" rules 2>/dev/null | python3 -I -c 'import hashlib,sys; print(hashlib.sha256(sys.stdin.buffer.read()).hexdigest())')"
chk "the baseline's caveman rules are what bin/heimdall-caveman rules prints in an empty HOME" [ "$(jq -r '.sections.caveman.rules.sha256' "$SHIPPED" 2>/dev/null)" = "$rules_independent" ]
CAN_BEFORE="$(snap "$CAN")"
GIT_BEFORE="$(git -C "$REPO" status --porcelain 2>/dev/null)"
START="$(date +%s)"
( export HOME="$CAN" HEIMDALL_HOME="$CAN/.heimdall" CANARY_LEAK=leaked CLAUDE_PLUGIN_ROOT=/nonexistent CLAUDE_PROJECT_DIR=/nonexistent; run real check )
LASTRUN=real
ELAPSED=$(( $(date +%s) - START ))
chk "THE GATE: this tree's injected context equals the baseline (check exits 0)" rc_is real 0
chk "the gate says PASS" oh real 'lean-context-parity: PASS'
chk "the real run left the caller's HOME and HEIMDALL_HOME byte-identical" [ "$(snap "$CAN")" = "$CAN_BEFORE" ]
chk "the real run left the repo's work tree status unchanged" [ "$(git -C "$REPO" status --porcelain 2>/dev/null)" = "$GIT_BEFORE" ]
printf '  (real-tree check took %ss)\n' "$ELAPSED"

RC="$T/rc"; mkdir -p "$RC"
for d in agents commands skills hooks; do cp -R "$REPO/$d" "$RC/$d"; done
cp "$REPO/settings.json" "$RC/settings.json"
run rc0 check --root "$RC" --baseline "$SHIPPED" --sections files,settings,hooks_json
chk "a copy of the real tree at another path is as green as the tree" rc_is rc0 0
printf '\n' >> "$RC/agents/coder.md"
run rc1 check --root "$RC" --baseline "$SHIPPED" --sections files
chk "one added newline in agents/coder.md turns the real baseline RED" rc_is rc1 1
chk "...and names agents/coder.md" oh rc1 'changed  files  agents/coder.md'
cp "$REPO/agents/coder.md" "$RC/agents/coder.md"
rm "$RC/commands/save.md"
run rc2 check --root "$RC" --baseline "$SHIPPED" --sections files
chk "a removed command turns the real baseline RED, named as missing" oh rc2 'missing  files  commands/save.md'
cp "$REPO/commands/save.md" "$RC/commands/save.md"
printf ' ' >> "$RC/hooks/hooks.json"
run rc3 check --root "$RC" --baseline "$SHIPPED" --sections hooks_json
chk "a changed hooks.json turns the real baseline RED" rc_is rc3 1

echo
echo "lean-context-parity: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
