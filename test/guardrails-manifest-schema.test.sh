#!/usr/bin/env bash
#
# guardrails-manifest-schema.test.sh -- guardrails.manifest.json format v1: its schema file and its validator
# (3.x M1, task T0.5 of docs/superpowers/plans/2026-11-12-3x-m1-skill-registry.md).
#
# guardrails.manifest.json puts every guardrail in one of two tiers: `core` (security and correctness gates, never
# switchable by any hmd command or config file) or `recommended` (cost and discipline guards: on by default, switchable
# by the operator). The rule the whole tier system rests on, and the one this suite exists to pin:
#
#     ANYTHING NOT POSITIVELY CLASSIFIED IS CORE.
#
# bin/lib/guardrails_manifest.py therefore never defaults a missing tier (the row is rejected), treats a hook that
# hooks.metadata.json does not positively mark `locked: false` as locked, and refuses every shape in which two readers
# could disagree about one guard's tier (a repeated id, a repeated JSON key, a field it does not know).
#
# Proven here against a throwaway fixture manifest and fixture hooks metadata (the repo's own manifest is a later task):
#   A. the valid fixture is accepted -- including the shapes a too-eager rule would reject: a `recommended` guard INSIDE a
#      locked hook (ci-waste-guard inside bash-gate-chain), a `provisional` core row, a `feature` row without a proof, a guard
#      outside hooks.json whose `hook` is null or absent --
#      and the real hooks/hooks.metadata.json loads
#   B. every defect, applied ALONE to that fixture, is rejected with exit 1 naming its reason and never with a traceback:
#      structure (schema is the integer 1, shape, enums, patterns), tiers (unknown, missing, locked but recommended),
#      duplicate ids, a guard without a proof, the hooks-metadata cross-checks, JSON that is malformed, ambiguous or unreadable
#   C. the schema file and the validator state the same format (enums, required and optional keys, patterns, the example)
#   D. the suite can go RED: a one-line break of a copy of the validator makes each rule's cases pass
# The validator does not look for the files `proof` names; that is the drift test's job (T1.3), which can see the repo.
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VALIDATOR="$REPO/bin/lib/guardrails_manifest.py"
PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; if [ -n "${2:-}" ]; then printf '       %s\n' "$2"; fi; }

PY="$(command -v python3 || true)"
[ -n "$PY" ] || { echo "FATAL: python3 not found"; exit 2; }
# the interpreter itself, not a version-manager shim: a shim costs ~0.4 s a call and this suite starts python ~120 times
PY="$("$PY" -c 'import sys; print(sys.executable)')" && [ -n "$PY" ] || { echo "FATAL: cannot resolve python3"; exit 2; }

WORK="$(mktemp -d)" || exit 2
trap 'rm -rf "$WORK"' EXIT
CASES="$WORK/cases"
MUT="$WORK/mut"
mkdir -p "$CASES" "$MUT"
INDEX="$CASES/index.tsv"     # name, manifest file, reason, hooks metadata file: section D replays every case against a broken validator
: > "$INDEX"
VALID="$WORK/manifest.json"
META="$WORK/hooks.metadata.json"

