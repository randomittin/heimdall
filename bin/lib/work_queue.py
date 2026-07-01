#!/usr/bin/env python3
# work_queue.py — the LOCAL continuous-intake work queue (the durable store behind
# `bin/heimdall-queue` + the `bin/heimdall-watch` drainer).
#
# This GENERALIZES bin/lib/issue_queue.py's durability discipline (atomic writes,
# fsync, claim-before-work, idempotent-by-hash ingest, prioritized pick) into a
# kind-agnostic work item — a task | issue | review — with a dedup hash, a ttl, a
# retry/poison budget, and a per-task gate verdict. It is DISTINCT from the Cloud
# Run control-plane (which refuses arbitrary prompts by security design): every
# item here is written to a purely LOCAL append-only log, never routed through the
# PKI control-plane allowlist.
#
# STORE (append-only + replay-fold): ${HEIMDALL_HOME:-<repo>/.heimdall}/queue/
# work.jsonl. Every mutation is ONE appended JSON line (an "op" record); the live
# state is the fold over the whole log. Durability discipline mirrors issue_queue /
# persona_store: every append is flushed + fsync'd, and every read-modify-append
# op (the pick claim especially) holds an EXCLUSIVE flock so two concurrent picks
# can never fight over one item (claim-before-work — the no-double-pick guard).
#
# ITEM SCHEMA (the folded live shape):
#   id            unique work id (wq-<ts>-<rand>)
#   kind          task | issue | review
#   prompt        the work body (for kind=task) — or None
#   task_ref      a reference to external work (for kind=issue|review) — or None
#   repo          the repo the work targets (part of the dedup hash)
#   dedup_hash    sha256(prompt_or_task_ref + "\0" + repo) — idempotency key
#   priority      0-9 (9 = highest; drained first)
#   source        cli | mcp | webhook — the intake frontend
#   state         queued | claimed | running | done | failed | flagged
#   claimed_by    the HAID that claimed it (or None)
#   claimed_at    ISO time the current claim was taken (or None) — the ttl anchor
#   ttl_s         seconds a claim may live before it is reaped as crashed
#   attempts      how many times it has been CLAIMED (incremented at pick)
#   max_attempts  the poison budget — attempts >= max on reap/fail => flagged
#   gate_verdict  PROVEN | BLOCKED | None — the ATTESTED verdict (never self-report)
#   created_at    ISO ingest time
#   updated_at    ISO time of the last state change
#   seq           monotonic insertion index (stable tie-break for pick order)
#
# This is a LIBRARY with a thin CLI core (driven by bin/heimdall-queue). The CLI
# owns argv + the JSON stdout shape; the library owns durability + the fold.

from __future__ import annotations

import datetime
import fcntl
import hashlib
import json
import os

# ── lifecycle states ───────────────────────────────────────────────────────────
STATE_QUEUED = "queued"
STATE_CLAIMED = "claimed"
STATE_RUNNING = "running"
STATE_DONE = "done"
STATE_FAILED = "failed"
STATE_FLAGGED = "flagged"

# states that REMOVE an item from the pick set (already-claimed / in-flight).
_CLAIMED_STATES = (STATE_CLAIMED, STATE_RUNNING)
_TERMINAL_STATES = (STATE_DONE, STATE_FLAGGED)
# a dedup hash held by an item in ANY of these states blocks a re-ingest (a retry
# of live-or-resolved work never double-runs). failed/flagged are re-ingestable.
_DEDUP_BLOCKING = (STATE_QUEUED, STATE_CLAIMED, STATE_RUNNING, STATE_DONE)

_KINDS = ("task", "issue", "review")
_SOURCES = ("cli", "mcp", "webhook")

DEFAULT_TTL_S = 1800          # 30 min before a claim is presumed crashed
DEFAULT_MAX_ATTEMPTS = 3      # poison budget
DEFAULT_PRIORITY = 5


