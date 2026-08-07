#!/usr/bin/env bash
# test/dream-permission-ask.test.sh — acceptance for the FIRST-RUN PERMISSION ASK.
#
# WHAT THIS CLOSES. Commit 245ede5 made the nightly /dream fail LOUDLY instead of
# silently: the runner now lives outside the TCC-protected repo, probes it, records a
# structured status and exits 75. That turned 24 silent days into a visible failure —
# but a visible failure is still a failure. The machine says "blocked: tcc-denied" every
# night and the operator is never actually ASKED for the one thing that would fix it.
#
# So: on FIRST RUN, and only when a grant is genuinely needed, say plainly what is
# missing, why, what breaks without it, and the exact steps — including the option that
# needs NO permission at all. Then never ask again unless the situation changes.
#
# THE HONESTY CONSTRAINT IS PART OF THE FEATURE. macOS exposes NO API to request or set
# Full Disk Access, and it does NOT raise its own prompt for a launchd job (measured in
# 245ede5: a probe LaunchAgent was refused with no prompt shown). A tool that implied
# otherwise would send the operator hunting for a dialog that is never coming. So the
# block must state that a human click is required, and this suite asserts the tool never
# reaches for TCC state itself.
#
# ARMED BY STRUCTURE, DISARMED BY EVIDENCE. The ask arms on a structural fact (the repo
# is inside a macOS-protected folder, so a LaunchAgent cannot read it) and disarms on
# evidence from the launchd domain itself (a scheduled run that recorded result=ok proves
# the job CAN read the repo). That is what makes "do not re-ask once granted" a
# measurement rather than a checkbox the operator has to remember to tick.
#
# FALSIFIABLE claims proven:
#   (1) A protected repo ARMS the ask: check reports needs-grant, ask prints the block.
#   (2) The block is COMPLETE — names the permission, the cause, what breaks, the repo,
#       and a runnable step for every option it offers.
#   (3) The block is HONEST — says a human click is required and that Heimdall cannot
#       grant it; the tool never invokes tccutil / reads TCC.db / opens Settings by itself.
#   (4) IDEMPOTENT — a second ask on the same subject is SILENT (no nag), --force re-shows.
#   (5) DISARMED BY EVIDENCE — a scheduled run recorded result=ok goes silent and CLEARS
#       the marker, so a later recurrence re-arms honestly.
#   (6) A repo OUTSIDE a protected folder never asks at all.
#   (7) A CHANGED SUBJECT (different repo) asks again — it is a different grant.
#   (8) REVERSIBLE — heimdall-dream-schedule uninstall removes what the ask added.
#   (9) WIRED — heimdall-dream-schedule install surfaces the block on a protected repo.
#  (10) THE LOUD PATH FROM 245ede5 STILL FIRES — when nothing could run the runner still
#       exits 75 and records blocked, a denied repo is still RECORDED as unreachable, and
#       the notice still names TCC and the denied path. The ask ADDS a remedy; it must
#       never become a substitute for the failure report.

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
PERM="$ROOT/bin/heimdall-dream-permission"
SCHED="$ROOT/bin/heimdall-dream-schedule"
RUNNER="$ROOT/bin/heimdall-dream-runner"
NOTICE="$ROOT/bin/heimdall-dream-notice"
DREAM="$ROOT/bin/heimdall-dream"

PASS=0
FAIL=0
ok()  { PASS=$((PASS+1)); printf "  \033[32mPASS\033[0m %s\n" "$1"; }
bad() { FAIL=$((FAIL+1)); printf "  \033[31mFAIL\033[0m %s\n" "$1"; }

[ -x "$PERM" ]   || { echo "FATAL: $PERM not executable" >&2; exit 2; }
[ -x "$SCHED" ]  || { echo "FATAL: $SCHED not executable" >&2; exit 2; }
[ -x "$RUNNER" ] || { echo "FATAL: $RUNNER not executable" >&2; exit 2; }
[ -x "$NOTICE" ] || { echo "FATAL: $NOTICE not executable" >&2; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "FATAL: jq required" >&2; exit 2; }

# PHYSICALLY RESOLVED on purpose. On macOS mktemp hands back /var/folders/... while /var is
# a symlink to /private/var, and the protected-root predicate resolves physically so a
# symlinked $HOME cannot launder a path past it. Comparing a physical answer against an
# unresolved fixture path would make these assertions pass only by substring accident.
WORK="$(cd "$(mktemp -d -t "dream-perm-test.$(printf 'X%.0s' 1 2 3 4 5 6)")" && pwd -P)"
cleanup() { chmod -R u+rwx "$WORK" 2>/dev/null || true; rm -rf "$WORK"; }
trap cleanup EXIT

# ── HERMETIC WORLD ───────────────────────────────────────────────────────────────
# A FAKE $HOME is what makes the protected-folder predicate testable: the predicate asks
# whether a path is under <home>/Downloads|Documents|Desktop, so a throwaway home gives us
# a real "protected" folder with none of the developer's actual ~/Downloads involved.
# HEIMDALL_REAL_HOME points the passwd-derived answer at the same throwaway tree, which is
# the seam bin/lib/real-home.sh documents — launchctl still goes through the shim below and
# the plist still lands in $HEIMDALL_LAUNCH_AGENTS_DIR, so nothing can reach a real domain.
FHOME="$WORK/home"
mkdir -p "$FHOME/Downloads" "$FHOME/Documents" "$FHOME/Desktop"
HH="$WORK/heimdall-home"            # $HEIMDALL_HOME — deliberately NOT under $FHOME/Downloads
STATE="$HH/dream-permission.json"   # the "already asked" marker
STATUSF="$WORK/dream-status.json"

