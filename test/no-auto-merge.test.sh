#!/usr/bin/env bash
#
# no-auto-merge.test.sh — RP10 item 7: no shipped code path merges or deploys without explicit human action.
#
#   bash test/no-auto-merge.test.sh               the gate (exit 0 = the human merge boundary holds)
#   bash test/no-auto-merge.test.sh --self-test   prove the gate can go RED (mutants) and stay GREEN (inverted mutants)
#   bash test/no-auto-merge.test.sh --survey      print every candidate hit and how it was classified
#   bash test/no-auto-merge.test.sh --keys        machine-readable violation keys (what --self-test diffs)
#
# THE CLAIM. Plan section 2.3, "Human merge boundary is permanent": overnight, cloud and other
# unattended work may observe -> research -> experiment -> prove -> open a PR. It may NEVER merge or
# deploy by default. This is the static half of that claim. It goes RED when a shipped file can merge,
# push, release or deploy and nothing in the repo says why a human is the one who does it.
#
# WHAT "SHIPPED" MEANS (a decision, stated so it can be argued with).
#   Scanned: agents/ bin/ commands/ conformance/ deploy/ hooks/ infra/ modules/ packages/ patches/
#   release/ relay/ sentinels/ skills/ heimdall-demo-app/ .claude-plugin/ .github/ and the root files
#   install.sh Dockerfile* vercel.json settings.json .mcp.json glama.json _redirects AGENTS.md CLAUDE.md.
#   Instruction files ARE shipped code paths: agents/, skills/, commands/ markdown plus any CLAUDE.md or
#   AGENTS.md. An instruction that tells an agent to merge or deploy is a hit. conformance/ is scanned
#   because heimdall-land's default gate set executes its fixtures.
#   NOT scanned: docs/ launch-docs/ test/ fixtures/ evals/ .planning/ .heimdall/, and every markdown or
#   text file outside the instruction roots (READMEs, runbooks, checklists). Those are documentation
#   for a human, never executed and never read as an agent's instructions.
#
# HOW A HIT IS CLASSIFIED (first rule that applies; anything left over is RED).
#   1. COMMENT   a whole-line comment in a code file. The comment leader must be the first non-blank
#                token, so `cmd  # gh pr merge` is still LIVE: only a comment that is the whole line
#                sits between the text and the interpreter.
#   2. NEGATION  in an instruction file, a clause that carries an explicit negator before the verb
#                ("NEVER merges", "NO push to main", "do not deploy"). Clauses end at punctuation and at
#                and/but/then/so/unless, so a negator cannot launder a later clause.
#   3. ALLOWLIST an entry below: exact file + primitive + a fragment of the line + a class + a reason.
#                No globs, no directories (a directory-wide exemption is a false green; the validator
#                rejects it). Classes: DOC, HINT, DATA (text that cannot execute); HUMAN-RUN (a script or
#                CLI only a human invokes; its invocation names are checked against every unattended
#                surface); GATED (explicit in-code guard, verified present); CI-TRIGGER (a workflow whose
#                triggers are parsed and must be human-only); BRANCH-PUSH (pushes one named non-protected
#                ref, guards verified); HUMAN-REQUESTED (an instruction conditional on the user asking
#                for that exact action); KNOWN-GAP (instruction text that tells an agent to release or
#                deploy with no human step in the text: never a merge, never code, and printed on every
#                run so it stays a decision somebody owns). An entry that matches nothing is STALE and fails.
#
# INVARIANTS ON TOP OF THE SCAN (the positive half of the claim).
#   bot      the PR-opening bot surfaces (bin/rr, the App-token mint, relay/, deploy/cloud-run, the
#            fixer and maintain definitions) carry no MERGE-kind hit that can execute.
#   unattended  nothing in hooks.json, autoupdate, the dream scheduler, the relay client or any
#            instruction file names a HUMAN-RUN or GATED script, and no such allowlist entry covers a
#            hit inside an unattended file.
#   remote   every action the phone can send is in a reviewed set and none names a merge or deploy verb.
#   ci       a workflow that deploys may only trigger on workflow_dispatch or a push to main.
#
# LIMITS, said plainly. This is a static tripwire against accidents and against an agent editing the
# repo, not a sandbox: a primitive hidden by string concatenation, encoding, or a command assembled at
# run time is out of reach. It reads text; it cannot see GitHub branch protection or environment
# reviewers, which are server-side settings. Prose rules are heuristic by nature. git pull and git
# fetch are not primitives: they move a LOCAL ref and cannot change shared main or production.
#
# POSTMORTEM. A result-string filter on '/.claude/worktrees/' once discarded every hit of a sibling gate
# because the repo itself lives under such a path, and the gate reported green for months. Here the walk
# starts at each shipped root and prunes by directory NAME at traversal; no absolute path is ever tested
# for a substring. --self-test plants a defect in a copy that lives under .claude/worktrees/ to keep it so.
set -uo pipefail

SELF="${BASH_SOURCE[0]}"
SELF_DIR="$(cd "$(dirname "$SELF")" && pwd)"
REPO="${NO_AUTO_MERGE_REPO:-$(cd "$SELF_DIR/.." && pwd)}"

usage() { sed -n '2,8p' "$SELF" | sed 's/^# \{0,1\}//'; }
case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  ""|--self-test|--keys|--survey) ;;
  *) usage >&2; exit 2 ;;
