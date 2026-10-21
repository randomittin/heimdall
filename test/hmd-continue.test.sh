#!/usr/bin/env bash
# test/hmd-continue.test.sh
#
# Proof for /hmd:continue -- /compact and /continue in one move.
#
# A command, skill or hook can NOT run /compact (only the user types it), PreCompact cannot inject
# context, and SessionStart with source "compact" CAN (hookSpecificOutput.additionalContext). So the
# feature is three parts, and this file grades each head-on:
#   1. THE COMMAND  commands/continue.md exists and is valid, and bin/heimdall-continue is its tool.
#   2. THE WRITE    `heimdall-continue write` takes a fresh checkpoint (the existing writer), records
#                   the session-only next step / gated items through the existing notes seam, writes
#                   .planning/CONTINUE.md and prints ONE `/compact <focus>` line that carries the
#                   next step and stays under the cap, however much state it is given.
#   3. THE INJECT   the SessionStart(compact) path -- the REAL resume-probe hook command taken from
#                   hooks/hooks.json, not a re-typed copy -- injects a fresh handoff in full, once
#                   (the same one never twice), never a stale, future-dated or foreign one, and never
#                   through a link.
#
# Cost: ONE real `heimdall-checkpoint write` (about 4 s, it forks a few hundred processes); everything
# else is the python helper or the probe on a file, so the suite stays near 10 s. Every case runs in a
# throwaway git repo with HEIMDALL_HOME redirected and from a scratch cwd, so the operator's real notes
# store, probe log and .planning are never touched.

set -u

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONT="$REPO/bin/heimdall-continue"
CMD="$REPO/commands/continue.md"
HOOKS="$REPO/hooks/hooks.json"

PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; }

TMPROOT="$(mktemp -d)"
cd "$TMPROOT" || { echo "FATAL: cannot cd into scratch dir"; exit 1; }
unset CLAUDE_PROJECT_DIR HMD_CONTINUE_WINDOW_MIN
export HEIMDALL_HOME="$TMPROOT/hmdhome"
trap 'rm -rf "$TMPROOT"' EXIT

# A pyenv shim costs ~0.2 s per `python3` and this suite (and the checkpoint writer it drives) starts
# python dozens of times: put the real interpreter first on PATH, once, so the budget is spent on
# the feature and not on the shim. Nothing else about the environment changes.
PYREAL="$(python3 -c 'import sys; print(sys.executable)' 2>/dev/null)"
if [ -n "$PYREAL" ] && [ -x "$PYREAL" ]; then
  mkdir -p "$TMPROOT/pybin" && ln -s "$PYREAL" "$TMPROOT/pybin/python3" && PATH="$TMPROOT/pybin:$PATH"
fi

# The real repo's own handoff (a developer may have one): it must be byte-identical at the end.
real_digest() { shasum -a 256 "$REPO/.planning/CONTINUE.md" 2>/dev/null; }
REAL_BEFORE="$(real_digest)"

mk_project() {
  local d="$TMPROOT/$1"
  mkdir -p "$d"
  git -C "$d" init -q
  git -C "$d" config user.email t@t.t
  git -C "$d" config user.name t
  printf 'hello\n' > "$d/README.md"
  git -C "$d" add README.md
  git -C "$d" commit -qm "initial commit" --no-verify
  mkdir -p "$d/.planning"
  printf '%s' "$d"
}

now_s() { date +%s; }

GOAL='ship /hmd:continue: compact, then resume with full context'
NEXT='run test/hmd-continue.test.sh once, then commit feat(skill) with the CHANGELOG bullet'
AGENT='coder: docs sweep | /tmp/wt/agent-docs | running, 3 files edited'
DECISION='the handoff is one file, .planning/CONTINUE.md, written through the no-follow helper'
GATED='whether the command should also be a skills/ entry'

note_of() { # the stdin note for write/focus
  printf 'goal: %s\nnext: %s\nagent: %s\ndecision: %s\ngated: %s\n' "$GOAL" "$NEXT" "$AGENT" "$DECISION" "$GATED"
}

json_ctx() { # stdin: hook JSON -> the additionalContext text (non-zero when it is not the expected shape)
  python3 -I -c 'import json,sys
d=json.loads(sys.stdin.read())
o=d["hookSpecificOutput"]
assert o["hookEventName"]=="SessionStart"
sys.stdout.write(o["additionalContext"])'
}

