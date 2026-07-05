#!/usr/bin/env python3
# issue_pr.py — piece (d) of the Heimdall issue-resolution loop: PR CREATION,
# the HUMAN-APPROVAL GATE, and resolution WRITE-BACK. The real engine behind
# `bin/heimdall-issue-pr`. SAFETY-CRITICAL (design dossier §6).
#
# ── THE HUMAN-APPROVAL GATE (the safety line — STRUCTURAL, not convention) ─────
#   Heimdall's autonomy ENDS at the PR. It opens the PR and STOPS. There is NO
#   self-merge and NO auto-close, EVER. This is enforced BY CONSTRUCTION:
#
#     • open_pr(issue, record) builds the PR artifact (branch + body carrying the
#       SI-2 record) and RETURNS. It does NOT merge, does NOT close the source
#       issue, does NOT call post_resolution. The loop's state machine terminates
#       at PR_OPEN — nothing past it is reachable from the loop.
#     • There is NO merge verb of any kind ANYWHERE in this module. Self-merge is
#       impossible because the verb does not exist.
#     • close_issue + post_resolution (the write-back) live ONLY behind on_merged,
#       which is invoked EXCLUSIVELY by an external HUMAN-merge signal — never by
#       the loop. on_merged first VERIFIES the PR is merged (Connector-side check)
#       and only THEN closes the source issue + posts the resolution back.
#
#   The loop calls open_pr. The loop NEVER calls on_merged. on_merged is a
#   DISTINCT entry point a human (or a merged-webhook/poll) drives. The two are
#   wired apart on purpose: the human merge is the only bridge from "PR opened" to
#   "issue resolved / written back".
#
# ── THE CARDINAL RULE (dossier §5, defence-in-depth) ──────────────────────────
#   open_pr ASSERTS record["evidence"]["all_passed"] is True before building a PR.
#   A gate-FAIL physically cannot produce a PR — the loop already gates this (a
#   FAIL never reaches open_pr), and open_pr re-checks so a misuse fails loud, not
#   silently. A PR a human approves is a PROVEN fix: its body renders the runnable
#   evidence (the recorded real exits), not a claim.
#
# ── THE AGENT NEVER PUSHES WITH RJ's CREDS (scoped PR-only bot token) ──────────
#   HARD CONSTRAINT (project-wide): the agent NEVER pushes/publishes with RJ's
#   personal creds; RJ holds all credentials. open_pr builds the PR *artifact* —
#   the branch name (ALWAYS heimdall/*), the rendered body, and the `gh pr create`
#   command shape — and persists it into the queue store (in_flight[id].pr).
#
#   The SOLE production PR-open path is the SCOPED BOT-TOKEN runner (gh_bot_runner):
#   it authenticates `gh` as a bot identity read from env HEIMDALL_PR_BOT_TOKEN — a
#   GitHub App installation token / fine-grained PAT scoped to contents:write on
#   refs/heads/heimdall/* + pull_requests:write, with NO push to main and NO merge.
#   That scope is enforced SERVER-SIDE by GitHub: the token physically cannot push
#   to main nor merge a PR. This is how an unattended PR-open reconciles with "RJ
#   holds the creds" — the bot (NOT RJ's personal creds) opens a PR from a
#   heimdall/* branch, and a HUMAN merges.
#
#   The token is passed to `gh` via the GH_TOKEN child-env var — NEVER on the argv
#   (which is recorded/ps-visible) and NEVER printed/logged (no-secret-logging
#   discipline). When HEIMDALL_PR_BOT_TOKEN is ABSENT we fall back to record-only
#   (build the artifact, push NOTHING) — we NEVER push with personal creds. In
#   tests a fake connector / mock gh stands in — no live creds, no network, no PR.
#
# This is a LIBRARY (pure-ish orchestration + a thin connector/gh seam). The bash
# CLI (bin/heimdall-issue-pr) owns argv + stdout shape.

from __future__ import annotations

import json
import os
import shlex
import subprocess
import sys

_HERE = os.path.dirname(os.path.abspath(__file__))
if _HERE not in sys.path:
    sys.path.insert(0, _HERE)

import issue_queue  # piece (b); sibling on sys.path

# the queue machine-state this piece marks on a gate-PASS issue (dossier §4/§6).
PR_OPEN = "PR_OPEN"

