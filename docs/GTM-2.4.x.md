<!-- HEIMDALL:PIN:FROZEN:BEGIN — a point-in-time plan; the versions it names are deliberately not rendered -->
# GTM plan: hmd 2.4.8 and the runhmd phone app

> **DRAFT. NOT APPROVED.** Nothing here is posted, published, submitted or sent until the operator approves this plan. Every post, store entry and release command below is an operator act or waits for one. **OPEN** marks a fact the repo cannot answer.
> Drafted 2026-10-14 on `release/2.4.8` (7ee401fb). Read: CHANGELOG.md, README.md, DATA.md, relay/, bin/heimdall-app, release/, and, read-only, the app repo `hmdapp` and the site repo `heimdall-site`. Revised 2026-10-14 with the operator's decisions; still a draft.

## Who, what, headline

- **For:** Claude Code users running long sessions.
- **Headline (operator decision, 2026-10-14):** answer and steer your Claude Code session from your phone (runhmd for iOS and Android). Message contents are end-to-end encrypted; the relay sees only metadata (session ID, sizes, timing, IP); push notification text isn't encrypted; --confirm adds a 6-digit check.
- **In the launch:** hmd 2.4.8, and the runhmd app moving from internal testers to a public TestFlight link and a Play open test.

| Item | State today | Source |
|---|---|---|
| hmd 2.4.8 | Prepared, not shipped: `VERSION` and plugin.json read 2.4.7 and there is no v2.4.8 tag here. `release/ship.sh` does the bump, tag, Release and npm. 2.4.7 reached npm on 2026-10-15. | CHANGELOG [2.4.8] |
| 2.4.8 for the phone | A stopped or crashed laptop client no longer unpairs it: the login sits in Keychain or a 0600 file and resumes for 24 h, for every paired phone. Only `hmd app disconnect`, `--device` or a phone revoke unpairs. No relay deploy. | CHANGELOG [2.4.8] |
| runhmd app 1.2.0 | iOS build 14 on TestFlight internal, Android versionCode 20 on Play internal (2026-10-13). No public TestFlight link or Play open-test track is recorded: OPEN. | hmdapp app.json, 4cae519e |

| Claim | Evidence | Say it with this caveat |
|---|---|---|
| Answer and steer a live session | The phone sends a message, answers the agent's question, stops a turn, saves a checkpoint and denies (DATA.md sections 8-9). | Do not say "run": the app source has no start-a-session action (its only "launch" is app launch) and hmd's `remote-launch` is off by default. Deny only, never approve. |
| Message contents are end-to-end encrypted | X25519, HKDF-SHA256, ChaCha20-Poly1305: `bin/lib/hmd_relay_e2e.py`, app `src/relay/crypto.ts`, DATA.md section 9. | No outside audit is recorded in the repo: never write "audited". |
| The relay sees only metadata | It stores and forwards ciphertext and holds no session key (relay/README.md:33-37). It sees session id, sequence numbers, sizes, timing, IP and the phone's public key, and keeps the newest sealed state frame. | The relay sees only metadata (session ID, sizes, timing, IP). Default pair-by-code trusts the relay to deliver the right keys (a relay that swapped its key could read the session); `hmd app connect --confirm` adds a 6-digit check (DATA.md:650-653). Self-host with `--relay URL`. Decided 2026-10-14: `--confirm` stays opt-in. |
| Push notification text isn't encrypted | Expo and Apple/Google can read it: title 48, body 120 chars (DATA.md push section). | `HMD_PUSH=0` turns it off. The store listing's "only ever sees encrypted data" is looser than DATA.md: align it. |
| The gh token reaches the relay once per code, never on a timer (pairing is on by default for every repo since 2026-10-20; the old claim, "only after `hmd app connect`", is withdrawn) | Pair-by-code sends `gh auth token`; the relay makes one `GET /user` and, by INV-39, never stores or logs it (a promise about relay code, not checkable from the client). At 5b22234a the pair-window SessionStart hook still sends it on every window registration, about every 350 s, while gh is signed in (bin/heimdall-app:75-77, 144-190; DATA.md:608-645). README:121 says it goes "while the code is offered": update it with the fix. Do not post this claim until the fix lands. | Sent once for each code registered for a phone to claim (a session start of a repo with no phone paired, `hmd app connect`, `hmd app add-device`), only while gh is signed in, with no 5-minute resend. `--no-code` pairs by QR and sends no token. Off for one repo with `hmd app disconnect` or `hmd app connect --no-code`, for the machine with `HMD_PAIR_WINDOW=0` or `hmd hooks disable pair-window-start`. The app also needs a GitHub sign-in, and the relay learns the numeric id and login. |
| Do not say | audited; zero-knowledge; a bare "no data collection" (fails `test/truth-pass-claims.test.sh`); no account needed; public release (both are test tracks); start a session from the phone. | |

## Channels

