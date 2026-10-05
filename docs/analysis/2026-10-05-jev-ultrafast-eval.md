# jev-ultrafast evaluation: does it improve hmd web and browser use?

Date: 2026-10-05. Subject: https://github.com/browser-use/jev-ultrafast @ `1231850a` (2026-09-18, 3 commits, MIT).
Harness: `bash evals/jev-ultrafast/run.sh` (results: `evals/jev-ultrafast/results.json`).

## Verdict

**DON'T adopt as an `hmd web` backend. Live interaction arm BLOCKED (not measured), and it cannot change the verdict.**

- jev-ultrafast is an interactive click/type agent, not a page reader. It returns the final page URL, not page text. It cannot answer "fetch page, extract fact", crawl, or metadata. That is 12 of the 14 benchmark tasks and everything `hmd web` does today.
- The one thing it does that hmd lacks (interaction: click, type, submit) could not be run. It needs `TYPESAFE_API_KEY` and `TEXT_MODEL_API_KEY`; neither is set in this environment (checked by name only). Interaction arm = BLOCKED on those two keys. No jev numbers are reported.
- Even if unblocked: the decision-making brain is a hosted proprietary API (api.typesafe.ai). The MIT licence covers a ~850-line harness, not the model. hmd has no current interaction need that the existing Playwright plugin or claude-in-chrome do not cover.
- The real gap this eval exposed is **JS-rendered pages (0/2)**. jev is the wrong fix for it; see "What to do instead".

## What it is

| Item | Finding |
|---|---|
| Kind | Python agent library + local inspector (`uv run jev` on 127.0.0.1:8766). Not a model, not an MCP server, not a CLI for fetching. |
| Loop | Snapshot DOM into an indexed element table, send `{url, title, visible text up to 6000 chars, elements, last 10 actions}` to TypeSafe `jev-latest` (`POST https://api.typesafe.ai/v1/systemone`), which picks an operation (CLICK, TYPE_TEXT, SELECT, SCROLL_UP/DOWN, WAIT, DONE, BLOCKED) and a target. A small LLM (OpenRouter `inception/mercury-2.5` by default) writes text only for TYPE_TEXT. |
| Install | `git clone`, `uv sync`, `cp .env.example .env`, add keys. Needs Python >=3.12, `uv`, and Chrome with remote debugging enabled. |
| Keys | `TYPESAFE_API_KEY` (paid, hosted Jev), `TEXT_MODEL_API_KEY` (OpenRouter or any OpenAI-compatible endpoint). |
| Claims | Google Flights ZRH to LHR in 7.07 s; matched A/B vs its own earlier version: median 9.45 s to 7.09 s, 3 pairs, sign-test p=0.25. Authors state it is "not a general reliability benchmark". Out of scope per README: shadow roots, frames, canvas, uploads, pop-up tabs, nested scrolling. |
| Provenance | `browser-use` org, Browser Use x TypeSafe. 22.1k stars at fetch time. Repo has 3 commits. |

## Install footprint (measured, scratch clone, deleted afterwards)

- `uv sync`: 5.6 s, `.venv` 47 MB (includes dev group: pytest, ruff, pillow), repo checkout 4.8 MB. Disk free before: 5 GB (above the 3 GB stop line).
- 31/31 offline unit tests pass (`uv run pytest`, 2.5 s). So it installs cleanly with no key; only live runs need keys.
- Runtime deps: `browser-harness==0.1.13`, `httpx[http2]`, which pull `cdp-use`, `fetch-use`, `pillow`, `websockets`, `h2`, `anyio` and others. 23 packages in `uv.lock` total, 22 installed with dev group. hmd's own web path today: 0 third-party packages (stdlib only).

## hmd current web and browser surface

