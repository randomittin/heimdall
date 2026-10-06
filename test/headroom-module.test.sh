#!/usr/bin/env bash
#
# headroom-module.test.sh — acceptance for modules/headroom/manifest.json and the
# DUAL-CLASS support in bin/heimdall-modules that the manifest needs.
#
# THE PROPERTY THIS FILE EXISTS TO PROVE. Headroom claims TWO permission classes —
# it sits on the wire (traffic-proxy) and it encodes what hmd writes to disk
# (storage-codec) — and BOTH classes' invariants actually run. Declaring only one
# would not fail loudly; it would quietly skip the other class's checks and every
# green after that would be worth less than it looked. So H5 does exactly that
# mutation and proves a check DISAPPEARS, which is the whole reason the dual class
# is not cosmetic.
#
# THIS SUITE OWNS ITS STATE ROOTS; THE MACHINE'S IS NONE OF ITS BUSINESS.
# H1 used to assert "nothing is installed" against hmd's CANONICAL state root
# ($PLUGIN_DIR/.heimdall/modules) — a directory whose contents are simply whatever
# the operator installed. That made five assertions here statements about the
# developer's machine, and they went RED the day the owner ran `hmd modules add
# headroom` for real. Headroom is `default_included: true`, so HAVING it is the
# normal state for everyone: a suite that only passes on machines that never
# adopted the feature is worthless exactly when it matters. Every list/status
# assertion below therefore runs against a scratch --state this file creates.
#
# THIS SUITE OWNS ITS CONTROL PLANE, TOO. H1b, H3, H5 and H6's green arm drive the
# REAL manifest through `add`, and its traffic-proxy `no-signed-traffic-routing`
# invariant curls $HEIMDALL_DEFAULT_CP_URL/readyz and FAILS CLOSED on anything but
# 200. Left at its baked-in default that is the LIVE production control plane, so
# a dozen assertions here were statements about the internet: green only while it
# answered, and red (add failed, no invariant record, the dropped-class arm never
# completed, the restored manifest still failed) the moment it did not — or when
# the ambient env pinned the default at a dead port, which test/lib/net-default-
# guard.sh does on purpose for the presence corpus. The suite now serves /readyz
# itself from a loopback stand-in (test/lib/hermetic-cp.sh, shared with
# omniroute-module and module-consent-waiver). The manifest and the engine are
# untouched, and H3b proves the add still FAILS CLOSED when that control plane is
# unreachable, so supplying a reachable one is not a weakening.
#
# THE ABSENCE ASSERTIONS ARE KEPT, NOT DELETED — they are a real property. Install
# can fail (no uv, no network, wrong Python) and an operator can decline outright,
# so every invariant the manifest ships has to be green with the library absent; a
# module whose checks only pass when it is present cannot be honestly shipped in a
# default set. They are simply pointed at a root where the module is genuinely
# absent, which this file controls. And they are now paired with the PRESENT arm
# (H1b), which is both the case an operator is actually in and the falsifier that
# stops "not installed" from being a constant this suite would happily accept.
#
# WHY THE MUTATIONS RUN AGAINST A COPY. Every corrupt-the-manifest arm builds a
# temp registry from a byte-identical copy of the real one (asserted in H0), so an
# interrupted run can never leave a mutated manifest in the tree. The copy is the
# same bytes, so the proof is the same proof.
#
# Guarantees proved:
#   CP  the control plane the add path probes is a loopback stand-in this file
#       owns, and it is a real probe target (200 on /readyz, 404 everywhere else).
#   H0  the manifest is valid JSON, covers the schema, and the temp copy the
#       mutation arms use is byte-identical to the shipped file.
#   H1  `hmd modules` lists headroom as AVAILABLE, and against a state root where
#       it is genuinely absent, list/status are honest about that absence.
#   H1b the same surfaces against a root this file really installs into are honest
#       about PRESENCE — the falsifier that proves H1 reads state, not a constant.
#   H2  permission_class is DUAL, and both named classes exist in the registry.
#   H3  the add path runs BOTH classes' invariants with the module wired, and the
#       recorded evidence proves the judgment falsifier really ran at 25/0 —
#       twice, once for each class that consumes it.
#   H3b FALSIFIER FOR THE STAND-IN — the SAME add with ONLY the control plane
#       unreachable is REFUSED, names the invariant it could not verify, and
#       leaves no receipt: an unreachable check fails closed, it never passes.
#   H4  the storage-codec invariants are wired to the codec seam and the
#       traffic-proxy ones to the gate falsifier, demonstrated WITHOUT installing
#       Headroom.
#   H5  FALSIFIER FOR THE DUAL CLASS — dropping `storage-codec` from the manifest
#       makes round-trip-fidelity STOP RUNNING. The check that vanishes is what
#       proves the second class was load-bearing.
#   H6  FALSIFIER FOR COVERAGE — removing a required invariant's command makes the
#       add REFUSE and name the uncovered id; restoring it goes green again.
#   H7  a bad or missing pin is REFUSED.
#   H8  a consent-required class with no consent_text is REFUSED.
#   H9  tier is `available`, and `suggested` is UNREACHABLE without
#       tier_evidence.receipt — the A/B has not run.
#   H10 default_included is a boolean distribution fact, kept separate from tier,
#       and it does not waive the disclosure text.
#   H11 DEPEND, DON'T CLONE — the module directory holds a manifest and nothing
#       else, and no Headroom source is vendored anywhere in the tree. The verdict
#       is taken from a candidate directory's CONTENTS, never its path, and H11b
#       proves that rule still fires on a vendoring hidden in an excluded shape.
#   H12 CP / enroll / signed traffic is scrubbed of LOCAL REWRITERS — and is NOT
#       blanket-bypassed, because a corporate CONNECT proxy must keep working.
#
# Usage:  bash test/headroom-module.test.sh   (exit 0 = every guarantee holds)
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SELF_DIR/.." && pwd)"
MODS="$REPO/bin/heimdall-modules"
REG="$REPO/modules"
MANIFEST="$REG/headroom/manifest.json"

