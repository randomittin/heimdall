#!/usr/bin/env bash
# test/heimdall-ui-inbox.test.sh
#
# Oracle for POST /api/send -- the companion app -> running Claude Code session
# write path (sentinels/hmd-ui.py, bin/lib/companion_ui_inbox.py, `hmd ui inbox`).
# Contract under test:
#   - POST /api/send?token=<t>: same Host/token gate as every other route
#     (401 bad/missing token, 403 bad Host)
#   - Content-Type must be application/json, else 415
#   - body > 4096 bytes -> 413
#   - malformed JSON -> 400
#   - text non-empty after strip, <= 2000 chars, else 422
#   - secret_shaped(text) -> 422, body {"error":"secret-shaped"}
#   - success -> 202 {"id": <uuid4>, "queued": <n>}, one line appended to
#     <repo>/.heimdall/ui/inbox.jsonl: {"id","ts","text","source":"companion"}
#   - /api/state gains a top-level "inbox": {"pending": <n>}, additive
#   - `hmd ui inbox ls|pop|peek` list/deliver/peek the same queue
#   - pending queue capped at MAX_PENDING=200 -> 422 {"error":"inbox-full"};
#     draining (pop) makes room again (N3)
#   - inbox-delivered.jsonl rotates to .1 once it reaches MAX_INBOX_BYTES
#     (2 MiB), then a fresh delivery starts a new file (N3)
#
# Hermetic: HOME/HEIMDALL_HOME/TMPDIR redirected to a temp dir, fixture repo is a temp
#   dir -- TMPDIR is pinned too: sentinels/hmd-ui.py's collect_parallelism() falls back
#   to the most-recently-touched *.state file under $TMPDIR/heimdall-parallel when no
#   session id is set (always true for the server this file launches), so an unpinned
#   TMPDIR would read whichever real Claude Code session on the machine last made a
#   tool call instead of this fixture's own (empty) state.
# dir, background processes reaped on EXIT. No `timeout` on macOS -- every wait
# is a bounded sleep-0.2 poll. The secret-shaped fixture is assembled at RUNTIME
# (never a literal) -- same discipline as heimdall-ui-panels.test.sh.

set -u

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
UI="${HEIMDALL_UI_BIN:-$REPO/bin/heimdall-ui}"

PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; }

echo "heimdall-ui-inbox (POST /api/send companion -> session oracle)"

if [ ! -x "$UI" ]; then
  printf '  SKIP bin/heimdall-ui is absent or not executable (%s)\n' "$UI"
  printf '\n0 passed, 0 failed, 1 skipped (heimdall-ui not landed)\n'
  exit 0
fi
if ! grep -q '"inbox"' "$UI" 2>/dev/null || [ ! -f "$REPO/bin/lib/companion_ui_inbox.py" ]; then
  printf '  SKIP the `inbox` subcommand is not wired yet\n'
  printf '       (need: an `inbox` guard clause in %s AND %s)\n' "$UI" "$REPO/bin/lib/companion_ui_inbox.py"
  printf '\n0 passed, 0 failed, 1 skipped (POST /api/send: author not landed)\n'
  exit 0
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
# TMPDIR before HOME -- see the Hermetic note above (parallelism-tracker leak).
export TMPDIR="$TMPROOT"
export HOME="$TMPROOT/home"
export HEIMDALL_HOME="$TMPROOT/home/.heimdall"
FIX="$TMPROOT/fixture-repo"
mkdir -p "$HOME/.claude" "$FIX/.heimdall/receipts" "$FIX/.planning/reels"

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

( cd "$FIX" && git init -q . 2>/dev/null && git -c user.email=t@t -c user.name=t add -A >/dev/null 2>&1 \
  && git -c user.email=t@t -c user.name=t commit -qm fixture >/dev/null 2>&1 ) || true

free_port() {
  python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])'
}
PORT="$(free_port)"

wait_for() {
  local file="$1" re="$2" secs="${3:-10}" i=0 max
  max=$(( secs * 5 ))
  while [ "$i" -lt "$max" ]; do
    grep -Eq "$re" "$file" 2>/dev/null && return 0
    sleep 0.2; i=$((i + 1))
  done
  return 1
}

