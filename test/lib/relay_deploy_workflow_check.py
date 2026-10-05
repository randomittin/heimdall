#!/usr/bin/env python3
"""Structural checks for the relay deploy pipeline.

Run by test/relay-deploy-workflow.test.sh: once on the real files (every property must hold) and
once per deliberately broken copy from relay_deploy_workflow_mutants.py (the matching property must
go red), so none of these checks is a tautology. It only reads.

    relay_deploy_workflow_check.py [--workflow F] [--relay-ci F] [--wrangler F] [--health-script F]

Prints one `ok   <id>: ...` or `FAIL <id>: ...` line per property and exits 1 if any property FAILs.
"""
import argparse
import os
import re
import sys

import yaml

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
TOKEN_EXPR = "${{ secrets.CLOUDFLARE_API_TOKEN }}"
ACCOUNT_EXPR = "${{ vars.CLOUDFLARE_ACCOUNT_ID }}"
SHA_PINNED = re.compile(r"^[A-Za-z0-9_.-]+/[A-Za-z0-9_./-]+@[0-9a-f]{40}$")
DEPLOY_JOBS = ("canary", "production")


def read(path):
    with open(path, encoding="utf-8") as fh:
        return fh.read()


def triggers(doc):
    # PyYAML follows YAML 1.1, where the bare key `on` is the boolean True.
    return doc.get("on", doc.get(True)) or {}


def as_list(value):
    if value is None:
        return []
    return value if isinstance(value, list) else [value]


def jobs_of(doc):
    jobs = doc.get("jobs")
    return jobs if isinstance(jobs, dict) else {}


def steps_of(job):
    return job.get("steps") or []


def run_of(step):
    return step.get("run") or ""


def steps_running(job, pattern):
    """[(index, step)] of the job's steps whose `run` script matches `pattern`."""
    return [(i, s) for i, s in enumerate(steps_of(job)) if re.search(pattern, run_of(s))]


def uses_refs(doc):
    for name, job in jobs_of(doc).items():
        if "uses" in job:
            yield name, job["uses"]
        for step in steps_of(job):
            if "uses" in step:
                yield name, step["uses"]


def pinned_checks(job):
    """The health-check steps that pin the version to this commit (they pass "$GITHUB_SHA")."""
    return [(i, s) for i, s in steps_running(job, r"scripts/health-check\.sh") if '"$GITHUB_SHA"' in run_of(s)]


def toml_tables(text):
    """Minimal reader for wrangler.toml's shape: [(header, is_array_of_tables, {key: raw value})] in
    file order, top-level keys under header ''. Comments are cut at the first '#', which is safe
    only because no value in that file contains one."""
    tables = [("", False, {})]
    for raw in text.splitlines():
        line = raw.split("#", 1)[0].strip()
        if not line:
            continue
        array = re.match(r"^\[\[([^\]]+)\]\]$", line)
        table = re.match(r"^\[([^\[\]]+)\]$", line)
        pair = re.match(r"^([A-Za-z0-9_.-]+)\s*=\s*(.+)$", line)
        if array:
            tables.append((array.group(1).strip(), True, {}))
        elif table:
            tables.append((table.group(1).strip(), False, {}))
        elif pair:
            tables[-1][2][pair.group(1)] = pair.group(2).strip()
    return tables


def p_triggers(ctx):
    on = triggers(ctx["wf"])
    if not isinstance(on, dict):
        return ["`on` is not a mapping"]
    problems = []
    extra = sorted(str(k) for k in set(on) - {"push", "workflow_dispatch"})
    if extra:
        problems.append(f"only push and workflow_dispatch may start a deploy, found {extra}")
    push = on.get("push")
    if not isinstance(push, dict) or push.get("branches") != ["main"]:
        problems.append("push must be limited to `branches: [main]`")
    elif "relay/**" not in as_list(push.get("paths")):
        problems.append("push must be path-filtered to relay/**")
    if "workflow_dispatch" not in on:
        problems.append("workflow_dispatch is missing")
    return problems


def p_permissions(ctx):
    wf = ctx["wf"]
    problems = []
    if wf.get("permissions") != {"contents": "read"}:
        problems.append(f"top-level permissions must be exactly {{contents: read}}, got {wf.get('permissions')!r}")
    for name, job in jobs_of(wf).items():
        perms = job.get("permissions")
        if isinstance(perms, dict) and "write" in perms.values():
            problems.append(f"job {name} widens permissions to write")
    return problems


