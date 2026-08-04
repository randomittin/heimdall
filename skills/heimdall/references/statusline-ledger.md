# The Ledger `status.json` Contract (HMD Statusline Spec v1 §6)

The new statusline reads **one** JSON file per refresh — `~/.heimdall/ledger/status.json` —
instead of shelling out to a dozen probes on the hot path. This document is the contract
between the **writer** (`bin/heimdall-status-json`) and the **reader** (the statusline script).

## Who writes it

`bin/heimdall-status-json` is the **single writer**. It folds four already-existing, real
sources into the schema below and writes the result **atomically** (temp file + `os.replace`
rename), so a mid-refresh read never sees a partial file.

## Cadence — when it refreshes

- **Live-session cadence:** the presence **keeper loop** (`bin/heimdall-presence`, the
  `keeper-loop` subcommand) calls `heimdall-status-json` on **every heartbeat cycle** (default
  every 20s, `HMD_KEEPER_INTERVAL`). So while a session is live and the keeper is running, the
  file stays warm. This is also the source of the `daemon` liveness signal — the keeper's own
  pidfile is what makes `daemon` read `"watching"`.
- **Gate cadence:** the `gates`/`verdict` fields refresh whenever a **gate run records a new
  verdict** — i.e. when `bin/heimdall-gate-run` runs at commit/push and rewrites
  `<repo>/.heimdall/verdict.json`. The next status refresh picks the new gates up.
- The statusline reads the file through its **own ~5s cache**, so the writer only has to keep
  that cache warm — it does not need to be sub-second.

## The schema

```json
{
  "daemon": "watching",
  "gates": [
    {"id": "secrets",     "state": "pass", "detail": "0"},
    {"id": "tests",       "state": "pass", "detail": "41/41"},
    {"id": "designmatch", "state": "pass", "detail": ".91"}
  ],
  "verdict": {"state": "pass", "label": "GENERALIZES"},
  "team": [
    {"user": "mira", "sigil": "#3DD6A3", "branch": null, "state": "active", "ts": 1752403000}
  ]
}
```

| Field | Type | Vocabulary / meaning |
|---|---|---|
| `daemon` | string | `"watching"` \| `"down"` — is the presence keeper alive? |
| `gates[].id` | string | the gate's identifier (e.g. `falsify:<domain>`, `corpus`) |
| `gates[].state` | string | `"pass"` \| `"running"` \| `"deny"` — statusline renders ✓ / ◌ / ✗ |
| `gates[].detail` | string | short honest detail (e.g. `"41/41"`, the falsifiability score `"6/6"`) |
| `verdict.state` | string | `"pass"` \| `"deny"` \| `"pending"` (no gated run yet) |
| `verdict.label` | string | `"GENERALIZES"` (pass) \| `"BLOCKED"` (deny) \| `"PENDING"` |
| `team[].user` | string | the teammate's handle (falls back to the HAID human part) |
| `team[].sigil` | string | `#RRGGBB` — the teammate's deterministic identity hue (see below) |
| `team[].branch` | string \| null | the git branch — **currently always `null`** (see gaps) |
| `team[].state` | string \| null | the roster wall state: `"active"` \| `"idle"` |
| `team[].ts` | int \| null | heartbeat epoch seconds (reconstructed from roster `age_seconds`) |

The top-level object always has exactly these four keys, sorted, and is always valid JSON.

## The real sources (never fabricated)

Every field is read from a real, existing source. An **empty source yields an honestly-empty
field** — the writer never invents a gate, a verdict, or a teammate.