command -v jq >/dev/null 2>&1 || { echo "error: jq is required" >&2; exit 2; }
cd "$REPO" || exit 2

PASS=0; FAIL=0
ok()  { printf '  \033[32mPASS\033[0m %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAIL=$((FAIL+1)); }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# THE SAME RULE AS THE STATE ROOT ABOVE, APPLIED TO FREE SPACE. hmd's generic
# preflight floor is 4096 MB, sized for what a REAL Headroom install costs
# (Rust + ONNX + weights clears a gigabyte on its own). H1b and H3 install into
# a scratch --state root under $TMP, so that floor is measuring the developer's
# disk and nothing this suite is about: on a machine sitting at ~2 GB free every
# add-path assertion here goes RED with `refused: ... disk: at least 4096 MB
# free`, which is a statement about the laptop, not about the manifest. Pinned
# low so the add path is what gets judged. The library documents this override
# ("overridable so a test can pin both sides of the boundary"), and the floor's
# OWN behaviour is proven — on both sides, with explicit per-command values — in
# test/module-preflight-wiring.test.sh, which is where that assertion belongs.
export HMD_PREFLIGHT_DISK_FLOOR_MB=1

# THE SAME RULE, APPLIED TO THE NETWORK — see "THIS SUITE OWNS ITS CONTROL PLANE"
# in the header. Started before any add runs, and verified (CP section) before any
# add result is read as a statement about the manifest.
# shellcheck source=lib/hermetic-cp.sh disable=SC1091  # the default run never opens sourced files; source= is for -x -P SCRIPTDIR
. "$SELF_DIR/lib/hermetic-cp.sh"
hermetic_cp_start "$TMP" || exit 2
hermetic_cp_selfcheck

sha_file() { shasum -a 256 "$1" | awk '{print $1}'; }

# A temp registry holding the REAL class contracts and a byte-identical copy of
# the real manifest. Mutations happen here and never in the tree.
MREG="$TMP/registry"
mkdir -p "$MREG/_classes" "$MREG/headroom"
cp "$REG"/_classes/*.json "$MREG/_classes/"
cp "$MANIFEST" "$MREG/headroom/manifest.json"

# add against the temp registry, with consent granted non-interactively.
add_mut() { "$MODS" --registry "$MREG" --state "$TMP/state/$1" add headroom --yes 2>&1; }
# Reset the mutated manifest back to the shipped bytes.
restore() { cp "$MANIFEST" "$MREG/headroom/manifest.json"; }
# Apply a jq filter to the temp manifest.
mutate() {
  jq "$1" "$MREG/headroom/manifest.json" > "$MREG/headroom/m.tmp" \
    && mv "$MREG/headroom/m.tmp" "$MREG/headroom/manifest.json"
}

# Two state roots this file owns outright, against the REAL registry. `list` and
# `status` with no --state read hmd's canonical root, so every install-state
# assertion gets an explicit one instead: nothing is ever added to ABSENT_STATE,
# and H1b really does add the module to PRESENT_STATE. Both cases then hold on any
# machine, adopted or not.
ABSENT_STATE="$TMP/state/absent"
PRESENT_STATE="$TMP/state/present"
mkdir -p "$ABSENT_STATE"
hmd_absent()  { "$MODS" --state "$ABSENT_STATE"  "$@"; }
hmd_present() { "$MODS" --state "$PRESENT_STATE" "$@"; }

echo
echo "H0 — the manifest is valid and the mutation copy is byte-identical"
if jq -e . "$MANIFEST" >/dev/null 2>&1; then
  ok "manifest is valid JSON"
else
  bad "manifest is not valid JSON"
fi
if [ "$(sha_file "$MANIFEST")" = "$(sha_file "$MREG/headroom/manifest.json")" ]; then
  ok "the mutation copy is byte-identical to the shipped manifest"
else
  bad "mutation copy diverged from the shipped manifest"
fi
for f in name description upstream license pinned_version permission_class \
         installs_via wires invariants tier consent_text; do
  if jq -e --arg f "$f" 'has($f)' "$MANIFEST" >/dev/null 2>&1; then
    ok "manifest carries \`$f\`"
  else
    bad "manifest is missing \`$f\`"
  fi
done
if [ "$(jq -r '.name' "$MANIFEST")" = "headroom" ]; then
  ok "name matches the module directory"
else
  bad "name/directory mismatch"
fi
if [ "$(jq -r '.license' "$MANIFEST")" = "Apache-2.0" ]; then
  ok "license is Apache-2.0"
else
  bad "unexpected license"
fi
if jq -e '.pinned_version.artifact_sha256 | test("^[0-9a-f]{64}$")' "$MANIFEST" >/dev/null 2>&1; then
  ok "the pin carries a 64-hex artifact digest"
else
  bad "pin digest is not 64 lowercase hex"
fi
if [ "$(jq -r '.installs_via.kind' "$MANIFEST")" = "upstream" ]; then
  ok "installs_via is upstream — depend, don't clone"
else
  bad "installs_via is not upstream"
fi
if jq -e '.installs_via.fetch | test("uv tool install")' "$MANIFEST" >/dev/null 2>&1; then
  ok "the fetch command is the recorded uv install line"
else
  bad "fetch command is not the uv line"
fi

echo
echo "H1 — listed as AVAILABLE, and honest that it is NOT installed"
# Against ABSENT_STATE: a state root this file created and never added to, so
# "nothing is installed" is a fact the suite established rather than one it
# inherited from whoever ran hmd on this machine last.
LIST="$(hmd_absent list 2>&1)"
if grep -q 'headroom' <<<"$LIST"; then
  ok "\`hmd modules\` lists headroom"
else
  bad "headroom is not listed"
fi
if grep -qE 'headroom +available' <<<"$LIST"; then
  ok "it is listed at tier available"
else
  bad "headroom is not listed as available"
fi
if grep -q 'Installed: none' <<<"$LIST"; then
  ok "nothing is installed — the base install ships zero payloads"
else
  bad "something is reported installed"
fi
JLIST="$(hmd_absent --json list 2>/dev/null)"
if [ "$(printf '%s' "$JLIST" | jq -r '.installed_count')" = "0" ]; then
  ok "json list agrees: installed_count is 0"
else
  bad "json list reports an install"
fi
if [ "$(printf '%s' "$JLIST" | jq -r '.available[] | select(.name=="headroom") | .tier')" = "available" ]; then
  ok "json list reports headroom at tier available"
else
  bad "json tier is wrong"
fi
STATUS="$(hmd_absent status headroom 2>&1)"
if grep -q 'not installed' <<<"$STATUS"; then
  ok "\`status headroom\` is honest that it is absent"
else
  bad "status is not honest about absence"
fi
if [ "$(hmd_absent --json status headroom 2>/dev/null | jq -r '.installed')" = "false" ]; then
  ok "json status reports installed:false"
else
  bad "json status is not honest"
fi
# NOT a state-root fact — an IMPORT-PATH one, and it is why the absent path stays
# the live case even on a machine that has adopted the module. The sanctioned
# install is `uv tool install`, which puts headroom-ai in an isolated uv tool venv
# that hmd's python3 cannot see, so `import headroom` fails whether or not the
# module is added and the seam must stay on the plain backend. Asserting the
# REASON as well as the verdict is what stops a seam that has silently stopped
# looking from reading as a seam that looked and found nothing.
CODEC="$(python3 "$REPO/bin/lib/memory_codec.py" status 2>&1)"
if grep -q 'available: no' <<<"$CODEC"; then
  ok "the codec seam is on the plain backend — the uv-tool install never reaches hmd's import path"
else
  bad "the codec seam claims a backend hmd cannot import"
fi
if grep -q 'not importable' <<<"$CODEC"; then
  ok "…and it NAMES the reason: headroom is not importable from hmd's interpreter"
else
  bad "the seam reports plain without saying headroom is unimportable"
fi

echo
echo "H1b — and honest about PRESENCE, against a root this file really installs into"
# THE FALSIFIER FOR H1. Identical surfaces, a state root where the module is
# genuinely installed, opposite answers. Without this arm, every "not installed"
# above would pass just as happily against a tool that printed the words
# unconditionally. It is also the case an operator is actually in: headroom is
# default_included, so PRESENT is the normal state and deserves its own honesty
# assertions rather than being the case nobody checked.
PIN="$(jq -r '.pinned_version.version' "$MANIFEST")"
PADD="$(hmd_present add headroom --yes 2>&1)"; PRC=$?
if [ "$PRC" -eq 0 ]; then
  ok "the module installs into a state root the suite owns (exit 0)"
else
  bad "add into the scratch present root failed (exit $PRC)"
  printf '%s\n' "$PADD" | tail -15
fi
PLIST="$(hmd_present list 2>&1 | tr -s ' ')"
if grep -q 'Installed: none' <<<"$PLIST"; then
  bad "list still reports 'Installed: none' with the module installed"
else
  ok "list stops claiming an empty install set once the module is there"
fi
if grep -qF "headroom $PIN" <<<"$PLIST"; then
  ok "list names headroom at the manifest pin ($PIN)"
else
  bad "list does not report the installed pin"
fi
PJLIST="$(hmd_present --json list 2>/dev/null)"
if [ "$(printf '%s' "$PJLIST" | jq -r '.installed_count')" = "1" ]; then
  ok "json list agrees: installed_count is 1"
else
  bad "json list did not count the install"
fi
if [ "$(printf '%s' "$PJLIST" | jq -r '[.installed[] | select(.name=="headroom")] | length')" = "1" ]; then
  ok "json list names headroom under installed"
else
  bad "json list lost the installed module"
fi
PSTATUS="$(hmd_present status headroom 2>&1 | tr -s ' ')"
if grep -q 'not installed' <<<"$PSTATUS"; then
  bad "status still claims absence with the module installed"
else
  ok "\`status headroom\` is honest about PRESENCE — it stops claiming absence"
fi
if grep -qF "pin: $PIN" <<<"$PSTATUS"; then
  ok "status reports the pin it installed"
else
  bad "status does not report the installed pin"
fi
if [ "$(hmd_present --json status headroom 2>/dev/null | jq -r '.installed')" = "true" ]; then
  ok "json status reports installed:true"
else
  bad "json status hides the install"
fi
hmd_present remove headroom >/dev/null 2>&1
if [ "$(hmd_present --json status headroom 2>/dev/null | jq -r '.installed')" = "false" ]; then
  ok "…and back to installed:false after remove — the readout TRACKS state, it is not a constant"
else
  bad "status still reports installed after remove"
fi

echo
echo "H2 — permission_class is DUAL and both contracts exist"
if [ "$(jq -r '.permission_class | type' "$MANIFEST")" = "array" ]; then
  ok "permission_class is a list, not a single class"
else
  bad "permission_class is not a list"
fi
for c in traffic-proxy storage-codec; do
  if jq -e --arg c "$c" '.permission_class | index($c) != null' "$MANIFEST" >/dev/null 2>&1; then
    ok "declares the $c class"
  else
    bad "does not declare $c"
  fi
  if [ -f "$REG/_classes/$c.json" ]; then
    ok "the $c contract exists in the registry"
  else
    bad "no contract for $c"
  fi
done

echo
echo "H3 — the add path runs BOTH classes' invariants, module WIRED"
ST="$TMP/state/real"
OUT="$("$MODS" --state "$ST" add headroom --yes 2>&1)"; RC=$?
if [ "$RC" -eq 0 ]; then
  ok "add succeeds against the real dual-class contract"
else
  bad "add failed (exit $RC)"
  printf '%s\n' "$OUT" | tail -20
fi
INV="$ST/headroom/invariants.json"
if [ -f "$INV" ]; then
  if [ "$(jq -r 'length' "$INV")" = "6" ]; then
    ok "all six invariants across both classes ran"
  else
    bad "expected 6 invariants, got $(jq -r 'length' "$INV")"
  fi
  if [ "$(jq -r '[.[] | select(.passed)] | length' "$INV")" = "6" ]; then
    ok "all six passed with the codec library NOT importable"
  else
    bad "not all six passed"
  fi
  if [ "$(jq -r '[.[] | select(.class=="traffic-proxy")] | length' "$INV")" = "3" ]; then
    ok "three of them are attributed to traffic-proxy"
  else
    bad "traffic-proxy count wrong"
  fi
  if [ "$(jq -r '[.[] | select(.class=="storage-codec")] | length' "$INV")" = "3" ]; then
    ok "three of them are attributed to storage-codec"
  else
    bad "storage-codec count wrong"
  fi
  # The evidence, not the claim: the falsifier's own 25/0 line must appear in the
  # recorded output of BOTH class-owned suite checks.
  if jq -r '.[] | select(.id=="gates-read-raw") | .output_tail' "$INV" | grep -q '25 passed, 0 failed'; then
    ok "gates-read-raw really ran the judgment falsifier at 25/0"
  else
    bad "gates-read-raw output has no 25/0 line"
  fi
  if jq -r '.[] | select(.id=="never-touches-judgment-inputs") | .output_tail' "$INV" \
    | grep -q '25 passed, 0 failed'; then
    ok "never-touches-judgment-inputs ran the same falsifier at 25/0"
  else
    bad "never-touches-judgment-inputs output has no 25/0 line"
  fi
  if [ -f "$ST/headroom/wired.json" ]; then
    ok "the module was WIRED before the invariants ran"
  else
    bad "module was not wired"
  fi
  if [ "$(jq -r '.permission_classes | length' "$ST/headroom/receipt.json")" = "2" ]; then
    ok "the receipt records BOTH classes"
  else
    bad "receipt lost a class"
  fi
  if [ "$(jq -r '.default_included' "$ST/headroom/receipt.json")" = "true" ]; then
    ok "the receipt records default_included"
  else
    bad "receipt lost default_included"
  fi
else
  bad "no invariant record from the real add"
fi
"$MODS" --state "$ST" remove headroom >/dev/null 2>&1

echo
echo "H3b — FALSIFIER FOR THE STAND-IN: the SAME add with the control plane unreachable is REFUSED"
# H3 is green against a control plane this file supplies. This is what keeps that from
# reading as a weakening: ONE difference from H3 — the control plane the traffic-proxy
# no-signed-traffic-routing invariant probes is a loopback port nothing listens on —
# and the add must be REFUSED and unwound. An unreachable check fails closed; it never
# passes (also proved on its own in test/cp-signed-no-rewriting-proxy.test.sh 4.6).
NST="$TMP/state/cp-down"
NOUT="$(env HEIMDALL_DEFAULT_CP_URL="$(hermetic_cp_dead_url)" "$MODS" --state "$NST" add headroom --yes 2>&1)"; NRC=$?
if [ "$NRC" -ne 0 ]; then
  ok "RED ARM: the SAME add is REFUSED when the control plane is unreachable (exit $NRC)"
else
  bad "add succeeded with an unreachable control plane — an unverifiable invariant PASSED"
fi
if grep -q 'FAILED INVARIANT: no-signed-traffic-routing' <<<"$NOUT"; then
  ok "the refusal names the invariant that could not be verified"
else
  bad "the refusal did not name no-signed-traffic-routing: $(printf '%s\n' "$NOUT" | tail -8)"
fi
if [ ! -f "$NST/headroom/receipt.json" ]; then
  ok "nothing was left installed after the fail-closed refusal"
else
  bad "a refused add left a receipt"
fi

echo
echo "H4 — the invariants are wired to the repo's real falsifiers"
CTP="$REG/_classes/traffic-proxy.json"
CSC="$REG/_classes/storage-codec.json"
if jq -e '[.requires_invariants[] | select(.check.kind=="suite") | .check.command]
       | any(test("gate-judgment-uncompressed"))' "$CTP" >/dev/null 2>&1; then
  ok "traffic-proxy consumes test/gate-judgment-uncompressed.test.sh"
else
  bad "traffic-proxy is not wired to the gate falsifier"
fi
if jq -e '[.requires_invariants[] | select(.check.kind=="suite") | .check.command]
       | any(test("gate-judgment-uncompressed"))' "$CSC" >/dev/null 2>&1; then
  ok "storage-codec consumes the same falsifier"
else
  bad "storage-codec is not wired to the gate falsifier"
fi
if jq -e '.invariants["round-trip-fidelity"].command | test("memory_codec")' "$MANIFEST" >/dev/null 2>&1; then
  ok "round-trip-fidelity drives bin/lib/memory_codec.py"
else
  bad "round-trip is not wired to the codec"
fi
if jq -e '.invariants["plain-fallback-when-absent"].command | test("memory_codec")' "$MANIFEST" >/dev/null 2>&1; then
  ok "plain-fallback-when-absent drives the same seam"
else
  bad "fallback check is not wired to the codec"
fi
# test/memory-codec.test.sh is the suite that guards that seam; it must exist and
# still be the 59/0 gate the storage-codec attachment point relies on.
if [ -f "$REPO/test/memory-codec.test.sh" ]; then
  ok "test/memory-codec.test.sh — the codec seam's own gate — exists"
else
  bad "the codec seam has no gate suite"
fi

echo
echo "H5 — FALSIFIER: dropping storage-codec makes a real check DISAPPEAR"
# This is the mutation the task warns about: silently keeping one class. It does
# not error — it quietly stops running the round-trip check. Proving the check
# vanishes is what makes the dual class load-bearing rather than decorative.
restore
mutate '.permission_class = ["traffic-proxy"]'
OUT="$(add_mut dropped)"; RC=$?
if [ "$RC" -eq 0 ]; then
  ok "RED ARM: dropping a class still 'succeeds' — no error is raised"
  DINV="$TMP/state/dropped/headroom/invariants.json"
  if [ "$(jq -r 'length' "$DINV")" = "3" ]; then
    ok "…but only 3 invariants ran instead of 6"
  else
    bad "unexpected invariant count when a class was dropped"
  fi
  if jq -e '[.[] | select(.id=="round-trip-fidelity")] | length == 0' "$DINV" >/dev/null 2>&1; then
    ok "round-trip-fidelity STOPPED RUNNING — the dropped class cost a real check"
  else
    bad "round-trip-fidelity still ran with storage-codec dropped"
  fi
  if jq -e '[.[] | select(.class=="storage-codec")] | length == 0' "$DINV" >/dev/null 2>&1; then
    ok "no storage-codec invariant ran at all"
  else
    bad "a storage-codec invariant ran anyway"
  fi
  "$MODS" --registry "$MREG" --state "$TMP/state/dropped" remove headroom >/dev/null 2>&1
else
  bad "the dropped-class arm did not complete (exit $RC)"
fi
restore
if [ "$(sha_file "$MANIFEST")" = "$(sha_file "$MREG/headroom/manifest.json")" ]; then
  ok "GREEN ARM: restored — the copy is byte-identical to the shipped manifest again"
else
  bad "restore did not return the copy to the shipped bytes"
fi

echo
echo "H6 — FALSIFIER: an uncovered invariant is REFUSED and named"
restore
mutate 'del(.invariants["round-trip-fidelity"])'
OUT="$(add_mut hole)"; RC=$?
if [ "$RC" -ne 0 ]; then
  ok "RED ARM: a manifest with an uncovered invariant is refused"
else
  bad "an uncovered invariant was accepted"
fi
if grep -q 'round-trip-fidelity' <<<"$OUT"; then
  ok "the refusal names the uncovered invariant"
else
  bad "the refusal did not name the hole"
fi
if grep -q 'storage-codec' <<<"$OUT"; then
  ok "the refusal names the class that demanded it"
else
  bad "the refusal did not name the class"
fi
if [ ! -e "$TMP/state/hole/headroom" ]; then
  ok "the refused manifest installed nothing"
else
  bad "a refused manifest left residue"
fi
restore
OUT="$(add_mut restored)"; RC=$?
if [ "$RC" -eq 0 ]; then
  ok "GREEN ARM: restoring the command makes the add pass again"
else
  bad "restored manifest still fails (exit $RC)"
  printf '%s\n' "$OUT" | tail -15
fi
"$MODS" --registry "$MREG" --state "$TMP/state/restored" remove headroom >/dev/null 2>&1

echo
echo "H7 — a bad or missing pin is REFUSED"
restore
mutate '.pinned_version.artifact_sha256 = "not-a-real-digest"'
OUT="$(add_mut badpin)"; RC=$?
if [ "$RC" -ne 0 ]; then
  ok "a non-hex pin digest is refused"
else
  bad "a bad pin was accepted"
fi
if grep -q 'artifact_sha256' <<<"$OUT"; then
  ok "the refusal names artifact_sha256"
else
  bad "the refusal did not name the field"
fi
restore
mutate 'del(.pinned_version)'
OUT="$(add_mut nopin)"; RC=$?
if [ "$RC" -ne 0 ]; then
  ok "a missing pin is refused — there is no latest"
else
  bad "a missing pin was accepted"
fi
if grep -q 'pinned_version' <<<"$OUT"; then
  ok "the refusal names pinned_version"
else
  bad "the refusal did not name pinned_version"
fi

echo
echo "H8 — a consent-required class with no consent_text is REFUSED"
restore
mutate 'del(.consent_text)'
OUT="$(add_mut noconsent)"; RC=$?
if [ "$RC" -ne 0 ]; then
  ok "a consent-required class with no disclosure text is refused"
else
  bad "a blank consent prompt was accepted"
fi
if grep -q 'consent_text' <<<"$OUT"; then
  ok "the refusal names consent_text"
else
  bad "the refusal did not name consent_text"
fi
if [ ! -e "$TMP/state/noconsent/headroom" ]; then
  ok "the consent refusal installed nothing"
else
  bad "a consent refusal left residue"
fi

echo
echo "H9 — tier is available, and suggested is unreachable without the A/B receipt"
restore
if [ "$(jq -r '.tier' "$MANIFEST")" = "available" ]; then
  ok "the shipped tier is available"
else
  bad "the shipped tier is not available"
fi
if jq -e 'has("tier_evidence") | not' "$MANIFEST" >/dev/null 2>&1; then
  ok "no tier_evidence is claimed — the A/B has not run"
else
  bad "tier_evidence claimed without an A/B"
fi
mutate '.tier = "suggested"'
OUT="$(add_mut suggested)"; RC=$?
if [ "$RC" -ne 0 ]; then
  ok "flipping tier to suggested WITHOUT a receipt is refused"
else
  bad "suggested was reachable without evidence"
fi
if grep -q 'tier_evidence' <<<"$OUT"; then
  ok "the refusal demands tier_evidence.receipt"
else
  bad "the refusal did not demand a receipt"
fi
if grep -qi 'advertisement' <<<"$OUT"; then
  ok "the refusal says why: a recommendation without evidence is an advertisement"
else
  bad "the refusal gave no rationale"
fi
restore

echo
echo "H10 — default_included is a distribution fact, kept apart from tier"
if [ "$(jq -r '.default_included' "$MANIFEST")" = "true" ]; then
  ok "headroom is marked default_included"
else
  bad "default_included is not set"
fi
if [ "$(jq -r '.default_included | type' "$MANIFEST")" = "boolean" ]; then
  ok "default_included is a boolean"
else
  bad "default_included is not a boolean"
fi
mutate '.default_included = "yes"'
OUT="$(add_mut baddefault)"; RC=$?
if [ "$RC" -ne 0 ]; then
  ok "a non-boolean default_included is refused"
else
  bad "a non-boolean was accepted"
fi
restore
# Default inclusion must NOT be able to launder itself into an evidence claim.
if jq -e '.tier == "available" and .default_included == true' "$MANIFEST" >/dev/null 2>&1; then
  ok "default-included AND unproven are stated together, not conflated"
else
  bad "distribution and evidence are conflated"
fi
# A default-included module reaches every machine, so its disclosure must exist
# before it ships — enforced at validate, not at a prompt nobody may see.
mutate 'del(.consent_text)'
OUT="$(add_mut defaultnodisclosure)"; RC=$?
if [ "$RC" -ne 0 ]; then
  ok "a default-included module with no disclosure text is refused"
else
  bad "a default-included module shipped with no disclosure"
fi
restore

echo
echo "H11 — DEPEND, DON'T CLONE"
EXTRA="$(find "$REG/headroom/" -mindepth 1 -maxdepth 1 ! -name manifest.json | sed 's|.*/||' | head -5)"
if [ -z "$EXTRA" ]; then
  ok "modules/headroom holds manifest.json and nothing else"
else
  bad "vendored payload in modules/headroom: $EXTRA"
fi
# No Headroom source anywhere in the tree. What makes a directory a VENDORING is
# what is INSIDE it, so that is what is judged — never its path.
#
# hmd legitimately owns directories called `headroom` and it always will: the
# registry entry (modules/headroom/, one manifest) and, the moment anybody runs
# `hmd modules add headroom`, the install record ($STATE/headroom/, receipts hmd
# writes itself). Flagging those by name is what made this check fail on the
# owner's machine for doing the thing the module exists to do. Excluding them BY
# PATH would have been worse: `.heimdall/modules/headroom` is a path a real
# vendoring could be dropped into, and the check would then have been blind there
# forever.
#
# So the exclusion is an INVENTORY, not a path. A candidate is cleared only if
# every file beneath it is one of the four records hmd writes itself; anything else
# — a .py, a pyproject.toml, a PKG-INFO, a LICENSE, one stray source file — is
# foreign, and a directory holding foreign files is reported. Headroom's source
# cannot be spelled in manifest.json/receipt.json/wired.json/invariants.json, so no
# genuine vendoring can satisfy the inventory, wherever it is put. H11b proves that
# on the exact shape this fix stopped flagging.
HMD_OWN_RECORDS='manifest.json receipt.json wired.json invariants.json'

# Files under $1 that hmd does not write itself. Empty ⇒ hmd bookkeeping only.
foreign_files() {
  find "$1" -type f 2>/dev/null | while IFS= read -r f; do
    case " $HMD_OWN_RECORDS " in
      *" ${f##*/} "*) ;;
      *) printf '%s\n' "$f" ;;
    esac
  done
}

