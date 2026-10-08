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
    commitment and fresh keys until the window total ends, and the stream follows each new session;
  * a key that was revealed is burned: the relay knows it, so whatever the approval's outcome no bind on that
    session is accepted again (a QR bind made up from the revealed key, a second claim by code, in any code
    state), the window renewed afterwards pairs normally under a fresh key, and a window that ends on a burned
    key ends the session;
  * --code and --identity-revoke put the GitHub token in a request body, so they are refused unless the relay
    is https or on this machine.
"""
import argparse
import hashlib
import json
import os
import re
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


def documented_key_reveal_patterns():
    """How relay/contract/code-pair.json says each key_reveal payload field is spelled: the pattern of the binding its
    template names. The contract is read, not restated, so a change on either side of it turns the check red."""
    contract = json.load(open(H.CODE_PAIR_CONTRACT_PATH))
    template = contract["frames"]["key_reveal"]["envelope"]["payload"]
    return {field: re.compile(contract["bindings"][ref.lstrip("$")]["match"]) for field, ref in template.items()}


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
        documented = documented_key_reveal_patterns()
        sent, qr_key = kr["payload"], pair_inits(c)[0]["qr"]["hmd_pubkey"]
        T.check(sorted(documented) == sorted(sent)
                and all(documented[field].fullmatch(sent[field]) for field in documented)
                and documented["hmd_pubkey"].fullmatch(qr_key),
                "key_reveal: hmd_pubkey and nonce are spelled the way relay/contract/code-pair.json documents them, "
                "and the QR carries hmd_pubkey in that same spelling", "payload %s, QR hmd_pubkey %s" % (sent, qr_key))
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
        sid = s.bind()
        bound = c.wait_event("device_bound")
        paired = c.wait_event("code_paired")
        c.wait_for(lambda: s.relay.frames_of(sid, "state"), 15)
        T.check(bool(bound) and bool(paired) and paired["gh_login"] == "octocat" and paired["device_label"] == "Pixel 9a"
                and c.count_events("approve_request") == 0 and bool(s.relay.frames_of(sid, "key_reveal"))
                and bool(s.relay.frames_of(sid, "state")),
                "--no-confirm: the claim pairs at once -- no approve_request (no SAS), a code_paired event naming what the relay claimed",
                c.tail())
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


# -- a revealed key is a burned key -----------------------------------------------------------------
# The key_reveal crosses the relay in plaintext, so from the moment it is posted the relay knows hmd's public key
# for that session -- and a bind it makes up from there (a "QR" bind with a key of its own, or a second claim by
# code with a key ground to show the same SAS) cannot be told from a phone's. The cases below play a HOSTILE
# relay: it keeps a session open after being asked to revoke it, and attacks the window whose key it has seen.
BURN_ENV = {"HMD_RELAY_CODE_RENEW_MIN_S": "30", "HMD_RELAY_CODE_RENEW_MARGIN_S": "0.2"}  # the burned window outlives the attack


def refusals(proc):
    return [e for e in proc.events() if e.get("event") == "error" and "device_bound refused" in e.get("detail", "")]


def await_binds_answered(proc, refused, timeout=8.0):
    """Until the client has refused `refused` binds -- or paired, which fails the case at once, not at the timeout."""
    proc.wait_for(lambda: len(refusals(proc)) >= refused or proc.count_events("device_bound"), timeout)


def status_paired(sandbox):
    with open(os.path.join(sandbox.repo, ".heimdall", "app", "relay.json"), encoding="utf-8") as f:
        return json.load(f)["paired"]


def burn(s, c, how):
    """A phone claims the window by code, hmd reveals its key, and the approval ends without a pairing.
    Returns (the session id, the code_rejected event)."""
    c.wait_event("code_window")
    sid = s.bind()
    if how in ("reject", "eof"):
        c.wait_event("approve_request", timeout=10)
        if how == "reject":
            c.send("reject\n")
        else:
            c.close_stdin()
    return sid, c.wait_event("code_rejected", timeout=10)


def case_burned_key_binds_nothing():
    for how, ended in (("reject", "operator"), ("timeout", "timeout"), ("eof", "eof"), ("reveal-failed", "reveal-failed")):
        with Scenario() as s:
            s.relay.ignore_revokes = True
            if how == "reveal-failed":  # the relay refuses the key_reveal -- having read it
                s.relay.frames_status = lambda env: (400, {"error": "refused"}) if env.get("type") == "key_reveal" else None
            c = s.client(env=dict(BURN_ENV, HMD_RELAY_APPROVAL_TIMEOUT_S=1.5) if how == "timeout" else BURN_ENV)
            sid, rejected = burn(s, c, how)
            s.relay.inject_device_bound(sid, H.Phone(E2E).pub_b64url, via="qr")  # a bind made up from the revealed key
            await_binds_answered(c, 1)
            qr_refused = len(refusals(c)) == 1
            s.bind(sid=sid, via="code", phone=H.Phone(E2E))  # a second claim by code
            await_binds_answered(c, 2)
            time.sleep(0.5)
            T.check(bool(rejected) and rejected["reason"] == ended and len(s.relay.frames_of(sid, "key_reveal")) == 1,
                    "burned key (%s): the approval ended without a pairing, the key revealed once" % how, c.tail())
            T.check(qr_refused and c.count_events("device_bound") == 0 and sealed_frames(s.relay, sid) == []
                    and status_paired(s.sb) is False,
                    "burned key (%s): a QR bind made up from the revealed key is refused -- unpaired, nothing sealed" % how, c.tail())
            T.check(len(refusals(c)) == 2 and c.count_events("approve_request") == (0 if how == "reveal-failed" else 1)
                    and len(s.relay.frames_of(sid, "key_reveal")) == 1,
                    "burned key (%s): a second claim by code is refused too -- no second prompt, no second key_reveal" % how,
                    c.tail())


class captured_events:
    """The client's own event channel, captured into a list instead of printed -- for cases that drive a RelayClient
    in this process, with no relay and no sockets."""

    def __enter__(self):
        self.events, self._real = [], CLIENT.emit
        CLIENT.emit = self.events.append
        return self.events

    def __exit__(self, *_exc):
        CLIENT.emit = self._real


def offline_client(sandbox):
    """A RelayClient as `--code` mode leaves it right after code_start, pointed at a port nothing listens on."""
    client = CLIENT.RelayClient(argparse.Namespace(relay="http://127.0.0.1:1", repo=sandbox.repo, tick_s=2.0,
                                                   status_file=os.path.join(sandbox.root, "relay.json"),
                                                   public_host=None, ui_port=1))
    client.priv, client.pub = E2E.generate_keypair()
    client._commit_nonce = os.urandom(32)
    client.session_id = "offline-session"
    return client


def device_bound(client, via):
    """What the relay tells hmd's stream about a phone claiming the session (`via` None: a relay that predates the field)."""
    payload = {"device_pubkey": H.Phone(E2E).pub_b64url, "bound_at": 1}
    if via is not None:
        payload["via"] = via
    return {"v": 1, "session_id": client.session_id, "seq": 0, "sender": "relay", "type": "device_bound",
            "nonce": None, "ciphertext": None, "payload": payload}


