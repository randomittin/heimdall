#!/usr/bin/env bash
# Journey 08 -- pair a phone with the session by its code (README "The phone companion", `hmd app connect --help`, docs/GTM-2.4.x.md demo step "Pair").
#
#   A developer wants to steer their coding session from a phone. The laptop is signed in to GitHub (`gh`), the relay is the one network hop between the two,
#   and it is the one party hmd must not trust blindly: it is only ever told what hmd means to tell it.
#     1. `hmd app connect` shows a SESSION CODE, says to type it in the app and who may (the laptop's GitHub login); the relay holds that very code, registered with
#        the laptop's GitHub token and a commitment to hmd's key -- nothing else -- and the token is never printed
#     2. a claim the relay passes on for ANOTHER GitHub account is refused: the developer is told, nothing is revealed or sealed to that phone and its session is
#        revoked. (A relay that lies about whose phone it is: hmd checks the login itself, before any key moves.)
#     3. `hmd app connect` again offers the same code (it is the repo's, not the run's) and the developer's own phone types it: connect says the phone paired by
#        code and names the device and account the relay claimed
#     4. the phone checks the key hmd revealed against the commitment it was given, derives the session key and opens the first state: the key came first, the state
#        is sealed on the wire (the relay never held it in the clear) and it names this repo's session code
#     5. the pairing shows on the laptop: `hmd app status` lists the phone, and the Claude session is handed a notice naming it -- what tells a developer that a
#        phone they did not expect got in
#     6. the GitHub token left the laptop once per code the developer asked for and is on no file, no screen and no command line
#     7. `hmd app disconnect` unpairs: the relay is told to end the session, no phone is listed, and no hmd ui, relay client or connect of this journey is left running
#     8. a model was never called, the keychain was never asked and no temp file of connect is left behind
#
# The relay and the phone are one python process this journey starts and stops by pid (never by name): test/lib/fake_relay_code.py answers the relay's pair-by-code
# surface and never binds a phone on its own; test/lib/pair_code_harness.py supplies the phone's keys and the commitment reference. Both are what
# test/app-pair-code.test.sh and test/app-pair-confirm.test.sh drive the same client with, case by case; this walks one developer through them. `gh` and the
# tailscale binary are doubles; the macOS keychain is never reached (HMD_SESSION_LOGIN_STORE=file, and the fake `security` logs any call).
# Nothing here reaches past HOME: hmd records the per-repo choice in the ACCOUNT's own home (read from the account database, not HOME), so a stand-in home that
# carries the test marker is named in HMD_TEST_CANONICAL_HOME and proved believed before anything starts.
# Mutants (test/use-cases/mutants.list): a claim for another GitHub account is believed, a pairing leaves no notice in the session.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib.sh
. "$HERE/../lib.sh"
uc_begin 08_pair_a_phone
uc_tree
uc_fakebin
UC_PATH="${HMD_MKTEMP_SHIM_DIR:+$HMD_MKTEMP_SHIM_DIR:}$UC_PATH"   # this platform's mktemp ignores TMPDIR: connect's bare mktemp calls must follow it into the private root (test/lib/private-tmp.sh)
uc_sandbox pair

HH="$UC_ROOT/pair/heimdall-home"           # hmd's own state, kept apart from HOME
CANON="$UC_ROOT/pair/canonical-home"       # stands in for the account's own ~/.heimdall (see the header)
CTL="$UC_ROOT/pair/phone"                  # the relay-and-phone process's control directory
SEEN="$CTL/seen.json"                      # what it saw, rewritten about five times a second
WIRE="$CTL/wire.json"                      # every frame hmd posted to the relay, as the relay read it
REPO="$UC_WORK/shop"
TOKEN="journey-08-fake-github-token-0123456789"   # fake on purpose: it matches no real credential pattern, and every check below looks for exactly this string
DRIVER_PID=""
CONNECT_PID=""
HMD_ENV=(HEIMDALL_HOME="$HH" HMD_TEST_CANONICAL_HOME="$CANON" HMD_SESSION_LOGIN_STORE=file HMD_RELAY_STREAM_TRANSPORT=ndjson HMD_RELAY_BACKOFF_BASE_MS=200 HMD_TAILSCALE_BIN="$UC_ROOT/pair/no-tailscale")
hmd() { uc_run "$UC_HOME" "$REPO" "${HMD_ENV[@]}" -- "$UC_TREE/bin/hmd" "$@"; }

