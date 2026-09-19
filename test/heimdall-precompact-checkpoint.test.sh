#!/usr/bin/env bash
# test/heimdall-precompact-checkpoint.test.sh
#
# Proof for bin/heimdall-precompact-checkpoint -- the PreCompact hook that makes
# "checkpoint before compaction" mechanical instead of a stderr plea to the
# operator (docs/analysis/2026-09-19-ecc-harness-gap-analysis.md, item #1).
#
# Two properties, asserted head-on:
#   1. It SAVES: a real PreCompact payload produces .planning/CHECKPOINT.md via the
#      existing writer, and the checkpoint records that compaction caused it and
#      which trigger kind ("manual" / "auto").
#   2. It CANNOT HURT compaction: exit 0 and an empty stdout on every failure --
#      malformed JSON, empty stdin, missing writer, a hung dependency -- and the
#      hung case returns inside its own alarm, not the hook runtime's.
#
# Every case runs in a throwaway git repo with HEIMDALL_HOME redirected, so the
# operator's real notes store and .planning are never touched.

set -u

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOOK="$REPO/bin/heimdall-precompact-checkpoint"

PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; }

TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT

# A fresh throwaway git project with a .planning dir (same shape the autosave
# test uses -- the writer needs a HEAD to derive its contract fields).
mk_project() {
  local d="$TMPROOT/$1"
  mkdir -p "$d"
  git -C "$d" init -q
  git -C "$d" config user.email t@t.t
  git -C "$d" config user.name t
  printf 'hello\n' > "$d/README.md"
  git -C "$d" add README.md
  git -C "$d" commit -qm "initial commit" --no-verify
  mkdir -p "$d/.planning"
  printf '%s' "$d"
}

payload() { # <trigger> <cwd>
  printf '{"session_id":"sess-%s","transcript_path":"/nonexistent/t.jsonl","cwd":"%s","hook_event_name":"PreCompact","trigger":"%s","custom_instructions":null}' "$1" "$2" "$1"
}

# run_hook <stdin-file> [args...] -> echoes rc; stdout/stderr captured to files.
run_hook() {
  local in="$1"; shift
  "$HOOK" "$@" <"$in" >"$TMPROOT/out" 2>"$TMPROOT/err"
  printf '%s' "$?"
}

now_s() { date +%s; }

echo "heimdall-precompact-checkpoint"

# ── 1. manual payload → checkpoint written, mentions compaction + trigger ────
P1="$(mk_project manual)"
payload manual "$P1" > "$TMPROOT/in1"
rc="$(HEIMDALL_HOME="$P1/.hmdhome" run_hook "$TMPROOT/in1")"
CK1="$P1/.planning/CHECKPOINT.md"
if [ "$rc" = "0" ] && [ -f "$CK1" ]; then
  ok "1. manual payload → exit 0 and .planning/CHECKPOINT.md exists"
else
  bad "1. manual payload did not produce a checkpoint (rc=$rc, file=$([ -f "$CK1" ] && echo yes || echo no))"
fi

if grep -q 'heimdall-auto-checkpoint:begin' "$CK1" 2>/dev/null; then
  ok "2. the checkpoint came from the EXISTING writer (auto-checkpoint marker present)"
else
  bad "2. auto-checkpoint marker missing — the hook did not reuse bin/heimdall-checkpoint"
fi

if grep -q 'compaction (manual)' "$CK1" 2>/dev/null; then
  ok "3. checkpoint records it was compaction-triggered with trigger kind 'manual'"
else
  bad "3. checkpoint does not mention 'compaction (manual)'"
fi

if grep -q 'sess-manual' "$CK1" 2>/dev/null; then
  ok "4. checkpoint carries the session_id from the payload"
else
  bad "4. session_id from the payload not found in the checkpoint"
fi

if [ ! -s "$TMPROOT/out" ]; then
  ok "5. stdout is empty on the success path"
else
  bad "5. stdout was not empty: $(head -c 200 "$TMPROOT/out")"
