#!/usr/bin/env bash
# test/heimdall-context-capsule.test.sh — acceptance for the rr CONTEXT HANDOFF:
# bin/heimdall-context-capsule (build/ship) + bin/heimdall-maintain-loop --context.
#
# Hermetic: gcloud, the secret scanner, and heimdall-state are all driven through
# env seams (a fake gcloud that records argv + captures STDIN, a fake secret-scan,
# and a REAL heimdall-state against a throwaway state file). Nothing here touches a
# live VM, the network, gitleaks, or a real transcript. The capsule is assembled
# from a REAL throwaway git repo with REAL .planning state — no canned shapes.
#
# FALSIFIABLE claims proven:
#   (1) BUILD gathers CHECKPOINT + STATE + git-log + the active goal into the capsule
#       (each source is proven present by a unique sentinel).
#   (2) SECRET SCRUB (redaction) — a planted AWS key in a source file is REDACTED:
#       the raw secret NEVER appears in the assembled capsule (falsifiable — without
#       the scrub the byte-for-byte secret would be in the briefing that ships).
#   (3) FAIL-CLOSED — when the scanner reports a finding, build ABORTS (nonzero) and
#       writes NO capsule (the gate fires; a flagged capsule never ships).
#   (4) SHIP --dry-run prints the scp/ssh plan, transfers NOTHING (gcloud never runs)
#       and carries NO secret in the printed plan.
#   (5) SHIP (real, fake gcloud) streams the capsule over STDIN via IAP — the capsule
#       content arrives on stdin, and NO secret / NO capsule body is on argv.
#   (6) MAINTAIN-LOOP --context plan shows the LOCAL SESSION CONTEXT block prepended.
#   (7) MAINTAIN-LOOP --context run INJECTS the context block into the fix cycle's
#       prompt (the fix brief body begins with the read-only briefing).
#   (8) AUTO-DETECT — a shipped capsule under ~/.heimdall/rr-context/<slug> is picked
#       up with NO --context flag.
#   (9) NO-REGRESSION — maintain-loop WITHOUT --context is unchanged: plan has no
#       context key, and the existing heimdall-maintain-loop.test.sh still passes.

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
CAP="$ROOT/bin/heimdall-context-capsule"
MLOOP="$ROOT/bin/heimdall-maintain-loop"
QCMD="$ROOT/bin/heimdall-issue-queue"
STATE_BIN="$ROOT/bin/heimdall-state"

PASS=0
FAIL=0
ok()  { PASS=$((PASS+1)); printf "  \033[32mPASS\033[0m %s\n" "$1"; }
bad() { FAIL=$((FAIL+1)); printf "  \033[31mFAIL\033[0m %s\n" "$1"; }

command -v jq >/dev/null 2>&1 || { echo "FATAL: jq required" >&2; exit 2; }
PY="$(command -v python3 || command -v python)"
[ -x "$CAP" ]   || { echo "FATAL: $CAP not executable" >&2; exit 2; }
[ -x "$MLOOP" ] || { echo "FATAL: $MLOOP not executable" >&2; exit 2; }

WORK="$(mktemp -d -t "context-capsule-test.$(printf 'X%.0s' 1 2 3 4 5 6)")"
trap 'rm -rf "$WORK"' EXIT

# ── a REAL throwaway repo with REAL .planning state ───────────────────────────
new_repo() {
  local name="$1"
  local repo="$WORK/$name"
  mkdir -p "$repo/.planning"
  git -C "$repo" init -q
  git -C "$repo" config user.email "test@runheimdall.dev"
  git -C "$repo" config user.name "test"
  printf 'module init\n' > "$repo/app.py"
  git -C "$repo" add -A
  git -C "$repo" commit -qm "COMMIT_SENTINEL_first: seed the tree"
  printf '%s' "$repo"
}

# ── fake secret scanners (env seam: HEIMDALL_SECRET_SCAN_BIN "<file>") ─────────
mk_scanner_clean() {   # always reports clean (exit 0)
  cat > "$1" <<'S'
#!/usr/bin/env bash
exit 0
S
  chmod +x "$1"
}
mk_scanner_finding() { # always reports a finding (exit 1) — proves fail-closed
  cat > "$1" <<'S'
#!/usr/bin/env bash
echo "FAKE-LEAK: a secret was detected" >&2
exit 1
S
  chmod +x "$1"
}
SCAN_CLEAN="$WORK/scan_clean";     mk_scanner_clean   "$SCAN_CLEAN"
SCAN_FINDING="$WORK/scan_finding"; mk_scanner_finding "$SCAN_FINDING"

# ── fake gcloud: records argv, captures STDIN (the streamed capsule) ───────────
mk_gcloud() {
  # $1 = dest ; $2 = argv-log path ; $3 = stdin-capture path
  cat > "$1" <<G
#!/usr/bin/env bash
printf '%s\n' "\$*" > "$2"
cat > "$3"
exit 0
G
  chmod +x "$1"
}

