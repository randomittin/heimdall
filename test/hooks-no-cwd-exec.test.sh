#!/usr/bin/env bash
# test/hooks-no-cwd-exec.test.sh
#
# hooks/hooks.json must never EXECUTE, SOURCE or COMPILE code that lives in the
# repo a session happens to be working in.
#
# THE HOLE (security review of 2e481b64, "untrusted-code-execution in
# hooks/hooks.json"): every hook command resolved its plugin root as
#     ${CLAUDE_PLUGIN_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}
# and then ran "$root/bin/<script>" (and sourced "$root/bin/lib/hook-enabled.sh").
# With CLAUDE_PLUGIN_ROOT unset that root is the toplevel of whatever repo the
# session's cwd is in, so a cloned repository that ships bin/heimdall-precheck-bash
# (or any other script name a hook calls) got code execution on every tool call,
# before the user had read a line of it.
#
# THE RULE pinned here: a hook resolves the plugin root from CLAUDE_PLUGIN_ROOT or
# from the install the plugin itself controls ($HOME/.heimdall, where install.sh
# clones it) -- never from the cwd. No cwd-derived path is safe as a trust root: a
# "this repo is heimdall" marker inside the repo can be shipped by any repo.
#
# WHEN NO ROOT RESOLVES (case 8), per gate, and why:
#   * the gates that can refuse -- Bash commit/push precheck, Agent spawn precheck,
#     pasted-credential filter, credential-read guard, lint-config guard -- FAIL
#     OPEN with one loud stderr line. Heimdall's gates are its own repo policy:
#     there is nothing of ours to run in a repo that is not ours, and failing
#     closed on every Bash call / prompt / read would brick the session. The native
#     pre-push hook and CI stay the fail-closed backstop where it matters.
#   * the Write|Edit stub gate FAILS CLOSED (it always did): its scanner IS the
#     gate, content it cannot scan must not be written, and the block names why.
# Every advisory / bookkeeping hook simply does nothing.
#
# HOW: every command in hooks.json is run (bash -c, as Claude Code does) from
# inside a hostile clone -- a git repo with a planted stand-in for EVERY script and
# library a hook command names, plus the state files that carry each hook past its
# early-exit file test. Each plant appends its own name to a marker file when it
# runs or is sourced, so "what executed, from where" is a file, not a guess.

set -u

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOOKS_JSON="${HMD_TEST_HOOKS_JSON:-$REPO/hooks/hooks.json}"

PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; [ -n "${2:-}" ] && printf '       %s\n' "$2"; }

command -v jq >/dev/null 2>&1   || { echo "FATAL: jq is required"; exit 1; }
command -v perl >/dev/null 2>&1 || { echo "FATAL: perl is required"; exit 1; }
[ -f "$HOOKS_JSON" ] || { echo "FATAL: $HOOKS_JSON not found"; exit 1; }

TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT

echo "hooks-no-cwd-exec"

# -- 1. every hook command, one file each -------------------------------------
CMDDIR="$TMPROOT/cmds"; mkdir -p "$CMDDIR"
N="$(jq '[.hooks[][] | .hooks[]?] | length' "$HOOKS_JSON")"
i=0
while [ "$i" -lt "$N" ]; do
  jq -r --argjson i "$i" '[.hooks[][] | .hooks[]? | .command][$i]' "$HOOKS_JSON" > "$CMDDIR/$(printf '%03d' "$i").cmd"
  i=$((i + 1))
done
if [ "$N" -ge 40 ]; then
  ok "1. hooks.json yields $N hook commands to audit"
else
  bad "1. only $N hook commands found (expected >= 40) -- the audit would be vacuous"; exit 1
fi

# -- 2. static: no command derives a root (or anything executable) from the cwd --
STATIC="$(grep -nE 'show-toplevel|pwd\)|\$PWD|`pwd`|[ "]\./bin/' "$CMDDIR"/*.cmd | cut -c1-170 | head -3)"
if [ -z "$STATIC" ]; then
  ok "2. no hook command derives a path from the session's git toplevel or cwd"
else
  bad "2. a hook command derives a path from the session's repo/cwd" "$STATIC"
fi

