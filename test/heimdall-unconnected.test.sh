#!/usr/bin/env bash
# test/heimdall-unconnected.test.sh -- hermetic tests for bin/heimdall-unconnected.
# Builds a fixture git repo under $TMPDIR with known branch and bin/ tool
# shapes -- never depends on this repo's own (constantly changing) branch set.
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SELF_DIR/.." && pwd)"
BIN="$ROOT/bin/heimdall-unconnected"

PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); printf 'ok - %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf 'not ok - %s\n' "$1"; [ $# -gt 1 ] && printf '  # %s\n' "$2"; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/hmd-unconnected-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

TODAY="2026-06-01"

# ============================================================
# Fixture 1: mixed repo -- branches (real/wip/clean) + tools
#            (untested-dead/tested-dead/exempt-dead/expired-dead/live).
# ============================================================
FIX="$WORK/fixture"
mkdir -p "$FIX/bin/lib" "$FIX/hooks" "$FIX/test"
git -C "$FIX" init -q -b main
git -C "$FIX" config user.email test@example.com
git -C "$FIX" config user.name "Test"
git -C "$FIX" config commit.gpgsign false

touch "$FIX/install.sh"
printf '{}\n' > "$FIX/.mcp.json"
cat > "$FIX/bin/heimdall" <<'EOF'
#!/usr/bin/env bash
echo dispatcher
EOF
chmod +x "$FIX/bin/heimdall"

cat > "$FIX/hooks/hooks.json" <<'EOF'
{"hooks":{"SessionStart":[{"hooks":[{"command":"bin/heimdall-live-tool"}]}]}}
EOF

cat > "$FIX/bin/heimdall-live-tool" <<'EOF'
#!/usr/bin/env bash
echo live
EOF
chmod +x "$FIX/bin/heimdall-live-tool"

# dead + UNTESTED -- plain dead code, NOT a Face B finding.
cat > "$FIX/bin/heimdall-dead-untested" <<'EOF'
#!/usr/bin/env bash
echo dead-untested
EOF
chmod +x "$FIX/bin/heimdall-dead-untested"

# dead + TESTED + no exemption row -- THE Face B finding.
cat > "$FIX/bin/heimdall-dead-tested" <<'EOF'
#!/usr/bin/env bash
echo dead-tested
EOF
chmod +x "$FIX/bin/heimdall-dead-tested"
cat > "$FIX/test/heimdall-dead-tested.test.sh" <<'EOF'
#!/usr/bin/env bash
echo "covers heimdall-dead-tested"
EOF

# dead + TESTED + VALID (unexpired) exemption -- NOT a finding.
cat > "$FIX/bin/heimdall-dead-exempt" <<'EOF'
#!/usr/bin/env bash
echo dead-exempt
EOF
chmod +x "$FIX/bin/heimdall-dead-exempt"
cat > "$FIX/test/heimdall-dead-exempt.test.sh" <<'EOF'
#!/usr/bin/env bash
echo "covers heimdall-dead-exempt"
EOF

# dead + TESTED + EXPIRED exemption -- a finding.
cat > "$FIX/bin/heimdall-dead-expired" <<'EOF'
#!/usr/bin/env bash
echo dead-expired
EOF
chmod +x "$FIX/bin/heimdall-dead-expired"
cat > "$FIX/test/heimdall-dead-expired.test.sh" <<'EOF'
#!/usr/bin/env bash
echo "covers heimdall-dead-expired"
EOF

printf 'heimdall-dead-exempt\t2026-12-31\tintentional, long grace period\n' > "$FIX/bin/lib/reachability-exemptions.tsv"
printf 'heimdall-dead-expired\t2026-01-01\tgrace period long since over\n' >> "$FIX/bin/lib/reachability-exemptions.tsv"

git -C "$FIX" add -A
git -C "$FIX" commit -q -m "feat(fixture): seed repo" --no-verify
MAIN_SHA="$(git -C "$FIX" rev-parse HEAD)"

# Branch 1: REAL unlanded -- a real feat: commit whose content is not on main.
git -C "$FIX" checkout -q -b branch-real "$MAIN_SHA"
echo "real feature" > "$FIX/real-feature.txt"
git -C "$FIX" add real-feature.txt
git -C "$FIX" commit -q -m "feat(real): add a real unlanded feature" --no-verify

# Branch 2: WIP-only -- only a wip: commit, no conventional prefix.
git -C "$FIX" checkout -q -b branch-wip "$MAIN_SHA"
echo "wip snapshot" > "$FIX/wip-snapshot.txt"
git -C "$FIX" add wip-snapshot.txt
git -C "$FIX" commit -q -m "wip: preserve interrupted agent work" --no-verify

# Branch 3: clean -- content-identical to main once .planning is excluded.
# Simulates "merged, then gained a journal-only commit": ahead by commit
# count, clean by content. THE most important false-positive case.
git -C "$FIX" checkout -q -b branch-clean "$MAIN_SHA"
mkdir -p "$FIX/.planning"
echo "journal entry" > "$FIX/.planning/journal.md"
git -C "$FIX" add .planning/journal.md
git -C "$FIX" commit -q -m "journal: after-the-fact note, no real content change" --no-verify

