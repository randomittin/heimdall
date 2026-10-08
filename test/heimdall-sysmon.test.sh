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
     HMD_SYSMON_BAREPY_WARN=100000 HMD_SYSMON_BAREPY_CRIT=100001 \
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

# 6. disk suggestion is HONEST about mac-deep-clean's actual availability (never overclaims).
#    Three places count: a USER-level copy and a PROJECT-level copy (both invoked as plain
#    `mac-deep-clean`), and the copy hmd itself SHIPS at <plugin>/skills/mac-deep-clean (the
#    plugin namespace is `hmd`, so that one is invoked as `hmd:mac-deep-clean`).
#    CLAUDE_PLUGIN_ROOT is the plugin-root seam: pointing it at a temp dir simulates "the
#    plugin has / lacks the skill" without touching this checkout and without depending on
#    whatever this machine's real ~/.claude holds.
MDC_HOME="$(mktemp -d "${TMPDIR:-/tmp}/heimdall-sysmon-test.XXXXXX")"
mkdir -p "$MDC_HOME/with/.claude/skills/mac-deep-clean" "$MDC_HOME/without" \
         "$MDC_HOME/plugin-with/skills/mac-deep-clean" "$MDC_HOME/plugin-without"
printf -- '---\nname: mac-deep-clean\n---\nfixture\n' > "$MDC_HOME/with/.claude/skills/mac-deep-clean/SKILL.md"
printf -- '---\nname: mac-deep-clean\n---\nfixture\n' > "$MDC_HOME/plugin-with/skills/mac-deep-clean/SKILL.md"

# forced-full disk so the disk suggestion always fires.  $1=HOME  $2=CLAUDE_PROJECT_DIR  $3=CLAUDE_PLUGIN_ROOT
disk_suggestion() {
  HOME="$1" CLAUDE_PROJECT_DIR="$2" CLAUDE_PLUGIN_ROOT="$3" \
    HMD_SYSMON_DISK_WARN_PCT=0 HMD_SYSMON_DISK_CRIT_PCT=0 "$BIN" 2>&1
}

d_has="$(disk_suggestion "$MDC_HOME/with" "$MDC_HOME/without" "$MDC_HOME/plugin-without")"
printf '%s\n' "$d_has" | grep -q "invoke the 'mac-deep-clean' skill" \
  && ok "disk WARN + user-level skill -> suggestion names it" \
  || bad "disk WARN + user-level skill but suggestion text missing: $d_has"

d_proj="$(disk_suggestion "$MDC_HOME/without" "$MDC_HOME/with" "$MDC_HOME/plugin-without")"
printf '%s\n' "$d_proj" | grep -q "invoke the 'mac-deep-clean' skill" \
  && ok "disk WARN + project-level skill -> suggestion names it" \
  || bad "disk WARN + project-level skill but suggestion text missing: $d_proj"

d_plug="$(disk_suggestion "$MDC_HOME/without" "$MDC_HOME/without" "$MDC_HOME/plugin-with")"
printf '%s\n' "$d_plug" | grep -q "invoke the 'hmd:mac-deep-clean' skill" \
  && ok "disk WARN + plugin-shipped skill, no user copy -> suggestion names hmd:mac-deep-clean" \
  || bad "disk WARN + plugin-shipped skill but suggestion text missing: $d_plug"

d_no="$(disk_suggestion "$MDC_HOME/without" "$MDC_HOME/without" "$MDC_HOME/plugin-without")"
if printf '%s\n' "$d_no" | grep -Eq "invoke the '(hmd:)?mac-deep-clean' skill"; then
  bad "disk WARN + skill nowhere (no user, project or plugin copy) but suggestion still says to invoke it (overclaim)"
else
  ok "disk WARN + skill nowhere -> no overclaim; falls back to manual investigation"
fi
printf '%s\n' "$d_no" | grep -q 'heimdall-cleanup --apply' \
  && ok "disk WARN fallback still points at heimdall-cleanup --apply" \
  || bad "disk WARN fallback missing heimdall-cleanup --apply: $d_no"

# 6b. with CLAUDE_PLUGIN_ROOT UNSET the plugin root resolves from the script's OWN location.
#     A symlinked invocation must still land in the real plugin tree (so the copy this checkout
#     ships is found) ...
ln -s "$BIN" "$MDC_HOME/sysmon-link"
d_self="$(env -u CLAUDE_PLUGIN_ROOT HOME="$MDC_HOME/without" CLAUDE_PROJECT_DIR="$MDC_HOME/without" \
  HMD_SYSMON_DISK_WARN_PCT=0 HMD_SYSMON_DISK_CRIT_PCT=0 "$MDC_HOME/sysmon-link" 2>&1)"
printf '%s\n' "$d_self" | grep -q "invoke the 'hmd:mac-deep-clean' skill" \
  && ok "no CLAUDE_PLUGIN_ROOT: shipped skill found from the script's own (symlink-resolved) location" \
  || bad "no CLAUDE_PLUGIN_ROOT: shipped skill not found via the script location: $d_self"
#     ... and a script sitting in a plugin tree that LACKS the skill must not claim one.
mkdir -p "$MDC_HOME/bare-plugin/bin"
cp "$BIN" "$MDC_HOME/bare-plugin/bin/heimdall-sysmon"
d_bare="$(env -u CLAUDE_PLUGIN_ROOT HOME="$MDC_HOME/without" CLAUDE_PROJECT_DIR="$MDC_HOME/without" \
  HMD_SYSMON_DISK_WARN_PCT=0 HMD_SYSMON_DISK_CRIT_PCT=0 "$MDC_HOME/bare-plugin/bin/heimdall-sysmon" 2>&1)"
if printf '%s\n' "$d_bare" | grep -Eq "invoke the '(hmd:)?mac-deep-clean' skill"; then
  bad "script in a plugin tree WITHOUT skills/mac-deep-clean still tells the user to invoke it (overclaim)"
else
  ok "script in a plugin tree without the skill -> no overclaim"
fi

# 6c. the skill hmd claims to ship is actually in the repo, loadable (frontmatter name = dir name),
#     and portable (no author-machine absolute home paths baked in).
SHIPPED="$ROOT/skills/mac-deep-clean/SKILL.md"
if [ -f "$SHIPPED" ] && [ "$(sed -n '1,2p' "$SHIPPED" | tr '\n' '|')" = "---|name: mac-deep-clean|" ] \
   && grep -q '^description: ' "$SHIPPED"; then
  ok "hmd ships skills/mac-deep-clean/SKILL.md with name + description frontmatter"
else
  bad "skills/mac-deep-clean/SKILL.md missing or its frontmatter is not name: mac-deep-clean + description"
fi
if [ -f "$SHIPPED" ] && ! grep -nE '/Users/|/home/' "$SHIPPED" >/dev/null 2>&1; then
  ok "shipped mac-deep-clean skill is portable (no absolute home paths)"
else
  bad "shipped mac-deep-clean skill is missing or carries an absolute /Users/ or /home/ path"
fi

rm -rf "$MDC_HOME"

echo
echo "$P passed, $F failed"
[ "$F" -eq 0 ]
