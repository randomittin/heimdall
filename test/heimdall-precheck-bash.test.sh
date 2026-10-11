#!/usr/bin/env bash
# test/heimdall-precheck-bash.test.sh
#
# Proof that bin/heimdall-precheck-bash IS the PreToolUse/Bash hook chain that
# used to live as one ~5,000-char shell string inside hooks/hooks.json — not a
# rewrite of it, not "close enough", the same program.
#
# HOW: for every branch of the chain (plain command, empty/malformed payload,
# git-guard routing, commit secret gate deny/allow, push quality-gate deny /
# allow / UNAVAILABLE, push secret gate deny, self-scan deny, native-hook
# delegation, HMD_SKIP not widening that delegation, oracle falsify deny with
# and without heimdall-stamp / report.json, corpus deny, stack-file APPLIES) the
# same payload is fed, under one identical environment, to:
#   (a) the REFERENCE inline string  — `bash -c "$INLINE"`
#   (b) the extracted script          — `bash bin/heimdall-precheck-bash`
#   (c) the shipped hooks.json command — `bash -c "$(jq ... hooks.json)"`, which
#       is (a) itself before the JSON swap and the one-liner wrapper after it
# and stdout, stderr and exit code must be byte-identical across all three. On
# top of that (a) and (b) are re-run under `bash -x` and their execution traces
# must match line for line (the script's own `case "${1:-}"` -h guard is the one
# line filtered out — it is the only statement not in the inline string).
#
# TWO DELIBERATE DELTAS (2026-10-11, "precheck never blocks silently in another
# repo") — the one place the script is NOT the historical inline chain any more,
# each updated here on purpose and pinned by its own case:
#   * a deny (exit 2) also states its verdict on STDERR (case 24). stdout is
#     unchanged; equiv() therefore compares a deny's stderr with that mirrored
#     line removed, and skips the xtrace comparison for denies (the mirror is the
#     only statement that differs).
#   * with CLAUDE_PLUGIN_ROOT unset the plugin root is the script's own location,
#     never the cwd's git toplevel (case 21); the shipped hooks.json wrappers fail
#     open with one stderr line instead of exiting 127 (cases 25, 26).
#
# WHERE THE REFERENCE COMES FROM: the working tree's hooks.json while it still
# carries the inline string; once hooks.json has been swapped to the wrapper, the
# newest commit of hooks.json whose Bash command still carried the inline chain
# (found by walking `git log -- hooks/hooks.json`). Either way the reference is
# the string that actually shipped, never a copy pasted into this file.
#
# Every gate bin the chain calls is a deterministic fake under a throwaway
# CLAUDE_PLUGIN_ROOT, so "same output" is a real byte comparison, and no real
# git push, gitleaks or heimdall-state ever runs.

set -u

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$REPO/bin/heimdall-precheck-bash"
# HMD_TEST_HOOKS_JSON lets the swap be rehearsed: point it at a scratch copy of
# hooks.json already carrying the wrapper one-liner and this file proves the
# wrapper against the historical inline chain BEFORE the real file is touched.
HOOKS_JSON="${HMD_TEST_HOOKS_JSON:-$REPO/hooks/hooks.json}"

PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; [ -n "${2:-}" ] && printf '       %s\n' "$2"; }

TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT

echo "heimdall-precheck-bash"

# ── 0. the script exists, is executable, parses ─────────────────────────────
[ -x "$SCRIPT" ] && ok "0a. bin/heimdall-precheck-bash exists and is executable" \
                 || { bad "0a. bin/heimdall-precheck-bash missing or not executable"; exit 1; }
if bash -n "$SCRIPT" 2>"$TMPROOT/syn"; then
  ok "0b. bash -n bin/heimdall-precheck-bash"
else
  bad "0b. bash -n failed" "$(cat "$TMPROOT/syn")"; exit 1
fi
if grep -v '^[[:space:]]*#' "$SCRIPT" | grep -qE '^[[:space:]]*set -[a-z]*[eu]|set -o pipefail'; then
  bad "0c. script must not add set -e/-u/pipefail (the inline ran without them; they change the chain's semantics)"
