#!/usr/bin/env bash
# test/heimdall-phone-deny.test.sh
#
# Oracle for A4, DENY-ONLY round (docs/HANDOFF-TO-HEIMDALL-product-asks.md item A4; the operator
# decision: the phone can DENY or STOP a pending risky action, it can never approve one):
#
#   bin/lib/companion_ui_decisions.py   the decision store: pending requests, single-use deny
#                                       decisions, the phone `stop` request, the armed heartbeat
#   bin/lib/phone_deny_risk.py          what counts as a risky action, and its one-line summary
#   bin/heimdall-phone-deny             the PreToolUse hook: OFF unless HMD_PHONE_DENY=1
#   hooks/hooks.json + .metadata.json   the `phone-deny` group and its kill switch
#   sentinels/hmd-ui.py                 the `approvals` slice of /api/state
#
# The relay half (the sealed `decide` / `stop` commands) is test/heimdall-phone-deny-relay.test.sh.
#
# Design rule under test, head-on: a phone only ever REDUCES what runs. The hook's whole output
# vocabulary is {nothing, deny, deny + continue:false}; "allow" is not in it. No reply, a timeout,
# a malformed record, any internal error -> the hook prints nothing and exits 0 (Claude Code's
# normal permission flow is untouched).
#
# Hermetic: HOME / HEIMDALL_HOME / TMPDIR are a temp dir, every repo is a temp dir, every
# background process is reaped on EXIT. No `timeout(1)` on macOS: every wait is a bounded poll.

set -u

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$REPO/bin/lib/companion_ui_decisions.py"
RISK="$REPO/bin/lib/phone_deny_risk.py"
HOOK="$REPO/bin/heimdall-phone-deny"
HOOKS_JSON="$REPO/hooks/hooks.json"
HOOKS_META="$REPO/hooks/hooks.metadata.json"
HOOKS_TOOL="$REPO/bin/heimdall-hooks"
UI_PY="$REPO/sentinels/hmd-ui.py"

PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; }

echo "heimdall-phone-deny (A4 deny-only: the phone can deny or stop, never approve)"

for tool in python3 jq; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    printf '  FAIL required tool missing: %s\n' "$tool"
    printf '\n0 passed, 1 failed\n'
    exit 1
  fi
done

TMPROOT="$(mktemp -d)"
export TMPDIR="$TMPROOT"
export HOME="$TMPROOT/home"
export HEIMDALL_HOME="$TMPROOT/home/.heimdall"
mkdir -p "$HOME/.claude"
unset HMD_PHONE_DENY HMD_PHONE_DENY_WINDOW_S HMD_JUDGMENT HMD_AGENT_TYPE CLAUDE_CODE_ENTRYPOINT \
      CLAUDE_PLUGIN_ROOT CLAUDE_PROJECT_DIR CLAUDE_SESSION_ID SESSION_ID CLAUDE_CODE_SESSION_ID

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

# py_checks <python-args...>: the python source arrives on stdin and prints one `PASS name` or
# `FAIL name :: detail` line per check (anything else is shown as context). A traceback -- which is
# what a missing module under test produces before it exists -- is a failure of the block itself.
py_checks() {
  local out rc line
  out="$(python3 - "$@" 2>&1)"
  rc=$?
  while IFS= read -r line; do
    case "$line" in
      "PASS "*) ok "${line#PASS }" ;;
      "FAIL "*) bad "${line#FAIL }" ;;
      "") ;;
      *) printf '       | %s\n' "$line" ;;
    esac
  done <<<"$out"
  [ "$rc" -eq 0 ] || bad "python check block exited $rc"
}

# ══ A. the decision store ═══════════════════════════════════════════════════════════════════
py_checks "$REPO" <<'PYEOF'
import importlib.util, json, os, re, stat, sys, tempfile, threading, time

REPO = sys.argv[1]
spec = importlib.util.spec_from_file_location("dec", os.path.join(REPO, "bin", "lib", "companion_ui_decisions.py"))
D = importlib.util.module_from_spec(spec)
spec.loader.exec_module(D)


def check(name, cond, detail=""):
    print(("PASS %s" % name) if cond else ("FAIL %s :: %s" % (name, detail)))


def newroot():
    return tempfile.mkdtemp(prefix="dec-")


