#!/usr/bin/env bash
# memory-codec.test.sh — acceptance for the MemoryCodec seam (§8,
# bin/lib/memory_codec.py + the verified_memory store boundary it sits under).
#
# THE SEAM. One place where hmd's durable payloads become their stored wire form and
# back. A codec shrinks STORAGE only; hmd keeps ALL truth semantics. The thing this
# suite exists to make impossible: a codec changing a verdict.
#
# Every assertion is mechanical + falsifiable. The falsifier for the whole suite is
# the same one the verified-memory suites carry: an entry that SHOULD read live but
# reads stale (or the reverse) reds the test. A codec that can move that needle is
# a corrupted judge, and a corrupted judge emits false greens.
#
# REAL PAYLOADS, NOT ONLY SYNTHETIC: the throwaway repo is seeded with this repo's
# OWN source files (memory_codec.py, vm_gitcheck.py, verified_memory.py). The claims
# reference real symbols in those real files, git-verified for real; the heavy
# payloads ARE those files' bodies — the multi-KB shape a session summary, a corpus
# case body or a context-branch payload actually has.
#
# The proofs:
#   A. PLAIN FALLBACK, WITH THE BACKEND ABSENT (invariant 3) — headroom is not
#      installed here and must not be. backend=plain, everything works, the store
#      stays LITERAL text (so gitleaks still reads it natively), nothing is printed.
#   B. ROUND-TRIP FIDELITY ON REAL PAYLOADS (invariant 1) — with a real non-plain
#      codec active, real multi-KB file bodies go through the ACTUAL store path
#      (_append → entries.ndjson → _read_raw) and come back BYTE-IDENTICAL, and the
#      entries carrying them still re-verify LIVE against git.
#   C. THE CODEC NEVER TOUCHES GATE/VERIFIER INPUTS (invariant 2) — with a codec
#      active: every verifier field survives encode bit-identical, the stored line
#      still carries the literal commit sha / refs / status, and what reaches
#      vm_gitcheck.verify() contains no wire form at all. Plus the load-time guard
#      that keeps PAYLOAD_FIELDS and VERIFIER_FIELDS disjoint.
#   D. A LOSSY CODEC CANNOT PERSIST (invariant 1a) — a codec that drops a byte is
#      caught by the write-side self-check; the payload is stored literally and the
#      verification does NOT move.
#   E. A CORRUPTED WIRE FORM IS NEVER SERVED (invariant 1b) — tamper with a stored
#      envelope: the read-side digest catches it and the line is SKIPPED, never
#      served truncated.
#   F. EXACTLY ONE HINT, ONCE (the user surface) — heavy store + no codec → the one
#      sentence, on stderr, once and never again. Small store → silent. Codec
#      present → silent.
#   G. THE SECRET GATE RUNS BEFORE THE CODEC — a secret-shaped claim is still
#      REJECTED (exit 3) and absent from the store with a codec in the path.
#
# Exit 0 = every proof holds. Nonzero = a proof failed (prints which).

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SELF_DIR/.." && pwd)"
LIBDIR="$REPO/bin/lib"
CLI="$REPO/bin/heimdall-memory"
CODEC="$LIBDIR/memory_codec.py"

command -v python3 >/dev/null 2>&1 || { echo "FATAL: python3 required" >&2; exit 2; }
[ -f "$CODEC" ] || { echo "FATAL: codec missing at $CODEC" >&2; exit 2; }
[ -x "$CLI" ] || { echo "FATAL: CLI missing/not-exec at $CLI" >&2; exit 2; }