# wait_text FILE REGEX SECS / wait_seen JQ SECS / wait_gone PID SECS -- polled every 0.2 s until it holds or SECS pass: a readiness check that gives up, never a speed assertion
wait_text() { local n=$(( $3 * 5 )); while [ "$n" -gt 0 ]; do grep -Eq -- "$2" "$1" 2>/dev/null && return 0; sleep 0.2; n=$((n - 1)); done; return 1; }
wait_seen() { local n=$(( $2 * 5 )); while [ "$n" -gt 0 ]; do jq -e "$1" "$SEEN" >/dev/null 2>&1 && return 0; sleep 0.2; n=$((n - 1)); done; return 1; }
wait_gone() { local n=$(( $2 * 5 )); [ -n "$1" ] || return 1; while [ "$n" -gt 0 ]; do kill -0 "$1" 2>/dev/null || return 0; sleep 0.2; n=$((n - 1)); done; return 1; }

# a pid is signalled only while its command line still names something this journey started: the tree under test or its own temp root
stop_mine() {
  case "$(ps -ww -o command= -p "${1:-0}" 2>/dev/null)" in *"$UC_TREE"*|*"$UC_ROOT"*) kill -TERM "$1" 2>/dev/null ;; esac
  return 0
}

# the journey ends however it ends: the product's own teardown first (it names each process before it signals one), then the pids this journey started, then the temp root
cleanup() {
  stop_mine "$CONNECT_PID"
  [ ! -e "$REPO/.heimdall/app/connect.json" ] || hmd app disconnect >/dev/null 2>&1
  stop_mine "$DRIVER_PID"
  hmd_private_tmp_rm
}
trap cleanup EXIT

# start_connect N -- `hmd app connect` left running in the foreground, as a developer leaves it in a terminal. uc_run waits for its command, so a one-line launcher
# starts connect in the background and returns; the output goes to connect-N.out and the pid to connect-N.pid, which this journey owns.
start_connect() {
  CONNECT_OUT="$UC_ROOT/connect-$1.out"
  : > "$CONNECT_OUT"
  # shellcheck disable=SC2016  # the launcher's own shell expands these, not this one
  uc_run "$UC_HOME" "$REPO" "${HMD_ENV[@]}" -- \
    sh -c 'out=$1; pidfile=$2; shift 2; "$@" >"$out" 2>&1 </dev/null & echo $! >"$pidfile"' sh "$CONNECT_OUT" "$UC_ROOT/connect-$1.pid" \
    "$UC_TREE/bin/hmd" app connect --relay "$RELAY" --repo "$REPO" --port 0
  CONNECT_PID="$(cat "$UC_ROOT/connect-$1.pid" 2>/dev/null)"
  CONNECT_UI_PID=""; CONNECT_CLIENT_PID=""
}

# note_pids -- what the running connect started, from its own record
note_pids() {
  CONNECT_UI_PID="$(jq -r '.pid_ui // empty' "$REPO/.heimdall/app/connect.json" 2>/dev/null)"
  CONNECT_CLIENT_PID="$(jq -r '.pid_client // empty' "$REPO/.heimdall/app/connect.json" 2>/dev/null)"
}

# phone_types N CODE LOGIN LABEL -- a phone types CODE in the app; LOGIN is the GitHub account the relay says that phone is signed in as
phone_types() {
  printf '{"code":"%s","login":"%s","label":"%s"}\n' "$2" "$3" "$4" > "$CTL/claim-$1.tmp" && mv "$CTL/claim-$1.tmp" "$CTL/claim-$1.json"
}

