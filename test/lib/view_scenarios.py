#!/usr/bin/env python3
"""test/lib/view_scenarios.py -- the cases of test/companion-view.test.sh (the `view-v1` file diff, end to end).

Every case drives the REAL bin/heimdall-relay-client (or a mutated copy of it -- see --client) as its own process against
test/lib/fake-relay.py, through a sealed command and the sealed state frame that answers it, with test/lib/view_phone.py
playing the paired phone. Nothing here imports the client or bin/lib/companion_view.py. What git says is computed
independently, by running git again on the same working tree.

    view_scenarios.py main   --client PATH [--groups a,b,..]   one stack, groups wire diff paths secrets params size latch kill
    view_scenarios.py subdir --client PATH                     --repo is a subdirectory of the git toplevel; the 20/min limit
    view_scenarios.py killenv --client PATH                    HMD_UI_CONTROLS=0 in the client's environment

Secret-shaped inputs are assembled at runtime: no such literal sits in the repo. Output: "  ok   ..." / "  FAIL ..." lines
and a closing "P passed, F failed"; exit 1 when F > 0. Processes this starts are reaped on exit; it signals nothing else.
"""
import argparse
import json
import os
import shutil
import socket
import subprocess
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.realpath(__file__))
sys.path.insert(0, HERE)
import view_phone as VP  # noqa: E402

FAKE_RELAY = os.path.join(HERE, "fake-relay.py")
BUDGET = 1048576 * 3 // 8  # the slice budget the client derives from its 1 MiB envelope cap
PASS = FAIL = 0


def check(cond, text, got=None):
    global PASS, FAIL
    if cond:
        PASS += 1
        print("  ok   " + text, flush=True)
    else:
        FAIL += 1
        print("  FAIL " + text, flush=True)
        if got is not None:
            print("       got: %r" % (got,), flush=True)


def token_shaped():
    return "".join(("gh", "p_", "Q" * 36))  # a GitHub-token-shaped string, assembled at runtime


def refused(ack, code):
    return ack is not None and ack.get("ok") is False and ack.get("detail") == code and "id" not in ack


class Repo:
    def __init__(self, path):
        self.path = path

    def git(self, *args):
        return subprocess.run(["git", "-c", "user.email=t@t", "-c", "user.name=t", "-c", "core.quotepath=false", *args],
                              cwd=self.path, check=True, capture_output=True, text=True).stdout

    def write(self, rel, text="", binary=False):
        full = os.path.join(self.path, rel)
        os.makedirs(os.path.dirname(full), exist_ok=True)
        with open(full, "wb" if binary else "w", encoding=None if binary else "utf-8", newline=None if binary else "") as f:
            f.write(text)

    def commit(self, message):
        self.git("add", "-A")
        self.git("commit", "-q", "--allow-empty", "-m", message)

    def reset(self, *untracked):
        self.git("reset", "-q", "--hard", "HEAD")
        for rel in untracked:
            full = os.path.join(self.path, rel)
            if os.path.islink(full) or os.path.isfile(full):
                os.remove(full)

    def numstat(self, *args):
        """git's own `--numstat -z` for the same tree: [(path, add|None, del|None)], None for a binary file's `-`."""
        out = self.git("diff", "--numstat", "-z", *args)
        rows = []
        for field in out.split("\0")[:-1]:
            added, removed, path = field.split("\t", 2)
            rows.append((path, None if added == "-" else int(added), None if removed == "-" else int(removed)))
        return rows


def listed(result):
    return [(f["path"], None if f["binary"] else f["add"], None if f["binary"] else f["del"]) for f in result["files"]]


def lines_of(hunk):
    return [l["t"] + l["s"] for l in hunk["lines"]]


def patch_lines(repo, path, *args):
    """The unified-diff lines git itself prints for `path`, from its first hunk header on."""
    text = repo.git("diff", "--no-ext-diff", "--no-color", "--no-prefix", *args, "--", path)
    rows = text.split("\n")[:-1]
    return rows[next(i for i, row in enumerate(rows) if row.startswith("@@")):]


def shown(result):
    rows = []
    for hunk in result["hunks"]:
        rows += [hunk["header"]] + lines_of(hunk)
    return rows