else
  ok "0c. no set -e / set -u / pipefail added"
fi

# ── reference + shipped command ─────────────────────────────────────────────
bash_cmd_of() { jq -r '.hooks.PreToolUse[] | select(.matcher=="Bash") | .hooks[].command' 2>/dev/null; }

SHIPPED="$(bash_cmd_of <"$HOOKS_JSON")"
[ -n "$SHIPPED" ] || { bad "hooks.json has no PreToolUse Bash command"; exit 1; }

INLINE=""
INLINE_SRC=""
if grep -q 'NATIVE_GATE=0' <<<"$SHIPPED" && ! grep -q 'heimdall-precheck-bash' <<<"$SHIPPED"; then
  INLINE="$SHIPPED"; INLINE_SRC="working tree hooks/hooks.json"
else
  while IFS= read -r sha; do
    cand="$(git -C "$REPO" show "$sha:hooks/hooks.json" 2>/dev/null | bash_cmd_of)"
    if grep -q 'NATIVE_GATE=0' <<<"$cand" && ! grep -q 'heimdall-precheck-bash' <<<"$cand"; then
      INLINE="$cand"; INLINE_SRC="hooks/hooks.json @ ${sha:0:8}"; break
    fi
  done < <(git -C "$REPO" log --format=%H -- hooks/hooks.json)
fi
if [ -n "$INLINE" ]; then
  ok "0d. reference inline chain located ($INLINE_SRC, ${#INLINE} chars)"
else
  bad "0d. no inline Bash chain found in hooks.json or its history"; exit 1
fi

# ── fake plugin roots ───────────────────────────────────────────────────────
# Every bin the chain may call, deterministic, steered by FAKE_* env vars. No
# $$, no timestamps, no clocks — output must be reproducible run to run.
mk_fake() {  # mk_fake <dir> <name> <body>
  printf '#!/usr/bin/env bash\n%s\n' "$3" > "$1/bin/$2"; chmod +x "$1/bin/$2"
}
mk_plugin() {  # mk_plugin <name> [omit-bin...] -> path
  local d="$TMPROOT/plugin-$1"; shift
  mkdir -p "$d/bin" "$d/evals/oracles/demo-domain/fixtures/mutants"
  mk_fake "$d" heimdall-git-guard 'echo "git-guard ran ($*)" >&2; exit 0'
  mk_fake "$d" secret-scan 'if [ "${1:-}" = --require ]; then echo "secret-scan --require SECRET_SCAN_REQUIRE=${SECRET_SCAN_REQUIRE:-unset}"; rc=${FAKE_SCAN_REQUIRE_RC:-0}; else echo "secret-scan staged"; rc=${FAKE_SCAN_RC:-0}; fi; [ "$rc" = 0 ] || echo "leak: AKIA\"quoted\" value \\ here" >&2; exit "$rc"'
  mk_fake "$d" heimdall-state 'echo "heimdall-state $*"; [ "${FAKE_HSTATE_RC:-0}" = 0 ] && echo "all quality gates pass"; exit ${FAKE_HSTATE_RC:-0}'
  mk_fake "$d" heimdall-selfscan 'echo "selfscan ran"; [ "${FAKE_SELFSCAN_RC:-0}" = 0 ] || echo "selfscan: secret in history" >&2; exit ${FAKE_SELFSCAN_RC:-0}'
  mk_fake "$d" falsify 'echo "falsify $*"; exit ${FAKE_FALSIFY_RC:-0}'
  mk_fake "$d" corpus 'echo "corpus $*"; exit ${FAKE_CORPUS_RC:-0}'
  mk_fake "$d" heimdall-stamp 'echo "stamp $*"; echo "stamp-stderr" >&2; exit 0'
  mk_fake "$d" parallelism-tracker 'echo "tracker $*"; echo "tracker-stderr" >&2; exit 0'
  # the wrapper form of the hook resolves the script under $PLUGIN/bin
  cp "$SCRIPT" "$d/bin/heimdall-precheck-bash"; chmod +x "$d/bin/heimdall-precheck-bash"
  local o; for o in "$@"; do rm -f "$d/bin/$o"; done
  printf '%s' "$d"
}
PLUGIN_FULL="$(mk_plugin full)"
PLUGIN_NOSTAMP="$(mk_plugin nostamp heimdall-stamp)"
PLUGIN_NOHSTATE="$(mk_plugin nohstate heimdall-state)"