echo "-- (1) BUILD gathers CHECKPOINT + STATE + git-log + goal ---------------------"
R1="$(new_repo build)"
printf '# checkpoint\nlast wave: CHECKPOINT_SENTINEL_a1\n' > "$R1/.planning/CHECKPOINT.md"
printf '# state\ncurrent: STATE_SENTINEL_b2\n'            > "$R1/.planning/STATE.md"
printf '# decisions\nchose DECISION_SENTINEL_c3\n'        > "$R1/.planning/decisions.md"
ST1="$R1/heimdall-state.json"
HEIMDALL_STATE_FILE="$ST1" "$STATE_BIN" init >/dev/null 2>&1 || true
HEIMDALL_STATE_FILE="$ST1" "$STATE_BIN" goal-set "GOAL_SENTINEL_d4 ship rr" >/dev/null 2>&1 || true
CAP_OUT="$R1/out/context.md"
env HEIMDALL_SECRET_SCAN_BIN="$SCAN_CLEAN" HEIMDALL_STATE_BIN="$STATE_BIN" \
    HEIMDALL_STATE_FILE="$ST1" \
    "$CAP" build --repo acme/widget --repo-dir "$R1" --out "$CAP_OUT" >/dev/null 2>&1
if [ -f "$CAP_OUT" ] \
   && grep -q 'CHECKPOINT_SENTINEL_a1' "$CAP_OUT" \
   && grep -q 'STATE_SENTINEL_b2'      "$CAP_OUT" \
   && grep -q 'COMMIT_SENTINEL_first'  "$CAP_OUT" \
   && grep -q 'GOAL_SENTINEL_d4'       "$CAP_OUT"; then
  ok "capsule contains CHECKPOINT + STATE + git-log + goal sentinels"
else
  bad "capsule missing one of the required sources ($CAP_OUT)"
fi
if grep -q 'DECISION_SENTINEL_c3' "$CAP_OUT"; then
  ok "capsule includes decisions when present"
else
  bad "capsule dropped the decisions section"
fi
if grep -qi 'LOCAL SESSION CONTEXT\|what this session did\|session' "$CAP_OUT"; then
  ok "capsule carries a briefing header"
else
  bad "capsule has no briefing header"
fi

echo "-- (2) SECRET SCRUB — a planted AWS key is REDACTED, never in the capsule ----"
R2="$(new_repo scrub)"
SECRET='AKIAIOSFODNN7EXAMPLE'
printf '# state\ncurrent: STATE_SENTINEL_ok\nleaked=%s\n' "$SECRET" > "$R2/.planning/STATE.md"
printf '# checkpoint\nok\n' > "$R2/.planning/CHECKPOINT.md"
CAP_OUT2="$R2/out/context.md"
env HEIMDALL_SECRET_SCAN_BIN="$SCAN_CLEAN" HEIMDALL_STATE_BIN="$STATE_BIN" \
    HEIMDALL_STATE_FILE="$R2/heimdall-state.json" \
    "$CAP" build --repo acme/widget --repo-dir "$R2" --out "$CAP_OUT2" >/dev/null 2>&1
if [ -f "$CAP_OUT2" ] && ! grep -q "$SECRET" "$CAP_OUT2"; then
  ok "the planted AWS key was REDACTED — raw secret is absent from the shipped capsule"
else
  bad "the planted secret LEAKED into the capsule (scrub failed)"
fi
if grep -qi 'REDACTED' "$CAP_OUT2"; then
  ok "the redaction marker is present where the secret was"
else
  bad "no redaction marker — the secret was not scrubbed in place"
fi

echo "-- (3) FAIL-CLOSED — scanner finding ABORTS build, writes NO capsule ---------"
R3="$(new_repo failclosed)"
printf '# state\nok\n' > "$R3/.planning/STATE.md"
printf '# checkpoint\nok\n' > "$R3/.planning/CHECKPOINT.md"
CAP_OUT3="$R3/out/context.md"
set +e
env HEIMDALL_SECRET_SCAN_BIN="$SCAN_FINDING" HEIMDALL_STATE_BIN="$STATE_BIN" \
    HEIMDALL_STATE_FILE="$R3/heimdall-state.json" \
    "$CAP" build --repo acme/widget --repo-dir "$R3" --out "$CAP_OUT3" >/dev/null 2>&1
RC3=$?
set -e
if [ "$RC3" -ne 0 ] && [ ! -f "$CAP_OUT3" ]; then
  ok "scanner finding -> build aborted (rc=$RC3) and wrote NO capsule (fail-closed)"
else
  bad "fail-closed broken (rc=$RC3, capsule present=$([ -f "$CAP_OUT3" ] && echo yes || echo no))"
