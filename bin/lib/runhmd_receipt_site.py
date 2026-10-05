#!/usr/bin/env python3
"""runhmd_receipt_site -- `/r/<id>` (HTML) and `/r/<id>.json` (the exact signed bytes) for runhmd.dev.

Three entry points, one code path:
  respond(store, trust, method, target) -> (status, headers, body)   answers ONE request
  serve(store, trust, port)                                          `hmd receipt serve`: respond() over HTTP on 127.0.0.1
  build_site(store, trust, out_dir)                                  `hmd receipt render`: the same page and byte
                                                                     functions, written as a static tree
so the pages a static host publishes and the pages the local server returns cannot disagree.

WHERE THIS RUNS. runhmd.dev has no DNS yet (operator-only), so the pages are built to be served
anywhere: `hmd receipt render --out DIR` writes DIR/r/<id>.json and DIR/r/<id>.html, which any static
host (Netlify and Cloudflare Pages map /r/<id> to r/<id>.html and set application/json for .json)
can publish, and `hmd receipt serve` runs the same thing locally for testing. A hosted service
that accepts uploads (`POST /api/receipts`), renders the 1200x630 card and takes finding ratings is
NOT here: it needs storage, auth and a deploy, all operator decisions (docs/RECEIPTS.md).

WHAT IS SERVED. Only a stored receipt that verifies RIGHT NOW against the pinned keys, and only
under the id it is filed as. /r/<id>.json is the stored bytes untouched. /r/<id> is rendered from
the verified document with every dynamic value passed through html.escape; the template has no
script, no external resource and no form, and carries its own Content-Security-Policy
(default-src 'none', the one inline <style> allowed by hash) so it stays safe on any host. A
receipt that fails verification is a 500 with a fixed body: its content is never echoed. The
publishable tree only ever contains `public` receipts; the local server (loopback only) also
serves `private` ones, marked noindex.
"""
from __future__ import annotations

import base64
import hashlib
import html
import http.server
import os
import re
import sys
import tempfile

HERE = os.path.dirname(os.path.realpath(__file__))
if HERE not in sys.path:
    sys.path.insert(0, HERE)

import runhmd_receipt as rr  # noqa: E402

DEFAULT_PORT = 8720
_ROUTE = re.compile(r"/r/([^/?#]+)")

CSS = """body{font:16px/1.5 system-ui,-apple-system,"Segoe UI",sans-serif;margin:0;background:#fafafa;color:#111}
main{max-width:46rem;margin:2rem auto;padding:0 1rem}
header p{margin:0;color:#555}
h1{margin:.2rem 0 1rem;font-size:2.2rem;letter-spacing:.04em}
.proven{color:#0a6b2d}.denied{color:#a31515}
dl{display:grid;grid-template-columns:max-content 1fr;gap:.35rem 1rem}
dt{color:#555}dd{margin:0;overflow-wrap:anywhere}
table{border-collapse:collapse;width:100%}
th,td{border-bottom:1px solid #ddd;padding:.4rem .5rem;text-align:left;vertical-align:top}
code,pre{font-family:ui-monospace,SFMono-Regular,Menlo,monospace;font-size:.85em;overflow-wrap:anywhere}
pre{background:#eee;padding:.6rem;white-space:pre-wrap}
.t{unicode-bidi:isolate}
"""
_STYLE_HASH = "sha256-" + base64.b64encode(hashlib.sha256(CSS.encode("utf-8")).digest()).decode("ascii")
PAGE_CSP = "default-src 'none'; style-src '%s'; base-uri 'none'; form-action 'none'" % _STYLE_HASH
HEADER_CSP = PAGE_CSP + "; frame-ancestors 'none'"


def _e(value):
    return html.escape(str(value), quote=True)


def _num(value, places):
    return ("%.*f" % (places, value)).rstrip("0").rstrip(".") or "0"


def _table(head, rows):
    return "<table><thead><tr>%s</tr></thead><tbody>%s</tbody></table>" % (
        "".join("<th>%s</th>" % cell for cell in head), "".join("<tr>%s</tr>" % "".join("<td>%s</td>" % cell for cell in row) for row in rows))


