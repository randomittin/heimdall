#!/usr/bin/env bash
# Journey 09 -- come back to a session: quit hmd, run `hmd --resume`, and be in the same conversation again (`hmd --help` "heimdall --resume [id]: Resume last session
# (conversation + .planning state); a background session is re-attached", CHANGELOG "`hmd --resume` re-attaches a conversation that is running in the background",
# commands/save.md "the next `heimdall` run resumes exactly where you left off").
#
#   A developer works in their project with hmd, quits, and some time later comes back to it:
#     1. `hmd` starts a NEW conversation with the heimdall agent and its plugin; quitting ends hmd with claude's own status; nothing is resumed or attached
#     2. `hmd --resume` with nothing running in the background continues the LAST conversation (claude --continue) with the same agent and plugin, says it found the
#        project's state, and tells claude to restore the goal the session left
#     3. a conversation left running in the background is one `claude --continue` refuses: `hmd agents` lists this project's background sessions (running and exited;
#        not another project's, not the developer's own terminal) with the command that re-attaches, and `hmd --resume` re-attaches the running one (`claude attach <id>`)
#        instead of starting a conversation beside it
#     4. with several running, `hmd --resume` re-attaches the one worked in last (latest transcript write, not latest start); `hmd --resume <name|id>` picks one; a name
#        that matches nothing is said and the last conversation is continued; `--foreground` continues it without asking Claude Code for its sessions
#     5. a Claude Code that cannot list its sessions does not break the resume: the last conversation is continued, one line on stderr names `claude attach <id>`, and
#        `hmd agents` says what it needs (exit 3)
#
# Engines reused: test/hmd-resume-attach.test.sh section 3 (the real launcher, a fake claude), bin/heimdall-bg-sessions (how `claude agents --json` is read).
# The fake claude is lib.sh's: it records every call. A thin front adds the two things hmd cannot do without, an answer from Claude Code's background service
# (`agents --json`) and a copy of the preamble file the launcher hands claude, which the launcher deletes when it exits.
# Mutants (test/use-cases/mutants.list): the resume never re-attaches a background session, the resume forgets to continue the last conversation.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib.sh
. "$HERE/../lib.sh"
uc_begin 09_resume_a_session
uc_tree
uc_fakebin
uc_sandbox resume

HMD="$UC_TREE/bin/heimdall"
TREE_REAL="$(cd "$UC_TREE" && pwd -P)"    # the launcher resolves its own path, so --plugin-dir is the real one
GOAL="checkout returns 201 and all tests pass"
SID_REFACTOR=11111111-1111-4111-8111-111111111111
SID_DOCS=22222222-2222-4222-8222-222222222222
SID_SPIKE=33333333-3333-4333-8333-333333333333
SID_BILLING=44444444-4444-4444-8444-444444444444
SID_TERMINAL=55555555-5555-4555-8555-555555555555
NOW="$(date +%s)"

# a developer who set hmd up long ago and is signed in to Claude Code; their project is an ordinary git repo
mkdir -p "$UC_HOME/.heimdall"
: > "$UC_HOME/.heimdall/setup-done"
printf '{"oauthAccount":{"accountUuid":"00000000-0000-4000-8000-000000000000"}}\n' > "$UC_HOME/.claude.json"
PROJ="$UC_WORK/shop-api"
mkdir -p "$PROJ" "$UC_WORK/billing-service"
g() { uc_run "$UC_HOME" "$PROJ" -- git "$@"; }
g init -q
g config user.email dev@example.com
g config user.name Dev
g config commit.gpgsign false
printf '# shop api\n' > "$PROJ/README.md"
g add README.md
g commit -q -m "start the shop api"
uc_rc "(setup) the project is a git repo with one commit" 0

# Claude Code, as far as hmd can tell: lib.sh's fake first (it records the call), then the background service's answer and a copy of the preamble file
CC="$UC_ROOT/cc"
mkdir -p "$CC"
cat > "$CC/claude" <<'EOF'
#!/usr/bin/env bash
"$UC_BASE_CLAUDE" "$@"
rc=$?
prev=""
for a in "$@"; do
  if [ "$prev" = --append-system-prompt-file ] && [ -r "$a" ]; then cp "$a" "$UC_PREAMBLE_COPY"; fi
  prev="$a"
done
if [ "${1:-}" = agents ] && [ -n "${UC_AGENTS_JSON:-}" ]; then cat "$UC_AGENTS_JSON"; fi
exit "$rc"
EOF
chmod +x "$CC/claude"
UC_PATH="$CC:$UC_PATH"

