#!/usr/bin/env bash
#
# runhmd-parity.test.sh — what must STAY IDENTICAL / IN SYNC between the two npm wrappers.
#
#   bash test/runhmd-parity.test.sh              the gate            (exit 0 = no drift)
#   bash test/runhmd-parity.test.sh --self-test  corrupt-and-confirm (every leg must go RED)
#
# packages/runheimdall and packages/runhmd are published as two separate tarballs, so they
# cannot share a module at runtime — a shared third package would put one more thing between a
# user and the digest check. The pinning logic is therefore MIRRORED, and a mirror is only as
# good as the gate that keeps it honest. Four legs, each a different way the mirror can rot:
#
#   1. TEXT         the byte-source and verification code (die, sha256, loadScript, fetchHttps,
#                   the two pin-shape guards, the digest compare, the config lines) is the same
#                   text in both files, modulo the brand name and the one sanctioned divergence
#                   documented at SANCTIONED below. Catches a weakening made to ONE copy.
#   2. BEHAVIOUR    both wrappers are run against the same matrix of pin states (match, bent
#                   digest, near-miss, malformed, placeholder, missing file, truncated bytes) and
#                   must make the SAME call — run the script or refuse — with the SAME refusal
#                   message. Catches what text parity cannot: verification skipped or reordered
#                   outside the compared blocks.
#   3. PIN FIELDS   .version / .heimdall.tag / .heimdall.installScriptUrl / .heimdall.sha256 are
#                   identical in the two package.json files — both pin the same install.sh, so
#                   `npx runheimdall` and `npx runhmd` resolve to byte-identical bytes.
#   4. SUBCOMMANDS  packages/runhmd/subcommands.txt lists every subcommand bin/heimdall
#                   dispatches. A subcommand missing from it is silently routed to
#                   `hmd attack <word>` instead of reaching hmd.
#
# R6: --self-test plants a mutant for each leg in a THROWAWAY copy and asserts the gate goes RED
# for the right reason. A parity gate that cannot demonstrate going red proves nothing.
set -uo pipefail

SELF="${BASH_SOURCE[0]}"
SELF_DIR="$(cd "$(dirname "$SELF")" && pwd)"
REPO="${RUNHMD_PARITY_REPO:-$(cd "$SELF_DIR/.." && pwd)}"
FIXTURES="$SELF_DIR/lib/runhmd-fixtures.sh"

