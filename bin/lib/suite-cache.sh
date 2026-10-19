#!/usr/bin/env bash
# bin/lib/suite-cache.sh -- the per-suite cache of GREEN test results: a suite whose inputs did not change is not run again.
#
#   user:  test/run-all.sh   (per suite: HIT -> not launched, MISS -> launched, then its result goes through suite_cache_store)
#   proof: test/suite-cache.test.sh   (every guard below is broken one at a time; some case must go red)
#
# WHY IT EXISTS. A sweep is ~540 suites and 20-75 minutes, and any change stales the one whole-tree receipt, so an interrupted, cancelled or
# merely follow-up sweep threw away every suite it had already finished. A green result of suite S depends on the files S can reach (its
# CLOSURE) and on the machinery that runs it (the SALT: run-all.sh, test/lib, the closure engine, this file, tool versions). While neither
# changed the result cannot have, so it is reused -- until it is 7 days old, and with a seeded sample of the hits re-run anyway to catch a
# closure that missed something. This file only STORES and COMPARES: it never computes a closure or a salt. Both arrive as 64-digit
# lowercase hex strings (sha256) from bin/heimdall-suite-closure, so the cache holds no opinion on what a dependency is.
#
# THE ENTRY  <repo>/.heimdall/receipts/suite-cache/<suite>.json  (gitignored; one JSON object, mode 0600, in a 0700 directory), EXACTLY these fields:
#   suite                      the bare file name, test/ stripped: letters, digits and . _ - only, starting with a letter or digit
#   closure_sha, salt          64 lowercase hex digits each -- what the result is bound to
#   exit_code                  0
#   assertions_passed          the parsed count (a run whose counts could not be parsed has none, and is never cached)
#   assertions_failed          0       -- exit_code 0 with failures printed is a discrepancy, not a green
#   live_reason                ""      -- a live/credentialed suite carries the reason it is live
#   tree_integrity_violations  0
#   finished_at                UTC, 2026-10-19T12:00:00Z -- the age cap counts from here
#   ran_at_head                the full object id of the commit it ran at (provenance; not compared)
#   duration_s                 seconds
# The caller hands over the facts it already has (the sweep's exit code, the parsed counts, live_reason, the tree-integrity count) VERBATIM; the
# schema decides. It is ONE jq definition (_SUITE_CACHE_JQ_DEFS) read by the writer and by the reader, so what store accepts and what lookup
# trusts cannot drift apart (the pattern of bin/lib/hmd_repo_receipt.py). An entry with a missing, mistyped or unknown field is refused / ignored.
#
# THE CALLS. Return 0 = yes, 1 = refused or unusable; reasons go to stderr, except lookup, which answers on stdout.
#   suite_cache_dir REPO                  -> <REPO>/.heimdall/receipts/suite-cache. Every other call accepts a directory with exactly that last name, no other.
#   suite_cache_name SUITE                -> the bare name, or rc 1. A path is reduced to its file name, so nothing can leave the cache directory.
#   suite_cache_lookup DIR SUITE CLOSURE_SHA SALT MAX_DAYS NOW
#                                         -> ONE line: "HIT" (rc 0) or "MISS <reason>" (rc 1), never a crash. HIT needs a valid entry for this suite whose
#                                            closure_sha and salt equal the arguments and whose age is 0..MAX_DAYS days. MAX_DAYS can only TIGHTEN the
#                                            7-day ceiling (the rule of hmd_sweep_tighten, bin/lib/sweep-chain.sh); empty = the ceiling, junk = the
#                                            ceiling with a note on stderr. NOW is epoch seconds. An entry dated after NOW is a MISS.
#   suite_cache_store DIR SUITE JSON      -> rc 0: stored (atomic: temp file + rename). Anything but a clean green record of SUITE is refused AND forgets the
#                                            suite's earlier entry, so after any refusal no older green of that suite can HIT: a red always re-runs.
#   suite_cache_invalidate DIR SUITE      -> forget one suite (it ran and there is no record to hand over, e.g. a timeout).
#   suite_cache_purge DIR                 -> empty the directory. CLOSURE UNSOUND (an audited suite failed with an unchanged closure) distrusts every entry.
#   suite_cache_audit_seed HEAD_SHA SALT  -> sha256(HEAD_SHA . SALT) as 64 hex digits.
#   suite_cache_audit_count N_HITS        -> how many hits are re-run anyway: min(N, max(20, ceil(N * 10 / 100))). HMD_SUITE_CACHE_AUDIT_PCT can only RAISE
#                                            the 10. The gate recomputes this number, so it is defined here and nowhere else.
#   suite_cache_audit_pick SEED HITS_FILE -> that many suite names, one per line, sorted: those with the smallest sha256(SEED:name). The same seed picks the
#                                            same set whatever the order of the hits. With no usable seed, or no sha256 tool, it prints EVERY hit (never
#                                            fewer than asked) and says so. HITS_FILE: one suite name per line; blank lines and duplicates are ignored.
#   suite_cache_compose_receipt DIR SALT NOW COLD FRESH CACHED AUDITED SUITES_FILE
#                                         -> the `cache` block of the sweep receipt on one line, built from the entries ON DISK of the suites listed (each
#                                            must have a valid entry under SALT, no older than the cap), so the receipt cannot claim more than the cache
#                                            shows. FRESH = suites that ran (audited hits included), CACHED = hits served without running, AUDITED = hits
#                                            re-run as the audit sample. COLD is true or false, and a cold run served nothing from the cache.
#
# CALL SEQUENCE (the sweep): D=$(suite_cache_dir "$REPO"); salt and per-suite closure hashes come from bin/heimdall-suite-closure.
#   per suite     suite_cache_lookup "$D" "$s" "$closure" "$salt" "${HMD_SUITE_CACHE_MAX_DAYS:-}" "$(date +%s)"    HIT -> write $s into HITS_FILE
#   audit         suite_cache_audit_pick "$(suite_cache_audit_seed "$HEAD" "$salt")" HITS_FILE     those hits are launched anyway; the rest are CACHED
#   after a run   clean green -> suite_cache_store "$D" "$s" "$json" (the entry above, built with jq from the facts the sweep holds); any other result of
#                 a suite that ran -> hand over what there is, or suite_cache_invalidate "$D" "$s": a suite that ran and is not green must not keep an old green
#   CLOSURE UNSOUND  suite_cache_purge "$D"
#   receipt       suite_cache_compose_receipt "$D" "$salt" "$(date +%s)" "$cold" "$fresh" "$cached" "$audited" SUITES_FILE   (all green suites, fresh and cached)
#
# NEVER CACHED: a red, a timeout, a discrepancy, unparsed counts, a live suite, a run with a tree-integrity violation (the schema refuses each); a suite
# the disk floor never started has no record to hand over. A COOPERATING-AGENT CONTROL, NOT A SECURITY BOUNDARY: the entries are plain local files, like
# receipts/last-sweep.json. The closure/salt binding and the audit catch stale, copied and mismatched entries and an under-approximated closure; they do
# not stop anyone who can write the files and the hashes. bin/heimdall-suite-closure verify-receipt re-derives what a receipt claims.
#
# Bash 3.2 compatible (no associative arrays, no mapfile), nounset-safe, safe to source under `set -euo pipefail`: it sets no shell option and no
# variable except _HMD_SUITE_CACHE_SH, SUITE_CACHE_* and _SUITE_CACHE_*. Needs jq; the audit needs one of sha256sum, shasum, openssl.

