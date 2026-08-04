#!/usr/bin/env bash
# module-preflight-wiring.test.sh — prove bin/lib/module_preflight.sh is actually
# WIRED into bin/heimdall-modules, and that the wiring can fail.
#
# WHAT THIS GUARDS. A preflight library that exists but is never called is worse
# than no preflight: it reads as a shipped safety net while every install still
# fails the old illegible way. So every assertion here drives the real binary
# through its real verbs and reads the real effect — never the library directly.
#
# THE GATE IS SCOPED, AND THAT IS THE POINT. `add` on an upstream module is a
# DECLARATION ("depend, do not clone. Nothing is vendored at add time"): it
# records the pin and never runs `installs_via.fetch`. So `add` refuses only on
# the checks that would falsify what it writes — pin, disk, platform — and the
# rest are reported with their remedies. `repair` is the verb that fetches, so
# `repair` gates on EVERY blocking check. W2/W3 pin both sides of that line.
#
#   W1  `add` runs preflight as a named pipeline step, before consent.
#   W2  A BLOCKING precondition makes `add` REFUSE, name the fix, and mutate
#       NOTHING — the state tree stays byte-identical.
#   W3  FALSIFIER FOR W2 — the same add SUCCEEDS once the precondition is met.
#       The refusal is therefore caused by the gate, not by a broken fixture.
#   W4  A non-blocking precondition does NOT refuse the add, and IS reported
#       with its remedy — a false refusal is how a gate teaches people to bypass it.
#   W5  `repair` gates on every blocking check, records the STAGE, and stays clean.
#   W6  `repair` is idempotent: healthy is a true no-op that changes nothing.
#   W7  `repair` honours an opt-out and does no work at all.
#   W8  `status` tells the three not-installed states APART: opted out ·
#       install failed (naming the stage) · not yet attempted.
#   W9  `pending` is the cheap decision `hmd update` makes: deferred yes,
#       opted-out no, installed no.
#  W10  DUAL-CLASS SURVIVES THE WIRING — a two-class module still runs BOTH
#       classes' invariants through the preflight-gated add. Dropping a class
#       does not error; it silently runs fewer checks. That silent narrowing is
#       the failure mode, so it is asserted against directly.
#
# Usage:  bash test/module-preflight-wiring.test.sh   (exit 0 = every guarantee holds)
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SELF_DIR/.." && pwd)"
MODS="$REPO/bin/heimdall-modules"

command -v jq >/dev/null 2>&1 || { echo "error: jq is required" >&2; exit 2; }

PASS=0; FAIL=0
ok()  { printf '  \033[32mPASS\033[0m %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAIL=$((FAIL+1)); }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

REG="$TMP/registry"
STATE="$TMP/state/modules"

# A preflight test must not depend on the internet to be meaningful — the
# library documents this switch for exactly that reason.
export HMD_PREFLIGHT_NO_NET=1

hmd() { "$MODS" --registry "$REG" --state "$STATE" "$@"; }

sha_file() { shasum -a 256 "$1" | awk '{print $1}'; }

# Distinguishes ABSENT from EMPTY: an add that leaves an empty directory behind
# has still left residue.
tree_sum() {
  [ -e "$1" ] || { printf 'ABSENT\n'; return 0; }
  ( cd "$1" && find . -mindepth 1 | LC_ALL=C sort | while IFS= read -r p; do
      if [ -d "$p" ]; then printf 'd %s\n' "$p"
      else printf 'f %s %s\n' "$p" "$(sha_file "$p")"
      fi
    done ) | shasum -a 256 | awk '{print $1}'
}

mkclass() { # <name> <consent_required> <requires_invariants JSON array>
  mkdir -p "$REG/_classes"
  jq -n --arg c "$1" --argjson consent "$2" --argjson inv "$3" \
    '{class:$c, version:"1", summary:"fixture class",
      why_this_class_exists:"fixture", consent_required:$consent,
      consent_rationale:"fixture rationale", requires_invariants:$inv}' \
    > "$REG/_classes/$1.json"
}

