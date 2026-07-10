#!/usr/bin/env python3
# checkpoint_share.py — the Shared Team Checkpoints (TEAM MODE P4) SCRUB + STORE engine.
#
# WHAT THIS IS. The engine behind `bin/heimdall-checkpoint-share`. A teammate's session
# publishes ONE git-committed, per-HAID record at .planning/ledger/checkpoints/{slug}.json —
# the additive P4 sibling of the P1 activity / P2 verdicts / P3 collision stores. One writer
# per file → conflict-free git merges (INV-E). Every teammate holds the full checkpoints/ dir
# after a `git pull`, so a dropped teammate's last snapshot survives their machine loss with
# ZERO server dependency (the redundancy property). git IS the coordination substrate (TM-1).
#
# THE PRIVACY LINE IS ABSOLUTE — and it is REUSED, NOT REBUILT. The record is an ALLOWLIST
# (SHARED_FIELDS): a field not on the list is never shared, by construction. Every string
# field passes, in order (INVARIANTS.md section 6):
#   1. allowlist assembly (only SHARED_FIELDS emitted)
#   2. path strip (absolute machine paths -> repo-relative or [path-redacted])
#   3. telemetry._scrub / _SECRET_PATTERNS / _ASSIGNED_OPAQUE (no-secret-by-construction)
#   4. assert_zero_content (checkpoint-tuned no-free-form-body guard — INV-A)
#   5. the security classifier (issue_corpus._SECURITY_CLASSES) — a security-sensitive record
#      is EXCLUDED from the shared roster (INV-C), routed to the local-only security lane
#   6. secret_scan (telemetry vocab + gitleaks belt) fail-closed — a finding aborts the write
#
# The SECURITY-SIGNALS lane (.planning/security-signals/) stays broadly gitignored and is
# NEVER un-ignored — a security incident stays local, enforced by the ABSENCE of a re-include
# line, backed by this emit-time classifier.
#
# CONSENT is the presence consent gate, reused verbatim: <repo>/.heimdall/presence.json
# {"enabled": false} (or the global ~/.heimdall/presence-off marker) => publish writes NOTHING
# (INV-D), a hard no-op a hook/cron cannot leak around.
#
# stdlib-only. IMPORTS the telemetry / corpus gate modules — never EDITS them (they stay
# byte-for-byte green). House style: a thin bash CLI (bin/heimdall-checkpoint-share) over this
# engine; runtime planning home resolved the same way heimdall-claim resolves it.

from __future__ import annotations

import json
import os
import re
import sys

_HERE = os.path.dirname(os.path.abspath(__file__))
if _HERE not in sys.path:
    sys.path.insert(0, _HERE)

# REUSE the general telemetry secret vocabulary + the corpus zero-content traversal and the
# approved security taxonomy — never re-derive them (INVARIANTS.md section 6).
import telemetry as _tel          # noqa: E402 — _scrub / _SECRET_PATTERNS / _ASSIGNED_OPAQUE
import pmr_corpus                  # noqa: E402 — _leaf_strings / secret_scan_payload
import issue_corpus               # noqa: E402 — _SECURITY_CLASSES (the taxonomy)

# ── schema + policy constants ─────────────────────────────────────────────────

SCHEMA = "team_checkpoint_v1"

# The ONLY keys a shared record ever carries (INVARIANTS.md section 1). A field not here is not
# shared, by construction — the allowlist IS the boundary.
SHARED_FIELDS = (
    "haid", "human", "branch", "head_sha", "phase", "progress_pct",
    "active_goal", "claimed_surfaces", "task_ref", "updated_at", "resumable",
)

# The security taxonomy, reused (not re-derived) from the approved issue-corpus set. A record
# whose coded fields match any of these is security-sensitive -> excluded from the shared roster
# (INV-C) and routed to the local-only lane.
_SECURITY_CLASSES = frozenset(issue_corpus._SECURITY_CLASSES)  # noqa: SLF001 — intentional reuse

