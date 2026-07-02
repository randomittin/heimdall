#!/usr/bin/env python3
# cp_maintainer_runner.py — HYBRID runner selection for the maintainer autopilot.
#
# THE PROBLEM. The maintainer cycle (run-maintainer-cycle) can run in TWO places:
#   • Arch A — the OPERATOR'S OWN BOX (cp_jobrunner.SubprocessRunner): cheap, uses the
#     box's ambient subscription auth (CLAUDE_CODE_OAUTH_TOKEN), $0 infra.
#   • Arch B — a CLOUD RUN JOB (cp_jobrunner.CloudRunJobRunner): zero-touch, machine-
#     independent, auth from Secret Manager.
# The merged dispatch pinned ONE runner per deployment (HEIMDALL_JOB_RUNNER). This module
# adds the HYBRID policy: prefer the operator's box WHEN IT IS UP, else fall back to the
# cloud — and NEVER drop a cycle if the box dies between "up" and "claimed".
#
# THE LIVENESS SUBSTRATE (REUSE cp_presence, do NOT invent a parallel one). The operator's
# box proves it is up by beating a signed heartbeat to the control plane exactly like a dev's
# presence beat — same StateBackend keyed-record store, same TTL-freshness read, same
# secret-scrub. We add a DISTINCT presence KIND ("maintainer-runner", a 90s TTL) so a runner
# beat never mixes with the team roster. "The box is up" == a runner beat fresher than the TTL.
# The beat is DATA-ONLY (runner_id + repo + ts) and carries NO token — the store stays
# secret-free by construction, and the selection never reads a credential.
#
# THE SELECTION (deterministic + logged, token never logged). HEIMDALL_MAINTAINER_RUNNER =
# hybrid|local|cloud (default hybrid):
#   • local  -> Arch A always (SubprocessRunner).
#   • cloud  -> Arch B always (CloudRunJobRunner).
#   • hybrid -> Arch A IFF a fresh self-hosted runner beat exists; else Arch B IFF the cloud
#               Job is configured (a resolvable project); else PARK ("no runner available").
# Every decision logs WHICH arm + WHY to stderr (the Cloud Run log sink, cp_jobrunner._log
# convention). The LLM token is NEVER part of a decision — selection reads presence + env +
# durable job state only, so it cannot appear in any logged/recorded selection surface.
#
# NEVER DROP A CYCLE (the hard guarantee). dispatch_maintainer_cycle creates the durable job
# FIRST (so the cycle EXISTS in the store the moment it is dispatched — a crash can't lose it),
# then dispatches to the selected arm. Under hybrid, if Arch A was picked but the job is NOT
# CLAIMED (its durable state leaves `queued`) within a bounded grace window — the box went down
# between the beat and the claim — it FAILS OVER to Arch B. If Arch A is unclaimed AND Arch B is
# unconfigured, the cycle PARKS with a clear reason (the durable job stays `queued`, re-drivable
# by the next tick / resume_orphans) — flagged, never silently dropped.
#
# THE SECURITY SPINE IS UNTOUCHED. This module decides WHERE the cycle runs, NEVER WHAT: it
# re-validates the params through cp_allowlist.validate (the §1 gate) before enqueue, so an
# off-slug repo / out-of-range max / a smuggled key is refused here exactly as at create. There
# is no free-form prompt/cmd anywhere; the maintainer prompt is still built INSIDE
# heimdall-maintain-loop from the queued issue. The agent still only OPENS PRs (bot token in the
# child env) — it never pushes main / merges, on EITHER arm.
#
# stdlib-only (os/sys/time) + the sibling cp_* substrate (cp_allowlist / cp_audit / cp_jobstore /
# cp_jobrunner / cp_presence / cp_state) — imported, never edited. No third-party dep here; the
# only lazy GCP import lives in cp_jobrunner.CloudRunJobRunner, reached only when Arch B runs.

