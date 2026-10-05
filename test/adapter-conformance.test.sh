#!/usr/bin/env bash
# test/adapter-conformance.test.sh — the adapter conformance suite (RP9), and the proof that the
# suite itself can go red.
#
# The contract is docs/ADAPTERS.md; its executable form is `python3 -m adapters.conformance`. This
# file tests THAT, and is deliberately independent of any one adapter: the golden loop is driven by
# `--list`, so claude/codex/gemini adapters are picked up the day they land, with no edit here.
#
# WHAT THIS PROVES
#   [A] GOLDEN       every adapter present under adapters/ exits 0 under its own conformance run,
#                    and the --json report has the documented shape.
#   [B] MUTANTS      the suite is falsifiable. Each deliberately broken copy of the gitdiff adapter
#                    (test/fixtures/adapter-mutants/mutant.py, one broken contract rule per copy) is
#                    REJECTED (exit 1) for the rule it breaks: a green suite that cannot go red proves nothing.
#   [C] INDEPENDENCE the suite core imports no adapter implementation and no adapter helper: its
#                    expectations come from the contract, not from any adapter's behaviour.
#   [D] DOCS         every rule id the suite enforces is documented in docs/ADAPTERS.md, and the other way round.
#   [E] CLI          exit codes: 2 for an unknown adapter / missing driver / unreadable adapter file.
#
# Hermetic: every repo lives in a throwaway dir created by the suite; no network.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
MUTANT_PY="$REPO/test/fixtures/adapter-mutants/mutant.py"
DOC="$REPO/docs/ADAPTERS.md"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  \033[32mPASS\033[0m %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  \033[31mFAIL\033[0m %s\n' "$1"; }

for tool in git python3 jq; do
  command -v "$tool" >/dev/null 2>&1 || { echo "$tool required" >&2; exit 2; }
done

TMP="$(mktemp -d "${TMPDIR:-/tmp}/adapter-conformance-test-XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
export TMPDIR="$TMP/suite-tmp"; mkdir -p "$TMPDIR"
cd "$REPO" || exit 2

conf() { COUT="$TMP/conf.out"; CERR="$TMP/conf.err"; python3 -m adapters.conformance "$@" >"$COUT" 2>"$CERR" </dev/null; CRC=$?; }

# ══════════════════════════════════════════════════════════════════════════════
# [A] golden: every adapter present passes
# ══════════════════════════════════════════════════════════════════════════════
echo "[A] golden: every adapter under adapters/ conforms"

conf --list
[ "$CRC" -eq 0 ] && ADAPTERS="$(cat "$COUT")" || ADAPTERS=""
[ -n "$ADAPTERS" ] && grep -qx gitdiff "$COUT" && ok "--list names the adapters present, gitdiff among them" || bad "--list wrong (rc=$CRC): $(head -c 200 "$COUT") $(head -c 200 "$CERR")"
! grep -Eqx '_?common|conformance' "$COUT" && ok "--list does not mistake the helper modules for adapters" || bad "--list names a helper module"

for name in $ADAPTERS; do
  conf --adapter "$name"
  [ "$CRC" -eq 0 ] && grep -q '^RESULT: [0-9]* passed, 0 failed' "$COUT" && ok "adapter '$name': python3 -m adapters.conformance --adapter $name exits 0" \
    || bad "adapter '$name' does not conform (rc=$CRC): $(grep -E '^(FAIL|RESULT)' "$COUT" | head -5 | tr '\n' '|') $(head -c 200 "$CERR")"
done

conf --adapter gitdiff --json
jq -e '.schema=="runhmd.adapter-conformance/1" and .adapter=="gitdiff" and .contract=="runhmd.adapter/1" and .ok==true and .failed==0 and (.checks|length)>=20
       and ([.checks[]|select(.status=="pass")]|length)==.passed and all(.checks[]; has("id") and has("title") and has("status") and has("detail"))' "$COUT" >/dev/null 2>&1 \
  && ok "--json: runhmd.adapter-conformance/1 with every check (id, title, status, detail) and consistent counts" || bad "--json shape wrong (rc=$CRC): $(head -c 300 "$COUT")"
jq -e '[.checks[]|select(.status=="skip")]|length==0' "$COUT" >/dev/null 2>&1 \
  && ok "a conforming adapter skips nothing: every rule actually ran" || bad "golden run skipped checks: $(jq -c '[.checks[]|select(.status=="skip")|.id]' "$COUT" 2>/dev/null)"

# ══════════════════════════════════════════════════════════════════════════════
# [B] mutants: each broken adapter is rejected for the rule it breaks
# ══════════════════════════════════════════════════════════════════════════════
echo "[B] falsifiability: one broken contract rule per mutant"

# <mutant id> <the exact set of rules the suite must fail, comma separated>
MUTANTS='M1 M1
T1 T1
T2 T2
T3 T3
T3x T3
T4 T4
T5 T5
E1 E1
E2 E2
E3 E3
E4 E4
E5 E5
E6 E6
K1 K1
K2 K2
K3 K3,K6
K4 K4
K5 K5
K6 K6
K7 K7
K8 K8'

NMUT=0
while read -r mutant want; do
  [ -n "$mutant" ] || continue
  NMUT=$((NMUT+1))
  HMD_MUTANT="$mutant" conf --adapter-file "$MUTANT_PY" --driver gitdiff --json
  got="$(jq -r '[.checks[]|select(.status=="fail")|.id]|sort|join(",")' "$COUT" 2>/dev/null)"
  if [ "$CRC" -eq 1 ] && [ "$got" = "$want" ]; then ok "mutant $mutant is rejected: exit 1, failing rules exactly {$want}"
  else bad "mutant $mutant: want exit 1 and failing rules {$want}, got rc=$CRC rules {$got} $(head -c 200 "$CERR")"; fi
done <<<"$MUTANTS"
[ "$NMUT" -ge 21 ] && ok "$NMUT mutants ran, covering every rule the suite enforces" || bad "only $NMUT mutants ran"

# every rule the suite enforces has at least one mutant aimed at it
conf --rules
RULES="$(cut -f1 "$COUT")"
[ "$CRC" -eq 0 ] && [ "$(printf '%s\n' "$RULES" | grep -c .)" -ge 20 ] && ok "--rules lists the contract's rules ($(printf '%s\n' "$RULES" | grep -c .) of them)" || bad "--rules wrong (rc=$CRC): $(head -c 200 "$COUT")"
missing=""
for rule in $RULES; do
  printf '%s\n' "$MUTANTS" | tr ' ,' '\n\n' | grep -qx "$rule" || missing="$missing $rule"
done
[ -z "$missing" ] && ok "every rule id has a mutant that must trip it" || bad "rules with no mutant:$missing"

# ══════════════════════════════════════════════════════════════════════════════
# [C] independence
# ══════════════════════════════════════════════════════════════════════════════
echo "[C] independence: the suite core imports no adapter"

CORE="$REPO/adapters/conformance/__main__.py $REPO/adapters/conformance/rules.py $REPO/adapters/conformance/fixture.py"
# shellcheck disable=SC2086
! grep -En '^[[:space:]]*(from|import)[[:space:]]+adapters\.(_common|gitdiff|claude|codex|gemini)\b|from[[:space:]]+adapters[[:space:]]+import[[:space:]]+(_common|gitdiff|claude|codex|gemini)\b' $CORE >/dev/null 2>&1 \
  && ok "no static import of an adapter or of adapters._common in the suite core" || bad "the suite core imports an adapter: $(grep -En 'adapters\.(_common|gitdiff)' $CORE | head -3)"
# shellcheck disable=SC2086
! grep -En 'adapters\._common|adapters/_common' $CORE >/dev/null 2>&1 \
  && ok "the suite core never reaches adapters._common (it keeps its own git helpers)" || bad "the suite core reaches adapters._common"
check_drivers=""
for driver_file in "$REPO"/adapters/conformance/drivers/*.py; do
  driver_name="$(basename "$driver_file" .py)"
  case "$driver_name" in __*) ;; *) check_drivers="$check_drivers$driver_name " ;; esac
done
[ -n "$check_drivers" ] && ok "adapter-specific glue lives only in adapters/conformance/drivers/ (${check_drivers% })" || bad "no drivers directory"
! grep -En '^[[:space:]]*(from|import)[[:space:]]+adapters\.(_common|gitdiff)|from[[:space:]]+adapters[[:space:]]+import' "$REPO"/adapters/conformance/drivers/*.py >/dev/null 2>&1 \
  && ok "drivers import no adapter either: they translate a scenario into a task, nothing more" || bad "a driver imports an adapter"
# a conforming run must not depend on the adapter's own fixtures: the suite builds its repo itself
grep -q '"init"' "$REPO/adapters/conformance/fixture.py" 2>/dev/null && ok "the suite builds its own fixture repository" || bad "fixture.py does not build a repo"

# ══════════════════════════════════════════════════════════════════════════════
# [D] docs <-> suite
# ══════════════════════════════════════════════════════════════════════════════
echo "[D] docs/ADAPTERS.md documents exactly the rules the suite enforces"

[ -f "$DOC" ] && ok "docs/ADAPTERS.md exists" || bad "docs/ADAPTERS.md missing"
undoc=""
for rule in $RULES; do
  grep -Eq "^\| *$rule *\|" "$DOC" 2>/dev/null || undoc="$undoc $rule"
done
[ -z "$undoc" ] && ok "every enforced rule id has a row in the ADAPTERS.md rules table" || bad "rules enforced but not documented:$undoc"
extra="$(grep -Eo '^\| *[MTEK][0-9]+ *\|' "$DOC" 2>/dev/null | tr -d '| ' | sort -u | while read -r id; do printf '%s\n' "$RULES" | grep -qx "$id" || printf '%s ' "$id"; done)"
[ -z "$extra" ] && ok "no documented rule id is missing from the suite" || bad "documented but not enforced: $extra"
for form in 'start(task' 'events(run_id' 'claim(run_id' 'done|failed|gave_up' 'tool|message|test|status' 'python3 -m adapters.conformance --adapter'; do
  grep -qF -- "$form" "$DOC" 2>/dev/null || { bad "ADAPTERS.md does not state the contract form: $form"; continue; }
done
grep -qF 'start(task' "$DOC" && grep -qF 'tool|message|test|status' "$DOC" && ok "ADAPTERS.md states the RP9 contract signatures and enums verbatim" || bad "contract signatures missing"

# ══════════════════════════════════════════════════════════════════════════════
# [E] CLI behaviour
# ══════════════════════════════════════════════════════════════════════════════
echo "[E] CLI exit codes"

conf --adapter no_such_adapter
[ "$CRC" -eq 2 ] && grep -qi 'no_such_adapter' "$CERR" && ok "an unknown adapter is exit 2 (usage), never a pass" || bad "unknown adapter rc=$CRC"
conf --adapter-file "$TMP/missing.py" --driver gitdiff
[ "$CRC" -eq 2 ] && ok "an unreadable --adapter-file is exit 2" || bad "missing adapter file rc=$CRC"
cp "$REPO/adapters/gitdiff.py" "$TMP/needs_driver.py"
conf --adapter-file "$TMP/needs_driver.py" --driver no_such_driver
[ "$CRC" -eq 2 ] && grep -q 'drivers' "$CERR" && ok "an adapter with no driver is exit 2 and the error points at adapters/conformance/drivers/" || bad "missing driver rc=$CRC: $(head -c 200 "$CERR")"
conf
[ "$CRC" -eq 2 ] && ok "no --adapter is exit 2" || bad "no adapter rc=$CRC"
printf 'CONTRACT = "runhmd.adapter/1"\nAGENT = "none"\nraise RuntimeError("boom at import")\n' >"$TMP/explodes.py"
conf --adapter-file "$TMP/explodes.py" --driver gitdiff --json
[ "$CRC" -eq 1 ] && jq -e '[.checks[]|select(.status=="fail")|.id]==["M1"]' "$COUT" >/dev/null 2>&1 \
  && ok "an adapter that raises on import is nonconformant (M1, exit 1), not a crash and not a usage error" || bad "import failure wrong (rc=$CRC): $(head -c 200 "$COUT") $(head -c 200 "$CERR")"

echo
echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
