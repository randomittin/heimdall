# Does Headroom make claude-mem obsolete?

**Date:** 2026-08-04 · **Scope:** analysis only, nothing installed, nothing changed outside this file.

## Verdict

**No.** They are not substitutes. Headroom **shrinks bytes reversibly**; claude-mem **decides what is worth keeping and retrieves it later, irreversibly**. Neither one does the other's job, and on this machine Headroom does nothing at all — its payload is not installed.

Drop claude-mem and you lose cross-session recall with no replacement. Drop Headroom and you lose a storage/transport size win that is currently **0 bytes** because it is not installed.

---

## 1. Verified state of THIS machine (2026-08-04)

Every row below was measured, not assumed.

| Fact | Value | How measured |
|---|---|---|
| Headroom payload installed | **No** | `uv tool list` → `No tools installed` |
| `headroom` importable | **No** | `python3 -c "importlib.util.find_spec('headroom')"` → `False` |
| Active storage codec | **`plain`** (identity) | `python3 bin/lib/memory_codec.py status --json` → `{"backend":"plain","available":false,"reason":"headroom is not importable — using the plain codec"}` |
| claude-mem installed | **Yes, v13.13.1** | `~/.claude/plugins/installed_plugins.json` → `claude-mem@thedotmack`, `lastUpdated 2026-08-04T03:17:26Z` |
| claude-mem store size | **~575 MiB** (`603,090,944` B) | `ls -la ~/.claude-mem/claude-mem.db` |
| claude-mem observations | **15,299** (7,157 for `heimdall`) | `sqlite3 …?mode=ro "select count(*) from observations"` |
| claude-mem session summaries | **2,080** | `select count(*) from session_summaries` |
| claude-mem user prompts | **4,385** | `select count(*) from user_prompts` |
| claude-mem actively writing | **Yes** — newest obs `2026-08-04T05:17:30Z` | `select max(created_at) from observations` |
| hmd verified-memory store | **Does not exist** (0 entries) | `ls ~/.heimdall/memory/` → no such directory |

**Consequence:** any claim about Headroom's *live* behaviour on this machine is **UNVERIFIED**. The codec seam currently runs the identity path, so today Headroom's measured effect on storage is exactly zero bytes. Its design is verified by reading the code; its runtime benefit is not.

---

## 2. What each of the three things actually is

There are **three** distinct systems that all get loosely called "memory". Conflating them is most of the confusion.

| | **Headroom** | **claude-mem** | **hmd's own memory** |
|---|---|---|---|
| **What it is** | A local context-compression proxy + a storage codec | An LLM-summarising observation recorder with retrieval + auto-injection | Two things: (a) agent-memory markdown files, (b) verified-memory NDJSON store |
| **Where it lives** | `modules/headroom/manifest.json`; seam at `bin/lib/memory_codec.py` | `~/.claude/plugins/cache/thedotmack/claude-mem/13.13.1`; data in `~/.claude-mem` | (a) `.claude/agent-memory/hmd-*/MEMORY.md` + typed files; (b) `bin/lib/verified_memory.py` → `$HEIMDALL_HOME/memory/entries.ndjson` |
| **Primary axis** | **Size** | **Retention + recall** | **Retention + truth** |
| **Does it retain across sessions?** | **No.** Neither wire creates a memory. The codec only re-encodes payloads hmd *already decided* to store | **Yes.** That is its entire purpose | **Yes** |
| **Does it shrink anything?** | **Yes** — in flight (proxy) and at rest (codec) | **Yes, but by discarding.** Summarisation, not encoding | No |
| **Reversible?** | **Yes, by construction.** Byte-exact round-trip or it refuses to persist | **No.** A summary cannot be un-summarised | (a) n/a, hand-written; (b) yes, stores literal text |
| **Authored by** | a codec (mechanical) | a model (`claude-sonnet-4-6` / `haiku`) | a human/agent writing deliberately |
| **Installed & running here?** | **No** | **Yes, heavily** | (a) yes; (b) **no entries yet** |