# ── cwd fixtures ────────────────────────────────────────────────────────────
mk_cwd() {  # mk_cwd <name> -> a real git repo with the evals scaffolding the chain reads from CWD
  local d="$TMPROOT/cwd-$1"
  mkdir -p "$d/evals/oracles/demo-domain" "$d/evals/corpus"
  ( cd "$d" && git init -q && git config user.email t@t && git config user.name t )
  printf '{}\n' > "$d/evals/corpus/INDEX.json"
  printf '%s' "$d"
}
CWD_PLAIN="$(mk_cwd plain)"
CWD_NATIVE="$(mk_cwd native)"
mkdir -p "$CWD_NATIVE/.heimdall/hooks"
printf '#!/usr/bin/env bash\nexit 0\n' > "$CWD_NATIVE/.heimdall/hooks/pre-push"; chmod +x "$CWD_NATIVE/.heimdall/hooks/pre-push"
( cd "$CWD_NATIVE" && git config core.hooksPath .heimdall/hooks )
CWD_REPORT="$(mk_cwd report)"
printf '{"score":0.5}\n' > "$CWD_REPORT/evals/oracles/demo-domain/report.json"
CWD_STACK="$TMPROOT/cwd-stack"   # APPLIES via .planning/detected-stack.json, no evals/oracles/<dom> in cwd
mkdir -p "$CWD_STACK/.planning" "$CWD_STACK/evals/corpus"
( cd "$CWD_STACK" && git init -q )
printf '{"stacks":["demo-domain"]}\n' > "$CWD_STACK/.planning/detected-stack.json"
printf '{}\n' > "$CWD_STACK/evals/corpus/INDEX.json"
CWD_NOGIT="$TMPROOT/cwd-nogit"; mkdir -p "$CWD_NOGIT"

# ── runner ──────────────────────────────────────────────────────────────────
# run_variant <tag> <mode> <cwd> <plugin> <payload> [ENV=VAL ...]
#   mode: inline | script | shipped | trace-inline | trace-script
# writes $TMPROOT/<tag>.<mode>.{out,err,rc}
run_variant() {
  local tag="$1" mode="$2" cwd="$3" plugin="$4" payload="$5"; shift 5
  local base="$TMPROOT/$tag.$mode" rc
  (
    cd "$cwd" || exit 99
    case "$mode" in
      inline)       printf '%s' "$payload" | env CLAUDE_PLUGIN_ROOT="$plugin" PATH="$plugin/bin:$PATH" "$@" bash -c "$INLINE" ;;
      script)       printf '%s' "$payload" | env CLAUDE_PLUGIN_ROOT="$plugin" PATH="$plugin/bin:$PATH" "$@" bash "$SCRIPT" ;;
      shipped)      printf '%s' "$payload" | env CLAUDE_PLUGIN_ROOT="$plugin" PATH="$plugin/bin:$PATH" "$@" bash -c "$SHIPPED" ;;
      trace-inline) printf '%s' "$payload" | env CLAUDE_PLUGIN_ROOT="$plugin" PATH="$plugin/bin:$PATH" PS4='+ ' "$@" bash -x -c "$INLINE" ;;
      trace-script) printf '%s' "$payload" | env CLAUDE_PLUGIN_ROOT="$plugin" PATH="$plugin/bin:$PATH" PS4='+ ' "$@" bash -x "$SCRIPT" ;;
    esac
  ) >"$base.out" 2>"$base.err"
  rc=$?
  printf '%s' "$rc" > "$base.rc"
}