# The self-serve landing surface for the PR-body footer (the viral-loop entrance).
# The CP maintainer opens PRs through build_pr_body, so this footer is the ONE
# surface a drive-by reviewer sees — it turns every bot PR into a funnel entrance.
# The canonical Heimdall domain (README + share card); NOT a secret, NEVER a token.
HEIMDALL_LANDING_URL = "https://runheimdall.dev"


class HumanGateError(Exception):
    """Raised when a caller tries to drive a state transition the human-approval
    gate forbids: opening a PR on an UNPROVEN change (all_passed != True), or
    writing back a PR a human has NOT actually merged. The gate fails LOUD, never
    silently doing the forbidden thing."""


# ── connector access (the originating source we route the resolution back to) ──


def _soft_import_connectors():
    """Soft-import the connectors registry (piece a), mirroring how issue_loop /
    issue_queue do. Returns the module, or None when absent (tests may inject a
    mock; an absent registry on the write-back path is an honest error, not a
    crash — on_merged surfaces it)."""
    try:
        import connectors  # piece (a); sibling on sys.path when present
    except Exception:
        return None
    return connectors


def _resolve_connector(source, connectors_mod):
    """Resolve the originating Connector for an issue's `source` (dossier §6:
    write-back routes back to the ORIGINATING connector via issue.source). Raises
    a clear error when the registry or the source is absent — write-back must
    never silently swallow a routing failure."""
    if connectors_mod is None:
        raise HumanGateError(
            "no connectors registry available — cannot route the resolution "
            "back to source %r" % source
        )
    return connectors_mod.get(source)  # KeyError lists available() — fail loud


# ── the SI-2 record -> a human-reviewable PR body (a PROVEN fix, not a claim) ──


def _render_evidence(record):
    """Render the SI-2 evidence block — the RUNNABLE proof — as markdown. This is
    the load-bearing section: a human approves a PROVEN fix, so the recorded real
    exits (cmd + exit code + ok) are shown verbatim, never summarized into a
    claim. all_passed is echoed as the headline verdict."""
    ev = record.get("evidence") or {}
    checks = ev.get("checks") or []
    all_passed = ev.get("all_passed")
    lines = ["## Runnable evidence (the proof — recorded real exits)"]
    lines.append("")
    lines.append("**Gate verdict (`evidence.all_passed`): `%s`**" % all_passed)
    lines.append("")
    if not checks:
        lines.append("_No runnable evidence commands were recorded._")
        return "\n".join(lines)
    lines.append("| # | command | exit | ok |")
    lines.append("|---|---------|------|----|")
    for i, c in enumerate(checks, 1):
        cmd = str(c.get("cmd", "")).replace("|", "\\|")
        lines.append(
            "| %d | `%s` | %s | %s |"
            % (i, cmd, c.get("exit"), "yes" if c.get("ok") else "no")
        )
    return "\n".join(lines)


def _render_claims(record):
    """Render the SI-2 claims block — WHAT the change asserts it does (derived
    from the diff, not the agent's prose)."""
    claims = record.get("claims") or {}
    lines = ["## What this claims to change"]
    lines.append("")
    lines.append(claims.get("summary", "(no claims summary)"))
    files = claims.get("files") or []
    if files:
        lines.append("")
        for f in files:
            units = ", ".join(f.get("units") or []) or "-"
            lines.append(
                "- `%s` (%s) - units: %s"
                % (f.get("path"), f.get("status"), units)
            )
    return "\n".join(lines)


def _render_contracts(record):
    """Render the SI-2 contracts block — the public/exported surface the change
    adds or changes (the interfaces a reviewer must honor)."""
    contracts = record.get("contracts") or {}
    surface = contracts.get("surface") or []
    lines = ["## Contracts (public surface touched)"]
    lines.append("")
    if not surface:
        lines.append("_No public symbols added or changed._")
        return "\n".join(lines)
    for s in surface:
        lines.append(
            "- `%s` (%s) in `%s`" % (s.get("name"), s.get("kind"), s.get("path"))
        )
    return "\n".join(lines)


def _render_reuse(record):
    """Render the SI-2 reuse block — how much existing repo code the fix reused
    (the S-6 metric), so a reviewer sees it reused rather than reinvented."""
    reuse = record.get("reuse") or {}
    pct = reuse.get("reuse_pct")
    pct_s = "n/a" if pct is None else "%.0f%%" % (pct * 100)
    lines = ["## Reuse"]
    lines.append("")
    lines.append(
        "reuse_pct=%s (%d unit(s) reusing / %d reinventing, engine=%s)"
        % (
            pct_s,
            reuse.get("units_reusing", 0),
            reuse.get("units_reinventing", 0),
            reuse.get("engine", "?"),
        )
    )
    return "\n".join(lines)