# ── runtime home (mirrors issue_queue.heimdall_home) ───────────────────────────
def _repo_root(start):
    cur = os.path.abspath(start)
    while True:
        if os.path.isdir(os.path.join(cur, ".git")):
            return cur
        parent = os.path.dirname(cur)
        if parent == cur:
            return os.path.abspath(start)
        cur = parent


def heimdall_home(repo=None):
    """${HEIMDALL_HOME:-<repo>/.heimdall}, resolved from the env every call so a
    test that sets HEIMDALL_HOME in a subprocess sees its own dir."""
    explicit = os.environ.get("HEIMDALL_HOME")
    if explicit:
        return explicit
    base = _repo_root(repo or os.getcwd())
    return os.path.join(base, ".heimdall")


def log_path(repo=None):
    """Absolute path to the append-only work log."""
    return os.path.join(heimdall_home(repo), "queue", "work.jsonl")


def _now():
    return datetime.datetime.now(datetime.timezone.utc)


def _now_iso():
    return _now().replace(microsecond=0).isoformat()


def _parse_iso(ts):
    if not ts:
        return None
    s = str(ts).strip()
    if s.endswith("Z"):
        s = s[:-1] + "+00:00"
    try:
        dt = datetime.datetime.fromisoformat(s)
    except ValueError:
        return None
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=datetime.timezone.utc)
    return dt


def dedup_hash(body, repo):
    """The idempotency key: sha256(body + NUL + repo). Stable across processes."""
    h = hashlib.sha256()
    h.update((body or "").encode("utf-8"))
    h.update(b"\x00")
    h.update((repo or "").encode("utf-8"))
    return h.hexdigest()


def _new_id():
    return "wq-%d-%s" % (int(_now().timestamp() * 1000), os.urandom(3).hex())


