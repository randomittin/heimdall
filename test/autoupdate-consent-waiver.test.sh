#!/usr/bin/env bash
# autoupdate-consent-waiver — the UPDATER and the INSTALLER must agree about who has
# to be asked.
#
# THE DEFECT THIS GATES. `hmd modules add headroom` installs with no prompt: the module's
# own manifest carries `consent_waived`, and heimdall-modules' obtain_consent returns on
# that waiver before it ever reaches its terminal check. heimdall-autoupdate read only the
# CLASS contract, so `hmd --update` deferred the same module forever and printed
#
#     headroom  absent — class traffic-proxy + storage-codec requires your explicit consent
#                 install it with: hmd modules add headroom
#
# while handing over a command that installs without asking. Two binaries, two notions of
# "does this need consent", one module they disagreed about. Fixing the message alone
# would have left the behaviour wrong; fixing the behaviour alone would have left the
# message wrong. This suite pins BOTH, and W7 pins that they cannot drift apart again.
#
# WHAT IS UNDER TEST IS THE PRECEDENCE, NOT HEADROOM. Both binaries compute it the same
# way, and W2 runs it over synthetic modules this repo has never heard of:
#   1. the union of the declared CLASSES decides whether consent is required at all;
#   2. a required consent may be WAIVED by the module's OWN manifest;
#   3. a waiver with no `consent_text` is inert, because obtain_consent refuses it too.
#
# THE INVARIANTS, each of which cost something to establish:
#   W1  headroom's real manifest waives → the updater ACQUIRES instead of deferring, and
#       the sentence that contradicted `hmd modules add` is gone.
#   W2  the waiver is PER-MODULE. A synthetic traffic-proxy module WITHOUT the waiver, in
#       the SAME registry reading the SAME class contract, still DEFERS. A waiver that
#       leaked to the class is the outcome the owner explicitly rejected, so it is proven
#       against modules that exist only for this test rather than argued from headroom.
#   W3  a waived module still DISCLOSES. Waived means the question is not asked; it never
#       means the operator is not told.
#   W4  opt-out still wins. HEIMDALL_NO_MODULES=1 and $HEIMDALL_HOME/modules-optout both
#       suppress a WAIVED module, and neither nags.
#   W5  a failed acquisition leaves `hmd update` at exit 0 with the module ABSENT — never
#       a false "installed".
#   W6  `--yes` is never passed, on the waived path either.
#   W7  the updater's decision matches heimdall-modules' declared posture, module for
#       module, over the real registry.
#   F1-F4 FALSIFIERS. Four mutants, one per load-bearing claim, each restoring a real
#       defect: the class-only read (the original bug), a class-wide waiver, a dropped
#       opt-out guard, a dropped disclosure. Every one must produce the broken behaviour,
#       or the assertion above it is passing vacuously.
#
# NOTHING IS INSTALLED, FETCHED OR DOWNLOADED, AND THE CANONICAL STATE ROOT IS NEVER
# TOUCHED. Every run uses a throwaway HOME + temp registry + temp state root. Acquisition
# is either the decide-only seam (HEIMDALL_MODULE_RECONCILE_DRYRUN=1) or a local stub that
# records its argv and installs nothing. No network, no uv, no payload.
#
# Exit 0 = every proof holds.

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SELF_DIR/.." && pwd)"
BIN="$REPO/bin/heimdall-autoupdate"
MODS_BIN="$REPO/bin/heimdall-modules"

[ -x "$BIN" ] || { printf 'FATAL: %s missing/not executable\n' "$BIN" >&2; exit 2; }
[ -x "$MODS_BIN" ] || { printf 'FATAL: %s missing/not executable\n' "$MODS_BIN" >&2; exit 2; }
command -v jq >/dev/null 2>&1 || { printf 'FATAL: jq is required\n' >&2; exit 2; }

PASS=0
FAIL=0
ok()  { PASS=$((PASS+1)); printf "  \033[32mPASS\033[0m %s\n" "$1"; }
bad() { FAIL=$((FAIL+1)); printf "  \033[31mFAIL\033[0m %s\n" "$1"; }

# Everything transient lands here. Mutants must live in bin/ so their SELF_DIR and
# PLUGIN_DIR resolve exactly as the real script's do.
TMPROOT="$(mktemp -d -t hmd-waiver)"
MUTANT="$REPO/bin/.heimdall-autoupdate.waiver-falsifier.$$"
cleanup() { rm -rf "$TMPROOT" 2>/dev/null; rm -f "$MUTANT" 2>/dev/null; }
trap cleanup EXIT INT TERM

