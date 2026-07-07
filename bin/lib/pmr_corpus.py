#!/usr/bin/env python3
# pmr_corpus.py — the Pre-Merge Corpus (PMR) T0 telemetry engine (spec
# heimdall-premerge-corpus-spec.md §1/§2/§3/§5.1 step 1).
#
# WHAT THIS IS: Heimdall sits at the merge boundary and can JOIN (1) which agent
# produced a change + its shape, (2) what verification found, (3) what happened
# next (merged/reverted/hotfixed/survived). That join is ground-truth labels for
# "does AI-written code actually work." This module emits the TELEMETRY PROJECTION
# of the gate pipeline's SI-2 attestation record — the `pmr_v1` record — into a
# LOCAL spool. Step 1 (this file) is EMIT-LOCALLY ONLY: the consent-gated send
# QUEUE is plumbed but NOTHING sends anywhere (the CP ingest route is step 2).
#
# THE PRIVACY LINE IS ABSOLUTE (§2), enforced by construction + falsifier-tested:
#   * ZERO-CONTENT: a pmr_v1 carries NO source, NO path strings (extension +
#     HASHED dir only), NO prompts. Only counts, hashes, coded verdicts, lang/gate
#     tokens, booleans. assert_zero_content() is the CARDINAL GUARD: any leaf that
#     looks like a real path or a source line -> emission BLOCKED + ALARMED, never
#     written. (Falsifier: plant a path/source line into the input -> blocked.)
#   * SECRET-SCAN-BEFORE-SEND: every payload is scanned client-side BEFORE it is
#     queued (reusing telemetry.py's high-signal patterns + gitleaks when present).
#     A detected secret -> BLOCKED + ALARMED. A leaked secret in telemetry is the
#     brand-killing incident; it cannot enter the spool.
#   * OFF FULLY HONORED: consent off (or HEIMDALL_TELEMETRY=off) -> emit is a pure
#     no-op; a gate eval writes ZERO PMR.
#   * PURGE ACTUALLY DELETES: `purge` empties the local spool AND records a
#     deletion request keyed by team_id_hash (the CP-side deletion is step 2).
#
# OWN NAMESPACE (§3): everything lands under <corpus_home>/telemetry/pmr/ — NEVER
# mixed with presence/ops (telemetry/events.ndjson) or the queue. BYO-inference:
# this is a PURE LOCAL METADATA PROJECTION — no model calls, no network, ever.
#
# This is a LIBRARY + a thin CLI core (driven by bin/heimdall-telemetry-corpus and
# the `hmd telemetry` router case). stdlib-only, mirrors bin/lib/telemetry.py.

from __future__ import annotations

import datetime
import hashlib
import json
import os
import re
import subprocess
import sys
import uuid

_HERE = os.path.dirname(os.path.abspath(__file__))
if _HERE not in sys.path:
    sys.path.insert(0, _HERE)

# REUSE the general telemetry layer's secret-shape patterns — never re-derive the
# secret vocabulary (bin/lib/telemetry.py:81 _SECRET_PATTERNS / :95 _ASSIGNED_OPAQUE).
import telemetry as _tel  # noqa: E402 — sibling import after sys.path setup

# ── versioned consent (stamped on EVERY record — §3 rights layer) ─────────────
# Bump when the T0 disclosure text or the pmr_v1 shape changes. The consent
# version travels with each record so an acquirer's counsel can prove exactly
# which disclosure each datum was collected under. See DATA.md.
CONSENT_VERSION = "t0-2026-07"

SCHEMA_PMR = "pmr_v1"
SCHEMA_OUTCOME = "pmr_outcome_v1"
SCHEMA_DELETE = "pmr_delete_v1"

# The bound on any coded string tag in a record. A value over this is truncated
# for the guard (a truncated path still carries '/', a truncated source line still
# carries code punctuation) so a leak is caught, never silently shipped.
_TAG_MAX = 64


# ── namespace + store layout (own dir, HOME-based — §3) ───────────────────────


def corpus_home():
    """The PMR corpus runtime home. Precedence:
        HEIMDALL_CORPUS_HOME  (tests + explicit override)
        HEIMDALL_HOME         (shared runtime home if the operator pinned one)
        ~/.heimdall           (the default; NEVER the repo-local .heimdall, so PMR
                               is never mixed with per-repo presence/ops state)
    Resolved every call (no module-load caching) so a subprocess test sees its own
    dir."""
    for key in ("HEIMDALL_CORPUS_HOME", "HEIMDALL_HOME"):
        v = os.environ.get(key)
        if v:
            return v
    return os.path.join(os.path.expanduser("~"), ".heimdall")


def pmr_dir(home=None):
    """<home>/telemetry/pmr — the PMR-only namespace root (never presence/ops)."""
    base = home if home else corpus_home()
    return os.path.join(base, "telemetry", "pmr")


def spool_dir(home=None):
    return os.path.join(pmr_dir(home), "spool")


def outcome_dir(home=None):
    return os.path.join(pmr_dir(home), "outcome")


def deletions_dir(home=None):
    return os.path.join(pmr_dir(home), "deletions")


def consent_path(home=None):
    return os.path.join(pmr_dir(home), "consent.json")


def pending_path(home=None):
    return os.path.join(pmr_dir(home), "pending.json")


def seeds_path(home=None):
    return os.path.join(pmr_dir(home), "seeds.json")


def alarms_path(home=None):
    return os.path.join(pmr_dir(home), "alarms.ndjson")


# ── hashing (never a name/URL/path in the clear — §1/§2) ──────────────────────


