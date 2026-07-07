# Heimdall Design Invariants

Standing design assumptions that outlive any single feature or release. Each is stated plainly,
motivated, and locked by a falsifiable test. An invariant is not a preference — it is a promise the
codebase makes to itself. Breaking one is a regression even if every unit test is green.

---

## Δ1 — Live presence + the wall are free at any team size, forever

**The invariant.** Live presence and the wall are free at **any** team size, **forever**. No feature
may gate presence, enrollment into the wall, the beat, or roster membership/visibility on team size.
A team with 3 members and a team with 3,000 members see the **same** presence product: every online
teammate appears on the wall. The server/roster API returns the **full** member set — never a
size-capped page.

**Permitted (explicitly not a violation):**

- **Display overflow (`+k`).** A client may render `K` glyphs and a `+k more` badge. This is a pure
  computation *over the complete set the server returned* — the server still hands back every member;
  the client chooses how many to draw. A display cap is a rendering choice, never a membership drop.
- **Abuse throttles (per-IP / per-window rate limits).** These are cost-governance, keyed on request
  *rate*, not on team *size*. A per-IP roster-read cap (429 under flood) or a per-team enqueue-rate
  cap is fine — it slows a flood, it never hides a real teammate.

**Forbidden (a Δ1 violation):**

- A **membership / visibility cap** that hides or refuses a **real** teammate once a team crosses a
  size threshold: `MAX_TEAM_MEMBERS` in the roster read, a roster query that truncates real members
  to `N`, enrollment refused past `N` *for being too many*, a paywall/entitlement gate keyed on team
  size, or any beat/heartbeat path that stops recording a member because the team is "full".

### Why this is load-bearing

1. **It protects the auto-join viral loop.** The growth engine is "everyone on the project shows up
   live, automatically." If presence assumed a team-size limit, a teammate past the cap would
   silently never appear on the wall — the promise dies at `N`, and the loop that makes teams adopt
   Heimdall stops compounding.

2. **It avoids a refactor tax when revenue opens.** Revenue is currently *deferred* — parked behind
   ★1,000 GitHub stars. When the gate opens, revenue must gate on **features** (history retention,
   analytics, advanced dashboards), **never** on presence or team size. If a size cap were baked into
   the read/beat path now, opening the revenue gate would mean ripping it back out *and* re-proving
   the isolation/durability properties around it. Keeping presence uncapped from day one means the
   revenue work is purely additive.

Revenue gates on **what a team can do with history/analytics**, never on **how many teammates can be
seen live**. Presence and size are off the pricing table by construction.

### Where it lives

- `bin/lib/cp_presence.py` — `record_presence()` (the beat, no size gate), `roster()` (the fold,
  enumerates the *entire* partition via `StateBackend.list_names`, no cap/slice), `roster_team_route()`
  (the team-private browser read, returns the full `online` set).
- `bin/lib/cp_state.py` / `cp_state_firestore.py` — `list_names()` is a full sorted enumeration with
  **no** limit argument; there is no paging seam that could silently drop members.

### Locked by

`test/heimdall-delta1-team-size.test.sh` — seeds `N=50` distinct online beats into one
`(project, team)` partition and proves:

- **A/B** — `roster()` returns all 50; every beat is accepted, none refused for size (the beat /
  auto-join path has no team-size gate).
- **C** — `GET /roster-team` returns the full 50-member set (the wall's data source is complete,
  un-paged).
- **D (falsifier)** — monkeypatching a `MAX_TEAM_MEMBERS` cap into the roster read truncates the wall,
  which would flip **C** red. The lock is not green-by-construction: a membership cap is caught.
- **E** — a `K`-glyph + `+k` display overflow is derivable from the full server set (the permitted,
  client-side side of the distinction).

External falsifier check (run during development): patching `return out[:10]` into
`cp_presence.roster` turns the suite red (A1/C1/D1/E1 fail) — proving the test catches the exact class
of change Δ1 forbids.

### Open tension — flagged, not resolved here

`bin/lib/cp_enroll.py` carries a **per-team member cap** (`HEIMDALL_TEAM_MAX_MEMBERS`, default `100`;
"RJ ruling 4"): a *net-new* haid is refused enrollment with `team_full` (429) once a team already
holds 100 PKI bindings. Its stated intent is **abuse containment** — bounding how much one (possibly
leaked) `team_secret` can bloat the registry — and it is env-tunable.

This sits on a fault line in Δ1's wording:

- It is **not** in the presence/beat/roster read path — those remain uncapped (this test proves it),
  so the *wall/visibility* half of Δ1 is intact regardless.
- But it **is** a team-size threshold on **enrollment**, and Δ1's plain statement forbids gating
  *enrollment* on team size. Under the strict reading it caps the PKI auto-join loop at 100
  members/team.

Two ways to reconcile (a deliberate decision for RJ, **not** silently changed here):

1. **Δ1 scopes to presence/wall/roster only** (the live-visibility surface). Then the 100-cap is an
   accepted abuse control on the *registration* surface and Δ1 holds as written. If so, Δ1's wording
   should be tightened to say "presence/wall/roster membership", dropping bare "enrollment".
2. **Δ1 scopes to enrollment too.** Then the 100-cap must be **reframed** from a hard membership
   count into a per-IP / per-window *rate* throttle (the permitted abuse class), so a real 101st
   teammate is never refused for existing.

Until RJ rules, the presence/wall/roster surface is locked uncapped (this invariant), and the
`cp_enroll` 100-cap is recorded here as the one place that touches a team-size threshold.
