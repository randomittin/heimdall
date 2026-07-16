#!/usr/bin/env bash
#
# cc-update.test.sh — acceptance for hmd keeping Claude Code updated WITHOUT ever
# disturbing a live session.
#
#   bash test/cc-update.test.sh    (exit 0 = all cases pass)
#
# Covers two binaries and one config:
#   * bin/heimdall-gc `ccversions` — reclaims retired ~/.local/share/claude/versions/<v>
#     binaries (~230MB each) on a PROOF of non-use, never otherwise.
#   * bin/heimdall-cc-selfheal — health detection must be READ-ONLY, and the version
#     a session is pinned to must be surfaced rather than force-swapped.
#   * .mcp.json — must not reference an env var that is unset in project context.
#
# THE SAFETY PROPERTIES (cases 2-5). Reaping a 230MB binary out from under a live
# multi-day session, or removing a lock another process owns, is unrecoverable damage.
# Each of these plants a live holder and asserts the file SURVIVES, so a regression that
# widens the reap goes red rather than silently eating a running session's binary.
#
# WHY LSOF AND NOT ARGV/LOCKS (case 4 exists because of this). On a real machine a pinned
# session's argv is just "claude" — no version path in it — and a version can be executed
# with NO lock file at all. An argv- or lock-only reaper therefore deletes a version that
# is actively executing. Case 4 plants exactly that shape (live pid, no lock, argv-free)
# and would pass for a wrong implementation only if lsof were ignored.
#
# R6 (checks must be able to fail): every case asserts a behaviour a regression would flip.
# All fixtures are stubs + temp dirs — the real ~/.local/share/claude is never touched and
# no real `claude update` is ever invoked.
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SELF_DIR/.." && pwd)"
GC="$REPO/bin/heimdall-gc"
HEAL="$REPO/bin/heimdall-cc-selfheal"

