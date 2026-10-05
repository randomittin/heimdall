#!/usr/bin/env python3
"""companion_push_cli.py -- `hmd app push-test`: the operator's check that a phone registered for push really
receives one (hmdapp's docs/HANDOFF-TO-HEIMDALL-push-notifications.md PN5).

    hmd app push-test [--repo DIR] [--wait SECONDS]

Puts ONE `test` notification ("<label> · test notification") on every device registered for push on this repo and
prints, per device, what Expo said: an 8-hex fingerprint of its token (never the token), its platform, and

    accepted                      Expo took it and queued it for APNs / FCM; it should show on the phone in seconds
    DeviceNotRegistered           Expo says the app is gone; its registration was removed from this laptop
    error: <code>                 Expo's own error code, or network / http-<status> / backoff / paused
    not sent (rate-limited)       the device already had 20 notifications this hour

THIS COMMAND NEVER SENDS. The sender is the one process per repo that holds <repo>/.heimdall/app/push-sender.lock
(the `hmd ui` that `hmd app connect` started, or the relay client: whichever had a notification to send first), and
a process that does not own that lock drops every event it detects. A CLI that took the lock to send a test would
therefore make the real sender lose an approval or a question detected meanwhile, and one that sent without it
would break the one-sender rule. So it posts a REQUEST (<repo>/.heimdall/app/push-test) and the lock owner answers
it (push-test.result) through the same message builder, scrub, transport, back-off and DeviceNotRegistered pruning
as every real notification. The request and the answer are specified in bin/lib/companion_push.py, "OPERATOR
TEST", together with what a test bypasses (the kind filter, foreground suppression, the coalescing window and the
10 s spacing) and what it still obeys (the 20-per-hour cap, the provider back-off and pause, the lock, HMD_PUSH=0,
the loopback-only HMD_PUSH_EXPO_URL rule).

A sender that does not pick the request up within PICKUP_S is not running (a live one notices it within a poll of
its state cache, about 2 s); --wait bounds how long the whole answer may take (1..120 s, default 60). A request
nobody answered is withdrawn, so a sender that starts later does not find it.

Exit codes: 0 at least one device accepted the test; 1 an unexpected local fault; 2 usage (an unknown flag, a --wait
outside 1..120, a --repo that is not a directory -- the last checked by bin/heimdall-app); 3 no device registered
for push on this repo; 4 no sender picked the request up, or the one that did had not finished in time; 5 push is
switched off (HMD_PUSH=0); 6 every device failed or was held back.

The Expo token is a secret (anyone holding it can put a notification on that phone): it is read here only to
compute the fingerprint, and appears in no output, request or result. Stdlib only. Loadable by path.
"""
import argparse
import os
import sys
import time
from importlib.util import module_from_spec, spec_from_file_location

HERE = os.path.dirname(os.path.abspath(__file__))

EXIT_OK = 0
EXIT_FAULT = 1
EXIT_USAGE = 2
EXIT_NO_DEVICE = 3
EXIT_NO_SENDER = 4
EXIT_DISABLED = 5
EXIT_FAILED = 6
EXIT_INTERRUPTED = 130

DEFAULT_WAIT_S = 60.0
MIN_WAIT_S = 1.0
MAX_WAIT_S = 120.0
PICKUP_S = 10.0                   # a live sender notices a request within one state-cache poll (~2 s): this is generous
POLL_S = 0.1

NO_DEVICE = ("push-test: no device registered for push on this repo -- pair the phone (hmd app connect --relay) "
             "and turn notifications on in the app\n")
# what to say next to a failure code the sender can answer with; anything else is shown as its bare code
HINTS = {
    "DeviceNotRegistered": "Expo says the app is gone; its registration was removed from this laptop",
    "network": "Expo could not be reached",
    "backoff": "the sender is holding back after Expo kept failing; try again in a minute",
    "paused": "the sender is paused after Expo refused its credentials",
}


def wait_seconds(text):
    """argparse type for --wait: a number of seconds in MIN_WAIT_S..MAX_WAIT_S."""
    try:
        value = float(text)
    except ValueError:
        raise argparse.ArgumentTypeError("not a number: %r" % text)
    if not MIN_WAIT_S <= value <= MAX_WAIT_S:
        raise argparse.ArgumentTypeError("must be %d..%d seconds" % (MIN_WAIT_S, MAX_WAIT_S))
    return value


