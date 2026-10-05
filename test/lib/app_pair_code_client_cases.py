#!/usr/bin/env python3
"""test/lib/app_pair_code_client_cases.py -- the REAL bin/heimdall-relay-client, `--code` mode, against
test/lib/fake_relay_code.py (the relay's pair-by-session-code surface, hmdapp's
docs/superpowers/specs/2026-10-05-pair-by-session-code.md sections 5 and 6). Run by
test/app-pair-code.test.sh; the heimdall-app half is test/lib/app_pair_code_app_cases.py.

What is proven here, each against the shipped client and a loopback relay:
  * the shared known-answer vectors (commitment, SAS 817531 / 006173), against an independent hashlib reference;
  * registration: POST /session/:id/code carries {code, gh_token, hmd_commit} and nothing else; the token
    is read from stdin only and is on no disk, argv or output the client produced;
  * every refusal the relay can answer maps to one code_unavailable reason, and the QR flow stays alive;
  * a phone that claimed by code gets a plaintext key_reveal whose commitment opens to the registered one,
    the SAS the client shows equals the independent one, and NOTHING is sealed until `approve` arrives
    (a stray early `approve` approves nothing); reject, timeout and a closed control input all revoke and
    the window renews; --no-confirm approves by itself;
  * a QR bind in a code-registered session pairs as before; renewal registers the same code with a fresh
    commitment and fresh keys until the window total ends, and the stream follows each new session.
"""
import hashlib
import json
import os
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.realpath(__file__)))
import pair_code_harness as H  # noqa: E402
from fake_relay_code import FakeCodeRelay  # noqa: E402

T = H.Tally()
CLIENT = H.load_module("hmd_relay_client", H.CLIENT_PATH)
E2E = H.load_module("hmd_relay_e2e", H.E2E_PATH)


class Scenario:
    def __init__(self, ttl=60, gh_login="octocat", expect_token=H.TOKEN):
        self.sb = H.Sandbox()
        self.relay = FakeCodeRelay(ttl_s=ttl, gh_login=gh_login, expect_token=expect_token).start()
        self.phone = H.Phone(E2E)
        self.procs = []

    def __enter__(self):
        return self

    def __exit__(self, *_exc):
        for proc in self.procs:
            proc.stop()
        self.relay.stop()
        self.sb.close()

    def client(self, token=H.TOKEN, code=H.CODE, extra=(), env=None, close_stdin=False):
        argv = [H.CLIENT_PATH, "--relay", self.relay.url, "--repo", self.sb.repo, "--ui-port", "1"]
        if code is not None:
            argv += ["--code", code]
        argv += list(extra)
        proc = H.Proc(argv, self.sb.env(**(env or {})))
        self.procs.append(proc)
        if token is not None:
            proc.send(token + "\n")
        if close_stdin:
            proc.close_stdin()
        return proc

    def bind(self, via="code", label="Pixel 9a", sid=None, phone=None):
        """The phone claims the newest session; what the relay tells hmd about it."""
        sid = sid or self.relay.latest().id
        self.relay.inject_device_bound(sid, (phone or self.phone).pub_b64url, via=via, device_label=label)
        return sid


def pair_inits(proc):
    return [ev for ev in proc.events() if ev.get("event") == "pair_init"]


def hmd_pub_of(proc, index=0):
    return H.b64_any(pair_inits(proc)[index]["qr"]["hmd_pubkey"])


def sealed_frames(relay, sid):
    return relay.frames_of(sid, "state") + relay.frames_of(sid, "ack")