echo "hmd-continue"

# ── 1. the command and its tool exist and are valid ─────────────────────────
echo "1. command + tool"
if [ -f "$CMD" ] && [ "$(sed -n 1p "$CMD")" = "---" ] && [ "$(sed -n 2p "$CMD")" = "name: continue" ] \
   && sed -n 3p "$CMD" | grep -qE '^description: .{80,}' && [ "$(sed -n 4p "$CMD")" = "---" ]; then
  ok "1a. commands/continue.md has the frontmatter every command has (name: continue, a real description)"
else
  bad "1a. commands/continue.md missing or its frontmatter is not --- / name: continue / description: ... / ---"
fi
if grep -qF 'bin/heimdall-continue" write' "$CMD" 2>/dev/null && grep -qF '/compact' "$CMD" 2>/dev/null \
   && grep -qiE 'paste' "$CMD" 2>/dev/null && grep -qE 'cannot run `?/compact|can.t run `?/compact|cannot run /compact' "$CMD" 2>/dev/null; then
  ok "1b. the command drives heimdall-continue write, tells the user to paste the /compact line, and says it cannot run /compact itself"
else
  bad "1b. commands/continue.md does not call heimdall-continue write / mention paste / state that a command cannot run /compact"
fi
if [ -x "$CONT" ] && [ -f "$REPO/bin/lib/hmd_continue.py" ] && bash -n "$CONT" 2>/dev/null \
   && python3 -I -c 'import ast,sys; ast.parse(open(sys.argv[1]).read())' "$REPO/bin/lib/hmd_continue.py" 2>/dev/null; then
  ok "1c. bin/heimdall-continue is executable, parses, and its logic file parses"
else
  bad "1c. bin/heimdall-continue (executable launcher) or bin/lib/hmd_continue.py missing or not valid"
fi
if "$CONT" --help 2>&1 | grep -q 'write' && "$CONT" --help 2>&1 | grep -q 'inject' && "$CONT" --help 2>&1 | grep -q 'focus'; then
  ok "1d. --help names write, focus and inject"
else
  bad "1d. --help does not name write / focus / inject"
fi

# ── 2. the /compact line: carries the next step, one line, under the cap ─────
echo "2. the /compact line"
LINE="$(note_of | "$CONT" focus 2>"$TMPROOT/ferr")"; rc=$?
if [ "$rc" = "0" ] && [ "${LINE#/compact }" != "$LINE" ]; then
  ok "2a. focus prints a line that starts with '/compact '"
else
  bad "2a. focus did not print a /compact line (rc=$rc): $(head -c 200 "$TMPROOT/ferr")"
fi
if [ -n "$LINE" ] && [ "$(printf '%s' "$LINE" | wc -l | tr -d ' ')" = "0" ] && [ "${#LINE}" -le 1500 ]; then
  ok "2b. it is ONE line and ${#LINE} chars (cap 1500)"
else
  bad "2b. the line is not one line or is over the cap (${#LINE} chars)"
fi
miss=""
for part in "$NEXT" "$GOAL" "$AGENT" "$DECISION" "$GATED"; do
  case "$LINE" in *"$part"*) ;; *) miss="$miss [$part]" ;; esac
done
if [ -z "$miss" ]; then
  ok "2c. the line carries the exact next step, the goal, the agent with its worktree, the decision and the gated item"
else
  bad "2c. the line lost:$miss"
fi

# an enormous state: 60 decisions + 12 agents + a long next step. The next step must survive; the line must not grow.
BIG_NEXT="$(printf 'step-%03d ' $(seq 1 55))"
BIG="$( { printf 'goal: %s\nnext: %s\n' "$GOAL" "$BIG_NEXT"
          for i in $(seq 1 12); do printf 'agent: agent-%02d | /tmp/wt/agent-%02d | running %s\n' "$i" "$i" "$(printf 'x%.0s' $(seq 1 80))"; done
          for i in $(seq 1 60); do printf 'decision: decision-%02d %s\n' "$i" "$(printf 'y%.0s' $(seq 1 150))"; done
          printf 'gated: %s\n' "$GATED"; } | "$CONT" focus 2>/dev/null)"
