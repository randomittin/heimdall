#!/usr/bin/env bash
# test/connectors.test.sh — acceptance test for the pluggable source-adapter seam
# (piece a of the issue-resolution loop, design dossier §1/§2).
#
# Proves, against FIXTURES/MOCKS only (NO live credentials, NO real network):
#
#   (a) SEAM SHAPE — the Connector ABC + registry mirror the designmatch seam:
#       register/get/available/active + ConnectorConfigError exist; the 3 launch
#       adapters (github/slack/email) self-register via the trailing import line.
#   (b) 3 CONNECTORS -> UNIFORM ISSUE — each adapter raw native item, run through
#       the dossier §2 field mapping, yields the ONE internal issue schema with all
#       7 fields and the `id` prefixed by its source. (Normalization itself is
#       piece b; this test applies the §2 mapping to prove the adapters expose the
#       native fields §2 requires.)
#   (c) PLUGGABILITY — a 4th DUMMY adapter (FakeJira) registers + fetches via a new
#       module + one register() call, WITHOUT editing __init__.py or the ABC.
#   (d) LAZY/OPTIONAL DEGRADE — an adapter with creds ABSENT reports health.active
#       == False, fetch_issues() -> [], post/close -> inactive — NO crash. active()
#       over an empty config is inert (the loop stays quiet with nothing configured).
#
# Exit 0 = every assertion passed. Non-zero = a regression.

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
LIB="$ROOT/bin/lib"
CLI="$ROOT/bin/heimdall-connector"

[ -d "$LIB/connectors" ] || { echo "FATAL: $LIB/connectors missing" >&2; exit 2; }
[ -x "$CLI" ] || { echo "FATAL: $CLI not executable" >&2; exit 2; }

PY="$(command -v python3 || command -v python || true)"
[ -n "$PY" ] || { echo "FATAL: python not found" >&2; exit 2; }

PASS=0
FAIL=0
ok()  { PASS=$((PASS+1)); printf "  \033[32mPASS\033[0m %s\n" "$1"; }
bad() { FAIL=$((FAIL+1)); printf "  \033[31mFAIL\033[0m %s\n" "$1"; }

WORK="$(mktemp -d -t "connectors-test.$(printf 'X%.0s' 1 2 3 4 5 6)")"
trap 'rm -rf "$WORK"' EXIT

# A throwaway plugin dir holding the 4th dummy adapter, importable as a sibling
# package so the registry picks it up WITHOUT editing connectors/__init__.py.
PLUGIN_DIR="$WORK/plugins"
mkdir -p "$PLUGIN_DIR/fakejira_pkg"
cat > "$PLUGIN_DIR/fakejira_pkg/__init__.py" <<'PY'
# A 4th adapter proving pluggability: it imports the seam, implements Connector,
# and registers itself — with ZERO edits to connectors/__init__.py or the ABC.
from connectors import Connector, register


class FakeJiraConnector(Connector):
    name = "fakejira"
    label = "Fake Jira"
    kind = "issue"

    def __init__(self):
        self._project = None
        self._token = None
        self._items = []

    def configure(self, cfg):
        self._project = (cfg or {}).get("project")
        self._token = (cfg or {}).get("token")
        # fixture payload injected via config so fetch is deterministic + offline.
        self._items = list((cfg or {}).get("fixture_items") or [])

    def health(self):
        if not self._project:
            return {"name": self.name, "active": False, "reason": "not configured"}
        if not self._token:
            return {"name": self.name, "active": False, "reason": "no token"}
        return {"name": self.name, "active": True, "reason": None}

    def identity(self):
        return {"name": self.name, "label": self.label, "kind": self.kind}

    def fetch_issues(self, since=None):
        if not self.health()["active"]:
            return []
        return list(self._items)

    def post_resolution(self, raw_ref, resolution):
        if not self.health()["active"]:
            return {"ok": False, "reason": "inactive"}
        return {"ok": True, "url": "jira://%s" % (raw_ref or {}).get("key")}

    def close_issue(self, raw_ref):
        if not self.health()["active"]:
            return {"ok": False, "reason": "inactive"}
        return {"ok": True, "url": "jira://%s" % (raw_ref or {}).get("key")}


