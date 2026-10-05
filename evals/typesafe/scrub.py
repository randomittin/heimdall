"""scrub.py -- secret/email scrubbing shared by build_dataset.py and run.py.

Superset of bin/lib/companion_ui_attention.py's secret_shaped patterns, but REDACTS instead of detecting.
"""
import re

_SECRET_RES = (
    (re.compile(r"(token|secret|password|passwd|pwd|api[_-]?key|apikey|access[_-]?key|auth|bearer|"
                r"credential|private[_-]?key)(\s*[=:]\s*)\S{8,}", re.I), r"\1\2[REDACTED]"),
    (re.compile(r"gh[oprsu]_[A-Za-z0-9]{20,}"), "[REDACTED]"),
    (re.compile(r"github_pat_[A-Za-z0-9_]{20,}"), "[REDACTED]"),
    (re.compile(r"AKIA[0-9A-Z]{16}"), "[REDACTED]"),
    (re.compile(r"sk[-_](?:live|test|ant|proj)?[-_]?[A-Za-z0-9_-]{16,}"), "[REDACTED]"),
    (re.compile(r"xox[baprs]-[A-Za-z0-9-]{10,}"), "[REDACTED]"),
    (re.compile(r"-----BEGIN[ A-Z]*PRIVATE KEY-----.*?(?:-----END[ A-Z]*PRIVATE KEY-----|\Z)", re.S), "[REDACTED]"),
    (re.compile(r"eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}"), "[REDACTED]"),
    (re.compile(r"[A-Za-z0-9+/_=-]{32,}"), "[REDACTED]"),                       # any long opaque token / hash
    (re.compile(r"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"), "[EMAIL]"),
    (re.compile(r"\b(?:\d{1,3}\.){3}\d{1,3}\b"), "[IP]"),
    (re.compile(r"\b\+?\d[\d\s().-]{9,}\d\b"), "[PHONE]"),
)
_PASTED_RE = re.compile(r"<pasted_content[^>]*>.*?(?:</pasted_content>|\Z)", re.S)
_IMAGE_RE = re.compile(r"\[Image[^\]]*\]")


def scrub(text, max_chars=1200, keep="head"):
    t = _PASTED_RE.sub("[PASTED]", text)
    t = _IMAGE_RE.sub("[IMAGE]", t)
    for rx, rep in _SECRET_RES:
        t = rx.sub(rep, t)
    t = t.strip()
    if len(t) <= max_chars:
        return t
    # keep="tail": an assistant question lives in its LAST sentence, so cut from the front instead.
    return t[:max_chars - 1] + "…" if keep == "head" else "…" + t[-(max_chars - 1):]
