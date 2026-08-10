#!/usr/bin/env bash
# test/heimdall-dream-schedule.test.sh — acceptance for the AUTO-BACKGROUND nightly
# schedule of /dream (bin/heimdall-dream-schedule): a macOS launchd LaunchAgent
# (com.heimdall.dream) that fires `heimdall-dream --repo <repo> run --overnight`
# nightly at 03:00 and logs to ~/.heimdall/logs/dream.log.
#
# Hermetic + PRIVILEGE-FREE: the LaunchAgent dir and the log path are redirected to a
# throwaway tmp dir via env overrides, and `launchctl` is SHIMMED (LAUNCHCTL=<mock>)
# so the suite proves register / idempotent / status / uninstall WITHOUT loading a
# real agent or requiring root. The mock records every call and tracks a "loaded"
# state file so `status` reflects load/unload truthfully.
#
# FALSIFIABLE claims proven:
#   (1) INSTALL writes a com.heimdall.dream plist encoding the EXACT overnight command
#       (heimdall-dream --repo <repo> run --overnight) at cron 03:00 and the log path,
#       and loads it via launchctl.
#   (2) IDEMPOTENT — install twice leaves exactly ONE plist and ONE loaded job (no dup).
#   (3) STATUS reports the job registered (loaded) after install; --json is parseable.
#   (4) UNINSTALL unloads via launchctl and removes the plist; status then reports gone;
#       a second uninstall is a clean no-op (idempotent off-switch).
#   (5) run-now fires the SAME argv the schedule encodes and writes a fresh dated report.
#   (6) EPHEMERAL-CHECKOUT REFUSAL — install from a LINKED git worktree refuses (exit 5)
#       WITHOUT calling launchctl and WITHOUT writing a plist, while the byte-identical
#       tree checked out as the MAIN worktree installs normally. See §6 for the incident.
#
# WHY §1–§4 RUN FROM A FIXTURE, NOT FROM $ROOT
#   The command path the plist pins is derived from where the helper itself lives, and
#   §6's guard refuses an ephemeral one. $ROOT is the MAIN worktree for a human and a
#   LINKED worktree for an agent, so driving install from $ROOT would make this suite
#   pass or fail based on WHO ran it. The canonical fixture below makes the register
#   path deterministic everywhere; run-now (§5) registers nothing and stays on $ROOT.

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
CLI="$ROOT/bin/heimdall-dream-schedule"
DREAM="$ROOT/bin/heimdall-dream"

PASS=0
FAIL=0
ok()  { PASS=$((PASS+1)); printf "  \033[32mPASS\033[0m %s\n" "$1"; }
bad() { FAIL=$((FAIL+1)); printf "  \033[31mFAIL\033[0m %s\n" "$1"; }

command -v jq >/dev/null 2>&1 || { echo "FATAL: jq required" >&2; exit 2; }
[ -x "$CLI" ]   || { echo "FATAL: $CLI not executable" >&2; exit 2; }
[ -x "$DREAM" ] || { echo "FATAL: $DREAM not executable" >&2; exit 2; }

WORK="$(mktemp -d -t "dream-sched-test.$(printf 'X%.0s' 1 2 3 4 5 6)")"
trap 'rm -rf "$WORK"' EXIT

# ── the launchctl SHIM: records calls, tracks a "loaded" state file so status is real.
SHIM="$WORK/mock-launchctl"
STATE="$WORK/loaded"          # exists iff the agent is "loaded"
CALLS="$WORK/calls"           # one line per launchctl invocation
cat > "$SHIM" <<EOF
#!/usr/bin/env bash
echo "\$@" >> "$CALLS"
case "\$1" in
  load|bootstrap)   : > "$STATE"; exit 0 ;;
  unload|bootout)   rm -f "$STATE"; exit 0 ;;
  list)
    if [ -n "\${2:-}" ]; then [ -f "$STATE" ] && exit 0 || exit 1; fi
    [ -f "$STATE" ] && echo "-	0	com.heimdall.dream"; exit 0 ;;
  print) [ -f "$STATE" ] && exit 0 || exit 1 ;;
  *) exit 0 ;;
esac
EOF
chmod +x "$SHIM"

