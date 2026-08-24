#!/usr/bin/env bash
# test/issue-loop-claude-fix-overload.test.sh — direct, hermetic proof that
# _run_claude_fix (bin/lib/issue_loop.py) ROUTES THROUGH the retry wrapper
# (bin/lib/hmd-claude-retry.sh) instead of calling `claude` bare.
#
# THE BUG THIS CLOSES: hmd-claude-retry.sh already existed to retry a transient
# 529/overload with backoff, but nothing referenced it outside its own test —
# _run_claude_fix called `claude` directly. On an overload, `claude` exhausted
# its OWN retries, exited non-zero, and _run_claude_fix recorded a completed
# "fix attempt" whose output_tail WAS the overload banner: a capacity failure
# silently misfiled as fix output, invisible to the SI-2 gate.
#
# HERMETIC: exercises _run_claude_fix DIRECTLY (python3 -c) against three FIXED
# fake `claude` scripts selected via HMD_CLAUDE_BIN — the WRAPPER's own seam
# (deliberately NOT HEIMDALL_CLAUDE_BIN, proving that resolution path too).
# HMD_OVERLOAD_BASE_SECS=0 / CAP_SECS=0 so nothing sleeps. Each fake counts its
# own invocations into a path baked directly into its script TEXT (never an env
# var — _fix_child_env() is credential-scrubbed to a fixed allowlist, so a
# counter passed via env would be dropped exactly like a real credential is).
#
# Falsifiable — FAILS if:
#   (a) an always-overloaded fake (529 banner + non-zero exit, every call) is
#       NOT retried exactly HMD_OVERLOAD_MAX_ATTEMPTS times, or the give-up
#       outcome is not the DISTINCT overloaded:true shape (e.g. comes back
#       looking like a normal completed ran-dict with files_changed).
#   (b) a REAL error (non-zero exit, NO overload marker) IS retried instead of
#       failing fast on the FIRST call with claude's own real exit code.
#   (c) a clean success (exit 0) is invoked more than once, or its output/exit
#       is not returned verbatim.
# Plus two smaller checks on this same edit: (d) HEIMDALL_CLAUDE_BIN (this
# module's own pre-existing seam) still wins over HMD_CLAUDE_BIN when both are
# set; (e) a missing binary still preserves the pre-existing claude-not-found
# shape through the new routing.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LIB="$ROOT/bin/lib/issue_loop.py"
WRAPPER="$ROOT/bin/lib/hmd-claude-retry.sh"
command -v jq >/dev/null 2>&1 || { echo "FATAL: jq required" >&2; exit 2; }
[ -f "$LIB" ]     || { echo "FATAL: $LIB missing" >&2; exit 2; }
[ -f "$WRAPPER" ] || { echo "FATAL: $WRAPPER missing" >&2; exit 2; }
PY="$(command -v python3 || command -v python || true)"
[ -n "$PY" ] || { echo "FATAL: no python3/python on PATH" >&2; exit 2; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

PASS=0; FAIL=0
ok()  { PASS=$((PASS + 1)); printf '  \033[32mPASS\033[0m %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  \033[31mFAIL\033[0m %s\n' "$1"; }
jget() { printf '%s' "$1" | jq -r "$2" 2>/dev/null; }
# a truncated-but-existing counter file (`: > file`) reads as "" from cat, exit 0 —
# `cat ... || echo 0` only covers a MISSING file, never an empty one, so normalize here.
count_of() { local v; v="$(cat "$1" 2>/dev/null)"; printf '%s' "${v:-0}"; }

# a real (throwaway) git repo: the ran-shape path shells out to
# `git -C <repo> status --porcelain` (_changed_file_count) — must be real git.
REPO="$WORK/repo"
mkdir -p "$REPO"
git -C "$REPO" init -q
git -C "$REPO" -c user.email=t@t.example -c user.name=t commit -q --allow-empty -m init

# ── fake claude #1: clean success — exit 0, real stdout, counts invocations. ──
CNT_OK="$WORK/count-success"
cat > "$WORK/claude-success" <<EOF
#!/usr/bin/env bash
n=\$(cat "$CNT_OK" 2>/dev/null || echo 0); n=\$((n + 1)); echo "\$n" > "$CNT_OK"
echo "STUB-OK real fix output"
exit 0
EOF
chmod +x "$WORK/claude-success"

# ── fake claude #2: REAL error — non-zero exit, NO overload marker. must NOT retry. ──
CNT_ERR="$WORK/count-real-error"
cat > "$WORK/claude-real-error" <<EOF
#!/usr/bin/env bash
n=\$(cat "$CNT_ERR" 2>/dev/null || echo 0); n=\$((n + 1)); echo "\$n" > "$CNT_ERR"
echo "Error: invalid prompt — malformed request" >&2
exit 1
EOF
chmod +x "$WORK/claude-real-error"

# ── fake claude #3: ALWAYS overloaded — non-zero exit + 529 marker, every call.
#    must be retried up to HMD_OVERLOAD_MAX_ATTEMPTS times, then give up loudly. ──
CNT_OVL="$WORK/count-overload"
cat > "$WORK/claude-overload" <<EOF
#!/usr/bin/env bash
n=\$(cat "$CNT_OVL" 2>/dev/null || echo 0); n=\$((n + 1)); echo "\$n" > "$CNT_OVL"
echo "API Error: 529 Overloaded · Retrying \${n}/10" >&2
exit 1
EOF
chmod +x "$WORK/claude-overload"

# invoke _run_claude_fix DIRECTLY (no CLI, no queue) and print its result dict
# as one line of JSON. $1 = fake claude path (-> HMD_CLAUDE_BIN) ; $2 = max attempts.
run_fix() {
  HMD_CLAUDE_BIN="$1" \
  HMD_OVERLOAD_MAX_ATTEMPTS="$2" \
  HMD_OVERLOAD_BASE_SECS=0 HMD_OVERLOAD_CAP_SECS=0 HMD_OVERLOAD_EXIT=75 \
  HEIMDALL_FIX_WITH_CLAUDE=1 \
  "$PY" -c "
import json, sys
sys.path.insert(0, '$ROOT/bin/lib')
import issue_loop as il
result = il._run_claude_fix({'title': 't', 'body': 'b'}, {}, '$REPO')
print(json.dumps(result))
"
}

echo "== (a) always-overloaded -> retried HMD_OVERLOAD_MAX_ATTEMPTS times, then a DISTINCT give-up outcome =="
: > "$CNT_OVL"
OUT_A="$(run_fix "$WORK/claude-overload" 3)"
[ "$(jget "$OUT_A" '.invoked')" = "true" ] && ok "a: invoked=true" || bad "a: invoked=true (got: $OUT_A)"
[ "$(jget "$OUT_A" '.overloaded')" = "true" ] && ok "a: overloaded=true (the distinct give-up shape)" || bad "a: overloaded=true (got: $OUT_A)"
[ "$(jget "$OUT_A" '.exit')" = "75" ] && ok "a: exit == HMD_OVERLOAD_EXIT (75)" || bad "a: exit==75 (got: $OUT_A)"
[ "$(jget "$OUT_A" '.files_changed')" = "null" ] && ok "a: NOT the ran-shape (no files_changed key on give-up)" || bad "a: files_changed absent (got: $OUT_A)"
N_A="$(count_of "$CNT_OVL")"
[ "$N_A" = "3" ] && ok "a: retried exactly HMD_OVERLOAD_MAX_ATTEMPTS (3) times (proves the knob is forwarded)" || bad "a: expected 3 invocations, got $N_A"

echo "== (b) real error, no overload marker -> fails FAST, NOT retried =="
: > "$CNT_ERR"
OUT_B="$(run_fix "$WORK/claude-real-error" 6)"
[ "$(jget "$OUT_B" '.invoked')" = "true" ] && ok "b: invoked=true" || bad "b: invoked=true (got: $OUT_B)"
[ "$(jget "$OUT_B" '.exit')" = "1" ] && ok "b: exit == claude's own real exit code (1)" || bad "b: exit==1 (got: $OUT_B)"
[ "$(jget "$OUT_B" '.overloaded')" = "null" ] && ok "b: NOT flagged overloaded (a real error, not transient)" || bad "b: overloaded absent (got: $OUT_B)"
[ "$(jget "$OUT_B" '.files_changed')" = "0" ] && ok "b: still the ran-shape (files_changed:0)" || bad "b: files_changed==0 (got: $OUT_B)"
N_B="$(count_of "$CNT_ERR")"
[ "$N_B" = "1" ] && ok "b: NOT retried — exactly one invocation (fail fast)" || bad "b: expected 1 invocation, got $N_B"

echo "== (c) clean success -> returned verbatim, exactly one invocation (no spurious retry) =="
: > "$CNT_OK"
OUT_C="$(run_fix "$WORK/claude-success" 6)"
[ "$(jget "$OUT_C" '.invoked')" = "true" ] && ok "c: invoked=true" || bad "c: invoked=true (got: $OUT_C)"
[ "$(jget "$OUT_C" '.exit')" = "0" ] && ok "c: exit == 0" || bad "c: exit==0 (got: $OUT_C)"
case "$(jget "$OUT_C" '.output_tail')" in
  *"STUB-OK real fix output"*) ok "c: real stdout returned verbatim" ;;
  *) bad "c: output_tail missing expected text (got: $OUT_C)" ;;
