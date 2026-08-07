#!/usr/bin/env bash
# brief-core.sh — the ONE resolution + refusal core every brief assembler shares.
#
# WHY THIS FILE EXISTS. Heimdall shipped TWO brief assemblers with OPPOSITE
# failure semantics. bin/heimdall-brief refused an unresolvable ref and said
# THIS BRIEF IS INCOMPLETE; sentinels/lib/brief.sh — the one bin/heimdall-spawn
# actually called — degraded gracefully, printed "(unavailable: … — skipped)"
# and returned 0. So the real spawn path handed out silently-thin briefs. That
# is strictly worse than a fat brief: the agent cannot tell the context it was
# promised is absent, so it produces confidently wrong work and every downstream
# gate sees a green run.
#
# Two assemblers cannot be kept in agreement by intention. So the resolution and
# the refusal live HERE, once, and both entry points call in. They keep their
# own framing (a spawn json has a kind and a trigger; a CLI build has symbols
# and file outlines) but they cannot disagree about whether a ref resolved or
# what to do when it did not.
#
# THE THREE VERDICTS — the distinction is the whole point:
#
#   0  OK            every ref the caller named resolved.
#   1  INCOMPLETE    a ref was LOOKED FOR and is genuinely absent. The brief is
#                    refused; the unresolved refs are listed by name.
#   3  NON_VERIFIED  nobody could look — the store is unreachable, a file exists
#                    but cannot be read. An unverifiable gate is NEVER reported
#                    OPEN, and never downgraded to "absent": "it is not there"
#                    and "I could not check" demand different repairs.
#
# EMPTY IS NOT UNREACHABLE. A capsule store that exists and holds nothing is a
# legitimate state — the repo's store has been empty since June. Referencing a
# capsule against an empty store is a real absence (1). Referencing one against
# a store that cannot be created or read is (3). Collapsing those would let a
# broken install read as "no context needed".
#
# CONTRACT FOR CALLERS
#   - Source bin/lib/protocol.sh and run proto_resolve_paths FIRST: CAPSULE_DIR
#     is the single source of truth for where capsules live, and this file
#     refuses to guess a second answer.
#   - Call brief_core_init <workdir> once before resolving anything.
#   - Every function RETURNS its verdict; none of them call exit. The entry
#     point owns the mapping to a process exit code, because a sourced library
#     that exits would take its caller's own exit contract with it.

# ── the unresolved-ref accumulator ───────────────────────────────────────────
# A FILE, not a shell variable. Both assemblers build their bodies inside
# `{ … } >> "$BODY"` blocks, and a variable assigned inside one of those dies
# with the subshell — a ref recorded deep in a block would be forgotten by the
# time the top level decided whether to refuse. A file survives.
brief_core_init() {
  BRIEF_CORE_WORK="${1:?brief_core_init needs a work dir}"
  mkdir -p "$BRIEF_CORE_WORK"
  BRIEF_CORE_MISSING="$BRIEF_CORE_WORK/missing"
  : > "$BRIEF_CORE_MISSING"
}

brief_core_missing() { printf '%s\n' "$*" >> "$BRIEF_CORE_MISSING"; }

brief_core_missing_count() {
  [ -f "${BRIEF_CORE_MISSING:-}" ] || { printf '0'; return 0; }
  wc -l < "$BRIEF_CORE_MISSING" | tr -d ' '
}

# ── the refusal, in one wording ──────────────────────────────────────────────
# Both entry points print these EXACT strings. A paraphrase in either place is a
# second copy that drifts, and the drift is invisible until the day it matters.
brief_core_incomplete_banner() {
  printf '!! THIS BRIEF IS INCOMPLETE — %s ref(s) UNRESOLVED. DO NOT SPAWN ON IT.\n' "$1"
  printf '!! Acting on it means working without context the task said it needed.\n'
}

brief_core_unresolved_block() {
  printf 'UNRESOLVED REFS (%s) — THIS BRIEF IS INCOMPLETE:\n' "$1"
  sed 's/^/  !! /' "$BRIEF_CORE_MISSING"
  printf '\n'
  printf 'Refusing to certify a brief that is missing context the task referenced.\n'
}

# brief_core_nonverified <what> <why> — the NON_VERIFIED refusal. Printed to
# stderr because it is an operational fault, not a content verdict: the brief
# was never assembled, so there is no brief on stdout to annotate.
brief_core_nonverified() {
  printf 'error: %s — %s\n' "$1" "$2" >&2
  printf 'NON_VERIFIED: refusing to emit a brief whose refs were never checked.\n' >&2
  return 3
}

