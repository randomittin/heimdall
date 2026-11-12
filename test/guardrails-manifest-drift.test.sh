#!/usr/bin/env bash
#
# guardrails-manifest-drift.test.sh -- guardrails.manifest.json against the tree it describes
# (3.x M1, task T1.3 of docs/superpowers/plans/2026-11-12-3x-m1-skill-registry.md).
#
# guardrails.manifest.json puts every guardrail Heimdall enforces in one of two tiers: `core` (security and correctness
# gates, never switchable by any hmd command or config file) or `recommended` (cost and discipline guards: on by default,
# switchable by the operator). bin/lib/guardrails_manifest.py checks the FILE: its shape, its enums and, given
# hooks/hooks.metadata.json, that locked hooks are core and every hook has a row. This suite checks what no validator can see
# from the file alone: that the file still describes the tree.
#
#   A. the real manifest. The validator accepts it WITH --hooks-metadata, and every drift check is green:
#        hook-coverage           every hooks.metadata.json hook has exactly one row with layer hook, and no such row names an
#                                unknown hook: a hook added without a decision fails here until someone classifies it
#        locked-core             a hook row is core exactly when its hook is locked (a locked hook marked recommended would be
#                                switchable; a core row for an unlocked hook would be a promise `hmd hooks disable` breaks)
#        core-floor              at least 8 core rows
#        sub-guard-tiers         the nine cost and discipline guards inside the two precheck hooks are the ONLY non-hook rows
#                                that may be recommended (the table in drift.py below: the decisions of record), each stating
#                                its override; every other row is core, because anything not positively classified is core.
#                                The validator lets a guard inside a locked hook be recommended, so without this check a push
#                                gate could be flipped to optional and nothing would fail. The provisional rows (plan open
#                                decision O5) are exactly three.
#        operator-env-in-script  every operator_env variable appears in the code that honours it: the layer's script, or the
#                                command and scripts the hook's own entry in hooks/hooks.json runs
#        proof-exists            every proof is a file inside the repository
#        container-hook          a precheck-bash or precheck-agent row names the hook whose command runs that script
#   B. every defect, applied ALONE to a copy of the manifest or of the hooks metadata, turns the check that owns it red; and
#      the validator, run with --hooks-metadata, refuses a locked hook marked recommended.
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export REPO
MANIFEST="$REPO/guardrails.manifest.json"
META="$REPO/hooks/hooks.metadata.json"
HOOKS="$REPO/hooks/hooks.json"
VALIDATOR="$REPO/bin/lib/guardrails_manifest.py"
PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; if [ -n "${2:-}" ]; then printf '       %s\n' "$2"; fi; }
finish() { printf '\n  guardrails-manifest-drift: %d passed, %d failed\n' "$PASS" "$FAIL"; [ "$FAIL" -eq 0 ]; }

PY="$(command -v python3 || true)"
[ -n "$PY" ] || { echo "FATAL: python3 not found"; exit 2; }
# the interpreter itself, not a version-manager shim: a shim costs ~0.4 s a call and this suite starts python ~50 times
PY="$("$PY" -c 'import sys; print(sys.executable)')" && [ -n "$PY" ] || { echo "FATAL: cannot resolve python3"; exit 2; }

WORK="$(mktemp -d)" || exit 2
trap 'rm -rf "$WORK"' EXIT
MUT="$WORK/mut"
mkdir -p "$MUT"

# the drift checker: reads a manifest, a hooks metadata file, hooks.json and the repository; prints `ok <check>` or
# `FAIL <check>: <reason>` per check and exits 1 if any check failed. Files, not heredocs inside command substitutions.
cat > "$WORK/drift.py" <<'EOF'
import json
import os
import re
import sys

manifest_path, meta_path, hooks_path, repo = sys.argv[1:5]

