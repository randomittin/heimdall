# Part B — exact values, from source

Answers to the six runbook blockers. Every value below is either cited to `file:line` or is the
verbatim output of a real command run against the real service. Where a value could not be
established from the repo, it says **cannot establish from source** rather than guessing.

Repo: `/Users/rj/Downloads/heimdall` @ `9b3d2fd` (main). Branch: `partb-answers`.
`PUB=https://heimdall-cp-public-eqfrs7sfuq-uc.a.run.app`

**Nothing here was deployed, pushed, or mutated.** Live commands run were read-only:
`gcloud run services describe`, GETs, and unsigned POSTs that are rejected pre-write.

---

## 1. Session 1 step 5 — the enroll-posture flip

### The var is `HEIMDALL_ENROLL_OPEN`. There is exactly one.

Established from source, three independent places agreeing:

- `bin/lib/cp_enroll.py:93` — `ENROLL_OPEN_ENV = "HEIMDALL_ENROLL_OPEN"`
- `bin/lib/cp_publicsurface.py:222` — `_ENROLL_OPEN_ENV = "HEIMDALL_ENROLL_OPEN"` (the second,
  rate-limit gate reads the same var)
- `deploy/cloud-run/deploy-public-surface.sh:402-404` — the deploy sets it only in open mode

### Current live posture: OPEN

`gcloud run services describe heimdall-cp-public --region=us-central1 --project=heimdall-cp-prod`
(read-only) returns, verbatim:

```
HEIMDALL_PUBLIC_SURFACE      = 1
HEIMDALL_STATE_BACKEND       = firestore
GOOGLE_CLOUD_PROJECT         = heimdall-cp-prod
HEIMDALL_ENROLL_IP_LIMIT     = 5
HEIMDALL_ENROLL_IP_WINDOW    = 60
HEIMDALL_ENROLL_MAX_KEYS     = 1000
HEIMDALL_ENROLL_BUDGET_MAX   = 50
HEIMDALL_ENROLL_BUDGET_WINDOW= 3600
HEIMDALL_CP_SERVER_HAID      = cp-public-server
HEIMDALL_ENROLL_TOKEN        = <secret cp-enroll-token:latest>
HEIMDALL_CP_PKI_KEY          = <secret cp-pki-key-public:latest>
HEIMDALL_ENROLL_OPEN         = 1        <-- the flip target
```

Image digest: `sha256:2deffb90b1d1518d3f49f075fce42a0862f459b2aba447266304d4f11d7b9781`

**The flip is safe to make right now**, and this is the load-bearing fact: token mode is
*fail-closed*. If `HEIMDALL_ENROLL_TOKEN` is not mounted, closing the posture does not merely
tighten `/enroll` — it kills it, refusing every enrollment with `enroll_disabled`
(`bin/lib/cp_enroll.py:22-25`, `139-148`). On this service the `cp-enroll-token` secret **is**
already mounted (see the describe output above), so closing the posture lands in working token
mode rather than a dead route. Had it not been mounted, this command would have broken onboarding
for every new dev.

### The command

The canonical token-mode shape leaves the var **unset**, not `=0`
(`deploy/cloud-run/deploy-public-surface.sh:390-392, 399-401`; `GO-LIVE-RUNBOOK.md:12, 219, 401`).
`--update-env-vars` cannot unset a variable, so the byte-identical-to-canonical command is
`--remove-env-vars`:

```bash
gcloud run services update heimdall-cp-public \
  --region=us-central1 \
  --project=heimdall-cp-prod \
  --remove-env-vars=HEIMDALL_ENROLL_OPEN
```

**Recommended.** This reproduces exactly what a fresh `deploy-public-surface.sh` in the default
token mode produces.

The `--update-env-vars` form the runbook asks for also works and is behaviourally identical:

```bash
gcloud run services update heimdall-cp-public \
  --region=us-central1 \
  --project=heimdall-cp-prod \
  --update-env-vars=HEIMDALL_ENROLL_OPEN=0
```

