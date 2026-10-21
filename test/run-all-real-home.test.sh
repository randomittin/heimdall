#!/usr/bin/env bash
# test/run-all-real-home.test.sh -- THE SWEEP HANDS EVERY SUITE A STAND-IN FOR THE ACCOUNT'S OWN HOME, AND GOES RED WHEN THAT HOME CHANGES ANYWAY.
#
# WHY THIS EXISTS. bin/lib/hmd_pair_optin.py records the per-repo "pair by code" choice (`hmd app connect` / `disconnect`) in the account's own heimdall home -- <pw_dir>/.heimdall, pw_dir from the
# account database, never $HOME -- as well as in the home the environment names, unless HMD_TEST_CANONICAL_HOME names a believed stand-in. About twenty suites sandbox HOME and HEIMDALL_HOME and
# name no stand-in, so the 2.4.9 full sweep wrote ten records into the operator's real ~/.heimdall. test/run-all.sh now (a) launches every suite with a stand-in of its own and (b) snapshots
# <pw_dir>/.heimdall/app/pair-optin and .../relay-approved before the first suite and after the last: an entry that is new, changed or gone makes the run RED, naming the entries and the suites
# that were running when each was written. It never writes, removes or restores anything in that home.
#
# Proven here against throwaway git repos holding the REAL test/run-all.sh and small fixture suites. NOTHING here touches the real home: the guard is pointed at a FAKE account home
# (HMD_TEST_ACCOUNT_HOME), and the real module is driven in-process with a fake pw_dir -- the way test/lib/pair_window_token_optin_cases.py does -- so a stand-in that is not honoured writes
# the fake home, never the real one.
#   S  the stand-in: a suite is handed a 0700 directory holding the 0600 marker, which the REAL module believes (it records the off there, besides HEIMDALL_HOME, and NOT in the account's home);
#      two suites get two directories and the second sees none of the first's records; a suite that names its own keeps its own; nothing of it is left once the suite is done
#   L  in the real layout (the guard library next to run-all.sh) the stand-in is under the suite's own TMPDIR, and is not counted as a leftover even under HMD_TEST_STRICT_TMP=1; the fixture
#      sweep's own TMPDIR is short enough (the runner's 60-byte socket headroom target) to be accepted inside a sweep, where this suite's TMPDIR is already deep
#   G  the guard: five suites reach the fake account home -- a new record, a changed one, a removed one, a new relay approval, and a file outside the two stores. The run is RED (exit 1, the receipt
#      says exit_code 1, nothing is anchored) and names the first four, each with the suites that were running; the fifth is out of scope. Nothing is removed or restored. A control sweep that
#      touches nothing is green and says "untouched"; a sweep with no usable account home says it did not check
#   M  mutation proof: break one line of the real code at a time, each proof above must go red
# Cost: about 10 s -- every scenario runs side by side, each in a repo of its own.
# EXIT: 0 = every proof holds and every mutant is killed; 1 = any FAIL.
# shellcheck disable=SC2016  # the fixture suites are written LITERALLY: their $VARs must reach the file unexpanded
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
RUN_ALL="$ROOT/test/run-all.sh"
LIBDIR="$ROOT/bin/lib"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  \033[32mPASS\033[0m %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  \033[31mFAIL\033[0m %s\n' "$1"; [ -n "${2:-}" ] && printf '        %s\n' "$2" >&2; return 0; }
eq()    { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "got [$2] want [$3]"; fi; }
has()   { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "missing [$3] in: $(printf '%s' "$2" | tail -c 900)" ;; esac; }
lacks() { case "$2" in *"$3"*) bad "$1" "unexpected [$3] in: $(printf '%s' "$2" | tail -c 900)" ;; *) ok "$1" ;; esac; }

for tool in git jq python3 perl; do command -v "$tool" >/dev/null 2>&1 || { echo "FATAL: $tool required" >&2; exit 2; }; done
for f in "$RUN_ALL" "$LIBDIR/hook-owned-path.sh" "$LIBDIR/hmd_pair_optin.py" "$ROOT/test/lib/run-all-guards.sh"; do
  [ -f "$f" ] || { echo "FATAL: missing $f" >&2; exit 2; }
done
# the real interpreter, resolved once: a pyenv shim costs 0.3-0.8 s a call and the fixture suites make several
PY="$(python3 -c 'import sys; print(sys.executable)' 2>/dev/null)"
case "$PY" in /*) [ -x "$PY" ] || PY="" ;; *) PY="" ;; esac
[ -n "$PY" ] || { echo "FATAL: python3 gave no absolute interpreter path" >&2; exit 2; }

# WORK holds every fixture repo and, beside each, the TMPDIR its fixture sweep runs under ($d.tmp), so it has to be SHORT. test/run-all.sh refuses to start (exit 6) when its per-suite temp dir,
# $TMPDIR/hr.XXXX/s<N>, leaves a unix socket path no room, and the L scenario (the guard library next to run-all.sh) is the one that has that preflight. Inside a sweep THIS suite's own TMPDIR is
# already such a dir (~70 bytes on macOS), and a WORK under it put the L sweep's per-suite dir at 108 bytes: refused, L-1..L-4 red -- in a sweep only, never in a plain run, where TMPDIR is short
# (the defect test/run-all-guards.test.sh had, fixed in 55a73a60). So WORK is a private dir directly under /tmp, made from a template and removed by the trap below, whatever TMPDIR this suite
# runs under (under TMPDIR only when /tmp cannot be written); check_room judges it, so a plain run catches a regression too. No socket goes into the shared /tmp: the fixtures bind none.
WORK="$(mktemp -d /tmp/rh.XXXXXX 2>/dev/null || mktemp -d "${TMPDIR:-/tmp}/rh.XXXXXX")"
[ -n "$WORK" ] || { echo "FATAL: mktemp failed" >&2; exit 2; }
FACTS_ROOT="$WORK/facts"; MUT="$WORK/mut"; PROBE="$WORK/probe.py"; mkdir -p "$FACTS_ROOT" "$MUT"
cleanup() { local p; for p in $(jobs -p); do kill "$p" 2>/dev/null; done; rm -rf "$WORK"; }
trap cleanup EXIT
# HMD_TEST_CANONICAL_HOME too: inside a sweep THIS suite was handed a stand-in, and a fixture sweep that does not hand one over would then pass the outer one on.
# HMD_TEST_SOCK_HEADROOM: check_room reads the runner's default socket target (60), so a caller's own value must not move it.
unset HEIMDALL_HOME HMD_TEST_CANONICAL_HOME HMD_TEST_ACCOUNT_HOME HMD_TEST_STRICT_TMP HMD_TEST_TMP_WATCH HMD_TEST_SOCK_HEADROOM HMD_COLD HMD_SUITE_CACHE_MAX_DAYS HMD_SUITE_CACHE_AUDIT_PCT GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR 2>/dev/null || true
export PY LIBDIR PROBE PYTHONDONTWRITEBYTECODE=1

# What a fixture suite learns about its stand-in, printed as key=value lines (the proofs below judge them). The account database is replaced the way the module's own tests do it, so the
# REAL pw_dir is never asked for and `write` refuses to run unless the account's home is the fake one.
cat > "$PROBE" <<'PROBE_EOF'
import os, stat, sys, types

lib, mode = sys.argv[1], sys.argv[2]
sys.path.insert(0, lib)
import hmd_pair_optin as m

fake = os.environ.get("FAKE_PW_DIR", "")
m.pwd = types.SimpleNamespace(getpwuid=lambda uid: types.SimpleNamespace(pw_dir=fake))
home = os.environ.get("HMD_TEST_CANONICAL_HOME", "")
tmpdir = os.environ.get("TMPDIR", "").rstrip("/")


def out(key, value):
    print("%s=%s" % (key, value))


def mode_of(path):
    try:
        return "%04o" % stat.S_IMODE(os.stat(path).st_mode)
    except OSError:
        return "none"


def has_record(base):
    d = os.path.join(base, "app", "pair-optin")
    return "yes" if os.path.isdir(d) and any(n.endswith(".json") for n in os.listdir(d)) else "no"


if mode == "facts":
    out("home", home)
    out("dir_mode", mode_of(home))
    out("marker_mode", mode_of(os.path.join(home, ".hmd-test-canonical-home")))
    out("entries", ",".join(sorted(os.listdir(home))) if os.path.isdir(home) else "none")
    real_tmp = os.path.realpath(tmpdir) if tmpdir else ""   # by directory, not by spelling: a doubled slash or macOS's /var -> /private/var must not decide it
    out("in_tmpdir", "yes" if home and real_tmp and os.path.realpath(home).startswith(real_tmp + os.sep) else "no")
    out("seam", m._seam())
    out("own_home", m._own_home())
elif mode == "write":
    expected = os.path.join(fake, ".heimdall")
    if not fake or m.real_home() != expected:
        out("fake_ok", "no")
        sys.exit(3)
    out("fake_ok", "yes")
    try:
        m.off(sys.argv[3])
        out("off", "ok")
    except OSError as exc:
        out("off", "failed: %s" % exc)
    out("in_heimdall_home", has_record(os.environ["HEIMDALL_HOME"]))
    out("in_stand_in", has_record(home))
    out("in_account", has_record(expected))
PROBE_EOF

# ── fixtures ───────────────────────────────────────────────────────────────────────────────────────────────────────────
mkfix() { # dir run-all-copy [guards] -- a git repo holding that run-all.sh (with `guards`: the real guard library next to it) and no suite yet
  local d="$1" ra="$2"
  mkdir -p "$d/test/lib" "$d/bin/lib" "$d.home" "$d.tmp" "$d.watch"
  git -C "$d" init -q; git -C "$d" config user.email t@example.com; git -C "$d" config user.name T
  printf '.heimdall/\n' > "$d/.gitignore"
  cp "$ra" "$d/test/run-all.sh"
  cp "$LIBDIR/hook-owned-path.sh" "$d/bin/lib/"
  [ -z "${3:-}" ] || cp "$ROOT/test/lib/run-all-guards.sh" "$d/test/lib/"
}
commit() { git -C "$1" add -A; git -C "$1" -c core.hooksPath=/dev/null -c commit.gpgsign=false commit -qm fixture; }
mkseam() { # dir name write -- a fixture suite that saves what the runner handed it; with write=1 it also names its own stand-in and drives the module's off() through the one it was handed
  local d="$1" n="$2" w="${3:-0}"
  {
    printf '%s\n' '#!/usr/bin/env bash' "n=$n" '"$PY" "$PROBE" "$LIBDIR" facts > "$FACTS/$n.facts" 2>&1'
    if [ "$w" = 1 ]; then
      printf '%s\n' \
        'OWN="$(mktemp -d "${TMPDIR:-/tmp}/own.XXXXXX")" && ( umask 077 && echo own > "$OWN/.hmd-test-canonical-home" )' \
        'HMD_TEST_CANONICAL_HOME="$OWN" "$PY" "$PROBE" "$LIBDIR" facts > "$FACTS/$n.own" 2>&1' \
        'HH="$(mktemp -d "${TMPDIR:-/tmp}/hh.XXXXXX")"; RX="$(mktemp -d "${TMPDIR:-/tmp}/rx.XXXXXX")"' \
        'HEIMDALL_HOME="$HH" "$PY" "$PROBE" "$LIBDIR" write "$RX" > "$FACTS/$n.write" 2>&1' \
        'rm -rf "$OWN" "$HH" "$RX"'
    fi
    printf '%s\n' 'echo "$n: 1 passed, 0 failed"'
  } > "$d/test/$n.test.sh"
}
mkleak() { # dir name body -- a fixture suite that passes after doing BODY to the fake account home ($ACCT)
  printf '#!/usr/bin/env bash\n%s\necho "%s: 1 passed, 0 failed"\n' "$3" "$2" > "$1/test/$2.test.sh"
}
seed_acct() { # dir -- a fake account home that already holds two pair records and one relay approval
  mkdir -p "$1/.heimdall/app/pair-optin" "$1/.heimdall/app/relay-approved"
  echo '{"keep":1}' > "$1/.heimdall/app/pair-optin/keep-chg.json"
  echo '{"keep":2}' > "$1/.heimdall/app/pair-optin/keep-rm.json"
  echo '{"keep":3}' > "$1/.heimdall/app/relay-approved/keep.json"
}
runit() { # dir [run-all args] -> OUT, RC. The sweep gets a throwaway HOME, the FAKE account home (ACCT, and the module's pw_dir) and no disk floor -- the box's free space is not what is graded.
  # The caller's ACCT / FACTS / HMD_TEST_STRICT_TMP / HMD_TEST_TMP_WATCH travel with the call
  local d="$1"; shift
  OUT="$( cd "$d" && env HOME="$d.home" TMPDIR="$d.tmp" HMD_TEST_ACCOUNT_HOME="$ACCT" FAKE_PW_DIR="$ACCT" HMD_TEST_MIN_FREE_GB=0 HMD_MIN_FREE_PCT=0 HMD_NO_CAFFEINATE=1 bash test/run-all.sh --min 1 --jobs 1 "$@" 2>&1 )"; RC=$?
}
sweep_done() { # dir facts-dir -- what one sweep left behind
  printf '%s' "$OUT" > "$2/out"; printf '%s' "$RC" > "$2/rc"
  cp "$1/.heimdall/receipts/last-sweep.json" "$2/last.json" 2>/dev/null
  if [ -e "$1/.heimdall/receipts/last-full-green.json" ]; then : > "$2/anchored"; fi
  return 0
}
fact() { sed -n "s/^$3=//p" "$1/$2" 2>/dev/null | head -n 1; } # facts-dir file key

# ── scenarios: each leaves its facts in $FACTS_ROOT/<name>/, so they can all run at once ───────────────────────────────
scn_seam() { # name [run-all-copy] -- S: two suites; the first one also drives the module's off() through its stand-in
  local d="$WORK/$1" f="$FACTS_ROOT/$1"
  mkdir -p "$f"; mkfix "$d" "${2:-$RUN_ALL}"; mkseam "$d" seam1 1; mkseam "$d" seam2 0; commit "$d"
  ACCT="$d.acct" FACTS="$f" runit "$d"; sweep_done "$d" "$f"
}
scn_lib() { # name [run-all-copy] -- L: the real layout, every leftover in a suite's own TMPDIR a failure, and the watched directories private so nobody else's /tmp traffic counts
  local d="$WORK/$1" f="$FACTS_ROOT/$1"
  mkdir -p "$f"; mkfix "$d" "${2:-$RUN_ALL}" guards; mkseam "$d" seam1 0; commit "$d"
  ACCT="$d.acct" FACTS="$f" HMD_TEST_STRICT_TMP=1 HMD_TEST_TMP_WATCH="$d.watch" runit "$d"; sweep_done "$d" "$f"
}
scn_leak() { # name [run-all-copy] -- G: five suites reach the fake account home
  local d="$WORK/$1" f="$FACTS_ROOT/$1" a="$WORK/$1.acct"
  mkdir -p "$f"; seed_acct "$a"; mkfix "$d" "${2:-$RUN_ALL}"
  mkleak "$d" l-new     'echo leaked > "$ACCT/.heimdall/app/pair-optin/new-rec.json"'
  mkleak "$d" l-chg     'echo grown >> "$ACCT/.heimdall/app/pair-optin/keep-chg.json"'
  mkleak "$d" l-rm      'rm -f "$ACCT/.heimdall/app/pair-optin/keep-rm.json"'
  mkleak "$d" l-relay   'echo approved > "$ACCT/.heimdall/app/relay-approved/r.json"'
  mkleak "$d" l-outside 'echo x > "$ACCT/.heimdall/elsewhere.txt"'
  commit "$d"
  ACCT="$a" FACTS="$f" runit "$d"; sweep_done "$d" "$f"
}
scn_ctl() { # name -- the control: one suite that touches nothing, the same fake account home
  local d="$WORK/$1" f="$FACTS_ROOT/$1" a="$WORK/$1.acct"
  mkdir -p "$f"; seed_acct "$a"; mkfix "$d" "$RUN_ALL"; mkleak "$d" quiet 'true'; commit "$d"
  ( cd "$a" && find . -type f -exec cat {} + ) > "$f/before.txt" 2>/dev/null
  ACCT="$a" FACTS="$f" runit "$d"; sweep_done "$d" "$f"
  ( cd "$a" && find . -type f -exec cat {} + ) > "$f/after.txt" 2>/dev/null
}
scn_noacct() { # name -- no usable account home (not an absolute path): the guard says it did not check, and the sweep is unaffected
  local d="$WORK/$1" f="$FACTS_ROOT/$1"
  mkdir -p "$f"; mkfix "$d" "$RUN_ALL"; mkleak "$d" quiet 'true'; commit "$d"
  ACCT="not/absolute" FACTS="$f" runit "$d"; sweep_done "$d" "$f"
}

# ── the proofs ─────────────────────────────────────────────────────────────────────────────────────────────────────────
check_seam() { # name label
  local f="$FACTS_ROOT/$1" l="$2" h1 h2 o
  h1="$(fact "$f" seam1.facts home)"; h2="$(fact "$f" seam2.facts home)"; o="$(fact "$f" seam1.own home)"
  eq "$l-1 the sweep is green and the real-home guard has nothing to report" "$(cat "$f/rc" 2>/dev/null):$(grep -c 'REAL HOME WRITTEN' "$f/out" 2>/dev/null)" "0:0"
  eq "$l-2 the suite is handed a stand-in: a directory of mode 0700 holding nothing but the 0600 marker" "$(fact "$f" seam1.facts dir_mode):$(fact "$f" seam1.facts marker_mode):$(fact "$f" seam1.facts entries)" "0700:0600:.hmd-test-canonical-home"
  eq "$l-3 the REAL module believes it: its seam, and the home it records an off in besides HEIMDALL_HOME, are that directory" "$([ -n "$h1" ] && [ "$(fact "$f" seam1.facts seam)" = "$h1" ] && [ "$(fact "$f" seam1.facts own_home)" = "$h1" ] && echo believed || echo no)" "believed"
  eq "$l-4 a suite that names its own stand-in keeps its own" "$([ -n "$o" ] && [ "$o" != "$h1" ] && [ "$(fact "$f" seam1.own own_home)" = "$o" ] && echo kept || echo no)" "kept"
  eq "$l-5 off() through the stand-in is recorded in HEIMDALL_HOME and in the stand-in, and not in the account's own home" "$(fact "$f" seam1.write fake_ok):$(fact "$f" seam1.write off):$(fact "$f" seam1.write in_heimdall_home):$(fact "$f" seam1.write in_stand_in):$(fact "$f" seam1.write in_account)" "yes:ok:yes:yes:no"
  eq "$l-6 the second suite gets a directory of its own, and none of the first one's records is in it" "$([ -n "$h2" ] && [ "$h2" != "$h1" ] && echo different || echo same):$(fact "$f" seam2.facts entries)" "different:.hmd-test-canonical-home"
  eq "$l-7 nothing of either stand-in is left once its suite is done" "$([ -n "$h1" ] && [ ! -e "$h1" ] && [ -n "$h2" ] && [ ! -e "$h2" ] && echo gone || echo left)" "gone"
  eq "$l-8 the account's own home was never created" "$([ -e "$WORK/$1.acct/.heimdall" ] && echo created || echo untouched)" "untouched"
  has "$l-9 the run says the real home is untouched" "$(cat "$f/out" 2>/dev/null)" "real-home: untouched"
}
check_lib() { # name label
  local f="$FACTS_ROOT/$1" l="$2" h
  h="$(fact "$f" seam1.facts home)"
  eq "$l-1 the sweep is green under HMD_TEST_STRICT_TMP=1, where any leftover in a suite's TMPDIR fails it" "$(cat "$f/rc" 2>/dev/null):$(grep -c 'RUN GREEN' "$f/out" 2>/dev/null)" "0:1"
  eq "$l-2 the stand-in is under the suite's own TMPDIR" "$(fact "$f" seam1.facts in_tmpdir)" "yes"
  eq "$l-3 and it is one the REAL module believes" "$([ -n "$h" ] && [ "$(fact "$f" seam1.facts own_home)" = "$h" ] && echo believed || echo no)" "believed"
  has "$l-4 the temp accounting calls every suite's TMPDIR clean: the stand-in is the runner's, never a suite's leftover" "$(cat "$f/out" 2>/dev/null)" "tmp dirs:   clean"
  lacks "$l-5 and reports no TMP LEAK" "$(cat "$f/out" 2>/dev/null)" "TMP LEAK"
}
check_room() { # name label -- L, beside check_lib (not part of it: the mutants are graded on check_lib alone, and a mutant must die of its own break). See WORK above.
  local f="$FACTS_ROOT/$1"
  eq "$2-6 the fixture sweep's TMPDIR is short: its receipt says the runner's 60-byte socket headroom target is met, so a deep TMPDIR here cannot get it refused (exit 6) inside a sweep" "$(jq -r 'if .tmp_sock.target == 60 and .tmp_sock.headroom >= .tmp_sock.target then "met" else "short: \(.tmp_sock)" end' "$f/last.json" 2>&1)" "met"
}
finding() { printf '%s\n' "$1" | grep -F -- "$3" | grep -Eq "^ +$2 "; } # output kind path -- a report line of that kind naming that path
check_leak() { # name label
  local f="$FACTS_ROOT/$1" l="$2" a="$WORK/$1.acct" out p="$WORK/$1.acct/.heimdall/app"
  out="$(cat "$f/out" 2>/dev/null)"
  eq "$l-1 the run is RED (exit 1) although every suite passed" "$(cat "$f/rc" 2>/dev/null)" "1"
  has "$l-2 it says REAL HOME WRITTEN, with the number of entries" "$out" "REAL HOME WRITTEN (4)"
  eq "$l-3 a new pair record is named as new" "$(finding "$out" new "$p/pair-optin/new-rec.json" && echo named)" "named"
  eq "$l-4 a record that changed is named as changed" "$(finding "$out" changed "$p/pair-optin/keep-chg.json" && echo named)" "named"
  eq "$l-5 a record that is gone is named as removed" "$(finding "$out" removed "$p/pair-optin/keep-rm.json" && echo named)" "named"
  eq "$l-6 a new relay approval is named too: the second store is watched" "$(finding "$out" new "$p/relay-approved/r.json" && echo named)" "named"
  eq "$l-7 each new or changed entry names a suite that was running when it was written" "$(printf '%s\n' "$out" | grep -F "$p/pair-optin/new-rec.json" | grep -F 'running then:' | grep -cF 'l-new.test.sh')" "1"
  lacks "$l-8 a file outside the two stores is out of scope" "$out" "elsewhere.txt"
  has "$l-9 the summary line says it" "$out" "real-home: WRITTEN (4"
  eq "$l-10 the receipt is red and nothing is anchored" "$(jq -r .exit_code "$f/last.json" 2>/dev/null):$([ -e "$f/anchored" ] && echo anchored || echo none)" "1:none"
  eq "$l-11 nothing was removed or restored: the leaked record is still there and the removed one is still gone" "$([ -e "$p/pair-optin/new-rec.json" ] && [ ! -e "$p/pair-optin/keep-rm.json" ] && echo as-left || echo touched)" "as-left"
}
check_ctl() { # name label
  local f="$FACTS_ROOT/$1" l="$2" out
  out="$(cat "$f/out" 2>/dev/null)"
  eq "$l-1 a sweep that touches nothing is green" "$(cat "$f/rc" 2>/dev/null):$(grep -c 'RUN GREEN' "$f/out" 2>/dev/null)" "0:1"
  has "$l-2 it says the real home is untouched, and that it saw the five entries that were there (two stores, three records)" "$out" "real-home: untouched ($WORK/$1.acct/.heimdall/app/{pair-optin,relay-approved}: 5 entries"
  eq "$l-3 and the fake account home is byte for byte what it was" "$(cmp -s "$f/before.txt" "$f/after.txt" && [ -s "$f/before.txt" ] && echo same || echo changed)" "same"
}
check_noacct() { # name label
  local f="$FACTS_ROOT/$1" l="$2" out
  out="$(cat "$f/out" 2>/dev/null)"
  eq "$l-1 the sweep is green" "$(cat "$f/rc" 2>/dev/null):$(grep -c 'RUN GREEN' "$f/out" 2>/dev/null)" "0:1"
  has "$l-2 the run says it did not check the real home" "$out" "real-home: not checked"
  lacks "$l-3 and does not claim it is untouched" "$out" "real-home: untouched"
}

# ── mutation proof, launched with the scenarios so everything runs side by side ───────────────────────────────────────
mutant() { # name sed-expr kind -- in the background: break one line of a COPY of run-all.sh, grade the scenario of KIND (seam | lib | leak) with its proofs, record killed (a proof goes red) or survived
  local name="$1" expr="$2" kind="$3" fails
  (
    sed "$expr" "$RUN_ALL" > "$MUT/$name.sh"
    if cmp -s "$RUN_ALL" "$MUT/$name.sh"; then echo noapply > "$MUT/$name.res"; exit 0; fi
    case "$kind" in
      seam) scn_seam "m-$name" "$MUT/$name.sh"; fails="$( ( check_seam "m-$name" M ) 2>&1 | grep -c $'\033\\[31mFAIL' )" ;;
      lib)  scn_lib  "m-$name" "$MUT/$name.sh"; fails="$( ( check_lib  "m-$name" M ) 2>&1 | grep -c $'\033\\[31mFAIL' )" ;;
      leak) scn_leak "m-$name" "$MUT/$name.sh"; fails="$( ( check_leak "m-$name" M ) 2>&1 | grep -c $'\033\\[31mFAIL' )" ;;
    esac
    if [ "$fails" = 0 ]; then echo survived > "$MUT/$name.res"; else echo killed > "$MUT/$name.res"; fi
  ) &
}

echo "════════════════════════════════════════════════════════════════"
echo "run-all: every suite gets a stand-in for the account's own home; the sweep is RED when that home changes anyway"
echo "════════════════════════════════════════════════════════════════"

scn_seam seam &
scn_lib lib &
scn_leak leak &
scn_ctl ctl &
scn_noacct noacct &
mutant no-seam    's/HMD_TEST_CANONICAL_HOME="\$seam" //g' seam
mutant no-marker  's/\.hmd-test-canonical-home/.hmd-test-canonical-hom/g' seam
mutant loose      's/umask 077/umask 022/' seam
mutant shared     's/canonical-home\.\$idx/canonical-home/' seam
mutant kept       's/^  \[ -z "\$shome" \] || rm -rf "\$shome" 2>\/dev\/null$/  :/' lib
mutant guard-off  's/^  n_realhome=\$(.*$/  n_realhome=0/' leak
mutant one-store  's# "\$ACCOUNT_HOME/.heimdall/app/relay-approved"##' leak
wait

echo "-- S. every suite gets a stand-in the real module believes -----------------------------------------------------------"
check_seam seam S
echo "-- L. in the real layout it is under the suite's own TMPDIR, and never a leftover ------------------------------------"
check_lib lib L
check_room lib L
echo "-- G. the guard: a write to the account's own home turns the run red, and names what changed -------------------------"
check_leak leak G
echo "-- G. the controls ---------------------------------------------------------------------------------------------------"
check_ctl ctl C
check_noacct noacct N

echo "-- M. mutation proof: break one line of the real run-all.sh at a time; the proof for it must go red -----------------"
KILLED=0; TOTAL=0
verdict() { # name what-breaking-it-breaks
  TOTAL=$((TOTAL + 1))
  case "$(cat "$MUT/$1.res" 2>/dev/null)" in
    killed)   KILLED=$((KILLED + 1)); ok "M[$1] killed: $2" ;;
    survived) bad "M[$1] SURVIVED: $2 -- and every proof above still passed" ;;
    noapply)  bad "M[$1] the mutation did not apply: the line it breaks is gone or reworded (update this mutant)" ;;
    *)        bad "M[$1] produced no result" ;;
  esac
}
verdict no-seam   "the suite is no longer handed HMD_TEST_CANONICAL_HOME, so the module records its off in the account's own home"
verdict no-marker "the marker has a name the module does not look for: the stand-in is not believed"
verdict loose     "the marker is made 0644: a file with group or other bits is not believed"
verdict shared    "every suite gets the same stand-in directory (the path no longer carries the suite's index)"
verdict kept      "the stand-in is left behind after its suite, and counted as that suite's leftover"
verdict guard-off "the change count is forced to zero: a write to the account's own home no longer turns the run red"
verdict one-store "the relay-approved store is no longer watched"

echo
printf 'falsifiability: %d/%d\n' "$KILLED" "$TOTAL"
printf '  run-all-real-home: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