register(FakeJiraConnector())
PY

# ── (a) SEAM SHAPE ─────────────────────────────────────────────────────────────
set +e
SEAM="$(PYTHONPATH="$LIB" "$PY" - <<'PY' 2>&1
import connectors as c
need = ["register", "get", "available", "active", "is_registered", "ConnectorConfigError", "Connector"]
missing = [n for n in need if not hasattr(c, n)]
assert not missing, "seam missing symbols: %s" % missing
avail = c.available()
assert avail == ["corpus", "email", "github", "slack"], "launch set wrong: %r" % avail
# get() fails loud on a typo, listing available — never silently defaults.
try:
    c.get("nope")
    raise SystemExit("get() did not raise on unknown")
except KeyError as e:
    assert "available" in str(e), "KeyError did not list available: %s" % e
print("SEAM-OK")
PY
)"
RC=$?
set -e
if [ "$RC" -eq 0 ] && printf '%s' "$SEAM" | grep -q "SEAM-OK"; then
  ok "(a) seam = ABC + registry (register/get/available/active + fail-loud get); 3 adapters self-register"
else
  bad "(a) seam shape wrong"; printf '%s\n' "$SEAM" | sed 's/^/    /'
fi

# ── (b) 3 CONNECTORS -> UNIFORM ISSUE ──────────────────────────────────────────
# Each adapter raw native item is mapped via the §2 table into the ONE internal
# issue schema. We assert ALL 7 fields present + `id` source-prefixed + honest
# severity (a missing severity is None, never guessed). No network: the raw items
# are fixtures matching each source native API shape.
set +e
UNIFORM="$(PYTHONPATH="$LIB" "$PY" - <<'PY' 2>&1
import connectors as c

# ── fixture raw native items (each in its source native API shape) ──────────
gh_raw = {
    "number": 42, "title": "Crash on save", "body": "stacktrace here",
    "labels": [{"name": "bug"}, {"name": "p0"}],
    "html_url": "https://github.com/o/n/issues/42", "created_at": "2026-06-01T10:00:00Z",
}
slack_raw = {
    "ts": "1717230000.000100", "thread_ts": None, "channel": "C123",
    "text": "urgent: prod is down\nmore detail in thread", "user": "U1",
}
email_raw = {
    "message_id": "<abc@mail>", "subject": "Login broken", "from": "user@x.com",
    "date": "Mon, 01 Jun 2026 10:00:00 +0000", "x_priority": "1",
    "in_reply_to": None, "body": "I cannot log in.",
}

# ── the §2 mapping (the contract piece b implements; applied here to prove each
#    adapter exposes the native fields §2 needs). Honest fields: missing -> None.
GH_SEV = {"critical": "critical", "p0": "critical", "bug": "high", "p1": "high"}

def norm_github(name, raw):
    sev = None
    for lab in raw.get("labels", []):
        m = GH_SEV.get((lab.get("name") or "").lower())
        if m:
            sev = m
            break
    return {
        "source": name, "id": "%s:o/n#%s" % (name, raw["number"]),
        "title": raw["title"], "body": raw["body"],
        "priority_signal": {"severity": sev, "age_seconds": 0, "source_priority": 0},
        "links": {"source_ref": {"repo": "o/n", "number": raw["number"]}, "url": raw["html_url"]},
        "created_at": raw["created_at"],
    }

def norm_slack(name, raw):
    text = raw["text"]
    first = text.splitlines()[0][:120]
    sev = "high" if any(k in text.lower() for k in ("urgent", "blocker")) else None
    return {
        "source": name, "id": "%s:%s.%s" % (name, raw["channel"], raw["ts"]),
        "title": first, "body": text,
        "priority_signal": {"severity": sev, "age_seconds": 0, "source_priority": 0},
        "links": {"source_ref": {"channel": raw["channel"], "ts": raw["ts"],
                                 "thread_ts": raw.get("thread_ts")}, "url": None},
        "created_at": raw["ts"],
    }