INBOX_FILE="$FIX/.heimdall/ui/inbox.jsonl"
DELIVERED_FILE="$FIX/.heimdall/ui/inbox-delivered.jsonl"

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

# ═══ 1. happy path: 202 + id + queued, one line appended ══════════════════
BODY="$TMPROOT/send1.json"; HDR="$TMPROOT/send1.hdr"
MSG1="hello from the companion app $(date +%s)"
rc="$(curl -s -D "$HDR" -o "$BODY" -w '%{http_code}' -X POST -H "Content-Type: application/json" \
     -d "$(jq -cn --arg t "$MSG1" '{text:$t}')" "$BASE/api/send?$AUTH")"
UUID_RE='^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-4[0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$'
if [ "$rc" = "202" ] && jq -e --arg re "$UUID_RE" '.id | test($re)' "$BODY" >/dev/null 2>&1 \
   && jq -e '.queued == 1' "$BODY" >/dev/null 2>&1; then
  ok "1. POST /api/send with valid text -> 202, uuid4 id, queued==1"
else
  bad "1. POST /api/send happy path: rc=$rc body=$(cat "$BODY" 2>/dev/null)"
fi
if grep -qi '^content-type: *application/json' "$HDR"; then
  ok "1b. /api/send response Content-Type is application/json"
else
  bad "1b. /api/send Content-Type = $(grep -i '^content-type' "$HDR" | tr -d '\r')"
fi
if [ -f "$INBOX_FILE" ] && [ "$(wc -l < "$INBOX_FILE" | tr -d ' ')" = "1" ] \
   && jq -e --arg t "$MSG1" '.text == $t and .source == "companion" and (.ts|type) == "number" and (.id|type) == "string"' \
        "$INBOX_FILE" >/dev/null 2>&1; then
  ok "2. inbox.jsonl has exactly one line: {id,ts,text,source=companion} matching the sent text"
else
  bad "2. inbox.jsonl wrong: $(cat "$INBOX_FILE" 2>/dev/null)"
fi
SENT_ID="$(jq -r '.id' "$BODY")"
if jq -e --arg id "$SENT_ID" '.id == $id' "$INBOX_FILE" >/dev/null 2>&1; then
  ok "2b. the id in the 202 response matches the id written to inbox.jsonl"
else
  bad "2b. id mismatch: response=$SENT_ID file=$(jq -r '.id' "$INBOX_FILE" 2>/dev/null)"
fi

# ═══ 2c/2d/2e. filesystem perms after the first append: dir 700, file 600,
# lock 600 (A10) -- portable stat idiom per test/heimdall-team.test.sh:115 ═══
DIR_PERM="$(stat -f '%Lp' "$FIX/.heimdall/ui" 2>/dev/null || stat -c '%a' "$FIX/.heimdall/ui" 2>/dev/null || echo '?')"
if [ "$DIR_PERM" = "700" ]; then
  ok "2c. .heimdall/ui directory is mode 700 after the first append"
else
  bad "2c. .heimdall/ui directory mode is $DIR_PERM, expected 700"
fi
INBOX_PERM="$(stat -f '%Lp' "$INBOX_FILE" 2>/dev/null || stat -c '%a' "$INBOX_FILE" 2>/dev/null || echo '?')"
if [ "$INBOX_PERM" = "600" ]; then
  ok "2d. inbox.jsonl is mode 600 after the first append"
else
  bad "2d. inbox.jsonl mode is $INBOX_PERM, expected 600"
fi
LOCK_PERM="$(stat -f '%Lp' "$FIX/.heimdall/ui/inbox.jsonl.lock" 2>/dev/null || stat -c '%a' "$FIX/.heimdall/ui/inbox.jsonl.lock" 2>/dev/null || echo '?')"
if [ "$LOCK_PERM" = "600" ]; then
  ok "2e. inbox.jsonl.lock is mode 600 after the first append"
else
  bad "2e. inbox.jsonl.lock mode is $LOCK_PERM, expected 600"
