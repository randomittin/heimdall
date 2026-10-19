#!/usr/bin/env bash
# test/suite-cache.test.sh -- proves bin/lib/suite-cache.sh: the per-suite cache of GREEN results that lets a sweep skip a suite whose
# closure (every file it can reach) and salt (the test infrastructure it runs on) are unchanged.
#
# WHY THIS EXISTS. The cache is a GATE: a wrong HIT hides a regression for up to a week. So every way a HIT can be wrongly granted has a
# case here, and a mutation matrix proves the cases can fail (a green run of THESE tests means the guards hold AND that breaking any
# of them is noticed).
#
# Proven here (every call runs in a fresh /bin/bash -- 3.2 on macOS -- under `set -euo pipefail`, the strictest way to source the lib):
#   A  lookup   a fresh entry for the same closure + salt is a HIT; a changed closure, a changed salt, an entry older than the age cap
#               (7 days, inclusive; a caller may only TIGHTEN it), one dated in the future, a missing, corrupt, oversized, symlinked,
#               directory-shaped or another suite's entry, and every malformed argument are a MISS with a reason -- never a crash
#   B  store    only a CLEAN GREEN record is stored: a red, a timeout, a discrepancy (exit 0 but failures printed), unparsed counts, a
#               live suite and a tree-integrity violation are refused, and a refusal forgets what was cached for that suite before; the
#               write is atomic, 0600 in a 0700 directory, and never follows a link out of the cache directory
#   C  audit    seed = sha256(HEAD sha + salt); max(20, ceil(10%)) of the hits are re-run (the percentage may only be RAISED); the pick is
#               deterministic, independent of the order of the hits, different for a different seed, and falls back to auditing EVERY hit
#               (never fewer) when it has no usable seed or no sha256 tool
#   D  purge    CLOSURE UNSOUND empties the cache; it refuses any directory not named suite-cache and never follows a link
#   E  compose  the `cache` block of the sweep receipt is built from the entries ON DISK and refuses to claim what they do not show
#   F  schema   mutation walk: every field of an entry deleted, nulled and given a wrong value must be refused by store AND ignored by
#               lookup (falsifiability: killed/total), then every guard of the lib is broken one at a time and some case must go RED
#
# HERMETIC: a throwaway directory under $TMPDIR, nothing outside it is read or written, no network, no real repository state.
# EXIT: 0 = every proof holds; 1 = any FAIL.
# shellcheck disable=SC2016  # jq programs, `bash -c` bodies and the mutation needles are written LITERALLY: their $names must reach the callee unexpanded
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
LIB_REAL="$ROOT/bin/lib/suite-cache.sh"
LIB="$LIB_REAL"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  \033[32mPASS\033[0m %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  \033[31mFAIL\033[0m %s\n' "$1"; [ -n "${2:-}" ] && printf '        %s\n' "$2"; return 0; }

command -v jq >/dev/null 2>&1 || { echo "FATAL: jq required" >&2; exit 2; }
[ -f "$LIB_REAL" ] || { echo "FATAL: $LIB_REAL is missing" >&2; exit 2; }

T="$(mktemp -d "${TMPDIR:-/tmp}/suite-cache-test.XXXXXX")" || { echo "FATAL: mktemp failed" >&2; exit 2; }
T="$(cd "$T" && pwd -P)"
cleanup() { chmod -R u+rwX "$T" 2>/dev/null; rm -rf "$T"; }
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

LIB_BASH=/bin/bash; [ -x "$LIB_BASH" ] || LIB_BASH="$(command -v bash)"
CACHE="$T/repo/.heimdall/receipts/suite-cache"

# ── harness ──────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
RC=0; O=""; E=""
libe() { # libe [K=V ...] -- FUNC [ARGS...]: ONE call of a lib function in a fresh strict-mode shell -> RC, O (stdout), E (stderr)
  local -a ev=()
  while [ $# -gt 0 ] && [ "$1" != -- ]; do ev[${#ev[@]}]="$1"; shift; done
  shift
  env ${ev[@]+"${ev[@]}"} "$LIB_BASH" -c 'set -euo pipefail; . "$1"; shift; "$@"' _ "$LIB" "$@" >"$T/o" 2>"$T/e"
  RC=$?
  O="$(cat "$T/o")"; E="$(cat "$T/e")"
  return 0
}
lib() { libe -- "$@"; }
dbg() { printf 'rc=%s out=[%s] err=[%s]' "$RC" "$(printf '%s' "$O" | head -c 300)" "$(printf '%s' "$E" | head -c 300)"; }
check() { local desc="$1"; shift; if "$@"; then ok "$desc"; else bad "$desc" "$(dbg)"; fi; }

sha() { if command -v shasum >/dev/null 2>&1; then printf '%s' "$1" | shasum -a 256 | awk '{print $1}'; else printf '%s' "$1" | sha256sum | awk '{print $1}'; fi; }
iso() { date -u -r "$1" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date -u -d "@$1" '+%Y-%m-%dT%H:%M:%SZ'; }
perm() { stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1"; }
nfiles() { find "$1" -mindepth 1 -maxdepth 1 | wc -l | tr -d ' '; }
mkhits() { local i=1; : > "$2"; while [ "$i" -le "$1" ]; do printf 'hit%03d.test.sh\n' "$i" >> "$2"; i=$((i + 1)); done; }

NOW0=1760000000                      # a fixed "now" (2025-10-09T08:53:20Z): ages are whatever the case says, never the real clock
DAY=86400
CL1="$(sha closure-one)"; CL2="$(sha closure-two)"; CLA="$(sha closure-a)"; CLB="$(sha closure-b)"; CLC="$(sha closure-c)"
SALT1="$(sha salt-one)"; SALT2="$(sha salt-two)"
HEAD1="$(sha head-one | cut -c1-40)"; HEAD2="$(sha head-two | cut -c1-40)"
SEED_A="$(sha seed-a)"; SEED_B="$(sha seed-b)"

BASE_ENTRY="$(jq -n -c --arg cl "$CL1" --arg salt "$SALT1" --arg fin "$(iso "$NOW0")" --arg head "$HEAD1" '{
  suite: "alpha.test.sh", closure_sha: $cl, salt: $salt, exit_code: 0, assertions_passed: 12, assertions_failed: 0, live_reason: "",
  tree_integrity_violations: 0, finished_at: $fin, ran_at_head: $head, duration_s: 3}')"

entry() { # entry [FIELD=JSON ...] -> the valid entry for alpha.test.sh with each FIELD replaced by the JSON value (FIELD=@del removes it)
  local j="$BASE_ENTRY" a k v
  for a in "$@"; do
    k="${a%%=*}"; v="${a#*=}"
    if [ "$v" = "@del" ]; then j="$(printf '%s' "$j" | jq -c --arg k "$k" 'del(.[$k])')"
    else j="$(printf '%s' "$j" | jq -c --arg k "$k" --argjson v "$v" '.[$k] = $v')"; fi
  done
  printf '%s' "$j"
}
fresh()  { [ -n "$T" ] || exit 2; rm -rf "$T/repo"; mkdir -p "$T/repo/.heimdall/receipts"; }
plant()  { mkdir -p "$CACHE"; printf '%s\n' "$2" > "$CACHE/$1.json"; }              # plant SUITE TEXT: a file the store never wrote
store()  { lib suite_cache_store "$CACHE" "$1" "$2"; }                              # store SUITE JSON
look()   { lib suite_cache_lookup "$CACHE" "$1" "$2" "$3" "$4" "$5"; }              # look SUITE CLOSURE SALT MAX_DAYS NOW
lk()     { look alpha.test.sh "$CL1" "$SALT1" 7 "${1:-$NOW0}"; }                    # lk [NOW]: the lookup the valid entry must answer HIT
stored() { store "$1" "$2"; [ "$RC" -eq 0 ]; }                                      # stored SUITE JSON: ... and it was accepted

hit()  { [ "$RC" -eq 0 ] && [ "$O" = HIT ] && [ -z "$E" ]; }
miss() { # miss [PHRASE]: the last call was a MISS -- rc 1, exactly one line starting "MISS " that holds PHRASE, nothing on stderr
  [ "$RC" -eq 1 ] || return 1
  case "$O" in *$'\n'*) return 1 ;; "MISS "*"${1:-}"*) ;; *) return 1 ;; esac
  [ -z "$E" ]
}
refused() { # refused [PHRASE]: the last call was refused -- rc 1, nothing on stdout, PHRASE named on stderr
  [ "$RC" -eq 1 ] && [ -z "$O" ] && case "$E" in *"${1:-}"*) true ;; *) false ;; esac
}

