#!/usr/bin/env bash
# Journey 06 -- turn a repo into a gated one with `hmd init`, then try to commit a stub (README "the gate is a plain git pre-push hook, so it holds in any repo",
# CLAUDE.md "Code Quality -- Zero Tolerance" and "Commit attribution").
#
#   A developer has an ordinary git repo and no Claude Code on the machine: git alone is in the loop.
#     1. `hmd init` wires the repo: core.hooksPath points at .heimdall/hooks, the pre-commit, pre-push, post-commit and prepare-commit-msg hooks exist and run,
#        and AGENTS.md tells every coding agent the repo is gated
#     2. a commit of real code goes through, and carries the hmd co-author trailer exactly once
#     3. a commit that introduces an unfinished-code marker is REFUSED: git exits non-zero, no commit is made, a BIFROST block names the gate (stub-scan) and the file,
#        the work stays staged, and `hmd verdict` says deny
#     4. the developer finishes the code, commits again, and it goes through: verdict pass, trailer once
#     5. a commit made with --no-verify skips the gate (by design) but still gets the trailer: the one hook --no-verify does not skip
#
# Engines reused: test/heimdall-init.test.sh (hook wiring), test/pre-commit-stub-gate.test.sh (the stub shapes), test/prepare-commit-msg-trailer.test.sh.
# The marker is assembled at run time so that this file is not itself an unfinished-code marker for the scanners it exercises.
# Mutants (test/use-cases/mutants.list): the marker pattern never matches, the hooks are never wired, the trailer names the wrong account.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib.sh
. "$HERE/../lib.sh"
uc_begin 06_init_a_repo_then_try_to_commit_a_stub
uc_tree
uc_fakebin
rm -f "$UC_BIN/claude"                    # git alone in the loop: no Claude Code anywhere on this PATH
uc_sandbox init

HH="$UC_ROOT/init/heimdall-home"
mkdir -p "$HH"
REPO="$UC_WORK/shop"
TRAILER='Co-Authored-By: runhmd <318965969+runhmd@users.noreply.github.com>'
MARK="TO""DO"
hmd() { uc_run "$UC_HOME" "$REPO" HEIMDALL_HOME="$HH" -- "$UC_TREE/bin/hmd" "$@"; }
g() { uc_run "$UC_HOME" "$REPO" HEIMDALL_HOME="$HH" -- git "$@"; }
commits() { g rev-list --count HEAD; if [ "$UC_RC" -eq 0 ]; then tr -d '\n' < "$UC_OUT"; else printf 0; fi; }
trailers() { g log -1 --format=%B; grep -cFx -- "$TRAILER" "$UC_OUT" || true; }

mkdir -p "$REPO"
g init -q
g config user.email dev@example.com
g config user.name Dev
g config commit.gpgsign false
uc_run "$UC_HOME" "$REPO" -- sh -c 'command -v claude'
if [ "$UC_RC" -ne 0 ]; then uc_ok "(setup) no claude binary on the PATH: git and hmd only"; else uc_bad "(setup) a claude binary is reachable, so this is not a git-alone proof"; fi

# 1. hmd init wires the repo
hmd init
uc_rc "hmd init in an ordinary repo" 0
g config --get core.hooksPath
if [ "$(tr -d '\n' < "$UC_OUT")" = ".heimdall/hooks" ]; then uc_ok "core.hooksPath points at .heimdall/hooks"; else uc_bad "core.hooksPath is '$(tr -d '\n' < "$UC_OUT")'"; fi
missing=""
for h in pre-commit pre-push post-commit prepare-commit-msg; do [ -x "$REPO/.heimdall/hooks/$h" ] || missing="$missing $h"; done
if [ -z "$missing" ]; then uc_ok "the four hooks exist and are executable"; else uc_bad "missing or not executable:$missing"; fi
uc_has "AGENTS.md tells every coding agent the repo is gated" "$REPO/AGENTS.md" 'HEIMDALL:AGENTS:BEGIN'

# 2. real code goes through, with the trailer once
printf 'function add(a, b) { return a + b; }\n' > "$REPO/math.js"
g add math.js
g commit -q -m "add math"
uc_rc "a commit of real code goes through" 0
if [ "$(commits)" = 1 ]; then uc_ok "…and is the repo's first commit"; else uc_bad "expected 1 commit, found $(commits)"; fi
if [ "$(trailers)" = 1 ]; then uc_ok "…and carries the hmd co-author trailer exactly once"; else uc_bad "the trailer count on the first commit is $(trailers), want 1"; fi
hmd verdict --field verdict
if [ "$(tr -d '\n' < "$UC_OUT")" = pass ]; then uc_ok "hmd verdict says pass"; else uc_bad "hmd verdict says '$(tr -d '\n' < "$UC_OUT")', want pass"; fi

# 3. a stub is refused
printf 'function pay(total) { return total; }\n// %s: wire up the payment provider\n' "$MARK" > "$REPO/checkout.js"
g add checkout.js
g commit -q -m "add checkout"
if uc_hang "committing a stub"; then :; elif [ "$UC_RC" -ne 0 ]; then uc_ok "committing an unfinished-code marker is refused (exit $UC_RC)"; else uc_bad "a commit that introduces an unfinished-code marker went through"; fi
if [ "$(commits)" = 1 ]; then uc_ok "…no commit was made"; else uc_bad "the refused commit still landed ($(commits) commits)"; fi
g commit -q -m "add checkout"
uc_has "the BIFROST block names the gate" "$UC_ERR" 'stub-scan'
uc_has "…and the file the stub is in" "$UC_ERR" 'checkout\.js'
g diff --cached --name-only
uc_has "…and the work stays staged" "$UC_OUT" '^checkout\.js$'
hmd verdict --field verdict
if [ "$(tr -d '\n' < "$UC_OUT")" = deny ]; then uc_ok "hmd verdict says deny"; else uc_bad "hmd verdict says '$(tr -d '\n' < "$UC_OUT")', want deny"; fi

# 4. finish the code, commit again
printf 'function pay(total) { return Math.round(total * 100) / 100; }\n' > "$REPO/checkout.js"
g add checkout.js
g commit -q -m "add checkout"
uc_rc "the finished code goes through" 0
if [ "$(commits)" = 2 ]; then uc_ok "…as the second commit"; else uc_bad "expected 2 commits, found $(commits)"; fi
if [ "$(trailers)" = 1 ]; then uc_ok "…with the trailer exactly once"; else uc_bad "the trailer count is $(trailers), want 1"; fi
hmd verdict --field verdict
if [ "$(tr -d '\n' < "$UC_OUT")" = pass ]; then uc_ok "hmd verdict says pass again"; else uc_bad "hmd verdict says '$(tr -d '\n' < "$UC_OUT")', want pass"; fi

# 5. --no-verify skips the gate but not the trailer
printf 'function sub(a, b) { return a - b; }\n' >> "$REPO/math.js"
g add math.js
g commit -q --no-verify -m "add sub"
uc_rc "a --no-verify commit goes through" 0
if [ "$(trailers)" = 1 ]; then uc_ok "…and still carries the trailer exactly once (prepare-commit-msg is the one hook --no-verify does not skip)"; else uc_bad "the --no-verify commit's trailer count is $(trailers), want 1"; fi

uc_finish
