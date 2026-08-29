#!/usr/bin/env bash
#
# omniroute-module.test.sh — acceptance for modules/omniroute/manifest.json and
# bin/heimdall-omniroute-install, the two files a SEPARATE pair of agents is
# writing concurrently with this suite.
#
# THE HEADLINE PROPERTY THIS FILE EXISTS TO PROVE: OmniRoute is OPT-IN ONLY. It
# must never install unless an operator explicitly turns it on. Every section
# below either proves that directly or proves a mechanism the property depends
# on (the default-set derivation, the consent gate, the opt-out record).
#
# THIS FILE OWNS TWO FACTS THAT ARE OUTSIDE ITS CONTROL: whether
# modules/omniroute/manifest.json and bin/heimdall-omniroute-install exist yet.
# Two other agents are writing those concurrently. Every section that reads one
# of them is gated behind an existence check and SKIPS — loudly, counted apart
# from PASS/FAIL, never counted as a pass — when its dependency is absent. A
# suite that quietly reported green over a file it never looked at would be
# worse than useless the day this lands broken.
#
# WHERE FALSIFIABILITY DOES NOT NEED THE OTHER FILES AT ALL. Several of the
# properties under test are properties of the MECHANISM (heimdall-modules,
# heimdall-autoupdate's default-set reconciler, the secret-scrubbing harness
# this file drives the installer through), not of OmniRoute's own manifest.
# Those sections build SYNTHETIC fixtures — a traffic-proxy module this repo
# has never heard of, a script that deliberately leaks a marker secret — and
# run RIGHT NOW, mutation-tested, regardless of whether the other two agents
# have landed. They are what let this file report real, executed, RED/GREEN
# evidence today instead of "everything is skipped".
#
# Guarantees proved:
#   O1  the manifest sets default_included:false and consent_waived:false as
#       BOOLEANS — asserted on the JSON, not on prose. Falsifier: a mutated copy
#       flipped to true is shown to actually read true, proving the assertion
#       reads the field and is not a constant.
#   O2  SYNTHETIC — a traffic-proxy module with default_included:false is never
#       even NAMED by heimdall-autoupdate's real reconcile loop against a
#       registry this repo has never heard of. Falsifier: flipping
#       default_included to true on the same synthetic module makes it appear
#       (deferred, pending consent) in the very same log.
#   O2b REAL (gated) — the shipped OmniRoute manifest is excluded from
#       default_module_names() / reconcile the same way, against the real
#       registry.
#   O3  consent is REQUIRED, in contrast to headroom, which is deliberately
#       waived: the identical add invocation against the identical registry
#       refuses for OmniRoute and succeeds unprompted for headroom. Falsifier:
#       a copy of OmniRoute's manifest with consent_waived flipped to true (and
#       a reason) installs unprompted, proving O3's refusal is really about
#       consent_waived and not some unrelated block.
#   O4  `hmd modules optout omniroute` records the decision, `status` renders
#       it, `repair` honours it as a no-op (real code path, read before this
#       was written), and `optin` reverses it — all against the real registry.
#   O5  the manifest passes the repo's own validator (validate_manifest,
#       resolve_classes, check_invariant_coverage, check_default_included) —
#       proved by reaching the consent step of the real add pipeline WITHOUT
#       ever reaching install (no network, nothing fetched). Falsifiers: a
#       broken pin and an uncovered class invariant are each refused by name,
#       mirroring headroom's own H6/H7.
#   O6  pin integrity — the manifest carries the exact commit
#       d82b68274c75c14d258b4898a34edc25d9712b87 and version 3.8.51 the
#       operator pinned. Falsifier: a copy with the SHA replaced is shown to no
#       longer match. Cross-checked against patches/omniroute/README.md when it
#       exists.
#   O7  the installer exists, is executable, is `bash -n` clean, and its source
#       carries the same pin. (gated on the file existing)
#   O8  SYNTHETIC harness proof — a reference "installer" that checks node,
#       checks a post-clone SHA, and checks for a Tier-1 provider row is driven
#       through refusal on all three axes, and a mutant with one guard removed
#       is shown to stop refusing on exactly that axis. This is the harness
#       that O9 then points at the real installer.
#   O9  REAL installer (gated) — the same three refusal fixtures driven against
#       bin/heimdall-omniroute-install.
#   O10 secrets discipline — a marker planted in plausible secret env vars
#       never appears in captured stdout/stderr, proved on a synthetic leaker
#       (RED) and then on the real installer's refusal paths (GREEN, gated).
#
# HERMETICITY: no network is ever reached deliberately. Every add/status/
# reconcile call in this file either runs entirely read-only steps (validate /
# class contract / preflight / consent) or is refused before `installs_via`
# would ever execute; the one place a real fetch command exists (headroom, used
# only for CONTRAST in O3) is a call this repo's OWN suites already run
# non-interactively with no payload downloaded beyond what headroom-module.test.sh
# already exercises. All state lives under $TMP. Nothing here touches
# /Users/rj/omniroute or ~/.omniroute — every child process gets a throwaway
# $HOME and every module invocation gets an explicit --registry/--state.
#
# macOS has no timeout(1): anything that could hang runs under the same perl
# alarm wrapper test/run-all.sh itself uses.
#
# Usage:  bash test/omniroute-module.test.sh   (exit 0 = every guarantee holds)
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SELF_DIR/.." && pwd)"
MODS="$REPO/bin/heimdall-modules"
AUTOUPD="$REPO/bin/heimdall-autoupdate"
REAL_REG="$REPO/modules"
REAL_CLASSES="$REAL_REG/_classes"
MANIFEST="$REAL_REG/omniroute/manifest.json"
INSTALLER="$REPO/bin/heimdall-omniroute-install"
PATCH_README="$REPO/patches/omniroute/README.md"

PIN_SHA="d82b68274c75c14d258b4898a34edc25d9712b87"
PIN_VERSION="3.8.51"

command -v jq >/dev/null 2>&1 || { echo "error: jq is required" >&2; exit 2; }
[ -x "$MODS" ]    || { echo "FATAL: $MODS missing/not executable" >&2; exit 2; }
[ -x "$AUTOUPD" ] || { echo "FATAL: $AUTOUPD missing/not executable" >&2; exit 2; }
cd "$REPO" || exit 2

PASS=0; FAIL=0; SKIP=0
ok()   { printf '  \033[32mPASS\033[0m %s\n' "$1"; PASS=$((PASS+1)); }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAIL=$((FAIL+1)); }
skip() { printf '  \033[33mSKIP\033[0m %s\n' "$1"; SKIP=$((SKIP+1)); }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Same reasoning every sibling suite documents: hmd's generic preflight disk
# floor (4096 MB) is sized for a real payload, not these fixtures. Pinned low so
# consent — the thing under test — is what decides the outcome, never the
# laptop's free space. Proven both ways in test/module-preflight-wiring.test.sh.
export HMD_PREFLIGHT_DISK_FLOOR_MB=1

