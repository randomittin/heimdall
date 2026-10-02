#!/usr/bin/env bash
# test/heimdall-phone-deny.test.sh
#
# Oracle for A4, DENY-ONLY round (docs/HANDOFF-TO-HEIMDALL-product-asks.md item A4; the operator
# decision: the phone can DENY a pending risky action, it can never approve one):
#
#   bin/lib/companion_ui_decisions.py   the decision store: pending requests, single-use deny
#                                       decisions, settle() -- the hook's window ends, and a deny
#                                       is honoured or refused, never both
#   bin/lib/phone_deny_risk.py          what counts as a risky action, and its one-line summary
#   bin/heimdall-phone-deny             the PreToolUse hook: OFF unless HMD_PHONE_DENY=1
#   hooks/hooks.json + .metadata.json   the `phone-deny` group and its kill switch
#   sentinels/hmd-ui.py                 the `approvals` slice of /api/state
#
# The relay half (the sealed `decide` command) is test/heimdall-phone-deny-relay.test.sh.
#
# Design rule under test, head-on: a phone only ever REDUCES what runs. It has exactly two verbs on
# a pending request -- `deny` (refuse this call) and `stop` (refuse it AND end the turn, the hook's
# {"continue": false}) -- and the hook's whole output vocabulary is {nothing, deny, deny + stop};
# "allow" is not in it. No reply, a timeout, a malformed record, any internal error -> the hook
# prints nothing and exits 0 (Claude Code's normal permission flow is untouched).
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

echo "heimdall-phone-deny (A4 deny-only: the phone can deny a risky action, never approve one)"

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

# A13 -- housekeeping and permissions
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

# A16 -- settle(): the hook's window is over. A deny on record is honoured; otherwise the slot is
# claimed so that no deny can land afterwards -- an ack for a deny that did nothing is a lie.
root = newroot()
rec = D.request(root, "Bash", "git push", 10, now=T0)
mpath = os.path.join(adir(root), rec["id"] + ".decision")
check("A16. settle() with no deny on record -> None, and the slot is claimed by a 0600 timeout marker",
      D.settle(root, rec["id"], now=T0 + 10) is None and json.load(open(mpath))["decision"] == "timeout"
      and mode(mpath) == 0o600, os.listdir(adir(root)))
check("A16b. ...so a late deny is `expired`, writes nothing, and the marker stays a timeout",
      decide_code(root, rec["id"], "deny", now=T0 + 10.5) == "expired" and json.load(open(mpath))["decision"] == "timeout")
check("A16c. a timeout marker is no deny: decision_of() -> None, and the request left pending()",
      D.decision_of(root, rec["id"]) is None and D.pending(root, now=T0 + 1) == [])
check("A16d. allow on a settled request is still `allow-not-permitted` (policy before state, as in A6)",
      decide_code(root, rec["id"], "allow", now=T0 + 11) == "allow-not-permitted")
check("A16e. settle() twice -> None both times, no exception, the first marker kept",
      D.settle(root, rec["id"], now=T0 + 12) is None and json.load(open(mpath))["decided_at"] == T0 + 10)
root = newroot()
rec = D.request(root, "Bash", "git push", 10, now=T0)
D.decide(root, rec["id"], "deny", now=T0 + 1)
dpath = os.path.join(adir(root), rec["id"] + ".decision")
before = open(dpath).read()
check("A16f. settle() when the deny is on record -> 'deny', and the record is untouched",
      D.settle(root, rec["id"], now=T0 + 9) == "deny" and open(dpath).read() == before)
root = newroot()
check("A16g. settle() on a malformed id, or with no approvals dir at all -> None, no exception, no file",
      D.settle(root, "../x") is None and D.settle(root, None) is None and D.settle(root, "p-00000000") is None
      and not os.path.exists(adir(root)))
root = newroot()
rec = D.request(root, "Bash", "git push", 10, now=T0)
with open(os.path.join(adir(root), rec["id"] + ".decision"), "w") as f:
    f.write("garbage")
check("A16h. settle() over a garbage decision file -> None (never a deny) and leaves the file alone",
      D.settle(root, rec["id"], now=T0 + 5) is None
      and open(os.path.join(adir(root), rec["id"] + ".decision")).read() == "garbage")

# A17 -- no stray temp files, and records are never visible half-written
root = newroot()
rec = D.request(root, "Bash", "git push", 10, now=T0)
D.decide(root, rec["id"], "deny", now=T0 + 1)
D.close(root, rec["id"])
check("A17. request + decide + close leave only the .decision file (no .tmp-* leftovers)",
      sorted(os.listdir(adir(root))) == [rec["id"] + ".decision"], sorted(os.listdir(adir(root))))
root = newroot()
rec = D.request(root, "Bash", "git push", 10, now=T0)
D.settle(root, rec["id"], now=T0 + 10)
check("A17b. request + settle leave exactly the request and the marker",
      sorted(os.listdir(adir(root))) == sorted([rec["id"] + ".json", rec["id"] + ".decision"]), sorted(os.listdir(adir(root))))

# A18 -- the linearization point: a phone deny and the hook's settle race. Exactly one side wins
# and the ack is truthful: decide() answers OK exactly when settle() goes on to see the deny.
inconsistent = []
for _ in range(80):
    root = newroot()
    rec = D.request(root, "Bash", "git push", 100, now=time.time())
    gate = threading.Barrier(2)
    seen = {}

    def phone():
        gate.wait()
        seen["decide"] = decide_code(root, rec["id"], "deny")

    def hook():
        gate.wait()
        seen["settle"] = D.settle(root, rec["id"])

    threads = [threading.Thread(target=phone), threading.Thread(target=hook)]
    [t.start() for t in threads]
    [t.join() for t in threads]
    if not ((seen["decide"] == "OK" and seen["settle"] == "deny") or (seen["decide"] == "expired" and seen["settle"] is None)):
        inconsistent.append(seen)
check("A18. 80 deny-vs-settle races: decide() is OK exactly when settle() sees the deny, else `expired`",
      not inconsistent, inconsistent[:3])

# A19 -- `stop`, the phone's second reduce-only verb: refuse this call AND end the turn. Same single
# decision slot as deny, same rules; only the verb differs.
root = newroot()
rec = D.request(root, "Bash", "git push", 10, now=T0)
spath = os.path.join(adir(root), rec["id"] + ".decision")
res = D.decide(root, rec["id"], "stop", now=T0 + 1)
check("A19. decide(stop) -> {id, decision: stop} and a 0600 decision file holding the stop",
      res == {"id": rec["id"], "decision": "stop"} and json.load(open(spath))["decision"] == "stop"
      and mode(spath) == 0o600, res)
check("A19b. the hook-side read sees the stop; a stopped request leaves pending()",
      D.decision_of(root, rec["id"]) == "stop" and D.pending(root, now=T0 + 1) == [])
check("A19c. the slot is single-use across both verbs: stop then deny, stop then stop -> already-decided",
      decide_code(root, rec["id"], "deny", now=T0 + 2) == "already-decided"
      and decide_code(root, rec["id"], "stop", now=T0 + 2) == "already-decided"
      and json.load(open(spath))["decision"] == "stop")
root = newroot()
rec = D.request(root, "Bash", "git push", 10, now=T0)
D.decide(root, rec["id"], "deny", now=T0 + 1)
check("A19d. deny then stop -> already-decided, the deny stays",
      decide_code(root, rec["id"], "stop", now=T0 + 2) == "already-decided" and D.decision_of(root, rec["id"]) == "deny")
root = newroot()
rec = D.request(root, "Bash", "git push", 10, now=T0)
D.decide(root, rec["id"], "stop", now=T0 + 1)
check("A19e. settle() with a stop on record hands the stop back", D.settle(root, rec["id"], now=T0 + 9) == "stop")
root = newroot()
rec = D.request(root, "Bash", "git push", 10, now=T0)
codes = {repr(v): decide_code(root, rec["id"], v, now=T0 + 1) for v in ("Stop", "STOP", " stop", "stop ", "halt", "approve", "approved", "cancel")}
check("A19f. the verbs are exact: Stop / STOP / padded / halt / approve / cancel -> bad-decision, nothing written",
      set(codes.values()) == {"bad-decision"} and not os.path.exists(os.path.join(adir(root), rec["id"] + ".decision")), codes)