| Channel | Asset and lead | Owner |
|---|---|---|
| GitHub release notes | `ship.sh` derives them from commits; the prose is editable after (CHANGELOG [2.4.8]). Lead: "Your phone stays paired when the laptop client stops, restarts or Claude Code resumes; re-pair once after upgrading. Second phone: `hmd app add-device`." Publishing the Release is what rolls existing installs forward (auto-update). | hmd drafts, operator edits |
| Site changelog, homepage | Separate repo (release/HOSTING.md); a push deploys it. It has no changelog page (`log.html` is "The Log"): OPEN new page or log.html. Homepage phone section (`index.html:292-311`) is stale: "not in a tagged release", invite-only, diff and attach "not built", "paired by QR"; so is `how-it-works.html:430`. Privacy page still says "No accounts" (`privacy.html:83`, effective 2026-10-05); corrected text: hmdapp `docs/store/privacy-page.md`. Add both store links; site version pins are manual in 2.4.8. Deferred out of 2.4.8: BACKLOG. | hmd drafts, operator pushes |
| npm README | `runheimdall`'s is a byte copy of README.md (`test/npm-readme-drift.test.sh`); `runhmd` has its own. A README ships in the tarball, so land a short Phone section before ship, with scoped claims only. OPEN: NAMING.md:9 says the `runhmd` npm name is not yet claimed. | hmd drafts, operator ships |
| X post, Show HN, demo | Below. House HN rules (docs/specs/heimdall-ship-spec.md L1): no superlatives, Tue/Wed/Thu 7-8pm IST. `launch-docs/SHOW-HN-DRAFT.md` is a different story marked READY TO POST, with no record of posting: OPEN which Show HN goes first. | operator posts and records |

## Draft copy

**X post** (275 chars, one link; the homepage carries the store links):

```text
Answer and steer your Claude Code session from your phone. runhmd (iOS, Android) pairs with hmd on your laptop. Message contents are end-to-end encrypted; the relay sees only metadata. hmd 2.4.8: the phone stays paired when the laptop client restarts. https://runheimdall.dev
```

Reply (223 chars): `Scope: message contents are end-to-end encrypted; the relay sees only metadata (session ID, sizes, timing, IP); push notification text isn't encrypted; --confirm adds a 6-digit check. Details: DATA.md section 9 in the repo.`

**Show HN title** (66 chars): `Show HN: Answer and steer your Claude Code session from your phone`