# shellcheck disable=SC2016  # the jq programs are single-quoted on purpose: their $names are jq variables, not shell ones
[ -n "${_HMD_SUITE_CACHE_SH:-}" ] && return 0 2>/dev/null || true
_HMD_SUITE_CACHE_SH=1

SUITE_CACHE_LIMIT_DAYS=7        # the age cap's ceiling; a caller may only tighten it
SUITE_CACHE_AUDIT_MIN=20        # at least this many hits are re-run (or all of them when there are fewer)
SUITE_CACHE_AUDIT_PCT=10        # at least this percent of the hits are re-run; HMD_SUITE_CACHE_AUDIT_PCT may only raise it
SUITE_CACHE_MAX_BYTES=16384     # an entry over this is not one: it is never read whole into memory or handed to a parser
SUITE_CACHE_DIR_NAME='suite-cache'

# Written out, not ranges: [a-z] is not ASCII-only in every locale, and a suite name becomes a file name.
_SUITE_CACHE_ALNUM='abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789'
_SUITE_CACHE_NAMECH="${_SUITE_CACHE_ALNUM}._-"

# The schema: ONE definition, in jq, read by store (the writer) and lookup / compose (the readers). `spec` is the table of fields (name, test, what
# the value must be); entry_problem is the first thing wrong with an entry, or null when it is a clean green record. `rx` anchors with \A \z: in
# jq's regex engine `$` also matches before a trailing newline, and "<64 hex digits>\n" must not pass for a hash.
_SUITE_CACHE_JQ_DEFS='
def rx($re): type == "string" and test("\\A(?:" + $re + ")\\z");
def spec: . as $e | [
  {k: "suite", ok: ($e.suite | rx("[A-Za-z0-9][A-Za-z0-9._-]{0,199}")), what: "a bare suite file name (letters, digits, . _ -)"},
  {k: "closure_sha", ok: ($e.closure_sha | rx("[0-9a-f]{64}")), what: "the closure hash: 64 lowercase hex digits"},
  {k: "salt", ok: ($e.salt | rx("[0-9a-f]{64}")), what: "the salt: 64 lowercase hex digits"},
  {k: "exit_code", ok: ($e.exit_code | type == "number" and . == 0), what: "0 (a suite that exited non-zero or timed out is never cached)"},
  {k: "assertions_passed", ok: ($e.assertions_passed | type == "number" and . == floor and . >= 0 and . < 1e9), what: "the parsed count of passed assertions (a run whose counts could not be parsed is never cached)"},
  {k: "assertions_failed", ok: ($e.assertions_failed | type == "number" and . == 0), what: "0 (a run that printed failures is never cached, even when it exited 0)"},
  {k: "live_reason", ok: ($e.live_reason | type == "string" and . == ""), what: "the empty string (a live or credentialed suite is never cached)"},
  {k: "tree_integrity_violations", ok: ($e.tree_integrity_violations | type == "number" and . == 0), what: "0 (nothing from a run that violated tree integrity is cached)"},
  {k: "finished_at", ok: ($e.finished_at | rx("[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z") and (try (fromdateiso8601 | true) catch false)), what: "a UTC timestamp like 2026-10-19T12:00:00Z"},
  {k: "ran_at_head", ok: ($e.ran_at_head | rx("[0-9a-f]{40}(?:[0-9a-f]{24})?")), what: "the full object id of the commit the suite ran at"},
  {k: "duration_s", ok: ($e.duration_s | type == "number" and . >= 0 and . < 1e9), what: "a number of seconds, 0 or more"}
];
def entry_problem:
  if type != "object" then "the entry is not a JSON object"
  else
    . as $e
    | (spec | map(select(.ok | not)) | first | select(. != null) | "\(.k) must be \(.what)")
      // ((($e | keys) - (spec | map(.k))) | select(length > 0) | "unknown field(s): " + join(", "))
      // null
  end;
