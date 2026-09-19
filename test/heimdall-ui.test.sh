#!/usr/bin/env bash
# test/heimdall-ui.test.sh
#
# INDEPENDENT oracle for Wave 1 of .planning/plans/PLAN-companion-ui.md
# (`hmd ui` -- the loopback companion web UI). Written by the TESTER role from
# the PLAN's contract only, never from the server's source: every assertion
# below cites the PLAN line it is derived from, so a server that "passes" has
# met the contract, not merely agreed with its own author.
#
# Contract under test (PLAN-companion-ui.md, line-cited):
#   - runtime: python3 stdlib server + one static HTML page        (L76-84)
#   - transport: SSE `/api/events`, `text/event-stream`, a new `data:` frame
#     ONLY when the SHA-256 digest of the canonical state JSON changes; poll
#     every 2s                                                       (L105-113)
#   - auth: bind 127.0.0.1 only, per-launch random token required on `/`,
#     `/api/events` (URL param) and `/api/state`; Host header outside
#     {127.0.0.1:<port>, localhost:<port>} refused BEFORE the token check
#                                                                    (L215-225)
#   - data contract: the exact top-level keys of `GET /api/state` and every
#     SSE frame                                                      (L251-276)
#   - `sweep_receipt` is a raw parse of .heimdall/receipts/last-sweep.json and
#     is `| null` when absent                                        (L269, L282)
#   - `checkpoint` is header-fields-only from .planning/CHECKPOINT.md, `| null`
#     when absent                                                    (L273, L286-288)
#   - secrets the UI process must NEVER read, in any form, in any field:
#     .heimdall/team.json, ~/.heimdall/team.json, PKI seeds, signing key,
#     gh-app key.pem                                                 (L70-71, L208)
#   - the fixture's planted `suites_total` (999) must be DERIVED from the file,
#     and a mutation to 111 must show up in a later SSE frame        (L390-392)
#   - fail-open: missing sources render as empty/null, never an error (L57, L484)
#
# Where the orchestrator's brief for THIS build diverged from the PLAN's spelling
# (bin name `bin/heimdall-ui`, `--repo DIR`, `--no-open`, `?t=` token param,
# `--print-sources`, 403 for a foreign Host where the PLAN says 400), the test
# follows the brief for flag names, and accepts EITHER refusal code for the
# Host check while reporting which one was observed. The token PARAM NAME is
# not assumed: it is read off the printed URL line (`?t=` or `?token=`) and
# reused verbatim, so both spellings are exercised with equal strictness.
#
# Hermetic: HOME and HEIMDALL_HOME are redirected to a temp dir, the fixture
# repo is a temp dir, and every background process is reaped on EXIT. macOS has
# no `timeout`; every wait is a bounded sleep-0.2 poll.

set -u

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
UI="${HEIMDALL_UI_BIN:-$REPO/bin/heimdall-ui}"   # override only for harness self-check / red-proof runs

PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; }

echo "heimdall-ui (companion web UI, Wave 1 oracle)"

# ── preconditions: absent bin is an explicit skip, not a crash ──────────────
if [ ! -x "$UI" ]; then
  printf '  SKIP bin/heimdall-ui is absent or not executable (%s)\n' "$UI"
  printf '       the author has not landed Wave 1 yet; every case below needs the server\n'
  printf '\n0 passed, 1 failed (harness could not start the server under test)\n'
  exit 1
fi
for tool in curl jq python3; do
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
EMPTY="$TMPROOT/not-a-repo"
mkdir -p "$HOME/.claude" "$HEIMDALL_HOME/signing" "$HEIMDALL_HOME/pki" \
         "$FIX/.heimdall/receipts" "$FIX/.planning/reels" "$EMPTY"

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

