# Relay hibernation: what hibernates, what pins the Durable Object, and how to measure it

Date 2026-10-05. Scope `relay/` (`SessionDO`). Evidence: `relay/test/hibernation.spec.ts`; the hmd client event logs of the two
sessions on this machine (`<repo>/.heimdall/app/relay-events.jsonl*`, 2026-09-26 to 2026-10-05); Cloudflare's *Pricing* and
*Lifecycle of a Durable Object* docs (both "last updated Sep 30, 2026", fetched 2026-10-05).

## TL;DR

- **The phone leg was already on the Hibernation API.** `ctx.acceptWebSocket(server, ["device"])` (`acceptDeviceSocket`),
  `webSocketMessage` / `webSocketClose` / `webSocketError`, per-socket state on `serializeAttachment`. There was nothing to move; the
  new suite proves it with simulated evictions and fails if that regresses.
- **The Durable Object duration bill is hmd's `GET /stream`.** An open response keeps the object resident, and with it the keepalive
  and stream-lifetime timers. Cloudflare bills 128 MB wall-clock for as long as that lasts: one always-on stream is
  0.125 GB x 86,400 s = **10,800 GB-s/day**, against a free cap of 13,000.
- **The 2026-10-04 cap is accounted for by two always-on streams.** hmd runs from two repos here (heimdall and hmdapp) against the same relay. Their logs put
  ~53,000 stream-open seconds each into 10-04 before the outage: 13,289 GB-s, crossing the cap at 18:04Z in the model and at
  18:17:12Z (first `1101`, hmdapp client) / 18:18:10Z (heimdall client) in reality.
- **This change does not move the bill by itself**, because the phone leg was never the cost. It fixes the two things the relay kept on the
  instance that a hibernation loses (a held `device_bound` for hmd, and the session id in early log lines), pins the hibernation properties
  with tests, and documents the residual and the two follow-ups that remove it (section 6).
- **Ack volume is an app bug, not relay load.** 5,193 of the 5,240 phone commands on 10-04 (99.1%) are `register_push`, repeated 1 to 3 times a
  second in 14 bursts. Each is a valid idempotent upsert and gets a valid ack. The relay cannot dedupe or batch sealed acks (INV-24), so the fix is
  the app's (section 4). Once the stream stops pinning the object, the whole loop adds at most ~240 GB-s on 10-04 (~90 on 10-03), not thousands.

## 1. What hibernates and what does not

| Piece | Survives an eviction? | Mechanism | Pinned by |
| --- | --- | --- | --- |
| Phone WebSocket | yes, stays `OPEN` | `ctx.acceptWebSocket` | "keeps the phone's socket open across an eviction" |
| `gen` (which socket is newest), `token_exp`, `sid` | yes | socket attachment | "ranks sockets by the generation...", "enforces the token expiry..." |
| Session record, last `state`, the held `device_bound` | yes | DO storage (the held frame moved here by this change) | "still delivers device_bound ... evicted between the claim and hmd connecting" |
| Purge alarm | yes | `setAlarm` | existing `hardening.spec.ts` |
| hmd `GET /stream` response, its controller | **no** | in-memory `ReadableStream` | n/a, it holds the object instead |
| Keepalive (20 s) and stream-lifetime (10 min) timers | exist only while a stream is open | `setTimeout` | "can be evicted straight after each kind of phone-leg request" |

With no stream open, a bound session can be evicted immediately after a claim, a reconnect, an hmd `POST /frames`, and a revoke (same test).

## 2. What pins the object

Cloudflare's rules (Lifecycle doc): an object hibernates only if no `setTimeout`/`setInterval` is pending, no I/O or `waitUntil` is
unfinished, the standard WebSocket API is not used, and no request is still being processed. It is billed while actively running **or
while idle but not hibernation-eligible**; idle and eligible is not billed, "even during the brief window before the runtime hibernates it".

hmd's stream breaks the fourth condition (an unfinished response) and the first (the timers that serve it). The suite reproduces it: with
a stream open, `evictDurableObject` stays pending; it completes only when the stream's own 8 s test deadline closes it, and then nothing
else is left holding the object. A leftover timer would hold it too (mutation M3: a constructor `setInterval` fails 9 of 11 tests).

`MAX_STREAM_LIFETIME_MS` (10 minutes) bounds a stream after a deploy orphans it. It does not help duration: hmd reconnects ~2 s later, far
inside the ~10 s idle window, so the object never hibernates between streams. It costs one reconnect per 10 minutes (144 a day per session;
the logs show 6 to 9 `stream_drop` an hour). The keepalive is not the cost either: it is a timer, but only ever armed while a stream already pins the object.