- `bin/heimdall-web` to `bin/lib/web_fetch.py`: `fetch | crawl | batch | meta`. Stdlib only, robots.txt respected, SSRF guard with connection pinning, no credentials ever sent, byte/page/wall-clock caps, URL cache. Tested hermetically in `test/heimdall-web.test.sh`. Static HTML only; no JS execution; read-only.
- Native `WebFetch` (one URL, model-summarised every call) and `WebSearch` (no bodies) used by agents; `hmd web` fills the crawl/batch/meta/raw-markdown gaps (see `2026-09-05-web-research-tools-rollout.md`).
- Browser automation in-repo: only designmatch's Playwright rendering for visual QA (`bin/lib/designmatch_targets/web.py`) and plugin detection for `playwright` in `heimdall-skills.json`. No interaction agent.

## Benchmark

14 tasks x 3 reps, hmd arm measured. Rows that need determinism (JS-rendered, deep crawl, form, click-reveal) run against a local 127.0.0.1 fixture; the rest hit live public pages. Success = expected regex present in tool output (hmd) or server-side fixture state flipped (jev, interaction only). "Ctx tokens" = output chars/4, i.e. what an agent would pull into context if it read the whole result; hmd itself spends zero model tokens.

| Task | cat | hmd pass | median s | ctx tokens |
|---|---|---|---|---|
| doc-python-json | doc-fact | 3/3 | 0.51 | 9,499 |
| doc-wikipedia-godel | doc-fact | 3/3 | 1.65 | 41,045 |
| doc-mdn-418 | doc-fact | 3/3 | 0.50 | 764 |
| doc-sqlite-limits | doc-fact | 3/3 | 3.12 | 4,486 |
| doc-semver | doc-fact | 3/3 | 0.55 | 4,832 |
| doc-rfc8259 | doc-fact | 3/3 | 1.84 | 9,167 |
| crawl-live-pytutorial (depth 1, 6 pages) | crawl | 3/3 | 5.99 | 270,095 (whole dump; grep it, do not read it) |
| crawl-fixture-deep (depth 2) | crawl | 3/3 | 0.35 | 98 |
| meta-github-jev | meta | 3/3 | 1.99 | 617 |
| meta-semver | meta | 3/3 | 0.53 | 624 |
| js-fixture-inject | js-rendered | **0/3** | 0.67 | 2 |
| js-live-quotes | js-rendered | **0/3** | 2.37 | 24 |
| interact-fixture-form | interaction | 0/3 (unsupported by design) | n/a | n/a |
| interact-fixture-reveal | interaction | 0/3 (unsupported by design) | n/a | n/a |

Aggregate hmd: 30/42 runs. By category: doc-fact 18/18, meta 6/6, crawl 6/6, js-rendered 0/6, interaction 0/6.

jev-ultrafast arm:

| Category | Result |
|---|---|
| doc-fact, crawl, meta, js-rendered (10 tasks) | NOT_APPLICABLE. No text-extraction output; it returns the final URL. Running it would have produced a pass/fail with nothing to compare. |
| interaction (2 tasks) | **BLOCKED**: missing `TYPESAFE_API_KEY`, `TEXT_MODEL_API_KEY` (and `JEV_DIR` pointing at a clone; the scratch clone was deleted). Wall time, token and cost columns intentionally empty. |

Caveats on the numbers: 3 reps per task; live rows depend on the network and the sites (all passed, so no flakiness observed). `hmd web` itself was observed to reject `--no-cache` on `crawl` although `--help` lists it under common options; the harness works around it. Interaction rows for hmd are scored as failures only to make the capability gap visible; they are a gap, not a defect.

The harness's jev path is written but UNTESTED end to end (blocked). To run it: `JEV_DIR=<clone> TYPESAFE_API_KEY=... TEXT_MODEL_API_KEY=... bash evals/jev-ultrafast/run.sh`, with Chrome remote debugging enabled. It sets the three telemetry opt-out env vars for the jev subprocess.

## Security and licence