# ── the append-only store with replay-fold ─────────────────────────────────────
class WorkQueue:
    """The durable local work queue. State lives ONLY in the append-only log; the
    in-memory view is a fold over it, re-read on demand so concurrent processes
    (multiple CLI invocations, a webhook + a drainer) always agree on disk."""

    def __init__(self, path=None, repo=None):
        self.path = path or log_path(repo)

    # -- durability primitives -------------------------------------------------
    def _lock_path(self):
        return self.path + ".lock"

    def _ensure_dir(self):
        os.makedirs(os.path.dirname(self.path), exist_ok=True)

    def _append(self, record):
        """Append ONE op record as a JSON line, flushed + fsync'd (durable)."""
        self._ensure_dir()
        line = json.dumps(record, sort_keys=True) + "\n"
        with open(self.path, "a", encoding="utf-8") as fh:
            fh.write(line)
            fh.flush()
            os.fsync(fh.fileno())

    def _locked(self):
        """Context manager holding an EXCLUSIVE flock for a read-modify-append.
        Serializes concurrent picks/reaps so the claim-before-work guard holds."""
        self._ensure_dir()
        return _FlockCtx(self._lock_path())

    # -- fold ------------------------------------------------------------------
    def _fold(self):
        """Replay the log into { id: item }. Later ops for an id overwrite earlier
        fields. A malformed line is skipped (never aborts the fold)."""
        state = {}
        if not os.path.exists(self.path):
            return state
        with open(self.path, "r", encoding="utf-8") as fh:
            for raw in fh:
                raw = raw.strip()
                if not raw:
                    continue
                try:
                    rec = json.loads(raw)
                except ValueError:
                    continue
                op = rec.get("op")
                if op == "add":
                    item = rec.get("item") or {}
                    iid = item.get("id")
                    if iid:
                        state[iid] = dict(item)
                elif op == "update":
                    iid = rec.get("id")
                    it = state.get(iid)
                    if it is not None:
                        it.update(rec.get("fields") or {})
        return state

    # -- ingest (idempotent by dedup_hash) -------------------------------------
    def add(self, body, kind="task", repo="", priority=DEFAULT_PRIORITY,
            source="cli", ttl_s=DEFAULT_TTL_S, max_attempts=DEFAULT_MAX_ATTEMPTS,
            task_ref=None):
        """Ingest a work item. body is the prompt (kind=task) or the dedup subject.
        Idempotent: if a live-or-resolved item already holds this dedup_hash, this
        is a NO-OP and returns (existing_item, False). Otherwise appends an `add`
        op and returns (new_item, True). Held under the exclusive lock so a
        race between two identical adds cannot both win."""
        if kind not in _KINDS:
            raise ValueError("kind must be one of %s" % ", ".join(_KINDS))
        if source not in _SOURCES:
            raise ValueError("source must be one of %s" % ", ".join(_SOURCES))
        priority = _clamp_priority(priority)
        subject = body if body is not None else (task_ref or "")
        dh = dedup_hash(subject, repo)
        with self._locked():
            state = self._fold()
            for it in state.values():
                if it.get("dedup_hash") == dh and it.get("state") in _DEDUP_BLOCKING:
                    return it, False
            now = _now_iso()
            item = {
                "id": _new_id(),
                "kind": kind,
                "prompt": body if kind == "task" else None,
                "task_ref": task_ref,
                "repo": repo,
                "dedup_hash": dh,
                "priority": priority,
                "source": source,
                "state": STATE_QUEUED,
                "claimed_by": None,
                "claimed_at": None,
                "ttl_s": int(ttl_s),
                "attempts": 0,
                "max_attempts": int(max_attempts),
                "gate_verdict": None,
                "created_at": now,
                "updated_at": now,
                "seq": len(state),
            }
            self._append({"op": "add", "at": now, "item": item})
            return item, True

    # -- pick (prioritized claim-before-work) ----------------------------------
    def pick(self, claimed_by="watch", now=None):
        """Claim the highest-priority QUEUED item, atomically moving it to CLAIMED
        (attempts++) BEFORE returning it. Order: highest priority first, oldest
        (lowest seq) first on a tie. Returns the claimed item, or None if the queue
        is empty. The whole read-select-append runs under the exclusive lock, so a
        second concurrent pick sees the first's claim and never double-picks."""
        now_iso = (now.replace(microsecond=0).isoformat()
                   if now is not None else _now_iso())
        with self._locked():
            state = self._fold()
            queued = [it for it in state.values() if it.get("state") == STATE_QUEUED]
            if not queued:
                return None
            queued.sort(key=lambda it: (-int(it.get("priority", 0)),
                                        int(it.get("seq", 0)), it.get("id", "")))
            chosen = queued[0]
            fields = {
                "state": STATE_CLAIMED,
                "claimed_by": claimed_by,
                "claimed_at": now_iso,
                "attempts": int(chosen.get("attempts", 0)) + 1,
                "updated_at": now_iso,
            }
            self._append({"op": "update", "at": now_iso,
                          "id": chosen["id"], "fields": fields})
            merged = dict(chosen)
            merged.update(fields)
            return merged

    # -- state transitions -----------------------------------------------------
    def _update(self, item_id, fields):
        with self._locked():
            state = self._fold()
            it = state.get(item_id)
            if it is None:
                raise KeyError("unknown work id: %s" % item_id)
            fields = dict(fields)
            fields.setdefault("updated_at", _now_iso())
            self._append({"op": "update", "at": fields["updated_at"],
                          "id": item_id, "fields": fields})
            it.update(fields)
            return it

    def mark_running(self, item_id):
        """CLAIMED -> RUNNING (the drainer has begun executing the work)."""
        return self._update(item_id, {"state": STATE_RUNNING})

    def complete(self, item_id, verdict):
        """Record the ATTESTED verdict and move the item to DONE. verdict must be
        PROVEN | BLOCKED — a BLOCKED verdict is a recorded outcome, NOT a retry
        (the retry/poison path is for crashes + executor failures, not gate calls).
        The verdict is the attestation's, never the executor's self-report."""
        v = (verdict or "").upper()
        if v not in ("PROVEN", "BLOCKED"):
            raise ValueError("verdict must be PROVEN or BLOCKED (got %r)" % verdict)
        return self._update(item_id,
                            {"state": STATE_DONE, "gate_verdict": v})

    def fail(self, item_id, now=None):
        """An executor failure. Requeue for another attempt, or FLAG as poison if
        the attempt budget is spent (attempts >= max_attempts) — never infinite
        retry. Returns the updated item."""
        with self._locked():
            state = self._fold()
            it = state.get(item_id)
            if it is None:
                raise KeyError("unknown work id: %s" % item_id)
            return self._decide_retry(it, now)

    def reap(self, now=None):
        """Reap CRASHED claims: any CLAIMED/RUNNING item whose claimed_at + ttl_s
        is older than `now` is presumed dead. Requeue it (state=queued) or FLAG it
        as poison if the attempt budget is spent. Returns the list of reaped ids.
        The ttl guarantees a crash never wedges an item in-flight forever."""
        clk = now or _now()
        reaped = []
        with self._locked():
            state = self._fold()
            for it in state.values():
                if it.get("state") not in _CLAIMED_STATES:
                    continue
                claimed_at = _parse_iso(it.get("claimed_at"))
                ttl = int(it.get("ttl_s", DEFAULT_TTL_S))
                if claimed_at is None:
                    deadline = None
                else:
                    deadline = claimed_at + datetime.timedelta(seconds=ttl)
                if deadline is not None and clk >= deadline:
                    self._decide_retry(it, now=clk)
                    reaped.append(it["id"])
        return reaped

    def _decide_retry(self, it, now=None):
        """Shared requeue-or-flag decision (used by fail + reap). MUST be called
        while holding the lock. attempts was incremented at claim, so a spent
        budget (attempts >= max_attempts) flags; otherwise the item requeues."""
        now_iso = (now.replace(microsecond=0).isoformat()
                   if isinstance(now, datetime.datetime) else _now_iso())
        attempts = int(it.get("attempts", 0))
        max_attempts = int(it.get("max_attempts", DEFAULT_MAX_ATTEMPTS))
        if attempts >= max_attempts:
            fields = {"state": STATE_FLAGGED, "claimed_by": None,
                      "claimed_at": None, "updated_at": now_iso}
        else:
            fields = {"state": STATE_QUEUED, "claimed_by": None,
                      "claimed_at": None, "updated_at": now_iso}
        self._append({"op": "update", "at": now_iso,
                      "id": it["id"], "fields": fields})
        it.update(fields)
        return it

    # -- queries ---------------------------------------------------------------
    def get(self, item_id):
        return self._fold().get(item_id)

    def list(self, state=None):
        """All items, queued ones first in pick order, then the rest by recency."""
        items = list(self._fold().values())
        queued = [it for it in items if it.get("state") == STATE_QUEUED]
        queued.sort(key=lambda it: (-int(it.get("priority", 0)),
                                    int(it.get("seq", 0)), it.get("id", "")))
        rest = [it for it in items if it.get("state") != STATE_QUEUED]
        rest.sort(key=lambda it: it.get("updated_at", ""))
        ordered = queued + rest
        if state is not None:
            ordered = [it for it in ordered if it.get("state") == state]
        return ordered

    def status(self):
        """At-a-glance counts + the HUD line (depth / draining / last_verdict)."""
        items = list(self._fold().values())
        counts = {s: 0 for s in (STATE_QUEUED, STATE_CLAIMED, STATE_RUNNING,
                                 STATE_DONE, STATE_FAILED, STATE_FLAGGED)}
        for it in items:
            st = it.get("state")
            if st in counts:
                counts[st] += 1
        # last_verdict = the gate verdict of the most-recently-updated DONE item.
        done = [it for it in items if it.get("state") == STATE_DONE
                and it.get("gate_verdict")]
        done.sort(key=lambda it: it.get("updated_at", ""))
        last_verdict = done[-1].get("gate_verdict") if done else None
        draining = (counts[STATE_CLAIMED] + counts[STATE_RUNNING]) > 0
        return {
            "path": self.path,
            "depth": counts[STATE_QUEUED],
            "draining": draining,
            "last_verdict": last_verdict,
            "total": len(items),
            **counts,
        }


