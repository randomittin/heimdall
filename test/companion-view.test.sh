#!/usr/bin/env bash
# test/companion-view.test.sh -- the phone's Files, agent and checkpoint rows open a diff, a transcript, a pull request: hmd
# answers `view-v1`.
#
# The phone half is hmdapp's src/views (docs/HANDOFF-TO-HEIMDALL-cursor-parity.md CP5). The wire under test, through the REAL
# bin/heimdall-relay-client against test/lib/fake-relay.py (a hermetic stand-in for the relay; test/lib/view_phone.py plays
# the paired phone and seals with the real bin/lib/hmd_relay_e2e.py -- nothing about the client is mocked, and no case imports
# the client or bin/lib/companion_view.py):
#     cap      view-v1 in every state frame's caps
#     command  {"action":"view","params":{"rid","kind":"diff","scope","path","ctx","max_bytes"}}
#              {"action":"view","params":{"rid","kind":"transcript","agent_id"?,"tail"?}}
#              {"action":"view","params":{"rid","kind":"pr"}}
#     ack      {"ok":true,"of_seq":N,"id":rid} | {"ok":false,"of_seq":N,"detail":<code>[,"retry_after_s":N]}
#     answer   state.views = {"v":1,"enabled","kinds":["diff","transcript","pr"],"result":{id,kind,at,...the kind's fields}}
#
# What it proves (the cases live in test/lib/view_scenarios.py, one group per concern):
#   wire     the cap, the slice's shape, no slice for a phone that has not listed the cap, caps-missing, the result forgotten
#   diff     files[] and the hunk text equal what git itself prints for the same tree (computed here by running git again);
#            worktree / staged / head, ctx, a rename, a deletion, a binary file, an untracked file shown whole, not-found
#   paths    traversal and absolute paths, the deny list, every kind of symlink, a named pipe: refused, nothing leaks
#   secrets  a token, an assigned credential and a PEM key masked line by line, hunk-header context, secret-shaped names,
#            the relay's redaction profile on the result, the 2000-character line cut
#   params   the exact key set of each kind, every wrong type and range, and the contract's fourth kind, reel (not-implemented)
#   size     max_bytes at a hunk boundary, a first hunk kept in part, the slice budget, the 1 MiB envelope, zlib, the 2000-file cap
#   transcript  the repo's own session written into the client's HOME: the turns exactly (prompt and assistant text with their line breaks
#            kept, one line per tool call; no thinking, sidechain, caveat or noise), the 400-character cut the phone makes too, tail, the
#            newest-first slice budget (and the sealed frame it bounds, plain and zlib), the 4 MiB read window, a secret masked whole
#            even when the cut would have half shown it, no output line for a call that named .env, a symlinked session or agent file
#            never followed, agent_id (sidechain file, metadata role, an older session's agent, unknown, hostile ids)
#   pr       a fake gh first on the client's PATH: its argv is exactly `pr view --json <fields>`, a GH_TOKEN reaches it only by environment
#            (GH_REPO never does), the document read field for field, the gate joined to the sweep receipt (clean and all-green for THIS
#            head only), secrets and emails scrubbed, a url only when github.com/<owner>/<repo>/pull/<this number>, every shape the
#            contract cannot carry, a failing gh, too-large, and the 8 s timeout; gh missing from the PATH (its own stack)
#   latch    a forged or replayed command is never run; the same device binding again, or another device's refused bind, keeps the
#            phone's caps and the held result (a frame that binds no one strips nothing)
#   kill     .heimdall/app/controls-disabled and HMD_UI_CONTROLS=0 -> controls-off, enabled:false
#   rate     --repo below the git toplevel; the 21st request in a minute is rate-limited
# and, falsifiably, that each rule is the thing holding: a copy of the client with one rule removed must turn its group red.
#
# Hermetic: HOME/HEIMDALL_HOME/TMPDIR are temp dirs, every process this suite starts is reaped on exit, every wait is bounded.
# It signals no process it did not start (a running relay client of the operator's is never touched).
#
# Every scenario process -- the four stacks (the main one in four parts) and each mutant -- shares nothing with another, so they run in
# one pool, POOL_JOBS at a time (see "the pool" below), and are reported afterwards in the order they are declared.

