#!/usr/bin/env python3
# repo_roster.py — the REPO ROSTER data layer behind bin/heimdall-repo-roster.
#
# THE DEFECT THIS CLOSES. The statusline wall renders LIVE PRESENCE ONLY. Live presence needs a
# control-plane deploy; when that deploy is outstanding the wall shows exactly ONE human and is
# indistinguishable from broken. This module folds THREE independent sources into ONE ranked
# roster of everyone who works on the repo:
#
#   1. online       — a presence heartbeat inside the online TTL (beating right now)
#   2. contributed  — a commit inside the git window, on ANY branch
#   3. away         — a presence heartbeat inside the 7-day wall window, but not beating now
#   4. member       — a repo collaborator (GitHub) with no recent signal at all
#
# THE PROPERTY THAT MAKES IT WORTH BUILDING: tiers 2 and 4 need NO control plane. `git log --all`
# and `gh api .../collaborators` work TODAY. A FULLY degraded presence layer still yields a
# populated, useful wall — so a pending CP deploy stops being an outage.
#
# ── THE FROZEN OUTPUT CONTRACT (the renderer codes against this exactly) ──────────────────────
#
#   [{"handle":       str,                  # display name, short
#     "haid":         str | null,           # null when never enrolled
#     "tier":         "online"|"contributed"|"away"|"member",
#     "online":       bool,
#     "last_seen_ts": number | null,        # presence
#     "last_commit_ts": number | null,      # git
#     "sources":      ["presence","git","github"]},   # which inputs produced this row
#    ...]
#
# Already sorted: best tier first, then most-recent-first inside a tier. EXACTLY these seven
# keys — no more, no fewer. `sources` is emitted in the canonical order presence, git, github.
#
# ── IDENTITY UNIFICATION — the hard part ─────────────────────────────────────────────────────
#
# One human appears under many identities. Measured on the owner's rally repo, a single person
# is ALL of: `akshat@mewt.in`, `akshat@Akshats-MacBook-Air-2.local`,
# `112849320+akshat-mewt@users.noreply.github.com`, GitHub login `akshat-mewt`, and HAID
# `haid:akshat.akshats-macbook-air-2-755c`. Fold them wrong and the wall shows one human three
# times; fold them TOO eagerly and a real teammate is ERASED — which is strictly worse. So:
#
#   THE MERGE RULE. Two identity fragments merge iff EITHER
#     (a) one DECISIVE signal (weight 3) holds, OR
#     (b) the weight totals >= 3 across >= 2 DISTINCT classes AND at least one of those classes
#         is STRONG (weight >= 2).
#   A single non-decisive signal NEVER merges. Weight-1 signals never merge on their own no
#   matter how many pile up: they routinely restate ONE underlying coincidence rather than
#   corroborating independently. Measured — `Akshat Nandini <nandini@elsewhere.example>` against
#   the akshat cluster fires name_first + name_subset + machine_name, three signals that are all
#   just the token `akshat` counted three times; summing them to 3 ERASED a real human from the
#   wall until the strong-class floor was added. The ambiguous zone now REFUSES and is reported
#   as a near-miss by explain() instead of being guessed.
#
#   THE SIGNAL CLASSES (each derived independently, so agreement is real corroboration):
#     email        3  identical normalized email address
#     login        3  identical GitHub login (a globally unique namespace token)
#     name_is_login 3 a git display name that folds byte-equal to a collaborator login on THIS
#                     repo — a deliberate self-identification inside a 19-person bounded set
#     name         2  identical folded display name (>= 4 chars, not generic)
#     localpart    2  identical email local-part (>= 3 chars, not a generic role address)
#     haid_human   2  a HAID's human slug == an email local-part (bin/heimdall-haid derives the
#                     human slug from exactly that local-part, so this is the HAID<->git bridge)
#     haid_machine 2  a HAID's machine slug == a personal-machine email domain slug
#                     (`akshat@Akshats-MacBook-Air-2.local` -> `akshats-macbook-air-2`)
#     login_local  2  a login's head (split on -/_, trailing digits stripped) == a local-part
#     login_org    2  a login folds to local-part + the email domain's org label
#                     (`akshat-mewt` == `akshat` + `mewt` from `akshat@mewt.in`)
#     name_first   1  a login's head == a display name's FIRST token (>= 3 chars)
#     name_subset  1  one display name's token set is a PROPER subset of the other's AND they
#                     share the first token (>= 3 chars)
#     localpart_name 1 a local-part STRICTLY contains a display-name token (>= 4 chars)
#     machine_name   1 a device name — an email's machine domain slug OR a HAID's machine slug —
#                      contains a display-name token (>= 4 chars). Measured: the owner beats as
#                      `haid:rj.rishabhs-macbook-air-46d5` but commits as `Rishabh Jain
#                      <rj@superpe.in>`; the laptop's name is what carries `rishabh` across.
#
#   WHY CONSERVATIVE WINS. `Akshat Nandini <nandini@elsewhere.example>` shares a first-name token
#   with the akshat cluster and nothing else: 2 weak signals, total 2 < 3 -> REFUSED, she keeps
#   her row, and the pair is listed in explain()["near_misses"] so the ambiguity is VISIBLE.
#   Generic role local-parts (git, admin, dev, proxy, noreply, ci, bot, ...) are excluded from
#   the localpart/haid_human classes entirely, so `dev@a` and `dev@b` never collapse.
#
#   Clustering runs to a FIXED POINT over merged clusters, so evidence accumulated by a merge
#   can unlock the next one (git noreply -> login -> the GitHub collaborator row).
#
# ── CACHING (the statusline runs on EVERY prompt) ─────────────────────────────────────────────
#
#   git    TTL   300s (5 min).  `git log --all` measures ~0.2s on a 100-ref repo — not a
#                per-prompt budget. "contributed" is a multi-day window, so 5 minutes of
#                staleness is invisible at that granularity while capping git to <= 12
#                invocations/hour no matter how fast the human types.
#   github TTL 21600s (6 h).    Collaborator sets change on the order of weeks; 6h means <= 4
#                API calls/day/repo (negligible against 5000/hr) and a new collaborator lands
#                within a working half-day.
#   github NEGATIVE TTL 600s (10 min). A FAILED probe (no gh / not authed / offline / 404 /
#                rate-limited) is cached too, so a broken gh is not re-shelled every prompt —
#                but with a SHORT ttl so recovery after `gh auth login` is quick.
#   presence     NOT cached here. It is read from the roster cache the statusline already
#                maintains (<repo>/.heimdall/.roster-cache.json). Zero added egress, zero added
#                presence surface.
#
#   HOT-PATH POLICY (blocking=None, the default): git blocks ONLY on a COLD cache and only
#   behind a hard subprocess timeout; GitHub NEVER blocks — a cold github cache spawns a
#   detached refresh and this render simply lacks tier 4, which appears on the next prompt.
#   Every subprocess runs in its own session and is killed by process group on timeout, so a
#   hung `gh` can never wedge the statusline.
#
# ── PRIVACY (non-negotiable) ─────────────────────────────────────────────────────────────────
#
# Presence is visible ONLY to holders of the repo team secret. Collaborator names from git and
# GitHub are REPO METADATA, not presence. The separation is STRUCTURAL, not a convention:
#   * `online`, `last_seen_ts` and the tiers "online"/"away" are written in exactly ONE place —
#     presence_fragments(), which reads the team-secret-authorized roster cache and nothing else.
#   * git_fragments() and github_fragments() cannot produce them; a person with no presence
#     fragment is forced to online=False, last_seen_ts=None and tier contributed|member.
#   * No presence fact is ever INFERRED from git ("committed 30s ago" never implies online).
#   * Ordering leaks nothing: the sort is a pure function of (tier, timestamps), and without
#     presence only tiers 2 and 4 exist, so the order carries git facts only.
#   presence_free(rows) asserts all of that on a finished roster and is exercised by
#   test/repo-roster.test.sh.
#
# Read-only end to end: this module never writes to the control plane and never mutates the
# presence store. Its only writes are its own cache files.
#
# Exit: the roster path ALWAYS exits 0 (an empty roster is the honest degraded answer, never an
# error); 2 is reserved for CLI usage errors.