def p_concurrency(ctx):
    conc = ctx["wf"].get("concurrency")
    if isinstance(conc, dict) and conc.get("group") == "relay-deploy" and conc.get("cancel-in-progress") is False:
        return []
    return ["need `group: relay-deploy` with `cancel-in-progress: false`: a running deploy must never be cancelled"]


def p_ci_gate(ctx):
    ci = jobs_of(ctx["wf"]).get("ci")
    if isinstance(ci, dict) and ci.get("uses") == "./.github/workflows/relay-ci.yml":
        return []
    return ["job `ci` must be `uses: ./.github/workflows/relay-ci.yml`: the deploy gates on the whole of relay-ci"]


def p_job_order(ctx):
    jobs = jobs_of(ctx["wf"])
    problems = []
    for name, wanted in (("canary", {"ci"}), ("production", {"ci", "canary"})):
        job = jobs.get(name)
        if not isinstance(job, dict):
            problems.append(f"job {name} is missing")
            continue
        missing = wanted - set(as_list(job.get("needs")))
        if missing:
            problems.append(f"job {name} must need {sorted(wanted)}, but does not need {sorted(missing)}")
    return problems


def p_environments(ctx):
    problems = []
    for name, want in (("canary", "relay-canary"), ("production", "relay-production")):
        env = (jobs_of(ctx["wf"]).get(name) or {}).get("environment")
        got = env.get("name") if isinstance(env, dict) else env
        if got != want:
            problems.append(f"job {name} must run in environment {want}, got {got!r}")
    return problems


def p_production_main_only(ctx):
    cond = (jobs_of(ctx["wf"]).get("production") or {}).get("if")
    if "github.ref == 'refs/heads/main'" in str(cond):
        return []
    return ["production must be conditioned on github.ref == 'refs/heads/main': workflow_dispatch can start from any branch"]


def p_pinned(ctx):
    problems = []
    vetted = {ref.split("@")[0]: ref for _, ref in uses_refs(ctx["ci"])}
    for name, ref in uses_refs(ctx["wf"]):
        action = ref.split("@")[0]
        if ref.startswith("./"):
            if not ref.startswith("./.github/workflows/"):
                problems.append(f"{name}: local `uses: {ref}` is not a workflow of this repo")
        elif not SHA_PINNED.match(ref):
            problems.append(f"{name}: `uses: {ref}` is not pinned to a 40-hex commit sha")
        elif action in vetted and vetted[action] != ref:
            problems.append(f"{name}: {action} is pinned differently from relay-ci.yml (one vetted sha per action)")
    return problems


def p_secrets(ctx):
    wf, text = ctx["wf"], ctx["text"]
    problems = []
    for name in ("CLOUDFLARE_API_TOKEN", "CLOUDFLARE_ACCOUNT_ID"):
        if text.count(name) < 2:
            problems.append(f"{name} is referenced {text.count(name)} time(s); both deploy jobs need it")
    if "CLOUDFLARE_API_TOKEN" in (wf.get("env") or {}):
        problems.append("the token is set at workflow level")
    for jname, job in jobs_of(wf).items():
        if "CLOUDFLARE_API_TOKEN" in (job.get("env") or {}):
            problems.append(f"job {jname}: the token is set at job level, so `npm ci` and its install scripts would see it")
        for i, step in enumerate(steps_of(job)):
            env, run = step.get("env") or {}, run_of(step)
            where = f"job {jname} step {i + 1}"
            touches_cloudflare = bool(re.search(r"wrangler\s+(deploy|rollback)\b", run))
            if "CLOUDFLARE_API_TOKEN" in run:
                problems.append(f"{where}: a run script mentions the token")
            if "CLOUDFLARE_API_TOKEN" in env and not touches_cloudflare:
                problems.append(f"{where}: carries the token but neither deploys nor rolls back")
            if touches_cloudflare:
                if env.get("CLOUDFLARE_API_TOKEN") != TOKEN_EXPR:
                    problems.append(f"{where}: must set CLOUDFLARE_API_TOKEN to {TOKEN_EXPR}")
                if env.get("CLOUDFLARE_ACCOUNT_ID") != ACCOUNT_EXPR:
                    problems.append(f"{where}: must set CLOUDFLARE_ACCOUNT_ID to {ACCOUNT_EXPR}")
    return problems