def _h(domain, value, n=16):
    """Domain-separated sha256 hex prefix. The domain string prevents cross-use of
    a hash between fields (a team hash can never collide with a repo hash)."""
    d = hashlib.sha256()
    d.update(domain.encode("utf-8"))
    d.update(b"\x00")
    d.update(str(value).encode("utf-8"))
    return d.hexdigest()[:n]


def team_id_hash(team_id):
    """A stable, non-reversible team key. `team_id` is ALREADY a hash (the team.json
    team_id = sha256('heimdall-team\\0'+secret)[:32]); we project it once more with
    a PMR domain so the corpus key can never be joined back to presence/ops data.
    Deletion requests are keyed by THIS value (purge round-trip)."""
    return _h("heimdall-pmr-team", team_id, 16)


def repo_class_hash(repo_identity):
    """A repo class key — NEVER the repo name or URL in the clear. `repo_identity`
    is the origin slug (or repo root) resolved by the emitter; we only ever store
    its hash."""
    return _h("heimdall-pmr-repo", repo_identity, 16)


def _dir_hash(path):
    """Hash of a file's DIRECTORY (never the path). Paired with the extension so a
    change's shape (which extensions, how many distinct dirs) survives with zero
    path leak."""
    return _h("heimdall-pmr-dir", os.path.dirname(path) or ".", 12)


def _path_hash(path):
    """Hash of a full path — used ONLY internally by the outcome observer to match
    'the same file' across commits for overlap detection. Never emitted in a T0
    record; only booleans/buckets derived from it leave."""
    return _h("heimdall-pmr-path", path, 16)


def _sha_hash(sha):
    return _h("heimdall-pmr-sha", sha, 16)


# ── time helpers ──────────────────────────────────────────────────────────────


def _now():
    return datetime.datetime.now(datetime.timezone.utc)


def _now_iso():
    return _now().replace(microsecond=0).isoformat()


def _tz_bucket():
    """A COARSE local timezone bucket (offset only, single-token, no ':' — never a
    precise locale). e.g. 'utc+0530'. Coarse by design (§1)."""
    off = datetime.datetime.now().astimezone().strftime("%z") or "+0000"
    return "utc" + off


# ── consent state (the standing decision, productized — §2/§3) ────────────────


def _read_json(path, default):
    try:
        with open(path, "r", encoding="utf-8") as fh:
            obj = json.load(fh)
        return obj if isinstance(obj, dict) else default
    except (OSError, ValueError, TypeError):
        return default


def _atomic_write_json(path, obj):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = path + ".tmp-%d" % os.getpid()
    with open(tmp, "w", encoding="utf-8") as fh:
        json.dump(obj, fh, sort_keys=True, indent=2)
        fh.write("\n")
        fh.flush()
    os.replace(tmp, path)


def load_consent(home=None):
    """The consent record: {consent_version, enabled, hunks{repo_class_hash:bool}}.
    Default is ON (T0 disclosed at install, one line + link — §2). Missing file ->
    the ON default (never fails)."""
    default = {
        "consent_version": CONSENT_VERSION,
        "enabled": True,
        "hunks": {},
        "updated": _now_iso(),
    }
    state = _read_json(consent_path(home), None)
    if not state:
        return default
    # forward-compat: fill any missing key from the default.
    for k, v in default.items():
        state.setdefault(k, v)
    if not isinstance(state.get("hunks"), dict):
        state["hunks"] = {}
    # the disclosure version currently in force is always the code's version.
    state["consent_version"] = CONSENT_VERSION
    return state


def save_consent(state, home=None):
    state["updated"] = _now_iso()
    _atomic_write_json(consent_path(home), state)
    return state


def enabled(home=None):
    """True unless telemetry is turned OFF: HEIMDALL_TELEMETRY=off|0|false|no, or the
    persisted consent has enabled=false. Default ON, but a disabled world behaves
    IDENTICALLY (emit becomes a no-op — §2 'off fully honored'). Never raises."""
    flag = (os.environ.get("HEIMDALL_TELEMETRY") or "").strip().lower()
    if flag in ("off", "0", "false", "no", "disabled"):
        return False
    try:
        return bool(load_consent(home).get("enabled", True))
    except Exception:  # noqa: BLE001 — a consent-read failure never raises/enables oddly
        return True


def set_enabled(value, home=None):
    state = load_consent(home)
    state["enabled"] = bool(value)
    return save_consent(state, home)


def set_hunks(repo_class_hash_val, value, home=None):
    """T1 per-repo opt-in FLAG only (no T1 payload is built here — §2/§5.1). Records
    that a given repo class has opted into hunk-level capture; the payload path is
    step 3, out of scope."""
    state = load_consent(home)
    if value:
        state["hunks"][repo_class_hash_val] = True
    else:
        state["hunks"].pop(repo_class_hash_val, None)
    return save_consent(state, home)


def hunks_enabled(repo_class_hash_val, home=None):
    return bool(load_consent(home).get("hunks", {}).get(repo_class_hash_val))


# ── the ZERO-CONTENT cardinal guard (§2, falsifier-tested) ────────────────────

# A leaf string that looks like a real filesystem path (a path separator with a
# segment either side). The single strongest content-leak signal.
_RX_PATHSEP = re.compile(r"[/\\]")
# A filename bearing a known source/text extension — a path or source file leaked
# even without a separator (e.g. 'users.js').
_RX_FILEEXT = re.compile(
    r"[\w.\-]+\.(?:py|js|jsx|ts|tsx|mjs|cjs|sh|bash|go|rb|rs|java|c|cc|cpp|h|hpp|"
    r"cs|php|swift|kt|scala|json|ya?ml|toml|md|txt|sql|html|css|xml)\b",
    re.I,
)
# Code punctuation that a coded metadata tag NEVER contains but a source line
# always does.
_RX_CODEY = re.compile(r"[(){};]|=>|::|==|!=|\+\+|--\s|->")