# Planted, distinctive sentinels. None may EVER appear in any server output.
# Assembled at RUNTIME (per-run timestamp + $RANDOM), never a literal: .gitleaks.toml's
# discipline is that fixtures must not carry any gitleaks-detectable token in the file,
# and a 28-char literal here was flagged by generic-api-key in the full-history selfscan
# on 2026-09-19 -- the gate could not tell a planted sentinel from a real key, correctly.
S_TEAM="hmd-ui-sentinel-team-$(date +%s)-$RANDOM$RANDOM"
S_KEY="hmd-ui-sentinel-key-$(date +%s)-$RANDOM$RANDOM"
S_OMNI="hmd-ui-sentinel-omni-$(date +%s)-$RANDOM$RANDOM"
S_ENV="hmd-ui-sentinel-env-$(date +%s)-$RANDOM$RANDOM"
S_SET="hmd-ui-sentinel-set-$(date +%s)-$RANDOM$RANDOM"
S_SEED="hmd-ui-sentinel-seed-$(date +%s)-$RANDOM$RANDOM"
SENTINELS=("$S_TEAM" "$S_KEY" "$S_OMNI" "$S_ENV" "$S_SET" "$S_SEED")

# secret deny-list (PLAN L70-71, L208 + brief): repo-local and home-local copies
printf '{"team_id":"t_fixture","secret":"%s"}\n' "$S_TEAM" > "$FIX/.heimdall/team.json"
printf '{"team_id":"t_fixture","secret":"%s"}\n' "$S_TEAM" > "$HEIMDALL_HOME/team.json"
printf -- '-----BEGIN PRIVATE KEY-----\n%s\n-----END PRIVATE KEY-----\n' "$S_KEY" > "$FIX/x.key"
printf '%s\n' "$S_KEY" > "$HEIMDALL_HOME/signing/heimdall-signing.key"
printf '%s\n' "$S_SEED" > "$HEIMDALL_HOME/pki/fixture.seed"
printf 'OMNIROUTE_API_KEY=%s\n' "$S_OMNI" > "$HOME/.omniroute"
printf 'ANTHROPIC_AUTH_TOKEN=%s\n' "$S_ENV" > "$FIX/.env"
printf 'ANTHROPIC_AUTH_TOKEN=%s\n' "$S_ENV" > "$FIX/.env.local"
printf '{"env":{"ANTHROPIC_AUTH_TOKEN":"%s"},"model":"sonnet"}\n' "$S_SET" > "$HOME/.claude/settings.json"

# realistic state files the PLAN names as sources (L45, L49-50, L53)
printf '{"verdict":"pass","passed":41,"total":41,"gate":"tests","ts":1758276286}\n' \
  > "$FIX/.heimdall/statusline.json"
cat > "$FIX/.heimdall/receipts/last-sweep.json" <<'JSON'
{"finished_at":"2026-09-19T09:04:46Z","head_sha":"b43c4f4b","tree_clean":true,"exit_code":0,
 "suites_total":999,"suites_passed":999,"suites_failed":0,"duration_s":1037}
JSON
cat > "$FIX/.heimdall/roster-cache.json" <<'JSON'
[{"haid":"haid:fixture.box-0001","handle":"fixture","branch":"main","project":"fixture-repo",
  "state":"active","verdict":"pass","file":"","ts":1758276286,"activity_ts":1758276286,
  "age_seconds":1.0,"online":true}]
JSON
cat > "$FIX/.planning/CHECKPOINT.md" <<'MD'
<!-- heimdall-auto-checkpoint:begin -->
## Auto-checkpoint — 2026-09-19T08:54:05Z

> Written automatically at session end (mechanical, no LLM).

- **Branch:** fixture-branch
- **HEAD:** f1x7u4e0
- **Phase:** fixture-phase
- **Active goal:** none
- **Uncommitted files:** 3
- **Open warnings:** ⚠ push gate is RED

