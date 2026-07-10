#!/usr/bin/env python3
# reference.py — the INDEPENDENT reference fold for the team-checkpoint differential oracle.
#
# INDEPENDENCE (differential integrity). This module imports NOTHING from bin/lib/* — every
# constant and rule below is HAND-REPRODUCED from evals/oracles/team-checkpoint/INVARIANTS.md,
# so it shares no code path with the implementation under test (bin/lib/checkpoint_share.py).
# The impl author and this reference author are disjoint; differential.py (the neutral gate
# wiring) imports BOTH and diffs them, so oracle independence holds by construction. An
# acceptance grep enforces `! grep -q 'checkpoint_share' reference.py`.
#
# WHAT IT COMPUTES. The SAME roster partition the impl fold produces, recomputed from first
# principles over a stream of raw checkpoint inputs:
#   {"served": sorted list of roster rows, "excluded_security": int}
# per the pipeline in INVARIANTS.md section 3/6:
#   consent OFF for a record            -> SKIP           (INV-D)
#   security-sensitive                  -> EXCLUDE + count (INV-C)
#   a secret shape anywhere             -> DROP           (INV-B)
#   a free-form body/diff/abs-path      -> DROP           (INV-A)
#   else                                -> project the allowlisted, scrubbed roster row (INV-G)

from __future__ import annotations

import hashlib
import json
import re

# ── constants hand-copied from INVARIANTS.md (never imported) ─────────────────

# section 1 — the SHARED allowlist, in the roster-row order (INV-G).
_SHARED_FIELDS = (
    "haid", "human", "branch", "head_sha", "phase", "progress_pct",
    "active_goal", "claimed_surfaces", "task_ref", "updated_at", "resumable",
)

# section 5 — the approved security taxonomy.
_SECURITY_CLASSES = frozenset(
    {"auth", "crypto", "secret", "injection", "deanon", "isolation", "incident"})

# section 2 — the byte cap on a prose field; over this is a body, not a tag (INV-A).
_GOAL_MAX = 240
_TOKEN_MAX = 120

# INV-B — high-signal secret shapes (hand-copied families; a value matching any is dropped).
_SECRET_RX = (
    re.compile(r"ghp_[A-Za-z0-9]{36}"),
    re.compile(r"gh[oprsu]_[A-Za-z0-9]{36}"),
    re.compile(r"AKIA[0-9A-Z]{16}"),
    re.compile(r"sk_live_[A-Za-z0-9]{16,}"),
    re.compile(r"xox[baprs]-[A-Za-z0-9-]{10,}"),
    re.compile(r"-----BEGIN[ A-Z]*PRIVATE KEY-----"),
    re.compile(r"eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}"),
)
_ASSIGNED_RX = re.compile(
    r"(?:token|secret|password|passwd|pwd|api[_-]?key|apikey|access[_-]?key|auth|bearer|"
    r"credential|private[_-]?key)\s*[=:]\s*\S{16,}", re.I)

# section 2 — an absolute machine path shape (INV-A / path-strip).
_ABSPATH_RX = re.compile(
    r"(?:(?<=^)|(?<=[\s\"'=(:]))(?:/[A-Za-z0-9._][^\s\"']*|~/[^\s\"']*|[A-Za-z]:\\[^\s\"']*)")
_SURFACE_OK_RX = re.compile(r"^[A-Za-z0-9._][A-Za-z0-9._/*#\-]*$")

_PATH_REDACTED = "[path-redacted]"


# ── the scrub reproduction (INVARIANTS.md section 6, hand-authored) ───────────


def _has_secret(text):
    s = str(text)
    if _ASSIGNED_RX.search(s):
        return True
    return any(rx.search(s) for rx in _SECRET_RX)


def _redact_paths(text):
    """Replace every absolute-path run with [path-redacted]. The reference has no repo root, so
    (unlike the impl's repo-relative rewrite) EVERY absolute path is redacted — the golden
    stream carries none, so the two agree; a mutant that ships a raw machine path diverges."""
    return _ABSPATH_RX.sub(_PATH_REDACTED, str(text))


def _scrub_token(value, default):
    if value is None:
        return default
    s = str(value)
    if len(s) > _TOKEN_MAX or _has_secret(s):
        return default
    return s


def _scrub_prose(value):
    if value is None:
        return None
    s = str(value).replace("\r", " ").replace("\n", " ").strip()
    return _redact_paths(s)


def _scrub_surface(value):
    if value is None:
        return None
    s = _redact_paths(str(value).strip())
    if not s or s == _PATH_REDACTED:
        return None
    return s if _SURFACE_OK_RX.match(s) else None


def _clamp_pct(value):
    try:
        n = int(value)
    except (TypeError, ValueError):
        return 0
    return max(0, min(100, n))


def _haid_human(haid):
    m = re.match(r"^haid:([a-z0-9-]+)\.", str(haid))
    return m.group(1) if m else str(haid)