VER="2.0.0"
mk_home()  { d="$(mktemp -d "$TMPROOT/home.XXXXXX")"; printf '%s' "$d"; }
mk_state() { d="$(mktemp -d "$TMPROOT/state.XXXXXX")"; printf '%s' "$d"; }

# A registry carrying the REAL class contracts. Synthetic modules therefore read the same
# traffic-proxy contract headroom does — which is what makes "the waiver did not leak to
# the class" a claim about the shipped contract and not about a fixture.
mk_registry() {
  local reg="$1"
  mkdir -p "$reg/_classes"
  cp "$REPO"/modules/_classes/*.json "$reg/_classes/" 2>/dev/null
  printf '%s' "$reg"
}

# add_module <reg> <name> <class> <default_included> <waived:true|false> <consent_text>
# An empty consent_text with waived=true is the INERT waiver of precedence rule 3.
add_module() {
  local reg="$1" name="$2" class="$3" default_included="$4" waived="$5" text="$6"
  mkdir -p "$reg/$name"
  jq -n --arg n "$name" --arg c "$class" --argjson d "$default_included" \
        --argjson w "$waived" --arg t "$text" \
    '{name:$n, description:"synthetic test module", upstream:"https://example.invalid/x",
      license:"Apache-2.0", tier:"available", default_included:$d,
      pinned_version:{version:"1.0.0", artifact:"x-1.0.0.tar.gz",
        artifact_sha256:"0000000000000000000000000000000000000000000000000000000000000000"},
      permission_class:[$c],
      installs_via:{kind:"upstream", fetch:"uv tool install --python 3.13 \"x==1.0.0\""},
      wires:[], invariants:{}, consent_text:$t}
     + (if $w then {consent_waived:true,
                    consent_waived_reason:"synthetic per-module waiver, declared for this test only"}
        else {} end)' \
    > "$reg/$name/manifest.json"
}

# A stand-in for bin/heimdall-modules that RECORDS its argv and installs nothing. It also
# writes a marker to stdout, which is how W3 proves the quiet path CAPTURES `add`'s output
# (where the real disclosure lives) instead of discarding it.
mk_stub() {
  local path="$1" exit_code="$2" argv_log="$3"
  cat > "$path" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$argv_log"
printf 'STUB-STDOUT-MARKER %s\n' "\$*"
exit $exit_code
STUB
  chmod +x "$path"
}

# The decide-only run: logs its decision, spawns nothing, writes no receipt.
run_dry() {
  local bin="$1" home="$2" reg="$3" state="$4"; shift 4
  env -u HEIMDALL_NO_MODULES -u HMD_MODULES_BIN \
      HOME="$home" HEIMDALL_HOME="$home" \
      HMD_MODULES_REGISTRY="$reg" HMD_MODULES_STATE="$state" \
      HEIMDALL_LATEST_OVERRIDE="$VER" HEIMDALL_INSTALLED_OVERRIDE="$VER" \
      HEIMDALL_AUTOUPDATE_DRYRUN=1 HEIMDALL_MODULE_RECONCILE_DRYRUN=1 \
      "$@" "$bin" update 2>&1
}

# The real acquire path with the modules bin replaced by a stub: reconcile runs for real,
# `add` is invoked for real, and nothing is installed.
run_acquire() {
  local bin="$1" home="$2" reg="$3" state="$4" stub="$5"; shift 5
  env -u HEIMDALL_NO_MODULES \
      HOME="$home" HEIMDALL_HOME="$home" \
      HMD_MODULES_REGISTRY="$reg" HMD_MODULES_STATE="$state" HMD_MODULES_BIN="$stub" \
      HEIMDALL_LATEST_OVERRIDE="$VER" HEIMDALL_INSTALLED_OVERRIDE="$VER" \
      HEIMDALL_AUTOUPDATE_DRYRUN=1 \
      "$@" "$bin" update 2>&1
}

decision() { grep "reconcile: $2 " "$1/autoupdate.log" 2>/dev/null; }

printf "\n\033[1mautoupdate-consent-waiver — the updater and the installer agree on who is asked\033[0m\n\n"

# ── W1. The real registry: headroom acquires, and the contradiction is gone ──────
printf "\033[1mW1  the real registry — headroom's own waiver makes the update acquire it\033[0m\n"
H="$(mk_home)"; S="$(mk_state)"
OUT="$(run_dry "$BIN" "$H" "$REPO/modules" "$S")"
RC=$?
[ "$RC" -eq 0 ] && ok "update exits 0" || bad "update exited $RC"
decision "$H" headroom | grep -q 'would-acquire' \
  && ok "headroom is selected for ACQUISITION (it was deferred forever before)" \
  || bad "headroom was not selected: $(decision "$H" headroom)"
decision "$H" headroom | grep -q 'consent waived' \
  && ok "the log names the WAIVER as the reason — unprompted is not undisclosed" \
  || bad "the acquire decision does not record the waiver: $(decision "$H" headroom)"
printf '%s' "$OUT" | grep -q 'will never install it for you' \
  && bad "update still claims it will never install a module it now acquires" \
  || ok "the sentence that contradicted \`hmd modules add\` is gone"
[ ! -f "$S/headroom/receipt.json" ] \
  && ok "the decide-only seam wrote no receipt" \
  || bad "a receipt appeared under HEIMDALL_MODULE_RECONCILE_DRYRUN=1"

# ── W2. PER-MODULE: the waiver does not leak to the class ────────────────────────
printf "\n\033[1mW2  the waiver is PER-MODULE — one class contract, four different verdicts\033[0m\n"
H="$(mk_home)"; S="$(mk_state)"; REG="$(mk_registry "$TMPROOT/reg-scope")"
add_module "$REG" proxywaived traffic-proxy true true  "synthetic proxy disclosure"
add_module "$REG" proxyplain  traffic-proxy true false "synthetic proxy disclosure"
add_module "$REG" proxyblank  traffic-proxy true true  ""
add_module "$REG" codecmod    storage-codec true false "synthetic codec disclosure"
OUT="$(run_dry "$BIN" "$H" "$REG" "$S")"
decision "$H" proxywaived | grep -q 'would-acquire' \
  && ok "a WAIVED traffic-proxy module is acquired" \
  || bad "the waived module was not acquired: $(decision "$H" proxywaived)"
decision "$H" proxyplain | grep -q 'defer-consent' \
  && ok "an UN-WAIVED module of the SAME class still DEFERS — the waiver did not leak" \
  || bad "an un-waived traffic-proxy module was acquired: $(decision "$H" proxyplain)"
decision "$H" proxyblank | grep -q 'defer-consent' \
  && ok "a waiver with a BLANK disclosure is INERT — obtain_consent refuses it too" \
  || bad "a waiver with nothing to disclose was honoured: $(decision "$H" proxyblank)"
decision "$H" codecmod | grep -q 'would-acquire' \
  && ok "a class that needs no consent still acquires with no waiver involved" \
  || bad "the no-consent control did not acquire: $(decision "$H" codecmod)"
[ "$(jq -r '.consent_required' "$REPO/modules/_classes/traffic-proxy.json")" = "true" ] \
  && ok "the shipped traffic-proxy contract STILL requires consent" \
  || bad "the class contract was flipped — every traffic-proxy module is now unguarded"
CLASS_WAIVERS=0
for cf in "$REPO"/modules/_classes/*.json; do
  jq -e 'has("consent_waived")' "$cf" >/dev/null 2>&1 && CLASS_WAIVERS=$((CLASS_WAIVERS+1))
done
[ "$CLASS_WAIVERS" -eq 0 ] \
  && ok "no class contract carries a waiver of its own (checked all $(ls "$REPO"/modules/_classes/*.json | wc -l | tr -d ' '))" \
  || bad "$CLASS_WAIVERS class contract(s) carry consent_waived — the waiver escaped the module"
printf '%s' "$OUT" | grep -q 'proxyplain' \
  && ok "the deferred module is still NAMED to the operator with its command" \
  || bad "the un-waived module was silently skipped: $OUT"

# ── W3. A waived module is TOLD, not asked ───────────────────────────────────────
printf "\n\033[1mW3  waived means the question is not asked — never that the operator is not told\033[0m\n"
H="$(mk_home)"; S="$(mk_state)"; REG="$(mk_registry "$TMPROOT/reg-disclose")"
add_module "$REG" proxywaived traffic-proxy true true "SYNTHETIC-DISCLOSURE-BODY what this module does"
ARGV="$TMPROOT/argv-disclose.log"; : > "$ARGV"
STUB="$TMPROOT/stub-ok"; mk_stub "$STUB" 0 "$ARGV"
OUT="$(run_acquire "$BIN" "$H" "$REG" "$S" "$STUB")"
RC=$?
[ "$RC" -eq 0 ] && ok "update exits 0 on the acquire path" || bad "update exited $RC"
printf '%s' "$OUT" | grep -q 'WAIVED in its own manifest' \
  && ok "the operator is told the consent was waived, and where" \
  || bad "the acquisition never says consent was waived: $OUT"
printf '%s' "$OUT" | grep -q 'SYNTHETIC-DISCLOSURE-BODY' \
  && ok "the module's own consent_text is printed — the disclosure itself, not a summary" \
  || bad "the disclosure text was never shown: $OUT"
printf '%s' "$OUT" | grep -q 'synthetic per-module waiver' \
  && ok "the REASON for the waiver is printed" \
  || bad "the waiver reason was not shown: $OUT"
printf '%s' "$OUT" | grep -q 'every other module of that class still requires your explicit consent' \
  && ok "the per-module SCOPE of the waiver is stated on screen" \
  || bad "the operator is not told the waiver covers this module alone: $OUT"
printf '%s' "$OUT" | grep -q 'hmd modules optout proxywaived' \
  && ok "the way to decline it is printed alongside" \
  || bad "no decline path was offered: $OUT"
D_LINE="$(printf '%s' "$OUT" | grep -n 'SYNTHETIC-DISCLOSURE-BODY' | head -1 | cut -d: -f1)"
A_LINE="$(printf '%s' "$OUT" | grep -n 'installed\.' | head -1 | cut -d: -f1)"
if [ -n "$D_LINE" ] && [ -n "$A_LINE" ] && [ "$D_LINE" -lt "$A_LINE" ]; then
  ok "the disclosure is printed BEFORE the add completes (disclosure=$D_LINE result=$A_LINE)"
else
  bad "the disclosure does not precede the acquisition result (disclosure=$D_LINE result=$A_LINE)"
fi
printf '%s' "$OUT" | grep -q '\[y/N\]' \
  && bad "the updater issued a prompt — consent belongs in heimdall-modules" \
  || ok "no [y/N] prompt was issued from an unattended path"
# The QUIET path is silent to the terminal by design, so the disclosure has to land
# somewhere the operator can still read it: `add`'s stdout is redirected into the log
# rather than discarded. The stub's marker stands in for the real consent_text.
H="$(mk_home)"; S="$(mk_state)"
ARGV2="$TMPROOT/argv-quiet.log"; : > "$ARGV2"
STUB2="$TMPROOT/stub-quiet"; mk_stub "$STUB2" 0 "$ARGV2"
env -u HEIMDALL_NO_MODULES HOME="$H" HEIMDALL_HOME="$H" \
    HMD_MODULES_REGISTRY="$REG" HMD_MODULES_STATE="$S" HMD_MODULES_BIN="$STUB2" \
    HEIMDALL_MODULE_ACQUIRE_SYNC=1 \
    HEIMDALL_LATEST_OVERRIDE="$VER" HEIMDALL_INSTALLED_OVERRIDE="$VER" \
    HEIMDALL_AUTOUPDATE_DRYRUN=1 "$BIN" check >/dev/null 2>&1
grep -q 'STUB-STDOUT-MARKER add proxywaived' "$H/autoupdate.log" 2>/dev/null \
  && ok "on the SILENT path the add's output is captured to the log, not discarded" \
  || bad "the background acquisition threw away the disclosure: $(cat "$H/autoupdate.log" 2>/dev/null)"

# ── W4. Opt-out still wins over a waiver ─────────────────────────────────────────
printf "\n\033[1mW4  opt-out beats a waiver — both signals, on a module that would otherwise acquire\033[0m\n"
# (a) the env switch
H="$(mk_home)"; S="$(mk_state)"; REG="$(mk_registry "$TMPROOT/reg-opt-env")"
add_module "$REG" proxywaived traffic-proxy true true "synthetic proxy disclosure"
OUT="$(env HOME="$H" HEIMDALL_HOME="$H" HMD_MODULES_REGISTRY="$REG" HMD_MODULES_STATE="$S" \
        HEIMDALL_LATEST_OVERRIDE="$VER" HEIMDALL_INSTALLED_OVERRIDE="$VER" \
        HEIMDALL_AUTOUPDATE_DRYRUN=1 HEIMDALL_MODULE_RECONCILE_DRYRUN=1 \
        HEIMDALL_NO_MODULES=1 "$BIN" update 2>&1)"
grep -q 'would-acquire' "$H/autoupdate.log" 2>/dev/null \
  && bad "HEIMDALL_NO_MODULES=1 was ignored for a waived module" \
  || ok "HEIMDALL_NO_MODULES=1 suppresses a WAIVED module"
printf '%s' "$OUT" | grep -q 'proxywaived' \
  && bad "an opted-out waived module was still advertised (a nag is a soft revert)" \
  || ok "the opted-out waived module is not even mentioned"
[ ! -f "$S/proxywaived/receipt.json" ] \
  && ok "no receipt under the env opt-out" \
  || bad "the env opt-out still produced an install"
# (b) the file signal
H="$(mk_home)"; S="$(mk_state)"; REG="$(mk_registry "$TMPROOT/reg-opt-file")"
add_module "$REG" proxywaived traffic-proxy true true "synthetic proxy disclosure"
printf '# operator opted out\nproxywaived\n' > "$H/modules-optout"
OUT="$(run_dry "$BIN" "$H" "$REG" "$S")"
grep -q 'would-acquire' "$H/autoupdate.log" 2>/dev/null \
  && bad "the modules-optout file was ignored for a waived module" \
  || ok "\$HEIMDALL_HOME/modules-optout suppresses a WAIVED module"
grep -q 'reconcile: proxywaived skip-optout' "$H/autoupdate.log" 2>/dev/null \
  && ok "the opt-out decision is recorded as skip-optout" \
  || bad "no skip-optout recorded: $(cat "$H/autoupdate.log" 2>/dev/null)"
printf '%s' "$OUT" | grep -q 'proxywaived' \
  && bad "the file-opted-out waived module was still advertised" \
  || ok "the file opt-out is silent too"

# ── W5. A failed acquisition is ABSENT, never a false "installed" ────────────────
printf "\n\033[1mW5  a failed acquisition leaves the update at exit 0 with the module ABSENT\033[0m\n"
H="$(mk_home)"; S="$(mk_state)"; REG="$(mk_registry "$TMPROOT/reg-failacq")"
add_module "$REG" proxywaived traffic-proxy true true "synthetic proxy disclosure"
ARGV="$TMPROOT/argv-fail.log"; : > "$ARGV"
STUB_BAD="$TMPROOT/stub-fail"; mk_stub "$STUB_BAD" 1 "$ARGV"
OUT="$(run_acquire "$BIN" "$H" "$REG" "$S" "$STUB_BAD")"
RC=$?
[ "$RC" -eq 0 ] && ok "update exits 0 though the waived acquisition failed outright" \
                || bad "a failed acquisition broke hmd's own update (exit $RC)"
[ ! -f "$S/proxywaived/receipt.json" ] \
  && ok "no receipt was written for the failed acquisition" \
  || bad "a receipt appeared despite the acquisition failing"
printf '%s' "$OUT" | grep -q 'could not be installed right now' \
  && ok "the failure is SAID, not swallowed" \
  || bad "the failed acquisition was silent: $OUT"
printf '%s' "$OUT" | grep -q '"proxywaived" installed\.' \
  && bad "a false \"installed\" was printed over a failed acquisition" \
  || ok "no \"installed.\" claim stands over the failure"
grep -q 'reconcile: proxywaived acquire-failed' "$H/autoupdate.log" 2>/dev/null \
  && ok "the failure is recorded with its reason" \
  || bad "no acquire-failed decision in the log: $(cat "$H/autoupdate.log" 2>/dev/null)"
ST="$(env -u HEIMDALL_NO_MODULES HOME="$H" HEIMDALL_HOME="$H" \
        HMD_MODULES_REGISTRY="$REG" HMD_MODULES_STATE="$S" \
        HEIMDALL_LATEST_OVERRIDE="$VER" HEIMDALL_INSTALLED_OVERRIDE="$VER" \
        HMD_PREFLIGHT_NO_NET=1 "$BIN" status 2>&1)"
printf '%s' "$ST" | grep -q 'proxywaived *absent' \
  && ok "status reports the module ABSENT afterwards" \
  || bad "status does not report the failed module as absent: $ST"

# ── W6. `--yes` is never passed, waived or not ───────────────────────────────────
printf "\n\033[1mW6  the updater never auto-consents, on the waived path either\033[0m\n"
grep -vE '^[[:space:]]*#' "$BIN" | grep -E 'MODULES_BIN|\$mods' | grep -q -- '--yes' \
  && bad "the updater passes --yes to heimdall-modules" \
  || ok "no --yes in any of the updater's calls to heimdall-modules"
grep -q 'add proxywaived' "$TMPROOT/argv-disclose.log" 2>/dev/null \
  && ok "the waived acquisition really did invoke \`heimdall-modules add <name>\`" \
  || bad "the waived acquisition never reached the modules bin: $(cat "$TMPROOT/argv-disclose.log" 2>/dev/null)"
grep -q -- '--yes' "$TMPROOT/argv-disclose.log" 2>/dev/null \
  && bad "--yes reached heimdall-modules on the waived path" \
  || ok "the waived invocation carries no --yes (the installer stays free to refuse)"

# ── W7. The two binaries agree, module for module ────────────────────────────────
printf "\n\033[1mW7  no drift — the updater's decision matches heimdall-modules' declared posture\033[0m\n"
H="$(mk_home)"; S="$(mk_state)"
run_dry "$BIN" "$H" "$REPO/modules" "$S" >/dev/null 2>&1
COMPARED=0; DISAGREE=0
while IFS= read -r n; do
  [ -n "$n" ] || continue
  mf="$REPO/modules/$n/manifest.json"
  [ -f "$mf" ] || continue
  # The UPDATER's decision, read off the log it just wrote.
  upd_defers=0
  decision "$H" "$n" | grep -q 'defer-consent' && upd_defers=1
  # The INSTALLER's posture, read from its own read-only JSON surface. `add` is never
  # invoked: this asks what heimdall-modules would DO, without doing it.
  waived="$(env HOME="$H" HEIMDALL_HOME="$H" HMD_MODULES_REGISTRY="$REPO/modules" \
              HMD_MODULES_STATE="$S" "$MODS_BIN" --json status "$n" 2>/dev/null </dev/null \
            | jq -r '.consent_waiver.waived // false' 2>/dev/null)"
  [ -n "$waived" ] || waived=false
  cls_requires=0
  while IFS= read -r cls; do
    [ -n "$cls" ] || continue
    cf="$REPO/modules/_classes/$cls.json"
    [ -f "$cf" ] || continue
    [ "$(jq -r '.consent_required // false' "$cf")" = "true" ] && cls_requires=1
  done <<< "$(jq -r '.permission_class | if type=="array" then .[] else . end' "$mf")"
  inst_asks=0
  [ "$cls_requires" -eq 1 ] && [ "$waived" != "true" ] && inst_asks=1
  COMPARED=$((COMPARED+1))
  if [ "$upd_defers" -ne "$inst_asks" ]; then
    DISAGREE=$((DISAGREE+1))
    bad "DRIFT on \"$n\": updater defers=$upd_defers, installer asks=$inst_asks"
  fi
done <<< "$(jq -r 'select(.default_included == true) | .name' "$REPO"/modules/*/manifest.json 2>/dev/null)"
[ "$COMPARED" -gt 0 ] \
  && ok "the comparison ran over $COMPARED real default module(s) — not vacuous" \
  || bad "no default module was compared; W7 proved nothing"
