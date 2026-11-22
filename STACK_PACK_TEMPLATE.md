# Stack Pack Template

Copy this file to `skills/stacks/<stack-id>/PACK.md` and replace every section
below with real, stack-specific content. A pack is **knowledge layered onto a
role agent** (coder/architect/reviewer/...), not a new agent. Keep commands
exact and acceptance criteria runnable.

Before you start: make sure `bin/stack-detect` already emits your `<stack-id>`.
If it does not, the pack will never load — extend the detector first.

Rules for filling this out:

- Every command must be **copy-paste runnable** — the exact invocation, with
  flags, that works in a clean checkout of that stack.
- Every acceptance criterion must be a **command** (test, grep, curl, build) a
  reviewer can run and read the exit code of. No vague prose like "works".
- **The gate is `lint` + the stack's use-case suite**: real user journeys, one
  scenario each, entered through the public door (HTTP route, screen, command),
  real code end to end, fakes only at external boundaries (payments, third-party
  APIs, the LLM, the clock). See `skills/heimdall/references/use-case-tests.md`.
  A pack MUST give both commands, a per-journey selector, and a `use-cases`
  criterion in Section 4. A pack that gates on "the full suite is green", a
  coverage threshold, or one test file per controller/router/route is wrong:
  those are the generic checks the use-case rule replaces.
- A run that collects **zero** tests must FAIL. Say, for this stack, how the runner
  exits non-zero when nothing matches, and never document a flag or wrapper that
  turns an empty run into a pass (`--passWithNoTests`, `--pass-with-no-tests`,
  `|| true`).
- Unit tests of touched code are allowed **during work** (one file or one test,
  run once) to pin a specific bug. They are never a gate criterion.
- Keep it generic to the stack. Repo-specific quirks belong in a project's
  `.planning/skills/`, which layers on top of this base pack.

---

## Section 1 — Stack ID & Detection Signals

- **Stack id:** `<stack-id>` (must match what `bin/stack-detect` emits)
- **Detected from:** which manifest file(s) and which contents trigger this id.
- **Disambiguation:** if this stack shares a manifest with others (e.g. all JS
  stacks share `package.json`), state the precedence rule that selects it.

## Section 2 — Directory Layout Conventions

