#!/usr/bin/env bash
# ctx-meter.test.sh — acceptance for the CONTEXT METER (bin/heimdall-ctx-meter).
#
# THE MEASURED DEFECT THIS GUARDS (docs/analysis/token-spend-forensics.md, 2026-08-08)
# ------------------------------------------------------------------------------------
# 234 sessions / 3,830 requests / $1,103.05 over three weeks. ONE session accounts for
# $913.54 — 82.8% — because it ran 15 days at a MEAN context of 501,000 tokens (peak
# 998,857) and never restarted. $369.50 of that is recoverable by capping context at
# ~150K. The proof is the owner's own two days, same repo, same working style:
#
#     2026-08-05 · 476 reqs · 731,707 mean ctx -> $0.366  / request
#     2026-08-07 · 153 reqs · 118,678 mean ctx -> $0.0593 / request     = 6.17x cheaper
#
# Nothing was skipped on the cheaper day. Cost = turns x context; the turns are inherent
# to this repo's verification discipline, the context size is not. Above ~800K a second,
# separate cost appears: cache-creation jumps from ~13,320 tok/req to 42,183 (3.2x) —
# $118.92 more. A restart re-pays only ~35K of preamble (~$0.02).
#
# So drift is expensive and INVISIBLE. The meter's whole job is to make a session
# unable to reach 500K without the operator being told, while there is still time.
#
# WHAT THIS FILE PROVES — and why each proof is falsifiable
# --------------------------------------------------------
#   A. SILENT BELOW THE CEILING   — under 150K it prints NOTHING on either stream. A
#      meter that chatters every turn gets muted, and then it protects nobody; it would
#      also become context bloat, which would be an absurd way to fail.
#   B. CEILING SPEAKS             — at/over 150K: one clear line, carrying the MEASURED
#      cost of ignoring it ($0.366 vs $0.0593, 6.17x) — not an adjective.
#   C/D. CLIFF IS LOUD            — approaching and past 800K render a ruled block.
#   E. ESCALATION IS VISIBLE      — the severe render is structurally distinct from the
#      routine one, so it cannot scroll past as more of the same.
#   F/G/H. FAIL CLOSED            — no reading, a STALE reading, or a malformed record
#      must report NON_VERIFIED. An unreachable verifier is NEVER "fine". This is the
#      one that matters most: silently reporting a comfortable number is worse than
#      having no meter, because it actively buys confidence that was never measured.
#   I. NON_VERIFIED IS QUIET-SAFE — it says it once per session, never every turn.
#   J. ANTI-CHATTER               — above the ceiling it re-speaks on GROWTH, not on
#      every prompt; and a drop re-baselines so a later climb is not swallowed.
#   K. ONE SOURCE OF TRUTH        — the meter reads context_window.* from the SAME
#      statusLine stdin blob the status bar's CTX% gauge reads. A second estimator that
#      could disagree with the number on screen would be worse than none.
#   L. MODEL-VISIBLE, BOUNDED     — the model gets ONE short line (hook JSON on stdout) on
#      the prompt where a tier is crossed, and nothing below the ceiling or on a repeat.
#      It used to be "stderr only, never context": that kept the cost down and the warning
#      from everyone, because Claude Code shows a UserPromptSubmit hook's stderr to nobody
#      on exit 0.
#   M/N. ACTUALLY WIRED           — extracted from the REAL hooks/statusline.sh and the
#      REAL hooks/hooks.json UserPromptSubmit entry. This is the falsifier: a meter
#      wired to nothing is a file, not a gate. SessionStart-only would be useless —
#      drift happens mid-session, so it must fire per prompt.
#   O. NEVER ERRORS               — garbage on stdin still exits 0 on every verb. This
#      runs in the prompt path; it must never be able to break a turn.
#   P. HERMETIC                   — the real ~/.heimdall is never touched.
#   R. GATE                       — a NEW machine-checkable verb (2026-09-08): may
#      NEW work start? Real exit code (0=proceed, 1=refuse), gated on REAL process/
#      filesystem facts (a live agent, an uncommitted change) — never refuses below
#      the hard ceiling, never refuses while work is in flight, and fails OPEN the
#      instant the boundary itself cannot be verified.
#   S. IDLE RETURN                — a session back after the prompt cache's hour with >=150K
#      in context is told ONCE, in one model-visible line, that this turn re-writes it all
#      and that /hmd:save (which ends on the /compact line) or /compact first is nearly free. Silent when the gap is short,
#      the context small, or the gap cannot be established.
#
# Usage:  bash test/ctx-meter.test.sh    (exit 0 = every proof holds)
#
# budget: 70 s solo (63 s measured with section S): about 170 hermetic runs of the meter,
# each starting an interpreter, plus the 2 s alarm of the idle-stdin cases.

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SELF_DIR/.." && pwd)"
METER="$REPO/bin/heimdall-ctx-meter"
HOOKS="$REPO/hooks/hooks.json"
STATUSLINE="$REPO/hooks/statusline.sh"

# The model channel is hook JSON; reading it back needs jq (section M already did).
command -v jq >/dev/null 2>&1 || { echo "FATAL: jq is required"; exit 1; }

