# OmniRoute as a backup route when Claude Code credits run out

Date: 2026-11-22. Read-only research. No config, launchd job or process was changed. No secret printed.
Smoke traffic used only the dedicated fallback gateway key (`~/.omniroute/heimdall-fallback.key`, 0600).

## Verdict

NOT USABLE TODAY; WORKS WITH STEPS. The wiring is complete and armed (`state=auto`). Both providers behind it are
exhausted right now, and the config has drifted. Fix the providers, then it works as a degraded (non-Claude) route.

## 1. What is installed and running

| Item | Evidence |
|---|---|
| Install | `/Users/rj/omniroute` (npm app, not a git checkout), `package.json` version 3.8.51 |
| Listener | node pid 4793 on 127.0.0.1:20128 (API), :20131, :20132; loopback only |
| launchd | `launchctl list`: `dev.runheimdall.omniroute` pid 2477, last exit 0; plist `RunAtLoad`+`KeepAlive`, `HOST=127.0.0.1`, `DATA_DIR=/Users/rj/.omniroute` |
| Health | `GET /api/health` 200 `{"status":"ok"}`; `GET /v1/models` without a key 401 (auth enforced) |
| Headroom | python pid 7169 on 127.0.0.1:8787, `headroom proxy --lossless`, `/health` healthy v0.35.0 |
| Wiring | `~/.zshrc` `claude()` -> `hmd route claude`; `~/.claude/settings.json` env is `{}` (no base URL) |

Providers (read from `~/.omniroute/storage.sqlite` read-only, non-secret columns only):

- `opencode` / "OpenCode Free", `no-auth`, active, `last_error_type=forbidden`.
- `dahl` / "Dahl Manual", `apikey`, active. 1944 calls logged as 200, then 10x 401, 9x 504, 1x 402.
- No `claude` or `claude-web` row: the Tier-1 (subscription reuse) boundary holds by credential absence.
- `combos` table is empty. `/v1/models` lists virtual `auto/*` combos only.
- Management API (`/api/providers`, `/api/combos`) answers 403 to the gateway key. Expected: it is scoped to inference.

Heimdall fallback config (`/Users/rj/Downloads/heimdall/.heimdall/fallback.json`):

- `state=auto`, `endpoint=http://127.0.0.1:20128`, `gateway_token_file` set, `operator_key_env` empty.
- `fallback_model=dahl/MiniMaxAI/MiniMax-M2.7`.
- `target_provider=aihorde`, which has NO connection row in OmniRoute. Drift: the model points at `dahl`, the target at `aihorde`.
- `heimdall-fallback check`: all 10 preflight items OK; verdict WAIT only because session_usage is "under" threshold.
- `hmd route --url` prints `http://127.0.0.1:8787` today (Headroom), i.e. the gate does not currently route to OmniRoute.

## 2. What happens when CC credits run out; can a fallback trigger

CC's own stop text is the subscription session/usage limit: "You've hit your session limit · resets 5:40pm (TZ)"
(shape matched by `bin/lib/quota_stop.py`; five production incidents 2026-08-24 to 2026-09-05 per
`docs/analysis/2026-08-29-fallback-did-not-fire-rootcause.md`). It is shown by CC itself; nothing downstream can
intercept and re-send that request. Hence "react to the 429" never saves the failed request.

Trigger paths that exist:

1. `state=auto`: the NEXT `claude` launch routes to OmniRoute only when `heimdall-session-usage` says `crossed`. That
   signal is a statusline snapshot (`~/.heimdall/rate-limits.json`): it lags and it missed three real exhaustions
   (root-cause doc). A running session can never be re-routed (no way to mutate a live process env).
2. `state=switch`: routes at launch whenever the preflight passes, no usage condition (`bin/heimdall-fallback`
   `is_switch`; `bin/heimdall-route:373` prints the refusal when preflight fails). This is the deterministic option.
