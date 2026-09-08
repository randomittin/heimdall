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
#   R. GATE                       — a NEW machine-checkable verb (2026-09-08): may
#      NEW work start? Real exit code (0=proceed, 1=refuse), gated on REAL process/
#      filesystem facts (a live agent, an uncommitted change) — never refuses below
#      the hard ceiling, never refuses while work is in flight, and fails OPEN the
#      instant the boundary itself cannot be verified.
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

has()   { grep -qF "$2" <<<"$1"; }
hasre() { grep -qE "$2" <<<"$1"; }
hasrei(){ grep -qiE "$2" <<<"$1"; }   # case-insensitive: renders SHOUT

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
# EVERY speaking state, not only the cliff. The ceiling and the blind notice render
# through a DIFFERENT printer than the ruled cliff block, so a cliff-only version of this
# proof leaves the routine path free to leak onto stdout — and it did: a mutation that
# moved the ceiling printer to stdout survived the first version of this section.
sec "L. STDERR, NOT CONTEXT (a context warning must not itself cost context):"
for L_TOK in 214000 720000 812000; do
  rm -rf "$HEIMDALL_HOME"; publish "$L_TOK"
  notice
  [ -z "$OUT" ] && ok "$L_TOK tok: stdout empty — nothing injected into the model's context" \
                || bad "$L_TOK tok wrote to stdout; UserPromptSubmit stdout becomes context: $OUT"
  [ -n "$ERR" ] && ok "$L_TOK tok: spoken on stderr, where the operator sees it" \
                || bad "$L_TOK tok: nothing on stderr"
done
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

printf '\nctx-meter.test.sh: %s passed, %s failed.\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
