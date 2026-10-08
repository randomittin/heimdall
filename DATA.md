# DATA.md — Heimdall data contract

This is the whole, specified, minimal contract for every byte Heimdall records or
sends. It is the receipt behind the scoped claims in the README: *gates run
locally, presence is opt-out, telemetry is documented and killable, the phone
companion is opt-in.* If the code and this file ever disagree, that is a bug —
file it.

Heimdall has exactly **eight** data surfaces. Six of them can put bytes on the
network. Presence and the update check are on by default; the other four — `rr`
and the three phone-companion surfaces (§9) — only ever do so because you ran
`rr`, or ran `hmd app connect` and paired a phone.

| Surface | Leaves your machine? | Default | Kill switch |
|---|---|---|---|
| **Local gates** (secret-scan, falsify, bloat, reuse, verify) | **No — never.** Your code is read on-disk and never transmitted. | on | n/a — nothing to disable; nothing is sent |
| **Team presence** (`bin/heimdall-presence`) | Yes — a scoped heartbeat to your team's control-plane endpoint | on (auto-solo team until you invite) | `hmd presence off` |
| **Telemetry / Pre-Merge Corpus** (`bin/heimdall-telemetry`, `bin/heimdall-telemetry-corpus`) | **Not in this release.** Written to a LOCAL spool only; the control-plane ingest is a future step (see "Send status" below). | on (T0) | `hmd telemetry off` |
| **Auto-update version check** (`bin/heimdall-autoupdate`) | Yes — one unauthenticated GET to the public GitHub Releases API. No body, no credential, no code. | on (throttled ~24h) | `HEIMDALL_NO_AUTOUPDATE=1` or `~/.heimdall/no-autoupdate` |
| **`rr` cloud maintainer** (`bin/rr`) | Yes — **only when you run it.** Sends your BYO Claude credential, your GitHub App installation id, and the literal task text you typed. | off — inert unless invoked | don't run `rr` (`RR_NO_CONTEXT=1` drops the context capsule) |
| **Phone companion relay** (`bin/heimdall-relay-client`) | Yes — **only while you run `hmd app connect`.** End-to-end sealed frames to *your own* paired phone through the hosted relay (`https://hmd-relay.therishabh16.workers.dev`): session state with repo-relative paths, and — only when the phone asks — a file diff, transcript tail or PR summary. The relay forwards ciphertext and cannot read it (§9). | off — nothing runs until `hmd app connect` | `hmd app disconnect` (or Ctrl-C); `hmd app controls off` / `HMD_UI_CONTROLS=0` refuse phone views and controls; `--relay URL` / `HMD_RELAY_URL` to self-host |
| **Phone push notifications** (`bin/lib/companion_push.py`) | Yes — **only once a paired phone registered an Expo push token.** hmd POSTs straight to `exp.host`: not through the relay, and **not end-to-end sealed** — Expo, and Apple or Google behind it, can read the text. Title ≤ 48 and body ≤ 120 UTF-16 units: fixed templates plus allowlisted fields (§9). | off — nothing is sent until a phone registers | `HMD_PUSH=0` (exactly `0`); `hmd app disconnect`; delete `<repo>/.heimdall/app/push.json` |
| **Pair-by-code** (`hmd app connect`) | Yes — **while the 10-minute code window is open.** Your `gh auth token` goes to the relay in a TLS request body; the relay spends it on one `GET /user` to GitHub to learn your numeric GitHub id and, by its INV-39, never stores or logs it (§9). | on whenever `gh auth token` yields a token | `hmd app connect --no-code` (QR pairing — no token leaves); `hmd app identity revoke` |

Everything below documents the *real* shapes emitted by the code, field by field.

**Not listed above: auto-commit.** hmd's automatic checkpoint commits
(`bin/heimdall-autocommit`) are a **repository-mutation** behavior, not a
data-collection one, so they are not another row in the table above — nothing
they do puts a byte on any network. They write only to your own git history and
to a local `.heimdall/receipts/unproven.log` file. See SECURITY.md's
"Auto-commit" section for what gets committed, when it bypasses your commit
gate, and how to turn it off.

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