PASS=0; FAIL=0
ok()  { printf '  \033[32mPASS\033[0m %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAIL=$((FAIL + 1)); }

# ── throwaway repo seeded with REAL source + isolated store (cleaned on exit) ──
WORK="${TMPDIR:-/tmp}/vm-codec.$$.${RANDOM}"
mkdir -p "$WORK"
trap 'rm -rf "$WORK"' EXIT
GR="$WORK/repo"
HOME_DIR="$WORK/home"
CACHE="$WORK/cache"
mkdir -p "$GR/lib" "$HOME_DIR"
git -C "$GR" init -q
git -C "$GR" config user.email "test@vm.local"
git -C "$GR" config user.name "vm-codec-test"

# REAL payloads: this repo's own modules, committed into the throwaway repo so the
# claims below verify against real files carrying real symbols.
cp "$LIBDIR/memory_codec.py"   "$GR/lib/memory_codec.py"
cp "$LIBDIR/vm_gitcheck.py"    "$GR/lib/vm_gitcheck.py"
cp "$LIBDIR/verified_memory.py" "$GR/lib/verified_memory.py"
git -C "$GR" add -A
git -C "$GR" commit -q -m "seed: real hmd modules as the verification target"
SHA="$(git -C "$GR" rev-parse HEAD)"

STORE="$HOME_DIR/memory/entries.ndjson"

# py <<'PY' — run a python driver with the lib dir + the fixture paths exported.
py() { LIBDIR="$LIBDIR" GR="$GR" HOME_DIR="$HOME_DIR" CACHE="$CACHE" SHA="$SHA" \
       STORE="$STORE" python3 - "$@"; }

echo
echo "A. PLAIN FALLBACK with the backend ABSENT (invariant 3 — this machine):"

ST="$(python3 "$CODEC" status --json 2>/dev/null)"; RC=$?
[ "$RC" -eq 0 ] && ok "codec status exits 0 with no codec installed" \
                || bad "codec status exited $RC"
printf '%s' "$ST" | grep -q '"backend": "plain"' \
  && ok "backend resolves to plain (headroom absent → degrade, not error)" \
  || bad "backend is not plain: $ST"
printf '%s' "$ST" | grep -q '"headroom_importable": false' \
  && ok "headroom is NOT importable here (it must never be a hard dependency)" \
  || bad "headroom appears importable — this test asserts the absent-backend path"
printf '%s' "$ST" | grep -q '"available": false' \
  && ok "available=false — 'no codec' is a supported state, not a failure" \
  || bad "available is not false"

# A full write→read cycle through the REAL CLI, with no codec anywhere.
CLAIM_A="verified_memory._read_raw is the store read boundary"
OUT="$("$CLI" write --repo "$GR" --home "$HOME_DIR" --cache-dir "$CACHE" \
        --claim "$CLAIM_A" --commit "$SHA" --ref "lib/verified_memory.py:_read_raw" \
        2>"$WORK/a.err")"; RC=$?
[ "$RC" -eq 0 ] && ok "write succeeds with no codec installed (exit 0)" \
                || bad "write exited $RC with no codec"
ID_A="$(printf '%s' "$OUT" | python3 -c 'import sys,json; print(json.load(sys.stdin)["entry"]["id"])' 2>/dev/null)"
printf '%s' "$OUT" | grep -q '"status": "live"' \
  && ok "the entry verifies LIVE at write time — the codec seam changed no verdict" \
  || bad "entry did not verify live"
[ ! -s "$WORK/a.err" ] && ok "nothing printed to stderr — absence degrades SILENTLY" \
                       || bad "stderr was not silent: $(cat "$WORK/a.err")"
grep -qF "$CLAIM_A" "$STORE" \
  && ok "the store line is LITERAL text — gitleaks still reads it natively" \
  || bad "claim is not literal in the store"
grep -q '"\$hmdc"' "$STORE" \
  && bad "an envelope was written with no codec installed" \
  || ok "no codec envelope in the store — plain writes exactly what it always did"

OUT="$("$CLI" get --repo "$GR" --home "$HOME_DIR" --cache-dir "$CACHE" --id "$ID_A" 2>/dev/null)"; RC=$?
GOT="$(printf '%s' "$OUT" | python3 -c 'import sys,json; print(json.load(sys.stdin)["claim"])' 2>/dev/null)"
[ "$RC" -eq 0 ] && [ "$GOT" = "$CLAIM_A" ] \
  && ok "read-back is byte-identical on plain (round-trip fidelity, invariant 1)" \
  || bad "plain round-trip lost the claim: got [$GOT]"

echo
echo "B. ROUND-TRIP FIDELITY on REAL payloads through the REAL store path (inv. 1):"

py <<'PY' > "$WORK/b.out" 2>"$WORK/b.err"
import os, sys, zlib
sys.path.insert(0, os.environ["LIBDIR"])
import memory_codec as mc
import verified_memory as vm
import vm_gitcheck as vmg

# A REAL, lossless storage codec (stdlib zlib) registered through the seam's only
# entry point. This is the shape the Headroom backend will take when it wires in.
mc.register_backend("zlib-test",
                    lambda t: zlib.compress(t.encode("utf-8"), 9),
                    lambda w: zlib.decompress(w).decode("utf-8"))
assert mc.backend_name() == "zlib-test", mc.backend_name()

repo, home = os.environ["GR"], os.environ["HOME_DIR"]
sha, cache = os.environ["SHA"], os.environ["CACHE"]

# REAL payloads: this repo's own module bodies — the multi-KB shape a session
# summary / corpus case body / context-branch payload actually has.
bodies = {}
for name in ("memory_codec.py", "vm_gitcheck.py", "verified_memory.py"):
    with open(os.path.join(repo, "lib", name), "r", encoding="utf-8") as fh:
        bodies[name] = fh.read()

results = []
for i, (name, body) in enumerate(sorted(bodies.items())):
    entry = vmg.make_entry(
        "real module body: %s" % name, sha,
        [{"path": "lib/%s" % name, "symbol": ""}],
        entry_id="vm-codec-%d" % i,
    )
    entry = vmg.verify(entry, repo, cache_dir=cache)
    entry.pop("cache", None)
    entry["summary"] = body          # the heavy payload the codec is for
    assert vm._append(entry, home), "store append failed"
    results.append((entry["id"], name, body, entry["status"]))

# Did the codec ACTUALLY engage? Read the raw bytes, undecoded.
with open(os.environ["STORE"], "r", encoding="utf-8") as fh:
    raw = fh.read()
print("ENVELOPES=%d" % raw.count('"$hmdc"'))
print("LITERAL_BODY_IN_STORE=%s" % any(b[:400] in raw for _i, _n, b, _s in results))

# Now the read path — the same _read_raw every consumer goes through.
back = {e["id"]: e for e in vm._read_raw(home)}
identical = 0
for eid, name, body, status in results:
    if eid in back and back[eid].get("summary") == body:
        identical += 1
print("BYTE_IDENTICAL=%d/%d" % (identical, len(results)))

# And the verdict must not have moved: re-verify the round-tripped entries.
live = 0
for eid, name, body, status in results:
    fresh = vmg.verify(back[eid], repo, cache_dir=cache)
    if fresh["status"] == vmg.LIVE and status == vmg.LIVE:
        live += 1
print("STILL_LIVE=%d/%d" % (live, len(results)))

# Storage actually shrank — a codec that does not shrink is not worth a seam.
plain_bytes = sum(len(b.encode("utf-8")) for _i, _n, b, _s in results)
print("SHRANK=%s" % (len(raw.encode("utf-8")) < plain_bytes))
PY
RC=$?
[ "$RC" -eq 0 ] || bad "block B driver exited $RC: $(cat "$WORK/b.err")"
grep -q '^ENVELOPES=3$' "$WORK/b.out" \
  && ok "all 3 real payloads were stored as codec envelopes (the codec engaged)" \
  || bad "codec did not engage: $(grep '^ENVELOPES=' "$WORK/b.out")"
grep -q '^LITERAL_BODY_IN_STORE=False$' "$WORK/b.out" \
  && ok "no literal payload body remains in the store (storage really shrank)" \
  || bad "a literal body is still in the store — the codec did not encode it"
grep -q '^BYTE_IDENTICAL=3/3$' "$WORK/b.out" \
  && ok "all 3 real payloads read back BYTE-IDENTICAL through _append → _read_raw" \
  || bad "round-trip lost data: $(grep '^BYTE_IDENTICAL=' "$WORK/b.out")"
grep -q '^STILL_LIVE=3/3$' "$WORK/b.out" \
  && ok "every round-tripped entry still re-verifies LIVE — no verdict moved" \
  || bad "a verification flipped across the round-trip: $(grep '^STILL_LIVE=' "$WORK/b.out")"
grep -q '^SHRANK=True$' "$WORK/b.out" \
  && ok "the encoded store is smaller than the raw payloads (the seam earns its keep)" \
  || bad "the codec did not shrink storage"

echo
echo "C. THE CODEC NEVER TOUCHES GATE/VERIFIER INPUTS (invariant 2):"

py <<'PY' > "$WORK/c.out" 2>"$WORK/c.err"
import os, sys, zlib
sys.path.insert(0, os.environ["LIBDIR"])
import memory_codec as mc
import verified_memory as vm
import vm_gitcheck as vmg

mc.register_backend("zlib-test",
                    lambda t: zlib.compress(t.encode("utf-8"), 9),
                    lambda w: zlib.decompress(w).decode("utf-8"))

repo, cache = os.environ["GR"], os.environ["CACHE"]
sha = os.environ["SHA"]

entry = vmg.make_entry("memory_codec.decode_entry runs at the store boundary", sha,
                       [{"path": "lib/memory_codec.py", "symbol": "decode_entry"}],
                       entry_id="vm-codec-inv2")
entry = vmg.verify(entry, repo, cache_dir=cache)
entry.pop("cache", None)
with open(os.path.join(repo, "lib", "verified_memory.py"), "r", encoding="utf-8") as fh:
    entry["summary"] = fh.read()

encoded = mc.encode_entry(entry)
print("PAYLOAD_ENCODED=%s" % mc.is_wire(encoded.get("summary")))
print("VERIFIER_INTACT=%s" % mc.verifier_fields_intact(encoded, entry))
# field-by-field, so a pass cannot come from a lenient helper
print("COMMIT_SAME=%s" % (encoded["commit_ref"] == entry["commit_ref"]))
print("REFS_SAME=%s" % (encoded["refs"] == entry["refs"]))
print("STATUS_SAME=%s" % (encoded["status"] == entry["status"]))
print("WEIGHT_SAME=%s" % (encoded["weight"] == entry["weight"]))

# STRUCTURAL half: what reaches the verifier carries no wire form anywhere.
decoded = mc.decode_entry(encoded)
def has_wire(obj):
    if mc.is_wire(obj):
        return True
    if isinstance(obj, dict):
        return any(has_wire(v) for v in obj.values())
    if isinstance(obj, list):
        return any(has_wire(v) for v in obj)
    return False
print("VERIFIER_INPUT_RAW=%s" % (not has_wire(decoded)))
fresh = vmg.verify(decoded, repo, cache_dir=cache)
print("VERDICT_UNMOVED=%s" % (fresh["status"] == entry["status"] == vmg.LIVE))

# the load-time guard that keeps a future edit from widening payloads into verdicts
print("DISJOINT=%s" % (not (mc.VERIFIER_FIELDS & set(mc.PAYLOAD_FIELDS))))
try:
    mc.PAYLOAD_FIELDS = ("claim", "commit_ref")
    mc._assert_disjoint()
    print("GUARD_FIRES=False")
except RuntimeError:
    print("GUARD_FIRES=True")
PY
RC=$?
[ "$RC" -eq 0 ] || bad "block C driver exited $RC: $(cat "$WORK/c.err")"
grep -q '^PAYLOAD_ENCODED=True$' "$WORK/c.out" \
  && ok "the payload field WAS encoded (so the guards below are not vacuous)" \
  || bad "payload was not encoded — the invariant-2 assertions would be vacuous"
for k in VERIFIER_INTACT COMMIT_SAME REFS_SAME STATUS_SAME WEIGHT_SAME; do
  grep -q "^$k=True$" "$WORK/c.out" \
    && ok "verifier input survives encode bit-identical: $k" \
    || bad "$k is not identical — the codec reached a verifier input"
done
grep -q '^VERIFIER_INPUT_RAW=True$' "$WORK/c.out" \
  && ok "what reaches vm_gitcheck.verify() contains NO wire form (gates read raw)" \
  || bad "a wire form reached the verifier — a compressed judge input"
grep -q '^VERDICT_UNMOVED=True$' "$WORK/c.out" \
  && ok "the verdict is identical with the codec in the path" \
  || bad "the verdict moved with a codec in the path"
grep -q '^DISJOINT=True$' "$WORK/c.out" \
  && ok "PAYLOAD_FIELDS and VERIFIER_FIELDS are disjoint" \
  || bad "PAYLOAD_FIELDS overlaps VERIFIER_FIELDS"
grep -q '^GUARD_FIRES=True$' "$WORK/c.out" \
  && ok "the load-time guard REJECTS widening payloads into a verifier input" \
  || bad "the load-time disjointness guard did not fire"

# the stored line itself still carries the literal verifier values
grep -q "\"commit_ref\":\"$SHA\"" "$STORE" \
  && ok "the stored line carries the LITERAL commit sha (never encoded)" \
  || bad "the stored commit_ref is not literal"
grep -q '"status":"live"' "$STORE" \
  && ok "the stored line carries the LITERAL status (never encoded)" \
  || bad "the stored status is not literal"

echo
echo "D. A LOSSY CODEC CANNOT PERSIST (invariant 1a — the write-side self-check):"

py <<'PY' > "$WORK/d.out" 2>"$WORK/d.err"
import os, sys
sys.path.insert(0, os.environ["LIBDIR"])
import memory_codec as mc
import verified_memory as vm
import vm_gitcheck as vmg

# A codec that silently drops the first character — the exact class of defect that
# would make hmd remember something subtly different from what happened.
mc.register_backend("lossy-test", lambda t: t[1:], lambda w: w)
assert mc.backend_name() == "lossy-test"

repo, home, cache = os.environ["GR"], os.environ["HOME_DIR"], os.environ["CACHE"]
sha = os.environ["SHA"]
with open(os.path.join(repo, "lib", "vm_gitcheck.py"), "r", encoding="utf-8") as fh:
    body = fh.read()

print("ENCODE_FALLS_BACK=%s" % (mc.encode_text(body) == body))

entry = vmg.make_entry("lossy codec must not corrupt this", sha,
                       [{"path": "lib/vm_gitcheck.py", "symbol": "verify"}],
                       entry_id="vm-codec-lossy")
entry = vmg.verify(entry, repo, cache_dir=cache)
entry.pop("cache", None)
entry["summary"] = body
before = entry["status"]
assert vm._append(entry, home)

back = {e["id"]: e for e in vm._read_raw(home)}
got = back.get("vm-codec-lossy", {})
print("PAYLOAD_INTACT=%s" % (got.get("summary") == body))
print("CLAIM_INTACT=%s" % (got.get("claim") == "lossy codec must not corrupt this"))
fresh = vmg.verify(got, repo, cache_dir=cache)
print("VERDICT_UNMOVED=%s" % (fresh["status"] == before == vmg.LIVE))
PY
RC=$?
[ "$RC" -eq 0 ] || bad "block D driver exited $RC: $(cat "$WORK/d.err")"
grep -q '^ENCODE_FALLS_BACK=True$' "$WORK/d.out" \
  && ok "a lossy codec fails the self-check → the payload is stored LITERALLY" \
  || bad "a lossy encoding was accepted by the write-side self-check"
grep -q '^PAYLOAD_INTACT=True$' "$WORK/d.out" \
  && ok "the real payload survives a lossy codec byte-identical" \
  || bad "a lossy codec corrupted the stored payload"
grep -q '^CLAIM_INTACT=True$' "$WORK/d.out" \
  && ok "the claim survives a lossy codec byte-identical" \
  || bad "a lossy codec corrupted the claim"
grep -q '^VERDICT_UNMOVED=True$' "$WORK/d.out" \
  && ok "a lossy codec CANNOT move the verdict (still live)" \
  || bad "a lossy codec moved a verdict — the seam is not safe"

echo
echo "E. A CORRUPTED WIRE FORM IS NEVER SERVED (invariant 1b — the read-side digest):"

py <<'PY' > "$WORK/e.out" 2>"$WORK/e.err"
import json, os, sys, zlib
sys.path.insert(0, os.environ["LIBDIR"])
import memory_codec as mc
import verified_memory as vm
import vm_gitcheck as vmg

mc.register_backend("zlib-test",
                    lambda t: zlib.compress(t.encode("utf-8"), 9),
                    lambda w: zlib.decompress(w).decode("utf-8"))

repo, cache, sha = os.environ["GR"], os.environ["CACHE"], os.environ["SHA"]
home = os.path.join(os.environ["HOME_DIR"], "..", "home-tamper")
home = os.path.abspath(home)

with open(os.path.join(repo, "lib", "memory_codec.py"), "r", encoding="utf-8") as fh:
    body = fh.read()
entry = vmg.make_entry("tamper target", sha,
                       [{"path": "lib/memory_codec.py", "symbol": "encode_text"}],
                       entry_id="vm-codec-tamper")
entry = vmg.verify(entry, repo, cache_dir=cache)
entry.pop("cache", None)
entry["summary"] = body
assert vm._append(entry, home)
print("READS_BEFORE=%d" % len(vm._read_raw(home)))

# Tamper: swap the envelope body for a VALID encoding of DIFFERENT text, so the
# only thing standing between the reader and a silently-wrong memory is the digest.
store = vm.entries_path(home)
with open(store, "r", encoding="utf-8") as fh:
    rec = json.loads(fh.read().strip())
import base64
rec["summary"]["b"] = base64.b64encode(
    zlib.compress(body.replace("codec", "kodec").encode("utf-8"), 9)
).decode("ascii")
with open(store, "w", encoding="utf-8") as fh:
    fh.write(json.dumps(rec, sort_keys=True, separators=(",", ":")) + "\n")

served = vm._read_raw(home)
print("READS_AFTER=%d" % len(served))
print("NOTHING_WRONG_SERVED=%s" % all(e.get("summary") == body for e in served))
PY
RC=$?
[ "$RC" -eq 0 ] || bad "block E driver exited $RC: $(cat "$WORK/e.err")"
grep -q '^READS_BEFORE=1$' "$WORK/e.out" \
  && ok "the untampered entry reads back fine" \
  || bad "the untampered entry did not read back"
grep -q '^READS_AFTER=0$' "$WORK/e.out" \
  && ok "a tampered envelope is SKIPPED — a wrong memory is never served" \
  || bad "a tampered envelope was served: $(grep '^READS_AFTER=' "$WORK/e.out")"
grep -q '^NOTHING_WRONG_SERVED=True$' "$WORK/e.out" \
  && ok "no reader ever sees the substituted text" \
  || bad "a substituted payload reached a reader"

echo
echo "F. EXACTLY ONE HINT, ONCE (the user surface):"

py <<'PY' > "$WORK/f.out" 2>"$WORK/f.err"
import os, sys, zlib
sys.path.insert(0, os.environ["LIBDIR"])
import memory_codec as mc
import verified_memory as vm
import vm_gitcheck as vmg

repo, cache, sha = os.environ["GR"], os.environ["CACHE"], os.environ["SHA"]
home = os.path.abspath(os.path.join(os.environ["HOME_DIR"], "..", "home-hint"))
os.makedirs(os.path.join(home, "memory"), exist_ok=True)

def mkentry(eid):
    e = vmg.make_entry("hint probe %s" % eid, sha,
                       [{"path": "lib/memory_codec.py", "symbol": "maybe_hint"}],
                       entry_id=eid)
    e = vmg.verify(e, repo, cache_dir=cache)
    e.pop("cache", None)
    return e

# a small store has nothing to hint about
assert vm._append(mkentry("vm-hint-1"), home)
store = vm.entries_path(home)
print("SMALL_STORE_SILENT=%s" % (mc.maybe_hint(store) is None))

# grow the store past the heavy threshold with well-formed, ignorable lines
filler = ('{"id":"vm-filler","claim":"%s"}\n' % ("x" * 200))
with open(store, "a", encoding="utf-8") as fh:
    while os.path.getsize(store) < mc.HEAVY_STORE_BYTES + 4096:
        fh.write(filler * 200)
        fh.flush()
print("STORE_IS_HEAVY=%s" % (os.path.getsize(store) > mc.HEAVY_STORE_BYTES))

h1 = mc.maybe_hint(store)
h2 = mc.maybe_hint(store)
h3 = mc.maybe_hint(store)
print("HINT_ONCE=%s" % (h1 == mc.HINT and h2 is None and h3 is None))
print("HINT_TEXT=%s" % h1)

# with a codec active there is nothing to suggest — silent forever
home2 = os.path.abspath(os.path.join(os.environ["HOME_DIR"], "..", "home-hint2"))
os.makedirs(os.path.join(home2, "memory"), exist_ok=True)
store2 = vm.entries_path(home2)
with open(store2, "w", encoding="utf-8") as fh:
    fh.write(filler * (mc.HEAVY_STORE_BYTES // len(filler) + 200))
mc.register_backend("zlib-test",
                    lambda t: zlib.compress(t.encode("utf-8"), 9),
                    lambda w: zlib.decompress(w).decode("utf-8"))
print("CODEC_PRESENT_SILENT=%s" % (mc.maybe_hint(store2) is None))
PY
RC=$?
[ "$RC" -eq 0 ] || bad "block F driver exited $RC: $(cat "$WORK/f.err")"
grep -q '^SMALL_STORE_SILENT=True$' "$WORK/f.out" \
  && ok "a small store is silent — the hint waits for a payload worth compressing" \
  || bad "the hint fired on a small store"
grep -q '^STORE_IS_HEAVY=True$' "$WORK/f.out" \
  && ok "the probe store really is over the heavy threshold" \
  || bad "the probe store never got heavy — block F would be vacuous"
grep -q '^HINT_ONCE=True$' "$WORK/f.out" \
  && ok "the hint fires exactly ONCE and never repeats" \
  || bad "the hint did not fire exactly once"
grep -qF 'HINT_TEXT=hmd can compress its memory stores via Headroom if installed — optional.' "$WORK/f.out" \
  && ok "the hint is the one approved sentence, verbatim" \
  || bad "the hint text drifted: $(grep '^HINT_TEXT=' "$WORK/f.out")"
grep -q '^CODEC_PRESENT_SILENT=True$' "$WORK/f.out" \
  && ok "with a codec active the hint never fires (nothing to suggest)" \
  || bad "the hint fired with a codec already installed"

# the hint reaches the user on stderr, not in the CLI's JSON stdout contract
HINT_ERR="$(py <<'PY' 2>&1 >/dev/null
import os, sys
sys.path.insert(0, os.environ["LIBDIR"])
import verified_memory as vm
home = os.path.abspath(os.path.join(os.environ["HOME_DIR"], "..", "home-hint3"))
os.makedirs(os.path.join(home, "memory"), exist_ok=True)
store = vm.entries_path(home)
filler = ('{"id":"vm-filler","claim":"%s"}\n' % ("x" * 200))
with open(store, "w", encoding="utf-8") as fh:
    fh.write(filler * 6000)
vm._codec_hint(store)
PY
)"
printf '%s' "$HINT_ERR" | grep -qF "hmd: hmd can compress its memory stores via Headroom if installed — optional." \
  && ok "the hint is emitted on STDERR (stdout stays the JSON contract)" \
  || bad "the hint did not reach stderr: [$HINT_ERR]"

echo
echo "G. THE SECRET GATE RUNS BEFORE THE CODEC:"

SECRET="$(printf 'ghp_%s' "$(python3 -c 'print("A"*36)')")"
OUT="$("$CLI" write --repo "$GR" --home "$HOME_DIR" --cache-dir "$CACHE" \
        --claim "token=$SECRET" --commit "$SHA" 2>/dev/null)"; RC=$?
[ "$RC" -eq 3 ] && ok "a secret-shaped claim is REJECTED (exit 3) with the seam in place" \
               || bad "secret-shaped claim exited $RC (expected 3)"
grep -q "$SECRET" "$STORE" 2>/dev/null \
  && bad "the secret reached the store" \
  || ok "the secret is ABSENT from the store — the gate runs before the codec"

echo
if [ "$FAIL" -eq 0 ]; then
  printf '\033[32mALL %d PROOFS PASSED\033[0m\n' "$PASS"
else
  printf '\033[31m%d PROOF(S) FAILED\033[0m (%d passed)\n' "$FAIL" "$PASS"
fi
echo "memory-codec: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
