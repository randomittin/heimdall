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
jq -e . "$MANIFEST" >/dev/null 2>&1 \
  && ok "manifest is valid JSON" || bad "manifest is not valid JSON"
[ "$(sha_file "$MANIFEST")" = "$(sha_file "$MREG/headroom/manifest.json")" ] \
  && ok "the mutation copy is byte-identical to the shipped manifest" \
  || bad "mutation copy diverged from the shipped manifest"
for f in name description upstream license pinned_version permission_class \
         installs_via wires invariants tier consent_text; do
  jq -e --arg f "$f" 'has($f)' "$MANIFEST" >/dev/null 2>&1 \
    && ok "manifest carries \`$f\`" || bad "manifest is missing \`$f\`"
done
[ "$(jq -r '.name' "$MANIFEST")" = "headroom" ] \
  && ok "name matches the module directory" || bad "name/directory mismatch"
[ "$(jq -r '.license' "$MANIFEST")" = "Apache-2.0" ] \
  && ok "license is Apache-2.0" || bad "unexpected license"
jq -e '.pinned_version.artifact_sha256 | test("^[0-9a-f]{64}$")' "$MANIFEST" >/dev/null 2>&1 \
  && ok "the pin carries a 64-hex artifact digest" || bad "pin digest is not 64 lowercase hex"
[ "$(jq -r '.installs_via.kind' "$MANIFEST")" = "upstream" ] \
  && ok "installs_via is upstream — depend, don't clone" || bad "installs_via is not upstream"
jq -e '.installs_via.fetch | test("uv tool install")' "$MANIFEST" >/dev/null 2>&1 \
  && ok "the fetch command is the recorded uv install line" || bad "fetch command is not the uv line"

echo
echo "H1 — listed as AVAILABLE, and honest that it is NOT installed"
# Against ABSENT_STATE: a state root this file created and never added to, so
# "nothing is installed" is a fact the suite established rather than one it
# inherited from whoever ran hmd on this machine last.
LIST="$(hmd_absent list 2>&1)"
grep -q 'headroom' <<<"$LIST" \
  && ok "\`hmd modules\` lists headroom" || bad "headroom is not listed"
grep -qE 'headroom +available' <<<"$LIST" \
  && ok "it is listed at tier available" || bad "headroom is not listed as available"
grep -q 'Installed: none' <<<"$LIST" \
  && ok "nothing is installed — the base install ships zero payloads" \
  || bad "something is reported installed"
JLIST="$(hmd_absent --json list 2>/dev/null)"
[ "$(printf '%s' "$JLIST" | jq -r '.installed_count')" = "0" ] \
  && ok "json list agrees: installed_count is 0" || bad "json list reports an install"
[ "$(printf '%s' "$JLIST" | jq -r '.available[] | select(.name=="headroom") | .tier')" = "available" ] \
  && ok "json list reports headroom at tier available" || bad "json tier is wrong"
STATUS="$(hmd_absent status headroom 2>&1)"
grep -q 'not installed' <<<"$STATUS" \
  && ok "\`status headroom\` is honest that it is absent" || bad "status is not honest about absence"
[ "$(hmd_absent --json status headroom 2>/dev/null | jq -r '.installed')" = "false" ] \
  && ok "json status reports installed:false" || bad "json status is not honest"
# NOT a state-root fact — an IMPORT-PATH one, and it is why the absent path stays
# the live case even on a machine that has adopted the module. The sanctioned
# install is `uv tool install`, which puts headroom-ai in an isolated uv tool venv
# that hmd's python3 cannot see, so `import headroom` fails whether or not the
# module is added and the seam must stay on the plain backend. Asserting the
# REASON as well as the verdict is what stops a seam that has silently stopped
# looking from reading as a seam that looked and found nothing.
CODEC="$(python3 "$REPO/bin/lib/memory_codec.py" status 2>&1)"
grep -q 'available: no' <<<"$CODEC" \
  && ok "the codec seam is on the plain backend — the uv-tool install never reaches hmd's import path" \
  || bad "the codec seam claims a backend hmd cannot import"
grep -q 'not importable' <<<"$CODEC" \
  && ok "…and it NAMES the reason: headroom is not importable from hmd's interpreter" \
  || bad "the seam reports plain without saying headroom is unimportable"

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
[ "$PRC" -eq 0 ] && ok "the module installs into a state root the suite owns (exit 0)" \
  || { bad "add into the scratch present root failed (exit $PRC)"; printf '%s\n' "$PADD" | tail -15; }