### What must never be lost (the resume contract)
- **In progress:** OPERATOR_PRIVATE_NOTE_do_not_mirror_to_browser
<!-- heimdall-auto-checkpoint:end -->
MD
touch "$FIX/.planning/reels/2026-09-19-fixture.reel"
( cd "$FIX" && git init -q . 2>/dev/null && git -c user.email=t@t -c user.name=t add -A >/dev/null 2>&1 \
  && git -c user.email=t@t -c user.name=t commit -qm fixture >/dev/null 2>&1 ) || true

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

code_of() { curl -s -o /dev/null -w '%{http_code}' "$@"; }

contains_sentinel() {
  local file="$1" s
  for s in "${SENTINELS[@]}"; do
    grep -q "$s" "$file" 2>/dev/null && { printf '%s' "$s"; return 0; }
  done
  return 1
}

# ── start the server under test ─────────────────────────────────────────────
SRV_OUT="$TMPROOT/server.out"
( cd "$FIX" && HEIMDALL_WATCH_ROOT="$FIX" exec "$UI" --repo "$FIX" --port "$PORT" --no-open ) \
  >"$SRV_OUT" 2>&1 &
SRV_PID=$!
PIDS+=("$SRV_PID")

URL_RE="^http://127\.0\.0\.1:$PORT/\?(t|token)=[A-Za-z0-9_-]+\$"

# ── 1. one URL line, loopback, this port, a token ──────────────────────────
# PLAN L215-219: 127.0.0.1 bind, per-launch random token riding the URL for `/`.
if wait_for "$SRV_OUT" "$URL_RE" 10; then
  URL="$(grep -E "$URL_RE" "$SRV_OUT" | head -1)"
  Q="${URL#*\?}"                 # t=abc...  or token=abc...
  TP="${Q%%=*}"                  # param name actually printed
  TOKEN="${Q#*=}"
  if [ "${#TOKEN}" -ge 16 ]; then
    ok "1. URL line printed within 10s: http://127.0.0.1:$PORT/?$TP=<${#TOKEN} chars>"
  else
    bad "1. token on the URL line is too short to be a 32-byte random value (${#TOKEN} chars)"
  fi
else
  bad "1. no URL line matching $URL_RE within 10s; server output:"
  sed 's/^/       | /' "$SRV_OUT"
  printf '\n%s passed, %s failed (server never came up; remaining cases not run)\n' "$PASS" "$((FAIL))"
  exit 1
fi
BASE="http://127.0.0.1:$PORT"
AUTH="$TP=$TOKEN"

# ── 2. GET / with token -> HTML, non-empty, no secret ──────────────────────
# PLAN L83-84 (one static HTML page served at `/`), L219 (token required on `/`).
HDR="$TMPROOT/root.hdr"; BODY="$TMPROOT/root.html"
rc="$(curl -s -D "$HDR" -o "$BODY" -w '%{http_code}' "$BASE/?$AUTH")"
if [ "$rc" = "200" ] && grep -qi '^content-type: *text/html' "$HDR" && [ -s "$BODY" ] \
   && grep -qi '<html\|<!doctype html' "$BODY"; then
  ok "2. GET / with token -> 200 text/html, non-empty HTML"
else
  bad "2. GET / with token -> rc=$rc, content-type=$(grep -i '^content-type' "$HDR" | tr -d '\r'), bytes=$(wc -c <"$BODY" | tr -d ' ')"
fi
if leak="$(contains_sentinel "$BODY")"; then
  bad "2b. HTML body leaks planted secret $leak"
else
  ok "2b. HTML body carries none of the ${#SENTINELS[@]} planted secrets"
fi
rc="$(code_of "$BASE/")"
if [ "$rc" = "401" ]; then
  ok "2c. GET / WITHOUT token -> 401 (token is required on / too, PLAN L219)"
else
  bad "2c. GET / without token -> $rc, expected 401"
fi