import json
import os
import re
import signal
import subprocess
import sys
import time

# ── tiers ────────────────────────────────────────────────────────────────────────────────────
# The ranking is DERIVED from this tuple (index == rank), so inverting this one line inverts the
# whole roster order — which is exactly what test/repo-roster.test.sh mutates to prove the
# ordering proof actually tests the ordering.
_TIER_ORDER = ("online", "contributed", "away", "member")

_SOURCE_ORDER = ("presence", "git", "github")

# ── windows ──────────────────────────────────────────────────────────────────────────────────
# How far back a commit still counts as "contributed". Bounded on purpose: a wider window costs
# more git and turns the wall into a graveyard of everyone who ever touched the repo.
GIT_WINDOW_DAYS_ENV = "HMD_ROSTER_GIT_DAYS"
DEFAULT_GIT_WINDOW_DAYS = 90.0

# The presence wall window — mirrors cp_presence.DEFAULT_OFFLINE_WINDOW_SECONDS and reads the
# SAME env var, so tuning the server's window keeps the client in step.
PRESENCE_WINDOW_ENV = "HEIMDALL_PRESENCE_OFFLINE_WINDOW_SECONDS"
DEFAULT_PRESENCE_WINDOW_SECONDS = 7 * 24 * 60 * 60.0

# Fallback online TTL, used ONLY when a roster row carries neither `online` nor `state` (a CP
# older than the wall-state model). Mirrors cp_presence.DEFAULT_TTL_SECONDS.
PRESENCE_ONLINE_TTL_SECONDS = 45.0

# ── cache TTLs (rationale in the header) ─────────────────────────────────────────────────────
GIT_CACHE_TTL_SECONDS = 300.0
GITHUB_CACHE_TTL_SECONDS = 21600.0
GITHUB_NEGATIVE_TTL_SECONDS = 600.0

# ── hard subprocess bounds — a wedged child must never wedge the statusline ───────────────────
GIT_TIMEOUT_SECONDS = 5.0
GITHUB_TIMEOUT_SECONDS = 8.0
GIT_MAX_COMMITS = 20000        # a monorepo must not stall the walk
GITHUB_MAX_COLLABORATORS = 100  # one page; no --paginate on the hot path

_UNIT_SEP = "\x1f"
_HAID_RE = re.compile(r"^haid:([a-z0-9-]+)\.([a-z0-9-]+)-([0-9a-f]{4})(?:/[a-z0-9][a-z0-9-]*)?$")
_LOGIN_RE = re.compile(r"^[A-Za-z0-9](?:[A-Za-z0-9-]{0,38})$")
_GH_NOREPLY_DOMAIN = "users.noreply.github.com"

# Role addresses that identify a FUNCTION, not a human. Two people can share `dev@` on different
# domains, so these are excluded from the localpart / haid_human classes.
_GENERIC_LOCALPARTS = frozenset("""
admin administrator bot build builder ci cd code contact dev developer deploy devops eng git
github hello hey hi info mail me no-reply noreply ops proxy release root service support team
test testing user www work
""".split())

_GENERIC_NAMES = frozenset("""
admin bot ci dev developer git github none null root unknown user
""".split())

# Domains that host mail for the general public — their org label identifies the PROVIDER, not
# the human's organisation, so login_org must not fire on them.
_PUBLIC_MAIL_DOMAINS = frozenset("""
aol.com fastmail.com gmail.com gmx.com googlemail.com hey.com hotmail.com icloud.com live.com
mail.com mail.ru me.com msn.com outlook.com pm.me proton.me protonmail.com qq.com yahoo.com
yandex.com zoho.com 163.com 126.com
""".split())

# Domain suffixes that mean "this is someone's laptop", not an organisation. mDNS/LAN names.
_MACHINE_SUFFIXES = (".local", ".lan", ".localdomain", ".home", ".home.arpa", ".internal")

# Second-level registry labels: in `superpe.co.in` the org is `superpe`, not `co`.
_REGISTRY_LABELS = frozenset("ac co com edu gov net org sch".split())

# Automation identities. Never humans, never wall rows.
_BOT_EMAILS = frozenset("""
noreply@github.com actions@github.com support@github.com
""".split())
_BOT_NAMES = frozenset(["dependabot", "github", "github action", "github actions",
                        "github-actions", "renovate", "web-flow"])


# ═════════════════════════════════════════════════════════════════════════════════════════════
# Text primitives
# ═════════════════════════════════════════════════════════════════════════════════════════════

def slug(value):
    """Lowercase, keep [a-z0-9], collapse everything else to '-', trim, cap at 24 chars.

    BYTE-IDENTICAL to bin/heimdall-haid's slug(). That equality is load-bearing: it is what lets
    a HAID's machine field be compared against an email's machine domain."""
    if not value:
        return ""
    lowered = str(value).lower()
    out = "".join(ch if ("a" <= ch <= "z" or "0" <= ch <= "9") else "-" for ch in lowered)
    out = re.sub(r"-{2,}", "-", out).strip("-")
    return out[:24]


def fold(value):
    """Case-fold and strip every separator: `Priyadharshan-SuperPe` and `priyadharshan superpe`
    both fold to `priyadharshansuperpe`. Used to compare a display name against a login."""
    if not value:
        return ""
    return re.sub(r"[^a-z0-9]+", "", str(value).lower())


def name_tokens(value):
    """A display name split into lowercase alphanumeric tokens, order preserved."""
    if not value:
        return []
    return [t for t in re.split(r"[^a-z0-9]+", str(value).lower()) if t]


def split_email(email):
    """(local-part, domain), both lowercased. ('', '') when the address is unusable."""
    if not email or "@" not in str(email):
        return "", ""
    local, _, domain = str(email).strip().lower().rpartition("@")
    return local.strip("<> \t"), domain.strip("<> \t")


def github_login_from_email(email):
    """The GitHub login carried by a noreply address, else None.

    `112849320+akshat-mewt@users.noreply.github.com` -> `akshat-mewt`; the older bare
    `login@users.noreply.github.com` form works too. This is the ONE place a git-only scan can
    read a login directly off a commit, which is what makes the noreply identity mergeable."""
    local, domain = split_email(email)
    if domain != _GH_NOREPLY_DOMAIN or not local:
        return None
    candidate = local.split("+", 1)[1] if "+" in local else local
    candidate = candidate.strip()
    return candidate if _LOGIN_RE.match(candidate) else None