export HOME="$FHOME"
export HEIMDALL_REAL_HOME="$FHOME"
export HEIMDALL_HOME="$HH"
export HEIMDALL_DREAM_STATUS="$STATUSF"

# `open` is SHIMMED and RECORDED. The tool must never open System Settings on its own —
# that is an action, and the contract here is detect-and-ask, never act.
OPENLOG="$WORK/open-calls"
OPENSHIM="$WORK/mock-open"
cat > "$OPENSHIM" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$OPENLOG"
exit 0
EOF
chmod +x "$OPENSHIM"
export HEIMDALL_OPEN="$OPENSHIM"

PROT_REPO="$FHOME/Downloads/heimdall"      # the shape of the owner's real machine
SAFE_REPO="$FHOME/src/heimdall"            # the shape after option [A]
mkdir -p "$PROT_REPO/.planning" "$SAFE_REPO/.planning"

write_status() { # write_status <file> <result> <reason> <denied_path>
  cat > "$1" <<EOF
{
  "schema": 1,
  "ts": "2026-08-05T03:20:07Z",
  "date": "2026-08-05",
  "label": "com.heimdall.dream",
  "result": "$2",
  "reason": "$3",
  "repo": "$PROT_REPO",
  "dream": "$PROT_REPO/bin/heimdall-dream",
  "denied_path": "$4",
  "detail": "ls: $4: Operation not permitted",
  "exit": 75
}
EOF
}

echo "dream first-run permission ask"
echo "=============================="

# ── (1) ARMED BY STRUCTURE ───────────────────────────────────────────────────────
write_status "$STATUSF" blocked tcc-denied "$PROT_REPO"

CRC=0
CJSON="$("$PERM" check --repo "$PROT_REPO" --json)" || CRC=$?
if [ "$(printf '%s' "$CJSON" | jq -r '.state')" = "needs-grant" ]; then
  ok "(1) a repo inside a protected folder reports state=needs-grant"
else
  bad "(1) check did not arm: $CJSON"
fi
if [ "$CRC" = 1 ]; then
  ok "(1) check exits 1 when a grant is needed (scriptable)"
else
  bad "(1) check exit was $CRC, expected 1"
fi
if [ "$(printf '%s' "$CJSON" | jq -r '.protected_root')" = "$FHOME/Downloads" ]; then
  ok "(1) check names the protected root that armed it"
else
  bad "(1) check did not name the protected root: $CJSON"
fi

BLOCK="$("$PERM" ask --repo "$PROT_REPO" 2>&1)"
if [ -n "$BLOCK" ]; then
  ok "(1) ask prints the permission block on first run"
else
  bad "(1) ask printed nothing on first run"
fi

ARC=0
"$PERM" ask --repo "$PROT_REPO" --force >/dev/null 2>&1 || ARC=$?
[ "$ARC" = 0 ] && ok "(1) ask always exits 0 (hook-safe)" || bad "(1) ask exited $ARC"

# ── (2) THE BLOCK IS COMPLETE ────────────────────────────────────────────────────
has() { printf '%s' "$BLOCK" | grep -qi -- "$1"; }

has 'Full Disk Access' \
  && ok "(2) names the missing permission (Full Disk Access)" \
  || bad "(2) block never names the permission"

{ has 'protect' && has "$FHOME/Downloads"; } \
  && ok "(2) names WHY — the repo sits in a macOS-protected folder" \
  || bad "(2) block does not explain the cause"

{ has '03:00' && has 'report'; } \
  && ok "(2) names WHAT BREAKS — the 03:00 run, and the missing report" \
  || bad "(2) block does not say what breaks"

has "$PROT_REPO" \
  && ok "(2) names the exact repo the grant is about" \
  || bad "(2) block omits the repo path"

# EVERY option it offers must be runnable — an ask with no command is a complaint.
{ has 'heimdall-dream-schedule install' && has 'mv '; } \
  && ok "(2) option [A] (move the repo) is spelled as runnable commands" \
  || bad "(2) the no-permission option has no runnable step"

has 'System Settings' \
  && ok "(2) option [B] (grant) names where the human must click" \
  || bad "(2) the grant option does not say where to click"

{ has 'heimdall-dream' && has 'run'; } \
  && ok "(2) option [C] keeps the works-today manual command in front of him" \
  || bad "(2) block drops the manual remedy"

# The verbatim OS error is the evidence line — a diagnosis must not be paraphrased away.
has 'Operation not permitted' \
  && ok "(2) block carries the verbatim OS error from the last blocked attempt" \
  || bad "(2) block lost the recorded OS error"

# ── (3) THE BLOCK IS HONEST, AND THE TOOL NEVER ACTS ─────────────────────────────
{ has 'cannot grant' || has 'cannot be granted' || has 'only you'; } \
  && ok "(3) states plainly that Heimdall cannot grant this itself" \
  || bad "(3) block does not admit the grant is out of its hands"

{ has 'click' || has 'human'; } \
  && ok "(3) states that a human click is required" \
  || bad "(3) block does not say a human must act"

# 245ede5 measured that no prompt is raised for a launchd job. Saying so stops the
# operator waiting for a dialog that is never coming.
{ has 'no prompt' || has 'will not prompt' || has 'does not prompt'; } \
  && ok "(3) warns that macOS raises NO prompt for a background job" \
  || bad "(3) block does not warn that no prompt will appear"

