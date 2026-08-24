#!/usr/bin/env bash
#
# heimdall-statusline-agent-tiers.test.sh — per-agent model tier on the swarm
# block, sourced from a cached `heimdall-tier agents --json` (never read
# synchronously on the render path).
#
# WHY THIS EXISTS: the repo owner asked to see which agent runs on which
# model, on the statusline. swarm_block() (sentinels/hmd-statusline.py) is the
# existing per-teammate-agent row renderer; this suite proves the tier tag it
# now carries is (a) cache-only — a solo-agent render never stats or forks for
# it, matching heimdall-statusline-agents-cache.test.sh's precedent for the
# HMD_LIVE_SUBAGENTS count, and (b) HONEST about routing-overrides.json — an
# override is shown as existing and pending, never as the tier actually
# running.
#
# HERMETICITY: every case gets a fresh mktemp workspace/HOME. agent-pool.json
# entries carry NO "pid" key on purpose — active_swarm_agents() only runs the
# os.kill() liveness probe when a pid IS present (sentinels/hmd-statusline.py),
# so a pid-less entry is deterministically "active" without a real process to
# keep alive. HMD_AGENT_TIERS_TTL/_LOCK_TTL are overridden small (1s/2s),
# mirroring HMD_AGENTS_COUNT_TTL/_LOCK_TTL's precedent in
# heimdall-statusline-agents-cache.test.sh, purely so polling stays sub-second.
#
# FALSIFIER (verified by hand for this task): reverting swarm_block() to drop
# the `tier_map = agent_tier_map(cwd)` line and the `_tier_tag(...)` call makes
# cases 3, 4 and 5 go RED (no "[sonnet]"/"[opus]"/"(unapplied)" ever appears,
# and the tier-cache file is never created even with 2 active agents). Case 7
# (zero-cost solo path) stays green either way — it is pinned going forward,
# not a differentiator of this change.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
SL="$ROOT/sentinels/hmd-statusline.py"
TIERBIN="$ROOT/bin/heimdall-tier"

pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n' "$1"; }

command -v python3 >/dev/null 2>&1 || { echo "SKIP: python3 unavailable"; exit 0; }
[ -f "$SL" ] || { echo "FATAL: statusline missing at $SL"; exit 2; }
[ -x "$TIERBIN" ] || { echo "FATAL: heimdall-tier missing at $TIERBIN"; exit 2; }

CACHE_REL=".heimdall/.agent-tiers-cache.json"
LOCK_REL=".heimdall/.agent-tiers-cache.json.lock"

strip_ansi() { python3 -c 'import sys,re; sys.stdout.write(re.sub(r"\033\[[0-9;]*m","",sys.stdin.read()))'; }

mk_agent_template() {
  # mk_agent_template <repo-dir> <name> <model> <tier>
  local dir="$1/agents" name="$2" model="$3" tier="$4"
  mkdir -p "$dir"
  {
    printf '%s\n' '---'
    printf 'name: %s\n' "$name"
    printf 'description: fixture template for the statusline tier tag\n'
    printf 'model: %s\n' "$model"
    printf 'tier: %s\n' "$tier"
    printf '%s\n' '---'
    printf '\n%s\n' 'Fixture body.'
  } > "$dir/$name.md"
}

mkws() {
  # Fresh workspace + HOME. $1/$2 = extra agent-pool "type" strings (roles).
  ws="$(mktemp -d)"; homed="$(mktemp -d)"
  mkdir -p "$ws/.heimdall" "$homed/.heimdall"
  printf '{"handle":"rj","seed":"rj","created":0}\n' > "$ws/.heimdall/identity.json"
  printf '{"verdict":"pass","passed":3,"total":3}\n' > "$ws/.heimdall/statusline.json"
  : > "$ws/.heimdall/.beat-stamp"
  : > "$ws/.heimdall/.wall-cache.json.lock"
  if [ -n "${1:-}" ]; then
    python3 -c "
import json
agents = {}
roles = '$*'.split()
for i, r in enumerate(roles):
    agents['a%d' % i] = {'type': r, 'status': 'active',
                          'started_at': '2026-01-01T00:00:0%dZ' % i,
                          'last_active': '2026-01-01T00:00:0%dZ' % i}
json.dump({'max_agents': 10, 'min_agents': 1, 'agents': agents},
          open('$homed/.heimdall/agent-pool.json', 'w'))
"
  fi
  printf '%s|%s' "$ws" "$homed"
}

