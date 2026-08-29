#!/usr/bin/env python3
"""paste_secret_filter — credential detection + local vault for pasted secrets.

This is the classification half of `bin/heimdall-secret-filter`. The shell half
runs a cheap grep pre-filter on every prompt and only invokes this module when
something credential-shaped is present, so interpreter startup is not paid on
the ~99.9% of prompts that contain no candidate at all.

DESIGN CONSTRAINT (see docs/secret-paste-filter.md): a Claude Code
`UserPromptSubmit` hook CANNOT rewrite prompt text — measured against 2.1.251,
no such field exists. It can only block or append context. So the only way to
keep a pasted credential off the wire is to refuse the whole prompt. This module
therefore mints a reference, stores the value locally, and reports what to say
instead; it never pretends a substitution happened.

PRECISION OVER RECALL, deliberately. False positives are the failure mode that
kills this feature: a filter that fires on ordinary code gets turned off, and
then it protects nothing. Entropy is a SECONDARY signal only — it gates the
generic `KEY=value` rule and nothing else. A named-prefix shape (sk-ant-, AKIA,
ghp_) is recognized on shape alone; a bare high-entropy blob is never flagged
without a credential-ish key name in front of it.

NEVER prints a stored value except via the explicit `get` / `exec` verbs. The
`scan` and `list` verbs emit references, shapes and fingerprints only.
"""

import base64
import hashlib
import json
import math
import os
import re
import sys
from collections import Counter
from datetime import datetime, timezone

# ── Named credential shapes ──────────────────────────────────────────────────
# Each of these is recognized on SHAPE ALONE. They are specific enough that a
# match is a credential or a deliberate imitation of one; entropy is not
# consulted. Ordering does not matter — overlapping matches are de-duplicated by
# span containment below.
NAMED_PATTERNS = [
    # Anthropic. The api03/admin01 infix form is the current issued shape; the
    # looser second form catches older/other infixes without matching the short
    # `sk-ant-api03-YOUR-KEY-HERE` placeholder that appears throughout docs.
    ("anthropic-api-key", re.compile(r"sk-ant-(?:api|admin)[0-9]{2}-[A-Za-z0-9_\-]{20,}")),
    ("anthropic-api-key", re.compile(r"sk-ant-[A-Za-z0-9_\-]{28,}")),
    # OpenAI. `sk-proj-` is the current project-scoped form. The bare `sk-` form
    # requires 32+ UNBROKEN alphanumerics, which `sk-ant-...` can never satisfy
    # (it hits a `-` after three chars), so the vendors do not collide.
    ("openai-api-key", re.compile(r"sk-proj-[A-Za-z0-9_\-]{20,}")),
    ("openai-api-key", re.compile(r"sk-[A-Za-z0-9]{32,}")),
    # GitHub: ghp_ (classic PAT), gho_ (OAuth), ghu_/ghs_ (app), ghr_ (refresh).
    ("github-token", re.compile(r"gh[pousr]_[A-Za-z0-9]{36,}")),
    ("github-pat", re.compile(r"github_pat_[A-Za-z0-9_]{60,}")),
    # AWS key ids are fixed-width and unmistakable. The 40-char SECRET key has no
    # distinguishing shape, so it is reached only via the generic rule below
    # (i.e. it must appear as AWS_SECRET_ACCESS_KEY=...).
    ("aws-access-key-id", re.compile(r"(?:AKIA|ASIA)[0-9A-Z]{16}")),
    ("google-api-key", re.compile(r"AIza[0-9A-Za-z_\-]{35}")),
    ("slack-token", re.compile(r"xox[baprs]-[0-9A-Za-z\-]{10,}")),
    # JWT. Requiring the PAYLOAD to also start with eyJ (base64 of '{"') is what
    # makes this precise: arbitrary dotted base64 does not match, but a real JWT
    # — whose header and payload are both base64-encoded JSON objects — always does.
    ("jwt", re.compile(r"eyJ[A-Za-z0-9_\-]{8,}\.eyJ[A-Za-z0-9_\-]{8,}\.[A-Za-z0-9_\-]{8,}")),
    # PEM private key block, captured whole (it spans lines).
    (
        "private-key-pem",
        re.compile(r"-----BEGIN [A-Z ]*PRIVATE KEY-----[\s\S]*?-----END [A-Z ]*PRIVATE KEY-----"),
    ),
]