# Every directory under $1 that is NAMED like a Headroom package tree AND holds
# something other than hmd's own records.
# Prune agent worktrees by DIRECTORY NAME, not by path prefix: every agent worktree
# carries its own copy of modules/headroom/, and $REPO may itself sit inside one — a
# path-prefix filter then matches everything and the scan silently examines nothing.
# -mindepth 1 keeps a checkout literally named .claude from pruning its own root.
scan_vendored() {
  find "$1" -mindepth 1 \
      \( -type d -name '.git' -o -type d -name 'worktrees' -o -type d -name 'node_modules' \) -prune -o \
      -type d \( -name 'headroom' -o -name 'headroom_ai' \) -print 2>/dev/null \
  | while IFS= read -r d; do
      [ -n "$(foreign_files "$d")" ] && printf '%s\n' "$d"
    done
}

VEND="$(scan_vendored "$REPO" | head -3)"
if [ -z "$VEND" ]; then
  ok "no Headroom package tree is vendored anywhere in the repo"
else
  bad "possible vendored Headroom source: $VEND"
fi
# No published Headroom artifact may be sitting in the tree either. The one
# license-compliant exception path (a single vendored component carrying Apache
# headers plus a NOTICE) is deliberately NOT taken here, so the sdist and the
# wheels must both be absent.
VENDFILE="$(find "$REPO" \( -name 'headroom_ai-*' -o -name 'headroom-*.tar.gz' \) \
            -not -path '*/.git/*' 2>/dev/null | head -3)"