class Stack:
    """One fake relay and one real relay client on `repo_arg`, with a phone bound to it."""

    def __init__(self, tmp, client, repo, repo_arg=None, env=None):
        self.tmp, self.client_path, self.repo, self.env_extra = tmp, client, repo, env or {}
        self.repo_arg = repo_arg or repo.path
        self.log, self.ctl = os.path.join(tmp, "log"), os.path.join(tmp, "ctl")
        self.out, self.err = os.path.join(tmp, "client.out"), os.path.join(tmp, "client.err")
        self.procs = []
        self.phone = None
        self.listed = False
        self.counter = 0

    def start(self):
        os.makedirs(self.log)
        os.makedirs(self.ctl)
        relay_port, ui_port = _free_port(), _free_port()
        relay = subprocess.Popen([sys.executable, FAKE_RELAY, "serve", str(relay_port), "--log", self.log, "--ctl", self.ctl],
                                 stdout=open(os.path.join(self.tmp, "relay.out"), "w"), stderr=subprocess.STDOUT)
        self.procs.append(relay)
        for _ in range(100):
            with socket.socket() as probe:
                if probe.connect_ex(("127.0.0.1", relay_port)) == 0:
                    break
            time.sleep(0.1)
        self.phone = VP.Phone(self.ctl, self.log)
        self.phone.bind()
        env = dict(os.environ, **self.env_extra)
        client = subprocess.Popen([self.client_path, "--relay", "http://127.0.0.1:%d" % relay_port, "--repo", self.repo_arg,
                                   "--ui-port", str(ui_port)], stdout=open(self.out, "w"), stderr=open(self.err, "w"),
                                  env=env)
        self.procs.append(client)
        return self.phone.pair(self.out)

    def stop(self):
        for proc in reversed(self.procs):
            if proc.poll() is None:
                proc.terminate()
        for proc in self.procs:
            try:
                proc.wait(timeout=10)
            except subprocess.TimeoutExpired:
                proc.kill()
                proc.wait()

    def rid(self):
        self.counter += 1
        return "v-%d" % self.counter

    def ready(self):
        """The phone lists view-v1 (once): from then on every state frame carries the views slice."""
        if not self.listed:
            self.phone.resync(VP.FULL_CAPS)
            self.listed = True

    def view(self, path=None, **extra):
        """A view request shaped exactly like the app's (hmdapp src/views/protocol.ts), with `extra` overriding keys."""
        self.ready()
        params = {"rid": self.rid(), "kind": "diff", "scope": "worktree", "path": path, "ctx": 3, "max_bytes": 131072}
        params.update(extra)
        return self.phone.view(params)

    def burst(self, params_list):
        """Seal every request first, then read the acks: the client answers them in order."""
        self.ready()
        seqs = [self.phone.command({"action": "view", "params": p}) for p in params_list]
        return [self.phone.ack(s) for s in seqs]

    def artifacts(self):
        """Every file the client and the relay wrote, by name: where a path or a secret must never be."""
        files = {"stdout": self.out, "stderr": self.err, "relay-log": os.path.join(self.log, "requests.log"),
                 "events": os.path.join(self.repo_arg, ".heimdall", "app", "relay-events.jsonl"),
                 "status": os.path.join(self.repo_arg, ".heimdall", "app", "relay.json")}
        text = {}
        for name, path in files.items():
            try:
                with open(path, encoding="utf-8", errors="replace") as f:
                    text[name] = f.read()
            except OSError:
                text[name] = ""
        return text

    def found_in(self, needle):
        """The names of the places `needle` is in: every artifact above and the decrypted frames. [] when it is nowhere."""
        text = self.artifacts()
        text["frames"] = self.phone.all_text()
        return [name for name, body in text.items() if needle in body]


def _free_port():
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def new_repo(tmp, name="repo"):
    repo = Repo(os.path.join(tmp, name))
    os.makedirs(repo.path)
    repo.git("init", "-q", ".")
    repo.write(".gitignore", ".heimdall/\n")
    repo.commit("fixture")
    return repo


# -- groups ----------------------------------------------------------------------------------------------------------------
def g_wire(st):
    p = st.phone
    first = p.state(timeout=30)
    check(first is not None, "wire: the client sent a state frame after the phone bound")
    caps = first["body"]["caps"]
    check("view-v1" in caps and caps == sorted(caps), "wire: every state frame lists view-v1 in its sorted caps", caps)
    check("views" not in first["body"]["state"], "wire: a phone that has not listed view-v1 gets no views key")
    seq = p.command({"action": "view", "params": {"rid": "v-pre", "kind": "diff", "path": None}})
    ack = p.ack(seq)
    check(ack == {"ok": False, "of_seq": seq, "detail": "caps-missing"},
          "wire: a view command before the phone listed view-v1 is refused caps-missing", ack)
    before = p.mark()
    ack, _ = p.resync(VP.FULL_CAPS)
    st.listed = True
    frame = p.state(lambda s: "views" in s, since=before)
    check(frame is not None and frame["body"]["state"]["views"] == {"v": 1, "enabled": True, "kinds": ["diff"], "result": None},
          "wire: after its resync lists view-v1 the next frame carries views {v:1, enabled:true, kinds:[diff], result:null}",
          frame and frame["body"]["state"].get("views"))
    st.repo.write("wire.txt", "one\n")
    st.repo.commit("wire baseline")
    st.repo.write("wire.txt", "two\n")
    ack, res = st.view("wire.txt")
    check(ack and ack.get("ok") is True and res is not None and ack.get("id") == res["id"] and ack["of_seq"] > 0,
          "wire: the ack is {ok:true, of_seq, id: the rid} and the answer rides in state.views.result with that id", ack)
    before = p.mark()
    p.resync(["resync", "z-zlib"])
    frame = p.state(since=before)
    check(frame is not None and "views" not in frame["body"]["state"],
          "wire: a resync that drops view-v1 takes the views key out of the next frame")
    before = p.mark()
    p.resync(VP.FULL_CAPS)
    frame = p.state(lambda s: "views" in s, since=before)
    check(frame is not None and frame["body"]["state"]["views"]["result"] is None,
          "wire: and the result held for the earlier listing is gone when the phone lists view-v1 again")
    st.repo.reset()