fi

# ═══ 3/4. auth: same gate as every other route ═════════════════════════════
rc_notoken="$(curl -s -o /dev/null -w '%{http_code}' -X POST -H "Content-Type: application/json" \
             -d '{"text":"x"}' "$BASE/api/send")"
if [ "$rc_notoken" = "401" ]; then
  ok "3. POST /api/send without a token -> 401"
else
  bad "3. POST /api/send without a token -> $rc_notoken, expected 401"
fi
rc_evilhost="$(curl -s -o /dev/null -w '%{http_code}' -X POST -H "Host: evil.example:$PORT" \
              -H "Content-Type: application/json" -d '{"text":"x"}' "$BASE/api/send?$AUTH")"
if [ "$rc_evilhost" = "403" ]; then
  ok "4. POST /api/send with a foreign Host header (valid token) -> 403"
else
  bad "4. POST /api/send foreign Host -> $rc_evilhost, expected 403"
fi

# ═══ 5. Content-Type must be application/json -> 415 ══════════════════════
rc_ctype="$(curl -s -o /dev/null -w '%{http_code}' -X POST -H "Content-Type: text/plain" \
           -d '{"text":"x"}' "$BASE/api/send?$AUTH")"
if [ "$rc_ctype" = "415" ]; then
  ok "5. POST /api/send with Content-Type: text/plain -> 415"
else
  bad "5. wrong Content-Type -> $rc_ctype, expected 415"
fi

# ═══ 6. body > 4096 bytes -> 413 ═══════════════════════════════════════════
BIGTEXT="$(python3 -c 'print("a" * 4300)')"
BIGBODY="$(jq -cn --arg t "$BIGTEXT" '{text:$t}')"
rc_big="$(curl -s -o /dev/null -w '%{http_code}' -X POST -H "Content-Type: application/json" \
         -d "$BIGBODY" "$BASE/api/send?$AUTH")"
if [ "$rc_big" = "413" ]; then
  ok "6. POST /api/send with a >4096-byte body -> 413"
else
  bad "6. oversize body -> $rc_big, expected 413 (body was $(printf '%s' "$BIGBODY" | wc -c | tr -d ' ') bytes)"
fi
if [ "$(wc -l < "$INBOX_FILE" | tr -d ' ')" = "1" ]; then
  ok "6b. the oversize POST wrote nothing (inbox.jsonl still 1 line)"
else
  bad "6b. inbox.jsonl line count changed after the oversize POST: $(wc -l < "$INBOX_FILE")"
fi

# ═══ 7. malformed JSON -> 400 ═══════════════════════════════════════════════
rc_badjson="$(curl -s -o /dev/null -w '%{http_code}' -X POST -H "Content-Type: application/json" \
             -d '{not json' "$BASE/api/send?$AUTH")"
if [ "$rc_badjson" = "400" ]; then
  ok "7. POST /api/send with malformed JSON -> 400"
else
  bad "7. malformed JSON -> $rc_badjson, expected 400"
fi

# ═══ 8. empty text (after strip) -> 422 ════════════════════════════════════
rc_empty="$(curl -s -o /dev/null -w '%{http_code}' -X POST -H "Content-Type: application/json" \
           -d '{"text":"   "}' "$BASE/api/send?$AUTH")"
if [ "$rc_empty" = "422" ]; then
  ok "8. POST /api/send with whitespace-only text -> 422"
else
  bad "8. whitespace-only text -> $rc_empty, expected 422"
fi

# ═══ 9. text > 2000 chars -> 422 ════════════════════════════════════════════
LONGTEXT="$(python3 -c 'print("b" * 2001)')"
LONGBODY="$(jq -cn --arg t "$LONGTEXT" '{text:$t}')"
rc_long="$(curl -s -o /dev/null -w '%{http_code}' -X POST -H "Content-Type: application/json" \
          -d "$LONGBODY" "$BASE/api/send?$AUTH")"
if [ "$rc_long" = "422" ]; then
  ok "9. POST /api/send with 2001-char text -> 422"