def load_push():
    """bin/lib/companion_push.py by path, like every companion_* module."""
    spec = spec_from_file_location("companion_push", os.path.join(HERE, "companion_push.py"))
    module = module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def await_answer(push, root, request_id, wait_s):
    """Poll for the sender's answer. Returns it the moment it is "done"; None when nothing answered within PICKUP_S;
    the "sending" stub when the sender took the request but did not finish within `wait_s`."""
    began = time.monotonic()
    pickup_by, finish_by = began + min(PICKUP_S, wait_s), began + wait_s
    while True:
        result = push.read_test_result(root, request_id)
        now = time.monotonic()
        if result is not None and result["state"] == "done":
            return result
        if now >= finish_by or (result is None and now >= pickup_by):
            return result
        time.sleep(POLL_S)


def describe(entry):
    """One device's outcome as the word the operator reads."""
    if entry["ok"]:
        return "accepted"
    if entry["suppressed"] == "rate-limited":
        return "not sent (rate-limited: 20 notifications per device per hour)"
    detail = entry["detail"]
    text = detail if detail == "DeviceNotRegistered" else "error: %s" % (detail or "unknown")
    return "%s (%s)" % (text, HINTS[detail]) if detail in HINTS else text


def report(results, platforms, out):
    """Print the per-device lines and the summary; the exit code: 0 when at least one device accepted."""
    out.write("push-test: %d device(s) registered for push\n" % len(results))
    for entry in results:
        out.write("  %s  %-7s  %s\n" % (entry["device"], platforms.get(entry["device"]) or "?", describe(entry)))
    accepted = sum(1 for entry in results if entry["ok"])
    if accepted:
        out.write("push-test: %d of %d accepted by Expo (accepted = queued for APNs / FCM; the phone should show it "
                  "within seconds)\n" % (accepted, len(results)))
        return EXIT_OK
    out.write("push-test: 0 of %d accepted -- no notification was queued\n" % len(results))
    return EXIT_FAILED


def run(push, root, wait_s, out, env):
    if not push.enabled(env):
        out.write("push-test: push is switched off (HMD_PUSH=0): nothing was sent\n")
        return EXIT_DISABLED
    devices = push.registered_devices(root)
    if not devices:
        out.write(NO_DEVICE)
        return EXIT_NO_DEVICE
    platforms = {d["device"]: d["platform"] for d in devices}
    sys.stderr.write("push-test: asking the push sender to notify %d device(s)...\n" % len(devices))
    request_id = push.request_test(root)
    result = None
    try:
        result = await_answer(push, root, request_id, wait_s)
    finally:
        if result is None or result["state"] != "done":
            push.withdraw_test_request(root, request_id)
    if result is None:
        out.write("push-test: no push sender picked the request up within %g s. The sender is the `hmd ui` process "
                  "that `hmd app connect` started for this repo (`hmd app status`); one started before this command "
                  "existed has to be restarted, and HMD_PUSH=0 in its environment turns it off.\n"
                  % min(PICKUP_S, wait_s))
        return EXIT_NO_SENDER
    if result["state"] != "done":
        out.write("push-test: the push sender took the request but had not finished within %g s; it may still "
                  "deliver -- check the phone.\n" % wait_s)
        return EXIT_NO_SENDER
    if not result["results"]:
        out.write(NO_DEVICE)
        return EXIT_NO_DEVICE
    return report(result["results"], platforms, out)


def main(argv=None, out=None, env=None):
    argv = list(sys.argv[1:] if argv is None else argv)
    out = sys.stdout if out is None else out
    env = os.environ if env is None else env
    if not argv or argv[0] != "push-test":
        sys.stderr.write("usage: hmd app push-test [--repo DIR] [--wait SECONDS]\n")
        return EXIT_USAGE
    parser = argparse.ArgumentParser(prog="hmd app push-test", add_help=False)
    parser.add_argument("--repo", default=os.getcwd())
    parser.add_argument("--wait", type=wait_seconds, default=DEFAULT_WAIT_S)
    args = parser.parse_args(argv[1:])            # a bad flag: argparse prints the usage and exits 2
    try:
        push = load_push()
    except Exception as exc:
        sys.stderr.write("push-test: cannot load bin/lib/companion_push.py (%s)\n" % exc.__class__.__name__)
        return EXIT_FAULT
    try:
        return run(push, os.path.abspath(args.repo), args.wait, out, env)
    except KeyboardInterrupt:
        out.write("\npush-test: interrupted\n")
        return EXIT_INTERRUPTED
    except (OSError, RuntimeError) as exc:
        sys.stderr.write("push-test: %s\n" % (getattr(exc, "strerror", None) or exc))
        return EXIT_FAULT


if __name__ == "__main__":
    sys.exit(main())
