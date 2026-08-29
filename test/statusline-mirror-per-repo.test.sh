#!/usr/bin/env bash
# test/statusline-mirror-per-repo.test.sh — the PER-REPO LEDGER MIRROR (mirror-race fix).
#
# THE BUG (docs/analysis/2026-08-29-statusline-roster-inflation.md): every repo's presence
# keeper on ONE machine wrote the SAME machine-global path
# (${HEIMDALL_HOME:-~/.heimdall}/ledger/status.json) — a single, last-writer-wins slot.
# _ledger_in_scope() in sentinels/hmd-statusline.py bounds the blast radius (a foreign
# stamp fails closed to "no team shown") but does not remove the race: between one repo's
# write and the next read, a DIFFERENT repo's roster could transiently render on this
# repo's statusline. Same-owner, cross-repo mirror CONTENT leak — not a cross-team/secret
# leak (ruled out separately).
#
# THE FIX: key the mirror PER REPO so the race is structurally impossible, not merely
# detected. sentinels/hmd_ledger.py::repo_key(repo) (SHA256[:16] of the realpath'd git
# root, via the no-subprocess _git_root() walk) and status_path_for(repo)
# (${HEIMDALL_HOME:-~/.heimdall}/ledger/repos/<repo_key>.json) are the ONE place the key is
# derived; bin/heimdall-status-json (the writer) imports that exact function (same
# sys.path.insert(0, sentinels-dir) it already uses for hmd_sigil) so the writer and every
# reader can never independently drift onto different paths for the same tree.
# sentinels/hmd-statusline.py threads its stdin-derived cwd through to
# hmd_ledger.read_status(session_id, repo=cwd) so the tree actually being rendered — not the
# statusline process's own os.getcwd() — decides which mirror is read. _ledger_in_scope()
# is UNCHANGED and stays as defense-in-depth (it operates on whichever dict answered,
# agnostic to which tier produced it).
#
# MIGRATION (deliberate: read-legacy-as-fallback, never delete). The legacy global
# ledger/status.json is kept and tried SECOND, so a machine mid-rollout (some repos'
# keepers have beaten under the new code, some have not) never regresses to a blank/broken
# wall — an unwritten repo still gets whatever the legacy tier last held. Nothing here ever
# deletes the legacy file. See section 3 below for the asserted contract.
#
# THIS SUITE LOCKS:
#   1. HEADLINE — two DIFFERENT repos sharing one HEIMDALL_HOME (the actual bug scenario)
#      write to two DIFFERENT per-repo files; neither's content leaks into the other's, the
#      legacy global slot is untouched, and the reader (repo=) resolves each repo to its
#      OWN roster.
#   2. STABILITY — the same repo hashes to the same path across two separate writer beats
#      AND regardless of cwd depth (root vs. a nested subdirectory) — the key is a
#      property of the repo, not of who is asking or from where.
#   3. MIGRATION — a pre-existing legacy status.json is used as a fallback (never deleted,
#      never modified) until this repo's OWN writer beats once under the new code, after
#      which the per-repo mirror takes precedence.
#   4. FAIL-CLOSED — a corrupt/truncated per-repo mirror degrades to the exact SAFE_DEFAULT
#      (no traceback, no fabricated partial parse, no silent fall-through to a legacy file
#      that happens to be readable), and the REAL render entry point
#      (hooks/statusline.sh -> bin/heimdall-statusline -> sentinels/hmd-statusline.py)
#      still exits 0 with non-empty, traceback-free output against that same corruption.
#   5. SYNTAX sanity on all three files this fix touches.
#
# Hermetic: every fixture (HEIMDALL_HOME, repo roots, statusline tmp-cache dir) lives under
# $TMPDIR only. This suite never reads or writes the real ~/.heimdall and never touches any
# real checkout (e.g. /Users/rj/omniroute).
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
WRITER="$ROOT/bin/heimdall-status-json"
MOD="$ROOT/sentinels/hmd_ledger.py"
STATUSLINE_PY="$ROOT/sentinels/hmd-statusline.py"
STATUSLINE_SH="$ROOT/hooks/statusline.sh"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  \033[32mPASS\033[0m %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  \033[31mFAIL\033[0m %s\n' "$1"; }

command -v python3 >/dev/null 2>&1 || { echo "SKIP: python3 unavailable"; exit 0; }
command -v jq   >/dev/null 2>&1 || { echo "FATAL: jq required" >&2; exit 2; }
command -v git  >/dev/null 2>&1 || { echo "FATAL: git required" >&2; exit 2; }
[ -x "$WRITER" ]         || { echo "FATAL: $WRITER not executable" >&2; exit 2; }
[ -f "$MOD" ]            || { echo "FATAL: $MOD missing" >&2; exit 2; }
[ -f "$STATUSLINE_PY" ]  || { echo "FATAL: $STATUSLINE_PY missing" >&2; exit 2; }
[ -f "$STATUSLINE_SH" ]  || { echo "FATAL: $STATUSLINE_SH missing" >&2; exit 2; }
PY="$(command -v python3)"

PERL_BIN="$(command -v perl || true)"
# run_with_alarm SECS CMD... — bounded execution (macOS has no `timeout`); CMD must be a
# real executable (perl's exec replaces the process image, it cannot invoke a shell
# function or builtin).
run_with_alarm() {
  local secs="$1"; shift
  if [ -n "$PERL_BIN" ]; then
    "$PERL_BIN" -e "alarm $secs; exec @ARGV" "$@"
  else
    "$@"
  fi
}

# Every fixture lives under here — never the real ~/.heimdall, never a real checkout.
BASE="$(mktemp -d "${TMPDIR:-/tmp}/statusline-mirror-per-repo.XXXXXX")"
[ -n "$BASE" ] || { echo "FATAL: BASE path empty (mktemp failed)" >&2; exit 2; }
trap 'rm -rf "$BASE"' EXIT

# mkrepo DIR — a throwaway git repo with one commit. The writer shells out to
# `git rev-parse --show-toplevel`, and hmd_ledger's _git_root() walks up looking for a
# real `.git` marker — both need an actual repo, not just a directory.
mkrepo() {
  local d="$1"
  mkdir -p "$d"
  git -C "$d" init -q
  git -C "$d" config user.email "test@runheimdall.dev"
  git -C "$d" config user.name "test"
  printf 'seed\n' > "$d/seed.txt"
  git -C "$d" add -A
  git -C "$d" commit -qm seed
}

# repo_key_path REPO WS — the per-repo mirror path hmd_ledger.status_path_for() computes
# for REPO under fake home WS. This calls the SAME function both the writer and the real
# statusline reader call, so a file landing here proves writer/reader agreement — it is
# not an independent re-derivation of the hash.
repo_key_path() {
  local repo="$1" ws="$2"
  HEIMDALL_HOME="$ws" run_with_alarm 10 "$PY" -c "
import sys
sys.path.insert(0, '$ROOT/sentinels')
import hmd_ledger as L
print(L.status_path_for(sys.argv[1]))
" "$repo"
}

# write_mirror REPO WS KEEPERDIR ROSTER_JSON NOW — one writer beat, cwd=REPO, deliberately
# WITHOUT HMD_STATUS_OUT/--out — an explicit override would bypass the very default-path
# logic this suite exists to prove.
write_mirror() {
  local repo="$1" ws="$2" kdir="$3" roster="$4" now="$5"
  mkdir -p "$kdir"
  ( cd "$repo" && \
    HEIMDALL_HOME="$ws" HEIMDALL_KEEPER_DIR="$kdir" \
    HMD_STATUS_VERDICT_FILE="$ws/no-such-verdict.json" \
    HMD_STATUS_ROSTER_JSON="$roster" HMD_STATUS_NOW="$now" \
    run_with_alarm 10 "$WRITER" >/dev/null 2>&1 )
}

# pyread WS REPO SESSION NOW — hmd_ledger.read_status(SESSION, repo=REPO) with
# HEIMDALL_HOME=WS, in an isolated env (mirrors test/heimdall-ledger-reader.test.sh's
# pyrun isolation — including the real $HOME being cleared, closing that reference
# helper's one gap: _self_ids() would otherwise fall through to the REAL ~/.heimdall for
# identity.json) so nothing leaks from this test's OWN real session/identity env.
# SESSION must be unique per distinct expectation within a shared WS — read_status caches
# per session_id for 5s, and a reused id across two different repos in the same WS would
# read back the FIRST call's cached answer instead of exercising a fresh read.
# NOW must land within OFFLINE_WINDOW (7 days) of the write's HMD_STATUS_NOW/ts, else
# hmd_ledger.filter_team() honestly drops the synthetic entry as beyond-window-stale —
# that is a REAL, correct part of the contract (see heimdall-ledger-reader.test.sh's own
# section 5), not something to relax; passing a NOW close to the write-time NOW here
# simply keeps the fixture inside the window, same as any real recent heartbeat would be.
pyread() {
  local ws="$1" repo="$2" sess="$3" now="$4"
  run_with_alarm 10 env -i PATH="$PATH" LANG="${LANG:-en_US.UTF-8}" HOME="$ws" \
    HEIMDALL_HOME="$ws" HMD_STATUSLINE_TMP="$ws/tmp-cache" HMD_NOW="$now" \
    "$PY" -c "
import sys, json
sys.path.insert(0, '$ROOT/sentinels')
import hmd_ledger as L
r = L.read_status(sys.argv[1], repo=sys.argv[2])
print(json.dumps(r))
" "$sess" "$repo"
}

# ══════════════════════════════════════════════════════════════════════════════
echo "== 1) HEADLINE: two different repos, one shared HEIMDALL_HOME -> two different files, no cross-talk =="
WS1="$BASE/ws1"; mkdir -p "$WS1"
REPO_A="$BASE/repo-a"; mkrepo "$REPO_A"
REPO_B="$BASE/repo-b"; mkrepo "$REPO_B"

ROSTER_A="$(jq -cn '[{haid:"haid:alice.aaaa11", handle:"alice-mirror-test", verdict:"pass", file:"a.ts", age_seconds:0, state:"active"}]')"
ROSTER_B="$(jq -cn '[{haid:"haid:bob.bbbb22", handle:"bob-mirror-test", verdict:"pass", file:"b.ts", age_seconds:0, state:"active"}]')"

write_mirror "$REPO_A" "$WS1" "$BASE/keeper-a" "$ROSTER_A" 1000
write_mirror "$REPO_B" "$WS1" "$BASE/keeper-b" "$ROSTER_B" 1001

PATH_A="$(repo_key_path "$REPO_A" "$WS1")"
PATH_B="$(repo_key_path "$REPO_B" "$WS1")"

[ -n "$PATH_A" ] && [ -n "$PATH_B" ] && [ "$PATH_A" != "$PATH_B" ] \
  && ok "repo A and repo B hash to two DIFFERENT mirror paths" \
  || bad "expected two distinct paths, got A='$PATH_A' B='$PATH_B'"

[ -f "$PATH_A" ] && ok "repo A's write landed at repo A's own computed path" || bad "repo A's mirror file missing at $PATH_A"
[ -f "$PATH_B" ] && ok "repo B's write landed at repo B's own computed path" || bad "repo B's mirror file missing at $PATH_B"

GOT_A_USER="$(jq -r '.team[0].user // empty' "$PATH_A" 2>/dev/null)"
GOT_B_USER="$(jq -r '.team[0].user // empty' "$PATH_B" 2>/dev/null)"
[ "$GOT_A_USER" = "alice-mirror-test" ] && ok "repo A's file carries repo A's roster (alice)" || bad "repo A user wrong: '$GOT_A_USER'"
[ "$GOT_B_USER" = "bob-mirror-test" ] && ok "repo B's file carries repo B's roster (bob)" || bad "repo B user wrong: '$GOT_B_USER'"

if [ -f "$PATH_A" ] && grep -q "bob-mirror-test" "$PATH_A" 2>/dev/null; then
  bad "repo A's mirror leaked repo B's roster"
else
  ok "repo A's mirror contains no trace of repo B's roster"
fi
if [ -f "$PATH_B" ] && grep -q "alice-mirror-test" "$PATH_B" 2>/dev/null; then
  bad "repo B's mirror leaked repo A's roster"
else
  ok "repo B's mirror contains no trace of repo A's roster"
fi

if [ -e "$WS1/ledger/status.json" ]; then
  bad "a write with no explicit override still touched the legacy GLOBAL mirror path"
else
  ok "neither write touched the legacy global mirror path (ledger/status.json never created)"
fi

# reader closure: the SAME key the writer used is what the reader resolves for each tree.
OUT_READ_A="$(pyread "$WS1" "$REPO_A" "sess-headline-a" 1000)"
OUT_READ_B="$(pyread "$WS1" "$REPO_B" "sess-headline-b" 1001)"
READ_A_USER="$(printf '%s' "$OUT_READ_A" | jq -r '.team[0].user // empty' 2>/dev/null)"
READ_B_USER="$(printf '%s' "$OUT_READ_B" | jq -r '.team[0].user // empty' 2>/dev/null)"
[ "$READ_A_USER" = "alice-mirror-test" ] && ok "read_status(repo=A) resolves A's own roster (alice)" || bad "read_status(repo=A) got '$READ_A_USER': $OUT_READ_A"
[ "$READ_B_USER" = "bob-mirror-test" ] && ok "read_status(repo=B) resolves B's own roster (bob)" || bad "read_status(repo=B) got '$READ_B_USER': $OUT_READ_B"

# ══════════════════════════════════════════════════════════════════════════════
echo "== 2) STABILITY: same repo -> same key across writer beats AND across cwd depth =="
WS2="$BASE/ws2"; mkdir -p "$WS2"
REPO_S="$BASE/repo-s"; mkrepo "$REPO_S"
mkdir -p "$REPO_S/nested/deeper"

PATH_ROOT="$(repo_key_path "$REPO_S" "$WS2")"
PATH_NESTED="$(repo_key_path "$REPO_S/nested/deeper" "$WS2")"
[ -n "$PATH_ROOT" ] && [ "$PATH_ROOT" = "$PATH_NESTED" ] \
  && ok "status_path_for(root) == status_path_for(nested subdir) of the same repo" \
  || bad "key drifted by cwd depth: root='$PATH_ROOT' nested='$PATH_NESTED'"

ROSTER_S1="$(jq -cn '[{haid:"haid:carol.c1c1c1", handle:"carol-v1", verdict:"pass", file:"a.ts", age_seconds:0, state:"active"}]')"
ROSTER_S2="$(jq -cn '[{haid:"haid:carol.c1c1c1", handle:"carol-v2", verdict:"pass", file:"a.ts", age_seconds:0, state:"active"}]')"

write_mirror "$REPO_S" "$WS2" "$BASE/keeper-s" "$ROSTER_S1" 2000
FIRST_PATH="$(repo_key_path "$REPO_S" "$WS2")"
write_mirror "$REPO_S" "$WS2" "$BASE/keeper-s" "$ROSTER_S2" 2001
SECOND_PATH="$(repo_key_path "$REPO_S" "$WS2")"
[ "$FIRST_PATH" = "$SECOND_PATH" ] && ok "same repo resolves the same path across two separate writer beats" \
  || bad "repo key changed across beats: '$FIRST_PATH' vs '$SECOND_PATH'"

NFILES="$(find "$WS2/ledger/repos" -type f -name '*.json' 2>/dev/null | wc -l | tr -d ' ')"
[ "$NFILES" = "1" ] && ok "two beats from one repo land in exactly ONE mirror file (in place, no duplicate)" \
  || bad "expected exactly 1 file under ledger/repos/, found $NFILES"

GOT_S_USER="$(jq -r '.team[0].user // empty' "$FIRST_PATH" 2>/dev/null)"
[ "$GOT_S_USER" = "carol-v2" ] && ok "the second beat overwrote the first IN PLACE at the stable path" \
  || bad "expected carol-v2 (2nd beat) at the stable path, got '$GOT_S_USER'"

# ══════════════════════════════════════════════════════════════════════════════
echo "== 3) MIGRATION: legacy global status.json is a fallback, never deleted, per-repo wins once written =="
WS3="$BASE/ws3"; mkdir -p "$WS3/ledger"
REPO_L="$BASE/repo-legacy"; mkrepo "$REPO_L"

# Seed ONLY the legacy global mirror — simulating an existing pre-fix install where some
# keeper already beat under the OLD code before THIS repo's writer has ever run under the
# new per-repo code.
LEGACY_PATH="$WS3/ledger/status.json"
cat > "$LEGACY_PATH" <<JSON
{"daemon": true, "gates": [], "verdict": {"state":"pass","label":"GATE"},
 "team": [{"user":"legacy-user","sigil":"#112233","branch":"main","state":"pass","ts":5000}],
 "repo": "$REPO_L"}
JSON
LEGACY_BEFORE="$(cat "$LEGACY_PATH")"

OUT_L1="$(pyread "$WS3" "$REPO_L" "sess-legacy-1" 5000)"
GOT_L1_USER="$(printf '%s' "$OUT_L1" | jq -r '.team[0].user // empty' 2>/dev/null)"
[ "$GOT_L1_USER" = "legacy-user" ] \
  && ok "no per-repo mirror yet -> reader falls back to the legacy global mirror (old roster, not a blank wall)" \
  || bad "legacy fallback did not surface the legacy team: $OUT_L1"

LEGACY_AFTER="$(cat "$LEGACY_PATH")"
[ "$LEGACY_BEFORE" = "$LEGACY_AFTER" ] && ok "reading through the legacy fallback did not modify the legacy file" \
  || bad "the legacy file changed after being read through the fallback path"

# Now this repo's writer beats for the first time under the new per-repo code.
ROSTER_L="$(jq -cn '[{haid:"haid:dave.d1d1d1", handle:"dave", verdict:"pass", file:"a.ts", age_seconds:0, state:"active"}]')"
write_mirror "$REPO_L" "$WS3" "$BASE/keeper-l" "$ROSTER_L" 6000
PERREPO_PATH="$(repo_key_path "$REPO_L" "$WS3")"

[ -f "$PERREPO_PATH" ] && ok "the first beat under the new code creates the per-repo mirror file" \
  || bad "per-repo mirror file was not created at $PERREPO_PATH"
[ -f "$LEGACY_PATH" ] && ok "the legacy global file still exists once the per-repo mirror exists (no destructive migration)" \
  || bad "the legacy file was deleted -- migration must never delete it"

OUT_L2="$(pyread "$WS3" "$REPO_L" "sess-legacy-2" 6000)"
GOT_L2_USER="$(printf '%s' "$OUT_L2" | jq -r '.team[0].user // empty' 2>/dev/null)"
[ "$GOT_L2_USER" = "dave" ] && ok "once the per-repo mirror exists it takes precedence over the legacy global fallback" \
  || bad "per-repo mirror did not win over the legacy fallback: $OUT_L2"

# ══════════════════════════════════════════════════════════════════════════════
echo "== 4) FAIL-CLOSED: corrupt per-repo mirror -> safe default, no fall-through, no traceback, still renders =="
WS4="$BASE/ws4"; mkdir -p "$WS4/ledger"
REPO_C="$BASE/repo-corrupt"; mkrepo "$REPO_C"

# Seed a legacy global file with REAL, readable content — proves a corrupt LIVE per-repo
# source does NOT silently fall through to it (the "malformed -> safe default, not the
# next tier" contract hmd_ledger._read_source()'s docstring makes explicit).
cat > "$WS4/ledger/status.json" <<JSON
{"daemon": true, "gates": [], "verdict": null,
 "team": [{"user":"should-not-leak","sigil":"#000000","branch":"main","state":"pass","ts":5000}],
 "repo": "$REPO_C"}
JSON

CORRUPT_PATH="$(repo_key_path "$REPO_C" "$WS4")"
mkdir -p "$(dirname "$CORRUPT_PATH")"
printf '{"daemon": true, "team": [ { "user": "truncated-mid-wr' > "$CORRUPT_PATH"

OUT_CORRUPT="$(pyread "$WS4" "$REPO_C" "sess-corrupt-1" 9000 2>&1)"
if printf '%s' "$OUT_CORRUPT" | grep -qi "traceback"; then
  bad "corrupt mirror raised a traceback: $OUT_CORRUPT"
else
  ok "corrupt mirror produced no traceback (reader degrades, never crashes)"
fi

WANT_NORM='{"daemon":"down","gates":[],"repo":"","team":[],"team_overflow":0,"verdict":null}'
GOT_NORM="$(printf '%s' "$OUT_CORRUPT" | jq -Sc . 2>/dev/null)"
[ -n "$GOT_NORM" ] && [ "$GOT_NORM" = "$WANT_NORM" ] \
  && ok "corrupt mirror -> the exact SAFE_DEFAULT (never a fabricated partial parse)" \
  || bad "corrupt mirror did not degrade to SAFE_DEFAULT: got '$GOT_NORM' want '$WANT_NORM'"

if printf '%s' "$OUT_CORRUPT" | grep -q "should-not-leak"; then
  bad "a corrupt LIVE mirror silently fell through to the legacy global tier"
else
  ok "a corrupt LIVE mirror does NOT fall through to the legacy tier (reported honestly, never masked by stale data)"
fi

# The ACTUAL render entry point must never crash on this same corruption.
RENDER_OUT="$(printf '{"workspace":{"current_dir":"%s"},"model":{"display_name":"x"}}' "$REPO_C" \
  | HEIMDALL_HOME="$WS4" HMD_STATUSLINE_TMP="$WS4/tmp-cache" COLUMNS=120 \
    run_with_alarm 15 bash "$STATUSLINE_SH" 2>&1)"
RENDER_RC=$?
[ "$RENDER_RC" -eq 0 ] && ok "hooks/statusline.sh exits 0 against a corrupt per-repo mirror" \
  || bad "hooks/statusline.sh exited $RENDER_RC against a corrupt mirror"
if printf '%s' "$RENDER_OUT" | grep -qi "traceback"; then
  bad "the statusline render surfaced a traceback on a corrupt mirror: $RENDER_OUT"
else
  ok "the statusline render surfaced no traceback on a corrupt mirror"
fi
[ -n "$RENDER_OUT" ] && ok "the statusline still renders non-empty output on a corrupt mirror" \
  || bad "the statusline rendered EMPTY output on a corrupt mirror"

# ══════════════════════════════════════════════════════════════════════════════
echo "== 5) syntax sanity (the three files this fix touches) =="
bash -n "$WRITER" 2>/dev/null && ok "bash -n bin/heimdall-status-json clean" || bad "bash -n bin/heimdall-status-json FAILED"
"$PY" -m py_compile "$MOD" 2>/dev/null && ok "py_compile sentinels/hmd_ledger.py clean" || bad "py_compile sentinels/hmd_ledger.py FAILED"
"$PY" -m py_compile "$STATUSLINE_PY" 2>/dev/null && ok "py_compile sentinels/hmd-statusline.py clean" || bad "py_compile sentinels/hmd-statusline.py FAILED"
bash -n "$STATUSLINE_SH" 2>/dev/null && ok "bash -n hooks/statusline.sh clean" || bad "bash -n hooks/statusline.sh FAILED"

echo ""
echo "  ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ] || exit 1
