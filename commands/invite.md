---
name: invite
description: Print a ONE-COMMAND team join to recruit a teammate onto your Heimdall team. Use when a dev wants to add someone to their team's presence wall — the statusline "invite your team" tease points here. Resolves this repo's team secret from the dev's OWN <repo>/.heimdall/team.json and inlines it (plus the control-plane URL) into the canonical curl|bash installer one-liner, so the teammate pastes a single command and auto-joins on first session. The team secret is a bearer capability printed to the terminal ONLY — never written to any file. Enrollment is open-bounded (tokenless) — the join carries only the team secret. Degrades cleanly (helpful setup message) when no team is configured.
---

# /hmd:invite — Recruit a Teammate with a One-Command Join

Use when a dev wants to add a teammate to their team — the growth loop behind the
statusline wall tease ("── watch ── invite your team · hmd invite"). It prints a
single `curl … | … bash` line carrying THIS team's control-plane URL + team
secret; the teammate pastes that one command and presence auto-enrolls them on
their first session (the wall recruits the team). Enrollment itself is
open-bounded (tokenless) — nothing for a user to pass or see.

## Process

1. **Run the CLI** — it resolves everything and prints the shareable join:

   ```bash
   "${CLAUDE_PLUGIN_ROOT}/bin/heimdall-invite"
   ```

   Add `--qr` to also render a scannable QR of the join (only if `qrencode` is
   installed; it degrades silently when absent):

   ```bash
   "${CLAUDE_PLUGIN_ROOT}/bin/heimdall-invite" --qr
   ```

   The CLI reads this repo's OWN `<repo>/.heimdall/team.json` (the same file
   `bin/heimdall-presence` and `bin/heimdall-team` read) for the team secret, and
   the dev's global `~/.heimdall/cp-endpoint.json` (else the baked public default)
   for the control-plane `url`, then mirrors the canonical README installer
   one-liner for the repo/ref.

2. **Relay the join verbatim.** Pass the printed one-liner straight to the dev —
   do NOT paraphrase, wrap, or alter it. The teammate runs it as-is.

3. **Honor the secret caveat.** The CLI prints a
   `⚠ contains your team secret — share only with teammates` caveat above the
   command. Keep that warning attached when you relay it.

4. **On the "not configured" message**, the dev has no team minted for this repo
   yet. The CLI prints how to mint one (`heimdall-team new`, writes
   `<repo>/.heimdall/team.json`, 0600) and exits 0 — relay that guidance; there is
   nothing to invite to yet.

## Constraints

- **The team secret is a bearer capability.** It is this team's own secret,
  deliberately shared with a teammate — the CLI prints it to the terminal ONLY and
  NEVER writes it to a tracked/committed file, a log, or anything in the repo. Do
  not echo it into any other command, copy it into a tracked file, or paste it
  anywhere but to the intended teammate.
- **Tokenless enrollment.** The join carries a team secret, never a bootstrap
  enroll credential. Do not add any enroll credential to the one-liner — re-gating
  enrollment is an operator-only concern (see `OPERATORS.md`), never a user surface.
- **Don't fabricate a join.** If no team is configured, relay the CLI's setup
  guidance — never hand-craft a one-liner with a guessed URL or secret.
- Files nothing. It reads local config and makes one lightweight, read-only origin
  check (`git ls-remote` + a raw-URL HTTP probe) to guarantee the pinned ref
  actually resolves — if it does NOT, the CLI REFUSES to print a broken join,
  prints a loud error, and exits non-zero (the owner must push/tag/publish first).

## Examples

Dev: "add Sam to my team"
→ `heimdall-invite`
→ relay the printed `curl … | HEIMDALL_CP_URL='…' HEIMDALL_TEAM_SECRET='…' bash`
  line plus the `⚠ … share only with teammates` caveat.

Dev: "give me a QR my teammate can scan"
→ `heimdall-invite --qr`
→ relay the one-liner and the rendered QR (or just the one-liner if `qrencode`
  isn't installed).