def p_deploy(ctx):
    problems = []
    for name in DEPLOY_JOBS:
        job = jobs_of(ctx["wf"]).get(name) or {}
        found = steps_running(job, r"wrangler\s+deploy\b")
        if len(found) != 1:
            problems.append(f"job {name} must have exactly one `wrangler deploy` step, has {len(found)}")
            continue
        step = found[0][1]
        run = run_of(step)
        if not step.get("id"):
            problems.append(f"job {name}: the deploy step needs an `id`; the rollback is conditioned on its outcome")
        if not run.strip().startswith("npx --no-install wrangler deploy"):
            problems.append(f"job {name}: deploy must run the lockfile-pinned wrangler (`npx --no-install wrangler deploy ...`)")
        if '--var "BUILD_ID:${GITHUB_SHA}"' not in run:
            problems.append(f'job {name}: deploy must inject the commit as --var "BUILD_ID:${{GITHUB_SHA}}"')
        targets_canary = re.search(r"--env[ =]canary\b", run) is not None
        if name == "canary" and not targets_canary:
            problems.append("canary deploy must pass `--env canary`, or it would deploy over production")
        if name == "production" and re.search(r"--env\b|\s-e\s", run):
            problems.append("production deploy must not pass --env")
    return problems


def p_check(ctx):
    problems = []
    for name, host in (("canary", "hmd-relay-canary"), ("production", "hmd-relay.")):
        job = jobs_of(ctx["wf"]).get(name) or {}
        deploy = steps_running(job, r"wrangler\s+deploy\b")
        rollback = steps_running(job, r"wrangler\s+rollback\b")
        checks = pinned_checks(job)
        if len(checks) != 1:
            problems.append(
                f'job {name} must have exactly one health check pinned to the commit '
                f'(`scripts/health-check.sh "$RELAY_URL" "$GITHUB_SHA"`), has {len(checks)}'
            )
            continue
        index, step = checks[0]
        if deploy and index < deploy[0][0]:
            problems.append(f"job {name}: the health check runs before the deploy")
        if rollback and index > rollback[0][0]:
            problems.append(f"job {name}: the health check runs after the rollback")
        url = str((step.get("env") or {}).get("RELAY_URL", ""))
        if host not in url or (name == "production" and "canary" in url):
            problems.append(f"job {name}: RELAY_URL must default to the {name} Worker's host, got {url!r}")
    return problems


def p_rollback(ctx):
    problems = []
    for name in DEPLOY_JOBS:
        job = jobs_of(ctx["wf"]).get(name) or {}
        deploy = steps_running(job, r"wrangler\s+deploy\b")
        found = steps_running(job, r"wrangler\s+rollback\b")
        if len(found) != 1:
            problems.append(f"job {name} must have exactly one `wrangler rollback` step, has {len(found)}")
            continue
        index, step = found[0]
        run = run_of(step)
        cond = str(step.get("if", ""))
        deploy_id = deploy[0][1].get("id") if deploy else None
        if "failure()" not in cond:
            problems.append(f"job {name}: the rollback must be conditioned on failure(), got `if: {cond}`")
        if not deploy_id or f"steps.{deploy_id}.outcome == 'success'" not in cond:
            problems.append(
                f"job {name}: the rollback must also require the deploy step to have succeeded; a failed "
                "deploy changed nothing, and rolling back would revert the previous good version"
            )
        checks = pinned_checks(job)
        if checks and index < checks[0][0]:
            problems.append(f"job {name}: the rollback is ordered before the health check it reacts to")
        for flag in ("--yes", "--message"):
            if flag not in run:
                problems.append(f"job {name}: rollback needs {flag} (it must not prompt in CI, and it records why)")
        if name == "canary" and not re.search(r"--env[ =]canary\b", run):
            problems.append("canary rollback must pass `--env canary`, or it would roll production back")
        if name == "production" and re.search(r"--env\b", run):
            problems.append("production rollback must not pass --env")
        if "scripts/health-check.sh" not in run.split("wrangler rollback", 1)[-1]:
            problems.append(f"job {name}: the rollback must be followed by a health check that it landed")
    return problems


def p_no_soften(ctx):
    problems = []
    for name, job in jobs_of(ctx["wf"]).items():
        if job.get("continue-on-error") not in (None, False):
            problems.append(f"job {name} sets continue-on-error")
        for i, step in enumerate(steps_of(job)):
            if step.get("continue-on-error") not in (None, False):
                problems.append(f"job {name} step {i + 1} sets continue-on-error, so a red step would not stop the pipeline")
    return problems


