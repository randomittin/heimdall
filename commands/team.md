---
name: team
description: Manage this repo's TEAM for multi-tenant Heimdall presence — mint, join, or inspect the per-repo team secret. Use when a dev wants to start a private team, switch teams, join a teammate's team, or check which team this repo is on. A team = a high-entropy secret scoped to a repo; presence (HAID + online + edits) is visible ONLY to holders of that secret. `new` mints a secret into <repo>/.heimdall/team.json (0600, gitignored) and prints the share-able join one-liner; `join <secret>` enrolls into a teammate's team; `show` prints the NON-SECRET team_id (never the secret). Zero-config still works — heimdall-presence auto-mints a solo team on first run.
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

3. **Inspect the team** — `show` prints the NON-SECRET team_id + whether
   configured; it NEVER prints the secret:

   ```bash
   "${CLAUDE_PLUGIN_ROOT}/bin/heimdall-team" show
   "${CLAUDE_PLUGIN_ROOT}/bin/heimdall-team" show --json
   ```

4. **Recruit teammates** — once a team exists, `/hmd:invite` (or
   `bin/heimdall-invite`) prints the one-command join carrying the team secret.

## Constraints

- **The team secret is a secret.** It is written ONLY to `<repo>/.heimdall/team.json`
  (mode 0600, gitignored) and never crosses another command's argv, a log, or a
  tracked file. `new` prints it to stdout ONCE (with a ⚠ caveat) so the owner can
  share it; `show` never prints it. When relaying `new`/`invite` output, keep the
  caveat attached and only share the secret with intended teammates.
- **One active team per repo.** `team.json` holds one team; `join` switches teams
  by overwriting it. A dev on different repos may be on different teams.
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

Dev: "what team is this repo on?"
→ `heimdall-team show` → relay the team_id (never the secret).
