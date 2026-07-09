#!/usr/bin/env python3
"""Independent reference aggregator for the issue-collection differential oracle.

This module is authored SEPARATELY from the implementation (the ``bin/lib/``
issue-aggregate module and its siblings). It is a from-scratch, spec-only
recomputation of the k-anon issue aggregate so that a bug shared with the
implementation cannot false-green the Wave-4 differential gate.

INDEPENDENCE CONTRACT (enforced by the Wave-2d / Wave-4 acceptance greps):
    * imports NOTHING from ``bin/lib/*`` — not the shared privacy-primitive lib,
      not the issue ingest/aggregate/synth impl, not the corpus-aggregate impl.
      Every constant and every computation is reproduced here from the SPEC
      (``evals/oracles/issue-collection/INVARIANTS.md``) alone. The impl module
      names are deliberately NOT spelled here so a literal independence grep over
      this file stays empty; see README.md for the mapping.
    * lives on a disjoint path (``evals/oracles/issue-collection/reference/``).
    * favours correctness and obviousness over speed — this is an oracle, not a
      hot path.

WHAT THE SPEC SAYS (INVARIANTS.md is the ONLY source of truth):
    INV-A  every leaf is coded/hashed/bounded — no raw text. (Enforced upstream
           at emit/ingest; the aggregator consumes already-projected records and
           does not re-derive it, but it refuses to echo any unexpected free-text
           leaf into its output — it only ever emits the pinned bucket key.)
    INV-B  a bucket is SERVED only when >= ISSUE_K_ANONYMITY_MIN (=10) DISTINCT
           team_id_hash have contributed. Distinct-team count, never row count.
           Sub-threshold buckets (incl. a rare signature seen by < 10 teams) get
           a {suppressed: true, reason: "k_anonymity", teams: n} marker and
           NEVER the underlying metrics.
    INV-F  a security-sensitive record NEVER enters the public aggregate, at any
           team count, regardless of k. It is excluded outright and counted only
           as an opaque total.
    INV-G  the store is per-team-partitioned; the aggregate counts DISTINCT
           teams and never emits a per-team row (tenant isolation preserved in
           the output shape).

The bucket key is, per INV-B / plan §Wave-2 issue-aggregate:
    (error_class, signature_hash, hmd_version, os_class, command|phase)

See README.md for the recorded SPEC AMBIGUITIES and the plainest-reading choices
made here (command|phase coalesce, suppressed-marker key visibility, security
exclusion predicate).
"""

from __future__ import annotations

import argparse
import json
import random
import sys
from collections import defaultdict
from typing import Any, Dict, Iterable, List, Optional, Tuple

# --- Spec constants (reproduced from INVARIANTS.md, NOT imported) -------------

#: INV-B — issues use a k-anon floor of 10 distinct teams (the corpus uses 20;
#: issues are rarer, so a 20-floor would starve the feed). This value is
#: hand-copied from INVARIANTS.md §RJ-decision-3, not imported from any impl lib.
ISSUE_K_ANONYMITY_MIN = 10

#: INV-F — the canonical security-sensitive error classes. A record in any of
#: these classes (or flagged security_sensitive) is excluded from the public
#: aggregate outright, regardless of team count. Hand-copied from INVARIANTS.md.
SECURITY_CLASSES = frozenset(
    {"auth", "crypto", "secret", "injection", "deanon", "isolation", "incident"}
)

#: Output schema tag for the reference aggregate (distinct from any impl tag so a
#: byte-diff cannot accidentally match on the wrapper alone).
REF_AGGREGATE_SCHEMA = "issue_aggregate_ref_v1"

#: The pinned bucket-key dimensions, in canonical order. Only these five leaves
#: ever appear in the reference output — nothing else from a record is echoed
#: (INV-A defence: the aggregator cannot leak a stray free-text leaf).
BUCKET_KEY_FIELDS = (
    "error_class",
    "signature_hash",
    "hmd_version",
    "os_class",
    "command_or_phase",
)


# --- Record projection --------------------------------------------------------


