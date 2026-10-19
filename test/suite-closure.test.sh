#!/usr/bin/env bash
# test/suite-closure.test.sh -- THE STATIC DEPENDENCY CLOSURE OF A SUITE, AND THE PROOF THAT IT CANNOT MISS A DEPENDENCY IT CLAIMS TO SEE.
#
# WHAT IT TESTS. bin/heimdall-suite-closure (the launcher) and bin/lib/suite_closure.py (the engine): for every test/*.test.sh the
# set of tracked files its result can depend on (the closure), the closure hash (sha256 over sorted `path<TAB>blob_id`, blob ids read
# from git objects), the salt that invalidates every cached result at once, test/closure-hints.json (the escape hatch for what a static
# scan cannot see) and `verify-receipt`, which re-derives every closure hash at the graded commit instead of trusting a receipt's flag.
# bin/lib/hook-owned-path.sh decides which tracked paths are never part of any closure (the hooks' own journal and ledger writes).
#
# WHY IT EXISTS. A per-suite result cache is only safe if "this suite's closure did not change" really means "nothing it could read
# changed". A closure that misses an edge turns a cached green into a hidden regression, so the engine is graded the way the oracles
# are: by MUTATION. Each kind of dependency below is edited one byte at a time in a throwaway git repo built from real files (no mocks),
# and the suite's closure hash MUST change; an unrelated edit MUST NOT. `falsifiability: <killed>/<total>` counts the dependency
# mutations noticed over the ones made, and the run is red unless that is 1.0.
#
# Proven here:
#   A  the CLI on the real repo (HEAD, read from git objects): one `suite<TAB>sha` line per test/*.test.sh, bin/heimdall is in the
#      closure of test/banner-version.test.sh, the salt is a sha256
#   B  the fixture's CLI contract: hash-all / hash / deps agree, `deps` lists exactly what is hashed, output is deterministic,
#      a dirty tree is REFUSED (a cache key must describe HEAD) while --rev reads objects only
#   C  mutation proof, one fixture suite per dependency kind: source of a library, exec by PATH basename, a data file read by path,
#      a directory token with fixture files, a test/lib helper, a dispatcher sub-command, a wildcard (git ls-files), hints `extra`,
#      a header comment in a SUITE, a transitive dependency through an executable, hints `always_run`; plus the precision half:
#      an edit to an unrelated file, to a dispatcher arm nobody invoked, and to a tool only an executable's COMMENT names changes nothing
#   D  hints are validated (an `extra` path that names nothing, an unknown key, a non-boolean refuse; they never silently no-op)
#   E  the salt moves with test/run-all.sh, test/lib, the hints file and bin/lib/suite-cache.sh, and not with an unrelated file
#   F  verify-receipt: a green cold receipt and a green cache-composed receipt pass; each field of the cache block mutated alone is
#      refused with its reason (stale closure, old entry, salt, under-audited, missing suite, forged head, lying `cold`, ...); a gate
#      may only TIGHTEN the age limit and RAISE the audit share
#
# HERMETIC: the fixture lives under $TMPDIR with its own HOME; nothing touches the real receipts or the real work tree.
# EXIT: 0 = every proof holds and falsifiability is 1.0; 1 = anything else.
# shellcheck disable=SC2016  # the fixture files are written LITERALLY: their $VARs must reach the file unexpanded
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
CLI="$ROOT/bin/heimdall-suite-closure"

PASS=0; FAIL=0; KILLED=0; MUTANTS=0
ok()  { PASS=$((PASS+1)); printf '  \033[32mPASS\033[0m %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  \033[31mFAIL\033[0m %s\n' "$1"; [ -n "${2:-}" ] && printf '        %s\n' "$2" >&2; return 0; }
eq()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "got [$2] want [$3]"; fi; }
has() { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "missing [$3] in: $(printf '%s' "$2" | tail -c 600)" ;; esac; }
# mutant NAME yes|no [DETAIL] -- a dependency mutation the engine MUST notice; counts toward falsifiability
mutant() {
  MUTANTS=$((MUTANTS+1))
  if [ "$2" = yes ]; then KILLED=$((KILLED+1)); ok "mutant killed: $1"; else bad "mutant SURVIVED: $1" "${3:-}"; fi
}

