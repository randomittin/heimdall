#!/usr/bin/env bash
# test/protocol-conformance.test.sh — the falsifier for bin/heimdall-conformance.
#
# WHY THIS FILE EXISTS
# --------------------
# `bin/heimdall-conformance` landed in 9b72263 WITHOUT a suite, and its own commit
# message said so: "that tool ships WITHOUT its own suite -- its agent truncated before
# writing one. A gate without a falsifier is exactly what this repo refuses to trust, so
# it is landed as unproven and owes a suite before any protocol claim rests on it."
#
# This is that debt. The tool's whole thesis is that a rule nobody can falsify is a
# comment — so a gate whose own red paths are never exercised is the same disease one
# level up. Section M below breaks each rule the tool enforces and proves the tool goes
# RED; a check that cannot be made to fail is decoration, not a gate.
#
# THE TRAP THIS SUITE EXISTS TO PIN
# ---------------------------------
# `commit-per-unit` decides that an agent worktree is ABANDONED and its uncommitted files
# are lost work. That verdict is acted on by humans. Six agents were running concurrently
# in worktrees while this tool took its first measurement, and every one of them had
# uncommitted files BY DEFINITION — they were mid-keystroke. A tool that flags those is
# not merely noisy, it invites someone to discard live work; and a check that cries wolf
# gets muted, which is how gates die. So BOTH directions are proven, from both sides of
# the freshness boundary, and both are mutation-killed (M1/M2).
#
# WHAT THIS FILE PROVES
#   A. LIVE vs ABANDONED     an abandoned dirty worktree IS flagged; a live one is NEVER
#                            flagged; no-evidence fails toward ALIVE; the freshness
#                            boundary is pinned from both sides.
#   B. EMPTY SCAN IS LOUD    zero worktrees inspected is NON_VERIFIED, never "clean".
#                            "Nothing found therefore fine" is the vacuous green this
#                            tool was written to prevent.
#   C. BRIEF ROUTING         a spawn doc that does not route through heimdall-brief is a
#                            violation, and discovery is a GLOB — a doc dropped into any
#                            scanned root is inspected, so the two-month unwired-brief
#                            failure (a hardcoded list) cannot recur.
#   D. GATE CLASSIFIER       duplicate full-gate runs are caught; an edit between them
#                            clears; `--filter` is not the full gate; and `test/run-all.sh`
#                            only counts in COMMAND POSITION (pgrep/wc/a python string
#                            literal are not gate runs, while nohup/env/time/./ are).
#   E. GATES AT END          a full gate before any edit in the session is a violation.
#   F. TRANSCRIPT FAIL-CLOSED  missing, unreadable, empty, event-free and corrupt
#                            transcripts are ALL NON_VERIFIED on stderr with exit 3 — never
#                            a silent green.
#   G. THE DETECTOR CHECKS ITSELF  running under the full gate while parsing zero gate
#                            invocations is a violation: a blind classifier reports "no
#                            duplicates" forever.
#   H. INVENTORY ANTI-VACUOUS  an extractor that finds too few rules is NON_VERIFIED, the
#                            50-rule floor is pinned from both sides, fenced code is not a
#                            rulebook, and every UNCHECKABLE row carries a stated reason
#                            (the honesty rule: no silent exemption).
#   I. READ-ONLY             the fixture tree is byte-identical after a full run, the
#                            real ~/.heimdall is untouched, and `inventory --write` writes
#                            inside its own $REPO and nowhere else.
#   J. MAIN-CHECKOUT RESOLUTION  launched from inside a REAL linked worktree it still
#                            inspects the main checkout's worktree root. If it resolved to
#                            the worktree it ran from, every check would report
#                            NON_VERIFIED for the exact agents it exists to police.
#   K. EXIT-CODE CONTRACT    0 conformant · 1 violation · 2 usage/dependency · 3
#                            NON_VERIFIED, with 2 never confusable with 1.
#   M. MUTATION PROOFS       nine mutants of the tool, each disarming one rule, each
#                            required to flip a verdict from RED to GREEN.
#
# HERMETIC BY CONSTRUCTION
# Every verdict below is read from a fixture whose expected answer is known by
# construction: fabricated worktrees, fabricated transcripts, a fabricated rulebook, a
# pinned clock (HMD_NOW). Nothing consults the live session, the real ~/.claude/projects,
# the real ~/.heimdall or today's worktree list — those change hourly and a suite that
# reads them flaps.
#
# KNOWN DEFECT, DELIBERATELY NOT PINNED HERE
# `bin/lib/rule-inventory.sh`'s verdict table maps rules to enforcer suites that DO NOT
# EXIST on disk (test/conformance-brief-routing.test.sh, test/session-start-order.test.sh;
# test/conformance-commit-per-unit.test.sh and test/conformance-inventory.test.sh are named
# in the table and are likewise absent). A CHECKED verdict naming a nonexistent falsifier is
# precisely the overclaim the inventory exists to prevent. It is REPORTED rather than pinned
# because the fix belongs in bin/lib/rule-inventory.sh, which this agent does not own — and a
# test that asserted the current behaviour were fine would codify the bug.

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
CONF="$ROOT/bin/heimdall-conformance"

PASS=0
FAIL=0
ok()  { PASS=$((PASS+1)); printf "  \033[32mPASS\033[0m %s\n" "$1"; }
bad() { FAIL=$((FAIL+1)); printf "  \033[31mFAIL\033[0m %s\n" "$1"; }

[ -x "$CONF" ] || { echo "FATAL: $CONF not executable" >&2; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "FATAL: jq required" >&2; exit 2; }

WORK="$(cd "$(mktemp -d -t "protoconf.XXXXXX")" && pwd -P)"
cleanup() { chmod -R u+rwx "$WORK" 2>/dev/null || true; rm -rf "$WORK"; }
trap cleanup EXIT

