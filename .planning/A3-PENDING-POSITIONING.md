# A3 — RESOLVED: package.json `description` / `keywords` §3 positioning

> **DECIDED: candidate A, committed 0185059** — `packages/runheimdall/package.json` `.description`
> now ends with the canonical tagline "Nothing ships unproven." and carries the 12-term keyword
> list. `release/ship.sh` `npm_positioning_notice()` keys on that tagline: with §3 decided the
> PENDING warning is now SILENT, and it only re-fires if a future package.json drops the tagline
> (a genuinely-undecided state). The candidates and history below are retained for the record.

## Why this file exists

Task A3 asked for two fields sourced from `heimdall-seo-geo-spec.md` §3 and
`heimdall-fix-document.md`:

- a "new positioning line" → `packages/runheimdall/package.json` `.description`
- a "fix-doc topics list" → `packages/runheimdall/package.json` `.keywords`

**Neither source document exists in this repo** (verified: `find . -iname
"heimdall-seo-geo-spec.md" -o -iname "heimdall-fix-document.md"` returns nothing). I did not
invent a §3 line and pass it off as canonical. `.description` and `.keywords` in
`packages/runheimdall/package.json` are **unchanged** — still the pre-existing values. Everything
else in scope (README drift-proofing, npm link, homepage/repository verification) is done; see
the A3 branch report for that work.

This mirrors agent A6's finding on `launch-docs/SUBMISSIONS.md` (`{{POSITIONING_LINE}}`
placeholder, branch `a6-submissions`) — same missing source, same conclusion. **The candidates
below reuse A6's exact lettering (A/B/C)** so RJ's single pick of a positioning line fills both
the npm `description` and every `{{POSITIONING_LINE}}` slot in `launch-docs/SUBMISSIONS.md` in
one decision.

## Candidate `description` lines

Current value (unchanged, functional — describes what the wrapper *does*, not what Heimdall
*is*):

> "Thin npx wrapper for the Heimdall installer — fetches the pinned-tag install.sh, verifies its sha256, and runs it. Byte-identical to runheimdall.dev/install."

Each candidate below = that functional sentence + one positioning line appended, so the
wrapper's own behavior stays documented and the product positioning rides alongside it. Pick
the letter — same letter fills `launch-docs/SUBMISSIONS.md`'s `{{POSITIONING_LINE}}`.

| # | Candidate `description` | Source of the appended line |
|---|---|---|
| A | "Thin npx wrapper for the Heimdall installer — fetches the pinned-tag install.sh, verifies its sha256, and runs it. Byte-identical to runheimdall.dev/install. Nothing ships unproven." | `IDENTITY.md:18` `tagline:` field (canonical) |
| B | "Thin npx wrapper for the Heimdall installer — fetches the pinned-tag install.sh, verifies its sha256, and runs it. Byte-identical to runheimdall.dev/install. Heimdall is a cloud bot that fixes your GitHub issues and opens a proven PR — you review, you merge." | `README.md:3` (bolded opening line) |
| C | "Thin npx wrapper for the Heimdall installer — fetches the pinned-tag install.sh, verifies its sha256, and runs it. Byte-identical to runheimdall.dev/install. Verification gates for AI-written code: every plan wires an external, falsifiable oracle so the merge stays blocked until the work is proven correct." | Paraphrase of `README.md:37`, per A6's Candidate C |

npm truncates package descriptions in search results at roughly 100–120 characters, so A is the
safest for search-result legibility; B and C read better on the full npmjs.com package page
where the whole string renders.

**Not recommended without a decision: leaving `.description` as-is forever** — it never mentions
Heimdall's actual differentiator (falsifiable verification, not just "an installer"), which is a
missed positioning opportunity on a page anyone lands on from `npm search runheimdall` /
`npm view runheimdall`.

## Candidate `keywords`

Current value (unchanged): `["heimdall", "installer", "verification", "claude-code"]`

Candidate (derived from repo truth — README headings/bullets, `IDENTITY.md`, and the wrapper's
own function — nothing invented):

```json
[
  "heimdall",
  "claude-code",
  "claude",
  "ai-agent",
  "code-review",
  "verification",
  "falsifiable",
  "installer",
  "cli",
  "npx",
  "sha256",
  "self-hostable"
]
```

Sourcing per term: `claude-code`/`claude`/`ai-agent`/`code-review` — README.md:1-5 ("Claude Code
plugin", "fixes your GitHub issues and opens a proven PR"); `verification`/`falsifiable` —
README.md:30,37 (falsifiable oracle, mutant tests); `installer`/`cli`/`npx`/`sha256` — this
package's own function (thin npx wrapper, sha256-verified install); `self-hostable` —
`LICENSE` (MIT) + `OPERATORS.md` (self-deployment documented). `heimdall` kept as-is
(package identity).

npm allows keyword search matches on any array entry; this list trades the current 4 generic
terms for a mix of product-identity and function terms so `npm search` surfaces the package for
both "claude code verification" style queries and "npx installer" style queries.

## What to do

Pick a positioning letter (A/B/C) and confirm/edit the keywords list, then either:

- hand-edit `packages/runheimdall/package.json` `.description` / `.keywords` directly (these two
  fields are NOT rendered by `bin/heimdall-render-version` or `release/sync-release.sh` — they
  are plain authorial content, not version-derived, so hand-editing them is correct, unlike
  version/tag/sha fields on this same file), or
- ask an agent to apply the chosen candidate verbatim.

Either way, re-run `bash test/version-drift.test.sh` afterward (it does not check these two
fields, but confirms the edit didn't accidentally touch the version-bearing fields on the same
file) and `jq . packages/runheimdall/package.json` to confirm the JSON stays valid.

## Ordering caveat — decide this BEFORE the next npm publish

`release/ship.sh` now publishes `packages/runheimdall` to npm as a stage of the ship (branch
`a3-npm-ship`), because publishing used to be a human step outside the script and the human
forgot: `npm view runheimdall version` reported **2.0.5** while the repo shipped **2.2.6**.

That makes this pending decision time-sensitive, and the ordering is the whole point:

- **`.description` and `.keywords` are what npmjs.com renders** as the package page's subtitle
  and its `npm search` result. They are the first words anyone reads about Heimdall on npm.
- **npm versions are immutable.** `npm unpublish` is blocked after 72 hours and a version
  number can never be reused. There is no "edit the description later" — the published tarball
  carries the metadata it was published with.
- Therefore **publishing before this decision lands means publishing twice**: once with the
  pre-launch text, and again (burning a whole version number) to correct the words.

`release/ship.sh` states this at the npm stage rather than deciding it — `npm_positioning_notice()`
prints a loud warning naming this file on every `npm publish` path (`--dry-run`, `--npm-only`,
and a full ship). It is a **notice, not a block**: it does not gate the publish, because whether
the words are final is RJ's call, not a script's. Confirm it by running:

```bash
release/ship.sh --npm-only --dry-run     # publishes nothing; prints the notice + the exact command
```

**Recommended order:** pick the letter → apply `.description`/`.keywords` → commit → then run
the npm reconcile (`release/ship.sh --npm-only`) so npm's very first correct-version publish
also carries the correct words. If the reconcile has to happen first for other reasons, that is
a deliberate choice to publish the positioning text twice — make it knowingly.