# ── --self-test ──────────────────────────────────────────────────────────────
if [ "${1:-}" = "--self-test" ]; then
  TMP="$(mktemp -d "${TMPDIR:-/tmp}/runhmd-parity-self.XXXXXX")"
  [ -n "$TMP" ] || { echo "FATAL: mktemp failed" >&2; exit 2; }
  trap 'rm -rf "$TMP"' EXIT
  M="$TMP/repo"

  # fresh_copy — a pristine throwaway repo carrying only what the gate reads
  fresh_copy() {
    rm -rf "$M"
    mkdir -p "$M/packages/runheimdall" "$M/packages/runhmd" "$M/bin"
    cp -R "$REPO/packages/runheimdall/bin" "$REPO/packages/runheimdall/package.json" "$M/packages/runheimdall/"
    cp -R "$REPO/packages/runhmd/bin" "$REPO/packages/runhmd/package.json" "$REPO/packages/runhmd/subcommands.txt" "$M/packages/runhmd/"
    cp "$REPO/bin/heimdall" "$M/bin/heimdall"
  }
  # mutate <file> <sed-expr> — apply one mutation and prove it actually changed the file
  mutate() {
    local f="$1" expr="$2"
    cp "$f" "$f.orig"
    sed "$expr" "$f.orig" > "$f"
    if cmp -s "$f" "$f.orig"; then
      echo "  ✗ SELF-TEST BROKEN: the mutation '$expr' did not change $f — the proof would be vacuous" >&2
      exit 1
    fi
    rm -f "$f.orig"
  }
  # assert_red <label> <expected-substring> / assert_green <label>
  assert_red() {
    local label="$1" want="$2" out
    if out="$(RUNHMD_PARITY_REPO="$M" bash "$SELF" 2>&1)"; then
      echo "  ✗ SELF-TEST FAILED: the gate stayed GREEN with $label planted" >&2
      exit 1
    fi
    case "$out" in
      *"$want"*) echo "  ✓ RED on $label" ;;
      *) echo "  ✗ SELF-TEST FAILED: RED for the wrong reason with $label planted (wanted: $want)" >&2
         printf '%s\n' "$out" >&2
         exit 1 ;;
    esac
  }
  assert_green() {
    local label="$1" out
    if out="$(RUNHMD_PARITY_REPO="$M" bash "$SELF" 2>&1)"; then
      echo "  ✓ GREEN on $label"
    else
      echo "  ✗ SELF-TEST FAILED: the gate went RED on $label" >&2
      printf '%s\n' "$out" >&2
      exit 1
    fi
  }

  HMD_JS="$M/packages/runhmd/bin/runhmd.js"
  OLD_JS="$M/packages/runheimdall/bin/runheimdall.js"

  echo "runhmd-parity --self-test: asserting every leg goes RED on a planted drift"

  fresh_copy
  assert_green "a pristine copy (so every red below is attributable to its own mutant)"

  # Leg 1 (TEXT) — weaken the digest compare in ONE wrapper, then in the other. Either copy
  # quietly accepting a digest that merely STARTS the same would let a near-miss tarball run.
  fresh_copy
  mutate "$HMD_JS" 's/if (actual !== EXPECTED_SHA) {/if (actual.slice(0, 8) !== EXPECTED_SHA.slice(0, 8)) {/'
  assert_red "runhmd comparing only a digest PREFIX" "PIN LOGIC DRIFT"

  fresh_copy
  mutate "$OLD_JS" 's/if (actual !== EXPECTED_SHA) {/if (actual.slice(0, 8) !== EXPECTED_SHA.slice(0, 8)) {/'
  assert_red "runheimdall comparing only a digest PREFIX" "PIN LOGIC DRIFT"

  fresh_copy
  mutate "$HMD_JS" "s/EXPECTED_SHA === 'replace_at_publish'/EXPECTED_SHA === 'never-matches'/"
  assert_red "runhmd no longer refusing the placeholder digest" "PIN LOGIC DRIFT"

  fresh_copy
  mutate "$HMD_JS" "s/ || '').toLowerCase();/ || '');/"
  assert_red "runhmd no longer lower-casing the pinned digest" "PIN LOGIC DRIFT"

  # Leg 2 (BEHAVIOUR) — verification skipped OUTSIDE every compared block. Text parity is
  # blind to this by construction; the differential run is what sees the install script run on
  # bytes that never matched the pin.
  fresh_copy
  mutate "$HMD_JS" 's/await verifiedScript()/await loadScript()/'
  assert_red "runhmd running fetched bytes WITHOUT verifying them" "PIN BEHAVIOUR DRIFT"

  # Leg 3 (PIN FIELDS)
  fresh_copy
  mutate "$M/packages/runhmd/package.json" 's/"sha256": "\([0-9a-f]\)/"sha256": "0\1/'
  assert_red "runhmd package.json pinning a different digest than runheimdall" "PIN FIELD DRIFT"

  fresh_copy
  mutate "$M/packages/runhmd/package.json" 's/"tag": "v/"tag": "v9/'
  assert_red "runhmd package.json pinning a different tag than runheimdall" "PIN FIELD DRIFT"

  # Leg 4 (SUBCOMMANDS)
  fresh_copy
  mutate "$M/packages/runhmd/subcommands.txt" '/^team$/d'
  assert_red "a real hmd subcommand (team) missing from subcommands.txt" "SUBCOMMAND DRIFT"

  fresh_copy
  printf 'bogus-subcommand\n' >> "$M/packages/runhmd/subcommands.txt"
  assert_red "a phantom subcommand that bin/heimdall does not dispatch" "SUBCOMMAND DRIFT"

  fresh_copy
  mutate "$M/packages/runhmd/subcommands.txt" '/^attack$/d'
  assert_red "the default command (attack) missing from subcommands.txt" "SUBCOMMAND DRIFT"

  fresh_copy
  : > "$M/bin/heimdall"
  assert_red "a dispatch extractor that finds nothing (vacuous)" "SUBCOMMAND DRIFT"

  echo "runhmd-parity --self-test: PASS"
  exit 0
fi