def _leaf_strings(obj, prefix="$"):
    """Yield (dotted_path, value) for every STRING leaf in a nested record. Used by
    the guard to scan the FINAL record — a leak anywhere is caught, not just in the
    fields we expect."""
    if isinstance(obj, str):
        yield prefix, obj
        return
    if isinstance(obj, dict):
        for k, v in obj.items():
            yield from _leaf_strings(v, prefix + "." + str(k))
        return
    if isinstance(obj, (list, tuple)):
        for i, v in enumerate(obj):
            yield from _leaf_strings(v, prefix + "[%d]" % i)
        return
    # numbers / bools / None carry no content payload — nothing to scan.


def _violates_zero_content(value):
    """Return a violation CODE if a leaf string could be source/path content, else
    None. High-signal only (a coded tag / hash / lang / verdict never trips these);
    a real path or source line always does."""
    if _RX_PATHSEP.search(value):
        return "path-separator"
    if "\n" in value or "\r" in value:
        return "newline"
    if len(value) > _TAG_MAX:
        return "over-length"
    if _RX_FILEEXT.search(value):
        return "source-file-extension"
    if _RX_CODEY.search(value):
        return "code-punctuation"
    # a multi-word value (whitespace-separated) — coded tags are single tokens;
    # a source line / a path with spaces / prose is multi-word.
    if len(value.split()) >= 2:
        return "multi-word-content"
    return None


def assert_zero_content(record):
    """Scan EVERY string leaf of a record. Returns (ok, violations) where violations
    is a list of {field, code} (the offending VALUE is never included — it could be
    the very content/secret we are refusing to handle). ok=True means the record is
    pure T0 metadata and may be queued; ok=False means it must be BLOCKED."""
    violations = []
    for field, value in _leaf_strings(record):
        code = _violates_zero_content(value)
        if code is not None:
            violations.append({"field": field, "code": code})
    return (len(violations) == 0, violations)


# ── secret-scan-before-send (§2, falsifier-tested) ────────────────────────────


def secret_scan_payload(record):
    """Scan a serialized payload for secret shapes BEFORE it can be queued to send.
    Reuses telemetry.py's high-signal patterns (never re-derived) and, when gitleaks
    is installed, pipes the payload through `gitleaks stdin` as defense in depth.
    Returns (clean, findings) — findings are pattern LABELS only, never the matched
    bytes."""
    blob = json.dumps(record, sort_keys=True)
    findings = []
    for rx in _tel._SECRET_PATTERNS:  # noqa: SLF001 — intentional reuse of the vocab
        if rx.search(blob):
            findings.append(rx.pattern[:40])
    if _tel._ASSIGNED_OPAQUE.search(blob):  # noqa: SLF001
        findings.append("assigned-opaque-credential")
    # gitleaks (if present) — belt over the builtin regex braces.
    gl = _gitleaks_stdin(blob)
    if gl:
        findings.append("gitleaks:" + gl)
    return (len(findings) == 0, findings)


def _gitleaks_stdin(blob):
    """Run `gitleaks stdin` over the blob when available. Returns a short label on a
    finding, "" on clean, None when gitleaks is absent/unusable (a missing scanner
    must never gate — the builtin regex is always armed)."""
    from shutil import which
    if which("gitleaks") is None:
        return None
    try:
        proc = subprocess.run(
            ["gitleaks", "stdin", "--no-banner", "--redact"],
            input=blob.encode("utf-8"),
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=20,
        )
    except (OSError, subprocess.SubprocessError):
        return None
    # gitleaks: nonzero exit == a finding.
    return "finding" if proc.returncode != 0 else ""


# ── alarms (a blocked emission is LOUD, never silent — §2) ────────────────────


def _alarm(kind, detail, home=None):
    """Record a blocked-emission alarm (redacted: kind + field paths / labels only,
    never the offending value) and shout on stderr. A blocked payload is NEVER
    written to the spool — this is the audit trail that it was refused."""
    rec = {
        "ts": _now_iso(),
        "kind": kind,
        "detail": detail,
        "consent_version": CONSENT_VERSION,
    }
    try:
        os.makedirs(pmr_dir(home), exist_ok=True)
        with open(alarms_path(home), "a", encoding="utf-8") as fh:
            fh.write(json.dumps(rec, sort_keys=True) + "\n")
            fh.flush()
    except OSError:
        pass  # alarm-log write failed; caller still gets blocked + the stderr shout
    sys.stderr.write(
        "PMR-ALARM [%s]: emission BLOCKED (never sent) — %s\n"
        % (kind, json.dumps(detail))
    )


# ── the projection: SI-2 attestation record -> pmr_v1 (§1) ────────────────────

# File basenames that mark a dependency-graph touch (computed from paths, then the
# paths are DISCARDED — only the boolean leaves).
_DEP_MANIFESTS = {
    "package.json", "package-lock.json", "yarn.lock", "pnpm-lock.yaml",
    "requirements.txt", "pyproject.toml", "poetry.lock", "pipfile", "pipfile.lock",
    "go.mod", "go.sum", "cargo.toml", "cargo.lock", "gemfile", "gemfile.lock",
    "pom.xml", "build.gradle", "build.gradle.kts", "composer.json", "composer.lock",
}
# A test-file signal on a path basename (computed, then discarded — only the count).
_RX_TESTFILE = re.compile(r"(^|[._/-])(test|tests|spec|__tests__)([._/-]|$)", re.I)


