# Security-Guidance Reviewer Tier — Decision Memo

**Date:** 2026-08-08 · **Decision owner:** RJ · **Supersedes:** row 3 of [`token-spend-forensics.md`](./token-spend-forensics.md)
**Verdict:** **IRREDUCIBLE — do not retier.** The measured spend is a genuine security review already running on the tier this repo's own rule assigns it.
**Status:** the tier change is rejected; a separate, smaller frequency fix needs the owner's hand (§6).

---

## 1. The question

`token-spend-forensics.md` row 3 measured **$57.73** against the `security-guidance` plugin, called it *"right check, wrong tier"*, and prescribed a one-liner:

```
export SECURITY_REVIEW_MODEL=claude-haiku-4-5   # REFUTED — see §3 and §4
```

claiming **$46.18** of saving. It was reported and never applied. This memo resolves whether to apply it.

**It should not be applied.** It targets a code path that did not generate the measured spend, and it points the wrong way on a check that is correctly tiered.

---

## 2. The plugin has TWO independent LLM review surfaces, not one

This is the distinction row 3 collapsed. They are different code paths, different transports, different env knobs, and only one of them is measurable from session transcripts.

| | **Stop review** | **Commit / push review** |
|---|---|---|
| Hook | `Stop` | `PostToolUse` matcher `Bash`, `if: Bash(git commit:*)` / `Bash(git push:*)` |
| Entry | `handle_stop_hook` | `handle_commit_review_posttooluse` / `handle_push_sweep_posttooluse` |
| Shape | **single-shot, no tools** | **agentic loop, `allowed_tools=["Read","Grep","Glob"]`** (`llm.py:1285`), `SG_AGENTIC_MAX_TURNS` 18 |
| Transport | **raw `urllib` POST** to `/v1/messages` (`llm.py:526`, `:532`) | **Claude Agent SDK** → spawns the `claude` CLI |
| Writes a session transcript? | **No** | **Yes** (`entrypoint: sdk-py`) |
| Model knob | `SECURITY_REVIEW_MODEL` (`llm.py:131`) | `SG_AGENTIC_MODEL` (`llm.py:1191`) |
| Default | `claude-opus-4-7` | `claude-opus-4-7` |

The plugin says so itself, at `security_reminder_hook.py:1985-1988`:

> ```python
> # Stop hook is single-shot only. Agentic review is wired into
> # handle_commit_review_posttooluse (PostToolUse on `git commit`) — commits
> # are slower-OK and benefit from the deeper context-reading loop.
> ```

---

## 3. The $57.73 is not the Stop hook — three independent proofs

The forensics identified the spend as *"a **Stop hook**, so it fires every time an agent stops with a diff present"*. That attribution is wrong.

**Proof 1 — the Stop hook cannot appear in the corpus at all.** The corpus is `~/.claude/projects/**/*.jsonl`, which only exists for sessions spawned through the Agent SDK / CLI. The Stop path calls `urllib.request.urlopen` directly (`llm.py:532`) against `api.anthropic.com`. A raw HTTP POST from Python writes no transcript. Its spend is structurally invisible to the measurement that produced $57.73. (The SDK path is reachable from Stop *only* under a 3P provider — `_is_3p_provider()`, `llm.py:466` — and no `CLAUDE_CODE_USE_*` var is set here.)

**Proof 2 — the prompt in every measured session is the agentic one.** All 254 sessions whose first prompt begins `"Review this change for security vulnerabilities."` continue with:

> `Changed files (you may Read these and any other file in the repo):`

That string occurs in exactly two places in the plugin — `llm.py:1213` (inside `agentic_review`, whose `def` is at `llm.py:1138`) and `review_api.py:168`, its prompt builder. It appears **nowhere** in the Stop path's prompt builder. *"you may Read"* is an instruction to a tool-using agent; the Stop reviewer has no tools.

**Proof 3 — the measured tool usage matches the agentic grant.** Re-measured over the full corpus (usage deduped by `message.id`, the trap the forensics documents):

```
security-review sessions: 254
deduped assistant requests: 1672
models: {'claude-opus-4-7': 1669, '<synthetic>': 3}
tool mix: {'Read': 493, 'Bash': 168, 'Grep': 102, 'StructuredOutput': 28, 'Glob': 13}
```

Read/Grep/Glob are exactly `agentic_review`'s grant. The Stop reviewer is granted nothing.

**Consequence:** `export SECURITY_REVIEW_MODEL=claude-haiku-4-5` would have moved **$0.00** of the measured $57.73. It changes the tier of the *other* surface — the one whose cost was never measured. The $46.18 saving was not available from that command.

---