for tool in git jq python3; do command -v "$tool" >/dev/null 2>&1 || { echo "FATAL: $tool required" >&2; exit 2; }; done
[ -x "$CLI" ] || { echo "FATAL: $CLI is missing or not executable" >&2; exit 2; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/hmd-closure.XXXXXX")"
[ -n "$WORK" ] || { echo "FATAL: mktemp failed" >&2; exit 2; }
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/home"
export HOME="$WORK/home"
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR HMD_SUITE_CACHE_MAX_DAYS HMD_SUITE_CACHE_AUDIT_PCT

echo "════════════════════════════════════════════════════════════════"
echo "suite closure: static dependency closure, closure hash, salt, verify-receipt"
echo "════════════════════════════════════════════════════════════════"

# ── A. the real repo, HEAD read from git objects (never the work tree) ───────────────────────────────────────────────
echo "── A. the CLI on the real repo"
if [ -e "$ROOT/.git" ]; then
  REAL_TSV="$WORK/real.tsv"
  "$CLI" hash-all --repo "$ROOT" --rev HEAD > "$REAL_TSV" 2>"$WORK/real.err"; rc=$?
  eq "A1 hash-all --rev HEAD exits 0 on the real repo" "$rc" 0
  want_n="$(git -C "$ROOT" ls-tree -r --name-only HEAD -- test | grep -c '^test/[^/]*\.test\.sh$')"
  eq "A2 one line per test/*.test.sh at HEAD ($want_n)" "$(wc -l < "$REAL_TSV" | tr -d ' ')" "$want_n"
  bad_lines="$(grep -cvE '^test/[^/]+\.test\.sh	[0-9a-f]{64}$' "$REAL_TSV" || true)"
  eq "A3 every line is  suite<TAB>64 hex" "$bad_lines" 0
  banner_deps="$("$CLI" deps --suite test/banner-version.test.sh --repo "$ROOT" --rev HEAD 2>/dev/null)"
  case "$(printf '%s\n' "$banner_deps" | grep -x 'bin/heimdall')" in bin/heimdall) ok "A4 bin/heimdall is in the closure of test/banner-version.test.sh" ;; *) bad "A4 bin/heimdall missing from the closure of test/banner-version.test.sh" ;; esac
  has "A5 the suite is in its own closure" "$banner_deps" "test/banner-version.test.sh"
  real_salt="$("$CLI" salt --repo "$ROOT" --rev HEAD 2>/dev/null)"
  if printf '%s' "$real_salt" | grep -qE '^[0-9a-f]{64}$'; then ok "A6 salt is a sha256"; else bad "A6 salt is a sha256" "got [$real_salt]"; fi
else
  echo "  SKIP A (not a git checkout: $ROOT/.git is absent)"
fi

# ── fixture: a git repo of REAL files, one suite per dependency kind ─────────────────────────────────────────────────
FIX="$WORK/fix"
mk() { # PATH LINE... -- write fixture file PATH (directories created), one LINE per argument
  local p="$1"; shift
  mkdir -p "$(dirname "$FIX/$p")"
  printf '%s\n' "$@" > "$FIX/$p"
}
suite() { # NAME LINE... -- a fixture suite that prints a result line the way real ones do
  local n="$1"; shift
  mk "test/$n.test.sh" '#!/usr/bin/env bash' "$@" 'echo "1 passed, 0 failed"'
}
gitf() { git -C "$FIX" "$@"; }
commit_all() { gitf add -A && gitf commit -q --no-verify -m "${1:-change}"; }