def _tag(v):
    """Bound a coded string tag to _TAG_MAX. Content is PRESERVED (not sanitized):
    the zero-content guard — not this normalizer — is the enforcer, so a planted
    path/source line survives to the guard and is caught, never silently cleaned."""
    if v is None:
        return None
    return str(v)[:_TAG_MAX]


def _tag_list(seq):
    out = []
    for v in seq or []:
        t = _tag(v)
        if t:
            out.append(t)
    return out


def _int(v, default=0):
    try:
        return int(v)
    except (TypeError, ValueError):
        return default


def _num(v, default=0):
    if isinstance(v, bool):
        return int(v)
    if isinstance(v, (int, float)):
        return v
    try:
        return int(v)
    except (TypeError, ValueError):
        try:
            return float(v)
        except (TypeError, ValueError):
            return default


def project(job):
    """Build a pmr_v1 record from the gate-pipeline job (PURE — no IO). ZERO-CONTENT
    by construction: derives COUNTS/booleans from the SI-2 attestation and copies
    only coded/hashed/lang/verdict tags. NEVER copies a path or a source symbol.

    job = {
      attestation: <SI-2 record>,          # the projection source (report.json peer)
      ids:   {team_id, repo},              # team_id (already a hash), repo identity
      diff:  {loc_added, loc_deleted, hunks},
      agent: {tool, model_family, version},
      verify:{gates_run[], verdict, deny_reasons[coded], retry_count,
              time_to_green_s, mutants_run, survived, bloat_budget_delta},
      human: {merged, overridden, override_latency_s},
      env:   {os_class, ci, hmd_version},
    }
    """
    att = job.get("attestation") or {}
    ids = job.get("ids") or {}
    diff = job.get("diff") or {}
    agent = job.get("agent") or {}
    verify = job.get("verify") or {}
    human = job.get("human") or {}
    env = job.get("env") or {}

    claims = att.get("claims") or {}
    files = claims.get("files") or []
    reuse = att.get("reuse") or {}
    risk = att.get("risk") or {}

    # change shape — all derived from the attestation, paths never copied.
    langs = sorted({f.get("lang") for f in files if f.get("lang")})
    test_files_touched = sum(
        1 for f in files if isinstance(f.get("path"), str)
        and _RX_TESTFILE.search(os.path.basename(f["path"]) or f["path"])
    )
    dep_graph_touch = any(
        isinstance(f.get("path"), str)
        and os.path.basename(f["path"]).lower() in _DEP_MANIFESTS
        for f in files
    )
    files_touched = _int(claims.get("file_count", len(files)))
    complexity_delta = _int(claims.get("unit_count", 0))

    # verify shape — coded verdicts + falsify/reuse rollups. deny_reasons default to
    # the SI-2 risk flag CODES (never prose) when the verdict is a deny/fail.
    verdict = _tag(verify.get("verdict"))
    deny_reasons = _tag_list(verify.get("deny_reasons"))
    if not deny_reasons and verdict in ("deny", "fail", "block", "red"):
        deny_reasons = _tag_list(
            f.get("code") for f in (risk.get("flags") or []) if f.get("code")
        )

    rec = {
        "schema": SCHEMA_PMR,
        "consent_version": CONSENT_VERSION,
        "ids": {
            "pmr_id": "pmr-" + uuid.uuid4().hex,
            "team_id_hash": team_id_hash(ids.get("team_id", "solo")),
            "repo_class_hash": repo_class_hash(ids.get("repo", "unknown")),
        },
        "when": {
            "ts": _now_iso(),
            "tz_bucket": _tz_bucket(),
        },
        "agent": {
            "haid_class": {
                "tool": _tag(agent.get("tool") or "unknown"),
                "model_family": _tag(agent.get("model_family") or "unknown"),
                "version": _tag(agent.get("version") or "unknown"),
            },
        },
        "change": {
            "files_touched": files_touched,
            "loc_added": _int(diff.get("loc_added", 0)),
            "loc_deleted": _int(diff.get("loc_deleted", 0)),
            "hunks": _int(diff.get("hunks", 0)),
            "langs": _tag_list(langs),
            "complexity_delta": complexity_delta,
            "dep_graph_touch": bool(dep_graph_touch),
            "test_files_touched": test_files_touched,
        },
        "verify": {
            "gates_run": _tag_list(verify.get("gates_run")),
            "verdict": verdict,
            "deny_reasons": deny_reasons,
            "retry_count": _int(verify.get("retry_count", 0)),
            "time_to_green_s": _num(verify.get("time_to_green_s", 0)),
            "falsify": {
                "mutants_run": _int(verify.get("mutants_run", 0)),
                "survived": _int(verify.get("survived", 0)),
            },
            "reuse": {
                "dup_candidates": _int(
                    len(reuse.get("suspected_duplicates") or [])
                ),
                "reused": bool(_int(reuse.get("units_reusing", 0)) > 0),
            },
            "bloat_budget_delta": _num(verify.get("bloat_budget_delta", 0)),
        },
        "human": {
            "merged": bool(human.get("merged", False)),
            "overridden": bool(human.get("overridden", False)),
            "override_latency_s": _num(human.get("override_latency_s", 0)),
        },
        "env": {
            "os_class": _tag(env.get("os_class") or _default_os_class()),
            "ci": bool(env.get("ci", False)),
            "hmd_version": _tag(env.get("hmd_version") or "unknown"),
        },
    }
    return rec