# ── 0. the lib exists, parses on the oldest bash we support, and does not change its caller ───────────────────────────────────────────
echo "-- 0. the lib parses and leaves its caller alone --"
p_parses() { "$LIB_BASH" -n "$LIB"; }
p_options() {
  local out
  out="$("$LIB_BASH" -c 'a=$-; . "$1"; . "$1"; b=$-; if [ "$a" = "$b" ]; then echo same; else echo "changed:$a:$b"; fi' _ "$LIB" 2>&1)"
  [ "$out" = same ] || return 1
  out="$("$LIB_BASH" -c 'set -u; . "$1"; echo ok' _ "$LIB" 2>&1)"
  [ "$out" = ok ]
}
check "the lib parses under $("$LIB_BASH" -c 'echo "bash $BASH_VERSION"')" p_parses
check "sourcing it (twice, and under set -u) changes no shell option and prints nothing" p_options

# ── A. lookup ─────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
echo "-- A. lookup: HIT only for a green entry bound to the closure, the salt and the clock --"
p_roundtrip() {
  fresh; stored alpha.test.sh "$(entry)" || return 1
  [ -f "$CACHE/alpha.test.sh.json" ] || return 1
  lk; hit
}
p_miss_closure() { fresh; stored alpha.test.sh "$(entry)" || return 1; look alpha.test.sh "$CL2" "$SALT1" 7 "$NOW0"; miss closure; }
p_miss_salt()    { fresh; stored alpha.test.sh "$(entry)" || return 1; look alpha.test.sh "$CL1" "$SALT2" 7 "$NOW0"; miss salt; }
p_miss_8days()   { fresh; stored alpha.test.sh "$(entry)" || return 1; lk "$((NOW0 + 8 * DAY))"; miss "day(s) old"; }
p_age_edge() {
  fresh; stored alpha.test.sh "$(entry)" || return 1
  lk "$((NOW0 + 7 * DAY))"; hit || return 1                                          # exactly at the cap: still a HIT
  lk "$((NOW0 + 7 * DAY + 1))"; miss "day(s) old"                                    # one second over: a MISS
}
p_miss_future()  { fresh; stored alpha.test.sh "$(entry)" || return 1; lk "$((NOW0 - 1))"; miss future; }
p_miss_absent() {
  fresh; lk; miss "no entry" || return 1                                              # no cache directory at all
  mkdir -p "$CACHE"; lk; miss "no entry"                                              # a cache directory without that entry
}
p_corrupt() {
  local junk
  fresh
  for junk in '{not json' '' '[]' 'null' '"text"' '7' '{}' '{"suite":"alpha.test.sh"}' "$(entry) $(entry)" '{"a":1}garbage'; do
    plant alpha.test.sh "$junk"; lk; miss || { printf 'junk [%s]: ' "$junk"; return 1; }
  done
  printf '\000\001\002{{{' > "$CACHE/alpha.test.sh.json"; lk; miss                    # binary junk
}
p_oversized() {
  fresh; mkdir -p "$CACHE"
  { entry; head -c 20000 /dev/zero | tr '\0' ' '; echo; } > "$CACHE/alpha.test.sh.json"   # valid JSON, then 20 KB of blanks
  lk; miss oversized
}
p_symlink_entry() {
  fresh; stored alpha.test.sh "$(entry)" || return 1
  cp "$CACHE/alpha.test.sh.json" "$T/elsewhere.json"; rm -f "$CACHE/alpha.test.sh.json"; ln -s "$T/elsewhere.json" "$CACHE/alpha.test.sh.json"
  lk; miss "symbolic link"
}
p_dir_entry()    { fresh; mkdir -p "$CACHE/alpha.test.sh.json"; lk; miss "not a regular file"; }
p_other_suite() {
  fresh; stored alpha.test.sh "$(entry)" || return 1
  cp "$CACHE/alpha.test.sh.json" "$CACHE/beta.test.sh.json"                           # alpha's record under beta's name
  look beta.test.sh "$CL1" "$SALT1" 7 "$NOW0"; miss "another suite"
}
p_unreadable() {
  [ "$(id -u)" -ne 0 ] || return 0                                                    # root reads anything: nothing to prove
  fresh; stored alpha.test.sh "$(entry)" || return 1
  chmod 000 "$CACHE/alpha.test.sh.json"; lk; chmod 600 "$CACHE/alpha.test.sh.json"
  miss unreadable
}
p_bad_args() {
  local v
  fresh; stored alpha.test.sh "$(entry)" || return 1
  for v in '' xyz "$(printf '%s' "$CL1" | tr a-f A-F)" "${CL1}0" "${CL1%?}"; do
    look alpha.test.sh "$v" "$SALT1" 7 "$NOW0"; miss "closure" || { printf 'closure [%s]: ' "$v"; return 1; }
    look alpha.test.sh "$CL1" "$v" 7 "$NOW0"; miss "salt" || { printf 'salt [%s]: ' "$v"; return 1; }
  done
  for v in '' abc -5 1.5 99999999999999; do
    look alpha.test.sh "$CL1" "$SALT1" 7 "$v"; miss "clock" || { printf 'now [%s]: ' "$v"; return 1; }
  done
  for v in '' 'dir/' .. .hidden 'a b.test.sh' -rf 'a;b' "$(printf 'a\nb')" 'é.test.sh'; do
    look "$v" "$CL1" "$SALT1" 7 "$NOW0"; miss "unsafe suite name" || { printf 'suite [%s]: ' "$v"; return 1; }
  done
  look test/alpha.test.sh "$CL1" "$SALT1" 7 "$NOW0"; hit || return 1                  # a path names the suite by its file name
  lib suite_cache_lookup "$T/repo/cache" alpha.test.sh "$CL1" "$SALT1" 7 "$NOW0"; miss "must be named suite-cache"
}
p_days() {
  fresh; stored alpha.test.sh "$(entry)" || return 1
  look alpha.test.sh "$CL1" "$SALT1" 30 "$((NOW0 + 8 * DAY))"; miss "day(s) old" || return 1    # a caller can never LOOSEN the cap
  look alpha.test.sh "$CL1" "$SALT1" 2 "$((NOW0 + 3 * DAY))"; miss "day(s) old" || return 1      # ... but may tighten it
  look alpha.test.sh "$CL1" "$SALT1" 0 "$((NOW0 + 3600))"; miss "day(s) old" || return 1
  look alpha.test.sh "$CL1" "$SALT1" '' "$((NOW0 + 3 * DAY))"; hit || return 1                   # unset = the default cap, silently
  look alpha.test.sh "$CL1" "$SALT1" abc "$((NOW0 + 3 * DAY))"                                   # junk = the default cap, said out loud
  [ "$RC" -eq 0 ] && [ "$O" = HIT ] && case "$E" in *"abc"*) true ;; *) false ;; esac || return 1
  look alpha.test.sh "$CL1" "$SALT1" -1 "$((NOW0 + 8 * DAY))"; [ "$RC" -eq 1 ] && case "$O" in "MISS "*) true ;; *) false ;; esac
}
check "a fresh entry for the same closure and salt is a HIT (the entry file exists)" p_roundtrip
check "a different closure is a MISS naming the closure" p_miss_closure
check "a different salt is a MISS naming the salt" p_miss_salt
check "an 8-day-old entry is a MISS" p_miss_8days
check "the age cap is inclusive: exactly 7 days is a HIT, 7 days and a second is a MISS" p_age_edge
check "an entry dated in the future is a MISS" p_miss_future
check "no entry (and no cache directory) is a MISS, not an error" p_miss_absent
check "corrupt, empty, non-object, multi-value and binary entries are a MISS (rc 1, one line, silent stderr), never a crash" p_corrupt
check "an entry over the size bound is a MISS" p_oversized
check "an entry that is a symlink is a MISS (no link is followed)" p_symlink_entry
check "an entry that is a directory is a MISS" p_dir_entry
check "another suite's record under this suite's file name is a MISS" p_other_suite
check "an unreadable entry is a MISS" p_unreadable
check "malformed closure, salt, clock, suite name and directory are a MISS with a reason" p_bad_args
check "the age cap can be tightened but never loosened; junk means the default, said on stderr" p_days