build_fixture() {
  mkdir -p "$FIX"
  gitf init -q
  gitf config user.email t@example.com; gitf config user.name T
  gitf config commit.gpgsign false; gitf config core.hooksPath /dev/null
  mk bin/dep.sh '#!/usr/bin/env bash' '. "$(dirname "$0")/dep-inner.sh"' 'echo dep v1'
  mk bin/dep-inner.sh '#!/usr/bin/env bash' 'echo inner v1'
  mk bin/tool-x '#!/usr/bin/env bash' 'echo tool-x v1'
  mk data/config.txt 'config v1'
  mk fixtures/dir/a.txt 'a v1'
  mk fixtures/dir/b.txt 'b v1'
  mk test/lib/helper.sh '#!/usr/bin/env bash' 'helper() { echo helper v1; }'
  mk bin/heimdall '#!/usr/bin/env bash' 'case "${1:-}" in' '  sub)' '    exec "$PLUGIN_DIR/bin/heimdall-sub" "$@"' '    ;;' \
    '  other)' '    exec "$PLUGIN_DIR/bin/heimdall-other" "$@"' '    ;;' '  *)' '    echo usage' '    ;;' 'esac'
  mk bin/heimdall-sub '#!/usr/bin/env bash' 'echo sub v1'
  mk bin/heimdall-other '#!/usr/bin/env bash' 'echo other v1'
  mk bin/hmd '#!/usr/bin/env bash' 'dir="$(cd "$(dirname "$0")" && pwd)"' 'exec "$dir/heimdall" "$@"'
  mk extra/hinted.txt 'hinted v1'
  mk unrelated/noise.txt 'noise v1'
  mk bin/mentions.sh '#!/usr/bin/env bash' '# calls bin/never-run-tool' 'echo hi'
  mk bin/never-run-tool '#!/usr/bin/env bash' 'echo never v1'
  mk bin/mentions-code.sh '#!/usr/bin/env bash' '"$(dirname "$0")/run-tool"'
  mk bin/run-tool '#!/usr/bin/env bash' 'echo run-tool v1'
  mk bin/commented-tool '#!/usr/bin/env bash' 'echo commented v1'
  mk test/run-all.sh '#!/usr/bin/env bash' 'live_reason() {' '  case "$(basename "$1")" in' '    *-deployed.test.sh)' '      echo "deployed" ;;' \
    '    *) echo "" ;;' '  esac' '}'
  mk test/closure-hints.json '{"test/k8-hint.test.sh":{"extra":["extra/hinted.txt"]},"test/k11-always.test.sh":{"always_run":true}}'
  suite k1-source 'REPO="$(cd "$(dirname "$0")/.." && pwd)"' '. "$REPO/bin/dep.sh"'
  suite k2-path 'out="$(tool-x)"'
  suite k3-data 'cat "$REPO/data/config.txt" >/dev/null'
  suite k4-dir 'ls "$REPO/fixtures/dir" >/dev/null'
  suite k5-lib 'HERE="$(cd "$(dirname "$0")" && pwd)"' '. "$HERE/lib/helper.sh"'
  suite k6-dispatch '"$REPO/bin/hmd" sub'
  suite k7-wild 'git ls-files | head -1 >/dev/null'
  suite k8-hint 'echo hinted'
  suite k9-comment '# exercises bin/commented-tool' 'echo ok'
  suite k10-nocomment '"$REPO/bin/mentions.sh"'
  suite k10b-code '"$REPO/bin/mentions-code.sh"'
  suite k11-always 'echo always'
  suite x-deployed 'echo live'
  local i=1 n
  while [ "$i" -le 30 ]; do n="$(printf 'p%02d' "$i")"; suite "$n" 'echo plain'; i=$((i+1)); done
  commit_all base >/dev/null 2>&1
}
build_fixture
BASE="$(gitf rev-parse HEAD)"
SUITES_N="$(find "$FIX/test" -maxdepth 1 -name '*.test.sh' | wc -l | tr -d ' ')"

BASE_TSV="$WORK/base.tsv"; MUT_TSV="$WORK/mut.tsv"
hashes() { "$CLI" hash-all --repo "$FIX" 2>"$WORK/hashes.err"; }
hashes > "$BASE_TSV"
[ -s "$BASE_TSV" ] || { echo "FATAL: hash-all produced nothing on the fixture: $(cat "$WORK/hashes.err")" >&2; exit 1; }
pick() { awk -F'\t' -v s="test/$2.test.sh" '$1 == s {print $2}' "$1"; }

# ── B. the fixture's CLI contract ────────────────────────────────────────────────────────────────────────────────────
echo "── B. CLI contract on the fixture"
eq "B1 hash-all prints one line per suite ($SUITES_N)" "$(wc -l < "$BASE_TSV" | tr -d ' ')" "$SUITES_N"
hashes > "$WORK/again.tsv"
eq "B2 hash-all is deterministic" "$(cat "$BASE_TSV")" "$(cat "$WORK/again.tsv")"
eq "B3 hash --suite test/x == its hash-all line" "$("$CLI" hash --suite test/k1-source.test.sh --repo "$FIX")" "$(pick "$BASE_TSV" k1-source)"
eq "B4 hash --suite accepts the bare file name" "$("$CLI" hash --suite k1-source.test.sh --repo "$FIX")" "$(pick "$BASE_TSV" k1-source)"
eq "B5 deps k1 = the suite, bin/dep.sh and what it sources (sorted)" "$("$CLI" deps --suite test/k1-source.test.sh --repo "$FIX")" \
  "$(printf '%s\n' bin/dep-inner.sh bin/dep.sh test/k1-source.test.sh)"