# The cost and discipline guards that live INSIDE the two locked precheck hooks and are recommended, each with the
# operator_env its row must state (docs/superpowers/plans/2026-11-12-3x-m1-skill-registry.md, "Stage 0" D2, plus the wait guard
# and the general-purpose agent rules that landed after it). Every other row that is not a hook is core.
RECOMMENDED = {
    "ci-waste-guard": "HMD_CI_RERUN_ALLOW=1",
    "disk-floor": "HMD_MIN_FREE_PCT=0",
    "sweep-guard": "HMD_SWEEP_ALLOW=1",
    "wait-guard": "HMD_WAIT_ALLOW=1",
    "parallelism-check-bash": None,
    "named-agent-notice": "HEIMDALL_ALLOW_NAMED_AGENT=1",
    "context-gate": "HMD_CTX_GATE_OFF=1",
    "fix-chain-advisory": "HMD_FIX_CHAIN_ALLOW=1",
    "gp-agent-rules": "HMD_GP_RULES_OFF=1",
}
# core only because nobody has classified them yet (plan open decision O5): the rows flagged provisional are exactly these
PROVISIONAL = {"agent-concurrency-cap", "adjudication-fallback-fence", "coop-native-spawn-refusal"}
# a row's layer names the script that enforces it and the hook whose command runs that script
LAYERS = {
    "precheck-bash": ("bin/heimdall-precheck-bash", "bash-gate-chain"),
    "precheck-agent": ("bin/heimdall-precheck-agent", "agent-precheck"),
    "native-git-hook": ("bin/heimdall-init", None),
}
CORE_FLOOR = 8


def load(path, what):
    try:
        with open(path, encoding="utf-8") as handle:
            return json.load(handle)
    except (OSError, ValueError) as exc:
        print("FAIL load: cannot read %s %s: %s" % (what, path, exc))
        sys.exit(1)


manifest = load(manifest_path, "manifest")
rows = [row for row in (manifest.get("guardrails") or []) if isinstance(row, dict)] if isinstance(manifest, dict) else []
meta = {hook["id"]: hook for hook in load(meta_path, "hooks metadata").get("hooks", []) if isinstance(hook, dict) and "id" in hook}
hooks_doc = load(hooks_path, "hooks.json").get("hooks", {})


def text_of(rel):
    try:
        with open(os.path.join(repo, rel), encoding="utf-8", errors="replace") as handle:
            return handle.read()
    except OSError:
        return None


def hook_command(hook_id):
    """The command text of the hooks.json entry that hooks.metadata.json says is `hook_id`, or None."""
    try:
        group = hooks_doc[meta[hook_id]["event"]][meta[hook_id]["index"]]
        return "\n".join(item.get("command", "") for item in group["hooks"])
    except (KeyError, IndexError, TypeError):
        return None


def hook_coverage():
    out = []
    by_id = {}
    for row in rows:
        if row.get("layer") == "hook":
            by_id.setdefault(row.get("id"), []).append(row)
    for hook_id in meta:
        count = len(by_id.get(hook_id, []))
        if count != 1:
            out.append("hook %r has %d rows with layer hook, needs exactly 1 (a new hook is unclassified until it has a row)" % (hook_id, count))
    for hook_id in by_id:
        if hook_id not in meta:
            out.append("row %r has layer hook but hooks.metadata.json has no such hook" % (hook_id,))
    return out


def locked_core():
    out = []
    for row in rows:
        hook_id = row.get("id")
        if row.get("layer") != "hook" or hook_id not in meta:
            continue
        locked = meta[hook_id].get("locked") is not False
        core = row.get("tier") == "core"
        if locked and not core:
            out.append("hook %r is locked, so its row must be core, not %r" % (hook_id, row.get("tier")))
        if core and not locked:
            out.append("hook %r is core but not locked: `hmd hooks disable` can switch it off, and core is never switchable" % (hook_id,))
    return out


def core_floor():
    count = sum(1 for row in rows if row.get("tier") == "core")
    return [] if count >= CORE_FLOOR else ["%d core rows, needs at least %d" % (count, CORE_FLOOR)]


