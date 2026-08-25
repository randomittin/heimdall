# OmniRoute as an exhaustion-fallback TRANSPORT — assessment

**Date:** 2026-08-25 · **Scope:** narrower than `2026-08-23-omniroute-assessment.md`
(cost-routing, verdict NO — not re-litigated here). This asks only: when Claude
capacity is genuinely exhausted mid-task, can `claude -p` be pointed at a
locally-hosted OmniRoute so work continues on the operator's own third-party
keys? Investigation only — no code written, nothing installed or configured.

## Verdict: GO-WITH-CAVEATS on transport mechanics, NO-GO on shipping today

The **transport question the brief opened with has a clean, well-sourced YES**:
OmniRoute exposes a genuine Anthropic-shaped `/v1/messages` endpoint, and
Claude Code's own officially documented mechanism for pointing at *any* gateway
(`ANTHROPIC_BASE_URL` + `ANTHROPIC_AUTH_TOKEN`/`ANTHROPIC_API_KEY`) is exactly
what OmniRoute's own Claude Code guide instructs operators to set. This is not
a hack or an undocumented seam on either side — it is the supported path on
both.

That YES does not clear the feature to ship, for three independent reasons
found in this pass, each sufficient alone:

1. **Tier-1 OAuth-reuse cannot be verifiably disabled.** No config flag in
   OmniRoute's own `ENVIRONMENT.md` / `FEATURE_FLAGS.md` turns off the
   "Tier 1 Subscription (Claude Code, Codex, Copilot)" cascade step the prior
   assessment already flagged as a likely ToS breach landing on the operator's
   own account. Per the brief's own instruction, this is a **blocking finding**
   — the feature must not ship without one, and this pass did not find one.
2. **Prompt caching cannot survive a route to either of the two backends the
   owner reports are actually used in practice (Mistral, LLM7).** OmniRoute's
   own translator only preserves Anthropic `cache_control` breakpoints for a
   provider explicitly flagged caching-capable (DashScope/Alibaba is the named
   case in source); neither Mistral's nor LLM7's registry entry carries that
   flag, so a fallback request to either backend forfeits the 0.1×-cache-read
   pricing this repo's own cost forensics identified as the mechanism holding
   spend down today (see `token-spend-forensics.md`, 95.56% cache-read ratio).
   This is a structural loss, not a tuning problem — OpenAI-shaped chat
   completions (what both backends speak) has no cache_control concept at all.
3. **Neither Mistral nor LLM7 clears this repo's own ZDR-equivalent bar,** and
   for LLM7 specifically the shape is exactly what the ToS-conflict flag exists
   to catch — see §4 below.

**What IS clean:** if this ships at all, it should ship as a **hand-picked
allowlist naming Mistral only, with the operator's own paid Mistral API key,
pinned so OmniRoute's cascade cannot substitute LLM7 or anything else** — not
a blanket "fall back to OmniRoute." That narrower shape is mechanically
supported (see §5) but still blocked on finding #1 above (Tier-1 must be
provably off regardless of which backend the allowlist names, since the
cascade step sits above per-provider selection).

---

## 1. Does OmniRoute expose an Anthropic-shaped endpoint?

**READ, verified from source at commit `d82b68274c75c14d258b4898a34edc25d9712b87`
on branch `release/v3.8.51`** (this repo's default branch moves faster than its
git tags — latest tag `v3.8.49` is dated 2026-07-29 while `pushed_at` is
2026-08-25, so a tag pin would be stale; pinning by commit SHA instead, noted
here for reproducibility).

`src/app/api/v1/messages/route.ts` exists and is a real, wired handler, not a
stub:

```ts
/**
 * POST /v1/messages - Claude format (auto convert via handleChat)
 */
async function postHandler(request, context, preParsedBody = null) { ... }
export const POST = withChatAdmission(withInjectionGuard(postHandler));
```

Its own code comment names the exact client this path was built for:

> "Streaming Anthropic clients (Claude Code, the Anthropic SDK) drop the
> connection when no bytes arrive while a large prompt is processed before the
> first token... OmniRoute holds the response until the first useful upstream
> byte... keep the connection warm with early keepalives... emit a real
> `event: ping` (`ANTHROPIC_PING_FRAME`)."