[ "$DISAGREE" -eq 0 ] \
  && ok "every default module gets the SAME answer from both binaries" \
  || bad "$DISAGREE module(s) disagree between the updater and the installer"

# ── FALSIFIERS ───────────────────────────────────────────────────────────────────
# Each mutant restores a defect that has actually existed or was explicitly rejected,
# and must produce the broken behaviour. A mutant that stays green means the assertion
# above it is not gripping the code.
printf "\n\033[1mF   FALSIFIERS — four mutants, four assertions proven able to go RED\033[0m\n"

# F1 — THE ORIGINAL BUG: module_needs_consent consults only the CLASS contract.
sed 's|module_consent_waived "$mf" && return 1|:|' "$BIN" > "$MUTANT"; chmod +x "$MUTANT"
if ! grep -q '^  :$' "$MUTANT"; then
  bad "F1 could not find the waiver precedence line — the test has lost its grip on the code"
else
  H="$(mk_home)"; S="$(mk_state)"
  run_dry "$MUTANT" "$H" "$REPO/modules" "$S" >/dev/null 2>&1
  decision "$H" headroom | grep -q 'defer-consent' \
    && ok "F1 class-only read → headroom DEFERS again → W1 can go RED" \
    || bad "F1 mutant still acquired headroom — W1 may be passing vacuously"
