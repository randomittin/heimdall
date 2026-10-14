#!/usr/bin/env bash
# disk-floor.test.sh -- proves the disk-space floor (2.4.8, operator directive 2026-10-14: "a disk-space floor of 10%, enforced by hooks: agent spawns, test
# runs, each test file"). The machine this was written on was at 7.1% free (16.4 GB of 228 GB) while agents ran suites.
#
#   1. THE SHARED CHECK (bin/lib/hmd_disk_floor.sh): free percent = available / size of the volume holding a path (df -Pk; NOT df's Capacity column, which on
#      APFS leaves out every other volume of the container); floor 10 by default, HMD_MIN_FREE_PCT overrides it (0 = off, junk = the default, said out loud);
#      the message names free GB, free %, the floor and the override; one line per volume; a df that cannot answer warns and ALLOWS (a resource guard, not a gate).
#   2. bin/heimdall-disk-floor check: the same, for a human.
#   3. THE AGENT FENCE (bin/heimdall-precheck-agent): a spawn under the floor is DENIED, before any in-process lease is staked.
#   4. THE BASH FENCE (bin/heimdall-precheck-bash): a command that RUNS a *.test.sh or test/run-all.sh is DENIED under the floor; a command that only MENTIONS one
#      (cat, grep, bash -n, git add, echo) never reaches df.
#   5. THE SWEEP (test/run-all.sh + test/lib/run-all-guards.sh): the preflight also refuses on the percent floor (whichever of it and the GB floor is stricter;
#      exit 5, nothing left behind), and between suites it re-checks and stops launching: REFUSED suites, a red receipt, exit 1.
#
# Every free-space figure comes from a fake `df` first on PATH, so nothing here depends on the disk this suite runs on. bash 3.2 compatible.
#
# Usage:  bash test/disk-floor.test.sh
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SELF_DIR/.." && pwd)"
LIBSH="$REPO/bin/lib/hmd_disk_floor.sh"
CLI="$REPO/bin/heimdall-disk-floor"
AGENT_HOOK="$REPO/bin/heimdall-precheck-agent"
BASH_HOOK="$REPO/bin/heimdall-precheck-bash"
GUARDS="$REPO/test/lib/run-all-guards.sh"
RUNALL="$REPO/test/run-all.sh"
BASH_ABS="$(command -v bash)"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; }

# nothing of the caller's settings may leak into a case (the operator runs this machine with HMD_MIN_FREE_PCT=7 right now)
unset HMD_MIN_FREE_PCT HMD_TEST_MIN_FREE_GB HMD_DISK_FLOOR_QUIET HEIMDALL_INPROC_AGENT_MAX HEIMDALL_INPROC_AGENT_TTL

T="$(mktemp -d "${TMPDIR:-/tmp}/disk-floor.XXXXXX")" || exit 1; T="$(cd "$T" && pwd -P)"
# ERT is the TMPDIR the fixture sweeps run under, and it has to be SHORT (run-all.sh refuses to start, exit 6, when its per-suite temp dir leaves a unix socket
# path no room); a private dir directly under /tmp, whatever TMPDIR is, removed by the trap below.
ERT="$(mktemp -d /tmp/dfl.XXXXXX 2>/dev/null || mktemp -d "${TMPDIR:-/tmp}/dfl.XXXXXX")" || exit 1; ERT="$(cd "$ERT" && pwd -P)"
cleanup() { chmod -R u+rwX "$T" "$ERT" 2>/dev/null; rm -rf "$T" "$ERT"; }
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

echo "disk-floor (HMD_MIN_FREE_PCT: the shared check, its CLI, the agent fence, the Bash fence, the sweep)"

# ── the fake df ────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
mkdir -p "$T/dfshim" "$T/rt" "$T/vol/a" "$T/vol/b" "$T/acwd" "$T/othercwd" "$T/atmp" "$T/btmp" "$T/bcwd" "$T/clidir" "$T/ahome" "$T/marks"
cat > "$T/dfshim/df" <<'DFEOF'
#!/bin/sh
# Fake `df -Pk PATH` (the last argument is the path).
#   free KB: $SHIM_DF_LOW_KB when the path is $SHIM_DF_LOW_PATH; else the first line of $SHIM_DF_FREE_FILE when that file exists (a fixture suite lowers it
#            mid-sweep); else $SHIM_DF_FREE_KB (default 50 GB)
#   size KB: $SHIM_DF_SIZE_KB (default 100 GB)
#   mount:   $SHIM_DF_MOUNT, else a name made from the path (so two paths are two volumes unless a case says otherwise)
#   SHIM_DF_FAIL=1: df fails.  SHIM_DF_GARBAGE=1: a row whose numeric columns are not numbers.
[ "${SHIM_DF_FAIL:-0}" = 1 ] && exit 1
last=""; for a in "$@"; do last="$a"; done
free="${SHIM_DF_FREE_KB:-52428800}"
if [ -n "${SHIM_DF_FREE_FILE:-}" ] && [ -r "$SHIM_DF_FREE_FILE" ]; then free="$(cat "$SHIM_DF_FREE_FILE")"; fi
[ "$last" = "${SHIM_DF_LOW_PATH:-}" ] && free="${SHIM_DF_LOW_KB:-1048576}"
mnt="${SHIM_DF_MOUNT:-/fake$(printf '%s' "$last" | tr -c 'A-Za-z0-9' _)}"
if [ "${SHIM_DF_GARBAGE:-0}" = 1 ]; then
  printf 'Filesystem 1024-blocks Used Available Capacity Mounted on\n/dev/fake n/a n/a n/a n/a %s\n' "$mnt"; exit 0
fi
printf 'Filesystem 1024-blocks Used Available Capacity Mounted on\n/dev/fake %s 1 %s 1%% %s\n' "${SHIM_DF_SIZE_KB:-104857600}" "$free" "$mnt"
DFEOF
chmod +x "$T/dfshim/df"
# the figures, in the 1024-byte blocks df -Pk prints
OP_SZ=239362496; OP_FREE=17203896     # this machine on 2026-10-14: 16.4 GB of 228.3 GB = 7.1% free -- under the default floor, over the 7 the operator runs
G100=104857600; G50=52428800; G8=8388608; G4=4194304; G20=20971520

# ── helpers: every runner writes $T/<name>.{out,err,rc} ────────────────────────────────────────────────────────────────────────────
RC() { cat "$T/$1.rc" 2>/dev/null; }
go() { grep -qF -- "$2" "$T/$1.out" 2>/dev/null; }      # stdout of run $1 contains $2
ge() { grep -qF -- "$2" "$T/$1.err" 2>/dev/null; }      # stderr of run $1 contains $2
eo() { [ -f "$T/$1.out" ] && [ ! -s "$T/$1.out" ]; }    # stdout empty
ee() { [ -f "$T/$1.err" ] && [ ! -s "$T/$1.err" ]; }    # stderr empty
show() { printf 'rc=%s out=[%s] err=[%s]' "$(RC "$1")" "$(head -c 400 "$T/$1.out" 2>/dev/null)" "$(head -c 400 "$T/$1.err" 2>/dev/null)"; }