def g_diff(st):
    r, p = st.repo, st.phone
    st.ready()
    r.write("src/a.ts", "".join("line %d\n" % i for i in range(1, 41)))
    r.write("src/gone.txt", "bye\n")
    r.write("src/mv.txt", "".join("keep %d\n" % i for i in range(1, 30)))
    r.write("bin.dat", b"a\0b\n", binary=True)
    r.write('we"ird.txt', "one\n")
    r.write("notes with space.txt", "alpha\n")
    r.write("nonl.txt", "x")
    r.write(".env", "FOO=bar\n")
    r.commit("diff baseline")
    r.write("src/a.ts", "".join("CHANGED %d\n" % i if i in (3, 20, 38) else "line %d\n" % i for i in range(1, 41)))
    os.remove(os.path.join(r.path, "src/gone.txt"))
    r.git("mv", "src/mv.txt", "src/moved.txt")
    r.write("src/moved.txt", "".join("keep %d\n" % i if i != 5 else "edited\n" for i in range(1, 30)))
    r.write("bin.dat", b"a\0c\n", binary=True)
    r.write('we"ird.txt', "two\n")
    r.write("notes with space.txt", "beta\n")
    r.write("nonl.txt", "y")
    r.write(".env", "FOO=changed\n")
    ack, res = st.view("src/a.ts")
    rows = r.numstat("--", "src/a.ts")
    check(res is not None and res["kind"] == "diff" and res["truncated"] is False and isinstance(res["at"], float),
          "diff: a modified tracked file answers {kind:diff, truncated:false, at}", res and {k: res[k] for k in ("kind", "truncated")})
    check(res is not None and res["files"] == [{"path": "src/a.ts", "status": "M", "add": rows[0][1], "del": rows[0][2],
                                                "binary": False}], "diff: files[] is that file, counted as git diff --numstat counts it",
          res and res["files"])
    check(res is not None and shown(res) == patch_lines(r, "src/a.ts", "-U3"),
          "diff: header and lines of every hunk are git's own unified diff, character for character")
    check(res is not None and res["bytes"] == sum(len(row.encode()) + 1 for row in shown(res)),
          "diff: bytes is the size of the diff text shown")
    check(res is not None and sum(l["t"] == "+" for h in res["hunks"] for l in h["lines"]) == rows[0][1]
          and sum(l["t"] == "-" for h in res["hunks"] for l in h["lines"]) == rows[0][2] and all(h["path"] == "src/a.ts" for h in res["hunks"]),
          "diff: the + and - lines add up to the numstat counts, every hunk under its own path")
    ack, whole = st.view(None)
    want = [row for row in r.numstat() if row[0] != ".env"]
    check(whole is not None and listed(whole) == want, "diff: the whole tree lists exactly git diff --numstat's files, in its order, less .env",
          whole and listed(whole))
    names = {f["path"]: f for f in whole["files"]} if whole else {}
    check(names.get("src/gone.txt", {}).get("status") == "D" and names.get('we"ird.txt', {}).get("status") == "M"
          and names.get("bin.dat", {}).get("binary") is True and "notes with space.txt" in names,
          "diff: statuses and odd names come through (a deleted file D, a quote in a name, a space, a binary file)",
          sorted(names))
    texts = {}
    for h in whole["hunks"] if whole else []:
        texts.setdefault(h["path"], []).append(h)
    check(whole is not None and all(sum(l["t"] == "+" for h in texts.get(path, []) for l in h["lines"]) == add
                                    for path, add, _ in want if add is not None) and "bin.dat" not in texts and ".env" not in texts,
          "diff: every text file's hunks add up to its numstat, the binary file has none, .env has none")
    check(whole is not None and ".env" not in json.dumps(whole) and not st.found_in("FOO=changed"),
          "diff: .env is in neither files nor hunks, and its content is in no frame", st.found_in("FOO=changed"))
    check(whole is not None and any(l["t"] == "\\" for h in texts.get("nonl.txt", []) for l in h["lines"]),
          "diff: git's no-newline marker comes through as a line of type backslash")
    ack, cached = st.view(None, scope="staged")
    check(cached is not None and listed(cached) == [("src/moved.txt", 0, 0)] and cached["files"][0]["status"] == "R"
          and cached["files"][0]["old_path"] == "src/mv.txt", "diff: scope staged is git diff --cached (the staged rename, with its old_path)",
          cached and cached["files"])
    ack, head = st.view(None, scope="head")
    want_head = [row for row in r.numstat("HEAD") if row[0] != ".env"]
    check(head is not None and listed(head) == want_head and {f["path"]: f for f in head["files"]}["src/moved.txt"]["status"] == "R",
          "diff: scope head is git diff HEAD (the rename shows as R beside the other changes)", head and listed(head))
    ack, c0 = st.view("src/a.ts", ctx=0)
    ack, c10 = st.view("src/a.ts", ctx=10)
    check(c0 is not None and all(l["t"] != " " for h in c0["hunks"] for l in h["lines"]) and c10 is not None
          and sum(len(h["lines"]) for h in c10["hunks"]) > sum(len(h["lines"]) for h in res["hunks"]),
          "diff: ctx 0 has no context lines and ctx 10 has more than ctx 3")
    for name, body, binary in (("fresh.txt", "x\ny\n", False), ("nonl-new.txt", "p\nq", False), ("empty.txt", "", False),
                               ("blob.bin", b"\0\1\2", True)):
        r.write(name, body, binary=binary)
    ack, fresh = st.view("fresh.txt")
    check(fresh is not None and fresh["files"] == [{"path": "fresh.txt", "status": "?", "add": 2, "del": 0, "binary": False}]
          and shown(fresh) == ["@@ -0,0 +1,2 @@", "+x", "+y"], "diff: an untracked file is shown whole, as added (status ?)",
          fresh and (fresh["files"], shown(fresh)))
    ack, nonl = st.view("nonl-new.txt")
    check(nonl is not None and shown(nonl) == ["@@ -0,0 +1,2 @@", "+p", "+q", "\\ No newline at end of file"],
          "diff: an untracked file without a final newline gets git's no-newline marker", nonl and shown(nonl))
    ack, empty = st.view("empty.txt")
    check(empty is not None and empty["files"][0]["add"] == 0 and empty["hunks"] == [], "diff: an empty untracked file lists with no hunks")
    ack, blob = st.view("blob.bin")
    check(blob is not None and blob["files"][0]["binary"] is True and blob["hunks"] == [], "diff: a binary untracked file is flagged binary, no hunks")
    r.write("huge.log", "z" * 2200000)
    ack, _ = st.view("huge.log")
    check(refused(ack, "too-large"), "diff: an untracked file over 2 MiB is refused too-large", ack)
    ack, unchanged = st.view(".gitignore")
    check(unchanged is not None and unchanged["files"] == [] and unchanged["hunks"] == [] and unchanged["truncated"] is False,
          "diff: a tracked path with nothing to show answers ok with no files and no hunks", unchanged)
    acks = st.burst([{"rid": st.rid(), "kind": "diff", "path": "no/such/file.txt"}, {"rid": st.rid(), "kind": "diff", "path": "nothing"}])
    check(all(refused(a, "not-found") for a in acks), "diff: a path that is neither on disk nor in git is refused not-found", acks)
    r.reset("fresh.txt", "nonl-new.txt", "empty.txt", "blob.bin", "huge.log")