BIG_NEXT_TRIM="$(printf '%s' "$BIG_NEXT" | sed 's/ *$//')"
if [ -n "$BIG" ] && [ "${#BIG}" -le 1500 ]; then
  ok "2d. 60 decisions + 12 agents + a long next step still fit: ${#BIG} chars (cap 1500)"
else
  bad "2d. the line is empty or over the cap with a large state (${#BIG} chars)"
fi
case "$BIG" in
  *"$BIG_NEXT_TRIM"*) ok "2e. the next step is kept whole when everything else has to go" ;;
  *) bad "2e. the next step was cut or dropped under pressure" ;;
esac
case "$BIG" in
  *"$GATED"*) ok "2f. gated items outrank decisions: the gated item survived, the decisions were dropped first" ;;
  *) bad "2f. the gated item was dropped before the decisions" ;;
esac
n_dec="$(printf '%s' "$BIG" | grep -o 'decision-[0-9][0-9]' | wc -l | tr -d ' ')"
case "$BIG" in
  *"(+"*) [ "$n_dec" -lt 60 ] && ok "2g. what was dropped is counted on the line ('(+N more ...)'; $n_dec of 60 decisions kept)" || bad "2g. nothing was dropped yet the line says so" ;;
  *) bad "2g. items were dropped without a '(+N more' marker" ;;
esac

# control characters and newlines in a value must never break the pasted line in two
MESSY="$(printf 'goal: g\nnext: first part\twith a tab\r and a CR\nagent: a | /w | s\n' | "$CONT" focus 2>/dev/null)"
if [ -n "$MESSY" ] && [ "$(printf '%s' "$MESSY" | wc -l | tr -d ' ')" = "0" ] && ! printf '%s' "$MESSY" | grep -q "$(printf '\r')"; then
  ok "2h. control characters in the note are flattened: still one line"
else
  bad "2h. a control character survived into the pasted line"
fi
printf 'goal: only a goal\n' | "$CONT" focus >/dev/null 2>"$TMPROOT/ferr"; rc=$?
if [ "$rc" = "2" ] && grep -qi 'next' "$TMPROOT/ferr"; then
  ok "2i. no next step -> exit 2 naming it (the line must carry one)"
else
  bad "2i. a note without a next step was accepted (rc=$rc)"
fi
printf 'goal: g\nnext: n\nwhatever: x\n' | "$CONT" focus >/dev/null 2>"$TMPROOT/ferr"; rc=$?
if [ "$rc" = "2" ] && grep -q 'whatever' "$TMPROOT/ferr"; then
  ok "2j. an unknown key is refused (exit 2, named), never silently dropped"
else
  bad "2j. an unknown key was accepted (rc=$rc)"
fi

# ── 3. write: checkpoint + notes + CONTINUE.md + the line (the one real writer run) ─
echo "3. write"
P="$(mk_project main)"
t0="$(now_s)"
note_of | "$CONT" write --repo "$P" >"$TMPROOT/wout" 2>"$TMPROOT/werr"; rc=$?
t1="$(now_s)"
CK="$P/.planning/CHECKPOINT.md"
CF="$P/.planning/CONTINUE.md"
if [ "$rc" = "0" ] && [ -f "$CF" ] && [ -f "$CK" ] && [ -f "$P/.planning/RESUME-KEY.json" ]; then
  ok "3a. write exits 0 and leaves CHECKPOINT.md, RESUME-KEY.json and CONTINUE.md ($((t1 - t0))s)"
else
  bad "3a. write failed or left files out (rc=$rc): $(head -c 400 "$TMPROOT/werr")"
fi
if sed -n 1p "$CF" 2>/dev/null | grep -qE '^<!-- hmd-continue:v1 id=[0-9a-f]{8} written_ts=[0-9]+ consumed_ts= -->$'; then
  ok "3b. CONTINUE.md opens with the handoff marker: an id, when it was written, not consumed"
else
  bad "3b. CONTINUE.md has no valid marker line: $(sed -n 1p "$CF" 2>/dev/null)"
fi
miss=""
for part in "$GOAL" "$NEXT" "$AGENT" "$DECISION" "$GATED"; do
  grep -qF -- "$part" "$CF" 2>/dev/null || miss="$miss [$part]"
