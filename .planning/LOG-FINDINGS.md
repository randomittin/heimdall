# HMD Log & Telemetry Findings

**Branch:** `log-monitor-report2` · **Base sha:** `7ea54ea` · **Generated:** 2026-07-22
**Method:** superpowers:systematic-debugging — every finding is observation → evidence (file:line / log line) → root-cause → fix → falsification. Read-only. No code changed.

---

## TL;DR — the 3 highest-value fixes to green-light first

1. **F1 — Wire a `metric:"task"` emitter.** The SONA self-improve loop is starved: `heimdall-self-improve collect` returns `total_task_records: 0` because **nothing in the codebase writes a `metric:"task"` record** — the sole metrics.jsonl writer (`parallelism-tracker.c:259`) only ever writes `metric:"parallelism"`. Structural, but the highest leverage: without it the router can never learn. (CONFIRMED)
2. **F2 — Wire run-lifecycle telemetry into the real run.** `events.ndjson` is 1892 rows, **100% `install_step`**. The `phase / gate / token / outcome / commit` emitters in `bin/lib/run_telemetry.py` have **zero production callers** (only `bin/heimdall-demo` references the module). Every run-quality signal the telemetry schema promises is never emitted. Same "zero-callers wiring gap" class as verified incident `inc-14`. (CONFIRMED)
3. **F3 — Fix the documented `collect` invocation + skip claude-mem install on no-TTY.** `skills/self-improve/SKILL.md:47` documents `heimdall-self-improve collect --repo .`, which **errors** (`--repo` must precede the subcommand). And 14 of 15 telemetry `failed` events are `companion:claude-mem` failing "no interactive TTY or bun absent" — a predictable precondition that should skip, not fail. Both are ≤1hr quick wins. (CONFIRMED)

---

## Findings (ranked by impact × evidence-strength)

### F1 — SONA routing-feedback loop is starved: no `metric:"task"` record is ever written  ⭐ TOP

- **Observation:** `heimdall-self-improve collect` yields nothing to learn from.
- **Evidence (run in hand):**
  ```
  $ bin/heimdall-self-improve --repo . collect
  {"cells": [], "task_types": [], "total_task_records": 0, ...}
  ```
  - `.planning/metrics.jsonl` = 30 records, **all** `"metric":"parallelism"`, span 2026-05-31 → 2026-07-15. Zero `"metric":"task"`.
  - Reader: `bin/heimdall-self-improve:142` — `if ... r.get("metric") != "task": continue`. It only counts task records.
  - Writer census: the **only** appender to `.planning/metrics.jsonl` is `bin/parallelism-tracker.c:259-262`, and it hard-codes `"metric":"parallelism"`. `grep -rn '"metric":"task"'` across `bin lib skills` matches **only doc/reader lines** (`heimdall-self-improve:45` comment, `:142` reader, `skills/self-improve/SKILL.md:51` doc) — **no writer**.
- **Root cause:** The task-outcome emit site was specified (SKILL.md:51 gives the exact record shape; self-improve consumes it; agents/heimdall.md says "adjust model routing every 10 tasks") but **never implemented**. The gate/verifier that decides task pass/fail never appends a `metric:"task"` row. Same defect family as `inc-14-issue-queue-never-ingested` ("ZERO callers → never populated") in `experiments.jsonl`.
- **Fix:** At the point a task's acceptance-criteria gate resolves (verifier PASS/FAIL — `hmd:verifier` / reviewer gate in the heimdall run flow), append one line:
  `{"metric":"task","task_type":<role>,"model":<emitted_model>,"outcome":"pass|fail","retries":N,"wall_secs":N,"ts":...}`.
  `bin/heimdall:2673-2682` already computes `emitted_model` per run — that block is the natural hook; it needs the task_type + gate outcome threaded in. Prefer emitting from the same real gate self-improve trusts ("the recorded task OUTCOMES from the real gate, never a self-report" — heimdall-self-improve:26).
- **Falsify:** After wiring, run a real `hmd "<task>"` that hits a gate, then `grep '"metric":"task"' .planning/metrics.jsonl` returns ≥1 row AND `heimdall-self-improve --repo . collect` reports `total_task_records >= 1`. If still 0, the emit site is wrong.

### F2 — Run-lifecycle telemetry has no production caller: events.ndjson is 100% install_step  ⭐