# equiv <n> <label> <cwd> <plugin> <payload> [ENV=VAL ...]
# Asserts inline == script == shipped on stdout/stderr/rc, and trace equality.
equiv() {
  local n="$1" label="$2" cwd="$3" plugin="$4" payload="$5"; shift 5
  local tag="c$n" m
  for m in inline script shipped trace-inline trace-script; do
    run_variant "$tag" "$m" "$cwd" "$plugin" "$payload" "$@"
  done
  local why=""
  for m in script shipped; do
    cmp -s "$TMPROOT/$tag.inline.out" "$TMPROOT/$tag.$m.out" || why="$why stdout($m)"
    # a deny (rc 2) mirrors its stdout verdict onto stderr — the deliberate delta (case 24);
    # remove exactly that line and the rest of stderr must still be the historical bytes
    { if [ "$(cat "$TMPROOT/$tag.$m.rc")" = 2 ]; then grep -vxF -f "$TMPROOT/$tag.$m.out" "$TMPROOT/$tag.$m.err"; else cat "$TMPROOT/$tag.$m.err"; fi; } | cmp -s "$TMPROOT/$tag.inline.err" - || why="$why stderr($m)"
    cmp -s "$TMPROOT/$tag.inline.rc"  "$TMPROOT/$tag.$m.rc"  || why="$why rc($m)"
  done
  # the -h guard is the ONE statement the script has that the string does not.
  # Traces are compared SORTED: the two sides of a `printf | grep` / `printf | jq`
  # pipeline run concurrently and bash -x interleaves their lines in whichever
  # order the kernel schedules them, so line order is not a property of the
  # program — the multiset of executed statements is.
  grep -v '^+ case "${1:-}" in$' "$TMPROOT/$tag.trace-script.err" | LC_ALL=C sort > "$TMPROOT/$tag.trace-script.filtered"
  LC_ALL=C sort "$TMPROOT/$tag.trace-inline.err" > "$TMPROOT/$tag.trace-inline.sorted"
  # denies are exempt from the trace comparison: the stderr mirror is a statement the string never had
  [ "$(cat "$TMPROOT/$tag.inline.rc")" = 2 ] || cmp -s "$TMPROOT/$tag.trace-inline.sorted" "$TMPROOT/$tag.trace-script.filtered" || why="$why xtrace"
  # the expected branch really ran (guards against three copies of a wrong thing agreeing)
  local rc; rc="$(cat "$TMPROOT/$tag.inline.rc")"
  if [ -z "$why" ]; then
    ok "$n. $label  [rc=$rc]"
  else
    bad "$n. $label — DIVERGED:$why"
    for m in script shipped; do
      diff "$TMPROOT/$tag.inline.out" "$TMPROOT/$tag.$m.out" | sed 's/^/       out /' | head -6
      diff "$TMPROOT/$tag.inline.err" "$TMPROOT/$tag.$m.err" | sed 's/^/       err /' | head -6
    done
    diff "$TMPROOT/$tag.trace-inline.sorted" "$TMPROOT/$tag.trace-script.filtered" | sed 's/^/       trace /' | head -10
  fi
}

# expect <n> <what> <file-suffix> <grep-pattern>  — the branch under test actually fired in the INLINE run
expect() {
  local n="$1" what="$2" suf="$3" pat="$4"
  if grep -q -- "$pat" "$TMPROOT/c$n.inline.$suf"; then ok "$n. …and the reference took the expected branch ($what)"
  else bad "$n. reference did not take the expected branch ($what): no /$pat/ in $suf" "$(head -c 300 "$TMPROOT/c$n.inline.$suf")"; fi
}
expect_rc() {
  local n="$1" want="$2" got; got="$(cat "$TMPROOT/c$n.inline.rc")"
  [ "$got" = "$want" ] && ok "$n. …reference exit code is $want" || bad "$n. reference exit code $got, wanted $want"
}

pl() { jq -nc --arg c "$1" '{tool_name:"Bash", tool_input:{command:$c}}'; }

# ── 1-3. non-git / degenerate payloads ──────────────────────────────────────
equiv 1 "ordinary 'ls -la': only parallelism-tracker runs" "$CWD_PLAIN" "$PLUGIN_FULL" "$(pl 'ls -la')"
expect 1 "tracker" out '^tracker check Bash$'
expect_rc 1 0

