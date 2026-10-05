# runhmd receipts (RP3)

A receipt is the signed, shareable record that one verification happened and what it concluded:
`runhmd attacked THIS (a content hash) and concluded THAT (the verdict, each finding as a digest),
with THIS tool version, at THIS time`. The contract is `docs/schemas/runhmd.receipt.v1.json` (the
single source; `bin/lib/runhmd_schema.py` enforces it). The code is `bin/lib/runhmd_receipt.py`
(issue, verify, keys, store), `bin/lib/runhmd_receipt_site.py` (the pages) and `hmd receipt`.

## What is in one, and what never is

In: `id` (the verdict's id), `created_at`, `visibility`, `verdict`, `subject` (`kind`, git
`head_sha`, `tree_sha256` of what was attacked), `attacks`, `findings` (`id`, `title`, `severity`,
`category`, `digest`), optional `gates` / `regression_tests`, `agent`, `cost_usd`, `duration_s`,
`tool` (`hmd` + version), `verdict_sha256`, `key_id`, `signature`.

Never in: file contents, any path, counterexample text, repro commands, any secret. A finding
carries `digest` = sha256 of its canonical JSON in the verdict, so the receipt commits to a
counterexample it does not publish (`minimal_input` can therefore never leak from a receipt).
`verdict_sha256` is the sha256 of the canonical verdict with `receipt_url` set to null.

## Signing, and which key

Ed25519 over `runhmd.receipt/1` LF + the canonical JSON of the receipt without `signature`
(canonical form: see the schema description), through the shipped `cp_auth` backend
(`cryptography` or `PyNaCl`; neither installed means issue and verify fail closed, there is no
weaker scheme). A receipt FILE is the canonical form of the whole document plus one LF, and the
verifier accepts only those bytes: changing any field, or any single byte, fails.

**The key is not the release key.** RP3 says `key = heimdall-signing key`. `release/heimdall-signing.pub`
is the minisign key that signs the auto-update channel and must stay offline; a receipt service
needs its key online, and a leaked receipt key must forge receipts at worst, never ship code. So
receipts use their own Ed25519 key:

- secret: `$RUNHMD_RECEIPT_KEY_FILE`, else `$HEIMDALL_HOME/signing/runhmd-receipt.key` (base64
  32-byte seed, mode 0600; a file other users can read is refused). Never in an environment variable.
- `hmd receipt keygen [--dir DIR]` writes the pair and never overwrites a key.
- operator, once: run `hmd receipt keygen`, commit the public file as `release/runhmd-receipt.pub`
  (trust anchor shipped with hmd), keep the secret out of the tree.
- trust, never taken from the receipt: `--pubkey FILE`, else `$RUNHMD_RECEIPT_PUBKEY_FILE`, else
  `release/runhmd-receipt.pub` plus `$HEIMDALL_HOME/signing/runhmd-receipt.pub`. One base64 key per
  line, `#` comments allowed, several lines while rotating. No trust anchor is exit 2, never a pass.

## Verify

`hmd receipt verify <file|id> [--pubkey FILE] [--store DIR] [--json]`: exit 0 valid, 1 invalid
(`bad_signature`, `unknown_key`, `not_canonical`, `schema`, `not_json`, `id_mismatch`), 2 usage or
configuration (`no_trust`, `not_found`, `bad_trust`, `bad_id`). An id is looked up in
`$RUNHMD_RECEIPT_DIR` (default `$HEIMDALL_HOME/runhmd/receipts`) and must be the id the receipt carries.

## `/r/<id>` and `/r/<id>.json`

`hmd receipt render --out DIR` writes `DIR/r/<id>.json` (the exact signed bytes) and
`DIR/r/<id>.html` for every PUBLIC receipt that verifies; a private one is never written and a
failing one is reported (exit 1) and never written. Publish `DIR` on any static host that maps
`/r/<id>` to `r/<id>.html` (Netlify, Cloudflare Pages). `hmd receipt serve [--port N]` serves the
same responses on 127.0.0.1 only, for testing. The HTML escapes every dynamic value, has no script,
no external resource and no form, and carries its own CSP.

`runhmd.dev` has no DNS yet (operator-only), so receipt URLs do not resolve until the operator
points it at a host serving that tree. NOT built: `POST /api/receipts`, `GET /r/<id>/card.png`,
`POST /r/<id>/f/<fid>/rate`, the "request cloud access" CTA. They need storage, auth and a deploy.

## `hmd attack --receipt`

Issues a receipt per verdict, stores it as `<id>.json`, and sets `receipt_url` to
`https://runhmd.dev/r/<id>` (`RUNHMD_RECEIPT_BASE_URL` moves it) once the file is on disk.
`--public` makes it publishable, `--no-upload` keeps `receipt_url` null. No key: exit 2 before
anything runs. Unwritable store: exit 5 and no verdict is printed.

## Wiring hmd prove

`hmd prove` (RP2) is another workstream and is not wired here. After it builds its `runhmd.prove/1`
document `p`, it calls, keyword-only:

```python
import runhmd_receipt as rr
raw = rr.issue_receipt(signer=rr.load_signer(), id=<stable token, e.g. 12 hex of the git head>,
        verdict=p["verdict"], subject={"kind": "path", "head_sha": <git head or None>, "tree_sha256": <sha256 of the tree it proved>},
        attacks={"total": 0, "survived": 0, "killed": 0}, findings=<see below>, gates=p["gates"],
        regression_tests=p["regression_tests"], agent={"name": "none", "model": None},
        cost_usd=0, duration_s=<seconds>, verdict_sha256=rr.verdict_digest(p))
rr.write_receipt(rr.store_dir(), id, raw); url = rr.receipt_url(id)
```

RC2 (the verdict/1 rules over the receipt's own fields) applies: a PROVEN prove run needs every gate
passing and falsified, and a DENIED one must carry at least one finding, so each gate that passes
but was never shown to fail becomes a finding (`id` `f-NNNN`, a title naming the gate, category
`regression`, `digest` = `rr.finding_digest(<that finding>)`). `issue_receipt` refuses a receipt
that violates its schema, so a mistake here is an error, not a bad receipt.

## Where this differs from the RP3 sketch (names are contract: tell hmdapp)

Added: `tool`, `verdict_sha256`, `key_id`, `subject.tree_sha256`, `findings[].digest`. Not present:
`repo`, `diff_summary`, `subject.pr` / `base_sha` (no PR targets yet), `findings[].counterexample`
and `human_label` (digests only; labels belong to the service, RP5, because a signed document
cannot change). `signature` is a base64 string as in the sketch.