`"0"` is not in the truthy set, so both gates read it as closed —
`cp_enroll.py:97` (`_OPEN_TRUTHY = {"1","true","yes","on"}`) with `enroll_open()` at
`cp_enroll.py:151-159`, and `cp_publicsurface.py:193, 226-232`. The only difference is cosmetic:
`=0` leaves an explicit var on the service that a fresh deploy would not have written.

### Verify after the flip

```bash
gcloud run services describe heimdall-cp-public --region=us-central1 \
  --project=heimdall-cp-prod \
  --format='value(spec.template.spec.containers[0].env)' | tr ',' '\n' | grep -i enroll
```

Expect no `HEIMDALL_ENROLL_OPEN` line (remove form), or `HEIMDALL_ENROLL_OPEN=0` (update form).

### The enroll caps — what they actually are

`.planning/settings.json:50` says *"Re-assert enroll caps on public after"* a rebuild. The caps
are these five vars, defined at `deploy/cloud-run/deploy-public-surface.sh:100-105` and written to
the service at `408-410`:

| Var | Value | Meaning | Source |
|---|---|---|---|
| `HEIMDALL_ENROLL_IP_LIMIT` | 5 | new enrolls per client-IP per window | `deploy-public-surface.sh:101` |
| `HEIMDALL_ENROLL_IP_WINDOW` | 60 | that window, seconds | `:102` |
| `HEIMDALL_ENROLL_MAX_KEYS` | 1000 | hard cap on total registry size | `:103` |
| `HEIMDALL_ENROLL_BUDGET_MAX` | 50 | deployment-wide new enrolls per window | `:104` |
| `HEIMDALL_ENROLL_BUDGET_WINDOW` | 3600 | that window, seconds | `:105` |

These apply in **both** postures — they are not the open-mode-only controls
(`deploy-public-surface.sh:405-407`, `:43-44`). The live values above are already exactly these
defaults, so a rebuild reasserts them identically. Re-assert command if ever needed:

```bash
gcloud run services update heimdall-cp-public --region=us-central1 --project=heimdall-cp-prod \
  --update-env-vars=HEIMDALL_ENROLL_IP_LIMIT=5,HEIMDALL_ENROLL_IP_WINDOW=60,HEIMDALL_ENROLL_MAX_KEYS=1000,HEIMDALL_ENROLL_BUDGET_MAX=50,HEIMDALL_ENROLL_BUDGET_WINDOW=3600
```

One caveat worth knowing: `HEIMDALL_ENROLL_IP_LIMIT` defaults *tighter* in open mode (5) than in
token mode (10) — `cp_publicsurface.py:240`. Because the service sets it explicitly to 5, and an
explicit value always wins, closing the posture keeps the tighter 5. Nothing to do; just don't be
surprised that the closed posture is running the open-mode default.

### Two rebuild hazards, both real

1. **Any rebuild flips the posture to closed on its own.** `go-live.sh:58` and
   `deploy-public-rr.sh:69` both default `ENROLL_OPEN=0`. So a rebuild silently reverts an open
   posture. If open is wanted after a rebuild, it must be passed explicitly
   (`ENROLL_OPEN=1 bash deploy/cloud-run/go-live.sh` — `GO-LIVE-RUNBOOK.md:286-291`).

2. **Running `deploy-public-surface.sh` directly would strip the PKI seed.** It defaults
   `PUBLIC_PKI_SECRET=""` (`deploy-public-surface.sh:109`), and the seed + server HAID are only
   written on the non-empty path (`:411-416`). The live service has both
   (`HEIMDALL_CP_PKI_KEY=cp-pki-key-public`, `HEIMDALL_CP_SERVER_HAID=cp-public-server`), so a
   bare direct run would **drop** them. `go-live.sh` is safe — it defaults
   `PUBLIC_PKI_SECRET=cp-pki-key-public` (`go-live.sh:59`) and `PUBLIC_SERVER_HAID=cp-public-server`
   (`go-live.sh:61`), matching live. Prefer `go-live.sh`; if `deploy-public-surface.sh` is run
   directly, pass both vars.