# ── Generic `SOMETHING_KEY = value` rule ─────────────────────────────────────
# The only rule that consults entropy, and the only one that can fire on a value
# with no distinguishing shape. Every guard below exists to keep it off ordinary
# code.
GENERIC_ASSIGN = re.compile(
    r"(?P<key>[A-Za-z0-9_.\-]*"
    r"(?:api[_\-]?key|apikey|secret|token|password|passwd|"
    r"private[_\-]?key|access[_\-]?key|client[_\-]?secret|auth[_\-]?token)"
    r"[A-Za-z0-9_.\-]*)"
    r"\s*[:=]\s*"
    # Brackets, parens and quotes are excluded from the value: an issued
    # credential never contains them, but a function call does. Without this,
    # `private_key = rsa.generate_private_key(public_exponent=65537)` is a
    # 3-character-class, high-entropy "value".
    r"(?P<q>[\"']?)(?P<val>[^\s\"',;(){}\[\]]{16,})(?P=q)",
    re.IGNORECASE,
)

MIN_GENERIC_LEN = 16
MIN_GENERIC_ENTROPY = 3.6

UUID_RE = re.compile(r"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$")
PURE_HEX_RE = re.compile(r"^[0-9a-fA-F]{16,}$")

# Substrings that mark a value as a reference, a template, or a documentation
# placeholder rather than a real credential.
_NOT_A_SECRET_SUBSTRINGS = (
    "process.env",
    "os.environ",
    "os.getenv",
    "getenv(",
    "import.meta.env",
    "config.get",
    "secrets.token",
    "your_",
    "your-",
    "yourkey",
    "changeme",
    "change_me",
    "placeholder",
    "redacted",
    "insert_",
    "replace_with",
    "_here",
    "xxxxxxxx",
)

_NOT_A_SECRET_PREFIXES = ("$", "%", "<", "{{", "{%", "data:", "http://", "https://", "/", "./", "../", "~/")


def shannon_entropy(s: str) -> float:
    """Shannon entropy in bits per character."""
    if not s:
        return 0.0
    n = len(s)
    return -sum((c / n) * math.log2(c / n) for c in Counter(s).values())


def charset_classes(s: str) -> int:
    """How many of {lower, upper, digit, symbol} the value draws on."""
    return sum(
        bool(re.search(p, s))
        for p in (r"[a-z]", r"[A-Z]", r"[0-9]", r"[^A-Za-z0-9]")
    )


def looks_machine_generated(s: str) -> bool:
    """True when the value mixes character classes the way issued keys do.

    An issued credential is essentially always either mixed-case or
    alphanumeric-with-digits. A snake_case identifier is neither, which is what
    separates a real key from `AUTH_TOKEN_KEY = 'auth_token_storage_key'` — a
    22-character, entropy-3.6 value that a naive threshold happily flags.
    """
    has_lower = bool(re.search(r"[a-z]", s))
    has_upper = bool(re.search(r"[A-Z]", s))
    has_digit = bool(re.search(r"[0-9]", s))
    has_alpha = has_lower or has_upper
    return (has_digit and has_alpha) or (has_lower and has_upper)


def is_template_or_placeholder(value: str) -> bool:
    """True when the value is plainly a reference/template, not a credential."""
    low = value.lower()
    if value.startswith(_NOT_A_SECRET_PREFIXES):
        return True
    if "${" in value or "{{" in value or "<%" in value:
        return True
    return any(tok in low for tok in _NOT_A_SECRET_SUBSTRINGS)