from __future__ import annotations

import os
import sys
import time

_HERE = os.path.dirname(os.path.abspath(__file__))
if _HERE not in sys.path:
    sys.path.insert(0, _HERE)

import cp_allowlist   # THE §1 gate — re-validate the maintainer params at dispatch (defense in depth).
import cp_audit       # §9 — a dispatch / failover / park writes a job_state row (params-shape, no token).
import cp_jobrunner   # the runner impls: SubprocessRunner (Arch A) + CloudRunJobRunner (Arch B).
import cp_jobstore    # the durable job store — the cycle EXISTS here the moment it is dispatched.
import cp_presence    # REUSE the presence heartbeat substrate (store/scrub/TTL) — NO parallel liveness infra.

# The allowlisted maintainer action_type (the SAME one cp_scheduler / cp_allowlist name).
MAINTAINER_ACTION_TYPE = "run-maintainer-cycle"


# ── loud, token-free selection logging (cp_jobrunner._log convention) ──────────────
#
# Every selection / failover / park prints ONE stderr line (Cloud Run captures stderr into
# the service logs), so a run can always name WHICH arm ran + WHY. We format ONLY the arm,
# the reason, the runner NAME, the job_id, and the repo slug — NEVER an env value / token /
# base_env. A logging failure must never break a dispatch (the never-drop contract).

def _log(msg):
    """Write one LOUD, token-free diagnostic line to stderr. Prefixed
    `cp_maintainer_runner:` (mirrors cp_jobrunner._log / cp_boot). Best-effort: a logging
    failure is swallowed so it can NEVER break the dispatch / failover / park path."""
    try:
        sys.stderr.write("cp_maintainer_runner: %s\n" % msg)
        sys.stderr.flush()
    except Exception:  # noqa: BLE001 — diagnostic only; a write error must not break dispatch.
        return


# ── the self-hosted runner heartbeat (a DISTINCT presence kind — reuse cp_presence) ─
#
# The operator's box beats liveness under a presence kind SEPARATE from the team roster, so a
# runner beat never appears in / is never confused with the dev roster. The record is keyed
# by (repo-scope, runner_id) exactly as a presence record is keyed by (project/team, haid) —
# last-write-wins via put_record, TTL-filtered on read via cp_presence.is_online. DATA-ONLY:
# runner_id + repo + ts, no token, secret-scrubbed by cp_presence._clean.

# The rel sub-tree all maintainer-runner beats live under, within control-plane/.
RUNNER_PRESENCE_REL = "maintainer-runner"

# The liveness window: a runner beat fresher than this = the box is UP. 90s gives ~2 missed
# beats of slack for a ~30-45s cron cadence before the box is treated as down. Overridable.
RUNNER_TTL_ENV = "HEIMDALL_MAINTAINER_RUNNER_TTL_SECONDS"
RUNNER_TTL_DEFAULT = 90.0

# The scope segment used when a beat is not pinned to one repo (a box that maintains any repo).
_RUNNER_SCOPE_ALL = "_all"

# The keyed-record suffix (one .json per runner, mirrors cp_presence's per-dev record).
_RECORD_SUFFIX = ".json"


def runner_ttl_seconds():
    """The runner-liveness TTL in seconds (HEIMDALL_MAINTAINER_RUNNER_TTL_SECONDS, default
    90). A malformed / non-positive env value falls back to the default (never crashes a read)."""
    raw = os.environ.get(RUNNER_TTL_ENV)
    if not raw:
        return RUNNER_TTL_DEFAULT
    try:
        val = float(raw)
    except (TypeError, ValueError):
        return RUNNER_TTL_DEFAULT
    return val if val > 0 else RUNNER_TTL_DEFAULT


def _scope(repo):
    """The repo scope segment for a runner beat: the slugged repo, or `_all` when a beat is
    not pinned to one repo. Reuses cp_presence._slug (filesystem-safe, Firestore-flat-safe)."""
    if not repo:
        return _RUNNER_SCOPE_ALL
    return cp_presence._slug(repo)