## 4. The tier is correct — do not lower it

Even aimed at the right knob (`SG_AGENTIC_MODEL`), the downgrade is the wrong call.

**4a. This repo's own routing rule already assigns this work to opus.** `bin/heimdall:3688-3691`, the MODEL ROUTING preamble injected into every lead agent:

> ```
> MODEL ROUTING — when spawning subagents, select model per task:
> - haiku: lint, format, rename, config, simple lookups (fast + cheap)
> - sonnet: docs, tests, research, analysis, simple fixes (good enough)
> - opus: ALL code writing, architecture, design, review, security, DB (quality non-negotiable)
> ```

`review` and `security` are both named, and the parenthetical is *quality non-negotiable*. `agents/planner.md:83-89` escalates further: security audit earns opus at **`effort: max`**. Downgrading this reviewer would make the repo's automated security review the one place it violates its own published rule.

**4b. The forensics mischaracterised the work.** Row 3 argued *"Pattern-matching a diff for known vulnerability shapes is exactly the bounded, mechanical task a small model handles well."* That describes the plugin's **layer 1** — the `PostToolUse` regex rules in `patterns.py`, which use no LLM and cost nothing. The measured layer is the agentic reviewer, which reads files, greps the repo, and reasons across up to 18 turns. Its prompt is ~40 vulnerability classes of adversarial reasoning, including instructions like:

> **Distrust safety claims**: Comments and docstrings that assert safety ("SSRF-safe", "validated upstream", "not user input", "sanitized above") are claims, not evidence. Verify the invariant holds in the visible code. (`llm.py:972`)

> **Check for missing controls, not just added sinks**: A new handler, route, or auth path can be vulnerable because of what it LACKS, not what it adds. (`llm.py:974`)

Absence-of-control detection and multi-hop taint reasoning are not pattern matching. This is the judgement work the tier exists for.

**4c. The plugin chose opus deliberately, and documents why.** `llm.py:127-130`:

> ```python
> # Model for security review. Default chosen for its precision profile on
> # interruptive review surfaces — false positives are the dominant uninstall
> # driver, so the default favors precision over recall and over latency.
> ```

`README.md:106` closes the same way: *"if precision is the priority, stay on Opus 4.7"*.

**4d. Setting the var is itself hazardous.** `llm.py:623-632`:

```python
explicit = os.environ.get("SECURITY_REVIEW_MODEL", "").strip()
primary = explicit or SECURITY_REVIEW_MODEL
...
r = _call_claude(..., model=primary, retry_5xx=False)
if r is None and not explicit:
    debug_log(f"single: {primary} failed, falling back to sonnet")
```

`and not explicit` — **setting `SECURITY_REVIEW_MODEL` at all suppresses the sonnet fallback.** The value is never validated (`llm.py:131` only `.strip()`s it) and bare aliases like `opus`/`haiku` are CLI concepts the Messages API rejects with a 400. A typo'd or alias-form value therefore yields a reviewer that returns `None` forever, exits 0, reports `vulns_found: 0`, and looks exactly like "no issues found". **This is why the tier must not be pinned via `heimdall-model-resolve`'s bare alias here** — that helper emits `opus`, which this path would post verbatim and the API would reject.

**Conclusion: the tier stays `claude-opus-4-7`. The $57.73 is largely IRREDUCIBLE.** It is the correct check, on the correct tier, doing real work. A cheaper reviewer that misses one authorization bypass costs more than the entire line item.

---

## 5. What *is* reducible — and the honest number

The genuine inefficiency is in the **Stop** surface, and it is smaller than row 3 claimed.

Measured from the plugin's own debug log (`~/.claude/security/log.txt{,.1}`, window 2026-08-05 → 2026-08-08):

| metric | value |
|---|---|
| `Stop` events | 218 |
| already skipped (`empty review set`) | 84 |
| already skipped (`no source code files in diff`) | 8 |
| **ran an LLM review** | **126** |
| reviews that found an issue | **0 of 126** |

Of those 126 reviews, the same baseline is re-reviewed repeatedly. Grouping by baseline SHA and comparing files actually sent (post the 30-file cap):

- 29 dedupable baselines, 81 reviews, **707 files sent, 270 distinct → 2.62× amplification**
- **50.8%** of all file-content sent to the Stop reviewer had already been reviewed under the same baseline
- 21 reviews sent a file set identical in size to the immediately preceding review of the same baseline — provably zero new content
- worst case, baseline `e46e35062a34`: 10 reviews sending `[1, 3, 3, 7, 30, 30, 30, 30, 30, 30]` — six consecutive reviews of the capped 30-file set