# LaunchAgents dir + log redirected into tmp; launchctl shimmed. Absolute repo.
LA="$WORK/LaunchAgents"
LOG="$WORK/logs/dream.log"
REPO="$WORK/repo"; mkdir -p "$REPO/.planning"
PLIST="$LA/com.heimdall.dream.plist"

export HEIMDALL_LAUNCH_AGENTS_DIR="$LA"
export HEIMDALL_DREAM_LOG="$LOG"
export LAUNCHCTL="$SHIM"
# The register path STAGES the runner into $HEIMDALL_HOME/bin. Redirect it into the
# throwaway tree: unredirected, this suite would write into the developer's real
# ~/.heimdall on every run. $HOME does not isolate that, and a test writing into real
# user state is exactly the class of accident this file's guards exist to prevent.
export HEIMDALL_HOME="$WORK/heimdall-home"

# ── the CANONICAL vs EPHEMERAL fixture pair ──────────────────────────────────────
# Two checkouts of the SAME commit, holding BYTE-IDENTICAL copies of the helper under
# test. The only difference between them is structural: CANON is the MAIN worktree,
# EPHEM is a linked worktree created by `git worktree add`. That is the whole variable
# §6 isolates — a refusal there cannot be blamed on different code or a different path
# spelling, only on worktree-ness.
#
# Only the files the REGISTER path touches are checked in (the helper, the two shared libs
# it sources, the dream bin it stats and embeds, and the runner it stages), so both
# checkouts are instant. heimdall-dream is never EXECUTED from here — §5 drives run-now
# from $ROOT for that. The lib list is not decoration: both libs fail SAFE when undefined,
# so a fixture missing one refuses to install rather than degrading quietly.
CANON="$WORK/canonical"
EPHEM="$WORK/ephemeral"
mkdir -p "$CANON/bin/lib"
cp "$CLI" "$CANON/bin/heimdall-dream-schedule"
cp "$ROOT/bin/lib/real-home.sh" "$CANON/bin/lib/real-home.sh"
cp "$ROOT/bin/lib/tcc-paths.sh" "$CANON/bin/lib/tcc-paths.sh"
cp "$DREAM" "$CANON/bin/heimdall-dream"
# heimdall-dream-runner is ProgramArguments[0]: the register path stages it OUTSIDE the
# repo (see the TCC note in bin/heimdall-dream-schedule), so it is a fourth file the
# register path touches and the fixture must carry it.
cp "$ROOT/bin/heimdall-dream-runner" "$CANON/bin/heimdall-dream-runner"
chmod +x "$CANON/bin/heimdall-dream-schedule" "$CANON/bin/heimdall-dream" \
         "$CANON/bin/heimdall-dream-runner"
git -C "$CANON" init -q
git -C "$CANON" add -A >/dev/null 2>&1
git -C "$CANON" -c user.email=t@t -c user.name=t commit -qm fixture >/dev/null 2>&1
git -C "$CANON" worktree add --detach -q "$EPHEM" >/dev/null 2>&1

CLI_CANON="$CANON/bin/heimdall-dream-schedule"
DREAM_CANON="$CANON/bin/heimdall-dream"
CLI_EPHEM="$EPHEM/bin/heimdall-dream-schedule"

echo "dream-schedule acceptance"
echo "========================="

# fixture sanity — a mis-built pair would turn §6 green for the wrong reason.
if [ -x "$CLI_EPHEM" ] && [ -f "$EPHEM/.git" ] && [ -d "$CANON/.git" ]; then
  ok "(0) fixture: CANON is the main worktree, EPHEM is a linked worktree of the same commit"
else
  bad "(0) fixture not built (CLI_EPHEM=$([ -x "$CLI_EPHEM" ] && echo yes || echo no), EPHEM/.git file=$([ -f "$EPHEM/.git" ] && echo yes || echo no))"
fi

# ── (1) INSTALL ─────────────────────────────────────────────────────────────────
"$CLI_CANON" install --repo "$REPO" >/dev/null

[ -f "$PLIST" ] && ok "(1) plist written at $PLIST" \
  || bad "(1) plist not written"

grep -q "<string>com.heimdall.dream</string>" "$PLIST" \
  && ok "(1) plist declares Label com.heimdall.dream" \
  || bad "(1) plist missing Label"

