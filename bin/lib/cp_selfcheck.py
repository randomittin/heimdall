#!/usr/bin/env python3
# cp_selfcheck.py — the OPERATOR SELF-CHECK engine behind
# `heimdall-control-plane diagnose`.
#
# DESIGN DOSSIER §C (rich diagnostics — the operator-facing slice) + §3/§9/§10.
# Two distinct diagnostic surfaces share the "diagnostics" name; this module is the
# OPERATOR one: a synchronous, read-only "is this control plane sane right now?"
# pre-flight an operator runs on a box BEFORE trusting it to serve. (The OTHER
# surface — the runtime telemetry that flows to observe-ingest — is built elsewhere;
# this module never ships anything anywhere, it only INSPECTS local state.)
#
# WHAT IT CHECKS (each returns a structured pass/fail + a human remedy):
#   python_runtime  — the interpreter is a supported version (the engine is py3).
#   crypto_backend  — an Ed25519 backend (cryptography|pynacl) loaded → PKI is live
#                     (CRITICAL: with no backend the server fails CLOSED on every
#                     request, so an operator must know before serving).
#   pki_key         — the HAID→pubkey registry exists, loads, and holds >=1 key
#                     (CRITICAL: an empty/absent registry means no instance can auth).
#   audit_writable  — the append-only audit store dir is present + writable
#                     (CRITICAL: §9 audit is the security record; an unwritable audit
#                     store means actions go unrecorded).
#   stores_reachable— every cp_* state dir (jobs/schedules/approvals/notify/observe)
#                     is creatable + writable (CRITICAL: the durable substrate).
#   allowlist_sane  — the action-type allowlist (§1 blast-radius control) is
#                     non-empty + every spec validates (CRITICAL: an empty allowlist
#                     refuses everything; a malformed one is a latent refusal bug).
#   config_sane     — HEIMDALL_HOME resolves to a usable path + the control-plane
#                     subtree is under it (advisory: surfaces a mis-pointed home).
#   notify_egress   — the notify connector registry loads and each connector reports
#                     health() WITHOUT crashing (advisory, READ-ONLY: an inactive
#                     connector is fine — absent creds is the documented degrade —
#                     we only assert the egress layer is wired + introspectable).
#
# NO-SECRET-BY-CONSTRUCTION (§5/§7, the same discipline the stores hold). A check
# result carries ONLY: id, a one-line human status, the critical flag, ok, and a
# remedy string — plus, where useful, a PATH (never a file's CONTENTS). No check
# reads or emits key material, a signature, a token, or any registry VALUE. The
# pki_key check proves a key is PRESENT by COUNTING registry entries; it never reads
# a pubkey byte and certainly never a private seed (private seeds never live in any
# cp store at all). connectors' health() is content-free by its own contract
# ({name, active, reason}) — no creds in the shape. The result of run_all() is
# therefore safe to print verbatim to a terminal or pipe as JSON.
#
# stdlib-only. Imports the cp_* libs it inspects (they import cleanly even with no
# crypto backend — the dossier's graceful-degrade), so this module loads anywhere
# the engine loads.

from __future__ import annotations

import os
import sys

_HERE = os.path.dirname(os.path.abspath(__file__))
if _HERE not in sys.path:
    sys.path.insert(0, _HERE)

# The lowest supported interpreter for the engine (py3; f-strings/typing used across
# the cp_* libs). Kept as a constant so the runtime check and its remedy stay synced.
_MIN_PY = (3, 7)


# ── the check-result shape (structured pass/fail + human remedy — §C) ──────────


def _result(check_id, *, critical, ok, status, remedy, path=None):
    """One self-check outcome. The ONLY fields that leave this module:
        id       — stable machine id (the table row key + the JSON key).
        critical — True iff a failure should fail the whole diagnose (nonzero exit).
        ok       — pass/fail.
        status   — a one-line, SECRET-FREE human summary (paths ok, values never).
        remedy   — what an operator should DO to fix a failure (always present, even
                   on a pass, so the table reads uniformly).
        path     — OPTIONAL: a filesystem path the check probed (a path is not a
                   secret; a path's CONTENTS would be — those are never included).
    No registry value, key byte, signature, or token is ever placed here."""
    out = {
        "id": check_id,
        "critical": bool(critical),
        "ok": bool(ok),
        "status": status,
        "remedy": remedy,
    }
    if path is not None:
        out["path"] = path
    return out


# ── individual checks (each pure-ish: reads local state, returns a _result) ────