def machine_slug(domain):
    """The device slug of a PERSONAL-MACHINE email domain, else ''.

    `Akshats-MacBook-Air-2.local` -> `akshats-macbook-air-2`, which is exactly what
    bin/heimdall-haid's derive_machine() produces from the same host."""
    if not domain:
        return ""
    dom = str(domain).lower()
    for suffix in _MACHINE_SUFFIXES:
        if dom.endswith(suffix) and len(dom) > len(suffix):
            return slug(dom[: -len(suffix)])
    return ""


def domain_org(domain):
    """The organisation label of a domain, else '' for machine/public-mail/github domains.

    `mewt.in` -> `mewt`; `superpe.co` -> `superpe`; `superpe.co.in` -> `superpe`;
    `gmail.com` -> '' (a mail provider is not an organisation)."""
    if not domain:
        return ""
    dom = str(domain).lower().strip(".")
    if dom in _PUBLIC_MAIL_DOMAINS or dom == _GH_NOREPLY_DOMAIN or dom.endswith(".github.com"):
        return ""
    if machine_slug(dom):
        return ""
    parts = [p for p in dom.split(".") if p]
    if len(parts) < 2:
        return ""
    label = parts[-2]
    if label in _REGISTRY_LABELS and len(parts) >= 3:
        label = parts[-3]
    return label


def login_head(login):
    """A login's leading human token: split on -/_, then strip trailing digits.

    `akshat-mewt` -> `akshat`; `Anu5846` -> `anu`; `Ravikiran2904` -> `ravikiran`."""
    if not login:
        return ""
    first = re.split(r"[-_]", str(login).lower(), 1)[0]
    return re.sub(r"\d+$", "", first)


def login_nodigits(login):
    """The whole login, lowercased, with trailing digits stripped (`Nikhil311234` -> `nikhil`)."""
    if not login:
        return ""
    return re.sub(r"\d+$", "", str(login).lower())


def haid_parts(haid):
    """(human, machine) of a well-formed HAID, else ('', ''). Spawn suffixes are ignored."""
    if not haid:
        return "", ""
    match = _HAID_RE.match(str(haid).strip())
    return (match.group(1), match.group(2)) if match else ("", "")


def is_bot(name=None, email=None, login=None):
    """True for automation identities (dependabot, github-actions, the web-flow committer)."""
    for value in (name, login):
        if value and "[bot]" in str(value).lower():
            return True
    if name and " ".join(name_tokens(name)) in _BOT_NAMES:
        return True
    if login and str(login).lower() in _BOT_NAMES:
        return True
    if email and str(email).strip().lower() in _BOT_EMAILS:
        return True
    return False


# ═════════════════════════════════════════════════════════════════════════════════════════════
# Fragments — one observed identity atom, from exactly one source
# ═════════════════════════════════════════════════════════════════════════════════════════════

def fragment(kind, *, handle=None, haid=None, email=None, name=None, login=None,
             online=False, last_seen_ts=None, last_commit_ts=None):
    """Build one identity fragment. `kind` is the source that produced it and is the ONLY way a
    row can acquire the "presence" source, hence the only way it can carry a presence fact."""
    frag = {
        "kinds": {kind} if kind else set(),
        "handles": {handle} if handle else set(),
        "haids": {haid} if haid else set(),
        "emails": {str(email).strip().lower()} if email else set(),
        "names": {str(name).strip()} if name else set(),
        "logins": {str(login).strip().lower()} if login else set(),
        # Comparison always folds case; DISPLAY must not. `SuperMadhavan` is how GitHub spells
        # that human, and a wall that renders `supermadhavan` has quietly corrupted their name.
        "logins_raw": {str(login).strip()} if login else set(),
        "online": bool(online),
        "last_seen_ts": last_seen_ts,
        "last_commit_ts": last_commit_ts,
        "evidence": [],
    }
    return _derive(frag)


def _derive(frag):
    """(Re)compute the comparison attributes of a fragment or cluster."""
    locals_, domains, machines, orgs = set(), set(), set(), set()
    for email in frag["emails"]:
        local, domain = split_email(email)
        login = github_login_from_email(email)
        if login:
            frag["logins"].add(login.lower())
            frag.setdefault("logins_raw", set()).add(login)
            continue          # a noreply local-part is an account id, never a human local-part
        if local:
            locals_.add(local)
        if domain:
            domains.add(domain)
            mslug = machine_slug(domain)
            if mslug:
                machines.add(mslug)
            org = domain_org(domain)
            if org:
                orgs.add(org)
    frag["locals"] = locals_
    frag["domains"] = domains
    frag["machines"] = machines
    frag["orgs"] = orgs
    # A presence handle is a display name for comparison purposes (it is what the dev chose).
    all_names = set(frag["names"]) | set(frag["handles"])
    frag["name_folds"] = {fold(n) for n in all_names if fold(n)}
    frag["name_token_sets"] = [tuple(name_tokens(n)) for n in all_names if name_tokens(n)]
    frag["haid_humans"] = set()
    frag["haid_machines"] = set()
    for haid in frag["haids"]:
        human, machine = haid_parts(haid)
        if human:
            frag["haid_humans"].add(human)
        if machine:
            frag["haid_machines"].add(machine)
    return frag


def _all_name_tokens(frag):
    out = set()
    for tokens in frag["name_token_sets"]:
        out.update(tokens)
    return out


def _first_tokens(frag):
    return {tokens[0] for tokens in frag["name_token_sets"] if tokens}


# ═════════════════════════════════════════════════════════════════════════════════════════════
# The merge rule
# ═════════════════════════════════════════════════════════════════════════════════════════════

