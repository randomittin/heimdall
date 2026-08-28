#!/usr/bin/env bash
# heimdall-presence-sandbox-guard.test.sh — FALSIFIER, table-driven: a sandboxed install's
# $HOME never gets the self-heal doctor daemon; a real dev $HOME always still does.
#
# ORIGIN. bin/heimdall-presence's _keeper_start() SANDBOX GUARD (grep that heading) skips the
# nohup+disown self-heal-doctor autoenroll whenever $HOME matches a system temp root. Without
# it, every hermetic suite that installs under `env -i HOME="$(mktemp -d)"` (see
# test/install-stranger.test.sh's run_install()) leaks a detached doctor that outlives its own
# $HOME (deleted at test-end) by up to HMD_DOCTOR_MAX_SECONDS (1800s default) — measured 32 live
# orphans at load 6.23 on a 10-core box in production, which then tripped OTHER suites' own
# wall-clock watchdogs and made passing code report as hung.
#
# WHY A SEPARATE FILE from heimdall-presence-keeper.test.sh's Section E: Section E proves the
# guard through the shapes that motivated it (a fresh mktemp -d HOME under plain env, the same
# under env -i — install-stranger's exact trigger — and a real fixture HOME as negative control).
# This file is the durable, TABLE-DRIVEN superset — born from a throwaway repro script
# (repro-sandbox-home.sh, written to root-cause a real gap in an EARLIER version of this guard:
# a $TMPDIR-only check missed macOS's /var/folders/*/T/* root once env -i stripped $TMPDIR). A
# one-off repro proves a bug once; this file keeps proving the fix stays fixed — across every
# temp-root shape anyone has since had reason to worry about, PLUS the documented escape hatch
# (HMD_DOCTOR_ALLOW_TMP_HOME) and a /var/tmp root — by invoking the REAL script (never a copy of
# its matching logic, which could silently drift from what actually ships).
#
# HERMETIC: local StateBackend only, no network — net-default-guard.sh pins the zero-config CP
# default to a dead local port, and every case bounds the doctor's own lifetime
# (HMD_DOCTOR_MAX_CYCLES=1 HMD_DOCTOR_MAX_SECONDS=1) so even a guard failure self-heals in ~1s
# instead of leaking for the full 1800s.
#
# Exit 0 = every case classified correctly (sandboxed HOMEs get no doctor, real HOMEs still do).

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SELF_DIR/.." && pwd)"
BIN="$REPO/bin/heimdall-presence"
. "$REPO/test/lib/net-default-guard.sh"

PY="$(command -v python3 || command -v python || true)"
[ -n "$PY" ] || { echo "FATAL: python not found" >&2; exit 2; }
[ -x "$BIN" ] || { echo "FATAL: $BIN missing/not executable" >&2; exit 2; }

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf "  \033[32mPASS\033[0m %s\n" "$1"; }
bad() { FAIL=$((FAIL+1)); printf "  \033[31mFAIL\033[0m %s\n" "$1"; }