PLIST="$(hmd_present list 2>&1 | tr -s ' ')"
grep -q 'Installed: none' <<<"$PLIST" \
  && bad "list still reports 'Installed: none' with the module installed" \
  || ok "list stops claiming an empty install set once the module is there"
grep -qF "headroom $PIN" <<<"$PLIST" \
  && ok "list names headroom at the manifest pin ($PIN)" || bad "list does not report the installed pin"
PJLIST="$(hmd_present --json list 2>/dev/null)"
[ "$(printf '%s' "$PJLIST" | jq -r '.installed_count')" = "1" ] \
  && ok "json list agrees: installed_count is 1" || bad "json list did not count the install"
[ "$(printf '%s' "$PJLIST" | jq -r '[.installed[] | select(.name=="headroom")] | length')" = "1" ] \
  && ok "json list names headroom under installed" || bad "json list lost the installed module"
PSTATUS="$(hmd_present status headroom 2>&1 | tr -s ' ')"
grep -q 'not installed' <<<"$PSTATUS" \
  && bad "status still claims absence with the module installed" \
  || ok "\`status headroom\` is honest about PRESENCE — it stops claiming absence"
grep -qF "pin: $PIN" <<<"$PSTATUS" \
  && ok "status reports the pin it installed" || bad "status does not report the installed pin"
[ "$(hmd_present --json status headroom 2>/dev/null | jq -r '.installed')" = "true" ] \
  && ok "json status reports installed:true" || bad "json status hides the install"
hmd_present remove headroom >/dev/null 2>&1
[ "$(hmd_present --json status headroom 2>/dev/null | jq -r '.installed')" = "false" ] \
  && ok "…and back to installed:false after remove — the readout TRACKS state, it is not a constant" \
  || bad "status still reports installed after remove"

echo
echo "H2 — permission_class is DUAL and both contracts exist"
[ "$(jq -r '.permission_class | type' "$MANIFEST")" = "array" ] \
  && ok "permission_class is a list, not a single class" || bad "permission_class is not a list"
for c in traffic-proxy storage-codec; do
  jq -e --arg c "$c" '.permission_class | index($c) != null' "$MANIFEST" >/dev/null 2>&1 \
    && ok "declares the $c class" || bad "does not declare $c"
  [ -f "$REG/_classes/$c.json" ] \
    && ok "the $c contract exists in the registry" || bad "no contract for $c"
done

echo
echo "H3 — the add path runs BOTH classes' invariants, module WIRED"
ST="$TMP/state/real"
OUT="$("$MODS" --state "$ST" add headroom --yes 2>&1)"; RC=$?
[ "$RC" -eq 0 ] && ok "add succeeds against the real dual-class contract" \
                || { bad "add failed (exit $RC)"; printf '%s\n' "$OUT" | tail -20; }
INV="$ST/headroom/invariants.json"
if [ -f "$INV" ]; then
  [ "$(jq -r 'length' "$INV")" = "6" ] \
    && ok "all six invariants across both classes ran" \
    || bad "expected 6 invariants, got $(jq -r 'length' "$INV")"
  [ "$(jq -r '[.[] | select(.passed)] | length' "$INV")" = "6" ] \
    && ok "all six passed with the codec library NOT importable" || bad "not all six passed"
  [ "$(jq -r '[.[] | select(.class=="traffic-proxy")] | length' "$INV")" = "3" ] \
    && ok "three of them are attributed to traffic-proxy" || bad "traffic-proxy count wrong"
  [ "$(jq -r '[.[] | select(.class=="storage-codec")] | length' "$INV")" = "3" ] \
    && ok "three of them are attributed to storage-codec" || bad "storage-codec count wrong"
  # The evidence, not the claim: the falsifier's own 25/0 line must appear in the
  # recorded output of BOTH class-owned suite checks.
  jq -r '.[] | select(.id=="gates-read-raw") | .output_tail' "$INV" | grep -q '25 passed, 0 failed' \
    && ok "gates-read-raw really ran the judgment falsifier at 25/0" \
    || bad "gates-read-raw output has no 25/0 line"
  jq -r '.[] | select(.id=="never-touches-judgment-inputs") | .output_tail' "$INV" \
    | grep -q '25 passed, 0 failed' \
    && ok "never-touches-judgment-inputs ran the same falsifier at 25/0" \
    || bad "never-touches-judgment-inputs output has no 25/0 line"
  [ -f "$ST/headroom/wired.json" ] \
    && ok "the module was WIRED before the invariants ran" || bad "module was not wired"
  [ "$(jq -r '.permission_classes | length' "$ST/headroom/receipt.json")" = "2" ] \
    && ok "the receipt records BOTH classes" || bad "receipt lost a class"
  [ "$(jq -r '.default_included' "$ST/headroom/receipt.json")" = "true" ] \
    && ok "the receipt records default_included" || bad "receipt lost default_included"
