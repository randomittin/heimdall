#!/usr/bin/env python3
# chat_cli.py — chat-ops P2 CLI implementation (driven by the bin/heimdall-chat launcher).
#
# Subcommands:
#   link [channel]                 Mint a one-time 6-digit link code for THIS machine's HAID
#                                  (team server-derived). Prints the code + the DM to send the
#                                  bot. `hmd link telegram` is the shorthand for `chat link`.
#   handle --chat-id ID --text T   One-shot: run a single message through the dispatch seam and
#   handle --update-json JSON      print the reply (and send it if the bot token is configured).
#                                  --update-json takes a raw Telegram Update (parsed via the
#                                  adapter); '-' reads it from stdin.
#   serve [channel]                Long-poll getUpdates and reply in-thread (real Telegram loop).
#                                  Requires HEIMDALL_TELEGRAM_BOT_TOKEN; exits 2 when inactive.
#   bindings                       List every non-revoked chat binding (audit surface).
#   unlink <chat_id> [channel]     Revoke a chat binding (fail-closed tombstone).
#
# The bot token is read from env HEIMDALL_TELEGRAM_BOT_TOKEN ONLY (never a literal). Identity
# binding is the crux: a chat handle is never trusted bare — see bin/lib/chat_link.py.
#
# Exit: 0 ok, 2 usage / inactive / not-enrolled error.

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import time

_LIB = os.path.dirname(os.path.abspath(__file__))   # …/bin/lib
_BIN = os.path.dirname(_LIB)                          # …/bin
if _LIB not in sys.path:
    sys.path.insert(0, _LIB)

import chat_adapter
import chat_core
import chat_link


def _current_haid():
    """This checkout's HAID via the sibling `heimdall-haid current` CLI (the deterministic
    per-checkout identity). Returns the HAID string, or None when the CLI is unavailable."""
    cli = os.path.join(_BIN, "heimdall-haid")
    if not os.path.isfile(cli):
        return None
    try:
        proc = subprocess.run([cli, "current"], capture_output=True, text=True, timeout=10)
    except (OSError, subprocess.SubprocessError):
        return None
    if proc.returncode != 0:
        return None
    haid = (proc.stdout or "").strip()
    return haid or None


def cmd_link(args):
    """Mint a one-time link code for this machine's HAID (team server-derived from the HAID)."""
    channel = args.channel or chat_link.DEFAULT_CHANNEL
    haid = _current_haid()
    if not haid:
        sys.stderr.write("heimdall-chat: could not resolve this machine's HAID "
                         "(is heimdall-haid installed and enrolled?)\n")
        return 2
    res = chat_link.mint_code(haid, channel=channel)
    if not res.get("ok"):
        reason = res.get("reason")
        if reason == "no_team":
            sys.stderr.write("heimdall-chat: this HAID is not enrolled in a team — run "
                             "`hmd team` / enroll first, then link.\n")
        else:
            sys.stderr.write("heimdall-chat: could not mint a link code (%s)\n" % reason)
        return 2
    ttl_min = int(res.get("ttl", chat_link.DEFAULT_TTL_SECONDS)) // 60
    print("Link code: %s" % res["code"])
    print("Team:      %s" % (res.get("team_id") or "")[:8])
    print("Expires:   in %d minutes (single-use)" % ttl_min)
    print("")
    print("DM the bot on %s:  /hmd link %s" % (channel, res["code"]))
    return 0


def _reply_for(chat_id, text, channel):
    """Run one message through the dispatch seam; return (reply_text, result_dict)."""
    result = chat_core.handle_message(chat_id, text, channel=channel)
    return result.get("reply", ""), result


def cmd_handle(args):
    """One-shot: dispatch a single inbound message and print (and optionally send) the reply."""
    channel = args.channel or chat_link.DEFAULT_CHANNEL
    if args.update_json is not None:
        raw = sys.stdin.read() if args.update_json == "-" else args.update_json
        try:
            update = json.loads(raw)
        except (ValueError, TypeError):
            sys.stderr.write("heimdall-chat: --update-json is not valid JSON\n")
            return 2
        parsed = chat_adapter.parse_update(update)
        if not parsed:
            sys.stderr.write("heimdall-chat: update carried no text message to handle\n")
            return 2
        chat_id, text = parsed["chat_id"], parsed["text"]
    else:
        if args.chat_id is None or args.text is None:
            sys.stderr.write("heimdall-chat handle: need --chat-id and --text "
                             "(or --update-json)\n")
            return 2
        chat_id, text = args.chat_id, args.text

    reply, _result = _reply_for(chat_id, text, channel)
    print(reply)
    # Send the reply in-thread when the bot is configured; a clean no-op otherwise.
    if chat_adapter.is_active():
        chat_adapter.send_message(chat_id, reply)
    return 0


