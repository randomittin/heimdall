# Consent-aware installer for hmd — spec

Status: DRAFT for owner review. Read-only research task; no `install.sh` or `bin/*`
changes proposed or made by this document. Repo tip at research time: `654c484`.

---

## 0. Verdict up front (the $99/yr decision)

**Recommendation: stay CLI, do not build a double-clickable installer `.app`, for now.**

The single number that decides this: a `.app` a stranger can double-click needs a
**Developer ID** signature to pass Gatekeeper, which requires enrolling in the **Apple
Developer Program at $99 USD/year** (fetched live, § 5.1), plus notarization plumbing
(a CI step that uploads to Apple's notary service and staples the ticket — no extra
per-notarization fee, but real engineering cost: a hardened-runtime build, a secure
timestamp, a Developer ID cert issued to a legal entity, and a renewal the owner must
remember every year or every already-shipped copy starts failing Gatekeeper again for
new downloads).

That spend buys exactly one thing this design needs and cannot get any other way: a
code identity Gatekeeper will let a stranger's double-click run. It buys nothing on the
TCC side — **Full Disk Access still cannot be requested or set programmatically by
ANY app, Developer-ID-signed or not** (§ 2, unchanged from the constraint already
proven in `bin/heimdall-dream-permission`). So the $99/yr does not solve the hard part
of this problem; it only unlocks a nicer front door onto the same folder-permission
dialog the CLI can already trigger for free.

