# runhmd receipts (hosted service)

The hosted half of RP3: a Cloudflare Worker with two Durable Object classes that stores signed
`runhmd.receipt/1` receipts and serves them. The receipt itself (schema, canonical form, signature,
`hmd receipt verify`) is `docs/RECEIPTS.md` and `bin/lib/runhmd_receipt.py`; this directory is the
service around it. It is a self-contained package (own `package.json`, `wrangler.toml`, vitest
config), laid out like `relay/`, and nothing else in the repo imports it.

## Endpoints

| Route | Auth | Answer |
|---|---|---|
| `POST /api/receipts` | bearer token | `201 {ok,id,url,visibility,created:true}`; `200 ... created:false` for the identical bytes again; `409 id_conflict` for a different receipt under a stored id; `400 not_json`; `422 invalid_receipt` with `kind` = `schema`, `not_canonical`, `unknown_key`, `bad_signature`; `413` over 1 MiB; `415` unless `application/json`; `401`; `429`; `503` when unconfigured |
| `GET /r/<id>` | none (public) | the receipt page (HTML, own CSP, no script, OG tags) |
| `GET /r/<id>.json` | none (public) | the exact signed bytes: `hmd receipt verify` accepts them, a one-byte edit fails |
| `GET /r/<id>/card.png` | none (public) | the 1200x630 card, `image/png` (the Open Graph image) |
| `POST /r/<id>/f/<finding_id>/rate` | bearer token | body `{"label":"real"\|"false","source":"cli"\|"pr"\|"mobile"?}` -> `{ok,receipt_id,finding_id,label,human_label}` (`real` is `true_positive`, `false` is `false_positive`) |
| `GET /health` | none | `{ok,version}`, answered without a Durable Object |

`HEAD` works on every GET route. A private receipt (the signed `visibility` field) is a plain 404 on
all three read routes, byte for byte the answer for an id that does not exist, unless the request
carries a valid bearer token; no flag serves one anonymously.

## What is accepted, what is served

- **Accepted:** only a receipt whose Ed25519 signature verifies against the pinned public key(s) in
  `RECEIPT_PUBKEYS`, under exactly the rules of `bin/lib/runhmd_receipt.py` (`verify_bytes`): valid
  JSON, the receipt schema and its invariants (RC1-RC3, V1-V4, G1), the file is the canonical form
  plus at most one LF, a trusted `key_id`, canonical base64 signature, signature over
  `runhmd.receipt/1` LF + canonical(receipt without `signature`). The key is never taken from the
  receipt. Unsigned, mis-signed, non-canonical and over-size uploads are refused.
- **Immutable:** the first receipt filed under an id is the only one it ever holds (a Durable Object
  per id, single-threaded, `INSERT` into a one-row table).
- **Re-verified on every read**, so removing a key from `RECEIPT_PUBKEYS` withdraws what it signed
  (500 `receipt failed verification`, content never echoed).
- **No counterexample text anywhere:** a receipt holds digests only (the schema forbids more), so
  `minimal_input` can appear in no page, card or `.json`; the tests assert it.
- **Ratings are the service's, not the receipt's:** a signed document cannot change, so a rating is
  stored beside it (last write wins) and shown as the finding's *Label* on the page.
- **The CTA:** the page shows a "Request cloud access for this team" link only when some finding is
  rated `real` (`human_label == true_positive`), and withdraws it when the label flips. It links to
  `CTA_URL?receipt=<id>`; what answers there (recording the request, the cohort cap) is RP12's. With
  no `CTA_URL` configured there is no link.

## Limits and throttle

Upload cap 1 MiB (`MAX_RECEIPT_BYTES`, the same constant as the Python verifier; the declared length
is not trusted, the stream is counted); rating cap 1 KiB. Write attempts (upload and rate, failed ones
included) are throttled to 30 per 60 s per `CF-Connecting-IP` in a `ThrottleDO` (the relay's
`/pair/init` pattern; an absent header, as in `wrangler dev`, shares one `unknown` bucket, fail
closed). GET routes are not throttled here: an id that was never stored costs a Durable Object
instantiation and no storage, the same accepted cost the relay documents, and per-IP read limits belong
in a Cloudflare rate-limiting rule on the zone.

## Configuration (all provisioned at deploy, none committed)