def _default_os_class():
    try:
        return (os.uname().sysname or "unknown").lower()
    except (AttributeError, OSError):
        return sys.platform or "unknown"


# ── the emit path: project -> guard -> secret-scan -> queue (§1/§2/§5.1) ──────


def emit_pmr(job, home=None):
    """Emit ONE pmr_v1 to the LOCAL send-queue (spool). The full T0 gate:
        1. OFF honored — disabled -> pure no-op, ZERO write.
        2. project() — the zero-content-by-construction metadata projection.
        3. assert_zero_content() — CARDINAL guard; a path/source leak -> BLOCK+ALARM.
        4. secret_scan_payload() — a secret shape -> BLOCK+ALARM (before queueing).
        5. write to spool + seed the outcome observer's pending join.
    Returns a status dict (never raises into the gate pipeline — telemetry must
    never fail a run). NOTHING sends anywhere; the spool IS the queue (step 1)."""
    try:
        if not enabled(home):
            return {"emitted": False, "reason": "disabled"}

        rec = project(job)

        ok, violations = assert_zero_content(rec)
        if not ok:
            _alarm("zero-content", {"violations": violations}, home)
            return {"emitted": False, "reason": "zero-content-blocked",
                    "violations": violations}

        clean, findings = secret_scan_payload(rec)
        if not clean:
            _alarm("secret-scan", {"findings": findings}, home)
            return {"emitted": False, "reason": "secret-detected-blocked",
                    "findings": findings}

        path = _write_spool(rec, home)
        # The pending-join key is the GIT-resolved repo class (cwd), which the
        # post-commit observer looks up by the same function — so the join holds
        # regardless of what repo identity string the emitter passed in ids.repo
        # (a slug in one call, a realpath in another). Independent of the record's
        # own repo_class_hash.
        try:
            join_rc = repo_class_hash(repo_identity())
        except Exception:  # noqa: BLE001 — never fail the emit on a git-resolve hiccup
            join_rc = rec["ids"]["repo_class_hash"]
        _set_pending(join_rc, rec["ids"]["pmr_id"], home)
        return {"emitted": True, "pmr_id": rec["ids"]["pmr_id"], "spool_path": path,
                "consent_version": rec["consent_version"]}
    except Exception as exc:  # noqa: BLE001 — telemetry NEVER fails the caller (§8 style)
        return {"emitted": False, "reason": "error", "detail": str(exc)[:120]}


def _write_spool(rec, home=None):
    d = spool_dir(home)
    os.makedirs(d, exist_ok=True)
    path = os.path.join(d, rec["ids"]["pmr_id"] + ".json")
    _atomic_write_json(path, rec)
    return path


def spool_records(home=None):
    """Read every queued pmr_v1 from the spool (read-only). Tolerant: a bad file is
    skipped, an absent spool yields []."""
    return _read_dir_records(spool_dir(home))


def outcome_records(home=None):
    return _read_dir_records(outcome_dir(home))


def _read_dir_records(d):
    out = []
    try:
        names = sorted(n for n in os.listdir(d) if n.endswith(".json"))
    except OSError:
        return out
    for n in names:
        obj = _read_json(os.path.join(d, n), None)
        if obj:
            out.append(obj)
    return out


# ── the local outcome observer (pmr_outcome — §1 outcome join) ────────────────


def repo_identity(repo=None):
    """The repo's identity for repo_class_hash: the origin slug when present, else
    the repo root path. Only ever HASHED before it leaves — never emitted raw."""
    repo = repo or os.getcwd()
    origin = _git(repo, ["remote", "get-url", "origin"])
    if origin:
        m = re.search(r"github\.com[:/]+([^/]+)/(.+?)(?:\.git)?/?$", origin.strip())
        if m:
            return m.group(1) + "/" + m.group(2)
        return origin.strip()
    root = _git(repo, ["rev-parse", "--show-toplevel"]) or repo
    return root.strip()


def _git(repo, args):
    try:
        proc = subprocess.run(
            ["git", "-C", repo] + args,
            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=30,
        )
    except (OSError, subprocess.SubprocessError):
        return ""
    if proc.returncode != 0:
        return ""
    return proc.stdout.decode("utf-8", "replace")


def _set_pending(rc_hash, pmr_id, home=None):
    """Record that the next commit in this repo class should be joined to this PMR.
    The post-commit hook (observe_commit) consumes it. Local-only."""
    state = _read_json(pending_path(home), {})
    if not isinstance(state, dict):
        state = {}
    state[rc_hash] = {"pmr_id": pmr_id, "ts": _now_iso()}
    _atomic_write_json(pending_path(home), state)


def _get_pending(rc_hash, home=None):
    return (_read_json(pending_path(home), {}) or {}).get(rc_hash)


def _clear_pending(rc_hash, home=None):
    state = _read_json(pending_path(home), {})
    if isinstance(state, dict) and rc_hash in state:
        state.pop(rc_hash, None)
        _atomic_write_json(pending_path(home), state)


