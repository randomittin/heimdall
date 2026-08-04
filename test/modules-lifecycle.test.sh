#!/usr/bin/env bash
#
# modules-lifecycle.test.sh — acceptance for the module system core
# (bin/heimdall-modules + modules/_classes/*.json).
#
# THE PROPERTY THIS FILE EXISTS TO PROVE. A module that fails its own class test
# must leave NO TRACE. `add` and `remove` share one removal path, and an
# invariant failure calls exactly that path, so a REJECTED module and a REMOVED
# module are byte-identical outcomes. "It half-installed" is the failure mode
# that eats an afternoon; this file is what stops it shipping.
#
# WHY THE ROUND-TRIP IS CHECKSUMMED AND THEN DELIBERATELY BROKEN. A byte-identity
# assertion that cannot fail proves nothing — it would "pass" against a tool that
# never wrote anything at all. So G7 PLANTS residue and asserts the checksum goes
# RED, then clears it and asserts GREEN. The positive is what makes the negative
# mean something. (That method caught a live data-loss bug in this repo.)
#
# FIXTURES, AND WHY THERE ARE TWO KINDS. The mechanism tests run against FIXTURE
# class contracts in a temp registry, because the real traffic-proxy contract
# runs the full judgment falsifier and the mechanism does not need to pay that
# cost on every assertion. Building a fixture class the harness has never seen
# and watching it get enforced IS the proof that classes are DATA, not code —
# nothing in the binary knows these class names. The REAL contracts are then
# asserted separately (G3, G4), including that they still consume the judgment
# falsifier at 25/0 and that the falsifier itself is unmodified.
#
# Guarantees proved:
#   G1  binary exists, is executable, -h exits 0.
#   G2  `list` with NOTHING installed is honest — exit 0, says none, no error,
#       no fabricated entry.
#   G3  the four real class contracts are valid and DATA-DRIVEN (each carries
#       consent_required + a non-empty requires_invariants list).
#   G4  the traffic-proxy and storage-codec contracts consume the judgment
#       falsifier pinned at "25 passed, 0 failed", and that falsifier is
#       UNMODIFIED vs git HEAD (it must not be weakened to make a class pass).
#   G5  ADD happy path runs the whole ordered pipeline and records receipt +
#       wiring + invariant results.
#   G6  ROUND-TRIP: add -> remove leaves the tree BYTE-IDENTICAL to pre-add,
#       proven by checksum, and never mutates the registry.
#   G7  FALSIFIER FOR G6 — planted residue turns the checksum RED, clearing it
#       turns it GREEN. The round-trip assertion can fail, so its pass counts.
#   G8  a manifest with a MISSING permission_class is REFUSED, not defaulted.
#   G9  a manifest with an UNKNOWN permission_class is REFUSED, and says which
#       classes are valid.
#   G10 a module failing a class invariant at add-time is NOT WIRED, says why,
#       and rolls back byte-identically.
#   G11 a manifest that does not COVER a required invariant is refused and names
#       the uncovered id — a hole in a class contract is never silently allowed.
#   G12 digest MISMATCH is refused; nothing is installed.
#   G13 digest is reported honestly — "verified" only when an artifact was
#       actually hashed; an upstream dependency reads "deferred-upstream".
#   G14 consent: a consent_required class refuses a non-interactive add without
#       --yes, and records the grant when --yes is passed.
#   G15 consent: a class that does not require it installs without prompting.
#   G16 tier: "suggested" without tier_evidence is refused; with it, accepted.
#   G17 PINS, NOT LATEST — `update` at the manifest's pin is a no-op, and the
#       binary contains no fetch/clone path at all.
#   G18 base install ships the SYSTEM and ZERO module payloads, and adds no new
#       runtime dependency.
#   G19 `verify` is a real CI gate — green while the invariant holds, RED the
#       moment it regresses.
#   G20 --json emits valid JSON on every read verb.
#
# Usage:  bash test/modules-lifecycle.test.sh   (exit 0 = every guarantee holds)
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SELF_DIR/.." && pwd)"
MODS="$REPO/bin/heimdall-modules"
REAL_CLASSES="$REPO/modules/_classes"

command -v jq >/dev/null 2>&1 || { echo "error: jq is required" >&2; exit 2; }