done
if [ -z "$miss" ]; then ok "3c. the handoff carries the goal, next step, agent + worktree, decision and gated item"; else bad "3c. the handoff lost:$miss"; fi
miss=""
for label in 'In progress' 'Gated decisions' 'Held branches' 'Unpushed' 'Open warnings' 'Refuted claims'; do
  grep -q "^- \*\*$label:\*\* " "$CF" 2>/dev/null || miss="$miss [$label]"
done
if grep -q 'What must never be lost' "$CF" 2>/dev/null && [ -z "$miss" ]; then
  ok "3d. the checkpoint's 'What must never be lost' block is in the handoff, all six fields"
else
  bad "3d. the contract block is missing or incomplete in the handoff:$miss"
fi
if grep -qF -- "next: $NEXT" "$CK" 2>/dev/null && grep -qF -- "$GATED" "$CK" 2>/dev/null; then
  ok "3e. the next step and the gated item went through the existing notes seam into CHECKPOINT.md"
else
  bad "3e. the notes did not reach CHECKPOINT.md (the in-progress / gated fields)"
fi
WLINE="$(grep -E '^/compact ' "$TMPROOT/wout")"
if [ "$(grep -cE '^/compact ' "$TMPROOT/wout")" = "1" ] && [ "${#WLINE}" -le 1500 ] && case "$WLINE" in *"$NEXT"*) true ;; *) false ;; esac; then
  ok "3f. stdout holds exactly one /compact line, ${#WLINE} chars, with the next step in it"
else
  bad "3f. stdout does not hold one /compact line with the next step under the cap: $(head -c 300 "$TMPROOT/wout")"
fi
if [ -n "$WLINE" ] && [ "$(tail -n 1 "$TMPROOT/wout")" = "$WLINE" ]; then
  ok "3g. the /compact line is the LAST line printed (nothing after it for the model to mix in)"
else
  bad "3g. something is printed after the /compact line"
fi

# the checkpoint writer failing must not lose the note: handoff written, exit 3, said loudly
ALONE="$TMPROOT/alone"; mkdir -p "$ALONE/bin/lib"
cp "$CONT" "$ALONE/bin/heimdall-continue"
cp "$REPO/bin/lib/hmd_continue.py" "$REPO/bin/lib/hmd_nofollow_write.py" "$ALONE/bin/lib/"
chmod +x "$ALONE/bin/heimdall-continue"
PW="$(mk_project nowriter)"
note_of | "$ALONE/bin/heimdall-continue" write --repo "$PW" >"$TMPROOT/aout" 2>"$TMPROOT/aerr"; rc=$?
if [ "$rc" = "3" ] && [ -f "$PW/.planning/CONTINUE.md" ] && grep -q 'unavailable' "$PW/.planning/CONTINUE.md" \
   && grep -qE '^/compact ' "$TMPROOT/aout" && grep -qi 'checkpoint' "$TMPROOT/aerr"; then
  ok "3h. no checkpoint writer -> exit 3, the handoff and the line are still produced, stderr says the checkpoint is missing"
else
  bad "3h. a missing writer was mishandled (rc=$rc): $(head -c 300 "$TMPROOT/aerr")"
fi

# a link anywhere on the way down is refused, nothing written, no line printed
PL="$(mk_project linked)"
mkdir -p "$TMPROOT/elsewhere"
rm -rf "$PL/.planning"; ln -s "$TMPROOT/elsewhere" "$PL/.planning"
note_of | "$CONT" write --repo "$PL" >"$TMPROOT/lout" 2>"$TMPROOT/lerr"; rc=$?
if [ "$rc" = "4" ] && [ -z "$(ls -A "$TMPROOT/elsewhere")" ] && ! grep -q '^/compact' "$TMPROOT/lout" && grep -qi 'symbolic link' "$TMPROOT/lerr"; then
  ok "3i. a symlinked .planning -> exit 4, nothing written through it, no /compact line, the reason on stderr"
else
  bad "3i. write went through (or mishandled) a symlinked .planning (rc=$rc, elsewhere holds: $(ls -A "$TMPROOT/elsewhere" | tr '\n' ' '))"
fi

