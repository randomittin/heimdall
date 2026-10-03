#!/usr/bin/env python3
"""test/lib/fake-claude.py -- a hermetic stand-in for the `claude` CLI, placed first on PATH (as a symlink
named `claude`) by test/companion-cc-login-e2e.test.sh. It never touches the network, a keychain or the
operator's real Claude Code store: its whole world is $FAKE_CLAUDE_DIR.

It is faithful to what the real 2.1.288 CLI does on the three subcommands bin/lib/companion_cc_login.py
runs (read from the binary's `authLogin` / `authStatus` / `authLogout` handlers):

  auth login [--console]   replays docs/samples/login/cc-2.1.288-transcript.txt (`Opening browser to sign
                           in...`, `If the browser didn't open, visit: <URL>`, then the prompt
                           `Paste code here if prompted > ` with no newline) and then reads LINES from
                           stdin like readline does: a line is trimmed and split on `#`; a missing CODE or
                           STATE prints `Invalid code. Please make sure the full code was copied.` on
                           stderr and goes on waiting. A line equal to $FAKE_CLAUDE_EXPECT prints
                           `Login successful.` and exits 0 having signed the store in; any other
                           well-formed line prints `Login failed: <reason>` on stderr and exits 1. It never
                           exits on its own while waiting.
  auth status              pretty JSON {loggedIn, authMethod, apiProvider, analyticsDisabled,
                           projectsDirectory, configDirectory[, apiKeySource][, email, orgId, orgName,
                           subscriptionType]}; exit 0 iff loggedIn. ANTHROPIC_API_KEY in its environment
                           wins over the store, as it does for the real CLI.
  auth logout              signs the store out.

Every call is one line in $FAKE_CLAUDE_DIR/calls.log (never the code). The login process's pid goes to
login.pid and, in the modes that leave a helper behind, the helper's pid to child.pid, so a test can prove
the whole process group was killed.

$FAKE_CLAUDE_MODE for `auth login` (default happy):
  happy                  as above
  split-url              the URL line arrives in three writes, with pauses (a partial URL must not be judged)
  noise-then-url         an unrelated https link is printed before the visit line
  bad-host               the URL names claude.com.evil.example
  bad-redirect           the URL's redirect_uri is a localhost callback
  no-url                 prints nothing and waits forever
  hang                   URL + prompt, never reads stdin, waits forever (a helper `sleep` stays in the group)
  ignore-term            like hang but ignores SIGTERM (only SIGKILL ends it)
  exit-early             prints the first line and exits 1
  exit-after-url         URL + prompt, then exits 1
  slow-result            takes the right code and then says nothing, forever
  invalid-code-marker    answers a well-formed line with the `Invalid code` message and keeps waiting
  login-keeps-store      prints `Login successful.` but leaves the store signed out
  echo-code              echoes the received line back before succeeding (the worst case for leaks)
"""
import json
import os
import signal
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.realpath(__file__))
REPO = os.path.normpath(os.path.join(HERE, "..", ".."))
TRANSCRIPT = os.environ.get("FAKE_CLAUDE_TRANSCRIPT") or os.path.join(
    REPO, "docs", "samples", "login", "cc-2.1.288-transcript.txt")
DIR = os.environ["FAKE_CLAUDE_DIR"]
MODE = os.environ.get("FAKE_CLAUDE_MODE", "happy")
STORE = os.path.join(DIR, "store.json")
MANAGED_KEY = "/login managed key"


def log(line):
    with open(os.path.join(DIR, "calls.log"), "a", encoding="utf-8") as f:
        f.write(line + "\n")


def read_store():
    try:
        with open(STORE, encoding="utf-8") as f:
            return json.load(f)
    except (OSError, ValueError):
        return {"loggedIn": False}


def write_store(obj):
    with open(STORE, "w", encoding="utf-8") as f:
        json.dump(obj, f)


def home():
    return os.environ.get("HOME", "/nonexistent-home")