## 3. The 2026-10-04 cap, reproduced from the client logs

Each client logs `connect for=stream` and `stream_drop`; a stream's life on the relay side is bounded by the 10-minute lifetime, so each
interval is capped at 600 s. GB-s = open seconds x 0.125.

| UTC day | heimdall repo | hmdapp repo | both | free cap | outcome |
| --- | --- | --- | --- | --- | --- |
| 10-03 | 5,853 | 5,906 | 11,759 | 13,000 | under; no `1101` |
| 10-04, to 18:18Z | 6,633 | 6,656 | **13,289** | 13,000 | cap; first `1101` 18:17:12Z / 18:18:10Z |

The model crosses 13,000 at 18:04Z, 13 minutes before the first `1101`. Every 10-04 stream is under 620 s, so that day is tight. Where a log has
a long silent gap (a laptop asleep) the cap overstates the relay's side, which is why the same model also "crosses" on 10-02 (21:22Z) when no `1101` was seen:
treat these as upper bounds, tight on 10-04.

Cloudflare's free limits are per account and reset at 00:00 UTC; a second Worker with Durable Objects on the account would share them. On Workers Paid (400,000 GB-s/month included,
then $12.50 per million GB-s, usage rounded up to the next million) one always-on session is 324,000 GB-s/month and fits the allowance; two is
648,000, so the overage rounds up to $12.50 a month. Cheap, but linear in sessions.

## 4. Ack volume

Where acks come from: hmd acks **every** phone command (`_handle_command` in `bin/heimdall-relay-client`, INV-28) with a sealed `ack` envelope POSTed to
`/frames`. The relay's per-ack work is a bearer check, size/JSON/provenance gates, `liveDeviceSocket()` and one `ws.send`. No storage write (only `state` frames write).

What the logs say (heimdall-repo session):

| UTC day | commands | of which `register_push` | `app_state` | `resync` | `send-message` | ack retries |
| --- | --- | --- | --- | --- | --- | --- |
| 10-02 and before | 1 to 4 a day | 0 | 0 | 0 | 1 to 4 | 0 |
| 10-03 | 833 | 823 | 4 | 3 | 3 | 0 |
| 10-04 | 5,240 | **5,193 (99.1%)** | 23 | 22 | 2 | 9 of 5,249 |

The 5,193 arrive in 14 bursts of 20 s to 9 minutes (03:50 to 07:22Z), 0.9 to 3.2 a second, median gap 0.25 s. Every one is acked `ok:true` (the ack POST takes ~108 ms), so this is not
retry amplification; it is a phone-side registration loop. It first appears on 10-03, the date of the push-registration spec. hmd documents
`register_push` as an idempotent upsert, so each repeat is a no-op write and an ack. The hmdapp-repo session logged 22 commands over its whole history and no `register_push`.

Why the relay cannot cut it: acks are sealed per sequence number and the relay never sees an action. INV-24 requires exactly one phone message per posted ack
(`test/trace/mutants-ack-retry.spec.ts`, "not coalesced"), so batching or dropping duplicates would break the contract. A relay-side rate limit is rejected too: it cannot
tell a `decide` (a deny from the phone must never be dropped) from a `register_push`.

Recommended, not implemented (outside the relay and the E2E-neutral scope):

1. **App (primary):** register once per (token, `ref`, `events`) per bound session and on token change; stop on an `ok:true` ack; never re-register in response to an ack
   or a state frame. Expected: ~5,200 acks/day to ~50.
2. **Optional additive hint (needs app and hmd):** an ack for an unchanged `register_push` carries `"unchanged": true` and a `retry_after_s`. Clients that ignore unknown ack fields are unaffected.
3. **hmd:** skip the `push.json` rewrite when the upsert is identical (saves ~5,000 local disk writes a day; the ack is still sent).

As a duration driver, the storm is small once the stream stops pinning: counting every command, ack POST and state POST of the heimdall-repo session as a wake with a full 10 s window (an over-estimate, see section 2),
10-03 would be 1,628 GB-s with the loop and 1,540 without; 10-04 (to 18:18Z) 664 versus 422. The storm costs requests (~5,200 Worker and ~5,200 Durable Object requests a day, ~156,000 a month, inside the Paid allowance), not duration.

## 5. What this change does