# libcall [K=V ...] -- FUNC [ARGS...]: the shared lib sourced under `set -u` (so an unset-variable slip is a failure) with the fake df first on PATH and ONLY the given settings
libcall() {
  local -a e=(); while [ $# -gt 0 ] && [ "$1" != -- ]; do e[${#e[@]}]="$1"; shift; done; shift
  env -u HMD_MIN_FREE_PCT -u HMD_DISK_FLOOR_QUIET PATH="$T/dfshim:$PATH" ${e[@]+"${e[@]}"} \
    "$BASH_ABS" -c 'set -u; . "$1"; shift; "$@"' _ "$LIBSH" "$@" >"$T/l.out" 2>"$T/l.err"
  echo $? > "$T/l.rc"
}

echo "-- 0. the files exist and parse --"
if [ -f "$LIBSH" ] && bash -n "$LIBSH" 2>/dev/null; then ok "bin/lib/hmd_disk_floor.sh exists and parses"; else bad "bin/lib/hmd_disk_floor.sh is missing or does not parse"; fi
if [ -x "$CLI" ] && bash -n "$CLI" 2>/dev/null; then ok "bin/heimdall-disk-floor exists, is executable and parses"; else bad "bin/heimdall-disk-floor is missing, not executable, or does not parse"; fi

echo "-- 1. the shared check (bin/lib/hmd_disk_floor.sh) --"
libcall -- hmd_disk_floor_pct
if [ "$(RC l)" = 0 ] && [ "$(cat "$T/l.out")" = 10 ] && ee l; then ok "the floor is 10 percent by default"; else bad "default floor: $(show l)"; fi
libcall HMD_MIN_FREE_PCT=7 -- hmd_disk_floor_pct
if [ "$(cat "$T/l.out")" = 7 ] && ee l; then ok "HMD_MIN_FREE_PCT=7 (what the operator runs now) is the floor"; else bad "override 7: $(show l)"; fi
libcall HMD_MIN_FREE_PCT=0 -- hmd_disk_floor_pct
if [ "$(cat "$T/l.out")" = 0 ] && ee l; then ok "HMD_MIN_FREE_PCT=0 is the floor (off)"; else bad "override 0: $(show l)"; fi
libcall HMD_MIN_FREE_PCT=07 -- hmd_disk_floor_pct
if [ "$(cat "$T/l.out")" = 7 ] && ee l; then ok "a leading zero is decimal (07 is 7, not an octal error)"; else bad "override 07: $(show l)"; fi
libcall HMD_MIN_FREE_PCT= -- hmd_disk_floor_pct
if [ "$(cat "$T/l.out")" = 10 ] && ee l; then ok "an EMPTY override is unset: 10, no warning"; else bad "empty override: $(show l)"; fi
JUNK_BAD=""
for junk in abc '7%' 101 -1 1.5 ' 7' 0x7 9999999999999999999; do
  libcall "HMD_MIN_FREE_PCT=$junk" -- hmd_disk_floor_pct
  { [ "$(cat "$T/l.out")" = 10 ] && ge l "HMD_MIN_FREE_PCT=$junk" && ge l 'using the default, 10'; } || JUNK_BAD="$JUNK_BAD [$junk: $(show l)]"
done
if [ -z "$JUNK_BAD" ]; then ok "a typo in the override (abc, 7%, 101, -1, 1.5, ' 7', 0x7, a huge number) falls back to 10 and SAYS so -- it can never silently remove the floor"; else bad "junk override:$JUNK_BAD"; fi
libcall HMD_MIN_FREE_PCT=abc HMD_DISK_FLOOR_QUIET=1 -- hmd_disk_floor_pct
if [ "$(cat "$T/l.out")" = 10 ] && ee l; then ok "HMD_DISK_FLOOR_QUIET=1 keeps the junk-override warning off stderr (the value is still 10)"; else bad "quiet junk: $(show l)"; fi

P="$T/vol/a"; Q="$T/vol/b"
libcall SHIM_DF_SIZE_KB=1000000 SHIM_DF_FREE_KB=100000 -- hmd_disk_floor_check "$P"
if [ "$(RC l)" = 0 ] && eo l && ee l; then ok "exactly 10.0% free is AT the floor: allowed, silent"; else bad "exactly at the floor: $(show l)"; fi
libcall SHIM_DF_SIZE_KB=1000000 SHIM_DF_FREE_KB=99999 -- hmd_disk_floor_check "$P"
if [ "$(RC l)" = 1 ] && go l '(9.9%)'; then ok "one block under 10% is below it, and the percent is shown truncated (9.9%), never rounded up to the floor it is under"; else bad "just under the floor: $(show l)"; fi
libcall SHIM_DF_SIZE_KB=1000000 SHIM_DF_FREE_KB=100001 -- hmd_disk_floor_check "$P"
if [ "$(RC l)" = 0 ] && eo l; then ok "one block over 10%: allowed"; else bad "just over the floor: $(show l)"; fi
libcall SHIM_DF_SIZE_KB=$OP_SZ SHIM_DF_FREE_KB=$OP_FREE -- hmd_disk_floor_check "$P"
if [ "$(RC l)" = 1 ] && go l "only 16.4 GB (7.1%) free on the volume holding $P (mounted on /fake" && go l 'the floor is 10% free (HMD_MIN_FREE_PCT' && go l '0 turns it off' && [ "$(wc -l < "$T/l.out" | tr -d ' ')" = 1 ] && ee l; then ok "this machine's own disk (16.4 GB of 228.3 GB): below the 10% default; ONE line naming free GB, free %, the volume, the floor and the override"; else bad "operator disk: $(show l)"; fi
libcall SHIM_DF_SIZE_KB=$OP_SZ SHIM_DF_FREE_KB=$OP_FREE HMD_MIN_FREE_PCT=7 -- hmd_disk_floor_check "$P"
if [ "$(RC l)" = 0 ] && eo l && ee l; then ok "the same disk at HMD_MIN_FREE_PCT=7: allowed (7.1% is over 7)"; else bad "operator disk at 7: $(show l)"; fi
libcall SHIM_DF_SIZE_KB=$OP_SZ SHIM_DF_FREE_KB=$OP_FREE HMD_MIN_FREE_PCT=8 -- hmd_disk_floor_check "$P"
if [ "$(RC l)" = 1 ] && go l 'the floor is 8% free'; then ok "the same disk at HMD_MIN_FREE_PCT=8: below, and the line states the floor that applied (8%)"; else bad "operator disk at 8: $(show l)"; fi
libcall SHIM_DF_FREE_KB=0 SHIM_DF_FAIL=1 HMD_MIN_FREE_PCT=0 -- hmd_disk_floor_check "$P"
if [ "$(RC l)" = 0 ] && eo l && ee l; then ok "HMD_MIN_FREE_PCT=0 turns the floor off before df is even asked (a failing df says nothing)"; else bad "floor off: $(show l)"; fi
libcall SHIM_DF_FAIL=1 -- hmd_disk_floor_check "$P"
if [ "$(RC l)" = 0 ] && eo l && ge l "could not read the free space of the volume holding $P" && ge l 'allowing'; then ok "a df that fails: warns on stderr and ALLOWS (a resource guard fails open)"; else bad "df fails: $(show l)"; fi
libcall SHIM_DF_GARBAGE=1 -- hmd_disk_floor_check "$P"
if [ "$(RC l)" = 0 ] && eo l && ge l 'could not read the free space'; then ok "a df row with no numbers: warns and allows"; else bad "df garbage: $(show l)"; fi
libcall SHIM_DF_SIZE_KB=0 -- hmd_disk_floor_check "$P"
if [ "$(RC l)" = 0 ] && eo l && ge l 'could not read the free space'; then ok "a volume of size 0 (no percent to compute): warns and allows"; else bad "df size 0: $(show l)"; fi
libcall SHIM_DF_FAIL=1 HMD_DISK_FLOOR_QUIET=1 -- hmd_disk_floor_check "$P"
if [ "$(RC l)" = 0 ] && eo l && ee l; then ok "HMD_DISK_FLOOR_QUIET=1: the unreadable-df warning is off too"; else bad "df fails, quiet: $(show l)"; fi
mkdir -p "$T/nodf"; ln -s "$(command -v awk)" "$T/nodf/awk"
env -i PATH="$T/nodf" "$BASH_ABS" -c 'set -u; . "$1"; hmd_disk_floor_check "$2"' _ "$LIBSH" "$P" >"$T/l.out" 2>"$T/l.err"; echo $? > "$T/l.rc"
if [ "$(RC l)" = 0 ] && eo l && ge l 'could not read the free space'; then ok "no df on PATH at all: warns and allows"; else bad "no df: $(show l)"; fi
libcall SHIM_DF_FREE_KB=1000 SHIM_DF_MOUNT=/vol -- hmd_disk_floor_check "$P" "$Q"
if [ "$(RC l)" = 1 ] && [ "$(wc -l < "$T/l.out" | tr -d ' ')" = 1 ] && go l "the volume holding $P and $Q (mounted on /vol)"; then ok "two paths on ONE volume are one line naming both"; else bad "same volume: $(show l)"; fi
libcall SHIM_DF_FREE_KB=1000 -- hmd_disk_floor_check "$P" "$Q"
if [ "$(RC l)" = 1 ] && [ "$(wc -l < "$T/l.out" | tr -d ' ')" = 2 ] && go l "holding $P (" && go l "holding $Q ("; then ok "two paths on two volumes, both short: one line each"; else bad "two volumes: $(show l)"; fi
libcall SHIM_DF_LOW_PATH="$P" SHIM_DF_LOW_KB=1000 -- hmd_disk_floor_check "$P" "$Q"
if [ "$(RC l)" = 1 ] && [ "$(wc -l < "$T/l.out" | tr -d ' ')" = 1 ] && go l "holding $P (" && ! go l "$Q"; then ok "only the volume that is short is named"; else bad "one short volume: $(show l)"; fi
libcall SHIM_DF_FREE_KB=1000 'SHIM_DF_MOUNT=/Volumes/My Disk' -- hmd_disk_floor_check "$P"
if [ "$(RC l)" = 1 ] && go l '(mounted on /Volumes/My Disk)'; then ok "a mount point with a space in it is shown whole"; else bad "mount with space: $(show l)"; fi
libcall SHIM_DF_FREE_KB=1000 -- hmd_disk_floor_check "" "$P"
if [ "$(RC l)" = 1 ] && [ "$(wc -l < "$T/l.out" | tr -d ' ')" = 1 ] && go l "holding $P ("; then ok "an empty path argument is skipped (an unset TMPDIR must not turn into a bogus df call)"; else bad "empty arg: $(show l)"; fi

echo "-- 2. bin/heimdall-disk-floor check --"
# cli [K=V ...] -- ARGS: the CLI run from a private cwd under the fake df with ONLY the given settings; out/err/rc in $T/c.*
cli() {
  local -a e=(); while [ $# -gt 0 ] && [ "$1" != -- ]; do e[${#e[@]}]="$1"; shift; done; shift
  ( cd "$T/clidir" && env -u HMD_MIN_FREE_PCT -u HMD_DISK_FLOOR_QUIET PATH="$T/dfshim:$PATH" ${e[@]+"${e[@]}"} "$BASH_ABS" "$CLI" "$@" ) >"$T/c.out" 2>"$T/c.err"
  echo $? > "$T/c.rc"
}
cli -- check --path "$P"
if [ "$(RC c)" = 0 ] && go c 'ok: 50.0 GB (50.0%) free' && go c "the volume holding $P" && go c 'the floor is 10% free'; then ok "check --path P: exit 0 and an 'ok:' line with what is free and the floor"; else bad "cli ok: $(show c)"; fi
cli SHIM_DF_SIZE_KB=$OP_SZ SHIM_DF_FREE_KB=$OP_FREE -- check --path "$P"
if [ "$(RC c)" = 1 ] && go c 'BELOW: only 16.4 GB (7.1%) free' && go c 'HMD_MIN_FREE_PCT'; then ok "below the floor: exit 1 and a 'BELOW:' line naming the override"; else bad "cli below: $(show c)"; fi
cli SHIM_DF_SIZE_KB=$OP_SZ SHIM_DF_FREE_KB=$OP_FREE HMD_MIN_FREE_PCT=7 -- check --path "$P"
if [ "$(RC c)" = 0 ] && go c 'ok: 16.4 GB (7.1%) free' && go c 'the floor is 7% free'; then ok "HMD_MIN_FREE_PCT=7: exit 0, and the line says the floor is 7%"; else bad "cli override: $(show c)"; fi
cli SHIM_DF_LOW_PATH="$T/rt" SHIM_DF_LOW_KB=1048576 TMPDIR="$T/rt" -- check
if [ "$(RC c)" = 1 ] && go c "BELOW: only 1.0 GB (1.0%) free on the volume holding $T/rt" && go c "ok: 50.0 GB (50.0%) free on the volume holding $T/clidir"; then ok "no --path: TMPDIR and the current directory are checked (TMPDIR short -> exit 1, the cwd's volume still reported ok)"; else bad "cli default paths: $(show c)"; fi
cli -- check --path "$P" --path "$Q"
if [ "$(RC c)" = 0 ] && [ "$(grep -c '^ok:' "$T/c.out")" = 2 ]; then ok "several --path: one line each"; else bad "cli two paths: $(show c)"; fi
cli SHIM_DF_FAIL=1 -- check --path "$P"
if [ "$(RC c)" = 0 ] && ge c 'could not read the free space'; then ok "a df that fails: exit 0 with the warning (fails open, like the hooks)"; else bad "cli df fails: $(show c)"; fi
cli HMD_MIN_FREE_PCT=0 SHIM_DF_FREE_KB=0 -- check --path "$P"
if [ "$(RC c)" = 0 ] && go c 'floor off'; then ok "HMD_MIN_FREE_PCT=0: 'floor off', exit 0"; else bad "cli floor off: $(show c)"; fi
cli -- -h
if [ "$(RC c)" = 0 ] && go c 'heimdall-disk-floor' && go c 'HMD_MIN_FREE_PCT'; then ok "-h prints the usage and exits 0"; else bad "cli -h: $(show c)"; fi
cli -- ; R1="$(RC c)"; cli -- bogus; R2="$(RC c)"; cli -- check --bogus; R3="$(RC c)"; cli -- check --path; R4="$(RC c)"
if [ "$R1" = 2 ] && [ "$R2" = 2 ] && [ "$R3" = 2 ] && [ "$R4" = 2 ] && ge c 'usage'; then ok "no subcommand, an unknown subcommand, an unknown option and a --path with no value are all exit 2 (usage on stderr)"; else bad "cli usage errors: rc=$R1/$R2/$R3/$R4 $(show c)"; fi

echo "-- 3. the agent fence (bin/heimdall-precheck-agent): a spawn under the floor is denied --"
# afire HOOK [K=V ...]: the hook run from $T/othercwd with an Agent payload whose cwd is $T/acwd; env -i, so nothing of the caller's environment leaks in
# (no ANTHROPIC_BASE_URL, no HMD_MIN_FREE_PCT); the context gate is pinned off like test/agent-name-gate.test.sh does -- it reads this machine's ambient state
afire() {
  local hook="$1"; shift
  ( cd "$T/othercwd" && jq -nc --arg cwd "$T/acwd" '{tool_name:"Agent", cwd:$cwd, tool_input:{subagent_type:"hmd:coder", description:"t", prompt:"do the thing"}}' \
      | env -i HOME="$T/ahome" HEIMDALL_HOME="$T/ahome/.heimdall" TMPDIR="$T/atmp" PATH="$T/dfshim:$PATH" HMD_CTX_GATE_OFF=1 "$@" "$BASH_ABS" "$hook" ) >"$T/a.out" 2>"$T/a.err"
  echo $? > "$T/a.rc"
}
afire "$AGENT_HOOK"
if [ "$(RC a)" = 0 ] && eo a && ! ge a 'disk floor'; then ok "50 GB of 100 GB free: the spawn passes, no output"; else bad "agent plenty: $(show a)"; fi
afire "$AGENT_HOOK" SHIM_DF_SIZE_KB=$OP_SZ SHIM_DF_FREE_KB=$OP_FREE
AERR="$(jq -r '.error // empty' "$T/a.out" 2>/dev/null)"
if [ "$(RC a)" = 2 ] && [ -n "$AERR" ] && printf '%s' "$AERR" | grep -q 'disk floor' && printf '%s' "$AERR" | grep -q 'spawn REFUSED' && printf '%s' "$AERR" | grep -q '16.4 GB' && printf '%s' "$AERR" | grep -q '7.1%' && printf '%s' "$AERR" | grep -q '10% free' && printf '%s' "$AERR" | grep -q 'HMD_MIN_FREE_PCT'; then ok "this machine's disk (7.1% free, 16.4 GB) at the default floor: the spawn is DENIED (exit 2), stdout is JSON {error} naming free GB, free %, the floor and the override"; else bad "agent below: $(show a)"; fi
if ge a 'spawn REFUSED' && ge a 'HMD_MIN_FREE_PCT'; then ok "the deny is repeated on stderr (Claude Code shows only stderr for an exit-2 hook)"; else bad "agent below, stderr: $(show a)"; fi
if printf '%s' "$AERR" | grep -q 'heimdall-disk-floor'; then ok "the deny points at bin/heimdall-disk-floor check"; else bad "agent deny names no CLI: $AERR"; fi
afire "$AGENT_HOOK" SHIM_DF_SIZE_KB=$OP_SZ SHIM_DF_FREE_KB=$OP_FREE HMD_MIN_FREE_PCT=7
if [ "$(RC a)" = 0 ] && eo a && ! ge a 'disk floor'; then ok "the same disk with HMD_MIN_FREE_PCT=7 in the hook's environment: allowed"; else bad "agent override 7: $(show a)"; fi
afire "$AGENT_HOOK" SHIM_DF_FREE_KB=0 HMD_MIN_FREE_PCT=0
if [ "$(RC a)" = 0 ] && eo a; then ok "HMD_MIN_FREE_PCT=0: allowed even at 0 KB free"; else bad "agent floor off: $(show a)"; fi
afire "$AGENT_HOOK" SHIM_DF_FAIL=1
if [ "$(RC a)" = 0 ] && eo a && ge a 'could not read the free space'; then ok "a df that fails: the spawn is allowed, with the warning on stderr (fails open)"; else bad "agent df fails: $(show a)"; fi
afire "$AGENT_HOOK" SHIM_DF_LOW_PATH="$T/acwd" SHIM_DF_LOW_KB=$G4
if [ "$(RC a)" = 2 ] && ge a "holding $T/acwd (" && ! ge a "holding $T/atmp ("; then ok "the cwd in the PAYLOAD is the repo that is checked (not the hook's own cwd); only the short volume is named"; else bad "agent cwd volume: $(show a)"; fi
afire "$AGENT_HOOK" SHIM_DF_LOW_PATH="$T/atmp" SHIM_DF_LOW_KB=$G4
if [ "$(RC a)" = 2 ] && ge a "holding $T/atmp (" && ! ge a "holding $T/acwd ("; then ok "TMPDIR's volume is checked too"; else bad "agent TMPDIR volume: $(show a)"; fi
afire "$AGENT_HOOK" SHIM_DF_FREE_KB=$G4 SHIM_DF_MOUNT=/onevol
if [ "$(RC a)" = 2 ] && [ "$(jq -r '.error' "$T/a.out" | grep -o 'only 4.0 GB' | wc -l | tr -d ' ')" = 1 ]; then ok "TMPDIR and the repo on one volume: one clause in the deny, not two"; else bad "agent one volume: $(show a)"; fi
# the fence comes BEFORE the in-process concurrency cap: a refused spawn must not stake a lease
rm -rf "$T/ahome/.heimdall"
afire "$AGENT_HOOK" HEIMDALL_INPROC_AGENT_MAX=5 SHIM_DF_SIZE_KB=$OP_SZ SHIM_DF_FREE_KB=$OP_FREE
LEASES_DENIED="$(ls -1 "$T/ahome/.heimdall/inproc-agent-leases" 2>/dev/null | wc -l | tr -d ' ')"
rm -rf "$T/ahome/.heimdall"
afire "$AGENT_HOOK" HEIMDALL_INPROC_AGENT_MAX=5
LEASES_ALLOWED="$(ls -1 "$T/ahome/.heimdall/inproc-agent-leases" 2>/dev/null | wc -l | tr -d ' ')"
if [ "$LEASES_DENIED" = 0 ] && [ "$LEASES_ALLOWED" = 1 ]; then ok "a spawn refused for disk stakes no in-process lease (0), while an allowed one does (1) -- the cap path is live, so the 0 is not vacuous"; else bad "lease staking: denied=$LEASES_DENIED allowed=$LEASES_ALLOWED"; fi
# a sandbox copy of the hook with no lib next to it (a throwaway plugin root): the fence is a silent no-op, never an error
mkdir -p "$T/agent-nolib/bin"; cp "$AGENT_HOOK" "$T/agent-nolib/bin/heimdall-precheck-agent"
afire "$T/agent-nolib/bin/heimdall-precheck-agent" SHIM_DF_SIZE_KB=$OP_SZ SHIM_DF_FREE_KB=$OP_FREE
if [ "$(RC a)" = 0 ] && eo a && ee a; then ok "no bin/lib/hmd_disk_floor.sh next to the hook: allowed, completely silent (a plumbing gap is not a deny)"; else bad "agent no lib: $(show a)"; fi

echo "-- 4. the Bash fence (bin/heimdall-precheck-bash): a command that RUNS a test file or the sweep is denied under the floor --"
# a throwaway plugin root: the REAL script and the REAL lib, a tracker that does nothing (the script's last line calls it)
PLUG="$T/plug"; mkdir -p "$PLUG/bin/lib"
cp "$BASH_HOOK" "$PLUG/bin/heimdall-precheck-bash"; cp "$LIBSH" "$PLUG/bin/lib/hmd_disk_floor.sh" 2>/dev/null
printf '#!/bin/sh\nexit 0\n' > "$PLUG/bin/parallelism-tracker"; chmod +x "$PLUG/bin/parallelism-tracker" "$PLUG/bin/heimdall-precheck-bash"
PLUG_NOLIB="$T/plug-nolib"; mkdir -p "$PLUG_NOLIB/bin"
cp "$BASH_HOOK" "$PLUG_NOLIB/bin/heimdall-precheck-bash"; cp "$PLUG/bin/parallelism-tracker" "$PLUG_NOLIB/bin/parallelism-tracker"; chmod +x "$PLUG_NOLIB/bin/heimdall-precheck-bash"
# bfire PLUGIN COMMAND [K=V ...]: the script run from $T/othercwd with a Bash payload whose cwd is $T/bcwd, env -i
bfire() {
  local plug="$1" cmd="$2"; shift 2
  ( cd "$T/othercwd" && jq -nc --arg c "$cmd" --arg cwd "$T/bcwd" '{tool_name:"Bash", cwd:$cwd, tool_input:{command:$c}}' \
      | env -i HOME="$T/ahome" TMPDIR="$T/btmp" PATH="$T/dfshim:$PATH" CLAUDE_PLUGIN_ROOT="$plug" "$@" "$BASH_ABS" "$plug/bin/heimdall-precheck-bash" ) >"$T/b.out" 2>"$T/b.err"
  echo $? > "$T/b.rc"
}
B_RUNS=0; B_RUNS_BAD=""
b_expect_denied() { # COMMAND -- denied under this machine's disk, verdict on stdout AND stderr
  B_RUNS=$((B_RUNS + 1)); bfire "$PLUG" "$1" SHIM_DF_SIZE_KB=$OP_SZ SHIM_DF_FREE_KB=$OP_FREE
  { [ "$(RC b)" = 2 ] && grep -q '^{"error": "BLOCKED: disk floor: ' "$T/b.out" && ge b 'BLOCKED: disk floor: '; } || B_RUNS_BAD="$B_RUNS_BAD [$1]"
}
while IFS= read -r form; do
  [ -n "$form" ] || continue
  b_expect_denied "$form"
done <<'EOF'
bash test/x.test.sh
bash test/x.test.sh 2>&1 | tail -20
bash ./test/x.test.sh
bash /abs/repo/test/x.test.sh
bash "$ROOT/test/x.test.sh"
bash -x test/x.test.sh
bash -e -u test/x.test.sh
bash -o pipefail test/x.test.sh
sh test/x.test.sh
zsh test/x.test.sh
./test/x.test.sh
test/x.test.sh --verbose
/abs/repo/test/x.test.sh
cd /repo && bash test/x.test.sh
cd test; bash x.test.sh
ls; bash test/x.test.sh
false || bash test/x.test.sh
(bash test/x.test.sh)
FOO=1 bash test/x.test.sh
HMD_X=1 HMD_Y=2 bash test/x.test.sh
env FOO=1 bash test/x.test.sh
time bash test/x.test.sh
timeout 300 bash test/x.test.sh
nohup bash test/x.test.sh &
sh -c "cd /repo && bash test/x.test.sh"
if true; then bash test/x.test.sh; fi
x=$(bash test/x.test.sh)
bash test/run-all.sh
bash test/run-all.sh --since-green
test/run-all.sh --filter statusline
cd test && bash run-all.sh
bash test/agent-name-gate.test.sh
EOF
b_expect_denied $'cd /repo\nbash test/x.test.sh'
if [ -z "$B_RUNS_BAD" ]; then ok "all $B_RUNS ways of RUNNING a test file or the sweep are denied under the floor (bash/sh/zsh + flags, ./path, absolute path, quoted \$VAR path, cd &&, ;, ||, |, (), env prefix, time, timeout, nohup, sh -c, \$(), then, newline, run-all.sh)"; else bad "forms that were NOT denied:$B_RUNS_BAD"; fi
bfire "$PLUG" 'bash test/x.test.sh' SHIM_DF_SIZE_KB=$OP_SZ SHIM_DF_FREE_KB=$OP_FREE
BERR="$(jq -r '.error // empty' "$T/b.out" 2>/dev/null)"
if printf '%s' "$BERR" | grep -q '16.4 GB' && printf '%s' "$BERR" | grep -q '7.1%' && printf '%s' "$BERR" | grep -q '10% free' && printf '%s' "$BERR" | grep -q 'HMD_MIN_FREE_PCT' && printf '%s' "$BERR" | grep -q 'heimdall-disk-floor'; then ok "the deny names free GB, free %, the floor, the override and the CLI"; else bad "bash deny text: $BERR"; fi
if printf '%s' "$BERR" | grep -q 'inline'; then ok "the deny says an inline HMD_MIN_FREE_PCT=... before the command does not reach this hook (the operator sets it in Claude Code's environment)"; else bad "bash deny does not explain the inline override: $BERR"; fi
B_PASS=0; B_PASS_BAD=""
while IFS= read -r form; do
  [ -n "$form" ] || continue
  B_PASS=$((B_PASS + 1)); bfire "$PLUG" "$form" SHIM_DF_SIZE_KB=$OP_SZ SHIM_DF_FREE_KB=$OP_FREE SHIM_DF_FAIL=1
  { [ "$(RC b)" = 0 ] && eo b && ee b; } || B_PASS_BAD="$B_PASS_BAD [$form: $(show b)]"
done <<'EOF'
ls -la
cat test/x.test.sh
grep -n foo test/x.test.sh
sed -n '1,20p' test/x.test.sh
head -5 test/x.test.sh
wc -l test/*.test.sh
ls test/*.test.sh
bash -n test/x.test.sh
bash -nx test/x.test.sh
shellcheck test/x.test.sh
git add test/x.test.sh
git diff -- test/x.test.sh
git log --oneline -- test/run-all.sh
echo "bash test/x.test.sh"
echo bash test/x.test.sh
printf 'run bash test/x.test.sh when done\n'
vim test/x.test.sh
chmod +x test/x.test.sh
bash scripts/latest.sh
bash test/lib/helper.sh
python3 test/lib/foo_cases.py
grep -rn "run-all.sh" docs/
EOF
if [ -z "$B_PASS_BAD" ]; then ok "all $B_PASS commands that only MENTION a test file or the sweep (cat, grep, sed, head, wc, ls, bash -n, shellcheck, git add/diff/log, echo, printf, vim, chmod, helpers) pass -- and with df BROKEN they print nothing: they never reach df"; else bad "commands wrongly held:$B_PASS_BAD"; fi
bfire "$PLUG" 'git commit -m "fix test/x.test.sh" --no-verify' SHIM_DF_SIZE_KB=$OP_SZ SHIM_DF_FREE_KB=$OP_FREE
if [ "$(RC b)" = 0 ] && ! go b 'disk floor'; then ok "a commit whose MESSAGE mentions a test file is not held"; else bad "commit mentioning a test file: $(show b)"; fi
B_OK=0; B_OK_BAD=""
for form in 'bash test/x.test.sh' 'bash test/run-all.sh' './test/x.test.sh'; do
  B_OK=$((B_OK + 1)); bfire "$PLUG" "$form"
  { [ "$(RC b)" = 0 ] && eo b && ee b; } || B_OK_BAD="$B_OK_BAD [$form: $(show b)]"
done
if [ -z "$B_OK_BAD" ]; then ok "with 50 GB of 100 GB free, running a test file or the sweep is allowed, silently ($B_OK forms)"; else bad "held with plenty free:$B_OK_BAD"; fi
bfire "$PLUG" 'bash test/x.test.sh' SHIM_DF_SIZE_KB=$OP_SZ SHIM_DF_FREE_KB=$OP_FREE HMD_MIN_FREE_PCT=7
if [ "$(RC b)" = 0 ] && eo b; then ok "HMD_MIN_FREE_PCT=7 in the hook's environment: the same run is allowed"; else bad "bash override 7: $(show b)"; fi
bfire "$PLUG" 'bash test/x.test.sh' SHIM_DF_FREE_KB=0 HMD_MIN_FREE_PCT=0
if [ "$(RC b)" = 0 ] && eo b; then ok "HMD_MIN_FREE_PCT=0: allowed even at 0 KB free"; else bad "bash floor off: $(show b)"; fi
bfire "$PLUG" 'bash test/x.test.sh' SHIM_DF_FAIL=1
if [ "$(RC b)" = 0 ] && eo b && ge b 'could not read the free space'; then ok "a df that fails: the run is allowed, with the warning on stderr (fails open)"; else bad "bash df fails: $(show b)"; fi
bfire "$PLUG" 'bash test/x.test.sh' SHIM_DF_LOW_PATH="$T/bcwd" SHIM_DF_LOW_KB=$G4
if [ "$(RC b)" = 2 ] && ge b "holding $T/bcwd (" && ! ge b "holding $T/btmp ("; then ok "the cwd in the PAYLOAD is the repo that is checked; only the short volume is named"; else bad "bash cwd volume: $(show b)"; fi
bfire "$PLUG" 'bash test/x.test.sh' SHIM_DF_LOW_PATH="$T/btmp" SHIM_DF_LOW_KB=$G4
if [ "$(RC b)" = 2 ] && ge b "holding $T/btmp ("; then ok "TMPDIR's volume is checked too"; else bad "bash TMPDIR volume: $(show b)"; fi
bfire "$PLUG_NOLIB" 'bash test/x.test.sh' SHIM_DF_SIZE_KB=$OP_SZ SHIM_DF_FREE_KB=$OP_FREE
if [ "$(RC b)" = 0 ] && eo b && ee b; then ok "no bin/lib/hmd_disk_floor.sh in the plugin root: allowed, completely silent (a plumbing gap is not a deny)"; else bad "bash no lib: $(show b)"; fi

echo "-- 5. the sweep: test/lib/run-all-guards.sh (preflight) and test/run-all.sh (between suites) --"
# pf [K=V ...]: hmd_test_disk_preflight "$REPO" from the REAL guards lib under the fake df, TMPDIR=$T/rt; stdout+stderr in $T/pf.out, status in $T/pf.rc
pf() {
  local -a e=(); while [ $# -gt 0 ] && [ "$1" != -- ]; do e[${#e[@]}]="$1"; shift; done
  ( env -u HMD_MIN_FREE_PCT -u HMD_TEST_MIN_FREE_GB -u HMD_DISK_FLOOR_QUIET PATH="$T/dfshim:$PATH" TMPDIR="$T/rt" ${e[@]+"${e[@]}"} \
      "$BASH_ABS" -c 'set -u; . "$1"; hmd_test_disk_preflight "$2"' _ "$GUARDS" "$REPO" ) >"$T/pf.out" 2>&1
  echo $? > "$T/pf.rc"
}
pfn() { grep -c 'refusing to start' "$T/pf.out" | tr -d ' '; }
pf
if [ "$(RC pf)" = 0 ] && [ ! -s "$T/pf.out" ]; then ok "50 GB of 100 GB free: the preflight is silent and passes"; else bad "preflight plenty: rc=$(RC pf) $(cat "$T/pf.out")"; fi
pf SHIM_DF_SIZE_KB=$G100 SHIM_DF_FREE_KB=$G8 SHIM_DF_MOUNT=/vol
if [ "$(RC pf)" = 1 ] && [ "$(pfn)" = 1 ] && grep -q 'only 8.0 GB (8.0%) free' "$T/pf.out" && grep -q 'the floor is 10% free (HMD_MIN_FREE_PCT' "$T/pf.out" && ! grep -q 'a sweep needs at least' "$T/pf.out" && grep -q 'no receipt was written' "$T/pf.out"; then ok "8 GB of 100 GB (8%): over the 5 GB floor, UNDER the 10% floor -> refused by the percent floor alone, one line, 'no receipt was written'"; else bad "percent only: rc=$(RC pf) $(cat "$T/pf.out")"; fi
pf SHIM_DF_SIZE_KB=$G100 SHIM_DF_FREE_KB=$G4 SHIM_DF_MOUNT=/vol
if [ "$(RC pf)" = 1 ] && [ "$(pfn)" = 2 ] && grep -q 'a sweep needs at least 5 GB free (HMD_TEST_MIN_FREE_GB)' "$T/pf.out" && grep -q 'the floor is 10% free (HMD_MIN_FREE_PCT' "$T/pf.out"; then ok "4 GB of 100 GB: under BOTH floors -> each is named, with its own knob"; else bad "both floors: rc=$(RC pf) $(cat "$T/pf.out")"; fi
pf SHIM_DF_SIZE_KB=$G20 SHIM_DF_FREE_KB=$G4 SHIM_DF_MOUNT=/vol
if [ "$(RC pf)" = 1 ] && [ "$(pfn)" = 1 ] && grep -q 'a sweep needs at least 5 GB free (HMD_TEST_MIN_FREE_GB)' "$T/pf.out" && ! grep -q 'the floor is' "$T/pf.out"; then ok "4 GB of 20 GB (20%): over the 10% floor, under the 5 GB floor -> the GB floor is the stricter and refuses alone"; else bad "gb only: rc=$(RC pf) $(cat "$T/pf.out")"; fi
pf SHIM_DF_SIZE_KB=$G100 SHIM_DF_FREE_KB=$G8 SHIM_DF_MOUNT=/vol HMD_MIN_FREE_PCT=7
if [ "$(RC pf)" = 0 ] && [ ! -s "$T/pf.out" ]; then ok "HMD_MIN_FREE_PCT=7: the same 8 GB passes"; else bad "preflight override 7: rc=$(RC pf) $(cat "$T/pf.out")"; fi
pf SHIM_DF_SIZE_KB=$G100 SHIM_DF_FREE_KB=$G8 SHIM_DF_MOUNT=/vol HMD_MIN_FREE_PCT=0
if [ "$(RC pf)" = 0 ] && [ ! -s "$T/pf.out" ]; then ok "HMD_MIN_FREE_PCT=0 turns the percent floor off (the 5 GB floor still passes at 8 GB)"; else bad "preflight pct off: rc=$(RC pf) $(cat "$T/pf.out")"; fi
pf SHIM_DF_SIZE_KB=$G100 SHIM_DF_FREE_KB=$G8 SHIM_DF_MOUNT=/vol HMD_TEST_MIN_FREE_GB=0
if [ "$(RC pf)" = 1 ] && grep -q 'the floor is 10% free' "$T/pf.out"; then ok "HMD_TEST_MIN_FREE_GB=0 does NOT switch the percent floor off (two knobs, two floors)"; else bad "gb off, pct on: rc=$(RC pf) $(cat "$T/pf.out")"; fi
pf SHIM_DF_FREE_KB=1024 SHIM_DF_MOUNT=/vol HMD_TEST_MIN_FREE_GB=0 HMD_MIN_FREE_PCT=0
if [ "$(RC pf)" = 0 ] && [ ! -s "$T/pf.out" ]; then ok "both knobs at 0: 1 MB free passes, silently"; else bad "both off: rc=$(RC pf) $(cat "$T/pf.out")"; fi
pf SHIM_DF_FAIL=1
if [ "$(RC pf)" = 0 ] && grep -q 'could not read the free space' "$T/pf.out" && ! grep -q 'refusing to start' "$T/pf.out"; then ok "a df that cannot answer: a notice, no refusal (a preflight never blocks a sweep on a broken df)"; else bad "df fails: rc=$(RC pf) $(cat "$T/pf.out")"; fi
pf SHIM_DF_LOW_PATH="$T/rt" SHIM_DF_LOW_KB=$G8
if [ "$(RC pf)" = 1 ] && [ "$(pfn)" = 1 ] && grep -qF "holding $T/rt (" "$T/pf.out" && ! grep -qF "holding $REPO (" "$T/pf.out"; then ok "only TMPDIR's volume short: it is the one named"; else bad "tmpdir volume only: rc=$(RC pf) $(cat "$T/pf.out")"; fi
pf SHIM_DF_LOW_PATH="$REPO" SHIM_DF_LOW_KB=$G8
if [ "$(RC pf)" = 1 ] && [ "$(pfn)" = 1 ] && grep -qF "holding $REPO (" "$T/pf.out" && ! grep -qF "holding $T/rt (" "$T/pf.out"; then ok "only the repo's volume short: it is the one named"; else bad "repo volume only: rc=$(RC pf) $(cat "$T/pf.out")"; fi
# rk [K=V ...]: hmd_test_disk_recheck "$REPO" -- the same two floors, asked again between suites; prints DISK_RECHECK_MSG on stdout, status in $T/rk.rc
rk() {
  local -a e=(); while [ $# -gt 0 ] && [ "$1" != -- ]; do e[${#e[@]}]="$1"; shift; done
  ( env -u HMD_MIN_FREE_PCT -u HMD_TEST_MIN_FREE_GB -u HMD_DISK_FLOOR_QUIET PATH="$T/dfshim:$PATH" TMPDIR="$T/rt" ${e[@]+"${e[@]}"} \
      "$BASH_ABS" -c 'set -u; . "$1"; hmd_test_disk_recheck "$2"; rc=$?; printf "%s" "$DISK_RECHECK_MSG"; exit $rc' _ "$GUARDS" "$REPO" ) >"$T/rk.out" 2>"$T/rk.err"
  echo $? > "$T/rk.rc"
}
rk
if [ "$(RC rk)" = 0 ] && eo rk && ee rk; then ok "recheck, 50 GB free: 0, no message, no output"; else bad "recheck ok: $(show rk)"; fi
rk SHIM_DF_SIZE_KB=$G100 SHIM_DF_FREE_KB=$G4 SHIM_DF_MOUNT=/vol
if [ "$(RC rk)" = 1 ] && go rk 'HMD_TEST_MIN_FREE_GB' && go rk 'HMD_MIN_FREE_PCT' && ee rk; then ok "recheck, 4 GB of 100 GB: 1, and the message carries BOTH floors (it is the preflight's own evaluation)"; else bad "recheck low: $(show rk)"; fi
rk SHIM_DF_SIZE_KB=$G100 SHIM_DF_FREE_KB=$G8 SHIM_DF_MOUNT=/vol HMD_MIN_FREE_PCT=7
if [ "$(RC rk)" = 0 ] && eo rk; then ok "recheck honours HMD_MIN_FREE_PCT=7 (8 GB of 100 passes)"; else bad "recheck override: $(show rk)"; fi
rk SHIM_DF_FAIL=1
if [ "$(RC rk)" = 0 ] && eo rk && ee rk; then ok "recheck on a df that cannot answer: 0 and QUIET (the preflight said it once; it is not repeated before every suite)"; else bad "recheck df fails: $(show rk)"; fi

echo "-- 5b. through the REAL run-all.sh (a fixture repo): exit 5 before anything exists; REFUSED suites when the disk fills mid-sweep --"
FX="$T/fx"; mkdir -p "$FX/test/lib" "$FX/bin/lib"
cp "$RUNALL" "$FX/test/run-all.sh"; cp "$GUARDS" "$FX/test/lib/run-all-guards.sh"; cp "$REPO/bin/lib/hook-owned-path.sh" "$FX/bin/lib/hook-owned-path.sh"; cp "$LIBSH" "$FX/bin/lib/hmd_disk_floor.sh" 2>/dev/null
git -C "$FX" init -q >/dev/null 2>&1
fx_commit() { git -C "$FX" add -A >/dev/null 2>&1; git -C "$FX" -c user.email=t@example.com -c user.name=t -c core.hooksPath=/dev/null -c commit.gpgsign=false commit -q --allow-empty --no-verify -m fixture >/dev/null 2>&1; }
# fx_sweep [K=V ...] [-- run-all args]: one sweep of the fixture under the fake df (a 100 GB volume; its free KB is the first line of $T/free, which a fixture suite may lower);
# output in $T/fx.out, status in $T/fx.rc. Default arguments: --jobs 1 --no-retry.
fx_sweep() {
  local -a e=() a=()
  while [ $# -gt 0 ] && [ "$1" != -- ]; do e[${#e[@]}]="$1"; shift; done
  [ $# -eq 0 ] || shift
  while [ $# -gt 0 ]; do a[${#a[@]}]="$1"; shift; done
  [ "${#a[@]}" -gt 0 ] || a=(--jobs 1 --no-retry)
  rm -rf "$T/marks"; mkdir -p "$T/marks"
  ( cd "$FX" && env -u HMD_MIN_FREE_PCT -u HMD_TEST_MIN_FREE_GB -u HMD_TEST_STRICT_TMP -u HMD_TEST_TMP_LEAK_MAX_MB -u HMD_TEST_TMP_WATCH -u HMD_TEST_SOCK_HEADROOM \
      TMPDIR="$ERT" HEIMDALL_HOME="$T/hh" PATH="$T/dfshim:$PATH" SHIM_DF_SIZE_KB=$G100 SHIM_DF_FREE_FILE="$T/free" MARKDIR="$T/marks" \
      ${e[@]+"${e[@]}"} "$BASH_ABS" "$FX/test/run-all.sh" --min 1 "${a[@]}" ) >"$T/fx.out" 2>&1
  echo $? > "$T/fx.rc"
  rm -rf "$ERT"/heimdall-run-all-evidence.* 2>/dev/null
}
RCPT="$T/hh/receipts/last-sweep.json"
cat > "$FX/test/a.test.sh" <<'EOF'
touch "$MARKDIR/a.ran"
echo "a: 1 passed, 0 failed."
EOF
cat > "$FX/test/b.test.sh" <<'EOF'
touch "$MARKDIR/b.ran"
echo "b: 1 passed, 0 failed."
EOF
cat > "$FX/test/c.test.sh" <<'EOF'
touch "$MARKDIR/c.ran"
echo "c: 1 passed, 0 failed."
EOF
fx_commit

echo "$G8" > "$T/free"
fx_sweep HEIMDALL_HOME="$T/hh-refused"
if [ "$(RC fx)" = 5 ] && grep -q 'refusing to start' "$T/fx.out" && grep -q 'HMD_MIN_FREE_PCT' "$T/fx.out" && grep -q '8.0%' "$T/fx.out" && ! grep -q '^progress' "$T/fx.out" && [ ! -e "$T/hh-refused" ] && [ -z "$(ls -A "$T/marks")" ] && [ -z "$(ls -A "$ERT")" ]; then ok "8% free at the default floor: exit 5 BEFORE anything exists -- no suite ran, no HEIMDALL_HOME (so no lock, marker or receipt), no temp root"; else bad "percent refusal rc=$(RC fx) hh=$([ -e "$T/hh-refused" ] && echo present || echo absent) ert=$(ls -A "$ERT"): $(tail -8 "$T/fx.out")"; fi
echo "$G8" > "$T/free"
fx_sweep HMD_MIN_FREE_PCT=7
if [ "$(RC fx)" = 0 ] && grep -q 'RUN GREEN' "$T/fx.out" && [ -e "$T/marks/c.ran" ]; then ok "the same 8% with HMD_MIN_FREE_PCT=7 in the sweep's environment: the sweep runs, and finishes green"; else bad "override sweep rc=$(RC fx): $(tail -8 "$T/fx.out")"; fi
echo "$G50" > "$T/free"
fx_sweep
if [ "$(RC fx)" = 0 ] && grep -q 'RUN GREEN' "$T/fx.out" && jq -e '(has("suites_refused") or has("disk_floor")) | not' "$RCPT" >/dev/null 2>&1 && ! grep -q 'DISK FLOOR' "$T/fx.out" && ! grep -q '^disk floor:' "$T/fx.out"; then ok "control, floor holding throughout: green, nothing about the floor in the output, and the receipt has no new key (it only appears when the floor tripped)"; else bad "control sweep rc=$(RC fx): $(tail -8 "$T/fx.out") receipt=$(jq -c 'keys' "$RCPT" 2>&1)"; fi
if [ -z "$(ls -A "$ERT")" ]; then ok "after a sweep nothing is left under the runner's TMPDIR"; else bad "left under TMPDIR: $(ls -A "$ERT")"; fi

# the disk fills while the FIRST suite runs: --jobs 1 makes the order exact
cat > "$FX/test/a.test.sh" <<'EOF'
touch "$MARKDIR/a.ran"
printf '4194304\n' > "$SHIM_DF_FREE_FILE"     # 4 GB of 100 GB: under the 5 GB floor and under the 10% floor
echo "a: 1 passed, 0 failed."
EOF
fx_commit
echo "$G50" > "$T/free"
fx_sweep
if [ "$(RC fx)" = 1 ] && grep -q 'RUN RED' "$T/fx.out" && grep -q 'DISK FLOOR' "$T/fx.out" && [ -e "$T/marks/a.ran" ] && [ ! -e "$T/marks/b.ran" ] && [ ! -e "$T/marks/c.ran" ]; then ok "disk fills during suite 1 of 3: exit 1 (RUN RED), suite 1 ran, suites 2 and 3 were NEVER started"; else bad "mid-sweep rc=$(RC fx) marks=$(ls "$T/marks" | tr '\n' ' '): $(tail -14 "$T/fx.out")"; fi
if grep -qE '^PASS +a\.test\.sh' "$T/fx.out" && grep -qE '^REFUSED +b\.test\.sh' "$T/fx.out" && grep -qE '^REFUSED +c\.test\.sh' "$T/fx.out"; then ok "the table says PASS for the suite that ran and REFUSED for each that never started"; else bad "table: $(grep -E 'a\.test|b\.test|c\.test' "$T/fx.out")"; fi
if grep -qE '^disk floor: TRIPPED before b\.test\.sh \(launch\) -- 2 suite\(s\) REFUSED' "$T/fx.out" && grep -q '^suites: 1 ran,' "$T/fx.out" && grep -q 'a sweep needs at least 5 GB free (HMD_TEST_MIN_FREE_GB)' "$T/fx.out" && grep -q 'the floor is 10% free (HMD_MIN_FREE_PCT' "$T/fx.out"; then ok "the summary says it plainly: tripped before b.test.sh, 2 REFUSED, '1 ran'; the loud text carries BOTH floors that were crossed (4 GB of 100 GB), each with its knob"; else bad "summary: $(grep -E 'disk floor|^suites:|DISK FLOOR|needs at least|the floor is' "$T/fx.out")"; fi
if jq -e '.exit_code == 1 and .suites_refused == 2 and .suites_passed == 1 and .disk_floor.before == "b.test.sh" and .disk_floor.phase == "launch" and ((.non_green_suites | sort) == ["b.test.sh","c.test.sh"]) and (.disk_floor.reason | test("HMD_MIN_FREE_PCT"))' "$RCPT" >/dev/null 2>&1; then ok "the receipt is red (exit_code 1), records suites_refused 2 and disk_floor {before, phase, reason}, and carries both refused suites in non_green_suites (the next incremental sweep re-runs them)"; else bad "receipt: $(jq -c . "$RCPT" 2>&1 | head -c 700)"; fi
if [ ! -e "$T/hh/receipts/last-full-green.json" ] || ! jq -e '.suites_refused' "$T/hh/receipts/last-full-green.json" >/dev/null 2>&1; then ok "a refused sweep never becomes the full-green anchor"; else bad "a refused sweep wrote the anchor"; fi
if [ -z "$(ls -A "$ERT")" ]; then ok "nothing is left under the runner's TMPDIR after a refused sweep either"; else bad "left under TMPDIR: $(ls -A "$ERT")"; fi
# only the GB floor trips: the same suites on a 20 GB volume, which falls to 4 GB = 20% free (over the 10% floor, under the 5 GB floor)
echo "$G20" > "$T/free"
fx_sweep SHIM_DF_SIZE_KB=$G20
if [ "$(RC fx)" = 1 ] && grep -qE '^REFUSED +b\.test\.sh' "$T/fx.out" && grep -q 'a sweep needs at least 5 GB free (HMD_TEST_MIN_FREE_GB)' "$T/fx.out" && ! grep -q 'the floor is 10% free' "$T/fx.out" && [ ! -e "$T/marks/b.ran" ]; then ok "a 20 GB volume falling to 4 GB (20% free): the GB floor alone stops the sweep -- whichever floor is stricter wins, between suites too"; else bad "gb-only mid-sweep rc=$(RC fx): $(tail -14 "$T/fx.out")"; fi

# the same, with a red suite and the solo re-run phase (--jobs 2): the re-runs are refused too, and the header stops claiming they happened
cat > "$FX/test/a.test.sh" <<'EOF'
echo x >> "$MARKDIR/a.runs"
i=0; while [ ! -e "$MARKDIR/b.started" ] && [ "$i" -lt 100 ]; do sleep 0.1; i=$((i + 1)); done
printf '4194304\n' > "$SHIM_DF_FREE_FILE"
echo "a: 0 passed, 1 failed."
exit 1
EOF
cat > "$FX/test/b.test.sh" <<'EOF'
touch "$MARKDIR/b.started"
echo "b: 1 passed, 0 failed."
EOF
rm -f "$FX/test/c.test.sh"
fx_commit
echo "$G50" > "$T/free"
fx_sweep -- --jobs 2
if [ "$(RC fx)" = 1 ] && [ "$(wc -l < "$T/marks/a.runs" | tr -d ' ')" = 1 ] && grep -q 'DISK FLOOR' "$T/fx.out" && grep -qE '^disk floor: TRIPPED before a\.test\.sh \(re-run\) -- 0 suite\(s\) REFUSED, 1 re-run\(s\) skipped' "$T/fx.out" && grep -q 'NOT re-run alone' "$T/fx.out"; then ok "a red suite when the disk has filled: its solo re-run is NOT started (ran once), the summary says 1 re-run skipped, and the FAILED header no longer claims it was reproduced alone"; else bad "re-run phase rc=$(RC fx) runs=$(cat "$T/marks/a.runs" 2>/dev/null | wc -l): $(tail -16 "$T/fx.out")"; fi
if jq -e '.exit_code == 1 and .suites_refused == 0 and .disk_floor.phase == "re-run" and .disk_floor.before == "a.test.sh" and .disk_floor.retries_skipped == 1' "$RCPT" >/dev/null 2>&1; then ok "the receipt records phase re-run, before a.test.sh, retries_skipped 1"; else bad "re-run receipt: $(jq -c . "$RCPT" 2>&1 | head -c 600)"; fi
rm -f "$FX/test/a.test.sh" "$FX/test/b.test.sh"; fx_commit

echo "-- 6. wiring: the suites that run the REAL spawn hook pin the floor; the docs name it --"
# a suite that drives the shipped bin/heimdall-precheck-agent from the real bin/ dir would otherwise be at the mercy of this machine's free space, exactly as the context
# gate would be -- test/agent-name-gate.test.sh pins HMD_CTX_GATE_OFF=1 for that reason, these pin HMD_MIN_FREE_PCT=0
PIN_BAD=""
for s in agent-name-gate brief-adoption-gate agent-inproc-cap heimdall-switch-launch-env; do
  grep -q 'HMD_MIN_FREE_PCT=0' "$REPO/test/$s.test.sh" 2>/dev/null || PIN_BAD="$PIN_BAD $s"
done
if [ -z "$PIN_BAD" ]; then ok "agent-name-gate, brief-adoption-gate, agent-inproc-cap and heimdall-switch-launch-env pin HMD_MIN_FREE_PCT=0 (hermetic against the disk they run on)"; else bad "suites that run the real spawn hook without pinning the floor:$PIN_BAD"; fi
if grep -q 'HMD_MIN_FREE_PCT' "$REPO/CLAUDE.md" && grep -q 'bin/lib/hmd_disk_floor.sh' "$REPO/CLAUDE.md"; then ok "CLAUDE.md ('When the full gate runs') documents the floor and names the shared lib"; else bad "CLAUDE.md does not document HMD_MIN_FREE_PCT / bin/lib/hmd_disk_floor.sh"; fi
if grep -q 'HMD_MIN_FREE_PCT' "$RUNALL" && grep -q 'hmd_test_disk_recheck' "$RUNALL" && grep -q 'suites_refused' "$RUNALL"; then ok "run-all.sh carries the knob, the between-suites recheck and the receipt field"; else bad "run-all.sh is missing HMD_MIN_FREE_PCT / hmd_test_disk_recheck / suites_refused"; fi
if grep -q 'heimdall-disk-floor' "$REPO/docs/INVENTORY.md"; then ok "docs/INVENTORY.md lists heimdall-disk-floor"; else bad "docs/INVENTORY.md does not list heimdall-disk-floor"; fi
if bash -n "$RUNALL" 2>/dev/null && bash -n "$GUARDS" 2>/dev/null && bash -n "$AGENT_HOOK" 2>/dev/null && bash -n "$BASH_HOOK" 2>/dev/null; then ok "run-all.sh, the guards lib and both hooks still parse"; else bad "a touched script no longer parses"; fi

printf '\ndisk-floor: %s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
