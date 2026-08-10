#!/usr/bin/env bash
# heimdall-sysmon.test.sh — the system-health advisor: it RUNS clean, emits valid JSON, and
# (the safety-critical part) its reap SCOPING never targets a foreign process. The reaper and
# the counter share ONE matcher, exposed as `--filter-orphans`, so testing the matcher proves
# the kill scope.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
BIN="$ROOT/bin/heimdall-sysmon"

P=0; F=0
ok()  { P=$((P+1)); echo "  ok   $1"; }
bad() { F=$((F+1)); echo "  FAIL $1"; }

[ -x "$BIN" ] || { echo "FATAL: $BIN not executable"; exit 2; }

# 1. runs, exits 0/1/2, prints the three sections
out="$("$BIN" 2>&1)"; rc=$?
case "$rc" in 0|1|2) ok "runs, exit in {0,1,2} (got $rc)";; *) bad "unexpected exit $rc";; esac
grep -q 'disk' <<<"$out"   && ok "report has a disk section"   || bad "no disk section"
grep -q 'memory' <<<"$out" && ok "report has a memory section" || bad "no memory section"
grep -q 'procs' <<<"$out"  && ok "report has a procs section"  || bad "no procs section"

# 2. --json is valid JSON with the three sections + a severity
js="$("$BIN" --json 2>/dev/null)"
if command -v python3 >/dev/null 2>&1; then
  echo "$js" | python3 -c '
import json,sys
d=json.load(sys.stdin)
assert d["severity"] in ("ok","warn","crit"), d
for k in ("disk","memory","procs"): assert k in d and "status" in d[k], (k,d)
assert isinstance(d["procs"]["hmd_orphans"], int)
print("JSONOK")
' 2>/dev/null | grep -q JSONOK && ok "--json valid, has disk/memory/procs + severity" \
    || bad "--json invalid or missing keys: $js"
else
  echo "  SKIP json (no python3)"
fi

# 3. --quiet is silent when healthy (force all thresholds sky-high → sev must be ok)
q="$(HMD_SYSMON_DISK_WARN_PCT=100 HMD_SYSMON_DISK_CRIT_PCT=101 \
     HMD_SYSMON_SWAP_WARN_PCT=101 HMD_SYSMON_SWAP_CRIT_PCT=102 \
     HMD_SYSMON_WIRED_WARN_PCT=101 HMD_SYSMON_ORPHAN_WARN=100000 \
     HMD_SYSMON_ORPHAN_CRIT=100001 HMD_SYSMON_RUNAWAY_ANY=100000 \
     "$BIN" --quiet 2>&1)"; qrc=$?
[ -z "$q" ] && [ "$qrc" = 0 ] && ok "--quiet silent + exit 0 when healthy" \
  || bad "--quiet not silent/clean when healthy (rc=$qrc out='$q')"

# 4. SCOPING ORACLE — the reaper targets EXACTLY heimdall's own launchd-orphaned python.
#    Feed synthetic `pid ppid command…` rows; --filter-orphans prints the pids it WOULD kill.
rows="$(cat <<'ROWS'
100 1 /usr/bin/python3 /var/folders/x/mock_cp.py --port 1
101 1 python3 /Users/rj/Downloads/heimdall/bin/presence-doctor
102 1 /usr/bin/python3 /Users/rj/.heimdall/keeper/loop.py
200 1 /usr/bin/python3 /Users/rj/myapp/server.py
201 1 /opt/homebrew/bin/python3 -m http.server
202 1 node /Users/rj/app/index.js
300 501 /usr/bin/python3 /var/folders/x/mock_cp.py
301 1 /usr/bin/python3 /Users/rj/work/train.py
ROWS
)"
got="$(printf '%s\n' "$rows" | "$BIN" --filter-orphans | sort | tr '\n' ' ' | sed 's/ *$//')"
want="100 101 102"
[ "$got" = "$want" ] && ok "reap scope = heimdall orphans ONLY (got: $got)" \
  || bad "reap scope wrong — want '$want' got '$got'"

# 4a. FALSIFIER: a foreign python (200) or a non-orphan mock_cp (300, ppid 501) MUST NOT match
printf '%s\n' "$rows" | "$BIN" --filter-orphans | grep -qx 200 && bad "FALSE POSITIVE: foreign myapp/server.py matched" || ok "foreign python (myapp/server.py) NOT matched"
printf '%s\n' "$rows" | "$BIN" --filter-orphans | grep -qx 300 && bad "FALSE POSITIVE: non-orphan mock_cp (real parent) matched" || ok "non-orphan mock_cp.py (ppid!=1) NOT matched"
printf '%s\n' "$rows" | "$BIN" --filter-orphans | grep -qx 301 && bad "FALSE POSITIVE: foreign train.py matched" || ok "foreign train.py NOT matched"

# 5. injected leak → CRIT + a reap suggestion (thresholds low, matcher fed via a fake ps? —
#    instead assert the suggestion wiring: force orphan WARN=1 has no effect without real
#    orphans, so assert the DISK suggestion path deterministically via a forced-full disk.)
d="$(HMD_SYSMON_DISK_WARN_PCT=0 HMD_SYSMON_DISK_CRIT_PCT=0 "$BIN" 2>&1)"; drc=$?
grep -q 'mac-deep-clean' <<<"$d" && ok "disk WARN → suggests mac-deep-clean" \
  || bad "disk WARN did not suggest mac-deep-clean"
[ "$drc" = 2 ] && ok "forced-full disk → exit 2 (crit)" || bad "forced-full disk exit != 2 (got $drc)"

echo
echo "$P passed, $F failed"
[ "$F" -eq 0 ]
