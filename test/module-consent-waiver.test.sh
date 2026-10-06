#!/usr/bin/env bash
#
# module-consent-waiver.test.sh — acceptance for the PER-MODULE consent waiver
# (bin/heimdall-modules `obtain_consent` + `modules/headroom/manifest.json`).
#
# WHAT A WAIVER IS, AND WHAT IT DELIBERATELY IS NOT.
# Headroom ships as part of hmd. That is a distribution decision, so the add path
# must not stop and ask. The obvious way to do that is to flip `consent_required`
# to false in modules/_classes/traffic-proxy.json — and it is the wrong way, by a
# wide margin: that field governs the CLASS, so flipping it silently disarms
# consent for every traffic-proxy module hmd ever ships, forever, including ones
# nobody has written yet. The blast radius of a one-word edit would be the whole
# class.
#
# So the waiver is a PER-MODULE field on the module's own manifest
# (`consent_waived` + `consent_waived_reason`), and the class contract keeps
# `consent_required: true` untouched. A future traffic-proxy module is still
# gated unless it too carries an explicit, reasoned waiver.
#
# THE THREE THINGS A WAIVER MUST NOT TOUCH, each asserted below:
#   the DISCLOSURE   the operator is still TOLD, they are simply not ASKED. W3.
#   the INVARIANTS   waiving consent waives no class invariant. W8.
#   the REVERSIBILITY  add -> remove is still byte-identical. W10.
#
# AND THE ONE THING THAT MAKES IT DEFENSIBLE: it is declared. A silent waiver is
# indistinguishable from a bug, so an unexplained one is REFUSED at validate (W7)
# and a granted one is rendered in status and in the --json receipt (W5, W6).
#
# THIS SUITE OWNS ITS CONTROL PLANE. W9 runs the REAL headroom manifest through
# `add`, and its traffic-proxy `no-signed-traffic-routing` invariant curls
# $HEIMDALL_DEFAULT_CP_URL/readyz and FAILS CLOSED on anything but 200. Left at its
# baked-in default that is the LIVE production control plane, so W9 was a statement
# about the internet: when it did not answer — or the ambient env pinned the default
# at a dead port, which test/lib/net-default-guard.sh does on purpose for the
# presence corpus — seven assertions went RED (the real add failed, no
# invariants.json, no traffic-proxy or storage-codec invariant ran, the receipt hid
# the waiver), none of which says anything about consent. The suite now serves
# /readyz itself from a loopback stand-in (test/lib/hermetic-cp.sh, shared with
# headroom-module and omniroute-module). Consent, the manifest and the engine are
# untouched, and W10b proves the real waived add still FAILS CLOSED when that
# control plane is unreachable, so supplying a reachable one is not a weakening.
#
# Guarantees proved:
#   CP  the control plane W9's real add probes is a loopback stand-in this file
#       owns, and it is a real probe target (200 on /readyz, 404 everywhere else).
#   W1  Headroom's manifest declares the waiver explicitly, with a reason, and
#       still ships the disclosure text.
#   W2  the traffic-proxy CLASS contract is untouched — still consent_required,
#       and carries no waiver field of its own. This is the blast-radius guard:
#       it goes RED the moment somebody waives at the class level instead.
#   W3  a WAIVED module adds non-interactively with NO --yes and NO prompt, and
#       the disclosure is printed anyway.
#   W4  an UN-WAIVED module of the SAME real traffic-proxy class is still GATED.
#       This is the assertion that stops the waiver becoming a class-wide hole.
#   W5  the receipt records the waiver, its reason, and the hash of the text that
#       was disclosed — via --json, which is what the add path emits.
#   W6  `status` renders the waiver, installed AND not-installed. A waiver a
#       reader cannot see is the indefensible one.
#   W7  validate REFUSES a waiver with no reason, and one with no disclosure.
#   W8  a waiver waives CONSENT ONLY — a waived module that fails a class
#       invariant is still refused and rolled back.
#   W9  the REAL `hmd modules add headroom` runs past consent unprompted, and
#       both class contracts' invariants actually execute.
#   W10 `remove headroom` still leaves the tree BYTE-IDENTICAL to pre-add.
#   W10b a waiver waives CONSENT ONLY, on the REAL manifest: with the control plane
#       its no-signed-traffic-routing invariant probes unreachable, the same waived
#       add gets past consent, is REFUSED at step 7 and rolls back byte-identically.
#       The falsifier for the stand-in control plane W9 runs against.
#   W11 FALSIFIER FOR W3 — strip the waiver from the same manifest and the very
#       same add GATES again. The RED/GREEN pair is what makes W3 mean something
#       rather than passing against a tool that never gated anybody.
#
# Usage:  bash test/module-consent-waiver.test.sh   (exit 0 = every guarantee holds)
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SELF_DIR/.." && pwd)"
MODS="$REPO/bin/heimdall-modules"
REAL_REG="$REPO/modules"
REAL_CLASSES="$REAL_REG/_classes"