# ── 4. the REAL SessionStart hook command from hooks.json: inject once on compact ────
echo "4. the SessionStart(compact) hook"
HOOKCMD="$(python3 -I - "$HOOKS" <<'PY'
import json, sys
def walk(o):
    if isinstance(o, dict):
        if isinstance(o.get("command"), str):
            yield o["command"]
        for v in o.values():
            yield from walk(v)
    elif isinstance(o, list):
        for v in o:
            yield from walk(v)
for c in walk(json.load(open(sys.argv[1]))):
    if "heimdall-resume-probe" in c:
        print(c)
        break
PY
)"
if [ -n "$HOOKCMD" ]; then ok "4a. the resume-probe SessionStart command was found in hooks/hooks.json"; else bad "4a. no heimdall-resume-probe command in hooks/hooks.json"; fi

payload() { printf '{"session_id":"s-cont","transcript_path":"/nonexistent/t.jsonl","cwd":"%s","hook_event_name":"SessionStart","source":"%s","model":"m"}' "$P" "$1"; }
hook_run() { # <source>: runs the hook command exactly as the harness would; stdout -> $TMPROOT/hout
  payload "$1" | CLAUDE_PLUGIN_ROOT="$REPO" CLAUDE_PROJECT_DIR="$P" sh -c "$HOOKCMD" >"$TMPROOT/hout" 2>"$TMPROOT/herr"
}
header_of() { sed -n 1p "$CF"; }

hook_run startup
if grep -q 'resume probe' "$TMPROOT/hout" && ! grep -q '^{' "$TMPROOT/hout" && header_of | grep -q 'consumed_ts= -->'; then
  ok "4b. a plain session start prints the probe verdict as before and leaves the handoff unconsumed"
else
  bad "4b. startup injected (or dropped the verdict): $(head -c 300 "$TMPROOT/hout")"
fi

hook_run compact
CTX="$(json_ctx <"$TMPROOT/hout" 2>"$TMPROOT/jerr")"; jrc=$?
if [ "$jrc" = "0" ] && [ "$(wc -l <"$TMPROOT/hout" | tr -d ' ')" = "1" ]; then
  ok "4c. on compact the hook prints ONE line of hookSpecificOutput JSON (it survives the hook's head -8)"
else
  bad "4c. compact output is not a single-line SessionStart JSON object (rc=$jrc, lines=$(wc -l <"$TMPROOT/hout" | tr -d ' ')): $(head -c 300 "$TMPROOT/hout")"
fi
miss=""
for part in "$GOAL" "$NEXT" "$AGENT" "$DECISION" "$GATED" 'What must never be lost' 'resume probe GREEN'; do
  case "$CTX" in *"$part"*) ;; *) miss="$miss [$part]" ;; esac
done
if [ -z "$miss" ]; then
  ok "4d. additionalContext is the whole handoff: continue note + the contract block + the probe verdict it replaced"
else
  bad "4d. additionalContext lost:$miss"
fi
if header_of | grep -qE 'consumed_ts=[0-9]+ -->$'; then
  ok "4e. the handoff is marked consumed the moment it is injected"
else
  bad "4e. the handoff was not marked consumed: $(header_of)"
fi

hook_run compact
if grep -q 'resume probe' "$TMPROOT/hout" && ! grep -q '^{' "$TMPROOT/hout" && ! grep -qF -- "$NEXT" "$TMPROOT/hout"; then
  ok "4f. a second compaction does NOT re-inject it (plain probe verdict only)"
else
  bad "4f. the consumed handoff was injected again: $(head -c 300 "$TMPROOT/hout")"
fi

# stale handoff through the hook: the same shape that injected above, 31 minutes old -> not injected
set_header() { # <written_ts> <consumed_ts> : rewrites the marker line, keeps the body
  { printf '<!-- hmd-continue:v1 id=%08x written_ts=%s consumed_ts=%s -->\n' $((RANDOM * 32768 + RANDOM)) "$1" "$2"; tail -n +2 "$CF"; } >"$TMPROOT/hdr.tmp" \
    && cat "$TMPROOT/hdr.tmp" >"$CF"
}
set_header "$(( $(now_s) - 31 * 60 ))" ""
hook_run compact
if grep -q 'resume probe' "$TMPROOT/hout" && ! grep -q '^{' "$TMPROOT/hout" && header_of | grep -q 'consumed_ts= -->'; then
  ok "4g. a 31-minute-old handoff is not injected through the hook and stays unconsumed"
