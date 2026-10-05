#!/usr/bin/env bash
# run.sh — `attack` oracle gate, structured-contract front end (spec 2A).
#
# THE QUESTION. "Can I break this?" (RP1). The graded subject (--input) is a settlement
# webhook — a module exporting `createWebhook({ store })` — or a directory that declares
# one in runhmd.attack.json. The gate replays an adversarial battery against it
# (duplicate / retried deliveries on a virtual clock, IDOR reads, rounding boundaries) and
# compares what the target did with an INDEPENDENT reference model
# (reference/settlement.ref.mjs, derived from INVARIANTS.md). A target no attack can
# break is PROVEN (status pass); one a single attack breaks is DENIED (status fail), with
# the minimal counterexample.
#
# run.sh is the SINGLE source of verdict truth. `hmd attack` (bin/heimdall-attack) and
# `bin/falsify attack` both consume the report.json written here — neither re-derives it.
#
#   report.json = {                                   # spec H-1 — 8 fixed fields
#     "gate_id": "attack",
#     "status":  "pass" | "fail" | "error",
#     "first_divergence": { file, step, expected, actual } | null,   # step = attack id
#     "metrics": {                                    # attack-specific, open-keyed
#        profile, suite,
#        attacks:  { total, survived, killed },
#        cases:    [ { id, class, status } ... ],
#        findings: [ { key, title, severity, category, attacks[], counterexample{...},
#                      evidence[] } ... ]             # one per root cause, not per attack
#     },
#     "fix_hint": string, "haid": string, "wave": string|null, "ts": string
#   }
#   status "error" (exit 2): no verdict could be produced; metrics.error_kind says why
#   (no_attack_surface | bad_manifest | too_large | watchdog | infra).
#
# ISOLATION. The target is copied into a private temp dir and run there, in a scrubbed
# environment (env -i: no inherited secrets), HOME and TMPDIR inside the temp dir, under a
# wall-clock watchdog. Where node has a permission model it is enabled so the target can
# read only the engine and its own copy and write only to the result dir (no writes
# outside the temp dir, no child processes). The caller's tree is never written to.
# Limits: the target runs IN-PROCESS with the battery, so a target that deliberately
# subverts the harness can forge a result — attack is built for buggy AI-written code,
# not hostile code — and the network is not blocked by node's permission model.
#
# Usage:
#   run.sh [--input <module.mjs | dir>] [--report <out>]
#     --input   subject. Default: fixtures/golden/target.mjs. A directory must contain
#               runhmd.attack.json: {"schema":"runhmd.attack-target/1",
#               "profile":"settlement-webhook/1","module":"<relative .mjs path>"}
#     --report  where to WRITE report.json. Default: <gate dir>/report.json
#   Env: RUNHMD_ATTACK_TIMEOUT_S (default 60), RUNHMD_ATTACK_MAX_FILES (2000),
#        RUNHMD_ATTACK_MAX_KB (20480) — caps on the copied target directory.
#
# Exit: 0 pass (PROVEN), 1 fail (DENIED), 2 no verdict possible (usage / unusable target /
# infrastructure) — consumers must treat 2 as "no usable verdict", never as pass.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
GATE_ID="attack"
PROFILE="settlement-webhook/1"
INPUT="$HERE/fixtures/golden/target.mjs"
REPORT="$HERE/report.json"
TIMEOUT_S="${RUNHMD_ATTACK_TIMEOUT_S:-60}"
MAX_FILES="${RUNHMD_ATTACK_MAX_FILES:-2000}"
MAX_KB="${RUNHMD_ATTACK_MAX_KB:-20480}"

die() { printf 'run.sh: %s\n' "$*" >&2; exit 2; }

command -v jq   >/dev/null 2>&1 || die "jq is required to emit report.json"
command -v node >/dev/null 2>&1 || die "node is required to run the attack battery"
NODE_BIN="$(command -v node)"

while [ "$#" -gt 0 ]; do
  case "$1" in
    --input)  INPUT="${2:?--input needs a path}";   shift 2 ;;
    --report) REPORT="${2:?--report needs a path}"; shift 2 ;;
    -h|--help) sed -n '2,60p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) die "unknown arg: $1 (see --help)" ;;
  esac
done
case "$TIMEOUT_S$MAX_FILES$MAX_KB" in *[!0-9]*|'') die "RUNHMD_ATTACK_* limits must be positive integers" ;; esac