def case_burn_guard_holds_in_every_code_state():
    sandbox = H.Sandbox()
    try:
        with captured_events() as events:
            bound = []
            for state in ("off", "open", "closed", "bound"):
                for via in ("qr", "code", None):
                    client = offline_client(sandbox)
                    client._code_state, client._key_revealed = state, True
                    client._handle_envelope(device_bound(client, via))
                    if client.session_key is not None or client.paired or client.device_pub is not None:
                        bound.append((state, via))
            T.check(bound == [], "a burned key binds nothing whatever the code state (off/open/closed/bound) or the via", str(bound))
            T.check(sum(1 for e in events if e.get("event") == "error" and "device_bound refused" in e.get("detail", "")) == 12,
                    "...and each of those twelve binds is refused loudly, none dropped silently", str(events)[:300])
            control = offline_client(sandbox)
            control._handle_envelope(device_bound(control, "qr"))
            T.check(control.session_key is not None and control.paired,
                    "control: the same QR bind on a key that was never revealed pairs (the cases above prove something)")
    finally:
        sandbox.close()


def case_code_end_on_a_burned_key():
    sandbox = H.Sandbox()
    try:
        for label, revealed, state, ends in (("a window whose key was revealed", True, "open", True),
                                             ("a window whose key was never revealed", False, "open", False),
                                             ("an approval still in flight on a revealed key", True, "approving", False)):
            with captured_events() as events:
                client = offline_client(sandbox)
                client._code_state, client._key_revealed = state, revealed
                client._code_end("code_window_closed", "expired")
            names = [(e.get("event"), e.get("reason")) for e in events]
            want = [] if state == "approving" else [("code_window_closed", "expired")] + ([("session_ended", "key-revealed")] if ends else [])
            T.check(names == want and client.stop_event.is_set() is ends
                    and client._code_state == ("approving" if state == "approving" else "closed"),
                    "code end on %s: %s" % (label, "the session ends with the window" if ends else
                                            "the in-flight approval decides first, nothing is closed" if state == "approving"
                                            else "the QR session goes on"), str(names))
    finally:
        sandbox.close()


