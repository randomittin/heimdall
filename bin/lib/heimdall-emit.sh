#!/usr/bin/env bash
# bin/lib/heimdall-emit.sh — COMPRESS AT THE PRODUCER, NEVER THE CONSUMER.
#
# WHY THIS FILE EXISTS
# ---------------------
# Measured (docs/analysis/rtk-incorporation-assessment-2026-08-22.md): bash/tool
# output is 22.36% of all replayed input tokens — the single largest identifiable
# category — and hmd had nothing at that layer. RTK's own answer (declined
# elsewhere in this repo, see that doc) is to intercept and re-parse FOREIGN
# command stdout, which corrupts silently: it eats `git status --porcelain`'s
# trailing newline (dropping a `while read` loop's last line — upstream #3267)
# and duplicates filenames out of `git diff --name-only` (#2811). That failure
# mode does not exist here, structurally: this library never reads a byte of
# another program's output and never rewrites anything. It only helps an hmd bin
# compact OUTPUT IT ALREADY PRODUCED AND FULLY OWNS.
#
# THE SAFE DESIGN — three properties, each load-bearing:
#   1. CONTENT-BLIND. The only fact ever extracted from the captured content is
#      its byte count (`wc -c`). Never parsed, never pattern-matched, never
#      re-interpreted. A gate that cannot read meaning into content cannot
#      corrupt it by misreading that meaning.
#   2. THE CALLER SUPPLIES THE VERDICT. The one-line (or few-line) summary
#      printed on the compaction path is whatever the calling bin hands in —
#      normally something it already tracked in its own counters (e.g.
#      `heimdall-agents`'s sweep already counts `n_reap`/`n_parked` before it
#      prints anything). This library never derives a summary FROM the
#      captured bytes. It only ever echoes what the caller already knows.
#   3. NOTHING BECOMES UNVERIFIABLE. Elided content is archived byte-for-byte,
#      never discarded. The exact artifact path is printed inline. Compact
#      output is a smaller WINDOW onto the truth, never a smaller amount of it.
#
# THE FRESHNESS CONTRACT (docs/superpowers/specs/2026-08-22-gate-execution-alternative.md
# §3.4 — "never close enough": a pointer is only safe if it names the EXACT
# identity of what it points to). Applied here: `evidence:` always names the
# ONE artifact file this call just wrote (its own mktemp-random suffix), never
# the mutable `LATEST` pointer. A later call landing a newer LATEST must never
# retroactively invalidate an evidence line already printed by an earlier one —
# see test/heimdall-emit.test.sh section (3) for the falsifiable proof.
#
# DURABILITY: artifacts live under ${HEIMDALL_HOME:-$HOME/.heimdall}/runs/<tool>/,
# never /tmp. A bare /tmp evidence dir was the measured root cause of an
# invalidated sweep the same day this library was written — OS housekeeping
# reaped it mid-flight. This mirrors the existing `~/.heimdall/runs/` sweep-log
# convention already produced by test/run-all.sh; this library gives individual
# bins the same durability without touching that file.
#
# THE ONE NON-NEGOTIABLE: the wrapped command's exit code is caller-supplied and
# is returned UNCHANGED on every path below (verbatim, compacted, and every
# fail-open branch). The two exceptions are pure library-usage errors — an empty
# tool-name or a missing/unreadable content file — which return 2 because in
# those cases nothing was actually emitted, so passing through the caller's
# claimed exit code would misrepresent an emission that never happened.
#
# ENV:
#   HEIMDALL_HOME        durable-artifact root (existing repo-wide convention);
#                         default ${HOME}/.heimdall
#   HMD_EMIT_THRESHOLD    byte threshold above which output compacts; default
#                         4096; any non-numeric value falls back to the default
#   HMD_EMIT_VERBOSE      "1" forces verbatim output unconditionally (escape
#                         hatch), and skips archiving entirely
#
# Sourcing is side-effect-free apart from defining functions: no shell options
# are set, no directory is touched, no env var is read until a function is
# actually called. Safe to `. ` into any caller's shell without side effects.

