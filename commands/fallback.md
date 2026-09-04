---
name: fallback
description: Show or change hmd's OmniRoute fallback-routing gate — whether Heimdall may route work to a third-party model, through a locally-hosted OmniRoute gateway, using the operator's OWN API key, when Claude capacity runs out. Use when a dev asks why fallback isn't routing, wants to arm it (`auto` for near-exhaustion only, `switch` for everything), or wants it back off. No key is required for a no-auth provider (e.g. `duckduckgo-web`); a keyed provider needs `operator_key_env` set to the NAME of the env var holding the key, never the key itself. This is a policy gate only — it decides whether routing is ALLOWED, it never performs the routing itself, and it never arms anything without an explicit `heimdall-fallback set`.
argument-hint: [status|check|arm|auto|switch|off|where]
disable-model-invocation: true
---

# /hmd:fallback — Control Whether Heimdall May Route Work Off Claude

`heimdall-fallback` is a POLICY gate, not a transport: it decides whether hmd
is *allowed* to route a task to a locally-hosted OmniRoute gateway using the
operator's own third-party API key. It never calls OmniRoute itself. Three
states, one identical safety boundary underneath all of them (Tier-1
credential absence, `ANTHROPIC_MODEL` pinning, no delegated sidecar, a
provider allow-list) — no state ever weakens that boundary. `off` is the
default on every fresh install and on any corrupted config.

## No argument — show state and what's blocking a route

```bash
heimdall-fallback status
```

If it prints `would preflight pass: no`, also run:

```bash
heimdall-fallback check
```

and read the failing lines back in plain language — each `[FAIL]` line
already names the check and the exact reason, e.g.:

```
[FAIL] anthropic_model_pinned -- ANTHROPIC_MODEL is not set -- ...
```

Never just say "it's not routing" — say which of state / key / endpoint /
Tier-1 credential / model-pin / sidecar / provider is the actual blocker,
using the table below to translate the check name into what the operator
needs to do about it.

## The three states

