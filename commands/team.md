---
name: team
description: Manage this repo's TEAM for multi-tenant Heimdall presence — mint, join, share, or inspect the per-repo team secret. Use when a dev wants to start a private team, switch teams, join a teammate's team, auto-join repo collaborators, or check which team this repo is on. A team = a high-entropy secret scoped to a repo; presence (HAID + online + edits) is visible ONLY to holders of that secret. `new` mints a secret into <repo>/.heimdall/team.json (0600, gitignored) and prints the share-able join one-liner; `join <secret>` enrolls into a teammate's team; `share` commits the team secret to a verified-PRIVATE repo as team.shared.json so collaborators auto-join on pull (HARD-REFUSES on a public repo); `show` prints the NON-SECRET team_id + its source (never the secret). Zero-config still works — heimdall-presence auto-mints a solo team on first run.
---

# /hmd:team — Manage This Repo's Team (Multi-Tenant Presence)

Use when a dev wants to control which TEAM this repo's presence is scoped to. A
**team = a secret scoped to a repo**: a teammate's HAID, online state, and current
file/edits are visible ONLY to holders of that secret; cross-team and outsiders
see NOTHING. The secret's non-secret handle is
`team_id = sha256("heimdall-team\0"+secret)[:32]` — the partition the server keys
presence on.

**Zero-config still holds:** a dev does NOT have to run this. `bin/heimdall-presence`
auto-mints a private solo team on the first beat/roster, so a new dev starts in
their own team (sees only themselves) until they deliberately share or join.

**Two team files (distinct on purpose):**

- `<repo>/.heimdall/team.json` — **PERSONAL/local**: a dev's own (or auto-solo) team.
  Mode 0600, **gitignored**, never committed.
- `<repo>/.heimdall/team.shared.json` — the team's **SHARED** secret, **TRACKED/
  committed** (only ever in a PRIVATE repo). A collaborator who clones/pulls it
  **auto-joins** that team with no secret paste — the collaborator-clone is the
  access boundary. Written ONLY by `share`, gated HARD on a verified-private repo.

## Process

1. **Mint a new team** — `new` writes a fresh secret to `<repo>/.heimdall/team.json`
   (0600, gitignored) and prints the secret plus the `heimdall-invite` join
   one-liner to share:

   ```bash
   "${CLAUDE_PLUGIN_ROOT}/bin/heimdall-team" new
   ```

   It REFUSES to overwrite an existing team without `--force` (re-minting orphans
   you from the current team). Re-mint deliberately with:

   ```bash
   "${CLAUDE_PLUGIN_ROOT}/bin/heimdall-team" new --force
   ```

2. **Join a teammate's team** — paste the secret they shared:

   ```bash
   "${CLAUDE_PLUGIN_ROOT}/bin/heimdall-team" join '<team-secret>'
   ```

   A secret shorter than 32 chars is rejected (a weak secret could collide into
   another team). This switches THIS repo onto their team on the next beat/roster.

3. **Auto-join repo collaborators (private repos only)** — `share` commits this
   repo's team secret to `<repo>/.heimdall/team.shared.json` (tracked) so anyone who
   is already a collaborator and pulls the repo **auto-joins** the team — zero secret
   paste:

   ```bash
   "${CLAUDE_PLUGIN_ROOT}/bin/heimdall-team" share
   ```

   **THE CARDINAL GUARD:** `share` FIRST verifies the repo is **PRIVATE** via
   `gh api repos/{owner}/{repo} --jq .private` (owner/repo from `origin`). It
   **HARD-REFUSES** (non-zero exit, writes/commits NOTHING) if:
   - the repo is **PUBLIC** — committing the team secret to a public repo would
     expose the whole team's private presence to the world (the exact thing the
     multi-tenant model prevents); or
   - privacy **cannot be verified** — `gh` is absent or not authenticated. Fail
     closed: if it can't PROVE the repo is private, it won't risk a leak.

   `share` does NOT push (the owner pushes when ready). Rotate the team secret later
   with `--rotate` (mints a fresh secret, overwrites both team files, re-commits; the
   old team_id ages out in one presence TTL, collaborators re-join on next pull):

   ```bash
   "${CLAUDE_PLUGIN_ROOT}/bin/heimdall-team" share --rotate
   ```

