#!/usr/bin/env bash
#
# tier-routing-table.test.sh — acceptance for the declared model-routing table.
#
# WHY: the security-guidance Stop hook ran 89x on Opus for $57.73 doing work the
# Haiku tier handles. That is a CLASS of leak, not an incident: wrong model on
# wrong task, invisible because nothing ever declared what tier the task WANTED.
# The fix is a routing table that is data, not doctrine — every task class maps
# to a tier, every agent template maps to a class, and both are machine-readable
# so an audit can compare DECLARED against OBSERVED.
#
# Guarantees proved:
#   1. bin/lib/tier-table.json is valid JSON and encodes every class in the spec
#      routing table at the spec's tier.
#   2. Every agents/*.md template is mapped to a known class (no silent orphans).
#   3. Fable is refused LOUDLY in a repo whose policy does not allow non-ZDR
#      models — nonzero exit, stderr diagnostic, and EMPTY stdout. A silent
#      downgrade to a cheaper tier would be the exact failure this gate exists
#      to prevent, so stdout emptiness is asserted, not assumed.
#   4. The refusal is FAIL-CLOSED: absent policy file, false, a JSON string
#      "true", and a decoy key all deny. Only a literal boolean true allows.
#   5. A HEIMDALL_MODEL_FABLE pin cannot bypass the policy gate.
#   6. bin/heimdall's degraded resolve_model() fallback also refuses fable — it
#      swallowed resolver stderr, so without its own gate it printed a bare
#      "fable" and the whole policy was decorative.
#   7. opus/sonnet/haiku are unaffected by repo policy (all are ZDR-eligible).
#
# PERF NOTE: every table assertion runs inside ONE python3 process. Interpreter
# startup on a loaded machine is seconds, so a spawn-per-assertion loop pushed
# this suite past two minutes and into the full gate's per-suite alarm.
#
# Usage:  test/tier-routing-table.test.sh   (exit 0 = all guarantees hold)
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SELF_DIR/.." && pwd)"
TABLE="$REPO/bin/lib/tier-table.json"
RESOLVE="$REPO/bin/heimdall-model-resolve"

PASS=0; FAIL=0
ok()  { printf '  \033[32mPASS\033[0m %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAIL=$((FAIL+1)); }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/tier-routing.XXXXXX")"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

echo "tier-routing-table harness  repo=$REPO"
echo "--------------------------------------------------------------------"

# ── 1-2. TABLE CONTENT: spec classes at spec tiers, every agent mapped ──
REPORT="$TMP/table-report.txt"
python3 - "$TABLE" "$REPO/agents" <<'PY' > "$REPORT" 2>"$TMP/table-err"
import glob, json, os, sys

# Spec 2.1 routing table, transcribed. A mismatch means the encoded table drifted
# from the written one.
SPEC = {
    "hook": "haiku", "classifier": "haiku", "formatter": "haiku",
    "janitor": "haiku", "statusline": "haiku", "marker_check": "haiku",
    "coder": "sonnet", "test_writer": "sonnet", "doc": "sonnet", "triage": "sonnet",
    "orchestrator": "opus", "architecture": "opus", "security_critical": "opus",
    "gate_adjudication": "opus", "forensics": "opus",
}

table_path, agents_dir = sys.argv[1], sys.argv[2]
out = []


def emit(good, message):
    out.append(("ok" if good else "bad") + "|" + message)


try:
    with open(table_path) as handle:
        table = json.load(handle)
    emit(True, "tier-table.json exists and parses as JSON")
except (OSError, ValueError) as exc:
    emit(False, "tier-table.json unreadable or invalid JSON: %s" % exc)
    print("\n".join(out))
    raise SystemExit(0)

classes = table.get("classes", {})
for name in sorted(SPEC):
    got = classes.get(name, {}).get("tier", "")
    emit(got == SPEC[name],
         "class %r -> tier %r (spec: %r)" % (name, got, SPEC[name]))

extra = sorted(set(classes) - set(SPEC))
emit(not extra, "no class outside the spec table (extra: %s)" % (extra or "none"))

agent_map = table.get("agents", {})
unmapped = []
for path in sorted(glob.glob(os.path.join(agents_dir, "*.md"))):
    agent = os.path.basename(path)[:-3]
    cls = agent_map.get(agent)
    if not cls:
        unmapped.append(agent)
    elif cls not in classes:
        unmapped.append("%s(unknown-class:%s)" % (agent, cls))
emit(bool(agent_map), "tier-table declares an agent->class map")
emit(not unmapped, "every agents/*.md maps to a known class (orphans: %s)"
     % (unmapped or "none"))

# Tier metadata the audit depends on: rank ordering and a price for each tier.
tiers = table.get("tiers", {})
emit(set(tiers) == {"haiku", "sonnet", "opus", "fable"},
     "tiers block covers haiku/sonnet/opus/fable (got: %s)" % sorted(tiers))
ranks = [(name, meta.get("rank")) for name, meta in sorted(tiers.items())]
emit(all(isinstance(rank, int) for _, rank in ranks),
     "every tier declares an integer rank (%s)" % ranks)
emit(tiers.get("haiku", {}).get("rank", 0) < tiers.get("sonnet", {}).get("rank", 0)
     < tiers.get("opus", {}).get("rank", 0),
     "rank orders haiku < sonnet < opus")
emit(tiers.get("fable", {}).get("rank") == tiers.get("opus", {}).get("rank"),
     "fable shares opus's rank (spec 2.1 top row is 'Opus / Fable')")
emit(all(meta.get("price_input_per_mtok", 0) > 0
         and meta.get("price_output_per_mtok", 0) > 0 for meta in tiers.values()),
     "every tier carries a nonzero input and output price")

emit(table.get("non_zdr_tiers") == ["fable"],
     "non_zdr_tiers = %r (must match the tier the resolver gates)"
     % (table.get("non_zdr_tiers"),))
emit(table.get("non_zdr_policy_key") == "allow_non_zdr_models",
     "non_zdr_policy_key names the opt-in key the resolver reads")
emit(tiers.get("fable", {}).get("zdr_eligible") is False,
     "fable is marked zdr_eligible: false")

# The binding safety rule, encoded as data: classes that may never be downgraded
# to save money must say so, with a reason a reader can evaluate.
for name in ("security_critical", "gate_adjudication"):
    meta = classes.get(name, {})
    emit(meta.get("security_sensitive") is True
         and bool(meta.get("no_downgrade_reason")),
         "class %r is flagged security_sensitive with a stated no-downgrade reason"
         % name)

print("\n".join(out))
PY

if [ ! -s "$REPORT" ]; then
  bad "table check produced no output — assertions did not run"
  printf '       %s\n' "$(cat "$TMP/table-err")"
else
  LINES=0
  while IFS='|' read -r verdict message; do
    LINES=$((LINES+1))
    case "$verdict" in
      ok)  ok "$message" ;;
      bad) bad "$message" ;;
      *)   bad "unparseable table-check line: $verdict|$message" ;;
    esac
  done < "$REPORT"
  # Anti-vacuous floor: the block above emits 26 verdicts. Fewer means it bailed
  # early and a green run would be meaningless.
  [ "$LINES" -ge 26 ] \
    && ok "table check ran all $LINES assertions" \
    || bad "table check emitted only $LINES verdicts — expected at least 26"