def cmd_serve(args):
    """Long-poll getUpdates and reply in-thread (the real Telegram loop). Inactive -> exit 2."""
    channel = args.channel or chat_link.DEFAULT_CHANNEL
    if not chat_adapter.is_active():
        sys.stderr.write("heimdall-chat serve: %s is not set — set the bot token to serve.\n"
                         % chat_adapter.BOT_TOKEN_ENV)
        return 2
    sys.stderr.write("heimdall-chat: serving %s (Ctrl-C to stop)\n" % channel)
    offset = None
    while True:
        try:
            updates = chat_adapter.get_updates(offset)
        except KeyboardInterrupt:
            sys.stderr.write("\nheimdall-chat: stopped.\n")
            return 0
        for update in updates:
            parsed = chat_adapter.parse_update(update)
            uid = update.get("update_id") if isinstance(update, dict) else None
            if uid is not None:
                offset = uid + 1  # ack this update so it is not redelivered.
            if not parsed:
                continue
            reply, _result = _reply_for(parsed["chat_id"], parsed["text"], channel)
            chat_adapter.send_message(parsed["chat_id"], reply)
        if not updates:
            # No pending updates and the long-poll returned empty (or errored) — pace the loop.
            time.sleep(1)


def cmd_bindings(_args):
    """List every non-revoked chat binding (the audit surface, §2)."""
    rows = chat_link.list_bindings()
    if not rows:
        print("no chat bindings.")
        return 0
    print("channel   chat_id              team      haid")
    for r in rows:
        print("%-9s %-20s %-9s %s" % (
            r.get("channel") or "?", r.get("chat_id") or "?",
            (r.get("team_id") or "")[:8], r.get("haid") or "?"))
    return 0


def cmd_unlink(args):
    """Revoke a chat binding (fail-closed tombstone)."""
    channel = args.channel or chat_link.DEFAULT_CHANNEL
    if chat_link.unlink(args.chat_id, channel=channel):
        print("unlinked %s on %s." % (args.chat_id, channel))
        return 0
    sys.stderr.write("heimdall-chat: no binding to unlink for %s on %s.\n"
                     % (args.chat_id, channel))
    return 2


def build_parser():
    p = argparse.ArgumentParser(prog="heimdall-chat",
                                description="Heimdall chat-ops P2 CLI (Telegram).")
    sub = p.add_subparsers(dest="cmd")

    pl = sub.add_parser("link", help="mint a one-time link code for this machine's HAID")
    pl.add_argument("channel", nargs="?", default=chat_link.DEFAULT_CHANNEL)
    pl.set_defaults(func=cmd_link)

    ph = sub.add_parser("handle", help="dispatch a single inbound message")
    ph.add_argument("--chat-id", dest="chat_id")
    ph.add_argument("--text")
    ph.add_argument("--update-json", dest="update_json",
                    help="a raw Telegram Update as JSON (or '-' to read stdin)")
    ph.add_argument("--channel", default=chat_link.DEFAULT_CHANNEL)
    ph.set_defaults(func=cmd_handle)

    ps = sub.add_parser("serve", help="long-poll and reply in-thread (needs the bot token)")
    ps.add_argument("channel", nargs="?", default=chat_link.DEFAULT_CHANNEL)
    ps.set_defaults(func=cmd_serve)

    pb = sub.add_parser("bindings", help="list every non-revoked chat binding")
    pb.set_defaults(func=cmd_bindings)

    pu = sub.add_parser("unlink", help="revoke a chat binding")
    pu.add_argument("chat_id")
    pu.add_argument("channel", nargs="?", default=chat_link.DEFAULT_CHANNEL)
    pu.set_defaults(func=cmd_unlink)

    return p


def main(argv=None):
    parser = build_parser()
    args = parser.parse_args(argv)
    if not getattr(args, "cmd", None):
        parser.print_help()
        return 2
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
