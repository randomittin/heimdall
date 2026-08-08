#!/usr/bin/env bash
# test/liveness-receipt.test.sh — acceptance for the LIVENESS RECEIPT (bin/heimdall-liveness).
#
# THE CLASS DEFECT THIS CLOSES
# ----------------------------
# The nightly /dream did not run for 26 days and NOTHING said so. The proximate bug was
# fixed (bin/heimdall-dream-permission classify(): a scheduled run wrote result=ok while
# macOS TCC had denied it the repo, so a COMPLETED run was read as a SUCCESSFUL one, and
# `needs-grant` — the only state that speaks — never fired). The CLASS question the fix
# left open is: what ELSE is silently not running?
#
# A self-silencing monitor is the worst failure this product can contain, so every
# scheduled/background subsystem now writes a receipt carrying BOTH facts:
#
#     COMPLETION IS NOT REACHABILITY.
#
# A receipt that records only "it ran" reproduces the original bug in every subsystem it
# touches. Both facts, or the receipt is worthless — that distinction is structural here,
# not advisory, and (C)/(E)/(G) below are the tests that make it so.
#
# WHAT THIS FILE PROVES — each one falsifiable, each one the shape of a real outage
# --------------------------------------------------------------------------------
#   A. FRESH READS OK           — a receipt that attempted, completed AND reached its
#      subject inside its cycle is the only shape that reads OK.
#   B. AGED GOES LOUD           — past N missed cycles it reads STALE and `check` exits
#      nonzero. N is per-subsystem, from the manifest, justified by its own period.
#   C. COMPLETED-BUT-UNREACHED  — THE DREAM BUG IN THE GENERAL CASE. A run that finished
#      and recorded reached=no is NON_VERIFIED immediately, not after N cycles: its
#      output cannot vouch for a subject it never touched.
#   D. MISSING IS NOT FINE      — no receipt at all reads NON_VERIFIED, never OK. This is
#      the 26-day silence in its purest costume: absent-and-therefore-fine.
#   E. UNRECORDED FAILS CLOSED  — a receipt written before the reachability field existed
#      is unverifiable, and an unverifiable gate is NON_VERIFIED, never OPEN.
#   F. THE MANIFEST IS THE TRUTH— `check` iterates the DECLARED subsystems, so one that
#      has NEVER written a receipt is reported. A directory scan would list nothing and
#      call it health.
#   G. THE PROBE OUTRANKS THE CLAIM — a caller asserting --reached yes over a subject it
#      demonstrably cannot read is recorded as NOT reached. Self-report is what failed
#      the first time; the probe runs in the caller's own process context, so it measures
#      the same denial the caller is subject to.
#   H. NO SUBJECT, NO CREDIT    — a subject that cannot be probed and carries no explicit
#      verdict records `unrecorded`, which reads NON_VERIFIED.
#   I. HERMETIC                 — the whole suite writes ZERO bytes into the real
#      ~/.heimdall. Asserted, not assumed.
#   J. STARTED-NEVER-FINISHED   — an attempt with no completion a full period later is
#      NON_VERIFIED. A job that dies mid-run is invisible to a completion-only receipt.
#   K. CLOCK SANITY             — a receipt stamped in the future is malformed, not
#      infinitely fresh. That is the trivial forgery that would defeat every staleness
#      check at once.
#   L. WIRED, NOT DEAD CODE     — every subsystem in the shipped manifest has a real
#      caller in the tree. A primitive nothing calls is the failure `heimdall-brief` just
#      demonstrated (built June, wired to nothing, empty store).
#
# The dream retrofit, `hmd doctor` and the statusline gate are proven in their own suites
# (liveness-wiring.test.sh) so this file stays about the primitive.

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
LIVE="$ROOT/bin/heimdall-liveness"

PASS=0
FAIL=0
ok()  { PASS=$((PASS+1)); printf "  \033[32mPASS\033[0m %s\n" "$1"; }
bad() { FAIL=$((FAIL+1)); printf "  \033[31mFAIL\033[0m %s\n" "$1"; }

[ -x "$LIVE" ] || { echo "FATAL: $LIVE not executable" >&2; exit 2; }

WORK="$(cd "$(mktemp -d -t "liveness-test.XXXXXX")" && pwd -P)"
cleanup() { chmod -R u+rwx "$WORK" 2>/dev/null || true; rm -rf "$WORK"; }
trap cleanup EXIT