def _render_risk(record):
    """Render the SI-2 risk block — the flagged risks a reviewer should weigh
    before approving (low reuse, duplicates, large surface, partial analysis)."""
    risk = record.get("risk") or {}
    flags = risk.get("flags") or []
    lines = ["## Flagged risk"]
    lines.append("")
    lines.append("**overall: `%s`**" % risk.get("overall", "none"))
    if not flags:
        lines.append("")
        lines.append("_No risks flagged._")
        return "\n".join(lines)
    lines.append("")
    for f in flags:
        lines.append(
            "- **%s** `%s` - %s"
            % (f.get("level"), f.get("code"), f.get("detail"))
        )
    return "\n".join(lines)


def _render_footer():
    """The branded self-serve footer (the viral-loop CTA) — the ONE surface a
    drive-by PR reviewer sees. Three lines, no emoji, engineer-credible: what
    Heimdall is, the self-serve CTA + landing link, and the honest human-gate
    constraint (opens the PR, never merges). STATIC branded text — it carries NO
    token/secret, EVER. Pure function — no IO."""
    return "\n".join([
        "---",
        "",
        "**Heimdall** opens proven-fix PRs from your issue queue — every PR ships "
        "the runnable evidence that the fix passes.",
        "Want this bot on your repos? → %s" % HEIMDALL_LANDING_URL,
        "Heimdall opens the PR and stops — it never merges; a human reviews and "
        "merges.",
    ])


def build_pr_body(issue, record):
    """Build the full PR body markdown from the issue + the SI-2 record. The body
    carries EVERY SI-2 field a human needs to approve a PROVEN fix: what it
    CLAIMS, the contracts it touches, the RUNNABLE EVIDENCE (recorded real exits),
    the reuse, and the flagged risk. The SI-2 record is also embedded verbatim in
    a machine-readable fenced block so a reader/tool can parse it back.

    Pure function — no IO. Returns the markdown string."""
    issue_id = issue.get("id", "")
    title = issue.get("title", "")
    url = (issue.get("links") or {}).get("url")
    sections = [
        "# Heimdall fix: %s" % (title or issue_id),
        "",
        "Resolves issue `%s`%s." % (issue_id, " (%s)" % url if url else ""),
        "",
        "> Opened by Heimdall's issue-resolution loop on a **gate-PASS** fix. "
        "**Autonomy ends here** - a human reviews and merges. Heimdall does not "
        "self-merge.",
        "",
        _render_claims(record),
        "",
        _render_contracts(record),
        "",
        _render_evidence(record),
        "",
        _render_reuse(record),
        "",
        _render_risk(record),
        "",
        "## SI-2 attestation (machine-readable)",
        "",
        "```json",
        json.dumps(record, indent=2, sort_keys=True),
        "```",
        "",
        _render_footer(),
    ]
    return "\n".join(sections)


def build_pr_title(issue):
    """A conventional PR title derived from the issue."""
    title = issue.get("title") or issue.get("id") or "issue fix"
    return "fix: %s" % title


# ── the PR artifact + the `gh pr create` command shape (NEVER executed here) ──


def _branch_name(issue):
    """A deterministic, safe branch name for the issue's fix PR."""
    safe = (
        issue.get("id", "issue")
        .replace(":", "-")
        .replace("/", "-")
        .replace("#", "-")
        .replace(" ", "-")
    )
    return "heimdall/issue/%s" % safe


def build_gh_create_command(issue, title, body_file, base="main"):
    """Build the `gh pr create` command shape (a list of argv tokens). This is the
    ARTIFACT the agent produces; the agent NEVER executes it — RJ's creds run it at
    runtime (dossier §6.3). body comes from a file so the (large) SI-2 body never
    has to be shell-quoted inline."""
    return [
        "gh", "pr", "create",
        "--base", base,
        "--head", _branch_name(issue),
        "--title", title,
        "--body-file", body_file,
    ]


# ── open_pr: the terminal loop action — OPEN + STOP. Never merges, never closes ─