def check_python_runtime():
    """The interpreter is a supported py3. The engine is python3 across bin/lib."""
    v = sys.version_info
    ok = (v.major, v.minor) >= _MIN_PY
    ver = "%d.%d.%d" % (v.major, v.minor, v.micro)
    return _result(
        "python_runtime",
        critical=False,
        ok=ok,
        status=("python %s (>= %d.%d required)" % (ver, _MIN_PY[0], _MIN_PY[1]))
        if ok else
        ("python %s is below the required %d.%d" % (ver, _MIN_PY[0], _MIN_PY[1])),
        remedy="run the control plane under python %d.%d or newer"
        % (_MIN_PY[0], _MIN_PY[1]),
    )


def check_crypto_backend():
    """An Ed25519 backend loaded → PKI sign/verify is live (§3). With no backend the
    server fails CLOSED on every request, so this is CRITICAL for a serving box."""
    import cp_auth
    ok = cp_auth.crypto_available()
    backend = cp_auth.backend_name() or "(none)"
    return _result(
        "crypto_backend",
        critical=True,
        ok=ok,
        status=("Ed25519 backend live: %s" % backend) if ok else
        "no Ed25519 backend — PKI runs DEGRADED (server fails closed on every request)",
        remedy="install `cryptography` (preferred) or `pynacl` so PKI sign/verify works",
    )


def check_pki_key(home=None):
    """The HAID->pubkey registry loads and holds >=1 key (§3). An empty or absent
    registry means no instance can authenticate. CRITICAL. We COUNT entries to prove
    presence — never read a pubkey byte, and private seeds never live here at all (the
    instance keeps its seed locally).

    BACKEND-AWARE. The registry is read THROUGH the StateBackend (cp_auth._load_keys ->
    get_record), so the COUNT works on any backend — firestore-durable or local. Only the
    PATH the row reports is filesystem-specific: keys_path() routes to backend.path(),
    which a non-filesystem backend (firestore) REFUSES (BackendUnavailable). So we resolve
    the path BEST-EFFORT (omitting it under firestore — a path is the only filesystem-bound
    field) and decide presence by the backend-served COUNT, not by os.path.isfile()."""
    import cp_auth
    import cp_state
    # Path is filesystem-specific and purely informational; a non-filesystem backend has
    # none. Resolve best-effort so the row keeps a path on local and simply omits it on
    # firestore — never let path() refusal crash the check.
    path = None
    try:
        path = cp_auth.keys_path(home)
    except cp_state.BackendUnavailable:
        path = None
    # Presence + count come from the backend-served registry (get_record), which works on
    # every backend. _load_keys folds an absent/corrupt/off-schema registry to {} keys.
    count = 0
    loadable = True
    try:
        reg = cp_auth._load_keys(home)
        count = len(reg.get("keys", {}))
    except Exception:  # noqa: BLE001 — any unexpected backend/read error → not loadable.
        loadable = False
    ok = loadable and count >= 1
    if not loadable:
        status = "key registry present but unreadable/off-schema"
    elif count == 0:
        status = "no registered identities — the key registry is empty or absent"
    else:
        status = "%d registered identit%s in the key registry" % (
            count, "y" if count == 1 else "ies")
    return _result(
        "pki_key",
        critical=True,
        ok=ok,
        status=status,
        remedy="register an identity: `heimdall-control-plane identity --haid <HAID>`",
        path=path,
    )


def check_audit_writable(home=None):
    """The append-only audit store (§9) is reachable + writable. The audit log is the
    security + 3am-debug record; an unwritable store loses it. CRITICAL.

    BACKEND-AWARE (same path()-under-firestore class as stores_reachable). audit_dir() /
    audit_path() resolve through the SELECTED backend's path(), which FirestoreBackend
    REFUSES (BackendUnavailable) — there is no local audit dir to stat. So:

      • LOCAL backend  — keep the writable-dir probe (create dir + a throwaway temp file
        we remove; we NEVER read an existing audit row).
      • Non-filesystem backend (firestore) — probe writability with a backend-safe
        read-only op (read_lines of the audit rel proves the backend can serve the store)
        rather than a local-dir stat. PASS when the backend answers; FAIL only on a real
        backend error."""
    import cp_audit
    import cp_state
    try:
        ddir = cp_audit.audit_dir(home)
        apath = cp_audit.audit_path(home)
    except cp_state.BackendUnavailable:
        # Non-filesystem backend: no local audit dir. Reachability is decided by a
        # backend-safe read-only op (read_lines of the audit log rel -> [] when absent).
        backend = cp_state.get_backend(home=home)
        try:
            backend.read_lines("audit/audit.ndjson")
            ok, detail = True, ""
        except Exception as exc:  # noqa: BLE001 — a real backend error -> not reachable.
            ok, detail = False, type(exc).__name__
        return _result(
            "audit_writable",
            critical=True,
            ok=ok,
            status=("firestore: backend probe authoritative, local-dir N/A — audit store "
                    "reachable" if ok else
                    "firestore audit store unreachable: %s" % detail),
            remedy="ensure the selected state backend can initialize and serve, then re-run",
        )
    ok, detail = _probe_writable(ddir)
    return _result(
        "audit_writable",
        critical=True,
        ok=ok,
        status=("audit store is writable" if ok else
                "audit store is NOT writable: %s" % detail),
        remedy="ensure HEIMDALL_HOME is set to a writable path and re-run",
        path=apath,
    )