# ---- fixtures: the valid manifest and the hooks metadata it is checked against ------------------------------------
cat > "$META" <<'EOF'
{
  "_comment": "fixture: the shape of hooks/hooks.metadata.json, four hooks",
  "hooks": [
    {"event": "PreToolUse", "index": 0, "id": "stub-gate", "locked": true, "remote_toggle": false},
    {"event": "PreToolUse", "index": 1, "id": "bash-gate-chain", "locked": true, "remote_toggle": false},
    {"event": "Stop", "index": 2, "id": "stop-lint", "locked": false, "remote_toggle": true},
    {"event": "SessionStart", "index": 3, "id": "session-bootstrap", "locked": false, "remote_toggle": true}
  ]
}
EOF
cat > "$VALID" <<'EOF'
{
  "_comment": "fixture for test/guardrails-manifest-schema.test.sh",
  "schema": 1,
  "guardrails": [
    {"id": "stub-gate", "kind": "guard", "tier": "core", "layer": "hook", "hook": "stub-gate",
     "fails": "closed", "operator_env": null, "proof": "test/pre-commit-stub-gate.test.sh",
     "why": "unfinished code never lands"},
    {"id": "bash-gate-chain", "kind": "guard", "tier": "core", "layer": "hook", "hook": "bash-gate-chain",
     "fails": "closed", "operator_env": null, "proof": "test/heimdall-precheck-bash.test.sh",
     "why": "the commit and push gate stack"},
    {"id": "ci-waste-guard", "kind": "guard", "tier": "recommended", "layer": "precheck-bash",
     "hook": "bash-gate-chain", "fails": "open", "operator_env": "HMD_CI_RERUN_ALLOW=1",
     "proof": "test/ci-waste-guard.test.sh", "why": "never pay CI minutes to re-roll a flaky result"},
    {"id": "kill-guard", "kind": "guard", "tier": "core", "layer": "precheck-bash",
     "hook": "bash-gate-chain", "fails": "closed", "operator_env": "HMD_KILL_GUARD=off",
     "proof": "test/hmd-server-kill-guard.test.sh", "provisional": true,
     "why": "no pkill or killall by name"},
    {"id": "stop-lint", "kind": "guard", "tier": "recommended", "layer": "hook", "hook": "stop-lint",
     "fails": "open", "operator_env": null, "proof": "test/heimdall-stop-lint.test.sh",
     "why": "lint runs before a turn ends"},
    {"id": "session-bootstrap", "kind": "feature", "tier": "recommended", "layer": "hook",
     "hook": "session-bootstrap", "why": "session start wiring, not a guardrail"},
    {"id": "native-pre-push", "kind": "guard", "tier": "core", "layer": "native-git-hook", "hook": null,
     "fails": "closed", "operator_env": null, "proof": "test/pre-push-gate-dedup.test.sh",
     "why": "the native push gate, outside hooks.json"},
    {"id": "repo-checks", "kind": "guard", "tier": "core", "layer": "script",
     "proof": "test/heimdall-push-gate-per-repo.test.sh", "why": "the per-repo push gate, a script with no hook"}
  ]
}
EOF

# ---- helper scripts (files, so no heredoc has to live inside a command substitution) ------------------------------
cat > "$WORK/mutate.py" <<'EOF'
import json
import sys

src, dst, code = sys.argv[1:4]
with open(src, encoding="utf-8") as handle:
    d = json.load(handle)


def r(row_id):
    """The guardrail row (or hooks-metadata hook) with this id."""
    return next(x for x in (d.get("guardrails") or d.get("hooks")) if x["id"] == row_id)


exec(code)
with open(dst, "w", encoding="utf-8") as handle:
    json.dump(d, handle, indent=2)
EOF
cat > "$WORK/apply.py" <<'EOF'
import sys

src, dst, old, new = sys.argv[1:5]
with open(src, encoding="utf-8") as handle:
    text = handle.read()
count = text.count(old)
if count != 1:
    sys.exit("mutation target found %d times, need exactly 1: %s" % (count, old))
with open(dst, "w", encoding="utf-8") as handle:
    handle.write(text.replace(old, new))
EOF
cat > "$WORK/cross.py" <<'EOF'
import json
import os
import sys

repo = sys.argv[1]
sys.path.insert(0, os.path.join(repo, "bin", "lib"))
import guardrails_manifest as gm

with open(os.path.join(repo, "docs", "schemas", "guardrails.manifest.v1.json"), encoding="utf-8") as handle:
    schema = json.load(handle)