check("A19g. allow stays refused for every request, stop being accepted changes nothing about it",
      decide_code(root, rec["id"], "allow", now=T0 + 1) == "allow-not-permitted")
root = newroot()
rec = D.request(root, "Bash", "git push", 10, now=T0)
dpath = os.path.join(adir(root), rec["id"] + ".decision")
seen = {}
for label, body in {
    "stop for another id": json.dumps({"id": "p-00000000", "decision": "stop", "decided_at": T0}),
    "Stop": json.dumps({"id": rec["id"], "decision": "Stop", "decided_at": T0}),
    "approve": json.dumps({"id": rec["id"], "decision": "approve", "decided_at": T0}),
    "stop in a list": json.dumps([{"id": rec["id"], "decision": "stop"}]),
}.items():
    with open(dpath, "w") as f:
        f.write(body)
    seen[label] = D.decision_of(root, rec["id"])
with open(dpath, "w") as f:
    f.write(json.dumps({"id": rec["id"], "decision": "stop", "decided_at": T0}))
check("A19h. only a well-formed stop for exactly this id reads as a stop; foreign / case-varied / approve / listed ones read as nothing",
      set(seen.values()) == {None} and D.decision_of(root, rec["id"]) == "stop", seen)

# A20 -- the linearization point holds for stop too
inconsistent = []
for _ in range(60):
    root = newroot()
    rec = D.request(root, "Bash", "git push", 100, now=time.time())
    gate = threading.Barrier(2)
    seen = {}

    def phone_stop():
        gate.wait()
        seen["decide"] = decide_code(root, rec["id"], "stop")

    def hook_settle():
        gate.wait()
        seen["settle"] = D.settle(root, rec["id"])

    threads = [threading.Thread(target=phone_stop), threading.Thread(target=hook_settle)]
    [t.start() for t in threads]
    [t.join() for t in threads]
    if not ((seen["decide"] == "OK" and seen["settle"] == "stop") or (seen["decide"] == "expired" and seen["settle"] is None)):
        inconsistent.append(seen)
check("A20. 60 stop-vs-settle races: decide() is OK exactly when settle() sees the stop, else `expired`",
      not inconsistent, inconsistent[:3])
PYEOF

# ══ B. what counts as risky ═════════════════════════════════════════════════════════════════
py_checks "$REPO" <<'PYEOF'
import importlib.util, os, sys, tempfile, time

REPO = sys.argv[1]
spec = importlib.util.spec_from_file_location("risk", os.path.join(REPO, "bin", "lib", "phone_deny_risk.py"))
R = importlib.util.module_from_spec(spec)
spec.loader.exec_module(R)


def check(name, cond, detail=""):
    print(("PASS %s" % name) if cond else ("FAIL %s :: %s" % (name, detail)))


ROOT, HOME, SCRATCH = "/work/proj", "/home/u", ("/scratch",)


def classify(tool, tool_input, cwd=None, root=ROOT, scratch=SCRATCH, home=HOME):
    return R.classify(tool, tool_input, root, cwd=cwd, scratch=scratch, home=home)


def why(tool, tool_input, cwd=None, **kw):
    got = classify(tool, tool_input, cwd, **kw)
    return None if got is None else got["why"]


def bash(cmd):
    return why("Bash", {"command": cmd})


# B1 -- each risky class, by representative: the doc's "write outside repo, network, delete, push,
# spend" plus privilege / system changes. Every row is (command, the class that must fire).
RISKY = [
    ("git push origin main", "push"), ("git push --force-with-lease", "push"), ("git -C /x push", "push"),
    ("git -c user.name=x push origin HEAD", "push"), ("git status && git push", "push"), ("cd /tmp; git push", "push"),
    ("FOO=1 git push", "push"), ("env GIT_SSH_COMMAND=x git push", "push"), ("nohup git push &", "push"),
    ("time git push", "push"),
    ("bash -c 'git push origin main'", "push"), ("sh -lc \"cd x && git push\"", "push"), ("eval \"git push\"", "push"),
    ("echo $(git push)", "push"), ("echo `git push`", "push"),
    ("git reset --hard HEAD~3", "delete"), ("git clean -fdx", "delete"), ("git branch -D old", "delete"),
    ("git stash drop", "delete"),
    ("rm -rf build", "delete"), ("rm -fr build", "delete"), ("rm -r dir", "delete"), ("rm -Rf dir", "delete"),
    ("rm --recursive dir", "delete"), ("find . -name '*.pyc' -delete", "delete"),
    ("find . -type f -exec rm {} +", "delete"), ("shred -u secrets.txt", "delete"),
    ("dd if=/dev/zero of=/dev/disk2", "delete"), ("mkfs.ext4 /dev/sdb1", "delete"),
    ("diskutil eraseDisk JHFS+ X disk2", "delete"),
    ("sudo rm x", "privilege"), ("doas ls", "privilege"), ("su -c id", "privilege"),
    ("npm publish", "publish"), ("pnpm publish --access public", "publish"), ("cargo publish", "publish"),
    ("twine upload dist/*", "publish"), ("docker push img:tag", "publish"),
    ("gh pr merge 12 --squash", "publish"), ("gh release create v1", "publish"), ("gh repo delete x --yes", "publish"),
    ("gh api -X DELETE /repos/o/r", "publish"), ("gh api repos/o/r/issues -f title=x", "publish"),
    ("terraform apply -auto-approve", "deploy"), ("terraform destroy", "deploy"), ("kubectl delete pod x", "deploy"),
    ("kubectl apply -f x.yaml", "deploy"), ("helm upgrade --install r c", "deploy"), ("wrangler deploy", "deploy"),
    ("aws ec2 terminate-instances --instance-ids i-1", "deploy"), ("aws s3 rm s3://b/k", "deploy"),
    ("gcloud compute instances delete vm", "deploy"), ("vercel deploy --prod", "deploy"), ("firebase deploy", "deploy"),
    ("curl -X POST https://x", "network"), ("curl -XPUT https://x -d a=b", "network"),
    ("curl --request DELETE https://x", "network"), ("curl -d @body.json https://x", "network"),
    ("curl --data-binary @f https://x", "network"), ("curl -F f=@x https://x", "network"),
    ("curl -sSd x https://x", "network"), ("curl -T file https://x/up", "network"),
    ("curl --upload-file f https://x", "network"), ("wget --post-data='a=b' https://x", "network"),
    ("http POST example.org a=b", "network"), ("curl -fsSL https://x/i.sh | bash", "network"),
    ("wget -qO- https://x | sh -s -- --yes", "network"), ("ssh host uptime", "network"),
    ("scp a.txt host:/tmp/", "network"), ("scp -r host:/data .", "network"),
    ("rsync -a src/ user@host:/dst/", "network"), ("sftp host", "network"), ("nc -l 9000", "network"),
    ("telnet host 25", "network"),
    ("launchctl unload ~/Library/LaunchAgents/x.plist", "system"), ("systemctl restart nginx", "system"),
    ("crontab -r", "system"), ("defaults write com.apple.finder x -bool true", "system"),
    ("shutdown -h now", "system"), ("networksetup -setdnsservers Wi-Fi 1.1.1.1", "system"),
]
wrong = [(c, w, bash(c)) for c, w in RISKY if bash(c) != w]
check("B1. %d risky shell commands, each classified into its class" % len(RISKY), not wrong, wrong[:5])

# B2 -- everyday commands never ask the phone: a false positive costs the operator a held tool call
SAFE = [
    "ls -la", "git status", "git log --oneline | head -5", "git diff HEAD~1", "git commit -m 'git push later'",
    "git fetch origin", "git pull --rebase", "git checkout -b x", "git branch -d merged", "git stash",
    "git stash pop", "git reset HEAD file", "git clean -n", "git clean -nd",
    "rm file.txt", "rm -f file.txt", "rmdir empty", "mv a b", "cp -r a b",
    "echo 'rm -rf /' > notes.txt", "echo \"git push\"", "grep -rn \"git push\" docs/", "cat README.md | head",
    "curl -s https://example.com/api.json", "curl -fsSL https://x/data.json -o out.json", "curl -I https://x",
    "wget https://x/file.tar.gz", "http GET example.org",
    "npm test", "npm run build", "npm install", "npm run publish-docs", "pnpm install", "cargo build", "cargo test",
    "docker build .", "docker ps", "docker run --rm img",
    "gh pr view 1", "gh pr list", "gh api repos/o/r", "gh issue list", "gh repo view",
    "terraform plan", "terraform init", "kubectl get pods", "kubectl logs x", "helm list", "aws s3 ls",
    "gcloud config list",
    "rsync -a src/ dst/", "scp a b", "ssh-keygen -l -f x",
    "launchctl list", "systemctl status x", "crontab -l", "defaults read com.apple.finder",
    "python3 -c 'print(1)'", "bash -c 'echo hi'", "sh script.sh", "make test", "pytest -q",
    "", "   ", "echo \"unterminated", "git push' broken quote",
]
false_pos = [(c, bash(c)) for c in SAFE if bash(c) is not None]
check("B2. %d everyday shell commands are not risky" % len(SAFE), not false_pos, false_pos[:5])

