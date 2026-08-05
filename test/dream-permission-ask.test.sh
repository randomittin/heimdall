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
#  (10) THE LOUD PATH FROM 245ede5 STILL FIRES — the runner still exits 75 and records
#       blocked, and the notice still names TCC and the denied path. The ask ADDS a
#       remedy; it must never become a substitute for the failure report.

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
DENIED="$WORK/denied"; mkdir -p "$DENIED/.planning"
chmod 000 "$DENIED"
DSTATUS="$WORK/denied-status.json"
DRC=0
"$RUNNER" --dream "$DREAM" --repo "$DENIED" --status "$DSTATUS" run --overnight \
  >"$WORK/denied.log" 2>&1 || DRC=$?
chmod 755 "$DENIED"

[ "$DRC" = 75 ] && ok "(10) runner STILL exits 75 on a denied repo — never a silent 0" \
  || bad "(10) runner exit regressed to $DRC"
grep -q '"result": "blocked"' "$DSTATUS" 2>/dev/null \
  && ok "(10) runner STILL records result=blocked" \
  || bad "(10) runner stopped recording the blocked status"
grep -qi 'BLOCKED' "$WORK/denied.log" \
  && ok "(10) runner STILL shouts into the dream log" \
  || bad "(10) runner went quiet"

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

echo "------------------------------"
if [ "$FAIL" -eq 0 ]; then
  printf "dream-permission: \033[32m%d passed\033[0m, 0 failed\n" "$PASS"
else
  printf "dream-permission: %d passed, \033[31m%d failed\033[0m\n" "$PASS" "$FAIL"
  exit 1
fi