esac
N_C="$(count_of "$CNT_OK")"
[ "$N_C" = "1" ] && ok "c: no spurious retry on success — exactly one invocation" || bad "c: expected 1 invocation, got $N_C"

echo "== (d) HEIMDALL_CLAUDE_BIN (this module's own seam) still wins over HMD_CLAUDE_BIN when both are set =="
: > "$CNT_OK"; : > "$CNT_ERR"
OUT_D="$(HEIMDALL_CLAUDE_BIN="$WORK/claude-success" run_fix "$WORK/claude-real-error" 6)"
[ "$(jget "$OUT_D" '.exit')" = "0" ] && ok "d: HEIMDALL_CLAUDE_BIN takes priority over HMD_CLAUDE_BIN" || bad "d: HEIMDALL_CLAUDE_BIN priority (got: $OUT_D)"
N_OK_D="$(count_of "$CNT_OK")"; N_ERR_D="$(count_of "$CNT_ERR")"
[ "$N_OK_D" = "1" ] && [ "$N_ERR_D" = "0" ] && ok "d: the HEIMDALL_CLAUDE_BIN target ran, the HMD_CLAUDE_BIN one did not" || bad "d: invocation counts wrong (ok=$N_OK_D err=$N_ERR_D)"

echo "== (e) claude-not-found: preserves the pre-existing reason shape through the new routing =="
OUT_E="$(run_fix "$WORK/does-not-exist-claude" 6)"
[ "$(jget "$OUT_E" '.invoked')" = "false" ] && ok "e: invoked=false for a missing binary" || bad "e: invoked=false (got: $OUT_E)"
[ "$(jget "$OUT_E" '.reason')" = "claude-not-found" ] && ok "e: reason=claude-not-found preserved" || bad "e: reason=claude-not-found (got: $OUT_E)"

echo
echo "════════════════════════════════════════════════════════════════════════════"
printf "issue-loop-claude-fix-overload: \033[32m%d passed\033[0m, " "$PASS"
if [ "$FAIL" -gt 0 ]; then
  printf "\033[31m%d failed\033[0m\n" "$FAIL"
  exit 1
fi
printf "%d failed\n" "$FAIL"
echo "ALL GREEN — _run_claude_fix now routes through hmd-claude-retry.sh: a transient"
echo "529/overload is retried with backoff and, on exhaustion, reported as the distinct"
echo "overloaded:true outcome — never silently recorded as completed fix output. A real"
echo "(non-overload) error still fails fast on the first call, and a clean success is"
echo "still returned verbatim with no added retry or latency."