def check_stores_reachable(home=None):
    """Every durable cp_* state store is reachable: jobs (§4), schedules (§6), approvals
    (§7), notify (§8), observe (§5). CRITICAL — these are the substrate's persistence.

    BACKEND-AWARE (mirrors cp_diag._stores_reachable). Each store's *_dir() accessor
    resolves through the SELECTED backend's path() — and a non-filesystem backend
    (FirestoreBackend) REFUSES path() by design (BackendUnavailable): there is no local dir
    to probe for writability. That refusal is NOT an unreachable-store signal. So:

      • LOCAL backend  — keep the byte-identical writable-dir probe (create dir + a
        throwaway temp file we remove); never read a stored record.
      • Non-filesystem backend (firestore) — do NOT call path()/*_dir(). Probe reachability
        with a cheap, read-only StateBackend op (read_lines of a per-store health rel) that
        proves the backend can SERVE without mutating it. PASS when the backend answers;
        FAIL only on a genuine backend error (the op raises)."""
    import cp_state
    # rel keys for each store (relative to control-plane/) — used ONLY for the backend-safe
    # read-only probe under a non-filesystem backend. Local keeps its writable-dir probe.
    store_rels = {
        "jobs": "jobs/_selfcheck_probe.ndjson",
        "schedules": "schedules/_selfcheck_probe.ndjson",
        "approvals": "approvals/_selfcheck_probe.ndjson",
        "notify": "notify/_selfcheck_probe.ndjson",
        "observe": "observe/_selfcheck_probe.ndjson",
    }
    try:
        import cp_approval
        import cp_ingest
        import cp_jobstore
        import cp_notify
        import cp_scheduler
        dirs = {
            "jobs": cp_jobstore.jobs_dir(home),
            "schedules": cp_scheduler.schedules_dir(home),
            "approvals": cp_approval.approvals_dir(home),
            "notify": cp_notify.notify_dir(home),
            "observe": cp_ingest.observe_dir(home),
        }
    except cp_state.BackendUnavailable:
        # Non-filesystem backend: no local dirs to probe. Reachability is governed by a
        # backend-safe read-only op per store (read_lines of an absent health rel -> []).
        backend = cp_state.get_backend(home=home)
        failed = []
        for name, rel in sorted(store_rels.items()):
            try:
                backend.read_lines(rel)
            except Exception as exc:  # noqa: BLE001 — a real backend error -> unreachable.
                failed.append("%s (%s)" % (name, type(exc).__name__))
        ok = not failed
        return _result(
            "stores_reachable",
            critical=True,
            ok=ok,
            status=("firestore: backend probe authoritative, local-dir N/A — all %d state "
                    "stores reachable: %s"
                    % (len(store_rels), ", ".join(sorted(store_rels))))
            if ok else
            ("firestore backend unreachable for state store(s): %s" % "; ".join(failed)),
            remedy="ensure the selected state backend can initialize and serve, then re-run",
        )
    failed = []
    for name, ddir in sorted(dirs.items()):
        good, detail = _probe_writable(ddir)
        if not good:
            failed.append("%s (%s)" % (name, detail))
    ok = not failed
    return _result(
        "stores_reachable",
        critical=True,
        ok=ok,
        status=("all %d state stores writable: %s"
                % (len(dirs), ", ".join(sorted(dirs))))
        if ok else
        ("unwritable state store(s): %s" % "; ".join(failed)),
        remedy="ensure HEIMDALL_HOME points at a writable filesystem and re-run",
        path=os.path.dirname(dirs["jobs"]),
    )


