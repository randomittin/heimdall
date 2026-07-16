# DATA.md — Heimdall data contract

This is the whole, specified, minimal contract for every byte Heimdall records or
sends. It is the receipt behind the scoped claims in the README: *gates run
locally, presence is opt-out, telemetry is documented and killable.* If the code
and this file ever disagree, that is a bug — file it.

Heimdall has exactly **five** data surfaces. Three of them can put bytes on the
network; two of those only ever do so because you asked.

| Surface | Leaves your machine? | Default | Kill switch |
|---|---|---|---|
| **Local gates** (secret-scan, falsify, bloat, reuse, verify) | **No — never.** Your code is read on-disk and never transmitted. | on | n/a — nothing to disable; nothing is sent |
| **Team presence** (`bin/heimdall-presence`) | Yes — a scoped heartbeat to your team's control-plane endpoint | on (auto-solo team until you invite) | `hmd presence off` |
| **Telemetry / Pre-Merge Corpus** (`bin/heimdall-telemetry`, `bin/heimdall-telemetry-corpus`) | **Not in this release.** Written to a LOCAL spool only; the control-plane ingest is a future step (see "Send status" below). | on (T0) | `hmd telemetry off` |
| **Auto-update version check** (`bin/heimdall-autoupdate`) | Yes — one unauthenticated GET to the public GitHub Releases API. No body, no credential, no code. | on (throttled ~24h) | `HEIMDALL_NO_AUTOUPDATE=1` or `~/.heimdall/no-autoupdate` |
| **`rr` cloud maintainer** (`bin/rr`) | Yes — **only when you run it.** Sends your BYO Claude credential, your GitHub App installation id, and the literal task text you typed. | off — inert unless invoked | don't run `rr` (`RR_NO_CONTEXT=1` drops the context capsule) |

Everything below documents the *real* shapes emitted by the code, field by field.

---

## 1. Team presence

Presence lets teammates see who is online in a repo. It is a feature you can see
and switch off. The client is `bin/heimdall-presence`; the wire body is built in
its embedded Python client (`run_client` → `POST /presence`).

The endpoint defaults to the public control plane baked in at
`bin/heimdall-presence:304` (`DEFAULT_CP_URL="https://heimdall-cp-public-eqfrs7sfuq-uc.a.run.app"`),
and resolves `--url` > `$HEIMDALL_CP_URL` > `$BASE_URL` > `~/.heimdall/cp-endpoint.json`
> that default. Presence talks to a server by default; it is opt-out, not absent.

### What enrollment (`/enroll`) sends — the exact body

```json
{
  "haid":   "<your presence identity>",
  "pubkey": "<your Ed25519 public key, base64>",
  "handle": "<your display handle, or null>"
}
```

### What a heartbeat (`beat`) sends — the exact body

```json
{
  "project":     "<normalized git remote: host+path, scheme/user/port stripped, .git dropped, lowercased>",
  "handle":      "<your display handle, from heimdall-identity>",
  "verdict":     "<a short status tag: working | pass | deny | scanning | watching | idle | …>",
  "file":        "<current filename only — basename-level, never contents, never full path>",
  "activity_ts": "<epoch seconds of your last real edit/verdict, for ACTIVE vs IDLE>",
  "nonce":       "<single-use replay-guard token>",
  "ts":          "<unix timestamp>"
}
```

- The request also carries `X-Heimdall-HAID` (your presence identity) and an
  Ed25519 `X-Heimdall-Signature` over method+path+body.
- The per-repo **team secret** (`<repo>/.heimdall/team.json`) rides the
  `X-Heimdall-Team-Secret` header on **every** presence call — beat, retire, and
  roster — not only at `/enroll` (`bin/heimdall-presence:469-476`). The server
  hashes it (`derive_team_id`) to the same partition the roster read derives, which
  is what makes a signed beat land where its team.json secret reads it back. The
  signature covers only method+path+body, so the header never perturbs it. The
  secret travels over TLS, never on argv, and is never logged.

### What `roster` returns (read)

Per online teammate: `{ handle, verdict, file, age_seconds }`. Reading the roster
sends no body (a GFE-safe signed `GET /roster?project=<p>` — the project rides the
query string, which the signature covers).

### Presence controls