### Does `hmd` commit `team.json`? — and the off switch

The team secret file is a **repository-mutation** surface as well as a network one. In a
repo `hmd` can *prove* is private (authenticated `gh`), `hmd team` — and the SessionStart
`hmd team auto` step — force-adds `<repo>/.heimdall/team.json` and makes one **local** commit
(never a push), so a teammate's clone auto-joins. A public or unprovable repo is never
committed to: the file is gitignored instead (`bin/heimdall-team`: `commit_team`).

To keep the secret out of git history entirely, switch the commit off:

| Switch | Effect |
|---|---|
| `HMD_TEAM_NO_COMMIT=1` | this process / shell |
| `touch ~/.heimdall/no-team-commit` | persistent, machine-wide (`rm` it to restore) |

With either on, `team.json` is **still written and kept current on disk** (`new`, `join`,
`rotate`, `auto` — presence works exactly as before) but is **never staged or committed**:
not by `hmd team new|share|rotate|auto|<bare>`, and not by the blanket `git add -A` inside
`bin/heimdall-wip-commit`'s mid-task checkpoints (it backs `team.json` out of the index; the
edit stays on disk as a pending change). Any value other than empty / `0` / `false` / `no` /
`off` turns the switch on — fail-safe, so a typo can never commit a secret. An untracked
`team.json` is added to your clone's local `.git/info/exclude` (never the shared
`.gitignore`) so a blanket `git add` cannot sweep it in either. One limit: a `team.json`
that is **already tracked** stays tracked — `git rm --cached .heimdall/team.json` stops that.
Without the commit a clone no longer carries the file, so grow the team with `hmd invite`.
Proof: `test/heimdall-team-no-commit.test.sh`.

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
  context_proxied      # bool — is the provider BASE URL redirected by the environment
  proxy_vendor         # coded vendor tag (e.g. "headroom"); ABSENT when none is named
  hmd_version          # coded version tag