else
  bad "no invariant record from the real add"
fi
"$MODS" --state "$ST" remove headroom >/dev/null 2>&1

echo
echo "H4 — the invariants are wired to the repo's real falsifiers"
CTP="$REG/_classes/traffic-proxy.json"
CSC="$REG/_classes/storage-codec.json"
jq -e '[.requires_invariants[] | select(.check.kind=="suite") | .check.command]
       | any(test("gate-judgment-uncompressed"))' "$CTP" >/dev/null 2>&1 \
  && ok "traffic-proxy consumes test/gate-judgment-uncompressed.test.sh" \
  || bad "traffic-proxy is not wired to the gate falsifier"
jq -e '[.requires_invariants[] | select(.check.kind=="suite") | .check.command]
       | any(test("gate-judgment-uncompressed"))' "$CSC" >/dev/null 2>&1 \
  && ok "storage-codec consumes the same falsifier" \
  || bad "storage-codec is not wired to the gate falsifier"
jq -e '.invariants["round-trip-fidelity"].command | test("memory_codec")' "$MANIFEST" >/dev/null 2>&1 \
  && ok "round-trip-fidelity drives bin/lib/memory_codec.py" || bad "round-trip is not wired to the codec"
jq -e '.invariants["plain-fallback-when-absent"].command | test("memory_codec")' "$MANIFEST" >/dev/null 2>&1 \
  && ok "plain-fallback-when-absent drives the same seam" || bad "fallback check is not wired to the codec"
# test/memory-codec.test.sh is the suite that guards that seam; it must exist and
# still be the 59/0 gate the storage-codec attachment point relies on.
[ -f "$REPO/test/memory-codec.test.sh" ] \
  && ok "test/memory-codec.test.sh — the codec seam's own gate — exists" \
  || bad "the codec seam has no gate suite"

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
  [ "$(jq -r 'length' "$DINV")" = "3" ] \
    && ok "…but only 3 invariants ran instead of 6" || bad "unexpected invariant count when a class was dropped"
  jq -e '[.[] | select(.id=="round-trip-fidelity")] | length == 0' "$DINV" >/dev/null 2>&1 \
    && ok "round-trip-fidelity STOPPED RUNNING — the dropped class cost a real check" \
    || bad "round-trip-fidelity still ran with storage-codec dropped"
  jq -e '[.[] | select(.class=="storage-codec")] | length == 0' "$DINV" >/dev/null 2>&1 \
    && ok "no storage-codec invariant ran at all" || bad "a storage-codec invariant ran anyway"
  "$MODS" --registry "$MREG" --state "$TMP/state/dropped" remove headroom >/dev/null 2>&1
else
  bad "the dropped-class arm did not complete (exit $RC)"
fi
restore
[ "$(sha_file "$MANIFEST")" = "$(sha_file "$MREG/headroom/manifest.json")" ] \
  && ok "GREEN ARM: restored — the copy is byte-identical to the shipped manifest again" \
  || bad "restore did not return the copy to the shipped bytes"

echo
echo "H6 — FALSIFIER: an uncovered invariant is REFUSED and named"
restore
mutate 'del(.invariants["round-trip-fidelity"])'
OUT="$(add_mut hole)"; RC=$?
[ "$RC" -ne 0 ] && ok "RED ARM: a manifest with an uncovered invariant is refused" \
               || bad "an uncovered invariant was accepted"
grep -q 'round-trip-fidelity' <<<"$OUT" \
  && ok "the refusal names the uncovered invariant" || bad "the refusal did not name the hole"
grep -q 'storage-codec' <<<"$OUT" \
  && ok "the refusal names the class that demanded it" || bad "the refusal did not name the class"
[ ! -e "$TMP/state/hole/headroom" ] \
  && ok "the refused manifest installed nothing" || bad "a refused manifest left residue"