3. Manual one-shot (section 4).

OmniRoute capability (cited, not recalled):

- Serves Anthropic Messages (`POST /v1/messages`) and OpenAI formats; project README lists them. Confirmed live here:
  `/v1/messages` returns Anthropic-shaped errors (`{"error":{"type":"billing_error",...}}`).
- Fallback on 429: combos with strategies (priority, round-robin, fill-first, ...). Per the maintainer, with 2+
  connections to a provider, a 429 on one puts it on cooldown and the next serves; with ONE connection the error is
  returned to the client. Source: https://github.com/diegosouzapw/OmniRoute/discussions/11127 (repo now
  https://github.com/cheaper-inference/OmniRoute).
- It cannot fall back FROM the CC subscription: the subscription limit is enforced by Anthropic against the OAuth login
  on the direct path. OmniRoute only ever sees traffic you point at it.

Auth and model implications:

- Anthropic: setting only `ANTHROPIC_BASE_URL` keeps the saved claude.ai login as the credential (its limits and
  billing still apply, and gateways must forward Authorization + anthropic-beta); a gateway credential variable
  (`ANTHROPIC_AUTH_TOKEN`/`ANTHROPIC_API_KEY`) replaces the subscription for those requests and bills the key owner.
  Source: https://code.claude.com/docs/en/llm-gateway ("Subscriptions and gateways").
- Same page: Anthropic "doesn't support routing Claude Code to non-Claude models through any gateway". The fallback
  models here (MiniMax-M2.7, big-pickle) are non-Claude: tool use, thinking blocks and context behavior may differ.
  `heimdall-fallback` already pins the model and only ever routes generation roles, never judgment roles.
- A subscription token cannot and must not be forwarded to a third provider; the Tier-1 gate refuses it by design.
- A Claude-quality fallback needs an Anthropic Console API key (pay per token). Pointing CC straight at
  api.anthropic.com with `ANTHROPIC_API_KEY` needs no OmniRoute. Adding it as an OmniRoute `anthropic` apikey
  connection: not tested; whether heimdall's `target_provider_allowed` list admits it is UNVERIFIED.

## 3. Chain with Headroom; how hmd treats it

- Chain `claude -> headroom -> omni` is deliberately NOT supported. `bin/lib/hmd-headroom-chain.sh` pins
  `HMD_HEADROOM_UPSTREAM=https://api.anthropic.com` and refuses a proxy whose reported upstream differs; the
  `bin/heimdall-route` comment (lines 143-160) states the gate WINS over Headroom: on ROUTE, `ANTHROPIC_BASE_URL` is the
  OmniRoute URL and compression is OFF for that session (weak model + compressed prompt = worst case). Whether
  Headroom 0.35 can take a custom upstream: not checked, because the design rejects it anyway.
- Direct `claude -> omni` is the supported shape: `bin/heimdall-route` (fallback branch) probes `:20128/` (<=1s),
  REFUSES to launch (exit 3) if the gateway is down rather than silently going direct, exports `ANTHROPIC_AUTH_TOKEN`
  from the 0600 key file into that one child, pins `ANTHROPIC_MODEL`, and sets `CLAUDE_CODE_MAX_CONTEXT_TOKENS` from
  the gateway's `/v1/models`.
- `lean_route_guard.sh` (verified by running it): `ANTHROPIC_BASE_URL=127.0.0.1:20128` -> `ok ... left alone, local
  proxies that are not Headroom's`; `...:8787` -> `defer` (exit 10). So `install.sh --reset` / `hmd headroom off
  --next-session` never touch a session routed to OmniRoute, and never stop OmniRoute (separate launchd job).
- `hmd fallback` is NOT a subcommand of the current `hmd` (`unknown command: fallback`); the CLI is
  `bin/heimdall-fallback` (on PATH). `bin/heimdall-route` still mentions `hmd fallback` in an error string: stale text.