PASS=0; FAIL=0
ok()  { printf '  \033[32mPASS\033[0m %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAIL=$((FAIL + 1)); }
sec() { printf '\n%s\n' "$1"; }

# ── hermetic state root: the real ~/.heimdall is NEVER written ────────────────────
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export HEIMDALL_HOME="$TMP/heimdall-home"
SID="ctxtest-$$"
REAL_HOME_CTX="$HOME/.heimdall/ctx"

# A synthetic statusLine stdin blob, exactly the shape Claude Code hands the status bar.
blob() { # <tokens> [session] [window]
  local tok="$1" sid="${2:-$SID}" win="${3:-1000000}" pct
  pct=$(awk -v t="$tok" -v w="$win" 'BEGIN{ printf "%.4f", (w>0? t*100.0/w : 0) }')
  printf '{"session_id":"%s","cwd":"%s","model":{"display_name":"Opus 5"},"context_window":{"total_input_tokens":%s,"context_window_size":%s,"used_percentage":%s}}' \
    "$sid" "$REPO" "$tok" "$win" "$pct"
}

publish() { blob "$@" | "$METER" publish >/dev/null 2>&1; }

# Capture the two streams SEPARATELY — proof L depends on telling them apart.
OUT=""; ERR=""; RC=0
notice() { # [session]
  local sid="${1:-$SID}"
  OUT="$(printf '{"session_id":"%s","prompt":"do the thing"}' "$sid" \
        | "$METER" notice 2>"$TMP/err.txt")"; RC=$?
  ERR="$(cat "$TMP/err.txt" 2>/dev/null)"
}
both() { printf '%s%s' "$OUT" "$ERR"; }

has()   { grep -qF "$2" <<<"$1"; }
hasre() { grep -qE "$2" <<<"$1"; }
hasrei(){ grep -qiE "$2" <<<"$1"; }   # case-insensitive: renders SHOUT

# The model channel: notice's STDOUT, a hook JSON object whose additionalContext is what the model reads.
ctx_text() { jq -r '.hookSpecificOutput.additionalContext // empty' <<<"$1" 2>/dev/null; }
ctx_line() { ctx_text "$OUT"; }
lines_of() { printf '%s\n' "$1" | grep -c .; }     # non-empty lines in a string
commas()   { printf '%s' "$1" | sed -e :a -e 's/\(.*[0-9]\)\([0-9]\{3\}\)/\1,\2/;ta'; }

# ── 0. the binary exists and is executable ───────────────────────────────────────
sec "0. THE METER EXISTS:"
if [ -x "$METER" ]; then ok "bin/heimdall-ctx-meter is executable"
else bad "bin/heimdall-ctx-meter missing or not executable"; printf '\nctx-meter.test.sh: %s passed, %s failed.\n' "$PASS" "$((FAIL+1))"; exit 1; fi

# ── A. SILENT below the ceiling ──────────────────────────────────────────────────
sec "A. SILENT BELOW THE CEILING (a meter that chatters gets muted):"
publish 118678                      # the measured CHEAP day: 2026-08-07
notice
[ -z "$(both)" ] && ok "118,678 tok (the measured cheap day) -> absolutely nothing printed" \
                 || bad "spoke below the ceiling: $(both)"
[ "$RC" = 0 ] && ok "exit 0 when silent" || bad "exit $RC when silent"

publish 149999
notice
[ -z "$(both)" ] && ok "149,999 tok -> still silent (boundary is exclusive below)" \
                 || bad "spoke at 149,999: $(both)"

# ── B. CEILING speaks, with the MEASURED cost ────────────────────────────────────
sec "B. CEILING (150K) SPEAKS — and quotes the measurement, not an adjective:"
rm -rf "$HEIMDALL_HOME"; publish 214000
notice
CEIL="$(both)"
[ -n "$CEIL" ] && ok "214,000 tok -> the meter speaks" || bad "silent at 214,000 tok"
has "$CEIL" '0.366'  && ok "states \$0.366/req (measured at 731K context)"   || bad "missing the \$0.366 figure"
has "$CEIL" '0.0593' && ok "states \$0.0593/req (measured at 118K context)"  || bad "missing the \$0.0593 figure"
has "$CEIL" '6.17'   && ok "states the 6.17x multiple"                        || bad "missing the 6.17x multiple"
hasre "$CEIL" '150|150,000|150K' && ok "names the 150K ceiling"               || bad "never names the ceiling"
hasre "$CEIL" 'save|checkpoint'  && ok "tells the operator to save/checkpoint" || bad "no save/checkpoint instruction"
has    "$CEIL" '/hmd:save' && ok "names /hmd:save explicitly (mandatory at every tier that speaks)" || bad "does not explicitly name /hmd:save"
has    "$CEIL" '/compact'  && ok "recommends /compact as the primary remedy"  || bad "does not recommend /compact"
hasrei "$CEIL" 'restart'   && bad "CEILING notice still defaults to a restart (compact should be primary here)" \
                            || ok "CEILING notice does not default to a restart (compact is primary; fresh session is CLIFF-only)"
hasre "$CEIL" '214,000|214000'   && ok "reports the ACTUAL current reading"   || bad "does not report the reading"

# ── C. approaching the cliff — LOUD ──────────────────────────────────────────────
sec "C. APPROACHING THE 800K CACHE CLIFF — loud:"
rm -rf "$HEIMDALL_HOME"; publish 720000
notice
NEAR="$(both)"
[ -n "$NEAR" ] && ok "720,000 tok -> speaks" || bad "silent at 720,000 tok"
has "$NEAR" '━'    && ok "renders a ruled block (visually distinct)" || bad "no ruled block near the cliff"
hasre "$NEAR" '800' && ok "names the 800K cliff it is approaching"   || bad "does not name the cliff"
has    "$NEAR" '/hmd:save' && ok "CLIFF_NEAR notice names /hmd:save (mandatory at every tier that speaks)" || bad "CLIFF_NEAR notice missing /hmd:save"
has    "$NEAR" '/compact'  && ok "CLIFF_NEAR notice recommends /compact as the primary remedy" || bad "CLIFF_NEAR notice does not recommend /compact"
hasrei "$NEAR" 'restart'   && bad "CLIFF_NEAR notice mentions a restart -- reserved for the CLIFF extreme case only" \
                            || ok "CLIFF_NEAR notice correctly never mentions a restart (fresh session is CLIFF-only)"

# ── D. past the cliff — LOUD, with the measured 3.2x ─────────────────────────────
sec "D. PAST THE 800K CLIFF — loud, and quotes the cache-write measurement:"
rm -rf "$HEIMDALL_HOME"; publish 812000
notice
CLIFF="$(both)"
[ -n "$CLIFF" ] && ok "812,000 tok -> speaks" || bad "silent at 812,000 tok"
has "$CLIFF" '━'      && ok "renders a ruled block"                     || bad "no ruled block past the cliff"
has "$CLIFF" '42,183' && ok "states 42,183 cache-create tok/req (q5)"   || bad "missing the 42,183 figure"
has "$CLIFF" '13,320' && ok "states the 13,320 baseline (q2-q4)"        || bad "missing the 13,320 baseline"
has "$CLIFF" '3.2'    && ok "states the measured 3.2x jump"             || bad "missing the 3.2x jump"
has    "$CLIFF" '/hmd:save' && ok "CLIFF notice names /hmd:save (mandatory at every tier that speaks)" || bad "CLIFF notice missing /hmd:save"
has    "$CLIFF" '/compact'  && ok "CLIFF notice recommends /compact first, even at the hard ceiling" || bad "CLIFF notice does not recommend /compact"
hasrei "$CLIFF" 'fresh session' && ok "CLIFF notice offers a fresh session as fallback -- the one tier where that is appropriate" \
                                 || bad "CLIFF notice dropped the fresh-session fallback for the one tier that should keep it"

# ── E. the severe case is STRUCTURALLY distinct from the routine one ─────────────
sec "E. ESCALATION IS VISIBLE (severe != more of the same):"
if has "$CLIFF" '━' && ! has "$CEIL" '━'; then
  ok "cliff renders a ruled block, ceiling does not — the escalation is structural"
else
  bad "ceiling and cliff render alike; a severe notice would scroll past as routine"
fi
CEIL_N=$(printf '%s\n' "$CEIL" | grep -c .); CLIFF_N=$(printf '%s\n' "$CLIFF" | grep -c .)
[ "$CLIFF_N" -gt "$CEIL_N" ] && ok "cliff notice is larger than ceiling ($CLIFF_N vs $CEIL_N lines)" \
                             || bad "cliff notice is not larger than the ceiling notice"

# ── F. NO READING -> NON_VERIFIED, never "fine" ──────────────────────────────────
sec "F. UNREADABLE -> NON_VERIFIED (an unreachable verifier is never OPEN):"
rm -rf "$HEIMDALL_HOME"
JSON="$("$METER" read --session "$SID" --json 2>/dev/null)"
has "$JSON" 'NON_VERIFIED' && ok "no published reading -> state=NON_VERIFIED" \
                           || bad "no reading did NOT report NON_VERIFIED: $JSON"
hasre "$JSON" '"state"[[:space:]]*:[[:space:]]*"OK"' && bad "reported OK with no reading (FAILS OPEN)" \
                                                     || ok "never reports OK without a reading"
notice
NV="$(both)"
[ -n "$NV" ] && ok "the operator is TOLD the meter is blind" || bad "silently blind — the exact fail-open this forbids"
hasrei "$NV" 'cannot read|unreadable|cannot see' && ok "says it cannot see, in plain words" \
                                                 || bad "does not say it cannot see: $NV"
hasrei "$NV" 'not telling you that you are fine|is NOT reporting' \
  && ok "explicitly refuses to imply things are fine" \
  || bad "blind notice does not rule out a comfortable reading: $NV"

# ── G. STALE reading -> NON_VERIFIED ─────────────────────────────────────────────
sec "G. STALE READING -> NON_VERIFIED (an old number is not a current one):"
rm -rf "$HEIMDALL_HOME"
NOW="$(date +%s)"
HMD_CTX_NOW="$NOW" publish 900000                 # a CLIFF-level reading...
JSON="$(HMD_CTX_NOW="$((NOW + 4000))" "$METER" read --session "$SID" --json 2>/dev/null)"
has "$JSON" 'NON_VERIFIED' && ok "a reading older than the TTL -> NON_VERIFIED, not CLIFF" \
                           || bad "stale reading was trusted: $JSON"
hasre "$JSON" 'stale' && ok "names staleness as the reason" || bad "does not name staleness: $JSON"

# ── H. MALFORMED record -> NON_VERIFIED ──────────────────────────────────────────
sec "H. MALFORMED RECORD -> NON_VERIFIED (never a comfortable number):"
rm -rf "$HEIMDALL_HOME"; publish 300000
REC="$(find "$HEIMDALL_HOME" -name "*.json" -type f 2>/dev/null | head -1)"
if [ -n "$REC" ]; then
  ok "publish wrote a record under HEIMDALL_HOME"
  printf 'not json at all {{{\n' > "$REC"
  JSON="$("$METER" read --session "$SID" --json 2>/dev/null)"
  has "$JSON" 'NON_VERIFIED' && ok "corrupt record -> NON_VERIFIED" || bad "corrupt record was trusted: $JSON"
  RC2=0; "$METER" read --session "$SID" --json >/dev/null 2>&1 || RC2=$?
  [ "$RC2" != 139 ] && ok "does not crash on a corrupt record" || bad "crashed on a corrupt record"
else
  bad "publish wrote no record under HEIMDALL_HOME"
fi

# ── I. NON_VERIFIED is quiet-safe: once per session, not every turn ──────────────
sec "I. NON_VERIFIED SPEAKS ONCE (blind must not become wallpaper):"
rm -rf "$HEIMDALL_HOME"
notice; FIRST="$(both)"
notice; SECOND="$(both)"
[ -n "$FIRST" ]  && ok "first blind prompt -> told"        || bad "never told"
[ -z "$SECOND" ] && ok "second blind prompt -> silent (once per session)" \
                 || bad "repeats every turn — would be muted: $SECOND"

# ── J. anti-chatter above the ceiling: re-speak on GROWTH ────────────────────────
sec "J. ANTI-CHATTER — above the ceiling it re-speaks on GROWTH, not per prompt:"
rm -rf "$HEIMDALL_HOME"
publish 200000; notice; A="$(both)"
publish 200000; notice; B="$(both)"
publish 205000; notice; C="$(both)"
publish 320000; notice; D="$(both)"
[ -n "$A" ] && ok "entering the ceiling band -> speaks"            || bad "did not speak on entry"
[ -z "$B" ] && ok "same reading again -> silent"                   || bad "repeated at an unchanged reading"
[ -z "$C" ] && ok "+5K growth -> still silent"                     || bad "spoke on trivial growth"
[ -n "$D" ] && ok "+120K growth -> speaks again (re-armed)"        || bad "went silent across a 120K climb"
# a DROP (a compact/restart) must re-baseline, or the next climb is swallowed
publish 160000; notice; E="$(both)"
publish 275000; notice; F="$(both)"
[ -z "$E" ] && ok "a drop after a compact -> silent (no noise on good news)" || bad "nagged right after a compact"
[ -n "$F" ] && ok "climbing again after the drop -> speaks (re-baselined)"   || bad "a post-compact climb was swallowed"
# the cliff is an emergency: it speaks EVERY prompt
rm -rf "$HEIMDALL_HOME"
publish 850000; notice; G="$(both)"
notice; H="$(both)"
[ -n "$G" ] && [ -n "$H" ] && ok "past the cliff it speaks every prompt (emergency)" \
                           || bad "cliff notice was suppressed by the cooldown"

# ── K. ONE SOURCE OF TRUTH — the statusLine blob the CTX% gauge reads ────────────
sec "K. SAME SOURCE AS THE STATUS BAR (no second estimator that could disagree):"
grep -q 'context_window' "$METER" && ok "reads context_window.* — the statusLine blob field" \
                                  || bad "does not read context_window.*"
grep -q 'total_input_tokens' "$METER" && ok "reads total_input_tokens (the gauge's own token field)" \
                                      || bad "does not read total_input_tokens"
grep -q 'total_input_tokens' "$REPO/sentinels/hmd-statusline.py" \
  && ok "sentinels/hmd-statusline.py reads the SAME field (single source confirmed)" \
  || bad "the watchman no longer reads total_input_tokens — sources have diverged"
# used_percentage x window is the documented fallback when the absolute count is absent
rm -rf "$HEIMDALL_HOME"
printf '{"session_id":"%s","context_window":{"used_percentage":42.0,"context_window_size":1000000}}' "$SID" \
  | "$METER" publish >/dev/null 2>&1
JSON="$("$METER" read --session "$SID" --json 2>/dev/null)"
hasre "$JSON" '"tokens"[[:space:]]*:[[:space:]]*420000[^0-9]' \
  && ok "derives tokens from used_percentage x window when the count is absent (42% of 1M = 420,000)" \
  || bad "no percentage fallback: $JSON"
# ...but a blob with NO context signal at all must NOT become a comfortable zero
rm -rf "$HEIMDALL_HOME"
printf '{"session_id":"%s"}' "$SID" | "$METER" publish >/dev/null 2>&1
JSON="$("$METER" read --session "$SID" --json 2>/dev/null)"
has "$JSON" 'NON_VERIFIED' && ok "a blob with no context signal -> NON_VERIFIED, not 0 tokens" \
                           || bad "an absent context signal became a comfortable number: $JSON"

# ── L. the MODEL gets ONE short line when a tier is crossed — and nothing else ───
# This section used to prove the opposite: "stdout empty — nothing injected into the model's
# context". That was the defect, not the safeguard. Claude Code shows a UserPromptSubmit
# hook's stderr to nobody on exit 0, so the meter spoke correctly for 72 days (that session's
# .notice file says CEILING) into a stream neither the operator nor the model reads: zero
# `[heimdall] CONTEXT` strings in its transcript
# (docs/analysis/2026-11-22-token-utilization-next.md §4). The cost worry it encoded still
# stands, so the model channel is BOUNDED instead of banned: one line, as hook JSON on stdout
# (hookSpecificOutput.additionalContext, the shape bin/lib/hmd_finished_agents.py emits), on
# the prompt where something new is true, and nowhere else — an injected line stays in the
# conversation and is read again on every later turn. The full render stays on stderr, for an
# operator at a terminal.
sec "L. MODEL-VISIBLE: ONE SHORT LINE, ONLY WHEN A TIER IS CROSSED:"
for L_TOK in 214000 720000 812000; do
  rm -rf "$HEIMDALL_HOME"; publish "$L_TOK"
  notice
  L_TXT="$(ctx_line)"
  if [ "$(lines_of "$OUT")" = 1 ] && jq -e '.hookSpecificOutput.hookEventName == "UserPromptSubmit"' <<<"$OUT" >/dev/null 2>&1; then
    ok "$L_TOK tok: stdout is ONE line of UserPromptSubmit hook JSON"
  else
    bad "$L_TOK tok: stdout is not one line of hook JSON: '$OUT'"
  fi
  hasre "$L_TXT" '^\[heimdall\] CONTEXT ' && has "$L_TXT" "$(commas "$L_TOK")" \
    && ok "$L_TOK tok: the line says CONTEXT and carries the reading" \
    || bad "$L_TOK tok: the model line is missing or lacks the reading: '$L_TXT'"
  has "$L_TXT" '/hmd:save' && has "$L_TXT" '/compact' \
    && ok "$L_TOK tok: it names the remedy (/hmd:save, then /compact)" \
    || bad "$L_TOK tok: the model line names no remedy: '$L_TXT'"
  hasrei "$L_TXT" 'restart' && bad "$L_TOK tok: the model line mentions a restart" \
                            || ok "$L_TOK tok: no restart advice (compaction is the primary remedy)"
  [ "$(lines_of "$L_TXT")" = 1 ] && [ "${#L_TXT}" -le 300 ] \
    && ok "$L_TOK tok: ONE short line (${#L_TXT} chars)" \
    || bad "$L_TOK tok: not one short line (${#L_TXT} chars): '$L_TXT'"
  [ -n "$ERR" ] && ok "$L_TOK tok: the full render is still spoken on stderr" \
                || bad "$L_TOK tok: nothing on stderr"
  [ "$RC" = 0 ] && ok "$L_TOK tok: exit 0" || bad "$L_TOK tok: exit $RC"
done
# Not per turn. The cliff block on stderr speaks every prompt (an emergency is not
# rate-limited); the model already holds the line it was told, so it is not told twice.
rm -rf "$HEIMDALL_HOME"; publish 812000
notice; notice
[ -z "$OUT" ] && [ -n "$ERR" ] \
  && ok "past the cliff, the 2nd prompt: stderr speaks again, the model is not told twice" \
  || bad "the 2nd prompt past the cliff told the model again, or said nothing on stderr: out='$OUT'"
# Something NEW is true on a climb into a higher tier, and on a +100K climb inside the band
# (the same re-arm stderr uses); a step down (a compaction) is good news and tells it nothing.
rm -rf "$HEIMDALL_HOME"
publish 200000; notice; L_A="$OUT"
publish 205000; notice; L_B="$OUT"
publish 330000; notice; L_C="$OUT"
publish 720000; notice; L_D="$OUT"
publish 812000; notice; L_E="$OUT"
publish 750000; notice; L_F="$OUT"
publish 400000; notice; L_G="$OUT"
[ -n "$L_A" ] && ok "entering the ceiling band tells the model"                       || bad "no model line on entering the band"
[ -z "$L_B" ] && ok "+5K inside the band: nothing new, the model is not told"         || bad "told the model again at +5K: '$L_B'"
[ -n "$L_C" ] && ok "+125K inside the band re-arms: told again"                       || bad "no model line at +125K"
if [ -n "$L_D" ] && has "$(ctx_text "$L_D")" '800,000'; then ok "climbing to 700K tells it, naming the 800,000 cliff"
else bad "no model line naming the cliff at 720K: '$L_D'"; fi
[ -n "$L_E" ] && ok "climbing past 800K tells it"                                    || bad "no model line past the cliff"
[ -z "$L_F" ] && ok "stepping DOWN a tier (a compaction) tells the model nothing"     || bad "told the model on a step down: '$L_F'"
[ -z "$L_G" ] && ok "dropping from a cliff tier into the ceiling band tells the model nothing" || bad "told the model on a drop into the band: '$L_G'"
# and the blind notice — the one that fires precisely when nothing can be measured
rm -rf "$HEIMDALL_HOME"
notice
[ -z "$OUT" ] && ok "NON_VERIFIED: stdout empty" || bad "the blind notice wrote to stdout: $OUT"
[ -n "$ERR" ] && ok "NON_VERIFIED: spoken on stderr" || bad "the blind notice printed nothing at all"

# ── M. WIRED into the REAL per-prompt hook (SessionStart-only would be useless) ──
sec "M. WIRED @ UserPromptSubmit — the hook that fires per prompt:"
UPS_CMD="$(jq -r '.hooks.UserPromptSubmit[]?.hooks[]?.command // empty' "$HOOKS" 2>/dev/null \
          | grep -F 'heimdall-ctx-meter' | head -1)"
if [ -n "$UPS_CMD" ]; then
  ok "a UserPromptSubmit hook invokes heimdall-ctx-meter"
  rm -rf "$HEIMDALL_HOME"; publish 880000
  HOOK_JSON="$(cd "$REPO" && printf '{"session_id":"%s","prompt":"go"}' "$SID" \
    | CLAUDE_PLUGIN_ROOT="$REPO" HEIMDALL_HOME="$HEIMDALL_HOME" sh -c "$UPS_CMD" 2>"$TMP/hook-err.txt")"
  HOOK_RC=$?
  HOOK_OUT="$HOOK_JSON$(cat "$TMP/hook-err.txt" 2>/dev/null)"
  has "$HOOK_OUT" '━' && ok "the REAL wired hook command fires the cliff notice" \
                      || bad "wired hook produced no notice: $HOOK_OUT"
  # what Claude Code actually reads from a UserPromptSubmit hook: stdout, parsed as hook JSON
  jq -e '.hookSpecificOutput.hookEventName == "UserPromptSubmit" and (.hookSpecificOutput.additionalContext | startswith("[heimdall] CONTEXT"))' \
    <<<"$HOOK_JSON" >/dev/null 2>&1 \
    && ok "the REAL wired hook's STDOUT alone is the model line, as hook JSON (stderr is not mixed into it)" \
    || bad "the wired hook's stdout is not the model's hook JSON: '$HOOK_JSON'"
  [ "$HOOK_RC" = 0 ] && ok "the wired hook exits 0 (never blocks a prompt)" || bad "wired hook exit $HOOK_RC"
  # below the ceiling the same wired command must stay silent
  rm -rf "$HEIMDALL_HOME"; publish 90000
  QUIET="$(cd "$REPO" && printf '{"session_id":"%s","prompt":"go"}' "$SID" \
    | CLAUDE_PLUGIN_ROOT="$REPO" HEIMDALL_HOME="$HEIMDALL_HOME" sh -c "$UPS_CMD" 2>&1)"
  [ -z "$QUIET" ] && ok "the wired hook is silent below the ceiling" || bad "wired hook chatters: $QUIET"
else
  bad "NOT WIRED — no UserPromptSubmit hook calls heimdall-ctx-meter (a meter wired to nothing is a file)"
fi

# ── N. WIRED into the statusline — the only place context is exposed ─────────────
# BEHAVIOR, not mechanism. This used to gate on `grep -q 'heimdall-ctx-meter'
# "$STATUSLINE"` — i.e. the publish call had to appear as a literal line inside
# hooks/statusline.sh itself. The CLI-agnostic-renderer refactor (feat 80a5c4c) made
# hooks/statusline.sh a thin `exec` wrapper into the shared bin/heimdall-statusline,
# and the CTX_METER block moved one level down with it — the grep then found nothing
# in the wrapper and reported NOT WIRED even though the publisher still runs end to
# end. Drive the REAL entry point Claude Code registers as `statusLine`
# (hooks/statusline.sh — see that file's own comment on why the path must never
# move) with a payload carrying real context tokens, and check for the resulting
# on-disk record. That is what "wired" means: it survives a refactor that relocates
# the code as long as the behavior still holds, and it still fails the moment the
# publish call is deleted from either file, because the wrapper always execs
# straight into the renderer that holds it.
sec "N. WIRED @ statusline — the publisher, because only the bar sees context:"
rm -rf "$HEIMDALL_HOME"
blob 456000 "$SID" | HEIMDALL_HOME="$HEIMDALL_HOME" bash "$STATUSLINE" >/dev/null 2>&1
JSON="$("$METER" read --session "$SID" --json 2>/dev/null)"
hasre "$JSON" '"tokens"[[:space:]]*:[[:space:]]*456000' \
  && ok "driving the REAL statusline entry point published the reading (456,000)" \
  || bad "NOT WIRED — hooks/statusline.sh does not publish a reading: $JSON"

# ── O. never errors, on any verb, with garbage ───────────────────────────────────
sec "O. NEVER ERRORS (it runs in the prompt path):"
for VERB in publish read notice; do
  RC3=0; printf 'garbage not json \x01\x02' | "$METER" "$VERB" >/dev/null 2>&1 || RC3=$?
  [ "$RC3" = 0 ] && ok "$VERB exits 0 on garbage stdin" || bad "$VERB exited $RC3 on garbage stdin"
done
RC3=0; "$METER" no-such-verb >/dev/null 2>&1 || RC3=$?
[ "$RC3" != 0 ] && ok "an unknown verb is a real error (exit $RC3), not a silent no-op" \
                || bad "unknown verb silently succeeded"
RC3=0; printf '' | "$METER" notice >/dev/null 2>&1 || RC3=$?
[ "$RC3" = 0 ] && ok "notice exits 0 on EMPTY stdin" || bad "notice exited $RC3 on empty stdin"

# NEVER BLOCKS THE PROMPT. Regression for a measured 8s stall: a hook's stdin can be
# open-but-idle, and an unbounded `cat` there blocks the turn itself. A meter that can
# hang a prompt is far worse than the drift it watches for.
FIFO="$TMP/idle.fifo"
rm -f "$FIFO"; mkfifo "$FIFO" 2>/dev/null
if [ -p "$FIFO" ]; then
  rm -rf "$HEIMDALL_HOME"; publish 500000
  ( exec 9>"$FIFO"; sleep 8 ) &            # holds the write end open, sends nothing
  HOLDER=$!
  S=$(date +%s); "$METER" read --session "$SID" --json >/dev/null 2>&1 < "$FIFO"; E=$(date +%s)
  D=$((E - S))
  [ "$D" -le 3 ] && ok "read returns in ${D}s on an idle-but-open stdin (does not wait it out)" \
                 || bad "read blocked ${D}s on an idle stdin — would stall the prompt"
  kill "$HOLDER" 2>/dev/null; wait "$HOLDER" 2>/dev/null

  ( exec 9>"$FIFO"; sleep 8 ) &
  HOLDER=$!
  S=$(date +%s); "$METER" notice --session "$SID" >/dev/null 2>&1 < "$FIFO"; E=$(date +%s)
  D=$((E - S))
  [ "$D" -le 4 ] && ok "notice is time-boxed on an idle stdin (${D}s, not 8s)" \
                 || bad "notice blocked ${D}s on an idle stdin — would stall every prompt"
  kill "$HOLDER" 2>/dev/null; wait "$HOLDER" 2>/dev/null
  rm -f "$FIFO"
else
  bad "could not create a fifo — the prompt-blocking regression went unproven"
fi

# ── P. hermetic — the real ~/.heimdall was never touched ─────────────────────────
sec "P. HERMETIC (the real ~/.heimdall is never written):"
if [ -d "$REAL_HOME_CTX" ] && find "$REAL_HOME_CTX" -name "*$SID*" 2>/dev/null | grep -q .; then
  bad "leaked a record for $SID into the real $REAL_HOME_CTX"
else
  ok "no test record leaked into the real ~/.heimdall"
fi
[ -d "$HEIMDALL_HOME" ] && ok "state stayed under the overridden HEIMDALL_HOME" \
                        || bad "HEIMDALL_HOME override was not honored"

# ── Q. OUTPUT-TOKEN SHARE (outshare) — the measurement blocker, now falsifiable ──
# Caveman/hmd output compression narrows OUTPUT wording. Its ceiling is bounded by
# whatever share of total token spend is even OUTPUT — before this verb, NOTHING
# in this repo measured that share: headroom's own ledger carries
# output_tokens_saved permanently at 0, and .planning/metrics.jsonl carries only
# parallelism fields. `outshare` sums every local session transcript's real
# message.usage (reusing heimdall-tokens' sum_session — Q6, no second parser) and
# checks it against headroom's external lifetime.total_input_tokens.
sec "Q. OUTPUT-TOKEN SHARE (outshare) — the measurement blocker, now falsifiable:"

FIXROOT="$TMP/outshare-fixtures"
PROJ_A="$FIXROOT/projects/proj-a"
PROJ_B="$FIXROOT/projects/proj-b"
mkdir -p "$PROJ_A" "$PROJ_B"

usage_line() { # <input> <output> <cache_creation> <cache_read>
  printf '{"type":"assistant","sessionId":"fix","message":{"usage":{"input_tokens":%s,"output_tokens":%s,"cache_creation_input_tokens":%s,"cache_read_input_tokens":%s}}}\n' \
    "$1" "$2" "$3" "$4"
}

{
  printf '{"type":"user","message":{"content":"hi"}}\n'   # no usage -> must not count as a turn
  usage_line 1000 100 50 20
  usage_line 2000 300 0  80
} > "$PROJ_A/sess1.jsonl"

{
  usage_line 500 50 10 0
} > "$PROJ_B/sess2.jsonl"

printf 'not json at all\nstill not json\n' > "$PROJ_B/garbage.jsonl"  # unparseable -> excluded from sessions_scanned
printf 'input_tokens=999999\n' > "$PROJ_B/notes.txt"                  # wrong extension -> must never be opened

HEADROOM_OK="$FIXROOT/headroom-ok.json"
printf '{"lifetime":{"total_input_tokens":4130110220}}\n' > "$HEADROOM_OK"
HEADROOM_MISSING="$FIXROOT/no-such-headroom-ledger.json"

# Q1/Q2: exact arithmetic — a stub or a hardcoded number cannot satisfy this.
OJ="$(HMD_CTX_PROJECTS_ROOT="$FIXROOT/projects" HMD_HEADROOM_LEDGER="$HEADROOM_OK" "$METER" outshare --json 2>/dev/null)"
EXPECT="$(python3 -c '
import json
inp, outp, cc, cr = 3500, 450, 60, 100
local_total = inp + outp + cc + cr
ext = 4130110220
print(json.dumps({
  "local_input_tokens": inp, "local_output_tokens": outp,
  "local_cache_creation_tokens": cc, "local_cache_read_tokens": cr,
  "local_total_tokens": local_total,
  "output_share_of_local_total": outp / local_total,
  "external_lifetime_input_tokens": ext,
  "output_share_vs_external_lifetime_input": outp / ext,
}))
' 2>/dev/null)"
CMP="$(python3 -c '
import json, sys
got = json.loads(sys.argv[1]); want = json.loads(sys.argv[2])
bad = []
for k, v in want.items():
    g = got.get(k)
    if isinstance(v, float):
        if g is None or abs(g - v) > 1e-9:
            bad.append("%s: got %r want %r" % (k, g, v))
    elif g != v:
        bad.append("%s: got %r want %r" % (k, g, v))
print("OK" if not bad else "; ".join(bad))
' "$OJ" "$EXPECT" 2>/dev/null)"
[ "$CMP" = "OK" ] && ok "outshare sums real usage across 2 files exactly (input/output/cache/local-share/external-share)" \
                   || bad "outshare arithmetic wrong: $CMP" "$OJ"

echo "$OJ" | python3 -c 'import json,sys
d=json.load(sys.stdin); sys.exit(0 if d.get("state")=="OK" else 1)' 2>/dev/null \
  && ok "state=OK when transcripts + ledger both resolve" || bad "state was not OK" "$OJ"

SCANNED="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["sessions_scanned"])' <<<"$OJ" 2>/dev/null)"
[ "$SCANNED" = "2" ] && ok "sessions_scanned=2 — the all-garbage file and the wrong-extension file are both excluded" \
                      || bad "sessions_scanned wrong (garbage/extension filtering broken)" "got '$SCANNED'"

# Q3: independence — a missing/unreadable headroom ledger degrades ONLY the
# external-comparison fields; the local measurement must not be dragged down.
OJ_NOEXT="$(HMD_CTX_PROJECTS_ROOT="$FIXROOT/projects" HMD_HEADROOM_LEDGER="$HEADROOM_MISSING" "$METER" outshare --json 2>/dev/null)"
python3 -c '
import json, sys
d = json.loads(sys.argv[1])
assert d["state"] == "OK"
assert d["local_output_tokens"] == 450
assert d.get("external_lifetime_input_tokens") is None
assert d.get("output_share_vs_external_lifetime_input") is None
' "$OJ_NOEXT" 2>/dev/null \
  && ok "a missing headroom ledger nulls ONLY the external-comparison fields (local share still measured)" \
  || bad "missing ledger corrupted the local measurement too" "$OJ_NOEXT"

# Q4: no transcripts anywhere -> NON_VERIFIED, never a fabricated zero share.
EMPTYROOT="$TMP/outshare-empty"; mkdir -p "$EMPTYROOT"
OJ_EMPTY="$(HMD_CTX_PROJECTS_ROOT="$EMPTYROOT" HMD_HEADROOM_LEDGER="$HEADROOM_OK" "$METER" outshare --json 2>/dev/null)"
has "$OJ_EMPTY" '"state":"NON_VERIFIED"' && has "$OJ_EMPTY" 'no-transcripts' \
  && ok "zero transcripts -> NON_VERIFIED (reason no-transcripts), never a fabricated 0% share" \
  || bad "empty projects root did not fail closed" "$OJ_EMPTY"

# Q5: human-readable mode is labeled, not a bare number dump.
OH="$(HMD_CTX_PROJECTS_ROOT="$FIXROOT/projects" HMD_HEADROOM_LEDGER="$HEADROOM_OK" "$METER" outshare 2>/dev/null)"
hasrei "$OH" 'sessions scanned' && hasrei "$OH" 'output share' \
  && ok "human-readable mode labels its numbers (sessions scanned / output share)" \
  || bad "human-readable outshare output is not labeled" "$OH"

# Q6: NO SECOND PARSER — outshare must compose with heimdall-tokens' sum_session,
# never re-implement usage-extraction. Proof K's single-source-of-truth rule
# applies to output tokens exactly as much as it does to context tokens.
if grep -q 'heimdall-tokens' "$METER" && ! grep -qE 'def[[:space:]]+sum_session|_extract_usage' "$METER"; then
  ok "outshare composes with heimdall-tokens (sum_session) rather than re-parsing usage itself"
else
  bad "outshare either does not reuse heimdall-tokens or re-implements its parser"
fi

# Q7: discoverable — --help names the new verb (also proves the help-range bump
# past this insertion is correct, not silently truncated).
HELP="$("$METER" --help 2>/dev/null)"
has "$HELP" 'outshare' && ok "--help documents the outshare verb" \
                        || bad "--help does not mention outshare"

# Q8: fail-closed when the resolved interpreter cannot actually run.
#
# This deliberately does NOT try to hide python3 from PATH. bin/lib/hmd-python.sh
# (lines 22-27, 74-79) probes the hardcoded absolute path /usr/bin/python3 BEFORE
# any PATH search, by design -- a documented perf optimization, not an oversight.
# On any host where /usr/bin/python3 is real and working -- this one included --
# PATH-stripping cannot simulate "no python anywhere": hmd_python() finds it
# directly, no PATH lookup involved. Confirmed empirically on this machine:
# /usr/bin/python3 is a real, executable ~118KB binary, independent of whatever
# shim `command -v python3` resolves to. A prior version of this test stripped
# PATH by collecting coreutil directories and asserted a false precondition on
# every run on this class of host, for exactly this reason.
#
# hmd-python.sh ships its own documented test seam instead: HMD_PYTHON, "honoured
# without probing" (hmd-python.sh:55-60) so a test does not have to pay the 31ms
# probe cost the file exists to avoid paying on every hook call. Pointing it at a
# path that does not exist makes hmd_python() hand back an interpreter that cannot
# run -- exactly what a caller gets on a host where the resolved python turns out
# broken -- and reaches the same fail-closed guarantee (never fabricate a share)
# through a door that is reachable on every host, not just python-less ones. The
# "truly zero interpreters anywhere" branch (command -v python3 also absent) stays
# in the implementation for genuinely python-less hosts; it is real, honest,
# defensive code, just not one this suite can hermetically trigger on a host that
# ships /usr/bin/python3.
NOPY_TARGET="$FIXROOT/definitely-not-a-real-interpreter"
if [ -e "$NOPY_TARGET" ]; then
  bad "Q8 precondition: fixture path unexpectedly exists"
else
  OJ_NOPY="$(HMD_PYTHON="$NOPY_TARGET" HMD_CTX_PROJECTS_ROOT="$FIXROOT/projects" HMD_HEADROOM_LEDGER="$HEADROOM_OK" "$METER" outshare --json 2>/dev/null)"
  has "$OJ_NOPY" '"state":"NON_VERIFIED"' \
    && ok "an unusable resolved interpreter -> NON_VERIFIED, not a fabricated share" \
    || bad "unusable interpreter did not fail closed" "$OJ_NOPY"
  has "$OJ_NOPY" 'output_share_of_local_total' \
    && bad "a NON_VERIFIED outshare response still carried a share number" "$OJ_NOPY" \
    || ok "the NON_VERIFIED response carries no share figure at all (nothing to mistake for real)"
fi

# ── R. GATE — refuse NEW work only at the hard ceiling with a clean, ungameable
#    boundary; never interrupt in-flight work; fail open on anything unresolvable ──
# THE NEW BEHAVIOR THIS GUARDS (docs/analysis/2026-09-08-context-discipline-gate.md)
# ------------------------------------------------------------------------------
# The meter above is PURELY advisory: it rendered the cliff notice every prompt of
# a session that reached 422,199 tokens -- 2.8x its own ceiling -- and the session
# ran a full day past it anyway. `gate` is the first machine-checkable decision: a
# real exit code (0=proceed, 1=refuse), gated on process/filesystem facts an
# operator cannot talk their way past. THREE TIERS, same thresholds as always:
#   - CEILING (150K)     -> soft floor, advisory only, gate always "ok"
#   - CLIFF_NEAR (700K)  -> strong notice, gate always "checkpoint", ALWAYS
#     exit 0 -- this tier never consults the boundary and never refuses
#   - CLIFF (800K)       -> hard ceiling, the ONLY tier that can refuse
# At CLIFF alone, it must satisfy three things at once:
#   - never refuse while ANY agent is live, or the tree carries an uncommitted
#     change -- interrupting in-flight work to save tokens is a net loss
#   - never refuse on a fact it could not verify (missing heimdall-agents binary,
#     no git, no repo) -- fail OPEN on the boundary signal itself, same as the
#     meter's own NON_VERIFIED philosophy for its primary reading
sec "R. GATE — mechanical, ungameable refuse-vs-defer at the hard ceiling:"

fake_agents() { # <count> -> prints path to an executable stub reporting <count>
  local f; f="$(mktemp "$TMP/fake-agents-XXXXXX")"
  printf '#!/bin/sh\necho %s\n' "$1" > "$f"
  chmod +x "$f"
  printf '%s' "$f"
}
git_repo_clean() { # -> prints path to a fresh, committed, clean git repo
  local d; d="$(mktemp -d "$TMP/repo-clean-XXXXXX")"
  git -C "$d" init -q
  git -C "$d" -c user.email=t@t.test -c user.name=t commit -q --allow-empty -m init
  printf '%s' "$d"
}
git_repo_dirty() { # -> prints path to a committed git repo with an uncommitted file
  local d; d="$(git_repo_clean)"
  printf 'x' > "$d/dirty.txt"
  printf '%s' "$d"
}
gate() { # extra args...
  OUT="$("$METER" gate --session "$SID" "$@" 2>"$TMP/err.txt")"; RC=$?
  ERR="$(cat "$TMP/err.txt" 2>/dev/null)"
}

ZERO_AGENTS="$(fake_agents 0)"
TWO_AGENTS="$(fake_agents 2)"
CLEAN_REPO="$(git_repo_clean)"
DIRTY_REPO="$(git_repo_dirty)"

# R1: below the hard ceiling -> always proceed, regardless of boundary state.
rm -rf "$HEIMDALL_HOME"; publish 118678
HMD_CTX_AGENTS_BIN="$TWO_AGENTS" HMD_CTX_REPO="$DIRTY_REPO" gate
[ "$RC" = 0 ] && ok "118,678 tok (below ceiling) -> gate exits 0" || bad "gate exited $RC below the ceiling"
hasre "$OUT" '^ok \(' && ok "decision=ok below the ceiling" || bad "gate did not report ok: $OUT$ERR"

rm -rf "$HEIMDALL_HOME"; publish 400000
HMD_CTX_AGENTS_BIN="$ZERO_AGENTS" HMD_CTX_REPO="$CLEAN_REPO" gate
[ "$RC" = 0 ] && ok "400,000 tok (CEILING, below hard ceiling) -> gate exits 0" \
             || bad "gate exited $RC at CEILING tier"

# R2: NON_VERIFIED (no reading at all) -> gate fails OPEN, never refuses.
rm -rf "$HEIMDALL_HOME"
HMD_CTX_AGENTS_BIN="$ZERO_AGENTS" HMD_CTX_REPO="$CLEAN_REPO" gate
[ "$RC" = 0 ] && ok "no reading (NON_VERIFIED) -> gate exits 0 (fails open)" \
             || bad "gate exited $RC on an unverified reading -- must never block on its own blind spot"

# R3: CLIFF_NEAR (>=700K, <800K) is the STRONG-NOTICE tier -- it recommends a
#     checkpoint but NEVER refuses, regardless of live agents or a dirty tree.
#     Only CLIFF (>=800K, R4 below) can ever refuse.
rm -rf "$HEIMDALL_HOME"; publish 720000
HMD_CTX_AGENTS_BIN="$ZERO_AGENTS" HMD_CTX_REPO="$CLEAN_REPO" gate
[ "$RC" = 0 ] && ok "720,000 tok (CLIFF_NEAR, clean boundary) -> gate still exits 0 (checkpoint, not refuse)" \
             || bad "gate refused at CLIFF_NEAR (exit $RC) -- only CLIFF may ever refuse"
hasrei "$OUT" 'checkpoint' && ok "decision names the strong-notice/checkpoint tier" || bad "CLIFF_NEAR decision not named: $OUT"

# R3b: CLIFF_NEAR ignores the boundary entirely -- it must not even flip to
#      "defer" when agents are live or the tree is dirty, because it never
#      calls the boundary check in the first place.
rm -rf "$HEIMDALL_HOME"; publish 720000
HMD_CTX_AGENTS_BIN="$TWO_AGENTS" HMD_CTX_REPO="$DIRTY_REPO" gate
[ "$RC" = 0 ] && ok "720,000 tok + live agents + dirty tree -> still just checkpoint, never refuse" \
             || bad "gate refused at CLIFF_NEAR even with agents live and a dirty tree (exit $RC)"
hasrei "$OUT" 'checkpoint' && ok "CLIFF_NEAR decision unaffected by boundary state" || bad "CLIFF_NEAR decision drifted: $OUT"

# R4: past the TRUE hard ceiling (CLIFF, >=800K) + a CONFIRMED clean boundary (no
#     live agents, clean tree) -> the one and only path that REFUSES.
rm -rf "$HEIMDALL_HOME"; publish 812000
HMD_CTX_AGENTS_BIN="$ZERO_AGENTS" HMD_CTX_REPO="$CLEAN_REPO" gate
[ "$RC" = 1 ] && ok "812,000 tok + 0 live agents + clean tree -> gate REFUSES (exit 1)" \
             || bad "gate did not refuse on a fully clean hard-ceiling boundary (exit $RC): $OUT$ERR"
has "$OUT" 'refuse' && ok "decision field says refuse" || bad "refuse decision not named: $OUT"

rm -rf "$HEIMDALL_HOME"; publish 900000
HMD_CTX_AGENTS_BIN="$ZERO_AGENTS" HMD_CTX_REPO="$CLEAN_REPO" gate
[ "$RC" = 1 ] && ok "900,000 tok (well past CLIFF) + clean boundary -> gate REFUSES too" \
             || bad "gate did not refuse well past the cliff with a clean boundary (exit $RC)"

# R5: past CLIFF but an agent is LIVE -> DEFER, never refuse. In-flight work is
#     never interrupted, full stop -- this is the non-negotiable case.
rm -rf "$HEIMDALL_HOME"; publish 812000
HMD_CTX_AGENTS_BIN="$TWO_AGENTS" HMD_CTX_REPO="$CLEAN_REPO" gate
[ "$RC" = 0 ] && ok "812,000 tok + 2 live agents -> gate DEFERS (exit 0, never interrupts)" \
             || bad "gate refused while agents were live -- would interrupt in-flight work (exit $RC)"
has "$OUT" 'defer' && ok "decision field says defer" || bad "defer decision not named: $OUT"
hasre "$OUT" '2 agent'  && ok "names the live-agent count in the reason" || bad "reason does not cite the live agents: $OUT"

# R6: past CLIFF, no live agents, but an UNCOMMITTED change sits in the tree ->
#     DEFER. Uncommitted work is a mid-flight signal too.
rm -rf "$HEIMDALL_HOME"; publish 812000
HMD_CTX_AGENTS_BIN="$ZERO_AGENTS" HMD_CTX_REPO="$DIRTY_REPO" gate
[ "$RC" = 0 ] && ok "812,000 tok + 0 agents + DIRTY tree -> gate DEFERS, does not refuse" \
             || bad "gate refused on a dirty tree (exit $RC) -- uncommitted work is mid-flight too"
hasrei "$OUT" 'uncommitted' && ok "reason names the uncommitted change" || bad "reason silent on why: $OUT"

# R6b: the boundary itself is UNRESOLVABLE at CLIFF -> fail OPEN, defer, never
#      refuse. Three independent ways it can be unresolvable, all must defer:
rm -rf "$HEIMDALL_HOME"; publish 812000
NO_SUCH_BIN="$TMP/does-not-exist-$$"
HMD_CTX_AGENTS_BIN="$NO_SUCH_BIN" HMD_CTX_REPO="$CLEAN_REPO" gate
[ "$RC" = 0 ] && ok "missing heimdall-agents binary -> gate DEFERS (fails open on the boundary)" \
             || bad "gate refused when it could not even check for live agents (exit $RC)"

NOT_A_REPO="$(mktemp -d "$TMP/not-a-repo-XXXXXX")"
HMD_CTX_AGENTS_BIN="$ZERO_AGENTS" HMD_CTX_REPO="$NOT_A_REPO" gate
[ "$RC" = 0 ] && ok "HMD_CTX_REPO is not a git repo -> gate DEFERS (fails open)" \
             || bad "gate refused with no git repo to check (exit $RC)"

HMD_CTX_AGENTS_BIN="$ZERO_AGENTS" HMD_CTX_REPO="$TMP/nonexistent-dir-$$" gate
[ "$RC" = 0 ] && ok "HMD_CTX_REPO points nowhere -> gate DEFERS (fails open)" \
             || bad "gate refused with an unresolvable repo path (exit $RC)"

# R7: --json is well-formed and carries state + tokens alongside the decision.
rm -rf "$HEIMDALL_HOME"; publish 812000
HMD_CTX_AGENTS_BIN="$ZERO_AGENTS" HMD_CTX_REPO="$CLEAN_REPO" gate --json
hasre "$OUT" '"decision"[[:space:]]*:[[:space:]]*"refuse"' && ok "JSON decision=refuse" || bad "JSON missing decision=refuse: $OUT"
hasre "$OUT" '"state"[[:space:]]*:[[:space:]]*"CLIFF"'     && ok "JSON carries the underlying state (CLIFF)" || bad "JSON missing state: $OUT"
hasre "$OUT" '"tokens"[[:space:]]*:[[:space:]]*812000'     && ok "JSON carries the actual token reading"    || bad "JSON missing tokens: $OUT"

# R8: render_cliff (the existing per-prompt notice) now ALSO carries the same
#     decision inline -- an operator reading stderr sees it without a second call.
rm -rf "$HEIMDALL_HOME"; publish 850000
HMD_CTX_AGENTS_BIN="$ZERO_AGENTS" HMD_CTX_REPO="$CLEAN_REPO" notice
hasrei "$(both)" 'refuse new work' && ok "the cliff notice itself names REFUSE on a clean boundary" \
                                    || bad "cliff notice does not carry the refuse decision: $(both)"

rm -rf "$HEIMDALL_HOME"; publish 850000
HMD_CTX_AGENTS_BIN="$TWO_AGENTS" HMD_CTX_REPO="$CLEAN_REPO" notice
hasrei "$(both)" 'deferring' && ok "the cliff notice names DEFERRING when agents are live" \
                              || bad "cliff notice does not carry the defer decision: $(both)"

# R8b: at CLIFF_NEAR the notice shows STRONG NOTICE framing and must NEVER claim
#      refuse capability -- the tier separation has to hold in rendered text too.
rm -rf "$HEIMDALL_HOME"; publish 720000
HMD_CTX_AGENTS_BIN="$ZERO_AGENTS" HMD_CTX_REPO="$CLEAN_REPO" notice
hasrei "$(both)" 'strong notice' && ok "CLIFF_NEAR notice shows STRONG NOTICE framing" \
                                  || bad "CLIFF_NEAR notice missing strong-notice framing: $(both)"
hasrei "$(both)" 'refuse new work' && bad "CLIFF_NEAR notice must never claim REFUSE NEW WORK" \
                                    || ok "CLIFF_NEAR notice correctly never claims refuse capability"

# R9: gate is on the machine-checkable path, not the hot path -- still fast.
rm -rf "$HEIMDALL_HOME"; publish 812000
S=$(date +%s)
HMD_CTX_AGENTS_BIN="$ZERO_AGENTS" HMD_CTX_REPO="$CLEAN_REPO" gate >/dev/null 2>&1
E=$(date +%s)
D=$((E - S))
[ "$D" -le 5 ] && ok "gate resolves in ${D}s (two subprocess calls, not a hang)" \
               || bad "gate took ${D}s -- too slow for something the orchestrator checks before every spawn"

# R10: --help documents gate (discoverability, and proves the widened comment
#      range was NOT silently truncated by this change).
HELP="$("$METER" --help 2>/dev/null)"
has "$HELP" 'gate' && ok "--help documents the gate verb" || bad "--help does not mention gate"

# R11: never errors -- garbage stdin/session still exits 0 or 1, never crashes,
#      and an unknown verb still lists gate among the expected verbs.
RC3=0; printf 'garbage \x01\x02' | "$METER" gate --session "$SID" >/dev/null 2>&1 || RC3=$?
{ [ "$RC3" = 0 ] || [ "$RC3" = 1 ]; } && ok "gate exits 0 or 1 on garbage stdin, never crashes" \
                                       || bad "gate exited $RC3 on garbage stdin (expected 0 or 1)"
ERRMSG="$("$METER" no-such-verb 2>&1 >/dev/null)"
has "$ERRMSG" 'gate' && ok "unknown-verb error message lists gate among the expected verbs" \
                      || bad "unknown-verb message was not updated: $ERRMSG"

# R12: DEFAULT resolution (no override) -- the real fallback path must be sane,
#      not just the test seam. Never drives gate's DECISION against the real
#      tree here (this worktree is being edited live by this very task, so its
#      git-clean state is not a stable thing to assert on).
DEFAULT_REPO="$(cd "$REPO" && git rev-parse --show-toplevel 2>/dev/null)"
[ -n "$DEFAULT_REPO" ] && ok "default repo resolution: git rev-parse --show-toplevel works from here" \
                        || bad "could not confirm the real repo resolves via git rev-parse"
[ -x "$REPO/bin/heimdall-agents" ] && ok "default agents-bin sibling path exists and is executable" \
                                    || bad "bin/heimdall-agents missing next to the meter -- default resolution would fail"

# R13: hermetic -- none of this touched the real ~/.heimdall.
if [ -d "$REAL_HOME_CTX" ] && find "$REAL_HOME_CTX" -name "*$SID*" 2>/dev/null | grep -q .; then
  bad "section R leaked a record for $SID into the real ~/.heimdall"
else
  ok "section R never touched the real ~/.heimdall"
fi

# ── S. IDLE RETURN — the prompt cache went cold while the session sat there ──────
# THE MEASURED DEFECT: 102 idle gaps over an hour in the 72-day session re-wrote the whole
# prefix at cache-write price — $441.88, 37.2% of that session's spend, and 78 of them had
# >150K in the context (docs/analysis/2026-11-22-token-utilization-next.md §1, lever 2). The
# tier notice cannot see it (the context did not grow, the cache expired) and a return is the
# cheapest moment to compact. THE RULE: gap since the last main-thread assistant entry of the
# transcript the payload names >= HMD_CTX_IDLE_S (3300 s) AND the session's reading >= the
# ceiling (150K) -> ONE model line suggesting /hmd:save (the compact line comes with it) or /compact; silent otherwise,
# including whenever the gap cannot be established. "Now" is HMD_CTX_NOW, so a 3,700 s gap
# costs no 3,700 s here.
sec "S. IDLE RETURN — cache cold AND context >= 150K -> ONE model line to compact; silent otherwise:"
T0=1795400000
iso() { date -u -r "$1" +%Y-%m-%dT%H:%M:%S.000Z 2>/dev/null || date -u -d "@$1" +%Y-%m-%dT%H:%M:%S.000Z; }
tx_entry() { # <type> <epoch> [isSidechain]: one transcript line, shaped like Claude Code's.
  # Every entry's text mentions "assistant", as real prompts and tool results do, so only the
  # type field (not a cheap substring skip) can keep a non-assistant entry out of the clock.
  printf '{"type":"%s","isSidechain":%s,"timestamp":"%s","message":{"role":"%s","content":"the assistant said x"}}\n' \
    "$1" "${3:-false}" "$(iso "$2")" "$1"
}
notice_tx() { # <now> <transcript path> -> OUT/ERR/RC. A hang is cut at 10 s and reads as RC 142, never as silence.
  OUT="$(printf '{"session_id":"%s","prompt":"go","transcript_path":"%s"}' "$SID" "$2" \
        | HMD_CTX_NOW="$1" perl -e 'alarm 10; exec @ARGV' "$METER" notice 2>"$TMP/err.txt")"; RC=$?
  ERR="$(cat "$TMP/err.txt" 2>/dev/null)"
}
# A session ACTIVE at T0 (its tier line, if any, already told), quiet for <gap> s, then its first
# prompt back -> OUT/ERR/RC of THAT prompt. The status bar re-renders every 2 s (refreshInterval)
# even while nothing happens, so the reading is fresh at return; `stale` models a suspended UI.
TX_STD="$TMP/tx-std.jsonl"; { tx_entry user $((T0 - 20)); tx_entry assistant "$T0"; } > "$TX_STD"
idle_return() { # <tokens> <gap> [transcript] [stale]
  local tok="$1" gap="$2" tx="${3:-$TX_STD}"
  rm -rf "$HEIMDALL_HOME"
  HMD_CTX_NOW="$T0" publish "$tok"
  notice_tx "$T0" "$tx"
  [ "${4:-}" = stale ] || HMD_CTX_NOW="$((T0 + gap))" publish "$tok"
  notice_tx "$((T0 + gap))" "$tx"
}

# S1. the case the lever exists for
idle_return 200000 3700
S_TXT="$(ctx_line)"
hasre "$S_TXT" '^\[heimdall\] CACHE COLD' && ok "3,700 s idle at 200,000 tok -> the model is told the cache is cold" \
                                          || bad "no cold-cache line after 3,700 s idle at 200,000 tok: out='$OUT'"
hasre "$S_TXT" 'idle 61 min'   && ok "it states the real gap (3,700 s = 61 min), computed, not canned" \
                               || bad "the line does not state the gap: '$S_TXT'"
has   "$S_TXT" '200,000'       && ok "it names what this turn re-writes (200,000 tokens)" || bad "the line omits the reading: '$S_TXT'"
{ has "$S_TXT" '/compact' && has "$S_TXT" '/hmd:save'; } \
                               && ok "it suggests /hmd:save (which prints the /compact line) or /compact" || bad "the line suggests neither remedy: '$S_TXT'"
has   "$S_TXT" '/hmd:continue' && bad "the line still sends the user to the deprecated /hmd:continue: '$S_TXT'" \
                               || ok "it does not name the deprecated /hmd:continue"
[ "$(lines_of "$OUT")" = 1 ] && [ "$(lines_of "$S_TXT")" = 1 ] && [ "${#S_TXT}" -le 300 ] \
  && ok "ONE short line (${#S_TXT} chars)" || bad "not one short line (${#S_TXT} chars): '$S_TXT'"
[ "$RC" = 0 ] && ok "exit 0" || bad "exit $RC"

# S2. silent where it should be
idle_return 100000 3700
[ -z "$(both)" ] && ok "3,700 s idle at 100,000 tok -> silent on both streams (a small context is cheap to re-write)" \
                 || bad "spoke at 100,000 tok after 3,700 s: $(both)"
idle_return 400000 60
[ -z "$OUT" ] && ok "60 s gap at 400,000 tok -> no idle line (the cache is warm)" || bad "cold-cache line after only 60 s: '$OUT'"
idle_return 200000 3299
[ -z "$OUT" ] && ok "3,299 s -> silent, one second under the threshold" || bad "spoke at 3,299 s: '$OUT'"
idle_return 200000 3300
[ -n "$(ctx_line)" ] && ok "3,300 s -> speaks: the threshold is inclusive" || bad "silent at exactly 3,300 s"
HMD_CTX_IDLE_S=600 idle_return 200000 700
[ -n "$(ctx_line)" ] && ok "HMD_CTX_IDLE_S=600 moves the threshold (700 s speaks)" || bad "HMD_CTX_IDLE_S was not honoured"

# S3. a suspended UI leaves a STALE reading at return; what it last showed is what gets re-written
idle_return 200000 3700 "$TX_STD" stale
hasre "$(ctx_line)" '^\[heimdall\] CACHE COLD' && ok "a STALE reading (UI suspended) still counts: its size is what the next turn re-writes" \
                                               || bad "a stale reading silenced the idle line: out='$OUT'"

# S4. what counts as activity: the last MAIN-THREAD ASSISTANT entry — the cache is refreshed by an
# API response, not by a tool result, a typed prompt or a subagent
TX_TAIL="$TMP/tx-tail.jsonl"
{ tx_entry assistant "$T0"; tx_entry user $((T0 + 3690)); tx_entry attachment $((T0 + 3695)); } > "$TX_TAIL"
idle_return 200000 3700 "$TX_TAIL"
[ -n "$(ctx_line)" ] && ok "a prompt or tool result written after the last response is not activity (so it does not matter whether the current prompt is already in the file)" \
                     || bad "trailing non-assistant entries were counted as activity: out='$OUT'"
TX_SIDE="$TMP/tx-side.jsonl"
{ tx_entry assistant "$T0"; tx_entry assistant $((T0 + 3600)) true; } > "$TX_SIDE"
idle_return 200000 3700 "$TX_SIDE"
[ -n "$(ctx_line)" ] && ok "a subagent's (sidechain) response does not keep the MAIN thread's cache warm" \
                     || bad "a sidechain entry was counted as main-thread activity: out='$OUT'"

# S5. no evidence of the gap -> never a cold cache
rm -rf "$HEIMDALL_HOME"
HMD_CTX_NOW="$T0" publish 200000; HMD_CTX_NOW="$T0" notice
HMD_CTX_NOW="$((T0 + 5000))" publish 200000; HMD_CTX_NOW="$((T0 + 5000))" notice
[ -z "$OUT" ] && ok "the payload names no transcript -> silent (an unknown gap is not a cold cache)" || bad "spoke with no transcript: '$OUT'"
idle_return 200000 5000 "$TMP/no-such-transcript.jsonl"
[ -z "$OUT" ] && ok "the transcript path does not exist -> silent" || bad "spoke for a missing transcript: '$OUT'"
TX_BAD="$TMP/tx-garbage.jsonl"; printf 'not json {{{ assistant\n\001\002 "type":"assistant"\n' > "$TX_BAD"
idle_return 200000 5000 "$TX_BAD"
{ [ -z "$OUT" ] && [ "$RC" = 0 ]; } && ok "the transcript is garbage -> silent, exit 0" || bad "garbage transcript: rc=$RC out='$OUT'"
TX_FIFO="$TMP/tx.fifo"; rm -f "$TX_FIFO"; mkfifo "$TX_FIFO" 2>/dev/null
if [ -p "$TX_FIFO" ]; then
  S0=$(date +%s); idle_return 200000 5000 "$TX_FIFO"; E0=$(date +%s)
  { [ -z "$OUT" ] && [ "$RC" = 0 ] && [ $((E0 - S0)) -le 6 ]; } \
    && ok "a FIFO as the transcript path is never opened (back in $((E0 - S0))s) -> silent, the prompt cannot block" \
    || bad "a FIFO transcript path hung or spoke: rc=$RC after $((E0 - S0))s out='$OUT'"
  rm -f "$TX_FIFO"
else
  bad "could not create a fifo — the transcript-hang regression went unproven"
fi

# S6. bounded: only the last 1 MiB of the file is read (a long session's transcript runs to 100 MB)
TX_HEAD="$TMP/tx-head.jsonl"; TX_BIGTAIL="$TMP/tx-bigtail.jsonl"
PADPY='import sys; sys.stdout.write("{\"type\":\"user\",\"message\":{\"content\":\"pad\"}}\n" * 60000)'
{ tx_entry assistant "$T0"; python3 -c "$PADPY"; } > "$TX_HEAD"
{ python3 -c "$PADPY"; tx_entry assistant "$T0"; } > "$TX_BIGTAIL"
idle_return 200000 3700 "$TX_HEAD"
[ -z "$OUT" ] && ok "the only response is $(( $(wc -c < "$TX_HEAD") / 1000000 )) MB from the end -> not found: only the tail is read" \
              || bad "the whole transcript was read (an entry beyond the 1 MiB tail was found): '$OUT'"
idle_return 200000 3700 "$TX_BIGTAIL"
[ -n "$(ctx_line)" ] && ok "a transcript larger than the window whose last response is at its end -> read from the tail, speaks" \
                     || bad "a large transcript was skipped instead of read from its tail: out='$OUT'"

# S7. the reading must be this session's own: another session's size is not this one's
rm -rf "$HEIMDALL_HOME"
HMD_CTX_NOW="$T0" publish 300000 "other-$$"
notice_tx "$((T0 + 5000))" "$TX_STD"
[ -z "$OUT" ] && ok "no reading of its own -> another session's size is never used for the nudge" \
              || bad "the nudge used another session's reading: '$OUT'"

# S8. a tier crossing and a cold cache on the SAME prompt are still ONE hook JSON object
rm -rf "$HEIMDALL_HOME"
HMD_CTX_NOW="$((T0 + 3700))" publish 400000
notice_tx "$((T0 + 3700))" "$TX_STD"
S_TXT="$(ctx_line)"
if [ "$(jq -s 'length' <<<"$OUT" 2>/dev/null)" = 1 ] && [ "$(lines_of "$S_TXT")" = 2 ] \
   && hasre "$S_TXT" 'CONTEXT' && hasre "$S_TXT" 'CACHE COLD'; then
  ok "tier entry + cold cache on one prompt -> still ONE hook JSON object, two lines inside it"
else
  bad "two model lines did not share one valid hook JSON object: '$OUT'"
fi

# S9. discoverable: --help documents the knob, and now runs to the last ENVIRONMENT line (the
# old fixed range stopped short of HMD_CTX_REPO and HMD_CTX_AGENTS_BIN)
HELP="$("$METER" --help 2>/dev/null)"
has "$HELP" 'HMD_CTX_IDLE_S'     && ok "--help documents HMD_CTX_IDLE_S" || bad "--help does not mention HMD_CTX_IDLE_S"
has "$HELP" 'HMD_CTX_AGENTS_BIN' && ok "--help runs to the last ENVIRONMENT line (HMD_CTX_AGENTS_BIN)" \
                                 || bad "--help is cut short before HMD_CTX_AGENTS_BIN"

printf '\nctx-meter.test.sh: %s passed, %s failed.\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
