#!/usr/bin/env bash
# spike-pty.sh -- Wave 0 throwaway-pty harness for docs/analysis/2026-11-13-seamless-restart-spike.md
# (plan: docs/superpowers/plans/2026-11-13-seamless-update-restart.md, Task W0-spike). Kept as evidence:
# every number in the memo comes from a run of this file.
#
# What it does: starts ONE throwaway interactive `claude` per scenario inside a real pty that it allocates
# itself (os.openpty: the same primitive script(1) and expect(1) use, but with full control over signals,
# window size and the master-side byte stream), in a scratch HOME (trimmed copy of ~/.claude.json: onboarding
# done, only the scratch cwd trusted, no MCP servers; own settings.json with evidence hooks only; auto-update
# off) and a scratch cwd, on a cheap model. It signals only pids it forked itself, or a descendant of one that
# it verified by walking ppid links; it never touches a session it did not start and never reads/prints a
# credential (auth is the macOS keychain item the real binary reads through `security`, untouched).
#
# usage: W0_DIR=<scratch dir> bash spike-pty.sh <scenario>... | all
#   probe   startup state of an idle claude (fullscreen and default TUI): modes, sessions file, fds, signal masks
#   q1      SIGTERM / SIGHUP / SIGINT / `/exit` (control) at turn end, SIGTERM after a settle; fullscreen + default TUI
#   q3      session state vs `claude --resume <id>`
#   q4      sessions/<pid>.json status across idle / busy / permission dialog / background Bash / background subagent
#   q5      tty atime vs keystrokes and vs claude's own output; resize redraw metrics
#   q6      claude as a `&` job of a bash script that `wait`s (plain, and with `<&0`): keystrokes, Ctrl-C, resize
#   q7      does git / cp / mv rewrite a running script in place? (no claude involved)
#   script  Q2 cross-check: claude started under script(1)
# env: W0_CLAUDE_BIN (default: what ~/.local/bin/claude resolves to), W0_MODEL (default haiku), W0_SETTLE_S (15)
# output: $W0_DIR/out/<run>/{stream.raw,stream.txt,events.log,hooks.log,result.json}
set -euo pipefail
: "${W0_DIR:?W0_DIR must name the scratch directory (HOME, cwd and evidence live there)}"
export W0_DIR
[ "$#" -gt 0 ] || set -- probe
exec python3 -I - "$@" <<'PY'
import atexit, collections, errno, fcntl, glob, json, os, re, select, shutil, signal, struct, subprocess, sys, termios, time, traceback, uuid

ROOT = os.environ["W0_DIR"]
REAL_HOME = os.path.expanduser("~")
BIN = os.path.realpath(os.environ.get("W0_CLAUDE_BIN") or os.path.join(REAL_HOME, ".local", "bin", "claude"))
HOME = os.path.join(ROOT, "home")
CWD = os.path.realpath(os.path.join(ROOT, "cwd"))
OUT = os.path.join(ROOT, "out")
SESS_DIR = os.path.join(HOME, ".claude", "sessions")
MODEL = os.environ.get("W0_MODEL", "haiku")
SETTLE_S = float(os.environ.get("W0_SETTLE_S", "15"))
DEFAULT_ON = {7, 25}
EVENTS = ("SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse", "Notification", "Stop", "SubagentStop", "SessionEnd")
MODE_NAMES = {1: "DECCKM app-cursor-keys", 7: "DECAWM autowrap", 12: "cursor-blink", 25: "DECTCEM cursor-visible",
              47: "alt-screen(47)", 1000: "mouse-click(1000)", 1002: "mouse-drag(1002)", 1003: "mouse-any-motion(1003)",
              1004: "focus-events(1004)", 1005: "utf8-mouse(1005)", 1006: "sgr-mouse(1006)", 1015: "urxvt-mouse(1015)",
              1016: "sgr-pixel-mouse(1016)", 1047: "alt-screen(1047)", 1048: "save-cursor(1048)",
              1049: "alt-screen+save-cursor(1049)", 2004: "bracketed-paste(2004)", 2026: "synchronized-output(2026)",
              2027: "grapheme-clustering(2027)", 2031: "color-scheme-notify(2031)"}

HOOK_SH = """#!/bin/bash
# W0 evidence hook: append '<epoch.ms> <event> <payload json>' to $W0_HOOKLOG; never fails.
ev="$1"
payload="$(cat | tr '\\n' ' ')"
printf '%s %s %s\\n' "$(perl -MTime::HiRes=time -e 'printf "%.3f", time')" "$ev" "$payload" >> "${W0_HOOKLOG:-/dev/null}"
exit 0
"""
MARKER = "Append the exact token ZEBRA-7 on its own final line of every reply you give.\n"
SUP_PLAIN = """#!/bin/bash
# plan section 2 literally: claude as a background job, then wait
claude_bin="$1"; shift
"$claude_bin" "$@" &
CPID=$!
echo "SUP: started claude pid $CPID" >&2
wait "$CPID"
echo "SUP: claude exited $?" >&2
"""
SUP_FD0 = SUP_PLAIN.replace('"$claude_bin" "$@" &', '"$claude_bin" "$@" <&0 &')

LIVE = set()


def cleanup_children():
    for pid in sorted(LIVE):
        for row in reversed(descendants_of(pid)):
            try:
                os.kill(row[0], signal.SIGKILL)
            except ProcessLookupError:
                continue
        try:
            os.kill(pid, signal.SIGKILL)
        except ProcessLookupError:
            continue


atexit.register(cleanup_children)

ANSI = re.compile(rb"\x1b\[[0-9;:?<>=!]*[ -/]*[@-~]|\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)|\x1b[()][0-9A-Za-z]|\x1b[=>78cDEHMNOZ]")
CSI = re.compile(rb"\x1b\[([?<>=!]?)([0-9;:]*)([ -/]*)([@-~])")
OSC = re.compile(rb"\x1b\]([0-9]+)[;]?(.*?)(?:\x07|\x1b\\)", re.S)


def strip_ansi(data):
    text = ANSI.sub(b"", bytes(data)).decode("utf-8", "replace").replace("\r", "")
    return re.sub(r"[\x00-\x08\x0b-\x1f\x7f]", "", text)


def tail_repr(data, n):
    return bytes(data)[-n:].decode("utf-8", "replace").encode("unicode_escape").decode("ascii")