restore
OUT="$(add_mut restored)"; RC=$?
[ "$RC" -eq 0 ] && ok "GREEN ARM: restoring the command makes the add pass again" \
               || { bad "restored manifest still fails (exit $RC)"; printf '%s\n' "$OUT" | tail -15; }
"$MODS" --registry "$MREG" --state "$TMP/state/restored" remove headroom >/dev/null 2>&1

echo
echo "H7 — a bad or missing pin is REFUSED"
restore
mutate '.pinned_version.artifact_sha256 = "not-a-real-digest"'
OUT="$(add_mut badpin)"; RC=$?
[ "$RC" -ne 0 ] && ok "a non-hex pin digest is refused" || bad "a bad pin was accepted"
grep -q 'artifact_sha256' <<<"$OUT" \
  && ok "the refusal names artifact_sha256" || bad "the refusal did not name the field"
restore
mutate 'del(.pinned_version)'
OUT="$(add_mut nopin)"; RC=$?
[ "$RC" -ne 0 ] && ok "a missing pin is refused — there is no latest" || bad "a missing pin was accepted"
grep -q 'pinned_version' <<<"$OUT" \
  && ok "the refusal names pinned_version" || bad "the refusal did not name pinned_version"

echo
echo "H8 — a consent-required class with no consent_text is REFUSED"
restore
mutate 'del(.consent_text)'
OUT="$(add_mut noconsent)"; RC=$?
[ "$RC" -ne 0 ] && ok "a consent-required class with no disclosure text is refused" \
               || bad "a blank consent prompt was accepted"
grep -q 'consent_text' <<<"$OUT" \
  && ok "the refusal names consent_text" || bad "the refusal did not name consent_text"
[ ! -e "$TMP/state/noconsent/headroom" ] \
  && ok "the consent refusal installed nothing" || bad "a consent refusal left residue"

echo
echo "H9 — tier is available, and suggested is unreachable without the A/B receipt"
restore
[ "$(jq -r '.tier' "$MANIFEST")" = "available" ] \
  && ok "the shipped tier is available" || bad "the shipped tier is not available"
jq -e 'has("tier_evidence") | not' "$MANIFEST" >/dev/null 2>&1 \
  && ok "no tier_evidence is claimed — the A/B has not run" || bad "tier_evidence claimed without an A/B"
mutate '.tier = "suggested"'
OUT="$(add_mut suggested)"; RC=$?
[ "$RC" -ne 0 ] && ok "flipping tier to suggested WITHOUT a receipt is refused" \
               || bad "suggested was reachable without evidence"
grep -q 'tier_evidence' <<<"$OUT" \
  && ok "the refusal demands tier_evidence.receipt" || bad "the refusal did not demand a receipt"
grep -qi 'advertisement' <<<"$OUT" \
  && ok "the refusal says why: a recommendation without evidence is an advertisement" \
  || bad "the refusal gave no rationale"
restore

echo
echo "H10 — default_included is a distribution fact, kept apart from tier"
[ "$(jq -r '.default_included' "$MANIFEST")" = "true" ] \
  && ok "headroom is marked default_included" || bad "default_included is not set"
[ "$(jq -r '.default_included | type' "$MANIFEST")" = "boolean" ] \
  && ok "default_included is a boolean" || bad "default_included is not a boolean"
mutate '.default_included = "yes"'
OUT="$(add_mut baddefault)"; RC=$?
[ "$RC" -ne 0 ] && ok "a non-boolean default_included is refused" || bad "a non-boolean was accepted"
restore
# Default inclusion must NOT be able to launder itself into an evidence claim.
jq -e '.tier == "available" and .default_included == true' "$MANIFEST" >/dev/null 2>&1 \
  && ok "default-included AND unproven are stated together, not conflated" \
  || bad "distribution and evidence are conflated"
# A default-included module reaches every machine, so its disclosure must exist
# before it ships — enforced at validate, not at a prompt nobody may see.
mutate 'del(.consent_text)'
OUT="$(add_mut defaultnodisclosure)"; RC=$?
[ "$RC" -ne 0 ] && ok "a default-included module with no disclosure text is refused" \
               || bad "a default-included module shipped with no disclosure"
restore

echo
echo "H11 — DEPEND, DON'T CLONE"
EXTRA="$(ls -A "$REG/headroom" | grep -v '^manifest.json$' | head -5)"
[ -z "$EXTRA" ] \
  && ok "modules/headroom holds manifest.json and nothing else" \
  || bad "vendored payload in modules/headroom: $EXTRA"
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
[ -z "$VEND" ] && ok "no Headroom package tree is vendored anywhere in the repo" \
               || bad "possible vendored Headroom source: $VEND"