fi
rm -f "$MUTANT"

# F2 — THE REJECTED DESIGN: the waiver read as if it were class-wide.
sed "s|'.consent_waived // false'|'true'|" "$BIN" > "$MUTANT"; chmod +x "$MUTANT"
if ! grep -q "jq -r 'true'" "$MUTANT"; then
  bad "F2 could not find the manifest waiver read — the test has lost its grip on the code"
else
  H="$(mk_home)"; S="$(mk_state)"; REG="$(mk_registry "$TMPROOT/reg-f2")"
  add_module "$REG" proxyplain traffic-proxy true false "synthetic proxy disclosure"
  run_dry "$MUTANT" "$H" "$REG" "$S" >/dev/null 2>&1
  decision "$H" proxyplain | grep -q 'would-acquire' \
    && ok "F2 class-wide waiver → an UN-WAIVED proxy is acquired → W2 can go RED" \
    || bad "F2 mutant still deferred the un-waived module — W2 may be passing vacuously"
fi
rm -f "$MUTANT"

# F3 — the opt-out guard dropped, on a module the waiver would otherwise acquire.
sed 's/if module_opted_out .*; then/if false; then/' "$BIN" > "$MUTANT"; chmod +x "$MUTANT"
if ! grep -q 'if false; then' "$MUTANT"; then
  bad "F3 could not find the opt-out guard — the test has lost its grip on the code"