DENIED = (".env", ".env.local", "config/.ENV", "prod.env", "id_rsa", "deploy/id_ed25519_work", "keys/server.pem", "certs/a.KEY",
          "store.p12", ".git/config", ".git/HEAD", ".GIT/config", ".heimdall/ui/inbox.jsonl", ".netrc", ".npmrc")
TRAVERSAL = ("../x", "src/../../x", "a/./../../x", "..", "/etc/passwd", "/", "x\0y", "x\ny", "", ".", "./", "p" * 1025, 123, ["a"])


def g_paths(st):
    r, p = st.repo, st.phone
    outside = tempfile.mkdtemp(prefix="view-outside-")
    marker = "OUTSIDE-FILE-MARKER-" + "7" * 8
    with open(os.path.join(outside, "outside.txt"), "w") as f:
        f.write(marker + "\n")
    r.write("src/a.ts", "ok\n")
    r.write("id_utils.py", "a = 1\n")
    r.write(".github/workflows/ci.yml", "on: push\n")
    r.write(".env", "FOO=bar\n")
    r.write("link-target.txt", "t\n")
    os.symlink(os.path.join(outside, "outside.txt"), os.path.join(r.path, "link-out"))
    os.symlink("link-target.txt", os.path.join(r.path, "link-in"))
    os.symlink(outside, os.path.join(r.path, "linkdir"))
    r.commit("paths baseline")
    r.write("id_utils.py", "a = 2\n")
    r.write(".github/workflows/ci.yml", "on: [push, pull_request]\n")
    r.write(".env", "FOO=changed\n")
    base = {"kind": "diff", "scope": "worktree", "ctx": 3, "max_bytes": 131072}
    acks = st.burst([dict(base, rid=st.rid(), path=t) for t in TRAVERSAL])
    check(all(refused(a, "bad-params") for a in acks),
          "paths: traversal, absolute, NUL, newline, empty, dot, over-long and non-string paths are bad-params", [(t, a) for t, a in zip(TRAVERSAL, acks) if not refused(a, "bad-params")])
    abs_acks = st.burst([dict(base, rid=st.rid(), path=os.path.join(r.path, "src/a.ts"))])
    check(refused(abs_acks[0], "bad-params"), "paths: the repo's own absolute path is bad-params too (the phone is never given one)", abs_acks)
    acks = st.burst([dict(base, rid=st.rid(), path=d) for d in DENIED])
    check(all(refused(a, "not-allowed") for a in acks), "paths: .git, .heimdall, .env*, *.env, id_rsa-shaped, *.pem *.key *.p12, .netrc .npmrc are not-allowed (case-insensitively), present or not",
          [(d, a) for d, a in zip(DENIED, acks) if not refused(a, "not-allowed")])
    for path in ("id_utils.py", ".github/workflows/ci.yml", ".gitignore"):
        ack, res = st.view(path)
        check(ack and ack.get("ok") is True and res is not None, "paths: %s is an ordinary file and is shown" % path, ack)
    os.symlink(os.path.join(outside, "outside.txt"), os.path.join(r.path, "ulink"))
    escapes = ("link-out", "link-in", "linkdir/outside.txt", "linkdir", "ulink")
    acks = st.burst([dict(base, rid=st.rid(), path=e) for e in escapes])
    check(all(refused(a, "not-allowed") for a in acks), "paths: a symlink anywhere in the path (to outside the repo, inside it, a directory link, an untracked link) is not-allowed",
          [(e, a) for e, a in zip(escapes, acks) if not refused(a, "not-allowed")])
    os.mkfifo(os.path.join(r.path, "fifo"))
    ack, res = st.view("fifo")
    check(ack is not None and (ack.get("ok") is True or refused(ack, "not-allowed")) and (res is None or res["hunks"] == []),
          "paths: a named pipe is answered without hanging and shows nothing", ack)
    check(not st.absent_everywhere(marker) and not st.absent_everywhere("FOO=changed"),
          "paths: neither the outside file's content nor .env's is in any frame or any file the client wrote",
          st.absent_everywhere(marker) + st.absent_everywhere("FOO=changed"))
    ack, again = st.view("id_utils.py")
    check(ack and ack.get("ok") is True, "paths: after all of it a plain request still works")
    r.reset("ulink", "fifo", "link-in", "link-out", "linkdir")
    shutil.rmtree(outside, ignore_errors=True)