# No published Headroom artifact may be sitting in the tree either. The one
# license-compliant exception path (a single vendored component carrying Apache
# headers plus a NOTICE) is deliberately NOT taken here, so the sdist and the
# wheels must both be absent.
VENDFILE="$(find "$REPO" \( -name 'headroom_ai-*' -o -name 'headroom-*.tar.gz' \) \
            -not -path '*/.git/*' 2>/dev/null | head -3)"
[ -z "$VENDFILE" ] \
  && ok "no Headroom sdist or wheel is vendored in the tree" \
  || bad "vendored Headroom artifact: $VENDFILE"

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
[ -z "$(scan_vendored "$VFX/clean")" ] \
  && ok "GREEN: hmd's own registry entry AND install record are both cleared" \
  || bad "the scan flags hmd's own bookkeeping: $(scan_vendored "$VFX/clean")"
# (b) source smuggled INTO the install record. This is the whole question: the
#     directory the fix stopped flagging is precisely where a violation would now
#     try to hide, so a path-based exclusion would be blind here and this must fire.
cp -R "$VFX/clean" "$VFX/smuggled"
printf 'def compress(text):\n    return text\n' > "$VFX/smuggled/.heimdall/modules/headroom/__init__.py"
printf '%s' "$(scan_vendored "$VFX/smuggled")" | grep -q '\.heimdall/modules/headroom' \
  && ok "RED: one .py inside the install record is reported — the exclusion is an inventory, not a path" \
  || bad "a vendoring hidden in the install-state directory was MISSED"
# (c) an ordinary vendoring anywhere else is still caught…
mkdir -p "$VFX/plain/vendor/headroom"
printf 'def compress(text):\n    return text\n' > "$VFX/plain/vendor/headroom/__init__.py"
printf '[project]\nname = "headroom"\n' > "$VFX/plain/vendor/headroom/pyproject.toml"
printf '%s' "$(scan_vendored "$VFX/plain")" | grep -q 'vendor/headroom' \
  && ok "RED: a plain vendored source tree is reported" || bad "an outright vendoring was missed"
# (d) …and it cannot launder itself by wearing an hmd-shaped filename, because the
#     rule clears a directory only when EVERY file in it is one of hmd's records.
cp "$VFX/clean/modules/headroom/manifest.json" "$VFX/plain/vendor/headroom/manifest.json"
printf '%s' "$(scan_vendored "$VFX/plain")" | grep -q 'vendor/headroom' \
  && ok "RED: adding a manifest.json beside the source does not clear it" \
  || bad "a vendoring laundered itself with an hmd-shaped filename"

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
[ -z "$UNSCRUBBED" ] \
  && ok "every signed / enrollment surface routes its client through hmd_signed_exec" \
  || bad "a signed-traffic surface does not scrub local rewriters:$UNSCRUBBED"

# …and the scrub must never become a BLANKET bypass. A corporate HTTPS proxy CONNECT-tunnels
# TLS, so it cannot rewrite signed bytes, and in a locked-down estate it is the only egress —
# forcing `--noproxy` would break hmd for those operators to defend against a threat their
# proxy does not pose.
BLANKET=""
for f in $SIGNED_FILES; do
  grep -q -- '--noproxy' "$REPO/$f" 2>/dev/null && BLANKET="$BLANKET $f"
done
[ -z "$BLANKET" ] \
  && ok "no signed surface blanket-bypasses proxies — a corporate CONNECT proxy still works" \
  || bad "a signed surface forces a blanket proxy bypass:$BLANKET"
# And the gate scrub still covers Headroom's own namespace.
grep -q 'HEADROOM_BASE_URL' "$REPO/bin/lib/hmd-gate-endpoint.sh" \
  && ok "the gate scrub covers Headroom's own routing namespace" \
  || bad "the gate scrub does not know about HEADROOM_* vars"
grep -q 'HMD_PROVIDER_BASE_URL="https://api.anthropic.com"' "$REPO/bin/lib/hmd-gate-endpoint.sh" \
  && ok "judgment is still pinned to the real provider by a hardcoded constant" \
  || bad "the judgment pin is no longer a hardcoded constant"

echo
echo "--------------------------------------------------------------------"
printf 'headroom-module: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