HAID="${HEIMDALL_HAID:-haid:local}"
WAVE="${HEIMDALL_WAVE:-}"
mkdir -p "$(dirname "$REPORT")"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/runhmd-attack.XXXXXX")"
WORK="$(cd "$WORK" && pwd -P)"
trap 'rm -rf "$WORK"' EXIT
SANDBOX="$WORK/sandbox"; OUT="$WORK/out"; mkdir -p "$SANDBOX" "$OUT" "$WORK/home" "$WORK/tmp"

# write_report <json-on-stdin>: atomic write of the typed report
write_report() {
  local tmp; tmp="$(mktemp "$WORK/report.XXXXXX")"
  cat >"$tmp"
  mv "$tmp" "$REPORT"
}

# emit_error <kind> <detail>: no verdict possible. status "error", exit 2.
emit_error() {
  local kind="$1" detail="$2"
  jq -n --arg gate_id "$GATE_ID" --arg kind "$kind" --arg detail "$detail" \
        --arg haid "$HAID" --arg wave "$WAVE" --arg ts "$(date -u +%FT%TZ)" \
    '{gate_id:$gate_id, status:"error",
      first_divergence:{file:$gate_id, step:$kind, expected:"a target the attack battery can run", actual:$detail},
      metrics:{error_kind:$kind, profile:"'"$PROFILE"'"},
      fix_hint:$detail, haid:$haid, wave:(if $wave=="" then null else $wave end), ts:$ts}' | write_report
  printf '%s: error (%s): %s -> %s\n' "$GATE_ID" "$kind" "$detail" "$REPORT" >&2
  exit 2
}

[ -e "$INPUT" ] || emit_error no_attack_surface "target not found: $INPUT"

# ── resolve the target into the sandbox ───────────────────────────────────────────────
if [ -d "$INPUT" ]; then
  MANIFEST="$INPUT/runhmd.attack.json"
  [ -f "$MANIFEST" ] || emit_error no_attack_surface "no runhmd.attack.json in $INPUT: nothing declares an attack surface here, so there is nothing to attack (a verdict over nothing would be a false green)"
  jq -e 'type=="object"' "$MANIFEST" >/dev/null 2>&1 || emit_error bad_manifest "runhmd.attack.json is not a JSON object"
  m_schema="$(jq -r '.schema // empty' "$MANIFEST")"
  m_profile="$(jq -r '.profile // empty' "$MANIFEST")"
  m_module="$(jq -r '.module // empty' "$MANIFEST")"
  [ "$m_schema" = "runhmd.attack-target/1" ] || emit_error bad_manifest "runhmd.attack.json: schema must be runhmd.attack-target/1 (got '${m_schema}')"
  [ "$m_profile" = "$PROFILE" ] || emit_error bad_manifest "runhmd.attack.json: unknown profile '${m_profile}' (this build attacks: $PROFILE)"
  case "$m_module" in
    ''|/*|../*|*/../*|*/..|..) emit_error bad_manifest "runhmd.attack.json: module must be a relative path inside the target directory" ;;
    *.mjs) ;;
    *) emit_error bad_manifest "runhmd.attack.json: module must be an ES module (.mjs)" ;;
  esac
  [ -f "$INPUT/$m_module" ] || emit_error bad_manifest "runhmd.attack.json: module '$m_module' does not exist in the target directory"

  n_files="$(find "$INPUT" \( -name .git -o -name node_modules \) -prune -o -type f -print | wc -l | tr -d ' ')"
  [ "$n_files" -le "$MAX_FILES" ] || emit_error too_large "target has $n_files files (cap $MAX_FILES): point runhmd.attack.json at a smaller directory"
  size_kb="$(find "$INPUT" \( -name .git -o -name node_modules \) -prune -o -type f -exec du -k {} + | awk '{s+=$1} END {print s+0}')"
  [ "$size_kb" -le "$MAX_KB" ] || emit_error too_large "target is ${size_kb} KB (cap ${MAX_KB} KB): point runhmd.attack.json at a smaller directory"

  (cd "$INPUT" && tar -cf - --exclude=.git --exclude=node_modules .) | (cd "$SANDBOX" && tar -xf -)
  find "$SANDBOX" -type l -delete   # a symlink must never lead the target out of its copy
  TARGET="$SANDBOX/$m_module"
else
  cp "$INPUT" "$SANDBOX/target.mjs"
  TARGET="$SANDBOX/target.mjs"
fi