- `src/session.ts`: the `device_bound` held for hmd moved from a field to storage (`PENDING_HMD_CONTROL_KEY`), flushed and deleted by `handleStream`. Before, an eviction between the phone's claim and hmd
  connecting dropped it, and hmd, which derives its session key from that frame alone, never completed the pairing (reproduced: "expected null not to be null"). `acceptDeviceSocket` writes it before accepting the socket, so a failed write cannot leave an accepted socket the phone never received.
- `src/session.ts`: the socket attachment carries `sid`, so a woken instance names the session in the log lines written before it has read the record (they logged `"unknown"`).
- `test/hibernation.spec.ts`: 11 tests, eviction-based. Two were RED first (the held frame, the session id); the other nine pin behaviour that was already correct. Mutation-checked: M2 (attachment never written) fails the
  generation and session-id tests, M3 (a constructor timer) fails 9/11, M4 (`server.accept()` instead of `acceptWebSocket`) fails 10/11; each was reverted.
- Verified: `npm test` in `relay/` (84 node tests, 121 vitest tests), `npm run typecheck`, `test/relay-contract-fixtures.test.sh` (9 passed).
- Deliberately unchanged: `webSocketClose` does not reply to the close (the compat date 2026-08-22 is past 2026-04-07, so the runtime does); no ping/pong auto-response (the app sends no application
  ping, so there is nothing to answer; if it adds one, `setWebSocketAutoResponse(new WebSocketRequestResponsePair("ping", "pong"))` answers it without waking the object, and protocol-level pings already do).

## 6. Follow-ups that would remove the residual (not in this change)

Both end with the object able to hibernate between events. Cloudflare bills only handler run time then: ~3,500 events a day at an assumed ~20 ms is ~70 s, order **10 GB-s/day**; even if every
wake cost a full 10 s window, both sessions on 10-04 (to 18:18Z) come to at most 1,481 GB-s against 13,289.

**A. hmd leg over a hibernatable WebSocket** (the end state). `GET /stream` with `Upgrade: websocket`. The DO side is inside `SessionDO` only: the router already forwards the request, header included, to the object.
Tag `hmd`; one live socket, newest wins (close the older with 4002); control frames as text messages; flush the stored `device_bound` on accept (this change's buffer); no keepalive timer (hmd sends `ping`; `setWebSocketAutoResponse` answers `pong`
without waking the object); no lifetime rotation, because hibernatable sockets are re-delivered to a new generation after a deploy, which also removes the 2026-09-25 orphaned-stream failure.
Needs an RFC 6455 client in `bin/heimdall-relay-client` (stdlib has none), a `stream_ws` section in `relay/contract/wire.json` so `test/relay-contract-fixtures.test.sh` covers it, and NDJSON kept for old clients. Optional phase
2: hmd POSTs over the socket (an incoming message bills at 1/20 of a request).

**B. A Worker-held stream** (no client change). The Worker serves `GET /stream`, keeps the NDJSON response and its keepalives (Worker CPU time, not GB-s), and bridges to the object over a hibernatable WebSocket opened with
`stub.fetch` + `Upgrade`. Needs a router change in `src/worker.ts`, deferred here because another change is editing the router. Not validated against the platform: the open questions are Worker behaviour on a long streamed response and on deploys.

Pick B if hmd cannot ship a release soon, A as the destination. Meanwhile, running one hmd session instead of two halves the stream cost with no code change.

## 7. Duration probe: how to measure before and after

Take the baseline before any follow-up deploys; repeat with the same sessions after. Use whole UTC days (the free allowance resets at 00:00 UTC).