top = schema["properties"]
row = schema["$defs"]["guardrail"]
props = row["properties"]
invariants = [item["id"] for item in schema["x-invariants"]]
checks = [
    ("schema constant is SCHEMA_VERSION", top["schema"].get("const") == gm.SCHEMA_VERSION),
    ("top-level keys are closed and required", sorted(top) == sorted(gm.TOP_LEVEL) and schema.get("additionalProperties") is False
        and schema.get("required") == ["schema", "guardrails"]),
    ("guardrails is a non-empty array of guardrail", top["guardrails"].get("type") == "array" and top["guardrails"].get("minItems") == 1
        and top["guardrails"].get("items") == {"$ref": "#/$defs/guardrail"}),
    ("tier enum", props["tier"].get("enum") == list(gm.TIERS)),
    ("kind enum", props["kind"].get("enum") == list(gm.KINDS)),
    ("fails enum", props["fails"].get("enum") == list(gm.FAILS)),
    ("row required keys", row.get("required") == list(gm.REQUIRED)),
    ("row keys are closed", sorted(props) == sorted(gm.REQUIRED + gm.OPTIONAL) and row.get("additionalProperties") is False),
    ("id pattern", props["id"] == {"$ref": "#/$defs/id"} and schema["$defs"]["id"].get("pattern") == "^" + gm.ID + "$"),
    ("hook pattern", props["hook"].get("type") == ["string", "null"] and props["hook"].get("pattern") == "^" + gm.ID + "$"),
    ("layer pattern", props["layer"].get("pattern") == "^" + gm.LAYER + "$"),
    ("operator_env pattern", props["operator_env"].get("type") == ["string", "null"]
        and props["operator_env"].get("pattern") == "^" + gm.OPERATOR_ENV + "$"),
    ("why and proof must not be blank", props["why"].get("pattern") == "\\S" and props["proof"].get("pattern") == "\\S"),
    ("provisional is a boolean", props["provisional"].get("type") == "boolean"),
    ("x-invariants have unique ids", len(invariants) >= 5 and len(invariants) == len(set(invariants))),
    ("its example is a valid manifest", gm.validate(schema["examples"][0]) == []),
]
for name, passed in checks:
    print(("ok " if passed else "bad ") + name)
EOF
cat > "$WORK/realmeta.py" <<'EOF'
import sys

sys.path.insert(0, sys.argv[1] + "/bin/lib")
import guardrails_manifest as gm

hooks = gm.load_hooks_metadata(sys.argv[1] + "/hooks/hooks.metadata.json")
assert all(isinstance(locked, bool) for locked in hooks.values()), "locked must be a bool for every hook"
assert hooks["stub-gate"] is True and hooks["bash-gate-chain"] is True, "the security gates must read as locked"
assert not all(hooks.values()), "at least one hook must read as unlocked"
print("ok %d hooks, %d locked" % (len(hooks), sum(hooks.values())))
EOF

# ---- helpers -------------------------------------------------------------------------------------------------------
run_validator() { local v="$1"; shift; OUT="$("$PY" -I "$v" "$@" 2>&1)"; RC=$?; }

# accepts <validator> <file> [args]: exit 0, the ok line, no traceback
accepts() {
  local v="$1" file="$2"; shift 2
  run_validator "$v" validate "$file" "$@"
  [ "$RC" -eq 0 ] || return 1
  case "$OUT" in *Traceback*) return 1 ;; esac
  case "$OUT" in *"ok guardrails.manifest/1"*) return 0 ;; *) return 1 ;; esac
}

# rejects <validator> <file> <reason> [args]: exit 1, <reason> in the output, no traceback
rejects() {
  local v="$1" file="$2" reason="$3"; shift 3
  run_validator "$v" validate "$file" "$@"
  [ "$RC" -eq 1 ] || return 1
  case "$OUT" in *Traceback*) return 1 ;; esac
  case "$OUT" in *"$reason"*) return 0 ;; *) return 1 ;; esac
}

# rejects_meta <validator> <file> <reason> <meta>: rejects, with <meta> a hooks metadata file, "" for none, or @empty for an EMPTY --hooks-metadata value
rejects_meta() {
  case "$4" in
    "")     rejects "$1" "$2" "$3" ;;
    @empty) rejects "$1" "$2" "$3" --hooks-metadata "" ;;
    *)      rejects "$1" "$2" "$3" --hooks-metadata "$4" ;;
  esac
}