OmniRoute *also* exposes the OpenAI shape (`src/app/api/v1/chat/completions/route.ts`)
— it is not either/or, it runs both `/v1/messages` (Anthropic) and
`/v1/chat/completions` (OpenAI) side by side, with a bidirectional translator
layer between them (`open-sse/translator/request/{claude-to-openai,openai-to-claude}.ts`,
`open-sse/translator/response/{claude-to-openai,openai-to-claude}.ts`).

**Answer: Anthropic-shaped, confirmed from source, not inferred.**

## 2. Can `claude -p` be pointed at a non-Anthropic base URL?

**READ, from Anthropic's own official docs** (`code.claude.com/docs/en/llm-gateway`
and `.../llm-gateway-connect` — the `docs.claude.com` URLs from the brief now
301-redirect here; fetched 2026-08-25):

- `ANTHROPIC_BASE_URL` is "the variable that points Claude Code at the
  gateway." Set alone (no credential), it does **not** replace the
  subscription — requests still carry the saved claude.ai login. A credential
  variable is required to actually switch billing/quota off the subscription.
- Two credential variables, either sufficient: `ANTHROPIC_AUTH_TOKEN` (sent as
  `Authorization: Bearer …`, "your gateway team said 'bearer token'") or
  `ANTHROPIC_API_KEY` (sent as `x-api-key`, "your gateway team said 'API
  key'"). The doc's own verification curl is literally:
  ```
  curl "$ANTHROPIC_BASE_URL/v1/messages" \
    -H "Authorization: Bearer $ANTHROPIC_AUTH_TOKEN" \
    -H "anthropic-version: 2023-06-01" \
    -H "content-type: application/json" -d ...
  ```
  — the exact same `/v1/messages` path OmniRoute's own route handler answers.
- **Conflicts with an existing login, resolved explicitly:** "A gateway
  credential variable takes precedence over a saved claude.ai login or Console
  key... With `ANTHROPIC_AUTH_TOKEN`, the variable takes precedence
  immediately." `/status` shows which credential source is active; `/logout`
  clears a saved login if only the gateway credential should remain.
- **"The CLI reads the environment variables and settings files above"** —
  the docs explicitly confirm this covers the CLI surface (which `claude -p`
  runs as, headless mode of the same binary), distinct from the VS Code
  extension / desktop app / Agent SDK / cloud surfaces, which are covered
  separately in the same doc.
- The provider-abstraction seam the brief hypothesized from Bedrock/Vertex
  support is real and is this exact mechanism — `ANTHROPIC_BASE_URL` is the
  same variable Bedrock/Vertex/Foundry gateway configs use.

**Cross-checked against OmniRoute's own `docs/guides/CLAUDE-CODE-CONFIGURATION.md`**
(same commit), which independently describes the identical variable set
(`ANTHROPIC_BASE_URL` "no `/v1` suffix — Claude Code appends `/v1/messages`",
`ANTHROPIC_AUTH_TOKEN`, `ANTHROPIC_API_KEY`) from the gateway-author's side —
the two sources agree exactly, one written by Anthropic, one by OmniRoute,
neither citing the other.

**Answer: yes, confirmed from Anthropic's own primary documentation, not
inferred and not taken on OmniRoute's word alone.** `claude-code-guide` was not
reachable as a callable agent in this session (no such tool was exposed to this
run); the above substitutes direct primary-source verification, which the
brief's own standard ("Do NOT guess") requires regardless.

## 2b. Passthrough vs. normalization — does `cache_control` (and the 1M beta header) survive?

**Load-bearing for the cost verdict, so checked directly in source** (same
commit, `open-sse/translator/request/claude-to-openai.ts`):

- `cache_control` preservation through the Claude→OpenAI translation path is
  **gated behind an explicit per-provider capability flag**
  (`credentials._preserveCacheControl === true`), with the source comment
  naming the intended beneficiary explicitly: *"when the routed provider
  honors OpenAI-format cache_control breakpoints (DashScope/alibaba, etc.)...
  keep the client's cache_control markers... Otherwise fall back to the
  joined-string form expected by generic OpenAI providers."*
- Neither `open-sse/config/providers/registry/mistral/index.ts` nor
  `.../llm7/index.ts` sets this flag (READ — both files are 18 and 27 lines,
  reproduced in full in §4; neither references caching capability at all).
  **INFERRED from the absence of the flag** (not proven by tracing every
  credentials-object construction site in this pass): a request routed to
  Mistral or LLM7 through OmniRoute collapses to the plain joined-string
  system prompt, and the client's cache breakpoints are dropped.
- This is not a bug to fix — OpenAI's `chat/completions` schema has no
  `cache_control` concept at all, so there is nothing on the wire for Mistral
  or LLM7 to honor even if OmniRoute forwarded the field. The loss is
  structural to routing an Anthropic-shaped request to an OpenAI-shaped
  first-party API, not a missing feature in OmniRoute.
- The `anthropic-beta: context-1m-2025-08-07` header has zero references
  anywhere in `claude-to-openai.ts` (grepped, zero matches) — moot for the
  same reason: OpenAI's schema has no header equivalent, and Mistral's/LLM7's
  actual context windows are dictated by their own models, not by anything
  Claude Code requests.
- **Net effect on the cost math**: this reconfirms, now as a structural fact
  for these two specific backends rather than a general inference, §4 of the
  2026-08-23 assessment ("provider-hopping forfeits the thing that is already
  working") — a fallback turn to Mistral or LLM7 starts from zero cache every
  time, with no cache ever available on that path to lose incrementally; it
  is not merely more expensive than expected, prompt caching cannot apply to
  these two routes at all.

## 3. If (1) and (2) are incompatible — is `cursor-agent` a real alternative?

They are **not** incompatible (see verdict above) — but the "own-keys, no
Anthropic transport at all" framing is still worth a straight answer, and
`cursor-agent` **is installed on this machine**:

```
$ which cursor-agent
/Users/rj/.local/bin/cursor-agent
$ cursor-agent --version
2026.08.11-e8db854
```

(READ — command output, not inferred.) `cursor-agent` is Cursor's CLI agent,
built OpenAI-compatible-friendly (multi-provider by design), so it is a
plausible EXECUTOR for a genuinely-OpenAI-shaped fallback path (LLM7, or a
BYOK OpenAI-compatible provider) without needing Claude Code's transport at
all.

**What hmd would lose, stated plainly, not softened:**

- **Every `hmd:<role>` agent definition** this repo's architect/coder/reviewer/
  verifier/etc. roles are built on is a Claude Code subagent construct — there
  is no equivalent concept `cursor-agent` reads natively.
- **The entire hook stack** (`hooks.json` — PreToolUse content scans, the
  `git push` quality-gate chain, `prepare-commit-msg` trailer injection,
  PostToolUse `edit-tracker`, SessionStart `resume-hint`/`quota-resume`) is
  Claude Code's own hook surface. None of it fires under `cursor-agent`.
- **Every skill in `skills/heimdall/`** (brainstorming, writing-plans,
  systematic-debugging, the oracle-gate protocol this very document's parent
  agent type is bound by) is invoked through Claude Code's `Skill` tool.
  `cursor-agent` has no such mechanism.
- **Worktree conventions** (`superpowers:using-git-worktrees`, the
  parallel-wave dispatch model, `bin/heimdall-agent-resume`'s subagent
  termination classification) assume Claude Code's `Agent`/`Task` primitives.
- Net: `cursor-agent` as a fallback executor is not "hmd running on a
  different transport" — it is a **different, much thinner tool** that would
  need its own from-scratch equivalents of all of the above to reach parity.
  That is a real cost, not a rounding error, and should be named as such to
  whoever evaluates this path rather than assumed away.

## 4. Own-keys mode without Tier-1 — and the Mistral/LLM7 concrete case

### 4a. Tier-1 disable: NOT FOUND — blocking

Searched `docs/reference/ENVIRONMENT.md` (1635 lines) and
`docs/reference/FEATURE_FLAGS.md` (241 lines), same commit, for any flag
naming tier-1/subscription-reuse/own-keys-only. The only tier-1-adjacent hit
is unrelated:

```
BIFROST_ENABLED | 1 | ... | Master kill switch for the bifrost sidecar proxy.
... Use to disable the sidecar without redeploying (tier-1 router incident, key rotation).
```

This is an operational incident killswitch for a sidecar process, not a
routing-policy flag that excludes the Tier-1 subscription-reuse cascade step
from ever being selected. **No config was found in this pass that verifiably
disables Tier-1.** Per the brief: this is a blocking finding. The feature must
not ship without one, and none exists in the searched surface — this is not
"unlikely to matter," it is "not found," stated as instructed rather than
assumed safe.

### 4b. Mistral — READ from source, structurally clean; ToS training status UNVERIFIED

`open-sse/config/providers/registry/mistral/index.ts`, in full:

```ts
export const mistralProvider: RegistryEntry = {
  id: "mistral", alias: "mistral", format: "openai", executor: "default",
  baseUrl: "https://api.mistral.ai/v1/chat/completions",
  authType: "apikey", authHeader: "bearer",
  models: [ /* mistral-large-latest, mistral-medium-3-5, mistral-small-latest,
               devstral-latest, codestral-latest */ ],
};
```

- **`baseUrl` is Mistral's own official API domain** (`api.mistral.ai`) — this
  is direct-to-first-party routing, not a proxy pool. No `poolConfig` field
  (contrast with LLM7 below) — nothing in this entry manages a shared session
  pool, consistent with "operator supplies one key, requests go straight to
  Mistral under that key."
- OmniRoute's own `docs/reference/FREE_TIERS.md` (its own ToS research,
  already cited in the 2026-08-23 assessment) flags `mistral` **caution**,
  quoting: *"Consumer ToS explicitly states APIs may only be used for
  'personal needs' and prohibits making API keys available to third
  part[ies]."* Read literally, that clause restricts a user from **sharing**
  their key with others — it does not, on its face, forbid an operator
  running a local, single-operator OmniRoute instance under their own key.
  This is a plausible reading, not a confirmed one — I could not independently
  retrieve Mistral's actual terms/DPA text in this pass (the fetch of
  `mistral.ai/terms` returned a page whose rendered text did not contain the
  relevant clauses in the time budget available), so **whether that ToS
  clause's "personal needs" language also restricts hmd's specific
  commercial-coding-agent use case is UNVERIFIED, not established either
  way.**