def sub_guard_tiers():
    out = []
    for row in rows:
        row_id = row.get("id")
        if row.get("layer") == "hook":
            continue
        if row_id in RECOMMENDED:
            if row.get("tier") != "recommended":
                out.append("%r must stay recommended (the decision of record), got %r" % (row_id, row.get("tier")))
            if row.get("operator_env") != RECOMMENDED[row_id]:
                out.append("%r must state operator_env %r, got %r" % (row_id, RECOMMENDED[row_id], row.get("operator_env")))
        elif row.get("tier") != "core":
            out.append("%r is not a hook and not in the recommended table, so it must be core (anything not positively classified is core), got %r" % (row_id, row.get("tier")))
    for row_id in sorted(set(RECOMMENDED) - {row.get("id") for row in rows}):
        out.append("recommended guard %r has no row" % (row_id,))
    provisional = {row.get("id") for row in rows if row.get("provisional") is True}
    if provisional != PROVISIONAL:
        out.append("provisional rows must be exactly %s, got %s" % (sorted(PROVISIONAL), sorted(provisional)))
    return out


def env_in_script():
    out = []
    for row in rows:
        env = row.get("operator_env")
        if env is None:
            continue
        name = env.split("=", 1)[0]
        pattern = re.compile(r"(?<![A-Za-z0-9_])" + re.escape(name) + r"(?![A-Za-z0-9_])")
        layer, row_id = row.get("layer"), row.get("id")
        if layer == "hook":
            command = hook_command(row_id)
            if command is None:
                out.append("%r: hooks.json has no entry for hook %r" % (row_id, row_id))
                continue
            scope = {"the command of hook %s in hooks.json" % row_id: command}
            for rel in sorted(set(re.findall(r"(?:bin|hooks|sentinels)/[A-Za-z0-9._-]+", command))):
                text = text_of(rel)
                if text is not None:
                    scope[rel] = text
        elif layer in LAYERS:
            scope = {LAYERS[layer][0]: text_of(LAYERS[layer][0]) or ""}
        else:
            out.append("%r: no script is known for layer %r, so %s cannot be checked: add the layer to LAYERS" % (row_id, layer, name))
            continue
        if not any(pattern.search(text) for text in scope.values()):
            out.append("%r: operator_env variable %s appears in none of: %s" % (row_id, name, ", ".join(sorted(scope))))
    return out


def proof_exists():
    out = []
    for row in rows:
        proof = row.get("proof")
        if proof is None:
            continue
        if not isinstance(proof, str) or proof.startswith("/") or ".." in proof.split("/"):
            out.append("%r: proof %r must be a path inside the repository (relative, no ..)" % (row.get("id"), proof))
        elif not os.path.isfile(os.path.join(repo, proof)):
            out.append("%r: proof %s is not a file in the repository" % (row.get("id"), proof))
    return out


def container_hook():
    out = []
    for row in rows:
        layer = row.get("layer")
        if layer in LAYERS and LAYERS[layer][1] is not None and row.get("hook") != LAYERS[layer][1]:
            out.append("%r: layer %s runs inside hook %r, the row says %r" % (row.get("id"), layer, LAYERS[layer][1], row.get("hook")))
    for layer, (script, container) in sorted(LAYERS.items()):
        if container is None:
            continue
        command = hook_command(container)
        if command is None or os.path.basename(script) not in command:
            out.append("hook %r does not run %s" % (container, script))
    return out


CHECKS = [
    ("hook-coverage", hook_coverage),
    ("locked-core", locked_core),
    ("core-floor", core_floor),
    ("sub-guard-tiers", sub_guard_tiers),
    ("operator-env-in-script", env_in_script),
    ("proof-exists", proof_exists),
    ("container-hook", container_hook),
]
failed = False
for name, check in CHECKS:
    problems = check()
    if problems:
        failed = True
        for problem in problems:
            print("FAIL %s: %s" % (name, problem))
    else:
        print("ok %s" % name)