def signals(a, b, known_logins=frozenset()):
    """Every corroborating signal between two fragments/clusters, as (class, weight) pairs.

    Each class draws on a DIFFERENT user-configured field (email / name / login / HAID), so two
    classes agreeing is genuine corroboration rather than the same fact counted twice."""
    found = []

    # ── decisive (weight 3) ──────────────────────────────────────────────────────────────────
    if a["emails"] & b["emails"]:
        found.append(("email", 3))
    if a["logins"] & b["logins"]:
        found.append(("login", 3))
    known = {fold(l) for l in known_logins if fold(l)}
    for left, right in ((a, b), (b, a)):
        right_logins = {fold(l) for l in right["logins"]} | known
        for folded in left["name_folds"]:
            if len(folded) >= 4 and folded not in _GENERIC_NAMES and folded in right_logins \
                    and folded in {fold(l) for l in right["logins"]}:
                found.append(("name_is_login", 3))
                break
        else:
            continue
        break

    # ── strong (weight 2) ────────────────────────────────────────────────────────────────────
    shared_names = {n for n in (a["name_folds"] & b["name_folds"])
                    if len(n) >= 4 and n not in _GENERIC_NAMES}
    if shared_names:
        found.append(("name", 2))
    shared_locals = {l for l in (a["locals"] & b["locals"])
                     if len(l) >= 3 and l not in _GENERIC_LOCALPARTS}
    if shared_locals:
        found.append(("localpart", 2))
    # >= 2 chars, not >= 3: bin/heimdall-haid DERIVES the human slug from the email local-part,
    # so an exact match here is structural rather than coincidental. Two-letter initials (`rj`)
    # are extremely common as a work address and the owner is usually the one they belong to.
    if any(h in other["locals"] and h not in _GENERIC_LOCALPARTS and len(h) >= 2
           for one, other in ((a, b), (b, a)) for h in one["haid_humans"]):
        found.append(("haid_human", 2))
    if any(m in other["machines"]
           for one, other in ((a, b), (b, a)) for m in one["haid_machines"]):
        found.append(("haid_machine", 2))
    if any((login_head(l) == lp or login_nodigits(l) == lp)
           for one, other in ((a, b), (b, a))
           for l in one["logins"]
           for lp in other["locals"]
           if len(lp) >= 3 and lp not in _GENERIC_LOCALPARTS):
        found.append(("login_local", 2))
    if any(fold(l) == lp + org
           for one, other in ((a, b), (b, a))
           for l in one["logins"]
           for lp in other["locals"]
           for org in other["orgs"]
           if len(lp) >= 3 and org):
        found.append(("login_org", 2))

    # ── corroborating only (weight 1 — never enough on its own) ──────────────────────────────
    if any(login_head(l) == tok
           for one, other in ((a, b), (b, a))
           for l in one["logins"]
           for tok in _first_tokens(other)
           if len(tok) >= 3 and tok not in _GENERIC_NAMES):
        found.append(("name_first", 1))
    if _name_subset(a, b) or _name_subset(b, a):
        found.append(("name_subset", 1))
    if any(tok in lp and len(lp) > len(tok)
           for one, other in ((a, b), (b, a))
           for lp in one["locals"]
           for tok in _all_name_tokens(other)
           if len(tok) >= 4):
        found.append(("localpart_name", 1))
    # A HAID's machine field and an email's machine domain are the SAME kind of evidence — a
    # device name — so both are searched. `haid:rj.rishabhs-macbook-air-46d5` carries `rishabh`
    # even though the git address (`rj@superpe.in`) never does.
    if any(tok in mslug
           for one, other in ((a, b), (b, a))
           for mslug in (one["machines"] | one["haid_machines"])
           for tok in _all_name_tokens(other)
           if len(tok) >= 4):
        found.append(("machine_name", 1))
    return found


def _name_subset(a, b):
    """One display name's tokens are a PROPER subset of the other's, sharing the first token.

    `Akshat` inside `Akshat Singh` fires; `Akshat Nandini` vs `Akshat Singh` does NOT (neither
    contains the other), which is precisely what keeps two same-first-name humans apart."""
    for small in a["name_token_sets"]:
        for big in b["name_token_sets"]:
            if not small or not big or len(small) >= len(big):
                continue
            if small[0] != big[0] or len(small[0]) < 3 or small[0] in _GENERIC_NAMES:
                continue
            if set(small) < set(big):
                return True
    return False


def would_merge(a, b, known_logins=frozenset()):
    """(bool, evidence). Merge iff one DECISIVE signal, OR weight >= 3 across >= 2 distinct
    classes WITH at least one strong (weight >= 2) class among them.

    Three floors, each closing a different way to erase a human:
      * the two-class floor — a lone strong signal (a shared local-part, a matching login head)
        is never enough on its own;
      * the strong-class floor — weight-1 signals cannot merge by accumulation, because several
        of them usually restate ONE coincidence (a shared first name shows up as name_first AND
        name_subset AND machine_name) rather than corroborating independently;
      * the weight floor — a single weak signal is noise.
    A refused-but-suspicious pair surfaces through explain()["near_misses"], so residual
    ambiguity is made VISIBLE rather than silently guessed in either direction."""
    found = signals(a, b, known_logins)
    if any(weight >= 3 for _, weight in found):
        return True, found
    classes = {name for name, _ in found}
    total = sum(weight for _, weight in found)
    has_strong = any(weight >= 2 for _, weight in found)
    return (total >= 3 and len(classes) >= 2 and has_strong), found


_SET_KEYS = ("kinds", "handles", "haids", "emails", "names", "logins", "logins_raw")


def _clone(frag):
    """A deep-enough copy: every identity set is fresh so absorbing never mutates the caller's
    fragments (unify must be safe to call twice on the same list)."""
    out = dict(frag)
    for key in _SET_KEYS:
        out[key] = set(frag.get(key) or ())
    out["evidence"] = list(frag.get("evidence") or ())
    return _derive(out)


def _absorb(target, other, evidence):
    """Fold `other` into `target`, keeping the freshest timestamps and the union of identities."""
    for key in _SET_KEYS:
        target[key] = set(target.get(key) or ()) | set(other.get(key) or ())
    target["online"] = bool(target["online"]) or bool(other["online"])
    target["last_seen_ts"] = _max_ts(target["last_seen_ts"], other["last_seen_ts"])
    target["last_commit_ts"] = _max_ts(target["last_commit_ts"], other["last_commit_ts"])
    target["evidence"] = list(target["evidence"]) + list(other["evidence"]) + list(evidence)
    return _derive(target)


def _max_ts(left, right):
    values = [v for v in (left, right) if isinstance(v, (int, float)) and not isinstance(v, bool)]
    return max(values) if values else None


def unify(fragments, known_logins=frozenset()):
    """Fold fragments into people. Runs to a FIXED POINT so evidence gained by one merge can
    unlock the next (a git noreply address yields a login, which then merges the GitHub row)."""
    clusters = [_clone(f) for f in fragments]
    merged = True
    while merged and len(clusters) > 1:
        merged = False
        for i in range(len(clusters)):
            for j in range(i + 1, len(clusters)):
                ok, evidence = would_merge(clusters[i], clusters[j], known_logins)
                if ok:
                    clusters[i] = _absorb(clusters[i], clusters.pop(j), evidence)
                    merged = True
                    break
            if merged:
                break
    return clusters


def near_misses(clusters, known_logins=frozenset()):
    """Pairs that were REFUSED but showed some evidence — the residual ambiguity, made visible.

    Emitted by explain(), never by the frozen contract: surfacing a doubt must not change the
    shape the renderer parses."""
    out = []
    for i in range(len(clusters)):
        for j in range(i + 1, len(clusters)):
            found = signals(clusters[i], clusters[j], known_logins)
            if not found:
                continue
            ok, _ = would_merge(clusters[i], clusters[j], known_logins)
            if ok:
                continue
            out.append({
                "a": display_handle(clusters[i]),
                "b": display_handle(clusters[j]),
                "weight": sum(w for _, w in found),
                "signals": sorted(name for name, _ in found),
                "a_identities": _identity_list(clusters[i]),
                "b_identities": _identity_list(clusters[j]),
            })
    out.sort(key=lambda m: (-m["weight"], m["a"], m["b"]))
    return out


def _identity_list(cluster):
    return sorted(cluster["emails"] | (cluster.get("logins_raw") or cluster["logins"])
                  | cluster["haids"] | cluster["names"])


# ═════════════════════════════════════════════════════════════════════════════════════════════
# Sources — presence (team-secret gated), git, github
# ═════════════════════════════════════════════════════════════════════════════════════════════

def presence_cache_path(repo):
    """The roster cache the statusline already maintains. Reading it is the WHOLE presence
    integration: `heimdall-presence roster --json` (which carries the repo team secret) writes
    it, we read it. No new presence surface, no extra egress, and a reader without the team
    secret finds nothing here because the control plane never returned anything to write."""
    override = os.environ.get("HMD_ROSTER_PRESENCE_CACHE")
    if override:
        return override
    if not repo:
        return None
    return os.path.join(repo, ".heimdall", ".roster-cache.json")


