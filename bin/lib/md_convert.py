#!/usr/bin/env python3
# md_convert.py — the real engine behind `bin/heimdall-md`.
#
# Converts a LOCAL document (PDF / Word / Excel / PowerPoint / HTML / CSV /
# JSON / XML / …) to clean, token-efficient Markdown for Heimdall's context
# building, using `microsoft/markitdown` (>= 0.1.6, MIT) as the deterministic
# converter.
#
# SECURITY IS FIRST-CLASS HERE. Document conversion is an attack surface: a
# malicious doc must NOT become a fetch primitive, and an agent-influenced path
# must NOT read outside an allowed root. The guards below are the point of this
# module — the conversion itself is one narrow call.
#
#   1. NARROWEST API — we call markitdown's `convert_local()` for local files and
#      `convert_stream()` for controlled bytes. We NEVER call the permissive
#      `convert()` (which dispatches on URIs, fetches remote http(s)/data URIs,
#      and follows redirects). The conversion target is always a concrete local
#      file we have already resolved + validated.
#   2. PATH SANITIZATION — the input path is resolved (symlinks followed) to a
#      real absolute path and must live inside an allowed root. A `..` escape, an
#      absolute path outside the root, or a symlink that points outside the root
#      is REFUSED before markitdown ever opens the file.
#   3. SSRF / REMOTE-URI REFUSAL — any input that looks like a URI (http, https,
#      ftp, file, data, …) is REFUSED. A bare hostname/IP that resolves to a
#      private / loopback / link-local / metadata (169.254.169.254) address is
#      REFUSED. Conversion never performs network I/O.
#   4. LAZY / OPTIONAL — markitdown is imported lazily inside the convert call.
#      If it is absent, we raise `MarkItDownUnavailable` so the caller can SKIP
#      gracefully (clean message, clean exit) without crashing. The base install
#      and the stranger-test never depend on markitdown being present.
#   5. EMBEDDED-RESOURCE EGRESS KILL — guard (3) blocks the INPUT being a remote
#      reference, but markitdown's HTML/RSS/Wikipedia/YouTube converters can be
#      backed by a requests.Session and may dereference URLs embedded INSIDE a
#      document (an <img>, iframe, remote stylesheet, or a metadata URL). We pass
#      markitdown an OFFLINE requests.Session whose HTTP adapter raises on every
#      send, so zero network I/O can occur regardless of converter version.
#   6. RESOURCE BOUNDS (DoS) — a tiny ZIP-backed Office file or a billion-laughs
#      XML can OOM/hang the process. We refuse oversize input (HEIMDALL_MD_MAX_BYTES,
#      default 50 MiB) BEFORE any read, and bound conversion wall-clock time
#      (HEIMDALL_MD_TIMEOUT_SECONDS, default 60 s) so an expansion bomb cannot hang.
#
# This module never shells out. With the offline session in place it never opens
# a network socket either. It is a pure function of (path, allowed_root) →
# markdown, with every guard applied first.

import ipaddress
import os
import signal
import socket
import sys
import threading
import urllib.parse


# ── resource bounds (DoS guard) ───────────────────────────────────────────────
#
# A document is an attack surface for resource exhaustion as well as for egress.
# A tiny ZIP-backed Office file (docx/xlsx/pptx) or an XML with nested entities
# (the "billion laughs") can decompress / expand to gigabytes and OOM or hang the
# process. We bound BOTH the input size (refused before any read) and the
# wall-clock conversion time. Both are stdlib-only and configurable via env.

# Default maximum input size: 50 MiB. A real spec / report / sheet is comfortably
# under this; anything larger is refused BEFORE markitdown opens the file.
_DEFAULT_MAX_BYTES = 50 * 1024 * 1024

# Default wall-clock conversion budget: 60 s. A decompression bomb that expands
# forever is cut off here rather than hanging the run indefinitely.
_DEFAULT_TIMEOUT_SECONDS = 60


def _max_bytes():
    """The input-size cap in bytes, overridable via HEIMDALL_MD_MAX_BYTES. A
    non-positive / unparseable value falls back to the default (never unbounded)."""
    raw = os.environ.get("HEIMDALL_MD_MAX_BYTES")
    if raw is None:
        return _DEFAULT_MAX_BYTES
    try:
        val = int(str(raw).strip())
    except (TypeError, ValueError):
        return _DEFAULT_MAX_BYTES
    return val if val > 0 else _DEFAULT_MAX_BYTES