```

`context_proxied` and `proxy_vendor` exist to answer one research question: does
running an agent through a proxied base URL correlate with deny classes? Both are
read from environment variables only — nothing is executed, probed, or installed,
and the named tool need not be present. Like every field above, they are written to
the **local spool only**; this release sends nothing.

- **`context_proxied`** is true when a base-URL redirect is set:
  `ANTHROPIC_BASE_URL`, `ANTHROPIC_API_URL`, `ANTHROPIC_DEFAULT_BASE_URL`, or
  `CLAUDE_CODE_BASE_URL` (a strict subset of the routing vars
  `bin/lib/hmd-gate-endpoint.sh` scrubs from every gate child). It records
  *redirection* — not compression: an enterprise LiteLLM/Bedrock gateway sets a base
  URL and compresses nothing.
- `HTTP_PROXY` / `HTTPS_PROXY` / `ALL_PROXY` / `NO_PROXY` (and the lowercase forms)
  are **deliberately excluded**. A corporate egress proxy sets those and redirects no
  base URL, so counting them would mark every developer behind a corporate network as
  proxied — an enterprise-correlated bias in the very data meant to measure proxying.
- **`proxy_vendor`** is emitted only when the environment names a vendor namespace
  (`HEADROOM_*` → `"headroom"`). When no vendor is named the key is **absent**, never
  `"unknown"` — an absent key is the honest shape for "none observed".

The exclusion and the absent-when-unknown rule are gated by
`test/pmr-context-proxied.test.sh`, not merely intended.

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

- **Source code / file contents** — never read into any record or body, with one
  exception: when you pair a phone, a file diff you ask it to open travels
  end-to-end sealed to that phone (§9). No surface uploads your working tree;
  `rr`'s worker clones from GitHub instead (§4).
- **File paths** — never in the clear. Presence sends only the current *filename*;
  PMR stores only a hashed directory + a coded extension, never the path. (The `rr`
  context capsule may carry planning-doc and commit-subject text you authored — see
  §4; it is allowlisted, redacted, and gitleaks-gated fail-closed. The phone
  companion carries repo-relative paths only inside its sealed frames, and a push
  body can carry a bare basename out of a question's text — §9.)
- **Repo names / URLs** — never in telemetry: PMR stores only `repo_class_hash` (a
  non-reversible, domain-separated sha256 of the origin slug). Presence sends a
  normalized project slug, and `rr connect` sends your repo slug, because both are
  addressed *to* your team's own partition.
- **Prompts** — never captured by the gates, by presence, or by telemetry. **Two
  exceptions, each only when you invoke it:** `rr "<task>"` transmits the literal
  task text you typed (§4), and a paired phone that opens the transcript view is
  shown the session's one-line turns, prompts included, end-to-end sealed (§9).
  Nothing else captures a Claude Code session prompt.
- **Secrets / tokens / credentials / PII** — blocked *before* write by the
  zero-content guard and the gitleaks-pattern secret scan; a matching value is
  dropped and alarmed, never stored or queued. Two credentials move, each on
  purpose: the one you hand `rr connect`, write-only (§4), and your `gh auth token`,
  sent to the relay while a pair-by-code window is open (§9; `hmd app connect
  --no-code` keeps it home). Your phone's Expo push token goes to Expo with every
  push (§9).
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

## 8. Phone deny — on by default, deny-only

`bin/heimdall-phone-deny` is a `PreToolUse` hook (hook id `phone-deny`, matcher
`Bash|Write|Edit|MultiEdit|NotebookEdit`) that lets a phone paired through `hmd app connect`
refuse a risky action. **It is on by default.** It has no network client of its own — it reads
and writes files under the repo's `.heimdall/` — and it writes nothing to presence, telemetry or
the control plane. Whatever reaches a phone rides the `hmd app connect` relay session you started
yourself, sealed end-to-end (the relay forwards ciphertext only).

**When it does anything.** Only when all of these hold; otherwise it exits 0 having printed and
written nothing, and Claude Code's normal permission flow decides exactly as it would without it:

- the session is attended (not `claude -p` / an SDK child, not an hmd sub-session);
- a relay-mode `hmd app connect` is live (`.heimdall/app/connect.json` naming live pids), a device
  is paired, and the relay did not report "no phone connected" on its last frame;
- the action is risky: a shell command that pushes, deletes, publishes, deploys, changes something
  over the network, escalates privilege or changes the system, or a `Write` / `Edit` / `MultiEdit` /
  `NotebookEdit` whose real path is outside the project root.

With no `connect.json` in the project the hook is skipped after one file test per tool call.

**Deny-only.** The phone has two verbs on a pending request: `deny` (refuse this call) and `stop`
(refuse it and end the turn). There is no allow, no approve and no edit of the call — the hook's
whole output is nothing, a deny, or a deny plus `{"continue": false}`; a phone can only reduce what
runs. While a phone is connected a risky action is held for up to a window
(`HMD_PHONE_DENY_WINDOW_S`, default 10 s, clamped to 1–120); no reply inside it prints nothing.

**What it writes, for one held action.** One request file,
`<repo>/.heimdall/ui/approvals/p-<8 hex>.json` (directory `0700`, file `0600`), withdrawn when the
hook leaves:

```
id            "p-" + 8 random hex
tool          the tool label, reduced to [A-Za-z0-9_.:-]
summary       the shell command, or "<Tool> <path>" for a file tool; control bytes flattened,
              cut to 200 chars; a secret-shaped summary is stored as null, never written raw