# expect <name> <file> <reason> [hooks metadata file | @empty]: the REAL validator rejects <file> for <reason>; the case is kept for section D
expect() {
  local name="$1" file="$2" reason="$3" meta="${4:-}"
  printf '%s\t%s\t%s\t%s\n' "$name" "$file" "$reason" "$meta" >> "$INDEX"
  if rejects_meta "$VALIDATOR" "$file" "$reason" "$meta"; then ok "$name: exit 1, \"$reason\""; else bad "$name: want exit 1 saying \"$reason\"" "exit $RC: $OUT"; fi
}

# reject <name> <reason> <python on d>: the valid manifest with ONE defect, checked against the good hooks metadata.
# `d` is the parsed JSON and r("<id>") the row with that id.
reject() {
  local file="$CASES/$1.json"
  if ! "$PY" -I "$WORK/mutate.py" "$VALID" "$file" "$3" 2>"$WORK/build.err"; then bad "$1: the case could not be built" "$(cat "$WORK/build.err")"; return; fi
  expect "$1" "$file" "$2" "$META"
}

# reject_meta <name> <reason> <python on d>: the valid manifest against hooks metadata with ONE defect
reject_meta() {
  local file="$CASES/$1.json"
  if ! "$PY" -I "$WORK/mutate.py" "$META" "$file" "$3" 2>"$WORK/build.err"; then bad "$1: the case could not be built" "$(cat "$WORK/build.err")"; return; fi
  expect "$1" "$VALID" "$2" "$file"
}

# ---- A. the valid fixture --------------------------------------------------------------------------------------------
echo "-- A. the valid fixture --"
if accepts "$VALIDATOR" "$VALID" --hooks-metadata "$META"; then
  ok "the valid fixture is accepted against the hooks metadata (a recommended guard inside a locked hook, a provisional core row and a feature row without a proof are all legal)"
else
  bad "the valid fixture is accepted against the hooks metadata" "exit $RC: $OUT"
fi
case "$OUT" in *"(8 guardrails)"*) ok "the ok line says how many rows were checked" ;; *) bad "the ok line says how many rows were checked" "$OUT" ;; esac
case "$OUT" in *"were not checked"*) bad "with --hooks-metadata the output must not say the hook checks were skipped" "$OUT" ;; *) ok "with --hooks-metadata there is no skipped-checks note" ;; esac
if accepts "$VALIDATOR" "$VALID"; then
  case "$OUT" in
    *"were not checked"*) ok "without --hooks-metadata the structure is checked and the output says the hook checks were not" ;;
    *) bad "without --hooks-metadata the output must say the hook checks were skipped" "$OUT" ;;
  esac
else
  bad "the valid fixture is accepted without --hooks-metadata" "exit $RC: $OUT"
fi
if REALOUT="$("$PY" -I "$WORK/realmeta.py" "$REPO" 2>&1)"; then ok "the real hooks/hooks.metadata.json loads: $REALOUT"; else bad "the real hooks/hooks.metadata.json loads" "$REALOUT"; fi

# ---- B. one defect at a time -----------------------------------------------------------------------------------------
echo "-- B1. structure: the schema version, the shape, the enums and patterns --"
reject schema-2           'schema must be the integer 1'          'd["schema"] = 2'
reject schema-true        'schema must be the integer 1'          'd["schema"] = True'
reject schema-float       'schema must be the integer 1'          'd["schema"] = 1.0'
reject schema-string      'schema must be the integer 1'          'd["schema"] = "1"'
reject top-level-extra    "unexpected top-level key 'extra'"      'd["extra"] = 1'
reject comment-not-text   '_comment must be a string'             'd["_comment"] = 5'
reject guardrails-gone    'guardrails must be a non-empty array'  'del d["guardrails"]'
reject guardrails-empty   'guardrails must be a non-empty array'  'd["guardrails"] = []'
reject guardrails-object  'guardrails must be a non-empty array'  'd["guardrails"] = {}'
reject row-not-object     'guardrails[8] must be a JSON object'   'd["guardrails"].append("stub-gate")'
reject row-extra-key      "unexpected key 'switchable'"           'r("ci-waste-guard")["switchable"] = True'
reject id-bad             'id must match'                         'r("ci-waste-guard")["id"] = "CI_Waste"'
reject kind-unknown       "unknown kind 'optional'"               'r("ci-waste-guard")["kind"] = "optional"'
reject layer-bad          'layer must match'                      'r("ci-waste-guard")["layer"] = "Precheck Bash"'
reject why-blank          'why must be a non-blank string'        'r("ci-waste-guard")["why"] = "  "'
reject hook-not-id        'hook must be a hook id'                'r("ci-waste-guard")["hook"] = "Bash Gate"'
reject fails-bad          "unknown fails 'maybe'"                 'r("ci-waste-guard")["fails"] = "maybe"'
reject env-bad            'operator_env must be NAME'             'r("ci-waste-guard")["operator_env"] = "HMD CI RERUN"'
reject provisional-bad    'provisional must be true or false'     'r("kill-guard")["provisional"] = "yes"'

