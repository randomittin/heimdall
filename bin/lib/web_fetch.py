#!/usr/bin/env python3
"""web_fetch.py -- dependency-light web fetch/crawl/extract engine for heimdall-web.

WHY THIS EXISTS
    Firecrawl was evaluated twice (docs/analysis/2026-08-23-firecrawl-assessment.md,
    docs/analysis/2026-09-05-web-research-tools-rollout.md Part 2) and rejected both
    times as a DEPENDENCY: AGPL-3.0's network-use clause on modification, and a
    self-hosted build that needs a Playwright browser pool + Redis + Postgres and is
    feature-behind the hosted tier. That verdict is about the dependency, not the
    capability -- the operator's own framing: "by itself cc isn't able to fetch and
    crawl webpages well -- firecrawl just makes it easier -- I don't want you to copy
    it but replicate it's functionality." This module is that replication, built
    independently against stdlib only -- no Firecrawl code, config shape, or output
    format is vendored, forked, or copied anywhere in this file.

WHAT NATIVE TOOLS ALREADY COVER (verified against this session's own tool grants and
docs/analysis/2026-09-05-web-research-tools-rollout.md, not assumed):
    WebFetch  -- fetches ONE url, summarizes it through a model on every call (no
                 raw-markdown output, no crawl, no link-following, no batch, token
                 cost per page every time even for a re-fetch of the same url).
    WebSearch -- returns search results; never fetches the page bodies at all.
    Neither does: bounded multi-page crawling, concurrent batch fetch, a byte/page/
    depth-capped run, structured metadata extraction (OG/Twitter/JSON-LD/canonical),
    or same-session caching. Those gaps are this module's whole scope. Where a native
    tool already covers something, it is deliberately NOT rebuilt here.

SECURITY MODEL (this makes network requests -- treat every call as a trust boundary)
    Adapted from the SSRF-guard / byte-cap / exit-code pattern in bin/lib/md_convert.py
    (same repo, different direction: that module renders LOCAL files someone else
    handed the model; this one fetches REMOTE content the model asked for -- both
    need the same "never trust the byte source, never trust the address" posture).

    1. Scheme allowlist: only http/https. Everything else is a Refused (exit 4).
    2. SSRF guard: hostnames are resolved via socket.getaddrinfo, and EVERY resolved
       address is checked against ipaddress' is_private/is_loopback/is_link_local/
       is_reserved/is_multicast/is_unspecified, plus the literal cloud-metadata
       address 169.254.169.254. If ANY resolved address is blocked, the whole lookup
       is refused -- a multi-A-record host that offers one public and one private
       answer is exactly the "ambiguity" this project's safety rules say must refuse,
       not silently pick the public one. --allow-private opts out, for local testing
       only.
    3. Connection pinning: the actual socket connects to the pre-validated IP
       directly (see _PinnedHTTPConnection/_PinnedHTTPSConnection below), never
       re-resolving the hostname at connect time. Without this, a validate-then-
       reconnect design is a classic DNS-rebind TOCTOU: the name resolves to a public
       IP for the check and a private one a few milliseconds later for the real
       connection. The Host header and TLS SNI still use the original hostname, so
       virtual hosting keeps working -- only the socket's peer address is pinned.
    4. Every redirect hop is fully re-validated: scheme, host resolution, and
       robots.txt are all re-checked at each Location target, not just the original
       URL. Otherwise "fetch this public URL" that 302s to a private address, or to
       a disallowed path, would sail through unnoticed.
    5. robots.txt is fetched through this SAME guarded path (never
       RobotFileParser.read()'s own internal urlopen(), which would bypass every
       guard above, including across ITS OWN redirects) and only handed to
       RobotFileParser.parse() for the rule matching itself (parse-only, no I/O).
       An unreachable or missing robots.txt is treated as "allow", the universal
       web convention -- that is a normal, unambiguous case, not the kind of
       safety-relevant ambiguity the refuse-by-default rule is about.
    6. Credentials: never sent, ever. No Authorization header, no Cookie header, no
       reading of environment variables that look like secrets. The only headers
       sent are Host, User-Agent, Accept, and Connection: close -- nothing else, and
       nothing sourced from the environment. This is absolute, not best-effort.
    7. Bounded everything: per-request timeout, total wall-clock budget for crawl/
       batch runs, per-page byte cap, total-bytes cap for a crawl, page-count cap,
       depth cap, redirect-count cap. A hung or enormous fetch cannot wedge a caller.
    8. Fail open on crashing: a malformed page, bad HTML, or one failed URL inside a
       crawl/batch run is recorded as an error entry, never an uncaught exception
       that kills the whole run. Fail closed on safety: any scheme/address/robots
       ambiguity refuses that one fetch outright rather than guessing.

WHAT WAS DELIBERATELY LEFT OUT (see bin/heimdall-web --help and the coder's final
report for the reasoning): a POST/form-submission mode (this is a read-only research
tool, not a browser automation tool -- that gap is what Firecrawl's Cloud-only
Agent/Interact tiers cover, and is explicitly out of scope here); JavaScript
rendering (would require a real browser -- the same Playwright-pool cost that got
Firecrawl's self-host build rejected in the first assessment; a bounded, headless-
browser-free tool is the entire point); arbitrary named-field extraction beyond the
well-known metadata this module already extracts deterministically (title,
description, OpenGraph, Twitter Card, canonical, JSON-LD, headings) -- pulling
ad hoc fields ("give me the price and SKU from this page") is exactly what a model
reading the cleaned markdown this module already produces is good at, and pinning
that logic into this tool would mean either re-implementing a second, worse
extraction model here or shipping a schema mini-language nobody asked for.
"""

import collections
import concurrent.futures
import hashlib
import html.parser
import http.client
import ipaddress
import json
import os
import re
import socket
import ssl
import sys
import time
import urllib.parse
import urllib.robotparser
from dataclasses import dataclass

