---
name: stacks
description: Load stack-specific knowledge (conventions, exact lint/test/build commands, common failure patterns) onto the current role agent for the project's detected tech stack(s) — Next.js, React Native, Spring Boot, FastAPI, Django, Rust, etc. Use at the start of any task in an unfamiliar or newly-onboarded repo, or whenever acceptance criteria need a stack's exact command instead of a guess.
---

# stacks

Knowledge packs loaded onto existing role agents — never new role×stack agents. There is
exactly one `coder`, one `reviewer`, one `architect`; a pack gives that same agent
stack-specific judgment without changing its identity. Full design: `skills/stacks/README.md`.

## Run it

```bash
bin/stack-detect [path]        # scan manifests, print detected stack id(s) as JSON
bin/stack-pack load [path]     # detect + print the pack file path(s) to read, in order
```

`bin/stack-pack load` prints, in layering order:
1. **Base pack** — `skills/stacks/<id>/PACK.md` (cold-start scaffold, shipped with hmd).
2. **Repo refinement** — any `.planning/skills/*.md` in the target project (learned,
   repo-specific notes that override the base pack where they disagree).

Read every path it prints, then apply those conventions for the rest of the task — exact
lint/format/test/build commands, directory layout, runnable acceptance-criteria templates,
common failure patterns + fixes. Your identity as the current role does not change; only
your knowledge of this stack does.

## Detection already runs for you

A `SessionStart` hook runs `bin/stack-detect` and writes the result to
`.planning/detected-stack.json` when the project is a Heimdall project. If that file
exists, read it directly instead of re-running detection, then call `bin/stack-pack load`
(or resolve the paths yourself from the ids it lists) to get the pack(s) to read.

## Supported stack ids

`nextjs` · `react-native` · `react` · `vue` · `svelte` · `node` · `spring-boot` · `jvm` ·
`fastapi` · `django` · `flask` · `python` · `go` · `rust` — detection rules for each:
`skills/stacks/README.md`.

## Adding a new pack

Copy `STACK_PACK_TEMPLATE.md` (repo root) to `skills/stacks/<stack-id>/PACK.md`, fill every
section, and confirm `bin/stack-detect` already emits that `<stack-id>` — a pack whose id
`stack-detect` never emits is never loaded.

## Verification

- [ ] `bin/stack-detect .` on a repo whose `package.json` depends on `next` prints
      `{"stacks":["nextjs"], ...}` (a `signals` array included).
- [ ] `bin/stack-pack load .` on that same repo prints a path ending in
      `skills/stacks/nextjs/PACK.md`.
- [ ] A repo that also has a `.planning/skills/*.md` file gets that path printed AFTER
      the base pack path — repo refinement layers on top, never instead of.
- [ ] A repo matching none of the known stacks: `bin/stack-detect .` prints
      `{"stacks":[],"signals":[]}` and `bin/stack-pack load .` prints no pack path.