command -v jq >/dev/null 2>&1 || { echo "error: jq is required" >&2; exit 2; }

PASS=0; FAIL=0
ok()  { printf '  \033[32mPASS\033[0m %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAIL=$((FAIL+1)); }

TMP="$(mktemp -d)"
# NEVER touch the operator's real ~/.heimdall — it holds a live team secret and
# PKI. Every child process in this file gets a throwaway HOME.
export HOME="$TMP/home"
mkdir -p "$HOME"
trap 'rm -rf "$TMP"' EXIT

REG="$TMP/registry"
STATE="$TMP/state/modules"

# Same reasoning as the throwaway HOME above: a precondition this file does not
# control must not decide its verdict. hmd's generic preflight floor is 4096 MB,
# sized for a real Rust+ONNX payload rather than these one-file fixtures, and
# preflight runs at [3/7] — BEFORE consent at [4/7]. Left ambient on a machine at
# ~2 GB free, every add is refused for disk and the consent arms never execute at
# all: the waiver assertions then fail reporting "the disclosure was never shown",
# which is true and entirely about the laptop. Pinned so consent is what gets
# judged. The library documents the override ("overridable so a test can pin both
# sides of the boundary"); the floor is proven in module-preflight-wiring.
export HMD_PREFLIGHT_DISK_FLOOR_MB=1

# THE SAME RULE, APPLIED TO THE NETWORK — see "THIS SUITE OWNS ITS CONTROL PLANE"
# in the header. Started before any add runs, and verified (CP section) before any
# add result is read as a statement about consent.
# shellcheck source=/dev/null  # sibling helper test/lib/hermetic-cp.sh; not followed (no -x)
. "$SELF_DIR/lib/hermetic-cp.sh"
hermetic_cp_start "$TMP" || exit 2
hermetic_cp_selfcheck

hmd()      { "$MODS" --registry "$REG"      --state "$STATE" "$@"; }
hmd_real() { "$MODS" --registry "$REAL_REG" --state "$STATE" "$@"; }

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

# The temp registry carries the REAL class contracts. That is the point: the
# synthetic modules below are genuinely traffic-proxy class, judged by the same
# contract Headroom is judged by, so W4's refusal is the real gate refusing and
# not a fixture pretending to.
mkdir -p "$REG"
cp -R "$REAL_CLASSES" "$REG/_classes"

# A synthetic traffic-proxy module. `installs_via.kind` is "local" so the add
# hashes a real artifact and never reaches for the network. The two manifest-kind
# invariants the real contract requires are supplied and deliberately CHEAP —
# consent is decided at step 4, long before step 7 runs them, so what they assert
# is irrelevant to every assertion except W8, which overrides them on purpose.
mkproxy() { # <name> [extra JSON merged over the manifest]
  local name="$1" extra="${2:-}"
  [ -n "$extra" ] || extra='{}'
  mkdir -p "$REG/$name"
  printf 'synthetic traffic-proxy payload for %s\n' "$name" > "$REG/$name/artifact.bin"
  jq -n --arg n "$name" --arg sha "$(sha_file "$REG/$name/artifact.bin")" \
        --argjson extra "$extra" '
    { name:$n, description:("synthetic traffic-proxy " + $n),
      upstream:("https://example.invalid/" + $n), license:"MIT",
      pinned_version:{version:"1.0.0", artifact:"artifact.bin", artifact_sha256:$sha},
      permission_class:"traffic-proxy",
      installs_via:{kind:"local", artifact_path:"artifact.bin"},
      wires:[{kind:"env", target:"SYNTHETIC_TARGET"}],
      invariants:{
        "non-interactive-passthrough":{command:"printf PASSTHROUGH-OK", expect:"PASSTHROUGH-OK"},
        "no-signed-traffic-routing":{command:"printf BYPASS-OK", expect:"BYPASS-OK"},
        "gates-read-raw":{command:"printf 25 passed, 0 failed", expect:"25 passed, 0 failed"}
      },
      tier:"available",
      consent_text:("Synthetic disclosure for " + $n + ".")
    } * $extra' > "$REG/$name/manifest.json"
}

# ═════════════════════════════════════════════════════════════════════════════
echo
echo "W1 — Headroom declares the waiver explicitly, and keeps the disclosure"
HMF="$REAL_REG/headroom/manifest.json"
if [ -f "$HMF" ]; then ok "headroom manifest exists"; else bad "headroom manifest missing"; fi
if [ "$(jq -r '.consent_waived // "absent"' "$HMF")" = "true" ]; then
  ok "consent_waived is true — the waiver is declared, not implied"
else
  bad "headroom carries no consent_waived (got: $(jq -r '.consent_waived // "absent"' "$HMF"))"
fi
if jq -e '.consent_waived | type == "boolean"' "$HMF" >/dev/null 2>&1; then
  ok "consent_waived is a boolean"
else
  bad "consent_waived is not a boolean"
fi
WR="$(jq -r '.consent_waived_reason // ""' "$HMF")"
if [ -n "$WR" ]; then
  ok "consent_waived_reason is present — the waiver says WHY"
else
  bad "no consent_waived_reason: an unexplained waiver reads as a bug"
fi
if [ "${#WR}" -ge 60 ]; then
  ok "the reason is a real explanation, not a shrug (${#WR} chars)"
else
  bad "consent_waived_reason is too short to be a reason (${#WR} chars)"
fi
if [ -n "$(jq -r '.consent_text // ""' "$HMF")" ]; then
  ok "consent_text SURVIVES the waiver — disclosure is not deleted"
else
  bad "the waiver deleted the disclosure text"
fi
if jq -e . "$HMF" >/dev/null 2>&1; then ok "headroom manifest is still valid JSON"; else bad "manifest is not valid JSON"; fi

echo
echo "W2 — the CLASS contract is untouched (the blast-radius guard)"
TPC="$REAL_CLASSES/traffic-proxy.json"
if [ "$(jq -r '.consent_required' "$TPC")" = "true" ]; then
  ok "traffic-proxy STILL requires consent — the waiver did not flip the class"
else
  bad "traffic-proxy consent_required is no longer true — the waiver widened to the whole class"
fi
if jq -e 'has("consent_waived") | not' "$TPC" >/dev/null 2>&1; then
  ok "the class contract carries no consent_waived of its own"
else
  bad "a waiver was placed on the CLASS — that exempts every traffic-proxy module ever shipped"
fi
for cls in storage-codec rule-pack tool-adapter; do
  if jq -e 'has("consent_waived") | not' "$REAL_CLASSES/$cls.json" >/dev/null 2>&1; then
    ok "$cls contract carries no class-level waiver"
  else
    bad "$cls contract carries a class-level waiver"
  fi
done

echo
echo "W3 — a WAIVED module adds unprompted, and still discloses"
mkproxy shipped '{"consent_waived":true,
                 "consent_waived_reason":"synthetic fixture waiver for the acceptance test"}'
