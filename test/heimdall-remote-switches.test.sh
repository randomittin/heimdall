#!/usr/bin/env bash
# test/heimdall-remote-switches.test.sh
#
# CP2 of hmdapp's docs/HANDOFF-TO-HEIMDALL-cursor-parity.md: the laptop-side safeguards every `expand` remote action
# (launch-session, pr-merge, anything tagged expand later) sits behind. bin/lib/companion_remote_switches.py owns the two
# switches and the repo allowlist (and their CLI: `hmd app remote-launch|remote-merge on|off|status`, `hmd app
# launch-allow`); bin/lib/companion_ui_controls.py owns the gate in the one dispatcher, the second audit record and the
# `remote_actions` / `launch` state keys. Driven through the REAL CLI (under a real pseudo-terminal where a terminal is
# the point), the REAL dispatcher and the REAL `hmd ui` server. The sealed transport is
# test/heimdall-controls-relay.test.sh (section 9); the class tags and the kill-switch exemption are
# test/heimdall-controls.test.sh (section 12).
#
#   1  the switches: `on` with stdin NOT a terminal is refused and writes nothing (an agent, a script and the phone cannot
#      enable it); refused under HMD_UI_CONTROLS=0 and under a repo's controls-disabled; at a terminal it writes
#      {"enabled","since"} mode 0600; `off` / `status` need no terminal; a switch file that is group/world-writable, a
#      symlink, junk, oversized, mistyped or without `since` reads as OFF
#   2  the allowlist: add needs a terminal, stores {id, label, path, merge} with id = r- + the first 4 hex of sha256 of the
#      REALPATH (a symlinked path adds the real one), merge false unless --merge, mode 0600; a non-repo, a subdirectory and
#      a missing path are refused; --list / --remove need no terminal; a re-add restates the flags
#   3  the gate (the dispatcher in-process, with the expand actions the next asks register): switch off -> not-allowed
#      before the params are read; on + repo not on the allowlist, named by LABEL or by PATH -> not-allowed; allowlisted by
#      id -> the handler runs with the allowlist's own path; a symlink swapped in after the add -> not-allowed and not
#      offered to the phone; merge needs --merge AND its own switch; the kill switch beats everything, except launch-stop;
#      every attempt, refused ones too, is in controls-audit.jsonl AND relay-events.jsonl (same ts, ref = the action id),
#      with no prompt, rid or path in either; an expand command that cannot be audited is refused, not run; rate limits
#   4  no ALLOWED action writes either switch file (every action run against absent / off switches), and nothing remote
#      reachable even names the writers
#   5  the real `hmd ui`: launch-session / pr-merge are refused not-allowed while off, then not-implemented once the switch
#      is on and nothing has registered a handler; both logs and state.remote_actions.recent agree; state.launch lists
#      id + label only; the digest moves when a switch flips; the page carries the Remote actions card
#   6  mutants: the same battery against deliberately broken copies must FAIL (an audit line with the prompt, a switch an
#      action can flip, an allowlist matched by label, a symlink swap not re-checked, a merge flag ignored, a gate that is
#      skipped / ignores the switch, a launch-stop that needs the switch, a kill switch that exempts everything, an expand
#      run unaudited, no second record, a reserved name that is ungated, an unchecked class tag, a dropped hourly ceiling,
#      a CLI that needs no terminal, a switch file that is not trust-checked)
#   7  the `hmd app` arms, through the REAL bin/heimdall-app: remote-launch / remote-merge / launch-allow delegate to the
#      module and keep its terminal rule (stdin is the caller's own, not one the wrapper replaced); the allowlist is
#      $HEIMDALL_HOME/app/launch-allowlist.json (0600, directory 0700, no second .heimdall under HEIMDALL_HOME); a bad
#      invocation is the module's usage error and exit 2; --help documents the three; `hmd app status` prints the one-line
#      `remote:` summary in the tailscale report AND the relay report, and it follows the switches and the allowlist;
#      without python3 the arms say so and exit 2
#
# Hermetic: HOME / HEIMDALL_HOME / TMPDIR are a temp dir, fixture repos are temp dirs, every server is reaped on EXIT,
# every wait is a bounded poll. Secret-shaped strings are assembled at RUNTIME. No live relay client is ever signalled
# (section 7's stand-in for one is a bash loop that merely carries the name in its argv, killed when the section ends).

set -u

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SW="$REPO/bin/lib/companion_remote_switches.py"
CTL_LIB="$REPO/bin/lib/companion_ui_controls.py"
UI="$REPO/bin/heimdall-ui"
UI_PY="$REPO/sentinels/hmd-ui.py"
LIBDIR="$REPO/bin/lib"

PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; }

echo "heimdall-remote-switches (the expand gate: switches, allowlist, audit twice, remote_actions)"

for f in "$SW" "$CTL_LIB" "$UI" "$UI_PY"; do
  if [ ! -e "$f" ]; then
    printf 'FATAL: required file missing: %s\n' "$f" >&2
    printf '\n0 passed, 1 failed\n'
    exit 1
  fi
done
for tool in curl jq python3 git; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    printf 'FATAL: required tool missing: %s\n' "$tool" >&2
    printf '\n0 passed, 1 failed\n'
    exit 1
  fi
done

TMPROOT="$(mktemp -d)"
export TMPDIR="$TMPROOT"
export HOME="$TMPROOT/home"
export HEIMDALL_HOME="$TMPROOT/home/.heimdall"
export HEIMDALL_FALLBACK_ASSUME_REACHABLE=0
export HEIMDALL_FALLBACK_PROBE_TIMEOUT=1
export HMD_UI_COMPANION_PANELS=0
export HMD_UI_CONTROL_DEADLINE_S=8
unset CLAUDE_SESSION_ID SESSION_ID CLAUDE_CODE_SESSION_ID CLAUDE_CONFIG_DIR HMD_AGENT_PROJECTS_DIR HMD_UI_CONTROLS \
      HMD_RELAY_EVENT_LOG CLAUDE_CODE_ENTRYPOINT HMD_AGENT_TYPE HMD_JUDGMENT HMD_HOOKS_METADATA HMD_TMUX_TARGET
mkdir -p "$HOME/.claude" "$HEIMDALL_HOME"

PIDS=()
UI_PID=""
cleanup() {
  local p
  for p in "${PIDS[@]:-}"; do [ -n "$p" ] && kill "$p" 2>/dev/null; done
  for p in "${PIDS[@]:-}"; do [ -n "$p" ] && wait "$p" 2>/dev/null; done
  rm -rf "$TMPROOT"
}
trap cleanup EXIT