# B3 -- file tools: a write below the project root is routine; anywhere else is not
cases = [
    ("Write", {"file_path": "/work/proj/src/a.py"}, None),
    ("Write", {"file_path": "src/a.py"}, None),
    ("Edit", {"file_path": "/work/proj/README.md"}, None),
    ("Write", {"file_path": "/etc/hosts"}, "outside-repo"),
    ("Edit", {"file_path": "/home/u/.zshrc"}, "outside-repo"),
    ("Write", {"file_path": "/work/projX/x.py"}, "outside-repo"),
    ("Write", {"file_path": "/work/other/x.py"}, "outside-repo"),
    ("Write", {"file_path": "/work/proj/../other/x.py"}, "outside-repo"),
    ("Write", {"file_path": "src/../../../etc/x"}, "outside-repo"),
    ("MultiEdit", {"file_path": "/usr/local/bin/x"}, "outside-repo"),
    ("NotebookEdit", {"notebook_path": "/etc/x.ipynb"}, "outside-repo"),
    ("NotebookEdit", {"notebook_path": "/work/proj/nb.ipynb"}, None),
    ("Write", {"file_path": "/scratch/x.txt"}, None),
    ("Write", {"file_path": "/home/u/.claude/projects/p/memory/MEMORY.md"}, None),
    ("Write", {"file_path": "/home/u/.claude/settings.json"}, "outside-repo"),
]
wrong = [(t, i, w, why(t, i)) for t, i, w in cases if why(t, i) != w]
check("B3. file-tool writes: below the root / scratch / agent memory are routine, everything else outside-repo",
      not wrong, wrong[:5])
check("B3b. a relative path resolves against the hook's cwd: `x.py` in a subdir is fine, `../../x.py` is not",
      why("Write", {"file_path": "x.py"}, cwd="/work/proj/sub") is None
      and why("Write", {"file_path": "../../x.py"}, cwd="/work/proj/sub") == "outside-repo")

# B4 -- a symlink inside the repo that leads out of it does not launder a write
base = os.path.realpath(tempfile.mkdtemp(prefix="risk-"))
os.makedirs(os.path.join(base, "proj", "src"))
os.makedirs(os.path.join(base, "other"))
os.symlink(os.path.join(base, "other"), os.path.join(base, "proj", "link"))
got = why("Write", {"file_path": os.path.join(base, "proj", "link", "x.py")}, root=os.path.join(base, "proj"),
          scratch=("/nonexistent-scratch",))
inside = why("Write", {"file_path": os.path.join(base, "proj", "src", "x.py")}, root=os.path.join(base, "proj"),
             scratch=("/nonexistent-scratch",))
check("B4. a write through an in-repo symlink to a directory outside is outside-repo; a real in-repo path is not",
      got == "outside-repo" and inside is None, (got, inside))

# B5 -- the summary the phone shows
check("B5. a shell command's summary is the command; a file tool's is `<Tool> <path>`",
      classify("Bash", {"command": "git push origin main"})["summary"] == "git push origin main"
      and classify("Write", {"file_path": "/etc/hosts"})["summary"] == "Write /etc/hosts")

# B6 -- not a tool this gate covers, or not a shape it can read: never risky, never an exception
odd = [("Read", {"file_path": "/etc/hosts"}), ("Glob", {"pattern": "*"}), ("WebFetch", {"url": "https://x"}),
       ("Bash", None), ("Bash", []), ("Bash", {"command": None}), ("Bash", {"command": 5}), ("Bash", {}),
       ("Write", {"file_path": None}), ("Write", {"file_path": 7}), ("Write", {}), ("Write", "/etc/hosts"),
       (None, {"command": "git push"}), (5, {}), ("", {"command": "git push"}), ("mcp__x__y", {"command": "git push"})]
errors = []
for tool, tool_input in odd:
    try:
        got = classify(tool, tool_input)
    except Exception as e:                       # the hook must never be the thing that raises
        errors.append((tool, tool_input, repr(e)))
        continue
    if got is not None:
        errors.append((tool, tool_input, got))
check("B6. unknown tools and unreadable inputs -> None, never an exception", not errors, errors[:5])

# B7 -- bounded work: a pathological command cannot stall the hook
t0 = time.time()
big = ("echo " + "x" * 50 + " ; ") * 4000 + "git push"
got = why("Bash", {"command": big})
check("B7. a 200 KB command is analysed in well under a second (the tail past the cap is not looked at)",
      time.time() - t0 < 1.0 and got in (None, "push"), (time.time() - t0, got))
t0 = time.time()
got = why("Bash", {"command": "(" * 5000 + "git push" + ")" * 5000})
check("B7b. deep nesting does not blow the stack or the clock", time.time() - t0 < 1.0 and got in (None, "push"),
      (time.time() - t0, got))
PYEOF

# ══ C. the hook ═════════════════════════════════════════════════════════════════════════════
# A fixture repo whose companion looks connected: a relay-mode connect.json naming a live pid (this
# shell's -- the same-user, same-liveness test the inbox hook applies) and a relay.json saying a
# device is paired and the last frame reached it.
mk_repo() {
  local d
  d="$(mktemp -d "$TMPROOT/repo.XXXXXX")"
  mkdir -p "$d/.heimdall/app"
  printf '{"mode":"relay","pid_ui":%s,"pid_client":%s,"port":1,"relay":"http://127.0.0.1:1","started_at":"t"}' "$$" "$$" \
    > "$d/.heimdall/app/connect.json"
  printf '{"paired":true,"last_delivered":true,"pid":%s}' "$$" > "$d/.heimdall/app/relay.json"
  printf '%s' "$d"
}

bash_payload() { # <cwd> <command>
  jq -cn --arg c "$2" --arg d "$1" \
    '{hook_event_name:"PreToolUse",session_id:"sess-1",tool_use_id:"toolu_1",cwd:$d,tool_name:"Bash",tool_input:{command:$c}}'
}
file_payload() { # <cwd> <tool> <path>
  jq -cn --arg t "$2" --arg p "$3" --arg d "$1" \
    '{hook_event_name:"PreToolUse",session_id:"sess-1",tool_use_id:"toolu_2",cwd:$d,tool_name:$t,tool_input:{file_path:$p,content:"x"}}'
}

now_s() { python3 -c 'import time; print(time.time())'; }

# run_hook <repo> <payload-file> [VAR=val ...] -> HOOK_OUT / HOOK_ERR / HOOK_RC / HOOK_S (seconds)
HOOK_OUT=""; HOOK_ERR=""; HOOK_RC=""; HOOK_S=""
run_hook() {
  local repo="$1" payload="$2" t0 t1
  shift 2
  t0="$(now_s)"
  HOOK_OUT="$(env "$@" "$HOOK" --repo "$repo" < "$payload" 2>"$TMPROOT/hook.err")"
  HOOK_RC=$?
  t1="$(now_s)"
  HOOK_ERR="$(cat "$TMPROOT/hook.err")"
  HOOK_S="$(python3 -c "print(round($t1 - $t0, 2))")"
}
under() { python3 -c "import sys; sys.exit(0 if float('$1') < float('$2') else 1)"; }
atleast() { python3 -c "import sys; sys.exit(0 if float('$1') >= float('$2') else 1)"; }
no_approvals() { [ ! -d "$1/.heimdall/ui/approvals" ] || [ -z "$(ls -A "$1/.heimdall/ui/approvals" 2>/dev/null)" ]; }
approvals_json() { # <repo> -> D.pending() as JSON
  python3 - "$LIB" "$1" <<'PYEOF'
import importlib.util, json, sys
spec = importlib.util.spec_from_file_location("dec", sys.argv[1])
D = importlib.util.module_from_spec(spec)
spec.loader.exec_module(D)
print(json.dumps(D.pending(sys.argv[2])))
PYEOF
}
wait_pending() { # <repo> <secs> -> 0 once a request is listed
  local i=0 max=$(( $2 * 10 ))
  while [ "$i" -lt "$max" ]; do
    [ "$(approvals_json "$1")" != "[]" ] && return 0
    sleep 0.1; i=$((i + 1))
  done
  return 1
}

