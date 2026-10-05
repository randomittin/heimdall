#!/usr/bin/env bash
# test/companion-push.test.sh -- the SENDING half of phone push notifications.
#
# Spec of record: docs/HANDOFF-TO-HEIMDALL-push-notifications.md and docs/superpowers/specs/
# 2026-10-03-push-notifications.md (hmdapp repo, read-only inputs). bin/lib/companion_push.py turns
# transitions of the already-collected /api/state into Expo push messages: five triggers (question,
# approval, error, gate red, finished), deduped per attention id / event, coalesced and rate limited,
# suppressed while the app is in the foreground, carrying only allowlisted, scrubbed text.
#
# Written from the spec's tables, never from the implementation's source:
#   A  scrub (spec 8.2) and the Expo message shape / caps / allowlist (spec 5.5, 8.1)
#   B  the planner: each trigger fires once per transition, a baseline tick is silent, nothing else leaks
#   C  the monitor against a loopback fake Expo: policy (foreground, coalescing, gap, hourly cap, kind
#      filter), retries and back-pressure, DeviceNotRegistered pruning (ticket and receipt), batching,
#      log hygiene (never a token, title, body or ref), the kill switch, the endpoint override rule,
#      a network failure that never blocks the caller
#   D  the real hmd-ui StateCache hook: a transcript question and a phone-deny request push once, and a
#      hung Expo costs the poller nothing
#   E  two processes on one repo: exactly one sender, and a failover when the owner exits
#   F  the sender against the PRODUCTION store (bin/lib/companion_push_store.py): registrations made through
#      it, the kinds and timestamps it writes, DeviceNotRegistered pruning through its remove_tokens
#   ERR an API-error turn end, end to end (PN3): the REAL companion_ui_attention collector over a transcript
#      written in the shapes Claude Code writes -> a monitor over the production store -> a fake Expo:
#      exactly one `error` push per error, none for a recovery, a user interrupt or an unflagged stop
#
# Hermetic: HOME / HEIMDALL_HOME / TMPDIR are a temp dir, every sender talks to a loopback fake through
# HMD_PUSH_EXPO_URL, and HTTPS_PROXY points at a closed port so a push that tried to leave this machine
# would die at the proxy. Token- and secret-shaped inputs are assembled at runtime. Bounded waits only.
set -u

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PASS=0
FAIL=0
N=0
ok()  { N=$((N + 1)); PASS=$((PASS + 1)); printf '  ok   %d. %s\n' "$N" "$1"; }
bad() { N=$((N + 1)); FAIL=$((FAIL + 1)); printf '  FAIL %d. %s\n' "$N" "$1"; }

echo "companion-push (Expo push sender: triggers, policy, scrub, allowlist, one sender per repo)"

for f in "$REPO/bin/lib/companion_push.py" "$REPO/bin/lib/companion_push_store.py" \
         "$REPO/test/lib/push_test_lib.py" "$REPO/sentinels/hmd-ui.py"; do
  if [ ! -e "$f" ]; then
    printf 'FATAL: required file missing: %s\n' "$f" >&2
    printf '\n0 passed, 1 failed\n'
    exit 1
  fi
done
if ! command -v python3 >/dev/null 2>&1 || ! command -v git >/dev/null 2>&1; then
  printf 'FATAL: python3 and git are required\n' >&2
  printf '\n0 passed, 1 failed\n'
  exit 1
fi

TMPROOT="$(mktemp -d)"
cleanup() { rm -rf "$TMPROOT"; }
trap cleanup EXIT

export HOME="$TMPROOT/home"
export HEIMDALL_HOME="$HOME/.heimdall"
export TMPDIR="$TMPROOT"
mkdir -p "$HOME"
unset HMD_PUSH HMD_PUSH_EXPO_URL HMD_PUSH_COALESCE_S HMD_PUSH_MIN_RUN_S
unset CLAUDE_CODE_SESSION_ID CLAUDE_SESSION_ID SESSION_ID CLAUDE_CONFIG_DIR HMD_AGENT_PROJECTS_DIR
# a push that tried to leave this machine dies at a closed proxy port; loopback bypasses it
export HTTPS_PROXY="http://127.0.0.1:9" HTTP_PROXY="http://127.0.0.1:9"
export https_proxy="$HTTPS_PROXY" http_proxy="$HTTP_PROXY"
export NO_PROXY="127.0.0.1,localhost" no_proxy="127.0.0.1,localhost"

# Run one python part; each line it prints is `ok <text>` or `bad <text>` (forwarded to the tally),
# anything else is shown indented. A part that dies before finishing is itself a failure.
run_part() {
  local label="$1" script="$2"; shift 2
  local out="$TMPROOT/$label.out" line saw_done=0
  python3 "$script" "$REPO" "$TMPROOT/$label" "$@" >"$out" 2>"$TMPROOT/$label.err"
  local rc=$?
  while IFS= read -r line; do
    case "$line" in
      "ok "*)   ok "${line#ok }" ;;
      "bad "*)  bad "${line#bad }" ;;
      "done")   saw_done=1 ;;
      *)        printf '       | %s\n' "$line" ;;
    esac
  done <"$out"
  if [ "$rc" -ne 0 ] || [ "$saw_done" -ne 1 ]; then
    bad "$label: part did not finish (rc=$rc): $(tail -n 6 "$TMPROOT/$label.err" | tr '\n' '|')"
  fi
}

# ── A. scrub, message shape, caps, allowlist ─────────────────────────────────────────────
cat >"$TMPROOT/part_a.py" <<'PYEOF'
import json
import os
import sys

code, tmp = sys.argv[1], sys.argv[2]
sys.path.insert(0, os.path.join(code, "test", "lib"))
import push_test_lib as T

CP = T.load("companion_push", os.path.join(code, "bin", "lib", "companion_push.py"))
SHORT = "q" * 10 + "42"
TOK = T.expo_token("t")
REF = T.session_ref()
A, P = T.a_id, T.p_id

# ── constants and the kill switch (spec 5.1, handoff PN1) ──
T.eq(CP.PUSH_CAP, "push-v1", "A0a. the capability token is push-v1")
T.eq(CP.KINDS, ("question", "approval", "error", "gate_red", "finished", "test"), "A0b. the kind set is closed")
T.eq(CP.EXPO_SEND_URL, "https://exp.host/--/api/v2/push/send", "A0c. default send endpoint")
T.eq(CP.EXPO_RECEIPTS_URL, "https://exp.host/--/api/v2/push/getReceipts", "A0d. default receipts endpoint")
T.check(CP.enabled({}) and CP.enabled({"HMD_PUSH": "1"}) and not CP.enabled({"HMD_PUSH": "0"}),
        "A0e. HMD_PUSH=0 (exactly) is the kill switch; unset or any other value leaves push on")

# ── scrub: spec 8.2 steps 2-7. Expected values are worked out BY HAND from the spec's rule list. ──
VECTORS = [
    ("path-basename", "Edit src/feature/longModuleName.ts now?", "Edit longModuleName.ts now?"),
    ("bearer-long", "use Bearer " + "A" * 40, "use Bearer [redacted]"),
    ("code-span", "Run `rm -rf build` first?", "Run [code] first?"),
    ("fenced-block", "Plan:\n```\nrm -rf /\n```\nProceed?", "Plan: [code] Proceed?"),
    ("email", "Mail bob@example.com about it", "Mail [email] about it"),
    ("url", "see https://example.com/a/b?x=1 now", "see [url] now"),
    ("bare-query", "Invalid URL: laptop.local/?token=%s&label=x" % SHORT, "Invalid URL: ?[query]"),
    ("bearer-short", "got 401 for bearer " + SHORT, "got 401 for bearer [redacted]"),
    ("kv-equals", "token=" + SHORT, "token=[redacted]"),
    ("kv-colon", "api_key: " + SHORT, "api_key: [redacted]"),
    ("kv-json", '{"device_token":"%s"}' % SHORT, '{"device_token":"[redacted]"}'),
    ("kv-quoted", "client_secret='%s'" % SHORT, "client_secret='[redacted]'"),
    ("pin", "pin=" + "4" * 4, "pin=[redacted]"),
    ("otp-json", '{"otp":%s}' % ("3" * 5), '{"otp":[redacted]}'),
    ("digits-6", "pairing failed for " + "7" * 6, "pairing failed for [redacted]"),
    ("digits-3-3", "enter %s %s on the laptop" % ("4" * 3, "9" * 3), "enter [redacted] on the laptop"),
    ("digits-in-parens", "expired (%s)" % ("5" * 9), "expired ([redacted])"),
    ("long-run", "unexpected " + "A" * 40, "unexpected [redacted]"),
    ("base64-alphabet", "x " + "b" * 30 + "+" + "c" * 12, "x [redacted]"),
    ("path-absolute", "open /Users/rj/proj/src/app.py please", "open app.py please"),
    ("path-windows", "edit C:\\Users\\rj\\file.txt now", "edit file.txt now"),
    ("path-only-separators", "go ///", "go [path]"),
    ("path-lone-slash", "yes / no", "yes [path] no"),
    ("path-trailing-dot", "see src/a/b.ts.", "see b.ts."),
    ("sha-short", "fixed in 3fa9c0d now", "fixed in [sha] now"),
    ("hex-letters-only-kept", "add deadbeef now", "add deadbeef now"),
    ("sha-40-is-a-long-run", "HEAD 3fa9c0d1e2b3a4f5061728394a5b6c7d8e9f0a1b", "HEAD [redacted]"),
    ("digits-7-not-sha", "build 1234567 failed", "build [redacted] failed"),
    ("whitespace-collapsed", "a\tb\n\nc   d", "a b c d"),
    ("control-chars", "a\x00b\x1fc", "a b c"),
]
for scheme in ("http", "https", "ws", "wss", "hmdapp"):
    VECTORS.append(("url-" + scheme,
                    "fetch failed for %s://127.0.0.1:5173/api/state?token=%s (offline)" % (scheme, SHORT),
                    "fetch failed for [url] (offline)"))
for kept in ("socket closed with code 1006", "HTTP status code=401", "at index.android.bundle:1:234567",
             "handlePress index.bundle:120:7", "request failed with status 503 after 3 retries",
             "sessions: 2, tokens=12, dropped 99999 frames", "token expired", "basic validation failed",
             "digest mismatch on frame 4", "TypeError: Cannot read property 'status' of undefined",
             "Should I delete the old branch?", "Which approach do you prefer, A or B?"):
    VECTORS.append(("kept: " + kept, kept, kept))
for vid, text, want in VECTORS:
    T.eq(CP.scrub(text), want, "A1. scrub %s" % vid)

# cut: at the limit, at a UTF-16 boundary, with an ellipsis that counts toward the limit
T.eq(CP.scrub("abcd " * 40), ("abcd " * 23) + "abcd\u2026", "A2a. a long line is cut to 120 UTF-16 units, ellipsis included")
T.eq(CP.scrub("abcd efgh ijkl", 10), "abcd efgh\u2026", "A2b. the limit is a parameter")
T.eq(CP.scrub("\U0001F600" * 100), "\U0001F600" * 59 + "\u2026", "A2c. an astral character counts as 2 units and is never split")
T.eq(CP.utf16_len("a\U0001F600b"), 4, "A2d. utf16_len counts surrogate pairs as 2")

# ── messages: the doc's own example, byte for byte (spec 5.5) ──
approval_ev = {"kind": "approval", "key": "p:" + P(0x1a2b3c4d), "ep": "a-3c1f09e2b7",
               "fields": {"tool": "Bash", "pid": "p-1a2b3c4d", "expires_at": 1791002301}}
doc_example = {
    "to": TOK, "title": "api server \u00b7 approval needed", "body": "Bash is waiting. Deny within 41 s.",
    "data": {"v": 1, "ref": REF, "kind": "approval", "ep": "a-3c1f09e2b7", "pid": "p-1a2b3c4d", "exp": 1791002301},
    "categoryId": "hmd_approval", "channelId": "hmd-attention", "priority": "high",
    "interruptionLevel": "time-sensitive", "sound": "default", "ttl": 41,
    "collapseId": REF + ".approval", "tag": REF + ".approval", "threadId": REF}
T.eq(CP.build_message(TOK, approval_ev, "api server", REF, 1791002260), doc_example,
     "A3a. an approval message equals the spec's 5.5 example exactly")