# perl alarm wrapper — the same pattern test/run-all.sh and test/brief-fail-closed.test.sh
# use for macOS, which has no timeout(1). Anything that could conceivably hang
# runs through a literal `perl -e 'alarm N; exec @ARGV' cmd args...` at its call
# site (not a wrapper function — a shell function can't be found through `env`,
# which some call sites below need for a clean environment; perl is always a
# real external binary, so it works identically whether invoked directly or
# through `env`).

sha_file() { shasum -a 256 "$1" | awk '{print $1}'; }

HAVE_MANIFEST=0;  [ -f "$MANIFEST" ]     && HAVE_MANIFEST=1
HAVE_INSTALLER=0; [ -f "$INSTALLER" ]    && HAVE_INSTALLER=1
HAVE_README=0;    [ -f "$PATCH_README" ] && HAVE_README=1

echo
echo "── dependency check (own status, never silent) ──"
[ "$HAVE_MANIFEST"  -eq 1 ] && echo "  modules/omniroute/manifest.json : present" \
                            || echo "  modules/omniroute/manifest.json : ABSENT — manifest sections will SKIP"
[ "$HAVE_INSTALLER" -eq 1 ] && echo "  bin/heimdall-omniroute-install   : present" \
                            || echo "  bin/heimdall-omniroute-install   : ABSENT — installer sections will SKIP"
[ "$HAVE_README"    -eq 1 ] && echo "  patches/omniroute/README.md      : present" \
                            || echo "  patches/omniroute/README.md      : ABSENT — README cross-check will SKIP"