# ── HERMETIC WORLD ───────────────────────────────────────────────────────────────
# Every write this suite can provoke is redirected under $WORK. The real ~/.heimdall is
# fingerprinted before the run and re-checked at the end (proof I), because "the tests
# relocate state" is exactly the kind of claim that rots silently.
REAL_HOME_DIR="${HEIMDALL_HOME:-$HOME/.heimdall}"
real_fingerprint() {
  [ -d "$REAL_HOME_DIR/liveness" ] || { printf 'absent'; return 0; }
  ls -1 "$REAL_HOME_DIR/liveness" 2>/dev/null | sort | tr '\n' ' '
}
REAL_BEFORE="$(real_fingerprint)"

export HEIMDALL_HOME="$WORK/home"
export HEIMDALL_LIVENESS_DIR="$WORK/home/liveness"
mkdir -p "$HEIMDALL_LIVENESS_DIR"

# ── the fixture manifest ─────────────────────────────────────────────────────────
# name|period_s|miss_threshold|scope|subject_label|remedy
MANIFEST="$WORK/manifest.conf"
cat > "$MANIFEST" <<'EOF'
# fixture — the shipped manifest is bin/lib/liveness-subsystems.conf
daily|86400|2|local|the repo it analyses|rerun-daily
weekly|604800|2|local|the git history|rerun-weekly
neverran|86400|2|local|a subject nothing has ever touched|install-it
EOF
export HEIMDALL_LIVENESS_MANIFEST="$MANIFEST"

SUBJECT="$WORK/subject"
mkdir -p "$SUBJECT"

# A clock we control. Everything below is anchored to T0 so no assertion depends on the
# wall clock — a staleness suite that is itself time-dependent is not a proof.
T0=1800000000

jfield() { # jfield <json> <key>   (jq: this suite runs in a terminal, the bin does not)
  printf '%s' "$1" | jq -r ".$2 // empty" 2>/dev/null
}

echo ""
echo "── liveness receipt ─────────────────────────────────────────────────────────"

# ── (A) a fresh, reaching receipt is the ONLY shape that reads OK ────────────────
HMD_LIVENESS_NOW=$T0 "$LIVE" complete --subsystem daily --subject "$SUBJECT" >/dev/null 2>&1
AJSON="$(HMD_LIVENESS_NOW=$T0 "$LIVE" read --subsystem daily --json 2>/dev/null)"
[ "$(jfield "$AJSON" state)" = "OK" ] \
  && ok "(A) attempted + completed + reached inside its cycle reads OK" \
  || bad "(A) a fresh reaching receipt did not read OK: $AJSON"

[ "$(jfield "$AJSON" last_reached)" = "$T0" ] \
  && ok "(A) the receipt carries the instant it demonstrably REACHED its subject" \
  || bad "(A) last_reached was $(jfield "$AJSON" last_reached), expected $T0"

[ "$(jfield "$AJSON" missed_cycles)" = "0" ] \
  && ok "(A) missed cycles are DERIVED from that instant (0 at T0)" \
  || bad "(A) missed_cycles was $(jfield "$AJSON" missed_cycles)"

# ── (B) aged past N cycles goes LOUD ─────────────────────────────────────────────
# N=2 at an 86400s period: one missed night is a closed laptop, two is a signal. The
# boundary is asserted from BOTH sides so an off-by-one cannot pass.
NEAR=$(( T0 + 86400 + 86399 ))          # 1 full cycle + change -> missed=1
BJSON="$(HMD_LIVENESS_NOW=$NEAR "$LIVE" read --subsystem daily --json 2>/dev/null)"
[ "$(jfield "$BJSON" state)" = "OK" ] && [ "$(jfield "$BJSON" missed_cycles)" = "1" ] \
  && ok "(B) one missed cycle is still OK — the threshold is N, not any gap at all" \
  || bad "(B) one missed cycle was not OK: $BJSON"

FAR=$(( T0 + 2 * 86400 ))               # exactly 2 cycles -> missed=2 -> LOUD
CJSON="$(HMD_LIVENESS_NOW=$FAR "$LIVE" read --subsystem daily --json 2>/dev/null)"
[ "$(jfield "$CJSON" state)" = "STALE" ] \
  && ok "(B) N missed cycles reads STALE — loud, at the exact declared boundary" \
  || bad "(B) at N missed cycles the state was $(jfield "$CJSON" state): $CJSON"