sys.exit(1 if failed else 0)
EOF
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

drift() { "$PY" -I "$WORK/drift.py" "$1" "$2" "$HOOKS" "$REPO"; }

# ---- A. the real manifest ---------------------------------------------------------------------------------------------
if [ ! -f "$MANIFEST" ]; then
  bad "guardrails.manifest.json does not exist at the repository root"
  finish
  exit
fi

VOUT="$("$PY" -I "$VALIDATOR" validate "$MANIFEST" --hooks-metadata "$META" 2>"$WORK/validator.err")"
VRC=$?
if [ "$VRC" -eq 0 ] && grep -Eq '^ok guardrails\.manifest/1 \([0-9]+ guardrails\)$' <<<"$VOUT" && ! grep -q 'no --hooks-metadata' "$WORK/validator.err"; then
  ok "the validator accepts the manifest with --hooks-metadata: $VOUT"
else
  bad "the validator does not accept the manifest with --hooks-metadata (exit $VRC)" "$VOUT $(cat "$WORK/validator.err")"
fi

OUT="$(drift "$MANIFEST" "$META" 2>&1)"
RC=$?
while IFS= read -r line; do
  case "$line" in
    "ok "*) ok "${line#ok }" ;;
    "FAIL "*) bad "${line#FAIL }" ;;
    *) bad "$line" ;;
  esac
done <<<"$OUT"
if [ "$RC" -ne 0 ] && ! grep -q '^FAIL ' <<<"$OUT"; then bad "the drift checker exited $RC without naming a failed check" "$OUT"; fi

# ---- B. each defect, alone, turns its check red -------------------------------------------------------------------------
# red <name> <check that must go red> <python for a copy of the manifest, or ''> [<python for a copy of the hooks metadata>]
red() {
  local name="$1" check="$2" mcode="$3" hcode="${4:-}" m="$MUT/manifest.json" h="$MUT/hooks.metadata.json" out rc
  cp "$MANIFEST" "$m"
  cp "$META" "$h"
  if [ -n "$mcode" ] && ! "$PY" -I "$WORK/mutate.py" "$MANIFEST" "$m" "$mcode" 2>"$WORK/mutate.err"; then
    bad "mutant \"$name\": the manifest copy could not be mutated" "$(cat "$WORK/mutate.err")"
    return
  fi
  if [ -n "$hcode" ] && ! "$PY" -I "$WORK/mutate.py" "$META" "$h" "$hcode" 2>"$WORK/mutate.err"; then
    bad "mutant \"$name\": the hooks metadata copy could not be mutated" "$(cat "$WORK/mutate.err")"
    return
  fi
  out="$(drift "$m" "$h" 2>&1)"
  rc=$?
  if [ "$rc" -ne 0 ] && grep -q "^FAIL $check:" <<<"$out"; then
    ok "mutant \"$name\": $check goes red"
  else
    bad "mutant \"$name\": $check did not go red (exit $rc)" "$out"
  fi
}

NEW_GUARD='d["guardrails"].append({"id": "new-guard", "kind": "guard", "tier": "recommended", "layer": "precheck-bash", "hook": "bash-gate-chain", "fails": "open", "operator_env": None, "proof": "test/ci-waste-guard.test.sh", "why": "x"})'
GHOST_HOOK='d["guardrails"].append({"id": "ghost-hook", "kind": "feature", "tier": "recommended", "layer": "hook", "hook": "ghost-hook", "why": "x"})'
NEW_HOOK='d["hooks"].append({"event": "Stop", "index": 99, "id": "brand-new-hook", "locked": False, "remote_toggle": False})'

