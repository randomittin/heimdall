# Plugin Auto-Install & Mid-Task Discovery

**Read this when a domain you detected has no installed skill covering it, or when a
file you just opened signals a stack no plugin is loaded for** (a `package.json` with
React, a `Dockerfile`, a Prisma schema, an OpenAPI spec, `.mcp.json`). The inline rule
in `agents/heimdall.md` §2 is the ordering constraint — install BEFORE spawning
agents; this file is the domain → plugin → command lookup, and the consent rule every
install goes through.

## Installing Required Plugins (consent first)

When a domain need isn't covered by any installed skill, install the plugin **through the consent gate** before starting work: `hmd skills install <plugin>`. The gate, not you, decides whether the user has already said yes (an earlier answer, an allow-listed plugin, or consent mode `auto`). Never install around it: no plugin-install call to the `claude` CLI of your own, no `git clone` of a skill, no `--yes` of your own.

**Plugin install map** (domain → plugin → install command):

<!-- Generated from skills.manifest.json: edit the manifest, then run `python3 -I bin/lib/skills_render_doc.py --write skills/heimdall/references/plugin-autoinstall.md`; never edit the rows between the markers. -->
<!-- BEGIN GENERATED skills.manifest part=auto-install flavour=ask -->
| Domain detected | Plugin needed | Install command |
|---|---|---|
| Frontend / UI / React / CSS | frontend-design | `hmd skills install frontend-design` |
| SEO / meta tags / sitemap | seo | `hmd skills install seo` |
| MCP / tool server | mcp-server-dev | `hmd skills install mcp-server-dev` |
| API design / OpenAPI | api-design | `hmd skills install api-design` |
| Database / SQL / schema | database-toolkit | `hmd skills install database-toolkit` |
| Docker / K8s / deploy | devops-toolkit | `hmd skills install devops-toolkit` |
| Security / auth / OWASP | security-scanner | `hmd skills install security-scanner` |
| Slack / notifications | slack | `hmd skills install slack` |
<!-- END GENERATED skills.manifest -->

**`hmd skills install <plugin>` answers with its exit code: read it, the consent decision is in it.**

| Exit | Meaning | You |
|---|---|---|
| 0 | installed, or already installed | announce it and continue |
| 1 | the install failed | say `install failed, continuing without <plugin>` and carry on |
| 2 | unknown plugin, or one hmd does not install | proceed without it |
| 3 | **consent required**: nothing was installed | **ask the user** (next paragraph) |
| 4 | the user declined for good (never ask again) | proceed without it |

**On exit 3**, ask the user one short question that names each plugin you need and why ("React found: install frontend-design for UI work? yes / no"), batching every plugin you need right now into that one question. Only after the user agrees, re-run `hmd skills install <plugin> --yes`. Never pass `--yes` on your own, never after exit 1 or 2, and never for a plugin the user declined. If the user says no, continue without the plugin and do not ask about it again this session.

**Process:**
1. Detect domains from the user's prompt (step 2a)
2. Check installed plugins: `claude plugins list`
3. For each needed plugin NOT installed, run `hmd skills install <plugin>` (the "Plugin needed" column above) and read its exit code; on 3, ask the user as above. Never swallow the status with `|| true`.
4. Announce the outcome: "Installed frontend-design plugin for UI work." (or `install failed, continuing without frontend-design` on exit 1)
5. Continue with the task — newly installed skills are immediately available

**If the plugin is not in the table above** (`hmd skills install` exits 2) **or not in the listed marketplace** (`claude-plugins-official`): proceed without it — the core agents handle most work. Do NOT add or search any other marketplace; only the sources named in `bin/lib/install-receipt.sh` (`hmd_marketplace_source`) are ever registered. Every install attempt, ok or failed, is recorded in the run receipt (`~/.heimdall/receipts/installs-<run id>.ndjson`) and listed by `summary-card --receipt`; the project's skills lock (`.planning/skills.lock`) keeps the consent that allowed it (`hmd skills why <plugin>` prints it).

**CRITICAL: Install BEFORE spawning agents.** If a coder agent needs frontend-design skills but they're not installed, the agent runs without them and produces worse output. Install first, spawn second — and a consent question still open counts as not installed, so ask it before the spawn.

## Mid-Task Plugin Discovery

Plugin needs aren't always obvious from the initial prompt. During execution, if you encounter ANY of these signals, **stop and get the relevant plugin installed through the same consent gate immediately**:

<!-- BEGIN GENERATED skills.manifest part=mid-task flavour=ask -->
| Signal during execution | Install |
|---|---|
| Reading a `package.json` with React/Vue/Angular | `frontend-design` |
| Touching `.css`/`.scss`/`tailwind.config` | `frontend-design` |
| Reading `Dockerfile`/`docker-compose`/`k8s` manifests | `devops-toolkit` |
| Seeing SQL files / Prisma / Sequelize / TypeORM | `database-toolkit` |
| Reading OpenAPI/Swagger specs | `api-design` |
| Finding auth/JWT/OAuth code | `security-scanner` |
| Touching SEO meta tags / robots.txt / sitemap | `seo` |
| Finding `.mcp.json` or MCP server code | `mcp-server-dev` |
| User mentions Slack / notifications mid-conversation | `slack` |
<!-- END GENERATED skills.manifest -->

**Process when discovered mid-task:**
1. Pause current work (don't spawn the next agent yet)
2. Install: `hmd skills install <plugin>` and read the exit code as above (3 = consent required: ask the user; a failure is reported as `install failed, continuing without <plugin>`)
3. Announce: "Discovered React codebase — installed frontend-design plugin."
4. Run `/reload-plugins` to load newly installed skills
5. Resume work — the new skills are now available to all agents

This is NOT a one-time check. Every time you read a new file or enter a new part of the codebase, re-evaluate whether a plugin would help, but ask the user about a given plugin once per session. A missed plugin costs lower quality output for the entire task; the consent question costs the user one line.