# the code as printed on screen
shown_code() { sed -n 's/^  SESSION CODE: \([ABCDEFGHJKLMNPQRSTUVWXYZ23456789]\{5\}\)$/\1/p' "$1" | head -1; }
CODE_RE='[ABCDEFGHJKLMNPQRSTUVWXYZ23456789]{5}'

# ── the world: a repo, a signed-in `gh`, the stand-in home, the relay and the phone ─────────────────────────────────────────────────────────────────────
mkdir -p "$HH" "$CTL" "$CANON" "$REPO"
: > "$HH/setup-done"                       # no first-run setup is part of this journey
chmod 700 "$CANON"
printf 'a test stand-in for the account home\n' > "$CANON/.hmd-test-canonical-home"
chmod 600 "$CANON/.hmd-test-canonical-home"
cat > "$UC_BIN/gh" <<EOF
#!/bin/sh
echo "gh \$*" >> "$UC_ROOT/gh.log"
if [ "\$1" = auth ] && [ "\$2" = token ]; then printf '%s\n' "$TOKEN"; exit 0; fi
echo 'fake gh: unsupported' >&2
exit 2
EOF
chmod +x "$UC_BIN/gh"
: > "$UC_ROOT/gh.log"

# hmd would record its per-repo choice in the account's real ~/.heimdall unless the stand-in is believed: prove that before anything runs
uc_run "$UC_HOME" "$UC_WORK" HMD_TEST_CANONICAL_HOME="$CANON" -- "$UC_PY" -I -B -c \
  'import sys; sys.path.insert(0, sys.argv[1]); import hmd_pair_optin; print("\n".join(hmd_pair_optin.canonical_homes()))' "$UC_TREE/bin/lib"
if [ "$UC_RC" -eq 0 ] && grep -Fxq -- "$CANON" "$UC_OUT"; then uc_ok "(setup) the stand-in home is the one hmd believes: nothing is recorded in the account's real home"; else uc_fatal "the stand-in home is not believed: connect would record its choice in the real ~/.heimdall"; fi

uc_run "$UC_HOME" "$UC_WORK" -- git init -q "$REPO"
uc_run "$UC_HOME" "$REPO" -- git -c user.email=dev@example.com -c user.name=Dev -c commit.gpgsign=false commit -q --allow-empty -m "start of the shop"
uc_rc "(setup) the developer has a git repo" 0

cat > "$UC_ROOT/phone.py" <<'PY'
import json
import os
import sys
import time

tree, ctl = sys.argv[1], sys.argv[2]
sys.path.insert(0, os.path.join(tree, "test", "lib"))
import pair_code_harness as H
from fake_relay_code import FakeCodeRelay

e2e = H.load_module("hmd_relay_e2e", H.E2E_PATH)
relay = FakeCodeRelay(ttl_s=360, gh_login="octocat", expect_token=os.environ["JOURNEY_GH_TOKEN"]).start()
phones = dict()   # session id -> the phone that claimed it
claims = []
saw = dict()      # session id -> what that phone could tell of the pairing
errors = []
wired = 0


def put(name, obj):
    path = os.path.join(ctl, name)
    with open(path + ".tmp", "w", encoding="utf-8") as f:
        json.dump(obj, f)
    os.replace(path + ".tmp", path)


def open_session_for(code):
    # the relay holds a code for the newest session registered under it that is neither ended nor claimed (a real relay releases a code at the bind)
    with relay.lock:
        sids = [r["session_id"] for r in relay.registrations if r["code"] == code]
    for sid in reversed(sids):
        sess = relay.get(sid)
        if sess is not None and not sess.ended and sid not in phones:
            return sid
    return None