mkmodule() { # <name> <class JSON: string or array> [extra JSON merged over]
  local name="$1" class="$2" extra="${3:-}"
  [ -n "$extra" ] || extra='{}'
  mkdir -p "$REG/$name"
  printf 'fixture artifact payload for %s\n' "$name" > "$REG/$name/artifact.bin"
  jq -n --arg n "$name" --argjson c "$class" --arg sha "$(sha_file "$REG/$name/artifact.bin")" \
        --argjson extra "$extra" '
    { name:$n, description:("fixture module " + $n),
      upstream:("https://example.invalid/" + $n), license:"MIT",
      pinned_version:{version:"1.0.0", artifact:"artifact.bin", artifact_sha256:$sha},
      permission_class:$c,
      installs_via:{kind:"local", artifact_path:"artifact.bin"},
      wires:[{kind:"env", target:"FIXTURE_TARGET"}],
      invariants:{"module-owned":{command:"printf MODULE-OK", expect:"MODULE-OK"}},
      tier:"available",
      consent_text:("Fixture consent text for " + $n + ".")
    } * $extra' > "$REG/$name/manifest.json"
}

mkclass fx-open false '[
  {"id":"cheap-suite","description":"a class-owned suite check",
   "check":{"kind":"suite","command":"printf FIXTURE-SUITE-OK","expect":"FIXTURE-SUITE-OK","expect_exit":0}},
  {"id":"module-owned","description":"a module-owned check","check":{"kind":"manifest"}}]'
# A SECOND class with its OWN suite check. If only one class's invariants run,
# this check is the one that silently vanishes.
mkclass fx-codec false '[
  {"id":"codec-fidelity","description":"the codec class round-trip check",
   "check":{"kind":"suite","command":"printf CODEC-ROUND-TRIP-OK","expect":"CODEC-ROUND-TRIP-OK","expect_exit":0}}]'

mkmodule plain '"fx-open"'
STATE_PRE="$(tree_sum "$STATE")"

# ═════════════════════════════════════════════════════════════════════════════
echo
echo "W1 — \`add\` runs preflight as a named step, before consent"
OUT="$(hmd add plain --yes 2>&1)"; RC=$?
[ "$RC" -eq 0 ] && ok "the preflight-gated add still succeeds when preconditions hold" \
                || { bad "add failed (exit $RC)"; printf '%s\n' "$OUT" | tail -20; }
printf '%s' "$OUT" | grep -q '\[3/7\] preflight' \
  && ok "preflight is a named pipeline step, not a silent call" || bad "no preflight step in the add output"
printf '%s' "$OUT" | grep -q 'preflight: every precondition met' \
  && ok "the add reports what preflight concluded" || bad "preflight result never reported"
# Order matters: consenting to an install that cannot happen wastes the yes.
PF_LINE="$(printf '%s' "$OUT" | grep -n '\[3/7\] preflight' | cut -d: -f1)"
CN_LINE="$(printf '%s' "$OUT" | grep -n '\[4/7\] consent' | cut -d: -f1)"
[ -n "$PF_LINE" ] && [ -n "$CN_LINE" ] && [ "$PF_LINE" -lt "$CN_LINE" ] \
  && ok "preflight runs BEFORE consent" || bad "preflight did not precede consent"
hmd remove plain >/dev/null 2>&1
[ "$(tree_sum "$STATE")" = "$STATE_PRE" ] && ok "state clean after W1" || bad "W1 left residue"

echo
echo "W2 — a BLOCKING precondition REFUSES the add and mutates nothing"
# The disk floor is the library's own documented seam ("overridable so a test can
# pin both sides of the boundary"). Setting it beyond any real disk makes the
# `disk` check fail for real — no mocking, the same code path a full disk takes.
OUT="$(HMD_PREFLIGHT_DISK_FLOOR_MB=999999999 hmd add plain --yes 2>&1)"; RC=$?
[ "$RC" -ne 0 ] && ok "add REFUSES when a blocking precondition fails (exit $RC)" \
                || bad "add installed anyway despite a failing precondition"
printf '%s' "$OUT" | grep -qi 'precondition this install depends on is not met' \
  && ok "the refusal names the reason" || bad "refusal did not name a precondition"
printf '%s' "$OUT" | grep -q 'fix:' \
  && ok "the refusal carries a remediation command" || bad "no remedy offered"