def p_no_interpolation(ctx):
    problems = []
    for name, job in jobs_of(ctx["wf"]).items():
        for i, step in enumerate(steps_of(job)):
            if "${{" in run_of(step):
                problems.append(
                    "job %s step %d: a ${{ }} expression inside a run script is shell injection waiting "
                    "for a hostile value; pass it through env" % (name, i + 1)
                )
    return problems


def p_timeouts(ctx):
    problems = []
    for name, job in jobs_of(ctx["wf"]).items():
        if "uses" in job:
            continue  # a called workflow carries its own timeouts
        if not isinstance(job.get("timeout-minutes"), int):
            problems.append(f"job {name} has no integer timeout-minutes; a wedged runner would hold the deploy lock")
    return problems


def p_defaults(ctx):
    problems = []
    for name in DEPLOY_JOBS:
        job = jobs_of(ctx["wf"]).get(name) or {}
        run_defaults = (job.get("defaults") or {}).get("run") or {}
        if run_defaults.get("working-directory") != "relay":
            problems.append(f"job {name} must default its run steps to working-directory: relay")
        if run_defaults.get("shell") != "bash":
            problems.append(f"job {name} must default its shell to bash (pipefail; the health check is a bash script)")
    return problems


def p_hygiene(ctx):
    problems = []
    ci_node = next(
        (
            str((s.get("with") or {}).get("node-version"))
            for j in jobs_of(ctx["ci"]).values()
            for s in steps_of(j)
            if str(s.get("uses", "")).startswith("actions/setup-node@")
        ),
        None,
    )
    for name in DEPLOY_JOBS:
        for i, step in enumerate(steps_of(jobs_of(ctx["wf"]).get(name) or {})):
            uses = str(step.get("uses", ""))
            with_ = step.get("with") or {}
            where = f"job {name} step {i + 1}"
            if uses.startswith("actions/checkout@") and with_.get("persist-credentials") is not False:
                problems.append(f"{where}: checkout must set persist-credentials: false")
            if uses.startswith("actions/setup-node@"):
                if "cache" in with_:
                    problems.append(f"{where}: no dependency cache in a job that holds the deploy token")
                if ci_node is None or str(with_.get("node-version")) != ci_node:
                    problems.append(f"{where}: node-version must equal relay-ci's ({ci_node}), the version the relay is verified on")
    return problems


def p_relay_ci(ctx):
    ci = ctx["ci"]
    problems = []
    on = triggers(ci)
    for key in ("workflow_call", "pull_request", "push"):
        if key not in on:
            problems.append(f"relay-ci.yml must keep the `{key}` trigger")
    group = str((ci.get("concurrency") or {}).get("group", ""))
    if "github.workflow" not in group or "github.ref" not in group:
        problems.append(
            "relay-ci.yml's concurrency group must include github.workflow and github.ref, or the deploy "
            "gate and the push-triggered run share a group and cancel each other"
        )
    return problems


def p_wrangler(ctx):
    try:
        tables = toml_tables(read(ctx["wrangler"]))
    except OSError as exc:
        return [f"cannot read wrangler.toml: {exc}"]
    top_name = tables[0][2].get("name")
    canary = [t[2] for t in tables if t[0] == "env.canary" and not t[1]]
    if len(canary) != 1:
        return ["wrangler.toml needs exactly one [env.canary] table"]
    problems = []
    name = canary[0].get("name")
    if name != '"hmd-relay-canary"':
        problems.append(f'[env.canary] name must be "hmd-relay-canary", got {name}')
    if name == top_name:
        problems.append("the canary Worker has the production Worker's name: deploying it would overwrite production")
    top_do = [t[2] for t in tables if t[0] == "durable_objects.bindings" and t[1]]
    canary_do = [t[2] for t in tables if t[0] == "env.canary.durable_objects.bindings" and t[1]]
    if not top_do:
        problems.append("no top-level durable_objects.bindings to compare the canary against")
    elif not canary_do:
        problems.append(
            "wrangler does not inherit durable_objects into an environment: [[env.canary.durable_objects.bindings]] "
            "must restate SESSION, or the canary deploys with no Durable Object and /health still passes"
        )
    elif canary_do != top_do:
        problems.append("the canary's durable_objects.bindings differ from production's")
    top_migrations = [t[2] for t in tables if t[0] == "migrations" and t[1]]
    canary_migrations = [t[2] for t in tables if t[0] == "env.canary.migrations" and t[1]]
    if canary_migrations and canary_migrations != top_migrations:
        problems.append("the canary restates migrations that differ from production's; omit them (they are inherited) or keep them identical")
    return problems