def adir(root):
    return os.path.join(root, ".heimdall", "ui", "approvals")


def mode(path):
    return stat.S_IMODE(os.stat(path).st_mode)


def decide_code(root, rid, decision, now=None):
    try:
        D.decide(root, rid, decision, now=now)
    except D.DecisionError as e:
        return e.code
    return "OK"


KEYS = {"id", "tool", "summary", "requested_at", "expires_at", "risk"}
ID_RE = re.compile(r"^p-[0-9a-f]{8}$")
T0 = 1_800_000_000.0

# A1 -- the record
root = newroot()
rec = D.request(root, "Bash", "git push origin main", 10, now=T0)
check("A1. request() -> the doc's six keys, id p-<8 hex>, risk high, expires = requested + window",
      set(rec) == KEYS and ID_RE.match(rec["id"]) and rec["risk"] == "high" and rec["tool"] == "Bash"
      and rec["summary"] == "git push origin main" and rec["requested_at"] == T0 and rec["expires_at"] == T0 + 10, rec)
check("A1b. the approvals dir is 0700 and the request file 0600",
      mode(adir(root)) == 0o700 and mode(os.path.join(adir(root), rec["id"] + ".json")) == 0o600,
      (oct(mode(adir(root))), oct(mode(os.path.join(adir(root), rec["id"] + ".json")))))
check("A1c. two requests never share an id", D.request(root, "Bash", "x", 10, now=T0)["id"] != rec["id"])

# A2 -- exposure: exactly the doc's keys, nothing else
root = newroot()
D.request(root, "Bash", "rm -rf build", 10, now=T0)
p = D.pending(root, now=T0 + 1)
check("A2. pending() entries carry exactly {id, tool, summary, requested_at, expires_at, risk}",
      len(p) == 1 and set(p[0]) == KEYS, p)
check("A2b. no pid / path / raw input leaks into the exposed record",
      "pid" not in json.dumps(p) and "tool_input" not in json.dumps(p))

# A3 -- at most 5 listed, oldest first
root = newroot()
for i in range(7):
    D.request(root, "Bash", "cmd %d" % i, 30, now=T0 + i * 0.1)
p = D.pending(root, now=T0 + 1)
check("A3. pending() lists at most 5, oldest first",
      [e["summary"] for e in p] == ["cmd 0", "cmd 1", "cmd 2", "cmd 3", "cmd 4"], p)

# A4 -- the summary scrub
root = newroot()
secret = "ghp_" + "a1B2c3D4e5" * 3 + "a1B2c3"
rec = D.request(root, "Bash", "curl -H 'Authorization: token %s' https://x" % secret, 10, now=T0)
check("A4. a secret-shaped summary -> summary null, the request itself survives",
      rec["summary"] is None and D.pending(root, now=T0 + 1)[0]["summary"] is None, rec)
check("A4b. the secret never reaches disk", secret not in open(os.path.join(adir(root), rec["id"] + ".json")).read())
rec = D.request(root, "Bash", "echo one\n\ttwo\x1b[31m  three\x00", 10, now=T0)
check("A4c. control bytes and newlines flatten to single spaces", rec["summary"] == "echo one two [31m three", rec["summary"])
rec = D.request(root, "Bash", "x" * 500, 10, now=T0)
check("A4d. a long summary is cut to exactly 200 chars with an ellipsis",
      len(rec["summary"]) == 200 and rec["summary"].endswith("…"), len(rec["summary"]))
rec = D.request(root, "Bash;rm -rf /\n", "x", 10, now=T0)
check("A4e. the tool label is sanitised to [A-Za-z0-9_.:-]", rec["tool"] == "Bashrm-rf", rec["tool"])

# A5 -- deny is recorded, single-use
root = newroot()
rec = D.request(root, "Bash", "npm publish", 10, now=T0)
res = D.decide(root, rec["id"], "deny", now=T0 + 1)
dpath = os.path.join(adir(root), rec["id"] + ".decision")
check("A5. decide(deny) -> {id, decision: deny} and a 0600 decision file",
      res == {"id": rec["id"], "decision": "deny"} and os.path.isfile(dpath) and mode(dpath) == 0o600, res)
check("A5b. the hook-side read sees the deny; a decided request leaves pending()",
      D.decision_of(root, rec["id"]) == "deny" and D.pending(root, now=T0 + 1) == [])