OUT="$(hmd add shipped < /dev/null 2>&1)"; RC=$?
if [ "$RC" -eq 0 ]; then
  ok "a waived module adds non-interactively with NO --yes (exit 0)"
else
  bad "waived add still failed (exit $RC)"
fi
if grep -qF 'Synthetic disclosure for shipped.' <<<"$OUT"; then
  ok "the disclosure text is PRINTED — told, not asked"
else
  bad "the disclosure was never shown"
fi
if grep -qi 'Install it? \[y/N\]' <<<"$OUT"; then
  bad "it still prompted"
else
  ok "no [y/N] prompt was issued"
fi
if grep -qi 'waived' <<<"$OUT"; then
  ok "the output says out loud that consent was waived"
else
  bad "the waiver happened silently — a reader cannot tell they were not asked"
fi
if grep -qF 'synthetic fixture waiver for the acceptance test' <<<"$OUT"; then
  ok "the REASON is printed at add time"
else
  bad "the reason was not shown"
fi
# The pipeline still ran in order, consent included as a real step.
if grep -q '\[4/7\] consent' <<<"$OUT"; then
  ok "step 4 still RUNS — the waiver answers it, it does not delete it"
else
  bad "the consent step vanished from the pipeline"
fi

echo
echo "W4 — an UN-WAIVED module of the same real class is STILL GATED"
mkproxy gated
OUT4="$(hmd add gated < /dev/null 2>&1)"; RC4=$?
if [ "$RC4" -ne 0 ]; then
  ok "an un-waived traffic-proxy module is REFUSED without consent (exit $RC4)"
