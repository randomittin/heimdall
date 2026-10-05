# TypeSafe (Jev) vs hmd heuristics: measured eval

Date 2026-10-05. Verdict: **BLOCKED** on an operator-supplied `TYPESAFE_API_KEY`. No TypeSafe number exists; none is invented here. Heuristic baseline measured. Harness is ready: `python3 evals/typesafe/run.py`.

## 1. What TypeSafe is (live docs, fetched 2026-10-05)

Sources: docs.typesafe.ai/{llms.txt, api.md, models.md, primitives/noul.md, legal.md}, typesafe.ai/legal/{data-processing, privacy-policy}, installed skill `~/.claude/plugins/marketplaces/typesafe-ai/skills/typesafe-ai/SKILL.md`. The fetch tool summarizes pages, so quotes below are the summarizer's rendering of the page, not raw bytes.

| Item | Finding |
|---|---|
| API | `POST https://api.typesafe.ai/v1/systemone`, `Authorization: Bearer <key>`. Body `{state, model, questions:{id:{type,...}}}`. Model `jev-latest` (resolves `jev-1.13.0`; pin the id for reproducibility). |
| Primitive used here | **Noul** (yes/no): `{type:"noul", instructions, criteria:{true,false}}` -> `answers.<id>.noul` in 0..1. No `confidence` field. Docs suggest 0.5 default, raise threshold when a false yes is costly, route 0.2..0.8 to a human. |
| Limits | Text only. 64k tokens/request (32k state + longest question). 100K tok/s, 80 req/s; 429/529 -> backoff. |
| Pricing | "$42 / $0.042 per Btok / per Mtok", input tokens only, output free. This eval's 287 calls is roughly 50-60K tokens, i.e. well under one cent (estimate, not measured). |
| Latency | **No figure published.** Only "batching 13 questions: 10.0x faster" and "fast, structured decisions". Network RTT to a US-hosted service on every prompt is unmeasured here. |
| Retention | Privacy policy: retained "as long as reasonably necessary" and "in support of our business or commercial purposes"; no fixed period; deletion on request. DPA (personal data only): no period, **no deletion/return clause**. ZDR offered to enterprise only (sales@typesafe.ai). |
| Training | Privacy policy: "We will not train or fine tune any AI/ML models on your prompts or other Input." Personal data may still be used to "improve, debug... the Services" and for anonymized/aggregated data (scope vs Input unstated). |
| Egress / hosting | Hosted in the United States. Input may go to "service providers"; subprocessor list at trust.typesafe.ai/subprocessors (not read). Policy says it "collects... your prompts, data, instructions, and other input". Logging of API calls not addressed. |

Egress implication for hmd: classifying a prompt in the `UserPromptSubmit` hook means every user prompt (raw, unscrubbed, including pasted content) leaves the machine to a third party on every turn. That contradicts hmd's zero-content / local-only posture unless the operator opts in knowingly. Assistant questions (hmd-question) carry code, paths and decisions and have the same issue.

## 2. Heuristics under test

- (a) `bin/parallel-gate`: bash UserPromptSubmit hook. Score = numbered/bullet lines + connectives (`also`, `then`, ...) + count of 26 imperative verbs + "multiple/parallel" phrases; fires at score >= 2; skips prompts under 4 words and ones starting what/why/how/....
- (b) `bin/lib/companion_ui_attention.py::_closed_polar_question` (used by `_make_options` for hmd-question): exactly one `?`, closing sentence starts with an auxiliary/modal (optionally after a <=8-word lead-in), no which/what/how/why/when/where/who/or, not secret-shaped. Deliberately conservative: a wrong Yes/No button is worse than no button.

## 3. Dataset and labels

Source: main-chain (non-sidechain) entries in `~/.claude/projects/-Users-rj-Downloads-{heimdall,hmdapp}/*.jsonl` (worktree slugs excluded: they are agent sessions). Pool 452 prompts / 200 assistant final turns ending in `?`; seeded random sample (seed 7) of 200 / 100. Stored: `evals/typesafe/dataset.jsonl` = sha256(raw)[:16], label, scrubbed text. Raw text is not stored.

Scrub: secret-shaped strings (superset of `secret_shaped`), any 32+ char opaque token, emails, IPv4, phone-like numbers, `<pasted_content>` blocks replaced by `[PASTED]`, images by `[IMAGE]`. Prompts truncated head-first at 1200 chars; assistant turns truncated tail-first (the question is in the last sentence). Leak grep on the stored file found no key/email/token shapes.

Dropped from the 200 prompts (13, listed in `excluded.json`): agent-authored task prompts, a test probe, and pasted terminal/hook/error output. Result: **187 prompts, 23 multi-part (12.3%)**; **100 questions, 25 closed-yes/no (25%)**.

Rubric.
- Multi-part = YES if the user asks for >= 2 distinct deliverables/changes that different workers could do at the same time. NO for: a single task, questions/status pings, answers to a prior question, steps that strictly depend on each other (e.g. "run spike first, then build"), or a second clause that is only context.
- Closed-yes/no = YES if the message's final ask is ONE question that a plain Yes/No fully answers (explicit "yes/no" tags and "Want me to X?" count). NO for A-or-B, A/B/C letter picks, which/what/how/why, requests for a value (IP:port, email, code), "reply `done`", and several questions in one turn.

