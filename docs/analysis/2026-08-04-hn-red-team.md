# HN Red Team — hostile pre-launch audit

**Date:** 2026-08-04
**Repos:** `/Users/rj/Downloads/heimdall` @ `30a8073`, `/Users/rj/Downloads/heimdall-site` (local working tree + live `https://runheimdall.dev`)
**Mode:** READ-ONLY. No code changed. Nothing pushed, deployed, or written to the control plane.
**Ranked by:** reputational damage if it is the top reply, not CVSS.

---

## What I actually sampled

I did **not** run the full board (~80 min). What ran:

| Probe | Command | Result |
|---|---|---|
| Published one-liner, end to end | `curl -fsSL .../v2.3.8/install.sh \| shasum -a 256` | `28bbdcd…d84580` — **matches** <!-- HEIMDALL:PIN:FROZEN — a probe result measured on the audit date, not a current claim --> |
| npm wrapper pin | read `packages/runheimdall/package.json` | tag + sha256 both correct |
| Stale-digest sweep | grep `168646ba` / `fafe31e` across both repos | only in `test/version-drift.test.sh` as documented history |
| Isolation oracle | `bin/falsify rr-multitenant-isolation --assert-score 1.0` | `SCORE: 23/23 = 1.0000`, exit 0 |
| Headless gate | `bin/heimdall-gate-run --phase pre-push --json` | exit 0, **zero stdout** |
| Regression corpus | `bin/corpus run` | `13/13 caught = 100%`, exit 0 |
| Module add, non-TTY | `HMD_MODULES_STATE=<tmp> HMD_MODULE_FETCH_DRYRUN=1 bin/heimdall-modules add headroom </dev/null` | installed, 6/6 invariants PASS, **no prompt** |
| Secret history | `gitleaks detect` — with config, with defaults, and with `--gitleaks-ignore-path /dev/null` | 1171 commits, **no leaks** in all three |
| Gate sample | `test/module-consent-waiver` (65/65), `test/public-repo-no-secrets` (4/4), `test/crontab-safe` (33/33), `test/cp-public-surface` (25/25) | all green |
| Exit-plumbing sweep | every `test/*.sh` for failures that cannot reach the exit code | **none found** — the `[ "$FAIL" -eq 0 ]` tail idiom is sound |
| Absence-grep sweep | `! grep -q` gates without an existence guard | 1 hit, covered by a sibling arm (see #12) |

---

# The findings

## 1. The site publishes `6 / 6` directly beside the command that prints `23/23`

> *"Their headline claim is that every number traces to a runnable command. So I ran the command they printed under the number. `bin/falsify rr-multitenant-isolation --assert-score 1.0` → `SCORE: 23/23`. The page says 6/6. If the one number I can check in ten seconds is wrong, why would I trust the ones I can't?"*

**Truth.** Verified. The oracle has 23 mutants (`ls evals/oracles/rr-multitenant-isolation/fixtures/mutants/*.mjs | wc -l` → 23). It shipped at 6 (`06da86e`) and grew through `02e1041`, `0d97ff0`, `4a1d1a3`, `3208b5f`, `3c6a0d4` — the last of which is literally titled *"AT7 same-repo-one-team convergence gate (23/23, falsifiable)"*. The site never followed. Live and local, in four places:

- `heimdall-site/proof.html:121` — `6 / 6 = 1.0` with `bin/falsify rr-multitenant-isolation --assert-score 1.0` rendered inline next to it
- `heimdall-site/proof.html:68` — nav: `Isolation oracle · 6/6`
- `heimdall-site/proof.html:11` — `<meta name="description">`: *"a cross-tenant isolation oracle that kills 6/6 mutant attacks"*
- `heimdall-site/index.html:245` — *"six mutant attacks … it kills **6 / 6 = 1.0**"*
- `heimdall-site/team.html:88` — *"an oracle that kills 6/6 attacks"*

The `6/6` is real — it belongs to **`exchange-lob`** (`evals/flagship/STATUS.md:25`). It was copied onto the wrong oracle and then frozen while the right one nearly quadrupled.

This is the single most damaging finding available, and not because the number is bad. It *undercounts by 17*. The damage is that the project's entire differentiator is "our numbers are falsifiable and you can re-run them", and the most prominently-displayed number-plus-command pair on the site does not reproduce.

**Response: FIX BEFORE LAUNCH.** Replace `6 / 6` with `23 / 23` in all five locations above. Then add the guard that should have existed: a gate that parses each `N/M` on the site against a live `bin/falsify <domain>` run, the same way `test/version-drift.test.sh` gates the install digest. A number on a marketing page with a command under it is a claim under test — treat it like one.

---

## 2. Headroom appears in zero public documents, and the update prompt promises a consent question the install path does not ask

> *"They ship a default-included local proxy that reads your prompts on the way to the model. It's not in the README. Not in SECURITY.md. Not in the CHANGELOG. Not on the site, the FAQ, or llms.txt. The only place it exists is a manifest you'd have to go looking for."*

**Truth.** Verified by count:

```
grep -ci headroom README.md SECURITY.md CHANGELOG.md            → 0, 0, 0
grep -ci headroom heimdall-site/{index,faq}.html llms{,-full}.txt → 0, 0, 0, 0
```

Now the mitigation, which is real and matters: **nothing auto-installs it.** The shipped `install.sh` at v2.3.8 contains no reference to modules at all (verified against the fetched published bytes). `bin/heimdall-autoupdate` transition 3 explicitly *defers* consent-requiring modules and never passes `--yes`. The manifest disclosure is, genuinely, some of the most honest technical writing in the repo — it volunteers that the storage-codec half **cannot engage** from the documented install, and says so in the same breath as declaring the class. <!-- HEIMDALL:PIN:FROZEN — names the tag whose published bytes were actually read; a later tag was never inspected -->

But there is a hard contradiction between two shipped code paths. On a manual update the user is told (`bin/heimdall-autoupdate:518-523`):

```
heimdall: "headroom" ships in hmd's default module set and is not installed here.
heimdall:   it is class traffic-proxy + storage-codec, which requires your explicit consent — so an update
heimdall:   will never install it for you. Install it yourself with:
heimdall:     hmd modules add headroom
```

The user then runs that command and is **not asked**. I ran it. `obtain_consent` (`bin/heimdall-modules:637-670`) returns at line 670 on `consent_waived: true`, *before* the `[ -t 0 ]` prompt at line 684. It printed `CONSENT WAIVED — this is disclosure, not a question.` and installed under `</dev/null`.

Same file's header comment then claims defence-in-depth that does not exist for this module (`bin/heimdall-autoupdate:404-406`): *"`heimdall-modules` independently refuses a consent-required install when stdin is not a terminal. Two gates, and BOTH would have to be wrong for a silent install to happen."* For Headroom — the only module this paragraph names — gate two is disabled by its own manifest. One gate stands.

**Response: FIX BEFORE LAUNCH**, three small changes, none of them to the design:

1. Reword `bin/heimdall-autoupdate:520` — it must not say "requires your explicit consent" for a module whose question is waived. Say: *"class traffic-proxy + storage-codec. An update will never install it for you. It discloses what it does at install time and does not stop to ask."*
2. Correct the "two gates" comment at `bin/heimdall-autoupdate:404-406` — one gate stands for Headroom.
3. Put **one paragraph** in `README.md` and one in `SECURITY.md`. Not a page. The manifest's own `consent_text` is already the right paragraph; lift it. The defence "we disclose it" is only true where a reader will find the disclosure, and right now the only reader who finds it is one who already decided to install.

---

## 3. `hmd modules add` executes a remote install and verifies no digest, under a heading that says "digest-verify"

> *"`hmd modules add` shells out to `uv tool install headroom-ai[all]==0.33.0`. Their manifest carries an `artifact_sha256`. That digest is never compared to anything. The installer prints `[5/7] install + digest-verify` and then `digest: present-upstream`, which is not a digest. A version pin is not a supply-chain control — PyPI yanks, re-uploads, and account takeovers are all live threat models, and `[all]` drags in Rust/ONNX/HuggingFace with nothing pinned at all."*

**Truth.** Verified. `bin/heimdall-modules:982-993` — the `else` branch (upstream kind) runs the fetch, then determines presence by asking `uv tool list` whether the package name appears. `pinned_version.artifact_sha256` is validated as *well-formed 64-char lowercase hex* by the manifest validator (line 425-429) and then never used. My non-TTY add printed exactly:

```
  [5/7] install + digest-verify
        digest: present-upstream
```

The JSON receipt is honest — it says *"no artifact existed to hash HERE"*. The terminal is not.

And the receipt contains a claim that is false: `bin/heimdall-modules:993` says *"the pin is RECORDED and **re-checked by `verify`**"*. `cmd_verify` (lines 1413-1465) resolves classes and runs invariants. It touches no digest. I grepped the whole function and `run_invariants` for `sha256|digest|pinned` — zero hits. Headroom's four manifest invariants contain no digest check either.

**Response: FIX BEFORE LAUNCH** — wording is mandatory, verification is a judgement call.

- **Mandatory:** stop printing `install + digest-verify` on a path that verifies no digest. Print `[5/7] install + provenance` and `provenance: upstream, pin recorded, not hashed here`. Delete "re-checked by `verify`" from line 993 or make `cmd_verify` actually re-check something.
- **Recommended:** `uv` supports `--require-hashes` via a lockfile. Even shipping a `uv.lock`/requirements file with hashes for the direct dependency would convert "we wrote the version down" into "we refuse a different artifact". If that is too heavy before launch, say so out loud rather than dressing it up — see pre-emptive disclosure.

The rest of this surface is **DEFENSIBLE** and the rebuttal is strong: nothing is vendored, removal is byte-identical, the fetch is bounded (`HMD_MODULE_FETCH_TIMEOUT`, default 1800s), presence is read from the installer rather than inferred from an exit code, and a fetch that exits 0 having installed nothing reports ABSENT and rolls back (`bin/heimdall-modules:916`).

---

## 4. The website's copy button hands you `curl | bash` with no digest, on the page that sells you on the digest

> *"Their README has a whole threat table telling me 'the digest check is the only thing between you and whatever those bytes are.' Their website's install button is `curl -fsSL … | bash`. No shasum, no `&&` chain, nothing. Which one is the product?"*

**Truth.** Verified on the **live site**, not just locally:

<!-- HEIMDALL:PIN:FROZEN:BEGIN — a verbatim transcript of what the live site served on the audit date. Rendering it would restate the quotation as a fresh measurement nobody took. -->
```
$ curl -fsSL https://runheimdall.dev/ | grep -o 'curl -fsSL[^<]*'
curl -fsSL https://raw.githubusercontent.com/randomittin/heimdall/v2.3.8/install.sh | bash
```
<!-- HEIMDALL:PIN:END -->

That is the only `curl` on the page (`heimdall-site/index.html:405`). No digest appears anywhere in `index.html`. Meanwhile `README.md:47` grades this exact path **"Highest"** risk and says *"The digest check is the only thing between you and whatever those bytes are. Verify it, or take path 3."* And `llms.txt:17` advertises *"Tag-pinned and sha256-checked one-liner; the `&&` chain is load-bearing"* — describing a command the site does not print.

`https://runheimdall.dev/install` 302s to the raw GitHub URL, so the npm path and the redirect are both fine. This is purely the homepage CTA.

**Response: FIX BEFORE LAUNCH.** Put the digest-checked form on the homepage. `llms-full.txt:43` and `netlify.toml:25` already carry `28bbdcd…d84580` — the value is in the repo, it just never reached the button. This is a two-line HTML change and it converts a top-reply into a screenshot the owner would want taken.

---

## 5. The gate's own persisted receipt reports `corpus 3/13` after a perfect `13/13` run

> *"A project whose whole thesis is receipts, whose receipt says 3/13 when the run says 13/13."*

**Truth.** Verified end to end.

```
$ bin/corpus run                  → 13/13 caught = 100%, exit 0
$ cat .heimdall/verdict.json      → {"id":"corpus","state":"pass","detail":"3/13"}
```

The bug is at `bin/heimdall-gate-run:101`:

```sh
CCOUNT="$(printf '%s' "$OUT" | sed -n 's/.*\([0-9][0-9]*\/[0-9][0-9]*\).*/\1/p' | tail -1)"
```

The leading `.*` is greedy, so it consumes as far as possible and the capture group matches at the **last** viable start position inside `13/13` — the second character. Proof:

```
$ echo '  row: | 0.1 | 13 cases | 13/13 caught | 100% |' | sed -n 's/.*\([0-9][0-9]*\/[0-9][0-9]*\).*/\1/p'
3/13
```

`verdict.json` is documented as *"the source of truth for `hmd verdict` + the beat"* and is read by `bin/heimdall-clip` (a **shareable** artifact), `bin/summary-card`, `bin/heimdall-status-json`, `bin/heimdall-gate-surface`, `bin/lib/report.py`. `3/13` reads as a catastrophic regression. It is a regex bug.

**Response: FIX BEFORE LAUNCH.** Anchor the extraction to the line the corpus actually emits rather than scraping any `N/M` on any line — e.g. match `caught` on the `[corpus catch-rate]` line, or have `bin/corpus` emit a machine field and read that. Then add the arm that would have caught it: assert `detail` equals the corpus runner's own printed count.

---

## 6. `heimdall-gate-run --json` is a documented flag that does nothing

> *"`--json` is in the usage block. It parses. It sets a variable. Nothing ever reads it. You get an empty stdout and exit 0, which is indistinguishable from 'no gates ran'."*

**Truth.** Verified. `bin/heimdall-gate-run:18` documents `[--json]`; line 37 initialises `JSON=""`; line 41 sets `JSON=1`. `grep -n 'JSON' bin/heimdall-gate-run` returns those three lines and `GATES_NDJSON` (an unrelated statusline feed). I ran it and captured `OUT_LEN=0` on exit 0.

This is the headless entrypoint a plain git hook runs. Anyone wiring it into CI reaches for `--json` first.

**Response: FIX BEFORE LAUNCH.** Either emit the verdict JSON it already assembles for `verdict.json`, or remove the flag from the usage block. A flag that silently no-ops is worse than an absent one.

---

## 7. The per-team daily spend cap fails open, and the site advertises it without qualification

> *"'per-team daily spend cap' on the marketing page. In `bin/lib/cp_daily_budget.py` there is a method literally named `_log_fail_open` that writes `FAIL-OPEN daily spend cap on backend error — daily ceiling not enforced this call; $1k billing budget is the backstop`. So the cap is a cap until Firestore hiccups, at which point my Claude subscription is uncapped and the backstop is someone else's $1000."*

**Truth.** Verified. `bin/lib/cp_daily_budget.py:208-217` and the `check_and_consume` docstring at 235-238:

> *"FAIL-OPEN: on ANY backend error the gate returns ok=True (failed_open=True) — a cost cap must not lock out a legit team on a transient store hiccup; the billing budget is the hard backstop."*

The engineering is defensible and well-executed: the fail-open is deliberate, it is flagged in the return value (`failed_open=True`), it emits one loud token-free stderr line that logs only the exception *type* and never the `team_id`, the logger is wrapped so a logging failure cannot defeat the caller, and a zero/negative cap is treated as an explicit kill switch that **refuses** rather than failing open. That is careful work.

The problem is only that `heimdall-site/index.html:245` says *"under a **per-team daily spend cap**"* flat, and a reader who greps the source finds the words FAIL-OPEN in capitals. Note also that this contradicts the project's own stated principle elsewhere — the `no-signed-traffic-routing` invariant states *"an unverifiable invariant is never allowed to read as a pass"* and fails closed. The budget gate does the opposite, for good reasons that are not written on the page.

**Response: CONCEDE, and say it first.** Change the site to *"per-team daily spend cap, with a hard billing-budget backstop — the cap fails open on a store error rather than locking out a paying team, and every fail-open window is logged."* That sentence is stronger than the current one, because it shows the trade-off was chosen rather than missed.

---

## 8. The Show HN draft cannot be posted: 29 unresolved `[RECEIPT:]` markers, and the cohort it is built around never ran

> *"The launch post is a template with the numbers still missing."*

**Truth.** Verified — 16 markers in `launch-docs/SHOW-HN-DRAFT.md`, 13 in `launch-docs/log-compression-and-gates.md`. The headline itself is a template: *"Show HN: Verification gates for AI coding agents – what [RECEIPT: N] teams' watchmen caught in 2 weeks"*.

**This finding does not survive contact**, and that is worth knowing before someone tries it. The drafts open with their own hard gate (`SHOW-HN-DRAFT.md:9`): *"**Hard gate: if a single `[RECEIPT:]` marker is still in the text, the post does not go out.**"* and state plainly at line 6 that the founding cohort *"has not run. There are no cohort numbers, so none are written here."* That is the opposite of AI slop — it is a document refusing to invent its own evidence.

The real problem is operational, not reputational: **the drafted post is unpostable today.** Every headline variant is parameterised on a two-week cohort that has not started.

**Response: DEFENSIBLE** as a document (`launch-docs/SHOW-HN-DRAFT.md:4-9` is the rebuttal, verbatim), **but plan around it.** Either run the cohort, or write the launch post the project can actually support right now — the isolation oracle at 23/23, the 29-bug bring-up ladder with a commit per bug, the 0.50 median reuse at `ae88a55`, and the falsifiability discipline. That post is available today and needs no cohort.

---

## 9. The published tag and `main` have diverged, with 236 unpushed commits behind it

> *"236 commits ahead of what they're telling people to install."*

**Truth.** Verified:

<!-- HEIMDALL:PIN:FROZEN:BEGIN — a transcript of commands actually run on the audit date. Moving the tag here would attach a real, checkable sha to a `git show` nobody ran. -->
```
git log --oneline origin/main..HEAD | wc -l   → 236
git show v2.3.8:install.sh | shasum -a 256    → 28bbdcd…d84580   (README + site + npm agree)
git show HEAD:install.sh   | shasum -a 256    → b3ec4ba…c387c
```
<!-- HEIMDALL:PIN:END -->

Right now this is **correct behaviour**, not a bug: the README pins the *tag*, the tag's bytes hash to the advertised digest, and the published one-liner verifies. `test/version-drift.test.sh` exists precisely because this went wrong three times before, and it currently holds.

The exposure is forward-looking. The digest is duplicated across `README.md` (×2), `heimdall-site/llms-full.txt:43`, `heimdall-site/netlify.toml:25`, and `packages/runheimdall/package.json`, plus the tag string in `heimdall-site/index.html:405` and `robots`/`sitemap`-adjacent copy. Cutting v2.3.9 means updating six places in two repos, and history says that is where it breaks.

**Response: DEFENSIBLE today** — evidence: fetch `https://raw.githubusercontent.com/randomittin/heimdall/v2.3.8/install.sh`, `shasum -a 256`, compare to `README.md:71`. It matches. **But do not launch mid-release.** Cut the tag, verify all six sites, then post. Do not push 236 commits and re-tag while a thread is live. <!-- HEIMDALL:PIN:FROZEN — cites the tag that was actually fetched and compared; the verdict is scoped to it -->

---

## 10. The pre-push gate fails open when its runner is missing, from a baked absolute path

> *"Their generated pre-push hook ends with `if [ -x "$GATE" ]; then "$GATE" …; fi; exit 0`. If the gate binary isn't there, the hook prints nothing and exits 0. A gate that silently passes when it's absent is not a gate."*

**Truth.** Verified. My first read was wrong and I want to record that: `.git/hooks/` is empty, but `git config core.hooksPath` is `/Users/rj/Downloads/heimdall/.heimdall/hooks`, and a real `pre-push` lives there. It is good work — it chains any pre-existing hook first, and `HMD_SKIP=1` writes a visible unproven-merge receipt rather than silently bypassing.

The failure mode is the tail (`.heimdall/hooks/pre-push:5` for the baked path, `:29-34` for the guard):

```sh
HMD_BIN="/Users/rj/Downloads/heimdall/bin"     # baked absolute path
GATE="$HMD_BIN/heimdall-gate-run"
[ -x "$GATE" ] || GATE="$(command -v heimdall-gate-run 2>/dev/null || true)"
if [ -n "$GATE" ] && [ -x "$GATE" ]; then
  "$GATE" --phase "$HOOK" || exit $?
fi
exit 0
```

Move, rename, or uninstall the plugin directory and every subsequent push is green, silent, and ungated. There is a `PATH` fallback, which helps — but if `hmd` was installed only into the plugin dir, both lookups miss together. `bin/heimdall-gate-run` has the same shape at the top level: its own contract says *"PASS = every applicable gate green (**or none configured**) → exit 0, quiet"*.

**Response: FIX BEFORE LAUNCH** — one branch. If `$GATE` cannot be resolved, print one loud line and `exit 1`. This is the same principle the module invariants already got right (*"an unverifiable invariant is never allowed to read as a pass"* — `modules/headroom/manifest.json`, `no-signed-traffic-routing`). Apply it here.

---

## 11. The team-join one-liner puts a bearer secret in the invitee's shell history

> *"Their team invite is a shell command with the team secret inlined as an env var. You paste that into your terminal and it's in `~/.zsh_history` forever, and it was in whatever Slack channel it came from before that."*

**Truth.** Verified. `bin/heimdall-invite:296`:

```
( set -o pipefail; f="$(mktemp …)" && curl -fsSL --proto '=https' <raw-url> -o "$f" \
  && HEIMDALL_CP_URL='<url>' HEIMDALL_TEAM_SECRET='<secret>' bash "$f"; r=$?; rm -f "$f"; exit $r )
```

The **inviter** side is well defended and the header documents each choice: fetch-to-file then run (never `curl | bash`, so a 404 fails loudly), the secret rides only the env of the `bash` invocation and never argv (`ps` safe), it is printed to stdout only and never to a tracked file or log, a `⚠ contains your team secret` caveat prints above it, and the ref is verified against `origin` with a refusal (exit 3) rather than handing over a silent-404 join.

None of that helps the **invitee**. A pasted command lands in shell history by construction, and the secret has already traversed whatever channel carried it. This is inherent to any paste-to-join flow — GitHub, Tailscale and Slack all have the same property — but this one is a long-lived bearer capability, and I found no rotation command in `bin/`.

**Response: CONCEDE, and disclose in SECURITY.md.** Say the shape plainly: *the team secret is a bearer capability, it is used once at enroll to bind an Ed25519 key, and after that presence is signed rather than bearer-authenticated.* Then ship `hmd team rotate` (or name it as roadmap). "Rotate it after onboarding" is only advice if the command exists.

---

## 12. `cp-funnel` 4d is an absence-grep with no existence guard

**Truth.** `test/cp-funnel.test.sh:427`:

```sh
if ! grep -qE 'urllib|http\.client|requests\.|cp_url|CP_URL' "$LIB/funnel.py" 2>/dev/null; then ok "4d …"
```

Delete `bin/lib/funnel.py` and 4d goes **green** — `grep` on a missing file returns 1, `!` inverts it. I proved the shell semantics directly. The project knows this antipattern: the sibling assertion at `test/cp-funnel-walk.test.sh:331-334` guards against it *by name* — *"The file MUST exist -- a missing file makes `! grep` succeed, which would turn a deleted badge into a silent PASS."*

**Response: DEFENSIBLE, fix opportunistically.** The deletion case is covered 45 lines earlier: `funnel.py` is in `FUNNEL_SURFACE` (line 385) and `SURFACE_MISSING` turns 4b **red** on a missing file. So the *suite* cannot be fooled; only 4d in isolation can. Add `[ -f "$LIB/funnel.py" ] || bad` for symmetry with 6a and close it.

---

## 13. `docs/analysis/` is gitignored

**Truth.** `.gitignore:35`. This document required `git add -f`. Worth a decision: if analysis docs are meant to be part of the public receipt trail, un-ignore the directory; if they are scratch, that is fine but the launch post should not link into it.

**Response: INFO.**

---

# Things that survive the attack — use these

These held up under deliberate attempts to break them. They are launch assets.

| Claim | Evidence |
|---|---|
| The published one-liner verifies end to end | `curl -fsSL https://raw.githubusercontent.com/randomittin/heimdall/v2.3.8/install.sh -o f && shasum -a 256 f` → `28bbdcd333ad36380c6ac1f133b654dc2c719d6773710c224ef7c57c44d84580`, matching `README.md:71` <!-- HEIMDALL:PIN:FROZEN — the tag and the digest are one receipt; rendering either alone would publish a pairing that was never verified --> |
| No stale digests anywhere | `168646ba` / `fafe31e` appear **only** in `test/version-drift.test.sh`, as the documented regression they now gate |
| Clean secret history | `gitleaks detect` over 1171 commits: no leaks with the project config, with default rules, and with `--gitleaks-ignore-path /dev/null` |
| The `$HOME`-cannot-isolate incident is fixed properly | `bin/lib/real-home.sh` reads the passwd DB via `getpwuid`, not an env opt-out, because *"one forgot, and that is precisely how the incident happened"*. Fail-safe: every "don't know" answers NO. This is the best file in the repo — **put it in the launch post.** |
| Headroom's manifest discloses its own dead half | `modules/headroom/manifest.json` volunteers that the storage-codec backend **cannot engage** from the documented install, with the measurement, in the same field that declares the class |
| `0.50 median reuse across 8 cold repos` traces | `launch-docs/SUBMISSIONS.md:361` — full sorted table at commit `ae88a55`, recomputed median exactly 0.50, raw run JSONs committed |
| The isolation oracle is real | 23 mutants, every one a distinct breach shape (forged IAP, wire-supplied `team_id`, session-honors-body-team, skipped sig verify, public-surface dispatch). `23/23`, exit 0. |
| Test exit plumbing is sound | swept all 283 `test/*.sh` for failures that cannot reach the exit code — found none |
| Consent disclosure text is genuinely good | the printed `consent_text` names the process, the wire position, the reversal command, and the licence, in plain English |

---

# Must fix before launch — the short list

**Seven.** In order.

1. **`6 / 6` → `23 / 23`** in `heimdall-site/proof.html` (×3, incl. `<meta description>`), `index.html:245`, `team.html:88`. Then gate site numbers against live `bin/falsify` output. *(#1)*
2. **Put the digest-checked one-liner on the homepage** — `heimdall-site/index.html:405`. The digest is already in `llms-full.txt:43` and `netlify.toml:25`. *(#4)*
3. **Fix the corpus count regex** — `bin/heimdall-gate-run:101`. `3/13` is currently written into every shareable receipt. *(#5)*
4. **Stop printing `digest-verify` where no digest is verified**, and delete the false *"re-checked by `verify`"* from `bin/heimdall-modules:993`. *(#3)*
5. **Reconcile the Headroom consent messages** — `bin/heimdall-autoupdate:520` promises a question the add path waives; the "two gates" comment at `:404-406` is wrong for the one module it names. *(#2)*
6. **One Headroom paragraph in `README.md` + `SECURITY.md`.** Lift the manifest's `consent_text`. *(#2)*
7. **Make the pre-push hook fail closed** when `heimdall-gate-run` cannot be resolved — `.heimdall/hooks/pre-push:29-34`, plus `bin/heimdall-init` which generates it. *(#10)*

Everything else on this list can ship as disclosure.

---

# Pre-emptive disclosure — say these yourselves

Each of these is survivable when volunteered and expensive when discovered. Put them in the launch post or the FAQ, in the project's own words.

**On the module install path.** *"`hmd modules add` runs `uv tool install` at a version pin. It is a version pin, not a hash pin — we record the sdist digest in the manifest and we do not currently verify it, because `uv tool install` resolves a different wheel per platform. The receipt says `deferred-upstream` rather than claiming a check that did not run. Hash-pinning the dependency tree is the next step and it is not done yet."*

**On Headroom's consent waiver.** *"Headroom is in our default module set and its consent question is waived. That is a distribution decision we made, and we think it is defensible: nothing installs it for you, the disclosure prints in full at install time, `granted_via` records `manifest-waiver` in the receipt, both class contracts run their invariants with it active, and `hmd modules remove headroom` returns the tree byte-identically. If you disagree, `hmd modules optout headroom`."*

**On Headroom's dead half.** Volunteer this before anyone finds it — it is the strongest honesty signal in the repo. *"We declared Headroom as both a traffic-proxy and a storage-codec. Only the traffic-proxy half can actually engage: `uv tool install` yields an isolated venv our `python3` cannot import, so the codec backend reads `plain` on every machine. We measured it, we wrote it into the manifest, and we left both classes declared because each contributes invariants that guard real code."* Commit `37a8d27`.

**On the spend cap.** *"The per-team daily cap fails open on a store error rather than locking out a paying team. Every fail-open window is logged. The billing budget is the hard backstop."* *(#7)*

**On the cohort.** *"The founding-cohort study has not run. There are no cohort numbers in this post, and the drafts that need them are gated on markers we have not filled."* *(#8)*

**On the team secret.** *"The team-join one-liner carries a bearer secret. It will be in your shell history. It is used once at enroll to bind an Ed25519 key; presence is signed after that."* *(#11)*

**On the shape of the whole thing.** The strongest available framing, and it is true: *this project has shipped its install one-liner broken three times, and the gate that now catches it is `test/version-drift.test.sh`.* Say that. A project that publishes its own regression ladder — the 29-bug bring-up, the inverted proxy invariant that printed `BYPASS-OK` while delivering zero bytes to the control plane, the manifest that overstated its own reach — is a project whose green means something. That is the post. It is more defensible than any number on the site right now, and it is the one story a hostile commenter cannot take away.
