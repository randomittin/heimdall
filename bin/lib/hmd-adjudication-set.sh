#!/usr/bin/env bash
# hmd-adjudication-set.sh — SINGLE SOURCE OF TRUTH for which subagent_type /
# agent role is ADJUDICATION (emits a verdict, score, pass/fail, or approval)
# versus GENERATION (writes code, does not itself gate anything).
#
# WHY THIS FILE EXISTS. D2 in
# docs/superpowers/plans/2026-08-29-agent-fallback-coverage.md (§0.3): when a
# parent Claude Code session is launched under a ROUTE verdict,
# ANTHROPIC_BASE_URL points at the local OmniRoute fallback gateway and EVERY
# in-process Agent-tool subagent inherits it -- there is no exec boundary for
# an in-process spawn, so hmd_gate_exec (bin/lib/hmd-gate-endpoint.sh) cannot
# reach it. A verifier/reviewer/security-auditor running on a degraded
# free-tier model emits confident FALSE GREENS -- the one failure this whole
# project exists to prevent. Generation may run compressed; judgment may not
# (see hmd-gate-endpoint.sh's own header) -- this file is how a caller tells
# the two apart.
#
# TWO CALLERS, ONE LIST (this file), so they cannot drift apart:
#   - bin/heimdall-precheck-agent  (PreToolUse/Agent hook -- denies an
#     in-process adjudication spawn when ANTHROPIC_BASE_URL is the live
#     fallback endpoint; Wave 1 Task 1.1)
#   - bin/lib/hmd-route-claude     (per-spawn subprocess gate seam -- pins the
#     real provider directly for a judgment-marked headless spawn; Wave 1
#     Task 1.2, already sources this file defensively via
#     `. "$HRC_LIB_DIR/hmd-adjudication-set.sh"`)
#
# CLASSIFICATION (verbatim from the plan, §1.5's "Adjudication set
# (explicit)"): reviewer, verifier, security-auditor, incident-responder,
# PLUS any subagent_type matching *-review*, *-audit*, *-verif*.
#
# WHY A GLOB ON TOP OF THE FOUR NAMES, NOT JUST THE FOUR NAMES:
#   (a) Real spawns are NAMESPACED (`hmd:reviewer`, never bare `reviewer` --
#       see CLAUDE.md's `description:` vs `name:` convention and this repo's
#       own agents/*.md front matter). Matching is done on the LOCAL name
#       (everything after the last ':') against the four explicit roles, so
#       both a bare and a namespaced form match.
#   (b) Third-party review/audit/verify agents never show up in agents/*.md
#       at all (e.g. `pr-review-toolkit:code-reviewer`,
#       `pr-review-toolkit:silent-failure-hunter`) and would silently escape
#       a four-name allowlist forever. The glob is matched against the FULL,
#       un-stripped subagent_type, so a review/audit/verify-shaped plugin
#       namespace is caught even when the caller adds agents to it later.
#
# Over-matching here (fencing a generation agent that merely LIVES in a
# review-named plugin) is the SAFE direction and is deliberately accepted:
# "a generation agent wrongly fenced is a small cost; a verifier on the free
# tier is a false green." Under-matching is not accepted at all: an
# UNRECOGNIZED type is generation (hmd_is_adjudication returns 1) so a
# missing/broken classification can never brick every spawn on its own --
# staying fail-open on THAT question belongs to each CALLER (see
# bin/heimdall-precheck-agent's own fail-open discipline), not to this file.
#
# Deliberately NOT `set -uo pipefail`: this file is SOURCED into a caller's
# shell (bash and POSIX sh both -- bin/lib/hmd-route-claude sources it from a
# `set -uo pipefail` bash script; a hook may source it from something
# plainer), and a library has no business changing the CALLER's shell options
# out from under it. bin/lib/hmd-gate-endpoint.sh follows the same rule for
# the same reason.
#
# Covered by test/agent-fallback-adjudication.test.sh.

# double-source guard (function is idempotent; skip re-defining on re-source).
[ -n "${_HMD_ADJUDICATION_SET_SH:-}" ] && return 0 2>/dev/null || true
_HMD_ADJUDICATION_SET_SH=1

# The four explicit roles, space-separated, exported for introspection/
# documentation ONLY. hmd_is_adjudication() below is the real classifier -- it
# also matches namespaced forms and the third-party glob patterns this flat
# list cannot express, so a caller must never grep/match against this var
# directly in place of calling the function.
HMD_ADJUDICATION_TYPES="reviewer verifier security-auditor incident-responder"
export HMD_ADJUDICATION_TYPES

# hmd_is_adjudication <subagent_type> -- 0 (true, shell success) if the type
# is adjudication, 1 (false) otherwise, INCLUDING for empty/unset input (an
# absent type is never a positive match -- absence is not evidence).
hmd_is_adjudication() {
  local sat="${1:-}"
  [ -n "$sat" ] || return 1

  # local name = everything after the LAST ':' -- "hmd:reviewer" -> "reviewer";
  # a bare "reviewer" (no colon) is left untouched by this pattern strip.
  local bare="${sat##*:}"

  case "$bare" in
    reviewer|verifier|security-auditor|incident-responder) return 0 ;;
  esac

  # Glob against the FULL, un-stripped type (namespace/plugin prefix included
  # on purpose -- see header, reason (b)).
  case "$sat" in
    *-review*|*-audit*|*-verif*) return 0 ;;
  esac

  return 1
}
