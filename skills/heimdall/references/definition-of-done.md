# Definition of Done

> **Attribution**: The Rationalization guard and Red Flags patterns referenced here are
> adapted from [addyosmani/agent-skills](https://github.com/addyosmani/agent-skills)
> (MIT, "Addy Osmani + contributors").

The canonical checklist every Heimdall agent cross-checks before reporting DONE. A task is
done when this checklist **passes with evidence** — not when the diff looks finished, not
when it "should work". Small-but-broken FAILS.

## The Checklist

- [ ] **Tests pass** — the test file(s) YOU added or edited ran ONCE, after your last edit: exit 0, output pristine. No skipped or `.only` tests left behind. Neighbouring suites and the full sweep are not a per-agent box — the orchestrator runs ONE full sweep on the final frozen tree immediately before the landing commit / push / demo / checkpoint (`CLAUDE.md` "When the full gate runs"), and for THAT run this box reads: the full-equivalent sweep (every suite run fresh or served from the verified per-suite cache, receipt `full_equivalent`) ran on the frozen tree, exit 0; after a red, `bash test/run-all.sh --failed` is that run, not a second full sweep.
- [ ] **Tests are proportionate** — a NEW test keeps the falsifiability floor (every behaviour claim has an assertion that goes RED on an injected defect, never traded for speed) and a small cost: it runs in 10 s or less solo, calls `bin/heimdall-<sub>` directly and not the `bin/heimdall` dispatcher (unless the dispatcher is what it tests), and carries a `# budget: <s>` header line if it must run longer than 30 s. Whether a suite needs to run for this diff is the suite cache's call, not a reason to re-run it by hand (`agents/coder.md` "Tests: the same ladder, proportionate").
- [ ] **Acceptance criteria runnable** — every criterion is a grep / curl / test / file-existence command that was actually run, not prose. Each exits 0.
- [ ] **No stubs** — zero `// TODO`, `pass`, `throw new Error('not implemented')`, empty bodies, fake data, or placeholder returns. Every line is production-ready.
- [ ] **Lint / build clean** — linter and build ran fresh, zero warnings, zero errors.
- [ ] **Verification evidence quoted** — the command AND its exit code / output appear in the status report. No claim without a fresh run behind it.
- [ ] **Scope respected** — only files in the assigned scope changed; no unrelated refactors, no feature creep.
- [ ] **No CI re-rolls** — a failing or flaky CI result was fixed (a test must not depend on the wall-clock speed of a shared runner: count steps, not seconds, or mark it local-only) or reported, never re-rolled: no empty commit (`git commit --allow-empty`), no `gh run rerun`, no `gh workflow run` to retrigger it. The Bash hook denies them (`CLAUDE.md` "CI waste guard"); each one pays GitHub Actions minutes for the same code.
- [ ] **Isolation 1.0 where applicable** — for tasks with a falsifiability oracle, `bin/falsify <domain> --assert-score 1.0` passes (golden green, every mutant killed).
- [ ] **Red flags named** — the agent has explicitly listed the red flags it sees (or "none, and here's why"), per its role-specific checklist.

## Rationalization Guard

Do not rationalize skipping any line above. If you catch yourself thinking **"I'll fix it
later"**, **"this is too simple to test"**, or **"close enough"** — STOP and do it properly.
Those three thoughts are the failure mode this checklist exists to catch.

## How agents use it

- **coder** — cross-check before every DONE; the checklist is the floor beneath the Lazy Ladder.
- **architect** — every emitted plan's acceptance criteria must be gradable against this checklist; unrunnable criteria fail plan-verification.
- **reviewer** — grade the diff against this checklist; a box that cannot be checked with evidence is a REQUEST CHANGES or BLOCK.