printf '%s' "$OUT" | grep -qi 'nothing was installed and nothing was wired' \
  && ok "the refusal states nothing was installed" || bad "no such statement"
printf '%s' "$OUT" | grep -q 'hmd modules preflight plain' \
  && ok "the refusal points at the full report" || bad "no pointer to the full report"
[ ! -e "$STATE/plain" ] && ok "the refused module has no install dir" || bad "refused module left an install dir"
[ "$(tree_sum "$STATE")" = "$STATE_PRE" ] \
  && ok "a preflight refusal is byte-identical to never having run" \
  || bad "preflight refusal left a trace: $(tree_sum "$STATE") != $STATE_PRE"
# The gate must stop the pipeline BEFORE consent, not after.
printf '%s' "$OUT" | grep -q '\[4/7\] consent' \
  && bad "the add reached consent despite a blocking precondition" \
  || ok "the refusal stopped before consent was requested"

echo
echo "W3 — FALSIFIER FOR W2: the same add SUCCEEDS once the precondition is met"
OUT="$(HMD_PREFLIGHT_DISK_FLOOR_MB=1 hmd add plain --yes 2>&1)"; RC=$?
[ "$RC" -eq 0 ] \
  && ok "lowering the floor makes the identical add pass — the gate caused the refusal" \
  || { bad "add still failed with a satisfiable floor (exit $RC)"; printf '%s\n' "$OUT" | tail -20; }
[ -f "$STATE/plain/receipt.json" ] && ok "the satisfied add really installed" || bad "no receipt written"
hmd remove plain >/dev/null 2>&1
[ "$(tree_sum "$STATE")" = "$STATE_PRE" ] && ok "state clean after W3" || bad "W3 left residue"

echo
echo "W4 — a NON-blocking precondition is reported, not weaponised into a refusal"
# `path` fails when ~/.local/bin exists but is off PATH. An `add` never puts a
# binary there, so refusing for it would be a FALSE refusal. Drive that exact
# check by pointing bin_dir at a real directory that is definitely not on PATH.
NOPATH="$TMP/definitely-not-on-path"
mkdir -p "$NOPATH"
mkmodule advisory '"fx-open"' "$(jq -n --arg d "$NOPATH" '{preflight:{bin_dir:$d}}')"
OUT="$(hmd add advisory --yes 2>&1)"; RC=$?
[ "$RC" -eq 0 ] \
  && ok "a precondition the add never touches does NOT refuse the add" \
  || { bad "add refused for a non-blocking check (exit $RC)"; printf '%s\n' "$OUT" | tail -20; }
printf '%s' "$OUT" | grep -qi 'the PAYLOAD needs are not met yet' \
  && ok "the unmet check is still surfaced, not swallowed" || bad "the unmet check was silently dropped"
printf '%s' "$OUT" | grep -q 'hmd modules repair advisory' \
  && ok "the report names the verb that DOES need the fix" || bad "no pointer to repair"
hmd remove advisory >/dev/null 2>&1

echo
echo "W5 — \`repair\` gates on EVERY blocking check and records the stage"
OUT="$(HMD_PREFLIGHT_DISK_FLOOR_MB=999999999 hmd repair plain 2>&1)"; RC=$?
[ "$RC" -ne 0 ] && ok "repair refuses when a precondition blocks (exit $RC)" \
                || bad "repair proceeded despite a blocking precondition"
printf '%s' "$OUT" | grep -qi 'blocking failure' \
  && ok "repair renders the full preflight report" || bad "no preflight report from repair"
[ "$(jq -r '.stage' "$STATE/.modstate/plain/failure.json" 2>/dev/null)" = "preflight" ] \
  && ok "the failure record names the STAGE that failed" || bad "no stage recorded"
[ ! -e "$STATE/plain/receipt.json" ] && ok "a blocked repair installed nothing" || bad "blocked repair still installed"
[ "$(hmd --json status plain 2>/dev/null | jq -r '.state')" = "failed" ] \
  && ok "status reads the failure back as \"failed\"" || bad "status did not read the failure"