# ── HERMETIC WORLD ────────────────────────────────────────────────────────────────
# Fingerprint the real home BEFORE anything runs, then redirect every state root the
# tool or its libs can reach into $WORK. Proof I re-checks the fingerprint at the end,
# because "the tests relocate state" is exactly the claim that rots silently.
REAL_HOME_DIR="${HEIMDALL_HOME:-$HOME/.heimdall}"
real_fingerprint() {
  [ -d "$REAL_HOME_DIR" ] || { printf 'absent'; return 0; }
  ls -1 "$REAL_HOME_DIR" 2>/dev/null | sort | tr '\n' ' '
}
REAL_HOME_BEFORE="$(real_fingerprint)"
REAL_ARTIFACT="$ROOT/skills/heimdall/references/protocol-rule-inventory.md"
REAL_ARTIFACT_BEFORE="$( [ -f "$REAL_ARTIFACT" ] && shasum "$REAL_ARTIFACT" | awk '{print $1}' || printf 'absent' )"

export HEIMDALL_HOME="$WORK/home"
export HMD_AGENT_PROJECTS_DIR="$WORK/projects"
mkdir -p "$HEIMDALL_HOME" "$HMD_AGENT_PROJECTS_DIR"

# A clock we own. Every liveness verdict below is arithmetic on T0, never on the wall
# clock — a liveness suite that is itself time-dependent proves nothing.
T0=1800000000
export HMD_NOW=$T0
export HMD_AGENT_SESSION_LIVE_SECS=900

# The self-check in section G probes the PROCESS TREE for test/run-all.sh. Under the full
# gate that probe is true, so it is pinned OFF by default and turned on only where G wants
# it — otherwise this suite would produce different verdicts standalone vs under the gate.
export HMD_CONF_UNDER_GATE=0

# EVERY scan root defaults into the sandbox. Left unset, HMD_CONF_REPO resolves to this
# checkout and HMD_CONF_WORKTREES to the live .claude/worktrees — and the first draft of
# this suite did exactly that: it scanned 56 real agent worktrees and produced a verdict
# that changed with whoever happened to be running. A conformance suite that reads the
# live machine is the flap it is meant to prevent, so the safe default is an empty
# directory and every meaningful root is named per-invocation.
mkdir -p "$WORK/norepo"
export HMD_CONF_REPO="$WORK/norepo"

ERRF="$WORK/stderr"
OUT=""; ERR=""; RC=0
confx() { # confx <binary> <args...>  -> $OUT, $ERR, $RC
  local bin="$1"; shift
  OUT="$("$bin" "$@" 2>"$ERRF")"; RC=$?
  ERR="$(cat "$ERRF")"
}
conf() { confx "$CONF" "$@"; }

has() { printf '%s' "$1" | grep -q "$2"; }

echo ""
echo "── protocol conformance (bin/heimdall-conformance) ──────────────────────────"

# ═══════════════════════════════════════════════════════════════════════════════════
# THE WORKTREE FIXTURE — five worktrees whose verdicts are known by construction
# ═══════════════════════════════════════════════════════════════════════════════════
#   abandoned  dirty + a subagent transcript idle 24h   -> MUST be flagged
#   live       dirty + a subagent transcript idle 1m    -> MUST NOT be flagged
#   noevidence dirty + NO transcript at all             -> MUST NOT be flagged (fails
#                                                          toward alive: an id we cannot
#                                                          resolve is not an accusation)
#   clean      a git worktree with nothing uncommitted  -> silent
#   notgit     a plain directory, not a worktree        -> not evidence about commits
WT="$WORK/worktrees"
SUB="$HMD_AGENT_PROJECTS_DIR/fixture-slug/fixture-session/subagents"
mkdir -p "$WT" "$SUB"
export HMD_CONF_WORKTREES="$WT"
for a in abandoned live noevidence clean; do
  mkdir -p "$WT/agent-$a"
  git -C "$WT/agent-$a" init -q
done
mkdir -p "$WT/agent-notgit"
for a in abandoned live noevidence notgit; do
  printf 'work in flight\n' > "$WT/agent-$a/uncommitted-work.txt"
done
touch_at() { perl -e 'utime $ARGV[0], $ARGV[0], $ARGV[1]' "$1" "$2"; }
mk_transcript() { printf '{"fixture":"%s"}\n' "$1" > "$SUB/agent-$1.jsonl"; touch_at "$2" "$SUB/agent-$1.jsonl"; }
mk_transcript abandoned $(( T0 - 86400 ))
mk_transcript live      $(( T0 - 60 ))
mk_transcript clean     $(( T0 - 60 ))

# ═══ (A) LIVE vs ABANDONED — the false-accusation trap, both directions ════════════
conf commit-per-unit
A_OUT="$OUT"; A_RC="$RC"

has "$A_OUT" '^VIOLATION.*abandoned worktree.*abandoned' \
  && ok "(A) an ABANDONED dirty worktree IS flagged — uncommitted work that was lost" \
  || bad "(A) the abandoned worktree was not flagged: $A_OUT"

[ "$A_RC" = 1 ] \
  && ok "(A) and the tool EXITS 1 on it — a gate, not a note" \
  || bad "(A) exit was $A_RC, expected 1"

printf '%s' "$A_OUT" | grep '^VIOLATION' | grep -q '	live	' \
  && bad "(A) A LIVE WORKTREE WAS FLAGGED ABANDONED — this verdict discards work in flight" \
  || ok "(A) a LIVE dirty worktree is NEVER flagged — an agent mid-keystroke is not a violation"

has "$A_OUT" '^OK.*live agent mid-work.*	live	' \
  && ok "(A) it is reported positively as live, not merely omitted" \
  || bad "(A) the live worktree produced no OK line: $A_OUT"

printf '%s' "$A_OUT" | grep '^VIOLATION' | grep -q 'noevidence' \
  && bad "(A) a worktree with NO liveness evidence was accused — liveness must fail toward ALIVE" \
  || ok "(A) no evidence is not evidence of abandonment — an unresolvable id fails toward ALIVE"

printf '%s' "$A_OUT" | grep -q 'clean' \
  && bad "(A) a worktree with nothing uncommitted was reported at all: $A_OUT" \
  || ok "(A) a clean worktree is silent — the check is about UNCOMMITTED work only"

