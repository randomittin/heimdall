#!/usr/bin/env python3
# issue_queue.py — piece (b) of the Heimdall issue-resolution loop: the SINGLE
# internal issue shape (normalize), the queue store, prioritization, and in-flight
# tracking. The real engine behind `bin/heimdall-issue-queue`.
#
# Three responsibilities, one module (dossier §2 + §3):
#
#   1. normalize(source, raw_item, cfg) — map any adapter's RAW native item to the
#      ONE internal issue schema. The connectors (piece a) return native data; this
#      is the single mapping owner so `fetch_issues` stays adapter-shaped. Pure
#      function: no IO, caller supplies the clock (`now`) so age is deterministic.
#
#   2. The queue store — a JSON file under the gitignored runtime home
#      (${HEIMDALL_HOME:-<repo>/.heimdall}/issues/queue.json), written atomically
#      (.tmp -> os.replace, sorted keys) — same discipline as persona_store.py /
#      the SI-1 capsule. Buckets: issues / in_flight / resolved / flagged.
#
#   3. pick() — prioritized, idempotent claim. The cardinal no-double-work guard:
#      pick() skips any id already in in_flight / resolved / flagged, and on pick
#      atomically MOVES the id into in_flight BEFORE any work touches it
#      (claim-before-work — the heimdall-ledger "claim surfaces before editing"
#      discipline). Two concurrent loop iterations can never fight over one issue.
#
# This is a LIBRARY (pure-ish functions + a small store class). The bash CLI
# (bin/heimdall-issue-queue) is a thin wrapper that owns argv + stdout shape.

from __future__ import annotations

import datetime
import json
import os
import re

# ── schema constants ──────────────────────────────────────────────────────────

SCHEMA_VERSION = "1.0.0"

# the connector .name values that map to a built-in identity descriptor. normalize
# prefers the live connectors registry (piece a) when it is importable; this is the
# honest fallback so normalize is testable in isolation and agrees with piece (a).
_KIND_BY_SOURCE = {
    "github": "issue",
    "slack": "chat",
    "email": "email",
    # corpus = the anonymized-issue-corpus SHADOW-proposal source (cp_issue_synth).
    # A "proposal" is a pending_review candidate a maintainer promotes — NEVER an
    # auto-opened issue. The corpus connector (connectors/corpus.py) reads these;
    # normalize maps them to the ONE internal schema below (source=corpus).
    "corpus": "proposal",
}

# severity rank (dossier §3) — a fixed map; the ONLY interpretation of severity for
# scoring. An absent/unknown severity ranks 0 (never guessed higher).
SEVERITY_RANK = {"critical": 3, "high": 2, "normal": 1, "low": 0, None: 0}

# default prioritization weights (dossier §3) — overridable via cfg.
DEFAULT_WEIGHTS = {"severity": 3, "age": 1, "source": 1}

# the lifecycle states an issue can occupy (dossier §4). queued is the implicit
# state of any id sitting in `issues` and NOT in any claim bucket.
STATE_QUEUED = "queued"
PICKED = "PICKED"

# the buckets that REMOVE an id from the pick set (the no-double-work guard).
_CLAIMED_BUCKETS = ("in_flight", "resolved", "flagged")


# ── runtime home (mirrors persona_store / SI-1) ───────────────────────────────


def _repo_root(start):
    """Walk up from `start` to the nearest git repo root, or return `start`."""
    cur = os.path.abspath(start)
    while True:
        if os.path.isdir(os.path.join(cur, ".git")):
            return cur
        parent = os.path.dirname(cur)
        if parent == cur:
            return os.path.abspath(start)
        cur = parent


def heimdall_home(repo=None):
    """${HEIMDALL_HOME:-<repo>/.heimdall}. Resolved from the environment every call
    (no module-load caching) so a test that sets HEIMDALL_HOME in a subprocess sees
    its own dir. Falls back to the repo root's .heimdall when the env is absent."""
    explicit = os.environ.get("HEIMDALL_HOME")
    if explicit:
        return explicit
    base = _repo_root(repo or os.getcwd())
    return os.path.join(base, ".heimdall")


