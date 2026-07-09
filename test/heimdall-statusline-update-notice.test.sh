#!/usr/bin/env bash
#
# heimdall-statusline-update-notice.test.sh — the statusline HUD must surface an
# "update available" notice the moment a newer Heimdall release exists, so a dev
# learns about it AMBIENTLY (RJ's ask) without running any command.
#
# THE CONTRACT under test (sentinels/hmd-statusline.py :: update_notice):
#   1. behind  — cached installed < cached latest -> the HUD CONTAINS a compact
#                notice naming the TARGET version + the update command
#                (`⬆ v<latest> available · hmd --update`). Falsifiable: strip the
#                render wiring and this assertion goes RED.
#   2. current — installed == latest -> notice ABSENT (no false "behind").
#   3. ahead   — installed  > latest -> notice ABSENT.
#   4. corrupt — a garbage/half-written cache -> notice ABSENT, render exits 0
#                (fail-safe: the line must NEVER break on a bad cache).
#   5. missing — no cache at all -> notice ABSENT, render exits 0 (silent).
#   6. ZERO NETWORK / ZERO PROBE — the render READS the cache only. It performs no
#      version probe: the cache file's mtime is UNCHANGED after a render, and the
#      notice still renders with `git` REMOVED from PATH (the only remote-tag probe
#      lives in bin/heimdall and needs git; its absence proves the render can't have
#      called it). This is the "statusline stays fast + off-box" guarantee.
#   7. the notice shows across density modes (full/compact/minimal), not just full.
#
# HERMETIC: a throwaway $HOME (no ~/.heimdall) + a separate $HEIMDALL_HOME holding
# ONLY the seeded update-check.json, CP pointed at an unreachable port so no render
# forks off-box, a fixed clock. The cache is consumed by the SAME writer schema
# bin/heimdall uses: {checked_epoch, installed, latest}.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
SL="$ROOT/sentinels/hmd-statusline.py"

command -v python3 >/dev/null 2>&1 || { echo "SKIP: python3 unavailable"; exit 0; }
[ -f "$SL" ] || { echo "FATAL: statusline missing at $SL"; exit 2; }

pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n' "$1"; }

# Seed the update-check cache exactly as bin/heimdall's background probe writes it.
# $1=HEIMDALL_HOME dir  $2=installed  $3=latest  ($3 empty -> omit the field)
seed_cache() {
  local hh="$1" inst="$2" late="$3"
  mkdir -p "$hh"
  if [ -n "$late" ]; then
    printf '{"checked_epoch":%s,"installed":"%s","latest":"%s"}\n' "1000" "$inst" "$late" > "$hh/update-check.json"
  else
    printf '{"checked_epoch":%s,"installed":"%s"}\n' "1000" "$inst" > "$hh/update-check.json"
  fi
}

# Render the statusline hermetically. $1=HEIMDALL_HOME  $2=COLUMNS  [$3=PATH override]
render() {
  local hh="$1" cols="$2" pathv="${3:-/usr/bin:/bin:/usr/local/bin}"
  local home; home="$(mktemp -d)"
  printf '{"workspace":{"current_dir":"%s"},"model":{"display_name":"Opus"},"context_window":{"used_percentage":21}}' "$home" \
    | env -i PATH="$pathv" HOME="$home" HEIMDALL_HOME="$hh" \
        HMD_NOW=7 HEIMDALL_CP_URL="http://127.0.0.1:1" COLUMNS="$cols" \
        TERM=xterm python3 "$SL" --no-color 2>/dev/null
  local rc=$?
  rm -rf "$home"
  return $rc
}

# ── 1) BEHIND: installed < latest -> the notice, naming the target + command ──
HH="$(mktemp -d)"; seed_cache "$HH" "v2.0.18" "v9.9.9"
OUT="$(render "$HH" 120)"; RC=$?
[ "$RC" = 0 ] && ok "behind: render exits 0" || bad "behind: render exited $RC"
case "$OUT" in *"v9.9.9"*)   ok "behind: notice names the target version (v9.9.9)" ;;
  *) bad "behind: target version v9.9.9 ABSENT from HUD" ;; esac
case "$OUT" in *"available"*) ok "behind: notice says 'available'" ;;
  *) bad "behind: 'available' ABSENT from HUD" ;; esac
case "$OUT" in *"hmd --update"*) ok "behind: notice names the update command (hmd --update)" ;;
  *) bad "behind: 'hmd --update' ABSENT from HUD" ;; esac
rm -rf "$HH"

# ── 2) CURRENT: installed == latest -> ABSENT (no false behind) ──
HH="$(mktemp -d)"; seed_cache "$HH" "v9.9.9" "v9.9.9"
OUT="$(render "$HH" 120)"
case "$OUT" in *"available"*|*"hmd --update"*) bad "current: a false 'behind' notice appeared on a current install" ;;
  *) ok "current: no notice (equal version -> silent)" ;; esac
