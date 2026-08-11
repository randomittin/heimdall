#!/usr/bin/env bash
#
# tier-declaration.test.sh — acceptance for declared tiers, inheritance logging,
# and the spec 3.4 conformance check.
#
# WHY: a routing table nobody declares against is decoration. Spec 2.1 requires
# every spawn template to carry an explicit tier, and a spawn WITHOUT one to
# inherit the role default AND LOG THAT IT DID — silent inheritance is how drift
# hides. Spec 2.3 allows an agent to request a HIGHER tier with one line of
# stated reason, recorded; an escalation with no reason is drift, not escalation.
#
# Guarantees proved:
#   1. `hmd tier` is reachable — bin/heimdall dispatches it and advertises it.
#   2. Conformance (spec 3.4) passes on this repo: every agents/*.md declares a
#      tier, and that tier agrees with the model the template actually runs.
#   3. Conformance FAILS CLOSED on an empty template set. A gate that passes
#      when it found nothing to check is worse than no gate.
#   4. Conformance fails a missing tier, a tier/model disagreement, and an
#      above-class tier with no stated reason.
#   5. Conformance PASSES an above-class tier WITH a stated reason — a reasoned
#      escalation is not drift.
#   6. The binding safety rule is enforced as code: a security-sensitive class
#      cannot be declared BELOW its table tier, reason or no reason.
#   7. A declaration with no requested tier inherits the role default and writes
#      a record saying so.
#   8. A reasoned escalation records the reason; an unreasoned one is recorded
#      as drift and exits nonzero.
#   9. Declaration composes with the non-ZDR gate: escalating to fable in a repo
#      that has not opted in is refused.
#
# Usage:  test/tier-declaration.test.sh   (exit 0 = all guarantees hold)
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SELF_DIR/.." && pwd)"
TIER="$REPO/bin/heimdall-tier"