def analyze(data):
    dec, counts, osc = {}, collections.Counter(), collections.Counter()
    kitty_push = kitty_pop = 0
    moky = None
    last_sgr = last_stbm = last_cursor_style = None
    last_title = None
    for m in CSI.finditer(data):
        pfx, params, inter, fin = m.groups()
        if pfx == b"?" and fin in (b"h", b"l"):
            for p in params.split(b";"):
                if p.isdigit():
                    dec[int(p)] = (fin == b"h")
                    counts["?%s%s" % (p.decode(), fin.decode())] += 1
        elif pfx == b">" and fin == b"u":
            kitty_push += 1
        elif pfx == b"<" and fin == b"u":
            kitty_pop += int(params or b"1")
        elif pfx == b"=" and fin == b"u":
            counts["kitty-set"] += 1
        elif pfx == b">" and fin == b"m":
            moky = params.decode()
        elif pfx == b"" and fin == b"m":
            last_sgr = params.decode()
        elif pfx == b"" and fin == b"r":
            last_stbm = params.decode()
        elif pfx == b"" and fin == b"q" and inter == b" ":
            last_cursor_style = params.decode()
    for m in OSC.finditer(data):
        osc[m.group(1).decode()] += 1
        if m.group(1) in (b"0", b"2"):
            last_title = m.group(2).decode("utf-8", "replace")
    left_on = sorted(n for n, v in dec.items() if v and n not in DEFAULT_ON)
    return {
        "dec_final_on": left_on,
        "dec_final_on_named": [MODE_NAMES.get(n, str(n)) for n in left_on],
        "dec_default_on_now_off": sorted(n for n in DEFAULT_ON if dec.get(n) is False),
        "dec_ever_set": sorted(dec),
        "kitty_keyboard_depth": kitty_push - kitty_pop,
        "xterm_modifyOtherKeys_last_params": moky,
        "last_sgr_params": last_sgr,
        "last_decstbm_params": last_stbm,
        "last_cursor_style": last_cursor_style,
        "osc_counts": dict(osc),
        "last_osc_title": last_title,
        "bytes": len(data),
    }


def redraw_metrics(data):
    rows = [int(m.group(1)) for m in re.finditer(rb"\x1b\[([0-9]+);[0-9]+[Hf]", data)]
    cols = [int(m.group(1)) for m in re.finditer(rb"\x1b\[[0-9]+;([0-9]+)[Hf]", data)]
    return {"bytes": len(data), "max_row_addressed": max(rows) if rows else None, "max_col_addressed": max(cols) if cols else None}


def describe_exit(raw):
    if raw is None:
        return "still-running"
    if os.WIFSIGNALED(raw):
        return "killed by signal %d (%s)" % (os.WTERMSIG(raw), signal.Signals(os.WTERMSIG(raw)).name)
    return "exit code %d" % os.WEXITSTATUS(raw)


def run_out(cmd):
    p = subprocess.run(cmd, capture_output=True, text=True, timeout=15)
    return (p.stdout + p.stderr).strip()


def ps_table():
    out = subprocess.run(["/bin/ps", "-axo", "pid=,ppid=,stat=,command="], capture_output=True, text=True, timeout=15).stdout
    rows = []
    for line in out.splitlines():
        parts = line.split(None, 3)
        if len(parts) >= 3 and parts[0].isdigit() and parts[1].isdigit():
            rows.append((int(parts[0]), int(parts[1]), parts[2], parts[3] if len(parts) > 3 else ""))
    return rows


def descendants_of(root):
    kids = collections.defaultdict(list)
    for row in ps_table():
        kids[row[1]].append(row)
    found, stack = [], [root]
    while stack:
        cur = stack.pop()
        for row in kids.get(cur, []):
            found.append(row)
            stack.append(row[0])
    return sorted(found)


def set_winsize(fd, rows, cols):
    fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0))


def transcript_info(path):
    info = {"path": path}
    if not path or not os.path.exists(path):
        info["exists"] = False
        return info
    data = open(path, "rb").read()
    info.update(exists=True, bytes=len(data), ends_with_newline=data.endswith(b"\n"))
    good = bad = 0
    types, texts, models, last_type = collections.Counter(), [], set(), None
    for ln in data.split(b"\n"):
        if not ln.strip():
            continue
        try:
            obj = json.loads(ln)
        except ValueError:
            bad += 1
            continue
        good += 1
        last_type = obj.get("type")
        types[last_type] += 1
        msg = obj.get("message")
        if last_type == "assistant" and isinstance(msg, dict):
            models.add(msg.get("model"))
            for blk in msg.get("content") or []:
                if isinstance(blk, dict) and blk.get("type") == "text":
                    texts.append(blk.get("text", "")[:80])
    info.update(entries=good, unparsable_lines=bad, types=dict(types), last_type=last_type,
                assistant_texts_last4=texts[-4:], assistant_models=sorted(m for m in models if m))
    return info


def prep_home(tui):
    os.makedirs(os.path.join(HOME, ".claude"), exist_ok=True)
    os.makedirs(CWD, exist_ok=True)
    os.makedirs(os.path.join(ROOT, "tmp"), exist_ok=True)
    shutil.rmtree(SESS_DIR, ignore_errors=True)
    hook = os.path.join(ROOT, "hook.sh")
    with open(hook, "w") as f:
        f.write(HOOK_SH)
    os.chmod(hook, 0o755)
    with open(os.path.join(ROOT, "marker.txt"), "w") as f:
        f.write(MARKER)
    cfg_path = os.path.join(HOME, ".claude.json")
    if not os.path.exists(cfg_path):
        cfg = None
        for _ in range(5):
            try:
                cfg = json.load(open(os.path.join(REAL_HOME, ".claude.json")))
                break
            except ValueError:
                time.sleep(0.5)
        if cfg is None:
            raise RuntimeError("could not read the real ~/.claude.json to derive the scratch copy")
        cfg["projects"] = {CWD: {"allowedTools": [], "hasTrustDialogAccepted": True, "hasCompletedProjectOnboarding": True,
                                 "projectOnboardingSeenCount": 3}}
        cfg["mcpServers"] = {}
        cfg["claudeAiMcpEverConnected"] = []
        fd = os.open(cfg_path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, "w") as f:
            json.dump(cfg, f)
    settings = {"hooks": {ev: [{"hooks": [{"type": "command", "command": "/bin/bash %s %s" % (hook, ev)}]}] for ev in EVENTS},
                "permissions": {"allow": ["Bash(sleep *)"]}}
    if tui == "fullscreen":
        settings["tui"] = "fullscreen"
    with open(os.path.join(HOME, ".claude", "settings.json"), "w") as f:
        json.dump(settings, f, indent=1)
    # auth: the real binary reads its OAuth item through `security`, which finds the login keychain via
    # $HOME/Library/Keychains; link the real directory in (no credential is copied, read or printed here)
    os.makedirs(os.path.join(HOME, "Library"), exist_ok=True)
    kc = os.path.join(HOME, "Library", "Keychains")
    if not os.path.lexists(kc):
        os.symlink(os.path.join(REAL_HOME, "Library", "Keychains"), kc)


