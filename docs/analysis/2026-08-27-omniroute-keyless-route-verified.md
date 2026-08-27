# Verified keyless fallback route, and an OmniRoute connection-health defect

Date: 2026-08-27
Scope: completing the credential plane for `heimdall-fallback auto` on this machine.
Everything below was executed against a live OmniRoute 3.8.51 on `127.0.0.1:20128`
and is reproducible from the commands quoted.

## Outcome: `auto` is armed, all nine safety checks pass

```
heimdall-fallback check -- VERDICT: WAIT
  [OK] state                    [OK] prefer_claude_code_flag_off
  [OK] operator_key             [OK] no_delegated_sidecar
  [OK] endpoint_local           [OK] target_provider_allowed
  [OK] endpoint_reachable       [OK] anthropic_model_pinned
  [OK] tier1_credential_absent
  [INFO] session_usage -- tracking not configured
```

`WAIT` here is correct, not a failure. Under `state=auto` the gate routes only when
the session pre-exhaustion verdict is `crossed`; `unconfigured` is deliberately not
read as `under` or as `crossed` (fail-closed, test 43). The single remaining step is
an operator value nobody else can honestly supply — see "What is left" below.

## What was provisioned

- **Provider connection**: `opencode` / "OpenCode Free", `authType: no-auth`,
  id `cc65e288-…`, created via `POST /api/providers/free-onboarding`
  (`{"providerIds":["opencode"],"confirmed":true}`). Stores no API key
  (`hasKey=False`).
- **Gateway API key**: minted via `POST /api/keys`, scoped least-privilege to that
  one connection with `allowedConnections`, stored `0600` at
  `~/.omniroute/heimdall-fallback.key`. Never printed, never logged, never committed.
  Verified `cloudEnabled` is absent from settings (so `isCloudEnabled()` is false)
  BEFORE minting — that route fire-and-forgets an outbound cloud sync on key
  creation, which would otherwise have egressed the new key.
- **Tier-1 invariant re-verified after every write**: `SELECT COUNT(*) FROM
  provider_connections WHERE provider IN ('claude','claude-web')` → `0`.
  The only connection on the box is `opencode`.

## The working model, and honest limits on the rest

Model ids are namespaced by provider ALIAS (`oc/`), not provider id — but the gateway
accepts BOTH, verified: `opencode/big-pickle` and `oc/big-pickle` each return 200. So
`arm`'s printed guidance (`export ANTHROPIC_MODEL=opencode/<model-id>`) is correct as
written; an earlier suspicion that it was misleading was itself wrong and is recorded
here rather than quietly dropped.

Of the eight `opencode` models, exactly ONE serves keyless:

| model | result |
|---|---|
| `oc/big-pickle` | **200, works** — 3/3 consecutive calls, native tool-calling |
| `oc/muse-spark-1.2` | 402 — requires a paid opencode API key |
| the other six `-free` models | 401 once the connection was poisoned (see defect) |

Tool-calling is real, not merely advertised: a live request returned
`finish_reason: tool_calls` with a well-formed `get_weather({"city": "Paris"})` call.
This matters because `/v1/models` reports `tool_calling: true` from an OPTIMISTIC
heuristic for providers with no registry entry, so the advertised flag alone is not
evidence. Here it was confirmed by execution.

Note `big-pickle` is a reasoning model: at `max_tokens: 16` it returned
`content: None` (reasoning consumed the budget) while still returning 200. Small
`max_tokens` will look like an empty answer rather than an error.

## DEFECT FOUND: a per-model 402 poisons the whole connection

Probing `oc/muse-spark-1.2` (which needs a paid key) returned 402 and flipped the
CONNECTION-level health state to `testStatus: credits_exhausted`,
`lastErrorType: quota_exhausted`. Every other model on that connection then returned
`401 [opencode] All 1 connection(s) credits exhausted` — including `oc/big-pickle`,
which had returned 200 minutes earlier.

This is misclassification, not exhaustion. Proof: clearing the health fields through
the management API alone — no credits added, no reconnect, no upstream change —
restored service immediately.

```
PATCH /api/providers/<id> {"testStatus":"untested","lastError":null,
  "lastErrorAt":null,"lastErrorType":null,"errorCode":null,"isActive":true}
→ 200
POST /v1/chat/completions {"model":"oc/big-pickle",...} → 200 "FALLBACK_OK"
```

A per-model paywall (402) is being conflated with an account-level credit exhaustion.
**Operational consequence for heimdall**: one request to a paid model can take the
entire keyless fallback route offline until the flag is manually cleared, and the
error message actively misdirects — it says "credits exhausted, reconnect in the
dashboard" when there is nothing wrong with the credits.

An earlier reading of this session was that the free tier had simply been burned by
the 8-model probe. That reading was wrong, and the correction only came from testing
it. Recorded here because the wrong version is the intuitive one.

## Independent corroboration of the provider ranking

`GET /api/providers/free-onboarding` returns OmniRoute's own eligibility list: 8
providers — `aihorde`, `chipotle`, `cloudflare-playground`, `duckduckgo-web`,
`felo-web`, `opencode`, `theoldllm`, `uncloseai`. That is exactly the rank-0 set from
`bin/heimdall-fallback` plus `duckduckgo-web` (rank 1, emulated tools), and it
excludes precisely the four `isLocalCli` providers and the video-only one. The
ranking committed in `dfdb9b0` agrees with the gateway's own judgment, arrived at
independently.

## What is left — one operator value

`auto` cannot fire while `session_usage` is `unconfigured`, because `unconfigured`
never becomes `crossed`. It needs:

```
export HEIMDALL_SESSION_TOKEN_BUDGET=<tokens>
```

This is deliberately not defaulted. `heimdall-session-usage` cannot observe
Anthropic's real quota, so the budget is an operator declaration; inventing a number
would manufacture a percentage that gates real routing decisions. Current observed
consumption, for calibration: ~16.8M tokens / 149 requests over the last 18000s.
