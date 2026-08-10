#!/usr/bin/env bash
#
# module-upstream-fetch.test.sh — acceptance for the UPSTREAM PAYLOAD path in
# bin/heimdall-modules: the fetch actually runs, and only the WORLD may authorise
# the word "Installed".
#
# THE DEFECT THIS FILE EXISTS TO KEEP DEAD. `hmd modules add headroom` printed
#
#     [5/7] install + digest-verify        (the step was CALLED that at the time;
#           digest: deferred-upstream       it is `install + provenance` now — see
#                                           test/module-provenance-honesty.test.sh)
#     Installed "headroom" at pin 0.33.0 (class traffic-proxy + storage-codec).
#
# while `uv tool list` said `No tools installed`. Nothing had been fetched: the
# manifest's `installs_via.fetch` was VALIDATED and RECORDED and never executed.
# A green word over an absent install is the exact failure class this repo exists
# to prevent, and it shipped anyway — because nothing asserted the difference.
#
# THE ASSERTION THAT WOULD HAVE CAUGHT IT (U3): a fetch that EXITS 0 AND INSTALLS
# NOTHING must report ABSENT. An exit code is the installer's opinion of itself;
# the probe is a fact. Any check that trusts the exit code passes U2 and fails U3,
# which is why U3 is the centre of this file rather than a nice extra.
#
# HOW THIS RUNS WITHOUT THE NETWORK OR A 2-4 GB ML STACK. Every arm drives a FAKE
# `uv` placed first on PATH. It is a real program with a real tool store (a
# directory of files) that `uv tool list` reads back — so presence here is read
# from a world, exactly as it is in production, and the arms differ only in what
# that world contains. No arm reaches PyPI and no arm installs anything real.
#
# WHY THE FIXTURE FETCH IS A `uv` LINE. The presence probe is DERIVED from the
# recorded fetch command (`uv tool install … "pkg[extras]==ver"` -> ask
# `uv tool list` for `pkg`), so a fixture that used some other installer would be
# testing the decline path, not the acquire path. U6 covers the decline path
# separately with an installer hmd cannot question.
#
# Guarantees proved:
#   U1  the fetch is EXECUTED — the recorded command really runs, with its
#       arguments, and `add` reports the payload PRESENT.
#   U2  a fetch that fails is reported ABSENT with the blocker and the remedy,
#       rolls back BYTE-IDENTICALLY, and never prints "Installed".
#   U3  THE DIFFERENTIAL: a fetch that exits 0 and installs nothing is ABSENT,
#       never "Installed". Presence comes from the world, not the exit code.
#   U4  FALSIFIABILITY OF U3 — the presence check is disabled in a copy of the
#       binary and U3's assertions go RED; restored, they go GREEN.
#   U5  a payload already present is not re-fetched.
#   U6  an installer hmd cannot question is NOT run blind — the module registers
#       at its pin and the operator's command is printed.
#   U7  the dryrun seam decides and logs without executing, and CANNOT manufacture
#       a present payload.
#   U8  `hmd update` stays exit 0 while a default module is absent — a failed
#       module install never fails hmd.
#   U9  the receipt carries the payload verdict, and `Installed` appears in the
#       output only when the receipt says present.
#
# Usage:  bash test/module-upstream-fetch.test.sh   (exit 0 = every guarantee holds)
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SELF_DIR/.." && pwd)"
MODS="$REPO/bin/heimdall-modules"

command -v jq >/dev/null 2>&1 || { echo "error: jq is required" >&2; exit 2; }