else
  bad "an un-waived traffic-proxy module installed with nobody asked — the waiver leaked to the class"
fi
if grep -qi 'consent is required' <<<"$OUT4"; then
  ok "it says consent is required"
else
  bad "no consent-required message"
fi
if [ ! -f "$STATE/gated/receipt.json" ]; then
  ok "nothing was installed for the un-waived module"
else
  bad "the un-waived module left a receipt"
fi
# ...and it is grantable the normal way, so the gate is a gate and not a wall.
OUT4B="$(hmd add gated --yes 2>&1)"; RC4B=$?
if [ "$RC4B" -eq 0 ]; then ok "--yes still grants consent the normal way"; else bad "--yes broke (exit $RC4B): $OUT4B"; fi
if [ "$(jq -r '.consent.granted_via' "$STATE/gated/receipt.json" 2>/dev/null)" = "--yes" ]; then
  ok "the un-waived receipt records the ordinary grant path"
else
  bad "grant path not recorded"
fi
if [ "$(jq -r '.consent.waived // false' "$STATE/gated/receipt.json" 2>/dev/null)" = "false" ]; then
  ok "the un-waived receipt is NOT marked waived"
else
  bad "an ordinary grant was recorded as a waiver"
fi
hmd remove gated >/dev/null 2>&1

echo
echo "W5 — the receipt records the waiver, the reason, and the disclosed text"
R="$STATE/shipped/receipt.json"
if [ "$(jq -r '.consent.required' "$R" 2>/dev/null)" = "true" ]; then
  ok "the receipt still says consent WAS required by the class"
else
  bad "the receipt pretends consent was never required"
fi
if [ "$(jq -r '.consent.waived' "$R" 2>/dev/null)" = "true" ]; then
  ok "the receipt records that it was waived"
else
  bad "the receipt hides the waiver"
fi
if [ "$(jq -r '.consent.granted_via' "$R" 2>/dev/null)" = "manifest-waiver" ]; then
  ok "granted_via names the waiver, distinctly from --yes and interactive"
else
  bad "granted_via does not distinguish a waiver from a human saying yes"
