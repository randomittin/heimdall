#!/usr/bin/env python3
"""runhmd_receipt_cli -- `hmd receipt`: verify, keygen, render, serve (RP3).

All logic is in runhmd_receipt.py (issue/verify/keys/store) and runhmd_receipt_site.py (pages);
this module only parses arguments and maps results to output and exit codes:
  0 ok, 1 the receipt is INVALID, 2 usage or configuration error, 5 infrastructure error.
JSON (--json) is the canonical output; the human text is a render of it.
"""
from __future__ import annotations

import argparse
import json
import os
import sys

HERE = os.path.dirname(os.path.realpath(__file__))
if HERE not in sys.path:
    sys.path.insert(0, HERE)

import runhmd_receipt as rr  # noqa: E402

EXIT_OK, EXIT_INVALID, EXIT_USAGE, EXIT_INFRA = 0, 1, 2, 5

USAGE = """usage:
  hmd receipt verify <file|id> [--pubkey FILE]... [--store DIR] [--json]
  hmd receipt keygen [--dir DIR] [--json]
  hmd receipt render --out DIR [--store DIR] [--pubkey FILE]... [--json]
  hmd receipt serve [--store DIR] [--port N] [--pubkey FILE]...
  hmd receipt --help
"""

HELP = """hmd receipt -- the signed, shareable record of one verdict (runhmd.receipt/1).

""" + USAGE + """
  verify   check a receipt. It must be a runhmd.receipt/1 document, its bytes must be exactly the
           canonical form that was signed, and the Ed25519 signature must be one of the PINNED keys'
           (the key is never taken from the receipt). <id> is looked up in the store and must be the
           id the receipt carries. Any changed field, or any changed byte, fails.
  keygen   create the receipt signing key (secret, mode 0600) and its public key in DIR (default
           $HEIMDALL_HOME/signing). Never overwrites a key. Pin the public key where verifiers
           look (release/runhmd-receipt.pub in the hmd repo, or --pubkey).
  render   write the PUBLIC receipts of the store as a static tree for runhmd.dev: r/<id>.json (the
           exact signed bytes) and r/<id>.html (escaped). Private receipts are never written and a
           receipt that fails verification is reported and never written.
  serve    serve /r/<id> and /r/<id>.json from the store on 127.0.0.1 only (default port 8720),
           for local testing of what render publishes. Refuses to start without a trust anchor.

options:
  --pubkey FILE   a file of pinned public keys, one base64 Ed25519 key per line (repeatable);
                  replaces the environment and the defaults
  --store DIR     the receipt store (default: see RUNHMD_RECEIPT_DIR)
  --dir DIR       where keygen writes
  --out DIR       where render writes
  --port N        serve port, 0 for any free port
  --json          print the result as one JSON object on stdout

environment:
  RUNHMD_RECEIPT_KEY_FILE      the signing key (default $HEIMDALL_HOME/signing/runhmd-receipt.key;
                               refused when other users can read it)
  RUNHMD_RECEIPT_PUBKEY_FILE   the pinned trust set (default: release/runhmd-receipt.pub in this
                               install plus $HEIMDALL_HOME/signing/runhmd-receipt.pub)
  RUNHMD_RECEIPT_DIR           the receipt store (default $HEIMDALL_HOME/runhmd/receipts)
  RUNHMD_RECEIPT_BASE_URL      the https base of receipt URLs (default https://runhmd.dev)

exit codes:
  0  ok
  1  the receipt is INVALID: changed after it was signed, signed by another key, or not a receipt
  2  usage or configuration error: bad flag, no trust anchor, no such receipt, unreadable key
  5  infrastructure error: the server cannot listen
"""


class _Parser(argparse.ArgumentParser):
    def error(self, message):
        sys.stderr.write("hmd receipt: %s (see hmd receipt --help)\n" % message)
        sys.exit(EXIT_USAGE)


def _parser(command):
    return _Parser(prog="hmd receipt " + command, add_help=False, allow_abbrev=False)


def _fail(exc, as_json):
    """Report a ReceiptError: JSON on stdout (the canonical form) or one line on stderr. Exit 2 for a
    configuration problem, 1 for a receipt that is bad."""
    config = exc.kind in rr.CONFIG_KINDS
    if as_json:
        sys.stdout.write(json.dumps({"ok": False, "error": exc.kind, "detail": exc.detail}) + "\n")
    else:
        sys.stderr.write("hmd receipt: %s%s: %s\n" % ("" if config else "INVALID: ", exc.kind, exc.detail))
    return EXIT_USAGE if config else EXIT_INVALID


def _read_file(path):
    try:
        with open(path, "rb") as fh:
            return fh.read(rr.MAX_RECEIPT_BYTES + 1)
    except OSError as exc:
        raise rr.ReceiptError("not_found", "cannot read %s: %s" % (path, exc.strerror or exc)) from exc