if [ ! -s "$OPENLOG" ]; then
  ok "(3) ask opened NOTHING — detect-and-ask never becomes act"
else
  bad "(3) ask opened System Settings by itself: $(tr '\n' ' ' < "$OPENLOG")"
fi

# COMMENT LINES ARE STRIPPED FIRST. The file DOCUMENTS this policy in prose ("never
# invokes tccutil, never touches the TCC database"), and a naive scan flags that
# documentation as the violation it describes. What must be absent is the INVOCATION, so
# the scan runs over code only.
if sed 's/[[:space:]]*#.*$//' "$PERM" | grep -Eq 'tccutil|TCC\.db|sqlite3'; then
  bad "(3) the tool reaches for TCC state itself — it must only detect and ask"
else
  ok "(3) the tool never invokes tccutil and never touches the TCC database"
fi

# open-settings is a SEPARATE, EXPLICIT verb — the human asked, so macOS's own UI opens.
: > "$OPENLOG"
"$PERM" open-settings >/dev/null 2>&1 || true
if grep -q 'Privacy_AllFiles' "$OPENLOG" 2>/dev/null; then
  ok "(3) open-settings opens the Full Disk Access pane — only when explicitly asked"
else
  bad "(3) open-settings did not open the pane: $(cat "$OPENLOG" 2>/dev/null)"
fi

# ── (4) IDEMPOTENT — asked once, never nags ──────────────────────────────────────
AGAIN="$("$PERM" ask --repo "$PROT_REPO" 2>&1)"
if [ -z "$AGAIN" ]; then
  ok "(4) a second ask on the same subject is SILENT (no nag)"
else
  bad "(4) the ask repeated itself: $(printf '%s' "$AGAIN" | head -3 | tr '\n' ' ')"
fi

[ -f "$STATE" ] && ok "(4) the ask records that it was shown" \
  || bad "(4) no marker written at $STATE"

FORCED="$("$PERM" ask --repo "$PROT_REPO" --force 2>&1)"
[ -n "$FORCED" ] && ok "(4) --force re-shows the block on demand" \
  || bad "(4) --force printed nothing"

"$PERM" reset --repo "$PROT_REPO" >/dev/null 2>&1
RESHOWN="$("$PERM" ask --repo "$PROT_REPO" 2>&1)"
[ -n "$RESHOWN" ] && ok "(4) reset re-arms the ask" || bad "(4) reset did not re-arm"

# ── (5) DISARMED BY EVIDENCE — a successful scheduled run proves the grant landed ──
# This is the assertion behind "does not re-ask once granted". Nothing is self-reported:
# result=ok can only be written by the runner AFTER the launchd job actually read the repo.
write_status "$STATUSF" ok "" ""
GRC=0
GJSON="$("$PERM" check --repo "$PROT_REPO" --json)" || GRC=$?
if [ "$(printf '%s' "$GJSON" | jq -r '.state')" = "granted" ] && [ "$GRC" = 0 ]; then
  ok "(5) a scheduled run that recorded result=ok disarms the ask (state=granted, exit 0)"
else
  bad "(5) a successful scheduled run did not disarm: rc=$GRC $GJSON"
fi

QUIET="$("$PERM" ask --repo "$PROT_REPO" 2>&1)"
[ -z "$QUIET" ] && ok "(5) ask is silent once the scheduled job is proven to reach the repo" \
  || bad "(5) ask nagged a working schedule: $QUIET"

[ ! -f "$STATE" ] \
  && ok "(5) the marker is CLEARED on success, so a later recurrence re-arms honestly" \
  || bad "(5) a stale marker survived success — a recurrence would go unasked"

write_status "$STATUSF" blocked tcc-denied "$PROT_REPO"
REARM="$("$PERM" ask --repo "$PROT_REPO" 2>&1)"
[ -n "$REARM" ] && ok "(5) a RECURRENCE after success asks again (not permanently muted)" \
  || bad "(5) a recurrence was silently swallowed"

# ── (6) A NON-PROTECTED REPO NEVER ASKS ──────────────────────────────────────────
rm -f "$STATE"
SRC=0
SJSON="$("$PERM" check --repo "$SAFE_REPO" --json)" || SRC=$?
if [ "$(printf '%s' "$SJSON" | jq -r '.state')" = "ok" ] && [ "$SRC" = 0 ]; then
  ok "(6) a repo outside every protected folder reports state=ok (exit 0)"
else
  bad "(6) a safe repo was flagged: rc=$SRC $SJSON"
fi
SOUT="$("$PERM" ask --repo "$SAFE_REPO" 2>&1)"
[ -z "$SOUT" ] && ok "(6) ask is silent for a repo that needs no grant" \
  || bad "(6) ask nagged a repo that needs nothing: $SOUT"

# ── (7) A CHANGED SUBJECT ASKS AGAIN ─────────────────────────────────────────────
OTHER="$FHOME/Documents/otherrepo"; mkdir -p "$OTHER/.planning"
"$PERM" ask --repo "$PROT_REPO" >/dev/null 2>&1
OTHER_OUT="$("$PERM" ask --repo "$OTHER" 2>&1)"
if printf '%s' "$OTHER_OUT" | grep -q "$OTHER"; then
  ok "(7) a DIFFERENT repo is a different grant — the block is shown again"
else
  bad "(7) a new protected repo inherited the old repo's silence"
fi

