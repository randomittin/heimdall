#!/usr/bin/env bash
# test/companion-push-store.test.sh -- bin/lib/companion_push_store.py, the phone's push registrations
# (hmdapp's docs/HANDOFF-TO-HEIMDALL-push-notifications.md PN2 and its spec section 5), and the
# push commands of bin/heimdall-relay-client that write it.
#
# Hermetic: no network, no relay. Part A drives the store module directly; part B pairs the REAL
# RelayClient in-process with a fake phone (the real device_bound path, real sealing) and sends it the
# three sealed commands. The real client against test/lib/fake-relay.py is test/heimdall-app-relay.test.sh.
#
# Token-shaped input is assembled at run time (tok()): no token-shaped literal is committed.
#
# Part A -- the store
#    1. interface: names and parameters the notification sender is written against
#    2. a missing file is the default and load() creates nothing
#    3. corrupt / oversized / wrongly shaped files are the default, never an exception
#    4. damaged entries are dropped, good ones survive; the cap and duplicates hold on load too
#    5. register: round trip, ISO timestamp, the stored entry
#    6. permissions: directory 0700, push.json 0600, lock 0600, no temp file left
#    7. token format (spec 5.2): accepted and refused shapes, nothing written on a refusal
#    8. platform, 9. ref, 10. label, 11. events: each rule, and the order the refusals come in
#   12. upsert by token, 13. upsert by ref, 14. at most 5, newest wins
#   15. unregister by token / by ref: True/False, no write when nothing matched
#   16. remove_tokens
#   17. set_app_state: the vocabulary, "active" for foreground, timestamps, refusals
#   18. load() hands back copies
#   19. permissions self-heal on every touch
#   20. a failed write keeps the old file and leaves no temp file
#   21. a planted symlink is replaced, never followed (push.json and its lock)
#   22. the store prints nothing and no refusal repeats a token
#   23-24. concurrent writers: no lost update, no torn read
#   25. falsifiable: with the lock removed the same race DOES lose updates
#   26. a lock held past LOCK_TIMEOUT_S is an OSError, not a hang
# Part B -- the relay client's three commands (in-process, sealed)
#   27. state frames carry push-v1 (and stop carrying it with HMD_PUSH=0, or without the store)
#   28. register_push: the exact ack, the stored entry, the event line
#   29. idempotent upsert; a rotated token replaces the old one
#   30. every malformed register_push is refused with the spec's detail and writes nothing
#   31. unregister_push, 32. app_state
#   33. HMD_PUSH=0 and a missing store: push-disabled, nothing written
#   34. an unwritable store: write-failed
#   35. no token in any event line, ack or status file
#   36. device_bound: an earlier session's registrations are cleared at the first bind; a same-device
#       repeat and a refused different-device frame leave them alone
set -u

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STORE="$REPO/bin/lib/companion_push_store.py"
CLIENT="$REPO/bin/heimdall-relay-client"

PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; }

echo "companion-push-store (push registrations: bin/lib/companion_push_store.py + the relay client's push commands)"

for f in "$STORE" "$CLIENT"; do
  if [ ! -f "$f" ]; then
    printf '  FAIL %s is absent\n' "$f"
    printf '\n0 passed, 1 failed\n'
    exit 1
  fi
done
if ! command -v python3 >/dev/null 2>&1; then
  printf '  FAIL required tool missing: python3\n'
  printf '\n0 passed, 1 failed\n'
  exit 1
fi

# ── sandbox: a throwaway HOME so nothing here can read or touch the operator's ~/.heimdall ──
TMPROOT="$(mktemp -d)"
export TMPDIR="$TMPROOT"
export HOME="$TMPROOT/home"
export HEIMDALL_HOME="$TMPROOT/home/.heimdall"
mkdir -p "$HOME/.claude"
unset HMD_PUSH
trap 'rm -rf "$TMPROOT"' EXIT