'

_suite_cache_err() { printf 'suite-cache: %s\n' "$*" >&2; }
_suite_cache_miss() { printf 'MISS %s\n' "$*"; }
_suite_cache_have_jq() { command -v jq >/dev/null 2>&1; }
_suite_cache_is_hex64() { case "${1:-}" in ''|*[!0-9a-f]*) return 1 ;; esac; [ "${#1}" -eq 64 ]; }
_suite_cache_is_uint() { case "${1:-}" in ''|*[!0-9]*) return 1 ;; esac; [ "${#1}" -le 12 ]; }

# _suite_cache_dir_problem DIR -- why DIR cannot be the cache directory; prints nothing when it can. Always returns 0.
_suite_cache_dir_problem() {
  case "${1:-}" in
    '') echo "no cache directory given" ;;
    */"$SUITE_CACHE_DIR_NAME"|"$SUITE_CACHE_DIR_NAME") if [ -L "$1" ]; then echo "the cache directory is a symbolic link"; fi ;;
    *) echo "the cache directory must be named $SUITE_CACHE_DIR_NAME" ;;
  esac
}

# _suite_cache_days VALUE -- the age cap in days: VALUE when it is a whole number below the ceiling, else the ceiling (junk is said on stderr).
_suite_cache_days() {
  case "${1:-}" in
    '') printf '%s' "$SUITE_CACHE_LIMIT_DAYS" ;;
    *[!0-9]*)
      _suite_cache_err "the age cap '$1' is not a whole number of days -- using $SUITE_CACHE_LIMIT_DAYS"
      printf '%s' "$SUITE_CACHE_LIMIT_DAYS" ;;
    *)
      if [ "${#1}" -le 6 ] && [ "$((10#$1))" -lt "$SUITE_CACHE_LIMIT_DAYS" ]; then printf '%s' "$((10#$1))"; else printf '%s' "$SUITE_CACHE_LIMIT_DAYS"; fi ;;
  esac
}

