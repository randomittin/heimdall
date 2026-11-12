#!/usr/bin/env bash
# guardrail-off-agent.test.sh -- the operator switches for the RECOMMENDED guards of bin/heimdall-precheck-agent (T6.2, docs/superpowers/plans/2026-11-12-3x-m1-skill-registry.md).
#
# Five guards in the Agent hook ask bin/lib/hmd_guardrail_enabled.sh before they act, next to the env override each one already honours: the disk floor fence (disk-floor), the
# named-agent notice (named-agent-notice), the context gate (context-gate), the fix-chain advisory (fix-chain-advisory) and the general-purpose agent rules (gp-agent-rules). Four are
# core and never ask: the in-process concurrency cap (agent-concurrency-cap), the adjudication fallback fence (adjudication-fallback-fence), the coop native-spawn refusal
# (coop-native-spawn-refusal) and the brief-adoption gate (brief-adoption-gate).
#
# Each of the nine has one canonical trigger, a spawn it acts on, fired alone, so a run shows that one guard and nothing else. The matrix:
#   INV-G2  no guardrails-off file: all nine act, as before the switches existed.
#   INV-G3  one recommended id in the file: that trigger goes through untouched and silent (the fix-chain one writes no counter either); the other eight still act.
#   INV-G1  every core id of the manifest in the file: all nine act. Every id of the manifest in the file: the five recommended are silent, the four core still enforce.
#   INV-G5  the switch fails open: with every id in the file, a hook with no switch lib beside it, and one whose lib answers neither 0 nor 1, still runs all nine.
# Static: the hook parses; it asks about exactly these five ids, each recommended in guardrails.manifest.json, and every recommended Agent-hook row of the manifest is one of
# them; the four core fences are core there; the security line `unset TOOL_INPUT SATYPE` still stands ahead of allow().
#
# Hermetic: each throwaway plugin root holds a byte copy of the hook, the libs it sources, the real manifest, and fakes for heimdall-ctx-meter, heimdall-fallback and heimdall-brief;
# a fake df comes first on PATH; every run is under env -i with its own HOME/HEIMDALL_HOME, from a scratch cwd. No network, no real spawns. bash 3.2 compatible.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/.." && pwd)"
REAL_HOOK="$REPO/bin/heimdall-precheck-agent"
MANIFEST="$REPO/guardrails.manifest.json"
BASH_ABS="$(command -v bash)"

command -v jq >/dev/null 2>&1 || { echo "FATAL: jq required" >&2; exit 2; }
for f in "$REAL_HOOK" "$MANIFEST" "$REPO/bin/lib/hmd_guardrail_enabled.sh" "$REPO/bin/lib/hmd_disk_floor.sh" "$REPO/bin/lib/hmd_fix_chain.sh" "$REPO/bin/lib/hmd-adjudication-set.sh"; do
  [ -f "$f" ] || { echo "FATAL: missing $f" >&2; exit 2; }
done

T="$(mktemp -d "${TMPDIR:-/tmp}/guardrail-off-agent.XXXXXX")"
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/cwd" "$T/acwd" "$T/tmp" "$T/dfshim" "$T/homes"

PASS=0
FAIL=0
ok()  { PASS=$((PASS+1)); printf '  \033[32mPASS\033[0m %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  \033[31mFAIL\033[0m %s\n' "$1"; }

REC="disk-floor named-agent-notice context-gate fix-chain-advisory gp-agent-rules"
CORE="agent-concurrency-cap adjudication-fallback-fence coop-native-spawn-refusal brief-adoption-gate"

echo "guardrail-off-agent (operator switches for the recommended guards of the Agent hook)"
echo "--------------------------------------------------------------------"