else
  bad "9. 2001-char text -> $rc_long, expected 422 (body was $(printf '%s' "$LONGBODY" | wc -c | tr -d ' ') bytes, under the 4096 cap)"
fi

# ═══ 10. secret-shaped text -> 422, body {"error":"secret-shaped"} ═════════
# Assembled at runtime -- never a literal (.gitleaks.toml discipline, matching
# heimdall-ui-panels.test.sh's SEC_* fixtures).
upnum() { python3 -c 'import secrets,string,sys; n=int(sys.argv[1]); print("".join(secrets.choice(string.ascii_uppercase+string.digits) for _ in range(n)))' "$1"; }
SEC_AWS="$(printf '%s%s%s' 'AK' 'IA' "$(upnum 16)")"
if ! printf '%s' "$SEC_AWS" | grep -Eq 'AKIA[0-9A-Z]{16}'; then
  printf '  FAIL harness bug: assembled shape does not match the AWS key family\n'
  printf '\n%s passed, %s failed\n' "$PASS" "$((FAIL + 1))"; exit 1
fi
SECBODY="$(jq -cn --arg t "$SEC_AWS" '{text:$t}')"
SECOUT="$TMPROOT/secret.json"
rc_secret="$(curl -s -o "$SECOUT" -w '%{http_code}' -X POST -H "Content-Type: application/json" \
            -d "$SECBODY" "$BASE/api/send?$AUTH")"
if [ "$rc_secret" = "422" ] && jq -e '.error == "secret-shaped"' "$SECOUT" >/dev/null 2>&1; then
  ok "10. POST /api/send with a secret-shaped text (AWS key) -> 422, body {\"error\":\"secret-shaped\"}"
else
  bad "10. secret-shaped text -> rc=$rc_secret body=$(cat "$SECOUT" 2>/dev/null)"
fi
if grep -qF "$SEC_AWS" "$INBOX_FILE" 2>/dev/null; then
  bad "10b. the secret-shaped value was written to inbox.jsonl"
else
  ok "10b. the secret-shaped value was never written to inbox.jsonl"
fi
if [ "$(wc -l < "$INBOX_FILE" | tr -d ' ')" = "1" ]; then
  ok "10c. every rejected POST (413/400/422 x3) left inbox.jsonl at 1 line -- nothing partial ever written"
else
  bad "10c. inbox.jsonl line count drifted from rejected POSTs: $(wc -l < "$INBOX_FILE")"
fi

# ═══ 11. /api/state gains "inbox": {"pending": n}, additive ═══════════════
STATE="$TMPROOT/state.json"
rc_state="$(curl -s -o "$STATE" -w '%{http_code}' "$BASE/api/state?$AUTH")"
CONTRACT_KEYS=(schema_version ts repo identity ledger roster quality_gate sweep_receipt hooks fallback parallelism checkpoint reels)
missing=""
for k in "${CONTRACT_KEYS[@]}"; do
  jq -e --arg k "$k" 'has($k)' "$STATE" >/dev/null 2>&1 || missing="$missing $k"
done
if [ "$rc_state" = "200" ] && [ -z "$missing" ] && jq -e '.inbox.pending == 1' "$STATE" >/dev/null 2>&1; then
  ok "11. /api/state: all 13 Wave-1 keys intact, additive inbox.pending == 1"
else
  bad "11. /api/state missing=[$missing] inbox=$(jq -c '.inbox' "$STATE" 2>/dev/null)"
fi

MSG2="second message $(date +%s)"
curl -s -o /dev/null -X POST -H "Content-Type: application/json" \
     -d "$(jq -cn --arg t "$MSG2" '{text:$t}')" "$BASE/api/send?$AUTH"
STATE2="$TMPROOT/state2.json"
i=0; got2=0
while [ "$i" -lt 15 ]; do
  curl -s -o "$STATE2" "$BASE/api/state?$AUTH"
  if jq -e '.inbox.pending == 2' "$STATE2" >/dev/null 2>&1; then got2=1; break; fi
  sleep 0.2; i=$((i + 1))
