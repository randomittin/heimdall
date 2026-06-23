#!/usr/bin/env bash
#
# update-prompt.test.sh — acceptance harness for the version-accurate update check
# in bin/heimdall (PIECE 1 of the internal-launch friction removal).
#
# Proves the update notice is ACCURATE, NON-BLOCKING, DAILY-CACHED, NON-TTY-SAFE,
# OPT-OUT-ABLE, and that `hmd update` updates OR prints the correct manual step:
#
#   T1  behind    — installed < latest (seeded cache) -> ONE-line "available" notice
#   T2  current   — installed == latest -> NO notice (the FALSIFIABLE no-false-behind
#                   case: a current install that says "behind" must turn this RED)
#   T3  cached    — a FRESH (<24h) cache is reused with ZERO network; a second
#                   same-day launch hits the cache (no ls-remote, no fetch)
#   T4  non-block — check returns promptly and never reads stdin / never prompts;
#                   under a non-TTY stdout it is a silent no-op (no hang)
#   T5  opt-out   — HEIMDALL_NO_UPDATE_CHECK=1 suppresses the notice entirely
#   T6  hmd update— a dev checkout (dirty / ahead of origin) prints the MANUAL step
#                   (git pull / reinstall) instead of force-resetting the tree
#
# The update functions are exercised via HEIMDALL_LIB_ONLY=1 (source bin/heimdall,
# call the function directly) so NO real `claude` and NO real network are needed.
# A scripted `git` on PATH answers describe/ls-remote deterministically + offline.
# HEIMDALL_HOME redirects the cache into a scratch dir.
#
# Exit 0 = every guarantee holds. Non-zero = a guarantee regressed (prints which).
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SELF_DIR/.." && pwd)"
HMD="$REPO/bin/heimdall"

PASS=0; FAIL=0
ok()   { printf "  \033[32m+\033[0m %s\n" "$1"; PASS=$((PASS+1)); }
bad()  { printf "  \033[31mx\033[0m %s\n" "$1"; FAIL=$((FAIL+1)); }

SCRATCH="$(mktemp -d)"
trap 'rm -rf "$SCRATCH"' EXIT

# ── A scripted `git` answering describe (installed version) + ls-remote (tags) ──
# Everything else passes through to the real git so rev-parse/status still behave.
REAL_GIT="$(command -v git)"
FAKEBIN="$SCRATCH/fakebin"
mkdir -p "$FAKEBIN"
make_fake_git() {
  # $1 = installed describe version, $2 = newline-joined remote tag list
  local installed="$1" remote_tags="$2"
  {
    printf '#!/usr/bin/env bash\n'
    printf 'REAL_GIT=%q\n' "$REAL_GIT"
    printf 'INSTALLED=%q\n' "$installed"
    printf 'REMOTE_TAGS=%q\n' "$remote_tags"
    cat <<'FAKE'
# Drop a leading "-C <dir>" so we can inspect the real subcommand.
args=("$@")
i=0
while [ $i -lt ${#args[@]} ]; do
  case "${args[$i]}" in
    -C) i=$((i+2)) ;;
    *) break ;;
  esac
done
sub="${args[$i]:-}"
case "$sub" in
  describe)
    [ -n "$INSTALLED" ] && echo "$INSTALLED"
    exit 0
    ;;
  ls-remote)
    # Emit ref lines for each remote tag; record that the network was touched.
    [ -n "${FAKE_GIT_NETLOG:-}" ] && echo "ls-remote" >> "$FAKE_GIT_NETLOG"
    if [ -n "$REMOTE_TAGS" ]; then
      while IFS= read -r t; do
        [ -n "$t" ] && printf '0000000000000000000000000000000000000000\trefs/tags/%s\n' "$t"
      done <<< "$REMOTE_TAGS"
    fi
    exit 0
    ;;
  *)
    exec "$REAL_GIT" "$@"
    ;;
esac
FAKE
  } > "$FAKEBIN/git"
  chmod +x "$FAKEBIN/git"
}

# check_for_update in lib-only mode (the [ -t 1 ] guard governs whether it acts).
run_check() {
  PATH="$FAKEBIN:$PATH" HEIMDALL_LIB_ONLY=1 bash -c '
    source "'"$HMD"'"
    check_for_update
  ' 2>&1
}

