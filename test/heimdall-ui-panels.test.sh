#!/usr/bin/env bash
# test/heimdall-ui-panels.test.sh
#
# INDEPENDENT oracle for Wave 4 ("job panels") of .planning/plans/PLAN-companion-ui.md.
# Written by the TESTER role from the PLAN's Decision 6 / Wave 4 contract only,
# never from bin/lib/companion_ui_panels.py or the panel code in sentinels/hmd-ui.*:
# every assertion cites the PLAN line it is derived from, so an implementation
# that "passes" has met the contract, not merely agreed with its own author.
#
# Contract under test (PLAN-companion-ui.md, line-cited):
#   - a panel is a JSON file at <repo>/.heimdall/ui/panels/<id>.json   (L285-297)
#   - `type` is a CLOSED set: kv|table|number|timeseries|bars|markdown|log-tail;
#     an unrecognized type is refused, nothing written           (L299-301, L431-432)
#   - per-type `data` shapes                                            (L303-342)
#   - a `source` key is a HARD validation failure: whole panel rejected,
#     the server never executes anything a panel supplies            (L343-355, L433-434)
#   - caps: MAX_FILE_BYTES=65536, MAX_TITLE_CHARS=120, MAX_STRING_CHARS=500,
#     MAX_LIST_ITEMS=200, MAX_SERIES=6, id ~ ^[A-Za-z0-9_-]{1,64}$     (L357-368, L318)
#   - staleness: `updated_at` (epoch) required; stale once
#     now - updated_at > max(refresh_s*3, 30); refresh_s is advisory      (L370-376)
#   - one writer per file; atomic `<id>.json.<pid>.tmp` + rename; an orphaned
#     .tmp is reaped, the live .json never touched                      (L377-386)
#   - secret scrub: every string leaf (title + data strings, never numeric x/y)
#     goes through bin/heimdall-activity's secret_shaped() family; a hit rejects
#     the WHOLE panel, stderr names the field, never the value            (L387-397)
#   - TTL: updated_at older than PANEL_TTL_SECONDS=86400 -> file auto-deleted
#     by the server on its next poll                                    (L399-404)
#   - the browser never executes job-provided bytes: escape-first for markdown,
#     plain-escape everywhere else; data never reaches innerHTML unescaped
#                                                              (L328-341, L406-412, L435-439)
#   - publish CLI: `hmd ui panel set <id> --type <t> --title <s> --data-json <file|->
#     [--refresh-s N]` and `hmd ui panel rm <id>`, a subcommand guard clause on
#     bin/heimdall-ui; `-` reads stdin                                    (L450-461)
#   - /api/state and every SSE frame gain a top-level `panels` array of
#     {id,title,type,data,refresh_s,updated_at,stale}, ADDITIVE to the 13 Wave-1
#     keys; provenance is read_panels(), never a raw dir listing           (L515-520)
#   - the server self-publishes `hmd-live-users` (type number, value = roster
#     length) every poll tick, in-process                                  (L697, L713)
#   - `panels` reflects a `set` within one poll cycle (2s, Decision 2)      (L713)
#   - worked examples (a) sqlite3->timeseries, (b) roster->number,
#     (c) CHECKPOINT.md->kv + activity ledger->log-tail                   (L791-830)
#
# Where the orchestrator's brief for this build diverged from the PLAN, the PLAN
# wins and the divergence is recorded in the case that touches it:
#   - brief: `--repo` on the panel CLI. PLAN L450-452 gives the CLI no --repo flag;
#     worked example (a) (L797) resolves the root via HEIMDALL_WATCH_ROOT and
#     (b)/(c) via cwd. This test does BOTH (cd into the fixture + export the var).
#   - brief: `panel ls`. PLAN L847 says a listing subcommand is NOT built this
#     cycle. Case 8 treats `ls` as optional: if present it must list ids.
#   - brief: "total cap across panels". PLAN Decision 6 defines per-panel caps
#     only (L357-368); no cross-panel total exists to assert.
#   - brief: "panels dir absent -> panels: []". PLAN L697 makes the SERVER write
#     hmd-live-users every tick, so the dir is never absent while it runs; case
#     12 asserts "no panel but the server's own" instead.
#
# Hermetic: HOME and HEIMDALL_HOME are redirected to a temp dir, the fixture repo
# is a temp dir, every background process is reaped on EXIT. macOS has no
# `timeout`; every wait is a bounded sleep-0.2 poll. Secret-shaped strings are
# assembled at RUNTIME from parts (never a literal): .gitleaks.toml flags the
# shape in any tracked file, and a full-history scan runs on push.

set -u

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
UI="${HEIMDALL_UI_BIN:-$REPO/bin/heimdall-ui}"   # override only for harness self-check / red-proof runs
FIXTURES="$REPO/test/fixtures/companion-ui-panels"

PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; }
note() { printf '       %s\n' "$1"; }

echo "heimdall-ui-panels (companion web UI, Wave 4 job-panels oracle)"

# ── preconditions: a not-yet-landed author is an explicit SKIP, never a crash ─
# PLAN L450-455: the publish path is a `panel` guard clause in bin/heimdall-ui
# that execs bin/lib/companion_ui_panels.py. Both must exist before any case can
# run; their CONTENT is never read here (author != tester).
if [ ! -x "$UI" ]; then
  printf '  SKIP bin/heimdall-ui is absent or not executable (%s)\n' "$UI"
  printf '       Wave 1 has not landed; every case below needs the server\n'
  printf '\n0 passed, 0 failed, 1 skipped (Wave 4 job panels: author not landed)\n'
  exit 0
fi
if ! grep -q '"panel"' "$UI" 2>/dev/null || [ ! -f "$REPO/bin/lib/companion_ui_panels.py" ]; then
  printf '  SKIP the `panel` subcommand is not wired yet\n'
  printf '       (need: a `panel` guard clause in %s AND %s -- PLAN L450-455)\n' "$UI" "$REPO/bin/lib/companion_ui_panels.py"
  printf '       the author has not landed Wave 4 (companion-ui-panels); nothing to grade\n'
  printf '\n0 passed, 0 failed, 1 skipped (Wave 4 job panels: author not landed)\n'
  exit 0
fi
for tool in curl jq python3 sqlite3 git; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    printf '  FAIL required tool missing: %s\n' "$tool"
    printf '\n0 passed, 1 failed\n'
    exit 1
  fi
done

# ── sandbox ─────────────────────────────────────────────────────────────────
TMPROOT="$(mktemp -d)"
export HOME="$TMPROOT/home"
export HEIMDALL_HOME="$TMPROOT/home/.heimdall"
FIX="$TMPROOT/fixture-repo"
PANELS="$FIX/.heimdall/ui/panels"
mkdir -p "$HOME/.claude" "$HEIMDALL_HOME/signing" "$HEIMDALL_HOME/pki" \
         "$FIX/.heimdall/receipts" "$FIX/.planning/reels" "$FIX/.planning/ledger/activity"

PIDS=()
cleanup() {
  local p
  for p in "${PIDS[@]:-}"; do
    [ -n "$p" ] && kill "$p" 2>/dev/null
  done
  for p in "${PIDS[@]:-}"; do
    [ -n "$p" ] && wait "$p" 2>/dev/null
  done
  rm -rf "$TMPROOT"
}
trap cleanup EXIT

