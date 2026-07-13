#!/usr/bin/env bash
# heimdall-statusline-identity-flip.test.sh
#
# REGRESSION: the MAIN (left-anchor) hero sigil must resolve the SAME pinned hero as
# the TEAM-SELF sigil for the same user — deterministically, every refresh, no flip.
#
# The bug (RJ screenshot): identity() forks `heimdall-identity` with a 1.0s timeout;
# on a timeout/failure it fell back to $USER (a bare handle like `rj`), which is NOT a
# real HAID → misses the batsy CUSTOM_SIGILS pin → renders the `rj`->dog TEAL animal
# blob. The 5s identity cache (perf commit) then FROZE that wrong fallback for 5s,
# turning a transient fork failure into a sticky 5-second flip. The team-self sigil
# never diverged because it reads the real HAID straight from the ledger/roster.
#
# These invariants pin the fix: a FAILED identity fork must NEVER regress the MAIN
# sigil to the $USER animal — it reuses the last-known-good HAID (== team-self) and
# never poisons the cache — while the warm no-fork perf path is preserved.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
SL="$ROOT/sentinels/hmd-statusline.py"

command -v python3 >/dev/null 2>&1 || { echo "SKIP: python3 unavailable"; exit 0; }
[ -f "$SL" ] || { echo "FATAL: statusline missing at $SL"; exit 2; }

ROOT="$ROOT" SL="$SL" python3 - <<'PY'
import os, sys, time, tempfile, importlib.util

SL   = os.environ["SL"]
ROOT = os.environ["ROOT"]

_p = 0; _f = 0
def ok(m):
    global _p; _p += 1; print("  ok   " + m)
def bad(m):
    global _f; _f += 1; print("  FAIL " + m)

def load(path, name):
    spec = importlib.util.spec_from_file_location(name, path)
    m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
    return m

sl = load(SL, "hmd_statusline_flip")
SIG = sl.SIG

HAID = "haid:rj.rishabhs-macbook-air-46d5"   # RJ's real HAID (batsy pin key)
HANDLE = "rj"                                 # bare $USER handle (pin MISS -> dog animal)

def heroname(seed):
    """The hero NAME a seed renders as: an explicit pin / hero-name / real-HAID hero,
    else the ANIMAL: fallback (the teal/green blob path for non-HAID seeds)."""
    spec = SIG._resolve_custom_spec(seed)
    if spec:
        return spec.get("name")
    import hashlib
    idx = hashlib.sha256(seed.encode()).digest()[0] % len(SIG.ANIMAL_ORDER)
    return "ANIMAL:" + SIG.ANIMAL_ORDER[idx]

# Ground-truth the fixtures the whole test leans on.
assert heroname(HAID) == "batsy", heroname(HAID)
assert heroname(HANDLE).startswith("ANIMAL:"), heroname(HANDLE)
TEAM_SELF_HERO = heroname(HAID)   # the team rail passes the real HAID -> this hero

# -- controllable stand-in `heimdall-identity` bins --------------------------
BINROOT = tempfile.mkdtemp(prefix="hmd-flip-bin-")
def _mkbin(name, body):
    d = os.path.join(BINROOT, name); os.makedirs(d, exist_ok=True)
    p = os.path.join(d, "heimdall-identity")
    with open(p, "w") as f: f.write(body)
    os.chmod(p, 0o755)
    return d

HEALTHY = _mkbin("healthy",
    '#!/bin/sh\nprintf \'{"handle":"rj","seed":"%s"}\'\n' % HAID)
# a FAILED fork: empty stdout, nonzero exit (stands in for timeout/error/jq-missing).
FAILING = _mkbin("failing", '#!/bin/sh\nexit 1\n')
# a TRIPWIRE bin: proves whether the fork ran at all (touches a marker, then healthy).
TRIP_MARK = os.path.join(BINROOT, "tripwire.mark")
TRIPWIRE = _mkbin("tripwire",
    '#!/bin/sh\ntouch %s\nprintf \'{"handle":"rj","seed":"%s"}\'\n' % (TRIP_MARK, HAID))

TMP = tempfile.mkdtemp(prefix="hmd-flip-tmp-")
os.environ["HMD_STATUSLINE_TMP"] = TMP
# strip a live sigil override so _sigil_override_seed is a passthrough in this harness.
os.environ["HEIMDALL_HOME"] = tempfile.mkdtemp(prefix="hmd-flip-home-")