# Every python case gets this prelude (the store loaded BY PATH, the convention bin/heimdall-relay-client
# itself uses) followed by its own body on stdin.
PRELUDE='
import ast, errno, inspect, json, os, re, stat, subprocess, sys, tempfile, threading, time
from importlib.util import module_from_spec, spec_from_file_location
STORE_PATH, CLIENT_PATH, REPO, TMPROOT = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
_spec = spec_from_file_location("companion_push_store", STORE_PATH)
store = module_from_spec(_spec)
_spec.loader.exec_module(store)
ISO = re.compile(r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$")
DEFAULT = {"tokens": [], "app_state": "unknown", "app_state_at": None}
WORKER = os.path.join(TMPROOT, "push-worker.py")


def tok(seed="a", n=22, kind="Exponent"):
    """A token-shaped string assembled at run time, so no token-shaped literal is ever committed."""
    return kind + "PushToken[" + (str(seed) * n)[:n] + "]"


def fresh():
    return tempfile.mkdtemp(prefix="push-store-", dir=TMPROOT)


def mode(path):
    return stat.S_IMODE(os.stat(path).st_mode)


def push_json(root):
    return os.path.join(root, ".heimdall", "app", "push.json")


def write_raw(root, data):
    os.makedirs(os.path.dirname(push_json(root)), exist_ok=True)
    with open(push_json(root), "wb") as f:
        f.write(data)


def refuse(code, fn, *args, **kwargs):
    """The PushStoreError fn(*args) raises, with `code`. AssertionError when it returns or raises anything else."""
    try:
        fn(*args, **kwargs)
    except store.PushStoreError as e:
        assert e.code == code, "refused with %r, expected %r" % (e.code, code)
        return e
    except Exception as e:
        raise AssertionError("raised %s instead of PushStoreError: %s" % (type(e).__name__, e))
    raise AssertionError("was accepted instead of refused with %r" % code)
'

# The workers the concurrency cases start (one python process each, started together).
cat > "$TMPROOT/push-worker.py" <<'WORKEREOF'
import contextlib
import sys
import time
from importlib.util import module_from_spec, spec_from_file_location

store_path, root, start_at, kind, prefix, count = sys.argv[1:7]
spec = spec_from_file_location("companion_push_store", store_path)
store = module_from_spec(spec)
spec.loader.exec_module(store)


def tok(seed):
    return "Exponent" + "PushToken[" + (str(seed) * 22)[:22] + "]"


if kind == "unlocked-slow":
    # the mutant: no lock, and a pause between reading the state and writing it back
    real_write = store._write

    def slow_write(repo_root, state):
        time.sleep(0.4)
        real_write(repo_root, state)

    store._Flock = lambda *_: contextlib.nullcontext()
    store._write = slow_write
if kind == "hold-lock":
    store.LOCK_TIMEOUT_S = 5.0
    with store._Flock(root):
        open(prefix, "w").close()          # tells the parent the lock is held
        time.sleep(float(count))
    sys.exit(0)

while time.time() < float(start_at):
    time.sleep(0.001)
if kind in ("register", "unlocked-slow"):
    for i in range(int(count)):
        store.register(root, tok("%s%d" % (prefix, i)), "ios")
elif kind == "mixed":
    previous = None
    for i in range(int(count)):
        current = tok("%s%d" % (prefix, i))
        store.register(root, current, "android")
        store.set_app_state(root, "foreground" if i % 2 else "background")
        if previous is not None:
            store.unregister(root, previous)
        previous = current
sys.exit(0)
WORKEREOF

# py_case NUM DESCRIPTION [rig]   (python body on stdin; stdout's last line, if any, is appended to the ok line)
py_case() {
  local num="$1" desc="$2" extra="" out
  [ "${3:-}" = "rig" ] && extra="$RIG"
  if { printf '%s\n%s\n' "$PRELUDE" "$extra"; cat; } | python3 - "$STORE" "$CLIENT" "$REPO" "$TMPROOT" >"$TMPROOT/case$num.out" 2>"$TMPROOT/case$num.err"; then
    out="$(tail -n 1 "$TMPROOT/case$num.out")"
    if [ -n "$out" ]; then ok "$num. $desc ($out)"; else ok "$num. $desc"; fi
  else
    bad "$num. $desc:"
    sed 's/^/       | /' "$TMPROOT/case$num.err"
  fi
}

# ═══ 1. interface ═══════════════════════════════════════════════════════════
py_case 1 "interface: the five functions the notification sender is written against keep their names and parameters" <<'PYEOF'
want = {
    "load": "(repo_root)",
    "register": "(repo_root, token, platform=None, *, ref=None, label=None, events=None)",
    "unregister": "(repo_root, token=None, *, ref=None)",
    "set_app_state": "(repo_root, state)",
    "remove_tokens": "(repo_root, tokens)",
}
for name, signature in want.items():
    got = str(inspect.signature(getattr(store, name)))
    assert got == signature, "%s%s is not the promised %s%s" % (name, got, name, signature)
assert issubclass(store.PushStoreError, ValueError) and store.MAX_TOKENS == 5
assert store.PUSH_REL == os.path.join(".heimdall", "app", "push.json")
print("5 functions, MAX_TOKENS=5, %s" % store.PUSH_REL)
PYEOF

# ═══ 2. a missing file ══════════════════════════════════════════════════════
py_case 2 "a missing file is the default state, and load() creates nothing" <<'PYEOF'
root = fresh()
assert store.load(root) == DEFAULT, store.load(root)
assert not os.path.exists(os.path.join(root, ".heimdall")), "load() must never create a directory"
assert store.load(os.path.join(root, "no", "such", "repo")) == DEFAULT
PYEOF

# ═══ 3. corrupt files ═══════════════════════════════════════════════════════
py_case 3 "a corrupt, oversized or wrongly shaped file is the default state, never an exception" <<'PYEOF'
root = fresh()
variants = [b"", b"{", b"not json", b"[]", b"\"str\"", b"123", b"null", b"\xff\xfe\x00junk",
            b"{\"tokens\": 5}", b"{\"tokens\": {\"a\": 1}}", b"{\"tokens\": \"x\", \"app_state\": 7}",
            b"{\"tokens\": [], \"pad\": \"" + b"x" * 70000 + b"\"}"]
for raw in variants:
    write_raw(root, raw)
    assert store.load(root) == DEFAULT, "%r gave %r" % (raw[:24], store.load(root))
os.unlink(push_json(root))
os.mkdir(push_json(root))  # a directory where the file belongs
assert store.load(root) == DEFAULT
os.rmdir(push_json(root))
write_raw(root, json.dumps({"app_state": "weird", "app_state_at": 5}).encode())
assert store.load(root) == DEFAULT
write_raw(root, json.dumps({"app_state": "background", "app_state_at": "soon"}).encode())
assert store.load(root) == dict(DEFAULT, app_state="background"), store.load(root)
write_raw(root, json.dumps({"app_state": "unknown", "app_state_at": "2026-10-03T10:05:00Z"}).encode())
assert store.load(root) == DEFAULT, "an unknown state carries no timestamp"
print("%d corrupt shapes" % (len(variants) + 4))
PYEOF

# ═══ 4. damaged entries ═════════════════════════════════════════════════════
py_case 4 "damaged entries are dropped and good ones survive; the cap and duplicates hold on load as well" <<'PYEOF'
root = fresh()
good = {"token": tok("g"), "platform": "ios", "registered_at": "2026-10-03T10:00:00Z"}
half = {"token": tok("h"), "platform": "bogus", "registered_at": "2026-10-03T10:00:01Z",
        "ref": "0123456789abcdef", "label": "x/y", "events": ["nope"]}
junk = [{"token": "short", "platform": "ios", "registered_at": "2026-10-03T10:00:00Z"}, 5, None, "s",
        {"token": tok("i"), "registered_at": "yesterday"}, {"token": tok("j")},
        {"registered_at": "2026-10-03T10:00:00Z"}, {"token": 7, "registered_at": "2026-10-03T10:00:00Z"}]
write_raw(root, json.dumps({"v": 1, "tokens": [junk[0], good, junk[1], half] + junk[2:],
                            "app_state": "foreground", "app_state_at": "2026-10-03T10:05:00Z"}).encode())
got = store.load(root)
assert got["tokens"] == [good, {"token": tok("h"), "platform": None, "registered_at": "2026-10-03T10:00:01Z",
                                "ref": "0123456789abcdef"}], got["tokens"]
assert got["app_state"] == "foreground" and got["app_state_at"] == "2026-10-03T10:05:00Z"
many = [{"token": tok(i), "platform": "ios", "registered_at": "2026-10-03T10:00:%02dZ" % i} for i in range(8)]
write_raw(root, json.dumps({"tokens": many}).encode())
assert [e["token"] for e in store.load(root)["tokens"]] == [tok(i) for i in range(3, 8)], "the 5 newest"
dup = [dict(many[0]), dict(many[1]), dict(many[0], registered_at="2026-10-03T10:00:09Z")]
write_raw(root, json.dumps({"tokens": dup}).encode())
got = store.load(root)["tokens"]
assert [e["token"] for e in got] == [tok(1), tok(0)] and got[1]["registered_at"] == "2026-10-03T10:00:09Z", got
PYEOF

# ═══ 5. register round trip ═════════════════════════════════════════════════
py_case 5 "register: round trip, the stored entry, an ISO-8601 UTC timestamp" <<'PYEOF'
root = fresh()
t = tok("r")
entry = store.register(root, t, "ios")
got = store.load(root)
assert got["tokens"] == [entry], (got, entry)
assert set(entry) == {"token", "platform", "registered_at"}, sorted(entry)
assert entry["token"] == t and entry["platform"] == "ios" and ISO.match(entry["registered_at"]), entry
assert got["app_state"] == "unknown" and got["app_state_at"] is None
raw = json.load(open(push_json(root)))
assert raw["v"] == 1 and raw["tokens"] == [entry]
full = store.register(root, tok("s"), "android", ref="9f3c2a1b7d4e6f80", label="api server",
                      events=["question", "approval"])
assert full["ref"] == "9f3c2a1b7d4e6f80" and full["label"] == "api server" and full["events"] == ["approval", "question"], full
assert store.load(root)["tokens"][-1] == full
assert store.register(root, tok("t"))["platform"] is None, "platform is optional"
print(entry["registered_at"])
PYEOF

# ═══ 6. permissions ═════════════════════════════════════════════════════════
py_case 6 "permissions: directory 0700, push.json 0600, lock 0600, and no temp file left behind" <<'PYEOF'
root = fresh()
store.register(root, tok("p"), "ios")
directory = os.path.dirname(push_json(root))
assert mode(directory) == 0o700, oct(mode(directory))
assert mode(push_json(root)) == 0o600, oct(mode(push_json(root)))
assert mode(push_json(root) + ".lock") == 0o600
assert sorted(os.listdir(directory)) == ["push.json", "push.json.lock"], os.listdir(directory)
old = os.umask(0o000)  # a hostile umask must not widen anything
try:
    root2 = fresh()
    store.set_app_state(root2, "background")
    assert mode(push_json(root2)) == 0o600 and mode(os.path.dirname(push_json(root2))) == 0o700
finally:
    os.umask(old)
print("dir 0700, files 0600")
PYEOF

# ═══ 7. token format ════════════════════════════════════════════════════════
py_case 7 "token format (spec 5.2): the accepted shapes are stored, every other is refused bad-token and writes nothing" <<'PYEOF'
accepted = [tok("a", 22), tok("a", 8), tok("a", 64), tok("a", 22, "Expo"), tok("A9_-", 40), tok("z", 22, "Exponent")]
for t in accepted:
    root = fresh()
    store.register(root, t, "ios")
    assert store.load(root)["tokens"][0]["token"] == t
body = "a" * 22
EXP, EXPO = "Exponent" + "PushToken", "Expo" + "PushToken"   # the prefixes, never joined to a body in the source
refused = [tok("a", 7), tok("a", 65), "", " " + tok("a"), tok("a") + " ", tok("a") + "\n", "\n" + tok("a"),
           EXP.lower() + "[" + body + "]", EXPO + body, EXP + "(" + body + ")",
           EXP + "[" + body, EXP + "[" + body + "]]", EXPO + "[" + "a b" * 4 + "]",
           EXP + "[" + "a/b." * 4 + "]", EXP + "[" + "ä" * 12 + "]", EXP + "[" + "a" * 11 + "\x00]",
           "FcmPushToken[" + body + "]", EXP + "[]", None, 5, b"x", [tok("a")], {"token": tok("a")}, True]
for bad in refused:
    root = fresh()
    e = refuse("bad-token", store.register, root, bad, "ios")
    assert not os.path.exists(os.path.join(root, ".heimdall")), "a refused token must write nothing (%r)" % (bad,)
    if isinstance(bad, str) and len(bad) > 12:
        assert bad not in str(e) and bad[:12] not in str(e), "the refusal must not repeat the token"
print("%d accepted, %d refused" % (len(accepted), len(refused)))
PYEOF

# ═══ 8. platform ════════════════════════════════════════════════════════════
py_case 8 "platform: None, ios or android; anything else is bad-platform; a bad token is reported first" <<'PYEOF'
root = fresh()
for p in (None, "ios", "android"):
    store.register(root, tok(p), p)
    assert store.load(root)["tokens"][-1]["platform"] == p
for bad in ("windows", "", "IOS", "Android", 1, True, ["ios"], b"ios", " ios"):
    refuse("bad-platform", store.register, root, tok("q"), bad)
refuse("bad-token", store.register, root, "nope", "windows")
assert len(store.load(root)["tokens"]) == 3
PYEOF

# ═══ 9. ref ═════════════════════════════════════════════════════════════════
py_case 9 "ref: 16 lowercase hex digits (spec 5.2); anything else is bad-ref" <<'PYEOF'
root = fresh()
for good in ("9f3c2a1b7d4e6f80", "0" * 16, "f" * 16, "0123456789abcdef"):
    assert store.register(root, tok(good[:3]), "ios", ref=good)["ref"] == good
for bad in ("9F3C2A1B7D4E6F80", "9f3c2a1b7d4e6f8", "9f3c2a1b7d4e6f800", "9f3c2a1b7d4e6f8g", "", " 9f3c2a1b7d4e6f8",
            "9f3c2a1b7d4e6f80\n", 9, True, ["9f3c2a1b7d4e6f80"], b"9f3c2a1b7d4e6f80"):
    refuse("bad-ref", store.register, root, tok("q"), "ios", ref=bad)
refuse("bad-platform", store.register, root, tok("q"), "bogus", ref="zz")
PYEOF

# ═══ 10. label ══════════════════════════════════════════════════════════════
py_case 10 "label: 1..24 UTF-16 units after trim, one line, no / or backslash; the trimmed label is what is stored" <<'PYEOF'
root = fresh()
good = {"api server": "api server", "x": "x", "x" * 24: "x" * 24, "\U0001F600" * 12: "\U0001F600" * 12,
        "  padded  ": "padded", "naïve café": "naïve café", "a b": "a b", "a·b": "a·b"}
for given, stored in good.items():
    assert store.register(root, tok("l"), "ios", label=given)["label"] == stored, given
for bad in ("", "   ", "x" * 25, "\U0001F600" * 13, "a" * 23 + "\U0001F600", "a/b", "a\\b", "a\nb", "a\tb", "a\x00b", "a\x7fb",
            "a\x85b", "a\ud800b", "\ud83d", 5, True, ["x"], b"x", {"a": 1}):
    refuse("bad-label", store.register, root, tok("l"), "ios", label=bad)
assert len(store.load(root)["tokens"]) == 1 and store.load(root)["tokens"][0]["label"] == "a·b"
refuse("bad-ref", store.register, root, tok("l"), "ios", ref="nope", label="x" * 99)
PYEOF

# ═══ 11. events ═════════════════════════════════════════════════════════════
py_case 11 "events: a non-empty set of the five kinds, no duplicate; stored sorted; anything else is bad-events" <<'PYEOF'
root = fresh()
five = ["question", "approval", "finished", "error", "gate_red"]
assert store.register(root, tok("e"), "ios", events=five)["events"] == ["approval", "error", "finished", "gate_red", "question"]
assert store.register(root, tok("e"), "ios", events=["error"])["events"] == ["error"]
assert store.register(root, tok("e"), "ios", events=("question", "approval"))["events"] == ["approval", "question"]
for bad in ([], "question", ["question", "question"], ["test"], ["nope"], ["Question"], [5], [None], [{"a": 1}], [["question"]],
            five + ["question"], five + ["test"], {"question"}, 5, True, b"question", {"question": 1}):
    refuse("bad-events", store.register, root, tok("e"), "ios", events=bad)
assert store.load(root)["tokens"][0]["events"] == ["approval", "question"], "a refusal must not change the stored entry"
# the order the refusals come in is the spec's: token, platform, ref, label, events
refuse("bad-token", store.register, root, "x", "x", ref="x", label="", events=[])
refuse("bad-platform", store.register, root, tok("e"), "x", ref="x", label="", events=[])
refuse("bad-ref", store.register, root, tok("e"), "ios", ref="x", label="", events=[])
refuse("bad-label", store.register, root, tok("e"), "ios", ref="0123456789abcdef", label="", events=[])
refuse("bad-events", store.register, root, tok("e"), "ios", ref="0123456789abcdef", label="ok", events=[])
PYEOF

# ═══ 12. upsert by token ════════════════════════════════════════════════════
py_case 12 "register is an upsert: the same token again leaves one entry, the newest, with the new details" <<'PYEOF'
root = fresh()
clock = iter("2026-10-03T10:00:%02dZ" % n for n in range(60))
store._now_iso = lambda: next(clock)
a, b = tok("a"), tok("b")
store.register(root, a, "ios", ref="0123456789abcdef", label="one", events=["error"])
store.register(root, b, "android")
store.register(root, a, "android", label="two")
got = store.load(root)["tokens"]
assert [e["token"] for e in got] == [b, a], "the re-registered token is the newest: %r" % got
assert got[1] == {"token": a, "platform": "android", "registered_at": "2026-10-03T10:00:02Z", "label": "two"}, got[1]
assert got[0]["registered_at"] == "2026-10-03T10:00:01Z"
PYEOF

# ═══ 13. upsert by ref ══════════════════════════════════════════════════════
py_case 13 "register: the same ref with a new token replaces the old one; another ref, or no ref, does not" <<'PYEOF'
root = fresh()
R1, R2 = "0123456789abcdef", "fedcba9876543210"
store.register(root, tok("a"), "ios", ref=R1)
store.register(root, tok("b"), "ios", ref=R2)
store.register(root, tok("c"), "ios", ref=R1)            # the phone rotated its token
assert [e["token"] for e in store.load(root)["tokens"]] == [tok("b"), tok("c")], store.load(root)["tokens"]
store.register(root, tok("d"), "ios")                      # no ref: replaces nothing but itself
store.register(root, tok("d"), "ios")
assert [e["token"] for e in store.load(root)["tokens"]] == [tok("b"), tok("c"), tok("d")]
store.register(root, tok("c"), "ios", ref=R2)              # same token, another ref: one entry, the new ref
got = store.load(root)["tokens"]
assert [e["token"] for e in got] == [tok("d"), tok("c")] and got[1]["ref"] == R2, got
PYEOF

# ═══ 14. the cap ════════════════════════════════════════════════════════════
py_case 14 "at most 5 tokens are kept, the newest winning; re-registering one moves it to the newest" <<'PYEOF'
root = fresh()
for i in range(7):
    store.register(root, tok(i), "ios")
assert [e["token"] for e in store.load(root)["tokens"]] == [tok(i) for i in range(2, 7)], "the 5 newest, oldest first"
store.register(root, tok(2), "ios")
assert [e["token"] for e in store.load(root)["tokens"]] == [tok(i) for i in (3, 4, 5, 6, 2)]
store.register(root, tok(6), "ios")
assert len(store.load(root)["tokens"]) == 5, "a duplicate evicts nobody"
store.register(root, tok(9), "ios")
assert [e["token"] for e in store.load(root)["tokens"]] == [tok(i) for i in (4, 5, 2, 6, 9)]
PYEOF

# ═══ 15. unregister ═════════════════════════════════════════════════════════
py_case 15 "unregister: by token or by ref, True only when something went, and nothing is rewritten otherwise" <<'PYEOF'
root = fresh()
R1, R2 = "0123456789abcdef", "fedcba9876543210"
assert store.unregister(root, tok("a")) is False and store.unregister(root, ref=R1) is False
assert not os.path.exists(os.path.join(root, ".heimdall")), "unregistering from nothing must create nothing"
store.register(root, tok("a"), "ios", ref=R1)
store.register(root, tok("b"), "ios", ref=R2)
store.register(root, tok("c"), "ios")
before = os.stat(push_json(root))
assert store.unregister(root, tok("zzz")) is False and store.unregister(root, ref="1111111111111111") is False
after = os.stat(push_json(root))
assert (before.st_ino, before.st_mtime_ns) == (after.st_ino, after.st_mtime_ns), "a no-op must not rewrite the file"
assert store.unregister(root, tok("a")) is True and store.unregister(root, tok("a")) is False
assert store.unregister(root, ref=R2) is True and store.unregister(root, ref=R2) is False
assert [e["token"] for e in store.load(root)["tokens"]] == [tok("c")]
for bad in ("9F3C2A1B7D4E6F80", "short", "", 5, True, ["0123456789abcdef"]):
    refuse("bad-ref", store.unregister, root, ref=bad)
refuse("bad-params", store.unregister, root)
refuse("bad-params", store.unregister, root, tok("c"), ref=R1)
assert store.unregister(root, 5) is False and store.unregister(root, "not a token") is False
assert len(store.load(root)["tokens"]) == 1
PYEOF

# ═══ 16. remove_tokens ══════════════════════════════════════════════════════
py_case 16 "remove_tokens: drops the listed tokens, counts them, ignores strangers, keeps the app state" <<'PYEOF'
root = fresh()
assert store.remove_tokens(root, [tok("a")]) == 0 and not os.path.exists(os.path.join(root, ".heimdall"))
for c in "abcd":
    store.register(root, tok(c), "ios")
store.set_app_state(root, "foreground")
assert store.remove_tokens(root, [tok("a"), tok("c"), tok("nope"), 5, None, b"x"]) == 2
assert [e["token"] for e in store.load(root)["tokens"]] == [tok("b"), tok("d")]
assert store.remove_tokens(root, []) == 0 and store.remove_tokens(root, ()) == 0
assert store.remove_tokens(root, {tok("b")}) == 1
assert store.remove_tokens(root, tok("d")) == 1, "a single token as a bare string"
got = store.load(root)
assert got["tokens"] == [] and got["app_state"] == "foreground" and ISO.match(got["app_state_at"]), got
PYEOF

# ═══ 17. app state ══════════════════════════════════════════════════════════
py_case 17 "set_app_state: foreground (or the phone's word, active), background, unknown; stamps its time; refuses the rest" <<'PYEOF'
root = fresh()
clock = iter("2026-10-03T11:00:%02dZ" % n for n in range(60))
store._now_iso = lambda: next(clock)
store.register(root, tok("a"), "ios")                       # takes clock tick 0
for given, stored in (("foreground", "foreground"), ("active", "foreground"), ("background", "background")):
    store.set_app_state(root, given)
    got = store.load(root)
    assert got["app_state"] == stored and ISO.match(got["app_state_at"]), (given, got)
at = store.load(root)["app_state_at"]
store.set_app_state(root, "background")
assert store.load(root)["app_state_at"] > at, "every report refreshes the timestamp (it is how a silent phone ages)"
assert [e["token"] for e in store.load(root)["tokens"]] == [tok("a")], "the tokens are untouched"
store.set_app_state(root, "unknown")
assert store.load(root) == dict(DEFAULT, tokens=store.load(root)["tokens"]), store.load(root)
store.set_app_state(root, "foreground")
for bad in ("inactive", "FOREGROUND", "Active", "", " background", None, 1, True, ["background"], b"background"):
    refuse("bad-state", store.set_app_state, root, bad)
assert store.load(root)["app_state"] == "foreground", "a refusal must change nothing"
fresh_root = fresh()
store.set_app_state(fresh_root, "background")
assert store.load(fresh_root)["tokens"] == [] and store.load(fresh_root)["app_state"] == "background"
PYEOF

# ═══ 18. copies ═════════════════════════════════════════════════════════════
py_case 18 "load() hands back copies: changing one never changes the next load, or the file" <<'PYEOF'
root = fresh()
store.register(root, tok("a"), "ios", events=["error"])
first = store.load(root)
first["tokens"].append("x")
first["tokens"][0]["token"] = "changed"
first["tokens"][0]["events"].append("question")
first["app_state"] = "foreground"
again = store.load(root)
assert len(again["tokens"]) == 1 and again["tokens"][0]["token"] == tok("a") and again["tokens"][0]["events"] == ["error"]
assert again["app_state"] == "unknown"
entry = store.register(root, tok("b"), "ios", events=["error"])
entry["events"].append("question")
assert store.load(root)["tokens"][-1]["events"] == ["error"], "register() returns a copy too"
PYEOF

# ═══ 19. permissions self-heal ══════════════════════════════════════════════
py_case 19 "permissions self-heal: a directory left 0755 and files left 0644 are tightened by the next write" <<'PYEOF'
root = fresh()
store.register(root, tok("a"), "ios")
directory = os.path.dirname(push_json(root))
os.chmod(directory, 0o755)
os.chmod(push_json(root), 0o644)
os.chmod(push_json(root) + ".lock", 0o644)
store.set_app_state(root, "background")
assert mode(directory) == 0o700 and mode(push_json(root)) == 0o600 and mode(push_json(root) + ".lock") == 0o600
PYEOF

# ═══ 20. a failed write ═════════════════════════════════════════════════════
py_case 20 "a failed write raises the OSError, keeps the old file intact and leaves no temp file" <<'PYEOF'
root = fresh()
store.register(root, tok("a"), "ios")
good = open(push_json(root), "rb").read()
real_replace = os.replace
def broken(*args, **kwargs):
    raise OSError(errno.ENOSPC, "disk full")
os.replace = broken
try:
    for fn, args in ((store.register, (tok("b"), "ios")), (store.set_app_state, ("background",)),
                     (store.unregister, (tok("a"),)), (store.remove_tokens, ([tok("a")],))):
        try:
            fn(root, *args)
        except OSError as e:
            assert e.errno == errno.ENOSPC
        else:
            raise AssertionError("%s swallowed the failed write" % fn.__name__)
finally:
    os.replace = real_replace
assert open(push_json(root), "rb").read() == good, "the old file must survive a failed write"
assert sorted(os.listdir(os.path.dirname(push_json(root)))) == ["push.json", "push.json.lock"]
store.register(root, tok("b"), "ios")
assert len(store.load(root)["tokens"]) == 2, "and the store works again afterwards"
PYEOF

# ═══ 21. planted symlinks ═══════════════════════════════════════════════════
py_case 21 "a planted symlink is replaced, never followed: not at push.json, not at its lock" <<'PYEOF'
root = fresh()
victim = os.path.join(root, "victim.txt")
open(victim, "w").write("precious")
os.makedirs(os.path.dirname(push_json(root)))
os.symlink(victim, push_json(root))
store.register(root, tok("a"), "ios")
assert open(victim).read() == "precious", "the symlink target was written through"
assert not os.path.islink(push_json(root)) and store.load(root)["tokens"][0]["token"] == tok("a")
root = fresh()
victim = os.path.join(root, "victim.txt")
open(victim, "w").write("precious")
os.makedirs(os.path.dirname(push_json(root)))
os.symlink(victim, push_json(root) + ".lock")
refused = False
try:
    store.register(root, tok("a"), "ios")
except OSError:
    refused = True
assert refused, "a symlinked lock file must be refused, not followed"
assert open(victim).read() == "precious" and not os.path.exists(push_json(root))
PYEOF

# ═══ 22. silence ════════════════════════════════════════════════════════════
py_case 22 "the store prints nothing, imports no logger, and no refusal repeats the token it was given" <<'PYEOF'
tree = ast.parse(open(STORE_PATH).read())
printed = [n for n in ast.walk(tree) if isinstance(n, ast.Call) and getattr(n.func, "id", "") == "print"]
imports = {a.name.split(".")[0] for n in ast.walk(tree) if isinstance(n, (ast.Import, ast.ImportFrom))
           for a in (n.names if isinstance(n, ast.Import) else [ast.alias(name=n.module)])}
assert not printed, "the store must not print"
assert not imports & {"logging", "sys", "traceback", "warnings"}, imports
stdlib_only = imports <= {"copy", "errno", "fcntl", "json", "os", "re", "secrets", "time", "unicodedata"}
assert stdlib_only, "unexpected import: %r" % (imports,)
secret = tok("S3cretS3cretS3cret")
probe = r"""
import sys
from importlib.util import module_from_spec, spec_from_file_location
spec = spec_from_file_location("s", sys.argv[1]); s = module_from_spec(spec); spec.loader.exec_module(s)
root, secret = sys.argv[2], sys.argv[3]
s.register(root, secret, "ios", ref="0123456789abcdef", label="l", events=["error"])
s.set_app_state(root, "foreground")
s.load(root); s.unregister(root, secret); s.register(root, secret, "ios"); s.remove_tokens(root, [secret])
for call in (lambda: s.register(root, secret + "x", "ios"), lambda: s.register(root, secret, "bad"),
             lambda: s.unregister(root, secret, ref=secret), lambda: s.set_app_state(root, secret)):
    try:
        call()
    except s.PushStoreError as e:
        assert secret not in str(e) and secret not in repr(e) and secret not in e.code
"""
root = fresh()
p = subprocess.run([sys.executable, "-c", probe, STORE_PATH, root, secret], capture_output=True, text=True, timeout=30)
assert p.returncode == 0, p.stderr
assert p.stdout == "" and p.stderr == "", "the store wrote to stdout/stderr: %r %r" % (p.stdout, p.stderr)
PYEOF

# ═══ 23. concurrent writers ═════════════════════════════════════════════════
py_case 23 "concurrent writers: no lost update across processes, and no reader ever sees a torn file" <<'PYEOF'
lost, torn, reads = [], [], [0]
for round_no in range(8):
    root = fresh()
    start = time.time() + 0.6
    procs = [subprocess.Popen([sys.executable, WORKER, STORE_PATH, root, str(start), "register", "w%d" % w, "1"])
             for w in range(4)]
    stop = threading.Event()
    def reader():
        path = push_json(root)
        while not stop.is_set():
            try:
                raw = open(path, "rb").read()
            except FileNotFoundError:
                continue
            reads[0] += 1
            try:
                json.loads(raw)
            except ValueError:
                torn.append(raw[:40])
    t = threading.Thread(target=reader); t.start()
    codes = [p.wait(timeout=60) for p in procs]
    stop.set(); t.join()
    assert codes == [0, 0, 0, 0], codes
    got = {e["token"] for e in store.load(root)["tokens"]}
    want = {tok("w%d0" % w) for w in range(4)}
    if got != want:
        lost.append((round_no, len(got)))
assert not torn, "a reader saw a torn push.json: %r" % torn[:3]
assert not lost, "updates were lost in rounds %r" % lost
print("8 rounds x 4 writers, %d raw reads, 0 torn" % reads[0])
PYEOF

py_case 24 "concurrent mixed traffic (register, app state, unregister) from 10 processes leaves a valid file at the cap" <<'PYEOF'
root = fresh()
start = time.time() + 0.8
procs = [subprocess.Popen([sys.executable, WORKER, STORE_PATH, root, str(start), "mixed", "m%d" % w, "6"])
         for w in range(10)]
assert [p.wait(timeout=120) for p in procs] == [0] * 10
raw = json.load(open(push_json(root)))
got = store.load(root)
assert raw["v"] == 1 and got["app_state"] in ("foreground", "background") and ISO.match(got["app_state_at"]), got
assert 1 <= len(got["tokens"]) <= store.MAX_TOKENS, len(got["tokens"])
for e in got["tokens"]:
    assert e["token"].split("[")[1].startswith("m"), e
assert mode(push_json(root)) == 0o600
assert sorted(os.listdir(os.path.dirname(push_json(root)))) == ["push.json", "push.json.lock"], "temp files left behind"
print("%d tokens kept of 60 registered" % len(got["tokens"]))
PYEOF

# ═══ 25. falsifiable ════════════════════════════════════════════════════════
py_case 25 "falsifiable: with the lock removed (and the write slowed) the same race loses updates, so case 23 means something" <<'PYEOF'
root = fresh()
start = time.time() + 0.6
procs = [subprocess.Popen([sys.executable, WORKER, STORE_PATH, root, str(start), "unlocked-slow", "u%d" % w, "1"])
         for w in range(4)]
assert [p.wait(timeout=60) for p in procs] == [0, 0, 0, 0]
kept = len(store.load(root)["tokens"])
assert kept < 4, "the unlocked mutant kept all %d updates: the race is not being exercised" % kept
print("unlocked: %d of 4 updates survived" % kept)
PYEOF

# ═══ 26. a stuck lock holder ════════════════════════════════════════════════
py_case 26 "a lock held past LOCK_TIMEOUT_S is an OSError (ETIMEDOUT), not a hang; the store works once it is released" <<'PYEOF'
root = fresh()
store.register(root, tok("a"), "ios")
held = os.path.join(TMPROOT, "held-%d" % os.getpid())
holder = subprocess.Popen([sys.executable, WORKER, STORE_PATH, root, "0", "hold-lock", held, "2.5"])
deadline = time.time() + 20
while not os.path.exists(held) and time.time() < deadline:
    time.sleep(0.01)
assert os.path.exists(held), "the holder never took the lock"
store.LOCK_TIMEOUT_S = 0.4
began = time.monotonic()
try:
    store.register(root, tok("b"), "ios")
except OSError as e:
    assert e.errno == errno.ETIMEDOUT, e
else:
    raise AssertionError("register returned while another process held the lock")
waited = time.monotonic() - began
assert 0.3 <= waited < 2.0, "waited %.2f s for a 0.4 s timeout" % waited
assert store.load(root)["tokens"][0]["token"] == tok("a"), "a read needs no lock"
holder.wait(timeout=30)
store.LOCK_TIMEOUT_S = 3.0
store.register(root, tok("b"), "ios")
assert len(store.load(root)["tokens"]) == 2
print("gave up after %.2f s" % waited)
PYEOF

# ═══ Part B: the relay client's three commands ═════════════════════════════
# The REAL RelayClient, paired in-process with a fake phone through the real device_bound path. Only the
# POST is replaced: every frame the client would send is recorded as the phone would receive it, and
# ack() opens the newest one with the key the phone derived.
RIG='
import argparse, contextlib, importlib.util, io
from importlib.machinery import SourceFileLoader

GOOD = {"v": 1, "provider": "expo", "token": tok("G"), "platform": "ios", "ref": "9f3c2a1b7d4e6f80",
        "label": "api server", "events": ["question", "approval", "finished", "error", "gate_red"]}
SORTED_EVENTS = ["approval", "error", "finished", "gate_red", "question"]
NOPARAMS = object()   # the command carries no `params` key at all
MISSING = object()    # drop this field from the params


@contextlib.contextmanager
def env(name, value):
    old = os.environ.get(name)
    os.environ[name] = value
    try:
        yield
    finally:
        if old is None:
            os.environ.pop(name, None)
        else:
            os.environ[name] = old


def variant(**changes):
    params = dict(GOOD)
    for key, value in changes.items():
        if value is MISSING:
            params.pop(key, None)
        else:
            params[key] = value
    return params


class Rig:
    def __init__(self, seed=None, bind=True):
        loader = SourceFileLoader("hmd_relay_client_push_rig", CLIENT_PATH)
        spec = importlib.util.spec_from_loader(loader.name, loader)
        self.mod = importlib.util.module_from_spec(spec)
        loader.exec_module(self.mod)
        self.E2E = self.mod.E2E
        self.out = io.StringIO()
        self.repo = tempfile.mkdtemp(prefix="push-rig-", dir=TMPROOT)
        if seed is not None:
            seed(os.path.realpath(self.repo))   # what an earlier session left behind
        self.status = os.path.join(self.repo, "status.json")
        args = argparse.Namespace(relay="http://127.0.0.1:1", repo=self.repo, ui_port=0, public_host=None,
                                  status_file=self.status, tick_s=2.0)
        self.client = self.mod.RelayClient(args)
        self.root = self.client.root
        self.client.session_id, self.client.token = "sess-push-rig", "token-push-rig"
        self.client.priv, self.client.pub = self.E2E.generate_keypair()
        self.dev_priv, self.dev_pub = self.E2E.generate_keypair()
        self.dev_key = self.E2E.derive_session_key(self.dev_priv, self.client.pub, self.client.session_id)
        self.dev_seq = 0
        self.posts = []
        self.client.send_frame_envelope = self._post
        if bind:
            self.bind()

    def _post(self, type_, nonce, ciphertext, seq, **kwargs):
        self.posts.append({"type": type_, "seq": seq, "nonce": nonce, "ciphertext": ciphertext})
        return True, len(ciphertext)

    def handle(self, env_):
        with contextlib.redirect_stdout(self.out):
            self.client._handle_envelope(env_)

    def bind(self, pub=None):
        payload = {"device_pubkey": self.E2E.pub_b64(self.dev_pub if pub is None else pub), "bound_at": 1}
        self.handle({"v": 1, "session_id": self.client.session_id, "seq": 0, "sender": "relay",
                     "type": "device_bound", "nonce": None, "ciphertext": None, "payload": payload})

    def command(self, action, params=NOPARAMS):
        """The phone sends one sealed command; returns the ack hmd sealed back (opened with the phone key)."""
        obj = {"action": action}
        if params is not NOPARAMS:
            obj["params"] = params
        self.dev_seq += 1
        nonce, ct = self.E2E.seal(self.dev_key, self.dev_seq, "device", json.dumps(obj).encode("utf-8"))
        self.handle({"v": 1, "session_id": self.client.session_id, "seq": self.dev_seq, "sender": "device",
                     "type": "command", "nonce": nonce, "ciphertext": ct, "payload": None})
        return self.ack()

    def plaintext(self, post):
        return self.E2E.open_(self.dev_key, post["seq"], "hmd", post["nonce"], post["ciphertext"])

    def ack(self):
        return json.loads(self.plaintext([p for p in self.posts if p["type"] == "ack"][-1]))

    def caps(self):
        with contextlib.redirect_stdout(self.out):
            self.client.send_hmd_frame("state", {"state": {"a": 1}})
        return json.loads(self.plaintext([p for p in self.posts if p["type"] == "state"][-1]))["caps"]

    def events(self, name):
        rows = (json.loads(line) for line in self.out.getvalue().splitlines() if line.strip())
        return [e for e in rows if e.get("event") == name]
'

# ═══ 27. caps ═══════════════════════════════════════════════════════════════
py_case 27 "every state frame lists push-v1 in its caps -- and stops listing it with HMD_PUSH=0 or without the store" rig <<'PYEOF'
rig = Rig()
SENDER_CAPS = ["push-v1", "push-digest-v1"]  # the sender's own tokens: the morning report's rides the same kill switch
base = [c for c in rig.E2E.hmd_caps(rig.client._feature_caps()) if c not in SENDER_CAPS]  # every other token the client lists (resync, z-zlib, login-v1)
assert base and "resync" in base
assert rig.caps() == sorted(base + SENDER_CAPS), rig.caps()
with env("HMD_PUSH", "0"):
    assert rig.caps() == base, "the kill switch must withdraw the cap: %r" % rig.caps()
with env("HMD_PUSH", ""):
    assert "push-v1" in rig.caps(), "only the exact value 0 is the kill switch"
real = rig.mod.PUSH_STORE
rig.mod.PUSH_STORE = None
try:
    assert rig.caps() == base, "no store, no cap"
finally:
    rig.mod.PUSH_STORE = real
assert rig.caps() == sorted(base + SENDER_CAPS), "and it is back once the switch is off"
print(rig.caps())
PYEOF

# ═══ 28. register_push ══════════════════════════════════════════════════════
py_case 28 "register_push: the exact ack, the stored entry, and a command line that names the action and the verdict only" rig <<'PYEOF'
rig = Rig()
assert not os.path.exists(push_json(rig.root)), "pairing alone must not create a registry"
ack = rig.command("register_push", dict(GOOD))
assert ack == {"ok": True, "of_seq": 1, "ref": GOOD["ref"], "events": SORTED_EVENTS}, ack
got = store.load(rig.root)
assert len(got["tokens"]) == 1 and ISO.match(got["tokens"][0]["registered_at"]), got
assert got["tokens"][0] == {"token": GOOD["token"], "platform": "ios", "registered_at": got["tokens"][0]["registered_at"],
                            "ref": GOOD["ref"], "label": "api server", "events": SORTED_EVENTS}, got
assert got["app_state"] == "unknown"
assert rig.events("command") == [{"event": "command", "action": "register_push", "ok": True, "detail": None}], rig.events("command")
extra = rig.command("register_push", dict(GOOD, token=tok("X"), ref="fedcba9876543210", future_field="ignored"))
assert extra["ok"] is True, "an unknown key is ignored, as the other commands do"
print(json.dumps(ack, sort_keys=True))
PYEOF

# ═══ 29. idempotent ═════════════════════════════════════════════════════════
py_case 29 "register_push is an idempotent upsert; a rotated token (same ref) replaces the old one" rig <<'PYEOF'
rig = Rig()
rig.command("register_push", dict(GOOD))
assert rig.command("register_push", dict(GOOD))["ok"] is True
assert len(store.load(rig.root)["tokens"]) == 1
ack = rig.command("register_push", variant(token=tok("R"), platform="android", label="renamed", events=["error"]))
assert ack == {"ok": True, "of_seq": 3, "ref": GOOD["ref"], "events": ["error"]}, ack
got = store.load(rig.root)["tokens"]
assert [e["token"] for e in got] == [tok("R")], "the old token must be gone: one phone, one registration"
assert got[0]["platform"] == "android" and got[0]["label"] == "renamed" and got[0]["events"] == ["error"]
PYEOF

# ═══ 30. malformed register_push ════════════════════════════════════════════
py_case 30 "every malformed register_push is refused with the spec's detail code and writes nothing" rig <<'PYEOF'
cases = [
    ("params is a string", "x", "bad-params"), ("params is a list", [], "bad-params"), ("params is a number", 5, "bad-params"),
    ("params is null", None, "bad-params"), ("params absent", NOPARAMS, "bad-params"),
    ("v is 2", variant(v=2), "bad-version"), ("v is the string 1", variant(v="1"), "bad-version"),
    ("v is true", variant(v=True), "bad-version"), ("v is 1.0", variant(v=1.0), "bad-version"),
    ("v absent", variant(v=MISSING), "bad-version"), ("v is null", variant(v=None), "bad-version"),
    ("provider apns", variant(provider="apns"), "bad-provider"), ("provider EXPO", variant(provider="EXPO"), "bad-provider"),
    ("provider absent", variant(provider=MISSING), "bad-provider"), ("provider a list", variant(provider=["expo"]), "bad-provider"),
    ("token absent", variant(token=MISSING), "bad-token"), ("token null", variant(token=None), "bad-token"),
    ("token too short", variant(token=tok("a", 7)), "bad-token"), ("token a number", variant(token=5), "bad-token"),
    ("token is a raw device token", variant(token="f" * 64), "bad-token"), ("token with a newline", variant(token=tok("a") + "\n"), "bad-token"),
    ("platform windows", variant(platform="windows"), "bad-platform"), ("platform absent", variant(platform=MISSING), "bad-platform"),
    ("platform IOS", variant(platform="IOS"), "bad-platform"), ("platform a number", variant(platform=1), "bad-platform"),
    ("ref upper case", variant(ref="9F3C2A1B7D4E6F80"), "bad-ref"), ("ref 15 digits", variant(ref="9f3c2a1b7d4e6f8"), "bad-ref"),
    ("ref absent", variant(ref=MISSING), "bad-ref"), ("ref null", variant(ref=None), "bad-ref"), ("ref a number", variant(ref=7), "bad-ref"),
    ("label empty", variant(label=""), "bad-label"), ("label blank", variant(label="   "), "bad-label"),
    ("label with a slash", variant(label="a/b"), "bad-label"), ("label with a backslash", variant(label="a\\b"), "bad-label"),
    ("label 25 units", variant(label="x" * 25), "bad-label"), ("label with a newline", variant(label="a\nb"), "bad-label"),
    ("label absent", variant(label=MISSING), "bad-label"), ("label a number", variant(label=5), "bad-label"),
    ("events empty", variant(events=[]), "bad-events"), ("events with test", variant(events=["test"]), "bad-events"),
    ("events a string", variant(events="question"), "bad-events"), ("events with a duplicate", variant(events=["error", "error"]), "bad-events"),
    ("events absent", variant(events=MISSING), "bad-events"), ("events an object", variant(events={"error": 1}), "bad-events"),
    ("events holding an object", variant(events=[{"a": 1}]), "bad-events"),
    ("version is checked before the token", variant(v=2, token="x"), "bad-version"),
    ("provider before the token", variant(provider="x", token="x"), "bad-provider"),
    ("token before the platform", variant(token="x", platform="x"), "bad-token"),
    ("platform before the ref", variant(platform="x", ref="x"), "bad-platform"),
    ("ref before the label", variant(ref="x", label=""), "bad-ref"),
    ("label before the events", variant(label="", events=[]), "bad-label"),
]
rig = Rig()
for name, params, detail in cases:
    ack = rig.command("register_push", params)
    assert ack == {"ok": False, "of_seq": rig.dev_seq, "detail": detail}, (name, ack)
    assert store.load(rig.root) == DEFAULT, "%s: a refused registration must write nothing" % name
    assert not os.path.exists(push_json(rig.root)), name
commands = rig.events("command")
assert len(commands) == len(cases) and all(c["ok"] is False and c["action"] == "register_push" for c in commands)
assert [c["detail"] for c in commands] == [c[2] for c in cases]
assert rig.command("register_push", dict(GOOD))["ok"] is True, "and a good one still goes through afterwards"
print("%d refusals" % len(cases))
PYEOF

# ═══ 31. unregister_push ════════════════════════════════════════════════════
py_case 31 "unregister_push: removed true then false, an unknown ref is not an error, a malformed one is bad-ref" rig <<'PYEOF'
rig = Rig()
other = variant(token=tok("O"), ref="fedcba9876543210")
rig.command("register_push", dict(GOOD))
rig.command("register_push", other)
ack = rig.command("unregister_push", {"ref": GOOD["ref"]})
assert ack == {"ok": True, "of_seq": 3, "ref": GOOD["ref"], "removed": True}, ack
assert [e["ref"] for e in store.load(rig.root)["tokens"]] == [other["ref"]]
assert rig.command("unregister_push", {"ref": GOOD["ref"]}) == {"ok": True, "of_seq": 4, "ref": GOOD["ref"], "removed": False}
assert rig.command("unregister_push", {"ref": "1111111111111111"}) == {"ok": True, "of_seq": 5, "ref": "1111111111111111", "removed": False}
for name, params in (("ref upper case", {"ref": GOOD["ref"].upper()}), ("ref short", {"ref": "abc"}), ("ref absent", {}),
                     ("ref null", {"ref": None}), ("ref a number", {"ref": 5}), ("ref a list", {"ref": [GOOD["ref"]]}),
                     ("the token instead of the ref", {"token": GOOD["token"]})):
    assert rig.command("unregister_push", params) == {"ok": False, "of_seq": rig.dev_seq, "detail": "bad-ref"}, name
for params in ("x", [], 5, None, NOPARAMS):
    assert rig.command("unregister_push", params) == {"ok": False, "of_seq": rig.dev_seq, "detail": "bad-params"}, params
assert [e["ref"] for e in store.load(rig.root)["tokens"]] == [other["ref"]], "no refusal may remove anything"
assert [c["action"] for c in rig.events("command")][:3] == ["register_push", "register_push", "unregister_push"]
PYEOF

# ═══ 32. app_state ══════════════════════════════════════════════════════════
py_case 32 "app_state: active and background are stored (as foreground / background) and acked bare; anything else is bad-state" rig <<'PYEOF'
rig = Rig()
assert rig.command("app_state", {"state": "active"}) == {"ok": True, "of_seq": 1}
got = store.load(rig.root)
assert got["app_state"] == "foreground" and ISO.match(got["app_state_at"]) and got["tokens"] == [], got
assert rig.command("app_state", {"state": "background"}) == {"ok": True, "of_seq": 2}
assert store.load(rig.root)["app_state"] == "background"
for given in ("inactive", "ACTIVE", "foreground", "", None, 1, True, ["active"], {"state": "active"}):
    assert rig.command("app_state", {"state": given}) == {"ok": False, "of_seq": rig.dev_seq, "detail": "bad-state"}, given
assert rig.command("app_state", {}) == {"ok": False, "of_seq": rig.dev_seq, "detail": "bad-state"}
for params in ("active", [], 5, None, NOPARAMS):
    assert rig.command("app_state", params) == {"ok": False, "of_seq": rig.dev_seq, "detail": "bad-params"}, params
assert store.load(rig.root)["app_state"] == "background", "a refusal must change nothing"
assert [c["detail"] for c in rig.events("command")][:3] == [None, None, "bad-state"]
PYEOF

# ═══ 33. push disabled ══════════════════════════════════════════════════════
py_case 33 "HMD_PUSH=0, or no store module: all three commands ack push-disabled and nothing is written" rig <<'PYEOF'
rig = Rig()
with env("HMD_PUSH", "0"):
    for action, params in (("register_push", dict(GOOD)), ("unregister_push", {"ref": GOOD["ref"]}),
                           ("app_state", {"state": "active"}), ("register_push", "x"), ("app_state", NOPARAMS)):
        assert rig.command(action, params) == {"ok": False, "of_seq": rig.dev_seq, "detail": "push-disabled"}, action
assert not os.path.exists(push_json(rig.root)), "a disabled hmd must write nothing"
assert rig.command("register_push", dict(GOOD))["ok"] is True, "the switch is read per command"
gone = Rig()
gone.mod.PUSH_STORE = None
for action, params in (("register_push", dict(GOOD)), ("unregister_push", {"ref": GOOD["ref"]}), ("app_state", {"state": "active"})):
    assert gone.command(action, params) == {"ok": False, "of_seq": gone.dev_seq, "detail": "push-disabled"}, action
PYEOF

# ═══ 34. write-failed ═══════════════════════════════════════════════════════
py_case 34 "an unwritable store is write-failed, never a crash, and the refusal repeats nothing the phone sent" rig <<'PYEOF'
def blocker(root):   # .heimdall/app is a FILE, so nothing can be created under it
    os.makedirs(os.path.join(root, ".heimdall"))
    open(os.path.join(root, ".heimdall", "app"), "w").write("not a directory")
rig = Rig(seed=blocker)
assert rig.command("register_push", dict(GOOD)) == {"ok": False, "of_seq": 1, "detail": "write-failed"}
assert rig.command("app_state", {"state": "active"}) == {"ok": False, "of_seq": 2, "detail": "write-failed"}
assert rig.command("unregister_push", {"ref": GOOD["ref"]}) == {"ok": True, "of_seq": 3, "ref": GOOD["ref"], "removed": False}
assert [c["detail"] for c in rig.events("command")] == ["write-failed", "write-failed", None]
assert not rig.events("error"), rig.events("error")
assert GOOD["token"] not in rig.out.getvalue()
PYEOF

# ═══ 35. no token anywhere ══════════════════════════════════════════════════
py_case 35 "the token (and label) appear in no event line, no ack and no status file, whatever the phone sends" rig <<'PYEOF'
rig = Rig()
rig.command("register_push", dict(GOOD))
rig.command("register_push", variant(token=tok("B"), ref="fedcba9876543210", label="second laptop"))
rig.command("register_push", variant(token=tok("C"), ref="bad"))
rig.command("register_push", variant(token=tok("D"), v=2))
rig.command("app_state", {"state": "active"})
rig.command("unregister_push", {"ref": "fedcba9876543210"})
rig.command("unregister_push", {"token": tok("B")})
with env("HMD_PUSH", "0"):
    rig.command("register_push", variant(token=tok("E")))
logged = rig.out.getvalue() + open(rig.status).read()
sealed = " ".join(rig.plaintext(p).decode("utf-8") for p in rig.posts)
secrets_ = [tok(c) for c in "GBCDE"] + ["api server", "second laptop"]
for s in secrets_:
    assert s not in logged, "a secret reached an event line or the status file: %r" % s[:14]
    assert s not in sealed, "a secret was echoed in an ack: %r" % s[:14]
events = [json.loads(line) for line in rig.out.getvalue().splitlines() if line.strip()]
commands = [e for e in events if e["event"] == "command"]
assert len(commands) == 8 and all(set(c) == {"event", "action", "ok", "detail"} for c in commands), commands
print("%d command lines, 7 secrets absent from %d bytes of logs and %d bytes of acks" % (len(commands), len(logged), len(sealed)))
PYEOF

# ═══ 36. device_bound ═══════════════════════════════════════════════════════
py_case 36 "device_bound: an earlier session's registrations go at the first bind; a same-device repeat and a refused other device leave them" rig <<'PYEOF'
def stale(root):
    store.register(root, tok("old"), "ios", ref="aaaaaaaaaaaaaaaa", label="old", events=["error"])
    store.register(root, tok("older"), "android")
    store.set_app_state(root, "foreground")
seeded = fresh()
stale(seeded)
assert len(store.load(seeded)["tokens"]) == 2, "the seed must really leave registrations behind"
rig = Rig(seed=stale)
assert store.load(rig.root) == DEFAULT, "a new pairing must not inherit the last pairing's tokens: %r" % store.load(rig.root)
assert not rig.events("error"), rig.events("error")
assert not os.path.exists(push_json(Rig().root)), "a fresh pairing with nothing stale writes nothing"
rig.command("register_push", dict(GOOD))
rig.command("app_state", {"state": "background"})
before = store.load(rig.root)
assert len(before["tokens"]) == 1 and before["app_state"] == "background"
rig.bind()                                           # the same phone again: a stream reconnect
assert store.load(rig.root) == before, "a same-device repeat must keep the registrations"
assert len(rig.events("device_bound")) == 2
_, other_pub = rig.E2E.generate_keypair()
rig.bind(other_pub)                                  # another device: refused by the latch, and so left alone
assert any("differs from the already latched" in e["detail"] for e in rig.events("error")), rig.events("error")
assert store.load(rig.root) == before, "a refused device_bound must not touch the registrations"
assert rig.command("app_state", {"state": "active"}) == {"ok": True, "of_seq": 3}, "and the paired phone still works"
with env("HMD_PUSH", "0"):
    off = Rig(seed=stale)
assert store.load(off.root) == DEFAULT, "stale tokens go even when push is switched off"
PYEOF

echo ""
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