# phone_decide <repo> <delay-s> <deny|stop> [<summary-to-match>]: a background "phone". It waits for
# a pending request (optionally the one whose summary is <summary-to-match>), waits <delay-s> more,
# then decides it through the store -- exactly what the relay client's sealed `decide` handler does.
# What the store answered is logged to $TMPROOT/phone.log, so a refusal is never silent.
phone_decide() {
  python3 - "$LIB" "$1" "$2" "$3" "${4:-}" <<'PYEOF' >>"$TMPROOT/phone.log" 2>&1 &
import importlib.util, sys, time
spec = importlib.util.spec_from_file_location("dec", sys.argv[1])
D = importlib.util.module_from_spec(spec)
spec.loader.exec_module(D)
root, delay, verb, match = sys.argv[2], float(sys.argv[3]), sys.argv[4], sys.argv[5]
deadline = time.time() + 20
while time.time() < deadline:
    for e in D.pending(root):
        if not match or e["summary"] == match:
            time.sleep(delay)
            try:
                D.decide(root, e["id"], verb)
                outcome = "ok"
            except D.DecisionError as err:
                outcome = err.code
            print("phone: %s %s -> %s" % (verb, e["id"], outcome))
            sys.exit(0)
    time.sleep(0.05)
print("phone: no matching request appeared")
PYEOF
  PIDS+=("$!")
}
phone_deny() { phone_decide "$1" "$2" deny "${3:-}"; }
phone_stop() { phone_decide "$1" "$2" stop "${3:-}"; }

ARMED=(HMD_PHONE_DENY=1)

# C1 -- flag off => nothing at all
R1="$(mk_repo)"; bash_payload "$R1" "git push origin main" > "$TMPROOT/p.push"
run_hook "$R1" "$TMPROOT/p.push"
if [ "$HOOK_RC" = 0 ] && [ -z "$HOOK_OUT" ] && [ -z "$HOOK_ERR" ] && no_approvals "$R1" && under "$HOOK_S" 3; then
  ok "C1. HMD_PHONE_DENY unset -> exit 0, no output, no request, no delay (${HOOK_S}s)"
else
  bad "C1. flag-off hook did something: rc=$HOOK_RC out=[$HOOK_OUT] err=[$HOOK_ERR] ${HOOK_S}s"
fi
for v in 0 true yes on "" 2 " 1" "1 "; do
  run_hook "$R1" "$TMPROOT/p.push" "HMD_PHONE_DENY=$v"
  if [ "$HOOK_RC" = 0 ] && [ -z "$HOOK_OUT" ] && no_approvals "$R1" && under "$HOOK_S" 3; then
    ok "C1b. HMD_PHONE_DENY='$v' is not the opt-in (only exactly 1 arms the hook) -> no-op"
  else
    bad "C1b. HMD_PHONE_DENY='$v' armed the hook: rc=$HOOK_RC out=[$HOOK_OUT]"
  fi
done

# C2 -- armed, but no companion that can answer => nothing at all, and no waiting
check_noop() { # <label> <repo> <payload> [VAR=val ...]
  local label="$1" repo="$2" payload="$3"
  shift 3
  run_hook "$repo" "$payload" "${ARMED[@]}" "$@"
  if [ "$HOOK_RC" = 0 ] && [ -z "$HOOK_OUT" ] && no_approvals "$repo" && under "$HOOK_S" 3; then
    ok "$label (${HOOK_S}s)"
  else
    bad "$label -- rc=$HOOK_RC out=[$HOOK_OUT] err=[$HOOK_ERR] ${HOOK_S}s approvals=$(ls -A "$repo/.heimdall/ui/approvals" 2>/dev/null | tr '\n' ' ')"
  fi
}
R2="$(mk_repo)"; rm -f "$R2/.heimdall/app/connect.json"; bash_payload "$R2" "git push origin main" > "$TMPROOT/p.push2"
check_noop "C2. no connect.json (no companion) -> no-op" "$R2" "$TMPROOT/p.push2"
R2="$(mk_repo)"; printf '{"pid_ui":%s,"port":1,"https_port":1,"host":"h","started_at":"t"}' "$$" > "$R2/.heimdall/app/connect.json"
check_noop "C2b. a funnel-mode connect.json (no relay, so no sealed command path) -> no-op" "$R2" "$TMPROOT/p.push2"
R2="$(mk_repo)"; sh -c 'exit 0' & DEAD=$!; wait "$DEAD" 2>/dev/null
printf '{"mode":"relay","pid_ui":%s,"pid_client":%s,"port":1,"relay":"r","started_at":"t"}' "$$" "$DEAD" > "$R2/.heimdall/app/connect.json"
check_noop "C2c. relay mode whose relay client pid is dead (a crash left connect.json behind) -> no-op" "$R2" "$TMPROOT/p.push2"
R2="$(mk_repo)"; printf '{"mode":"relay","pid_ui":%s,"pid_client":"x","port":1,"relay":"r","started_at":"t"}' "$$" > "$R2/.heimdall/app/connect.json"
check_noop "C2d. a pid that is not an integer -> no-op" "$R2" "$TMPROOT/p.push2"
R2="$(mk_repo)"; printf 'not json' > "$R2/.heimdall/app/connect.json"
check_noop "C2e. an unparsable connect.json -> no-op" "$R2" "$TMPROOT/p.push2"
R2="$(mk_repo)"; printf '{"paired":false,"last_delivered":null}' > "$R2/.heimdall/app/relay.json"
check_noop "C2f. relay up but no device paired yet -> no-op" "$R2" "$TMPROOT/p.push2"
R2="$(mk_repo)"; printf '{"paired":true,"last_delivered":false}' > "$R2/.heimdall/app/relay.json"
check_noop "C2g. paired, but the relay reported no phone connected on the last frame -> no-op" "$R2" "$TMPROOT/p.push2"
R2="$(mk_repo)"; rm -f "$R2/.heimdall/app/relay.json"
check_noop "C2h. no relay status file -> no-op" "$R2" "$TMPROOT/p.push2"
R2="$(mk_repo)"; printf '{"paired":"yes","last_delivered":true}' > "$R2/.heimdall/app/relay.json"
check_noop "C2i. a relay status whose paired is not the boolean true -> no-op" "$R2" "$TMPROOT/p.push2"

# C3 -- unattended sessions never hold the phone line (hmd's own automation shares these hooks)
R3="$(mk_repo)"; bash_payload "$R3" "git push origin main" > "$TMPROOT/p.push3"
check_noop "C3. HMD_JUDGMENT=1 (an hmd judge sub-session) -> no-op" "$R3" "$TMPROOT/p.push3" HMD_JUDGMENT=1
check_noop "C3b. HMD_AGENT_TYPE=judge (a role-tagged sub-session) -> no-op" "$R3" "$TMPROOT/p.push3" HMD_AGENT_TYPE=judge
check_noop "C3c. CLAUDE_CODE_ENTRYPOINT=sdk-cli (headless claude -p) -> no-op" "$R3" "$TMPROOT/p.push3" CLAUDE_CODE_ENTRYPOINT=sdk-cli

# C4 -- armed and connected, but the action is not risky: nothing published, nothing held
R4="$(mk_repo)"
bash_payload "$R4" "ls -la" > "$TMPROOT/p.ls"
check_noop "C4. a harmless shell command -> no request, no delay" "$R4" "$TMPROOT/p.ls"
file_payload "$R4" Write "$R4/src/a.py" > "$TMPROOT/p.inrepo"
check_noop "C4b. a write inside the repo -> no request, no delay" "$R4" "$TMPROOT/p.inrepo"
jq -cn --arg d "$R4" '{hook_event_name:"PreToolUse",cwd:$d,tool_name:"Read",tool_input:{file_path:"/etc/hosts"}}' > "$TMPROOT/p.read"
check_noop "C4c. a tool the gate does not cover (Read) -> no request, no delay" "$R4" "$TMPROOT/p.read"