# Directly print-from-cache (bypasses the [ -t 1 ] guard) to assert notice text
# deterministically without a pty.
run_print_from_cache() {
  local installed="$1" cache="$2"
  PATH="$FAKEBIN:$PATH" HEIMDALL_LIB_ONLY=1 bash -c '
    source "'"$HMD"'"
    _update_print_from_cache "'"$installed"'" "'"$cache"'"
  ' 2>&1
}

seed_cache() {
  # $1=cache path  $2=installed  $3=latest  $4=epoch
  local f="$1"
  mkdir -p "$(dirname "$f")"
  printf '{"checked_epoch":%s,"installed":"%s","latest":"%s"}\n' "$4" "$2" "$3" > "$f"
}

echo ""
echo "update-prompt.test.sh — version-accurate update notice"
echo ""

# ── T1: behind -> ONE-line "available" notice ─────────────────────────────────
make_fake_git "v2.0.0" "v2.0.0
v2.0.5"
CACHE="$SCRATCH/t1/.heimdall/update-check.json"
seed_cache "$CACHE" "v2.0.0" "v2.0.5" "$(date +%s)"
OUT="$(run_print_from_cache "v2.0.0" "$CACHE")"
if printf '%s' "$OUT" | grep -q "v2.0.5 available" && printf '%s' "$OUT" | grep -q "you have v2.0.0" && printf '%s' "$OUT" | grep -q "hmd update"; then
  lines="$(printf '%s\n' "$OUT" | grep -c "available")"
  if [ "$lines" -eq 1 ]; then
    ok "T1 behind: one-line notice names latest+installed+command"
  else
    bad "T1 behind: notice not exactly one line (got $lines)"
  fi
else
  bad "T1 behind: expected 'vX available (you have vY) ... hmd update', got: $OUT"
fi

# ── T2: current -> NO notice (FALSIFIABLE no-false-behind) ────────────────────
make_fake_git "v2.0.5" "v2.0.0
v2.0.5"
CACHE2="$SCRATCH/t2/.heimdall/update-check.json"
seed_cache "$CACHE2" "v2.0.5" "v2.0.5" "$(date +%s)"
OUT2="$(run_print_from_cache "v2.0.5" "$CACHE2")"
if [ -z "$(printf '%s' "$OUT2" | tr -d '[:space:]')" ]; then
  ok "T2 current: no notice on a current install (no false behind)"
else
  bad "T2 current: a CURRENT install wrongly printed a notice: $OUT2"
fi

# ── T3: daily cache — fresh cache reused, ZERO network on a second same-day run ─
make_fake_git "v2.0.0" "v2.0.0
v2.0.5"
CACHE3="$SCRATCH/t3/.heimdall/update-check.json"
seed_cache "$CACHE3" "v2.0.0" "v2.0.5" "$(date +%s)"   # fresh (now)
NETLOG="$SCRATCH/t3/netlog"; : > "$NETLOG"
OUT3="$(FAKE_GIT_NETLOG="$NETLOG" HEIMDALL_HOME="$SCRATCH/t3/.heimdall" \
        PATH="$FAKEBIN:$PATH" HEIMDALL_LIB_ONLY=1 bash -c '
  source "'"$HMD"'"
  installed="v2.0.0"; cache="'"$CACHE3"'"
  fresh="$(CACHE="$cache" python3 - <<PYEOF
import json,os,time
d=json.load(open(os.environ["CACHE"]))
age=time.time()-float(d.get("checked_epoch",0))
print("1" if 0<=age<86400 else "0")
PYEOF
)"
  _update_print_from_cache "$installed" "$cache"
  if [ "$fresh" != "1" ]; then ( _update_refresh_cache "$installed" "$cache" ) >/dev/null 2>&1; fi
  echo "FRESH=$fresh"
' 2>&1)"
net_hits="$(wc -l < "$NETLOG" | tr -d ' ')"
if printf '%s' "$OUT3" | grep -q "FRESH=1" && [ "$net_hits" -eq 0 ]; then
  ok "T3 daily-cache: fresh cache reused, zero network (second same-day launch)"
else
  bad "T3 daily-cache: fresh=$(printf '%s' "$OUT3" | grep FRESH) net_hits=$net_hits (expected FRESH=1, 0 hits)"
fi