fi

if grep -q 'compaction (manual)' "$TMPROOT/err" && grep -q 'checkpoint saved' "$TMPROOT/err"; then
  ok "6. one stderr status line names the trigger and the saved checkpoint"
else
  bad "6. stderr status line missing or wrong: $(head -c 300 "$TMPROOT/err")"
fi

# ── 7. auto payload → trigger kind 'auto' recorded ──────────────────────────
P2="$(mk_project auto)"
payload auto "$P2" > "$TMPROOT/in2"
rc="$(HEIMDALL_HOME="$P2/.hmdhome" run_hook "$TMPROOT/in2")"
if [ "$rc" = "0" ] && grep -q 'compaction (auto)' "$P2/.planning/CHECKPOINT.md" 2>/dev/null; then
  ok "7. auto payload → checkpoint records 'compaction (auto)'"
else
  bad "7. auto trigger not recorded (rc=$rc)"
fi

# ── 8. --repo overrides payload cwd (the hooks.json spelling) ───────────────
P3="$(mk_project repoflag)"
payload manual "/nonexistent/elsewhere" > "$TMPROOT/in3"
rc="$(HEIMDALL_HOME="$P3/.hmdhome" run_hook "$TMPROOT/in3" --repo "$P3")"
if [ "$rc" = "0" ] && [ -f "$P3/.planning/CHECKPOINT.md" ]; then
  ok "8. --repo <dir> selects the project even when payload cwd is bogus"
else
  bad "8. --repo not honoured (rc=$rc)"
fi

# ── 9. malformed JSON → exit 0, no stdout, no checkpoint-writer crash ────────
P4="$(mk_project malformed)"
printf '{"trigger": "man' > "$TMPROOT/in4"
rc="$(HEIMDALL_HOME="$P4/.hmdhome" run_hook "$TMPROOT/in4" --repo "$P4")"
if [ "$rc" = "0" ] && [ ! -s "$TMPROOT/out" ]; then
  ok "9. malformed JSON → exit 0, empty stdout"
else
  bad "9. malformed JSON broke the hook (rc=$rc, stdout bytes=$(wc -c <"$TMPROOT/out"))"
fi
if grep -q 'compaction (unknown)' "$TMPROOT/err"; then
  ok "10. malformed payload degrades to trigger 'unknown' and still checkpoints"
else
  bad "10. expected 'compaction (unknown)' on stderr: $(head -c 300 "$TMPROOT/err")"
fi

# ── 11. empty stdin → exit 0, no stdout ─────────────────────────────────────
P5="$(mk_project empty)"
: > "$TMPROOT/in5"
rc="$(HEIMDALL_HOME="$P5/.hmdhome" run_hook "$TMPROOT/in5" --repo "$P5")"
if [ "$rc" = "0" ] && [ ! -s "$TMPROOT/out" ]; then
  ok "11. empty stdin → exit 0, empty stdout"
else
  bad "11. empty stdin broke the hook (rc=$rc)"
fi

# ── 12. non-hmd project (no .planning) → exit 0, nothing created ────────────
P6="$TMPROOT/plain"; mkdir -p "$P6"
payload manual "$P6" > "$TMPROOT/in6"
rc="$(run_hook "$TMPROOT/in6")"
if [ "$rc" = "0" ] && [ ! -d "$P6/.planning" ] && [ ! -s "$TMPROOT/out" ]; then
  ok "12. project without .planning/ is left untouched (no dir sprayed), exit 0"
else
  bad "12. gate failed: rc=$rc, .planning created=$([ -d "$P6/.planning" ] && echo yes || echo no)"
fi