def check_allowlist_sane():
    """The action-type allowlist (§1, blast-radius control) is non-empty and every
    declared spec resolves. An empty allowlist refuses EVERYTHING; a spec that raises
    on lookup is a latent refusal bug. CRITICAL. Reads only the static allowlist
    declaration — no instance state."""
    import cp_allowlist
    types = cp_allowlist.action_types()
    n = len(types)
    bad = []
    for t in types:
        try:
            # spec_for must resolve for every advertised type; a missing/raising spec
            # is a broken allowlist entry. We do NOT dispatch — pure introspection.
            spec = cp_allowlist.spec_for(t)
            if spec is None:
                bad.append(t)
        except Exception:  # noqa: BLE001 — a raising spec lookup is a broken entry.
            bad.append(t)
    ok = n >= 1 and not bad
    if n == 0:
        status = "allowlist is EMPTY — every dispatch would be refused"
    elif bad:
        status = "%d allowlisted type(s) with a broken spec: %s" % (
            len(bad), ", ".join(sorted(bad)))
    else:
        status = "%d allowlisted action type(s), all specs resolve" % n
    return _result(
        "allowlist_sane",
        critical=True,
        ok=ok,
        status=status,
        remedy="restore the §1 action-type allowlist in cp_allowlist.py",
    )


def check_config_sane(home=None):
    """HEIMDALL_HOME resolves to a usable absolute path and the control-plane subtree
    sits under it. Advisory — surfaces a mis-pointed home before it bites a check
    above. Reports the resolved PATH (a path is not a secret), never env contents.

    BACKEND-AWARE. The "control-plane tree sits under home" check is a LOCAL-FILESYSTEM
    invariant: cp_audit.audit_dir() resolves the on-disk control-plane root through the
    SELECTED backend's path(), which a non-filesystem backend (firestore) REFUSES
    (BackendUnavailable). Under firestore there is no local control-plane tree to locate
    under home, so the layout check does not apply — we assert only that home resolves and
    report that the local-tree check is N/A. We still never crash on path() refusal."""
    import cp_audit
    import cp_state
    import issue_queue
    base = home if home else issue_queue.heimdall_home()
    abspath = os.path.abspath(base) if base else ""
    try:
        cp_root = os.path.dirname(cp_audit.audit_dir(home))  # …/control-plane
    except cp_state.BackendUnavailable:
        # Non-filesystem backend: no local control-plane tree. The layout invariant is
        # filesystem-only; on firestore it does not apply. Sanity = home resolves.
        ok = bool(abspath)
        return _result(
            "config_sane",
            critical=False,
            ok=ok,
            status=("home resolves; control-plane tree is firestore-backed "
                    "(local-tree layout check N/A)" if ok else
                    "HEIMDALL_HOME does not resolve to an absolute path"),
            remedy="set HEIMDALL_HOME to a writable directory (or pass --home)",
            path=abspath,
        )
    under = bool(cp_root) and os.path.abspath(cp_root).startswith(abspath)
    ok = bool(abspath) and under
    return _result(
        "config_sane",
        critical=False,
        ok=ok,
        status=("home resolves and the control-plane tree sits under it" if ok else
                "home/control-plane layout looks off — check HEIMDALL_HOME"),
        remedy="set HEIMDALL_HOME to a writable directory (or pass --home)",
        path=abspath,
    )


def check_notify_egress():
    """The notify connector registry (§8 egress) loads and EVERY registered connector
    answers health() WITHOUT crashing. Advisory + strictly READ-ONLY: an INACTIVE
    connector (absent creds) is fine — that is the documented lazy degrade — we only
    assert the egress layer is wired and introspectable. health()'s contract is
    content-free ({name, active, reason}); we never read or transmit any cred. We
    send NOTHING — no message, no probe request leaves the box."""
    try:
        import connectors
    except Exception as exc:  # noqa: BLE001 — the egress layer failed to import.
        return _result(
            "notify_egress",
            critical=False,
            ok=False,
            status="notify connector layer failed to load: %s" % type(exc).__name__,
            remedy="check the bin/lib/connectors package imports cleanly",
        )
    names = connectors.available()
    active_names = []
    broken = []
    for name in names:
        try:
            h = connectors.get(name).health()
            if isinstance(h, dict) and h.get("active"):
                active_names.append(name)
        except Exception:  # noqa: BLE001 — a connector that crashes on health() is broken.
            broken.append(name)
    if not names:
        # inbox is the always-on in-band channel; zero connectors is a valid layout.
        return _result(
            "notify_egress",
            critical=False,
            ok=True,
            status="no notify connectors registered (inbox-only delivery)",
            remedy="optional: add a connector for an out-of-band egress channel",
        )
    ok = not broken
    if broken:
        status = "connector(s) crash on health(): %s" % ", ".join(sorted(broken))
    else:
        status = "%d connector(s) wired; %d active (%s)" % (
            len(names), len(active_names),
            ", ".join(sorted(active_names)) if active_names else "none configured")
    return _result(
        "notify_egress",
        critical=False,
        ok=ok,
        status=status,
        remedy="configure a connector's creds to activate an egress channel "
               "(optional — inbox delivery always works)",
    )