PASS=0; FAIL=0
ok()  { printf '  \033[32mPASS\033[0m %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAIL=$((FAIL+1)); }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

REG="$TMP/registry"
# Deliberately NOT created: `add` must create it and `remove` must prune it back
# out of existence. "The directory came back" is residue too.
STATE="$TMP/state/modules"

hmd() { "$MODS" --registry "$REG" --state "$STATE" "$@"; }

sha_file() { shasum -a 256 "$1" | awk '{print $1}'; }

# A deterministic fingerprint of a tree that distinguishes ABSENT from EMPTY —
# an add that leaves an empty directory behind has still left residue.
tree_sum() {
  [ -e "$1" ] || { printf 'ABSENT\n'; return 0; }
  ( cd "$1" && find . -mindepth 1 | LC_ALL=C sort | while IFS= read -r p; do
      if [ -d "$p" ]; then printf 'd %s\n' "$p"
      else printf 'f %s %s\n' "$p" "$(sha_file "$p")"
      fi
    done ) | shasum -a 256 | awk '{print $1}'
}

# ── Fixture builders ─────────────────────────────────────────────────────────
mkclass() { # <name> <consent_required:true|false> <requires_invariants JSON array>
  mkdir -p "$REG/_classes"
  jq -n --arg c "$1" --argjson consent "$2" --argjson inv "$3" \
    '{class:$c, version:"1", summary:"fixture class",
      why_this_class_exists:"fixture", consent_required:$consent,
      consent_rationale:"fixture rationale", requires_invariants:$inv}' \
    > "$REG/_classes/$1.json"
}

mkmodule() { # <name> <class> [extra JSON merged over the manifest]
  local name="$1" class="$2" extra="${3:-}"
  [ -n "$extra" ] || extra='{}'
  mkdir -p "$REG/$name"
  printf 'fixture artifact payload for %s\n' "$name" > "$REG/$name/artifact.bin"
  jq -n --arg n "$name" --arg c "$class" --arg sha "$(sha_file "$REG/$name/artifact.bin")" \
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

# Two fixture classes the binary has never heard of. If they are enforced, the
# harness is reading class contracts as data.
mkclass fx-open false '[
  {"id":"cheap-suite","description":"a class-owned suite check",
   "check":{"kind":"suite","command":"printf FIXTURE-SUITE-OK","expect":"FIXTURE-SUITE-OK","expect_exit":0}},
  {"id":"module-owned","description":"a module-owned check","check":{"kind":"manifest"}}]'
mkclass fx-consent true '[
  {"id":"module-owned","description":"a module-owned check","check":{"kind":"manifest"}}]'

# ═════════════════════════════════════════════════════════════════════════════
echo
echo "G1 — the binary exists and is runnable"
[ -f "$MODS" ] && ok "bin/heimdall-modules exists" || bad "bin/heimdall-modules missing"
[ -x "$MODS" ] && ok "bin/heimdall-modules is executable" || bad "not executable"
"$MODS" -h >/dev/null 2>&1 && ok "-h exits 0" || bad "-h did not exit 0"
bash -n "$MODS" 2>/dev/null && ok "parses under bash -n" || bad "syntax error"

echo
echo "G2 — nothing installed renders honestly"
OUT="$(hmd list 2>&1)"; RC=$?
[ "$RC" -eq 0 ] && ok "list exits 0 with nothing installed (not an error)" \
                || bad "list exited $RC with nothing installed"
printf '%s' "$OUT" | grep -qi 'installed: none' \
  && ok "list says 'Installed: none' plainly" || bad "list did not state the empty case"
printf '%s' "$OUT" | grep -qi 'zero module payloads\|no module payloads' \
  && ok "list explains the base install ships no payloads" || bad "no base-install explanation"
J="$(hmd --json list 2>/dev/null)"
[ "$(printf '%s' "$J" | jq -r '.installed_count')" = "0" ] \
  && ok "json installed_count is 0" || bad "json installed_count wrong"
[ "$(printf '%s' "$J" | jq -r '.installed | length')" = "0" ] \
  && ok "json installed array is empty — no fabricated entry" || bad "json invented an entry"

