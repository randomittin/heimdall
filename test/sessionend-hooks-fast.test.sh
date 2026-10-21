#!/usr/bin/env bash
# test/sessionend-hooks-fast.test.sh -- every SessionEnd hook in hooks/hooks.json returns inside Claude Code's budget and still does its work.
#
# Claude Code gives a SessionEnd hook about 1.5 s unless its entry sets `timeout`; a hook that outlives that is cancelled, and quitting
# prints "SessionEnd hook [...] failed: Hook cancelled". f54a9fb2 fixed the one that was reported (session-end-sweep). pair-window-stop
# (`hmd app pair-window --stop`, 1.6 to 1.9 s with a live window) and presence-keeper-stop (`heimdall-presence keeper-stop`) did their work in the
# foreground and were cancelled the same way, so this is the structural guard, not a fourth one-off: it takes EVERY SessionEnd command out of
# hooks.json (one added later is covered with no edit here) and runs each as `sh -c` with the hook payload on stdin, in a throwaway project,
# against a fake plugin root where every bin of bin/ is a stub that holds for 5 s. Per command:
#   1. TIMEOUT     the entry sets an explicit `timeout` (a positive integer of seconds): the default budget is not left to decide.
#   2. FAST        the command returns, rc 0, in under 1 s while every bin holds. A bin in the foreground holds the hook for the full 5 s.
#                  A run that is just over budget is tried again (3 tries): a loaded machine slows one run, a bin in the foreground slows all.
#   3. NOT DROPPED once the hold is released, every bin the command names left its marker: the work was detached, not lost. A bin the command
#                  reaches only on a branch the throwaway project does not take is listed in CONDITIONAL_BINS, with the reason.
#   4. DETACHED    every stub ran in a process group of its own (setsid), not the hook's: a hook that is cancelled, or whose parent exits, takes
#                  its own group down, so work left in that group does not outlive it.
#   5. SESSION ID  a command that reads .session_id off stdin hands it to its detached work (the worker has no stdin): it shows in the argv a
#                  stub was given.
# What stays in the foreground is the farewell: sentinels/hmd-farewell.sh is a sentinel, not a bin, bounded by its own 1 s alarm and held to its
# speed by test/session-farewell.test.sh. A sentinel the command names runs here for real, against the real trackers: stubbing the trackers the
# farewell itself calls would only measure its alarm. Libraries a command sources (bin/lib/) are the real ones.
# Two mutants prove the harness itself goes red: a command that runs a bin in the foreground (check 2) and one that backgrounds with `&` and no
# setsid (check 4).
#
# Hermetic: HOME, HEIMDALL_HOME, the project and the plugin root are throwaway; no real bin runs, nothing is killed (a stub ends on its own).

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SELF_DIR/.." && pwd)"
HOOKS="$REPO/hooks/hooks.json"
META="$REPO/hooks/hooks.metadata.json"

HOLD_S=5            # how long a stubbed bin holds, unless the test releases it
BUDGET_MS=1000      # what a SessionEnd command may take in the foreground
CLEAR_MS=2500       # a run this far over is a bin held in the foreground, not a slow machine: no second try
TRIES=3
# bins a command names that the throwaway project cannot reach. heimdall-gc is the `elif` of heimdall-cleanup in the session-end worker: taken
# only when there is no cleanup bin, and here every bin exists.
CONDITIONAL_BINS="heimdall-gc"

PASS=0; FAIL=0
ok()  { PASS=$((PASS + 1)); printf '  \033[32mPASS\033[0m %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  \033[31mFAIL\033[0m %s\n' "$1"; }

for tool in jq perl git; do
  command -v "$tool" >/dev/null 2>&1 || { printf 'FATAL: required tool missing: %s\n' "$tool" >&2; exit 2; }
done
[ -f "$HOOKS" ] && [ -f "$META" ] || { printf 'FATAL: hooks.json or hooks.metadata.json missing\n' >&2; exit 2; }

ROOT="$(mktemp -d)"
trap 'rm -rf "$ROOT"' EXIT INT TERM

now_ms() { perl -MTime::HiRes=time -e 'printf "%.0f", time * 1000'; }

# the hook runs as the leader of a process group of its own (Claude Code runs a hook as a child it can cancel), and says which group
RUN_IN_GROUP='setpgrp(0, 0); open(my $f, ">", shift) or die "pgid file: $!"; print $f getpgrp(); close $f; exec @ARGV or exit 127'

