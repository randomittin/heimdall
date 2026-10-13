#!/usr/bin/env bash
# private-tmp.sh -- sourced by a suite that must leave nothing in the machine's temp dir when it is run on its OWN (`bash test/x.test.sh`), not only inside
# test/run-all.sh (which gives every suite a private TMPDIR, measures what is left in it and removes it: test/lib/run-all-guards.sh).
#
#   . "$SELF_DIR/lib/private-tmp.sh" && hmd_private_tmp <suite-name> || exit 1
#
# hmd_private_tmp NAME does four things a standalone run was missing (2026-10-14: ~22,000 entries and gigabytes in one user temp dir):
#   1. makes ONE private root under the current TMPDIR and makes it THE TMPDIR (exported), so what the suite makes through mktemp / $TMPDIR / python
#      tempfile lands in it;
#   2. makes a TEMPLATE-LESS mktemp honour it. This platform's mktemp does not (Darwin 27: `TMPDIR=x mktemp -d` and `mktemp -d -t p` answer with the user
#      temp dir /var/folders/.../T whatever TMPDIR says), so a "private TMPDIR" alone left every bare `mktemp` where it was -- the tmp.XXXXXXXXXX pile. The runner's
#      own probe-and-shim (hmd_test_mktemp_shim, test/lib/run-all-guards.sh) is reused: a PATH shim, installed only when the probe shows mktemp ignores TMPDIR.
#      HMD_MKTEMP_SHIM_DIR names it, for a child whose PATH is rebuilt (`env -i ... PATH=...`);
#   3. points the caches pip and uv write at (PIP_CACHE_DIR, UV_CACHE_DIR, XDG_CACHE_HOME) into the same root, so a tool run under a throwaway HOME never
#      grows a .cache/uv of its own in a tmp.XXXX dir and never writes the shared cache;
#   4. removes the root on EXIT, and makes INT / TERM / HUP exit so that EXIT runs: a bash script killed by a signal while it waits on a child used to leave it.
# A suite that sets its OWN EXIT trap replaces this one: it must end that trap with `hmd_private_tmp_rm`.
# Not covered, by nature: SIGKILL, and a child started with `env -i` (it drops TMPDIR and the cache variables: hand them over, see $HMD_MKTEMP_SHIM_DIR too).

HMD_PRIVATE_TMP=""

# hmd_private_tmp_rm -- remove the private root (idempotent; refuses anything that is not the directory hmd_private_tmp made).
hmd_private_tmp_rm() {
  [ -n "${HMD_PRIVATE_TMP:-}" ] && [ -d "$HMD_PRIVATE_TMP" ] && [ ! -L "$HMD_PRIVATE_TMP" ] || return 0
  chmod -R u+rwX "$HMD_PRIVATE_TMP" 2>/dev/null
  rm -rf "$HMD_PRIVATE_TMP" 2>/dev/null || { sleep 0.3; chmod -R u+rwX "$HMD_PRIVATE_TMP" 2>/dev/null; rm -rf "$HMD_PRIVATE_TMP" 2>/dev/null; }
  return 0
}

hmd_private_tmp() {
  local name="${1:?hmd_private_tmp needs a suite name}" base="${TMPDIR:-/tmp}" lib
  base="${base%/}"; [ -n "$base" ] || base=/tmp
  HMD_PRIVATE_TMP="$(mktemp -d "$base/$name.XXXXXX")" || { echo "private-tmp: cannot make a temp dir under $base" >&2; return 1; }
  TMPDIR="$HMD_PRIVATE_TMP"
  XDG_CACHE_HOME="$TMPDIR/.cache"; UV_CACHE_DIR="$TMPDIR/.cache/uv"; PIP_CACHE_DIR="$TMPDIR/.cache/pip"
  export TMPDIR XDG_CACHE_HOME UV_CACHE_DIR PIP_CACHE_DIR
  lib="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/run-all-guards.sh"
  if [ -r "$lib" ]; then
    # shellcheck source=run-all-guards.sh disable=SC1091  # the default run never opens sourced files
    . "$lib"
    hmd_test_mktemp_shim "$TMPDIR" || echo "private-tmp: mktemp ignores TMPDIR here and no shim could be made -- bare mktemp calls will land outside $TMPDIR" >&2
  fi
  trap hmd_private_tmp_rm EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  trap 'exit 129' HUP
  return 0
}