eq "B6 deps k6 follows ONLY the invoked dispatcher arm" "$("$CLI" deps --suite test/k6-dispatch.test.sh --repo "$FIX")" \
  "$(printf '%s\n' bin/heimdall bin/heimdall-sub bin/hmd test/k6-dispatch.test.sh)"
eq "B7 deps k4 pulls every file under the directory token" "$("$CLI" deps --suite test/k4-dir.test.sh --repo "$FIX")" \
  "$(printf '%s\n' fixtures/dir/a.txt fixtures/dir/b.txt test/k4-dir.test.sh)"
eq "B8 deps k10 ignores a tool only an executable's COMMENT names" "$("$CLI" deps --suite test/k10-nocomment.test.sh --repo "$FIX")" \
  "$(printf '%s\n' bin/mentions.sh test/k10-nocomment.test.sh)"
eq "B9 deps k9 counts the header COMMENT of a suite" "$("$CLI" deps --suite test/k9-comment.test.sh --repo "$FIX")" \
  "$(printf '%s\n' bin/commented-tool test/k9-comment.test.sh)"
eq "B10 deps k7 (git ls-files) is every tracked file" "$("$CLI" deps --suite test/k7-wild.test.sh --repo "$FIX" | wc -l | tr -d ' ')" "$(gitf ls-files | wc -l | tr -d ' ')"
has "B11 deps k8 holds the hinted file" "$("$CLI" deps --suite test/k8-hint.test.sh --repo "$FIX")" "extra/hinted.txt"
printf '{}\n' > "$WORK/empty-hints.json"
case "$("$CLI" deps --suite test/k8-hint.test.sh --repo "$FIX" --hints "$WORK/empty-hints.json")" in
  *extra/hinted.txt*) bad "B12 --hints replaces the hints file (the hinted file is still there)" ;;
  *) ok "B12 --hints replaces the hints file (no hinted file without the hint)" ;;
esac
# a dirty tree is refused: a cache key must describe HEAD, and the suite would run against the work tree
printf 'x' >> "$FIX/bin/dep.sh"
"$CLI" hash-all --repo "$FIX" >"$WORK/d.out" 2>"$WORK/d.err"; rc=$?
if [ "$rc" -ne 0 ] && grep -qi 'uncommitted' "$WORK/d.err"; then ok "B13 hash-all refuses a tree with an uncommitted edit (exit $rc)"; else bad "B13 hash-all refuses a dirty tree" "rc=$rc $(cat "$WORK/d.err")"; fi
"$CLI" hash --suite test/k1-source.test.sh --repo "$FIX" >/dev/null 2>&1; rc=$?
if [ "$rc" -ne 0 ]; then ok "B14 hash refuses it too"; else bad "B14 hash refuses a dirty tree"; fi
eq "B15 --rev HEAD reads git objects only: the dirty tree changes nothing" "$("$CLI" hash-all --repo "$FIX" --rev HEAD)" "$(cat "$BASE_TSV")"
gitf checkout -q -- bin/dep.sh
"$CLI" hash-all --repo "$FIX" >/dev/null 2>&1; eq "B16 clean again: hash-all exits 0" "$?" 0
"$CLI" bogus >/dev/null 2>&1; eq "B17 an unknown sub-command exits 2" "$?" 2
"$CLI" hash --repo "$FIX" >/dev/null 2>&1; eq "B18 hash without --suite exits 2" "$?" 2
"$CLI" hash --suite test/no-such.test.sh --repo "$FIX" >/dev/null 2>&1; eq "B19 a suite that does not exist exits 2" "$?" 2
"$CLI" hash-all --repo "$WORK" >/dev/null 2>&1; eq "B20 a directory that is not a git repository exits 2" "$?" 2
has "B21 --help names every sub-command" "$("$CLI" --help 2>&1)" "verify-receipt"