def _scope_dir(repo):
    """The store-relative dir of one repo-scope's runner beats: maintainer-runner/<scope>/."""
    return os.path.join(RUNNER_PRESENCE_REL, _scope(repo))


def _runner_record_rel(repo, runner_id):
    """The store-relative path of ONE runner's beat: maintainer-runner/<scope>/<runner>.json.
    The record KEY is the runner_id; the scope is the repo (or `_all`). Slugged on both."""
    return os.path.join(_scope_dir(repo), cp_presence._slug(runner_id) + _RECORD_SUFFIX)


def build_runner_beat(runner_id, *, repo=None, handle=None, ts=None):
    """Assemble ONE DATA-ONLY, secret-scrubbed runner-liveness beat. Pure — no IO. The schema
    is CLOSED: {kind, runner_id, repo, handle, ts}. There is NO token / command / handler field
    — a runner beat is rendered liveness, it executes nothing and carries no credential (the
    same DATA-ONLY discipline as a cp_presence record). `ts` is epoch seconds (defaults to now),
    the freshness the TTL filters on; a bad ts coerces to now."""
    return {
        "kind": RUNNER_PRESENCE_REL,
        "runner_id": runner_id,
        # repo / handle are scrubbed free-ish DATA (bounded + secret-rejected) — reuse
        # cp_presence._clean (telemetry._scrub) so a beat can never carry a credential.
        "repo": cp_presence._clean(repo),
        "handle": cp_presence._clean(handle),
        "ts": float(ts) if isinstance(ts, (int, float)) else time.time(),
    }


def record_runner_beat(runner_id, *, repo=None, handle=None, home=None, ts=None):
    """STORE one self-hosted runner heartbeat (the operator's box proves it is UP). Builds the
    scrubbed beat and atomically upserts it under (repo-scope, runner_id) via the SAME
    StateBackend.put_record cp_presence uses (last-write-wins — a fresher beat overwrites the
    prior one). Returns {ok, runner_id, repo, ttl} on a stored write, {ok: False, reason} on a
    missing id / IO failure. DATA only — no token, executes nothing. The control plane's
    selection reads these back to decide whether Arch A is live."""
    if not runner_id:
        return {"ok": False, "reason": "no_runner_id"}
    beat = build_runner_beat(runner_id, repo=repo, handle=handle, ts=ts)
    if not cp_presence._backend(home).put_record(
            _runner_record_rel(repo, runner_id), beat):
        return {"ok": False, "reason": "io_error"}
    return {"ok": True, "runner_id": runner_id, "repo": beat.get("repo"),
            "ttl": runner_ttl_seconds()}


def live_runner_beats(repo=None, *, home=None, now=None, ttl=None):
    """The LIVE (within-TTL) self-hosted runner beats relevant to `repo`: the fold of the beats
    under the repo's scope PLUS the `_all` scope (a box that maintains any repo), each filtered
    by cp_presence.is_online. Read-only; an absent store yields [] (honest empty). Reuses the
    backend list_names + get_record + cp_presence.is_online — no re-invented liveness math."""
    backend = cp_presence._backend(home)
    when = now if now is not None else time.time()
    window = ttl if ttl is not None else runner_ttl_seconds()
    scopes = [_scope_dir(repo)]
    all_dir = os.path.join(RUNNER_PRESENCE_REL, _RUNNER_SCOPE_ALL)
    if all_dir not in scopes:
        scopes.append(all_dir)
    out = []
    seen = set()
    for scope_dir in scopes:
        for name in backend.list_names(scope_dir, suffix=_RECORD_SUFFIX):
            rel = os.path.join(scope_dir, name)
            if rel in seen:
                continue
            seen.add(rel)
            record = backend.get_record(rel)
            if cp_presence.is_online(record, now=when, ttl=window):
                out.append(record)
    return out