if [ -z "$VENDFILE" ]; then
  ok "no Headroom sdist or wheel is vendored in the tree"
else
  bad "vendored Headroom artifact: $VENDFILE"
fi

echo
echo "H11b — FALSIFIER: the content rule still fires on a vendoring hidden in an hmd shape"
# A green scan proves nothing until the same scan can go RED. These trees are built
# under $TMP, outside $REPO, so they cannot disturb the real assertion above.
VFX="$TMP/vendorscan"
# (a) the two shapes hmd genuinely owns: the registry entry, and the install record
#     `add` writes — the exact directory that used to fail this check.
mkdir -p "$VFX/clean/modules/headroom" "$VFX/clean/.heimdall/modules/headroom"
printf '{}\n' > "$VFX/clean/modules/headroom/manifest.json"
for r in receipt wired invariants; do printf '{}\n' > "$VFX/clean/.heimdall/modules/headroom/$r.json"; done
if [ -z "$(scan_vendored "$VFX/clean")" ]; then
  ok "GREEN: hmd's own registry entry AND install record are both cleared"
else
  bad "the scan flags hmd's own bookkeeping: $(scan_vendored "$VFX/clean")"
fi
# (b) source smuggled INTO the install record. This is the whole question: the
#     directory the fix stopped flagging is precisely where a violation would now
#     try to hide, so a path-based exclusion would be blind here and this must fire.
cp -R "$VFX/clean" "$VFX/smuggled"
printf 'def compress(text):\n    return text\n' > "$VFX/smuggled/.heimdall/modules/headroom/__init__.py"
if printf '%s' "$(scan_vendored "$VFX/smuggled")" | grep -q '\.heimdall/modules/headroom'; then
  ok "RED: one .py inside the install record is reported — the exclusion is an inventory, not a path"