fi
if [ -n "$(jq -r '.consent.waived_reason // ""' "$R" 2>/dev/null)" ]; then
  ok "the receipt carries the reason"
else
  bad "the receipt drops the reason"
fi
if [ -n "$(jq -r '.consent.consent_text_sha256 // ""' "$R" 2>/dev/null)" ]; then
  ok "the receipt pins the hash of the text that was DISCLOSED"
else
  bad "no hash of the disclosed text"
fi
# The hash must be the hash of the real text, not a placeholder.
EXPECT_SHA="$(printf '%s' "$(jq -r '.consent_text' "$REG/shipped/manifest.json")" | shasum -a 256 | awk '{print $1}')"
if [ "$(jq -r '.consent.consent_text_sha256' "$R")" = "$EXPECT_SHA" ]; then
  ok "the pinned hash matches the manifest's disclosure text exactly"
else
  bad "the pinned hash is not the hash of the shown text"
fi
# The --json add receipt is the machine-readable surface the requirement names.
hmd remove shipped >/dev/null 2>&1
# `--json add` prints the human progress lines first and the receipt after, and
# jq pretty-prints it, so the JSON is the block from the first bare `{` onward —
# NOT the last line, which is just a closing brace.
J="$(hmd --json add shipped < /dev/null 2>/dev/null | awk '/^\{$/{f=1} f')"
if printf '%s' "$J" | jq -e . >/dev/null 2>&1; then
  ok "--json add emits valid JSON"
else
  bad "--json add emitted invalid JSON"
fi
if [ "$(printf '%s' "$J" | jq -r '.receipt.consent.waived')" = "true" ]; then
  ok "the --json receipt exposes the waiver"
else
  bad "--json receipt hides the waiver"
fi
if [ -n "$(printf '%s' "$J" | jq -r '.receipt.consent.waived_reason // ""')" ]; then
  ok "the --json receipt exposes the reason"
else
  bad "--json receipt drops the reason"
fi

echo
echo "W6 — status renders the waiver, installed and not-installed"
S="$(hmd status shipped 2>&1)"
if grep -qi 'waived' <<<"$S"; then
  ok "status on an INSTALLED waived module shows the waiver"
else
  bad "status hides the waiver on an installed module"
fi
if grep -qF 'synthetic fixture waiver for the acceptance test' <<<"$S"; then
  ok "status shows the REASON"
else
  bad "status shows no reason"
fi
SJ="$(hmd --json status shipped 2>/dev/null)"
if [ "$(printf '%s' "$SJ" | jq -r '.receipt.consent.waived')" = "true" ]; then
  ok "--json status exposes the waiver"
else
  bad "--json status hides the waiver"
fi
hmd remove shipped >/dev/null 2>&1
# NOT-INSTALLED is the state a reader is actually in when they go looking, so the
# waiver has to be visible there too or it is only ever visible after the fact.
S2="$(hmd status shipped 2>&1)"
if grep -qi 'waived' <<<"$S2"; then
  ok "status on a NOT-INSTALLED waived module still discloses the waiver"
else
  bad "the waiver is invisible until after it has already been applied"
fi
SJ2="$(hmd --json status shipped 2>/dev/null)"
if [ "$(printf '%s' "$SJ2" | jq -r '.consent_waiver.waived // false')" = "true" ]; then
  ok "--json status exposes the waiver before install"
else
  bad "--json status hides the pre-install waiver"
fi

echo
echo "W7 — an UNEXPLAINED or UNDISCLOSED waiver is REFUSED at validate"
mkproxy mute '{"consent_waived":true}'
OUT7="$(hmd add mute < /dev/null 2>&1)"; RC7=$?
if [ "$RC7" -ne 0 ]; then
  ok "a waiver with no reason is refused"
else
  bad "a silent waiver was accepted — that is the indefensible one"
fi
if grep -qi 'consent_waived_reason' <<<"$OUT7"; then
  ok "the refusal names the missing field"