# ── 0. static ──────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
if bash -n "$REAL_HOOK" 2>/dev/null; then ok "bin/heimdall-precheck-agent parses (bash -n)"; else bad "bin/heimdall-precheck-agent fails bash -n"; fi
ASKED="$(grep -v '^[[:space:]]*#' "$REAL_HOOK" | grep -oE 'guardrail_off [a-z0-9-]+' | awk '{print $2}' | sort -u | tr '\n' ' ')"
WANT="$(printf '%s\n' $REC | sort -u | tr '\n' ' ')"
if [ "$ASKED" = "$WANT" ]; then ok "the hook asks guardrail_off about exactly the five: $WANT"; else bad "the hook asks guardrail_off about [$ASKED], want [$WANT]"; fi
TIER_BAD=""
for id in $REC; do jq -e --arg id "$id" '[.guardrails[] | select(.id == $id)] | length == 1 and .[0].tier == "recommended"' "$MANIFEST" >/dev/null 2>&1 || TIER_BAD="$TIER_BAD [$id not recommended]"; done
for id in $CORE; do jq -e --arg id "$id" '[.guardrails[] | select(.id == $id)] | length == 1 and .[0].tier == "core"' "$MANIFEST" >/dev/null 2>&1 || TIER_BAD="$TIER_BAD [$id not core]"; done
if [ -z "$TIER_BAD" ]; then ok "guardrails.manifest.json: the five are recommended (one row each), the four fences are core"; else bad "manifest tiers:$TIER_BAD"; fi
MAN_AGENT_REC="$(jq -r '.guardrails[] | select(.hook == "agent-precheck" and .tier == "recommended") | .id' "$MANIFEST" | sort -u | tr '\n' ' ')"
WANT_AGENT_REC="$(printf '%s\n' named-agent-notice context-gate fix-chain-advisory gp-agent-rules | sort -u | tr '\n' ' ')"
if [ "$MAN_AGENT_REC" = "$WANT_AGENT_REC" ]; then ok "every recommended row of the agent-precheck hook in the manifest has its switch here (disk-floor's row lives under the Bash hook)"; else bad "recommended agent-precheck rows [$MAN_AGENT_REC], switched here [$WANT_AGENT_REC]"; fi
UNSET_LN="$(grep -nx 'unset TOOL_INPUT SATYPE' "$REAL_HOOK" | head -1 | cut -d: -f1)"
ALLOW_LN="$(grep -nx 'allow() {' "$REAL_HOOK" | head -1 | cut -d: -f1)"
if [ -n "$UNSET_LN" ] && [ -n "$ALLOW_LN" ] && [ "$UNSET_LN" -lt "$ALLOW_LN" ]; then ok "the security line 'unset TOOL_INPUT SATYPE' still stands ahead of allow()"; else bad "'unset TOOL_INPUT SATYPE' is gone or no longer ahead of allow() (unset at ${UNSET_LN:-none}, allow at ${ALLOW_LN:-none})"; fi

# ── the sandbox ────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
# Fake `df -Pk PATH`: a 100 GB volume with SHIM_DF_FREE_KB free (default 50 GB, well over the 10% floor).
cat > "$T/dfshim/df" <<'EOF'
#!/bin/sh
printf 'Filesystem 1024-blocks Used Available Capacity Mounted on\n/dev/fake 104857600 1 %s 1%% /fake\n' "${SHIM_DF_FREE_KB:-52428800}"
EOF
chmod +x "$T/dfshim/df"

# mkroot <dir> <real|missing|answers2>: a throwaway plugin root. The hook, its three other libs and the real manifest are copies; the switch lib is the real one, absent, or one whose
# function answers 2 (neither "enabled" nor "switched off"). Fakes stand in for the binaries the fences call:
#   heimdall-ctx-meter  answers `gate [--session S] --json`: FAKE_CTXMETER=refuse is a clean refuse (exit 1), anything else is ok (exit 0)
#   heimdall-fallback   with FAKE_COOP=1, `where` names <root>/coop.json (state coop) and `check --role R` is ROUTE (exit 0); otherwise there is no config (exit 1).
#                       The adjudication fence only needs it to be executable.
#   heimdall-brief      `build --task T --spec S` prints a delta brief for T (exit 0)
mkroot() {
  local d="$1" mode="$2" l
  mkdir -p "$d/bin/lib"
  cp "$REAL_HOOK" "$d/bin/heimdall-precheck-agent"
  for l in hmd_disk_floor.sh hmd_fix_chain.sh hmd-adjudication-set.sh; do cp "$REPO/bin/lib/$l" "$d/bin/lib/$l"; done
  case "$mode" in
    real) cp "$REPO/bin/lib/hmd_guardrail_enabled.sh" "$d/bin/lib/hmd_guardrail_enabled.sh" ;;
    answers2) printf '%s\n' 'hmd_guardrail_enabled() { return 2; }' > "$d/bin/lib/hmd_guardrail_enabled.sh" ;;
    missing) ;;
  esac
  cp "$MANIFEST" "$d/guardrails.manifest.json"
  printf '{"state":"coop"}\n' > "$d/coop.json"
  cat > "$d/bin/heimdall-ctx-meter" <<'EOF'
#!/bin/sh
if [ "${FAKE_CTXMETER:-ok}" = refuse ]; then
  printf '{"decision":"refuse","state":"cliff","tokens":900000,"reason":"no live agents, clean tree"}\n'
  exit 1
fi
printf '{"decision":"ok","state":"ok","tokens":1000,"reason":"below ceiling"}\n'
EOF
  cat > "$d/bin/heimdall-fallback" <<'EOF'
