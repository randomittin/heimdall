# Security Policy

Heimdall is a verification layer for coding agents, so we hold our own security
to the same standard we hold your code to: **nothing ships unproven — including
our own history.**

## Reporting a vulnerability

Please report security issues **privately**, not in a public issue or pull
request. Two private channels, use whichever you prefer:

- **Email `security@runheimdall.dev`.** This reaches the maintainer directly.
  Encrypt if you like, or just send enough for us to reproduce.
- **A GitHub Security Advisory** on this repository, if private vulnerability
  reporting is enabled (Security → Advisories → *Report a vulnerability*). This
  keeps the report confidential until a fix is ready and gives us a private
  channel to coordinate. If you do not see the option, use the email above — the
  GitHub private-reporting toggle lives under the repo owner's Settings →
  Security and may not be enabled yet.

What to expect:

- **Acknowledgement target: within 72 hours.** We confirm receipt and let you
  know whether we can reproduce it.
- **Triage target: within 7 days** of acknowledgement — we tell you the severity
  we assigned, whether we accept the report, and our intended fix window.
- We work a fix and a coordinated disclosure timeline with you. We credit
  reporters who want credit; we honor requests to stay anonymous.
- **No bug bounty.** Heimdall is an MIT-licensed open-source project with no
  paid disclosure program. We are grateful for responsible reports regardless.

These are targets from a single maintainer, not a staffed rotation or a
contractual SLA. If you have not heard back within the acknowledgement window,
please assume the mail went astray and ping again rather than assume silence.

## Disclosure policy

We practice coordinated disclosure:

- **90 days** from acknowledgement is the default window to ship a fix before
  the report is made public. If we need longer, we tell you why and agree a new
  date with you rather than let it lapse silently.
- **A fix ships first, then the advisory.** We publish a GitHub Security
  Advisory once a fixed release is available, crediting you unless you asked to
  stay anonymous.
- **Actively-exploited issues move faster** — we fix and disclose as quickly as
  we can, and will not sit on a live exploit for 90 days.
- If you plan to disclose publicly on your own timeline, please tell us the
  date; we would rather ship a fix before it lands than be surprised by it.

## Supported versions

| Version | Supported |
|---|---|
| The latest released version (see [Releases](https://github.com/randomittin/heimdall/releases)) | Yes — security fixes land here |
| Any earlier release | No |

Heimdall ships from a single `main` line with no separately maintained release
branches, so a security fix is delivered as a **new release**, not a backport.
`hmd` is idempotent — re-running the installer upgrades in place. If you are
pinned to an older tag, the remedy for a security issue is to move to the latest
release.

## Safe harbor for good-faith research

We will not pursue, support, or threaten legal action against anyone who reports
a vulnerability in good faith through the private channels above — nor will we
retaliate in any other way. "Good faith" means: you make a reasonable effort to
avoid privacy violations, data loss, and service disruption; you only interact
with accounts and data you own or have explicit permission to test; and you give
us a reasonable window to remediate before public disclosure. If you are unsure
whether an action is authorized, ask us first at `security@runheimdall.dev`.

## Supported scope

| In scope                                                        | Out of scope                                              |
|-----------------------------------------------------------------|-----------------------------------------------------------|
| **The plugin:** the Heimdall harness, gates, sentinels, and hooks in this repo. | Vulnerabilities in Claude Code or the Anthropic platform — report those to their respective projects. |
| **The control plane:** the hosted presence/enrollment/dispatch service (multi-tenant team presence, enroll tokens, PKI, job dispatch). | Issues that require a user to run `--dangerously-skip-permissions` in a throwaway sandbox (that flag is documented as autonomy with no safety classifier in the loop). |
| **The site:** the public marketing/docs site and its install path. | Third-party dependencies — we will help upstream the report. |
| The latest released version on the default branch.              | Automated scanner output with no demonstrated impact, and best-practice suggestions that are not an exploitable weakness. |
| Bypasses of a quality or safety gate that let unproven code through; tenant-isolation breaks in the control plane; supply-chain integrity of the install path. |                                                           |

For which releases receive fixes, see [Supported versions](#supported-versions)
above.

## Secret hygiene

Heimdall treats leaked credentials as a build defect, not an afterthought — and
it points that policy at itself first.

- **A standing secret-scan gate guards every push.** Heimdall's security sentinel
  runs [`gitleaks`](https://github.com/gitleaks/gitleaks) over the working tree
  and the commit range a push would publish, before any code leaves the machine.
  A finding is a hard fail: the push is blocked until the credential is removed
  and rotated. This is the same `git push` gate that re-triggers the
  falsifiability and corpus checks — security is part of the proof, not a
  side-channel.
- **It can run earlier too.** The same scan is safe to wire as a local
  pre-commit step so a credential is caught before it is ever recorded, not just
  before it is pushed. The gate is designed to run at whichever boundary you put
  it on.
- **It degrades honestly, never falsely.** If no scanner is installed, the gate
  reports *skipped* and names the missing tool — it never reports "clean" without
  a real scanner having actually run and found nothing. A pass means a real tool
  ran; a skip means go install one. (Install `gitleaks` to get a real verdict;
  `trufflehog` is a supported fallback.)
- **The principle:** a verification system that cannot prove its own history is
  clean cannot be trusted to prove yours. So the same secret scan that protects
  contributors protects this repository's own commits — credentials are kept out
  of history by construction, not by hope.

If you find a credential that did make it into the tree, please report it through
the private channel above rather than opening a public issue, so it can be
rotated before attention is drawn to it.

The same scan runs in CI as a bypass-proof backstop:
[`.github/workflows/public-repo-no-secrets.yml`](.github/workflows/public-repo-no-secrets.yml)
runs a sha256-pinned `gitleaks` over the full history on every push and pull
request, so a credential cannot land in the public repo even if a local gate was
skipped.

## Release integrity and verification

The install path is part of the attack surface, so it is signed and verifiable —
do not take our word that a downloaded `install.sh` is authentic, check it:

- **Every release signs `install.sh`** with [minisign](https://jedisct1.github.io/minisign/)
  (Ed25519) and publishes `install.sh.minisig` as a release asset. The public
  key ships in the repo at `release/heimdall-signing.pub`.
- **The one-liner in [`README.md`](README.md) is tag-pinned and sha256-checked** —
  it refuses to execute if the downloaded bytes do not match the digest.
- **The auto-updater is fail-closed:** with no signing public key present it
  refuses to apply a release rather than trusting it.

Full model — the verifier refusal codes, the bundled pure-python verifier for
machines without the `minisign` binary, and the signing workflow — is in
[`SIGNING.md`](SIGNING.md).