# C5 -- malformed hook input is ignored
R5="$(mk_repo)"
: > "$TMPROOT/p.empty"
printf 'not json at all' > "$TMPROOT/p.junk"
printf '[]' > "$TMPROOT/p.list"
printf '{"tool_name":5,"tool_input":"x"}' > "$TMPROOT/p.badtypes"
printf '{"tool_name":"Bash"}' > "$TMPROOT/p.noinput"
python3 -c 'import sys; sys.stdout.write("{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"" + "x" * 3000000 + "\"}}")' > "$TMPROOT/p.huge"
for f in empty junk list badtypes noinput huge; do
  check_noop "C5. hook input '$f' -> ignored (exit 0, no output, no request)" "$R5" "$TMPROOT/p.$f"
done

# C6 -- the window: parsed from HMD_PHONE_DENY_WINDOW_S, bounded both ways, junk -> the default
py_checks "$HOOK" <<'PYEOF'
import importlib.machinery, importlib.util, sys

loader = importlib.machinery.SourceFileLoader("phone_deny_hook", sys.argv[1])
spec = importlib.util.spec_from_loader("phone_deny_hook", loader)
H = importlib.util.module_from_spec(spec)
loader.exec_module(H)


def check(name, cond, detail=""):
    print(("PASS %s" % name) if cond else ("FAIL %s :: %s" % (name, detail)))


def window(v):
    return H.window_seconds({} if v is None else {"HMD_PHONE_DENY_WINDOW_S": v})


check("C6. the default window is 10 s (the operator's bound; the doc's 120 s is the ceiling, not the default)",
      window(None) == 10.0 and window("") == 10.0, (window(None), window("")))
check("C6b. a number in range is taken as is", window("3") == 3.0 and window("45.5") == 45.5 and window(" 7 ") == 7.0)
check("C6c. below 1 s is raised to 1 s; above 120 s is cut to 120 s",
      window("0.2") == 1.0 and window("0") == 1.0 and window("-5") == 1.0 and window("9999") == 120.0 and window("120") == 120.0)
check("C6d. junk, nan and inf fall back to the default, never to 0 or unbounded",
      all(window(v) == 10.0 for v in ("abc", "nan", "inf", "-inf", "1e999", "0x10", "3s")))
check("C6e. the module is import-safe: nothing ran at import, flag parsing is exact",
      H.armed({"HMD_PHONE_DENY": "1"}) is True
      and not any(H.armed({"HMD_PHONE_DENY": v}) for v in ("0", "true", "yes", "", " 1", "1 ", "2"))
      and H.armed({}) is False)
PYEOF

# C7 -- armed + connected + risky + nobody answers: the window runs out and the hook does NOTHING
R7="$(mk_repo)"; bash_payload "$R7" "git push origin main" > "$TMPROOT/p.push7"
run_hook "$R7" "$TMPROOT/p.push7" "${ARMED[@]}" HMD_PHONE_DENY_WINDOW_S=1
DEC7="$(ls "$R7/.heimdall/ui/approvals"/p-*.decision 2>/dev/null | head -1)"
if [ "$HOOK_RC" = 0 ] && [ -z "$HOOK_OUT" ] && [ -z "$HOOK_ERR" ] && atleast "$HOOK_S" 1 && under "$HOOK_S" 6; then
  ok "C7. no reply inside the window -> exit 0 with NO output (the normal permission flow is untouched); waited ${HOOK_S}s"
else
  bad "C7. timeout path wrong: rc=$HOOK_RC out=[$HOOK_OUT] err=[$HOOK_ERR] ${HOOK_S}s"
fi
if ! ls "$R7/.heimdall/ui/approvals"/p-*.json >/dev/null 2>&1 && [ -n "$DEC7" ] && jq -e '.decision == "timeout"' "$DEC7" >/dev/null 2>&1 \
   && [ "$(approvals_json "$R7")" = "[]" ]; then
  ok "C7b. on the way out the request is withdrawn and the slot is settled, so a late deny can only be 'expired'"
else
  bad "C7b. leftovers after the timeout: $(ls -A "$R7/.heimdall/ui/approvals" 2>/dev/null | tr '\n' ' ')"
fi

# C8 -- the phone denies inside the window: the hook blocks, promptly, with a reason
R8="$(mk_repo)"; bash_payload "$R8" "git push origin main" > "$TMPROOT/p.push8"
phone_deny "$R8" 0.3
run_hook "$R8" "$TMPROOT/p.push8" "${ARMED[@]}" HMD_PHONE_DENY_WINDOW_S=15
if [ "$HOOK_RC" = 0 ] && printf '%s' "$HOOK_OUT" | jq -e '
      (keys == ["hookSpecificOutput"]) and
      (.hookSpecificOutput | keys == ["hookEventName","permissionDecision","permissionDecisionReason"]) and
      .hookSpecificOutput.hookEventName == "PreToolUse" and
      .hookSpecificOutput.permissionDecision == "deny" and
      (.hookSpecificOutput.permissionDecisionReason | type == "string" and length > 20)' >/dev/null 2>&1; then
  ok "C8. a deny inside the window -> exactly one {hookSpecificOutput: PreToolUse deny + reason} object, exit 0"
else
  bad "C8. deny output wrong: rc=$HOOK_RC out=[$HOOK_OUT] err=[$HOOK_ERR] phone=[$(cat "$TMPROOT/phone.log" 2>/dev/null)]"
fi
if under "$HOOK_S" 8; then
  ok "C8b. the hook returned as soon as the deny landed (${HOOK_S}s of a 15s window)"
else
  bad "C8b. the hook sat on a decision it already had: ${HOOK_S}s"
fi
if [ "$(approvals_json "$R8")" = "[]" ] && ! ls "$R8/.heimdall/ui/approvals"/p-*.json >/dev/null 2>&1; then
  ok "C8c. the answered request is gone from the pending list"
else
  bad "C8c. the answered request is still listed"
fi

# C9 -- while it waits, the request is visible to the phone, live, in the doc's shape
R9="$(mk_repo)"; bash_payload "$R9" "git push origin main" > "$TMPROOT/p.push9"
( env "${ARMED[@]}" HMD_PHONE_DENY_WINDOW_S=6 "$HOOK" --repo "$R9" < "$TMPROOT/p.push9" >"$TMPROOT/c9.out" 2>"$TMPROOT/c9.err" ) &
C9_PID=$!; PIDS+=("$C9_PID")
if wait_pending "$R9" 8; then
  sleep 1.2   # longer than nothing, shorter than the heartbeat stale bound: it must still be listed
  SNAP="$(approvals_json "$R9")"
  if printf '%s' "$SNAP" | jq -e '
        length == 1 and (.[0] | keys == ["expires_at","id","requested_at","risk","summary","tool"]) and
        .[0].tool == "Bash" and .[0].summary == "git push origin main" and .[0].risk == "high" and
        (.[0].id | test("^p-[0-9a-f]{8}$")) and (.[0].expires_at - .[0].requested_at == 6)' >/dev/null 2>&1; then
    ok "C9. mid-wait the request is listed with the doc's six keys, risk high, window 6s, and still live 1s later"
  else
    bad "C9. mid-wait snapshot wrong: $SNAP"
  fi
else
  bad "C9. the hook never published a request"
fi
wait "$C9_PID" 2>/dev/null