rm -rf "$HH"

# ── 3) AHEAD: installed > latest -> ABSENT ──
HH="$(mktemp -d)"; seed_cache "$HH" "v9.9.10" "v9.9.9"
OUT="$(render "$HH" 120)"
case "$OUT" in *"available"*|*"hmd --update"*) bad "ahead: notice appeared on an ahead install" ;;
  *) ok "ahead: no notice (installed > latest -> silent)" ;; esac
rm -rf "$HH"

# ── 4) CORRUPT cache -> ABSENT + exit 0 (fail-safe, never breaks the line) ──
HH="$(mktemp -d)"; mkdir -p "$HH"; printf '{"latest":"v9.9.9", NOT JSON at all <<<' > "$HH/update-check.json"
OUT="$(render "$HH" 120)"; RC=$?
[ "$RC" = 0 ] && ok "corrupt: render still exits 0 (fail-safe)" || bad "corrupt: render exited $RC (must never break)"
case "$OUT" in *"available"*|*"hmd --update"*) bad "corrupt: a notice rendered off a corrupt cache" ;;
  *) ok "corrupt: no notice off a corrupt cache" ;; esac
[ -n "$OUT" ] && ok "corrupt: the HUD still renders a line" || bad "corrupt: the HUD rendered BLANK"
rm -rf "$HH"

# ── 5) MISSING cache -> ABSENT + exit 0 (silent) ──
HH="$(mktemp -d)"   # no update-check.json written
OUT="$(render "$HH" 120)"; RC=$?
[ "$RC" = 0 ] && ok "missing: render exits 0" || bad "missing: render exited $RC"
case "$OUT" in *"available"*|*"hmd --update"*) bad "missing: a notice rendered with no cache" ;;
  *) ok "missing: no notice with no cache (silent)" ;; esac
rm -rf "$HH"

# ── 6) ZERO NETWORK / ZERO PROBE ──
HH="$(mktemp -d)"; seed_cache "$HH" "v2.0.18" "v9.9.9"
CACHE="$HH/update-check.json"
MT_BEFORE="$(python3 -c 'import os,sys;print(int(os.path.getmtime(sys.argv[1])))' "$CACHE")"
# a) mtime unchanged -> the render did not write/refresh the cache (no probe)
render "$HH" 120 >/dev/null
MT_AFTER="$(python3 -c 'import os,sys;print(int(os.path.getmtime(sys.argv[1])))' "$CACHE")"
[ "$MT_BEFORE" = "$MT_AFTER" ] && ok "zero-probe: cache mtime unchanged by render (no refresh/network)" \
                              || bad "zero-probe: render MUTATED the cache (before=$MT_BEFORE after=$MT_AFTER)"
# b) the UPDATE path is a PURE LOCAL READ — no shell-out, no probe. We import the
#    statusline module, BOMB every shell-out primitive (subprocess.run/Popen,
#    os.popen/os.system) so any attempt to probe raises, then call update_notice().
#    A shell-out would be swallowed by update_notice's fail-safe try/except and
#    return '' → the notice vanishes → RED. It returns the notice iff it touched
#    NOTHING but the cache file. (Falsifier: make update_notice() shell out to git
#    and this goes RED.)
if python3 - "$SL" "$HH" <<'PY'
import importlib.util, sys, os
sl_path, hh = sys.argv[1], sys.argv[2]
os.environ['HEIMDALL_HOME'] = hh
spec = importlib.util.spec_from_file_location('sl_under_test', sl_path)
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
def bomb(*a, **k): raise AssertionError('update path attempted a shell-out / probe')
m.subprocess.run = bomb; m.subprocess.Popen = bomb
m.os.popen = bomb; m.os.system = bomb
note = m.update_notice()
sys.exit(0 if ('v9.9.9' in note and 'available' in note and 'hmd --update' in note) else 1)
PY
then ok "zero-network: update_notice() is a pure cache read (no subprocess/probe)"
else bad "zero-network: update_notice() shelled out or read nothing (probe leaked into the render path)"; fi
rm -rf "$HH"

# ── 7) density coverage: the notice reaches compact + minimal too, not just full ──
HH="$(mktemp -d)"; seed_cache "$HH" "v2.0.18" "v9.9.9"
for c in 120 100 60; do
  OUT="$(render "$HH" "$c")"
  case "$OUT" in *"v9.9.9"*"available"*) ok "density: notice present at COLUMNS=$c" ;;
    *) bad "density: notice ABSENT at COLUMNS=$c" ;; esac
done
rm -rf "$HH"

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ] || exit 1