# Byte cap for the prose fields (active_goal/task_ref): a full sentence is allowed, but a value
# over this is a body, not a tag — assert_zero_content (INV-A) rejects it rather than truncating
# (a truncated secret still leaks). Coded tokens are bounded by telemetry._scrub (its 120 cap).
_GOAL_MAX = 240

PATH_REDACTED = "[path-redacted]"

# An absolute machine path shape (unix abs / home / windows drive). Detected in prose fields so
# it can be stripped to repo-relative or redacted (INV-A / section 2). A leading repo-relative
# segment like "bin/lib/x.py" is NOT absolute and survives.
_RX_ABSPATH = re.compile(
    r"(?:(?<=^)|(?<=[\s\"'=(:]))"          # at start or after a boundary char
    r"(?:/[A-Za-z0-9._][^\s\"']*"          # /Users/... , /home/... , /tmp/...
    r"|~/[^\s\"']*"                        # ~/...
    r"|[A-Za-z]:\\[^\s\"']*)"              # C:\...
)

# A relative surface glob is the ONLY field allowed a path separator. Permit the glob/symbol
# vocabulary heimdall-claim uses (globs + "file#symbol"); reject anything absolute or shell-meta.
_RX_SURFACE_OK = re.compile(r"^[A-Za-z0-9._][A-Za-z0-9._/*#\-]*$")


# ── runtime planning home (mirrors bin/heimdall-claim resolution) ─────────────


def _git_root(start=None):
    """The git repo root of `start` (or cwd), else `start`/cwd. Only ever used to locate the
    tracked .planning ledger + the local .heimdall consent state — never emitted."""
    start = os.path.abspath(start or os.getcwd())
    cur = start
    while True:
        if os.path.isdir(os.path.join(cur, ".git")) or os.path.isfile(os.path.join(cur, ".git")):
            return cur
        parent = os.path.dirname(cur)
        if parent == cur:
            return start
        cur = parent


def planning_dir(repo_root=None):
    """${HEIMDALL_PLANNING_DIR:-<repo>/.planning} — the SAME resolution heimdall-claim uses so
    the checkpoint store is a sibling of claims/ under the one ledger. Resolved every call (no
    caching) so a subprocess test that pins the env sees its own dir."""
    explicit = os.environ.get("HEIMDALL_PLANNING_DIR")
    if explicit:
        return explicit
    return os.path.join(_git_root(repo_root), ".planning")


def ledger_dir(repo_root=None):
    return os.path.join(planning_dir(repo_root), "ledger")


def checkpoints_dir(repo_root=None):
    """.planning/ledger/checkpoints — the P4 store, one file per HAID (INV-E)."""
    return os.path.join(ledger_dir(repo_root), "checkpoints")


def claims_dir(repo_root=None):
    return os.path.join(ledger_dir(repo_root), "claims")


def decisions_file(repo_root=None):
    return os.path.join(ledger_dir(repo_root), "decisions.md")


def security_lane_dir(repo_root=None):
    """The PRIVATE local-only lane (broadly gitignored, NEVER un-ignored). A security-sensitive
    checkpoint routes here, never to the shared store."""
    return os.path.join(planning_dir(repo_root), "security-signals")


def haid_slug(haid):
    """Filesystem-safe slug for a HAID (the '/' in spawn HAIDs is illegal in a filename).
    Matches bin/heimdall-claim's `tr '/:' '__'` exactly, so a HAID's checkpoint file sits
    beside its claim file with the same stem -> the two stores align."""
    return re.sub(r"[/:]", "_", str(haid))


def checkpoint_path(haid, repo_root=None):
    return os.path.join(checkpoints_dir(repo_root), haid_slug(haid) + ".json")