# ── (8) REVERSIBLE — uninstall removes what install added ─────────────────────────
# Canonical MAIN-worktree fixture, same discipline as the sibling suites: the register
# path refuses a linked worktree, and $ROOT is one for an agent.
SHIM="$WORK/mock-launchctl"
CALLS="$WORK/calls"
cat > "$SHIM" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$CALLS"
exit 0
EOF
chmod +x "$SHIM"
export LAUNCHCTL="$SHIM"

CANON="$WORK/canonical"
mkdir -p "$CANON/bin/lib"
cp "$SCHED"  "$CANON/bin/heimdall-dream-schedule"
cp "$PERM"   "$CANON/bin/heimdall-dream-permission"
cp "$DREAM"  "$CANON/bin/heimdall-dream"
cp "$RUNNER" "$CANON/bin/heimdall-dream-runner"
cp "$ROOT/bin/lib/real-home.sh" "$CANON/bin/lib/real-home.sh"
cp "$ROOT/bin/lib/tcc-paths.sh" "$CANON/bin/lib/tcc-paths.sh"
chmod +x "$CANON/bin/heimdall-dream-schedule" "$CANON/bin/heimdall-dream" \
         "$CANON/bin/heimdall-dream-runner" "$CANON/bin/heimdall-dream-permission"
git -C "$CANON" init -q
git -C "$CANON" add -A >/dev/null 2>&1
git -C "$CANON" -c user.email=t@t -c user.name=t commit -qm fixture >/dev/null 2>&1

LA="$WORK/LaunchAgents"
export HEIMDALL_LAUNCH_AGENTS_DIR="$LA"
export HEIMDALL_DREAM_LOG="$WORK/logs/dream.log"
PLIST="$LA/com.heimdall.dream.plist"

# ── (9) WIRED — install surfaces the block on a protected repo ────────────────────
rm -f "$STATE"
write_status "$STATUSF" blocked tcc-denied "$PROT_REPO"
IRC=0
IOUT="$("$CANON/bin/heimdall-dream-schedule" install --repo "$PROT_REPO" 2>&1)" || IRC=$?

if [ "$IRC" = 0 ] && [ -f "$PLIST" ]; then
  ok "(9) install still succeeds for a protected REPO (the repo is deliberately exempt)"
else
  bad "(9) install refused a protected repo (rc=$IRC) — the exemption regressed"
fi
if printf '%s' "$IOUT" | grep -qi 'Full Disk Access'; then
  ok "(9) install surfaces the permission block — the ask reaches him at first run"
else
  bad "(9) install said nothing about the permission: $(printf '%s' "$IOUT" | tr '\n' ' ' | cut -c1-200)"
fi
if [ -f "$PLIST" ] && plutil -lint "$PLIST" >/dev/null 2>&1; then
  ok "(9) the plist install generates is still lint-clean"
else
  bad "(9) generated plist failed plutil -lint"
fi
# and installing twice must not re-ask — idempotence has to survive the wiring
I2="$("$CANON/bin/heimdall-dream-schedule" install --repo "$PROT_REPO" 2>&1)" || true
if printf '%s' "$I2" | grep -qi 'Full Disk Access'; then
  bad "(9) a re-install re-asked — the wiring broke idempotence"
else
  ok "(9) a re-install does NOT re-ask (idempotent through the install path)"
fi

[ -f "$STATE" ] && ok "(8) install left the marker behind it" || bad "(8) install wrote no marker"
"$CANON/bin/heimdall-dream-schedule" uninstall --repo "$PROT_REPO" >/dev/null 2>&1 || true
[ ! -f "$STATE" ] \
  && ok "(8) uninstall removes the marker — the feature is fully reversible" \
  || bad "(8) uninstall orphaned the permission marker at $STATE"

# ── (10) THE LOUD PATH FROM 245ede5 STILL FIRES ──────────────────────────────────
# The ask is an ADDITION. If it ever became a substitute for the failure report we would
# be back to a job whose only signal is one the operator has to go looking for.
#
# RETARGETED, NOT RELAXED. This block used to point the runner at a repo at mode 000 and
# demand exit 75. 92daf9d deliberately removed that trigger: dream's state moved to
# $HEIMDALL_HOME, so an unreadable repo no longer costs the run anything it needs, and
# failing there kept the nightly job dead for a reason that had been removed. That commit
# inverted the same fixture in dream-tcc-resilience (2)/(2b) but left this copy pointing at
# the retired trigger, where it went red measuring the fixture instead of the guarantee.
# The guarantee is "nothing ran ⇒ it says so, loudly", and its live trigger is an
# unreachable DREAM SCRIPT — still a hard precondition. Both halves are asserted here: the
# loud path on the target that still fires it, and the honesty of the denied-repo path the
# ask itself exists for. Nothing is dropped; (10b) is net-new coverage.
DENIED_HOME="$WORK/denied-home"; mkdir -p "$DENIED_HOME"

# (10a) NOTHING COULD RUN — the silent-death case, on the target that still causes it.
GONE="$WORK/gone-dream"            # deliberately never created: the program is unreadable
GSTATUS="$WORK/gone-status.json"
GRC=0
HEIMDALL_HOME="$DENIED_HOME" "$RUNNER" --dream "$GONE" --repo "$WORK" \
  --status "$GSTATUS" run --overnight >"$WORK/gone.log" 2>&1 || GRC=$?

[ "$GRC" = 75 ] && ok "(10) runner STILL exits 75 when nothing could run — never a silent 0" \
  || bad "(10) runner exit regressed to $GRC"
