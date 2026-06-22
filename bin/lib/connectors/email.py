#!/usr/bin/env python3
# email.py — the email (IMAP/SMTP) source adapter (design dossier §1/§2).
#
# fetch_issues returns RAW email message dicts (native parsed-header shape:
# {message_id, subject, from, date, body, x_priority, in_reply_to}) for the
# configured mailbox. It does NOT normalize — normalize() (piece b) maps the
# native shape to the internal issue schema (title = Subject, body = text/plain,
# source_ref = {message_id, from, in_reply_to}, links.url = None). post_resolution
# replies to the originating sender; close_issue is a no-op success (email has no
# "close" — the reply IS the resolution, so close is idempotently ok).
#
# LAZY / OPTIONAL: IMAP/SMTP use the stdlib (imaplib/smtplib — always present),
# but the adapter is INACTIVE without a password AND host. configure() reads the
# password from the resolved config block ONLY (key "password"). Absent password
# -> health().active == False, fetch_issues() -> [], post/close -> inactive. No
# IMAP/SMTP connection is opened without a password.

from __future__ import annotations

import email as _email
import email.utils
import imaplib
import smtplib
from email.header import decode_header, make_header
from email.message import EmailMessage
from typing import List, Optional

from . import Connector, ConnectorConfigError, register

_IMAP_TIMEOUT = 30