def g_secrets(st):
    r = st.repo
    st.ready()
    tok, pwd, key_begin, key_end = token_shaped(), "p" * 24, "-----BEGIN " + "RSA PRIVATE KEY-----", "-----END " + "RSA PRIVATE KEY-----"
    body = ("MIIEvQIBADANBgkq", "hkiG9w0BAQEFAASC")
    email, root = "someone@example.com", r.path
    r.write("k.txt", "start\n")
    r.write("src/a.ts", "x\n")
    r.write("sec.py", "def f(api_key=\"%s\"):\n%s\ndef g():\n%s" % ("x" * 30, "".join("    n%d = %d\n" % (i, i) for i in range(15)),
                                                                   "".join("    m%d = %d\n" % (i, i) for i in range(15))))
    r.write("password=%s.txt" % pwd, "a\n")
    r.commit("secrets baseline")
    r.write("k.txt", "\n".join(["start", "auth = " + tok, "password: " + pwd, key_begin, body[0], body[1], key_end, "plain neighbour",
                                "mail me at %s or see /etc/hosts and %s/src/a.ts" % (email, root), "w" * 2500, ""]))
    ack, res = st.view("k.txt")
    plus = [l["s"] for h in res["hunks"] for l in h["lines"] if l["t"] == "+"] if res else []
    check(res is not None and plus[:6] == ["[redacted]"] * 6,
          "secrets: a token-shaped line, an assigned-credential line and a whole PEM private key (BEGIN, body, END) are masked line by line", plus[:8])
    check(res is not None and plus[6] == "plain neighbour", "secrets: the line next to them is untouched", plus)
    check(res is not None and "[email]" in plus[7] and email not in plus[7] and root not in json.dumps(res) and "hosts" in plus[7] and "/etc/hosts" not in plus[7],
          "secrets: the relay's redaction profile applies to the result (the email, the repo's absolute path and /etc/hosts are scrubbed)", plus[7:8])
    check(res is not None and len(plus[8]) == 2001 and plus[8].endswith("…"), "secrets: a line past 2000 characters is cut with an ellipsis", len(plus[8]) if len(plus) > 8 else None)
    leaked = [n for n in (tok, pwd, body[0], body[1]) if st.absent_everywhere(n)]
    check(not leaked, "secrets: no secret-shaped string and no key body is in any frame or any file the client wrote", leaked)
    r.write("sec.py", "def f(api_key=\"%s\"):\n%s\ndef g():\n%s" % ("x" * 30, "".join("    n%d = %d\n" % (i, i + (100 if i == 9 else 0)) for i in range(15)),
                                                                   "".join("    m%d = %d\n" % (i, i + (100 if i == 9 else 0)) for i in range(15))))
    ack, res = st.view("sec.py")
    heads = [h["header"] for h in res["hunks"]] if res else []
    check(len(heads) == 2 and "api_key" not in heads[0] and heads[0].startswith("@@") and heads[1].endswith("def g():"),
          "secrets: git's function context in a hunk header is dropped when secret-shaped and kept when not", heads)
    name = "password=%s.txt" % pwd
    r.write(name, "b\n")
    ack, one = st.view(name)
    ack, whole = st.view(None)
    check(refused(ack if False else st.burst([{"rid": st.rid(), "kind": "diff", "path": name}])[0], "not-allowed") and whole is not None
          and all(f["path"] != name for f in whole["files"]) and not st.absent_everywhere(pwd),
          "secrets: a secret-shaped file name is not-allowed and left out of the whole tree")
    r.reset()