fi

# ── 3. FABLE REFUSED LOUDLY UNDER A FORBIDDING POLICY ──
DENY_POLICY="$TMP/deny.json"
printf '%s\n' '{"allow_non_zdr_models": false}' > "$DENY_POLICY"
ALLOW_POLICY="$TMP/allow.json"
printf '%s\n' '{"allow_non_zdr_models": true}' > "$ALLOW_POLICY"

out="$(HEIMDALL_REPO_POLICY="$DENY_POLICY" "$RESOLVE" fable 2>"$TMP/err")"; rc=$?
err="$(cat "$TMP/err")"
[ "$rc" -ne 0 ] \
  && ok "fable under allow_non_zdr_models:false exits nonzero (rc=$rc)" \
  || bad "fable under a forbidding policy exited 0 — silent acceptance"
[ -z "$out" ] \
  && ok "fable refusal writes NOTHING to stdout (no silent downgrade)" \
  || bad "fable refusal printed '$out' on stdout — a caller would use it"
grep -qi 'zdr' <<<"$err" \
  && ok "fable refusal names ZDR on stderr" \
  || bad "fable refusal stderr does not mention ZDR: '$err'"
grep -q 'allow_non_zdr_models' <<<"$err" \
  && ok "fable refusal names the policy key that would permit it" \
  || bad "fable refusal does not name allow_non_zdr_models: '$err'"

# ── 4. FAIL-CLOSED VARIANTS ──
printf '%s\n' '{"note": "no policy key here"}' > "$TMP/nokey.json"
printf '%s\n' '{"allow_non_zdr_models": "true"}' > "$TMP/string.json"
printf '%s\n' '{"x_allow_non_zdr_models": true}' > "$TMP/decoy.json"
for variant in missing:"$TMP/does-not-exist.json" \
               nokey:"$TMP/nokey.json" \
               json-string:"$TMP/string.json" \
               decoy-key:"$TMP/decoy.json"; do
  label="${variant%%:*}"; path="${variant#*:}"
  out="$(HEIMDALL_REPO_POLICY="$path" "$RESOLVE" fable 2>/dev/null)"; rc=$?
  if [ "$rc" -ne 0 ] && [ -z "$out" ]; then
    ok "fable denied fail-closed for policy variant '$label'"
  else
    bad "fable ALLOWED for policy variant '$label' (rc=$rc out='$out')"
  fi
done

# Default (no env override) must also deny while this repo commits no policy.
out="$(cd "$REPO" && env -u HEIMDALL_REPO_POLICY -u HEIMDALL_REPO "$RESOLVE" fable 2>/dev/null)"; rc=$?
if [ -f "$REPO/.planning/repo-policy.json" ] \
   && grep -Eq '"allow_non_zdr_models"[[:space:]]*:[[:space:]]*true' "$REPO/.planning/repo-policy.json"; then
  [ "$rc" -eq 0 ] && [ "$out" = "fable" ] \
    && ok "repo policy opts in — fable resolves to '$out'" \
    || bad "repo policy allows non-ZDR but fable was refused (rc=$rc)"