class EmailConnector(Connector):
    name = "email"
    label = "Email"
    kind = "email"

    def __init__(self) -> None:
        self._mailbox: Optional[str] = None
        self._user: Optional[str] = None
        self._password: Optional[str] = None
        self._imap_host: Optional[str] = None
        self._imap_port = 993
        self._smtp_host: Optional[str] = None
        self._smtp_port = 587
        self._folder = "INBOX"

    # ── configure / health / identity ─────────────────────────────────────────
    def configure(self, cfg: dict) -> None:
        if not isinstance(cfg, dict):
            raise ConnectorConfigError("email config must be an object")
        mailbox = cfg.get("mailbox")
        if not mailbox:
            raise ConnectorConfigError("email config needs 'mailbox' (the address to triage)")
        self._mailbox = str(mailbox)
        self._user = str(cfg.get("user") or mailbox)
        self._imap_host = str(cfg["imap_host"]) if cfg.get("imap_host") else None
        self._smtp_host = str(cfg["smtp_host"]) if cfg.get("smtp_host") else None
        self._imap_port = int(cfg.get("imap_port", 993))
        self._smtp_port = int(cfg.get("smtp_port", 587))
        self._folder = str(cfg.get("folder") or "INBOX")
        pw = cfg.get("password")
        self._password = str(pw) if pw else None

    def health(self) -> dict:
        if not self._mailbox:
            return {"name": self.name, "active": False, "reason": "not configured"}
        if not self._imap_host:
            return {"name": self.name, "active": False, "reason": "no imap_host configured"}
        if not self._password:
            return {
                "name": self.name,
                "active": False,
                "reason": "no password (set the password_env credential to activate)",
            }
        return {"name": self.name, "active": True, "reason": None}

    def identity(self) -> dict:
        return {"name": self.name, "label": self.label, "kind": self.kind}

    # ── fetch (raw native shape) ──────────────────────────────────────────────
    def fetch_issues(self, since: Optional[str] = None) -> List[dict]:
        if not self.health()["active"]:
            return []
        items: List[dict] = []
        try:
            conn = imaplib.IMAP4_SSL(self._imap_host, self._imap_port, timeout=_IMAP_TIMEOUT)
        except (OSError, imaplib.IMAP4.error):
            return []
        try:
            conn.login(self._user, self._password)
            conn.select(self._folder, readonly=True)
            criteria = ["UNSEEN"]
            if since:
                criteria = ["SINCE", str(since)]
            typ, data = conn.search(None, *criteria)
            if typ != "OK" or not data or not data[0]:
                return []
            for num in data[0].split():
                typ, msg_data = conn.fetch(num, "(RFC822)")
                if typ != "OK" or not msg_data or not msg_data[0]:
                    continue
                raw = msg_data[0][1]
                if isinstance(raw, (bytes, bytearray)):
                    items.append(self._parse(bytes(raw)))
        except (OSError, imaplib.IMAP4.error):
            return items
        finally:
            self._quiet_logout(conn)
        # deterministic order by message-id (a stable per-message key).
        items.sort(key=lambda m: m.get("message_id") or "")
        return items

    @staticmethod
    def _quiet_logout(conn) -> None:
        """Best-effort IMAP logout — a teardown failure must not mask the result
        of fetch_issues (which already returned its items)."""
        try:
            conn.logout()
        except (OSError, imaplib.IMAP4.error):
            return

    # ── writeback ─────────────────────────────────────────────────────────────
    def post_resolution(self, raw_ref: dict, resolution: dict) -> dict:
        if not self.health()["active"]:
            return {"ok": False, "reason": "inactive"}
        ref = raw_ref or {}
        to_addr = ref.get("from")
        in_reply_to = ref.get("message_id")
        if not to_addr:
            return {"ok": False, "reason": "missing from in source_ref"}
        if not self._smtp_host:
            return {"ok": False, "reason": "no smtp_host configured"}
        msg = EmailMessage()
        msg["From"] = self._mailbox
        msg["To"] = to_addr
        msg["Subject"] = "Re: " + str(ref.get("subject") or "your report")
        if in_reply_to:
            msg["In-Reply-To"] = in_reply_to
            msg["References"] = in_reply_to
        msg.set_content(self._resolution_text(resolution))
        try:
            with smtplib.SMTP(self._smtp_host, self._smtp_port, timeout=_IMAP_TIMEOUT) as smtp:
                smtp.starttls()
                smtp.login(self._user, self._password)
                smtp.send_message(msg)
        except (OSError, smtplib.SMTPException):
            return {"ok": False, "reason": "smtp send failed"}
        return {"ok": True, "message_id": msg.get("Message-ID") or in_reply_to}

    def close_issue(self, raw_ref: dict) -> dict:
        # Email has no "close" verb — the reply IS the resolution. close is an
        # idempotent success so writeback's close+reply pair is uniform across
        # sources. Inactive still degrades honestly.
        if not self.health()["active"]:
            return {"ok": False, "reason": "inactive"}
        return {"ok": True, "message_id": (raw_ref or {}).get("message_id")}

    # ── internals ─────────────────────────────────────────────────────────────
    @staticmethod
    def _resolution_text(resolution: dict) -> str:
        res = resolution or {}
        pr_url = res.get("pr_url") or res.get("url")
        summary = res.get("summary") or "Your report has been resolved."
        return summary + ("\n\nResolved in %s\n" % pr_url if pr_url else "\n")

    @classmethod
    def _parse(cls, raw: bytes) -> dict:
        msg = _email.message_from_bytes(raw)
        return {
            "message_id": (msg.get("Message-ID") or "").strip() or None,
            "subject": cls._hdr(msg.get("Subject")),
            "from": cls._addr(msg.get("From")),
            "date": (msg.get("Date") or "").strip() or None,
            "x_priority": (msg.get("X-Priority") or "").strip() or None,
            "in_reply_to": (msg.get("In-Reply-To") or "").strip() or None,
            "body": cls._body(msg),
        }

    @staticmethod
    def _hdr(value) -> str:
        if not value:
            return ""
        try:
            return str(make_header(decode_header(value)))
        except (ValueError, LookupError):
            return str(value)

    @classmethod
    def _addr(cls, value):
        if not value:
            return None
        _name, addr = email.utils.parseaddr(cls._hdr(value))
        return addr or None

    @staticmethod
    def _body(msg) -> str:
        # prefer text/plain; fall back to the first text part. HTML is not parsed
        # here (normalize, piece b, owns html-strip if a source is html-only).
        if msg.is_multipart():
            for part in msg.walk():
                if part.get_content_type() == "text/plain" and not part.get_filename():
                    payload = part.get_payload(decode=True)
                    if payload is not None:
                        charset = part.get_content_charset() or "utf-8"
                        return payload.decode(charset, "replace")
            return ""
        payload = msg.get_payload(decode=True)
        if payload is None:
            return ""
        charset = msg.get_content_charset() or "utf-8"
        return payload.decode(charset, "replace")


register(EmailConnector())
