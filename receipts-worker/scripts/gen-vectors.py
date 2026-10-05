#!/usr/bin/env python3
"""gen-vectors.py -- write contract/vectors.json, the cross-language vectors for runhmd.receipt/1.

The Python in bin/lib/runhmd_receipt.py is the reference: every expected value below is what THAT
code does, recorded. Two suites then replay the file against their own implementation:

  receipts-worker/test/vectors.spec.ts          the Worker's JavaScript (canonical.ts, receipt.ts)
  test/receipts-worker-contract.test.sh         the Python again, proving the recorded outcomes still hold

so a change to either side that makes them disagree fails a suite instead of shipping a receipt one
side accepts and the other rejects.

  canonical[]  a JSON text and the exact canonical bytes (hex) Python writes for it, or null when
               Python refuses to write one (NaN, an integer past 2**53, an exponent, a lone surrogate).
  receipts[]   the bytes of a would-be receipt file (raw_b64) and the outcome of verify_bytes against
               `anchors`: "ok", or the ReceiptError kind (not_json, schema, not_canonical,
               unknown_key, bad_signature). `pad_to` means: append spaces until the file is that long.

Keys are generated fresh on every run, in memory, and only PUBLIC data is written: the public key
and the signed bytes. The seed is never written anywhere, so the file holds nothing that can sign,
and regenerating it replaces the whole set with a new key. Usage: gen-vectors.py [--out FILE]
"""
from __future__ import annotations

import argparse
import base64
import json
import os
import random
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.normpath(os.path.join(HERE, "..", "..", "bin", "lib")))

import cp_auth  # noqa: E402
import runhmd_receipt as rr  # noqa: E402

HEX = lambda c: c * 64  # noqa: E731
MAX = rr.MAX_RECEIPT_BYTES


def new_signer():
    private_b64, public_b64 = cp_auth.generate_keypair()
    return rr.Signer(private_b64), public_b64


SIGNER, ANCHOR = new_signer()
STRANGER, _ = new_signer()
TRUST = {SIGNER.key_id: ANCHOR}

FINDINGS = [
    {"id": "f-0001", "title": "duplicate settlement (webhook+retry within 50ms)", "severity": "high", "category": "concurrency", "digest": "sha256:" + HEX("a")},
    {"id": "f-0002", "title": "missing auth check on /refunds — é ✓", "severity": "medium", "category": "auth", "digest": "sha256:" + HEX("b")},
]
GATES = [{"id": "settlement", "gate_type": "differential", "status": "fail", "falsified": True, "falsify_score": 1},
         {"id": "ledger", "gate_type": "property", "status": "pass", "falsified": False, "falsify_score": 0.5}]
PROVEN = dict(verdict="PROVEN", attacks={"total": 24, "survived": 24, "killed": 0}, findings=[],
              gates=[{"id": "settlement", "gate_type": "differential", "status": "pass", "falsified": True, "falsify_score": 1}])


def issue(signer=SIGNER, **over):
    fields = dict(signer=signer, id="a1b2c3d4e5f6", verdict="DENIED",
                  subject={"kind": "path", "head_sha": None, "tree_sha256": HEX("c")},
                  attacks={"total": 24, "survived": 21, "killed": 3}, findings=FINDINGS,
                  agent={"name": "none", "model": None}, cost_usd=0.41, duration_s=1.25,
                  verdict_sha256=HEX("d"), gates=GATES, regression_tests={"passed": 10, "failed": 0},
                  visibility="private", created_at="2026-10-05T12:00:00Z")
    fields.update(over)
    return rr.issue_receipt(**fields)


def signed(doc, signer=SIGNER, **replace):
    """The file bytes of `doc` (a parsed receipt) after `replace`, re-signed by `signer`: valid
    signature, whatever else is wrong with it."""
    body = {k: v for k, v in doc.items() if k != "signature"}
    body.update(replace)
    body["key_id"] = signer.key_id if "key_id" not in replace else replace["key_id"]
    return rr.canonical(dict(body, signature=signer.sign(rr.SIGN_PREFIX + rr.canonical(body)))) + b"\n"