else
  bad "a vendoring hidden in the install-state directory was MISSED"
fi
# (c) an ordinary vendoring anywhere else is still caught…
mkdir -p "$VFX/plain/vendor/headroom"
printf 'def compress(text):\n    return text\n' > "$VFX/plain/vendor/headroom/__init__.py"
printf '[project]\nname = "headroom"\n' > "$VFX/plain/vendor/headroom/pyproject.toml"
if printf '%s' "$(scan_vendored "$VFX/plain")" | grep -q 'vendor/headroom'; then
  ok "RED: a plain vendored source tree is reported"
else
  bad "an outright vendoring was missed"
fi
# (d) …and it cannot launder itself by wearing an hmd-shaped filename, because the
#     rule clears a directory only when EVERY file in it is one of hmd's records.
cp "$VFX/clean/modules/headroom/manifest.json" "$VFX/plain/vendor/headroom/manifest.json"
if printf '%s' "$(scan_vendored "$VFX/plain")" | grep -q 'vendor/headroom'; then
  ok "RED: adding a manifest.json beside the source does not clear it"
else
  bad "a vendoring laundered itself with an hmd-shaped filename"
fi

echo
echo "H12 — CP / enroll / signed traffic is scrubbed of LOCAL REWRITERS"
# This check USED to demand these files never MENTION a proxy variable. That was inverted:
# a script that never mentions a proxy is exactly the script that silently INHERITS an
# ambient one, because curl and urllib both read HTTPS_PROXY/ALL_PROXY from the environment
# whether or not the caller ever heard of them. Measured before the fix — a
# `heimdall-presence beat` under a loopback rewriter delivered POST /presence to the
# REWRITER — so the mention is now the DEFENSE, not the defect.
# The live differential lives in test/cp-signed-no-rewriting-proxy.test.sh; what is asserted
# here is the wiring that differential depends on.
SIGNED_FILES="bin/heimdall-presence bin/heimdall-connect bin/heimdall-team"
UNSCRUBBED=""
for f in $SIGNED_FILES; do
  grep -q 'hmd_signed_exec' "$REPO/$f" 2>/dev/null || UNSCRUBBED="$UNSCRUBBED $f"