4. **Inspect the team** — `show` prints the NON-SECRET team_id, its **source**
   (`shared` | `personal` | `solo`), and whether configured; it NEVER prints the
   secret:

   ```bash
   "${CLAUDE_PLUGIN_ROOT}/bin/heimdall-team" show
   "${CLAUDE_PLUGIN_ROOT}/bin/heimdall-team" show --json
   ```

5. **Recruit teammates** — once a team exists, `/hmd:invite` (or
   `bin/heimdall-invite`) prints the one-command join carrying the team secret (the
   out-of-band path for a teammate who is NOT yet a repo collaborator).

## Constraints

- **The team secret is a secret.** It is written ONLY to `<repo>/.heimdall/team.json`
  (mode 0600, gitignored) and never crosses another command's argv, a log, or a
  tracked file. `new` prints it to stdout ONCE (with a ⚠ caveat) so the owner can
  share it; `show` never prints it. When relaying `new`/`invite` output, keep the
  caveat attached and only share the secret with intended teammates.
- **One active team per repo.** `team.json` holds one team; `join` switches teams
  by overwriting it. A dev on different repos may be on different teams.
- **Resolution precedence (shared vs personal — the decision).** Both `show` and
  `heimdall-presence` resolve the active secret in this order:
  1. an **explicit** personal `team.json` (written by `new`/`join`, tagged
     `source:new|join`) — a deliberate choice **always wins**;
  2. **`team.shared.json`** — the committed team (collaborator **auto-join**);
  3. an **auto-solo** personal `team.json` (`source:auto-solo`/legacy);
  4. nothing → `heimdall-presence` auto-mints a solo team.
  **Rationale:** a teammate who just clones a private repo carrying
  `team.shared.json` auto-joins it (shared beats the auto-solo default), while a dev
  who *deliberately* ran `team join <other>` keeps their own choice (explicit beats
  shared). The `source` tag in `team.json` is what distinguishes a deliberate choice
  from an auto-solo mint.
- **`share` is the ONE intentional secret commit — gated on PRIVATE.** It is the only
  path that writes a secret to a tracked file, and only after proving the repo is
  private. `team.json` stays gitignored; `team.shared.json` is the sole un-ignored
  exception. The commit uses `--no-verify` so it is not blocked by the owner's own
  secret-scan pre-commit hook (the secret in `team.shared.json` is intentional).
- **The secret rides the wire ONCE, at enroll.** `heimdall-presence` sends it in
  the `X-Heimdall-Team-Secret` header on `/enroll`; signed beats and roster reads
  thereafter carry NO secret (membership is server-side).
- **Don't hand-craft a secret.** Use `new` (mints 43-char base64url, 256-bit
  entropy). Never type a short or low-entropy secret.

## Examples

Dev: "start a private team for this repo"
→ `heimdall-team new`
→ relay the printed team_id + the `curl … | … HEIMDALL_TEAM_SECRET='…' bash` join
  and the `⚠ … share only with teammates` caveat.

Dev: "join Sam's team, here's the secret"
→ `heimdall-team join '<secret>'` → confirm the team_id it joined.

Dev: "put all my repo collaborators on this team automatically"
→ `heimdall-team share` → if the repo is private, it commits `team.shared.json`;
  collaborators auto-join on pull. If the repo is public, it HARD-REFUSES — relay the
  warning (make it private or use `hmd invite` to distribute out-of-band).

Dev: "rotate our team secret"
→ `heimdall-team share --rotate` → new secret committed; the old team ages out in one
  TTL and collaborators re-join on next pull.

Dev: "what team is this repo on?"
→ `heimdall-team show` → relay the team_id + source (shared/personal/solo), never the
  secret.
