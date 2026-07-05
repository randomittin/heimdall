#!/usr/bin/env python3
# maintain_loop.py — the DURABLE maintainer AUTOPILOT engine. The real engine
# behind `bin/heimdall-maintain-loop`.
#
# It WRAPS the honest issue-resolution engine (bin/lib/issue_loop.py :: run_once —
# pick -> orient(SI-1) -> fix -> GATE -> attest(SI-2) -> [PR | flagged]); it adds
# NO new resolution primitive and NEVER edits issue_loop.py / issue_pr.py. What it
# adds is the survivability the raw `/loop` lacks:
#
#   • a BUDGET CAP  — before every cycle it reads the authoritative session token
#     meter (bin/heimdall-tokens session) against `.maintainer.budget_tokens`
#     (default 600000). Over cap -> STOP(budget). A missing/unreadable meter is
#     treated as NEAR-CAP (STOP) — the loop NEVER runs blind on tokens.
#   • STOP CONDITIONS — empty pickable queue -> STOP(empty-queue); budget hit ->
#     STOP(budget); N consecutive GATE_FAILED/ERRORED on DISTINCT issues (default
#     3) -> STOP(repeated-failure). The loop can never run away.
#   • an APPROVAL PARK — an approval-required issue (severity >= threshold) with no
#     recorded decision is PARKED (flagged 'approval-wait') and the loop CONTINUES
#     with the others; one gated issue never blocks the whole loop.
#   • BACKPRESSURE — concurrent fixers are capped through the existing bin/agent-pool
#     (best-effort; the loop is single-threaded so it acquires/releases one slot per
#     cycle and never fails when the pool is absent).
#   • a CHECKPOINT RECEIPT — every transition appends a machine-readable
#     `<!-- heimdall-autopilot ... -->` header block to .planning/CHECKPOINT.md so a
#     brand-new session (post death / compaction) can read exactly where it was and
#     whether to re-arm.
#
# The verdict for a cycle is READ from issue_loop's result state (which itself reads
# ONLY the recorded real exit — the cardinal rule); this engine NEVER self-reports a
# fix as done. Its own honesty rule: it can never CLAIM to have run under budget — a
# meter it cannot read is a STOP, not a guess.
#
# This is a LIBRARY (pure-ish orchestration + thin subprocess seams). The bash CLI
# (bin/heimdall-maintain-loop) owns argv + stdout shape (house style — same split as
# heimdall-issue-loop over issue_loop.py).

from __future__ import annotations

import json
import os
import re
import subprocess
import sys
import time

_HERE = os.path.dirname(os.path.abspath(__file__))
if _HERE not in sys.path:
    sys.path.insert(0, _HERE)

import issue_queue  # piece (b); the queue store we peek + park through
import issue_loop  # piece (c); the honest resolution engine we WRAP (never edit)


# ── defaults + stop reasons (dossier: the run-away guards) ────────────────────

DEFAULT_BUDGET_TOKENS = 600000
DEFAULT_MAX_FAILURES = 3
DEFAULT_APPROVAL_SEVERITY = "critical"

STOP_BUDGET = "budget"
STOP_EMPTY = "empty-queue"
STOP_REPEATED = "repeated-failure"
STOP_APPROVAL = "approval-wait"   # per-issue park verdict (not a run-terminal stop)
STOP_DISABLED = "disabled"        # maintainer switched off — the loop never runs

# the stop reasons that mean the WHOLE run is terminally done (no re-arm).
_TERMINAL_STOPS = (STOP_BUDGET, STOP_EMPTY, STOP_REPEATED, STOP_DISABLED)


# ── rr CONTEXT HANDOFF: INGEST the local-session capsule into the fix prompt ───
#
# The rr (remote-run) handoff ships a secret-scrubbed capsule of the LOCAL session
# (bin/heimdall-context-capsule) to this VM at ~/.heimdall/rr-context/<slug>/
# context.md. When present, we PREPEND it — as a clearly-delimited, READ-ONLY
# LOCAL SESSION CONTEXT block — to the fix cycle's prompt (the fix brief body the
# coder consumes), so the cloud bot works with continuity of the prior decisions/
# state instead of cold. It is a BRIEFING, not instructions: the issue is still the
# task; the context only informs it. Injection is BOUNDED (trimmed if huge).

CONTEXT_BLOCK_HEADER = "LOCAL SESSION CONTEXT (read-only briefing)"
DEFAULT_CONTEXT_MAX_BYTES = 16000


def _rr_home():
    """The runtime home the shipped capsule lands under: HEIMDALL_HOME, else
    ~/.heimdall (matches where bin/heimdall-context-capsule ships)."""
    return os.environ.get("HEIMDALL_HOME") or os.path.join(
        os.path.expanduser("~"), ".heimdall"
    )


def _repo_slug(repo):
    """Best-effort OWNER/REPO -> owner__repo slug from the repo's git remote, or
    None. Mirrors bin/heimdall-context-capsule's `tr '/:' '__'` convention."""
    try:
        proc = subprocess.run(
            ["git", "-C", repo, "config", "--get", "remote.origin.url"],
            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True,
        )
    except OSError:
        return None
    url = (proc.stdout or "").strip()
    if not url:
        return None
    slug = re.sub(r"^[a-z]+\+?[a-z]*://", "", url)
    slug = re.sub(r"^git@", "", slug)
    slug = re.sub(r"github\.com[:/]", "", slug)
    slug = re.sub(r"\.git$", "", slug).rstrip("/")
    if "/" not in slug:
        return None
    # Match bin/heimdall-context-capsule's `tr '/:' '__'` — each of / and : -> one _.
    return slug.replace("/", "_").replace(":", "_")