has "$A_OUT" 'inspected 4 worktree' \
  && ok "(A) the non-git directory is not counted as inspected (4 of 5) — it is not evidence about commits" \
  || bad "(A) inspected count wrong, a plain dir was treated as a worktree: $A_OUT"

# The freshness boundary, from BOTH sides. hmd_subagent_is_alive is `age < 900`, so 899
# is alive and 900 is not; an off-by-one here is the difference between sparing an agent
# and accusing it.
touch_at $(( T0 - 899 )) "$SUB/agent-live.jsonl"
conf commit-per-unit
printf '%s' "$OUT" | grep '^VIOLATION' | grep -q '	live	' \
  && bad "(A) idle 899s (< the 900s window) was called abandoned — off by one, in the costly direction" \
  || ok "(A) boundary: idle 899s of a 900s window is still ALIVE"

touch_at $(( T0 - 900 )) "$SUB/agent-live.jsonl"
conf commit-per-unit
printf '%s' "$OUT" | grep '^VIOLATION' | grep -q '	live	' \
  && ok "(A) boundary: idle exactly 900s crosses the window and IS flagged — the window is real" \
  || bad "(A) at the exact window the worktree was still spared — the staleness test never fires"

touch_at $(( T0 - 60 )) "$SUB/agent-live.jsonl"   # restore the fixture

# ═══ (B) AN EMPTY SCAN IS LOUD ═════════════════════════════════════════════════════
# "Nothing found, therefore fine" is how a green-but-blind gate is born.
mkdir -p "$WORK/empty-worktrees"
HMD_CONF_WORKTREES="$WORK/empty-worktrees" conf commit-per-unit
[ "$RC" = 3 ] && has "$ERR" '^NON_VERIFIED' \
  && ok "(B) a worktree root with nothing in it is NON_VERIFIED (exit 3), never 'clean'" \
  || bad "(B) an empty scan exited $RC with stdout[$OUT] stderr[$ERR]"

[ -z "$OUT" ] \
  && ok "(B) and it prints NO green line — a vacuous pass is not smuggled onto stdout" \
  || bad "(B) an unverified run still printed to stdout: $OUT"

mkdir -p "$WORK/nogit-worktrees/agent-x"
printf 'x\n' > "$WORK/nogit-worktrees/agent-x/f.txt"
HMD_CONF_WORKTREES="$WORK/nogit-worktrees" conf commit-per-unit
[ "$RC" = 3 ] && has "$ERR" '0 git worktrees' \
  && ok "(B) directories that only LOOK like worktrees inspect nothing -> NON_VERIFIED" \
  || bad "(B) a root of non-git dirs exited $RC: $ERR"

HMD_CONF_WORKTREES="$WORK/does-not-exist" conf commit-per-unit
[ "$RC" = 3 ] && has "$ERR" 'no worktree root' \
  && ok "(B) a missing worktree root is NON_VERIFIED — an unreachable verifier is never OPEN" \
  || bad "(B) a missing root exited $RC: $ERR"

# ═══ (C) BRIEF ROUTING ═════════════════════════════════════════════════════════════
# The set of spawn-instruction docs is DISCOVERED. A hardcoded list is exactly how the
# frugal brief sat unwired for two months: three files named it, the check passed, and
# every other spawn path was invisible.
FR="$WORK/briefrepo"
mkdir -p "$FR/agents" "$FR/skills" "$FR/commands"
cat > "$FR/agents/routes.md" <<'EOF'
# routing agent
Spawn the child with subagent_type: builder, and build its context with
`bin/heimdall-brief build --task <id> --spec <text>` — never the plan file.
EOF
HMD_CONF_REPO="$FR" conf brief-routing
[ "$RC" = 0 ] && has "$OUT" '^OK.*routes through the brief.*agents/routes.md' \
  && ok "(C) a spawn doc that routes through heimdall-brief passes" \
  || bad "(C) a compliant spawn doc did not pass (rc=$RC): $OUT$ERR"

cat > "$FR/skills/bypass.md" <<'EOF'
# bypassing skill
Spawn with subagent_type: implementer and paste the full plan file into the prompt.
EOF
HMD_CONF_REPO="$FR" conf brief-routing
[ "$RC" = 1 ] && has "$OUT" '^VIOLATION.*bypasses the frugal brief.*skills/bypass.md' \
  && ok "(C) a spawn doc that pastes the plan instead of the brief is a VIOLATION" \
  || bad "(C) a bypassing spawn doc was not caught (rc=$RC): $OUT$ERR"

cat > "$FR/commands/late.md" <<'EOF'
# a spawn path added later, in a different root
Dispatch work with subagent_type: reviewer. Nothing here mentions the brief.
EOF
HMD_CONF_REPO="$FR" conf brief-routing
has "$OUT" '^VIOLATION.*commands/late.md' && has "$OUT" 'inspected 3 spawn-instruction doc' \
  && ok "(C) discovery is a GLOB: a spawn doc dropped in ANY scanned root is inspected — the hardcoded-list failure cannot recur" \
  || bad "(C) a newly added spawn doc in commands/ was invisible: $OUT"

HMD_CONF_REPO="$WORK/norepo" conf brief-routing
[ "$RC" = 3 ] && has "$ERR" 'detector is blind' \
  && ok "(C) finding ZERO spawn docs means the detector broke, not that the repo is clean -> NON_VERIFIED" \
  || bad "(C) a blind detector exited $RC: $ERR"

# ═══════════════════════════════════════════════════════════════════════════════════
# THE TRANSCRIPT FIXTURES — hand-built JSONL whose event stream is known exactly
# ═══════════════════════════════════════════════════════════════════════════════════
ev_bash() { printf '{"type":"assistant","timestamp":"%s","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":%s}}]}}\n' "$1" "$(jq -n --arg c "$2" '$c')"; }
ev_edit() { printf '{"type":"assistant","timestamp":"%s","message":{"content":[{"type":"tool_use","name":"Edit","input":{"file_path":"%s"}}]}}\n' "$1" "$2"; }
ev_write(){ printf '{"type":"assistant","timestamp":"%s","message":{"content":[{"type":"tool_use","name":"Write","input":{"file_path":"%s"}}]}}\n' "$1" "$2"; }
ev_user() { printf '{"type":"user","timestamp":"%s","message":{"content":"%s"}}\n' "$1" "$2"; }