render() {
  # render <ws> <homed>  — the documented invocation, hermetic env.
  ws="$1"; homed="$2"
  printf '{"workspace":{"current_dir":"%s","repo":{"name":"fixture"}},"model":{"display_name":"Auto"},"context_window":{"used_percentage":10},"session_id":"agtiers"}' "$ws" \
    | env -i PATH="$PATH" HOME="$homed" \
        HEIMDALL_IDENTITY_DIR="$ws/.heimdall" HMD_HAID=rj HMD_NOW=7 \
        HEIMDALL_CP_URL="http://127.0.0.1:1" COLUMNS=120 LANG=en_US.UTF-8 \
        HMD_STATUSLINE_TMP="$ws/tmp" \
        HMD_AGENT_TIERS_TTL=1 HMD_AGENT_TIERS_LOCK_TTL=2 \
        HEIMDALL_STATUSLINE_MODE=truecolor python3 "$SL"
}

poll_for_file() {
  local n=0
  while [ "$n" -lt "$2" ]; do
    [ -f "$1" ] && return 0
    sleep 0.2
    n=$((n+1))
  done
  [ -f "$1" ]
}

echo "== 1) COLD: 2 live agents, no tier cache yet — renders cleanly, no tag =="
TRIPLE="$(mkws coder hmd:reviewer)"; IFS='|' read -r WS HOMED <<<"$TRIPLE"
mk_agent_template "$WS" coder sonnet sonnet
mk_agent_template "$WS" reviewer opus opus
OUT1="$(render "$WS" "$HOMED" 2>"$WS/err1.txt")"
RC1=$?
if [ "$RC1" -eq 0 ] && [ -n "$OUT1" ]; then
  ok "cold render (2 live agents, cold tier cache) exits 0 with non-empty output"
else
  bad "cold render failed: exit=$RC1 output-len=${#OUT1} stderr=$(cat "$WS/err1.txt")"
fi
if echo "$OUT1" | strip_ansi | grep -q "swarm 2"; then
  ok "swarm block renders (2 active agents) on the cold-cache render"
else
  bad "swarm header 'swarm 2' not found on cold-cache render"
fi
if [ -s "$WS/err1.txt" ]; then
  bad "cold render wrote to stderr (never-error contract): $(cat "$WS/err1.txt")"
else
  ok "cold render wrote nothing to stderr"
fi

echo "== 2) EVENTUAL: tier cache is populated by the background refresh =="
if poll_for_file "$WS/$CACHE_REL" 15; then
  if python3 -c "import json; d=json.load(open('$WS/$CACHE_REL')); assert isinstance(d.get('agents'), list)" 2>/dev/null; then
    ok "tier cache populated with valid JSON within ~3s"
  else
    bad "tier cache appeared but is not the expected shape"
  fi
else
  bad "tier cache never appeared within 3s of the cold render"
fi

echo "== 3) WARM: a fresh render shows each agent's cached declared tier =="
OUT3="$(render "$WS" "$HOMED" 2>/dev/null | strip_ansi)"
if echo "$OUT3" | grep -q '\[sonnet\]'; then
  ok "coder role shows its declared tier [sonnet]"
else
  bad "no [sonnet] tag found on the warm render"
fi
if echo "$OUT3" | grep -q '\[opus\]'; then
  ok "reviewer role (dispatched as hmd:reviewer) shows its declared tier [opus] — hmd: prefix normalized"
else
  bad "no [opus] tag found for the hmd:-prefixed reviewer role"
fi
rm -rf "$WS" "$HOMED"