def cache_path(sid):
    return sl._identity_cache_path(sid)
def age_cache(sid, seconds):
    """Backdate the session cache file so the next identity() call sees it STALE (the
    >TTL re-fork path — exactly where a failing fork used to poison the render)."""
    p = cache_path(sid)
    old = time.time() - seconds
    os.utime(p, (old, old))
def fresh_cache(sid):
    return os.path.exists(cache_path(sid)) and \
           (time.time() - os.path.getmtime(cache_path(sid))) <= sl.IDENTITY_TTL

orig_bindir = sl.BIN_DIR

# -- 1) HEALTHY fork -> MAIN seed is the real HAID -> batsy (== team-self) --
sl.BIN_DIR = HEALTHY
sid = "flip-healthy"
seed, handle = sl.identity(ROOT, HANDLE, sid)
(ok if seed == HAID else bad)("healthy fork: MAIN seed is the real HAID (%r)" % seed)
(ok if heroname(seed) == "batsy" else bad)("healthy fork: MAIN hero == batsy (got %r)" % heroname(seed))
(ok if heroname(seed) == TEAM_SELF_HERO else bad)(
    "healthy fork: MAIN hero == TEAM-SELF hero (%r == %r)" % (heroname(seed), TEAM_SELF_HERO))

# -- 2) STALE cache + FAILING fork -> reuse last-known-good HAID, NOT $USER animal --
# This is THE flip: the cache went stale (>5s), the re-fork fails, and the render must
# NOT regress to `rj`->dog. It must reuse the last-known-good HAID -> batsy.
age_cache(sid, sl.IDENTITY_TTL + 2.0)     # force the >TTL re-fork path
sl.BIN_DIR = FAILING
seed2, handle2 = sl.identity(ROOT, HANDLE, sid)
(ok if seed2 == HAID else bad)(
    "failed fork after good: reuses last-known-good HAID, not $USER (got %r)" % seed2)
(ok if heroname(seed2) == "batsy" else bad)(
    "failed fork after good: MAIN hero stays batsy — NO teal-animal flip (got %r)" % heroname(seed2))
(ok if heroname(seed2) == TEAM_SELF_HERO else bad)(
    "failed fork after good: MAIN hero == TEAM-SELF hero (no divergence)")

# -- 3) FAILING fork on a COLD session must NOT poison the 5s cache --
# A first-ever render with a broken fork may transiently show $USER, but it must NOT be
# frozen for 5s — the next (recovered) fork has to win immediately. So a FAILED cold
# resolution writes NO cache entry.
sl.BIN_DIR = FAILING
cold_sid = "flip-cold-broken"
if os.path.exists(cache_path(cold_sid)): os.remove(cache_path(cold_sid))
seed3, handle3 = sl.identity(ROOT, HANDLE, cold_sid)
(ok if not os.path.exists(cache_path(cold_sid)) else bad)(
    "cold broken fork: writes NO cache entry (never freezes $USER for 5s)")
# and it self-heals: the very next render with a healthy fork resolves batsy.
sl.BIN_DIR = HEALTHY
seed3b, _ = sl.identity(ROOT, HANDLE, cold_sid)
(ok if heroname(seed3b) == "batsy" else bad)(
    "cold broken fork self-heals: next healthy render is batsy (got %r)" % heroname(seed3b))

# -- 4) PERF preserved: a FRESH cache hit does ZERO forks --
sl.BIN_DIR = HEALTHY
warm_sid = "flip-warm"
if os.path.exists(cache_path(warm_sid)): os.remove(cache_path(warm_sid))
sl.identity(ROOT, HANDLE, warm_sid)          # cold miss -> forks + caches
assert fresh_cache(warm_sid)
if os.path.exists(TRIP_MARK): os.remove(TRIP_MARK)
sl.BIN_DIR = TRIPWIRE                          # would touch TRIP_MARK if forked
wseed, _ = sl.identity(ROOT, HANDLE, warm_sid)
(ok if not os.path.exists(TRIP_MARK) else bad)(
    "warm hit: NO identity fork (perf cache preserved)")
(ok if heroname(wseed) == "batsy" else bad)(
    "warm hit: still resolves batsy (got %r)" % heroname(wseed))

sl.BIN_DIR = orig_bindir
print("\n%d passed, %d failed" % (_p, _f))
sys.exit(1 if _f else 0)
PY