equiv 2 "empty payload (stdin is zero bytes)" "$CWD_PLAIN" "$PLUGIN_FULL" ""
expect_rc 2 0

equiv 3 "malformed JSON payload (jq parse error to stderr, nothing blocks)" "$CWD_PLAIN" "$PLUGIN_FULL" '{not json'
expect 3 "jq error" err 'jq: parse error'
expect_rc 3 0

# ── 4-5. git commit: guard routing + staged secret gate ─────────────────────
equiv 4 "git commit --no-verify, staged scan clean: guard runs, scan output to stderr, allowed" "$CWD_PLAIN" "$PLUGIN_FULL" "$(pl 'git commit --no-verify -m wip')"
expect 4 "git-guard" err '^git-guard ran'
expect 4 "staged scan" err '^secret-scan staged$'
expect_rc 4 0

equiv 5 "git commit with a staged secret: BLOCKED JSON on stdout, exit 2" "$CWD_PLAIN" "$PLUGIN_FULL" "$(pl 'git add -A && git commit -m x')" FAKE_SCAN_RC=1
expect 5 "deny" out '^{"error": "BLOCKED: secret detected in staged changes'
expect_rc 5 2

# ── 6-10. git push: quality gate, push secret gate, self-scan ───────────────
equiv 6 "git push, every gate green, no native hook: falsify + corpus run inline" "$CWD_PLAIN" "$PLUGIN_FULL" "$(pl 'git push origin main')"
expect 6 "quality gate verdict" err '^all quality gates pass$'
expect 6 "push-range scan sets SECRET_SCAN_REQUIRE" err '^secret-scan --require SECRET_SCAN_REQUIRE=1$'
expect 6 "falsify" err '^falsify demo-domain --assert-score 1.0$'
expect 6 "corpus" err '^corpus run$'
expect_rc 6 0

equiv 7 "git push, quality gate rc 2: BLOCKED, exit 2" "$CWD_PLAIN" "$PLUGIN_FULL" "$(pl 'git push')" FAKE_HSTATE_RC=2
expect 7 "deny" out '^{"error": "BLOCKED: pre-push quality gate failed'
expect_rc 7 2

equiv 8 "git push, quality gate rc 7 (never evaluated): UNAVAILABLE warning, push allowed" "$CWD_PLAIN" "$PLUGIN_FULL" "$(pl 'git push --force-with-lease')" FAKE_HSTATE_RC=7
expect 8 "unavailable" err 'quality-gate verdict UNAVAILABLE (exit 7)'
expect_rc 8 0

equiv 9 "git push, push-range secret gate fails: BLOCKED" "$CWD_PLAIN" "$PLUGIN_FULL" "$(pl 'git push')" FAKE_SCAN_REQUIRE_RC=1
expect 9 "deny" out '^{"error": "BLOCKED: pre-push secret gate failed (gitleaks)'
expect_rc 9 2

equiv 10 "git push, self-scan fails: BLOCKED" "$CWD_PLAIN" "$PLUGIN_FULL" "$(pl 'git push')" FAKE_SELFSCAN_RC=1
expect 10 "deny" out '^{"error": "BLOCKED: pre-push self-scan failed'
expect_rc 10 2

# ── 11-12. native-hook dedup + the HMD_SKIP invariant ───────────────────────
equiv 11 "git push with core.hooksPath=.heimdall/hooks wired: oracle+corpus DELEGATED, not run inline" "$CWD_NATIVE" "$PLUGIN_FULL" "$(pl 'git push')"
expect 11 "delegation notice" err 'delegated to the native pre-push hook'
if grep -q '^falsify' "$TMPROOT/c11.inline.err" || grep -q '^corpus' "$TMPROOT/c11.inline.err"; then
  bad "11. reference ran falsify/corpus inline despite the wired native hook"
else
  ok "11. …reference skipped the inline falsify/corpus run"
fi

equiv 12 "HMD_SKIP=1 + wired native hook: HMD_SKIP does NOT reach this layer, falsify+corpus still run" "$CWD_NATIVE" "$PLUGIN_FULL" "$(pl 'git push')" HMD_SKIP=1
expect 12 "falsify still ran" err '^falsify demo-domain'
expect 12 "corpus still ran" err '^corpus run$'