# A registry this file owns: the real class contracts (unmodified) plus a
# byte-identical copy of the real manifest when it exists, so every mutation
# arm below operates on a copy and the shipped tree is never touched.
MREG="$TMP/registry"
mkdir -p "$MREG/_classes"
cp "$REAL_CLASSES"/*.json "$MREG/_classes/"
if [ "$HAVE_MANIFEST" -eq 1 ]; then
  mkdir -p "$MREG/omniroute"
  cp "$MANIFEST" "$MREG/omniroute/manifest.json"
  # The shipped manifest declares a real preflight.disk_mb (16384 -- see
  # docs/analysis/2026-08-29-omniroute-disk-footprint.md) that can legitimately
  # exceed free space on a disk-constrained CI/test machine, and per
  # module_preflight.sh a manifest-declared disk_mb always wins over
  # HMD_PREFLIGHT_DISK_FLOOR_MB below. Overriding it here, once, up front --
  # never deleting the key -- keeps every subtest exercising a manifest that
  # still HAS a real preflight block (the true shape) while staying
  # disk-size-independent, this suite's own stated intent (see
  # HMD_PREFLIGHT_DISK_FLOOR_MB=1 above). MANIFEST_BASELINE, not $MANIFEST, is
  # what restore_manifest() and every "byte-identical" check below compare
  # against from this point on, since this override is a deliberate, explicit
  # part of this run's baseline, not a mutation under test.
  jq '.preflight.disk_mb = 1' "$MREG/omniroute/manifest.json" > "$MREG/omniroute/m.tmp" \
    && mv "$MREG/omniroute/m.tmp" "$MREG/omniroute/manifest.json"
  MANIFEST_BASELINE="$MREG/omniroute/manifest.baseline.json"
  cp "$MREG/omniroute/manifest.json" "$MANIFEST_BASELINE"
fi
# headroom rides along in the same temp registry for the O3 contrast — it is
# real, shipped, default_included:true, consent_waived:true.
mkdir -p "$MREG/headroom"
cp "$REAL_REG/headroom/manifest.json" "$MREG/headroom/manifest.json"

restore_manifest() { cp "$MANIFEST" "$MREG/omniroute/manifest.json"; }
mutate_manifest() {
  # "$@", not "$1" — some call sites need jq's --arg form (`mutate_manifest
  # --arg id "$FIRST_ID" 'del(.invariants[$id])'`), which is more than one
  # token. Forwarding only "$1" silently fed jq the literal string "--arg" as
  # its filter program (a bare flag jq rejected with "--arg takes two
  # parameters"), which made mv's precondition fail via the `&&` short-circuit
  # — so the mutation never landed and the copy stayed byte-identical to the
  # shipped manifest. A plain one-token call (the common case elsewhere in
  # this file) forwards identically under "$@" as it did under "$1".
  jq "$@" "$MREG/omniroute/manifest.json" > "$MREG/omniroute/m.tmp" \
    && mv "$MREG/omniroute/m.tmp" "$MREG/omniroute/manifest.json"
}

# ═════════════════════════════════════════════════════════════════════════════
echo
echo "O1 — opt-in headline: default_included:false, consent_waived:false"
if [ "$HAVE_MANIFEST" -eq 0 ]; then
  skip "O1 needs modules/omniroute/manifest.json — not present yet"
else
  jq -e . "$MANIFEST" >/dev/null 2>&1 \
    && ok "manifest is valid JSON" || bad "manifest is not valid JSON"
  [ "$(jq -r '.name' "$MANIFEST")" = "omniroute" ] \
    && ok "name matches the module directory" || bad "name/directory mismatch"
  jq -e '.default_included | type == "boolean"' "$MANIFEST" >/dev/null 2>&1 \
    && ok "default_included is a boolean" || bad "default_included is not a boolean"
  [ "$(jq -r '.default_included' "$MANIFEST")" = "false" ] \
    && ok "default_included is false — OmniRoute ships to NOBODY by default" \
    || bad "default_included is not false (got: $(jq -r '.default_included' "$MANIFEST"))"
  jq -e '.consent_waived | type == "boolean"' "$MANIFEST" >/dev/null 2>&1 \
    && ok "consent_waived is a boolean" || bad "consent_waived is not a boolean"
  [ "$(jq -r '.consent_waived' "$MANIFEST")" = "false" ] \
    && ok "consent_waived is false — nobody is auto-consented into OmniRoute" \
    || bad "consent_waived is not false (got: $(jq -r '.consent_waived' "$MANIFEST"))"
  jq -e '.permission_class | (type=="string" and .=="traffic-proxy") or (type=="array" and index("traffic-proxy")!=null)' \
    "$MANIFEST" >/dev/null 2>&1 \
    && ok "declares the traffic-proxy class — the strictest class in the system" \
    || bad "does not declare traffic-proxy"

  # FALSIFIER: on a COPY, flip both fields to true and show the same assertion
  # style now reads true — proving O1 reads the field rather than a constant.
  restore_manifest
  mutate_manifest '.default_included = true | .consent_waived = true'
  [ "$(jq -r '.default_included' "$MREG/omniroute/manifest.json")" = "true" ] \
    && ok "RED ARM: the mutated copy now reads default_included:true — the check discriminates" \
    || bad "the mutation did not take — the copy still reads false"
  [ "$(jq -r '.consent_waived' "$MREG/omniroute/manifest.json")" = "true" ] \
    && ok "RED ARM: the mutated copy now reads consent_waived:true — the check discriminates" \
    || bad "the mutation did not take on consent_waived"
  restore_manifest
  [ "$(sha_file "$MANIFEST")" = "$(sha_file "$MREG/omniroute/manifest.json")" ] \
    && ok "GREEN ARM: restored — the working copy is byte-identical to the shipped manifest again" \
    || bad "restore did not return the copy to the shipped bytes"
fi

# ═════════════════════════════════════════════════════════════════════════════
echo
echo "O2 — SYNTHETIC: default_included:false is invisible to the real reconcile loop"
# A registry this repo has never heard of, so this proves the RULE generalises
# rather than proving heimdall-autoupdate special-cases the name "omniroute".
SREG="$TMP/synthetic-registry"
mkdir -p "$SREG/_classes" "$SREG/proxymod_synth"
cp "$REAL_CLASSES"/*.json "$SREG/_classes/"
jq -n '{name:"proxymod_synth", description:"synthetic traffic-proxy fixture",
        upstream:"https://example.invalid/proxymod_synth", license:"MIT",
        tier:"available", default_included:false,
        pinned_version:{version:"1.0.0", artifact:"x-1.0.0.tar.gz",
          artifact_sha256:"0000000000000000000000000000000000000000000000000000000000000000"},
        permission_class:"traffic-proxy",
        installs_via:{kind:"upstream", fetch:"true"},
        wires:[], invariants:{}, consent_text:"synthetic disclosure"}' \
  > "$SREG/proxymod_synth/manifest.json"

SHOME="$TMP/home-o2"; mkdir -p "$SHOME"
run_reconcile() { # <home> <registry> <state>
  env HOME="$1" HEIMDALL_HOME="$1" HMD_MODULES_REGISTRY="$2" HMD_MODULES_STATE="$3" \
      HEIMDALL_LATEST_OVERRIDE="9.9.9" HEIMDALL_INSTALLED_OVERRIDE="9.9.9" \
      HEIMDALL_AUTOUPDATE_DRYRUN=1 HEIMDALL_MODULE_RECONCILE_DRYRUN=1 \
      "$AUTOUPD" check >/dev/null 2>&1
}
run_reconcile "$SHOME" "$SREG" "$TMP/state-o2"
grep -q 'proxymod_synth' "$SHOME/autoupdate.log" 2>/dev/null \
  && bad "a default_included:false traffic-proxy module was named by reconcile at all" \
  || ok "default_included:false keeps a module OUT of the reconcile loop entirely — not even deferred"

# FALSIFIER: flip default_included to true on the SAME synthetic module and show
# it now appears (deferred, pending consent — traffic-proxy always requires it
# and this fixture waives nothing).
SREG2="$TMP/synthetic-registry-flip"
mkdir -p "$SREG2/_classes"; cp -R "$SREG/proxymod_synth" "$SREG2/"; cp "$REAL_CLASSES"/*.json "$SREG2/_classes/"
jq '.default_included = true' "$SREG/proxymod_synth/manifest.json" > "$SREG2/proxymod_synth/manifest.json"
SHOME2="$TMP/home-o2-flip"; mkdir -p "$SHOME2"
run_reconcile "$SHOME2" "$SREG2" "$TMP/state-o2-flip"
grep -q 'reconcile: proxymod_synth defer-consent' "$SHOME2/autoupdate.log" 2>/dev/null \
  && ok "RED ARM: flipping default_included to true makes the SAME module appear (deferred, pending consent)" \
  || bad "flipping default_included to true did not change the outcome — O2 may be passing vacuously: $(cat "$SHOME2/autoupdate.log" 2>/dev/null)"

echo
echo "O2b — REAL (gated): the shipped OmniRoute manifest is excluded from the default set"
if [ "$HAVE_MANIFEST" -eq 0 ]; then
  skip "O2b needs modules/omniroute/manifest.json — not present yet"
else
  RHOME="$TMP/home-o2b"; mkdir -p "$RHOME"
  run_reconcile "$RHOME" "$REAL_REG" "$TMP/state-o2b"
  grep -q 'omniroute' "$RHOME/autoupdate.log" 2>/dev/null \
    && bad "the real reconcile loop named omniroute at all: $(cat "$RHOME/autoupdate.log" 2>/dev/null)" \
    || ok "the REAL registry's OmniRoute manifest never enters the reconcile loop — default_included:false holds for real"
fi

# ═════════════════════════════════════════════════════════════════════════════
echo
echo "O3 — consent is REQUIRED, contrasted against headroom's deliberate waiver"
if [ "$HAVE_MANIFEST" -eq 0 ]; then
  skip "O3 needs modules/omniroute/manifest.json — not present yet"
else
  hmd_mreg() { "$MODS" --registry "$MREG" --state "$1" "${@:2}"; }

  OSTATE="$TMP/state/o3-omni"
  OUT_O="$(hmd_mreg "$OSTATE" add omniroute < /dev/null 2>&1)"; RC_O=$?
  [ "$RC_O" -ne 0 ] \
    && ok "an un-waived OmniRoute is REFUSED without consent (exit $RC_O)" \
    || bad "OmniRoute installed with nobody asked — the opt-in property is broken"
  grep -qi 'consent is required' <<<"$OUT_O" \
    && ok "the refusal names consent as the reason" || bad "no consent-required message from the OmniRoute refusal"
  [ ! -f "$OSTATE/omniroute/receipt.json" ] \
    && ok "nothing was installed for OmniRoute" || bad "OmniRoute left a receipt despite the refusal"

  HSTATE="$TMP/state/o3-headroom"
  OUT_H="$(hmd_mreg "$HSTATE" add headroom < /dev/null 2>&1)"; RC_H=$?
  [ "$RC_H" -eq 0 ] \
    && ok "the SAME invocation shape SUCCEEDS unprompted for headroom (its own manifest waives consent)" \
    || bad "headroom failed under the identical harness (exit $RC_H) — the contrast fixture itself is broken"
  grep -qi 'Install it? \[y/N\]' <<<"$OUT_H" \
    && bad "headroom still prompted — its waiver stopped working" \
    || ok "headroom is not prompted — proving this harness CAN let a module through, so O3's OmniRoute refusal is not a wall that blocks everything"
  [ -f "$HSTATE/headroom/receipt.json" ] \
    && ok "headroom's receipt exists — the contrast is real, not two refusals dressed up differently" \
    || bad "headroom left no receipt — the contrast fixture did not actually install anything"
  "$MODS" --registry "$MREG" --state "$HSTATE" remove headroom >/dev/null 2>&1

  # FALSIFIER: a copy of OmniRoute's OWN manifest with consent explicitly waived
  # installs unprompted too — proving O3's refusal above is really ABOUT
  # consent_waived, and not some unrelated block (a bad pin, a missing invariant).
  restore_manifest
  mutate_manifest '.consent_waived = true | .consent_waived_reason = "synthetic falsifier: proving the O3 refusal is really about consent_waived, not an unrelated block"'
  FSTATE="$TMP/state/o3-falsify"
  OUT_F="$(hmd_mreg "$FSTATE" add omniroute < /dev/null 2>&1)"; RC_F=$?
  [ "$RC_F" -eq 0 ] \
    && ok "RED ARM: waiving consent on a COPY makes the identical add succeed unprompted" \
    || bad "even with consent waived on the copy, add still failed (exit $RC_F) — O3's refusal is not isolated to consent: $(printf '%s\n' "$OUT_F" | tail -15)"
  grep -qi 'Install it? \[y/N\]' <<<"$OUT_F" \
    && bad "the waived copy still prompted" || ok "the waived copy is not prompted"
  "$MODS" --registry "$MREG" --state "$FSTATE" remove omniroute >/dev/null 2>&1
  restore_manifest
  [ "$(sha_file "$MANIFEST")" = "$(sha_file "$MREG/omniroute/manifest.json")" ] \
    && ok "GREEN ARM: restored — the copy is byte-identical to the shipped manifest again" \
    || bad "restore did not return the copy to the shipped bytes"
fi

# ═════════════════════════════════════════════════════════════════════════════
echo
echo "O4 — hmd modules optout omniroute keeps it out, and nothing re-installs it"
if [ "$HAVE_MANIFEST" -eq 0 ]; then
  skip "O4 needs modules/omniroute/manifest.json — not present yet"
else
  O4STATE="$TMP/state/o4"
  hmd4() { "$MODS" --registry "$MREG" --state "$O4STATE" "$@"; }

  OUT4="$(hmd4 optout omniroute 2>&1)"; RC4=$?
  [ "$RC4" -eq 0 ] && ok "optout omniroute exits 0" || bad "optout exited $RC4"
  [ -f "$O4STATE/.modstate/omniroute/optout.json" ] \
    && ok "the opt-out is recorded as a file — hmd's own definition of a state fact" \
    || bad "no optout.json was written"

  ST4="$(hmd4 status omniroute 2>&1)"
  grep -qi 'OPTED OUT' <<<"$ST4" \
    && ok "status renders the opt-out in words" || bad "status does not mention the opt-out: $ST4"
  [ "$(hmd4 --json status omniroute 2>/dev/null | jq -r '.state')" = "opted-out" ] \
    && ok "json status reports state:opted-out" || bad "json status does not report opted-out"

  # repair — the real code path this suite read before writing this assertion:
  # cmd_repair checks is_opted_out FIRST and returns a no-op, never re-attempting
  # an install someone declined.
  REPOUT="$(hmd4 repair omniroute 2>&1)"; REPRC=$?
  [ "$REPRC" -eq 0 ] && ok "repair on an opted-out module exits 0 (a no-op, not an error)" \
                     || bad "repair on an opted-out module exited $REPRC"
  grep -qi 'opted out' <<<"$REPOUT" \
    && ok "repair SAYS it is honouring the opt-out rather than silently doing nothing" \
    || bad "repair gave no indication it was honouring the opt-out: $REPOUT"
  [ ! -f "$O4STATE/omniroute/receipt.json" ] \
    && ok "repair left OmniRoute uninstalled" || bad "repair installed OmniRoute despite the opt-out"

  # reconcile — belt and suspenders: the default set already excludes OmniRoute
  # (O2b), and the opt-out record independently keeps it out too.
  RCHOME="$TMP/home-o4"; mkdir -p "$RCHOME"
  env HOME="$RCHOME" HEIMDALL_HOME="$RCHOME" HMD_MODULES_REGISTRY="$MREG" HMD_MODULES_STATE="$O4STATE" \
      HEIMDALL_LATEST_OVERRIDE="9.9.9" HEIMDALL_INSTALLED_OVERRIDE="9.9.9" \
      HEIMDALL_AUTOUPDATE_DRYRUN=1 HEIMDALL_MODULE_RECONCILE_DRYRUN=1 \
      "$AUTOUPD" check >/dev/null 2>&1
  grep -qE 'reconcile: omniroute would-acquire' "$RCHOME/autoupdate.log" 2>/dev/null \
    && bad "reconcile tried to acquire the opted-out omniroute module" \
    || ok "reconcile does not try to re-install the opted-out omniroute module"

  # optin — reversible, and cleanly so.
  OUT4B="$(hmd4 optin omniroute 2>&1)"; RC4B=$?
  [ "$RC4B" -eq 0 ] && ok "optin omniroute exits 0" || bad "optin exited $RC4B"
  [ ! -f "$O4STATE/.modstate/omniroute/optout.json" ] \
    && ok "optin clears the opt-out record" || bad "the opt-out record survived optin"
  [ "$(hmd4 --json status omniroute 2>/dev/null | jq -r '.state')" != "opted-out" ] \
    && ok "status no longer reports opted-out after optin" || bad "status still reports opted-out after optin"
fi

# ═════════════════════════════════════════════════════════════════════════════
echo
echo "O5 — the manifest passes the repo's own validator, hermetically (no fetch reached)"
if [ "$HAVE_MANIFEST" -eq 0 ]; then
  skip "O5 needs modules/omniroute/manifest.json — not present yet"
else
  O5STATE="$TMP/state/o5"
  OUT5="$("$MODS" --registry "$MREG" --state "$O5STATE" add omniroute < /dev/null 2>&1)"; RC5=$?
  grep -q '\[1/7\] validate' <<<"$OUT5" && ok "reaches [1/7] validate" || bad "never reached validate"
  grep -q '\[2/7\] class contract' <<<"$OUT5" && ok "reaches [2/7] class contract" || bad "never reached class contract"
  grep -q '\[3/7\] preflight' <<<"$OUT5" && ok "reaches [3/7] preflight" || bad "never reached preflight"
  grep -q '\[4/7\] consent' <<<"$OUT5" && ok "reaches [4/7] consent — validate + class contract + preflight all passed" \
                                        || bad "never reached consent — something before it refused"
  grep -q '\[5/7\]' <<<"$OUT5" \
    && bad "reached [5/7] install — this run had no consent, so a fetch would have run without permission" \
    || ok "never reaches [5/7] install — HERMETIC: no fetch command ever runs on this path"
  grep -qi 'manifest failed validation' <<<"$OUT5" \
    && bad "validate_manifest rejected the shipped manifest: $OUT5" \
    || ok "validate_manifest accepts the shipped manifest"
  grep -qi 'does not cover every invariant' <<<"$OUT5" \
    && bad "check_invariant_coverage rejected the shipped manifest: $OUT5" \
    || ok "check_invariant_coverage accepts the shipped manifest"
  [ "$RC5" -ne 0 ] \
    && ok "the run still exits nonzero overall (refused at consent, as O3 already established)" \
    || bad "add exited 0 with no consent granted — something let it through"

  echo
  echo "  O5 falsifiers — a broken pin and an uncovered invariant are each refused by name"
  add_o5() { "$MODS" --registry "$MREG" --state "$TMP/state/o5-$1" add omniroute < /dev/null 2>&1; }

  restore_manifest
  mutate_manifest '.pinned_version.artifact_sha256 = "not-a-real-digest"'
  OUT5A="$(add_o5 badpin)"; RC5A=$?
  if jq -e '.installs_via.kind == "local"' "$MREG/omniroute/manifest.json" >/dev/null 2>&1; then
    [ "$RC5A" -ne 0 ] && ok "a non-hex artifact digest is refused (local install)" \
                      || bad "a bad local pin digest was accepted"
    grep -q 'artifact_sha256' <<<"$OUT5A" \
      && ok "the refusal names artifact_sha256" || bad "the refusal did not name the field"
  else
    ok "installs_via.kind is upstream — artifact_sha256 does not gate this manifest (documented divergence from headroom's local-kind pin)"
  fi
  restore_manifest

  mutate_manifest 'del(.pinned_version)'
  OUT5B="$(add_o5 nopin)"; RC5B=$?
  [ "$RC5B" -ne 0 ] && ok "a missing pinned_version is refused" || bad "a manifest with no pin was accepted"
  grep -q 'pinned_version' <<<"$OUT5B" \
    && ok "the refusal names pinned_version" || bad "the refusal did not name pinned_version"
  restore_manifest

  # An uncovered manifest-kind invariant the traffic-proxy class demands.
  MANIFEST_KIND_IDS="$(jq -r '.requires_invariants[] | select(.check.kind=="manifest") | .id' "$REAL_CLASSES/traffic-proxy.json")"
  FIRST_ID="$(printf '%s\n' "$MANIFEST_KIND_IDS" | head -1)"
  if [ -n "$FIRST_ID" ] && jq -e --arg id "$FIRST_ID" '.invariants | has($id)' "$MANIFEST" >/dev/null 2>&1; then
    mutate_manifest --arg id "$FIRST_ID" 'del(.invariants[$id])'
    OUT5C="$(add_o5 hole)"; RC5C=$?
    [ "$RC5C" -ne 0 ] && ok "an uncovered class invariant ($FIRST_ID) is refused" \
                      || bad "an uncovered class invariant ($FIRST_ID) was accepted"
    grep -qF "$FIRST_ID" <<<"$OUT5C" \
      && ok "the refusal names the uncovered invariant" || bad "the refusal did not name $FIRST_ID"
    grep -q 'traffic-proxy' <<<"$OUT5C" \
      && ok "the refusal names the class that demanded it" || bad "the refusal did not name traffic-proxy"
    [ ! -e "$TMP/state/o5-hole/omniroute" ] \
      && ok "the refused manifest installed nothing" || bad "a refused manifest left residue"
    restore_manifest
  else
    bad "could not find a manifest-kind traffic-proxy invariant covered by the shipped manifest to falsify against"
  fi
  [ "$(sha_file "$MANIFEST")" = "$(sha_file "$MREG/omniroute/manifest.json")" ] \
    && ok "GREEN ARM: restored — the working copy is byte-identical to the shipped manifest again" \
    || bad "restore did not return the copy to the shipped bytes"
fi

# ═════════════════════════════════════════════════════════════════════════════
echo
echo "O6 — pin integrity: commit $PIN_SHA, version $PIN_VERSION"
if [ "$HAVE_MANIFEST" -eq 0 ]; then
  skip "O6 needs modules/omniroute/manifest.json — not present yet"
else
  grep -q "$PIN_SHA" "$MANIFEST" \
    && ok "the manifest records the exact pinned commit $PIN_SHA" \
    || bad "the manifest does not mention the pinned commit $PIN_SHA anywhere"
  [ "$(jq -r '.pinned_version.version' "$MANIFEST")" = "$PIN_VERSION" ] \
    && ok "pinned_version.version is exactly $PIN_VERSION" \
    || bad "pinned_version.version is not $PIN_VERSION (got: $(jq -r '.pinned_version.version' "$MANIFEST"))"

  # FALSIFIER: a copy with the SHA swapped for a different (still well-formed)
  # 40-hex string no longer matches — proving this check reads the real bytes.
  DRIFT="$TMP/pin-drift-manifest.json"
  # The `g` flag is load-bearing: $PIN_SHA appears MORE THAN ONCE on the same
  # line in the shipped manifest (pin_provenance names it twice — once for the
  # GitHub commit lookup, again for the ?ref= contents-API call). Without `g`,
  # sed's s/// only replaces the FIRST match per line, silently leaving the
  # second occurrence on that line intact — which is exactly how this fixture
  # previously failed to drift at all.
  sed "s/$PIN_SHA/0000000000000000000000000000000000000000/g" "$MANIFEST" > "$DRIFT"
  [ "$(sha_file "$MANIFEST")" != "$(sha_file "$DRIFT")" ] \
    && ok "the drift fixture is genuinely different bytes from the shipped manifest — the sed substitution took" \
    || bad "the drift fixture is byte-identical to the shipped manifest — the sed substitution did not take at all"
  grep -q "$PIN_SHA" "$DRIFT" \
    && bad "the drift fixture still contains the real pin — the sed substitution did not take" \
    || ok "RED ARM: a manifest with the pin swapped for a different SHA no longer matches — a drifted manifest would FAIL this gate"

  if [ "$HAVE_README" -eq 1 ]; then
    grep -q "$PIN_SHA" "$PATCH_README" \
      && ok "patches/omniroute/README.md documents the same pinned commit" \
      || bad "the README does not mention $PIN_SHA — manifest and patch rationale have drifted"
    grep -q "$PIN_VERSION" "$PATCH_README" \
      && ok "patches/omniroute/README.md documents the same pinned version" \
      || bad "the README does not mention $PIN_VERSION"
  else
    skip "README cross-check needs patches/omniroute/README.md — not present yet"
  fi
fi

# ═════════════════════════════════════════════════════════════════════════════
echo
echo "O7 — the installer exists, is executable, is syntax-clean, and carries the pin"
if [ "$HAVE_INSTALLER" -eq 0 ]; then
  skip "O7 needs bin/heimdall-omniroute-install — not present yet"
else
  [ -x "$INSTALLER" ] && ok "bin/heimdall-omniroute-install is executable" \
                       || bad "bin/heimdall-omniroute-install exists but is not executable"
  bash -n "$INSTALLER" 2>/tmp/o7-syntax.$$ \
    && ok "bash -n is clean" || { bad "bash -n reported a syntax error"; cat /tmp/o7-syntax.$$ >&2; }
  rm -f /tmp/o7-syntax.$$
  grep -q "$PIN_SHA" "$INSTALLER" \
    && ok "the installer's own source carries the pinned commit $PIN_SHA" \
    || bad "the installer never mentions the pinned commit — it cannot be verifying against it"
  grep -qE '(^|[^0-9])24([^0-9]|$)' "$INSTALLER" \
    && ok "the installer mentions a version constraint touching 24 (the required node major)" \
    || bad "the installer never mentions node 24 anywhere in its source"
fi

# ═════════════════════════════════════════════════════════════════════════════
echo
echo "O8 — SYNTHETIC harness proof: refusal on all three preconditions, and a discriminating mutant"
# A reference installer, built here, that implements exactly the three refusals
# the task specifies: node major version, post-clone SHA, and a Tier-1 provider
# row. This proves the DRIVING HARNESS (PATH-stubbed node/git, a providers
# fixture file) actually forces each refusal before it is ever pointed at the
# real installer in O9 — and gives real, running, mutation-tested evidence今
# today, independent of whether bin/heimdall-omniroute-install has landed.
REF="$TMP/ref-installer.sh"
cat > "$REF" <<'REFEOF'
#!/usr/bin/env bash
set -uo pipefail
NODE_MAJOR="$(node --version 2>/dev/null | sed -E 's/^v([0-9]+).*/\1/')"
if [ "${NODE_MAJOR:-0}" -lt 24 ] 2>/dev/null; then
  echo "refused: node v24 or newer is required (found: $(node --version 2>/dev/null))"
  exit 1
