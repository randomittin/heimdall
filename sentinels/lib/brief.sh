#!/usr/bin/env bash
# brief.sh — minimal-context brief hydration for Heimdall spawns (spec H-3/H-4).
#
# The minimal-context rule (spec H-3): a spawn receives a BRIEF, never a full
# plan or prior conversation. A brief is:
#
#   { task spec, symbol-table ref, referenced capsule IDs, invariants ref }
#
# This library hydrates a spawn's context from its spawn json's `context` block
# WITHOUT ever pulling in a full plan. It references capsules by id/path.
#
# IT USED TO DEGRADE GRACEFULLY. THAT WAS THE BUG.
#   Every unresolvable ref printed "(unavailable: … — skipped)" and the function
#   returned 0. bin/heimdall-spawn is the path a real spawn takes, so a spawn
#   whose capsules or invariants were missing ran anyway, on a brief nobody
#   could tell was thin. A thin brief is strictly worse than a fat one: the
#   agent cannot see the gap, produces confidently wrong work, and every gate
#   downstream reads a green run. Meanwhile bin/heimdall-brief — the OTHER
#   assembler, for the same artefact — refused the same refs outright. Two
#   assemblers, opposite failure semantics, and the silent one was the one on
#   the live path.
#
#   It also read capsules from $root/capsules/ while bin/heimdall-capsule writes
#   $PLANNING_DIR/protocol/capsules/. Nothing ever wrote to the path it read, so
#   "capsules/ dir not present yet — H-4 pending" was printed forever about a
#   mechanism that had in fact landed. A store nothing writes to is empty
#   forever and looks fine.
#
# BOTH ARE FIXED BY DELETION, NOT BY DUPLICATION. The resolution and the refusal
# now come from bin/lib/brief-core.sh, which bin/heimdall-brief shares verbatim,
# and capsules come from bin/lib/protocol.sh's CAPSULE_DIR — the one definition
# of where capsules live. Neither behaviour is restated here, so neither can
# drift from the other again.
#
# The `context` block of a spawn json (see .planning/spawns/SCHEMA.md) is a
# free-form object; the keys this hydrator understands:
#   context.capsules     : array of capsule ids (resolved in CAPSULE_DIR)
#   context.invariants   : an invariants ref, <path> or <path>#<anchor>
#   context.symbols      : path to a symbol table (e.g. "symbols.json")
#   context.criteria     : array of acceptance-criteria ids (kept as ids; the
#                          resolver is H-4's `heimdall resolve`, not ours)
#   context.diff_ref     : a git ref/range the spawn grades (e.g. "HEAD~1..HEAD")
#
# Paths in context are relative to the spawn's repo root (the <repo-root> arg);
# capsule IDS are not paths and always resolve in the canonical store.

_BRIEF_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_BRIEF_PLUGIN_DIR="$(cd "$_BRIEF_LIB_DIR/../.." && pwd)"
# shellcheck source=../../bin/lib/protocol.sh
. "$_BRIEF_PLUGIN_DIR/bin/lib/protocol.sh"
# shellcheck source=../../bin/lib/brief-core.sh
. "$_BRIEF_PLUGIN_DIR/bin/lib/brief-core.sh"
# Resolved against bin/heimdall-brief's own path, not this file's, so CAPSULE_DIR
# comes out byte-identical to what the other entry point computes. Passing this
# lib's path would put PROTO_BIN_DIR in sentinels/ and silently invent a second
# store — the exact class of bug this rewrite removes.
proto_resolve_paths "$_BRIEF_PLUGIN_DIR/bin/heimdall-brief"

