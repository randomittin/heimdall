# Stack Packs — Stack Knowledge for Role Agents

**Read this when `.planning/detected-stack.json` exists and you are about to spawn a
role agent** (to resolve which pack paths to hand it), **or when authoring a new
pack**. The inline rule in `agents/heimdall.md` §5 is the one-line behavior: load the
packs and pass their paths in each role agent's spawn instructions. This file is the
layering model and the authoring entry point.

Stack specialization ships as **knowledge packs loaded onto existing role
agents**, never as new role x stack agents. Agents stay generic roles
(`coder`, `architect`, `reviewer`, ...); stacks are knowledge (conventions,
directory layout, exact lint/test/build commands, runnable acceptance-criteria
templates, common failure patterns). There is no `nextjs-coder` agent — there is
a `coder` that reads the `nextjs` pack.

**Detection at session start:** a `SessionStart` hook runs `bin/stack-pack
detect` and writes the result to `.planning/detected-stack.json` (e.g.
`{"stacks":["nextjs"],"signals":["package.json:next"]}`). Monorepos can yield
multiple stacks. Read this file to know the project's stack(s) without
re-detecting.

**Loading packs into agents:** when spawning a role agent, resolve the pack
paths with `bin/stack-pack load` and tell the agent to read them at task start:

```bash
bin/stack-pack load          # prints pack paths, base first then repo refinements
```

This prints, in layering order:
1. **Base pack** — `skills/stacks/<id>/PACK.md` (resolved via
   `CLAUDE_PLUGIN_ROOT`): the cold-start scaffold of stack-wide conventions.
2. **Repo refinement** — `.planning/skills/*.md` in the target project: learned,
   repo-specific notes that layer on top of and override the base pack.

Include the relevant pack path(s) in each agent's spawn instructions ("read
`<pack path>` for this stack's conventions, commands, and acceptance criteria
before writing code"). Use the pack's acceptance-criteria templates when
defining a task's runnable checks. See `skills/stacks/README.md` for the full
system and `STACK_PACK_TEMPLATE.md` for authoring a new pack.
