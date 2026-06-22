#!/usr/bin/env python3
# issue_config.py — piece (e) of the issue-resolution loop: config loading +
# CREDENTIAL RESOLUTION (the auth surface). Pure library; the CLI is
# bin/heimdall-issue-config. Mirrors the house style of bin/lib/attestation.py
# (gitignored runtime home, no baked paths) and bin/lib/redum.py (pure functions).
#
# ─ SECURITY CONTRACT (this module is the credential surface; auditor reviews it) ─
#   • Creds resolve ONLY from environment variables NAMED by the committed config
#     (`token_env` / `password_env` hold the env-var NAME, never the value), OR
#     from an explicitly gitignored secrets file (.heimdall/issue-loop.secrets.json,
#     already covered by the .heimdall/ gitignore). A token literal NEVER lands in
#     a committed file.
#   • A resolved credential is NEVER logged, echoed, returned by `show`, or placed
#     in any structure that a CLI prints. `connector_state()` returns a BOOLEAN
#     `cred_present`, never the secret. The only function that returns the secret
#     itself is `resolve_cred()`, whose value the loop hands straight to a
#     connector's `configure()` and nowhere else.
#   • LAZY / OPTIONAL (the MarkItDown clean-install contract): an absent config,
#     an absent connector block, or an absent credential makes that connector
#     simply INACTIVE — never a crash, never an abort. With NO connectors active
#     the loop is INERT (`is_inert()` -> True). The base install + stranger-test
#     stay green because nothing here hard-fails on missing config.
#
# This layer does NOT import the connectors registry (piece a): it is the config
# side of the seam. It tells the loop WHICH connectors are active and resolves
# the creds the loop feeds into `connectors.get(name).configure(cfg)`. Keeping it
# import-independent lets pieces (a) and (e) build in parallel without collision.

from __future__ import annotations

import json
import os
from typing import Any, Dict, List, Optional

# Committed config filename + its committed example. The REAL file is gitignored
# (covered by the .heimdall/ rule); only the .example is committed, carrying
# example (non-secret) values.
CONFIG_BASENAME = "issue-loop.config.json"
EXAMPLE_BASENAME = "issue-loop.config.json.example"
# Optional gitignored secrets file (an alternative to env vars). Lives under the
# already-gitignored .heimdall/ home, so it can never be committed.
SECRETS_BASENAME = "issue-loop.secrets.json"

# Prioritization defaults (section 3 of the design dossier). A config may override
# any weight; absent weights fall back to these.
DEFAULT_WEIGHTS = {"severity": 3, "age": 1, "source": 1}
# In-scope defaults: an empty label allowlist means "no label filter" (every issue
# is in scope by label); max_body_chars caps the body the fix task is briefed with.
DEFAULT_MAX_BODY_CHARS = 8000

# The per-connector key naming the ENV VAR that holds its credential. We accept the
# two the dossier names (token_env, password_env) plus a generic cred_env, so a new
# connector kind need not invent a third convention. The VALUE of this config key
# is the NAME of an env var — never the secret.
_CRED_ENV_KEYS = ("token_env", "password_env", "cred_env")


# ── home / path resolution (gitignored runtime, no baked paths) ────────────────


def heimdall_home(repo: str) -> str:
    """The runtime home: ${HEIMDALL_HOME:-<repo>/.heimdall}. Mirrors
    heimdall-attest's store_dir() exactly so config, attestations and the queue
    all live under the SAME gitignored home and relocate together."""
    explicit = os.environ.get("HEIMDALL_HOME")
    if explicit:
        return explicit
    return os.path.join(repo, ".heimdall")


def config_path(repo: str) -> str:
    """Absolute path to the REAL (gitignored) committed-structure config."""
    return os.path.join(heimdall_home(repo), CONFIG_BASENAME)


def example_path(repo: str) -> str:
    """Absolute path to the committed EXAMPLE config (example values only). The
    example is committed at <repo>/.heimdall/<EXAMPLE_BASENAME>; it is NOT under
    the gitignored home override, so it is found relative to the repo."""
    return os.path.join(repo, ".heimdall", EXAMPLE_BASENAME)


def secrets_path(repo: str) -> str:
    """Absolute path to the optional gitignored secrets file."""
    return os.path.join(heimdall_home(repo), SECRETS_BASENAME)


# ── config loading (lazy / optional — absent config NEVER crashes) ─────────────