def resolve_context_path(repo, explicit=None):
    """Resolve the local-session-context capsule to PREPEND, or None.

    Precedence: an explicit --context FILE wins; else the HEIMDALL_RR_CONTEXT env
    override; else AUTO-DETECT the shipped capsule under
    ${HEIMDALL_HOME:-~/.heimdall}/rr-context/<slug>/context.md — preferring the dir
    matching this repo's git remote slug, and falling back to the sole capsule when
    exactly one exists. Any miss (no file / ambiguous) -> None (no injection, the
    loop runs exactly as before)."""
    if explicit:
        return explicit if os.path.isfile(explicit) else None
    env = os.environ.get("HEIMDALL_RR_CONTEXT")
    if env:
        return env if os.path.isfile(env) else None
    base = os.path.join(_rr_home(), "rr-context")
    if not os.path.isdir(base):
        return None
    slug = _repo_slug(repo)
    if slug:
        cand = os.path.join(base, slug, "context.md")
        if os.path.isfile(cand):
            return cand
    hits = []
    for name in sorted(os.listdir(base)):
        cand = os.path.join(base, name, "context.md")
        if os.path.isfile(cand):
            hits.append(cand)
    return hits[0] if len(hits) == 1 else None


def load_context(path, max_bytes=DEFAULT_CONTEXT_MAX_BYTES):
    """Read + BOUND the capsule to max_bytes (a briefing, never a dump). Keeps the
    head (the briefing header + freshest state) and appends an honest truncation
    marker. Returns None on an unreadable/empty file."""
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as fh:
            text = fh.read()
    except OSError:
        return None
    if not text.strip():
        return None
    enc = text.encode("utf-8")
    if len(enc) > max_bytes:
        text = enc[:max_bytes].decode("utf-8", errors="ignore")
        text += ("\n\n[...local-session context trimmed to %d bytes for bounded "
                 "injection...]" % max_bytes)
    return text


def render_context_block(text):
    """Wrap the capsule in a clearly-delimited, READ-ONLY briefing block. It is
    CONTEXT, not instructions — the fix prompt makes that explicit so the cloud bot
    treats the issue as the task and the block only as prior state."""
    bar = "=" * 72
    return (
        "%s\n%s\n%s\n"
        "This is a READ-ONLY briefing of the LOCAL Heimdall session that preceded\n"
        "this cloud run. It is CONTEXT for continuity, NOT instructions — the issue\n"
        "below is the task; use this only to stay consistent with prior decisions\n"
        "and state.\n"
        "%s\n%s\n%s\n"
        % (bar, CONTEXT_BLOCK_HEADER, bar, bar, text.rstrip("\n"), bar)
    )


def resolve_context_block(repo, explicit=None, max_bytes=DEFAULT_CONTEXT_MAX_BYTES):
    """The end-to-end resolve: path -> bounded text -> rendered block, or None when
    no capsule is available. Returns (block, path) so callers can surface the path."""
    path = resolve_context_path(repo, explicit)
    if not path:
        return None, None
    text = load_context(path, max_bytes=max_bytes)
    if not text:
        return None, None
    return render_context_block(text), path


def make_context_fix_runner(context_block, inner=None):
    """Return a fix_runner that PREPENDS the context block to the issue body the fix
    brief carries, then delegates to the inner runner (default: the real
    issue_loop.default_fix_runner — we never edit it). The injected brief's body
    literally BEGINS with the LOCAL SESSION CONTEXT block, then the issue — so the
    cloud bot reads the prior state first, the task second."""
    inner = inner or issue_loop.default_fix_runner

    def _runner(issue, orient_result, repo):
        merged = dict(issue)
        merged["body"] = context_block + "\n\n" + (issue.get("body") or "")
        return inner(merged, orient_result, repo)

    return _runner


# ── tool locators (the sibling bins we REUSE, never reimplement) ──────────────


def _bindir():
    """bin/ — this lib lives at bin/lib/maintain_loop.py, so bin/ is one up."""
    return os.path.dirname(_HERE)


def _tokens_bin():
    """The authoritative session token meter. An env seam lets tests substitute a
    hermetic fake meter without a live transcript."""
    return os.environ.get("HEIMDALL_TOKENS_BIN") or os.path.join(
        _bindir(), "heimdall-tokens"
    )


def _agent_pool_bin():
    return os.environ.get("HEIMDALL_AGENT_POOL_BIN") or os.path.join(
        _bindir(), "agent-pool"
    )


def _state_bin():
    return os.environ.get("HEIMDALL_STATE_BIN") or os.path.join(
        _bindir(), "heimdall-state"
    )


def _gh_app_token_bin():
    """bin/heimdall-gh-app-token — the GitHub-App INSTALLATION-token minter. An env seam
    lets tests substitute a hermetic fake minter (no live App / network)."""
    return os.environ.get("HEIMDALL_GH_APP_TOKEN_BIN") or os.path.join(
        _bindir(), "heimdall-gh-app-token"
    )


# ── the DEDICATED BOT credential per cycle (GitHub App token, PAT fallback) ────
#
# A GitHub App INSTALLATION token EXPIRES AFTER 1 HOUR, so a static token cannot back a
# long-running loop. When App creds are configured (HEIMDALL_GH_APP_ID set), we MINT A
# FRESH installation token EACH CYCLE via bin/heimdall-gh-app-token and export it as
# HEIMDALL_PR_BOT_TOKEN — so issue_pr.gh_bot_runner (which reads that env) authenticates
# `gh` as the App's bot identity, unchanged. When App creds are ABSENT we keep the
# static HEIMDALL_PR_BOT_TOKEN (a fine-grained PAT) — the simpler fallback. The minted
# token is NEVER logged; only a token-free credential-path label is surfaced.