# a bin of the plugin, held: leave a marker (its process group and its argv), then hold, or until the test releases the hold
STUB="$ROOT/stub"
sed "s/@TENTHS@/$((HOLD_S * 10))/" > "$STUB" <<'EOF'
#!/bin/sh
{ printf 'pgid=%s argv=' "$(ps -o pgid= -p "$$" | tr -d ' ')"; printf '[%s]' "$@"; printf '\n'; } >> "$HMD_STUB_MARKS/${0##*/}"
i=0
while [ ! -e "$HMD_STUB_MARKS/.release" ] && [ "$i" -lt @TENTHS@ ]; do sleep 0.1; i=$((i + 1)); done
exit 0
EOF
chmod +x "$STUB"

# named KIND FILE -- the files of bin/, bin/lib/ or sentinels/ a command names
named() {
  case "$1" in
    bin)      perl -ne 'while (m{\bbin/([A-Za-z0-9][A-Za-z0-9._-]*)(?![A-Za-z0-9._/-])}g) { print "$1\n" }' "$2" ;;
    lib)      perl -ne 'while (m{\bbin/lib/([A-Za-z0-9][A-Za-z0-9._-]*)}g) { print "$1\n" }' "$2" ;;
    sentinel) perl -ne 'while (m{\bsentinels/([A-Za-z0-9][A-Za-z0-9._-]*)}g) { print "$1\n" }' "$2" ;;
  esac | sort -u
}

# expected_bins FILE -- the bins a command names that bin/ has, less the ones the throwaway project does not reach
expected_bins() {
  local n
  for n in $(named bin "$1"); do
    [ -f "$REPO/bin/$n" ] || continue
    case " $CONDITIONAL_BINS " in *" $n "*) continue ;; esac
    printf '%s\n' "$n"
  done
}

# mk_root DIR FILE -- a plugin root for the command in FILE: every bin of bin/ is the stub (a bin reached by name, by variable or from PATH is
# held alike), the libraries the command sources are the real ones, and a sentinel runs the real script against the real plugin root
mk_root() {
  local root="$1" n
  mkdir -p "$root/bin/lib" "$root/sentinels"
  perl -e 'my ($stub, $src, $dst) = @ARGV; opendir(my $d, $src) or die; for (readdir $d) { next if /^\./ || !-f "$src/$_"; symlink($stub, "$dst/$_") or die "$_: $!" }' \
    "$STUB" "$REPO/bin" "$root/bin"
  for n in $(named lib "$2"); do
    [ -f "$REPO/bin/lib/$n" ] && cp "$REPO/bin/lib/$n" "$root/bin/lib/$n"
  done
  for n in $(named sentinel "$2"); do
    [ -f "$REPO/sentinels/$n" ] || continue
    printf '#!/bin/sh\nCLAUDE_PLUGIN_ROOT=%q exec bash %q "$@"\n' "$REPO" "$REPO/sentinels/$n" > "$root/sentinels/$n"
    chmod +x "$root/sentinels/$n"
  done
}

# mk_project DIR -- a git repo with a commit, a .planning dir and an uncommitted file: every branch of the session-end worker applies
mk_project() {
  local p="$1"
  mkdir -p "$p/.planning"
  git -C "$p" init -q
  git -C "$p" config user.email t@t.t
  git -C "$p" config user.name t
  printf 'hello\n' > "$p/README.md"
  git -C "$p" add README.md
  git -C "$p" commit -qm "initial commit" --no-verify
  printf 'edit\n' > "$p/dirty.txt"
}

# setup_case NAME FILE -- the plugin root, the project, the session id and the hook payload of one case
setup_case() {
  local d="$ROOT/$1" sid
  mkdir -p "$d/home/.heimdall"
  mk_root "$d/root" "$2"
  mk_project "$d/project"
  sid="sid-$1-$$"
  printf '%s' "$sid" > "$d/sid"
  printf '{"session_id":"%s","cwd":"%s","hook_event_name":"SessionEnd","reason":"other"}' "$sid" "$d/project" > "$d/payload.json"
}