def load_config(repo: str, path: Optional[str] = None) -> Dict[str, Any]:
    """Load the issue-loop config. Lazy/optional contract: an ABSENT or malformed
    config returns the empty-but-valid inert shape, never raises — so the loop is
    inert (not broken) on a clean install.

    repo: the repository root (used to resolve the default config path + home).
    path: an explicit config file to load; defaults to config_path(repo).

    Returns a dict with at least {"connectors": {}, "prioritization": {...},
    "in_scope": {...}} — always safe to index. A connector block that the file
    omits simply isn't there; the loop then treats that connector as inactive."""
    target = path or config_path(repo)
    raw: Dict[str, Any] = {}
    try:
        with open(target, "r", encoding="utf-8") as fh:
            loaded = json.load(fh)
        if isinstance(loaded, dict):
            raw = loaded
    except FileNotFoundError:
        raw = {}
    except (OSError, ValueError):
        # Malformed/unreadable config must NOT brick the loop — degrade to inert,
        # exactly like a missing file. The loop reports inert, the user fixes it.
        raw = {}
    return _normalize_config(raw)


def _normalize_config(raw: Dict[str, Any]) -> Dict[str, Any]:
    """Fill the inert defaults so callers can always index the result. Never
    mutates `raw`."""
    connectors = raw.get("connectors")
    if not isinstance(connectors, dict):
        connectors = {}

    prioritization = raw.get("prioritization")
    if not isinstance(prioritization, dict):
        prioritization = {}
    weights = prioritization.get("weights")
    if not isinstance(weights, dict):
        weights = {}
    merged_weights = dict(DEFAULT_WEIGHTS)
    for k, v in weights.items():
        if isinstance(v, (int, float)):
            merged_weights[k] = v
    source_priority = prioritization.get("source_priority")
    if not isinstance(source_priority, dict):
        source_priority = {}

    in_scope = raw.get("in_scope")
    if not isinstance(in_scope, dict):
        in_scope = {}
    labels = in_scope.get("labels")
    if not isinstance(labels, list):
        labels = []
    labels = [str(x) for x in labels]
    max_body = in_scope.get("max_body_chars")
    if not isinstance(max_body, int) or max_body <= 0:
        max_body = DEFAULT_MAX_BODY_CHARS

    return {
        "connectors": connectors,
        "prioritization": {
            "weights": merged_weights,
            "source_priority": source_priority,
        },
        "in_scope": {"labels": labels, "max_body_chars": max_body},
    }


# ── credential resolution (THE auth surface — never logged, never committed) ────


def _cred_env_name(conn_cfg: Dict[str, Any]) -> Optional[str]:
    """The NAME of the env var holding this connector's credential, from the
    committed config. Returns the name string, or None when the connector
    declares no credential key. This reads only the env-var NAME — never a
    secret."""
    if not isinstance(conn_cfg, dict):
        return None
    for key in _CRED_ENV_KEYS:
        val = conn_cfg.get(key)
        if isinstance(val, str) and val.strip():
            return val.strip()
    return None


def resolve_cred(
    conn_cfg: Dict[str, Any],
    env: Optional[Dict[str, str]] = None,
    secrets: Optional[Dict[str, Any]] = None,
) -> Optional[str]:
    """Resolve a connector's credential VALUE, or None when it is absent.

    Resolution order (most-trusted first), value NEVER committed:
      1) the environment variable NAMED by the config's *_env key (the primary,
         committed-config-driven path),
      2) the gitignored secrets file keyed by that same env-var name (an explicit
         opt-in alternative for hosts that prefer a file over env vars).

    conn_cfg: the per-connector config block (holds the env-var NAME).
    env:     the environment mapping (defaults to os.environ) — injectable so a
             test resolves from a controlled env, not the host's.
    secrets: the parsed gitignored secrets file mapping (env-var-name -> token),
             or None. Caller supplies it via load_secrets(); this function never
             reads a file itself, keeping it pure + testable.

    SECURITY: the returned value is the live credential. The caller (the loop)
    hands it straight to a connector's configure() — it must NOT be logged,
    printed, or stored. There is intentionally no code path here that writes the
    returned value anywhere."""
    environ = os.environ if env is None else env

    env_name = _cred_env_name(conn_cfg)
    if env_name:
        val = environ.get(env_name)
        if val is not None and val != "":
            return val

    # Fallback: the gitignored secrets file, keyed by the connector's declared
    # env-var name. Only consulted when the env var did not resolve. The secrets
    # file itself can never be committed (it lives under the gitignored
    # .heimdall/ home).
    if secrets and env_name:
        file_val = secrets.get(env_name)
        if isinstance(file_val, str) and file_val != "":
            return file_val
    return None


