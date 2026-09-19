#!/usr/bin/env bash
# test/hooks-metadata-drift.test.sh
#
# Proof for `bin/heimdall-hooks check` -- the fingerprint drift test over
# hooks/hooks.json's matcher groups.
#
# What must hold, asserted head-on:
#   1. The committed sidecar matches the committed hooks.json (exit 0). If this
#      fails, somebody edited a hook command without `heimdall-hooks regen`.
#   2. Mutating ONE command flips `check` to exit 1 AND the failure names the
#      hook's id -- a drift report that says "something changed" is useless.
#   3. A live group with no metadata entry is exit 1 (an unnamed hook is a hook
#      nobody can disable or reason about).
#   4. `regen` is the only writer, repairs the drift, and `check` is 0 again.
#   5. `check` never writes hooks.json -- byte-identical before and after.
#   6. Fail-open is exactly one case: hooks.json itself unreadable -> exit 0.
#
# Everything runs against COPIES in a temp dir via --hooks/--metadata; the
# committed files are only ever read.

set -u

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TOOL="$REPO/bin/heimdall-hooks"
HOOKS="$REPO/hooks/hooks.json"
META="$REPO/hooks/hooks.metadata.json"

PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; }

TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT
export HEIMDALL_HOME="$TMPROOT/home"

run_tool() {
  "$TOOL" "$@" 2>"$TMPROOT/err" 1>"$TMPROOT/out"
  printf '%s' "$?"
}

echo "heimdall-hooks check (metadata drift)"

if ! command -v jq >/dev/null 2>&1; then
  echo "  SKIP: jq not installed"; exit 0
fi

# ── 1. committed sidecar is in sync with committed hooks.json ───────────────
rc="$(run_tool check)"
[ "$rc" = "0" ] && ok "1. committed hooks.json and hooks.metadata.json agree (exit 0)" \
                || bad "1. committed files drift (rc=$rc): $(cat "$TMPROOT/err")"

# ── 2. unmodified copies -> exit 0 ──────────────────────────────────────────
cp "$HOOKS" "$TMPROOT/hooks.json"; cp "$META" "$TMPROOT/meta.json"
rc="$(run_tool check --hooks "$TMPROOT/hooks.json" --metadata "$TMPROOT/meta.json")"
[ "$rc" = "0" ] && ok "2. unmodified copies exit 0" || bad "2. unmodified copies exited $rc"

# ── 3. mutate ONE command -> exit 1, names the id ───────────────────────────
jq '.hooks.SessionStart[9].hooks[0].command += " # drift"' "$HOOKS" > "$TMPROOT/drift.json"
rc="$(run_tool check --hooks "$TMPROOT/drift.json" --metadata "$TMPROOT/meta.json")"
if [ "$rc" = "1" ] && grep -q 'DRIFT caveman-rules' "$TMPROOT/err"; then
  ok "3. one mutated command -> exit 1 naming caveman-rules"
else
  bad "3. drift not detected or not named (rc=$rc): $(cat "$TMPROOT/err")"
fi

# ── 4. widening a matcher is drift too ──────────────────────────────────────
jq '.hooks.PreToolUse[1].matcher = "Read|Grep|Glob|Bash"' "$HOOKS" > "$TMPROOT/matcher.json"
rc="$(run_tool check --hooks "$TMPROOT/matcher.json" --metadata "$TMPROOT/meta.json")"
if [ "$rc" = "1" ] && grep -q 'DRIFT parallelism-tracker-read' "$TMPROOT/err"; then
  ok "4. a changed matcher is drift, named by id"
else
  bad "4. matcher change not detected (rc=$rc)"
fi

# ── 5. entry missing from metadata -> exit 1, names the slot ────────────────
jq 'del(.hooks[] | select(.id == "caveman-rules"))' "$META" > "$TMPROOT/meta-missing.json"
rc="$(run_tool check --hooks "$TMPROOT/hooks.json" --metadata "$TMPROOT/meta-missing.json")"
if [ "$rc" = "1" ] && grep -q 'SessionStart\[9\].*NO metadata entry' "$TMPROOT/err"; then
  ok "5. live group with no metadata entry -> exit 1 naming SessionStart[9]"
else
  bad "5. missing entry not reported (rc=$rc): $(cat "$TMPROOT/err")"
fi

# ── 6. stale metadata entry (no live group) -> exit 1 ───────────────────────
# Drop the LAST Stop group so no surviving entry shifts index; the stale id is
# read from metadata rather than hardcoded, so adding a Stop hook later cannot
# break this case (it did once: a 4th Stop hook turned a fixed Stop[2] into a
# fingerprint mismatch instead of the stale report this asserts).
LAST_STOP_ID="$(jq -r '[.hooks[] | select(.event=="Stop")] | max_by(.index) | .id' "$TMPROOT/meta.json")"
jq 'del(.hooks.Stop[-1])' "$HOOKS" > "$TMPROOT/fewer.json"
rc="$(run_tool check --hooks "$TMPROOT/fewer.json" --metadata "$TMPROOT/meta.json")"
if [ "$rc" = "1" ] && grep -q "$LAST_STOP_ID.*stale" "$TMPROOT/err"; then
  ok "6. metadata entry with no live group -> exit 1 (stale)"
else
  bad "6. stale entry not reported (rc=$rc)"
fi