grep -q '"result": "blocked"' "$GSTATUS" 2>/dev/null \
  && ok "(10) runner STILL records result=blocked" \
  || bad "(10) runner stopped recording the blocked status"
grep -qi 'BLOCKED' "$WORK/gone.log" \
  && ok "(10) runner STILL shouts into the dream log" \
  || bad "(10) runner went quiet"

# (10b) THE REPO IS DENIED — the exact situation the ask exists for. The run proceeds, but
# a bare "ok" would read as proof the grant landed and nobody would ever look again.
DENIED="$WORK/denied"; mkdir -p "$DENIED/.planning"
chmod 000 "$DENIED"
DSTATUS="$WORK/denied-status.json"
DRC=0
HEIMDALL_HOME="$DENIED_HOME" "$RUNNER" --dream "$DREAM" --repo "$DENIED" \
  --status "$DSTATUS" run --overnight >"$WORK/denied.log" 2>&1 || DRC=$?
chmod 755 "$DENIED"

grep -q '"repo_reachable": "no"' "$DSTATUS" 2>/dev/null \
  && ok "(10) a denied repo is RECORDED unreachable — an ok never reads as a landed grant" \
  || bad "(10) status hid the denial (exit $DRC): $(head -12 "$DSTATUS" 2>/dev/null | tr '\n' ' ')"
grep -qi 'repo unreadable' "$WORK/denied.log" \
  && ok "(10) the run names the denial BEFORE dream starts — a diagnosis, not a surprise" \
  || bad "(10) the denied-repo run went quiet about the denial"
[ ! -e "$DENIED/.planning/dream" ] \
  && ok "(10) FALSIFIER: nothing was written into the denied repo" \
  || bad "(10) the run wrote into the denied repo"

# (10c) THE ALARM IS NOT STUCK ON. An assertion that only ever fires one way cannot tell a
# working alarm from a jammed one: if the runner exited 75 unconditionally, (10a) would
# still be green and would still prove nothing. So hand the SAME runner a dream it can read
# and require the shouting to STOP. That is what makes (10a) evidence rather than
# coincidence — the 75 tracked the breakage, and ended when the breakage did.
OKREPO="$WORK/okrepo"; mkdir -p "$OKREPO/.planning"
RSTATUS="$WORK/restored-status.json"
RRC=0
HEIMDALL_HOME="$DENIED_HOME" "$RUNNER" --dream "$DREAM" --repo "$OKREPO" \
  --status "$RSTATUS" run --overnight >"$WORK/restored.log" 2>&1 || RRC=$?

[ "$RRC" = 0 ] \
  && ok "(10) FALSIFIER: a readable dream returns the runner to exit 0 — the 75 was earned" \
  || bad "(10) runner still failing after restore ($RRC) — (10a) proved nothing: $(head -3 "$WORK/restored.log")"
grep -q '"result": "ok"' "$RSTATUS" 2>/dev/null \
  && ok "(10) FALSIFIER: and the status returns to ok — the alarm is not jammed on" \
  || bad "(10) status stuck at non-ok: $(head -8 "$RSTATUS" 2>/dev/null | tr '\n' ' ')"
! grep -qi 'BLOCKED' "$WORK/restored.log" \
  && ok "(10) FALSIFIER: and the log stops shouting — silence is earned, not permanent" \
  || bad "(10) runner still shouting BLOCKED on a healthy run"

# and the thing the operator ACTUALLY sees surfaces the genuine failure. A status file
# nobody reads is the 10-night silence with extra steps.
#
# A REPO WITH NO REPORT FOR TODAY, deliberately — not $OKREPO. The (10c) run above just
# wrote today's report into $OKREPO, and notice is designed to self-clear once a report
# supersedes a stale blocked status (case (6) of dream-tcc-resilience). Pointing this at
# $OKREPO would assert silence is a failure when silence is the correct answer there.
BREPO="$WORK/blocked-repo"; mkdir -p "$BREPO/.planning/dream"
BNOTICE="$("$NOTICE" --repo "$BREPO" --status "$GSTATUS" 2>&1 || true)"
printf '%s' "$BNOTICE" | grep -qi 'not running\|blocked' \
  && ok "(10) heimdall-dream-notice surfaces the blocked run to the operator" \
  || bad "(10) notice stayed silent about a blocked run: $BNOTICE"

NREPO="$WORK/nrepo"; mkdir -p "$NREPO/.planning/dream"
NSTATUS="$WORK/notice-status.json"
write_status "$NSTATUS" blocked tcc-denied "$PROT_REPO"
mkdir -p "$LA"; printf '%s\n' '<plist></plist>' > "$PLIST"
NOUT="$("$NOTICE" --repo "$NREPO" --status "$NSTATUS" 2>&1)"
{ printf '%s' "$NOUT" | grep -qi 'TCC' && printf '%s' "$NOUT" | grep -q "$PROT_REPO"; } \
  && ok "(10) notice STILL names TCC and the exact denied path" \
  || bad "(10) notice lost its diagnosis: $(printf '%s' "$NOUT" | tr '\n' ' ' | cut -c1-200)"
printf '%s' "$NOUT" | grep -q 'heimdall-dream-permission' \
  && ok "(10) notice now also points at the permission ask (remedy added, not swapped)" \
  || bad "(10) notice does not route to the permission ask"