def load_secrets(repo: str, path: Optional[str] = None) -> Dict[str, Any]:
    """Load the OPTIONAL gitignored secrets file as a mapping, or {} when absent.
    Lazy/optional: a missing or malformed secrets file is simply {} (no crash) —
    creds then resolve from env only. The returned mapping is env-var-NAME ->
    secret-value; the loop never persists it, and no CLI prints it."""
    target = path or secrets_path(repo)
    try:
        with open(target, "r", encoding="utf-8") as fh:
            loaded = json.load(fh)
        if isinstance(loaded, dict):
            return loaded
    except FileNotFoundError:
        return {}
    except (OSError, ValueError):
        return {}
    return {}


# ── connector activeness (lazy/optional — absent cred -> inactive, no crash) ────


def connector_state(
    name: str,
    conn_cfg: Dict[str, Any],
    env: Optional[Dict[str, str]] = None,
    secrets: Optional[Dict[str, Any]] = None,
) -> Dict[str, Any]:
    """Decide a single connector's state WITHOUT ever exposing its credential.

    Returns {
      "name": str,
      "configured": bool,    # present in config AND active:true (operator intent)
      "cred_present": bool,  # a credential RESOLVED (env or secrets file) — NOT
                             # the value, only its presence
      "active": bool,        # configured AND cred_present — the loop uses this
      "reason": str|None,    # why inactive, for honest operator feedback
    }

    The lazy/optional contract lives here: a connector that is configured but
    whose credential env is absent comes back active=False with a clear reason —
    it is simply skipped, never a crash. `cred_present` is a boolean precisely so
    that no caller can accidentally surface the secret."""
    cfg = conn_cfg if isinstance(conn_cfg, dict) else {}
    configured = bool(cfg.get("active", False))
    cred = resolve_cred(cfg, env=env, secrets=secrets)
    cred_present = cred is not None
    # Drop the local reference promptly; we only ever needed its presence.
    del cred

    if not configured:
        active = False
        reason = "not configured (connector block absent or active:false)"
    elif not cred_present:
        env_name = _cred_env_name(cfg) or "<no *_env declared>"
        active = False
        reason = "credential absent (env %s unset and no secrets entry)" % env_name
    else:
        active = True
        reason = None

    return {
        "name": name,
        "configured": configured,
        "cred_present": cred_present,
        "active": active,
        "reason": reason,
    }


def connector_states(
    cfg: Dict[str, Any],
    env: Optional[Dict[str, str]] = None,
    secrets: Optional[Dict[str, Any]] = None,
) -> List[Dict[str, Any]]:
    """The state of EVERY connector named in the config, sorted by name for
    deterministic output. Safe on an empty config (returns [])."""
    connectors = cfg.get("connectors") if isinstance(cfg, dict) else None
    if not isinstance(connectors, dict):
        return []
    out = []
    for name in sorted(connectors):
        out.append(connector_state(name, connectors[name], env=env, secrets=secrets))
    return out


def active_connectors(
    cfg: Dict[str, Any],
    env: Optional[Dict[str, str]] = None,
    secrets: Optional[Dict[str, Any]] = None,
) -> List[str]:
    """Sorted names of connectors that are configured AND have a resolved
    credential. This is what the loop iterates. An empty config OR every
    connector cred-less -> []."""
    return [s["name"] for s in connector_states(cfg, env=env, secrets=secrets) if s["active"]]


def is_inert(
    cfg: Dict[str, Any],
    env: Optional[Dict[str, str]] = None,
    secrets: Optional[Dict[str, Any]] = None,
) -> bool:
    """True when NO connector is active — the loop is inert (nothing to pick,
    nothing to do). The clean-install / stranger-test state: an absent or
    connector-less config is inert, and the loop exits 0 doing nothing."""
    return not active_connectors(cfg, env=env, secrets=secrets)


# ── prioritization + in-scope (config knobs the loop reads) ────────────────────


def prioritization(cfg: Dict[str, Any]) -> Dict[str, Any]:
    """The prioritization knobs with defaults applied: {weights, source_priority}.
    Safe on any (even empty) config — load_config already normalized it."""
    pri = cfg.get("prioritization") if isinstance(cfg, dict) else None
    if not isinstance(pri, dict):
        return {"weights": dict(DEFAULT_WEIGHTS), "source_priority": {}}
    weights = pri.get("weights")
    if not isinstance(weights, dict):
        weights = dict(DEFAULT_WEIGHTS)
    source_priority = pri.get("source_priority")
    if not isinstance(source_priority, dict):
        source_priority = {}
    return {"weights": dict(weights), "source_priority": dict(source_priority)}


