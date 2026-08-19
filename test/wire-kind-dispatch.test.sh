#!/usr/bin/env bash
#
# wire-kind-dispatch.test.sh — acceptance for the WIRE-KIND HANDLER GATE in
# bin/heimdall-modules.
#
# THE DEFECT THIS FILE EXISTS TO STOP SHIPPING. `wire_module()` used to write a
# record listing `targets: (.wires // [])` and return 0. It touched no target and
# dispatched on no kind. Both of Headroom's declared wires were therefore inert —
# `bin/heimdall-wrap` contained no reference to the module at all — while
# `[6/7] wire` printed a clean green and `wired.json` looked exactly like a wired
# module's record. A module could declare a capability the code could not deliver
# and NOTHING said so. That is the shape of every overclaim: the honest state and
# the dishonest state are byte-identical on the surfaces a reader checks.
#
# THE FIX HAS TWO LAYERS, AND BOTH ARE PROVEN HERE.
#   1. VALIDATE refuses a wire kind that has no handler, read-only, before any
#      mutation. A capability the dispatcher cannot act on never gets installed.
#   2. The DISPATCHER refuses it again at wire time, as the backstop for any
#      future caller that reaches wiring without validating.
# W5 neuters each layer in turn against a MUTANT copy of the binary and proves the
# bogus kind gets through — first past validate, then all the way to a silent
# green. A gate that cannot be shown to fail is not evidence.
#
# WIRING IS MEASURED, NEVER ASSERTED. Each handler answers one question about one
# declared wire — is it ROUTED on this machine, or only RECORDED? — and derives the
# answer from the machine. This is the same discipline the provenance line already
# follows (see the `digest.verified` comment in cmd_add): a status written as a
# fixed string cannot go wrong, and therefore cannot be trusted. W3 and W4 are what
# stop the answer regressing into a constant.
#
# AND MEASURED AGAIN WHEN IT IS READ. A measurement taken once and then replayed
# forever is a fixed string with extra steps. Headroom's canonical wiring record
# proved it: written before the wrap-chain handler existed, it carries no per-wire
# verdict at all, while bin/heimdall-wrap references the module and a live add
# measures ROUTED — and no path on the machine rewrote it, because `add` refuses an
# installed module and `update` reports nothing to do. W7 holds the line the record
# could not: `status` measures when you READ it, names the disagreement when the
# stored record contradicts the machine, and `rewire` is the path that corrects it.
#
# THIS SUITE IS OFFLINE AND CHEAP BY CONSTRUCTION. It drives the dispatcher through
# FIXTURE modules that declare the real kinds and the real targets, under a fixture
# class whose invariants are `printf`. The full add-path coverage for the shipped
# module already exists in test/headroom-module.test.sh; duplicating it here would
# buy a second copy of a network-dependent 44/0 and nothing else.
#
# Guarantees proved:
#   W1  every wire kind the SHIPPED registry declares resolves to a handler —
#       enumerated from the manifests, driven through the binary, not grepped.
#   W2  an UNKNOWN kind is REFUSED at [1/7] validate, names the kind, names the
#       known kinds, and leaves the state tree BYTE-IDENTICAL — read-only refusal.
#   W3  the recorded status is MEASURED: for an `env` wire, exporting the target
#       variable flips `routed` false -> true. A fixed string cannot do that.
#   W4  for the shipped kinds, the recorded status agrees with an INDEPENDENT
#       measurement of this repo taken by this file. A differential, so it stays
#       correct if someone genuinely wires the module later. The fixture carries
#       the SHIPPED module's name, because the name is part of what gets measured.
#   W5  PROVE-RED, both layers: a mutant with validate's refusal neutered lets the
#       bogus kind reach [5/7]; a mutant with the dispatcher ALSO reverted to the
#       old record-and-return body installs it to a silent green. Restored binary
#       refuses both times.
#   W6  [6/7] reports per wire, out loud, whether it ROUTED or only RECORDED, so
#       an inert wire cannot read as a live one on the terminal either — proved on
#       ONE module carrying one of each.
#   W7  `status` measures at READ time, not at add time: the same install and the
#       same record print two different verdicts under two different machines, the
#       disagreement with the stored record is named out loud, and `rewire`
#       refreshes the record without re-fetching or disturbing the install.
#       PROVE-RED: a mutant whose status REPLAYS the record fails every one.
#
# Usage:  bash test/wire-kind-dispatch.test.sh   (exit 0 = every guarantee holds)
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
hmd() { "$MODS" --registry "$REG" --state "$STATE" "$@"; }