- **Observation:** The telemetry surface the task hoped to mine (gate denials, stalled phases, token blowouts, outcome=fail clusters) does not exist in the data.
- **Evidence:** `.heimdall/telemetry/events.ndjson` = 1892 rows, 1835 distinct `run_id`, span 2026-06-23 → 2026-07-16. `event_type` histogram: **`install_step` × 1892, everything else × 0.** The `gate` field is present in the schema but empty on every row.
  - The enum `EVENT_TYPES` (`bin/lib/telemetry.py:55`) declares `install_step, phase, gate, token, outcome, commit, issue_state` — all valid.
  - Emitters exist: `bin/lib/run_telemetry.py:59-96` = `emit_phase / emit_gate / emit_token / emit_outcome / emit_commit`.
  - Caller census: `grep -rn run_telemetry bin lib skills` matches **only** `bin/heimdall-demo:69` (`RUNLIB=...run_telemetry.py`). No real run path calls these. `install_step` is emitted separately via `bin/heimdall:139` (`emit --type install_step`), which is why only it appears.
- **Root cause:** Zero-callers wiring gap (the `inc-14` class again). The lifecycle emitters were built and unit-wired into the demo, never into the live `hmd` run.
- **Fix:** Call `run_telemetry.emit_phase/emit_gate/emit_outcome/emit_token/emit_commit` from the real run in `bin/heimdall` (per-phase and at the verifier gate). This also directly feeds F1 (a `gate` outcome event and a `task` metric can be emitted from the same point).
- **Falsify:** After wiring, a real `hmd` run produces ≥1 `event_type` ∈ {phase, gate, outcome} in `events.ndjson`. `python3 -c "..."` histogram shows non-`install_step` rows. If not, emit points weren't reached.

### F3a — Documented `collect` command errors (wrong arg order)  · QUICK WIN

- **Observation / Evidence:** `skills/self-improve/SKILL.md:47` shows `heimdall-self-improve collect --repo .`. Running it:
  ```
  $ bin/heimdall-self-improve collect --repo .
  error: unrecognized arguments: --repo .   (exit via argparse)
  ```
  `--repo` is a top-level arg (before the subcommand); the working form is `heimdall-self-improve --repo . collect`.
- **Root cause:** Doc written from the intended UX, not the actual argparse layout — a partial-read doc defect (see F6, the recurring "confident claim from partial read" class).
- **Fix:** Edit SKILL.md:47 (and any peer docs) to `heimdall-self-improve --repo . collect`. Optionally accept a trailing `--repo` in argparse for ergonomics.
- **Falsify:** `bash -c "$(sed -n '47p' skills/self-improve/SKILL.md | grep -o 'heimdall-self-improve.*')"` exits 0.

### F3b — claude-mem companion install fails predictably on no-TTY/no-bun  · QUICK WIN