#!/bin/sh
[ "${FAKE_COOP:-0}" = 1 ] || exit 1
case " $* " in
  *" where "*) printf '%s/coop.json\n' "${0%/bin/*}" ;;
  *" check "*) exit 0 ;;
  *) exit 1 ;;
esac
EOF
  cat > "$d/bin/heimdall-brief" <<'EOF'
#!/bin/sh
printf '=== DELTA BRIEF task=%s\nTASK SPEC:\nbuilt by the fake heimdall-brief\n' "$3"
EOF
  chmod +x "$d/bin/heimdall-precheck-agent" "$d/bin/heimdall-ctx-meter" "$d/bin/heimdall-fallback" "$d/bin/heimdall-brief"
}
ROOT="$T/root"; mkroot "$ROOT" real
NOLIB="$T/nolib"; mkroot "$NOLIB" missing
ANS2="$T/answers2"; mkroot "$ANS2" answers2
if cmp -s "$REAL_HOOK" "$ROOT/bin/heimdall-precheck-agent"; then ok "the hook under test is a byte copy of bin/heimdall-precheck-agent"; else bad "the sandbox hook differs from bin/heimdall-precheck-agent"; fi

# payload <file> <subagent_type> <description> <prompt> [extra tool_input JSON]: an Agent spawn from $T/acwd in session s-1
payload() {
  local extra="${5:-}"
  [ -n "$extra" ] || extra='{}'
  jq -cn --arg cwd "$T/acwd" --arg s "$2" --arg d "$3" --arg p "$4" --argjson x "$extra" \
    '{tool_name:"Agent", session_id:"s-1", cwd:$cwd, tool_input:({subagent_type:$s, description:$d, prompt:$p} + $x)}' > "$1"
}
LONG="$(awk 'BEGIN { for (i = 1; i <= 400; i++) printf "word%d ", i }')"
payload "$T/p.base"  hmd:coder       probe 'Do the thing.'
payload "$T/p.named" hmd:coder       probe 'Do the thing.' '{"name":"teammate"}'
payload "$T/p.fix"   hmd:coder       'Fix the reviewer finding F1' 'Fix the finding F1 from the security review.'
payload "$T/p.gp"    general-purpose probe 'Do the thing.'
payload "$T/p.judge" hmd:reviewer    probe 'Do the thing.'
payload "$T/p.long"  hmd:coder       probe "$LONG"

# fire <root> <home> <payload-file> [K=V ...]: the root's hook under env -i from $T/cwd -> $T/run.{out,err,rc}
fire() {
  local root="$1" home="$2" pf="$3"
  shift 3
  ( cd "$T/cwd" && env -i HOME="$home" HEIMDALL_HOME="$home/.heimdall" TMPDIR="$T/tmp" PATH="$T/dfshim:$PATH" CLAUDE_PLUGIN_ROOT="$root" "$@" \
      "$BASH_ABS" "$root/bin/heimdall-precheck-agent" < "$pf" ) > "$T/run.out" 2> "$T/run.err"
  echo $? > "$T/run.rc"
}

# trigger <root> <home> <id>: that guard's canonical spawn, alone
trigger() {
  local root="$1" home="$2"
  case "$3" in
    disk-floor)                  fire "$root" "$home" "$T/p.base" SHIM_DF_FREE_KB=0 ;;
    named-agent-notice)          fire "$root" "$home" "$T/p.named" ;;
    context-gate)                fire "$root" "$home" "$T/p.base" FAKE_CTXMETER=refuse ;;
    fix-chain-advisory)          fire "$root" "$home" "$T/p.fix" HMD_FIX_CHAIN_MAX=0 ;;
    gp-agent-rules)              fire "$root" "$home" "$T/p.gp" ;;
    agent-concurrency-cap)       fire "$root" "$home" "$T/p.base" HEIMDALL_INPROC_AGENT_MAX=0 ;;
    adjudication-fallback-fence) fire "$root" "$home" "$T/p.judge" ANTHROPIC_BASE_URL=http://127.0.0.1:20128 ;;
    coop-native-spawn-refusal)   fire "$root" "$home" "$T/p.base" FAKE_COOP=1 ;;
    brief-adoption-gate)         fire "$root" "$home" "$T/p.long" ;;
  esac
}

RC() { cat "$T/run.rc"; }
show() { printf 'rc=%s out=[%s] err=[%s]' "$(RC)" "$(head -c 200 "$T/run.out")" "$(head -c 200 "$T/run.err")"; }
deny_says() { [ "$(RC)" = 2 ] && jq -e --arg s "$1" '.error | type == "string" and contains($s)' "$T/run.out" >/dev/null 2>&1; }
err_has() { grep -qF -- "$1" "$T/run.err"; }
new_prompt_is() { jq -e "$1" "$T/run.out" >/dev/null 2>&1; }