T.eq(CP.build_message(TOK, dict(approval_ev, fields=dict(approval_ev["fields"], expires_at=1791002262)),
                      "api server", REF, 1791002260), None,
     "A3b. an approval with under 5 s left is not built (expired)")
odd = CP.build_message(TOK, dict(approval_ev, fields=dict(approval_ev["fields"], tool="mcp__x__y")),
                       "api server", REF, 1791002260)
T.eq(odd["body"], "A tool is waiting. Deny within 41 s.", "A3c. a tool outside the closed set reads 'A tool'")
for tool in ("Bash", "Write", "Edit", "MultiEdit", "NotebookEdit"):
    m = CP.build_message(TOK, dict(approval_ev, fields=dict(approval_ev["fields"], tool=tool)),
                         "api server", REF, 1791002260)
    T.check(m["body"].startswith(tool + " is waiting."), "A3d. approval tool %s is named" % tool, m["body"])

OPTS = ["Yes", "No"]


def question(summary, options=OPTS, ep=A(7)):
    return {"kind": "question", "key": "q:" + A(7), "ep": ep, "fields": {"summary": summary, "options": options}}


q = CP.build_message(TOK, question("Should I delete the old branch?"), "api server", REF, 1000)
T.eq(q, {"to": TOK, "title": "api server \u00b7 hmd asks", "body": "Should I delete the old branch? [Yes / No]",
         "data": {"v": 1, "ref": REF, "kind": "question", "ep": A(7)},
         "channelId": "hmd-attention", "priority": "high", "interruptionLevel": "time-sensitive",
         "sound": "default", "ttl": 3600, "collapseId": REF + ".question", "tag": REF + ".question",
         "threadId": REF}, "A4a. a question message: allowlisted body, option labels, per-kind constants")
q5 = CP.build_message(TOK, question("Pick one?", ["Alpha", "Beta", "Gamma", "Delta", "Epsilon"]),
                      "api server", REF, 1000)
T.eq(q5["body"], "Pick one? [Alpha / Beta / Gamma]", "A4b. only the first 3 option labels are used")
qlong = CP.build_message(TOK, question("Pick?", ["alpha beta gamma delta epsilon"]), "api server", REF, 1000)
T.eq(qlong["body"], "Pick? [alpha beta gamm\u2026]", "A4c. an option label is cut to 16 units, ellipsis included")
T.eq(CP.build_message(TOK, question(None), "api server", REF, 1000)["body"],
     "hmd has a question. Open to answer.", "A4d. no summary -> the constant body")
secret_forms = [("ghp", T.ghp_shaped()), ("kv", "password=" + "x" * 20), ("bearer-kv", "token: " + "z" * 24)]
for tag, secret in secret_forms:
    m = CP.build_message(TOK, question("Use " + secret + " for it?", ["Yes", "No"]), "api server", REF, 1000)
    T.eq(m["body"], "hmd has a question. Open to answer.", "A4e. a secret-shaped question (%s) -> the constant body, no options" % tag)
    T.check(secret not in json.dumps(m) and "x" * 20 not in json.dumps(m) and "z" * 24 not in json.dumps(m),
            "A4f. the secret (%s) is nowhere in the message" % tag)

err = CP.build_message(TOK, {"kind": "error", "key": "e:" + A(5), "ep": A(5), "fields": {}}, "api server", REF, 1000)
T.eq((err["title"], err["body"], err["channelId"], err["interruptionLevel"], err["ttl"], "categoryId" in err),
     ("api server \u00b7 agent error", "The session stopped on an error. Open to see it.", "hmd-attention",
      "active", 3600, False), "A5a. error message constants")


def gate(failing, total):
    return {"kind": "gate_red", "key": "g:1", "ep": None, "fields": {"failing": failing, "total": total}}


g = CP.build_message(TOK, gate(2, 5), "api server", REF, 1000)
T.eq((g["title"], g["body"], g["channelId"], g["interruptionLevel"], g["ttl"], g["data"]["ep"]),
     ("api server \u00b7 push gate red", "2 of 5 gates failing.", "hmd-updates", "active", 3600, None),
     "A5b. gate_red with ledger counts (ep null is sent as null)")
T.eq(CP.build_message(TOK, gate(None, None), "api server", REF, 1000)["body"], "The push gate turned red.",
     "A5c. gate_red without ledger counts")


def finished(**fields):
    return {"kind": "finished", "key": "f:" + A(2), "ep": A(2), "fields": fields}


d = CP.build_message(TOK, finished(variant="done", gate=True, suites_passed=427, suites_total=427, duration_s=2239),
                     "api server", REF, 1000)
T.eq((d["title"], d["body"], d["channelId"], d["interruptionLevel"]),
     ("api server \u00b7 done, verified", "Gates clear. Suites 427/427 passed. Ran 37m19s.", "hmd-updates", "active"),
     "A6a. finished/done: each clause from its own field")
T.eq(CP.build_message(TOK, finished(variant="done", gate=True, suites_passed=None, suites_total=None, duration_s=45),
                      "api server", REF, 1000)["body"], "Gates clear. Ran 45s.",
     "A6b. a clause whose fields are missing is left out")
T.eq(CP.build_message(TOK, finished(variant="done", gate=None, suites_passed=None, suites_total=None, duration_s=None),
                      "api server", REF, 1000)["body"], "Turn ended.", "A6c. finished/done with no fields -> a constant")
for gate_value, word in ((True, "clear"), (False, "red"), (None, "unknown")):
    s = CP.build_message(TOK, finished(variant="stopped", gate=gate_value), "api server", REF, 1000)
    T.eq((s["title"], s["body"]), ("api server \u00b7 finished, not verified", "Turn ended. Push gate %s." % word),
         "A6d. finished/stopped, gate=%s -> %s" % (gate_value, word))
v = CP.build_message(TOK, finished(variant="verdict", suites_passed=400, suites_total=427), "api server", REF, 1000)
T.eq((v["title"], v["body"]), ("api server \u00b7 sweep finished", "Suites 400/427 passed."), "A6e. finished/verdict")
t = CP.build_message(TOK, {"kind": "test", "key": "t:1", "ep": None, "fields": {}}, "api server", REF, 1000)
T.eq((t["title"], t["body"], t["ttl"], t["channelId"]),
     ("api server \u00b7 test notification", "Notifications from this laptop work.", 600, "hmd-updates"),
     "A6f. the closed per-kind table also covers the test kind")

# ── caps ──
big = ("abcd " * 80).strip()
m = CP.build_message(TOK, question(big), "api server", REF, 1000)
T.eq(m["body"], ("abcd " * 23) + "abcd\u2026", "A7a. a 399-char question summary becomes a 120-unit body; options do not fit, so none")
m = CP.build_message(TOK, question("\U0001F600" * 100, ["Yes"]), "api server", REF, 1000)
T.check(CP.utf16_len(m["body"]) <= 120 and m["body"] == "\U0001F600" * 59 + "\u2026",
        "A7b. an emoji-only question is cut on a pair boundary within 120 units", m["body"])
m = CP.build_message(TOK, finished(variant="stopped", gate=True), "x" * 24, REF, 1000)
T.check(CP.utf16_len(m["title"]) == 48 and m["title"].endswith("\u2026") and m["title"].startswith("x" * 24 + " \u00b7 "),
        "A7c. a 24-char label with the longest phrase is cut to exactly 48 units", m["title"])
worst = CP.build_message(T.expo_token("t", 64), question(("abcd " * 80).strip(), [("opt " * 10).strip()] * 3),
                         "x" * 24, "f" * 16, 1000)
T.check(len(json.dumps(worst, ensure_ascii=False).encode("utf-8")) < 3500,
        "A7d. the largest message the caps allow serialises well under the 3500 B margin (Expo caps 4096)")

# ── label and ref: validated, defaulted ──
for bad_label in ("a/b", "a\\b", "", "   ", "x" * 25, "tab\there", "\U0001F600" * 13):
    m = CP.build_message(TOK, finished(variant="stopped", gate=True), bad_label, REF, 1000)
    T.check(m["title"].startswith("hmd \u00b7 "), "A8a. invalid label %r falls back to 'hmd'" % bad_label, m["title"])
m = CP.build_message(TOK, finished(variant="stopped", gate=True), "  api server  ", REF, 1000)
T.check(m["title"].startswith("api server \u00b7 "), "A8b. a label is trimmed", m["title"])
m = CP.build_message(TOK, finished(variant="stopped", gate=True), "api server", "not-a-ref", 1000)
T.check(len(m["data"]["ref"]) == 16 and all(c in "0123456789abcdef" for c in m["data"]["ref"])
        and m["data"]["ref"] != "not-a-ref" and TOK not in json.dumps(m["data"]),
        "A8c. an invalid ref is replaced by a 16-hex derivation that is not the token", m["data"])

# ── closed shapes: exact key sets, nothing else may ride along ──
COMMON = {"to", "title", "body", "data", "channelId", "priority", "interruptionLevel", "sound", "ttl",
          "collapseId", "tag", "threadId"}
for name, ev, want_keys, want_data in (
        ("question", question("Q?"), COMMON, {"v", "ref", "kind", "ep"}),
        ("approval", approval_ev, COMMON | {"categoryId"}, {"v", "ref", "kind", "ep", "pid", "exp"}),
        ("error", {"kind": "error", "key": "e:x", "ep": A(5), "fields": {}}, COMMON, {"v", "ref", "kind", "ep"}),
        ("gate_red", gate(1, 2), COMMON, {"v", "ref", "kind", "ep"}),
        ("finished", finished(variant="stopped", gate=True), COMMON, {"v", "ref", "kind", "ep"})):
    m = CP.build_message(TOK, ev, "api server", REF, 1791002260)
    T.eq((set(m), set(m["data"]), m["priority"], m["sound"], "badge" in m),
         (want_keys, want_data, "high", "default", False), "A9. %s: exact key set, high priority, no badge" % name)
print("done")
PYEOF
run_part A "$TMPROOT/part_a.py"

# ── B. the planner: transitions -> events ────────────────────────────────────────────────
cat >"$TMPROOT/part_b.py" <<'PYEOF'
import copy
import json
import os
import sys

code, tmp = sys.argv[1], sys.argv[2]
sys.path.insert(0, os.path.join(code, "test", "lib"))
import push_test_lib as T

CP = T.load("companion_push", os.path.join(code, "bin", "lib", "companion_push.py"))
A, P, S, att = T.a_id, T.p_id, T.state, T.attention
REF = T.session_ref()
YESNO = [{"key": "yes", "label": "Yes"}, {"key": "no", "label": "No"}]

# ── baseline ──
p = CP.Planner()
T.eq(p.observe(S(att("needs_input", A(1), "question", "Q one?")), 1000.0), [],
     "B1a. the first tick is a baseline: silent even in the middle of a question")
T.eq(p.observe(S(att("needs_input", A(1), "question", "Q one?")), 1002.0), [], "B1b. the same episode stays silent")
p = CP.Planner()
T.eq(p.observe(S(approvals=[T.approval(P(1), "Bash", 1100.0)]), 1000.0), [], "B1c. a pending approval at the baseline is silent")
p = CP.Planner()
for junk in (None, [], "x", 7):
    p.observe(junk, 1000.0)
T.eq(p.observe(S(att("needs_input", A(1), "question", "Q?")), 1001.0), [],
     "B1d. non-dict states do not count as the baseline: the first real tick still is one")

# ── question ──
p = CP.Planner()
p.observe(S(att("working", A(1))), 1000.0)
out = p.observe(S(att("needs_input", A(2), "question", "Delete the old branch?", YESNO)), 1002.0)
T.eq(out, [{"kind": "question", "key": "q:" + A(2), "ep": A(2),
            "fields": {"summary": "Delete the old branch?", "options": ["Yes", "No"]}}],
     "B2a. working -> needs_input fires one question event with the allowlisted fields")
T.eq(p.observe(S(att("needs_input", A(2), "question", "Delete the old branch?", YESNO)), 1004.0), [],
     "B2b. the same attention id does not fire again")
out = p.observe(S(att("needs_input", A(3), "question", "Another?", [{"key": "k", "label": "L"}] * 5)), 1010.0)
T.eq([(e["kind"], e["key"], e["fields"]["options"]) for e in out], [("question", "q:" + A(3), ["L", "L", "L"])],
     "B2c. a new episode fires again; only the first 3 option labels are kept")