# the EXACT overnight command: dream bin + --repo <abs> + run + --overnight
grep -q "$DREAM_CANON" "$PLIST" \
  && grep -q "<string>$REPO</string>" "$PLIST" \
  && grep -q "<string>run</string>" "$PLIST" \
  && grep -q "<string>--overnight</string>" "$PLIST" \
  && ok "(1) plist encodes 'heimdall-dream --repo <repo> run --overnight'" \
  || bad "(1) plist ProgramArguments wrong"

# cron 0 3 * * *  ->  StartCalendarInterval Hour 3 Minute 0
grep -q "StartCalendarInterval" "$PLIST" \
  && ok "(1) plist schedules via StartCalendarInterval (survives restarts)" \
  || bad "(1) no StartCalendarInterval"
python3 - "$PLIST" <<'PY' && ok "(1) fires nightly at 03:00 (Hour=3, Minute=0)" || bad "(1) not 03:00"
import plistlib, sys
with open(sys.argv[1], "rb") as fh:
    pl = plistlib.load(fh)
ci = pl.get("StartCalendarInterval", {})
sys.exit(0 if ci.get("Hour") == 3 and ci.get("Minute") == 0 else 1)
PY

grep -q "$LOG" "$PLIST" \
  && ok "(1) plist logs to the configured dream log" \
  || bad "(1) log path not wired into plist"

grep -q "^load" "$CALLS" \
  && ok "(1) install loaded the agent via launchctl" \
  || bad "(1) launchctl load not invoked"

# ── (2) IDEMPOTENT — install again, still ONE plist + ONE loaded job ──────────────
"$CLI_CANON" install --repo "$REPO" >/dev/null
N="$(find "$LA" -name 'com.heimdall.dream.plist' | wc -l | tr -d ' ')"
[ "$N" = "1" ] && ok "(2) re-install leaves exactly ONE plist (no duplicate)" \
  || bad "(2) duplicate plist(s): $N"
# the mock's loaded-state is a single boolean file — one job, not two.
[ -f "$STATE" ] && ok "(2) exactly one job loaded after double-install" \
  || bad "(2) job not loaded after re-install"

# ── (3) STATUS reports registered ────────────────────────────────────────────────
# capture first (a piped `grep -q` closes the pipe early -> SIGPIPE -> the CLI's own
# pipefail would flip the pipeline red; capturing keeps the assertion honest).
STXT="$("$CLI_CANON" status --repo "$REPO")"
echo "$STXT" | grep -qi "registered\|loaded\|installed" \
  && ok "(3) status reports the job registered" \
  || bad "(3) status did not report registered"
SJSON="$("$CLI_CANON" status --repo "$REPO" --json)"
[ "$(echo "$SJSON" | jq -r '.loaded')" = "true" ] \
  && [ "$(echo "$SJSON" | jq -r '.label')" = "com.heimdall.dream" ] \
  && ok "(3) status --json: loaded=true, label=com.heimdall.dream" \
  || bad "(3) status --json wrong: $SJSON"

# ── (5) run-now fires the SAME argv and writes a fresh dated report ───────────────
DATE="$(date -u +%Y-%m-%d)"
RN="$("$CLI" run-now --repo "$REPO" --json 2>/dev/null || true)"
REP="$REPO/.planning/dream/$DATE.md"
[ -f "$REP" ] && ok "(5) run-now wrote a fresh report at .planning/dream/$DATE.md" \
  || bad "(5) run-now did not write the dated report"
if echo "$RN" | jq -e '.mode == "overnight"' >/dev/null 2>&1; then
  ok "(5) run-now ran in overnight mode (parity with the schedule)"
else
  bad "(5) run-now not in overnight mode: $RN"
fi

# ── (4) UNINSTALL — unload + remove; status gone; second uninstall clean ──────────
"$CLI_CANON" uninstall --repo "$REPO" >/dev/null
[ ! -f "$PLIST" ] && ok "(4) uninstall removed the plist" \
  || bad "(4) plist still present after uninstall"
grep -Eq "^(unload|bootout)" "$CALLS" \
  && ok "(4) uninstall unloaded the agent via launchctl" \
  || bad "(4) launchctl unload not invoked"
UJSON="$("$CLI_CANON" status --repo "$REPO" --json)"
[ "$(echo "$UJSON" | jq -r '.loaded')" = "false" ] \
  && [ "$(echo "$UJSON" | jq -r '.installed')" = "false" ] \
  && ok "(4) status after uninstall: loaded=false, installed=false" \
  || bad "(4) status still shows the job: $UJSON"
