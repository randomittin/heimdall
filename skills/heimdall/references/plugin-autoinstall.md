# Plugin Auto-Install & Mid-Task Discovery

**Read this when a domain you detected has no installed skill covering it, or when a
file you just opened signals a stack no plugin is loaded for** (a `package.json` with
React, a `Dockerfile`, a Prisma schema, an OpenAPI spec, `.mcp.json`). The inline rule
in `agents/heimdall.md` §2 is the ordering constraint — install BEFORE spawning
agents; this file is the domain → plugin → command lookup.

## Auto-Install Required Plugins

When a domain need isn't covered by any installed skill, **install it automatically** before starting work. Don't ask — just install and announce.

**Plugin auto-install map** (domain → plugin → install command):

| Domain detected | Plugin needed | Install command |
|---|---|---|
| Frontend / UI / React / CSS | frontend-design | `claude plugins install frontend-design@claude-plugins-official` |
| SEO / meta tags / sitemap | seo | `claude plugins install seo@claude-plugins-official` |
| MCP / tool server | mcp-server-dev | `claude plugins install mcp-server-dev@claude-plugins-official` |
| API design / OpenAPI | api-design | `claude plugins install api-design@claude-plugins-official` |
| Database / SQL / schema | database-toolkit | `claude plugins install database-toolkit@claude-plugins-official` |
| Docker / K8s / deploy | devops-toolkit | `claude plugins install devops-toolkit@claude-plugins-official` |
| Security / auth / OWASP | security-scanner | `claude plugins install security-scanner@claude-plugins-official` |
| Slack / notifications | slack | `claude plugins install slack@claude-plugins-official` |

**Process:**
1. Detect domains from the user's prompt (step 2a)
2. Check installed plugins: `claude plugins list`
3. For each needed plugin NOT installed, install it from the listed marketplace by its full `plugin@marketplace` name, and read the result:
   ```bash
   claude plugins install <plugin-name>@claude-plugins-official
   ```
   If it fails, say `install failed, continuing without <plugin-name>` and carry on. Never swallow the error with `|| true`; never pass `--yes`.
4. Announce: "Installed frontend-design plugin for UI work."
5. Continue with the task — newly installed skills are immediately available

**If the plugin is not in the listed marketplace** (`claude-plugins-official`): proceed without it — the core agents handle most work. Do NOT add or search any other marketplace; only the sources named in `bin/lib/install-receipt.sh` (`hmd_marketplace_source`) are ever registered. Every install attempt, ok or failed, is recorded in the run receipt (`~/.heimdall/receipts/installs-<run id>.ndjson`) and listed by `summary-card --receipt`.

**CRITICAL: Install BEFORE spawning agents.** If a coder agent needs frontend-design skills but they're not installed, the agent runs without them and produces worse output. Install first, spawn second.

## Mid-Task Plugin Discovery

Plugin needs aren't always obvious from the initial prompt. During execution, if you encounter ANY of these signals, **stop and install the relevant plugin immediately**:

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

**Process when discovered mid-task:**
1. Pause current work (don't spawn the next agent yet)
2. Install: `claude plugins install <plugin>@claude-plugins-official` (a failure is reported as `install failed, continuing without <plugin>`)
3. Announce: "Discovered React codebase — installed frontend-design plugin."
4. Run `/reload-plugins` to load newly installed skills
5. Resume work — the new skills are now available to all agents

This is NOT a one-time check. Every time you read a new file or enter a new part of the codebase, re-evaluate whether a plugin would help. The cost of installing is 2 seconds; the cost of working without the right skill is lower quality output for the entire task.