def _hunks_from_sha(repo, sha):
    """Compute the change's hunk line-ranges for `sha`, CLIENT-side, from the user's
    own repo. Returns a list of {path_hash, file_ext, dir_hash, ranges:[[a,b],...]}.
    The path is HASHED (never stored) — only enough to match 'the same file' across
    commits for overlap detection."""
    raw = _git(repo, ["show", "--format=", "--unified=0", "--no-color", sha])
    out = []
    cur = None
    for line in raw.splitlines():
        if line.startswith("+++ "):
            p = line[4:].strip()
            if p.startswith("b/"):
                p = p[2:]
            if p == "/dev/null":
                cur = None
                continue
            ext = os.path.splitext(p)[1].lstrip(".").lower()
            cur = {
                "path_hash": _path_hash(p),
                "file_ext": ext,
                "dir_hash": _dir_hash(p),
                "ranges": [],
            }
            out.append(cur)
        elif line.startswith("@@") and cur is not None:
            m = re.search(r"\+(\d+)(?:,(\d+))?", line)
            if m:
                start = int(m.group(1))
                count = int(m.group(2)) if m.group(2) is not None else 1
                if count == 0:
                    # a pure deletion hunk anchors at `start` (1 line of context).
                    cur["ranges"].append([start, start])
                else:
                    cur["ranges"].append([start, start + count - 1])
    # drop files that yielded no added/changed ranges (pure metadata).
    return [h for h in out if h["ranges"]]


def observe_commit(repo=None, sha=None, home=None):
    """Post-commit observer: join the just-made commit to the pending PMR for this
    repo class and SEED the outcome map with the commit's hunk line-ranges. ALL
    client-side. Fail-silent + non-blocking (a git-hook must never break a commit).
    A no-op when there is no pending PMR."""
    try:
        repo = repo or os.getcwd()
        sha = (sha or _git(repo, ["rev-parse", "HEAD"]).strip())
        if not sha:
            return {"observed": False, "reason": "no-sha"}
        rc = repo_class_hash(repo_identity(repo))
        pend = _get_pending(rc, home)
        if not pend:
            return {"observed": False, "reason": "no-pending-pmr"}
        ct = _git(repo, ["show", "-s", "--format=%ct", sha]).strip()
        seed = {
            "pmr_id": pend["pmr_id"],
            "repo_class_hash": rc,
            # sha is kept LOCAL-ONLY (seeds.json never leaves the machine) so the
            # scan can walk descendant history topologically; the record that is
            # queued to send carries only the HASH.
            "sha": sha,
            "merged_sha_hash": _sha_hash(sha),
            "commit_ts": _int(ct, int(_now().timestamp())),
            "hunks": _hunks_from_sha(repo, sha),
        }
        seeds = _read_json(seeds_path(home), {})
        if not isinstance(seeds, dict):
            seeds = {}
        seeds[pend["pmr_id"]] = seed
        _atomic_write_json(seeds_path(home), seeds)
        _clear_pending(rc, home)
        return {"observed": True, "pmr_id": pend["pmr_id"],
                "merged_sha_hash": seed["merged_sha_hash"]}
    except Exception as exc:  # noqa: BLE001 — a hook must never raise into a commit
        return {"observed": False, "reason": "error", "detail": str(exc)[:120]}


def _ranges_overlap(a, b):
    return a[0] <= b[1] and b[0] <= a[1]


def _hunks_overlap(seed_hunks, later_hunks):
    """True iff a later commit touches overlapping lines of the SAME file (path_hash)
    as the seed."""
    by_path = {}
    for h in later_hunks:
        by_path.setdefault(h["path_hash"], []).extend(h["ranges"])
    for sh in seed_hunks:
        for lr in by_path.get(sh["path_hash"], []):
            for sr in sh["ranges"]:
                if _ranges_overlap(sr, lr):
                    return True
    return False


_RX_REVERT = re.compile(r"\brevert\b", re.I)


def scan_outcomes(repo=None, now=None, home=None):
    """The local outcome job (weekly): for each seeded PMR, scan SUBSEQUENT history
    for revert/hotfix overlap (7d/30d) + survived_90d, ALL client-side from the
    user's own repo. Emits pmr_outcome records to the outcome spool — only booleans
    /buckets/hashes ever leave. Returns the list of outcome records."""
    repo = repo or os.getcwd()
    now_ts = int(now if now is not None else _now().timestamp())
    seeds = _read_json(seeds_path(home), {})
    if not isinstance(seeds, dict):
        return []
    results = []
    for pmr_id, seed in seeds.items():
        seed_ts = _int(seed.get("commit_ts"), now_ts)
        seed_sha_hash = seed.get("merged_sha_hash")
        seed_sha = seed.get("sha")
        seed_hunks = seed.get("hunks") or []

        reverted = {"7d": False, "30d": False}
        hotfixed = {"7d": False, "30d": False}
        overlap_within_90d = False

        # DESCENDANT history of the seed commit — topologically correct (timestamp-
        # independent): `git log <seed>..HEAD` is exactly the commits reachable from
        # HEAD but not from the seed, i.e. everything that landed AFTER it. This
        # avoids both the same-second-skip and the ancestor-false-positive that a
        # pure timestamp ordering suffers.
        if not seed_sha:
            log = ""  # legacy seed without a local sha -> no later-history known
        else:
            log = _git(repo, ["log", "--format=%H %ct", seed_sha + "..HEAD"])
        for ln in log.splitlines():
            parts = ln.split()
            if len(parts) < 2:
                continue
            csha, cts = parts[0], _int(parts[1], 0)
            age_days = max(0.0, (cts - seed_ts) / 86400.0)
            later_hunks = _hunks_from_sha(repo, csha)
            if not _hunks_overlap(seed_hunks, later_hunks):
                continue
            msg = _git(repo, ["show", "-s", "--format=%s%n%b", csha])
            is_revert = bool(_RX_REVERT.search(msg))
            if age_days <= 90:
                overlap_within_90d = True
            for win, days in (("7d", 7), ("30d", 30)):
                if age_days <= days:
                    if is_revert:
                        reverted[win] = True
                    else:
                        hotfixed[win] = True

        age_now_days = (now_ts - seed_ts) / 86400.0
        survived_90d = bool(age_now_days >= 90 and not overlap_within_90d)

        rec = {
            "schema": SCHEMA_OUTCOME,
            "consent_version": CONSENT_VERSION,
            "pmr_id": pmr_id,
            "merged_sha_hash": seed_sha_hash,
            "reverted_within": reverted,
            "hotfixed_within": hotfixed,
            "survived_90d": survived_90d,
        }
        # even an outcome is guarded: it must be booleans/buckets/hashes only.
        ok, violations = assert_zero_content(rec)
        if not ok:
            _alarm("zero-content-outcome", {"violations": violations}, home)
            continue
        _write_outcome(rec, home)
        results.append(rec)
    return results