def _timeout_seconds():
    """The wall-clock conversion budget in seconds, overridable via
    HEIMDALL_MD_TIMEOUT_SECONDS. A non-positive / unparseable value falls back to
    the default (never unbounded)."""
    raw = os.environ.get("HEIMDALL_MD_TIMEOUT_SECONDS")
    if raw is None:
        return _DEFAULT_TIMEOUT_SECONDS
    try:
        val = int(str(raw).strip())
    except (TypeError, ValueError):
        return _DEFAULT_TIMEOUT_SECONDS
    return val if val > 0 else _DEFAULT_TIMEOUT_SECONDS


# ── error taxonomy ────────────────────────────────────────────────────────────


class ConvertError(Exception):
    """Base for every conversion-layer error."""


class MarkItDownUnavailable(ConvertError):
    """markitdown is not installed — the caller should SKIP gracefully."""


class UnsafePathError(ConvertError):
    """The requested path is outside the allowed root / escapes via symlink."""


class RemoteRefused(ConvertError):
    """The input is a remote URI / SSRF vector — refused, never fetched."""


class UnsupportedInput(ConvertError):
    """The input is not a regular local file we can convert."""


class OversizeRefused(UnsupportedInput):
    """The input exceeds the size cap — refused BEFORE any read (a resource gate,
    a subclass of UnsupportedInput so it travels the existing refusal path)."""


class ConversionTimeout(ConvertError):
    """Conversion exceeded the wall-clock budget — refused cleanly (no partial
    output). Guards against decompression bombs that would otherwise hang."""


# ── SSRF / remote-URI guard ───────────────────────────────────────────────────

# Schemes that denote a NETWORK or otherwise non-local fetch. `file` is included
# deliberately: we accept plain filesystem PATHS, not `file://` URIs (which can
# encode hosts / UNC paths). A drive-letter like `C:` is NOT a scheme we block
# (handled below), but a multi-char alpha scheme followed by `://` or an opaque
# `data:`/`javascript:` body is.
_BLOCKED_SCHEMES = {
    "http", "https", "ftp", "ftps", "file", "data", "blob", "ws", "wss",
    "gopher", "dict", "ldap", "ldaps", "tftp", "sftp", "ssh", "smb", "view-source",
    "javascript", "vbscript", "about", "chrome", "res", "mailto", "tel",
}


def _looks_like_uri(s):
    """True if `s` carries a URI scheme we must refuse. We parse the scheme and
    reject anything in _BLOCKED_SCHEMES, plus any scheme used with an authority
    (`scheme://…`). A bare Windows drive path (`C:\\x`) has a single-letter
    scheme and no `//` and is NOT treated as a URI here."""
    parsed = urllib.parse.urlsplit(s)
    scheme = parsed.scheme.lower()
    if not scheme:
        return False
    # Single-letter scheme with no authority → Windows drive path, not a URI.
    if len(scheme) == 1 and "://" not in s:
        return False
    if scheme in _BLOCKED_SCHEMES:
        return True
    # Any scheme presented with an authority (`scheme://host`) is a network URI.
    if parsed.netloc:
        return True
    # An opaque scheme with a body (`scheme:something`) that is not a drive path
    # is suspicious — refuse it rather than hand it to the converter.
    if parsed.path and not parsed.path.startswith(("/", ".", os.sep)):
        return True
    return False


def _ip_is_blocked(ip_str):
    """True if an IP literal is in a private / loopback / link-local / reserved /
    metadata range. Covers the 169.254.169.254 cloud-metadata vector explicitly
    (it is link-local, but we name it for clarity)."""
    try:
        ip = ipaddress.ip_address(ip_str)
    except ValueError:
        return False
    return (
        ip.is_private
        or ip.is_loopback
        or ip.is_link_local
        or ip.is_reserved
        or ip.is_multicast
        or ip.is_unspecified
        or str(ip) == "169.254.169.254"
    )