echo
echo "G3 — the real class contracts are valid and data-driven"
for cls in traffic-proxy storage-codec rule-pack tool-adapter; do
  f="$REAL_CLASSES/$cls.json"
  if [ ! -f "$f" ]; then bad "$cls contract missing"; continue; fi
  if ! jq -e . "$f" >/dev/null 2>&1; then bad "$cls is not valid JSON"; continue; fi
  [ "$(jq -r '.class' "$f")" = "$cls" ] \
    && ok "$cls declares its own class name" || bad "$cls class field mismatch"
  jq -e 'has("consent_required") and (.consent_required | type == "boolean")' "$f" >/dev/null \
    && ok "$cls carries consent_required" || bad "$cls has no boolean consent_required"
  jq -e '(.requires_invariants | type == "array") and (.requires_invariants | length > 0)' "$f" >/dev/null \
    && ok "$cls carries a non-empty requires_invariants list" || bad "$cls has no invariants"
  jq -e 'all(.requires_invariants[]; ((.id // "") != "") and ((.description // "") != "")
          and (.check.kind == "suite" or .check.kind == "manifest"))' "$f" >/dev/null \
    && ok "$cls invariants are well-formed" || bad "$cls has a malformed invariant"
done
[ "$(jq -r '.consent_required' "$REAL_CLASSES/traffic-proxy.json")" = "true" ] \
  && ok "traffic-proxy requires consent (the spec's explicit demand)" \
  || bad "traffic-proxy does not require consent"

echo
echo "G4 — the judgment falsifier is consumed, and NOT weakened"
for cls in traffic-proxy storage-codec; do
  CMD="$(jq -r '.requires_invariants[] | select(.check.kind == "suite") | .check.command' "$REAL_CLASSES/$cls.json")"
  EXP="$(jq -r '.requires_invariants[] | select(.check.kind == "suite") | .check.expect' "$REAL_CLASSES/$cls.json")"
  printf '%s' "$CMD" | grep -q 'test/gate-judgment-uncompressed.test.sh' \
    && ok "$cls consumes the gates-read-raw falsifier" || bad "$cls does not run the falsifier"
  [ "$EXP" = "25 passed, 0 failed" ] \
    && ok "$cls pins the falsifier at 25/0" || bad "$cls expects '$EXP', not 25/0"
done
[ -f "$REPO/test/gate-judgment-uncompressed.test.sh" ] \
  && ok "the falsifier file exists" || bad "the falsifier file is gone"
if git -C "$REPO" diff --quiet HEAD -- test/gate-judgment-uncompressed.test.sh 2>/dev/null; then
  ok "the falsifier is unmodified vs git HEAD (not weakened to make a class pass)"
else
  bad "test/gate-judgment-uncompressed.test.sh was MODIFIED — the class consumes it, so weakening it is a false green"
fi

echo
echo "G5/G6 — the ordered pipeline, and a byte-identical round trip"
mkmodule good fx-open
REG_PRE="$(tree_sum "$REG")"
STATE_PRE="$(tree_sum "$STATE")"
[ "$STATE_PRE" = "ABSENT" ] && ok "state root is absent before the first add" \
                            || bad "state root already existed"

OUT="$(hmd add good --yes 2>&1)"; RC=$?
[ "$RC" -eq 0 ] && ok "add succeeded" || { bad "add failed (exit $RC)"; printf '%s\n' "$OUT"; }
for step in 'validate' 'class contract' 'consent' 'install + digest-verify' 'wire' 'class invariants'; do
  printf '%s' "$OUT" | grep -qF "$step" \
    && ok "pipeline ran step: $step" || bad "pipeline never reported: $step"
done
# The order is the contract: install must not precede consent, invariants must
# not precede wiring.
LINE_CONSENT=$(printf '%s\n' "$OUT" | grep -n 'consent'          | head -1 | cut -d: -f1)
LINE_INSTALL=$(printf '%s\n' "$OUT" | grep -n 'install + digest' | head -1 | cut -d: -f1)
LINE_WIRE=$(printf '%s\n'    "$OUT" | grep -n '\[5/6\] wire'     | head -1 | cut -d: -f1)
LINE_INV=$(printf '%s\n'     "$OUT" | grep -n 'class invariants' | head -1 | cut -d: -f1)
[ -n "$LINE_CONSENT" ] && [ -n "$LINE_INSTALL" ] && [ "$LINE_CONSENT" -lt "$LINE_INSTALL" ] \
  && ok "consent precedes install (nothing is written before the operator agrees)" \
  || bad "install ran at or before consent"
[ -n "$LINE_WIRE" ] && [ -n "$LINE_INV" ] && [ "$LINE_WIRE" -lt "$LINE_INV" ] \
  && ok "wiring precedes invariants (they run with the module ACTIVE)" \
  || bad "invariants ran before wiring — they would prove nothing"