- **Training/retention: UNVERIFIED, not established as clean.** The
  2026-08-23 assessment already covered this exact gap for `mistral` in its
  ~40-provider "caution/ambiguous" list: *"none of them carries any
  independently verified no-training/no-retention guarantee — none was
  found, none is cited."* This pass did not find one either. Per the ZDR
  standard this repo already applies to Fable 5 (`allow_non_zdr_models`
  required for anything not verified zero-data-retention), **Mistral does not
  clear that bar today** — not because it is confirmed to train on API
  submissions, but because no guarantee that it doesn't was found. Absence of
  a guarantee is treated the same way Fable 5's case treats it: gated, not
  waved through.

### 4c. LLM7 — is an aggregator/reseller, not a first-party provider; fails independent of the ToS flag

`open-sse/config/providers/registry/llm7/index.ts`, in full:

```ts
export const llm7Provider: RegistryEntry = {
  id: "llm7", alias: "llm7", format: "openai", executor: "default",
  baseUrl: "https://api.llm7.io/v1/chat/completions",
  modelsUrl: "https://api.llm7.io/v1/models",
  authType: "apikey", authHeader: "bearer",
  poolConfig: { minSessions: 1, maxSessions: 3, cooldownBase: 2000,
                cooldownMax: 5000, cooldownJitter: 100,
                requestTimeout: 30000, requestJitter: 50 },
  models: [ /* gpt-4o-mini-2024-07-18, gpt-4.1-nano-2025-04-14,
               deepseek-r1-0528, qwen2.5-coder-32b-instruct */ ],
};
```