# ── C. mutation proof ────────────────────────────────────────────────────────────────────────────────────────────────
echo "── C. mutation proof: each dependency edited -> the closure hash changes; unrelated edits -> nothing changes"
mutate() { # FILE byte|comment|ws -- one byte appended, a comment-only line appended (hash is content, not semantics), or one newline (JSON stays valid)
  case "$2" in byte) printf 'x' >> "$FIX/$1" ;; comment) printf '# note\n' >> "$FIX/$1" ;; ws) printf '\n' >> "$FIX/$1" ;; esac
}
PROBE_OK=1
probe() { # FILE HOW -- commit the edit, hash every suite, put the repo back on the base commit
  mutate "$1" "$2"; commit_all "mutate $1 ($2)" >/dev/null 2>&1
  hashes > "$MUT_TSV"
  gitf reset -q --hard "$BASE"
  PROBE_OK=1
  if [ "$(wc -l < "$MUT_TSV" | tr -d ' ')" != "$SUITES_N" ]; then PROBE_OK=0; bad "probe $1 ($2): hash-all failed on the mutated commit" "$(cat "$WORK/hashes.err")"; fi
}
changed_set() { # the suites whose closure hash differs between base and mutated, sorted, space separated
  join -t "$(printf '\t')" <(sort "$BASE_TSV") <(sort "$MUT_TSV") \
    | awk -F'\t' '$2 != $3 {n = $1; sub(/^test\//, "", n); sub(/\.test\.sh$/, "", n); print n}' | sort | tr '\n' ' ' | sed 's/ $//'
}
# k11-always and k7-wild are the two suites whose closure is the whole tree: ANY edit changes them
expected() { printf '%s\n' "$@" k11-always k7-wild | sort -u | tr '\n' ' ' | sed 's/ $//'; }
# kill LABEL FILE HOW TARGET [ALSO...] -- edit FILE; TARGET's hash must change (a killed mutant), and exactly the expected set changes
kill() {
  local label="$1" file="$2" how="$3" target="$4"; shift 4
  probe "$file" "$how"
  [ "$PROBE_OK" = 1 ] || { mutant "$label" no "no hashes"; return; }
  local got want; got="$(changed_set)"; want="$(expected "$target" "$@")"
  case " $got " in *" $target "*) mutant "$label" yes ;; *) mutant "$label" no "$target did not change; changed: [$got]" ;; esac
  eq "   precision: only [$want] may change" "$got" "$want"
}
# same LABEL FILE HOW -- an edit that must change nothing but the whole-tree suites
same() {
  probe "$2" "$3"
  [ "$PROBE_OK" = 1 ] || return 0
  eq "$1" "$(changed_set)" "$(expected)"
}
kill "1 source: one byte of the sourced library bin/dep.sh" bin/dep.sh byte k1-source
kill "1 source: comment-only edit of bin/dep.sh" bin/dep.sh comment k1-source
kill "1 source: transitive, bin/dep.sh sources bin/dep-inner.sh" bin/dep-inner.sh byte k1-source
kill "2 PATH basename: one byte of bin/tool-x" bin/tool-x byte k2-path
kill "2 PATH basename: comment-only edit of bin/tool-x" bin/tool-x comment k2-path
kill "3 data file: one byte of data/config.txt" data/config.txt byte k3-data
kill "4 directory token: one byte of fixtures/dir/b.txt" fixtures/dir/b.txt byte k4-dir
kill "5 test/lib helper: one byte of test/lib/helper.sh" test/lib/helper.sh byte k5-lib
kill "5 test/lib helper: comment-only edit of test/lib/helper.sh" test/lib/helper.sh comment k5-lib
kill "6 dispatcher sub-command: one byte of bin/heimdall-sub" bin/heimdall-sub byte k6-dispatch
kill "6 dispatcher: one byte of bin/heimdall itself" bin/heimdall byte k6-dispatch
kill "7 wildcard (git ls-files): one byte of an unrelated file" unrelated/noise.txt byte k7-wild
kill "8 hints extra: one byte of the hinted extra/hinted.txt" extra/hinted.txt byte k8-hint
kill "9 suite comment: one byte of bin/commented-tool named only in the suite's header" bin/commented-tool byte k9-comment
kill "10 executable code mention: one byte of bin/mentions.sh" bin/mentions.sh byte k10-nocomment
kill "10 transitive: bin/mentions-code.sh runs bin/run-tool" bin/run-tool byte k10b-code
kill "11 hints always_run: one byte of an unrelated file" unrelated/noise.txt byte k11-always
same "C-p1 an unrelated edit changes only the whole-tree suites" unrelated/noise.txt byte
same "C-p2 an arm of the dispatcher nobody invoked (bin/heimdall-other) changes no suite that did not invoke it" bin/heimdall-other byte
same "C-p3 a tool only an executable's COMMENT names (bin/never-run-tool) adds no edge" bin/never-run-tool byte