# ── run the battery, isolated ─────────────────────────────────────────────────────────
NODE_FLAGS=()
for flag in --permission --experimental-permission; do
  if "$NODE_BIN" "$flag" -e 0 >/dev/null 2>&1; then
    NODE_FLAGS=("$flag" "--allow-fs-read=$HERE" "--allow-fs-read=$SANDBOX" "--allow-fs-write=$OUT")
    break
  fi
done

# bounded <seconds> <cmd...>: SIGALRM from perl (macOS ships no timeout(1)), else timeout(1)
bounded() {
  local secs="$1"; shift
  if command -v perl >/dev/null 2>&1; then perl -e 'alarm shift; exec @ARGV' "$secs" "$@"
  elif command -v timeout >/dev/null 2>&1; then timeout "$secs" "$@"
  else "$@"; fi
}

rc=0
(cd "$SANDBOX" && bounded "$TIMEOUT_S" env -i PATH="$PATH" HOME="$WORK/home" TMPDIR="$WORK/tmp" LANG=C \
   "$NODE_BIN" ${NODE_FLAGS[@]+"${NODE_FLAGS[@]}"} "$HERE/grade.mjs" "$TARGET" "$OUT/result.json") \
   >"$WORK/node.stdout" 2>"$WORK/node.stderr" || rc=$?

if [ "$rc" -eq 142 ] || [ "$rc" -eq 124 ]; then
  emit_error watchdog "the target did not finish within ${TIMEOUT_S}s (a handler that never returns is not proven, so there is no verdict)"
fi
if [ "$rc" -ne 0 ] || ! jq -e 'type=="object"' "$OUT/result.json" >/dev/null 2>&1; then
  emit_error infra "the attack engine failed (exit $rc): $(tail -n 3 "$WORK/node.stderr" | tr '\n' ' ' | cut -c1-400)"
fi

# ── fold the raw battery result into the typed report ─────────────────────────────────
jq -n --slurpfile res "$OUT/result.json" --arg gate_id "$GATE_ID" \
      --arg haid "$HAID" --arg wave "$WAVE" --arg ts "$(date -u +%FT%TZ)" '
  def hint($r):
    if ($r.attacks.killed // 0) == 0
    then "Target survived all \($r.attacks.total) attack(s) of \($r.suite) — it did not diverge from the independent reference model on any duplicate delivery, IDOR read or rounding boundary."
    else "\($r.attacks.killed) of \($r.attacks.total) attack(s) broke the target: \($r.findings | map(.title) | join("; ")). Each finding carries a minimal counterexample; fix the defect and re-run."
    end;
  $res[0] as $r
  | if $r.load_error then
      {gate_id:$gate_id, status:"fail",
       first_divergence:{file:$gate_id, step:"module load",
                         expected:"an importable ES module exporting createWebhook({ store })", actual:$r.load_error},
       metrics:{profile:$r.profile, suite:$r.suite,
                attacks:{total:1, survived:0, killed:1},
                cases:[{id:"load", class:"load", status:"killed"}],
                findings:[{key:"load", title:"target module cannot be loaded", severity:"high", category:"regression",
                           attacks:["load"],
                           counterexample:{attack_id:"load", summary:$r.load_error, minimal_input:""},
                           evidence:[{attack_id:"load", title:"import the target module", aspect:"module load",
                                      expected:"an importable ES module exporting createWebhook({ store })",
                                      actual:$r.load_error, scenario:null}]}]},
       fix_hint:("The target cannot be attacked because it does not load: " + $r.load_error),
       haid:$haid, wave:(if $wave=="" then null else $wave end), ts:$ts}
    else
      {gate_id:$gate_id,
       status:(if $r.attacks.killed == 0 then "pass" else "fail" end),
       first_divergence:(if $r.first_divergence
                         then {file:$gate_id, step:$r.first_divergence.attack_id,
                               expected:$r.first_divergence.expected, actual:$r.first_divergence.actual}
                         else null end),
       metrics:{profile:$r.profile, suite:$r.suite, attacks:$r.attacks, cases:$r.cases, findings:$r.findings},
       fix_hint:hint($r), haid:$haid, wave:(if $wave=="" then null else $wave end), ts:$ts}
    end' | write_report

status="$(jq -r '.status' "$REPORT")"
printf '%s: %s (%s of %s attack(s) killed the target) -> %s\n' "$GATE_ID" "$status" \
  "$(jq -r '.metrics.attacks.killed' "$REPORT")" "$(jq -r '.metrics.attacks.total' "$REPORT")" "$REPORT" >&2

[ "$status" = "pass" ] && exit 0 || exit 1