done
if [ "$got2" = "1" ]; then
  ok "11b. a second message raises /api/state's inbox.pending to 2"
else
  bad "11b. inbox.pending did not reach 2: $(jq -c '.inbox' "$STATE2" 2>/dev/null)"
fi

# ═══ 12/13/14. hmd ui inbox peek/ls/pop ═════════════════════════════════════
inbox_cli() { ( cd "$FIX" && HEIMDALL_WATCH_ROOT="$FIX" exec "$UI" inbox "$@" ); }
PEEK_OUT="$TMPROOT/peek.out"
if inbox_cli peek --json >"$PEEK_OUT" 2>&1 && jq -e --arg t "$MSG1" '.text == $t' "$PEEK_OUT" >/dev/null 2>&1; then
  ok "12. hmd ui inbox peek --json shows the OLDEST message (msg1), non-destructively"
else
  bad "12. peek failed or wrong message: $(cat "$PEEK_OUT")"
fi
if [ "$(wc -l < "$INBOX_FILE" | tr -d ' ')" = "2" ]; then
  ok "12b. peek did not remove anything (inbox.jsonl still 2 lines)"
else
  bad "12b. peek mutated the queue: $(wc -l < "$INBOX_FILE") lines"
fi
LS_OUT="$TMPROOT/ls.out"
if inbox_cli ls --json >"$LS_OUT" 2>&1 \
   && jq -e --arg a "$MSG1" --arg b "$MSG2" 'length == 2 and .[0].text == $a and .[1].text == $b' "$LS_OUT" >/dev/null 2>&1; then
  ok "13. hmd ui inbox ls --json lists both pending messages in FIFO order"
else
  bad "13. ls --json wrong: $(cat "$LS_OUT")"
fi
POP_OUT="$TMPROOT/pop.out"
if inbox_cli pop --json >"$POP_OUT" 2>&1 && jq -e 'length == 2' "$POP_OUT" >/dev/null 2>&1; then
  ok "14. hmd ui inbox pop --json delivers both messages"
else
  bad "14. pop --json wrong: $(cat "$POP_OUT")"
fi
if [ ! -s "$INBOX_FILE" ]; then
  ok "14b. inbox.jsonl is empty after pop"
else
  bad "14b. inbox.jsonl still has content after pop: $(cat "$INBOX_FILE")"
fi
if [ -f "$DELIVERED_FILE" ] && [ "$(wc -l < "$DELIVERED_FILE" | tr -d ' ')" = "2" ] \
   && grep -qF "$MSG1" "$DELIVERED_FILE" && grep -qF "$MSG2" "$DELIVERED_FILE"; then
  ok "14c. inbox-delivered.jsonl carries both delivered messages"
else
  bad "14c. inbox-delivered.jsonl wrong: $(cat "$DELIVERED_FILE" 2>/dev/null)"
fi
LS_EMPTY="$TMPROOT/ls-empty.out"
if inbox_cli ls --json >"$LS_EMPTY" 2>&1 && jq -e 'length == 0' "$LS_EMPTY" >/dev/null 2>&1; then
  ok "14d. hmd ui inbox ls --json is empty after pop"
else
  bad "14d. ls --json after pop not empty: $(cat "$LS_EMPTY")"
fi

# ═══ 15. /api/state's inbox.pending drops back to 0 after pop ═════════════
i=0; got0=0
while [ "$i" -lt 15 ]; do
  curl -s -o "$STATE2" "$BASE/api/state?$AUTH"
  if jq -e '.inbox.pending == 0' "$STATE2" >/dev/null 2>&1; then got0=1; break; fi
  sleep 0.2; i=$((i + 1))
done
if [ "$got0" = "1" ]; then
  ok "15. /api/state inbox.pending drops to 0 after hmd ui inbox pop"
else
  bad "15. inbox.pending did not return to 0: $(jq -c '.inbox' "$STATE2" 2>/dev/null)"
fi