# ── 13. missing writer beside the hook → exit 0, stderr says so ─────────────
ALONE="$TMPROOT/alone-bin"; mkdir -p "$ALONE"
cp "$HOOK" "$ALONE/heimdall-precompact-checkpoint"
chmod +x "$ALONE/heimdall-precompact-checkpoint"
P7="$(mk_project nowriter)"
payload auto "$P7" > "$TMPROOT/in7"
"$ALONE/heimdall-precompact-checkpoint" <"$TMPROOT/in7" >"$TMPROOT/out" 2>"$TMPROOT/err"; rc=$?
if [ "$rc" = "0" ] && [ ! -s "$TMPROOT/out" ] && grep -q 'heimdall-checkpoint not found' "$TMPROOT/err"; then
  ok "13. missing bin/heimdall-checkpoint → exit 0, empty stdout, stderr names the cause"
else
  bad "13. missing writer not handled (rc=$rc): $(head -c 300 "$TMPROOT/err")"
fi

# ── 14. hung dependency (git shim sleeps) → exits 0 inside the alarm ────────
# The writer shells out to git via PATH; a git that never returns is the realistic
# "hung dependency". The hook's own budget is 2s here; it must return well before
# the shim's 60s, exit 0, and say the writer was stopped.
SHIM="$TMPROOT/shim"; mkdir -p "$SHIM"
cat > "$SHIM/git" <<'EOF'
#!/bin/sh
sleep 60
EOF
chmod +x "$SHIM/git"
P8="$(mk_project hung)"
payload auto "$P8" > "$TMPROOT/in8"
t0="$(now_s)"
PATH="$SHIM:$PATH" HMD_PRECOMPACT_BUDGET=2 HEIMDALL_HOME="$P8/.hmdhome" \
  "$HOOK" --repo "$P8" <"$TMPROOT/in8" >"$TMPROOT/out" 2>"$TMPROOT/err"; rc=$?
t1="$(now_s)"
elapsed=$((t1 - t0))
if [ "$rc" = "0" ] && [ "$elapsed" -lt 15 ] && [ ! -s "$TMPROOT/out" ]; then
  ok "14. hung git → exit 0 in ${elapsed}s (budget 2s, shim would hang 60s), empty stdout"
else
  bad "14. hung dependency not bounded (rc=$rc, elapsed=${elapsed}s, stdout bytes=$(wc -c <"$TMPROOT/out"))"
fi
if grep -q 'exceeded 2s and was stopped' "$TMPROOT/err"; then
  ok "15. stderr reports the writer was stopped at the budget and tells the operator to /hmd:save"
else
  bad "15. timeout not reported on stderr: $(head -c 300 "$TMPROOT/err")"
fi

# ── 16. help exits 0 and prints nothing on stdout ───────────────────────────
"$HOOK" help >"$TMPROOT/out" 2>"$TMPROOT/err"; rc=$?
if [ "$rc" = "0" ] && [ ! -s "$TMPROOT/out" ] && grep -q 'Usage' "$TMPROOT/err"; then
  ok "16. help → exit 0, usage on stderr, stdout empty"
else
  bad "16. help misbehaved (rc=$rc)"
fi

# ── 17. bad HMD_PRECOMPACT_BUDGET is tolerated, not fatal ───────────────────
P9="$(mk_project badbudget)"
payload manual "$P9" > "$TMPROOT/in9"
rc="$(HMD_PRECOMPACT_BUDGET=abc HEIMDALL_HOME="$P9/.hmdhome" run_hook "$TMPROOT/in9" --repo "$P9")"
if [ "$rc" = "0" ] && [ -f "$P9/.planning/CHECKPOINT.md" ]; then
  ok "17. garbage budget falls back to the default and still saves"
else
  bad "17. garbage budget broke the hook (rc=$rc)"
fi

# ── 18. the hook never exits 2 (the one code that blocks compaction) ────────
# Re-run every captured input once more through the hook and collect exit codes.
codes=""
for f in "$TMPROOT"/in*; do
  "$HOOK" <"$f" >/dev/null 2>&1; codes="$codes $?"
done
case "$codes" in
  *" 2"*) bad "18. some input produced exit 2 (would BLOCK compaction): codes=$codes" ;;
  *)      ok  "18. no input produced exit 2 (codes:$codes)" ;;
esac

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