T.eq(p.observe(S(att("needs_input", A(2), "question", "Delete the old branch?", YESNO)), 1012.0), [],
     "B2d. a replayed old episode is deduped by its key")
T.eq(p.observe(S(att("needs_input", None, "question", "no id")), 1020.0), [], "B2e. a needs_input without an id never fires")

# ── approval ──
p = CP.Planner()
p.observe(S(att("working", A(1))), 1000.0)
ap1, ap2 = T.approval(P(1), "Bash", 1100.0), T.approval(P(2), "Write", 1105.0)
ask = att("needs_approval", A(9), "permission", "permission requested: Bash")
out = p.observe(S(ask, approvals=[ap1]), 1002.0)
T.eq(out, [{"kind": "approval", "key": "p:" + P(1), "ep": A(9),
            "fields": {"tool": "Bash", "pid": P(1), "expires_at": 1100.0}}],
     "B3a. a new approvals[] id fires one approval event (tool, id, expiry only)")
T.eq(p.observe(S(ask, approvals=[ap1]), 1004.0), [], "B3b. the same pending approval is silent")
out = p.observe(S(ask, approvals=[ap1, ap2]), 1006.0)
T.eq([(e["kind"], e["key"], e["fields"]["tool"]) for e in out], [("approval", "p:" + P(2), "Write")],
     "B3c. a second approval fires on its own")
T.eq(p.observe(S(att("working", A(1)), approvals=[]), 1008.0), [], "B3d. an answered approval fires nothing")
T.eq(p.observe(S(ask, approvals=[ap1]), 1010.0), [], "B3e. an id that comes back is deduped")

# ── error ──
p = CP.Planner()
p.observe(S(att("working", A(1))), 1000.0)
out = p.observe(S(att("idle", A(5), "error")), 1005.0)
T.eq(out, [{"kind": "error", "key": "e:" + A(5), "ep": A(5), "fields": {}}],
     "B4a. an attention.kind=error fires one error event (and no finished: kind is not done/stopped)")
T.eq(p.observe(S(att("idle", A(5), "error")), 1007.0), [], "B4b. the same error episode is silent")
T.eq([e["key"] for e in p.observe(S(att("idle", A(6), "error")), 1050.0)], ["e:" + A(6)], "B4c. a new error episode fires")

# ── gate red ──
p = CP.Planner()
p.observe(S(gate=True, gates=T.gate_rows(0, 4)), 1000.0)
out = p.observe(S(gate=False, gates=T.gate_rows(2, 4)), 1005.7)
T.eq(out, [{"kind": "gate_red", "key": "g:1005", "ep": None, "fields": {"failing": 2, "total": 4}}],
     "B5a. clear_to_push true -> false fires gate_red with failing/total from ledger.gates")
T.eq(p.observe(S(gate=False, gates=T.gate_rows(2, 4)), 1007.0), [], "B5b. staying red is silent")
T.eq(p.observe(S(gate=True), 1010.0), [], "B5c. red -> green is silent (green is reported inside finished)")
T.eq([(e["key"], e["fields"]) for e in p.observe(S(gate=False, gates=[]), 1020.2)],
     [("g:1020", {"failing": None, "total": None})], "B5d. a second red transition fires; no gates -> no counts")
p = CP.Planner()
p.observe(S(gate=None), 1000.0)
T.eq(p.observe(S(gate=False), 1001.0), [], "B5e. unknown -> red is silent (no prior green to lose)")
p = CP.Planner()
p.observe(S(gate=True), 1000.0)
T.eq([p.observe(S(gate=None), 1001.0), p.observe(S(gate=False), 1002.0)], [[], []],
     "B5f. green -> unknown -> red is silent: the gate was not observed to turn red")

# ── finished ──
RC = T.receipt(finished_at="r1", passed=427, total=427, duration_s=2239)
p = CP.Planner()
p.observe(S(att("working", A(1)), gate=True, receipt=RC), 1000.0)
p.observe(S(att("working", A(1)), gate=True, receipt=RC), 1030.0)
out = p.observe(S(att("idle", A(2), "done"), gate=True, receipt=RC), 1090.0)
T.eq(out, [{"kind": "finished", "key": "f:" + A(2), "ep": A(2),
            "fields": {"variant": "done", "gate": True, "suites_passed": 427, "suites_total": 427, "duration_s": 2239}}],
     "B6a. a 90 s run that ends idle/done fires finished(done) with the receipt counts")
T.eq(p.observe(S(att("idle", A(2), "done"), gate=True, receipt=RC), 1092.0), [], "B6b. the same idle episode is silent")
p = CP.Planner()
p.observe(S(att("idle", A(1), "done")), 1000.0)
p.observe(S(att("working", A(2))), 1010.0)
T.eq(p.observe(S(att("idle", A(3), "stopped")), 1050.0), [], "B6c. a 40 s run is shorter than HMD_PUSH_MIN_RUN_S (60): silent")
p = CP.Planner({"min_run_s": 0})
p.observe(S(att("idle", A(1), "done")), 1000.0)
p.observe(S(att("working", A(2))), 1010.0)
out = p.observe(S(att("idle", A(3), "stopped"), gate=False), 1015.0)
T.eq(out, [{"kind": "finished", "key": "f:" + A(3), "ep": A(3), "fields": {"variant": "stopped", "gate": False}}],
     "B6d. with a minimum run of 0 a 5 s run fires finished(stopped), carrying only the gate")
p = CP.Planner()
p.observe(S(att("needs_input", A(1), "question", "Q?")), 1000.0)
T.eq([e["kind"] for e in p.observe(S(att("idle", A(2), "stopped")), 1100.0)], ["finished"],
     "B6e. needs_input -> idle counts (the run is measured from the first non-idle tick seen)")
p = CP.Planner()
p.observe(S(att("idle", A(1), "done")), 1000.0)
T.eq(p.observe(S(att("idle", A(2), "done")), 1100.0), [], "B6f. idle -> idle is not a run that finished")
p = CP.Planner({"min_run_s": 0})
p.observe(S(att("working", A(1))), 1000.0)
T.eq(p.observe(S(att("idle", A(2), None)), 1100.0), [], "B6g. an idle with no kind fires nothing")
p = CP.Planner()
p.observe(S(att("working", A(1))), 1000.0)
T.eq([e["kind"] for e in p.observe(S(att("ended", A(2))), 1100.0)], [], "B6h. ended never pushes")

# ── verdict (sweep receipt) ──
r1, r2 = T.receipt(finished_at="2026-10-03T10:00:00Z", passed=400, total=427), T.receipt(finished_at="2026-10-03T11:00:00Z")
p = CP.Planner()
idle = att("idle", A(1), "stopped")
p.observe(S(idle, receipt=r1), 2000.0)
T.eq(p.observe(S(idle, receipt=r1), 2002.0), [], "B7a. an unchanged receipt is silent")
out = p.observe(S(idle, receipt=r2), 2010.0)
T.eq(out, [{"kind": "finished", "key": "v:2026-10-03T11:00:00Z", "ep": A(1),
            "fields": {"variant": "verdict", "suites_passed": 427, "suites_total": 427}}],
     "B7b. a new sweep receipt fires finished(verdict) carrying only the counts")
p = CP.Planner({"min_run_s": 0})
p.observe(S(att("working", A(1)), receipt=T.receipt(finished_at="r1")), 2990.0)
out = p.observe(S(att("idle", A(2), "done"), gate=True, receipt=T.receipt(finished_at="r2")), 3000.0)
T.eq([e["fields"]["variant"] for e in out], ["done"], "B7c. finished and a new receipt in ONE tick: only finished(done)")
T.eq(p.observe(S(att("idle", A(2), "done"), gate=True, receipt=T.receipt(finished_at="r3")), 3050.0), [],
     "B7d. a receipt within 120 s of a finished is not announced separately")
T.eq([e["key"] for e in p.observe(S(att("idle", A(2), "done"), gate=True, receipt=T.receipt(finished_at="r4")), 3200.0)],
     ["v:r4"], "B7e. a receipt 200 s after the last finished is")
p = CP.Planner()
p.observe(S(idle), 100.0)
T.eq([e["key"] for e in p.observe(S(idle, receipt=r1), 110.0)], ["v:2026-10-03T10:00:00Z"],
     "B7f. the first receipt that ever appears fires")
T.eq(p.observe(S(idle, receipt=None), 120.0), [], "B7g. a receipt that disappears is silent")

# ── ordering, garbage, mutation ──
p = CP.Planner()
p.observe(S(att("working", A(1)), gate=True), 1000.0)
out = p.observe(S(att("needs_approval", A(2), "permission", "x"), approvals=[T.approval(P(1), "Bash", 1100.0)],
                  gate=False), 1005.0)
T.eq([e["kind"] for e in out], ["approval", "gate_red"], "B8a. several events in one tick come out in a fixed order")
p = CP.Planner()
p.observe(S(), 1000.0)
GARBAGE = [None, [], {}, {"attention": "x"}, {"attention": {"state": 5, "id": 7, "options": "z"}},
           {"approvals": "x"}, {"approvals": [{"id": 5}, None, {"id": "../etc", "tool": "Bash"}]},
           {"quality_gate": 7}, {"ledger": {"gates": "x"}}, {"ledger": {"gates": [None, 3, {"state": 9}]}},
           {"sweep_receipt": "x"}, {"sweep_receipt": {"finished_at": ["a"], "suites_passed": True}}]
raised = []
for junk in GARBAGE:
    try:
        p.observe(junk, 1001.0)
    except Exception as exc:
        raised.append((junk, exc.__class__.__name__))
T.eq(raised, [], "B9a. malformed slices never raise")
before = S(att("needs_input", A(1), "question", "Q?", YESNO), approvals=[T.approval(P(1), "Bash", 1100.0)], gate=False,
           gates=T.gate_rows(1, 2), receipt=RC)
snapshot = copy.deepcopy(before)
CP.Planner().observe(before, 1.0)
q = CP.Planner()
q.observe(S(), 1.0)
q.observe(before, 2.0)
T.eq(before, snapshot, "B9b. observe never mutates the state it is handed")

# ── allowlist: markers in every free-text field must reach no notification ──
def run(prev, cur, **cfg):
    pl = CP.Planner(dict({"min_run_s": 0}, **cfg))
    pl.observe(prev, 1000.0)
    return pl.observe(cur, 1100.0)


scenarios = {
    "question": (S(att("working", A(1))), S(att("needs_input", A(2), "question", "Delete the old branch?", YESNO))),
    "approval": (S(att("working", A(1))), S(att("needs_approval", A(2), "permission", "permission requested: Bash"),
                                            approvals=[T.approval(P(1), "Bash", 1160.0)])),
    "error": (S(att("working", A(1))), S(att("idle", A(2), "error"))),
    "gate_red": (S(gate=True, gates=T.gate_rows(0, 3)), S(gate=False, gates=T.gate_rows(1, 3))),
    "finished-done": (S(att("working", A(1)), gate=True, receipt=T.receipt(finished_at="a")),
                      S(att("idle", A(2), "done"), gate=True, receipt=T.receipt(finished_at="a"))),
    "finished-stopped": (S(att("working", A(1))), S(att("idle", A(2), "stopped"), gate=False)),
    "verdict": (S(att("idle", A(1), "stopped"), receipt=T.receipt(finished_at="a")),
                S(att("idle", A(1), "stopped"), receipt=T.receipt(finished_at="b"))),
}
for name, (prev, cur) in scenarios.items():
    events = run(prev, cur)
    T.check(len(events) == 1, "B10a. scenario %s plans exactly one event" % name, events)
    msg = CP.build_message(T.expo_token("t"), events[0], "api server", REF, 1100.0)
    wire = json.dumps(msg, ensure_ascii=False)
    leaked = [m for m in T.LEAK_VALUES if m in wire]
    T.check(msg is not None and not leaked, "B10b. scenario %s: no planted marker reaches the notification" % name, leaked)
    T.check(not any(m in json.dumps(events[0]) for m in T.LEAK_VALUES),
            "B10c. scenario %s: the event itself carries none of the planted markers" % name)
print("done")
PYEOF
run_part B "$TMPROOT/part_b.py"