def queue_path(repo=None):
    """Absolute path to the queue store JSON."""
    return os.path.join(heimdall_home(repo), "issues", "queue.json")


def _now_iso():
    """Current UTC time as a second-precision ISO-8601 string."""
    return (
        datetime.datetime.now(datetime.timezone.utc)
        .replace(microsecond=0)
        .isoformat()
    )


# ── normalize: RAW per-source item -> the ONE internal issue schema (dossier §2) ──


def _identity(source):
    """{ name, label, kind } for a source. Prefers the live connectors registry
    (piece a) so normalize agrees with the adapter's own descriptor; falls back to
    the built-in map for the three launch sources when connectors is not importable
    (e.g. unit-testing piece b in isolation). Raises ValueError on an unknown
    source — normalize never invents a source tag."""
    try:
        import connectors  # piece (a); sibling on sys.path when present

        ident = connectors.get(source).identity()
        return {
            "name": ident.get("name", source),
            "label": ident.get("label", source),
            "kind": ident.get("kind", _KIND_BY_SOURCE.get(source, "issue")),
        }
    except Exception:
        kind = _KIND_BY_SOURCE.get(source)
        if kind is None:
            raise ValueError(
                "unknown source %r — expected one of %s"
                % (source, ", ".join(sorted(_KIND_BY_SOURCE)))
            )
        return {"name": source, "label": source, "kind": kind}


def _first_line(text, limit=120):
    """First non-empty line of `text`, truncated to `limit` chars."""
    for line in (text or "").splitlines():
        line = line.strip()
        if line:
            return line[:limit]
    return ""


def _to_int_seconds(value):
    """Coerce an age value to a non-negative int seconds (None -> 0)."""
    try:
        n = int(value)
    except (TypeError, ValueError):
        return 0
    return max(0, n)


def _to_int(value, default=0):
    """Coerce to int, returning `default` on any failure (no bare except-body)."""
    try:
        return int(value)
    except (TypeError, ValueError):
        return default


def _parse_iso(ts):
    """Parse an ISO-8601 timestamp to an aware datetime, or None."""
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


def _age_seconds(created_at, now):
    """now - created_at in whole seconds, clamped at 0. now is an aware datetime
    supplied by the caller (deterministic). A missing/unparseable created_at -> 0."""
    dt = _parse_iso(created_at)
    if dt is None:
        return 0
    delta = (now - dt).total_seconds()
    return max(0, int(delta))


# ── per-source severity extraction (honest: missing -> None, never guessed) ───

_GITHUB_SEVERITY_LABELS = {
    "critical": "critical",
    "p0": "critical",
    "blocker": "critical",
    "high": "high",
    "p1": "high",
    "bug": "high",
    "normal": "normal",
    "p2": "normal",
    "low": "low",
    "p3": "low",
    "minor": "low",
}

_CHAT_SEVERITY_KEYWORDS = [
    (re.compile(r"\b(blocker|outage|p0|down)\b", re.I), "critical"),
    (re.compile(r"\b(urgent|asap|critical)\b", re.I), "high"),
]

_EMAIL_PRIORITY_HEADER = {
    "1": "critical",
    "2": "high",
    "3": "normal",
    "4": "low",
    "5": "low",
}


def _github_severity(raw):
    """Map GitHub issue labels to a severity, highest wins. Missing -> None."""
    best = None
    best_rank = -1
    for lbl in raw.get("labels") or []:
        name = lbl.get("name") if isinstance(lbl, dict) else lbl
        sev = _GITHUB_SEVERITY_LABELS.get(str(name).strip().lower())
        if sev is not None and SEVERITY_RANK[sev] > best_rank:
            best, best_rank = sev, SEVERITY_RANK[sev]
    return best


def _chat_severity(text):
    """Map Slack keywords to a severity, highest wins. Missing -> None."""
    best = None
    best_rank = -1
    for rx, sev in _CHAT_SEVERITY_KEYWORDS:
        if rx.search(text or "") and SEVERITY_RANK[sev] > best_rank:
            best, best_rank = sev, SEVERITY_RANK[sev]
    return best