T_DUPE="$WORK/dupe.jsonl"          # edit, gate, gate      -> one duplicate
{ ev_edit e1 a.sh; ev_bash g1 'bash test/run-all.sh'; ev_bash g2 'bash test/run-all.sh'; } > "$T_DUPE"

T_CLEAN="$WORK/clean.jsonl"        # edit, gate, edit, gate -> disciplined
{ ev_write e1 a.sh; ev_bash g1 'bash test/run-all.sh'; ev_edit e2 b.sh; ev_bash g2 'bash test/run-all.sh'; } > "$T_CLEAN"

T_EARLY="$WORK/early.jsonl"        # gate before any edit
{ ev_bash g1 'bash test/run-all.sh'; ev_edit e1 a.sh; } > "$T_EARLY"

T_NOISE="$WORK/noise.jsonl"        # events, but not one real full-gate run
{
  ev_edit e1 a.sh
  ev_bash n1 'pgrep -f test/run-all.sh'
  ev_bash n2 'wc -l test/run-all.sh'
  ev_bash n3 "python3 -c 'print(\"bash test/run-all.sh\")'"
  ev_bash n4 'bash test/run-all.sh --filter conformance'
  ev_bash n5 'bash test/run-all.sh --filter brief'
} > "$T_NOISE"

T_WRAP="$WORK/wrapped.jsonl"       # five spellings of the same full-gate run
{
  ev_edit e0 a.sh; ev_bash w1 'cd /tmp && bash test/run-all.sh'
  ev_edit e1 a.sh; ev_bash w2 'nohup bash test/run-all.sh'
  ev_edit e2 a.sh; ev_bash w3 'env HEIMDALL_TEST_SLOW=1 bash test/run-all.sh'
  ev_edit e3 a.sh; ev_bash w4 './test/run-all.sh'
  ev_edit e4 a.sh; ev_bash w5 'time bash test/run-all.sh'
} > "$T_WRAP"

# ═══ (D) THE GATE CLASSIFIER ═══════════════════════════════════════════════════════
# The full gate costs ~1374s measured. Two runs with no edit between them is 23 minutes
# spent recomputing a verdict already on screen.
HMD_CONF_TRANSCRIPT="$T_DUPE" conf gate-runs-once
[ "$RC" = 1 ] && has "$OUT" '^VIOLATION.*duplicate full-gate run.*first=g1.*second=g2' \
  && ok "(D) two full-gate runs with NO edit between them is a violation, naming both" \
  || bad "(D) the duplicate gate run was not caught (rc=$RC): $OUT$ERR"

HMD_CONF_TRANSCRIPT="$T_CLEAN" conf gate-runs-once
[ "$RC" = 0 ] && has "$OUT" 'gate_runs=2' \
  && ok "(D) two gate runs WITH an edit between them are two units of work, not waste" \
  || bad "(D) a disciplined session was flagged (rc=$RC): $OUT$ERR"

HMD_CONF_TRANSCRIPT="$T_NOISE" conf gate-runs-once
[ "$RC" = 0 ] && has "$OUT" 'gate_runs=0' \
  && ok "(D) command position is required: pgrep/wc/a python string literal are NOT gate runs, and --filter is not the full gate" \
  || bad "(D) a false positive in the classifier (rc=$RC): $OUT$ERR"

HMD_CONF_TRANSCRIPT="$T_WRAP" conf gate-runs-once
has "$OUT" 'gate_runs=5' \
  && ok "(D) and all five real spellings still count (&& · nohup · env · ./ · time) — no false negatives" \
  || bad "(D) a wrapped full-gate invocation was missed: $OUT"

# ═══ (E) GATES AT END ══════════════════════════════════════════════════════════════
HMD_CONF_TRANSCRIPT="$T_EARLY" conf gates-at-end
[ "$RC" = 1 ] && has "$OUT" '^VIOLATION.*before any edit.*at=g1' \
  && ok "(E) a full gate run BEFORE any edit is a verdict about the previous commit — violation" \
  || bad "(E) an early gate was not caught (rc=$RC): $OUT$ERR"

HMD_CONF_TRANSCRIPT="$T_CLEAN" conf gates-at-end
[ "$RC" = 0 ] \
  && ok "(E) every gate run that followed real work passes" \
  || bad "(E) a correctly ordered session was flagged (rc=$RC): $OUT$ERR"

HMD_CONF_TRANSCRIPT="$T_DUPE" conf gate-runs-once
DUPE_RC1="$RC"
HMD_CONF_TRANSCRIPT="$T_DUPE" conf gates-at-end
[ "$DUPE_RC1" = 1 ] && [ "$RC" = 0 ] \
  && ok "(E) the two checks are independent: the same transcript is a dupe violation and a clean ordering" \
  || bad "(E) gates-at-end and gate-runs-once are not separable: $DUPE_RC1/$RC"

# ═══ (F) TRANSCRIPT FAIL-CLOSED ════════════════════════════════════════════════════
# Five ways the tool can fail to read what it needs. All five must be NON_VERIFIED with
# exit 3, and none may print a green line.
fc() { # fc <label> <transcript-path-or-empty> <expected-stderr-ere>
  local label="$1" t="$2" want="$3"
  if [ -n "$t" ]; then HMD_CONF_TRANSCRIPT="$t" conf gate-runs-once
  else HMD_CONF_TRANSCRIPT="" conf gate-runs-once
  fi
  if [ "$RC" = 3 ] && has "$ERR" "^NON_VERIFIED" && has "$ERR" "$want" && [ -z "$OUT" ]; then
    ok "(F) $label -> NON_VERIFIED, exit 3, nothing green on stdout"
  else
    bad "(F) $label exited $RC stdout[$OUT] stderr[$ERR]"
  fi
}
printf '%s\n' '{"type":"user","timestamp":"t1","message":{"content":"just talking"}}' > "$WORK/eventfree.jsonl"
: > "$WORK/emptyfile.jsonl"
printf 'this is not json at all\n' > "$WORK/corrupt.jsonl"
cp "$WORK/dupe.jsonl" "$WORK/unreadable.jsonl"; chmod 000 "$WORK/unreadable.jsonl"