1. **Dashboard.** Cloudflare dashboard, *Durable Objects*: the account-level usage view (against the plan allowance) and, on the `SessionDO` namespace, the *Metrics* tab with a time window; filter to one object by id or name.
2. **GraphQL Analytics API** (needs an API token with Account Analytics read; datasets per Cloudflare's docs: `durableObjectsPeriodicGroups`, `durableObjectsInvocationsAdaptiveGroups`, `durableObjectsStorageGroups`, `durableObjectsSubrequestsAdaptiveGroups`).
   Field names are only partly documented, so introspect first. This lists every field on the periodic dataset; look for the duration (GB-s) and active-time names and the WebSocket counts:

   ```sh
   curl -sS https://api.cloudflare.com/client/v4/graphql \
     -H "Authorization: Bearer $CF_API_TOKEN" -H "Content-Type: application/json" \
     --data '{"query":"{ __schema { types { name fields { name } } } }"}' |
     jq -r '.data.__schema.types[] | select(.name | test("DurableObjectsPeriodicGroups")) | .name as $t | (.fields // [])[] | "\($t)\t\(.name)"'
   ```

   Then per day (replace `DURATION_FIELD` with what introspection printed; `cpuTime` and `requests` are the fields Cloudflare's own example uses, and if the API rejects an argument or dimension, adjust it from the same introspection):

   ```graphql
   query RelayDo($account: String!, $from: Date!, $to: Date!) {
     viewer {
       accounts(filter: { accountTag: $account }) {
         durableObjectsPeriodicGroups(limit: 100, filter: { date_geq: $from, date_leq: $to }, orderBy: [date_ASC]) {
           dimensions { date }
           sum { cpuTime DURATION_FIELD }
         }
         durableObjectsInvocationsAdaptiveGroups(limit: 100, filter: { date_geq: $from, date_leq: $to }, orderBy: [date_ASC]) {
           dimensions { date }
           sum { requests }
         }
       }
     }
   }
   ```

3. **`wrangler tail`** shows behaviour, not duration. The relay logs one JSON line per event (never a URL or token); count them:

   ```sh
   npx wrangler tail hmd-relay --format json \
     | jq -rc '.logs[]?.message[]? | fromjson? | select(.event) | [.event, .session_id] | @tsv'
   ```

   Before: a `stream_lifetime_expired` roughly every 10 minutes per attached hmd. After follow-up A: none. `session_id` is a correlation handle; keep the output out of public places.
4. **Client side, no credentials.** hmd's own log gives the stream-open time per day (an upper bound where the machine slept; repeat per repo that runs hmd). On the logs behind section 3 it prints exactly that table
   (10-04: 6,633 and 6,656 GB-s):

   ```python
   import collections, datetime, json, sys

   def when(e):
       return datetime.datetime.strptime(e["ts"], "%Y-%m-%dT%H:%M:%S.%fZ")

   per_day, open_stream = collections.defaultdict(float), {"since": None}

   def close_stream(at):
       since = open_stream["since"]
       if since is not None:  # the relay ends any stream at 10 minutes, whatever this log says
           per_day[since.strftime("%Y-%m-%d")] += min((at - since).total_seconds(), 600)
       open_stream["since"] = None

   for path in sys.argv[1:]:  # oldest first: relay-events.jsonl.1 relay-events.jsonl
       for line in open(path, errors="replace"):
           try:
               e = json.loads(line)
           except ValueError:
               continue
           kind = e.get("event")
           if kind == "connect" and e.get("for") == "stream":
               close_stream(when(e))
               open_stream["since"] = when(e)
           elif kind in ("stream_drop", "session_ended", "pair_init"):
               close_stream(when(e))
           elif kind == "error" and str(e.get("detail", "")).startswith("stream open HTTP"):
               open_stream["since"] = None  # never opened
   for day, secs in sorted(per_day.items()):
       print(f"{day}  open={secs:8.0f}s  {100 * secs / 86400:5.1f}%  ~{secs * 0.125:7.0f} GB-s")
   ```

5. **Deterministic, in CI.** `cd relay && npx vitest run test/hibernation.spec.ts` proves the property, not the bill: the object is evictable after every phone-leg request, held while a stream is open, freed when it closes.

Acceptance:

- **This change:** no change in GB-s is expected (the phone leg already hibernated). It passes if the suite is green and the baseline is recorded.
- **Follow-up A or B:** per-day GB-s for each session falls from the 5,800 to 10,800 range seen here (54% to 100% stream duty) to under ~500; the active WebSocket connection count (find its field by introspection) stays at least 1
  while a phone is connected, since sockets survive hibernation; `stream_lifetime_expired` stops appearing in the tail (A); phone-to-hmd round trips are unchanged.

## 8. PR description snippet

> **relay: pin hibernation, fix state lost across eviction.** The phone leg already ran on the Hibernation API; this adds `test/hibernation.spec.ts` (11 eviction-based tests, mutation-checked) and fixes two pieces of instance
> state that did not survive eviction: the `device_bound` held for hmd (now in storage) and the session id in early log lines (now on the socket attachment). It does not change Durable Object duration: that is hmd's open `GET /stream`,
> and two always-on streams account for the 2026-10-04 free-cap trip (13,289 GB-s modelled vs the observed 18:17Z). Removing it needs the hmd leg on a hibernatable WebSocket or a Worker-held stream
> (`docs/analysis/2026-10-05-relay-hibernation.md`, section 6). The ack volume (~5,200/day) is a phone-side `register_push` loop (99.1% of commands), not relay load. Duration probe: section 7 of the same note.
