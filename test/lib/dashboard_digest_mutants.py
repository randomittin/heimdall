#!/usr/bin/env python3
"""test/lib/dashboard_digest_mutants.py -- does test/lib/dashboard_digest_cases.py actually notice when the digest is wrong?

usage: dashboard_digest_mutants.py <repo> <tmp>

For each mutant: copy bin/lib, change ONE rule in ONE file (the text to change must be found exactly once, else the mutant itself is
broken and reported), run the whole case file against that copy (DIGEST_LIB), and demand that it FAILS -- a `bad` line, or a crash, or
no `done`. A mutant the cases survive is a rule nothing tests. Prints `ok <name>` per killed mutant and `bad <name>` per survivor.
"""
import concurrent.futures
import os
import shutil
import subprocess
import sys

code, tmp = sys.argv[1], sys.argv[2]
LIB = os.path.join(code, "bin", "lib")
CASES = os.path.join(code, "test", "lib", "dashboard_digest_cases.py")

# (name, file, text, replacement)
MUTANTS = [
    ("due-boundary-off-by-one", "dashboard_digest.py", 'minute >= at_minutes(config["at"])', 'minute > at_minutes(config["at"])'),
    ("once-per-day-guard-gone", "dashboard_digest.py", "return day != last_day and", "return True and"),
    ("claim-does-not-spend-the-day", "dashboard_digest.py", "state.update(last_day=day, last_at=int(now), counts=_zero())",
     "state.update(last_at=int(now), counts=_zero())"),
    ("claim-keeps-the-counters", "dashboard_digest.py", "state.update(last_day=day, last_at=int(now), counts=_zero())",
     "state.update(last_day=day, last_at=int(now))"),
    ("timezone-sign-flipped", "dashboard_digest.py", "t = time.gmtime(now + tz_min * 60)", "t = time.gmtime(now - tz_min * 60)"),
    ("values-on-by-default", "dashboard_digest.py", 'if taken["include_values"] else []', "else []"),
    ("skip-when-empty-gone", "dashboard_digest.py", "if not any(counts.values()) and not tiles:\n        return None", "if False:\n        return None"),
    ("four-tiles-allowed", "dashboard_digest.py", "len(v) <= MAX_TILES and", "len(v) <= MAX_TILES + 1 and"),
    ("duplicate-tiles-allowed", "dashboard_digest.py", "len(v) <= MAX_TILES and len(set(v)) == len(v)", "len(v) <= MAX_TILES"),
    ("line-cap-gone", "dashboard_digest.py", "if len(lines) >= MAX_LINES:", "if False:"),
    ("body-limit-raised", "dashboard_digest.py", "BODY_MAX = 160", "BODY_MAX = 900"),
    ("title-limit-raised", "dashboard_digest.py", "TITLE_UNITS = 24", "TITLE_UNITS = 90"),
    ("secret-check-gone", "dashboard_digest.py", "or check is None or check(title) or check(value):", ":"),
    ("scrub-gone", "dashboard_digest.py", "tools.scrub(title, TITLE_UNITS), tools.scrub(value, VALUE_UNITS)", "title, value"),
    ("stale-tile-shown", "dashboard_digest.py", 'and panel.get("stale") is False', "and True"),
    ("non-live-tile-shown", "dashboard_digest.py", 'tile.get("phase") == "live"', "True"),
    ("event-dedupe-gone", "dashboard_digest.py", 'if key not in state["seen"]:', "if True:"),
    ("counted-while-off", "dashboard_digest.py", 'if not (state["config"] and state["config"]["on"]):\n            return False, 0', "if False:\n            return False, 0"),
    ("turning-on-keeps-old-counts", "dashboard_digest.py", 'state["counts"], state["last_at"] = _zero(), int(now)', 'state["last_at"] = int(now)'),
    ("tz-range-widened", "dashboard_digest.py", "-840 <= v <= 840", "-840 <= v <= 900"),
    ("at-accepts-24", "dashboard_digest.py", "(?:[01][0-9]|2[0-3])", "(?:[0-2][0-9])"),
    ("bool-accepted-as-tz", "dashboard_digest.py", "isinstance(v, int) and not isinstance(v, bool) and -840", "isinstance(v, int) and -840"),
    ("verdict-counted-as-finished", "dashboard_digest.py", 'return "verdicts" if variant == "verdict" else', 'return "finished" if variant == "verdict" else'),
    ("alerts-not-counted", "dashboard_digest.py", 'return "alerts" if kind == "tile_alert" else None', "return None"),
    ("cap-gate-gone", "companion_dashboards.py", 'if fields["op"] == "set-digest" and _digest().CAP_DIGEST not in (getattr(ctx, "caps", None) or ()):', "if False:"),
    ("foreign-tile-accepted", "companion_dashboards.py", 'if any(_find(root, tile_id) is None for tile_id in f["tiles"]):', "if False:"),
    ("push-off-gone", "companion_dashboards.py", 'if not digest.available() or store is None or not store.load(root)["tokens"]:', "if False:"),
    ("digest-kind-ttl", "dashboard_digest.py", "ttl=21600, cap=CAP_DIGEST", "ttl=3600, cap=CAP_DIGEST"),
    ("digest-title-phrase", "dashboard_digest.py", 'phrase="morning report"', 'phrase="daily report"'),
    ("digest-channel", "dashboard_digest.py", 'channel="hmd-updates"', 'channel="hmd-attention"'),
    ("digest-level", "dashboard_digest.py", 'level="active"', 'level="time-sensitive"'),
    ("non-sender-spends-the-day", "companion_push.py", 'for rec in data["devices"].values()) and self._own_lock():', 'for rec in data["devices"].values()) and True:'),
    ("no-phone-asked-spends-the-day", "companion_push.py", 'if data is not None and any("digest" in rec["events"] for rec in data["devices"].values()) and',
     "if data is not None and"),
    ("dashboards-switch-ignored", "companion_push.py", "self._scheduler().fire(now, rows, self._dashboards_on)", "self._scheduler().fire(now, rows)"),
    ("digest-kind-not-registered", "companion_push.py", 'KIND_MODULES = ("dashboard_alerts", "dashboard_digest")', 'KIND_MODULES = ("dashboard_alerts",)'),
    ("digest-is-a-default-kind", "companion_push.py", '"error", "gate_red", "finished"))\n\n\ndef _fingerprint', '"error", "gate_red", "finished", "digest"))\n\n\ndef _fingerprint'),
    ("digest-body-flattened-to-one-line", "dashboard_digest.py", "lines=MAX_LINES,", "lines=1,"),
    ("digest-body-cut-at-the-default", "dashboard_digest.py", "body_max=BODY_MAX, lines=MAX_LINES,", "lines=MAX_LINES,"),
    ("digest-scope-ignored", "dashboard_digest.py", 'if fields.get("project") else None)', "if False else None)"),
    ("spooled-alerts-not-counted", "companion_push.py", "self._record_digest(batch + spooled, now)", "self._record_digest(batch, now)"),
    ("push-scrub-bypassed", "dashboard_digest.py", "body=lambda fields: compose_body(fields, kit),",
     'body=lambda fields: compose_body(fields, __import__("types").SimpleNamespace(scrub=lambda t, n=0: t, clip=kit.clip, utf16_len=kit.utf16_len, secret_shaped=kit.secret_shaped)),'),
]