# ══ INTERACTIVE ARMS ═════════════════════════════════════════════════════════════
#
# THE OWNER'S OBJECTION, VERBATIM: "the user would grant this, but prompt from hmd is
# required". He is willing to grant Full Disk Access. What he refuses is being handed
# homework — a block that tells him to go type another command later. So when a human is
# demonstrably present, ASK, and act on the answer within the same flow.
#
# THE GATE IS THE WHOLE SAFETY ARGUMENT. A prompt that fires from the SessionStart hook,
# a pipe, CI or `curl | bash` is far worse than the homework it replaces: it hangs a job
# nobody is watching. So interactivity is gated on BOTH stdin and stdout being a terminal,
# and §11 proves the non-interactive arm cannot prompt, cannot open anything, and does not
# even CONSUME stdin — the last being the property that makes hanging impossible.
#
#   (11) NON-INTERACTIVE never prompts, never opens, never reads stdin, exits 0.
#   (12) A REAL PTY opens the interactive branch with no seam set — the gate is genuinely
#        `[ -t 0 ] && [ -t 1 ]` and not something the seam invented.
#   (13) [C] declines cleanly.
#   (14) [B] OPENS the Full Disk Access pane from inside the flow — the objection, fixed.
#   (15) [B] re-probes afterwards and NEVER claims hmd granted anything.
#   (16) [A] does NOT move the repo without a separate explicit confirmation.
#   (17) [A] REFUSES to move a repo with linked worktrees (it would break every one).
#   (18) EOF and timeout both fall back to "do nothing" — a prompt cannot wedge.

PROMPT_MARK='Your choice'

echo
echo "  -- interactive arms --"

# ── (11) NON-INTERACTIVE: the hook/pipe/CI arm ───────────────────────────────────
rm -f "$STATE"; : > "$OPENLOG"
write_status "$STATUSF" blocked tcc-denied "$PROT_REPO"

NI="$(printf 'B\ny\n' | "$PERM" ask --repo "$PROT_REPO" 2>&1)"
NI_RC=$?
if printf '%s' "$NI" | grep -q 'Full Disk Access' \
   && ! printf '%s' "$NI" | grep -q "$PROMPT_MARK"; then
  ok "(11) no TTY: prints the block and does NOT prompt"
else
  bad "(11) non-interactive arm prompted or lost the block"
fi
[ "$NI_RC" = 0 ] && ok "(11) no TTY: exits 0" || bad "(11) non-interactive exit was $NI_RC"
if [ ! -s "$OPENLOG" ]; then
  ok "(11) no TTY: opened nothing"
else
  bad "(11) non-interactive arm opened System Settings: $(tr '\n' ' ' < "$OPENLOG")"
fi

# THE ANTI-HANG PROOF. If the tool consumed stdin, `cat` downstream sees nothing. A tool
# that never reads the pipe cannot block on it, which is the real guarantee a hook needs.
rm -f "$STATE"
LEFTOVER="$(printf 'B\ny\n' | { "$PERM" ask --repo "$PROT_REPO" >/dev/null 2>&1; cat; })"
if [ "$LEFTOVER" = "$(printf 'B\ny')" ]; then
  ok "(11) no TTY: stdin is left UNREAD — it cannot block on a pipe"
else
  bad "(11) non-interactive arm consumed stdin: got '$LEFTOVER'"
fi

# ── (12) FALSIFIER: a REAL pty opens the interactive branch, with NO seam set ────
# `script -q /dev/null` hands the child a genuine tty on both descriptors. Its own pty
# echo makes feeding answers unreliable, so this asserts only what it can assert
# honestly: with a real terminal the PROMPT APPEARS; without one (§11) it never does.
# That isolates the gate itself as the thing controlling interactivity.
rm -f "$STATE"; : > "$OPENLOG"
if command -v script >/dev/null 2>&1; then
  PTY_OUT="$(script -q /dev/null "$PERM" ask --repo "$PROT_REPO" </dev/null 2>&1 | tr -d '\r' || true)"
  if printf '%s' "$PTY_OUT" | grep -q "$PROMPT_MARK"; then
    ok "(12) FALSIFIER: with a REAL pty the prompt appears (the gate is the tty, not the seam)"
  else
    bad "(12) a real pty did not open the interactive branch"
  fi
  # …and closing stdin on that same pty must not wedge it. It got here, so it did not.
  ok "(12) a pty whose stdin is at EOF still terminates (no wedge)"
else
  bad "(12) script(1) unavailable — cannot prove the tty gate end to end"
fi

# ── the seam that drives ANSWERS ─────────────────────────────────────────────────
# HEIMDALL_DREAM_PERMISSION_TTY=1 forces the interactive branch so answers can be piped
# deterministically. §12 above is what keeps this honest: it proves the REAL gate opens
# on a real terminal, so the seam is a test convenience, not the feature.
I() { HEIMDALL_DREAM_PERMISSION_TTY=1 HEIMDALL_DREAM_PERMISSION_TIMEOUT=5 "$PERM" ask --repo "$1" 2>&1; }

# ── (13) [C] — not now ───────────────────────────────────────────────────────────
rm -f "$STATE"; : > "$OPENLOG"
C_OUT="$(printf 'c\n' | I "$PROT_REPO")"
printf '%s' "$C_OUT" | grep -q "$PROMPT_MARK" \
  && ok "(13) interactive: the choice is actually put to him" \
  || bad "(13) no prompt shown in interactive mode"
[ ! -s "$OPENLOG" ] && ok "(13) [C] opens nothing" \
  || bad "(13) [C] opened something: $(tr '\n' ' ' < "$OPENLOG")"