else
  bad "4g. a stale handoff was injected: $(head -c 300 "$TMPROOT/hout")"
fi

# ── 5. the freshness window, the once-only rule and the source rule, on the helper itself ─
echo "5. inject matrix"
inj() { # [args]: OUT = stdout, IRC = exit status, stderr -> $TMPROOT/ierr. A "nothing injected" case also demands exit 0, so a tool that never ran cannot pass it.
  OUT="$("$CONT" inject --repo "$P" "$@" </dev/null 2>"$TMPROOT/ierr")"; IRC=$?
}
set_header "$(( $(now_s) - 29 * 60 ))" ""
inj --source compact
if [ "$IRC" = "0" ] && [ -n "$OUT" ] && printf '%s' "$OUT" | json_ctx | grep -qF -- "$NEXT" && header_of | grep -qE 'consumed_ts=[0-9]+ -->$'; then
  ok "5a. 29 minutes old (inside the default 30) -> injected, then consumed"
else
  bad "5a. a 29-minute-old handoff was not injected (rc=$IRC)"
fi
set_header "$(( $(now_s) - 31 * 60 ))" ""
inj --source compact
if [ "$IRC" = "0" ] && [ -z "$OUT" ] && header_of | grep -q 'consumed_ts= -->'; then ok "5b. 31 minutes old -> not injected, not consumed"; else bad "5b. a 31-minute-old handoff was injected (rc=$IRC)"; fi
set_header "$(( $(now_s) - 10 * 60 ))" ""
HMD_CONTINUE_WINDOW_MIN=5 inj --source compact; R5="$IRC"; O5="$OUT"
HMD_CONTINUE_WINDOW_MIN=15 inj --source compact; R15="$IRC"; O15="$OUT"
if [ "$R5" = "0" ] && [ -z "$O5" ] && [ "$R15" = "0" ] && [ -n "$O15" ]; then
  ok "5c. HMD_CONTINUE_WINDOW_MIN moves the boundary both ways (10 min old: stale at 5, fresh at 15)"
else
  bad "5c. the window knob did not behave (window 5 -> rc=$R5 '${O5:0:20}', window 15 -> rc=$R15 '${O15:0:20}')"
fi
set_header "$(( $(now_s) + 3600 ))" ""
inj --source compact
if [ "$IRC" = "0" ] && [ -z "$OUT" ]; then ok "5d. a handoff dated in the future (a planted file) is never fresh"; else bad "5d. a future-dated handoff was injected (rc=$IRC)"; fi
set_header "$(( $(now_s) - 60 ))" ""
HMD_CONTINUE_WINDOW_MIN=0 inj --source compact
if [ "$IRC" = "0" ] && [ -z "$OUT" ] && header_of | grep -q 'consumed_ts= -->'; then ok "5e. HMD_CONTINUE_WINDOW_MIN=0 turns the injection off"; else bad "5e. window 0 still injected (rc=$IRC)"; fi
HMD_CONTINUE_WINDOW_MIN=abc inj --source compact
if [ "$IRC" = "0" ] && [ -n "$OUT" ] && grep -q 'HMD_CONTINUE_WINDOW_MIN' "$TMPROOT/ierr"; then
  ok "5f. a garbage window falls back to 30 minutes and says so on stderr (never a silent off)"
else
  bad "5f. a garbage window was mishandled: rc=$IRC out='${OUT:0:20}' err=$(head -c 200 "$TMPROOT/ierr")"
fi
set_header "$(( $(now_s) - 60 ))" "$(( $(now_s) - 30 ))"
inj --source compact
if [ "$IRC" = "0" ] && [ -z "$OUT" ]; then ok "5g. an already-consumed handoff is never injected again"; else bad "5g. a consumed handoff was injected (rc=$IRC)"; fi
set_header "$(( $(now_s) - 60 ))" ""
inj --source clear; RA="$IRC"; OA="$OUT"
inj --source startup; RB="$IRC"; OB="$OUT"
inj; RC="$IRC"; OC="$OUT"
if [ "$RA$RB$RC" = "000" ] && [ -z "$OA$OB$OC" ] && header_of | grep -q 'consumed_ts= -->'; then
  ok "5h. only source=compact injects: clear, startup and an unknown source (no payload on stdin) leave it waiting"