def _signal(record: Dict[str, Any]) -> Dict[str, Any]:
    """Return the ``signal`` sub-map, tolerating a flattened record.

    The issue_v1 shape nests coded fields under ``signal`` and env fields under
    ``env`` (INVARIANTS.md §INV-A record sketch). We read from the nested form
    first and fall back to a flat key so the reference can grade either a
    stored record or a hand-written fixture.
    """
    sig = record.get("signal")
    return sig if isinstance(sig, dict) else record


def _env(record: Dict[str, Any]) -> Dict[str, Any]:
    env = record.get("env")
    return env if isinstance(env, dict) else record


def _coalesce_command_phase(sig: Dict[str, Any]) -> str:
    """The ``command|phase`` bucket dimension.

    SPEC AMBIGUITY (see README): INVARIANTS.md / plan write the fifth key
    component as ``command|phase`` with a pipe. The plainest reading of a pipe
    is OR, so this coalesces to ``command`` when present and non-empty, else
    ``phase``, else the empty string. Recorded as an ambiguity; a two-field
    (command, phase) reading is the documented alternative.
    """
    command = sig.get("command")
    if isinstance(command, str) and command != "":
        return command
    phase = sig.get("phase")
    if isinstance(phase, str) and phase != "":
        return phase
    return ""


def is_security_sensitive(record: Dict[str, Any]) -> bool:
    """True iff the record must be excluded from the public aggregate (INV-F).

    A record is security-sensitive when its ``security_sensitive`` flag is truthy
    OR its ``error_class`` is in :data:`SECURITY_CLASSES`. Both readings agree on
    a well-formed stream (the emit lib sets the flag for security classes); the
    class check is a belt-and-suspenders reproduction of the INV-F definition so
    the reference stays correct even on a fixture that forgot to set the flag.
    """
    if record.get("security_sensitive") is True:
        return True
    sig = _signal(record)
    return sig.get("error_class") in SECURITY_CLASSES


def bucket_key(record: Dict[str, Any]) -> Tuple[str, str, str, str, str]:
    """Derive the canonical bucket key tuple for a non-security record."""
    sig = _signal(record)
    env = _env(record)
    return (
        str(sig.get("error_class", "")),
        str(sig.get("signature_hash", "")),
        str(env.get("hmd_version", "")),
        str(env.get("os_class", "")),
        _coalesce_command_phase(sig),
    )


def _team_id_hash(record: Dict[str, Any]) -> Optional[str]:
    """The team a record is attributed to (INV-C: server-derived at ingest).

    The reference reads the attribution the store already recorded — it does not
    re-derive it. Records without a team_id_hash are dropped (they could not have
    been ingested per INV-C's 403 fail-closed).
    """
    ids = record.get("ids")
    if isinstance(ids, dict):
        value = ids.get("team_id_hash")
    else:
        value = record.get("team_id_hash")
    if isinstance(value, str) and value != "":
        return value
    return None


# --- Aggregation --------------------------------------------------------------