def p_health_script(ctx):
    path = ctx["health_script"]
    try:
        body = read(path)
    except OSError:
        return [f"{path} does not exist"]
    problems = []
    if "curl -fsS" not in body or "/health" not in body:
        problems.append("the script must GET /health with `curl -fsS`")
    if ctx["text"].count("scripts/health-check.sh") < 2:
        problems.append("both the canary and the production job must call scripts/health-check.sh")
    return problems


PROPERTIES = [
    ("triggers", "push to main touching relay/** and workflow_dispatch, nothing else", p_triggers),
    ("permissions", "least privilege: contents: read, and no job widens it", p_permissions),
    ("concurrency", "one deploy at a time; a running deploy is never cancelled", p_concurrency),
    ("ci-gate", "relay-ci.yml runs first, as a reusable workflow", p_ci_gate),
    ("job-order", "canary needs ci; production needs ci and canary", p_job_order),
    ("environments", "canary and production run in their own GitHub environments", p_environments),
    ("production-main-only", "production is reachable from main only", p_production_main_only),
    ("pinned", "every action is pinned to a 40-hex commit sha, the one relay-ci.yml vets", p_pinned),
    ("secrets", "the Cloudflare token reaches only the deploy and rollback steps", p_secrets),
    ("deploy", "each job deploys with the lockfile-pinned wrangler and injects the commit as BUILD_ID; the canary targets --env canary", p_deploy),
    ("check", "each job health-checks its own Worker for the commit it just deployed", p_check),
    ("rollback", "a failed check rolls the Worker back (only after a deploy that succeeded) and confirms it", p_rollback),
    ("no-soften", "no continue-on-error anywhere", p_no_soften),
    ("no-interpolation", "no ${{ }} expression inside a run script", p_no_interpolation),
    ("timeouts", "every job has a timeout", p_timeouts),
    ("defaults", "the deploy jobs run bash from relay/", p_defaults),
    ("hygiene", "no persisted checkout credentials, no dependency cache, relay-ci's Node", p_hygiene),
    ("relay-ci", "relay-ci.yml is callable and its concurrency cannot cancel the gate", p_relay_ci),
    ("wrangler", "[env.canary] is a separate Worker with its own Durable Object binding", p_wrangler),
    ("health-script", "scripts/health-check.sh exists, uses curl -fsS, and both jobs call it", p_health_script),
]


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--workflow", default=os.path.join(REPO, ".github", "workflows", "relay-deploy.yml"))
    parser.add_argument("--relay-ci", default=os.path.join(REPO, ".github", "workflows", "relay-ci.yml"))
    parser.add_argument("--wrangler", default=os.path.join(REPO, "relay", "wrangler.toml"))
    parser.add_argument("--health-script", default=os.path.join(REPO, "relay", "scripts", "health-check.sh"))
    args = parser.parse_args()

    try:
        text = read(args.workflow)
        wf = yaml.safe_load(text)
    except (OSError, yaml.YAMLError) as exc:
        print(f"FAIL yaml: cannot load {args.workflow}: {' '.join(str(exc).split())}")
        return 1
    if not isinstance(wf, dict) or not isinstance(wf.get("jobs"), dict):
        print("FAIL yaml: the workflow has no `jobs` mapping")
        return 1
    print("ok   yaml: relay-deploy.yml parses as YAML and has a jobs mapping")

    try:
        ci = yaml.safe_load(read(args.relay_ci)) or {}
    except (OSError, yaml.YAMLError):
        ci = {}
    ctx = {
        "wf": wf,
        "text": text,
        "ci": ci if isinstance(ci, dict) else {},
        "wrangler": args.wrangler,
        "health_script": args.health_script,
    }

    failed = 0
    for pid, description, check in PROPERTIES:
        try:
            problems = check(ctx)
        except Exception as exc:  # a crash must read as a failed property, never as a pass
            problems = [f"check crashed: {type(exc).__name__}: {exc}"]
        if problems:
            failed += 1
            for problem in problems:
                print(f"FAIL {pid}: {problem}")
        else:
            print(f"ok   {pid}: {description}")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