| Command | Effect |
|---|---|
| `hmd presence status` | print repo / global / effective state + exactly what is broadcast |
| `hmd presence off` | stop broadcasting from this repo + emit one signed retire beat (drop off teammates' walls now, no TTL wait) |
| `hmd presence on` | re-enable this repo |
| `hmd presence on --no-files` | stay present but send `file: null` — handle + verdict only |
| `hmd presence off --global` | machine-wide kill switch (`~/.heimdall/presence-off`) |
| `hmd presence roster [--json]` | see the team (still works while you are OFF — off is invisible, not blind) |

State lives locally and is read without a server round-trip:
`<repo>/.heimdall/presence.json` (`{"enabled": false}` = repo off; `{"files": false}`
= no-files) and `~/.heimdall/presence-off` (existence = global off). Default = ON.
**OFF is enforced client-side as a stat-only no-op** — a cron/hook cannot leak a beat
around the toggle.

### Presence never sends

Source code · file contents · full file paths (only the current *filename* is ever
sent, and `--no-files` withholds even that) · prompts · your signing seed
(the Ed25519 private seed lives only in a `0600` file + the signing process — never
argv, never logged, never transmitted).

---

## 2. Telemetry — the Pre-Merge Corpus (PMR), tier T0

`hmd telemetry …` routes to `bin/heimdall-telemetry-corpus` → `bin/lib/pmr_corpus.py`.
It records the **shape and outcome** of a verified change so gate quality can be
measured — never the change itself. It is **zero-content by construction**: a
cardinal guard (`assert_zero_content`) scans every string leaf of every record and
**blocks** anything that looks like a path, a source line, or content; a
secret-shaped value is blocked by a gitleaks-pattern scan before it can be queued.

### T0 — the exact `pmr_v1` record (built by `project()`, `pmr_corpus.py:462`)

Every field below is a **count, boolean, coded tag, or non-reversible hash**. No
free-text payload field exists in the schema.

```
schema:          "pmr_v1"
consent_version: "t0-2026-07"          # stamped on every record (see §6)

ids:
  pmr_id           # random per-record uuid
  team_id_hash     # domain-separated sha256 of an already-hashed team_id (non-reversible)
  repo_class_hash  # domain-separated sha256 of the repo origin slug — NEVER the repo name/URL

when:
  ts               # ISO-8601 UTC, second precision
  tz_bucket        # coarse timezone bucket

agent.haid_class:
  tool             # coded tag (e.g. claude-code)
  model_family     # coded tag
  version          # coded tag

change:            # derived from the attestation — paths are NEVER copied
  files_touched        # count
  loc_added            # count
  loc_deleted          # count
  hunks                # count
  langs                # coded language tags (e.g. ["py","ts"]), derived from extensions
  complexity_delta     # count (unit count)
  dep_graph_touch      # bool — did the change touch a dependency manifest
  test_files_touched   # count

verify:
  gates_run            # coded gate-name tags (["secret-scan","falsify",…])
  verdict              # coded verdict (pass|deny|fail|…)
  deny_reasons         # coded risk-flag codes (never prose)
  retry_count          # count
  time_to_green_s      # number (seconds)
  falsify.mutants_run  # count
  falsify.survived     # count
  reuse.dup_candidates # count
  reuse.reused         # bool
  bloat_budget_delta   # number

human:
  merged               # bool
  overridden           # bool
  override_latency_s   # number (seconds)

env:
  os_class             # coded (e.g. darwin|linux)
  ci                   # bool
  hmd_version          # coded version tag
```

An **outcome** record (`pmr_outcome_v1`) later joins a change to whether it was
reverted / hotfixed / survived — again only booleans and coded buckets, passed
through the same zero-content guard.

### Tiers

- **T0** — the zero-content metadata above. **Default ON.** Disclosed at install
  (one line + a link to this file).
- **T1-hunks** — deny-context hunks (the diff around a *rejected* change), **opt-in
  per repo**. In this release `hmd telemetry hunks on` records the per-repo opt-in
  **flag only**; no T1 payload is built or stored yet.

### Telemetry controls

| Command | Effect |
|---|---|
| `hmd telemetry status` | read-only: tier, exactly what is collected, spool size, opted-in repos, queued deletions |
| `hmd telemetry off` | turn consent OFF — emit becomes a pure no-op, **zero** writes |
| `hmd telemetry on` | turn consent back ON |
| `hmd telemetry hunks on` / `off` | flip the per-repo T1-hunks opt-in flag |
| `hmd telemetry purge` | empty the local spool (pmr + outcome + pending + seeds) **and** record a `pmr_delete_v1` deletion request keyed by `team_id_hash` |

Also honored: `HEIMDALL_TELEMETRY=off` (env), and an opt-out marker file
`telemetry.off` under the runtime home. A disabled world behaves **identically** to
a build with no telemetry — every emit is a no-op that never fails a run or install.

### Send status (honest scope for this release)

Step 1 (what ships) is **emit-locally-only**: the consent-gated send queue is
plumbed, but **nothing is transmitted** — the local spool *is* the queue
(`~/.heimdall/telemetry/pmr/`). Verified: `bin/lib/pmr_corpus.py` contains no
network client at all — no `urllib`, no `requests`, no socket, no HTTP call. The
control-plane ingest and the server-side deletion job are **step 2 and are not
active in this release**. Consequently, today:

- Your PMR telemetry does not leave your machine.
- `hmd telemetry purge` deletes the local spool immediately, and the
  `pmr_delete_v1` request it queues is the durable contract the step-2 deletion
  job will honor once ingest exists.

> **Flag for the CLI/backend owners:** the scoped claim "telemetry … purge deletes
> the local spool" is fully honored today. If a remote leg (CP ingest + a
> server-side deletion job) is ever implemented, this file and the README claim must
> be updated in the same change — and only then does a round-trip deletion claim
> become sayable. Until then, no PMR data is transmitted, so there is nothing remote
> to delete.