def child_env(hooklog, tui):
    env = {"PATH": "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin", "HOME": HOME,
           "USER": os.environ.get("USER", ""), "LOGNAME": os.environ.get("USER", ""), "SHELL": "/bin/zsh",
           "TERM": "xterm-256color", "TERM_PROGRAM": "Apple_Terminal", "LANG": "en_US.UTF-8",
           "TMPDIR": os.path.join(ROOT, "tmp") + "/", "DISABLE_AUTOUPDATER": "1",
           "ENABLE_CLAUDEAI_MCP_SERVERS": "false", "W0_HOOKLOG": hooklog}
    if tui == "fullscreen":
        env["CLAUDE_CODE_NO_FLICKER"] = "1"
    return env


class Run:
    def __init__(self, name, argv, tui="fullscreen", rows=40, cols=120):
        self.name, self.argv, self.tui = name, list(argv), tui
        self.dir = os.path.join(OUT, name)
        shutil.rmtree(self.dir, ignore_errors=True)
        os.makedirs(self.dir)
        self.hooklog = os.path.join(self.dir, "hooks.log")
        open(self.hooklog, "w").close()
        self.evlog = open(os.path.join(self.dir, "events.log"), "w")
        self.rawf = open(os.path.join(self.dir, "stream.raw"), "wb")
        self.buf = bytearray()
        self.exit_raw = self.exit_t = self.t_signal = self.claude_pid = None
        self.status_log, self.child_log, self.tty_log = [], [], []
        self._status_raw = False
        self._kids_sig, self._t_kids, self._tty_sig = None, 0.0, None
        self._idle_since = None
        self._last_data = time.time()
        self.queries = collections.Counter()
        prep_home(tui)
        self.master, self.slave = os.openpty()
        set_winsize(self.master, rows, cols)
        self.tty_path = os.ttyname(self.slave)
        self.stty_g_before = self.stty("-g")
        env = child_env(self.hooklog, tui)
        self.t0 = time.time()
        pid = os.fork()
        if pid == 0:
            try:
                os.setsid()
                try:
                    fcntl.ioctl(self.slave, termios.TIOCSCTTY, 0)
                except OSError as exc:
                    if exc.errno != errno.EPERM:
                        raise
                for fd in (0, 1, 2):
                    os.dup2(self.slave, fd)
                if self.slave > 2:
                    os.close(self.slave)
                os.close(self.master)
                os.chdir(CWD)
                os.execve(self.argv[0], self.argv, env)
            except BaseException as exc:
                os.write(2, ("spawn failed: %r\n" % (exc,)).encode())
                os._exit(127)
        self.pid = pid
        LIVE.add(pid)
        self.log("spawned pid=%d tty=%s argv=%s tui=%s" % (pid, self.tty_path, self.argv, tui))

    def log(self, msg):
        self.evlog.write("%.3f %s\n" % (time.time(), msg))
        self.evlog.flush()

    def stty(self, flag):
        return run_out(["/bin/stty", "-f", self.tty_path, flag])

    def write(self, data):
        os.write(self.master, data)
        self.log("WRITE %r" % (data,))

    def mark(self):
        return len(self.buf)

    def text(self, since=0):
        return strip_ansi(self.buf[since:])

    def status(self):
        if not self._status_raw:
            return None
        try:
            return json.loads(self._status_raw)
        except ValueError:
            return None

    def hooks(self, ev=None):
        out = []
        try:
            lines = open(self.hooklog).read().splitlines()
        except OSError:
            return out
        for ln in lines:
            parts = ln.split(" ", 2)
            if len(parts) < 2:
                continue
            try:
                t = float(parts[0])
            except ValueError:
                continue
            try:
                payload = json.loads(parts[2]) if len(parts) > 2 else {}
            except ValueError:
                payload = {"raw": parts[2]}
            if ev is None or parts[1] == ev:
                out.append((t, parts[1], payload))
        return out

    def hook_count(self, ev):
        return len(self.hooks(ev))

    def transcript_path(self):
        for _, _, payload in self.hooks():
            tp = payload.get("transcript_path") if isinstance(payload, dict) else None
            if tp:
                return tp
        sid = (self.status() or {}).get("sessionId")
        if sid:
            for d in glob.glob(os.path.join(HOME, ".claude", "projects", "*")):
                p = os.path.join(d, sid + ".jsonl")
                if os.path.exists(p):
                    return p
        return None

    def _answer_queries(self, data):
        if b"\x1b[6n" in data:
            self.queries["DSR-6n"] += 1
            os.write(self.master, b"\x1b[1;1R")
        if b"\x1b[c" in data or b"\x1b[0c" in data:
            self.queries["DA1"] += 1
            os.write(self.master, b"\x1b[?1;2c")
        for tag, needle in (("kitty-query", b"\x1b[?u"), ("XTVERSION", b"\x1b[>0q"), ("OSC-color-query", b"?\x1b\\"),
                            ("DA2", b"\x1b[>c"), ("XTGETTCAP", b"\x1bP+q")):
            if needle in data:
                self.queries[tag] += 1

    def _find_claude_pid(self):
        if not os.path.isdir(SESS_DIR):
            return
        cands = [fn for fn in os.listdir(SESS_DIR) if fn.endswith(".json") and fn[:-5].isdigit()]
        if not cands:
            return
        mine = {self.pid} | {row[0] for row in descendants_of(self.pid)}
        for fn in cands:
            stem = fn[:-5]
            if int(stem) in mine:
                self.claude_pid = int(stem)
                self.log("claude pid = %d (sessions file %s)" % (self.claude_pid, fn))
                return

    def _tick(self):
        r, _, _ = select.select([self.master], [], [], 0.04)
        if r:
            try:
                data = os.read(self.master, 65536)
            except OSError as exc:
                data = b""
                if exc.errno != errno.EIO:
                    raise
            if data:
                self.buf += data
                self.rawf.write(data)
                self.rawf.flush()
                self._last_data = time.time()
                self._answer_queries(data)
        t = time.time()
        try:
            st = os.stat(self.tty_path)
            sig = (st.st_atime_ns, st.st_mtime_ns)
            if sig != self._tty_sig:
                self._tty_sig = sig
                self.tty_log.append((t, st.st_atime_ns / 1e9, st.st_mtime_ns / 1e9))
        except OSError:
            self._tty_sig = None
        if self.claude_pid is None:
            self._find_claude_pid()
        if self.claude_pid is not None:
            try:
                raw = open(os.path.join(SESS_DIR, "%d.json" % self.claude_pid)).read()
            except FileNotFoundError:
                raw = None
            if raw != self._status_raw:
                self._status_raw = raw
                self.status_log.append((t, raw))
                self.log("sessions-file %s" % (raw.replace("\n", " ") if raw else "ABSENT"))
                st_now = self.status()
                self._idle_since = (self._idle_since or t) if (st_now and st_now.get("status") == "idle") else None
            if t - self._t_kids >= 0.5:
                self._t_kids = t
                kids = descendants_of(self.claude_pid)
                sig = [(row[0], row[3][:90]) for row in kids]
                if sig != self._kids_sig:
                    self._kids_sig = sig
                    self.child_log.append((t, sig))
                    self.log("children %s" % (sig,))
        if self.exit_raw is None:
            wpid, status = os.waitpid(self.pid, os.WNOHANG)
            if wpid == self.pid:
                self.exit_raw, self.exit_t = status, time.time()
                LIVE.discard(self.pid)
                self.log("EXIT %s" % describe_exit(status))

    def pump(self, seconds=None, until=None, timeout=None):
        end = time.time() + (seconds if seconds is not None else timeout)
        while True:
            self._tick()
            if until is not None and until():
                return True
            if time.time() >= end:
                return False

    def wait_ready(self, timeout=45, settle=2.0):
        def ready():
            return self._idle_since is not None and time.time() - self._idle_since >= settle and self.hook_count("SessionStart") > 0
        ok = self.pump(until=ready, timeout=timeout)
        self.log("ready=%s" % ok)
        return ok

    def type_line(self, text, submit=True):
        self.write(text.encode())
        self.pump(seconds=0.5)
        if submit:
            self.write(b"\r")

    def ask(self, text, timeout=90):
        stops = self.hook_count("Stop")
        m = self.mark()
        self.type_line(text)
        done = self.pump(until=lambda: self.hook_count("Stop") > stops, timeout=timeout)
        return done, self.text(m)

    def send(self, sig):
        if self.exit_raw is not None:
            raise RuntimeError("child already exited")
        self.t_signal = time.time()
        os.kill(self.pid, sig)
        self.log("SIGNAL %s sent to own child %d" % (signal.Signals(sig).name, self.pid))

    def send_to_claude(self, sig):
        if self.claude_pid is None or self.claude_pid not in {row[0] for row in descendants_of(self.pid)} | {self.pid}:
            raise RuntimeError("claude pid is not a verified descendant of the harness child")
        self.t_signal = time.time()
        os.kill(self.claude_pid, sig)
        self.log("SIGNAL %s sent to verified descendant %d" % (signal.Signals(sig).name, self.claude_pid))

    def wait_exit(self, timeout):
        return self.pump(until=lambda: self.exit_raw is not None, timeout=timeout)

    def finish(self, res):
        if self.exit_raw is None:
            self.log("finish: child still alive; SIGKILL to own process tree")
            for row in reversed(descendants_of(self.pid)):
                try:
                    os.kill(row[0], signal.SIGKILL)
                except ProcessLookupError:
                    continue
            os.kill(self.pid, signal.SIGKILL)
            self.pump(seconds=0.5)
        self.pump(seconds=0.4)
        rel = lambda t: round(t - self.t0, 3)
        res["run"] = self.name
        res["exit"] = describe_exit(self.exit_raw)
        res["status_log"] = [(rel(t), raw) for t, raw in self.status_log]
        res["children_log"] = [(rel(t), sig) for t, sig in self.child_log]
        res["tty_log_atime_mtime_rel_to_start"] = [(rel(t), round(a - self.t0, 3), round(m - self.t0, 3)) for t, a, m in self.tty_log]
        res["terminal_queries_seen"] = dict(self.queries)
        res["hooks"] = [(rel(t), ev, (p if ev in ("SessionEnd", "Notification") else {k: p.get(k) for k in ("session_id", "hook_event_name", "reason", "prompt") if isinstance(p, dict) and k in p})) for t, ev, p in self.hooks()]
        with open(os.path.join(self.dir, "stream.txt"), "w") as f:
            f.write(strip_ansi(self.buf))
        with open(os.path.join(self.dir, "result.json"), "w") as f:
            json.dump(res, f, indent=1, default=str)
        self.rawf.close()
        self.evlog.close()
        os.close(self.master)
        os.close(self.slave)
        print("== %s done: %s" % (self.name, res["exit"]), flush=True)