requested_at  epoch seconds
expires_at    requested_at + the window
risk          "high"
```

A `p-<8 hex>.decision` file (`{id, decision, decided_at}`, no summary) is kept for up to 10
minutes so a late reply is answered `expired` rather than acknowledged for an action that already ran.

**What reaches the phone.** The live requests (at most 5, those six keys) ride the sealed state
frame as `approvals`, with absolute repo paths reduced to repo-relative and email addresses masked;
the phone's `deny` / `stop` comes back as a sealed, replay-guarded `decide` command. A push
notification, if you registered a device, carries only `<tool> is waiting. Deny within N s.` and
the request id — never the command, a path or the summary.

**Off switch.** `HMD_PHONE_DENY=0` (also `false`, `no`, `off`; any case) in the environment Claude
Code runs in, or `hmd hooks disable phone-deny` (`hmd hooks enable phone-deny` brings it back).
Unset, empty or any other value leaves it on, so a typo cannot silently disable it. Proof:
`test/heimdall-phone-deny.test.sh`, `test/heimdall-phone-deny-relay.test.sh`.

---

## 9. Phone companion — relay, push, pair-by-code

Three surfaces in the table exist only because you started `hmd app connect` and paired a
phone. Nothing starts them for you: no hook, installer step or session start runs `hmd app
connect`. (Phone deny, §8, is the approval path of this same session.)

### The relay leg (`bin/heimdall-relay-client`)

`hmd app connect` publishes through the hosted relay — a Cloudflare Worker plus Durable
Object whose source is `relay/` in this repo. The origin is baked in at
`bin/heimdall-app:293` (`DEFAULT_RELAY_URL="https://hmd-relay.therishabh16.workers.dev"`)
and resolves `--relay URL` > `$HMD_RELAY_URL` > that default; a Worker you deploy yourself
takes the project's relay out of the path. `hmd app connect --tailscale` is a different
transport and is **not** sealed end-to-end: it publishes the loopback `hmd ui` through
Tailscale Funnel at a public hostname guarded by a per-launch token, with absolute paths
reduced to basenames. Everything below describes the relay transport.

**Sealed.** Every `state`, `command` and `ack` frame is sealed before it leaves the process:
X25519 agreement with the phone's key, HKDF-SHA256 per session, ChaCha20-Poly1305
(`bin/lib/hmd_relay_e2e.py`, stdlib only, checked against the RFC vectors; if that check
fails the client exits 11 rather than send unsealed). The relay stores and forwards
ciphertext and cannot read it. It does see plaintext metadata: the session id, frame
sequence numbers, sizes and timing, your IP address (its rate-limit counters are keyed on
it) and the phone's public key. It keeps only the newest sealed state frame, to replay to a
reconnecting phone, until the session is revoked or purged (about 5 minutes after a revoke;
about 30 days for a bound session that was never revoked).

**A state frame** carries the slices `hmd ui` shows (`sentinels/hmd-ui.py:collect_state`):
identity (handle, HAID, branch, session code), coordination ledger, roster, push-gate
verdict, sweep receipt, hooks, fallback mode, parallelism, checkpoint, reels, `edits` (the
repo-relative paths of files this session changed), panels, inbox counts, `approvals` (§8),
`attention` (the agent's pending question), controls and dashboard tiles (none until you
switch `hmd app remote-dashboards on`). The relay redaction profile
(`_transport_redaction`) runs first: absolute paths below the repo become repo-relative,
paths outside it and `~/` paths become a basename, and emails are masked.

**On request only** (`view-v1`, `bin/lib/companion_view.py`; read-only, only to a phone that
listed the capability, at most 20 requests per 60 s):

- a file **diff** (`worktree`, `staged` or `head`; at most 256 KiB). Never shown: `.git`,
  `.heimdall`, `.env*`, `*.pem` `*.key` `*.p12` `*.pfx` `*.jks` `*.keystore`, `id_rsa`-shaped
  names, `.netrc` `.npmrc` `.pypirc`, any path with a symlink in it, any secret-shaped path;
  a secret-shaped line is masked `[redacted]` whole. **This is the one place source code
  itself leaves your machine — to the phone you paired, sealed.**
- a **transcript** tail of this repo's session or of one subagent (at most 500 turns, each
  of at most 400 characters, its line breaks kept: a prompt, an assistant text, or a tool
  call's name, status and first output line; a secret-shaped turn is masked).
- a **pull-request summary** from your local `gh pr view` (number, title, state, checks,
  reviewers, URL).

A result lives in memory only and is never logged. The client's local files are
`<repo>/.heimdall/app/connect.json`, `relay.json` and `relay-events.jsonl` (counts, sizes
and status codes — never plaintext, tokens or keys; `HMD_RELAY_EVENT_LOG=""` disables the
log).

**Inbound** (phone to laptop — not egress, listed because it is the other half of the
channel): a typed message into the agent's inbox, `decide` (deny only, §8), push
registration, and four remote controls (`interrupt`, `save-checkpoint`, `hook-toggle`,
`fallback-mode`), on by default. Remote login, launch, merge, dashboards, asks and alerts
are each **off until you switch them on at the laptop** (`hmd app remote-login`,
`remote-launch`, `remote-merge`, `remote-dashboards`, `remote-asks`, `remote-alerts`, each
`on`).

**A picture from the phone** (`attach-v1`, `bin/lib/companion_attach.py`; JPEG or PNG, at most 2 MiB, relay only) is the one thing the
phone can leave on disk: hmd checks its size, sha256 and magic bytes, strips Exif, GPS, XMP, IPTC, comments and thumbnails with a
byte-level whitelist (anything it cannot parse is refused) and keeps it as `<repo>/.heimdall/app/attachments/<id>.jpg|png` (file 0600,
directory 0700; the 20 newest, none past 24 hours; git-ignored with the rest of `.heimdall/`). One inbox record names the file's absolute
path so the session can read it; that path is in no frame sent to the phone, no audit line and no event. Never executed, never uploaded.

| Switch | Effect |
|---|---|
| `hmd app disconnect` (or Ctrl-C in the foreground `connect`) | stops the relay client, which revokes the session at the relay; the phone cannot reconnect. The only switch that stops state frames |
| `hmd app controls off` / `HMD_UI_CONTROLS=0` | every view and control is refused `controls-off` (`off` writes `<repo>/.heimdall/app/controls-disabled`, `on` removes it). State frames still flow while connected |
| `HMD_ATTACH=0` | in the environment of `hmd app connect`: `attach-v1` is no longer offered to the phone and every attach command is refused `not-implemented`. **Exactly `0`**. `hmd app controls off` refuses them `controls-off` instead |
| `--relay URL` / `HMD_RELAY_URL` | publish through a relay you run instead |

### Push notifications (`bin/lib/companion_push.py`)

Sent by hmd itself, **not through the relay**: one HTTPS call class to
`https://exp.host/--/api/v2/push/send` (and `…/getReceipts`, once, at least 900 s after a
send), only after a paired phone registered an Expo push token in
`<repo>/.heimdall/app/push.json`. The sender is the one `hmd ui` or relay-client process per
repo that holds `push-sender.lock`. **Not sealed:** Expo, and Apple or Google behind it, can
read the title and body. Redirects are never followed, and `HMD_PUSH_EXPO_URL` is honoured
only for a loopback host, so it cannot redirect pushes elsewhere.