done
if [ -z "$UNSCRUBBED" ]; then
  ok "every signed / enrollment surface routes its client through hmd_signed_exec"
else
  bad "a signed-traffic surface does not scrub local rewriters:$UNSCRUBBED"
fi

# …and the scrub must never become a BLANKET bypass. A corporate HTTPS proxy CONNECT-tunnels
# TLS, so it cannot rewrite signed bytes, and in a locked-down estate it is the only egress —
# forcing `--noproxy` would break hmd for those operators to defend against a threat their
# proxy does not pose.
BLANKET=""
for f in $SIGNED_FILES; do
  grep -q -- '--noproxy' "$REPO/$f" 2>/dev/null && BLANKET="$BLANKET $f"
done
if [ -z "$BLANKET" ]; then
  ok "no signed surface blanket-bypasses proxies — a corporate CONNECT proxy still works"
else
  bad "a signed surface forces a blanket proxy bypass:$BLANKET"
fi
# And the gate scrub still covers Headroom's own namespace.
if grep -q 'HEADROOM_BASE_URL' "$REPO/bin/lib/hmd-gate-endpoint.sh"; then
  ok "the gate scrub covers Headroom's own routing namespace"
else
  bad "the gate scrub does not know about HEADROOM_* vars"
fi
if grep -q 'HMD_PROVIDER_BASE_URL="https://api.anthropic.com"' "$REPO/bin/lib/hmd-gate-endpoint.sh"; then
  ok "judgment is still pinned to the real provider by a hardcoded constant"
else
  bad "the judgment pin is no longer a hardcoded constant"
fi

echo
echo "--------------------------------------------------------------------"
printf 'headroom-module: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