# ── C. the monitor against a loopback fake Expo ──────────────────────────────────────────
cat >"$TMPROOT/part_c.py" <<'PYEOF'
import json
import os
import sys
import threading
import time

code, tmp = sys.argv[1], sys.argv[2]
os.makedirs(tmp, exist_ok=True)
sys.path.insert(0, os.path.join(code, "test", "lib"))
import push_test_lib as T

CP = T.load("companion_push", os.path.join(code, "bin", "lib", "companion_push.py"))
A, P, S, att = T.a_id, T.p_id, T.state, T.attention
TOK = T.expo_token("t")
YESNO = [{"key": "yes", "label": "Yes"}, {"key": "no", "label": "No"}]
_n = [0]


class Rig:
    """One monitor + file store + fake Expo + recorders. start_thread=False: the test drives step(now)."""

    def __init__(self, tokens=None, app_state="unknown", app_state_at=None, cfg=None, env=None, attached=None,
                 fake=None, start_thread=False, store=None, root=None):
        _n[0] += 1
        self.root = root or os.path.join(tmp, "repo%d" % _n[0])
        os.makedirs(self.root, exist_ok=True)
        self.store = store or T.FileStore(os.path.join(tmp, "store%d.json" % _n[0]))
        if store is None:
            self.store.seed([TOK] if tokens is None else tokens, app_state, app_state_at)
        self.fake = fake or T.FakeExpo()
        self.events, self.sleeps = [], []
        environ = {"HMD_PUSH_EXPO_URL": self.fake.url}
        environ.update(env or {})
        config = {"min_run_s": 0, "timeout_s": 3.0}
        config.update(cfg or {})
        self.m = CP.PushMonitor(self.root, store=self.store, emit=self.events.append, config=config,
                                sleep=self.sleeps.append, attached=attached, environ=environ,
                                start_thread=start_thread)

    def pushes(self):
        return [e for e in self.events if e.get("event") == "push"]

    def lock_path(self):
        return os.path.join(self.root, ".heimdall", "app", "push-sender.lock")

    def close(self):
        self.m.close()
        self.fake.close()


def question_pair(n=2):
    return (S(att("working", A(1))), S(att("needs_input", A(n), "question", "Delete the old branch?", YESNO)))


# ── C1. every trigger sends exactly once per transition ──
CASES = [
    ("question", question_pair(), "question", "hmd · hmd asks", "Delete the old branch? [Yes / No]", True),
    ("approval", (S(att("working", A(1))),
                  S(att("needs_approval", A(2), "permission", "permission requested: Bash"),
                    approvals=[T.approval(P(1), "Bash", 1062.0)])),
     "approval", "hmd · approval needed", "Bash is waiting. Deny within 60 s.", False),
    ("error", (S(att("working", A(1))), S(att("idle", A(2), "error"))), "error", "hmd · agent error",
     "The session stopped on an error. Open to see it.", True),
    ("gate_red", (S(gate=True, gates=T.gate_rows(0, 3)), S(gate=False, gates=T.gate_rows(1, 3))), "gate_red",
     "hmd · push gate red", "1 of 3 gates failing.", True),
    ("finished-stopped", (S(att("working", A(1))), S(att("idle", A(2), "stopped"), gate=False)), "finished",
     "hmd · finished, not verified", "Turn ended. Push gate red.", True),
    ("finished-done", (S(att("working", A(1)), gate=True, receipt=T.receipt(finished_at="a")),
                       S(att("idle", A(2), "done"), gate=True, receipt=T.receipt(finished_at="a"))), "finished",
     "hmd · done, verified", "Gates clear. Suites 427/427 passed. Ran 37m19s.", True),
    ("verdict", (S(att("idle", A(1), "stopped"), receipt=T.receipt(finished_at="a", passed=400, total=427)),
                 S(att("idle", A(1), "stopped"), receipt=T.receipt(finished_at="b"))), "finished",
     "hmd · sweep finished", "Suites 427/427 passed.", True),
]
for name, (prev, cur), kind, title, body, windowed in CASES:
    rig = Rig()
    rig.m.observe(prev, 1000.0)
    rig.m.observe(cur, 1002.0)
    rig.m.step(1002.0)
    if windowed:
        T.eq(len(rig.fake.sends()), 0, "C1a. %s: a non-approval event waits out the coalescing window" % name)
        rig.m.step(1007.0)
    msgs = rig.fake.messages()
    T.eq(len(msgs), 1, "C1b. %s: exactly one message is POSTed" % name)
    if msgs:
        T.eq((msgs[0]["to"], msgs[0]["title"], msgs[0]["body"], msgs[0]["data"]["kind"]), (TOK, title, body, kind),
             "C1c. %s: addressed to the registered token with the allowlisted title and body" % name)
    rig.m.observe(cur, 1008.0)
    rig.m.step(1030.0)
    T.eq(len(rig.fake.messages()), 1, "C1d. %s: the same state again sends nothing more" % name)
    sent = [e for e in rig.pushes() if e["ok"]]
    T.eq([(e["kind"], e["suppressed"], e["detail"]) for e in sent], [(kind, None, None)],
         "C1e. %s: one log line, ok, not suppressed" % name)
    rig.close()

# the request itself: JSON array body, headers, nothing but the documented message keys
rig = Rig()
rig.m.observe(question_pair()[0], 1000.0)
rig.m.observe(question_pair()[1], 1002.0)
rig.m.step(1007.0)
req = rig.fake.sends()[0]
T.check(isinstance(req["body"], list) and len(req["body"]) == 1, "C1f. the request body is a JSON array of one message")
hdr = {k.lower(): v for k, v in req["headers"].items()}
T.check(hdr.get("content-type") == "application/json" and hdr.get("accept") == "application/json",
        "C1g. accept and content-type are application/json", hdr)
T.eq(req["path"], "/--/api/v2/push/send", "C1h. posted to the send path of the (loopback override) endpoint")
rig.close()

# ── C2. foreground suppression and its staleness rule ──
FG = [("fresh foreground", "foreground", 1002.0 - 10, None, True),
      ("foreground exactly 900 s old", "foreground", 1002.0 - 900, None, True),
      ("foreground 901 s old counts as unknown", "foreground", 1002.0 - 901, None, False),
      ("foreground with no timestamp", "foreground", None, None, False),
      ("background", "background", 1002.0 - 5, None, False),
      ("unknown", "unknown", None, None, False),
      ("fresh foreground, phone not attached", "foreground", 1002.0 - 10, lambda: False, False),
      ("fresh foreground, phone attached", "foreground", 1002.0 - 10, lambda: True, True)]
for name, app_state, at, attached, suppressed in FG:
    rig = Rig(app_state=app_state, app_state_at=at, attached=attached)
    rig.m.observe(question_pair()[0], 1000.0)
    rig.m.observe(question_pair()[1], 1002.0)
    rig.m.step(1002.0)
    rig.m.step(1008.0)
    T.eq(len(rig.fake.messages()), 0 if suppressed else 1, "C2a. %s -> %s" % (name, "suppressed" if suppressed else "sent"))
    if suppressed:
        T.eq([(e["kind"], e["ok"], e["suppressed"]) for e in rig.pushes()], [("question", False, "foreground")],
             "C2b. %s: logged as suppressed foreground, never sent" % name)
    rig.close()


def broken_attached():
    raise RuntimeError("cannot tell")


rig = Rig(app_state="foreground", app_state_at=990.0, attached=broken_attached)
rig.m.observe(question_pair()[0], 1000.0)
rig.m.observe(question_pair()[1], 1002.0)
rig.m.step(1008.0)
T.eq(len(rig.fake.messages()), 1, "C2c. an attached() probe that raises counts as 'not attached': the push goes out")
rig.close()
rig = Rig(app_state="foreground", app_state_at=995.0)
rig.m.observe(S(att("working", A(1))), 1000.0)
rig.m.observe(S(att("needs_approval", A(2), "permission", "x"), approvals=[T.approval(P(1), "Bash", 1062.0)]), 1002.0)
rig.m.step(1002.0)
T.eq(len(rig.fake.messages()), 0, "C2d. foreground suppresses approvals too (the app shows them live)")
rig.close()
# a foreground report is believed only with the store's own timestamp form (ISO-8601 UTC, whole seconds, Z)
for bad in ("yesterday", "2026-13-45T25:61:61Z", "2026-10-03T06:19:00+00:00", "2026-10-03T06:19:00Z\n", 990.0, True):
    rig = Rig(app_state="foreground", app_state_at=990.0)
    data = rig.store._read()
    data["app_state_at"] = bad
    rig.store._write(data)
    rig.m.observe(question_pair()[0], 1000.0)
    rig.m.observe(question_pair()[1], 1002.0)
    rig.m.step(1008.0)
    T.eq(len(rig.fake.messages()), 1, "C2e. a foreground report stamped %r is no timestamp the store writes: it reads as unknown, the push goes out" % (bad,))
    rig.close()

# ── C3. coalescing, the per-device gap, the hourly cap, kind filter, expiry ──
rig = Rig()
rig.m.observe(S(att("working", A(1)), gate=True, gates=T.gate_rows(0, 2)), 1000.0)
rig.m.observe(S(att("needs_input", A(2), "question", "Delete it?", None), gate=True, gates=T.gate_rows(0, 2)), 1002.0)
rig.m.observe(S(att("needs_input", A(2), "question", "Delete it?", None), gate=False, gates=T.gate_rows(1, 2)), 1004.0)
rig.m.step(1006.9)
T.eq(len(rig.fake.messages()), 0, "C3a. two candidates inside one window: nothing before the window ends")
rig.m.step(1007.0)
T.eq([m["data"]["kind"] for m in rig.fake.messages()], ["question"], "C3b. one message goes out: the highest priority (question > gate_red)")
T.eq(sorted((e["kind"], e["suppressed"]) for e in rig.pushes()),
     [("gate_red", "coalesced"), ("question", None)], "C3c. the loser is logged as coalesced")
rig.close()

rig = Rig()
rig.m.observe(S(att("working", A(1))), 1000.0)
rig.m.observe(S(att("needs_input", A(2), "question", "First?", None)), 1002.0)
rig.m.step(1007.0)
rig.m.observe(S(att("needs_input", A(3), "question", "Second?", None)), 1010.0)
rig.m.step(1015.0)
T.eq(len(rig.fake.messages()), 1, "C3d. a second message inside 10 s of the first waits (min gap), it is not dropped")
rig.m.step(1016.9)
T.eq(len(rig.fake.messages()), 1, "C3e. still waiting just before the gap ends")
rig.m.step(1017.0)
T.eq([m["body"] for m in rig.fake.messages()], ["First?", "Second?"], "C3f. it goes out the moment the gap is over")
rig.close()

rig = Rig()
rig.m.observe(S(att("working", A(1))), 1000.0)
rig.m.observe(S(att("needs_approval", A(2), "permission", "x"), approvals=[T.approval(P(1), "Bash", 1062.0)]), 1002.0)
rig.m.observe(S(att("needs_input", A(3), "question", "Q?", None)), 1003.0)
rig.m.step(1003.0)
T.eq([m["data"]["kind"] for m in rig.fake.messages()], ["approval"], "C3g. an approval does not wait for a window another kind opened")
rig.m.step(1008.0)
T.eq([m["data"]["kind"] for m in rig.fake.messages()], ["approval", "question"], "C3h. the windowed one follows when its window ends")
rig.close()

rig = Rig()
rig.m.observe(S(att("working", A(1))), 1000.0)
t = 1000.0
for i in range(2, 23):
    t += 12.0
    rig.m.observe(S(att("needs_input", A(i), "question", "Q%d?" % i, None)), t)
    rig.m.step(t + 5.5)
T.eq(len(rig.fake.messages()), 20, "C3i. at most 20 non-approval messages per rolling hour")
T.eq([e["suppressed"] for e in rig.pushes()].count("rate-limited"), 1, "C3j. the 21st is logged rate-limited")
t += 12.0
rig.m.observe(S(att("needs_input", A(99), "question", "Late?", None)), t + 3600.0)
rig.m.step(t + 3600.0 + 5.5)
T.eq(len(rig.fake.messages()), 21, "C3k. the cap is a ROLLING hour: an hour later it sends again")
rig.close()