def _write_outcome(rec, home=None):
    d = outcome_dir(home)
    os.makedirs(d, exist_ok=True)
    path = os.path.join(d, rec["pmr_id"] + ".outcome.json")
    _atomic_write_json(path, rec)
    return path


# ── controls: status / purge / deletion (§3 rights layer) ─────────────────────


def _dir_size(d):
    total = 0
    try:
        for n in os.listdir(d):
            fp = os.path.join(d, n)
            try:
                total += os.path.getsize(fp)
            except OSError:
                continue
    except OSError:
        return 0
    return total


def status(home=None):
    """A read-only at-a-glance: tier, what is collected, spool size, opted-in repos,
    queued deletions. Writes nothing."""
    consent = load_consent(home)
    hunks_repos = sorted(consent.get("hunks", {}).keys())
    pmr_n = len(spool_records(home))
    out_n = len(outcome_records(home))
    tiers = ["T0"]
    if hunks_repos:
        tiers.append("T1-hunks")
    return {
        "schema": "pmr_status_v1",
        "consent_version": CONSENT_VERSION,
        "enabled": enabled(home),
        "tier": "+".join(tiers),
        "collected": [
            "pmr_v1 T0 metadata: change SHAPES (counts/langs), verdict CODES, "
            "falsify/reuse rollups, merged/reverted/hotfixed/survived OUTCOMES",
        ],
        "never_collected": ["source code", "file paths (extension + hashed dir only)",
                            "prompts", "secrets"],
        "spool": {
            "pmr_queued": pmr_n,
            "outcome_queued": out_n,
            "bytes": _dir_size(spool_dir(home)) + _dir_size(outcome_dir(home)),
        },
        "hunks_optin_repos": hunks_repos,
        "deletion_requests": len(_read_dir_records(deletions_dir(home))),
        "home": pmr_dir(home),
    }


def purge(team_id=None, repo=None, home=None):
    """Local purge + queued corpus deletion (§3). Empties the local spool (pmr +
    outcome + pending + seeds) AND records a deletion request keyed by team_id_hash.
    Deletion ACTUALLY DELETES — the local data is gone; the request is what the
    CP-side deletion job (step 2) honors against the corpus. Round-trip tested."""
    tid = team_id
    if not tid:
        # resolve the current repo's team_id from team.json when available.
        tid = _current_team_id(repo)
    tih = team_id_hash(tid or "solo")
    req = {
        "schema": SCHEMA_DELETE,
        "consent_version": CONSENT_VERSION,
        "team_id_hash": tih,
        "requested_at": _now_iso(),
        "status": "queued",
    }
    os.makedirs(deletions_dir(home), exist_ok=True)
    req_path = os.path.join(
        deletions_dir(home),
        "%d-%s.json" % (int(_now().timestamp()), tih),
    )
    _atomic_write_json(req_path, req)

    removed = _empty_dir(spool_dir(home)) + _empty_dir(outcome_dir(home))
    for p in (pending_path(home), seeds_path(home)):
        try:
            if os.path.exists(p):
                os.remove(p)
                removed += 1
        except OSError:
            removed += 0  # best-effort local delete; never fail on one stubborn file
    return {"purged": True, "removed": removed, "team_id_hash": tih,
            "deletion_request": req_path}


def _current_team_id(repo=None):
    """Read the repo's team_id from .heimdall/team.json (the same secret->id the
    server uses). Returns None when there is no team file (solo)."""
    repo = repo or os.getcwd()
    root = _git(repo, ["rev-parse", "--show-toplevel"]).strip() or repo
    tf = os.path.join(root, ".heimdall", "team.json")
    data = _read_json(tf, None)
    if not data:
        return None
    sec = data.get("team_secret")
    if not sec:
        return None
    # team_id = sha256("heimdall-team\0"+secret)[:32] — matches heimdall-team.
    return hashlib.sha256(b"heimdall-team\x00" + sec.encode("utf-8")).hexdigest()[:32]


def _empty_dir(d):
    n = 0
    try:
        for name in os.listdir(d):
            fp = os.path.join(d, name)
            try:
                if os.path.isfile(fp):
                    os.remove(fp)
                    n += 1
            except OSError:
                continue
    except OSError:
        return 0
    return n


# ── post-commit hook install (chains an existing hook — never breaks it) ──────

_HOOK_MARKER = "# >>> heimdall pmr outcome observer >>>"
_HOOK_END = "# <<< heimdall pmr outcome observer <<<"