fc "a transcript that does not exist"        "$WORK/absent.jsonl"    "unreadable"
fc "a transcript that cannot be read"        "$WORK/unreadable.jsonl" "unreadable"
fc "a transcript with zero gate/edit events" "$WORK/eventfree.jsonl" "yielded 0 gate/edit events"
fc "an empty transcript file"                "$WORK/emptyfile.jsonl" "yielded 0 gate/edit events"
fc "a corrupt transcript"                    "$WORK/corrupt.jsonl"   "could not parse"
chmod 644 "$WORK/unreadable.jsonl"

# No transcript resolvable at all: the projects dir is sandboxed and holds no top-level
# session file, so resolution legitimately comes up empty.
HMD_CONF_TRANSCRIPT="" HMD_CONF_REPO="$WORK/norepo" conf gates-at-end
[ "$RC" = 3 ] && has "$ERR" 'no session transcript found' \
  && ok "(F) no session transcript resolvable at all -> NON_VERIFIED, never an assumed-clean session" \
  || bad "(F) an unresolvable transcript exited $RC: $ERR"

# ═══ (G) THE DETECTOR CHECKS ITSELF ════════════════════════════════════════════════
# A parser that silently stops recognising gate runs reports "no duplicates" forever.
# Under a real full-gate run, zero parsed invocations is proof the classifier is blind.
HMD_CONF_UNDER_GATE=1 HMD_CONF_TRANSCRIPT="$T_NOISE" conf gate-runs-once
[ "$RC" = 1 ] && has "$OUT" '^VIOLATION.*detector self-check' \
  && ok "(G) under the full gate, parsing ZERO gate runs is itself a violation — a blind classifier is not a clean session" \
  || bad "(G) the self-check did not fire (rc=$RC): $OUT$ERR"

HMD_CONF_UNDER_GATE=1 HMD_CONF_TRANSCRIPT="$T_CLEAN" conf gate-runs-once
[ "$RC" = 0 ] \
  && ok "(G) and it stays quiet when the parser demonstrably sees the gate" \
  || bad "(G) the self-check fired on a parser that was working (rc=$RC): $OUT"

HMD_CONF_UNDER_GATE=1 HMD_CONF_TRANSCRIPT="$T_NOISE" conf gates-at-end
[ "$RC" = 1 ] && has "$OUT" 'detector self-check' \
  && ok "(G) both transcript checks carry the self-check, not just one" \
  || bad "(G) gates-at-end shipped without the self-check (rc=$RC): $OUT"

# ═══════════════════════════════════════════════════════════════════════════════════
# THE RULEBOOK FIXTURE — a synthetic CLAUDE.md with an exactly known rule count
# ═══════════════════════════════════════════════════════════════════════════════════
# rule_extract counts list items >= 25 chars carrying a normative token, outside fenced
# code. Building the fixture by construction means the 50-rule floor can be pinned from
# both sides instead of asserted against whatever the real rulebook happens to hold today.
mk_rulebook() { # mk_rulebook <dir> <n-normative-rules>
  local dir="$1" n="$2" i
  mkdir -p "$dir"
  {
    printf '# fixture rulebook\n\nProse lines carry no verdict and are not rules.\n\n'
    i=1
    while [ "$i" -le "$n" ]; do
      printf -- '- rule %s: the working tree MUST stay green before handing off unit %s\n' "$i" "$i"
      i=$((i + 1))
    done
  } > "$dir/CLAUDE.md"
}

RB49="$WORK/rb49"; mk_rulebook "$RB49" 49
RB50="$WORK/rb50"; mk_rulebook "$RB50" 50

# ═══ (H) INVENTORY ANTI-VACUOUS + THE HONESTY RULE ═════════════════════════════════
HMD_CONF_REPO="$WORK/norepo" conf inventory
[ "$RC" = 3 ] && has "$ERR" 'extractor is broken' \
  && ok "(H) an inventory over ZERO rules is a broken extractor, not an empty rulebook -> NON_VERIFIED" \
  || bad "(H) an empty rulebook exited $RC: $ERR"

HMD_CONF_REPO="$RB49" conf inventory
[ "$RC" = 3 ] && has "$ERR" 'found only 49 rule' \
  && ok "(H) boundary: 49 rules is below the floor -> NON_VERIFIED, and it says how many it found" \
  || bad "(H) 49 rules exited $RC: $ERR"

HMD_CONF_REPO="$RB50" conf inventory
H50_OUT="$OUT"; H50_RC="$RC"
[ "$H50_RC" = 0 ] && has "$H50_OUT" 'SUMMARY	total=50' \
  && ok "(H) boundary: 50 rules clears the floor and every one is accounted for" \
  || bad "(H) 50 rules exited $H50_RC: $H50_OUT$ERR"

H_ROWS="$(printf '%s' "$H50_OUT" | grep -c '^\(CHECKED\|UNCHECKABLE\|UNCLASSIFIED\)')"
[ "$H_ROWS" = 50 ] \
  && ok "(H) every extracted rule gets its own verdict row (50/50) — none is silently dropped" \
  || bad "(H) $H_ROWS verdict rows for 50 rules"

has "$H50_OUT" 'unclassified=0' \
  && ok "(H) no rule falls through without a verdict" \
  || bad "(H) some rule was UNCLASSIFIED: $(printf '%s' "$H50_OUT" | grep '^UNCLASSIFIED')"

