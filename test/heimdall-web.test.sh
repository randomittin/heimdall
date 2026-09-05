#!/usr/bin/env bash
# test/heimdall-web.test.sh — falsifiable coverage for bin/heimdall-web /
# bin/lib/web_fetch.py, the dependency-light fetch/crawl/batch/meta engine
# that replicates Firecrawl's useful behavior without adopting Firecrawl
# itself (AGPL-3.0 network-use clause on modification; see
# docs/analysis/2026-08-23-firecrawl-assessment.md and
# docs/analysis/2026-09-05-web-research-tools-rollout.md).
#
# HERMETIC: every case runs against LOCAL, throwaway HTTP fixture servers
# this file starts and stops itself (127.0.0.1, OS-assigned ephemeral
# ports). It never contacts any real host on the internet. Two fixture
# server instances run concurrently ("main" and "ext") solely to prove the
# crawler's same-domain-only default against a genuinely different origin
# without ever touching a real external domain.
#
# It is genuinely falsifiable — it FAILS if heimdall-web:
#   does NOT strip <script>/<style>/<nav>/<header>/<footer> from markdown;
#   does NOT respect crawl --max-depth / --max-pages caps;
#   does NOT honour robots.txt Disallow by default;
#   fetches a loopback/private address WITHOUT --allow-private (SSRF guard);
#   fetches a non-http(s) scheme URL;
#   does NOT truncate a response at --max-bytes;
#   hangs or crashes instead of cleanly failing a request past --timeout;
#   ever sends a credential header, or leaks a credential-shaped env var;
#   re-fetches a URL that should have been served from cache.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TOOL="$ROOT/bin/heimdall-web"
LIB="$ROOT/bin/lib/web_fetch.py"

WORK="$(mktemp -d)"
main_PID=""
ext_PID=""
trap 'stop_server main; stop_server ext; rm -rf "$WORK"' EXIT

PASS=0; FAIL=0
ok()  { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; }

assert_contains() {
  # args: description haystack needle
  case "$2" in
    *"$3"*) ok "$1" ;;
    *) bad "$1 (did not find: $3)" ;;
  esac
}
assert_not_contains() {
  case "$2" in
    *"$3"*) bad "$1 (unexpectedly found: $3)" ;;
    *) ok "$1" ;;
  esac
}

fresh_home() {
  local d
  d="$(mktemp -d "$WORK/home.XXXXXX")"
  printf '%s\n' "$d"
}

webh() {
  local home="$1"; shift
  HEIMDALL_HOME="$home" "$TOOL" "$@"
}

# ── local fixture HTML/text server (shared code for "main" and "ext") ──────
FIXTURE_SRV="$WORK/fixture_server.py"
cat > "$FIXTURE_SRV" <<'PYEOF'
#!/usr/bin/env python3
"""Hermetic HTML/text fixture server for test/heimdall-web.test.sh. Binds an
ephemeral localhost port (or the port given as argv[1]), prints the bound
port to stdout, then serves fixed routes needed by that suite. Never talks
to anything real -- this process IS the only "internet" heimdall-web ever
touches during the test run."""
import http.server
import os
import sys
import time

COUNTER_PATH = os.environ.get("FIXTURE_COUNTER", "")
EXTERNAL_URL = os.environ.get("FIXTURE_EXTERNAL_URL", "http://127.0.0.1:1/unreachable")
SLOW_SECS = os.environ.get("FIXTURE_SLOW_SECS", "3")
BATCH_B_DELAY = os.environ.get("FIXTURE_BATCH_B_DELAY", "0.4")


def _bump_counter():
    if not COUNTER_PATH:
        return
    n = 0
    if os.path.exists(COUNTER_PATH):
        with open(COUNTER_PATH, "r", encoding="utf-8") as fh:
            text = fh.read().strip()
        n = int(text) if text else 0
    n += 1
    with open(COUNTER_PATH, "w", encoding="utf-8") as fh:
        fh.write(str(n))


ROBOTS_TXT = b"User-agent: *\nDisallow: /secret\n"