---

## 2. Session 1 step 4 — the live isolation test

`heimdall-live-isolation-test.md` is not on disk. The five checks below are reconstructed from
`.planning/settings.json:51` (the `live_verify` recipe), `.planning/settings.json:47` (the
`isolation_oracle` recipe), and `docs/team-validation-runbook.md` §4.

**I ran checks 1, 2, 3 and 5 live (all read-only) and the local oracle. All pass.** Check 4 is the
only one that writes, so I did not run it — it is yours.

### Check 1 — `GET /readyz` → 200

```bash
curl -s -o /dev/null -w '%{http_code}\n' https://heimdall-cp-public-eqfrs7sfuq-uc.a.run.app/readyz
```

Expected `200`. **Observed `200`**, body:

```json
{"status":"ready","booted":true,"routes_registered":27,"stores_reachable":true,"backend":"firestore","backend_ready":true,"version":"1.0"}
```

`backend_ready: true` and `stores_reachable: true` mean Firestore is genuinely reachable, not just
that the process is up.

### Check 2 — `GET /config` → 200

```bash
curl -s https://heimdall-cp-public-eqfrs7sfuq-uc.a.run.app/config
```

Expected `200`. **Observed `200`**, body:

```json
{"beat_interval_s":20,"refresh_interval_s":15,"ttl_s":45,"tier":0}
```

### Check 3 — unsigned `POST /corpus` → 401

The negative check: the PKI chokepoint must reject an unsigned write. It writes nothing — the
request is refused before any state change, which is why it is safe to run.

```bash
curl -s -o /dev/null -w '%{http_code}\n' -X POST \
  https://heimdall-cp-public-eqfrs7sfuq-uc.a.run.app/corpus \
  -H 'Content-Type: application/json' -d '{}'
```

Expected `401`. **Observed `401`**, body `{"error": "missing_signature"}`.

### Check 4 — beat → own watchman visible on `roster-team`

**This is the one check that mutates** (a presence beat writes a roster record). It self-expires:
`ttl_s: 45` from check 2. Not run here. From `docs/team-validation-runbook.md:81, 135, 143-151`:

```bash
cd /Users/rj/Downloads/heimdall
bin/heimdall-presence beat
bin/heimdall-presence roster --json | python3 -c "
import json,sys
d = json.load(sys.stdin)
haids = [e.get('haid') for e in d.get('online', [])]
print('HAIDs on roster:', haids)
assert haids, 'FAIL: empty roster — beat did not propagate'
print('PASS: %d entry/entries' % len(haids))
"
```

Expect your own HAID present. Per `docs/team-validation-runbook.md:151`, an empty roster on the
first try is not necessarily a failure — the beat may not have propagated. Re-beat and retry
before treating it as red.

### Check 5 — cross-tenant denial

Two halves. The **local oracle** (`.planning/settings.json:47`):

```bash
cd /Users/rj/Downloads/heimdall
bin/falsify rr-multitenant-isolation --assert-score 1.0
```

Expected `SCORE: 6/6 = 1.0000`. **Ran it — passes**, verbatim tail:

```
SCORE: 6/6 = 1.0000 (golden passing)
ASSERT PASS: score 1.0000 >= target 1.0 (golden passed, no mutant survived)
```

All six mutants killed (`drop-team-covers-repo`, `accept-request-team-id`,
`drop-cred-partition-key`, `drop-queue-partition-key`, `resolve-install-from-param`,
`public-surface-dispatch`) — per
`evals/oracles/rr-multitenant-isolation/COVERAGE.md:30-44`.

The **live** half — `docs/team-validation-runbook.md:317-351`, all read-only GETs. Ran all three:

