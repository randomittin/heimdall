#!/usr/bin/env bash
# test/heimdall-controls.test.sh
#
# The paired phone's remote controls (bin/lib/companion_ui_controls.py; hmdapp's
# docs/HANDOFF-TO-HEIMDALL-remote-controls.md H1-H6) driven through the REAL direct-mode server (bin/heimdall-ui,
# POST /api/control -- the same dispatcher the relay client calls; the sealed path is
# test/heimdall-controls-relay.test.sh), the real heimdall-hooks / heimdall-fallback / heimdall-checkpoint CLIs, the
# real stop hook (bin/heimdall-phone-control) and `hmd app controls`. Nothing about the dispatcher is mocked.
#
#   1  refusals: unknown action, extra / missing / mistyped keys, a path-climbing hook id, an unsettable fallback mode
#   2  hook-toggle: allowlisted disable/enable move hooks-disabled and nothing else; `unchanged` rewrites nothing; a
#      locked gate and the advisory hooks NOT marked remote_toggle are `not-allowed` with hooks-disabled untouched; a
#      hand-edited sidecar marking a locked hook remote_toggle still cannot move it
#   3  rid: a repeated rid is answered `dup` and the handler does not run again
#   4  fallback-mode: `off` is free; every other state heimdall-fallback accepts (`auto` / `switch` / `coop`) needs
#      confirm:true; the state lands in heimdall-fallback's own answer; `coop` moves the state word and nothing else (the
#      laptop's allowlist rides through untouched); the modes the state offers are exactly heimdall-fallback's VALID_STATES
#   5  save-checkpoint: writes .planning/CHECKPOINT.md and nothing else (no commit, no tracked change), a second save
#      inside 5 s is `coalesced`, a checkpoint that fails its own completeness gate is `incomplete`
#   6  interrupt: `not-running` (nothing written) while idle; while working it writes ONE 0600 request, a second is
#      `already-pending`; the real hook stops once, drops a stale request, is cleared by a new prompt, ignores an
#      unattended session, and is out of the phone's reach
#   7  rate limits (fresh server, fresh buckets): the 4th interrupt in a burst is `rate-limited` with retry_after_s
#   8  kill switch: `hmd app controls off` and HMD_UI_CONTROLS=0 each turn every action into `controls-off`, flip
#      state.controls.enabled and the state digest, and leave POST /api/send alone
#   9  audit: one line per command, refused ones too, mode 0600 in a 0700 dir, only whitelisted fields, no free text,
#      no rid, nothing secret-shaped; `last` in the state is its newest line
#  10  state: the additive `controls` key and the registry rules (no hook is both locked and remote_toggle; every
#      offered hook round-trips and every other one is refused, hooks-disabled never moving)
#  11  mutants: the same checks run against deliberately broken copies of the module must FAIL (an allowlist that runs
#      anything, a toggle gate that checks only `locked`, a dedupe that never remembers, a switch that needs no
#      confirm, a coop that needs no confirm, a mode list that drops coop, an interrupt that writes while idle, a hook
#      that never consumes / ignores the TTL / is never cleared)
#
# Rate limits are real (burst 5 overall, 3 interrupts, 3 fallback changes, 6 toggles a minute, per server process), so
# every group below that sends more than a few commands starts a FRESH server on the same repo -- fresh buckets.
#
# Hermetic: HOME / HEIMDALL_HOME / TMPDIR are a temp dir, fixture repos are temp dirs, the session-id env vars are
# unset, every server is reaped on EXIT, every wait is a bounded poll. Secret-shaped strings are assembled at RUNTIME.

set -u

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
UI="$REPO/bin/heimdall-ui"
APP="$REPO/bin/heimdall-app"
HOOKS_CLI="$REPO/bin/heimdall-hooks"
FALLBACK="$REPO/bin/heimdall-fallback"
STOP_HOOK="$REPO/bin/heimdall-phone-control"
CTL_LIB="$REPO/bin/lib/companion_ui_controls.py"
HOOK_ENABLED_SH="$REPO/bin/lib/hook-enabled.sh"
HOOKS_JSON="$REPO/hooks/hooks.json"
SIDECAR="$REPO/hooks/hooks.metadata.json"

PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; }

echo "heimdall-controls (the phone's remote controls through the real server, CLIs and stop hook)"

for f in "$UI" "$APP" "$HOOKS_CLI" "$FALLBACK" "$STOP_HOOK" "$CTL_LIB" "$HOOK_ENABLED_SH" "$HOOKS_JSON" "$SIDECAR"; do
  if [ ! -e "$f" ]; then
    printf 'FATAL: required file missing: %s\n' "$f" >&2
    printf '\n0 passed, 1 failed\n'
    exit 1
  fi
done
for tool in curl jq python3 git; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    printf 'FATAL: required tool missing: %s\n' "$tool" >&2
    printf '\n0 passed, 1 failed\n'
    exit 1
  fi
done

TMPROOT="$(mktemp -d)"
export TMPDIR="$TMPROOT"
export HOME="$TMPROOT/home"
export HEIMDALL_HOME="$TMPROOT/home/.heimdall"
export HEIMDALL_FALLBACK_ASSUME_REACHABLE=0
export HEIMDALL_FALLBACK_PROBE_TIMEOUT=1
export HMD_UI_COMPANION_PANELS=0
export HMD_UI_CONTROL_DEADLINE_S=8   # the operator knob, at its ceiling: a loaded CI box must not turn a slow CLI into a flaky timeout
export REPO_ROOT="$REPO"
unset CLAUDE_SESSION_ID SESSION_ID CLAUDE_CODE_SESSION_ID CLAUDE_CONFIG_DIR HMD_AGENT_PROJECTS_DIR HMD_UI_CONTROLS \
      CLAUDE_CODE_ENTRYPOINT HMD_AGENT_TYPE HMD_JUDGMENT HMD_HOOKS_METADATA HMD_TMUX_TARGET HMD_CKPT_FAULT
mkdir -p "$HOME/.claude"

PIDS=()
UI_PID=""
cleanup() {
  local p
  for p in "${PIDS[@]:-}"; do [ -n "$p" ] && kill "$p" 2>/dev/null; done
  for p in "${PIDS[@]:-}"; do [ -n "$p" ] && wait "$p" 2>/dev/null; done
  rm -rf "$TMPROOT"
}
trap cleanup EXIT