Measured this session (§ 5.2): the ad-hoc signature `hmd-dream.app` already uses is
**rejected by `spctl --assess`** — identically whether or not the bundle carries a
`com.apple.quarantine` xattr. That signature works today only because `launchd` execs
`ProgramArguments` directly and never consults Gatekeeper (documented in
`bin/heimdall-dream-bundle`'s own header, confirmed independently by this measurement).
The instant a human double-clicks instead of `launchd` exec'ing, that same signature
is turned away. **This is now CONFIRMED end-to-end by GUI, not inferred.** The
disposable `test.app` built for § 5.2 escaped the scratchpad and was double-clicked by
the repo owner on macOS **26.5.2**. The dialog:

> **"test" Not Opened** — Apple could not verify "test" is free of malware that may harm
> your Mac or compromise your privacy.  [ **Move to Trash** ]  [ **Done** ]

Two details make this WORSE than the assessment predicted, and they matter for the
verdict:

1. **There is no "Open Anyway" button, and no Control-click→Open escape in the dialog
   itself.** The only two actions offered are *Move to Trash* and *Done*. The historic
   right-click→Open workaround that made ad-hoc distribution merely annoying is not
   present here. A user who wants to proceed must know to visit System Settings →
   Privacy & Security and approve it there — an step the dialog never mentions.
2. **The destructive option is the visually dominant one.** *Move to Trash* is rendered
   as the primary action. The default path for a non-expert stranger is to delete the
   thing they just installed.

macOS also silently relocated the bundle into `AppTranslocation` (a read-only quarantine
sandbox), confirming the launch attempt reached Gatekeeper's full enforcement path and
not merely a signature check.

This converts § 5.2's UNVERIFIED flag into a measurement, and it strengthens the
recommendation rather than weakening it: an ad-hoc-signed `.app` is not "awkward to
distribute", it is effectively **undistributable to strangers**. Which is precisely why
$99/yr buys a real thing on the Gatekeeper side — and still buys nothing on the TCC
side, where the actual 41-day outage lived.

Given that:
- the folder-permission dialog **already fires today, for free, from a CLI-invoked
  binary** (§ 2 — Downloads/Documents/Desktop TCC services list a requesting binary
  the moment it has run once, no `.app`, no notarization, no Apple account required —
  this is the mechanism `heimdall-dream-permission open-settings` already leans on);
- `hmd-dream.app`'s ad-hoc signing already solved the "opaque `/bin/bash` in a TCC
  list" legibility problem, at zero cost, for the one surface (`launchd`) that doesn't
  check Gatekeeper;
- the install-path fix landed today (`2979e5f`) already removes the dead-front-door
  failure this whole investigation started from;

...the remaining gap — a nicer, app-shaped first-run experience with a "why before the
dialog" narrative — is a UX improvement, not a functionality unlock. It does not
justify an annual fee, a renewal-lapse cliff for a security-sensitive artifact, and a
notarization CI pipeline for a CLI tool whose install path is `curl | bash`.

**If the owner's priority changes** — e.g. hmd grows a GUI, or FDA-class access
becomes unavoidable for a feature that genuinely needs it — § 6's hybrid design is
the fallback plan and is scoped small deliberately so it doesn't have to be re-derived
from scratch.

---

## 1. What already exists (read, not re-invented)

This spec extends four files already in the tree; it does not replace them.

- `bin/heimdall-dream-bundle` — builds `hmd-dream.app`, an ad-hoc-signed, byte-identical
  (across rebuilds) private copy of `bash` under `dev.runheimdall.hmd-dream`, so a TCC
  row shows a legible name instead of a raw path. Read in full this session.
- `bin/heimdall-dream-permission` (1096 lines, read in full) — detects whether the repo
  sits under a TCC-protected root, asks the operator ONCE via a printed decision block
  when a human is present (`[ -t 0 ]` on both stdin and stdout), names the exact narrow
  folder service instead of Full Disk Access, opens the correct System Settings pane via
  `open-settings`, and — critically — **disarms only on a scheduled `launchd` run that
  recorded `repo_reachable=yes`**, never on self-report. Its own commit history
  (`8d729ea fix(dream-permission): ask for the folder TCC service, not Full Disk
  Access`) is the fix for the exact regression this spec is told never to repeat.
- `bin/lib/tcc-paths.sh` — the single shared predicate
  (`heimdall_tcc_protected_root`, `heimdall_tcc_folder_service`) mapping
  `~/Downloads` / `~/Documents` / `~/Desktop` to their own TCC service id, System
  Settings pane anchor, and human-visible row label. **This is already the "folder
  service insight generalised"** the task asked for — it already covers all three
  gated folders, not just Downloads. Nothing here needs to be re-derived.
- `install.sh` `ensure_dream_permission()` (line 803) — wires the ask into `curl | bash`
  installs and updates, always exits 0, gated on `HEIMDALL_NO_DREAM_SCHEDULE` and
  Darwin-only.

The gap this spec addresses is **sequencing and narrative quality**, not detection or
scoping — both of those are already correct and already narrow.

---

## 2. Capability matrix — what the installer can/can't do

This table is the artifact the task called "the thing nobody in this repo has ever
written down." Every row is either cited (Apple doc / man page, linked) or measured on
this machine (command + result shown).

| Consent | Category | Evidence | Mechanism today |
|---|---|---|---|
| Downloads Folder access (`kTCCServiceSystemPolicyDownloadsFolder`) | **Prompt-triggerable** | Measured, `bin/heimdall-dream-permission` header + `bin/lib/tcc-paths.sh` header: a binary that has attempted a read under `~/Downloads` is auto-listed in the Files & Folders pane's Downloads Folder row — no `+`, no `Cmd+Shift+G`. Confirmed against a live `TCC.db` per the file's own commit history (`8d729ea`). | `heimdall-dream-permission open-settings --repo <dir>` opens the pane; the human flips one switch. |
| Documents Folder access | **Prompt-triggerable** | Same mechanism, distinct TCC service id (`kTCCServiceSystemPolicyDocumentsFolder`), same file, same measured claim. | Same tool, `--repo` pointed at a `~/Documents`-rooted checkout. |
| Desktop Folder access | **Prompt-triggerable** | Same mechanism, `kTCCServiceSystemPolicyDesktopFolder`. | Same tool. |
| Full Disk Access (`kTCCServiceSystemPolicyAllFiles`) | **Manual System Settings visit only — NOT prompt-triggerable** | Measured (repo history, `cde9fb6`/`8d729ea`): a probe `LaunchAgent` was refused with **no dialog shown at all**. Apple exposes no API to request or set it. | `heimdall-dream-permission open-settings --full-disk-access` opens the pane; the human must click `+`, `Cmd+Shift+G`, paste the exact binary path, and flip it on by hand. Demoted to explicit last resort in the tool's own `[C]` option. |
| Gatekeeper launch approval for an ad-hoc-signed `.app` | **Manual System Settings visit only (if even that)** | Measured this session (§ 5.2): `spctl --assess --type execute` rejects an ad-hoc-signed bundle both with and without a `com.apple.quarantine` xattr (`rc=3`, "rejected", identical in both cases). The classic `Control-click → Open` bypass is documented by Apple for **unnotarized but Developer-ID-signed** software; whether it still applies to a bare **ad-hoc** signature on this OS build was **not** verified end-to-end (no GUI click available in this session) — flagged UNVERIFIED, not assumed. | None today — `hmd-dream.app` is never double-clicked, only `exec`'d by `launchd`, which is documented (`heimdall-dream-bundle` header) to never consult Gatekeeper at all. |
| Gatekeeper launch approval for a Developer-ID-signed, notarized `.app` | **Auto-grantable, once paid for** | Cited, Apple Developer docs (§ 5.1): a notarized, Developer-ID-signed app gets a Gatekeeper dialog that identifies the *verified* developer rather than blocking outright. Requires the $99/yr membership + hardened runtime + secure timestamp (all cited, § 5.1). | N/A — nothing in this repo does this today. |
| launchd exec permission for any code identity | **Auto-grantable — no consent needed at all** | Cited/documented in `heimdall-dream-bundle`'s own header: `launchd` execs `ProgramArguments` directly, bypassing Gatekeeper entirely, for ANY valid Mach-O the kernel will run (ad-hoc-signed included, confirmed by the existing `hmd-dream.app` working today). | Already in production. |
| Setting `hmd` as a default handler / requesting Automation (AppleEvents) access to another app | **Prompt-triggerable, but out of scope** | Not exercised by hmd today; included only because the task asked to study Arc, which uses exactly this category (§ 4). Public write-ups (Candid Technology, § 5.3) confirm Arc's browser-data import is a first-run, in-app-menu action, not a forced first-launch step — consistent with "ask in context," not upfront. | N/A |

**The regression this table exists to make impossible**: any future code path that
asks for Full Disk Access when a folder grant would cover it. `bin/lib/tcc-paths.sh`
already structurally prevents this by only ever returning a folder-specific service for
a recognized root and forcing callers to explicit-opt into the FDA pane via a separate,
named flag (`--full-disk-access`) rather than a default fallback. Any future installer
work MUST reuse this file's predicates rather than re-deriving the Downloads/Documents/
Desktop mapping, on pain of re-introducing the exact 41-day bug this task starts from.

---

## 3. The folder-service insight, generalised (already done, confirmed)

The task asked to "detect which protected root the repo lives under… and ask only for
that." Read in full: `bin/lib/tcc-paths.sh` already does exactly this, generically,
for all three gated folders, with no hardcoded "Downloads" assumption anywhere in the
predicate (`heimdall_tcc_folder_service` switches on `basename "$root"` over
`Downloads|Documents|Desktop`, returning empty + `rc 1` for anything else so callers
fall back to naming Full Disk Access as a last resort rather than guessing a label that
might be wrong). **No design work remains here.** The only outstanding item is
extending the *caller* (an installer, not this predicate) to run this check automatically
at first launch instead of only within `heimdall-dream-permission`'s repo-specific ask —
covered in § 6 as the one concretely scoped follow-on if the owner wants it.

---

## 4. Arc, and what its pattern actually teaches (research findings)

Direct textual capture of Arc's exact click-by-click TCC sequencing was not obtainable
in this session: `resources.arc.net`'s own help articles sit behind a Cloudflare
JS challenge (`Just a moment… Enable JavaScript`, confirmed by fetch,
`/tmp/arc-import.html`), and general web search returned marketing/how-to pages rather
than a step-by-step permission narrative. Arc.app itself is not installed on this
machine, so its `Info.plist` usage-description strings (which would have been the best
available *measured* evidence of what it asks and how it frames the ask) were not
inspectable either. The following is therefore **cited from secondary, public
sources**, not measured — marked accordingly.

What is reliably documented (Candid Technology, "How to transfer Chrome bookmarks and
passwords to Arc browser," fetched):
- Arc's data import (bookmarks, logins, history) is triggered from an **in-app menu
  item** ("Import from Another Browser") chosen by the user, not forced during a
  blocking first-launch wizard. The user picks the source browser and profile, then
  confirms, and only then does the underlying data read happen.

This is consistent with — and is the one concrete, transferable lesson worth adopting
regardless of the `.app`-vs-CLI verdict — **Apple's own published guidance to ask for
permission at the moment of use, not at launch**, a principle already implicit in
`heimdall-dream-permission`'s own design (it only arms when a `launchd` schedule is
about to exist, never speculatively at every `hmd` invocation). The generalizable
takeaway, applicable to a CLI exactly as well as an app:

1. **Never ask before the feature that needs the grant is about to run.** hmd already
   does this correctly (the ask is gated on scheduling `/dream`, not on installing hmd
   generically).
2. **State the "why" in the same breath as the ask, before triggering any OS dialog.**
   `heimdall-dream-permission`'s printed block already does this (`WHAT IS BROKEN` /
   `WHY` sections precede the numbered steps) — this is the one piece of Arc's pattern
   this repo had already independently converged on.