```bash
PUB=https://heimdall-cp-public-eqfrs7sfuq-uc.a.run.app
PROJECT='github.com/randomittin/heimdall'
Q=$(python3 -c "import urllib.parse;print(urllib.parse.quote('$PROJECT'))")

# 4.1 — no secret header -> 403
curl -s -w '\n%{http_code}\n' "$PUB/roster-team?project=$Q"

# 4.2 — random secret -> 200 with online=[] (no other team's data leaks)
RAND=$(python3 -c 'import secrets;print(secrets.token_urlsafe(32))')
curl -s -w '\n%{http_code}\n' -H "X-Heimdall-Team-Secret: $RAND" "$PUB/roster-team?project=$Q"

# 4.3 — /roster-public retired -> 403
curl -s -w '\n%{http_code}\n' "$PUB/roster-public?project=$Q"
```

**Observed, all as expected:**

| Check | Expected | Observed | Body |
|---|---|---|---|
| 4.1 no secret | 403 | **403** | `{"error":"team_secret_required","online":[]}` |
| 4.2 random secret | 200, `online=[]` | **200, `online=[]`** | `{"project":"github.com/randomittin/heimdall","online":[]}` |
| 4.3 roster-public | 403 | **403** | `{"error":"roster_public_retired","online":[]}` |

### One anomaly found — `/healthz` 404s live

`GET $PUB/healthz` returns **404**, not 200. `/healthz` is in the canonical public route set
(`deploy/cloud-run/deploy-public-surface.sh:78`) and in the allowlist
(`bin/lib/cp_publicsurface.py:181`), so this is a genuine gap between the documented contract and
the deployed service. It matters practically because
`docs/team-validation-runbook.md:20` uses `/healthz` as its reachability probe — that step will
fail as written. `/readyz` works and is the strictly better probe anyway (it proves backend
reachability, not just liveness). Not a blocker for the five checks above; flagging it because it
will bite whoever runs the team-validation runbook verbatim.

---

## 3. Session 2 — GitHub repo About

**FIX 1.1's canonical text cannot be established from source.** `heimdall-fix-document.md` does
not exist anywhere on disk. The description and topics below are **candidates only** — they exist
so there is something concrete to react to, not to substitute for your canonical decision.

Verified absent:

```
$ find /Users/rj/Downloads -iname 'heimdall-fix-document.md' -o -iname 'heimdall-seo-geo-spec.md'
(no results)
```

Two prior agents hit this same wall independently and reached the same conclusion — A3
(`.planning/A3-PENDING-POSITIONING.md:1-16`) and A6 (`launch-docs/SUBMISSIONS.md:56-66`). **The
candidates below deliberately reuse their A/B/C lettering**, so one letter from you fills every
surface at once.

### Current state on GitHub (confirmed, `gh repo view --json name,description,repositoryTopics`)

Current description — note it is already a strong positioning line, not a placeholder:

> Verification gates for AI coding agents — nothing ships unproven. Falsifiable oracle gates, team wall, receipts. Works with Claude Code today; Cursor, Codex, Gemini CLI & every git repo next.

Current topics — 16, verbatim:

```
ai-coding, anthropic, claude-code, claude-plugin, cli, developer-tools, devtools,
ai-code-quality, code-quality, code-review, cursor, gemini-cli, git-hooks, mcp,
testing, verification
```

### The real decision underneath this — worth seeing before picking a letter

The repo currently states **two different positionings**, and they are not variants of one idea:

- **GitHub About** (above) says Heimdall is *verification gates* — a gate you put in front of AI
  coding agents.
- **`README.md:3`** says: *"A cloud bot that fixes your GitHub issues and opens a proven PR. You
  review, you merge."* — an agent that does work for you.

Both are defensible and both are backed by shipped code. But a visitor reading the About line and
then the README meets two different products. That mismatch — not the missing file — is what FIX
1.1 most plausibly exists to resolve. The candidates below are the three coherent resolutions.

### Candidate description lines — candidate, awaiting RJ's canonical FIX 1.1