# hmd_emit_should_compact <byte-count>
# Pure predicate. The byte count is the ONLY signal — computed by the caller
# from a `wc -c` on content it already owns; this function never looks at the
# content itself, only the number.
hmd_emit_should_compact() {
  local bytes="${1:-0}" threshold="${HMD_EMIT_THRESHOLD:-}"
  case "$threshold" in ''|*[!0-9]*) threshold=4096 ;; esac
  [ "${HMD_EMIT_VERBOSE:-}" != "1" ] && [ "$bytes" -gt "$threshold" ] 2>/dev/null
}

# hmd_emit_result <tool-name> <content-file> <exit-code> [summary text...]
#
# <content-file> holds bytes the CALLER already produced (redirect its own
# stdout to a file with `>`, never capture through `$(...)` first — command
# substitution strips trailing newlines and would already have lost the
# byte-for-byte fidelity this function exists to preserve).
#
# Below threshold (or HMD_EMIT_VERBOSE=1): prints <content-file> verbatim,
# byte for byte, no archive written — existing small-output callers see zero
# behavior change.
#
# Above threshold: prints the caller's own <summary text> (verbatim, never
# rewritten) followed by one `evidence: <path>  (<bytes> bytes, <lines>
# lines...)` line naming the exact archived copy. The archived copy is a plain
# `cp` of <content-file> — same bytes, nothing re-encoded.
#
# Returns <exit-code> unchanged on every reachable path, including every
# fail-open branch (unwritable durable root, failed archive copy): a broken
# archive must never cost the caller data it already had, so those branches
# degrade to the exact same verbatim `cat` as the below-threshold path.
#
# Returns 2 (never <exit-code>) only for the two pure usage errors: an empty
# tool-name, or a content-file that does not exist / is not a readable regular
# file. Both write a real message to stderr and print nothing to stdout — a
# usage error must never masquerade as a fabricated summary.
hmd_emit_result() {
  local tool="${1:-}" content="${2:-}" code="${3:-0}" summary=""
  if [ "$#" -gt 3 ]; then
    shift 3
    summary="$*"
  fi

  if [ -z "$tool" ]; then
    printf 'hmd_emit_result: tool-name must not be empty\n' >&2
    return 2
  fi
  if [ -z "$content" ] || [ ! -f "$content" ] || [ ! -r "$content" ]; then
    printf 'hmd_emit_result: content file not found or unreadable: %s\n' "$content" >&2
    return 2
  fi

  local bytes
  bytes="$(wc -c < "$content" 2>/dev/null | tr -d ' ')"
  case "$bytes" in ''|*[!0-9]*) bytes=0 ;; esac

  if ! hmd_emit_should_compact "$bytes"; then
    cat "$content"
    return "$code"
  fi

  # ── compaction path — fail OPEN at every step below ─────────────────────────
  local home dir dest lines
  home="${HEIMDALL_HOME:-${HOME:-}/.heimdall}"
  dir="$home/runs/$tool"
  if ! mkdir -p "$dir" 2>/dev/null; then
    cat "$content"
    return "$code"
  fi
  dest="$(mktemp "$dir/$(date +%s)-XXXXXX" 2>/dev/null)" || dest=""
  if [ -z "$dest" ] || ! cp "$content" "$dest" 2>/dev/null; then
    [ -n "$dest" ] && rm -f "$dest" 2>/dev/null
    cat "$content"
    return "$code"
  fi
  # LATEST is a best-effort convenience pointer, not the source of truth — the
  # evidence line below names $dest directly, so a failed LATEST write here
  # never costs the caller anything verifiable.
  printf '%s\n' "$dest" > "$dir/LATEST" 2>/dev/null || true

  lines="$(wc -l < "$content" 2>/dev/null | tr -d ' ')"
  case "$lines" in ''|*[!0-9]*) lines=0 ;; esac

  [ -n "$summary" ] && printf '%s\n' "$summary"
  cat "$content"
  printf 'evidence: %s  (%s bytes, %s lines — full detail, not truncated)\n' "$dest" "$bytes" "$lines"
  return "$code"
}