def _host_is_blocked(host):
    """Resolve a hostname and refuse if ANY resolved address is in a blocked
    range. Refuse on resolution failure too (fail closed)."""
    host = host.strip().strip("[]")  # tolerate bracketed IPv6
    if not host:
        return True
    if _ip_is_blocked(host):
        return True
    # Obvious metadata / localhost names.
    low = host.lower()
    if low in ("localhost", "metadata", "metadata.google.internal"):
        return True
    try:
        infos = socket.getaddrinfo(host, None)
    except (socket.gaierror, UnicodeError, socket.error):
        return True  # cannot resolve → fail closed
    for info in infos:
        addr = info[4][0]
        if _ip_is_blocked(addr):
            return True
    return False


def assert_not_remote(raw_input):
    """Raise RemoteRefused if `raw_input` is a remote URI or an SSRF vector.
    This is the network gate: a malicious doc reference must never become a
    fetch. We refuse the URI form outright; for a bare host we refuse private /
    loopback / link-local / metadata targets."""
    s = str(raw_input).strip()
    if not s:
        raise UnsupportedInput("empty input")
    if _looks_like_uri(s):
        raise RemoteRefused(
            "remote/URI input refused (narrowest-API: local files only): %r" % s
        )
    # A bare `//host/share` UNC path or a `host:port` form: refuse if the host
    # side is a blocked target.
    if s.startswith("//") or s.startswith("\\\\"):
        host = s.lstrip("/\\").split("/", 1)[0].split("\\", 1)[0]
        if _host_is_blocked(host):
            raise RemoteRefused("UNC/remote host refused: %r" % s)
    return None


# ── path sanitization ─────────────────────────────────────────────────────────


def _default_root():
    """Default allowed root: the current working directory. A task's document
    references are expected to live inside the project tree."""
    return os.path.realpath(os.getcwd())


def sanitize_path(raw_path, allowed_root=None):
    """Resolve `raw_path` to a real absolute file path that lives inside
    `allowed_root`. Refuses:
      - remote/URI inputs (delegated to assert_not_remote),
      - paths that escape the root via `..` or an absolute jump,
      - symlinks whose real target is outside the root,
      - non-regular-file targets (dirs, devices, FIFOs, missing files).

    Returns the validated real path."""
    assert_not_remote(raw_path)

    root = os.path.realpath(allowed_root) if allowed_root else _default_root()

    # Expand a leading ~ to the user's home ONLY when the root permits it; the
    # realpath check below is the actual boundary, so this is just convenience.
    candidate = os.path.expanduser(str(raw_path))
    if not os.path.isabs(candidate):
        candidate = os.path.join(root, candidate)

    # realpath resolves symlinks AND collapses `..` — so a symlink that points
    # outside the root, or a `../../etc/passwd`, lands on its true location and
    # the containment check below catches it.
    real = os.path.realpath(candidate)

    # Containment: real must equal root or be a descendant of root. Compare on
    # path components so `/a/rootEVIL` is not accepted for root `/a/root`.
    root_norm = os.path.normpath(root)
    real_norm = os.path.normpath(real)
    if real_norm != root_norm and not real_norm.startswith(root_norm + os.sep):
        raise UnsafePathError(
            "path escapes the allowed root: %r resolves to %r (root=%r)"
            % (raw_path, real_norm, root_norm)
        )

    if not os.path.exists(real_norm):
        raise UnsupportedInput("no such file: %r" % raw_path)
    if not os.path.isfile(real_norm):
        raise UnsupportedInput("not a regular file: %r" % raw_path)

    return real_norm


# ── markitdown invocation (lazy, narrowest API) ───────────────────────────────


def _load_markitdown():
    """Import markitdown lazily and enforce the pinned minimum version. Raises
    MarkItDownUnavailable when the package is absent or too old, so the caller
    can SKIP gracefully instead of crashing."""
    try:
        import markitdown  # noqa: F401  (imported for version + class)
        from markitdown import MarkItDown
    except Exception as exc:  # ImportError, or a broken optional-dep import
        raise MarkItDownUnavailable(
            "markitdown is not installed (pip install 'markitdown[pdf,docx,pptx,xlsx]>=0.1.6'): %s"
            % exc
        )

    ver = getattr(markitdown, "__version__", None)
    if ver is not None and _version_tuple(ver) < (0, 1, 6):
        raise MarkItDownUnavailable(
            "markitdown %s is too old; pin >= 0.1.6 (the narrowest-API release)" % ver
        )
    return MarkItDown