def g_params(st):
    base = {"kind": "diff", "scope": "worktree", "path": None, "ctx": 3, "max_bytes": 131072}

    def bad(**kw):
        return dict(base, rid=st.rid(), **kw)

    cases = {"unknown kind": dict(base, rid=st.rid(), kind="flamegraph"), "extra key": bad(extra=1), "scope": bad(scope="bogus"),
             "ctx -1": bad(ctx=-1), "ctx 11": bad(ctx=11), "ctx str": bad(ctx="3"), "ctx float": bad(ctx=3.5), "ctx bool": bad(ctx=True),
             "max_bytes 0": bad(max_bytes=0), "max_bytes over": bad(max_bytes=262145), "max_bytes str": bad(max_bytes="9"),
             "max_bytes bool": bad(max_bytes=True), "no rid": {k: v for k, v in base.items()}, "rid chars": dict(base, rid="v 1"),
             "rid long": dict(base, rid="v" * 33), "rid int": dict(base, rid=5), "kind int": dict(base, rid=st.rid(), kind=7)}
    acks = st.burst(list(cases.values()))
    check(all(refused(a, "bad-params") for a in acks), "params: an unknown kind, an extra key, a wrong type or range and a bad rid are all bad-params",
          [(k, a) for k, a in zip(cases, acks) if not refused(a, "bad-params")])
    seqs = [st.phone.command({"action": "view", "params": params}) for params in ([1], None, "diff")]
    acks = [st.phone.ack(s) for s in seqs]
    check(all(refused(a, "bad-params") for a in acks), "params: params that are not an object are bad-params", acks)
    others = [{"rid": st.rid(), "kind": "transcript", "tail": 200}, {"rid": st.rid(), "kind": "reel", "name": "x.txt"}, {"rid": st.rid(), "kind": "pr"}]
    acks = st.burst(others)
    check(all(refused(a, "not-implemented") for a in acks), "params: transcript, reel and pr -- the contract's other kinds -- are refused not-implemented", acks)
    acks = st.burst([{"rid": st.rid(), "kind": "diff"}])
    check(acks[0] is not None and acks[0].get("ok") is True, "params: only rid and kind are required (the rest default)", acks)


def g_size(st):
    r = st.repo
    st.ready()
    r.write("spread.txt", "".join("row %d\n" % i for i in range(200)))
    r.write("bighunk.txt", "".join("old %d\n" % i for i in range(400)))
    r.write("huge.txt", "a\nb\nc\n")
    r.write("many/seed.txt", "x\n")
    r.commit("size baseline")
    r.write("spread.txt", "".join("ROW %d\n" % i if i in (10, 50, 90, 130, 170) else "row %d\n" % i for i in range(200)))
    ack, full = st.view("spread.txt")

    def size(h):
        return len(h["header"].encode()) + 1 + sum(len(l["s"].encode()) + 2 for l in h["lines"])

    if full is None or len(full["hunks"]) != 5:
        check(False, "size: fixture has five hunks", full and len(full["hunks"]))
        return
    cut = size(full["hunks"][0]) + size(full["hunks"][1]) + 5
    ack, two = st.view("spread.txt", max_bytes=cut)
    check(two is not None and two["hunks"] == full["hunks"][:2] and two["truncated"] is True and two["bytes"] == size(full["hunks"][0]) + size(full["hunks"][1])
          and two["bytes"] <= cut and two["files"] == full["files"],
          "size: past max_bytes the diff is cut at a hunk boundary (two whole hunks), truncated:true, bytes <= max_bytes, files[] still complete",
          two and (len(two["hunks"]), two["bytes"], cut))
    r.write("bighunk.txt", "".join("new %d\n" % i for i in range(400)))
    ack, whole = st.view("bighunk.txt")
    ack, part = st.view("bighunk.txt", max_bytes=2000)
    check(whole is not None and part is not None and len(part["hunks"]) == 1 and 0 < len(part["hunks"][0]["lines"]) < len(whole["hunks"][0]["lines"])
          and lines_of(part["hunks"][0]) == lines_of(whole["hunks"][0])[:len(part["hunks"][0]["lines"])] and part["truncated"] is True and part["bytes"] <= 2000,
          "size: a first hunk that alone is over max_bytes is kept in part (its leading lines), never dropped to nothing",
          part and (len(part["hunks"]), part["bytes"]))
    r.write("huge.txt", "".join("%059d\n" % i for i in range(4000)))
    ack, big = st.view("huge.txt")
    check(big is not None and big["truncated"] is True and 0 < big["bytes"] <= 131072 and big["files"][0]["add"] == 4000,
          "size: the default max_bytes (131072) cuts a 240 KB diff, and the file's count is still the whole file's", big and (big["truncated"], big["bytes"]))
    r.write("wide.txt", "".join("字" * 40 + "\n" for _ in range(2500)))
    before = st.phone.mark()
    st.phone.resync(["resync", "view-v1"])
    ack, wide = st.view("wide.txt", max_bytes=262144)
    plain = st.phone.state(lambda s: ((s.get("views") or {}).get("result") or {}).get("id") == (wide or {}).get("id"), since=before)
    check(wide is not None and wide["truncated"] is True and len(json.dumps(wide, separators=(",", ":"))) <= BUDGET and wide["bytes"] <= 262144,
          "size: a result is held to the slice budget (3/8 of the envelope cap) however wide its lines", wide and len(json.dumps(wide, separators=(",", ":"))))
    check(plain is not None and plain["z"] is False and plain["envelope_bytes"] < 1048576,
          "size: sealed plain (a phone without z-zlib) the whole frame is still under the 1 MiB envelope cap", plain and plain["envelope_bytes"])
    before = st.phone.mark()
    st.phone.resync(VP.FULL_CAPS)
    squeezed = st.phone.state(lambda s: ((s.get("views") or {}).get("result") or {}).get("id") == (wide or {}).get("id"), since=before)
    check(squeezed is not None and plain is not None and squeezed["z"] is True and squeezed["envelope_bytes"] < plain["envelope_bytes"],
          "size: for a phone that listed z-zlib the same frame goes out zlib-compressed and smaller", squeezed and squeezed["envelope_bytes"])
    for i in range(2100):
        r.write("many/f%04d.txt" % i, "v%d\n" % i)
    r.commit("many baseline")
    for i in range(2100):
        r.write("many/f%04d.txt" % i, "w%d\n" % i)
    ack, many = st.view(None)
    check(many is not None and len(many["files"]) == 2000 and many["truncated"] is True,
          "size: a diff of 2100 files lists 2000 (the phone's cap) and says it is truncated", many and len(many["files"]))
    r.reset("wide.txt")