# _suite_cache_audit_pct -- the audit percentage: HMD_SUITE_CACHE_AUDIT_PCT when it is a whole percent ABOVE the default, else the default.
_suite_cache_audit_pct() {
  local v="${HMD_SUITE_CACHE_AUDIT_PCT:-}" p="$SUITE_CACHE_AUDIT_PCT"
  case "$v" in
    '') ;;
    *[!0-9]*) _suite_cache_err "HMD_SUITE_CACHE_AUDIT_PCT='$v' is not a whole percent from 0 to 100 -- using $p" ;;
    *)
      if [ "${#v}" -gt 3 ] || [ "$((10#$v))" -gt 100 ]; then
        _suite_cache_err "HMD_SUITE_CACHE_AUDIT_PCT='$v' is not a whole percent from 0 to 100 -- using $p"
      elif [ "$((10#$v))" -gt "$p" ]; then
        p="$((10#$v))"
      fi ;;
  esac
  printf '%s' "$p"
}

# _suite_cache_sha256 -- stdin to its sha256 as 64 lowercase hex digits; rc 1 when no sha256 tool is installed.
_suite_cache_sha256() {
  local out
  if command -v sha256sum >/dev/null 2>&1; then out="$(sha256sum)"
  elif command -v shasum >/dev/null 2>&1; then out="$(shasum -a 256)"
  elif command -v openssl >/dev/null 2>&1; then out="$(openssl dgst -sha256)"; out="${out##* }"
  else return 1
  fi
  printf '%s\n' "${out%% *}"
}

# _suite_cache_entry_problem JSON SUITE -- what is wrong with JSON as the record of SUITE; prints nothing when it is a clean green one.
_suite_cache_entry_problem() {
  local json="${1-}" suite="${2:-}" out
  if [ "${#json}" -gt "$SUITE_CACHE_MAX_BYTES" ]; then echo "the entry is over $SUITE_CACHE_MAX_BYTES bytes"; return 0; fi
  out="$(printf '%s' "$json" | jq -s -r --arg suite "$suite" "$_SUITE_CACHE_JQ_DEFS"'
    if length != 1 then "the entry must be exactly one JSON value"
    else .[0] | (entry_problem) // (if .suite != $suite then "suite is \"\(.suite)\" but the entry is for \"\($suite)\"" else null end)
    end // empty' 2>/dev/null)" || out="the entry is not valid JSON"
  printf '%s' "$out"
}

# _suite_cache_entry_read DIR NAME -- the entry of suite NAME as its file holds it, once it passes the schema; rc 1 (reason on stderr) otherwise.
_suite_cache_entry_read() {
  local f="$1/$2.json" body problem
  if [ -L "$f" ]; then _suite_cache_err "$2: the entry is a symbolic link"; return 1; fi
  if [ ! -f "$f" ]; then _suite_cache_err "$2: no entry"; return 1; fi
  { body="$(head -c "$((SUITE_CACHE_MAX_BYTES + 1))" "$f")"; } 2>/dev/null || { _suite_cache_err "$2: the entry is unreadable"; return 1; }
  if [ "${#body}" -gt "$SUITE_CACHE_MAX_BYTES" ]; then _suite_cache_err "$2: the entry is over $SUITE_CACHE_MAX_BYTES bytes"; return 1; fi
  problem="$(_suite_cache_entry_problem "$body" "$2")"
  if [ -n "$problem" ]; then _suite_cache_err "$2: $problem"; return 1; fi
  printf '%s\n' "$body"
}

