#!/usr/bin/env python3
"""hmd_api_backend.py -- the `api` backend for bin/hmd-exec's wave-2 seam.

## What this is (and honestly is NOT)

A `claude -p` invocation is an AGENT: it reads files, edits them, runs shell commands,
and loops until the task is done. This backend is NOT that. It is a single Anthropic-
shaped `/v1/messages` completion, sent through an operator-configured, gate-checked
OmniRoute endpoint (see bin/heimdall-fallback) instead of Anthropic's own API.

That is choice (b) from the wave-2 task spec, deliberately, over choice (a) (a real
tool-use agent loop): a completion-only backend, honestly scoped, that REFUSES any
task shaped like it needs tool-use rather than silently returning a plausible-looking
non-answer. docs/analysis/2026-08-25-harness-independence-design.md's Stage 1 sketch
first proposed "the API agent loop (transport + message loop + the 6 filesystem/shell
tools)" as one wave-1 workstream -- a real loop remains a legitimate FUTURE increment
(the design doc is explicit that staging requires "no flag day": every stage is
independently valuable and independently revertible) -- but building a tool-use loop
half-way, on a first pass, in a fixed time budget, is exactly the "quietly become a
fake" failure mode the wave-2 task spec calls out by name. Ship the honest half first.

## What it CANNOT do (read this before wiring a caller to it)

  * NO tool-use of any kind: no file read/write/edit, no bash, no multi-step loop.
    One prompt in, one completion out.
  * Refuses immediately (exit 3), before any network or gate call, whenever the
    caller passes a non-empty `--allowedTools`. That flag is the one structural
    signal a real caller uses to say "I need edits made" (see
    bin/lib/issue_loop.py:281's `_FIX_ALLOWED_TOOLS = "Edit,Write,Read"`, threaded
    through to the real `claude -p` argv at :708). Answering anyway, in text, while
    making no edit, is the swallowed-failure this backend must never produce.
  * Cannot run at all unless bin/heimdall-fallback's `check` gate ROUTEs (exit 0) for
    the calling repo. No default route, no bypass, no fallback of its own -- the gate
    is the ONLY thing that may authorize an OmniRoute call (see "THE GATE IS
    MANDATORY" below).
  * Cannot succeed if the operator-configured target provider's model is unavailable
    upstream (a live fact about a third party, not a bug here) -- surfaced as a real,
    loud HTTP/parse error, never masked as success.
  * Ignores the caller's `--model`; always sends `$ANTHROPIC_MODEL` instead (the
    gate's own `anthropic_model_pinned` preflight check already requires that env var
    to carry an explicit `provider/` prefix before a ROUTE verdict is even possible).
    A Claude-alias model id (e.g. "sonnet") has no meaning to a third-party endpoint.
  * `--output-format` and `--permission-mode` are accepted and ignored -- there is no
    JSON/cost envelope to honor `--output-format json` with, and no permission system
    to honor `--permission-mode` with. Both are exactly the "flags it has no
    equivalent for [may be ignored]" case bin/hmd-exec's own wave-2-seam header
    (THE WAVE-2 SEAM, point 1) allows a backend to skip.
  * A raw network failure (connection refused, DNS failure, no response at all) is
    treated as a real, fail-fast error -- NOT retried. Only a failure that produced
    actual overload-shaped text (an HTTP status + body this backend can pattern-match)
    is eligible for retry, mirroring bin/lib/hmd-claude-retry.sh's own
    "retry ONLY on a positively-identified transient marker, never guess" rule. A dead
    endpoint is not evidence of "transient"; guessing otherwise would silently turn a
    real outage into a long, silent hang.
  * Will not get REAL work done against most keyless (no-auth) OmniRoute providers,
    even on a repo where the gate legitimately ROUTEs: measured directly against the
    live gateway on 2026-08-26, duckduckgo-web/felo-web/veoaifree-web all reject a
    request that carries a bare `system` field with a 400 or an unparseable response
    -- not tool schemas, not payload size, just that one field's presence. `_build_
    request` below sends only `{model, max_tokens, messages}` (no `system` field), so
    this file clears that specific bar today -- but a free keyless provider remains,
    at best, a toy-completion transport: no tool calling, some (e.g. aihorde-class
    queues) with multi-minute latency, and `claude -p` itself fails identically
    against this same gateway for the same reason. A live keyless run is evidence the
    wire is up and nothing more; it is never acceptance evidence for HTTP-error
    handling, malformed-body handling, or the retry loop -- see
    test/hmd-api-backend.test.sh's header for the fixture this backend's real
    acceptance evidence relies on instead.

## THE GATE IS MANDATORY

Every code path in this file that could reach OmniRoute is preceded by a call to
`bin/heimdall-fallback --repo <repo> check`. A non-zero exit (REFUSE, WAIT, or the
binary being missing/broken) is an unconditional refusal to route -- this file has no
fallback, retry-past-the-gate, or "just this once" bypass of its own. This mirrors
bin/lib/issue_loop.py's own `_fallback_gate_check`/`_fallback_gate_status`
(:517, :535) with ONE deliberate fix. issue_loop.py's `_omniroute_route_overlay`
(:556) does:

    key_value = os.environ.get(key_env) if key_env else None
    model = os.environ.get("ANTHROPIC_MODEL") or ""
    if not (key_value and endpoint and model):
        return None, None   # comment claims: "the gate's own preflight already
                             # required all three non-empty for a ROUTE verdict"

That comment is stale for the no-auth case: heimdall-fallback's `operator_key`
preflight check PASSES for a no-auth target_provider even when `operator_key_env` is
the empty string (see its `_target_provider_is_noauth` short-circuit) -- so
`key_value` is `None` by construction for every genuine no-auth provider, and this
unconditional check silently overrides the gate's own ROUTE verdict into a refusal.
That is a real bug. It is out of THIS file's scope to fix (`bin/lib/issue_loop.py` is
explicitly not-to-touch for this task) and is reported upstream rather than fixed
here. This file does not copy it: `resolve_route` below trusts the gate's own
`noauth_route` status field (a non-null string names a known no-auth provider, `null`
otherwise -- see heimdall-fallback's `cmd_status`) instead of re-deriving no-auth-ness
from a key value that a no-auth provider was never going to have.

## Credential handling (the Tier-1 invariant)

No Claude/Anthropic credential of any kind is ever read, forwarded, or logged by this
file. The ONLY secret this file will ever transmit is `operator_key_env`'s OWN value,
and only after bin/heimdall-fallback's preflight has already confirmed that env var
name does not match a Claude/Anthropic marker (its `FORBIDDEN_KEY_ENV_MARKERS` check
runs before a ROUTE verdict is possible). See
docs/analysis/2026-08-25-omniroute-credential-isolation.md for the invariant this
maintains structurally, not just by convention.

## Retry / exit-code contract

The wave-2 seam (bin/hmd-exec header) mandates exactly two sentinels: 0 on success,
and $HMD_OVERLOAD_EXIT (default 75) when a transient/overload-shaped failure survives
every retry -- "Any OTHER non-zero exit is a real, fail-fast error." This file adds
extra, non-mandated granularity on top of that single "any other nonzero" bucket
(matching heimdall-fallback's own run_preflight ethos: "a failure at 3am names exactly
what to fix"). A caller that only understands the documented 0/75 contract remains
fully correct treating every other code below uniformly as "a real error":

  0   success -- stdout is the model's answer text, nothing else.
  75  ($HMD_OVERLOAD_EXIT) -- transient/overload-shaped failure, retries exhausted.
  1   real error -- HTTP error, network error, or a malformed response body. Never
      retried, never masked as success.
  2   usage error -- malformed argv (e.g. `-p` missing its argument, or an
      unrecognized flag outside the five documented in THE WAVE-2 SEAM).
  3   capability refusal -- the task needs tool-use this backend cannot do
      (non-empty --allowedTools).
  4   routing refused -- bin/heimdall-fallback did not return a ROUTE verdict
      (REFUSE, WAIT, or the gate binary/config is missing or broken).

## Environment variables

  ANTHROPIC_MODEL               REQUIRED at call time (never read from --model). By
                                 the time this file runs, the gate has already forced
                                 it to carry a `provider/` prefix or ROUTE could never
                                 have been reached.
  HMD_API_BACKEND_REPO          Overrides which repo's `.heimdall/fallback.json` gates
                                 this call. Defaults to the current working directory,
                                 matching heimdall-fallback's own `--repo` default --
                                 this override exists for hermetic tests only; a real
                                 caller never needs it, since hmd-exec always runs from
                                 the target repo's own cwd.
  HMD_API_BACKEND_MAX_TOKENS    max_tokens sent in the request body. Default 4096.
  HMD_API_BACKEND_TIMEOUT_SECS  Per-HTTP-attempt socket timeout, in seconds. Default
                                 120 (some genuinely-keyless providers -- e.g. a
                                 volunteer-GPU queue -- run this slow).
  HMD_OVERLOAD_MAX_ATTEMPTS, HMD_OVERLOAD_BASE_SECS, HMD_OVERLOAD_CAP_SECS,
  HMD_OVERLOAD_EXIT, HMD_OVERLOAD_LOG, HEIMDALL_HOME
                                 Identical names, defaults, and meaning to
                                 bin/lib/hmd-claude-retry.sh's own contract (same repo
                                 convention, same shared heal log) -- see that file's
                                 header for the exact semantics mirrored here.
"""
import json
import os
import random
import re
import subprocess
import sys
import time
import urllib.error
import urllib.request

