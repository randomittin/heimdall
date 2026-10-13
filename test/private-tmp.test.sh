#!/usr/bin/env bash
#
# test/private-tmp.test.sh -- proof for test/lib/private-tmp.sh (hmd_private_tmp / hmd_private_tmp_rm) and hmd_test_mktemp_shim.
#
# WHY: 2026-10-14, ~22,000 entries and gigabytes in one user temp dir. Two causes were measured. (1) On this platform a TEMPLATE-LESS mktemp ignores TMPDIR
# (Darwin 27: `TMPDIR=x mktemp -d` answers with /var/folders/.../T), so the "private TMPDIR" five suites got in 2.4.8 left every bare `mktemp` where it was --
# only the sweep's PATH shim contained them. (2) A bash script killed by a signal while it waits on a child skips an EXIT trap it never set a signal trap for.
# The platform is emulated (a fake mktemp that ignores TMPDIR for exactly those forms) so this proves the shim on every OS, not only the one that has the bug.
#
#   1  with a mktemp that ignores TMPDIR: bare `mktemp`, `mktemp -d` and `mktemp -d -t p` all land under the private root, nothing under the "user temp dir"
#   2  the pip / uv caches point inside the root
#   3  the root is removed on a normal exit, on TERM and on HUP (the driver waits on a child, as a suite does)
#   4  hmd_private_tmp_rm removes only what hmd_private_tmp made: not an unset variable, not a symlink
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$SELF_DIR/lib/private-tmp.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  PASS %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; }
[ -r "$LIB" ] || { echo "FATAL: $LIB missing" >&2; echo "private-tmp: 0 passed, 1 failed."; exit 2; }
# shellcheck source=lib/private-tmp.sh disable=SC1091  # the default run never opens sourced files
. "$LIB" && hmd_private_tmp private-tmp-test || exit 1

T="$TMPDIR/w"; mkdir -p "$T/plat" "$T/user" "$T/run"
cat > "$T/plat/mktemp" <<'EOF'
#!/bin/sh
# a platform whose mktemp ignores TMPDIR for its template-less form (Darwin 27): those answer under FAKE_USER_TMP; an explicit template is honoured
d=""
case "$#" in
  0) ;;
  1) if [ "$1" = -d ]; then d=-d; else exec /usr/bin/mktemp "$@"; fi ;;
  *) exec /usr/bin/mktemp "$@" ;;
esac
exec /usr/bin/mktemp $d "$FAKE_USER_TMP/tmp.XXXXXXXX"
EOF
chmod +x "$T/plat/mktemp"
cat > "$T/driver.sh" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
. "$LIB" || exit 9
hmd_private_tmp drv || exit 9
{
  printf 'pid=%s\n' "$$"
  printf 'root=%s\n' "$TMPDIR"
  printf 'bare=%s\n' "$(mktemp)"
  printf 'dir=%s\n' "$(mktemp -d)"
  printf 'tflag=%s\n' "$(mktemp -d -t pfx)"
  printf 'caches=%s|%s|%s\n' "$UV_CACHE_DIR" "$PIP_CACHE_DIR" "$XDG_CACHE_HOME"
} > "$OUT"
if [ "${MODE:-exit}" = park ]; then sleep 60 & printf 'sleep=%s\n' "$!" >> "$OUT"; wait; fi
exit 0
EOF
chmod +x "$T/driver.sh"

run_driver() { # MODE [TAG] -- the driver under the fake platform; its report goes to $T/run/out.<TAG, default MODE>
  local mode="$1" tag="${2:-$1}"
  : > "$T/run/out.$tag"
  env -i HOME="$T/run" PATH="$T/plat:/usr/bin:/bin" TMPDIR="$T/run" FAKE_USER_TMP="$T/user" LIB="$LIB" OUT="$T/run/out.$tag" MODE="$mode" /bin/bash "$T/driver.sh"
}
field() { sed -n "s/^$2=//p" "$T/run/out.$1" | head -n 1; }

echo "-- 1/2/3. a mktemp that ignores TMPDIR, a normal exit --"
run_driver exit; RC=$?
ROOT_="$(field exit root)"
if [ "$RC" -eq 0 ] && [ -n "$ROOT_" ] && case "$ROOT_" in "$T/run"/drv.*) true ;; *) false ;; esac; then ok "the private root is made under the TMPDIR it was given"; else bad "rc=$RC root='$ROOT_'"; fi
ALL_IN=1; for k in bare dir tflag; do case "$(field exit $k)" in "$ROOT_"/?*) ;; *) ALL_IN=0 ;; esac; done
if [ "$ALL_IN" = 1 ] && [ -z "$(ls -A "$T/user")" ]; then ok "bare mktemp, mktemp -d and mktemp -d -t land under the private root; nothing reached the 'user temp dir'"; else bad "mktemp results: bare=$(field exit bare) dir=$(field exit dir) tflag=$(field exit tflag); user dir holds: $(ls -A "$T/user" | paste -sd' ' -)"; fi
case "$(field exit caches)" in "$ROOT_/.cache/uv|$ROOT_/.cache/pip|$ROOT_/.cache") ok "UV_CACHE_DIR, PIP_CACHE_DIR and XDG_CACHE_HOME point inside the private root" ;; *) bad "caches: $(field exit caches)" ;; esac
if [ -n "$ROOT_" ] && [ ! -e "$ROOT_" ]; then ok "a normal exit removes the private root (shim, mktemp results and all)"; else bad "root survived a normal exit: $ROOT_"; fi

echo "-- 3. killed while it waits on a child --"
for SIG in TERM HUP; do
  run_driver park "$SIG" &
  I=0; while ! grep -q '^sleep=' "$T/run/out.$SIG" 2>/dev/null && [ "$I" -lt 100 ]; do sleep 0.1; I=$((I + 1)); done
  ROOT_="$(field "$SIG" root)"; SLP="$(field "$SIG" sleep)"; DPID="$(field "$SIG" pid)"
  if [ -n "$ROOT_" ] && [ -d "$ROOT_" ]; then ok "$SIG: precondition -- the driver is parked with its private root in place"; else bad "$SIG: driver never parked (root='$ROOT_')"; fi
  [ -z "$DPID" ] || kill -"$SIG" "$DPID" 2>/dev/null
  I=0; while [ -n "$DPID" ] && kill -0 "$DPID" 2>/dev/null && [ "$I" -lt 100 ]; do sleep 0.1; I=$((I + 1)); done
  wait
  [ -z "$SLP" ] || kill "$SLP" 2>/dev/null
  if [ -n "$ROOT_" ] && [ ! -e "$ROOT_" ]; then ok "$SIG removes the private root"; else bad "$SIG left the private root: $ROOT_"; fi
done

echo "-- 4. hmd_private_tmp_rm removes only what hmd_private_tmp made --"
mkdir -p "$T/keep/inner"; ln -s "$T/keep" "$T/link"
( HMD_PRIVATE_TMP=""; hmd_private_tmp_rm ) ; ( HMD_PRIVATE_TMP="$T/link"; hmd_private_tmp_rm ); ( unset HMD_PRIVATE_TMP; hmd_private_tmp_rm )
if [ -d "$T/keep/inner" ] && [ -L "$T/link" ]; then ok "an empty variable, a symlink and an unset variable remove nothing"; else bad "hmd_private_tmp_rm removed something it did not make"; fi

echo ""
echo "private-tmp: $PASS passed, $FAIL failed."
[ "$FAIL" -eq 0 ]
