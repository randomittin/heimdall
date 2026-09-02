# OmniRoute live verification — this machine, pre-release

**Date:** 2026-09-02 · **Machine:** rishabhs-macbook-air · **Verdict: PASS**

Run against the real local install, not fixtures. Every figure below is a
captured command result.

## 1. Gateway health

| check | result |
|---|---|
| launchd service | `pid=2063 exit=0` |
| `GET /` | `307` in `0.012s` |
| `GET /v1/models` (authenticated) | `200` |
| models served | `auto/best-coding`, `auto/best-reasoning`, `auto/best-fast`, `auto/best-vision`, `auto/best-chat`, `auto/best-coding-fast` |

## 2. Real routed generation — the end-to-end test

A genuine `claude -p` subprocess through the routing seam
(`bin/lib/hmd-route-claude`) with the gate forced to ROUTE:

```
forced gate:          VERDICT: ROUTE
generation endpoint:  http://127.0.0.1:20128
prompt:               "Reply with exactly: OMNI_OK"
stdout:               OMNI_OK
rc:                   0
pinned model:         oc/big-pickle (hmd fallback model)
context window:       200000 (read from the gateway's own /v1/models)
```

Not a health probe — a real model call, correct answer, exit 0.

## 3. Safety properties (these matter more than the happy path)

**Judgment never routes.** With the gate forced ROUTE, `HMD_JUDGMENT=1`:
```
reply:            JUDGMENT_OK
endpoint:         https://api.anthropic.com
routed to omni?   NO
```
Verifier/reviewer/security-auditor work cannot land on a degraded model —
the "confident false green" failure mode stays closed.

**Tier-1 credential isolation holds.** `~/.omniroute/storage.sqlite`:
```
select provider, count(*) from provider_connections group by provider;
  opencode|1
```
Exactly one connection, and it is NOT Claude/Anthropic. No Anthropic
credential is inside omni — the owner's standing constraint that keys never
reach omni is satisfied at the data layer, not merely by policy.

## 4. Reactive 429 trigger — the path that had never fired

Sandboxed `HEIMDALL_HOME`, a 429 record in a sibling task transcript, parent
transcript carrying only prose (the real production shape):
```
before:  VERDICT: WAIT
detect:  marker WRITTEN
after:   VERDICT: ROUTE
```
The full chain now works. This is what four consecutive "omni didn't
trigger" reports were about: `SubagentStop` does not fire on a 429 death
(measured: zero subagentstop rows at any of three real 429s), so the
detector only became reachable once it also scanned sibling task
transcripts from the orchestrator's `Stop` hook (`dcc9225`).

## 5. What is still NOT proven

**A real, unsimulated 429 has not occurred since `dcc9225` landed.** Every
result above uses a real 429 *record* replayed through the real code path —
which proves parse, match, marker and gate promotion — but not that the
harness invokes the `Stop` hook at the moment of a live rate-limit death.
That single fact remains inference, and it is the last gap. Given the rate
these have been arriving, the next one will settle it, and the answer will
be visible in `~/.heimdall/429-marker.json` rather than reasoned about.

Do not read this document as "omni auto-shift is proven in production". It
says: the mechanism is correct, wired, and live-tested on every layer this
machine can exercise without waiting for a rate limit.