# ── D. hints are validated, never silently ignored ───────────────────────────────────────────────────────────────────
echo "── D. hints validation"
hint_refused() { # LABEL JSON REASON
  printf '%s\n' "$2" > "$WORK/hints.json"
  "$CLI" hash-all --repo "$FIX" --hints "$WORK/hints.json" >"$WORK/h.out" 2>"$WORK/h.err"; local rc=$?
  if [ "$rc" -eq 2 ] && grep -qiF -- "$3" "$WORK/h.err"; then ok "$1"; else bad "$1" "rc=$rc stderr=$(cat "$WORK/h.err")"; fi
}
hint_refused "D1 an extra path that names nothing is refused" '{"test/k8-hint.test.sh":{"extra":["no/such/path"]}}' "no/such/path"
hint_refused "D2 an unknown key is refused" '{"test/k8-hint.test.sh":{"extras":["extra/hinted.txt"]}}' "extras"
hint_refused "D3 always_run must be a boolean" '{"test/k8-hint.test.sh":{"always_run":"yes"}}' "always_run"
hint_refused "D4 the file must be a JSON object" '[1,2]' "object"
hint_refused "D5 invalid JSON is refused" '{not json' "hints"
printf '%s\n' '{"test/gone.test.sh":{"always_run":true}}' > "$WORK/hints.json"
"$CLI" hash-all --repo "$FIX" --hints "$WORK/hints.json" >/dev/null 2>"$WORK/h.err"; rc=$?
if [ "$rc" -eq 0 ] && grep -qF 'gone.test.sh' "$WORK/h.err"; then ok "D6 a hint for a suite that no longer exists warns on stderr and is ignored"; else bad "D6 hint for a removed suite" "rc=$rc $(cat "$WORK/h.err")"; fi

# ── E. the salt ──────────────────────────────────────────────────────────────────────────────────────────────────────
echo "── E. salt"
SALT0="$("$CLI" salt --repo "$FIX")"
if printf '%s' "$SALT0" | grep -qE '^[0-9a-f]{64}$'; then ok "E1 salt is a sha256"; else bad "E1 salt is a sha256" "got [$SALT0]"; fi
eq "E2 salt is stable" "$("$CLI" salt --repo "$FIX")" "$SALT0"
salt_after() { # FILE HOW -- the salt of a commit that edits FILE
  mutate "$1" "$2"; commit_all "salt probe" >/dev/null 2>&1
  SALT_NOW="$("$CLI" salt --repo "$FIX")"; gitf reset -q --hard "$BASE"
}
salt_kill() { # LABEL FILE HOW
  salt_after "$2" "$3"
  if [ -n "$SALT_NOW" ] && [ "$SALT_NOW" != "$SALT0" ]; then mutant "$1" yes; else mutant "$1" no "salt did not move ($SALT_NOW)"; fi
}
salt_kill "E3 salt moves with test/run-all.sh" test/run-all.sh byte
salt_kill "E4 salt moves with a test/lib file" test/lib/helper.sh byte
salt_kill "E5 salt moves with the hints file (a JSON-valid whitespace edit)" test/closure-hints.json ws
salt_after unrelated/noise.txt byte
eq "E6 salt does not move with an unrelated file" "$SALT_NOW" "$SALT0"
mk bin/lib/suite-cache.sh '#!/usr/bin/env bash' 'suite_cache_lookup() { :; }'
commit_all "add suite-cache.sh" >/dev/null 2>&1
SALT_NOW="$("$CLI" salt --repo "$FIX")"
if [ "$SALT_NOW" != "$SALT0" ]; then mutant "E7 salt moves when bin/lib/suite-cache.sh appears" yes; else mutant "E7 salt moves when bin/lib/suite-cache.sh appears" no; fi
gitf reset -q --hard "$BASE"