check("A5c. a replayed decision -> already-decided, the first decision untouched",
      decide_code(root, rec["id"], "deny", now=T0 + 2) == "already-decided"
      and json.load(open(dpath))["decided_at"] == T0 + 1)

# A6 -- approve is not supported in this round, and writes nothing
root = newroot()
rec = D.request(root, "Bash", "git push", 10, now=T0)
check("A6. decide(allow) on a live request -> allow-not-permitted",
      decide_code(root, rec["id"], "allow", now=T0 + 1) == "allow-not-permitted")
check("A6b. ...and writes no decision, the request stays pending",
      not os.path.exists(os.path.join(adir(root), rec["id"] + ".decision"))
      and [e["id"] for e in D.pending(root, now=T0 + 1)] == [rec["id"]])
check("A6c. allow on an unknown id -> unknown-id (existence is checked before policy)",
      decide_code(root, "p-00000000", "allow", now=T0) == "unknown-id")

# A7 -- malformed input is refused, writes nothing
root = newroot()
rec = D.request(root, "Bash", "git push", 10, now=T0)
codes = {repr(v): decide_code(root, rec["id"], v, now=T0 + 1) for v in ("maybe", "", "DENY", 5, None, ["deny"], {"a": 1})}
check("A7. an unknown / non-string decision -> bad-decision",
      set(codes.values()) == {"bad-decision"}, codes)
bad_ids = ["../x", "p-zzzzzzzz", "p-1234", "p-123456789", "", None, 12, ["p-00000000"], "P-00000000", "p-00000000/../x"]
codes = {repr(v): decide_code(root, v, "deny", now=T0 + 1) for v in bad_ids}
check("A7b. a malformed id -> unknown-id, never a path walk", set(codes.values()) == {"unknown-id"}, codes)
check("A7c. none of that wrote a decision file",
      sorted(os.listdir(adir(root))) == [rec["id"] + ".json"], sorted(os.listdir(adir(root))))

# A8 -- expiry and liveness
root = newroot()
rec = D.request(root, "Bash", "git push", 10, now=T0)
check("A8. past expires_at -> expired, no decision written",
      decide_code(root, rec["id"], "deny", now=T0 + 10) == "expired"
      and not os.path.exists(os.path.join(adir(root), rec["id"] + ".decision")))
root = newroot()
rec = D.request(root, "Bash", "git push", 100, now=T0)
check("A8b. a request whose hook stopped heartbeating (stale) -> expired",
      decide_code(root, rec["id"], "deny", now=T0 + D.HEARTBEAT_STALE_S + 1) == "expired")
D.heartbeat(root, rec["id"], now=T0 + 20)
check("A8c. a heartbeat keeps it alive", decide_code(root, rec["id"], "deny", now=T0 + 21) == "OK")

# A9 -- pending() hides everything that is not a live, undecided request
root = newroot()
live = D.request(root, "Bash", "live", 100, now=T0 + 50)
D.request(root, "Bash", "expired", 5, now=T0)
stale = D.request(root, "Bash", "stale", 100, now=T0)
decided = D.request(root, "Bash", "decided", 100, now=T0 + 50)
D.decide(root, decided["id"], "deny", now=T0 + 51)
p = D.pending(root, now=T0 + 52)
check("A9. pending() = only the live, undecided request", [e["summary"] for e in p] == ["live"], p)

# A10 -- replay after the hook closed its request
root = newroot()
rec = D.request(root, "Bash", "git push", 10, now=T0)
D.decide(root, rec["id"], "deny", now=T0 + 1)
D.close(root, rec["id"])
check("A10. a closed + decided request still answers already-decided (the doc's 409)",
      decide_code(root, rec["id"], "deny", now=T0 + 2) == "already-decided")
rec2 = D.request(root, "Bash", "ls", 10, now=T0)
D.close(root, rec2["id"])
check("A10b. a closed undecided request -> unknown-id (the doc's 404)",
      decide_code(root, rec2["id"], "deny", now=T0 + 2) == "unknown-id")
check("A10c. close() twice is not an error", D.close(root, rec2["id"]) is None)

# A11 -- single use under contention
root = newroot()
rec = D.request(root, "Bash", "git push", 100, now=time.time())
results = []
gate = threading.Barrier(8)