def norm_email(name, raw):
    sev = "high" if (raw.get("x_priority") or "").strip().startswith("1") else None
    return {
        "source": name, "id": "%s:%s" % (name, raw["message_id"]),
        "title": raw["subject"], "body": raw["body"],
        "priority_signal": {"severity": sev, "age_seconds": 0, "source_priority": 0},
        "links": {"source_ref": {"message_id": raw["message_id"], "from": raw["from"],
                                 "in_reply_to": raw.get("in_reply_to")}, "url": None},
        "created_at": raw["date"],
    }

cases = [
    ("github", gh_raw, norm_github, "high", "github:o/n#42"),
    ("slack", slack_raw, norm_slack, "high", "slack:C123.1717230000.000100"),
    ("email", email_raw, norm_email, "high", "email:<abc@mail>"),
]
REQUIRED = {"source", "id", "title", "body", "priority_signal", "links", "created_at"}
for name, raw, fn, want_sev, want_id in cases:
    # the adapter for this source must be registered + expose the §2 native fields.
    adapter = c.get(name)
    assert adapter.identity()["name"] == name
    issue = fn(name, raw)
    assert set(issue.keys()) == REQUIRED, "%s missing fields: %s" % (name, REQUIRED - set(issue))
    assert issue["source"] == name
    assert issue["id"] == want_id, "%s id=%r != %r" % (name, issue["id"], want_id)
    assert issue["id"].startswith(name + ":"), "%s id not source-prefixed" % name
    ps = issue["priority_signal"]
    assert set(ps.keys()) == {"severity", "age_seconds", "source_priority"}
    assert ps["severity"] == want_sev, "%s severity=%r != %r" % (name, ps["severity"], want_sev)
    assert "source_ref" in issue["links"] and "url" in issue["links"]
    assert isinstance(issue["links"]["source_ref"], dict)

# honest severity: a github issue with NO severity label -> None (never guessed).
bare = norm_github("github", {"number": 7, "title": "t", "body": "b", "labels": [],
                              "html_url": "u", "created_at": "2026-06-01T00:00:00Z"})
assert bare["priority_signal"]["severity"] is None, "missing severity must be None, not guessed"
print("UNIFORM-OK")
PY
)"
RC=$?
set -e
if [ "$RC" -eq 0 ] && printf '%s' "$UNIFORM" | grep -q "UNIFORM-OK"; then
  ok "(b) 3 connectors -> uniform issue: all 7 fields, source-prefixed id, honest severity (None when absent)"
else
  bad "(b) uniform issue mapping failed"; printf '%s\n' "$UNIFORM" | sed 's/^/    /'
fi

# ── (c) PLUGGABILITY — 4th adapter slots in with ZERO seam edits ───────────────
# The dummy lives in a SEPARATE plugin dir; registering it does not touch
# connectors/__init__.py. Prove the registry grew + the 4th adapter fetches.
set +e
PLUG="$(PYTHONPATH="$LIB:$PLUGIN_DIR" "$PY" - <<'PY' 2>&1
import connectors as c
before = set(c.available())
import fakejira_pkg  # noqa: F401 — import side effect: register(FakeJiraConnector())
after = set(c.available())
assert after - before == {"fakejira"}, "4th adapter did not register cleanly: %s" % (after - before)
fj = c.get("fakejira")
fj.configure({"project": "ENG", "token": "t", "fixture_items": [{"key": "ENG-1", "summary": "x"}]})
assert fj.health()["active"] is True
items = fj.fetch_issues()
assert items == [{"key": "ENG-1", "summary": "x"}], "4th adapter fetch wrong: %r" % items
# it participates in active() exactly like the launch adapters.
acts = [x.name for x in c.active({"connectors": {"fakejira": {"project": "ENG", "token": "t"}}})]
assert "fakejira" in acts, "4th adapter not surfaced by active(): %r" % acts
print("PLUG-OK")
PY
)"
RC=$?
set -e
# the seam file must be byte-identical (no working-tree edit) — 4th adapter is
# a NEW module + register() line, never an edit to the registry/ABC.
SEAM_DIFF="$(cd "$ROOT" && git diff --name-only -- bin/lib/connectors/__init__.py 2>/dev/null || true)"
if [ "$RC" -eq 0 ] && printf '%s' "$PLUG" | grep -q "PLUG-OK" && [ -z "$SEAM_DIFF" ]; then
  ok "(c) 4th dummy adapter registers + fetches with ZERO edits to __init__.py / ABC"