else
  bad "5h. a restart that was not a compaction injected the handoff (rc $RA$RB$RC)"
fi
{ printf 'a note somebody wrote by hand, no marker line\n'; tail -n +2 "$CF"; } >"$TMPROOT/foreign.tmp" && cat "$TMPROOT/foreign.tmp" >"$CF"
inj --source compact
if [ "$IRC" = "0" ] && [ -z "$OUT" ] && grep -q 'no handoff marker' "$TMPROOT/ierr"; then ok "5i. a file without the handoff marker is not a handoff and is never injected"; else bad "5i. a marker-less CONTINUE.md was injected (rc=$IRC)"; fi
{ printf '<!-- hmd-continue:v1 id=%08x written_ts=%s consumed_ts= -->\n' 42 "$(now_s)"; printf 'Next step: %s\n' "$NEXT"
  for i in $(seq 1 600); do printf 'filler line %03d %s\n' "$i" "$(printf 'z%.0s' $(seq 1 60))"; done; } >"$CF"
inj --source compact
LEN="$(printf '%s' "$OUT" | json_ctx 2>/dev/null | wc -c | tr -d ' ')"
if [ "$IRC" = "0" ] && [ -n "$OUT" ] && [ "$LEN" -le 10000 ] && printf '%s' "$OUT" | json_ctx | grep -q 'CONTINUE.md'; then
  ok "5j. an oversized handoff is cut to $LEN chars (the harness caps hook context at 10000) with a pointer to the file"
else
  bad "5j. an oversized handoff was injected whole or without a pointer ($LEN chars, rc=$IRC)"
fi

# ── 6. links, and the probe with nothing to inject ──────────────────────────
echo "6. links and the plain path"
printf '<!-- hmd-continue:v1 id=%08x written_ts=%s consumed_ts= -->\nNext step: planted\n' 7 "$(now_s)" >"$TMPROOT/planted.md"
rm -f "$CF"; ln -s "$TMPROOT/planted.md" "$CF"
inj --source compact
if [ "$IRC" = "4" ] && [ -z "$OUT" ] && grep -qi 'symbolic link' "$TMPROOT/ierr" && grep -q 'consumed_ts= -->' "$TMPROOT/planted.md"; then
  ok "6a. a symlinked CONTINUE.md is refused (exit 4, named on stderr), never read through or rewritten"
else
  bad "6a. a symlinked handoff was followed: rc=$IRC out='${OUT:0:30}' err=$(head -c 200 "$TMPROOT/ierr")"
fi
rm -f "$CF"
hook_run compact; rc=$?
if [ "$rc" = "0" ] && grep -q 'resume probe' "$TMPROOT/hout" && ! grep -q '^{' "$TMPROOT/hout" && [ ! -e "$CF" ]; then
  ok "6b. no handoff at all: the hook prints the plain probe verdict, exactly as before this feature"
else
  bad "6b. the plain path changed without a handoff: $(head -c 300 "$TMPROOT/hout")"
fi

# ── 7. the docs name it, and no case wrote into the real repo ───────────────
echo "7. docs and hermeticity"
if grep -q 'heimdall-continue' "$REPO/docs/INVENTORY.md" && grep -q '/hmd:continue' "$REPO/skills/heimdall/SKILL.md" \
   && grep -qE '`continue`' "$REPO/docs/INVENTORY.md" && grep -q '/hmd:continue' "$REPO/CHANGELOG.md"; then
  ok "7a. docs/INVENTORY.md (tool + command), skills/heimdall/SKILL.md and CHANGELOG.md name /hmd:continue"
else
  bad "7a. a doc that lists commands does not mention /hmd:continue / heimdall-continue"
fi
if [ "$REAL_BEFORE" = "$(real_digest)" ]; then
  ok "7b. the real repo's .planning/CONTINUE.md is untouched (hermetic)"
else
  bad "7b. a case wrote into the REAL repo's .planning/CONTINUE.md"
fi

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
