#!/usr/bin/env bash
# bin/lib/hmd_fix_chain.sh -- THE definition of "a finding-fix agent spawn" and of the chain limit: one definition, both callers.
#
# WHAT IT IS. A sourceable file: one jq function and one shell function, so the two places that ask "is this spawn another round of the fix -> finding -> fix loop?" ask it the same way:
#   bin/heimdall-conformance      `fix-chain`: reads the session transcript afterwards and FAILS on more than N consecutive finding-fix spawns inside one release cycle
#   bin/heimdall-precheck-agent   the Agent hook: WARNS on stderr (exit 0, never a deny) when the spawn being made is past N finding-fix spawns of this session
# Two copies of a definition is how a gate starts failing what the warning never mentioned (and the reverse), so there is one. Both callers evaluate the jq text below with jq itself (the tool
# prepends it to its transcript program, the hook runs it over the spawn payload), so the matching engine is shared too, not only the words.
#
# WHY (CLAUDE.md "Release convergence", operator directive 2026-10-21). Measured on 2.4.9: six chained rounds in one evening, each round spawning a fix agent for a MEDIUM/LOW finding that only
# existed because of the previous fix. Only BLOCKER/HIGH findings get a fix agent; MEDIUM/LOW go to the backlog.
#
# THE DEFINITION. A spawn is a finding-fix spawn when its description and its prompt, read together and without regard to case, BOTH
#   name a fix                                    the word fix, fixes, fixed, fixing, fixer, bugfix or hotfix, as a whole word (prefix, suffix, fixture and fixup are not it)
#   reference a review or security finding        the word finding or findings, "security review" (or security-review), or reviewer(s)
# It is deliberately loose, a plain word match with no attempt to understand the task: a false positive costs one stderr line or one spawn named in a report, and the limit is on a RUN of
# them, so a stray match cannot trip it. Tighten the two patterns below and both callers follow.
#
# THE KNOB. HMD_FIX_CHAIN_MAX: how many consecutive finding-fix spawns are allowed; the one past it is the violation. Default 3. A whole number of at most three digits (0 is allowed: every
# finding-fix spawn is then over the limit); anything else is the default, never "off". Set it in the environment the caller runs in.
#
# Every name here starts hmd_fix_chain_ / hmd_finding_ / HMD_FIX_CHAIN_, so sourcing it into a hook cannot collide with the hook's own. Bash 3.2 compatible (macOS /bin/bash) and nounset-safe.

# shellcheck disable=SC2016,SC2034  # the $d / $p / $t below are jq variables (this text is a jq program, not shell); the variable is read by the scripts that source this file
HMD_FIX_CHAIN_JQ='def hmd_finding_fix($d; $p):
  ((($d // "") | tostring) + "\n" + (($p // "") | tostring)) as $t
  | ($t | test("(^|[^A-Za-z])(bug|hot)?fix(es|ed|ing|er)?([^A-Za-z]|$)"; "i"))
    and ($t | test("(^|[^A-Za-z])(findings?|security[ -]review|reviewers?)([^A-Za-z]|$)"; "i"));
'

# hmd_fix_chain_max -- the limit N, a whole number, on stdout: HMD_FIX_CHAIN_MAX when it is one of at most three digits, else the default, 3.
hmd_fix_chain_max() {
  local v="${HMD_FIX_CHAIN_MAX:-}"
  case "$v" in
    '' | *[!0-9]*) printf '3\n' ;;
    *) if [ "${#v}" -le 3 ]; then printf '%s\n' "$((10#$v))"; else printf '3\n'; fi ;;
  esac
}