# C10 -- a decision file that is not a well-formed deny for THIS request is not a deny: the hook
# never approves, never blocks on garbage
for kind in allow garbage foreign; do
  R10="$(mk_repo)"; bash_payload "$R10" "git push origin main" > "$TMPROOT/p.push10"
  ( env "${ARMED[@]}" HMD_PHONE_DENY_WINDOW_S=2 "$HOOK" --repo "$R10" < "$TMPROOT/p.push10" >"$TMPROOT/c10.out" 2>"$TMPROOT/c10.err" ) &
  C10_PID=$!; PIDS+=("$C10_PID")
  if wait_pending "$R10" 8; then
    RID="$(approvals_json "$R10" | jq -r '.[0].id')"
    case "$kind" in
      allow)   printf '{"id":"%s","decision":"allow","decided_at":1}' "$RID" > "$R10/.heimdall/ui/approvals/$RID.decision" ;;
      garbage) printf 'allow allow allow' > "$R10/.heimdall/ui/approvals/$RID.decision" ;;
      foreign) printf '{"id":"p-00000000","decision":"deny","decided_at":1}' > "$R10/.heimdall/ui/approvals/$RID.decision" ;;
    esac
  fi
  wait "$C10_PID" 2>/dev/null
  if [ ! -s "$TMPROOT/c10.out" ] && [ ! -s "$TMPROOT/c10.err" ]; then
    ok "C10. a planted '$kind' decision file is no deny -> the hook prints nothing (it never approves, never trips on garbage)"
  else
    bad "C10. a planted '$kind' decision changed the hook's output: out=[$(cat "$TMPROOT/c10.out")] err=[$(cat "$TMPROOT/c10.err")]"
  fi
done

# C11 -- two requests at once: a deny for one never touches the other
R11="$(mk_repo)"
bash_payload "$R11" "git push origin deny-me" > "$TMPROOT/p.a"
bash_payload "$R11" "git push origin keep-me" > "$TMPROOT/p.b"
( env "${ARMED[@]}" HMD_PHONE_DENY_WINDOW_S=4 "$HOOK" --repo "$R11" < "$TMPROOT/p.a" >"$TMPROOT/c11.a" 2>/dev/null ) &
C11A=$!; PIDS+=("$C11A")
( env "${ARMED[@]}" HMD_PHONE_DENY_WINDOW_S=4 "$HOOK" --repo "$R11" < "$TMPROOT/p.b" >"$TMPROOT/c11.b" 2>/dev/null ) &
C11B=$!; PIDS+=("$C11B")
phone_deny "$R11" 0.8 "git push origin deny-me"
wait "$C11A" 2>/dev/null; wait "$C11B" 2>/dev/null
if jq -e '.hookSpecificOutput.permissionDecision == "deny"' "$TMPROOT/c11.a" >/dev/null 2>&1 && [ ! -s "$TMPROOT/c11.b" ]; then
  ok "C11. the denied request's hook blocks; the other request's hook times out untouched (empty output)"
else
  bad "C11. cross-talk: a=[$(cat "$TMPROOT/c11.a")] b=[$(cat "$TMPROOT/c11.b")]"
fi

# C12 -- killed mid-wait (Esc, the harness's own timeout): the request is withdrawn, nothing is printed
R12="$(mk_repo)"; bash_payload "$R12" "git push origin main" > "$TMPROOT/p.push12"
env "${ARMED[@]}" HMD_PHONE_DENY_WINDOW_S=60 "$HOOK" --repo "$R12" < "$TMPROOT/p.push12" >"$TMPROOT/c12.out" 2>"$TMPROOT/c12.err" &
C12_PID=$!; PIDS+=("$C12_PID")
if wait_pending "$R12" 8; then
  kill -TERM "$C12_PID" 2>/dev/null
  wait "$C12_PID" 2>/dev/null
  if [ ! -s "$TMPROOT/c12.out" ] && ! ls "$R12/.heimdall/ui/approvals"/p-*.json >/dev/null 2>&1 && [ "$(approvals_json "$R12")" = "[]" ]; then
    ok "C12. SIGTERM mid-wait -> the request is withdrawn and nothing is printed"
  else
    bad "C12. leftovers after SIGTERM: out=[$(cat "$TMPROOT/c12.out")] files=$(ls -A "$R12/.heimdall/ui/approvals" | tr '\n' ' ')"
  fi
else
  bad "C12. the hook never published a request"
fi

# C13 -- orphaned (the shell that launched it died, as on Esc): stands down, nothing printed
R13="$(mk_repo)"; bash_payload "$R13" "git push origin main" > "$TMPROOT/p.push13"
rm -f "$TMPROOT/c13.pid"
env "${ARMED[@]}" HMD_PHONE_DENY_WINDOW_S=60 sh -c '"$0" --repo "$1" < "$2" > "$4" 2>/dev/null & echo $! > "$3"; sleep 1.5; exit 0' \
  "$HOOK" "$R13" "$TMPROOT/p.push13" "$TMPROOT/c13.pid" "$TMPROOT/c13.out"
C13_PID="$(cat "$TMPROOT/c13.pid" 2>/dev/null)"; PIDS+=("$C13_PID")
i=0; while kill -0 "$C13_PID" 2>/dev/null && [ "$i" -lt 60 ]; do sleep 0.1; i=$((i + 1)); done
if ! kill -0 "$C13_PID" 2>/dev/null && [ ! -s "$TMPROOT/c13.out" ] && [ "$(approvals_json "$R13")" = "[]" ] \
   && ! ls "$R13/.heimdall/ui/approvals"/p-*.json >/dev/null 2>&1; then
  ok "C13. once its launching shell is gone the hook stands down on its own (request withdrawn, nothing printed)"
else
  bad "C13. orphaned hook still alive or leaked: alive=$(kill -0 "$C13_PID" 2>/dev/null && echo yes || echo no) out=[$(cat "$TMPROOT/c13.out" 2>/dev/null)]"
fi

# C14 -- any internal failure -> the hook does nothing (never blocks on its own bug)
R14="$(mk_repo)"; printf 'a file where the ui dir should be' > "$R14/.heimdall/ui"
bash_payload "$R14" "git push origin main" > "$TMPROOT/p.push14"
run_hook "$R14" "$TMPROOT/p.push14" "${ARMED[@]}" HMD_PHONE_DENY_WINDOW_S=1
if [ "$HOOK_RC" = 0 ] && [ -z "$HOOK_OUT" ] && under "$HOOK_S" 4; then
  ok "C14. the request cannot even be written (.heimdall/ui is a file) -> exit 0, no output, no wait"
else
  bad "C14. internal-failure path wrong: rc=$HOOK_RC out=[$HOOK_OUT] err=[$HOOK_ERR] ${HOOK_S}s"
fi
R14="$(mk_repo)"; bash_payload "$R14" "git push origin main" > "$TMPROOT/p.push14b"
mkdir -p "$R14/.heimdall/ui/approvals"; chmod 500 "$R14/.heimdall/ui/approvals"
run_hook "$R14" "$TMPROOT/p.push14b" "${ARMED[@]}" HMD_PHONE_DENY_WINDOW_S=1
chmod 700 "$R14/.heimdall/ui/approvals"
if [ "$HOOK_RC" = 0 ] && [ -z "$HOOK_OUT" ] && under "$HOOK_S" 4; then
  ok "C14b. an unwritable approvals dir -> exit 0, no output, no wait"
else
  bad "C14b. unwritable-dir path wrong: rc=$HOOK_RC out=[$HOOK_OUT] ${HOOK_S}s"
fi

# C15 -- a risky write OUTSIDE the repo is held and can be denied like a shell command
R15="$(mk_repo)"; file_payload "$R15" Write /etc/hosts > "$TMPROOT/p.w15"
phone_deny "$R15" 0.2
run_hook "$R15" "$TMPROOT/p.w15" "${ARMED[@]}" HMD_PHONE_DENY_WINDOW_S=15
if printf '%s' "$HOOK_OUT" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null 2>&1; then
  ok "C15. a Write to /etc/hosts is held and the phone's deny blocks it"
else
  bad "C15. outside-repo write not denied: rc=$HOOK_RC out=[$HOOK_OUT] err=[$HOOK_ERR]"
fi

# C16 -- --help
OUT="$("$HOOK" --help 2>&1)"; RC=$?
if [ "$RC" = 0 ] && printf '%s' "$OUT" | grep -q 'HMD_PHONE_DENY' && printf '%s' "$OUT" | grep -qi 'deny'; then
  ok "C16. --help explains the flag and exits 0"
else
  bad "C16. --help wrong: rc=$RC out=[$OUT]"
fi

