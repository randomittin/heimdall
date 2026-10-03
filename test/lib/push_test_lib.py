#!/usr/bin/env python3
"""test/lib/push_test_lib.py -- support for test/companion-push.test.sh.

  FakeExpo   a loopback stand-in for the Expo Push Service (POST .../push/send and .../push/getReceipts)
             that records every request and can be scripted to fail: HTTP errors, ticket errors, a hang.
             Nothing in the suite ever talks to the real service: every sender under test is pointed at
             one of these through HMD_PUSH_EXPO_URL.
  FileStore  the push-store interface the sender codes against (load / remove_tokens), backed by one JSON
             file so two PROCESSES can share it. A test double, not the production store.
  attention / approval / state   builders for the slices of the /api/state contract the sender reads,
             with a distinct marker string planted in every free-text field the sender must never use.

Token-shaped and secret-shaped inputs are assembled from parts at RUNTIME -- no such literal is written
anywhere in the repo. Stdlib only.
"""
import copy
import json
import os
import tempfile
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from importlib.util import module_from_spec, spec_from_file_location

SEND_PATH = "/--/api/v2/push/send"
RECEIPTS_PATH = "/--/api/v2/push/getReceipts"


def load(name, path):
    spec = spec_from_file_location(name, path)
    mod = module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def verdict(passed, text):
    """One tally line the bash harness forwards: `ok <text>` or `bad <text>`."""
    print(("ok " if passed else "bad ") + text, flush=True)


def check(cond, text, got=None):
    verdict(bool(cond), text)
    if not cond and got is not None:
        print("   got: %r" % (got,), flush=True)


def eq(actual, expected, text):
    verdict(actual == expected, text)
    if actual != expected:
        print("   got:  %r" % (actual,), flush=True)
        print("   want: %r" % (expected,), flush=True)


def expo_token(tag="a", n=22):
    """A token-shaped string assembled at runtime (never a literal in the repo)."""
    return "".join(("Exponent", "Push", "Token", "[", tag * n, "]"))


def ghp_shaped():
    """A GitHub-token-shaped string, assembled at runtime."""
    return "".join(("gh", "p_", "Q" * 36))


def session_ref(digit="7"):
    """A session ref -- 16 lowercase hex digits, the one session handle a notification may carry -- assembled at
    runtime. A hex literal written beside a label such as "api server" reads as a generic API key to a secret
    scanner, so no ref literal sits in the repo."""
    return digit * 16


def iso(epoch):
    """Epoch seconds -> the production store's timestamp form: ISO-8601 UTC, whole seconds, trailing Z."""
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(epoch))