Root cause is visible in the log: `UPS: preserving prior baseline — previous Stop hook never consumed touched_paths` fires **170 times** across 283 `UserPromptSubmit` events. On an interrupted or aborted turn the baseline does not advance, so the review set accumulates and the same code is re-sent.

**Cost of the Stop surface.** It leaves no transcript and the plugin's `_record_usage` accumulator (`_base.py:147`) is in-process only, so this is an **estimate**, labelled as such per this report's convention. What is measurable: the static prompt is **~35.5 KB (~8,870 tokens)** and is re-sent **uncached** on every fire (a fresh POST with no `cache_control` breakpoints), while the diff averages only 6.8 files. At Opus 5 list rates that is **$0.06–$0.11 per review**, i.e. **~$8–$14 for the 126 reviews in that 3-day window**.

So the honest ledger, against the $57.73 the finding named:

| candidate | saving | status |
|---|---|---|
| `SECURITY_REVIEW_MODEL=claude-haiku-4-5` (the reported fix) | **$0.00** | **REFUTED** — wrong knob; the measured path reads `SG_AGENTIC_MODEL` |
| `SG_AGENTIC_MODEL` → haiku (the knob that *would* have worked) | ~$46 | **REJECTED** — weakens a real security check; violates `bin/heimdall:3691` |
| Stop-surface frequency fix (§6) | **~$8–$14 per 3-day window**, estimated | **Available**, needs owner's hand |

**The $57.73 is ~100% irreducible without weakening the check.** The real saving is a separate, smaller, unmeasured line — worth taking, but it is single-digit dollars per active window, not $46.

---

## 6. The change that needs the owner's hand

Not applied here. It lives outside this repo, and `~/.claude/settings.json` is not ours to write.

The lever is `MAX_STOP_HOOK_FIRINGS` (`security_reminder_hook.py:178`, default `3`), which caps Stop reviews per 120-second window (`STOP_LOOP_STATE_TTL_SEC`, `diffstate.py:29`, hardcoded). Lowering it to `1` keeps the Stop reviewer running, keeps every gate and every file filter intact, and removes the repeat fires that re-send already-reviewed content within a single burst.

Add to the `env` block of `~/.claude/settings.json`:

```json
{
  "env": {
    "MAX_STOP_HOOK_FIRINGS": "1"
  }
}
```

Verify in one command — it should print `1`:

```sh
jq -r '.env.MAX_STOP_HOOK_FIRINGS // "unset"' ~/.claude/settings.json
```

**Do not** add `SECURITY_REVIEW_MODEL` or `SG_AGENTIC_MODEL` to that block. Both default to `claude-opus-4-7`, which is the decision recorded here, and setting the former also disables its fallback (§4d). `test/security-review-tier.test.sh` fails if either is ever set to a sub-opus tier, in the environment or anywhere in the repo.

**What this does not fix:** the baseline-never-advances behaviour (§5) is plugin-internal — it needs a fix in `security_reminder_hook.py` or an upstream report, not configuration. Coverage is unaffected either way: every file still gets reviewed, and everything committed is additionally reviewed by the stronger agentic reviewer at commit time.

---

## 7. Limitations

- The Stop-surface dollar figure is an **estimate** (§5). Input is computed from measured prompt bytes; output is assumed 400–1,500 tokens/review because the Stop path persists no usage anywhere on disk. Every other figure in this memo comes from `message.usage` or from the plugin's own log and involves no conversion.
- The re-measured corpus is **254 sessions / $141.86** (2026-07-14 → 2026-08-07) against the forensics' **89 / $57.73** for the same prompt prefix. The window and the directory set differ, and the corpus grows while it is read. **The ranking is unaffected** — the attribution correction in §3 holds at either size, and the tier conclusion does not depend on the magnitude.
- `0 of 126` Stop reviews finding an issue is a rate over one 3-day window on a repo with a mature mechanical gate stack. It is **not** evidence the reviewer is useless, and it is not used as an argument for removing it.
- Severity floor note: `llm.py:1052` admits `critical|high|medium`; the comment at `security_reminder_hook.py:1993` claiming high/critical only is stale. Not load-bearing here, but it misleads a reader auditing coverage.

---

**Bottom line:** the reported fix was aimed at the wrong hook via the wrong environment variable and would have saved nothing. Aimed correctly it would have saved ~$46 by making the repo's only automated vulnerability reviewer materially worse, in direct contradiction of `bin/heimdall:3691`. The tier stays opus. The real, honest saving is **~$8–$14 per active 3-day window** from firing the Stop reviewer less often, and it is the owner's to apply in §6.

Back to the analysis index: [`INDEX.md`](./INDEX.md).
