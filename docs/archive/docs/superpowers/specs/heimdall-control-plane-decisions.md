# Heimdall Control Plane — Architecture Decisions Record

**Status:** FINAL — RJ decided 2026-06-24/25. These are not proposals.
**Design dossier:** `docs/superpowers/specs/heimdall-control-plane-design.md`
**Deploy + diagnostics spec:** `heimdall-cp-deploy-and-diagnostics-spec.md`

---

## ADR-1 — Encryption: Cloud Run TLS (transit) + Ed25519 PKI signing (identity)

### Context

The control plane design (§3) specifies that instance↔server communications must be authenticated and encrypted. Two independent mechanisms were in play:

- **Ed25519 PKI signing** at the application layer: every request is signed with the instance private key; server verifies against the registered pubkey. Proves *identity and integrity*. Does NOT provide confidentiality on its own.
- **Transport encryption**: Cloud Run automatically terminates HTTPS/TLS on every inbound request. This provides confidentiality in transit.

The design dossier originally stated "All instance↔server comms encrypted — TLS for transport" in prose, but the integration-gate table summarised it as `instance↔server PKI-encrypted`, eliding the TLS layer and implying application-layer encryption alone. This imprecision needed resolution.

### Decision

The "encrypted" requirement is satisfied by **Cloud Run TLS (in transit) + Ed25519 PKI signing (identity)**. Together they give:

- **Authenticated**: every request is PKI-signed; unsigned/bad-sig/unknown-HAID → 401.
- **Encrypted in transit**: Cloud Run provides HTTPS termination on every request; the wire is TLS-encrypted before the application sees it.

Hard rule: **the control plane MUST NEVER be exposed on plain HTTP outside Cloud Run.** The TLS layer is not optional; it is what makes the "encrypted" claim true. PKI signing alone (application layer) proves identity and integrity but does NOT encrypt the wire. The correct statement, precisely: *authenticated (PKI) and encrypted in transit (Cloud Run TLS).*

Do NOT describe the channel as "PKI-encrypted" — that conflates signing with encryption. Do NOT downgrade to "signed only" — the channel IS encrypted, via Cloud Run TLS.

### Consequences

- Deployment: `gcloud run deploy` with `--no-allow-unauthenticated` and no `--allow-http` flag. Plain HTTP never exposed.
- Dev/local testing uses the local server only (loopback, no external HTTP). CI does not expose the server on a public port.
- The integration-gate test label `instance↔server PKI-encrypted` is misleading; the correct label is `instance↔server PKI-authenticated + TLS-encrypted (Cloud Run)`.
- Any future deployment that moves off Cloud Run (self-hosted, bare VM) must add its own TLS termination (nginx/caddy/etc.) before the control plane is reachable. The TLS requirement is architectural, not Cloud-Run-specific.

---

## ADR-2 — Worker Job Isolation: in-process Python (current) / OS sandbox (external-user trigger)

### Context

The design dossier (§2) describes an "isolated execution env" with "separate process + dropped privileges + scrubbed env + no mount of the server's key dir / audit store / DB creds." The integration test (`test/control-plane-integration.test.sh`, cardinal #8) proves that a worker job cannot read the PKI private key or audit store. The question was: what level of isolation is required now, and what triggers the stronger form?

Two isolation levels are in play:

- **In-process Python** (current): env allowlist enforced in Python before worker code runs; path-deny list blocks access to the PKI key dir and audit store; `HEIMDALL_HOME` pointed at a per-job scratch dir. Proven by integration test #8 to wall off the PKI key + audit. This is a software boundary, not an OS boundary.
- **OS-level sandbox** (planned seam): separate subprocess + dropped Unix privileges (dedicated low-priv `cp-worker` uid) + container boundary. Enforces the same invariant at the OS level, making it harder to break through a Python bug or module exploit.

The threat model at launch: ~7-8 internal trusted developers. No external/untrusted users submit jobs.

### Decision

**In-process Python isolation is SUFFICIENT for the current internal-trusted-user threat model.** The integration tests are the proof: cardinal #8 asserts the PKI key and audit store are unreachable from inside a worker, and the gate goes green. This is a real, tested boundary — not aspirational.

**OS-level sandboxing (subprocess + dropped privileges + container boundary) is REQUIRED before exposing job execution to external or untrusted users.** The seam is already architected: `cp_worker.py` launches the job; swapping from in-process call to `subprocess` + privilege drop + namespace isolation is a contained change at that one seam. Nothing in (a)–(f) needs to change.

**Trigger:** OS sandbox gets built when the threat model changes — specifically when job execution is opened to users outside the internal ~7-8 dev team. Not before. Building it now would be premature hardening against a threat that does not yet exist.

### Consequences

- Current isolation is **tested and sufficient**, not aspirational. The integration test must stay green; if it goes red, isolation is broken regardless of which mechanism is in use.
- The `cp_worker.py` seam must NOT be entangled with business logic. It is the single swap-point. Any refactor that moves job launch logic out of `cp_worker.py` must preserve this property.
- When the OS sandbox is built, the integration test #8 (isolation cardinal) must still pass — the test defines the invariant, not the mechanism. Update the test to exercise the stronger boundary, not to relax the assertion.
- Documentation must not claim OS-level isolation until it is built. The correct current claim: "in-process isolation, proven by integration test, sufficient for internal trusted users."
- The design dossier's phrasing "dedicated low-priv `cp-worker` uid ... separate process" describes the **target seam**, not the current implementation. This distinction is noted here so readers understand what is built vs. what is planned.

### Build-stronger-when trigger

Exact condition: job execution (`POST /jobs`) becomes accessible to users outside the Heimdall internal team (i.e., any external user, contractor, or multi-tenant path). At that point, OS-level sandboxing is mandatory before the feature ships. The threat model drives the build, not a calendar.