# _suite_cache_names FILE STRICT -- the suite names listed in FILE (blank lines skipped, paths reduced to file names), de-duplicated and sorted.
#   A line that is no suite name is skipped with a note (STRICT 0) or refuses the whole list (STRICT 1).
_suite_cache_names() {
  local list="${1:-}" strict="${2:-0}" line nm out=""
  if [ -z "$list" ] || [ ! -f "$list" ] || [ ! -r "$list" ]; then _suite_cache_err "cannot read the suite list '$list'"; return 1; fi
  while IFS= read -r line || [ -n "$line" ]; do
    [ -n "$line" ] || continue
    if nm="$(suite_cache_name "$line")"; then
      out="$out$nm"$'\n'
    elif [ "$strict" = 1 ]; then
      _suite_cache_err "'$line' in $list is not a suite name"; return 1
    else
      _suite_cache_err "skipping '$line' in $list: it is no suite name, so it cannot be a cache hit"
    fi
  done < "$list"
  printf '%s' "$out" | LC_ALL=C sort -u
}

# suite_cache_dir REPO -- the cache directory of a repository.
suite_cache_dir() {
  if [ -z "${1:-}" ]; then _suite_cache_err "suite_cache_dir: no repository given"; return 1; fi
  printf '%s/.heimdall/receipts/%s\n' "${1%/}" "$SUITE_CACHE_DIR_NAME"
}

# suite_cache_name SUITE -- the bare, safe file name of a suite (test/x.test.sh -> x.test.sh), or rc 1.
suite_cache_name() {
  local n="${1:-}"
  n="${n##*/}"
  case "$n" in
    '') return 1 ;;
    [!$_SUITE_CACHE_ALNUM]*) return 1 ;;
    *[!$_SUITE_CACHE_NAMECH]*) return 1 ;;
  esac
  [ "${#n}" -le 200 ] || return 1
  printf '%s\n' "$n"
}

# suite_cache_lookup DIR SUITE CLOSURE_SHA SALT MAX_DAYS NOW -- "HIT" (rc 0) or "MISS <reason>" (rc 1).
suite_cache_lookup() {
  local dir suite closure salt now days f body problem out
  dir="${1:-}"; dir="${dir%/}"
  closure="${3:-}"; salt="${4:-}"; now="${6:-}"
  _suite_cache_have_jq || { _suite_cache_miss "jq is required"; return 1; }
  suite="$(suite_cache_name "${2:-}")" || { _suite_cache_miss "unsafe suite name"; return 1; }
  _suite_cache_is_hex64 "$closure" || { _suite_cache_miss "bad closure hash (64 lowercase hex digits expected)"; return 1; }
  _suite_cache_is_hex64 "$salt" || { _suite_cache_miss "bad salt (64 lowercase hex digits expected)"; return 1; }
  _suite_cache_is_uint "$now" || { _suite_cache_miss "bad clock value (epoch seconds expected)"; return 1; }
  problem="$(_suite_cache_dir_problem "$dir")"
  if [ -n "$problem" ]; then _suite_cache_miss "$problem"; return 1; fi
  days="$(_suite_cache_days "${5:-}")"
  f="$dir/$suite.json"
  if [ -L "$f" ]; then _suite_cache_miss "entry is a symbolic link"; return 1; fi
  if [ ! -e "$f" ]; then _suite_cache_miss "no entry"; return 1; fi
  if [ ! -f "$f" ]; then _suite_cache_miss "entry is not a regular file"; return 1; fi
  { body="$(head -c "$((SUITE_CACHE_MAX_BYTES + 1))" "$f")"; } 2>/dev/null || { _suite_cache_miss "unreadable entry"; return 1; }   # the group's redirect also hushes bash 4.4+'s "ignored null byte" warning: a corrupt entry is a MISS, quietly
  if [ "${#body}" -gt "$SUITE_CACHE_MAX_BYTES" ]; then _suite_cache_miss "entry is oversized"; return 1; fi
  out="$(printf '%s' "$body" | jq -s -r --arg suite "$suite" --arg closure "$closure" --arg salt "$salt" --argjson days "$days" --argjson now "$now" "$_SUITE_CACHE_JQ_DEFS"'
    def verdict:
      if length != 1 then "MISS invalid entry: expected exactly one JSON value"
      else .[0]
        | (entry_problem) as $p
        | if $p != null then "MISS invalid entry: " + $p
          elif .suite != $suite then "MISS entry belongs to another suite"
          elif .closure_sha != $closure then "MISS closure changed"
          elif .salt != $salt then "MISS salt changed"
          else ($now - (.finished_at | fromdateiso8601)) as $age
            | if $age < 0 then "MISS entry is dated in the future"
              elif $age > ($days * 86400) then "MISS entry is \(($age / 86400) | floor) day(s) old (limit \($days))"
              else "HIT" end
          end
      end;
    try verdict catch "MISS invalid entry"' 2>/dev/null)" || out=""
  case "$out" in
    HIT) echo HIT; return 0 ;;
    "MISS "*) echo "$out"; return 1 ;;
  esac
  _suite_cache_miss "corrupt entry (not valid JSON)"
  return 1
}