# Planted deny-list sentinels (Wave 1 contract, L70-71/L208) -- the panel surface
# must not become a new channel for any of them either. Runtime-assembled.
S_TEAM="hmd-ui-sentinel-team-$(date +%s)-$RANDOM$RANDOM"
S_KEY="hmd-ui-sentinel-key-$(date +%s)-$RANDOM$RANDOM"
SENTINELS=("$S_TEAM" "$S_KEY")
printf '{"team_id":"t_fixture","secret":"%s"}\n' "$S_TEAM" > "$FIX/.heimdall/team.json"
printf '{"team_id":"t_fixture","secret":"%s"}\n' "$S_TEAM" > "$HEIMDALL_HOME/team.json"
printf '%s\n' "$S_KEY" > "$HEIMDALL_HOME/signing/heimdall-signing.key"

# Wave-1 state sources so the 13 contract keys have something real behind them.
cat > "$FIX/.heimdall/roster-cache.json" <<'JSON'
[{"haid":"haid:fixture.box-0001","handle":"fixture","branch":"main","project":"fixture-repo",
  "state":"active","verdict":"pass","file":"","ts":1758276286,"activity_ts":1758276286,
  "age_seconds":1.0,"online":true}]
JSON
cat > "$FIX/.planning/CHECKPOINT.md" <<'MD'
<!-- heimdall-auto-checkpoint:begin -->
## Auto-checkpoint — 2026-09-19T08:54:05Z

- **Branch:** fixture-branch
- **HEAD:** f1x7u4e0
- **Phase:** fixture-phase
- **Uncommitted files:** 0
<!-- heimdall-auto-checkpoint:end -->
MD
# worked example (c) reads the activity ledger (L826-828)
printf '{"haid":"haid:fixture.box-0001","active_task":"fixture-task","branch":"fixture-branch"}\n' \
  > "$FIX/.planning/ledger/activity/haid_fixture.json"
( cd "$FIX" && git init -q . 2>/dev/null && git -c user.email=t@t -c user.name=t add -A >/dev/null 2>&1 \
  && git -c user.email=t@t -c user.name=t commit -qm fixture >/dev/null 2>&1 ) || true

# ── secret shapes, assembled at runtime (bin/heimdall-activity:167-179) ─────
# The PLAN (L387-393) says the panel scrub CALLS heimdall-activity's own
# secret_shaped() family. Three of its shapes, built from parts so no literal
# credential-shaped token sits in this file:
#   Stripe secret   sk_(live|test)_[A-Za-z0-9]{16,}
#   AWS key id      AKIA[0-9A-Z]{16}
#   assigned cred   (password|token|...)\s*[=:]\s*\S{16,}
alnum() { python3 -c 'import secrets,string,sys; n=int(sys.argv[1]); print("".join(secrets.choice(string.ascii_letters+string.digits) for _ in range(n)))' "$1"; }
upnum() { python3 -c 'import secrets,string,sys; n=int(sys.argv[1]); print("".join(secrets.choice(string.ascii_uppercase+string.digits) for _ in range(n)))' "$1"; }
SEC_STRIPE="$(printf '%s%s%s_%s' 'sk' '_li' 've' "$(alnum 24)")"
SEC_AWS="$(printf '%s%s%s' 'AK' 'IA' "$(upnum 16)")"
SEC_ASSIGNED="$(printf '%s%s = %s' 'pass' 'word' "$(alnum 20)")"
# sanity: each shape really is one heimdall-activity rejects (the cited family)
for s in "$SEC_STRIPE" "$SEC_AWS" "$SEC_ASSIGNED"; do
  if ! printf '%s' "$s" | grep -Eq 'sk_(live|test)_[A-Za-z0-9]{16,}|AKIA[0-9A-Z]{16}|(password|token|secret)[[:space:]]*[=:][[:space:]]*[^[:space:]]{16,}'; then
    printf '  FAIL harness bug: assembled shape does not match heimdall-activity:167-179 family\n'
    printf '\n0 passed, 1 failed\n'; exit 1
  fi
done

# ── helpers ─────────────────────────────────────────────────────────────────
free_port() {
  python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])'
}
PORT="$(free_port)"

# Poll a file for a regex, up to $3 seconds (0.2s steps). Exit 0 on match.
wait_for() {
  local file="$1" re="$2" secs="${3:-10}" i=0 max
  max=$(( secs * 5 ))
  while [ "$i" -lt "$max" ]; do
    grep -Eq "$re" "$file" 2>/dev/null && return 0
    sleep 0.2; i=$((i + 1))
  done
  return 1
}

# The publish CLI, run the way the PLAN's worked examples run it (L797, L809, L822):
# from the repo root, with HEIMDALL_WATCH_ROOT pointing at it. stdin passes through.
panel() { ( cd "$FIX" && HEIMDALL_WATCH_ROOT="$FIX" exec "$UI" panel "$@" ); }

# Fetch /api/state into $1; echo http code.
STATE="$TMPROOT/state.json"
get_state() { curl -s -o "${1:-$STATE}" -w '%{http_code}' "$BASE/api/state?$AUTH"; }

# Poll /api/state up to $2 seconds until jq expression $1 is true. Exit 0 on true.
state_until() {
  local expr="$1" secs="${2:-6}" i=0 max
  max=$(( secs * 5 ))
  while [ "$i" -lt "$max" ]; do
    get_state >/dev/null 2>&1
    jq -e "$expr" "$STATE" >/dev/null 2>&1 && return 0
    sleep 0.2; i=$((i + 1))
  done
  return 1
}

# Poll until a path is gone, up to $2 seconds.
gone_within() {
  local path="$1" secs="${2:-6}" i=0 max
  max=$(( secs * 5 ))
  while [ "$i" -lt "$max" ]; do
    [ ! -e "$path" ] && return 0
    sleep 0.2; i=$((i + 1))
  done
  return 1
}

# Names of every regular file currently in the panels dir (sorted), for
# "nothing was written" assertions.
panel_files() { ( cd "$PANELS" 2>/dev/null && ls -1 2>/dev/null | sort ) || true; }

contains_sentinel() {
  local file="$1" s
  for s in "${SENTINELS[@]}"; do
    grep -q "$s" "$file" 2>/dev/null && { printf '%s' "$s"; return 0; }
  done
  return 1
}

CONTRACT_KEYS=(schema_version ts repo identity ledger roster quality_gate sweep_receipt hooks fallback parallelism checkpoint reels)
missing_contract_keys() {
  local f="$1" k m=""
  for k in "${CONTRACT_KEYS[@]}"; do
    jq -e --arg k "$k" 'has($k)' "$f" >/dev/null 2>&1 || m="$m $k"
  done
  printf '%s' "$m"
}

# ── start the server under test ─────────────────────────────────────────────
SRV_OUT="$TMPROOT/server.out"
( cd "$FIX" && HEIMDALL_WATCH_ROOT="$FIX" exec "$UI" --repo "$FIX" --port "$PORT" --no-open ) \
  >"$SRV_OUT" 2>&1 &
SRV_PID=$!
PIDS+=("$SRV_PID")
URL_RE="^http://127\.0\.0\.1:$PORT/\?(t|token)=[A-Za-z0-9_-]+\$"
if ! wait_for "$SRV_OUT" "$URL_RE" 10; then
  bad "0. server never printed its URL line within 10s; output:"
  sed 's/^/       | /' "$SRV_OUT"
  printf '\n%s passed, %s failed (server never came up; remaining cases not run)\n' "$PASS" "$FAIL"
  exit 1