rig = Rig()
rig.m.observe(S(att("working", A(1))), 1000.0)
for i in range(1, 22):
    rig.m.observe(S(att("needs_approval", A(100 + i), "permission", "x"),
                    approvals=[T.approval(P(i), "Bash", 5000.0)]), 1000.0 + i)
    rig.m.step(1000.0 + i)
T.eq(len(rig.fake.messages()), 20, "C3l. at most 20 approval messages per rolling hour as well")
rig.close()

rig = Rig(tokens=[{"token": TOK, "platform": "ios", "registered_at": T.iso(1), "events": ["question"]}])
rig.m.observe(S(att("working", A(1))), 1000.0)
rig.m.observe(S(att("needs_approval", A(2), "permission", "x"), approvals=[T.approval(P(1), "Bash", 1062.0)]), 1002.0)
rig.m.step(1002.0)
T.eq(len(rig.fake.messages()), 0, "C3m. a kind outside the device's events is not sent")
T.eq([(e["kind"], e["suppressed"]) for e in rig.pushes()], [("approval", "disabled-kind")], "C3n. logged as disabled-kind")
rig.close()

rig = Rig()
rig.m.observe(S(att("working", A(1))), 1000.0)
rig.m.observe(S(att("needs_approval", A(2), "permission", "x"), approvals=[T.approval(P(1), "Bash", 1005.0)]), 1002.0)
rig.m.step(1002.0)
T.eq(len(rig.fake.messages()), 0, "C3o. an approval with under 5 s of life left is not sent")
T.eq([(e["kind"], e["suppressed"]) for e in rig.pushes()], [("approval", "expired")], "C3p. logged as expired")
rig.close()

rig = Rig(tokens=[T.expo_token("a", 20), {"token": T.expo_token("b", 20), "ref": "0123456789abcdef", "label": "api server"}])
rig.m.observe(S(att("working", A(1))), 1000.0)
rig.m.observe(S(att("idle", A(2), "error")), 1002.0)
rig.m.step(1007.0)
msgs = {m["to"]: m for m in rig.fake.messages()}
T.eq(sorted(m["title"] for m in msgs.values()), ["api server · agent error", "hmd · agent error"],
     "C3q. two devices: one message each, each with its own label")
T.eq(msgs[T.expo_token("b", 20)]["data"]["ref"], "0123456789abcdef", "C3r. the registered ref is the one in data")
T.eq(len(rig.fake.sends()), 1, "C3s. both go in ONE request")
rig.close()

# ── C4. batching ──
many = [T.expo_token("a%03d" % i, 3) for i in range(250)]
rig = Rig(tokens=many)
rig.m.observe(S(att("working", A(1))), 1000.0)
rig.m.observe(S(att("needs_approval", A(2), "permission", "x"), approvals=[T.approval(P(1), "Bash", 1062.0)]), 1002.0)
rig.m.step(1002.0)
T.eq([len(r["body"]) for r in rig.fake.sends()], [100, 100, 50], "C4a. 250 devices -> requests of 100, 100 and 50 messages")
T.eq(len({m["to"] for m in rig.fake.messages()}), 250, "C4b. every device is addressed exactly once")
rig.close()

# ── C5. DeviceNotRegistered prunes: from a ticket, and from a receipt ──
rig = Rig()
rig.fake.unregistered.add(TOK)
rig.m.observe(question_pair()[0], 1000.0)
rig.m.observe(question_pair()[1], 1002.0)
rig.m.step(1007.0)
T.eq(rig.store.removed(), [TOK], "C5a. a DeviceNotRegistered ticket removes that token from the store")
T.eq([(e["ok"], e["detail"]) for e in rig.pushes()], [(False, "DeviceNotRegistered")], "C5b. logged by code, not by token")
rig.m.observe(question_pair(3)[1], 1100.0)
rig.m.step(1110.0)
T.eq(len(rig.fake.sends()), 1, "C5c. nothing more is sent once the device is gone")
rig.close()

rig = Rig()
rig.m.observe(question_pair()[0], 1000.0)
rig.m.observe(question_pair()[1], 1002.0)
rig.m.step(1007.0)
T.eq(len(rig.fake.receipt_requests()), 0, "C5d. no receipts request right after a send")
rig.fake.receipt_unregistered.add(TOK)
rig.m.step(1906.9)
T.eq(len(rig.fake.receipt_requests()), 0, "C5e. none before 900 s have passed")
rig.m.step(1907.0)
T.eq(len(rig.fake.receipt_requests()), 1, "C5f. receipts are fetched once, 900 s after the oldest ticket")
T.eq(rig.fake.receipt_requests()[0]["body"], {"ids": ["ticket-1"]}, "C5g. by ticket id")
T.eq(rig.store.removed(), [TOK], "C5h. a DeviceNotRegistered receipt removes the token too")
rig.m.step(3000.0)
T.eq(len(rig.fake.receipt_requests()), 1, "C5i. fetched once")
rig.close()

rig = Rig()
rig.m.observe(question_pair()[0], 1000.0)
rig.m.observe(question_pair()[1], 1002.0)
rig.m.step(1007.0)
rig.m.step(1907.0)
T.eq((rig.store.removed(), len(rig.fake.receipt_requests())), ([], 1), "C5j. an ok receipt changes nothing")
rig.close()


class BrokenStore:
    def __init__(self, inner, mode):
        self.inner, self.mode = inner, mode

    def load(self, root):
        if self.mode == "load":
            raise OSError("disk gone")
        if self.mode == "garbage":
            return "not a dict"
        return self.inner.load(root)

    def remove_tokens(self, root, tokens):
        raise OSError("read-only")


inner = T.FileStore(os.path.join(tmp, "inner.json"))
inner.seed([TOK])
for mode in ("load", "garbage", "remove"):
    rig = Rig(store=BrokenStore(inner, mode))
    if mode == "remove":
        rig.fake.unregistered.add(TOK)
    rig.m.observe(question_pair()[0], 1000.0)
    rig.m.observe(question_pair()[1], 1002.0)
    try:
        rig.m.step(1007.0)
        rig.m.observe(question_pair(3)[1], 1100.0)
        rig.m.step(1110.0)
        ok_run = True
    except Exception as exc:
        ok_run = repr(exc)
    T.eq(ok_run, True, "C5k. a store that fails on %s never raises into the caller" % mode)
    errors = [e for e in rig.events if e.get("event") == "error"]
    T.check(len(errors) >= 1 and TOK not in json.dumps(rig.events), "C5l. store failure (%s) is reported, without the token" % mode, rig.events)
    T.check(len(errors) <= 2, "C5m. store failure (%s) is not logged on every tick" % mode, len(errors))
    rig.close()

# ── C6. retries, back-pressure, credentials ──
rig = Rig()
rig.fake.script = [{"status": 500}, {"status": 429}]
rig.m.observe(question_pair()[0], 1000.0)
rig.m.observe(question_pair()[1], 1002.0)
rig.m.step(1007.0)
T.eq((len(rig.fake.sends()), rig.sleeps, [e["ok"] for e in rig.pushes()]), (3, [1, 2], [True]),
     "C6a. a 500 then a 429 are retried after 1 s and 2 s; the third try succeeds")
rig.close()

rig = Rig()
rig.fake.script = [{"status": 429}] * 4
rig.m.observe(question_pair()[0], 1000.0)
rig.m.observe(question_pair()[1], 1002.0)
rig.m.step(1007.0)
T.eq((len(rig.fake.sends()), rig.sleeps), (4, [1, 2, 4]), "C6b. retried after 1, 2 and 4 s, then given up (4 requests)")
T.eq([(e["ok"], e["detail"]) for e in rig.pushes()], [(False, "http-429")], "C6c. the failure is logged by status")
rig.m.observe(question_pair(3)[1], 1020.0)
rig.m.step(1030.0)
T.eq(len(rig.fake.sends()), 4, "C6d. inside the 60 s back-off nothing is attempted")
T.eq([e["detail"] for e in rig.pushes()][-1], "backoff", "C6e. the skipped send is logged as backoff")
rig.m.observe(question_pair(4)[1], 1100.0)
rig.m.step(1110.0)
T.eq(len(rig.fake.sends()), 5, "C6f. after the back-off it tries again")
rig.close()

rig = Rig()
rig.fake.script = [{"tickets": [{"status": "error", "message": "slow down", "details": {"error": "MessageRateExceeded"}}]}]
rig.m.observe(question_pair()[0], 1000.0)
rig.m.observe(question_pair()[1], 1002.0)
rig.m.step(1007.0)
T.eq((len(rig.fake.sends()), rig.sleeps, [e["ok"] for e in rig.pushes()]), (2, [1], [True]),
     "C6g. a MessageRateExceeded ticket is retried after 1 s")
rig.close()

rig = Rig()
rig.fake.script = [{"tickets": [{"status": "error", "message": "bad key", "details": {"error": "InvalidCredentials"}}]}]
rig.m.observe(question_pair()[0], 1000.0)
rig.m.observe(question_pair()[1], 1002.0)
rig.m.step(1007.0)
T.eq([(e["ok"], e["detail"]) for e in rig.pushes()], [(False, "InvalidCredentials")], "C6h. InvalidCredentials is logged by code")
rig.m.observe(question_pair(3)[1], 1100.0)
rig.m.step(1110.0)
T.eq(len(rig.fake.sends()), 1, "C6i. all sending is paused for an hour after InvalidCredentials")
rig.m.observe(question_pair(4)[1], 1007.0 + 3601.0)
rig.m.step(1007.0 + 3611.0)
T.eq(len(rig.fake.sends()), 2, "C6j. and resumes after it")
rig.close()

rig = Rig()
rig.fake.script = [{"status": 200, "tickets": []}]
rig.m.observe(question_pair()[0], 1000.0)
rig.m.observe(question_pair()[1], 1002.0)
rig.m.step(1007.0)
T.eq([(e["ok"], e["detail"]) for e in rig.pushes()], [(False, "bad-response")], "C6k. a 200 whose ticket list does not match is a failure, not a success")
rig.close()

# ── C7. a dead or hanging network never blocks the caller ──
dead = T.FakeExpo()
dead.close()
rig = Rig(fake=dead)
rig.m.observe(question_pair()[0], 1000.0)
rig.m.observe(question_pair()[1], 1002.0)
began = time.perf_counter()
rig.m.step(1007.0)
T.eq((rig.sleeps, [(e["ok"], e["detail"]) for e in rig.pushes()]), ([1, 2, 4], [(False, "network")]),
     "C7a. connection refused: retried after 1, 2, 4 s and logged as network, no exception")
T.check(time.perf_counter() - began < 5, "C7b. a refused connection fails fast")
rig.close()

slow = T.FakeExpo()
slow.script = [{"hang": 4.0}] * 4
rig = Rig(fake=slow, cfg={"timeout_s": 0.3})
rig.m.observe(question_pair()[0], 1000.0)
rig.m.observe(question_pair()[1], 1002.0)
began = time.perf_counter()
rig.m.step(1007.0)
took = time.perf_counter() - began
T.check(took < 3.5 and [(e["ok"], e["detail"]) for e in rig.pushes()] == [(False, "network")],
        "C7c. a server that never answers costs one timeout per attempt, then fails as network", (took, rig.events))
rig.close()

hang = T.FakeExpo()
hang.script = [{"hang": 3.0}] * 6
rig = Rig(fake=hang, cfg={"timeout_s": 0.5, "retry_delays": (0, 0)}, start_thread=True)
now = time.time()
rig.m.observe(S(att("working", A(1))), now)
slowest, raised = 0.0, []
for i in range(1, 301):
    began = time.perf_counter()
    try:
        rig.m.observe(S(att("needs_approval", A(1000 + i), "permission", "x"),
                        approvals=[T.approval(P(i), "Bash", now + 600.0)], ts=now + i), now + i)
    except Exception as exc:
        raised.append(exc)
    slowest = max(slowest, time.perf_counter() - began)
    if i == 5:
        time.sleep(0.4)   # let the worker reach the hanging request
T.check(slowest < 0.25 and not raised, "C7d. 300 observe() calls while the worker is stuck on a hung Expo: none blocks (slowest %.1f ms; a blocked call would cost the 500 ms timeout)" % (slowest * 1000), (slowest, raised))
T.check(len(rig.m._pending) <= CP.EVENT_QUEUE_CAP, "C7e. the event queue is bounded (drop-oldest)", len(rig.m._pending))
began = time.perf_counter()
rig.m.close()
T.check(time.perf_counter() - began < 5, "C7f. close() returns promptly even with a request in flight")
hang.close()