# idempotent off-switch: a second uninstall must not error.
if "$CLI_CANON" uninstall --repo "$REPO" >/dev/null 2>&1; then
  ok "(4) second uninstall is a clean no-op (idempotent off-switch)"
else
  bad "(4) second uninstall errored"
fi

# ── (6) EPHEMERAL CHECKOUT — a linked worktree must NEVER reach launchd ──────────
#
# THE INCIDENT THIS CLOSES (observed, not hypothetical). The developer's live
# ~/Library/LaunchAgents/com.heimdall.dream.plist was rewritten to run
#   /Users/rj/Downloads/heimdall/.claude/worktrees/agent-<id>/bin/heimdall-dream
# — an AGENT WORKTREE, a tree that is reaped when the agent finishes. The nightly job
# was left pinned to a path that ceases to exist: it fails silently, and the only
# symptom is dreams quietly stop arriving.
#
# The existing passwd guard (§require_real_launchd_domain) does NOT cover this. That
# run had a GENUINE $HOME — a real user, real passwd home, real launchd domain. The
# only thing wrong was the TREE. So this is a second, distinct mechanism: the register
# path must refuse a command path inside a disposable checkout.
#
# The assertion that would have prevented the incident is the launchctl one: not "it
# printed a warning", but "launchd was NEVER told anything".
: > "$CALLS"; rm -f "$PLIST"
EPHEM_OUT="$("$CLI_EPHEM" install --repo "$EPHEM" 2>&1)" && EPHEM_RC=0 || EPHEM_RC=$?

if [ ! -s "$CALLS" ]; then
  ok "(6) install from a linked worktree: launchctl was NEVER invoked (the incident assertion)"
else
  bad "(6) EPHEMERAL GUARD FAILED — launchctl was called from a worktree checkout: $(tr '\n' ' ' < "$CALLS")"
fi
[ ! -f "$PLIST" ] \
  && ok "(6) install from a linked worktree wrote no plist (refusal precedes write_plist)" \
  || bad "(6) EPHEMERAL GUARD FAILED — a plist was written from a worktree checkout"
[ "$EPHEM_RC" = "5" ] \
  && ok "(6) linked worktree refusal exits 5 — distinct from sandboxed (4) and failure (3)" \
  || bad "(6) wrong exit code for a worktree checkout: $EPHEM_RC (want 5)"
grep -q 'ephemeral checkout' <<<"$EPHEM_OUT" \
  && ok "(6) refusal names the reason (ephemeral checkout), not a generic failure" \
  || bad "(6) refusal wording missing: $(printf '%s' "$EPHEM_OUT" | tr '\n' ' ' | cut -c1-200)"

# The mirror image, and the point of the whole guard: the SAME bytes in the MAIN
# worktree must still register. A guard that also refuses the human it protects is
# just an outage with better manners.
: > "$CALLS"; rm -f "$PLIST"
if "$CLI_CANON" install --repo "$CANON" >/dev/null 2>&1 \
   && [ -f "$PLIST" ] \
   && grep -qF "<string>$DREAM_CANON</string>" "$PLIST" \
   && grep -q "^load" "$CALLS"; then
  ok "(6) the byte-identical helper in the MAIN worktree still installs (plist + launchctl load)"
else
  bad "(6) main-worktree install regressed — the guard is refusing a canonical checkout"
fi
# --repo is pinned into the plist too (WorkingDirectory + the argv), so an ephemeral
# --repo is the same silently-dead job even when the helper itself is canonical.
: > "$CALLS"; rm -f "$PLIST"
REPO_EPHEM_RC=0
"$CLI_CANON" install --repo "$EPHEM" >/dev/null 2>&1 || REPO_EPHEM_RC=$?
if [ "$REPO_EPHEM_RC" = "5" ] && [ ! -f "$PLIST" ] && [ ! -s "$CALLS" ]; then
  ok "(6) an ephemeral --repo is refused too (exit 5, no plist, no launchctl)"
else
  bad "(6) ephemeral --repo not refused (rc=$REPO_EPHEM_RC, plist=$([ -f "$PLIST" ] && echo yes || echo no))"