# Hydrate the brief for a spawn json. Args:
#   <spawn-json-path> <repo-root>
# Prints the assembled brief. Returns:
#   0 every referenced ref resolved
#   1 INCOMPLETE — a ref was looked for and is absent; DO NOT SPAWN on it
#   2 the spawn json itself is unusable (missing file, no jq)
#   3 NON_VERIFIED — a store or file could not be read, so nothing was checked
brief_hydrate() {
  local spawn_json="$1" root="$2"
  command -v jq >/dev/null 2>&1 || { echo "error: jq is required for brief hydration" >&2; return 2; }
  [ -f "$spawn_json" ] || { echo "error: spawn json not found: $spawn_json" >&2; return 2; }

  local work rc=0
  work="$(mktemp -d)" || { echo "error: cannot create a work dir for brief hydration" >&2; return 2; }
  brief_core_init "$work"

  local body="$work/body"
  : > "$body"

  # ── the spawn's own framing: not refs, so nothing here can dangle ──────────
  {
    local kind trigger diff_ref criteria
    kind="$(jq -r '.kind // "unknown"' "$spawn_json")"
    trigger="$(jq -r '.trigger // "unknown"' "$spawn_json")"
    echo "kind:    $kind"
    echo "trigger: $trigger"

    diff_ref="$(jq -r '.context.diff_ref // empty' "$spawn_json")"
    [ -n "$diff_ref" ] && echo "diff_ref: $diff_ref"

    # acceptance-criteria ids — kept AS IDS (H-4's resolver expands them; we
    # don't restate the criteria text, that would defeat compression-by-reference)
    criteria="$(jq -r '(.context.criteria // []) | join(", ")' "$spawn_json")"
    [ -n "$criteria" ] && echo "criteria (ids): $criteria"
  } >> "$body"

  # ── refs, every one of which is checked ────────────────────────────────────
  local symbols invariants capsule_ids
  symbols="$(jq -r '.context.symbols // empty' "$spawn_json")"
  if [ -n "$symbols" ]; then
    brief_core_file_ref "symbols" "$symbols" "$root" >> "$body" || rc=$?
    [ "$rc" -eq 0 ] || { rm -rf "$work"; return "$rc"; }
  fi

  invariants="$(jq -r '.context.invariants // empty' "$spawn_json")"
  if [ -n "$invariants" ]; then
    brief_core_invariants "$invariants" "$root" >> "$body" || rc=$?
    [ "$rc" -eq 0 ] || { rm -rf "$work"; return "$rc"; }
  fi

  capsule_ids="$(jq -r '(.context.capsules // []) | .[]' "$spawn_json" | tr '\n' ' ')"
  if [ -n "${capsule_ids// /}" ]; then
    # shellcheck disable=SC2086 — capsule ids are whitespace-free tokens
    brief_core_capsules "$_BRIEF_PLUGIN_DIR/bin/heimdall-capsule" $capsule_ids >> "$body" || rc=$?
    [ "$rc" -eq 0 ] || { rm -rf "$work"; return "$rc"; }
  fi

  # ── emit ──────────────────────────────────────────────────────────────────
  local nmissing
  nmissing="$(brief_core_missing_count)"

  echo "── BRIEF (minimal-context; capsule refs only, never a full plan) ──"
  if [ "$nmissing" -gt 0 ]; then
    brief_core_incomplete_banner "$nmissing"
  fi
  cat "$body"
  echo "── END BRIEF ──"

  if [ "$nmissing" -gt 0 ]; then
    brief_core_unresolved_block "$nmissing"
    rm -rf "$work"
    return 1
  fi
  rm -rf "$work"
  return 0
}

# Assert a brief does NOT smuggle a full plan. The contract forbids embedding a
# whole plan in context; this guard fails if context references a plan file
# directly (PLAN-*.md / *plan*.md) instead of capsule ids. Returns 0 if clean,
# 1 if a plan ref is found. Used by tests and by heimdall-spawn before running.
brief_assert_no_plan() {
  local spawn_json="$1"
  command -v jq >/dev/null 2>&1 || return 2
  # Scan every string value anywhere in context for a plan-file pattern.
  if jq -e '
      [.context | .. | strings]
      | any(test("(?i)(^|/)PLAN-.*\\.md$|(?i)(^|/)plan\\.md$|(?i)full[_-]?plan"))
    ' "$spawn_json" >/dev/null 2>&1; then
    return 1
  fi
  return 0
}