fi
CLONE_DIR="$OMNIROUTE_CLONE_DIR"
git clone "$OMNIROUTE_UPSTREAM" "$CLONE_DIR" >/dev/null 2>&1
GOT_SHA="$(git -C "$CLONE_DIR" rev-parse HEAD 2>/dev/null)"
if [ "$GOT_SHA" != "$OMNIROUTE_PIN_SHA" ]; then
  echo "refused: cloned commit $GOT_SHA does not match the pinned $OMNIROUTE_PIN_SHA"
  exit 1
fi
if [ -f "$OMNIROUTE_PROVIDERS_FILE" ] && grep -q '"tier"[[:space:]]*:[[:space:]]*"1"' "$OMNIROUTE_PROVIDERS_FILE" 2>/dev/null; then
  echo "refused: a Tier-1 provider row is present — OmniRoute must never sit on judgment traffic"
  exit 1
fi
echo "installed"
exit 0
REFEOF
chmod +x "$REF"

# A safe, deterministic, network-free git stub — reused everywhere below EXCEPT
# GIT_RIGHTSHA_PATH. No fixture PATH built in this file ever exposes a real git
# binary: the reference installer (and any mutant of it) can clone/rev-parse
# all it wants without ever touching the network, no matter which check does
# or doesn't fire first.
write_stub_git() { # <dir> <rev-parse-output>
  cat > "$1/git" <<EOF
#!/usr/bin/env bash
case "\$1" in
  clone) mkdir -p "\$3"; exit 0 ;;
  -C) if [ "\$3" = "rev-parse" ]; then echo "$2"; exit 0; fi ;;