def in_scope(issue: Dict[str, Any], cfg: Dict[str, Any]) -> bool:
    """True when a normalized issue is in scope per config's in_scope filter:
      • label gate: if a label allowlist is configured (non-empty), the issue
        must carry at least one allowlisted label; an EMPTY allowlist means no
        label gate (every issue passes the label check).
      • size gate: the issue body must not exceed max_body_chars.
    An absent in_scope config means everything within the default size cap is in
    scope (honest default — never silently drops an issue)."""
    scope = cfg.get("in_scope") if isinstance(cfg, dict) else None
    if not isinstance(scope, dict):
        scope = {}

    labels = scope.get("labels")
    if not isinstance(labels, list):
        labels = []
    allow = {str(x) for x in labels}
    if allow:
        issue_labels = set()
        raw_labels = issue.get("labels")
        if isinstance(raw_labels, list):
            issue_labels = {str(x) for x in raw_labels}
        if not (issue_labels & allow):
            return False

    max_body = scope.get("max_body_chars")
    if not isinstance(max_body, int) or max_body <= 0:
        max_body = DEFAULT_MAX_BODY_CHARS
    body = issue.get("body")
    if isinstance(body, str) and len(body) > max_body:
        return False

    return True


# ── operator-facing view (NEVER carries a credential value) ────────────────────


def redacted_view(
    cfg: Dict[str, Any],
    env: Optional[Dict[str, str]] = None,
    secrets: Optional[Dict[str, Any]] = None,
) -> Dict[str, Any]:
    """A safe, printable view of the resolved config for `issue-config show`. It
    carries connector states (booleans + reasons), the prioritization knobs, and
    the in-scope filter — but NEVER a credential value. The only credential-
    adjacent field is `cred_present` (a boolean) and the env-var NAME the
    connector reads from (a name, not a secret). This is the structure the CLI
    prints, so the no-leak guarantee is enforced here, structurally."""
    connectors = cfg.get("connectors") if isinstance(cfg, dict) else {}
    if not isinstance(connectors, dict):
        connectors = {}

    states = connector_states(cfg, env=env, secrets=secrets)
    by_name = {s["name"]: s for s in states}

    conn_view = []
    for name in sorted(connectors):
        block = connectors[name] if isinstance(connectors[name], dict) else {}
        st = by_name.get(name, {})
        conn_view.append({
            "name": name,
            "configured": st.get("configured", False),
            "active": st.get("active", False),
            "cred_present": st.get("cred_present", False),
            # the NAME of the env var (not its value) — safe to print.
            "cred_env": _cred_env_name(block),
            "reason": st.get("reason"),
            # non-secret routing knobs, echoed for operator visibility.
            "repo": block.get("repo"),
            "channel": block.get("channel"),
            "mailbox": block.get("mailbox"),
            "source_priority": _source_priority_for(cfg, name),
        })

    return {
        "connectors": conn_view,
        "active": active_connectors(cfg, env=env, secrets=secrets),
        "inert": is_inert(cfg, env=env, secrets=secrets),
        "prioritization": prioritization(cfg),
        "in_scope": cfg.get("in_scope", {"labels": [], "max_body_chars": DEFAULT_MAX_BODY_CHARS}),
    }


def _source_priority_for(cfg: Dict[str, Any], name: str) -> int:
    pri = prioritization(cfg)
    sp = pri.get("source_priority", {})
    val = sp.get(name)
    return val if isinstance(val, int) else 0


def validate(
    cfg: Dict[str, Any],
    env: Optional[Dict[str, str]] = None,
    secrets: Optional[Dict[str, Any]] = None,
) -> Dict[str, Any]:
    """Validate the config WITHOUT failing on the lazy/optional cases. Returns
    {ok, problems, warnings}. A config that is merely inert (no active connector)
    is VALID (ok=True) — inert is a legitimate clean-install state, not an error.
    Genuine problems (a connector active:true that declares NO *_env key, so its
    credential can never resolve) are reported. Warnings flag configured-but-
    credless connectors (the operator likely forgot to export the env var)."""
    problems: List[str] = []
    warnings: List[str] = []

    connectors = cfg.get("connectors") if isinstance(cfg, dict) else {}
    if not isinstance(connectors, dict):
        connectors = {}

    for name in sorted(connectors):
        block = connectors[name] if isinstance(connectors[name], dict) else {}
        configured = bool(block.get("active", False))
        if not configured:
            continue
        env_name = _cred_env_name(block)
        if not env_name:
            problems.append(
                "connector %r is active:true but declares no credential env key "
                "(one of token_env/password_env/cred_env) — its credential can "
                "never resolve" % name
            )
            continue
        st = connector_state(name, block, env=env, secrets=secrets)
        if not st["cred_present"]:
            warnings.append(
                "connector %r is active:true but env %s is unset (and no secrets "
                "entry) — it will run INACTIVE until the credential is provided"
                % (name, env_name)
            )

    return {"ok": not problems, "problems": problems, "warnings": warnings}