# ═══ 16. control chars / OSC-52 escape + CR are stripped before write or
# print -- ANSI/OSC terminal injection via `hmd ui inbox ls|peek` (A8) ══════
OSC_RAW="$(printf '\x1b]52;c;dGVzdA==\x07before\rafter')"
OSCBODY="$(jq -cn --arg t "$OSC_RAW" '{text:$t}')"
OSCOUT="$TMPROOT/osc.json"
rc_osc="$(curl -s -o "$OSCOUT" -w '%{http_code}' -X POST -H "Content-Type: application/json" \
         -d "$OSCBODY" "$BASE/api/send?$AUTH")"
if [ "$rc_osc" = "202" ]; then
  ok "16. POST /api/send with an embedded ESC/OSC-52 sequence + \\r -> 202 (sanitized, not rejected)"
else
  bad "16. OSC/\\r text -> $rc_osc, expected 202 (body: $(cat "$OSCOUT" 2>/dev/null))"
fi
if [ "$(grep -c $'\x1b' "$INBOX_FILE" 2>/dev/null)" = "0" ]; then
  ok "16b. inbox.jsonl carries no raw ESC (\\x1b) byte"
else
  bad "16b. inbox.jsonl still contains a raw ESC byte"
fi
if [ "$(grep -c $'\r' "$INBOX_FILE" 2>/dev/null)" = "0" ]; then
  ok "16c. inbox.jsonl carries no raw CR (\\r) byte"
else
  bad "16c. inbox.jsonl still contains a raw CR byte"
fi
PEEK_RAW="$TMPROOT/peek-osc.out"
inbox_cli peek >"$PEEK_RAW" 2>&1
if [ "$(grep -c $'\x1b' "$PEEK_RAW" 2>/dev/null)" = "0" ]; then
  ok "16d. hmd ui inbox peek (plain) output has no raw ESC byte"
else
  bad "16d. peek output leaked a raw ESC byte"
fi
LS_RAW="$TMPROOT/ls-osc.out"
inbox_cli ls >"$LS_RAW" 2>&1
if [ "$(grep -c $'\x1b' "$LS_RAW" 2>/dev/null)" = "0" ]; then
  ok "16e. hmd ui inbox ls (plain) output has no raw ESC byte"
else
  bad "16e. ls output leaked a raw ESC byte"
fi
if [ "$(grep -c $'\r' "$LS_RAW" 2>/dev/null)" = "0" ]; then
  ok "16f. hmd ui inbox ls (plain) output has no raw CR byte"
else
  bad "16f. ls output leaked a raw CR byte"
fi
inbox_cli pop --json >/dev/null 2>&1   # drain -- leave the inbox clean for section 17

# ═══ 17. capacity cap (N3): MAX_PENDING=200 -- the 200th POST succeeds, the
# 201st is refused with 422 {"error":"inbox-full"} ═════════════════════════
TS="$(date +%s)"
CAP_FAILS=0
CAP_FAIL_DETAIL=""
for i in $(seq 1 200); do
  rc="$(curl -s -o /dev/null -w '%{http_code}' -X POST -H "Content-Type: application/json" \
       -d "$(printf '{"text":"cap message %d %s"}' "$i" "$TS")" "$BASE/api/send?$AUTH")"
  if [ "$rc" != "202" ]; then
    CAP_FAILS=$((CAP_FAILS + 1))
    [ -n "$CAP_FAIL_DETAIL" ] || CAP_FAIL_DETAIL="first failure at i=$i rc=$rc"
  fi
done
if [ "$CAP_FAILS" -eq 0 ]; then
  ok "17. 200 POSTs to /api/send (inbox drained beforehand) all return 202"
else
  bad "17. $CAP_FAILS/200 POSTs failed to return 202 ($CAP_FAIL_DETAIL)"
fi
if [ "$(wc -l < "$INBOX_FILE" | tr -d ' ')" = "200" ]; then
  ok "17a. inbox.jsonl has exactly 200 lines after the 200 accepted POSTs"
else
  bad "17a. inbox.jsonl line count is $(wc -l < "$INBOX_FILE" | tr -d ' '), expected 200"