def claim(n, cmd):
    sid = open_session_for(cmd["code"])
    claims.append({"n": n, "code": cmd["code"], "login": cmd["login"], "label": cmd["label"], "session": sid,
                   "result": "claimed" if sid else "no-open-session"})
    if sid:
        phones[sid] = H.Phone(e2e)
        relay.inject_device_bound(sid, phones[sid].pub_b64url, via="code", device_label=cmd["label"], gh_login=cmd["login"])


def look():
    # what each phone can tell once hmd answers its claim: the revealed key checked against the commitment it was given, and the first state it can open
    with relay.lock:
        commits = dict((r["session_id"], r["hmd_commit"]) for r in relay.registrations)
    for sid, phone in phones.items():
        if saw.get(sid, dict()).get("opened"):
            continue
        reveals, states = relay.frames_of(sid, "key_reveal"), relay.frames_of(sid, "state")
        if not reveals:
            continue
        hmd_pub = H.b64_any(reveals[0]["payload"]["hmd_pubkey"])
        nonce = H.b64_any(reveals[0]["payload"]["nonce"])
        found = {"commitment_ok": H.commit_ref(hmd_pub, nonce) == commits.get(sid), "opened": False, "session_code": None}
        plain = phone.open_hmd_frame(hmd_pub, sid, states[0]) if states else None
        if plain is not None:
            found["opened"] = True
            found["session_code"] = ((plain.get("state") or dict()).get("identity") or dict()).get("session_code")
        saw[sid] = found


def report():
    global wired
    with relay.lock:
        regs = [{"session": r["session_id"], "code": r["code"], "token_ok": r["token_ok"], "keys": r["keys"]} for r in relay.registrations]
        frames = list(relay.frames)
        revokes = list(relay.revokes)
    by_session = dict()
    for sid, env in frames:
        by_session.setdefault(sid, []).append(env.get("type"))
    if len(frames) != wired:
        wired = len(frames)
        put("wire.json", [{"session": sid, "envelope": env} for sid, env in frames])
    put("seen.json", {"registrations": regs, "frames": by_session, "revokes": revokes, "claims": claims, "phone": saw, "errors": errors})


with open(os.path.join(ctl, "port"), "w", encoding="utf-8") as f:
    f.write(str(relay.port))
done = 0
while True:
    try:
        nxt = os.path.join(ctl, "claim-%d.json" % (done + 1))
        if os.path.exists(nxt):
            with open(nxt, encoding="utf-8") as f:
                claim(done + 1, json.load(f))
            done += 1
        look()
        report()
    except Exception as exc:  # reported to the journey, which fails on any
        errors.append(repr(exc))
    time.sleep(0.2)
PY
JOURNEY_GH_TOKEN="$TOKEN" "$UC_PY" -I -B "$UC_ROOT/phone.py" "$UC_TREE" "$CTL" > "$UC_ROOT/phone.log" 2>&1 &
DRIVER_PID=$!
if wait_text "$CTL/port" '^[0-9]+$' 30 && wait_seen '.errors == []' 30; then
  RELAY="http://127.0.0.1:$(cat "$CTL/port")"
  uc_ok "(setup) the relay and the phone are up on $RELAY"
else
  uc_bad "(setup) the relay and the phone did not start" "$(head -c 400 "$UC_ROOT/phone.log" | LC_ALL=C tr '\n' ' ')"
  uc_finish
fi

# ── 1. connect shows a code ─────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
start_connect 1
CONNECT1_OUT="$CONNECT_OUT"; CONNECT1_PID="$CONNECT_PID"
if wait_text "$CONNECT1_OUT" "^  SESSION CODE: $CODE_RE\$" 60; then
  CODE="$(shown_code "$CONNECT1_OUT")"
  uc_ok "hmd app connect shows a session code: $CODE"
else
  uc_bad "hmd app connect never showed a session code" "$(head -c 600 "$CONNECT1_OUT" | LC_ALL=C tr '\n' ' ')"
  uc_finish