# time_case NAME FILE TRIES -- run the command, rc and foreground wall time of the last try in NAME/{rc,ms,try}; every try gets a marker dir of
# its own (a worker of an earlier try is still running) and the hold is released the moment the time is taken
time_case() {
  local d="$ROOT/$1" cmd t=0 t0 ms=0 rc=0
  cmd="$(cat "$2")"
  while [ "$t" -lt "$3" ]; do
    t=$((t + 1))
    mkdir -p "$d/marks.$t"
    t0="$(now_ms)"
    ( cd "$d/project" && env HOME="$d/home" HEIMDALL_HOME="$d/home/.heimdall" CLAUDE_PLUGIN_ROOT="$d/root" CLAUDE_PROJECT_DIR="$d/project" \
        PATH="$d/root/bin:$PATH" HMD_STUB_MARKS="$d/marks.$t" perl -e "$RUN_IN_GROUP" "$d/pgid.$t" sh -c "$cmd" ) < "$d/payload.json" > "$d/out.$t" 2>&1
    rc=$?
    ms=$(( $(now_ms) - t0 ))
    : > "$d/marks.$t/.release"
    if [ "$rc" -eq 0 ] && [ "$ms" -lt "$BUDGET_MS" ]; then break; fi
    [ "$ms" -ge "$CLEAR_MS" ] && break
  done
  printf '%s' "$t" > "$d/try"; printf '%s' "$ms" > "$d/ms"; printf '%s' "$rc" > "$d/rc"
}

# settle_case NAME FILE -- wait (bounded) for the work the command detached: every bin it names has run, and the groups they ran in are gone
settle_case() {
  local d="$ROOT/$1" t want n i=0 all groups pg live
  t="$(cat "$d/try")"
  want="$(expected_bins "$2")"
  while [ "$i" -lt 300 ]; do
    all=1
    for n in $want; do [ -s "$d/marks.$t/$n" ] || all=0; done
    [ "$all" = 1 ] && break
    sleep 0.1; i=$((i + 1))
  done
  i=0
  while [ "$i" -lt 200 ]; do
    groups="$(cat "$d"/marks.*/* 2>/dev/null | sed -n 's/^pgid=\([0-9][0-9]*\) .*/\1/p' | sort -u)"
    live=0
    for pg in $groups; do ps -ax -o pgid= | grep -qx " *$pg" && live=1; done
    [ "$live" = 0 ] && break
    sleep 0.1; i=$((i + 1))
  done
}

