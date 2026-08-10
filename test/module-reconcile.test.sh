#!/usr/bin/env bash
# module-reconcile.test.sh — an install that PREDATES a default module acquires it on update.
#
# THE GAP THIS COVERS. `repair` fixes a module install that was ATTEMPTED and broke.
# It cannot help the install that shipped before the module existed: that machine never
# had a failed install to repair, it has NOTHING, and nothing in the update path ever
# looked at the registry to notice. Repair and first-acquisition are different problems
# and only the first was built. This suite gates the second.
#
# THE RULE UNDER TEST is deliberately NOT "special-case headroom". It is: reconcile the
# INSTALLED module set against the DEFAULT set (every manifest with `default_included`
# true). R5/R6 run that rule over a SYNTHETIC registry containing modules that do not
# exist in this repo, which is what proves the next default module needs no new code.
#
# NOTHING IS INSTALLED, FETCHED OR DOWNLOADED. Every acquisition test runs under the
# decide-only seam HEIMDALL_MODULE_RECONCILE_DRYRUN=1, and the two tests that exercise
# the real spawn path point HMD_MODULES_BIN at a local stub. No network, no uv, no
# payload, and no write outside a throwaway HOME / temp registry / temp state root.
#
# WHAT IT PROVES (each with the falsifier that makes it mean something):
#   R1. REAL registry: headroom is in the default set, is absent, is not opted out, and
#       its own manifest WAIVES the consent question → update ACQUIRES it, records that
#       the waiver (not a prompt) is why, and stops claiming an update "will never
#       install it for you". The decide-only seam still writes no receipt.
#       R1 read the other way round until the updater was fixed: it consulted only the
#       CLASS contract, so it deferred a module `hmd modules add` installs with no
#       prompt, and the two binaries disagreed about the same module. The waiver-aware
#       transitions live in test/autoupdate-consent-waiver.test.sh; R1 pins the one
#       decision the REAL registry produces today.
#   R2. HEALTHY → no-op: zero stdout, zero stderr, and the registry + state trees are
#       BYTE-IDENTICAL before and after (a tree signature over names + content hashes).
#   R3. BROKEN (receipt present, payload gone) is NOT re-acquired — it belongs to the
#       repair path. Reconcile handling it too would double-install.
#   R4. OPTED OUT stays opted out: (a) HEIMDALL_NO_MODULES=1, (b) the modules-optout
#       file. Neither acquires and neither NAGS — a nag is a soft revert.
#   R4c FALSIFIER: a mutant of the updater with the opt-out guard removed DOES select
#       the module. The opt-out assertion can go RED, so its GREEN is worth something.
#   R5. GENERALISATION: a NON-consent default module absent from a synthetic registry
#       is selected for acquisition with zero code that knows its name.
#   R6. A module with `default_included` false is never touched.
#   R7. IDEMPOTENT: two consecutive runs produce identical decisions and byte-identical
#       trees. No re-install, no re-download, no accrued state.
#   R8. `--yes` is NEVER passed to `heimdall-modules` from the updater (structural).
#       Auto-consent from a background SessionStart process is the trust incident.
#   R9. uv ABSENT (PATH scrubbed): `update` still exits 0, no receipt appears, and
#       `status` NAMES uv as the blocker with its remedy.
#   R10. A FAILING acquisition never breaks the update: a stub modules bin that exits 1
#       leaves `update` at exit 0.
#   R11. Reconcile NEVER prompts and never reads a terminal (structural + behavioural:
#        it runs identically with stdin closed).
#
# Exit 0 = every proof holds.

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SELF_DIR/.." && pwd)"
BIN="$REPO/bin/heimdall-autoupdate"

[ -x "$BIN" ] || { echo "FATAL: $BIN missing/not executable" >&2; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "FATAL: jq is required" >&2; exit 2; }