TMP="$(mktemp -d -t "presence-sandbox-guard.XXXXXX")"
export HEIMDALL_KEEPER_DIR="$TMP/keeper"; mkdir -p "$HEIMDALL_KEEPER_DIR"
PROJECT="acme/sandboxguard"
CASE_HOMES=""
# Case 5's real-fixture HOME lives here — outside the repo (never trips the tree-integrity
# guard's root-litter check; see test/tree-integrity-guard.test.sh) and outside every temp-root
# glob the sandbox guard itself checks (bin/heimdall-presence's case "${HOME:-}" in /tmp/*|
# /private/tmp/*|/var/tmp/*|/private/var/tmp/*|/var/folders/*/T/*), so it still classifies as
# real dev use. A prior version anchored it under $REPO directly, relying solely on this
# script's own EXIT trap to remove it — but an untrappable SIGKILL (run-all.sh's timeout_run
# TERM's the whole process group, waits 2s, then KILLs it; SIGKILL cannot be caught regardless
# of what the trap says) left it behind INSIDE the scanned tree, tripping "TREE INTEGRITY
# VIOLATION" on the next full run. $HOME below is this script's own real ambient HOME — nothing
# above reassigns it (unlike heimdall-presence-keeper.test.sh, which throws its own $HOME away
# for the rest of that file).
FIXTURE_CACHE="${XDG_CACHE_HOME:-$HOME/.cache}/hmd-test"
mkdir -p "$FIXTURE_CACHE" 2>/dev/null || true
# Best-effort stale-fixture sweep (never fails the suite, hence the trailing || true): a run
# that got SIGKILLed before its own EXIT trap could fire leaves its fixture dir sitting here —
# sweep any leftovers now so they cannot accumulate across suite invocations.
rm -rf "$FIXTURE_CACHE"/.hmd-test-fixture-sandboxguard.* 2>/dev/null || true
cleanup() {
  for pf in "$HEIMDALL_KEEPER_DIR"/*.pid; do
    [ -f "$pf" ] || continue
    p="$(cat "$pf" 2>/dev/null || true)"
    case "$p" in ''|*[!0-9]*) : ;; *) kill "$p" 2>/dev/null || true ;; esac
  done
  for h in $CASE_HOMES; do rm -rf "$h"; done
  rm -rf "$TMP"
}
trap cleanup EXIT INT TERM

wait_pid_file() {  # $1 = glob -> prints first match's content once one appears (~2s bound)
  local i=0 f
  while [ "$i" -lt 20 ]; do
    for f in $1; do [ -f "$f" ] && { cat "$f" 2>/dev/null; return 0; }; done
    i=$((i + 1)); sleep 0.1 2>/dev/null || sleep 1
  done
  return 1
}

# run_case: $1=label  $2=HOME  $3=expect("skip"|"spawn")  $4=envmode("plain"|"strip")
#           $5=extra (optional NAME=value, e.g. an ALLOW override — passed through either mode)
run_case() {
  local label="$1" home="$2" expect="$3" envmode="$4" extra="${5:-}"
  local docdir="$home/.heimdall/doctor" sess out doc_pid
  sess="s$$_${RANDOM}"
  mkdir -p "$home/.heimdall"
  out="$TMP/${sess}.out"
  if [ "$envmode" = "strip" ]; then
    # Mirrors install-stranger.test.sh's run_install() EXACTLY: env -i re-lists only what it
    # names, so anything not listed here (including TMPDIR) is gone, same as a real install.
    env -i HOME="$home" TERM="dumb" PATH="$PATH" $extra \
      HEIMDALL_DEFAULT_CP_URL="$HEIMDALL_DEFAULT_CP_URL" HEIMDALL_KEEPER_DIR="$HEIMDALL_KEEPER_DIR" \
      HEIMDALL_DOCTOR_DIR="$docdir" HMD_DOCTOR_MAX_CYCLES=1 HMD_DOCTOR_MAX_SECONDS=1 HMD_DOCTOR_BACKOFF=0 \
      "$BIN" keeper-start --session "$sess" --project "$PROJECT" --interval 30 >"$out" 2>&1
  else
    env -u HMD_KEEPER_BEAT_BIN -u HMD_DOCTOR_DISABLE $extra HOME="$home" \
      HEIMDALL_KEEPER_DIR="$HEIMDALL_KEEPER_DIR" HEIMDALL_DOCTOR_DIR="$docdir" \
      HMD_DOCTOR_MAX_CYCLES=1 HMD_DOCTOR_MAX_SECONDS=1 HMD_DOCTOR_BACKOFF=0 \
      "$BIN" keeper-start --session "$sess" --project "$PROJECT" --interval 30 >"$out" 2>&1
  fi
  doc_pid="$(wait_pid_file "$docdir"/*.pid || true)"
  "$BIN" keeper-stop --session "$sess" --project "$PROJECT" >/dev/null 2>&1 || true
  case "$doc_pid" in ''|*[!0-9]*) : ;; *) kill "$doc_pid" 2>/dev/null || true ;; esac
  # give a spawned doctor (HMD_DOCTOR_MAX_CYCLES=1 HMD_DOCTOR_MAX_SECONDS=1 above) its own ~1s
  # bound to exit naturally too — without this, a `pgrep` immediately after this function
  # returns can catch it mid-teardown and misreport a live PID that is already on its way out
  # (matches the same wait E2/E3 in heimdall-presence-keeper.test.sh use for the same reason).
  "$PY" -c "import time;time.sleep(1.2)"
  if [ "$expect" = "skip" ]; then
    if [ -z "$doc_pid" ]; then ok "$label: no doctor spawned (guard held, envmode=$envmode)"
    else bad "$label: doctor spawned anyway (pid=$doc_pid, envmode=$envmode) — LEAK"; fi
  else
    if [ -n "$doc_pid" ]; then ok "$label: doctor spawned as expected (pid=$doc_pid, envmode=$envmode)"
    else bad "$label: doctor did NOT spawn (envmode=$envmode, out=$(cat "$out" 2>/dev/null | tr '\n' ' ')) — guard OVER-BROAD"; fi
  fi
}

echo "============================================================"
echo "PRESENCE-SANDBOX-GUARD falsifier — table-driven temp-root classification"
echo "  keeper_dir=$HEIMDALL_KEEPER_DIR"
echo "============================================================"
echo

# 1. Real macOS per-user Darwin temp root (mktemp -d's actual output when $TMPDIR is set,
#    i.e. any normal interactive/login shell) — plain env (TMPDIR still present).
H1="$(mktemp -d)"; CASE_HOMES="$CASE_HOMES $H1"; mkdir -p "$H1/.heimdall"
run_case "1 darwin-temp/plain" "$H1" skip plain

# 2. The SAME real Darwin temp root, but env -i (TMPDIR wiped) — the exact shape of
#    install-stranger.test.sh's real run_install() trigger. THE case that leaked in
#    production before /var/folders/*/T/* coverage existed.
H2="$(mktemp -d)"; CASE_HOMES="$CASE_HOMES $H2"; mkdir -p "$H2/.heimdall"
run_case "2 darwin-temp/env-i (real install-stranger shape)" "$H2" skip strip

# 3. Explicit /tmp root (Linux's default mktemp -d root; macOS symlinks /tmp -> /private/tmp,
#    covered by the /private/tmp/* arm) — env -i, TMPDIR wiped.
H3="$(mktemp -d /tmp/hmd-sbxguard.XXXXXX)"; CASE_HOMES="$CASE_HOMES $H3"; mkdir -p "$H3/.heimdall"
run_case "3 /tmp/env-i" "$H3" skip strip

# 4. /var/tmp root — some shells/CI runners default TMPDIR here instead of /tmp; added to the
#    glob alongside /tmp for the same reason. env -i, TMPDIR wiped.
H4="$(mktemp -d /var/tmp/hmd-sbxguard.XXXXXX)"; CASE_HOMES="$CASE_HOMES $H4"; mkdir -p "$H4/.heimdall"
run_case "4 /var/tmp/env-i" "$H4" skip strip

# 5. NEGATIVE CONTROL — a real fixture HOME under FIXTURE_CACHE (outside the repo checkout AND
#    outside every OS-temp-root glob the guard checks; see FIXTURE_CACHE's own comment above).
#    Proves the (now-wider) glob does not over-match real dev use: the doctor must STILL
#    auto-launch exactly as it did before this guard ever existed.
H5="$FIXTURE_CACHE/.hmd-test-fixture-sandboxguard.$$"; CASE_HOMES="$CASE_HOMES $H5"; mkdir -p "$H5/.heimdall"
run_case "5 real-fixture-home/plain (negative control)" "$H5" spawn plain

# 6. ESCAPE HATCH — a sandbox-shaped HOME, but HMD_DOCTOR_ALLOW_TMP_HOME=1 explicitly overrides
#    the guard. Untested anywhere else in the corpus: proves the documented opt-out actually
#    works, not just that it exists in the case-pattern's own comment.
H6="$(mktemp -d)"; CASE_HOMES="$CASE_HOMES $H6"; mkdir -p "$H6/.heimdall"
run_case "6 darwin-temp + HMD_DOCTOR_ALLOW_TMP_HOME=1 (escape hatch)" "$H6" spawn plain "HMD_DOCTOR_ALLOW_TMP_HOME=1"

echo
echo "============================================================"
printf "heimdall-presence-sandbox-guard: %d passed, %d failed\n" "$PASS" "$FAIL"
echo "============================================================"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