HMD_LIVENESS_NOW=$FAR "$LIVE" check --subsystem daily >/dev/null 2>&1
BRC=$?
[ "$BRC" != 0 ] \
  && ok "(B) and \`check\` EXITS NONZERO on it (rc=$BRC) — a gate, not a note" \
  || bad "(B) check exited 0 over a stale subsystem"

# ── (C) THE DREAM BUG, GENERALISED ───────────────────────────────────────────────
# A run that finished and could not reach its subject. Completion is not reachability:
# this is the exact shape that read as "granted" for 26 days.
UNREACHABLE="$WORK/gone"                # never created -> the probe genuinely fails
HMD_LIVENESS_NOW=$T0 "$LIVE" complete --subsystem weekly --subject "$UNREACHABLE" >/dev/null 2>&1
DJSON="$(HMD_LIVENESS_NOW=$T0 "$LIVE" read --subsystem weekly --json 2>/dev/null)"
[ "$(jfield "$DJSON" state)" = "NON_VERIFIED" ] \
  && ok "(C) completed-but-never-reached reads NON_VERIFIED — completion is not reachability" \
  || bad "(C) a run that never reached its subject read $(jfield "$DJSON" state): $DJSON"

[ "$(jfield "$DJSON" reason)" = "never-reached" ] \
  && ok "(C) the reason names the real cause, not a generic staleness verdict" \
  || bad "(C) reason was $(jfield "$DJSON" reason)"

# ...and it is IMMEDIATE. Waiting N cycles to speak would rebuild the 26-day silence.
HMD_LIVENESS_NOW=$T0 "$LIVE" check --subsystem weekly >/dev/null 2>&1
CRC=$?
[ "$CRC" != 0 ] \
  && ok "(C) it goes loud on the FIRST such run (rc=$CRC), not after N cycles" \
  || bad "(C) an unreached subject was tolerated for a whole cycle"

# A run that reached, then a later run that did NOT: last_reached must NOT advance, and
# the fresh completion must not launder the receipt back to OK.
HMD_LIVENESS_NOW=$T0 "$LIVE" complete --subsystem weekly --subject "$SUBJECT" >/dev/null 2>&1
LATER=$(( T0 + 3600 ))
HMD_LIVENESS_NOW=$LATER "$LIVE" complete --subsystem weekly --subject "$UNREACHABLE" >/dev/null 2>&1
EJSON="$(HMD_LIVENESS_NOW=$LATER "$LIVE" read --subsystem weekly --json 2>/dev/null)"
[ "$(jfield "$EJSON" last_complete)" = "$LATER" ] && [ "$(jfield "$EJSON" last_reached)" = "$T0" ] \
  && ok "(C) a later unreaching run advances last_complete but NOT last_reached" \
  || bad "(C) last_reached advanced on a run that never reached: $EJSON"

[ "$(jfield "$EJSON" state)" = "NON_VERIFIED" ] && [ "$(jfield "$EJSON" reason)" = "completed-unreachable" ] \
  && ok "(C) a FRESH completion over an unreachable subject is still NON_VERIFIED" \
  || bad "(C) a fresh completion laundered an unreachable subject to $(jfield "$EJSON" state): $EJSON"

# ── (D) a missing receipt is NON_VERIFIED, never OK ──────────────────────────────
FJSON="$(HMD_LIVENESS_NOW=$T0 "$LIVE" read --subsystem neverran --json 2>/dev/null)"
[ "$(jfield "$FJSON" state)" = "NON_VERIFIED" ] && [ "$(jfield "$FJSON" reason)" = "no-receipt" ] \
  && ok "(D) a subsystem that never wrote a receipt reads NON_VERIFIED, never absent-and-fine" \
  || bad "(D) a missing receipt read $(jfield "$FJSON" state)/$(jfield "$FJSON" reason): $FJSON"

# ── (E) a receipt predating the reachability field fails CLOSED ──────────────────
printf '{\n  "schema": 1,\n  "subsystem": "daily",\n  "last_attempt": %s,\n  "last_complete": %s,\n  "updated": %s\n}\n' \
  "$T0" "$T0" "$T0" > "$HEIMDALL_LIVENESS_DIR/daily.json"