def haid_human(haid):
    """The public handle embedded in a HAID (haid:<human>.<host>-<n> -> <human>)."""
    m = re.match(r"^haid:([a-z0-9-]+)\.", str(haid))
    return m.group(1) if m else str(haid)


# ── consent (the presence consent gate, reused verbatim — INV-D) ──────────────


def _presence_state_dir(repo_root=None):
    """Mirror bin/heimdall-presence `_pres_state_dir`: HEIMDALL_PRESENCE_DIR, else
    <git-root>/.heimdall (a dev's opt-out must never commit into a teammate's repo)."""
    d = os.environ.get("HEIMDALL_PRESENCE_DIR")
    if d:
        return d
    return os.path.join(_git_root(repo_root), ".heimdall")


def share_enabled(repo_root=None):
    """True unless presence/sharing is turned OFF (INV-D), mirroring the presence toggle:
      * global: ~/.heimdall/presence-off EXISTS => off.
      * per-repo: <state-dir>/presence.json {"enabled": false} => off.
    Default ON. Consent OFF is a hard no-op the publish path cannot leak around. Never raises."""
    home = os.environ.get("HOME")
    if home and os.path.exists(os.path.join(home, ".heimdall", "presence-off")):
        return False
    state = os.path.join(_presence_state_dir(repo_root), "presence.json")
    try:
        with open(state, "r", encoding="utf-8") as fh:
            raw = fh.read()
    except OSError:
        return True
    # A tolerant match of {"enabled": false} identical in spirit to the bash regex.
    if re.search(r'"enabled"\s*:\s*false', raw):
        return False
    return True


# ── scrub primitives (steps 2/3 of section 6) ─────────────────────────────────


def _rel_or_redact(match, repo_root):
    """Rewrite an absolute path to repo-relative when it lives under the repo root, else redact.
    Never leaks a machine path (INV-A / section 2)."""
    p = match.group(0)
    try:
        root = os.path.abspath(_git_root(repo_root))
        ap = os.path.abspath(os.path.expanduser(p))
    except (OSError, ValueError):
        return PATH_REDACTED
    if ap == root or ap.startswith(root + os.sep):
        rel = os.path.relpath(ap, root)
        if not rel.startswith(".."):   # never escape the root
            return rel
    return PATH_REDACTED


def _strip_paths(value, repo_root):
    """Replace every absolute-path run in a string with its repo-relative form or a redaction
    marker. Applied to the prose fields (active_goal/task_ref) — surfaces are validated
    separately and are relative by contract."""
    if not isinstance(value, str):
        return value
    return _RX_ABSPATH.sub(lambda m: _rel_or_redact(m, repo_root), value)


def _scrub_token(value):
    """A short coded token (haid/human/branch/head_sha/phase). Bounded + secret-rejected via
    telemetry._scrub. A rejected value (secret shape / over-bound) -> None so the field drops."""
    if value is None:
        return None
    return _tel._scrub(str(value))  # noqa: SLF001 — intentional reuse of the secret gate


def _scrub_prose(value, repo_root):
    """A prose field (active_goal / task_ref): single-line-ified (a fenced diff spans lines — we
    never carry a body) and absolute paths stripped. Multi-word prose is legitimate here (unlike
    a coded token) so we do NOT reject on word count. A secret shape is deliberately LEFT IN
    PLACE here — the fail-closed `secret_scan` (section 6 step 6) is the SINGLE authority that
    aborts the write on any finding, so a planted PAT must survive scrub to reach it (INV-B: the
    write ABORTS, it is never silently scrubbed-and-served). An over-cap value is a body, not a
    tag; it is NOT truncated (a truncated secret still leaks) but left for assert_zero_content
    (INV-A) to reject as a body. Returns the cleaned string, or None only for a None input."""
    if value is None:
        return None
    s = str(value).replace("\r", " ").replace("\n", " ").strip()
    return _strip_paths(s, repo_root)