def generic_value_is_secretlike(value: str) -> bool:
    """Guards for the generic KEY=value rule. Precision-first; see module docstring.

    Each rejection below maps to a real false positive this would otherwise
    produce on ordinary source code or prose.
    """
    if len(value) < MIN_GENERIC_LEN:
        return False
    if is_template_or_placeholder(value):
        return False
    # A git SHA, a sha256 digest and a UUID are all high-entropy by the naive
    # measure and are ubiquitous in ordinary code. Excluding them costs us
    # hex-shaped secrets; that trade is documented and deliberate.
    if UUID_RE.match(value) or PURE_HEX_RE.match(value):
        return False
    if value.isdigit():
        return False
    # Real keys mix character classes; dictionary words and identifiers do not.
    if charset_classes(value) < 2:
        return False
    if not looks_machine_generated(value):
        return False
    return shannon_entropy(value) >= MIN_GENERIC_ENTROPY


def detect(text: str):
    """Return [(shape, value)] for every credential found, de-duplicated.

    Overlapping matches are resolved by span containment (a JWT found inside
    `TOKEN=eyJ...` is reported once), then by exact value.
    """
    spans = []  # (start, end, shape, value)

    for shape, pattern in NAMED_PATTERNS:
        for m in pattern.finditer(text):
            val = m.group(0)
            # Angle brackets and long X-runs are unambiguous doc placeholders and
            # cannot occur in an issued credential.
            if "<" in val or ">" in val or re.search(r"[Xx]{8,}", val):
                continue
            spans.append((m.start(), m.end(), shape, val))

    for m in GENERIC_ASSIGN.finditer(text):
        val = m.group("val")
        if generic_value_is_secretlike(val):
            spans.append((m.start("val"), m.end("val"), "generic-assignment", val))

    spans.sort(key=lambda s: (s[0], -(s[1] - s[0])))

    kept = []
    for start, end, shape, val in spans:
        if any(start >= ks and end <= ke for ks, ke, _, _ in kept):
            continue  # contained in a match we already kept
        kept.append((start, end, shape, val))

    out, seen = [], set()
    for _, _, shape, val in kept:
        if val in seen:
            continue
        seen.add(val)
        out.append((shape, val))
    return out


# ── Local vault ──────────────────────────────────────────────────────────────
# NDJSON, one record per line, 0600, inside .heimdall/ (gitignored via the
# `.heimdall/*` rule — verified with `git check-ignore`, not assumed).
#
# Values are stored base64-encoded. That is ENCODING, not encryption: it exists
# so arbitrary bytes and embedded newlines (PEM keys) survive a line-oriented
# format, and so no raw secret ever needs JSON escaping. The real protection is
# the 0600 mode and nothing else — same threat model as ~/.aws/credentials.
#
# Nothing here ever passes a secret as a process ARGUMENT, which would expose it
# in `ps` output to every user on the machine. Values arrive on stdin and leave
# via the child process environment.


def fingerprint(value: str) -> str:
    """Stable, non-reversing id for a value, so `list` can show something useful."""
    return "sha256:" + hashlib.sha256(value.encode("utf-8")).hexdigest()[:12]


def vault_path() -> str:
    home = os.environ.get("HEIMDALL_HOME")
    if home:
        return os.path.join(home, "secret-vault.ndjson")
    root = os.environ.get("HEIMDALL_REPO_ROOT") or os.getcwd()
    return os.path.join(root, ".heimdall", "secret-vault.ndjson")


def read_vault():
    path = vault_path()
    if not os.path.exists(path):
        return []
    records = []
    with open(path, "r", encoding="utf-8") as fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            try:
                records.append(json.loads(line))
            except json.JSONDecodeError:
                # A corrupt line must not destroy access to the rest of the
                # vault, and must not crash the hook on a live prompt.
                continue
    return records