# ── F. verify-receipt ────────────────────────────────────────────────────────────────────────────────────────────────
echo "── F. verify-receipt"
iso_now() { date -u '+%Y-%m-%dT%H:%M:%SZ'; }
days_ago() { date -u -v-"$1"d '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date -u -d "$1 days ago" '+%Y-%m-%dT%H:%M:%SZ'; }
ZEROS="0000000000000000000000000000000000000000000000000000000000000000"
mkreceipt() { # OUT HEAD COLD CACHED AUDITED -- a receipt whose entries are every non-live suite at HEAD (x-deployed is live)
  local out="$1" head="$2" cold="$3" cached="$4" audited="$5" now salt
  now="$(iso_now)"; salt="$("$CLI" salt --repo "$FIX" --rev "$head")" || return 1
  "$CLI" hash-all --repo "$FIX" --rev "$head" | grep -v 'deployed' \
    | jq -R -s --arg head "$head" --arg salt "$salt" --arg now "$now" --argjson cold "$cold" --argjson cached "$cached" --argjson audited "$audited" '
        (split("\n") | map(select(length > 0) | split("\t"))) as $rows
        | {finished_at: $now, head_sha: $head, tree_clean: true, exit_code: 0, kind: "full",
           cache: {mode: "closure", salt: $salt, suites_fresh: (($rows | length) - $cached), suites_cached: $cached, audited: $audited,
                   cold: $cold, oldest_entry_age_days: 0, entries: ($rows | map({suite: .[0], closure_sha: .[1], finished_at: $now}))}}' > "$out"
}
vr() { # RECEIPT -> VR_RC, VR_ERR
  "$CLI" verify-receipt --repo "$FIX" --receipt "$1" >"$WORK/vr.out" 2>"$WORK/vr.err"; VR_RC=$?; VR_ERR="$(cat "$WORK/vr.err")"
}
COLD="$WORK/cold.json"; GOOD="$WORK/good.json"
mkreceipt "$COLD" "$BASE" true 0 0 || bad "F0 could not build the cold receipt"
mkreceipt "$GOOD" "$BASE" false 22 20 || bad "F0 could not build the cache-composed receipt"
vr "$COLD"; eq "F1 a cold receipt (every suite fresh, the live suite absent) passes" "$VR_RC" 0
[ "$VR_RC" = 0 ] || printf '        %s\n' "$VR_ERR" >&2
vr "$GOOD"; eq "F2 a cache-composed receipt (22 cached, 20 audited of 42 hits) passes" "$VR_RC" 0
[ "$VR_RC" = 0 ] || printf '        %s\n' "$VR_ERR" >&2
rjq() { jq "$1" "$2" > "$WORK/r.mut.json"; }
rmut() { # LABEL FILTER REASON [BASE_RECEIPT] -- the receipt, mutated by one jq filter, MUST be refused (exit 1) and say why
  rjq "$2" "${4:-$GOOD}"; vr "$WORK/r.mut.json"
  if [ "$VR_RC" = 1 ] && printf '%s' "$VR_ERR" | grep -qiF -- "$3"; then mutant "receipt: $1" yes
  else mutant "receipt: $1" no "rc=$VR_RC want reason [$3], stderr=[$VR_ERR]"; fi
}
rpass() { # LABEL FILTER [BASE_RECEIPT] -- the mutated receipt is still fine (precision)
  rjq "$2" "${3:-$GOOD}"; vr "$WORK/r.mut.json"
  if [ "$VR_RC" = 0 ]; then ok "$1"; else bad "$1" "rc=$VR_RC stderr=[$VR_ERR]"; fi
}
OLD="$(days_ago 8)"; RECENT="$(days_ago 6)"
rmut "one entry's closure_sha is wrong (the closure changed since it was recorded)" ".cache.entries[2].closure_sha = \"$ZEROS\"" "closure"
rmut "an entry is 8 days old (limit 7)" ".cache.entries[3].finished_at = \"$OLD\"" "days old"
rmut "the salt differs (test infrastructure, hints, engine or toolchain changed)" ".cache.salt = \"$ZEROS\"" "salt"
rmut "audited (5) is under max(20, 10%) of the 42 hits" ".cache.audited = 5" "audited"
rmut "a non-live suite has no entry" ".cache.entries |= .[1:]" "no green entry"
rmut "an entry names a suite that does not exist at the graded commit" ".cache.entries += [{suite: \"test/ghost.test.sh\", closure_sha: \"$ZEROS\", finished_at: \"$(iso_now)\"}]" "ghost"
rmut "an entry is listed twice" ".cache.entries += [.cache.entries[0]]" "twice"
rmut "exit_code is not 0" ".exit_code = 1" "exit_code"
rmut "kind is not full" ".kind = \"incremental\"" "kind"
rmut "cache.mode is not closure" ".cache.mode = \"other\"" "mode"
rmut "cache.cold is true yet suites were served from the cache" ".cache.cold = true" "cold"
rmut "the receipt itself says full_equivalent is false" ".full_equivalent = false" "full_equivalent"
rmut "the cache block is missing" "del(.cache)" "cache"
rmut "an entry's closure_sha is not a sha256" ".cache.entries[0].closure_sha = \"nothex\"" "closure_sha"
rmut "head_sha names no commit" ".head_sha = \"$(printf 'f%.0s' $(seq 1 40))\"" "head_sha"
mutate bin/dep.sh byte; commit_all "dep edit" >/dev/null 2>&1; C1="$(gitf rev-parse HEAD)"; gitf reset -q --hard "$BASE"
rmut "head_sha moved to a commit where a dependency of k1-source changed" ".head_sha = \"$C1\"" "closure"
rpass "F-p1 an entry 6 days old is still inside the limit" ".cache.entries[4].finished_at = \"$RECENT\""
rpass "F-p2 entries named by bare file name verify too" ".cache.entries |= map(.suite |= sub(\"^test/\"; \"\"))"
rpass "F-p3 a cold receipt is not aged out (every suite ran in that sweep)" ".cache.entries |= map(.finished_at = \"$OLD\")" "$COLD"
mutate unrelated/noise.txt byte; commit_all "later commit" >/dev/null 2>&1
vr "$GOOD"; eq "F-p4 the receipt is graded at ITS commit, not at whatever HEAD is now" "$VR_RC" 0
gitf reset -q --hard "$BASE"
# a gate may only TIGHTEN the age limit and RAISE the audit share
rjq ".cache.entries[4].finished_at = \"$RECENT\"" "$GOOD"
HMD_SUITE_CACHE_MAX_DAYS=5 "$CLI" verify-receipt --repo "$FIX" --receipt "$WORK/r.mut.json" >/dev/null 2>"$WORK/vr.err"; rc=$?
if [ "$rc" -eq 1 ] && grep -qi 'days old' "$WORK/vr.err"; then mutant "HMD_SUITE_CACHE_MAX_DAYS=5 tightens the limit: a 6-day entry is refused" yes; else mutant "HMD_SUITE_CACHE_MAX_DAYS=5 tightens the limit" no "rc=$rc $(cat "$WORK/vr.err")"; fi
rjq ".cache.entries[3].finished_at = \"$OLD\"" "$GOOD"
HMD_SUITE_CACHE_MAX_DAYS=30 "$CLI" verify-receipt --repo "$FIX" --receipt "$WORK/r.mut.json" >/dev/null 2>"$WORK/vr.err"; rc=$?
if [ "$rc" -eq 1 ]; then mutant "HMD_SUITE_CACHE_MAX_DAYS=30 cannot loosen the limit: an 8-day entry is still refused" yes; else mutant "HMD_SUITE_CACHE_MAX_DAYS=30 cannot loosen the limit" no "rc=$rc"; fi
HMD_SUITE_CACHE_AUDIT_PCT=100 "$CLI" verify-receipt --repo "$FIX" --receipt "$GOOD" >/dev/null 2>"$WORK/vr.err"; rc=$?
if [ "$rc" -eq 1 ] && grep -qi 'audited' "$WORK/vr.err"; then mutant "HMD_SUITE_CACHE_AUDIT_PCT=100 raises the share: 20 of 42 is under-audited" yes; else mutant "HMD_SUITE_CACHE_AUDIT_PCT=100 raises the share" no "rc=$rc $(cat "$WORK/vr.err")"; fi
HMD_SUITE_CACHE_AUDIT_PCT=1 "$CLI" verify-receipt --repo "$FIX" --receipt "$GOOD" >/dev/null 2>&1; eq "F-p5 HMD_SUITE_CACHE_AUDIT_PCT=1 cannot lower the share (the receipt still passes at the floor)" "$?" 0
printf '{"not":"a receipt"' > "$WORK/broken.json"
"$CLI" verify-receipt --repo "$FIX" --receipt "$WORK/broken.json" >/dev/null 2>&1; eq "F-p6 an unreadable receipt is refused (exit 1)" "$?" 1
"$CLI" verify-receipt --repo "$FIX" --receipt "$WORK/no-such-receipt.json" >/dev/null 2>&1; eq "F-p7 a missing receipt is refused (exit 1)" "$?" 1

# ── falsifiability ───────────────────────────────────────────────────────────────────────────────────────────────────
echo "════════════════════════════════════════════════════════════════"
echo "falsifiability: ${KILLED}/${MUTANTS}"
echo "${PASS} passed, ${FAIL} failed"
if [ "$KILLED" -ne "$MUTANTS" ] || [ "$MUTANTS" -eq 0 ]; then echo "FAIL: falsifiability score is not 1.0" >&2; exit 1; fi
[ "$FAIL" -eq 0 ] || exit 1
exit 0