fi
URL="$(grep -E "$URL_RE" "$SRV_OUT" | head -1)"
Q="${URL#*\?}"; TP="${Q%%=*}"; TOKEN="${Q#*=}"
BASE="http://127.0.0.1:$PORT"
AUTH="$TP=$TOKEN"
ok "0. server up on $BASE with a ?$TP= token"

# ═══ 12. no operator panels yet -> panels is an array; 13 Wave-1 keys intact ══
# PLAN L515-519: `panels` is ADDITIVE to the §4 contract. The panels dir did not
# exist when the server started. PLAN L697: the server itself publishes
# hmd-live-users every tick, so the only id allowed here is that one.
rc="$(get_state)"
m="$(missing_contract_keys "$STATE")"
if [ "$rc" = "200" ] && [ -z "$m" ] && jq -e '(.panels|type) == "array"' "$STATE" >/dev/null 2>&1; then
  ok "12. /api/state -> 200, all 13 Wave-1 keys present AND a top-level panels array (L515-519)"
else
  bad "12. rc=$rc missing=[$m] panels=$(jq -c '.panels|type' "$STATE" 2>/dev/null)"
fi
if jq -e '[.panels[].id] | all(. == "hmd-live-users")' "$STATE" >/dev/null 2>&1; then
  ok "12b. with no operator panels, no panel id other than the server's own hmd-live-users"
else
  bad "12b. unexpected panel ids before any publish: $(jq -c '[.panels[].id]' "$STATE" 2>/dev/null)"
fi
# the self-published dogfood panel (L697, L713, L807-813): number, value == roster length
if state_until '.panels[] | select(.id=="hmd-live-users") | .type=="number" and (.data.value|type)=="number"' 6 \
   && jq -e '(.panels[] | select(.id=="hmd-live-users") | .data.value) == (.roster|length)' "$STATE" >/dev/null 2>&1; then
  ok "12c. hmd-live-users is self-published: type number, data.value == roster length (L697, L713)"
else
  bad "12c. hmd-live-users missing or wrong: $(jq -c '[.panels[]|select(.id=="hmd-live-users")]' "$STATE" 2>/dev/null) roster=$(jq -c '.roster|length' "$STATE" 2>/dev/null)"
fi
if [ -f "$PANELS/hmd-live-users.json" ] \
   && jq -e '.type=="number" and (.data.value|type=="number") and .data.value>=0' "$PANELS/hmd-live-users.json" >/dev/null 2>&1; then
  ok "12d. worked example (b)'s own jq check passes on the server-written file (L810)"
else
  bad "12d. $PANELS/hmd-live-users.json missing or fails L810's jq: $(cat "$PANELS/hmd-live-users.json" 2>/dev/null | head -c 200)"
fi

# ═══ 1. every closed type round-trips ═════════════════════════════════════
# PLAN L299-342: the closed set and each type's data shape; L713: reflected in
# /api/state within one poll cycle; L516-517: entry keys.
declare -a T_NAMES=(kv table number timeseries bars markdown log-tail)
declare -a T_DATA=(
  '{"rows":[["Branch","main"],["HEAD","abc1234"],["Phase","fixture"]]}'
  '{"columns":["gate","state"],"rows":[["tests","pass"],["lint","running"]]}'
  '{"value":42,"delta":-3,"format":"count"}'
  '{"x":["2026-09-19T09:00:00Z","2026-09-19T10:00:00Z"],"y":[12,31]}'
  '{"labels":["a","b","c"],"values":[1,2,3]}'
  '{"text":"**bold** and `code`\n- item one\n- item two"}'
  '{"lines":["line one","line two","line three"]}'
)
i=0
while [ "$i" -lt "${#T_NAMES[@]}" ]; do
  t="${T_NAMES[$i]}"; d="${T_DATA[$i]}"; id="rt-$t"
  ERR="$TMPROOT/set-$t.err"
  if printf '%s' "$d" | panel set "$id" --type "$t" --title "Round trip $t" --data-json - 2>"$ERR"; then
    if [ -f "$PANELS/$id.json" ] \
       && state_until ".panels[] | select(.id==\"$id\") | .type==\"$t\" and .data==($d) and .title==\"Round trip $t\"" 6; then
      ok "1.$((i + 1)) type=$t: set exits 0, file at .heimdall/ui/panels/$id.json, /api/state round-trips type+title+data within one poll"
    else
      bad "1.$((i + 1)) type=$t: file=$([ -f "$PANELS/$id.json" ] && echo yes || echo no) state=$(jq -c "[.panels[]|select(.id==\"$id\")]" "$STATE" 2>/dev/null)"
    fi
  else
    bad "1.$((i + 1)) type=$t: set exited nonzero; stderr: $(head -c 300 "$ERR")"
  fi
  i=$((i + 1))
done
# multi-series shapes (L316-317, L326-327) and --refresh-s (L451, L516)
if printf '{"series":[{"name":"a","x":[1,2],"y":[3,4]},{"name":"b","x":[1,2],"y":[5,6]}]}' \
     | panel set rt-multi --type timeseries --title "Multi" --data-json - --refresh-s 60 2>/dev/null \
   && printf '{"series":[{"name":"a","labels":["p","q"],"values":[1,2]}]}' \
     | panel set rt-multibars --type bars --title "Multi bars" --data-json - 2>/dev/null \
   && state_until '(.panels[] | select(.id=="rt-multi") | .data.series|length)==2 and (.panels[] | select(.id=="rt-multi") | .refresh_s)==60 and ([.panels[].id]|index("rt-multibars"))!=null' 6; then
  ok "1.8 multi-series timeseries + bars accepted; --refresh-s 60 surfaces as refresh_s==60"
else
  bad "1.8 multi-series / --refresh-s: $(jq -c '[.panels[]|select(.id=="rt-multi" or .id=="rt-multibars")|{id,refresh_s,n:(.data.series|length)}]' "$STATE" 2>/dev/null)"
fi
# --data-json FILE (not just '-') (L450-451)
printf '{"value":7}' > "$TMPROOT/file-payload.json"
if panel set rt-file --type number --title "From file" --data-json "$TMPROOT/file-payload.json" 2>/dev/null \
   && state_until '.panels[] | select(.id=="rt-file") | .data.value==7' 6; then
  ok "1.9 --data-json <file> works as well as -"
else
  bad "1.9 --data-json <file> failed"
fi
# every served panel entry carries the full L516-517 key set, correct types
if jq -e '.panels | all(has("id") and has("title") and has("type") and has("data") and has("refresh_s") and has("updated_at") and has("stale")
                         and (.updated_at|type)=="number" and (.stale|type)=="boolean" and (.id|type)=="string")' "$STATE" >/dev/null 2>&1; then
  ok "1.10 every panels[] entry has id,title,type,data,refresh_s,updated_at,stale with the L516-517 types"
else
  bad "1.10 an entry is missing a contract key or has a wrong type: $(jq -c '[.panels[]|{id,keys:(keys),u:(.updated_at|type),s:(.stale|type)}]' "$STATE" 2>/dev/null | head -c 600)"
fi
if jq -e '[.panels[] | select(.id|startswith("rt-")) | .stale] | all(. == false)' "$STATE" >/dev/null 2>&1; then
  ok "1.11 freshly set panels are stale==false (L370-373)"