def outcome(raw):
    try:
        rr.verify_bytes(raw, TRUST)
        return "ok"
    except rr.ReceiptError as exc:
        return exc.kind


RECEIPTS = []


def add(name, note, raw, **extra):
    entry = {"name": name, "note": note, "raw_b64": base64.b64encode(raw).decode("ascii")}
    entry.update(extra)
    probe = raw + b" " * (extra["pad_to"] - len(raw)) if "pad_to" in extra else raw
    entry["outcome"] = outcome(probe)
    RECEIPTS.append(entry)


# ── receipts that must verify ────────────────────────────────────────────────────────────────
BASE = issue()
DOC = json.loads(BASE)
add("denied-canonical-lf", "a DENIED receipt exactly as `hmd attack --receipt` writes it", BASE)
add("no-trailing-lf", "the canonical form without the final LF is also a valid file", BASE[:-1])
add("proven-with-gate", "a PROVEN receipt with a falsified passing gate", issue(**PROVEN))
add("minimal-no-gates", "no gates, no regression_tests", issue(gates=None, regression_tests=None))
UNICODE = [dict(FINDINGS[0], title='quote " backslash \\ <script>alert(1)</script> é ✓ \U0001F6E1   \u0001'), FINDINGS[1]]
add("unicode-titles", "quotes, backslash, markup, accents, an astral character, U+2028 and a control character", issue(findings=UNICODE))
add("title-200-astral", "200 code points that are 400 UTF-16 units: valid, length is counted in code points", issue(findings=[dict(FINDINGS[0], title="\U0001F6E1" * 200)]))
add("small-fractions", "cost 0.0001, duration 3600.5", issue(cost_usd=0.0001, duration_s=3600.5))
add("longer-fractions", "cost 12.3456, duration 0.07", issue(cost_usd=12.3456, duration_s=0.07))
add("integral-numbers", "cost 3 and duration 134 are written without a fraction", issue(cost_usd=3, duration_s=134))
add("largest-safe-counts", "attack counts at 2**53 - 1", issue(attacks={"total": 2 ** 53 - 1, "survived": 2 ** 53 - 2, "killed": 1}))
add("leap-day-2028", "29 February in a leap year", issue(created_at="2028-02-29T23:59:59Z"))
add("leap-day-2000", "29 February in a century leap year", issue(created_at="2000-02-29T00:00:00Z"))
add("public-visibility", "visibility public", issue(visibility="public"))

# ── receipts whose spelling is wrong although the document is right ─────────────────────────
text = BASE.decode("utf-8")
add("crlf-ending", "CRLF instead of LF", BASE[:-1] + b"\r\n")
add("two-line-feeds", "a second LF", BASE + b"\n")
add("leading-space", "one space before the document", b" " + BASE)
add("pretty-printed", "indented JSON", json.dumps(DOC, indent=2, ensure_ascii=False).encode("utf-8") + b"\n")
add("keys-reversed", "members in reverse order", json.dumps(dict(reversed(list(DOC.items()))), separators=(",", ":"), ensure_ascii=False).encode("utf-8") + b"\n")
add("ascii-escaped", "non-ASCII written as \\u escapes", json.dumps(json.loads(issue(findings=UNICODE)), separators=(",", ":"), sort_keys=True).encode("ascii") + b"\n")
INTEGRAL = issue(duration_s=134)
add("integral-with-fraction", "134 spelled 134.0", INTEGRAL.replace(b'"duration_s":134,', b'"duration_s":134.0,'))
add("integral-with-exponent", "134 spelled 1.34e2", INTEGRAL.replace(b'"duration_s":134,', b'"duration_s":1.34e2,'))
add("trailing-zero-fraction", "0.41 spelled 0.410", BASE.replace(b'"cost_usd":0.41,', b'"cost_usd":0.410,'))
add("duplicate-member", "verdict repeated with the same value (a parser keeps the last)", BASE[:-2] + b',"verdict":"DENIED"}\n')
add("count-at-2-pow-53", "an attack count Python and JavaScript would both misread", json.dumps(
    dict(DOC, attacks={"total": 2 ** 53, "survived": 2 ** 53 - 1, "killed": 1}, signature="A" * 86 + "=="), separators=(",", ":"), sort_keys=True).encode() + b"\n")