- **`daemon`** ← presence **keeper liveness**. A pidfile under `$HEIMDALL_KEEPER_DIR` (default
  `~/.heimdall/presence-keeper`, the exact dir `bin/heimdall-presence`'s keeper claims) naming a
  **live** process (a real `kill -0` probe) ⇒ `"watching"`; none alive ⇒ `"down"`.
- **`gates`** ← the last gate-run's **per-gate results**, from `<repo>/.heimdall/verdict.json`
  `.gates` (the array `bin/heimdall-gate-run` persists alongside the overall verdict). Absent
  (old file, or no gated run yet) ⇒ `[]`.
- **`verdict`** ← the overall verdict from the same `verdict.json` `.verdict` (`pass`/`deny`),
  mapped to `{state,label}`. No `verdict.json` ⇒ `{"pending","PENDING"}`.
- **`team`** ← the presence **roster** (`bin/heimdall-presence roster --json`) — the devs on this
  project's team who are **on the wall**. Each roster row
  `{haid, handle, verdict, file, age_seconds, state, online}` maps to a `team[]` entry. The
  **sigil** hue is the sigil core's `glyph_color(haid)` (`sentinels/hmd_sigil.py`) rendered as
  `#RRGGBB` — the **same** hue every sigil surface (statusline, banner, TUI) paints for that
  identity. The `online` flag is carried through **verbatim**; an absent flag stays `null` and
  the statusline falls back to its own heartbeat TTL. The writer never synthesises it.

### The wall window — who gets a slot (three clocks, one decision each)

| Clock | Constant | Default | Decides |
|---|---|---|---|
| Online TTL | `cp_presence.DEFAULT_TTL_SECONDS` | 45s | `online: true` vs `false` |
| Activity window | `cp_presence.DEFAULT_ACTIVITY_TTL_SECONDS` | 120s | `active` vs `idle` (online devs only) |
| **Offline wall window** | `cp_presence.DEFAULT_OFFLINE_WINDOW_SECONDS` / `hmd_ledger.OFFLINE_WINDOW` | **7 days** | **membership — a slot at all** |

A teammate whose last heartbeat is **within 7 days** keeps a wall slot and renders in an
explicit **OFFLINE** state; past 7 days they leave the wall, so it stays a current-team view
rather than a graveyard. Both constants are **named at both layers** and must stay in step;
the server side is env-tunable via `HEIMDALL_PRESENCE_OFFLINE_WINDOW_SECONDS`.

**Why the window exists.** Membership used to be online-only: an away teammate was *erased*,
so a wall showing only yourself was indistinguishable from a wall that was **broken** — a real
presence outage looked exactly like a quiet afternoon. Rendering "away" explicitly is what makes
the difference visible.

**Offline is unmistakable, never a subtly-different online** — three independent signals, so no
single failure mode (no-color terminal, mono tier, colorblind viewer) can make away read as
present: the Row4 segment `⊘off 3d` (a glyph absent from the online vocabulary `◉ ⚡ ✗ ○`, plus
the literal word `off`), the sigil strip rendered in the **mono** tier so the identity hue drains
out, and the name dropped to the faintest hue. At narrow width the dot goes **hollow** (`○` away
vs `●` here). Offline **outranks** the Row4 branch line — a stale teammate still carries a branch
from their last beat, and `⎇feature/x` under an unmarked name reads as someone working *now*.

**No privacy change.** An offline row is the same partition behind the same repo team secret,
projecting exactly the fields an online row already did — it reveals nothing a live teammate
would not. Retirement (`hmd presence off`) still drops a dev at the read authority, so opt-out
stays real rather than becoming "visible, but greyed".

## The fallback contract — the writer must not write garbage

The **statusline** owns the absence case: if `status.json` is missing/stale, or `daemon` reads
`"down"`, the statusline shows the down / gates-offline state. The **writer's** only job is to
never write garbage:

- Every source is read **defensively**. A missing file, malformed JSON, or missing key degrades
  to that field's empty value (`[]`, `"down"`, `"pending"`) — so the assembled object is
  **always schema-valid**.
- The write is **atomic** (temp in the same directory + rename), and the temp is cleaned up on
  any failure, so a reader never observes a partial or truncated file.
- Daemon-down + empty-roster + no-verdict is a **normal success path** that produces a valid
  file (`daemon:"down"`, `gates:[]`, `team:[]`, `verdict` pending) and exits `0` — never a crash.

## Statusline-side responsibilities (not the writer's job)

- **Filter `team[]` to `ts` < 5 min old** and **exclude self**. The writer emits the full online
  roster projection (the presence roster already TTL-drops offline devs at ~45s); the freshness
  cut and self-exclusion are the statusline's.

## Env seams (for wiring + tests)

| Var | Default | Purpose |
|---|---|---|
| `HMD_STATUS_OUT` | `$HEIMDALL_HOME/ledger/status.json` | output path |
| `HEIMDALL_HOME` | `~/.heimdall` | runtime home |
| `HEIMDALL_KEEPER_DIR` | `$HEIMDALL_HOME/presence-keeper` | keeper pidfile dir (daemon liveness) |
| `HMD_STATUS_VERDICT_FILE` | `<repo>/.heimdall/verdict.json` | gate verdict source |
| `HMD_STATUS_ROSTER_JSON` | — | inject roster JSON (else run `heimdall-presence roster`) |
| `HMD_STATUS_NOW` | `date +%s` | inject "now" epoch (deterministic ts reconstruction) |

## Known gaps (honest-empty today, not fabricated)

1. **`team[].branch` is always `null`.** Presence broadcasts the **file** a dev is editing, not
   the git branch, and no cross-dev branch is available anywhere in the roster. Rather than
   fabricate one (e.g. from the file path), the writer emits `null`. Populating it would require
   the presence beat body (`bin/heimdall-presence` beat) to broadcast the branch, and the roster
   member view (`bin/lib/cp_presence.py::_team_view`) to carry it through.
2. **`gates[]` per-gate detail depends on the gate runner's output.** `heimdall-gate-run`
   records the falsifiability score (`bin/falsify`'s `SCORE: k/t` line) and the corpus count when
   the runner prints one; when it does not, `detail` is an honest empty string.

## Tests

`test/heimdall-status-json.test.sh` proves the schema, real daemon liveness (`kill -0`), the
gate/verdict/team mapping, the sigil-hue match against the core, honest-empty + no-crash, atomic
write (no `.tmp` left behind), and that `heimdall-gate-run` now persists a `gates[]` array that
the writer consumes end-to-end.