**Show HN body** (URL field: https://github.com/randomittin/heimdall):

```text
hmd is an MIT-licensed Claude Code plugin; its pre-push gate runs checks the agent did not write. This post is about its phone companion, runhmd (iOS and Android), which lets you answer and steer your Claude Code session from your phone. It pairs with a session running on your laptop (hmd app connect). From the phone you can read the session's status and chat, answer the agent's questions, send it a message, stop a turn and deny a pending action. The phone can deny; it cannot approve.

Laptop and phone talk through a Cloudflare Worker whose source is relay/ in the repo. Message contents are end-to-end encrypted (X25519, HKDF-SHA256, ChaCha20-Poly1305). The relay sees only metadata (session ID, sizes, timing, IP): it stores and forwards ciphertext, and it keeps the newest encrypted state frame so a reconnecting phone can catch up. hmd can use a relay you run (--relay URL).

What that does not cover: push notification text isn't encrypted. It goes through Expo and Apple/Google as short text (HMD_PUSH=0 turns push off). Pairing by code trusts the relay to hand each side the right key (hmd app connect --confirm adds a 6-digit check). Pairing by code sends your gh auth token to the relay once for each code registered for a phone to claim (a session start of a repo with no phone paired, hmd app connect, or hmd app add-device), only while gh is signed in; there is no 5-minute resend, and HMD_PAIR_WINDOW=0, or hmd app disconnect for one repo, turns the session-start code off. The relay's code never stores or logs the token, but the client cannot verify that. --no-code pairs by QR and sends no token. The app asks for a GitHub sign-in, and the relay learns your numeric id and login. The crypto has had no outside audit. [OPEN: operator confirms]

2.4.8: a stopped or crashed laptop client no longer unpairs the phone. Each paired phone resumes for 24 h; only hmd app disconnect or a revoke from the phone unpairs.

The app has an offline demo mode on sample data, so you can look before installing hmd: [TestFlight link: OPEN] [Play link: OPEN]. I will answer questions on the relay design here.
```

## 60-second demo (real devices, store build, not a dev build)

| Time | Shot | What is on screen |
|---|---|---|
| 0:00-0:06 | Long session, away from the desk | Terminal, Claude Code mid-task, statusline showing the 5-character session code; phone beside it |
| 0:06-0:16 | Pair | `hmd app connect` prints SESSION CODE and a QR; phone: runhmd, Pair a session, type the code; "phone paired", and a notice lands in the Claude session (bin/heimdall-app:52-66) |
| 0:16-0:28 | Answer | Chat tab shows the last turns; the agent asks a question; type the answer on the phone; cut to the laptop where Claude takes it as the operator's answer |
| 0:28-0:40 | Deny | Claude tries a risky command (a `git push`); the phone holds a Deny card for up to 10 s (DATA.md section 8); Face ID; denied on the laptop. Caption: "The phone can deny. It can't approve." |
| 0:40-0:50 | What the relay holds | `relay/contract/wire.json` `frames.state.wire` with the ciphertext cut short (`v`, `session_id`, `seq`, `sender`, `type`, `nonce`, `ciphertext`). Caption: "Fixture, not live traffic. The relay forwards this and has no key." |
| 0:50-0:57 | 2.4.8 resume | Ctrl-C the connect client, run `hmd app connect` again; the phone reconnects with no re-pair |
| 0:57-1:00 | End card | runheimdall.dev, store links [OPEN], one line: "Answer and steer your Claude Code session from your phone. Message contents are end-to-end encrypted; push notification text isn't encrypted: DATA.md section 9" |

Dry-run on a clean machine first: hmdapp's TEAM-QUICKSTART section 7 says phone deny needs `HMD_PHONE_DENY=1`; DATA.md section 8 says it is on by default.

## Launch order

| # | Step | Owner | Status |
|---|---|---|---|
| 1 | Freeze `release/2.4.8`, run the ONE full sweep (`bash test/run-all.sh`); `release/ship.sh` refuses to tag without a green FULL receipt at HEAD | hmd | not run by this plan |
| 2 | Decide the trust items: pair-window default, `--confirm` default or claim wording, the word "run" (table above) | operator | Decided 2026-10-14: 2.4.8 token fix (claims table); `--confirm` claim wording; "run" dropped |
| 3 | Encryption forms: `ITSAppUsesNonExemptEncryption` is still false in app.json; `docs/IOS-STORE-COMPLIANCE.md` argues false, `docs/RELEASE-READINESS-2026-10-08.md` F2 and `docs/RELEASING.md` say true (option B); if non-exempt, BIS self-classification due 1 Feb 2027 and France (ANSSI declaration or untick France). Counsel's call | operator | OPEN (operator's side) |
| 4 | Privacy forms: ASC App Privacy labels and Play Data safety (answers drafted in hmdapp `docs/store/`; both held the 1.1.0 push-only answers on 2026-10-08); publish the privacy page | operator | OPEN (operator's side; hmd diffs the page on request) |
| 5 | Sign-in proof: the GitHub App authorizable by a non-owner account (O6) and the browser sign-in round trip on a real iPhone and Android phone (O7), both open on 2026-10-08. Relay origin: app `hmdRelayUrl` and the hmd default (`hmd-relay.therishabh16.workers.dev`) must match, and the code-pairing secrets must be set in prod (else 503) | operator | OPEN |
| 6 | Store screenshots: retake the Android set of 5, confirm the iOS set of 4 (1320 x 2868) against the 1.2.0 UI (F5, A8); listing lead still says "Proof for AI coding agents", not the headline | operator | OPEN (operator's side; hmd drafts text on request) |
| 7 | Store review status: external TestFlight group and Beta App Review for the newest build (build 8 was rejected 2026-10-10; the demo sign-in fix is in build 12 and later; the outcome is not recorded); Play open-test track, listing and declarations (the repo documents internal testing only) | operator | OPEN: unknown (operator's side) |
| 8 | Support or feedback contact, one for listings, README and Show HN: `rj@runheimdall.dev` (privacy page), GitHub issues (`package.json` bugs URL), site root (ASC support URL); `docs/PRIVACY.md` Contact is still TBD-OPERATOR; ASC review-contact fields are not in the repo | operator | OPEN (operator's side) |
| 9 | Land the README Phone section and the CHANGELOG lead before ship | hmd | on approval |
| 10 | `release/ship.sh` (RJ-EXECUTED, `release/publish-checklist.md`): bump, push, verify, tag, Release, npm for both packages, site `/install` pin | operator | after 1-9 |
| 11 | Site: homepage, changelog, privacy page, store links, version pins; push `heimdall-site` | hmd drafts, operator pushes | BACKLOG (deferred out of 2.4.8) |
| 12 | Edit the Release prose; open the public TestFlight link and the Play open test; record the demo | operator | after 7, 10 |
| 13 | Post X, then Show HN. Answer within 2 h, concede valid points, file the issue live (ship-spec L1) | operator | last |

## Weekly metrics (read every Monday, trailing 7 days)

| Metric | Source | Status |
|---|---|---|
| npm installs | npm registry download counts for `runheimdall` and `runhmd`; `npx` runs and CI both count | OPEN: `runhmd` claim (NAMING.md:9) |
| App installs | App Store Connect (TestFlight public link) and Play Console (open test); the app ships no analytics library (hmdapp `package.json`), so the consoles are the only source | OPEN until the links exist |
| Phones paired | None today. The relay has no counter: `GET /health` returns `{ok, version}`, no log event marks a bind, `relay/wrangler.toml` declares no analytics or observability; hmd's `relay-events.jsonl` is local and never sent (DATA.md section 9). **BACKLOG, not built:** an aggregate-only count of binds per week at the relay (no session id, IP or GitHub id kept), plus a DATA.md and store-privacy update | BACKLOG (.planning/BACKLOG.md) |
<!-- HEIMDALL:PIN:END -->