def presence_window_seconds():
    raw = os.environ.get(PRESENCE_WINDOW_ENV)
    if raw:
        try:
            value = float(raw)
            if value > 0:
                return value
        except (TypeError, ValueError):
            return DEFAULT_PRESENCE_WINDOW_SECONDS
    return DEFAULT_PRESENCE_WINDOW_SECONDS


def presence_fragments(repo=None, *, now=None, cache_path=None, rows=None):
    """THE ONLY producer of presence facts (online / last_seen_ts / tiers online+away).

    Reads the team-secret-authorized roster cache; an absent, empty, or unparsable file yields
    [] — the honest degraded answer that leaves the wall built from git + github alone."""
    when = float(now) if now is not None else time.time()
    if rows is None:
        path = cache_path if cache_path is not None else presence_cache_path(repo)
        rows = _read_json(path)
    if not isinstance(rows, list):
        return []
    window = presence_window_seconds()
    out = []
    for row in rows:
        if not isinstance(row, dict):
            continue
        if row.get("retired"):
            continue          # opt-out is honored at the read authority too (defense in depth)
        haid = row.get("haid") if isinstance(row.get("haid"), str) else None
        handle = row.get("handle") if isinstance(row.get("handle"), str) else None
        if not haid and not handle:
            continue
        last_seen = _presence_last_seen(row, when)
        if last_seen is None or (when - last_seen) > window:
            continue          # past the 7-day wall window: not a teammate, a memory
        if is_bot(name=handle, login=handle):
            continue
        out.append(fragment("presence", handle=handle, haid=haid,
                            online=_presence_online(row, when, last_seen),
                            last_seen_ts=last_seen))
    return out


def _presence_last_seen(row, when):
    """Prefer age_seconds over ts: the server measured the age against ITS clock, so an age is
    immune to client/server skew. Mirrors sentinels/hmd-statusline.py's roster_presence()."""
    age = row.get("age_seconds")
    if isinstance(age, (int, float)) and not isinstance(age, bool):
        return when - float(age)
    ts = row.get("ts")
    if isinstance(ts, (int, float)) and not isinstance(ts, bool):
        return float(ts)
    return None


def _presence_online(row, when, last_seen):
    """The server's own flag wins. Then the derived wall state. Only if BOTH are absent (a CP
    older than the wall-state model) fall back to the TTL — never a hardcoded True: a wall that
    invents a present teammate is worse than an empty one."""
    flag = row.get("online")
    if isinstance(flag, bool):
        return flag
    state = row.get("state")
    if isinstance(state, str) and state:
        return state != "offline"
    return (when - last_seen) <= PRESENCE_ONLINE_TTL_SECONDS


def git_fragments(repo, *, now=None, days=None, cache_dir=None, blocking=None):
    """Authors who committed inside the window, across ALL refs.

    `--all` is load-bearing: teammates work on their OWN branches, so a HEAD-only scan silently
    misses them (measured — anu never appears in a HEAD-only scan of rally). Bounded three ways:
    the `--since` window, GIT_MAX_COMMITS, and a hard subprocess timeout."""
    when = float(now) if now is not None else time.time()
    window_days = float(days) if days is not None else git_window_days()
    if not repo:
        return []
    key = _cache_key(repo, "git", window_days)
    path = _cache_file(cache_dir, repo, key)
    payload, fresh = _cache_read(path, GIT_CACHE_TTL_SECONDS, when)
    if payload is None or (not fresh and blocking is True):
        if blocking is False and payload is None:
            _spawn_refresh(repo, window_days, cache_dir)
            return []
        payload = _git_probe(repo, when, window_days)
        _cache_write(path, payload)
    elif not fresh:
        _spawn_refresh(repo, window_days, cache_dir)
    return _git_payload_to_fragments(payload, when, window_days)


def _git_payload_to_fragments(payload, when, window_days):
    if not isinstance(payload, dict) or not payload.get("ok"):
        return []
    cutoff = when - window_days * 86400.0
    out = []
    for author in payload.get("authors") or []:
        if not isinstance(author, dict):
            continue
        email = author.get("email")
        last = author.get("last_commit_ts")
        if not isinstance(last, (int, float)) or isinstance(last, bool) or last < cutoff:
            continue
        names = [n for n in (author.get("names") or []) if isinstance(n, str) and n.strip()]
        if is_bot(name=(names[0] if names else None), email=email):
            continue
        frag = fragment("git", email=email, name=(names[0] if names else None),
                        last_commit_ts=float(last))
        for extra in names[1:]:
            frag["names"].add(extra.strip())
        out.append(_derive(frag))
    return out


def _git_probe(repo, when, window_days):
    """One bounded `git log --all` over the window. Any failure is a clean {ok: False}."""
    cutoff = when - window_days * 86400.0
    since = time.strftime("%Y-%m-%dT%H:%M:%S+0000", time.gmtime(max(0.0, cutoff)))
    code, out, _err = _run([
        "git", "-C", repo, "log", "--all", "--no-show-signature",
        "--since=" + since, "--max-count=%d" % GIT_MAX_COMMITS,
        "--format=%aN" + _UNIT_SEP + "%aE" + _UNIT_SEP + "%at",
    ], GIT_TIMEOUT_SECONDS)
    if code != 0:
        return {"ok": False, "ts": when, "reason": "git_unavailable", "authors": []}
    by_email = {}
    for line in out.splitlines():
        parts = line.split(_UNIT_SEP)
        if len(parts) != 3:
            continue
        name, email, raw_ts = parts[0].strip(), parts[1].strip().lower(), parts[2].strip()
        if not email:
            continue
        try:
            ts = float(raw_ts)
        except (TypeError, ValueError):
            continue
        entry = by_email.setdefault(email, {"email": email, "names": [], "last_commit_ts": ts})
        entry["last_commit_ts"] = max(entry["last_commit_ts"], ts)
        if name and name not in entry["names"]:
            entry["names"].append(name)
    return {"ok": True, "ts": when, "days": window_days,
            "authors": sorted(by_email.values(), key=lambda a: a["email"])}


def github_slug(repo):
    """`owner/repo` when origin points at github.com, else ''. Pure git config — no network."""
    override = os.environ.get("HMD_ROSTER_GITHUB_SLUG")
    if override:
        return override.strip().strip("/")
    if not repo:
        return ""
    code, out, _err = _run(["git", "-C", repo, "config", "--get", "remote.origin.url"],
                           GIT_TIMEOUT_SECONDS)
    if code != 0:
        return ""
    url = out.strip()
    if not url:
        return ""
    norm = re.sub(r"^[a-z+]+://", "", url.strip(), flags=re.I)
    norm = re.sub(r"^[^/@]+@", "", norm)
    norm = norm.replace(":", "/", 1) if "@" not in norm and ":" in norm.split("/", 1)[0] else norm
    norm = re.sub(r"^github\.com[:/]", "github.com/", norm, flags=re.I)
    norm = norm.rstrip("/")
    if norm.lower().endswith(".git"):
        norm = norm[:-4]
    match = re.match(r"(?i)^github\.com/([^/]+)/([^/]+)$", norm)
    return "%s/%s" % (match.group(1), match.group(2)) if match else ""