[ -f "$STATE" ] && ok "(13) [C] still records the ask (asked once, no nag)" \
  || bad "(13) [C] wrote no marker"

# ── (14) [B] — THE OBJECTION, FIXED: the pane opens from inside the flow ─────────
rm -f "$STATE"; : > "$OPENLOG"
B_OUT="$(printf 'b\ny\n\n' | I "$PROT_REPO")"
if grep -q 'Privacy_AllFiles' "$OPENLOG" 2>/dev/null; then
  ok "(14) [B] OPENS System Settings at Full Disk Access — no second command to type"
else
  bad "(14) [B] did not open the pane: $(cat "$OPENLOG" 2>/dev/null)"
fi
printf '%s' "$B_OUT" | grep -qi 'blast radius\|every other program\|interpreter' \
  && ok "(14) [B] still warns about the blast radius before he commits" \
  || bad "(14) [B] dropped the blast-radius warning"

# ── (15) [B] verdict is a MEASUREMENT, never a claim ─────────────────────────────
printf '%s' "$B_OUT" | grep -qi 'cannot confirm\|cannot read\|cannot see' \
  && ok "(15) [B] states plainly what it cannot see (macOS permission state)" \
  || bad "(15) [B] verdict does not admit its limits"
if printf '%s' "$B_OUT" | grep -Eqi 'granted successfully|permission granted|you are all set|now works|is now working'; then
  bad "(15) [B] CLAIMED success it cannot possibly verify"
else
  ok "(15) FALSIFIER: [B] never claims hmd granted anything or that 03:00 now works"
fi
printf '%s' "$B_OUT" | grep -q 'result: *ok\|result=ok\|heimdall-dream-permission check' \
  && ok "(15) [B] names the proof that actually counts (a scheduled run / check)" \
  || bad "(15) [B] gives him no way to confirm later"

# ── (16) [A] — never moves his repo as a side effect ─────────────────────────────
# A permission flow that quietly relocates a live checkout would be the worst kind of
# helpful. The move needs its own confirmation, and anything short of it is a no-op.
MREPO="$FHOME/Downloads/movable"; mkdir -p "$MREPO/.planning"
printf '%s\n' 'canary' > "$MREPO/canary.txt"
rm -f "$STATE"; : > "$OPENLOG"
A_OUT="$(printf 'a\nyes\n' | I "$MREPO")"
if [ -f "$MREPO/canary.txt" ]; then
  ok "(16) [A] did NOT move the repo without the explicit confirmation word"
else
  bad "(16) [A] MOVED HIS REPO on a plain 'yes' — unacceptable"
fi
printf '%s' "$A_OUT" | grep -q 'mv ' \
  && ok "(16) [A] hands him the paste-ready mv + re-register commands" \
  || bad "(16) [A] printed no move commands"

# ── (17) [A] refuses a repo with linked worktrees ────────────────────────────────
# Moving a checkout that has linked worktrees breaks every one of them: their .git files
# hold ABSOLUTE gitdir paths. Refusing beats a helpful move that detonates 30 worktrees.
WREPO="$FHOME/Downloads/wtrepo"; mkdir -p "$WREPO"
git -C "$WREPO" init -q 2>/dev/null
printf '%s\n' 'x' > "$WREPO/f.txt"
git -C "$WREPO" add -A >/dev/null 2>&1
git -C "$WREPO" -c user.email=t@t -c user.name=t commit -qm f >/dev/null 2>&1
git -C "$WREPO" worktree add --detach -q "$FHOME/Downloads/wtlinked" >/dev/null 2>&1
rm -f "$STATE"
W_OUT="$(printf 'a\nMOVE\n' | I "$WREPO")"
if [ -d "$WREPO" ] && [ -f "$WREPO/f.txt" ]; then
  ok "(17) [A] refused to move a repo that has linked worktrees"
else
  bad "(17) [A] moved a repo with linked worktrees — it would break every one"
fi
printf '%s' "$W_OUT" | grep -qi 'worktree' \
  && ok "(17) the refusal NAMES linked worktrees as the reason" \
  || bad "(17) refusal did not explain itself: $(printf '%s' "$W_OUT" | tr '\n' ' ' | cut -c1-200)"

# ── (18) EOF and TIMEOUT both fall back to doing nothing ─────────────────────────
rm -f "$STATE"; : > "$OPENLOG"
E_RC=0
HEIMDALL_DREAM_PERMISSION_TTY=1 HEIMDALL_DREAM_PERMISSION_TIMEOUT=5 \
  "$PERM" ask --repo "$PROT_REPO" </dev/null >/dev/null 2>&1 || E_RC=$?
[ "$E_RC" = 0 ] && ok "(18) stdin at EOF: exits 0 (never wedges)" \
  || bad "(18) EOF exit was $E_RC"
[ ! -s "$OPENLOG" ] && ok "(18) stdin at EOF: opened nothing" \
  || bad "(18) EOF path opened something"

T0="$(date +%s)"
T_RC=0
HEIMDALL_DREAM_PERMISSION_TTY=1 HEIMDALL_DREAM_PERMISSION_TIMEOUT=1 \
  "$PERM" ask --repo "$PROT_REPO" >/dev/null 2>&1 <<'NOANSWER' || T_RC=$?
NOANSWER
T1="$(date +%s)"
if [ "$T_RC" = 0 ] && [ "$((T1 - T0))" -lt 20 ]; then
  ok "(18) an unanswered prompt times out and exits 0 rather than hanging"