# ── the wave-2 seam's exit codes (see "Retry / exit-code contract" above) ───────
EXIT_OK = 0
EXIT_REAL_ERROR = 1
EXIT_USAGE = 2
EXIT_CAPABILITY_REFUSED = 3
EXIT_ROUTE_REFUSED = 4


def _overload_exit_code():
    # read live (not at import time) so tests that set/unset the env var per-case
    # never race a module-level default computed once at import.
    try:
        return int(os.environ.get("HMD_OVERLOAD_EXIT", "75") or "75")
    except ValueError:
        return 75


_HERE = os.path.dirname(os.path.abspath(__file__))
_BINDIR = os.path.dirname(_HERE)
_FALLBACK_GATE_BIN = os.path.join(_BINDIR, "heimdall-fallback")

# Same discrimination regex bin/lib/hmd-claude-retry.sh's _hmd_is_overload_text uses,
# ported verbatim so retry behaviour is identical whichever backend runs.
_OVERLOAD_RE = re.compile(
    r"529|overloaded(_error)?|too many requests|429|rate.?limit|"
    r"retrying( in)?|attempt[ \t]+[0-9]+/[0-9]+",
    re.IGNORECASE,
)


def _log_path():
    home = os.environ.get("HEIMDALL_HOME") or os.path.expanduser("~/.heimdall")
    return os.environ.get("HMD_OVERLOAD_LOG") or os.path.join(home, "overload-heal.log")