esac
command -v python3 >/dev/null 2>&1 || { echo "no-auto-merge: python3 not found" >&2; exit 2; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
GATE="$WORK/gate.py"

cat > "$GATE" <<'PYEOF'
import bisect
import json
import os
import re
import sys

REPO = os.path.abspath(sys.argv[1])
MODE = sys.argv[2] if len(sys.argv) > 2 else "report"

# ══════════════════════════════════════════════════════════════════════════════
# DATA 1 — THE SHIPPED SURFACE
# ══════════════════════════════════════════════════════════════════════════════
ROOT_DIRS = ("agents", "bin", "commands", "conformance", "deploy", "hooks", "infra", "modules",
             "packages", "patches", "release", "relay", "sentinels", "skills", "heimdall-demo-app",
             ".claude-plugin", ".github")
ROOT_FILES = ("install.sh", "Dockerfile", "Dockerfile.install", "Dockerfile.mcp", "vercel.json",
              "settings.json", ".mcp.json", "glama.json", "_redirects", "AGENTS.md", "CLAUDE.md")
# Directory NAMES pruned at traversal. Never an absolute-path substring: the repo lives under
# .claude/worktrees/ and a substring filter on that would discard every file.
PRUNE_NAMES = frozenset((".git", "node_modules", "__pycache__", ".venv", "venv", ".mypy_cache",
                         ".pytest_cache", ".tox"))
INSTRUCTION_ROOTS = ("agents", "skills", "commands")
INSTRUCTION_BASENAMES = ("CLAUDE.md", "AGENTS.md")
MAX_BYTES = 20000000
MAX_LINE = 20000
MIN_SCANNED = 300
# A file the gate reasons about by name. If a rename drops one, the gate says so instead of going quiet.
ANCHORS = ("hooks/hooks.json", "release/ship.sh", ".github/workflows/relay-deploy.yml",
           "bin/heimdall-land", "bin/heimdall-relay-client", "bin/lib/companion_ui_controls.py",
           "bin/lib/issue_pr.py", "agents/fixer.md", "commands/maintain.md")
REQUIRED_ROOTS = ("agents", "bin", "commands", "deploy", "hooks", "release", "relay", "sentinels", "skills")

# ══════════════════════════════════════════════════════════════════════════════
# DATA 2 — THE PRIMITIVES (reviewable: id, kind, scope, regex, anchors, what it is)
#   kind   merge | push | release | deploy      (the bot invariant forbids executing `merge`)
#   scope  all = every scanned file; instr = instruction markdown only (prose verbs)
#   anchors: lowercase substrings; a line is only tried against a primitive when it holds one.
#   <Q> = a quote character, <q> = quote characters inside a [...] class, <G> = git's global options.
# ══════════════════════════════════════════════════════════════════════════════
GIT_GLOBALS = r"(?:(?:-C|-c|--git-dir|--work-tree)(?:\s+|=)\S+\s+)*"
PRIM_TABLE = (
    ("gh-pr-merge", "merge", "all", r"\bgh\s+pr\s+merge\b", ("gh",),
     "gh pr merge: merges a pull request, or arms auto-merge on it"),
    ("gh-pr-approve", "merge", "all", r"\bgh\s+pr\s+review\b[^\n]*(?:--approve\b|\s-a\b)", ("gh",),
     "gh pr review --approve: the approval a merge waits on"),
    ("gh-api-merge", "merge", "all",
     r"\bgh\s+api\b[^\n]*?(?:/merges?\b|/pulls/[^\s<q>`]*/(?:merge|auto-merge|update-branch)\b|\bauto_merge\b|\bmerge_method\b)",
     ("gh",), "gh api against a merge endpoint"),
    ("rest-merge", "merge", "all",
     r"/pulls/[^\s<q>`)]*/merge\b|/repos/[^\s<q>`)]*/merges\b|\.pulls\.merge\b|\bmerge_pull_request\b|\bmerge_method\b|\bmergeMethod\b",
     ("merge",), "a GitHub REST merge call made from code"),
    ("graphql-merge", "merge", "all",
     r"\b(?:enablePullRequestAutoMerge|mergePullRequest|enqueuePullRequest|mergeBranch)\b",
     ("pullrequest", "mergebranch"), "GraphQL mutation that merges or arms auto-merge"),
    ("auto-merge", "merge", "all",
     r"\b(?:allow_auto_merge|enable_auto_merge|auto_merge|autoMerge|automerge|auto[- ]merg\w*|squash[- ]and[- ]merge|merge[- ]queue|merge[- ]when[- ]ready)\b",
     ("auto_merge", "automerge", "auto-merge", "auto merge", "squash", "merge queue", "merge-queue",
      "merge when", "merge-when"), "auto-merge, squash-and-merge, merge queue"),
    ("git-merge", "merge", "all",
     r"\bgit\s+<G>merge(?=\s|$|<Q>)|\[\s*<Q>git<Q>\s*,[^\]\n]*<Q>merge<Q>|\[\s*<Q>merge<Q>\s*[,\]]",
     ("merge",), "git merge (shell or argv form); merge-base/-tree/-file are not merges"),
    ("git-push", "push", "all",
     r"\bgit\s+<G>push\b|\[\s*<Q>git<Q>\s*,[^\]\n]*<Q>push<Q>|\[\s*<Q>push<Q>\s*[,\]]",
     ("push",), "git push (shell or argv form): publishes a ref, or main"),
    ("git-tag-create", "release", "all",
     r"\bgit\s+<G>tag\b(?!\s+(?:-l\b|--list\b|-d\b|--delete\b|-v\b|--verify\b|--contains\b|--no-contains\b|--points-at\b|--merged\b|--no-merged\b|--sort\b|-n\d*\b|--format\b))|\[\s*<Q>git<Q>\s*,[^\]\n]*<Q>tag<Q>",
     ("tag",), "git tag that creates a tag; listing tags is not a release"),
    ("wrangler-deploy", "deploy", "all",
     r"\bwrangler\s+(?:deploy|publish|rollback|delete|triggers\s+deploy|versions\s+(?:upload|deploy)|pages\s+(?:deploy|publish))\b|\[\s*<Q>wrangler<Q>\s*,[^\]\n]*<Q>(?:deploy|publish|rollback|delete)<Q>",
     ("wrangler",), "wrangler deploy/publish/rollback: ships a Cloudflare Worker"),
    ("gcloud-deploy", "deploy", "all",
     r"\bgcloud\b[^\n|;&]*?\s(?:deploy|builds\s+submit)\b|\bgcloud\s+run\s+(?:services\s+(?:replace|update|update-traffic)|jobs\s+(?:replace|update|deploy))\b",
     ("gcloud",), "gcloud ... deploy, builds submit, run services/jobs update"),
    ("vercel-deploy", "deploy", "all",
     r"\bvercel\s+(?:deploy|promote|rollback|alias|--prod)\b|\bvercel\b[^\n]*\s--prod\b",
     ("vercel",), "vercel deploy / --prod / promote"),
    ("netlify-deploy", "deploy", "all", r"\bnetlify\s+(?:deploy|build\s+--prod)\b", ("netlify",),
     "netlify deploy"),
    ("package-publish", "release", "all",
     r"\b(?:npm|pnpm|yarn)\s+publish\b|\bnpm\s+(?:dist-tag|deprecate|unpublish)\b|\btwine\s+upload\b|\bcargo\s+publish\b|\b(?:vsce|ovsx)\s+publish\b|\bgem\s+push\b|\bpoetry\s+publish\b",
     ("publish", "dist-tag", "deprecate", "twine", "gem push"), "publishing a package to a registry"),
    ("kubectl-mutate", "deploy", "all",
     r"\bkubectl\s+(?:apply|rollout|replace|patch|create|delete|scale|set|edit|expose|annotate|label|cordon|drain|taint|run)\b",
     ("kubectl",), "kubectl verbs that change a cluster (get/logs/describe are reads)"),
    ("iac-apply", "deploy", "all",
     r"\b(?:terraform|tofu)\s+(?:apply|destroy|import)\b|\bpulumi\s+(?:up|destroy)\b|\bhelm\s+(?:install|upgrade|rollback|uninstall)\b|\bcdk\s+(?:deploy|destroy)\b|\bsam\s+deploy\b|\b(?:serverless|sls)\s+deploy\b|\bansible-playbook\b",
     ("terraform", "tofu", "pulumi", "helm", "cdk", "sam ", "serverless", "sls", "ansible-playbook"),
     "infrastructure-as-code apply"),
    ("docker-push", "deploy", "all",
     r"\bdocker\s+(?:image\s+)?push\b|\bdocker\s+buildx\s+build\b[^\n]*--push\b|\bdocker\s+compose\s+push\b|\bpodman\s+push\b",
     ("docker", "podman"), "pushing an image to a registry"),
    ("gh-release", "release", "all",
     r"\bgh\s+release\s+(?:create|upload|edit|delete)\b|\bgh\s+workflow\s+run\b|\bgh\s+api\b[^\n]*(?:/dispatches\b|/releases\b|/git/refs\b|/contents/)|\[\s*<Q>gh<Q>\s*,\s*<Q>release<Q>\s*,\s*<Q>(?:create|upload|edit|delete)<Q>",
     ("gh",), "gh release create/upload, gh workflow run, ref/contents/dispatch writes"),
    ("paas-deploy", "deploy", "all",
     r"\b(?:fly|flyctl)\s+deploy\b|\bheroku\s+(?:container:release|releases:rollback|deploy)\b|\bfirebase\s+deploy\b|\brailway\s+up\b|\bsupabase\s+(?:db\s+push|functions\s+deploy)\b|\baws\s+(?:cloudformation\s+deploy|lambda\s+update-function-code|ecs\s+update-service|s3\s+(?:sync|cp|rm))\b|\baz\s+(?:webapp|functionapp)\s+deploy\b|\brender\s+deploy\b",
     ("fly", "heroku", "firebase", "railway", "supabase", "aws", "az ", "render"),
     "fly/heroku/firebase/railway/supabase/aws/az deploy verbs"),
    ("workflow-action", "deploy", "all",
     r"^\s*-?\s*uses:\s*\S*(?:wrangler-action|deploy-cloudrun|deploy-appengine|deploy-pages|pages-deploy|gh-pages|action-gh-release|create-release|pypi-publish|npm-publish|build-push-action|automerge|auto-merge|merge-me|merge-dependabot|enable-pull-request-automerge)",
     ("uses:",), "a third-party GitHub Action that deploys, publishes or merges"),
    # ── prose verbs: instruction markdown only ───────────────────────────────────
    ("p-merge", "merge", "instr",
     r"\bmerg(?:e|es|ing)\s+(?:(?:it|them)\b|(?:(?:the|this|that|your|its|each|every|all|any|a|an)\s+)?(?:\w+\s+){0,2}?(?:PRs?|pull[- ]requests?|branch(?:es)?|fix(?:es)?|patch(?:es)?|hotfix(?:es)?)\b)|\bmerg(?:e|es|ing)\b[^.\n]{0,40}\binto\s+(?:main|master|trunk|develop|production|prod)\b",
     ("merg",), "an instruction to merge something"),
    ("p-deploy", "deploy", "instr",
     r"\b(?:re)?deploy(?:s|ing)?\s+(?:it|them|this|that|fix(?:es)?|hotfix(?:es)?|patch(?:es)?|the\s+(?:fix(?:es)?|hotfix|patch|change|changes|build|release|service|app|package|code|update|migration)|(?:a|your)\s+(?:fix|hotfix|patch)|to\s+(?:prod|production|staging|the\s+(?:cluster|server)))\b|\bredeploy\w*\b",
     ("deploy",), "an instruction to deploy something"),
    ("p-release", "release", "instr",
     r"\bbatch(?:es|ed|ing)?\s+(?:[\w-]+\s+){0,3}?into\s+(?:a\s+|the\s+)?(?:(?:patch|minor|major|new)\s+)?releases?\b|\b(?:creat(?:e|es|ing)|cut(?:s|ting)?|draft(?:s|ing)?|publish(?:es|ing)?|issu(?:e|es|ing)|mak(?:e|es|ing)|trigger(?:s|ing)?|ship(?:s|ping)?)\s+(?:a\s+|an\s+|the\s+)?(?:(?:new|patch|minor|major|github|git|npm|release)\s+)*(?:release|tag)\b|\bmanag(?:e|es|ing)\s+releases?\b|(?:→|->|=>)\s*releases?\b",
     ("release",), "an instruction to cut or publish a release"),
    ("p-push-main", "push", "instr",
     r"\b(?:push(?:es|ing)?|force[- ]push\w*)\s+(?:\w+\s+){0,2}?(?:to|into)\s+(?:main|master|trunk|prod\w*|origin)\b",
     ("push",), "an instruction to push to main or origin"),
    ("p-publish", "release", "instr",
     r"\bpublish(?:es|ing)?\s+(?:it|them|this|the\s+(?:package|release|build|app|artifact|image)|a\s+(?:release|package)|to\s+(?:npm|pypi|crates|production|prod))\b",
     ("publish",), "an instruction to publish something"),
)

# Positive corpus: every sample MUST match its primitive. Negative corpus: no primitive may match any.
POSITIVE = (
    ("gh-pr-merge", "gh pr merge --auto 1"), ("gh-pr-merge", "gh pr merge 12 --squash --admin"),
    ("gh-pr-approve", "gh pr review 3 --approve"),
    ("gh-api-merge", "gh api -X PUT repos/o/r/pulls/3/merge"),
    ("gh-api-merge", "gh api repos/o/r/merges -f base=main -f head=x"),
    ("rest-merge", 'requests.put(f"{api}/repos/{r}/pulls/{n}/merge")'),
    ("rest-merge", "await octokit.pulls.merge({owner, repo, pull_number})"),
    ("graphql-merge", 'mutation { enablePullRequestAutoMerge(input: {pullRequestId: "x"}) { clientMutationId } }'),
    ("graphql-merge", "mergePullRequest(input: $in)"),
    ("auto-merge", "gh repo edit --enable-auto-merge"), ("auto-merge", "allow_auto_merge: true"),
    ("git-merge", "git merge --no-ff feature"), ("git-merge", 'git -C "$INTEG" merge --no-ff --no-commit "$SHA"'),
    ("git-merge", 'subprocess.run(["git", "merge", branch])'),
    ("git-push", "git push origin main"), ("git-push", "git push --force-with-lease origin HEAD"),
    ("git-push", 'git -C "$repo" push -q "$remote" "refs/heads/x:refs/heads/x"'),
    ("git-push", '_git(repo, ["push", "--force", "origin", ref])'),
    ("git-tag-create", "git tag v1.2.3"), ("git-tag-create", 'git tag -a "$TAG" -m msg'),
    ("wrangler-deploy", "npx wrangler deploy --env canary"), ("wrangler-deploy", "wrangler publish"),
    ("wrangler-deploy", "wrangler rollback --yes"),
    ("gcloud-deploy", "gcloud run deploy svc --image img"), ("gcloud-deploy", "gcloud builds submit --tag x"),
    ("gcloud-deploy", "gcloud run jobs replace job.yaml"),
    ("vercel-deploy", "vercel --prod"), ("vercel-deploy", "vercel deploy"),
    ("netlify-deploy", "netlify deploy --prod"),
    ("package-publish", "npm publish --access public"), ("package-publish", "twine upload dist/*"),
    ("kubectl-mutate", "kubectl apply -f x.yaml"), ("kubectl-mutate", "kubectl rollout restart deploy/x"),
    ("iac-apply", "terraform apply -auto-approve"), ("iac-apply", "helm upgrade --install x ./chart"),
    ("docker-push", "docker push repo/img:tag"),
    ("gh-release", "gh release create v1.0.0"), ("gh-release", "gh workflow run deploy.yml"),
    ("paas-deploy", "flyctl deploy --remote-only"), ("paas-deploy", "firebase deploy --only hosting"),
    ("workflow-action", "      - uses: peter-evans/enable-pull-request-automerge@v3"),
    ("p-merge", "When the tests are green, merge the PR yourself."),
    ("p-merge", "Then a reviewer merges it into main."),
    ("p-deploy", "Deploy fix, verify metrics return to baseline"), ("p-deploy", "or redeploy last-known-good"),
    ("p-deploy", "deploy to production when green"),
    ("p-release", "batch into patch release with semver bump"), ("p-release", "Create release tag + GitHub release"),
    ("p-release", "scan -> triage -> fix -> release -> communicate"),
    ("p-push-main", "push directly to main"), ("p-publish", "Publish to npm when done."),
)
NEGATIVE = (
    "git merge-base --is-ancestor main HEAD", "git merge-tree $(git merge-base HEAD main) HEAD stash@{0}",
    "git merge-file -p a b c", "git tag --list 'v[0-9]*' --sort=-v:refname", "git tag -l", "git describe --tags --abbrev=0",
    "git fetch origin main", "git pull --ff-only", "git status --short", "git diff --stat",
    "gh pr create --title x --body y", "gh pr view 12 --json state", "gh pr list --state merged --limit 5",
    "gh api user --jq .login", "gh api repos/o/r --jq .private", "gh release view v1.2.3",
    "docker pull alpine:3", "docker build -t img .", "wrangler dev --local", "wrangler whoami",
    "npm install && npm test", "npm run build", "terraform plan -out tf.plan", "terraform fmt",
    "kubectl get pods -n prod", "kubectl logs deploy/api", "gcloud auth print-access-token",
    "gcloud run services describe svc --region r", "helm template .", "vercel --version",
    "Shared writes -> merge conflicts when parallel.", "Rollback if recent deploy caused it",
    "Correlate w/ recent deploys, config changes, cron jobs", "Test migrations on prod-size dataset before deploy",
    "Deploy command: [if known]", "If error NO LONGER appears in logs -> the fix was deployed and worked:",
    "Reap merged agent worktrees at the top of each sweep", 'run `alembic merge heads -m "merge"` to create a merge migration',
    "deploy history", "the release queue is empty", "Auto-update checks GitHub Releases for new signed versions.",
)
# Negation corpus: the primitive matches, and the clause logic must classify it NEGATION / must NOT.
NEGATED = (
    ("p-push-main", "NEVER pushes to main, NEVER merges."), ("p-merge", "You must never merge the PR yourself."),
    ("p-merge", "Do not merge it or deploy it."), ("p-push-main", "NO push to main, NO merge"),
    ("p-merge", "never merge them"), ("git-push", "- **Agent-never-pushes** — `/dream` runs no `git push`, no `gh pr`"),
)
NOT_NEGATED = (
    ("p-merge", "Never skip tests, then merge the PR."), ("p-merge", "Do not wait; merge the PR now."),
    ("p-deploy", "Deploy fix, verify metrics return to baseline"),
    ("p-merge", "Never push broken code and merge the PR anyway."),
)

# ══════════════════════════════════════════════════════════════════════════════
# DATA 3 — THE ALLOWLIST
#   A(file, primitive(s), fragment-of-the-line, class, reason, guards=, names=, triggers=)
#   guards   regexes that must each match a line of the file (the in-code gate, verified, not trusted)
#   names    regexes that name how a human reaches this script; they must not appear on any unattended surface
#   triggers a workflow's allowed `on:` set ("workflow_dispatch", "push:main")
# ══════════════════════════════════════════════════════════════════════════════
CLASSES = ("DOC", "HINT", "DATA", "HUMAN-RUN", "GATED", "CI-TRIGGER", "BRANCH-PUSH", "HUMAN-REQUESTED", "KNOWN-GAP")
NONEXEC = ("DOC", "HINT", "DATA")
UNATTENDED_FORBIDDEN = ("HUMAN-RUN", "GATED", "CI-TRIGGER", "HUMAN-REQUESTED")


def A(file, prims, fragment, cls, reason, guards=(), names=(), triggers=()):
    return {"file": file, "prims": (prims,) if isinstance(prims, str) else tuple(prims), "fragment": fragment,
            "cls": cls, "reason": reason, "guards": tuple(guards), "names": tuple(names),
            "triggers": tuple(triggers)}


ALLOW = [
    # ── instruction text that tells an agent to ship, release or deploy ──────────────────────────────────────
    # HUMAN-REQUESTED is for a row that only fires when the user asks for that action. KNOWN-GAP is for text that
    # releases or deploys with no human-confirmation step in the text itself, and it is EMPTY on purpose: the nine
    # rows this gate found on 2026-10-05 (maintainer guide, incident responder, the maintain-cycle summary in
    # agents/heimdall.md) were reworded on 2026-10-06 so the agent prepares the release or fix and stops for the
    # operator to run it, and the gate now enforces that wording. The class stays so that a future gap is a
    # decision someone owns (main_report prints it on every run), never a silent one.
    A("agents/heimdall.md", "git-tag-create", "Execute + verify + git tag + changelog + push", "HUMAN-REQUESTED",
      "routing-table row: Ship mode is entered only when the user's own prompt says ship, deploy or release"),
    # ── DOC / DATA / HINT: text that mentions a push, merge or deploy without being able to run one ────────
    A("agents/architect.md", "p-merge", "merge them into one task", "DOC",
      "planning advice to fold two same-file tasks into one task; no code is merged"),
    A("agents/architect.md", "git-push", "**Bash `git push`**", "DOC",
      "hook-awareness note: describes the pre-push quality gate that blocks a failing push; instructs no push"),
    A("agents/coder.md", "git-push", "**Bash `git push`**", "DOC",
      "hook-awareness note: describes the pre-push quality gate that blocks a failing push; instructs no push"),
    A("agents/heimdall.md", "git-push", "Before ANY `git push`, verify ALL of these", "DOC",
      "pre-push checklist: conditions to meet before a work-branch push; it instructs no merge and no push to main"),
    A("agents/heimdall.md", "auto-merge", "better than a bad auto-merge", "DOC",
      "risk-preference sentence (escalate rather than auto-merge badly); it instructs no merge"),
    A("agents/heimdall.md", "p-release", "cutting a release", "DOC",
      "pointer saying when to read git-workflow.md (naming a branch, cutting a release, choosing a bump); not an instruction to release"),
    A("skills/heimdall/references/git-workflow.md", "p-release", "cutting a release", "DOC",
      "pointer saying when to read this file (naming a branch, cutting a release, choosing a bump); not an instruction to release"),
    A("skills/heimdall/references/maintainer-guide.md", "auto-merge", "better than a bad auto-merge", "DOC",
      "risk-preference sentence (escalate rather than auto-merge badly); it instructs no merge"),
    A("skills/heimdall/references/quality-gates.md", "git-push", "intercepts `git push` commands", "DOC",
      "describes what the PreToolUse hook does to a push (runs check-quality-gates); instructs no push"),
    A("CLAUDE.md", "git-push", "(enforced before git push)", "DOC",
      "section heading naming the pre-push quality gates; instructs no push"),
    A("CLAUDE.md", "git-push", "The `git push` hook stack", "DOC",
      "describes the pre-push hook stack that blocks a bad push; instructs no push"),
    A("CLAUDE.md", "git-push", "PreToolUse `git push` chain", "DOC",
      "describes the PreToolUse push-gate chain and its dedup with the native hook; instructs no push"),
    A("packages/runheimdall/CLAUDE.md", "git-push", "(enforced before git push)", "DOC",
      "section heading naming the pre-push quality gates; instructs no push"),
    A("bin/heimdall-precheck-bash", "git-push", "CLAUDE.md enforces quality gates before git push", "DOC",
      "the message the PreToolUse gate prints when it BLOCKS a push for a failed quality gate"),
    A("bin/lib/rule-inventory.sh", "git-push", "before .*git push", "DATA",
      "a row in the rule-inventory table mapping a CLAUDE.md rule to the hook that enforces it"),
    A("bin/lib/phone_deny_risk.py", "git-push", "git push (any form)", "DATA",
      "docstring row for one risk class the PHONE may veto: this table decides what gets held for a human, it runs nothing"),
    A("bin/lib/phone_deny_risk.py", ("kubectl-mutate", "iac-apply"), "terraform apply, kubectl delete, helm upgrade", "DATA",
      "docstring row for the deploy risk class the PHONE may veto: classifier text, it runs nothing"),
    A("conformance/INDEX.json", "git-push", "Hook PreToolUse Bash on git push", "DATA",
      "a conformance-matrix row naming the PreToolUse push gate; data, not a command"),
    A("bin/lib/funnel.py", "git-tag-create", "resolved from the git tag / manifest", "DOC",
      "docstring: says the version is READ from the nearest tag; it creates no tag"),
    A("bin/lib/collision.py", "auto-merge", "SURFACE > auto-merge:", "DOC",
      "docstring of the collision classifier: divergent bodies are SURFACED to a human, never auto-merged"),
    A("bin/lib/collision.py", "auto-merge", "decide (never auto-merged)", "DOC",
      "the message shown to the human for a flagged collision; it says nothing is auto-merged"),
    A("bin/lib/issue_pr.py", "git-push", "The child env for the `git push` of the heimdall/* branch", "DOC",
      "docstring of the bot's push-environment helper (heimdall/* branch only); see the BRANCH-PUSH entry for the push itself"),
    A("bin/lib/issue_pr.py", "git-push", "git push exited nonzero", "DOC",
      "the error text raised when the bot's branch push fails; it runs nothing"),
    A("bin/heimdall", "git-push", "HEIMDALL_SKIP_ID_GUARD=1 git push", "HINT",
      "printed for the human: the emergency identity bypass command they would type themselves"),
    A("bin/heimdall-check-identities", "git-push", "HEIMDALL_SKIP_ID_GUARD=1 git push", "HINT",
      "printed for the human: the emergency identity bypass command they would type themselves"),
    A("bin/heimdall-god", "gcloud-deploy", "gcloud run services update heimdall-control-plane", "HINT",
      "an error message telling the owner which command to run to grant owner; the CLI never runs it"),
    A("bin/heimdall-invite", "git-push", "git push \"$REMOTE\" HEAD --follow-tags", "HINT",
      "printed for the human inside a refusal: push your release and tag first; heimdall-invite never pushes"),
    A("bin/heimdall-volatile-repo-guard", "git-push", "git push --all", "HINT",
      "printed for the human: how to give an unpushed repo a remote; the guard never pushes"),
    A("bin/heimdall-volatile-repo-guard", "git-push", "git push --tags", "HINT",
      "printed for the human: how to give an unpushed repo a remote; the guard never pushes"),
    A("bin/heimdall-volatile-repo-guard", "git-push", "git push -u origin", "HINT",
      "printed for the human: how to give an unpushed repo a remote; the guard never pushes"),
    A("bin/heimdall-land", "git-push", "run: git -C $REPO push $REMOTE $MAIN", "HINT",
      "printed for the human when --no-shared-push holds the shared-main push back: the exact command to type"),
    A("deploy/cloud-run/verify-flight-fix.sh", "gcloud-deploy", "Redeploy with it (gcloud run services update", "HINT",
      "an error message telling the operator how to fix the deploy; the verifier does not run it"),
    A("deploy/cloud-run/verify-flight-fix.sh", "gcloud-deploy", "gcloud run services update failed", "HINT",
      "an error message reporting that the operator-run verifier's own revision roll failed"),
    A("skills/heimdall/references/quality-gates.md", "git-push", "git push ...", "HUMAN-REQUESTED",
      "Manual Override block: applies only when the user explicitly says 'push anyway' or 'force push' at autonomy level 3; the user's own words are the trigger"),

    # ── BRANCH-PUSH: pushes exactly one named, non-protected ref; the in-code guard is verified ──────────
    A("bin/heimdall-context-sync", "git-push", "push -q \"$remote\" \"refs/heads/$CONTEXT_BRANCH:refs/heads/$CONTEXT_BRANCH\"",
      "BRANCH-PUSH",
      "hook-run sync pushes only the orphan context branch hmd/context (a payload of notes, never code, never main)",
      guards=(r'^CONTEXT_BRANCH="hmd/context"\s*$',)),
    A("bin/lib/issue_pr.py", "git-push", "push = _git(repo, [\"push\", \"--force\", \"origin\",", "BRANCH-PUSH",
      "the PR bot pushes only its own heimdall/* branch (refspec built from that branch, main/master/base refused) and then opens a PR; a human merges",
      guards=(r'branch\.startswith\("heimdall/"\)', r'branch in \("main", "master"\) or branch == base',
              r'"%s:refs/heads/%s" % \(branch, branch\)')),

    # ── GATED: refuses to act unless an explicit human argument is given; the guard is verified ──────────
    A("deploy/cloud-run/deploy-public-surface.sh", "gcloud-deploy", "gcloud run deploy", "GATED",
      "plan-only unless the operator passes the explicit `apply` argument; the default prints and runs nothing",
      guards=(r'^MODE="\$\{1:-plan\}"', r'\[ "\$MODE" = "apply" \] && "\$@"'),
      names=(r"\bdeploy-public-surface\.sh\b",)),

    # ── HUMAN-RUN: a script or CLI only a human invokes. Its names are checked against every unattended
    #    surface (hooks, autoupdate, dream, relay client, instruction files, other workflows). ───────────────
    A("bin/heimdall-land", "git-push", "push --force-with-lease \"$REMOTE\"", "HUMAN-RUN",
      "HUMAN-RUN CLI reached only as the `hmd land` subcommand; force-with-lease on the developer's OWN branch. No in-code confirmation: the human is the trigger",
      names=(r"\bheimdall-land\b", r"\b(?:hmd|heimdall)\s+land\b")),
    A("bin/heimdall-land", "git-merge", "merge --no-ff --no-commit", "HUMAN-RUN",
      "HUMAN-RUN CLI reached only as `hmd land`; merges the branch onto current main in a THROWAWAY detached worktree to gate the merged state, not on a shared ref",
      names=(r"\bheimdall-land\b", r"\b(?:hmd|heimdall)\s+land\b")),
    A("bin/heimdall-land", "git-push", "push \"$REMOTE\" \"refs/heads/$MAIN:refs/heads/$MAIN\"", "HUMAN-RUN",
      "HUMAN-RUN CLI reached only as `hmd land`: AUTO-LANDS to shared main when the merged-state gates pass, with NO in-code confirmation (the human typing `hmd land` is the trigger; --no-shared-push holds the push)",
      names=(r"\bheimdall-land\b", r"\b(?:hmd|heimdall)\s+land\b")),
    A("release/ship.sh", "gh-release", "gh release edit", "HUMAN-RUN",
      "the maintainer's release script (publish-checklist.md: npm publish is 'RJ-EXECUTED'); signing needs the maintainer-held minisign key",
      names=(r"\bship\.sh\b",)),
    A("release/ship.sh", "gh-release", "gh release create", "HUMAN-RUN",
      "the maintainer's release script, run from a terminal with the maintainer's gh login; creates the Release for a tag they just pushed",
      names=(r"\bship\.sh\b",)),
    A("release/ship.sh", "gh-release", "gh release upload", "HUMAN-RUN",
      "the maintainer's release script: attaches the minisign signature made with the maintainer-held key (an unsigned release is refused by clients)",
      names=(r"\bship\.sh\b",)),
    A("release/ship.sh", "package-publish", "npm publish", "HUMAN-RUN",
      "the maintainer's release script: npm publish pins --auth-type=web, an interactive browser login only the maintainer can complete",
      names=(r"\bship\.sh\b",)),
    A("release/ship.sh", "git-tag-create", "git tag \"$TAG\"", "HUMAN-RUN",
      "the maintainer's release script: tags the release commit it just verified; run by the maintainer from a terminal",
      names=(r"\bship\.sh\b",)),
    A("release/ship.sh", "git-push", "git push origin \"$TAG\"", "HUMAN-RUN",
      "the maintainer's release script: pushes the tag it just created; run by the maintainer from a terminal",
      names=(r"\bship\.sh\b",)),
    A("release/ship.sh", "git-push", "git push origin \"$BRANCH\"", "HUMAN-RUN",
      "the maintainer's release script: pushes the release commit to main after the local pre-push gates are green; run by the maintainer from a terminal",
      names=(r"\bship\.sh\b",)),
    A("release/sync-release.sh", "git-push", "push origin main", "HUMAN-RUN",
      "step 1 of release/publish-checklist.md, run by the release maintainer: commits the site pin and pushes the SITE repo (auto-deploys /install); also hint text",
      names=(r"\bsync-release\.sh\b",)),
    A("release/sync-release.sh", "package-publish", "npm publish", "HINT",
      "printed for the maintainer: the next checklist step ('RJ executes release/publish-checklist.md'); this script never publishes"),
    A("deploy/cloud-run/go-live.sh", "gcloud-deploy", "gcloud builds submit", "HUMAN-RUN",
      "'THE GUIDED OPERATOR ... a sequencer RJ runs INTERACTIVELY' (spend-incurring); --plan runs nothing",
      names=(r"\bgo-live\.sh\b",)),
    A("deploy/cloud-run/go-live.sh", "gcloud-deploy", "gcloud run deploy", "HUMAN-RUN",
      "'THE GUIDED OPERATOR ... a sequencer RJ runs INTERACTIVELY' (spend-incurring); --plan runs nothing",
      names=(r"\bgo-live\.sh\b",)),
    A("deploy/cloud-run/deploy-arch-b.sh", "gcloud-deploy", "gcloud builds submit", "HUMAN-RUN",
      "'RUN BY THE OPERATOR (RJ) on his own machine with his gcloud creds ... the agent never runs this'; --dry-run prints the plan only",
      names=(r"\bdeploy-arch-b\.sh\b",)),
    A("deploy/cloud-run/deploy-maintainer.sh", "gcloud-deploy", "gcloud run jobs replace", "HUMAN-RUN",
      "'RUN BY THE OPERATOR on their own machine ... The agent never runs this'; --dry-run prints the plan only",
      names=(r"\bdeploy-maintainer\.sh\b",)),
    A("deploy/cloud-run/deploy-public-rr.sh", "gcloud-deploy", "gcloud run services update", "HUMAN-RUN",
      "'RUN BY THE OPERATOR (RJ) on his OWN machine with his OWN already-authenticated gcloud ... The agent never runs this'; --dry-run prints the plan only",
      names=(r"\bdeploy-public-rr\.sh\b",)),
    A("deploy/cloud-run/create-maintainer-test-repo.sh", "git-push", "push -q -u origin HEAD:main", "HUMAN-RUN",
      "'RUN BY THE OPERATOR (RJ) ... The agent never runs this'; pushes the scaffold to a THROWAWAY sandbox repo it just created, never a real codebase",
      names=(r"\bcreate-maintainer-test-repo\.sh\b",)),
    A("deploy/cloud-run/verify-flight-fix.sh", "gcloud-deploy", "if gcloud run services update", "HUMAN-RUN",
      "'HOW RJ RUNS IT (live target, RJ's creds)': needs the operator's own identity token and PKI seed in env; step 4 rolls a no-op, digest-pinned revision",
      names=(r"\bverify-flight-fix\.sh\b",)),
    A("relay/package.json", "wrangler-deploy", "\"deploy\": \"wrangler deploy\"", "HUMAN-RUN",
      "an npm script a human runs by hand (`npm run deploy`); the CI deploy goes through relay-deploy.yml, not this script",
      names=(r"\bnpm\s+run\s+deploy\b",)),

    # ── CI-TRIGGER: a workflow that deploys; its `on:` block is parsed and must be human-only ───────────
    A(".github/workflows/relay-deploy.yml", "wrangler-deploy", "wrangler deploy --env canary", "CI-TRIGGER",
      "runs only on workflow_dispatch or a push to main (= a human-merged PR; agents hold no merge), never on pull_request or a schedule; behind a GitHub environment",
      guards=(r"^\s+environment:\s*relay-canary\s*$", r"^\s+environment:\s*relay-production\s*$",
              r"if: github\.ref == 'refs/heads/main'"),
      triggers=("workflow_dispatch", "push:main")),
    A(".github/workflows/relay-deploy.yml", "wrangler-deploy", "wrangler rollback --env canary", "CI-TRIGGER",
      "automatic rollback inside the same human-triggered pipeline, after its own failed health check; same verified triggers",
      guards=(r"^\s+environment:\s*relay-canary\s*$",), triggers=("workflow_dispatch", "push:main")),
    A(".github/workflows/relay-deploy.yml", "wrangler-deploy", "wrangler deploy --var", "CI-TRIGGER",
      "production deploy: main only (`if: github.ref == 'refs/heads/main'`), after relay-ci and the canary, behind the relay-production environment",
      guards=(r"^\s+environment:\s*relay-production\s*$", r"if: github\.ref == 'refs/heads/main'"),
      triggers=("workflow_dispatch", "push:main")),
    A(".github/workflows/relay-deploy.yml", "wrangler-deploy", "wrangler rollback --yes", "CI-TRIGGER",
      "automatic production rollback inside the same human-triggered pipeline, after its own failed health check; same verified triggers",
      guards=(r"^\s+environment:\s*relay-production\s*$",), triggers=("workflow_dispatch", "push:main")),
]

# ══════════════════════════════════════════════════════════════════════════════
# DATA 4 — INVARIANTS
# ══════════════════════════════════════════════════════════════════════════════
# PR-opening bot surfaces: MERGE-kind hits here may be text only. (A directory entry here is a
# strictness scope, not an exemption.)
BOT_FILES = ("bin/rr", "bin/heimdall-gh-app-token", "bin/heimdall-issue-pr", "bin/lib/issue_pr.py",
             "bin/heimdall-maintain-loop", "bin/lib/maintain_loop.py", "agents/fixer.md", "agents/seeker.md",
             "commands/maintain.md", "commands/maintain-check.md",
             "skills/heimdall/references/maintainer-guide.md")
BOT_DIRS = ("relay", "deploy/cloud-run")
# Unattended entry points that hooks.json does not name. hooks.json (and settings.json) command strings
# are parsed for every bin/ sentinels/ hooks/ script they run; those join this set automatically.
UNATTENDED_EXTRA = ("bin/heimdall-autoupdate", "bin/heimdall-maintain-loop", "bin/heimdall-dream",
                    "bin/heimdall-dream-schedule", "bin/heimdall-dream-notice", "bin/heimdall-relay-client",
                    "bin/heimdall-phone-control", "bin/heimdall-inbox-deliver", "bin/lib/companion_ui_controls.py",
                    "bin/lib/maintain_loop.py", "deploy/cloud-run/heimdall-maintainer-job.yaml")
# Every action a paired phone can send. A new one must be reviewed against the human merge boundary
# and added here on purpose.
REVIEWED_REMOTE_ACTIONS = ("send-message", "decide", "view", "resync", "register_push", "unregister_push",
                           "app_state", "login_start", "login_code", "login_cancel", "interrupt",
                           "save-checkpoint", "hook-toggle", "fallback-mode")
REMOTE_DENY = re.compile(r"\b(?:merge|deploy|publish|release|ship|land|rollout|apply|approve|push|tag|git)\b", re.I)

# ══════════════════════════════════════════════════════════════════════════════
# LOGIC
# ══════════════════════════════════════════════════════════════════════════════
class Prim(object):
    def __init__(self, pid, kind, scope, rx, anchors, desc):
        self.id, self.kind, self.scope, self.rx, self.anchors, self.desc = pid, kind, scope, rx, anchors, desc


def build_prims():
    out = []
    for pid, kind, scope, pattern, anchors, desc in PRIM_TABLE:
        pat = pattern.replace("<Q>", "['\"]").replace("<q>", "'\"").replace("<G>", GIT_GLOBALS)
        out.append(Prim(pid, kind, scope, re.compile(pat, re.I if scope == "instr" else 0),
                        tuple(a.lower() for a in anchors), desc))
    return out


PRIMS = build_prims()
PRIM_BY_ID = dict((p.id, p) for p in PRIMS)
# One alternation of every anchor: a line that matches none of them cannot match any primitive.
QUICK_RX = re.compile("|".join(sorted(set(re.escape(a) for p in PRIMS for a in p.anchors), key=len, reverse=True)))

NEGATORS = re.compile(
    r"\b(?:never|no|not|nor|neither|without|cannot|can't|won't|don't|doesn't|didn't|isn't|aren't|mustn't|"
    r"shouldn't|refus\w*|forbid\w*|prohibit\w*|disallow\w*|avoid\w*|prevent\w*|instead of|rather than)\b|"
    r"\b(?:do|does|did|must|may|should|shall|will|is|are|can)\s+not\b", re.I)
CLAUSE_BREAK = re.compile(
    r"[.;:!?()\[\]|,—–]|--|->|=>|→|\b(?:and|but|then|so|yet|except|unless|until|because|which|while)\b",
    re.I)
CONT_RX = re.compile(r"(?:\\|,|\(|\[|\{|\||&&|\|\|)$")
HASH_EXT = (".sh", ".bash", ".zsh", ".py", ".yml", ".yaml", ".toml", ".tsv", ".conf", ".cfg", ".ini", ".env",
            ".service", ".rb", ".pl")
SLASH_EXT = (".js", ".mjs", ".cjs", ".ts", ".tsx", ".jsx", ".c", ".h", ".css")
HTML_EXT = (".html", ".htm", ".xml", ".plist", ".svg")
PROSE_EXT = (".md", ".mdx", ".txt")
BACKUP_SUFFIXES = (".bak", ".orig", ".example", ".sample", ".tmpl", ".template", ".in")


def norm(text):
    return " ".join(text.split())[:160]


def negated(text, start):
    prefix = text[:start]
    cut = 0
    for m in CLAUSE_BREAK.finditer(prefix):
        cut = m.end()
    return bool(NEGATORS.search(prefix[cut:]))


def comment_flags(lines, kind):
    """One bool per line: True when the line carries comment and NO live code character.
    `#` files: the first non-blank token is `#`. `//` and `/* */` files and html: a small state machine,
    so `*/ exec(...)` and `/* a */ exec(...) /* b */` stay LIVE and only a line that is all comment is not."""
    if kind == "hash":
        return [ln.lstrip().startswith("#") for ln in lines]
    if kind not in ("slash", "html"):
        return [False] * len(lines)
    block_open, block_close, line_leader = ("/*", "*/", "//") if kind == "slash" else ("<!--", "-->", None)
    flags, in_block = [], False
    for ln in lines:
        live, i, n = False, 0, len(ln)
        while i < n:
            if in_block:
                j = ln.find(block_close, i)
                if j < 0:
                    break
                in_block, i = False, j + len(block_close)
            elif line_leader and ln.startswith(line_leader, i):
                break
            elif ln.startswith(block_open, i):
                in_block, i = True, i + len(block_open)
            else:
                if not ln[i].isspace():
                    live = True
                i += 1
        flags.append(not live)
    return flags


def file_kind(rel, first):
    low = os.path.basename(rel).lower()
    for sfx in BACKUP_SUFFIXES:
        if low.endswith(sfx) and len(low) > len(sfx):
            low = low[:-len(sfx)]
            break
    ext = os.path.splitext(low)[1]
    if low.startswith("dockerfile") or low in (".gitignore", ".dockerignore", "makefile"):
        return "hash"
    if ext in PROSE_EXT:
        return "prose"
    if ext == ".json":
        return "data"
    if ext in HASH_EXT:
        return "hash"
    if ext in SLASH_EXT:
        return "slash"
    if ext in HTML_EXT:
        return "html"
    if first.startswith("#!"):
        return "slash" if re.search(r"\b(?:node|deno|bun)\b", first) else "hash"
    return "other"


def is_instruction(rel):
    base = os.path.basename(rel)
    if base in INSTRUCTION_BASENAMES:
        return True
    return rel.split("/", 1)[0] in INSTRUCTION_ROOTS and base.lower().endswith((".md", ".mdx", ".txt"))


def walk_shipped():
    out = []
    for d in ROOT_DIRS:
        base = os.path.join(REPO, d)
        if not os.path.isdir(base):
            continue
        for cur, dirs, files in os.walk(base):
            dirs[:] = sorted(x for x in dirs if x not in PRUNE_NAMES)
            for f in sorted(files):
                out.append(os.path.relpath(os.path.join(cur, f), REPO).replace(os.sep, "/"))
    for f in ROOT_FILES:
        if os.path.isfile(os.path.join(REPO, f)):
            out.append(f)
    return out


def read_text(rel):
    path = os.path.join(REPO, rel)
    if os.path.islink(path):
        return None, "symlink"
    try:
        with open(path, "rb") as fh:
            raw = fh.read(MAX_BYTES + 1)
    except OSError as exc:
        return None, "unreadable: %s" % (exc.strerror or exc)
    if len(raw) > MAX_BYTES:
        return None, "oversize"
    if b"\0" in raw[:8192]:
        return None, "binary"
    return raw.decode("utf-8", "replace"), None


class Hit(object):
    def __init__(self, file, line, prim, text, status, ctx):
        self.file, self.line, self.prim, self.text = file, line, prim, text
        self.status, self.ctx, self.entry = status, ctx, None


def candidates(low, instr):
    for p in PRIMS:
        if p.scope == "instr" and not instr:
            continue
        for a in p.anchors:
            if a in low:
                yield p
                break


def scan_code(rel, lines, kind):
    hits = []
    lows = [ln[:MAX_LINE].lower() for ln in lines]
    if not any(QUICK_RX.search(low) for low in lows):
        return hits
    flags = comment_flags(lines, kind)
    for i, raw in enumerate(lines):
        line, low = raw[:MAX_LINE], lows[i]
        comment = flags[i]
        seen = set()
        if QUICK_RX.search(low):
            for p in candidates(low, False):
                if p.rx.search(line):
                    seen.add(p.id)
                    hits.append(Hit(rel, i + 1, p, raw, "COMMENT" if comment else None, None))
        if comment or not CONT_RX.search(line.rstrip()):
            continue
        # a statement split over lines (`gh pr \` then `merge`, or an argv list across lines): look at a
        # 3-line window, and keep only matches that begin on this line and run into the next one
        window = line + " " + " ".join(x[:MAX_LINE].strip() for x in lines[i + 1:i + 3])
        wlow = window.lower()
        if not QUICK_RX.search(wlow):
            continue
        for p in candidates(wlow, False):
            if p.id in seen:
                continue
            for m in p.rx.finditer(window):
                if m.start() < len(line) and m.end() > len(line) + 1:
                    seen.add(p.id)
                    hits.append(Hit(rel, i + 1, p, raw, None, None))
                    break
    return hits


def prose_units(lines):
    """Group lines into paragraphs; list items, table rows, headings and fenced lines stand alone."""
    units, cur, in_fence = [], [], False
    bullet = re.compile(r"^(?:[-*+]\s|\d+[.)]\s|\||#{1,6}\s)")
    for i, line in enumerate(lines):
        s = line.strip()
        if s.startswith("```"):
            if cur:
                units.append(cur)
                cur = []
            in_fence = not in_fence
            continue
        if in_fence:
            if s:
                units.append([(i, line)])
            continue
        if not s:
            if cur:
                units.append(cur)
                cur = []
            continue
        if bullet.match(s) and cur:
            units.append(cur)
            cur = []
        cur.append((i, line))
    if cur:
        units.append(cur)
    return units


def unit_text(unit):
    text, starts = "", []
    for i, line in unit:
        starts.append((len(text), i))
        text += line.strip()[:MAX_LINE] + " "
    return text, starts


def scan_prose(rel, lines):
    hits = []
    for unit in prose_units(lines):
        text, starts = unit_text(unit)
        offs = [s[0] for s in starts]
        low = text.lower()
        if not QUICK_RX.search(low):
            continue
        for p in candidates(low, True):
            for m in p.rx.finditer(text):
                idx = starts[max(0, bisect.bisect_right(offs, m.start()) - 1)][1]
                hits.append(Hit(rel, idx + 1, p, lines[idx], None, (text, m.start())))
    uniq, seen = [], set()
    for h in hits:
        k = (h.line, h.prim.id)
        if k not in seen:
            seen.add(k)
            uniq.append(h)
    return uniq


def prose_logical_lines(lines):
    """(line_no, text, start_offset_ctx) for name scanning in instruction markdown."""
    out = []
    for unit in prose_units(lines):
        text, starts = unit_text(unit)
        out.append((starts[0][1] + 1, text))
    return out


def workflow_triggers(lines):
    """-> (trigger names, push branches or None, push has tags) parsed from the top-level `on:` block."""
    on_idx, inline = None, ""
    for idx, ln in enumerate(lines):
        m = re.match(r"""^["']?on["']?\s*:\s*(.*?)\s*(?:#.*)?$""", ln)
        if m:
            on_idx, inline = idx, m.group(1).strip()
            break
    if on_idx is None:
        return None
    if inline:
        if inline.startswith("["):
            names = [x.strip(" '\"") for x in inline.strip("[]").split(",") if x.strip(" '\"")]
        elif inline.startswith("{"):
            names = re.findall(r"([A-Za-z_]+)\s*:", inline)
        else:
            names = [inline.strip("'\"")]
        return set(names), None, False
    trig, cur, branches, tags, in_branches, b_indent = set(), None, None, False, False, 0
    for ln in lines[on_idx + 1:]:
        if not ln.strip() or ln.lstrip().startswith("#"):
            continue
        indent = len(ln) - len(ln.lstrip(" "))
        if indent == 0:
            break
        key = re.match(r"^\s*([A-Za-z_][A-Za-z0-9_-]*)\s*:\s*(.*?)\s*(?:#.*)?$", ln)
        if indent == 2 and key:
            cur = key.group(1)
            trig.add(cur)
            in_branches = False
            continue
        if cur != "push":
            continue
        if key and key.group(1) in ("tags", "tags-ignore"):
            tags = True
        if key and key.group(1) == "branches":
            branches, in_branches, b_indent = [], True, indent
            if key.group(2).startswith("["):
                branches = [x.strip(" '\"") for x in key.group(2).strip("[]").split(",") if x.strip(" '\"")]
                in_branches = False
            continue
        item = re.match(r"""^\s*-\s*["']?([^"'#\s]+)""", ln)
        if in_branches and item and indent > b_indent:
            branches.append(item.group(1))
        elif in_branches and indent <= b_indent:
            in_branches = False
    return trig, branches, tags


def collect_commands(node, out):
    if isinstance(node, dict):
        for k, v in node.items():
            if k == "command" and isinstance(v, str):
                out.append(v)
            else:
                collect_commands(v, out)
    elif isinstance(node, list):
        for v in node:
            collect_commands(v, out)


def hook_scripts():
    """Every bin/ sentinels/ hooks/ path named by a command string in hooks.json and settings.json."""
    names, parsed = set(), 0
    for rel in ("hooks/hooks.json", "settings.json"):
        try:
            with open(os.path.join(REPO, rel), "r", encoding="utf-8") as fh:
                data = json.load(fh)
        except (OSError, ValueError):
            continue
        cmds = []
        collect_commands(data, cmds)
        parsed += len(cmds)
        for c in cmds:
            for m in re.finditer(r"(?<![\w.-])((?:bin|sentinels|hooks)/[A-Za-z0-9_.-]+(?:/[A-Za-z0-9_.-]+)*)", c):
                if os.path.isfile(os.path.join(REPO, m.group(1))):
                    names.add(m.group(1))
    return names, parsed


def validate_entries(entries, scanned):
    """-> [(label, problem)]. The allowlist's own hygiene; also what --self-test feeds bad entries."""
    problems, seen = [], set()
    for e in entries:
        label = "%s %s %r" % (e["file"], "/".join(e["prims"]), e["fragment"][:40])
        f = e["file"]
        if any(ch in f for ch in "*?[]{}"):
            problems.append((label, "glob characters in the file: a pattern or directory exemption is a false green"))
        elif f.startswith("/") or ".." in f.split("/"):
            problems.append((label, "file must be an exact repo-relative path"))
        elif os.path.isdir(os.path.join(REPO, f)):
            problems.append((label, "file is a directory: a directory-wide exemption is a false green"))
        elif not os.path.isfile(os.path.join(REPO, f)):
            problems.append((label, "file does not exist"))
        elif f not in scanned:
            problems.append((label, "file is not part of the scanned shipped surface"))
        if not e["prims"] or any(p not in PRIM_BY_ID for p in e["prims"]):
            problems.append((label, "unknown or missing primitive id"))
        if len(e["fragment"].strip()) < 6:
            problems.append((label, "fragment shorter than 6 characters would match unrelated lines"))
        if e["cls"] not in CLASSES:
            problems.append((label, "unknown class %r" % e["cls"]))
        if len(e["reason"].strip()) < 40:
            problems.append((label, "reason too short: it must say who or what makes this safe"))
        if e["cls"] == "HUMAN-RUN" and not e["names"]:
            problems.append((label, "HUMAN-RUN needs names: how a human reaches it, so unattended reach can be checked"))
        if e["cls"] in ("GATED", "BRANCH-PUSH") and not e["guards"]:
            problems.append((label, "%s needs guards: the in-code gate must be verifiable" % e["cls"]))
        if e["cls"] == "CI-TRIGGER" and (not e["triggers"] or not re.match(r"^\.github/workflows/[^/]+\.ya?ml$", f)):
            problems.append((label, "CI-TRIGGER needs triggers and a .github/workflows/*.yml file"))
        if e["cls"] == "BRANCH-PUSH" and any(p in PRIM_BY_ID and PRIM_BY_ID[p].kind != "push" for p in e["prims"]):
            problems.append((label, "BRANCH-PUSH may only cover push-kind primitives"))
        if e["cls"] == "KNOWN-GAP" and not is_instruction(f):
            problems.append((label, "KNOWN-GAP may only cover instruction text (agents, skills, commands markdown): code that releases or deploys must be gated, not accepted"))
        if e["cls"] == "KNOWN-GAP" and any(p in PRIM_BY_ID and PRIM_BY_ID[p].kind in ("merge", "push") for p in e["prims"]):
            problems.append((label, "KNOWN-GAP may only cover release or deploy wording: the human merge boundary has no accepted gaps"))
        key = (f, e["prims"], e["fragment"])
        if key in seen:
            problems.append((label, "duplicate entry"))
        seen.add(key)
    return problems


def check_table():
    out = []
    for pid, sample in POSITIVE:
        if pid not in PRIM_BY_ID:
            out.append("positive corpus names unknown primitive %s" % pid)
        elif not PRIM_BY_ID[pid].rx.search(sample):
            out.append("%s did not fire on its own sample: %s" % (pid, sample))
    for pid in PRIM_BY_ID:
        if not any(p == pid for p, _ in POSITIVE):
            out.append("%s has no positive sample" % pid)
    for sample in NEGATIVE:
        for p in PRIMS:
            if p.rx.search(sample):
                out.append("%s fired on a look-alike that is not a merge/deploy: %s" % (p.id, sample))
    for pid, sample in NEGATED:
        m = PRIM_BY_ID[pid].rx.search(sample)
        if not m:
            out.append("negation sample did not match %s: %s" % (pid, sample))
        elif not negated(sample, m.start()):
            out.append("negation logic missed an explicit negator: %s" % sample)
    for pid, sample in NOT_NEGATED:
        m = PRIM_BY_ID[pid].rx.search(sample)
        if not m:
            out.append("sample did not match %s: %s" % (pid, sample))
        elif negated(sample, m.start()):
            out.append("negation logic laundered a live instruction: %s" % sample)
    return out


def analyze():
    A_ = {"files": [], "docs": [], "skipped": {}, "hits": [], "lines": {}, "kinds": {}}
    shipped = walk_shipped()
    for rel in shipped:
        text, why = read_text(rel)
        if text is None:
            A_["skipped"][rel] = why
            continue
        lines = re.split(r"\r?\n", text)
        A_["lines"][rel] = lines
        kind = file_kind(rel, lines[0] if lines else "")
        A_["kinds"][rel] = kind
        instr = is_instruction(rel)
        if kind == "prose" and not instr:
            A_["docs"].append(rel)
            continue
        A_["files"].append(rel)
        A_["hits"].extend(scan_prose(rel, lines) if kind == "prose" else scan_code(rel, lines, kind))
    entries = [dict(e, used=0) for e in ALLOW]
    for h in A_["hits"]:
        if h.status is None and h.ctx is not None and negated(h.ctx[0], h.ctx[1]):
            h.status = "NEGATION"
        if h.status is not None:
            continue
        for e in entries:
            if e["file"] == h.file and h.prim.id in e["prims"] and e["fragment"] in h.text:
                e["used"] += 1
                h.entry, h.status = e, e["cls"]
                break
        if h.status is None:
            h.status = "UNCLASSIFIED"
    A_["entries"] = entries
    return A_


def in_bot_surface(rel):
    return rel in BOT_FILES or any(rel.startswith(d + "/") for d in BOT_DIRS)


def remote_actions(A_):
    found = {}
    lines = A_["lines"].get("bin/heimdall-relay-client")
    if lines:
        for n, ln in enumerate(lines, 1):
            if ln.lstrip().startswith("#"):
                continue
            for m in re.finditer(r"""\baction\s*==\s*["']([a-z][a-z0-9_-]*)["']""", ln):
                found.setdefault(m.group(1), "bin/heimdall-relay-client:%d" % n)
    ctl = A_["lines"].get("bin/lib/companion_ui_controls.py")
    if ctl:
        body = "\n".join(ctl)
        order = re.search(r"^ACTION_ORDER\s*=\s*\(([^)]*)\)", body, re.M)
        if order:
            for name in re.findall(r"""["']([a-z][a-z0-9-]*)["']""", order.group(1)):
                found.setdefault(name, "bin/lib/companion_ui_controls.py ACTION_ORDER")
        for m in re.finditer(r"""^    ["']([a-z][a-z0-9-]*)["']\s*:\s*\{["']required["']""", body, re.M):
            found.setdefault(m.group(1), "bin/lib/companion_ui_controls.py _ACTIONS")
    login = A_["lines"].get("bin/lib/companion_cc_login.py")
    if login:
        m = re.search(r"^ACTIONS\s*=\s*\(([^)]*)\)", "\n".join(login), re.M)
        if m:
            for name in re.findall(r"""["']([a-z][a-z0-9_-]*)["']""", m.group(1)):
                found.setdefault(name, "bin/lib/companion_cc_login.py ACTIONS")
    return found


def evaluate(A_):
    """-> ordered list of (check id, title, [violation (key, human text)], note)."""
    scanned = set(A_["files"]) | set(A_["docs"])
    entries, hits = A_["entries"], A_["hits"]
    res = []

    res.append(("table", "primitive table fires on its positive corpus, stays silent on look-alikes, negation logic holds",
                [("TABLE|%s" % norm(m), m) for m in check_table()], "%d positive, %d negative, %d negation samples" % (
                    len(POSITIVE), len(NEGATIVE), len(NEGATED) + len(NOT_NEGATED))))

    probs = validate_entries(ALLOW, scanned)
    res.append(("allowlist", "allowlist is well-formed (exact files, no globs, known classes, reasons present)",
                [("ALLOWLIST|%s|%s" % (a, norm(b)), "%s: %s" % (a, b)) for a, b in probs],
                "%d entries" % len(ALLOW)))

    sv = []
    for rel, why in sorted(A_["skipped"].items()):
        if why != "binary" and why != "symlink":
            sv.append(("SURFACE|%s|%s" % (rel, why), "%s could not be scanned (%s)" % (rel, why)))
    if len(A_["files"]) < MIN_SCANNED:
        sv.append(("SURFACE|too-few-files", "only %d files scanned (floor %d): the walk is not seeing the tree"
                   % (len(A_["files"]), MIN_SCANNED)))
    for root in REQUIRED_ROOTS:
        if not any(f.startswith(root + "/") for f in A_["files"]):
            sv.append(("SURFACE|empty-root|%s" % root, "shipped root %s/ yielded no scanned file" % root))
    for rel in ANCHORS:
        if rel not in scanned:
            sv.append(("SURFACE|anchor|%s" % rel, "anchor %s is missing: a rename silently drops its coverage" % rel))
    for rel in BOT_FILES + UNATTENDED_EXTRA:
        if rel not in scanned:
            sv.append(("SURFACE|listed|%s" % rel, "%s is named by an invariant but not found: update the list" % rel))
    scripts, parsed = hook_scripts()
    if parsed < 10 or len(scripts) < 10:
        sv.append(("SURFACE|hooks", "hooks.json yielded %d commands / %d scripts: the unattended set is not being derived" % (
            parsed, len(scripts))))
    res.append(("surface", "shipped-surface walk is not vacuous (anchors present, every file readable)", sv,
                "%d files scanned, %d docs skipped, %d binary/symlink skipped, %d hook scripts derived" % (
                    len(A_["files"]), len(A_["docs"]),
                    sum(1 for w in A_["skipped"].values() if w in ("binary", "symlink")), len(scripts))))

    unclassified = [h for h in hits if h.status == "UNCLASSIFIED"]
    cnt = {}
    for h in hits:
        cnt[h.status] = cnt.get(h.status, 0) + 1
    note = "%d candidate hits: %s" % (len(hits), ", ".join("%d %s" % (v, k) for k, v in sorted(cnt.items())))
    res.append(("classified", "every merge/deploy primitive in shipped code is classified",
                [("UNCLASSIFIED|%s|%s|%s" % (h.prim.id, h.file, norm(h.text)),
                  "%s %s:%d: %s" % (h.prim.id, h.file, h.line, norm(h.text))) for h in unclassified], note))

    res.append(("stale", "no stale allowlist entry (each one still matches a live hit)",
                [("STALE|%s|%s|%s" % (e["file"], "/".join(e["prims"]), e["fragment"]),
                  "%s [%s] %r matches nothing" % (e["file"], "/".join(e["prims"]), e["fragment"]))
                 for e in entries if e["used"] == 0], ""))

    gv = []
    for e in entries:
        if e["used"] == 0 or e["file"] not in A_["lines"]:
            continue
        lines = A_["lines"][e["file"]]
        for g in e["guards"]:
            rx = re.compile(g)
            if not any(rx.search(x) for x in lines):
                gv.append(("GUARD|%s|missing %s" % (e["file"], norm(g)),
                           "%s: in-code guard not found: /%s/" % (e["file"], g)))
        if e["cls"] == "CI-TRIGGER":
            parsed_on = workflow_triggers(lines)
            if parsed_on is None:
                gv.append(("GUARD|%s|no on-block" % e["file"], "%s: no top-level on: block to verify" % e["file"]))
                continue
            names, branches, tags = parsed_on
            allowed = set(t.split(":")[0] for t in e["triggers"])
            for t in sorted(names - allowed):
                gv.append(("GUARD|%s|trigger %s" % (e["file"], t),
                           "%s: trigger %s is not human-only (allowed: %s)" % (e["file"], t, ", ".join(e["triggers"]))))
            if "push" in names:
                want = sorted(t.split(":", 1)[1] for t in e["triggers"] if t.startswith("push:"))
                if tags or sorted(branches or []) != want:
                    gv.append(("GUARD|%s|push branches" % e["file"],
                               "%s: push must be exactly branches %s with no tags (found %s, tags=%s)" % (
                                   e["file"], want, sorted(branches or []), tags)))
    seen_g, gv_u = set(), []
    for k, t in gv:
        if k not in seen_g:
            seen_g.add(k)
            gv_u.append((k, t))
    res.append(("guards", "in-code guards and CI triggers hold for every gated entry", gv_u, ""))

    bv = []
    for h in hits:
        if h.prim.kind == "merge" and in_bot_surface(h.file) and h.status not in NONEXEC + ("COMMENT", "NEGATION"):
            bv.append(("BOT|%s|%s|%s" % (h.prim.id, h.file, norm(h.text)),
                       "%s %s:%d: a PR-opening bot surface must carry no executable merge capability" % (
                           h.prim.id, h.file, h.line)))
    res.append(("bot", "PR-opening bot surfaces hold no merge capability", bv, ""))

    unattended = set(scripts) | set(UNATTENDED_EXTRA) | set(["hooks/hooks.json"])
    uv = []
    for h in hits:
        if h.entry and h.entry["cls"] in UNATTENDED_FORBIDDEN and h.file in unattended:
            uv.append(("UNATTENDED|%s|%s allowlist entry on %s" % (h.file, h.entry["cls"], h.prim.id),
                       "%s:%d: class %s may not cover a hit inside an unattended file (%s)" % (
                           h.file, h.line, h.entry["cls"], h.prim.id)))
    specs = []
    for e in entries:
        if e["cls"] in ("HUMAN-RUN", "GATED", "CI-TRIGGER") and e["used"]:
            for n in e["names"]:
                specs.append((os.path.basename(e["file"]), e["file"], re.compile(n)))
            if e["cls"] == "CI-TRIGGER":
                specs.append((os.path.basename(e["file"]), e["file"],
                              re.compile(r"\b" + re.escape(os.path.splitext(os.path.basename(e["file"]))[0]) + r"\b")))
    targets = sorted(set(f for f in A_["files"] if f in unattended or is_instruction(f)
                         or f.startswith(".github/workflows/")))
    for rel in targets:
        lines = A_["lines"][rel]
        kind = A_["kinds"][rel]
        if kind == "prose":
            units = [(n, t, True) for n, t in prose_logical_lines(lines)]
        else:
            flags = comment_flags(lines, kind)
            units = [(n, t, False) for n, t in enumerate(lines, 1) if not flags[n - 1]]
        for n, t, is_prose in units:
            for ident, owner, rx in specs:
                if owner == rel:
                    continue
                m = rx.search(t)
                if m and not (is_prose and negated(t, m.start())):
                    uv.append(("UNATTENDED|%s|reaches %s" % (rel, ident),
                               "%s:%d names %s (a human-run/gated script): %s" % (rel, n, ident, norm(t))))
    seen_u, uv_u = set(), []
    for k, t in uv:
        if k not in seen_u:
            seen_u.add(k)
            uv_u.append((k, t))
    res.append(("unattended", "no human-run or gated verb is reachable from an unattended surface", uv_u,
                "%d unattended/agent surfaces checked against %d script names" % (len(targets), len(specs))))

    rv = []
    acts = remote_actions(A_)
    if not acts:
        rv.append(("REMOTE|none-found", "no remote action could be extracted from the relay client or controls module"))
    for name, where in sorted(acts.items()):
        if REMOTE_DENY.search(name):
            rv.append(("REMOTE|%s|deny-word" % name, "%s (%s): a phone-reachable action may not name a merge/deploy verb" % (name, where)))
        elif name not in REVIEWED_REMOTE_ACTIONS:
            rv.append(("REMOTE|%s|unreviewed" % name, "%s (%s): not in the reviewed set; review it against the human merge boundary, then add it to REVIEWED_REMOTE_ACTIONS" % (name, where)))
    res.append(("remote", "relay/phone remote actions are the reviewed set and name no merge or deploy verb", rv,
                "%d actions: %s" % (len(acts), ", ".join(sorted(acts)))))
    return res


GREEN, RED, OFF = "\033[32m", "\033[31m", "\033[0m"


def main_report(A_, res, fail_only_keys=False):
    passed = failed = 0
    scanned_n = len(A_["files"])
    if MODE == "keys":
        print("#scanned=%d" % scanned_n)
        bad = False
        for _cid, _t, viol, _n in res:
            for k, _h in viol:
                print(k)
                bad = True
        return 1 if bad else 0
    print("no-auto-merge harness  repo=%s" % REPO)
    print("--------------------------------------------------------------------")
    for cid, title, viol, note in res:
        if viol:
            failed += 1
            print("  %sFAIL%s %s" % (RED, OFF, title))
            for _k, human in viol:
                print("    %s" % human)
        else:
            passed += 1
            print("  %sPASS%s %s%s" % (GREEN, OFF, title, ("  [" + note + "]") if note else ""))
    runs = sorted(set(e["file"] for e in A_["entries"] if e["cls"] == "HUMAN-RUN" and e["used"]))
    if runs:
        print("")
        print("  accepted, visible every run: human-run executables whose merge/deploy step has no in-code")
        print("  confirmation. A human typing the command is the trigger; their names appear on no unattended surface:")
        for r in runs:
            print("    %s" % r)
    gaps = sorted((e["file"], e["fragment"]) for e in A_["entries"] if e["cls"] == "KNOWN-GAP" and e["used"])
    if gaps:
        print("")
        print("  KNOWN GAPS, accepted and visible every run: instruction text that tells an agent to release or deploy")
        print("  with no human-confirmation step in the text (a merge verb can never be listed here). Each is an operator")
        print("  decision: reword it so the agent prepares the change and stops for the operator to run the command, or keep")
        print("  accepting it. (Name a human-run script only inside a 'never run' clause: the unattended check rejects any other mention.)")
        print("  A new one fails this gate:")
        for f, frag in gaps:
            print("    %s  %r" % (f, frag))
    print("")
    print("no-auto-merge.test.sh: %d passed, %d failed." % (passed, failed))
    return 1 if failed else 0


def main_survey(A_):
    print("# every candidate hit and its classification  (%d files scanned)" % len(A_["files"]))
    by = {}
    for h in A_["hits"]:
        by.setdefault(h.file, []).append(h)
    for rel in sorted(by):
        parts = {}
        for h in by[rel]:
            parts.setdefault((h.status, h.prim.id), []).append(h.line)
        row = "; ".join("%s %s@%s" % (st, pid, ",".join(str(x) for x in ls)) for (st, pid), ls in sorted(parts.items()))
        print("%-58s %s" % (rel, row))
    return 0


def main_hygiene():
    bad = [
        A("bin/*", "git-push", "git push origin", "HUMAN-RUN", "x" * 50, names=("a",)),
        A("bin", "git-push", "git push origin", "HUMAN-RUN", "x" * 50, names=("a",)),
        A("bin/does-not-exist", "git-push", "git push origin", "HUMAN-RUN", "x" * 50, names=("a",)),
        A("release/ship.sh", "git-push", "git", "HUMAN-RUN", "x" * 50, names=("a",)),
        A("release/ship.sh", "git-push", "git push origin", "NOT-A-CLASS", "x" * 50),
        A("release/ship.sh", "git-push", "git push origin", "HUMAN-RUN", "short"),
        A("release/ship.sh", "git-push", "git push origin", "HUMAN-RUN", "x" * 50),
        A("release/ship.sh", "git-push", "git push origin", "GATED", "x" * 50),
        A("release/ship.sh", "git-push", "git push origin", "CI-TRIGGER", "x" * 50, triggers=("workflow_dispatch",)),
        A("release/ship.sh", "no-such-primitive", "git push origin", "DOC", "x" * 50),
        A("release/ship.sh", "gh-release", "gh release", "BRANCH-PUSH", "x" * 50, guards=("g",)),
    ]
    cases = ("glob", "directory", "missing-file", "short-fragment", "unknown-class", "short-reason",
             "human-run-without-names", "gated-without-guards", "ci-trigger-outside-workflows",
             "unknown-primitive", "branch-push-non-push-kind")
    scanned = set(["release/ship.sh"])
    probs = {}
    for case, entry in zip(cases, bad[:4] + bad[4:6] + bad[6:8] + bad[8:]):
        probs[case] = validate_entries([entry], scanned)
    dup = validate_entries([A("release/ship.sh", "git-push", "git push origin", "DOC", "x" * 50)] * 2, scanned)
    ok = True
    for case in cases:
        rejected = bool(probs.get(case))
        ok = ok and rejected
        print("%s %s" % ("REJECTED" if rejected else "ACCEPTED-WRONGLY", case))
    rejected = any("duplicate" in b for _a, b in dup)
    ok = ok and rejected
    print("%s duplicate" % ("REJECTED" if rejected else "ACCEPTED-WRONGLY"))
    fine = validate_entries([A("release/ship.sh", "git-push", "git push origin", "DOC", "x" * 50)], scanned)
    print("%s well-formed-entry" % ("ACCEPTED" if not fine else "REJECTED-WRONGLY"))
    ok = ok and not fine
    scanned2 = set(["release/ship.sh", "agents/heimdall.md"])
    for case, entry in (("known-gap-on-code", A("release/ship.sh", "gh-release", "gh release", "KNOWN-GAP", "x" * 50)),
                        ("known-gap-on-merge-verb", A("agents/heimdall.md", "p-merge", "merge them", "KNOWN-GAP", "x" * 50)),
                        ("known-gap-on-push-verb", A("agents/heimdall.md", "p-push-main", "push to main", "KNOWN-GAP", "x" * 50))):
        rejected = any("KNOWN-GAP" in b for _a, b in validate_entries([entry], scanned2))
        ok = ok and rejected
        print("%s %s" % ("REJECTED" if rejected else "ACCEPTED-WRONGLY", case))
    gap_fine = validate_entries([A("agents/heimdall.md", "p-release", "fix \u2192 release", "KNOWN-GAP", "x" * 50)], scanned2)
    print("%s well-formed-known-gap" % ("ACCEPTED" if not gap_fine else "REJECTED-WRONGLY"))
    ok = ok and not gap_fine
    return 0 if ok else 1


def main():
    if MODE == "hygiene":
        return main_hygiene()
    if MODE == "copy-list":
        for d in ROOT_DIRS + ROOT_FILES:
            if os.path.exists(os.path.join(REPO, d)):
                print(d)
        return 0
    A_ = analyze()
    if MODE == "survey":
        return main_survey(A_)
    return main_report(A_, evaluate(A_))


sys.exit(main())
PYEOF

run_gate() { python3 -B "$GATE" "$REPO" "$1"; }

case "${1:-}" in
  "")          run_gate report;  exit $? ;;
  --keys)      run_gate keys;    exit $? ;;
  --survey)    run_gate survey;  exit $? ;;