def _version_tuple(ver):
    parts = []
    for chunk in str(ver).split("."):
        num = ""
        for ch in chunk:
            if ch.isdigit():
                num += ch
            else:
                break
        parts.append(int(num) if num else 0)
    while len(parts) < 3:
        parts.append(0)
    return tuple(parts[:3])


def markitdown_available():
    """True if a usable, version-pinned markitdown is importable. Never raises."""
    try:
        _load_markitdown()
        return True
    except MarkItDownUnavailable:
        return False


class _EgressBlocked(Exception):
    """Raised by the offline adapter for ANY outbound request — the egress kill
    that makes embedded-resource SSRF impossible regardless of converter version."""


def build_offline_session():
    """Build a requests.Session that refuses EVERY outbound request.

    markitdown's HTML / RSS / Wikipedia / YouTube converters can be backed by a
    `requests.Session`. A malicious HTML / SVG / doc embedding an `<img>`, iframe,
    remote stylesheet, or a metadata URL (http://169.254.169.254/...) could egress
    IF the installed converter dereferences embedded URLs. We pass markitdown a
    session whose HTTP adapter raises on every send, so zero network I/O can occur
    no matter what an embedded resource references — belt-and-braces egress kill.

    Returns None when `requests` is not importable (markitdown then has no session
    to use, and convert_local remains local-only either way)."""
    try:
        import requests
        from requests.adapters import BaseAdapter
    except Exception:
        return None

    class _OfflineAdapter(BaseAdapter):
        # Every request — http / https / file / data / anything mounted — raises
        # immediately. No connection is ever opened.
        def send(self, request, *args, **kwargs):
            raise _EgressBlocked(
                "outbound request refused (offline session): %s"
                % getattr(request, "url", "<unknown>")
            )

        def close(self):
            return None

    session = requests.Session()
    adapter = _OfflineAdapter()
    # Mount on every scheme prefix markitdown could plausibly use, plus a bare
    # "" prefix that matches ALL urls as a catch-all — belt-and-braces.
    for prefix in ("http://", "https://", "file://", "data://", "ftp://", ""):
        session.mount(prefix, adapter)
    return session


def _build_converter(MarkItDown):
    """Construct a MarkItDown instance with network / plugin features OFF where the
    installed version exposes the toggle. Defence in depth on two axes:

      - plugins OFF: even though we only ever call convert_local(), an installed
        third-party converter must not widen the I/O surface.
      - offline session: an OFFLINE requests.Session is injected so that even if a
        converter dereferences a URL embedded INSIDE the document, the request is
        refused with zero egress (see build_offline_session). The kwarg exists in
        markitdown >= 0.0.1a3; a build lacking it still works (TypeError tolerance,
        mirroring the enable_plugins handling)."""
    offline = build_offline_session()
    # Try the richest signature first (plugins off + offline session), then peel
    # back kwargs the installed version may not accept. convert_local stays
    # local-only in every branch, so an older signature is still safe.
    attempts = []
    if offline is not None:
        attempts.append({"enable_plugins": False, "requests_session": offline})
    attempts.append({"enable_plugins": False})
    attempts.append({})
    last_exc = None
    for kwargs in attempts:
        try:
            return MarkItDown(**kwargs)
        except TypeError as exc:
            last_exc = exc
            continue
    # Should be unreachable (the empty-kwargs attempt cannot raise TypeError on a
    # zero-arg constructor), but never silently swallow a real construction error.
    raise ConvertError("could not construct MarkItDown converter: %s" % last_exc)