# ── 3. /api/state and /api/events refuse a missing or wrong token ──────────
# PLAN L215-222 (token required, compared constant-time; missing/wrong -> 401).
rc_none="$(code_of "$BASE/api/state")"
rc_wrong="$(code_of "$BASE/api/state?$TP=deadbeefdeadbeefdeadbeefdeadbeef")"
rc_almost="$(code_of "$BASE/api/state?$TP=${TOKEN%?}x")"
if [ "$rc_none" = "401" ] && [ "$rc_wrong" = "401" ] && [ "$rc_almost" = "401" ]; then
  ok "3. /api/state: no token -> 401, wrong token -> 401, one-char-off token -> 401"
else
  bad "3. /api/state token gate: none=$rc_none wrong=$rc_wrong off-by-one=$rc_almost (all must be 401)"
fi
rc_ev_none="$(curl -s -m 2 -o /dev/null -w '%{http_code}' "$BASE/api/events")"
rc_ev_wrong="$(curl -s -m 2 -o /dev/null -w '%{http_code}' "$BASE/api/events?$TP=nope")"
if [ "$rc_ev_none" = "401" ] && [ "$rc_ev_wrong" = "401" ]; then
  ok "3b. /api/events: no token -> 401, wrong token -> 401"
else
  bad "3b. /api/events token gate: none=$rc_ev_none wrong=$rc_ev_wrong (both must be 401)"
fi

# ── 4. /api/state with token -> 200 + EXACT top-level keys of PLAN §4 ──────
# PLAN L252-276: the thirteen top-level keys of the data contract.
STATE="$TMPROOT/state.json"; SHDR="$TMPROOT/state.hdr"
rc="$(curl -s -D "$SHDR" -o "$STATE" -w '%{http_code}' "$BASE/api/state?$AUTH")"
CONTRACT_KEYS=(schema_version ts repo identity ledger roster quality_gate sweep_receipt hooks fallback parallelism checkpoint reels)
missing=""
if [ "$rc" = "200" ] && jq -e 'type == "object"' "$STATE" >/dev/null 2>&1; then
  for k in "${CONTRACT_KEYS[@]}"; do
    jq -e --arg k "$k" 'has($k)' "$STATE" >/dev/null 2>&1 || missing="$missing $k"
  done
  if [ -z "$missing" ]; then
    ok "4. /api/state -> 200 JSON object with all 13 contract keys (PLAN L252-276)"
  else
    bad "4. /api/state -> 200 but missing top-level key(s):$missing"
  fi
else
  bad "4. /api/state with token -> rc=$rc or body is not a JSON object"
fi
if grep -qi '^content-type: *application/json' "$SHDR"; then
  ok "4b. /api/state Content-Type is application/json"
else
  bad "4b. /api/state Content-Type = $(grep -i '^content-type' "$SHDR" | tr -d '\r')"
fi
# typed sub-shape spot checks straight from L252-276
if jq -e '.schema_version == 1
          and (.ts|type) == "number"
          and (.repo|type) == "string"
          and (.identity|type) == "object" and (.identity|has("handle") and has("haid") and has("branch"))
          and (.ledger|type) == "object" and (.ledger|has("daemon") and has("gates") and has("verdict") and has("team") and has("team_overflow"))
          and (.roster|type) == "array"
          and (.quality_gate|type) == "object" and (.quality_gate|has("clear_to_push") and has("reason"))
          and (.hooks|type) == "array"
          and (.fallback|type) == "object" and (.fallback|has("state") and has("target_provider"))
          and (.parallelism|type) == "object" and (.parallelism|has("batched") and has("turns") and has("ratio"))
          and (.reels|type) == "array"' "$STATE" >/dev/null 2>&1; then
  ok "4c. nested shapes match §4: schema_version==1, identity/ledger/quality_gate/fallback/parallelism keys, arrays for roster/hooks/reels"