USER_AGENT = "heimdall-web/1.0 (+https://runheimdall.dev/heimdall-web; anonymous, no credentials)"
ALLOWED_SCHEMES = ("http", "https")

DEFAULT_TIMEOUT = 15
DEFAULT_MAX_BYTES = 2 * 1024 * 1024
DEFAULT_MAX_REDIRECTS = 5
DEFAULT_CRAWL_MAX_DEPTH = 2
DEFAULT_CRAWL_MAX_PAGES = 20
DEFAULT_CRAWL_MAX_TOTAL_BYTES = 20 * 1024 * 1024
DEFAULT_CRAWL_WALL_CLOCK = 60
DEFAULT_BATCH_CONCURRENCY = 4
DEFAULT_BATCH_WALL_CLOCK = 60
DEFAULT_CACHE_TTL = 900

_METADATA_IP = "169.254.169.254"


# --------------------------------------------------------------------------
# Error taxonomy
# --------------------------------------------------------------------------

class WebFetchError(Exception):
    """Base for every error this module raises."""


class Refused(WebFetchError):
    """A deliberate SAFETY refusal: bad scheme, private/loopback/reserved
    address, or robots.txt disallow. Distinct from a transport failure --
    the target was rejected on purpose, not because the network broke."""


class SchemeRefused(Refused):
    """Refused: the URL scheme is not http or https."""


class PrivateAddressRefused(Refused):
    """Refused: a resolved address is loopback/private/reserved/link-local/
    multicast/unspecified, or the cloud-metadata address -- and
    --allow-private was not passed to opt in."""


class RobotsDisallowed(Refused):
    """Refused: robots.txt disallows this path for our user agent, and
    --ignore-robots was not passed to override."""


class FetchFailed(WebFetchError):
    """A transport-layer failure: DNS, connect, timeout, malformed response."""


class TooManyRedirects(FetchFailed):
    """Failed: the redirect chain exceeded max_redirects hops."""


class _UsageError(Exception):
    """CLI argument-parsing error. Caught only at the main() dispatch layer."""


# --------------------------------------------------------------------------
# SSRF guard + pinned connections
# --------------------------------------------------------------------------

def _ip_is_blocked(ip_str):
    try:
        ip = ipaddress.ip_address(ip_str)
    except ValueError:
        return True  # unparseable address -> fail closed
    if str(ip) == _METADATA_IP:
        return True
    return (
        ip.is_private or ip.is_loopback or ip.is_link_local
        or ip.is_reserved or ip.is_multicast or ip.is_unspecified
    )


def resolve_validated_ip(host, port, allow_private):
    """Resolve `host` and return one validated IP to connect to. Raises
    PrivateAddressRefused if ANY resolved address is private/loopback/
    reserved/link-local/multicast/unspecified/cloud-metadata (unless
    allow_private) -- a multi-answer DNS response offering both a public
    and a private address refuses entirely rather than picking the public
    one, since that split-answer shape is itself the ambiguity the
    fail-closed safety rule is about."""
    host_clean = (host or "").strip().strip("[]")
    if not host_clean:
        raise PrivateAddressRefused("empty host")
    try:
        infos = socket.getaddrinfo(host_clean, port, type=socket.SOCK_STREAM)
    except (socket.gaierror, UnicodeError, OSError) as exc:
        raise FetchFailed("DNS resolution failed for %r: %s" % (host, exc)) from exc
    addrs = []
    seen = set()
    for _family, _type, _proto, _canon, sockaddr in infos:
        ip = sockaddr[0]
        if ip not in seen:
            seen.add(ip)
            addrs.append(ip)
    if not addrs:
        raise FetchFailed("DNS resolution returned no usable addresses for %r" % host)
    if not allow_private:
        blocked = [ip for ip in addrs if _ip_is_blocked(ip)]
        if blocked:
            raise PrivateAddressRefused(
                "refusing private/loopback/reserved address(es) %s for host %r "
                "(pass --allow-private to opt in for local testing)"
                % (", ".join(blocked), host)
            )
    return addrs[0]


def _format_host_header(host, port):
    hostpart = "[%s]" % host if ":" in host else host
    if port in (80, 443):
        return hostpart
    return "%s:%d" % (hostpart, port)


class _PinnedHTTPConnection(http.client.HTTPConnection):
    """HTTPConnection that connects to a pre-validated IP instead of
    re-resolving self.host at connect time -- closes the DNS-rebind TOCTOU
    between the SSRF check and the real connection. Host header / request
    line still use the original hostname."""

    def __init__(self, host, port, resolved_ip, timeout):
        super().__init__(host, port=port, timeout=timeout)
        self._resolved_ip = resolved_ip

    def connect(self):
        self.sock = socket.create_connection((self._resolved_ip, self.port), timeout=self.timeout)


class _PinnedHTTPSConnection(http.client.HTTPSConnection):
    def __init__(self, host, port, resolved_ip, timeout, context):
        super().__init__(host, port=port, timeout=timeout, context=context)
        self._resolved_ip = resolved_ip

    def connect(self):
        raw = socket.create_connection((self._resolved_ip, self.port), timeout=self.timeout)
        self.sock = self._context.wrap_socket(raw, server_hostname=self.host)


# --------------------------------------------------------------------------
# Core guarded fetch
# --------------------------------------------------------------------------

@dataclass
class FetchResult:
    url: str
    final_url: str
    status: int
    content_type: str
    body: bytes
    truncated: bool

    @property
    def text(self):
        enc = _charset_from_content_type(self.content_type) or "utf-8"
        try:
            return self.body.decode(enc, errors="replace")
        except LookupError:
            return self.body.decode("utf-8", errors="replace")