# ══ D. the hook group ═══════════════════════════════════════════════════════════════════════
GROUP_FILTER='[.hooks.PreToolUse[] | select(any(.hooks[]?; (.command // "") | contains("bin/heimdall-phone-deny")))]'
GROUP_N="$(jq -r "$GROUP_FILTER | length" "$HOOKS_JSON")"
GROUP_CMD="$(jq -r "$GROUP_FILTER | .[0].hooks[0].command // empty" "$HOOKS_JSON")"
GROUP_MATCHER="$(jq -r "$GROUP_FILTER | .[0].matcher // empty" "$HOOKS_JSON")"
GROUP_TIMEOUT="$(jq -r "$GROUP_FILTER | .[0].hooks[0].timeout // 0" "$HOOKS_JSON")"
if [ "$GROUP_N" = 1 ]; then
  ok "D1. exactly one PreToolUse group invokes bin/heimdall-phone-deny"
else
  bad "D1. $GROUP_N PreToolUse groups invoke bin/heimdall-phone-deny (want 1)"
fi
if python3 - "$GROUP_MATCHER" <<'PYEOF'
import re, sys
m = sys.argv[1]
yes = ["Bash", "Write", "Edit", "MultiEdit", "NotebookEdit"]
no = ["Read", "Grep", "Glob", "Agent", "WebFetch", "WebSearch", "Task", "mcp__x__y"]
sys.exit(0 if m and all(re.fullmatch(m, t) for t in yes) and not any(re.fullmatch(m, t) for t in no) else 1)
PYEOF
then
  ok "D2. the matcher '$GROUP_MATCHER' covers the shell and the file-writing tools, and nothing else"
else
  bad "D2. matcher '$GROUP_MATCHER' wrong"
fi
if [ "${GROUP_TIMEOUT:-0}" -ge 130 ] 2>/dev/null && [ "${GROUP_TIMEOUT:-0}" -le 300 ] 2>/dev/null; then
  ok "D3. the hook timeout (${GROUP_TIMEOUT}s) outlasts the longest window (120s) so the harness never cuts a long window short"
else
  bad "D3. hook timeout is '${GROUP_TIMEOUT}' (want 130..300)"
fi
if jq -e '.hooks[] | select(.id == "phone-deny") | .event == "PreToolUse" and .locked == false
          and (.description | contains("HMD_PHONE_DENY") and contains("deny"))' "$HOOKS_META" >/dev/null 2>&1 \
   && "$HOOKS_TOOL" check >/dev/null 2>&1; then
  ok "D4. hooks.metadata.json names the group phone-deny (PreToolUse, advisory, described) and heimdall-hooks check is clean"
else
  bad "D4. metadata entry missing/wrong, or heimdall-hooks check drifts: $("$HOOKS_TOOL" check 2>&1 | tail -3)"
fi
if "$HOOKS_TOOL" list --json | jq -e '.[] | select(.id=="phone-deny") | .enabled == true' >/dev/null 2>&1 \
   && "$HOOKS_TOOL" disable phone-deny >/dev/null 2>&1 \
   && "$HOOKS_TOOL" list --json | jq -e '.[] | select(.id=="phone-deny") | .enabled == false' >/dev/null 2>&1 \
   && "$HOOKS_TOOL" enable phone-deny >/dev/null 2>&1 \
   && "$HOOKS_TOOL" list --json | jq -e '.[] | select(.id=="phone-deny") | .enabled == true' >/dev/null 2>&1; then
  ok "D5. the group has a working kill switch: list shows it, disable turns it off, enable turns it back on"
else
  bad "D5. kill switch for phone-deny does not round-trip"
fi

# D6 -- the command, run the way Claude Code runs it, against a stand-in script that records how it
# was launched: flag off or group disabled -> never launched; a crash or a stray exit 2 -> exit 0
PLUG="$TMPROOT/plug"
mkdir -p "$PLUG/bin/lib" "$PLUG/hooks"
cp "$REPO/bin/lib/hook-enabled.sh" "$PLUG/bin/lib/hook-enabled.sh"
cp "$HOOKS_META" "$PLUG/hooks/hooks.metadata.json"
cat > "$PLUG/bin/heimdall-phone-deny" <<'SHEOF'
#!/bin/sh
: > "$MARK"
printf '%s\n' "$*" > "$ARGS"
cat > "$STDIN_COPY"
exit "${FAKE_RC:-0}"
SHEOF
chmod +x "$PLUG/bin/heimdall-phone-deny"
RD="$(mk_repo)"; bash_payload "$RD" "git push origin main" > "$TMPROOT/p.d6"
run_group() { # [VAR=val ...] -> GROUP_RC; sets MARK / ARGS / STDIN_COPY files fresh
  rm -f "$TMPROOT/d6.mark" "$TMPROOT/d6.args" "$TMPROOT/d6.stdin"
  env CLAUDE_PLUGIN_ROOT="$PLUG" CLAUDE_PROJECT_DIR="$RD" MARK="$TMPROOT/d6.mark" ARGS="$TMPROOT/d6.args" \
      STDIN_COPY="$TMPROOT/d6.stdin" "$@" sh -c "$GROUP_CMD" < "$TMPROOT/p.d6" >"$TMPROOT/d6.out" 2>"$TMPROOT/d6.err"
  GROUP_RC=$?
}
run_group
if [ "$GROUP_RC" = 0 ] && [ ! -e "$TMPROOT/d6.mark" ]; then
  ok "D6. flag unset -> the hook script is never even launched"
else
  bad "D6. flag-off group launched the script (rc=$GROUP_RC)"
fi
run_group HMD_PHONE_DENY=0
[ "$GROUP_RC" = 0 ] && [ ! -e "$TMPROOT/d6.mark" ] && ok "D6b. HMD_PHONE_DENY=0 -> never launched" || bad "D6b. launched with the flag at 0"
run_group HMD_PHONE_DENY=1
if [ "$GROUP_RC" = 0 ] && [ -e "$TMPROOT/d6.mark" ] && cmp -s "$TMPROOT/d6.stdin" "$TMPROOT/p.d6" \
   && [ "$(cat "$TMPROOT/d6.args")" = "--repo $RD" ]; then
  ok "D6c. flag on -> launched with the hook payload on stdin, byte for byte, and --repo = the project dir"
else
  bad "D6c. launch wrong: rc=$GROUP_RC mark=$([ -e "$TMPROOT/d6.mark" ] && echo y || echo n) args=[$(cat "$TMPROOT/d6.args" 2>/dev/null)] err=[$(cat "$TMPROOT/d6.err")]"
fi
HEIMDALL_HOME="$TMPROOT/d6home" "$HOOKS_TOOL" disable phone-deny >/dev/null 2>&1
run_group HMD_PHONE_DENY=1 HEIMDALL_HOME="$TMPROOT/d6home"
[ "$GROUP_RC" = 0 ] && [ ! -e "$TMPROOT/d6.mark" ] && ok "D6d. flag on but the group disabled (hmd hooks disable phone-deny) -> never launched" \
  || bad "D6d. a disabled group still launched"
HEIMDALL_HOME="$TMPROOT/d6home" "$HOOKS_TOOL" enable phone-deny >/dev/null 2>&1
run_group HMD_PHONE_DENY=1 HEIMDALL_HOME="$TMPROOT/d6home"
[ "$GROUP_RC" = 0 ] && [ -e "$TMPROOT/d6.mark" ] && ok "D6e. re-enabled -> launched again" || bad "D6e. re-enabling did not bring the hook back"
run_group HMD_PHONE_DENY=1 FAKE_RC=2
[ "$GROUP_RC" = 0 ] && ok "D6f. a script that exits 2 (the code that BLOCKS a tool call) still leaves the group at exit 0 -- it can never block on its own bug" \
  || bad "D6f. the group passed a script's exit $GROUP_RC through"
run_group HMD_PHONE_DENY=1 FAKE_RC=1
[ "$GROUP_RC" = 0 ] && ok "D6g. a script that exits 1 -> group exit 0" || bad "D6g. exit $GROUP_RC"
rm -f "$PLUG/bin/heimdall-phone-deny"
run_group HMD_PHONE_DENY=1
[ "$GROUP_RC" = 0 ] && ok "D6h. script missing -> group exit 0, no error" || bad "D6h. missing script gave exit $GROUP_RC"

# ══ E. the approvals slice of /api/state ════════════════════════════════════════════════════
export HEIMDALL_FALLBACK_ASSUME_REACHABLE=0
py_checks "$REPO" <<'PYEOF'
import importlib.util, json, os, re, sys, tempfile, time