def _email_severity(raw):
    """Map an email's X-Priority header (or subject keyword) to severity. None if
    absent."""
    headers = raw.get("headers") or {}
    xprio = headers.get("X-Priority") or raw.get("x_priority")
    if xprio is not None:
        key = str(xprio).strip().split()[0] if str(xprio).strip() else ""
        sev = _EMAIL_PRIORITY_HEADER.get(key)
        if sev is not None:
            return sev
    subject = raw.get("subject") or headers.get("Subject") or ""
    return _chat_severity(subject)


def _source_priority(source, cfg):
    """Per-source weight from config (dossier §7). Default 0 — an unconfigured
    source carries no source-priority boost."""
    sp = ((cfg or {}).get("prioritization") or {}).get("source_priority") or {}
    return _to_int(sp.get(source, 0))


def _strip_html(text):
    """Crude text/plain extraction: drop tags + collapse whitespace runs. Email
    bodies arrive as html or plain; we keep the readable text."""
    if not text:
        return ""
    no_tags = re.sub(r"<[^>]+>", " ", text)
    return re.sub(r"[ \t]+\n", "\n", no_tags).strip()


def normalize(source, raw_item, cfg=None, now=None):
    """Map a RAW per-source item to the ONE internal issue schema (dossier §2).

    source:   connector .name — "github" | "slack" | "email".
    raw_item: the adapter-native dict (what `connectors.get(source).fetch_issues`
              returns). Never mutated.
    cfg:      the loaded config (dossier §7) — supplies per-source priority weights.
    now:      an aware datetime (the clock). Defaults to UTC-now; tests pin it so
              age_seconds is deterministic.

    Returns the normalized issue dict with EXACTLY these fields:
      source, id, title, body, priority_signal{severity, age_seconds,
      source_priority}, links{source_ref, url}, created_at.

    Pure function — no IO, no mutation of raw_item. Honest fields: a missing
    severity is None (never guessed); an absent url is None.
    """
    cfg = cfg or {}
    if now is None:
        now = datetime.datetime.now(datetime.timezone.utc)
    ident = _identity(source)  # validates the source; raises on unknown
    src = ident["name"]

    if src == "github":
        repo = raw_item.get("repo") or ""
        number = raw_item.get("number")
        native_id = "%s#%s" % (repo, number)
        title = raw_item.get("title") or ""
        body = raw_item.get("body") or ""
        severity = _github_severity(raw_item)
        created_at = raw_item.get("created_at") or _now_iso()
        source_ref = {"repo": repo, "number": number}
        url = raw_item.get("html_url")

    elif src == "slack":
        channel = raw_item.get("channel") or ""
        ts = raw_item.get("ts") or ""
        native_id = "%s.%s" % (channel, ts)
        text = raw_item.get("text") or ""
        thread = raw_item.get("thread") or ""
        title = _first_line(text)
        body = text if not thread else "%s\n\n%s" % (text, thread)
        severity = _chat_severity("%s\n%s" % (text, thread))
        created_at = _slack_ts_to_iso(ts)
        source_ref = {
            "channel": channel,
            "ts": ts,
            "thread_ts": raw_item.get("thread_ts"),
        }
        url = raw_item.get("permalink")

    elif src == "corpus":
        # A cp_issue_synth SHADOW proposal (native shape shadow_issue_v1). It is
        # ZERO-CONTENT by construction — a coded pattern (error_class, signature
        # HASH, hmd_version, os_class, command) + distinct-team support counts +
        # sample issue_ids. NO free text, NO path, NO url (SHADOW — never filed).
        pattern = raw_item.get("pattern") if isinstance(raw_item.get("pattern"), dict) else {}
        support = raw_item.get("support") if isinstance(raw_item.get("support"), dict) else {}
        proposal_id = raw_item.get("proposal_id") or ""
        native_id = proposal_id
        error_class = pattern.get("error_class") or "unknown"
        command = pattern.get("command") or "unknown"
        signature_hash = pattern.get("signature_hash") or "unknown"
        teams = support.get("teams")
        issue_count = support.get("issues")
        # Title + body are built from CODED tokens only (never the candidate's raw
        # anything — it is already a coded shadow string). No content can leak.
        title = "[shadow] %s @ %s - %s teams, %s issues (sig %s)" % (
            error_class, command, teams, issue_count, str(signature_hash)[:12]
        )
        body = raw_item.get("candidate") or title
        severity = None  # a shadow proposal carries no severity — never guessed
        created_at = _epoch_to_iso(raw_item.get("created_ts"))
        source_ref = {
            "proposal_id": proposal_id,
            "schema_version": raw_item.get("schema_version"),
            "status": raw_item.get("status"),
            "pattern": dict(pattern),
            "support": dict(support),
            "sample_issue_ids": list(raw_item.get("sample_issue_ids") or []),
        }
        url = None  # SHADOW — a proposal is never filed anywhere, so it has no url

    elif src == "email":
        headers = raw_item.get("headers") or {}
        message_id = raw_item.get("message_id") or headers.get("Message-ID") or ""
        native_id = message_id
        title = raw_item.get("subject") or headers.get("Subject") or ""
        body = _strip_html(raw_item.get("body") or raw_item.get("text") or "")
        severity = _email_severity(raw_item)
        created_at = raw_item.get("date") or headers.get("Date") or _now_iso()
        source_ref = {
            "message_id": message_id,
            "from": raw_item.get("from") or headers.get("From"),
            "in_reply_to": raw_item.get("in_reply_to")
            or headers.get("In-Reply-To"),
        }
        url = None  # email has no URL (dossier §2)

    else:  # unreachable: _identity already validated the source above
        raise ValueError("unsupported source %r" % src)

    return {
        "source": src,
        "id": "%s:%s" % (src, native_id),
        "title": title,
        "body": body,
        "priority_signal": {
            "severity": severity,
            "age_seconds": _age_seconds(created_at, now),
            "source_priority": _source_priority(src, cfg),
        },
        "links": {"source_ref": source_ref, "url": url},
        "created_at": _iso_or_now(created_at),
    }