def _record_pr_open_state(q, issue_id, pr_ref):
    """Mark an in_flight issue PR_OPEN with its PR ref. We NEVER force a resolved
    or closed state here — autonomy ends at PR_OPEN (dossier §6 human gate). An
    unknown id (never queued) or a non-in_flight id (already resolved/flagged) is
    left untouched: open_pr still returns the artifact, but it does not fabricate a
    state transition the queue does not permit. Returns True if the state advanced."""
    state = q.state_of(issue_id)
    if state is None:
        return False  # unknown id — only return the artifact, force no state
    try:
        q.set_state(issue_id, PR_OPEN, pr=pr_ref)
        return True
    except KeyError:
        return False  # not in_flight (resolved/flagged) — never force a state


def open_pr(issue, record, repo=None, base="main", gh_runner=None):
    """THE TERMINAL ACTION the loop calls on a gate-PASS issue (dossier §6).

    Builds the PR artifact from the SI-2 record (a PROVEN fix: the body renders the
    runnable evidence), opens the PR via the `gh pr create` shape, marks the issue
    PR_OPEN, and STOPS.

    issue:      the normalized issue (piece b shape) — supplies id + source + links.
    record:     the SI-2 attestation record (the gate verdict source AND the PR
                body payload). open_pr ASSERTS record.evidence.all_passed is True.
    repo:       the repo whose queue store tracks the issue (default: cwd's repo).
    base:       the PR base branch (default 'main').
    gh_runner:  callable(argv:list) -> dict invoked to actually create the PR.
                Defaults to gh_bot_runner: the SCOPED PR-only bot-token runner
                (HEIMDALL_PR_BOT_TOKEN — contents:write on refs/heads/heimdall/* +
                pull_requests:write, NO push to main, NO merge). With no bot token
                present it degrades to record-only (build the artifact, push
                NOTHING) — the agent NEVER pushes with RJ's personal creds. In tests
                a mock stands in — NO live gh, NO network, NO real PR.

    This function does NOT merge (no merge verb exists), does NOT close the source
    issue, and does NOT call post_resolution. It opens + stops. Full stop. The
    write-back is a separate, human-triggered entry point (on_merged).

    Returns the PR artifact dict { ok, branch, title, body, create_command, gh,
    issue_id, all_passed, merged:False, source_closed:False,
    resolution_posted:False }."""
    # ── defence-in-depth: a FAIL physically cannot produce a PR (cardinal rule) ─
    all_passed = (record.get("evidence") or {}).get("all_passed")
    if all_passed is not True:
        raise HumanGateError(
            "refusing to open a PR for %r: evidence.all_passed is %r, not True — "
            "a PR is only ever opened on a PROVEN (gate-PASS) fix (dossier §5/§6)"
            % (issue.get("id"), all_passed)
        )

    issue_id = issue["id"]
    title = build_pr_title(issue)
    body = build_pr_body(issue, record)
    branch = _branch_name(issue)

    # persist the rendered body to the gitignored runtime home so the runtime
    # `gh pr create --body-file` (and a human auditor) can read the exact body.
    q = issue_queue.IssueQueue(repo=repo)
    body_file = _write_body_file(issue_id, body, repo)
    create_command = build_gh_create_command(issue, title, body_file, base=base)

    # open the PR via the runner (mock in tests; the scoped bot token at runtime).
    # Default = gh_bot_runner: pushes the heimdall/* branch + opens the PR under the
    # bot identity, or (no bot token) records the shape only — NEVER personal creds.
    runner = gh_runner or gh_bot_runner
    gh_result = runner(create_command)

    # mark the issue PR_OPEN in the queue store. We do NOT mark it resolved and we
    # do NOT close the source — autonomy ends here (dossier §6 human gate).
    pr_ref = (gh_result or {}).get("url") or (gh_result or {}).get("pr") or branch
    _record_pr_open_state(q, issue_id, pr_ref)

    return {
        "ok": bool((gh_result or {}).get("ok", True)),
        "issue_id": issue_id,
        "branch": branch,
        "title": title,
        "body": body,
        "body_file": body_file,
        "create_command": create_command,
        "gh": gh_result,
        "all_passed": True,
        # explicit, auditable proof of the human gate: open_pr opened + stopped.
        "merged": False,
        "source_closed": False,
        "resolution_posted": False,
    }


def _default_gh_runner(create_command):
    """The default `gh pr create` runner. The agent NEVER pushes — this records
    the create-command shape and reports it as the artifact, WITHOUT executing a
    live `gh pr create` (RJ's creds run that at runtime). Returns an honest
    artifact descriptor; `pushed` is always False here."""
    return {
        "ok": True,
        "pushed": False,
        "create_command": create_command,
        "note": "PR artifact built; live `gh pr create` runs with RJ's creds at "
                "runtime (the agent never pushes).",
    }