PASS=0
FAIL=0
ok()  { PASS=$((PASS+1)); printf "  \033[32mPASS\033[0m %s\n" "$1"; }
bad() { FAIL=$((FAIL+1)); printf "  \033[31mFAIL\033[0m %s\n" "$1"; }

# Everything transient lands here and is swept on exit — including the falsifier mutant,
# which must live inside bin/ so its PLUGIN_DIR resolution matches the real script's.
TMPROOT="$(mktemp -d -t hmd-recon)"
MUTANT="$REPO/bin/.heimdall-autoupdate.falsifier.$$"
cleanup() { rm -rf "$TMPROOT" 2>/dev/null; rm -f "$MUTANT" 2>/dev/null; }
trap cleanup EXIT INT TERM

# The installed version is resolved from the repo tag; pin BOTH sides equal so no test
# ever reaches the network or decides to apply. We are testing modules, not semver.
VER="2.0.0"
# Common env for a run that touches no network and applies nothing.
# shellcheck disable=SC2086
NONET="HEIMDALL_LATEST_OVERRIDE=$VER HEIMDALL_INSTALLED_OVERRIDE=$VER HEIMDALL_AUTOUPDATE_DRYRUN=1"

mk_home()  { mktemp -d "$TMPROOT/home.XXXXXX"; }
mk_state() { mktemp -d "$TMPROOT/state.XXXXXX"; }

# A byte-level signature of a tree: every path AND the content hash of every file.
# A re-download, a re-install or any accrued state changes this string.
tree_sig() {
  { find "$1" 2>/dev/null | sort
    find "$1" -type f -print0 2>/dev/null | sort -z | xargs -0 shasum 2>/dev/null
  } | shasum | awk '{print $1}'
}

# Mark a module INSTALLED the only way the module system recognises: a receipt.
mk_receipt() {
  local state="$1" name="$2"
  mkdir -p "$state/$name"
  jq -n --arg n "$name" '{name:$n, pinned_version:{version:"1.0.0"}, installed_at:"2026-01-01T00:00:00Z"}' \
    > "$state/$name/receipt.json"
}