def github_fragments(repo, *, cache_dir=None, blocking=None, now=None):
    """Repo collaborators — tier 4, and the only source that needs no local history.

    DEGRADES CLEANLY, ALWAYS. No gh, not authed, no network, a private repo, a 404, a rate
    limit, garbage on stdout, or a gh that HANGS — every one of them yields [] and a negative
    cache entry. The roster keeps tiers 1-3 and simply lacks tier 4. It never blocks the
    statusline: on the hot path (blocking is None/False) a cold cache spawns a detached refresh
    and this render goes without tier 4."""
    when = float(now) if now is not None else time.time()
    if os.environ.get("HMD_ROSTER_NO_GITHUB"):
        return []
    slug_ = github_slug(repo)
    if not slug_:
        return []           # not a github remote: nothing to ask, nothing to degrade
    key = _cache_key(slug_, "github", 0)
    path = _cache_file(cache_dir, repo, key)
    payload, fresh = _cache_read(path, GITHUB_CACHE_TTL_SECONDS, when,
                                 negative_ttl=GITHUB_NEGATIVE_TTL_SECONDS)
    if not fresh:
        if blocking is True:
            payload = _github_probe(slug_, when)
            _cache_write(path, payload)
        else:
            _spawn_refresh(repo, git_window_days(), cache_dir)
            if payload is None:
                return []
    if not isinstance(payload, dict) or not payload.get("ok"):
        return []
    out = []
    for login in payload.get("logins") or []:
        if not isinstance(login, str) or not _LOGIN_RE.match(login) or is_bot(login=login):
            continue
        out.append(fragment("github", login=login))
    return out


def _github_probe(slug_, when):
    """One bounded `gh api` call. Every failure mode collapses to {ok: False, reason}."""
    env = dict(os.environ)
    env.update({"GH_PROMPT_DISABLED": "1", "GH_NO_UPDATE_NOTIFIER": "1", "GH_PAGER": "cat",
                "PAGER": "cat", "NO_COLOR": "1", "CLICOLOR": "0", "GIT_TERMINAL_PROMPT": "0"})
    code, out, err = _run(
        ["gh", "api", "repos/%s/collaborators?per_page=%d" % (slug_, GITHUB_MAX_COLLABORATORS),
         "--jq", ".[].login"],
        GITHUB_TIMEOUT_SECONDS, env=env)
    if code == 127:
        return {"ok": False, "ts": when, "slug": slug_, "reason": "gh_absent", "logins": []}
    if code == -1:
        return {"ok": False, "ts": when, "slug": slug_, "reason": "timeout", "logins": []}
    if code != 0:
        return {"ok": False, "ts": when, "slug": slug_, "logins": [],
                "reason": _github_failure_reason(err)}
    logins = []
    for line in out.splitlines():
        candidate = line.strip().strip('"')
        if candidate and _LOGIN_RE.match(candidate) and candidate not in logins:
            logins.append(candidate)
    if not logins:
        return {"ok": False, "ts": when, "slug": slug_, "reason": "no_logins", "logins": []}
    return {"ok": True, "ts": when, "slug": slug_, "logins": logins[:GITHUB_MAX_COLLABORATORS]}


def _github_failure_reason(err):
    lowered = (err or "").lower()
    if "rate limit" in lowered:
        return "rate_limited"
    if "404" in lowered or "not found" in lowered:
        return "not_found"
    if "no such host" in lowered or "dial tcp" in lowered or "connection refused" in lowered \
            or "network is unreachable" in lowered or "timeout" in lowered:
        return "offline"
    if "gh_token" in lowered or "gh auth" in lowered or "authentication" in lowered \
            or "401" in lowered:
        return "not_authenticated"
    return "gh_error"


# ═════════════════════════════════════════════════════════════════════════════════════════════
# Bounded subprocess + cache
# ═════════════════════════════════════════════════════════════════════════════════════════════

def _run(argv, timeout, env=None):
    """(returncode, stdout, stderr). 127 when the binary is absent, -1 on timeout.

    The child gets its OWN session and is killed BY PROCESS GROUP on timeout, so a `gh` that
    shells out and hangs cannot leave an orphan holding the pipe — which is exactly how a
    statusline wedges. Never raises: every failure is a return code."""
    try:
        proc = subprocess.Popen(argv, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                stdin=subprocess.DEVNULL, env=env, start_new_session=True,
                                universal_newlines=True)
    except FileNotFoundError:
        return 127, "", "binary not found: %s" % argv[0]
    except (OSError, ValueError) as exc:
        return 126, "", str(exc)
    try:
        out, err = proc.communicate(timeout=timeout)
        return proc.returncode, out or "", err or ""
    except subprocess.TimeoutExpired:
        _kill_group(proc)
        return -1, "", "timed out after %ss" % timeout
    except OSError as exc:
        _kill_group(proc)
        return 126, "", str(exc)


def _kill_group(proc):
    try:
        os.killpg(os.getpgid(proc.pid), signal.SIGKILL)
    except (OSError, ProcessLookupError):
        proc.kill()
    try:
        proc.communicate(timeout=2)
    except (subprocess.TimeoutExpired, OSError, ValueError):
        return None
    return None


def _read_json(path):
    if not path:
        return None
    try:
        with open(path, "r") as handle:
            return json.load(handle)
    except (OSError, ValueError):
        return None


def _cache_key(subject, kind, window):
    raw = "%s\x1f%s\x1f%s" % (os.path.realpath(str(subject)) if os.path.isdir(str(subject))
                              else str(subject), kind, window)
    digest = 0
    for ch in raw:
        digest = (digest * 131 + ord(ch)) & 0xFFFFFFFFFFFF
    return "%s-%012x" % (kind, digest)


def cache_dir_for(repo, override=None):
    """Where the git/github caches live: the override, else <repo>/.heimdall (next to the
    roster cache the statusline already writes), else ~/.heimdall/roster-cache."""
    candidate = override or os.environ.get("HMD_ROSTER_CACHE_DIR")
    if not candidate and repo:
        candidate = os.path.join(repo, ".heimdall")
    if not candidate:
        candidate = os.path.join(os.path.expanduser("~"), ".heimdall", "roster-cache")
    try:
        os.makedirs(candidate, exist_ok=True)
        return candidate
    except OSError:
        return None


def _cache_file(cache_dir, repo, key):
    directory = cache_dir_for(repo, cache_dir)
    return os.path.join(directory, ".repo-roster-%s.json" % key) if directory else None


def _cache_read(path, ttl, now, negative_ttl=None):
    """(payload, fresh). A FAILED payload uses the shorter negative ttl so a broken probe is not
    re-shelled every prompt while still recovering quickly once the cause clears."""
    payload = _read_json(path)
    if not isinstance(payload, dict):
        return None, False
    stamp = payload.get("ts")
    if not isinstance(stamp, (int, float)) or isinstance(stamp, bool):
        return payload, False
    effective = ttl if payload.get("ok") else (negative_ttl if negative_ttl is not None else ttl)
    return payload, (0 <= (now - float(stamp)) <= effective)


def _cache_write(path, payload):
    if not path or not isinstance(payload, dict):
        return False
    tmp = "%s.%d.tmp" % (path, os.getpid())
    try:
        with open(tmp, "w") as handle:
            json.dump(payload, handle, sort_keys=True)
        os.replace(tmp, path)
        return True
    except (OSError, ValueError, TypeError):
        try:
            os.remove(tmp)
        except OSError:
            return False
        return False


