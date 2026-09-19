#!/usr/bin/env bash
# test/hmd-python.test.sh
#
# Proof for bin/lib/hmd-python.sh -- the one-shot interpreter resolver every hot
# path (statusline, ctx-meter, face) leans on.
#
# The incident this test exists for (2026-09-19): a macOS CLT update re-armed the
# Xcode license prompt. /usr/bin/python3 stayed EXECUTABLE but exited non-zero
# with a license nag. The resolver's on-disk cache named that path, the cache
# branch trusted `-x` alone, and every consumer died silently -- the status bar
# rendered "[ heimdall ]" all day. The rule this locks in: a candidate is
# accepted only after it has actually RUN (`-c pass`), cached or not.
#
# Isolation: HEIMDALL_HOME and PATH are redirected per case, so this never reads
# or writes the operator's real cache and never depends on the machine's python.

set -u

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$REPO/bin/lib/hmd-python.sh"

PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; }

TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT

# A working interpreter to stand in for "a good python": any real one on this
# machine. Found via a broad probe so the test itself does not inherit the bug.
GOOD=""
for c in /opt/homebrew/bin/python3 "$HOME"/.pyenv/versions/*/bin/python3 /usr/bin/python3 "$(command -v python3 2>/dev/null)"; do
  if [ -n "$c" ] && [ -x "$c" ] && "$c" -c pass >/dev/null 2>&1; then GOOD="$c"; break; fi
done
[ -n "$GOOD" ] || { echo "no working python3 on this machine -- cannot run this suite"; exit 0; }

# An interpreter that is executable but BROKEN -- the exact shape of the
# license-nag stub.
BROKEN="$TMPROOT/broken-python3"
printf '#!/bin/sh\necho "You have not agreed to the Xcode license agreements." >&2\nexit 69\n' > "$BROKEN"
chmod +x "$BROKEN"

# Run the resolver in a fresh subshell with an isolated HEIMDALL_HOME and PATH.
#   resolve HOME_DIR PATH_DIR  -> prints the resolved path (or nothing), rc
resolve() {
  local home="$1" pathdir="$2"
  # PATH = the case's python dir + the bare system dirs (mkdir/rm live there). On a
  # machine where /usr/bin/python3 itself is broken -- the incident this test is
  # about -- that broken system python is therefore ALSO a candidate the resolver
  # must reject, which is the point.
  ( export HEIMDALL_HOME="$home" PATH="$pathdir:/usr/bin:/bin" HMD_PYTHON=""; unset HMD_PYTHON
    . "$LIB" && hmd_python )
}

echo "hmd-python"

# ── 1. cached path that is executable but broken is NOT returned ─────────────
H="$TMPROOT/h1"; mkdir -p "$H"; printf '%s\n' "$BROKEN" > "$H/.python3-path"
P="$TMPROOT/p1"; mkdir -p "$P"; ln -s "$GOOD" "$P/python3"
out="$(resolve "$H" "$P")"
if [ "$out" != "$BROKEN" ] && [ -n "$out" ] && "$out" -c pass >/dev/null 2>&1; then
  ok "1. a cached but broken interpreter is skipped; a working one is returned ($out)"
else
  bad "1. cached broken interpreter was returned or nothing resolved (out=[$out])"
fi

# ── 2. ...and the stale cache is replaced, not left to poison the next run ──
if [ -r "$H/.python3-path" ] && [ "$(cat "$H/.python3-path")" != "$BROKEN" ]; then
  ok "2. stale cache entry was overwritten with the working path"
else
  bad "2. stale cache still names the broken interpreter: [$(cat "$H/.python3-path" 2>/dev/null)]"
fi

# ── 3. a cached WORKING path is honoured without re-probing PATH ─────────────
# (PATH deliberately holds only the broken one: if the cache were ignored the
# resolver could only find garbage.)
H="$TMPROOT/h3"; mkdir -p "$H"; printf '%s\n' "$GOOD" > "$H/.python3-path"
P="$TMPROOT/p3"; mkdir -p "$P"; ln -s "$BROKEN" "$P/python3"
out="$(resolve "$H" "$P")"
[ "$out" = "$GOOD" ] && ok "3. a cached working interpreter is used as-is" \
                     || bad "3. cached working interpreter not honoured (out=[$out])"

# ── 4. no cache, PATH python is broken, system/homebrew may or may not work ──
# Whatever comes back must RUN. Nothing may come back that does not.
H="$TMPROOT/h4"; mkdir -p "$H"
P="$TMPROOT/p4"; mkdir -p "$P"; ln -s "$BROKEN" "$P/python3"
out="$(resolve "$H" "$P")"
if [ -z "$out" ] || "$out" -c pass >/dev/null 2>&1; then
  ok "4. never returns an interpreter that does not run (out=[${out:-<none>}])"
else
  bad "4. returned a non-running interpreter: [$out]"
fi

# ── 5. HMD_PYTHON override is honoured verbatim (operator's explicit choice) ──
H="$TMPROOT/h5"; mkdir -p "$H"; P="$TMPROOT/p5"; mkdir -p "$P"
out="$( ( export HEIMDALL_HOME="$H" PATH="$P" HMD_PYTHON="$GOOD"; . "$LIB" && hmd_python ) )"
[ "$out" = "$GOOD" ] && ok "5. HMD_PYTHON override wins" || bad "5. HMD_PYTHON override ignored (out=[$out])"

# ── 6. the cache is written under HEIMDALL_HOME only ─────────────────────────
H="$TMPROOT/h6"; mkdir -p "$H"; P="$TMPROOT/p6"; mkdir -p "$P"; ln -s "$GOOD" "$P/python3"
resolve "$H" "$P" >/dev/null
[ -r "$H/.python3-path" ] && ok "6. cache written under the isolated HEIMDALL_HOME" \
                          || bad "6. no cache written under HEIMDALL_HOME"

# ── 7. the lib parses under bash -n ──────────────────────────────────────────
bash -n "$LIB" && ok "7. lib parses" || bad "7. lib does not parse"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