- **`baseUrl` is `api.llm7.io` — not `api.openai.com`, not any DeepSeek or
  Alibaba/Qwen domain** — while the models it lists are named after OpenAI's,
  DeepSeek's, and Qwen's own model IDs. LLM7 is, structurally, **an aggregator
  reselling access to other companies' models**, not a first-party model
  provider with its own weights. This is exactly the shape the repo owner's
  framing predicted and exactly the shape the 2026-08-23 assessment's
  ToS-conflict flag exists to catch.
- **`poolConfig` is present** (min/max sessions, cooldown, jitter) — the same
  session-rotation-across-a-shared-pool shape OmniRoute uses for its
  free/anonymous-tier providers elsewhere. Mistral's entry has no such field.
  This is a structural, in-source difference between the two providers, not
  an assumption: LLM7 is architecturally treated as a pooled/session-managed
  resource by OmniRoute's own code; Mistral is not.
- OmniRoute's own `FREE_TIERS.md` flags `llm7` **caution**, quoting: *"ToS
  positions the service as for 'experimentation, development, and research';
  no explicit ban on self-hosted personal [use]…"* — i.e. LLM7's own terms
  describe a research/experimentation service, not a commercial API with a
  contractual data-handling posture suited to routing real client code. The
  same doc separately notes the operational reality has drifted since it was
  first catalogued: *"The 'no signup required' claim is now outdated — a free
  token from token.llm7.io is now required."* A free, self-serve token from an
  aggregator's own signup flow is not a commercial account with a DPA; it is
  the same category of relationship as the free-tier pools the 2026-08-23
  assessment already rejected wholesale, even though each operator's LLM7
  token is nominally "their own."