def case_window_renewed_after_a_burn_pairs():
    env = {"HMD_RELAY_CODE_RENEW_MIN_S": "0.5", "HMD_RELAY_CODE_RENEW_MARGIN_S": "0.2"}
    with Scenario() as s:
        c = s.client(env=env)
        c.wait_event("code_window")
        sid1, _req = await_request(s, c)
        c.send("reject\n")
        renewed = c.wait_event("code_window", where=lambda e: e.get("renewal") == 1, timeout=15)
        sid2, seen = s.relay.latest().id, len(c.events())
        s.bind(sid=sid2)
        req = c.wait_event("approve_request", start=seen, timeout=10)
        reveals = s.relay.frames_of(sid2, "key_reveal")
        hmd_pub2 = H.b64_any(reveals[0]["payload"]["hmd_pubkey"]) if reveals else b""
        fresh_key = len(pair_inits(c)) > 1 and hmd_pub2 == hmd_pub_of(c, 1) != hmd_pub_of(c, 0)
        T.check(bool(renewed) and bool(req) and sid2 != sid1 and fresh_key and req["sas"] == H.sas_ref(sid2, hmd_pub2, s.phone.pub),
                "a window renewed after a burned key is claimable again: a fresh key, and a new prompt on it", c.tail())
        c.send("approve\n")
        bound = c.wait_event("device_bound")
        c.wait_for(lambda: s.relay.frames_of(sid2, "state"), 15)
        states = s.relay.frames_of(sid2, "state")
        opened = s.phone.open_hmd_frame(hmd_pub2, sid2, states[0]) if states else None
        T.check(bool(bound) and opened is not None and "state" in opened,
                "...and the pairing it approves seals state under the fresh key", c.tail())


def case_burned_key_ends_the_session_when_the_window_does():
    env = {"HMD_RELAY_CODE_WINDOW_S": "3", "HMD_RELAY_CODE_RENEW_MIN_S": "0.5", "HMD_RELAY_CODE_RENEW_MARGIN_S": "0.2"}
    with Scenario() as s:
        s.relay.ignore_revokes = True
        c = s.client(env=env)
        c.wait_event("code_window")
        sid, _req = await_request(s, c)
        time.sleep(3.2)  # the window's whole 3 s runs out while the laptop is still looking at the prompt
        c.send("reject\n")
        closed = c.wait_event("code_window_closed", timeout=10)
        s.relay.inject_device_bound(sid, H.Phone(E2E).pub_b64url, via="qr")  # the burned session is still open on the relay's side
        c.wait_for(lambda: c.count_events("session_ended") or c.count_events("device_bound"), 10)
        ended = [e for e in c.events() if e.get("event") == "session_ended"]
        rc = c.wait_exit(10) if ended else None
        T.check(bool(closed) and closed["reason"] == "expired" and len(ended) == 1 and ended[0]["reason"] == "key-revealed"
                and rc == 0 and c.count_events("device_bound") == 0,
                "the window ending on a burned key ends the session: no QR is left to bind on that key, the client exits 0", c.tail())