class _FlockCtx:
    """A minimal exclusive-flock context manager on a lock file."""

    def __init__(self, lock_path):
        self.lock_path = lock_path
        self._fh = None

    def __enter__(self):
        self._fh = open(self.lock_path, "w")
        fcntl.flock(self._fh, fcntl.LOCK_EX)
        return self

    def __exit__(self, *exc):
        try:
            fcntl.flock(self._fh, fcntl.LOCK_UN)
        finally:
            self._fh.close()
        return False


def _clamp_priority(p):
    try:
        n = int(p)
    except (TypeError, ValueError):
        return DEFAULT_PRIORITY
    return max(0, min(9, n))


# ── webhook frontend: POST /queue -> the SAME local log ────────────────────────
def serve(port=0, host="127.0.0.1", portfile=None, repo=None):
    """Run a tiny LOCAL http listener. `POST /queue` with a JSON body
    {prompt|task_ref, kind?, repo?, priority?, ttl_s?, max_attempts?} ingests one
    work item into the SAME work.jsonl every other frontend writes — NEVER the PKI
    control-plane. Binds loopback only. Blocks until interrupted. If `portfile` is
    given, the bound port is written there (for an ephemeral --port 0 bind)."""
    from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

    q = WorkQueue(repo=repo)

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *_a):  # silence the default stderr access log
            return

        def _reply(self, code, payload):
            body = (json.dumps(payload) + "\n").encode("utf-8")
            self.send_response(code)
            self.send_header("content-type", "application/json")
            self.send_header("content-length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def do_POST(self):
            if self.path.split("?", 1)[0] != "/queue":
                self._reply(404, {"error": "not found: %s" % self.path})
                return
            length = int(self.headers.get("content-length") or 0)
            raw = self.rfile.read(length) if length else b""
            try:
                data = json.loads(raw or b"{}")
            except ValueError as exc:
                self._reply(400, {"error": "invalid JSON: %s" % exc})
                return
            body = data.get("prompt")
            task_ref = data.get("task_ref")
            if not body and not task_ref:
                self._reply(400, {"error": "require 'prompt' or 'task_ref'"})
                return
            try:
                item, added = q.add(
                    body=body,
                    kind=data.get("kind", "task"),
                    repo=data.get("repo", ""),
                    priority=data.get("priority", DEFAULT_PRIORITY),
                    source="webhook",
                    ttl_s=data.get("ttl_s", DEFAULT_TTL_S),
                    max_attempts=data.get("max_attempts", DEFAULT_MAX_ATTEMPTS),
                    task_ref=task_ref,
                )
            except ValueError as exc:
                self._reply(400, {"error": str(exc)})
                return
            self._reply(200, {"id": item["id"], "added": added,
                              "dedup_hash": item["dedup_hash"]})

    httpd = ThreadingHTTPServer((host, port), Handler)
    bound = httpd.server_address[1]
    if portfile:
        with open(portfile, "w", encoding="utf-8") as fh:
            fh.write(str(bound))
            fh.flush()
            os.fsync(fh.fileno())
    else:
        print(json.dumps({"listening": "http://%s:%d/queue" % (host, bound)}))
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        return
    finally:
        httpd.server_close()


# ── CLI core (driven by bin/heimdall-queue) ────────────────────────────────────
def _print(obj):
    print(json.dumps(obj, indent=2, sort_keys=True))


def _stderr():
    import sys
    return sys.stderr


def _cli(argv):
    import argparse

    p = argparse.ArgumentParser(prog="heimdall-queue", add_help=True)
    sub = p.add_subparsers(dest="cmd")

    sp = sub.add_parser("add")
    sp.add_argument("body", nargs="?", default=None)
    sp.add_argument("--kind", default="task", choices=list(_KINDS))
    sp.add_argument("--repo", default="")
    sp.add_argument("--priority", type=int, default=DEFAULT_PRIORITY)
    sp.add_argument("--source", default="cli", choices=list(_SOURCES))
    sp.add_argument("--ttl", type=int, default=DEFAULT_TTL_S, dest="ttl_s")
    sp.add_argument("--max-attempts", type=int, default=DEFAULT_MAX_ATTEMPTS,
                    dest="max_attempts")
    sp.add_argument("--task-ref", default=None, dest="task_ref")

    sp = sub.add_parser("pick")
    sp.add_argument("--by", default="watch", dest="claimed_by")
    sp.add_argument("--now", default=None)

    sp = sub.add_parser("complete")
    sp.add_argument("id")
    sp.add_argument("--verdict", required=True)

    sp = sub.add_parser("fail")
    sp.add_argument("id")

    sp = sub.add_parser("reap")
    sp.add_argument("--now", default=None)

    sp = sub.add_parser("get")
    sp.add_argument("id")

    sp = sub.add_parser("list")
    sp.add_argument("--state", default=None)

    sub.add_parser("status")

    sp = sub.add_parser("serve")
    sp.add_argument("--port", type=int, default=0)
    sp.add_argument("--host", default="127.0.0.1")
    sp.add_argument("--portfile", default=None)

    args = p.parse_args(argv)
    if not args.cmd:
        p.print_help()
        return 2

    q = WorkQueue()

    if args.cmd == "add":
        body = args.body
        if body is None and args.task_ref is None:
            print("error: add needs a body prompt or --task-ref", file=_stderr())
            return 2
        try:
            item, added = q.add(
                body=body, kind=args.kind, repo=args.repo, priority=args.priority,
                source=args.source, ttl_s=args.ttl_s,
                max_attempts=args.max_attempts, task_ref=args.task_ref)
        except ValueError as exc:
            print("error: %s" % exc, file=_stderr())
            return 2
        _print({"id": item["id"], "added": added,
                "dedup_hash": item["dedup_hash"], "state": item["state"],
                "priority": item["priority"]})
        return 0

    if args.cmd == "pick":
        now = _parse_iso(args.now) if args.now else None
        chosen = q.pick(claimed_by=args.claimed_by, now=now)
        _print({"picked": chosen})
        return 0

    if args.cmd == "complete":
        try:
            item = q.complete(args.id, args.verdict)
        except (KeyError, ValueError) as exc:
            print("error: %s" % exc, file=_stderr())
            return 2
        _print({"completed": True, "item": item})
        return 0

    if args.cmd == "fail":
        try:
            item = q.fail(args.id)
        except KeyError as exc:
            print("error: %s" % exc, file=_stderr())
            return 2
        _print({"item": item})
        return 0

    if args.cmd == "reap":
        now = _parse_iso(args.now) if args.now else None
        reaped = q.reap(now=now)
        _print({"reaped": reaped})
        return 0

    if args.cmd == "get":
        item = q.get(args.id)
        if item is None:
            print("error: unknown work id: %s" % args.id, file=_stderr())
            return 3
        _print(item)
        return 0

    if args.cmd == "list":
        _print(q.list(state=args.state))
        return 0

    if args.cmd == "status":
        _print(q.status())
        return 0

    if args.cmd == "serve":
        serve(port=args.port, host=args.host, portfile=args.portfile)
        return 0

    p.print_help()
    return 2


if __name__ == "__main__":
    import sys
    sys.exit(_cli(sys.argv[1:]))