# ── the gate ─────────────────────────────────────────────────────────────────
PASS=0; FAIL=0
ok()  { printf '  \033[32mPASS\033[0m %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAIL=$((FAIL+1)); }

[ -r "$FIXTURES" ] || { echo "FATAL: shared fixtures missing: $FIXTURES" >&2; exit 2; }
# shellcheck source=lib/runhmd-fixtures.sh disable=SC1091  # plain shellcheck (no -x) never opens sourced files
. "$FIXTURES"
for t in node jq shasum awk sed; do
  command -v "$t" >/dev/null 2>&1 || { echo "FATAL: $t is required" >&2; exit 2; }
done

OLD_PKG="$REPO/packages/runheimdall"
HMD_PKG="$REPO/packages/runhmd"
OLD_JS="$OLD_PKG/bin/runheimdall.js"
HMD_JS="$HMD_PKG/bin/runhmd.js"
DISPATCH="$REPO/bin/heimdall"

echo "runhmd-parity harness  repo=$REPO"
echo "--------------------------------------------------------------------"

for f in "$OLD_JS" "$HMD_JS" "$OLD_PKG/package.json" "$HMD_PKG/package.json" "$HMD_PKG/subcommands.txt" "$DISPATCH"; do
  [ -f "$f" ] || { bad "missing: ${f#"$REPO"/}"; }
done
if [ "$FAIL" -gt 0 ]; then
  echo ""; echo "runhmd-parity.test.sh: $PASS passed, $FAIL failed."; exit 1
fi

# ── Leg 1: TEXT ──────────────────────────────────────────────────────────────
echo "1. text — the pinning logic is the same text in both wrappers"

# normalize — brand-neutral and indentation-neutral.
#
# SANCTIONED divergence (exactly one, folded back here): runheimdall.js declares
# `const URL = …` (the install URL string), which SHADOWS the global URL class inside that
# module — so its redirect branch, `new URL(res.headers.location, url)`, throws "URL is not a
# constructor" on the first 3xx instead of following it. runhmd.js keeps the same `const URL`
# line (so every other line stays byte-identical) but reaches the real class through
# require('url'), and the redirect-follow case in test/runhmd-wrapper.test.sh pins that it works.
# If runheimdall.js is ever fixed, delete the folding rule below and the two texts converge.
normalize() {
  sed -e 's/runheimdall/@BRAND@/g' -e 's/runhmd/@BRAND@/g' \
      -e 's/RUNHEIMDALL/@ENV@/g'   -e 's/RUNHMD/@ENV@/g' \
      -e "s/new (require('url').URL)(/new URL(/g" \
      -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' \
  | grep -v '^$'
}

# extract_block <file> <start-ERE> — from the first line matching <start-ERE> through the line
# that brings the brace depth back to zero.
extract_block() {
  # The regex travels through the environment, not `awk -v`: -v would process backslash escapes
  # in it and turn `\(` into a bare `(`.
  EB_RE="$2" awk '
    !started && $0 ~ ENVIRON["EB_RE"] { started = 1 }
    started {
      print
      line = $0
      o = gsub(/\{/, "{", line)
      c = gsub(/\}/, "}", line)
      depth += o - c
      if (depth <= 0 && (o + c) > 0) exit
    }
  ' "$1"
}

compare_block() {  # <name> <start-ERE>
  local name="$1" re="$2" a b
  a="$(extract_block "$OLD_JS" "$re" | normalize)"
  b="$(extract_block "$HMD_JS" "$re" | normalize)"
  if [ -z "$a" ] || [ -z "$b" ]; then
    bad "PIN LOGIC DRIFT: '$name' could not be found in ${OLD_JS#"$REPO"/} and/or ${HMD_JS#"$REPO"/} (empty extraction — the gate would be vacuous)"
  elif [ "$a" = "$b" ]; then
    ok "$name is identical in both wrappers"
  else
    bad "PIN LOGIC DRIFT: '$name' differs between runheimdall.js and runhmd.js"
    diff <(printf '%s\n' "$a") <(printf '%s\n' "$b") | sed 's/^/      /' >&2
  fi
}

compare_line() {  # <name> <fixed substring identifying the line in runheimdall.js>
  local name="$1" needle="$2" a
  a="$(normalize < "$OLD_JS" | grep -F -- "$needle" | head -1)"
  if [ -z "$a" ]; then
    bad "PIN LOGIC DRIFT: '$name' not found in runheimdall.js (looked for: $needle)"
  elif normalize < "$HMD_JS" | grep -Fxq -- "$a"; then
    ok "$name is identical in both wrappers"
  else
    bad "PIN LOGIC DRIFT: '$name' differs — runheimdall.js has: $a"
  fi
}

compare_block "die()"                       '^function die\('
compare_block "sha256()"                    '^function sha256\('
compare_block "loadScript()"                '^function loadScript\('
compare_block "fetchHttps()"                '^function fetchHttps\('
compare_block "the placeholder-digest guard" 'if \(!EXPECTED_SHA \|\| EXPECTED_SHA ==='
compare_block "the digest-shape guard"      'if \(!/\^\[0-9a-f\]\{64\}\$/\.test\(EXPECTED_SHA\)\)'
compare_block "the digest compare + refusal" 'if \(actual !== EXPECTED_SHA\)'
compare_line  "the digest computation"      'const actual = sha256(buf);'
compare_line  "EXPECTED_SHA (env override, baked pin, lower-cased)" 'const EXPECTED_SHA ='
compare_line  "LOCAL_OVERRIDE"              'const LOCAL_OVERRIDE ='
compare_line  "the install URL"             'const URL ='
compare_line  "TAG"                         'const TAG ='

# ── Leg 2: BEHAVIOUR ─────────────────────────────────────────────────────────
echo "2. behaviour — the same pin state gets the same verdict from both wrappers"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/runhmd-parity.XXXXXX")"
[ -n "$WORK" ] || { echo "FATAL: mktemp failed" >&2; exit 2; }
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/tmp"

NODE_BIN="$(command -v node)"
BASE_PATH="$(dirname "$NODE_BIN"):/usr/bin:/bin"
HMD_TEMPLATE="$WORK/hmd-template";    rf_make_hmd_template "$HMD_TEMPLATE"
INSTALLER="$WORK/install-fixture.sh"; rf_make_installer "$INSTALLER"
SHA="$(rf_sha256 "$INSTALLER")"
BENT="$(rf_bend_digest "$SHA")"
NEAR="${SHA%?}$(printf '%s' "${SHA#"${SHA%?}"}" | tr '0123456789abcdef' '1234567890badcfe')"
UPPER="$(printf '%s' "$SHA" | tr 'abcdef' 'ABCDEF')"
TRUNC="$WORK/install-truncated.sh";   head -c 40 "$INSTALLER" > "$TRUNC"

# Package copies the wrappers can run from, with the pin rewritten by jq where a scenario needs.
make_pkgs() {  # <dest> <jq filter applied to BOTH package.json files>
  local dest="$1" filter="$2"
  mkdir -p "$dest/old/bin" "$dest/new/bin"
  cp "$OLD_JS" "$dest/old/bin/"
  cp "$HMD_JS" "$dest/new/bin/"
  cp "$HMD_PKG/subcommands.txt" "$dest/new/"
  jq "$filter" "$OLD_PKG/package.json" > "$dest/old/package.json"
  jq "$filter" "$HMD_PKG/package.json" > "$dest/new/package.json"
}

N=0
# run_wrapper <which: old|new> <pkgdir> <script> <sha> — sets W_RC / W_RAN / W_ERR / W_OUT
run_wrapper() {
  local which="$1" pkg="$2" script="$3" sha="$4"
  N=$((N+1))
  local h="$WORK/h$N" mark="$WORK/mark$N"
  W_ERR="$WORK/err$N"; W_OUT="$WORK/out$N"
  mkdir -p "$h/.local/bin"
  if [ "$which" = old ]; then
    env -i HOME="$h" PATH="$BASE_PATH" TMPDIR="$WORK/tmp" STUB_INSTALL_MARK="$mark" STUB_HMD_TEMPLATE="$HMD_TEMPLATE" \
      RUNHEIMDALL_INSTALL_SCRIPT="$script" RUNHEIMDALL_SHA256="$sha" \
      "$NODE_BIN" "$pkg/bin/runheimdall.js" >"$W_OUT" 2>"$W_ERR"
  else
    env -i HOME="$h" PATH="$BASE_PATH" TMPDIR="$WORK/tmp" STUB_INSTALL_MARK="$mark" STUB_HMD_TEMPLATE="$HMD_TEMPLATE" \
      RUNHMD_INSTALL_SCRIPT="$script" RUNHMD_SHA256="$sha" \
      "$NODE_BIN" "$pkg/bin/runhmd.js" attack . >"$W_OUT" 2>"$W_ERR"
  fi
  W_RC=$?
  if [ -e "$mark" ]; then W_RAN=1; else W_RAN=0; fi
}

# err_signature <stderr file> — everything the wrapper said about the pin, brand-neutral. runhmd
# narrates its own extra steps (why it is installing) on lines containing ': note: '; those are
# the only lines allowed to exist in one wrapper and not the other, so they are dropped here and
# EVERYTHING else — the verification line, every refusal message — must match line for line.
err_signature() {
  grep -v ': note: ' "$1" | sed -e 's/^runheimdall: //' -e 's/^runhmd: //' | normalize
}

scenario() {  # <label> <expect: ran|refused> <script> <sha> <jq filter for both package.json files>
  local label="$1" expect="$2" script="$3" sha="$4" filter="$5"
  local pk="$WORK/pk$((N+1))"
  make_pkgs "$pk" "$filter"
  run_wrapper old "$pk/old" "$script" "$sha"; local o_rc="$W_RC" o_ran="$W_RAN" o_err="$W_ERR"
  run_wrapper new "$pk/new" "$script" "$sha"; local n_rc="$W_RC" n_ran="$W_RAN" n_err="$W_ERR"

  local why=""
  if [ "$expect" = ran ]; then
    [ "$o_rc" -eq 0 ] && [ "$o_ran" -eq 1 ] || why="$why runheimdall did not run the script (rc=$o_rc ran=$o_ran);"
    [ "$n_rc" -eq 0 ] && [ "$n_ran" -eq 1 ] || why="$why runhmd did not run the script (rc=$n_rc ran=$n_ran);"
  else
    [ "$o_rc" -ne 0 ] && [ "$o_ran" -eq 0 ] || why="$why runheimdall did not refuse (rc=$o_rc ran=$o_ran);"
    [ "$n_rc" -ne 0 ] && [ "$n_ran" -eq 0 ] || why="$why runhmd did not refuse (rc=$n_rc ran=$n_ran);"
  fi
  if [ -z "$why" ] && [ "$(err_signature "$o_err")" != "$(err_signature "$n_err")" ]; then
    why="$why the stderr differs — runheimdall: [$(err_signature "$o_err" | tr '\n' '|')] runhmd: [$(err_signature "$n_err" | tr '\n' '|')];"
  fi
  if [ -z "$why" ]; then ok "$label — both wrappers: $expect"; else bad "PIN BEHAVIOUR DRIFT: $label —$why"; fi
}

scenario "digest matches"                          ran     "$INSTALLER" "$SHA"   '.'
scenario "digest matches, upper-case spelling"     ran     "$INSTALLER" "$UPPER" '.'
scenario "digest bent in every nibble"             refused "$INSTALLER" "$BENT"  '.'
scenario "digest wrong only in its last nibble"    refused "$INSTALLER" "$NEAR"  '.'
scenario "digest is not 64 hex"                    refused "$INSTALLER" "abc123" '.'
scenario "script truncated, full-length pin"       refused "$TRUNC"     "$SHA"   '.'
scenario "script file does not exist"              refused "$WORK/missing.sh" "$SHA" '.'
scenario "package carries the placeholder digest"  refused "$INSTALLER" ""       '.heimdall.sha256 = "REPLACE_AT_PUBLISH"'

# ── Leg 3: PIN FIELDS ────────────────────────────────────────────────────────
echo "3. pin fields — both packages pin the same install.sh"

for field in .version .heimdall.tag .heimdall.installScriptUrl .heimdall.sha256; do
  a="$(jq -r "$field // empty" "$OLD_PKG/package.json" 2>/dev/null)"
  b="$(jq -r "$field // empty" "$HMD_PKG/package.json" 2>/dev/null)"
  if [ -z "$a" ] || [ -z "$b" ]; then
    bad "PIN FIELD DRIFT: $field is empty in runheimdall ('$a') and/or runhmd ('$b')"
  elif [ "$a" = "$b" ]; then
    ok "$field is identical (${a:0:48})"
  else
    bad "PIN FIELD DRIFT: $field: runheimdall='$a' runhmd='$b' — run release/sync-release.sh <TAG>"
  fi
done

# ── Leg 4: SUBCOMMANDS ───────────────────────────────────────────────────────
echo "4. subcommands — every subcommand bin/heimdall dispatches is known to runhmd"

# The words bin/heimdall dispatches at the top level: the labels of the main `case "${1:-}"`
# (after the run-count bump, up to its closing esac) and the column-0 `if [[ "${1:-}" == word ]]`
# handlers that follow it. Flags (anything starting with a dash) are not subcommands.
dispatch_words() {
  {
    awk '
      /hmd_bump_run_count \|\| true/ { armed = 1 }
      armed && /^case "\$\{1:-\}" in/ { inside = 1; next }
      inside && /^esac/ { exit }
      inside && /^  [^ #)][^ )]*\)[[:space:]]*(#.*)?$/ {
        lbl = $0
        sub(/^  /, "", lbl)
        sub(/\)[[:space:]]*(#.*)?$/, "", lbl)
        n = split(lbl, parts, "|")
        for (i = 1; i <= n; i++) if (parts[i] ~ /^[a-z0-9][a-z0-9-]*$/) print parts[i]
      }
    ' "$DISPATCH"
    grep -E '^if \[\[ "\$\{1:-\}" == ' "$DISPATCH" | grep -oE '== "[a-z][a-z0-9-]*"' | sed -E 's/^== "(.*)"$/\1/'
  } | sort -u
}

# Words on hmd's roadmap that this tree's bin/heimdall does not dispatch yet. runhmd must
# already know them: `attack` IS the default command. None right now -- RP1 `hmd attack` and
# RP2 `hmd prove` are both dispatched by bin/heimdall -- and the list stays for the next roadmap
# word. Once a word lands in bin/heimdall it stops needing this allowance — and the allowance
# for a word that IS dispatched is itself reported, so the list cannot quietly outlive its reason.
PLANNED=""

DISPATCHED="$(dispatch_words)"
LISTED="$(grep -v '^[[:space:]]*#' "$HMD_PKG/subcommands.txt" | grep -v '^[[:space:]]*$' | sed 's/[[:space:]]*$//' | sort)"
N_DISPATCHED="$(printf '%s\n' "$DISPATCHED" | grep -c . || true)"

if [ "$N_DISPATCHED" -ge 50 ]; then
  ok "the dispatch extractor found $N_DISPATCHED subcommands in bin/heimdall (not vacuous)"
else
  bad "SUBCOMMAND DRIFT: the dispatch extractor found only $N_DISPATCHED subcommands in bin/heimdall — it has rotted, or the file is wrong"
fi

DUPES="$(printf '%s\n' "$LISTED" | uniq -d)"
if [ -z "$DUPES" ]; then ok "subcommands.txt has no duplicate entries"; else bad "SUBCOMMAND DRIFT: duplicate entries in subcommands.txt: $(printf '%s' "$DUPES" | tr '\n' ' ')"; fi

BADSHAPE="$(printf '%s\n' "$LISTED" | grep -vE '^[a-z0-9][a-z0-9-]*$' || true)"
if [ -z "$BADSHAPE" ]; then ok "every entry is a bare lowercase word"; else bad "SUBCOMMAND DRIFT: malformed entries in subcommands.txt: $(printf '%s' "$BADSHAPE" | tr '\n' ' ')"; fi

if printf '%s\n' "$LISTED" | grep -qx 'attack'; then
  ok "the default command (attack) is a known subcommand"
else
  bad "SUBCOMMAND DRIFT: 'attack' is not in subcommands.txt — 'runhmd attack .' would be routed to 'hmd attack attack .'"
fi

MISSING=""
for w in $DISPATCHED; do
  printf '%s\n' "$LISTED" | grep -qx "$w" || MISSING="$MISSING $w"
done
if [ -z "$MISSING" ]; then
  ok "every subcommand bin/heimdall dispatches is listed"
else
  bad "SUBCOMMAND DRIFT: bin/heimdall dispatches [${MISSING# }] but subcommands.txt does not list them — 'runhmd <word>' would be routed to 'hmd attack <word>'"
fi

PHANTOM=""
for w in $LISTED; do
  printf '%s\n' "$DISPATCHED" | grep -qx "$w" && continue
  case " $PLANNED " in *" $w "*) continue ;; esac
  PHANTOM="$PHANTOM $w"
done
if [ -z "$PHANTOM" ]; then
  ok "every listed subcommand is dispatched by bin/heimdall or is a planned one (planned: ${PLANNED:-none})"
else
  bad "SUBCOMMAND DRIFT: subcommands.txt lists [${PHANTOM# }] which bin/heimdall does not dispatch and which are not planned — 'runhmd <word>' would reach an hmd that treats it as a task prompt"
fi

STALE_PLAN=""
for w in $PLANNED; do
  printf '%s\n' "$DISPATCHED" | grep -qx "$w" && STALE_PLAN="$STALE_PLAN $w"
done
if [ -z "$STALE_PLAN" ]; then
  ok "no planned subcommand is already dispatched (the PLANNED allowance is still earning its keep)"
else
  echo "  NOTE  [${STALE_PLAN# }] now exist in bin/heimdall — drop them from PLANNED in test/runhmd-parity.test.sh"
fi

echo ""
echo "runhmd-parity.test.sh: $PASS passed, $FAIL failed."
[ "$FAIL" -eq 0 ] || exit 1
exit 0