### General event telemetry (`bin/heimdall-telemetry`, install-step)

A separate, local NDJSON event log (`<home>/.heimdall/telemetry/events.ndjson`)
records install/run lifecycle events: `install_step | phase | gate | token |
outcome | commit | issue_state`, each with coded tags (`step`, `outcome`, `gate`,
`loc` = `file:line`), optional `duration_ms`, short `commit` SHA, and **shape-only**
error summaries (`error.class/step/detail`). The schema has **no free-payload
field**; `error.detail` and any `extra` value are bounded to ≤120 chars and
**rejected** if they match a gitleaks high-signal pattern or a `key=opaque-value`
shape. `token` counts are copied verbatim from `bin/heimdall-tokens` (pure numeric
usage metrics). Same off switch: `HEIMDALL_TELEMETRY=off` or the `telemetry.off`
marker. `bin/lib/telemetry.py` has **no network call in it at all** — it writes one
file on disk. It is stored as plaintext NDJSON specifically so the gitleaks gate
scans it natively.

---

## 3. Auto-update version check

`bin/heimdall-autoupdate` keeps the plugin current. On session start, **throttled to
roughly once every 24h** (`HEIMDALL_UPDATE_INTERVAL`, default `86400`), it makes
**one unauthenticated GET** to the public GitHub Releases API:

```
https://api.github.com/repos/<owner>/<repo>/releases/latest      # bin/heimdall-autoupdate:76
```

- **No credential, no token, no body, no code, no identifier.** The only headers are
  `Accept: application/vnd.github+json` and whatever curl sends by default; the call
  is anonymous and ~5s-bounded (`bin/heimdall-autoupdate:139,153`).
- **What comes back is used, not stored about you:** the response's `.tag_name` is
  compared to the installed version. GitHub, like any host you fetch from, sees the
  request (source IP, timing) — that is the whole of what this surface discloses.
- If a newer release exists, the installer for that tag is downloaded and its
  **minisign signature is verified against the in-repo public key**
  (`release/heimdall-signing.pub`) via `bin/lib/heimdall-verify.sh`. A missing
  verifier, or a missing/invalid/mismatched signature, is **fail-closed** — it
  refuses to apply.
- **Off:** `HEIMDALL_NO_AUTOUPDATE=1`, or the marker file `~/.heimdall/no-autoupdate`.

---

## 4. `rr` — the cloud maintainer (opt-in by use)

`bin/rr` is the one surface that exists to send things, and it is **inert until you
run it**. It targets the public control plane baked in at `bin/rr:78`
(`DEFAULT_CP_URL="https://heimdall-cp-public-203927696193.us-central1.run.app"`),
overridable via `--endpoint` > `$HEIMDALL_CP_URL`/`$BASE_URL` >
`~/.heimdall/cp-endpoint.json`. Every call is Ed25519-signed with the same
presence-enrolled seed (the key is never re-implemented).

### `rr connect` — two write-only registrations

| Route | Body | Notes |
|---|---|---|
| `POST /team/cred` | `{kind, secret}` | Your **BYO Claude credential** (`$CLAUDE_CODE_OAUTH_TOKEN` / `$ANTHROPIC_API_KEY`, else pasted at a hidden `read -rs` prompt). Crosses bash→python via **env, never argv**. **Write-only** — never read back, never logged, never echoed. Lands in your team's own Secret Manager secret. |
| `POST /team/install` | `{installation_id, repo}` | Your **GitHub App installation id** and repo slug, so the worker can act as the scoped bot on your repo. |