# -- pure functions ---------------------------------------------------------------------------------
def case_vectors_and_helpers():
    v = json.load(open(H.VECTORS_PATH))
    sid, exp = v["session_id"], v["expected"]

    def raw(label):
        return hashlib.sha256(v["labels"][label].encode()).digest()

    hmd_pub, dev_pub, mitm_pub, nonce = raw("hmd_pubkey"), raw("device_pubkey"), raw("device_pubkey_mitm"), raw("nonce_h")
    T.check(CLIENT.b64url(CLIENT.commit_for(hmd_pub, nonce)) == exp["hmd_commit_b64url"],
            "shared vector: hmd_commit matches hmdapp's docs/samples/pair-code-vectors.json")
    T.check(CLIENT.sas_for(sid, hmd_pub, dev_pub) == exp["sas"] == "817531", "shared vector: SAS 817531")
    T.check(CLIENT.sas_for(sid, hmd_pub, mitm_pub) == exp["sas_mitm"] == "006173",
            "shared vector: a substituted device key gives 006173 (leading zeros kept)")
    T.check(H.commit_ref(hmd_pub, nonce) == exp["hmd_commit_b64url"] and H.sas_ref(sid, hmd_pub, dev_pub) == exp["sas"],
            "the fixture agrees with an independent hashlib computation (the fixture itself is sound)")
    T.check(len({CLIENT.sas_for(sid, hmd_pub, dev_pub), CLIENT.sas_for(sid + "x", hmd_pub, dev_pub),
                 CLIENT.sas_for(sid, mitm_pub, dev_pub), CLIENT.sas_for(sid, hmd_pub, mitm_pub)}) == 4,
            "the SAS binds the session id, hmd's key and the device's key")
    good = ["4SELK", "ABCDE", "23456", "ZZZZZ"]
    bad = ["", "4SEL", "4SELKK", "4SEL0", "4SELI", "4SELO", "4SEL1", "4selk", "4SE K", None, 12345]
    T.check(all(CLIENT.valid_code(c) for c in good) and not any(CLIENT.valid_code(c) for c in bad),
            "valid_code: exactly 5 characters of hmd's 32-symbol alphabet")
    T.check(CLIENT.clean_text("Pi\x1b[2Jxel\x00 \x07\x7f\u0085\u009f9a", 32) == "Pi[2Jxel 9a"
            and CLIENT.clean_text("x" * 40, 32) == "x" * 32,
            "clean_text strips C0, ESC, DEL and C1 code points and caps the length")
    T.check(all(CLIENT.valid_login(l) for l in ("octocat", "a-b", "A1"))
            and not any(CLIENT.valid_login(l) for l in ("bad login", "x\x1b", "", "a" * 40, None)),
            "valid_login: a GitHub login's characters and length, nothing else")


# -- registration -----------------------------------------------------------------------------------
def case_registration_and_hygiene():
    with Scenario() as s:
        log = os.path.join(s.sb.repo, ".heimdall", "app", "relay-events.jsonl")
        c = s.client(env={"HMD_RELAY_EVENT_LOG": log})
        pi = c.wait_event("pair_init")
        cw = c.wait_event("code_window")
        T.check(bool(pi) and bool(cw) and cw["code"] == H.CODE and cw["gh_login"] == "octocat"
                and cw["exp"] == s.relay.latest().exp, "registration: code_window carries the code, the login and the relay's exp",
                c.tail())
        reg = s.relay.registrations[0] if s.relay.registrations else {}
        T.check(reg.get("keys") == ["code", "gh_token", "hmd_commit"] and reg.get("code") == H.CODE
                and reg.get("session_id") == (pi or {}).get("qr", {}).get("session_id")
                and reg.get("token_ok") is True and reg.get("content_type") == "application/json",
                "registration: POST /session/:id/code carries code, gh_token and hmd_commit and nothing else", str(reg))
        T.check(len(reg.get("hmd_commit", "")) == 43, "registration: hmd_commit is 32 bytes, base64url without padding")
        argv = H.argv_of(c.pid)
        c.stop()
        needle = H.TOKEN.encode()
        T.check(needle not in argv.encode() and H.TOKEN not in argv, "hygiene: the token is not in the client's argv")
        T.check(needle not in c.out() and needle not in c.err(), "hygiene: the token is in neither stdout nor stderr")
        T.check(os.path.isfile(log) and "code_window" in open(log).read(), "hygiene: the event log exists (the scan below means something)")
        T.check(H.files_containing(s.sb.root, needle) == [], "hygiene: the token is on no disk -- event log, status file, anywhere in the sandbox",
                str(H.files_containing(s.sb.root, needle)))