# fired <id>: the guard acted on its trigger, in its own way
fired() {
  case "$1" in
    disk-floor)                  deny_says 'disk floor' ;;
    named-agent-notice)          [ "$(RC)" = 0 ] && err_has 'named-agent notice' ;;
    context-gate)                deny_says 'context gate' ;;
    fix-chain-advisory)          [ "$(RC)" = 0 ] && err_has 'fix-chain warning' ;;
    gp-agent-rules)              [ "$(RC)" = 0 ] && new_prompt_is '.hookSpecificOutput.updatedInput.prompt | contains("[hmd agent rules]")' ;;
    agent-concurrency-cap)       deny_says 'concurrency cap' ;;
    adjudication-fallback-fence) deny_says 'adjudication deny' ;;
    coop-native-spawn-refusal)   deny_says 'coop deny' ;;
    brief-adoption-gate)         [ "$(RC)" = 0 ] && new_prompt_is '.hookSpecificOutput.updatedInput.prompt | startswith("=== DELTA BRIEF")' ;;
    *)                           return 1 ;;
  esac
}

# silent <home> <id>: the spawn went through untouched -- exit 0, nothing on stdout or stderr; a switched-off fix-chain advisory leaves no counter behind
silent() {
  [ "$(RC)" = 0 ] && [ ! -s "$T/run.out" ] && [ ! -s "$T/run.err" ] || return 1
  [ "$2" != fix-chain-advisory ] || [ ! -e "$1/.heimdall/fix-chain" ]
}

# home_with <name> [id ...]: a fresh HOME whose $HEIMDALL_HOME/guardrails-off lists the ids, one per line (no ids: no file at all)
home_with() {
  local h="$T/homes/$1"
  shift
  mkdir -p "$h/.heimdall"
  [ "$#" -eq 0 ] || printf '%s\n' "$@" > "$h/.heimdall/guardrails-off"
  printf '%s' "$h"
}

# matrix <root> <home> <label> <ids switched off>: fires all nine triggers; the listed ones must go through silent, every other one must act
matrix() {
  local root="$1" home="$2" label="$3" off="$4" id quiet_bad="" act_bad="" nquiet=0 nact=0
  for id in $REC $CORE; do
    trigger "$root" "$home" "$id"
    case " $off " in
      *" $id "*) nquiet=$((nquiet+1)); silent "$home" "$id" || quiet_bad="$quiet_bad [$id: $(show)]" ;;
      *) nact=$((nact+1)); fired "$id" || act_bad="$act_bad [$id: $(show)]" ;;
    esac
  done
  local rest="all $nact guards act"
  if [ "$nquiet" -gt 0 ]; then
    rest="the other $nact guards still act"
    if [ -z "$quiet_bad" ]; then ok "$label: the $nquiet switched-off guard(s) let the spawn through untouched and silent"; else bad "$label: switched off, still acting:$quiet_bad"; fi
  fi
  if [ -z "$act_bad" ]; then ok "$label: $rest"; else bad "$label: did not act:$act_bad"; fi
}

ALL_IDS="$(jq -r '.guardrails[].id' "$MANIFEST")"
CORE_IDS="$(jq -r '.guardrails[] | select(.tier == "core") | .id' "$MANIFEST")"
# shellcheck disable=SC2086  # the id lists are split on purpose: one id per argument
{
  echo "-- 1. INV-G2: no guardrails-off file, every guard acts as before --"
  matrix "$ROOT" "$(home_with none)" "no guardrails-off file" ""

  echo "-- 2. INV-G3: one recommended id switched off changes that guard only --"
  for id in $REC; do
    matrix "$ROOT" "$(home_with "off-$id" "$id")" "guardrails-off lists $id" "$id"
  done

  echo "-- 3. INV-G1: core ids in the file change nothing --"
  matrix "$ROOT" "$(home_with core $CORE_IDS)" "guardrails-off lists every core id of the manifest" ""
  matrix "$ROOT" "$(home_with all $ALL_IDS)" "guardrails-off lists every id of the manifest" "$REC"

  echo "-- 4. INV-G5: the switch fails open --"
  matrix "$NOLIB" "$(home_with nolib $ALL_IDS)" "no bin/lib/hmd_guardrail_enabled.sh beside the hook, every id in the file" ""
  matrix "$ANS2" "$(home_with answers2 $ALL_IDS)" "a switch lib that answers 2 (only exactly 1 means off), every id in the file" ""
}

echo "--------------------------------------------------------------------"
echo "  Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