### `rr "<task>"` — the signed enqueue

The body built at `bin/rr:568` is **`{text, context?, nonce, ts}`**:

- **`text` — the literal task text you typed.** This is transmitted verbatim,
  because that text *is* the job you are asking the cloud maintainer to do. There is
  no way to ask a remote agent to do a thing without telling it the thing.
- **`context` (optional)** — a bounded session **briefing capsule** built by
  `bin/heimdall-context-capsule`, trimmed to 8000 chars client-side (the server
  scrubs and trims again). It is an **allowlist** of human-readable session state,
  never a dump: a short "what this session did" header, the active goal,
  `.planning/CHECKPOINT.md` and `.planning/STATE.md` (tails), `.planning/decisions*`,
  `git log --oneline -30`, and the project comprehend capsule. It **never** reads env
  files, `~/.heimdall/*.env`, `team.json`, or any credential store. Before it can
  leave, it is **redacted** (PEM keys, AWS/GitHub/Slack/Google tokens, JWTs,
  `key=value` secret shapes) and then **scanned by gitleaks — fail-closed**: a
  finding **aborts** the build and nothing is written or shipped. Opt out with
  `RR_NO_CONTEXT=1`.
- **No `team_id`** rides the body — the server derives the team from the signed
  binding (INV-1), which is what makes cross-tenant IDOR unrepresentable rather than
  merely forbidden.

### `rr` does not upload your source code

The worker **clones your repo server-side** from GitHub using your own GitHub App
installation — your working tree is never read or uploaded by `rr`. What leaves your
machine is the task text, the optional briefing capsule described above, and the two
`connect` registrations. Preview any of it with `--dry-run`, which prints the literal
signed payload and executes nothing (no creds, no network).

---

## 5. Never collected — by construction, on every surface

- **Source code / file contents** — never read into any record or body. No surface
  uploads your working tree; `rr`'s worker clones from GitHub instead (§4).
- **File paths** — never in the clear. Presence sends only the current *filename*;
  PMR stores only a hashed directory + a coded extension, never the path. (The `rr`
  context capsule may carry planning-doc and commit-subject text you authored — see
  §4; it is allowlisted, redacted, and gitleaks-gated fail-closed.)
- **Repo names / URLs** — never in telemetry: PMR stores only `repo_class_hash` (a
  non-reversible, domain-separated sha256 of the origin slug). Presence sends a
  normalized project slug, and `rr connect` sends your repo slug, because both are
  addressed *to* your team's own partition.
- **Prompts** — never captured by the gates, by presence, or by telemetry. **The one
  exception is `rr`, and only when you invoke it:** `rr "<task>"` transmits the
  literal task text you typed (§4). Nothing captures a Claude Code session prompt.
- **Secrets / tokens / credentials / PII** — blocked *before* write by the
  zero-content guard and the gitleaks-pattern secret scan; a matching value is
  dropped and alarmed, never stored or queued. The one credential that moves is the
  one you hand `rr connect` on purpose, write-only (§4).
- **Signing seeds** — the Ed25519 private seed lives only in a `0600` file + the
  signing process; never argv, never logged, never sent.

---

## 6. Consent versioning

Every telemetry record carries `consent_version` (currently **`t0-2026-07`**,
`pmr_corpus.CONSENT_VERSION`, `bin/lib/pmr_corpus.py:58`). Bump it whenever the T0
disclosure text **or** the record shape changes. A record's version pins it to the
exact disclosure the user agreed to, so a later schema change can never retroactively
re-interpret already recorded data. Deletion requests and status reports carry the
same version.

---

## 7. k-anonymity rule for published aggregates

Any aggregate derived from the corpus that is **published or shared outside the
contributing team** (dashboards, benchmark tables, blog figures, the `/proof`
page) MUST be **k-anonymous with k ≥ 5**:

- No published cell, bucket, or statistic may be computed from fewer than **5
  distinct teams** (distinct `team_id_hash` values). A group under the threshold is
  suppressed or merged into a coarser bucket — never published.
- Join keys stay non-reversible: `team_id_hash` and `repo_class_hash` are
  domain-separated sha256 projections, so a published figure can never be traced
  back to a repo or team.
- A deletion request (`hmd telemetry purge`) removes the contributor's records from
  the population before the next aggregate is computed.

This rule binds any code that computes or exports corpus aggregates; a change that
would publish a sub-k cell is a defect.

---

*Questions, or a mismatch between this file and the code? Open an issue —
`hmd report-bug`.*