# ── 13-16. oracle falsifiability + corpus denies ────────────────────────────
equiv 13 "falsify fails, stamp present, report.json present: stamp --report, BLOCKED" "$CWD_REPORT" "$PLUGIN_FULL" "$(pl 'git push')" FAKE_FALSIFY_RC=1
expect 13 "stamp --report" err '^stamp --report evals/oracles/demo-domain/report.json --branch heimdall/blocked/demo-domain$'
expect 13 "deny" out '^{"error": "BLOCKED: oracle gate demo-domain is not falsifiable'
expect_rc 13 2

equiv 14 "falsify fails, stamp present, no report.json: stamp --violation, BLOCKED" "$CWD_PLAIN" "$PLUGIN_FULL" "$(pl 'git push')" FAKE_FALSIFY_RC=1
expect 14 "stamp --violation" err '^stamp --violation oracle gate demo-domain is not falsifiable'
expect_rc 14 2

equiv 15 "falsify fails, NO stamp bin: BLOCKED without a stamp" "$CWD_PLAIN" "$PLUGIN_NOSTAMP" "$(pl 'git push')" FAKE_FALSIFY_RC=1
expect 15 "deny" out 'oracle gate demo-domain is not falsifiable'
expect_rc 15 2

equiv 16 "corpus run fails: stamp --violation corpus, BLOCKED" "$CWD_PLAIN" "$PLUGIN_FULL" "$(pl 'git push')" FAKE_CORPUS_RC=1
expect 16 "stamp" err '^stamp --violation corpus regression'
expect 16 "deny" out '^{"error": "BLOCKED: corpus regression'
expect_rc 16 2

# ── 17-18. the core.hooksPath= payloads (text in the COMMAND, not the cwd) ──
equiv 17 "command text 'git config core.hooksPath=…; git push' (push not at ^): no push gate" "$CWD_PLAIN" "$PLUGIN_FULL" "$(pl 'git config core.hooksPath=.heimdall/hooks && git push')"
if grep -q 'heimdall-state' "$TMPROOT/c17.inline.err" "$TMPROOT/c17.inline.out"; then
  bad "17. reference ran the push gate on a command whose push is not at line start"
else
  ok "17. …reference did not arm the push gate (regex anchored at ^git\\s+push)"
fi
expect_rc 17 0

equiv 18 "command text 'git -c core.hooksPath= commit': -c form matches neither guard nor commit regex" "$CWD_PLAIN" "$PLUGIN_FULL" "$(pl 'git -c core.hooksPath= commit -m x')"
expect_rc 18 0

# ── 19. APPLIES via .planning/detected-stack.json ──────────────────────────
equiv 19 "APPLIES through .planning/detected-stack.json (no evals/oracles/<dom> in cwd)" "$CWD_STACK" "$PLUGIN_FULL" "$(pl 'git push')"
expect 19 "falsify via stack file" err '^falsify demo-domain'

# ── 20. tool_input.command with the escape shapes hook-payload-escaping cares about
equiv 20 "command carrying \\n, \\t, quotes and backslashes in the payload" "$CWD_PLAIN" "$PLUGIN_FULL" "$(pl $'printf \'a\\tb\\n\' "q\\"q" \\\\ end')"
expect_rc 20 0

# ── 21. no CLAUDE_PLUGIN_ROOT: the plugin root is the script's OWN location ──
# 2026-10-11, deliberate change vs the historical inline chain, which fell back to
# the cwd's git toplevel (then pwd): in any repo that is not a heimdall checkout it
# looked for bin/ in the wrong place. The copy inside PLUGIN_FULL (fake gate bins,
# incl. a fake parallelism-tracker) runs with CLAUDE_PLUGIN_ROOT unset from a
# foreign git repo and from a non-git dir; ITS tracker must be the one that runs.
c21_bad=""
for cwd in "$CWD_PLAIN" "$CWD_NOGIT"; do
  ( cd "$cwd" && printf '%s' "$(pl 'ls')" | env -u CLAUDE_PLUGIN_ROOT bash "$PLUGIN_FULL/bin/heimdall-precheck-bash" ) >"$TMPROOT/c21.out" 2>"$TMPROOT/c21.err"
  rc=$?
  { [ "$rc" = 0 ] && grep -qx 'tracker check Bash' "$TMPROOT/c21.out" && ! grep -q 'No such file' "$TMPROOT/c21.out" "$TMPROOT/c21.err" && [ ! -s "$TMPROOT/c21.err" ]; } \
    || c21_bad="$c21_bad $(basename "$cwd")(rc=$rc: $(head -c 120 "$TMPROOT/c21.out"))"