def g_latch(st):
    r, p = st.repo, st.phone
    st.ready()
    r.write("secret-roadmap-marker.txt", "a\n")
    r.commit("latch baseline")
    r.write("secret-roadmap-marker.txt", "b\n")
    ack, res = st.view("secret-roadmap-marker.txt")
    check(res is not None, "latch: a request from the paired device is answered")
    wrong = bytes(range(32))
    before = p.mark()
    seq = p.command({"action": "view", "params": {"rid": "v-forged", "kind": "diff", "path": None}}, key=wrong)
    ack = p.ack(seq)
    check(ack is not None and ack.get("ok") is False and ack.get("detail") == "decrypt-failed",
          "latch: a command not sealed under the paired session key is decrypt-failed", ack)
    check(p.state(lambda s: ((s.get("views") or {}).get("result") or {}).get("id") == "v-forged", since=before, timeout=2) is None,
          "latch: and nothing it asked for is ever answered")
    before = p.mark()
    seq = p.command({"action": "view", "params": {"rid": "v-replay", "kind": "diff", "path": None}}, seq=1)
    ack = p.ack(seq)
    check(ack is not None and ack.get("ok") is False and ack.get("detail") == "non-increasing-seq",
          "latch: a genuine command under a seq already used is refused by the replay guard", ack)
    check(p.state(lambda s: ((s.get("views") or {}).get("result") or {}).get("id") == "v-replay", since=before, timeout=2) is None,
          "latch: and is not run")
    before = p.mark()
    p.rebind()
    frame = p.state(lambda s: "views" not in s, since=before)
    check(frame is not None, "latch: when the device binds again hmd forgets what the phone listed: the next frame has no views key")
    before = p.mark()
    p.resync(VP.FULL_CAPS)
    frame = p.state(lambda s: "views" in s, since=before)
    check(frame is not None and frame["body"]["state"]["views"]["result"] is None,
          "latch: and the result held for the earlier binding is not served to the new one")
    leaks = {n: b for n, b in st.artifacts().items() if "secret-roadmap-marker" in b or "roadmap" in b}
    events = st.artifacts()["events"]
    check(not leaks and '"action":"view"' in events, "latch: the event log records the view command (action, ok, detail) and no file name or content",
          list(leaks))
    r.reset()