# suite_cache_store DIR SUITE JSON -- keep JSON as the entry of SUITE when it is a clean green record of it; otherwise refuse and forget the suite.
suite_cache_store() {
  local dir suite json dest tmp problem
  dir="${1:-}"; dir="${dir%/}"; json="${3-}"
  _suite_cache_have_jq || { _suite_cache_err "not stored: jq is required"; return 1; }
  suite="$(suite_cache_name "${2:-}")" || { _suite_cache_err "not stored: unsafe suite name '${2:-}'"; return 1; }
  problem="$(_suite_cache_dir_problem "$dir")"
  if [ -n "$problem" ]; then _suite_cache_err "not stored ($suite): $problem"; return 1; fi
  dest="$dir/$suite.json"
  problem="$(_suite_cache_entry_problem "$json" "$suite")"
  if [ -n "$problem" ]; then
    rm -f "$dest" 2>/dev/null || true
    _suite_cache_err "not stored ($suite): $problem"
    return 1
  fi
  if [ -d "$dest" ] && [ ! -L "$dest" ]; then _suite_cache_err "not stored ($suite): $dest is a directory"; return 1; fi
  if [ ! -d "$dir" ]; then
    { mkdir -p "$(dirname "$dir")" && ( umask 077 && mkdir "$dir" ); } 2>/dev/null || [ -d "$dir" ] || { _suite_cache_err "not stored ($suite): cannot create $dir"; return 1; }
  fi
  tmp="$(mktemp "$dir/.entry.XXXXXX" 2>/dev/null)" || { _suite_cache_err "not stored ($suite): cannot create a temporary file in $dir"; return 1; }
  [ ! -L "$dest" ] || rm -f "$dest"
  if printf '%s' "$json" | jq -S -c . > "$tmp" 2>/dev/null && chmod 600 "$tmp" 2>/dev/null && mv -f "$tmp" "$dest" 2>/dev/null; then
    return 0
  fi
  rm -f "$tmp" 2>/dev/null || true
  _suite_cache_err "not stored ($suite): could not write $dest"
  return 1
}

# suite_cache_invalidate DIR SUITE -- forget one suite's entry (idempotent).
suite_cache_invalidate() {
  local dir suite problem
  dir="${1:-}"; dir="${dir%/}"
  suite="$(suite_cache_name "${2:-}")" || { _suite_cache_err "invalidate: unsafe suite name '${2:-}'"; return 1; }
  problem="$(_suite_cache_dir_problem "$dir")"
  if [ -n "$problem" ]; then _suite_cache_err "invalidate ($suite): $problem"; return 1; fi
  rm -f "$dir/$suite.json" 2>/dev/null || true
  if [ -e "$dir/$suite.json" ] || [ -L "$dir/$suite.json" ]; then _suite_cache_err "invalidate ($suite): could not remove $dir/$suite.json"; return 1; fi
  return 0
}