class FakeExpo:
    """Loopback Expo Push Service. `script` holds one dict per upcoming /send request, consumed in order:
        {"status": 500, "body": {...}}   an HTTP error
        {"tickets": [...]}               a 200 with exactly these tickets
        {"hang": 3.0}                    sleep this long before answering (the client's timeout fires first)
    With the script empty a /send answers an ok ticket per message, or DeviceNotRegistered for a token in
    `unregistered`; /getReceipts answers DeviceNotRegistered for tickets of tokens in `receipt_unregistered`."""

    def __init__(self):
        self.requests = []
        self.script = []
        self.unregistered = set()
        self.receipt_unregistered = set()
        self._lock = threading.Lock()
        self._ids = 0
        self._ticket_token = {}
        fake = self

        class Handler(BaseHTTPRequestHandler):
            protocol_version = "HTTP/1.1"

            def log_message(self, fmt, *args):
                return None

            def do_POST(self):
                raw = self.rfile.read(int(self.headers.get("Content-Length") or 0))
                try:
                    body = json.loads(raw.decode("utf-8"))
                except ValueError:
                    body = None
                status, reply, delay = fake._answer(self.path, body, dict(self.headers.items()), len(raw))
                if delay:
                    time.sleep(delay)
                data = json.dumps(reply).encode("utf-8")
                try:
                    self.send_response(status)
                    self.send_header("Content-Type", "application/json")
                    self.send_header("Content-Length", str(len(data)))
                    self.end_headers()
                    self.wfile.write(data)
                except OSError:
                    return None

        class Server(ThreadingHTTPServer):
            daemon_threads = True

            def handle_error(self, request, client_address):
                return None

        self.httpd = Server(("127.0.0.1", 0), Handler)
        self.port = self.httpd.server_address[1]
        threading.Thread(target=self.httpd.serve_forever, kwargs={"poll_interval": 0.05}, daemon=True).start()

    @property
    def url(self):
        return "http://127.0.0.1:%d%s" % (self.port, SEND_PATH)

    def _new_ticket(self, token):
        with self._lock:
            self._ids += 1
            tid = "ticket-%d" % self._ids
            self._ticket_token[tid] = token
        return {"status": "ok", "id": tid}

    def _answer(self, path, body, headers, nbytes):
        with self._lock:
            self.requests.append({"path": path, "body": body, "headers": headers, "bytes": nbytes,
                                  "at": time.time()})
            scripted = self.script.pop(0) if (self.script and path == SEND_PATH) else None
        if path == SEND_PATH:
            delay = (scripted or {}).get("hang", 0)
            if scripted and scripted.get("status", 200) != 200:
                return scripted["status"], scripted.get("body", {}), delay
            if scripted and "tickets" in scripted:
                return 200, {"data": scripted["tickets"]}, delay
            tickets = []
            for message in body if isinstance(body, list) else []:
                token = message.get("to") if isinstance(message, dict) else None
                if token in self.unregistered:
                    tickets.append({"status": "error", "message": "gone",
                                    "details": {"error": "DeviceNotRegistered"}})
                else:
                    tickets.append(self._new_ticket(token))
            return 200, {"data": tickets}, delay
        if path == RECEIPTS_PATH:
            data = {}
            for tid in (body.get("ids") if isinstance(body, dict) else None) or []:
                if self._ticket_token.get(tid) in self.receipt_unregistered:
                    data[tid] = {"status": "error", "message": "gone", "details": {"error": "DeviceNotRegistered"}}
                else:
                    data[tid] = {"status": "ok"}
            return 200, {"data": data}, 0
        return 404, {}, 0

    def sends(self):
        with self._lock:
            return [r for r in self.requests if r["path"] == SEND_PATH]

    def receipt_requests(self):
        with self._lock:
            return [r for r in self.requests if r["path"] == RECEIPTS_PATH]

    def messages(self):
        out = []
        for r in self.sends():
            out.extend(r["body"] if isinstance(r["body"], list) else [])
        return out

    def close(self):
        self.httpd.shutdown()
        self.httpd.server_close()


class FileStore:
    """The interface companion_push codes against -- load(root) / remove_tokens(root, tokens) -- over one JSON
    file, so two processes can share it, in the production store's wire form (bin/lib/companion_push_store.py:
    ISO-8601 UTC `registered_at` and `app_state_at`). seed() takes `app_state_at` as epoch seconds on the
    test's own clock and writes it the way the production store does. `removed()` lists what remove_tokens was
    asked to drop. Part F of the suite runs the sender against the production store itself."""

    def __init__(self, path):
        self.path = path

    def _read(self):
        try:
            with open(self.path, "r", encoding="utf-8") as f:
                return json.load(f)
        except (OSError, ValueError):
            return {"tokens": [], "app_state": "unknown", "app_state_at": None, "removed": []}

    def _write(self, data):
        fd, tmp = tempfile.mkstemp(dir=os.path.dirname(self.path), prefix=".fs-")
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            json.dump(data, f)
        os.replace(tmp, self.path)

    def seed(self, tokens, app_state="unknown", app_state_at=None):
        entries = [t if isinstance(t, dict) else {"token": t, "platform": "ios", "registered_at": iso(1)}
                   for t in tokens]
        self._write({"tokens": entries, "app_state": app_state,
                     "app_state_at": None if app_state_at is None else iso(app_state_at), "removed": []})

    def load(self, root):
        data = self._read()
        return copy.deepcopy({"tokens": data["tokens"], "app_state": data["app_state"],
                              "app_state_at": data["app_state_at"]})

    def remove_tokens(self, root, tokens):
        data = self._read()
        gone = set(tokens)
        data["removed"].extend(t["token"] for t in data["tokens"] if t["token"] in gone)
        data["tokens"] = [t for t in data["tokens"] if t["token"] not in gone]
        self._write(data)

    def removed(self):
        return self._read()["removed"]