PASS=0; FAIL=0
ok()  { printf '  \033[32mPASS\033[0m %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAIL=$((FAIL+1)); }

# The falsifier runs a MUTATED copy of the binary, and that copy has to sit in the
# repo's own bin/ — the tool resolves its plugin directory (and therefore the
# preflight library it cannot run without) from its own path, so a mutant parked
# in /tmp would die on a missing library and "fail" for the wrong reason. It is
# named per-PID and removed by the same trap that clears the temp tree.
MUTANT="$REPO/bin/.heimdall-modules.mutant.$$"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP" "$MUTANT"' EXIT

REG="$TMP/registry"

# THE FAKE INSTALLER (a real program, not a stand-in). Its tool store is a directory; `install` creates a file in
# it and `list` prints the directory back in uv's `<name> v<version>` shape. The
# three behaviours the arms need are selected by FAKE_UV_MODE:
#   land     install, and really record the tool          (a working installer)
#   fail     exit non-zero, record nothing                (no network / no python)
#   lie      exit 0, record NOTHING                       (THE BUG SHAPE)
# It also appends every invocation to a log, which is how U1 proves the real
# command ran rather than inferring it from an outcome.
FAKEBIN="$TMP/fakebin"
STORE="$TMP/uvstore"
UVLOG="$TMP/uv-invocations.log"
mkdir -p "$FAKEBIN" "$STORE"
cat > "$FAKEBIN/uv" <<'FAKEUVEOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FAKE_UV_LOG"
store="$FAKE_UV_STORE"
if [ "${1:-}" = "tool" ] && [ "${2:-}" = "list" ]; then
  n=0
  for f in "$store"/*; do
    [ -f "$f" ] || continue
    n=$((n+1))
    printf '%s v%s\n' "$(basename "$f")" "$(cat "$f")"
  done
  [ "$n" -eq 0 ] && printf 'No tools installed\n'
  exit 0
fi
if [ "${1:-}" = "tool" ] && [ "${2:-}" = "install" ]; then
  case "${FAKE_UV_MODE:-land}" in
    fail) printf 'error: no interpreter and no network\n' >&2; exit 2 ;;
    lie)  printf 'Resolved 1 package in 3ms\n'; exit 0 ;;
  esac
  spec=""
  shift 2
  while [ $# -gt 0 ]; do
    case "$1" in
      --python|-p) shift 2 ;;
      -*) shift ;;
      *) spec="$1"; shift ;;
    esac
  done
  pkg="${spec%%\[*}"; pkg="${pkg%%==*}"
  ver="${spec##*==}"
  [ "$ver" = "$spec" ] && ver="0"
  printf '%s' "$ver" > "$store/$pkg"
  printf 'Installed 1 executable: %s\n' "$pkg"
  exit 0
fi
printf 'fake uv: unsupported: %s\n' "$*" >&2
exit 64
FAKEUVEOF
chmod +x "$FAKEBIN/uv"

export FAKE_UV_LOG="$UVLOG"
export FAKE_UV_STORE="$STORE"
export PATH="$FAKEBIN:$PATH"
# Preflight must not reach the network in any arm.
export HMD_PREFLIGHT_NO_NET=1
# The fixture's fake store is not 4 GB of anything; the disk floor is hmd's
# generic one and would otherwise block an add for a payload that is one file.
export HMD_PREFLIGHT_DISK_FLOOR_MB=1

store_reset() { rm -f "$STORE"/* 2>/dev/null; : > "$UVLOG"; }
store_has()   { [ -f "$STORE/$1" ]; }

# A deterministic fingerprint of a tree that distinguishes ABSENT from EMPTY — an
# add that leaves an empty directory behind has still left residue.
sha_file() { shasum -a 256 "$1" | awk '{print $1}'; }
tree_sum() {
  [ -e "$1" ] || { printf 'ABSENT\n'; return 0; }
  ( cd "$1" && find . -mindepth 1 | LC_ALL=C sort | while IFS= read -r p; do
      if [ -d "$p" ]; then printf 'd %s\n' "$p"
      else printf 'f %s %s\n' "$p" "$(sha_file "$p")"
      fi
    done ) | shasum -a 256 | awk '{print $1}'
}

# A permissive fixture class: this file is about the acquire path, so the class
# contract carries one trivially-true invariant rather than the repo's real
# falsifiers, which modules-lifecycle and headroom-module already gate.
mkdir -p "$REG/_classes"
cat > "$REG/_classes/fx-net.json" <<'EOF'
{
  "class": "fx-net",
  "consent_required": false,
  "requires_invariants": [
    {"id": "fixture-ok",
     "description": "a fixture invariant that holds",
     "check": {"kind": "suite", "command": "printf FIXTURE-OK",
               "expect": "FIXTURE-OK", "expect_exit": 0}}
  ]
}
EOF

# mkmodule <name> <fetch command>
mkmodule() {
  local name="$1" fetch="$2"
  mkdir -p "$REG/$name"
  jq -n --arg n "$name" --arg f "$fetch" \
    '{name:$n, description:"upstream fixture", upstream:"https://example.invalid/x",
      license:"MIT",
      pinned_version:{version:"1.0.0", artifact:($n + "-1.0.0.tar.gz"),
        artifact_sha256:"0000000000000000000000000000000000000000000000000000000000000000"},
      permission_class:"fx-net", tier:"available",
      installs_via:{kind:"upstream", fetch:$f},
      wires:[{kind:"env", target:"FIXTURE_TARGET"}],
      invariants:{}}' > "$REG/$name/manifest.json"
}

# Every arm points --state at a scratch root. `add` performs a machine-global
# fetch only for hmd's CANONICAL state root — a global install booked into a
# scratch directory is an orphan `remove` cannot find — so each arm also opts in
# explicitly via HMD_MODULE_STATE_IS_CANONICAL, which exists for exactly this.
STATE="$TMP/state/modules"
hmd() { HMD_MODULE_STATE_IS_CANONICAL=1 "$MODS" --registry "$REG" --state "$STATE" "$@"; }

printf '\n\033[1mmodule-upstream-fetch — the fetch runs, and only the world says "Installed"\033[0m\n'

# ── U1. THE FETCH IS EXECUTED ────────────────────────────────────────────────
printf '\n\033[1mU1  the recorded fetch command really runs\033[0m\n'
mkmodule lands 'uv tool install --python 3.13 "lands-pkg[all]==1.0.0"'
store_reset
STATE_PRE="$(tree_sum "$STATE")"
FAKE_UV_MODE=land OUT="$(FAKE_UV_MODE=land hmd add lands --yes 2>&1)"; RC=$?
[ "$RC" -eq 0 ] && ok "add exits 0 when the payload lands" || { bad "add exited $RC"; printf '%s\n' "$OUT" | tail -12; }
grep -q 'tool install --python 3.13 lands-pkg\[all\]==1.0.0' "$UVLOG" \
  && ok "the fetch RAN, with the manifest's exact arguments" \
  || { bad "the fetch never ran (log: $(tr '\n' '|' < "$UVLOG"))"; }
store_has lands-pkg && ok "the installer really recorded the tool" || bad "nothing landed in the store"
grep -q 'Installed "lands" at pin 1.0.0' <<<"$OUT" \
  && ok 'a PRESENT payload may print `Installed`' || bad "no Installed line for a present payload"
grep -q 'payload: PRESENT' <<<"$OUT" \
  && ok "step 5 reports the payload PRESENT" || bad "step 5 did not report presence"
[ "$(jq -r '.payload.present' "$STATE/lands/receipt.json" 2>/dev/null)" = "true" ] \
  && ok "the receipt records payload.present = true" || bad "receipt does not record presence"
[ "$(jq -r '.digest.status' "$STATE/lands/receipt.json" 2>/dev/null)" = "present-upstream" ] \
  && ok "the digest reads present-upstream, not deferred-upstream" \
  || bad "digest status is $(jq -r '.digest.status' "$STATE/lands/receipt.json" 2>/dev/null)"
[ "$(jq -r '.payload.probe' "$STATE/lands/receipt.json" 2>/dev/null)" = "uv tool list" ] \
  && ok "the receipt names the probe that was used" || bad "no probe recorded"
hmd remove lands >/dev/null 2>&1
[ "$(tree_sum "$STATE")" = "$STATE_PRE" ] && ok "state is clean after U1" || bad "U1 left residue"

# ── U2. A FAILED FETCH IS ABSENT, NOT A GREEN ────────────────────────────────
printf '\n\033[1mU2  a fetch that FAILS reports ABSENT and rolls back byte-identically\033[0m\n'
mkmodule breaks 'uv tool install --python 3.13 "breaks-pkg==1.0.0"'
store_reset
STATE_PRE="$(tree_sum "$STATE")"
OUT="$(FAKE_UV_MODE=fail hmd add breaks --yes 2>&1)"; RC=$?
grep -q 'Installed "breaks"' <<<"$OUT" \
  && bad "printed Installed over a failed fetch" \
  || ok 'a failed fetch never prints `Installed`'
grep -q 'ABSENT: "breaks" was NOT installed' <<<"$OUT" \
  && ok "it says ABSENT in as many words" || bad "no ABSENT report"
grep -q 'blocker:' <<<"$OUT" && ok "the report names the blocker" || bad "no blocker named"
grep -q 'remedy:.*uv tool install' <<<"$OUT" \
  && ok "the report names the remedy — the operator's exact command" || bad "no remedy named"
grep -qi 'hmd itself is unaffected' <<<"$OUT" \
  && ok "it states hmd itself is unaffected" || bad "no statement that hmd is fine"
[ "$RC" -ne 0 ] && ok "add reports the failure to its caller (exit $RC)" \
                || bad "add exited 0 over a payload that never arrived"
[ ! -e "$STATE/breaks" ] && ok "no install directory survives a failed fetch" || bad "install dir left behind"
[ "$(tree_sum "$STATE")" = "$STATE_PRE" ] \
  && ok "the tree is BYTE-IDENTICAL to pre-add — rollback went through remove's path" \
  || bad "a failed fetch left residue"

# ── U3. THE DIFFERENTIAL — exit 0 that installs nothing ──────────────────────
printf '\n\033[1mU3  DIFFERENTIAL: a fetch that exits 0 and installs NOTHING is ABSENT\033[0m\n'
mkmodule liar 'uv tool install --python 3.13 "liar-pkg==1.0.0"'
store_reset
STATE_PRE="$(tree_sum "$STATE")"
OUT="$(FAKE_UV_MODE=lie hmd add liar --yes 2>&1)"; RC=$?
grep -q 'tool install' "$UVLOG" && ok "the fetch ran and exited 0" || bad "the fetch did not run"
store_has liar-pkg && bad "the fixture actually installed something — the arm is not testing the bug" \
                   || ok "the world is genuinely empty after that exit 0"
grep -q 'Installed "liar"' <<<"$OUT" \
  && bad "THE BUG IS BACK: printed Installed over an exit-0 fetch that landed nothing" \
  || ok 'an exit-0 fetch that landed nothing never prints `Installed`'
grep -q 'ABSENT: "liar" was NOT installed' <<<"$OUT" \
  && ok "it is reported ABSENT" || bad "not reported absent"
grep -q 'exited 0 but' <<<"$OUT" \
  && ok "the blocker says the exit code disagreed with the world" || bad "blocker does not name the disagreement"
[ "$RC" -ne 0 ] && ok "add does not report success (exit $RC)" || bad "add exited 0"
[ ! -e "$STATE/liar/receipt.json" ] && ok "no receipt claims an install that did not happen" || bad "receipt written"
[ "$(tree_sum "$STATE")" = "$STATE_PRE" ] && ok "rollback is byte-identical" || bad "residue left"

# ── U4. FALSIFIABILITY OF U3 ─────────────────────────────────────────────────
# A differential that cannot fail proves nothing. Break the presence check in a
# COPY of the binary — make it trust the fetch's exit code, which is precisely
# the defect — and U3's two load-bearing assertions must go RED.
printf '\n\033[1mU4  falsifier: break the presence check and U3 goes RED\033[0m\n'
cp "$MODS" "$MUTANT"
# `probe_lists_package` is what turns probe output into a verdict. Make it answer
# "yes" unconditionally: the fetch's exit 0 now decides, exactly as it used to.
perl -0pi -e 's/^probe_lists_package\(\) \{\n/probe_lists_package() {\n  return 0\n/m' "$MUTANT"
chmod +x "$MUTANT"
grep -q 'probe_lists_package() {' "$MUTANT" && grep -A1 'probe_lists_package() {' "$MUTANT" | grep -q 'return 0' \
  && ok "the mutant's presence check was really disabled" || bad "mutation did not apply"

store_reset
RED=0; GREEN=0
MOUT="$(FAKE_UV_MODE=lie HMD_MODULE_STATE_IS_CANONICAL=1 "$MUTANT" --registry "$REG" --state "$STATE" add liar --yes 2>&1)"
grep -q 'Installed "liar"' <<<"$MOUT" && RED=$((RED+1))
grep -q 'ABSENT: "liar" was NOT installed' <<<"$MOUT" || RED=$((RED+1))
[ "$RED" -eq 2 ] \
  && ok "RED ARM: with the presence check disabled, hmd claims Installed over nothing (2/2 assertions flipped)" \
  || bad "the mutant did not reproduce the defect — RED count $RED/2, so U3 may be vacuous"
HMD_MODULE_STATE_IS_CANONICAL=1 "$MUTANT" --registry "$REG" --state "$STATE" remove liar >/dev/null 2>&1

store_reset
OUT="$(FAKE_UV_MODE=lie hmd add liar --yes 2>&1)"
grep -q 'Installed "liar"' <<<"$OUT" || GREEN=$((GREEN+1))
grep -q 'ABSENT: "liar" was NOT installed' <<<"$OUT" && GREEN=$((GREEN+1))
[ "$GREEN" -eq 2 ] \
  && ok "GREEN ARM: the shipped binary reports ABSENT for the same fetch (2/2)" \
  || bad "the shipped binary did not report absent — GREEN count $GREEN/2"

# ── U5. ALREADY PRESENT IS NOT RE-FETCHED ────────────────────────────────────
printf '\n\033[1mU5  a payload already on the machine is not fetched again\033[0m\n'
mkmodule already 'uv tool install --python 3.13 "already-pkg==1.0.0"'
store_reset
printf '1.0.0' > "$STORE/already-pkg"
: > "$UVLOG"
OUT="$(FAKE_UV_MODE=fail hmd add already --yes 2>&1)"; RC=$?
[ "$RC" -eq 0 ] && ok "add exits 0 for a payload that is already there" || bad "add exited $RC"
grep -q 'tool install' "$UVLOG" \
  && bad "re-fetched a payload that was already present" \
  || ok "no fetch was attempted — the world was asked first"
grep -q 'Installed "already" at pin 1.0.0' <<<"$OUT" \
  && ok "an already-present payload is honestly Installed" || bad "no Installed line"
grep -q 'already present' <<<"$OUT" \
  && ok "the reason names that it was already present" || bad "reason does not say so"
hmd remove already >/dev/null 2>&1

# ── U6. AN INSTALLER hmd CANNOT QUESTION IS NOT RUN BLIND ────────────────────
printf '\n\033[1mU6  an installer with no world-probe is NOT run blind\033[0m\n'
mkmodule opaque 'someinstaller add example@1.0.0'
store_reset
OUT="$(hmd add opaque --yes 2>&1)"; RC=$?
[ "$RC" -eq 0 ] && ok "add exits 0 — registering at a pin is a real outcome" || bad "add exited $RC"
grep -q 'Installed "opaque"' <<<"$OUT" \
  && bad "claimed Installed for an unverifiable installer" \
  || ok 'no `Installed` claim for an installer hmd cannot question'
grep -q 'Registered "opaque" at pin 1.0.0' <<<"$OUT" \
  && ok "it is reported REGISTERED, which is what actually happened" || bad "no Registered line"
grep -q 'PAYLOAD NOT PRESENT' <<<"$OUT" \
  && ok "the output states the payload is not present" || bad "presence not stated"
grep -q 'someinstaller add example@1.0.0' <<<"$OUT" \
  && ok "the operator's exact command is printed" || bad "the fetch command was not printed"
[ "$(jq -r '.payload.present' "$STATE/opaque/receipt.json" 2>/dev/null)" = "false" ] \
  && ok "the receipt records payload.present = false" || bad "receipt does not record absence"
[ "$(jq -r '.digest.status' "$STATE/opaque/receipt.json" 2>/dev/null)" = "deferred-upstream" ] \
  && ok "the digest stays deferred-upstream — no verification is claimed" || bad "wrong digest status"
[ "$(jq -r '.payload.fetch_ran' "$STATE/opaque/receipt.json" 2>/dev/null)" = "false" ] \
  && ok "the receipt records that the fetch did NOT run" || bad "fetch_ran not recorded honestly"
hmd remove opaque >/dev/null 2>&1

# ── U7. THE DRYRUN SEAM ──────────────────────────────────────────────────────
printf '\n\033[1mU7  the dryrun seam decides without executing, and cannot fake presence\033[0m\n'
mkmodule dry 'uv tool install --python 3.13 "dry-pkg==1.0.0"'
store_reset
OUT="$(HMD_MODULE_FETCH_DRYRUN=1 FAKE_UV_MODE=land hmd add dry --yes 2>&1)"; RC=$?
grep -q 'tool install' "$UVLOG" && bad "the dryrun seam still ran the fetch" || ok "the fetch did NOT execute"
grep -q 'tool list' "$UVLOG" \
  && ok "the world was still probed — the seam weakens the action, not the check" \
  || bad "the seam skipped the probe too"
grep -q 'Installed "dry"' <<<"$OUT" \
  && bad "the seam manufactured an Installed claim" \
  || ok "a dryrun can never print Installed for an absent payload"
grep -q 'Registered "dry"' <<<"$OUT" && ok "it reports Registered" || bad "no Registered line"
[ "$RC" -eq 0 ] && ok "the dryrun add exits 0" || bad "dryrun add exited $RC"
hmd remove dry >/dev/null 2>&1
# The seam cannot even lie when the payload IS there: presence still comes from
# the world, so the answer flips to present without the fetch ever running.
store_reset
printf '1.0.0' > "$STORE/dry-pkg"
: > "$UVLOG"
OUT="$(HMD_MODULE_FETCH_DRYRUN=1 hmd add dry --yes 2>&1)"
grep -q 'tool install' "$UVLOG" && bad "dryrun fetched" || ok "still no fetch under the seam"
grep -q 'Installed "dry"' <<<"$OUT" \
  && ok "with the payload really present, the seam reports the truth: Installed" \
  || bad "the seam suppressed a true presence"
hmd remove dry >/dev/null 2>&1

# ── U8. A FAILED MODULE NEVER FAILS hmd ──────────────────────────────────────
printf '\n\033[1mU8  `hmd update` stays exit 0 while a default module cannot be acquired\033[0m\n'
UPD="$REPO/bin/heimdall-autoupdate"
if [ -x "$UPD" ]; then
  UH="$TMP/home"; US="$TMP/upstate/modules"
  mkdir -p "$UH"
  VER="$(jq -r '.version // "0.0.0"' "$REPO/plugin.json" 2>/dev/null || echo 0.0.0)"
  # A registry whose ONLY default-included module has a fetch that always fails.
  UREG="$TMP/upreg"
  mkdir -p "$UREG/_classes"
  cp "$REG/_classes/fx-net.json" "$UREG/_classes/"
  mkdir -p "$UREG/failing"
  jq -n '{name:"failing", description:"a default module that cannot be acquired",
      upstream:"https://example.invalid/x", license:"MIT",
      pinned_version:{version:"1.0.0", artifact:"failing-1.0.0.tar.gz",
        artifact_sha256:"0000000000000000000000000000000000000000000000000000000000000000"},
      permission_class:"fx-net", default_included:true,
      installs_via:{kind:"upstream", fetch:"uv tool install --python 3.13 \"failing-pkg==1.0.0\""},
      wires:[], invariants:{}}' > "$UREG/failing/manifest.json"
  store_reset
  OUT="$(env FAKE_UV_MODE=fail HOME="$UH" HEIMDALL_HOME="$UH" \
        HMD_MODULES_REGISTRY="$UREG" HMD_MODULES_STATE="$US" \
        HEIMDALL_LATEST_OVERRIDE="$VER" HEIMDALL_INSTALLED_OVERRIDE="$VER" \
        HEIMDALL_AUTOUPDATE_DRYRUN=1 HEIMDALL_MODULE_ACQUIRE_SYNC=1 \
        "$UPD" update 2>&1)"; RC=$?
  [ "$RC" -eq 0 ] \
    && ok "hmd update exits 0 with a default module that could not be acquired" \
    || { bad "hmd update exited $RC — a failed module must never fail hmd"; printf '%s\n' "$OUT" | tail -8; }
  [ ! -e "$US/failing/receipt.json" ] \
    && ok "no receipt claims the module that could not be acquired" || bad "a receipt was written anyway"
  [ -x "$MODS" ] && ok "hmd's own module binary is still installed and executable" || bad "hmd damaged itself"
else
  bad "bin/heimdall-autoupdate is missing — cannot prove hmd update stays green"
fi

# ── U9. THE RECEIPT IS THE SOURCE OF THE CLAIM ───────────────────────────────
printf '\n\033[1mU9  `Installed` in the output agrees with `payload.present` in the receipt\033[0m\n'
mkmodule agree 'uv tool install --python 3.13 "agree-pkg==1.0.0"'
for mode in land lie; do
  store_reset
  OUT="$(FAKE_UV_MODE=$mode hmd add agree --yes 2>&1)"
  SAID_INSTALLED=no
  grep -q 'Installed "agree"' <<<"$OUT" && SAID_INSTALLED=yes
  RECEIPT_SAYS="$(jq -r '.payload.present // false' "$STATE/agree/receipt.json" 2>/dev/null || echo false)"
  WANT=no; [ "$RECEIPT_SAYS" = "true" ] && WANT=yes
  [ "$SAID_INSTALLED" = "$WANT" ] \
    && ok "mode=$mode: the printed claim matches the receipt (installed=$SAID_INSTALLED, receipt=$RECEIPT_SAYS)" \
    || bad "mode=$mode: printed installed=$SAID_INSTALLED but the receipt says present=$RECEIPT_SAYS"
  hmd remove agree >/dev/null 2>&1
done
# And the store, which is the world these arms share, is left as we found it.
store_reset
[ -z "$(ls -A "$STORE" 2>/dev/null)" ] && ok "the fixture tool store is empty at the end" || bad "fixture store dirty"

printf '\n--------------------------------------------------------------------\n'
printf 'module-upstream-fetch: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
