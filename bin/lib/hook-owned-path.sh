#!/usr/bin/env bash
# bin/lib/hook-owned-path.sh — the shared hook-owned path allowlist.
#
# WHAT IT IS. One regex, $HMD_HOOK_OWNED_PATH_RE, and one predicate function,
# hmd_hook_owned_path <path>, naming the exact repo-relative path SHAPES this
# repo's OWN hooks write to — never a suite, never a human, never an agent's own
# code change:
#   .planning/journal/YYYY-MM-DD-haid_<slug>.md            — journal-commit hook
#   .planning/ledger/{activity,verdicts,checkpoints}/haid_<slug>.json
#                                                            — heimdall-activity,
#                                                              heimdall-gate-surface,
#                                                              heimdall-checkpoint
#   .planning/ledger/collisions/<slug>.json                 — collision recorder
#
# WHY ONE SHARED FILE. Before this existed, test/run-all.sh's tree-integrity guard
# (_hook_owned_path, matching full `git status --porcelain` lines) and its own
# sweep-receipt tree_clean check (_receipt_dirty_lines) carried the SAME allowlist
# as two hand-maintained copies. bin/heimdall-state's sweep-receipt STALENESS check
# needs the identical path shapes for a THIRD purpose: deciding whether commits
# that landed after a green receipt are this repo's own hook auto-commits (safe to
# treat the receipt as still fresh) or real code changes (genuinely stale). Three
# call sites, one regex, here — so they can never drift apart the way the first two
# already did once in this repo's history.
#
# ANCHORED ON PURPOSE — SECURITY-RELEVANT, DO NOT WIDEN. A path-prefix-only version
# of this allowlist (matching everything under .planning/ledger/checkpoints/, say,
# regardless of filename) was an exploitable gap found and closed on 2026-09-21: a
# suite (buggy or malicious) could drop an arbitrary file — `ledger/checkpoints/
# dropper.sh`, a nested path, a made-up name — under one of these directories and
# have it silently exempted from every check that uses this allowlist. Every
# branch below is anchored to the EXACT filename shape its real writer emits, with
# a trailing `$` — widening any branch back to a directory prefix reopens that gap
# on all three call sites at once, not just one. See test/tree-integrity-guard.test.sh
# cases 9-11 for the falsifying fixtures this anchoring must keep passing.
#
# PATH-ONLY. This is a pure path-shape predicate — it says nothing about git
# status codes (added/modified/deleted) or about ANCESTRY between two commits.
# A caller that also cares whether a path was ADDED/MODIFIED vs DELETED (a hook
# only ever adds/modifies these paths; nothing legitimate deletes one) must apply
# that check itself — see test/run-all.sh's own _hook_owned_path, which composes
# this same path regex with its own status-code prefix for exactly that reason.
#
# Bash 3.2 / POSIX-sh compatible: no arrays, no [[ ]], no mapfile.

[ -n "${_HMD_HOOK_OWNED_PATH_SH:-}" ] && return 0 2>/dev/null || true
_HMD_HOOK_OWNED_PATH_SH=1

# The path body, deliberately WITHOUT the outer ^...$ anchors, so a caller that
# needs to splice it into a larger pattern (test/run-all.sh's porcelain-line
# regex, which prepends a git-status-code group before this) can do so without
# producing a mid-pattern anchor. hmd_hook_owned_path below adds both anchors
# itself for the plain-path case.
HMD_HOOK_OWNED_PATH_RE='\.planning/(ledger/(activity|verdicts|checkpoints)/haid_[^/]+\.json|ledger/collisions/[^/]+\.json|journal/[0-9]{4}-[0-9]{2}-[0-9]{2}-haid_[^/]+\.md)'

# hmd_hook_owned_path <path> — exit 0 iff <path> (a plain, repo-relative path,
# e.g. one line of `git diff --name-only`; NOT a `git status --porcelain` line)
# matches one of the shapes above.
hmd_hook_owned_path() {
  printf '%s' "${1:-}" | grep -Eq "^${HMD_HOOK_OWNED_PATH_RE}\$"
}