def aggregate(
    records: Iterable[Dict[str, Any]],
    k_min: int = ISSUE_K_ANONYMITY_MIN,
) -> Dict[str, Any]:
    """Independent k-anon aggregate over an issue-record stream.

    Returns a canonical, sorted, JSON-serialisable partition:

        {
          "schema": "issue_aggregate_ref_v1",
          "k_anon_min": 10,
          "served":     [ {..key.., "teams": n, "rows": r}, ... ],   # teams >= k
          "suppressed": [ {..key.., "suppressed": true,
                           "reason": "k_anonymity", "teams": n}, ... ],  # 0<teams<k
          "excluded_security": n,       # INV-F records dropped, opaque count only
          "dropped_no_team": n          # INV-C records with no attribution
        }

    Distinct-team counting (INV-B) — a set of team_id_hash per bucket, never row
    count. Security records (INV-F) never reach a bucket. Per-team rows are never
    emitted (INV-G tenant isolation preserved).
    """
    teams_by_bucket: Dict[Tuple[str, ...], set] = defaultdict(set)
    rows_by_bucket: Dict[Tuple[str, ...], int] = defaultdict(int)
    excluded_security = 0
    dropped_no_team = 0

    for record in records:
        if is_security_sensitive(record):
            excluded_security += 1
            continue
        team = _team_id_hash(record)
        if team is None:
            dropped_no_team += 1
            continue
        key = bucket_key(record)
        teams_by_bucket[key].add(team)
        rows_by_bucket[key] += 1

    served: List[Dict[str, Any]] = []
    suppressed: List[Dict[str, Any]] = []

    for key in sorted(teams_by_bucket):
        n_teams = len(teams_by_bucket[key])
        key_map = dict(zip(BUCKET_KEY_FIELDS, key))
        if n_teams >= k_min:
            entry = dict(key_map)
            entry["teams"] = n_teams
            entry["rows"] = rows_by_bucket[key]
            served.append(entry)
        else:
            # SPEC AMBIGUITY (see README): the suppressed marker echoes the
            # bucket key so the differential can verify the FULL partition. A
            # stricter privacy reading would omit signature_hash from the marker;
            # recorded as an ambiguity. teams:n is mandated by INV-B.
            entry = dict(key_map)
            entry["suppressed"] = True
            entry["reason"] = "k_anonymity"
            entry["teams"] = n_teams
            suppressed.append(entry)

    return {
        "schema": REF_AGGREGATE_SCHEMA,
        "k_anon_min": k_min,
        "served": served,
        "suppressed": suppressed,
        "excluded_security": excluded_security,
        "dropped_no_team": dropped_no_team,
    }


# --- Seeded synthetic stream generator ---------------------------------------
#
# A deterministic issue-record stream so the differential gate can diff the impl
# aggregate against this reference over an IDENTICAL input. Same seed => byte-for
# -byte identical stream. Uses only the stdlib ``random`` seeded with the given
# seed (no import of any impl fixture generator).

_ERROR_CLASSES = ["lint", "test", "build", "typecheck", "runtime", "gate", "timeout"]
_SECURITY_ERROR_CLASSES = sorted(SECURITY_CLASSES)
_HMD_VERSIONS = ["2.0.16", "2.0.17", "2.0.18"]
_OS_CLASSES = ["darwin", "linux", "wsl"]
_PHASES = ["plan", "implement", "verify", "review"]
_COMMANDS = ["", "test", "build", "lint", "push"]
_SEVERITIES = ["low", "medium", "high"]


def _signature_hash(rng: random.Random) -> str:
    """A synthetic domain-separated-looking signature hash (hex, non-reversible
    shape). Deterministic given the rng state — NOT a real sha256, just a stable
    64-hex token so the aggregate keying is exercised."""
    return "%064x" % rng.getrandbits(256)


def generate_stream(
    seed: int,
    n_records: int = 400,
    n_signatures: int = 12,
    n_teams: int = 25,
    security_fraction: float = 0.12,
) -> List[Dict[str, Any]]:
    """Generate a deterministic list of issue_v1-shaped records.

    The distribution is deliberately skewed so that some signature buckets clear
    the k>=10 distinct-team floor and some do not (exercising both partitions),
    and a slice is security-sensitive (exercising INV-F exclusion).
    """
    rng = random.Random(seed)
    signatures = [_signature_hash(rng) for _ in range(n_signatures)]
    teams = ["team_%02d_%08x" % (i, rng.getrandbits(32)) for i in range(n_teams)]

    records: List[Dict[str, Any]] = []
    for _ in range(n_records):
        is_sec = rng.random() < security_fraction
        if is_sec:
            error_class = rng.choice(_SECURITY_ERROR_CLASSES)
        else:
            error_class = rng.choice(_ERROR_CLASSES)
        sig = rng.choice(signatures)
        team = rng.choice(teams)
        record = {
            "schema": "issue_v1",
            "consent_version": 1,
            "ids": {
                "issue_id": "%032x" % rng.getrandbits(128),
                "team_id_hash": team,
                "repo_class_hash": "%016x" % rng.getrandbits(64),
            },
            "when": {"ts": 0, "tz_bucket": "utc+0000"},
            "signal": {
                "error_class": error_class,
                "signature_hash": sig,
                "gate": rng.choice(["lint", "test", "build", ""]),
                "phase": rng.choice(_PHASES),
                "command": rng.choice(_COMMANDS),
                "severity": rng.choice(_SEVERITIES),
            },
            "env": {
                "os_class": rng.choice(_OS_CLASSES),
                "ci": rng.choice([True, False]),
                "hmd_version": rng.choice(_HMD_VERSIONS),
            },
            "security_sensitive": is_sec,
        }
        records.append(record)
    return records