else
  bad "1.11 a fresh panel is already stale: $(jq -c '[.panels[]|select(.id|startswith("rt-"))|{id,stale}]' "$STATE" 2>/dev/null)"
fi

# ═══ 2. `source` is refused outright (RCE surface) ═══════════════════════
# PLAN L343-355: presence of a `source` key is a hard validation failure, the
# WHOLE panel is rejected; L433-434: the server never executes anything a
# panel supplies. Two entry points: the CLI payload, and a file planted
# directly at the trust boundary (L426-429).
before="$(panel_files)"
ERR="$TMPROOT/source.err"
CANARY="$TMPROOT/pwned-by-source"
if printf '{"source":"touch %s","x":[1],"y":[1]}' "$CANARY" \
     | panel set src-cli --type timeseries --title "RCE" --data-json - 2>"$ERR"; then
  bad "2. a payload carrying a source key was ACCEPTED (exit 0)"
else
  if [ ! -e "$PANELS/src-cli.json" ] && [ "$(panel_files)" = "$before" ]; then
    ok "2. payload with a source key -> nonzero exit, no file written (L343-355)"
  else
    bad "2. source refused but a file was written: $(panel_files | tr '\n' ' ')"
  fi
fi
if grep -qi 'source' "$ERR"; then
  ok "2b. the refusal names source: $(head -1 "$ERR" | head -c 120)"
else
  bad "2b. refusal stderr does not mention source: $(head -c 200 "$ERR")"
fi
# planted file with a top-level source key (fixture) -> never served, never run
now="$(date +%s)"
jq --arg c "touch $CANARY" --argjson n "$now" '.source=$c | .updated_at=$n' \
  "$FIXTURES/invalid-source-key.json" > "$PANELS/planted-source.json"
sleep 4.5   # > two 2s polls (Decision 2, L110)
get_state >/dev/null
if ! jq -e '[.panels[].id] | index("planted-source")' "$STATE" >/dev/null 2>&1; then
  ok "2c. a planted panel FILE with a source key is dropped from /api/state (L426-434)"
else
  bad "2c. planted source-key panel is being served: $(jq -c '.panels[]|select(.id=="planted-source")' "$STATE")"
fi
if [ ! -e "$CANARY" ]; then
  ok "2d. the source command never ran (canary file absent after >2 polls)"
else
  bad "2d. RCE: the planted source command EXECUTED (canary $CANARY exists)"
fi
rm -f "$PANELS/planted-source.json"

# ═══ 3. unknown type refused, nothing written ═════════════════════════════
# PLAN L299-301, L431-432; Wave 4 acceptance L727 (chart3d).
before="$(panel_files)"
if printf '{"x":[1],"y":[1]}' | panel set bad --type chart3d --title "3d" --data-json - 2>/dev/null; then
  bad "3. --type chart3d was ACCEPTED"
else
  if [ ! -e "$PANELS/bad.json" ] && [ "$(panel_files)" = "$before" ]; then
    ok "3. --type chart3d -> nonzero exit, .heimdall/ui/panels/bad.json not written (L727)"
  else
    bad "3. chart3d refused but something was written: $(panel_files | tr '\n' ' ')"
  fi
fi
jq --argjson n "$(date +%s)" '.updated_at=$n' "$FIXTURES/invalid-type-chart3d.json" > "$PANELS/planted-chart3d.json"
sleep 4.5
get_state >/dev/null
if ! jq -e '[.panels[].id] | index("planted-chart3d")' "$STATE" >/dev/null 2>&1; then
  ok "3b. a planted FILE with type chart3d is dropped from /api/state (L431-432)"
else
  bad "3b. planted chart3d panel is served"
fi
rm -f "$PANELS/planted-chart3d.json"

# ═══ 4. id must match ^[A-Za-z0-9_-]{1,64}$ -- no traversal ═════════════
# PLAN L367-368.
before="$(panel_files)"
LONG_ID="$(printf 'a%.0s' $(seq 1 65))"
declare -a BAD_IDS=('../traversal-up' '/tmp/traversal-abs' 'has space' 'dot.id' 'slash/id' "$LONG_ID" '')
refused=0; accepted=""
for bid in "${BAD_IDS[@]}"; do
  if printf '{"value":1}' | panel set "$bid" --type number --title "bad id" --data-json - 2>/dev/null; then
    accepted="$accepted [$bid]"
  else
    refused=$((refused + 1))
  fi
done
if [ "$refused" = "${#BAD_IDS[@]}" ]; then
  ok "4. all ${#BAD_IDS[@]} malformed ids refused: ../, /abs, space, dot, slash, 65 chars, empty (L367-368)"
else
  bad "4. malformed id(s) ACCEPTED:$accepted"
fi
stray="$(find "$TMPROOT" -name '*traversal*' 2>/dev/null; ls /tmp/traversal-abs.json 2>/dev/null || true)"
if [ -z "$stray" ] && [ "$(panel_files)" = "$before" ]; then
  ok "4b. nothing written outside the panels dir, panels dir unchanged"
else
  bad "4b. stray file(s): $stray ; panels dir now: $(panel_files | tr '\n' ' ')"
fi
rm -f /tmp/traversal-abs.json 2>/dev/null

# ═══ 5. secret-shaped string -> whole panel refused, nothing written ═════
# PLAN L387-397: every string leaf (title + data strings) through
# bin/heimdall-activity's secret_shaped() (L167-179 there); a hit rejects the
# WHOLE panel; stderr names the field, never the value.
before="$(panel_files)"
n_ok=0; n_bad=""
try_secret() {  # $1 label, $2 id, $3 type, $4 title, $5 data
  ERR="$TMPROOT/secret-$2.err"
  if printf '%s' "$5" | panel set "$2" --type "$3" --title "$4" --data-json - 2>"$ERR"; then
    n_bad="$n_bad [$1: accepted]"
  elif [ -e "$PANELS/$2.json" ]; then
    n_bad="$n_bad [$1: refused but file written]"
  elif grep -qF "$SEC_STRIPE" "$ERR" || grep -qF "$SEC_AWS" "$ERR" || grep -qF "$SEC_ASSIGNED" "$ERR"; then
    n_bad="$n_bad [$1: stderr echoes the secret VALUE (L392: name the field, never the value)]"
  else
    n_ok=$((n_ok + 1))
  fi
}
try_secret stripe-kv-value   sec-1 kv       "Config"  "$(jq -cn --arg s "$SEC_STRIPE" '{rows:[["key",$s]]}')"
try_secret aws-log-line      sec-2 log-tail "Log"     "$(jq -cn --arg s "$SEC_AWS" '{lines:["boot ok", $s]}')"
try_secret assigned-markdown sec-3 markdown "Notes"   "$(jq -cn --arg s "$SEC_ASSIGNED" '{text:("env: " + $s)}')"
try_secret stripe-title      sec-4 number   "$SEC_STRIPE" '{"value":1}'
try_secret stripe-table-cell sec-5 table    "Table"   "$(jq -cn --arg s "$SEC_STRIPE" '{columns:["k","v"],rows:[["a",$s]]}')"
try_secret stripe-bar-label  sec-6 bars     "Bars"    "$(jq -cn --arg s "$SEC_STRIPE" '{labels:[$s],values:[1]}')"
if [ "$n_ok" = "6" ] && [ "$(panel_files)" = "$before" ]; then
  ok "5. 6/6 secret-shaped leaves refused (kv value, log line, markdown, title, table cell, bar label), nothing written, value never echoed (L387-397; heimdall-activity:167-179 shapes: Stripe, AWS, assigned-credential)"