| state    | what it actually does |
|----------|------------------------|
| `off`    | Never routes. Every task stays on Claude. |
| `auto`   | The exhaustion reaction: routes ONLY once THIS session's real usage crosses ~95% of Anthropic's 5-hour window (`rate_limits.five_hour.used_percentage` — the same number Claude Code's own statusline shows). Below that, or if it can't be measured, `auto` WAITs rather than routing blind — there's no reason to leave Anthropic while quota remains. |
| `switch` | Everything routes, every tier, tier is never consulted. `status` and `check` both print an impossible-to-miss warning while you're in this state — it's the one state where quality-sensitive work can land on a provider with no no-train guarantee. |

**Removed (owner directive):** a fourth state, `on`, used to exist as a
**capability-tier** decision — routing ONLY low-level work (lint, format,
rename, simple config, doc-sync; the haiku tier), independent of exhaustion.
That was a genuine, distinct capability: neither `auto` nor `switch` offers a
tier-restricted routing option, so it is gone, not renamed. `set on` /
`arm --state on` are now rejected outright, naming the three valid states.

All three sit behind the identical preflight (Tier-1 credential absence,
`ANTHROPIC_MODEL` pin, sidecar check, provider allow-list). No state skips
it — `switch` still REFUSEs on a failing Tier-1 check exactly like `off` does.

## Arming it automatically — `heimdall-fallback arm`

`heimdall-fallback arm [--provider <name>] [--state auto|switch]` does
almost all of the manual sequence below FOR you, in one command:

```bash
heimdall-fallback arm --state auto
```

It self-provisions everything it can honestly justify:

- **`target_provider`** — reuses an already-valid one already in the config,
  validates an explicit `--provider`, or auto-picks a no-auth provider (one
  that needs no key at all) when nothing usable is configured yet.
- **`operator_key_env`** — left empty for a no-auth target. For a keyed
  target, arm never invents a credential: it only reuses an env var name
  that is already configured in the JSON file AND already populated in this
  shell. If a keyed provider has no usable key, arm refuses rather than
  guessing one.
- **`state`** — written only once the provider/key pair above is settled.

It then runs the exact same preflight `check` runs and reports that verdict,
so `arm` is self-verifying: its own exit code is the identical `0`=ROUTE /
`1`=REFUSE / `2`=WAIT contract.

It fails closed, with no exception carved out for itself: it refuses
outright, leaving the on-disk config byte-for-byte unchanged, for a
`claude`/`claude-web` target, a ToS-denied target, a keyed target with no
usable key, or when no honest no-auth candidate remains.

Two things `arm` genuinely cannot do for you, and reports instead of
pretending are already done:

1. **Pin `ANTHROPIC_MODEL`.** arm prints the exact line, e.g.
   `export ANTHROPIC_MODEL=duckduckgo-web/gpt-4o-mini` — a child process has
   no syscall to set an environment variable in the shell that launched it,
   so this one step has to be run by hand, in that shell (add it to your
   shell profile to persist it across sessions).
2. **Start the OmniRoute gateway.** `heimdall-fallback` is a policy gate, not
   a transport — arm does not start the gateway itself; it only reports
   whether the configured endpoint is reachable and tells you to start it
   yourself if it isn't.

If `arm` refuses, it prints exactly why (and leaves state unchanged) — relay
that reason verbatim rather than re-running it blind.

## Arming it by hand — the manual sequence (there is no `config` subcommand)

`heimdall-fallback` has exactly five subcommands: `status`, `set`, `check`,
`arm`, `where`. Setting *which provider* and *which key* by hand (rather than
via `arm` above) is not one of them — those live directly in the JSON config
file, at the path `where` prints (default `<repo>/.heimdall/fallback.json`).
Useful when `arm` refuses and you want to supply your own provider/key.
Verified end-to-end against a live local OmniRoute gateway:

1. **Find the config file:**
   ```bash
   heimdall-fallback where
   ```
2. **Set `target_provider`** (and `operator_key_env` if it needs a key) by
   editing that JSON file directly — there is no `heimdall-fallback config
   ...` command:
   ```json
   { "target_provider": "duckduckgo-web" }
   ```
   Any field left out keeps its safe default; the next step preserves
   whatever you put here.
3. **Pin `ANTHROPIC_MODEL`** to `<provider>/<model>` (e.g.
   `duckduckgo-web/gpt-4o-mini`), set wherever this shell/session normally
   gets its env vars. This is required, not optional: an unpinned or bare
   `claude-*` model id is exactly the form OmniRoute would otherwise match
   back to the operator's own Claude subscription.
4. **Arm it:**
   ```bash
   heimdall-fallback set auto      # or: switch
   ```
5. **Confirm:**
   ```bash
   heimdall-fallback check
   ```
   Expect `VERDICT: ROUTE` (under `auto`, expect `WAIT` until the session
   actually crosses ~95% — that's correct behavior, not a bug). `check`'s
   exit code IS the verdict: `0` = ROUTE, `1` = REFUSE, `2` = WAIT.

## Automatic model pinning — the `fallback_model` config field

There is another field worth knowing about in that same JSON config file
(alongside `target_provider` and `operator_key_env`, set the same way — by
editing that JSON file directly): `fallback_model`.

**It is empty by default.** While it is empty, and the operator has not
exported `ANTHROPIC_MODEL` themselves, the preflight's `anthropic_model_pinned`
check FAILS. A passing preflight is required before `auto` can ever reach
`ROUTE`, so `auto` can only ever WAIT, indefinitely, on a fresh install —
this is not a bug: an unpinned session emits bare `claude-*` model ids,
exactly the form OmniRoute has an explicit branch to route back to provider
`claude`, the one thing this tool exists to prevent.

Setting `fallback_model` to a safe `<provider>/<model>` id (e.g.
`oc/big-pickle`; `heimdall-fallback arm` can also resolve one for you) is
what makes unattended `auto` genuinely automatic: `bin/heimdall-route` exports it as `ANTHROPIC_MODEL` on the routed child, right before exec. An operator-set `ANTHROPIC_MODEL` always outranks it — it is only exported when
`ANTHROPIC_MODEL` is not already set in that shell, never overriding an
explicit operator choice, safe or not.

`fallback_model` is held to the identical safety rule as `ANTHROPIC_MODEL`
itself: an id with no explicit `provider/` prefix, or one naming `claude`/
`claude-web` explicitly, is refused — `fallback_model` can never be used to
route fallback traffic back at the operator's own Claude subscription.

## Keys — no-auth needs none; keyed needs the env var NAME, never the key

- A no-auth provider (OmniRoute serves it over a synthetic keyless
  connection — e.g. `duckduckgo-web`) needs no `operator_key_env` at all.
  `status`/`check` say so explicitly when it applies.
- A keyed provider needs `operator_key_env` set, in that same JSON file, to
  the **name** of the environment variable holding the operator's own key —
  e.g. `"operator_key_env": "MISTRAL_API_KEY"` — never the key's value. The
  gate only checks that the named variable is set; it never reads or prints
  it. An `operator_key_env` naming anything with `ANTHROPIC` or `CLAUDE` in
  it is always refused — the Claude Code session can never be reused as a
  fallback key, no exceptions.

## Two costs worth knowing before arming this

1. **Keyless providers can't do real agent work.** A bare `system` field
   alone gets a 400 from `duckduckgo-web` and `felo-web` — they serve plain
   completions, not tool-use. `hmd-exec --backend api` works keyless
   precisely because it sends no `system` field; `--backend claude-code` and
   anything that needs tool-use requires a keyed provider.
2. **Routing is not free even when the provider is free.** Anthropic's
   prompt cache is 91-95% of the value on the table today, and OmniRoute
   drops `cache_control` — so `switch` trades cache hits for real cache
   misses. `auto` exists so that cost is paid only once Claude would
   otherwise be blocked, not by default.

## What gets sent when fallback routes

When state is `auto`/`switch` and a task actually routes, the request
goes to the configured third-party provider — not to Anthropic — and it
carries this session's local context along with it. A live end-to-end run
measured this directly: one routed request carried roughly 41,000 tokens of
local session context.

That figure is a measurement from one real run — not a cap or a guarantee — a
larger accumulated session sends more, not less. The receiving model
demonstrably retained what it was sent: it volunteered unrelated local details
from the session context back in its own reply, unprompted.

This is opt-in exposure, not exposure by default. `off` is the default on
every fresh install and on any corrupted config (see above).

And fallback config is per-repo — `heimdall-route` calls `heimdall-fallback
--repo "$PWD"`, reading and writing `<repo>/.heimdall/fallback.json`, so
arming fallback in one repo never arms it in another. Nothing routes, and
nothing leaves the operator's normal trust boundary, until an operator
explicitly runs `heimdall-fallback set auto|switch` (or `arm`) in that
specific repo.

Exposure scales with whatever is sitting in the context window at the moment
a task actually routes, not with the size of the repo or the provider.
Prefer routing small, self-contained tasks — ones that don't need broad
repo context — through fallback, rather than deep multi-file work carried on
a long, accumulated session: a short, independent task sends little; a long
accumulated session sends everything it has built up.

None of this touches the Tier-1 boundary described above: no state,
including `switch`, ever routes a request at the operator's own Claude
subscription — that boundary is identical across all three states and
unaffected by anything in this section.

## What this does not change

OmniRoute makes hmd **model**-independent — which model answers a request.
It does not make hmd **harness**-independent: the agent loop, tools, and
hooks stay Claude Code regardless of fallback state (see
`docs/analysis/2026-08-25-harness-independence-design.md`).

## Seams `bin/heimdall-route` consumes directly — not everyday commands

`base-url`, `token-file`, and `model` exist for `bin/heimdall-route` to call
in a command substitution when it launches a real child process — `status`,
`check`, and `arm` above are the operator-facing surface; these three are
documented here for completeness and for debugging a routed launch that
behaved unexpectedly.

- **`heimdall-fallback base-url`** — prints the OmniRoute base URL on stdout **only when the verdict is ROUTE**; on `REFUSE`, `WAIT`, or any internal error, stdout stays byte-empty and the reason goes to stderr only. `bin/heimdall-route` runs
  `url="$(heimdall-fallback base-url)"` and exports whatever comes back — a
  reason string or a traceback leaking onto stdout here would be exported as
  a base URL and silently point a live session at garbage, so this seam
  holds a stricter stdout contract than `check` itself.
- **`heimdall-fallback token-file`** — prints the **path** of the configured
  `gateway_token_file`, never its contents. It refuses — empty stdout, exit
  non-zero — a file that is unconfigured, missing, or **group/world-readable**
  (a bearer token must be `chmod 600`). `bin/heimdall-route` reads the path
  this prints, then reads that file itself, to populate
  `ANTHROPIC_AUTH_TOKEN` on the routed child; the token's contents never
  pass through this tool.
- **`heimdall-fallback model`** — prints the model id hmd pins on a routed
  child, or nothing. See "Automatic model pinning" above for the
  `fallback_model` field it reads and the safety rule it enforces.

None of the three are reachable through the `/hmd:fallback` slash command's
own argument parsing below (see Instructions) — they are a programmatic seam
`bin/heimdall-route` calls directly, not an operator-invoked subcommand.

## Other subcommands

- `heimdall-fallback set off` — disarm immediately; always safe.
- `heimdall-fallback status --json` — same fields, machine-readable.
- `heimdall-fallback base-url` / `token-file` / `model` — programmatic seams
  `bin/heimdall-route` consumes directly; see "Seams `bin/heimdall-route`
  consumes directly" above.

## Instructions

1. Parse `$ARGUMENTS`:
   - **Empty or `status`** → run `heimdall-fallback status`; if it shows
     `would preflight pass: no`, also run `heimdall-fallback check` and
     report the specific failing checks in plain language.
   - **`check`** → run `heimdall-fallback check`; report the verdict and
     every failing check's reason.
   - **`auto` / `switch`** → this arms real routing through a
     third-party provider. State that plainly, then run
     `heimdall-fallback arm --state <value>` — it self-provisions a
     target_provider (and operator_key_env, for a keyed one) and reports the
     resulting verdict in one step. Before relaying or saying anything
     else, check arm's own output for a line starting `REFUSED:` — arm
     always prints a full gateway/verdict block afterward regardless of
     whether it refused, so a buried REFUSED line reads, at a glance, like
     part of a successful run unless you check for it first.
     - **A `REFUSED:` line is present** → state was NOT changed. Say so
       plainly, first, before relaying anything else: state is still
       whatever it was, and why arm refused. Then relay arm's own output
       verbatim, then proactively offer the manual fallback — do not wait
       to be asked: run `heimdall-fallback set <value>` yourself to force
       it despite the refusal, then `heimdall-fallback check` to confirm.
     - **No `REFUSED:` line** → state changed. Say state is now `<value>`
       first, then relay arm's own output verbatim, including the
       `export ANTHROPIC_MODEL=` line if it prints one — that step
       genuinely cannot be automated.
     Never report "armed" without first checking for that `REFUSED:` line —
     relaying arm's output verbatim is not enough on its own, since a
     buried refusal reads like success unless you check for it before
     saying anything.
   - **`on`** → refuse: `on` was removed (owner directive) and no longer
     exists. Say so plainly and offer `auto` or `switch` instead — never
     silently substitute one.
   - **`arm`** → run `heimdall-fallback arm` (forward `--provider <p>` /
     `--state <s>` if the operator named either). Check its output for a
     `REFUSED:` line before relaying anything — if present, say plainly
     that state was left unchanged and why, first; if absent, say what
     changed, first. Then relay the rest verbatim either way.
   - **`off`** → run `heimdall-fallback set off`. Always safe, no
     confirmation needed.
   - **`where`** → run `heimdall-fallback where` and print the path.
   - Anything else → show the three-state table above and ask what they want.
2. Never fabricate a "would pass" verdict — always run `status`/`check`
   fresh and relay their real output.
3. Never invent a `target_provider` or `operator_key_env` value — if the
   operator wants to set one and hasn't said which, ask; don't guess a
   provider name.

## Examples

Dev: "why isn't fallback routing?"
→ `heimdall-fallback status`, then `check` if it's not passing → relay the
  named failing checks, not just "it's off."

Dev: "route to a third-party model once Claude capacity is nearly exhausted"
→ `heimdall-fallback arm --state auto`, relay its output verbatim (including
  the mandatory `export ANTHROPIC_MODEL=` line), then confirm with `check`.

Dev: "turn fallback off"
→ `heimdall-fallback set off`.