### 2a. Headroom's two wires do different things

From `modules/headroom/manifest.json`:

- **`wrap-chain` → `bin/heimdall-wrap`** — `hmd wrap <tool>` offers `hmd setup → headroom proxy → tool`. **Generation traffic may traverse the proxy; judgment traffic may not.** Every verdict-producing execution goes through `hmd_gate_exec` (`bin/lib/hmd-gate-endpoint.sh`), which unsets `ANTHROPIC_BASE_URL`, the HTTP(S)/ALL/NO_PROXY pairs, and the whole `HEADROOM_*` namespace, then pins the real provider endpoint. This wire is **transport-only**: it touches bytes on the wire and persists nothing.
- **`storage-codec-backend` → `bin/lib/memory_codec.py`** — the seam flips to the headroom backend when the library is importable and exposes a compatible entrypoint; every other outcome lands on `plain`. Deliberately **no environment lever** ("a routing var is precisely how a compressing proxy reaches a judge").

Neither wire is a memory. The proxy forgets immediately; the codec re-encodes what was already going to be written.

### 2b. What the codec deliberately does NOT touch

`bin/lib/memory_codec.py:93-110` partitions fields:

- `VERIFIER_FIELDS` (never touched): `id`, `commit_ref`, `refs`, `status`, `weight`, `verified_at`, `reason`, `provenance`, `schema_version`, `cache`
- `PAYLOAD_FIELDS` (may be compressed): `claim`, `summary`, `body`, `text`, `content`

`_assert_disjoint()` runs at **import time** (line 151), so widening payloads into a verifier input fails loudly at load, not silently at a verdict. Decode happens at `verified_memory._read_raw` (line 239), *before any consumer exists* — so by the time `vm_gitcheck.verify()` sees an entry, no wire form remains. **Gates read raw.**

### 2c. Codec reach is narrower than the manifest implies — FINDING

The manifest says the seam covers "corpus, context-branch and session-summary payloads". Measured:

```
$ grep -rln "memory_codec" bin/
bin/lib/verified_memory.py
bin/lib/memory_codec.py
```

The corpus modules that exist (`bin/lib/cp_corpus.py`, `cp_corpus_synth.py`, `cp_corpus_aggregate.py`, `cp_session.py`, `issue_corpus.py`, `pmr_corpus.py`) **do not import the codec**. The seam *supports* those payload field names, but only verified-memory is actually wired to it today. So the codec's live blast radius is one store — the store that currently has **zero entries**.

---

## 3. Compression and retention are different axes

```
                    RETAINS across sessions
                              ^
                              |
        hmd verified-memory   |   claude-mem
        (literal, git-checked)|   (summarised, model-authored)
                              |
    --------------------------+--------------------------> SHRINKS
                              |
                              |   Headroom
                              |   (proxy in flight, codec at rest)
                              |
```

- **Headroom retains nothing.** Ask "what did we decide last Tuesday?" with only Headroom installed and the answer is silence.
- **claude-mem shrinks, but only as a side effect of forgetting.** It does not encode; it *decides what survives*.
- The two axes only meet at one point: **token cost of context assembly.**

---

## 4. Overlap matrix

| Capability | Headroom | claude-mem | hmd's own memory |
|---|---|---|---|
| Shrink prompt bytes on the wire | **Yes** (proxy) | No — but a smaller injected context has the same *effect* | No |
| Shrink bytes at rest | **Yes** (codec, reversible) | **Yes** (summary, irreversible) | No |
| Decide what is worth keeping | No | **Yes** (model-judged) | **Yes** (deliberate) |
| Retrieve prior-session context | No | **Yes** (FTS + chroma vectors, auto-injected) | **Yes** (MEMORY.md always loaded; VM via CLI) |
| Survive `/clear` and new sessions | No | **Yes** | **Yes** |
| Byte-exact recovery of the original | **Yes** | **No** | **Yes** |
| Verdict-safe (gates read raw) | **Yes**, by construction | Not a gate input | **Yes** |
| Cross-project recall | No | **Yes** (`project` column, 15,299 rows / 6+ projects) | Per-repo only |