def status():
    log("status pid=%d" % os.getpid())
    base = {"loggedIn": False, "authMethod": "none", "apiProvider": "firstParty", "analyticsDisabled": False,
            "projectsDirectory": os.path.join(home(), ".claude", "projects"),
            "configDirectory": os.path.join(home(), ".claude")}
    if os.environ.get("FAKE_CLAUDE_STATUS_HANG"):
        time.sleep(300)
    if os.environ.get("FAKE_CLAUDE_STATUS_GARBAGE"):
        sys.stdout.write("this is not json\n")
        return 0
    if os.environ.get("ANTHROPIC_API_KEY"):
        base.update(loggedIn=True, authMethod="api_key", apiKeySource="ANTHROPIC_API_KEY")
    elif os.environ.get("CLAUDE_CODE_OAUTH_TOKEN"):
        base.update(loggedIn=True, authMethod="oauth_token")
    else:
        store = read_store()
        if store.get("loggedIn"):
            method = store.get("authMethod", "claude.ai")
            base.update(loggedIn=True, authMethod=method)
            if method == "api_key":
                base["apiKeySource"] = MANAGED_KEY
            base.update(email=store.get("email"), orgId=store.get("orgId"), orgName=store.get("orgName"))
            if method == "claude.ai":
                base["subscriptionType"] = store.get("subscriptionType", "max")
    sys.stdout.write(json.dumps(base, indent=2) + "\n")
    return 0 if base["loggedIn"] else 1


def logout():
    log("logout pid=%d" % os.getpid())
    write_store({"loggedIn": False})
    sys.stdout.write("Successfully logged out from your Anthropic account.\n")
    return 0


def say(text, err=False):
    stream = sys.stderr if err else sys.stdout
    stream.write(text)
    stream.flush()


def transcript_text(console):
    with open(TRANSCRIPT, "rb") as f:
        text = f.read().decode("utf-8").replace("\r\n", "\n")  # the PTY turns each \n back into \r\n
    if console:
        text = text.replace("https://claude.com/cai/oauth/authorize", "https://platform.claude.com/oauth/authorize")
    if MODE == "bad-host":
        text = text.replace("https://claude.com/", "https://claude.com.evil.example/")
    if MODE == "bad-redirect":
        text = text.replace("redirect_uri=https%3A%2F%2Fplatform.claude.com%2Foauth%2Fcode%2Fcallback",
                            "redirect_uri=http%3A%2F%2Flocalhost%3A54321%2Fcallback")
    return text


def leave_helper():
    child = subprocess.Popen(["sleep", "300"])  # same process group: a group kill must take it too
    with open(os.path.join(DIR, "child.pid"), "w", encoding="utf-8") as f:
        f.write(str(child.pid))


def login(argv):
    console = "--console" in argv
    log("login pid=%d console=%s mode=%s" % (os.getpid(), console, MODE))
    with open(os.path.join(DIR, "login.pid"), "w", encoding="utf-8") as f:
        f.write(str(os.getpid()))
    text = transcript_text(console)
    first, _, rest = text.partition("\n")
    if MODE == "no-url":
        leave_helper()
        time.sleep(300)
        return 1
    if MODE == "noise-then-url":
        say("See https://code.claude.com/docs/en/authentication for help\n")
    say(first + "\n")
    if MODE == "exit-early":
        return 1
    if MODE == "split-url":
        cut = rest.index("oauth/authorize") + 5
        cut2 = rest.index("code_challenge=") + 4
        for piece in (rest[:cut], rest[cut:cut2], rest[cut2:]):
            say(piece)
            time.sleep(0.3)
    else:
        say(rest)
    if MODE == "exit-after-url":
        return 1
    if MODE in ("hang", "ignore-term"):
        if MODE == "ignore-term":
            signal.signal(signal.SIGTERM, signal.SIG_IGN)
        leave_helper()
        time.sleep(300)
        return 1
    expected = os.environ.get("FAKE_CLAUDE_EXPECT", "")
    while True:
        line = sys.stdin.readline()
        if not line:
            return 1
        parts = line.strip().split("#")
        code, state = parts[0], parts[1] if len(parts) > 1 else ""
        if not code or not state or MODE == "invalid-code-marker":
            say("Invalid code. Please make sure the full code was copied.\n", err=True)
            continue
        break
    if MODE == "echo-code":
        say("Received: " + line)
    if MODE == "slow-result" and code + "#" + state == expected:
        leave_helper()
        time.sleep(300)
        return 1
    if code + "#" + state != expected:
        say("Login failed: Request failed with status code 400\n", err=True)
        return 1
    if MODE != "login-keeps-store":
        email = os.environ.get("FAKE_CLAUDE_ACCOUNT_EMAIL", "owner@example.test")
        org = os.environ.get("FAKE_CLAUDE_ACCOUNT_ORG", "11111111-2222-3333-4444-555555555555")
        write_store({"loggedIn": True, "authMethod": "api_key" if console else "claude.ai", "email": email,
                     "orgId": org, "orgName": "Test Org"})
    say("Login successful.\n")
    return 0


def main(argv):
    if argv[:2] == ["auth", "status"]:
        return status()
    if argv[:2] == ["auth", "logout"]:
        return logout()
    if argv[:2] == ["auth", "login"]:
        return login(argv[2:])
    sys.stderr.write("fake-claude: unsupported invocation\n")
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