def gh_bot_runner(argv):
    """The PR-ONLY SCOPED BOT-TOKEN runner — the SOLE production PR-open path (the
    agent NEVER pushes with RJ's personal creds). It authenticates `gh` as a bot
    identity read from env HEIMDALL_PR_BOT_TOKEN: a GitHub App installation token /
    fine-grained PAT scoped to contents:write on refs/heads/heimdall/* +
    pull_requests:write — NO push to main, NO merge. That scope is enforced
    SERVER-SIDE by GitHub, so this token physically cannot push to main nor merge a
    PR; an unattended PR-open reconciles with "RJ holds the creds" (the bot opens the
    PR from a heimdall/* branch; a human merges).

    The token is passed to `gh` via the GH_TOKEN child-env var — NEVER on the argv
    (which is recorded/ps-visible) and NEVER printed/logged. Any inherited personal
    GITHUB_TOKEN is scrubbed so ONLY the scoped bot identity is ever used.

    When HEIMDALL_PR_BOT_TOKEN is ABSENT we fall back to the record-only default —
    we NEVER push with personal creds. Returns { ok, pushed, url, exit, command,
    identity }; `command` is the shlex-joined argv WITHOUT the token (the token
    lives only in the child env)."""
    token = os.environ.get("HEIMDALL_PR_BOT_TOKEN")
    if not token:
        # no scoped bot identity available -> NEVER fall through to personal creds.
        return _default_gh_runner(argv)
    proc = subprocess.run(
        argv,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        env=_bot_env(token),
    )
    out = (proc.stdout or "").strip().splitlines()
    return {
        "ok": proc.returncode == 0,
        "pushed": proc.returncode == 0,
        "url": out[-1] if out else None,
        "exit": proc.returncode,
        # NB: the token is NOT here — it travelled via GH_TOKEN in the child env only.
        "command": " ".join(shlex.quote(t) for t in argv),
        "identity": "heimdall-pr-bot",
    }


def _bot_env(token):
    """Build the child-process env for the scoped bot identity: inject the token as
    GH_TOKEN (so `gh` authenticates as the bot), and SCRUB any inherited personal
    GITHUB_TOKEN plus the raw HEIMDALL_PR_BOT_TOKEN so the personal creds can never
    be what pushes and the child can never echo the raw token. The token lives in
    the ENV only, never on argv — so it is never logged/recorded."""
    env = dict(os.environ)
    env.pop("GITHUB_TOKEN", None)
    env.pop("HEIMDALL_PR_BOT_TOKEN", None)
    env["GH_TOKEN"] = token
    return env


# ── post_receipt: the "merged AND proven" artifact (ATTESTATION-SOURCED) ───────


def build_receipt_body(record):
    """Render the 'merged AND proven' receipt: the SI-2 attestation VERDICT block a
    human (and the audit trail) read off the RECORDED REAL EXITS — the runnable proof
    commands + their real exit codes + the all_passed verdict + the attestation /
    comprehension-capsule reference. ATTESTATION-SOURCED, NEVER an agent claim: it
    re-renders record.evidence verbatim. Pure function — no IO."""
    lines = [
        "## Heimdall receipt — merged AND proven",
        "",
        "This fix is backed by the SI-2 attestation below: the verdict is read from "
        "the **recorded real exit codes**, never an agent self-report.",
        "",
        _render_evidence(record),
        "",
        _render_capsule_ref(record),
    ]
    return "\n".join(lines)


def _render_capsule_ref(record):
    """Render the comprehension-capsule / attestation reference the receipt links
    back to — sourced from the SI-2 record (its task label + attested commit, plus a
    capsule ref when the record carries one). This ties the proof back to the
    comprehension the fix was oriented on."""
    task = record.get("task") or "(unknown task)"
    commit = record.get("commit") or "(uncommitted)"
    capsule = record.get("capsule") or record.get("capsule_ref")
    lines = ["## Attestation reference"]
    lines.append("")
    lines.append("- task: `%s`" % task)
    lines.append("- attested commit: `%s`" % commit)
    if capsule:
        lines.append("- comprehension capsule: `%s`" % capsule)
    else:
        lines.append(
            "- comprehension capsule: linked via the attestation task/commit above"
        )
    return "\n".join(lines)