# -- 3. the planted tree -------------------------------------------------------
SCRIPTS="$TMPROOT/scripts.txt"
grep -ohE '(bin|hooks|sentinels)/[A-Za-z0-9._/-]+' "$CMDDIR"/*.cmd | grep -vE '\.(c|json)$|/$' | sort -u > "$SCRIPTS"
NS="$(wc -l < "$SCRIPTS" | tr -d ' ')"
if [ "$NS" -ge 30 ]; then
  ok "3. $NS distinct scripts/libraries are named by the hook commands (all of them get planted)"
else
  bad "3. only $NS scripts named (expected >= 30)"; exit 1
fi

MARKS="$TMPROOT/marks"; mkdir -p "$MARKS"

# plant <root> <tag>: stand-ins for every script a hook names. Each appends "<rel>"
# to $HMD_MARKS_DIR/<tag> when it runs or is sourced. The two libraries define the
# functions their callers expect and never `exit` (that would end the sourcing hook).
plant() {
  local root="$1" tag="$2" rel
  while IFS= read -r rel; do
    mkdir -p "$root/$(dirname "$rel")"
    case "$rel" in
      bin/lib/*.sh)
        { printf '#!/bin/sh\nprintf "%%s\\n" "%s" >> "$HMD_MARKS_DIR/%s"\n' "$rel" "$tag"
          case "$rel" in
            */hook-enabled.sh)           printf 'hmd_hook_enabled() { return 0; }\n' ;;
            */heimdall-stub-patterns.sh) printf 'heimdall_stub_exempt_path() { return 1; }\nheimdall_stub_match() { cat >/dev/null; }\n' ;;
          esac
        } > "$root/$rel" ;;
      *) printf '#!/bin/sh\nprintf "%%s\\n" "%s" >> "$HMD_MARKS_DIR/%s"\nexit 0\n' "$rel" "$tag" > "$root/$rel" ;;
    esac
    chmod +x "$root/$rel"
  done < "$SCRIPTS"
}

# a hostile clone: the plants, plus every state file that carries a hook past its early-exit file test
FOREIGN="$TMPROOT/foreign"; mkdir -p "$FOREIGN"; ( cd "$FOREIGN" && git init -q )
plant "$FOREIGN" foreign
mkdir -p "$FOREIGN/.heimdall/ui" "$FOREIGN/.heimdall/app" "$FOREIGN/.planning" "$FOREIGN/evals/oracles/x"
printf '{"id":"1","text":"hi"}\n' > "$FOREIGN/.heimdall/ui/inbox.jsonl"
printf '{}\n' > "$FOREIGN/.heimdall/ui/stop-request.json"
printf '{}\n' > "$FOREIGN/.heimdall/app/connect.json"
printf '# checkpoint\n' > "$FOREIGN/.planning/CHECKPOINT.md"
printf '{"status":"fail"}\n' > "$FOREIGN/evals/oracles/x/report.json"

EMPTY_HOME="$TMPROOT/home-empty"; mkdir -p "$EMPTY_HOME"
PLUGIN_ROOT="$TMPROOT/plugin-root"; plant "$PLUGIN_ROOT" plugin
HOME_INSTALL="$TMPROOT/home-install"; plant "$HOME_INSTALL/.heimdall" install
STALE_ROOT="$TMPROOT/stale-root"; mkdir -p "$STALE_ROOT"
PAYLOAD='{"tool_name":"Write","tool_input":{"file_path":"/tmp/hmd-x.py","content":"x = 1"},"session_id":"s1","transcript_path":"/dev/null","source":"startup"}'