INDEX_HTML = b"""<!DOCTYPE html>
<html><head><title>Fixture Home</title>
<script>document.write('SHOULD-NOT-APPEAR-script');</script>
<style>body { color: red; }</style>
</head><body>
<nav><a href="/errorpage">SHOULD-NOT-APPEAR-nav-link</a></nav>
<header><h1>SHOULD-NOT-APPEAR-header-text</h1></header>
<h1>Welcome</h1>
<p>This is <strong>bold</strong> text with a <a href="/page2">a link</a>.</p>
<ul><li>one</li><li>two</li></ul>
<footer>SHOULD-NOT-APPEAR-footer-text</footer>
</body></html>"""

PAGE2_HTML = ("""<!DOCTYPE html>
<html><head><title>Page Two</title></head><body>
<h2>Page Two</h2>
<p>Back to <a href="/index">home</a>.
External: <a href="%s">ext</a>.
Errors: <a href="/errorpage">errorpage</a>.</p>
</body></html>""" % EXTERNAL_URL).encode("utf-8")

ERRORPAGE_HTML = b"""<!DOCTYPE html>
<html><body><h1>Not Found</h1>
<a href="/should-never-visit">SHOULD-NEVER-BE-VISITED</a>
</body></html>"""

SHOULD_NEVER_VISIT_HTML = b"<html><body><h1>should never be visited</h1></body></html>"

META_RICH_HTML = b"""<!DOCTYPE html>
<html><head>
<title>Meta Rich Page</title>
<meta name="description" content="A page for testing metadata extraction.">
<meta property="og:title" content="OG Title Here">
<meta property="og:image" content="https://example.com/img.png">
<meta name="twitter:card" content="summary">
<link rel="canonical" href="/canonical-target">
<script type="application/ld+json">{"@context": "https://schema.org", "@type": "Article", "headline": "JSONLD Headline"}</script>
</head><body>
<h1>Main Heading</h1>
<h2>Sub Heading</h2>
</body></html>"""


class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        return

    def _send(self, status, body, content_type="text/html; charset=utf-8", extra_headers=None):
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        if extra_headers:
            for k, v in extra_headers.items():
                self.send_header(k, v)
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        _bump_counter()
        path = self.path

        if path == "/robots.txt":
            self._send(200, ROBOTS_TXT, "text/plain")
        elif path == "/secret":
            self._send(200, b"top secret content", "text/plain")
        elif path == "/index":
            self._send(200, INDEX_HTML)
        elif path == "/page2":
            self._send(200, PAGE2_HTML)
        elif path == "/errorpage":
            self._send(404, ERRORPAGE_HTML)
        elif path == "/should-never-visit":
            self._send(200, SHOULD_NEVER_VISIT_HTML)
        elif path == "/meta-rich":
            self._send(200, META_RICH_HTML)
        elif path.startswith("/chain"):
            n = int(path[len("/chain"):])
            body = ("<html><body><h1>chain %d</h1><a href=\"/chain%d\">next</a></body></html>" % (n, n + 1)).encode("utf-8")
            self._send(200, body)
        elif path == "/redirect":
            self.send_response(302)
            self.send_header("Location", "/redirect-target")
            self.send_header("Content-Length", "0")
            self.end_headers()
        elif path == "/redirect-target":
            self._send(200, b"redirect target reached", "text/plain")
        elif path == "/big":
            self._send(200, b"x" * 50000, "text/plain")
        elif path == "/slow":
            time.sleep(float(SLOW_SECS))
            self._send(200, b"slow response", "text/plain")
        elif path == "/echo-headers":
            lines = ["%s: %s" % (k, self.headers.get(k)) for k in self.headers.keys()]
            self._send(200, "\n".join(lines).encode("utf-8"), "text/plain")
        elif path == "/batch-a":
            self._send(200, b"batch page a", "text/plain")
        elif path == "/batch-b":
            time.sleep(float(BATCH_B_DELAY))
            self._send(200, b"batch page b", "text/plain")
        elif path == "/batch-c":
            self._send(200, b"batch page c", "text/plain")
        else:
            self._send(404, b"not found", "text/plain")


