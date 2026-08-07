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
#   L. STDERR, NOT CONTEXT        — the notice must not be injected into the model's
#      context. A context warning that itself costs context is self-defeating.
#   M/N. ACTUALLY WIRED           — extracted from the REAL hooks/statusline.sh and the
#      REAL hooks/hooks.json UserPromptSubmit entry. This is the falsifier: a meter
#      wired to nothing is a file, not a gate. SessionStart-only would be useless —
#      drift happens mid-session, so it must fire per prompt.
#   O. NEVER ERRORS               — garbage on stdin still exits 0 on every verb. This
#      runs in the prompt path; it must never be able to break a turn.
#   P. HERMETIC                   — the real ~/.heimdall is never touched.
#
# Usage:  bash test/ctx-meter.test.sh    (exit 0 = every proof holds)

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SELF_DIR/.." && pwd)"
METER="$REPO/bin/heimdall-ctx-meter"
HOOKS="$REPO/hooks/hooks.json"
STATUSLINE="$REPO/hooks/statusline.sh"

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

has()   { printf '%s' "$1" | grep -qF "$2"; }
hasre() { printf '%s' "$1" | grep -qE "$2"; }
hasrei(){ printf '%s' "$1" | grep -qiE "$2"; }   # case-insensitive: renders SHOUT

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
hasre "$CEIL" 'save|checkpoint'  && ok "tells the operator to checkpoint/restart" || bad "no restart instruction"
hasre "$CEIL" '214,000|214000'   && ok "reports the ACTUAL current reading"   || bad "does not report the reading"

# ── C. approaching the cliff — LOUD ──────────────────────────────────────────────
sec "C. APPROACHING THE 800K CACHE CLIFF — loud:"
rm -rf "$HEIMDALL_HOME"; publish 720000
notice
NEAR="$(both)"
[ -n "$NEAR" ] && ok "720,000 tok -> speaks" || bad "silent at 720,000 tok"
has "$NEAR" '━'    && ok "renders a ruled block (visually distinct)" || bad "no ruled block near the cliff"
hasre "$NEAR" '800' && ok "names the 800K cliff it is approaching"   || bad "does not name the cliff"

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

# ── L. the notice goes to STDERR — it must not become context bloat ──────────────
sec "L. STDERR, NOT CONTEXT (a context warning must not itself cost context):"
rm -rf "$HEIMDALL_HOME"; publish 812000
notice
[ -z "$OUT" ] && ok "stdout is empty — nothing is injected into the model's context" \
              || bad "wrote to stdout; UserPromptSubmit stdout becomes context: $OUT"
[ -n "$ERR" ] && ok "the notice is on stderr, where the operator sees it" || bad "nothing on stderr"

# ── M. WIRED into the REAL per-prompt hook (SessionStart-only would be useless) ──
sec "M. WIRED @ UserPromptSubmit — the hook that fires per prompt:"
UPS_CMD="$(jq -r '.hooks.UserPromptSubmit[]?.hooks[]?.command // empty' "$HOOKS" 2>/dev/null \
          | grep -F 'heimdall-ctx-meter' | head -1)"
if [ -n "$UPS_CMD" ]; then
  ok "a UserPromptSubmit hook invokes heimdall-ctx-meter"
  rm -rf "$HEIMDALL_HOME"; publish 880000
  HOOK_OUT="$(cd "$REPO" && printf '{"session_id":"%s","prompt":"go"}' "$SID" \
    | CLAUDE_PLUGIN_ROOT="$REPO" HEIMDALL_HOME="$HEIMDALL_HOME" sh -c "$UPS_CMD" 2>&1)"
  HOOK_RC=$?
  has "$HOOK_OUT" '━' && ok "the REAL wired hook command fires the cliff notice" \
                      || bad "wired hook produced no notice: $HOOK_OUT"
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
sec "N. WIRED @ statusline — the publisher, because only the bar sees context:"
if grep -q 'heimdall-ctx-meter' "$STATUSLINE"; then
  ok "hooks/statusline.sh invokes heimdall-ctx-meter"
  rm -rf "$HEIMDALL_HOME"
  blob 456000 "$SID" | HEIMDALL_HOME="$HEIMDALL_HOME" bash "$STATUSLINE" >/dev/null 2>&1
  JSON="$("$METER" read --session "$SID" --json 2>/dev/null)"
  hasre "$JSON" '"tokens"[[:space:]]*:[[:space:]]*456000' \
    && ok "driving the REAL statusline published the reading (456,000)" \
    || bad "statusline did not publish: $JSON"
else
  bad "NOT WIRED — hooks/statusline.sh never publishes the reading"
fi

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

printf '\nctx-meter.test.sh: %s passed, %s failed.\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