class _CachedResult:
    """Same read interface as FetchResult (.final_url/.status/.content_type/
    .truncated/.text), built from a cache record instead of a live fetch."""

    def __init__(self, final_url, status, content_type, truncated, body_text, fetched_at):
        self.final_url = final_url
        self.status = status
        self.content_type = content_type
        self.truncated = truncated
        self.text = body_text
        self.fetched_at = fetched_at


def _charset_from_content_type(ct):
    if not ct:
        return None
    m = re.search(r"charset=([^\s;]+)", ct, re.IGNORECASE)
    if m:
        return m.group(1).strip("\"'")
    return None


def _is_textual(content_type):
    ct = (content_type or "").lower()
    return "html" in ct or "text" in ct or "json" in ct or "xml" in ct or ct == ""


def _open_pinned(url, timeout, allow_private):
    parts = urllib.parse.urlsplit(url)
    scheme = parts.scheme.lower()
    host = parts.hostname
    port = parts.port or (443 if scheme == "https" else 80)
    resolved_ip = resolve_validated_ip(host, port, allow_private)

    path = parts.path or "/"
    if parts.query:
        path = path + "?" + parts.query

    headers = {
        "Host": _format_host_header(host, port),
        "User-Agent": USER_AGENT,
        "Accept": "text/html,application/xhtml+xml,application/xml,text/plain,application/json;q=0.9,*/*;q=0.5",
        "Connection": "close",
    }
    # Deliberately no Accept-Encoding here: http.client's own putrequest()
    # fills in "Accept-Encoding: identity" whenever the header is absent from
    # the caller's dict, which is exactly what we want -- a byte cap that
    # truncates mid-stream must never truncate a partially-decompressed gzip
    # frame. No credential header (Authorization/Cookie) is ever set, and
    # none is ever read from the environment.
    if scheme == "https":
        ctx = ssl.create_default_context()
        conn = _PinnedHTTPSConnection(host, port, resolved_ip, timeout, ctx)
    else:
        conn = _PinnedHTTPConnection(host, port, resolved_ip, timeout)
    conn.request("GET", path, headers=headers)
    resp = conn.getresponse()
    return resp, conn


def _read_capped(resp, max_bytes):
    chunks = []
    total = 0
    truncated = False
    while True:
        remaining = max_bytes - total
        if remaining <= 0:
            truncated = True
            break
        chunk = resp.read(min(65536, remaining))
        if not chunk:
            break
        chunks.append(chunk)
        total += len(chunk)
    return b"".join(chunks), truncated


def _safe_drain(resp):
    """Drain a response body before following a redirect. The connection is
    about to be closed either way, so a failure here is harmless -- but it
    must never propagate and abort the redirect chain. Returns True if the
    drain completed cleanly."""
    try:
        resp.read()
    except (socket.timeout, TimeoutError, OSError):
        return False
    return True


def _check_robots(url, timeout, allow_private, cache):
    parts = urllib.parse.urlsplit(url)
    origin_key = (parts.scheme, parts.netloc)
    if origin_key not in cache:
        robots_url = urllib.parse.urlunsplit((parts.scheme, parts.netloc, "/robots.txt", "", ""))
        rp = None
        try:
            result = fetch(robots_url, timeout=timeout, max_bytes=1_000_000,
                            allow_private=allow_private, ignore_robots=True)
            if result.status < 400:
                rp = urllib.robotparser.RobotFileParser()
                rp.parse(result.text.splitlines())
        except WebFetchError:
            rp = None  # unreachable robots.txt -> allow, standard convention
        cache[origin_key] = rp
    rp = cache[origin_key]
    if rp is not None and not rp.can_fetch(USER_AGENT, url):
        raise RobotsDisallowed(
            "robots.txt disallows fetching %r (pass --ignore-robots to override)" % url
        )


def fetch(url, timeout=DEFAULT_TIMEOUT, max_bytes=DEFAULT_MAX_BYTES, allow_private=False,
          ignore_robots=False, max_redirects=DEFAULT_MAX_REDIRECTS, robots_cache=None):
    """Fetch one URL through the full guard chain. Returns a FetchResult.
    Raises a WebFetchError subclass on refusal/failure -- never a partial
    success silently returned as if it were whole."""
    if robots_cache is None:
        robots_cache = {}
    current = url
    redirects_used = 0
    while True:
        parts = urllib.parse.urlsplit(current)
        scheme = parts.scheme.lower()
        if scheme not in ALLOWED_SCHEMES:
            raise SchemeRefused("refusing non-http(s) scheme %r in %r" % (scheme or "(none)", current))
        if not parts.hostname:
            raise SchemeRefused("no host in url %r" % current)
        if not ignore_robots:
            _check_robots(current, timeout, allow_private, robots_cache)

        conn = None
        try:
            try:
                resp, conn = _open_pinned(current, timeout, allow_private)
            except Refused:
                raise
            except (socket.timeout, TimeoutError, OSError, ssl.SSLError) as exc:
                raise FetchFailed("connection failed for %r: %s" % (current, exc)) from exc

            status = resp.status
            loc = resp.getheader("Location")
            if status in (301, 302, 303, 307, 308) and loc:
                redirects_used += 1
                if redirects_used > max_redirects:
                    raise TooManyRedirects(
                        "exceeded %d redirects starting at %r" % (max_redirects, url)
                    )
                nxt = urllib.parse.urljoin(current, loc)
                _safe_drain(resp)  # best-effort; connection is closing regardless
                current = nxt
                continue

            content_type = resp.getheader("Content-Type", "") or ""
            try:
                body, truncated = _read_capped(resp, max_bytes)
            except (socket.timeout, TimeoutError, OSError) as exc:
                raise FetchFailed("read failed for %r: %s" % (current, exc)) from exc

            return FetchResult(
                url=url, final_url=current, status=status,
                content_type=content_type, body=body, truncated=truncated,
            )
        finally:
            if conn is not None:
                conn.close()