# run_all <ENV...>: every hook command once; cwd = the hostile clone; stdin = a tool payload; alarm-bounded
run_all() {
  local f
  for f in "$CMDDIR"/*.cmd; do
    ( cd "$FOREIGN" && printf '%s' "$PAYLOAD" | env "$@" HMD_MARKS_DIR="$MARKS" CLAUDE_PROJECT_DIR="$FOREIGN" HEIMDALL_HOME="$TMPROOT/state" perl -e 'alarm 30; exec @ARGV' bash -c "$(cat "$f")" ) >/dev/null 2>&1
  done
  sleep 1   # background hooks ( ... & ) get a moment to land their markers
}

REP="bin/heimdall-precheck-bash bin/heimdall-precheck-agent bin/heimdall-secret-filter bin/secret-read-guard bin/heimdall-lintconfig-guard bin/parallel-gate bin/heimdall-caveman bin/heimdall-precheck-edit bin/heimdall-inbox-deliver bin/heimdall-presence bin/edit-tracker bin/lib/hook-enabled.sh"
missing_reps() {  # missing_reps <tag> -> the representative scripts that did NOT run from that root
  local r miss=""
  for r in $REP; do grep -qxF "$r" "$MARKS/$1" 2>/dev/null || miss="$miss $r"; done
  printf '%s' "$miss"
}
foreign_ran() { sort -u "$MARKS/foreign" 2>/dev/null | tr '\n' ' ' | cut -c1-300; }

# -- 4. no root anywhere: nothing the clone ships may run ---------------------
rm -f "$MARKS"/*
run_all -u CLAUDE_PLUGIN_ROOT HOME="$EMPTY_HOME"
if [ ! -e "$MARKS/foreign" ]; then
  ok "4. CLAUDE_PLUGIN_ROOT unset, nothing installed, cwd = a hostile clone: none of its $NS planted scripts is executed or sourced"
else
  bad "4. a hook executed code from the session's repo" "ran from the clone: $(foreign_ran)"
fi

# -- 5. control: CLAUDE_PLUGIN_ROOT set -> the PLUGIN's scripts run, the clone's never do
rm -f "$MARKS"/*
run_all CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" HOME="$EMPTY_HOME"
miss="$(missing_reps plugin)"
if [ ! -e "$MARKS/foreign" ] && [ -z "$miss" ]; then
  ok "5. CLAUDE_PLUGIN_ROOT set: the plugin's scripts run (so case 4 is not vacuous) and the clone's never do"
else
  bad "5. with CLAUDE_PLUGIN_ROOT set" "ran from the clone: $(foreign_ran) | plugin scripts that did not run:$miss"
fi

# -- 6. CLAUDE_PLUGIN_ROOT unset but the plugin is installed at ~/.heimdall -----
rm -f "$MARKS"/*
run_all -u CLAUDE_PLUGIN_ROOT HOME="$HOME_INSTALL"
miss="$(missing_reps install)"
if [ ! -e "$MARKS/foreign" ] && [ -z "$miss" ]; then
  ok "6. CLAUDE_PLUGIN_ROOT unset, plugin installed at \$HOME/.heimdall: the install's scripts run, the clone's never do"
else
  bad "6. install-dir fallback" "ran from the clone: $(foreign_ran) | install scripts that did not run:$miss"
fi

# -- 7. CLAUDE_PLUGIN_ROOT set but stale (a removed plugin cache dir) -----------
rm -f "$MARKS"/*
run_all CLAUDE_PLUGIN_ROOT="$STALE_ROOT" HOME="$EMPTY_HOME"
if [ ! -e "$MARKS/foreign" ]; then
  ok "7. CLAUDE_PLUGIN_ROOT set but stale (no scripts there): still nothing from the clone runs"
else
  bad "7. a stale CLAUDE_PLUGIN_ROOT fell through to the session's repo" "ran from the clone: $(foreign_ran)"
fi

# -- 8. no root resolves: refusing gates fail open LOUDLY, the stub gate fails closed
cmd_with() { grep -lF -- "$1" "$CMDDIR"/*.cmd | head -1; }
unresolved() {  # unresolved <fragment> -> that hook, no root anywhere; rc/stdout/stderr in $TMPROOT/u.*
  local f; f="$(cmd_with "$1")"
  [ -n "$f" ] || { printf '1' > "$TMPROOT/u.rc"; : > "$TMPROOT/u.out"; printf 'no hook command names %s\n' "$1" > "$TMPROOT/u.err"; return 0; }
  ( cd "$FOREIGN" && printf '%s' "$PAYLOAD" | env -u CLAUDE_PLUGIN_ROOT HOME="$EMPTY_HOME" HMD_MARKS_DIR="$MARKS" CLAUDE_PROJECT_DIR="$FOREIGN" bash -c "$(cat "$f")" ) >"$TMPROOT/u.out" 2>"$TMPROOT/u.err"
  printf '%s' "$?" > "$TMPROOT/u.rc"
}
c8_bad=""
for frag in bin/heimdall-precheck-bash bin/heimdall-precheck-agent bin/heimdall-secret-filter bin/secret-read-guard bin/heimdall-lintconfig-guard; do
  unresolved "$frag"
  { [ "$(cat "$TMPROOT/u.rc")" = 0 ] && [ ! -s "$TMPROOT/u.out" ] && grep -q '^heimdall: .*not found' "$TMPROOT/u.err" && grep -q 'UNCHECKED' "$TMPROOT/u.err"; } \
    || c8_bad="$c8_bad $frag(rc=$(cat "$TMPROOT/u.rc") stdout=$(head -c 60 "$TMPROOT/u.out") stderr=$(head -c 100 "$TMPROOT/u.err"))"
done
if [ -z "$c8_bad" ]; then
  ok "8a. no root: Bash precheck, Agent precheck, credential filter, credential-read guard and lint-config guard fail open, rc 0, stdout empty, stderr says UNCHECKED"
else
  bad "8a. a refusing gate passed silently (or errored) with no plugin root:$c8_bad"
fi
unresolved heimdall-stub-patterns.sh
if [ "$(cat "$TMPROOT/u.rc")" = 2 ] && grep -q 'failing closed' "$TMPROOT/u.err"; then
  ok "8b. no root: the Write|Edit stub gate fails CLOSED (rc 2) and says why on stderr"
else
  bad "8b. the stub gate must fail closed when its scanner cannot load" "rc=$(cat "$TMPROOT/u.rc") stderr=$(head -c 160 "$TMPROOT/u.err")"
fi

printf '\n  hooks-no-cwd-exec: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