def _scrub_surface(value, repo_root):
    """A claimed surface: a repo-relative glob or 'file#symbol' ref (already public in claims/).
    Absolute paths are stripped first; anything not matching the relative-glob vocabulary is
    DROPPED (returns None) rather than shipped. Never carries a machine path."""
    if value is None:
        return None
    s = _strip_paths(str(value).strip(), repo_root)
    if not s or s == PATH_REDACTED:
        return None
    return s if _RX_SURFACE_OK.match(s) else None


# ── the security classifier (section 5 / INV-C) ───────────────────────────────


def is_security_sensitive(record_or_inputs):
    """True iff the checkpoint must be EXCLUDED from the shared roster and routed local-only
    (INV-C). Security-sensitive when ANY of:
      1. a coded field (phase / task_ref) is exactly a security class;
      2. the active_goal / task_ref / phase text contains a security-class WORD;
      3. an explicit incident marker (`incident: true` / marker == 'incident').
    Reuses the approved _SECURITY_CLASSES taxonomy — never a new vocabulary."""
    r = record_or_inputs or {}
    if r.get("incident") is True or str(r.get("marker") or "").strip().lower() == "incident":
        return True
    for key in ("phase", "task_ref"):
        if str(r.get(key) or "").strip().lower() in _SECURITY_CLASSES:
            return True
    for key in ("active_goal", "task_ref", "phase"):
        words = re.findall(r"[a-z]+", str(r.get(key) or "").lower())
        if any(w in _SECURITY_CLASSES for w in words):
            return True
    return False


# ── the no-free-form-body guard (section 4 / INV-A) ───────────────────────────

# The leak shapes a checkpoint must NEVER carry. Unlike the PMR zero-content record, prose goals
# and relative surface globs ARE legitimate here — so this rejects a diff/body/path, NOT prose:
#   * a newline (a fenced diff spans lines),
#   * an over-cap value (a body, not a tag),
#   * an absolute machine path (INV-A / section 2).
def _violates_zero_content(field, value):
    if "\n" in value or "\r" in value:
        return "newline-body"
    if len(value) > _GOAL_MAX:
        return "over-length-body"
    if _RX_ABSPATH.search(value):
        return "absolute-path"
    return None


def assert_zero_content(record):
    """Scan EVERY string leaf of the assembled record for a free-form body/diff/path (INV-A).
    Reuses pmr_corpus._leaf_strings for the traversal (never re-derived). Returns
    (ok, violations); a violation names the field + a CODE only — never the offending value
    (it could be the very content we are refusing to ship). ok=False => BLOCK the write."""
    violations = []
    for field, value in pmr_corpus._leaf_strings(record):  # noqa: SLF001 — intentional reuse
        code = _violates_zero_content(field, value)
        if code is not None:
            violations.append({"field": field, "code": code})
    return (len(violations) == 0, violations)


def secret_scan(record):
    """Fail-closed secret gate over the assembled record (section 6 step 6). Reuses
    pmr_corpus.secret_scan_payload (telemetry high-signal vocab + gitleaks belt when present).
    Returns (clean, findings) — findings are pattern LABELS only, never the matched bytes."""
    return pmr_corpus.secret_scan_payload(record)


# ── the record builder (PURE — the allowlist projection) ──────────────────────


def _clamp_pct(value):
    try:
        n = int(value)
    except (TypeError, ValueError):
        return 0
    return max(0, min(100, n))