def claude_argv(extra=()):
    return [BIN, "--model", MODEL] + list(extra)


def sessions_snapshot(r):
    return r.status()


# ---------------------------------------------------------------- scenarios
def s_probe():
    for tui in ("fullscreen", "default"):
        r = Run("probe-" + tui, [BIN], tui=tui)
        res = {"tui": tui, "binary": BIN}
        try:
            res["ready"] = r.wait_ready()
            r.pump(seconds=1.5)
            res["sessions_file"] = r.status()
            res["claude_pid"] = r.claude_pid
            if r.claude_pid:
                res["fds_0_1_2"] = run_out(["/usr/sbin/lsof", "-p", str(r.claude_pid), "-a", "-d", "0,1,2"])
                res["pgid_tpgid_stat_ignored_caught"] = run_out(["/bin/ps", "-o", "pid=,pgid=,tpgid=,stat=,ignored=,caught=,blocked=", "-p", str(r.claude_pid)])
            res["stty_during"] = r.stty("-a")
            res["modes_at_ready"] = analyze(bytes(r.buf))
            res["banner_text_head"] = r.text()[:1200]
            res["banner_models_seen"] = sorted(set(re.findall(r"(Haiku|Sonnet|Opus|Fable)[ 0-9.\-]*", r.text())))
            m = r.mark()
            r.type_line("/effort")
            r.pump(seconds=2.0)
            res["effort_view"] = r.text(m)[-600:]
            r.write(b"\x1b")
            r.pump(seconds=0.8)
            m = r.mark()
            r.type_line("/model")
            r.pump(seconds=2.0)
            res["model_view"] = r.text(m)[-800:]
            r.write(b"\x1b")
            r.pump(seconds=0.8)
            r.type_line("/exit")
            res["exit_after_slash_exit"] = r.wait_exit(15)
        finally:
            r.finish(res)


