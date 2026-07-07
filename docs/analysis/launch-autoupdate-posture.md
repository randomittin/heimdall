# Auto-Update Posture — Launch Decision Memo (item 9)

Date: 2026-07-07 · Author: hmd · Decision owner: RJ

## What auto-update does today (verified: `bin/heimdall-autoupdate`)
- **On by default.** SessionStart hook calls `heimdall-autoupdate check` (`:8,21-26`).
- Resolves **installed** (git tag → manifest, `:88-108`) vs **latest** (GitHub `releases/latest`
  `.tag_name`, then `ls-remote` fallback, `:110-155`). If `latest > installed` by strict semver
  (`:161-189`), it **re-runs the latest tag's `install.sh` detached** (`:221-243`).
- **Safe-apply model** (`:11-19`): the running session is never hot-swapped — the on-disk tree is
  refreshed for the **NEXT** launch. `install.sh` is the atomic unit (idempotent, preserves
  `cp-endpoint.json` + PKI seeds, fails closed). Worst case = "no upgrade this time."
- **Never downgrades** (strict-greater only, `:161-164`); throttled 24h (`:66,194-201`); offline =
  silent no-op (`:30-33`). Opt-out: `HEIMDALL_NO_AUTOUPDATE=1` **or** `~/.heimdall/no-autoupdate`
  (`:37,209-215`).

## The launch-day risk
Every `ship.sh` push becomes `releases/latest`, and **within 24h every installed machine — every
new HN stranger — rolls to it on next session.** A bad release therefore auto-propagates to the
entire install base. Because auto-update **never downgrades** (by design, `:32`), a bad release can
only be **fixed forward** — there is no roll-back lever, so the fix path must be fast.

## What already protects us
- `ship.sh` gates on a green R9 full gate before it tags/publishes (checklist item 1) — a broken
  build shouldn't reach `releases/latest` in the first place.
- Apply is next-session, atomic, config-preserving, fail-closed — no half-applied state, no
  live-session breakage (`:11-19`).
- Client resolves latest from **GitHub Releases**, not raw `main` — an un-released commit on `main`
  does **not** ship. The Release publish is the control point.

## Recommendation (decision-ready)
**Keep auto-update ON**, and add the launch-week discipline + one honest pre-published lever:

1. **Ritual (RJ):** during launch week, run `ship.sh` **only** from a green full gate, and use
   `--no-bump` for doc-only pushes so not every push becomes a `releases/latest` that rolls to
   strangers. (Checklist item 9 line item — confirmed the flag exists in the ship flow.)
2. **Fix-forward playbook, written & fast:** a bad release is superseded by shipping a fixed patch;
   clients roll forward next session. Because there is no downgrade, keep a one-command
   `ship.sh` hotfix path warm and know the ~24h throttle means worst-case propagation is a day
   (users can force sooner with `heimdall-autoupdate --force`).
3. **Operator pause lever (the kill-switch):** to stop the roll to *new* users mid-incident,
   **delete / unpublish the bad GitHub Release** (or publish a fixed patch as the new latest) —
   `latest_version()` reads `releases/latest` (`:110-140`), so un-publishing removes it as the
   auto-update target immediately; the `ls-remote --tags` fallback (`:142-153`) still resolves the
   highest **tag**, so also delete the bad tag if you unpublish, or clients fall back to it.
4. **Visible opt-out line at install (checklist checkbox):** ensure install output prints one line
   naming auto-update + the opt-out (`HEIMDALL_NO_AUTOUPDATE=1` / `~/.heimdall/no-autoupdate`), and
   the README "Automatic updates" section states the fix-forward trade-off honestly.

## The exact operator lever (how to pause the roll)
There is no env flag on the server that pauses client auto-update — the client pulls from GitHub.
The lever is therefore the **Release artifact itself**:

| Action | Effect on the fleet |
|---|---|
| **Un-publish the bad GitHub Release** (`gh release delete <tag> --yes`) **and delete the tag** (`git push origin :refs/tags/<tag>`) | Removes it as `releases/latest` **and** as the `ls-remote` fallback → new sessions stop rolling to it |
| **Ship a fixed patch** (`ship.sh` from green) | New latest supersedes; clients fix-forward next session (or `--force`) |
| Per-machine stop | `HEIMDALL_NO_AUTOUPDATE=1` or `touch ~/.heimdall/no-autoupdate` (`:37,209-215`) |

**Bottom line:** ON + green-gate ritual + a written fix-forward path + the un-publish lever. The
architecture is already fail-closed and downgrade-proof; the missing piece is the *human ritual*
and the *incident lever above written down before strangers install.*