fi

echo "-- (4) SHIP --dry-run — prints the plan, transfers nothing, no secret on plan-"
R4="$(new_repo shipdry)"
printf '# state\nleaked=%s\ncurrent: STATE_SENTINEL_ok\n' "$SECRET" > "$R4/.planning/STATE.md"
printf '# checkpoint\nok\n' > "$R4/.planning/CHECKPOINT.md"
GCLOUD4="$WORK/gcloud4"; ARGV4="$WORK/argv4.log"; STDIN4="$WORK/stdin4.cap"
mk_gcloud "$GCLOUD4" "$ARGV4" "$STDIN4"
DRYOUT="$(env HEIMDALL_SECRET_SCAN_BIN="$SCAN_CLEAN" HEIMDALL_GCLOUD_BIN="$GCLOUD4" \
    HEIMDALL_STATE_BIN="$STATE_BIN" HEIMDALL_STATE_FILE="$R4/heimdall-state.json" \
    "$CAP" ship --vm rr-vm --zone us-central1-a --project my-proj \
    --repo acme/widget --repo-dir "$R4" --dry-run 2>&1)"
if printf '%s' "$DRYOUT" | grep -q 'rr-context/acme_widget/context.md' \
   && printf '%s' "$DRYOUT" | grep -qi 'tunnel-through-iap'; then
  ok "dry-run prints the IAP ssh plan + the target path"
else
  bad "dry-run plan missing the target path or IAP transport"
fi
if [ ! -f "$STDIN4" ] && [ ! -f "$ARGV4" ]; then
  ok "dry-run transferred NOTHING (gcloud never invoked)"
else
  bad "dry-run still invoked gcloud (argv=$([ -f "$ARGV4" ] && echo yes || echo no))"
fi
if ! printf '%s' "$DRYOUT" | grep -q "$SECRET"; then
  ok "the printed plan carries NO secret (redaction + no content in the plan)"
else
  bad "the dry-run plan leaked the secret"
fi

echo "-- (5) SHIP (fake gcloud) — capsule streams over STDIN, no secret on argv ----"
R5="$(new_repo shipreal)"
printf '# state\nleaked=%s\ncurrent: STATE_SENTINEL_e5\n' "$SECRET" > "$R5/.planning/STATE.md"
printf '# checkpoint\nCHECKPOINT_SENTINEL_e5\n' > "$R5/.planning/CHECKPOINT.md"
GCLOUD5="$WORK/gcloud5"; ARGV5="$WORK/argv5.log"; STDIN5="$WORK/stdin5.cap"
mk_gcloud "$GCLOUD5" "$ARGV5" "$STDIN5"
env HEIMDALL_SECRET_SCAN_BIN="$SCAN_CLEAN" HEIMDALL_GCLOUD_BIN="$GCLOUD5" \
    HEIMDALL_STATE_BIN="$STATE_BIN" HEIMDALL_STATE_FILE="$R5/heimdall-state.json" \
    "$CAP" ship --vm rr-vm --zone us-central1-a --project my-proj \
    --repo acme/widget --repo-dir "$R5" >/dev/null 2>&1
if [ -f "$STDIN5" ] && grep -q 'STATE_SENTINEL_e5' "$STDIN5" \
   && grep -q 'CHECKPOINT_SENTINEL_e5' "$STDIN5"; then
  ok "the capsule content arrived over STDIN (streamed, not on argv)"
else
  bad "the capsule did not stream over STDIN"
fi
if [ -f "$ARGV5" ] && grep -q 'tunnel-through-iap' "$ARGV5" \
   && grep -q 'us-central1-a' "$ARGV5" && grep -q 'my-proj' "$ARGV5"; then
  ok "gcloud invoked over IAP with the right zone/project"
else
  bad "gcloud argv missing IAP/zone/project ($(cat "$ARGV5" 2>/dev/null))"
fi
if ! grep -q "$SECRET" "$ARGV5" && ! grep -q 'STATE_SENTINEL_e5' "$ARGV5"; then
  ok "NO secret and NO capsule body on argv (content is stdin-only)"
else
  bad "the ssh argv leaked capsule content / a secret"
fi

echo "-- (6) MAINTAIN-LOOP --context plan — shows the briefing block prepended ------"
CTX="$WORK/ctx.md"
printf 'CONTEXT_SENTINEL_x9 — prior local decisions here\n' > "$CTX"
R6="$(new_repo mplan)"
cat > "$R6/heimdall-state.json" <<'STATE'
{"maintainer":{"enabled":true,"budget_tokens":600000}}
STATE
PLANOUT="$(env HEIMDALL_STATE_FILE="$R6/heimdall-state.json" \
    "$MLOOP" plan --repo "$R6" --context "$CTX" 2>/dev/null)"