# OFFLINE AND CHEAP BY CONSTRUCTION, as stated above — and free disk is part of
# that contract. hmd's generic preflight floor is 4096 MB, sized for a real
# Rust+ONNX payload; these fixtures are one small file installed into $STATE. Left
# ambient it makes W3/W4/W6/W7 assertions about the developer's disk instead of the
# dispatcher: at ~2 GB free every add is refused with `disk: at least 4096 MB free`
# before wiring is ever reached. Pinned so the handler is what gets judged. The
# library documents the override ("overridable so a test can pin both sides of the
# boundary"); the floor itself is proven in test/module-preflight-wiring.test.sh.
export HMD_PREFLIGHT_DISK_FLOOR_MB=1

sha_file() { shasum -a 256 "$1" | awk '{print $1}'; }

# Distinguishes ABSENT from EMPTY — a refused add that leaves a bare directory
# behind has still mutated the tree.
tree_sum() {
  [ -e "$1" ] || { printf 'ABSENT\n'; return 0; }
  ( cd "$1" && find . -mindepth 1 | LC_ALL=C sort | while IFS= read -r p; do
      if [ -d "$p" ]; then printf 'd %s\n' "$p"
      else printf 'f %s %s\n' "$p" "$(sha_file "$p")"
      fi
    done ) | shasum -a 256 | awk '{print $1}'
}

# ── Fixtures ─────────────────────────────────────────────────────────────────
# One class the binary has never heard of, with invariants that cost nothing. The
# subject under test is the wire dispatcher, not the invariant runner.
mkdir -p "$REG/_classes"
jq -n '{class:"fx-wire", version:"1", summary:"fixture class for wire dispatch",
        why_this_class_exists:"fixture", consent_required:false,
        consent_rationale:"fixture rationale",
        requires_invariants:[{id:"cheap",description:"a cheap fixture check",
                              check:{kind:"manifest"}}]}' \
  > "$REG/_classes/fx-wire.json"

mkmodule() { # <name> <wires JSON array>
  local name="$1" wires="$2"
  mkdir -p "$REG/$name"
  printf 'fixture artifact for %s\n' "$name" > "$REG/$name/artifact.bin"
  jq -n --arg n "$name" --arg sha "$(sha_file "$REG/$name/artifact.bin")" \
        --argjson wires "$wires" '
    { name:$n, description:("fixture module " + $n),
      upstream:("https://example.invalid/" + $n), license:"MIT",
      pinned_version:{version:"1.0.0", artifact:"artifact.bin", artifact_sha256:$sha},
      permission_class:"fx-wire",
      installs_via:{kind:"local", artifact_path:"artifact.bin"},
      wires:$wires,
      invariants:{cheap:{command:"printf CHEAP-OK", expect:"CHEAP-OK"}},
      tier:"available",
      consent_text:("Fixture consent text for " + $n + ".")
    }' > "$REG/$name/manifest.json"
}

echo
echo "W1 — every wire kind the shipped registry declares has a handler"

# Enumerated from the shipped manifests rather than hardcoded, so a new module
# declaring a new kind is covered the day it lands.
SHIPPED_KINDS="$(jq -r '.wires[]?.kind // empty' "$REPO"/modules/*/manifest.json 2>/dev/null | LC_ALL=C sort -u)"
if [ -z "$SHIPPED_KINDS" ]; then
  bad "no wire kinds found in the shipped registry — this suite would pass vacuously"
else
  ok "shipped registry declares $(printf '%s\n' "$SHIPPED_KINDS" | wc -l | tr -d ' ') distinct wire kind(s)"