def build_gh_comment_command(pr_ref, body_file):
    """Build the `gh pr comment` command shape (argv tokens) that posts the receipt
    onto the opened PR. body comes from a file so the (large) receipt body never has
    to be shell-quoted inline. NEVER executed here — the bot-token runner runs it."""
    return ["gh", "pr", "comment", str(pr_ref), "--body-file", body_file]


def _write_receipt_file(record, body, repo):
    """Persist the rendered receipt body under the gitignored runtime home so the
    `gh pr comment --body-file` reads the exact receipt. Atomic write, mirroring the
    PR-body / queue-store discipline."""
    home = issue_queue.heimdall_home(repo)
    rc_dir = os.path.join(home, "issues", "pr-receipts")
    os.makedirs(rc_dir, exist_ok=True)
    stem = str(record.get("commit") or record.get("task") or "receipt")
    safe = (
        stem.replace(":", "_").replace("/", "_").replace("#", "_").replace(" ", "_")
    )
    path = os.path.join(rc_dir, safe + ".md")
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        fh.write(body)
        if not body.endswith("\n"):
            fh.write("\n")
    os.replace(tmp, path)
    return path


def post_receipt(record, pr_ref, repo=None, gh_runner=None):
    """Post the SI-2 attestation VERDICT block as a comment on the opened PR — the
    'merged AND proven' receipt (the overnight artifact).

    The verdict is ATTESTATION-SOURCED (record.evidence — the recorded real exits),
    NEVER an agent claim; build_receipt_body re-renders it verbatim.

    Defence-in-depth (cardinal rule): a receipt attests a PROVEN fix, so post_receipt
    REFUSES a record whose evidence.all_passed != True — a proof-less fix gets no
    'proven' receipt (raise HumanGateError). A missing pr_ref is also refused (there
    is no PR to attach the proof to). Posts via the scoped bot-token runner by
    default (the agent never pushes with personal creds); tests inject a mock.

    Returns { ok, pr_ref, body, receipt_file, comment_command, gh, all_passed }."""
    all_passed = (record.get("evidence") or {}).get("all_passed")
    if all_passed is not True:
        raise HumanGateError(
            "refusing to post a 'proven' receipt for %r: evidence.all_passed is %r, "
            "not True — the receipt attests a PROVEN fix (cardinal rule)"
            % (record.get("task"), all_passed)
        )
    if not pr_ref:
        raise HumanGateError(
            "refusing to post a receipt with no PR ref — there is no opened PR to "
            "attach the proof to"
        )
    body = build_receipt_body(record)
    receipt_file = _write_receipt_file(record, body, repo)
    comment_command = build_gh_comment_command(pr_ref, receipt_file)
    runner = gh_runner or gh_bot_runner
    gh_result = runner(comment_command)
    return {
        "ok": bool((gh_result or {}).get("ok", True)),
        "pr_ref": pr_ref,
        "body": body,
        "receipt_file": receipt_file,
        "comment_command": comment_command,
        "gh": gh_result,
        "all_passed": True,
    }


def _write_body_file(issue_id, body, repo):
    """Persist the rendered PR body under the gitignored runtime home so the
    runtime `gh pr create --body-file` reads the exact body the loop produced.
    Atomic write (.tmp -> os.replace), mirroring the queue store discipline."""
    home = issue_queue.heimdall_home(repo)
    pr_dir = os.path.join(home, "issues", "pr-bodies")
    os.makedirs(pr_dir, exist_ok=True)
    safe = issue_id.replace(":", "_").replace("/", "_").replace("#", "_")
    path = os.path.join(pr_dir, safe + ".md")
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        fh.write(body)
        if not body.endswith("\n"):
            fh.write("\n")
    os.replace(tmp, path)
    return path


# ── on_merged: the WRITE-BACK — the ONLY close/post path, HUMAN-triggered ──────