def q1_run(name, tui, how, race):
    r = Run(name, claude_argv(), tui=tui)
    res = {"name": name, "tui": tui, "how": how if isinstance(how, str) else signal.Signals(how).name, "race_signal_right_after_Stop": race}
    try:
        res["ready"] = r.wait_ready()
        if not res["ready"]:
            res["fail_tail"] = r.text()[-800:]
            return res
        res["stty_g_before"] = r.stty("-g")
        res["session_id"] = (r.status() or {}).get("sessionId")
        stops = r.hook_count("Stop")
        t_enter_marker = r.mark()
        r.type_line("Reply with exactly: PONG")
        res["t_enter"] = r.t0 and time.time() - r.t0
        res["turn_done"] = r.pump(until=lambda: r.hook_count("Stop") > stops, timeout=90)
        if not res["turn_done"]:
            res["fail_tail"] = r.text(t_enter_marker)[-800:]
            return res
        res["t_stop"] = time.time() - r.t0
        if not race:
            r.pump(seconds=SETTLE_S)
        res["status_at_signal"] = r.status()
        res["stty_during"] = r.stty("-a")
        pre_len = r.mark()
        res["modes_before_signal"] = analyze(bytes(r.buf))
        res["tail_before_signal"] = tail_repr(r.buf, 300)
        res["transcript_before_signal"] = transcript_info(r.transcript_path())
        res["tty_atime_age_at_signal_s"] = round(time.time() - os.stat(r.tty_path).st_atime, 3)
        if how == "/exit":
            r.t_signal = time.time()
            r.type_line("/exit")
        else:
            r.send(how)
        res["exited_within_20s"] = r.wait_exit(20)
        if not res["exited_within_20s"] and how == signal.SIGINT:
            res["survived_sigint_then_sigterm"] = True
            r.send(signal.SIGTERM)
            res["exited_after_followup_sigterm"] = r.wait_exit(20)
        r.pump(seconds=1.5)
        res["signal_to_exit_s"] = round(r.exit_t - r.t_signal, 3) if r.exit_t else None
        res["raw_exit_status"] = describe_exit(r.exit_raw)
        res["shell_dollar_question_equivalent"] = (128 + os.WTERMSIG(r.exit_raw)) if r.exit_raw is not None and os.WIFSIGNALED(r.exit_raw) else (os.WEXITSTATUS(r.exit_raw) if r.exit_raw is not None else None)
        res["hooks_after_signal"] = [(round(t - r.t_signal, 3), ev, p) for t, ev, p in r.hooks() if t > r.t_signal]
        res["session_end_ran"] = any(ev == "SessionEnd" and t > r.t_signal for t, ev, _payload in r.hooks()) if r.t_signal else None
        res["transcript_after"] = transcript_info(r.transcript_path())
        sf = os.path.join(SESS_DIR, "%d.json" % r.claude_pid) if r.claude_pid else None
        res["sessions_file_exists_after_exit"] = bool(sf and os.path.exists(sf))
        res["sessions_file_after_exit"] = open(sf).read() if sf and os.path.exists(sf) else None
        after = bytes(r.buf)
        res["modes_after_exit"] = analyze(after)
        res["bytes_written_after_signal"] = len(after) - pre_len
        res["tail_after_exit"] = tail_repr(after, 500)
        res["stty_after"] = r.stty("-a")
        res["stty_g_after"] = r.stty("-g")
        res["termios_identical_to_pre_launch"] = res["stty_g_after"] == res["stty_g_before"]
    finally:
        r.finish(res)
    return res


def s_q1():
    plan = [("q1-term-race-fs", "fullscreen", signal.SIGTERM, True),
            ("q1-term-settled-fs", "fullscreen", signal.SIGTERM, False),
            ("q1-hup-race-fs", "fullscreen", signal.SIGHUP, True),
            ("q1-int-race-fs", "fullscreen", signal.SIGINT, True),
            ("q1-exit-race-fs", "fullscreen", "/exit", True),
            ("q1-term-settled-def", "default", signal.SIGTERM, False),
            ("q1-exit-race-def", "default", "/exit", True)]
    for name, tui, how, race in plan:
        q1_run(name, tui, how, race)