3. **Verify the grant landed from independent evidence, not self-report** — this is
   `heimdall-dream-permission`'s `repo_reachable` check, already stronger than what the
   secondary sources describe for Arc (which relies on the import succeeding or failing
   in the moment, a UI-synchronous check rather than a next-day scheduled-job proof).

No part of Arc's researched behavior suggests a capability this repo lacks. The
value of the research is confirmation, not a gap.

---

## 5. Evidence log (cited + measured)

### 5.1 Apple Developer Program cost and notarization requirements (cited)

- Fetched `https://developer.apple.com/support/compare-memberships/`: **"Enrollment is
  99 USD (or in local currency where available) per membership year."** This is the
  cost gating a Developer ID certificate, which is in turn required for notarization.
- Fetched `https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution`
  (markdown mirror, since the JS-rendered page requires a browser runtime not available
  here): notarization requires (a) a valid code signature, (b) a **"Developer ID"**
  application certificate — explicitly, "Don't use a Mac Distribution, ad hoc, Apple
  Developer, or local development certificate" — (c) the Hardened Runtime capability,
  (d) a secure timestamp on the signature, (e) no `com.apple.security.get-task-allow`
  entitlement. Also: **"Beginning in macOS 10.15, all software built after June 1,
  2019, and distributed with Developer ID must be notarized."** There is no separate
  per-submission notarization fee beyond the membership; the cost is the membership
  itself plus the CI/build engineering to satisfy the above list.