else
  [ "$rc" -ne 0 ] && [ -z "$out" ] \
    && ok "no repo policy committed -> fable denied by default (deny-by-default)" \
    || bad "fable allowed with no policy file (rc=$rc out='$out') — default is open"
fi

# ── 5. ALLOWED POLICY LETS FABLE THROUGH, AS A BARE ALIAS ──
# Without this the gate could be satisfied by refusing everything.
out="$(HEIMDALL_REPO_POLICY="$ALLOW_POLICY" "$RESOLVE" fable 2>/dev/null)"; rc=$?
[ "$rc" -eq 0 ] && [ "$out" = "fable" ] \
  && ok "fable under allow_non_zdr_models:true -> '$out' (bare alias)" \
  || bad "fable under an allowing policy -> rc=$rc out='$out', expected 'fable'"

# ── 6. A PIN CANNOT BYPASS THE GATE ──
out="$(HEIMDALL_REPO_POLICY="$DENY_POLICY" HEIMDALL_MODEL_FABLE=claude-fable-5 \
       "$RESOLVE" fable 2>/dev/null)"; rc=$?
[ "$rc" -ne 0 ] && [ -z "$out" ] \
  && ok "HEIMDALL_MODEL_FABLE pin does NOT bypass the policy gate" \
  || bad "pin bypassed the ZDR gate (rc=$rc out='$out')"
out="$(HEIMDALL_REPO_POLICY="$ALLOW_POLICY" HEIMDALL_MODEL_FABLE=claude-fable-5 \
       "$RESOLVE" fable 2>/dev/null)"
[ "$out" = "claude-fable-5" ] \
  && ok "HEIMDALL_MODEL_FABLE pins fable when policy allows -> '$out'" \
  || bad "fable pin under an allowing policy -> '$out', expected claude-fable-5"

# ── 7. bin/heimdall DEGRADED PATH ALSO REFUSES ──
# resolve_model() falls back to a bare tier when the resolver is unavailable and
# used to swallow its stderr. Without its own gate that path prints "fable".
if grep -q '^resolve_model()' "$REPO/bin/heimdall"; then
  probe="$TMP/probe.sh"
  {
    printf '%s\n' '#!/usr/bin/env bash'
    printf '%s\n' 'set -uo pipefail'
    printf '%s\n' "PLUGIN_DIR=\"$TMP/no-such-plugin-dir\""
    sed -n '/^resolve_model()/,/^}/p' "$REPO/bin/heimdall"
    printf '%s\n' 'resolve_model "$1"'
  } > "$probe"
  chmod +x "$probe"
  out="$(HEIMDALL_REPO_POLICY="$DENY_POLICY" "$probe" fable 2>/dev/null)"; rc=$?
  [ "$rc" -ne 0 ] && [ -z "$out" ] \
    && ok "bin/heimdall resolve_model() degraded path refuses fable" \
    || bad "resolve_model() degraded path emitted '$out' for fable (rc=$rc) — gate bypassed"
  out="$("$probe" sonnet 2>/dev/null)"
  [ "$out" = "sonnet" ] \
    && ok "resolve_model() degraded path still resolves sonnet -> '$out'" \
    || bad "resolve_model() degraded path broke sonnet -> '$out'"
else
  bad "bin/heimdall has no resolve_model() — cannot verify the degraded path"
fi

# ── 8. ZDR TIERS UNAFFECTED BY POLICY ──
for tier in opus sonnet haiku; do
  out="$(HEIMDALL_REPO_POLICY="$DENY_POLICY" \
         env -u HEIMDALL_MODEL_OPUS -u HEIMDALL_MODEL_SONNET -u HEIMDALL_MODEL_HAIKU \
         "$RESOLVE" "$tier" 2>/dev/null)"; rc=$?
  # What this asserts is that the non-ZDR gate does not reach a ZDR-eligible
  # tier: it resolves, exit 0, and names THIS tier. The match is a prefix rather
  # than an equality because sonnet legitimately resolves to 'sonnet[1m]' (the
  # 1M-context alias) — still that tier, still not a pinned id. An equality here
  # would fail on a context-window change that has nothing to do with ZDR.
  case "$out" in
    "$tier"|"$tier"'[1m]') named_tier=yes ;;
    *) named_tier=no ;;
  esac
  [ "$rc" -eq 0 ] && [ "$named_tier" = yes ] \
    && ok "$tier unaffected by non-ZDR policy -> '$out'" \
    || bad "$tier blocked or renamed by non-ZDR policy (rc=$rc out='$out') — over-broad gate"
done

echo ""
echo "tier-routing-table.test.sh: $PASS passed, $FAIL failed."
[ "$FAIL" -eq 0 ] || exit 1
exit 0