# ── C8. log hygiene: never a token, title, body or ref ──
rig = Rig(tokens=[{"token": TOK, "platform": "ios", "registered_at": T.iso(1), "ref": "0123456789abcdef", "label": "api server"}])
rig.m.observe(S(att("working", A(1))), 1000.0)
rig.m.observe(S(att("needs_input", A(2), "question", "ZEBRAMARKER walk the dog?", YESNO)), 1002.0)
rig.m.step(1007.0)
rig.fake.unregistered.add(TOK)
rig.m.observe(S(att("idle", A(3), "error")), 1100.0)
rig.m.step(1110.0)
wire = json.dumps(rig.events)
T.check(len(rig.pushes()) == 2 and TOK not in wire and "ZEBRAMARKER" not in wire and "0123456789abcdef" not in wire
        and "api server" not in wire and "hmd asks" not in wire and "Open to see it" not in wire,
        "C8a. the event log carries no token, title, body, label or ref", wire)
T.check(all(set(e) == {"event", "kind", "device", "ok", "detail", "suppressed", "ms"} for e in rig.pushes())
        and all(len(e["device"]) == 8 and isinstance(e["ms"], int) for e in rig.pushes()),
        "C8b. every push line has exactly the documented keys, an 8-char device fingerprint and integer ms", rig.pushes())
written = sorted(os.path.relpath(os.path.join(d, f), rig.root) for d, _, fs in os.walk(rig.root) for f in fs)
T.eq(written, [".heimdall/app/push-sender.lock"], "C8c. the only file the sender creates in the repo is its lock")
rig.close()

# ── C9. kill switch, endpoint override, config clamps ──
rig = Rig(env={"HMD_PUSH": "0"})
rig.m.observe(question_pair()[0], 1000.0)
rig.m.observe(question_pair()[1], 1002.0)
rig.m.step(1010.0)
T.eq((len(rig.fake.requests), rig.events, os.path.exists(rig.lock_path())), (0, [], False),
     "C9a. HMD_PUSH=0: nothing is planned, sent, logged or locked")
rig.close()

errors = []
for url in ("https://evil.example/--/api/v2/push/send", "http://127.0.0.1.evil.com/x", "http://localhost@evil.com/x",
            "ftp://127.0.0.1/x", "http://[::1]:9/x", "garbage"):
    errors.clear()
    send_url, receipts_url, loopback = CP.resolve_endpoint({"HMD_PUSH_EXPO_URL": url}, errors.append)
    T.check((send_url, receipts_url, loopback) == (CP.EXPO_SEND_URL, CP.EXPO_RECEIPTS_URL, False)
            and [e["event"] for e in errors] == ["error"] and url not in json.dumps(errors),
            "C9b. HMD_PUSH_EXPO_URL=%s is ignored, with one error event that does not echo it" % url, (send_url, errors))
for url in ("http://127.0.0.1:1234/--/api/v2/push/send", "http://localhost:5/--/api/v2/push/send"):
    errors.clear()
    send_url, receipts_url, loopback = CP.resolve_endpoint({"HMD_PUSH_EXPO_URL": url}, errors.append)
    T.check(send_url == url and receipts_url == url[:-len("send")] + "getReceipts" and loopback and errors == [],
            "C9c. a loopback HMD_PUSH_EXPO_URL (%s) is honoured, receipts derived next to it" % url, (send_url, receipts_url))
T.eq(CP.resolve_endpoint({}, errors.append), (CP.EXPO_SEND_URL, CP.EXPO_RECEIPTS_URL, False), "C9d. unset -> the real Expo endpoints")
T.eq((CP.config_from_env({"HMD_PUSH_COALESCE_S": "0"})["coalesce_s"], CP.config_from_env({"HMD_PUSH_COALESCE_S": "999"})["coalesce_s"],
      CP.config_from_env({"HMD_PUSH_COALESCE_S": "abc"})["coalesce_s"], CP.config_from_env({})["coalesce_s"]),
     (1, 60, 5.0, 5.0), "C9e. HMD_PUSH_COALESCE_S is clamped to 1..60 and a garbage value reads as the default")
T.eq((CP.config_from_env({"HMD_PUSH_MIN_RUN_S": "-5"})["min_run_s"], CP.config_from_env({"HMD_PUSH_MIN_RUN_S": "99999"})["min_run_s"],
      CP.config_from_env({"HMD_PUSH_MIN_RUN_S": "nan"})["min_run_s"], CP.config_from_env({})["min_run_s"]),
     (0, 3600, 60.0, 60.0), "C9f. HMD_PUSH_MIN_RUN_S is clamped to 0..3600 and nan reads as the default")
paths = CP.source_paths("/r")
T.check(paths == ["/r/.heimdall/app/push.json", "/r/.heimdall/app/push-sender.lock"], "C9g. source_paths names the store and the lock", paths)

# ── C10. no devices -> no network, no lock; one sender per repo inside a process ──
rig = Rig(tokens=[])
rig.m.observe(question_pair()[0], 1000.0)
rig.m.observe(question_pair()[1], 1002.0)
rig.m.step(1010.0)
T.eq((len(rig.fake.requests), rig.events, os.path.exists(rig.lock_path())), (0, [], False),
     "C10a. nothing registered: events are handled and dropped; no request, no log, the lock file is never created")
rig.close()

rig1 = Rig()
rig2 = Rig(root=rig1.root, store=rig1.store, fake=rig1.fake)
for r in (rig1, rig2):
    r.m.observe(question_pair()[0], 1000.0)
    r.m.observe(question_pair()[1], 1002.0)
for r in (rig1, rig2):
    r.m.step(1007.0)
T.eq(len(rig1.fake.messages()), 1, "C10b. two monitors on one repo (same process): exactly ONE message is sent")
T.eq((len(rig1.pushes()), len(rig2.pushes())), (1, 0), "C10c. and only the owner logs it")
rig1.m.close()
for r in (rig1, rig2):
    r.m.observe(question_pair(3)[1], 1100.0)
    r.m.step(1110.0)
T.eq(len(rig1.fake.messages()), 2, "C10d. when the owner closes, the other monitor takes over at its next event")
rig2.m.close()
rig1.fake.close()

# ── C11. out-of-order states never fabricate a transition ──
rig = Rig()
rig.m.observe(S(gate=True, ts=1000.0), 1000.0)
rig.m.observe(S(gate=False, ts=1002.0), 1002.0)
rig.m.observe(S(gate=True, ts=1001.0), 1003.0)
rig.m.observe(S(gate=False, ts=1004.0), 1004.0)
rig.m.step(1010.0)
T.eq([(e["kind"], e["suppressed"]) for e in rig.pushes()], [("gate_red", None)],
     "C11a. a state older than the newest seen is ignored: ONE gate_red planned (no second one to coalesce away)")
rig.close()

# ── C12. an event that cannot be built is logged, never sent, never raised ──
rig = Rig()
rig.m._pending.append((1000.0, {"kind": "finished", "key": "f:x", "ep": None, "fields": {"variant": "bogus"}}))
rig.m.step(1010.0)
T.eq((len(rig.fake.requests), [(e["ok"], e["detail"]) for e in rig.pushes()]), (0, [(False, "unbuildable")]),
     "C12a. an unbuildable event is logged as unbuildable and sends nothing")
rig.close()
print("done")
PYEOF
run_part C "$TMPROOT/part_c.py"

# ── D. the real hmd-ui StateCache hook ───────────────────────────────────────────────────
cat >"$TMPROOT/part_d.py" <<'PYEOF'
import datetime
import json
import os
import re
import subprocess
import sys
import threading
import time
import uuid

code, tmp = sys.argv[1], sys.argv[2]
sys.path.insert(0, os.path.join(code, "test", "lib"))
import push_test_lib as T

home = os.path.join(tmp, "home")
projects = os.path.join(home, ".claude", "projects")
os.makedirs(projects)
fake = T.FakeExpo()
os.environ.update(HOME=home, HEIMDALL_HOME=os.path.join(home, ".heimdall"), TMPDIR=tmp, HMD_AGENT_PROJECTS_DIR=projects,
                  HMD_PUSH_EXPO_URL=fake.url, HMD_PUSH_COALESCE_S="1", HMD_PUSH_MIN_RUN_S="0",
                  HMD_UI_COMPANION_PANELS="0", HEIMDALL_FALLBACK_ASSUME_REACHABLE="0")
for name in ("CLAUDE_CODE_SESSION_ID", "CLAUDE_SESSION_ID", "SESSION_ID", "HMD_PUSH"):
    os.environ.pop(name, None)
root = os.path.realpath(os.path.join(tmp, "repo"))
os.makedirs(root)
subprocess.run(["git", "init", "-q", root], check=True)
subprocess.run(["git", "-C", root, "-c", "user.email=t@t", "-c", "user.name=t", "commit", "-q", "--allow-empty", "-m", "fixture"],
               check=True)
sid = str(uuid.uuid4())
pdir = os.path.join(projects, re.sub(r"[^A-Za-z0-9]", "-", root))
os.makedirs(pdir)
transcript = os.path.join(pdir, sid + ".jsonl")


