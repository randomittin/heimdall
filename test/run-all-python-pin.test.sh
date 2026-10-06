#!/usr/bin/env bash
# test/run-all-python-pin.test.sh -- proves the python3 pin of the test harness (test/run-all.sh + test/lib/py-pin.sh).
#
# WHY: on a box where python3 resolves through a pyenv shim every call pays a bash + version-resolution tax
# (0.3-0.8 s under load against 0.05 s for the interpreter itself) and the app-relay / companion-push / controls
# suites make thousands of calls. test/lib/app-relay-common.sh pinned the real interpreter for the app-relay suites
# only; run-all.sh now does it for every suite it runs.
#
# CLAIMS (each one fails if the thing it names is removed):
#   A. run-all.sh, python3 behind a shim: the suite's `command -v python3` is not the shim but a regular file (a
#      wrapper, not a symlink); every call runs the real interpreter with stdin, exit status and argv intact; the
#      shim itself runs exactly ONCE (run-all's single resolve); the run header carries exactly one `python3 pin:`
#      line, naming the interpreter, before the first progress line; nothing is left in TMPDIR afterwards.
#   B. HMD_TEST_NO_PY_PIN=1 opts out: the suite sees the shim, every call goes through it, nothing was resolved.
#   C. python3 already is the interpreter: nothing is installed and the header says so.
#   D. an interpreter path holding spaces, quotes and a dollar sign survives the wrapper (the path is embedded in
#      the wrapper script, so it has to be quoted for sh).
#   E. test/lib/app-relay-common.sh: standalone it still pins (one resolve, wrapper first on PATH); under a pin that
#      is already in the environment (what run-all.sh leaves for its suites) it neither resolves nor wraps again.
#   F. the helper is idempotent: a second call changes nothing.
#
# The proof is a COUNT, not a stopwatch: the fake shim appends a line to a counter file every time it runs, then
# execs the real interpreter. The fixture suite calls python3 seven times: pinned the shim runs once, opted out it
# runs seven times. A wall clock would measure the load of the box; the counter measures the claim.

set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RUN_ALL="$ROOT/test/run-all.sh"
PIN_LIB="$ROOT/test/lib/py-pin.sh"
HOOK_LIB="$ROOT/bin/lib/hook-owned-path.sh"

PASS=0; FAIL=0; SKIP=0; N=0
ok()   { N=$((N + 1)); PASS=$((PASS + 1)); printf '  ok   %d. %s\n' "$N" "$1"; }
bad()  { N=$((N + 1)); FAIL=$((FAIL + 1)); printf '  FAIL %d. %s\n' "$N" "$1"; }
skip() { N=$((N + 1)); SKIP=$((SKIP + 1)); printf '  SKIP %d. %s\n' "$N" "$1"; }
lines() { wc -l < "$1" 2>/dev/null | tr -d ' '; }

echo "run-all python3 pin"