git -C "$FIX" checkout -q main

run_bin() { HMD_REACH_TODAY="$TODAY" "$BIN" "$@"; }

# ---------- report mode ----------
OUT="$(cd "$FIX" && run_bin --repo "$FIX" 2>&1)"
RC=$?

[ "$RC" -eq 1 ] && ok "report mode exits 1 when real findings exist" || bad "report mode exit code" "got $RC, want 1"

printf '%s' "$OUT" | grep -q "branch-real" && ok "unmerged feat: branch is reported" || bad "unmerged feat: branch is reported" "not found"
printf '%s' "$OUT" | grep -A5 "WIP-ONLY" | grep -q "branch-wip" && ok "wip:-only branch reported in its own bucket" || bad "wip:-only branch bucket" "not found"
if printf '%s' "$OUT" | grep -q "branch-clean"; then bad "content-identical branch must NOT be reported" "branch-clean appeared"; else ok "content-identical branch (post-merge journal commit) is NOT reported"; fi
if printf '%s' "$OUT" | grep -A2 "UNLANDED" | grep -q "branch-wip"; then bad "wip-only branch leaked into UNLANDED bucket" ""; else ok "wip-only branch does not appear in UNLANDED bucket"; fi

printf '%s' "$OUT" | grep -q "heimdall-dead-tested" && ok "dead + tested + unexempt tool is reported (Face B)" || bad "dead+tested+unexempt tool reported" "not found"
if printf '%s' "$OUT" | grep -q "heimdall-dead-untested"; then bad "dead + UNTESTED tool must not be a Face B finding" "appeared"; else ok "dead + untested tool is NOT a Face B finding"; fi
if printf '%s' "$OUT" | grep -q "heimdall-dead-exempt"; then bad "validly-exempted dead tool must not be a finding" "appeared in output"; else ok "validly exempted dead+tested tool is NOT a finding"; fi
printf '%s' "$OUT" | grep -q "heimdall-dead-expired" && ok "EXPIRED exemption on a dead+tested tool IS a finding" || bad "expired-exemption tool reported" "not found"
if printf '%s' "$OUT" | grep -q "heimdall-live-tool"; then bad "live (reachable) tool must never be reported" "appeared"; else ok "live tool is never reported"; fi

printf '%s' "$OUT" | grep -qE 'real:[[:space:]]+1 branch' && ok "FA_REAL_N == 1" || bad "FA_REAL_N == 1" "$(printf '%s' "$OUT" | grep 'real:')"
printf '%s' "$OUT" | grep -qE 'wip-only:[[:space:]]+1 branch' && ok "FA_WIP_N == 1" || bad "FA_WIP_N == 1" "$(printf '%s' "$OUT" | grep 'wip-only:')"
printf '%s' "$OUT" | grep -qE 'clean:[[:space:]]+1 branch' && ok "FA_CLEAN_N == 1" || bad "FA_CLEAN_N == 1" "$(printf '%s' "$OUT" | grep 'clean:')"
printf '%s' "$OUT" | grep -qE 'unconnected:[[:space:]]+2 of those' && ok "FB_UNCONNECTED == 2" || bad "FB_UNCONNECTED == 2" "$(printf '%s' "$OUT" | grep 'unconnected:')"
printf '%s' "$OUT" | grep -qE 'exempt:[[:space:]]+1 dead' && ok "FB_EXEMPT_VALID == 1" || bad "FB_EXEMPT_VALID == 1" "$(printf '%s' "$OUT" | grep 'exempt:')"

printf '%s' "$OUT" | grep "heimdall-dead-tested" | grep -q "exempt: none" && ok "no-exemption reason renders as 'none'" || bad "no-exemption reason 'none'" "$(printf '%s' "$OUT" | grep 'heimdall-dead-tested')"
printf '%s' "$OUT" | grep "heimdall-dead-expired" | grep -q "exempt: EXPIRED" && ok "expired-exemption reason renders as 'EXPIRED -- ...'" || bad "expired reason text" "$(printf '%s' "$OUT" | grep 'heimdall-dead-expired')"