[ -f "$STATE/good/receipt.json" ]    && ok "receipt written"        || bad "no receipt"
[ -f "$STATE/good/wired.json" ]      && ok "wiring record written"  || bad "no wiring record"
[ -f "$STATE/good/invariants.json" ] && ok "invariant results kept" || bad "no invariant results"
[ "$(jq -r '[.[] | select(.passed)] | length' "$STATE/good/invariants.json" 2>/dev/null)" = "2" ] \
  && ok "both fixture-class invariants ran and passed" || bad "fixture invariants did not both run"
[ "$(jq -r '.[] | select(.id=="cheap-suite") | .source' "$STATE/good/invariants.json" 2>/dev/null)" = "class-contract" ] \
  && ok "suite-kind invariant was sourced from the CLASS contract" || bad "suite invariant not class-sourced"
[ "$(jq -r '.[] | select(.id=="module-owned") | .source' "$STATE/good/invariants.json" 2>/dev/null)" = "manifest" ] \
  && ok "manifest-kind invariant was sourced from the MANIFEST" || bad "manifest invariant not manifest-sourced"
# The proof that classes are DATA: the ids that ran come from a fixture class
# the binary has never seen, and those ids appear NOWHERE in the binary.
RAN_IDS="$(jq -r '[.[].id] | sort | join(",")' "$STATE/good/invariants.json" 2>/dev/null || echo "")"
if [ "$RAN_IDS" = "cheap-suite,module-owned" ] \
   && ! grep -q 'cheap-suite' "$MODS" && ! grep -q 'fx-open' "$MODS"; then
  ok "a class the binary has never seen was enforced (ran: $RAN_IDS, hardcoded nowhere) — classes are DATA, not code"
else
  bad "the fixture class was not enforced from data (ran: '$RAN_IDS')"
fi

# Capture before grepping: `hmd ... | grep -q` makes grep exit early, which
# SIGPIPEs the writer, which `set -o pipefail` then reports as a failed
# pipeline (141). That would be a false RED about the tool.
OUT="$(hmd list 2>&1)"
printf '%s' "$OUT" | grep -q 'good' && ok "list shows the installed module" || bad "list omitted it"
OUT="$(hmd status good 2>&1)"
printf '%s' "$OUT" | grep -q 'wiring' && ok "status reports wiring" || bad "status omitted wiring"

hmd remove good >/dev/null 2>&1
STATE_POST="$(tree_sum "$STATE")"
REG_POST="$(tree_sum "$REG")"
[ "$STATE_POST" = "$STATE_PRE" ] \
  && ok "add -> remove is BYTE-IDENTICAL to pre-add ($STATE_PRE)" \
  || bad "residue after remove: pre=$STATE_PRE post=$STATE_POST"
[ "$REG_POST" = "$REG_PRE" ] \
  && ok "the registry was never mutated by add/remove" || bad "add/remove mutated the registry"

echo
echo "G7 — the round-trip assertion can actually FAIL (falsifier for G6)"
mkdir -p "$STATE/good"
printf 'leftover byte\n' > "$STATE/good/leftover"
RESIDUE_SUM="$(tree_sum "$STATE")"
[ "$RESIDUE_SUM" != "$STATE_PRE" ] \
  && ok "planted residue turns the checksum RED — the method detects a trace" \
  || bad "checksum did NOT notice planted residue; G6 would be a false green"
rm -rf "$TMP/state"
[ "$(tree_sum "$STATE")" = "$STATE_PRE" ] \
  && ok "clearing the residue returns the checksum to GREEN" || bad "could not restore GREEN"

echo
echo "G8/G9 — permission_class is refused, never defaulted"
mkmodule noclass fx-open '{"permission_class":null}'
OUT="$(hmd add noclass --yes 2>&1)"; RC=$?
[ "$RC" -ne 0 ] && ok "missing permission_class is refused" || bad "missing permission_class was accepted"
printf '%s' "$OUT" | grep -q 'permission_class' \
  && ok "the refusal names permission_class" || bad "refusal did not name the field"
[ ! -e "$STATE/noclass" ] && ok "nothing was installed for the refused manifest" || bad "residue for a refused manifest"
[ "$(tree_sum "$STATE")" = "$STATE_PRE" ] \
  && ok "a validate-stage refusal mutates NOTHING" || bad "validate-stage refusal left a trace"