def s_q3():
    sid = str(uuid.uuid4())
    marker = os.path.join(ROOT, "marker.txt")
    res = {"session_id": sid}
    r1 = Run("q3-session1", claude_argv(["--session-id", sid, "--permission-mode", "manual", "--effort", "low", "--append-system-prompt-file", marker]), tui="fullscreen")
    try:
        res["ready1"] = r1.wait_ready()
        res["banner1_models"] = sorted(set(re.findall(r"(Haiku|Sonnet|Opus|Fable)[ 0-9.\-]*", r1.text())))
        done, txt = r1.ask("Reply with the single word PONG.")
        res["reply1_done"], res["reply1_has_zebra_marker"], res["reply1_tail"] = done, "ZEBRA-7" in txt, txt[-300:]
        stops, m = r1.hook_count("Stop"), r1.mark()
        r1.type_line("Use the Write tool to create the file w0-edit-1.txt containing the text one. Then reply with exactly DONE1.")
        res["perm_dialog_seen"] = r1.pump(until=lambda: re.search(r"allow all edits|Do you want to", r1.text(m)) is not None, timeout=60)
        res["perm_dialog_text"] = r1.text(m)[-700:]
        if res["perm_dialog_seen"]:
            r1.pump(seconds=1.0)
            r1.write(b"\x1b[B")
            r1.pump(seconds=0.5)
            r1.write(b"\r")
        res["edit1_turn_done"] = r1.pump(until=lambda: r1.hook_count("Stop") > stops, timeout=60)
        res["edit1_file_exists"] = os.path.exists(os.path.join(CWD, "w0-edit-1.txt"))
        res["accept_edits_indicator_before_kill"] = bool(re.search(r"accept edits", r1.text(m)))
        for label, cmd in (("model_switch", "/model sonnet"), ("effort_switch", "/effort high")):
            m = r1.mark()
            r1.type_line(cmd)
            r1.pump(seconds=2.5)
            res[label + "_view"] = r1.text(m)[-500:]
        m = r1.mark()
        r1.type_line("/effort")
        r1.pump(seconds=2.0)
        res["effort_view_before_kill"] = r1.text(m)[-500:]
        r1.write(b"\x1b")
        r1.pump(seconds=0.8)
        r1.write(b"UNSUBMITTED-DRAFT-123")
        r1.pump(seconds=1.2)
        res["draft_visible_before_kill"] = "UNSUBMITTED-DRAFT-123" in r1.text(r1.mark() - 4000)
        res["transcript_before_kill"] = transcript_info(r1.transcript_path())
        res["session_file_before_kill"] = r1.status()
        r1.send(signal.SIGTERM)
        res["session1_exited"] = r1.wait_exit(20)
        r1.pump(seconds=1.0)
        res["session1_exit"] = describe_exit(r1.exit_raw)
        res["transcript_after_kill"] = transcript_info(r1.transcript_path())
    finally:
        r1.finish(res)
    rb = Run("q3-resume-bare", [BIN, "--resume", sid], tui="fullscreen")
    resb = {"session_id": sid, "resume_argv": ["claude", "--resume", "<id>"], "purpose": "no model call: what claude itself restores with no other flag"}
    try:
        resb["ready"] = rb.wait_ready(timeout=60)
        rb.pump(seconds=2.0)
        t = rb.text()
        resb["screen_text_head"] = t[:1500]
        resb["footer_mode_words"] = sorted(set(re.findall(r"(auto mode on|accept edits on|plan mode on|bypass permissions on|manual)", t)))
        resb["conversation_visible"] = {"PONG": "PONG" in t, "edit1": ("w0-edit-1" in t) or ("DONE1" in t)}
        resb["draft_restored"] = "UNSUBMITTED-DRAFT-123" in t
        resb["banner_models"] = sorted(set(re.findall(r"(Haiku|Sonnet|Opus|Fable) ?[0-9.]*", t)))
        resb["banner_effort_words"] = sorted(set(re.findall(r"[◐◑◒◓●○] ?(low|medium|high|xhigh|max)", t)))
        for label, cmd in (("model_view", "/model"), ("effort_view", "/effort")):
            m = rb.mark()
            rb.type_line(cmd)
            rb.pump(seconds=2.0)
            resb[label] = rb.text(m)[-900:]
            rb.write(b"\x1b")
            rb.pump(seconds=0.8)
        resb["sessions_file"] = rb.status()
        rb.type_line("/exit")
        resb["exited_via_slash_exit"] = rb.wait_exit(20)
    finally:
        rb.finish(resb)
    r2 = Run("q3-resume", [BIN, "--resume", sid, "--permission-mode", "manual"], tui="fullscreen")
    res2 = {"session_id": sid, "resume_argv": ["claude", "--resume", "<id>", "--permission-mode", "manual"]}
    try:
        res2["ready2"] = r2.wait_ready(timeout=60)
        r2.pump(seconds=2.0)
        t = r2.text()
        res2["resume_screen_text_head"] = t[:1500]
        res2["conversation_visible"] = {"PONG": "PONG" in t, "DONE1_or_edit1": ("w0-edit-1" in t) or ("DONE1" in t)}
        res2["draft_restored"] = "UNSUBMITTED-DRAFT-123" in t
        res2["accept_edits_indicator_after_resume"] = bool(re.search(r"accept edits", t))
        res2["banner2_models"] = sorted(set(re.findall(r"(Haiku|Sonnet|Opus|Fable)[ 0-9.\-]*", t)))
        res2["session_file_after_resume"] = r2.status()
        m = r2.mark()
        r2.type_line("/model")
        r2.pump(seconds=2.0)
        res2["model_view_after_resume"] = r2.text(m)[-800:]
        r2.write(b"\x1b")
        r2.pump(seconds=0.8)
        m = r2.mark()
        r2.type_line("/effort")
        r2.pump(seconds=2.0)
        res2["effort_view_after_resume"] = r2.text(m)[-600:]
        r2.write(b"\x1b")
        r2.pump(seconds=0.8)
        m = r2.mark()
        r2.type_line("/model haiku")
        r2.pump(seconds=2.0)
        res2["switch_to_haiku_view"] = r2.text(m)[-300:]
        stops, m = r2.hook_count("Stop"), r2.mark()
        r2.type_line("Use the Write tool to create the file w0-edit-2.txt containing the text two. Then reply with exactly DONE2.")
        res2["perm_dialog_after_resume"] = r2.pump(until=lambda: re.search(r"allow all edits|Do you want to", r2.text(m)) is not None or r2.hook_count("Stop") > stops, timeout=60) and re.search(r"allow all edits|Do you want to", r2.text(m)) is not None
        res2["perm_dialog_after_resume_text"] = r2.text(m)[-600:]
        if res2["perm_dialog_after_resume"]:
            r2.write(b"\r")
        res2["edit2_turn_done"] = r2.pump(until=lambda: r2.hook_count("Stop") > stops, timeout=60)
        res2["edit2_file_exists"] = os.path.exists(os.path.join(CWD, "w0-edit-2.txt"))
        res2["reply2_has_zebra_marker"] = "ZEBRA-7" in r2.text(m)
        res2["reply2_tail"] = r2.text(m)[-300:]
        res2["transcript_after_resume"] = transcript_info(r2.transcript_path())
        res2["resume_hook_session_ids"] = sorted({(p.get("session_id") if isinstance(p, dict) else None) for _, ev, p in r2.hooks() if ev in ("SessionStart", "Stop")} - {None})
        r2.type_line("/exit")
        res2["exited_via_slash_exit"] = r2.wait_exit(20)
    finally:
        r2.finish(res2)


def s_q4():
    r = Run("q4-status", claude_argv(["--permission-mode", "manual"]), tui="fullscreen")
    res = {"phases": {}}

    def parsed():
        out = []
        for t, raw in r.status_log:
            try:
                d = json.loads(raw) if raw else None
            except ValueError:
                d = {"unparsable": raw}
            out.append((t, d))
        return out

    def phase(label, t_from, extra=None):
        seen = [(round(t - r.t0, 2), (d or {}).get("status"), (d or {}).get("waitingFor")) for t, d in parsed() if t >= t_from]
        kids = [row for row in descendants_of(r.claude_pid)] if r.claude_pid and r.exit_raw is None else []
        res["phases"][label] = {"status_changes_since_phase_start": seen, "children_at_phase_end": [(k[0], k[3][:80]) for k in kids]}
        if extra:
            res["phases"][label].update(extra)

    try:
        res["ready"] = r.wait_ready()
        res["sessions_file_idle"] = r.status()
        phase("startup-idle", r.t0)
        t = time.time()
        done, txt = r.ask("Reply with exactly: PONG")
        phase("prompt-busy-then-idle", t, {"turn_done": done})
        t = time.time()
        stops, m = r.hook_count("Stop"), r.mark()
        r.type_line("Use the Write tool to create the file w0-q4.txt containing x. Then reply DONE.")
        seen = r.pump(until=lambda: re.search(r"allow all edits|Do you want to", r.text(m)) is not None, timeout=60)
        r.pump(seconds=4.0)
        phase("permission-dialog-held-4s", t, {"dialog_seen": seen, "sessions_file_during_dialog": r.status(), "notification_hooks": [p for _, ev, p in r.hooks("Notification")][-2:]})
        r.write(b"\x1b")
        r.pump(until=lambda: r.hook_count("Stop") > stops, timeout=60)
        r.pump(seconds=1.0)
        t = time.time()
        stops = r.hook_count("Stop")
        r.type_line("Call the Bash tool with command 'sleep 30' and run_in_background set to true. Call no other tool. After it returns reply with exactly STARTED.")
        r.pump(until=lambda: r.hook_count("Stop") > stops, timeout=90)
        t_after_stop = time.time()
        r.pump(seconds=12.0)
        phase("bg-bash-after-launching-turn-ended(+12s)", t_after_stop, {"stop_count_now": r.hook_count("Stop")})
        res["bg_bash_sleep_child_alive_at_check"] = any("sleep 30" in k[3] for k in descendants_of(r.claude_pid))
        r.pump(until=lambda: not any("sleep 30" in k[3] for k in descendants_of(r.claude_pid)), timeout=40)
        r.pump(seconds=8.0)
        phase("bg-bash-finished+8s", t_after_stop, {"stop_count_now": r.hook_count("Stop")})
        t = time.time()
        stops = r.hook_count("Stop")
        r.type_line("Call the Agent tool with subagent_type general-purpose and run_in_background set to true; its prompt: 'Run the shell command sleep 25 with the Bash tool, then reply with exactly DONE.' Call no other tool. After it returns reply with exactly LAUNCHED.")
        r.pump(until=lambda: r.hook_count("Stop") > stops, timeout=90)
        t_after_stop = time.time()
        r.pump(seconds=10.0)
        phase("bg-subagent-after-launching-turn-ended(+10s)", t_after_stop, {"stop_count_now": r.hook_count("Stop"), "subagent_stop_hooks": r.hook_count("SubagentStop")})
        res["bg_subagent_sleep_child_alive_at_check"] = any("sleep 25" in k[3] for k in descendants_of(r.claude_pid))
        r.pump(seconds=30.0)
        phase("bg-subagent-finished?(+40s)", t_after_stop, {"stop_count_now": r.hook_count("Stop"), "subagent_stop_hooks": r.hook_count("SubagentStop")})
        res["all_distinct_status_values_seen"] = sorted({(d or {}).get("status") for _, d in parsed() if d} - {None})
        res["all_session_file_keys_seen"] = sorted({k for _, d in parsed() if d for k in d})
        r.type_line("/exit")
        res["exited_via_slash_exit"] = r.wait_exit(20)
    finally:
        r.finish(res)