# ---------- --json mode ----------
JSON="$(cd "$FIX" && run_bin --repo "$FIX" --json 2>&1)"
JRC=$?
[ "$JRC" -eq 1 ] && ok "--json exits 1 on findings" || bad "--json exit code" "got $JRC"
printf '%s' "$JSON" | grep -q '"branches_real":1' && ok "--json branches_real == 1" || bad "--json branches_real" "$JSON"
printf '%s' "$JSON" | grep -q '"branches_wip_only":1' && ok "--json branches_wip_only == 1" || bad "--json branches_wip_only" "$JSON"
printf '%s' "$JSON" | grep -q '"branches_clean":1' && ok "--json branches_clean == 1" || bad "--json branches_clean" "$JSON"
printf '%s' "$JSON" | grep -q '"bin_unconnected":2' && ok "--json bin_unconnected == 2" || bad "--json bin_unconnected" "$JSON"
printf '%s' "$JSON" | grep -q '"bin_exempt_valid":1' && ok "--json bin_exempt_valid == 1" || bad "--json bin_exempt_valid" "$JSON"
printf '%s' "$JSON" | grep -q '"real_names":\["branch-real"\]' && ok "--json real_names contains branch-real" || bad "--json real_names" "$JSON"
printf '%s' "$JSON" | grep -q "heimdall-dead-tested" && ok "--json unconnected_names contains heimdall-dead-tested" || bad "--json unconnected_names" "$JSON"

# ---------- --advise mode ----------
ADV_HOME="$WORK/hmd-home"
mkdir -p "$ADV_HOME"
ADV_OUT="$(cd "$FIX" && HEIMDALL_HOME="$ADV_HOME" HMD_REACH_TODAY="$TODAY" "$BIN" --repo "$FIX" --advise 2>&1)"
ADV_RC=$?
[ "$ADV_RC" -eq 0 ] && ok "--advise always exits 0 (never gates)" || bad "--advise exit code" "got $ADV_RC"
printf '%s' "$ADV_OUT" | grep -q '^\[heimdall\]' && ok "--advise prints a [heimdall]-prefixed line when findings exist" || bad "--advise line prefix" "$ADV_OUT"
[ -f "$ADV_HOME/unconnected-advice" ] && ok "--advise writes its TTL cache file" || bad "--advise cache file written" "missing $ADV_HOME/unconnected-advice"

# ============================================================
# Fixture 2: clean repo -- nothing to find, either face.
# ============================================================
CLEANFIX="$WORK/cleanfix"
mkdir -p "$CLEANFIX/bin" "$CLEANFIX/hooks"
git -C "$CLEANFIX" init -q -b main
git -C "$CLEANFIX" config user.email test@example.com
git -C "$CLEANFIX" config user.name "Test"
git -C "$CLEANFIX" config commit.gpgsign false
# reach_build refuses (rc=2) when reach_subjects finds zero bin/ executables
# (reachability.sh:388-389) -- a real repo always has some, so the fixture
# needs at least one LIVE subject to exercise the genuinely-clean path
# rather than the (unrelated) "engine refused" path.
cat > "$CLEANFIX/hooks/hooks.json" <<'EOF'
{"hooks":{"SessionStart":[{"hooks":[{"command":"bin/heimdall-clean-live"}]}]}}
EOF
cat > "$CLEANFIX/bin/heimdall-clean-live" <<'EOF'
#!/usr/bin/env bash
echo clean-live
EOF
chmod +x "$CLEANFIX/bin/heimdall-clean-live"
git -C "$CLEANFIX" add -A
git -C "$CLEANFIX" commit -q -m "feat(fixture): clean repo, nothing to find" --no-verify

CLEAN_RC=0
CLEAN_OUT="$(cd "$CLEANFIX" && run_bin --repo "$CLEANFIX" 2>&1)" || CLEAN_RC=$?
[ "$CLEAN_RC" -eq 0 ] && ok "report mode exits 0 on a fully clean repo" || bad "clean repo report exit code" "got $CLEAN_RC: $CLEAN_OUT"

CLEAN_ADV_HOME="$WORK/hmd-home-clean"
mkdir -p "$CLEAN_ADV_HOME"
CLEAN_ADV_OUT="$(cd "$CLEANFIX" && HEIMDALL_HOME="$CLEAN_ADV_HOME" HMD_REACH_TODAY="$TODAY" "$BIN" --repo "$CLEANFIX" --advise 2>&1)"
CLEAN_ADV_RC=$?
[ "$CLEAN_ADV_RC" -eq 0 ] && ok "--advise on a clean repo exits 0" || bad "--advise clean exit" "got $CLEAN_ADV_RC"
[ -z "$CLEAN_ADV_OUT" ] && ok "--advise on a clean repo prints nothing" || bad "--advise clean output empty" "got: $CLEAN_ADV_OUT"

# ---------- --help and error handling ----------
HELP_OUT="$("$BIN" --help 2>&1)"
HELP_RC=$?
if [ "$HELP_RC" -eq 0 ] && printf '%s' "$HELP_OUT" | grep -q "Usage:"; then ok "--help exits 0 and prints usage"; else bad "--help" "rc=$HELP_RC out=$HELP_OUT"; fi

BADREPO_RC=0
BADREPO_OUT="$("$BIN" --repo "$WORK/does-not-exist" 2>&1)" || BADREPO_RC=$?
[ "$BADREPO_RC" -eq 2 ] && ok "--repo pointing nowhere exits 2 (refused to run)" || bad "--repo nonexistent exit code" "got $BADREPO_RC: $BADREPO_OUT"

printf 'RESULT: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