else
  bad "5. secret scrub gaps:$n_bad ; panels dir delta: $(diff <(printf '%s' "$before") <(panel_files) | tr '\n' ' ')"
fi
# a planted FILE carrying a secret leaf is dropped and the secret never reaches any output
jq -cn --arg s "$SEC_STRIPE" --argjson n "$(date +%s)" \
  '{id:"planted-secret",title:"Planted",type:"kv",data:{rows:[["k",$s]]},refresh_s:60,updated_at:$n}' \
  > "$PANELS/planted-secret.json"
sleep 4.5
get_state >/dev/null
if ! jq -e '[.panels[].id] | index("planted-secret")' "$STATE" >/dev/null 2>&1 && ! grep -qF "$SEC_STRIPE" "$STATE"; then
  ok "5b. a planted FILE with a secret-shaped leaf is dropped; the value is nowhere in /api/state (fail-closed, L393-395)"
else
  bad "5b. planted secret panel served or value leaked: $(jq -c '[.panels[]|select(.id=="planted-secret")|.id]' "$STATE")"
fi
rm -f "$PANELS/planted-secret.json"
# numeric leaves are NOT string-scanned (L390: "NOT numeric x/y values") -- a
# large numeric series must not be mistaken for a credential
if printf '{"x":[1758276286,1758279886],"y":[1234567890123456,9876543210987654]}' \
     | panel set numeric-ok --type timeseries --title "Big numbers" --data-json - 2>/dev/null; then
  ok "5c. numeric x/y leaves are not scrubbed as strings (L390)"
else
  bad "5c. a purely numeric timeseries was refused"
fi
panel rm numeric-ok >/dev/null 2>&1

# ═══ 6. size caps ═════════════════════════════════════════════════════════
# PLAN L357-366 (+ L318 MAX_SERIES). Per-panel caps only: Decision 6 defines no
# cross-panel total, so none is asserted (brief/PLAN drift recorded in header).
before="$(panel_files)"
cap_ok=0; cap_bad=""
try_cap() {  # $1 label, $2 id, $3 type, $4 title, $5 data(file)
  if panel set "$2" --type "$3" --title "$4" --data-json "$5" 2>/dev/null; then
    cap_bad="$cap_bad [$1: accepted]"
  elif [ -e "$PANELS/$2.json" ]; then
    cap_bad="$cap_bad [$1: refused but written]"
  else
    cap_ok=$((cap_ok + 1))
  fi
}
jq -cn '{rows: [range(201) | ["k\(.)", "v"]]}'                         > "$TMPROOT/cap-rows.json"      # 201 > MAX_LIST_ITEMS (L365)
jq -cn '{lines: [range(201) | "l\(.)"]}'                                > "$TMPROOT/cap-lines.json"     # 201 log-tail lines (L339, L365)
jq -cn '{lines: [("x" * 501)]}'                                         > "$TMPROOT/cap-string.json"    # 501 > MAX_STRING_CHARS (L363)
jq -cn '{series: [range(7) | {name:"s\(.)", x:[1], y:[1]}]}'            > "$TMPROOT/cap-series.json"    # 7 > MAX_SERIES (L318)
jq -cn '{lines: [range(200) | ("y" * 400)]}'                            > "$TMPROOT/cap-bytes.json"     # 200*400 = 80000 > 65536 (L359), each leaf < 500
printf '{"value":1}'                                                     > "$TMPROOT/cap-title.json"
LONG_TITLE="$(printf 't%.0s' $(seq 1 121))"                                                              # 121 > MAX_TITLE_CHARS (L361)
try_cap list-items-201  cap-1 kv         "Rows"       "$TMPROOT/cap-rows.json"
try_cap log-lines-201   cap-2 log-tail   "Lines"      "$TMPROOT/cap-lines.json"
try_cap string-501      cap-3 log-tail   "String"     "$TMPROOT/cap-string.json"
try_cap series-7        cap-4 timeseries "Series"     "$TMPROOT/cap-series.json"
try_cap file-bytes-80k  cap-5 log-tail   "Bytes"      "$TMPROOT/cap-bytes.json"
try_cap title-121       cap-6 number     "$LONG_TITLE" "$TMPROOT/cap-title.json"
if [ "$cap_ok" = "6" ] && [ "$(panel_files)" = "$before" ]; then
  ok "6. 6/6 over-cap payloads refused: 201 rows, 201 lines, 501-char leaf, 7 series, 80KB file, 121-char title (L318, L357-366)"
else
  bad "6. cap gaps:$cap_bad"
fi
# exactly-at-cap is fine (200 items, 500 chars, 6 series, 120-char title)
jq -cn '{lines: [range(100) | ("z" * 500)]}' > "$TMPROOT/atcap-lines.json"   # 100 lines x 500 chars ~ 50KB < 65536; 500 == MAX_STRING_CHARS
jq -cn '{rows: [range(200) | ["k\(.)", "v"]]}' > "$TMPROOT/atcap-rows.json"
jq -cn '{series: [range(6) | {name:"s\(.)", x:[1], y:[1]}]}' > "$TMPROOT/atcap-series.json"
AT_TITLE="$(printf 't%.0s' $(seq 1 120))"
if panel set atcap-1 --type log-tail --title "At cap" --data-json "$TMPROOT/atcap-lines.json" 2>/dev/null \
   && panel set atcap-2 --type kv --title "$AT_TITLE" --data-json "$TMPROOT/atcap-rows.json" 2>/dev/null \
   && panel set atcap-3 --type bars --title "Six" --data-json "$TMPROOT/atcap-series.json" 2>/dev/null; then
  ok "6b. exactly-at-cap payloads accepted: 200 rows, 500-char leaf, 6 series, 120-char title (caps are >, not >=)"
else
  bad "6b. an exactly-at-cap payload was refused (cap implemented as >= instead of >)"
fi
for id in atcap-1 atcap-2 atcap-3; do panel rm "$id" >/dev/null 2>&1; done

# ═══ 7. staleness + TTL ═══════════════════════════════════════════════════
# PLAN L370-376: stale once now - updated_at > max(refresh_s*3, 30).
# PLAN L399-404: updated_at older than 86400s -> file auto-deleted on next poll.
if printf '{"value":1}' | panel set stale-demo --type number --title "Stale" --data-json - --refresh-s 1 2>/dev/null \
   && state_until '.panels[] | select(.id=="stale-demo") | .stale==false' 6; then
  ok "7. stale-demo (refresh_s=1) fresh -> stale==false"
else
  bad "7. stale-demo not served fresh: $(jq -c '[.panels[]|select(.id=="stale-demo")]' "$STATE" 2>/dev/null)"
fi
# backdate 20s: under max(3,30)=30 -> still fresh (refresh_s*3 is NOT the floor)
now="$(date +%s)"
jq --argjson t "$((now - 20))" '.updated_at=$t' "$PANELS/stale-demo.json" > "$PANELS/stale-demo.json.tmp.$$" \
  && mv -f "$PANELS/stale-demo.json.tmp.$$" "$PANELS/stale-demo.json"