grep -q 'reached' "$HEIMDALL_LIVENESS_DIR/daily.json" \
  && bad "(E) fixture still carries a reachability field — the unrecorded case is untested" \
  || ok "(E) fixture models a receipt written before reachability was recorded"
GJSON="$(HMD_LIVENESS_NOW=$T0 "$LIVE" read --subsystem daily --json 2>/dev/null)"
[ "$(jfield "$GJSON" state)" = "NON_VERIFIED" ] && [ "$(jfield "$GJSON" reason)" = "reachability-unrecorded" ] \
  && ok "(E) unrecorded reachability is NON_VERIFIED — an unverifiable gate is never OPEN" \
  || bad "(E) an unrecorded reachability was treated as $(jfield "$GJSON" state): $GJSON"

# ── (F) `check` iterates the MANIFEST, not the receipt directory ─────────────────
ALL="$(HMD_LIVENESS_NOW=$T0 "$LIVE" check --json 2>/dev/null)"
printf '%s' "$ALL" | jq -e '.subsystems | map(.subsystem) | index("neverran")' >/dev/null 2>&1 \
  && ok "(F) a DECLARED subsystem with no receipt is reported — a dir scan would show health" \
  || bad "(F) the never-run subsystem was missing from check: $ALL"

COUNT="$(printf '%s' "$ALL" | jq -r '.subsystems | length' 2>/dev/null)"
[ "$COUNT" = "3" ] \
  && ok "(F) every declared subsystem is evaluated (3/3)" \
  || bad "(F) check evaluated $COUNT subsystems, manifest declares 3"

# ── (G) the probe outranks the caller's claim ────────────────────────────────────
# Self-report is precisely what failed the first time. The probe runs in the caller's own
# process, so it is subject to the same denial the caller is — it can only ever make the
# verdict WORSE, never better.
HMD_LIVENESS_NOW=$T0 "$LIVE" complete --subsystem daily --subject "$UNREACHABLE" --reached yes >/dev/null 2>&1
HJSON="$(HMD_LIVENESS_NOW=$T0 "$LIVE" read --subsystem daily --json 2>/dev/null)"
[ "$(jfield "$HJSON" reached)" = "no" ] \
  && ok "(G) --reached yes over an unreadable subject is RECORDED AS NO — the probe wins" \
  || bad "(G) a self-reported 'yes' survived a failing probe: $HJSON"

# ...and the converse is NOT symmetric: a caller who knows it failed is believed even when
# the path is readable, because it can see failures the probe cannot.
HMD_LIVENESS_NOW=$T0 "$LIVE" complete --subsystem daily --subject "$SUBJECT" --reached no >/dev/null 2>&1
IJSON="$(HMD_LIVENESS_NOW=$T0 "$LIVE" read --subsystem daily --json 2>/dev/null)"
[ "$(jfield "$IJSON" reached)" = "no" ] \
  && ok "(G) --reached no is believed over a readable path — the probe never upgrades a verdict" \
  || bad "(G) a passing probe overrode the caller's own failure report: $IJSON"

# ── (H) an unprobeable subject with no verdict records `unrecorded` ──────────────
HMD_LIVENESS_NOW=$T0 "$LIVE" complete --subsystem weekly --subject "api.example.invalid" >/dev/null 2>&1
JJSON="$(HMD_LIVENESS_NOW=$T0 "$LIVE" read --subsystem weekly --json 2>/dev/null)"
[ "$(jfield "$JJSON" state)" = "NON_VERIFIED" ] && [ "$(jfield "$JJSON" reason)" = "reachability-unrecorded" ] \
  && ok "(H) a subject that cannot be probed earns no credit — NON_VERIFIED" \
  || bad "(H) an unprobeable subject read $(jfield "$JJSON" state)/$(jfield "$JJSON" reason): $JJSON"

# ── (J) started and never finished ───────────────────────────────────────────────
rm -f "$HEIMDALL_LIVENESS_DIR/daily.json"
HMD_LIVENESS_NOW=$T0 "$LIVE" attempt --subsystem daily --subject "$SUBJECT" >/dev/null 2>&1
KJSON="$(HMD_LIVENESS_NOW=$T0 "$LIVE" read --subsystem daily --json 2>/dev/null)"
[ "$(jfield "$KJSON" last_attempt)" = "$T0" ] \
  && ok "(J) \`attempt\` records the start on its own — the receipt carries all three facts" \
  || bad "(J) attempt did not record last_attempt: $KJSON"