fi
note_pids; CONNECT1_UI_PID="$CONNECT_UI_PID"; CONNECT1_CLIENT_PID="$CONNECT_CLIENT_PID"
uc_has "…says to type it in the app" "$CONNECT1_OUT" "tap \"Enter code\" and type $CODE\\."
uc_has "…and that only a phone signed in as the laptop's own GitHub account can use it" "$CONNECT1_OUT" 'Only a phone signed in to GitHub as @octocat can use it'
uc_has "…and that the token went out once, for this registration" "$CONNECT1_OUT" 'Your gh token was sent once, for this registration'
wait_seen '(.registrations | length) >= 1' 20
uc_jq "the relay holds exactly that code, registered once, with the laptop's GitHub token" ".registrations | length == 1 and .[0].code == \"$CODE\" and .[0].token_ok == true" "$SEEN"
uc_jq "…the registration carried the code, the token and a commitment to hmd's key, nothing else" '.registrations[0].keys == ["code", "gh_token", "hmd_commit"]' "$SEEN"
uc_lacks "connect never prints the token" "$CONNECT1_OUT" "$TOKEN"

# ── 2. a claim for another GitHub account is refused ────────────────────────────────────────────────────────────────────────────────────────────────
phone_types 1 "$CODE" mallory "Mallory Phone"
wait_text "$CONNECT1_OUT" 'pairing rejected|phone paired via code' 30
wait_seen '(.claims | length) >= 1' 10
SID_A="$(jq -r '.claims[0].session // empty' "$SEEN")"
uc_jq "(setup) the relay handed the open session to a phone it says belongs to @mallory" '.claims[0].result == "claimed" and .claims[0].login == "mallory"' "$SEEN"
uc_has "the developer is told the pairing was rejected" "$CONNECT1_OUT" 'pairing rejected'
uc_lacks "…and is never told a phone paired" "$CONNECT1_OUT" 'phone paired'
wait_seen ".revokes | index(\"$SID_A\") != null" 20
uc_jq "the session that phone was handed is revoked at the relay" ".revokes | index(\"$SID_A\") != null" "$SEEN"
uc_jq "nothing was revealed, derived or sealed to it: hmd sent that session no frame at all" "(.frames[\"$SID_A\"] // []) | length == 0" "$SEEN"

# the developer ends this connect; everything it started goes with it
hmd app disconnect --repo "$REPO"
uc_rc "hmd app disconnect ends the first connect" 0
if wait_gone "$CONNECT1_PID" 20 && wait_gone "$CONNECT1_UI_PID" 20 && wait_gone "$CONNECT1_CLIENT_PID" 20; then uc_ok "…connect, its hmd ui and its relay client are gone"; else uc_bad "disconnect left a process of the first connect running (connect $CONNECT1_PID, ui ${CONNECT1_UI_PID:-none}, client ${CONNECT1_CLIENT_PID:-none})"; fi

# ── 3. the developer's own phone pairs ──────────────────────────────────────────────────────────────────────────────────────────────────────────────
start_connect 2
CONNECT2_OUT="$CONNECT_OUT"; CONNECT2_PID="$CONNECT_PID"
if wait_text "$CONNECT2_OUT" "^  SESSION CODE: $CODE_RE\$" 60; then
  uc_ok "hmd app connect, run again, shows a code"
else
  uc_bad "hmd app connect, run again, never showed a session code" "$(head -c 600 "$CONNECT2_OUT" | LC_ALL=C tr '\n' ' ')"
  uc_finish