def _overload_log(line):
    """Best-effort, mirrors bin/lib/hmd-claude-retry.sh's _hmd_overload_log: stderr
    always fires, the shared heal log file is written best-effort. A failure to open
    or create the log file is deliberately swallowed here -- an attribution log is
    bookkeeping, not a gate, and must never be the reason a real result is lost --
    but the swallow is narrow (OSError only, from this one write) and documented,
    not a stand-in for real logic."""
    msg = "hmd-exec(api): %s" % line
    print(msg, file=sys.stderr)
    path = _log_path()
    log_dir = os.path.dirname(path)
    dir_ready = True
    if log_dir:
        try:
            os.makedirs(log_dir, exist_ok=True)
        except OSError:
            dir_ready = False
    if not dir_ready:
        return
    try:
        with open(path, "a", encoding="utf-8") as f:
            f.write(msg + "\n")
    except OSError:
        return


# ── argv parsing -- the strict wave-2-seam shape only ───────────────────────────
_FLAGS_WITH_ARG = ("-p", "--model", "--output-format", "--permission-mode", "--allowedTools")


def parse_argv(argv):
    """Recognises exactly the five flags THE WAVE-2 SEAM documents (bin/hmd-exec
    header). No `--flag=value` form and no tolerance for unrecognized flags -- every
    real caller found in this repo (bin/lib/issue_loop.py's fix-argv, and every case
    in test/hmd-exec.test.sh) uses only two-token `--flag value` pairs from this exact
    five, so silently accepting anything else would be guessing at a shape no caller
    has ever sent, which this repo's own convention treats as a loud failure, not a
    tolerated default (see bin/hmd-exec's own "unknown --backend is ALWAYS a hard,
    loud failure" stance). Returns a dict on success; raises ValueError with a
    human-readable message on any parse failure."""
    out = {
        "prompt": None,
        "model": None,
        "output_format": None,
        "permission_mode": None,
        "allowed_tools": None,
    }
    i = 0
    n = len(argv)
    while i < n:
        tok = argv[i]
        if tok not in _FLAGS_WITH_ARG:
            raise ValueError("unrecognized argument: %s" % tok)
        if i + 1 >= n:
            raise ValueError("%s requires an argument" % tok)
        val = argv[i + 1]
        if tok == "-p":
            out["prompt"] = val
        elif tok == "--model":
            out["model"] = val
        elif tok == "--output-format":
            out["output_format"] = val
        elif tok == "--permission-mode":
            out["permission_mode"] = val
        elif tok == "--allowedTools":
            out["allowed_tools"] = val
        i += 2
    if out["prompt"] is None:
        raise ValueError("-p <prompt> is required")
    return out