def g_kill(st):
    r = st.repo
    st.ready()
    r.write("kill.txt", "a\n")
    r.commit("kill baseline")
    r.write("kill.txt", "b\n")
    ack, res = st.view("kill.txt")
    check(res is not None, "kill: with the switch on its default (on) a request is answered")
    flag = os.path.join(r.path, ".heimdall", "app", "controls-disabled")
    os.makedirs(os.path.dirname(flag), exist_ok=True)
    open(flag, "w").close()
    ack, _ = st.view("kill.txt")
    check(refused(ack, "controls-off"), "kill: with .heimdall/app/controls-disabled in place a request is refused controls-off", ack)
    before = st.phone.mark()
    st.phone.resync(VP.FULL_CAPS)
    frame = st.phone.state(lambda s: "views" in s, since=before)
    check(frame is not None and frame["body"]["state"]["views"] == {"v": 1, "enabled": False, "kinds": ["diff"], "result": None},
          "kill: and the slice says enabled:false and holds no result, though one was held", frame and frame["body"]["state"].get("views"))
    os.remove(flag)
    ack, res = st.view("kill.txt")
    check(res is not None, "kill: taking the file away turns views back on")
    r.reset()


def g_killenv(st):
    first = st.phone.state(timeout=30)
    check(first is not None and "view-v1" in first["body"]["caps"], "killenv: with HMD_UI_CONTROLS=0 the cap is still listed (the phone says why views are off)")
    ack, _ = st.view("anything.txt")
    check(refused(ack, "controls-off"), "killenv: HMD_UI_CONTROLS=0 refuses every request controls-off", ack)
    before = st.phone.mark()
    st.phone.resync(VP.FULL_CAPS)
    frame = st.phone.state(lambda s: "views" in s, since=before)
    check(frame is not None and frame["body"]["state"]["views"]["enabled"] is False, "killenv: and the slice says enabled:false")


def g_subdir(st):
    r = st.repo
    st.ready()
    ack, res = st.view(None)
    check(res is not None and listed(res) == [("a.txt", 1, 1)] and shown(res)[0].startswith("@@"),
          "subdir: with --repo a subdirectory of the git toplevel, paths are relative to it and changes outside it are not listed", res and listed(res))
    ack, one = st.view("a.txt")
    check(one is not None and one["files"][0]["path"] == "a.txt", "subdir: a path relative to --repo works")
    ack, _ = st.view("../other.txt")
    check(refused(ack, "bad-params"), "subdir: ../ out of --repo is still bad-params")
    sent = 3
    oks, limited = 0, None
    for _ in range(25):
        ack, res = st.view("a.txt")
        if ack and ack.get("ok") is True:
            oks += 1
        else:
            limited = ack
            break
    check(limited is not None and limited.get("detail") == "rate-limited" and sent + oks == 20 and 1 <= limited.get("retry_after_s", 0) <= 60,
          "subdir: the 21st request inside a minute is refused rate-limited with retry_after_s (20 answered)", (sent + oks, limited))


MAIN_GROUPS = ("wire", "diff", "paths", "secrets", "params", "size", "latch", "kill")
RUN = {"wire": g_wire, "diff": g_diff, "paths": g_paths, "secrets": g_secrets, "params": g_params, "size": g_size, "latch": g_latch,
       "kill": g_kill, "killenv": g_killenv, "subdir": g_subdir}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("stack", choices=("main", "subdir", "killenv"))
    ap.add_argument("--client", required=True)
    ap.add_argument("--groups", default=",".join(MAIN_GROUPS))
    args = ap.parse_args()
    tmp = tempfile.mkdtemp(prefix="view-scenarios-")
    st = None
    try:
        env = {"HOME": os.path.join(tmp, "home"), "HEIMDALL_HOME": os.path.join(tmp, "home", ".heimdall"), "TMPDIR": tmp}
        os.makedirs(os.path.join(env["HOME"], ".claude"))
        for name in ("CLAUDE_SESSION_ID", "SESSION_ID", "CLAUDE_CODE_SESSION_ID", "HMD_UI_CONTROLS", "HMD_VIEW_RATE_LIMIT"):
            os.environ.pop(name, None)
        if args.stack == "main":
            env["HMD_VIEW_RATE_LIMIT"] = "1000"
            repo = new_repo(tmp)
            st = Stack(tmp, args.client, repo, env=env)
            groups = [g for g in args.groups.split(",") if g]
        elif args.stack == "killenv":
            env["HMD_UI_CONTROLS"] = "0"
            repo = new_repo(tmp)
            st = Stack(tmp, args.client, repo, env=env)
            groups = ["killenv"]
        else:
            top = new_repo(tmp, "top")
            top.write("pkg/a.txt", "one\n")
            top.write("other.txt", "one\n")
            top.commit("subdir baseline")
            top.write("pkg/a.txt", "two\n")
            top.write("other.txt", "two\n")
            st = Stack(tmp, args.client, top, repo_arg=os.path.join(top.path, "pkg"), env=env)
            groups = ["subdir"]
        if not st.start():
            check(False, "setup: the real relay client paired with the fake relay", open(st.err).read()[-400:] if os.path.exists(st.err) else None)
        else:
            check(True, "setup: the real relay client paired with the fake relay and the phone is bound")
            for name in groups:
                RUN[name](st)
    finally:
        if st is not None:
            st.stop()
        shutil.rmtree(tmp, ignore_errors=True)
    print("\n%d passed, %d failed" % (PASS, FAIL))
    return 1 if FAIL else 0


if __name__ == "__main__":
    sys.exit(main())