free_port() { python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()'; }
wait_for() {
  local file="$1" re="$2" secs="${3:-10}" i=0 max
  max=$(( secs * 5 ))
  while [ "$i" -lt "$max" ]; do
    grep -Eq "$re" "$file" 2>/dev/null && return 0
    sleep 0.2; i=$((i + 1))
  done
  return 1
}
new_repo() {
  local d="$TMPROOT/$1"
  mkdir -p "$d"
  ( cd "$d" && git init -q . 2>/dev/null && git -c user.email=t@t -c user.name=t commit -q --allow-empty -m fixture ) >/dev/null 2>&1
  ( cd "$d" && pwd -P )
}
stop_ui() {
  if [ -n "$UI_PID" ]; then kill "$UI_PID" 2>/dev/null; wait "$UI_PID" 2>/dev/null; fi
  UI_PID=""
}
start_ui() {
  local fix="$1" port out url q
  stop_ui
  port="$(free_port)"
  out="$TMPROOT/ui.$port.out"
  ( cd "$fix" && HEIMDALL_WATCH_ROOT="$fix" exec "$UI" --repo "$fix" --port "$port" --no-open ) >"$out" 2>&1 &
  UI_PID=$!
  PIDS+=("$UI_PID")
  if ! wait_for "$out" "^http://127\.0\.0\.1:$port/\?(t|token)=[A-Za-z0-9_-]+\$" 20; then
    bad "server for $fix never printed its URL"; sed 's/^/       | /' "$out"; return 1
  fi
  url="$(grep -E "^http://127\.0\.0\.1:$port/" "$out" | head -1)"
  q="${url#*\?}"
  UI_BASE="http://127.0.0.1:$port"
  UI_TOKEN="${q#*=}"
}
ctl() {
  CODE="$(curl -s -o "$TMPROOT/ctl.body" -w '%{http_code}' -X POST -H 'Content-Type: application/json' \
          -d "$1" "$UI_BASE/api/control?token=$UI_TOKEN")"
  BODY="$(cat "$TMPROOT/ctl.body")"
}
state() { curl -s "$UI_BASE/api/state?token=$UI_TOKEN"; }
etag() { curl -s -D - -o /dev/null "$UI_BASE/api/state?token=$UI_TOKEN" | tr -d '\r' | awk -F': ' 'tolower($1)=="etag"{print $2}'; }
poll_state() {
  local expr="$1" secs="${2:-15}" i=0
  while [ "$i" -lt $(( secs * 5 )) ]; do
    state | jq -e "$expr" >/dev/null 2>&1 && return 0
    sleep 0.2; i=$((i + 1))
  done
  return 1
}
jq_ok() { printf '%s' "$BODY" | jq -e "$1" >/dev/null 2>&1; }
expect() {
  if [ "$CODE" = "$2" ] && jq_ok "$3"; then ok "$1"; else bad "$1 -- got $CODE $BODY"; fi
}
mode_of() { stat -f %Lp "$1" 2>/dev/null || stat -c %a "$1"; }

# tty_run CMD ARGS... -- CMD with a real pseudo-terminal on its stdin / stdout / stderr (what a person at the laptop has);
# its output (CRs stripped) lands in TTY_OUT and the return status is CMD's
tty_run() {
  python3 -c 'import os, pty, sys
status = pty.spawn(sys.argv[1:])
sys.exit(os.waitstatus_to_exitcode(status))' "$@" >"$TMPROOT/tty.raw" 2>&1 </dev/null
  local rc=$?
  TTY_OUT="$(tr -d '\r' < "$TMPROOT/tty.raw")"
  return $rc
}

# ═══ the battery: gate (the dispatcher in-process) and cli (the real command), against any copy of the two modules ═══
BATT="$TMPROOT/battery.py"
cat > "$BATT" <<'PYEOF'
import hashlib, importlib.util, json, os, re, stat, subprocess, sys, tempfile, uuid

DEV = subprocess.DEVNULL
PTY_WRAPPER = ("import os, pty, sys\n"
               "status = pty.spawn(sys.argv[1:])\n"
               "sys.exit(os.waitstatus_to_exitcode(status))\n")
GOOD_SINCE = "2026-10-05T09:15:00Z"


def git_repo(parent, name):
    path = os.path.join(parent, name)
    os.makedirs(path)
    subprocess.run(["git", "init", "-q", path], check=True, stdout=DEV, stderr=DEV)
    subprocess.run(["git", "-C", path, "-c", "user.email=t@t", "-c", "user.name=t", "commit", "-q", "--allow-empty", "-m", "x"],
                   check=True, stdout=DEV, stderr=DEV)
    return os.path.realpath(path)


def load(libdir):
    spec = importlib.util.spec_from_file_location("ctl_" + uuid.uuid4().hex, os.path.join(libdir, "companion_ui_controls.py"))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def lines(path):
    try:
        with open(path, encoding="utf-8") as f:
            return [json.loads(x) for x in f if x.strip()]
    except OSError:
        return []


def cli(libdir, args, tty=False, env=None):
    script = os.path.join(libdir, "companion_remote_switches.py")
    e = dict(os.environ)
    e.update(env or {})
    cmd = ([sys.executable, "-c", PTY_WRAPPER, sys.executable, script] if tty else [sys.executable, script]) + list(args)
    p = subprocess.run(cmd, stdin=DEV, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, env=e, timeout=60)
    return p.returncode, p.stdout.decode("utf-8", "replace").replace("\r", "")


def gate_checks(libdir):
    failed = []

    def expect(label, cond, got=""):
        if not cond:
            failed.append("%s [%s]" % (label, str(got)[:200]))

    base = tempfile.mkdtemp(prefix="gate-")
    home = os.path.join(base, "home")
    os.makedirs(home)
    os.environ["HEIMDALL_HOME"] = home
    for k in ("HMD_UI_CONTROLS", "HMD_RELAY_EVENT_LOG"):
        os.environ.pop(k, None)
    counter = [0]

    def mkroot():
        counter[0] += 1
        p = os.path.join(base, "root%d" % counter[0])
        os.makedirs(p)
        return os.path.realpath(p)

    def aud(r):
        return os.path.join(r, ".heimdall", "ui", "controls-audit.jsonl")

    def evt(r):
        return os.path.join(r, ".heimdall", "app", "relay-events.jsonl")

    def d(C, root, action, params, clear=True):
        if clear:
            C._BUCKETS.clear()
        return C.dispatch(root, action, params, device_id="a1b2c3d4", seq=7, transport="relay")

    def off():
        for f in ("remote-launch.json", "remote-merge.json"):
            target = os.path.join(home, f)
            if os.path.lexists(target):
                os.unlink(target)

    # -- 1. a reserved expand name is gated before anything has registered a handler for it -----------------------
    C0 = load(libdir)
    S0 = C0._switches()
    if S0 is None:
        return ["the switches module did not load"]
    r1 = mkroot()
    expect("1a launch-session, switch off, no handler -> not-allowed", d(C0, r1, "launch-session", {"repo": "r-0000", "branch": "x"})[:2] == (False, "not-allowed"))
    expect("1b pr-merge, switch off, no handler -> not-allowed", d(C0, r1, "pr-merge", {"number": 1})[:2] == (False, "not-allowed"))
    S0.set_switch("launch", True)
    S0.set_switch("merge", True)
    expect("1c launch-session, switch on, no handler -> not-implemented", d(C0, r1, "launch-session", {"repo": "r-0000", "branch": "x"})[:2] == (False, "not-implemented"))
    expect("1d pr-merge, switch on, no handler -> not-implemented", d(C0, r1, "pr-merge", {"number": 1})[:2] == (False, "not-implemented"))
    expect("1e every attempt is in BOTH logs", len(lines(aud(r1))) == 4 and len(lines(evt(r1))) == 4 and all(x.get("event") == "remote-action" for x in lines(evt(r1))), (len(lines(aud(r1))), len(lines(evt(r1)))))
    expect("1f an unknown name is not an expand action: audited, no second record", d(C0, r1, "rm-rf", {})[:2] == (False, "not-implemented") and len(lines(aud(r1))) == 5 and len(lines(evt(r1))) == 4)
    off()

    # -- the expand actions the next asks register, as they will ------------------------------------------------------
    C = load(libdir)
    S = C._switches()
    calls, merged, stopped = [], [], []
    PROMPT = "PROMPT-MARKER /Users/someone/secret-path"

    def f_launch(body):
        for k in ("repo", "branch"):
            if not isinstance(body[k], str):
                raise C._Refusal("bad-params")
        return {"repo": body["repo"], "branch": body["branch"], "prompt": body.get("prompt")}

    def audit_launch(f):   # a BAD rule on purpose: it hands the central filter everything the filter must drop
        return {"repo": f["repo"], "branch": f["branch"], "prompt": f.get("prompt"), "path": "/etc/passwd", "rid": "L-1",
                "model": "sonnet", "mode": "plan"}

    def h_launch(root, fields, ctx):
        calls.append((ctx.repo["path"], ctx.repo["id"]))
        return True, None, {"id": "l-77", "result": {"worktree": "x-l-77"}}

    def f_merge(body):
        if not isinstance(body["number"], int) or isinstance(body["number"], bool) or body["method"] not in ("squash", "merge", "rebase"):
            raise C._Refusal("bad-params")
        return {"number": body["number"], "method": body["method"]}

    def h_merge(root, fields, ctx):
        merged.append((ctx.repo["id"], ctx.repo["merge"]))
        return True, None, {"id": "m-5c1d", "result": {"merged": True, "method": fields["method"]}}

    def h_stop(root, fields, ctx):
        stopped.append(fields["id"])
        return True, None, {"id": fields["id"]}

    C.register_action("launch-session", cls="expand", switch="launch", repo_field="repo", required=("repo", "branch"),
                      optional=("prompt",), fields=f_launch, audit=audit_launch, handler=h_launch,
                      rate=C.EXPAND_RATES["launch-session"])
    C.register_action("pr-merge", cls="expand", switch="merge", required=("number", "method"), fields=f_merge,
                      audit=lambda f: {"number": f["number"], "method": f["method"]}, handler=h_merge,
                      rate=C.EXPAND_RATES["pr-merge"])
    C.register_action("launch-stop", cls="safe-write", required=("id",), fields=lambda b: {"id": b["id"]},
                      audit=lambda f: {"id": f["id"]}, handler=h_stop)

    a, b, c = git_repo(base, "alpha"), git_repo(base, "bravo"), git_repo(base, "charlie")
    ea, err = S.add_repo(a, False)
    expect("2a add_repo (alpha)", ea is not None, err)
    repo_a = ea["id"]
    launch = lambda root, repo, **kw: d(C, root, "launch-session", dict({"repo": repo, "branch": "feat/x", "prompt": PROMPT}, **kw))

    # -- 2. switch off: refused before the params are read, audited twice ----------------------------------------------
    r2 = mkroot()
    res = launch(r2, repo_a)
    expect("2b switch off, repo allowlisted -> not-allowed", res[:2] == (False, "not-allowed") and not calls, res)
    expect("2c ... even with malformed params (the gate comes first)", d(C, r2, "launch-session", {"repo": 5})[:2] == (False, "not-allowed"))
    expect("2d both logs hold one line per attempt", len(lines(aud(r2))) == 2 and len(lines(evt(r2))) == 2)

    # -- 3. switch on + allowlisted: the handler runs with the ALLOWLIST's path ------------------------------------------
    S.set_switch("launch", True)
    r3 = mkroot()
    res = launch(r3, repo_a)
    expect("3a on + allowlisted by id -> ok with the handler's id", res[0] is True and res[2].get("id") == "l-77", res)
    expect("3b the handler got the allowlist's own path, never the phone's", calls == [(a, repo_a)], calls)
    al, el = lines(aud(r3)), lines(evt(r3))
    expect("3c one audit line, one relay-events line", len(al) == 1 and len(el) == 1, (len(al), len(el)))
    if al and el:
        expect("3d the audit line carries the id; the event line says remote-action with ref = that id and the repo id",
               al[0].get("id") == "l-77" and el[0].get("event") == "remote-action" and el[0].get("ref") == "l-77"
               and el[0].get("repo") == repo_a and el[0].get("device") == "a1b2c3d4" and el[0].get("ok") is True
               and el[0].get("detail") is None and el[0].get("ts") == al[0].get("ts") and el[0].get("action") == "launch-session", (al[0], el[0]))
        expect("3e audit params: the central whitelist dropped prompt, path and rid",
               set(al[0]["params"]) == {"repo", "branch", "model", "mode"} and "rid" not in al[0], al[0]["params"])
    blob = open(aud(r3)).read() + open(evt(r3)).read()
    expect("3f no prompt text, no path and no rid in either log", PROMPT.split()[0] not in blob and "/etc/passwd" not in blob
           and "/Users/" not in blob and base not in blob and "L-1" not in blob, blob[:300])

    # -- 4. not on the allowlist: by id, by LABEL (an id-shaped one), by PATH ----------------------------------------------
    n = len(calls)
    expect("4a an id nothing added -> not-allowed", launch(mkroot(), S.repo_id(c))[:2] == (False, "not-allowed"))
    lab = git_repo(base, "r-beef")
    el_, err = S.add_repo(lab, False)
    if el_ is not None and el_["id"] != "r-beef":
        expect("4b a repo named by its LABEL (r-beef, shaped like an id) -> not-allowed", launch(mkroot(), "r-beef")[:2] == (False, "not-allowed"))
    expect("4c a repo named by its label (alpha) -> not-allowed", launch(mkroot(), "alpha")[:2] == (False, "not-allowed"))
    expect("4d a repo named by its PATH -> not-allowed", launch(mkroot(), a)[:2] == (False, "not-allowed"))
    expect("4e none of those reached the handler", len(calls) == n, calls)

    # -- 5. a symlink swapped in after the add ------------------------------------------------------------------------------
    swp = git_repo(base, "swap")
    es, err = S.add_repo(swp, False)
    r5 = mkroot()
    expect("5a before the swap -> ok", launch(r5, es["id"])[0] is True)
    os.rename(swp, swp + ".bak")
    os.symlink(c, swp)
    n = len(calls)
    expect("5b after the swap -> not-allowed, handler not run", launch(r5, es["id"])[:2] == (False, "not-allowed") and len(calls) == n)
    expect("5c ... and the phone is no longer offered it", all(x["id"] != es["id"] for x in C.launch_state(r5).get("repos", [])))
    os.unlink(swp)
    os.rename(swp + ".bak", swp)

    # -- 6. merge: its own switch, the session's own repo, --merge ----------------------------------------------------------
    rm = git_repo(base, "mroot")
    S.set_switch("merge", False)
    merge = lambda root, **kw: d(C, root, "pr-merge", dict({"number": 12, "method": "squash"}, **kw))
    expect("6a merge switch off (launch on) -> not-allowed", merge(rm)[:2] == (False, "not-allowed"))
    S.set_switch("merge", True)
    expect("6b merge on, the session repo not allowlisted -> not-allowed", merge(rm)[:2] == (False, "not-allowed"))
    S.add_repo(rm, False)
    expect("6c allowlisted without --merge -> not-allowed", merge(rm)[:2] == (False, "not-allowed") and not merged)
    em, err = S.add_repo(rm, True)
    expect("6d allowlisted with --merge -> ok", merge(rm)[0] is True and merged == [(em["id"], True)], merged)
    expect("6e a malformed number (a string) with everything allowed -> bad-params", merge(rm, number="12")[:2] == (False, "bad-params"))
    S.set_switch("merge", False)
    expect("6f ... and with the switch off the same params are not-allowed (gate first)", merge(rm, number="12")[:2] == (False, "not-allowed"))

    # -- 7. the kill switch beats everything -- except launch-stop ---------------------------------------------------------
    S.set_switch("merge", True)
    for how in ("env", "file"):
        r7 = mkroot()
        if how == "env":
            os.environ["HMD_UI_CONTROLS"] = "0"
        else:
            C.set_enabled(r7, False)
        n = len(calls)
        expect("7a (%s) launch-session, everything allowed -> controls-off" % how, launch(r7, repo_a)[:2] == (False, "controls-off") and len(calls) == n)
        expect("7b (%s) pr-merge -> controls-off" % how, merge(r7)[:2] == (False, "controls-off"))
        expect("7c (%s) save-checkpoint -> controls-off" % how, d(C, r7, "save-checkpoint", {})[:2] == (False, "controls-off"))
        stopped.clear()
        res = d(C, r7, "launch-stop", {"id": "l-77"})
        expect("7d (%s) launch-stop is exempt: it runs" % how, res[0] is True and stopped == ["l-77"], res)
        expect("7e (%s) the audit holds all 4 attempts; the timeline the 3 expand-ish ones" % how, len(lines(aud(r7))) == 4 and len(lines(evt(r7))) == 3, (len(lines(aud(r7))), len(lines(evt(r7)))))
        os.environ.pop("HMD_UI_CONTROLS", None)

    # -- 8. the central audit filter: a handler's own rule cannot widen it -----------------------------------------------------
    r8 = mkroot()
    token = "gh" + "p_" + "a" * 36
    launch(r8, repo_a, branch=token)
    launch(r8, repo_a, branch="/abs/path/branch")
    launch(r8, repo_a, branch="feat/ok")
    rows = lines(aud(r8))
    expect("8a a secret-shaped branch and an absolute-path branch are dropped from params, a clean one stays",
           len(rows) == 3 and "branch" not in rows[0]["params"] and "branch" not in rows[1]["params"] and rows[2]["params"].get("branch") == "feat/ok",
           [x["params"] for x in rows])
    expect("8b ... and the token is nowhere in either log", token not in open(aud(r8)).read() + open(evt(r8)).read())

    # -- 9. an expand command that cannot be audited is not run -----------------------------------------------------------------
    r9 = mkroot()
    os.makedirs(os.path.join(r9, ".heimdall"))
    open(os.path.join(r9, ".heimdall", "ui"), "w").close()   # a FILE where the audit directory must be
    n = len(calls)
    res = launch(r9, repo_a)
    expect("9a unwritable audit log -> expand refused internal-error, handler not run", res[:2] == (False, "internal-error") and len(calls) == n, res)
    stopped.clear()
    res = d(C, r9, "launch-stop", {"id": "l-77"})
    expect("9b ... while a launch-stop (reduce-direction) still runs", res[0] is True and stopped == ["l-77"], res)

    # -- 10. rate limits: 1 a minute; merge 1 per 30 s and 5 an hour ------------------------------------------------------------
    r10 = mkroot()
    first = d(C, r10, "launch-session", {"repo": repo_a, "branch": "b"}, clear=False)
    second = d(C, r10, "launch-session", {"repo": repo_a, "branch": "b"}, clear=False)
    expect("10a second launch inside a minute -> rate-limited with retry_after_s",
           first[0] is True and second[:2] == (False, "rate-limited") and 1 <= second[2].get("retry_after_s", 0) <= 60, (first, second))
    S.set_switch("merge", True)
    results = []
    for i in range(6):
        for key in ((rm, "pr-merge#0"), (rm, "*")):
            if key in C._BUCKETS:
                C._BUCKETS[key].tokens = C._BUCKETS[key].capacity
        results.append(d(C, rm, "pr-merge", {"number": 12, "method": "squash"}, clear=False)[:2])
    expect("10b five merges an hour: the 6th is rate-limited even with the 30 s bucket full",
           [r[0] for r in results[:5]] == [True] * 5 and results[5] == (False, "rate-limited"), results)
    S.set_switch("merge", False)

    # -- 11. the relay event log honours HMD_RELAY_EVENT_LOG --------------------------------------------------------------------
    r11 = mkroot()
    os.environ["HMD_RELAY_EVENT_LOG"] = ""
    launch(r11, repo_a)
    expect("11a HMD_RELAY_EVENT_LOG='' -> the audit line only, no event file at all", len(lines(aud(r11))) == 1 and not os.path.exists(evt(r11)))
    custom = os.path.join(base, "custom-events.jsonl")
    os.environ["HMD_RELAY_EVENT_LOG"] = custom
    launch(r11, repo_a)
    expect("11b a path override gets the event instead of the default", len(lines(custom)) == 1 and not os.path.exists(evt(r11)))
    os.environ.pop("HMD_RELAY_EVENT_LOG", None)

    # -- 12. state: remote_actions reads the audit back; launch offers id + label only --------------------------------------------
    S.set_switch("launch", True)
    ra = C.remote_actions(r3)
    expect("12a remote_actions: v 1, launch on, merge off, rows newest first with only the public fields",
           ra["v"] == 1 and ra["launch_enabled"] is True and ra["merge_enabled"] is False and len(ra["recent"]) == 1
           and set(ra["recent"][0]) == {"at", "action", "device", "repo_label", "ok", "detail"}
           and ra["recent"][0]["repo_label"] == "alpha" and ra["recent"][0]["action"] == "launch-session", ra)
    ra2 = C.remote_actions(r2)
    expect("12b a refusal is a row too, newest first, matching the audit", [(x["ok"], x["detail"]) for x in ra2["recent"]] == [(False, "not-allowed")] * 2
           and [x["action"] for x in ra2["recent"]] == [x["action"] for x in reversed(lines(aud(r2)))], ra2)
    expect("12c no path and no prompt anywhere in the slice", base not in json.dumps(ra) + json.dumps(ra2) and "PROMPT-MARKER" not in json.dumps(ra) + json.dumps(ra2))
    ls = C.launch_state(r3)
    expect("12d launch (on): enabled, repos = allowlist id + label only (no path)",
           ls["v"] == 1 and ls["enabled"] is True and {"id": repo_a, "label": "alpha"} in ls["repos"]
           and all(set(x) == {"id", "label"} for x in ls["repos"]) and base not in json.dumps(ls), ls)
    S.set_switch("launch", False)
    expect("12e launch (off) is {v:1, enabled:false}: no repos", C.launch_state(r3) == {"v": 1, "enabled": False}, C.launch_state(r3))

    # -- 13. no ALLOWED action writes either switch ---------------------------------------------------------------------------
    rg = git_repo(base, "g14")
    probes = {"interrupt": {}, "save-checkpoint": {}, "hook-toggle": {"id": "parallel-gate", "enabled": False},
              "fallback-mode": {"mode": "off"}, "launch-session": {"repo": repo_a, "branch": "b"},
              "pr-merge": {"number": 1, "method": "squash"}, "launch-stop": {"id": "l-77"},
              "dashboard-request": {"rid": "q-00000001", "op": "create", "dashboard_id": "d-0a0a0a0a", "screen_id": "s-0b0b0b0b",
                                    "tile_id": "t-0c0c0c0c", "project": os.path.basename(rg), "text": "daily new customers"},
              "quick-ask": {"rid": "q-00000002", "project": os.path.basename(rg), "text": "how many orders today"},
              "attach-begin": {"rid": "a-00000001", "name": "shot.jpg", "mime": "image/jpeg", "bytes": 1, "w": 1, "h": 1, "n": 1, "sha256": "0" * 64},
              "attach-chunk": {"rid": "a-00000001-0", "id": "att-00000000", "idx": 0, "b64": "AA=="},
              "attach-commit": {"rid": "a-00000001-c", "id": "att-00000000"}}
    files = [os.path.join(home, "remote-launch.json"), os.path.join(home, "remote-merge.json"),
             os.path.join(home, "remote-dashboards.json"), os.path.join(home, "remote-asks.json")]

    def snap():
        out = []
        for f in files:
            out.append((os.stat(f).st_mtime_ns, open(f, "rb").read()) if os.path.exists(f) else None)
        return out

    for phase in ("absent", "off"):
        off()
        if phase == "off":
            S.set_switch("launch", False)
            S.set_switch("merge", False)
        before = snap()
        for action in sorted(C.ALLOWED_ACTIONS):
            if action not in probes:
                expect("13 a probe exists for %s" % action, False)
                continue
            d(C, rg, action, probes[action])
        expect("13 no allowed action wrote a switch file (%s)" % phase, snap() == before, (before, snap()))

    # -- 14. class tags and the registry -----------------------------------------------------------------------------------------------
    expect("14a every allowed action has a valid class tag", all(C._ACTIONS[x]["cls"] in C.CLASSES for x in C.ALLOWED_ACTIONS))
    pins = {"interrupt": "safe-write", "save-checkpoint": "safe-write", "hook-toggle": "risky-write", "fallback-mode": "risky-write",
            "launch-session": "expand", "pr-merge": "expand", "launch-stop": "safe-write"}
    expect("14b the classes are the pinned ones", all(C._ACTIONS[k]["cls"] == v for k, v in pins.items()), {k: C._ACTIONS[k]["cls"] for k in pins})
    C2 = load(libdir)
    hnd = lambda root, fields, ctx: (True, None, {})

    def rejects(**kw):
        try:
            C2.register_action(**kw)
        except ValueError:
            return True
        return False

    expect("14c an unknown class is refused", rejects(name="x-bad", cls="admin", handler=hnd))
    expect("14d expand without a switch is refused", rejects(name="x-exp", cls="expand", handler=hnd))
    expect("14e expand with a switch that does not exist is refused", rejects(name="x-exp2", cls="expand", switch="deploy", handler=hnd))
    expect("14f a non-expand action naming a switch is refused", rejects(name="x-read", cls="read", switch="launch", handler=hnd))
    expect("14g a reserved name cannot be registered as a weaker class", rejects(name="launch-session", cls="safe-write", handler=hnd))
    expect("14h a reserved name cannot be re-pointed at the other switch", rejects(name="pr-merge", cls="expand", switch="launch", handler=hnd))
    expect("14i only a safe-write action can be kill-switch exempt", rejects(name="launch-stop", cls="risky-write", handler=hnd))
    expect("14j a duplicate name is refused", rejects(name="interrupt", cls="safe-write", handler=hnd))
    C2.register_action("x-view", cls="read", handler=hnd)
    expect("14k a good registration lands in ALLOWED_ACTIONS", "x-view" in C2.ALLOWED_ACTIONS and "x-view" not in C.ALLOWED_ACTIONS)
    expect("14l the timeline covers the reserved names, launch-stop and dashboard-request (its create/refine/remove ops only), nothing else",
           C._timeline_names() == {"launch-session", "pr-merge", "launch-stop", "dashboard-request"}, C._timeline_names())
    return failed


def cli_checks(libdir):
    failed = []

    def expect(label, cond, got=""):
        if not cond:
            failed.append("%s [%s]" % (label, str(got)[:200]))

    base = tempfile.mkdtemp(prefix="cli-")
    home = os.path.join(base, "home")
    os.makedirs(home)
    env = {"HEIMDALL_HOME": home}
    os.environ.pop("HMD_UI_CONTROLS", None)
    lp, mp = os.path.join(home, "remote-launch.json"), os.path.join(home, "remote-merge.json")
    al = os.path.join(home, "app", "launch-allowlist.json")
    repo = git_repo(base, "proj")

    for sub, f in (("remote-launch", lp), ("remote-merge", mp)):
        rc, out = cli(libdir, [sub, "on"], env=env)
        expect("%s on with stdin not a terminal is refused and writes nothing" % sub, rc != 0 and not os.path.exists(f) and "terminal" in out, (rc, out))
    rc, out = cli(libdir, ["launch-allow", repo], env=env)
    expect("launch-allow (add) without a terminal is refused and writes nothing", rc != 0 and not os.path.exists(al), (rc, out))
    rc, out = cli(libdir, ["remote-launch", "on"], tty=True, env=dict(env, HMD_UI_CONTROLS="0"))
    expect("on at a terminal is refused under HMD_UI_CONTROLS=0", rc != 0 and not os.path.exists(lp) and "HMD_UI_CONTROLS" in out, (rc, out))
    os.makedirs(os.path.join(repo, ".heimdall", "app"))
    open(os.path.join(repo, ".heimdall", "app", "controls-disabled"), "w").close()
    rc, out = cli(libdir, ["remote-launch", "on", "--repo", repo], tty=True, env=env)
    expect("on at a terminal is refused where the repo's kill switch file exists", rc != 0 and not os.path.exists(lp), (rc, out))
    os.unlink(os.path.join(repo, ".heimdall", "app", "controls-disabled"))

    rc, out = cli(libdir, ["remote-launch", "on", "--repo", repo], tty=True, env=env)
    expect("on at a terminal -> exit 0, file written", rc == 0 and os.path.exists(lp), (rc, out))
    if os.path.exists(lp):
        obj = json.load(open(lp))
        expect("the switch file is {enabled:true, since:<iso>} mode 0600", set(obj) == {"enabled", "since"} and obj["enabled"] is True
               and re.fullmatch(r"\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ", obj["since"]) and stat.S_IMODE(os.stat(lp).st_mode) == 0o600, (obj, oct(os.stat(lp).st_mode)))
    rc, out = cli(libdir, ["remote-launch", "status"], env=env)
    expect("status (no terminal needed) says on", rc == 0 and "remote launch: on" in out, (rc, out))
    rc, out = cli(libdir, ["remote-merge", "status"], env=env)
    expect("the merge switch is its own: off", rc == 0 and "remote merge: off" in out, (rc, out))
    rc, out = cli(libdir, ["remote-launch", "off"], env=env)
    expect("off needs no terminal and writes enabled:false", rc == 0 and json.load(open(lp)).get("enabled") is False and "remote launch: off" in out, (rc, out))

    good = {"enabled": True, "since": GOOD_SINCE}

    def put(obj, mode=0o600, raw=None):
        if os.path.lexists(lp):
            os.unlink(lp)
        with open(lp, "w") as f:
            f.write(raw if raw is not None else json.dumps(obj))
        os.chmod(lp, mode)

    put(good)
    rc, out = cli(libdir, ["remote-launch", "status"], env=env)
    expect("control: a hand-written, well-formed 0600 file reads on", "remote launch: on" in out, out)
    for label, setup in (("group/world-writable", lambda: put(good, 0o666)),
                         ("junk", lambda: put(None, raw="{not json")),
                         ("oversized", lambda: put(None, raw=json.dumps(dict(good, pad="x" * 8000)))),
                         ("enabled mistyped", lambda: put({"enabled": "yes", "since": GOOD_SINCE})),
                         ("since missing", lambda: put({"enabled": True})),
                         ("a list", lambda: put([1, 2]))):
        setup()
        rc, out = cli(libdir, ["remote-launch", "status"], env=env)
        expect("a switch file that is %s reads as OFF" % label, "remote launch: off" in out, out)
    if os.path.lexists(lp):
        os.unlink(lp)
    target = os.path.join(base, "elsewhere.json")
    with open(target, "w") as f:
        json.dump(good, f)
    os.chmod(target, 0o600)
    os.symlink(target, lp)
    rc, out = cli(libdir, ["remote-launch", "status"], env=env)
    expect("a switch file that is a symlink reads as OFF", "remote launch: off" in out, out)
    os.unlink(lp)

    real = os.path.realpath(repo)
    rid = "r-" + hashlib.sha256(real.encode()).hexdigest()[:4]
    rc, out = cli(libdir, ["launch-allow", repo], tty=True, env=env)
    entries = json.load(open(al)) if os.path.exists(al) else None
    expect("launch-allow at a terminal adds {id, label, path, merge:false}; id = r- + sha256(realpath)[:4]",
           rc == 0 and entries == [{"id": rid, "label": "proj", "path": real, "merge": False}], (rc, out, entries))
    expect("the allowlist is mode 0600", os.path.exists(al) and stat.S_IMODE(os.stat(al).st_mode) == 0o600)
    rc, out = cli(libdir, ["launch-allow", repo, "--merge"], tty=True, env=env)
    entries = json.load(open(al))
    expect("--merge sets merge:true on the same entry (no duplicate)", rc == 0 and len(entries) == 1 and entries[0]["merge"] is True, entries)
    link = os.path.join(base, "link-to-proj")
    os.symlink(repo, link)
    rc, out = cli(libdir, ["launch-allow", link], tty=True, env=env)
    entries = json.load(open(al))
    expect("a symlinked path adds the REAL path (one entry), and a re-add without --merge restates merge:false",
           rc == 0 and len(entries) == 1 and entries[0]["path"] == real and entries[0]["merge"] is False, entries)
    sub = os.path.join(repo, "sub")
    os.makedirs(sub)
    plain = os.path.join(base, "plain")
    os.makedirs(plain)
    for label, path in (("a subdirectory of a repo", sub), ("a directory that is not a repository", plain), ("a missing path", os.path.join(base, "nope"))):
        rc, out = cli(libdir, ["launch-allow", path], tty=True, env=env)
        expect("%s is refused" % label, rc != 0 and len(json.load(open(al))) == 1, (rc, out))
    rc, out = cli(libdir, ["launch-allow", "--list"], env=env)
    expect("--list needs no terminal and shows the id, the label and the merge flag", rc == 0 and rid in out and "proj" in out and "merge" in out, (rc, out))
    rc, out = cli(libdir, ["launch-allow", "--remove", "r-ffff"], env=env)
    expect("--remove of an id that is not there fails", rc != 0 and len(json.load(open(al))) == 1, (rc, out))
    rc, out = cli(libdir, ["launch-allow", "--remove", "proj"], env=env)
    expect("--remove takes an id, never a label", rc != 0 and len(json.load(open(al))) == 1, (rc, out))
    rc, out = cli(libdir, ["launch-allow", "--remove", rid], env=env)
    expect("--remove <id> needs no terminal and removes it", rc == 0 and json.load(open(al)) == [], (rc, out))
    rc, out = cli(libdir, ["status-line"], env=env)
    expect("status-line is one line for `hmd app status`", rc == 0 and out.startswith("remote:") and out.count("\n") == 1, (rc, out))
    rc, out = cli(libdir, ["frobnicate"], env=env)
    expect("an unknown subcommand is a usage error", rc == 2, (rc, out))
    return failed


def checks(libdir, parts):
    failed = []
    if "gate" in parts:
        failed += gate_checks(libdir)
    if "cli" in parts:
        failed += cli_checks(libdir)
    return failed


MUTANTS = [
    ("audit-line-carries-the-prompt", "gate", "companion_ui_controls.py",
     "    return {k: v for k, v in params.items() if k in _AUDIT_FIELDS and _AUDIT_FIELDS[k](v) and not secret_shaped(v)}",
     "    return dict(params)"),
    ("switch-flippable-by-an-action", "gate", "companion_ui_controls.py",
     "def _do_save_checkpoint(root, fields, ctx):\n", "def _do_save_checkpoint(root, fields, ctx):\n    _switches().set_switch(\"launch\", True)\n"),
    ("allowlist-matched-by-label", "gate", "companion_remote_switches.py",
     "        if entry[\"id\"] == wanted:", "        if entry[\"label\"] == wanted:"),
    ("symlink-swap-not-rechecked", "gate", "companion_remote_switches.py",
     "    return os.path.realpath(entry[\"path\"]) == entry[\"path\"] and os.path.isdir(entry[\"path\"])",
     "    return os.path.isdir(entry[\"path\"])"),
    ("merge-flag-ignored", "gate", "companion_remote_switches.py",
     "    if switch == \"merge\" and entry[\"merge\"] is not True:", "    if False:"),
    ("expand-gate-skipped", "gate", "companion_ui_controls.py",
     "        if spec[\"cls\"] == CLASS_EXPAND:\n            entry, repo, detail = _authorize(root, spec, fields)",
     "        if False:\n            entry, repo, detail = _authorize(root, spec, fields)"),
    ("switch-not-consulted", "gate", "companion_ui_controls.py",
     "    if sw is None or not sw.switch_enabled(spec[\"switch\"]):", "    if sw is None:"),
    ("launch-stop-needs-the-switch", "gate", "companion_ui_controls.py",
     "KILL_SWITCH_EXEMPT = frozenset((\"launch-stop\",))", "KILL_SWITCH_EXEMPT = frozenset()"),
    ("kill-switch-exempts-everything", "gate", "companion_ui_controls.py",
     "    if action not in KILL_SWITCH_EXEMPT and not controls_enabled(root):", "    if False:"),
    ("expand-runs-unaudited", "gate", "companion_ui_controls.py",
     "        if spec[\"cls\"] == CLASS_EXPAND and not _audit_ready(root):", "        if False:"),
    ("no-second-record", "gate", "companion_ui_controls.py",
     "    if name is not None and name in _timeline_names() and _timeline_row_ok(name, line.get(\"op\")):", "    if False:"),
    ("reserved-name-ungated-without-a-handler", "gate", "companion_ui_controls.py",
     "        detail = \"not-allowed\" if not _switch_on(gate) else \"not-implemented\"", "        detail = \"not-implemented\""),
    ("class-tag-unchecked", "gate", "companion_ui_controls.py",
     "    if cls not in CLASSES:\n        raise ValueError(\"unknown class\")", "    if False:\n        raise ValueError(\"unknown class\")"),
    ("merge-hourly-ceiling-dropped", "gate", "companion_ui_controls.py",
     "((1, 1 / 30.0), (5, 5 / 3600.0))}", "((1, 1 / 30.0),)}"),
    ("cli-needs-no-terminal", "cli", "companion_remote_switches.py",
     "    if not sys.stdin.isatty():", "    if False:"),
    ("switch-file-not-trust-checked", "cli", "companion_remote_switches.py",
     "        if st.st_mode & 0o022:", "        if False:"),
]


def main():
    mode, libdir = sys.argv[1], sys.argv[2]
    if mode == "real":
        try:
            failed = checks(libdir, ("gate", "cli"))
        except Exception as e:
            failed = ["crashed: %s: %s" % (type(e).__name__, e)]
        print("REAL", json.dumps(failed))
        return
    sources = {n: open(os.path.join(libdir, n)).read() for n in ("companion_ui_controls.py", "companion_remote_switches.py")}
    for name, part, fname, old, new in MUTANTS:
        if old not in sources[fname]:
            print("MUTANT", name, "NO-ANCHOR")
            continue
        d = tempfile.mkdtemp(prefix="mut-")
        for n, src in sources.items():
            with open(os.path.join(d, n), "w") as f:
                f.write(src.replace(old, new, 1) if n == fname else src)
        try:
            failed = checks(d, (part,))
        except Exception as e:
            failed = ["crashed: %s" % type(e).__name__]
        print("MUTANT", name, "CAUGHT" if failed else "SURVIVED", json.dumps(failed)[:140])


main()
PYEOF

# ═══ 1-4. the battery against the real modules: the CLI, the allowlist, the gate, the audit, the switches ═══
REAL_OUT="$(python3 "$BATT" real "$LIBDIR" 2>/dev/null | tail -1)"
if [ "$REAL_OUT" = "REAL []" ]; then
  ok "1-4. the CLI (terminal, kill switch, trust checks, allowlist) and the gate (switch, allowlist by id, symlink, merge flag, kill switch + launch-stop, audit twice, fail-closed audit, rates, state, class tags) all hold"
else
  bad "1-4. the battery fails on the real modules: $(printf '%s' "$REAL_OUT" | cut -c1-1800)"
  printf '%s' "$REAL_OUT" | sed -e 's/^REAL //' | python3 -c 'import json,sys
for x in json.load(sys.stdin): print("       -", x)' 2>/dev/null
fi

# the writers are named nowhere a remote command can reach
LEAK=""
for f in "$CTL_LIB" "$REPO/bin/heimdall-relay-client" "$UI_PY" "$REPO/bin/lib/companion_view.py"; do
  grep -nE 'set_switch|_write_switch|add_repo|remove_repo|remote-launch\.json|remote-merge\.json|launch-allowlist' "$f" >/dev/null 2>&1 && LEAK="$LEAK $(basename "$f")"
done
if [ -z "$LEAK" ]; then ok "4b. nothing a remote command can reach (controls module, relay client, hmd ui, view module) names a switch writer, a switch file or the allowlist file"; else bad "4b. these name a switch writer / file:$LEAK"; fi

# ═══ 5. the real hmd ui ═══════════════════════════════════════════════════════════════════════════════════════
FIX="$(new_repo main)"
ALLOWED_REPO="$(new_repo allowed-proj)"
start_ui "$FIX" || { printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"; exit 1; }
MARK="DIRECT-PROMPT-MARKER-$$"
PAYLOAD="$(jq -cn --arg m "$MARK" '{action:"launch-session",params:{rid:"L-1",repo:"r-0000",branch:"feat/x",prompt:($m + " /etc/hosts")}}')"
ctl "$PAYLOAD"
expect "5a launch-session over /api/control with the switch off -> 403 not-allowed" 403 '.ok == false and .detail == "not-allowed"'
ctl '{"action":"pr-merge","params":{"rid":"M-1","number":12,"method":"squash"}}'
expect "5b pr-merge with the switch off -> 403 not-allowed" 403 '.ok == false and .detail == "not-allowed"'
AUD="$FIX/.heimdall/ui/controls-audit.jsonl"
EVT="$FIX/.heimdall/app/relay-events.jsonl"
if jq -e -s 'length == 2 and all(.[]; .detail == "not-allowed" and .ok == false and .params == {} and (has("rid") | not) and .device == "direct")' "$AUD" >/dev/null 2>&1 \
   && jq -e -s 'length == 2 and all(.[]; .event == "remote-action" and .ok == false and .detail == "not-allowed" and .device == "direct" and .repo == null and .ref == null)' "$EVT" >/dev/null 2>&1 \
   && [ "$(mode_of "$EVT")" = "600" ]; then
  ok "5c each refused expand command left ONE controls-audit line and ONE relay-events remote-action line (0600)"
else
  bad "5c logs: $(cat "$AUD" 2>/dev/null | head -c 400) // $(cat "$EVT" 2>/dev/null | head -c 400)"
fi
if ! grep -rq "$MARK" "$FIX/.heimdall" "$HEIMDALL_HOME" 2>/dev/null && ! grep -q '/etc/hosts' "$AUD" "$EVT" 2>/dev/null; then
  ok "5d the prompt text appears in neither log nor anywhere under .heimdall"
else
  bad "5d the prompt leaked into a log or a file"
fi
if poll_state '.remote_actions.v == 1 and .remote_actions.launch_enabled == false and .remote_actions.merge_enabled == false and (.remote_actions.recent | length) == 2 and .launch == {"v":1,"enabled":false}' 15; then
  ok "5e state.remote_actions (both switches off, 2 recent) and state.launch {v:1, enabled:false} are in /api/state"
else
  bad "5e state: $(state | jq -c '{remote_actions, launch}')"
fi
if state | jq -e '.remote_actions.recent | (.[0].action == "pr-merge") and (.[1].action == "launch-session") and all(.[]; .ok == false and .detail == "not-allowed" and .device == "direct" and .repo_label == null and (keys == ["action","at","detail","device","ok","repo_label"]))' >/dev/null 2>&1; then
  ok "5f recent is newest first and matches the audit (action, ok, detail, device) with no params beyond repo_label"
else
  bad "5f recent: $(state | jq -c .remote_actions.recent)"
fi
E0="$(etag)"
tty_run python3 "$SW" remote-launch on --repo "$FIX"; RC1=$?
tty_run python3 "$SW" launch-allow "$ALLOWED_REPO"; RC2=$?
if [ "$RC1" = 0 ] && [ "$RC2" = 0 ] && [ "$(mode_of "$HEIMDALL_HOME/remote-launch.json")" = "600" ]; then ok "5g the operator's two commands (at a terminal): remote-launch on, launch-allow <repo>"; else bad "5g on=$RC1 allow=$RC2"; fi
if poll_state '.launch.enabled == true and (.launch.repos | length) == 1 and (.launch.repos[0] | keys == ["id","label"]) and (.launch.repos[0].id | test("^r-[0-9a-f]{4}$")) and .launch.repos[0].label == "allowed-proj" and .remote_actions.launch_enabled == true' 15; then
  ok "5h state.launch now lists the allowlisted repo by id + label (and state.remote_actions.launch_enabled is true)"
else
  bad "5h state after on+allow: $(state | jq -c '{remote_actions: .remote_actions | del(.recent), launch}')"
fi
E1="$(etag)"
if [ "$E0" != "$E1" ] && ! state | grep -qF "$ALLOWED_REPO"; then ok "5i the state digest moved with the switch, and the allowlisted path is nowhere in the state (id + label only)"; else bad "5i digest moved: $([ "$E0" != "$E1" ] && echo yes || echo no); path in state: $(state | grep -cF "$ALLOWED_REPO")"; fi
ctl "$PAYLOAD"
expect "5j switch on, no handler registered -> 404 not-implemented (the gate passed; it never runs anything)" 404 '.ok == false and .detail == "not-implemented"'
if poll_state '(.remote_actions.recent | length) == 3 and .remote_actions.recent[0].detail == "not-implemented"' 15 && [ "$(wc -l < "$AUD" | tr -d ' ')" = 3 ] && [ "$(wc -l < "$EVT" | tr -d ' ')" = 3 ]; then
  ok "5k ... and it is recorded in both logs and in recent as well"
else
  bad "5k logs: audit $(wc -l < "$AUD") events $(wc -l < "$EVT")"
fi
tty_run python3 "$SW" remote-merge on --repo "$FIX" >/dev/null
tty_run python3 "$SW" remote-merge off >/dev/null 2>&1
if poll_state '.remote_actions.launch_enabled == true and .remote_actions.merge_enabled == false' 15; then ok "5l the merge switch is separate from the launch switch in the state too"; else bad "5l flags: $(state | jq -c '.remote_actions | del(.recent)')"; fi
PAGE="$(curl -s "$UI_BASE/?token=$UI_TOKEN")"
if printf '%s' "$PAGE" | grep -q 'id="p-remote"' && printf '%s' "$PAGE" | grep -q 'Remote actions' && printf '%s' "$PAGE" | grep -q 'remote_actions' && grep -q 'remote_actions' "$UI_PY"; then
  ok "5m hmd ui serves the Remote actions card (and sentinels/hmd-ui.py collects remote_actions)"
else
  bad "5m the page has no Remote actions card"
fi
tty_run python3 "$SW" remote-launch off >/dev/null 2>&1
stop_ui

# ═══ 6. mutants: the battery against deliberately broken copies must fail ═══════════════════════════════════
MUTOUT="$(python3 "$BATT" mutants "$LIBDIR" 2>/dev/null)"
NMUT="$(printf '%s' "$MUTOUT" | grep -c '^MUTANT ' || true)"
CAUGHT="$(printf '%s' "$MUTOUT" | grep -c ' CAUGHT ' || true)"
SURV="$(printf '%s' "$MUTOUT" | grep -c ' SURVIVED \| NO-ANCHOR' || true)"
if [ "$NMUT" = "16" ] && [ "$CAUGHT" = "16" ] && [ "$SURV" = "0" ]; then
  ok "6. all 16 mutants (prompt in the audit, a switch an action can flip, allowlist by label, symlink swap not re-checked, merge flag ignored, gate skipped, switch not consulted, launch-stop needing the switch, a kill switch that exempts everything, an expand run unaudited, no second record, a reserved name ungated, an unchecked class, a dropped hourly ceiling, a CLI needing no terminal, an untrusted switch file) are caught"
else
  bad "6. caught $CAUGHT of 16 (saw $NMUT), survived/no-anchor $SURV: $(printf '%s' "$MUTOUT" | grep -v ' CAUGHT ' | head -8)"
fi

# ═══ 7. the `hmd app` arms: bin/heimdall-app hands remote-launch / remote-merge / launch-allow to the module, and `status` prints its summary line ═══
APP="$REPO/bin/heimdall-app"
FAKE_TS="$TMPROOT/fake-tailscale"
printf '#!/bin/sh\nexit 1\n' > "$FAKE_TS"
chmod +x "$FAKE_TS"
# hmd_app ARGS... -- the real script, stdin NOT a terminal, stderr folded in; tailscale, its plist and the inbox are stand-ins that
# answer "no", so `status` never reaches for the real ones
hmd_app() {
  HMD_TAILSCALE_BIN="$FAKE_TS" HMD_TAILSCALE_APP_PLIST="$TMPROOT/no-such.plist" HEIMDALL_INBOX_DELIVER_BIN="$TMPROOT/no-such-inbox" \
    "$APP" "$@" </dev/null 2>&1
}
ARMS_REPO="$(new_repo arms-proj)"
ARMS_RELAY="$(new_repo arms-relay)"
ARMS_ID="$(python3 -c 'import hashlib, sys; print("r-" + hashlib.sha256(sys.argv[1].encode()).hexdigest()[:4])' "$ARMS_REPO")"
ALLOWLIST="$HEIMDALL_HOME/app/launch-allowlist.json"
rm -rf "$HEIMDALL_HOME/remote-launch.json" "$HEIMDALL_HOME/remote-merge.json" "$HEIMDALL_HOME/app"

OUT="$(hmd_app remote-launch on)"; RC=$?
if [ "$RC" -ne 0 ] && printf '%s' "$OUT" | grep -q 'interactive terminal' && [ ! -e "$HEIMDALL_HOME/remote-launch.json" ]; then
  ok "7a. hmd app remote-launch on without a terminal is refused through the arm and writes nothing"
else
  bad "7a. rc=$RC out=$OUT file=$(find "$HEIMDALL_HOME" -mindepth 1 -maxdepth 1 -exec basename {} \; 2>&1 | sort | tr '\n' ' ')"
fi
OUT="$(hmd_app launch-allow "$ARMS_REPO")"; RC=$?
if [ "$RC" -ne 0 ] && printf '%s' "$OUT" | grep -q 'interactive terminal' && [ ! -e "$ALLOWLIST" ]; then
  ok "7b. hmd app launch-allow <repo> without a terminal is refused through the arm and writes nothing"
else
  bad "7b. rc=$RC out=$OUT"
fi
tty_run "$APP" remote-launch on --repo "$ARMS_REPO"; RC=$?
if [ "$RC" = 0 ] && printf '%s' "$TTY_OUT" | grep -q 'remote launch: on' && jq -e '.enabled == true' "$HEIMDALL_HOME/remote-launch.json" >/dev/null 2>&1 \
   && [ "$(mode_of "$HEIMDALL_HOME/remote-launch.json")" = "600" ]; then
  ok "7c. at a terminal, hmd app remote-launch on --repo DIR writes the switch (0600): the arm leaves the caller's own stdin in place"
else
  bad "7c. rc=$RC out=$TTY_OUT"
fi
tty_run "$APP" launch-allow "$ARMS_REPO" --merge; RC=$?
if [ "$RC" = 0 ] && jq -e --arg id "$ARMS_ID" --arg p "$ARMS_REPO" '. == [{"id": $id, "label": "arms-proj", "path": $p, "merge": true}]' "$ALLOWLIST" >/dev/null 2>&1; then
  ok "7d. at a terminal, hmd app launch-allow <repo> --merge adds {id, label, path, merge:true} (id = r- + sha256(realpath)[:4])"
else
  bad "7d. rc=$RC out=$TTY_OUT file=$(cat "$ALLOWLIST" 2>/dev/null)"
fi
if [ "$(mode_of "$ALLOWLIST")" = "600" ] && [ "$(mode_of "$HEIMDALL_HOME/app")" = "700" ] && [ ! -e "$HEIMDALL_HOME/.heimdall/app/launch-allowlist.json" ]; then
  ok "7e. the allowlist is \$HEIMDALL_HOME/app/launch-allowlist.json (0600, its directory 0700), not under a second .heimdall"
else
  bad "7e. file mode $(mode_of "$ALLOWLIST" 2>&1), dir mode $(mode_of "$HEIMDALL_HOME/app" 2>&1), doubled path present: $([ -e "$HEIMDALL_HOME/.heimdall/app/launch-allowlist.json" ] && echo yes || echo no)"
fi
OUT="$(hmd_app launch-allow --list)"; RC=$?
if [ "$RC" = 0 ] && printf '%s' "$OUT" | grep -q "$ARMS_ID" && printf '%s' "$OUT" | grep -q 'merge:yes'; then
  ok "7f. hmd app launch-allow --list needs no terminal and shows the entry"
else
  bad "7f. rc=$RC out=$OUT"
fi
OUT="$(hmd_app remote-launch status)"; RC=$?
if [ "$RC" = 0 ] && printf '%s\n' "$OUT" | grep -q '^remote launch: on (since ' && printf '%s\n' "$OUT" | grep -qx 'allowlist: 1 repo(s), 1 with merge'; then
  ok "7g. hmd app remote-launch status (no terminal) says on and the allowlist size"
else
  bad "7g. rc=$RC out=$OUT"
fi
OUT="$(hmd_app remote-merge status)"; RC=$?
if [ "$RC" = 0 ] && printf '%s\n' "$OUT" | grep -qx 'remote merge: off'; then
  ok "7h. hmd app remote-merge status is its own switch: off"
else
  bad "7h. rc=$RC out=$OUT"
fi
ARMS_LINE='remote: launch on, merge off, allowlist 1 repo(s)'
OUT="$(hmd_app status --repo "$ARMS_REPO")"; RC=$?
if [ "$RC" = 0 ] && printf '%s\n' "$OUT" | grep -qxF "$ARMS_LINE"; then
  ok "7i. hmd app status (tailscale report) prints the one-line remote summary"
else
  bad "7i. rc=$RC out=$OUT"
fi
mkdir -p "$ARMS_RELAY/.heimdall/app"
bash -c 'while :; do sleep 0.2; done' heimdall-relay-client &
ARMS_CLIENT=$!
PIDS+=("$ARMS_CLIENT")
jq -n --argjson pid "$ARMS_CLIENT" '{mode: "relay", pid_ui: null, pid_client: $pid, port: 1, relay: "https://relay.example.com", started_at: "2026-10-06T00:00:00Z"}' > "$ARMS_RELAY/.heimdall/app/connect.json"
OUT="$(hmd_app status --repo "$ARMS_RELAY")"; RC=$?
kill "$ARMS_CLIENT" 2>/dev/null
{ wait "$ARMS_CLIENT"; } 2>/dev/null
if [ "$RC" = 0 ] && printf '%s\n' "$OUT" | grep -qx 'mode: relay' && printf '%s\n' "$OUT" | grep -qxF "$ARMS_LINE"; then
  ok "7j. hmd app status (relay report) prints the same one-line remote summary"
else
  bad "7j. rc=$RC out=$OUT"
fi
OUT="$(hmd_app remote-launch off)"; RC=$?
if [ "$RC" = 0 ] && jq -e '.enabled == false' "$HEIMDALL_HOME/remote-launch.json" >/dev/null 2>&1 \
   && hmd_app status --repo "$ARMS_REPO" | grep -qxF 'remote: launch off, merge off, allowlist 1 repo(s)'; then
  ok "7k. hmd app remote-launch off needs no terminal, and the status line follows the switch"
else
  bad "7k. rc=$RC out=$OUT"
fi
OUT="$(hmd_app launch-allow --remove "$ARMS_ID")"; RC=$?
if [ "$RC" = 0 ] && jq -e '. == []' "$ALLOWLIST" >/dev/null 2>&1 \
   && hmd_app status --repo "$ARMS_REPO" | grep -qxF 'remote: launch off, merge off, allowlist 0 repo(s)'; then
  ok "7l. hmd app launch-allow --remove <id> needs no terminal, and the status line's allowlist size follows"
else
  bad "7l. rc=$RC out=$OUT file=$(cat "$ALLOWLIST" 2>/dev/null)"
fi
OUT="$(hmd_app remote-launch frobnicate)"; RC=$?
OUT2="$(hmd_app launch-allow)"; RC2=$?
if [ "$RC" = 2 ] && [ "$RC2" = 2 ] && printf '%s' "$OUT" | grep -q '^usage: hmd app remote-launch' && printf '%s' "$OUT2" | grep -q 'launch-allow <repo-path>'; then
  ok "7m. a malformed invocation is the module's usage error with exit status 2, unchanged by the arm"
else
  bad "7m. rc=$RC/$RC2 out=$OUT // $OUT2"
fi
HELP="$("$APP" --help 2>&1)"
if printf '%s' "$HELP" | grep -q 'hmd app remote-launch on|off|status' && printf '%s' "$HELP" | grep -q 'hmd app remote-merge  on|off|status' \
   && printf '%s' "$HELP" | grep -q 'hmd app launch-allow <repo-path>' && printf '%s' "$HELP" | grep -q 'app/launch-allowlist.json'; then
  ok "7n. hmd app --help documents the three arms and where the allowlist lives"
else
  bad "7n. help: $(printf '%s' "$HELP" | grep -n 'remote-\|launch-allow' | head -5)"
fi
NOPY="$TMPROOT/nopy"
mkdir -p "$NOPY/lib"
cp "$APP" "$NOPY/heimdall-app"
cp "$LIBDIR/hmd_tailscale.sh" "$NOPY/lib/hmd_tailscale.sh"
printf 'hmd_python() { return 1; }\n' > "$NOPY/lib/hmd-python.sh"
OUT="$("$NOPY/heimdall-app" remote-merge status 2>&1 </dev/null)"; RC=$?
if [ "$RC" = 2 ] && printf '%s' "$OUT" | grep -q 'hmd app remote-merge: python3 not found'; then
  ok "7o. with no python3 the arm says so and exits 2 (a copy of the script whose interpreter lookup finds none)"
else
  bad "7o. rc=$RC out=$OUT"
fi
if [ ! -e "$HEIMDALL_HOME/.heimdall" ]; then
  ok "7p. nothing in this suite created a second .heimdall under HEIMDALL_HOME"
else
  bad "7p. $HEIMDALL_HOME/.heimdall exists: $(find "$HEIMDALL_HOME/.heimdall" | head -5 | tr '\n' ' ')"
fi

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