**Genuine overlap: one cell** — "shrink bytes at rest", and even there they do opposite things (encode vs discard). **Everything in the retrieval row is claude-mem-only.**

---

## 5. The crux: a codec round-trips, a summary does not

This is the load-bearing distinction and the measurement is unambiguous.

**Headroom's codec cannot lose a byte, structurally.** `encode_text` (`memory_codec.py:339-391`) re-decodes its own output and compares before returning any wire form; a mismatch means the payload is **stored literally instead**. The envelope also carries a sha256 prefix of the original, and `decode_text` raises `CodecCorruption` if the digest does not reproduce (`:434-439`) — corrupted memory is *skipped, never served*. The manifest's `round-trip-fidelity` invariant proves the guard bites: ARM 2 registers a deliberately lossy backend and asserts it never persists.

**claude-mem's compression is irreversible, and the raw text is gone.** Measured on the live DB:

```sql
select count(*) from observations where text is not null and text <> '';
-- 0        (of 15,299 rows)

select generated_by_model, count(*) from observations group by 1;
-- claude-sonnet-4-6 | 15016
-- haiku             |   283
```

Every stored observation is **model-generated** and the raw `text` column is **NULL on 100% of rows**. What survives per observation for the `heimdall` project (mean chars): `narrative` 551, `facts` 883, `concepts` 35 — against a mean `discovery_tokens` of **9,919**. Roughly an order of magnitude of reduction, achieved by throwing the original away. (Interpretation of `discovery_tokens` as "tokens observed" is inferred from the column name — **UNVERIFIED**.)

### Does "gates read raw" survive a summarising memory layer?

**Yes — because claude-mem is not on hmd's storage path at all.** `_read_raw` decodes at the store boundary so `vm_gitcheck.verify()` never sees a wire form; that property is about `entries.ndjson`, which claude-mem never touches. claude-mem writes to its own SQLite at `~/.claude-mem`, is consumed by *prompt injection*, and is never a verifier input.

**But the question generalises correctly and the answer matters:** if a summarising layer were ever placed *before* hmd's store, the raw-read property would **not** survive. The codec's guarantee is "the bytes you get back are the bytes you put in". A summariser's output is a *different, shorter claim* — there is no digest that can detect the loss because nothing was corrupted; something was **decided**. A gate reading a summarised claim would be judging a model's paraphrase of evidence, which is precisely the false-green the `hmd_gate_exec` scrub exists to prevent. **Rule: a summariser may sit above the store (deciding what to write) but never between the store and a gate.** Today nothing violates this.

---

## 6. Is running BOTH redundant or harmful?

| Concern | Assessment |
|---|---|
| **Double compression** (codec compressing an already-summarised store) | **Does not occur.** The codec is imported only by `verified_memory.py`; claude-mem's SQLite is outside hmd entirely. Even if it did, it would be harmless — the codec would just compress less well and, per `:388`, skip the envelope when it is not smaller. |
| **Recall quality degraded by lossy storage** | **No.** The codec is not lossy; it is refuse-or-round-trip. The recall loss in the system comes from claude-mem's summarisation, which happens with or without Headroom. |
| **A codec compressing a summary** | Not currently wired (§2c). If corpus/session-summary stores are ever attached, the codec still round-trips — it shrinks the summary's bytes without further degrading it. Safe. |
| **Proxy reaching a judge** | Structurally blocked: `hmd_gate_exec` scrubs `HEADROOM_*` + all proxy vars at the gate-execution boundary, and the codec seam offers **no env lever**. |
| **Real cost of running both** | claude-mem is expensive on its own terms — ~575 MiB and growing, a resident worker service, plus a model call per observation. That is a claude-mem cost/benefit question, entirely independent of Headroom. |

