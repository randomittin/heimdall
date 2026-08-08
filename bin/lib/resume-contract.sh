# resume-contract.sh — THE RESUME CONTRACT: what must never be lost across a restart,
# and how it is graded. Sourced VERBATIM by bin/heimdall-checkpoint (which writes the
# answer key) and bin/heimdall-resume-probe (which grades against it).
#
# WHY THIS IS A SHARED FILE AND NOT TWO AGREEING IMPLEMENTATIONS
# --------------------------------------------------------------
# The writer digests a value it holds in memory; the probe digests a value it reads
# back off disk. If those two ever disagreed about what "the same answer" means —
# which label names it, how whitespace normalises, which hash — every restart would
# report a loss that never happened, and the gate would be turned off inside a week.
# bin/heimdall-brief learned this the expensive way: two assemblers of the same thing
# drifted into OPPOSITE failure semantics and the one nobody watched degraded
# silently. Two implementations cannot be held in agreement by intention. They can
# only share the decision. This file is that decision.
#
# THE SIX CATEGORIES (spec 1.4 — "what must never be lost")
#   in_progress      in-progress work + rationale, and the next step
#   gated_decisions  decisions parked awaiting a human call
#   held_branches    branches/worktrees holding unmerged work, and why
#   unpushed         commits that exist only on this machine
#   open_warnings    open ⚠ items — known-broken things not yet fixed
#   refuted_claims   what this session proved FALSE
#
# Refuted claims are in the list because corrections are the single most expensive
# knowledge to re-derive: git records what a session decided, never what it learned
# was wrong. A restart that drops them re-walks every dead end at full price.
#
# THE LAYER ATTRIBUTION is the other half of the decision. When the probe finds a
# miss, "something was lost" is useless — the operator needs to know WHICH LAYER of
# the memory stack dropped it, because that is the thing to fix. Every category
# therefore declares the layer that sourced it, and the probe files the miss against
# that layer by name.

# The six ids, in the order a checkpoint renders and a probe grades them.
RC_IDS="in_progress gated_decisions held_branches unpushed open_warnings refuted_claims"

# id -> the CHECKPOINT.md field label. This is the one string the writer prints and
# the probe greps; a change here changes both at once, which is the point.
rc_label() {
  case "$1" in
    in_progress)     printf 'In progress' ;;
    gated_decisions) printf 'Gated decisions' ;;
    held_branches)   printf 'Held branches' ;;
    unpushed)        printf 'Unpushed' ;;
    open_warnings)   printf 'Open warnings' ;;
    refuted_claims)  printf 'Refuted claims' ;;
    *)               return 1 ;;
  esac
}

# id -> the memory-stack layer that SOURCED this answer. A miss is filed against it.
#   checkpoint  .planning/CHECKPOINT.md — the durable local carrier
#   index       the observation store — ⚠ items live here, not in git
rc_layer() {
  case "$1" in
    open_warnings) printf 'index' ;;
    in_progress|gated_decisions|held_branches|unpushed|refuted_claims) printf 'checkpoint' ;;
    *) return 1 ;;
  esac
}

# One-line human gloss per category, used by the probe's RED render so a miss reads
# as a loss of something specific rather than an id.
rc_gloss() {
  case "$1" in
    in_progress)     printf 'what was in progress and the next step' ;;
    gated_decisions) printf 'decisions parked awaiting a human call' ;;
    held_branches)   printf 'branches holding unmerged work, and why' ;;
    unpushed)        printf 'commits that exist only on this machine' ;;
    open_warnings)   printf 'open ⚠ items — known-broken, not yet fixed' ;;
    refuted_claims)  printf 'what this session proved FALSE' ;;
    *) return 1 ;;
  esac
}

# Collapse an answer to its comparable form: newlines and runs of whitespace become
# one space, ends trimmed. Formatting must never register as knowledge loss — only
# CONTENT may. Reads stdin, writes stdout.
rc_normalize() {
  tr '\n\t' '  ' | sed -e 's/  */ /g' -e 's/^ //' -e 's/ $//'
}

# sha256 of the normalised stdin, lowercase hex, no trailing name. Returns non-zero
# when no hasher exists — the caller MUST treat that as a failure, never as "skip
# the check": an ungradeable answer is exactly the silent pass this gate forbids.
rc_digest() {
  local norm out
  norm="$(rc_normalize)"
  if command -v shasum >/dev/null 2>&1; then
    out="$(printf '%s' "$norm" | shasum -a 256 2>/dev/null | cut -d' ' -f1)"
  elif command -v sha256sum >/dev/null 2>&1; then
    out="$(printf '%s' "$norm" | sha256sum 2>/dev/null | cut -d' ' -f1)"
  elif command -v python3 >/dev/null 2>&1; then
    out="$(printf '%s' "$norm" | python3 -c 'import hashlib,sys; print(hashlib.sha256(sys.stdin.buffer.read()).hexdigest())' 2>/dev/null)"
  else
    return 1
  fi
  case "$out" in
    [0-9a-f][0-9a-f]*) printf '%s' "$out" ;;
    *) return 1 ;;
  esac
}