# A synthetic registry. `class` picks the permission class, which is what decides
# whether acquisition needs a human's yes — the test never hardcodes that decision.
mk_registry() {
  local reg="$1"; mkdir -p "$reg/_classes"
  cp "$REPO"/modules/_classes/*.json "$reg/_classes/" 2>/dev/null
  printf '%s' "$reg"
}
add_manifest() {
  local reg="$1" name="$2" class="$3" default_included="$4"
  mkdir -p "$reg/$name"
  jq -n --arg n "$name" --arg c "$class" --argjson d "$default_included" \
    '{name:$n, description:"synthetic test module", upstream:"https://example.invalid/x",
      license:"Apache-2.0", tier:"available", default_included:$d,
      pinned_version:{version:"1.0.0", artifact:"x-1.0.0.tar.gz",
        artifact_sha256:"0000000000000000000000000000000000000000000000000000000000000000"},
      permission_class:$c, installs_via:{kind:"upstream", fetch:"uv tool install --python 3.13 \"x==1.0.0\""},
      wires:[], invariants:{}, consent_text:"synthetic disclosure for the test registry"}' \
    > "$reg/$name/manifest.json"
}

# A stand-in for bin/heimdall-modules that RECORDS its argv instead of installing
# anything. `exit_code` lets a test make acquisition fail on purpose (R10).
mk_stub_modules() {
  local path="$1" exit_code="$2" argv_log="$3"
  cat > "$path" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$argv_log"
exit $exit_code
STUB
  chmod +x "$path"
}

# Run the updater with a scrubbed, explicit environment. Everything the reconcile
# reads is passed here, so no test can accidentally depend on the developer's shell.
run_upd() {
  local home="$1" reg="$2" state="$3"; shift 3
  env -u HEIMDALL_NO_MODULES -u HMD_MODULES_BIN \
      HOME="$home" HEIMDALL_HOME="$home" \
      HMD_MODULES_REGISTRY="$reg" HMD_MODULES_STATE="$state" \
      HEIMDALL_LATEST_OVERRIDE="$VER" HEIMDALL_INSTALLED_OVERRIDE="$VER" \
      HEIMDALL_AUTOUPDATE_DRYRUN=1 \
      "$@"
}

printf "\n\033[1mmodule-reconcile — an install that predates a default module acquires it\033[0m\n\n"

# ── R1. REAL registry: headroom is in the default set, absent, not opted out ─────
printf "\033[1mR1  real registry — headroom's own waiver makes the update acquire it\033[0m\n"
H="$(mk_home)"; S="$(mk_state)"
OUT="$(run_upd "$H" "$REPO/modules" "$S" HEIMDALL_MODULE_RECONCILE_DRYRUN=1 "$BIN" update 2>&1)"
RC=$?
[ "$RC" -eq 0 ] && ok "update exits 0 with a default module absent" \
                || bad "update exited $RC (a missing module must never fail the update)"
grep -q 'reconcile: headroom would-acquire' "$H/autoupdate.log" 2>/dev/null \
  && ok "the decision is ACQUIRE — the updater honours the module's own waiver" \
  || bad "headroom was not selected for acquisition: $(cat "$H/autoupdate.log" 2>/dev/null)"
grep -q 'reconcile: headroom would-acquire.*consent waived' "$H/autoupdate.log" 2>/dev/null \
  && ok "the log SAYS the waiver is why — an unprompted acquire is not an undisclosed one" \
  || bad "the acquire decision does not record the waiver as its reason: $(cat "$H/autoupdate.log" 2>/dev/null)"
[ ! -f "$S/headroom/receipt.json" ] \
  && ok "nothing was installed (no receipt) — the decide-only seam decides and stops" \
  || bad "a receipt appeared under HEIMDALL_MODULE_RECONCILE_DRYRUN=1"
if grep -q 'reconcile: headroom defer-consent' "$H/autoupdate.log" 2>/dev/null; then
  bad "headroom is still deferred — the updater is reading the CLASS contract and ignoring the manifest waiver"
elif grep -q 'will never install it for you' <<<"$OUT"; then
  bad "update still tells the operator it will never install a module it now acquires"
else
  ok "the old defer-consent decision and its contradictory sentence are both gone"
fi

# ── R2. HEALTHY → no-op, zero output, byte-identical trees ───────────────────────
printf "\n\033[1mR2  healthy — no-op, zero output, byte-identical trees\033[0m\n"
H="$(mk_home)"; S="$(mk_state)"; REG="$(mk_registry "$TMPROOT/reg-healthy")"
add_manifest "$REG" "codecmod" '"storage-codec"' true
mk_receipt "$S" "codecmod"
SIG_REG_BEFORE="$(tree_sig "$REG")"; SIG_STATE_BEFORE="$(tree_sig "$S")"
OUT="$(run_upd "$H" "$REG" "$S" "$BIN" check 2>&1)"
RC=$?
[ "$RC" -eq 0 ] && ok "check exits 0" || bad "check exited $RC"
[ -z "$OUT" ] && ok "check printed ZERO bytes on stdout+stderr (a chatty updater gets disabled)" \
              || bad "check printed output on a healthy machine: [$OUT]"
[ "$(tree_sig "$REG")" = "$SIG_REG_BEFORE" ] \
  && ok "registry tree is byte-identical after the check" \
  || bad "the registry tree changed on a healthy no-op"
[ "$(tree_sig "$S")" = "$SIG_STATE_BEFORE" ] \
  && ok "state tree is byte-identical (no re-install, no re-download)" \
  || bad "the state tree changed on a healthy no-op"

# ── R3. BROKEN belongs to repair, not to acquisition ─────────────────────────────
printf "\n\033[1mR3  broken (receipt present, payload gone) is left to the repair path\033[0m\n"
H="$(mk_home)"; S="$(mk_state)"; REG="$(mk_registry "$TMPROOT/reg-broken")"
add_manifest "$REG" "codecmod" '"storage-codec"' true
mk_receipt "$S" "codecmod"
rm -rf "$S/codecmod/payload" 2>/dev/null; mkdir -p "$S/codecmod"   # receipt only: the broken shape
run_upd "$H" "$REG" "$S" HEIMDALL_MODULE_RECONCILE_DRYRUN=1 "$BIN" check >/dev/null 2>&1
grep -q 'reconcile: codecmod would-acquire' "$H/autoupdate.log" 2>/dev/null \
  && bad "reconcile tried to acquire a module that is already installed-but-broken (double-install)" \
  || ok "reconcile does NOT acquire a broken install — repair owns that transition"

# ── R4. OPTED OUT stays opted out, and does not nag ──────────────────────────────
printf "\n\033[1mR4  opted out — nothing installed, nothing offered\033[0m\n"
# (a) the env switch
H="$(mk_home)"; S="$(mk_state)"; REG="$(mk_registry "$TMPROOT/reg-opt-env")"
add_manifest "$REG" "codecmod" '"storage-codec"' true
OUT="$(env HOME="$H" HEIMDALL_HOME="$H" HMD_MODULES_REGISTRY="$REG" HMD_MODULES_STATE="$S" \
        HEIMDALL_LATEST_OVERRIDE="$VER" HEIMDALL_INSTALLED_OVERRIDE="$VER" \
        HEIMDALL_AUTOUPDATE_DRYRUN=1 HEIMDALL_MODULE_RECONCILE_DRYRUN=1 \
        HEIMDALL_NO_MODULES=1 "$BIN" update 2>&1)"
grep -q 'would-acquire' "$H/autoupdate.log" 2>/dev/null \
  && bad "HEIMDALL_NO_MODULES=1 was ignored — the updater selected a module anyway" \
  || ok "HEIMDALL_NO_MODULES=1 suppresses acquisition entirely"
grep -q 'codecmod' <<<"$OUT" \
  && bad "an opted-out module was still advertised (a nag is a soft revert)" \
  || ok "an opted-out module is not even mentioned"
[ ! -f "$S/codecmod/receipt.json" ] && ok "no receipt was created under the env opt-out" \
                                    || bad "the env opt-out still produced an install"

# (b) the file signal
H="$(mk_home)"; S="$(mk_state)"; REG="$(mk_registry "$TMPROOT/reg-opt-file")"
add_manifest "$REG" "codecmod" '"storage-codec"' true
mkdir -p "$H"; printf '# operator opted out\ncodecmod\n' > "$H/modules-optout"
run_upd "$H" "$REG" "$S" HEIMDALL_MODULE_RECONCILE_DRYRUN=1 "$BIN" update >/dev/null 2>&1
grep -q 'would-acquire' "$H/autoupdate.log" 2>/dev/null \
  && bad "the modules-optout file was ignored — the updater selected the module anyway" \
  || ok "the modules-optout file suppresses acquisition"
grep -q 'reconcile: codecmod skip-optout' "$H/autoupdate.log" 2>/dev/null \
  && ok "the opt-out decision is recorded as skip-optout" \
  || bad "no skip-optout decision recorded: $(cat "$H/autoupdate.log" 2>/dev/null)"
[ ! -f "$S/codecmod/receipt.json" ] && ok "no receipt was created under the file opt-out" \
                                    || bad "the file opt-out still produced an install"

# ── R4c. FALSIFIER — remove the opt-out guard and watch the assertion go RED ─────
printf "\n\033[1mR4c FALSIFIER — a mutant without the opt-out guard DOES select the module\033[0m\n"
# The mutant lives in bin/ so its SELF_DIR/PLUGIN_DIR resolve exactly like the real one.
sed 's/if module_opted_out .*; then/if false; then/' "$BIN" > "$MUTANT"
chmod +x "$MUTANT"
if ! grep -q 'if false; then' "$MUTANT"; then
  bad "the falsifier could not find the opt-out guard to mutate — the test has lost its grip on the code"
else
  H="$(mk_home)"; S="$(mk_state)"; REG="$(mk_registry "$TMPROOT/reg-falsify")"
  add_manifest "$REG" "codecmod" '"storage-codec"' true
  mkdir -p "$H"; printf 'codecmod\n' > "$H/modules-optout"
  run_upd "$H" "$REG" "$S" HEIMDALL_MODULE_RECONCILE_DRYRUN=1 "$MUTANT" update >/dev/null 2>&1
  grep -q 'reconcile: codecmod would-acquire' "$H/autoupdate.log" 2>/dev/null \
    && ok "MUTANT ignores the opt-out and selects the module → the R4 assertion can go RED" \
    || bad "even the mutant did not select the module — R4 may be passing vacuously"
fi
rm -f "$MUTANT"

# ── R5. GENERALISATION — a non-consent default module is acquired, no new code ───
printf "\n\033[1mR5  generalisation — a NON-consent default module is acquired by the rule alone\033[0m\n"
H="$(mk_home)"; S="$(mk_state)"; REG="$(mk_registry "$TMPROOT/reg-general")"
add_manifest "$REG" "codecmod" '"storage-codec"' true
run_upd "$H" "$REG" "$S" HEIMDALL_MODULE_RECONCILE_DRYRUN=1 "$BIN" check >/dev/null 2>&1
grep -q 'reconcile: codecmod would-acquire' "$H/autoupdate.log" 2>/dev/null \
  && ok "a module this repo has never heard of is selected for acquisition" \
  || bad "the rule did not generalise: $(cat "$H/autoupdate.log" 2>/dev/null)"

# ── R6. default_included false is never touched ──────────────────────────────────
printf "\n\033[1mR6  a module outside the default set is never touched\033[0m\n"
H="$(mk_home)"; S="$(mk_state)"; REG="$(mk_registry "$TMPROOT/reg-nondefault")"
add_manifest "$REG" "optmod" '"storage-codec"' false
run_upd "$H" "$REG" "$S" HEIMDALL_MODULE_RECONCILE_DRYRUN=1 "$BIN" check >/dev/null 2>&1
grep -q 'optmod' "$H/autoupdate.log" 2>/dev/null \
  && bad "a module with default_included=false was reconciled" \
  || ok "default_included=false is outside the reconcile set"

# ── R7. IDEMPOTENT — two runs, identical decisions, identical trees ──────────────
printf "\n\033[1mR7  idempotent — repeated updates re-install nothing and accrue nothing\033[0m\n"
H="$(mk_home)"; S="$(mk_state)"; REG="$(mk_registry "$TMPROOT/reg-idem")"
add_manifest "$REG" "codecmod" '"storage-codec"' true
mk_receipt "$S" "codecmod"
SIG1="$(tree_sig "$S")"
O1="$(run_upd "$H" "$REG" "$S" "$BIN" check 2>&1)"
SIG2="$(tree_sig "$S")"
O2="$(run_upd "$H" "$REG" "$S" "$BIN" --force 2>&1)"
SIG3="$(tree_sig "$S")"
[ "$SIG1" = "$SIG2" ] && [ "$SIG2" = "$SIG3" ] \
  && ok "the state tree is byte-identical across three observations" \
  || bad "repeated updates mutated the state tree ($SIG1 / $SIG2 / $SIG3)"
[ "$O1" = "$O2" ] && [ -z "$O1" ] \
  && ok "both runs printed the same (empty) output" \
  || bad "repeated runs differ or are noisy: [$O1] vs [$O2]"

# ── R8. `--yes` is never passed — structural, and behavioural via the stub ───────
printf "\n\033[1mR8  the updater NEVER auto-consents\033[0m\n"
# Comment lines are stripped FIRST: the file explains at length why `--yes` must never
# be passed, and a check that cannot tell an invocation from a sentence about one would
# fire on its own documentation.
grep -vE '^[[:space:]]*#' "$BIN" | grep -E 'MODULES_BIN|\$mods' | grep -q -- '--yes' \
  && bad "the updater passes --yes to heimdall-modules — that auto-grants consent unattended" \
  || ok "no --yes in any of the updater's calls to heimdall-modules (fails closed)"
H="$(mk_home)"; S="$(mk_state)"; REG="$(mk_registry "$TMPROOT/reg-noyes")"
add_manifest "$REG" "codecmod" '"storage-codec"' true
ARGV="$TMPROOT/argv-noyes.log"; : > "$ARGV"
STUB="$TMPROOT/stub-ok"; mk_stub_modules "$STUB" 0 "$ARGV"
env HOME="$H" HEIMDALL_HOME="$H" HMD_MODULES_REGISTRY="$REG" HMD_MODULES_STATE="$S" \
    HMD_MODULES_BIN="$STUB" HEIMDALL_MODULE_ACQUIRE_SYNC=1 \
    HEIMDALL_LATEST_OVERRIDE="$VER" HEIMDALL_INSTALLED_OVERRIDE="$VER" \
    HEIMDALL_AUTOUPDATE_DRYRUN=1 "$BIN" check >/dev/null 2>&1
grep -q 'add codecmod' "$ARGV" 2>/dev/null \
  && ok "the real acquisition path invokes \`heimdall-modules add <name>\`" \
  || bad "the acquisition never reached the modules bin: $(cat "$ARGV" 2>/dev/null)"
grep -q -- '--yes' "$ARGV" 2>/dev/null \
  && bad "--yes reached heimdall-modules from an unattended path" \
  || ok "the invocation carries no --yes (heimdall-modules stays free to refuse)"

# ── R9. uv ABSENT — update survives, status names the reason ─────────────────────
printf "\n\033[1mR9  uv absent — hmd still updates, and status NAMES uv as the blocker\033[0m\n"
H="$(mk_home)"; S="$(mk_state)"
# A PATH with no uv on it. This machine HAS uv, so absence is simulated deliberately
# rather than assumed — the test must hold on both kinds of machine.
NOUV_PATH="$TMPROOT/nouv-bin"; mkdir -p "$NOUV_PATH"
for c in bash sh env jq shasum sed grep awk find sort head tail cat printf date mktemp rm mkdir chmod uname df dirname basename ls stat tr cut wc xargs touch mv cp ln readlink perl python3 curl git; do
  src="$(command -v "$c" 2>/dev/null)"; [ -n "$src" ] && ln -sf "$src" "$NOUV_PATH/$c" 2>/dev/null
done
command -v uv >/dev/null 2>&1 && ok "uv IS present on this machine — absence is simulated by a scrubbed PATH" \
                              || ok "uv is absent on this machine (the scrubbed PATH matches reality)"
[ ! -x "$NOUV_PATH/uv" ] && ok "the scrubbed PATH genuinely has no uv" || bad "the scrubbed PATH still exposes uv"
OUT="$(env -i PATH="$NOUV_PATH" HOME="$H" HEIMDALL_HOME="$H" \
        HMD_MODULES_REGISTRY="$REPO/modules" HMD_MODULES_STATE="$S" \
        HEIMDALL_LATEST_OVERRIDE="$VER" HEIMDALL_INSTALLED_OVERRIDE="$VER" \
        HEIMDALL_AUTOUPDATE_DRYRUN=1 HMD_PREFLIGHT_NO_NET=1 \
        bash "$BIN" update 2>&1)"
RC=$?
[ "$RC" -eq 0 ] && ok "hmd's own update succeeds with uv absent (exit 0)" \
                || bad "update exited $RC when uv was missing — a module must never fail the update"
[ ! -f "$S/headroom/receipt.json" ] && ok "the module stays absent (nothing faked)" \
                                    || bad "a receipt appeared without uv"
ST="$(env -i PATH="$NOUV_PATH" HOME="$H" HEIMDALL_HOME="$H" \
        HMD_MODULES_REGISTRY="$REPO/modules" HMD_MODULES_STATE="$S" \
        HEIMDALL_LATEST_OVERRIDE="$VER" HEIMDALL_INSTALLED_OVERRIDE="$VER" \
        HMD_PREFLIGHT_NO_NET=1 bash "$BIN" status 2>&1)"
grep -q 'headroom' <<<"$ST" \
  && ok "status lists the absent default module" \
  || bad "status does not mention the module at all: $ST"
grep -qi 'uv' <<<"$ST" \
  && ok "status NAMES uv as the blocking reason" \
  || bad "status does not name uv as the reason: $ST"
grep -q 'astral.sh/uv/install.sh' <<<"$ST" \
  && ok "status prints the exact remedy command for uv" \
  || bad "status names the blocker but not the fix: $ST"

# ── R10. A failing acquisition never breaks the update ───────────────────────────
printf "\n\033[1mR10 a failed acquisition never breaks hmd's own update\033[0m\n"
H="$(mk_home)"; S="$(mk_state)"; REG="$(mk_registry "$TMPROOT/reg-failacq")"
add_manifest "$REG" "codecmod" '"storage-codec"' true
ARGV="$TMPROOT/argv-fail.log"; : > "$ARGV"
STUB_BAD="$TMPROOT/stub-fail"; mk_stub_modules "$STUB_BAD" 1 "$ARGV"
OUT="$(env HOME="$H" HEIMDALL_HOME="$H" HMD_MODULES_REGISTRY="$REG" HMD_MODULES_STATE="$S" \
        HMD_MODULES_BIN="$STUB_BAD" HEIMDALL_MODULE_ACQUIRE_SYNC=1 \
        HEIMDALL_LATEST_OVERRIDE="$VER" HEIMDALL_INSTALLED_OVERRIDE="$VER" \
        HEIMDALL_AUTOUPDATE_DRYRUN=1 "$BIN" update 2>&1)"
RC=$?
[ "$RC" -eq 0 ] && ok "update exits 0 even though acquisition failed outright" \
                || bad "a failed module acquisition broke the update (exit $RC)"
[ ! -f "$S/codecmod/receipt.json" ] \
  && ok "the module stays absent with an honest status (no fake receipt)" \
  || bad "a receipt was written despite the acquisition failing"

# ── R11. Never prompts, never reads a terminal ───────────────────────────────────
printf "\n\033[1mR11 reconcile never prompts\033[0m\n"
H="$(mk_home)"; S="$(mk_state)"
OUT="$(run_upd "$H" "$REPO/modules" "$S" HEIMDALL_MODULE_RECONCILE_DRYRUN=1 "$BIN" update 2>&1 <&-)"
RC=$?
[ "$RC" -eq 0 ] && ok "update runs to completion with stdin CLOSED (nothing waits on a human)" \
                || bad "update exited $RC with stdin closed — something tried to read input"
# The real hazard is not `read` as such — every loop here reads from a heredoc. It is
# reading a TERMINAL, or prompting. Either would let a backgrounded SessionStart process
# seize a tty the caller never offered, or block forever waiting for a human who is not
# there. Consent belongs in `hmd modules add`, where a human is present by construction.
grep -nE '/dev/tty|read +-[a-z]*p' "$BIN" | grep -q . \
  && bad "the updater reads a terminal or prompts — consent must live in heimdall-modules" \
  || ok "the updater never touches /dev/tty and never prompts"

# ── Summary ──────────────────────────────────────────────────────────────────────
printf "\n"
if [ "$FAIL" -eq 0 ]; then
  printf "  \033[32m%s passed, %s failed\033[0m\n\n" "$PASS" "$FAIL"
  exit 0
fi
printf "  \033[31m%s passed, %s failed\033[0m\n\n" "$PASS" "$FAIL"
exit 1