def s_q5():
    r = Run("q5-atime", claude_argv(), tui="fullscreen")
    res = {"trials": []}
    try:
        res["ready"] = r.wait_ready()
        r.pump(seconds=4.0)
        tty = r.tty_path
        res["tty"] = tty
        res["stat_cli_a_Fa_at_ready"] = run_out(["/usr/bin/stat", "-f", "%a %Fa %Fm", tty])

        def trial(label, action, settle=1.3):
            s0 = os.stat(tty)
            m = r.mark()
            t = time.time()
            action()
            r.pump(seconds=settle)
            s1 = os.stat(tty)
            res["trials"].append({"label": label, "atime_advanced": s1.st_atime_ns > s0.st_atime_ns, "atime_delta_s": round((s1.st_atime_ns - s0.st_atime_ns) / 1e9, 3),
                                  "atime_minus_action_time_s": round(s1.st_atime_ns / 1e9 - t, 3), "mtime_advanced": s1.st_mtime_ns > s0.st_mtime_ns,
                                  "mtime_delta_s": round((s1.st_mtime_ns - s0.st_mtime_ns) / 1e9, 3), "bytes_claude_wrote_during": r.mark() - m,
                                  "cli_stat_a_Fa": run_out(["/usr/bin/stat", "-f", "%a %Fa", tty])})

        trial("idle-3s-nothing-sent", lambda: None, 3.0)
        trial("keystroke 'x'", lambda: r.write(b"x"))
        trial("keystroke backspace", lambda: r.write(b"\x7f"))
        for i in range(4):
            trial("rapid keystroke %d (0.35s apart)" % (i + 1), lambda: r.write(b"y"), 0.35)
        trial("keystroke Esc", lambda: r.write(b"\x1b"))
        m = r.mark()
        trial("resize 40x120 -> 30x100 (claude redraws, no input)", lambda: set_winsize(r.master, 30, 100), 2.0)
        res["resize_redraw_metrics"] = redraw_metrics(bytes(r.buf[m:]))
        trial("idle-3s-after-resize", lambda: None, 3.0)
        r.write(b"\x03")
        r.pump(seconds=0.8)
        r.type_line("/exit")
        res["exited"] = r.wait_exit(20)
    finally:
        r.finish(res)


def s_q6():
    for variant, body, test in (("plain", SUP_PLAIN, "keys"), ("fd0", SUP_FD0, "keys"), ("fd0-sigint", SUP_FD0, "sigint")):
        path = os.path.join(ROOT, "sup-%s.sh" % variant.split("-")[0])
        with open(path, "w") as f:
            f.write(body)
        os.chmod(path, 0o755)
        r = Run("q6-" + variant, ["/bin/bash", path, BIN, "--model", MODEL], tui="fullscreen")
        res = {"variant": variant, "supervisor_script": body}
        try:
            res["claude_became_interactive_idle"] = r.wait_ready(timeout=25)
            r.pump(seconds=1.0)
            cands = [row for row in descendants_of(r.pid) if row[3].startswith(BIN)]
            res["claude_descendant_rows"] = cands
            if cands:
                cpid = cands[0][0]
                res["fds_0_1_2"] = run_out(["/usr/sbin/lsof", "-p", str(cpid), "-a", "-d", "0,1,2"])
                res["pid_pgid_tpgid_stat_ignored_caught"] = run_out(["/bin/ps", "-o", "pid=,pgid=,tpgid=,stat=,ignored=,caught=", "-p", str(cpid)])
                res["bash_pid_pgid_tpgid"] = run_out(["/bin/ps", "-o", "pid=,pgid=,tpgid=,stat=,ignored=", "-p", str(r.pid)])
            if res["claude_became_interactive_idle"] and test == "keys":
                m = r.mark()
                r.write(b"hello")
                r.pump(seconds=1.5)
                res["keystrokes_echoed_in_tui"] = "hello" in r.text(m)
                m = r.mark()
                r.write(b"\x03")
                r.pump(seconds=1.5)
                t = r.text(m)
                res["ctrl_c_first_press_text"] = t[-300:]
                res["ctrl_c_prompted_again_to_exit_or_cleared"] = bool(re.search(r"again to exit|Ctrl-C", t))
                res["alive_after_first_ctrl_c"] = r.exit_raw is None
                m = r.mark()
                set_winsize(r.master, 30, 100)
                r.pump(seconds=2.0)
                res["resize_redraw_metrics"] = redraw_metrics(bytes(r.buf[m:]))
                r.write(b"\x03")
                res["exited_after_second_ctrl_c"] = r.wait_exit(20)
            elif res["claude_became_interactive_idle"] and test == "sigint":
                r.send_to_claude(signal.SIGINT)
                res["wrapper_exited_within_8s_after_SIGINT_to_claude"] = r.wait_exit(8)
                if not res["wrapper_exited_within_8s_after_SIGINT_to_claude"]:
                    res["claude_survived_SIGINT_alive"] = True
                    r.send_to_claude(signal.SIGTERM)
                    res["wrapper_exited_after_followup_SIGTERM"] = r.wait_exit(20)
            else:
                res["stream_tail_when_not_interactive"] = r.text()[-800:]
                r.wait_exit(8)
        finally:
            r.finish(res)