echo "-- B2. tiers: anything not positively classified is core --"
reject tier-unknown       "unknown tier 'optional'"               'r("stop-lint")["tier"] = "optional"'
reject tier-case          "unknown tier 'Recommended'"            'r("stop-lint")["tier"] = "Recommended"'
reject tier-list          "unknown tier ['core']"                 'r("stop-lint")["tier"] = ["core"]'
reject tier-null          'unknown tier None'                     'r("stop-lint")["tier"] = None'
reject tier-missing       "missing required key 'tier'"           'del r("ci-waste-guard")["tier"]'
reject locked-recommended 'so tier must be core'                  'r("stub-gate")["tier"] = "recommended"'
# Without the metadata the locked rule cannot run: the manifest is accepted, and the output says what was skipped.
if accepts "$VALIDATOR" "$CASES/locked-recommended.json"; then
  case "$OUT" in *"were not checked"*) ok "locked-recommended without --hooks-metadata: accepted, with the note that the hook checks were skipped" ;; *) bad "locked-recommended without --hooks-metadata must carry the note" "$OUT" ;; esac
else
  bad "locked-recommended without --hooks-metadata is a structural pass" "exit $RC: $OUT"
fi

echo "-- B3. ids and proofs --"
reject duplicate-id       "duplicate id 'ci-waste-guard'"         'd["guardrails"].append(dict(r("ci-waste-guard")))'
reject duplicate-id-conflicting-tiers "duplicate id 'kill-guard'" 'x = dict(r("kill-guard")); x["tier"] = "recommended"; d["guardrails"].append(x)'
reject guard-no-proof     'requires a proof'                      'del r("ci-waste-guard")["proof"]'
reject guard-blank-proof  'requires a proof'                      'r("ci-waste-guard")["proof"] = "  "'
reject guard-null-proof   'requires a proof'                      'r("ci-waste-guard")["proof"] = None'
reject feature-proof-bad  'proof must be a non-blank string or null' 'r("session-bootstrap")["proof"] = 5'

echo "-- B4. the hooks-metadata cross-checks --"
reject hook-row-unknown   'is not a hook in hooks metadata'       'd["guardrails"].append({"id": "ghost-hook", "kind": "feature", "tier": "recommended", "layer": "hook", "hook": "ghost-hook", "why": "not in the metadata"})'
reject hook-row-mismatch  'hook must equal id'                    'r("stop-lint")["hook"] = "session-bootstrap"'
reject hook-ref-unknown   "hook 'no-such-hook' is not in hooks metadata" 'r("ci-waste-guard")["hook"] = "no-such-hook"'
reject hook-mislabelled   "hook 'stub-gate' has no row with layer \"hook\"" 'r("stub-gate").update(layer="precheck-bash", tier="recommended")'
reject coverage-missing   "hook 'session-bootstrap' has no row with layer \"hook\"" 'd["guardrails"].remove(r("session-bootstrap"))'
# A hook the metadata does not positively mark `locked: false` is locked: its row cannot be recommended.
reject_meta meta-locked-string  'so tier must be core'            'r("stop-lint")["locked"] = "false"'
reject_meta meta-locked-missing 'so tier must be core'            'del r("stop-lint")["locked"]'