done
if [ -z "$c21_bad" ]; then
  ok "21. CLAUDE_PLUGIN_ROOT unset: plugin root comes from the script's own location, not the cwd repo (foreign git repo and non-git dir)"
else
  bad "21. plugin root resolved from the cwd instead of the script's own location" "$c21_bad"
fi

# ── 22. missing $PLUGIN/bin/heimdall-state → falls back to `heimdall-state` by name on PATH
# Whether PATH has one (real bin → "No heimdall-state.json found", exit 1) or not
# (bash "command not found", exit 127) depends on the machine; either way both
# forms must agree, and the chain must land in the UNAVAILABLE-warn-and-allow branch.
# bash names the SOURCE in a missing-command diagnostic ("bash: " for -c,
# "<script>: line N: " for a file); strip that prefix — the one tolerance here is
# bash's, not the chain's.
strip_bash_prefix() { sed -E 's#^(bash|/[^:]+): (line [0-9]+: )?#<bash>: #' "$1"; }
run_variant c22 inline "$CWD_PLAIN" "$PLUGIN_NOHSTATE" "$(pl 'git push')"
run_variant c22 script "$CWD_PLAIN" "$PLUGIN_NOHSTATE" "$(pl 'git push')"
if cmp -s "$TMPROOT/c22.inline.out" "$TMPROOT/c22.script.out" \
   && cmp -s "$TMPROOT/c22.inline.rc" "$TMPROOT/c22.script.rc" \
   && [ "$(strip_bash_prefix "$TMPROOT/c22.inline.err")" = "$(strip_bash_prefix "$TMPROOT/c22.script.err")" ] \
   && grep -q 'quality-gate verdict UNAVAILABLE (exit [0-9]*)' "$TMPROOT/c22.script.err" \
   && [ "$(cat "$TMPROOT/c22.inline.rc")" = 0 ]; then
  ok "22. absent \$PLUGIN/bin/heimdall-state → PATH fallback → UNAVAILABLE warning, push allowed; identical  [rc=0]"
else
  bad "22. heimdall-state fallback diverged" "$(diff "$TMPROOT/c22.inline.err" "$TMPROOT/c22.script.err" | head -4)"
fi

# ── 23. the shipped hooks.json command is the recognised wrapper OR the inline
if [ "$SHIPPED" = "$INLINE" ]; then
  ok "23. hooks.json still ships the inline chain (pre-swap); it matched the script in every case above"
elif grep -qF '"$PLUGIN/bin/heimdall-precheck-bash"' <<<"$SHIPPED" && ! grep -q '|| true' <<<"$SHIPPED"; then
  ok "23. hooks.json ships the wrapper one-liner calling \$PLUGIN/bin/heimdall-precheck-bash with its exit code propagated (no '|| true')"
else
  bad "23. hooks.json Bash command is neither the inline chain nor the precheck-bash wrapper" "$SHIPPED"
fi

# ── 24. every deny states its reason on stderr too ──────────────────────────
# Claude Code surfaces ONLY stderr for an exit-2 hook and ignores stdout, so the
# stdout-only verdict showed up as "hook error … No stderr output": a blocked
# `git push` with no stated reason (seen live in a foreign repo whose own quality
# gates were failing). Cases 5,7,9,10,13,14,15,16 above are the deny branches.
c24_bad=""
for n in 5 7 9 10 13 14 15 16; do
  for m in script shipped; do
    { grep -q '^{"error": "BLOCKED' "$TMPROOT/c$n.$m.out" && grep -qxF -f "$TMPROOT/c$n.$m.out" "$TMPROOT/c$n.$m.err"; } || c24_bad="$c24_bad c$n.$m"
  done