REPO = sys.argv[1]


def load(name, rel):
    spec = importlib.util.spec_from_file_location(name, os.path.join(REPO, rel))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


D = load("dec", "bin/lib/companion_ui_decisions.py")
UI = load("hmd_ui", "sentinels/hmd-ui.py")


def check(name, cond, detail=""):
    print(("PASS %s" % name) if cond else ("FAIL %s :: %s" % (name, detail)))


KEYS = ["expires_at", "id", "requested_at", "risk", "summary", "tool"]
root = os.path.realpath(tempfile.mkdtemp(prefix="e-"))
os.makedirs(os.path.join(root, ".git"))

state = UI.collect_state(root)
check("E1. /api/state carries `approvals`, additive: an empty array when nothing is pending, old keys intact",
      state.get("approvals") == [] and all(k in state for k in ("schema_version", "inbox", "attention", "panels", "edits")),
      sorted(state))

d0 = UI.digest_of(state)
rec = D.request(root, "Bash", "git push origin main", 30)
state1 = UI.collect_state(root)
check("E2. a live request is listed with exactly the doc's six keys",
      [sorted(e) for e in state1["approvals"]] == [KEYS] and state1["approvals"][0]["id"] == rec["id"]
      and state1["approvals"][0]["summary"] == "git push origin main", state1["approvals"])
check("E3. the slice is inside the SSE digest: a request appearing changes it, an unchanged set does not",
      UI.digest_of(state1) != d0 and UI.digest_of(UI.collect_state(root)) == UI.digest_of(state1))
D.settle(root, rec["id"])
D.close(root, rec["id"])
check("E4. a settled + withdrawn request leaves the slice and the digest returns to its old value",
      UI.collect_state(root)["approvals"] == [] and UI.digest_of(UI.collect_state(root)) == d0)

secret = "ghp_" + "a1B2c3D4e5" * 3 + "a1B2c3"
D.request(root, "Bash", "curl -H 'Authorization: token %s' https://x" % secret, 30)
blob = json.dumps(UI.collect_state(root))
check("E5. a secret-shaped summary is dropped to null (request kept) and never reaches the served state",
      secret not in blob and UI.collect_state(root)["approvals"][0]["summary"] is None)

root2 = os.path.realpath(tempfile.mkdtemp(prefix="e2-"))
os.makedirs(os.path.join(root2, ".git"))
D.request(root2, "Write", "rm -rf %s/src/app/x.ts and mail me@example.com" % root2, 30)
loop = UI.collect_state(root2)["approvals"][0]["summary"]
relay = UI.collect_state(root2, {"bind": "relay"})["approvals"][0]["summary"]
public = UI.collect_state(root2, {"bind": "loopback", "public_host": "x.example.ts.net"})["approvals"][0]["summary"]
check("E6. loopback is unredacted; the relay profile keeps repo-relative paths; the public profile reduces to basenames; emails go in both",
      root2 in loop and "me@example.com" in loop
      and relay == "rm -rf src/app/x.ts and mail [email]" and public == "rm -rf x.ts and mail [email]",
      (loop, relay, public))

root3 = os.path.realpath(tempfile.mkdtemp(prefix="e3-"))
os.makedirs(os.path.join(root3, ".git"))
D.request(root3, "Bash", "git push", 30, now=time.time() - 60)
D.request(root3, "Bash", "stale", 300, now=time.time() - 30)
check("E7. an expired request, and one whose hook stopped heartbeating, are not listed",
      UI.collect_state(root3)["approvals"] == [], UI.collect_state(root3)["approvals"])

# E9 -- A1 parity (hmdapp's remote-controls handoff, H7): while a request is pending, `attention` says
# so, anchored on the request -- the phone's "needs you" signal and its approvals list never disagree
root4 = os.path.realpath(tempfile.mkdtemp(prefix="e4-"))
os.makedirs(os.path.join(root4, ".git"))
quiet = UI.collect_state(root4)["attention"]
rec = D.request(root4, "Bash", "git push origin main", 30)
st = UI.collect_state(root4)
att = st["attention"]
turn = st["parallelism"].get("turns")
turn = turn if isinstance(turn, int) and not isinstance(turn, bool) and turn >= 0 else None
check("E9. a pending request -> attention needs_approval / permission, anchored on the request",
      att["state"] == "needs_approval" and att["kind"] == "permission" and att["options"] is None
      and re.match(r"^a-[0-9a-f]{10}$", att["id"] or "") and att["since"] == round(rec["requested_at"], 3)
      and att["summary"] == "permission requested: Bash" and att["turn"] == turn, att)
check("E9b. the episode id is stable across collects; the request's command never reaches attention",
      UI.collect_state(root4)["attention"]["id"] == att["id"] and "git push" not in json.dumps(att), att)
D.settle(root4, rec["id"])
D.close(root4, rec["id"])
check("E9c. once the request is gone attention is back to what the transcript says (the idle default here)",
      UI.collect_state(root4)["attention"] == quiet, (quiet, UI.collect_state(root4)["attention"]))
root5 = os.path.realpath(tempfile.mkdtemp(prefix="e5-"))
os.makedirs(os.path.join(root5, ".git"))
first = D.request(root5, "Bash", "first", 30)
D.request(root5, "Write", "second", 30, now=time.time() + 1)
att = UI.collect_state(root5)["attention"]
check("E9d. with several pending, attention is anchored on the oldest",
      att["summary"] == "permission requested: Bash" and att["since"] == round(first["requested_at"], 3), att)
PYEOF

# E8 -- over HTTP there is NO decide route: a bearer token is not a sealed E2E command
FIX="$TMPROOT/ui-repo"; mkdir -p "$FIX/.heimdall"
( cd "$FIX" && git init -q . 2>/dev/null && git -c user.email=t@t -c user.name=t commit -q --allow-empty -m fixture >/dev/null 2>&1 ) || true
UI_PORT="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])')"
( cd "$FIX" && HEIMDALL_WATCH_ROOT="$FIX" exec "$REPO/bin/heimdall-ui" --repo "$FIX" --port "$UI_PORT" --no-open ) >"$TMPROOT/ui.out" 2>&1 &
PIDS+=("$!")
URL_RE="^http://127\.0\.0\.1:$UI_PORT/\?(t|token)=[A-Za-z0-9_-]+\$"
i=0; while [ "$i" -lt 100 ] && ! grep -Eq "$URL_RE" "$TMPROOT/ui.out" 2>/dev/null; do sleep 0.1; i=$((i + 1)); done
URL="$(grep -E "$URL_RE" "$TMPROOT/ui.out" | head -1)"
if [ -n "$URL" ]; then
  Q="${URL#*\?}"; TP="${Q%%=*}"; TOKEN="${Q#*=}"
  BASE="http://127.0.0.1:$UI_PORT"
  RID8="$(python3 - "$LIB" "$FIX" <<'PYEOF'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("dec", sys.argv[1]); D = importlib.util.module_from_spec(spec); spec.loader.exec_module(D)
print(D.request(sys.argv[2], "Bash", "git push", 60)["id"])
PYEOF
)"
  CODE="$(curl -s -o /dev/null -w '%{http_code}' -X POST -H 'Content-Type: application/json' \
          -d "{\"id\":\"$RID8\",\"decision\":\"deny\"}" "$BASE/api/decide?$TP=$TOKEN")"
  if [ "$CODE" = 405 ] && [ ! -e "$FIX/.heimdall/ui/approvals/$RID8.decision" ]; then
    ok "E8. POST /api/decide with a valid token -> 405 and nothing recorded (only sealed relay commands can decide)"
  else
    bad "E8. HTTP decide answered $CODE / left a decision"
  fi
  STATE="$TMPROOT/e8.state"
  curl -s -o "$STATE" "$BASE/api/state?$TP=$TOKEN"
  if jq -e --arg id "$RID8" '.approvals | length == 1 and .[0].id == $id' "$STATE" >/dev/null 2>&1; then
    ok "E8b. the live server's /api/state serves the pending request in approvals"
  else
    bad "E8b. live /api/state approvals: $(jq -c .approvals "$STATE" 2>/dev/null)"
  fi
else
  bad "E8. hmd ui never printed its URL: $(head -c 300 "$TMPROOT/ui.out")"
fi

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