def _slack_ts_to_iso(ts):
    """A Slack ts is an epoch-seconds float string ("1700000000.000100"). Convert
    to ISO-8601 UTC; an unparseable ts -> now."""
    try:
        epoch = float(str(ts).split(".")[0])
    except (TypeError, ValueError):
        return _now_iso()
    return (
        datetime.datetime.fromtimestamp(epoch, datetime.timezone.utc)
        .replace(microsecond=0)
        .isoformat()
    )


def _epoch_to_iso(value):
    """A cp_issue_synth proposal's created_ts is epoch seconds (float, time.time()).
    Convert to a second-precision ISO-8601 UTC string; a missing/unparseable ts ->
    now (the schema's created_at is always a valid ISO string)."""
    try:
        epoch = float(value)
    except (TypeError, ValueError):
        return _now_iso()
    return (
        datetime.datetime.fromtimestamp(epoch, datetime.timezone.utc)
        .replace(microsecond=0)
        .isoformat()
    )


def _iso_or_now(value):
    """Echo `value` if it parses as ISO-8601, else the current time (the schema's
    created_at is always a valid ISO string)."""
    return value if _parse_iso(value) is not None else _now_iso()


# ── prioritization (dossier §3) ───────────────────────────────────────────────


def _weights(cfg):
    """Merge config weights over the defaults (an absent key keeps its default)."""
    w = dict(DEFAULT_WEIGHTS)
    cfg_w = ((cfg or {}).get("prioritization") or {}).get("weights") or {}
    for k in ("severity", "age", "source"):
        if k in cfg_w:
            try:
                w[k] = float(cfg_w[k])
            except (TypeError, ValueError):
                w[k] = DEFAULT_WEIGHTS[k]
    return w


