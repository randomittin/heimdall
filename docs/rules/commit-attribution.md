# Commit attribution: long form

Moved verbatim from `CLAUDE.md` on 2026-11-23 (operator directive: shrink `CLAUDE.md`, which every session and subagent loads, and remove redundancy). `CLAUDE.md` keeps a digest of each rule under the same heading; this file is the long form. "above", "below" and "the Wait guard" in the text refer to the original single file: [README.md](README.md) says where each section lives now. Change a rule here and in the `CLAUDE.md` digest together.

## Commit attribution
Every commit produced through hmd carries:

    Co-Authored-By: runhmd <318965969+runhmd@users.noreply.github.com>

hmd is the constant identity — the model underneath varies (Claude today,
something else tomorrow, a different tool on a teammate's machine) and none of
that changes who gated the work. The trailer records the layer that held the
line, not the one that typed. Rendered through the real `runhmd` GitHub machine
account (id `318965969`) rather than a plain-text address, so it links: see
"GitHub account, not a plain-text address" below. The display name is `runhmd`,
not `hmd` — only the email drives GitHub's account match, so the name is purely
cosmetic, but matching it to the account's actual login means nobody reading
history has to wonder why the visible name and the linked handle disagree.

**The model's own `Co-Authored-By` is stripped, not kept alongside it** (owner
directive, 2026-08-20). This reverses what used to be written here: "keep the
model's own trailer alongside it… dropping the model would be the same overclaim
this repo exists to prevent." The repo owner — the one human accountable for
every push (see the identity gate below) — asked for commits to show their own
identity and hmd's, and nothing else. hmd is what gated the work, so hmd is the
trailer that stays; a doc asserting the old behavior while the hook does the new
one is exactly the drift this repo keeps getting bitten by, so the paragraph is
rewritten here rather than left stale beside the new code.

The trailer is a TRAILER, deliberately. Author and committer stay human, because
`heimdall-selfscan`'s identity gate allowlists `%ae`/`%ce` and a human is the one
accountable for a push — "a human always gates the merge" has to remain literally
true. Trailers sit outside that gate, so this adds no allowlist surface. The gate
reads only the author/committer EMAIL, never the display name — changing
`user.name` (e.g. to a GitHub username) has zero effect on it.

**Mechanically enforced, not just documented.** A generated `prepare-commit-msg`
git hook (`.heimdall/hooks/prepare-commit-msg`, emitted by `hmd init` from
`bin/heimdall-init`) appends the hmd trailer to every commit message that doesn't
already carry it, and strips two things first, unconditionally, before deciding
whether to add: any Anthropic/model `Co-Authored-By` line, and any trailer still
using the OLD `hmd@runheimdall.dev` address retired on 2026-08-20. The Anthropic
strip matches by email DOMAIN (`@anthropic.com`), never the model's display name
— that name changes every release ("Claude Opus 5 (1M context)", "Claude
Sonnet 5", …) but the address stays `noreply@anthropic.com` regardless, so
domain-matching never lags a new model name and never risks catching a real
human co-author. The old-address strip matches the exact retired email, bounded
to the `<...>` field rather than the whole domain — unlike anthropic.com,
`@runheimdall.dev` is also the human owner's own author/committer address and
could plausibly host a real teammate's address too, so only the one retired
local part (`hmd@`) is matched, never the domain. Together the two strips mean a
message can never end up with an old-address trailer, a stray model trailer, and
the current trailer all at once — every rename and every model swap normalizes
to exactly one hmd line, it never stacks. This is the one client-side hook `git
commit --no-verify` does NOT skip — verified empirically, not assumed — which is
why prose alone (agents were told to add this trailer in their spawn prompts and
still routinely didn't: 55/81 commits since 2026-08-18 had it, 26 did not) isn't
enough on its own and this now lives in a hook too. Append-and-strip, all
idempotent: never duplicates the hmd trailer, never leaves a stray model or
old-address trailer behind, and fails OPEN on anything malformed or unwritable —
an attribution trailer is bookkeeping, not a correctness gate, and must never be
the reason a commit is lost. History before this hook existed was NOT rewritten
(~195 unpushed commits at the time — that would have changed every SHA); this
is enforced going forward only, and the same applies to the address rename
itself — commits already made with the old address keep it. See
`test/prepare-commit-msg-trailer.test.sh` (the proof).

**GitHub account, not a plain-text address** (owner directive, 2026-08-20 —
supersedes the "GitHub rendering limitation" this section used to document under
the retired `hmd@runheimdall.dev` address). GitHub only links a `Co-Authored-By`
to an account when the email is verified as belonging to that account; no
GitHub account ever had `hmd@runheimdall.dev` (verified: `gh api
"search/users?q=hmd@runheimdall.dev+in:email"` → `total_count: 0`), so it always
rendered as plain text, with no avatar — and that would have stayed true
regardless of whether the domain itself could receive mail, since GitHub's
account-email verification is the only thing that matters here, not general
deliverability. The owner created a real GitHub account for this instead
(`runhmd`, id `318965969`, type `User`) and the trailer now uses that account's
own GitHub-minted `<id>+<login>@users.noreply.github.com` form — an address
GitHub itself issues and already recognizes for that account, so it needs no
mail delivery or separate verification step and is guaranteed to render as a
linked co-author with an avatar.