def render_page(doc):
    """The HTML page for the verified receipt document `doc` (a str). Every value that came from the
    receipt goes through html.escape."""
    subject, attacks, agent, tool = doc["subject"], doc["attacks"], doc["agent"], doc["tool"]
    verdict = doc["verdict"]
    facts = [
        ("Receipt", "<code>%s</code>" % _e(doc["id"])),
        ("Issued", _e(doc["created_at"])),
        ("Visibility", _e(doc["visibility"])),
        ("Attacked", "%s &middot; tree <code>%s</code>%s" % (
            _e(subject["kind"]), _e(subject["tree_sha256"]), " &middot; git <code>%s</code>" % _e(subject["head_sha"]) if subject["head_sha"] else "")),
        ("Attacks", "%d total &middot; %d survived &middot; %d killed" % (attacks["total"], attacks["survived"], attacks["killed"])),
        ("Agent", _e(agent["name"]) + (" &middot; <span class=\"t\">%s</span>" % _e(agent["model"]) if agent["model"] else "")),
        ("Cost", "$%s &middot; %ss" % (_num(doc["cost_usd"], 4), _num(doc["duration_s"], 2))),
        ("Tool", "<span class=\"t\">%s %s</span>" % (_e(tool["name"]), _e(tool["version"]))),
    ]
    if doc["findings"]:
        found = _table(["Finding", "Severity", "Category", "Title", "Digest"],
                       [["<code>%s</code>" % _e(f["id"]), _e(f["severity"]), _e(f["category"]), "<span class=\"t\">%s</span>" % _e(f["title"]),
                         "<code>%s</code>" % _e(f["digest"])] for f in doc["findings"]])
    else:
        found = "<p>No findings.</p>"
    sections = ["<section><h2>Findings</h2>%s<p>A finding is shown as a digest: the receipt commits to its counterexample without carrying it.</p></section>" % found]
    if doc.get("gates"):
        sections.append("<section><h2>Gates</h2>%s</section>" % _table(
            ["Gate", "Type", "Status", "Falsified", "Score"],
            [["<span class=\"t\">%s</span>" % _e(g["id"]), "<span class=\"t\">%s</span>" % _e(g["gate_type"]), _e(g["status"]),
              "yes" if g["falsified"] else "no", _num(g["falsify_score"], 4)] for g in doc["gates"]]))
    if doc.get("regression_tests"):
        sections.append("<section><h2>Regression tests</h2><p>%d passed &middot; %d failed</p></section>" % (
            doc["regression_tests"]["passed"], doc["regression_tests"]["failed"]))
    sections.append(
        "<section><h2>Signature</h2><p>Ed25519 &middot; key <code>%s</code> &middot; checked against the pinned runhmd receipt keys when this page was produced.</p>"
        "<p>Check it yourself:</p><pre>hmd receipt verify %s</pre>"
        "<p><a href=\"%s.json\">%s.json</a> is the exact signed receipt.</p></section>" % (_e(doc["key_id"]), _e(doc["id"]), _e(doc["id"]), _e(doc["id"])))
    robots = "<meta name=\"robots\" content=\"noindex\">\n" if doc["visibility"] != "public" else ""
    return (
        "<!doctype html>\n<html lang=\"en\">\n<head>\n<meta charset=\"utf-8\">\n"
        "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">\n"
        "<meta http-equiv=\"Content-Security-Policy\" content=\"%s\">\n<meta name=\"referrer\" content=\"no-referrer\">\n%s"
        "<title>runhmd receipt %s &middot; %s</title>\n<style>%s</style>\n</head>\n<body>\n<main>\n"
        "<header><p>runhmd receipt</p><h1 class=\"%s\">%s</h1></header>\n<dl>\n%s\n</dl>\n%s\n</main>\n</body>\n</html>\n" % (
            PAGE_CSP, robots, _e(doc["id"]), _e(verdict), CSS, "proven" if verdict == "PROVEN" else "denied", _e(verdict),
            "\n".join("<dt>%s</dt><dd>%s</dd>" % (label, value) for label, value in facts), "\n".join(sections)))


def page_bytes(doc):
    return render_page(doc).encode("utf-8")


def _headers(content_type, private=False):
    headers = [("Content-Type", content_type), ("X-Content-Type-Options", "nosniff"), ("Referrer-Policy", "no-referrer"),
               ("Content-Security-Policy", HEADER_CSP), ("Cache-Control", "no-store")]
    if private:
        headers.append(("X-Robots-Tag", "noindex"))
    return headers


def _plain(status, text, extra=()):
    return status, _headers("text/plain; charset=utf-8") + list(extra), (text + "\n").encode("utf-8")