# --- Canonical serialisation --------------------------------------------------


def to_canonical_json(obj: Any) -> str:
    """Deterministic JSON: sorted keys, compact separators, trailing newline.

    Byte-stable so the differential gate can diff impl-vs-reference output
    directly.
    """
    return json.dumps(obj, sort_keys=True, separators=(",", ":")) + "\n"


def _read_records(path: Optional[str]) -> List[Dict[str, Any]]:
    """Read newline-delimited JSON records (ndjson) or a JSON array, from a file
    or stdin (path ``-`` or None)."""
    if path in (None, "-"):
        text = sys.stdin.read()
    else:
        with open(path, "r", encoding="utf-8") as handle:
            text = handle.read()
    text = text.strip()
    if not text:
        return []
    if text[0] == "[":
        data = json.loads(text)
        return list(data)
    records: List[Dict[str, Any]] = []
    for line in text.splitlines():
        line = line.strip()
        if line:
            records.append(json.loads(line))
    return records


# --- Self-consistency check (hand-checked partition) --------------------------


def _selftest() -> int:
    """Hand-built fixture whose served/suppressed/excluded partition is checked
    by hand here, proving the aggregator matches the spec on a known input.

    Fixture:
      * signature "AAAA": hit by 11 distinct teams (t00..t10)  -> SERVED (>=10)
      * signature "BBBB": hit by  3 distinct teams (t00..t02)  -> SUPPRESSED (<10)
      * signature "CCCC": one team, error_class "auth"         -> EXCLUDED (INV-F)
      * signature "DDDD": one team, security_sensitive=True     -> EXCLUDED (INV-F)
    All non-security records share error_class/hmd/os/command so each signature
    is exactly one bucket.
    """
    records: List[Dict[str, Any]] = []
    base_sig = {
        "error_class": "lint",
        "gate": "lint",
        "phase": "implement",
        "command": "lint",
        "severity": "low",
    }
    base_env = {"os_class": "linux", "ci": False, "hmd_version": "2.0.18"}

    def mk(sig_hash: str, team: str, *, error_class: str = "lint",
           security: bool = False) -> Dict[str, Any]:
        sig = dict(base_sig)
        sig["error_class"] = error_class
        sig["signature_hash"] = sig_hash
        return {
            "schema": "issue_v1",
            "ids": {"team_id_hash": team},
            "signal": sig,
            "env": dict(base_env),
            "security_sensitive": security,
        }

    # AAAA: 11 distinct teams, with a duplicate row (rows > teams) to prove
    # distinct-team counting, not row counting.
    for i in range(11):
        records.append(mk("AAAA", "t%02d" % i))
    records.append(mk("AAAA", "t00"))  # duplicate team -> rows=12, teams=11

    # BBBB: 3 distinct teams -> suppressed
    for i in range(3):
        records.append(mk("BBBB", "t%02d" % i))

    # CCCC: excluded by error_class (auth), even though it is its own bucket
    records.append(mk("CCCC", "t00", error_class="auth"))

    # DDDD: excluded by flag
    records.append(mk("DDDD", "t00", security=True))

    result = aggregate(records)

    problems: List[str] = []

    if len(result["served"]) != 1:
        problems.append("expected 1 served bucket, got %d" % len(result["served"]))
    else:
        served = result["served"][0]
        if served["signature_hash"] != "AAAA":
            problems.append("served bucket is not AAAA: %r" % served)
        if served["teams"] != 11:
            problems.append("AAAA teams != 11: %r" % served["teams"])
        if served["rows"] != 12:
            problems.append("AAAA rows != 12 (distinct vs row bug?): %r" % served["rows"])

    supp_sigs = sorted(s["signature_hash"] for s in result["suppressed"])
    if supp_sigs != ["BBBB"]:
        problems.append("expected suppressed == [BBBB], got %r" % supp_sigs)
    else:
        bbbb = result["suppressed"][0]
        if bbbb["teams"] != 3 or bbbb["reason"] != "k_anonymity" or bbbb["suppressed"] is not True:
            problems.append("BBBB suppressed marker malformed: %r" % bbbb)

    if result["excluded_security"] != 2:
        problems.append("expected 2 excluded security records, got %d" % result["excluded_security"])

    # No security signature may appear anywhere in the served/suppressed output.
    leaked = [
        e["signature_hash"]
        for e in (result["served"] + result["suppressed"])
        if e["signature_hash"] in ("CCCC", "DDDD")
    ]
    if leaked:
        problems.append("SECURITY LEAK: %r reached the public partition" % leaked)

    if problems:
        sys.stderr.write("SELFTEST FAILED:\n")
        for p in problems:
            sys.stderr.write("  - %s\n" % p)
        sys.stderr.write("\nPartition:\n%s" % to_canonical_json(result))
        return 1

    sys.stdout.write("SELFTEST OK — partition matches hand-checked spec:\n")
    sys.stdout.write("  served=1 (AAAA teams=11 rows=12), ")
    sys.stdout.write("suppressed=1 (BBBB teams=3), excluded_security=2\n")
    return 0