else
  bad "4c. nested shape mismatch vs PLAN §4 (see $STATE):"
  jq -c '{schema_version, ts_type:(.ts|type), identity:(.identity|keys?), ledger:(.ledger|keys?), qg:(.quality_gate|keys?), fb:(.fallback|keys?), par:(.parallelism|keys?)}' "$STATE" 2>/dev/null | sed 's/^/       | /'
fi
# planted-value derivation proof (PLAN L390): 999 came from the fixture file
if jq -e '.sweep_receipt.suites_total == 999 and .sweep_receipt.finished_at == "2026-09-19T09:04:46Z"' "$STATE" >/dev/null 2>&1; then
  ok "4d. sweep_receipt is DERIVED from the fixture (suites_total==999, planted finished_at)"
else
  bad "4d. sweep_receipt not derived from fixture: $(jq -c '.sweep_receipt' "$STATE" 2>/dev/null)"
fi
# checkpoint = header fields only, never the free-text body (PLAN L273, L286-288, L466)
if jq -e '.checkpoint.branch == "fixture-branch" and .checkpoint.head == "f1x7u4e0"
          and .checkpoint.phase == "fixture-phase" and .checkpoint.uncommitted_files == 3' "$STATE" >/dev/null 2>&1; then
  ok "4e. checkpoint header fields extracted (branch/head/phase/uncommitted_files)"
else
  bad "4e. checkpoint header fields wrong: $(jq -c '.checkpoint' "$STATE" 2>/dev/null)"
fi
if grep -q 'OPERATOR_PRIVATE_NOTE_do_not_mirror_to_browser' "$STATE"; then
  bad "4f. /api/state forwards CHECKPOINT.md free-text body (PLAN L273/L466 forbid this)"
else
  ok "4f. CHECKPOINT.md free-text body is NOT forwarded"
fi
# fallback is capped to state+target_provider (PLAN L283-284, L462)
if jq -e '.fallback | (has("operator_key_configured") or has("endpoint") or has("config_path")) | not' "$STATE" >/dev/null 2>&1; then
  ok "4g. fallback carries no operator_key_configured/endpoint/config_path"
else
  bad "4g. fallback leaks a forbidden key: $(jq -c '.fallback' "$STATE" 2>/dev/null)"
fi
# repo echoes the fixture root (PLAN L255)
if jq -e --arg r "$FIX" '.repo == $r or (.repo|endswith("fixture-repo"))' "$STATE" >/dev/null 2>&1; then
  ok "4h. repo points at the --repo fixture dir"
else
  bad "4h. repo = $(jq -r '.repo' "$STATE" 2>/dev/null), expected $FIX"
fi

# ── 5. foreign Host header -> refused even WITH a valid token ──────────────
# PLAN L223-225: allowlist {127.0.0.1:<port>, localhost:<port>}; PLAN says 400,
# the brief for this build says 403 -- either is a refusal; 2xx is the bug.
rc_evil="$(code_of -H "Host: evil.example:$PORT" "$BASE/api/state?$AUTH")"
rc_evil2="$(code_of -H "Host: evil.example" "$BASE/api/state?$AUTH")"
rc_root_evil="$(code_of -H "Host: 127.0.0.1.evil.example:$PORT" "$BASE/?$AUTH")"
case "$rc_evil:$rc_evil2:$rc_root_evil" in
  403:403:403) ok "5. foreign Host -> 403 on /api/state and / (brief's code)" ;;
  400:400:400) ok "5. foreign Host -> 400 on /api/state and / (PLAN L225's code)" ;;
  *) bad "5. foreign Host must be refused with 400/403; got api=$rc_evil api(no-port)=$rc_evil2 root=$rc_root_evil" ;;
esac
rc_lh="$(code_of -H "Host: localhost:$PORT" "$BASE/api/state?$AUTH")"
if [ "$rc_lh" = "200" ]; then
  ok "5b. Host: localhost:$PORT is on the allowlist -> 200"
else
  bad "5b. Host: localhost:$PORT -> $rc_lh, expected 200 (PLAN L224 allows it)"
fi