mkmodule badclass fx-open '{"permission_class":"not-a-real-class"}'
OUT="$(hmd add badclass --yes 2>&1)"; RC=$?
[ "$RC" -ne 0 ] && ok "unknown permission_class is refused" || bad "unknown class was accepted"
printf '%s' "$OUT" | grep -q 'not-a-real-class' && ok "the refusal quotes the bad class" || bad "refusal did not quote it"
printf '%s' "$OUT" | grep -q 'Valid classes' && ok "the refusal lists the valid classes" || bad "refusal listed no alternatives"
[ "$(tree_sum "$STATE")" = "$STATE_PRE" ] && ok "unknown-class refusal mutates nothing" || bad "left a trace"

echo
echo "G10 — a failed class invariant is NOT WIRED and rolls back byte-identically"
mkmodule broken fx-open '{"invariants":{"module-owned":{"command":"printf MODULE-BROKEN; exit 3","expect":"MODULE-OK"}}}'
OUT="$(hmd add broken --yes 2>&1)"; RC=$?
[ "$RC" -ne 0 ] && ok "add of an invariant-failing module exits non-zero" || bad "invariant failure was accepted"
printf '%s' "$OUT" | grep -q 'NOT WIRED' && ok "the refusal says NOT WIRED" || bad "refusal never said NOT WIRED"
printf '%s' "$OUT" | grep -q 'FAILED INVARIANT: module-owned' \
  && ok "the refusal names the failing invariant" || bad "refusal did not name the invariant"
printf '%s' "$OUT" | grep -q 'exit 3, expected 0' \
  && ok "the refusal says WHY it failed" || bad "refusal gave no reason"
printf '%s' "$OUT" | grep -q 'what it guarantees' \
  && ok "the refusal explains what the invariant guarantees" || bad "no guarantee explanation"
[ ! -e "$STATE/broken" ] && ok "the rejected module left no install dir" || bad "rejected module left residue"
[ "$(tree_sum "$STATE")" = "$STATE_PRE" ] \
  && ok "a REJECTED module rolls back byte-identically — same path as remove" \
  || bad "rejected module left a trace: $(tree_sum "$STATE") != $STATE_PRE"

echo
echo "G11 — an uncovered class invariant is a refusal that names the hole"
mkmodule uncovered fx-open
# jq's `*` DEEP-merges, so passing {"invariants":{}} would leave the existing
# entry in place. Replace the key outright to build a genuine hole.
jq '.invariants = {}' "$REG/uncovered/manifest.json" > "$REG/uncovered/m.tmp" \
  && mv "$REG/uncovered/m.tmp" "$REG/uncovered/manifest.json"
[ "$(jq -r '.invariants | length' "$REG/uncovered/manifest.json")" = "0" ] \
  && ok "the uncovered fixture really has no invariants (the hole is real)" \
  || bad "fixture did not actually clear its invariants"
OUT="$(hmd add uncovered --yes 2>&1)"; RC=$?
[ "$RC" -ne 0 ] && ok "a manifest missing a required invariant is refused" || bad "hole was accepted"
printf '%s' "$OUT" | grep -q 'module-owned' && ok "the refusal names the uncovered invariant" || bad "hole not named"
printf '%s' "$OUT" | grep -qi 'nothing was installed' && ok "the refusal states nothing was installed" || bad "no such statement"
[ "$(tree_sum "$STATE")" = "$STATE_PRE" ] && ok "coverage refusal mutates nothing" || bad "left a trace"

echo
echo "G12/G13 — digests are verified, and reported honestly"
mkmodule tampered fx-open
printf 'this is NOT the pinned artifact\n' > "$REG/tampered/artifact.bin"
OUT="$(hmd add tampered --yes 2>&1)"; RC=$?
[ "$RC" -ne 0 ] && ok "an artifact that does not match its pin is refused" || bad "digest mismatch was accepted"
printf '%s' "$OUT" | grep -qi 'digest MISMATCH' && ok "the refusal says digest MISMATCH" || bad "no mismatch message"
[ "$(tree_sum "$STATE")" = "$STATE_PRE" ] && ok "digest refusal rolls back byte-identically" || bad "left a trace"

mkmodule good fx-open
hmd add good --yes >/dev/null 2>&1
[ "$(jq -r '.digest.status' "$STATE/good/receipt.json" 2>/dev/null)" = "verified" ] \
  && ok "a hashed local artifact is recorded as verified" || bad "local artifact not marked verified"