# ── changed after signing ───────────────────────────────────────────────────────────────────
add("tampered-cost", "cost_usd 0.41 -> 0.42, still canonical", BASE.replace(b'"cost_usd":0.41,', b'"cost_usd":0.42,'))
add("tampered-id", "id changed by one character", BASE.replace(b'"id":"a1b2c3d4e5f6"', b'"id":"a1b2c3d4e5f7"'))
add("tampered-title", "one letter of a title", BASE.replace(b"duplicate settlement", b"duplicate settlemenx"))
SIG = DOC["signature"]
flip = ("B" if SIG[0] != "B" else "C") + SIG[1:]
add("signature-first-char", "first signature character changed", BASE.replace(SIG.encode(), flip.encode()))
LAST = SIG[85]
alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
lax = SIG[:85] + alphabet[alphabet.index(LAST) + 1] + "=="
add("signature-noncanonical-base64", "same 64 bytes, last base64 character spelled with non-zero padding bits", BASE.replace(SIG.encode(), lax.encode()))
add("signature-all-a", "pattern-valid signature of zero bytes", BASE.replace(SIG.encode(), ("A" * 86 + "==").encode()))
add("unsigned", "no signature member", rr.canonical({k: v for k, v in DOC.items() if k != "signature"}) + b"\n")
add("empty-signature", "signature is the empty string", BASE.replace(SIG.encode(), b""))
add("stranger-signer", "validly signed by a signer that is not trusted", issue(signer=STRANGER))
add("forged-signer-id", "names the trusted signer's id but is signed by another", signed(DOC, signer=STRANGER, key_id=SIGNER.key_id))

# ── validly signed, but not a valid receipt ─────────────────────────────────────────────────
add("extra-member", "a signed receipt with an extra member (minimal_input)", signed(DOC, minimal_input="{}"))
add("finding-with-counterexample", "a finding carrying counterexample text", signed(
    DOC, findings=[dict(FINDINGS[0], counterexample={"summary": "s", "repro_cmd": "c", "minimal_input": "{}"}), FINDINGS[1]]))
add("proven-with-findings", "PROVEN but findings present", signed(DOC, verdict="PROVEN", attacks={"total": 24, "survived": 24, "killed": 0}))
add("denied-without-findings", "DENIED but no findings", signed(DOC, findings=[]))
add("attacks-do-not-add-up", "total != survived + killed", signed(DOC, attacks={"total": 25, "survived": 21, "killed": 3}))
add("duplicate-finding-ids", "two findings with one id", signed(DOC, findings=[FINDINGS[0], FINDINGS[0]]))
add("falsified-gate-without-score", "falsified gate whose score is 0.5", signed(
    DOC, gates=[dict(GATES[0], falsify_score=0.5)]))
add("proven-with-unfalsified-gate", "PROVEN over a gate that passes but was never falsified", signed(
    DOC, verdict="PROVEN", findings=[], attacks={"total": 24, "survived": 24, "killed": 0},
    gates=[{"id": "g", "gate_type": "example", "status": "pass", "falsified": False, "falsify_score": 0.5}]))