PASS=0; FAIL=0
ok()  { printf '  \033[32mPASS\033[0m %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAIL=$((FAIL+1)); }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/cc-update-test.XXXXXX")"
cleanup() { rm -rf "$WORK" 2>/dev/null || true; }
trap cleanup EXIT

# ── fixture: a native-shaped claude install ─────────────────────────────────────
# versions/{2.1.208,2.1.209,2.1.210,2.1.211}, launcher symlink -> 2.1.211, lock dir.
# Mirrors the real on-disk shape (four ~230MB binaries) at 1KB each.
mk_install() {
  local root="$1"; shift
  V="$root/versions"; L="$root/locks"; BIN="$root/bin/claude"
  rm -rf "$root"; mkdir -p "$V" "$L" "$root/bin"
  local i=0
  for v in 2.1.208 2.1.209 2.1.210 2.1.211; do
    head -c 1024 /dev/zero > "$V/$v" 2>/dev/null
    # distinct, ascending mtimes so newest-first ordering is deterministic
    touch -t "20260714120${i}" "$V/$v" 2>/dev/null
    i=$((i + 1))
  done
  ln -sf "$V/2.1.211" "$BIN"
}

# a lock exactly matching Claude's real schema
mk_lock() {
  printf '{\n  "pid": %s,\n  "version": "%s",\n  "execPath": "%s/%s",\n  "acquiredAt": 1784053918878\n}\n' \
    "$2" "$1" "$V" "$1" > "$L/$1.lock"
}

# an `lsof -t <file>` stub: LSOF_MAP lines are "<version> <pid>"
mk_lsof() {
  cat > "$WORK/lsof-stub" <<'EOF'
#!/usr/bin/env bash
f="${1:-}"; base="${f##*/}"
[ -r "$LSOF_MAP" ] || exit 0
while read -r v p; do [ "$v" = "$base" ] && printf '%s\n' "$p"; done < "$LSOF_MAP"
exit 0
EOF
  chmod +x "$WORK/lsof-stub"
}

gc_ccv() {  # run the reaper against the fixture; args passed through
  HMD_GC_CC_VERSIONS="$V" HMD_GC_CC_BIN="$BIN" HMD_GC_CC_LOCKS="$L" \
  HMD_GC_CC_LSOF="$WORK/lsof-stub" LSOF_MAP="$WORK/lsof-map" \
  HMD_GC_LIVE_PIDS="${LIVE_PIDS:-}" HMD_GC_CC_KEEP="${KEEP:-0}" \
  bash "$GC" ccversions "$@" 2>&1
}

echo "cc-update.test.sh"
mk_lsof

# ── 1. a retired, unreferenced version IS reaped ────────────────────────────────
# 2.1.208: not the symlink target, no live pid, no lock. The ONLY provably-dead one.
mk_install "$WORK/i1"; : > "$WORK/lsof-map"
LIVE_PIDS="" KEEP=0 gc_ccv >/dev/null 2>&1
if [ ! -e "$V/2.1.208" ]; then ok "unreferenced retired version is reaped"
else bad "unreferenced retired version was NOT reaped (no disk ever reclaimed)"; fi

# ── 2. SAFETY: the current symlink target is NEVER reaped ───────────────────────
if [ -e "$V/2.1.211" ]; then ok "current symlink target survives"
else bad "current symlink target was reaped — this bricks the claude launcher"; fi

# ── 3. SAFETY: a version whose lock is held by a LIVE pid is NEVER reaped ───────
mk_install "$WORK/i3"; : > "$WORK/lsof-map"
mk_lock 2.1.209 8029                      # live holder, mirrors the real pinned session
LIVE_PIDS="8029" KEEP=0 gc_ccv >/dev/null 2>&1
if [ -e "$V/2.1.209" ]; then ok "version locked by a LIVE pid survives"
else bad "version locked by a LIVE pid was reaped — pulled from under a live session"; fi
if [ -e "$L/2.1.209.lock" ]; then ok "a LIVE pid's lock is never removed (Claude's protocol is read, not written)"
else bad "a LIVE pid's lock was removed — hmd must never touch a lock it does not own"; fi

# ── 4. SAFETY: a version executed by a live pid with NO lock is NEVER reaped ────
# The real 2.1.210 shape: live multi-day session, no lock file, argv says only "claude".
# A lock-only or argv-only reaper deletes this. lsof is what makes it survivable.
mk_install "$WORK/i4"; printf '2.1.210 32924\n' > "$WORK/lsof-map"
LIVE_PIDS="32924" KEEP=0 gc_ccv >/dev/null 2>&1
if [ -e "$V/2.1.210" ]; then ok "version executed by a live pid (no lock) survives"
else bad "version executed by a live pid was reaped — argv/lock-only logic is unsafe"; fi

# ── 5. a DEAD pid's lock does NOT protect its version (the reap still proceeds) ──
# Claude itself treats a dead-pid lock as stale, so it must not pin disk for hmd either.
mk_install "$WORK/i5"; : > "$WORK/lsof-map"
mk_lock 2.1.208 999999                    # pid absent from LIVE_PIDS => dead
LIVE_PIDS="8029" KEEP=0 gc_ccv >/dev/null 2>&1
if [ ! -e "$V/2.1.208" ]; then ok "a DEAD pid's lock does not protect a retired version"
else bad "a DEAD pid's stale lock blocked the reap — disk is pinned by a ghost"; fi

# ── 6. FAIL-SAFE: with no reference oracle, EVERYTHING is kept ──────────────────
mk_install "$WORK/i6"; : > "$WORK/lsof-map"
out="$(HMD_GC_CC_VERSIONS="$V" HMD_GC_CC_BIN="$BIN" HMD_GC_CC_LOCKS="$L" \
       HMD_GC_CC_KEEP=0 PATH="/nonexistent" \
       /bin/bash "$GC" ccversions 2>&1)"
if [ -e "$V/2.1.208" ] && printf '%s' "$out" | grep -q "keeping every version"; then
  ok "no lsof => cannot prove non-use => keeps every version"
else bad "reaped without a reference oracle — must fail safe to KEEP"; fi

# ── 7. --dry-run reports the reap but deletes nothing ───────────────────────────
mk_install "$WORK/i7"; : > "$WORK/lsof-map"
out="$(LIVE_PIDS="" KEEP=0 gc_ccv --dry-run)"
if [ -e "$V/2.1.208" ] && printf '%s' "$out" | grep -q "reap 2.1.208"; then
  ok "--dry-run reports the reap and mutates nothing"
else bad "--dry-run deleted a file or reported nothing"; fi

# ── 8. headroom: the newest unreferenced versions are kept ──────────────────────
mk_install "$WORK/i8"; : > "$WORK/lsof-map"
LIVE_PIDS="" KEEP=2 gc_ccv >/dev/null 2>&1
if [ -e "$V/2.1.210" ] && [ -e "$V/2.1.209" ] && [ ! -e "$V/2.1.208" ]; then
  ok "keeps the newest-2 unreferenced versions as rollback headroom"
else bad "headroom window wrong (expected 2.1.210+2.1.209 kept, 2.1.208 reaped)"; fi

# ── 9. THE REGRESSION THAT CAUSED THE BANNER: detection must not run an installer ──
# `claude update` is a mutating install. Running it as a health PROBE makes hmd race the
# auto-update poll of every live session for Claude's install lock — which produces the
# very "Auto-update failed" banner this tool exists to remove.
mkdir -p "$WORK/stub"
cat > "$WORK/stub/claude" <<'EOF'
#!/bin/sh
echo "$@" >> "$CLAUDE_CALLS"
exit 0
EOF
chmod +x "$WORK/stub/claude"
printf '{"installMethod":"native","autoUpdates":true}\n' > "$WORK/claude.json"
printf '{"outcome":"success","status":"success","version_from":"2.1.209","version_to":"2.1.211","error_code":null}\n' \
  > "$WORK/update-ok.json"
export CLAUDE_CALLS="$WORK/calls"; : > "$CLAUDE_CALLS"
PATH="$WORK/stub:$PATH" HEIMDALL_HOME="$WORK/h9" HEIMDALL_CLAUDE_CONFIG="$WORK/claude.json" \
  HEIMDALL_CC_UPDATE_RESULT="$WORK/update-ok.json" HEIMDALL_CC_VERSIONS="$WORK/none" \
  bash "$HEAL" status >/dev/null 2>&1
if [ ! -s "$CLAUDE_CALLS" ]; then ok "health detection is read-only (never invokes \`claude update\`)"
else bad "detection ran a mutating installer: $(tr '\n' ' ' < "$CLAUDE_CALLS")"; fi

# ── 10. health is read from Claude's OWN recorded outcome ───────────────────────
printf '{"outcome":"failed","status":"install_failed","version_from":"2.1.209","version_to":null,"error_code":"network_error"}\n' \
  > "$WORK/update-bad.json"
out="$(PATH="$WORK/stub:$PATH" HEIMDALL_HOME="$WORK/h10" HEIMDALL_CLAUDE_CONFIG="$WORK/claude.json" \
       HEIMDALL_CC_UPDATE_RESULT="$WORK/update-bad.json" HEIMDALL_CC_VERSIONS="$WORK/none" \
       bash "$HEAL" status 2>&1)"
if printf '%s' "$out" | grep -q "last-update-failed"; then ok "a recorded install_failed is reported as unhealthy"
else bad "recorded failure not detected: $out"; fi
out="$(PATH="$WORK/stub:$PATH" HEIMDALL_HOME="$WORK/h10b" HEIMDALL_CLAUDE_CONFIG="$WORK/claude.json" \
       HEIMDALL_CC_UPDATE_RESULT="$WORK/update-ok.json" HEIMDALL_CC_VERSIONS="$WORK/none" \
       bash "$HEAL" status 2>&1)"
if printf '%s' "$out" | grep -q "healthy"; then ok "a recorded success is reported healthy"
else bad "recorded success misreported: $out"; fi
# a missing result file must never be invented into a fault
out="$(PATH="$WORK/stub:$PATH" HEIMDALL_HOME="$WORK/h10c" HEIMDALL_CLAUDE_CONFIG="$WORK/claude.json" \
       HEIMDALL_CC_UPDATE_RESULT="$WORK/absent.json" HEIMDALL_CC_VERSIONS="$WORK/none" \
       bash "$HEAL" status 2>&1)"
if printf '%s' "$out" | grep -q "healthy"; then ok "an absent update-result is not invented into a fault"
else bad "absent result misreported as unhealthy: $out"; fi

# ── 11. the pin notice: a session on an older binary is told, once, to restart ──
mk_install "$WORK/i11"
cat > "$WORK/lsof-p-stub" <<EOF
#!/bin/sh
echo "claude 8029 rj txt REG 1,15 240377264 60375379 $V/2.1.209"
EOF
chmod +x "$WORK/lsof-p-stub"
out="$(HEIMDALL_HOME="$WORK/h11" HEIMDALL_CLAUDE_CONFIG="$WORK/claude.json" \
       HEIMDALL_CC_VERSIONS="$V" HEIMDALL_CC_PIN_PID=8029 HEIMDALL_CC_LSOF="$WORK/lsof-p-stub" \
       bash "$HEAL" pin-notice 2>&1)"
if printf '%s' "$out" | grep -q "2.1.209 is pinned" && printf '%s' "$out" | grep -q "2.1.211 is installed"; then
  ok "pin notice names the pinned version, the installed one, and the remedy"
else bad "pin notice wrong/absent: $out"; fi

# ── 12. the pin notice is SILENT when the session is already on the newest ──────
cat > "$WORK/lsof-p-newest" <<EOF
#!/bin/sh
echo "claude 92315 rj txt REG 1,15 242445680 61777638 $V/2.1.211"
EOF
chmod +x "$WORK/lsof-p-newest"
out="$(HEIMDALL_HOME="$WORK/h12" HEIMDALL_CLAUDE_CONFIG="$WORK/claude.json" \
       HEIMDALL_CC_VERSIONS="$V" HEIMDALL_CC_PIN_PID=92315 HEIMDALL_CC_LSOF="$WORK/lsof-p-newest" \
       bash "$HEAL" pin-notice 2>&1)"
if [ -z "$out" ]; then ok "pin notice is silent on an up-to-date session (no per-session noise)"
else bad "pin notice nagged an up-to-date session: $out"; fi

# ── 13. the opt-out is honoured ─────────────────────────────────────────────────
mkdir -p "$WORK/h13"; : > "$WORK/h13/no-selfheal"
out="$(HEIMDALL_HOME="$WORK/h13" HEIMDALL_CLAUDE_CONFIG="$WORK/claude.json" \
       HEIMDALL_CC_VERSIONS="$V" HEIMDALL_CC_PIN_PID=8029 HEIMDALL_CC_LSOF="$WORK/lsof-p-stub" \
       bash "$HEAL" pin-notice 2>&1)"
if [ -z "$out" ]; then ok "~/.heimdall/no-selfheal opts out of the pin notice"
else bad "opt-out ignored: $out"; fi

# ── 14. .mcp.json resolves with CLAUDE_PLUGIN_ROOT UNSET (the doctor defect) ────
# `claude doctor` reported: mcpServers.heimdall-ledger: Missing environment variables:
# CLAUDE_PLUGIN_ROOT. Claude expands ${VAR:-default}, so a default makes it resolve in
# project context (where the var is unset) as well as plugin context (where it is set).
arg="$(python3 -c "import json;print(json.load(open('$REPO/.mcp.json'))['mcpServers']['heimdall-ledger']['args'][0])" 2>/dev/null)"
case "$arg" in
  '${CLAUDE_PLUGIN_ROOT}'*) bad ".mcp.json still has a bare \${CLAUDE_PLUGIN_ROOT} — doctor stays dirty" ;;
  '${CLAUDE_PLUGIN_ROOT:-'*) ok ".mcp.json supplies a default for CLAUDE_PLUGIN_ROOT" ;;
  *) bad ".mcp.json ledger arg unexpected: $arg" ;;
esac
# and the target it resolves to in project context must actually exist + be executable
resolved="$REPO/${arg#*\}/}"
if [ -x "$resolved" ]; then ok "the ledger MCP target resolves to a real executable"
else bad "ledger MCP target missing/not executable: $resolved"; fi

echo
printf 'cc-update: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