hmd remove good >/dev/null 2>&1

mkmodule upstreamer fx-open '{"installs_via":{"kind":"upstream","fetch":"npm i -g example@1.0.0","artifact_path":null}}'
hmd add upstreamer --yes >/dev/null 2>&1
DS="$(jq -r '.digest.status' "$STATE/upstreamer/receipt.json" 2>/dev/null)"
[ "$DS" = "deferred-upstream" ] \
  && ok "an un-vendored upstream pin reads 'deferred-upstream', never 'verified'" \
  || bad "upstream digest status was '$DS'"
jq -e '.digest.pinned_sha256 != null' "$STATE/upstreamer/receipt.json" >/dev/null 2>&1 \
  && ok "the pin is still RECORDED for later verification" || bad "pin was not recorded"
hmd remove upstreamer >/dev/null 2>&1
[ "$(tree_sum "$STATE")" = "$STATE_PRE" ] && ok "state clean after the digest tests" || bad "state dirty"

echo
echo "G14/G15 — consent"
mkmodule consented fx-consent
OUT="$(hmd add consented < /dev/null 2>&1)"; RC=$?
[ "$RC" -ne 0 ] && ok "a consent_required class refuses a non-interactive add without --yes" \
               || bad "installed a consent-required module with nobody asked"
printf '%s' "$OUT" | grep -qi 'not a terminal' && ok "the refusal explains there was no terminal" || bad "no explanation"
printf '%s' "$OUT" | grep -qi 'Re-run with --yes' && ok "the refusal says how to proceed" || bad "no remedy offered"
[ "$(tree_sum "$STATE")" = "$STATE_PRE" ] && ok "declined consent mutates nothing" || bad "left a trace"

OUT="$(hmd add consented --yes 2>&1)"; RC=$?
[ "$RC" -eq 0 ] && ok "--yes grants consent and the add proceeds" || bad "--yes did not work (exit $RC)"
printf '%s' "$OUT" | grep -qF "Fixture consent text for consented." \
  && ok "the manifest's consent_text is actually shown" || bad "consent text never displayed"
[ "$(jq -r '.consent.granted_via' "$STATE/consented/receipt.json" 2>/dev/null)" = "--yes" ] \
  && ok "the receipt records HOW consent was granted" || bad "consent grant not recorded"
jq -e '.consent.consent_text_sha256 != null' "$STATE/consented/receipt.json" >/dev/null 2>&1 \
  && ok "the receipt pins the hash of the text agreed to" || bad "no consent text hash"
hmd remove consented >/dev/null 2>&1

mkmodule quiet fx-open
OUT="$(hmd add quiet < /dev/null 2>&1)"; RC=$?
[ "$RC" -eq 0 ] && ok "a class that needs no consent installs without --yes" || bad "prompted when it should not"
printf '%s' "$OUT" | grep -qi 'requires your consent' \
  && bad "prompted for a class that does not require consent" \
  || ok "no consent prompt for a class that does not require it"
[ "$(jq -r '.consent.required' "$STATE/quiet/receipt.json" 2>/dev/null)" = "false" ] \
  && ok "the receipt records that consent was not required" || bad "consent state not recorded"
hmd remove quiet >/dev/null 2>&1

echo
echo "G16 — tier: a recommendation must carry its evidence"
mkmodule loud fx-open '{"tier":"suggested"}'
OUT="$(hmd add loud --yes 2>&1)"; RC=$?
[ "$RC" -ne 0 ] && ok "tier 'suggested' without tier_evidence is refused" || bad "unproven suggestion accepted"
printf '%s' "$OUT" | grep -qi 'tier_evidence' && ok "the refusal names tier_evidence" || bad "refusal did not name it"

mkmodule proven fx-open '{"tier":"suggested","tier_evidence":{"receipt":"ab-2026-08-01: 12/12 green, pre-registered"}}'
RC=0; hmd add proven --yes >/dev/null 2>&1 || RC=$?
[ "$RC" -eq 0 ] && ok "tier 'suggested' WITH evidence is accepted" || bad "evidenced suggestion refused"
[ "$(jq -r '.tier' "$STATE/proven/receipt.json" 2>/dev/null)" = "suggested" ] \
  && ok "the tier is carried onto the receipt" || bad "tier not recorded"
hmd remove proven >/dev/null 2>&1