Describe where things live in an idiomatic project of this stack: source root,
the use-case suite (one directory, package or marker that the `use-cases` check
runs and nothing else) and where its fakes live, config, build output,
entrypoints. Use a tree. Note any conventions a role agent must honor when adding
files (e.g. "controllers go under `.../web/`", "an external system gets one
adapter and one fake").

## Section 3 — Lint / Format / Test / Build Commands

Exact commands. Fill in real invocations:

- **Format:** `<exact command>`
- **Lint:** `<exact command>` (state how warnings are surfaced / treated). This is
  the `lint` check: chain the linter, the formatter check and the type check in
  one command.
- **Use-cases (the gate):** `<exact command that runs the use-case suite and nothing else>`
  — one journey: `<exact selector>`
  — an empty run: `<how this runner exits non-zero when it collects zero tests>`
- **Touched code (during work, not a gate):** `<exact command for one file or one test>`
- **Build:** `<exact command>` (never one that also runs the whole test suite)
- **Type check (if applicable):** `<exact command>`

State the gate as the declaration the repo commits, `.heimdall/repo-checks.json`
(each `cmd` runs with `bash -c` from the repo root):

```json
{"schema":1,"checks":[
  {"name":"lint","cmd":"<lint command>"},
  {"name":"use-cases","cmd":"<use-cases command>"}
]}
```

## Section 4 — Acceptance-Criteria Templates

Reusable, runnable criteria a reviewer can drop into a plan for this stack. Each
must be a command with a checkable outcome. The first group is REQUIRED: a pack
without a `use-cases` criterion is incomplete.

### Gate: `lint` + `use-cases` (required)

- `<lint command>` exits 0 — the `lint` check.
- `<use-cases command>` exits 0 and ran at least one scenario — the `use-cases`
  check; say how an empty run fails on this stack.
- `<use-cases command with the per-journey selector>` exits 0 for each journey the
  plan names — the scenario exists and passes (a missing one selects nothing and
  fails).
- `<grep>` returns no lines — scenarios enter through the public door, never an
  internal module, and none is skipped or focused.
- `<grep>` returns no lines — fakes sit only at external boundaries; the repo's own
  routers, services and components are never patched or mocked.

### Other criteria (optional, stack-specific)

Code-shape checks, build health, runtime reachability. Never a full-suite or
coverage criterion.

- `<runnable check>` — what it proves
- `<runnable check>` — what it proves

## Section 5 — Common Failure Patterns + Fixes

For each recurring failure: the symptom, the root cause, and the concrete fix.

- **Symptom:** … **Cause:** … **Fix:** …
- **Symptom:** … **Cause:** … **Fix:** …

## Self-check before you commit a pack

Run from the repo root, replacing `<stack-id>`:

- `grep -c '"name":"use-cases"' skills/stacks/<stack-id>/PACK.md` prints `1` or
  more — the pack declares its `use-cases` check.
- `grep -n '^### Gate' skills/stacks/<stack-id>/PACK.md` prints a line — the gate
  criteria exist.

---

## Filled Example (shows the expected shape — `spring-boot`)

> The block below is a worked example so a contributor can see the level of
> concreteness expected. Delete it when authoring a real pack.

### Section 1 — Stack ID & Detection Signals

- **Stack id:** `spring-boot`
- **Detected from:** `build.gradle`, `build.gradle.kts`, or `pom.xml` whose
  contents reference `spring-boot` (e.g. `org.springframework.boot` plugin or
  `spring-boot-starter-*` dependencies).
- **Disambiguation:** a JVM build file *without* any `spring-boot` reference
  detects as `jvm`, not `spring-boot`.

### Section 2 — Directory Layout Conventions

```
src/
  main/
    java/com/example/app/
      Application.java          # @SpringBootApplication entrypoint
      web/        controllers   # @RestController classes
      service/    business logic (@Service)
      repository/ data access   (@Repository / Spring Data interfaces)
      domain/     entities + DTOs
    resources/
      application.yml           # config + profiles
  test/
    java/com/example/app/
      usecases/                 # THE GATE: one <Journey>JourneyTest per user journey
        PlaceAnOrderJourneyTest.java   # @SpringBootTest(RANDOM_PORT): real HTTP, real beans, real (H2) database
        fakes/                  # one hand-written fake per external system, records what it was sent
build.gradle(.kts) | pom.xml    # build definition
```

New REST endpoints go in `web/` as `@RestController` classes; persistence goes
through `repository/` interfaces, never raw JDBC in controllers. A new
user-facing capability gets a journey class in `usecases/`; an external system
gets one adapter interface in `main/` and one fake in `usecases/fakes/`.

### Section 3 — Lint / Format / Test / Build Commands

Gradle (swap `./gradlew` for `./mvnw` + Maven goals on Maven projects):

- **Format:** `./gradlew spotlessApply`
- **Lint:** `./gradlew check -x test` (Checkstyle/Spotless; build fails on any violation)
- **Use-cases (the gate):** `./gradlew test --tests '*JourneyTest'`
  — one journey: `./gradlew test --tests '*PlaceAnOrderJourneyTest'`
  — an empty run: a `--tests` filter that matches nothing fails the build
  ("No tests found for given includes"); Maven: `./mvnw test -Dtest='*JourneyTest'`
  fails the same way.
- **Touched code (during work, not a gate):** `./gradlew test --tests 'com.example.app.web.OrderControllerTest'`
- **Build:** `./gradlew clean build -x test`
- **Run locally:** `./gradlew bootRun`

```json
{"schema":1,"checks":[
  {"name":"lint","cmd":"./gradlew check -x test"},
  {"name":"use-cases","cmd":"./gradlew test --tests '*JourneyTest'"}
]}
```

### Section 4 — Acceptance-Criteria Templates

#### Gate: `lint` + `use-cases`

- `./gradlew check -x test` exits 0 — the `lint` check.
- `./gradlew test --tests '*JourneyTest'` exits 0 — the `use-cases` check: every
  journey passes; an empty suite fails the build.
- `./gradlew test --tests '*<Journey>JourneyTest'` exits 0 for each journey the plan
  names — the scenario exists and passes.
- `grep -rL '@SpringBootTest' src/test/java --include='*JourneyTest.java'` prints
  nothing — every journey runs the whole application, not a slice with mocked beans.
- `grep -rn '@MockBean\|@SpyBean\|Mockito\|@Disabled' src/test/java/com/example/app/usecases`
  returns no lines — fakes only at external boundaries, no journey switched off.

#### Other criteria

- `./gradlew clean build -x test` succeeds (exit 0) — compiles and packages.
- `curl -s -o /dev/null -w '%{http_code}' localhost:8080/actuator/health`
  returns `200` after `./gradlew bootRun`.

### Section 5 — Common Failure Patterns + Fixes

- **Symptom:** `No qualifying bean of type '…'` at startup.
  **Cause:** a `@Service`/`@Repository` lives outside the
  `@SpringBootApplication` package scan root.
  **Fix:** move it under the base package, or add
  `@ComponentScan(basePackages = "…")`.
- **Symptom:** `@WebMvcTest` test fails to autowire a service.
  **Cause:** slice tests do not load `@Service` beans.
  **Fix:** add `@MockBean <Service>` to that slice test (a bug-pinning test, not a
  journey), or switch to `@SpringBootTest`.
- **Symptom:** `Port 8080 already in use` on `bootRun`.
  **Cause:** a prior run is still bound.
  **Fix:** `lsof -ti tcp:8080 | xargs kill`, or set
  `server.port=0` for a random test port.

### Code Quality Bar (applies to every pack)

All generated code must be production-ready: real implementations only. Do not
emit incomplete-and-marked-for-later code, do not leave method bodies empty to
be filled in later, do not return fake data in place of real logic. If a piece
cannot be implemented fully, state that explicitly instead of emitting
incomplete code. The repo's PreToolUse content scan enforces this automatically.
