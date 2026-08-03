# Agent Spawning Templates

Templates for spawning each agent type with appropriate context.

## Architect Agent

```
Analyze the codebase and decompose the following task into sub-projects:

Task: [TASK DESCRIPTION]

Requirements:
1. Map existing codebase structure
2. Identify files that need creation or modification
3. Create dependency graph between sub-projects
4. Recommend which sub-projects can run in parallel
5. Flag any risks or ambiguities

Output a structured plan with sub-projects, dependencies, and agent assignments.
```

## Coder Agent

```
Implement [SUB-PROJECT NAME] for the [PROJECT] project.

Scope:
- [Specific deliverables]
- [Files to create/modify]

Context:
- [Relevant existing files]
- [Patterns to follow]
- [Skills to apply]

Constraints:
- Only modify files in [SCOPE]
- Do not touch [OUT-OF-SCOPE areas]
- Write tests alongside implementation

After completion, run:
  heimdall-state set '.plan.sub_projects[INDEX].status' '"complete"'
```

## Test Runner Agent

```
Run the test suite and report results for the [PROJECT] project.

Focus areas:
- [Specific modules to test]
- [New features that need coverage]

Protocol:
1. Discover test framework from package.json/config
2. Run full test suite
3. Report pass/fail/skip counts
4. Flag any untested code paths in recently changed files
5. If all pass: run `heimdall-state mark-clean`
6. If failures: report details with file paths and error messages
```

## Lint Quality Agent

```
Run lint and formatting checks on the [PROJECT] project.

Protocol:
1. Run the project's configured linter (check package.json scripts)
2. Run formatting check
3. Report all violations with file paths and line numbers
4. If clean: run `heimdall-state set '.quality_gates.lint_clean' 'true'`
5. If violations: list them for the coder agent to fix
```

## Docs Writer Agent

```
Update documentation for the [PROJECT] project after recent changes.

Changes made:
- [Summary of recent changes]

Tasks:
1. Update CLAUDE.md with current project state
2. Update README.md if API or setup changed
3. Add/update inline documentation where genuinely needed
4. Update CHANGELOG.md with new entries
```

## Reviewer Agent

```
Review all changes before push for the [PROJECT] project.

Review scope:
- Run `git diff` to see all staged/unstaged changes
- Check each changed file against the review checklist
- Verify test coverage for new code
- Check for security vulnerabilities
- Ensure code follows existing patterns

Output:
- Verdict: APPROVE / REQUEST CHANGES / BLOCK
- List of issues with severity (CRITICAL/WARNING/SUGGESTION)
- File paths and line numbers for each issue
```

## Design Agent

```
Handle the UI/UX design for [SUB-PROJECT NAME] in the [PROJECT] project.

Scope:
- [Specific design deliverables — layouts, components, design tokens]
- [Pages/views to design]

Context:
- [Existing design system or styles]
- [Brand guidelines if any]
- [Target audience and platform]

Design-for-ai skills available:
- Use `design-for-ai:design` for establishing foundations
- Use `design-for-ai:color` for color system
- Use `design-for-ai:fonts` for typography
- Use `design-for-ai:flow` for interactions and responsive behavior
- Use `design-for-ai:exam` for design audit
- Use `design-for-ai:hone` for final quality pass

Constraints:
- Follow existing design patterns in the project
- Ensure WCAG AA accessibility compliance
- Mobile-first responsive approach
- Do not change business logic or API code

After completion, run:
  heimdall-state set '.plan.sub_projects[INDEX].status' '"complete"'
```

## Parallel Role Team Template

For large tasks requiring 3+ parallel workers.

**Roles are carried in `description:`, never `name:`.** A spawn carrying `name:` is DENIED (exit 2)
by the `PreToolUse` `Agent` hook. `name:` assigns mailbox residency at spawn time: that agent never
self-terminates, never returns a result, and the parent cannot terminate it — no signalable PID, no
socket, no terminate marker. Measured: 0/43 named spawns completed vs 59/66 unnamed. It is not
recoverable by prompt — a controlled pair testing a "terminate, do not await messages" clause
produced one `idle_notification` each either way, both recorded `"taskKind": "in_process_teammate"`.
(conventions R13; proof: `bash test/agent-name-gate.test.sh`)

Spawn every role in a wave in ONE message, each `run_in_background: true`:

```
Agent(subagent_type: "hmd:architect",    description: "decompose codebase into sub-projects")
Agent(subagent_type: "hmd:design",       description: "UI/UX, component design, design tokens")
Agent(subagent_type: "hmd:coder",        description: "auth module — src/auth/**")
Agent(subagent_type: "hmd:coder",        description: "API endpoints — src/api/**")
Agent(subagent_type: "hmd:coder",        description: "UI components — src/components/**")
Agent(subagent_type: "hmd:test-runner",  description: "test suite as code lands")
Agent(subagent_type: "hmd:lint-quality", description: "lint after each coder completes")
Agent(subagent_type: "hmd:reviewer",     description: "review all changes before merge")
Agent(subagent_type: "hmd:docs-writer",  description: "sync docs with implementation")
```

The identity that used to live in a teammate name (`coder-auth`) goes in `description:`
("auth module — src/auth/**"). Same information, and it dispatches.

File scopes MUST be disjoint within a wave — two agents writing one file collide.

Coordination is wave ordering, not one flat batch:

- Wave 0: architect alone → decomposition plan. Plan is approved before wave 1 spawns.
- Wave 1: design + auth coder + API coder — parallel, disjoint scopes
- Wave 2: frontend coder — depends on API + design
- Wave 3: test-runner + lint-quality
- Wave 4: reviewer — after all coders and tests
- Wave 5: docs-writer — last, with full context

Within a wave: ALL agents in ONE message. Between waves: let the wave return first.

### When a named agent is genuinely right

One case: a long-lived conversational agent you will actually drive with `SendMessage` across the
session. `HEIMDALL_ALLOW_NAMED_AGENT=1` is the deliberate opt-in.

Accept what it costs: that agent is mailbox-resident for the WHOLE session. It never self-terminates,
never returns a result to the parent, and **cannot be closed** — the parent has no way to reach it,
and `SendMessage` is not enabled in the orchestrator context, so in an orchestrator you cannot even
use the thing you named it for. A role that does a unit of work and reports back is NOT this case.
Spawn it unnamed.