echo
echo "G17 — pins, not latest"
mkmodule pinned fx-open
hmd add pinned --yes >/dev/null 2>&1
OUT="$(hmd update pinned 2>&1)"; RC=$?
[ "$RC" -eq 0 ] && ok "update at the manifest pin exits 0" || bad "update failed (exit $RC)"
printf '%s' "$OUT" | grep -qi 'already at the pinned version' \
  && ok "update is a no-op at the current pin" || bad "update did something at the same pin"
printf '%s' "$OUT" | grep -qi 'no "latest" to move to' \
  && ok "update states there is no latest to move to" || bad "update did not say pins-only"
for forbidden in 'curl' 'wget' 'git clone' 'npm install' 'pip install' 'brew install'; do
  if grep -qF -- "$forbidden" "$MODS"; then
    bad "the binary contains a fetch/install path: $forbidden"
  else
    ok "no '$forbidden' path in the binary — it depends, it never clones"
  fi
done
hmd remove pinned >/dev/null 2>&1

echo
echo "G18 — base install: the system, and zero module payloads"
[ -d "$REAL_CLASSES" ] && ok "modules/_classes ships with the base install" || bad "no class dir"
[ "$(ls "$REAL_CLASSES"/*.json 2>/dev/null | wc -l | tr -d ' ')" = "4" ] \
  && ok "exactly the four class contracts ship" || bad "unexpected class contract count"
PAYLOAD=0
for d in "$REPO"/modules/*/; do
  [ -d "$d" ] || continue
  n="${d%/}"; n="${n##*/}"
  [ "$n" = "_classes" ] && continue
  extra="$(ls -A "$d" | grep -v '^manifest.json$' | head -1)"
  [ -z "$extra" ] || { bad "modules/$n ships a payload file: $extra"; PAYLOAD=1; }
done
[ "$PAYLOAD" -eq 0 ] && ok "no module directory ships a vendored payload" || true
for probe in npm pip brew cargo go docker; do
  grep -qE "command -v $probe|$probe (install|i) " "$MODS" \
    && bad "the binary reaches for $probe — a new runtime dependency" \
    || ok "no $probe dependency introduced"
done
DEPS="$(grep -o 'command -v [a-z0-9]*' "$MODS" | awk '{print $3}' | LC_ALL=C sort -u | tr '\n' ' ')"
[ "$DEPS" = "jq openssl readlink sha256sum shasum " ] \
  && ok "external tools are exactly jq (a pre-existing hard dep) + base-system hashers/readlink" \
  || bad "unexpected external tool set: $DEPS"
grep -q 'no sha256 tool available' "$MODS" \
  && ok "a machine with no sha256 tool is refused clearly, not silently mis-digested" \
  || bad "missing hasher would surface as an empty digest"

echo
echo "G19 — verify is a real CI gate that can go RED"
mkmodule watched fx-open
hmd add watched --yes >/dev/null 2>&1
OUT="$(hmd verify 2>&1)"; RC=$?
[ "$RC" -eq 0 ] && ok "verify is green while the invariant holds" || bad "verify failed on a good module"
printf '%s' "$OUT" | grep -qi 'hold their class invariants' && ok "verify says so plainly" || bad "verify was mute"
# Regress the module's own invariant: verify must notice on the next run.
jq '.invariants["module-owned"].command = "printf REGRESSED; exit 1"' \
  "$REG/watched/manifest.json" > "$REG/watched/manifest.json.tmp" \
  && mv "$REG/watched/manifest.json.tmp" "$REG/watched/manifest.json"
OUT="$(hmd verify 2>&1)"; RC=$?
[ "$RC" -ne 0 ] && ok "verify goes RED the moment the invariant regresses" || bad "verify missed a regression"
printf '%s' "$OUT" | grep -q 'module-owned' && ok "verify names the regressed invariant" || bad "verify did not name it"
OUT="$(hmd verify watched 2>&1)"; RC=$?
[ "$RC" -ne 0 ] && ok "verify <name> targets a single module and still goes RED" || bad "targeted verify missed it"
hmd remove watched >/dev/null 2>&1
[ "$(tree_sum "$STATE")" = "$STATE_PRE" ] && ok "state is clean after the verify tests" || bad "state dirty"

echo
echo "G20 — --json is valid on every read verb"
mkmodule jsonny fx-open
hmd add jsonny --yes >/dev/null 2>&1
for verb in "list" "status jsonny" "verify"; do
  # shellcheck disable=SC2086
  if hmd --json $verb 2>/dev/null | jq -e . >/dev/null 2>&1; then
    ok "--json $verb emits valid JSON"
  else
    bad "--json $verb emitted invalid JSON"
  fi