sleep 4.5
get_state >/dev/null
if jq -e '.panels[] | select(.id=="stale-demo") | .stale==false' "$STATE" >/dev/null 2>&1; then
  ok "7b. backdated 20s with refresh_s=1: still fresh (threshold is max(3, 30)=30s, L373)"
else
  bad "7b. 20s old with refresh_s=1 marked stale -- the 30s floor is missing: $(jq -c '[.panels[]|select(.id=="stale-demo")|{stale,updated_at}]' "$STATE")"
fi
# backdate 100s: over 30 -> stale, still served (not TTL-reaped)
now="$(date +%s)"
jq --argjson t "$((now - 100))" '.updated_at=$t' "$PANELS/stale-demo.json" > "$PANELS/stale-demo.json.tmp.$$" \
  && mv -f "$PANELS/stale-demo.json.tmp.$$" "$PANELS/stale-demo.json"
if state_until '.panels[] | select(.id=="stale-demo") | .stale==true' 6; then
  ok "7c. backdated 100s -> stale==true within one poll, panel still served (L372-373)"
else
  bad "7c. 100s old not marked stale: $(jq -c '[.panels[]|select(.id=="stale-demo")|{stale,updated_at}]' "$STATE")"
fi
# a large refresh_s raises the threshold: refresh_s=60 -> 180s; 100s old is fresh
if printf '{"value":1}' | panel set slow-demo --type number --title "Slow" --data-json - --refresh-s 60 2>/dev/null; then
  now="$(date +%s)"
  jq --argjson t "$((now - 100))" '.updated_at=$t' "$PANELS/slow-demo.json" > "$PANELS/slow-demo.json.tmp.$$" \
    && mv -f "$PANELS/slow-demo.json.tmp.$$" "$PANELS/slow-demo.json"
  sleep 4.5
  get_state >/dev/null
  if jq -e '.panels[] | select(.id=="slow-demo") | .stale==false' "$STATE" >/dev/null 2>&1; then
    ok "7d. refresh_s=60, 100s old -> fresh (threshold refresh_s*3=180s, L373)"
  else
    bad "7d. refresh_s=60 at 100s old marked stale -- refresh_s is not tuning the threshold"
  fi
  panel rm slow-demo >/dev/null 2>&1
else
  bad "7d. could not set slow-demo"
fi
# TTL: 90000s old -> the server deletes the FILE on its next poll
if printf '{"value":1}' | panel set ttl-demo --type number --title "TTL" --data-json - 2>/dev/null; then
  now="$(date +%s)"
  jq --argjson t "$((now - 90000))" '.updated_at=$t' "$PANELS/ttl-demo.json" > "$PANELS/ttl-demo.json.tmp.$$" \
    && mv -f "$PANELS/ttl-demo.json.tmp.$$" "$PANELS/ttl-demo.json"
  if gone_within "$PANELS/ttl-demo.json" 6; then
    get_state >/dev/null
    if ! jq -e '[.panels[].id] | index("ttl-demo")' "$STATE" >/dev/null 2>&1; then
      ok "7e. updated_at 90000s old -> file auto-deleted within one poll and not served (PANEL_TTL_SECONDS=86400, L399-404)"
    else
      bad "7e. TTL file deleted but ttl-demo still served"
    fi
  else
    bad "7e. ttl-demo.json (updated_at 90000s old) still on disk 6s later -- no TTL reap"
  fi
else
  bad "7e. could not set ttl-demo"
fi
# missing updated_at is invalid (L370-371: required) -> dropped, server alive
cp "$FIXTURES/invalid-no-updated-at.json" "$PANELS/planted-no-updated-at.json"
printf '{"id":"planted-not-json","type":"number",\n' > "$PANELS/planted-not-json.json"
sleep 4.5
rc="$(get_state)"
if [ "$rc" = "200" ] && ! jq -e '[.panels[].id] | (index("planted-no-updated-at") or index("planted-not-json"))' "$STATE" >/dev/null 2>&1 \
   && kill -0 "$SRV_PID" 2>/dev/null; then
  ok "7f. missing updated_at and unparsable JSON are dropped; server still 200 and alive (L370-371, L519)"
else
  bad "7f. rc=$rc alive=$(kill -0 "$SRV_PID" 2>/dev/null && echo yes || echo no) ids=$(jq -c '[.panels[].id]' "$STATE" 2>/dev/null)"
fi
rm -f "$PANELS/planted-no-updated-at.json" "$PANELS/planted-not-json.json"

# ═══ 8. rm deletes the file; next /api/state lacks it; ls (optional) ══════
# PLAN L399-400 (`rm` is the clean path), L732; L847 (no `ls` this cycle).
if printf '{"x":[1,2,3],"y":[4,5,6]}' | panel set demo --type timeseries --title Demo --data-json - 2>/dev/null \
   && [ -f "$PANELS/demo.json" ] && state_until '[.panels[].id] | index("demo")' 6; then
  ok "8. L726 verbatim: set demo --type timeseries --title Demo --data-json - -> exit 0, .heimdall/ui/panels/demo.json exists, served"
else
  bad "8. demo set/serve failed"
fi
LS_OUT="$TMPROOT/ls.out"
if panel ls >"$LS_OUT" 2>&1; then
  if grep -q '^demo$\|"demo"\|\bdemo\b' "$LS_OUT" && grep -q 'rt-kv' "$LS_OUT"; then
    ok "8b. panel ls exists and lists ids (demo, rt-kv)"
  else
    bad "8b. panel ls exited 0 but does not list the ids: $(head -c 300 "$LS_OUT")"
  fi
else
  ok "8b. panel ls is not built (PLAN L847: listing subcommand not required this cycle; the brief asked for it -- drift recorded)"
fi
if panel rm demo 2>/dev/null && [ ! -e "$PANELS/demo.json" ]; then
  if state_until '[.panels[].id] | index("demo") | not' 6; then
    ok "8c. panel rm demo -> file removed, next /api/state no longer lists demo (L732)"
  else
    bad "8c. file removed but demo still served 6s later"
  fi
else
  bad "8c. panel rm demo failed or left the file: $(ls "$PANELS/demo.json" 2>&1)"
fi
# one-writer atomic convention (L377-386): an orphaned <id>.json.<pid>.tmp is
# never served and is reaped (age > presence's 120s, dead pid), the live .json untouched
printf '{"id":"rt-kv","type":"kv","data":{"rows":[]},"updated_at":1}' > "$PANELS/rt-kv.json.99999.tmp"
touch -t 202001010000 "$PANELS/rt-kv.json.99999.tmp"
live_before="$(cat "$PANELS/rt-kv.json")"
sleep 4.5
get_state >/dev/null
if jq -e '[.panels[] | select(.id=="rt-kv")] | length == 1 and .[0].data.rows|length == 3' "$STATE" >/dev/null 2>&1 \
   && [ "$(cat "$PANELS/rt-kv.json")" = "$live_before" ]; then
  ok "8d. an orphaned rt-kv.json.99999.tmp is not served as a panel and the live rt-kv.json is untouched (L379-386)"
else
  bad "8d. orphan .tmp leaked into panels or the live file changed: $(jq -c '[.panels[]|select(.id=="rt-kv")|.data.rows|length]' "$STATE")"
fi
if gone_within "$PANELS/rt-kv.json.99999.tmp" 6; then
  ok "8e. the orphaned .tmp (mtime 2020, pid 99999 dead) was reaped (L384-386, presence reaper precedent)"
else
  bad "8e. orphaned .tmp still present after >2 polls"
