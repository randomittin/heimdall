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
#   8. A tier states no price of its own: `heimdall-tier table` prices each tier at
#      the newest model_prices row of its family (the current generation), a newer
#      row moves the tier price with no second edit, and a tier with no row fails
#      loudly instead of printing an invented number.
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
python3 - "$TABLE" "$REPO/agents" "$REPO/bin/heimdall-tier" <<'PY' > "$REPORT" 2>"$TMP/table-err"
import glob, json, os, re, shutil, subprocess, sys, tempfile

# Spec 2.1 routing table, transcribed. A mismatch means the encoded table drifted
# from the written one.
SPEC = {
    "hook": "haiku", "classifier": "haiku", "formatter": "haiku",
    "janitor": "haiku", "statusline": "haiku", "marker_check": "haiku",
    "coder": "sonnet", "test_writer": "sonnet", "doc": "sonnet", "triage": "sonnet",
    "architecture": "sonnet", "forensics": "sonnet",
    "orchestrator": "opus", "security_critical": "opus", "gate_adjudication": "opus",
}

table_path, agents_dir, tier_bin = sys.argv[1], sys.argv[2], sys.argv[3]
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
# Tier prices. A tier states NO price of its own: the number lives once, in the
# newest model_prices row of the tier's family, so it cannot drift from the
# per-model list prices. The stored copy did: it read Sonnet 4.6's $3/$15 for
# "sonnet" after Sonnet 5.5 listed at $2/$10 (Opus $5/$25 vs $4/$20, Haiku $1/$5
# vs $0.10/$0.50), and everything that read the tier price repeated it.
stored = sorted(name for name, meta in tiers.items()
                if "price_input_per_mtok" in meta or "price_output_per_mtok" in meta)
emit(not stored, "no tier stores its own price, model_prices is the one source (stored: %s)"
     % (stored or "none"))


def version_key(row):
    return tuple(int(part) for part in row["version"].split("."))


def newest_rows(rows):
    newest = {}
    for row in rows:
        family = row["family"]
        if family not in newest or version_key(row) > version_key(newest[family]):
            newest[family] = row
    return newest


newest = newest_rows(table.get("model_prices", {}).get("rows", []))
unpriced = sorted(set(tiers) - set(newest))
emit(not unpriced, "every tier has a model_prices row of its own family (unpriced: %s)"
     % (unpriced or "none"))


def printed_prices(binary):
    """{tier: (input, output)} that `heimdall-tier table` prints, plus its exit
    code and stderr. Parsed from the printed table: that is what a reader sees."""
    run = subprocess.run([binary, "table"], capture_output=True, text=True)
    shown = {}
    for line in run.stdout.splitlines():
        found = re.match(r"(\w+)\s+rank \d+\s+\$([0-9.]+)/\$([0-9.]+) per Mtok", line)
        if found:
            shown[found.group(1)] = (float(found.group(2)), float(found.group(3)))
    return shown, run.returncode, run.stderr


# $/MTok input/output of the current generation, from the claude-api skill's
# Current Models table (pricing cached 2026-11-03). A bare tier alias resolves
# to the current generation, so the tier's price IS that generation's price.
CURRENT = {"haiku": (0.10, 0.50),     # Claude Haiku 5.5
           "sonnet": (2.00, 10.00),   # Claude Sonnet 5.5
           "opus": (4.00, 20.00),     # Claude Opus 5.5
           "fable": (8.00, 40.00)}    # Claude Fable 5.2
shown, rc, err = printed_prices(tier_bin)
emit(shown == {name: (round(row["input"], 2), round(row["output"], 2))
               for name, row in newest.items() if name in tiers},
     "heimdall-tier table prints each tier at its family's newest model_prices row (rc=%d, got %s)"
     % (rc, shown))
for name in sorted(CURRENT):
    emit(shown.get(name) == CURRENT[name],
         "tier %s prints the current-generation price %s (got %s)"
         % (name, CURRENT[name], shown.get(name)))

# Single-source property: add a row and the tier price follows, no second edit.
# The newest row (10.1: a string compare ranks it below 5.5) sits in the middle,
# an older row first and another last, so the first row, the last row and a
# string max all give the wrong answer.
workdir = tempfile.mkdtemp(prefix="tier-price.")
try:
    os.makedirs(os.path.join(workdir, "lib"))
    copy_bin = os.path.join(workdir, "heimdall-tier")
    shutil.copy(tier_bin, copy_bin)
    mutated = json.loads(json.dumps(table))
    mutated_rows = mutated["model_prices"]["rows"]
    mutated_rows.insert(0, {"family": "opus", "version": "1.0", "input": 99.0, "output": 99.0})
    mutated_rows.insert(len(mutated_rows) // 2,
                        {"family": "opus", "version": "10.1", "input": 1.5, "output": 7.5})
    mutated_rows.append({"family": "opus", "version": "2.0", "input": 98.0, "output": 98.0})
    with open(os.path.join(workdir, "lib", "tier-table.json"), "w") as handle:
        json.dump(mutated, handle)
    shown_m, rc_m, err_m = printed_prices(copy_bin)
    emit(shown_m.get("opus") == (1.5, 7.5),
         "a newer opus row moves the opus tier price, numeric newest wins not first/last/string order (got %s)"
         % (shown_m.get("opus"),))
    emit(all(shown_m.get(name) == CURRENT[name] for name in ("haiku", "sonnet", "fable")),
         "the other tiers keep pricing from their own rows after that edit (got %s)" % (shown_m,))
    mutated["model_prices"]["rows"] = [row for row in mutated_rows if row["family"] != "haiku"]
    with open(os.path.join(workdir, "lib", "tier-table.json"), "w") as handle:
        json.dump(mutated, handle)
    bare = subprocess.run([copy_bin, "table"], capture_output=True, text=True)
    emit(bare.returncode != 0 and "haiku" in bare.stderr,
         "a tier with no model_prices row fails loudly, no invented price (rc=%d stderr=%r)"
         % (bare.returncode, bare.stderr.strip()))
finally:
    shutil.rmtree(workdir, ignore_errors=True)

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
  # Anti-vacuous floor: the block above emits 38 verdicts. Fewer means it bailed
  # early and a green run would be meaningless.
  [ "$LINES" -ge 38 ] \
    && ok "table check ran all $LINES assertions" \
    || bad "table check emitted only $LINES verdicts — expected at least 38"
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