echo "-- B5. JSON that cannot be read as strict JSON, and hooks metadata that cannot be trusted --"
printf '{"schema": 1, "guardrails": [' > "$CASES/truncated.json"
expect truncated "$CASES/truncated.json" 'is not strict JSON'
: > "$CASES/empty.json"
expect empty-file "$CASES/empty.json" 'is not strict JSON'
printf '\377\376{"schema": 1}' > "$CASES/bad-utf8.json"
expect bad-utf8 "$CASES/bad-utf8.json" 'is not strict JSON'
"$PY" -I -c 'import sys; sys.stdout.write("[" * 100000 + "]" * 100000)' > "$CASES/deep.json"
expect deep-nesting "$CASES/deep.json" 'is not strict JSON'
printf '[]' > "$CASES/root-array.json"
expect root-array "$CASES/root-array.json" 'the manifest must be a JSON object'
cat > "$CASES/dup-key.json" <<'EOF'
{"schema": 1, "guardrails": [{"id": "stop-lint", "kind": "feature", "tier": "core", "tier": "recommended", "layer": "hook", "hook": "stop-lint", "why": "states its tier twice"}]}
EOF
expect dup-key "$CASES/dup-key.json" "duplicate key 'tier'"
expect missing-manifest "$CASES/no-such-file.json" 'cannot read manifest'
printf '{"hooks": [' > "$CASES/meta-truncated.json"
expect meta-truncated "$VALID" "hooks metadata $CASES/meta-truncated.json is not strict JSON" "$CASES/meta-truncated.json"
printf '{"hooks": []}' > "$CASES/meta-empty.json"
expect meta-empty "$VALID" 'has no non-empty "hooks" array' "$CASES/meta-empty.json"
printf '{"hooks": [{"locked": true}]}' > "$CASES/meta-no-id.json"
expect meta-no-id "$VALID" 'has no string id' "$CASES/meta-no-id.json"
printf '{"hooks": [{"id": "a-b", "locked": true}, {"id": "a-b", "locked": false}]}' > "$CASES/meta-dup-id.json"
expect meta-dup-id "$VALID" "duplicate hook id 'a-b'" "$CASES/meta-dup-id.json"
expect meta-missing "$VALID" 'cannot read hooks metadata' "$CASES/no-such-meta.json"
# an EMPTY --hooks-metadata value (an unset shell variable, say) is an error, never "no metadata"
expect meta-empty-path "$VALID" 'cannot read hooks metadata' @empty

echo "-- B6. a usage error exits 2 and prints the usage (a missing script also exits 2, so the usage line is what counts) --"
# usage_error <label> [args]
usage_error() {
  local label="$1"; shift
  run_validator "$VALIDATOR" "$@"
  if [ "$RC" -ne 2 ]; then bad "$label: exit 2" "exit $RC: $OUT"; return; fi
  case "$OUT" in *"usage: guardrails_manifest.py"*) ok "$label: exit 2 and the usage" ;; *) bad "$label: exit 2 but no usage line" "$OUT" ;; esac
}
usage_error "no arguments"
usage_error "an unknown command" bogus
usage_error "validate without a file" validate

# ---- C. the schema file and the validator state the same format -------------------------------------------------------
echo "-- C. docs/schemas/guardrails.manifest.v1.json and the validator agree --"
CROSS="$("$PY" -I "$WORK/cross.py" "$REPO" 2>&1)"; RC=$?
if [ "$RC" -ne 0 ]; then
  bad "the schema file could be compared with the validator" "exit $RC: $CROSS"
else
  while IFS= read -r line; do
    case "$line" in
      "ok "*)  ok "schema file == validator: ${line#ok }" ;;
      "bad "*) bad "schema file == validator: ${line#bad }" ;;
    esac
  done <<< "$CROSS"
fi