else
  bad "the refusal does not say what is missing"
fi
if [ ! -f "$STATE/mute/receipt.json" ]; then ok "the refused waiver installed nothing"; else bad "left a receipt"; fi

mkproxy nodisclose '{"consent_waived":true,"consent_waived_reason":"a reason long enough to be a real explanation of the decision","consent_text":null}'
OUT7B="$(hmd add nodisclose < /dev/null 2>&1)"; RC7B=$?
if [ "$RC7B" -ne 0 ]; then
  ok "a waiver that also drops the disclosure is refused"
else
  bad "a module waived consent AND shipped no disclosure — nobody is told anything"
fi
if grep -qi 'consent_text' <<<"$OUT7B"; then
  ok "the refusal names the missing disclosure field"
else
  bad "the refusal does not name consent_text, so it cannot be told apart from an unrelated failure: $OUT7B"
fi

mkproxy notbool '{"consent_waived":"yes","consent_waived_reason":"a reason long enough to be a real explanation of the decision"}'
OUT7C="$(hmd add notbool < /dev/null 2>&1)"; RC7C=$?
if [ "$RC7C" -ne 0 ]; then
  ok "a non-boolean consent_waived is refused, never coerced"
else
  bad "a string \"yes\" was coerced into a waiver"
fi
if grep -qi 'must be a boolean' <<<"$OUT7C"; then
  ok "the refusal says consent_waived must be a boolean"
else
  bad "the refusal does not say consent_waived must be a boolean, so it cannot be told apart from an unrelated failure: $OUT7C"
fi

echo
echo "W8 — a waiver waives CONSENT ONLY; class invariants still bite"
# The broken invariant is a MANIFEST-kind one on purpose. `gates-read-raw` is a
# SUITE check, which means the CLASS owns its command and a manifest physically
# cannot override it — a module is structurally incapable of weakening the
# judgment falsifier, which is a stronger guarantee than this test asserting it.
# So the deliberate break goes where a module CAN reach, and the suite check is
# asserted separately below to stay class-owned.
mkproxy shippedbad '{"consent_waived":true,
                    "consent_waived_reason":"synthetic fixture waiver whose invariant is deliberately broken",
                    "invariants":{"non-interactive-passthrough":{"command":"printf INVARIANT-DELIBERATELY-BROKEN","expect":"PASSTHROUGH-OK"}}}'
PRE8="$(tree_sum "$STATE")"
OUT8="$(hmd add shippedbad < /dev/null 2>&1)"; RC8=$?
if [ "$RC8" -ne 0 ]; then
  ok "a WAIVED module that fails a class invariant is still REFUSED"
else
  bad "the waiver skipped the invariants — consent and invariants got conflated"
fi
if grep -q 'FAILED INVARIANT' <<<"$OUT8"; then
  ok "the refusal names the failed invariant"
else
  bad "no invariant failure reported"
fi
if [ "$(tree_sum "$STATE")" = "$PRE8" ]; then
  ok "the failed waived module rolled back byte-identically"
else
  bad "left residue"
fi
# A module cannot weaken the class-owned falsifier even by naming it. Proven by
# handing a WAIVED module a green-looking gates-read-raw command and watching the
# real suite command run instead of the manifest's.
mkproxy shippedliar '{"consent_waived":true,
                      "consent_waived_reason":"synthetic fixture waiver that tries to redefine a class-owned suite check",
                      "invariants":{"gates-read-raw":{"command":"printf 25 passed, 0 failed","expect":"25 passed, 0 failed"}}}'
hmd add shippedliar < /dev/null >/dev/null 2>&1
GRR="$(jq -r '.[] | select(.id == "gates-read-raw") | .command' "$STATE/shippedliar/invariants.json" 2>/dev/null)"
if grep -q 'test/gate-judgment-uncompressed.test.sh' <<<"$GRR"; then
  ok "a waived module CANNOT redefine the class-owned judgment falsifier"