| # | Line | Source | Reads as |
|---|---|---|---|
| **A** | `Nothing ships unproven.` | `IDENTITY.md:18` `tagline:` — canonical | The tagline. 23 chars. Pairs with a longer sentence; too terse to carry About alone. |
| **B** | `A cloud bot that fixes your GitHub issues and opens a proven PR. You review, you merge.` | `README.md:3` verbatim | The *bot* positioning. Resolves the mismatch toward the README. |
| **C** | `Verification gates for AI-written code: every plan wires an external, falsifiable oracle so the merge stays blocked until the work is proven correct.` | Paraphrase of `README.md:37`; A6's Candidate C | The *gate* positioning. Closest to today's About line. |

A6 defaults to **Candidate A** inline (`launch-docs/SUBMISSIONS.md:64`). It appears **11 times** in
that file (`grep -c POSITIONING_LINE launch-docs/SUBMISSIONS.md` → `11`), so one find/replace
fills them all. A6 also notes A is the only one that fits Product Hunt's ≤60-char tagline field
(`SUBMISSIONS.md:250`).

My read, offered as a recommendation rather than a finding: **B**. GitHub's About is the line that
decides whether someone clicks, and "fixes your issues and opens a proven PR" is a concrete
outcome where "verification gates" is a category. It also aligns About with the README instead of
leaving the two fighting. A is the better *tagline* and should stay exactly where it is — it is
already canonical in `IDENTITY.md:18` — but it is too abstract to carry About on its own.

If it goes to npm's `description` too, note A3's constraint: npm truncates at roughly 100-120 chars
in search results (`.planning/A3-PENDING-POSITIONING.md`), and B is 86 chars — it fits; C does not.

### Candidate topics — candidate, awaiting RJ's canonical FIX 1.1

The current 16 are already well-chosen. This is a small delta, not a rewrite:

**Add** (each defensible from repo truth):

| Topic | Justification |
|---|---|
| `github-app` | `README.md:5` — "as a scoped GitHub App" |
| `ai-agents` | broader than the existing `ai-coding`; the common search term |
| `npx` | the `runheimdall` wrapper is a real entry point |
| `self-hostable` | `OPERATORS.md` + MIT `LICENSE`; A3 cites this |

**Remove** — nothing. GitHub caps topics at 20; 16 + 4 = 20, exactly at the ceiling. If you want
headroom, `devtools` duplicates `developer-tools` and is the one I would drop first.

`cursor`, `gemini-cli`, `codex` are worth a deliberate look: the About line promises them "next",
so the topics are making a forward-looking claim. That is a positioning call, not a fact I can
settle from source.

Apply with:

```bash
gh repo edit randomittin/heimdall --description "<chosen line>"
gh repo edit randomittin/heimdall --add-topic github-app,ai-agents,npx,self-hostable
```

### The v1.1.0 release-title rename — already done, no action needed

```
$ gh release view v1.1.0 --json tagName,name,createdAt
{"createdAt":"2026-04-19T05:07:31Z","name":"v1.1.0","tagName":"v1.1.0"}
```

The title is **already** `v1.1.0`. The rename step is a **no-op** — skip it.

Worth noting what the runbook may have actually meant: **`v1.0.0`** still carries a superx-era
title that has nothing to do with Heimdall —

```
$ gh release view v1.0.0 --json tagName,name
{"name":"v1.0.0 — superx pixel dashboard + single-phase orchestration","tagName":"v1.0.0"}
```

If the intent was "make the old release titles consistent", `v1.0.0` is the one that needs it, not
`v1.1.0`. I have not changed it. `gh release edit v1.0.0 --title "v1.0.0"` would do it.

---

## 4. Session 3 step 7 — npm

### Publish from `packages/runheimdall`, not the repo root

This is the trap worth naming first: the **root** `package.json` is a different package entirely —
`name: "triv", version: "1.0.1"`. Running `npm publish` from `/Users/rj/Downloads/heimdall` would
not publish Heimdall. The real package is at
`/Users/rj/Downloads/heimdall/packages/runheimdall/package.json`: `name: "runheimdall"`,
`version: "2.2.6"`.