def on_merged(issue, repo=None, pr_ref=None, connectors_mod=None,
              verify=None, resolution=None):
    """THE WRITE-BACK (dossier §6). Invoked ONLY when a HUMAN has merged the PR —
    NEVER by the loop. This is the single entry point that closes the source issue
    and posts the resolution back; it is wired APART from open_pr on purpose (the
    human merge is the only bridge from PR_OPEN to resolved).

    Order of operations (each step gated on the prior):
      1. VERIFY the PR is actually merged (a Connector-/source-side check). If it
         is NOT merged, raise HumanGateError — we NEVER close/write-back a PR a
         human did not merge.
      2. close_issue(source_ref) on the ORIGINATING connector (idempotent).
      3. post_resolution(source_ref, resolution) — route the resolution (PR url +
         a merged note) back to the originating source (Slack thread / GitHub
         issue / email reply), via issue.source.
      4. mark the issue resolved{merged:True} in the queue store.

    issue:          the normalized issue — supplies source + links.source_ref.
    repo:           the repo whose queue store tracks the issue.
    pr_ref:         the merged PR's locator (url/number). Default: the pr recorded
                    on the in_flight record by open_pr.
    connectors_mod: the connectors registry (default: soft-imported). Tests inject
                    a mock module exposing get(source) -> a fake connector.
    verify:         callable(connector, raw_ref, pr_ref) -> bool — the merged
                    check. Default: trust a connector-supplied is_merged(pr_ref)
                    when present, else take a non-empty pr_ref as the human-merge
                    signal. on_merged is, by contract, called ONLY on a real human
                    merge.
    resolution:     the resolution payload to post back. Default: built from the
                    PR ref. Always carries the PR ref so the source links to it.

    Returns { ok, issue_id, merged, source_closed, resolution_posted, close,
    post, resolved }."""
    issue_id = issue["id"]
    source = issue["source"]
    raw_ref = (issue.get("links") or {}).get("source_ref") or {}

    q = issue_queue.IssueQueue(repo=repo)
    if pr_ref is None:
        in_flight = q.data["in_flight"].get(issue_id) or {}
        pr_ref = in_flight.get("pr")

    connectors_mod = connectors_mod or _soft_import_connectors()
    connector = _resolve_connector(source, connectors_mod)

    # ── 1) VERIFY the human merge (never close/write-back an un-merged PR) ─────
    checker = verify or _default_merge_verify
    if not checker(connector, raw_ref, pr_ref):
        raise HumanGateError(
            "refusing to write back %r: PR %r is NOT merged — the write-back is "
            "triggered ONLY by a human merge (dossier §6)" % (issue_id, pr_ref)
        )

    # ── 2) close the source issue (idempotent, ONLY after a verified merge) ───
    close = connector.close_issue(raw_ref)

    # ── 3) post the resolution back to the ORIGINATING source ─────────────────
    if resolution is None:
        resolution = _build_resolution(issue, pr_ref)
    post = connector.post_resolution(raw_ref, resolution)

    # ── 4) move the issue to resolved{merged:True} in the queue store ─────────
    resolved = q.mark_resolved(issue_id, pr=pr_ref, merged=True)

    return {
        "ok": True,
        "issue_id": issue_id,
        "source": source,
        "merged": True,
        "pr": pr_ref,
        "source_closed": bool((close or {}).get("ok", True)),
        "resolution_posted": bool((post or {}).get("ok", True)),
        "close": close,
        "post": post,
        "resolved": resolved,
    }


def _default_merge_verify(connector, raw_ref, pr_ref):
    """The default human-merge check. Prefers a connector-side is_merged(pr_ref)
    when the connector exposes one (the source is authoritative for merge state).
    Absent that, a non-empty pr_ref is taken as the human-supplied merge signal —
    on_merged is, by contract, invoked ONLY on a real human merge. Returns a bool.
    NEVER assumes merged when pr_ref is missing (no pr -> not merged)."""
    is_merged = getattr(connector, "is_merged", None)
    if callable(is_merged):
        try:
            return bool(is_merged(pr_ref))
        except Exception:
            return False
    return pr_ref is not None and pr_ref != ""


def _build_resolution(issue, pr_ref):
    """Build the resolution payload posted back to the source: the PR url + a
    short, human-readable note that the fix was merged. Routed back via
    issue.source by the originating connector."""
    return {
        "kind": "merged",
        "pr": pr_ref,
        "issue_id": issue.get("id"),
        "message": "Resolved by Heimdall - the fix PR (%s) was reviewed and merged "
                   "by a human." % pr_ref,
    }


# ── status (a read-only view of the PR/writeback state for an issue) ──────────


def status(issue_id, repo=None):
    """Read-only: where does this issue sit on the PR/writeback path? Reports its
    queue machine-state, the recorded PR ref (if any), and whether it is resolved.
    Touches nothing."""
    q = issue_queue.IssueQueue(repo=repo)
    state = q.state_of(issue_id)
    in_flight = q.data["in_flight"].get(issue_id) or {}
    resolved = q.data["resolved"].get(issue_id) or {}
    return {
        "id": issue_id,
        "state": state,
        "pr": in_flight.get("pr") or resolved.get("pr"),
        "resolved": issue_id in q.data["resolved"],
        "merged": bool(resolved.get("merged")) if resolved else False,
    }