def respond(store, trust, method, target):
    """(status, [(header, value)], body bytes) for one request. Only GET and HEAD, only the exact
    paths /r/<id> and /r/<id>.json (the target is never percent-decoded, so nothing but a safe
    token can name a file), only a receipt that verifies now and is filed under its own id."""
    if method not in ("GET", "HEAD"):
        return _plain(405, "method not allowed", [("Allow", "GET, HEAD")])
    match = _ROUTE.fullmatch(target.split("?", 1)[0].split("#", 1)[0])
    if not match:
        return _plain(404, "not found")
    name = match.group(1)
    as_json = name.endswith(".json")
    ident = name[:-len(".json")] if as_json else name
    try:
        rr.check_id(ident)
        doc, raw = rr.load_verified(store, ident, trust)
    except rr.ReceiptError as exc:
        if exc.kind in ("not_found", "bad_id"):
            return _plain(404, "not found")
        sys.stderr.write("hmd receipt serve: refusing %s: %s\n" % (ident, exc))
        return _plain(500, "receipt failed verification")
    private = doc["visibility"] != "public"
    if as_json:
        return 200, _headers("application/json", private), raw
    return 200, _headers("text/html; charset=utf-8", private), page_bytes(doc)


def _write_atomic(path, data):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    fd, tmp = tempfile.mkstemp(prefix=".", suffix=".tmp", dir=os.path.dirname(path))
    try:
        with os.fdopen(fd, "wb") as fh:
            fh.write(data)
        os.chmod(tmp, 0o644)
        os.replace(tmp, path)
    except OSError:
        if os.path.exists(tmp):
            os.unlink(tmp)
        raise


def build_site(store, trust, out_dir):
    """Write the PUBLIC receipts of `store` that verify as out_dir/r/<id>.json (the exact bytes) and
    out_dir/r/<id>.html. Returns {"ok", "rendered", "skipped_private", "failed": [{id, error, detail}]};
    a receipt that fails verification is reported and never written, and the others still are."""
    summary = {"rendered": [], "skipped_private": [], "failed": []}
    try:
        names = sorted(os.listdir(store))
    except FileNotFoundError:
        names = []
    for name in names:
        if not name.endswith(".json"):
            continue
        ident = name[:-len(".json")]
        try:
            rr.check_id(ident)
        except rr.ReceiptError:
            continue
        try:
            doc, raw = rr.load_verified(store, ident, trust)
        except rr.ReceiptError as exc:
            summary["failed"].append({"id": ident, "error": exc.kind, "detail": exc.detail})
            continue
        if doc["visibility"] != "public":
            summary["skipped_private"].append(ident)
            continue
        _write_atomic(os.path.join(out_dir, "r", ident + ".json"), raw)
        _write_atomic(os.path.join(out_dir, "r", ident + ".html"), page_bytes(doc))
        summary["rendered"].append(ident)
    summary["ok"] = not summary["failed"]
    return summary


def _handler(store, trust):
    class Handler(http.server.BaseHTTPRequestHandler):
        server_version = "hmd-receipts"
        sys_version = ""

        def _serve(self, method):
            # The request target exactly as the client wrote it: some Python versions collapse a
            # leading // in self.path, and only the exact /r/<id>[.json] forms may be served.
            words = self.requestline.split(" ")
            status, headers, body = respond(store, trust, method, words[1] if len(words) >= 3 else self.path)
            self.send_response(status)
            for name, value in headers:
                self.send_header(name, value)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            if method != "HEAD":
                self.wfile.write(body)

        def do_GET(self):
            self._serve("GET")

        def do_HEAD(self):
            self._serve("HEAD")

        def do_POST(self):
            self._serve("POST")

        def do_PUT(self):
            self._serve("PUT")

        def do_DELETE(self):
            self._serve("DELETE")

        def do_PATCH(self):
            self._serve("PATCH")

        def do_OPTIONS(self):
            self._serve("OPTIONS")

    return Handler


def serve(store, trust, port):
    """Serve respond() on 127.0.0.1:`port` (0 = any free port) until interrupted. Loopback only: there
    is deliberately no way to bind another address. Raises OSError when the port cannot be bound."""
    server = http.server.ThreadingHTTPServer(("127.0.0.1", port), _handler(store, trust))
    host, bound = server.server_address[:2]
    sys.stdout.write("listening on http://%s:%d (receipts: %s, %d trusted key(s))\n" % (host, bound, store, len(trust)))
    sys.stdout.flush()
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        return 0
    finally:
        server.server_close()
    return 0