### Established facts

| Fact | Value | Source |
|---|---|---|
| Published npm version | `2.0.5` | `npm view runheimdall version` |
| Repo/manifest version | `2.2.6` | `packages/runheimdall/package.json:3`, `VERSION`, `.claude-plugin/plugin.json` |
| `v2.2.6` tag exists | yes, at `8a28870` | `git rev-parse v2.2.6` |
| Pinned install.sh sha256 | `fafe31e…585b33` | `packages/runheimdall/package.json` `heimdall.sha256` |
| Pin matches live tag | **verified match** | see below |

The integrity precondition passes — I fetched the tag's `install.sh` and hashed it:

```
live  https://raw.githubusercontent.com/randomittin/heimdall/v2.2.6/install.sh
      -> fafe31e30b481882a43ab93aaab742b1e90b0d4bde31498aa8f58f3f23585b33
pin   package.json heimdall.sha256
      -> fafe31e30b481882a43ab93aaab742b1e90b0d4bde31498aa8f58f3f23585b33
MATCH
```

So the package is safe to publish from an integrity standpoint. The only reason to wait is §3.

### Publish AFTER the §3 decision — why, concretely

The `files` allowlist is `["bin/runheimdall.js", "README.md"]`
(`packages/runheimdall/package.json`). Two consequences:

1. **`README.md` ships to npm and becomes the rendered npm package page.** It already carries a
   positioning line — `packages/runheimdall/README.md:3`: *"The npm-native door to Heimdall —
   Nothing ships unproven."* If §3 changes the positioning line, this file changes, and the npm
   page is stale until republished.
2. `package.json`'s `description` and `keywords` are npm-page surfaces too. Current values:
   `description: "Thin npx wrapper for the Heimdall installer — fetches the pinned-tag
   install.sh, verifies its sha256, and runs it. Byte-identical to runheimdall.dev/install."`;
   `keywords: ["heimdall","installer","verification","claude-code"]`.

npm versions are immutable — a republish needs a fresh version number. Publishing 2.2.6 now and
then landing §3 means either shipping a stale npm page or burning 2.2.7 purely for text. **Land §3
first, then publish once.**

Note the `description` is scoped to the *wrapper*, not to Heimdall as a product, so §3 may
legitimately leave it alone. The README tagline is the surface most likely to move.

### The sequence

`v2.2.6` is already tagged and its `install.sh` digest already matches the pin, so steps 1-2 of
`release/publish-checklist.md` are satisfied. What remains is step 3
(`release/publish-checklist.md:42-50`):

```bash
cd /Users/rj/Downloads/heimdall/packages/runheimdall

# 1. confirm identity + pin (should print runheimdall / 2.2.6 / v2.2.6 / 64-hex)
python3 -c "import json;d=json.load(open('package.json'));print(d['name'],d['version'],d['heimdall']['tag'],d['heimdall']['sha256'])"

# 2. see exactly what would ship — expect ONLY bin/runheimdall.js, README.md, package.json
npm pack --dry-run

# 3. confirm you are the right npm identity
npm whoami

# 4. publish  (RJ-EXECUTED — publish-checklist.md:47 says never from an agent)
npm publish --access public
```

Verify:

```bash
npm view runheimdall version          # expect 2.2.6
npm view runheimdall dist.tarball
```

Then `release/publish-checklist.md:77`: `npx runheimdall` in a fresh HOME should print
`verified install.sh (v2.2.6, …)` and install.

The 2.0.5 → 2.2.6 jump also closes the historical downgrade bug that `ship.sh:558-561` describes,
where a stale `DEFAULT_REF` made a fresh install fetch v2.0.5.

---

## 5. Orphaned releases

### A5's finding is confirmed — and reproduced

All three versions have a `chore(release)` commit, and **no tag either locally or on origin**:

| Version | Bump commit | Manifest at that commit | Tag local | Tag origin |
|---|---|---|---|---|
| v2.2.3 | `f6c5f10` | `2.2.3` | none | none |
| v2.0.17 | `68353df` | `2.0.17` | none | none |
| v2.0.13 | `b0616d5` | `2.0.13` | none | none |

Verified with `git rev-parse -q --verify refs/tags/<t>` and
`git ls-remote --exit-code --tags origin refs/tags/<t>`. The tag list confirms the holes:
`… v2.0.12, v2.0.14 …` (no 13), `… v2.0.16, v2.0.18 …` (no 17), `… v2.2.2, v2.2.4 …` (no 3).

### `--release-only` cannot reconcile these as-is — this contradicts the task premise

This is the important correction. `--release-only` publishes **the version currently in the
manifest**, not a version you name:

- `release/ship.sh:507` — `RO_VERSION="$(read_version)"`, then `TAG="v$RO_VERSION"` (`:508`)
- `release/ship.sh:82-87` — `read_version()` reads `.claude-plugin/plugin.json`
- `release/ship.sh:80` — `PLUGIN_MANIFEST=".claude-plugin/plugin.json"`
- It takes **no version argument** (`release/ship.sh:377` — `--release-only) RELEASE_ONLY=1; DO_BUMP=0`)

The manifest is now at `2.2.6`, which is already tagged. So running `release/ship.sh --release-only`
from `main` today would act on **v2.2.6, not v2.2.3** — it would find the tag exists
(`ship.sh:515-517`) and re-publish/update the v2.2.6 Release. It would not touch the orphans.

What A5 actually shipped is the *guard* — `reconcile_orphan_release()` (`ship.sh:446-456`) refuses
a future bump that would strand the current version, and `preflight_release_prereqs`
(`ship.sh:538`) proves a release is possible before mutating anything. That prevents the **next**
orphan. `--release-only` recovers an orphan **caught at the moment it happens**, while the manifest
still reads that version. It is not a time machine for orphans already bumped past.

### To reconcile a historical orphan, the manifest must read that version

Since the manifest read `2.2.3` at `f6c5f10` (verified above), checking that commit out detached
makes `read_version()` return `2.2.3`, and `git tag` (`ship.sh:513`) tags **that** commit. Oldest
first, so `prev_release_tag`'s notes ranges come out in order:

```bash
cd /Users/rj/Downloads/heimdall
git status --porcelain          # MUST be clean first
git fetch --tags origin

# --- v2.0.13 ---
git checkout b0616d5            # detached; manifest here reads 2.0.13
release/ship.sh --dry-run --release-only     # PROVE IT FIRST — mutates nothing, ship.sh:458-498
release/ship.sh --release-only               # tags v2.0.13 at b0616d5, pushes, publishes notes

# --- v2.0.17 ---
git checkout 68353df
release/ship.sh --dry-run --release-only
release/ship.sh --release-only

# --- v2.2.3 ---
git checkout f6c5f10
release/ship.sh --dry-run --release-only
release/ship.sh --release-only

git checkout main               # ALWAYS return to main
git fetch --tags origin
git tag --list 'v2.*' | sort -V # expect v2.0.13, v2.0.17, v2.2.3 now present
```

**Run `--dry-run --release-only` for each one before the real run.** It prints the exact
`gh release` invocation and the exact notes body, then exits 0 having mutated nothing
(`ship.sh:458-498`) — that is how you confirm it resolved the version you meant before anything
becomes permanent.

What each real run does, per source: tags if absent (`:512-514`), pushes the tag (`:518`, tolerates
already-on-origin), builds notes (`:521`), publishes (`:522`), signs and attaches
`install.sh.minisig` (`:523`), prints
`✓ Released vX.Y.Z — https://github.com/randomittin/heimdall/releases/tag/vX.Y.Z` (`:524-525`).

### Three cautions

1. **Detached HEAD is required, and returning to `main` is on you.** Forgetting `git checkout main`
   leaves the worktree detached.