def _normalized_age(age_seconds, max_age):
    """Age scaled to [0,1] against the queue's oldest issue, so age is comparable
    across very different absolute ages. max_age==0 -> 0 (all issues same age)."""
    if max_age <= 0:
        return 0.0
    return min(1.0, age_seconds / max_age)


def score(issue, weights, max_age):
    """The pick-order score (dossier §3):
      score = w_sev*severity_rank + w_age*normalized_age + w_src*source_priority
    Higher is picked first. Pure function of the issue + the weights + the queue's
    oldest age (for age normalization)."""
    ps = issue.get("priority_signal") or {}
    sev_rank = SEVERITY_RANK.get(ps.get("severity"), 0)
    nage = _normalized_age(_to_int_seconds(ps.get("age_seconds")), max_age)
    src_prio = _to_int(ps.get("source_priority"))
    return (
        weights["severity"] * sev_rank
        + weights["age"] * nage
        + weights["source"] * src_prio
    )


def pick_order(issues, cfg=None):
    """Return `issues` sorted by descending score, ties broken by ascending id for
    determinism (dossier §3). `issues` is a list of normalized issue dicts."""
    cfg = cfg or {}
    weights = _weights(cfg)
    max_age = max(
        (_to_int_seconds((i.get("priority_signal") or {}).get("age_seconds"))
         for i in issues),
        default=0,
    )
    return sorted(
        issues,
        key=lambda i: (-score(i, weights, max_age), i.get("id", "")),
    )


# ── the queue store (atomic JSON, bucketed) ───────────────────────────────────


def _empty_store():
    return {
        "schema_version": SCHEMA_VERSION,
        "issues": {},
        "in_flight": {},
        "resolved": {},
        "flagged": {},
    }