[ "$(jfield "$KJSON" state)" = "NON_VERIFIED" ] \
  && ok "(J) an in-flight run is NOT yet OK — nothing has completed or reached" \
  || bad "(J) a bare attempt read $(jfield "$KJSON" state): $KJSON"

AFTER=$(( T0 + 86400 + 1 ))
LJSON="$(HMD_LIVENESS_NOW=$AFTER "$LIVE" read --subsystem daily --json 2>/dev/null)"
[ "$(jfield "$LJSON" reason)" = "attempted-never-completed" ] \
  && ok "(J) a full period later it names the crash: attempted-never-completed" \
  || bad "(J) a dead mid-run job reported $(jfield "$LJSON" reason): $LJSON"

# ── (K) a future timestamp is malformed, not infinitely fresh ────────────────────
FUTURE=$(( T0 + 999999 ))
printf '{\n  "schema": 1,\n  "subsystem": "daily",\n  "subject": "%s",\n  "last_attempt": %s,\n  "last_complete": %s,\n  "last_reached": %s,\n  "reached": "yes",\n  "updated": %s\n}\n' \
  "$SUBJECT" "$FUTURE" "$FUTURE" "$FUTURE" "$FUTURE" > "$HEIMDALL_LIVENESS_DIR/daily.json"
MJSON="$(HMD_LIVENESS_NOW=$T0 "$LIVE" read --subsystem daily --json 2>/dev/null)"
[ "$(jfield "$MJSON" state)" = "NON_VERIFIED" ] \
  && ok "(K) a receipt stamped in the future is NON_VERIFIED, not permanently fresh" \
  || bad "(K) a future-dated receipt read $(jfield "$MJSON" state): $MJSON"

# garbage in the file is not a health report either
printf 'not json at all\n' > "$HEIMDALL_LIVENESS_DIR/daily.json"
NJSON="$(HMD_LIVENESS_NOW=$T0 "$LIVE" read --subsystem daily --json 2>/dev/null)"
[ "$(jfield "$NJSON" state)" = "NON_VERIFIED" ] && [ "$(jfield "$NJSON" reason)" = "malformed" ] \
  && ok "(K) a corrupt receipt is NON_VERIFIED/malformed — never silently trusted" \
  || bad "(K) a corrupt receipt read $(jfield "$NJSON" state)/$(jfield "$NJSON" reason)"

# ── (L) the SHIPPED manifest is wired to real callers ────────────────────────────
# A primitive nothing calls is the failure heimdall-brief just demonstrated: built in
# June, wired to nothing, an empty store nobody noticed. Every declared subsystem must
# have a caller in the tree that records for it.
SHIPPED="$ROOT/bin/lib/liveness-subsystems.conf"
[ -f "$SHIPPED" ] \
  && ok "(L) the shipped manifest exists at bin/lib/liveness-subsystems.conf" \
  || bad "(L) no shipped manifest at $SHIPPED"

UNWIRED=""
if [ -f "$SHIPPED" ]; then
  while IFS='|' read -r NAME _rest; do
    case "$NAME" in ''|'#'*) continue ;; esac
    if ! grep -rq -- "--subsystem $NAME" "$ROOT/bin" "$ROOT/hooks" "$ROOT/sentinels" 2>/dev/null; then
      UNWIRED="$UNWIRED $NAME"
    fi
  done < "$SHIPPED"
fi
[ -z "$UNWIRED" ] \
  && ok "(L) every declared subsystem has a real caller — no dead manifest rows" \
  || bad "(L) declared but nothing records for it:$UNWIRED"

# ── (I) HERMETIC — zero records reached the real home ────────────────────────────
REAL_AFTER="$(real_fingerprint)"
[ "$REAL_BEFORE" = "$REAL_AFTER" ] \
  && ok "(I) the real $REAL_HOME_DIR/liveness is byte-for-byte untouched" \
  || bad "(I) this suite wrote into the REAL home: before[$REAL_BEFORE] after[$REAL_AFTER]"

echo ""
printf "  %s passed, %s failed\n" "$PASS" "$FAIL"
[ "$FAIL" = 0 ] || exit 1
exit 0