# ── the capsule store ────────────────────────────────────────────────────────
# brief_core_store_state — "ok" when the store can be read or created, else
# "unreachable". Emptiness is NOT consulted: an empty store is readable, and a
# readable store is one we can make honest statements about.
brief_core_store_state() {
  local d="${CAPSULE_DIR:-}"
  if [ -z "$d" ]; then printf 'unreachable'; return 0; fi
  if [ -d "$d" ]; then
    if [ -r "$d" ] && [ -x "$d" ]; then printf 'ok'; else printf 'unreachable'; fi
    return 0
  fi
  # Not there yet. Reachable iff it can be created — a parent that is a regular
  # file or a read-only mount means nobody can ever look, for any user.
  if mkdir -p "$d" 2>/dev/null; then printf 'ok'; else printf 'unreachable'; fi
}

# brief_core_capsules <capsule-bin> <id…> — emit the CONTEXT CAPSULES block.
# Returns 0 (block emitted; unresolvable ids recorded) or 3 (store unreachable).
#
# Hydration is delegated to bin/heimdall-capsule so the dependency CLOSURE is
# computed in one place. A second closure walk here would be a second answer to
# a question that already has one.
brief_core_capsules() {
  local capsule_bin="$1"; shift
  [ $# -gt 0 ] || return 0

  if [ "$(brief_core_store_state)" != "ok" ]; then
    brief_core_nonverified "capsule store unreachable at ${CAPSULE_DIR:-<unset>}" \
      "the store could not be read or created, so no capsule can be called absent"
    return 3
  fi

  local id ok_all=1
  for id in "$@"; do
    [ -f "$CAPSULE_DIR/$id.md" ] && continue
    ok_all=0
    brief_core_missing "capsule $id — no such capsule in $CAPSULE_DIR"
  done

  printf 'CONTEXT CAPSULES (dependency closure of referenced ids ONLY):\n'
  if [ "$ok_all" -eq 1 ]; then
    local hyd hyd_rc
    set +e
    hyd="$("$capsule_bin" hydrate "$@" 2>&1)"
    hyd_rc=$?
    set -e
    if [ "$hyd_rc" -eq 0 ]; then
      printf '%s\n' "$hyd" | sed 's/^/  /'
    else
      printf '  <UNRESOLVED>\n'
      brief_core_missing "capsule closure incomplete — hydrate failed: $hyd"
    fi
  else
    printf '  <UNRESOLVED>\n'
  fi
  printf '\n'
  return 0
}

# ── the invariants ref ───────────────────────────────────────────────────────
# The invariants ref is HOW a spawn inherits the no-stub and quality rules. It
# used to be echoed through verbatim, so a ref at a deleted file — or an anchor
# that no longer exists — passed silently and the agent believed it had been
# handed constraints it never received. Worse than handing over nothing, because
# nothing is visible.
#
# Three failures, three repairs, kept apart on purpose:
#   MALFORMED     the ref is not <path> or <path>#<anchor>  -> fix the ref
#   FILE MISSING  the path names nothing                    -> fix the path / restore the file
#   ANCHOR MISSING the file is there, the section is not    -> fix the anchor / restore the heading

# brief_core_slug <text> — the GitHub heading-anchor slug: lowercase, drop
# everything that is not [a-z0-9 _-], spaces to hyphens. LC_ALL=C so multi-byte
# punctuation (the em dash in "Code Quality — Zero Tolerance") is dropped
# byte-wise and deterministically, exactly as GitHub drops it.
brief_core_slug() {
  printf '%s' "$1" | LC_ALL=C tr '[:upper:]' '[:lower:]' \
    | LC_ALL=C sed 's/[^a-z0-9 _-]//g; s/ /-/g'
}

# brief_core_anchors <file> — every anchor the file actually offers, one per
# line, in document order. Repeated headings get GitHub's -1/-2 suffixes, so a
# ref to the second "## Notes" resolves instead of being called dangling.
brief_core_anchors() {
  LC_ALL=C awk '
    {
      if (match($0, /^#+[ \t]+/) == 0) next
      n = 0
      while (substr($0, n + 1, 1) == "#") n++
      if (n > 6) next
      s = substr($0, RSTART + RLENGTH)
      sub(/[ \t]*#*[ \t]*$/, "", s)
      s = tolower(s)
      gsub(/[^a-z0-9 _-]/, "", s)
      gsub(/ /, "-", s)
      if (s == "") next
      if (s in seen) { print s "-" seen[s]; seen[s] = seen[s] + 1 }
      else { print s; seen[s] = 1 }
    }
  ' "$1" 2>/dev/null
}

# brief_core_invariants <ref> <base-dir> — validate and emit the INVARIANTS REF
# line. Returns 0 (resolved or recorded as unresolved) or 3 (NON_VERIFIED).
#
# The emitted line always says what was CHECKED. "INVARIANTS REF: x" reads the
# same whether x was verified or never looked at, and that ambiguity is the bug.
brief_core_invariants() {
  local ref="$1" base="$2" path anchor abs hashes

  hashes="$(printf '%s' "$ref" | LC_ALL=C tr -cd '#' | wc -c | tr -d ' ')"
  path="${ref%%#*}"
  anchor=""
  case "$hashes" in
    0) ;;
    1) anchor="${ref#*#}" ;;
    *)
      printf 'INVARIANTS REF: %s = <UNRESOLVED>\n' "$ref"
      brief_core_missing "invariants $ref — MALFORMED ref: $hashes '#' separators (repair: use <path> or <path>#<anchor>)"
      return 0 ;;
  esac
  if [ -z "$path" ] || { [ "$hashes" = "1" ] && [ -z "$anchor" ]; }; then
    printf 'INVARIANTS REF: %s = <UNRESOLVED>\n' "$ref"
    brief_core_missing "invariants $ref — MALFORMED ref: expected <path> or <path>#<anchor> (repair: name the file the anchor lives in)"
    return 0
  fi

  case "$path" in /*) abs="$path" ;; *) abs="$base/$path" ;; esac

  if [ ! -f "$abs" ]; then
    printf 'INVARIANTS REF: %s = <UNRESOLVED>\n' "$ref"
    brief_core_missing "invariants $ref — no such file: $abs (repair: fix the path, or restore the file)"
    return 0
  fi
  # Exists but cannot be read: nobody looked, so the anchor is not absent — it
  # is unchecked. That is NON_VERIFIED, never a content verdict.
  if [ ! -r "$abs" ]; then
    brief_core_nonverified "invariants file unreadable: $abs" \
      "it exists but could not be opened, so its anchors were never checked"
    return 3
  fi

  if [ -z "$anchor" ]; then
    printf 'INVARIANTS REF: %s (verified: file exists)\n' "$ref"
    return 0
  fi

  # No pipe into grep -q: grep exits on the first match, awk takes SIGPIPE, and
  # `set -o pipefail` would turn a FOUND anchor into a failure. The list goes to
  # a file, and the file is what gets searched.
  local anchors="$BRIEF_CORE_WORK/anchors.$$"
  brief_core_anchors "$abs" > "$anchors"
  if LC_ALL=C grep -qxF "$anchor" "$anchors"; then
    rm -f "$anchors"
    printf 'INVARIANTS REF: %s (verified: file + anchor)\n' "$ref"
    return 0
  fi

  local candidates
  candidates="$(LC_ALL=C grep -F "$anchor" "$anchors" | head -3 | tr '\n' ' ')"
  [ -n "$candidates" ] || candidates="$(head -5 "$anchors" | tr '\n' ' ')"
  [ -n "$candidates" ] || candidates="(none — $path offers no headings)"
  rm -f "$anchors"
  printf 'INVARIANTS REF: %s = <UNRESOLVED>\n' "$ref"
  brief_core_missing "invariants $ref — ANCHOR '$anchor' not found in $path (repair: fix the anchor, or restore the heading). Anchors that exist: $candidates"
  return 0
}

# brief_core_file_ref <label> <path> <base-dir> — validate a plain file ref that
# a brief promised (a symbol table, an criteria file). Same three verdicts.
brief_core_file_ref() {
  local label="$1" path="$2" base="$3" abs
  case "$path" in /*) abs="$path" ;; *) abs="$base/$path" ;; esac
  if [ ! -f "$abs" ]; then
    printf '%s: %s = <UNRESOLVED>\n' "$label" "$path"
    brief_core_missing "$label $path — no such file: $abs (repair: fix the path, or write the file)"
    return 0
  fi
  if [ ! -r "$abs" ]; then
    brief_core_nonverified "$label file unreadable: $abs" \
      "it exists but could not be opened, so it was never checked"
    return 3
  fi
  printf '%s: %s (verified: file exists)\n' "$label" "$path"
  return 0
}