else
  bad "the manifest overrode a class-owned suite check (ran: $GRR)"
fi
if [ "$(jq -r '.[] | select(.id == "gates-read-raw") | .source' "$STATE/shippedliar/invariants.json" 2>/dev/null)" = "class-contract" ]; then
  ok "the receipt attributes that check to the CLASS, not the manifest"
else
  bad "gates-read-raw was attributed to the manifest"
fi
hmd remove shippedliar >/dev/null 2>&1

echo
echo "W9 — the REAL headroom add runs past consent unprompted"
RSTATE="$TMP/realstate/modules"
REAL_PRE="$(tree_sum "$RSTATE")"
OUT9="$("$MODS" --registry "$REAL_REG" --state "$RSTATE" add headroom < /dev/null 2>&1)"; RC9=$?
if [ "$RC9" -eq 0 ]; then
  ok "hmd modules add headroom SUCCEEDS non-interactively (exit 0)"
else
  bad "real headroom add failed (exit $RC9)"
fi
if grep -q '\[4/7\] consent' <<<"$OUT9"; then
  ok "it reaches step 4"
else
  bad "never reached the consent step"
fi
if grep -qi 'Install it? \[y/N\]' <<<"$OUT9"; then
  bad "the real add still prompted"
else
  ok "the real add did NOT prompt"
fi
if grep -qF 'Headroom is a local context-compression proxy.' <<<"$OUT9"; then
  ok "the real disclosure is printed in full"
else
  bad "the real disclosure was not shown"
fi
if grep -q '\[7/7\] class invariants' <<<"$OUT9"; then
  ok "it reaches step 7 — the waiver did not short-circuit the pipeline"
else
  bad "never reached the invariants"
fi
# Both classes' invariants must actually have executed, waiver or no waiver.
INV="$RSTATE/headroom/invariants.json"
if [ -f "$INV" ]; then ok "invariant evidence was recorded"; else bad "no invariants.json"; fi
N_TP="$(jq -r '[.[] | select(.class == "traffic-proxy")] | length' "$INV" 2>/dev/null || echo 0)"
N_SC="$(jq -r '[.[] | select(.class == "storage-codec")] | length' "$INV" 2>/dev/null || echo 0)"
case "$N_TP" in ''|*[!0-9]*) N_TP=0 ;; esac
case "$N_SC" in ''|*[!0-9]*) N_SC=0 ;; esac
if [ "$N_TP" -ge 3 ]; then
  ok "the traffic-proxy contract's invariants ran"
else
  bad "traffic-proxy invariants did not run"
fi
if [ "$N_SC" -ge 1 ]; then
  ok "the storage-codec contract's invariants ran (dual class preserved)"
else
  bad "storage-codec invariants did not run"
fi
if jq -e 'all(.[]; .passed)' "$INV" >/dev/null 2>&1; then
  ok "every invariant PASSED with the module active"
else
  bad "an invariant failed"
fi
if jq -e 'any(.[]; .id == "gates-read-raw" and .source == "class-contract")' "$INV" >/dev/null 2>&1; then
  ok "the class-owned judgment falsifier ran from the CLASS contract"
else
  bad "gates-read-raw did not run from the class contract"
fi
if [ "$(jq -r '.consent.waived' "$RSTATE/headroom/receipt.json" 2>/dev/null)" = "true" ]; then
  ok "the real receipt records the waiver"
else
  bad "the real receipt hides the waiver"
fi
RS="$("$MODS" --registry "$REAL_REG" --state "$RSTATE" status headroom 2>&1)"
if grep -qi 'waived' <<<"$RS"; then
  ok "hmd modules status headroom shows the waiver"
else
  bad "real status hides the waiver"
fi

echo
echo "W10 — remove headroom is still byte-identical reversibility"
"$MODS" --registry "$REAL_REG" --state "$RSTATE" remove headroom >/dev/null 2>&1
if [ "$(tree_sum "$RSTATE")" = "$REAL_PRE" ]; then
  ok "add -> remove leaves the tree byte-identical (waiver did not cost reversibility)"