- **Training/retention: no published terms found for LLM7 in this pass**
  (its homepage returned a JS app shell with no static ToS/privacy text within
  the time budget) — **UNVERIFIED, and given the research/experimentation
  framing OmniRoute itself quotes, there is no basis to assume clean absent a
  guarantee.**
- **Independent of data handling — the contractual gap is decisive on its
  own.** Even with a personal LLM7 token, the operator has no relationship of
  any kind with OpenAI, DeepSeek, or Alibaba/Qwen, whoever actually serves the
  request behind LLM7. This is precisely the "no contractual relationship with
  whoever actually serves the request" failure mode named in the follow-up
  brief, and it holds regardless of whatever LLM7's own terms say about
  itself.

### 4d. Own-key vs. pooled — named per provider, as asked

| Provider | Mode as configured in OmniRoute source | Contractual party if operator supplies own key |
|---|---|---|
| Mistral | Direct-to-first-party (`api.mistral.ai`, no `poolConfig`) | Mistral AI, directly |
| LLM7 | Own-token-to-aggregator (`api.llm7.io`, `poolConfig` present) | LLM7 only — no relationship with OpenAI/DeepSeek/Qwen, who actually serve the tokens |

**Conclusion for §4:** Mistral is the structurally cleaner of the two (direct,
no pooling, first-party endpoint) but is not yet verified clean on training/
retention terms. LLM7 fails on two independent grounds regardless of key
ownership: it is an aggregator with no contractual chain to the real model
owner, and its own terms self-describe a research/experimentation service.
Neither clears the ZDR-equivalent bar this repo already holds Fable 5 to.
**And both are moot until §4a's Tier-1 finding is resolved**, since the
cascade sits above per-provider selection in OmniRoute's own architecture.

## 5. Is a hand-picked allowlist workable, and can OmniRoute pin to one provider?

**Yes — and OmniRoute already documents the exact mechanism, independent of
whether Mistral itself ends up cleared.** OmniRoute's model IDs are
provider-prefixed (`<provider>/<model>`, e.g. `glm/glm-5.2`, `kimi/kimi-k2.6`
in its own Claude Code guide), and `ANTHROPIC_MODEL=<provider>/<model>`
pins a specific provider rather than letting the auto-combo/cascade choose.
The same guide's troubleshooting section states this outright: *"Explicit
provider prefixes always win."* So `ANTHROPIC_MODEL=mistral/mistral-large-latest`
(or any single named model) is a real, sourced way to force every request to
one specific, vetted provider and bypass OmniRoute's own fallback cascade for
model selection.

This does **not**, by itself, address §4a — provider pinning controls *which
model answers*, not whether the Tier-1 subscription-reuse step can fire as
part of getting there. An allowlist design is the right shape (name providers
individually, refuse the rest, matching this repo's existing
`allow_non_zdr_models`-style opt-in pattern for Fable 5) but is blocked on the
same open question until Tier-1 is provably disabled or shown never to be
consulted when a model is pinned this specifically.

## 6. Quota-exhaustion detection vs. a transient 529

**READ, from this repo's own code** (`bin/lib/quota_stop.py`,
`bin/heimdall-quota-advisor`, `bin/heimdall-quota-resume` — all already
implemented and shipped, not proposed here):