# ── B. store ──────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
echo "-- B. store: only a clean green record is kept; a refusal forgets the suite --"
p_refuse_class() { # p_refuse_class FIELD=JSON...: a record that differs from the valid one in these fields is refused and nothing is cached
  local f
  fresh; store alpha.test.sh "$(entry "$@")"
  f="${1%%=*}"
  refused "$f" && [ ! -e "$CACHE/alpha.test.sh.json" ]
}
p_red()        { p_refuse_class exit_code=1; }
p_timeout()    { p_refuse_class exit_code=124; }
p_discrep()    { p_refuse_class assertions_failed=2; }
p_unparsed()   { p_refuse_class assertions_passed='"?"'; }
p_live()       { p_refuse_class live_reason='"reads/mutates the DEPLOYED control plane"'; }
p_treeviol()   { p_refuse_class tree_integrity_violations=1; }
p_forgets() {
  fresh; stored alpha.test.sh "$(entry)" || return 1
  lk; hit || return 1
  store alpha.test.sh "$(entry exit_code=1)"; refused exit_code || return 1             # the suite re-ran and went red ...
  [ ! -e "$CACHE/alpha.test.sh.json" ] || return 1
  lk; miss "no entry" || return 1                                                        # ... so its old green is gone
  stored alpha.test.sh "$(entry)" || return 1
  store alpha.test.sh ""; refused "" || return 1                                         # nothing to record (e.g. unparsed counts) forgets too
  [ ! -e "$CACHE/alpha.test.sh.json" ]
}
p_store_files() {
  fresh; stored alpha.test.sh "$(entry)" || return 1
  [ "$(perm "$CACHE/alpha.test.sh.json")" = 600 ] || return 1
  [ "$(perm "$CACHE")" = 700 ] || return 1
  [ "$(nfiles "$CACHE")" -eq 1 ] || return 1                                              # no temp file left behind
  [ "$(wc -l < "$CACHE/alpha.test.sh.json" | tr -d ' ')" -eq 1 ] || return 1
  [ "$(jq -S -c . "$CACHE/alpha.test.sh.json")" = "$(entry | jq -S -c .)" ]
}
p_replace() {
  fresh; stored alpha.test.sh "$(entry)" || return 1
  stored alpha.test.sh "$(entry closure_sha="\"$CL2\"")" || return 1
  look alpha.test.sh "$CL2" "$SALT1" 7 "$NOW0"; hit || return 1
  lk; miss closure || return 1
  [ "$(nfiles "$CACHE")" -eq 1 ]
}
p_store_links() {
  fresh; mkdir -p "$CACHE" "$T/decoydir"; printf 'decoy\n' > "$T/decoy.txt"; rm -rf "$T/decoydir"/*
  ln -s "$T/decoy.txt" "$CACHE/alpha.test.sh.json"                                       # a link to a file
  ln -s "$T/decoydir" "$CACHE/beta.test.sh.json"                                         # a link to a directory
  stored alpha.test.sh "$(entry)" || return 1
  stored beta.test.sh "$(entry suite='"beta.test.sh"')" || return 1
  [ "$(cat "$T/decoy.txt")" = decoy ] && [ -z "$(ls -A "$T/decoydir")" ] || return 1
  [ -f "$CACHE/alpha.test.sh.json" ] && [ ! -L "$CACHE/alpha.test.sh.json" ] && [ -f "$CACHE/beta.test.sh.json" ] && [ ! -L "$CACHE/beta.test.sh.json" ] || return 1
  lk; hit
}
p_store_dir_is_entry() { fresh; mkdir -p "$CACHE/alpha.test.sh.json"; store alpha.test.sh "$(entry)"; refused "directory" && [ -z "$(ls -A "$CACHE/alpha.test.sh.json")" ]; }
p_store_symdir() {
  fresh; rm -rf "$T/decoydir2"; mkdir -p "$T/decoydir2"; printf 'keep\n' > "$T/decoydir2/keep"
  ln -s "$T/decoydir2" "$CACHE"
  store alpha.test.sh "$(entry)"; refused "symbolic link" || return 1
  lk; miss "symbolic link" || return 1
  lib suite_cache_purge "$CACHE"; refused "symbolic link" || return 1
  lib suite_cache_invalidate "$CACHE" alpha.test.sh; refused "symbolic link" || return 1
  [ "$(ls -A "$T/decoydir2")" = keep ]                                                   # nothing was written into, or deleted from, the target
}
p_store_mismatch() {
  fresh; store beta.test.sh "$(entry)"; refused "alpha.test.sh" || return 1              # alpha's record offered for beta
  [ ! -e "$CACHE/beta.test.sh.json" ] && [ ! -e "$CACHE/alpha.test.sh.json" ]
}
p_store_junk() {
  local junk
  fresh
  for junk in '' '{not json' '[]' 'null' '{} {}' "$(entry) $(entry)" "$(entry)$(head -c 20000 /dev/zero | tr '\0' ' ')"; do
    store alpha.test.sh "$junk"; refused || { printf 'junk [%s]: ' "$(printf '%s' "$junk" | head -c 40)"; return 1; }
  done
  [ ! -e "$CACHE/alpha.test.sh.json" ]
}
p_store_unknown_field() { fresh; store alpha.test.sh "$(entry extra=1)"; refused "unknown field" && [ ! -e "$CACHE/alpha.test.sh.json" ]; }
p_store_names() {
  local v
  fresh
  stored test/../../escape.test.sh "$(entry suite='"escape.test.sh"')" || return 1       # a path is reduced to its file name: nothing lands outside
  [ -f "$CACHE/escape.test.sh.json" ] && [ ! -e "$T/repo/escape.test.sh.json" ] && [ ! -e "$T/escape.test.sh.json" ] && [ ! -e "$T/repo/.heimdall/escape.test.sh.json" ] || return 1
  for v in '' 'dir/' .. .hidden 'a b' -x 'a;b'; do
    store "$v" "$(entry)"; refused "unsafe suite name" || { printf 'suite [%s]: ' "$v"; return 1; }
  done
}
p_store_dir_name() {
  fresh
  lib suite_cache_store "$T/repo/cache" alpha.test.sh "$(entry)"; refused "must be named suite-cache" && [ ! -e "$T/repo/cache" ]
}
p_invalidate() {
  fresh; stored alpha.test.sh "$(entry)" || return 1; stored beta.test.sh "$(entry suite='"beta.test.sh"')" || return 1
  lib suite_cache_invalidate "$CACHE" alpha.test.sh; [ "$RC" -eq 0 ] || return 1
  lk; miss "no entry" || return 1
  look beta.test.sh "$CL1" "$SALT1" 7 "$NOW0"; hit || return 1                           # the others stay
  lib suite_cache_invalidate "$CACHE" alpha.test.sh; [ "$RC" -eq 0 ] || return 1         # idempotent
  lib suite_cache_invalidate "$CACHE" 'a b'; refused "unsafe suite name" || return 1
  lib suite_cache_invalidate "$T/repo/cache" alpha.test.sh; refused "must be named suite-cache"
}
p_dir() {
  lib suite_cache_dir /x/y/; [ "$RC" -eq 0 ] && [ "$O" = /x/y/.heimdall/receipts/suite-cache ] || return 1
  lib suite_cache_dir ""; [ "$RC" -eq 1 ] || return 1
  lib suite_cache_name test/alpha.test.sh; [ "$RC" -eq 0 ] && [ "$O" = alpha.test.sh ] || return 1
  lib suite_cache_name 'a b'; [ "$RC" -eq 1 ] && [ -z "$O" ]
}
check "a red suite (non-zero exit) is never cached" p_red
check "a timeout (exit 124) is never cached" p_timeout
check "a discrepancy (exit 0 but failures printed) is never cached" p_discrep
check "unparsed counts are never cached" p_unparsed
check "a live suite is never cached" p_live
check "a run with a tree-integrity violation is never cached" p_treeviol
check "a refused result forgets the suite's earlier green (a red always re-runs), also when there is nothing to record" p_forgets
check "an entry is one line, 0600, in a 0700 directory, with no temp file left behind" p_store_files
check "a new result replaces the old one in place" p_replace
check "a symlink at the entry path is replaced, never written through (file or directory target)" p_store_links
check "a directory at the entry path is refused, not moved into" p_store_dir_is_entry
check "a symlinked cache directory is refused by store, lookup, purge and invalidate, and its target is untouched" p_store_symdir
check "a record for another suite is refused" p_store_mismatch
check "empty, non-JSON, non-object, multi-value and oversized input is refused" p_store_junk
check "an unknown field is refused (the schema is exact)" p_store_unknown_field
check "a path as suite name lands inside the cache directory only; unsafe names are refused" p_store_names
check "a directory not named suite-cache is refused (nothing is created)" p_store_dir_name
check "invalidate forgets one suite, is idempotent, and validates its arguments" p_invalidate
check "suite_cache_dir and suite_cache_name" p_dir

# ── C. audit ──────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
echo "-- C. audit: seeded by HEAD sha + salt, max(20, 10%), deterministic, never fewer than asked --"
mkhits 30 "$T/h30"; mkhits 7 "$T/h7"
sort -r "$T/h30" > "$T/h30r"; { cat "$T/h30"; echo; cat "$T/h30"; } > "$T/h30d"
p_seed() {
  local want
  want="$(sha "${HEAD1}${SALT1}")"
  lib suite_cache_audit_seed "$HEAD1" "$SALT1"; [ "$RC" -eq 0 ] && [ "$O" = "$want" ] || return 1       # sha256(HEAD sha + salt), independently recomputed
  lib suite_cache_audit_seed "$HEAD2" "$SALT1"; [ "$RC" -eq 0 ] && [ "$O" != "$want" ] || return 1
  lib suite_cache_audit_seed "$HEAD1" "$SALT2"; [ "$RC" -eq 0 ] && [ "$O" != "$want" ] || return 1
  lib suite_cache_audit_seed "${HEAD1%?}" "$SALT1"; refused || return 1
  lib suite_cache_audit_seed "" "$SALT1"; refused || return 1
  lib suite_cache_audit_seed "$HEAD1" "abc"; refused
}
p_count() {
  local pair
  for pair in 0:0 1:1 7:7 19:19 20:20 21:20 100:20 200:20 201:21 536:54 1000:100; do
    lib suite_cache_audit_count "${pair%%:*}"; [ "$RC" -eq 0 ] && [ "$O" = "${pair#*:}" ] || { printf 'n=%s: ' "${pair%%:*}"; return 1; }
  done
  lib suite_cache_audit_count abc; refused || return 1
  libe HMD_SUITE_CACHE_AUDIT_PCT=100 -- suite_cache_audit_count 536; [ "$O" = 536 ] || return 1       # the percentage may be raised ...
  libe HMD_SUITE_CACHE_AUDIT_PCT=50 -- suite_cache_audit_count 100; [ "$O" = 50 ] || return 1
  libe HMD_SUITE_CACHE_AUDIT_PCT=5 -- suite_cache_audit_count 536; [ "$O" = 54 ] || return 1          # ... never lowered
  libe HMD_SUITE_CACHE_AUDIT_PCT=0 -- suite_cache_audit_count 536; [ "$O" = 54 ] || return 1
  libe HMD_SUITE_CACHE_AUDIT_PCT=abc -- suite_cache_audit_count 536; [ "$O" = 54 ] && case "$E" in *"abc"*) true ;; *) false ;; esac || return 1
  libe HMD_SUITE_CACHE_AUDIT_PCT=101 -- suite_cache_audit_count 536; [ "$O" = 54 ] && [ -n "$E" ]
}
p_pick_basic() {
  local a b c
  lib suite_cache_audit_pick "$SEED_A" "$T/h30"; [ "$RC" -eq 0 ] && [ -z "$E" ] || return 1; a="$O"
  [ "$(printf '%s\n' "$a" | wc -l | tr -d ' ')" -eq 20 ] || return 1                                  # max(20, 10% of 30) = 20
  [ "$(printf '%s\n' "$a" | sort -u | wc -l | tr -d ' ')" -eq 20 ] || return 1                        # no name twice
  if printf '%s\n' "$a" | grep -qvxFf "$T/h30"; then return 1; fi                                     # every pick is a hit
  [ "$(printf '%s\n' "$a")" = "$(printf '%s\n' "$a" | LC_ALL=C sort)" ] || return 1                   # printed sorted
  lib suite_cache_audit_pick "$SEED_A" "$T/h30"; [ "$O" = "$a" ] || return 1                          # same seed, same set
  lib suite_cache_audit_pick "$SEED_B" "$T/h30"; [ "$RC" -eq 0 ] && b="$O" && [ "$b" != "$a" ] || return 1   # another seed, another set
  [ "$(printf '%s\n' "$b" | wc -l | tr -d ' ')" -eq 20 ] || return 1
  lib suite_cache_audit_pick "$SEED_A" "$T/h30r"; c="$O"; [ "$c" = "$a" ] || return 1                 # the order of the hits is irrelevant
  lib suite_cache_audit_pick "$SEED_A" "$T/h30d"; [ "$O" = "$a" ]                                     # so are blank lines and duplicates
}
p_pick_seed() { # the seed is what drives the pick: another seed over the same hits picks another set
  local a
  lib suite_cache_audit_pick "$SEED_A" "$T/h30"; a="$O"
  lib suite_cache_audit_pick "$SEED_B" "$T/h30"
  [ "$RC" -eq 0 ] && [ -n "$a" ] && [ "$O" != "$a" ]
}
p_pick_small() {
  lib suite_cache_audit_pick "$SEED_A" "$T/h7"; [ "$RC" -eq 0 ] && [ "$O" = "$(cat "$T/h7")" ] || return 1   # 7 hits: all 7
  : > "$T/h0"; lib suite_cache_audit_pick "$SEED_A" "$T/h0"; [ "$RC" -eq 0 ] && [ -z "$O" ] && [ -z "$E" ]
}
p_pick_pct() {
  libe HMD_SUITE_CACHE_AUDIT_PCT=100 -- suite_cache_audit_pick "$SEED_A" "$T/h30"; [ "$RC" -eq 0 ] && [ "$O" = "$(cat "$T/h30")" ] || return 1
  libe HMD_SUITE_CACHE_AUDIT_PCT=5 -- suite_cache_audit_pick "$SEED_A" "$T/h30"; [ "$(printf '%s\n' "$O" | wc -l | tr -d ' ')" -eq 20 ]
}
p_pick_fallback() {
  local v
  for v in '' xyz "${SEED_A%?}"; do
    lib suite_cache_audit_pick "$v" "$T/h30"
    [ "$RC" -eq 0 ] && [ "$O" = "$(cat "$T/h30")" ] && [ -n "$E" ] || { printf 'seed [%s]: ' "$v"; return 1; }   # no usable seed: audit EVERY hit
  done
}
p_pick_input() {
  lib suite_cache_audit_pick "$SEED_A" "$T/does-not-exist"; refused "cannot read" || return 1
  printf 'hit001.test.sh\nbad name\nhit002.test.sh\n../hit003.test.sh\n' > "$T/hbad"
  lib suite_cache_audit_pick "$SEED_A" "$T/hbad"
  [ "$RC" -eq 0 ] && [ "$O" = "$(printf 'hit001.test.sh\nhit002.test.sh\nhit003.test.sh')" ] && case "$E" in *"bad name"*) true ;; *) false ;; esac
}
p_pick_nohash() {
  local d tool
  d="$T/nohash"; mkdir -p "$d"
  for tool in awk sort wc tr cat sed grep head mktemp mv rm chmod find mkdir jq ls date; do
    command -v "$tool" >/dev/null 2>&1 && ln -sf "$(command -v "$tool")" "$d/$tool"
  done
  env PATH="$d" "$LIB_BASH" -c 'command -v sha256sum || command -v shasum || command -v openssl' >/dev/null 2>&1 && return 1   # the shim really has no sha256 tool
  libe PATH="$d" -- suite_cache_audit_pick "$SEED_A" "$T/h30"
  [ "$RC" -eq 0 ] && [ "$O" = "$(cat "$T/h30")" ] && case "$E" in *"sha256"*) true ;; *) false ;; esac || return 1
  libe PATH="$d" -- suite_cache_audit_seed "$HEAD1" "$SALT1"; refused "sha256"
}
check "audit seed = sha256(HEAD sha + salt), recomputed independently; bad inputs are refused" p_seed
check "audit count = min(n, max(20, ceil(10% of n))); the percentage can be raised, never lowered; junk is said out loud" p_count
check "audit pick: 20 of 30, no repeats, only hits, sorted; same seed = same set; another seed = another set; order, blanks and duplicates are irrelevant" p_pick_basic
check "audit pick: up to 20 hits are all audited; no hits is no output" p_pick_small
check "audit pick honours a raised percentage and ignores a lowered one" p_pick_pct
check "audit pick without a usable seed audits EVERY hit (never fewer), and says so" p_pick_fallback
check "audit pick: an unreadable hits file is refused; a line that is no suite name is skipped, a path is reduced to its file name" p_pick_input
check "audit pick and seed without any sha256 tool: every hit is audited / the seed is refused" p_pick_nohash

# ── D. purge ──────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
echo "-- D. purge: CLOSURE UNSOUND empties the cache, and only the cache --"
p_purge() {
  fresh; stored alpha.test.sh "$(entry)" || return 1; stored beta.test.sh "$(entry suite='"beta.test.sh"')" || return 1
  : > "$CACHE/.entry.ABC123"; printf 'x' > "$CACHE/stray.txt"; mkdir -p "$CACHE/sub"; : > "$CACHE/sub/inner"
  ln -s "$T" "$CACHE/lnk"                                                                  # a link out of the cache: removed, never followed
  lib suite_cache_purge "$CACHE"; [ "$RC" -eq 0 ] && [ -z "$O" ] && [ -z "$E" ] || return 1
  [ -d "$CACHE" ] && [ -z "$(ls -A "$CACHE")" ] || return 1
  [ -d "$T/repo" ] && [ -f "$T/o" ] || return 1                                            # what the link pointed at is intact
  lk; miss "no entry" || return 1
  lib suite_cache_purge "$CACHE"; [ "$RC" -eq 0 ] || return 1                              # an empty cache purges fine
  lib suite_cache_purge "$T/gone/suite-cache"; [ "$RC" -eq 0 ]                             # so does one that does not exist
}
p_purge_guards() {
  mkdir -p "$T/other"; printf 'keep\n' > "$T/other/x.json"
  lib suite_cache_purge "$T/other"; refused "must be named suite-cache" && [ -f "$T/other/x.json" ] || return 1
  lib suite_cache_purge ""; refused || return 1
  [ -f "$T/other/x.json" ]
}
check "purge empties the directory (entries, temp files, strays, subdirectories, links) and leaves link targets alone" p_purge
check "purge refuses a directory not named suite-cache and an empty argument, and deletes nothing" p_purge_guards

# ── E. compose ────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
echo "-- E. compose: the receipt's cache block is built from the entries on disk --"
printf 'gamma.test.sh\nalpha.test.sh\n\nbeta.test.sh\nalpha.test.sh\n' > "$T/suites3"
mk3() { # three green entries under SALT1: alpha 2 days old, beta 3 days and 5 hours, gamma 1 hour
  fresh
  stored alpha.test.sh "$(entry closure_sha="\"$CLA\"" finished_at="\"$(iso "$((NOW0 - 2 * DAY))")\"")" || return 1
  stored beta.test.sh "$(entry suite='"beta.test.sh"' closure_sha="\"$CLB\"" finished_at="\"$(iso "$((NOW0 - 3 * DAY - 18000))")\"")" || return 1
  stored gamma.test.sh "$(entry suite='"gamma.test.sh"' closure_sha="\"$CLC\"" finished_at="\"$(iso "$((NOW0 - 3600))")\"")" || return 1
}
compose() { lib suite_cache_compose_receipt "$CACHE" "$SALT1" "$NOW0" "$@"; }            # compose COLD FRESH CACHED AUDITED LIST
p_compose_ok() {
  mk3 || return 1
  compose false 1 2 1 "$T/suites3"; [ "$RC" -eq 0 ] && [ -z "$E" ] || return 1
  printf '%s' "$O" | jq -e --arg salt "$SALT1" --arg cla "$CLA" --arg clb "$CLB" --arg clc "$CLC" --arg fa "$(iso "$((NOW0 - 2 * DAY))")" '
    (keys | sort) == ["audited","cold","entries","mode","oldest_entry_age_days","salt","suites_cached","suites_fresh"]
    and .mode == "closure" and .salt == $salt and .suites_fresh == 1 and .suites_cached == 2 and .audited == 1 and .cold == false
    and .oldest_entry_age_days == 3
    and (.entries | map(.suite)) == ["alpha.test.sh","beta.test.sh","gamma.test.sh"]
    and (.entries | map(.closure_sha)) == [$cla,$clb,$clc]
    and (.entries | all((keys | sort) == ["closure_sha","finished_at","suite"]))
    and .entries[0].finished_at == $fa' >/dev/null || return 1
  [ "$(printf '%s\n' "$O" | wc -l | tr -d ' ')" -eq 1 ] || return 1                        # one line of JSON
  compose true 3 0 0 "$T/suites3"; [ "$RC" -eq 0 ] && printf '%s' "$O" | jq -e '.cold == true and .suites_cached == 0' >/dev/null || return 1
  : > "$T/suites0"; compose false 0 0 0 "$T/suites0"
  [ "$RC" -eq 0 ] && printf '%s' "$O" | jq -e '.entries == [] and .oldest_entry_age_days == null' >/dev/null
}
p_compose_refusals() {
  mk3 || return 1
  printf 'alpha.test.sh\ndelta.test.sh\n' > "$T/suites_missing"
  compose false 1 1 0 "$T/suites_missing"; refused "delta.test.sh" || return 1           # a suite that has no entry cannot be claimed green
  compose true 1 2 1 "$T/suites3"; refused "cold" || return 1                              # a cold run served nothing from the cache
  compose false 1 2 3 "$T/suites3"; refused "audited" || return 1                          # audited suites are suites that ran
  compose false x 2 1 "$T/suites3"; refused || return 1
  compose maybe 1 2 1 "$T/suites3"; refused "cold" || return 1
  compose false 1 2 1 "$T/does-not-exist"; refused "cannot read" || return 1
  lib suite_cache_compose_receipt "$CACHE" abc "$NOW0" false 1 2 1 "$T/suites3"; refused "salt" || return 1
  lib suite_cache_compose_receipt "$CACHE" "$SALT1" abc false 1 2 1 "$T/suites3"; refused "clock" || return 1
  lib suite_cache_compose_receipt "$T/repo/cache" "$SALT1" "$NOW0" false 1 2 1 "$T/suites3"; refused "must be named suite-cache" || return 1
  cp "$CACHE/beta.test.sh.json" "$T/beta.bak"; printf '{garbage' > "$CACHE/beta.test.sh.json"
  compose false 1 2 1 "$T/suites3"; refused "beta.test.sh" || return 1                    # a corrupt entry
  cp "$T/beta.bak" "$CACHE/beta.test.sh.json"
  cp "$CACHE/alpha.test.sh.json" "$CACHE/gamma.test.sh.json"
  compose false 1 2 1 "$T/suites3"; refused "gamma.test.sh"                               # alpha's record under gamma's name
}
p_compose_cold()    { mk3 || return 1; compose true 1 2 1 "$T/suites3"; refused cold; }       # a cold run that claims cached suites
p_compose_audited() { mk3 || return 1; compose false 1 2 3 "$T/suites3"; refused audited; }   # more audited hits than suites that ran
p_compose_bad_entry() { # p_compose_bad_entry PHRASE FIELD=JSON...: gamma's entry differs from a valid one in these fields -> the block is refused
  local phrase="$1"; shift
  mk3 || return 1
  stored gamma.test.sh "$(entry suite='"gamma.test.sh"' "$@")" || return 1
  compose false 1 2 1 "$T/suites3"; refused "$phrase"
}
p_compose_salt()   { p_compose_bad_entry salt salt="\"$SALT2\""; }                                              # written under another salt
p_compose_old()    { p_compose_bad_entry old finished_at="\"$(iso "$((NOW0 - 8 * DAY))")\""; }                 # older than the cap: the gate would refuse the receipt
p_compose_future() { p_compose_bad_entry future finished_at="\"$(iso "$((NOW0 + 1000))")\""; }                 # dated after now
check "compose builds the exact cache block (mode, salt, counts, cold, oldest age in whole days, sorted entries) from the entries on disk" p_compose_ok
check "compose refuses a missing, corrupt or mislabelled entry, an unreadable list, bad arguments and a wrong directory" p_compose_refusals
check "compose refuses a cold run that claims cached suites" p_compose_cold
check "compose refuses more audited hits than suites that ran" p_compose_audited
check "compose refuses an entry written under another salt" p_compose_salt
check "compose refuses an entry older than the age cap (the gate would refuse that receipt)" p_compose_old
check "compose refuses an entry dated in the future" p_compose_future

# ── F. falsifiability ─────────────────────────────────────────────────────────────────────────────────────────────────────────────
echo "-- F. falsifiability: every field of an entry, then every guard of the lib --"
FIELDS="suite closure_sha salt exit_code assertions_passed assertions_failed live_reason tree_integrity_violations finished_at ran_at_head duration_s"
wrong() { # a value of the right shape's neighbour that the schema must refuse
  case "$1" in
    suite) echo '"beta.test.sh"' ;;                      closure_sha) echo '"zz"' ;;
    salt) echo '"zz"' ;;                                 exit_code) echo 1 ;;
    assertions_passed) echo '"12"' ;;                    assertions_failed) echo 1 ;;
    live_reason) echo '"live"' ;;                        tree_integrity_violations) echo 1 ;;
    finished_at) echo '"2025-10-09 08:53:20"' ;;         ran_at_head) echo '"abc"' ;;
    duration_s) echo -1 ;;
  esac
}
MT=0; MK=0
walk() { # walk LABEL FIELD=JSON: store must refuse the mutated entry AND lookup must not trust it when planted on disk
  local label="$1" mutated
  MT=$((MT + 1))
  mutated="$(entry "$2")"
  fresh; store alpha.test.sh "$mutated"
  if ! { [ "$RC" -eq 1 ] && [ ! -e "$CACHE/alpha.test.sh.json" ]; }; then bad "schema mutation survived the STORE: $label" "$(dbg)"; return 0; fi
  fresh; plant alpha.test.sh "$mutated"; lk
  if ! miss; then bad "schema mutation survived the LOOKUP: $label" "$(dbg)"; return 0; fi
  MK=$((MK + 1))
}
fresh
if stored alpha.test.sh "$(entry)" && lk && hit; then ok "control: the unmutated entry is stored and is a HIT (the walk below can pass only by refusing the mutations)"; else bad "control failed" "$(dbg)"; fi
for f in $FIELDS; do
  walk "$f deleted" "$f=@del"
  walk "$f null" "$f=null"
  walk "$f wrong ($(wrong "$f"))" "$f=$(wrong "$f")"
done
if [ "$MK" -eq "$MT" ]; then ok "every mutated field is refused by store and ignored by lookup ($MK/$MT)"; else bad "schema mutations survived: $MK of $MT killed"; fi
SCHEMA_K="$MK"; SCHEMA_T="$MT"

# The guards of the lib, broken one at a time: the lib with a one-token change must fail the case that guards it.
mutate() { # mutate FIND REPLACE -> $T/mut.sh: the lib with the first literal FIND replaced; rc 3 when FIND is not in the lib
  FIND="$1" REPL="$2" awk 'BEGIN { f = ENVIRON["FIND"]; r = ENVIRON["REPL"] }
    !done && (i = index($0, f)) { $0 = substr($0, 1, i - 1) r substr($0, i + length(f)); done = 1 }
    { print }
    END { exit done ? 0 : 3 }' "$LIB_REAL" > "$T/mut.sh"
}
mutant() { # mutant NAME FIND REPLACE PROBE...
  local name="$1" find="$2" repl="$3"; shift 3
  MT=$((MT + 1))
  if ! mutate "$find" "$repl"; then bad "mutant $name did not apply: [$find] is not in the lib"; return 0; fi
  if ! "$LIB_BASH" -n "$T/mut.sh" 2>/dev/null; then bad "mutant $name is not valid shell, so it proves nothing"; return 0; fi
  LIB="$T/mut.sh"
  if "$@" >/dev/null 2>&1; then bad "mutant $name SURVIVED: $* still passes against the broken lib"
  else MK=$((MK + 1)); ok "mutant $name killed by $*"; fi
  LIB="$LIB_REAL"
}
#       name            the one-token change to the lib                                       the case that must go red
mutant age-cap          'elif $age > ($days * 86400)'          'elif $age < ($days * 86400)'          p_age_edge
mutant closure          'elif .closure_sha != $closure then'   'elif false then'                      p_miss_closure
mutant salt             'elif .salt != $salt then'             'elif false then'                      p_miss_salt
mutant future           'if $age < 0 then'                     'if false then'                        p_miss_future
mutant other-suite      'elif .suite != $suite then'           'elif false then'                      p_other_suite
mutant cap-ceiling      '-lt "$SUITE_CACHE_LIMIT_DAYS" ]'      '-lt 99999 ]'                          p_days
mutant red              '($e.exit_code | type == "number" and . == 0)'                '($e.exit_code | type == "number")'                p_red
mutant discrepancy      '($e.assertions_failed | type == "number" and . == 0)'        '($e.assertions_failed | type == "number")'        p_discrep
mutant live             '($e.live_reason | type == "string" and . == "")'             '($e.live_reason | type == "string")'              p_live
mutant tree-integrity   '($e.tree_integrity_violations | type == "number" and . == 0)' '($e.tree_integrity_violations | type == "number")' p_treeviol
mutant forget-on-refusal 'rm -f "$dest" 2>/dev/null || true'   ':'                                    p_forgets
mutant mode-0600        'chmod 600 "$tmp"'                     'chmod 644 "$tmp"'                     p_store_files
mutant dir-0700         'umask 077 &&'                         'umask 022 &&'                         p_store_files
mutant entry-symlink    'if [ -L "$f" ]; then _suite_cache_miss "entry is a symbolic link"' 'if false; then _suite_cache_miss "entry is a symbolic link"' p_symlink_entry
mutant size-bound       'if [ "${#body}" -gt "$SUITE_CACHE_MAX_BYTES" ]; then _suite_cache_miss "entry is oversized"' 'if false; then _suite_cache_miss "entry is oversized"' p_oversized
mutant dir-name         'echo "the cache directory must be named $SUITE_CACHE_DIR_NAME"' ':'          p_purge_guards
mutant store-suite      'if .suite != $suite then "suite is'   'if false then "suite is'             p_store_mismatch
mutant audit-seed       '"$seed" "$nm" | _suite_cache_sha256'  '"x" "$nm" | _suite_cache_sha256'      p_pick_seed
mutant audit-min        'SUITE_CACHE_AUDIT_MIN=20'             'SUITE_CACHE_AUDIT_MIN=1'              p_count
mutant audit-raise-only 'elif [ "$((10#$v))" -gt "$p" ]; then' 'elif true; then'                      p_count
mutant audit-fallback   'if ! _suite_cache_is_hex64 "$seed"; then' 'if false; then'                   p_pick_fallback
mutant compose-cold     'if [ "$cold" = true ] && {'           'if false && {'                        p_compose_cold
mutant compose-audited  'if [ "$audited" -gt "$fresh" ]; then' 'if false; then'                       p_compose_audited
mutant compose-salt     'if $other != null then'               'if false then'                        p_compose_salt
mutant compose-old      'elif $old != null then'               'elif false then'                      p_compose_old
mutant compose-future   'elif $future != null then'           'elif false then'                      p_compose_future

if [ "$MK" -eq "$MT" ]; then ok "falsifiability: $MK/$MT mutations killed (fields $SCHEMA_K/$SCHEMA_T, guards $((MK - SCHEMA_K))/$((MT - SCHEMA_T)))"; else bad "falsifiability: only $MK/$MT mutations killed"; fi
echo "falsifiability: $MK/$MT"

printf '\nsuite-cache: %s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