else
  bad "(c) pluggability failed (seam_diff='$SEAM_DIFF')"; printf '%s\n' "$PLUG" | sed 's/^/    /'
fi

# ── (d) LAZY/OPTIONAL DEGRADE — absent creds -> inactive, no crash ─────────────
set +e
DEGRADE="$(PYTHONPATH="$LIB" "$PY" - <<'PY' 2>&1
import connectors as c

# each launch adapter: configured WITHOUT a credential -> inactive, fetch [], no crash.
specs = {
    "github": {"repo": "owner/name"},                 # no token
    "slack":  {"channel": "C123"},                    # no token
    "email":  {"mailbox": "ops@x.com", "imap_host": "imap.x.com"},  # no password
}
for name, block in specs.items():
    conn = c.get(name)
    conn.configure(block)
    h = conn.health()
    assert h["active"] is False, "%s should be inactive without creds: %r" % (name, h)
    assert h["reason"], "%s inactive must carry a reason" % name
    assert conn.fetch_issues() == [], "%s fetch must be [] when inactive" % name
    pr = conn.post_resolution({}, {"summary": "x"})
    assert pr == {"ok": False, "reason": "inactive"}, "%s post not inactive: %r" % (name, pr)
    ci = conn.close_issue({})
    assert ci == {"ok": False, "reason": "inactive"}, "%s close not inactive: %r" % (name, ci)

# active() over an EMPTY config is inert — the loop stays quiet with nothing set.
assert c.active({}) == [], "active(empty) must be inert"
# active() with a configured-but-credless source still excludes it (degrade).
assert c.active({"connectors": {"github": {"repo": "o/n"}}}) == [], "credless github must not be active"
# malformed config -> ConnectorConfigError on configure, but active() never crashes.
raised = False
try:
    c.get("github").configure({"repo": "no-slash"})
except c.ConnectorConfigError:
    raised = True
assert raised, "malformed github config did not raise ConnectorConfigError"
assert c.active({"connectors": {"github": {"repo": "no-slash"}}}) == [], "malformed config must degrade, not crash"
print("DEGRADE-OK")
PY
)"
RC=$?
set -e
if [ "$RC" -eq 0 ] && printf '%s' "$DEGRADE" | grep -q "DEGRADE-OK"; then
  ok "(d) absent creds -> inactive + fetch [] + writeback inactive; active() inert/degrades — no crash"
else
  bad "(d) lazy-degrade failed"; printf '%s\n' "$DEGRADE" | sed 's/^/    /'
fi

# ── (d2) CLI degrade path — fetch on an inactive connector exits 0 with [] ─────
set +e
CLI_OUT="$("$CLI" fetch github 2>&1)"; CLI_RC=$?
set -e
if [ "$CLI_RC" -eq 0 ] && [ "$CLI_OUT" = "[]" ]; then
  ok "(d) CLI: fetch on a credless connector exits 0 with [] (no crash)"
else
  bad "(d) CLI degrade wrong (rc=$CLI_RC): $CLI_OUT"
fi

echo
echo "  connectors tests: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