add("february-30", "created_at on a day that does not exist", signed(DOC, created_at="2026-02-30T12:00:00Z"))
add("not-a-leap-year", "29 February 2026", signed(DOC, created_at="2026-02-29T12:00:00Z"))
add("century-not-leap", "29 February 2100", signed(DOC, created_at="2100-02-29T00:00:00Z"))
add("hour-25", "created_at hour 25", signed(DOC, created_at="2026-10-05T25:00:00Z"))
add("second-60", "created_at second 60", signed(DOC, created_at="2026-10-05T12:00:60Z"))
add("year-zero", "created_at year 0000", signed(DOC, created_at="0000-01-01T00:00:00Z"))
add("cost-five-places", "cost_usd with five decimal places", signed(DOC, cost_usd=0.12345))
add("duration-three-places", "duration_s with three decimal places", signed(DOC, duration_s=1.255))
add("negative-cost", "cost_usd below zero", signed(DOC, cost_usd=-1))
add("id-with-slash", "an id that is not a safe token", signed(DOC, id="a/b/c/d"))
add("title-201-astral", "201 code points: over the limit", signed(DOC, findings=[dict(FINDINGS[0], title="\U0001F6E1" * 201), FINDINGS[1]]))
add("tool-name-other", "tool.name is not hmd", signed(DOC, tool={"name": "other", "version": "1"}))
add("key-id-uppercase", "key_id in upper case", signed(DOC, key_id=SIGNER.key_id.upper()))
add("cost-overflow", "cost_usd 1e999 (read as infinity)", BASE.replace(b'"cost_usd":0.41,', b'"cost_usd":1e999,'))

# ── not a receipt file at all ───────────────────────────────────────────────────────────────
add("not-json", "text that is not JSON", b"not json{")
add("empty-file", "zero bytes", b"")
add("byte-order-mark", "a UTF-8 BOM before a valid file", b"\xef\xbb\xbf" + BASE)
add("invalid-utf8", "a byte that is not UTF-8 inside a string", b'{"schema":"runhmd.receipt/1","id":"\xff"}')
add("nan-literal", "the NaN literal", b'{"cost_usd":NaN}')
add("array-document", "a JSON array", b"[]")
add("null-document", "JSON null", b"null")
add("other-schema-id", "a different schema id", b'{"schema":"runhmd.receipt/2"}')
add("over-size", "a valid file padded with spaces past the size limit", BASE, pad_to=MAX + 1)

# ── canonical form, no keys involved ────────────────────────────────────────────────────────
CASES = [
    ("empty-object", "{}"), ("empty-array", "[]"), ("null", "null"), ("true", "true"), ("false", "false"),
    ("keys-sorted", '{"b":1,"a":[true,null,"x"]}'),
    ("whitespace-ignored", ' \t\r\n{ "b" : 2 ,\n"a" : 1 } \n'),
    ("nested", '{"z":{"y":{"x":[1,[2,[3,[]]]]}},"a":{}}'),
    ("short-escapes", r'"\"\\\/\b\f\n\r\t"'),
    ("control-characters", r'"\u0000\u0001\u001f\u007f"'),
    ("accents-literal", '"é ✓ 日本語 \\u00e9"'),
    ("astral-escape-pair", r'"🛡 shield"'),
    ("astral-literal", '"\U0001F6E1 runhmd"'),
    ("line-separators", r'"  "'),
    ("member-order-utf16", r'{"￿":1,"𐀀":2,"a":3,"é":4,"Z":5}'),
    ("member-order-digits", '{"10":1,"9":2,"1":3,"b":4,"B":5}'),
    ("lone-high-surrogate", r'"\ud800"'), ("lone-low-surrogate", r'"\udc00"'), ("lone-surrogate-member", r'{"\ud800":1}'),
    ("duplicate-members", '{"a":1,"a":2}'),
    ("int-zero", "0"), ("int-negative-zero", "-0"), ("float-zero", "0.0"), ("float-negative-zero", "-0.0"),
    ("int", "134"), ("float-integral", "134.0"), ("exponent-integral", "1e2"), ("exponent-integral-upper", "1E2"),
    ("exponent-fraction-integral", "1.5e1"), ("fraction", "0.41"), ("fraction-quarter", "1.25"), ("tenth", "0.1"),
    ("sum-artifact", "0.30000000000000004"), ("half", "0.5"), ("negative-fraction", "-2.5"), ("negative-tenth", "-0.1"),
    ("smallest-plain-fraction", "0.0001"), ("small-fraction", "0.00012345"),
    ("below-plain-fraction", "0.00009999999999999999"), ("exponent-fraction", "0.00001"), ("denormal", "5e-324"),
    ("max-safe-int", "9007199254740991"), ("negative-max-safe-int", "-9007199254740991"),
    ("two-pow-53", "9007199254740992"), ("negative-two-pow-53", "-9007199254740992"),
    ("beyond-two-pow-53", "12345678901234567890"), ("one-e-21", "1e21"), ("max-double", "1.7976931348623157e308"),
    ("overflow-to-infinity", "1e999"),
    ("long-fraction", "123456789.12345679"), ("large-fraction", "1234567890123456.5"), ("half-below-two-pow-52", "4503599627370495.5"),
    ("mixed-array", "[1,1.0,0.5,-0.0,1e2,\"1\"]"),
]