Label noise (honest): one labeller (me, the author of this eval, who has seen the heuristic source), no second rater, no inter-annotator agreement. "Independent" is a judgement call; ~6 prompts are borderline (e.g. "setup fastlane for both play and appstore" labelled multi-part; "do the sweep ... plus a similar one on git" labelled multi-part; "land worktrees -> run waves -> report" labelled single because sequential). 23 positives means every prompt-arm number carries a wide interval. The sample is one developer's prompts in one project family, heavy on terse follow-ups ("continue", "is it done?"), so the 12% base rate is not general. Labels were assigned after viewing the prompt text only, not heuristic output, but I did read the heuristic code first.

## 4. Baseline results (heuristic arm, measured)

Command: `python3 evals/typesafe/run.py --json evals/typesafe/results-heuristic.json`

| Task | n (pos) | Precision | Recall | F1 (95% bootstrap CI) | Always-yes F1 | Latency p50 / p95 |
|---|---|---|---|---|---|---|
| Multi-part prompt (`parallel-gate`, real hook subprocess) | 187 (23) | 0.647 (tp 11, fp 6) | 0.478 (fn 12) | **0.550** [0.333, 0.720] | 0.219 | 475 ms / 769 ms (see caveat) |
| Closed yes/no (`_closed_polar_question`, in-process) | 100 (25) | 1.000 (tp 8, fp 0) | 0.320 (fn 17) | **0.485** [0.250, 0.688] | 0.400 | 0.20 ms / 0.62 ms |

Latency caveat: host 1-min load average was 30-36 during the runs (spawning `true` took ~43 ms; normal is ~2 ms). The `parallel-gate` figure is the full bash+jq+~40 grep subprocess cost under that load, not a clean number. Early-exit prompts (< 4 words) measured ~90 ms in the same conditions. The script header claims "~1ms"; treat that as unverified. The polar detector is a regex, sub-millisecond regardless.

Error shape.
- `parallel-gate` misses are asks joined by plain "and"/"plus"/";" with no listed signal words (7 of 12 FN contain none of its connectives) and 2-item asks like "fastlane for both play and appstore". FPs: install instructions with several verbs, pasted handoff notes.
- `_closed_polar_question` is perfect on precision and loses recall almost entirely to one opener: "Want me to ...?" (also "Ready to ...?", "Done yes/no?", "Build X now -- yes or no?"), none of which start with an auxiliary. The what-if arm in `run.py` (`candidate_polar_arm`, regex extended with those openers) scores **P 0.913 R 0.840 F1 0.875** on the same 100 items, but that is tuned after reading this data's misses, so it is an in-sample optimistic bound, not a result. It does show the cheap local fix has headroom a classifier would have to beat.

## 5. TypeSafe arm: BLOCKED

`env` contains no `TYPESAFE_API_KEY` or similar (names checked; values never printed). Nothing was sent to typesafe.ai. The harness's TypeSafe arm refuses to run unless all three hold: `TYPESAFE_API_KEY` set by the operator, `--typesafe`, `--accept-egress`. `python3 evals/typesafe/run.py --selftest` exercises the request shape, auth header, response parsing and error path against a local fake server (plumbing only; no eval numbers; the real API's behavior with these questions is untested).

To unblock (operator):
```
export TYPESAFE_API_KEY=...            # operator-supplied; the stored text is scrubbed but still leaves the machine
export TYPESAFE_MODEL=jev-1.13.0       # pin; default jev-latest
python3 evals/typesafe/run.py --typesafe --accept-egress --json evals/typesafe/results-typesafe.json
```
It reports P/R/F1 at threshold 0.5 with bootstrap CI, AUC, an in-sample-best threshold (flagged optimistic), latency p50/p95 and input tokens. Decision rule to pre-commit before running: TypeSafe "beats" a heuristic only if its F1 at the fixed 0.5 threshold exceeds the heuristic's upper-CI bound or its AUC-derived advantage holds on a held-out half; with 23/25 positives, anything inside the CIs above is a tie. Compare also against the cheap local what-if in section 4, not just the current regex.

## 6. Verdict and adoption constraint

**BLOCKED.** Cannot say adopt / don't adopt without the key. Priors, stated as priors not findings: a semantic classifier plausibly helps the multi-part arm (the heuristic's F1 0.55 is weak and its misses are semantic); it is unlikely to be worth a network hop for the closed-yes/no arm, where a 2-line regex change likely closes most of the gap locally.

If a measured run does favor TypeSafe, adoption constraints (all required):
1. **Opt-in**, off by default, per operator; never on in team/shared mode without each member's consent.
2. **Advisory only**: its output may add context or a hint, never block a turn, never change what a gate enforces, never auto-spawn agents by itself.
3. **Fail-open**: timeout (tight, hook path is on the user's critical path; budget to be set from measured p95), 401/429/529/network error -> fall back to the local heuristic silently and log locally.
4. **Operator-supplied key** read from env/secret store, never written to the repo, `.planning/`, logs, or telemetry; never printed.
5. **Egress**: send only the scrubbed (secret/email/paste stripped, length-capped) text, never raw prompt or pasted content, and tell the operator in setup that prompts go to a US-hosted third party with no published retention period (ZDR enterprise-only). hmd's zero-content ledger/telemetry guarantees do not extend to this path.
6. Re-run this harness on any `jev-latest` bump (pin the version id).

## 7. Limits of this eval

Single labeller; n small (23/25 positives); one user's prompts; assistant questions only from this project family; latency measured under heavy host load; TypeSafe arm unmeasured; the polar what-if is overfit by construction; `parallel-gate` is graded on prompt text with pasted blocks removed (the live hook would see them, adding verb/connective hits and likely more FPs).