def is_security_sensitive(raw):
    """INV-C — a record is security-sensitive when a coded field is exactly a security class, a
    security-class WORD appears in the goal/task/phase text, or an explicit incident marker is
    set. Reproduces the taxonomy match independently."""
    r = raw or {}
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


def _build_row(raw):
    """Project a clean raw input to its allowlisted, scrubbed roster row (INV-G order)."""
    haid = str(raw.get("haid") or "haid:unknown")
    human = _scrub_token(raw.get("human") or _haid_human(haid), _haid_human(haid))
    branch = _scrub_token(raw.get("branch") or "unknown", "unknown")
    head_sha = _scrub_token(raw.get("head_sha") or "none", "none")
    phase = _scrub_token(raw.get("phase") or "unknown", "unknown")
    goal = _scrub_prose(raw.get("active_goal"))
    task = _scrub_prose(raw.get("task_ref"))
    surfaces = []
    for s in raw.get("claimed_surfaces") or []:
        cleaned = _scrub_surface(s)
        if cleaned is not None:
            surfaces.append(cleaned)
    resumable = bool(raw.get("resumable", bool(head_sha and head_sha != "none")))
    return [
        haid,
        human,
        branch,
        head_sha,
        phase,
        _clamp_pct(raw.get("progress_pct", 0)),
        goal if goal is not None else "[dropped]",
        task if task is not None else "[dropped]",
        json.dumps(sorted(surfaces), sort_keys=True),
        resumable,
    ]


def _violates_body(row):
    """INV-A — a free-form body/diff/abs-path leaked into a leaf. Prose + relative surfaces are
    legitimate; a newline, an over-cap value, or an absolute path is a body."""
    for leaf in row:
        if not isinstance(leaf, str):
            continue
        if "\n" in leaf or "\r" in leaf:
            return True
        if len(leaf) > _GOAL_MAX:
            return True
        if _ABSPATH_RX.search(leaf):
            return True
    return False


def _row_has_secret(row):
    return any(isinstance(leaf, str) and _has_secret(leaf) for leaf in row)


def fold(stream):
    """Fold a stream of raw checkpoint inputs into the reference roster partition (the truth
    half of the differential). Returns {"served": sorted rows, "excluded_security": int}."""
    served = []
    excluded_security = 0
    for raw in stream or []:
        if not isinstance(raw, dict):
            continue
        if raw.get("share_consent") is False:            # INV-D
            continue
        if is_security_sensitive(raw):                   # INV-C
            excluded_security += 1
            continue
        row = _build_row(raw)
        if _violates_body(row):                          # INV-A
            continue
        if _row_has_secret(row):                         # INV-B
            continue
        served.append(row)
    return {"served": sorted(served, key=lambda r: r[0]), "excluded_security": excluded_security}


# ── deterministic seeded stream generator (the seeded-differential arm) ───────


def _seeded_int(seed, *parts):
    h = hashlib.sha256(("|".join([str(seed)] + [str(p) for p in parts])).encode()).hexdigest()
    return int(h[:8], 16)


def generate_stream(seed, n_records=24):
    """Produce a deterministic stream for `seed`: ONE record per teammate (unique HAID — mirrors
    the one-file-per-HAID store, so neither fold dedups). The distribution is skewed so a slice
    is security-sensitive (INV-C) and a slice is consent-off (INV-D), the rest clean — so the
    fold exercises served + excluded_security every seed. Same seed => byte-identical stream.
    Carries NO absolute path and NO secret (those are the mutant-only defects), so the impl fold
    and this reference fold MUST agree on every seed."""
    stream = []
    for i in range(n_records):
        haid = "haid:dev%02d.box" % i
        kind = _seeded_int(seed, "kind", i) % 10
        phase = "wave-%d/build" % (1 + (_seeded_int(seed, "ph", i) % 3))
        if kind == 0:
            phase = "incident"                            # security-sensitive slice (INV-C)
        rec = {
            "haid": haid,
            "human": "dev%02d" % i,
            "branch": "feat/dev%02d" % i,
            "head_sha": "%07x" % (_seeded_int(seed, "sha", i) % (16 ** 7)),
            "phase": phase,
            "progress_pct": _seeded_int(seed, "pct", i) % 101,
            "active_goal": "advance module %d toward green" % (_seeded_int(seed, "g", i) % 20),
            "claimed_surfaces": ["src/mod%02d.py" % (_seeded_int(seed, "s", i) % 30)],
            "task_ref": "task-%02d" % (_seeded_int(seed, "t", i) % 15),
            "updated_at": "2026-07-10T00:00:%02dZ" % (i % 60),
            "resumable": True,
        }
        if kind == 1:
            rec["share_consent"] = False                  # consent-off slice (INV-D)
        stream.append(rec)
    return stream