def case_no_token():
    for label, kwargs in (("stdin closed", {"token": None, "close_stdin": True}), ("an empty line", {"token": ""})):
        with Scenario() as s:
            c = s.client(**kwargs)
            ev = c.wait_event("code_unavailable")
            T.check(bool(ev) and ev["reason"] == "no-gh" and pair_inits(c) and s.relay.registrations == [] and c.rc is None,
                    "no token (%s): code_unavailable no-gh, nothing registered, the QR flow keeps running" % label, c.tail())
    with Scenario() as s:
        c = s.client(code="4sel0", token=None)
        rc = c.wait_exit(5)
        T.check(rc == 2 and b"--code" in c.err(), "a malformed --code is a usage error (exit 2) before anything is sent", c.tail())
    with Scenario() as s:
        master, slave = os.openpty()
        proc = H.Proc([H.CLIENT_PATH, "--relay", s.relay.url, "--repo", s.sb.repo, "--ui-port", "1", "--code", H.CODE],
                      s.sb.env(), stdin=slave)
        s.procs.append(proc)
        os.close(slave)
        ev = proc.wait_event("code_unavailable", timeout=4)
        os.close(master)
        T.check(bool(ev) and ev["reason"] == "no-gh" and s.relay.registrations == [],
                "a terminal on stdin is never read for a token (it would echo): code_unavailable, no wait", proc.tail())


REFUSALS = (
    (409, {"error": "code in use by another open window"}, "conflict"),
    (503, {"error": "code pairing disabled"}, "disabled"),
    (401, {"error": "github token rejected"}, "no-gh"),
    (401, {"error": "unauthorized"}, "http-401"),
    (410, {"error": "session no longer claimable"}, "http-410"),
    (429, {"error": "too many code registrations", "retry_after_s": 60}, "http-429"),
    (502, {"error": "github unavailable"}, "http-502"),
)


def case_refusals():
    for status, body, reason in REFUSALS:
        with Scenario(ttl=2) as s:
            s.relay.code_status = lambda _reg, st=status, bd=body: (st, bd)
            c = s.client(env={"HMD_RELAY_CODE_RENEW_MARGIN_S": "0.2", "HMD_RELAY_CODE_RENEW_MIN_S": "0.5"})
            ev = c.wait_event("code_unavailable")
            time.sleep(3.2 if status == 409 else 0)  # a refusal ends code mode: no renewal follows, a whole TTL later
            T.check(bool(ev) and ev["reason"] == reason and pair_inits(c) and len(s.relay.registrations) == 1 and c.rc is None
                    and c.count_events("code_window") == 0,
                    "relay answers %d -> code_unavailable %s, one attempt, QR flow alive" % (status, reason), c.tail())


# -- approval ---------------------------------------------------------------------------------------
def await_request(s, c, **kw):
    sid = s.bind(**kw)
    return sid, c.wait_event("approve_request", timeout=10)


def case_approve_flow():
    with Scenario() as s:
        c = s.client()
        c.wait_event("code_window")
        c.send("approve\n")  # a stray early answer must approve nothing that has not been asked yet
        time.sleep(0.3)
        sid, req = await_request(s, c)
        reveals = s.relay.frames_of(sid, "key_reveal")
        T.check(len(reveals) == 1 and bool(req), "bind via code: exactly one key_reveal is posted before approve_request", c.tail())
        kr = reveals[0] if reveals else {"payload": {"hmd_pubkey": "", "nonce": ""}}
        hmd_pub, nonce = H.b64_any(kr["payload"]["hmd_pubkey"]), H.b64_any(kr["payload"]["nonce"])
        T.check(kr.get("sender") == "hmd" and kr.get("type") == "key_reveal" and kr.get("v") == 1 and kr.get("seq") == 0
                and kr.get("nonce") is None and kr.get("ciphertext") is None and len(hmd_pub) == 32 and len(nonce) == 32,
                "key_reveal: a plaintext hmd envelope (seq 0, no ciphertext) carrying two 32-byte values", str(kr))
        T.check(hmd_pub == hmd_pub_of(c), "key_reveal: it reveals the very key the QR carries")
        T.check(H.commit_ref(hmd_pub, nonce) == s.relay.registrations[0]["hmd_commit"],
                "key_reveal: SHA256(domain || key || nonce) opens the commitment registered before any phone key existed")
        T.check(req["sas"] == H.sas_ref(sid, hmd_pub, s.phone.pub) and req["device_label"] == "Pixel 9a"
                and req["gh_login"] == "octocat" and req["timeout_s"] == 60 and "auto" not in req,
                "approve_request: the SAS equals the independent one; the label and the login ride along", str(req))
        time.sleep(1.0)
        T.check(sealed_frames(s.relay, sid) == [] and c.count_events("device_bound") == 0,
                "nothing is sealed or sent and the session is not paired until the laptop approves (a stray early approve counted for nothing)",
                c.tail())
        c.send("approve\n")
        bound = c.wait_event("device_bound")
        c.wait_for(lambda: s.relay.frames_of(sid, "state"), 15)
        states = s.relay.frames_of(sid, "state")
        opened = s.phone.open_hmd_frame(hmd_pub, sid, states[0]) if states else None
        T.check(bool(bound) and opened is not None and "state" in opened,
                "approve: the session pairs and the first state frame opens under the key derived from the revealed key", c.tail())
        T.check(c.count_events("approve_request") == 1 and len(s.relay.registrations) == 1,
                "approve: the window is done -- no second request, no renewal")