**No redundancy, no interference.** They do not touch each other's data or code paths.

---

## 7. Recommendation

**Keep claude-mem. Headroom does not replace any part of it.**

The two decisions are independent and should be made separately:

1. **claude-mem — keep/drop on its own merits.** The real question is not Headroom; it is whether ~575 MiB, a resident worker, and a model call per tool use are worth cross-session recall. If you want to test that, disable it for a week and see whether sessions start colder. Headroom is not evidence in that argument either way.
2. **Headroom — currently a no-op here.** It is `default_included` but its payload is not installed, its tier is honestly `available` (not `suggested`, because the A/B has not run). Its measured benefit today is zero bytes on a store with zero entries.

### What would change this verdict

| Condition | Effect |
|---|---|
| Headroom ships a **retention/recall** feature (persistent cross-session store + retrieval), verified by reading its source | Overlap becomes real and the obsolescence question becomes live. **Today: no such wire exists in this repo.** |
| hmd's verified-memory grows a **retrieval + auto-injection** path good enough to replace claude-mem's recall | claude-mem becomes droppable — but the replacement is **hmd's own memory**, still not Headroom. |
| claude-mem's summarisation output is ever fed to an hmd **gate or verifier** | Becomes actively harmful; must be blocked before then (§5). |
| The Headroom A/B receipt lands green under `tier_evidence` | Justifies installing the payload — changes nothing about claude-mem. |

---

## 8. What could NOT be verified

- **Headroom's live behaviour on this machine.** Payload absent (`uv tool list` empty, `find_spec('headroom')` → `False`); the codec runs the identity path. Everything stated about Headroom's runtime is read from `modules/headroom/manifest.json` and `bin/lib/memory_codec.py`, **not observed**. Its actual compression ratio here is unmeasured.
- **Headroom's upstream source.** `https://github.com/headroomlabs-ai/headroom` was not fetched during this analysis; no Headroom source is vendored in this repo. Claims about the proxy's internals come from the manifest's own `consent_text`, which is hmd's description of it, not Headroom's.
- **claude-mem's compression prompt and model-call details.** Inferred from the schema (`generated_by_model`, `narrative`/`facts`/`concepts`) and the `how-it-works` skill; the worker source (`scripts/worker-service.cjs`, minified CJS) was not read line-by-line.
- **`discovery_tokens` semantics.** Interpreted from the column name as tokens observed pre-summarisation. Not confirmed against claude-mem source.
- **Whether claude-mem's retrieval actually improves outcomes.** Not measured. Neither system has a green A/B receipt in this repo.

---

## Sources

Read directly:
- `/Users/rj/Downloads/heimdall/modules/headroom/manifest.json`
- `/Users/rj/Downloads/heimdall/bin/lib/memory_codec.py`
- `/Users/rj/Downloads/heimdall/bin/lib/verified_memory.py`
- `/Users/rj/.claude/plugins/installed_plugins.json`
- `/Users/rj/.claude/plugins/cache/thedotmack/claude-mem/13.13.1/.claude-plugin/plugin.json`
- `/Users/rj/.claude/plugins/cache/thedotmack/claude-mem/13.13.1/hooks/hooks.json`
- `/Users/rj/.claude/plugins/cache/thedotmack/claude-mem/13.13.1/skills/how-it-works/SKILL.md`
- `/Users/rj/Downloads/heimdall/.claude/agent-memory/hmd-heimdall/`

Queried read-only: `~/.claude-mem/claude-mem.db` (`?mode=ro`, SELECT only).
Ran: `uv tool list`, `python3 bin/lib/memory_codec.py status --json`, `grep -rln memory_codec bin/`.
Installed/modified: **nothing**.