else
  bad "removal left residue"
fi
REG_SUM_NOW="$(tree_sum "$REAL_REG")"
if [ -n "$REG_SUM_NOW" ]; then ok "the registry is readable after the round trip"; else bad "registry unreadable"; fi

echo
echo "W10b — a waiver waives CONSENT ONLY, on the REAL manifest: an unreachable control plane still REFUSES"
# W8 proves it with a synthetic broken invariant. This is the same property against the
# REAL headroom manifest and the REAL no-signed-traffic-routing invariant, and it is what
# keeps W9's green — taken against the stand-in control plane this file supplies — from
# reading as a weakening: ONE difference from W9, the control plane that invariant probes
# is a loopback port nothing listens on. The waived add still gets past consent (step 4)
# and must then be REFUSED at step 7 and rolled back byte-identically. An unreachable
# check fails closed; it never passes.
DSTATE="$TMP/downstate/modules"
DPRE="$(tree_sum "$DSTATE")"
OUT10B="$(env HEIMDALL_DEFAULT_CP_URL="$(hermetic_cp_dead_url)" \
            "$MODS" --registry "$REAL_REG" --state "$DSTATE" add headroom < /dev/null 2>&1)"; RC10B=$?
if [ "$RC10B" -ne 0 ]; then
  ok "the REAL waived add is REFUSED when the control plane is unreachable (exit $RC10B)"
else
  bad "the real waived add succeeded with an unreachable control plane — an unverifiable invariant PASSED"
fi
if grep -q '\[4/7\] consent' <<<"$OUT10B" && ! grep -qi 'Install it? \[y/N\]' <<<"$OUT10B"; then
  ok "it got past consent unprompted — the waiver did its job and nothing more"
else
  bad "the refusal did not come after a waived, unprompted consent step"
fi
if grep -q 'FAILED INVARIANT: no-signed-traffic-routing' <<<"$OUT10B"; then
  ok "the refusal names the invariant that could not be verified — the waiver did not skip it"
else
  bad "the refusal did not name no-signed-traffic-routing: $(printf '%s\n' "$OUT10B" | tail -8)"
fi
if [ "$(tree_sum "$DSTATE")" = "$DPRE" ]; then
  ok "the refused waived add rolled back byte-identically"
else
  bad "the refused waived add left residue"
fi

echo
echo "W11 — FALSIFIER: strip the waiver and the SAME add gates again"
# A copy of the real manifest with `consent_waived` removed. If the add still
# sails through, the waiver is not what let it through and W3/W9 prove nothing.
FALSIFY_REG="$TMP/falsify"
mkdir -p "$FALSIFY_REG/headroom"
cp -R "$REAL_CLASSES" "$FALSIFY_REG/_classes"
jq 'del(.consent_waived, .consent_waived_reason)' "$HMF" > "$FALSIFY_REG/headroom/manifest.json"
OUT11="$("$MODS" --registry "$FALSIFY_REG" --state "$TMP/fstate/modules" add headroom < /dev/null 2>&1)"; RC11=$?
if [ "$RC11" -ne 0 ]; then
  ok "with the waiver REMOVED, the identical add is GATED again (exit $RC11)"
else
  bad "the add succeeded without the waiver — the waiver is not the thing letting it through"
fi
if grep -qi 'consent is required' <<<"$OUT11"; then
  ok "the un-waived headroom refusal names consent as the reason"
else
  bad "refused for some other reason — the RED/GREEN pair does not isolate consent"
fi
if [ ! -f "$TMP/fstate/modules/headroom/receipt.json" ]; then
  ok "the gated add installed nothing"
else
  bad "the gated add left a receipt"
fi

echo
echo "--------------------------------------------------------------------"
printf 'module-consent-waiver: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