def runner_is_live(repo=None, *, home=None, now=None, ttl=None):
    """True IFF at least one self-hosted runner beat for `repo` (or `_all`) is fresher than the
    TTL — i.e. the operator's box is UP. The single liveness predicate the hybrid selection
    consults for Arch A."""
    return bool(live_runner_beats(repo, home=home, now=now, ttl=ttl))


# ── the hybrid policy + deterministic arm selection ─────────────────────────────────

POLICY_ENV = "HEIMDALL_MAINTAINER_RUNNER"
POLICY_HYBRID = "hybrid"
POLICY_LOCAL = "local"
POLICY_CLOUD = "cloud"
POLICY_DEFAULT = POLICY_HYBRID
_POLICIES = (POLICY_HYBRID, POLICY_LOCAL, POLICY_CLOUD)

# The three arms a selection resolves to.
ARM_LOCAL = "local"   # Arch A — cp_jobrunner.SubprocessRunner (the operator's box).
ARM_CLOUD = "cloud"   # Arch B — cp_jobrunner.CloudRunJobRunner (a Cloud Run Job execution).
ARM_PARK = "park"     # no runner available — the cycle parks (flagged, never dropped).


def resolve_policy(policy_name=None):
    """Resolve the runner policy: an explicit `policy_name` wins, else HEIMDALL_MAINTAINER_RUNNER,
    else the default (hybrid). An UNKNOWN non-empty value does NOT crash the dispatch (that would
    drop a cycle) — it falls back to hybrid and logs the coercion (deterministic + observable)."""
    raw = policy_name if policy_name is not None else os.environ.get(POLICY_ENV)
    raw = (raw or "").strip().lower()
    if not raw:
        return POLICY_DEFAULT
    if raw in _POLICIES:
        return raw
    _log("unknown %s=%r -> defaulting to %s" % (POLICY_ENV, raw, POLICY_DEFAULT))
    return POLICY_DEFAULT


def cloud_configured(*, cloud_runner=None):
    """True IFF Arch B (the Cloud Run Job) can be dispatched at all — the CloudRunJobRunner can
    build its Job resource name (a project is resolvable). On a box with no GCP project set this
    is False, which is the "Arch B unconfigured" signal the hybrid PARK path keys on. Injectable
    (`cloud_runner`) for hermetic tests. Constructing the runner is cheap and imports NO GCP dep
    (run_v2 is imported lazily only inside an ACTUAL dispatch)."""
    runner = cloud_runner if cloud_runner is not None else cp_jobrunner.CloudRunJobRunner()
    try:
        runner.job_resource_name()
        return True
    except Exception:  # noqa: BLE001 — any resolution failure (no project) => Arch B unconfigured.
        return False


class RunnerDecision:
    """The resolved arm + WHY. `arm` is ARM_LOCAL / ARM_CLOUD / ARM_PARK; `reason` is a short,
    token-free human string (logged + surfaced); `runner_live` records whether a fresh self-
    hosted beat was seen; `policy` is the effective policy. Immutable-ish (slots)."""

    __slots__ = ("arm", "reason", "runner_live", "policy")

    def __init__(self, arm, reason, runner_live, policy):
        self.arm = arm
        self.reason = reason
        self.runner_live = bool(runner_live)
        self.policy = policy

    def as_dict(self):
        return {"arm": self.arm, "reason": self.reason,
                "runner_live": self.runner_live, "policy": self.policy}