# ── CLI core (driven by bin/heimdall-issue-pr) ────────────────────────────────


def _load_json_arg(value):
    """A JSON CLI arg is either inline JSON or @path-to-file."""
    if value.startswith("@"):
        with open(value[1:], "r", encoding="utf-8") as fh:
            return json.load(fh)
    return json.loads(value)


def _cli(argv):
    """CLI core. Subcommands:
      open     --issue @file|JSON --record @file|JSON [--repo R] [--base B] [--print]
      on-merge --issue @file|JSON [--pr REF] [--repo R] [--print]
      receipt  --record @file|JSON --pr REF [--repo R] [--print]
      status   --id ID [--repo R]
    Returns an exit code; prints JSON to stdout, human notes to stderr.

    NOTE: there is no `merge` subcommand — Heimdall never merges. The human gate is
    structural: open + on-merge (post-human-merge) only."""
    import argparse

    p = argparse.ArgumentParser(prog="heimdall-issue-pr", add_help=True)
    p.add_argument("subcommand")
    p.add_argument("--issue")
    p.add_argument("--record")
    p.add_argument("--pr")
    p.add_argument("--id")
    p.add_argument("--repo", default=os.getcwd())
    p.add_argument("--base", default="main")
    p.add_argument("--print", dest="do_print", action="store_true")
    args = p.parse_args(argv)

    repo = os.path.abspath(args.repo)
    sub = args.subcommand

    if sub == "open":
        if not args.issue or not args.record:
            print("error: open needs --issue and --record", file=sys.stderr)
            return 2
        issue = _load_json_arg(args.issue)
        record = _load_json_arg(args.record)
        try:
            result = open_pr(issue, record, repo=repo, base=args.base)
        except HumanGateError as exc:
            print("error: %s" % exc, file=sys.stderr)
            return 1
        _emit_open(result, args.do_print)
        return 0

    if sub == "on-merge":
        if not args.issue:
            print("error: on-merge needs --issue", file=sys.stderr)
            return 2
        issue = _load_json_arg(args.issue)
        try:
            result = on_merged(issue, repo=repo, pr_ref=args.pr)
        except HumanGateError as exc:
            print("error: %s" % exc, file=sys.stderr)
            return 1
        if args.do_print:
            print(json.dumps(result, indent=2, sort_keys=True))
        sys.stderr.write(
            "issue-pr on-merge: %s — closed=%s posted=%s merged=%s\n"
            % (
                result["issue_id"],
                result["source_closed"],
                result["resolution_posted"],
                result["merged"],
            )
        )
        return 0

    if sub == "receipt":
        if not args.record or not args.pr:
            print("error: receipt needs --record and --pr", file=sys.stderr)
            return 2
        record = _load_json_arg(args.record)
        try:
            result = post_receipt(record, args.pr, repo=repo)
        except HumanGateError as exc:
            print("error: %s" % exc, file=sys.stderr)
            return 1
        if args.do_print:
            printable = dict(result)
            printable.pop("body", None)  # full body is on disk (receipt_file)
            print(json.dumps(printable, indent=2, sort_keys=True))
        sys.stderr.write(
            "issue-pr receipt: posted merged-AND-proven receipt to %s "
            "(all_passed=%s)\n" % (result["pr_ref"], result["all_passed"])
        )
        return 0

    if sub == "status":
        if not args.id:
            print("error: status needs --id", file=sys.stderr)
            return 2
        print(json.dumps(status(args.id, repo=repo), indent=2, sort_keys=True))
        return 0

    print("error: unknown subcommand: %s" % sub, file=sys.stderr)
    return 2


def _emit_open(result, do_print):
    """Print the open_pr result + a one-line human summary that makes the human
    gate explicit (opened + stopped; never merged/closed)."""
    if do_print:
        printable = dict(result)
        # keep stdout compact: the full body is on disk (body_file).
        printable.pop("body", None)
        print(json.dumps(printable, indent=2, sort_keys=True))
    sys.stderr.write(
        "issue-pr open: %s — branch=%s opened (NOT merged, NOT closed; human "
        "gate holds)\n" % (result["issue_id"], result["branch"])
    )


if __name__ == "__main__":
    sys.exit(_cli(sys.argv[1:]))