fi

# Each shipped kind is driven through the REAL binary on a fixture module that
# declares that kind against that kind's REAL target. Accepting it proves a
# handler exists; the binary is the oracle, not a grep over its source.
while IFS= read -r K; do
  [ -n "$K" ] || continue
  KT="$(jq -r --arg k "$K" 'first(.wires[]? | select(.kind == $k) | .target) // empty' \
        "$REPO"/modules/*/manifest.json 2>/dev/null | head -1)"
  FX="fxk-$(printf '%s' "$K" | tr -c 'a-z0-9' '-')"
  mkmodule "$FX" "$(jq -n --arg k "$K" --arg t "$KT" '[{kind:$k, target:$t}]')"
  OUT="$(hmd add "$FX" --yes 2>&1)"; RC=$?
  if [ "$RC" -eq 0 ]; then
    ok "wire kind \"$K\" has a handler (add accepted it against target $KT)"
  else
    bad "wire kind \"$K\" was REFUSED — no handler: $(printf '%s' "$OUT" | tail -3 | tr '\n' ' ')"
  fi
  hmd remove "$FX" >/dev/null 2>&1
done <<< "$SHIPPED_KINDS"

echo
echo "W2 — an unknown wire kind is refused read-only, before anything is written"

mkmodule bogus '[{"kind":"teleport-chain","target":"bin/heimdall-wrap"}]'
PRE="$(tree_sum "$STATE")"
OUT="$(hmd add bogus --yes 2>&1)"; RC=$?
[ "$RC" -ne 0 ] && ok "add REFUSED a module declaring an unhandled wire kind (exit $RC)" \
                || bad "add ACCEPTED an unhandled wire kind — the defect is back"
grep -q 'teleport-chain' <<<"$OUT" \
  && ok "the refusal names the offending kind" || bad "refusal does not name the kind"
grep -qi 'known kinds' <<<"$OUT" \
  && ok "the refusal lists the kinds that DO have handlers" || bad "refusal does not list known kinds"
grep -q '\[1/7\] validate' <<<"$OUT" \
  && ok "it was caught at [1/7] validate" || bad "not caught at validate"
grep -q '\[5/7\]' <<<"$OUT" \
  && bad "the refused module reached [5/7] install — validate is not read-only" \
  || ok "it never reached [5/7] install — nothing was fetched or written"
[ "$(tree_sum "$STATE")" = "$PRE" ] \
  && ok "the state tree is BYTE-IDENTICAL after the refusal" || bad "the refusal left residue"

echo
echo "W3 — the recorded status is MEASURED, not a fixed string"

mkmodule envwire '[{"kind":"env","target":"HMD_WIRE_FIXTURE_URL"}]'
hmd add envwire --yes >/dev/null 2>&1
W="$STATE/envwire/wired.json"
if [ -f "$W" ]; then
  [ "$(jq -r '.wires[0].routed' "$W")" = "false" ] \
    && ok "an UNSET env target records routed=false" || bad "unset env target did not record routed=false"
  [ "$(jq -r '.wires[0].measured' "$W")" = "true" ] \
    && ok "and records that the answer was actually measured" || bad "measured flag missing or false"
else
  bad "no wiring record written for the env fixture"
fi
hmd remove envwire >/dev/null 2>&1

# The same module, same manifest, one thing different about the machine. If the
# record were a constant this arm could not move it.
HMD_WIRE_FIXTURE_URL="http://127.0.0.1:8080" hmd add envwire --yes >/dev/null 2>&1
if [ -f "$W" ]; then
  [ "$(jq -r '.wires[0].routed' "$W")" = "true" ] \
    && ok "exporting the target variable flips the SAME manifest to routed=true" \
    || bad "routed did not flip — the record is not measuring the machine"
else
  bad "no wiring record written on the routed arm"
fi
hmd remove envwire >/dev/null 2>&1

echo
echo "W4 — the shipped kinds' recorded status agrees with an independent measurement"