done
[ "$(hmd --json status jsonny 2>/dev/null | jq -r '.receipt.name')" = "jsonny" ] \
  && ok "json status carries the receipt" || bad "json status lost the receipt"
hmd remove jsonny >/dev/null 2>&1
[ "$(hmd --json remove jsonny 2>/dev/null | jq -r '.ok')" = "true" ] \
  && ok "removing an absent module is a clean no-op, not an error" || bad "remove of absent module errored"

echo
echo "G21 — END-TO-END against the REAL traffic-proxy contract"
# Everything above proves the mechanism with cheap fixture classes. This proves
# the expensive path actually executes: the real traffic-proxy contract runs the
# real gates-read-raw falsifier, with the module installed and WIRED. If the
# suite check were skipped, mis-wired, or silently swallowed, the recorded
# output could not contain the falsifier's own 25/0 line.
REG2="$TMP/real-registry"
STATE2="$TMP/real-state/modules"
mkdir -p "$REG2/_classes" "$REG2/fixture-proxy"
cp "$REAL_CLASSES"/*.json "$REG2/_classes/"
printf 'fixture proxy artifact\n' > "$REG2/fixture-proxy/artifact.bin"
jq -n --arg sha "$(sha_file "$REG2/fixture-proxy/artifact.bin")" '{
  name:"fixture-proxy",
  description:"test-only module exercising the real traffic-proxy contract",
  upstream:"https://example.invalid/fixture-proxy", license:"MIT",
  pinned_version:{version:"0.1.0", artifact:"artifact.bin", artifact_sha256:$sha},
  permission_class:"traffic-proxy",
  installs_via:{kind:"local", artifact_path:"artifact.bin"},
  wires:[{kind:"env", target:"FIXTURE_PROXY_BASE_URL"}],
  invariants:{
    "non-interactive-passthrough":{
      command:"printf hello | cat | grep -q hello && printf PASSTHROUGH-OK",
      expect:"PASSTHROUGH-OK"},
    "no-signed-traffic-routing":{
      command:"printf %s \"$FIXTURE_ROUTES\" | grep -qE \"control-plane|enroll|signed\" && printf ROUTED || printf BYPASS-OK",
      expect:"BYPASS-OK"}},
  tier:"available",
  consent_text:"This test-only module would sit on the wire. It is never shipped."
}' > "$REG2/fixture-proxy/manifest.json"

REAL_PRE="$(tree_sum "$STATE2")"
OUT="$(FIXTURE_ROUTES="generation-only" "$MODS" --registry "$REG2" --state "$STATE2" add fixture-proxy --yes 2>&1)"; RC=$?
[ "$RC" -eq 0 ] && ok "a module passes the REAL traffic-proxy contract end to end" \
                || { bad "real-contract add failed (exit $RC)"; printf '%s\n' "$OUT" | tail -25; }
INV="$STATE2/fixture-proxy/invariants.json"
if [ -f "$INV" ]; then
  [ "$(jq -r '[.[] | select(.passed)] | length' "$INV")" = "3" ] \
    && ok "all three traffic-proxy invariants ran and passed" || bad "not all three ran"
  jq -r '.[] | select(.id=="gates-read-raw") | .output_tail' "$INV" | grep -q '25 passed, 0 failed' \
    && ok "the recorded output proves the falsifier really ran at 25/0 (not skipped)" \
    || bad "gates-read-raw output does not contain the falsifier's 25/0 line"
  [ -f "$STATE2/fixture-proxy/wired.json" ] \
    && ok "the module was wired BEFORE the falsifier ran — it passed with it active" || bad "not wired"
  [ "$(jq -r '.consent.granted' "$STATE2/fixture-proxy/receipt.json")" = "true" ] \
    && ok "the real consent-required class recorded a grant" || bad "consent not recorded"
else
  bad "no invariant record from the real-contract add"
fi
"$MODS" --registry "$REG2" --state "$STATE2" remove fixture-proxy >/dev/null 2>&1
[ "$(tree_sum "$STATE2")" = "$REAL_PRE" ] \
  && ok "the real-contract module round-trips byte-identically too" || bad "real-contract module left residue"

echo
echo "--------------------------------------------------------------------"
printf 'modules-lifecycle: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