def select_runner_arm(repo, *, home=None, now=None, policy_name=None,
                      cloud_ok=None, runner_live=None):
    """THE deterministic hybrid selection. Given the repo (for the runner-liveness scope) it
    resolves the arm from the policy + the live beat + whether the cloud is configured:

      policy=local  -> ARM_LOCAL   (forced Arch A, regardless of liveness).
      policy=cloud  -> ARM_CLOUD   (forced Arch B, regardless of liveness).
      policy=hybrid ->
          fresh self-hosted beat            -> ARM_LOCAL  (prefer the operator's box).
          no beat, cloud configured         -> ARM_CLOUD  (fall back to the Cloud Run Job).
          no beat, cloud NOT configured     -> ARM_PARK   (no runner available).

    `runner_live` / `cloud_ok` are injectable booleans (hermetic tests); when None they are
    resolved live (runner_is_live / cloud_configured). Pure of side effects — returns a
    RunnerDecision; the caller logs + acts. The credential is never consulted here."""
    pol = resolve_policy(policy_name)
    live = runner_is_live(repo, home=home, now=now) if runner_live is None else bool(runner_live)

    if pol == POLICY_LOCAL:
        return RunnerDecision(
            ARM_LOCAL,
            "policy=local: forced self-hosted runner (Arch A, SubprocessRunner)",
            live, pol)
    if pol == POLICY_CLOUD:
        return RunnerDecision(
            ARM_CLOUD,
            "policy=cloud: forced Cloud Run Job (Arch B, CloudRunJobRunner)",
            live, pol)

    # hybrid — prefer the operator's box when it is up, else the cloud, else park.
    if live:
        return RunnerDecision(
            ARM_LOCAL,
            "hybrid: fresh self-hosted runner beat within TTL -> Arch A (SubprocessRunner)",
            True, pol)
    cloud = cloud_configured() if cloud_ok is None else bool(cloud_ok)
    if cloud:
        return RunnerDecision(
            ARM_CLOUD,
            "hybrid: no fresh self-hosted runner beat -> fall back to Arch B (Cloud Run Job)",
            False, pol)
    return RunnerDecision(
        ARM_PARK,
        "hybrid: no self-hosted runner beat AND Cloud Run Job unconfigured -> no runner available",
        False, pol)


# ── the never-drop dispatch driver (select -> dispatch -> failover -> park) ─────────

# The grace window a dispatched Arch-A job has to be CLAIMED (its durable state to leave
# `queued`) before hybrid fails over to Arch B. Default 30s (a box's poller claims a fresh job
# well within this); tunable, and injectable per-call for tests.
GRACE_ENV = "HEIMDALL_MAINTAINER_CLAIM_GRACE_SECONDS"
GRACE_DEFAULT = 30.0
# How often the claim wait re-reads the durable job state (short = responsive; not a spin).
_CLAIM_POLL_SECONDS = 0.1


def claim_grace_seconds():
    """The Arch-A claim grace window in seconds (HEIMDALL_MAINTAINER_CLAIM_GRACE_SECONDS,
    default 30). A malformed / negative env value falls back to the default."""
    raw = os.environ.get(GRACE_ENV)
    if raw is None or raw == "":
        return GRACE_DEFAULT
    try:
        val = float(raw)
    except (TypeError, ValueError):
        return GRACE_DEFAULT
    return val if val >= 0 else GRACE_DEFAULT


def _is_claimed(job_id, home):
    """A dispatched maintainer job is CLAIMED once its durable state has LEFT `queued` — a
    runner / the box's worker transitioned it to running (or beyond). Still `queued` = not yet
    claimed (the box never picked it up). An unknown job (no record) reads as NOT claimed."""
    state = cp_jobstore.current_state(job_id, home)
    return state is not None and state != cp_jobstore.STATE_QUEUED


def _await_claim(job_id, *, home, grace, claimed):
    """Poll the durable job state up to `grace` seconds, returning True as soon as `claimed`
    reports the job left `queued`, else False when the window elapses. `claimed(job_id, home)`
    is injectable (tests pass a deterministic predicate). grace<=0 = a single immediate check."""
    if claimed(job_id, home):
        return True
    if grace <= 0:
        return False
    waited = 0.0
    while waited < grace:
        time.sleep(_CLAIM_POLL_SECONDS)
        waited += _CLAIM_POLL_SECONDS
        if claimed(job_id, home):
            return True
    return False