| Area | Finding | Risk to hmd |
|---|---|---|
| Licence | MIT on jev-ultrafast, `browser-harness`, `cdp-use`/`fetch-use` per PyPI metadata (browser-harness verified MIT; others not independently checked). Compatible with hmd. The hosted TypeSafe model/API is separate terms, not reviewed. | low |
| Data egress | Every step sends the page URL, title, up to 6000 chars of visible text and the element table to api.typesafe.ai; text generation sends page context (6000 chars) to the OpenRouter endpoint. Password, file, and hidden inputs are excluded from the element table, but visible page text is not scrubbed. hmd's current web path sends nothing to any third party. | high for anything behind a login |
| Browser identity | Attaches to your existing Chrome profile over CDP (README: "Owned tabs share the existing Chrome profile"). Logged-in sessions and cookies are in scope of every action. hmd `web_fetch.py` is the opposite: never sends cookies or credentials. | high |
| Telemetry | `browser-harness` ships a PostHog client (`eu.i.posthog.com`) in `telemetry.py`, opt-out via `BH_TELEMETRY`, `BROWSER_HARNESS_TELEMETRY`, `ANONYMIZED_TELEMETRY`. It is wired in the `browser-harness` CLI entrypoint (`run.py`); jev imports only `admin.ensure_daemon` and `helpers.cdp`, which do not reference it, but the README tells users to run `browser-harness --doctor`, which is the CLI path. The harness also has a PyPI version-check URL and `api.browser-use.com` / `fetch.browser-use.com` endpoints (cloud features, not exercised). jev-ultrafast itself has no telemetry code (grep clean). | medium, mitigable by env opt-out |
| Supply chain | 23 locked packages, `browser-harness` pinned `==0.1.13` and its transitive pins fixed in the lock. Maintainer is a recognised org. Repo age ~3 weeks, 3 commits; README documents git-clone install only (PyPI publication not checked), so no tagged release to pin. Also a README-embedded cloud waitlist: the project is a funnel to a paid cloud product. | medium |
| Prompt injection | Page text goes into a policy model that can click and type on a logged-in profile. Authors mitigate (targets must map to observed nodes; no selectors or code from the model), but there is no domain allowlist. | medium to high |

## Integration sketch (not recommended; for the record only)

If a future need for interaction appears AND the keys exist, the least bad shape is:

- `hmd web interact <url> --goal "..." --backend jev` as a new subcommand, never as a `fetch` backend.
- Opt-in only: requires `HMD_WEB_BACKEND=jev` plus both keys; absent any of them it exits 0 with one stderr line (fail-open, same as the missing-python behaviour in `bin/heimdall-web`).
- Isolated Chrome profile (fresh `--user-data-dir`), never the user's; a domain allowlist; telemetry opt-out env set on the subprocess; page-text egress warning printed once.
- Must keep the existing `heimdall-web` SSRF and robots guarantees by routing the initial URL through `web_fetch.py`'s validator first.

## What to do instead (follow-ups, not done here)

1. **JS-rendered reads (the measured 0/2 gap):** add a headless-render fallback to `hmd web fetch --render` using a locally installed Chromium (`chrome --headless --dump-dom`) or the Playwright that designmatch already depends on. No hosted model, no egress, no profile sharing. This is the improvement the benchmark actually motivates.
2. Fix `crawl` rejecting `--no-cache` while `--help` lists it as a common option.
3. Re-evaluate jev only if hmd gains a concrete interaction use case and a decision on sending page text to a third party.

## OUT OF SCOPE

- Any integration code under `bin/` (explicitly deferred this round).
- Native `WebFetch`/`WebSearch` timing or cost; they cannot be invoked from a shell harness.
- Live jev runs (blocked on keys); jev reliability on Google Flights or other sites; TypeSafe pricing; the Browser Use Cloud product.
- Security audit of `browser-harness` beyond grep for telemetry and endpoints.
- Implementing `--render` (follow-up 1).