def mint_pr_bot_token():
    """Mint a fresh GitHub-App installation token via bin/heimdall-gh-app-token, or
    None when App creds are not configured / the mint fails. NEVER logs the token — on
    failure it emits only a token-free reason line so the caller can fall back."""
    if not os.environ.get("HEIMDALL_GH_APP_ID"):
        return None
    tok_bin = _gh_app_token_bin()
    try:
        proc = subprocess.run(
            [tok_bin],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
    except OSError as exc:
        sys.stderr.write(
            "maintain-loop: gh-app token minter unavailable (%s); falling back to the "
            "static HEIMDALL_PR_BOT_TOKEN if present\n" % exc
        )
        return None
    if proc.returncode != 0:
        # the minter already printed a key-free diagnostic to ITS stderr; surface a
        # one-line, token-free note and let the caller fall back.
        sys.stderr.write(
            "maintain-loop: gh-app token mint failed (rc=%d); falling back to the "
            "static HEIMDALL_PR_BOT_TOKEN if present\n" % proc.returncode
        )
        return None
    token = (proc.stdout or "").strip()
    return token or None


def apply_pr_bot_token():
    """Per-cycle credential resolution. If App creds are configured, mint a fresh
    installation token and EXPORT it as HEIMDALL_PR_BOT_TOKEN (so issue_pr opens the PR
    as the App bot). Else leave any static HEIMDALL_PR_BOT_TOKEN (PAT) in place. Returns
    the active credential path: 'app' | 'static' | 'none'. The token is never logged."""
    token = mint_pr_bot_token()
    if token:
        os.environ["HEIMDALL_PR_BOT_TOKEN"] = token
        return "app"
    return "static" if os.environ.get("HEIMDALL_PR_BOT_TOKEN") else "none"


# ── state file (mirrors bin/heimdall-state resolution) ────────────────────────


def _state_file(repo):
    """The heimdall-state.json this loop reads/writes. Prefers HEIMDALL_STATE_FILE
    (the same env bin/heimdall-state honors), then <repo>/heimdall-state.json, then
    a cwd file — so the loop agrees with the CLI about where state lives."""
    explicit = os.environ.get("HEIMDALL_STATE_FILE")
    if explicit:
        return explicit
    cand = os.path.join(repo, "heimdall-state.json")
    if os.path.isfile(cand):
        return cand
    if os.path.isfile("heimdall-state.json"):
        return os.path.abspath("heimdall-state.json")
    return cand


def _read_state(repo):
    """Load the state dict, or {} when absent/unreadable (never raises)."""
    try:
        with open(_state_file(repo), "r", encoding="utf-8") as fh:
            data = json.load(fh)
    except (FileNotFoundError, ValueError, OSError):
        return {}
    return data if isinstance(data, dict) else {}


def _maintainer(state):
    m = state.get("maintainer")
    return m if isinstance(m, dict) else {}


def is_enabled(state):
    """True ONLY when maintainer.enabled is explicitly True. A missing key is OFF —
    the loop never auto-runs on an unconfigured repo. This is the LOCAL-workstation gate
    for UNATTENDED / scheduled cycles (kept OFF by default); an EXPLICIT rr-task dispatch
    authorizes independently via the run() `explicit` arg, and an operator via env_enabled()."""
    return _maintainer(state).get("enabled") is True


# The operator ENV override: authorizes cycles to run WITHOUT a local heimdall-state.json
# enable flag. Documented belt-and-suspenders to the per-dispatch `explicit` authorization.
MAINTAINER_ENABLED_ENV = "HEIMDALL_MAINTAINER_ENABLED"
_ENABLED_TRUTHY = {"1", "true", "yes", "on"}


def env_enabled():
    """Operator ENV override: HEIMDALL_MAINTAINER_ENABLED set truthy (1/true/yes/on)
    authorizes cycles to run WITHOUT a local heimdall-state.json enable flag. This is the
    documented, GLOBAL always-on an operator opts a box into deliberately — the belt-and-
    suspenders to the PRIMARY per-dispatch `explicit` authorization (which the gated drain
    sets per rr task). Unset / "" / "0" / "false" -> off (the loop keeps the OFF-by-default
    local-enable gate for unattended cycles — it never auto-runs on an unconfigured repo)."""
    raw = os.environ.get(MAINTAINER_ENABLED_ENV)
    if not raw:
        return False
    return raw.strip().lower() in _ENABLED_TRUTHY


def resolve_cap(state, override=None):
    """The token budget cap: an explicit override (CLI --budget-tokens) wins; else
    `.maintainer.budget_tokens`; else the 600000 default."""
    if override is not None:
        return int(override)
    val = _maintainer(state).get("budget_tokens")
    if isinstance(val, (int, float)) and val > 0:
        return int(val)
    return DEFAULT_BUDGET_TOKENS


# ── the BUDGET meter read (authoritative; fail-safe = STOP, never run blind) ───


def measure_tokens(repo):
    """Read the REAL session token usage from bin/heimdall-tokens (the authoritative
    meter). Returns (used_tokens, cost_usd, ok).

    ok is False whenever the meter is UNAVAILABLE for ANY reason — the binary is
    missing, the call fails, the output is unparseable, or the record carries an
    `error` (a degraded read). An ok=False read is treated by the caller as
    NEAR-CAP -> STOP: the loop NEVER runs blind on tokens (the honesty rule)."""
    meter = _tokens_bin()
    cwd = os.environ.get("HEIMDALL_TOKENS_CWD") or repo
    try:
        proc = subprocess.run(
            [meter, "session", "--cwd", cwd],
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
        )
    except OSError:
        return (None, None, False)  # binary missing / not executable -> near-cap
    if proc.returncode != 0:
        return (None, None, False)  # a usage error (bad flags) -> near-cap
    try:
        rec = json.loads(proc.stdout)
    except (ValueError, TypeError):
        return (None, None, False)
    if not isinstance(rec, dict) or rec.get("error"):
        return (None, None, False)  # degraded record -> treat as unreadable
    used = rec.get("total_tokens")
    if not isinstance(used, (int, float)):
        return (None, None, False)
    cost = rec.get("total_cost_usd")
    cost = cost if isinstance(cost, (int, float)) else None
    return (int(used), cost, True)


def budget_state(repo, cap):
    """The budget snapshot for a cycle: {cap_tokens, used, cost_usd_est, over}.
    over is True when used >= cap OR the meter is unreadable (fail-safe STOP)."""
    used, cost, ok = measure_tokens(repo)
    if not ok:
        return {
            "cap_tokens": cap,
            "used": None,
            "cost_usd_est": None,
            "over": True,
            "meter": "unavailable",
        }
    return {
        "cap_tokens": cap,
        "used": used,
        "cost_usd_est": cost,
        "over": used >= cap,
        "meter": "ok",
    }


# ── APPROVAL gate (park-and-continue; never block the whole loop) ─────────────


def _approval_severity(state, cfg):
    """The severity at/above which an issue needs a human decision before a fix. An
    env seam + cfg override; default 'critical'."""
    env = os.environ.get("HEIMDALL_APPROVAL_SEVERITY")
    if env:
        return env
    m = _maintainer(state)
    if m.get("approval_severity"):
        return m["approval_severity"]
    cfg_v = ((cfg or {}).get("maintainer") or {}).get("approval_severity")
    return cfg_v or DEFAULT_APPROVAL_SEVERITY


def requires_approval(issue, state, cfg):
    """True when the issue's severity is at/above the approval threshold — such an
    issue must not be auto-fixed without a recorded human decision (dossier: the
    Critical x Any route requires human approval)."""
    sev = (issue.get("priority_signal") or {}).get("severity")
    thr = _approval_severity(state, cfg)
    return issue_queue.SEVERITY_RANK.get(sev, 0) >= issue_queue.SEVERITY_RANK.get(
        thr, issue_queue.SEVERITY_RANK["critical"]
    )


def has_decision(issue_id, state):
    """True when a human decision for this issue has been recorded — in
    `.maintainer.autopilot.approvals` (a list of approved ids) or the
    HEIMDALL_APPROVED_IDS env seam (comma-separated). No decision -> the issue is
    parked, never auto-fixed."""
    ap = ((_maintainer(state).get("autopilot") or {}).get("approvals")) or []
    approved = set(x for x in ap if isinstance(x, str))
    env = os.environ.get("HEIMDALL_APPROVED_IDS", "")
    approved |= set(x.strip() for x in env.split(",") if x.strip())
    return issue_id in approved


# ── BACKPRESSURE: cap concurrent fixers through bin/agent-pool (best-effort) ───


def _pool_acquire(cycle):
    """Claim a fixer slot from the shared agent-pool so concurrent maintainer loops
    (or a maintainer alongside a build) never exceed the pool's max. Best-effort:
    an absent/uninitialized pool is a NO-OP (returns a slot id or None), and this
    NEVER fails the loop. When the pool is at capacity it blocks briefly on
    `agent-pool wait` then retries once."""
    pool = _agent_pool_bin()
    slot = "maintain-fixer-%d" % cycle
    try:
        proc = subprocess.run(
            [pool, "acquire", slot, "fixer"],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
    except OSError:
        return None  # pool binary absent -> backpressure is a no-op
    if proc.returncode == 2:
        # at capacity — wait for a slot (bounded by agent-pool's own timeout), retry.
        try:
            subprocess.run([pool, "wait"], stdout=subprocess.DEVNULL,
                           stderr=subprocess.DEVNULL)
            proc = subprocess.run(
                [pool, "acquire", slot, "fixer"],
                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
            )
        except OSError:
            return None
    return slot if proc.returncode == 0 else None


def _pool_release(slot):
    """Release a previously-claimed fixer slot. Best-effort + never raises."""
    if not slot:
        return
    pool = _agent_pool_bin()
    try:
        subprocess.run([pool, "release", slot], stdout=subprocess.DEVNULL,
                       stderr=subprocess.DEVNULL)
    except OSError:
        return  # a pool release fault must never fail the loop


# ── queue snapshot (for the checkpoint block) ─────────────────────────────────


def _queue_counts(repo):
    """The queue buckets for the checkpoint header: pending(=queued)/in_flight/
    flagged/resolved. Read fresh so the block reflects post-cycle truth."""
    s = issue_queue.IssueQueue(repo=repo).status()
    return {
        "pending": s.get("queued", 0),
        "in_flight": s.get("in_flight", 0),
        "flagged": s.get("flagged", 0),
        "resolved": s.get("resolved", 0),
    }


def _peek_queued(repo, cfg):
    """The queued issues in pick order (highest priority first), read-only — this
    does NOT claim anything (unlike pick())."""
    q = issue_queue.IssueQueue(repo=repo)
    return [row["issue"] for row in q.list_issues(cfg, state=issue_queue.STATE_QUEUED)]


# ── the CHECKPOINT receipt (machine-readable transition header) ───────────────


def _planning_dir(repo, override=None):
    return override or os.path.join(repo, ".planning")


def _checkpoint_path(planning_dir):
    return os.path.join(planning_dir, "CHECKPOINT.md")


def render_block(cycle, budget, queue, last, stop, tally, next_action):
    """Render ONE machine-readable autopilot header block. Every value after
    `key: ` is valid JSON, so a fresh session parses it deterministically."""
    budget_out = {
        "cap_tokens": budget.get("cap_tokens"),
        "used": budget.get("used"),
        "cost_usd_est": budget.get("cost_usd_est"),
    }
    lines = [
        "<!-- heimdall-autopilot",
        "cycle: %s" % json.dumps(cycle),
        "budget: %s" % json.dumps(budget_out, sort_keys=True),
        "queue: %s" % json.dumps(queue, sort_keys=True),
        "last: %s" % json.dumps(last, sort_keys=True),
        "stop: %s" % json.dumps(stop),
        "tally: %s" % json.dumps(tally, sort_keys=True),
        "next: %s" % json.dumps(next_action),
        "-->",
    ]
    return "\n".join(lines) + "\n"


def append_checkpoint(planning_dir, block):
    """Append a header block to .planning/CHECKPOINT.md (creating the dir/file).
    Append-only: the transition history is a durable audit trail."""
    os.makedirs(planning_dir, exist_ok=True)
    path = _checkpoint_path(planning_dir)
    header = ""
    if not os.path.exists(path):
        header = "# Heimdall Autopilot Checkpoint\n\n"
    with open(path, "a", encoding="utf-8") as fh:
        fh.write(header + block + "\n")


def parse_last_block(planning_dir):
    """Parse the LAST autopilot header block from CHECKPOINT.md into a dict. Each
    `key: <json>` line is decoded; a non-JSON value is kept as a raw string.
    Returns None when no block exists."""
    path = _checkpoint_path(planning_dir)
    try:
        with open(path, "r", encoding="utf-8") as fh:
            text = fh.read()
    except (FileNotFoundError, OSError):
        return None
    marker = "<!-- heimdall-autopilot"
    idx = text.rfind(marker)
    if idx < 0:
        return None
    seg = text[idx + len(marker):]
    end = seg.find("-->")
    if end >= 0:
        seg = seg[:end]
    out = {}
    for line in seg.splitlines():
        line = line.strip()
        if not line or ":" not in line:
            continue
        key, _, val = line.partition(":")
        key = key.strip()
        val = val.strip()
        try:
            out[key] = json.loads(val)
        except (ValueError, TypeError):
            out[key] = val
    return out or None


# ── the HEARTBEAT receipt (one line, rendered from the last checkpoint block) ──


def _short_issue(iid):
    """Compact an issue id for the heartbeat: github:acme/widget#412 -> gh-412."""
    if not iid or not isinstance(iid, str):
        return "—"  # em dash
    src, _, rest = iid.partition(":")
    tag = {"github": "gh", "slack": "sl", "email": "em"}.get(src, (src or "?")[:2])
    if "#" in rest:
        num = rest.rsplit("#", 1)[-1]
    elif "." in rest:
        num = rest.rsplit(".", 1)[-1]
    else:
        num = rest or "?"
    return "%s-%s" % (tag, num)


def _pct(used, cap):
    if isinstance(used, (int, float)) and isinstance(cap, (int, float)) and cap > 0:
        return str(int(used * 100 / cap))
    return "?"


def heartbeat_line(planning_dir):
    """Render the last checkpoint block as ONE line, e.g.
    'autopilot: cycle 47 · 12 fixed · 2 flagged · 1 PR · budget 36% · last PASS gh-412'.
    A missing checkpoint renders an honest sentinel (never a fabricated number)."""
    block = parse_last_block(planning_dir)
    if not block:
        return "autopilot: no checkpoint yet"
    cyc = block.get("cycle", 0)
    tally = block.get("tally") or {}
    budget = block.get("budget") or {}
    last = block.get("last") or {}
    if not isinstance(tally, dict):
        tally = {}
    if not isinstance(budget, dict):
        budget = {}
    if not isinstance(last, dict):
        last = {}
    pct = _pct(budget.get("used"), budget.get("cap_tokens"))
    verdict = last.get("verdict") or "—"
    issue = _short_issue(last.get("issue"))
    return (
        "autopilot: cycle %s · %d fixed · %d flagged · %d PR "
        "· budget %s%% · last %s %s"
        % (
            cyc,
            int(tally.get("fixed", 0) or 0),
            int(tally.get("flagged", 0) or 0),
            int(tally.get("pr", 0) or 0),
            pct,
            verdict,
            issue,
        )
    )


# ── the RESUME hint (only when it is honest to re-arm) ────────────────────────


def resume_hint(repo, planning_dir):
    """Return the re-arm line for a fresh SessionStart, or None. It fires ONLY when
    ALL hold:
      • the last checkpoint's stop is null (the loop PAUSED with work remaining —
        not a terminal budget/empty-queue/repeated-failure stop), AND
      • `.maintainer.enabled` is True, AND
      • budget remains (the last read used < cap; an unreadable read never re-arms).
    Any miss -> None (SessionStart stays quiet — the loop does not auto-resurrect a
    finished or over-budget run)."""
    state = _read_state(repo)
    if not is_enabled(state):
        return None
    block = parse_last_block(planning_dir)
    if not block:
        return None
    stop = block.get("stop", None)
    if stop is not None:
        return None  # a terminal stop (or any non-null pause reason) — do not re-arm
    budget = block.get("budget") or {}
    if not isinstance(budget, dict):
        return None
    used = budget.get("used")
    cap = budget.get("cap_tokens")
    if not (isinstance(used, (int, float)) and isinstance(cap, (int, float))):
        return None  # meter was unreadable -> never re-arm blind
    if used >= cap:
        return None
    pct = _pct(used, cap)
    return (
        "autopilot armed — work remains (budget %s%% used). "
        "Re-arm: /loop 30m /hmd:maintain-check" % pct
    )


# ── autopilot state persistence (best-effort; via bin/heimdall-state) ─────────


def _persist_autopilot(repo, cycle, stop, heartbeat):
    """Record the loop's terminal position into `.maintainer.autopilot` via
    bin/heimdall-state (so it honors the state lock). Best-effort: a failure here
    NEVER fails the loop — the checkpoint file is the durable source of truth."""
    state_file = _state_file(repo)
    if not os.path.isfile(state_file):
        return
    payload = json.dumps(
        {"cycle": cycle, "stop": stop, "last_heartbeat": heartbeat},
        sort_keys=True,
    )
    env = dict(os.environ)
    env["HEIMDALL_STATE_FILE"] = state_file
    try:
        subprocess.run(
            [_state_bin(), "autopilot-set-all", payload],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, env=env,
        )
    except OSError:
        return  # persistence is advisory; the checkpoint file remains authoritative


# ── the AUTOPILOT run loop (drives issue_loop.run_once cycle-by-cycle) ─────────


def _verdict(state_name):
    """Map an issue_loop result state to a compact heartbeat verdict."""
    if state_name == issue_loop.PR_OPEN:
        return "PASS"
    if state_name == issue_loop.GATE_FAILED:
        return "FAIL"
    if state_name == issue_loop.ERRORED:
        return "ERROR"
    if state_name == issue_loop.IDLE:
        return "IDLE"
    return state_name or "—"


def run(repo, base="HEAD", evidence_cmds=None, cfg=None, max_cycles=0,
        cap_override=None, max_failures=None, planning_dir=None, fix_runner=None,
        context_file=None, context_max_bytes=DEFAULT_CONTEXT_MAX_BYTES,
        explicit=False):
    """Drive the autopilot loop over the honest engine (issue_loop.run_once).

    One CYCLE = one budget-gated, approval-gated, backpressured issue_loop.run_once.
    The loop STOPS on the first run-away guard that trips (budget / empty-queue /
    repeated-failure) or pauses when --max is reached (stop=null -> re-armable).

    explicit: the DEPLOYED-SHAPE AUTHORIZATION. When True, the cycle originates from an
    EXPLICIT rr task a user signed + submitted (the gated drain sets it) — that submission
    IS the authorization, so the loop runs WITHOUT a local heimdall-state.json enable flag
    (which never exists in the ephemeral Cloud Run Job container). When False (unattended /
    scheduled cycles), the loop keeps the OFF-by-default local-enable gate (is_enabled) — it
    NEVER auto-runs on an unconfigured repo (the safety property is preserved).

    context_file: the rr LOCAL-SESSION-CONTEXT capsule to PREPEND to each fix cycle's
    prompt (a read-only briefing). When None, the shipped capsule is auto-detected
    under ~/.heimdall/rr-context/<slug>/context.md; when neither exists the loop runs
    EXACTLY as before (the injection is purely additive — no regression).

    Returns a summary dict {cycles, stop, tally, last, budget, results}. Every
    transition is durably appended to .planning/CHECKPOINT.md."""
    repo = os.path.abspath(repo)
    state = _read_state(repo)
    planning_dir = _planning_dir(repo, planning_dir)
    cap = resolve_cap(state, cap_override)
    if max_failures is None:
        max_failures = DEFAULT_MAX_FAILURES

    # ── rr CONTEXT INGEST: resolve the local-session briefing and, when present,
    #    wrap the fix slot so every cycle's prompt is PREPENDED with it. Absent -> no
    #    change (the loop is byte-identical to before).
    context_block, context_path = resolve_context_block(
        repo, context_file, max_bytes=context_max_bytes
    )
    if context_block is not None:
        fix_runner = make_context_fix_runner(context_block, inner=fix_runner)

    tally = {"fixed": 0, "flagged": 0, "parked": 0, "pr": 0}
    last = None
    budget = {"cap_tokens": cap, "used": None, "cost_usd_est": None, "over": None}
    results = []
    cycle = 0
    fail_streak = 0
    stop = None

    # ── AUTHORIZATION — the maintainer must be authorized before the loop runs. THREE
    #    independent authorizations (the deployed-shape design):
    #      • explicit=True — the cycle originates from an EXPLICIT rr task the user signed +
    #        submitted, which the gated drain dispatched. That submission IS the
    #        authorization, so the loop runs WITHOUT a local heimdall-state.json enable flag
    #        (which never exists in the ephemeral Cloud Run Job container — THE deployed-shape
    #        gap this fixes: the enable flag was a local-workstation concept).
    #      • env_enabled() — HEIMDALL_MAINTAINER_ENABLED, a documented operator ENV override.
    #      • is_enabled(state) — the LOCAL-workstation enable flag (OFF by default): the
    #        UNATTENDED / scheduled path keeps this safety gate, so the loop NEVER auto-runs
    #        on an unconfigured repo (the safety property is preserved).
    if not (explicit or env_enabled() or is_enabled(state)):
        return {
            "cycles": 0,
            "stop": STOP_DISABLED,
            "tally": tally,
            "last": None,
            "budget": budget,
            "results": [],
            "note": ("maintainer is not enabled (.maintainer.enabled != true, no --explicit "
                     "rr-task authorization, no HEIMDALL_MAINTAINER_ENABLED)"),
        }

    def emit(next_action, stop_reason):
        """Append one checkpoint block reflecting the current position."""
        block = render_block(
            cycle, budget, _queue_counts(repo), last, stop_reason, tally,
            next_action,
        )
        append_checkpoint(planning_dir, block)

    while True:
        # ── BUDGET gate (before ANY work — the can't-burn-tokens guarantee) ───
        budget = budget_state(repo, cap)
        if budget["over"]:
            stop = STOP_BUDGET
            reason = ("budget cap %d reached (used %s)"
                      % (cap, budget.get("used")))
            emit("stopped: " + reason, stop)
            break

        # ── peek the queue (read-only) — empty pickable set -> STOP ───────────
        queued = _peek_queued(repo, cfg)
        if not queued:
            stop = STOP_EMPTY
            emit("stopped: queue empty (nothing pickable)", stop)
            break

        # ── APPROVAL gate — park a gated issue and CONTINUE with the others ───
        top = queued[0]
        top_id = top["id"]
        if requires_approval(top, state, cfg) and not has_decision(top_id, state):
            issue_queue.IssueQueue(repo=repo).flag(
                top_id, STOP_APPROVAL, evidence_ref="needs-human-decision"
            )
            tally["parked"] += 1
            last = {"issue": top_id, "verdict": "PARKED", "pr": None, "cycle_ms": 0}
            emit("parked %s (needs human approval); continue" % top_id, None)
            continue  # a park is not a cycle, not a failure — keep draining others

        # ── DEDICATED BOT credential: mint a FRESH App installation token for THIS
        #    cycle (App creds set) or keep the static PAT. The 1-hour App-token expiry
        #    is why this is per-cycle. issue_pr reads HEIMDALL_PR_BOT_TOKEN unchanged.
        apply_pr_bot_token()

        # ── BACKPRESSURE: claim a fixer slot (best-effort) ────────────────────
        slot = _pool_acquire(cycle)
        t0 = time.time()
        result = issue_loop.run_once(
            repo, base=base, evidence_cmds=evidence_cmds, cfg=cfg,
            fix_runner=fix_runner,
        )
        cycle_ms = int((time.time() - t0) * 1000)
        _pool_release(slot)

        st = result.get("state")
        issue = result.get("issue") or {}
        results.append(result)

        # a run_once that found nothing pickable (raced-empty) -> empty-queue.
        if st == issue_loop.IDLE:
            stop = STOP_EMPTY
            last = {"issue": None, "verdict": "IDLE", "pr": None,
                    "cycle_ms": cycle_ms}
            emit("stopped: queue empty (nothing pickable)", stop)
            break

        cycle += 1
        pr = None
        if st == issue_loop.PR_OPEN:
            tally["fixed"] += 1
            if result.get("pr_opened"):
                tally["pr"] += 1
            pr = (result.get("gate") or {}).get("evidence_ref") \
                or ("pr-ready:" + issue.get("id", ""))
            fail_streak = 0
        else:  # GATE_FAILED or ERRORED — an honest failure (never a PR)
            tally["flagged"] += 1
            fail_streak += 1

        last = {
            "issue": issue.get("id"),
            "verdict": _verdict(st),
            "pr": pr,
            "cycle_ms": cycle_ms,
        }

        # ── REPEATED-FAILURE guard (distinct issues — pick never re-picks) ────
        if fail_streak >= max_failures:
            stop = STOP_REPEATED
            emit("stopped: %d consecutive failures on distinct issues"
                 % fail_streak, stop)
            break

        # ── normal per-cycle checkpoint (stop still null — more to do) ─────────
        emit("run cycle %d" % (cycle + 1), None)

        # ── --max pause: NOT terminal (stop=null) -> re-armable next session ──
        if max_cycles and cycle >= max_cycles:
            stop = None
            emit("paused: --max %d reached (work may remain)" % max_cycles, None)
            break

    heartbeat = heartbeat_line(planning_dir)
    _persist_autopilot(repo, cycle, stop, heartbeat)
    summary = {
        "cycles": cycle,
        "stop": stop,
        "tally": tally,
        "last": last,
        "budget": budget,
        "results": results,
        "heartbeat": heartbeat,
    }
    if context_block is not None:
        summary["context"] = {
            "path": context_path,
            "bytes": len(context_block.encode("utf-8")),
            "prepended": True,
            "block_header": CONTEXT_BLOCK_HEADER,
        }
    return summary


def plan(repo, base="HEAD", cfg=None, cap_override=None, context_file=None,
         context_max_bytes=DEFAULT_CONTEXT_MAX_BYTES):
    """Read-only DRY-RUN: what the next drain WOULD do, without touching anything.
    Reads the budget + the queued issues (pick order) and classifies each into the
    action it WOULD take (park for approval vs fix+gate+PR). Mutates NOTHING.

    When an rr LOCAL-SESSION-CONTEXT capsule resolves (explicit --context or the
    auto-detected shipped capsule), the plan surfaces a `context` block showing the
    read-only briefing that WOULD be prepended to each fix prompt. When no capsule is
    present the output is byte-identical to before (no `context` key)."""
    repo = os.path.abspath(repo)
    state = _read_state(repo)
    cap = resolve_cap(state, cap_override)
    budget = budget_state(repo, cap)
    enabled = is_enabled(state)
    queued = _peek_queued(repo, cfg)
    plan_rows = []
    for iss in queued:
        if requires_approval(iss, state, cfg) and not has_decision(iss["id"], state):
            action = "WOULD: park for human approval (approval-wait)"
        else:
            action = "WOULD: fix + GATE + PR (via issue-loop run-once)"
        plan_rows.append({
            "issue": iss["id"],
            "severity": (iss.get("priority_signal") or {}).get("severity"),
            "action": action,
        })
    would_stop = None
    if not enabled:
        would_stop = STOP_DISABLED
    elif budget["over"]:
        would_stop = STOP_BUDGET
    elif not queued:
        would_stop = STOP_EMPTY
    out = {
        "enabled": enabled,
        "budget": {
            "cap_tokens": budget.get("cap_tokens"),
            "used": budget.get("used"),
            "cost_usd_est": budget.get("cost_usd_est"),
            "over": budget.get("over"),
        },
        "queue": _queue_counts(repo),
        "plan": plan_rows,
        "would_stop": would_stop,
    }
    # rr CONTEXT INGEST (additive): only present when a capsule resolves, so a run
    # WITHOUT a shipped/explicit capsule keeps the exact prior output shape.
    context_block, context_path = resolve_context_block(
        repo, context_file, max_bytes=context_max_bytes
    )
    if context_block is not None:
        out["context"] = {
            "path": context_path,
            "bytes": len(context_block.encode("utf-8")),
            "prepended": True,
            "block_header": CONTEXT_BLOCK_HEADER,
            "block_preview": context_block[:600],
        }
    return out


# ── CLI core (driven by bin/heimdall-maintain-loop) ───────────────────────────


def _load_cfg(cfg_arg):
    if not cfg_arg:
        return {}
    if cfg_arg.startswith("@"):
        with open(cfg_arg[1:], "r", encoding="utf-8") as fh:
            return json.load(fh)
    return json.loads(cfg_arg)


def _cli(argv):
    """CLI core. Subcommands:
      run         [--repo R] [--base REF] [--evidence CMD]... [--config C]
                  [--max N] [--budget-tokens N] [--max-failures N]
                  [--planning-dir D] [--print]
      plan        [--repo R] [--base REF] [--config C] [--budget-tokens N]
      heartbeat   [--repo R] [--planning-dir D]
      resume-hint [--repo R] [--planning-dir D]
      status      [--repo R]     (delegates to issue-loop status + the budget)
    Prints JSON/plain to stdout, human notes to stderr; returns an exit code."""
    import argparse

    p = argparse.ArgumentParser(prog="heimdall-maintain-loop", add_help=True)
    p.add_argument("subcommand")
    p.add_argument("--repo", default=os.getcwd())
    p.add_argument("--base", default="HEAD")
    p.add_argument("--evidence", action="append", default=[])
    p.add_argument("--config")
    p.add_argument("--max", type=int, default=0)
    p.add_argument("--budget-tokens", dest="budget_tokens", type=int, default=None)
    p.add_argument("--max-failures", dest="max_failures", type=int, default=None)
    p.add_argument("--planning-dir", dest="planning_dir", default=None)
    p.add_argument("--print", dest="do_print", action="store_true")
    # rr CONTEXT HANDOFF: the local-session briefing to PREPEND to each fix prompt.
    # Omitted -> auto-detect the shipped capsule; absent -> unchanged behavior.
    p.add_argument("--context", dest="context", default=None,
                   help="local-session-context capsule to prepend to each fix prompt")
    p.add_argument("--context-max-bytes", dest="context_max_bytes", type=int,
                   default=DEFAULT_CONTEXT_MAX_BYTES,
                   help="bound the injected context to N bytes (default %d)"
                        % DEFAULT_CONTEXT_MAX_BYTES)
    p.add_argument("--dry-run", dest="dry_run", action="store_true",
                   help="on run: print the plan (incl. context) and execute nothing")
    # AUTHORIZATION: the gated drain passes --explicit for a cycle from a signed rr task, so
    # the loop runs WITHOUT a local heimdall-state.json enable flag (absent in the ephemeral
    # job container). Unattended/scheduled runs OMIT it and keep the OFF-by-default gate.
    p.add_argument("--explicit", dest="explicit", action="store_true",
                   help="authorize this cycle WITHOUT a local enable flag (the gated drain "
                        "sets this for an explicit rr task; unattended runs omit it)")
    args = p.parse_args(argv)

    repo = os.path.abspath(args.repo)
    cfg = _load_cfg(args.config)
    pdir = _planning_dir(repo, args.planning_dir)

    if args.subcommand == "run":
        # --dry-run makes `run` a read-only preview (incl. the context that WOULD be
        # prepended): print the plan, execute/mutate nothing.
        if args.dry_run:
            out = plan(repo, base=args.base, cfg=cfg,
                       cap_override=args.budget_tokens, context_file=args.context,
                       context_max_bytes=args.context_max_bytes)
            print(json.dumps(out, indent=2, sort_keys=True))
            return 0
        summary = run(
            repo, base=args.base, evidence_cmds=args.evidence, cfg=cfg,
            max_cycles=args.max, cap_override=args.budget_tokens,
            max_failures=args.max_failures, planning_dir=args.planning_dir,
            context_file=args.context, context_max_bytes=args.context_max_bytes,
            explicit=args.explicit,
        )
        print(json.dumps(summary, indent=2, sort_keys=True))
        t = summary.get("tally") or {}
        sys.stderr.write(
            "maintain-loop run: %d cycle(s), stop=%s (fixed=%d flagged=%d "
            "parked=%d pr=%d)\n"
            % (
                summary.get("cycles", 0),
                summary.get("stop"),
                t.get("fixed", 0), t.get("flagged", 0),
                t.get("parked", 0), t.get("pr", 0),
            )
        )
        return 0

    if args.subcommand == "plan":
        out = plan(repo, base=args.base, cfg=cfg, cap_override=args.budget_tokens,
                   context_file=args.context,
                   context_max_bytes=args.context_max_bytes)
        print(json.dumps(out, indent=2, sort_keys=True))
        return 0

    if args.subcommand == "heartbeat":
        print(heartbeat_line(pdir))
        return 0

    if args.subcommand == "resume-hint":
        line = resume_hint(repo, pdir)
        if line:
            print(line)
        return 0

    if args.subcommand == "status":
        st = issue_loop.status(repo)
        state = _read_state(repo)
        cap = resolve_cap(state, args.budget_tokens)
        st["budget"] = budget_state(repo, cap)
        st["autopilot"] = parse_last_block(pdir)
        print(json.dumps(st, indent=2, sort_keys=True))
        return 0

    sys.stderr.write("error: unknown subcommand: %s\n" % args.subcommand)
    return 2


if __name__ == "__main__":
    sys.exit(_cli(sys.argv[1:]))