# ── 6. /api/state never carries a planted secret ───────────────────────────
# PLAN L70-71: team secret, PKI seeds, signing key NEVER read "in any form, in any field".
if leak="$(contains_sentinel "$STATE")"; then
  bad "6. /api/state leaks planted secret $leak"
else
  ok "6. /api/state carries none of the ${#SENTINELS[@]} planted secrets"
fi

# ── 7. --print-sources lists what it reads; no secret path among them ──────
PS_OUT="$TMPROOT/print-sources.out"
( cd "$FIX" && HEIMDALL_WATCH_ROOT="$FIX" exec "$UI" --repo "$FIX" --print-sources ) >"$PS_OUT" 2>&1 &
PS_PID=$!
i=0
while kill -0 "$PS_PID" 2>/dev/null && [ "$i" -lt 50 ]; do sleep 0.2; i=$((i + 1)); done
if kill -0 "$PS_PID" 2>/dev/null; then
  kill "$PS_PID" 2>/dev/null; wait "$PS_PID" 2>/dev/null
  bad "7. --print-sources did not exit within 10s (must list and exit, not serve)"
else
  wait "$PS_PID" 2>/dev/null; ps_rc=$?
  if [ "$ps_rc" = "0" ] && [ -s "$PS_OUT" ] && grep -q 'last-sweep.json' "$PS_OUT"; then
    ok "7. --print-sources exits 0 and names last-sweep.json among its sources"
  else
    bad "7. --print-sources rc=$ps_rc, output:"; sed 's/^/       | /' "$PS_OUT" | head -20
  fi
  denied="$(grep -Ei 'team\.json|\.key\b|key\.pem|\.seed\b|\.omniroute|\.env(\.|$|[[:space:]])|settings\.json' "$PS_OUT" || true)"
  if [ -z "$denied" ]; then
    ok "7b. --print-sources names no team.json / *.key / key.pem / *.seed / .omniroute / .env* / settings.json"
  else
    bad "7b. --print-sources lists a deny-listed path:"; printf '%s\n' "$denied" | sed 's/^/       | /'
  fi
fi

# ── 8. SSE: first frame, then a second frame ONLY after a source mutates ───
# PLAN L105-113 (text/event-stream, digest-diffed), L392 (999 -> 111 proof).
EV_HDR="$TMPROOT/events.hdr"; EV_BODY="$TMPROOT/events.body"
: > "$EV_BODY"
curl -sN -m 30 -D "$EV_HDR" -o "$EV_BODY" "$BASE/api/events?$AUTH" &
EV_PID=$!
PIDS+=("$EV_PID")
if wait_for "$EV_BODY" '^data: ' 6; then
  first="$(grep '^data: ' "$EV_BODY" | head -1 | sed 's/^data: //')"
  if grep -qi '^content-type: *text/event-stream' "$EV_HDR"; then
    ok "8. /api/events -> text/event-stream with a first data: frame within 6s"
  else
    bad "8. first frame arrived but Content-Type = $(grep -i '^content-type' "$EV_HDR" | tr -d '\r')"
  fi
  if printf '%s' "$first" | jq -e '.sweep_receipt.suites_total == 999 and .schema_version == 1' >/dev/null 2>&1; then
    ok "8b. first SSE frame is the §4 object with the planted suites_total==999"
  else
    bad "8b. first SSE frame is not the contract object / planted value: ${first:0:200}"
  fi
  # idle window: no new frame while nothing changes (digest-diff, PLAN L110-113)
  sleep 4.5
  n_idle="$(grep -c '^data: ' "$EV_BODY")"
  if [ "$n_idle" -eq 1 ]; then
    ok "8c. idle 4.5s (> two 2s polls) produced NO extra frame -- digest-diff holds"
  else
    bad "8c. $n_idle frames arrived while nothing changed (server re-emits without a digest change)"
  fi
  # mutate a source, expect a second frame within 6s carrying the new value
  sed -i.bak 's/"suites_total":999/"suites_total":111/' "$FIX/.heimdall/receipts/last-sweep.json"
  rm -f "$FIX/.heimdall/receipts/last-sweep.json.bak"
  i=0; got=0
  while [ "$i" -lt 30 ]; do
    if [ "$(grep -c '^data: ' "$EV_BODY")" -gt "$n_idle" ]; then got=1; break; fi
    sleep 0.2; i=$((i + 1))
  done
  if [ "$got" = "1" ]; then
    second="$(grep '^data: ' "$EV_BODY" | tail -1 | sed 's/^data: //')"
    if printf '%s' "$second" | jq -e '.sweep_receipt.suites_total == 111' >/dev/null 2>&1; then
      ok "8d. mutating last-sweep.json (999->111) produced a second frame carrying 111 within 6s"
    else
      bad "8d. second frame arrived but does not carry the mutated value: ${second:0:200}"
    fi
  else
    bad "8d. no second SSE frame within 6s of mutating a source file"
  fi
  if leak="$(contains_sentinel "$EV_BODY")"; then
    bad "8e. SSE stream leaks planted secret $leak"
  else
    ok "8e. SSE stream carries none of the planted secrets"
  fi