| Name | Kind | Meaning |
|---|---|---|
| `RECEIPT_PUBKEYS` | secret | the receipt PUBLIC key(s): content of `release/runhmd-receipt.pub` (one base64 32-byte key per line, `#` comments ok, several while rotating) |
| `API_TOKEN_SHA256S` | secret | SHA-256 hex digests (whitespace or comma separated) of the bearer tokens allowed to upload, rate and read private receipts |
| `PUBLIC_BASE_URL` | var | https base URL the pages, OG tags and upload answers link to (default `https://runhmd.dev`) |
| `CTA_URL` | var | https URL of the "Request cloud access" link |
| `BUILD_ID` | var | commit sha shown by `/health` (`wrangler deploy --var BUILD_ID:<sha>`) |

Fail closed: no tokens, no public key, or a malformed list of either means the write routes answer
`503 disabled` (and reads of stored receipts 503), never open access.

## Deploy (operator steps; nothing here has been run)

1. `hmd receipt keygen` once; keep the secret file out of the tree; commit the public file as
   `release/runhmd-receipt.pub`. (`docs/RECEIPTS.md`: this is NOT the minisign release key.)
2. In the Cloudflare account: `cd receipts-worker && npx wrangler login`.
3. `npx wrangler secret put RECEIPT_PUBKEYS` (paste the public key line(s)).
4. Mint a token, store only its digest, hand the token to the uploader:
   `t=$(openssl rand -hex 32); printf %s "$t" | shasum -a 256 | cut -d' ' -f1 | npx wrangler secret put API_TOKEN_SHA256S`
   (append further digests, space separated, for more tokens; keep `$t` where `hmd` will read it).
5. Durable Objects need the Workers Paid plan. `npx wrangler deploy`; the v1 migration creates both
   classes. Production signing-key custody (who holds the secret that signs the receipts uploaded
   here) is the operator's decision.
6. Point the zone at it: add `routes = [{ pattern = "runhmd.dev/*", zone_name = "runhmd.dev" }]` to
   `wrangler.toml` once `runhmd.dev` is on the account (it has no DNS yet).
7. Check: `curl -fsS https://runhmd.dev/health`, then upload a receipt and
   `curl -fsS https://runhmd.dev/r/<id>.json | jq -e '.schema=="runhmd.receipt/1"'`,
   `curl -fsS https://runhmd.dev/r/<id>/card.png -o /dev/null -w '%{content_type}'`.

## Test

```
cd receipts-worker
npm ci
npm test            # schema-copy check, then vitest in a real workerd (no account, no network)
npm run typecheck
```

Every credential in the suite is generated per run (`vitest.config.ts`) or per test and exists only
in memory: the Worker gets a fresh public key and the SHA-256 of a fresh token, the suite the matching
seed and token through `TEST_*` bindings no real environment has. `tsconfig.json` is deliberately not
here (the repo's lint-config guard refuses a new one); `npm run typecheck` passes the same strict
options on the command line.

## One contract, two languages

`src/canonical.ts`, `src/schema.ts` and `src/receipt.ts` are ports of `canonical()`,
`bin/lib/runhmd_schema.py` and `verify_bytes()`. They are held to the Python by
`contract/vectors.json`, written from the Python reference by `scripts/gen-vectors.py` (133 canonical
cases, 65 receipt files covering every outcome):

- `test/vectors.spec.ts` replays it against the JavaScript: identical canonical bytes (or identical
  refusal) and identical outcome (`ok` or the `ReceiptError` kind) for every vector.
- `test/receipts-worker-contract.test.sh` (repo root) replays it against the Python, regenerates it,
  checks the schema copies, and runs the real `hmd receipt verify` on the same bytes.

The generator makes a fresh key per run and writes only the public anchor and the signed bytes, never
a seed, so regenerating replaces the whole set. `schema/` holds byte-identical copies of
`docs/schemas/runhmd.{receipt,verdict}.v1.json` (the single source), kept in step by
`npm run sync-schemas` and checked by `npm test` and by the repo suite.

The card is drawn without a dependency: an 8-bit palette PNG, a 5x7 bitmap font designed for this
project (upper case; lower case folds up, unknown characters draw `?`), zlib through
`CompressionStream`. It is built only from the verified receipt's fields.
