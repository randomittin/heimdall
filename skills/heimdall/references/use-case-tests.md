# Use-Case Tests — how a managed (client) repo is tested

Operator directive 2026-11-12, about every repo hmd manages except heimdall's own: *"testing is always extra and never testing actual usecases and always testing random scripts against general checks and wasting tokens."* The measured case: on a client repo an hmd agent planned ruff + all ~917 pytest files + offline evals before tagging, and the push gate's sweep class had already pushed that repo into writing a full-sweep `test/run-all.sh`. The operator's answer: *"linting is okay but instead of python tests -- make test cases for real usecases, like booking a cab, coffee, meal, email search etc."*

A **client repo** is any repo that is not heimdall's own (the plugin source: `.claude-plugin/plugin.json` named `hmd`, plus a `test/run-all.sh` that writes `last-sweep.json`). Heimdall's own repo keeps its sweep regime (`CLAUDE.md` "When the full gate runs"); nothing here changes it.

## The rule

1. **The release/tag gate is `lint` + the use-case suite.** Nothing else gates a client repo: no full unit-suite sweep, no offline-eval sweep, no coverage threshold. The gate run follows heimdall's own rule for the full sweep (`CLAUDE.md` "When the full gate runs"): it is RECOMMENDED to the developer immediately before a merge operation or the release, with why, the command (`bin/heimdall-repo-checks run`) and the cost (wall time, a token estimate), and it runs when the developer says so. An agent never starts it on its own initiative, not after a change lands and not "to be safe"; the push gate still needs the green receipt, so the developer's yes is what produces it.
2. **During work, run only the tests of the files you touched, once** — after all changes are written; one solo re-run for a failure plausibly caused by machine load. No full unit-suite sweep, no offline-eval sweep as a gate, no "regression" run of unrelated suites.
3. **Never create a full-sweep runner in a client repo to satisfy an hmd gate.** A `test/run-all.sh` naming `last-sweep.json` grades the repo as the sweep class, heimdall's own regime. Declare `.heimdall/repo-checks.json` (the repo-checks class) with the checks `lint` and `use-cases` instead.
4. **"Test" means use-case scenarios first.** Write or extend the scenario for the journey the change touches; add a unit test only to pin a specific bug.
5. **Every report names the user journeys the change was proven on** — journey → scenario → result, e.g. `book a cab → test_book_a_cab → pass` — or says no journey was touched and why (`none: internal refactor, lint only`).

## Derive the journey list

A journey is one thing a user comes to the product to get done and can tell whether it happened: "book a cab", "order coffee", "order a meal", "search email", "cancel a booking".

- Read the promises: README, product and landing copy, `--help` and the command list, API summaries, onboarding screens, the owner's user stories. Every "you can …" / "ask it to …" is a candidate.
- One line per journey, in the suite's header or the repo's own docs. Add a failure path only where the product promises one ("no driver nearby → the rider is told and nothing is charged").
- Docs thin or silent: ask the owner once, batched (`agents/heimdall.md` §2d). Never derive the list from the module tree — that is the "random scripts against general checks" the directive rejects.
- The list is the suite's spec: a promised journey with no scenario is a gap; a scenario with no promised journey is deleted.

## Scenario shape

Given / when / then against the **public entry point** — the door the user uses: the CLI command, the HTTP route, the chat or message handler, the app action, the job trigger. Never an internal function.

- **given** — the world before, built through the public path or the repo's own fixtures: the user, the saved card, the driver nearby, the inbox with three mails.
- **when** — the user's action, worded as the user words it: `"book me a cab to the airport at 6am"`, `POST /orders`, `mail search --from asha`.
- **then** — what the user can observe and what the product promised: the reply, the booking or order that now exists with the right fields, the one charge of the right amount, the notification sent, and the negative promise where there is one (a declined card books nothing). Assert outcomes and what the fakes recorded, never call sequences or internal state.

One journey per scenario, readable top to bottom. The shape (pytest; the fixture names are the repo's own):

```python
def test_book_a_cab(app, fake_payments, fake_maps):
    rider = app.signup("asha", saved_card="tok_visa")                # given
    fake_maps.driver_nearby(eta_min=4)
    reply = app.say(rider, "book me a cab to the airport at 6am")    # when
    assert reply.booking.status == "confirmed"                       # then
    assert fake_payments.charges == [("tok_visa", reply.booking.fare)]
```

## Where the fakes go

Real code end to end, from the entry point to the datastore. Fakes only at the **external boundaries** the repo does not own: payments, the network and third-party APIs (maps, driver supply, email and SMS providers, calendars, OAuth), the LLM, and the clock and randomness when the journey depends on them.

- Not faked: the repo's own routers, services, queues, prompts and tool code, and its database (a real sqlite, in-memory or disposable one).
- One fake per external system, at the client or adapter seam, in one shared place (for example `tests/use_cases/fakes/`). It implements the real client's interface, records what it was sent so **then** can assert on it, and can be told to fail so the promised failure path runs. An LLM fake returns scripted replies keyed to the scenario's user message; the agent loop and the tools run for real.
- A scenario that patches one of the repo's own functions to pass is testing a script, not a journey: move the seam out to the boundary.

## Naming, size, speed

- **Named after the journey, in the user's words**: `test_book_a_cab`, `test_order_coffee_with_oat_milk`, `test_search_email_by_sender`, `test_declined_card_books_nothing`. A red name reads as the broken promise.
- **One directory** (for example `tests/use_cases/`) or marker, so the `use-cases` check runs exactly the suite and nothing else.
- **Small and fast**: tens of scenarios, not hundreds; the whole suite in about a minute. Hermetic (no network, no real payments, frozen clock, seeded randomness), so a red is a broken journey, never a slow runner: count steps, not seconds. A flaky scenario is fixed or reported, never re-run to green.

## The gate: `.heimdall/repo-checks.json`

```json
{"schema":1,"checks":[
  {"name":"lint","cmd":"ruff check ."},
  {"name":"use-cases","cmd":"pytest tests/use_cases -q"}
]}
```

- Track the declaration and gitignore `.heimdall/receipts/` (the receipt is build output). Each `cmd` runs with `bash -c` from the repo root, in order, every one even when an earlier one fails.
- `lint` may chain the repo's own linter, formatter check and type check in one command. Do not add a check that sweeps unit tests or evals: it puts back what this rule removes. Other stacks: `npm run lint` + `npm run test:use-cases`; `golangci-lint run` + `go test ./usecases/...`.
- Adopting it: derive the journey list, write the scenarios, commit the declaration (it is read as committed at HEAD, never from the work tree), then `bin/heimdall-repo-checks run` (when the developer chooses the run) records the receipt and `status` says whether it is green and current. The push gate passes a push on a green receipt for the commit it sends (`quality-gates.md` "Which gate runs"); a commit after the run makes the receipt stale, so run it again after the last commit.