# ---- D. the suite can go RED -----------------------------------------------------------------------------------------
echo "-- D. a one-line break of a copy of the validator turns the cases that pin the rule green-to-red --"
# mutant <label> <old text> <new text> <case>...: break ONE exact line; every named case must then FAIL its assertion
mutant() {
  local label="$1" old="$2" new="$3" name line file reason meta total=0 red=0 alive=""
  shift 3
  if ! "$PY" -I "$WORK/apply.py" "$VALIDATOR" "$MUT/guardrails_manifest.py" "$old" "$new" 2>"$WORK/apply.err"; then
    bad "mutant \"$label\": the validator could not be broken" "$(cat "$WORK/apply.err")"
    return
  fi
  for name in "$@"; do
    line="$(awk -F'\t' -v n="$name" '$1 == n { print; exit }' "$INDEX")"
    if [ -z "$line" ]; then bad "mutant \"$label\": no such case: $name"; return; fi
    IFS=$'\t' read -r _ file reason meta <<< "$line"
    total=$((total + 1))
    if rejects_meta "$MUT/guardrails_manifest.py" "$file" "$reason" "$meta"; then alive="$alive $name"; else red=$((red + 1)); fi
  done
  if [ "$red" -eq "$total" ]; then ok "mutant \"$label\": $total case(s) go red"; else bad "mutant \"$label\": still satisfied by:$alive"; fi
}
# mutant_valid <label> <old text> <new text>: the broken validator must stop accepting the valid fixture
mutant_valid() {
  if ! "$PY" -I "$WORK/apply.py" "$VALIDATOR" "$MUT/guardrails_manifest.py" "$2" "$3" 2>"$WORK/apply.err"; then
    bad "mutant \"$1\": the validator could not be broken" "$(cat "$WORK/apply.err")"
    return
  fi
  if accepts "$MUT/guardrails_manifest.py" "$VALID" --hooks-metadata "$META"; then bad "mutant \"$1\": the valid fixture is still accepted"; else ok "mutant \"$1\": the valid fixture goes red"; fi
}
mutant "no tier enum"               '("kind", KINDS), ("tier", TIERS), ("fails", FAILS)' '("kind", KINDS), ("fails", FAILS)' tier-unknown tier-case tier-list tier-null
mutant "a missing tier is tolerated" 'if key not in row:' 'if key not in row and key != "tier":' tier-missing
mutant "tiers held in a set"        'TIERS = ("core", "recommended")' 'TIERS = {"core", "recommended"}' tier-list
mutant "locked rule gone"           'if hooks[row["id"]] and row.get("tier") in TIERS' 'if False and row.get("tier") in TIERS' locked-recommended
mutant "locked means literal true"  'locked[hook_id] = hook.get("locked") is not False' 'locked[hook_id] = hook.get("locked") is True' meta-locked-string meta-locked-missing
mutant "duplicate ids tolerated"    'if len(indexes) > 1:' 'if len(indexes) > 2:' duplicate-id duplicate-id-conflicting-tiers
mutant "a guard needs no proof"     'if row.get("kind") == "guard" and not _text(proof):' 'if False:' guard-no-proof guard-blank-proof guard-null-proof
mutant "schema 1 compared with =="  'if type(schema) is not int or schema != SCHEMA_VERSION:' 'if schema != SCHEMA_VERSION:' schema-true schema-float
mutant "no hook coverage"           'for hook_id in sorted(set(hooks) - covered):' 'for hook_id in []:' coverage-missing hook-mislabelled
mutant "hook reference unchecked"   'if isinstance(hook, str) and hook not in hooks:' 'if False:' hook-ref-unknown
mutant "hook row need not name itself" 'if row.get("hook") != row["id"]:' 'if False:' hook-row-mismatch
mutant "unknown hook row accepted"  'if row["id"] not in hooks:' 'if False:' hook-row-unknown
mutant "repeated JSON key tolerated" 'if key in found:' 'if False:' dup-key
mutant "deep nesting escapes"       'except (ValueError, RecursionError) as exc:' 'except ValueError as exc:' deep-nesting
mutant "row type unchecked"         'if not isinstance(row, dict):' 'if False:' row-not-object
mutant "an empty --hooks-metadata means none" 'if args.hooks_metadata is not None else None' 'if args.hooks_metadata else None' meta-empty-path
mutant_valid "every row is the hook itself" 'if row.get("layer") == HOOK_LAYER:' 'if True:'

printf '\n  guardrails-manifest-schema: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