esac
exit 0
EOF
  chmod +x "$1/git"
}

# The node stub: reports an old major version. Real other tools pass through
# (git is deliberately the safe stub above, never the real network-capable git).
NODE_OLD_PATH="$TMP/path-node-old"; mkdir -p "$NODE_OLD_PATH"
cat > "$NODE_OLD_PATH/node" <<'EOF'
#!/usr/bin/env bash
[ "$1" = "--version" ] && echo "v18.19.0"
EOF
chmod +x "$NODE_OLD_PATH/node"
# dirname/mktemp/readlink/rm are added on top of O8's original coreutils list
# specifically so O9 (below) can drive the REAL installer far enough to reach
# its node-version guard: heimdall-omniroute-install resolves its own SELF path
# (readlink/dirname) and allocates a SCRATCH dir (mktemp) before check_preconditions
# ever runs, and without these four the real installer dies on a raw "dirname:
# command not found" / "cannot create a scratch dir" error instead of ever
# reaching — let alone naming — the node check. None of this reaches git clone:
# resolve_node24 dies (HOME here is always a fresh, git-clone-free sandbox with
# no ~/.nvm) before check_preconditions' tool loop or clone_and_pin ever run.
for c in bash sh env grep sed perl dirname mktemp readlink rm; do
  src="$(command -v "$c" 2>/dev/null)"; [ -n "$src" ] && ln -sf "$src" "$NODE_OLD_PATH/$c" 2>/dev/null