- The same document states notarization tickets carry an audit trail tied to the
  signing key and can be individually revoked by Apple on request — it does **not**
  state what happens to already-issued tickets if the *membership itself* lapses
  (non-renewal vs. active revocation are different events). **Flagged UNVERIFIED**: this
  spec does not assert that a lapsed $99/yr renewal invalidates already-notarized,
  already-installed copies; the "secure timestamp" requirement exists specifically so a
  signature's validity is evaluated as of signing time, which is suggestive that
  previously notarized copies keep working, but this was not confirmed against an
  authoritative source and must not be treated as established.

### 5.2 Ad-hoc signature vs. Gatekeeper — measured this session

```
$ codesign --force -s - --identifier dev.runheimdall.test-consent test.app
test.app: replacing existing signature

$ spctl --assess --type execute -v test.app
test.app: rejected
rc=3

$ xattr -w com.apple.quarantine "0081;<ts>;Safari;" test.app
$ spctl --assess --type execute -v test.app
test.app: rejected
rc=3
```

Built and signed identically to `bin/heimdall-dream-bundle`'s own method
(`codesign --force -s - --identifier <id> <bundle>`), using a disposable copy of
`/bin/bash` in the session scratchpad — no repo file touched. Result: **Gatekeeper's
own assessment subsystem rejects an ad-hoc signature outright, and adding a quarantine
flag (simulating a browser/curl download) changes nothing** — it was already rejected
before quarantine was added. `man spctl` describes `--assess` as evaluating "whether the
system allows the installation, execution, and other operations on files" — i.e., this
is Gatekeeper's own launch-time verdict, not an approximation of it.