class Server(http.server.ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True


def main():
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 0
    server = Server(("127.0.0.1", port), Handler)
    print(server.server_address[1], flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
PYEOF

start_server() {
  # args: role [extra_env=value ...]
  local role="$1"; shift
  local portfile="$WORK/port-$role"
  local logfile="$WORK/log-$role"
  : > "$portfile"
  env "$@" FIXTURE_COUNTER="$WORK/counter-$role" \
    python3 "$FIXTURE_SRV" 0 >"$portfile" 2>"$logfile" &
  eval "${role}_PID=\$!"
  local tries=0
  local port=""
  while [ "$tries" -lt 100 ]; do
    port="$(cat "$portfile" 2>/dev/null)"
    [ -n "$port" ] && break
    sleep 0.05
    tries=$((tries + 1))
  done
  if [ -z "$port" ]; then
    echo "FATAL: $role fixture server never printed a port" >&2
    cat "$logfile" >&2
    exit 90
  fi
  eval "${role}_PORT=$port"
}

stop_server() {
  local role="$1"
  local pidvar="${role}_PID"
  local pid="${!pidvar:-}"
  if [ -n "$pid" ]; then
    kill "$pid" 2>/dev/null
    wait "$pid" 2>/dev/null
  fi
}

counter_of() {
  cat "$WORK/counter-$1" 2>/dev/null || echo 0
}

echo "heimdall-web test harness  repo=$ROOT"
echo "--------------------------------------------------------------------"

# ── Case A: executables exist, --help / no-args / unknown command ──────────
echo "Case A — sanity, executables, usage:"
[ -x "$TOOL" ] && ok "bin/heimdall-web is executable" || bad "bin/heimdall-web missing or not executable"
[ -f "$LIB" ] && ok "bin/lib/web_fetch.py exists" || bad "bin/lib/web_fetch.py missing"

H="$(fresh_home)"
help_out="$(webh "$H" --help)"; rc=$?
[ "$rc" -eq 0 ] && ok "--help exits 0 (rc=$rc)" || bad "--help exits 0 (rc=$rc)"
for word in fetch crawl batch meta allow-private ignore-robots; do
  assert_contains "--help mentions '$word'" "$help_out" "$word"
done

noargs_out="$(webh "$H" 2>&1)"; rc=$?
[ "$rc" -eq 2 ] && ok "no-args invocation exits 2 (rc=$rc)" || bad "no-args invocation exits 2 (rc=$rc)"
[ -n "$noargs_out" ] && ok "no-args invocation prints usage" || bad "no-args invocation printed nothing"

unknown_out="$(webh "$H" bogus-command 2>&1)"; rc=$?
[ "$rc" -eq 2 ] && ok "unknown command exits 2 (rc=$rc)" || bad "unknown command exits 2 (rc=$rc)"

missing_val_err="$(webh "$H" fetch --timeout 2>&1 1>/dev/null)"; rc=$?
[ "$rc" -eq 2 ] && ok "missing flag value exits 2 (rc=$rc)" || bad "missing flag value exits 2 (rc=$rc)"
assert_contains "missing flag value names the flag on stderr" "$missing_val_err" "--timeout"

# ── Case B: non-http(s) scheme refused, no network involved at all ─────────
echo "Case B — non-http(s) scheme refused:"
H="$(fresh_home)"
scheme_out="$(webh "$H" fetch 'file:///etc/passwd' 2>"$WORK/scheme.err")"; rc=$?
[ "$rc" -eq 4 ] && ok "file:// scheme refused with exit 4 (rc=$rc)" || bad "file:// scheme refused with exit 4 (rc=$rc)"
[ -z "$scheme_out" ] && ok "file:// scheme refusal produced no stdout" || bad "file:// scheme refusal leaked stdout: $scheme_out"
scheme_err="$(cat "$WORK/scheme.err")"
assert_contains "file:// refusal names REFUSED on stderr" "$scheme_err" "REFUSED"
assert_contains "file:// refusal explains non-http(s)" "$scheme_err" "non-http(s)"

# ── start fixture servers (ext first: main's PAGE2_HTML embeds ext's URL) ──
start_server ext
start_server main FIXTURE_EXTERNAL_URL="http://127.0.0.1:$ext_PORT/index"
MAIN="http://127.0.0.1:$main_PORT"
EXT="http://127.0.0.1:$ext_PORT"

# ── Case C: SSRF guard — loopback refused by default, allowed with opt-in ──
echo "Case C — private/loopback address refused without --allow-private:"
H="$(fresh_home)"
priv_out="$(webh "$H" fetch "$MAIN/index" 2>"$WORK/priv.err")"; rc=$?
[ "$rc" -eq 4 ] && ok "loopback fetch without --allow-private refused, exit 4 (rc=$rc)" \
  || bad "loopback fetch without --allow-private refused, exit 4 (rc=$rc)"
[ -z "$priv_out" ] && ok "refused loopback fetch produced no stdout" || bad "refused loopback fetch leaked stdout: $priv_out"
priv_err="$(cat "$WORK/priv.err")"
assert_contains "loopback refusal names REFUSED on stderr" "$priv_err" "REFUSED"
assert_contains "loopback refusal mentions --allow-private" "$priv_err" "allow-private"

H="$(fresh_home)"
allowed_out="$(webh "$H" fetch "$MAIN/index" --allow-private)"; rc=$?
[ "$rc" -eq 0 ] && ok "loopback fetch WITH --allow-private succeeds, exit 0 (rc=$rc)" \
  || bad "loopback fetch WITH --allow-private succeeds, exit 0 (rc=$rc)"
assert_contains "opted-in loopback fetch returns real content" "$allowed_out" "Welcome"

# ── Case D: HTML -> clean markdown strips script/style/nav/header/footer ───
echo "Case D — HTML to markdown strips script/style/nav/header/footer:"
H="$(fresh_home)"
md_out="$(webh "$H" fetch "$MAIN/index" --allow-private)"
assert_not_contains "markdown strips <script> content"  "$md_out" "SHOULD-NOT-APPEAR-script"
assert_not_contains "markdown strips <style> content"    "$md_out" "color: red"
assert_not_contains "markdown strips <nav> content"       "$md_out" "SHOULD-NOT-APPEAR-nav-link"
assert_not_contains "markdown strips <header> content"    "$md_out" "SHOULD-NOT-APPEAR-header-text"
assert_not_contains "markdown strips <footer> content"    "$md_out" "SHOULD-NOT-APPEAR-footer-text"
assert_contains     "markdown keeps h1 as heading"         "$md_out" "# Welcome"
assert_contains     "markdown keeps strong as bold"        "$md_out" "**bold**"
assert_contains     "markdown keeps link with absolute url" "$md_out" "[a link]($MAIN/page2)"
assert_contains     "markdown keeps list item one"         "$md_out" "- one"
assert_contains     "markdown keeps list item two"         "$md_out" "- two"

# ── Case E: structured metadata extraction ──────────────────────────────────
echo "Case E — meta command extracts title/description/OG/canonical/JSON-LD/headings:"
H="$(fresh_home)"
meta_out="$(webh "$H" meta "$MAIN/meta-rich" --allow-private)"; rc=$?
[ "$rc" -eq 0 ] && ok "meta command exits 0 (rc=$rc)" || bad "meta command exits 0 (rc=$rc)"
assert_contains "meta extracts title"       "$meta_out" '"title": "Meta Rich Page"'
assert_contains "meta extracts description" "$meta_out" '"description": "A page for testing metadata extraction."'
assert_contains "meta extracts og:title"    "$meta_out" '"og:title": "OG Title Here"'
assert_contains "meta extracts twitter:card" "$meta_out" '"twitter:card": "summary"'
assert_contains "meta resolves canonical to absolute url" "$meta_out" "\"canonical\": \"$MAIN/canonical-target\""
assert_contains "meta parses JSON-LD headline" "$meta_out" '"headline": "JSONLD Headline"'
assert_contains "meta lists h1 heading"     "$meta_out" '"text": "Main Heading"'
assert_contains "meta lists h2 heading"     "$meta_out" '"text": "Sub Heading"'

# ── Case F: robots.txt disallow honoured by default, overridable ───────────
echo "Case F — robots.txt Disallow honoured by default, --ignore-robots overrides:"
H="$(fresh_home)"
robots_out="$(webh "$H" fetch "$MAIN/secret" --allow-private 2>"$WORK/robots.err")"; rc=$?
[ "$rc" -eq 4 ] && ok "disallowed path refused by default, exit 4 (rc=$rc)" || bad "disallowed path refused by default, exit 4 (rc=$rc)"
[ -z "$robots_out" ] && ok "robots-disallowed fetch produced no stdout" || bad "robots-disallowed fetch leaked stdout: $robots_out"
robots_err="$(cat "$WORK/robots.err")"
assert_contains "robots refusal names REFUSED on stderr" "$robots_err" "REFUSED"
assert_contains "robots refusal mentions robots.txt" "$robots_err" "robots.txt"

H="$(fresh_home)"
override_out="$(webh "$H" fetch "$MAIN/secret" --allow-private --ignore-robots)"; rc=$?
[ "$rc" -eq 0 ] && ok "--ignore-robots overrides disallow, exit 0 (rc=$rc)" || bad "--ignore-robots overrides disallow, exit 0 (rc=$rc)"
assert_contains "overridden fetch returns the real disallowed content" "$override_out" "top secret content"

# ── Case G: crawl respects --max-depth ──────────────────────────────────────
echo "Case G — crawl respects --max-depth cap:"
H="$(fresh_home)"
depth_out="$(webh "$H" crawl "$MAIN/chain0" --allow-private --max-depth 2 --max-pages 100)"; rc=$?
[ "$rc" -eq 0 ] && ok "depth-capped crawl exits 0 (rc=$rc)" || bad "depth-capped crawl exits 0 (rc=$rc)"
depth_count="$(printf '%s' "$depth_out" | grep -o '"depth"' | wc -l | tr -d ' ')"
[ "$depth_count" -eq 3 ] && ok "max-depth 2 from chain0 visits exactly 3 pages (chain0/1/2), got $depth_count" \
  || bad "max-depth 2 from chain0 visited $depth_count pages, expected 3"
assert_contains     "depth-capped crawl includes chain2" "$depth_out" "\"url\": \"$MAIN/chain2\""
assert_not_contains "depth-capped crawl excludes chain3" "$depth_out" "\"url\": \"$MAIN/chain3\""

# ── Case H: crawl respects --max-pages ──────────────────────────────────────
echo "Case H — crawl respects --max-pages cap:"
H="$(fresh_home)"
pages_out="$(webh "$H" crawl "$MAIN/chain0" --allow-private --max-depth 100 --max-pages 2)"; rc=$?
[ "$rc" -eq 0 ] && ok "page-capped crawl exits 0 (rc=$rc)" || bad "page-capped crawl exits 0 (rc=$rc)"
pages_count="$(printf '%s' "$pages_out" | grep -o '"depth"' | wc -l | tr -d ' ')"
[ "$pages_count" -eq 2 ] && ok "max-pages 2 from chain0 visits exactly 2 pages, got $pages_count" \
  || bad "max-pages 2 from chain0 visited $pages_count pages, expected 2"
assert_not_contains "page-capped crawl excludes chain2 (depth budget unused)" "$pages_out" "/chain2"

# ── Case I: crawl same-domain-only default vs --allow-external ─────────────
echo "Case I — crawl same-domain-only by default, --allow-external opts in:"
H="$(fresh_home)"
samedomain_out="$(webh "$H" crawl "$MAIN/index" --allow-private --max-depth 2 --max-pages 20)"; rc=$?
[ "$rc" -eq 0 ] && ok "same-domain crawl exits 0 (rc=$rc)" || bad "same-domain crawl exits 0 (rc=$rc)"
assert_contains     "same-domain crawl includes page2 (same origin)" "$samedomain_out" "/page2"
assert_not_contains "same-domain-only crawl excludes the external origin" "$samedomain_out" "127.0.0.1:$ext_PORT"

H="$(fresh_home)"
external_out="$(webh "$H" crawl "$MAIN/index" --allow-private --allow-external --max-depth 2 --max-pages 20)"; rc=$?
[ "$rc" -eq 0 ] && ok "--allow-external crawl exits 0 (rc=$rc)" || bad "--allow-external crawl exits 0 (rc=$rc)"
assert_contains "with --allow-external, the external origin IS visited" "$external_out" "127.0.0.1:$ext_PORT"

# ── Case J: crawl never extracts links from a non-2xx page ─────────────────
echo "Case J — crawl does not follow links found inside a non-2xx response:"
H="$(fresh_home)"
err_crawl_out="$(webh "$H" crawl "$MAIN/errorpage" --allow-private --max-depth 5 --max-pages 20)"; rc=$?
[ "$rc" -eq 0 ] && ok "crawl of a 404 seed still exits 0 (never crashes)" || bad "crawl of a 404 seed exits 0 (rc=$rc)"
assert_contains     "errorpage itself is recorded with status 404" "$err_crawl_out" '"status": 404'
assert_not_contains "link embedded in the 404 body is never visited" "$err_crawl_out" "should-never-visit"

# ── Case K: redirect is followed, final_url reflects the target ────────────
echo "Case K — redirect is followed to its target:"
H="$(fresh_home)"
redirect_out="$(webh "$H" fetch "$MAIN/redirect" --allow-private --json)"; rc=$?
[ "$rc" -eq 0 ] && ok "redirect fetch exits 0 (rc=$rc)" || bad "redirect fetch exits 0 (rc=$rc)"
assert_contains "redirect final_url points at the target" "$redirect_out" "\"final_url\": \"$MAIN/redirect-target\""
assert_contains "redirect fetch returns the target's content" "$redirect_out" "redirect target reached"

# ── Case L: byte ceiling truncates ──────────────────────────────────────────
echo "Case L — --max-bytes truncates a large response:"
H="$(fresh_home)"
big_out="$(webh "$H" fetch "$MAIN/big" --allow-private --json --max-bytes 500)"; rc=$?
[ "$rc" -eq 0 ] && ok "capped big fetch exits 0 (rc=$rc)" || bad "capped big fetch exits 0 (rc=$rc)"
assert_contains "capped big fetch reports truncated:true" "$big_out" '"truncated": true'

H="$(fresh_home)"
untrunc_out="$(webh "$H" fetch "$MAIN/big" --allow-private --json --max-bytes 1000000)"
assert_contains "uncapped big fetch reports truncated:false" "$untrunc_out" '"truncated": false'

# ── Case M: per-request timeout fails cleanly, never hangs or crashes ──────
echo "Case M — request past --timeout fails cleanly (exit 5), not a hang or crash:"
H="$(fresh_home)"
FIXTURE_SLOW_SECS_SAVE="${FIXTURE_SLOW_SECS:-}"
slow_out="$(webh "$H" fetch "$MAIN/slow" --allow-private --timeout 1 2>"$WORK/slow.err")"; rc=$?
[ "$rc" -eq 5 ] && ok "timed-out fetch exits 5 (rc=$rc)" || bad "timed-out fetch exits 5 (rc=$rc)"
[ -z "$slow_out" ] && ok "timed-out fetch produced no stdout" || bad "timed-out fetch leaked stdout: $slow_out"
slow_err="$(cat "$WORK/slow.err")"
assert_contains "timed-out fetch names ERROR on stderr" "$slow_err" "ERROR"

# ── Case N: credentials are never sent, and a decoy env var never leaks ────
echo "Case N — no credential headers ever sent, no env-var secret leak:"
H="$(fresh_home)"
export ANTHROPIC_API_KEY="decoy-secret-value-should-never-leak"
headers_out="$(webh "$H" fetch "$MAIN/echo-headers" --allow-private)"
unset ANTHROPIC_API_KEY
assert_not_contains "no Authorization header sent"        "$headers_out" "Authorization"
assert_not_contains "no Cookie header sent"                "$headers_out" "Cookie"
assert_not_contains "decoy env-var secret never appears in the request" "$headers_out" "decoy-secret-value-should-never-leak"
assert_contains     "the fixture did see a real User-Agent header" "$headers_out" "User-Agent"

# ── Case O: URL cache — hit avoids re-fetch (content AND robots.txt) ───────
echo "Case O — same-session cache avoids re-fetching an already-fetched URL:"
H="$(fresh_home)"
first_out="$(webh "$H" fetch "$MAIN/index" --allow-private --json)"
first_count="$(counter_of main)"
assert_contains "first fetch of a URL reports cached:false" "$first_out" '"cached": false'
[ "$first_count" -eq 2 ] && ok "first fetch made exactly 2 real requests (robots.txt + index), got $first_count" \
  || bad "first fetch made $first_count real requests to the server, expected 2"

second_out="$(webh "$H" fetch "$MAIN/index" --allow-private --json)"
second_count="$(counter_of main)"
assert_contains "second fetch of the same URL reports cached:true" "$second_out" '"cached": true'
[ "$second_count" -eq "$first_count" ] && ok "second fetch made NO additional real requests (still $second_count)" \
  || bad "second fetch made additional real requests ($first_count -> $second_count), cache did not hit"

nocache_out1="$(webh "$H" fetch "$MAIN/index" --allow-private --json --no-cache)"
nocache_out2="$(webh "$H" fetch "$MAIN/index" --allow-private --json --no-cache)"
nocache_count="$(counter_of main)"
assert_contains "--no-cache fetch #1 reports cached:false" "$nocache_out1" '"cached": false'
assert_contains "--no-cache fetch #2 (same URL) still reports cached:false" "$nocache_out2" '"cached": false'
[ "$nocache_count" -eq "$((second_count + 4))" ] && ok "--no-cache made 2 more real round trips each call (4 total), got $((nocache_count - second_count))" \
  || bad "--no-cache request count unexpected: went from $second_count to $nocache_count"

# ── Case P: batch fetch preserves input order regardless of completion order ──
echo "Case P — batch fetch returns results in original input order; --list reads a file:"
H="$(fresh_home)"
batch_out="$(webh "$H" batch "$MAIN/batch-a" "$MAIN/batch-b" "$MAIN/batch-c" --allow-private --concurrency 3)"; rc=$?
[ "$rc" -eq 0 ] && ok "batch fetch exits 0 (rc=$rc)" || bad "batch fetch exits 0 (rc=$rc)"
a_pos=$(printf '%s' "$batch_out" | grep -bo "batch-a" | head -1 | cut -d: -f1)
b_pos=$(printf '%s' "$batch_out" | grep -bo "batch-b" | head -1 | cut -d: -f1)
c_pos=$(printf '%s' "$batch_out" | grep -bo "batch-c" | head -1 | cut -d: -f1)
if [ -n "$a_pos" ] && [ -n "$b_pos" ] && [ -n "$c_pos" ] && [ "$a_pos" -lt "$b_pos" ] && [ "$b_pos" -lt "$c_pos" ]; then
  ok "batch results appear in input order a,b,c even though b is the slowest to complete"
else
  bad "batch results are NOT in input order (positions: a=$a_pos b=$b_pos c=$c_pos)"
fi

listfile="$WORK/urls.txt"
printf '%s\n%s\n' "$MAIN/batch-a" "$MAIN/batch-c" > "$listfile"
list_out="$(webh "$H" batch --list "$listfile" --allow-private)"; rc=$?
[ "$rc" -eq 0 ] && ok "batch --list exits 0 (rc=$rc)" || bad "batch --list exits 0 (rc=$rc)"
assert_contains "batch --list fetched the first listed URL"  "$list_out" "batch page a"
assert_contains "batch --list fetched the second listed URL" "$list_out" "batch page c"

# ── Case Q: fetch -o FILE and crawl -o DIR write to disk correctly ─────────
echo "Case Q — fetch -o FILE and crawl -o DIR write real output to disk:"
H="$(fresh_home)"
outfile="$WORK/fetch-out.md"
webh "$H" fetch "$MAIN/index" --allow-private -o "$outfile" >/dev/null 2>&1; rc=$?
[ "$rc" -eq 0 ] && ok "fetch -o FILE exits 0 (rc=$rc)" || bad "fetch -o FILE exits 0 (rc=$rc)"
[ -f "$outfile" ] && ok "fetch -o FILE created the output file" || bad "fetch -o FILE did not create the output file"
filecontent="$(cat "$outfile" 2>/dev/null)"
assert_contains "written markdown file contains the expected heading" "$filecontent" "# Welcome"

outdir="$WORK/crawl-out"
webh "$H" crawl "$MAIN/index" --allow-private --max-depth 1 --max-pages 5 -o "$outdir" >/dev/null 2>&1; rc=$?
[ "$rc" -eq 0 ] && ok "crawl -o DIR exits 0 (rc=$rc)" || bad "crawl -o DIR exits 0 (rc=$rc)"
[ -f "$outdir/index.json" ] && ok "crawl -o DIR wrote an index.json manifest" || bad "crawl -o DIR did not write index.json"
mdfiles="$(ls "$outdir"/*.md 2>/dev/null | wc -l | tr -d ' ')"
[ "$mdfiles" -gt 0 ] && ok "crawl -o DIR wrote at least one per-page .md file ($mdfiles found)" \
  || bad "crawl -o DIR wrote no per-page .md files"

echo
echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