rng = random.Random(20261005)
POOL = ["a", "Z", "é", "ß", "✓", "日", "\U0001F6E1", "\U00010000", "￿", " ", "\"", "\\", "/", "\n", "\t", "\x00", "\x7f", " ", "<", "&"]


def rand_string():
    return "".join(rng.choice(POOL) for _ in range(rng.randint(0, 6)))


def rand_number():
    kind = rng.randint(0, 3)
    if kind == 0:
        return rng.randint(-10 ** 6, 10 ** 15)
    if kind == 1:
        return round(rng.uniform(-1000, 1000), rng.randint(0, 4))
    if kind == 2:
        return rng.choice([0.1, 0.2, 0.3, 1 / 3, 2 / 3, 1e-4, 12.35, 0.07, 100.0, 1e15 + 0.5])
    return float(rng.randint(0, 10 ** 9))


def rand_value(depth=0):
    kind = rng.randint(0, 6 if depth < 3 else 4)
    if kind == 0:
        return None
    if kind == 1:
        return rng.random() < 0.5
    if kind == 2:
        return rand_string()
    if kind in (3, 4):
        return rand_number()
    if kind == 5:
        return [rand_value(depth + 1) for _ in range(rng.randint(0, 4))]
    return {rand_string(): rand_value(depth + 1) for _ in range(rng.randint(0, 4))}


for index in range(80):
    CASES.append(("random-%02d" % index, json.dumps(rand_value(), ensure_ascii=rng.random() < 0.5, indent=rng.choice([None, 1]))))

CANONICAL = []
for name, text in CASES:
    try:
        out = rr.canonical(json.loads(text))
    except ValueError:
        out = None
    CANONICAL.append({"name": name, "json": text, "canonical": None if out is None else out.decode("utf-8"),
                      "hex": None if out is None else out.hex()})

DOCUMENT = {
    "description": "Cross-language vectors for runhmd.receipt/1, written by receipts-worker/scripts/gen-vectors.py from "
                   "bin/lib/runhmd_receipt.py. See that script's docstring for how the two suites replay them.",
    "max_receipt_bytes": MAX,
    "anchors": [ANCHOR],
    "canonical": CANONICAL,
    "receipts": RECEIPTS,
}


def main(argv):
    parser = argparse.ArgumentParser(description="write the cross-language receipt vectors")
    parser.add_argument("--out", default=os.path.join(HERE, "..", "contract", "vectors.json"))
    args = parser.parse_args(argv)
    with open(args.out, "w", encoding="utf-8") as fh:
        json.dump(DOCUMENT, fh, indent=1, ensure_ascii=False)
        fh.write("\n")
    kinds = sorted({r["outcome"] for r in RECEIPTS})
    sys.stdout.write("wrote %d canonical and %d receipt vectors to %s (outcomes: %s)\n" % (len(CANONICAL), len(RECEIPTS), args.out, ", ".join(kinds)))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