free_port() { python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()'; }
wait_for() {
  local file="$1" re="$2" secs="${3:-10}" i=0 max
  max=$(( secs * 5 ))
  while [ "$i" -lt "$max" ]; do
    grep -Eq "$re" "$file" 2>/dev/null && return 0
    sleep 0.2; i=$((i + 1))
  done
  return 1
}

# new_repo NAME -> a fixture git repo with one commit; prints its real path
new_repo() {
  local d="$TMPROOT/$1"
  mkdir -p "$d"
  ( cd "$d" && git init -q . 2>/dev/null && git -c user.email=t@t -c user.name=t commit -q --allow-empty -m fixture ) >/dev/null 2>&1
  ( cd "$d" && pwd -P )
}

stop_ui() {
  if [ -n "$UI_PID" ]; then kill "$UI_PID" 2>/dev/null; wait "$UI_PID" 2>/dev/null; fi
  UI_PID=""
}
# start_ui REPO -> sets UI_BASE, UI_TOKEN, UI_PID for a FRESH real `hmd ui` bound to REPO (the previous one is stopped);
# extra environment goes in front of the call
start_ui() {
  local fix="$1" port out url q
  stop_ui
  port="$(free_port)"
  out="$TMPROOT/ui.$port.out"
  ( cd "$fix" && HEIMDALL_WATCH_ROOT="$fix" exec "$UI" --repo "$fix" --port "$port" --no-open ) >"$out" 2>&1 &
  UI_PID=$!
  PIDS+=("$UI_PID")
  if ! wait_for "$out" "^http://127\.0\.0\.1:$port/\?(t|token)=[A-Za-z0-9_-]+\$" 20; then
    bad "server for $fix never printed its URL"; sed 's/^/       | /' "$out"; return 1
  fi
  url="$(grep -E "^http://127\.0\.0\.1:$port/" "$out" | head -1)"
  q="${url#*\?}"
  UI_BASE="http://127.0.0.1:$port"
  UI_TOKEN="${q#*=}"
}

# ctl JSON -> POST /api/control on the current server; CODE and BODY hold the answer
ctl() {
  CODE="$(curl -s -o "$TMPROOT/ctl.body" -w '%{http_code}' -X POST -H 'Content-Type: application/json' \
          -d "$1" "$UI_BASE/api/control?token=$UI_TOKEN")"
  BODY="$(cat "$TMPROOT/ctl.body")"
}
state() { curl -s "$UI_BASE/api/state?token=$UI_TOKEN"; }
etag() { curl -s -D - -o /dev/null "$UI_BASE/api/state?token=$UI_TOKEN" | tr -d '\r' | awk -F': ' 'tolower($1)=="etag"{print $2}'; }
jq_ok() { printf '%s' "$BODY" | jq -e "$1" >/dev/null 2>&1; }
# expect LABEL CODE JQ -- the last control's status code and a jq predicate over its body
expect() {
  if [ "$CODE" = "$2" ] && jq_ok "$3"; then ok "$1"; else bad "$1 -- got $CODE $BODY"; fi
}
file_stamp() { python3 -c 'import os,sys
try:
    st = os.stat(sys.argv[1]); print(st.st_mtime_ns, st.st_size)
except OSError:
    print("absent")' "$1"; }
mode_of() { stat -f %Lp "$1" 2>/dev/null || stat -c %a "$1"; }

# the transcript the repo's session is read from (see test/heimdall-ui-attention.test.sh): `working` / `idle` on demand
tx() {
  python3 - "$1" "$2" <<'PYEOF'
import datetime, json, sys, time, uuid
path, kind = sys.argv[1:3]
SID = "bbbbbbbb-0000-4000-8000-000000000001"
def iso(t):
    return datetime.datetime.fromtimestamp(t, datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.") + "%03dZ" % int((t % 1) * 1000)
def base(age):
    return {"parentUuid": None, "isSidechain": False, "uuid": str(uuid.uuid4()), "timestamp": iso(time.time() - age),
            "sessionId": SID, "entrypoint": "cli", "cwd": "/fixture"}
rows = []
if kind == "working":
    e = base(0.0); e.update(type="user", message={"role": "user", "content": "do the thing"}); rows.append(e)
elif kind == "idle":
    e = base(0.01); e.update(type="assistant", message={"role": "assistant", "stop_reason": "end_turn",
                                                       "content": [{"type": "text", "text": "done."}]}); rows.append(e)
    t = base(0.0); t.update(type="system", subtype="turn_duration", durationMs=1000); rows.append(t)
with open(path, "a", encoding="utf-8") as f:
    for r in rows:
        f.write(json.dumps(r, separators=(",", ":")) + "\n")
PYEOF
}
# transcript_for REPO -> the path of the session transcript the server will read for REPO (dir created)
transcript_for() {
  local slug dir
  slug="$(printf '%s' "$1" | sed 's/[^A-Za-z0-9]/-/g')"
  dir="$HOME/.claude/projects/$slug"
  mkdir -p "$dir"
  printf '%s/bbbbbbbb-0000-4000-8000-000000000001.jsonl' "$dir"
}
att() { state | jq -r '.attention.state'; }
wait_att() { local want="$1" i=0; while [ "$i" -lt 40 ]; do [ "$(att)" = "$want" ] && return 0; sleep 0.2; i=$((i + 1)); done; return 1; }

FIX="$(new_repo main)"
TX="$(transcript_for "$FIX")"
tx "$TX" idle
SR="$FIX/.heimdall/ui/stop-request.json"
SC="$FIX/.heimdall/ui/stop-request.consumed"
DIS="$HEIMDALL_HOME/hooks-disabled"
# put_request AGE_S -> a stop request as the handler would have written it, requested AGE_S seconds ago
put_request() {
  python3 - "$SR" "$1" <<'PYEOF'
import json, os, sys, time
path, age = sys.argv[1], float(sys.argv[2])
os.makedirs(os.path.dirname(path), exist_ok=True)
with open(path, "w") as f:
    json.dump({"id": "s-0000aaaa", "requested_at": time.time() - age, "turn": None, "device": "direct"}, f)
os.chmod(path, 0o600)
PYEOF
}

# ═══ 1. refusals (none of these is charged against the rate limit: they fail before the handler) ══════════════
start_ui "$FIX" || { printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"; exit 1; }
ok "0. a real hmd ui is up on $UI_BASE with a token"
ctl '{"action":"rm-rf","params":{}}'
expect "1a. an unknown action -> 404 not-implemented" 404 '.ok == false and .detail == "not-implemented"'
ctl '{"action":"save-checkpoint","params":{"x":1}}'
expect "1b. an extra key -> 422 bad-params" 422 '.ok == false and .detail == "bad-params"'
ctl '{"action":"hook-toggle","params":{"id":"../etc","enabled":true}}'
expect "1c. a hook id that climbs a path -> 422 bad-params" 422 '.detail == "bad-params"'
ctl '{"action":"hook-toggle","params":{"id":"parallel-gate","enabled":"false"}}'
expect "1d. enabled as a string -> bad-params" 422 '.detail == "bad-params"'
ctl '{"action":"hook-toggle","params":{"id":"parallel-gate"}}'
expect "1e. enabled missing -> bad-params" 422 '.detail == "bad-params"'
ctl '{"action":"hook-toggle","params":{"id":"parallel-gate","toggle":true}}'
expect "1f. a flip instead of a set -> bad-params" 422 '.detail == "bad-params"'
LONGID="$(python3 -c 'print("a" * 300)')"
ctl "{\"action\":\"hook-toggle\",\"params\":{\"id\":\"$LONGID\",\"enabled\":true}}"
expect "1g. a 300-char hook id -> bad-params" 422 '.detail == "bad-params"'
ctl '{"action":"hook-toggle","params":{"id":"","enabled":true}}'
expect "1h. an empty hook id -> bad-params" 422 '.detail == "bad-params"'
ctl '{"action":"interrupt","params":"stop"}'
expect "1i. params that is not an object -> bad-params" 422 '.detail == "bad-params"'
ctl '{"action":"interrupt","params":{"rid":"r 1"}}'
expect "1j. a rid outside [A-Za-z0-9_-] -> bad-params" 422 '.detail == "bad-params"'
ctl '{"action":"interrupt","params":{"rid":"r23456789012345678901234567890123"}}'
expect "1k. a rid of 33 chars -> bad-params" 422 '.detail == "bad-params"'
ctl '{"action":"fallback-mode","params":{"mode":"panic","confirm":true}}'
expect "1l. a fallback mode heimdall-fallback does not know is bad-params even with confirm:true" 422 '.detail == "bad-params"'
ctl '{"action":"fallback-mode","params":{"mode":"on"}}'
expect "1m. fallback mode on (retired) -> bad-params" 422 '.detail == "bad-params"'
ctl '{"action":"fallback-mode","params":{"mode":"switch","confirm":"yes"}}'
expect "1n. confirm as a string -> bad-params" 422 '.detail == "bad-params"'
ctl '{"action":"fallback-mode","params":{"mode":"OFF"}}'
expect "1o. a case-varied mode -> bad-params" 422 '.detail == "bad-params"'
HUGE="$(python3 -c 'print("x" * 1500)')"
ctl "{\"action\":\"interrupt\",\"params\":{\"pad\":\"$HUGE\"}}"
expect "1p. a command over 1 KiB -> bad-params" 422 '.detail == "bad-params"'
BIG="$(python3 -c 'print("y" * 5000)')"
ctl "{\"action\":\"interrupt\",\"params\":{\"pad\":\"$BIG\"}}"
if [ "$CODE" = "413" ]; then ok "1q. a body over the HTTP cap (4096 bytes) -> 413 before anything is read"; else bad "1q. oversize body answered $CODE"; fi
CODE_NOAUTH="$(curl -s -o /dev/null -w '%{http_code}' -X POST -H 'Content-Type: application/json' -d '{"action":"interrupt","params":{}}' "$UI_BASE/api/control")"
CODE_BADHOST="$(curl -s -o /dev/null -w '%{http_code}' -X POST -H 'Host: evil.example' -H 'Content-Type: application/json' -d '{"action":"interrupt","params":{}}' "$UI_BASE/api/control?token=$UI_TOKEN")"
CODE_CT="$(curl -s -o /dev/null -w '%{http_code}' -X POST -H 'Content-Type: text/plain' -d '{"action":"interrupt","params":{}}' "$UI_BASE/api/control?token=$UI_TOKEN")"
if [ "$CODE_NOAUTH" = "401" ] && [ "$CODE_BADHOST" = "403" ] && [ "$CODE_CT" = "415" ]; then
  ok "1r. the direct route has the same gate as /api/send: no token 401, foreign Host 403, wrong content type 415"
else
  bad "1r. gate: no token $CODE_NOAUTH, bad Host $CODE_BADHOST, text/plain $CODE_CT"
fi
if [ ! -e "$DIS" ] && [ ! -e "$FIX/.heimdall/fallback.json" ] && [ ! -e "$FIX/.planning" ] && [ ! -e "$SR" ]; then
  ok "1s. none of those refusals wrote anything (no hooks-disabled, fallback.json, .planning or stop request)"
else
  bad "1s. a refusal left a file behind"
fi

# ═══ 2 + 3. hook-toggle through the real heimdall-hooks, and rid (a fresh server: 5 charged commands) ══════════
start_ui "$FIX"
ctl '{"action":"hook-toggle","params":{"id":"parallel-gate","enabled":false}}'
expect "2a. disabling an allowlisted hook -> 200 {id, enabled:false}" 200 '.ok == true and .result == {"id":"parallel-gate","enabled":false} and (has("detail") | not)'
if [ "$(cat "$DIS" 2>/dev/null)" = "parallel-gate" ]; then ok "2b. hooks-disabled now holds exactly that id"; else bad "2b. hooks-disabled is: $(cat "$DIS" 2>/dev/null)"; fi
if bash -c '. "$1"; hmd_hook_enabled parallel-gate' _ "$HOOK_ENABLED_SH"; then
  bad "2c. a fresh shell still reads parallel-gate as enabled"
else
  ok "2c. a fresh shell reads parallel-gate as disabled (hmd_hook_enabled returns 1)"
fi
STAMP="$(file_stamp "$DIS")"
ctl '{"action":"hook-toggle","params":{"id":"parallel-gate","enabled":false}}'
expect "2d. disabling it again -> ok, detail unchanged" 200 '.ok == true and .detail == "unchanged"'
if [ "$(file_stamp "$DIS")" = "$STAMP" ]; then ok "2e. ... and hooks-disabled was not rewritten (mtime and size identical)"; else bad "2e. hooks-disabled changed on an unchanged toggle"; fi
ctl '{"action":"hook-toggle","params":{"id":"parallel-gate","enabled":true}}'
expect "2f. enabling it -> 200 {enabled:true}" 200 '.ok == true and .result.enabled == true'
if [ ! -s "$DIS" ] && bash -c '. "$1"; hmd_hook_enabled parallel-gate' _ "$HOOK_ENABLED_SH"; then
  ok "2g. hooks-disabled lost exactly that id and a fresh shell reads it as enabled"
else
  bad "2g. enable did not restore parallel-gate: $(cat "$DIS" 2>/dev/null)"
fi
ctl '{"action":"hook-toggle","params":{"id":"ctx-meter-notice","enabled":false,"rid":"dd1"}}'
expect "3a. first send of a rid -> ok, no dup" 200 '.ok == true and (has("dup") | not)'
STAMP="$(file_stamp "$DIS")"
ctl '{"action":"hook-toggle","params":{"id":"ctx-meter-notice","enabled":false,"rid":"dd1"}}'
expect "3b. the same rid again -> the stored ack with dup:true" 200 '.ok == true and .dup == true and .result.id == "ctx-meter-notice"'
if [ "$(file_stamp "$DIS")" = "$STAMP" ]; then ok "3c. ... and the handler did not run again (hooks-disabled mtime unchanged)"; else bad "3c. hooks-disabled changed on a dup"; fi
ctl '{"action":"hook-toggle","params":{"id":"ctx-meter-notice","enabled":true,"rid":"dd2"}}'
expect "3d. a new rid runs the handler (enable)" 200 '.ok == true and (has("dup") | not) and .result.enabled == true'

# ── 2 (cont). what the phone must not reach (a fresh server) ──────────────────────────────────────────────────
start_ui "$FIX"
ctl '{"action":"hook-toggle","params":{"id":"stub-gate","enabled":false}}'
expect "2h. a LOCKED gate (stub-gate) -> 403 not-allowed" 403 '.ok == false and .detail == "not-allowed"'
for id in inbox-deliver-stop phone-control-pretool edit-claim-prewarn; do
  ctl "{\"action\":\"hook-toggle\",\"params\":{\"id\":\"$id\",\"enabled\":false}}"
  if [ "$CODE" = "403" ] && jq_ok '.detail == "not-allowed"'; then :; else bad "2i. $id was not refused: $CODE $BODY"; fi
done
if [ ! -s "$DIS" ]; then ok "2i. advisory hooks the phone must not reach (its own message path, its own stop path, a never-lose commit) -> not-allowed, hooks-disabled still empty"; else bad "2i. hooks-disabled moved: $(cat "$DIS")"; fi
ctl '{"action":"hook-toggle","params":{"id":"no-such-hook","enabled":false}}'
expect "2j. an id the registry does not know -> 409 unknown-id" 409 '.detail == "unknown-id"'

# a hand-edited sidecar marking a LOCKED hook remote_toggle: check fails AND the handler still refuses it
BADMETA="$TMPROOT/sidecar-bad.json"
jq '(.hooks[] | select(.id == "stub-gate") | .remote_toggle) = true' "$SIDECAR" > "$BADMETA"
if "$HOOKS_CLI" check --metadata "$BADMETA" >/dev/null 2>&1; then
  bad "2k. heimdall-hooks check accepted a locked hook marked remote_toggle"
else
  ok "2k. heimdall-hooks check exits non-zero for a hook that is both locked and remote_toggle"
fi
FIX_B="$(new_repo badmeta)"
HMD_HOOKS_METADATA="$BADMETA" start_ui "$FIX_B"
ctl '{"action":"hook-toggle","params":{"id":"stub-gate","enabled":false}}'
if [ "$CODE" = "403" ] && jq_ok '.detail == "not-allowed"' && [ ! -s "$DIS" ]; then
  ok "2l. ... and the phone's handler still returns not-allowed for it (hooks-disabled untouched)"
else
  bad "2l. a locked hook with a hand-set remote_toggle was reachable: $CODE $BODY"
fi

# ═══ 4. fallback-mode through the real heimdall-fallback (the fallback bucket holds 3: two fresh servers) ═══════
FB() { "$FALLBACK" --repo "$FIX" status --json 2>/dev/null | jq -r .state; }
start_ui "$FIX"
ctl '{"action":"fallback-mode","params":{"mode":"off"}}'
expect "4a. off while already off -> ok, detail unchanged" 200 '.ok == true and .detail == "unchanged" and .result == {"mode":"off"}'
ctl '{"action":"fallback-mode","params":{"mode":"switch"}}'
expect "4b. switch without confirm -> 422 confirm-required" 422 '.ok == false and .detail == "confirm-required"'
ctl '{"action":"fallback-mode","params":{"mode":"auto","confirm":false}}'
expect "4c. auto with confirm:false -> confirm-required" 422 '.detail == "confirm-required"'
if [ "$(FB)" = "off" ]; then ok "4d. no refusal moved the fallback state (heimdall-fallback still says off)"; else bad "4d. fallback state is $(FB)"; fi
start_ui "$FIX"
ctl '{"action":"fallback-mode","params":{"mode":"switch","confirm":true,"rid":"fb1"}}'
expect "4e. switch with confirm:true -> ok {mode:switch, was:off}" 200 '.ok == true and .result == {"mode":"switch","was":"off"}'
if [ "$(FB)" = "switch" ]; then ok "4f. heimdall-fallback itself now says switch"; else bad "4f. fallback state is $(FB)"; fi
ctl '{"action":"fallback-mode","params":{"mode":"off"}}'
expect "4g. off needs no confirm -> ok {mode:off, was:switch}" 200 '.ok == true and .result == {"mode":"off","was":"switch"}'
"$FALLBACK" --repo "$FIX" set coop >/dev/null 2>&1
S="$(state)"
if printf '%s' "$S" | jq -e '.controls.fallback == {"mode":"coop","modes":["off","auto","switch","coop"],"confirm":["auto","switch","coop"]}' >/dev/null 2>&1; then
  ok "4h. the state reports the laptop's coop mode, all four modes the phone may set, and the three that need confirm"
else
  bad "4h. controls.fallback is: $(printf '%s' "$S" | jq -c .controls.fallback)"
fi
ctl '{"action":"fallback-mode","params":{"mode":"off"}}'
expect "4i. the phone can leave coop for off (reduce) -> ok, was coop" 200 '.ok == true and .result == {"mode":"off","was":"coop"}'

# coop through the phone: it routes the allowlisted subagent roles off Claude, so it needs confirm like auto / switch, and it
# moves the state word and nothing else -- the laptop's allowlist is never read, grown or shrunk from here. A fresh server:
# the fallback bucket holds 3 and this uses all 3.
"$FALLBACK" --repo "$FIX" coop add hmd:coder >/dev/null 2>&1
start_ui "$FIX"
ctl '{"action":"fallback-mode","params":{"mode":"coop"}}'
expect "4j. coop without confirm -> 422 confirm-required" 422 '.ok == false and .detail == "confirm-required"'
if [ "$(FB)" = "off" ]; then ok "4k. ... and the refusal moved nothing (heimdall-fallback still says off)"; else bad "4k. fallback state is $(FB)"; fi
ctl '{"action":"fallback-mode","params":{"mode":"coop","confirm":true,"rid":"fb2"}}'
expect "4l. coop with confirm:true -> ok {mode:coop, was:off}" 200 '.ok == true and .result == {"mode":"coop","was":"off"}'
if [ "$(FB)" = "coop" ]; then ok "4m. heimdall-fallback itself now says coop"; else bad "4m. fallback state is $(FB)"; fi
ctl '{"action":"fallback-mode","params":{"mode":"off"}}'
expect "4n. off from coop needs no confirm -> ok {mode:off, was:coop}" 200 '.ok == true and .result == {"mode":"off","was":"coop"}'
if "$FALLBACK" --repo "$FIX" coop list --json 2>/dev/null | jq -e '.coop_roles == ["hmd:coder"]' >/dev/null 2>&1; then
  ok "4o. the laptop's coop allowlist rode through both flips untouched (still exactly hmd:coder)"
else
  bad "4o. the coop allowlist is now: $("$FALLBACK" --repo "$FIX" coop list --json 2>/dev/null)"
fi
"$FALLBACK" --repo "$FIX" coop remove hmd:coder >/dev/null 2>&1

# every state heimdall-fallback's own `set` accepts -- read off ITS VALID_STATES, not off the module under test -- through the
# phone's dispatcher in-process (rate limits reset between calls; the real heimdall-fallback runs each time): off is free,
# every other one is refused without confirm with fallback.json byte-identical, lands with it, and the answer names the
# previous state. The same pass checks the state key offers exactly those states and asks confirm for all but off.
MATRIX="$(python3 - "$CTL_LIB" "$FALLBACK" <<'PYEOF'
import importlib.machinery, importlib.util, json, os, sys
sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location("c", sys.argv[1])
C = importlib.util.module_from_spec(spec); spec.loader.exec_module(C)
loader = importlib.machinery.SourceFileLoader("hmd_fallback", sys.argv[2])
F = importlib.util.module_from_spec(importlib.util.spec_from_loader("hmd_fallback", loader)); loader.exec_module(F)
root = os.path.join(os.environ["TMPDIR"], "matrix-repo"); os.makedirs(root, exist_ok=True)
cfg_path = os.path.join(root, ".heimdall", "fallback.json")
def raw():
    try:
        return open(cfg_path, "rb").read()
    except OSError:
        return None
def landed():
    return F.load_config(root)[0]["state"]
states = list(F.VALID_STATES)
fb = C.snapshot(root)["fallback"]
drift = []
if fb["modes"] != states:
    drift.append("modes %r != VALID_STATES %r" % (fb["modes"], states))
if fb["confirm"] != [s for s in states if s != "off"]:
    drift.append("confirm %r is not every state but off" % (fb["confirm"],))
bad, prev = [], "off"
for state in states:
    before = raw()
    C._BUCKETS.clear()
    ok, detail, _ = C.dispatch(root, "fallback-mode", {"mode": state})
    if state == "off":
        if not ok:
            bad.append("off needed confirm: %s %s" % (ok, detail))
    elif (ok, detail) != (False, "confirm-required") or raw() != before:
        bad.append("%s without confirm: %s %s, file moved: %s" % (state, ok, detail, raw() != before))
    C._BUCKETS.clear()
    ok, detail, extra = C.dispatch(root, "fallback-mode", {"mode": state, "confirm": True})
    want = {"mode": state} if state == prev else {"mode": state, "was": prev}
    if not ok or extra.get("result") != want or landed() != state:
        bad.append("%s with confirm: ok=%s detail=%s result=%s landed=%s" % (state, ok, detail, extra.get("result"), landed()))
    prev = state
print(json.dumps({"states": states, "drift": drift, "bad": bad}))
PYEOF
)"
if printf '%s' "$MATRIX" | jq -e '.drift == [] and (.states | index("coop")) != null' >/dev/null 2>&1; then
  ok "4p. state.controls.fallback.modes is exactly heimdall-fallback's VALID_STATES ($(printf '%s' "$MATRIX" | jq -r '.states | join(", ")')) and confirm is each of them but off"
else
  bad "4p. the offered modes drifted from heimdall-fallback: $MATRIX"
fi
if printf '%s' "$MATRIX" | jq -e '.bad == []' >/dev/null 2>&1; then
  ok "4q. each of those states goes through the phone's dispatcher: off free, the rest refused without confirm and landed with it"
else
  bad "4q. state matrix: $MATRIX"
fi

# ═══ 5. save-checkpoint through the real heimdall-checkpoint ═════════════════════════════════════════════════
HEAD0="$(git -C "$FIX" rev-parse HEAD)"
CK="$FIX/.planning/CHECKPOINT.md"
start_ui "$FIX"
ctl '{"action":"save-checkpoint","params":{"rid":"ck1"}}'
expect "5a. save-checkpoint -> 200 {result:{written_at}}" 200 '.ok == true and (.result.written_at | type == "number") and (has("detail") | not)'
if [ -s "$CK" ]; then ok "5b. .planning/CHECKPOINT.md was written"; else bad "5b. no checkpoint file"; fi
if [ "$(git -C "$FIX" rev-parse HEAD)" = "$HEAD0" ] && [ -z "$(git -C "$FIX" diff --name-only; git -C "$FIX" diff --cached --name-only)" ]; then
  ok "5c. it committed nothing and changed no tracked file (HEAD unchanged, no diff)"
else
  bad "5c. the checkpoint touched git state"
fi
STAMP="$(file_stamp "$CK")"
sleep 1
ctl '{"action":"save-checkpoint","params":{}}'
expect "5d. a second save a second later -> ok, detail coalesced, the same result" 200 '.ok == true and .detail == "coalesced" and (.result.written_at | type == "number")'
if [ "$(file_stamp "$CK")" = "$STAMP" ]; then ok "5e. ... and the checkpoint file was not rewritten"; else bad "5e. CHECKPOINT.md changed on a coalesced save"; fi
i=0; HEADSEEN=""
while [ "$i" -lt 25 ]; do HEADSEEN="$(state | jq -r '.checkpoint.head // empty')"; [ -n "$HEADSEEN" ] && break; sleep 0.2; i=$((i + 1)); done
case "$HEAD0" in
  "$HEADSEEN"?*) if [ -n "$HEADSEEN" ]; then ok "5f. state.checkpoint.head ($HEADSEEN) follows the write and names HEAD"; else bad "5f. no checkpoint head in the state"; fi ;;
  *) bad "5f. state.checkpoint.head is '$HEADSEEN', HEAD is $HEAD0" ;;
esac
FIX_C="$(new_repo ckfail)"
HMD_CKPT_FAULT=in_progress start_ui "$FIX_C"
ctl '{"action":"save-checkpoint","params":{}}'
expect "5g. a checkpoint that fails its own completeness gate -> ok:false, detail incomplete" 500 '.ok == false and .detail == "incomplete"'

# ═══ 6. interrupt and the stop hook (the interrupt bucket holds 3: this server sends exactly 3) ═══════════════
start_ui "$FIX"
if wait_att idle; then
  ctl '{"action":"interrupt","params":{}}'
  expect "6a. an idle session -> 409 not-running" 409 '.ok == false and .detail == "not-running"'
  if [ ! -e "$SR" ]; then ok "6b. ... and no stop request was written"; else bad "6b. a request was written while idle"; fi
else
  bad "6a. the fixture session never read as idle (attention: $(att))"
fi
tx "$TX" working
if wait_att working; then
  ctl '{"action":"interrupt","params":{"rid":"in1"}}'
  expect "6c. a working session -> 200 with a stop id and the honest limits" 200 \
    '.ok == true and (.id | test("^s-[0-9a-f]{8}$")) and .result == {"via":"hook","effective":"next-tool-boundary"}'
  SID1="$(printf '%s' "$BODY" | jq -r .id)"
  if [ -f "$SR" ] && [ "$(mode_of "$SR")" = "600" ] && jq -e --arg id "$SID1" '.id == $id and (.requested_at | type == "number")' "$SR" >/dev/null 2>&1; then
    ok "6d. stop-request.json exists, mode 600, carries that id"
  else
    bad "6d. stop-request.json missing, wrong mode or wrong content"
  fi
  ctl '{"action":"interrupt","params":{}}'
  expect "6e. a second interrupt while pending -> ok, already-pending, the same id" 200 ".ok == true and .detail == \"already-pending\" and .id == \"$SID1\""
else
  bad "6c. the fixture session never read as working (attention: $(att))"
fi
HOOKOUT="$("$STOP_HOOK" stop --repo "$FIX" </dev/null)"
if printf '%s' "$HOOKOUT" | jq -e '.continue == false and (.stopReason | test("^Stopped from the phone at [0-9]{2}:[0-9]{2}\\. Send a message to continue\\.$"))' >/dev/null 2>&1 && [ ! -e "$SR" ] && [ -f "$SC" ]; then
  ok "6f. the stop hook prints {continue:false, stopReason}, consumes the request (renamed to .consumed)"
else
  bad "6f. hook output: '$HOOKOUT' (request present: $([ -e "$SR" ] && echo yes || echo no))"
fi
HOOKOUT="$("$STOP_HOOK" stop --repo "$FIX" </dev/null)"
if [ -z "$HOOKOUT" ]; then ok "6g. a second tool event prints nothing (single use)"; else bad "6g. the hook stopped twice: $HOOKOUT"; fi

put_request 200
HOOKOUT="$("$STOP_HOOK" stop --repo "$FIX" </dev/null)"
if [ -z "$HOOKOUT" ] && [ ! -e "$SR" ]; then ok "6h. a request older than 120 s prints nothing and is deleted"; else bad "6h. a stale request was honoured or kept: '$HOOKOUT'"; fi

put_request 1
"$STOP_HOOK" prompt --repo "$FIX" </dev/null
HOOKOUT="$("$STOP_HOOK" stop --repo "$FIX" </dev/null)"
if [ ! -e "$SR" ] && [ -z "$HOOKOUT" ]; then ok "6i. a pending request then UserPromptSubmit -> the request is gone and the next tool event prints nothing"; else bad "6i. prompt did not clear: '$HOOKOUT'"; fi

put_request 1
H1="$(CLAUDE_CODE_ENTRYPOINT=sdk-cli "$STOP_HOOK" stop --repo "$FIX" </dev/null)"
H2="$(HMD_AGENT_TYPE=hmd:reviewer "$STOP_HOOK" stop --repo "$FIX" </dev/null)"
H3="$(HMD_JUDGMENT=1 "$STOP_HOOK" stop --repo "$FIX" </dev/null)"
CLAUDE_CODE_ENTRYPOINT=sdk-cli "$STOP_HOOK" prompt --repo "$FIX" </dev/null
if [ -z "$H1$H2$H3" ] && [ -f "$SR" ]; then ok "6j. a headless / sub-session neither stops on nor clears the request (it stays pending for the operator's session)"; else bad "6j. an unattended session acted: '$H1$H2$H3'"; fi
rm -f "$SR"

for hid in phone-control-pretool phone-control-posttool phone-control-prompt; do
  if jq -e --arg id "$hid" '.hooks[] | select(.id == $id) | (.locked == false and .remote_toggle == false)' "$SIDECAR" >/dev/null 2>&1; then :; else bad "6k. $hid is missing from the registry or reachable"; fi
done
if "$HOOKS_CLI" check >/dev/null 2>&1; then ok "6k. the three phone-control hooks are in the registry (not locked, not remote_toggle) and heimdall-hooks check is clean"; else bad "6k. heimdall-hooks check fails"; fi
CMD="$(jq -r '.hooks.PreToolUse[] | select(.matcher == "*") | .hooks[0].command | select(contains("phone-control"))' "$HOOKS_JSON")"
TIMES="$(python3 - "$FIX" "$CMD" <<'PYEOF'
import os, subprocess, sys, time
fix, cmd = sys.argv[1:3]
env = dict(os.environ, CLAUDE_PROJECT_DIR=fix, CLAUDE_PLUGIN_ROOT=os.environ["REPO_ROOT"])
def run(argv):
    t = []
    for _ in range(200):
        a = time.perf_counter()
        subprocess.run(argv, env=env, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        t.append((time.perf_counter() - a) * 1000)
    t.sort()
    return t[len(t) // 2], t[int(len(t) * 0.99)]
b50, b99 = run(["sh", "-c", "exit 0"])      # what merely starting a shell costs on THIS machine, right now
c50, c99 = run(["sh", "-c", cmd])           # the wired command with nothing pending
print("%.1f %.1f %.1f %.1f" % (c50, c99, b50, b99))
PYEOF
)"
set -- $TIMES
P50="$1"; P99="$2"; B50="$3"; B99="$4"
if python3 -c "import sys; sys.exit(0 if float('$P50') - float('$B50') < 10 and float('$P99') - float('$B99') < 60 else 1)"; then
  ok "6l. the wired PreToolUse command with nothing pending costs a shell start and a file test: p50 ${P50} ms vs ${B50} ms for a bare shell, p99 ${P99} vs ${B99} (200 runs each; bound +10 / +60 ms)"
else
  bad "6l. the wired fast path costs more than a shell start: p50 ${P50} vs ${B50} ms, p99 ${P99} vs ${B99} ms"
fi

# ═══ 7. rate limits (fresh servers, fresh buckets) ═══════════════════════════════════════════════════════════
FIX_R="$(new_repo ratelimit)"
TXR="$(transcript_for "$FIX_R")"
tx "$TXR" working
start_ui "$FIX_R"
wait_att working >/dev/null
ctl '{"action":"interrupt","params":{}}';  C1="$CODE"
ctl '{"action":"interrupt","params":{}}';  C2="$CODE"
ctl '{"action":"interrupt","params":{}}';  C3="$CODE"
ctl '{"action":"interrupt","params":{}}'
if [ "$C1$C2$C3" = "200200200" ] && [ "$CODE" = "429" ] && jq_ok '.ok == false and .detail == "rate-limited" and (.retry_after_s | type == "number" and . > 0)'; then
  ok "7a. three interrupts pass, the 4th inside the minute -> 429 rate-limited with retry_after_s > 0"
else
  bad "7a. interrupt burst: $C1 $C2 $C3 then $CODE $BODY"
fi
RA="$(curl -s -D - -o /dev/null -X POST -H 'Content-Type: application/json' -d '{"action":"interrupt","params":{}}' "$UI_BASE/api/control?token=$UI_TOKEN" | tr -d '\r' | awk -F': ' 'tolower($1)=="retry-after"{print $2}')"
if [ -n "$RA" ] && [ "$RA" -gt 0 ] 2>/dev/null; then ok "7b. the 429 carries Retry-After: $RA"; else bad "7b. no Retry-After header on the 429"; fi
FIX_G="$(new_repo globalrate)"
start_ui "$FIX_G"
limited=0; passed=0; n=0
for _ in 1 2 3 4 5 6 7; do   # refusals cost no process, so the burst really is a burst
  ctl '{"action":"hook-toggle","params":{"id":"stub-gate","enabled":false}}'
  n=$((n + 1)); if [ "$CODE" = "429" ]; then limited=$((limited + 1)); elif [ "$CODE" = "403" ]; then passed=$((passed + 1)); fi
done
if [ "$passed" -eq 5 ] && [ "$limited" -eq 2 ]; then ok "7c. seven commands in a burst: the overall budget (burst 5) lets 5 reach the handler and refuses the other 2 with 429"; else bad "7c. expected 5 through and 2 refused out of $n, got $passed through and $limited refused"; fi

# ═══ 8. kill switch ═════════════════════════════════════════════════════════════════════════════════════════
FIX_K="$(new_repo killswitch)"
start_ui "$FIX_K"
E0="$(etag)"
OUT="$("$APP" controls off --repo "$FIX_K" 2>&1)"
if printf '%s' "$OUT" | grep -q "controls: off" && [ -f "$FIX_K/.heimdall/app/controls-disabled" ]; then ok "8a. hmd app controls off writes .heimdall/app/controls-disabled and says off"; else bad "8a. controls off: $OUT"; fi
all_off=1
for body in '{"action":"interrupt","params":{}}' '{"action":"save-checkpoint","params":{}}' \
            '{"action":"hook-toggle","params":{"id":"parallel-gate","enabled":false}}' '{"action":"fallback-mode","params":{"mode":"off"}}'; do
  ctl "$body"
  if [ "$CODE" = "403" ] && jq_ok '.ok == false and .detail == "controls-off"'; then :; else all_off=0; echo "       $body -> $CODE $BODY"; fi
done
if [ "$all_off" = 1 ]; then ok "8b. every action is refused 403 controls-off"; else bad "8b. an action ran with controls off"; fi
i=0; EN=""
while [ "$i" -lt 25 ]; do EN="$(state | jq -r '.controls.enabled')"; [ "$EN" = "false" ] && break; sleep 0.2; i=$((i + 1)); done
E1="$(etag)"
if [ "$EN" = "false" ] && [ "$E0" != "$E1" ]; then ok "8c. state.controls.enabled is false and the state digest moved (so the SSE / relay frame follows)"; else bad "8c. enabled=$EN, digest unchanged=$([ "$E0" = "$E1" ] && echo yes || echo no)"; fi
SEND="$(curl -s -o /dev/null -w '%{http_code}' -X POST -H 'Content-Type: application/json' -d '{"text":"hello from the phone"}' "$UI_BASE/api/send?token=$UI_TOKEN")"
if [ "$SEND" = "202" ]; then ok "8d. POST /api/send is untouched by the kill switch (202)"; else bad "8d. /api/send answered $SEND"; fi
"$APP" controls on --repo "$FIX_K" >/dev/null 2>&1
ctl '{"action":"hook-toggle","params":{"id":"parallel-gate","enabled":true}}'
expect "8e. hmd app controls on -> the action runs again" 200 '.ok == true'
FIX_E="$(new_repo killenv)"
HMD_UI_CONTROLS=0 start_ui "$FIX_E"
ctl '{"action":"save-checkpoint","params":{}}'
expect "8f. HMD_UI_CONTROLS=0 in the server's environment -> controls-off" 403 '.detail == "controls-off"'
if [ "$(state | jq -r '.controls.enabled')" = "false" ]; then ok "8g. ... and state.controls.enabled is false"; else bad "8g. enabled is not false under HMD_UI_CONTROLS=0"; fi
ctl '{"action":"rm-rf","params":{}}'
expect "8h. an unknown action is still not-implemented with the switch off (it never reaches anything)" 404 '.detail == "not-implemented"'

# ═══ 9. audit (the main repo's log holds every command the groups above sent it) ══════════════════════════════
AUD="$FIX/.heimdall/ui/controls-audit.jsonl"
start_ui "$FIX"
SECRET_ID="gh""p_$(python3 -c 'print("a" * 36)')"
ctl "{\"action\":\"hook-toggle\",\"params\":{\"id\":\"$SECRET_ID\",\"enabled\":false}}"
if [ -f "$AUD" ]; then
  LINES="$(wc -l < "$AUD" | tr -d ' ')"
  if [ "$(mode_of "$AUD")" = "600" ] && [ "$(mode_of "$FIX/.heimdall/ui")" = "700" ]; then ok "9a. the audit log is mode 600 in a 0700 directory"; else bad "9a. audit mode $(mode_of "$AUD"), dir mode $(mode_of "$FIX/.heimdall/ui")"; fi
  if jq -e -s 'length > 25 and all(.[]; has("text") | not) and all(.[]; has("rid") | not) and all(.[]; (.params | keys - ["id","enabled","mode","confirm"]) == [])' "$AUD" >/dev/null 2>&1; then
    ok "9b. $LINES lines, none with free text or a rid, params only from the whitelist (id, enabled, mode, confirm)"
  else
    bad "9b. audit lines carry something outside the whitelist"
  fi
  if jq -e -s 'any(.[]; .detail == "not-implemented") and any(.[]; .detail == "bad-params") and any(.[]; .detail == "not-allowed") and any(.[]; .ok == true) and any(.[]; .dup == true) and any(.[]; (.id // "") | test("^s-[0-9a-f]{8}$"))' "$AUD" >/dev/null 2>&1; then
    ok "9c. refused, unknown and duplicate commands are audited as well as the ones that ran (an interrupt line carries its stop id)"
  else
    bad "9c. the audit log is missing a refused / unknown / dup / interrupt command"
  fi
  if jq -e -s 'all(.[]; (.ts | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:.]+Z$")) and (.device == "direct") and (.ms | type == "number") and (.via == "direct"))' "$AUD" >/dev/null 2>&1; then
    ok "9d. every line has ts, device (direct), ms and the transport"
  else
    bad "9d. an audit line is malformed"
  fi
  if ! grep -q "$SECRET_ID" "$AUD" && tail -1 "$AUD" | jq -e '.detail == "unknown-id" and .params == {"enabled": false}' >/dev/null 2>&1; then
    ok "9e. a secret-shaped id is refused and kept out of the audit line"
  else
    bad "9e. a secret-shaped id reached the audit log"
  fi
else
  bad "9. no audit log was written"
fi
LAST="$(state | jq -c '.controls.last')"
if printf '%s' "$LAST" | jq -e '(keys == ["action","at","ok"]) and (.action | type == "string") and (.ok | type == "boolean") and (.at | type == "number")' >/dev/null 2>&1; then
  ok "9f. state.controls.last is {action, ok, at} and carries no params ($LAST)"
else
  bad "9f. controls.last is $LAST"
fi

# ═══ 10. the state key and the registry ═══════════════════════════════════════════════════════════════════════
S="$(state)"
if printf '%s' "$S" | jq -e '.controls.v == 1 and (.controls.actions == ["interrupt","save-checkpoint","hook-toggle","fallback-mode"]) and .controls.enabled == true and (.controls.hooks_toggleable | length) == 13' >/dev/null 2>&1; then
  ok "10a. state.controls: v 1, the four actions, enabled, 13 toggleable hooks"
else
  bad "10a. controls is $(printf '%s' "$S" | jq -c .controls | cut -c1-300)"
fi
if printf '%s' "$S" | jq -e '.controls as $c | (($c.hooks | map(.id)) == $c.hooks_toggleable) and ($c.hooks | all(.[]; (.enabled | type == "boolean")))' >/dev/null 2>&1; then
  ok "10b. controls.hooks lists each toggleable hook's current enabled flag"
else
  bad "10b. controls.hooks does not match hooks_toggleable"
fi
if jq -e '[.hooks[] | select(.remote_toggle and .locked)] | length == 0' "$SIDECAR" >/dev/null 2>&1 \
   && jq -e '[.hooks[] | select(.remote_toggle)] | length == 13' "$SIDECAR" >/dev/null 2>&1; then
  ok "10c. no registry entry is both locked and remote_toggle; exactly 13 hooks are remote_toggle"
else
  bad "10c. the registry's remote_toggle set is wrong"
fi
REGEN_META="$TMPROOT/sidecar-regen.json"
cp "$SIDECAR" "$REGEN_META"
"$HOOKS_CLI" regen --metadata "$REGEN_META" >/dev/null 2>&1
if cmp -s "$SIDECAR" "$REGEN_META"; then ok "10d. heimdall-hooks regen leaves every remote_toggle value untouched (sidecar byte-identical)"; else bad "10d. regen changed the sidecar"; fi
if "$HOOKS_CLI" list --json | jq -e 'all(.[]; has("remote_toggle")) and ([.[] | select(.remote_toggle)] | length == 13)' >/dev/null 2>&1; then ok "10e. heimdall-hooks list --json exposes remote_toggle"; else bad "10e. list --json lacks remote_toggle"; fi

# every offered hook round-trips (disable then enable) and every other registry id is refused with hooks-disabled
# byte-identical -- in-process against the real module, rate limits reset between calls
ROUND="$(python3 - "$CTL_LIB" "$SIDECAR" <<'PYEOF'
import importlib.util, json, os, sys
spec = importlib.util.spec_from_file_location("c", sys.argv[1])
C = importlib.util.module_from_spec(spec); spec.loader.exec_module(C)
root = os.path.join(os.environ["TMPDIR"], "roundtrip-repo"); os.makedirs(root, exist_ok=True)
ids = [e["id"] for e in json.load(open(sys.argv[2]))["hooks"]]
toggleable = C.toggleable_hooks()
disabled_file = os.path.join(os.environ["HEIMDALL_HOME"], "hooks-disabled")
def disabled():
    try:
        return sorted(l.strip() for l in open(disabled_file) if l.strip())
    except OSError:
        return []
bad = []
for hid in toggleable:
    C._BUCKETS.clear()
    ok, d, _ = C.dispatch(root, "hook-toggle", {"id": hid, "enabled": False})
    if not ok or disabled() != [hid]:
        bad.append("disable %s -> %s %s %s" % (hid, ok, d, disabled()))
    C._BUCKETS.clear()
    ok, d, _ = C.dispatch(root, "hook-toggle", {"id": hid, "enabled": True})
    if not ok or disabled() != []:
        bad.append("enable %s -> %s %s %s" % (hid, ok, d, disabled()))
before = open(disabled_file).read() if os.path.exists(disabled_file) else None
for hid in ids:
    if hid in toggleable:
        continue
    C._BUCKETS.clear()
    ok, d, _ = C.dispatch(root, "hook-toggle", {"id": hid, "enabled": False})
    if ok or d != "not-allowed":
        bad.append("%s was not refused: %s %s" % (hid, ok, d))
after = open(disabled_file).read() if os.path.exists(disabled_file) else None
if before != after:
    bad.append("hooks-disabled changed while refusing")
print(json.dumps({"toggleable": len(toggleable), "refused": len(ids) - len(toggleable), "total": len(ids), "bad": bad}))
PYEOF
)"
if printf '%s' "$ROUND" | jq -e '.bad == [] and .toggleable == 13 and (.refused + .toggleable == .total)' >/dev/null 2>&1; then
  ok "10f. all 13 offered hooks disable/enable cleanly; the other $(printf '%s' "$ROUND" | jq .refused) (locked, never-lose, commits, the phone's own paths) are not-allowed and hooks-disabled never moved"
else
  bad "10f. allowlist round trip: $ROUND"
fi

# ═══ 11. mutants: the same checks against deliberately broken copies must fail ═══════════════════════════════
MUT="$TMPROOT/mutants.py"
cat > "$MUT" <<'PYEOF'
import importlib.util, json, os, sys, tempfile, time

def load(path, name):
    spec = importlib.util.spec_from_file_location(name, path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod

def checks(C):
    """The list of failed expectations for module C (empty for the real module)."""
    failed = []
    root = tempfile.mkdtemp(prefix="mut-")
    def d(action, params):
        C._BUCKETS.clear()
        return C.dispatch(root, action, params)
    ok, detail, _ = d("rm-rf", {})
    if (ok, detail) != (False, "not-implemented"):
        failed.append("unknown action ran or was misreported: %r" % ((ok, detail),))
    ok, detail, _ = d("hook-toggle", {"id": "inbox-deliver-stop", "enabled": False})
    if (ok, detail) != (False, "not-allowed"):
        failed.append("a non-remote_toggle advisory hook was toggleable: %r" % ((ok, detail),))
    ok, detail, _ = d("hook-toggle", {"id": "stub-gate", "enabled": False})
    if (ok, detail) != (False, "not-allowed"):
        failed.append("a locked hook was toggleable: %r" % ((ok, detail),))
    d("hook-toggle", {"id": "dream-notice", "enabled": False, "rid": "m1"})
    again = d("hook-toggle", {"id": "dream-notice", "enabled": False, "rid": "m1"})
    d("hook-toggle", {"id": "dream-notice", "enabled": True})
    if again[2].get("dup") is not True:
        failed.append("a repeated rid was not answered dup")
    ok, detail, _ = d("fallback-mode", {"mode": "switch"})
    if (ok, detail) != (False, "confirm-required"):
        failed.append("switch ran without confirm: %r" % ((ok, detail),))
    ok, detail, _ = d("fallback-mode", {"mode": "coop"})
    if (ok, detail) != (False, "confirm-required"):
        failed.append("coop ran without confirm, or was not offered at all: %r" % ((ok, detail),))
    fb = C.snapshot(root)["fallback"]
    if fb["modes"] != ["off", "auto", "switch", "coop"] or fb["confirm"] != ["auto", "switch", "coop"]:
        failed.append("the state offers the wrong modes / confirm set: %r" % (fb,))
    ok, detail, _ = d("interrupt", {})
    if ok or os.path.exists(os.path.join(root, ".heimdall", "ui", "stop-request.json")):
        failed.append("interrupt wrote a request for a session that is not working")
    C.clear_stop_request(root)
    C._write_stop(root, {"id": "s-12345678", "requested_at": time.time(), "turn": None, "device": "x"})
    one = C.consume_stop_request(root)
    two = C.consume_stop_request(root)
    if one is None or two is not None:
        failed.append("a stop request was not single use: %r then %r" % (one, two))
    C._write_stop(root, {"id": "s-12345679", "requested_at": time.time() - 500, "turn": None, "device": "x"})
    if C.consume_stop_request(root) is not None:
        failed.append("a stop request past its TTL was honoured")
    C._write_stop(root, {"id": "s-1234567a", "requested_at": time.time(), "turn": None, "device": "x"})
    C.clear_stop_request(root)
    if os.path.exists(os.path.join(root, ".heimdall", "ui", "stop-request.json")):
        failed.append("a new prompt did not clear a pending request")
    return failed

real = load(sys.argv[1], "real")
print("REAL", json.dumps(checks(real)))
src = open(sys.argv[1]).read()
mutants = [
    ("allowlist-runs-anything", "if not isinstance(action, str) or action not in _ACTIONS:", "if not isinstance(action, str):"),
    ("toggle-checks-only-locked", 'return entry.get("remote_toggle") is True and not entry.get("locked")', 'return not entry.get("locked")'),
    ("no-dedupe", "            if hit is not None:\n                ok, detail, extra = hit", "            if False:\n                ok, detail, extra = hit"),
    ("switch-needs-no-confirm", 'if mode in CONFIRM_MODES and fields["confirm"] is not True:', "if False:"),
    ("coop-needs-no-confirm", 'CONFIRM_MODES = tuple(m for m in FALLBACK_MODES if m != "off")', 'CONFIRM_MODES = ("auto", "switch")'),
    ("coop-not-offered", 'FALLBACK_MODES = ("off", "auto", "switch", "coop")', 'FALLBACK_MODES = ("off", "auto", "switch")'),
    ("interrupt-writes-while-idle", 'if attention.get("state") != "working":', "if False:"),
    ("stop-not-single-use", "os.replace(claim, os.path.join(root, STOP_CONSUMED_REL))\n        return record", "os.replace(claim, path)\n        return record"),
    ("ttl-ignored", "return -5.0 <= now - requested < STOP_TTL_S", "return True"),
    ("prompt-does-not-clear", "        os.unlink(_stop_path(root))\n    except OSError:\n        return False\n    return True",
     "        return False\n    except OSError:\n        return False\n    return True"),
]
for name, old, new in mutants:
    if old not in src:
        print("MUTANT", name, "NO-ANCHOR")
        continue
    path = os.path.join(tempfile.mkdtemp(prefix="mutsrc-"), "companion_ui_controls.py")
    open(path, "w").write(src.replace(old, new, 1))
    try:
        failed = checks(load(path, "mut_" + name.replace("-", "_")))
    except Exception as e:
        failed = ["crashed: %s" % type(e).__name__]
    print("MUTANT", name, "CAUGHT" if failed else "SURVIVED", json.dumps(failed)[:140])
PYEOF
MUTOUT="$(python3 "$MUT" "$CTL_LIB" 2>&1)"
if printf '%s' "$MUTOUT" | grep -q '^REAL \[\]$'; then ok "11a. the checks pass against the real module"; else bad "11a. the checks fail on the real module: $(printf '%s' "$MUTOUT" | head -2)"; fi
SURV="$(printf '%s' "$MUTOUT" | grep -c ' SURVIVED \| NO-ANCHOR' || true)"
CAUGHT="$(printf '%s' "$MUTOUT" | grep -c ' CAUGHT ' || true)"
if [ "$CAUGHT" = "10" ] && [ "$SURV" = "0" ]; then ok "11b. all 10 mutants (allowlist, toggle gate, dedupe, confirm, coop confirm, coop offered, idle write, single use, TTL, prompt clear) are caught"; else bad "11b. caught $CAUGHT of 10, survived/no-anchor $SURV: $(printf '%s' "$MUTOUT" | grep MUTANT)"; fi

# ═══ 12. class tags and the kill-switch exemption (the CP1 carve-outs of hmdapp's cursor-parity handoff) ══════════
# Every action carries one of read / safe-write / risky-write / expand; `expand` is gated by the laptop's switches (the full
# battery is test/heimdall-remote-switches.test.sh); the kill switch turns every action into controls-off EXCEPT launch-stop,
# which only ends what the phone started. Nothing has registered launch-stop yet, so the in-process half registers one the way
# its ask will, and the real server half proves the reserved names are gated before any handler exists.
CLS="$TMPROOT/classes.py"
cat > "$CLS" <<'PYEOF'
import importlib.util, json, os, sys, tempfile, uuid

def load(libdir):
    spec = importlib.util.spec_from_file_location("c_" + uuid.uuid4().hex, os.path.join(libdir, "companion_ui_controls.py"))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod

def checks(libdir):
    failed = []
    def expect(label, cond, got=""):
        if not cond:
            failed.append("%s [%s]" % (label, str(got)[:160]))
    os.environ.pop("HMD_UI_CONTROLS", None)
    C = load(libdir)
    root = tempfile.mkdtemp(prefix="cls-")
    stopped = []
    def h_stop(r, fields, ctx):
        stopped.append(fields["id"])
        return True, None, {"id": fields["id"]}
    C.register_action("launch-stop", cls="safe-write", required=("id",), fields=lambda b: {"id": b["id"]},
                      audit=lambda f: {"id": f["id"]}, handler=h_stop)
    C.register_action("x-view", cls="read", handler=lambda r, f, c: (True, None, {}))
    pins = {"interrupt": "safe-write", "save-checkpoint": "safe-write", "hook-toggle": "risky-write", "fallback-mode": "risky-write"}
    expect("the four shipped actions carry the pinned class tags", all(C._ACTIONS[k]["cls"] == v for k, v in pins.items()))
    expect("every allowed action has a class from the closed set", all(C._ACTIONS[a]["cls"] in C.CLASSES for a in C.ALLOWED_ACTIONS))
    expect("the classes are exactly read / safe-write / risky-write / expand", C.CLASSES == ("read", "safe-write", "risky-write", "expand"))
    C2 = load(libdir)
    try:
        C2.register_action("launch-stop", cls="risky-write", handler=lambda r, f, c: (True, None, {}))
        refused = False
    except ValueError:
        refused = True
    expect("launch-stop cannot be registered as anything but safe-write", refused)
    def d(action, params):
        C._BUCKETS.clear()
        return C.dispatch(root, action, params)
    for how in ("env", "file"):
        if how == "env":
            os.environ["HMD_UI_CONTROLS"] = "0"
        else:
            os.environ.pop("HMD_UI_CONTROLS", None)
            C.set_enabled(root, False)
        expect("(%s) launch-stop runs under the kill switch" % how, d("launch-stop", {"id": "l-77"})[0] is True)
        expect("(%s) every other action -- a read one included -- is controls-off" % how,
               all(d(a, {})[:2] == (False, "controls-off") for a in ("x-view", "save-checkpoint", "interrupt", "launch-session", "pr-merge")))
        expect("(%s) the exemption is by NAME: a look-alike is still not-implemented" % how, d("launch-stoop", {"id": "l-77"})[:2] == (False, "not-implemented"))
    os.environ.pop("HMD_UI_CONTROLS", None)
    C.set_enabled(root, True)
    expect("with the kill switch off again launch-stop and a read action both run", d("launch-stop", {"id": "l-78"})[0] is True and d("x-view", {})[0] is True)
    return failed

real = checks(sys.argv[1])
print("REAL", json.dumps(real))
ctl_src = open(os.path.join(sys.argv[1], "companion_ui_controls.py")).read()
sw_src = open(os.path.join(sys.argv[1], "companion_remote_switches.py")).read()
mutants = [
    ("launch-stop-needs-the-switch", 'KILL_SWITCH_EXEMPT = frozenset(("launch-stop",))', "KILL_SWITCH_EXEMPT = frozenset()"),
    ("kill-switch-exempts-everything", "    if action not in KILL_SWITCH_EXEMPT and not controls_enabled(root):", "    if False:"),
    ("exempt-class-unchecked", "    if name in KILL_SWITCH_EXEMPT and cls != CLASS_SAFE_WRITE:", "    if False:"),
    ("reserved-names-unnamed", 'RESERVED_EXPAND = {"launch-session": "launch", "pr-merge": "merge"}', "RESERVED_EXPAND = {}"),
]
for name, old, new in mutants:
    if old not in ctl_src:
        print("MUTANT", name, "NO-ANCHOR")
        continue
    d = tempfile.mkdtemp(prefix="clsmut-")
    open(os.path.join(d, "companion_ui_controls.py"), "w").write(ctl_src.replace(old, new, 1))
    open(os.path.join(d, "companion_remote_switches.py"), "w").write(sw_src)
    try:
        failed = checks(d)
    except Exception as e:
        failed = ["crashed: %s" % type(e).__name__]
    print("MUTANT", name, "CAUGHT" if failed else "SURVIVED", json.dumps(failed)[:140])
PYEOF
CLSOUT="$(python3 "$CLS" "$REPO/bin/lib" 2>/dev/null)"
if printf '%s' "$CLSOUT" | grep -q '^REAL \[\]$'; then ok "12a class tags (closed set, the four pinned) and the launch-stop kill-switch exemption hold on the real module"; else bad "12a class tags / exemption: $(printf '%s' "$CLSOUT" | head -3 | cut -c1-500)"; fi
CAUGHT="$(printf '%s' "$CLSOUT" | grep -c ' CAUGHT ' || true)"
SURV="$(printf '%s' "$CLSOUT" | grep -c ' SURVIVED \| NO-ANCHOR' || true)"
if [ "$CAUGHT" = "3" ] && [ "$SURV" = "1" ] && printf '%s' "$CLSOUT" | grep -q 'MUTANT reserved-names-unnamed SURVIVED'; then
  bad "12b the reserved-names mutant survived: the in-process half does not check a reserved name's gate"
elif [ "$CAUGHT" = "4" ] && [ "$SURV" = "0" ]; then
  ok "12b all 4 mutants (launch-stop needing the switch, a kill switch that exempts everything, an exempt class unchecked, reserved names unnamed) are caught"
else
  bad "12b caught $CAUGHT of 4, survived/no-anchor $SURV: $(printf '%s' "$CLSOUT" | grep MUTANT)"
fi
FIX_X="$(new_repo expandgate)"
HMD_UI_CONTROLS=0 start_ui "$FIX_X"
ctl '{"action":"launch-session","params":{"repo":"r-0000","branch":"x"}}'
expect "12c the kill switch beats the expand gate: launch-session -> 403 controls-off" 403 '.ok == false and .detail == "controls-off"'
ctl '{"action":"launch-stop","params":{"id":"l-1"}}'
expect "12d launch-stop is exempt from the kill switch, but nothing registered a handler yet -> 404 not-implemented, never controls-off" 404 '.ok == false and .detail == "not-implemented"'
start_ui "$FIX_X"
ctl '{"action":"pr-merge","params":{"number":1,"method":"squash"}}'
expect "12e the reserved expand name pr-merge is gated before any handler exists: 403 not-allowed while the switch is off" 403 '.ok == false and .detail == "not-allowed"'
stop_ui

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