set -u

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLIENT="$REPO/bin/heimdall-relay-client"
SCEN="$REPO/test/lib/view_scenarios.py"
MODULE="$REPO/bin/lib/companion_view.py"

PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; }

echo "companion-view (the phone's diff, transcript and pull request: view-v1 through the real relay client)"

for f in "$CLIENT" "$SCEN" "$MODULE" "$REPO/test/lib/view_phone.py" "$REPO/test/lib/fake-relay.py"; do
  if [ ! -e "$f" ]; then
    printf 'FATAL: required file missing: %s\n' "$f" >&2
    printf '\n0 passed, 1 failed\n'
    exit 1
  fi
done
for tool in python3 git; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    printf 'FATAL: required tool missing: %s\n' "$tool" >&2
    printf '\n0 passed, 1 failed\n'
    exit 1
  fi
done

TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT

# A copy of the client that differs from the real one in nothing but what a mutant changes: the client file itself is a real
# copy (it finds bin/lib beside its own real path), bin/lib is a directory of links except companion_view.py (also a copy),
# and everything else -- sentinels, the other bin scripts, the codec -- is linked to the real one. One ln for each directory, then the two
# names that must not be links come out again: bin/ and bin/lib hold some 440 files, and a fork for each of them (and another for its
# basename) was seconds of every mutant on a loaded machine.
mutant_tree() {
  local dir="$TMPROOT/mutant-$1"
  mkdir -p "$dir/bin"
  ln -s "$REPO"/bin/* "$dir/bin/"
  rm "$dir/bin/lib" "$dir/bin/heimdall-relay-client"
  mkdir "$dir/bin/lib"
  ln -s "$REPO"/bin/lib/* "$dir/bin/lib/"
  rm "$dir/bin/lib/companion_view.py"
  cp "$CLIENT" "$dir/bin/heimdall-relay-client"
  cp "$MODULE" "$dir/bin/lib/companion_view.py"
  ln -s "$REPO/sentinels" "$dir/sentinels"
  printf '%s' "$dir"
}

# mutate FILE OLD NEW -- exactly one occurrence of OLD, else the mutant would be vacuous and the suite says so.
mutate() {
  python3 - "$1" "$2" "$3" <<'PYEOF'
import sys
path, old, new = sys.argv[1:4]
src = open(path, encoding="utf-8").read()
if src.count(old) != 1:
    sys.exit("mutation site found %d times, not once: %r" % (src.count(old), old))
open(path, "w", encoding="utf-8").write(src.replace(old, new))
PYEOF
}

# -- the pool ------------------------------------------------------------------------------------------------------------------
# Every scenario process of this suite is independent of every other: its own temp dir and repo, its own fake relay and relay client
# on ports the OS hands out. One after another they were ~250 s on a loaded machine, nearly all of it waiting -- on sockets, and on the
# cases' own bounded waits (a gh that never answers for 8 s, windows of 2 and 4 s in which nothing may happen). So `scenario` and
# `mutant` only queue a job; run_pool starts POOL_JOBS workers, each of which takes the next job nobody has taken (its mkdir claim is
# the atomic step: a job never runs twice, nothing polls, and a slow job never keeps a free slot waiting) and runs it; and report_jobs
# prints everything afterwards, in the order the jobs were queued. A worker is a subshell and cannot add to PASS/FAIL, so a job leaves
# what it found in $TMPROOT: job.N.out and job.N.rc for a stack, job.N.verdict for a mutant (ok|bad, then the message ok/bad prints).
# A job that left nothing -- its worker died first -- is reported as a failure, never as silence.
POOL_JOBS=8
JOB_KIND=()    # section | stack | mutant | cover: what the entry is
JOB_NAME=()    # a section's text, a stack's label, a mutant's name
JOB_STACK=()   # a stack: main | nogh | subdir | killenv
JOB_GROUPS=()  # a stack: the groups of the main stack it runs; a mutant: the groups that must go red
JOB_FILE=()    # a mutant: the file of its tree that changes
JOB_OLD=()     # a mutant: the text it takes out
JOB_NEW=()     # a mutant: the text it puts there
JOB_SLOW=()    # 1: starts before the 0s, so the short jobs fill the end of the run; -: nothing to run
MAIN_RUN=""    # the groups of the main stack that the queued processes run, comma-separated

# job KIND NAME STACK GROUPS FILE OLD NEW SLOW -- queue one entry; the report follows the order they were queued in.
job() {
  JOB_KIND+=("$1")
  JOB_NAME+=("$2")
  JOB_STACK+=("$3")
  JOB_GROUPS+=("$4")
  JOB_FILE+=("$5")
  JOB_OLD+=("$6")
  JOB_NEW+=("$7")
  JOB_SLOW+=("$8")
}

# section TEXT -- a heading line of the report.
section() { job section "$1" "" "" "" "" "" -; }

# scenario LABEL STACK [GROUPS] -- one process of the stack STACK (main, nogh, subdir or killenv); only main takes GROUPS, a comma list.
# The main stack's processes are the longest of the suite, so they start first.
scenario() {
  local slow=0
  if [ "$2" = main ]; then
    slow=1
    MAIN_RUN="$MAIN_RUN,${3:-}"
  fi
  job stack "$1" "$2" "${3:-}" "" "" "" "$slow"
}

# cover -- a check, made when the report reaches it, that the groups the queued main-stack processes run are exactly the ones
# view_scenarios.py lists: the groups are named here now, so one added there and to no list here would silently never run.
cover() { job cover "main stack groups" "" "" "" "" "" -; }

# mutant NAME FILE-IN-TREE OLD NEW GROUPS -- the suite's own cases for GROUPS must go red on the changed copy. A mutant whose GROUPS hold
# the slow cases (the 8 s gh, 500 long turns, 2100 files) starts early.
mutant() {
  local slow=0
  case ",$5," in *,transcript,*|*,pr,*|*,size,*) slow=1 ;; esac
  job mutant "$1" "" "$5" "$2" "$3" "$4" "$slow"
}

run_mutant() {
  local name="${JOB_NAME[$1]}" rel="${JOB_FILE[$1]}" old="${JOB_OLD[$1]}" new="${JOB_NEW[$1]}" groups="${JOB_GROUPS[$1]}"
  local dir out rc verdict="$TMPROOT/job.$1.verdict"
  dir="$(mutant_tree "$name")"
  if ! mutate "$dir/$rel" "$old" "$new" 2>"$TMPROOT/mut.$name.err"; then
    printf 'bad\nmutant %s could not be built: %s\n' "$name" "$(cat "$TMPROOT/mut.$name.err")" >"$verdict"
    return
  fi
  out="$TMPROOT/mut.$name.out"
  python3 "$SCEN" main --client "$dir/bin/heimdall-relay-client" --groups "$groups" >"$out" 2>&1
  rc=$?
  if [ "$rc" -ne 0 ] && grep -q '^  FAIL ' "$out"; then
    printf 'ok\nmutant %s turns the suite red (%s checks failed: %s)\n' "$name" "$(grep -c '^  FAIL ' "$out")" "$(grep -m1 '^  FAIL ' "$out" | cut -c8-90)" >"$verdict"
  else
    printf 'bad\nmutant %s NOT caught (exit %s) -- the rule it removes is not what the cases test\n' "$name" "$rc" >"$verdict"
  fi
}

run_stack() {
  local n="$1"
  local args=("${JOB_STACK[$n]}" --client "$CLIENT")
  [ -n "${JOB_GROUPS[$n]}" ] && args+=(--groups "${JOB_GROUPS[$n]}")
  python3 "$SCEN" "${args[@]}" >"$TMPROOT/job.$n.out" 2>&1
  echo $? >"$TMPROOT/job.$n.rc"
}

# worker -- one slot of the pool: the slow jobs first, then the rest, each in the order they were queued ("run_$kind" is run_stack
# or run_mutant; a section or a cover has no slot to run in).
worker() {
  local pass n
  for pass in 1 0; do
    for ((n = 0; n < ${#JOB_KIND[@]}; n++)); do
      [ "${JOB_SLOW[$n]}" = "$pass" ] || continue
      mkdir "$TMPROOT/claim.$n" 2>/dev/null || continue
      "run_${JOB_KIND[$n]}" "$n"
    done
  done
}

run_pool() {
  local w
  for ((w = 0; w < POOL_JOBS; w++)); do
    worker &
  done
  wait
}

report_section() { echo "${JOB_NAME[$1]}"; }

# report_stack N -- print the stack's own lines and fold its tally into ours; no tally is a failure.
report_stack() {
  local n="$1" label="${JOB_NAME[$1]}" out="$TMPROOT/job.$1.out" rc tally p f
  rc="$(cat "$TMPROOT/job.$n.rc" 2>/dev/null)"
  cat "$out" 2>/dev/null
  tally="$(grep -E '^[0-9]+ passed, [0-9]+ failed$' "$out" 2>/dev/null | tail -1)"
  if [ -z "$tally" ]; then
    bad "$label: the scenario run produced no tally (exit ${rc:-unknown, its job died})"
    tail -20 "$out" 2>/dev/null
    return
  fi
  p="${tally%% passed*}"
  f="${tally##*, }"
  f="${f%% failed}"
  PASS=$((PASS + p))
  FAIL=$((FAIL + f))
}

report_mutant() {
  local n="$1" kind message
  if [ ! -s "$TMPROOT/job.$n.verdict" ]; then
    bad "mutant ${JOB_NAME[$n]} left no verdict (its job died before it could write one)"
    return
  fi
  { IFS= read -r kind; IFS= read -r message; } <"$TMPROOT/job.$n.verdict"
  if [ "$kind" = ok ]; then ok "$message"; else bad "$message"; fi
}

report_cover() {
  local want got
  want="$(python3 -B -c 'import sys; sys.path.insert(0, sys.argv[1]); import view_scenarios; print("\n".join(view_scenarios.MAIN_GROUPS))' "$REPO/test/lib" 2>&1 | sort | tr '\n' ' ')"
  got="$(printf '%s' "$MAIN_RUN" | tr ',' '\n' | grep . | sort | tr '\n' ' ')"
  if [ -n "$want" ] && [ "$want" = "$got" ]; then
    ok "the main stack's groups are each run by exactly one process (${got% })"
  else
    bad "the groups the main-stack processes run (${got% }) are not the groups view_scenarios.py lists (${want% })"
  fi
}

report_jobs() {
  local n
  for ((n = 0; n < ${#JOB_KIND[@]}; n++)); do
    "report_${JOB_KIND[$n]}" "$n"
  done
}

# The main stack as four processes. wire, diff, paths, secrets and params stay together, in the order they were written in (wire has to
# come first: it reads the first frame the client ever sends); the pool is kept busy by the mutants for the whole run, so splitting
# them further would buy nothing. size, transcript and pr + latch + kill each make their own repo state and files and read nothing
# another group left behind, so each gets a stack of its own.
section "-- the real client: main stack (groups wire diff paths secrets params size transcript pr latch kill), as four processes"
scenario "main (wire diff paths secrets params)" main wire,diff,paths,secrets,params
scenario "main (size)" main size
scenario "main (transcript)" main transcript
scenario "main (pr latch kill)" main pr,latch,kill
cover
section "-- the real client: a PATH without gh"
scenario nogh nogh
section "-- the real client: --repo below the git toplevel, and the rate limit"
scenario subdir subdir
section "-- the real client: HMD_UI_CONTROLS=0"
scenario killenv killenv

section "-- mutants: one rule removed from a copy, the cases that guard it must fail"
mutant drop-secret-mask  bin/lib/companion_view.py $'        if P.secret_shaped(text):\n            return REDACTED' $'        if False:\n            return REDACTED' secrets
mutant accept-env        bin/lib/companion_view.py 'name.startswith(".env") or name.endswith(_DENIED_SUFFIXES)' 'name.endswith(_DENIED_SUFFIXES[1:])' paths
mutant accept-dot-git    bin/lib/companion_view.py 'if any(s in _DENIED_DIRS for s in low):' 'if False:' paths
mutant skip-symlink-check bin/lib/companion_view.py 'if os.path.realpath(candidate) != candidate:' 'if False:' paths
mutant skip-max-bytes-cut bin/lib/companion_view.py '"max_bytes": max_bytes,' '"max_bytes": 10 ** 9,' size
mutant skip-cap-check    bin/lib/companion_view.py $'        if not has_cap:\n            return False, "caps-missing", {}' $'        if False:\n            return False, "caps-missing", {}' wire
# skip-redaction: _relay_redactor is the one place the relay's redaction profile becomes a callable, and state.views, state.dashboards
# and state.asks all take theirs from it -- this one site is the whole rule. A second inline copy of that lambda would make the site
# appear twice and the mutant unbuildable ("found 2 times, not once"): the alarm that the rule has been duplicated again.
mutant skip-redaction    bin/heimdall-relay-client 'return (lambda obj: UI._redact_public(obj, strip_root)) if redact else None' 'return None' secrets
mutant drop-turn-mask    bin/lib/companion_view.py $'    if P.secret_shaped(text[:limit + SCAN_MARGIN]):\n        return REDACTED' $'    if False:\n        return REDACTED' transcript,pr
mutant scan-only-shown-text bin/lib/companion_view.py 'P.secret_shaped(text[:limit + SCAN_MARGIN])' 'P.secret_shaped(text[:limit - 1])' transcript
mutant turn-cap-240      bin/lib/companion_view.py 'TURN_CHARS = 400' 'TURN_CHARS = 240' transcript
mutant collapse-turn-newlines bin/lib/companion_view.py '"s": _multi_line(text, TURN_CHARS)' '"s": _one_line(text, TURN_CHARS)' transcript
mutant lone-cr-is-no-break bin/lib/companion_view.py 'for line in raw.splitlines()' 'for line in raw.split("\n")' transcript
mutant keep-blank-runs   bin/lib/companion_view.py '_BLANK_RUN = re.compile(r"\n{3,}")' '_BLANK_RUN = re.compile(r"\n{999,}")' transcript
mutant skip-tail         bin/lib/companion_view.py 'chosen = turns[-req["tail"]:]' 'chosen = turns' transcript
mutant show-denied-output bin/lib/companion_view.py 'if lines and not _names_denied(call):' 'if lines:' transcript
mutant follow-transcript-symlink bin/lib/companion_view.py 'os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK |' 'os.open(path, os.O_RDONLY | os.O_NONBLOCK |' transcript
mutant accept-any-agent-id bin/lib/companion_view.py 'or _AGENT_ID.fullmatch(agent) is None))' 'or False))' transcript
mutant pr-token-in-argv  bin/lib/companion_view.py '["gh", "pr", "view", "--json", PR_FIELDS]' '["gh", "pr", "view", "--json", PR_FIELDS, "--token", os.environ.get("GH_TOKEN", "")]' pr
mutant pr-forward-gh-repo bin/lib/companion_view.py '"GH_CONFIG_DIR", "GH_HOST", "GH_TOKEN"' '"GH_CONFIG_DIR", "GH_HOST", "GH_REPO", "GH_TOKEN"' pr
mutant pr-no-timeout     bin/lib/companion_view.py 'GH_DEADLINE_S = 8.0' 'GH_DEADLINE_S = 3600.0' pr
mutant pr-trust-exit-code bin/lib/companion_view.py $'        if code != 0:  # not logged in, no pull request for this branch, offline, ...: nothing to show\n            raise ViewError("not-found")' $'        if False:\n            raise ViewError("not-found")' pr
mutant gate-ignore-head  bin/lib/companion_view.py 'green = covered == head and receipt.get("tree_clean") is True' 'green = receipt.get("tree_clean") is True' pr

run_pool
report_jobs

echo ""
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