def _run_with_timeout(fn, seconds):
    """Run `fn()` under a wall-clock budget of `seconds`, raising
    ConversionTimeout if it overruns. Stdlib-only, no extra deps.

    Strategy: prefer signal.alarm (lowest overhead, truly interrupts the C-level
    work markitdown does) when we are on the main thread of a platform that has
    SIGALRM. Otherwise fall back to running `fn` on a worker thread and joining
    with a timeout — the worker cannot be force-killed, but the process no longer
    blocks on it and we refuse cleanly with no partial output returned."""
    use_alarm = (
        hasattr(signal, "SIGALRM")
        and threading.current_thread() is threading.main_thread()
    )
    if use_alarm:
        def _on_alarm(signum, frame):
            raise ConversionTimeout(
                "conversion exceeded %ds budget (possible decompression bomb)"
                % seconds
            )

        prev_handler = signal.signal(signal.SIGALRM, _on_alarm)
        # setitimer takes a float and supports sub-second budgets used by tests.
        prev_timer = signal.setitimer(signal.ITIMER_REAL, float(seconds))
        try:
            return fn()
        finally:
            signal.setitimer(signal.ITIMER_REAL, 0.0)
            signal.signal(signal.SIGALRM, prev_handler)
            # Restore any pre-existing timer the caller had armed.
            if prev_timer and prev_timer[0] > 0:
                signal.setitimer(signal.ITIMER_REAL, prev_timer[0])

    # Thread fallback (signals unavailable / not on main thread).
    box = {}
    error = {}

    def _worker():
        try:
            box["result"] = fn()
        except BaseException as exc:  # capture everything, re-raise on join
            error["exc"] = exc

    t = threading.Thread(target=_worker, daemon=True)
    t.start()
    t.join(float(seconds))
    if t.is_alive():
        raise ConversionTimeout(
            "conversion exceeded %ds budget (possible decompression bomb)" % seconds
        )
    if "exc" in error:
        raise error["exc"]
    return box.get("result")


def convert_file(raw_path, allowed_root=None):
    """Convert a LOCAL file to markdown. Applies the full guard chain
    (assert_not_remote → sanitize_path → size cap), then calls markitdown's
    narrowest local API under a wall-clock timeout. Returns the markdown text.

    Raises:
      RemoteRefused        — input was a remote URI / SSRF vector
      UnsafePathError      — path escaped the allowed root
      UnsupportedInput     — not a regular local file / unconvertible / oversize
      ConversionTimeout    — conversion overran the wall-clock budget
      MarkItDownUnavailable— markitdown absent (caller should SKIP)
      ConvertError         — conversion failed for another reason
    """
    safe_path = sanitize_path(raw_path, allowed_root)

    # DoS guard (a): refuse oversize input BEFORE any read / import / convert. A
    # 50 KB ZIP-backed docx/xlsx/pptx is small on disk but can decompress to GBs,
    # so this cap is on the ON-DISK size as a cheap first gate; the timeout below
    # is the second gate that bounds expansion that slips under the size cap.
    cap = _max_bytes()
    size = os.path.getsize(safe_path)
    if size > cap:
        raise OversizeRefused(
            "file too large: %d bytes exceeds cap %d (set HEIMDALL_MD_MAX_BYTES "
            "to override): %r" % (size, cap, raw_path)
        )

    MarkItDown = _load_markitdown()
    md = _build_converter(MarkItDown)

    # NARROWEST API: convert_local on a path we have already resolved + validated.
    # Never convert() (URI dispatch + remote fetch) and never a stream we did not
    # control. `convert_local` is markitdown's explicit local-file entrypoint.
    def _do_convert():
        if hasattr(md, "convert_local"):
            return md.convert_local(safe_path)
        # Belt-and-braces fallback for a pre-0.1.6 build lacking convert_local
        # (we pin >= 0.1.6, so this path is not expected): feed our OWN opened
        # bytes to convert_stream so dispatch is still on controlled local data,
        # never on a URI.
        with open(safe_path, "rb") as fh:
            return md.convert_stream(fh, file_extension=os.path.splitext(safe_path)[1])

    # DoS guard (b): bound conversion wall-clock so a decompression bomb that
    # slips under the size cap cannot hang the process forever.
    try:
        result = _run_with_timeout(_do_convert, _timeout_seconds())
    except (MarkItDownUnavailable, ConversionTimeout):
        raise
    except Exception as exc:
        raise ConvertError("markitdown failed to convert %r: %s" % (raw_path, exc))

    text = getattr(result, "text_content", None)
    if text is None:
        text = getattr(result, "markdown", None)
    if text is None:
        raise ConvertError("converter returned no markdown for %r" % raw_path)
    return text


