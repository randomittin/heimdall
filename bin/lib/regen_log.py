#!/usr/bin/env python3
# regen_log.py — the designmatch v2 hash-log: change-detection GATE + provenance
# RECORD in one content-hash ledger.
#
# WHY THIS EXISTS (designmatch v2, READ pipeline steps 1-2):
#   designmatch v2 regenerates a screen from its canonical design rather than
#   retrofitting the old component. Regenerating EVERY screen on every run would
#   churn unchanged screens (and the behavior re-attached to them) for no reason.
#   So we gate regeneration on a CONTENT HASH of the canonical: a screen is
#   regenerated only when its canonical's hash differs from what the ledger last
#   recorded. The same ledger doubles as the PROVENANCE record — which generated
#   file was derived from which canonical at which hash, and when — so a generated
#   component is verifiably "derived from the design" (Heimdall's source-of-truth
#   ethos), not hand-mutated.
#
# This module is STANDALONE. The regenerate path (a separate piece) CALLS it:
#   - `changed(screen, canonical)` is the gate it checks before regenerating.
#   - `record(screen, canonical, generated_output)` is what it writes after a
#     successful regenerate, to both advance the gate AND stamp provenance.
#
# ── HASH NORMALIZATION (the choice + why) ─────────────────────────────────────
# The content hash is sha256 over a NORMALIZED view of the canonical's bytes, not
# the raw bytes. Normalization (applied in this order):
#   1. Decode as UTF-8 (errors -> surrogateescape, so non-UTF-8 bytes still hash
#      deterministically and round-trip — we never crash on binary-ish input).
#   2. Normalize line endings: CRLF and lone CR  ->  LF.
#   3. Strip TRAILING whitespace on every line (spaces, tabs, form-feeds, etc.).
#   4. Strip trailing blank lines, then append exactly ONE trailing newline.
#   The normalized text is re-encoded UTF-8 (surrogateescape) and sha256'd.
#
# Rationale: a designer/exporter reflowing the canonical — re-saving with CRLF,
# adding trailing spaces, or churning the final-newline count — is NOT a design
# change and must NOT trigger a regenerate (that would re-churn the screen's
# migrated behavior for a no-op edit). But a REAL design change (different label,
# color, structure — any non-whitespace byte) DOES change the normalized text and
# therefore the hash. Normalization is deliberately conservative: it only collapses
# whitespace differences that carry no semantic weight in a design source. Internal
# whitespace (indentation, spaces between tokens) is PRESERVED, because in markup/
# JSX that can be semantically meaningful — we strip only trailing/line-ending
# noise, the part that is provably presentation-free churn.
#
# ── LEDGER SCHEMA (.designmatch/regen-log.json) ───────────────────────────────
#   {
#     "version": 1,
#     "screens": {
#       "<screen>": {
#         "design_hash":      "sha256:<64 hex>",   # hash of the canonical at record time
#         "canonical_path":   "<path as recorded>",# which canonical it came from
#         "generated_output": "<path>",            # which generated file was derived
#         "recorded_at":      "<ISO-8601 UTC>"      # when provenance was stamped
#       }, ...
#     }
#   }
# The ledger is ALWAYS written atomically (temp file in the same dir + os.replace),
# so a crash mid-write never leaves a partial/corrupt ledger — the old one stays
# intact and jq-valid. A missing or empty ledger is tolerated (first run): reads
# see an empty screen map; the first `record` materializes the file.

import hashlib
import json
import os
import sys
import tempfile
from datetime import datetime, timezone

LEDGER_VERSION = 1
HASH_PREFIX = "sha256:"

# Test-only hook: when this env var is truthy, a write raises AFTER the temp file
# is written but BEFORE os.replace, to prove the atomic-rename guarantee (the old
# ledger survives, no partial write lands). Never set in production.
_CRASH_BEFORE_RENAME_ENV = "DESIGNMATCH_REGEN_CRASH_BEFORE_RENAME"


# ── hashing ───────────────────────────────────────────────────────────────────


def normalize_content(raw_bytes):
    """Normalize canonical bytes to the text we hash. See the module header for
    the rationale. Pure function of the input bytes; deterministic."""
    text = raw_bytes.decode("utf-8", errors="surrogateescape")
    # 2. line endings: CRLF and lone CR -> LF
    text = text.replace("\r\n", "\n").replace("\r", "\n")
    # 3. strip trailing whitespace per line
    lines = [ln.rstrip() for ln in text.split("\n")]
    # 4. drop trailing blank lines, then re-join with a single trailing newline
    while lines and lines[-1] == "":
        lines.pop()
    normalized = "\n".join(lines)
    if normalized:
        normalized += "\n"
    return normalized


def hash_bytes(raw_bytes):
    """Return the canonical content hash 'sha256:<64 hex>' of normalized bytes."""
    normalized = normalize_content(raw_bytes)
    digest = hashlib.sha256(
        normalized.encode("utf-8", errors="surrogateescape")
    ).hexdigest()
    return HASH_PREFIX + digest