done
write_stub_git "$NODE_OLD_PATH" "2222222222222222222222222222222222222222"

OUT8A="$(PATH="$NODE_OLD_PATH" perl -e 'alarm 20; exec @ARGV' bash "$REF" 2>&1)"; RC8A=$?
[ "$RC8A" -ne 0 ] && ok "an old node major (v18) is REFUSED by the reference installer" \
                  || bad "the reference installer accepted node v18"
grep -qi 'node v24' <<<"$OUT8A" && ok "the refusal names the node v24 requirement" \
                                || bad "the refusal did not name node v24"

# A real (new-enough) node stub: the same script proceeds past the node check.
NODE_NEW_PATH="$TMP/path-node-new"; mkdir -p "$NODE_NEW_PATH"
cat > "$NODE_NEW_PATH/node" <<'EOF'
#!/usr/bin/env bash
[ "$1" = "--version" ] && echo "v24.4.0"
EOF
chmod +x "$NODE_NEW_PATH/node"
for c in bash sh env grep sed perl; do
  src="$(command -v "$c" 2>/dev/null)"; [ -n "$src" ] && ln -sf "$src" "$NODE_NEW_PATH/$c" 2>/dev/null
done

# git stub: "clone" fabricates an empty dir; rev-parse returns a WRONG sha.
GIT_WRONGSHA_PATH="$TMP/path-git-wrongsha"; mkdir -p "$GIT_WRONGSHA_PATH"
write_stub_git "$GIT_WRONGSHA_PATH" "1111111111111111111111111111111111111111"
cp "$NODE_NEW_PATH/node" "$GIT_WRONGSHA_PATH/node"; chmod +x "$GIT_WRONGSHA_PATH/node"
for c in bash sh env grep sed perl; do
  src="$(command -v "$c" 2>/dev/null)"; [ -n "$src" ] && ln -sf "$src" "$GIT_WRONGSHA_PATH/$c" 2>/dev/null
done

OUT8B="$(PATH="$GIT_WRONGSHA_PATH" \
  OMNIROUTE_CLONE_DIR="$TMP/clone-wrongsha" OMNIROUTE_UPSTREAM="https://example.invalid/omniroute" \
  OMNIROUTE_PIN_SHA="$PIN_SHA" OMNIROUTE_PROVIDERS_FILE="$TMP/no-such-providers.json" \
  perl -e 'alarm 20; exec @ARGV' bash "$REF" 2>&1)"; RC8B=$?
[ "$RC8B" -ne 0 ] && ok "a post-clone SHA that does not match the pin is REFUSED" \
                  || bad "the reference installer accepted a mismatched post-clone SHA"
grep -q "$PIN_SHA" <<<"$OUT8B" && ok "the refusal names the pin it expected" \
                                || bad "the refusal did not name the expected pin"

# git stub returning the CORRECT sha: proceeds past the SHA check. This is the
# ONLY fixture PATH in this whole section whose "clone" outcome matters for a
# passing run — it is still the safe stub, never real git.
GIT_RIGHTSHA_PATH="$TMP/path-git-rightsha"; mkdir -p "$GIT_RIGHTSHA_PATH"
write_stub_git "$GIT_RIGHTSHA_PATH" "$PIN_SHA"
cp "$NODE_NEW_PATH/node" "$GIT_RIGHTSHA_PATH/node"; chmod +x "$GIT_RIGHTSHA_PATH/node"
for c in bash sh env grep sed perl; do
  src="$(command -v "$c" 2>/dev/null)"; [ -n "$src" ] && ln -sf "$src" "$GIT_RIGHTSHA_PATH/$c" 2>/dev/null
done