else
  bad "8. no data: frame on /api/events within 6s; headers:"; sed 's/^/       | /' "$EV_HDR" 2>/dev/null
fi
kill "$EV_PID" 2>/dev/null; wait "$EV_PID" 2>/dev/null

# ── 9. bound to 127.0.0.1 only ─────────────────────────────────────────────
# PLAN L216: "bind 127.0.0.1 only (never 0.0.0.0)".
if command -v lsof >/dev/null 2>&1; then
  LISTEN="$(lsof -nP -iTCP:"$PORT" -sTCP:LISTEN 2>/dev/null | tail -n +2)"
  if [ -n "$LISTEN" ] && grep -q "127\.0\.0\.1:$PORT" <<<"$LISTEN" \
     && ! grep -Eq "(\*|0\.0\.0\.0|\[::\]|\[::1\]):$PORT" <<<"$LISTEN"; then
    ok "9. lsof shows a listener on 127.0.0.1:$PORT and none on *, 0.0.0.0 or ::"
  else
    bad "9. listener set is not loopback-only:"; printf '%s\n' "$LISTEN" | sed 's/^/       | /'
  fi
else
  # no lsof: prove it the other way -- a non-loopback local address must refuse
  NONLO="$(python3 -c 'import socket;s=socket.socket(socket.AF_INET,socket.SOCK_DGRAM);s.connect(("10.255.255.255",1));print(s.getsockname()[0])' 2>/dev/null || true)"
  if [ -n "$NONLO" ] && [ "$NONLO" != "127.0.0.1" ]; then
    rc="$(curl -s -m 2 -o /dev/null -w '%{http_code}' "http://$NONLO:$PORT/" || true)"
    if [ "$rc" = "000" ]; then ok "9. no lsof; connect via $NONLO:$PORT refused (loopback-only)"; else bad "9. reachable on $NONLO:$PORT (rc=$rc)"; fi
  else
    ok "9. (skipped: no lsof and no non-loopback address to probe)"
  fi
fi

# ── 10. sources vanish -> still 200, field null, server alive ──────────────
# PLAN L269 `sweep_receipt … | null`, L273 `checkpoint … | null`, L57/L484 empty state.
rm -f "$FIX/.heimdall/statusline.json" "$FIX/.heimdall/receipts/last-sweep.json" "$FIX/.planning/CHECKPOINT.md"
STATE2="$TMPROOT/state2.json"
rc="$(curl -s -o "$STATE2" -w '%{http_code}' "$BASE/api/state?$AUTH")"
missing=""
for k in "${CONTRACT_KEYS[@]}"; do
  jq -e --arg k "$k" 'has($k)' "$STATE2" >/dev/null 2>&1 || missing="$missing $k"