2. **Tags are effectively immutable once pushed.** `release/publish-checklist.md:31` — *"never
   re-point an existing one"*. The dry run is the cheap insurance.
3. **These runs push tags and create public GitHub Releases** — outward-facing and hard to reverse.
   Nothing above was run. All three are yours to execute.

If publishing three historical Releases has no real audience value, the honest alternative is to
leave the holes and let the guard prevent new ones. The version numbers are already spent either
way; nothing downstream resolves `v2.2.3`.

---

## 6. Dependency summary

| Item | Status | Blocked on |
|---|---|---|
| §1 step 5 — enroll posture flip | **UNBLOCKED** | nothing — exact command in §1, token secret confirmed mounted |
| §1 step 4 — live isolation test | **UNBLOCKED** | nothing — 4 of 5 checks run and passing; check 4 (beat) is yours, it writes |
| §2 — GitHub About description | **BLOCKED** | `heimdall-fix-document.md` (FIX 1.1) absent from disk — candidates A/B/C only |
| §2 — GitHub topics | **BLOCKED** | same — current 16 confirmed; +4 candidate delta |
| §2 — v1.1.0 release-title rename | **NO-OP** | already titled `v1.1.0` — verified, skip it |
| §3 — SEO/GEO surfaces | **BLOCKED** | `heimdall-seo-geo-spec.md` absent from disk |
| §3 step 7 — npm publish | **SEQUENCED** | not blocked technically (pin verified, tag live) — but publish *after* §2/§3 positioning lands, or you publish twice |
| §5 — orphan reconcile | **UNBLOCKED, premise corrected** | nothing — but `--release-only` needs a detached checkout per orphan, not a flag argument |

The two missing spec files are the whole of the remaining blockage, and they block one decision,
not many: the positioning line. It propagates to the GitHub About, the `{{POSITIONING_LINE}}`
placeholder in `launch-docs/SUBMISSIONS.md`, `packages/runheimdall/README.md:3` (which ships to
npm), and the npm `description`/`keywords`. Deciding it once unblocks §2, §3, and releases the npm
publish in a single move.

---

## What was established from source vs. not

**Answered from source / real command output — 5 of 6:** §1 (env var name, live posture, caps,
flip command), §2 (all five checks; four run live and passing), §4 (npm paths, versions, sha256
verified against the live tag), §5 (orphan commits, manifest versions, tag absence confirmed local
+ origin + GitHub Releases, `--release-only` semantics read from source), §6.

**§3 — partially cannot establish.** Established from real `gh` output: the current GitHub
description, the current 16 topics, and the v1.1.0 release title (already `v1.1.0` — a no-op).
**Cannot establish from source:** FIX 1.1's canonical description and topics
(`heimdall-fix-document.md` not on disk) and the §3 SEO/GEO surface list
(`heimdall-seo-geo-spec.md` not on disk). Everything offered for those is marked candidate and is
not canonical.

**Three findings that contradict the task's premises**, each worth reading before acting:

1. **§5 — `--release-only` cannot reconcile the orphans by itself.** It publishes whatever version
   the manifest currently holds (`ship.sh:507`), which is now 2.2.6. Reaching v2.2.3 requires a
   detached checkout of `f6c5f10` first. A5's flag prevents the *next* orphan; it does not
   retroactively fix these three.
2. **§3 — the v1.1.0 rename is already done.** `v1.0.0` is the release carrying a stale
   superx-era title, if consistency was the actual goal.
3. **§2 — `/healthz` 404s live** despite being in the canonical public route set
   (`deploy-public-surface.sh:78`, `cp_publicsurface.py:181`). It breaks
   `docs/team-validation-runbook.md:20` as written. Use `/readyz`.

**Nothing was deployed, pushed, published, or mutated.** Every live call was read-only: a `gcloud
run services describe`, GETs, unsigned POSTs rejected before any write, and read-only `gh`/`npm`
queries. The one check that writes (§2 check 4, the presence beat) was deliberately left for RJ.