def _spawn_refresh(repo, window_days, cache_dir):
    """Fire-and-forget cache warm, mirroring sentinels/hmd-statusline.py's presence fork: fully
    detached, output discarded, stampede-guarded by a lock stamp. NEVER waited on — this is the
    reason the hot path cannot block on gh."""
    directory = cache_dir_for(repo, cache_dir)
    if not directory or not repo:
        return False
    lock = os.path.join(directory, ".repo-roster-refresh.lock")
    now = time.time()
    try:
        if os.path.exists(lock) and (now - os.path.getmtime(lock)) < 30:
            return False
        with open(lock, "w") as handle:
            handle.write("%d\n" % os.getpid())
    except OSError:
        return False
    argv = [sys.executable or "python3", os.path.abspath(__file__), "--refresh",
            "--repo", repo, "--git-days", str(window_days), "--cache-dir", directory]
    try:
        subprocess.Popen(argv, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                         stdin=subprocess.DEVNULL, start_new_session=True)
        return True
    except (OSError, ValueError):
        try:
            os.remove(lock)
        except OSError:
            return False
        return False


def git_window_days():
    raw = os.environ.get(GIT_WINDOW_DAYS_ENV)
    if raw:
        try:
            value = float(raw)
            if value > 0:
                return value
        except (TypeError, ValueError):
            return DEFAULT_GIT_WINDOW_DAYS
    return DEFAULT_GIT_WINDOW_DAYS


# ═════════════════════════════════════════════════════════════════════════════════════════════
# People -> the frozen contract
# ═════════════════════════════════════════════════════════════════════════════════════════════

def display_handle(cluster):
    """The short display name. A presence handle wins (the dev chose it), then the first token of
    the RICHEST git name, then a login, then an email local-part, then the HAID's human slug."""
    for handle in sorted(cluster["handles"]):
        if handle.strip():
            return handle.strip()
    names = sorted(cluster["names"], key=lambda n: (-len(name_tokens(n)), n))
    for name in names:
        tokens = name_tokens(name)
        if tokens and len(tokens[0]) >= 2 and tokens[0] not in _GENERIC_NAMES:
            return tokens[0]
    for login in sorted(cluster.get("logins_raw") or cluster["logins"]):
        if login:
            return login
    for local in sorted(cluster["locals"]):
        if local:
            return local
    for human in sorted(cluster["haid_humans"]):
        if human:
            return human
    return "?"


def _handle_candidates(cluster):
    """Progressively more specific display names, used to break a collision between two DISTINCT
    humans who share a first name. Showing `akshat` twice is indistinguishable on a wall, so the
    lower-ranked row gets a longer, unambiguous label instead."""
    out = [display_handle(cluster)]
    for name in sorted(cluster["names"], key=lambda n: (-len(name_tokens(n)), n)):
        tokens = name_tokens(name)
        if len(tokens) > 1:
            out.append(" ".join(tokens))
    out.extend(sorted(cluster.get("logins_raw") or cluster["logins"]))
    out.extend(sorted(cluster["locals"]))
    out.extend(sorted(cluster["haid_humans"]))
    seen, unique = set(), []
    for candidate in out:
        if candidate and candidate not in seen:
            seen.add(candidate)
            unique.append(candidate)
    return unique or ["?"]


def _pick_haid(cluster):
    """One HAID for the row. A human on two machines has two HAIDs; take the lexicographically
    smallest so the choice is stable across renders rather than flapping."""
    valid = sorted(h for h in cluster["haids"] if _HAID_RE.match(str(h).strip()))
    return valid[0] if valid else None


def tier_of(cluster, *, now, git_days):
    """The rank. `online` and `away` REQUIRE a presence fragment — that is the structural reason
    a reader without the team secret can never see a presence tier."""
    has_presence = "presence" in cluster["kinds"]
    if has_presence and cluster["online"]:
        return "online"
    last_commit = cluster["last_commit_ts"]
    if isinstance(last_commit, (int, float)) and not isinstance(last_commit, bool) \
            and (now - float(last_commit)) <= git_days * 86400.0:
        return "contributed"
    if has_presence:
        return "away"
    return "member"


def _sources(cluster):
    return [s for s in _SOURCE_ORDER if s in cluster["kinds"]]


def rows(clusters, *, now, git_days):
    """The FROZEN CONTRACT: exactly seven keys per row, sorted best-tier-first then
    most-recent-first within a tier."""
    ordered = sorted(clusters, key=lambda c: _presort_key(c, now=now, git_days=git_days))
    used, out = set(), []
    for cluster in ordered:
        tier = tier_of(cluster, now=now, git_days=git_days)
        has_presence = "presence" in cluster["kinds"]
        handle = _unique_handle(cluster, used)
        used.add(handle)
        out.append({
            "handle": handle,
            "haid": _pick_haid(cluster),
            "tier": tier,
            "online": bool(has_presence and cluster["online"]),
            "last_seen_ts": cluster["last_seen_ts"] if has_presence else None,
            "last_commit_ts": cluster["last_commit_ts"],
            "sources": _sources(cluster),
        })
    return out


def _unique_handle(cluster, used):
    for candidate in _handle_candidates(cluster):
        if candidate not in used:
            return candidate
    base = _handle_candidates(cluster)[0]
    index = 2
    while "%s~%d" % (base, index) in used:
        index += 1
    return "%s~%d" % (base, index)


def _presort_key(cluster, *, now, git_days):
    tier = tier_of(cluster, now=now, git_days=git_days)
    rank = _TIER_ORDER.index(tier) if tier in _TIER_ORDER else len(_TIER_ORDER)
    seen = cluster["last_seen_ts"] if "presence" in cluster["kinds"] else None
    commit = cluster["last_commit_ts"]
    if tier in ("online", "away"):
        primary, secondary = seen, commit
    elif tier == "contributed":
        primary, secondary = commit, seen
    else:
        primary, secondary = None, None
    return (rank, -_num(primary), -_num(secondary), display_handle(cluster))


def _num(value):
    return float(value) if isinstance(value, (int, float)) and not isinstance(value, bool) else 0.0


def presence_free(roster_rows):
    """True iff NO row carries a presence fact — the assertion behind the privacy guarantee.

    A roster built without the repo team secret must satisfy this: no online:true, no
    last_seen_ts, no "presence" source, and no online/away tier."""
    for row in roster_rows or []:
        if row.get("online"):
            return False
        if row.get("last_seen_ts") is not None:
            return False
        if "presence" in (row.get("sources") or []):
            return False
        if row.get("tier") in ("online", "away"):
            return False
    return True


# ═════════════════════════════════════════════════════════════════════════════════════════════
# The one-shot entry points
# ═════════════════════════════════════════════════════════════════════════════════════════════

def collect(repo=None, *, now=None, git_days=None, presence_cache=None, cache_dir=None,
            blocking=None, use_presence=True, use_git=True, use_github=True):
    """Gather every fragment, then unify. Each source is independently skippable and each one
    degrades to [] on its own, so any subset of the three still produces a roster."""
    when = float(now) if now is not None else time.time()
    window = float(git_days) if git_days is not None else git_window_days()
    repo_dir = repo if repo else _git_toplevel(os.getcwd())
    frags = []
    if use_presence:
        frags.extend(presence_fragments(repo_dir, now=when, cache_path=presence_cache))
    if use_git:
        frags.extend(git_fragments(repo_dir, now=when, days=window, cache_dir=cache_dir,
                                   blocking=blocking))
    gh_frags = github_fragments(repo_dir, cache_dir=cache_dir, blocking=blocking,
                                now=when) if use_github else []
    frags.extend(gh_frags)
    known = {next(iter(f["logins"])) for f in gh_frags if f["logins"]}
    return unify(frags, known), known, when, window