- The classifier requires **two independent signals to agree** before calling
  anything a quota stop: (1) `ANCHOR_RE = r"hit your [a-z0-9][a-z0-9\- ]{0,24}limit"`
  — the Claude-specific "you're out of quota" phrase — and (2)
  `RESET_RE = r"resets?\s+(\d{1,2}):(\d{2})\s*([ap]m)\s*\(...\)"` — a
  well-formed wall-clock reset clause with a named IANA timezone. Either alone
  classifies `"unknown"`, and `heimdall-quota-resume record` **refuses** to
  write a resume record for `"unknown"` text (module docstring: *"deliberately
  conservative... a generic 'rate limit exceeded' from some unrelated HTTP API
  has neither signal and so can never be mistaken for a quota stop"*).
- **This is precisely the signal that distinguishes exhaustion from a 529.** A
  transient overload error carries no wall-clock reset clause naming a
  specific timezone-local time — there is nothing to retry *until*, only
  "retry with backoff." A genuine quota/session/weekly-limit stop always
  carries both the anchor phrase and a concrete reset instant. The classifier
  encodes the correct differential response directly in its refusal behavior:
  matched on both → retryable-at-a-known-time (wait or fall back); matched on
  neither, or only one → left for a human/normal retry logic, never silently
  treated as a quota window.
- `heimdall-quota-advisor` (the honest, never-auto-switching layer already
  built on top of this) already surfaces OmniRoute by name as option 4 of 4,
  ranked last, with the Tier-1 risk stated plainly in its own output text —
  this document's findings do not change that file, they inform whether
  anything should ever be built to go further than "print the option and stop
  there," which today it correctly does not.

---

## Sources

**Anthropic official docs (primary, fetched 2026-08-25):**
- `code.claude.com/docs/en/llm-gateway` (redirect target of
  `docs.claude.com/en/docs/claude-code/llm-gateway`, which now 301s)
- `code.claude.com/docs/en/llm-gateway-connect` (`ANTHROPIC_BASE_URL`,
  `ANTHROPIC_AUTH_TOKEN`, `ANTHROPIC_API_KEY`, the `/v1/messages` verification
  curl, the "conflicts with an existing login" and "configure each surface"
  sections)

**OmniRoute source, commit `d82b68274c75c14d258b4898a34edc25d9712b87`
(`release/v3.8.51`, the actual default branch — latest git *tag* `v3.8.49` is
stale, dated 2026-07-29 against a 2026-08-25 last push):**
- `src/app/api/v1/messages/route.ts` (Anthropic-shaped endpoint, full text read)
- `src/app/api/v1/chat/completions/route.ts` (OpenAI-shaped sibling, existence
  confirmed via repo tree)
- `open-sse/translator/request/claude-to-openai.ts` (`cache_control`
  preservation gate, full relevant section read)
- `open-sse/config/providers/registry/mistral/index.ts` (full file, 18 lines)
- `open-sse/config/providers/registry/llm7/index.ts` (full file, 27 lines)
- `docs/guides/CLAUDE-CODE-CONFIGURATION.md` (full file)
- `docs/reference/FREE_TIERS.md` (`mistral`/`llm7` caution entries + drift notes)
- `docs/reference/ENVIRONMENT.md`, `docs/reference/FEATURE_FLAGS.md` (searched
  for a Tier-1 disable flag — not found)
- `api.github.com/repos/diegosouzapw/OmniRoute` (`default_branch`, `pushed_at`,
  `tags`, `branches`, `git/trees?recursive=1`)

**This repo:**
- `docs/analysis/2026-08-23-omniroute-assessment.md` (prior verdict, not
  re-litigated; its ~40-provider "no verified no-train guarantee" finding,
  which already included `mistral`, is cited directly in §4b)
- `docs/analysis/token-spend-forensics.md` (95.56% cache-read ratio, cited in
  the verdict and §2b)
- `bin/lib/quota_stop.py`, `bin/heimdall-quota-advisor`, `bin/heimdall-quota-resume`
  (full files read)
- `cursor-agent --version` (command output, this machine, darwin/arm64)

**Not independently verified in this pass (stated plainly, not assumed):**
- Mistral's and LLM7's actual training/retention terms — no primary-source
  ToS/DPA text was retrieved with the relevant clauses inside the time budget.
  Both are therefore treated as **not clearing** the ZDR-equivalent bar (absent
  a guarantee = gated, per this repo's own existing Fable 5 precedent), not as
  confirmed to train.
- `claude-code-guide` as a callable agent — not exposed as a tool in this
  session; substituted with direct primary-source doc verification instead.

## OUT OF SCOPE

- Re-litigating the 2026-08-23 cost-routing verdict (unchanged, NO)
- Auditing all 350 OmniRoute-fronted providers — only Mistral and LLM7 were
  assessed concretely, per the owner's own narrowing to the two backends
  actually observed in practice
- Any code, hook, or config change, and installing/running/configuring
  OmniRoute or `cursor-agent` — this is a read-only investigation
- Designing the on/off/auto policy layer itself (being built in parallel by
  another agent per the brief)
- Retrieving Mistral's/LLM7's full legal ToS/DPA text verbatim — flagged
  UNVERIFIED above rather than pursued past the time budget for this pass