PASS=0; FAIL=0
ok()  { printf '  \033[32mPASS\033[0m %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAIL=$((FAIL+1)); }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/tier-decl.XXXXXX")"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

echo "tier-declaration harness  repo=$REPO"
echo "--------------------------------------------------------------------"

# ── 1. REACHABILITY ──
[ -x "$TIER" ] \
  && ok "bin/heimdall-tier is executable" \
  || bad "bin/heimdall-tier missing or not executable"
grep -q '^  tier)' "$REPO/bin/heimdall" \
  && ok "bin/heimdall dispatches a 'tier' subcommand" \
  || bad "bin/heimdall has no 'tier)' case arm — the command is unreachable"
# Either spelling counts: `hmd` and `heimdall` are the same binary, and the help
# block lists every other subcommand as `heimdall <cmd>` (see the weekly-log,
# invite, join, presence lines). Demanding the `hmd` spelling here would have
# forced this one entry to break the convention of the surface it lives on,
# which makes the listing less discoverable, not more. The requirement that
# matters is that the help surface names the command at all.
grep -qE '(hmd|heimdall) tier' "$REPO/bin/heimdall" \
  && ok "bin/heimdall advertises the tier command in its help surface" \
  || bad "bin/heimdall never mentions 'tier' — undiscoverable"

# ── 2. CONFORMANCE PASSES ON THIS REPO ──
"$TIER" check --repo "$REPO" > "$TMP/check.out" 2>"$TMP/check.err"; rc=$?
[ "$rc" -eq 0 ] \
  && ok "tier check passes on this repo (every agents/*.md declares a tier)" \
  || bad "tier check FAILED on this repo (rc=$rc): $(cat "$TMP/check.err" "$TMP/check.out")"

# ── 3-6. CONFORMANCE FIXTURES ──
mk_agent() {
  # mk_agent <fixture-dir> <name> <model> [tier] [reason]
  local dir="$1/agents" name="$2" model="$3" tier="${4:-}" reason="${5:-}"
  mkdir -p "$dir"
  {
    printf '%s\n' '---'
    printf 'name: %s\n' "$name"
    printf 'description: fixture template for the tier conformance gate\n'
    # model may be empty on purpose: a `tier: inherit` template pins no model.
    [ -n "$model" ]  && printf 'model: %s\n' "$model"
    [ -n "$tier" ]   && printf 'tier: %s\n' "$tier"
    [ -n "$reason" ] && printf 'tier_reason: %s\n' "$reason"
    printf '%s\n' '---'
    printf '\n%s\n' 'Fixture body.'
  } > "$dir/$name.md"
}

# The fixture uses REAL agent names so the shipped table maps them to a class.
# coder -> class 'coder' -> tier sonnet. reviewer -> gate_adjudication -> opus.
run_check() { "$TIER" check --repo "$1" >"$TMP/o" 2>"$TMP/e"; }

FIX_OK="$TMP/fix-ok"; mk_agent "$FIX_OK" coder sonnet sonnet
run_check "$FIX_OK"; rc=$?
[ "$rc" -eq 0 ] \
  && ok "conformance: declared tier matching the class passes" \
  || bad "conformance rejected a conforming template (rc=$rc): $(cat "$TMP/e")"

FIX_EMPTY="$TMP/fix-empty"; mkdir -p "$FIX_EMPTY/agents"
run_check "$FIX_EMPTY"; rc=$?
if [ "$rc" -ne 0 ] && grep -qi 'no spawn templates' "$TMP/e" "$TMP/o"; then
  ok "conformance FAILS CLOSED on zero templates (empty scan never passes)"
else
  bad "conformance passed an empty template set (rc=$rc) — vacuous gate"
fi

FIX_NOTIER="$TMP/fix-notier"; mk_agent "$FIX_NOTIER" coder sonnet
run_check "$FIX_NOTIER"; rc=$?
[ "$rc" -ne 0 ] \
  && ok "conformance fails a template with no tier: field" \
  || bad "conformance passed a template that declares no tier"

FIX_MISMATCH="$TMP/fix-mismatch"; mk_agent "$FIX_MISMATCH" coder opus sonnet
run_check "$FIX_MISMATCH"; rc=$?
if [ "$rc" -ne 0 ] && grep -qi 'model' "$TMP/e" "$TMP/o"; then
  ok "conformance fails when tier: disagrees with model: (declaration is a lie)"
else
  bad "conformance passed tier=sonnet model=opus (rc=$rc) — declaration unenforced"
fi

FIX_UNREASONED="$TMP/fix-unreasoned"; mk_agent "$FIX_UNREASONED" coder opus opus
run_check "$FIX_UNREASONED"; rc=$?
[ "$rc" -ne 0 ] \
  && ok "conformance fails an above-class tier with NO stated reason (= drift)" \
  || bad "conformance passed an unreasoned escalation — 2.3 not enforced"

FIX_REASONED="$TMP/fix-reasoned"
mk_agent "$FIX_REASONED" coder opus opus "writes and reviews code; repo doctrine keeps that on opus"
run_check "$FIX_REASONED"; rc=$?
[ "$rc" -eq 0 ] \
  && ok "conformance PASSES an above-class tier WITH a stated reason (not drift)" \
  || bad "conformance flagged a reasoned escalation as a failure (rc=$rc): $(cat "$TMP/e")"

FIX_DOWNGRADE="$TMP/fix-downgrade"
mk_agent "$FIX_DOWNGRADE" reviewer haiku haiku "cheaper, review is mostly mechanical"
run_check "$FIX_DOWNGRADE"; rc=$?
if [ "$rc" -ne 0 ] && grep -qi 'security' "$TMP/e" "$TMP/o"; then
  ok "conformance REFUSES a security-sensitive class below its tier, reason or not"
else
  bad "conformance allowed gate_adjudication downgraded to haiku (rc=$rc) — binding rule unenforced"
fi

# ── 6b. tier: inherit — DELIBERATE DEFERENCE TO THE OPERATOR'S DEFAULT ──
# The main orchestrator pins no model: it runs on whatever Claude Code default
# the human chose. That must be DECLARABLE, or the only way to ship it is a
# blank tier: — which is exactly the invisible drift this gate exists to catch.
# The invariant is unchanged: the declaration is still cross-checked against
# what executes — POSITIVELY, via the literal `model: inherit` that Claude Code's
# own agent-file parser honours, so deference is stated rather than inferred from
# a missing field.

FIX_INH_MODEL="$TMP/fix-inherit-model"
mk_agent "$FIX_INH_MODEL" heimdall opus inherit "deferring to the operator default"
run_check "$FIX_INH_MODEL"; rc=$?
if [ "$rc" -ne 0 ] && grep -qi 'both' "$TMP/e" "$TMP/o"; then
  ok "conformance fails 'inherit' that ALSO pins a model (two claims at once)"
else
  bad "conformance passed tier=inherit with model=opus (rc=$rc) — a template claiming both"
fi

# The one model value that is NOT a second claim: the literal `inherit`, which
# says the same thing the tier says. Rejecting it would force deference to be
# expressed only as silence — and silence is indistinguishable from a forgotten
# field, which is strictly weaker evidence than a stated one.
FIX_INH_NATIVE="$TMP/fix-inherit-native"
mk_agent "$FIX_INH_NATIVE" heimdall inherit inherit "unpinned by owner directive; operator default owned"
run_check "$FIX_INH_NATIVE"; rc=$?
if [ "$rc" -eq 0 ]; then
  ok "conformance ACCEPTS tier: inherit + model: inherit (Claude Code honours it natively)"
else
  bad "conformance rejected model: inherit (rc=$rc) — the one model value that agrees with the tier: $(cat "$TMP/e")"
fi
if grep -q 'model: inherit' "$TMP/o"; then
  ok "render distinguishes a STATED deference ('model: inherit') from an omitted field"
else
  bad "render does not show how deference was expressed — omission and statement look identical"
fi

FIX_INH_NOREASON="$TMP/fix-inherit-noreason"
mk_agent "$FIX_INH_NOREASON" heimdall "" inherit
run_check "$FIX_INH_NOREASON"; rc=$?
if [ "$rc" -ne 0 ] && grep -qi 'security-sensitive' "$TMP/e" "$TMP/o"; then
  ok "conformance fails 'inherit' on a security-sensitive class with NO stated reason"
else
  bad "conformance passed unreasoned inherit on class orchestrator (rc=$rc) — the operator default could sit below opus and nobody would have owned that"
fi

FIX_INH_OK="$TMP/fix-inherit-ok"
mk_agent "$FIX_INH_OK" heimdall "" inherit "unpinned by owner directive; the risk that the operator default sits below opus is seen and accepted"
run_check "$FIX_INH_OK"; rc=$?
[ "$rc" -eq 0 ] \
  && ok "conformance PASSES 'inherit' on a security-sensitive class WITH a stated reason" \
  || bad "conformance rejected a reasoned inherit (rc=$rc): $(cat "$TMP/e")"

FIX_INH_PLAIN="$TMP/fix-inherit-plain"
mk_agent "$FIX_INH_PLAIN" coder "" inherit
run_check "$FIX_INH_PLAIN"; rc=$?
[ "$rc" -eq 0 ] \
  && ok "conformance PASSES 'inherit' with no reason on a NON-sensitive class" \
  || bad "conformance demanded a reason for inherit on class coder (rc=$rc): $(cat "$TMP/e")"

# inherit is rankless: it must never be read as an escalation or a downgrade.
FIX_INH_OK2="$TMP/fix-inherit-rankless"
mk_agent "$FIX_INH_OK2" reviewer "" inherit "operator default, accepted"
run_check "$FIX_INH_OK2"; rc=$?
if [ "$rc" -eq 0 ] && ! grep -qi 'below its\|departs from' "$TMP/e" "$TMP/o"; then
  ok "inherit takes no part in the rank arithmetic (not reported as a downgrade)"
else
  bad "inherit was rank-compared on a security-sensitive class (rc=$rc): $(cat "$TMP/e")"
fi

# and the SHIPPED repo renders the orchestrator as inherit, not as a tier
"$TIER" check --repo "$REPO" >"$TMP/real.out" 2>"$TMP/real.err"; rc=$?
if [ "$rc" -eq 0 ] && grep -qE '~ +heimdall +inherit' "$TMP/real.out"; then
  ok "shipped agents/heimdall.md renders as '~ heimdall inherit' (unpinned, and visibly so)"
else
  bad "shipped heimdall.md is not rendered as inherit (rc=$rc): $(cat "$TMP/real.err")"
fi

# ── 7-9. DECLARATION RECORDS ──
DECL_REPO="$TMP/decl"; mkdir -p "$DECL_REPO/.planning"
LOG="$DECL_REPO/.planning/tier-declarations.jsonl"

out="$("$TIER" declare --repo "$DECL_REPO" --class coder --agent fixture-a 2>"$TMP/e1")"; rc=$?
[ "$rc" -eq 0 ] && [ "$out" = "sonnet" ] \
  && ok "declare with no requested tier inherits the role default -> '$out'" \
  || bad "inherited declaration -> rc=$rc out='$out', expected 'sonnet'"

"$TIER" declare --repo "$DECL_REPO" --class coder --tier opus --agent fixture-b \
  --reason "cross-file refactor needs whole-repo reasoning" >/dev/null 2>"$TMP/e2"; rc2=$?
[ "$rc2" -eq 0 ] \
  && ok "declare escalates with a stated reason (exit 0)" \
  || bad "reasoned escalation exited $rc2: $(cat "$TMP/e2")"

"$TIER" declare --repo "$DECL_REPO" --class coder --tier opus --agent fixture-c \
  >/dev/null 2>"$TMP/e3"; rc3=$?
[ "$rc3" -ne 0 ] \
  && ok "declare with a higher tier and NO reason exits nonzero (rc=$rc3)" \
  || bad "unreasoned escalation exited 0 — silent drift"
grep -qi 'reason' "$TMP/e3" \
  && ok "unreasoned escalation says on stderr that a reason was required" \
  || bad "unreasoned escalation gave no diagnostic: $(cat "$TMP/e3")"

"$TIER" declare --repo "$DECL_REPO" --class security_critical --tier haiku \
  --agent fixture-d --reason "save money" >/dev/null 2>"$TMP/e4"; rc4=$?
if [ "$rc4" -ne 0 ] && grep -qi 'security' "$TMP/e4"; then
  ok "declare REFUSES downgrading a security-critical class (rc=$rc4)"
else
  bad "security-critical downgrade accepted (rc=$rc4) — binding rule unenforced"
fi

env -u HEIMDALL_REPO_POLICY "$TIER" declare --repo "$DECL_REPO" --class forensics \
  --tier fable --agent fixture-e --reason "needs the largest model available" \
  >/dev/null 2>"$TMP/e5"; rc5=$?
if [ "$rc5" -ne 0 ] && grep -qi 'zdr' "$TMP/e5"; then
  ok "declare composes with the non-ZDR gate — fable refused in this repo"
else
  bad "fable declaration accepted with no repo opt-in (rc=$rc5): $(cat "$TMP/e5")"
fi

# One python3 pass over the whole log — interpreter startup is the slow part.
python3 - "$LOG" <<'PY' > "$TMP/logreport" 2>"$TMP/logerr"
import json, sys
records = []
try:
    with open(sys.argv[1]) as handle:
        for line in handle:
            line = line.strip()
            if line:
                records.append(json.loads(line))
except (OSError, ValueError) as exc:
    print("bad|declaration log unreadable: %s" % exc)
    raise SystemExit(0)

out = []


def emit(good, message):
    out.append(("ok" if good else "bad") + "|" + message)


by_agent = {r.get("agent"): r for r in records}
emit(bool(records), "declaration log has records (%d)" % len(records))

a = by_agent.get("fixture-a", {})
emit(a.get("inherited") is True and a.get("declared_tier") == "sonnet"
     and a.get("requested_tier") in (None, ""),
     "inherited spawn LOGGED as inherited: %r" % ({k: a.get(k) for k in
        ("inherited", "declared_tier", "requested_tier")},))
emit(a.get("escalated") is False and a.get("drift") is False,
     "inherited spawn is neither escalation nor drift")

b = by_agent.get("fixture-b", {})
emit(b.get("escalated") is True and b.get("drift") is False
     and bool(b.get("reason", "").strip()),
     "reasoned escalation recorded with its reason and NOT flagged as drift")
emit(b.get("declared_tier") == "opus" and b.get("default_tier") == "sonnet",
     "reasoned escalation records both the declared tier and the default it left")

c = by_agent.get("fixture-c", {})
emit(c.get("drift") is True and c.get("escalated") is False,
     "unreasoned escalation recorded as DRIFT, not escalation")
emit(not (c.get("reason") or "").strip(),
     "unreasoned escalation records an empty reason")

emit("fixture-d" not in by_agent or by_agent["fixture-d"].get("allowed") is False,
     "refused security-critical downgrade is not recorded as an allowed declaration")
emit("fixture-e" not in by_agent or by_agent["fixture-e"].get("allowed") is False,
     "refused fable declaration is not recorded as an allowed declaration")

# A record must carry enough to audit it later without re-deriving anything.
required = ("ts", "class", "declared_tier", "default_tier", "inherited",
            "escalated", "drift", "reason", "agent")
missing = sorted({key for r in records for key in required if key not in r})
emit(not missing, "every record carries the audit fields (missing: %s)"
     % (missing or "none"))

print("\n".join(out))
PY

if [ ! -s "$TMP/logreport" ]; then
  bad "declaration-log check produced no output: $(cat "$TMP/logerr")"
else
  LINES=0
  while IFS='|' read -r verdict message; do
    LINES=$((LINES+1))
    case "$verdict" in
      ok)  ok "$message" ;;
      bad) bad "$message" ;;
      *)   bad "unparseable log-check line: $verdict|$message" ;;
    esac
  done < "$TMP/logreport"
  [ "$LINES" -ge 10 ] \
    && ok "declaration-log check ran all $LINES assertions" \
    || bad "declaration-log check emitted only $LINES verdicts — expected at least 10"
fi

# ── POLICY REPORT ──
env -u HEIMDALL_REPO_POLICY "$TIER" policy --repo "$REPO" > "$TMP/pol" 2>&1; rc=$?
if grep -qi 'denied\|not allowed\|deny' "$TMP/pol"; then
  ok "tier policy reports non-ZDR models denied for this repo"
else
  bad "tier policy did not report the non-ZDR stance (rc=$rc): $(cat "$TMP/pol")"
fi

echo ""
echo "tier-declaration.test.sh: $PASS passed, $FAIL failed."
[ "$FAIL" -eq 0 ] || exit 1
exit 0