# This file measures the repo ITSELF, by hand, and demands the binary's record
# match. Written as a differential on purpose: if someone genuinely wires the
# module later, both sides move together and this stays green. Only a record that
# has stopped tracking reality can fail it.
#
# THE FIXTURE'S NAME IS PART OF THE MEASUREMENT, which is why it is the shipped
# module's name and not a neutral label. Every handler asks its question ABOUT THE
# MODULE BEING WIRED: wrap-chain greps the target for the module's own name,
# storage-codec-backend compares the seam's live backend against it. A fixture
# called something else therefore makes the binary answer "is bin/heimdall-wrap
# wired to MIRROR?" (it never is) while the independent grep below asks "is it
# wired to HEADROOM?" (it is) — two different questions about two different
# subjects, a mismatch guaranteed by construction, and a red that accuses the
# record of drifting when nothing has drifted at all. A differential is only one
# if both sides name the same subject.
mkmodule headroom "$(jq -c '[.wires[] | {kind, target}]' "$REPO/modules/headroom/manifest.json")"
hmd add headroom --yes >/dev/null 2>&1
MW="$STATE/headroom/wired.json"
if [ -f "$MW" ]; then
  # wrap-chain: is the target file actually referencing the module?
  WT="$(jq -r '.wires[] | select(.kind=="wrap-chain") | .target' "$MW")"
  if [ -n "$WT" ] && [ -f "$REPO/$WT" ]; then
    if grep -qi 'headroom' "$REPO/$WT"; then INDEP=true; else INDEP=false; fi
    [ "$(jq -r '.wires[] | select(.kind=="wrap-chain") | .routed' "$MW")" = "$INDEP" ] \
      && ok "wrap-chain routed=$INDEP matches an independent grep of $WT" \
      || bad "wrap-chain record disagrees with the repo (independent grep says $INDEP)"
  else
    bad "wrap-chain target does not resolve to a file in this repo: $WT"
  fi
  # storage-codec-backend: ask the seam which backend is live.
  ST="$(jq -r '.wires[] | select(.kind=="storage-codec-backend") | .target' "$MW")"
  if [ -n "$ST" ] && [ -f "$REPO/$ST" ]; then
    BK="$(python3 "$REPO/$ST" status --json 2>/dev/null | jq -r '.backend // "plain"')"
    if [ "$BK" = "plain" ]; then INDEP=false; else INDEP=true; fi
    [ "$(jq -r '.wires[] | select(.kind=="storage-codec-backend") | .routed' "$MW")" = "$INDEP" ] \
      && ok "storage-codec-backend routed=$INDEP matches the seam's own backend ($BK)" \
      || bad "storage-codec record disagrees with the seam (it reports backend=$BK)"
  else
    bad "storage-codec-backend target does not resolve to a file in this repo: $ST"
  fi
  [ "$(jq -r '.wires | length' "$MW")" = "2" ] \
    && ok "both declared wires are recorded, neither dropped" || bad "wire count wrong"
else
  bad "no wiring record for the shipped-wires fixture"
fi
hmd remove headroom >/dev/null 2>&1

echo
echo "W5 — PROVE-RED: neuter each layer and watch the bogus kind get through"