## 4. Smoke tests run (no global config changed)

Gateway key sent as Bearer; `POST http://127.0.0.1:20128/v1/messages`, `max_tokens` 200-300, one word prompt:

| Model | Result |
|---|---|
| `dahl/MiniMaxAI/MiniMax-M2.7` | HTTP 402 `[402]: available tokens exhausted` (type `billing_error`) |
| `oc/big-pickle` | HTTP 429 `Free usage limit reached ... (reset after 3s)` (call_logs: 4x `opencode` 429, 2x `opencode-zen` 429) |
| `claude-haiku-4-5` | curl timed out at 20s (HTTP 000); cause not investigated. Expected: no Claude connection exists |

The inline `ANTHROPIC_BASE_URL=... claude -p` run was SKIPPED: both providers are exhausted, so it could only reproduce
the 402/429 above while spending a CC turn. Protocol plumbing is proven by the Anthropic-shaped errors; end-to-end
tool-use through CC is therefore unproven on the current providers.

## 5. Steps to make it a real backup

1. Fund or replace the provider: top up `dahl`, or add a second connection via the OmniRoute dashboard
   (http://127.0.0.1:20128, management password in `~/.omniroute/management-password.txt`; do not paste it anywhere).
   A single connection has nothing to fail over to (maintainer, link above); two give 429 fallback inside a combo.
2. Fix the drift: `target_provider` must name a provider that has an active connection (`dahl`), matching
   `fallback_model`; then `bin/heimdall-fallback arm`, then `bin/heimdall-fallback check`.
3. Re-clear `opencode` health if you rely on it: its connection shows `forbidden`; a per-model 402 can poison the whole
   connection (defect recorded in `docs/analysis/2026-08-27-omniroute-keyless-route-verified.md`).
4. Pick the trigger: keep `auto` (lagging, can miss) or `bin/heimdall-fallback set switch` (route on every launch while
   armed; use only while capacity is gone, then `set auto`/`set off`).
5. Ad-hoc, no state change, bypass the zshrc function with `command`:
   `ANTHROPIC_BASE_URL=http://127.0.0.1:20128 ANTHROPIC_AUTH_TOKEN="$(cat ~/.omniroute/heimdall-fallback.key)" ANTHROPIC_MODEL=<provider/model> command claude`
   Base URL has no `/v1` suffix. Start a NEW session; a live one cannot be re-routed.

## 6. Risks

- Non-Claude model on CC: tool-call/thinking mismatches, weaker output; unsupported by Anthropic (link above).
- Free providers rate-limit in minutes (observed 429 on `big-pickle` today); paid one is out of tokens (402).
- Data egress: prompts and repo context go to a third-party provider (MiniMax via Dahl, OpenCode). Operator opt-in
  only (`state` is explicit); never for judgment roles (`hmd_is_adjudication`).
- Subscription tokens stay on the direct path; with only `ANTHROPIC_BASE_URL` set (no auth token) CC would send the
  OAuth login to OmniRoute: always set the gateway token, as `heimdall-route` does.
- `auto` depends on a lagging statusline snapshot: it can fail to arm exactly when credits end.
- Config drift (`aihorde` target without a connection) means a green `check` today does not imply a working route.

## Sources

- https://code.claude.com/docs/en/llm-gateway (fetched 2026-11-22)
- https://code.claude.com/docs/en/llm-gateway-protocol.md (fetched; headers to forward, not quoted above)
- https://github.com/diegosouzapw/OmniRoute/discussions/11127 (maintainer on 429 fallback and cooldown)
- Local: `bin/heimdall-fallback`, `bin/heimdall-route`, `bin/lib/lean_route_guard.sh`, `bin/lib/hmd-headroom-chain.sh`,
  `docs/analysis/2026-08-27-omniroute-keyless-route-verified.md`, `docs/analysis/2026-08-29-fallback-did-not-fire-rootcause.md`