REALPY="$(python3 -c 'import sys; print(sys.executable)' 2>/dev/null)"
case "$REALPY" in /*) [ -x "$REALPY" ] || REALPY="" ;; *) REALPY="" ;; esac
if [ -z "$REALPY" ]; then
  echo "FATAL: python3 -c 'print(sys.executable)' gave no absolute executable path" >&2
  printf '\n0 passed, 1 failed\n'
  exit 1
fi

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/shimbin" "$T/directbin" "$T/tmp" "$T/hh"

# the fake shim: counts every run, then execs the real interpreter (a pyenv shim minus the tax)
cat > "$T/shimbin/python3" <<'SHIM_EOF'
#!/bin/sh
echo x >> "$SHIM_COUNT"
exec "$FIXTURE_REAL_PY" "$@"
SHIM_EOF
chmod +x "$T/shimbin/python3"
ln -s "$REALPY" "$T/directbin/python3"

# a throwaway repo holding the REAL run-all.sh, its libs and one probe suite
mkdir -p "$T/repo/test/lib" "$T/repo/bin/lib"
cp "$RUN_ALL" "$T/repo/test/run-all.sh"
cp "$HOOK_LIB" "$T/repo/bin/lib/hook-owned-path.sh"
cp "$PIN_LIB" "$T/repo/test/lib/py-pin.sh" 2>/dev/null || bad "setup: test/lib/py-pin.sh is missing"
cat > "$T/repo/test/probe.test.sh" <<'PROBE_EOF'
#!/usr/bin/env bash
cur="$(command -v python3)"
if [ -L "$cur" ]; then kind=symlink; else kind=file; fi
{ printf 'CMDV %s\n' "$cur"; printf 'KIND %s\n' "$kind"; } > "$PROBE_OUT.cmdv"
: > "$PROBE_OUT.exe"
for _ in 1 2 3 4 5; do python3 -c 'import sys; print(sys.executable)' >> "$PROBE_OUT.exe"; done
printf 'a b' | python3 -c 'import sys; sys.stdout.write(sys.stdin.read()); sys.exit(7)' > "$PROBE_OUT.stdin"
echo $? > "$PROBE_OUT.stdin.rc"
python3 -c 'import sys; print("|".join(sys.argv[1:]))' 'x y' "it's" '$HOME' > "$PROBE_OUT.args"
echo "probe: 1 passed, 0 failed."
PROBE_EOF
( cd "$T/repo" && git init -q . && git add -A \
  && git -c user.email=t@t -c user.name=t -c commit.gpgsign=false commit -qm fixture ) >/dev/null 2>&1

# no pin state may leak in from a sweep this suite itself runs under
UNSET=(-u HMD_TEST_NO_PY_PIN -u HMD_TEST_PY_PIN_DIR -u HMD_TEST_PY_PIN_REAL)

# run_fixture LABEL PATH_PREFIX [VAR=VAL ...] -- one sweep of the fixture repo; leaves $T/LABEL.{log,rc,count,...}
run_fixture() {
  local label="$1" pfx="$2"; shift 2
  : > "$T/$label.count"
  ( cd "$T/repo" && env "${UNSET[@]}" PATH="$pfx:$PATH" SHIM_COUNT="$T/$label.count" FIXTURE_REAL_PY="$REALPY" \
      PROBE_OUT="$T/$label" HEIMDALL_HOME="$T/hh" TMPDIR="$T/tmp" "$@" \
      bash test/run-all.sh --min 1 --jobs 1 --no-retry ) > "$T/$label.log" 2>&1
  echo $? > "$T/$label.rc"
}
cmdv() { sed -n 's/^CMDV //p' "$T/$1.cmdv"; }
kind() { sed -n 's/^KIND //p' "$T/$1.cmdv"; }
green() { [ "$(cat "$T/$1.rc" 2>/dev/null)" = 0 ] && grep -q 'RUN GREEN' "$T/$1.log"; }
pin_lines() { grep -c '^python3 pin: ' "$T/$1.log"; }

# ── A. pinned ────────────────────────────────────────────────────────────
echo "-- A. python3 behind a shim: pinned for the suites run-all.sh runs"
run_fixture pinned "$T/shimbin"
if green pinned; then
  ok "A1 the fixture sweep is green"
else
  bad "A1 the fixture sweep is green"
  sed -n '1,14p' "$T/pinned.log"
fi
want="python3 pin: pinned -> $REALPY (python3 resolved via $T/shimbin/python3)"
if [ "$(pin_lines pinned)" = 1 ] && grep -Fxq -- "$want" "$T/pinned.log"; then
  ok "A2 the header carries exactly one pin line naming the interpreter and the shim it replaced"
else
  bad "A2 header pin line (want exactly: $want) -- got: $(grep '^python3 pin: ' "$T/pinned.log" | tr '\n' '~')"
fi
hl="$(grep -n '^python3 pin: ' "$T/pinned.log" | head -1 | cut -d: -f1)"
pl="$(grep -n '^progress ' "$T/pinned.log" | head -1 | cut -d: -f1)"
if [ -n "$hl" ] && [ -n "$pl" ] && [ "$hl" -lt "$pl" ]; then ok "A3 the pin line comes before the first progress line (it is part of the header)"
else bad "A3 pin line (line '${hl:-none}') must precede the first progress line (line '${pl:-none}')"; fi
if [ -n "$(cmdv pinned)" ] && [ "$(cmdv pinned)" != "$T/shimbin/python3" ] && [ "$(kind pinned)" = file ]; then
  ok "A4 the suite's python3 is a regular-file wrapper, not the shim and not a symlink"
else bad "A4 suite python3 = '$(cmdv pinned)' kind '$(kind pinned)' (shim is $T/shimbin/python3)"; fi
if [ "$(lines "$T/pinned.count")" = 1 ]; then ok "A5 the shim ran exactly once (run-all's own resolve) for 7 suite calls"
else bad "A5 shim ran $(lines "$T/pinned.count") times, want 1"; fi
if [ "$(lines "$T/pinned.exe")" = 5 ] && [ "$(sort -u "$T/pinned.exe")" = "$REALPY" ]; then ok "A6 every call ran the real interpreter"
else bad "A6 sys.executable lines: $(tr '\n' '~' < "$T/pinned.exe")"; fi
if [ "$(cat "$T/pinned.stdin" 2>/dev/null)" = 'a b' ] && [ "$(cat "$T/pinned.stdin.rc" 2>/dev/null)" = 7 ] \
   && [ "$(cat "$T/pinned.args" 2>/dev/null)" = "x y|it's|\$HOME" ]; then ok "A7 stdin, exit status and argv pass through the wrapper untouched"
else bad "A7 passthrough: stdin='$(cat "$T/pinned.stdin" 2>/dev/null)' rc='$(cat "$T/pinned.stdin.rc" 2>/dev/null)' args='$(cat "$T/pinned.args" 2>/dev/null)'"; fi
if [ -z "$(ls -A "$T/tmp")" ]; then ok "A8 the wrapper dir is gone when the run ends (nothing left in TMPDIR)"
else bad "A8 left in TMPDIR: $(find "$T/tmp" -mindepth 1 -maxdepth 1 -exec basename {} \; | tr '\n' ' ')"; fi

# ── B. opt-out ───────────────────────────────────────────────────────────
echo "-- B. HMD_TEST_NO_PY_PIN=1 opts out"
run_fixture optout "$T/shimbin" HMD_TEST_NO_PY_PIN=1
if green optout; then
  ok "B1 the opted-out sweep is green"
else
  bad "B1 the opted-out sweep is green"
fi
if grep -Fxq 'python3 pin: off (HMD_TEST_NO_PY_PIN=1)' "$T/optout.log" && [ "$(pin_lines optout)" = 1 ]; then
  ok "B2 the header says the pin is off, and why"
else
  bad "B2 header: $(grep '^python3 pin: ' "$T/optout.log" | tr '\n' '~')"
fi
if [ "$(cmdv optout)" = "$T/shimbin/python3" ]; then
  ok "B3 the suite still sees the shim"
else
  bad "B3 suite python3 = '$(cmdv optout)'"
fi
if [ "$(lines "$T/optout.count")" = 7 ]; then
  ok "B4 all 7 calls went through the shim, nothing was resolved up front"
else
  bad "B4 shim ran $(lines "$T/optout.count") times, want 7"
fi

# ── C. already direct ────────────────────────────────────────────────────
echo "-- C. python3 already is the interpreter"
run_fixture direct "$T/directbin"
if green direct; then
  ok "C1 the sweep is green"
else
  bad "C1 the sweep is green"
fi
if grep -q '^python3 pin: not needed' "$T/direct.log" && [ "$(pin_lines direct)" = 1 ]; then
  ok "C2 the header says no pin was needed"
else
  bad "C2 header: $(grep '^python3 pin: ' "$T/direct.log" | tr '\n' '~')"
fi
if [ "$(cmdv direct)" = "$T/directbin/python3" ]; then
  ok "C3 no wrapper was installed: the suite sees the original python3"
else
  bad "C3 suite python3 = '$(cmdv direct)'"
fi

# ── D. an interpreter path that needs quoting ────────────────────────────
echo "-- D. an interpreter path with spaces, quotes and a dollar sign"
WEIRD="$T/we ird \"dq\" \$x 'sq'"
mkdir -p "$WEIRD" "$T/fakeshim"
cat > "$WEIRD/py" <<'W_EOF'
#!/bin/sh
if [ "$1" = -c ]; then printf '%s\n' "$FAKE_SELF"; else printf 'FAKE-PY'; for a in "$@"; do printf '[%s]' "$a"; done; echo; fi
W_EOF
chmod +x "$WEIRD/py"
cat > "$T/fakeshim/python3" <<'FS_EOF'
#!/bin/sh
exec "$FAKE_SELF" "$@"
FS_EOF
chmod +x "$T/fakeshim/python3"
cat > "$T/d.sh" <<'D_EOF'
. "$1"
hmd_test_pin_python3 "$2"
python3 'a b' "it's"
D_EOF
got="$(env "${UNSET[@]}" FAKE_SELF="$WEIRD/py" PATH="$T/fakeshim:$PATH" bash "$T/d.sh" "$PIN_LIB" "$T/wd" 2>&1)"
if [ "$got" = "FAKE-PY[a b][it's]" ]; then
  ok "D1 the wrapper execs the awkward path with its arguments intact"
else
  bad "D1 got: $got"
fi

# ── E. app-relay-common.sh ───────────────────────────────────────────────
echo "-- E. test/lib/app-relay-common.sh"
cat > "$T/e.sh" <<'E_EOF'
RELAY_SUITE_TITLE=probe
. "$1/test/lib/app-relay-common.sh"
printf 'CMDV %s\n' "$(command -v python3)"
E_EOF
cat > "$T/e2.sh" <<'E2_EOF'
. "$1"
hmd_test_pin_python3 "$2"
bash "$3" "$4"
E2_EOF
if command -v curl >/dev/null 2>&1; then
  : > "$T/e1.count"
  env "${UNSET[@]}" PATH="$T/shimbin:$PATH" SHIM_COUNT="$T/e1.count" FIXTURE_REAL_PY="$REALPY" bash "$T/e.sh" "$ROOT" > "$T/e1.out" 2>&1
  e1="$(sed -n 's/^CMDV //p' "$T/e1.out")"
  if [ -n "$e1" ] && [ "$e1" != "$T/shimbin/python3" ] && [ "$(lines "$T/e1.count")" = 1 ]; then
    ok "E1 standalone it still pins: wrapper first on PATH after one resolve"
  else bad "E1 standalone: python3 = '$e1', shim ran $(lines "$T/e1.count") times (want a wrapper and 1)"; fi
  : > "$T/e2.count"
  env "${UNSET[@]}" PATH="$T/shimbin:$PATH" SHIM_COUNT="$T/e2.count" FIXTURE_REAL_PY="$REALPY" \
    bash "$T/e2.sh" "$PIN_LIB" "$T/pre" "$T/e.sh" "$ROOT" > "$T/e2.out" 2>&1
  e2="$(sed -n 's/^CMDV //p' "$T/e2.out")"
  if [ "$e2" = "$T/pre/python3" ] && [ "$(lines "$T/e2.count")" = 1 ] && [ ! -e "$T/pre/../pybin" ]; then
    ok "E2 under an existing pin it keeps it: no second wrapper, no second resolve"
  else bad "E2 pre-pinned: python3 = '$e2' (want $T/pre/python3), shim ran $(lines "$T/e2.count") times (want 1)"; fi
else
  skip "E1 app-relay-common.sh standalone (curl is absent, so the relay suites cannot run here either)"
  skip "E2 app-relay-common.sh under an existing pin (curl is absent)"
fi

# ── F. idempotent ────────────────────────────────────────────────────────
echo "-- F. a second call is a no-op"
cat > "$T/f.sh" <<'F_EOF'
. "$1"
hmd_test_pin_python3 "$2"
p1="$PATH"
hmd_test_pin_python3 "$3"
if [ "$PATH" = "$p1" ] && [ ! -e "$3" ]; then echo SAME; fi
printf 'NOTE %s\n' "$HMD_PY_PIN_NOTE"
F_EOF
: > "$T/f.count"
env "${UNSET[@]}" PATH="$T/shimbin:$PATH" SHIM_COUNT="$T/f.count" FIXTURE_REAL_PY="$REALPY" bash "$T/f.sh" "$PIN_LIB" "$T/f1" "$T/f2" > "$T/f.out" 2>&1
if grep -qx SAME "$T/f.out" && grep -q '^NOTE inherited' "$T/f.out" && [ "$(lines "$T/f.count")" = 1 ]; then
  ok "F1 the second call leaves PATH alone, creates nothing and resolves nothing"
else
  bad "F1 idempotence: $(tr '\n' '~' < "$T/f.out"), shim ran $(lines "$T/f.count") times"
fi

echo
printf '%d passed, %d failed, %d skipped\n' "$PASS" "$FAIL" "$SKIP"
[ "$FAIL" -eq 0 ]