def build_record(inputs, repo_root=None, now=None):
    """Assemble ONE allowlisted, scrubbed shared record from raw inputs (PURE — no IO). Emits
    ONLY SHARED_FIELDS (+ schema/updated_at); every string field is path-stripped + secret-
    scrubbed. A field whose scrub rejects it (secret shape) is set to "[dropped]" so the record
    still assembles but carries no secret — the publish path's secret_scan is the fail-closed
    belt that aborts the whole write on any finding. Returns the record dict."""
    inputs = inputs or {}
    rr = repo_root
    haid = str(inputs.get("haid") or "haid:unknown")
    human = _scrub_token(inputs.get("human") or haid_human(haid)) or haid_human(haid)
    branch = _scrub_token(inputs.get("branch") or "unknown") or "unknown"
    head_sha = _scrub_token(inputs.get("head_sha") or "none") or "none"
    phase = _scrub_token(inputs.get("phase") or "unknown") or "unknown"
    goal = _scrub_prose(inputs.get("active_goal"), rr)
    task = _scrub_prose(inputs.get("task_ref"), rr)
    surfaces = []
    for s in inputs.get("claimed_surfaces") or []:
        cleaned = _scrub_surface(s, rr)
        if cleaned is not None:
            surfaces.append(cleaned)
    rec = {
        "schema": SCHEMA,
        "haid": haid,
        "human": human,
        "branch": branch,
        "head_sha": head_sha,
        "phase": phase,
        "progress_pct": _clamp_pct(inputs.get("progress_pct", 0)),
        "active_goal": goal if goal is not None else "[dropped]",
        "claimed_surfaces": sorted(surfaces),
        "task_ref": task if task is not None else "[dropped]",
        "updated_at": now or _now_iso(),
        "resumable": bool(inputs.get("resumable", bool(head_sha and head_sha != "none"))),
    }
    return rec


def _now_iso():
    import datetime
    return (
        datetime.datetime.now(datetime.timezone.utc)
        .replace(microsecond=0)
        .isoformat()
        .replace("+00:00", "Z")
    )


# ── the roster projection (the comparable partition unit — INV-G) ─────────────


def roster_row(rec):
    """Project a shared record to its canonical roster row (the differential unit). Keyed by
    HAID; carries the scrubbed fields the roster displays. A stable, sorted, str/int-leaf row so
    the impl fold and the independent reference fold are byte-comparable."""
    return [
        str(rec.get("haid", "")),
        str(rec.get("human", "")),
        str(rec.get("branch", "")),
        str(rec.get("head_sha", "")),
        str(rec.get("phase", "")),
        _clamp_pct(rec.get("progress_pct", 0)),
        str(rec.get("active_goal", "")),
        str(rec.get("task_ref", "")),
        json.dumps(sorted(str(s) for s in rec.get("claimed_surfaces", [])), sort_keys=True),
        bool(rec.get("resumable", False)),
    ]


def fold_stream(stream, repo_root=None):
    """Fold a STREAM of raw checkpoint inputs into the roster partition (the impl side of the
    differential — INV-G). For each raw input, run the FULL publish gate in-memory:
      * consent OFF for that input (`share_consent: false`) => SKIP (INV-D);
      * security-sensitive => EXCLUDE + count (INV-C);
      * a secret-scan finding => DROP (INV-B);
      * an assert_zero_content violation => DROP (INV-A);
      * else build + emit the roster row.
    Returns {served: sorted rows, excluded_security: int, dropped: int}. PURE — no IO."""
    served = []
    excluded_security = 0
    dropped = 0
    for raw in stream or []:
        if raw.get("share_consent") is False:
            continue
        if is_security_sensitive(raw):
            excluded_security += 1
            continue
        rec = build_record(raw, repo_root=repo_root, now=raw.get("updated_at") or "t")
        zok, _ = assert_zero_content(rec)
        if not zok:
            dropped += 1
            continue
        clean, _ = secret_scan(rec)
        if not clean:
            dropped += 1
            continue
        served.append(roster_row(rec))
    return {
        "served": sorted(served, key=lambda r: r[0]),
        "excluded_security": excluded_security,
        "dropped": dropped,
    }