def put(kind, text=""):
    """Append one transcript entry in the shape Claude Code writes it."""
    now = time.time()
    stamp = datetime.datetime.fromtimestamp(now, datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.") + "%03dZ" % int((now % 1) * 1000)
    entry = {"parentUuid": None, "isSidechain": False, "uuid": str(uuid.uuid4()), "timestamp": stamp,
             "sessionId": sid, "entrypoint": "cli", "cwd": root}
    if kind == "prompt":
        entry.update(type="user", message={"role": "user", "content": text})
    else:
        entry.update(type="assistant", message={"role": "assistant", "stop_reason": "end_turn",
                                                "content": [{"type": "text", "text": text}]})
    with open(transcript, "a", encoding="utf-8") as f:
        f.write(json.dumps(entry, separators=(",", ":")) + "\n")


def wait_for(pred, secs):
    end = time.monotonic() + secs
    while time.monotonic() < end:
        if pred():
            return True
        time.sleep(0.05)
    return pred()


TOK = T.expo_token("t")
ui = T.load("hmd_ui", os.path.join(code, "sentinels", "hmd-ui.py"))
put("prompt", "do the thing")
store = T.FileStore(os.path.join(tmp, "store.json"))
store.seed([TOK], "background", time.time())
transport = {"bind": "relay", "public_host": "relay", "trust_proxy": False, "port": 0}
cache = ui.StateCache(root, transport)
T.check(cache._push is not None, "D1. a StateCache builds a PushMonitor by default")
cache._push.store = store
logged = []
cache._push.emit = logged.append
cache.start()
_, digest = cache.wait_for_change(None, 90)
time.sleep(1.0)

# a question in the transcript -> one push, however many polls follow
put("end", "Should I delete the old branch?")
T.check(wait_for(lambda: len(fake.messages()) >= 1, 45), "D2. a transcript question reaches Expo through the StateCache poller")
if fake.messages():
    first = fake.messages()[0]
    T.eq((first["to"], first["title"], first["data"]["kind"]), (TOK, "hmd · hmd asks", "question"),
         "D2b. addressed to the registered token, titled hmd asks")
    T.check(first["body"].startswith("Should I delete the old branch?"), "D2c. the body is the question summary", first["body"])
time.sleep(3.0)
T.eq(len(fake.messages()), 1, "D3. exactly one push no matter how many polls follow")

# a phone-deny request -> one approval push at once; the command text never leaves
req = ui.DECISIONS.request(root, "Bash", "git push origin main " + T.LEAK["cmd"], 45.0)
beat = threading.Event()


def heartbeats():
    while not beat.wait(1.0):
        for name in os.listdir(os.path.join(root, ".heimdall", "ui", "approvals")):
            if name.endswith(".json"):
                ui.DECISIONS.heartbeat(root, name[:-5])


threading.Thread(target=heartbeats, daemon=True).start()
T.check(wait_for(lambda: len(fake.messages()) >= 2, 45), "D4. a pending phone-deny request reaches Expo")
if len(fake.messages()) >= 2:
    second = fake.messages()[1]
    T.check(second["data"]["kind"] == "approval" and second["data"]["pid"] == req["id"]
            and re.fullmatch(r"Bash is waiting\. Deny within 4[45] s\.", second["body"]),
            "D4b. an approval message for exactly that request, with the seconds left", second)
T.check(T.LEAK["cmd"] not in json.dumps(fake.messages()) and "git push" not in json.dumps(fake.messages()),
        "D5. the command text of the approval is nowhere in what was sent")
T.check(all(TOK not in json.dumps(e) for e in logged), "D5b. the log carries no token", logged)

# a hung Expo costs the poller nothing
fake.script = [{"hang": 30.0}] * 6
req2 = ui.DECISIONS.request(root, "Write", "write " + T.LEAK["cmd"], 45.0)
T.check(wait_for(lambda: len(fake.sends()) >= 3, 45), "D6. the next push goes out to the (now hanging) Expo")


def probe(value):
    ui.PANELS.write_panel(root, "probe", {"id": "probe", "title": "probe", "type": "number",
                                          "data": {"value": value, "format": "count"}, "refresh_s": 30,
                                          "updated_at": time.time()})


def landed(state, value):
    return any(p.get("id") == "probe" and (p.get("data") or {}).get("value") == value for p in state.get("panels") or [])


def latency(value):
    _, seen = cache.latest()
    probe(value)
    began = time.monotonic()
    while time.monotonic() - began < 5.0:
        state, now_digest = cache.wait_for_change(seen, 1.0)
        if now_digest != seen:
            seen = now_digest
            if landed(state, value):
                return time.monotonic() - began
    return None


lats = [latency(v) for v in range(1, 6)]
T.check(all(v is not None for v in lats) and max(lats) < 3.0,
        "D7. while the sender is stuck on a hung Expo a panel write still reaches the digest fast (worst %s s)"
        % ("%.2f" % max(v for v in lats if v is not None) if any(v is not None for v in lats) else "n/a"), lats)
beat.set()
began = time.monotonic()
cache.stop()
T.check(time.monotonic() - began < 6, "D8. stopping the cache returns promptly with a request still in flight")

# the kill switch and the print-sources list
os.environ["HMD_PUSH"] = "0"
off = ui.StateCache(root, transport)
T.check(off._push is None, "D9. HMD_PUSH=0: the StateCache builds no monitor at all")
del os.environ["HMD_PUSH"]
listing = subprocess.run([sys.executable, os.path.join(code, "sentinels", "hmd-ui.py"), "--repo", root, "--print-sources"],
                         capture_output=True, text=True, timeout=30).stdout
T.check(os.path.join(root, ".heimdall", "app", "push.json") in listing
        and os.path.join(root, ".heimdall", "app", "push-sender.lock") in listing,
        "D10. --print-sources names the push store and the sender lock", listing[-400:])
fake.close()
print("done")
PYEOF
run_part D "$TMPROOT/part_d.py"

# ── ERR. an API-error turn end, end to end (PN3) ─────────────────────────────────────────
# `attention.kind:"error"` is derived by bin/lib/companion_ui_attention.py from Claude Code's own
# transcript entry for a failed request (isApiErrorMessage:true). Part B proves the planner turns such
# an attention into one error event; this part proves the two halves meet: a REAL collector run over a
# transcript written in the shapes Claude Code writes, its output handed to a monitor over the
# PRODUCTION store, a loopback fake Expo on the far end, and a clock the test drives.
cat >"$TMPROOT/part_err.py" <<'PYEOF'
import datetime
import json
import os
import re
import sys
import time
import uuid

code, tmp = sys.argv[1], sys.argv[2]
os.makedirs(tmp, exist_ok=True)
sys.path.insert(0, os.path.join(code, "test", "lib"))
import push_test_lib as T

projects = os.path.join(tmp, "projects")
os.makedirs(projects)
os.environ["HMD_AGENT_PROJECTS_DIR"] = projects
for name in ("CLAUDE_CODE_SESSION_ID", "CLAUDE_SESSION_ID", "SESSION_ID", "CLAUDE_CONFIG_DIR"):
    os.environ.pop(name, None)

CP = T.load("companion_push", os.path.join(code, "bin", "lib", "companion_push.py"))
STORE = T.load("companion_push_store", os.path.join(code, "bin", "lib", "companion_push_store.py"))
ATT = T.load("companion_ui_attention", os.path.join(code, "bin", "lib", "companion_ui_attention.py"))
TOK, REF = T.expo_token("t"), T.session_ref()
ID_RE = re.compile(r"a-[0-9a-f]{10}")
RATE = "You've hit your session limit · resets 1:50am (Asia/Calcutta)"
OVERLOADED = "API Error: 529 Overloaded. This is a server-side issue, usually temporary — try again in a moment."
BODY = "The session stopped on an error. Open to see it."
_n = [0]


def stamp(age):
    t = time.time() - age
    return datetime.datetime.fromtimestamp(t, datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.") + "%03dZ" % int((t % 1) * 1000)


class Run:
    """One fixture repo with its Claude Code transcript, a PushMonitor over the production store (built the way
    sentinels/hmd-ui.py builds it) aimed at a loopback fake Expo, and a clock the test drives. tick() is one poll of
    the host: derive `attention` from the transcript with the real collector, hand the state to the monitor, run
    the worker's pass."""

    def __init__(self, min_run_s=0.0):
        _n[0] += 1
        self.root = os.path.realpath(os.path.join(tmp, "repo%d" % _n[0]))
        os.makedirs(self.root)
        pdir = os.path.join(projects, re.sub(r"[^A-Za-z0-9]", "-", self.root))
        os.makedirs(pdir)
        self.sid = str(uuid.uuid4())
        self.path = os.path.join(pdir, self.sid + ".jsonl")
        self.fake = T.FakeExpo()
        STORE.register(self.root, TOK, "ios", ref=REF, label="api server")
        self.events = []
        self.m = CP.PushMonitor(self.root, emit=self.events.append, config={"min_run_s": min_run_s, "timeout_s": 3.0},
                                sleep=lambda seconds: None, environ={"HMD_PUSH_EXPO_URL": self.fake.url},
                                start_thread=False)
        self.clock = 1000.0

    def put(self, kind, text="", age=0.0, category="rate_limit", status=429):
        """Append one entry in the shape Claude Code writes it, `age` seconds old. "error" is the synthetic assistant
        entry of a request that failed (isApiErrorMessage:true, the category in `error`, the HTTP status); "noresp" the
        same synthetic shape with the flag false ("No response requested.")."""
        base = {"parentUuid": None, "isSidechain": False, "uuid": str(uuid.uuid4()), "timestamp": stamp(age),
                "sessionId": self.sid, "entrypoint": "cli", "cwd": self.root}
        if kind == "prompt":
            rows = [dict(base, type="user", message={"role": "user", "content": text})]
        elif kind == "tool":
            tid = "toolu_" + uuid.uuid4().hex[:12]
            call = {"type": "tool_use", "id": tid, "name": "Bash", "input": {"command": "echo hi"}}
            result = {"type": "tool_result", "tool_use_id": tid, "content": "hi"}
            rows = [dict(base, type="assistant", message={"role": "assistant", "stop_reason": "tool_use", "content": [call]}),
                    dict(base, uuid=str(uuid.uuid4()), type="user", message={"role": "user", "content": [result]})]
        elif kind == "end":
            rows = [dict(base, type="assistant", message={"role": "assistant", "stop_reason": "end_turn",
                                                           "content": [{"type": "text", "text": text}]})]
        elif kind == "interrupt":
            rows = [dict(base, type="user", message={"role": "user", "content": [
                {"type": "text", "text": "[Request interrupted by user]"}]})]
        elif kind == "turn":
            rows = [dict(base, type="system", subtype="turn_duration", durationMs=1000)]
        elif kind in ("error", "noresp"):
            usage = {"input_tokens": 0, "output_tokens": 0, "cache_creation_input_tokens": 0, "cache_read_input_tokens": 0}
            synthetic = {"id": str(uuid.uuid4()), "container": None, "model": "<synthetic>", "role": "assistant",
                         "stop_details": None, "stop_reason": "stop_sequence", "stop_sequence": "", "type": "message",
                         "content": [{"type": "text", "text": text or "No response requested."}], "usage": usage,
                         "context_management": None}
            row = dict(base, type="assistant", isApiErrorMessage=(kind == "error"), message=synthetic)
            if kind == "error":
                row.update(error=category, apiErrorStatus=status)
            rows = [row]
        else:
            raise ValueError(kind)
        with open(self.path, "a", encoding="utf-8") as f:
            for row in rows:
                f.write(json.dumps(row, separators=(",", ":")) + "\n")

    def tick(self, dt):
        self.clock += dt
        att = ATT.collect(self.root)
        self.m.observe(T.state(att), self.clock)
        self.m.step(self.clock)
        return att

    def kinds(self):
        return [msg["data"]["kind"] for msg in self.fake.messages()]

    def close(self):
        self.m.close()
        self.fake.close()


# ── ERR1. one error -> one push, however many polls follow ──
run = Run()
run.put("prompt", "fix the flaky test", age=300)
run.put("tool", age=250)
a0 = run.tick(0)
T.eq((a0["state"], a0["kind"]), ("working", None), "ERR1a. a run in progress is working; this first tick is the monitor's silent baseline")
run.put("error", RATE, age=5)
run.put("turn", age=4.9)
a1 = run.tick(1.0)
T.check(a1["state"] == "idle" and a1["kind"] == "error" and a1["summary"] == RATE and ID_RE.fullmatch(a1["id"] or ""),
        "ERR1b. the transcript's API-error entry is attention idle/error, its text the summary, with an episode id", a1)
T.eq(len(run.fake.messages()), 0, "ERR1c. the error waits out the coalescing window like any non-approval event")
run.tick(5.0)
msgs = run.fake.messages()
T.eq(len(msgs), 1, "ERR1d. exactly one message is POSTed for the error")
if msgs:
    T.eq((msgs[0]["to"], msgs[0]["title"], msgs[0]["body"], msgs[0]["data"]),
         (TOK, "api server · agent error", BODY, {"v": 1, "ref": REF, "kind": "error", "ep": a1["id"]}),
         "ERR1e. addressed to the registered token, the allowlisted title and body, the data keyed to that attention id")
T.check("Calcutta" not in json.dumps(msgs) and "session limit" not in json.dumps(msgs),
        "ERR1f. the provider's error text stays out of the notification (it rides attention.summary only)")
for _ in range(5):
    run.tick(30.0)
T.eq(len(run.fake.messages()), 1, "ERR1g. the poller re-reading the same error episode sends nothing more")
T.eq([(e["kind"], e["ok"], e["suppressed"]) for e in run.events if e.get("event") == "push"], [("error", True, None)],
     "ERR1h. one log line: an error push, ok, not suppressed")

# ── ERR2. recovery: work resuming clears the error and pushes nothing ──
run.put("prompt", "continue", age=0.5)
a2 = run.tick(30.0)
T.check(a2["state"] == "working" and a2["kind"] is None and a2["summary"] is None and a2["id"] != a1["id"],
        "ERR2a. a new prompt clears the error: working, kind and summary null, a new episode id", a2)
run.put("tool", age=0.2)
run.tick(30.0)
T.eq(len(run.fake.messages()), 1, "ERR2b. the recovery sent no extra push")

# ── ERR3. a second error is a new transition: one more push, keyed to its own id ──
run.put("error", OVERLOADED, age=0.1, category="server_error", status=529)
run.put("turn", age=0.05)
a3 = run.tick(1.0)
T.check(a3["kind"] == "error" and a3["id"] not in (a1["id"], a2["id"]) and a3["summary"] == OVERLOADED,
        "ERR3a. the next failed request is a new error episode (distinct id)", a3)
run.tick(15.0)
T.eq(run.kinds(), ["error", "error"], "ERR3b. exactly one more error push")
if len(run.fake.messages()) == 2:
    T.eq(run.fake.messages()[1]["data"]["ep"], a3["id"], "ERR3c. the second push is keyed to the second episode")
for _ in range(3):
    run.tick(30.0)
T.eq(len(run.fake.messages()), 2, "ERR3d. and only one")
run.close()

# ── ERR4. stops that are NOT errors never push an error ──
STOPS = (("a user interrupt", "interrupt", ""),
         ("an ordinary end_turn", "end", "All done."),
         ("the unflagged synthetic 'No response requested.' entry (isApiErrorMessage false)", "noresp", ""))
for label, kind, text in STOPS:
    r = Run()
    r.put("prompt", "work", age=60)
    r.put("tool", age=30)
    r.tick(0)
    r.put(kind, text, age=4.0)
    r.put("turn", age=3.9)
    att = r.tick(1.0)
    r.tick(10.0)
    r.tick(30.0)
    T.check(att["state"] == "idle" and att["kind"] == "stopped", "ERR4a. %s is attention idle/stopped, not error" % label, att)
    T.check("error" not in r.kinds(), "ERR4b. %s: no error push (sent: %s)" % (label, r.kinds()), r.kinds())
    r.close()

# ── ERR5. an error left over from before the monitor started is a baseline, not a push ──
r = Run()
r.put("prompt", "old work", age=400)
r.put("error", RATE, age=300)
r.put("turn", age=299.9)
b = r.tick(0)
r.tick(10.0)
r.tick(30.0)
T.check(b["kind"] == "error" and r.kinds() == [], "ERR5. an API error already in the transcript when the monitor starts is silent", [b["kind"], r.kinds()])
r.close()
print("done")
PYEOF
run_part ERR "$TMPROOT/part_err.py"

# ── E. two processes on one repo: exactly one sender, and a failover ─────────────────────
cat >"$TMPROOT/push_child.py" <<'PYEOF'
import json
import os
import sys
import time

code, root, store_path, url, name, ctl = sys.argv[1:7]
sys.path.insert(0, os.path.join(code, "test", "lib"))
import push_test_lib as T

CP = T.load("companion_push", os.path.join(code, "bin", "lib", "companion_push.py"))
S, att, A, P = T.state, T.attention, T.a_id, T.p_id


def flag(*parts):
    return os.path.join(ctl, "-".join(parts))


def wait_for(path, secs=40.0):
    end = time.monotonic() + secs
    while time.monotonic() < end:
        if os.path.exists(path):
            return True
        time.sleep(0.02)
    return False


def touch(path):
    with open(path, "w", encoding="utf-8") as f:
        f.write("1")


events = []
monitor = CP.PushMonitor(root, store=T.FileStore(store_path), emit=events.append, config={"min_run_s": 0},
                         environ={"HMD_PUSH_EXPO_URL": url}, start_thread=False)


def report(round_name):
    with open(flag("result", name, round_name), "w", encoding="utf-8") as f:
        json.dump([e for e in events if e.get("event") == "push"], f)


monitor.observe(S(att("working", A(1))), 1000.0)
touch(flag("ready", name))
if not wait_for(flag("go1")):
    sys.exit(3)
monitor.observe(S(att("needs_approval", A(2), "permission", "x"), approvals=[T.approval(P(1), "Bash", 1062.0)]), 1002.0)
monitor.step(1002.0)
report("1")
touch(flag("done1", name))
while not (os.path.exists(flag("exit", name)) or os.path.exists(flag("go2"))):
    time.sleep(0.02)
if os.path.exists(flag("exit", name)):
    sys.exit(0)                      # the process dies holding nothing: the kernel frees the flock
monitor.observe(S(att("needs_input", A(3), "question", "Second?", None)), 1100.0)
monitor.step(1110.0)
report("2")
touch(flag("done2", name))
monitor.close()
PYEOF
cat >"$TMPROOT/part_e.py" <<'PYEOF'
import json
import os
import subprocess
import sys
import time

code, tmp = sys.argv[1], sys.argv[2]
os.makedirs(tmp)
sys.path.insert(0, os.path.join(code, "test", "lib"))
import push_test_lib as T

ctl = os.path.join(tmp, "ctl")
os.makedirs(ctl)
root = os.path.join(tmp, "repo")
os.makedirs(root)
store_path = os.path.join(tmp, "store.json")
T.FileStore(store_path).seed([T.expo_token("t")])
fake = T.FakeExpo()
child = os.path.join(os.path.dirname(tmp), "push_child.py")
procs = {name: subprocess.Popen([sys.executable, child, code, root, store_path, fake.url, name, ctl]) for name in ("a", "b")}


def flag(*parts):
    return os.path.join(ctl, "-".join(parts))


def wait_for(path, secs=40.0):
    end = time.monotonic() + secs
    while time.monotonic() < end:
        if os.path.exists(path):
            return True
        time.sleep(0.02)
    return False


def touch(path):
    with open(path, "w", encoding="utf-8") as f:
        f.write("1")


def result(name, rnd):
    try:
        with open(flag("result", name, rnd), encoding="utf-8") as f:
            return json.load(f)
    except (OSError, ValueError):
        return None


T.check(wait_for(flag("ready", "a")) and wait_for(flag("ready", "b")), "E0. both processes are up and past their baseline tick")
touch(flag("go1"))
T.check(wait_for(flag("done1", "a")) and wait_for(flag("done1", "b")), "E1. both processes saw the same approval and finished their step")
T.eq(len(fake.messages()), 1, "E2. two processes, one repo, one approval: Expo receives exactly ONE message")
ra, rb = result("a", "1"), result("b", "1")
owners = [n for n, r in (("a", ra), ("b", rb)) if r]
T.eq(len(owners), 1, "E3. exactly one of the two processes logged the push (the owner of the lock)")
if len(owners) == 1:
    owner = owners[0]
    other = "b" if owner == "a" else "a"
    touch(flag("exit", owner))
    try:
        rc = procs[owner].wait(timeout=30)
    except subprocess.TimeoutExpired:
        rc = None
    T.eq(rc, 0, "E4. the owner process exits cleanly")
    touch(flag("go2"))
    T.check(wait_for(flag("done2", other)), "E5. the surviving process handled the next event")
    T.eq(len(fake.messages()), 2, "E6. with the owner gone the survivor takes over and sends the next event: exactly one more message")
    r2 = result(other, "2")
    T.check(bool(r2) and r2[0]["ok"] is True and r2[0]["kind"] == "question", "E7. the survivor's log shows that question as sent", r2)
    T.eq(procs[other].wait(timeout=30), 0, "E8. the survivor exits cleanly")
else:
    for p in procs.values():
        p.kill()
written = sorted(os.path.relpath(os.path.join(d, f), root) for d, _, fs in os.walk(root) for f in fs)
T.eq(written, [".heimdall/app/push-sender.lock"], "E9. the only file the sender creates in the repo is its lock")
fake.close()
print("done")
PYEOF
run_part E "$TMPROOT/part_e.py"

# ── F. the sender against the production store ───────────────────────────────────────────
# Parts C-E feed the sender through a test double. This part registers devices with the real
# bin/lib/companion_push_store.py -- what the phone's register_push writes through -- and lets
# PushMonitor load that module itself, as hmd-ui does, so the seam between the two halves (the entry
# shape, the ISO timestamps, remove_tokens) is checked against the code on the other side of it.
cat >"$TMPROOT/part_f.py" <<'PYEOF'
import calendar
import os
import stat
import sys
import time

code, tmp = sys.argv[1], sys.argv[2]
os.makedirs(tmp, exist_ok=True)
sys.path.insert(0, os.path.join(code, "test", "lib"))
import push_test_lib as T

CP = T.load("companion_push", os.path.join(code, "bin", "lib", "companion_push.py"))
STORE = T.load("companion_push_store", os.path.join(code, "bin", "lib", "companion_push_store.py"))
A, S, att = T.a_id, T.state, T.attention
TOK, TOK2, REF = T.expo_token("t"), T.expo_token("u"), T.session_ref()
YESNO = [{"key": "yes", "label": "Yes"}, {"key": "no", "label": "No"}]
_n = [0]


class RealRig:
    """One monitor over a repo whose registrations the production store wrote. The monitor loads that store
    module itself (no store= given), exactly as sentinels/hmd-ui.py builds it. The test drives step(now)."""

    def __init__(self):
        _n[0] += 1
        self.root = os.path.join(tmp, "repo%d" % _n[0])
        self.fake = T.FakeExpo()
        self.events = []
        self.m = CP.PushMonitor(self.root, emit=self.events.append, config={"min_run_s": 0, "timeout_s": 3.0},
                                sleep=lambda seconds: None, environ={"HMD_PUSH_EXPO_URL": self.fake.url},
                                start_thread=False)

    def question_at(self, at):
        """A question appears 2 s after `at` on the sender's clock, and its coalescing window is stepped out."""
        self.m.observe(S(att("working", A(1))), at)
        self.m.observe(S(att("needs_input", A(2), "question", "Delete the old branch?", YESNO)), at + 2)
        self.m.step(at + 2)
        self.m.step(at + 8)

    def pushes(self):
        return [e for e in self.events if e.get("event") == "push"]

    def close(self):
        self.m.close()
        self.fake.close()


def stamped(root):
    """When the production store stamped the app state, as epoch seconds -- read back from what it wrote."""
    return calendar.timegm(time.strptime(STORE.load(root)["app_state_at"], "%Y-%m-%dT%H:%M:%SZ"))


# ── F1. a registration made through the production store is what gets the push ──
rig = RealRig()
STORE.register(rig.root, TOK, "ios", ref=REF, label="api server", events=["question", "finished"])
rig.question_at(1000.0)
msgs = rig.fake.messages()
T.eq(len(msgs), 1, "F1a. a device registered through the production store receives the question")
if msgs:
    T.eq((msgs[0]["to"], msgs[0]["title"], msgs[0]["data"]["ref"]), (TOK, "api server · hmd asks", REF),
         "F1b. addressed to the registered token, titled with its registered label, carrying its registered ref")
rig.close()

# ── F2. the kinds the phone asked for are honoured ──
rig = RealRig()
STORE.register(rig.root, TOK, "ios", events=["error"])
rig.question_at(1000.0)
T.eq(len(rig.fake.messages()), 0, "F2a. a device registered for errors only is sent no question")
T.eq([(e["kind"], e["ok"], e["suppressed"]) for e in rig.pushes()], [("question", False, "disabled-kind")],
     "F2b. the question is logged as a disabled kind")
rig.close()

# ── F3. foreground suppression reads the timestamp the production store stamped ──
for name, state, age, suppressed in (("fresh foreground", "foreground", 10, True),
                                     ("foreground exactly 900 s old", "foreground", 900, True),
                                     ("foreground 901 s old counts as unknown", "foreground", 901, False),
                                     ("background", "background", 5, False)):
    rig = RealRig()
    STORE.register(rig.root, TOK, "ios")
    STORE.set_app_state(rig.root, state)
    rig.question_at(stamped(rig.root) + age - 2)
    T.eq(len(rig.fake.messages()), 0 if suppressed else 1, "F3a. %s -> %s" % (name, "suppressed" if suppressed else "sent"))
    if suppressed:
        T.eq([(e["kind"], e["ok"], e["suppressed"]) for e in rig.pushes()], [("question", False, "foreground")],
             "F3b. %s: logged as suppressed foreground, never sent" % name)
    rig.close()

# ── F4. DeviceNotRegistered is pruned through the production store ──
rig = RealRig()
STORE.register(rig.root, TOK, "ios", ref=REF)
STORE.register(rig.root, TOK2, "android")
rig.fake.unregistered.add(TOK)
rig.question_at(1000.0)
T.eq([e["token"] for e in STORE.load(rig.root)["tokens"]], [TOK2],
     "F4a. the dead token is gone from push.json and the live one stays")
T.eq(stat.S_IMODE(os.stat(os.path.join(rig.root, STORE.PUSH_REL)).st_mode), 0o600,
     "F4b. the rewritten push.json is still 0600")
rig.close()

# ── F5. the sender only writes the store to drop a dead token ──
rig = RealRig()
STORE.register(rig.root, TOK, "ios", ref=REF, label="api server")
path = os.path.join(rig.root, STORE.PUSH_REL)
with open(path, "rb") as f:
    before = f.read()
rig.question_at(1000.0)
with open(path, "rb") as f:
    after = f.read()
T.eq((len(rig.fake.messages()), after == before), (1, True), "F5. a send that prunes nothing leaves push.json exactly as the store wrote it")
rig.close()
print("done")
PYEOF
run_part F "$TMPROOT/part_f.py"

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