def case_reject_timeout_eof():
    with Scenario() as s:
        c = s.client()
        c.wait_event("code_window")
        sid, req = await_request(s, c)
        c.send("reject\n")
        ev = c.wait_event("code_rejected")
        c.wait_for(lambda: len(s.relay.registrations) >= 2, 10)
        T.check(bool(ev) and ev["reason"] == "operator" and sid in s.relay.revokes and len(s.relay.registrations) >= 2
                and s.relay.registrations[1]["code"] == H.CODE and s.relay.registrations[1]["session_id"] != sid
                and sealed_frames(s.relay, sid) == [] and c.count_events("device_bound") == 0,
                "reject: the session is revoked, nothing was sealed, and the window renews with the same code", c.tail())
    with Scenario() as s:
        c = s.client(env={"HMD_RELAY_APPROVAL_TIMEOUT_S": "1.5"})
        c.wait_event("code_window")
        sid, req = await_request(s, c)
        ev = c.wait_event("code_rejected", timeout=8)
        T.check(bool(req) and req["timeout_s"] == 1.5 and bool(ev) and ev["reason"] == "timeout" and sid in s.relay.revokes
                and c.count_events("device_bound") == 0, "no answer in time: the pairing is revoked (reason timeout)", c.tail())
    with Scenario() as s:
        c = s.client()
        c.wait_event("code_window")
        sid, req = await_request(s, c)
        c.close_stdin()
        ev = c.wait_event("code_rejected", timeout=8)
        T.check(bool(ev) and ev["reason"] == "eof" and sid in s.relay.revokes and c.count_events("device_bound") == 0,
                "the control input closing with an approval pending fails closed (reason eof)", c.tail())


def case_no_confirm_and_qr_bind():
    with Scenario() as s:
        c = s.client(extra=("--no-confirm",))
        c.wait_event("code_window")
        sid, req = await_request(s, c)
        bound = c.wait_event("device_bound")
        c.wait_for(lambda: s.relay.frames_of(sid, "state"), 15)
        T.check(bool(req) and req.get("auto") is True and bool(bound) and bool(s.relay.frames_of(sid, "key_reveal"))
                and bool(s.relay.frames_of(sid, "state")),
                "--no-confirm: approve_request is flagged auto and the session pairs without a control line", c.tail())
    for via in ("qr", None):
        with Scenario(ttl=2) as s:
            c = s.client(env={"HMD_RELAY_CODE_RENEW_MARGIN_S": "0.2", "HMD_RELAY_CODE_RENEW_MIN_S": "0.5"})
            c.wait_event("code_window")
            sid = s.bind(via=via)
            bound = c.wait_event("device_bound")
            c.wait_for(lambda: s.relay.frames_of(sid, "state"), 15)
            time.sleep(3.0)  # longer than a whole TTL: a bound session must not renew
            T.check(bool(bound) and c.count_events("approve_request") == 0 and s.relay.frames_of(sid, "key_reveal") == []
                    and bool(s.relay.frames_of(sid, "state")) and len(s.relay.registrations) == 1,
                    "QR bind (via=%s) in a code-registered session: paired as before, no approval, no key_reveal, no renewal" % via,
                    c.tail())
    with Scenario() as s:
        c = s.client()
        c.wait_event("code_window")
        sid, _req = await_request(s, c)
        s.bind()  # the relay re-delivers the same bind (a stream reconnect)
        other = H.Phone(E2E)
        s.relay.inject_device_bound(sid, other.pub_b64url, via="code")  # a different key: never adopted
        err = c.wait_event("error", where=lambda e: "differs" in e.get("detail", ""), timeout=6)
        time.sleep(0.5)
        T.check(bool(err) and c.count_events("approve_request") == 1 and len(s.relay.frames_of(sid, "key_reveal")) == 1,
                "a repeated bind asks nothing twice and a different key is refused loudly", c.tail())