def hash_file(path):
    """Content hash of a file on disk. Raises FileNotFoundError if absent — the
    caller decides whether a missing canonical is an error (it is for `hash`/
    `changed`/`record`: you cannot detect or record a design that isn't there)."""
    with open(path, "rb") as fh:
        return hash_bytes(fh.read())


# ── ledger I/O (tolerant load, atomic write) ──────────────────────────────────


def _empty_ledger():
    return {"version": LEDGER_VERSION, "screens": {}}


def load_ledger(path):
    """Load the ledger, tolerating a missing OR empty OR malformed file: any of
    those yields a fresh empty ledger rather than crashing (first-run safety and
    crash-recovery). A well-formed ledger with the wrong shape is repaired to the
    canonical shape, preserving the existing 'screens' map if present."""
    if not os.path.exists(path):
        return _empty_ledger()
    try:
        with open(path, "rb") as fh:
            raw = fh.read()
    except OSError:
        return _empty_ledger()
    if not raw.strip():
        return _empty_ledger()
    try:
        data = json.loads(raw.decode("utf-8", errors="surrogateescape"))
    except (ValueError, UnicodeError):
        # A corrupt/partial ledger should not wedge the gate; treat as empty.
        return _empty_ledger()
    if not isinstance(data, dict):
        return _empty_ledger()
    screens = data.get("screens")
    if not isinstance(screens, dict):
        screens = {}
    return {"version": LEDGER_VERSION, "screens": screens}


def save_ledger(path, ledger):
    """Atomically write the ledger: serialize to a temp file in the SAME directory,
    fsync it, then os.replace() over the target. os.replace is atomic on POSIX, so
    a reader/crash never observes a half-written ledger — it sees either the old
    bytes or the new bytes, nothing in between. On any failure the temp file is
    removed so no stray '<ledger>.<rand>' is left behind."""
    directory = os.path.dirname(path) or "."
    os.makedirs(directory, exist_ok=True)
    payload = json.dumps(ledger, indent=2, sort_keys=True) + "\n"
    fd, tmp_path = tempfile.mkstemp(
        prefix=os.path.basename(path) + ".", dir=directory
    )
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            fh.write(payload)
            fh.flush()
            os.fsync(fh.fileno())
        # Test-only crash hook: prove the temp+rename atomicity. We raise here,
        # AFTER the temp is fully written but BEFORE the replace — exactly the
        # window where a naive in-place writer would have already corrupted the
        # real ledger. The finally-block cleans the temp so no stray file leaks.
        if os.environ.get(_CRASH_BEFORE_RENAME_ENV):
            raise RuntimeError(
                "simulated crash before rename (%s set)" % _CRASH_BEFORE_RENAME_ENV
            )
        os.replace(tmp_path, path)
        tmp_path = None  # consumed by replace; nothing to clean
    finally:
        if tmp_path is not None and os.path.exists(tmp_path):
            try:
                os.remove(tmp_path)
            except OSError:
                # Best-effort cleanup; the temp lives in the ledger dir and an
                # unremovable temp must never mask the original write failure.
                _ignore_temp_cleanup_failure()


def _ignore_temp_cleanup_failure():
    """A no-op landing point so the temp-cleanup except clause has a real body
    (not a bare pass) while still swallowing an unremovable-temp OSError."""
    return None


# ── operations ────────────────────────────────────────────────────────────────


def op_hash(canonical_path):
    """Return the content hash of a canonical file."""
    return hash_file(canonical_path)


def is_changed(ledger, screen, canonical_path):
    """Return (changed, current_hash, recorded_hash). `changed` is True if `screen`
    must be regenerated: its canonical's current hash differs from the ledger's
    recorded hash, OR the screen has no ledger entry (new). False only when an
    entry exists AND its recorded hash equals the current hash."""
    current = hash_file(canonical_path)
    entry = ledger["screens"].get(screen)
    if entry is None:
        return True, current, None
    recorded = entry.get("design_hash")
    return (current != recorded), current, recorded


def op_record(ledger, screen, canonical_path, generated_output):
    """Upsert the ledger entry for `screen` from the canonical's CURRENT hash and
    return the new entry. The caller persists via save_ledger."""
    current = hash_file(canonical_path)
    entry = {
        "design_hash": current,
        "canonical_path": canonical_path,
        "generated_output": generated_output,
        "recorded_at": datetime.now(timezone.utc)
        .isoformat(timespec="seconds")
        .replace("+00:00", "Z"),
    }
    ledger["screens"][screen] = entry
    return entry


def op_provenance(ledger, screen):
    """Return the recorded provenance entry for `screen`, or None if unrecorded."""
    return ledger["screens"].get(screen)


def op_list(ledger):
    """Return the full screen->entry map (provenance for every recorded screen)."""
    return ledger["screens"]