fi
rm -f "$PANELS/rt-kv.json.99999.tmp"

# ═══ 9. SSE: a set produces a frame within one poll; idle produces none ═══
# PLAN L515-517 (every SSE frame carries panels), L713 (within one poll cycle),
# Decision 2 L105-113 (digest-diff: no frame when nothing changed).
EV_BODY="$TMPROOT/events.body"; : > "$EV_BODY"
curl -sN -m 40 -o "$EV_BODY" "$BASE/api/events?$AUTH" &
EV_PID=$!
PIDS+=("$EV_PID")
if wait_for "$EV_BODY" '^data: ' 6; then
  n0="$(grep -c '^data: ' "$EV_BODY")"
  first="$(grep '^data: ' "$EV_BODY" | head -1 | sed 's/^data: //')"
  if printf '%s' "$first" | jq -e '(.panels|type)=="array" and has("schema_version")' >/dev/null 2>&1; then
    ok "9. first SSE frame carries the panels array alongside the Wave-1 object (L515-517)"
  else
    bad "9. first SSE frame lacks panels: ${first:0:200}"
  fi
  printf '{"value":99}' | panel set sse-demo --type number --title "SSE" --data-json - 2>/dev/null
  i=0; got=0
  while [ "$i" -lt 30 ]; do
    if grep '^data: ' "$EV_BODY" | tail -1 | sed 's/^data: //' | jq -e '.panels[] | select(.id=="sse-demo") | .data.value==99' >/dev/null 2>&1; then got=1; break; fi
    sleep 0.2; i=$((i + 1))
  done
  if [ "$got" = "1" ]; then
    ok "9b. after panel set sse-demo, a frame carrying it (value 99) arrived within 6s (L713)"
  else
    bad "9b. no SSE frame carrying sse-demo within 6s (frames so far: $(grep -c '^data: ' "$EV_BODY"))"
  fi
  sleep 1   # let any frame from the set itself land before measuring idle
  n1="$(grep -c '^data: ' "$EV_BODY")"
  sleep 4.5
  n2="$(grep -c '^data: ' "$EV_BODY")"
  if [ "$n2" -eq "$n1" ]; then
    ok "9c. idle 4.5s (> two 2s polls) produced NO extra frame -- digest-diff holds with panels present (L110-113)"
  else
    # diagnose: is the churn ONLY the server's own hmd-live-users updated_at?
    a="$(grep '^data: ' "$EV_BODY" | tail -2 | head -1 | sed 's/^data: //' | jq -c 'del(.ts) | .panels |= map(select(.id!="hmd-live-users"))' 2>/dev/null)"
    b="$(grep '^data: ' "$EV_BODY" | tail -1 | sed 's/^data: //' | jq -c 'del(.ts) | .panels |= map(select(.id!="hmd-live-users"))' 2>/dev/null)"
    if [ -n "$a" ] && [ "$a" = "$b" ]; then
      bad "9c. $((n2 - n1)) idle frame(s): consecutive frames differ ONLY in hmd-live-users -- PLAN L697 (updated_at=now every tick) contradicts Decision 2's digest-diff (L110-113); the self-published panel must not churn the digest"
    else
      bad "9c. $((n2 - n1)) frame(s) arrived while nothing changed (digest-diff broken)"
    fi
  fi
  if leak="$(contains_sentinel "$EV_BODY")"; then
    bad "9d. SSE stream leaks planted deny-list secret $leak"
  else
    ok "9d. SSE stream carries no deny-list sentinel"
  fi
else
  bad "9. no data: frame on /api/events within 6s"
fi
kill "$EV_PID" 2>/dev/null; wait "$EV_PID" 2>/dev/null
panel rm sse-demo >/dev/null 2>&1

# ═══ 10. no server-side injection; data reaches the browser only as data ═══
# PLAN L406-412, L435-439: the page is static; panel data arrives via
# /api/state / SSE and is rendered escape-first, never into innerHTML raw.
# PLAN L730: a markdown panel with <script>alert(1)</script> never appears
# unescaped in the served page. (The "eventual DOM output" of L730 needs a
# browser; the served source + a structural innerHTML audit are the stand-in.)
INLINE="hmd-panel-inline-sentinel-$(date +%s)-$RANDOM"
XSS='<script>alert(1)</script>'
jq -cn --arg s "<b>x</b>$INLINE" '{text:$s}'  | panel set html-demo --type markdown --title "HTML-ish" --data-json - 2>/dev/null
jq -cn --arg s "$XSS" '{text:$s}'              | panel set xss-demo  --type markdown --title "XSS" --data-json - 2>/dev/null
jq -cn --arg s "$XSS" '{columns:["c"],rows:[[$s]]}' | panel set xss-table --type table --title "$XSS" --data-json - 2>/dev/null
jq --argjson n "$(date +%s)" '.updated_at=$n' "$FIXTURES/valid-markdown-xss.json" > "$PANELS/planted-xss.json"
if state_until '(.panels[] | select(.id=="xss-demo") | .data.text) == "<script>alert(1)</script>"
                and ((.panels[] | select(.id=="html-demo") | .data.text) | startswith("<b>x</b>"))
                and ([.panels[].id] | index("planted-xss")) != null' 6; then
  ok "10. /api/state returns HTML-looking text as DATA, byte-exact (<b>x</b>, <script>alert(1)</script>; markdown text is not secret-shaped)"
else
  bad "10. HTML-looking data did not round-trip: $(jq -c '[.panels[]|select(.id=="xss-demo" or .id=="html-demo" or .id=="planted-xss")|{id,text:.data.text}]' "$STATE" 2>/dev/null)"
fi
PAGE="$TMPROOT/page.html"
rc="$(curl -s -o "$PAGE" -w '%{http_code}' "$BASE/?$AUTH")"
if [ "$rc" = "200" ] && ! grep -qF "$INLINE" "$PAGE" && ! grep -qF '<script>alert' "$PAGE" && ! grep -qF 'Round trip kv' "$PAGE"; then
  ok "10b. GET / carries no panel data inline: no sentinel, no <script>alert, no panel title (data arrives only via /api/state or SSE)"
else
  bad "10b. rc=$rc; served HTML embeds panel data: sentinel=$(grep -cF "$INLINE" "$PAGE") script=$(grep -cF '<script>alert' "$PAGE") title=$(grep -cF 'Round trip kv' "$PAGE")"
fi
if grep -qi 'panels' "$PAGE"; then
  ok "10c. the served page has a panels rendering section (L712)"
else
  bad "10c. served page never mentions panels -- no renderer shipped"
fi
# structural audit: every innerHTML assignment must not take a raw panel-data
# expression. Allowed: a constant/template with no data reference, or an
# expression that visibly passes through an escape helper on the same line.
RAW_SINK="$(grep -n 'innerHTML' "$PAGE" \
  | grep -E '\.(data|text|rows|lines|columns|labels|values|title|value|series|name)\b' \
  | grep -Eiv 'esc|escape|sanit|textContent' || true)"
if [ -z "$RAW_SINK" ]; then
  ok "10d. no innerHTML sink takes a panel-data field without an escape call on the same line (L328-336, L408-410, L435-439)"
else
  bad "10d. innerHTML fed panel data with no visible escape (L408-410):"
  printf '%s\n' "$RAW_SINK" | head -5 | sed 's/^/       | /'