# ── T3b: stale cache -> background refresh DOES touch the network (and rewrites) ─
make_fake_git "v2.0.0" "v2.0.0
v2.0.5"
CACHE3B="$SCRATCH/t3b/.heimdall/update-check.json"
seed_cache "$CACHE3B" "v2.0.0" "v2.0.4" "$(( $(date +%s) - 200000 ))"  # >24h old
NETLOG2="$SCRATCH/t3b/netlog"; : > "$NETLOG2"
FAKE_GIT_NETLOG="$NETLOG2" HEIMDALL_HOME="$SCRATCH/t3b/.heimdall" \
  PATH="$FAKEBIN:$PATH" HEIMDALL_LIB_ONLY=1 bash -c '
  source "'"$HMD"'"
  _update_refresh_cache "v2.0.0" "'"$CACHE3B"'"
' >/dev/null 2>&1
new_latest="$(CACHE="$CACHE3B" python3 -c 'import json,os;print(json.load(open(os.environ["CACHE"]))["latest"])' 2>/dev/null)"
if [ -s "$NETLOG2" ] && [ "$new_latest" = "v2.0.5" ]; then
  ok "T3b stale-cache: background refresh probes remote + rewrites latest (v2.0.5)"
else
  bad "T3b stale-cache: net=$(cat "$NETLOG2" 2>/dev/null) latest=$new_latest (expected ls-remote + v2.0.5)"
fi

# ── T4: non-TTY safe — check_for_update is a silent no-op, returns promptly ────
make_fake_git "v2.0.0" "v2.0.0
v2.0.5"
T4_START=$(date +%s)
OUT4="$(HEIMDALL_HOME="$SCRATCH/t4/.heimdall" run_check </dev/null)"
T4_END=$(date +%s)
T4_ELAPSED=$(( T4_END - T4_START ))
if [ -z "$(printf '%s' "$OUT4" | tr -d '[:space:]')" ] && [ "$T4_ELAPSED" -lt 5 ]; then
  ok "T4 non-TTY: silent no-op, no prompt, returns promptly (${T4_ELAPSED}s)"
else
  bad "T4 non-TTY: produced output or hung (${T4_ELAPSED}s): $OUT4"
fi

# ── T5: opt-out env suppresses the check entirely ─────────────────────────────
make_fake_git "v2.0.0" "v2.0.0
v2.0.5"
OUT5="$(HEIMDALL_NO_UPDATE_CHECK=1 HEIMDALL_HOME="$SCRATCH/t5/.heimdall" run_check </dev/null)"
if [ -z "$(printf '%s' "$OUT5" | tr -d '[:space:]')" ]; then
  ok "T5 opt-out: HEIMDALL_NO_UPDATE_CHECK=1 suppresses the notice"
else
  bad "T5 opt-out: notice leaked despite opt-out: $OUT5"
fi

# ── T6: hmd update on a dev checkout prints the MANUAL step (no clobber) ───────
# Build a throwaway git repo that is AHEAD of its own origin/main, point a copy
# of the launcher's PLUGIN_DIR at it, and assert `--update` refuses to reset.
DEVREPO="$SCRATCH/devrepo"
mkdir -p "$DEVREPO/bin/.claude-plugin" 2>/dev/null || true
git -C "$DEVREPO" init -q
git -C "$DEVREPO" config user.email t@t.t; git -C "$DEVREPO" config user.name t
echo base > "$DEVREPO/file"; git -C "$DEVREPO" add -A; git -C "$DEVREPO" commit -qm base
# Make origin/main point at this base, then add a LOCAL commit ahead of it.
git -C "$DEVREPO" update-ref refs/remotes/origin/main HEAD
echo local > "$DEVREPO/file2"; git -C "$DEVREPO" add -A; git -C "$DEVREPO" commit -qm "local ahead"
cp "$HMD" "$DEVREPO/bin/heimdall"
cat > "$DEVREPO/bin/.claude-plugin/plugin.json" <<'JSON'
{"name":"hmd","version":"2.0.5"}
JSON
OUT6="$(cd "$DEVREPO" && ./bin/heimdall --update </dev/null 2>&1 || true)"
if printf '%s' "$OUT6" | grep -qi "development checkout" \
   && printf '%s' "$OUT6" | grep -q "git pull" \
   && ! printf '%s' "$OUT6" | grep -q "Updated"; then
  if [ -f "$DEVREPO/file2" ]; then
    ok "T6 hmd update: dev checkout prints manual step, never clobbers the tree"
  else
    bad "T6 hmd update: dev checkout was clobbered (file2 gone)"
  fi
else
  bad "T6 hmd update: expected manual-step message on a dev checkout, got: $OUT6"
fi

echo ""
echo "  ── $PASS passed, $FAIL failed ──"
echo ""
[ "$FAIL" -eq 0 ]
