---
name: author-runbook
description: Draft a coded Sherlock-style Runbook bean + PR from a resolver's stored plain-language proposal. Use when a resolver has submitted a runbook proposal for a ticket (via the project's "Propose runbook" flow) and a local Heimdall session, running inside the target project's own repo checkout, needs to turn that proposal into a real, tested, reviewed Runbook implementation and open a PR — without merging, activating, or deploying it.
argument-hint: <ticketId>
---

# /hmd:author-runbook — draft a coded Runbook from a resolver's proposal

You are a resolver's Claude Code / Heimdall session running **inside the target project's own
repo checkout** (whichever project implements Sherlock-style ticketing — this command is generic
and reads project specifics from config, never hardcodes a project's module names). A resolver hit
a ticket with no matching runbook, described the fix in plain language via that project's
"propose runbook" flow, and the proposal is now stored server-side. Your job: turn that
plain-language proposal into a real, tested, reviewed `Runbook` bean and open a PR. **You do NOT
merge, activate, or deploy it** — that is a separate human-gated step (a new runbook registers as
`draft` on boot; a human activates it later, per that project's registry service).

The ticket id is `$1` (the argument after `/hmd:author-runbook`). If it's missing, ask for it — do
not guess.

## Step 0 — Load project config (config-driven, no hardcoding)

Look for `.sherlock/author-runbook.json` at the repo root (or under `repoPath` if you haven't cd'd
yet). Schema (all keys optional — see defaults/fallbacks below):

```json
{
  "repoPath": ".",
  "apiBase": "http://localhost:8080",
  "proposalEndpoint": "/api/v1/sherlock/tickets/{ticketId}/runbook-proposal",
  "actorHeader": "<your-actor-header>",
  "spiPath": "path/to/module/src/main/java/.../runbook/Runbook.java",
  "exemplarPath": "path/to/module/src/main/java/.../runbook/impl/SomeExistingRunbook.java",
  "runbookImplDir": "path/to/module/src/main/java/.../runbook/impl/",
  "capabilityPortDir": "path/to/module/src/main/java/.../application/port/out/",
  "adapterModuleHint": "name-of-the-module-that-can-see-both-the-port-and-the-real-service",
  "buildCmd": "mvn spotless:apply && mvn test -pl <module> -Dtest=<pattern>",
  "prBase": "develop"
}
```

- `repoPath` — where to `cd` before doing anything else (default `.`, i.e. assume you're already
  in the repo).
- `apiBase` — base URL of the running app for fetching the proposal (default
  `http://localhost:8080`, local dev). **Never assume this is prod** — confirm with the resolver
  or the project's own env files before pointing it anywhere else.
- `proposalEndpoint` — path template for fetching a stored proposal; `{ticketId}` is substituted
  with `$1` (default `/api/v1/sherlock/tickets/{ticketId}/runbook-proposal`).
- `actorHeader` — the header name this project uses to identify the calling human/service
  (project-specific; configure it in `.sherlock/author-runbook.json`); value comes from the
  resolver's own session, never hardcode a user id.
- `spiPath` — path to the `Runbook` interface (or equivalent) that defines the contract every
  runbook bean implements.
- `exemplarPath` — path to one existing, working runbook bean to copy the shape of.
- `runbookImplDir` — directory new runbook beans go in.
- `capabilityPortDir` — directory capability-port interfaces (the abstraction a runbook calls
  instead of touching internal services directly) go in.
- `adapterModuleHint` — name of the module where a NEW port's adapter should live, if a new port
  is needed (see Step 3) — i.e. the module whose dependency graph can see both the port interface's
  module and the real internal service.
- `buildCmd` — exact command(s) to compile + test the change.
- `prBase` — the branch PRs target (default `develop`; many projects don't PR into `main` directly).

**If `.sherlock/author-runbook.json` is absent**, say so explicitly, then fall back to
auto-detection before proceeding:

1. `grep -rl "interface Runbook" --include=*.java .` (or the project's language-appropriate
   equivalent) to find `spiPath`.
2. Look for an `impl/` sibling directory next to that interface for `runbookImplDir`, and pick the
   first concrete bean found there as `exemplarPath`.
3. `grep -rl "port/out" --include=*.java .` near the SPI's module for `capabilityPortDir`.
4. Infer `buildCmd` from the build tool present (`pom.xml` → `mvn test`, `package.json` → the
   project's test script, etc.) — don't guess a submodule filter, ask if it's ambiguous.
5. **Show the resolver what you inferred and ask them to confirm or correct it** before writing
   any code. Auto-detection is a starting point, not a substitute for the config file — suggest
   they save it as `.sherlock/author-runbook.json` for next time.

## Step 1 — Fetch the proposal + ticket context

```bash
cd "<repoPath>"
API_BASE="<apiBase>"
curl -s "$API_BASE<proposalEndpoint with {ticketId} replaced by $1>" \
  -H "<actorHeader>: <your actor id>"
```

- Expect a response shape roughly like `{ ticketId, displayRef, merchantId/entityId, title,
  whenToUse, resolverSteps, team, proposedBy, status, createdAt, ticketDisposition,
  ticketAiSummary }` — adapt field names to what the project's endpoint actually returns; read one
  real response before assuming the shape.
- A 404 means either the ticket doesn't exist or has no stored proposal — stop and tell the
  resolver to submit a proposal first (via that project's own "propose runbook" flow). Do not fall
  back to the datastore for a 404 — there is nothing to read; correctly report it as not found.

**If the API is unreachable** (a connection-level failure — app not running, DNS, connection
refused, timeout — i.e. no HTTP response at all), fall back to reading the proposal straight from
the project's own datastore — the exact connection details (host/port/credentials) are
project-specific; look for how this repo's own scripts/docs connect to its DB (e.g. a
`.env.local`, a documented `psql`/equivalent one-liner) and reuse that pattern. Never invent
credentials, and **never print or log a password or any secret value** while doing this.

**Any other HTTP error status (401, 403, 500, etc.) — anything that is NOT a 404 — must STOP and
surface the error to the resolver.** Do NOT fall back to the datastore for these: the app answered
and refused or failed, which may reflect authz the direct datastore path would bypass. The
datastore fallback is reserved strictly for the connection-level "unreachable" case above, never
for an HTTP error response.

## Step 2 — Ground yourself in the REAL code before drafting anything

Read, in this order, before writing a line of the new bean:

1. **The SPI** (`spiPath`) — the interface every runbook implements. Expect something shaped like:
   ```java
   public interface Runbook {
     RunbookMetadata metadata();
     ProposedAction prepare(TicketContext ctx);
     ExecutionResult execute(TicketContext ctx);
     ValidationResult validate(TicketContext ctx, ExecutionResult result);
   }
   ```
   plus its supporting records/types (metadata shape, context shape, action/result/validation
   shapes) — read whatever this project actually defines, names may differ.
2. **The exemplar bean** (`exemplarPath`) — copy its shape: how `metadata()` is built, how
   `prepare()` reads required fields off the context (and rejects cleanly when they're missing),
   how `execute()` calls a capability-port then reports a result, how `validate()` re-reads state
   through the same port.
3. **How new beans get discovered/registered** — most registries auto-discover any bean
   implementing the SPI (e.g. Spring `@Component`) and register it in a non-active/`draft` status;
   confirm this project's actual mechanism rather than assuming — grep for the registry service
   named in the SPI's package or docs.
4. **Existing capability-ports** under `capabilityPortDir` and their adapters — a capability-port
   is the abstraction a runbook calls instead of reaching into an internal service directly (keeps
   the runbook module decoupled from modules it shouldn't depend on).
5. **Grep for the real internal service/method the resolver's steps imply.** The proposal's
   `resolverSteps` / `whenToUse` are plain language — map them to actual code by running real
   greps in this repo. If you can't find a matching internal service call, **STOP and ask the
   resolver for more detail rather than inventing one.**

## Step 3 — Decide: reuse a capability-port, or flag a new one

Most modular codebases have a dependency-direction rule that keeps a "core"/domain module from
depending on modules that own the concrete integrations it needs to call. Work out (or re-read
from this project's own docs) which module sits at the intersection — able to see both a
port interface's module and the internal service the action needs — that module is where new
adapters belong (`adapterModuleHint` in config, or infer it and confirm with the resolver).
**Never introduce a new inter-module dependency to route around this** — that's how dependency
cycles happen and the build breaks.

- **A matching port already exists** → inject it into your new bean via constructor injection,
  call it from `execute`/`validate`. No new files beyond the bean + its test.
- **No matching port exists** → **flag this clearly in the PR description** and, before writing
  the bean:
  1. Create the port interface under `capabilityPortDir` — an idempotent action method + a re-read
     ("is this already done?") method, mirroring an existing port's shape. Document WHY it's a
     port (the dependency-direction reason) in the interface's own doc comment.
  2. Create the adapter in the module named by `adapterModuleHint` (or the module you confirmed in
     Step 3's intersection analysis), implementing the new port and delegating to the real service
     found in Step 2.5.
  3. The new `Runbook` bean depends only on the new port interface — never on the adapter or the
     internal service directly.

## Step 4 — Draft the coded Runbook bean

New file under `runbookImplDir`, following this project's own bean-declaration conventions
(dependency-injection annotations, logging, etc. — copy the exemplar's style exactly), implementing
the SPI:

```java
public class <Name>Runbook implements Runbook {

  static final String RUNBOOK_ID = "RBK_<UPPER_SNAKE_NAME>";   // stable, NEVER renamed once live
  static final String TARGET_TEAM = "<from proposal.team>";
  private static final String WHEN_TO_USE = "<verbatim / lightly-edited proposal.whenToUse>";

  private final <X>Port <x>Port;   // the capability-port from Step 3

  @Override
  public RunbookMetadata metadata() {
    // runbookId, title (proposal.title), version=1, whenToUse, targetTeam,
    // requiresSecondApprover=<see rule below>
  }

  @Override
  public ProposedAction prepare(TicketContext ctx) {
    // Read required fields off ctx. NO side effects here — this is the human-review prefill.
  }

  @Override
  public ExecutionResult execute(TicketContext ctx) {
    // Call the REAL internal service via the capability-port, IDEMPOTENTLY (upsert / re-assert
    // terminal state — a retry must be a safe no-op).
  }

  @Override
  public ValidationResult validate(TicketContext ctx, ExecutionResult result) {
    // Re-read live state via the port and confirm the end state actually holds.
  }
}
```

`requiresSecondApprover` rule (generic, non-negotiable): `true` for anything touching money,
cards, payouts, whitelisting, or any other approval-bypass action; `false` only for genuinely
low-risk, reversible, self-serve actions. When unsure, default `true` and say so in the PR.

## Step 5 — Write the unit test

New test file next to the bean, following this project's own test conventions. Mock the
capability-port. Assert:

- `metadata()` — id/team/`requiresSecondApprover` match what you set.
- `prepare()` — returns the expected proposed action and triggers **zero** port interactions
  (prepare must have no side effects).
- `execute()` — calls the port with the right args, returns a success result; call it **twice**
  and assert idempotency (no exception, no duplicate side effect).
- `validate()` — re-reads via the port and returns valid/invalid correctly for both cases.

Use an existing runbook's test (next to the exemplar bean, if present) as your template.

## Step 6 — Build

Run exactly `buildCmd` from config (or, if absent, the build/test command you inferred and
confirmed in Step 0). It must be clean before you move on. If a new port/adapter was added, also
build/test whatever module now hosts the adapter — write a small adapter test too (mock the real
service, assert the port delegates correctly).

## Step 7 — Open a PR

```bash
git checkout -b feat/rbk-<name>
git add <your new/changed files>
git commit -m "feat(sherlock): add RBK_<UPPER_NAME> runbook (from ticket $1)"
git push -u origin feat/rbk-<name>
```

Target `prBase` from config (default `develop`) — confirm against this repo's actual convention
(`git remote -v`, recent PRs) rather than assuming, if config is absent.

```bash
gh pr create --base "<prBase>" --title "feat(sherlock): RBK_<UPPER_NAME> runbook" --body "$(cat <<'EOF'
## Summary
- Drafts RBK_<UPPER_NAME>: <one-line what it does>, from ticket <ticketId/displayRef>
- Capability-port: <reused <X>Port | added new <X>Port + <X>Adapter — FLAGGED, see below>
- requiresSecondApprover=<true|false>: <why>

## Seed ticket
- ticketId=<id> (+ any other identifying fields the proposal returned)
- Proposal: "<title>" — <whenToUse>

## Status
Registers as `draft` on boot — NOT active. A human must review + activate separately. This PR
does not merge/deploy/activate anything beyond adding the bean + test.
EOF
)"
```

**STOP here.** Do not merge, do not activate the runbook, do not deploy. That is a distinct,
human-gated step after review.

## Security reminders (non-negotiable, generic)

- Never write a plaintext secret, credential, or raw PII into code, logs, or the PR body — mask
  per this project's own guardrails doc if one exists.
- Any money-moving, approval, or whitelist action: `requiresSecondApprover = true`, and
  `execute()` MUST be idempotent — a retry must never double-act.
- Follow this project's existing conventions (naming, wire-format casing, amount units, etc.) —
  read them from the codebase, don't assume superback's or any other project's specifics apply.
- Never drop or rename a DB column/table; migrations are additive-only, if this project has a
  migration tool.
- Keep the module/dependency direction intact — a capability-port's consuming module must never
  gain a new dependency edge just to route around Step 3's intersection module.

## Example project config

This command reads everything project-specific from `.sherlock/author-runbook.json` — it never
hardcodes a project's module names, ports, or build commands in its own body. A Java/Maven
monorepo's config typically points `spiPath`/`exemplarPath`/`runbookImplDir` at the relevant
`.../runbook/` package, `capabilityPortDir` at the module's `application/port/out/` directory, and
`buildCmd` at a `mvn test -pl <module>` invocation — see the schema in Step 0 for the full set of
keys.