esac
if [ "${1:-}" = "--self-test" ]; then
  PASSN=0; FAILN=0
  pass() { PASSN=$((PASSN+1)); printf '  \033[32mPASS\033[0m %s\n' "$1"; }
  fail() { FAILN=$((FAILN+1)); printf '  \033[31mFAIL\033[0m %s\n' "$1"; }
  echo "no-auto-merge --self-test: planting defects in a copy that lives under .claude/worktrees/"

  # 0. the allowlist validator rejects every malformed entry and accepts a well-formed one
  if HYG="$(run_gate hygiene 2>&1)" && ! printf '%s' "$HYG" | grep -qE 'ACCEPTED-WRONGLY|REJECTED-WRONGLY'; then
    pass "the allowlist validator rejects globs, directories, KNOWN-GAP on code and on merge/push verbs, and accepts a well-formed entry"
  else
    fail "the allowlist validator: $HYG"
  fi

  # 1. a faithful copy, deliberately under .claude/worktrees/ (the POSTMORTEM path)
  COPY="$WORK/.claude/worktrees/copy"
  mkdir -p "$COPY" || exit 2
  ITEMS="$(run_gate copy-list | tr '\n' ' ')"
  [ -n "$ITEMS" ] || { echo "no-auto-merge --self-test: copy-list is empty" >&2; exit 2; }
  # shellcheck disable=SC2086
  tar -C "$REPO" --exclude=node_modules --exclude=.git -cf - $ITEMS | tar -C "$COPY" -xf - \
    || { echo "no-auto-merge --self-test: could not copy the shipped roots" >&2; exit 2; }
  keys_of() { python3 -B "$GATE" "$1" keys 2>/dev/null | sort; }
  REAL_KEYS="$(keys_of "$REPO")"
  COPY_KEYS="$(keys_of "$COPY")"
  case "$COPY_KEYS" in
    "#scanned="*) pass "the gate produces keys on the copy ($(printf '%s\n' "$COPY_KEYS" | head -1))" ;;
    *)            fail "the gate produced no keys on the copy: it is not running, so every mutant below would be vacuous" ;;
  esac
  if [ "$REAL_KEYS" = "$COPY_KEYS" ]; then
    pass "the copy under .claude/worktrees/ is faithful: same scan size and same violations as the real tree"
  else
    fail "the copy differs from the real tree: a filter on the .claude/worktrees/ path substring would look exactly like this"
  fi

  BAK="$WORK/orig.bak"
  plant()   { cp -p "$COPY/$1" "$BAK" && printf '\n%s\n' "$2" >> "$COPY/$1"; }
  restore() { cp -p "$BAK" "$COPY/$1"; }
  new_keys() { comm -13 <(printf '%s\n' "$COPY_KEYS") <(keys_of "$COPY") | grep -v '^#scanned=' || true; }
  expect_red() {   # <label> <relfile> <text> <substring the new violation key must contain>
    local nk
    plant "$2" "$3" || { fail "$1: could not plant into $2"; return; }
    nk="$(new_keys)"; restore "$2"
    case "$nk" in
      *"$4"*) pass "RED on $1" ;;
      "")     fail "$1: the gate stayed GREEN with the defect planted in $2" ;;
      *)      fail "$1: RED for the wrong reason (wanted $4; got: $(printf '%s' "$nk" | head -2 | cut -c1-160))" ;;
    esac
  }
  expect_green() { # <label> <relfile> <text>
    local nk
    plant "$2" "$3" || { fail "$1: could not plant into $2"; return; }
    nk="$(new_keys)"; restore "$2"
    if [ -z "$nk" ]; then pass "GREEN on $1"; else fail "$1: the gate went RED on text that cannot merge or deploy: $(printf '%s' "$nk" | head -2 | cut -c1-160)"; fi
  }

  RELAY_SRC="$(cd "$COPY" && find relay -type d -name node_modules -prune -o -type f \( -name '*.js' -o -name '*.mjs' -o -name '*.ts' \) -print | sort | head -1)"
  [ -n "$RELAY_SRC" ] || fail "no relay source file to plant into"

  # 2. the defects the gate exists to catch
  expect_red "gh pr merge --auto planted in a shipped bin script" bin/heimdall-verdict 'gh pr merge --auto 1' 'UNCLASSIFIED|gh-pr-merge|bin/heimdall-verdict'
  expect_red "wrangler deploy planted in a hook script" hooks/statusline.sh 'wrangler deploy --env production' 'UNCLASSIFIED|wrangler-deploy|hooks/statusline.sh'
  expect_red "a GraphQL auto-merge mutation planted in relay/ (and the bot invariant fires)" "$RELAY_SRC" \
    'const q = "mutation { enablePullRequestAutoMerge(input: {pullRequestId: 1}) { clientMutationId } }";' "BOT|graphql-merge|$RELAY_SRC"
  expect_red "git push origin main planted in a sentinels script" sentinels/hmd-gate-event.sh 'git push origin main' 'UNCLASSIFIED|git-push|sentinels/hmd-gate-event.sh'
  expect_red "a merge instruction planted in an agent definition" agents/coder.md 'When the tests are green, merge the PR yourself.' 'UNCLASSIFIED|p-merge|agents/coder.md'
  expect_red "a release instruction planted in an agent definition" agents/lint-quality.md 'When lint is clean, publish a release.' 'UNCLASSIFIED|p-release|agents/lint-quality.md'
  expect_red "a merge instruction planted in the maintainer guide (a bot surface)" skills/heimdall/references/maintainer-guide.md \
    'Then merge the PR yourself.' 'UNCLASSIFIED|p-merge|skills/heimdall/references/maintainer-guide.md'
  # the nine lines once accepted as KNOWN-GAP are enforced now: the old autonomous release or deploy wording, planted back, is RED
  expect_red "the old autonomous release step planted back in the maintainer guide" skills/heimdall/references/maintainer-guide.md \
    '5. Create release tag + GitHub release' 'UNCLASSIFIED|p-release|skills/heimdall/references/maintainer-guide.md'
  expect_red "the old autonomous deploy step planted back in the incident responder" agents/incident-responder.md \
    '- Deploy fix, verify metrics return to baseline' 'UNCLASSIFIED|p-deploy|agents/incident-responder.md'
  expect_red "the old maintain-cycle release step planted back in the heimdall agent" agents/heimdall.md \
    'Each cycle runs: scan -> triage -> fix -> release -> communicate.' 'UNCLASSIFIED|p-release|agents/heimdall.md'

  # a stale allowlist entry: delete the line an entry covers
  cp -p "$COPY/agents/heimdall.md" "$BAK" && grep -v 'better than a bad auto-merge' "$BAK" > "$COPY/agents/heimdall.md"
  NK="$(new_keys)"; restore agents/heimdall.md
  case "$NK" in
    *"STALE|agents/heimdall.md|auto-merge"*) pass "RED on an allowlist entry whose line was deleted (STALE)" ;;
    *) fail "a stale allowlist entry went unnoticed (got: $(printf '%s' "$NK" | head -2 | cut -c1-160))" ;;
  esac

  # 3. the inverted mutants: text that cannot merge or deploy must stay GREEN
  expect_green "a merge verb inside a whole-line comment of a code file" bin/heimdall-verdict '# gh pr merge --auto 1   (documented as what NOT to run)'
  expect_green "an explicit negation in an instruction file" agents/coder.md 'You must never merge the PR yourself.'
  expect_green "git merge-base, which is not a merge" bin/heimdall-verdict 'git merge-base --is-ancestor main HEAD'

  echo "no-auto-merge --self-test: $PASSN passed, $FAILN failed."
  [ "$FAILN" -eq 0 ]
  exit $?
fi