The exact message (`build_message`):

```
to             the phone's own Expo push token
title          "<label> · <phrase>", at most 48 UTF-16 units; the label (at most 24) is the phone's own
body           at most 120 units: a fixed template over allowlisted fields (below)
data           {v: 1, ref: <16 hex>, kind, ep: <attention id | null>} (+ pid, exp for an approval)
categoryId · channelId · priority · interruptionLevel · sound · ttl · collapseId · tag · threadId
               fixed per kind; the ids are sha256 prefixes, never a raw id
```

Body fields, all allowlisted: counts and booleans (`3 of 12 gates failing.`, `Suites 40/42
passed.`, `Ran 4m 12s.`), the tool name of a held approval (`Bash is waiting. Deny within 8
s.` — never its command), and, for a question, the agent's question summary plus up to three
option labels of at most 16 units — **the only free text**. That text is replaced whole by a
constant if it is secret-shaped, and otherwise scrubbed: code spans become `[code]`; emails,
URLs, query strings, `key=value` secrets, long tokens, long digit runs and hex hashes are
masked; any path is cut to its last segment, so a bare basename can survive. Never read: an
approval's command text, paths, branches, repo names, chat text, panels. Two more kinds
exist only once you enabled dashboards at the laptop (`hmd app remote-dashboards on`, and
`remote-alerts on` for alerts) and the phone subscribed: `tile_alert` (`<value>, limit
<limit>`, when you asked for the value) and `digest` (a morning report of at most four lines
of tile values and counts). Volume is bounded: at most one non-approval message per device
per 10 s, and 20 non-approval plus 20 approval per device per rolling hour.