# ── 7. duplicate id -> exit 1 ───────────────────────────────────────────────
jq '(.hooks[] | select(.id == "dream-notice")).id = "caveman-rules"' "$META" > "$TMPROOT/meta-dup.json"
rc="$(run_tool check --hooks "$TMPROOT/hooks.json" --metadata "$TMPROOT/meta-dup.json")"
if [ "$rc" = "1" ] && grep -q 'duplicate id' "$TMPROOT/err"; then
  ok "7. duplicate id -> exit 1"
else
  bad "7. duplicate id not reported (rc=$rc)"
fi

# ── 8. regen repairs drift, prints what changed, check is 0 again ───────────
cp "$TMPROOT/meta.json" "$TMPROOT/meta-regen.json"
rc="$(run_tool regen --hooks "$TMPROOT/drift.json" --metadata "$TMPROOT/meta-regen.json")"
out="$(cat "$TMPROOT/out")"
rc2="$(run_tool check --hooks "$TMPROOT/drift.json" --metadata "$TMPROOT/meta-regen.json")"
if [ "$rc" = "0" ] && grep -q 'FP    caveman-rules' <<<"$out" && [ "$rc2" = "0" ] \
   && [ "$(jq -r '.hooks[] | select(.id=="caveman-rules") | .locked' "$TMPROOT/meta-regen.json")" = "false" ] \
   && [ "$(jq -r '.hooks[] | select(.id=="stub-gate") | .locked' "$TMPROOT/meta-regen.json")" = "true" ]; then
  ok "8. regen names the changed id, preserves id/locked, and check is clean after"
else
  bad "8. regen did not repair drift cleanly (regen=$rc check=$rc2): $out"
fi

# ── 9. regen on a NEW group adds an entry flagged NEW ───────────────────────
jq '.hooks.Stop += [{"hooks":[{"type":"command","command":"\"$P/bin/heimdall-new-thing\" run; exit 0"}]}]' \
  "$HOOKS" > "$TMPROOT/more.json"
cp "$TMPROOT/meta.json" "$TMPROOT/meta-more.json"
rc="$(run_tool regen --hooks "$TMPROOT/more.json" --metadata "$TMPROOT/meta-more.json")"
NEW_IDX="$(jq '.hooks.Stop | length' "$HOOKS")"   # appended group lands at the old length
if [ "$rc" = "0" ] && grep -q "NEW   new-thing (Stop\[$NEW_IDX\])" "$TMPROOT/out" \
   && [ "$(jq -r --argjson i "$NEW_IDX" '.hooks[] | select(.event=="Stop" and .index==$i) | .locked' "$TMPROOT/meta-more.json")" = "false" ]; then
  ok "9. regen adds a NEW, unlocked entry for a group with no metadata"
else
  bad "9. regen did not add the new group (rc=$rc): $(cat "$TMPROOT/out")"
fi

# ── 10. check never writes hooks.json ───────────────────────────────────────
before="$(shasum -a 256 < "$TMPROOT/drift.json")"
run_tool check --hooks "$TMPROOT/drift.json" --metadata "$TMPROOT/meta.json" >/dev/null
run_tool regen --hooks "$TMPROOT/drift.json" --metadata "$TMPROOT/meta-regen.json" >/dev/null
after="$(shasum -a 256 < "$TMPROOT/drift.json")"
[ "$before" = "$after" ] && ok "10. neither check nor regen touches hooks.json" \
                         || bad "10. hooks.json was rewritten"

# ── 11. fail-open ONLY when hooks.json is unreadable ────────────────────────
rc="$(run_tool check --hooks "$TMPROOT/does-not-exist.json" --metadata "$TMPROOT/meta.json")"
if [ "$rc" = "0" ] && grep -q 'fail-open' "$TMPROOT/err"; then
  ok "11. unreadable hooks.json -> exit 0 with the reason on stderr"
else
  bad "11. unreadable hooks.json handled wrong (rc=$rc)"
fi
rc="$(run_tool check --hooks "$TMPROOT/hooks.json" --metadata "$TMPROOT/does-not-exist.json")"
[ "$rc" = "1" ] && ok "12. missing metadata is NOT fail-open (exit 1)" \
                || bad "12. missing metadata exited $rc"

# ── 13. every fingerprint in the committed sidecar is sha256(matcher\ncommand) ─
mismatch=0
while IFS=$'\t' read -r ev idx fp; do
  matcher="$(jq -r --arg e "$ev" --argjson i "$idx" '.hooks[$e][$i].matcher // ""' "$HOOKS")"
  cmd="$(jq -r --arg e "$ev" --argjson i "$idx" '[.hooks[$e][$i].hooks[].command] | join("\n")' "$HOOKS")"
  want="$(printf '%s\n%s' "$matcher" "$cmd" | shasum -a 256 | cut -d' ' -f1)"
  [ "$want" = "$fp" ] || mismatch=$((mismatch + 1))
done < <(jq -r '.hooks[] | [.event, (.index|tostring), .fingerprint] | @tsv' "$META")
[ "$mismatch" = "0" ] && ok "13. fingerprint formula independently reproduced with shasum for every entry" \
                      || bad "13. $mismatch fingerprint(s) do not match sha256(matcher + \\n + command)"

# ── 14. python syntax + bash -n on the lib ─────────────────────────────────
if python3 -m py_compile "$TOOL" 2>/dev/null && bash -n "$REPO/bin/lib/hook-enabled.sh"; then
  ok "14. tool compiles, lib parses"
else
  bad "14. syntax error in tool or lib"
fi

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