# the verdicts, each on the last try of a case: 0 holds
fast_ok()     { [ "$(cat "$ROOT/$1/rc")" = 0 ] && [ "$(cat "$ROOT/$1/ms")" -lt "$BUDGET_MS" ]; }
kept_ok()     { local n; for n in $(expected_bins "$2"); do [ -s "$ROOT/$1/marks.$(cat "$ROOT/$1/try")/$n" ] || return 1; done; }
missing()     { local n m=""; for n in $(expected_bins "$2"); do [ -s "$ROOT/$1/marks.$(cat "$ROOT/$1/try")/$n" ] || m="$m $n"; done; printf '%s' "$m"; }
marker_pgids() { cat "$ROOT/$1/marks.$(cat "$ROOT/$1/try")"/* 2>/dev/null | sed -n 's/^pgid=\([0-9][0-9]*\) .*/\1/p'; }
detached_ok() {
  local runner pg any=0
  runner="$(cat "$ROOT/$1/pgid.$(cat "$ROOT/$1/try")")"
  for pg in $(marker_pgids "$1"); do any=1; [ "$pg" != "$runner" ] || return 1; done
  [ "$any" = 1 ]
}
sid_ok()      { cat "$ROOT/$1/marks.$(cat "$ROOT/$1/try")"/* 2>/dev/null | grep -qF -- "$(cat "$ROOT/$1/sid")"; }

# -- 1. the SessionEnd commands of hooks.json ----------------------------------------------------------------
NC=0
while IFS="$(printf '\t')" read -r g h t; do
  jq -r --argjson g "$g" --argjson h "$h" '.hooks.SessionEnd[$g].hooks[$h].command' "$HOOKS" > "$ROOT/c$NC.cmd"
  id="$(jq -r --argjson g "$g" '[.hooks[] | select(.event == "SessionEnd" and .index == $g) | .id][0] // empty' "$META")"
  printf '%s' "${id:-SessionEnd[$g]}" > "$ROOT/c$NC.label"
  printf '%s' "$t" > "$ROOT/c$NC.timeout"
  NC=$((NC + 1))
done < <(jq -r '.hooks.SessionEnd | to_entries[] | .key as $g | .value.hooks | to_entries[] | [$g, .key, (.value.timeout // "none")] | @tsv' "$HOOKS")
if [ "$NC" -ge 1 ]; then
  ok "1. hooks.json has $NC SessionEnd command(s) to audit"
else
  bad "1. no SessionEnd command in hooks.json: the audit would be vacuous"
  printf '\n  sessionend-hooks-fast: %d passed, %d failed\n' "$PASS" "$FAIL"
  exit 1
fi

# the two mutants: a bin in the foreground, and a background job with no setsid
printf '%s\n' '"$CLAUDE_PLUGIN_ROOT/bin/heimdall-presence" keeper-stop --session x >/dev/null 2>&1; exit 0' > "$ROOT/m1.cmd"
printf '%s\n' 'nohup "$CLAUDE_PLUGIN_ROOT/bin/heimdall-presence" keeper-stop --session x </dev/null >/dev/null 2>&1 & exit 0' > "$ROOT/m2.cmd"

# -- 2. run them all: every plant first, so one case's setup never lands inside another's timed run ------------
i=0
while [ "$i" -lt "$NC" ]; do setup_case "c$i" "$ROOT/c$i.cmd"; i=$((i + 1)); done
setup_case m1 "$ROOT/m1.cmd"
setup_case m2 "$ROOT/m2.cmd"
i=0
while [ "$i" -lt "$NC" ]; do time_case "c$i" "$ROOT/c$i.cmd" "$TRIES"; i=$((i + 1)); done
time_case m1 "$ROOT/m1.cmd" 1
time_case m2 "$ROOT/m2.cmd" 1
i=0
while [ "$i" -lt "$NC" ]; do settle_case "c$i" "$ROOT/c$i.cmd"; i=$((i + 1)); done
settle_case m1 "$ROOT/m1.cmd"
settle_case m2 "$ROOT/m2.cmd"

# -- 3. the verdicts -----------------------------------------------------------------------------------------
i=0
while [ "$i" -lt "$NC" ]; do
  c="c$i"; f="$ROOT/c$i.cmd"; label="$(cat "$ROOT/c$i.label")"; t="$(cat "$ROOT/c$i.timeout")"
  case "$t" in
    ''|none|*[!0-9]*|0) bad "$label: no explicit timeout on the entry (Claude Code's default SessionEnd budget, about 1.5 s, then applies)" ;;
    *)                  ok "$label: sets an explicit timeout of ${t}s" ;;
  esac
  if fast_ok "$c"; then
    ok "$label: returned rc 0 in $(cat "$ROOT/$c/ms")ms (< ${BUDGET_MS}ms) with every bin holding ${HOLD_S}s"
  else
    bad "$label: rc $(cat "$ROOT/$c/rc"), $(cat "$ROOT/$c/ms")ms over $(cat "$ROOT/$c/try") try(ies) (want rc 0 in < ${BUDGET_MS}ms): a bin runs in the foreground"
  fi
  if [ -z "$(expected_bins "$f")" ]; then
    ok "$label: names no bin of bin/, so there is no work to hold or detach"
  else
    kept_ok "$c" "$f" && ok "$label: the work still ran once the hold was released ($(expected_bins "$f" | tr '\n' ' '))" \
      || bad "$label: the work was dropped: no marker from$(missing "$c" "$f")"
    detached_ok "$c" && ok "$label: every bin ran in a process group of its own, not the hook's (setsid)" \
      || bad "$label: a bin ran in the hook's own process group, or none ran: work left there does not outlive the hook"
  fi
  if grep -q 'session_id' "$f"; then
    sid_ok "$c" && ok "$label: the session id read from stdin reached the detached work" \
      || bad "$label: the session id read from stdin never reached a bin's argv"
  fi
  i=$((i + 1))
done

# -- 4. the mutants: the harness can go red -----------------------------------------------------------------
fast_ok m1 && bad "M1. a bin run in the foreground was not caught by the time check ($(cat "$ROOT/m1/ms")ms)" \
  || ok "M1. the time check fails a bin run in the foreground ($(cat "$ROOT/m1/ms")ms >= ${BUDGET_MS}ms)"
fast_ok m2 && detached_ok m2 && bad "M2. a background job with no setsid was not caught by the process-group check" \
  || ok "M2. the process-group check fails a background job that did not setsid (fast: $(cat "$ROOT/m2/ms")ms)"
fast_ok m2 && ok "M2. ...and it is the group check that catches it: the command itself returned in time" \
  || bad "M2. the no-setsid mutant was not fast ($(cat "$ROOT/m2/ms")ms): it proves nothing about the group check"

printf '\n  sessionend-hooks-fast: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