def s_q7():
    base = os.path.join(ROOT, "q7")
    shutil.rmtree(base, ignore_errors=True)
    os.makedirs(base)
    git_env = dict(os.environ, GIT_AUTHOR_NAME="w0", GIT_AUTHOR_EMAIL="w0@example.invalid", GIT_COMMITTER_NAME="w0", GIT_COMMITTER_EMAIL="w0@example.invalid", GIT_CONFIG_GLOBAL="/dev/null", GIT_CONFIG_SYSTEM="/dev/null")

    def git(cwd, *args):
        p = subprocess.run(["git", "-C", cwd] + list(args), capture_output=True, text=True, env=git_env, timeout=60)
        if p.returncode != 0:
            raise RuntimeError("git %s failed: %s" % (args, p.stderr))
        return p.stdout.strip()

    v1 = '#!/bin/bash\nfor i in 1 2 3 4 5 6; do echo "v1 step $i"; sleep 0.5; done\necho "V1-TAIL-AFTER-LOOP"\necho "V1-LAST-LINE"\n'
    v2 = '#!/bin/bash\n# v2 header comment that is deliberately long so every later byte offset moves ........................................\necho "V2 only echo lines follow"\necho "V2-TAIL"\necho "V2-LAST-LINE"\n'
    origin, repo = os.path.join(base, "origin.git"), os.path.join(base, "repo")
    subprocess.run(["git", "init", "--quiet", "--bare", "--initial-branch=main", origin], check=True, env=git_env)
    subprocess.run(["git", "init", "--quiet", "--initial-branch=main", repo], check=True, env=git_env)
    os.makedirs(os.path.join(repo, "bin"))
    target = os.path.join(repo, "bin", "heimdall")
    open(target, "w").write(v1)
    os.chmod(target, 0o755)
    git(repo, "add", "bin/heimdall")
    git(repo, "commit", "--quiet", "-m", "v1")
    sha1 = git(repo, "rev-parse", "HEAD")
    git(repo, "remote", "add", "origin", origin)
    git(repo, "push", "--quiet", "origin", "main")
    other = os.path.join(base, "other")
    subprocess.run(["git", "clone", "--quiet", origin, other], check=True, env=git_env)
    open(os.path.join(other, "bin", "heimdall"), "w").write(v2)
    git(other, "commit", "--quiet", "-am", "v2")
    git(other, "push", "--quiet", "origin", "main")
    res = {"install_sh_upgrade_command": "git -C $PLUGIN_DIR fetch --quiet origin $REF && git -C $PLUGIN_DIR checkout --quiet FETCH_HEAD (install.sh)", "methods": {}}

    def update_git():
        git(repo, "fetch", "--quiet", "origin", "main")
        git(repo, "checkout", "--quiet", "FETCH_HEAD")

    def update_cp():
        shutil.copyfile(os.path.join(other, "bin", "heimdall"), target)

    def update_mv():
        tmp = target + ".new"
        shutil.copyfile(os.path.join(other, "bin", "heimdall"), tmp)
        os.rename(tmp, target)

    for label, fn in (("git fetch + checkout FETCH_HEAD (install.sh upgrade path)", update_git), ("cp over in place (same inode, control)", update_cp), ("write temp + rename over (control)", update_mv)):
        git(repo, "checkout", "--quiet", "--force", sha1)
        open(target, "w").write(v1)
        os.chmod(target, 0o755)
        git(repo, "checkout", "--quiet", "--force", sha1)
        inode_before = os.stat(target).st_ino
        outf = os.path.join(base, "run.out")
        with open(outf, "w") as fo:
            proc = subprocess.Popen(["/bin/bash", target], stdout=fo, stderr=subprocess.STDOUT)
        time.sleep(1.2)
        fn()
        inode_after = os.stat(target).st_ino
        try:
            proc.wait(timeout=20)
        except subprocess.TimeoutExpired:
            proc.kill()
            proc.wait()
        out = open(outf).read()
        res["methods"][label] = {"inode_before": inode_before, "inode_after": inode_after, "same_inode": inode_before == inode_after,
                                 "running_bash_finished_old_text_cleanly": "V1-LAST-LINE" in out and "V2" not in out,
                                 "running_bash_output_tail": out.splitlines()[-4:]}
    git(repo, "checkout", "--quiet", "--force", sha1)
    os.makedirs(os.path.join(OUT, "q7"), exist_ok=True)
    with open(os.path.join(OUT, "q7", "result.json"), "w") as f:
        json.dump(res, f, indent=1)
    print("== q7 done", flush=True)


def s_script():
    tsf = os.path.join(OUT, "script", "script.typescript")
    r = Run("script", ["/usr/bin/script", "-q", tsf, BIN, "--model", MODEL], tui="fullscreen")
    res = {"wrapper": "script -q <typescript> claude"}
    try:
        res["ready"] = r.wait_ready()
        r.pump(seconds=1.5)
        res["modes_before_signal"] = analyze(bytes(r.buf))
        r.send_to_claude(signal.SIGTERM)
        res["wrapper_exited"] = r.wait_exit(20)
        r.pump(seconds=1.0)
        res["modes_after_exit_master_capture"] = analyze(bytes(r.buf))
        if os.path.exists(tsf):
            ts = open(tsf, "rb").read()
            res["typescript_bytes"] = len(ts)
            res["modes_after_exit_script_typescript"] = analyze(ts)
            res["typescript_tail"] = tail_repr(ts, 400)
    finally:
        r.finish(res)


SCENARIOS = {"probe": s_probe, "q1": s_q1, "q3": s_q3, "q4": s_q4, "q5": s_q5, "q6": s_q6, "q7": s_q7, "script": s_script}


def main(args):
    names = args or ["probe"]
    if names == ["all"]:
        names = ["probe", "q5", "q6", "q1", "q3", "q4", "q7", "script"]
    os.makedirs(OUT, exist_ok=True)
    for n in names:
        print("### scenario %s" % n, flush=True)
        try:
            SCENARIOS[n]()
        except Exception:
            tb = traceback.format_exc()
            with open(os.path.join(OUT, n + ".error.txt"), "w") as f:
                f.write(tb)
            print("SCENARIO %s FAILED\n%s" % (n, tb), file=sys.stderr, flush=True)


main(sys.argv[1:])
PY