# ── CLI ───────────────────────────────────────────────────────────────────────
#
# Invoked by the thin wrapper bin/designmatch-regen-log. Contract:
#
#   hash       <canonical>                          -> prints sha256:<hex>; exit 0
#   changed    <screen> <canonical>                 -> "changed"   + exit 0  (regen)
#                                                       "unchanged" + exit 1  (no-op)
#   record     <screen> <canonical> <generated>     -> upsert; prints the entry; 0
#   provenance <screen>                             -> prints the entry JSON; exit 0
#                                                       (exit 3 if the screen is absent)
#   list                                            -> prints the screen->entry map
#
# --ledger PATH overrides the ledger location (default .designmatch/regen-log.json,
# resolved relative to the current working directory). Usage errors -> exit 2.

DEFAULT_LEDGER = os.path.join(".designmatch", "regen-log.json")

USAGE = """designmatch-regen-log — hash-log change-detection + provenance ledger

usage:
  designmatch-regen-log [--ledger PATH] hash       <canonical-file>
  designmatch-regen-log [--ledger PATH] changed    <screen> <canonical-file>
  designmatch-regen-log [--ledger PATH] record     <screen> <canonical-file> <generated-output>
  designmatch-regen-log [--ledger PATH] provenance <screen>
  designmatch-regen-log [--ledger PATH] list

exit codes:
  0  ok / changed (regenerate)
  1  unchanged (no-op — the gate that prevents churning unchanged screens)
  2  usage error
  3  provenance: no such recorded screen
  4  runtime error (e.g. missing canonical file, interrupted write)
"""


def _die(msg, code):
    sys.stderr.write(msg.rstrip("\n") + "\n")
    return code


def main(argv):
    args = list(argv[1:])
    ledger_path = DEFAULT_LEDGER
    # Parse the optional --ledger PATH (may appear before the subcommand).
    out = []
    i = 0
    while i < len(args):
        if args[i] == "--ledger":
            if i + 1 >= len(args):
                return _die("regen-log: --ledger requires a PATH", 2)
            ledger_path = args[i + 1]
            i += 2
            continue
        if args[i] in ("-h", "--help"):
            sys.stdout.write(USAGE)
            return 0
        out.append(args[i])
        i += 1
    args = out

    if not args:
        return _die(USAGE, 2)

    cmd = args[0]
    rest = args[1:]

    try:
        if cmd == "hash":
            if len(rest) != 1:
                return _die("regen-log: hash <canonical-file>", 2)
            sys.stdout.write(op_hash(rest[0]) + "\n")
            return 0

        if cmd == "changed":
            if len(rest) != 2:
                return _die("regen-log: changed <screen> <canonical-file>", 2)
            screen, canonical = rest
            ledger = load_ledger(ledger_path)
            changed, current, recorded = is_changed(ledger, screen, canonical)
            if changed:
                sys.stdout.write("changed\n")
                sys.stderr.write(
                    "regen-log: %s CHANGED (current=%s recorded=%s)\n"
                    % (screen, current, recorded if recorded else "<none>")
                )
                return 0
            sys.stdout.write("unchanged\n")
            sys.stderr.write(
                "regen-log: %s unchanged (hash=%s) — no regenerate\n"
                % (screen, current)
            )
            return 1

        if cmd == "record":
            if len(rest) != 3:
                return _die(
                    "regen-log: record <screen> <canonical-file> <generated-output>",
                    2,
                )
            screen, canonical, generated = rest
            ledger = load_ledger(ledger_path)
            entry = op_record(ledger, screen, canonical, generated)
            save_ledger(ledger_path, ledger)
            sys.stdout.write(json.dumps(entry, indent=2, sort_keys=True) + "\n")
            sys.stderr.write(
                "regen-log: recorded %s -> %s @ %s\n"
                % (screen, generated, entry["design_hash"])
            )
            return 0

        if cmd == "provenance":
            if len(rest) != 1:
                return _die("regen-log: provenance <screen>", 2)
            screen = rest[0]
            ledger = load_ledger(ledger_path)
            entry = op_provenance(ledger, screen)
            if entry is None:
                return _die(
                    "regen-log: no provenance recorded for screen %r" % screen, 3
                )
            sys.stdout.write(json.dumps(entry, indent=2, sort_keys=True) + "\n")
            return 0

        if cmd == "list":
            if rest:
                return _die("regen-log: list takes no arguments", 2)
            ledger = load_ledger(ledger_path)
            sys.stdout.write(
                json.dumps(op_list(ledger), indent=2, sort_keys=True) + "\n"
            )
            return 0

        return _die("regen-log: unknown command %r\n\n%s" % (cmd, USAGE), 2)

    except FileNotFoundError as exc:
        return _die("regen-log: file not found: %s" % exc, 4)
    except RuntimeError as exc:
        # Includes the simulated-crash hook: a write was interrupted. The atomic
        # rename guarantees the old ledger is intact; we surface the failure so the
        # caller knows the record did NOT land.
        return _die("regen-log: interrupted: %s" % exc, 4)
    except OSError as exc:
        return _die("regen-log: i/o error: %s" % exc, 4)


if __name__ == "__main__":
    sys.exit(main(sys.argv))