done
if [ -z "$c24_bad" ]; then
  ok "24. every deny branch (8 cases x script+shipped) repeats its verdict on stderr, stdout unchanged"
else
  bad "24. deny verdict missing from stderr (exit 2 + empty stderr = a silent block):$c24_bad"
fi

# ── 25. shipped Bash hook, CLAUDE_PLUGIN_ROOT unset, session cwd in ANOTHER repo ─
# The wrapper must not resolve the plugin root to the cwd repo and then exit 127 on
# every Bash call: fail OPEN, stdout empty, exactly one stderr line saying why.
c25_bad=""
for cwd in "$CWD_PLAIN" "$CWD_NOGIT"; do
  ( cd "$cwd" && printf '%s' "$(pl 'git push origin main')" | env -u CLAUDE_PLUGIN_ROOT bash -c "$SHIPPED" ) >"$TMPROOT/c25.out" 2>"$TMPROOT/c25.err"
  rc=$?
  { [ "$rc" = 0 ] && [ ! -s "$TMPROOT/c25.out" ] && [ "$(wc -l <"$TMPROOT/c25.err" | tr -d ' ')" = 1 ] && grep -q 'precheck-bash not found' "$TMPROOT/c25.err"; } \
    || c25_bad="$c25_bad $(basename "$cwd")(rc=$rc: $(head -c 120 "$TMPROOT/c25.err"))"
done
# …while a cwd that IS a heimdall checkout (hmd developing itself, env var unset) still resolves to it.
CWD_DEV="$TMPROOT/cwd-dev"; mkdir -p "$CWD_DEV"; cp -R "$PLUGIN_FULL/bin" "$CWD_DEV/bin"; ( cd "$CWD_DEV" && git init -q )
( cd "$CWD_DEV" && printf '%s' "$(pl 'ls')" | env -u CLAUDE_PLUGIN_ROOT bash -c "$SHIPPED" ) >"$TMPROOT/c25.out" 2>"$TMPROOT/c25.err"
grep -qx 'tracker check Bash' "$TMPROOT/c25.out" || c25_bad="$c25_bad dev-checkout($(head -c 120 "$TMPROOT/c25.err"))"
if [ -z "$c25_bad" ]; then
  ok "25. env var unset in a foreign cwd: Bash hook fails open with one stderr line (no 127); a heimdall-checkout cwd still resolves"
else
  bad "25. Bash hook wrapper mishandles an unset CLAUDE_PLUGIN_ROOT:$c25_bad"
fi

# ── 26. same for the Agent hook (the other unguarded `$PLUGIN/bin/<script>` call) ─
AGENT_SHIPPED="$(jq -r '.hooks.PreToolUse[] | select(.matcher=="Agent") | .hooks[0].command' "$HOOKS_JSON")"
c26_bad=""
for cwd in "$CWD_PLAIN" "$CWD_NOGIT"; do
  ( cd "$cwd" && printf '%s' '{"tool_name":"Agent","tool_input":{}}' | env -u CLAUDE_PLUGIN_ROOT bash -c "$AGENT_SHIPPED" ) >"$TMPROOT/c26.out" 2>"$TMPROOT/c26.err"
  rc=$?
  { [ "$rc" = 0 ] && [ ! -s "$TMPROOT/c26.out" ] && [ "$(wc -l <"$TMPROOT/c26.err" | tr -d ' ')" = 1 ] && grep -q 'precheck-agent not found' "$TMPROOT/c26.err"; } \
    || c26_bad="$c26_bad $(basename "$cwd")(rc=$rc: $(head -c 120 "$TMPROOT/c26.err"))"
done
if [ -z "$c26_bad" ]; then
  ok "26. env var unset in a foreign cwd: Agent hook fails open with one stderr line (no 127)"
else
  bad "26. Agent hook wrapper mishandles an unset CLAUDE_PLUGIN_ROOT:$c26_bad"
fi

printf '\n  heimdall-precheck-bash: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