def fetch_cached(url, use_cache, ttl, **fetch_kwargs):
    """Cache-aware wrapper over fetch(). Only the raw fetched text is cached
    (keyed by sha256(url), TTL-gated) -- markdown/meta conversion is always
    recomputed fresh from that text so a converter change benefits cached
    entries without needing cache invalidation. Only textual content types
    are cached; a binary response is fetched fresh every time."""
    if use_cache:
        cached = cache_get(url, ttl)
        if cached is not None:
            return _CachedResult(**cached), True
    result = fetch(url, **fetch_kwargs)
    if use_cache and _is_textual(result.content_type):
        cache_put(url, {
            "final_url": result.final_url,
            "status": result.status,
            "content_type": result.content_type,
            "truncated": result.truncated,
            "body_text": result.text,
            "fetched_at": time.time(),
        })
    return result, False


# --------------------------------------------------------------------------
# URL cache (file-based, TTL-gated, keyed by sha256(url))
# --------------------------------------------------------------------------

def _cache_dir():
    base = os.environ.get("HEIMDALL_HOME") or os.path.join(os.path.expanduser("~"), ".heimdall")
    return os.path.join(base, "web-cache")


def _cache_key(url):
    return hashlib.sha256(url.encode("utf-8")).hexdigest()


def cache_get(url, ttl):
    if not ttl or ttl <= 0:
        return None
    path = os.path.join(_cache_dir(), _cache_key(url) + ".json")
    try:
        with open(path, "r", encoding="utf-8") as fh:
            data = json.load(fh)
    except (OSError, ValueError):
        return None
    fetched_at = data.get("fetched_at", 0)
    if (time.time() - fetched_at) > ttl:
        return None
    required = ("final_url", "status", "content_type", "truncated", "body_text", "fetched_at")
    if not all(k in data for k in required):
        return None
    return {k: data[k] for k in required}


def cache_put(url, record):
    d = _cache_dir()
    try:
        os.makedirs(d, exist_ok=True)
        path = os.path.join(d, _cache_key(url) + ".json")
        tmp = path + ".tmp.%d" % os.getpid()
        with open(tmp, "w", encoding="utf-8") as fh:
            json.dump(record, fh)
        os.replace(tmp, path)
    except OSError:
        return  # caching is a best-effort optimization, never a hard failure


# --------------------------------------------------------------------------
# HTML -> clean markdown
# --------------------------------------------------------------------------

_SKIP_TAGS = {
    "script", "style", "noscript", "template", "nav", "header", "footer",
    "aside", "form", "iframe", "svg", "button", "select", "option",
    "object", "embed", "canvas", "video", "audio", "map",
}

_HEADING_LEVEL = {"h1": 1, "h2": 2, "h3": 3, "h4": 4, "h5": 5, "h6": 6}


def _safe_feed(parser, text):
    """Feed HTML into an html.parser.HTMLParser subclass, swallowing
    malformed-markup errors. HTMLParser is normally lenient, but a
    pathological document can still raise -- when it does, whatever the
    parser already extracted before the error must survive, since one bad
    page must never abort a fetch, crawl, or batch run. Returns True if
    feed() completed without raising."""
    try:
        parser.feed(text)
    except Exception:
        return False
    return True


class _MarkdownExtractor(html.parser.HTMLParser):
    """Streaming HTML -> markdown converter. Strips nav/script/style/forms/
    etc. entirely (never emitted, not even their text), keeps headings,
    paragraphs, lists, links, images, emphasis, and code blocks."""

    def __init__(self, base_url=None):
        super().__init__(convert_charrefs=True)
        self.base_url = base_url
        self._skip_stack = []
        self._out = []
        self._link_href_stack = []
        self._in_title = False
        self.title = ""
        self._pre_depth = 0
        self._list_stack = []

    def handle_starttag(self, tag, attrs):
        tag = tag.lower()
        d = dict(attrs)
        if tag in _SKIP_TAGS:
            self._skip_stack.append(tag)
            return
        if self._skip_stack:
            return
        if tag == "title":
            self._in_title = True
            return
        if tag in _HEADING_LEVEL:
            self._out.append("\n\n" + "#" * _HEADING_LEVEL[tag] + " ")
            return
        if tag == "p":
            self._out.append("\n\n")
            return
        if tag == "br":
            self._out.append("  \n")
            return
        if tag == "hr":
            self._out.append("\n\n---\n\n")
            return
        if tag in ("strong", "b"):
            self._out.append("**")
            return
        if tag in ("em", "i"):
            self._out.append("*")
            return
        if tag == "pre":
            self._pre_depth += 1
            self._out.append("\n\n```\n")
            return
        if tag == "code" and self._pre_depth == 0:
            self._out.append("`")
            return
        if tag == "blockquote":
            self._out.append("\n\n> ")
            return
        if tag in ("ul", "ol"):
            self._list_stack.append([tag, 0])
            self._out.append("\n")
            return
        if tag == "li":
            depth = max(1, len(self._list_stack))
            indent = "  " * (depth - 1)
            if self._list_stack and self._list_stack[-1][0] == "ol":
                self._list_stack[-1][1] += 1
                marker = "%d." % self._list_stack[-1][1]
            else:
                marker = "-"
            self._out.append("\n%s%s " % (indent, marker))
            return
        if tag == "a":
            href = d.get("href", "") or ""
            if href and self.base_url:
                href = urllib.parse.urljoin(self.base_url, href)
            self._link_href_stack.append(href)
            self._out.append("[")
            return
        if tag == "img":
            alt = d.get("alt", "") or ""
            src = d.get("src", "") or ""
            if src and self.base_url:
                src = urllib.parse.urljoin(self.base_url, src)
            self._out.append("![%s](%s)" % (alt, src))
            return

    def handle_endtag(self, tag):
        tag = tag.lower()
        if tag in _SKIP_TAGS:
            if self._skip_stack and self._skip_stack[-1] == tag:
                self._skip_stack.pop()
            return
        if self._skip_stack:
            return
        if tag == "title":
            self._in_title = False
            return
        if tag in ("strong", "b"):
            self._out.append("**")
            return
        if tag in ("em", "i"):
            self._out.append("*")
            return
        if tag == "pre":
            self._pre_depth = max(0, self._pre_depth - 1)
            self._out.append("\n```\n\n")
            return
        if tag == "code" and self._pre_depth == 0:
            self._out.append("`")
            return
        if tag in ("ul", "ol"):
            if self._list_stack:
                self._list_stack.pop()
            self._out.append("\n")
            return
        if tag == "a":
            href = self._link_href_stack.pop() if self._link_href_stack else ""
            self._out.append("](%s)" % href)
            return

    def handle_data(self, data):
        if self._skip_stack:
            return
        if self._in_title:
            self.title += data
            return
        if self._pre_depth > 0:
            self._out.append(data)
            return
        collapsed = re.sub(r"[ \t\r\n]+", " ", data)
        if collapsed == " " and (not self._out or self._out[-1].endswith((" ", "\n"))):
            return
        self._out.append(collapsed)

    def get_markdown(self):
        text = "".join(self._out)
        text = re.sub(r"\n{3,}", "\n\n", text)
        text = "\n".join(line.rstrip() for line in text.split("\n"))
        return text.strip() + "\n"