def install_post_commit_hook(repo=None):
    """Install a MINIMAL post-commit hook that calls the outcome observer, chaining
    any pre-existing hook so it is NEVER broken. Idempotent (guarded by a marker).
    Returns a status dict."""
    repo = repo or os.getcwd()
    root = _git(repo, ["rev-parse", "--show-toplevel"]).strip()
    if not root:
        return {"installed": False, "reason": "not-a-git-repo"}
    hooks_dir = _git(repo, ["rev-parse", "--git-path", "hooks"]).strip()
    if not hooks_dir:
        hooks_dir = os.path.join(root, ".git", "hooks")
    if not os.path.isabs(hooks_dir):
        hooks_dir = os.path.join(root, hooks_dir)
    os.makedirs(hooks_dir, exist_ok=True)
    hook = os.path.join(hooks_dir, "post-commit")

    block = _hook_block()

    if os.path.exists(hook):
        with open(hook, "r", encoding="utf-8") as fh:
            existing = fh.read()
        if _HOOK_MARKER in existing:
            return {"installed": True, "reason": "already-present", "path": hook}
        # A foreign hook exists — CHAIN it: preserve it verbatim, append our block.
        if not existing.startswith("#!"):
            existing = "#!/usr/bin/env bash\n" + existing
        new = existing.rstrip("\n") + "\n\n" + block + "\n"
        with open(hook, "w", encoding="utf-8") as fh:
            fh.write(new)
        os.chmod(hook, 0o755)
        return {"installed": True, "reason": "chained", "path": hook}

    with open(hook, "w", encoding="utf-8") as fh:
        fh.write("#!/usr/bin/env bash\n" + block + "\n")
    os.chmod(hook, 0o755)
    return {"installed": True, "reason": "created", "path": hook}


def _hook_block():
    """The guarded, fail-silent, non-blocking observer call. Resolves the CLI via
    PATH (hmd); a missing CLI is a silent no-op — a git hook must NEVER break a
    commit."""
    return "\n".join([
        _HOOK_MARKER,
        "# Records the just-made commit's outcome-observer seed (booleans/buckets",
        "# leave; source never does). Fail-silent + non-blocking by contract.",
        'if command -v hmd >/dev/null 2>&1; then',
        '  hmd telemetry observe --sha "$(git rev-parse HEAD 2>/dev/null)" '
        '>/dev/null 2>&1 || true',
        "fi",
        _HOOK_END,
    ])


# ── CLI core (driven by bin/heimdall-telemetry-corpus + `hmd telemetry`) ──────


def _read_job(arg):
    """A --job arg is inline JSON or @path; default reads stdin. Returns {} on any
    parse failure (emit then no-ops honestly)."""
    try:
        if arg is None:
            raw = sys.stdin.read()
        elif arg.startswith("@"):
            with open(arg[1:], "r", encoding="utf-8") as fh:
                raw = fh.read()
        else:
            raw = arg
        obj = json.loads(raw)
        return obj if isinstance(obj, dict) else {}
    except (OSError, ValueError, TypeError):
        return {}


def _cli(argv):
    """CLI core. Subcommands (the `hmd telemetry` set + the internal emit/observe):
        status                         read-only at-a-glance (JSON)
        on | off                       flip consent (off is FULLY honored)
        hunks on|off                   T1 per-repo opt-in FLAG (no T1 payload)
        purge [--team-id ID]           local purge + queued deletion (round-trip)
        emit [--job @file|JSON]        project+guard+scan+queue one pmr_v1 (stdin default)
        observe [--sha SHA]            post-commit outcome-observer seed
        scan                           local outcome job (revert/hotfix/survived)
        install-hook                   install the chained post-commit hook
    """
    import argparse

    p = argparse.ArgumentParser(prog="hmd telemetry", add_help=True)
    p.add_argument("subcommand")
    p.add_argument("arg", nargs="?")            # `hunks on|off` value
    p.add_argument("--job")
    p.add_argument("--sha")
    p.add_argument("--team-id", dest="team_id")
    p.add_argument("--home")
    p.add_argument("--json", action="store_true", help="force JSON output")
    args = p.parse_args(argv)
    home = args.home

    sub = args.subcommand

    if sub == "status":
        print(json.dumps(status(home), indent=2, sort_keys=True))
        return 0

    if sub == "on":
        set_enabled(True, home)
        print(json.dumps({"enabled": True}))
        return 0

    if sub == "off":
        set_enabled(False, home)
        print(json.dumps({"enabled": False}))
        return 0

    if sub == "hunks":
        val = (args.arg or "").lower()
        if val not in ("on", "off"):
            print(json.dumps({"error": "usage: hunks on|off"}))
            return 2
        rc = repo_class_hash(repo_identity())
        set_hunks(rc, val == "on", home)
        print(json.dumps({"hunks": val == "on", "repo_class_hash": rc}))
        return 0

    if sub == "purge":
        print(json.dumps(purge(team_id=args.team_id, home=home), indent=2,
                         sort_keys=True))
        return 0

    if sub == "emit":
        res = emit_pmr(_read_job(args.job), home)
        print(json.dumps(res, sort_keys=True))
        return 0  # never gate the caller

    if sub == "observe":
        res = observe_commit(sha=args.sha, home=home)
        print(json.dumps(res, sort_keys=True))
        return 0

    if sub == "scan":
        res = scan_outcomes(home=home)
        print(json.dumps({"outcomes": res}, sort_keys=True))
        return 0

    if sub == "install-hook":
        print(json.dumps(install_post_commit_hook(), sort_keys=True))
        return 0

    print(json.dumps({"error": "unknown subcommand: %s" % sub}))
    return 2


if __name__ == "__main__":
    sys.exit(_cli(sys.argv[1:]))