LISTING="$UC_ROOT/agents.json"           # what `claude agents --json` answers when it can
LISTED=""                                # the file it answers from; empty: this Claude Code cannot list its sessions
PRE="$UC_ROOT/preamble.last"             # the preamble the last launch handed claude
# hmd ARGS... -- the developer runs hmd in the project. What claude was asked lands in $UC_CLAUDE_LOG (emptied first), the preamble it was handed in $PRE (removed first).
hmd() {
  : > "$UC_CLAUDE_LOG"
  rm -f "$PRE"
  uc_run "$UC_HOME" "$PROJ" UC_BASE_CLAUDE="$UC_BIN/claude" UC_AGENTS_JSON="$LISTED" UC_PREAMBLE_COPY="$PRE" -- "$HMD" "$@"
}
# entry KIND ID SESSION NAME STATE STATUS AGE_SECONDS CWD -- one entry of `claude agents --json`; an empty field is left out, and no STATUS means the process exited
entry() {
  jq -n --arg kind "$1" --arg id "$2" --arg sid "$3" --arg name "$4" --arg state "$5" --arg status "$6" --argjson age "$7" --arg cwd "$8" --argjson now "$NOW" \
    '{kind: $kind, sessionId: $sid, cwd: $cwd, startedAt: (($now - $age) * 1000)}
     + (if $id == "" then {} else {id: $id} end) + (if $name == "" then {} else {name: $name} end)
     + (if $state == "" then {} else {state: $state} end) + (if $status == "" then {} else {pid: 4242, status: $status} end)'
}
listing() { jq -s '.' > "$LISTING"; }

# 1. a plain hmd starts a new conversation, and the developer quits
hmd
uc_rc "hmd in the project starts a session; the developer quits and hmd ends with claude's status" 0
uc_has "a plain hmd starts a NEW conversation: the heimdall agent with its plugin" "$UC_CLAUDE_LOG" "^claude --agent heimdall .*--plugin-dir $TREE_REAL "
uc_lacks "…and resumes or attaches nothing" "$UC_CLAUDE_LOG" ' --(continue|resume)( |$)|^claude attach '
uc_has "(control) claude was handed hmd's preamble for this project" "$PRE" '^PROJECT: '
uc_lacks "…which does not claim a resume" "$PRE" 'heimdall resumed'

# the session saved its progress (/hmd:save) and set a goal, as its agent does with heimdall-state
mkdir -p "$PROJ/.planning"
printf '# State\ncurrent_phase: 2\nphase: checkout endpoint\n' > "$PROJ/.planning/STATE.md"
uc_run "$UC_HOME" "$PROJ" -- "$UC_TREE/bin/heimdall-state" init
uc_rc "(setup) the session left a state file in the project" 0
uc_run "$UC_HOME" "$PROJ" -- "$UC_TREE/bin/heimdall-state" goal-set "$GOAL" agent
uc_rc "(setup) …and a goal: $GOAL" 0

# 2. hmd --resume, nothing running in the background: the last conversation, with the project's state
echo '[]' > "$LISTING"; LISTED="$LISTING"
hmd --resume
uc_rc "hmd --resume with nothing running in the background" 0
uc_has "the LAST conversation is continued, with the same agent and plugin" "$UC_CLAUDE_LOG" "^claude --continue --agent heimdall .*--plugin-dir $TREE_REAL "
uc_lacks "…and nothing is attached" "$UC_CLAUDE_LOG" '^claude attach '
uc_has "it says it found the project's state" "$UC_OUT" 'Resuming from \.planning/STATE\.md'
uc_has "…and that the goal comes back" "$UC_OUT" 'Goal restored'
uc_has "claude is told this is a resume" "$PRE" '^heimdall resumed\.$'
uc_has "…and to restore the goal the session left" "$PRE" "^/goal ${GOAL}\$"

# 3. a conversation running in the background
{ entry background a1b2c3d4 "$SID_REFACTOR" refactor-auth working busy 7200 "$PROJ"
  entry background c9d0e1f2 "$SID_SPIKE" old-spike stopped "" 90000 "$PROJ"
  entry background 0f0f0f0f "$SID_BILLING" billing-fix working busy 600 "$UC_WORK/billing-service"
  entry interactive "" "$SID_TERMINAL" this-terminal "" busy 60 "$PROJ"; } | listing