class _LinkExtractor(html.parser.HTMLParser):
    def __init__(self, base_url):
        super().__init__(convert_charrefs=True)
        self.base_url = base_url
        self.links = []

    def handle_starttag(self, tag, attrs):
        if tag.lower() != "a":
            return
        href = dict(attrs).get("href")
        if not href:
            return
        href = href.strip()
        low = href.lower()
        if not href or href.startswith("#") or low.startswith("javascript:") or low.startswith("mailto:"):
            return
        absolute = urllib.parse.urljoin(self.base_url, href)
        absolute, _frag = urllib.parse.urldefrag(absolute)
        self.links.append(absolute)


def extract_links(html_text, base_url):
    parser = _LinkExtractor(base_url)
    _safe_feed(parser, html_text)  # malformed HTML -> best-effort partial link list
    return parser.links


def _looks_like_html(content_type):
    ct = (content_type or "").lower()
    return "html" in ct or ct == ""


# --------------------------------------------------------------------------
# Structured metadata extraction
# --------------------------------------------------------------------------

class _MetaExtractor(html.parser.HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.title = ""
        self._in_title = False
        self.meta = {}
        self.og = {}
        self.twitter = {}
        self.canonical = None
        self.headings = []
        self._heading_stack = []
        self.jsonld_raw = []
        self._in_jsonld = False
        self._jsonld_buf = []

    def handle_starttag(self, tag, attrs):
        tag = tag.lower()
        d = dict(attrs)
        if tag == "title":
            self._in_title = True
            return
        if tag == "meta":
            name = (d.get("name") or d.get("property") or "").lower()
            content = d.get("content", "") or ""
            if not name:
                return
            if name.startswith("og:"):
                self.og[name] = content
            elif name.startswith("twitter:"):
                self.twitter[name] = content
            else:
                self.meta[name] = content
            return
        if tag == "link" and (d.get("rel") or "").lower() == "canonical":
            self.canonical = d.get("href")
            return
        if tag in _HEADING_LEVEL:
            self._heading_stack.append([tag, []])
            return
        if tag == "script" and (d.get("type") or "").lower() == "application/ld+json":
            self._in_jsonld = True
            self._jsonld_buf = []
            return

    def handle_endtag(self, tag):
        tag = tag.lower()
        if tag == "title":
            self._in_title = False
            return
        if tag in _HEADING_LEVEL and self._heading_stack:
            htag, parts = self._heading_stack.pop()
            text = "".join(parts).strip()
            if text:
                self.headings.append((_HEADING_LEVEL[htag], text))
            return
        if tag == "script" and self._in_jsonld:
            self._in_jsonld = False
            raw = "".join(self._jsonld_buf).strip()
            if raw:
                self.jsonld_raw.append(raw)
            return

    def handle_data(self, data):
        if self._in_title:
            self.title += data
        if self._in_jsonld:
            self._jsonld_buf.append(data)
        if self._heading_stack:
            self._heading_stack[-1][1].append(data)


def extract_meta(html_text, base_url=None):
    parser = _MetaExtractor()
    _safe_feed(parser, html_text)  # malformed HTML -> extract whatever parsed before the error
    jsonld = []
    for raw in parser.jsonld_raw:
        try:
            jsonld.append(json.loads(raw))
        except (ValueError, TypeError):
            continue  # malformed JSON-LD block -> skipped, not fatal
    canonical = parser.canonical
    if canonical and base_url:
        canonical = urllib.parse.urljoin(base_url, canonical)
    return {
        "title": parser.title.strip(),
        "description": parser.meta.get("description", ""),
        "canonical": canonical,
        "og": parser.og,
        "twitter": parser.twitter,
        "headings": [{"level": lvl, "text": txt} for lvl, txt in parser.headings],
        "jsonld": jsonld,
    }


# --------------------------------------------------------------------------
# Bounded crawl
# --------------------------------------------------------------------------

@dataclass
class CrawlPage:
    url: str
    final_url: str
    depth: int
    status: int
    bytes: int
    truncated: bool
    title: str
    markdown: str
    error: str = ""


def crawl(seed_url, max_depth=DEFAULT_CRAWL_MAX_DEPTH, max_pages=DEFAULT_CRAWL_MAX_PAGES,
          max_page_bytes=DEFAULT_MAX_BYTES, max_total_bytes=DEFAULT_CRAWL_MAX_TOTAL_BYTES,
          same_domain_only=True, allow_private=False, ignore_robots=False,
          timeout=DEFAULT_TIMEOUT, wall_clock_budget=DEFAULT_CRAWL_WALL_CLOCK):
    seed_parts = urllib.parse.urlsplit(seed_url)
    if seed_parts.scheme.lower() not in ALLOWED_SCHEMES:
        raise SchemeRefused("refusing non-http(s) scheme in seed %r" % seed_url)
    seed_domain = seed_parts.netloc.lower()
    robots_cache = {}
    visited = set()
    queue = collections.deque([(seed_url, 0)])
    pages = []
    total_bytes = 0
    start = time.monotonic()

    def norm(u):
        u2, _ = urllib.parse.urldefrag(u)
        return u2

    while queue and len(pages) < max_pages:
        if time.monotonic() - start > wall_clock_budget:
            break
        url, depth = queue.popleft()
        key = norm(url)
        if key in visited:
            continue
        visited.add(key)
        try:
            result = fetch(url, timeout=timeout, max_bytes=max_page_bytes,
                            allow_private=allow_private, ignore_robots=ignore_robots,
                            robots_cache=robots_cache)
        except WebFetchError as exc:
            pages.append(CrawlPage(url=url, final_url=url, depth=depth, status=0,
                                    bytes=0, truncated=False, title="", markdown="",
                                    error=str(exc)))
            continue
        text = result.text
        md_parser = _MarkdownExtractor(base_url=result.final_url)
        _safe_feed(md_parser, text)  # malformed HTML on one page must not abort the crawl
        markdown = md_parser.get_markdown()
        total_bytes += len(result.body)
        pages.append(CrawlPage(
            url=url, final_url=result.final_url, depth=depth, status=result.status,
            bytes=len(result.body), truncated=result.truncated,
            title=md_parser.title.strip(), markdown=markdown,
        ))
        if len(pages) >= max_pages or total_bytes >= max_total_bytes:
            break
        if depth < max_depth and _looks_like_html(result.content_type):
            for link in extract_links(text, result.final_url):
                lp = urllib.parse.urlsplit(link)
                if lp.scheme.lower() not in ALLOWED_SCHEMES:
                    continue
                if same_domain_only and lp.netloc.lower() != seed_domain:
                    continue
                if norm(link) not in visited:
                    queue.append((link, depth + 1))
    return pages


# --------------------------------------------------------------------------
# Concurrent batch fetch
# --------------------------------------------------------------------------

def batch_fetch(urls, concurrency=DEFAULT_BATCH_CONCURRENCY, timeout=DEFAULT_TIMEOUT,
                 max_bytes=DEFAULT_MAX_BYTES, allow_private=False, ignore_robots=False,
                 wall_clock_budget=None, use_cache=True, ttl=DEFAULT_CACHE_TTL):
    robots_cache = {}

    def one(u):
        try:
            result, cached = fetch_cached(
                u, use_cache, ttl, timeout=timeout, max_bytes=max_bytes,
                allow_private=allow_private, ignore_robots=ignore_robots,
                robots_cache=robots_cache,
            )
            text = result.text
            parser = _MarkdownExtractor(base_url=result.final_url)
            _safe_feed(parser, text)  # malformed HTML on one URL must not fail the batch
            return {
                "url": u, "final_url": result.final_url, "status": result.status,
                "truncated": result.truncated, "bytes": len(text.encode("utf-8")),
                "title": parser.title.strip(), "markdown": parser.get_markdown(),
                "cached": cached,
            }
        except WebFetchError as exc:
            return {"url": u, "error": str(exc)}

    results = {}
    start = time.monotonic()
    with concurrent.futures.ThreadPoolExecutor(max_workers=max(1, concurrency)) as ex:
        futs = {ex.submit(one, u): u for u in urls}
        pending = set(futs)
        while pending:
            remaining = None
            if wall_clock_budget is not None:
                remaining = wall_clock_budget - (time.monotonic() - start)
                if remaining <= 0:
                    break
            try:
                for fut in concurrent.futures.as_completed(pending, timeout=remaining):
                    results[futs[fut]] = fut.result()
                    pending.discard(fut)
            except concurrent.futures.TimeoutError:
                break
        for fut in pending:
            u = futs[fut]
            results.setdefault(u, {"url": u, "error": "batch wall-clock budget exceeded"})
    return [results.get(u, {"url": u, "error": "not completed"}) for u in urls]


# --------------------------------------------------------------------------
# CLI
# --------------------------------------------------------------------------

USAGE = """usage: web_fetch.py <command> [options]

commands:
  fetch <url>     fetch one URL, print clean markdown (or JSON with --json)
  crawl <url>     bounded crawl from a seed URL, same-domain by default
  batch <url...>  fetch many URLs concurrently (or --list FILE)
  meta <url>      structured metadata: title/description/OG/canonical/JSON-LD/headings

common options (fetch/crawl/batch/meta):
  --timeout SECS       per-request timeout (default 15)
  --max-bytes N        per-page byte cap (default 2097152 = 2MiB)
  --allow-private      opt in to loopback/private-range addresses (local testing;
                        refused by default -- SSRF guard)
  --ignore-robots      override robots.txt (respected by default)
  --no-cache           skip the URL cache
  --ttl SECS           cache TTL in seconds (default 900); 0 disables caching

fetch-only:
  --json               emit JSON instead of plain markdown
  -o, --out FILE        write output to FILE instead of stdout

crawl-only:
  --max-depth N         max link-follow depth from the seed (default 2)
  --max-pages N         max pages fetched in one run (default 20)
  --max-total-bytes N   per-run byte ceiling across all pages (default 20MiB)
  --allow-external      follow links off the seed's domain (default: same-domain only)
  --wall-clock SECS     total wall-clock budget for the whole crawl (default 60)
  -o, --out DIR         write one .md file per page + index.json manifest into DIR

batch-only:
  --list FILE           read URLs from FILE (one per line) instead of argv
  --concurrency N       max concurrent fetches (default 4)
  --wall-clock SECS     total wall-clock budget for the whole batch (default 60)

Never sends credentials: no Authorization/Cookie headers, no env-var secrets.
Refuses non-http(s) schemes and (by default) loopback/private-range addresses.
"""


def _next(args, i, name):
    if i >= len(args):
        raise _UsageError("%s needs a value" % name)
    return args[i]


def _next_int(args, i, name):
    v = _next(args, i, name)
    try:
        return int(v)
    except ValueError:
        raise _UsageError("%s expects an integer, got %r" % (name, v))


def cmd_fetch(args):
    url = None
    timeout = DEFAULT_TIMEOUT
    max_bytes = DEFAULT_MAX_BYTES
    allow_private = False
    ignore_robots = False
    use_cache = True
    ttl = DEFAULT_CACHE_TTL
    as_json = False
    out = None
    i = 0
    while i < len(args):
        a = args[i]
        if a == "--timeout":
            i += 1; timeout = _next_int(args, i, a)
        elif a == "--max-bytes":
            i += 1; max_bytes = _next_int(args, i, a)
        elif a == "--allow-private":
            allow_private = True
        elif a == "--ignore-robots":
            ignore_robots = True
        elif a == "--no-cache":
            use_cache = False
        elif a == "--ttl":
            i += 1; ttl = _next_int(args, i, a)
        elif a == "--json":
            as_json = True
        elif a in ("-o", "--out"):
            i += 1; out = _next(args, i, a)
        elif a in ("-h", "--help"):
            sys.stdout.write(USAGE)
            return 0
        elif a.startswith("-"):
            sys.stderr.write("web_fetch fetch: unknown option: %s\n" % a)
            return 2
        elif url is None:
            url = a
        else:
            sys.stderr.write("web_fetch fetch: unexpected extra argument: %s\n" % a)
            return 2
        i += 1
    if url is None:
        sys.stderr.write(USAGE)
        return 2
    try:
        result, cached = fetch_cached(url, use_cache, ttl, timeout=timeout, max_bytes=max_bytes,
                                       allow_private=allow_private, ignore_robots=ignore_robots)
    except Refused as exc:
        sys.stderr.write("web_fetch: REFUSED -- %s\n" % exc)
        return 4
    except WebFetchError as exc:
        sys.stderr.write("web_fetch: ERROR -- %s\n" % exc)
        return 5
    parser = _MarkdownExtractor(base_url=result.final_url)
    _safe_feed(parser, result.text)  # malformed HTML must still yield recoverable markdown
    markdown = parser.get_markdown()
    if as_json:
        payload = {
            "url": url, "final_url": result.final_url, "status": result.status,
            "truncated": result.truncated, "cached": cached, "title": parser.title.strip(),
            "markdown": markdown,
        }
        text_out = json.dumps(payload, ensure_ascii=False) + "\n"
    else:
        text_out = markdown
    if out:
        with open(out, "w", encoding="utf-8") as fh:
            fh.write(text_out)
        sys.stderr.write("web_fetch: wrote %s (%d chars)\n" % (out, len(text_out)))
    else:
        sys.stdout.write(text_out)
    return 0


def cmd_crawl(args):
    seed = None
    timeout = DEFAULT_TIMEOUT
    max_page_bytes = DEFAULT_MAX_BYTES
    max_depth = DEFAULT_CRAWL_MAX_DEPTH
    max_pages = DEFAULT_CRAWL_MAX_PAGES
    max_total_bytes = DEFAULT_CRAWL_MAX_TOTAL_BYTES
    same_domain_only = True
    allow_private = False
    ignore_robots = False
    wall_clock = DEFAULT_CRAWL_WALL_CLOCK
    out_dir = None
    i = 0
    while i < len(args):
        a = args[i]
        if a == "--timeout":
            i += 1; timeout = _next_int(args, i, a)
        elif a == "--max-bytes-per-page":
            i += 1; max_page_bytes = _next_int(args, i, a)
        elif a == "--max-depth":
            i += 1; max_depth = _next_int(args, i, a)
        elif a == "--max-pages":
            i += 1; max_pages = _next_int(args, i, a)
        elif a == "--max-total-bytes":
            i += 1; max_total_bytes = _next_int(args, i, a)
        elif a == "--allow-external":
            same_domain_only = False
        elif a == "--allow-private":
            allow_private = True
        elif a == "--ignore-robots":
            ignore_robots = True
        elif a == "--wall-clock":
            i += 1; wall_clock = _next_int(args, i, a)
        elif a in ("-o", "--out"):
            i += 1; out_dir = _next(args, i, a)
        elif a in ("-h", "--help"):
            sys.stdout.write(USAGE)
            return 0
        elif a.startswith("-"):
            sys.stderr.write("web_fetch crawl: unknown option: %s\n" % a)
            return 2
        elif seed is None:
            seed = a
        else:
            sys.stderr.write("web_fetch crawl: unexpected extra argument: %s\n" % a)
            return 2
        i += 1
    if seed is None:
        sys.stderr.write(USAGE)
        return 2
    try:
        pages = crawl(seed, max_depth=max_depth, max_pages=max_pages,
                       max_page_bytes=max_page_bytes, max_total_bytes=max_total_bytes,
                       same_domain_only=same_domain_only, allow_private=allow_private,
                       ignore_robots=ignore_robots, timeout=timeout, wall_clock_budget=wall_clock)
    except Refused as exc:
        sys.stderr.write("web_fetch: REFUSED -- %s\n" % exc)
        return 4
    except WebFetchError as exc:
        sys.stderr.write("web_fetch: ERROR -- %s\n" % exc)
        return 5

    manifest = []
    if out_dir:
        os.makedirs(out_dir, exist_ok=True)
    for idx, p in enumerate(pages):
        entry = {
            "url": p.url, "final_url": p.final_url, "depth": p.depth, "status": p.status,
            "bytes": p.bytes, "truncated": p.truncated, "title": p.title,
        }
        if p.error:
            entry["error"] = p.error
        elif out_dir:
            slug = re.sub(r"[^A-Za-z0-9]+", "-", p.final_url).strip("-")[:80] or "page"
            fname = "%03d-%s.md" % (idx, slug)
            with open(os.path.join(out_dir, fname), "w", encoding="utf-8") as fh:
                fh.write("<!-- %s (status %s) -->\n\n" % (p.final_url, p.status))
                fh.write(p.markdown)
            entry["file"] = fname
        else:
            entry["markdown"] = p.markdown
        manifest.append(entry)
    if out_dir:
        with open(os.path.join(out_dir, "index.json"), "w", encoding="utf-8") as fh:
            json.dump(manifest, fh, ensure_ascii=False, indent=2)
        sys.stdout.write(json.dumps({"pages": len(pages), "out_dir": out_dir}, ensure_ascii=False) + "\n")
    else:
        sys.stdout.write(json.dumps(manifest, ensure_ascii=False) + "\n")
    return 0


def cmd_batch(args):
    urls = []
    list_file = None
    timeout = DEFAULT_TIMEOUT
    max_bytes = DEFAULT_MAX_BYTES
    concurrency = DEFAULT_BATCH_CONCURRENCY
    allow_private = False
    ignore_robots = False
    use_cache = True
    ttl = DEFAULT_CACHE_TTL
    wall_clock = DEFAULT_BATCH_WALL_CLOCK
    i = 0
    while i < len(args):
        a = args[i]
        if a == "--list":
            i += 1; list_file = _next(args, i, a)
        elif a == "--timeout":
            i += 1; timeout = _next_int(args, i, a)
        elif a == "--max-bytes":
            i += 1; max_bytes = _next_int(args, i, a)
        elif a == "--concurrency":
            i += 1; concurrency = _next_int(args, i, a)
        elif a == "--allow-private":
            allow_private = True
        elif a == "--ignore-robots":
            ignore_robots = True
        elif a == "--no-cache":
            use_cache = False
        elif a == "--ttl":
            i += 1; ttl = _next_int(args, i, a)
        elif a == "--wall-clock":
            i += 1; wall_clock = _next_int(args, i, a)
        elif a in ("-h", "--help"):
            sys.stdout.write(USAGE)
            return 0
        elif a.startswith("-"):
            sys.stderr.write("web_fetch batch: unknown option: %s\n" % a)
            return 2
        else:
            urls.append(a)
        i += 1
    if list_file:
        try:
            with open(list_file, "r", encoding="utf-8") as fh:
                for line in fh:
                    line = line.strip()
                    if line and not line.startswith("#"):
                        urls.append(line)
        except OSError as exc:
            sys.stderr.write("web_fetch batch: cannot read --list file: %s\n" % exc)
            return 2
    if not urls:
        sys.stderr.write(USAGE)
        return 2
    results = batch_fetch(urls, concurrency=concurrency, timeout=timeout, max_bytes=max_bytes,
                           allow_private=allow_private, ignore_robots=ignore_robots,
                           wall_clock_budget=wall_clock, use_cache=use_cache, ttl=ttl)
    sys.stdout.write(json.dumps(results, ensure_ascii=False) + "\n")
    return 0


def cmd_meta(args):
    url = None
    timeout = DEFAULT_TIMEOUT
    max_bytes = DEFAULT_MAX_BYTES
    allow_private = False
    ignore_robots = False
    use_cache = True
    ttl = DEFAULT_CACHE_TTL
    i = 0
    while i < len(args):
        a = args[i]
        if a == "--timeout":
            i += 1; timeout = _next_int(args, i, a)
        elif a == "--max-bytes":
            i += 1; max_bytes = _next_int(args, i, a)
        elif a == "--allow-private":
            allow_private = True
        elif a == "--ignore-robots":
            ignore_robots = True
        elif a == "--no-cache":
            use_cache = False
        elif a == "--ttl":
            i += 1; ttl = _next_int(args, i, a)
        elif a in ("-h", "--help"):
            sys.stdout.write(USAGE)
            return 0
        elif a.startswith("-"):
            sys.stderr.write("web_fetch meta: unknown option: %s\n" % a)
            return 2
        elif url is None:
            url = a
        else:
            sys.stderr.write("web_fetch meta: unexpected extra argument: %s\n" % a)
            return 2
        i += 1
    if url is None:
        sys.stderr.write(USAGE)
        return 2
    try:
        result, cached = fetch_cached(url, use_cache, ttl, timeout=timeout, max_bytes=max_bytes,
                                       allow_private=allow_private, ignore_robots=ignore_robots)
    except Refused as exc:
        sys.stderr.write("web_fetch: REFUSED -- %s\n" % exc)
        return 4
    except WebFetchError as exc:
        sys.stderr.write("web_fetch: ERROR -- %s\n" % exc)
        return 5
    meta = extract_meta(result.text, base_url=result.final_url)
    meta["url"] = url
    meta["final_url"] = result.final_url
    meta["cached"] = cached
    sys.stdout.write(json.dumps(meta, ensure_ascii=False) + "\n")
    return 0


def main(argv):
    if len(argv) < 2:
        sys.stderr.write(USAGE)
        return 2
    cmd = argv[1]
    rest = argv[2:]
    try:
        if cmd == "fetch":
            return cmd_fetch(rest)
        if cmd == "crawl":
            return cmd_crawl(rest)
        if cmd == "batch":
            return cmd_batch(rest)
        if cmd == "meta":
            return cmd_meta(rest)
        if cmd in ("-h", "--help"):
            sys.stdout.write(USAGE)
            return 0
        sys.stderr.write("web_fetch: unknown command: %s\n" % cmd)
        sys.stderr.write(USAGE)
        return 2
    except _UsageError as exc:
        sys.stderr.write("web_fetch %s: %s\n" % (cmd, exc))
        return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