def roster_from_files(repo_root=None):
    """Fold the ON-DISK per-HAID checkpoint files into the roster partition. Read-only,
    tolerant: a bad file is skipped. This is what the CLI `roster` renders. `excluded_security`
    is 0 here — a sensitive record is never WRITTEN to the shared store (it lives in the local
    lane), so it is absent by construction, not counted."""
    served = []
    d = checkpoints_dir(repo_root)
    try:
        names = sorted(n for n in os.listdir(d) if n.endswith(".json"))
    except OSError:
        names = []
    for n in names:
        try:
            with open(os.path.join(d, n), "r", encoding="utf-8") as fh:
                rec = json.load(fh)
        except (OSError, ValueError):
            continue
        if isinstance(rec, dict) and rec.get("schema") == SCHEMA:
            served.append(roster_row(rec))
    return {"served": sorted(served, key=lambda r: r[0]), "excluded_security": 0, "dropped": 0}


# ── atomic write ──────────────────────────────────────────────────────────────


def _atomic_write_json(path, obj):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = path + ".tmp-%d" % os.getpid()
    with open(tmp, "w", encoding="utf-8") as fh:
        json.dump(obj, fh, sort_keys=True, indent=2)
        fh.write("\n")
        fh.flush()
    os.replace(tmp, path)


# ── the publish path: consent -> build -> guard -> scan -> route/write (sec 6) ─


def publish(inputs, repo_root=None, now=None):
    """Publish ONE shared checkpoint. The full gate (INVARIANTS.md section 6 / section 3):
      1. consent OFF => pure no-op, ZERO bytes written (INV-D), returns published=False.
      2. security-sensitive => route to the LOCAL-ONLY security lane, NOT the shared store
         (INV-C) — never counted as published.
      3. build_record — the allowlisted, path-stripped, secret-scrubbed projection.
      4. assert_zero_content (INV-A) — a free-form body/diff/path => BLOCK, nothing written.
      5. secret_scan (INV-B) — a secret shape => BLOCK fail-closed, nothing written.
      6. atomic write to .planning/ledger/checkpoints/{slug}.json (one writer per file — INV-E).
    Returns a status dict — never raises into the caller (a publish fault must not fail a run)."""
    try:
        if not share_enabled(repo_root):
            return {"published": False, "reason": "consent-off"}

        haid = str((inputs or {}).get("haid") or "haid:unknown")

        if is_security_sensitive(inputs):
            rec = build_record(inputs, repo_root=repo_root, now=now)
            # the private lane is still guarded fail-closed so even it can never persist a leak.
            zok, violations = assert_zero_content(rec)
            clean, findings = secret_scan(rec)
            if not (zok and clean):
                return {"published": False, "reason": "security-blocked",
                        "violations": violations, "findings": findings}
            path = os.path.join(security_lane_dir(repo_root), haid_slug(haid) + ".json")
            _atomic_write_json(path, rec)
            return {"published": False, "reason": "security-sensitive-private",
                    "private": True, "lane_path": path, "haid": haid}

        rec = build_record(inputs, repo_root=repo_root, now=now)

        zok, violations = assert_zero_content(rec)
        if not zok:
            return {"published": False, "reason": "zero-content-blocked",
                    "violations": violations}

        clean, findings = secret_scan(rec)
        if not clean:
            return {"published": False, "reason": "secret-detected-blocked",
                    "findings": findings}

        path = checkpoint_path(haid, repo_root)
        _atomic_write_json(path, rec)
        return {"published": True, "haid": haid, "path": path,
                "resumable": rec["resumable"]}
    except Exception as exc:  # noqa: BLE001 — a publish fault never fails the caller
        return {"published": False, "reason": "error", "detail": str(exc)[:120]}


def read_checkpoint(haid, repo_root=None):
    """Read one teammate's shared checkpoint (read-only, tolerant). Returns the record dict or
    None."""
    try:
        with open(checkpoint_path(haid, repo_root), "r", encoding="utf-8") as fh:
            rec = json.load(fh)
        return rec if isinstance(rec, dict) else None
    except (OSError, ValueError):
        return None