def _park(job_id, *, actor, home, reason, detail):
    """PARK the cycle: leave the durable job `queued` (re-drivable by the next tick /
    resume_orphans — NOT lost) and audit the reason. Returns the park outcome dict. This is the
    never-drop floor: even with no runner available the cycle survives in the store, flagged."""
    _log("PARK job=%s: %s" % (job_id, reason))
    cp_audit.write("job_state", actor_haid=actor, action_type=MAINTAINER_ACTION_TYPE,
                   job_id=job_id, outcome="ok", detail=detail, home=home)
    return {"dispatched": False, "parked": True, "cycle_lost": False,
            "job_id": job_id, "arm": ARM_PARK, "reason": reason,
            "failover": False, "http_status": 200}


def dispatch_maintainer_cycle(identity, params, *, home=None, base_env=None, now=None,
                              policy_name=None, actor_haid=None,
                              local_runner=None, cloud_runner=None,
                              cloud_ok=None, runner_live=None,
                              grace_seconds=None, claimed=None):
    """Dispatch ONE maintainer cycle to the HYBRID-selected runner, never dropping it.

    The flow (each step a hard guarantee):
      1. §1 GATE — cp_allowlist.validate(run-maintainer-cycle, params). An off-slug repo /
         out-of-range max / smuggled key is REFUSED here (422 + audit), before any job exists.
      2. SELECT — select_runner_arm(repo, ...): the deterministic arm + reason (logged).
      3. ENQUEUE — cp_jobstore.create_job: the cycle now EXISTS durably (a crash can't lose it).
      4. PARK / DISPATCH — ARM_PARK parks (queued, flagged, re-drivable); else dispatch to the
         chosen runner (SubprocessRunner for A / CloudRunJobRunner for B). The LLM token is NEVER
         logged / stored — it rides base_env into the runner's child env only.
      5. FAILOVER — under hybrid, if Arch A was picked but the job is NOT claimed (leaves
         `queued`) within the grace window, fail over to Arch B (Cloud Run Job). If Arch A is
         unclaimed AND Arch B is unconfigured, PARK (never drop).

    Returns an outcome dict: {dispatched, job_id, arm, runner, reason, runner_live, failover,
    parked, cycle_lost, http_status, ...}. Token-free by construction — no field carries a
    credential. `local_runner` / `cloud_runner` / `cloud_ok` / `runner_live` / `grace_seconds` /
    `claimed` are injectable for hermetic tests; in production they resolve to the real runners +
    live liveness/claim reads."""
    actor = actor_haid if actor_haid is not None else (
        identity.haid if hasattr(identity, "haid") else identity)

    # 1. THE §1 GATE — re-validate at dispatch (defense in depth; the security spine holds).
    try:
        plan = cp_allowlist.validate(MAINTAINER_ACTION_TYPE, params)
    except cp_allowlist.RefusedDispatch as ref:
        aid = cp_audit.record_refusal(actor, MAINTAINER_ACTION_TYPE, reason=ref.reason,
                                      params=params, home=home)
        _log("REFUSED reason=%s (params off-allowlist) — no job created" % ref.reason)
        return {"dispatched": False, "refused": True, "reason": ref.reason,
                "arm": None, "parked": False, "failover": False,
                "http_status": 422, "audit_id": aid}
    clean = plan["params"]
    repo = clean.get("repo")

    # 2. SELECT the arm (deterministic + reason).
    decision = select_runner_arm(repo, home=home, now=now, policy_name=policy_name,
                                 cloud_ok=cloud_ok, runner_live=runner_live)

    # 3. ENQUEUE — the cycle EXISTS durably now (never dropped from here on).
    job_id = cp_jobstore.create_job(MAINTAINER_ACTION_TYPE, clean,
                                    instance_haid=actor, home=home)
    if job_id is None:
        _log("job store unavailable — cycle could not be enqueued (arm=%s)" % decision.arm)
        return {"dispatched": False, "reason": "job_store_unavailable",
                "arm": decision.arm, "parked": False, "failover": False,
                "http_status": 500}
    cp_audit.write("job_state", actor_haid=actor, action_type=MAINTAINER_ACTION_TYPE,
                   job_id=job_id, outcome="ok", detail="queued", home=home)

    # 4a. PARK — no runner available; the job stays queued, flagged, re-drivable next tick.
    if decision.arm == ARM_PARK:
        return _park(job_id, actor=actor, home=home, reason=decision.reason,
                     detail="parked:no_runner_available")

    # 4b. DISPATCH to the chosen arm's runner. base_env carries the credential into the runner's
    #     child env ONLY — we log the arm + runner NAME + reason, NEVER the env/token.
    lr = local_runner if local_runner is not None else cp_jobrunner.SubprocessRunner()
    cr = cloud_runner if cloud_runner is not None else cp_jobrunner.CloudRunJobRunner()
    chosen = lr if decision.arm == ARM_LOCAL else cr
    _log("SELECT job=%s repo=%s arm=%s runner=%s reason=%s"
         % (job_id, repo, decision.arm, chosen.name, decision.reason))
    result = chosen.dispatch(job_id, actor_haid=actor, home=home, base_env=base_env)
    cp_audit.write("job_state", actor_haid=actor, action_type=MAINTAINER_ACTION_TYPE,
                   job_id=job_id, outcome="ok",
                   detail="dispatched:%s:%s" % (decision.arm, chosen.name), home=home)

    outcome = {
        "dispatched": bool(result.get("dispatched")),
        "job_id": job_id, "arm": decision.arm, "runner": chosen.name,
        "reason": decision.reason, "runner_live": decision.runner_live,
        "failover": False, "parked": False, "cycle_lost": False,
        "http_status": 200,
    }

    # 5. FAILOVER — hybrid only, Arch-A arm only: if the box never claimed the job within the
    #    grace window (it went down between the beat and the claim), re-dispatch to Arch B so
    #    the cycle is NEVER dropped. If Arch B is unconfigured too, park (still never dropped).
    if decision.policy == POLICY_HYBRID and decision.arm == ARM_LOCAL:
        grace = claim_grace_seconds() if grace_seconds is None else float(grace_seconds)
        claim_fn = claimed if claimed is not None else _is_claimed
        if (not result.get("dispatched")) or not _await_claim(
                job_id, home=home, grace=grace, claimed=claim_fn):
            _log("FAILOVER job=%s: Arch A not claimed within grace=%ss -> trying Arch B"
                 % (job_id, grace))
            cok = cloud_configured(cloud_runner=cr) if cloud_ok is None else bool(cloud_ok)
            if not cok:
                parked = _park(
                    job_id, actor=actor, home=home,
                    reason=("hybrid failover: Arch A unclaimed AND Arch B unconfigured"
                            " -> no runner available"),
                    detail="parked:local_unclaimed_cloud_unconfigured")
                outcome.update(parked)
                outcome["runner_live"] = decision.runner_live
                return outcome
            fres = cr.dispatch(job_id, actor_haid=actor, home=home, base_env=base_env)
            cp_audit.write("job_state", actor_haid=actor,
                           action_type=MAINTAINER_ACTION_TYPE, job_id=job_id,
                           outcome="ok", detail="failover:%s:%s" % (ARM_CLOUD, cr.name),
                           home=home)
            outcome.update({
                "dispatched": bool(fres.get("dispatched")),
                "arm": ARM_CLOUD, "runner": cr.name, "failover": True,
                "reason": ("hybrid failover: Arch A not claimed within grace"
                           " -> Arch B (Cloud Run Job)"),
            })

    return outcome