# The honesty rule the whole inventory implements: "a protocol that can't be checked gets
# a line saying so rather than silent exemption." A reasonless UNCHECKABLE is exemption
# wearing a verdict.
H_REASONLESS="$(printf '%s' "$H50_OUT" | awk -F'\t' '$1=="UNCHECKABLE" && length($2) < 20' | grep -c '[^[:space:]]')"
[ "${H_REASONLESS:-0}" = 0 ] \
  && ok "(H) every UNCHECKABLE row states a class AND a reason — no silent exemption" \
  || bad "(H) $H_REASONLESS UNCHECKABLE rows carry no stated reason"

# Fenced code is not a rulebook: a sample that merely contains "MUST NEVER" is not a rule.
RBFENCE="$WORK/rbfence"; mk_rulebook "$RBFENCE" 50
{
  printf '\n```bash\n'
  printf -- '- this fenced sample line MUST NEVER be counted as rule %s\n' 1 2 3 4 5
  printf '```\n'
} >> "$RBFENCE/CLAUDE.md"
HMD_CONF_REPO="$RBFENCE" conf inventory
has "$OUT" 'SUMMARY	total=50' \
  && ok "(H) fenced code is excluded — a code sample containing NEVER is not a normative rule" \
  || bad "(H) fenced code inflated the rule count: $(printf '%s' "$OUT" | grep SUMMARY)"

# A rule naming a real enforcer is CHECKED rather than exempted.
printf -- '- spawned children MUST be briefed with `bin/heimdall-brief`, never the plan\n' >> "$RB50/CLAUDE.md"
HMD_CONF_REPO="$RB50" conf inventory
has "$OUT" '^CHECKED	[^	]' \
  && ok "(H) a rule matching an enforcer is CHECKED and NAMES the enforcer" \
  || bad "(H) no CHECKED row carried an enforcer name"

# ═══ (I) READ-ONLY ═════════════════════════════════════════════════════════════════
# The tool's own header promises "THIS TOOL NEVER MUTATES ANYTHING", because several agent
# worktrees are live agent-memory homes and touching one destroys work in flight. Asserted,
# not assumed: the fixture is fingerprinted byte-for-byte, .git directories included.
fingerprint() { find "$1" -type f | sort | xargs shasum 2>/dev/null | shasum | awk '{print $1}'; }
FIX_BEFORE="$(fingerprint "$WT")"
BRIEF_BEFORE="$(fingerprint "$FR")"

HMD_CONF_TRANSCRIPT="$T_CLEAN" HMD_CONF_REPO="$FR" conf all
ALL_RC="$RC"
[ "$ALL_RC" = 1 ] && has "$OUT" 'abandoned worktree' && has "$OUT" 'bypasses the frugal brief' \
  && ok "(I) \`all\` aggregates every check and reports each one's violations" \
  || bad "(I) the aggregate run lost a check (rc=$ALL_RC): $OUT$ERR"

[ "$(fingerprint "$WT")" = "$FIX_BEFORE" ] \
  && ok "(I) the worktree fixture is byte-identical after a full run — the tool REPORTS, it never cleans" \
  || bad "(I) heimdall-conformance mutated the worktree fixture"

[ "$(fingerprint "$FR")" = "$BRIEF_BEFORE" ] \
  && ok "(I) the scanned repo fixture is byte-identical after a full run" \
  || bad "(I) heimdall-conformance mutated the repo it scanned"

# `inventory --write` is the ONE writing path. Prove it writes inside its own $REPO and
# nowhere else — a writer that ignored $REPO would rewrite the real committed artifact.
mkdir -p "$RB50/skills/heimdall/references"
HMD_CONF_REPO="$RB50" conf inventory --write
[ "$RC" = 0 ] && [ -f "$RB50/skills/heimdall/references/protocol-rule-inventory.md" ] \
  && ok "(I) \`inventory --write\` writes its artifact inside the \$REPO it was pointed at" \
  || bad "(I) --write did not produce an artifact in the fixture repo (rc=$RC): $ERR"

REAL_ARTIFACT_AFTER="$( [ -f "$REAL_ARTIFACT" ] && shasum "$REAL_ARTIFACT" | awk '{print $1}' || printf 'absent' )"
[ "$REAL_ARTIFACT_BEFORE" = "$REAL_ARTIFACT_AFTER" ] \
  && ok "(I) ...and the real repo's committed artifact is untouched by it" \
  || bad "(I) --write escaped its \$REPO and rewrote $REAL_ARTIFACT"

