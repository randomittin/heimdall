#!/usr/bin/env bash
# shellcheck disable=SC1090,SC2016,SC2030,SC2031  # the lib is sourced by a computed path; single quotes hold the literal $ of programs and of mutation texts; every helper runs in a subshell on purpose
#
# guardrail-enabled.test.sh -- bin/lib/hmd_guardrail_enabled.sh, the read side of the guardrail switch
# (3.x M1, task T2.2 of docs/superpowers/plans/2026-11-12-3x-m1-skill-registry.md).
#
# hmd_guardrail_enabled <id> exits 1 (disabled: skip that guard) only when $HEIMDALL_HOME/guardrails-off lists the id AND guardrails.manifest.json
# calls it `recommended`. Every other outcome exits 0 (enabled): a core id, an unknown id, no file, no jq, a manifest that is missing or wrong, anything
# it cannot read. Core is never switchable (INV-G1) and any doubt is enabled (INV-G5).
#
#   A. the real guardrails.manifest.json, found through the lib's own location, from a cwd that is not the repository
#        INV-G2  no guardrails-off: every row is enabled
#        INV-G1  every row listed at once: each core row stays enabled, each recommended row is disabled
#        INV-G3  each recommended guard listed alone: it is disabled and the row next to it is not
#   B. checks_core, over a fixture manifest and fixture guardrails-off files (also the oracle of F)
#        the switch; every id that is not a clean `recommended` row; which lines of guardrails-off count; INV-G5: a manifest that is missing, unreadable,
#        empty, not JSON or the wrong shape, no jq, an unreadable guardrails-off; INV-G7: a repository's own guardrails-off and guardrails.manifest.json,
#        and a relative HEIMDALL_HOME, manifest override or CLAUDE_PLUGIN_ROOT, are never read; where the manifest comes from (override, CLAUDE_PLUGIN_ROOT,
#        the lib's own location, fixed when it is sourced so a later cd cannot move it); the HOME fallback; paths with spaces; no output; no name outside its own
#   C. cost and reach: the fast path forks nothing, bash / sh / dash / zsh, set -eu, the call-site idiom of the lib's header
#   F. falsifiability: every defect injected ALONE into a copy of the lib (each fail-safe `return 0` made `return 1`, the `return 1` made `return 0`, and a list of
#      specific ones: tier, repeats, shape, line match, absolute paths, precedence, quoting, noise ...) turns a check of B red, while an unmodified copy passes them all
set -u

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$REPO/bin/lib/hmd_guardrail_enabled.sh"
MANIFEST="$REPO/guardrails.manifest.json"
PASS=0
FAIL=0
ok()      { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
bad()     { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; if [ -n "${2:-}" ]; then printf '       %s\n' "$2"; fi; }
skip()    { printf '  skip %s\n' "$1"; }
section() { printf '\n%s\n' "$1"; }
finish()  { printf '\n  guardrail-enabled: %d passed, %d failed\n' "$PASS" "$FAIL"; [ "$FAIL" -eq 0 ]; }

command -v jq >/dev/null 2>&1 || { echo "FATAL: jq not found (the lib's verdict needs it)"; exit 2; }
[ -f "$LIB" ] || { bad "bin/lib/hmd_guardrail_enabled.sh does not exist"; finish; exit 1; }

WORK="$(mktemp -d)" || exit 2
trap 'rm -rf "$WORK"' EXIT
NOHOME="$WORK/nohome"
mkdir -p "$NOHOME"

# ---- fixtures ---------------------------------------------------------------------------------------------------------------------------------------
# the fixture manifest: two recommended guards, a core one, ids listed twice (both orders and twice recommended), and rows with no clean tier
FIX="$WORK/fix.json"
cat > "$FIX" <<'EOF'
{"schema": 1, "guardrails": [
  {"id": "opt-a", "kind": "guard", "tier": "recommended", "layer": "precheck-bash", "why": "w", "proof": "p"},
  {"id": "opt-b", "kind": "guard", "tier": "recommended", "layer": "precheck-bash", "why": "w", "proof": "p"},
  {"id": "core-a", "kind": "guard", "tier": "core", "layer": "precheck-bash", "why": "w", "proof": "p"},
  {"id": "dup-rr", "kind": "guard", "tier": "recommended", "layer": "x", "why": "w", "proof": "p"},
  {"id": "dup-rr", "kind": "guard", "tier": "recommended", "layer": "x", "why": "w", "proof": "p"},
  {"id": "dup-rc", "kind": "guard", "tier": "recommended", "layer": "x", "why": "w", "proof": "p"},
  {"id": "dup-rc", "kind": "guard", "tier": "core", "layer": "x", "why": "w", "proof": "p"},
  {"id": "dup-cr", "kind": "guard", "tier": "core", "layer": "x", "why": "w", "proof": "p"},
  {"id": "dup-cr", "kind": "guard", "tier": "recommended", "layer": "x", "why": "w", "proof": "p"},
  {"id": "no-tier", "kind": "guard", "layer": "x", "why": "w", "proof": "p"},
  {"id": "tier-null", "tier": null},
  {"id": "tier-optional", "tier": "optional"},
  {"id": "tier-case", "tier": "Recommended"},
  {"id": "tier-padded", "tier": "recommended "},
  {"id": "tier-list", "tier": ["recommended"]}
]}
EOF
row() { printf '{"schema": 1, "guardrails": [{"id": "opt-a", "kind": "guard", "tier": "%s", "layer": "x", "why": "w", "proof": "p"}]}\n' "$1"; }
row recommended > "$WORK/m_rec.json"   # one row: opt-a is recommended
row core > "$WORK/m_core.json"         # one row: opt-a is core
printf '%s' '{"guardrails":[{"id":"opt-a","tier":"recommended"}]}' > "$WORK/good.json"

# mkhome DIR ID... -- DIR/guardrails-off lists the IDs, one per line
mkhome() { local d="$1"; shift; mkdir -p "$d"; printf '%s\n' "$@" > "$d/guardrails-off"; }
H_ALL="$WORK/h_all";     mkhome "$H_ALL" opt-a opt-b core-a dup-rr dup-rc dup-cr no-tier tier-null tier-optional tier-case tier-padded tier-list ghost
H_ONE="$WORK/h_one";     mkhome "$H_ONE" opt-a
H_EMPTY="$WORK/h_empty"; mkdir -p "$H_EMPTY"
H_BLANK="$WORK/h_blank"; mkdir -p "$H_BLANK"; : > "$H_BLANK/guardrails-off"
H_DIR="$WORK/h_dir";     mkdir -p "$H_DIR/guardrails-off"
# near misses of opt-a (a prefix, a suffix, padding, case, a trailing CR, a comment, globs, a blank line), then opt-b exactly, as a last line with no newline
H_NEAR="$WORK/h_near";   mkdir -p "$H_NEAR"
{ printf '%s\n' 'opt-a-x' 'x-opt-a' ' opt-a' 'opt-a ' 'OPT-A' 'opt-a#' '# opt-a' 'opt-*' '*' '.*' 'opt-.' ''; printf 'opt-a\r\n'; printf 'opt-b'; } > "$H_NEAR/guardrails-off"
E_ALL=(HEIMDALL_HOME="$H_ALL" HMD_GUARDRAILS_MANIFEST="$FIX")
E_ONE=(HEIMDALL_HOME="$H_ONE" HMD_GUARDRAILS_MANIFEST="$FIX")

# files nobody can read (skipped as root, who reads everything)
CAN_UNREAD=0
if [ "$(id -u)" != 0 ]; then
  mkhome "$WORK/h_unread" opt-a
  chmod 000 "$WORK/h_unread/guardrails-off"
  cp "$WORK/m_rec.json" "$WORK/unread.json"
  chmod 000 "$WORK/unread.json"
  if [ ! -r "$WORK/h_unread/guardrails-off" ] && [ ! -r "$WORK/unread.json" ]; then CAN_UNREAD=1; fi
fi
NOJQ="$WORK/nojq"; mkdir -p "$NOJQ"; ln -s "$(command -v grep)" "$NOJQ/grep"   # a PATH with grep and no jq
# a grep and a jq that fail loudly, and a manifest that is not JSON, to prove nothing they say reaches the hook
BOOM_GREP="$WORK/boom_grep"; mkdir -p "$BOOM_GREP"; printf '#!/bin/sh\necho "grep: boom" >&2\nexit 2\n' > "$BOOM_GREP/grep"; chmod +x "$BOOM_GREP/grep"
BOOM_JQ="$WORK/boom_jq"; mkdir -p "$BOOM_JQ"; printf '#!/bin/sh\necho "jq: boom" >&2\nexit 5\n' > "$BOOM_JQ/jq"; chmod +x "$BOOM_JQ/jq"
printf '%s' 'garbage{' > "$WORK/garbage.json"

# a stranger's repository: its own guardrails-off in the three places a clone could ship one, a manifest that calls opt-a recommended, a bin/lib
STR="$WORK/stranger"
mkdir -p "$STR/.heimdall" "$STR/.planning" "$STR/bin/lib"
for f in "$STR/guardrails-off" "$STR/.heimdall/guardrails-off" "$STR/.planning/guardrails-off"; do printf 'opt-a\n' > "$f"; done
cp "$WORK/m_rec.json" "$STR/guardrails.manifest.json"
REL="$WORK/rel"; mkdir -p "$REL/plug"                      # relative-path targets: rel.json, plug/guardrails.manifest.json
cp "$WORK/m_rec.json" "$REL/rel.json"; cp "$WORK/m_rec.json" "$REL/plug/guardrails.manifest.json"
PR_REC="$WORK/pr_rec"; mkdir -p "$PR_REC"; cp "$WORK/m_rec.json" "$PR_REC/guardrails.manifest.json"      # plugin roots for the precedence checks
PR_CORE="$WORK/pr_core"; mkdir -p "$PR_CORE"; cp "$WORK/m_core.json" "$PR_CORE/guardrails.manifest.json"
HF="$WORK/hf"; mkdir -p "$HF/.heimdall"; printf 'opt-a\n' > "$HF/.heimdall/guardrails-off"                   # a HOME that holds .heimdall/guardrails-off
SP="$WORK/sp ace"; mkdir -p "$SP/home dir"; printf 'opt-a\n' > "$SP/home dir/guardrails-off"; cp "$WORK/m_rec.json" "$SP/m rec.json"

# ---- harness ----------------------------------------------------------------------------------------------------------------------------------------
# rc_of [-C DIR] LIB ID [NAME=VALUE ...] -- the exit status of `hmd_guardrail_enabled ID` after sourcing LIB, in a subshell that starts from this test's environment with
# HEIMDALL_HOME, CLAUDE_PLUGIN_ROOT and HMD_GUARDRAILS_MANIFEST unset and HOME an empty directory, then the NAME=VALUEs, inside DIR when given. Prints the status and
# nothing else, so a lib that prints anything spoils the comparison.
rc_of() {
  (
    unset HEIMDALL_HOME CLAUDE_PLUGIN_ROOT HMD_GUARDRAILS_MANIFEST
    export HOME="$NOHOME"
    if [ "$1" = -C ]; then cd "$2" || exit 97; shift 2; fi
    _lib="$1"; _id="$2"; shift 2
    # shellcheck disable=SC2163  # NAME=VALUE is the argument on purpose
    for _kv in "$@"; do export "$_kv"; done
    . "$_lib" 2>/dev/null
    hmd_guardrail_enabled "$_id"
    printf '%s' "$?"
  )
}
# rc_rel PLUGIN CWD ID [NAME=VALUE ...] -- source PLUGIN/bin/lib/hmd_guardrail_enabled.sh by a RELATIVE path, then cd to CWD and make the call there
rc_rel() {
  (
    unset HEIMDALL_HOME CLAUDE_PLUGIN_ROOT HMD_GUARDRAILS_MANIFEST
    export HOME="$NOHOME"
    _p="$1"; _c="$2"; _id="$3"; shift 3
    # shellcheck disable=SC2163  # NAME=VALUE is the argument on purpose
    for _kv in "$@"; do export "$_kv"; done
    cd "$_p" || exit 97
    # shellcheck source=/dev/null  # the relative path is the point
    . ./bin/lib/hmd_guardrail_enabled.sh 2>/dev/null
    cd "$_c" || exit 97
    hmd_guardrail_enabled "$_id"
    printf '%s' "$?"
  )
}
# noise LIB ID [NAME=VALUE ...] -- every byte sourcing LIB and calling the function wrote to stdout or stderr (a hook's stdout is parsed, its stderr is shown)
noise() {
  (
    unset HEIMDALL_HOME CLAUDE_PLUGIN_ROOT HMD_GUARDRAILS_MANIFEST
    export HOME="$NOHOME"
    _lib="$1"; _id="$2"; shift 2
    # shellcheck disable=SC2163  # NAME=VALUE is the argument on purpose
    for _kv in "$@"; do export "$_kv"; done
    . "$_lib"
    hmd_guardrail_enabled "$_id"
  ) 2>&1
}
# hygiene LIB -- "clean", or what sourcing LIB (twice) and calling it changed in the caller's shell: a variable or function outside its own prefix, a caller's variable
hygiene() {
  (
    unset HEIMDALL_HOME CLAUDE_PLUGIN_ROOT HMD_GUARDRAILS_MANIFEST
    export HOME="$NOHOME" HEIMDALL_HOME="$H_ONE" HMD_GUARDRAILS_MANIFEST="$FIX"
    id=keep home=keep file=keep meta=keep verdict=keep
    compgen -v | LC_ALL=C sort > "$WORK/vars0"
    compgen -A function | LC_ALL=C sort > "$WORK/funcs0"
    . "$1"
    . "$1"
    hmd_guardrail_enabled opt-a
    hmd_guardrail_enabled core-a
    compgen -v | LC_ALL=C sort > "$WORK/vars1"
    compgen -A function | LC_ALL=C sort > "$WORK/funcs1"
    newvars="$(LC_ALL=C comm -13 "$WORK/vars0" "$WORK/vars1" | awk '!/^HMD_GUARDRAIL_ENABLED/' | tr '\n' ' ')"
    newfuncs="$(LC_ALL=C comm -13 "$WORK/funcs0" "$WORK/funcs1" | awk '!/^hmd_guardrail_enabled/' | tr '\n' ' ')"
    if [ -z "$newvars$newfuncs" ] && [ "$id $home $file $meta $verdict" = "keep keep keep keep keep" ]; then
      echo clean
    else
      echo "new variables [$newvars] new functions [$newfuncs] caller's variables now: $id $home $file $meta $verdict"
    fi
  )
}
# mkplugin DIR [MANIFEST] -- DIR/bin/lib holds a copy of the lib under test, DIR/guardrails.manifest.json a copy of MANIFEST when given
mkplugin() {
  rm -rf "${1:?}"
  mkdir -p "$1/bin/lib"
  cp "$L" "$1/bin/lib/hmd_guardrail_enabled.sh"
  if [ -n "${2:-}" ]; then cp "$2" "$1/guardrails.manifest.json"; fi
}

# chk LABEL WANT GOT [DETAIL] -- report mode prints ok or FAIL; quiet mode (a defect injected into a copy of the lib, in a subshell) leaves that subshell at the first mismatch
MODE=report
chk() {
  if [ "$3" = "$2" ]; then
    if [ "$MODE" = report ]; then ok "$1"; fi
  elif [ "$MODE" = report ]; then
    bad "$1" "want '$2', got '$3'${4:+ ($4)}"
  else
    exit 1
  fi
  return 0
}
# t LABEL WANT ARGS... -- the check: rc_of ARGS must print WANT
t() { local label="$1" want="$2"; shift 2; chk "$label" "$want" "$(rc_of "$@")"; }
# badm LABEL CONTENT -- opt-a is listed, and a manifest holding CONTENT still cannot disable it
badm() {
  printf '%s' "$2" > "$WORK/bad.json"
  t "manifest $1: enabled" 0 "$L" opt-a HEIMDALL_HOME="$H_ONE" HMD_GUARDRAILS_MANIFEST="$WORK/bad.json"
}

# ---- B. the checks every defect must trip (and the proof of every claim of the lib) ---------------------------------------------------------------------
# L is the lib under test. Ordered so that the broadest checks come first: a defect usually dies in the first few.
checks_core() {
  t "a recommended id listed in guardrails-off is disabled" 1 "$L" opt-a "${E_ALL[@]}"
  t "a core id listed there stays enabled (INV-G1)" 0 "$L" core-a "${E_ALL[@]}"
  t "an id the manifest does not know stays enabled" 0 "$L" ghost "${E_ALL[@]}"
  t "listing one id leaves a recommended neighbour enabled (INV-G3)" 0 "$L" opt-b "${E_ONE[@]}"
  t "listing one id leaves a core id enabled (INV-G3)" 0 "$L" core-a "${E_ONE[@]}"
  t "an id that is not exactly a line (prefix, suffix, padding, case, CR, comment, glob) is enabled" 0 "$L" opt-a HEIMDALL_HOME="$H_NEAR" HMD_GUARDRAILS_MANIFEST="$FIX"
  t "the exact id as a last line with no newline matches" 1 "$L" opt-b HEIMDALL_HOME="$H_NEAR" HMD_GUARDRAILS_MANIFEST="$FIX"
  t "no guardrails-off file: enabled" 0 "$L" opt-a HEIMDALL_HOME="$H_EMPTY" HMD_GUARDRAILS_MANIFEST="$FIX"
  t "an empty id: enabled" 0 "$L" "" "${E_ALL[@]}"
  for g in dup-rr dup-rc dup-cr no-tier tier-null tier-optional tier-case tier-padded tier-list; do
    t "listed id $g (repeated in the manifest, or without a clean recommended tier): enabled" 0 "$L" "$g" "${E_ALL[@]}"
  done
  t "a relative HEIMDALL_HOME is the cwd in disguise: ignored (INV-G7)" 0 -C "$STR" "$L" opt-a HEIMDALL_HOME=.heimdall HMD_GUARDRAILS_MANIFEST="$WORK/m_rec.json"
  t "control: that file IS read when HEIMDALL_HOME is the operator's, absolute" 1 -C "$STR" "$L" opt-a HEIMDALL_HOME="$STR/.heimdall" HMD_GUARDRAILS_MANIFEST="$WORK/m_rec.json"
  t "a repository's own guardrails-off files are never read (INV-G7)" 0 -C "$STR" "$L" opt-a HEIMDALL_HOME="$H_EMPTY" HMD_GUARDRAILS_MANIFEST="$WORK/m_rec.json"
  t "a relative manifest override is the cwd in disguise: ignored" 0 -C "$REL" "$L" opt-a HEIMDALL_HOME="$H_ONE" HMD_GUARDRAILS_MANIFEST=rel.json
  t "control: the same manifest by an absolute path is read" 1 -C "$REL" "$L" opt-a HEIMDALL_HOME="$H_ONE" HMD_GUARDRAILS_MANIFEST="$REL/rel.json"
  t "paths with spaces (HEIMDALL_HOME and the manifest) are quoted" 1 "$L" opt-a HEIMDALL_HOME="$SP/home dir" HMD_GUARDRAILS_MANIFEST="$SP/m rec.json"
  t "no jq on PATH: enabled (INV-G5)" 0 "$L" opt-a "${E_ONE[@]}" PATH="$NOJQ"
  t "manifest missing: enabled (INV-G5)" 0 "$L" opt-a HEIMDALL_HOME="$H_ONE" HMD_GUARDRAILS_MANIFEST="$WORK/nope.json"
  t "control: a minimal well-formed manifest does disable it" 1 "$L" opt-a HEIMDALL_HOME="$H_ONE" HMD_GUARDRAILS_MANIFEST="$WORK/good.json"
  badm "that is not JSON" 'garbage{'
  badm "that is empty" ''
  badm "that is an array" '[]'
  badm "that is {}" '{}'
  badm "that is null" 'null'
  badm "that is a string" '"opt-a"'
  badm "whose guardrails is a string" '{"guardrails":"opt-a"}'
  badm "whose guardrails is an object of rows, not an array" '{"guardrails":{"a":{"id":"opt-a","tier":"recommended"}}}'
  badm "with a row that is not an object" '{"guardrails":[1,{"id":"opt-a","tier":"recommended"}]}'
  badm "with a null tier" '{"guardrails":[{"id":"opt-a","tier":null}]}'
  t "a guardrails-off that is empty: enabled" 0 "$L" opt-a HEIMDALL_HOME="$H_BLANK" HMD_GUARDRAILS_MANIFEST="$FIX"
  t "a guardrails-off that is a directory: enabled" 0 "$L" opt-a HEIMDALL_HOME="$H_DIR" HMD_GUARDRAILS_MANIFEST="$FIX"
  t "a manifest that is a directory: enabled" 0 "$L" opt-a HEIMDALL_HOME="$H_ONE" HMD_GUARDRAILS_MANIFEST="$WORK"
  if [ "$CAN_UNREAD" = 1 ]; then
    t "an unreadable manifest: enabled" 0 "$L" opt-a HEIMDALL_HOME="$H_ONE" HMD_GUARDRAILS_MANIFEST="$WORK/unread.json"
    t "an unreadable guardrails-off: enabled" 0 "$L" opt-a HEIMDALL_HOME="$WORK/h_unread" HMD_GUARDRAILS_MANIFEST="$FIX"
  fi
  # where the manifest comes from: the override, then CLAUDE_PLUGIN_ROOT, then the lib's own location; never the cwd
  t "a relative CLAUDE_PLUGIN_ROOT is ignored" 0 -C "$REL" "$L" opt-a HEIMDALL_HOME="$H_ONE" CLAUDE_PLUGIN_ROOT=plug
  t "control: the same CLAUDE_PLUGIN_ROOT, absolute, is read" 1 -C "$REL" "$L" opt-a HEIMDALL_HOME="$H_ONE" CLAUDE_PLUGIN_ROOT="$REL/plug"
  mkplugin "$WORK/p1"
  t "no manifest beside the lib: enabled, whatever manifest the cwd holds (INV-G7)" 0 -C "$STR" "$WORK/p1/bin/lib/hmd_guardrail_enabled.sh" opt-a HEIMDALL_HOME="$H_ONE"
  mkplugin "$WORK/p2" "$WORK/m_rec.json"
  t "control: the manifest beside the lib is read" 1 -C "$STR" "$WORK/p2/bin/lib/hmd_guardrail_enabled.sh" opt-a HEIMDALL_HOME="$H_ONE"
  mkplugin "$WORK/p3" "$WORK/m_core.json"
  chk "a lib sourced by a relative path still reads the manifest beside it after a cd (the cwd's is not)" 0 "$(rc_rel "$WORK/p3" "$STR" opt-a HEIMDALL_HOME="$H_ONE")"
  mkplugin "$WORK/p4" "$WORK/m_rec.json"
  chk "control: ... and does read that manifest" 1 "$(rc_rel "$WORK/p4" "$STR" opt-a HEIMDALL_HOME="$H_ONE")"
  t "the override beats CLAUDE_PLUGIN_ROOT (core)" 0 "$L" opt-a HEIMDALL_HOME="$H_ONE" HMD_GUARDRAILS_MANIFEST="$WORK/m_core.json" CLAUDE_PLUGIN_ROOT="$PR_REC"
  t "the override beats CLAUDE_PLUGIN_ROOT (recommended)" 1 "$L" opt-a HEIMDALL_HOME="$H_ONE" HMD_GUARDRAILS_MANIFEST="$WORK/m_rec.json" CLAUDE_PLUGIN_ROOT="$PR_CORE"
  mkplugin "$WORK/p5" "$WORK/m_core.json"
  t "CLAUDE_PLUGIN_ROOT beats the lib's own location (recommended over core)" 1 "$WORK/p5/bin/lib/hmd_guardrail_enabled.sh" opt-a HEIMDALL_HOME="$H_ONE" CLAUDE_PLUGIN_ROOT="$PR_REC"
  mkplugin "$WORK/p6" "$WORK/m_rec.json"
  t "CLAUDE_PLUGIN_ROOT beats the lib's own location (core over recommended)" 0 "$WORK/p6/bin/lib/hmd_guardrail_enabled.sh" opt-a HEIMDALL_HOME="$H_ONE" CLAUDE_PLUGIN_ROOT="$PR_CORE"
  t "HEIMDALL_HOME unset: guardrails-off is read from \$HOME/.heimdall" 1 "$L" opt-a HOME="$HF" HMD_GUARDRAILS_MANIFEST="$FIX"
  t "HEIMDALL_HOME set: the one under \$HOME is not read" 0 "$L" opt-a HOME="$HF" HEIMDALL_HOME="$H_EMPTY" HMD_GUARDRAILS_MANIFEST="$FIX"
  # quiet: a hook's stdout is parsed and its stderr is shown, so no outcome may print
  local out=""
  out="$out$(noise "$L" opt-a HEIMDALL_HOME="$H_ONE" HMD_GUARDRAILS_MANIFEST="$WORK/garbage.json")"
  out="$out$(noise "$L" opt-a HEIMDALL_HOME="$H_ONE" HMD_GUARDRAILS_MANIFEST="$WORK/nope.json")"
  out="$out$(noise "$L" opt-a "${E_ONE[@]}" PATH="$NOJQ")"
  out="$out$(noise "$L" opt-a "${E_ONE[@]}" PATH="$BOOM_JQ:$PATH")"
  out="$out$(noise "$L" opt-a "${E_ONE[@]}" PATH="$BOOM_GREP:$PATH")"
  out="$out$(noise "$L" opt-a "${E_ONE[@]}")$(noise "$L" opt-b "${E_ONE[@]}")$(noise "$L" opt-a "${E_ALL[@]}")$(noise "$L" "" "${E_ALL[@]}")"
  if [ "$CAN_UNREAD" = 1 ]; then out="$out$(noise "$L" opt-a HEIMDALL_HOME="$WORK/h_unread" HMD_GUARDRAILS_MANIFEST="$FIX")"; fi
  chk "no outcome prints anything: not a garbled manifest, not a grep or jq that fails loudly" "" "$out"
  chk "sourcing it twice and calling it adds no name outside its own and changes no caller variable" clean "$(hygiene "$L")"
}

# ---- A. the real manifest ---------------------------------------------------------------------------------------------------------------------------
section "A. the real guardrails.manifest.json, through the lib's own location"
jq -r '.guardrails[] | "\(.id) \(.tier) \(.kind)"' "$MANIFEST" > "$WORK/rows"
awk '{ print $1 }' "$WORK/rows" > "$WORK/ids"
N_ROWS="$(wc -l < "$WORK/rows" | tr -d ' ')"
N_CORE="$(awk '$2 == "core"' "$WORK/rows" | wc -l | tr -d ' ')"
N_REC="$(awk '$2 == "recommended"' "$WORK/rows" | wc -l | tr -d ' ')"
if [ "$N_CORE" -ge 1 ] && [ "$N_REC" -ge 1 ] && [ $((N_CORE + N_REC)) -eq "$N_ROWS" ]; then
  ok "the manifest has $N_ROWS rows: $N_CORE core, $N_REC recommended, nothing else"
else
  bad "the manifest rows are not all core or recommended" "rows $N_ROWS, core $N_CORE, recommended $N_REC"
fi
# sweep HOME -- "<id> <status>" for every id of the manifest, from one shell that sources the real lib once, from a cwd that is not the repository
sweep() {
  (
    unset HEIMDALL_HOME CLAUDE_PLUGIN_ROOT HMD_GUARDRAILS_MANIFEST
    export HOME="$NOHOME" HEIMDALL_HOME="$1"
    cd "$WORK" && . "$LIB" || exit 99
    while IFS= read -r _i <&3; do
      hmd_guardrail_enabled "$_i"
      printf '%s %s\n' "$_i" "$?"
    done 3< "$WORK/ids"
  )
}
# alone HOME -- for each recommended guard, with only that id listed: "<id> <its status> <status of the row after it>"
alone() {
  (
    unset HEIMDALL_HOME CLAUDE_PLUGIN_ROOT HMD_GUARDRAILS_MANIFEST
    export HOME="$NOHOME" HEIMDALL_HOME="$1"
    cd "$WORK" && . "$LIB" || exit 99
    A=(); T=(); K=()
    while IFS=' ' read -r _a _t _k <&3; do A+=("$_a"); T+=("$_t"); K+=("$_k"); done 3< "$WORK/rows"
    n=${#A[@]}
    for ((i = 0; i < n; i++)); do
      if [ "${T[$i]}" = recommended ] && [ "${K[$i]}" = guard ]; then
        printf '%s\n' "${A[$i]}" > "$HEIMDALL_HOME/guardrails-off"
        hmd_guardrail_enabled "${A[$i]}"; a=$?
        hmd_guardrail_enabled "${A[$(((i + 1) % n))]}"; b=$?
        printf '%s %s %s\n' "${A[$i]}" "$a" "$b"
      fi
    done
  )
}
sweep "$H_EMPTY" > "$WORK/out_none"
enabled_all="$(awk '$2 != 0 { printf "%s ", $1 }' "$WORK/out_none")"
chk "INV-G2: with no guardrails-off all $N_ROWS rows answer" "$N_ROWS" "$(grep -c . "$WORK/out_none")" "rows answered"
chk "INV-G2: ... and none of them is disabled" "" "$enabled_all"
H_REAL="$WORK/h_real"; mkdir -p "$H_REAL"; cp "$WORK/ids" "$H_REAL/guardrails-off"
sweep "$H_REAL" > "$WORK/out_all"
chk "INV-G1: with every id listed, all $N_ROWS rows answered" "$N_ROWS" "$(grep -c . "$WORK/out_all")" "rows answered"
chk "INV-G1: with every id listed, no core row is disabled" "" "$(awk 'NR == FNR { t[$1] = $2; next } t[$1] == "core" && $2 != 0 { printf "%s ", $1 }' "$WORK/rows" "$WORK/out_all")"
chk "with every id listed, every recommended row is disabled" "" "$(awk 'NR == FNR { t[$1] = $2; next } t[$1] == "recommended" && $2 != 1 { printf "%s ", $1 }' "$WORK/rows" "$WORK/out_all")"
H_SOLO="$WORK/h_solo"; mkdir -p "$H_SOLO"
alone "$H_SOLO" > "$WORK/out_alone"
N_GUARDS="$(awk '$2 == "recommended" && $3 == "guard"' "$WORK/rows" | wc -l | tr -d ' ')"
chk "INV-G3: all $N_GUARDS recommended guards were tried alone" "$N_GUARDS" "$(grep -c . "$WORK/out_alone")" "guards answered"
chk "INV-G3: each one listed alone is disabled and the next row is not" "" "$(awk '$2 != 1 || $3 != 0 { printf "%s(%s,%s) ", $1, $2, $3 }' "$WORK/out_alone")"

section "B. fixture manifest and guardrails-off files (INV-G1, INV-G3, INV-G5, INV-G7)"
L="$LIB"
checks_core

# ---- C. cost and reach ------------------------------------------------------------------------------------------------------------------------------
section "C. cost, and where it can be sourced"
mkdir -p "$WORK/shim"
for tool in grep jq; do
  real="$(command -v "$tool")"
  cat > "$WORK/shim/$tool" <<EOF
#!/bin/sh
echo $tool >> "\$SHIM_LOG"
exec "$real" "\$@"
EOF
  chmod +x "$WORK/shim/$tool"
done
# used HOME ID -- the helper programs one call ran, in order
used() {
  : > "$WORK/shim.log"
  rc_of "$LIB" "$2" HEIMDALL_HOME="$1" HMD_GUARDRAILS_MANIFEST="$FIX" PATH="$WORK/shim:$PATH" SHIM_LOG="$WORK/shim.log" > /dev/null
  tr '\n' ' ' < "$WORK/shim.log"
}
chk "fast path: with no guardrails-off no program runs" "" "$(used "$H_EMPTY" opt-a)"
chk "an id that is not in guardrails-off costs one grep and no jq" "grep " "$(used "$H_ONE" opt-b)"
chk "a listed id costs one grep and one jq" "grep jq " "$(used "$H_ONE" opt-a)"
for name in sh dash zsh; do
  shell="$(command -v "$name" 2>/dev/null)" || { skip "$name is not installed"; continue; }
  for pair in "opt-a 1" "core-a 0" "ghost 0"; do
    g="${pair% *}"
    got="$(env -i PATH="$PATH" HOME="$NOHOME" HEIMDALL_HOME="$H_ALL" HMD_GUARDRAILS_MANIFEST="$FIX" "$shell" -c '. "$1" 2>/dev/null; hmd_guardrail_enabled "$2"; echo $?' _ "$LIB" "$g")"
    chk "under $name: $g -> exit ${pair#* }" "${pair#* }" "$got"
  done
done
got="$(env -i PATH="$PATH" "$BASH" -c 'set -eu; . "$1"; if hmd_guardrail_enabled zz-none; then echo enabled; else echo disabled; fi; hmd_guardrail_enabled zz-none; echo survived' _ "$LIB" 2>&1 | tr '\n' ' ')"
chk "under set -eu, with no HOME and no HEIMDALL_HOME: sourced, enabled, quiet, still running" "enabled survived " "$got"
# site ID [NAME=VALUE ...] -- what a hook body printed behind the call-site idiom of the lib's header
site() {
  local g="$1" p
  shift
  p='. "$HMDP/bin/lib/hmd_guardrail_enabled.sh" 2>/dev/null && { hmd_guardrail_enabled '"$g"'; [ "$?" -eq 1 ]; } && exit 0; echo RAN'
  env -i PATH="$PATH" HOME="$NOHOME" HMDP="$REPO" "$@" "$BASH" -c "$p"
}
chk "call site: the body of a disabled guard is skipped" "" "$(site opt-a "${E_ONE[@]}")"
chk "call site: the body of an enabled guard runs" "RAN" "$(site opt-b "${E_ONE[@]}")"
chk "call site: the body of a core guard listed in guardrails-off runs" "RAN" "$(site core-a "${E_ALL[@]}")"
chk "call site: a lib that cannot be sourced leaves the body running" "RAN" "$(site opt-a HMDP="$WORK/nowhere" "${E_ONE[@]}")"

# ---- F. falsifiability ------------------------------------------------------------------------------------------------------------------------------
section "F. falsifiability: each defect injected alone into a copy of the lib must turn a check of B red"
MUT="$WORK/mut"; mkdir -p "$MUT"
NM=0
KILLED=0
# judge LABEL FILE -- FILE is the lib with one defect: it must be valid shell, and some check of B must go red on it
judge() {
  if ! "$BASH" -n "$2" 2>/dev/null; then bad "mutant '$1' is not valid shell, so it proves nothing"; return 0; fi
  NM=$((NM + 1))
  if ( MODE=quiet; L="$2"; checks_core ) > /dev/null 2>&1; then
    bad "defect survived every check: $1"
  else
    KILLED=$((KILLED + 1))
    ok "defect caught: $1"
  fi
}
# literal LABEL OLD NEW -- the lib with the first occurrence of the text OLD, on a line of code (the header comment names the same things), replaced by NEW
literal() {
  local out="$MUT/m$((NM + 1)).sh"
  if awk -v old="$2" -v new="$3" '!done && $0 !~ /^ *#/ && (i = index($0, old)) { $0 = substr($0, 1, i - 1) new substr($0, i + length(old)); done = 1 } { print } END { exit (done ? 0 : 3) }' "$LIB" > "$out"; then
    judge "$1" "$out"
  else
    bad "mutant '$1': the text it replaces is not in the lib any more (edit the mutant with the lib)"
  fi
}
cp "$LIB" "$MUT/control.sh"
if ( MODE=quiet; L="$MUT/control.sh"; checks_core ) > /dev/null 2>&1; then
  ok "control: an unmodified copy of the lib passes every check, so a red below is the defect's"
else
  bad "control: an unmodified copy of the lib fails a check of B, so a red below proves nothing"
fi
# every fail-safe `return 0` of the code, made `return 1` (the guard would be switched off on that doubt); the one `return 1`, made `return 0` (it could never be switched off)
grep -n '^[^#]*return 0' "$LIB" | cut -d: -f1 > "$MUT/lines_safe"
while read -r n <&3; do
  awk -v n="$n" 'NR == n { sub(/return 0/, "return 1") } { print }' "$LIB" > "$MUT/f$n.sh"
  judge "line $n turns 'return 0' into 'return 1': $(sed -n "${n}p" "$LIB" | sed 's/^ *//')" "$MUT/f$n.sh"
done 3< "$MUT/lines_safe"
grep -n '^[^#]*return 1' "$LIB" | cut -d: -f1 > "$MUT/lines_off"
while read -r n <&3; do
  awk -v n="$n" 'NR == n { sub(/return 1/, "return 0") } { print }' "$LIB" > "$MUT/g$n.sh"
  judge "line $n turns 'return 1' into 'return 0': $(sed -n "${n}p" "$LIB" | sed 's/^ *//')" "$MUT/g$n.sh"
done 3< "$MUT/lines_off"
literal "the tier is no longer required to be recommended" ' and .[0].tier == "recommended"' ''
literal "an id repeated in the manifest is trusted" 'length == 1 and ' ''
literal "guardrails need not be an array" 'type == "array" and ' ''
literal "a substring of a line counts" 'grep -qxF' 'grep -qF'
literal "any verdict jq prints counts as yes" '[ "$verdict" = true ]' '[ -n "$verdict" ]'
literal "a relative HEIMDALL_HOME is read" 'case "$home" in /*) ;; *) return 0 ;; esac' ':'
literal "a relative manifest path is read" 'case "$meta" in /*) ;; *) return 0 ;; esac' ':'
literal "the lib's own path is not made absolute when sourced" '*) HMD_GUARDRAIL_ENABLED_LIB="${PWD:-.}/$HMD_GUARDRAIL_ENABLED_LIB" ;;' '*) ;;'
literal "the manifest override is ignored" '[ -n "${HMD_GUARDRAILS_MANIFEST:-}" ]' '[ -n "${HMD_GUARDRAILS_MANIFEST_OFF:-}" ]'
literal "CLAUDE_PLUGIN_ROOT is ignored" '[ -n "${CLAUDE_PLUGIN_ROOT:-}" ]' '[ -n "${CLAUDE_PLUGIN_ROOT_OFF:-}" ]'
literal "the manifest is read from the cwd" "printf '%s/../../guardrails.manifest.json' \"\${HMD_GUARDRAIL_ENABLED_LIB%/*}\"" "printf '%s/guardrails.manifest.json' \"\$PWD\""
literal "HOME is not consulted" '${HOME:-/tmp}' '/tmp'
literal "its variables are no longer local" 'local id="${1:-}" home file meta verdict' 'id="${1:-}"'
literal "the guardrails-off path is unquoted" '[ -f "$file" ]' '[ -f $file ]'
literal "the manifest path is unquoted" '[ -f "$meta" ]' '[ -f $meta ]'
literal "jq may print its errors" '"$meta" 2>/dev/null)"' '"$meta")"'
literal "grep may print its errors" 'grep -qxF -- "$id" "$file" 2>/dev/null' 'grep -qxF -- "$id" "$file"'
chk "falsifiability score $KILLED/$NM" "$NM" "$KILLED"

finish