# ── builders for the slices of /api/state the sender reads ───────────────────────────────────────
# A distinct marker sits in every free-text field the sender must NEVER put in a notification.
LEAK = {"repo": "LEAKrepoQ1", "branch": "LEAKbranchQ2", "edit": "LEAKeditQ3", "panel": "LEAKpanelQ4",
        "reason": "LEAKreasonQ5", "handle": "LEAKhandleQ6", "sha": "LEAKshaQ7", "cmd": "LEAKcommandQ8",
        "gate": "LEAKgatedetailQ9", "chat": "LEAKchatQ10", "team": "LEAKteamQ11"}
LEAK_VALUES = tuple(LEAK.values())


def a_id(n):
    return "a-%010x" % n


def p_id(n):
    return "p-%08x" % n


def attention(state="idle", id=None, kind=None, summary=None, options=None):
    return {"state": state, "id": id, "since": None, "kind": kind, "summary": summary,
            "options": options, "turn": None}


def approval(id=None, tool="Bash", expires_at=None):
    return {"id": id or p_id(1), "tool": tool, "summary": "git push " + LEAK["cmd"],
            "requested_at": 0, "expires_at": expires_at, "risk": "high"}


def state(att=None, approvals=(), gate=None, gates=None, receipt=None, ts=None):
    return {
        "schema_version": 1, "ts": ts, "repo": "/work/" + LEAK["repo"],
        "identity": {"handle": LEAK["handle"], "haid": "haid_" + LEAK["handle"], "branch": LEAK["branch"],
                     "session_code": "ABCDE"},
        "ledger": {"daemon": "up", "gates": list(gates or []), "verdict": {"state": "pass", "label": LEAK["gate"]},
                   "team": [{"user": LEAK["team"], "branch": LEAK["branch"], "state": "pass"}],
                   "team_overflow": 0},
        "roster": [{"handle": LEAK["handle"], "branch": LEAK["branch"], "project": LEAK["repo"]}],
        "quality_gate": {"clear_to_push": gate, "reason": "GATE FAILED: " + LEAK["reason"]},
        "sweep_receipt": receipt,
        "checkpoint": {"branch": LEAK["branch"], "head": LEAK["sha"], "phase": LEAK["chat"]},
        "edits": {"count": 1, "paths": ["src/" + LEAK["edit"] + ".py"]},
        "panels": [{"id": "chat", "title": "Chat", "type": "log-tail",
                    "data": {"lines": ["10:00 you " + LEAK["chat"]]}},
                   {"id": "probe", "title": LEAK["panel"], "type": "markdown", "data": {"text": LEAK["panel"]}}],
        "approvals": list(approvals),
        "attention": att if att is not None else attention(),
    }


def receipt(finished_at="2026-10-03T10:00:00Z", passed=427, total=427, duration_s=2239):
    return {"finished_at": finished_at, "head_sha": LEAK["sha"], "tree_clean": True, "suites_total": total,
            "suites_passed": passed, "suites_failed": total - passed, "duration_s": duration_s}


def gate_rows(failing, total):
    return [{"id": "g%d" % i, "state": "deny" if i < failing else "pass", "detail": LEAK["gate"]}
            for i in range(total)]
