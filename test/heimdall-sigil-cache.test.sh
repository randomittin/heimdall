#!/usr/bin/env bash
#
# heimdall-sigil-cache.test.sh — CONTENT-HASHED SIGIL CACHE INVALIDATION.
#
# BUG: the on-disk sigil cache key (seed__size__color-unicode__eye) had NO content
# hash, so a sigil code/grid change served the STALE cached sigil forever ("my sigil
# never updated"). FIX: fold a short content hash of hmd_sigil.py's source
# (_SIG_VERSION) into the cache key + filename → any code change mints a fresh key
# and the stale sigil is never served again, with no manual cache clear.
#
# THIS SUITE LOCKS:
#   1. SAME content → cache HIT: a second render (fresh process, cold memo) serves the
#      STORED bytes — proven by corrupting the .sig on disk and getting the corruption
#      back (it read the cache, did not recompute).
#   2. CHANGED content (bumped _SIG_VERSION) → cache MISS: the corrupted .sig is
#      IGNORED (different key) and the sigil is recomputed to the correct render.
#   3. The version hash is present in the cache filename.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
SL="$ROOT/sentinels/hmd-statusline.py"

# A skip must never look like a pass: exit 0 with no roll-up line is exactly how a
# vacuous gate hides. Report the skip LOUDLY and as a zero-assertion row.
command -v python3 >/dev/null 2>&1 || {
  echo "SKIP: python3 unavailable"
  echo "RESULT: SKIPPED (0 assertions ran — this is NOT a pass)"
  echo "heimdall-sigil-cache: 0 passed, 0 failed (SKIPPED — python3 unavailable)"
  exit 0
}
[ -f "$SL" ] || { echo "FATAL: statusline missing at $SL"; exit 2; }

SL="$SL" python3 - <<'PY'
import importlib.util, os, glob, sys, tempfile, io, contextlib
SL = os.environ["SL"]

def load():
    # a clean import each time = a COLD in-process memo, so only the DISK cache carries
    # across "processes" (the real per-refresh spawn condition).
    spec = importlib.util.spec_from_file_location("sl_%d" % load.n, SL)
    load.n += 1
    m = importlib.util.module_from_spec(spec)
    with contextlib.redirect_stdout(io.StringIO()):
        spec.loader.exec_module(m)
    return m
load.n = 0

home = tempfile.mkdtemp()
os.environ["HOME"] = home

fail = 0
passed = 0
def ok(t):
    global passed; passed += 1; print("  ok   " + t)
def bad(t):
    global fail; fail += 1; print("  FAIL " + t)

m = load()
CACHE = m._sigil_cache_dir()
VER = m._SIG_VERSION

# 1) first render → writes the cache file, keyed by the version hash.
r1 = m.cached_sigil("rj", "M", m.CAPS, None)
files = glob.glob(os.path.join(CACHE, "*.sig"))
if len(files) == 1 and VER in os.path.basename(files[0]):
    ok("first render wrote a cache file keyed by version %s" % VER)
else:
    bad("expected one .sig keyed by the version hash, got %r" % [os.path.basename(f) for f in files])
    print("%d failed" % (fail or 1))
    print("heimdall-sigil-cache: %d passed, %d failed" % (passed, fail))
    sys.exit(1)
CFILE = files[0]

# corrupt the stored sigil with a recognizable sentinel.
SENTINEL = ["SENT_R0", "SENT_R1", "SENT_R2", "SENT_R3"]
open(CFILE, "w", encoding="utf-8").write("\n".join(SENTINEL))

# 2) SAME content → HIT: a fresh module (cold memo) must serve the sentinel from disk.
m2 = load()
r2 = m2.cached_sigil("rj", "M", m2.CAPS, None)
if r2 == SENTINEL:
    ok("same content → cache HIT (served the stored bytes, did not recompute)")
else:
    bad("same content did NOT hit the disk cache (recomputed instead of serving stored)")

# 3) CHANGED content → MISS: bump the version hash (simulating a sigil code change).
#    The sentinel file must be IGNORED (different key) and the sigil recomputed.
m3 = load()
m3._SIG_VERSION = "deadbeefcafe"
r3 = m3.cached_sigil("rj", "M", m3.CAPS, None)
if r3 == SENTINEL:
    bad("version bump still served the STALE sentinel (cache did not invalidate)")
elif r3 == r1:
    ok("changed content → cache MISS → recomputed to the correct sigil (auto-invalidation)")
else:
    bad("version bump recomputed but produced unexpected bytes")

# and the new version minted a NEW cache file alongside the old.
files2 = glob.glob(os.path.join(CACHE, "*.sig"))
if any("deadbeefcafe" in os.path.basename(f) for f in files2):
    ok("the bumped version wrote a fresh cache file (new key, old one untouched)")
else:
    bad("the bumped version did not write a distinct cache file")

print()
print("%s" % ("all passed" if fail == 0 else ("%d failed" % fail)))
print("heimdall-sigil-cache: %d passed, %d failed" % (passed, fail))
sys.exit(1 if fail else 0)
PY