# A mutant must run from a tree that LOOKS like the plugin, because the binary
# resolves its own libraries (bin/lib/module_preflight.sh) relative to itself. A
# bare copy in a temp dir dies at [3/7] preflight and would "prove" the gate works
# when nothing was tested at all. So each mutant lives in a symlink farm of the
# real repo with only heimdall-modules replaced: same libraries, same targets,
# one behaviour different.
mkfarm() { # <farm-dir> <mutant-binary-source>
  local farm="$1" src="$2" e b
  mkdir -p "$farm/bin"
  for e in "$REPO"/*; do
    b="$(basename "$e")"
    [ "$b" = "bin" ] && continue
    ln -s "$e" "$farm/$b"
  done
  for e in "$REPO"/bin/*; do
    b="$(basename "$e")"
    [ "$b" = "heimdall-modules" ] && continue
    ln -s "$e" "$farm/bin/$b"
  done
  cp "$src" "$farm/bin/heimdall-modules"
  chmod +x "$farm/bin/heimdall-modules"
}

# The farm itself must be proven neutral BEFORE it carries a mutation, or a
# mutant that dies of harness breakage reads exactly like a mutant the gate
# caught.
mkfarm "$TMP/farm-control" "$MODS"
CTL="$("$TMP/farm-control/bin/heimdall-modules" --registry "$REG" --state "$TMP/sctl/modules" add envwire --yes 2>&1)"; RCC=$?
[ "$RCC" -eq 0 ] \
  && ok "control: an UNMUTATED binary in the farm still installs normally (harness is neutral)" \
  || { bad "the farm harness itself is broken — every mutant result below would be noise"; printf '%s\n' "$CTL" | tail -6; }

# Layer 1 neutered: validate's refusal becomes a no-op. `: "..."` is a valid bash
# no-op that keeps the string, so the mutant differs from the real binary in
# exactly one behaviour — whether the refusal fires.
M1SRC="$TMP/mutant-validate.sh"
sed 's/verr "unknown wire kind/: "unknown wire kind/' "$MODS" > "$M1SRC"
if cmp -s "$M1SRC" "$MODS"; then
  bad "the validate mutation changed nothing — the PROVE-RED arm would be vacuous"
else
  ok "mutant 1 differs from the shipped binary (validate refusal neutered)"
fi
mkfarm "$TMP/farm1" "$M1SRC"
M1="$TMP/farm1/bin/heimdall-modules"
MSTATE1="$TMP/mstate1/modules"
OUT1="$("$M1" --registry "$REG" --state "$MSTATE1" add bogus --yes 2>&1)"; RC1=$?
grep -q '\[5/7\]' <<<"$OUT1" \
  && ok "RED: with validate neutered the bogus kind reaches [5/7] install" \
  || bad "mutant 1 did not get past validate — the layer-1 proof is inconclusive"
[ "$RC1" -ne 0 ] \
  && ok "the DISPATCHER still caught it at wire time (backstop holds, exit $RC1)" \
  || bad "mutant 1 installed a bogus wire — the dispatcher backstop does not exist"

# Layer 2 also neutered: wire_module reverted to the body that shipped this
# morning — record `targets` and return 0, dispatching on nothing. This mutant IS
# the defect, reconstructed, so what it does is what the tree used to do.
M2SRC="$TMP/mutant-both.sh"
awk '
  /^wire_module\(\) \{/ { skip = 1
    print "wire_module() {"
    print "  local name=\"$1\" mf=\"$2\""
    print "  local mdir=\"$STATE/$name\""
    print "  jq --arg at \"$(now_iso)\" \x27{wired_at:$at, targets:(.wires // [])}\x27 \\"
    print "     \"$mf\" > \"$mdir/wired.json\" || return 1"
    print "  return 0"
    print "}"
    next }
  skip && /^\}/ { skip = 0; next }
  skip { next }
  { print }
' "$M1SRC" > "$M2SRC"
bash -n "$M2SRC" 2>/dev/null && ok "mutant 2 is syntactically valid bash (a broken mutant proves nothing)" \
                             || bad "mutant 2 does not parse — the reconstruction is wrong"
mkfarm "$TMP/farm2" "$M2SRC"
M2="$TMP/farm2/bin/heimdall-modules"
MSTATE2="$TMP/mstate2/modules"
OUT2="$("$M2" --registry "$REG" --state "$MSTATE2" add bogus --yes 2>&1)"; RC2=$?
[ "$RC2" -eq 0 ] \
  && ok "RED: with BOTH layers gone, a module declaring \"teleport-chain\" installs to a green" \
  || bad "mutant 2 still refused — the reconstruction does not reproduce the defect"
if [ -f "$MSTATE2/bogus/wired.json" ]; then
  jq -e '.targets[0].kind == "teleport-chain"' "$MSTATE2/bogus/wired.json" >/dev/null 2>&1 \
    && ok "RED: and the old record lists the unhandled wire as if it were wired" \
    || bad "mutant 2's record does not show the old recording behaviour"
else
  bad "mutant 2 wrote no wiring record — the reconstruction is not the old code path"
fi

# GREEN again on the shipped binary, same fixture, same registry. The restore is
# what makes the two REDs above evidence rather than noise.
MSTATE3="$TMP/mstate3/modules"
OUT3="$("$MODS" --registry "$REG" --state "$MSTATE3" add bogus --yes 2>&1)"; RC3=$?
[ "$RC3" -ne 0 ] && ok "GREEN: the shipped binary refuses the same fixture again" \
                 || bad "the shipped binary accepted the bogus kind"
[ "$(tree_sum "$MSTATE3")" = "ABSENT" ] \
  && ok "GREEN: and wrote nothing at all for it" || bad "the shipped binary left state behind"

echo
echo "W6 — [6/7] says out loud what it actually did, per wire"

# The fixture carries Headroom's real wires AND its real name (see W4), so this
# one module presents one LIVE wire and one INERT wire in a single step. That is
# the strongest available form of the guarantee: the two outcomes have to be
# distinguishable from each other on the same terminal, in the same run, not
# merely distinguishable across two separate fixtures.
OUT="$(hmd add headroom --yes 2>&1)"
grep -q '\[6/7\] wire' <<<"$OUT" \
  && ok "the step is still labelled [6/7] wire (the ordering gate's anchor survives)" \
  || bad "[6/7] wire label is gone — modules-lifecycle's order assertion would break"
grep -q ': RECORDED, not routed' <<<"$OUT" \
  && ok "an inert wire prints \"RECORDED, not routed\", not a bare green" \
  || bad "[6/7] does not report an inert wire as recorded-not-routed"
grep -q ': ROUTED' <<<"$OUT" \
  && ok "and a LIVE wire on the same module prints ROUTED — the two are distinguishable" \
  || bad "[6/7] does not report a live wire as ROUTED"
grep -q 'wrap-chain' <<<"$OUT" \
  && ok "each declared wire is named in the step output" || bad "wires are not named at [6/7]"
hmd remove headroom >/dev/null 2>&1

echo
echo "W7 — \`status\` measures the machine at READ time, and names the record it contradicts"

# THE PREMISE THIS SECTION REPLACES. W6 used to end by asserting that `status`
# printed the word "recorded", on the stated reasoning that "the status verb reads
# the same record, so it cannot drift from it". It cannot drift from the RECORD.
# It can drift from the MACHINE, and on the owner's install it had: Headroom's
# canonical wired.json predates the wrap-chain handler and carries no per-wire
# verdict at all, while bin/heimdall-wrap references the module and a live add
# measures ROUTED. `add` refuses an installed module and `update` reports nothing
# to do, so nothing on the machine could correct it. An assertion that a replayed
# record is self-consistent is an assertion that cannot fail.
#
# So the property asserted here is the stronger one: the verdict `status` prints is
# measured WHEN YOU READ IT, and the add-time record is kept as provenance whose
# disagreement is SURFACED rather than silently preferred. An `env` wire is the
# subject because this file can flip its routedness at will, which turns "measured
# at read time" from a claim about wording into a differential — the SAME install
# and the SAME record must print two different verdicts under two different
# machines. No replaying implementation can do that, which is what the mutant at
# the end of this section demonstrates instead of assuming.

hmd add envwire --yes >/dev/null 2>&1
EW="$STATE/envwire/wired.json"
[ "$(jq -r '.wires[0].routed' "$EW" 2>/dev/null)" = "false" ] \
  && ok "setup: the add-time record for the env wire says routed=false" \
  || bad "setup: the env fixture did not record routed=false"

# Arm 1 — the machine agrees with the record.
S_OFF="$(hmd status envwire 2>&1)"
grep -q 'measured now' <<<"$S_OFF" \
  && ok "\`status\` states its verdict was measured NOW, not replayed from the record" \
  || bad "\`status\` does not report a verdict measured at read time"
grep -q ': NOT ROUTED (measured now)' <<<"$S_OFF" \
  && ok "with the target unset it measures NOT ROUTED" \
  || bad "unset target did not measure NOT ROUTED"
grep -q 'add-time record says' <<<"$S_OFF" \
  && bad "it reported drift while the record and the machine agree" \
  || ok "and reports NO drift, because the record and the machine agree"

# Arm 2 — same install, same record, one thing different about the machine. This
# is the arm a replaying status cannot pass, and it is also the drifted state the
# mutant below is run against.
S_ON="$(HMD_WIRE_FIXTURE_URL="http://127.0.0.1:8080" hmd status envwire 2>&1)"
grep -q ': ROUTED (measured now)' <<<"$S_ON" \
  && ok "exporting the target flips the SAME record's status to ROUTED — read-time measurement" \
  || bad "status did not move when the machine moved — it is replaying the record"
grep -q 'add-time record says 0 ROUTED' <<<"$S_ON" \
  && ok "and the DRIFT is named out loud, quoting what the stored record claims" \
  || bad "status silently preferred one side instead of naming the disagreement"
[ "$(jq -r '.wires[0].routed' "$EW" 2>/dev/null)" = "false" ] \
  && ok "\`status\` did NOT rewrite the record behind the reader's back — it stays read-only" \
  || bad "status mutated the stored record; a read must not be a write"

# PROVE-RED. Everything above is a property the shipped binary has, so on its own
# it cannot show those assertions are load-bearing. This mutant restores the
# REPLAYING body of status_wiring() — the code that shipped before this change,
# verbatim — and is run against the SAME drifted state. It must fail every arm.
cat > "$TMP/replay-body.sh" <<'REPLAY'
status_wiring() {
  local name="$1" d="$2"
  local nwires nrouted
  nwires="$(jq -r '(.wires // []) | length' "$d/wired.json" 2>/dev/null || echo 0)"
  [ -n "$nwires" ] || nwires=0
  if [ "$nwires" = "0" ]; then
    printf '    wiring:   0 wires declared — the module is inert\n'
  else
    nrouted="$(jq -r '[(.wires // [])[] | select(.routed)] | length' "$d/wired.json" 2>/dev/null || echo 0)"
    printf '    wiring:   %s declared, %s ROUTED when measured at add time\n' "$nwires" "$nrouted"
    jq -r '(.wires // [])[] |
      "              \(.kind) -> \(.target): \(if (.measured | not) then "NOT MEASURED" elif .routed then "ROUTED" else "RECORDED, not routed" end)"' \
      "$d/wired.json" 2>/dev/null
  fi
}
REPLAY

M3SRC="$TMP/mutant-replay-status.sh"
awk -v body="$TMP/replay-body.sh" '
  /^status_wiring\(\) \{/ { skip = 1
    while ((getline line < body) > 0) print line
    close(body); next }
  skip && /^\}/ { skip = 0; next }
  skip { next }
  { print }
' "$MODS" > "$M3SRC"

if cmp -s "$M3SRC" "$MODS"; then
  bad "the status mutation changed nothing — every PROVE-RED arm below would be vacuous"
else
  ok "mutant 3 differs from the shipped binary (status reverted to replaying the record)"
fi
bash -n "$M3SRC" 2>/dev/null \
  && ok "mutant 3 is syntactically valid bash (a broken mutant proves nothing)" \
  || bad "mutant 3 does not parse — the reconstruction is wrong"
mkfarm "$TMP/farm3" "$M3SRC"
M3OUT="$(HMD_WIRE_FIXTURE_URL="http://127.0.0.1:8080" \
         "$TMP/farm3/bin/heimdall-modules" --registry "$REG" --state "$STATE" status envwire 2>&1)"
grep -q 'measured now' <<<"$M3OUT" \
  && bad "mutant 3 still claims a read-time measurement — the reconstruction is wrong" \
  || ok "RED: the replaying status makes no read-time claim, so arm 1's assertion fails on it"
grep -q 'add-time record says' <<<"$M3OUT" \
  && bad "mutant 3 flagged drift — a replaying status cannot detect drift, so this is wrong" \
  || ok "RED: it cannot see the drift at all, so arm 2's drift assertion fails on it"
grep -q ': RECORDED, not routed' <<<"$M3OUT" \
  && ok "RED: and it reports the wire as not routed while the machine has it ROUTED — the exact defect" \
  || bad "mutant 3 did not reproduce the replayed verdict"

# GREEN again on the shipped binary, same state, same machine. The restore is what
# makes the REDs above evidence rather than noise.
S_RESTORE="$(HMD_WIRE_FIXTURE_URL="http://127.0.0.1:8080" hmd status envwire 2>&1)"
grep -q ': ROUTED (measured now)' <<<"$S_RESTORE" \
  && ok "GREEN: the shipped binary measures the same state as ROUTED again" \
  || bad "the shipped binary did not restore the measured verdict"

# ── the REFRESH PATH ─────────────────────────────────────────────────────────
# Drift that can be SEEN but not CORRECTED is half an answer, and the half that
# leaves a stale record on disk for the next reader. `rewire` re-runs step 6 and
# nothing else against an already-installed module: no fetch, no consent, no
# invariant run, no removal. It calls the same wire_module() the add path calls,
# so a refreshed record cannot describe a different measurement than an add would
# have taken — there is no second implementation to drift.
RCPT_BEFORE="$(sha_file "$STATE/envwire/receipt.json")"
INV_BEFORE="$(sha_file "$STATE/envwire/invariants.json")"
RW="$(HMD_WIRE_FIXTURE_URL="http://127.0.0.1:8080" hmd rewire envwire 2>&1)"; RCRW=$?
[ "$RCRW" -eq 0 ] \
  && ok "\`rewire\` on an installed module exits 0" \
  || bad "\`rewire\` failed (exit $RCRW): $(printf '%s' "$RW" | tail -2 | tr '\n' ' ')"
[ "$(jq -r '.wires[0].routed' "$EW" 2>/dev/null)" = "true" ] \
  && ok "and REWROTE the stale record to what the machine actually says (routed=true)" \
  || bad "rewire did not refresh the stored record"
[ "$(sha_file "$STATE/envwire/receipt.json")" = "$RCPT_BEFORE" ] \
  && ok "the receipt is BYTE-IDENTICAL — nothing was re-fetched, re-consented or re-installed" \
  || bad "rewire disturbed the install receipt"
[ "$(sha_file "$STATE/envwire/invariants.json")" = "$INV_BEFORE" ] \
  && ok "the invariant evidence is BYTE-IDENTICAL — rewire re-ran no invariants" \
  || bad "rewire disturbed the invariant record"
S_FIX="$(HMD_WIRE_FIXTURE_URL="http://127.0.0.1:8080" hmd status envwire 2>&1)"
grep -q 'add-time record says' <<<"$S_FIX" \
  && bad "the drift note survived the refresh — rewire did not actually correct the record" \
  || ok "and the drift note is GONE, because the record now agrees with the machine"

# Idempotent: same machine, run it again, identical verdicts.
WSUM="$(jq -S '{declared, routed, wires}' "$EW")"
HMD_WIRE_FIXTURE_URL="http://127.0.0.1:8080" hmd rewire envwire >/dev/null 2>&1
[ "$(jq -S '{declared, routed, wires}' "$EW")" = "$WSUM" ] \
  && ok "a second \`rewire\` on an unchanged machine produces identical verdicts (idempotent)" \
  || bad "rewire is not idempotent — two runs on one machine disagree"

# It refuses what it cannot refresh rather than inventing a record for it.
PRE_RW="$(tree_sum "$STATE")"
hmd rewire not-a-module >/dev/null 2>&1 \
  && bad "rewire accepted a module that is not installed" \
  || ok "rewire REFUSES a module that is not installed"
[ "$(tree_sum "$STATE")" = "$PRE_RW" ] \
  && ok "and left the state tree BYTE-IDENTICAL doing so" || bad "the refused rewire left residue"
hmd remove envwire >/dev/null 2>&1

echo
echo "--------------------------------------------------------------------"
printf 'wire-kind-dispatch: %s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
