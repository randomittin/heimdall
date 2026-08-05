#!/usr/bin/env python3
# dream_data — WHERE THE NIGHTLY DREAM KEEPS ITS STATE, AND WHY IT IS NOT IN THE REPO.
#
# THE DENIAL THIS ROUTES AROUND.
#   macOS TCC refuses a LaunchAgent every read under ~/Downloads, ~/Documents and
#   ~/Desktop. It refuses the JOB, not the program: measured in 245ede5, a probe agent
#   whose program sat OUTSIDE the protected tree still recorded LIST_REPO_DIR=DENIED
#   while WRITE_DOTHEIMDALL=OK. So relocating the binary alone fixes nothing — the job
#   dies READING the repo, wherever its program lives. The two remedies that do work,
#   moving the checkout and granting Full Disk Access, were both ruled out by the owner.
#
#   The third way is to stop needing the repo at all. dream's appetite for it is tiny
#   and was audited rather than assumed: it reads NO source, NO tests and NO git
#   history. Its entire state is four .planning files (metrics.jsonl, queue-stats.json,
#   routing-overrides.json, experiments.jsonl) plus the report it writes. Relocate those
#   under $HEIMDALL_HOME — not TCC-guarded, and measured writable from launchd — and the
#   03:00 job touches nothing under ~/Downloads, needs no grant and needs no move.
#
# NAMESPACED PER REPO, BECAUSE METRICS ARE PROJECT-SCOPED.
#   One flat file under ~/.heimdall would blend every checkout's routing evidence into a
#   single corpus, and the pass-rate deltas the keep-gate grades would be computed across
#   projects that share nothing. That is not a smaller corpus, it is a WRONG one — it
#   would produce confident verdicts from mixed evidence, which is the exact failure the
#   sample-size floor exists to prevent. So each repo gets its own root, keyed by
#
#       <slug of the repo's basename>-<first 12 hex of sha256 of its physical path>
#
#   The basename keeps the directory legible to a human browsing ~/.heimdall/data; the
#   path hash is what actually makes it unique, so two checkouts both named "heimdall"
#   cannot collide. The key is derived, never stored, so it survives a reinstall — and
#   because a hash is one-way, ensure_root() also drops a `repo` marker file naming the
#   checkout, so a human can read the mapping without reversing anything.
#
#   The SAME derivation is implemented in bin/lib/dream-data.sh for the bash callers.
#   Two languages resolving one path is only safe if a test pins them together, and
#   test/dream-data-root.test.sh does exactly that.
#
# MIGRATION, NOT ABANDONMENT.
#   A relocation that started from an empty corpus would make dream report "no evidence
#   yet" on a machine that has been accumulating records for weeks — it would go quiet
#   for entirely the wrong reason, and look exactly like the silent failure this whole
#   effort exists to end. So seed_from_repo() carries the existing .planning state over
#   on first use, and does it ONLY when the destination is absent, so it can never
#   double-count on a later run.
#
# Usage (the CLI exists for the bash callers and for tests):
#   dream_data.py key      --repo DIR    # the namespacing key
#   dream_data.py root     --repo DIR    # $HEIMDALL_HOME/data/<key>
#   dream_data.py planning --repo DIR    # <root>/planning — dream's state dir
#   dream_data.py ensure   --repo DIR    # create the root, write the marker, seed once

import hashlib
import os
import sys

# The state files dream and heimdall-self-improve actually touch. This list is the
# audited surface, not a guess: anything not named here is something dream never opens.
STATE_FILES = (
    "metrics.jsonl",
    "queue-stats.json",
    "routing-overrides.json",
    "experiments.jsonl",
)

KEY_SLUG_MAX = 24
KEY_HASH_LEN = 12


def heimdall_home():
    return os.environ.get("HEIMDALL_HOME") or os.path.join(
        os.path.expanduser("~"), ".heimdall")


def _physical(repo):
    """The path both languages hash. realpath resolves symlinks so two names for one
    checkout key the same, which is what stops a /tmp -> /private/tmp alias from
    silently forking one repo's evidence into two corpora."""
    return os.path.realpath(os.path.abspath(repo))


def _slug(value):
    """Lowercase; every run of non [a-z0-9] becomes one '-'; trim; cap.

    Deliberately simpler than the emitter's slug (which keeps '_'): this half of the key
    is decoration for human eyes, the hash carries the uniqueness. A simple rule is one
    the shell twin can reproduce exactly with a single sed, and exactness is the only
    property that matters when two languages must agree on a path."""
    out = []
    prev_dash = False
    for ch in str(value).lower():
        if ("a" <= ch <= "z") or ("0" <= ch <= "9"):
            out.append(ch)
            prev_dash = False
        elif not prev_dash:
            out.append("-")
            prev_dash = True
    return "".join(out).strip("-")[:KEY_SLUG_MAX].strip("-")


def repo_key(repo):
    phys = _physical(repo)
    digest = hashlib.sha256(phys.encode("utf-8")).hexdigest()[:KEY_HASH_LEN]
    slug = _slug(os.path.basename(phys.rstrip(os.sep)))
    return "%s-%s" % (slug, digest) if slug else digest