# ── the orchestrator: run every check, compute the overall verdict ─────────────


def run_all(home=None):
    """Run every self-check against the (optionally overridden) home and return a
    structured, SECRET-FREE report:
        {
          "overall": "pass" | "fail",
          "ok": bool,                       # True iff no CRITICAL check failed
          "critical_failures": [id, ...],   # the critical checks that failed
          "checks": [ <_result>, ... ],     # every check, in a stable order
        }
    `overall`/`ok` are decided by the CRITICAL checks only — an advisory failure is
    reported in its row but does NOT fail the run (the caller exits 0). The whole
    object is safe to print or pipe as JSON: every field is a status/path, never a
    secret value."""
    checks = [
        check_python_runtime(),
        check_crypto_backend(),
        check_pki_key(home),
        check_audit_writable(home),
        check_stores_reachable(home),
        check_allowlist_sane(),
        check_config_sane(home),
        check_notify_egress(),
    ]
    critical_failures = [c["id"] for c in checks if c["critical"] and not c["ok"]]
    ok = not critical_failures
    return {
        "overall": "pass" if ok else "fail",
        "ok": ok,
        "critical_failures": critical_failures,
        "checks": checks,
    }


# ── text rendering (the PASS/FAIL table the operator reads) ────────────────────


def render_table(report):
    """Render run_all()'s report as a human PASS/FAIL table + an overall verdict.
    Pure: takes the structured report, returns a string. Prints status + path only —
    the report it renders is already secret-free by construction."""
    lines = []
    lines.append("Heimdall control-plane self-check")
    lines.append("=" * 60)
    width = max((len(c["id"]) for c in report["checks"]), default=12)
    for c in report["checks"]:
        mark = "PASS" if c["ok"] else "FAIL"
        tag = "  " if c["critical"] else " *"  # '*' marks an advisory (non-critical)
        lines.append("  %s%s  %-*s  %s"
                     % (mark, tag, width, c["id"], c["status"]))
        if not c["ok"]:
            lines.append("        -> remedy: %s" % c["remedy"])
        if c.get("path"):
            lines.append("        path: %s" % c["path"])
    lines.append("-" * 60)
    lines.append("  (* = advisory, non-critical)")
    verdict = "PASS" if report["ok"] else "FAIL"
    if report["ok"]:
        lines.append("overall verdict: %s — all critical checks passed" % verdict)
    else:
        lines.append("overall verdict: %s — critical failure(s): %s"
                     % (verdict, ", ".join(report["critical_failures"])))
    return "\n".join(lines) + "\n"


# ── filesystem probe helper (writability without reading any stored content) ───


def _probe_writable(ddir):
    """Return (ok, detail). Probe a store dir by ensuring it exists (create it) and
    writing+removing a throwaway temp file. We NEVER read an existing file in the
    dir — only prove we COULD write one. `detail` is a short, secret-free reason on
    failure ('' on success)."""
    try:
        os.makedirs(ddir, exist_ok=True)
    except OSError as exc:
        return False, "cannot create dir (%s)" % exc.strerror
    if not os.access(ddir, os.W_OK):
        return False, "dir not writable"
    probe = os.path.join(ddir, ".selfcheck.%d.tmp" % os.getpid())
    try:
        with open(probe, "w", encoding="utf-8") as fh:
            fh.write("ok")
            fh.flush()
    except OSError as exc:
        return False, "cannot write (%s)" % exc.strerror
    finally:
        _quiet_remove(probe)
    return True, ""


def _quiet_remove(path):
    """Remove `path`, swallowing a missing-file/permission error — the probe file is
    throwaway, its cleanup must never mask the check's real result."""
    try:
        os.remove(path)
    except OSError:
        return False
    return True