def convert_bytes(data, file_extension=None):
    """Convert controlled in-memory BYTES to markdown via markitdown's
    convert_stream. No path, no network — for bytes the caller already trusts
    (e.g. a blob already read + bounded). `file_extension` (".html", ".csv", …)
    hints the converter when the bytes carry no name."""
    if not isinstance(data, (bytes, bytearray)):
        raise UnsupportedInput("convert_bytes expects bytes")
    MarkItDown = _load_markitdown()
    md = _build_converter(MarkItDown)
    import io

    stream = io.BytesIO(bytes(data))
    try:
        if file_extension is not None:
            result = md.convert_stream(stream, file_extension=file_extension)
        else:
            result = md.convert_stream(stream)
    except MarkItDownUnavailable:
        raise
    except Exception as exc:
        raise ConvertError("markitdown failed on byte stream: %s" % exc)
    text = getattr(result, "text_content", None)
    if text is None:
        text = getattr(result, "markdown", None)
    if text is None:
        raise ConvertError("converter returned no markdown for byte stream")
    return text


# ── CLI ────────────────────────────────────────────────────────────────────────
#
# Used by bin/heimdall-md. Exit codes:
#   0  converted (markdown on stdout or written to --out)
#   3  graceful SKIP — markitdown absent (NOT an error; the caller continues)
#   4  refused — remote/URI, unsafe path, OVERSIZE input, or conversion TIMEOUT
#      (a SECURITY / resource gate, hard fail — never partial output)
#   5  conversion error (bad/unsupported file content)
#   2  usage error
#
# The "absent → exit 3" split lets the shell wrapper distinguish a graceful skip
# (which must not abort a task run) from a real refusal (which must). The DoS
# refusals (oversize / timeout) ride the SAME exit-4 path as a security refusal:
# the input was rejected, no output was produced, and the caller must know.

USAGE = (
    "usage: md_convert.py <file> [--out FILE] [--root DIR] [--check]\n"
    "  <file>      local document to convert (PDF/docx/xlsx/pptx/html/csv/...)\n"
    "  --out FILE  write markdown here instead of stdout\n"
    "  --root DIR  allowed root the file must live inside (default: cwd)\n"
    "  --check     print 'available'/'absent' for markitdown and exit\n"
)


def main(argv):
    args = argv[1:]
    path = None
    out = None
    root = None
    check = False
    i = 0
    while i < len(args):
        a = args[i]
        if a == "--out":
            i += 1
            if i >= len(args):
                sys.stderr.write("md_convert: --out needs a path\n")
                return 2
            out = args[i]
        elif a == "--root":
            i += 1
            if i >= len(args):
                sys.stderr.write("md_convert: --root needs a dir\n")
                return 2
            root = args[i]
        elif a == "--check":
            check = True
        elif a in ("-h", "--help"):
            sys.stdout.write(USAGE)
            return 0
        elif a.startswith("-"):
            sys.stderr.write("md_convert: unknown option: %s\n" % a)
            return 2
        elif path is None:
            path = a
        else:
            sys.stderr.write("md_convert: unexpected extra argument: %s\n" % a)
            return 2
        i += 1

    if check:
        sys.stdout.write("available\n" if markitdown_available() else "absent\n")
        return 0

    if path is None:
        sys.stderr.write(USAGE)
        return 2

    try:
        md_text = convert_file(path, allowed_root=root)
    except MarkItDownUnavailable as exc:
        sys.stderr.write(
            "md_convert: SKIP — %s\n" % exc
        )
        return 3
    except (RemoteRefused, UnsafePathError) as exc:
        sys.stderr.write("md_convert: REFUSED (security) — %s\n" % exc)
        return 4
    except OversizeRefused as exc:
        # DoS resource gate — refused BEFORE any read. Same hard exit-4 path as a
        # security refusal: input rejected, no output produced.
        sys.stderr.write("md_convert: REFUSED (oversize) — %s\n" % exc)
        return 4
    except ConversionTimeout as exc:
        # DoS resource gate — conversion overran the budget; refuse cleanly with
        # NO partial output rather than hang the caller.
        sys.stderr.write("md_convert: REFUSED (timeout) — %s\n" % exc)
        return 4
    except (UnsupportedInput, ConvertError) as exc:
        sys.stderr.write("md_convert: ERROR — %s\n" % exc)
        return 5

    if out:
        with open(out, "w", encoding="utf-8") as fh:
            fh.write(md_text)
        sys.stderr.write("md_convert: wrote %s (%d chars)\n" % (out, len(md_text)))
    else:
        sys.stdout.write(md_text)
        if not md_text.endswith("\n"):
            sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