# Read one "- **Label:** value" line out of a checkpoint. Prints the value, or
# NOTHING when the field is absent OR appears more than once. A duplicated field is
# treated as absent on purpose: two answers to one question is not more knowledge,
# it is an ambiguous checkpoint, and guessing which one is current is how a resume
# proceeds confidently on stale state.
rc_field() { # <checkpoint-file> <label>
  local file="$1" label="$2" n
  [ -f "$file" ] || return 0
  n="$(grep -c "^- \*\*$label:\*\* " "$file" 2>/dev/null)"
  [ "${n:-0}" = "1" ] || return 0
  sed -n "s/^- \*\*$label:\*\* \(.*\)\$/\1/p" "$file" 2>/dev/null | head -1
}

# Flatten a possibly-multi-line derived value into the single line a field carries.
# Blank segments are dropped so the separator never doubles.
rc_flatten() {
  tr '\n' '\036' | sed -e 's/\036\036*/\036/g' -e 's/^\036//' -e 's/\036$//' -e 's/\036/ · /g' \
    | sed -e 's/  */ /g' -e 's/^ //' -e 's/ $//'
}

# Escape a value for embedding in a JSON string (backslash, quote, control chars).
rc_json_esc() {
  printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' | tr -d '\000-\010\013\014\016-\037'
}

# ${HEIMDALL_HOME:-<repo>/.heimdall} — the same resolution issue_queue.heimdall_home
# uses. Never re-derived, so a test that relocates HEIMDALL_HOME relocates all of it.
rc_home() { # <repo>
  if [ -n "${HEIMDALL_HOME:-}" ]; then printf '%s' "$HEIMDALL_HOME"; else printf '%s/.heimdall' "$1"; fi
}

# The three artefacts of the contract.
rc_key_path()   { printf '%s/.planning/RESUME-KEY.json' "$1"; }          # <repo>
rc_notes_path() { printf '%s/resume-notes.ndjson' "$(rc_home "$1")"; }   # <repo>
rc_log_path()   { printf '%s/probe.ndjson' "$(rc_home "$1")"; }          # <repo>
rc_ckpt_path()  { printf '%s/.planning/CHECKPOINT.md' "$1"; }            # <repo>

# How many observations the index layer currently holds. 0 when the store is absent.
# The writer records this at save time; the probe compares. A store that SHRANK
# between save and resume means an observation was pruned — which is precisely the
# "index observation missing" failure the probe has to be able to name.
rc_notes_count() { # <repo>
  local store n
  store="$(rc_notes_path "$1")"
  [ -f "$store" ] || { printf '0'; return 0; }
  n="$(grep -c . "$store" 2>/dev/null)"
  printf '%s' "${n:-0}"
}

# The hmd/context worklog branch, as the memory stack's third layer. Sets:
#   RC_CB_PRESENT  yes|no      the orphan ref exists locally
#   RC_CB_HEAD     <sha>       its tip
#   RC_CB_TS       <epoch>     worklog.json's generated_ts (0 when unreadable)
# Read via `git show` against the ref, never a checkout: the branch is orphan and
# must never touch the working tree (bin/heimdall-context-sync's whole design).
rc_ctx_branch() { # <repo>
  local repo="$1" sha wl
  RC_CB_PRESENT=no; RC_CB_HEAD=""; RC_CB_TS=0
  sha="$(git -C "$repo" rev-parse --verify --quiet refs/heads/hmd/context 2>/dev/null)"
  [ -n "$sha" ] || return 0
  RC_CB_PRESENT=yes; RC_CB_HEAD="$sha"
  wl="$(git -C "$repo" show refs/heads/hmd/context:worklog.json 2>/dev/null)"
  RC_CB_TS="$(printf '%s' "$wl" | sed -n 's/.*"generated_ts"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p' | head -1)"
  [ -n "$RC_CB_TS" ] || RC_CB_TS=0
}

# The note categories the recording seam accepts, mapped to the category they feed.
# Three of the six categories exist ONLY in the session's head — no git command can
# see "the next step", "we are waiting on a human", or "that claim turned out to be
# false". Without a seam those fields could only ever say "none", and a probe that
# grades six blanks proves nothing. This is that seam.
rc_note_category() { # <note-kind> -> <contract id>
  case "$1" in
    in-progress|next) printf 'in_progress' ;;
    gated|decision)   printf 'gated_decisions' ;;
    refuted|wrong)    printf 'refuted_claims' ;;
    warn|warning)     printf 'open_warnings' ;;
    *) return 1 ;;
  esac
}