# -- renewal ----------------------------------------------------------------------------------------
def case_renewal():
    env = {"HMD_RELAY_CODE_WINDOW_S": "7", "HMD_RELAY_CODE_RENEW_MARGIN_S": "0.2", "HMD_RELAY_CODE_RENEW_MIN_S": "0.5"}
    with Scenario(ttl=2) as s:
        c = s.client(env=env)
        c.wait_for(lambda: len(s.relay.registrations) >= 2, 12)
        sid, req = await_request(s, c)  # the stream must already be on the newest session
        T.check(bool(req) and sid == s.relay.registrations[-1]["session_id"] if req else False,
                "renewal: the stream follows the new session (a bind on the newest session reaches the client)", c.tail())
        c.send("reject\n")
        closed = c.wait_event("code_window_closed", timeout=20)
        regs = list(s.relay.registrations)
        time.sleep(3.0)
        T.check(len(regs) >= 3 and all(r["code"] == H.CODE for r in regs), "renewal: the same code is registered again and again", str(len(regs)))
        T.check(len({r["session_id"] for r in regs}) == len(regs) and len({r["hmd_commit"] for r in regs}) == len(regs),
                "renewal: every registration is a new session with a fresh commitment")
        keys = [ev["qr"]["hmd_pubkey"] for ev in pair_inits(c)]
        T.check(len(set(keys)) == len(keys) and [ev.get("renewal") for ev in pair_inits(c)][1:] == list(range(1, len(keys))),
                "renewal: each pair_init after the first carries its renewal number and a fresh X25519 key", str(keys))
        T.check(all(r["session_id"] in s.relay.revokes for r in regs[:-1]), "renewal: every superseded session is revoked")
        T.check(bool(closed) and closed["reason"] == "expired" and len(s.relay.registrations) == len(regs),
                "the window total ends with code_window_closed, and nothing registers after it", c.tail())
    with Scenario(ttl=60) as s:
        c = s.client()
        pi = c.wait_event("pair_init")
        c.wait_event("code_window")
        s.relay.end_session(pi["qr"]["session_id"], reason="expired")  # the relay ended an unbound session early
        c.wait_for(lambda: len(s.relay.registrations) >= 2, 10)
        T.check(len(s.relay.registrations) >= 2 and c.rc is None
                and s.relay.registrations[1]["session_id"] != pi["qr"]["session_id"],
                "a session that ends unbound while the window is open renews instead of ending the client", c.tail())


def case_qr_only_unchanged():
    with Scenario() as s:
        c = s.client(code=None, token=None)
        pi = c.wait_event("pair_init")
        sid = s.bind(via=None)
        bound = c.wait_event("device_bound")
        c.wait_for(lambda: s.relay.frames_of(sid, "state"), 15)
        T.check(bool(pi) and bool(bound) and bool(s.relay.frames_of(sid, "state")) and s.relay.registrations == []
                and not [e for e in c.events() if e["event"].startswith("code_") or e["event"] == "approve_request"],
                "without --code: no registration, no code event, a QR bind pairs at once as it always did", c.tail())


def main():
    for case in (case_vectors_and_helpers, case_registration_and_hygiene, case_no_token, case_refusals,
                 case_approve_flow, case_reject_timeout_eof, case_no_confirm_and_qr_bind, case_renewal,
                 case_qr_only_unchanged):
        try:
            case()
        except Exception as exc:  # a case that dies is a failure, not a crash of the whole run
            T.check(False, "%s raised %s: %s" % (case.__name__, type(exc).__name__, exc))
    return T.finish()


if __name__ == "__main__":
    sys.exit(main())