fi
i=0; got200=0
while [ "$i" -lt 15 ]; do
  curl -s -o "$STATE2" "$BASE/api/state?$AUTH"
  if jq -e '.inbox.pending == 200' "$STATE2" >/dev/null 2>&1; then got200=1; break; fi
  sleep 0.2; i=$((i + 1))
done
if [ "$got200" = "1" ]; then
  ok "17b. /api/state inbox.pending reaches 200 after 200 accepted POSTs"
else
  bad "17b. inbox.pending did not reach 200: $(jq -c '.inbox' "$STATE2" 2>/dev/null)"
fi
CAPOUT="$TMPROOT/cap-201.json"
rc_cap="$(curl -s -o "$CAPOUT" -w '%{http_code}' -X POST -H "Content-Type: application/json" \
         -d "$(printf '{"text":"cap message 201 %s"}' "$TS")" "$BASE/api/send?$AUTH")"
if [ "$rc_cap" = "422" ] && jq -e '.error == "inbox-full"' "$CAPOUT" >/dev/null 2>&1; then
  ok "17c. the 201st POST (queue at 200) -> 422 {\"error\":\"inbox-full\"}"
else
  bad "17c. 201st POST -> rc=$rc_cap body=$(cat "$CAPOUT" 2>/dev/null), expected 422 inbox-full"
fi
if [ "$(wc -l < "$INBOX_FILE" | tr -d ' ')" = "200" ]; then
  ok "17d. the refused 201st POST wrote nothing (inbox.jsonl still 200 lines)"
else
  bad "17d. inbox.jsonl line count changed after the refused POST: $(wc -l < "$INBOX_FILE")"
fi
curl -s -o "$STATE2" "$BASE/api/state?$AUTH"
if jq -e '.inbox.pending == 200' "$STATE2" >/dev/null 2>&1; then
  ok "17e. /api/state inbox.pending is still 200 after the refused 201st POST"
else
  bad "17e. inbox.pending changed after the refused POST: $(jq -c '.inbox' "$STATE2" 2>/dev/null)"
fi

# ═══ 18. drain the full queue -> posting works again, pending count tracks ═
POP200_OUT="$TMPROOT/pop200.out"
if inbox_cli pop --json >"$POP200_OUT" 2>&1 && jq -e 'length == 200' "$POP200_OUT" >/dev/null 2>&1; then
  ok "18. hmd ui inbox pop --json drains all 200 messages at once"
else
  bad "18. pop at capacity wrong: length=$(jq 'length' "$POP200_OUT" 2>/dev/null)"
fi
i=0; got0b=0
while [ "$i" -lt 15 ]; do
  curl -s -o "$STATE2" "$BASE/api/state?$AUTH"
  if jq -e '.inbox.pending == 0' "$STATE2" >/dev/null 2>&1; then got0b=1; break; fi
  sleep 0.2; i=$((i + 1))
done
if [ "$got0b" = "1" ]; then
  ok "18a. /api/state inbox.pending drops to 0 after draining the full queue"
else
  bad "18a. inbox.pending did not return to 0 after drain: $(jq -c '.inbox' "$STATE2" 2>/dev/null)"
fi
MSG3="post-drain message $TS"
POST3_OUT="$TMPROOT/post3.json"
rc_post3="$(curl -s -o "$POST3_OUT" -w '%{http_code}' -X POST -H "Content-Type: application/json" \
           -d "$(jq -cn --arg t "$MSG3" '{text:$t}')" "$BASE/api/send?$AUTH")"
if [ "$rc_post3" = "202" ]; then
  ok "18b. posting works again immediately after draining a full (200/200) queue"
else
  bad "18b. post-drain POST -> $rc_post3, expected 202 (body: $(cat "$POST3_OUT" 2>/dev/null))"
fi
i=0; got1c=0
while [ "$i" -lt 15 ]; do
  curl -s -o "$STATE2" "$BASE/api/state?$AUTH"
  if jq -e '.inbox.pending == 1' "$STATE2" >/dev/null 2>&1; then got1c=1; break; fi
  sleep 0.2; i=$((i + 1))
done
if [ "$got1c" = "1" ]; then
  ok "18c. /api/state inbox.pending is 1 after the post-drain message"