def all_checkpoints(repo_root=None):
    """Every shared checkpoint record on disk, keyed by HAID (read-only, tolerant)."""
    out = {}
    d = checkpoints_dir(repo_root)
    try:
        names = sorted(n for n in os.listdir(d) if n.endswith(".json"))
    except OSError:
        return out
    for n in names:
        try:
            with open(os.path.join(d, n), "r", encoding="utf-8") as fh:
                rec = json.load(fh)
        except (OSError, ValueError):
            continue
        if isinstance(rec, dict) and rec.get("haid"):
            out[rec["haid"]] = rec
    return out


# ── the no-rewrite / no-redo guard (the core redundancy guarantee — section 4) ─


def _surface_file(surface):
    return str(surface).split("#", 1)[0]


def _glob_prefix(g):
    if g.endswith("/**"):
        return g[:-3]
    if g == "**":
        return ""
    if "*" in g:
        return g.rsplit("/", 1)[0] if "/" in g else ""
    return g


def _surfaces_overlap(a, b):
    """Whether two surface refs collide (mirrors heimdall-claim's file-prefix nesting). Two
    surfaces overlap when their file parts are equal or one directory-prefix nests the other.
    A 'file#symbol' ref collides on the same file only when the symbols match (or either side
    claims the whole file / a glob over it)."""
    fa, fb = _surface_file(a), _surface_file(b)
    pa, pb = _glob_prefix(fa), _glob_prefix(fb)
    files = False
    if fa == fb:
        files = True
    elif pa == "" or pb == "":
        files = True
    elif fb == pa or fb.startswith(pa + "/") or fa == pb or fa.startswith(pb + "/") \
            or pb == pa or pb.startswith(pa + "/") or pa.startswith(pb + "/"):
        files = True
    if not files:
        return False
    sa = a.split("#", 1)[1] if "#" in str(a) else ""
    sb = b.split("#", 1)[1] if "#" in str(b) else ""
    if sa and sb and fa == fb and "*" not in fa:
        return sa == sb
    return True


def _is_completed(rec):
    """A checkpoint marks completed work when progress is 100 OR the phase names a done/merged/
    complete state. Such surfaces must not be rewritten/redone by another teammate."""
    try:
        pct = int(rec.get("progress_pct", 0))
    except (TypeError, ValueError):
        pct = 0
    if pct >= 100:
        return True
    phase = str(rec.get("phase") or "").lower()
    return bool(re.search(r"\b(done|complete|completed|merged|shipped|landed)\b", phase))


def precheck_surfaces(surfaces, my_haid, repo_root=None):
    """The NO-REWRITE / NO-REDO guard (the core redundancy guarantee — INVARIANTS.md section 4).
    Before an hmd starts work on a surface, read teammates' SHARED CHECKPOINTS and refuse to
    rewrite/redo a surface another teammate has COMPLETED (their checkpoint at progress 100 / a
    done phase covering that surface). This EXTENDS the heimdall-claim active-claim no-stomp
    guarantee across shared state: a claim covers live work, a checkpoint covers recently-
    completed work.

    Returns (ok, collisions): ok=False when any requested surface overlaps a DIFFERENT teammate's
    completed checkpoint surface. Each collision names the holder + why. The CLI also runs
    `heimdall-claim check` for the ACTIVE-claim half; this covers the COMPLETED half."""
    collisions = []
    for haid, rec in all_checkpoints(repo_root).items():
        if haid == my_haid:
            continue
        if not _is_completed(rec):
            continue
        held = rec.get("claimed_surfaces") or []
        for req in surfaces:
            for h in held:
                if _surfaces_overlap(req, h):
                    collisions.append({
                        "requested": req, "overlaps": h, "holder": haid,
                        "human": rec.get("human"), "phase": rec.get("phase"),
                        "progress_pct": rec.get("progress_pct"),
                        "reason": "completed-by-teammate",
                    })
    return (len(collisions) == 0, collisions)
