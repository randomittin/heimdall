#!/usr/bin/env python3
"""Deliberately broken copies of the relay deploy pipeline, for test/relay-deploy-workflow.test.sh.

    relay_deploy_workflow_mutants.py list               # `<name> <property-id>` per mutant
    relay_deploy_workflow_mutants.py make <name> <dir>  # writes relay-deploy.yml, relay-ci.yml and
                                                        # wrangler.toml into <dir>, <name> applied

Each mutant breaks exactly one property of relay_deploy_workflow_check.py, so a checker that can no
longer fail shows up as a mutant it fails to catch. A mutant whose edit matches nothing is itself an
error: a stale pattern must never turn into a vacuous pass.
"""
import os
import re
import sys

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
FILES = {
    "workflow": (os.path.join(".github", "workflows", "relay-deploy.yml"), "relay-deploy.yml"),
    "relay-ci": (os.path.join(".github", "workflows", "relay-ci.yml"), "relay-ci.yml"),
    "wrangler": (os.path.join("relay", "wrangler.toml"), "wrangler.toml"),
}

CHECKOUT = "actions/checkout@11bd71901bbe5b1630ceea73d27597364c9af683"
CANARY_CHECK = '        run: bash scripts/health-check.sh "$RELAY_URL" "$GITHUB_SHA"\n'
DEPLOY_VAR = '--var "BUILD_ID:${GITHUB_SHA}"'


def rep(old, new, count=-1):
    return lambda text: text.replace(old, new, count)


def sub(pattern, new, flags=0):
    return lambda text: re.sub(pattern, new, text, flags=flags)


# (name, file to break, property that must go red, edit)
MUTANTS = [
    ("tag-pinned-checkout", "workflow", "pinned", rep(CHECKOUT, "actions/checkout@v4")),
    ("checkout-pin-differs-from-relay-ci", "workflow", "pinned", rep(CHECKOUT, "actions/checkout@" + "0" * 40, 1)),
    ("rollback-condition-removed", "workflow", "rollback", rep("        if: failure() && steps.deploy.outcome == 'success'\n", "")),
    ("rollback-step-removed", "workflow", "rollback", sub(r"\n      - name: Roll [^\n]*\n.*?(?=\n  [a-z]|\Z)", "", re.S)),
    ("rollback-without-confirmation", "workflow", "rollback", rep('          bash scripts/health-check.sh "$RELAY_URL"\n', "")),
    ("production-needs-removed", "workflow", "job-order", rep("    needs: [ci, canary]\n", "")),
    ("canary-environment-removed", "workflow", "environments", rep("    environment: relay-canary\n", "")),
    ("pull-request-target-trigger", "workflow", "triggers", rep("  workflow_dispatch:\n", "  workflow_dispatch:\n  pull_request_target:\n", 1)),
    (
        "token-at-job-level",
        "workflow",
        "secrets",
        rep(
            "    environment: relay-canary\n",
            "    environment: relay-canary\n    env:\n      CLOUDFLARE_API_TOKEN: ${{ secrets.CLOUDFLARE_API_TOKEN }}\n",
            1,
        ),
    ),
    ("token-in-run-script", "workflow", "secrets", rep(DEPLOY_VAR, DEPLOY_VAR + ' --token "$CLOUDFLARE_API_TOKEN"', 1)),
    ("continue-on-error-on-check", "workflow", "no-soften", rep(CANARY_CHECK, "        continue-on-error: true\n" + CANARY_CHECK, 1)),
    ("ci-gate-removed", "workflow", "ci-gate", rep("    uses: ./.github/workflows/relay-ci.yml\n", "    runs-on: ubuntu-latest\n    steps:\n      - run: 'true'\n")),
    ("canary-deploys-to-production", "workflow", "deploy", rep("wrangler deploy --env canary", "wrangler deploy", 1)),
    ("canary-wrangler-unpinned", "workflow", "deploy", rep("npx --no-install wrangler deploy", "npx wrangler@latest deploy", 1)),
    ("production-not-main-only", "workflow", "production-main-only", rep("    if: github.ref == 'refs/heads/main'\n", "")),
    ("expression-in-run-script", "workflow", "no-interpolation", rep(DEPLOY_VAR, '--var "BUILD_ID:${{ github.sha }}"', 1)),
    ("cache-in-deploy-job", "workflow", "hygiene", rep("          node-version: 24\n", "          node-version: 24\n          cache: npm\n", 1)),
    ("checkout-persists-credentials", "workflow", "hygiene", rep("          persist-credentials: false\n", "", 1)),
    ("canary-check-not-pinned-to-commit", "workflow", "check", rep(CANARY_CHECK, '        run: bash scripts/health-check.sh "$RELAY_URL"\n', 1)),
    ("timeout-removed", "workflow", "timeouts", rep("    timeout-minutes: 15\n", "", 1)),
    ("running-deploy-cancellable", "workflow", "concurrency", rep("cancel-in-progress: false", "cancel-in-progress: true")),
    ("permissions-widened", "workflow", "permissions", rep("permissions:\n  contents: read\n", "permissions:\n  contents: write\n", 1)),
    ("relay-ci-not-callable", "relay-ci", "relay-ci", rep("  workflow_call:\n", "")),
    ("relay-ci-concurrency-shared", "relay-ci", "relay-ci", rep("relay-ci-${{ github.workflow }}-${{ github.ref }}", "relay-ci-${{ github.ref }}")),
    ("canary-without-durable-object-binding", "wrangler", "wrangler", sub(r"\[\[env\.canary\.durable_objects\.bindings\]\]\n(?:[^\n\[]*\n)*", "")),
    ("canary-named-like-production", "wrangler", "wrangler", rep('name = "hmd-relay-canary"', 'name = "hmd-relay"', 1)),
]


def make(name, outdir):
    by_name = {m[0]: m for m in MUTANTS}
    if name not in by_name:
        sys.exit(f"unknown mutant {name!r}")
    _, target, _, edit = by_name[name]
    os.makedirs(outdir, exist_ok=True)
    for key, (src, dst) in FILES.items():
        with open(os.path.join(REPO, src), encoding="utf-8") as fh:
            text = fh.read()
        if key == target:
            mutated = edit(text)
            if mutated == text:
                sys.exit(f"mutant {name}: its edit matched nothing in {src}, so it would prove nothing")
            text = mutated
        with open(os.path.join(outdir, dst), "w", encoding="utf-8") as fh:
            fh.write(text)


def main(argv):
    if argv[:1] == ["list"]:
        for name, _, prop, _ in MUTANTS:
            print(name, prop)
        return 0
    if len(argv) == 3 and argv[0] == "make":
        make(argv[1], argv[2])
        return 0
    sys.exit(__doc__)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