else
  bad "18c. inbox.pending did not reach 1 after the post-drain message: $(jq -c '.inbox' "$STATE2" 2>/dev/null)"
fi

# ═══ 19. inbox-delivered.jsonl rotation at MAX_INBOX_BYTES (2 MiB) ═════════
# Fabricate an oversized delivered archive directly on disk, then deliver the
# one message left pending by section 18 -- pop_all() must rotate the
# existing (fake) archive to .1 before writing the fresh batch.
MARKER="OLDDELIVEREDFAKE-$TS"
python3 -c '
import sys
marker, path, target = sys.argv[1], sys.argv[2], int(sys.argv[3])
line = (marker + "\n").encode()
n = target // len(line) + 1
open(path, "wb").write(line * n)
' "$MARKER" "$DELIVERED_FILE" "$((2 * 1024 * 1024 + 100000))"
FAKE_SIZE="$(wc -c < "$DELIVERED_FILE" | tr -d ' ')"
if [ "$FAKE_SIZE" -ge "$((2 * 1024 * 1024))" ]; then
  ok "19a. harness: fake inbox-delivered.jsonl is >= 2 MiB ($FAKE_SIZE bytes) before delivery"
else
  bad "19a. harness bug: fake delivered file only $FAKE_SIZE bytes, expected >= 2 MiB"
fi
ROT_OUT="$TMPROOT/pop-rotate.out"
if inbox_cli pop --json >"$ROT_OUT" 2>&1 && jq -e --arg t "$MSG3" 'length == 1 and .[0].text == $t' "$ROT_OUT" >/dev/null 2>&1; then
  ok "19b. delivering the pending message while the archive is oversized still returns it"
else
  bad "19b. rotation-triggering pop wrong: $(cat "$ROT_OUT")"
fi
if [ -f "${DELIVERED_FILE}.1" ] && grep -qF "$MARKER" "${DELIVERED_FILE}.1"; then
  ok "19c. inbox-delivered.jsonl.1 exists and carries the rotated-out fake content"
else
  bad "19c. inbox-delivered.jsonl.1 missing or missing the fake marker"
fi
if grep -qF "$MARKER" "$DELIVERED_FILE" 2>/dev/null; then
  bad "19d. the live inbox-delivered.jsonl still carries the old (rotated-out) content"
else
  ok "19d. the live inbox-delivered.jsonl no longer carries the old content (fresh file)"
fi
if grep -qF "$MSG3" "$DELIVERED_FILE" 2>/dev/null; then
  ok "19e. the live inbox-delivered.jsonl carries the newly delivered message"
else
  bad "19e. the newly delivered message is missing from the live inbox-delivered.jsonl"
fi
LIVE_SIZE="$(wc -c < "$DELIVERED_FILE" | tr -d ' ')"
if [ "$LIVE_SIZE" -lt 100000 ]; then
  ok "19f. the live inbox-delivered.jsonl is small after rotation ($LIVE_SIZE bytes)"
else
  bad "19f. the live inbox-delivered.jsonl is still large after rotation: $LIVE_SIZE bytes"
fi
i=0; got0c=0
while [ "$i" -lt 15 ]; do
  curl -s -o "$STATE2" "$BASE/api/state?$AUTH"
  if jq -e '.inbox.pending == 0' "$STATE2" >/dev/null 2>&1; then got0c=1; break; fi
  sleep 0.2; i=$((i + 1))
done
if [ "$got0c" = "1" ]; then
  ok "19g. /api/state inbox.pending is back to 0 after the rotation-triggering delivery"
else
  bad "19g. inbox.pending did not return to 0: $(jq -c '.inbox' "$STATE2" 2>/dev/null)"
fi

# ═══ 20. server survived every malformed/oversize/secret/control-char/
# capacity/rotation payload ═════════════════════════════════════════════════
if kill -0 "$SRV_PID" 2>/dev/null; then
  ok "20. server still alive after every case"
else
  bad "20. server died during the run; tail of its output:"; tail -5 "$SRV_OUT" | sed 's/^/       | /'
fi

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