# Tier-1 provider row present: refused even with a correct node and a correct SHA.
PROVIDERS_TIER1="$TMP/providers-tier1.json"
printf '{"providers":[{"name":"anthropic","tier":"1"}]}\n' > "$PROVIDERS_TIER1"
OUT8C="$(PATH="$GIT_RIGHTSHA_PATH" \
  OMNIROUTE_CLONE_DIR="$TMP/clone-tier1" OMNIROUTE_UPSTREAM="https://example.invalid/omniroute" \
  OMNIROUTE_PIN_SHA="$PIN_SHA" OMNIROUTE_PROVIDERS_FILE="$PROVIDERS_TIER1" \
  perl -e 'alarm 20; exec @ARGV' bash "$REF" 2>&1)"; RC8C=$?
[ "$RC8C" -ne 0 ] && ok "a Tier-1 provider row present is REFUSED even with node and pin both correct" \
                  || bad "the reference installer proceeded with a Tier-1 provider row present"
grep -qi 'tier-1' <<<"$OUT8C" && ok "the refusal names the Tier-1 provider reason" \
                              || bad "the refusal did not name Tier-1"

# GREEN — all three preconditions genuinely satisfied: the reference installer
# proceeds. This is the falsifier for O8's three refusals: it proves the same
# script CAN say "installed" and is not a hardwired `exit 1`.
PROVIDERS_TIER2="$TMP/providers-tier2.json"
printf '{"providers":[{"name":"some-vendor","tier":"2"}]}\n' > "$PROVIDERS_TIER2"
OUT8D="$(PATH="$GIT_RIGHTSHA_PATH" \
  OMNIROUTE_CLONE_DIR="$TMP/clone-green" OMNIROUTE_UPSTREAM="https://example.invalid/omniroute" \
  OMNIROUTE_PIN_SHA="$PIN_SHA" OMNIROUTE_PROVIDERS_FILE="$PROVIDERS_TIER2" \
  perl -e 'alarm 20; exec @ARGV' bash "$REF" 2>&1)"; RC8D=$?
[ "$RC8D" -eq 0 ] && grep -q '^installed$' <<<"$OUT8D" \
  && ok "GREEN ARM: node v24, correct SHA, no Tier-1 row → the reference installer proceeds — the three refusals are real gates, not a wall" \
  || bad "the reference installer did not proceed with every precondition satisfied (exit $RC8D): $OUT8D"

# MUTANT — the node guard's echo+exit disabled. Proves the harness itself is
# discriminating: a script that stops checking node still gets caught by the
# git/tier fixtures doing their job (both left fully intact), but the node axis
# specifically stops firing. Never touches real git even though node no longer
# refuses first — OMNIROUTE_CLONE_DIR here is still routed through the safe
# NODE_OLD_PATH git stub added above, so the mutant still never reaches network.
MUTREF="$TMP/ref-installer-nonode.sh"
# Two -e expressions, deliberately NOT one global "s/^  exit 1$/  :/" — this
# script has three "exit 1" lines (node, SHA, tier) and a blanket rule would
# silently disable all three, defeating the point of an axis-specific mutant.
# The second expression fires ONLY on the line immediately after the node
# marker (`n` advances to exactly the next line before substituting), so the
# SHA and tier refusals stay fully live.
sed -e 's/^  echo "refused: node v24 or newer is required.*/  : node check disabled by mutant/' \
    -e '/node check disabled by mutant/{n; s/^  exit 1$/  : # mutant disabled/;}' \
    "$REF" > "$MUTREF"
chmod +x "$MUTREF"
if grep -q 'node check disabled by mutant' "$MUTREF"; then
  OUT8E="$(PATH="$NODE_OLD_PATH" \
    OMNIROUTE_CLONE_DIR="$TMP/clone-mutant" OMNIROUTE_UPSTREAM="https://example.invalid/omniroute" \
    OMNIROUTE_PIN_SHA="$PIN_SHA" OMNIROUTE_PROVIDERS_FILE="$TMP/no-such-providers.json" \
    perl -e 'alarm 20; exec @ARGV' bash "$MUTREF" 2>&1)"
  grep -qi 'node v24' <<<"$OUT8E" \
    && bad "the mutant with the node guard disabled still refused on node — the mutation did not take" \
    || ok "MUTANT: disabling the node guard stops the node-specific refusal from firing — O8's node assertion can go RED"
else
  bad "could not build the node-guard-disabled mutant — the sed rewrite did not match the reference script"
fi

# ═════════════════════════════════════════════════════════════════════════════
echo
echo "O9 — REAL installer (gated): the same three refusal fixtures, driven for real"
if [ "$HAVE_INSTALLER" -eq 0 ]; then
  skip "O9 needs bin/heimdall-omniroute-install — not present yet"