# suite_cache_purge DIR -- empty the cache directory (CLOSURE UNSOUND). Links inside are removed, never followed.
suite_cache_purge() {
  local dir problem
  dir="${1:-}"; dir="${dir%/}"
  problem="$(_suite_cache_dir_problem "$dir")"
  if [ -n "$problem" ]; then _suite_cache_err "purge: $problem"; return 1; fi
  [ -d "$dir" ] || return 0
  find -P "$dir" -mindepth 1 -delete 2>/dev/null || { _suite_cache_err "purge: could not empty $dir"; return 1; }
  return 0
}

# suite_cache_audit_seed HEAD_SHA SALT -- the seed of the audit sample: sha256 of the HEAD sha followed by the salt.
suite_cache_audit_seed() {
  local head="${1:-}" salt="${2:-}" out
  case "$head" in ''|*[!0-9a-f]*) _suite_cache_err "audit_seed: HEAD must be a full lowercase hex object id"; return 1 ;; esac
  if [ "${#head}" -ne 40 ] && [ "${#head}" -ne 64 ]; then _suite_cache_err "audit_seed: HEAD must be a full lowercase hex object id"; return 1; fi
  _suite_cache_is_hex64 "$salt" || { _suite_cache_err "audit_seed: the salt must be 64 lowercase hex digits"; return 1; }
  out="$(printf '%s%s' "$head" "$salt" | _suite_cache_sha256)" || { _suite_cache_err "audit_seed: no sha256 tool (sha256sum, shasum or openssl)"; return 1; }
  printf '%s\n' "$out"
}

# suite_cache_audit_count N_HITS -- how many of N hits are re-run anyway.
suite_cache_audit_count() {
  local n="${1:-}" pct k
  _suite_cache_is_uint "$n" || { _suite_cache_err "audit_count: '$n' is not a whole number"; return 1; }
  n=$((10#$n))
  pct="$(_suite_cache_audit_pct)"
  k=$(( (n * pct + 99) / 100 ))
  [ "$k" -ge "$SUITE_CACHE_AUDIT_MIN" ] || k="$SUITE_CACHE_AUDIT_MIN"
  [ "$k" -le "$n" ] || k="$n"
  printf '%s\n' "$k"
}

# suite_cache_audit_pick SEED HITS_FILE -- the hits to re-run: audit_count of them, those whose sha256(SEED:name) sorts first.
suite_cache_audit_pick() {
  local seed="${1:-}" names n k probe ranked nm h
  names="$(_suite_cache_names "${2:-}" 0)" || return 1
  [ -n "$names" ] || return 0
  n="$(printf '%s\n' "$names" | wc -l | tr -d '[:space:]')"
  k="$(suite_cache_audit_count "$n")" || return 1
  if ! _suite_cache_is_hex64 "$seed"; then
    _suite_cache_err "audit_pick: no usable seed ('$seed') -- every cache hit is audited instead"
    printf '%s\n' "$names"
    return 0
  fi
  probe="$(printf x | _suite_cache_sha256 2>/dev/null)" || probe=""
  if [ "${#probe}" -ne 64 ]; then
    _suite_cache_err "audit_pick: no sha256 tool (sha256sum, shasum or openssl) -- every cache hit is audited instead"
    printf '%s\n' "$names"
    return 0
  fi
  ranked="$(printf '%s\n' "$names" | while IFS= read -r nm; do
      h="$(printf '%s:%s' "$seed" "$nm" | _suite_cache_sha256)" || exit 1
      [ "${#h}" -eq 64 ] || exit 1
      printf '%s %s\n' "$h" "$nm"
    done | LC_ALL=C sort | awk -v k="$k" 'NR <= k { print $2 }' | LC_ALL=C sort)" || {
    _suite_cache_err "audit_pick: hashing failed -- every cache hit is audited instead"
    printf '%s\n' "$names"
    return 0
  }
  printf '%s\n' "$ranked"
}