class IssueQueue:
    """The persistent issue store. Buckets (dossier §3):
      issues    — { id: <normalized issue> }   (the queued pool; dedup by id)
      in_flight — { id: { since, state, pr } } (claimed; out of the pick set)
      resolved  — { id: { pr, merged, at } }   (PR'd / done; out of the pick set)
      flagged   — { id: { reason, evidence_ref, at } } (gate-failed/out-of-scope)

    An id appears in AT MOST one of {in_flight, resolved, flagged} at a time; the
    issue payload always stays in `issues` so writeback can read links.source_ref.
    Persisted atomically (.tmp -> os.replace, sorted keys)."""

    def __init__(self, path=None, repo=None):
        self.path = path or queue_path(repo)
        self.data = self._load()

    # -- persistence -----------------------------------------------------------

    def _load(self):
        try:
            with open(self.path, "r", encoding="utf-8") as fh:
                data = json.load(fh)
        except (FileNotFoundError, ValueError, OSError):
            return _empty_store()
        if not isinstance(data, dict):
            return _empty_store()
        # heal a partially-shaped store (missing bucket -> empty) without losing data
        base = _empty_store()
        for k in base:
            if k != "schema_version" and not isinstance(data.get(k), dict):
                data[k] = {}
        data.setdefault("schema_version", SCHEMA_VERSION)
        return data

    def save(self):
        """Atomic write: temp file in the same dir, fsync, os.replace. Sorted keys
        so the on-disk form is stable/diffable (persona_store discipline)."""
        os.makedirs(os.path.dirname(self.path), exist_ok=True)
        tmp = self.path + ".tmp"
        with open(tmp, "w", encoding="utf-8") as fh:
            json.dump(self.data, fh, indent=2, sort_keys=True)
            fh.write("\n")
            fh.flush()
            os.fsync(fh.fileno())
        os.replace(tmp, self.path)

    # -- claim-state queries ---------------------------------------------------

    def _claimed(self, issue_id):
        """True if the id sits in any bucket that removes it from the pick set."""
        return any(issue_id in self.data[b] for b in _CLAIMED_BUCKETS)

    def state_of(self, issue_id):
        """The lifecycle state of an id: the in_flight machine-state, 'resolved',
        'flagged', 'queued' (in `issues`, unclaimed), or None (unknown id)."""
        if issue_id in self.data["in_flight"]:
            return self.data["in_flight"][issue_id].get("state", PICKED)
        if issue_id in self.data["resolved"]:
            return "resolved"
        if issue_id in self.data["flagged"]:
            return "flagged"
        if issue_id in self.data["issues"]:
            return STATE_QUEUED
        return None

    # -- ingest (idempotent dedup by id) --------------------------------------

    def ingest(self, issue):
        """Add a normalized issue. Idempotent: an id ALREADY known in ANY bucket is
        NOT re-queued (re-ingest of a known id is a no-op — dossier §3). Returns
        True if newly added, False if it was already known."""
        issue_id = issue["id"]
        if issue_id in self.data["issues"] or self._claimed(issue_id):
            return False
        self.data["issues"][issue_id] = issue
        return True

    def ingest_many(self, issues):
        """Ingest a batch; returns the count of NEWLY added issues."""
        return sum(1 for i in issues if self.ingest(i))

    # -- pick (prioritized + claim-before-work) -------------------------------

    def _queued(self):
        """The pick set: issues in `issues` and NOT in any claim bucket."""
        return [
            iss
            for iid, iss in self.data["issues"].items()
            if not self._claimed(iid)
        ]

    def pick(self, cfg=None, now=None):
        """Claim the highest-priority QUEUED issue, atomically moving it into
        in_flight BEFORE returning it (claim-before-work — the no-double-work
        guard, dossier §3). A second pick() on the same store returns the NEXT
        issue, never the one already claimed. Returns the claimed issue dict, or
        None when nothing is pickable. Persists the claim immediately."""
        queued = self._queued()
        if not queued:
            return None
        chosen = pick_order(queued, cfg)[0]
        since = (
            now.replace(microsecond=0).isoformat() if now is not None else _now_iso()
        )
        self.data["in_flight"][chosen["id"]] = {
            "since": since,
            "state": PICKED,
            "pr": None,
        }
        self.save()
        return chosen

    # -- state transitions (the loop drives these) ----------------------------

    def set_state(self, issue_id, state, pr=None):
        """Advance an in_flight issue's machine-state (dossier §4). Only valid for
        an id already in_flight. Returns the updated in_flight record."""
        rec = self.data["in_flight"].get(issue_id)
        if rec is None:
            raise KeyError(
                "cannot set state of %r — it is not in_flight (state=%r)"
                % (issue_id, self.state_of(issue_id))
            )
        rec["state"] = state
        if pr is not None:
            rec["pr"] = pr
        self.save()
        return rec

    def mark_resolved(self, issue_id, pr, merged=True, at=None):
        """Move an id from in_flight to resolved (PR'd / merged). Stays OUT of the
        pick set permanently. Returns the resolved record."""
        self.data["in_flight"].pop(issue_id, None)
        rec = {"pr": pr, "merged": bool(merged), "at": at or _now_iso()}
        self.data["resolved"][issue_id] = rec
        self.save()
        return rec

    def flag(self, issue_id, reason, evidence_ref=None, at=None):
        """Move an id from in_flight to flagged (gate-failed / out-of-scope). Stays
        OUT of the pick set (never re-picked — dossier §3/§5). Returns the record."""
        self.data["in_flight"].pop(issue_id, None)
        rec = {
            "reason": reason,
            "evidence_ref": evidence_ref,
            "at": at or _now_iso(),
        }
        self.data["flagged"][issue_id] = rec
        self.save()
        return rec

    def release(self, issue_id):
        """Return an in_flight id to the QUEUED pool (re-pickable) — the honest
        ERRORED-but-retryable path (dossier §4). No-op if not in_flight. Returns
        True if released."""
        if issue_id in self.data["in_flight"]:
            self.data["in_flight"].pop(issue_id, None)
            self.save()
            return True
        return False

    # -- listing / status ------------------------------------------------------

    def list_issues(self, cfg=None, state=None):
        """All known issues with their current state, in pick order for the queued
        ones (claimed ones appended after). `state` optionally filters to one of
        queued|in_flight|resolved|flagged."""
        rows = []
        queued = pick_order(self._queued(), cfg)
        for iss in queued:
            rows.append({"id": iss["id"], "state": STATE_QUEUED, "issue": iss})
        for iid, iss in self.data["issues"].items():
            if self._claimed(iid):
                rows.append({"id": iid, "state": self.state_of(iid), "issue": iss})
        if state is not None:
            rows = [r for r in rows if r["state"] == state]
        return rows

    def status(self):
        """Counts per bucket — the at-a-glance store summary."""
        return {
            "schema_version": self.data.get("schema_version", SCHEMA_VERSION),
            "path": self.path,
            "queued": len(self._queued()),
            "in_flight": len(self.data["in_flight"]),
            "resolved": len(self.data["resolved"]),
            "flagged": len(self.data["flagged"]),
            "total": len(self.data["issues"]),
        }


