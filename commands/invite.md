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

2. **Expect a non-interactive refusal — that is correct, not a bug.** Because you
   (the assistant) capture this command's output rather than reading it off a live
   screen, the CLI cannot tell "an assistant relaying to a trusted dev" apart from
   any other non-human reader of a transcript — so by default it refuses (exit 4)
   and prints guidance instead of the join. This is the fix for the exact incident
   this command used to cause: an agent ran this CLI, and a live bearer secret got
   written into a session transcript on disk.

   - Do **NOT** pass `--yes-print-secret` to force output. That override exists for
     a human operator's OWN deliberate non-interactive use (CI, scripted
     enrollment) — never for an assistant to invoke on a user's behalf just to make
     the command produce text.
   - Relay the refusal instead: tell the dev to run `heimdall-invite` themselves,
     at their own terminal, to get the join. That is the only path that should ever
     show the live secret.

3. **Relay the join verbatim** — only when the CLI actually printed one (a human
   ran it themselves at a real terminal, per step 2, and is now pasting the
   result). Pass it straight to the dev — do NOT paraphrase, wrap, or alter it. The
   teammate runs it as-is.

4. **Honor both secret warnings.** The CLI prints a
   `⚠ contains your team secret — share only with teammates` caveat AND a
   `⚠ this is a LIVE bearer credential — anyone who can read your screen or
   scrollback can join your team` warning above the command. Keep both attached
   when you relay it.

5. **On the "not configured" message**, the dev has no team minted for this repo
   yet. The CLI prints how to mint one (`heimdall-team new`, writes
   `<repo>/.heimdall/team.json`, 0600) and exits 0 — relay that guidance; there is
   nothing to invite to yet. (Unaffected by the non-interactive refusal — there is
   no secret yet to withhold.)

## Constraints

- **Never pass `--yes-print-secret` on a user's behalf.** It exists so a human
  operator can deliberately opt in to non-interactive printing (CI, scripted
  enrollment) — never so an assistant can route around the refusal to get output.
  Hitting the refusal is the CLI working as designed; relay it, don't override it.
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
→ typical result: refused (exit 4) because this runs non-interactively — relay
  the guidance and tell the dev to run `heimdall-invite` themselves at their own
  terminal.
→ if the dev instead pastes output from their OWN terminal session, relay the
  printed `curl … | HEIMDALL_CP_URL='…' HEIMDALL_TEAM_SECRET='…' bash` line plus
  both `⚠` warnings verbatim.

Dev: "give me a QR my teammate can scan"
→ `heimdall-invite --qr` (same non-interactive refusal applies)
→ relay the one-liner and the rendered QR (or just the one-liner if `qrencode`
  isn't installed).