def build(repo=None, *, now=None, git_days=None, presence_cache=None, cache_dir=None,
          blocking=None, use_presence=True, use_git=True, use_github=True):
    """THE ENTRY POINT the renderer calls. Returns the frozen contract. Never raises."""
    clusters, _known, when, window = collect(
        repo, now=now, git_days=git_days, presence_cache=presence_cache, cache_dir=cache_dir,
        blocking=blocking, use_presence=use_presence, use_git=use_git, use_github=use_github)
    return rows(clusters, now=when, git_days=window)


def explain(repo=None, **kwargs):
    """The AUDIT view — the frozen array PLUS why each person merged and which refused pairs are
    still ambiguous. Separate on purpose: surfacing a doubt must never change the shape the
    renderer parses."""
    clusters, known, when, window = collect(repo, **kwargs)
    people = []
    for cluster in sorted(clusters, key=lambda c: _presort_key(c, now=when, git_days=window)):
        people.append({
            "handle": display_handle(cluster),
            "tier": tier_of(cluster, now=when, git_days=window),
            "sources": _sources(cluster),
            "identities": _identity_list(cluster),
            "merged_on": sorted({name for name, _ in cluster["evidence"]}),
        })
    return {
        "people": people,
        "near_misses": near_misses(clusters, known),
        "rows": rows(clusters, now=when, git_days=window),
        "counts": {"people": len(people), "collaborators": len(known)},
        "cache_ttl_seconds": {"git": GIT_CACHE_TTL_SECONDS, "github": GITHUB_CACHE_TTL_SECONDS,
                              "github_negative": GITHUB_NEGATIVE_TTL_SECONDS},
    }


def _git_toplevel(start):
    code, out, _err = _run(["git", "-C", start, "rev-parse", "--show-toplevel"],
                           GIT_TIMEOUT_SECONDS)
    return out.strip() if code == 0 and out.strip() else start


def refresh(repo, *, git_days=None, cache_dir=None, now=None):
    """Warm BOTH caches synchronously. This is what the detached background child runs, and what
    `--refresh` does from the CLI. Returns the two payloads for observability."""
    when = float(now) if now is not None else time.time()
    window = float(git_days) if git_days is not None else git_window_days()
    git_payload = _git_probe(repo, when, window)
    _cache_write(_cache_file(cache_dir, repo, _cache_key(repo, "git", window)), git_payload)
    gh_payload = {"ok": False, "reason": "not_github", "logins": [], "ts": when}
    slug_ = github_slug(repo)
    if slug_ and not os.environ.get("HMD_ROSTER_NO_GITHUB"):
        gh_payload = _github_probe(slug_, when)
        _cache_write(_cache_file(cache_dir, repo, _cache_key(slug_, "github", 0)), gh_payload)
    directory = cache_dir_for(repo, cache_dir)
    if directory:
        try:
            os.remove(os.path.join(directory, ".repo-roster-refresh.lock"))
        except OSError:
            return {"git": git_payload, "github": gh_payload}
    return {"git": git_payload, "github": gh_payload}


# ═════════════════════════════════════════════════════════════════════════════════════════════
# CLI
# ═════════════════════════════════════════════════════════════════════════════════════════════

_USAGE = """usage: heimdall-repo-roster [options]

Emit the repo roster — everyone who works on this repo, ranked:
  online       a presence heartbeat inside the online TTL   (needs the repo team secret)
  contributed  a commit inside the git window, any branch   (git only, no control plane)
  away         seen inside the 7-day presence window        (needs the repo team secret)
  member       a GitHub collaborator with no recent signal  (gh only, no control plane)

Options:
  --repo DIR            repo to inspect (default: the git toplevel of cwd)
  --git-days N          the "contributed" window in days (default %d, $HMD_ROSTER_GIT_DAYS)
  --presence-cache P    the roster cache to read (default <repo>/.heimdall/.roster-cache.json)
  --cache-dir DIR       where the git/github caches live (default <repo>/.heimdall)
  --now EPOCH           inject the clock (tests / deterministic renders)
  --blocking            refresh stale caches synchronously instead of in the background
  --refresh             ONLY warm the caches, print the probe results, exit
  --explain             the audit view: merge evidence + residual near-miss pairs
  --no-presence         skip the presence source
  --no-git              skip the git source
  --no-github           skip the github source
  -h, --help

Output is the frozen JSON array (or, with --explain, the audit object). Exit is ALWAYS 0 for a
roster — an empty roster is the honest degraded answer, never an error. 2 is a usage error.
""" % int(DEFAULT_GIT_WINDOW_DAYS)


def _cli(argv):
    opts = {"repo": None, "git_days": None, "presence_cache": None, "cache_dir": None,
            "now": None, "blocking": None, "explain": False, "refresh": False,
            "use_presence": True, "use_git": True, "use_github": True}
    flags = {"--no-presence": "use_presence", "--no-git": "use_git", "--no-github": "use_github"}
    values = {"--repo": "repo", "--git-days": "git_days", "--presence-cache": "presence_cache",
              "--cache-dir": "cache_dir", "--now": "now"}
    index = 0
    while index < len(argv):
        arg = argv[index]
        if arg in ("-h", "--help", "help"):
            sys.stdout.write(_USAGE)
            return 0
        if arg in flags:
            opts[flags[arg]] = False
        elif arg == "--blocking":
            opts["blocking"] = True
        elif arg == "--explain":
            opts["explain"] = True
        elif arg == "--refresh":
            opts["refresh"] = True
        elif arg in values:
            if index + 1 >= len(argv):
                sys.stderr.write("repo-roster: %s needs a value\n" % arg)
                return 2
            opts[values[arg]] = argv[index + 1]
            index += 1
        else:
            sys.stderr.write("repo-roster: unknown option: %s\n" % arg)
            return 2
        index += 1

    repo = opts["repo"] or _git_toplevel(os.getcwd())
    now = _float_or_none(opts["now"]) or _float_or_none(os.environ.get("HMD_ROSTER_NOW"))
    git_days = _float_or_none(opts["git_days"])
    cache_dir = opts["cache_dir"] or os.environ.get("HMD_ROSTER_CACHE_DIR")

    if opts["refresh"]:
        result = refresh(repo, git_days=git_days, cache_dir=cache_dir, now=now)
        sys.stdout.write(json.dumps(result, indent=2, sort_keys=True) + "\n")
        return 0

    kwargs = {"now": now, "git_days": git_days, "presence_cache": opts["presence_cache"],
              "cache_dir": cache_dir, "blocking": opts["blocking"],
              "use_presence": opts["use_presence"], "use_git": opts["use_git"],
              "use_github": opts["use_github"]}
    payload = explain(repo, **kwargs) if opts["explain"] else build(repo, **kwargs)
    sys.stdout.write(json.dumps(payload, indent=2, sort_keys=True) + "\n")
    return 0


def _float_or_none(value):
    if value in (None, ""):
        return None
    try:
        return float(value)
    except (TypeError, ValueError):
        return None


if __name__ == "__main__":
    sys.exit(_cli(sys.argv[1:]))