# ── the gate consultation + no-auth-aware route resolver ────────────────────────
def _repo_dir():
    return os.environ.get("HMD_API_BACKEND_REPO") or os.getcwd()


def _fallback_gate_check(repo):
    if not os.path.isfile(_FALLBACK_GATE_BIN):
        return None
    try:
        proc = subprocess.run(
            [_FALLBACK_GATE_BIN, "--repo", repo, "check"],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
    except OSError:
        return None
    return proc.returncode


def _fallback_gate_status(repo):
    if not os.path.isfile(_FALLBACK_GATE_BIN):
        return None
    try:
        proc = subprocess.run(
            [_FALLBACK_GATE_BIN, "--repo", repo, "status", "--json"],
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
        )
    except OSError:
        return None
    if proc.returncode != 0:
        return None
    try:
        return json.loads(proc.stdout)
    except (ValueError, TypeError):
        return None


def resolve_route(repo):
    """The ONE authority for whether/how to reach OmniRoute. Returns a dict with
    endpoint/model/key_value (key_value is None for a genuine no-auth route), or None
    if routing must be refused for ANY reason. See the module docstring ("THE GATE IS
    MANDATORY") for how and why this deliberately diverges from
    bin/lib/issue_loop.py's `_omniroute_route_overlay`."""
    rc = _fallback_gate_check(repo)
    if rc != 0:
        return None  # REFUSE, WAIT, or a missing/broken gate: never route.

    conf = _fallback_gate_status(repo)
    if not isinstance(conf, dict):
        return None  # gate said ROUTE but its own config read failed: no route.

    endpoint = conf.get("endpoint") or ""
    model = os.environ.get("ANTHROPIC_MODEL") or ""
    if not endpoint or not model:
        return None  # the gate's own preflight requires both; a gap here is fail-closed.

    is_noauth = bool(conf.get("noauth_route"))  # non-null string = known no-auth provider
    key_env = conf.get("operator_key_env") or ""
    key_value = os.environ.get(key_env) if key_env else None
    if not is_noauth and not key_value:
        return None  # a keyed route needs the operator's own key value present NOW

    return {"endpoint": endpoint.rstrip("/"), "model": model, "key_value": key_value}


# ── the Anthropic-shaped /v1/messages transport ──────────────────────────────────
def _max_tokens():
    try:
        return int(os.environ.get("HMD_API_BACKEND_MAX_TOKENS", "4096") or "4096")
    except ValueError:
        return 4096


def _timeout_secs():
    try:
        return float(os.environ.get("HMD_API_BACKEND_TIMEOUT_SECS", "120") or "120")
    except ValueError:
        return 120.0


def _build_request(endpoint, model, key_value, prompt):
    url = endpoint + "/v1/messages"
    body = json.dumps(
        {
            "model": model,
            "max_tokens": _max_tokens(),
            "messages": [{"role": "user", "content": prompt}],
        }
    ).encode("utf-8")
    headers = {"Content-Type": "application/json"}
    if key_value:
        headers["Authorization"] = "Bearer %s" % key_value
    return urllib.request.Request(url, data=body, headers=headers, method="POST")


def call_once(endpoint, model, key_value, prompt):
    """One HTTP attempt. Returns (kind, payload):
      kind == "ok"       -> payload is the extracted answer text.
      kind == "overload" -> payload is diagnostic text; caller MAY retry.
      kind == "error"    -> payload is diagnostic text; caller must NOT retry.
    Never raises for HTTP/network-shaped failures -- those are reported through this
    return value, never an exception, so retry logic never has to special-case
    exceptions vs. application-level errors."""
    # NOTE: urllib.request.urlopen() raises HTTPError for EVERY non-2xx response --
    # there is no code path where the `with` block below completes normally at a
    # status outside 2xx. A second "if status >= 300" check after the `with` would
    # therefore be dead code (unreachable, not just unlikely); the HTTPError except
    # clause below is the one and only non-2xx path, by construction.
    req = _build_request(endpoint, model, key_value, prompt)
    try:
        with urllib.request.urlopen(req, timeout=_timeout_secs()) as resp:
            raw = resp.read().decode("utf-8", errors="replace")
    except urllib.error.HTTPError as exc:
        raw = exc.read().decode("utf-8", errors="replace") if exc.fp else ""
        combined = "HTTP %s\n%s" % (exc.code, raw)
        return ("overload" if _OVERLOAD_RE.search(combined) else "error"), combined
    except urllib.error.URLError as exc:
        return "error", "network error: %s" % exc.reason
    except (OSError, ValueError) as exc:
        return "error", "network error: %s" % exc

    try:
        parsed = json.loads(raw)
    except ValueError:
        return "error", "malformed response body (not JSON): %s" % raw[:500]
    if not isinstance(parsed, dict):
        return "error", "malformed response body (not a JSON object): %s" % raw[:500]

    if parsed.get("type") == "error":
        # An Anthropic-shaped error envelope delivered with a 2xx status.
        err = parsed.get("error") or {}
        msg = err.get("message") or str(err)
        marker_text = "%s %s" % (err.get("type", ""), msg)
        return ("overload" if _OVERLOAD_RE.search(marker_text) else "error"), msg

    content = parsed.get("content")
    if not isinstance(content, list) or not content:
        return "error", "malformed response body (no .content array): %s" % raw[:500]
    texts = [
        block.get("text", "")
        for block in content
        if isinstance(block, dict) and block.get("type") == "text"
    ]
    answer = "".join(texts)
    if not answer:
        return "error", "malformed response body (no text block in .content): %s" % raw[:500]
    return "ok", answer


def run_with_retry(endpoint, model, key_value, prompt):
    """Retry/backoff shaped identically to bin/lib/hmd-claude-retry.sh's
    hmd_claude_retry: retry ONLY on a positively-identified overload marker, real
    errors fail fast on the first attempt, exponential backoff with jitter, and a
    loud give-up at $HMD_OVERLOAD_EXIT once the attempt budget is exhausted."""
    try:
        max_attempts = int(os.environ.get("HMD_OVERLOAD_MAX_ATTEMPTS", "6") or "6")
    except ValueError:
        max_attempts = 6
    try:
        base = float(os.environ.get("HMD_OVERLOAD_BASE_SECS", "5") or "5")
    except ValueError:
        base = 5.0
    try:
        cap = float(os.environ.get("HMD_OVERLOAD_CAP_SECS", "120") or "120")
    except ValueError:
        cap = 120.0

    attempt = 0
    while True:
        attempt += 1
        kind, payload = call_once(endpoint, model, key_value, prompt)
        if kind == "ok":
            if attempt > 1:
                _overload_log("recovered on attempt %d/%d" % (attempt, max_attempts))
            return EXIT_OK, payload
        if kind == "error":
            sys.stderr.write("hmd-exec(api): real error: %s\n" % payload)
            return EXIT_REAL_ERROR, None
        # kind == "overload"
        if attempt >= max_attempts:
            _overload_log("GAVE UP after %d attempts: %s" % (attempt, payload))
            return _overload_exit_code(), None
        delay = min(base * (2 ** (attempt - 1)), cap) + random.uniform(0, base)
        _overload_log(
            "will-retry attempt %d/%d in %.1fs: %s" % (attempt, max_attempts, delay, payload)
        )
        time.sleep(delay)


def main(argv):
    try:
        parsed = parse_argv(argv)
    except ValueError as exc:
        sys.stderr.write("hmd-exec(api): %s\n" % exc)
        return EXIT_USAGE

    if parsed["allowed_tools"]:
        sys.stderr.write(
            "hmd-exec(api): refusing -- caller requested --allowedTools '%s', which "
            "signals this task needs tool-use (file read/write/edit, bash). The api "
            "backend is completion-only: no tool-use of any kind. Use --backend "
            "claude-code for tasks that need edits.\n" % parsed["allowed_tools"]
        )
        return EXIT_CAPABILITY_REFUSED

    repo = _repo_dir()
    route = resolve_route(repo)
    if route is None:
        sys.stderr.write(
            "hmd-exec(api): refusing -- bin/heimdall-fallback did not return a ROUTE "
            "verdict for repo '%s'. The api backend never contacts OmniRoute without "
            "an explicit ROUTE from that gate (no default, no bypass). Run "
            "`heimdall-fallback --repo %s status` to see why.\n" % (repo, repo)
        )
        return EXIT_ROUTE_REFUSED

    rc, answer = run_with_retry(route["endpoint"], route["model"], route["key_value"], parsed["prompt"])
    if rc == EXIT_OK:
        sys.stdout.write(answer if answer.endswith("\n") else answer + "\n")
        return EXIT_OK
    return rc


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