def racer():
    gate.wait()
    results.append(decide_code(root, rec["id"], "deny"))


threads = [threading.Thread(target=racer) for _ in range(8)]
[t.start() for t in threads]
[t.join() for t in threads]
check("A11. 8 concurrent denies -> exactly one OK, the rest already-decided",
      results.count("OK") == 1 and results.count("already-decided") == 7, results)

# A12 -- the hook-side read trusts only a well-formed deny for ITS id
root = newroot()
rec = D.request(root, "Bash", "git push", 10, now=T0)
dpath = os.path.join(adir(root), rec["id"] + ".decision")
bad_files = {
    "garbage": "not json",
    "empty": "",
    "allow": json.dumps({"id": rec["id"], "decision": "allow", "decided_at": T0}),
    "other id": json.dumps({"id": "p-00000000", "decision": "deny", "decided_at": T0}),
    "list": "[1]",
    "no decision": json.dumps({"id": rec["id"]}),
}
seen = {}
for label, body in bad_files.items():
    with open(dpath, "w") as f:
        f.write(body)
    seen[label] = D.decision_of(root, rec["id"])
check("A12. a malformed / allow / foreign-id decision file is read as NO decision",
      set(seen.values()) == {None}, seen)
check("A12b. decision_of on an id that is not shaped like one -> None, no exception",
      D.decision_of(root, "../../etc/passwd") is None and D.decision_of(root, None) is None)

# A13 -- the stop request
root = newroot()
check("A13. no stop request -> apply_stop is None", D.apply_stop(root, now=T0) is None)
stop = D.request_stop(root, now=T0)
check("A13b. request_stop -> {id: s-<8 hex>, requested_at, expires_at = requested + STOP_TTL_S}",
      re.match(r"^s-[0-9a-f]{8}$", stop["id"]) and stop["expires_at"] == T0 + D.STOP_TTL_S, stop)
check("A13c. the marker is 0600", mode(os.path.join(adir(root), "stop.json")) == 0o600)
check("A13d. first apply returns it; a sibling inside the grace window still gets it",
      D.apply_stop(root, now=T0 + 3)["id"] == stop["id"] and D.apply_stop(root, now=T0 + 3 + D.STOP_GRACE_S - 0.1) is not None)
check("A13e. after the grace window a stop is spent: None, and the marker is removed",
      D.apply_stop(root, now=T0 + 3 + D.STOP_GRACE_S + 1) is None and not os.path.exists(os.path.join(adir(root), "stop.json")))
root = newroot()
D.request_stop(root, now=T0)
check("A13f. a stop nobody applied expires after STOP_TTL_S", D.apply_stop(root, now=T0 + D.STOP_TTL_S + 1) is None)
root = newroot()
os.makedirs(adir(root))
with open(os.path.join(adir(root), "stop.json"), "w") as f:
    f.write("{not json")
check("A13g. a corrupt stop marker is no stop", D.apply_stop(root, now=T0) is None)

# A14 -- the armed heartbeat
root = newroot()
check("A14. never armed -> armed() False", D.armed(root, now=T0) is False)
D.mark_armed(root, now=T0)
check("A14b. mark_armed -> armed() True inside ARMED_FRESH_S, False after",
      D.armed(root, now=T0 + D.ARMED_FRESH_S - 1) is True and D.armed(root, now=T0 + D.ARMED_FRESH_S + 1) is False)

# A15 -- housekeeping and permissions
root = newroot()
old = D.request(root, "Bash", "old", 10, now=T0)
D.decide(root, old["id"], "deny", now=T0 + 1)
D.request(root, "Bash", "fresh", 10, now=T0 + D.GC_AFTER_S + 100)
left = sorted(os.listdir(adir(root)))
check("A15. request() sweeps request/decision files older than GC_AFTER_S and keeps the new one",
      not any(n.startswith(old["id"]) for n in left) and len(left) == 1, left)
root = newroot()
os.makedirs(adir(root), mode=0o755)
os.chmod(adir(root), 0o755)
D.request(root, "Bash", "x", 10, now=T0)
check("A15b. a pre-existing 0755 approvals dir self-heals to 0700", mode(adir(root)) == 0o700, oct(mode(adir(root))))
PYEOF

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