# -- the token only travels over TLS or to this machine ----------------------------------------------------
def case_code_needs_tls_or_loopback():
    ok_urls = ["https://hmd-relay.therishabh16.workers.dev", "https://relay.example/base", "HTTPS://Relay.Example",
               "http://127.0.0.1:8787", "http://127.1.2.3", "http://localhost", "http://LOCALHOST:9", "http://[::1]:9"]
    bad_urls = ["http://relay.example", "http://192.0.2.1", "http://[2001:db8::1]", "http://0.0.0.0:9",
                "http://127.0.0.1.relay.example", "http://localhost.relay.example", "http://relay.example:443"]
    T.check(all(CLIENT.token_transport_ok(CLIENT._split_relay(u)) for u in ok_urls)
            and not any(CLIENT.token_transport_ok(CLIENT._split_relay(u)) for u in bad_urls),
            "token_transport_ok: https anywhere, plain http only to localhost or a loopback address",
            str([u for u in ok_urls if not CLIENT.token_transport_ok(CLIENT._split_relay(u))]
                + [u for u in bad_urls if CLIENT.token_transport_ok(CLIENT._split_relay(u))]))
    for flag, extra in (("--code", ["--code", H.CODE]), ("--identity-revoke", ["--identity-revoke"])):
        with Scenario() as s:
            proc = H.Proc([H.CLIENT_PATH, "--relay", "http://relay.example.test", "--repo", s.sb.repo, "--ui-port", "1"] + extra,
                          s.sb.env())
            s.procs.append(proc)
            proc.send(H.TOKEN + "\n")
            rc = proc.wait_exit(10)
            T.check(rc == 2 and ("%s sends the GitHub token in a request body" % flag).encode() in proc.err()
                    and b"https://" in proc.err() and proc.out() == b""
                    and H.TOKEN.encode() not in proc.out() + proc.err(),
                    "%s over plain http to a host that is not this machine: a usage error (exit 2) before anything is sent" % flag,
                    proc.tail())
    with Scenario() as s:  # the gate lets a TLS relay through: what fails is pair/init, on a port nothing listens on
        proc = H.Proc([H.CLIENT_PATH, "--relay", "https://127.0.0.1:1", "--repo", s.sb.repo, "--ui-port", "1",
                       "--code", H.CODE], s.sb.env())
        s.procs.append(proc)
        proc.send(H.TOKEN + "\n")
        rc = proc.wait_exit(20)
        T.check(rc == 12, "--code over https passes the gate: the client goes on to pair/init (unreachable here, exit 12)", proc.tail())


def main():
    for case in (case_vectors_and_helpers, case_registration_and_hygiene, case_no_token, case_refusals,
                 case_approve_flow, case_reject_timeout_eof, case_no_confirm_and_qr_bind, case_renewal,
                 case_qr_only_unchanged, case_code_needs_tls_or_loopback, case_burn_guard_holds_in_every_code_state,
                 case_code_end_on_a_burned_key, case_burned_key_binds_nothing, case_window_renewed_after_a_burn_pairs,
                 case_burned_key_ends_the_session_when_the_window_does):
        try:
            case()
        except Exception as exc:  # a case that dies is a failure, not a crash of the whole run
            T.check(False, "%s raised %s: %s" % (case.__name__, type(exc).__name__, exc))
    return T.finish()


if __name__ == "__main__":
    sys.exit(main())