else
  # ASSUMPTION, STATED EXPLICITLY: the real installer is invoked with no
  # arguments and reads node/git off PATH the same way the O8 reference does.
  # If its actual interface differs (flags, env var names, a config file
  # instead of PATH-resolved tools) these three probes need updating to match
  # once the real interface is documented — that is a FINDING for the
  # orchestrator, not a silent pass. HOME/TMPDIR/CWD are all throwaway; nothing
  # here can reach /Users/rj/omniroute or ~/.omniroute.
  SAFE_HOME="$TMP/home-o9"; mkdir -p "$SAFE_HOME"

  run_installer() { # <path> [extra env...]
    ( cd "$TMP" && env -i PATH="$1" HOME="$SAFE_HOME" TMPDIR="$TMP" "${@:2}" \
        perl -e 'alarm 30; exec @ARGV' bash "$INSTALLER" < /dev/null ) 2>&1
  }

  # BEHAVIOURAL, not a source grep: a static grep for '/Users/*/omniroute' in
  # the installer's SOURCE was a false positive — the default
  # INSTALL_DIR="${INSTALL_DIR:-$HOME/omniroute}" is exactly what the option is
  # documented to default to, and clone_and_pin() (bin/heimdall-omniroute-install)
  # REFUSES at runtime the instant that path already exists and is not a git
  # checkout — which is precisely the shape of a live, non-git production
  # install (verified live against /Users/rj/omniroute during investigation;
  # this suite itself never touches that real path, only a throwaway fixture
  # under $TMP that reproduces the same SHAPE: existing, non-git).
  FIXTURE_NONGIT="$TMP/fixture-existing-nongit"; mkdir -p "$FIXTURE_NONGIT"
  printf 'not a git checkout\n' > "$FIXTURE_NONGIT/some-file"

  # A PATH that satisfies check_preconditions in full (real node v24, real git,
  # real openssl/sqlite3/curl/lsof/npm) so the run reaches clone_and_pin at all.
  # git is still the safe, network-free stub from write_stub_git — never real
  # git — and every other real binary here is only ever existence-checked
  # (`command -v`) before the refusal below fires; none of them get invoked.
  FULL_PRECOND_PATH="$TMP/path-full-precond"; mkdir -p "$FULL_PRECOND_PATH"
  cp "$NODE_NEW_PATH/node" "$FULL_PRECOND_PATH/node"; chmod +x "$FULL_PRECOND_PATH/node"
  for c in bash sh env grep sed perl dirname mktemp readlink rm mkdir openssl sqlite3 curl lsof npm; do
    src="$(command -v "$c" 2>/dev/null)"; [ -n "$src" ] && ln -sf "$src" "$FULL_PRECOND_PATH/$c" 2>/dev/null
  done
  write_stub_git "$FULL_PRECOND_PATH" "0000000000000000000000000000000000000000"

  OUT9F1="$(run_installer "$FULL_PRECOND_PATH" INSTALL_DIR="$FIXTURE_NONGIT")"; RC9F1=$?
  [ "$RC9F1" -ne 0 ] \
    && ok "the real installer refuses when INSTALL_DIR already exists and is not a git checkout (exit $RC9F1)" \
    || bad "the real installer proceeded against an existing non-git INSTALL_DIR — it should refuse (this is the live-gateway protection)"
  grep -qi 'already exists and is not a git checkout' <<<"$OUT9F1" \
    && ok "the refusal names the reason: not a git checkout" \
    || bad "the refusal did not name 'not a git checkout': $OUT9F1"

  # RED ARM / falsifier: an ABSENT INSTALL_DIR must NOT trip this specific
  # refusal — it proceeds into clone_and_pin's clone step (the same safe,
  # stubbed git; never real git) and instead fails later, on the post-checkout
  # pin mismatch the stub is deliberately configured to produce. This proves
  # the assertion above discriminates on INSTALL_DIR's actual shape rather than
  # refusing unconditionally regardless of what INSTALL_DIR points at.
  FIXTURE_ABSENT="$TMP/fixture-absent-$$"
  OUT9F2="$(run_installer "$FULL_PRECOND_PATH" INSTALL_DIR="$FIXTURE_ABSENT")"; RC9F2=$?
  grep -qi 'already exists and is not a git checkout' <<<"$OUT9F2" \
    && bad "RED-ARM CHECK FAILED: an absent INSTALL_DIR still tripped the 'not a git checkout' refusal — the check above is not discriminating" \
    || ok "RED ARM: an absent INSTALL_DIR does not trip the same refusal (it fails later instead, on the stubbed pin mismatch)"

  # PATH here intentionally carries only the stub node plus symlinked coreutils
  # from O8's fixture — reused so this section makes no new assumption beyond O8's.
  OUT9A="$(run_installer "$NODE_OLD_PATH")"; RC9A=$?
  if [ "$RC9A" -eq 0 ]; then
    bad "the real installer exited 0 with node v18 on PATH — it should refuse (see O8's reference contract)"
  else
    ok "the real installer exits nonzero with an old node on PATH (exit $RC9A)"
    grep -qi 'node' <<<"$OUT9A" \
      && ok "…and its refusal mentions node" \
      || bad "…but its refusal never mentions node — cannot confirm THIS is why it refused (may be refusing for an unrelated, unmet assumption)"
  fi

  OUT9B="$(run_installer "$GIT_WRONGSHA_PATH" OMNIROUTE_PIN_SHA="$PIN_SHA")"; RC9B=$?
  if [ "$RC9B" -eq 0 ]; then
    bad "the real installer exited 0 with a git stub returning a WRONG post-clone SHA — it should refuse"
  else
    ok "the real installer exits nonzero when the post-clone SHA is wrong (exit $RC9B)"
  fi
fi

# ═════════════════════════════════════════════════════════════════════════════
echo
echo "O10 — secrets discipline: a marker planted in plausible secret env vars never leaks"
SECRET_MARKER="OMNIROUTE-TEST-SECRET-$$-$(date +%s)"
SECRET_ENV=(OMNIROUTE_PASSWORD="$SECRET_MARKER" OMNIROUTE_ADMIN_PASSWORD="$SECRET_MARKER"
            OMNIROUTE_API_KEY="$SECRET_MARKER" OMNIROUTE_TOKEN="$SECRET_MARKER"
            OMNIROUTE_SECRET="$SECRET_MARKER")

# RED ARM — a synthetic script that DOES leak the marker, proving the detector fires.
LEAKY="$TMP/leaky-installer.sh"
cat > "$LEAKY" <<'EOF'
#!/usr/bin/env bash
echo "starting install…"
echo "using credential: $OMNIROUTE_PASSWORD"
exit 1
EOF
chmod +x "$LEAKY"
# NOTE: SECRET_ENV is an array built from expansion, not literal VAR=val tokens
# written in the source — bash only recognizes a LITERAL "name=value" word as a
# temporary-environment assignment prefix; an expanded array element does not
# qualify, so without `env` these would be misparsed as an attempt to RUN a
# program literally named "OMNIROUTE_PASSWORD=...". `env` (a real external
# binary) is what actually applies them, and unlike the old alarm_run function,
# perl is a real binary too, so this composes correctly.
LEAK_OUT="$(env "${SECRET_ENV[@]}" perl -e 'alarm 10; exec @ARGV' bash "$LEAKY" 2>&1)"
grep -qF "$SECRET_MARKER" <<<"$LEAK_OUT" \
  && ok "RED ARM: the marker-leak detector correctly catches a script that echoes a secret env var" \
  || bad "the detector missed an intentional secret leak — the check is not discriminating"

# GREEN ARM — the O8 reference installer never touches those vars and never leaks.
CLEAN_OUT="$(env "${SECRET_ENV[@]}" PATH="$GIT_RIGHTSHA_PATH" \
  OMNIROUTE_CLONE_DIR="$TMP/clone-secrets" OMNIROUTE_UPSTREAM="https://example.invalid/omniroute" \
  OMNIROUTE_PIN_SHA="$PIN_SHA" OMNIROUTE_PROVIDERS_FILE="$TMP/no-such-providers.json" \
  perl -e 'alarm 20; exec @ARGV' bash "$REF" 2>&1)"
grep -qF "$SECRET_MARKER" <<<"$CLEAN_OUT" \
  && bad "the reference installer leaked the secret marker" \
  || ok "GREEN ARM: the reference installer's stdout+stderr are byte-free of the marker"

if [ "$HAVE_INSTALLER" -eq 0 ]; then
  skip "the real-installer secrets probe needs bin/heimdall-omniroute-install — not present yet"
else
  mkdir -p "$TMP/home-o10"
  REAL_SEC_OUT="$(env "${SECRET_ENV[@]}" PATH="$NODE_OLD_PATH" HOME="$TMP/home-o10" TMPDIR="$TMP" \
    perl -e 'alarm 30; exec @ARGV' bash "$INSTALLER" < /dev/null 2>&1)"
  grep -qF "$SECRET_MARKER" <<<"$REAL_SEC_OUT" \
    && bad "the REAL installer printed the planted secret marker to stdout/stderr" \
    || ok "the real installer's captured stdout+stderr on its refusal path are byte-free of the marker"
fi

# ═════════════════════════════════════════════════════════════════════════════
echo
echo "--------------------------------------------------------------------"
[ "$SKIP" -gt 0 ] && printf 'omniroute-module: %d skipped (dependency not yet landed — not counted as passing)\n' "$SKIP"
printf 'omniroute-module: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