red "a hook without a row"                            hook-coverage          'd["guardrails"] = [x for x in d["guardrails"] if x["id"] != "stop-lint"]'
red "a new hook nobody classified"                    hook-coverage          '' "$NEW_HOOK"
red "a row for a hook that does not exist"            hook-coverage          "$GHOST_HOOK"
red "a locked hook marked recommended"                locked-core            'r("secret-read-guard")["tier"] = "recommended"'
red "an unlocked hook marked core"                    locked-core            'r("stop-lint")["tier"] = "core"'
red "a core hook unlocked in the metadata"            locked-core            '' 'r("stub-gate")["locked"] = False'
red "every row recommended"                           core-floor             'for x in d["guardrails"]: x["tier"] = "recommended"'
red "a push gate marked recommended"                  sub-guard-tiers        'r("push-secret-scan")["tier"] = "recommended"'
red "a spawn fence marked recommended"                sub-guard-tiers        'r("adjudication-fallback-fence")["tier"] = "recommended"'
red "an unclassified guard marked recommended"        sub-guard-tiers        "$NEW_GUARD"
red "a recommended guard marked core"                 sub-guard-tiers        'r("wait-guard")["tier"] = "core"'
red "a recommended guard's override renamed"          sub-guard-tiers        'r("gp-agent-rules")["operator_env"] = "HMD_GP_RULES_ON=1"'
red "a recommended guard's row removed"               sub-guard-tiers        'd["guardrails"] = [x for x in d["guardrails"] if x["id"] != "gp-agent-rules"]'
red "a provisional mark dropped"                      sub-guard-tiers        'del r("coop-native-spawn-refusal")["provisional"]'
red "an override no code honours"                     operator-env-in-script 'r("wait-guard")["operator_env"] = "HMD_WAIT_ELSEWHERE=1"'
red "an override honoured by another layer's script"  operator-env-in-script 'r("ci-waste-guard")["operator_env"] = "HMD_GP_RULES_OFF=1"'
red "an override missing from the hook's command"     operator-env-in-script 'r("stub-gate")["operator_env"] = "HMD_PHONE_DENY=0"'
red "an override that only prefixes a real one"       operator-env-in-script 'r("wait-guard")["operator_env"] = "HMD_WAIT_ALLO=1"'
red "a row in a layer no script is known for"         operator-env-in-script 'r("kill-guard")["layer"] = "mystery-layer"'
red "a hook entry hooks.json no longer has"           operator-env-in-script '' 'r("lintconfig-guard")["index"] = 99'
red "a proof that does not exist"                     proof-exists           'r("ci-waste-guard")["proof"] = "test/no-such-suite.test.sh"'
red "a proof that climbs out with .."                 proof-exists           'r("ci-waste-guard")["proof"] = "test/../test/ci-waste-guard.test.sh"'
red "an absolute proof path"                          proof-exists           'r("ci-waste-guard")["proof"] = __import__("os").environ["REPO"] + "/test/ci-waste-guard.test.sh"'
red "a guard inside the wrong hook"                   container-hook         'r("named-agent-notice")["hook"] = "bash-gate-chain"'
red "a container hook that no longer runs its script" container-hook         '' 'r("bash-gate-chain")["index"] = 1'

# the validator, run WITH --hooks-metadata, is the other half of "a locked hook is core": drop the flag and this mutant passes
cp "$MANIFEST" "$MUT/manifest.json"
if "$PY" -I "$WORK/mutate.py" "$MANIFEST" "$MUT/manifest.json" 'r("secret-read-guard")["tier"] = "recommended"' 2>"$WORK/mutate.err"; then
  VOUT="$("$PY" -I "$VALIDATOR" validate "$MUT/manifest.json" --hooks-metadata "$META" 2>&1)"
  VRC=$?
  if [ "$VRC" -eq 1 ] && grep -q 'tier must be core' <<<"$VOUT"; then
    ok "mutant \"a locked hook marked recommended\": the validator, run with --hooks-metadata, refuses it"
  else
    bad "mutant \"a locked hook marked recommended\": the validator did not refuse it (exit $VRC)" "$VOUT"
  fi
else
  bad "mutant \"a locked hook marked recommended\": the manifest copy could not be mutated" "$(cat "$WORK/mutate.err")"
fi

finish