def _verify(argv):
    p = _parser("verify")
    p.add_argument("target")
    p.add_argument("--pubkey", action="append")
    p.add_argument("--store")
    p.add_argument("--json", action="store_true")
    args = p.parse_args(argv)
    try:
        trust = rr.load_trust(args.pubkey)
        if os.path.isfile(args.target):
            doc = rr.verify_bytes(_read_file(args.target), trust)
        elif os.sep in args.target or args.target.endswith(".json") or args.target in (".", ".."):
            raise rr.ReceiptError("not_found", "no such receipt file: %s" % args.target)
        else:
            doc, _ = rr.load_verified(args.store or rr.store_dir(), args.target, trust)
    except rr.ReceiptError as exc:
        return _fail(exc, args.json)
    if args.json:
        sys.stdout.write(json.dumps({"ok": True, "id": doc["id"], "verdict": doc["verdict"], "visibility": doc["visibility"],
                                     "created_at": doc["created_at"], "key_id": doc["key_id"]}) + "\n")
    else:
        sys.stdout.write("ok %s %s signed by key %s (issued %s, %s)\n" % (doc["id"], doc["verdict"], doc["key_id"], doc["created_at"], doc["visibility"]))
    return EXIT_OK


def _keygen(argv):
    p = _parser("keygen")
    p.add_argument("--dir")
    p.add_argument("--json", action="store_true")
    args = p.parse_args(argv)
    try:
        key_path, pub_path, key_id = rr.generate_key_files(args.dir or rr.signing_dir())
    except rr.ReceiptError as exc:
        return _fail(exc, args.json)
    if args.json:
        sys.stdout.write(json.dumps({"ok": True, "key_id": key_id, "key_file": key_path, "pub_file": pub_path}) + "\n")
    else:
        sys.stdout.write("key_id  %s\nsecret  %s  (mode 0600: keep it private, never commit it)\npublic  %s\n"
                         "Pin the public key where verifiers look: copy it to release/runhmd-receipt.pub in the hmd repo, "
                         "or pass --pubkey FILE.\n" % (key_id, key_path, pub_path))
    return EXIT_OK


def _trust_or_fail(pubkeys, as_json):
    """(trust, None) or (None, exit code): the trust set must exist before anything is read or written."""
    try:
        trust = rr.load_trust(pubkeys)
        if not trust:
            raise rr.ReceiptError("no_trust", "no trusted receipt public key is configured: pass --pubkey FILE, set "
                                  "RUNHMD_RECEIPT_PUBKEY_FILE, or run `hmd receipt keygen`")
    except rr.ReceiptError as exc:
        return None, _fail(exc, as_json)
    return trust, None


def _render(argv):
    p = _parser("render")
    p.add_argument("--out", required=True)
    p.add_argument("--store")
    p.add_argument("--pubkey", action="append")
    p.add_argument("--json", action="store_true")
    args = p.parse_args(argv)
    trust, code = _trust_or_fail(args.pubkey, args.json)
    if trust is None:
        return code
    import runhmd_receipt_site as site
    try:
        summary = site.build_site(args.store or rr.store_dir(), trust, args.out)
    except OSError as exc:
        sys.stderr.write("hmd receipt: cannot write the site into %s: %s\n" % (args.out, exc))
        return EXIT_INFRA
    if args.json:
        sys.stdout.write(json.dumps(summary) + "\n")
    else:
        sys.stdout.write("rendered %d public receipt(s) into %s; skipped %d private; %d failed verification\n" % (
            len(summary["rendered"]), os.path.join(args.out, "r"), len(summary["skipped_private"]), len(summary["failed"])))
        for failure in summary["failed"]:
            sys.stderr.write("hmd receipt: INVALID: %s: %s: %s\n" % (failure["id"], failure["error"], failure["detail"]))
    return EXIT_OK if summary["ok"] else EXIT_INVALID


def _serve(argv):
    p = _parser("serve")
    p.add_argument("--store")
    p.add_argument("--port", default="8720")
    p.add_argument("--pubkey", action="append")
    args = p.parse_args(argv)
    if not args.port.isdigit() or int(args.port) > 65535:
        sys.stderr.write("hmd receipt: --port needs a number from 0 to 65535, got %r (see hmd receipt --help)\n" % args.port)
        return EXIT_USAGE
    trust, code = _trust_or_fail(args.pubkey, False)
    if trust is None:
        return code
    import runhmd_receipt_site as site
    try:
        return site.serve(args.store or rr.store_dir(), trust, int(args.port))
    except OSError as exc:
        sys.stderr.write("hmd receipt: cannot listen on 127.0.0.1:%s: %s\n" % (args.port, exc.strerror or exc))
        return EXIT_INFRA


COMMANDS = {"verify": _verify, "keygen": _keygen, "render": _render, "serve": _serve}


def main(argv):
    if not argv:
        sys.stderr.write("hmd receipt: a subcommand is required\n" + USAGE)
        return EXIT_USAGE
    command, rest = argv[0], argv[1:]
    if command in ("-h", "--help", "help") or (command in COMMANDS and any(a in ("-h", "--help") for a in rest)):
        sys.stdout.write(HELP)
        return EXIT_OK
    if command not in COMMANDS:
        sys.stderr.write("hmd receipt: unknown subcommand '%s' (verify, keygen, render, serve; see hmd receipt --help)\n" % command)
        return EXIT_USAGE
    return COMMANDS[command](rest)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