- **Observation:** All 15 `outcome:"failed"` telemetry events are `step: companion:claude-mem`.
- **Evidence:** 14 rows `error.detail = "no interactive TTY or bun absent; claude-mem wizard needs both"` (all 2026-07-05, one non-interactive session), 1 row `"npm exec exit 1"` (2026-07-12). No other step ever fails.
- **Root cause:** The companion install *attempts* a wizard that requires a TTY+bun, then records `failed` when the precondition is knowably absent — turning an expected skip into a failure signal.
- **Fix:** Pre-check TTY+bun; if absent, emit `outcome:"skipped"` (or don't emit a failure) instead of attempting-and-failing. Keeps the failure channel meaningful.
- **Falsify:** Run install in a non-TTY shell (`setsid`/pipe); `companion:claude-mem` yields a skip, not a `failed` row.

### F4 — heimdall-presence self-contradicting comment: "secret sent ONCE at /enroll" is false  · CONFIRMED

- **Observation:** Two comments in the same file disagree about when the team secret is transmitted.
- **Evidence:**
  - `bin/heimdall-presence:350` (docstring): *"It is sent ONCE in the X-Heimdall-Team-Secret header at /enroll; signed beats/reads thereafter carry NO secret."*
  - `bin/heimdall-presence:508` (the `/enroll` docstring): **a second** stale copy — *"it is sent ONCE here at enroll; signed beats/reads thereafter carry NO secret."*
  - `bin/heimdall-presence:471` (inside `def request()`, the **shared** helper for every call — `:456`): *"The per-repo TEAM SECRET rides the header on EVERY presence call (beat / retire / roster), not just enroll."*
  - Code confirms `:471` is the truth: `request()` at `:475-476` adds `X-Heimdall-Team-Secret` whenever `PRES_TEAM_SECRET` is set, for **any** method/path — beats included.
- **Root cause:** `:350` and `:508` are stale text describing an earlier one-shot-enroll design; the code moved to per-call secret (the "BUG2 write↔read round-trip") but the two docstrings weren't updated. It's a security-relevant claim (implies beats are secret-free when they are not) — and it appears **twice**, so a reader is doubly misled.
- **Fix:** Correct **both** `:350` and `:508` to "sent on EVERY presence call (enroll/beat/retire/roster) in the X-Heimdall-Team-Secret header," matching `:471` and the code.
- **Falsify:** Read `:475-476` — header is added unconditionally on `PRES_TEAM_SECRET`, not gated on `path == "/enroll"`. Already confirmed.

### F5 — Coordination `protocol.log` is empty (0 bytes) — coordination telemetry produces nothing  · CONFIRMED

- **Observation / Evidence:** `wc -l .planning/protocol.log` → **0**. The task named it the primary source for retries/timeouts/R1-collisions/reaped-claims/stalled-agents. None of that has ever been logged here.
- **Root cause (now confirmed):** The writer **exists and works** — `bin/lib/protocol.sh:66` does `printf '%s\t%s\t%s\t%s\n' ... >> "$PROTOCOL_LOG"`. The file is empty because the **local** coordination-audit path (`proto_log`/`proto_audit`) was never invoked in this repo; coordination this session runs over the MCP `heimdall-ledger`, not the local bash protocol. So `protocol.log` is a live-but-unexercised sink, not a dead one — the task's premise that it holds retries/collisions/reaps is simply not met here because no local coordination sequence ran.
- **Fix:** Either route real coordination through `protocol.sh` so the audit log populates (making these events mineable), or scope docs to say the audit log only fills on local (non-MCP) coordination. Don't treat empty as healthy, and don't treat it as broken.
- **Falsify:** Run a local coordination op that calls `proto_log`; confirm a tab-delimited line lands in `.planning/protocol.log`. It will — the appender is real.

### F6 — "Agents confidently write claims from partial reads" IS a recurring, evidenced class  · CONFIRMED (pattern)

- **Observation:** The four truth-pass doc defects this week (FAQ path, FAQ wire body, FAQ "four things", presence :350) are not isolated — the same class is directly visible in git history and reproduced here.
- **Evidence (git log, base `7ea54ea`):** a run of `fix(docs)/fix(...)` commits that correct stale claims written in good faith:
  - `22e133d fix(docs): correct stale README finding in SUBMISSIONS.md`
  - `34b3d5d fix(geo): correct stale README claim — bare telemetry line already removed`
  - `dde713e fix(npm): drift-proof runheimdall npm README`
  - `2e94aa3 fix(version): single-source version from plugin.json + drift gate`
  - plus F3a (SKILL.md:47 wrong command) and F4 (presence :350) found fresh in this pass.
- **Root cause:** No provenance gate on claims — a doc/comment can assert behavior the author only partially read, and nothing forces a re-verify against the code before merge.
- **Fix (structural):** a **claim-provenance gate** — when a doc/comment states a runnable claim (a command, a header name, a wire body, a count), the truth-pass must execute/grep it. F3a and F4 are exactly the kind a `grep+run` gate would have caught. Cheap first step: a CI check that every fenced `heimdall-*` command in `skills/**/SKILL.md` runs with exit 0 (would have caught F3a).
- **Falsify:** Add the SKILL-command smoke check; it fails today on SKILL.md:47. After F3a's fix it passes. If it never fails on a known-bad command, the gate is too weak.

### F7 — Mandated parallelism is measured and chronically low; the measurement drives nothing  · CONFIRMED

- **Observation:** CLAUDE.md mandates "2+ independent tasks → spawn ALL agents in ONE message," and `parallelism-tracker` measures compliance — but the numbers are low and no loop consumes them.
- **Evidence (metrics.jsonl, all 30 records):** aggregate **agent-batch ratio = 0.097** (30 batched / 308 agent calls); **in-turn parallel ratio = 0.094** (989/10561 turns). Large sessions barely batch: `2026-06-04` 89 agent_calls / 15 batched (0.17); `2026-07-11` 53/2; `2026-07-13` 73/6; `2026-06-26` 40/1.
- **Root cause:** The parallelism metric is written but **never read by the self-improve loop** (`collect` ignores non-`task` records at heimdall-self-improve:142). It accumulates as dead telemetry — measured, never acted on.
- **Fix:** Either surface parallelism ratio in the self-improve report (it's the only populated signal today), or accept it's advisory-only and stop implying it feeds routing. Pairs with F1: once `task` records exist, low-parallelism sessions can be correlated with outcomes.
- **Falsify:** `heimdall-self-improve` output references parallelism ratio, or a doc explicitly scopes it as advisory. Today neither is true.

### F8 — `.gitignore` ignores all of `.planning/`, contradicting CLAUDE.md's "git-committed" rule  · CONFIRMED

- **Observation:** Committing this very report required `git add -f` — `.planning/LOG-FINDINGS.md` is gitignored.
- **Evidence:** `git check-ignore -v` → `.gitignore:116:.planning/*`. CLAUDE.md (all three copies) states: *"Planning state lives in `.planning/` (human-readable, git-committed)."* The ignore rule makes that false for anything not explicitly force-added or re-included.
- **Root cause:** A broad `.planning/*` ignore (added to keep transient state out of git) directly conflicts with the documented convention that planning state IS committed. Whichever is intended, the two disagree.
- **Fix:** Decide the policy and make it consistent — either narrow the ignore to the transient files (`.planning/*.lock`, caches) and un-ignore human-readable planning docs, or amend CLAUDE.md to say planning state is local-only. Today a `git add` of a planning doc silently no-ops, which is a foot-gun (a prior agent could believe it committed planning state when it did not).
- **Falsify:** `git check-ignore .planning/LOG-FINDINGS.md` returns the path (ignored) while CLAUDE.md claims it is committed — already confirmed, the two contradict.

---

## Quick wins (≤1hr) vs structural

| # | Finding | Effort | Type |
|---|---------|--------|------|
| F3a | SKILL.md:47 wrong `collect` arg order | ~10 min | quick |
| F4 | presence:350 stale "sent ONCE" comment | ~10 min | quick |
| F3b | claude-mem install: skip not fail on no-TTY | ~30 min | quick |
| F5 | protocol.log unexercised sink — route coord or scope docs | ~30 min | quick |
| F8 | `.gitignore` `.planning/*` vs CLAUDE.md "git-committed" | ~10 min | quick |
| F1 | wire `metric:"task"` emitter at the gate | structural | structural |
| F2 | wire run-lifecycle telemetry into real run | structural | structural |
| F6 | claim-provenance / SKILL-command smoke gate | structural | structural |
| F7 | consume-or-scope the parallelism metric | small–structural | structural |

## Metrics summary + starvation root cause + SONA routing-override recommendation

- **metrics.jsonl:** 30 records, 100% `parallelism`, 0 `task`. Aggregate parallel ratios ~0.09 (F7).
- **experiments.jsonl:** 14 records, all `kind:incident`, all decided `keep` / `verified-in-prod|by-test`, logged 2026-07-05. These are bring-up incident postmortems, **not** routing A/B experiments — so the self-improve *experiment* loop has also never run a routing variant.
- **Starvation root cause:** `heimdall-self-improve collect` reads only `metric=="task"` (heimdall-self-improve:142); the sole metrics writer emits only `parallelism` (parallelism-tracker.c:259). No emit site for task outcomes exists → `total_task_records: 0` → hypotheses/experiment stages have nothing to fire on.
- **SONA routing-override recommendation:** Do **not** touch `routing-overrides.json` yet — with zero task samples, any override is unfalsifiable (violates the loop's own "falsifiability over vibes," heimdall-self-improve:26). **First** land F1 (emit `metric:"task"` from the real gate, threading `task_type` + `emitted_model` computed at heimdall:2673). Only once `collect` reports `samples >= --min-samples` (default 3) per `(task_type, model)` should `hypotheses` → `experiment start` be allowed to write an override.

## CONFIRMED vs SUSPECTED

- **CONFIRMED (evidence in hand):** F1 (collect run + writer census), F2 (event histogram + caller census), F3a (command errored), F3b (15 failed events enumerated), F4 (three comments — :350/:508 stale, :471 true — + code at :475), F5 (0-byte file + real appender at protocol.sh:66), F6 (git-log chain + F3a/F4 fresh), F7 (computed ratios), F8 (`git check-ignore` + CLAUDE.md text).
- **SUSPECTED (needs a run/trace):** Whether wiring F1/F2 at heimdall:2673 is the *correct* single hook vs. per-agent verifier return path — needs a read of the verifier gate to pick the exact emit site.

---
*No invented log data. Every claim above traces to a real file:line or a command run this session.*