else
  H="$(mk_home)"; S="$(mk_state)"; REG="$(mk_registry "$TMPROOT/reg-f3")"
  add_module "$REG" proxywaived traffic-proxy true true "synthetic proxy disclosure"
  printf 'proxywaived\n' > "$H/modules-optout"
  run_dry "$MUTANT" "$H" "$REG" "$S" >/dev/null 2>&1
  decision "$H" proxywaived | grep -q 'would-acquire' \
    && ok "F3 no opt-out guard → the opted-out waived module IS selected → W4 can go RED" \
    || bad "F3 mutant still honoured the opt-out — W4 may be passing vacuously"
fi
rm -f "$MUTANT"

# F4 — the disclosure dropped from the acquire path.
sed 's|print_waiver_disclosure "$n" "$mf"|:|' "$BIN" > "$MUTANT"; chmod +x "$MUTANT"
if ! grep -q 'print_waiver_disclosure() {' "$MUTANT" || grep -q 'print_waiver_disclosure "\$n"' "$MUTANT"; then
  bad "F4 could not remove the disclosure call — the test has lost its grip on the code"
else
  H="$(mk_home)"; S="$(mk_state)"; REG="$(mk_registry "$TMPROOT/reg-f4")"
  add_module "$REG" proxywaived traffic-proxy true true "SYNTHETIC-DISCLOSURE-BODY what this module does"
  ARGV="$TMPROOT/argv-f4.log"; : > "$ARGV"
  STUB="$TMPROOT/stub-f4"; mk_stub "$STUB" 0 "$ARGV"
  OUT="$(run_acquire "$MUTANT" "$H" "$REG" "$S" "$STUB")"
  printf '%s' "$OUT" | grep -q 'SYNTHETIC-DISCLOSURE-BODY' \
    && bad "F4 mutant still disclosed — W3 may be passing vacuously" \
    || ok "F4 no disclosure call → the waived module is acquired UNTOLD → W3 can go RED"
fi
rm -f "$MUTANT"

# ── Summary ──────────────────────────────────────────────────────────────────────
printf "\n"
if [ "$FAIL" -eq 0 ]; then
  printf "  \033[32m%s passed, %s failed\033[0m\n\n" "$PASS" "$FAIL"
  exit 0
fi
printf "  \033[31m%s passed, %s failed\033[0m\n\n" "$PASS" "$FAIL"
exit 1