echo
echo "W6 — \`repair\` is idempotent: healthy is a true no-op"
hmd add plain --yes >/dev/null 2>&1
SUM_BEFORE="$(tree_sum "$STATE/plain")"
J="$(hmd --json repair plain 2>/dev/null)"
[ "$(printf '%s' "$J" | jq -r '.changed')" = "false" ] \
  && ok "repair on a healthy module changes nothing" || bad "repair churned a healthy module: $J"
[ "$(printf '%s' "$J" | jq -r '.state')" = "installed" ] \
  && ok "repair reports the module as installed" || bad "wrong state: $J"
[ "$(tree_sum "$STATE/plain")" = "$SUM_BEFORE" ] \
  && ok "the install directory is byte-identical after a no-op repair" || bad "no-op repair mutated the install"
# A resolved failure must stop reading like an unresolved one.
[ ! -e "$STATE/.modstate/plain/failure.json" ] \
  && ok "a successful repair clears the stale failure record" || bad "stale failure record survived"

echo
echo "W7 — an opt-out is final: \`repair\` honours it and does no work"
hmd remove plain >/dev/null 2>&1
hmd optout plain >/dev/null 2>&1
[ -f "$STATE/.modstate/plain/optout.json" ] && ok "optout records the decision" || bad "optout wrote nothing"
J="$(hmd --json repair plain 2>/dev/null)"
[ "$(printf '%s' "$J" | jq -r '.state')" = "opted-out" ] \
  && ok "repair reports the opt-out instead of reinstalling" || bad "repair ignored the opt-out: $J"
[ "$(printf '%s' "$J" | jq -r '.changed')" = "false" ] && ok "an opted-out repair changes nothing" || bad "opted-out repair did work"
[ ! -e "$STATE/plain/receipt.json" ] && ok "the opted-out module was NOT installed" || bad "opt-out was overridden"
# The env switch is the second honoured source — an operator sets it directly.
[ "$(HMD_MODULE_OPTOUT=advisory hmd --json status advisory 2>/dev/null | jq -r '.state')" = "opted-out" ] \
  && ok "HMD_MODULE_OPTOUT is honoured as an opt-out source" || bad "env opt-out ignored"

echo
echo "W8 — \`status\` tells the three not-installed states APART"
S_OPT="$(hmd status plain 2>&1)"
printf '%s' "$S_OPT" | grep -qi 'OPTED OUT' && ok "opted out reads as OPTED OUT" || bad "opt-out state not distinguished"
printf '%s' "$S_OPT" | grep -q 'hmd modules optin plain' && ok "the opt-out names how to undo it" || bad "no undo offered"
hmd optin plain >/dev/null 2>&1
[ "$(hmd --json status plain 2>/dev/null | jq -r '.state')" = "not-attempted" ] \
  && ok "optin returns the module to not-attempted" || bad "optin did not clear the opt-out"

S_NEW="$(hmd status plain 2>&1)"
printf '%s' "$S_NEW" | grep -qi 'NOT ATTEMPTED' && ok "never-tried reads as NOT ATTEMPTED" || bad "not-attempted state not distinguished"

hmd defer plain >/dev/null 2>&1
S_DEF="$(hmd status plain 2>&1)"
printf '%s' "$S_DEF" | grep -qi 'NOT YET ATTEMPTED' && ok "deferred reads as NOT YET ATTEMPTED" || bad "deferred state not distinguished"
[ "$(hmd --json status plain 2>/dev/null | jq -r '.state')" = "deferred" ] \
  && ok "the JSON state is \"deferred\"" || bad "wrong JSON state for deferred"

HMD_PREFLIGHT_DISK_FLOOR_MB=999999999 hmd repair plain >/dev/null 2>&1
S_FAIL="$(hmd status plain 2>&1)"
printf '%s' "$S_FAIL" | grep -qi 'INSTALL FAILED at stage: preflight' \
  && ok "a failed install reads as INSTALL FAILED and NAMES the stage" || bad "failed state did not name the stage"
printf '%s' "$S_FAIL" | grep -q 'hmd modules repair plain' && ok "the failure offers the retry command" || bad "no retry offered"
# The three must be genuinely different renderings, not one message reworded.
[ "$S_OPT" != "$S_DEF" ] && [ "$S_DEF" != "$S_FAIL" ] && [ "$S_OPT" != "$S_FAIL" ] \
  && ok "all three not-installed states render differently" || bad "two states render identically"