fi
note_pids; CONNECT2_UI_PID="$CONNECT_UI_PID"; CONNECT2_CLIENT_PID="$CONNECT_CLIENT_PID"
if [ "$(shown_code "$CONNECT2_OUT")" = "$CODE" ]; then uc_ok "…the same code as before: it is the repo's, not the run's"; else uc_bad "the second connect showed $(shown_code "$CONNECT2_OUT"), not $CODE"; fi
wait_seen '(.registrations | length) >= 2' 20
uc_jq "the relay holds that code again, on a session of its own" ".registrations | length == 2 and .[1].code == \"$CODE\" and .[1].session != .[0].session" "$SEEN"
phone_types 2 "$CODE" octocat "Pixel 9a"
wait_text "$CONNECT2_OUT" 'phone paired via code|pairing rejected' 30
wait_seen '(.claims | length) >= 2' 10
SID_B="$(jq -r '.claims[1].session // empty' "$SEEN")"
uc_jq "(setup) the relay handed the new session to the developer's phone, signed in as @octocat" '.claims[1].result == "claimed" and .claims[1].login == "octocat" and .claims[1].session != .claims[0].session' "$SEEN"
uc_has "connect says the phone paired by code, naming the device and the account the relay claimed" "$CONNECT2_OUT" "hmd app: phone paired via code -- relay-claimed device 'Pixel 9a', GitHub @octocat"
uc_has "…and that the code is closed now" "$CONNECT2_OUT" 'one phone is paired and the code is closed now'

# ── 4. what the phone can tell ──────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
wait_seen ".phone[\"$SID_B\"].opened == true" 30
uc_jq "the phone checked the key hmd revealed against the commitment it was given" ".phone[\"$SID_B\"].commitment_ok == true" "$SEEN"
uc_jq "the key reveal came before the first state" ".frames[\"$SID_B\"] as \$t | (\$t | index(\"key_reveal\")) != null and (\$t | index(\"state\")) != null and (\$t | index(\"key_reveal\")) < (\$t | index(\"state\"))" "$SEEN"
uc_jq "the phone opened the first state with the key it derived, and it names this repo's session code" ".phone[\"$SID_B\"].opened == true and .phone[\"$SID_B\"].session_code == \"$CODE\"" "$SEEN"
uc_jq "every state on the wire is a nonce and a sealed body, never a readable payload" '[.[] | select(.envelope.type == "state")] | length >= 1 and all(.[]; (.envelope.nonce | type) == "string" and (.envelope.ciphertext | type) == "string" and .envelope.payload == null)' "$WIRE"
uc_lacks "…the state's own words are nowhere in what the relay was sent" "$WIRE" 'session_code|"identity"'

# ── 5. the pairing shows on the laptop ──────────────────────────────────────────────────────────────────────────────────────────────────────────────
hmd app status --repo "$REPO"
uc_rc "hmd app status with a phone paired" 0
uc_has "…says a phone is bound" "$UC_OUT" '^  paired: yes \(1 phone\(s\) bound\)$'
uc_has "…lists one phone" "$UC_OUT" '^devices: 1 paired \(limit [0-9]+\)$'
uc_has "…by the name and GitHub account the relay claimed" "$UC_OUT" '^  device: Pixel 9a  id [^ ]+  @octocat  paired '
INBOX="$REPO/.heimdall/ui/inbox.jsonl"
wait_text "$INBOX" 'paired' 15
uc_jq "the pairing queued a notice for the Claude session naming the code, the device and the account" ".text | contains(\"paired\") and contains(\"$CODE\") and contains(\"Pixel 9a\") and contains(\"@octocat\") and contains(\"hmd app disconnect\")" "$INBOX"
printf '{"hook_event_name":"UserPromptSubmit","cwd":"%s"}' "$REPO" > "$UC_ROOT/prompt-hook.json"
# shellcheck disable=SC2016  # the launcher's own shell expands these, not this one
uc_run "$UC_HOME" "$REPO" "${HMD_ENV[@]}" -- sh -c '"$1" inbox prompt --repo "$2" < "$3"' sh "$UC_TREE/bin/hmd" "$REPO" "$UC_ROOT/prompt-hook.json"
uc_rc "the next prompt of the session is handed what is queued" 0
uc_jq "…and the session is told a phone paired, by name" '.hookSpecificOutput.additionalContext | contains("Pixel 9a") and contains("paired")' "$UC_OUT"