fi
if grep -Eq 'textContent|createTextNode|replace\(/&/g|&amp;' "$PAGE"; then
  ok "10e. the page contains an HTML-escaping primitive (textContent/createTextNode/&-entity replace)"
else
  bad "10e. no escaping primitive found in the served page -- escape-first (L329-331) cannot be implemented"
fi
for id in html-demo xss-demo xss-table; do panel rm "$id" >/dev/null 2>&1; done
rm -f "$PANELS/planted-xss.json"

# ═══ 11. the three worked examples, as the PLAN writes them ═══════════════
# (a) L793-802: sqlite3 -> jq -> timeseries via HEIMDALL_WATCH_ROOT
DB="$TMPROOT/demo.db"
sqlite3 "$DB" "create table orders(id integer primary key, created_at text);
  insert into orders(created_at) values ('2026-09-19 09:05:00'),('2026-09-19 09:40:00'),('2026-09-19 10:10:00');"
if sqlite3 -json "$DB" "select strftime('%Y-%m-%dT%H:00:00Z',created_at) h, count(*) c from orders group by h order by h" \
     | jq -c '{x:[.[].h], y:[.[].c]}' \
     | HEIMDALL_WATCH_ROOT="$FIX" "$UI" panel set db-orders-per-hour --type timeseries --title "Orders / hour" --data-json - 2>"$TMPROOT/ex-a.err" \
   && test -f "$FIX/.heimdall/ui/panels/db-orders-per-hour.json" \
   && jq -e '.type=="timeseries" and (.data.x|length)==(.data.y|length)' "$FIX/.heimdall/ui/panels/db-orders-per-hour.json" >/dev/null \
   && state_until '.panels[] | select(.id=="db-orders-per-hour") | .data.y == [2,1]' 6; then
  ok "11a. worked example (a) sqlite3->jq->timeseries, root via HEIMDALL_WATCH_ROOT (L793-802), served with y==[2,1]"
else
  bad "11a. worked example (a) failed: $(head -c 300 "$TMPROOT/ex-a.err") served=$(jq -c '[.panels[]|select(.id=="db-orders-per-hour")|.data]' "$STATE" 2>/dev/null)"
fi
# (b) L804-813: roster count -> number, cwd-rooted. The presence roster is what
# the server already computes; in this hermetic fixture the same count comes
# from the planted roster-cache (1 entry), piped through L809's jq verbatim.
if ( cd "$FIX" && jq -c '{value: length}' .heimdall/roster-cache.json \
       | "$UI" panel set hmd-live-users --type number --title "hmd — live users" --data-json - ) 2>"$TMPROOT/ex-b.err" \
   && ( cd "$FIX" && jq -e '.type=="number" and (.data.value|type=="number") and .data.value>=0' .heimdall/ui/panels/hmd-live-users.json >/dev/null ); then
  ok "11b. worked example (b) roster-count->number, cwd-rooted, manual publish to hmd-live-users (L807-810)"
else
  bad "11b. worked example (b) failed: $(head -c 300 "$TMPROOT/ex-b.err")"
fi
# (c) L815-830: kv from CHECKPOINT.md header + log-tail from the activity ledger, cwd-rooted
if ( cd "$FIX" \
     && BR="$(git rev-parse --abbrev-ref HEAD)" && HD="$(git rev-parse --short HEAD)" \
     && PH="$(grep -m1 '^- \*\*Phase:\*\*\|^Phase:' .planning/CHECKPOINT.md | sed 's/^- \*\*Phase:\*\* *//; s/^Phase: *//')" \
     && jq -cn --arg b "$BR" --arg h "$HD" --arg p "$PH" '{rows:[["Branch",$b],["HEAD",$h],["Phase",$p]]}' \
        | "$UI" panel set task-progress --type kv --title "Task progress" --data-json - \
     && jq -e '.type=="kv" and (.data.rows|length)==3' .heimdall/ui/panels/task-progress.json >/dev/null \
     && jq -cs '{lines: (map("\(.active_task // "-") @ \(.branch // "-")") | .[:200])}' .planning/ledger/activity/*.json 2>/dev/null \
        | "$UI" panel set task-log --type log-tail --title "Recent activity" --data-json - \
     && jq -e '.type=="log-tail" and (.data.lines|length) <= 200' .heimdall/ui/panels/task-log.json >/dev/null ) 2>"$TMPROOT/ex-c.err" \
   && state_until '(.panels[] | select(.id=="task-progress") | .data.rows[2][1]) == "fixture-phase"
                   and (.panels[] | select(.id=="task-log") | .data.lines[0]) == "fixture-task @ fixture-branch"' 6; then
  ok "11c. worked example (c) kv (Branch/HEAD/Phase) + log-tail (activity ledger), both served (L815-830)"
else
  bad "11c. worked example (c) failed: $(head -c 300 "$TMPROOT/ex-c.err") served=$(jq -c '[.panels[]|select(.id=="task-progress" or .id=="task-log")|{id,data}]' "$STATE" 2>/dev/null | head -c 300)"
fi

# ═══ 13. --print-sources names the panels dir; still no deny-list path ═════
# PLAN L519-520 (panels dir is a read source); Wave-1 L70-71/L208 deny-list.
PS_OUT="$TMPROOT/print-sources.out"
( cd "$FIX" && HEIMDALL_WATCH_ROOT="$FIX" exec "$UI" --repo "$FIX" --print-sources ) >"$PS_OUT" 2>&1 &
PS_PID=$!
i=0
while kill -0 "$PS_PID" 2>/dev/null && [ "$i" -lt 50 ]; do sleep 0.2; i=$((i + 1)); done
if kill -0 "$PS_PID" 2>/dev/null; then
  kill "$PS_PID" 2>/dev/null; wait "$PS_PID" 2>/dev/null
  bad "13. --print-sources did not exit within 10s"
else
  wait "$PS_PID" 2>/dev/null; ps_rc=$?
  if [ "$ps_rc" = "0" ] && grep -q 'ui/panels' "$PS_OUT"; then
    ok "13. --print-sources exits 0 and names .heimdall/ui/panels (L519-520)"
  else
    bad "13. --print-sources rc=$ps_rc, no ui/panels line; output:"; sed 's/^/       | /' "$PS_OUT" | head -20
  fi
  denied="$(grep -Ei 'team\.json|\.key\b|key\.pem|\.seed\b|\.omniroute|\.env(\.|$|[[:space:]])|settings\.json' "$PS_OUT" || true)"
  if [ -z "$denied" ]; then
    ok "13b. --print-sources still names no team.json / *.key / key.pem / *.seed / .omniroute / .env* / settings.json"
  else
    bad "13b. --print-sources lists a deny-listed path:"; printf '%s\n' "$denied" | sed 's/^/       | /'
  fi
fi

# ═══ final: state + page never carried a deny-list sentinel ═══════════════
get_state >/dev/null
if leak="$(contains_sentinel "$STATE")" || leak="$(contains_sentinel "$PAGE")"; then
  bad "14. a deny-list sentinel ($leak) reached /api/state or the page via the panel surface"
else
  ok "14. no deny-list sentinel in /api/state or the served page"
fi
if kill -0 "$SRV_PID" 2>/dev/null; then
  ok "15. server survived every malformed/planted/oversize/secret payload"
else
  bad "15. server died during the run; tail of its output:"; tail -5 "$SRV_OUT" | sed 's/^/       | /'
fi

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