echo "== 4) OVERRIDE: shown as pending, declared tier never overwritten =="
TRIPLE="$(mkws coder hmd:reviewer)"; IFS='|' read -r WS HOMED <<<"$TRIPLE"
mk_agent_template "$WS" coder sonnet sonnet
mk_agent_template "$WS" reviewer opus opus
mkdir -p "$WS/.planning"
cat > "$WS/.planning/routing-overrides.json" <<'JSON'
{"schema":"heimdall.routing-overrides/1","overrides":{"coder":{"model":"opus","reason":"self-improve experiment (unvalidated)","experiment":"exp-1","status":"open","applied":"2026-08-20T00:00:00Z"}}}
JSON
render "$WS" "$HOMED" >/dev/null 2>/dev/null
poll_for_file "$WS/$CACHE_REL" 15 >/dev/null
OUT4="$(render "$WS" "$HOMED" 2>/dev/null | strip_ansi)"
if echo "$OUT4" | grep -q 'opus(unapplied)'; then
  ok "pending override (opus) is shown, explicitly marked unapplied"
else
  bad "override annotation 'opus(unapplied)' not found: $(echo "$OUT4" | grep -i coder)"
fi
CODER_LINE="$(echo "$OUT4" | grep -i 'coder' | head -1)"
if echo "$CODER_LINE" | grep -q '\[sonnet\]'; then
  ok "coder's row STILL shows declared_tier [sonnet] — override never substituted as active"
else
  bad "coder's row lost its real [sonnet] tag once an override existed: $CODER_LINE"
fi
rm -rf "$WS" "$HOMED"

echo "== 5) DEDUP: a fresh tier cache is served, not recomputed =="
TRIPLE="$(mkws coder hmd:reviewer)"; IFS='|' read -r WS HOMED <<<"$TRIPLE"
mk_agent_template "$WS" coder sonnet sonnet
mk_agent_template "$WS" reviewer opus opus
mkdir -p "$WS/.heimdall"
printf '{"schema":"heimdall.tier-agents/1","agents":[],"overrides_wired":false}' > "$WS/$CACHE_REL"
render "$WS" "$HOMED" >/dev/null 2>/dev/null
sleep 0.5
AFTER="$(cat "$WS/$CACHE_REL" 2>/dev/null || echo '')"
if echo "$AFTER" | grep -q '"agents":\[\]'; then
  ok "fresh sentinel cache (empty agents list) left untouched — no duplicate recompute within TTL"
else
  bad "fresh cache was overwritten while still within TTL: $AFTER"
fi
rm -rf "$WS" "$HOMED"

echo "== 6) DEGRADE: corrupt tier cache never crashes the render =="
TRIPLE="$(mkws coder hmd:reviewer)"; IFS='|' read -r WS HOMED <<<"$TRIPLE"
mk_agent_template "$WS" coder sonnet sonnet
mk_agent_template "$WS" reviewer opus opus
mkdir -p "$WS/.heimdall"
printf 'not json at all {{{' > "$WS/$CACHE_REL"
OUT6="$(render "$WS" "$HOMED" 2>"$WS/err6.txt")"
RC6=$?
if [ "$RC6" -eq 0 ] && [ -n "$OUT6" ]; then
  ok "corrupt tier cache: render still exits 0 with non-empty output"
else
  bad "corrupt tier cache crashed the render (rc=$RC6)"
fi
[ -s "$WS/err6.txt" ] \
  && bad "corrupt tier cache made the render write to stderr: $(cat "$WS/err6.txt")" \
  || ok "corrupt tier cache: still nothing on stderr"
rm -rf "$WS" "$HOMED"

echo "== 7) ZERO-COST SOLO PATH: <2 agents never touches the tier cache at all =="
TRIPLE="$(mkws)"; IFS='|' read -r WS HOMED <<<"$TRIPLE"
render "$WS" "$HOMED" >/dev/null 2>/dev/null
sleep 0.3
if [ -e "$WS/$CACHE_REL" ] || [ -e "$WS/$LOCK_REL" ]; then
  bad "solo-agent render created a tier cache/lock file — swarm_block's early return did not short-circuit"
else
  ok "solo-agent (0 active) render created NO tier cache/lock file — zero added cost confirmed"
fi
rm -rf "$WS" "$HOMED"

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ] || exit 1