# ── 6. the token ────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
ps -axww -o command= > "$UC_ROOT/ps.out" 2>/dev/null
if [ -s "$UC_ROOT/ps.out" ] && ! grep -qF -- "$TOKEN" "$UC_ROOT/ps.out"; then uc_ok "the GitHub token is on no running process's command line"; else uc_bad "the GitHub token is on a command line (or ps listed nothing)"; fi
LEAKS="$(grep -rlF -- "$TOKEN" "$UC_HOME" "$HH" "$CANON" "$REPO" "$UC_TMP" "$CONNECT1_OUT" "$CONNECT2_OUT" 2>/dev/null | head -3 | LC_ALL=C tr '\n' ' ')"
if [ -z "$LEAKS" ]; then uc_ok "…in no file under HOME, hmd's home, the repo or the temp dir, and on no screen"; else uc_bad "the GitHub token was written to a file or a screen" "$LEAKS"; fi
if [ "$(cat "$UC_ROOT/gh.log")" = "$(printf 'gh auth token\ngh auth token')" ]; then uc_ok "gh was asked for its token twice and for nothing else: once for each code the developer asked for"; else uc_bad "gh was called otherwise than once per code" "$(LC_ALL=C tr '\n' '|' < "$UC_ROOT/gh.log")"; fi
uc_jq "…and the relay got it twice, once with each registration, never on a timer" '(.registrations | length) == 2 and all(.registrations[]; .token_ok == true)' "$SEEN"

# ── 7. unpair ───────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
hmd app disconnect --repo "$REPO"
uc_rc "hmd app disconnect unpairs" 0
uc_has "…and says it stopped" "$UC_OUT" 'hmd app disconnect: stopped'
wait_seen ".revokes | index(\"$SID_B\") != null" 20
uc_jq "the relay was told to end the phone's session" ".revokes | index(\"$SID_B\") != null" "$SEEN"
if wait_gone "$CONNECT2_PID" 20 && wait_gone "$CONNECT2_UI_PID" 20 && wait_gone "$CONNECT2_CLIENT_PID" 20; then uc_ok "connect, its hmd ui and its relay client are gone"; else uc_bad "disconnect left a process of the second connect running (connect $CONNECT2_PID, ui ${CONNECT2_UI_PID:-none}, client ${CONNECT2_CLIENT_PID:-none})"; fi
hmd app status --repo "$REPO"
uc_has "hmd app status says nothing is connected" "$UC_OUT" '^connected: no$'
uc_lacks "…and lists no phone" "$UC_OUT" '^devices:'

# ── 8. the relay and the phone ran clean; no model, no keychain, nothing left in the temp dir ──────────────────────────────────────────────────────────
uc_jq "the relay and the phone ran to the end without an error of their own" '.errors == []' "$SEEN"
if [ -z "$(find "$UC_TMP" -maxdepth 1 -name 'tmp.*' 2>/dev/null)" ]; then uc_ok "connect and disconnect left no temp file behind"; else uc_bad "a temp file of connect survives it" "$(find "$UC_TMP" -maxdepth 1 -name 'tmp.*' | head -3 | LC_ALL=C tr '\n' ' ')"; fi
if kill -0 "$DRIVER_PID" 2>/dev/null; then uc_ok "…and are still up"; else uc_bad "the relay and the phone process died" "$(head -c 400 "$UC_ROOT/phone.log" | LC_ALL=C tr '\n' ' ')"; fi
if [ ! -s "$UC_CLAUDE_LOG" ]; then uc_ok "no model session was started"; else uc_bad "pairing started a claude session" "$(head -c 200 "$UC_CLAUDE_LOG")"; fi
if [ ! -s "$UC_SECURITY_LOG" ]; then uc_ok "the keychain was never asked"; else uc_bad "pairing asked the keychain" "$(head -c 200 "$UC_SECURITY_LOG")"; fi

uc_finish