This confirms the distinction the task asked to verify: `launchd` bypassing Gatekeeper
entirely (already documented, `heimdall-dream-bundle` header) is a **different code
path** from what a human's double-click goes through, and the ad-hoc signature that
works for the former does not clear the latter's bar. What was **not** measured: the
exact dialog text and whether `Control-click → Open` or the System Settings
"Open Anyway" affordance can still push an ad-hoc-signed, `rejected`-per-`spctl` app
through on this specific macOS build (26.5.2) — no GUI interaction is available in this
session. Treat this as an open risk for any future `.app`-based design, not a solved
problem.

### 5.3 Machine facts

```
$ sw_vers
ProductName:    macOS
ProductVersion: 26.5.2
BuildVersion:   25F84

$ spctl --status
assessments enabled
```

Gatekeeper assessments are enabled on this machine (the default, and the state a
stranger's fresh Mac will also be in) — so § 5.2's rejection is the live, enforced
policy, not a theoretical one.

### 5.4 Prior, already-committed measurements this spec relies on (not re-verified this session, cited by commit)

- `kTCCServiceSystemPolicyDownloadsFolder` grant lives in the **user** TCC database;
  no heimdall row ever existed under `kTCCServiceSystemPolicyAllFiles` — stated in
  `bin/heimdall-dream-permission`'s own header, landed in `8d729ea`.
- A probe `LaunchAgent` requesting Full Disk Access was refused **with no dialog
  shown** — stated in the same file's header, landed in `cde9fb6`.
- Two independent builds of `hmd-dream.app` in different directories, and a third with
  a forced different mtime, produced a **byte-identical CDHash** — stated in
  `bin/heimdall-dream-bundle`'s header.
- `spctl` rejects `hmd-dream.app`'s ad-hoc signature ("Insufficient Context") —
  stated in the same file's header; this session's § 5.2 measurement is an independent
  reproduction of the same underlying fact with a disposable test artifact, adding the
  quarantine-flag comparison that file did not test.

These are cited rather than re-measured in this session to avoid re-litigating settled,
already-committed findings; where this spec draws a NEW conclusion from them (the
quarantine-does-not-matter finding, § 5.2), that part was independently reproduced.

---

## 6. Fallback design (only if the verdict in § 0 is later overridden)

If the owner decides the $99/yr and notarization pipeline are worth it later — e.g. hmd
grows features that need a real GUI presence — the right shape is a **hybrid**, not a
full installer rewrite:

- `curl | bash` stays the entry point, unchanged. It remains the fast, zero-cost,
  zero-consent-surface path for anyone who doesn't need the app.
- A **small, separate, notarized helper app** (`hmd-consent.app`, distinct identifier
  from `hmd-dream.app` — do not conflate the two identities, since one execs under
  `launchd` and never needs Gatekeeper clearance while the other must clear it) is
  built and published as a signed release asset, downloaded and double-clicked
  **only** on the narrow path where a folder grant is needed (Downloads/Documents/
  Desktop) and the operator is at a terminal. `install.sh` would print a link to it
  instead of (or in addition to) `heimdall-dream-permission open-settings`.
- Its ENTIRE job is: explain the one folder grant in plain language before it triggers
  anything, deep-link the correct System Settings pane (`bin/lib/tcc-paths.sh`'s
  existing anchor mapping, reused verbatim — do not re-derive), and verify via the same
  `repo_reachable`-style evidence check `heimdall-dream-permission` already uses. It
  must **never** attempt Full Disk Access, `tccutil`, or any TCC database write — same
  hard constraint as this whole spec.
- Building this is a genuinely separate planning cycle (CI signing pipeline, a
  Developer ID cert the owner alone can create since they hold the credentials, a
  renewal calendar reminder) and is explicitly **not** decomposed further here per the
  "no code without an approved design" gate — this spec stops at "here is the shape,"
  not "here is the task graph," until the owner picks this path.

---

## OUT OF SCOPE

- Any change to `install.sh`, `bin/heimdall-dream-*`, or `bin/lib/tcc-paths.sh` — this
  document is research only; no code in this cycle.
- Building, signing, or submitting any artifact for notarization — no credentials for
  this exist in this environment, and the owner alone holds them.
- Deciding whether hmd should ever grow a GUI for reasons unrelated to consent
  (feature parity, branding, etc.) — out of scope of the consent problem this spec
  answers.
- Full Disk Access automation of any kind, including `tccutil` invocation or TCC
  database writes — hard-excluded per task constraints, not merely deprioritized.
- Verifying the exact Gatekeeper dialog text / "Open Anyway" recovery flow via live GUI
  interaction — flagged as an open risk (§ 5.2), not resolved here; would need a
  session with real display/mouse control.
- Windows/Linux installer consent flows — this entire investigation is macOS TCC/
  Gatekeeper-specific by construction (the underlying bug only exists on macOS).

## Risks & Mitigations

| Risk | Probability | Impact | Mitigation | Owner-task |
|---|---|---|---|---|
| A future contributor re-adds a Full Disk Access default because it "just works more broadly" | med | high (repeats the 41-day bug) | § 2's capability matrix + `bin/lib/tcc-paths.sh`'s existing explicit-opt-in design (`--full-disk-access` must be passed by name) are the structural blockers; any PR broadening the default should be rejected at review | any future dream/installer PR review |
| Ad-hoc-signed `.app` is built and shipped for double-click before its Gatekeeper behavior is GUI-verified | low (this spec recommends against building one at all) | high (ships a broken first-run experience, § 5.2's open risk) | § 0's verdict explicitly recommends against a double-clickable `.app` for now; if § 6 is later pursued, GUI-verify the exact Gatekeeper flow before shipping, not after | whoever picks up § 6 |
| Apple Developer Program renewal lapses silently, and the cliff for already-shipped notarized copies is worse than assumed | low (only relevant if § 6 is pursued) | med | § 5.1 flags this explicitly as UNVERIFIED; before committing to § 6, get an authoritative answer (Apple Developer forums / a direct test with a real, disposable-scope cert) rather than relying on the "secure timestamp" inference | whoever picks up § 6 |
| Arc-specific claims in § 4 are treated as more authoritative than they are (secondary sources, JS-walled primary docs) | low | low (the section's conclusion is "confirms existing design," not "requires a change") | § 4 explicitly marks its sourcing tier and states no gap was found | n/a — informational section only |

## Citations

- Apple Developer: Compare Memberships — `https://developer.apple.com/support/compare-memberships/` (fetched this session; $99/yr figure)
- Apple Developer: Notarizing macOS software before distribution — `https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution` (fetched via `.md` mirror this session; Developer ID / hardened runtime / secure timestamp / post-2019-06-01 requirement)
- `man spctl` (this machine) — `--assess` semantics
- Candid Technology, "How to transfer Chrome bookmarks and passwords to Arc browser" — `https://candid.technology/transfer-chrome-bookmarks-passwords-to-arc-browser/` (fetched this session; Arc's import-is-in-app-menu, not forced-at-launch, behavior)
- `bin/heimdall-dream-bundle`, `bin/heimdall-dream-permission`, `bin/lib/tcc-paths.sh`, `install.sh` (this repo, read in full this session)
- This session's own `spctl`/`codesign`/`xattr` measurements (§ 5.2, § 5.3), reproduced against a disposable scratchpad artifact, no repo files touched