fi
"$CLI_CANON" uninstall --repo "$REPO" >/dev/null 2>&1 || true

# ── (7) SILENT DEATH IS VISIBLE — status detects a plist pinned to a missing path ──
#
# The incident's lasting damage was not the bad write, it was that nothing afterwards
# said so. launchd does not validate ProgramArguments[0] at load time and does not
# complain at 03:00 when it has vanished — `launchctl list` keeps reporting the job — so
# `status` cheerfully said "registered (installed + loaded)" about a job that had not run
# in weeks. An operator whose nightly job died had no signal at all.
#
# TWO PINNED PATHS NOW. ProgramArguments[0] is the runner staged outside the repo (see
# the TCC note in the helper) and the --dream target is a second path inside it. Either
# vanishing kills the job the same silent way, so the detector must watch BOTH — and this
# section proves both, because a guard that narrowed to one path while gaining a second
# would reproduce the incident it was written for.
: > "$CALLS"; rm -f "$PLIST"
"$CLI_CANON" install --repo "$CANON" >/dev/null 2>&1
# Simulate the reap: the tree the plist points at goes away, exactly as a worktree does.
mv "$DREAM_CANON" "$DREAM_CANON.reaped"
DTXT="$("$CLI_CANON" status --repo "$CANON")"
DJSON="$("$CLI_CANON" status --repo "$CANON" --json)"
if [ "$(echo "$DJSON" | jq -r '.stale')" = "true" ] \
   && [ "$(echo "$DJSON" | jq -r '.stale_path')" = "$DREAM_CANON" ]; then
  ok "(7) status --json flags a plist pinned to a missing DREAM bin (stale=true + the path)"
else
  bad "(7) status --json did not flag the dead job: $DJSON"
fi
echo "$DTXT" | grep -qi 'dead\|stale\|no longer exists' \
  && ok "(7) status says so in words — a dead nightly job is no longer silent" \
  || bad "(7) status text hid the dead job: $(echo "$DTXT" | tr '\n' ' ' | cut -c1-160)"
# Repair is `install`, which is guarded — status itself must stay inert (it is what an
# operator runs while diagnosing, and a repairing status would re-pin from whatever tree
# it happened to run in: the very hijack §6 closes).
: > "$CALLS"
"$CLI_CANON" status --repo "$CANON" >/dev/null 2>&1
grep -Eq '^(load|unload|bootstrap|bootout)' "$CALLS" \
  && bad "(7) status mutated launchd — a read-only subcommand must never repair" \
  || ok "(7) status issues no launchctl load/unload — detection cannot become a hijack vector"
mv "$DREAM_CANON.reaped" "$DREAM_CANON"

# The SECOND pinned path: the staged runner is ProgramArguments[0]. If it is deleted the
# job cannot start at all — a strictly deadlier failure than a missing dream bin, and one
# the pre-split detector could not have expressed.
STAGED_RUNNER="$HEIMDALL_HOME/bin/heimdall-dream-runner"
if [ -x "$STAGED_RUNNER" ]; then
  mv "$STAGED_RUNNER" "$STAGED_RUNNER.reaped"
  RJSON="$("$CLI_CANON" status --repo "$CANON" --json)"
  if [ "$(echo "$RJSON" | jq -r '.stale')" = "true" ] \
     && [ "$(echo "$RJSON" | jq -r '.stale_path')" = "$STAGED_RUNNER" ]; then
    ok "(7) status also flags a missing staged RUNNER (both pinned paths guarded)"
  else
    bad "(7) a deleted runner went undetected: $RJSON"
  fi
  mv "$STAGED_RUNNER.reaped" "$STAGED_RUNNER"
else
  bad "(7) runner was not staged at $STAGED_RUNNER"
fi

# And the repair path itself: a re-install from the canonical tree heals the plist.
"$CLI_CANON" install --repo "$CANON" >/dev/null 2>&1
[ "$("$CLI_CANON" status --repo "$CANON" --json | jq -r '.stale')" = "false" ] \
  && ok "(7) re-running install from the canonical tree heals the stale plist" \
  || bad "(7) install did not heal the stale plist"
"$CLI_CANON" uninstall --repo "$REPO" >/dev/null 2>&1 || true

echo
echo "-------------------------"
printf "TOTAL: %d passed, %d failed\n" "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