echo
echo "W9 — \`pending\` is the cheap decision: deferred yes, opted-out no, installed no"
hmd optout advisory >/dev/null 2>&1
HMD_MODULE_RETRY_INTERVAL=0 hmd pending 2>/dev/null | grep -qx 'plain' \
  && ok "a module wanting a retry is pending" || bad "pending missed a retryable module"
hmd pending 2>/dev/null | grep -qx 'advisory' \
  && bad "pending offered an opted-out module" || ok "pending filters out an opted-out module"
# The backoff is what stops a permanently-broken module becoming a retry storm.
hmd pending 2>/dev/null | grep -qx 'plain' \
  && bad "a just-failed module was offered for immediate retry" || ok "the retry backoff suppresses an immediate retry"
hmd optin advisory >/dev/null 2>&1
hmd add advisory --yes >/dev/null 2>&1
hmd pending 2>/dev/null | grep -qx 'advisory' \
  && bad "pending offered an installed module" || ok "pending filters out an installed module"
hmd remove advisory >/dev/null 2>&1

echo
echo "W10 — DUAL-CLASS SURVIVES THE WIRING (the union still runs)"
# The failure mode is SILENT: dropping a class does not error, it just stops
# running that class's checks. So the assertion is on WHICH ids ran, never on
# the exit code.
mkmodule dual '["fx-open","fx-codec"]'
DST="$TMP/state/dual"
OUT="$("$MODS" --registry "$REG" --state "$DST" add dual --yes 2>&1)"; RC=$?
[ "$RC" -eq 0 ] && ok "a dual-class module installs through the preflight-gated add" \
                || { bad "dual-class add failed (exit $RC)"; printf '%s\n' "$OUT" | tail -20; }
DINV="$DST/dual/invariants.json"
RAN="$(jq -r '[.[].id] | sort | join(",")' "$DINV" 2>/dev/null || echo "")"
[ "$RAN" = "cheap-suite,codec-fidelity,module-owned" ] \
  && ok "BOTH classes' invariants ran through the wiring (union: $RAN)" \
  || bad "the union did not run — got: $RAN"
jq -e '[.[] | select(.class=="fx-codec")] | length == 1' "$DINV" >/dev/null 2>&1 \
  && ok "the second class's check is attributed to it in the receipt" || bad "fx-codec check missing or unattributed"
jq -e 'all(.[]; .passed)' "$DINV" >/dev/null 2>&1 \
  && ok "every invariant in the union passed" || bad "an invariant in the union failed"
CLASSES="$(jq -r '.permission_classes | sort | join(",")' "$DST/dual/receipt.json" 2>/dev/null || echo "")"
[ "$CLASSES" = "fx-codec,fx-open" ] \
  && ok "the receipt still records BOTH permission_classes" || bad "receipt lost a class: $CLASSES"

# THE SILENT-NARROWING FALSIFIER. Drop one class and prove the loss is real:
# the add STILL exits 0 and simply runs fewer checks. If this arm ever fails,
# the assertion above is a false green.
mkmodule dual '"fx-open"'
NST="$TMP/state/narrowed"
"$MODS" --registry "$REG" --state "$NST" add dual --yes >/dev/null 2>&1; NRC=$?
NRAN="$(jq -r '[.[].id] | sort | join(",")' "$NST/dual/invariants.json" 2>/dev/null || echo "")"
[ "$NRC" -eq 0 ] && [ "$NRAN" = "cheap-suite,module-owned" ] \
  && ok "dropping a class does NOT error — it silently runs fewer checks (exit 0, ran: $NRAN)" \
  || bad "the narrowing arm did not behave as documented (exit $NRC, ran: $NRAN)"
printf '%s' "$NRAN" | grep -q 'codec-fidelity' \
  && bad "the dropped class's check somehow still ran" \
  || ok "codec-fidelity STOPPED RUNNING — so W10's union assertion has real teeth"

# ═════════════════════════════════════════════════════════════════════════════
echo
echo "--------------------------------------------------------------------"
printf 'module-preflight-wiring: %s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