| Switch | Effect |
|---|---|
| `HMD_PUSH=0` | in the environment of `hmd app connect` / `hmd ui`: nothing is sent, `push-v1` is no longer offered to the phone, a registration is refused `push-disabled`. **Exactly `0`** — `off`, `false` or `no` leave push on |
| `hmd app disconnect` | ends the processes that send |
| delete `<repo>/.heimdall/app/push.json` | drops every registration (otherwise they stay until the next relay session binds a phone) |

### Pair-by-code (`hmd app connect`, the relay's `/session/:id/code`)

On whenever `gh auth token` yields a token — inside an `hmd app connect` you started — and
off with `--no-code` (QR pairing is untouched). The 5-character session code `hmd ui` shows
is registered with the relay under your GitHub identity, so a phone signed in to GitHub as
the same user can pair by typing it.

```
POST /session/:id/code      Authorization: Bearer <relay session token>
{ "code": "<5 chars>", "gh_token": "<your gh auth token>", "hmd_commit": "<commitment to this session's key>" }
```

- **Your GitHub token reaches a server you do not run.** It is read once from `gh`, handed
  to the client on a pipe (on no argv, environment variable or file), held in memory, and
  sent in that request body over TLS — the client refuses a non-https relay unless it is on
  loopback. The relay makes one `GET /user` to GitHub per request, to learn your numeric
  GitHub id and login. Its invariant INV-39 — checked by a test that scans every Durable
  Object's storage and every log line after a whole pairing — is that the token is never
  persisted or logged. That is a promise about the relay's code (`relay/`), not something
  the client can verify. The request repeats about once a minute as the relay's pairing
  window renews, until a phone binds or the 10-minute code window
  (`HMD_RELAY_CODE_WINDOW_S`) closes; the token is then dropped from memory.
- **The phone's side** (`POST /identity/github`, `POST /pair/code`): the phone's GitHub
  device-flow token is checked against hmd's GitHub App and deleted at GitHub, and replaced
  by a relay-signed assertion bound to the phone's key. The relay releases a pending pairing
  only to a phone whose verified GitHub id equals yours. After the bind a 6-digit number
  shows on both screens and you approve it at the terminal (`--no-confirm` skips that and
  trusts the relay).
- **What the relay keeps:** your numeric GitHub id, the code, and the phone's device label
  and GitHub login live on the session record only until bind, revoke, end or purge
  (INV-41); a per-GitHub-id index keeps nothing but a revoke timestamp, for up to 30 days.

| Switch | Effect |
|---|---|
| `hmd app connect --no-code` | no token leaves; pair by QR |
| `hmd app identity revoke` | sends your `gh auth token` to the relay once more (same pipe, same https rule) and invalidates every phone sign-in made with your GitHub identity — each phone signs in again. Revoking the GitHub App at github.com does not do this by itself |

---

*Questions, or a mismatch between this file and the code? Open an issue —
`hmd report-bug`.*