# --- CLI ----------------------------------------------------------------------


def _build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="aggregate_ref.py",
        description=(
            "Independent reference aggregator for the issue-collection "
            "differential oracle. Recomputes the k-anon (>=10 distinct teams) "
            "issue aggregate from spec, sharing no code with the implementation."
        ),
    )
    sub = parser.add_subparsers(dest="command")

    p_gen = sub.add_parser("generate", help="emit a seeded synthetic issue stream (ndjson)")
    p_gen.add_argument("--seed", type=int, required=True, help="deterministic stream seed")
    p_gen.add_argument("--records", type=int, default=400, help="number of records")
    p_gen.add_argument("--signatures", type=int, default=12, help="distinct error signatures")
    p_gen.add_argument("--teams", type=int, default=25, help="distinct teams")

    p_agg = sub.add_parser("aggregate", help="read a stream and emit the canonical aggregate")
    p_agg.add_argument("--input", default="-", help="ndjson/JSON-array file, or - for stdin")
    p_agg.add_argument("--k-min", type=int, default=ISSUE_K_ANONYMITY_MIN, help="k-anon floor")

    p_run = sub.add_parser("run", help="generate a seeded stream and aggregate it in one shot")
    p_run.add_argument("--seed", type=int, required=True, help="deterministic stream seed")
    p_run.add_argument("--records", type=int, default=400, help="number of records")
    p_run.add_argument("--signatures", type=int, default=12, help="distinct error signatures")
    p_run.add_argument("--teams", type=int, default=25, help="distinct teams")
    p_run.add_argument("--k-min", type=int, default=ISSUE_K_ANONYMITY_MIN, help="k-anon floor")

    sub.add_parser("selftest", help="run the hand-checked partition self-consistency check")

    return parser


def main(argv: Optional[List[str]] = None) -> int:
    parser = _build_parser()
    args = parser.parse_args(argv)

    if args.command == "generate":
        stream = generate_stream(
            args.seed, n_records=args.records,
            n_signatures=args.signatures, n_teams=args.teams,
        )
        out = sys.stdout.write
        for record in stream:
            out(to_canonical_json(record))
        return 0

    if args.command == "aggregate":
        records = _read_records(args.input)
        sys.stdout.write(to_canonical_json(aggregate(records, k_min=args.k_min)))
        return 0

    if args.command == "run":
        stream = generate_stream(
            args.seed, n_records=args.records,
            n_signatures=args.signatures, n_teams=args.teams,
        )
        sys.stdout.write(to_canonical_json(aggregate(stream, k_min=args.k_min)))
        return 0

    if args.command == "selftest":
        return _selftest()

    parser.print_help()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
