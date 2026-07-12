# Definition of Done

> **Attribution**: The Rationalization guard and Red Flags patterns referenced here are
> adapted from [addyosmani/agent-skills](https://github.com/addyosmani/agent-skills)
> (MIT, "Addy Osmani + contributors").

The canonical checklist every Heimdall agent cross-checks before reporting DONE. A task is
done when this checklist **passes with evidence** — not when the diff looks finished, not
when it "should work". Small-but-broken FAILS.

## The Checklist

- [ ] **Tests pass** — the full suite ran fresh THIS turn, exit 0, output pristine. No skipped or `.only` tests left behind.
- [ ] **Acceptance criteria runnable** — every criterion is a grep / curl / test / file-existence command that was actually run, not prose. Each exits 0.
- [ ] **No stubs** — zero `// TODO`, `pass`, `throw new Error('not implemented')`, empty bodies, fake data, or placeholder returns. Every line is production-ready.
- [ ] **Lint / build clean** — linter and build ran fresh, zero warnings, zero errors.
- [ ] **Verification evidence quoted** — the command AND its exit code / output appear in the status report. No claim without a fresh run behind it.
- [ ] **Scope respected** — only files in the assigned scope changed; no unrelated refactors, no feature creep.
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