def data_root(repo):
    """$HEIMDALL_DREAM_DATA_DIR wins outright — it is the seam tests redirect so a run
    can never reach the operator's real ~/.heimdall. Four machine-scoped escapes were
    found in one day on this system; a relocation that added a fifth would be a poor
    trade for the one it fixes."""
    override = os.environ.get("HEIMDALL_DREAM_DATA_DIR")
    if override:
        return os.path.abspath(override)
    return os.path.join(heimdall_home(), "data", repo_key(repo))


def planning_dir(repo):
    """Dream's state dir. Named 'planning' because it holds exactly what <repo>/.planning
    held for this loop — the same filenames, the same formats, just reachable at 03:00."""
    return os.path.join(data_root(repo), "planning")


def repo_planning_dir(repo):
    return os.path.join(os.path.abspath(repo), ".planning")


def _readable_file(path):
    try:
        return os.path.isfile(path) and os.access(path, os.R_OK)
    except OSError:
        return False


def writable_dir(path):
    """Is this directory usable for a write RIGHT NOW? Answered by asking the OS, not by
    inspecting mode bits, because TCC denies a job that the mode bits say may proceed."""
    try:
        return os.path.isdir(path) and os.access(path, os.W_OK | os.X_OK)
    except OSError:
        return False


def seed_from_repo(repo, dest=None):
    """Carry pre-existing .planning state into the relocated root. Returns the list of
    filenames actually seeded.

    ONLY WHEN THE DESTINATION IS ABSENT. That single condition is what makes this safe to
    call on every run: once a file has been relocated the repo copy is never consulted
    again, so a nightly append can never be undone by a later seed, and re-running can
    never double a record. It also means the repo copy is a starting point, not a master
    — after the move the relocated root is the one dream reads.

    Every step is best-effort. The repo may be unreadable (that is the whole reason this
    module exists), in which case there is nothing to carry and the seed is a no-op."""
    if dest is None:
        dest = planning_dir(repo)
    src_dir = repo_planning_dir(repo)
    seeded = []
    for name in STATE_FILES:
        src = os.path.join(src_dir, name)
        dst = os.path.join(dest, name)
        if os.path.exists(dst) or not _readable_file(src):
            continue
        try:
            with open(src, "rb") as fh:
                blob = fh.read()
        except OSError:
            continue
        try:
            tmp = dst + ".seed.tmp"
            with open(tmp, "wb") as fh:
                fh.write(blob)
            os.replace(tmp, dst)
            seeded.append(name)
        except OSError:
            continue
    return seeded


def _write_marker(root, phys):
    """Turn the one-way hash back into something a human can read: name the checkout this
    directory belongs to. Rewritten only when the content would change, so browsing
    ~/.heimdall/data never churns mtimes. Returns whether the marker is now correct — a
    missing marker costs legibility, never correctness, so a failure is reported to the
    caller rather than raised at it."""
    marker = os.path.join(root, "repo")
    try:
        if os.path.isfile(marker):
            with open(marker, "r", encoding="utf-8") as fh:
                if fh.read().strip() == phys:
                    return True
        with open(marker, "w", encoding="utf-8") as fh:
            fh.write(phys + "\n")
        return True
    except OSError:
        return False


def ensure_root(repo, seed=True):
    """Create the relocated root, record which repo it belongs to, and seed it once.

    Returns the planning dir, or None when it cannot be created — the caller then falls
    back to the repo, which is exactly today's behaviour and never worse than it."""
    dest = planning_dir(repo)
    try:
        os.makedirs(dest, exist_ok=True)
    except OSError:
        return None
    _write_marker(data_root(repo), _physical(repo))
    if seed:
        seed_from_repo(repo, dest)
    return dest


def resolve_planning(repo, seed=True):
    """THE ONE ENTRY POINT the bins call. The relocated root when it can be had, else
    the repo's own .planning.

    The fallback is not a consolation prize: on a machine where nothing is protected
    (Linux, CI, a repo outside the gated folders) it is the correct answer, and it keeps
    this module from being able to make anything WORSE than it was. It is also what runs
    if $HEIMDALL_HOME itself is unwritable."""
    dest = ensure_root(repo, seed=seed)
    if dest and writable_dir(dest):
        return dest
    return repo_planning_dir(repo)


def _main(argv):
    usage = "usage: dream_data.py key|root|planning|ensure --repo DIR\n"
    if len(argv) < 1:
        sys.stderr.write(usage)
        return 2
    cmd = argv[0]
    repo = "."
    rest = argv[1:]
    i = 0
    while i < len(rest):
        if rest[i] == "--repo" and i + 1 < len(rest):
            repo = rest[i + 1]
            i += 2
            continue
        i += 1
    repo = os.path.abspath(repo)

    if cmd == "key":
        print(repo_key(repo))
    elif cmd == "root":
        print(data_root(repo))
    elif cmd == "planning":
        print(planning_dir(repo))
    elif cmd == "ensure":
        dest = ensure_root(repo)
        if dest is None:
            sys.stderr.write("error: cannot create the data root for %s\n" % repo)
            return 3
        print(dest)
    else:
        sys.stderr.write(usage)
        return 2
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(_main(sys.argv[1:]))
    except BrokenPipeError:
        raise SystemExit(0)