def run_one(index, mutant):
    name, filename, old, new = mutant
    work = os.path.join(tmp, "mutant-%02d" % index)
    shutil.rmtree(work, ignore_errors=True)
    shutil.copytree(LIB, os.path.join(work, "lib"), ignore=shutil.ignore_patterns("__pycache__"))
    target = os.path.join(work, "lib", filename)
    with open(target, encoding="utf-8") as f:
        text = f.read()
    if text.count(old) != 1:
        return name, "broken", "the text to mutate occurs %d times in %s" % (text.count(old), filename)
    with open(target, "w", encoding="utf-8") as f:
        f.write(text.replace(old, new))
    env = dict(os.environ, DIGEST_LIB=os.path.join(work, "lib"))
    try:
        proc = subprocess.run([sys.executable, CASES, code, os.path.join(work, "run")], env=env, capture_output=True, text=True, timeout=300)
    except subprocess.TimeoutExpired:
        return name, "killed", "timeout"
    out = proc.stdout.splitlines()
    failing = [line for line in out if line.startswith("bad ")]
    if failing or proc.returncode != 0 or "done" not in out:
        return name, "killed", (failing[0] if failing else "crashed or did not finish")[:90]
    return name, "survived", ""


with concurrent.futures.ThreadPoolExecutor(max_workers=6) as pool:
    results = list(pool.map(lambda pair: run_one(*pair), enumerate(MUTANTS)))
for name, verdict, why in results:
    if verdict == "killed":
        print("ok mutant %s is caught (%s)" % (name, why))
    else:
        print("bad mutant %s %s %s" % (name, verdict.upper(), why))
print("done")