def store(shape: str, value: str) -> str:
    """Persist a value and return its reference. Idempotent per distinct value."""
    path = vault_path()
    os.makedirs(os.path.dirname(path), mode=0o700, exist_ok=True)

    records = read_vault()
    fp = fingerprint(value)
    for rec in records:
        if rec.get("fp") == fp:
            return rec["ref"]  # already vaulted — reuse the reference

    ref = "{{HMD_SECRET_%d}}" % (len(records) + 1)
    record = {
        "ref": ref,
        "shape": shape,
        "fp": fp,
        "created": datetime.now(timezone.utc).isoformat(),
        "value_b64": base64.b64encode(value.encode("utf-8")).decode("ascii"),
    }
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600)
    with os.fdopen(fd, "a", encoding="utf-8") as fh:
        fh.write(json.dumps(record) + "\n")
    os.chmod(path, 0o600)  # defensive: a pre-existing file may have looser mode
    return ref


def resolve(ref: str) -> str:
    for rec in read_vault():
        if rec.get("ref") == ref:
            return base64.b64decode(rec["value_b64"]).decode("utf-8")
    raise KeyError(ref)


# ── Verbs ────────────────────────────────────────────────────────────────────


def cmd_scan() -> int:
    """stdin -> findings on stdout as `shape<TAB>ref<TAB>fingerprint`.

    Emits references and fingerprints only. The value never reaches any stream.
    """
    findings = detect(sys.stdin.read())
    if not findings:
        return 0
    for shape, value in findings:
        sys.stdout.write("%s\t%s\t%s\n" % (shape, store(shape, value), fingerprint(value)))
    return 1


def cmd_list() -> int:
    records = read_vault()
    if not records:
        sys.stdout.write("vault is empty (%s)\n" % vault_path())
        return 0
    sys.stdout.write("%-22s %-20s %-20s %s\n" % ("REFERENCE", "SHAPE", "FINGERPRINT", "CREATED"))
    for rec in records:
        sys.stdout.write(
            "%-22s %-20s %-20s %s\n"
            % (rec.get("ref", "?"), rec.get("shape", "?"), rec.get("fp", "?"), rec.get("created", "?"))
        )
    return 0


def cmd_get(argv) -> int:
    if len(argv) != 1:
        sys.stderr.write("usage: heimdall-secret-filter get '{{HMD_SECRET_N}}'\n")
        return 2
    try:
        sys.stdout.write(resolve(argv[0]))
    except KeyError:
        sys.stderr.write("no such reference: %s\n" % argv[0])
        return 1
    return 0


def cmd_exec(argv) -> int:
    """exec REF VARNAME -- cmd ... — inject the value as env, never print it."""
    if "--" not in argv:
        sys.stderr.write("usage: heimdall-secret-filter exec REF VARNAME -- command [args...]\n")
        return 2
    split = argv.index("--")
    head, command = argv[:split], argv[split + 1 :]
    if len(head) != 2 or not command:
        sys.stderr.write("usage: heimdall-secret-filter exec REF VARNAME -- command [args...]\n")
        return 2
    ref, varname = head
    try:
        value = resolve(ref)
    except KeyError:
        sys.stderr.write("no such reference: %s\n" % ref)
        return 1
    env = dict(os.environ)
    env[varname] = value
    try:
        os.execvpe(command[0], command, env)
    except OSError as exc:
        sys.stderr.write("cannot exec %s: %s\n" % (command[0], exc))
        return 127


def main(argv) -> int:
    if not argv:
        sys.stderr.write("usage: paste_secret_filter.py {scan|list|get|exec} ...\n")
        return 2
    verb, rest = argv[0], argv[1:]
    if verb == "scan":
        return cmd_scan()
    if verb == "list":
        return cmd_list()
    if verb == "get":
        return cmd_get(rest)
    if verb == "exec":
        return cmd_exec(rest)
    sys.stderr.write("unknown verb: %s\n" % verb)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