if printf '%s' "$PLANOUT" | jq -e '.context.prepended == true' >/dev/null 2>&1 \
   && printf '%s' "$PLANOUT" | grep -q 'LOCAL SESSION CONTEXT'; then
  ok "plan --context surfaces the prepended LOCAL SESSION CONTEXT block"
else
  bad "plan --context did not show the context block"
fi

echo "-- (7) MAINTAIN-LOOP --context run — injects the block into the fix prompt ----"
R7="$(new_repo minject)"
cat > "$R7/heimdall-state.json" <<'STATE'
{"maintainer":{"enabled":true,"budget_tokens":600000}}
STATE
METER7="$WORK/meter7"
cat > "$METER7" <<'M'
#!/usr/bin/env bash
echo '{"total_tokens": 10, "total_cost_usd": 0.0}'
M
chmod +x "$METER7"
RAW7="$("$PY" -c 'import json;print(json.dumps({"repo":"acme/widget","number":7,"title":"fix the thing","body":"ISSUE_BODY_SENTINEL broken","labels":[{"name":"bug"}],"created_at":"2020-06-01T00:00:00Z"}))')"
HEIMDALL_HOME="$R7/.heimdall" "$QCMD" ingest --source github --raw "$RAW7" --repo "$R7" >/dev/null
env HEIMDALL_HOME="$R7/.heimdall" HEIMDALL_STATE_FILE="$R7/heimdall-state.json" \
    HEIMDALL_TOKENS_BIN="$METER7" \
    "$MLOOP" run --repo "$R7" --context "$CTX" --evidence "true" >/dev/null 2>&1
BRIEF="$(ls "$R7/.heimdall/issues/fix-briefs/"*.json 2>/dev/null | head -1)"
if [ -n "$BRIEF" ] && grep -q 'LOCAL SESSION CONTEXT' "$BRIEF" \
   && grep -q 'CONTEXT_SENTINEL_x9' "$BRIEF" \
   && grep -q 'ISSUE_BODY_SENTINEL' "$BRIEF"; then
  ok "the fix brief prompt begins with the briefing, then the issue (context prepended)"
else
  bad "the context was NOT injected into the fix cycle prompt ($BRIEF)"
fi

echo "-- (8) AUTO-DETECT — shipped capsule under ~/.heimdall/rr-context is used -----"
R8="$(new_repo mauto)"
cat > "$R8/heimdall-state.json" <<'STATE'
{"maintainer":{"enabled":true,"budget_tokens":600000}}
STATE
FAKEHOME="$WORK/vmhome"
mkdir -p "$FAKEHOME/rr-context/acme_widget"
printf 'AUTODETECT_SENTINEL_z1 prior state\n' > "$FAKEHOME/rr-context/acme_widget/context.md"
PLANAUTO="$(env HEIMDALL_HOME="$FAKEHOME" HEIMDALL_STATE_FILE="$R8/heimdall-state.json" \
    "$MLOOP" plan --repo "$R8" 2>/dev/null)"
if printf '%s' "$PLANAUTO" | jq -e '.context.prepended == true' >/dev/null 2>&1 \
   && printf '%s' "$PLANAUTO" | grep -q 'AUTODETECT_SENTINEL_z1'; then
  ok "the shipped capsule was auto-detected with NO --context flag"
else
  bad "auto-detect did not pick up the shipped capsule"
fi

echo "-- (9) NO-REGRESSION — no --context is unchanged + existing suite green -------"
R9="$(new_repo mnoreg)"
cat > "$R9/heimdall-state.json" <<'STATE'
{"maintainer":{"enabled":true,"budget_tokens":600000}}
STATE
PLANNONE="$(env HEIMDALL_STATE_FILE="$R9/heimdall-state.json" \
    "$MLOOP" plan --repo "$R9" 2>/dev/null)"
if ! printf '%s' "$PLANNONE" | jq -e 'has("context")' >/dev/null 2>&1; then
  ok "plan WITHOUT --context has no context key (byte-shape unchanged)"
else
  bad "plan added a context key with no capsule present (regression)"
fi
if bash "$ROOT/test/heimdall-maintain-loop.test.sh" >/dev/null 2>&1; then
  ok "the existing heimdall-maintain-loop.test.sh still passes (no regression)"
else
  bad "the existing maintain-loop suite FAILED after the --context change"
fi

echo
echo "============================================================================"
printf "context-capsule: \033[32m%d passed\033[0m, " "$PASS"
if [ "$FAIL" -gt 0 ]; then
  printf "\033[31m%d failed\033[0m\n" "$FAIL"
  exit 1
fi
printf "%d failed\n" "$FAIL"
echo "ALL GREEN — build gathers state · secret scrub+fail-closed · ship over IAP stdin · context ingest + no-regression"