# suite_cache_compose_receipt DIR SALT NOW COLD FRESH CACHED AUDITED SUITES_FILE -- the receipt's `cache` block, from the entries on disk.
suite_cache_compose_receipt() {
  local dir salt now cold fresh cached audited names nm stream="" body problem out
  dir="${1:-}"; dir="${dir%/}"
  salt="${2:-}"; now="${3:-}"; cold="${4:-}"; fresh="${5:-}"; cached="${6:-}"; audited="${7:-}"
  _suite_cache_have_jq || { _suite_cache_err "compose: jq is required"; return 1; }
  problem="$(_suite_cache_dir_problem "$dir")"
  if [ -n "$problem" ]; then _suite_cache_err "compose: $problem"; return 1; fi
  _suite_cache_is_hex64 "$salt" || { _suite_cache_err "compose: bad salt (64 lowercase hex digits expected)"; return 1; }
  _suite_cache_is_uint "$now" || { _suite_cache_err "compose: bad clock value '$now' (epoch seconds expected)"; return 1; }
  case "$cold" in true|false) ;; *) _suite_cache_err "compose: cold must be true or false (got '$cold')"; return 1 ;; esac
  for nm in "$fresh" "$cached" "$audited"; do
    _suite_cache_is_uint "$nm" || { _suite_cache_err "compose: the counts must be whole numbers (got '$nm')"; return 1; }
  done
  fresh=$((10#$fresh)); cached=$((10#$cached)); audited=$((10#$audited))
  if [ "$audited" -gt "$fresh" ]; then
    _suite_cache_err "compose: audited ($audited) cannot exceed the suites that ran ($fresh): an audited hit is a hit that was re-run"; return 1
  fi
  if [ "$cold" = true ] && { [ "$cached" -ne 0 ] || [ "$audited" -ne 0 ]; }; then
    _suite_cache_err "compose: a cold run serves nothing from the cache (cached=$cached audited=$audited)"; return 1
  fi
  names="$(_suite_cache_names "${8:-}" 1)" || return 1
  if [ -n "$names" ]; then
    while IFS= read -r nm; do
      body="$(_suite_cache_entry_read "$dir" "$nm")" || return 1
      stream="$stream$body"$'\n'
    done <<EOF
$names
EOF
  fi
  out="$(printf '%s' "$stream" | jq -s -c --arg salt "$salt" --argjson now "$now" --argjson cold "$cold" --argjson fresh "$fresh" \
      --argjson cached "$cached" --argjson audited "$audited" --argjson limit "$SUITE_CACHE_LIMIT_DAYS" '
    . as $es
    | ($es | map(select(.salt != $salt)) | first) as $other
    | ($es | map(select(($now - (.finished_at | fromdateiso8601)) < 0)) | first) as $future
    | ($es | map(select(($now - (.finished_at | fromdateiso8601)) > ($limit * 86400))) | first) as $old
    | if $other != null then {problem: "\($other.suite) was written under another salt"}
      elif $future != null then {problem: "\($future.suite) is dated in the future"}
      elif $old != null then {problem: "\($old.suite) is older than the \($limit)-day limit"}
      else {cache: {
          mode: "closure", salt: $salt, suites_fresh: $fresh, suites_cached: $cached, audited: $audited, cold: $cold,
          oldest_entry_age_days: (if ($es | length) == 0 then null else (($now - ($es | map(.finished_at | fromdateiso8601) | min)) / 86400 | floor) end),
          entries: ($es | map({suite, closure_sha, finished_at}))}}
      end' 2>/dev/null)" || out=""
  if [ -z "$out" ]; then _suite_cache_err "compose: could not build the cache block"; return 1; fi
  problem="$(printf '%s' "$out" | jq -r '.problem // empty' 2>/dev/null)" || problem="the composed block is unreadable"
  if [ -n "$problem" ]; then _suite_cache_err "compose: $problem"; return 1; fi
  printf '%s' "$out" | jq -c '.cache'
}