done
if [ "$rc" = "200" ] && [ -z "$missing" ] \
   && jq -e '.sweep_receipt == null and .checkpoint == null' "$STATE2" >/dev/null 2>&1; then
  ok "10. after deleting statusline.json + last-sweep.json + CHECKPOINT.md: 200, all keys present, sweep_receipt and checkpoint null"
else
  bad "10. missing sources: rc=$rc missing=[$missing] sweep=$(jq -c '.sweep_receipt' "$STATE2" 2>/dev/null) ckpt=$(jq -c '.checkpoint' "$STATE2" 2>/dev/null)"
fi
if kill -0 "$SRV_PID" 2>/dev/null; then
  ok "10b. server survived the missing sources (still running)"
else
  bad "10b. server died after a source file disappeared"
fi

# ── 11. --repo at a non-repo dir -> starts, 200, nulls (fail-open) ─────────
PORT2="$(free_port)"
SRV2_OUT="$TMPROOT/server2.out"
( cd "$EMPTY" && HEIMDALL_WATCH_ROOT="$EMPTY" exec "$UI" --repo "$EMPTY" --port "$PORT2" --no-open ) \
  >"$SRV2_OUT" 2>&1 &
SRV2_PID=$!
PIDS+=("$SRV2_PID")
URL2_RE="^http://127\.0\.0\.1:$PORT2/\?(t|token)=[A-Za-z0-9_-]+\$"
if wait_for "$SRV2_OUT" "$URL2_RE" 10; then
  Q2="$(grep -E "$URL2_RE" "$SRV2_OUT" | head -1)"; Q2="${Q2#*\?}"
  STATE3="$TMPROOT/state3.json"
  rc="$(curl -s -o "$STATE3" -w '%{http_code}' "http://127.0.0.1:$PORT2/api/state?$Q2")"
  missing=""
  for k in "${CONTRACT_KEYS[@]}"; do
    jq -e --arg k "$k" 'has($k)' "$STATE3" >/dev/null 2>&1 || missing="$missing $k"
  done
  if [ "$rc" = "200" ] && [ -z "$missing" ] \
     && jq -e '.sweep_receipt == null and .checkpoint == null and .roster == [] and .reels == []' "$STATE3" >/dev/null 2>&1; then
    ok "11. --repo on an empty non-repo dir: server starts, /api/state 200 with nulls/empties"
  else
    bad "11. non-repo dir: rc=$rc missing=[$missing] body=$(jq -c '{sweep_receipt,checkpoint,roster,reels}' "$STATE3" 2>/dev/null)"
  fi
  if [ "$TOKEN" != "${Q2#*=}" ]; then
    ok "11b. second launch minted a DIFFERENT token (per-launch random, PLAN L217)"
  else
    bad "11b. two launches printed the same token -- not per-launch random"
  fi
else
  bad "11. server did not start against a non-repo dir; output:"; sed 's/^/       | /' "$SRV2_OUT"
fi
kill "$SRV2_PID" 2>/dev/null; wait "$SRV2_PID" 2>/dev/null

# ── 12. kill -> port released ──────────────────────────────────────────────
kill "$SRV_PID" 2>/dev/null; wait "$SRV_PID" 2>/dev/null
i=0; released=0
while [ "$i" -lt 25 ]; do
  if python3 -c "import socket,sys; s=socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1); s.bind(('127.0.0.1',$PORT)); s.close()" 2>/dev/null \
     && [ "$(curl -s -m 1 -o /dev/null -w '%{http_code}' "$BASE/" || true)" = "000" ]; then
    released=1; break
  fi
  sleep 0.2; i=$((i + 1))
done
if [ "$released" = "1" ]; then
  ok "12. after kill: port $PORT is bindable again and nothing answers on it"
else
  bad "12. port $PORT still held 5s after killing the server"
fi

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