case "$HEIMDALL_HOME" in
  "$WORK"/*) ok "(I) \$HEIMDALL_HOME is redirected into the sandbox for the whole suite" ;;
  *)         bad "(I) \$HEIMDALL_HOME is not sandboxed: $HEIMDALL_HOME" ;;
esac

# ═══ (J) IT RESOLVES TO THE MAIN CHECKOUT, NOT THE WORKTREE IT RAN FROM ════════════
# Agent worktrees carry a full checkout, so `agent-X/bin/heimdall-conformance` is the copy
# that actually runs — and agent worktrees live under the MAIN tree's .claude/worktrees.
# If $REPO resolved to the launching worktree, the worktree root would not exist there and
# every check would report NON_VERIFIED for the exact agents it is meant to police. This
# is a REAL linked worktree (git worktree add), not a simulation of one.
MAINREPO="$WORK/mainrepo"
mkdir -p "$MAINREPO"
git -C "$MAINREPO" init -q 2>/dev/null
git -C "$MAINREPO" -c user.email=fixture@heimdall.test -c user.name=fixture \
  commit -q --allow-empty -m "fixture root" 2>/dev/null
mkdir -p "$MAINREPO/.claude/worktrees"
CHILD="$MAINREPO/.claude/worktrees/agent-child"
git -C "$MAINREPO" worktree add -q -b fixture-child "$CHILD" 2>/dev/null
mkdir -p "$CHILD/bin"
cp "$CONF" "$CHILD/bin/heimdall-conformance"
ln -s "$ROOT/bin/lib" "$CHILD/bin/lib"
printf 'work in flight\n' > "$CHILD/uncommitted-work.txt"

if [ -d "$CHILD/.git" ] || [ -f "$CHILD/.git" ]; then
  ok "(J) fixture: a REAL linked git worktree under the main checkout's .claude/worktrees"
else
  bad "(J) could not create the linked worktree fixture — (J) proves nothing"
fi

# No HMD_CONF_REPO, no HMD_CONF_WORKTREES: resolution is the thing under test.
OUT="$(env -u HMD_CONF_REPO -u HMD_CONF_WORKTREES "$CHILD/bin/heimdall-conformance" commit-per-unit 2>"$ERRF")"; RC=$?
ERR="$(cat "$ERRF")"
[ "$RC" = 0 ] && has "$OUT" 'inspected 1 worktree' \
  && ok "(J) launched from INSIDE a linked worktree it still inspects the MAIN checkout's worktree root" \
  || bad "(J) resolution escaped to the launching worktree (rc=$RC): $OUT$ERR"

has "$OUT" 'child' \
  && ok "(J) and it sees the very agent worktree it was launched from — self-inspection works" \
  || bad "(J) the launching worktree was invisible to the check: $OUT"

# ═══ (K) THE EXIT-CODE CONTRACT ════════════════════════════════════════════════════
# The header publishes four exits and other tooling will branch on them: 0 conformant,
# 1 violation, 2 usage/dependency, 3 NON_VERIFIED. 2 must never be confused with 1.
conf
[ "$RC" = 2 ] && has "$ERR" 'usage: heimdall-conformance' && [ -z "$OUT" ] \
  && ok "(K) no argument is a usage error: exit 2, usage on stderr, nothing on stdout" \
  || bad "(K) a bare invocation exited $RC: $OUT$ERR"

conf definitely-not-a-check
[ "$RC" = 2 ] && has "$ERR" 'unknown check definitely-not-a-check' \
  && ok "(K) an unknown check is exit 2 and NAMES the unknown check — never a silent 0" \
  || bad "(K) an unknown check exited $RC: $ERR"

conf --help
[ "$RC" = 2 ] \
  && ok "(K) --help keeps the usage exit, so a mistyped check can never read as conformant" \
  || bad "(K) --help exited $RC"

# ═══════════════════════════════════════════════════════════════════════════════════
# (M) MUTATION PROOFS — break the rule, prove the tool goes RED
# ═══════════════════════════════════════════════════════════════════════════════════
# Every check above asserts that a fixture produces a verdict. That is only evidence if
# the verdict COULD have been different. Each mutant below disarms exactly one rule inside
# heimdall-conformance and must flip a RED verdict to GREEN (or, for M2, flip a spared
# worktree into an accused one). A mutant that SURVIVES means the assertion above it is a
# tautology and proves nothing.
echo ""
echo "-- M. MUTATION: prove the red paths are checks, not tautologies -------------"

MUT="$WORK/mut"
mkdir -p "$MUT"
ln -s "$ROOT/bin/lib" "$MUT/lib"

# One `local` per name on purpose: bash expands EVERY word of a `local` statement before
# it assigns any of them, so `local a="$1" b="$MUT/$a"` reads an unbound $a under set -u.
mutant() { # mutant <name> <sed-script>  -> prints the mutant path, or "" if the edit missed
  local name="$1"
  local script="$2"
  local path="$MUT/$name"
  sed "$script" "$CONF" > "$path"
  chmod +x "$path"
  if cmp -s "$path" "$CONF"; then printf ''; else printf '%s' "$path"; fi
}

# ── M1 — liveness forced ALIVE: nothing can ever be called abandoned ────────────────
M1="$(mutant conf.m1 's|^    if hmd_subagent_is_alive "$id"; then$|    if true; then|')"
if [ -z "$M1" ]; then
  bad "M1 NOT APPLIED: the liveness branch no longer matches — this mutation proof is dead"
else
  confx "$M1" commit-per-unit
  [ "$RC" = 0 ] && ! has "$OUT" '^VIOLATION' \
    && ok "M1 KILLED: forcing every agent ALIVE turns (A)'s violation green -> the abandoned verdict is a real check" \
    || bad "M1 SURVIVED: the mutant that can never call anything abandoned still went RED (rc=$RC): $OUT"
fi

# ── M2 — liveness forced DEAD: the false-accusation direction ──────────────────────
# This is the mutant that matters most. If (A)'s "a live worktree is never flagged"
# assertion cannot detect a tool that accuses everything, it is not protecting anyone.
M2="$(mutant conf.m2 's|^    if hmd_subagent_is_alive "$id"; then$|    if false; then|')"
if [ -z "$M2" ]; then
  bad "M2 NOT APPLIED: the liveness branch no longer matches — this mutation proof is dead"
else
  confx "$M2" commit-per-unit
  printf '%s' "$OUT" | grep '^VIOLATION' | grep -q '	live	' \
    && ok "M2 KILLED: forcing every agent DEAD accuses the LIVE worktree -> (A)'s no-false-accusation assertion really watches that" \
    || bad "M2 SURVIVED: a tool that treats every agent as dead still spared the live worktree — the trap is unguarded: $OUT"
fi

# ── M3 — the anti-vacuous guard removed from commit-per-unit ───────────────────────
M3="$(mutant conf.m3 's|^  \[ "\$inspected" -gt 0 \] .*$|  :|')"
if [ -z "$M3" ]; then
  bad "M3 NOT APPLIED: the inspected-count guard no longer matches"
else
  HMD_CONF_WORKTREES="$WORK/empty-worktrees" confx "$M3" commit-per-unit
  [ "$RC" = 0 ] \
    && ok "M3 KILLED: deleting the inspected>0 guard makes an EMPTY SCAN pass -> (B) is the thing keeping it loud" \
    || bad "M3 SURVIVED: the mutant with no anti-vacuous guard still exited $RC on an empty scan"
fi

# ── M4 — the brief marker made unfalsifiable ───────────────────────────────────────
M4="$(mutant conf.m4 "s|^BRIEF_MARK='heimdall-brief'\$|BRIEF_MARK='.'|")"
if [ -z "$M4" ]; then
  bad "M4 NOT APPLIED: BRIEF_MARK no longer matches"
else
  HMD_CONF_REPO="$FR" confx "$M4" brief-routing
  [ "$RC" = 0 ] \
    && ok "M4 KILLED: a marker that matches any line turns the bypassing docs green -> (C) really tests for the brief" \
    || bad "M4 SURVIVED: a marker matching every line still reported a bypass (rc=$RC): $OUT"
fi

# ── M5 — the duplicate-gate memory disarmed ────────────────────────────────────────
M5="$(mutant conf.m5 's|^      pending="\$ts"$|      pending=""|')"
if [ -z "$M5" ]; then
  bad "M5 NOT APPLIED: the pending-gate assignment no longer matches"
else
  HMD_CONF_TRANSCRIPT="$T_DUPE" confx "$M5" gate-runs-once
  [ "$RC" = 0 ] \
    && ok "M5 KILLED: forgetting the previous gate run makes the duplicate invisible -> (D) is a real check" \
    || bad "M5 SURVIVED: the mutant that never remembers a gate run still found a duplicate (rc=$RC): $OUT"
fi

# ── M6 — gates-at-end pre-satisfied ────────────────────────────────────────────────
M6="$(mutant conf.m6 's|seen_mutate=0 gates=0 early=0|seen_mutate=1 gates=0 early=0|')"
if [ -z "$M6" ]; then
  bad "M6 NOT APPLIED: the seen_mutate initialiser no longer matches"
else
  HMD_CONF_TRANSCRIPT="$T_EARLY" confx "$M6" gates-at-end
  [ "$RC" = 0 ] \
    && ok "M6 KILLED: pretending work already happened turns the early gate green -> (E) is a real check" \
    || bad "M6 SURVIVED: the mutant that assumes prior work still flagged the early gate (rc=$RC): $OUT"
fi

# ── M7 — fail-closed disarmed everywhere at once ───────────────────────────────────
# nonverified() is the single choke point for every unreadable-source path. Neutering it
# is the exact shape of a fail-OPEN gate: the tool cannot read what it needs and says
# nothing. Both the empty-scan and the unreadable-transcript paths must go green.
M7="$(mutant conf.m7 's|^nonverified() .*$|nonverified() { return 0; }|')"
if [ -z "$M7" ]; then
  bad "M7 NOT APPLIED: the nonverified() definition no longer matches"
else
  HMD_CONF_TRANSCRIPT="$WORK/absent.jsonl" confx "$M7" gate-runs-once
  M7A="$RC"
  HMD_CONF_WORKTREES="$WORK/empty-worktrees" confx "$M7" commit-per-unit
  M7B="$RC"
  [ "$M7A" = 0 ] && [ "$M7B" = 0 ] \
    && ok "M7 KILLED: making NON_VERIFIED a no-op turns an unreadable transcript AND an empty scan into silent passes -> (B)/(F) are the fail-closed guard" \
    || bad "M7 SURVIVED: with nonverified() disarmed the tool still exited $M7A/$M7B instead of passing silently"
fi

# ── M8 — the detector self-check disarmed ──────────────────────────────────────────
M8="$(mutant conf.m8 's|^  if _under_full_gate && \[ "\$gates" -eq 0 \]; then$|  if false; then|')"
if [ -z "$M8" ]; then
  bad "M8 NOT APPLIED: the self-check condition no longer matches"
else
  HMD_CONF_UNDER_GATE=1 HMD_CONF_TRANSCRIPT="$T_NOISE" confx "$M8" gate-runs-once
  [ "$RC" = 0 ] \
    && ok "M8 KILLED: removing the self-check lets a BLIND classifier report a clean session -> (G) is a real check" \
    || bad "M8 SURVIVED: the mutant with no self-check still went RED (rc=$RC): $OUT"
fi

# ── M9 — main-checkout resolution disarmed ─────────────────────────────────────────
# Collapse the linked-worktree branch of _main_worktree() to "wherever I was launched
# from". This is the failure the tool's header warns about: run from an agent worktree it
# would look for .claude/worktrees INSIDE that worktree, find nothing, and report
# NON_VERIFIED for every agent it exists to police.
sed 's|^    ( cd "$here" && cd "$(dirname "$cd_")" && pwd )$|    printf %s "$here"|' \
  "$CONF" > "$CHILD/bin/conf.m9"
chmod +x "$CHILD/bin/conf.m9"
if cmp -s "$CHILD/bin/conf.m9" "$CONF"; then
  bad "M9 NOT APPLIED: the linked-worktree resolution branch no longer matches"
else
  OUT="$(env -u HMD_CONF_REPO -u HMD_CONF_WORKTREES "$CHILD/bin/conf.m9" commit-per-unit 2>"$ERRF")"; RC=$?
  ERR="$(cat "$ERRF")"
  [ "$RC" = 3 ] && has "$ERR" 'no worktree root' \
    && ok "M9 KILLED: resolving \$REPO to the launching worktree turns (J) into NON_VERIFIED -> the main-checkout resolution is load-bearing" \
    || bad "M9 SURVIVED: with resolution collapsed the run still exited $RC: $OUT$ERR"
fi

# ── the mutants must not have leaked into the real tool ────────────────────────────
cmp -s "$CONF" "$MUT/conf.m1" 2>/dev/null \
  && bad "(M) a mutant is byte-identical to the shipped tool — the mutations edited the wrong file" \
  || ok "(M) every mutant is a sandboxed COPY; bin/heimdall-conformance itself is never edited"

# ═══ (I, cont.) THE REAL HOME IS UNTOUCHED ═════════════════════════════════════════
REAL_HOME_AFTER="$(real_fingerprint)"
[ "$REAL_HOME_BEFORE" = "$REAL_HOME_AFTER" ] \
  && ok "(I) the real $REAL_HOME_DIR is untouched by the whole suite" \
  || bad "(I) this suite wrote into the REAL home: before[$REAL_HOME_BEFORE] after[$REAL_HOME_AFTER]"

echo ""
printf "  %s passed, %s failed\n" "$PASS" "$FAIL"
[ "$FAIL" = 0 ] || exit 1
exit 0