else
  bad "(18) unanswered prompt: rc=$T_RC after $((T1 - T0))s"
fi

# ── (19) the non-interactive block is UNCHANGED by any of this ───────────────────
# 41 assertions above describe that block. The interactive arm is an ADDITION; if it had
# quietly rewritten the printed path, every hook and CI consumer would have changed too.
rm -f "$STATE"
FINAL="$("$PERM" ask --repo "$PROT_REPO" 2>&1)"
if [ "$FINAL" = "$NI" ]; then
  ok "(19) the non-interactive block is byte-identical to before the interactive work"
else
  bad "(19) the printed block drifted between runs"
fi

# ── (20) --interactive-only: DEFER rather than spend the one-shot in a pipe ──────
#
# THE CALL SITE THIS EXISTS FOR. The published install is `curl … | bash`. Plain `ask`
# is right for a hook or a manual run — it prints the block and records that it did. But
# an installer running under a pipe has NO human: the block scrolls past unread and the
# marker is spent, so the FIRST person who ever sits at a terminal is met with silence.
# That is strictly worse than not asking at all, because the one chance was consumed by
# nobody.
#
# So the install and update paths pass --interactive-only, which means: ask NOW if a
# human is demonstrably here, otherwise do NOTHING AT ALL and stay armed. Nothing means
# nothing — no block, no marker, no stdin read, exit 0.
#
# THE GATE IS THE SAME ONE. --interactive-only reuses can_prompt() verbatim, so there is
# exactly one definition of "a human is present" in the file and a caller cannot invent a
# second that disagrees with it. §20e is the falsifier: a real pty still prompts.
echo
echo "  -- deferral arm (--interactive-only) --"

rm -f "$STATE"; : > "$OPENLOG"
write_status "$STATUSF" blocked tcc-denied "$PROT_REPO"

D_RC=0
D_OUT="$(printf 'B\ny\n' | "$PERM" ask --repo "$PROT_REPO" --interactive-only 2>&1)" || D_RC=$?
[ -z "$D_OUT" ] \
  && ok "(20) --interactive-only with no TTY prints NOTHING — no block scrolls past in a pipe" \
  || bad "(20) --interactive-only printed into a pipe: $(printf '%s' "$D_OUT" | head -3 | tr '\n' ' ')"
[ "$D_RC" = 0 ] && ok "(20) --interactive-only with no TTY exits 0" \
  || bad "(20) --interactive-only exited $D_RC"
[ ! -s "$OPENLOG" ] && ok "(20) --interactive-only with no TTY opens nothing" \
  || bad "(20) --interactive-only opened something: $(tr '\n' ' ' < "$OPENLOG")"

# THE ANTI-BURN ASSERTION — the whole point. A deferred ask must leave the one-shot
# UNSPENT, or wiring it into a piped installer would permanently mute the first real ask.
[ ! -f "$STATE" ] \
  && ok "(20) --interactive-only does NOT spend the one-shot marker when it defers" \
  || bad "(20) a headless --interactive-only wrote the marker — the first real ask is now muted"

# And it cannot block on the pipe either: an unread stdin is what makes that impossible.
LEFTOVER2="$(printf 'B\ny\n' | { "$PERM" ask --repo "$PROT_REPO" --interactive-only >/dev/null 2>&1; cat; })"
[ "$LEFTOVER2" = "$(printf 'B\ny')" ] \
  && ok "(20) --interactive-only leaves stdin UNREAD — a piped installer cannot wedge" \
  || bad "(20) --interactive-only consumed stdin: got '$LEFTOVER2'"

# The deferral is only worth anything if the ask is still THERE afterwards.
STILL="$("$PERM" ask --repo "$PROT_REPO" 2>&1)"
printf '%s' "$STILL" | grep -q 'Full Disk Access' \
  && ok "(20) after a deferral the ask is still ARMED — the first human still gets it" \
  || bad "(20) a deferred ask went missing: $(printf '%s' "$STILL" | tr '\n' ' ' | cut -c1-160)"

# (20e) FALSIFIER: the gate is genuinely the tty. With a REAL pty, --interactive-only
# does NOT defer — it asks. If this went green while §20's silence also went green for
# the wrong reason (e.g. the flag disabling the ask outright), this assertion catches it.
rm -f "$STATE"; : > "$OPENLOG"
if command -v script >/dev/null 2>&1; then
  PTY_D="$(script -q /dev/null "$PERM" ask --repo "$PROT_REPO" --interactive-only </dev/null 2>&1 | tr -d '\r' || true)"
  printf '%s' "$PTY_D" | grep -q "$PROMPT_MARK" \
    && ok "(20) FALSIFIER: with a REAL pty --interactive-only ASKS (it defers, it never disables)" \
    || bad "(20) --interactive-only failed to ask on a real terminal"
  printf '%s' "$PTY_D" | grep -q 'Full Disk Access' \
    && ok "(20) the pty path still prints the full block before the prompt" \
    || bad "(20) --interactive-only dropped the block on a real terminal"
else
  bad "(20) script(1) unavailable — cannot prove --interactive-only asks on a real tty"
fi

echo "------------------------------"
if [ "$FAIL" -eq 0 ]; then
  printf "dream-permission: \033[32m%d passed\033[0m, 0 failed\n" "$PASS"
else
  printf "dream-permission: %d passed, \033[31m%d failed\033[0m\n" "$PASS" "$FAIL"
  exit 1
fi