# ── CLI core (driven by bin/heimdall-issue-queue) ─────────────────────────────


def _read_json_arg(value):
    """A JSON CLI arg is either inline JSON or @path-to-file."""
    if value.startswith("@"):
        with open(value[1:], "r", encoding="utf-8") as fh:
            return json.load(fh)
    return json.loads(value)


def _load_cfg(cfg_arg):
    """Load the config dict from a @file/inline-JSON arg, or {} when absent."""
    if not cfg_arg:
        return {}
    return _read_json_arg(cfg_arg)


def _cli(argv):
    """CLI core. Subcommands:
      normalize --source S --raw @file|JSON [--config C] [--now ISO]
      ingest    --source S --raw @file|JSON [--config C]
      list      [--config C] [--state S]
      pick      [--config C]
      status
      release   --id ID
    Returns an exit code; prints JSON to stdout, human notes to stderr."""
    import argparse

    p = argparse.ArgumentParser(prog="heimdall-issue-queue", add_help=True)
    p.add_argument("subcommand")
    p.add_argument("--source")
    p.add_argument("--raw")
    p.add_argument("--config")
    p.add_argument("--state")
    p.add_argument("--id")
    p.add_argument("--now")
    p.add_argument("--repo")
    args = p.parse_args(argv)

    sub = args.subcommand
    cfg = _load_cfg(args.config)
    now = _parse_iso(args.now) if args.now else None

    if sub == "normalize":
        if not args.source or args.raw is None:
            print("error: normalize needs --source and --raw")
            return 2
        raw = _read_json_arg(args.raw)
        issue = normalize(args.source, raw, cfg, now=now)
        print(json.dumps(issue, indent=2, sort_keys=True))
        return 0

    q = IssueQueue(repo=args.repo)

    if sub == "ingest":
        if not args.source or args.raw is None:
            print("error: ingest needs --source and --raw")
            return 2
        raw = _read_json_arg(args.raw)
        items = raw if isinstance(raw, list) else [raw]
        issues = [normalize(args.source, r, cfg, now=now) for r in items]
        added = q.ingest_many(issues)
        q.save()
        print(json.dumps({"ingested": added, "submitted": len(issues)}, indent=2))
        return 0

    if sub == "list":
        rows = q.list_issues(cfg, state=args.state)
        print(json.dumps(rows, indent=2, sort_keys=True))
        return 0

    if sub == "pick":
        chosen = q.pick(cfg, now=now)
        if chosen is None:
            print(json.dumps({"picked": None}, indent=2))
            return 0
        print(json.dumps({"picked": chosen}, indent=2, sort_keys=True))
        return 0

    if sub == "status":
        print(json.dumps(q.status(), indent=2, sort_keys=True))
        return 0

    if sub == "release":
        if not args.id:
            print("error: release needs --id")
            return 2
        released = q.release(args.id)
        print(json.dumps({"released": released, "id": args.id}, indent=2))
        return 0

    print("error: unknown subcommand: %s" % sub)
    return 2


if __name__ == "__main__":
    import sys

    sys.exit(_cli(sys.argv[1:]))