hmd agents
uc_rc "hmd agents lists the project's background sessions" 0
uc_has "a running one: id, state, process, age and title" "$UC_OUT" 'a1b2c3d4 +working +busy +2h +refactor-auth'
uc_has "an exited one, marked as exited" "$UC_OUT" 'c9d0e1f2 +stopped +exited +1d +old-spike'
uc_lacks "not another project's session, not the developer's own terminal" "$UC_OUT" 'billing-fix|this-terminal'
uc_has "the command that re-attaches the running one" "$UC_OUT" 'Re-attach: hmd --resume a1b2c3d4 +\(or: claude attach a1b2c3d4\)'
hmd --resume
uc_rc "hmd --resume with a conversation running in the background" 0
uc_has "the running session is re-attached with claude attach <id>" "$UC_CLAUDE_LOG" '^claude attach a1b2c3d4$'
uc_lacks "…and no conversation is started beside it (claude --continue would be refused)" "$UC_CLAUDE_LOG" '^claude --(continue|agent|resume)( |$)'
uc_has "one line says which session was re-attached" "$UC_OUT" 're-attaching to background session a1b2c3d4 \(refactor-auth\)'

# 4. several running: the one worked in last, or the one asked for
TRANSCRIPTS="$UC_HOME/.claude/projects/$(printf '%s' "$PROJ" | tr -c 'A-Za-z0-9' '-')"
mkdir -p "$TRANSCRIPTS"
: > "$TRANSCRIPTS/$SID_REFACTOR.jsonl"; touch -t 202602010000 "$TRANSCRIPTS/$SID_REFACTOR.jsonl"   # refactor-auth: started first, written to last
: > "$TRANSCRIPTS/$SID_DOCS.jsonl"; touch -t 202601010000 "$TRANSCRIPTS/$SID_DOCS.jsonl"           # docs-pass: started later, written to before it
{ entry background a1b2c3d4 "$SID_REFACTOR" refactor-auth working busy 7200 "$PROJ"
  entry background e5f6a7b8 "$SID_DOCS" docs-pass "done" idle 600 "$PROJ"; } | listing
hmd --resume
uc_rc "hmd --resume with two conversations running" 0
uc_has "the one worked in last is re-attached, not the one started last" "$UC_CLAUDE_LOG" '^claude attach a1b2c3d4$'
uc_has "…with a note that there was nothing to pick on" "$UC_OUT" '2 background sessions and no terminal to pick on'
hmd --resume docs
uc_rc "hmd --resume docs" 0
uc_has "a name picks that session although another was worked in more recently" "$UC_CLAUDE_LOG" '^claude attach e5f6a7b8$'
hmd --resume e5f6
uc_rc "hmd --resume e5f6" 0
uc_has "an id prefix picks it too" "$UC_CLAUDE_LOG" '^claude attach e5f6a7b8$'
hmd --resume nosuch
uc_rc "hmd --resume nosuch" 0
uc_has "a name that matches nothing is said, with the way to list them" "$UC_OUT" 'no running background session matches "nosuch".*hmd agents'
uc_has "…and the last conversation is continued instead" "$UC_CLAUDE_LOG" '^claude --continue --agent heimdall '
uc_lacks "…with nothing attached" "$UC_CLAUDE_LOG" '^claude attach '
hmd --resume --foreground
uc_rc "hmd --resume --foreground" 0
uc_has "the last conversation is continued here although two are running" "$UC_CLAUDE_LOG" '^claude --continue --agent heimdall '
uc_lacks "…without asking Claude Code for its sessions or attaching one" "$UC_CLAUDE_LOG" '^claude (agents|attach)( |$)'

# 5. a Claude Code that cannot list its sessions
LISTED=""
hmd --resume
uc_rc "hmd --resume with a Claude Code that cannot list its sessions" 0
uc_has "the last conversation is continued, as before background sessions were known" "$UC_CLAUDE_LOG" '^claude --continue --agent heimdall '
uc_has "one line says how to attach by hand" "$UC_ERR" 'could not list background sessions.*claude attach <id>'
hmd agents
uc_rc "hmd agents with a Claude Code that cannot list its sessions" 3
uc_has "…says what it needs" "$UC_ERR" 'needs a Claude Code with'

if [ ! -s "$UC_SECURITY_LOG" ]; then uc_ok "the keychain was never asked"; else uc_bad "a launch asked the keychain" "$(head -c 200 "$UC_SECURITY_LOG")"; fi

uc_finish
