#!/usr/bin/env bash
#
# skills-manifest-transcription.test.sh -- 3.x M1, T1.1: skills.manifest.json is a faithful transcription of the three legacy skill
# mechanisms and of the code that implements them.
#
# Plan: docs/superpowers/plans/2026-11-12-3x-m1-skill-registry.md ("Stage 0" A, "Target formats", T1.1). skills.manifest.json is to become the
# ONE source of skill and plugin mappings; until the flag skills.registry is on, heimdall-skills.json, skills-registry.json and
# plugin-autoinstall.md (with preinstall_plugins() and first_run_setup() of bin/heimdall) stay authoritative and the manifest only RECORDS them.
# A record that drifts from what it records is worse than none, so nothing in this suite is a copy of a legacy fact: every expectation (the
# plugins, the ERE of each preinstall rule, the keywords, the marketplaces, the doc rows, the bundled skills) is read FROM THE LEGACY FILES when
# the suite runs, and the manifest is held to it field by field.
#
# plugin-autoinstall.md is the one legacy file whose legacy text is no longer on disk: since 93532a61 (T5.3) its install rows are GENERATED from
# the manifest (bin/lib/skills_render_doc.py), so the `claude plugins install` rows this suite transcribes are read from git history, as the doc
# stood the last time it carried no `BEGIN GENERATED skills.manifest` block. That commit is found by CONTENT, never by a SHA, so a rebase cannot
# move it. With no history to read it from (a shallow clone, a tree with no .git) the suite FAILS and says why: it never skips, and it never
# reads the generated rows in their place. The doc mutants of D change that extracted legacy text; the live doc and the manifest are not touched.
#
# Proven here:
#   A. the validator (bin/lib/skills_manifest.py, T0.3) accepts the manifest;
#   B. transcription, one line per group:
#        marketplaces      == the case arms of hmd_marketplace_source() (bin/lib/install-receipt.sh); the marketplace first_run_setup registers is listed
#        plugins           one entry per plugin ref any legacy mechanism names (heimdall-skills.json, the preinstall rules, the first-run install,
#                          plugin-autoinstall.md), with its marketplace; install is true exactly when that marketplace is on the allow-list, so
#                          caveman@caveman and design-for-ai@rtd are the activation-only ones; no entry without a legacy source, none twice
#        tiers             first-run + preinstall + auto-install plugins recommended, the on_demand list on_demand (in its order), the other plugins
#                          detected, the registry skills detected, the skills/ directories bundled
#        activation        permanent / detection rules of every plugin, and the order of the permanent plugins
#        detection_rules   verbatim from heimdall-skills.json, rules and entries in its order
#        triggers          every preinstall prompt rule's EXACT ERE string, its position in the code, and the file rules with their contains_any
#                          words; no other entry carries a trigger
#        github            every skills-registry.json skill field for field, in registry order (entries and keyword_skills)
#        bundled           one entry per skills/<name>/SKILL.md, in-tree, never installed
#        pointers          legacy[]: every legacy mapping (a heimdall-skills.json bucket, a preinstall rule, a plugin-autoinstall.md row, a registry
#                          skill, a bundled skill) is pointed at by exactly one pointer, and no pointer points nowhere
#      The legacy plugin-autoinstall.md behind those rows is found in history, and that lookup is run against seven throwaway repositories as
#      well: it reads the newest revision with no generated block (not the oldest), passes over every generated revision and a deletion, and
#      FAILS, naming the reason, on a doc generated from its first commit, on a shallow clone and on a repository with no commit;
#   C. the commit that added skills.manifest.json changed no legacy file (while it is uncommitted: the work tree and index hold no edit of one);
#      the check is run against five throwaway repositories as well, so it is known to go RED;
#   D. every check above can go RED: ONE fact of the manifest, or of a legacy file, is changed at a time, in memory, and the check that guards it
#      must fire. The legacy side matters as much as the manifest side: it is what shows the expectations are read from the legacy files.
#
# Hermetic: reads the repository, writes only to throwaway directories; no network.
#
# Usage: test/skills-manifest-transcription.test.sh      Exit 0 = every proof holds.
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SELF_DIR/.." && pwd)"
PASS=0; FAIL=0; SKIP=0
ok()   { printf '  \033[32mPASS\033[0m %s\n' "$1"; PASS=$((PASS + 1)); }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAIL=$((FAIL + 1)); }
skip() { printf '  \033[33mSKIP\033[0m %s\n' "$1"; SKIP=$((SKIP + 1)); }

PY="$(command -v python3 || true)"
[ -n "$PY" ] || { echo "FATAL: python3 not found"; exit 2; }
# the real interpreter, not a version-manager shim (0.4 s a call)
PYREAL="$("$PY" -I -c 'import sys; print(sys.executable)' 2>/dev/null)"
if [ -n "$PYREAL" ] && [ -x "$PYREAL" ]; then PY="$PYREAL"; fi

MANIFEST="$REPO/skills.manifest.json"
VALIDATOR="$REPO/bin/lib/skills_manifest.py"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# ── the checker: every expectation is read from the legacy files, never held here ─────
cat > "$WORK/check.py" <<'PYEOF'
"""check.py -- the proofs of skills-manifest-transcription.test.sh that are easier in python than in bash.

    check.py transcription REPO MANIFEST   the manifest against the legacy files, one line per group
    check.py legacydoc REPO                the legacy plugin-autoinstall.md is found in history (and that lookup goes RED when it is not there)
    check.py history REPO                  the commit that added the manifest changed no legacy file (and that check goes RED on a bad one)
    check.py mutants REPO MANIFEST         each check goes RED when ONE fact of the manifest or of a legacy file is changed
Every line printed is `ok<TAB>text`, `bad<TAB>text` or `skip<TAB>text`; the exit status is 0 unless the program itself broke.
"""
import copy
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile

MANIFEST = "skills.manifest.json"
LAUNCHER = "bin/heimdall"
RECEIPT = "bin/lib/install-receipt.sh"
DOC = "skills/heimdall/references/plugin-autoinstall.md"
CONFIG = "heimdall-skills.json"
REGISTRY = "skills-registry.json"
# the legacy mechanisms the manifest transcribes: the data and prose they live in, and the code that implements them
LEGACY_FILES = (CONFIG, REGISTRY, DOC, LAUNCHER, "bin/skill-manager", "bin/discover-skills", "bin/lib/skill_restore.py", RECEIPT)
GROUPS = ("legacy", "marketplaces", "plugins", "tiers", "activation", "detection_rules", "triggers", "github", "bundled", "pointers")
GROUP_OF_KIND = {"plugin": "plugins", "github-skill": "github", "bundled": "bundled"}
# kind -> [(group, field)]: fields compared with what the legacy files say; an absent field must be absent on both sides
FIELDS = {
    "plugin": [("plugins", "ref"), ("plugins", "marketplace"), ("plugins", "install"), ("tiers", "tier"),
               ("activation", "activate"), ("triggers", "triggers")],
    "github-skill": [("github", "repo"), ("github", "description"), ("github", "keywords"), ("github", "category"),
                     ("github", "install"), ("tiers", "tier"), ("github", "activate"), ("github", "triggers")],
    "bundled": [("bundled", "ref"), ("bundled", "install"), ("tiers", "tier"), ("bundled", "activate"), ("bundled", "triggers")],
}
AUTO_ROW = re.compile(r"^\| [^|]+ \| ([a-z0-9][a-z0-9._-]*) \| `claude plugins install ([a-z0-9][a-z0-9._-]*)@([a-z0-9][a-z0-9._-]*)` \|$", re.M)
MID_ROW = re.compile(r"^\| [^|]+ \| `([a-z0-9][a-z0-9._-]*)` \|$", re.M)
# the line that opens a generated block (BEGIN_PREFIX of bin/lib/skills_render_doc.py): a doc that holds one is not legacy text
GENERATED = re.compile(r"^<!-- BEGIN GENERATED skills\.manifest", re.M)
WORD = r"([A-Za-z0-9._-]+)"


class Legacy(Exception):
    """The legacy files cannot be read the way this suite reads them (a shape it does not know is a failure, never a pass)."""


def git(repo, *args):
    env = {key: value for key, value in os.environ.items() if not key.startswith("GIT_")}
    env.update({"GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": os.devnull, "GIT_TERMINAL_PROMPT": "0", "LC_ALL": "C"})
    try:
        done = subprocess.run(["git", "-C", repo] + list(args), env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                              encoding="utf-8", errors="replace", timeout=60)
    except (OSError, subprocess.SubprocessError) as exc:
        return 127, "", str(exc)
    return done.returncode, done.stdout, done.stderr


def legacy_doc(repo):
    """(commit, text) of plugin-autoinstall.md as it stood the last time it carried no generated block.

    Its install rows are generated from the manifest now, so the `claude plugins install` rows the manifest transcribes live only in history.
    The commit is found by CONTENT (the newest revision of the doc with no `BEGIN GENERATED skills.manifest` line), never by a SHA a rebase
    would move. No history to find it in is a Legacy failure that says so: never a pass, and the generated rows are never read in its place."""
    rc, out, err = git(repo, "log", "--format=%H", "--topo-order", "--diff-filter=d", "--", DOC)
    if rc != 0:
        raise Legacy("%s: its legacy rows live in git history (it is generated from %s now) and git cannot read it: %s"
                     % (DOC, MANIFEST, err.strip()[:120]))
    commits = out.split()
    for commit in commits:
        rc, text, err = git(repo, "show", "%s:./%s" % (commit, DOC))
        if rc != 0:
            raise Legacy("%s: cannot read it as of %s: %s" % (DOC, commit[:10], err.strip()[:120]))
        if not GENERATED.search(text):
            return commit, text
    shallow = git(repo, "rev-parse", "--is-shallow-repository")[1].strip() == "true"
    raise Legacy("%s: its legacy rows live in git history, but no commit of this clone holds it without a generated block (%d read)%s"
                 % (DOC, len(commits), "; this clone is shallow: git fetch --unshallow" if shallow else ""))


class Source:
    """The legacy side. Every fact the manifest must carry is read from these files now (plugin-autoinstall.md from history: see legacy_doc);
    `over` replaces the text of a file and `bundled` the list of bundled skills (the mutants, in memory), nothing else is ever substituted."""

    def __init__(self, repo, over=None, bundled=None):
        self.repo, self.over, self.names, self.cache = repo, dict(over or {}), bundled, {}

    def read(self, rel):
        if rel == DOC:
            return legacy_doc(self.repo)[1]
        try:
            with open(os.path.join(self.repo, rel), encoding="utf-8") as handle:
                return handle.read()
        except OSError as exc:
            raise Legacy("cannot read %s: %s" % (rel, exc.strerror or exc))

    def text(self, rel):
        if rel in self.over:
            return self.over[rel]
        if rel not in self.cache:
            self.cache[rel] = self.read(rel)
        return self.cache[rel]

    def bundled(self):
        if self.names is not None:
            return list(self.names)
        root = os.path.join(self.repo, "skills")
        try:
            found = os.listdir(root)
        except OSError as exc:
            raise Legacy("cannot list skills/: %s" % (exc.strerror or exc))
        return sorted(name for name in found if os.path.isfile(os.path.join(root, name, "SKILL.md")))

    def with_over(self, over=None, bundled=None):
        merged = dict(self.over)
        merged.update(over or {})
        clone = Source(self.repo, merged, self.names if bundled is None else bundled)
        clone.cache = self.cache
        return clone


def function_text(text, name):
    """One top-level shell function: from `name() {` to the first `}` in column 0."""
    found = re.search(r"^%s\(\) \{\n.*?^\}\n" % re.escape(name), text, re.S | re.M)
    if not found:
        raise Legacy("no function %s() in the legacy source" % name)
    return found.group(0)


def loads(src, rel):
    try:
        return json.loads(src.text(rel))
    except ValueError as exc:
        raise Legacy("%s is not JSON: %s" % (rel, exc))


def expect(src):
    """What the legacy files say the manifest must carry: {want, pointers, allow, first_markets, rules, permanent, on_demand, names, counts}."""
    cfg = loads(src, CONFIG)
    registry = loads(src, REGISTRY).get("skills")
    if not (isinstance(registry, list) and registry):
        raise Legacy("%s lists no skills" % REGISTRY)
    launcher = src.text(LAUNCHER)
    pre = function_text(launcher, "preinstall_plugins")
    first = function_text(launcher, "first_run_setup")
    prompt_rules = re.findall(r"grep -qE '([^']+)' && _try_install \"([^\"]+)\"", pre)
    market = re.search(r'hmd_install_known_plugin "\$1" %s prompt-preinstall' % WORD, pre)
    first_installs = re.findall(r"hmd_install_known_plugin %s %s first-run" % (WORD, WORD), first)
    first_markets = re.findall(r"hmd_marketplace_add %s first-run" % WORD, first)
    if not (prompt_rules and market and first_installs and first_markets):
        raise Legacy("%s: cannot read the prompt rules, the marketplace they install from or the first-run installs" % LAUNCHER)
    file_rules = []
    for line in pre.splitlines():
        if not line.lstrip().startswith('[ -f "$WORK_DIR/'):
            continue
        plugin = re.search(r'_try_install "([^"]+)"\s*$', line)
        if plugin is None:
            raise Legacy("%s: a file rule that does not end in _try_install: %s" % (LAUNCHER, line.strip()))
        words = {path: found.split("\\|") for found, path in re.findall(r'grep -q "([^"]+)" "\$WORK_DIR/([^"]+)"', line)}
        paths = re.findall(r'\[ -f "\$WORK_DIR/([^"]+)" \]', line)
        file_rules.append((plugin.group(1), [(path, words.get(path)) for path in paths]))
    if not file_rules:
        raise Legacy("%s: no file rule in preinstall_plugins" % LAUNCHER)
    arms = re.findall(r"^\s+%s\)\s+printf '%%s' \"([^\"]+)\" ;;" % WORD, function_text(src.text(RECEIPT), "hmd_marketplace_source"), re.M)
    if not arms:
        raise Legacy("%s: hmd_marketplace_source lists no marketplace" % RECEIPT)
    allow = {}
    for name, source in arms:
        base, _, pin = source.partition("#")
        allow[name] = {"source": base, "pin": pin or None}
    doc = src.text(DOC)
    auto = []
    for plugin, run_plugin, run_market in AUTO_ROW.findall(doc):
        if plugin != run_plugin:
            raise Legacy("%s: the row for %s installs %s" % (DOC, plugin, run_plugin))
        auto.append((run_plugin, run_market))
    mid = MID_ROW.findall(doc)
    if not (auto and mid):
        raise Legacy("%s: cannot read the auto-install or the mid-task table" % DOC)

    pre_market = market.group(1)
    refs = []

    def add(value):
        if not (isinstance(value, str) and value.count("@") == 1):
            raise Legacy("not a <plugin>@<marketplace> ref: %r" % (value,))
        if value not in refs:
            refs.append(value)

    permanent, on_demand, detection = cfg.get("permanent", []), cfg.get("on_demand", []), cfg.get("detection", {})
    for value in permanent + [p for spec in detection.values() for p in spec.get("plugins", [])] + on_demand:
        add(value)
    for _, plugin in prompt_rules:
        add("%s@%s" % (plugin, pre_market))
    for plugin, where in first_installs + auto:
        add("%s@%s" % (plugin, where))
    ids = {}
    for value in refs:
        if value.split("@")[0] in ids:
            raise Legacy("two legacy plugins share the id %r" % value.split("@")[0])
        ids[value.split("@")[0]] = value
    recommended = set("%s@%s" % (p, w) for p, w in first_installs + auto) | set("%s@%s" % (p, pre_market) for _, p in prompt_rules)

    pointers = {}

    def point(ident, mechanism, path):
        pointers.setdefault(ident, []).append((mechanism, path))

    triggers = {}
    for n, (ere, plugin) in enumerate(prompt_rules, 1):
        if plugin in triggers:
            raise Legacy("%s: two prompt rules for %s" % (LAUNCHER, plugin))
        triggers[plugin] = {"order": n, "prompt_ere": ere}
        point(plugin, "bin/heimdall:preinstall_plugins", "prompt rule %d" % n)
    for n, (plugin, found) in enumerate(file_rules, 1):
        if plugin not in triggers:
            raise Legacy("%s: a file rule for %s, which has no prompt rule to take its order from" % (LAUNCHER, plugin))
        for path, words in found:
            item = {"path": path}
            if words:
                item["contains_any"] = words
            triggers[plugin].setdefault("files", []).append(item)
        point(plugin, "bin/heimdall:preinstall_plugins", "file rule %d" % n)
    for plugin, _ in first_installs:
        point(plugin, "bin/heimdall:first_run_setup", "install %s" % plugin)
    for n, (plugin, _) in enumerate(auto, 1):
        point(plugin, "plugin-autoinstall.md", "auto-install map row %d" % n)
    for n, plugin in enumerate(mid, 1):
        if plugin not in ids:
            raise Legacy("%s: mid-task row %d names %s, which no other legacy mechanism gives a marketplace" % (DOC, n, plugin))
        point(plugin, "plugin-autoinstall.md", "mid-task signal row %d" % n)
    for value in permanent:
        point(value.split("@")[0], "heimdall-skills.json", "permanent")
    for rule, spec in detection.items():
        for value in spec.get("plugins", []):
            point(value.split("@")[0], "heimdall-skills.json", "detection.%s" % rule)
    for value in on_demand:
        point(value.split("@")[0], "heimdall-skills.json", "on_demand")

    want = {}
    for value in refs:
        plugin, where = value.split("@")
        detect = [rule for rule, spec in detection.items() if value in spec.get("plugins", [])]
        want[plugin] = {
            "kind": "plugin", "ref": value, "marketplace": where, "install": where in allow,
            "tier": "recommended" if value in recommended else "on_demand" if value in on_demand else "detected",
            "activate": {"permanent": value in permanent, "detect": detect} if (value in permanent or detect) else None,
            "triggers": triggers.get(plugin)}
    for n, skill in enumerate(registry):
        if skill["name"] in want:
            raise Legacy("%s: %s is also a plugin id" % (REGISTRY, skill["name"]))
        want[skill["name"]] = {
            "kind": "github-skill", "repo": skill["repo"], "description": skill["description"], "keywords": skill["keywords"],
            "category": skill["category"], "install": True, "tier": "detected", "activate": None, "triggers": None}
        point(skill["name"], "skills-registry.json", "skills[%d]" % n)
    for name in src.bundled():
        if name in want:
            raise Legacy("skills/%s is also a plugin or registry id" % name)
        want[name] = {"kind": "bundled", "ref": "skills/%s" % name, "install": False, "tier": "bundled", "activate": None, "triggers": None}
        point(name, "skills/", "skills/%s/SKILL.md" % name)
    kinds = [w["kind"] for w in want.values()]
    return {
        "want": want, "pointers": pointers, "allow": allow, "first_markets": first_markets,
        "rules": {rule: {"files": spec.get("files", []), "entries": [v.split("@")[0] for v in spec.get("plugins", [])]}
                  for rule, spec in detection.items()},
        "permanent": permanent, "on_demand": on_demand, "names": [skill["name"] for skill in registry],
        "counts": {"plugins": kinds.count("plugin"), "github": kinds.count("github-skill"), "bundled": kinds.count("bundled"),
                   "prompt": len(prompt_rules), "files": len(file_rules), "rows": len(auto) + len(mid), "markets": len(allow),
                   "rules": len(detection), "pointers": sum(len(v) for v in pointers.values())}}


def short(value, limit=150):
    text = repr(value)
    return text if len(text) <= limit else text[:limit - 3] + "..."


def problems(src, doc):
    """group -> the reasons the manifest `doc` is not a faithful transcription of the legacy files read through `src`."""
    out = {group: [] for group in GROUPS}
    try:
        legacy = expect(src)
    except Legacy as exc:
        out["legacy"].append(str(exc))
        return out
    entries = doc.get("entries") if isinstance(doc, dict) else None
    if not (isinstance(entries, list) and all(isinstance(entry, dict) for entry in entries)):
        out["plugins"].append("entries is not an array of objects")
        return out
    want = legacy["want"]
    seen = {}
    for entry in entries:
        seen.setdefault(entry.get("id"), []).append(entry)
    for ident, found in seen.items():
        group = GROUP_OF_KIND.get(found[0].get("kind"), "plugins")
        if len(found) > 1:
            out[group].append("%s appears %d times" % (ident, len(found)))
        elif ident not in want:
            out[group].append("%s has no legacy source" % ident)
    for ident, expected in want.items():
        found = seen.get(ident, [])
        if not found:
            out[GROUP_OF_KIND[expected["kind"]]].append("%s is missing" % ident)
            continue
        entry = found[0]
        if entry.get("kind") != expected["kind"]:
            out[GROUP_OF_KIND[expected["kind"]]].append("%s is kind %r, the legacy files make it %r" % (ident, entry.get("kind"), expected["kind"]))
            continue
        for group, field in FIELDS[expected["kind"]]:
            if entry.get(field) != expected.get(field):
                out[group].append("%s: %s is %s, the legacy files say %s" % (ident, field, short(entry.get(field)), short(expected.get(field))))
        listed = entry.get("legacy") if isinstance(entry.get("legacy"), list) else []
        got = sorted(((p.get("mechanism"), p.get("path")) for p in listed if isinstance(p, dict)), key=repr)
        wanted = sorted(legacy["pointers"].get(ident, []), key=repr)
        if got != wanted:
            out["pointers"].append("%s: legacy[] is %s, the legacy files point at %s" % (ident, short(got), short(wanted)))

    markets = doc.get("marketplaces")
    if markets != legacy["allow"]:
        out["marketplaces"].append("marketplaces is %s, hmd_marketplace_source() says %s" % (short(markets), short(legacy["allow"])))
    for name in legacy["first_markets"]:
        if name not in (markets if isinstance(markets, dict) else {}):
            out["marketplaces"].append("first_run_setup registers %s but marketplaces does not list it" % name)

    rules = doc.get("detection_rules")
    for name in sorted(set(rules if isinstance(rules, dict) else {}) | set(legacy["rules"])):
        have = rules.get(name) if isinstance(rules, dict) else None
        if have != legacy["rules"].get(name):
            out["detection_rules"].append("%s is %s, heimdall-skills.json says %s" % (name, short(have), short(legacy["rules"].get(name))))
    if isinstance(rules, dict) and list(rules) != list(legacy["rules"]):
        out["detection_rules"].append("the rules come in the order %s, heimdall-skills.json lists %s" % (list(rules), list(legacy["rules"])))

    names = legacy["names"]
    if doc.get("keyword_skills") != names:
        out["github"].append("keyword_skills is %s, skills-registry.json lists %s" % (short(doc.get("keyword_skills")), short(names)))
    order = [entry.get("id") for entry in entries if entry.get("kind") == "github-skill"]
    if order != names:
        out["github"].append("the github-skill entries come in the order %s, skills-registry.json lists %s" % (short(order), short(names)))
    permanent = [entry.get("ref") for entry in entries if isinstance(entry.get("activate"), dict) and entry["activate"].get("permanent") is True]
    if permanent != legacy["permanent"]:
        out["activation"].append("the permanent plugins are %s in that order, heimdall-skills.json lists %s" % (short(permanent), short(legacy["permanent"])))
    on_demand = [entry.get("ref") for entry in entries if entry.get("tier") == "on_demand"]
    if on_demand != legacy["on_demand"]:
        out["tiers"].append("the on_demand entries are %s in that order, heimdall-skills.json lists %s" % (short(on_demand), short(legacy["on_demand"])))
    return out


DESCRIBE = {
    "legacy": "legacy: read %(plugins)d plugin refs, %(github)d registry skills, %(bundled)d bundled skills, %(prompt)d prompt rules, %(files)d file rules and %(rows)d plugin-autoinstall.md rows (read from history)",
    "marketplaces": "marketplaces: equal to the %(markets)d case arms of hmd_marketplace_source(), and the one first_run_setup registers is listed",
    "plugins": "plugins: %(plugins)d entries, one per plugin ref the legacy mechanisms name, each with its marketplace and install flag; none without a legacy source",
    "tiers": "tiers: recommended = first-run + preinstall + auto-install, on_demand = the on_demand list in order, other plugins and registry skills detected, skills/ bundled",
    "activation": "activation: permanent and detection rules of every plugin as heimdall-skills.json has them, permanent plugins in its order",
    "detection_rules": "detection_rules: the %(rules)d rules of heimdall-skills.json verbatim, in its order",
    "triggers": "triggers: the %(prompt)d prompt EREs verbatim in code order, the %(files)d file rules with their contains_any words; no other entry carries one",
    "github": "github: the %(github)d skills of skills-registry.json field for field, in registry order (entries and keyword_skills)",
    "bundled": "bundled: the %(bundled)d skills/<name>/SKILL.md directories, in-tree and never installed",
    "pointers": "pointers: legacy[] holds each of the %(pointers)d legacy mappings exactly once and no pointer to nowhere"}


def say(verdict, text):
    print("%s\t%s" % (verdict, text.replace("\t", " ").replace("\n", " ")))


def transcription(repo, path):
    try:
        with open(path, encoding="utf-8") as handle:
            doc = json.load(handle)
    except (OSError, ValueError) as exc:
        say("bad", "manifest: cannot read %s: %s" % (path, exc))
        return
    src = Source(repo)
    found = problems(src, doc)
    if found["legacy"]:  # the legacy files cannot be read, so no other group was checked: none of them may print an ok
        for reason in found["legacy"]:
            say("bad", "legacy: %s" % reason)
        return
    counts = expect(src)["counts"]
    for group in GROUPS:
        if not found[group]:
            say("ok", DESCRIBE[group] % counts)
            continue
        for reason in found[group][:6]:
            say("bad", "%s: %s" % (group, reason))
        if len(found[group]) > 6:
            say("bad", "%s: and %d more" % (group, len(found[group]) - 6))


# ── C. the commit that added the manifest changed no legacy file ───────────────────────
def legacy_untouched(repo):
    """(verdict, text): did the commit that added skills.manifest.json leave every legacy file alone? skip = history cannot tell."""
    rc, out, _ = git(repo, "rev-parse", "--is-inside-work-tree")
    if rc != 0 or out.strip() != "true":
        return "skip", "history: not inside a git work tree, so what the manifest commit changed cannot be read"
    if git(repo, "cat-file", "-e", "HEAD:" + MANIFEST)[0] != 0:
        rc, out, err = git(repo, "diff", "--name-only", "HEAD", "--", *LEGACY_FILES)
        if rc != 0:
            return "skip", "history: git diff against HEAD failed (%s)" % err.strip()[:80]
        touched = [line for line in out.splitlines() if line]
        where = "the work tree and index (skills.manifest.json is not committed yet)"
    else:
        if git(repo, "rev-parse", "--is-shallow-repository")[1].strip() == "true":
            return "skip", "history: a shallow clone, where the commit that added skills.manifest.json is not told from the clone's root"
        rc, out, _ = git(repo, "log", "--diff-filter=A", "-1", "--format=%H", "HEAD", "--", MANIFEST)
        sha = out.strip()
        if rc != 0 or not sha:
            return "skip", "history: cannot find the commit that added skills.manifest.json"
        if len(git(repo, "rev-list", "--parents", "-n", "1", sha)[1].split()) < 2:
            return "skip", "history: skills.manifest.json arrived in a root commit, there is no parent to compare with"
        rc, out, err = git(repo, "diff-tree", "--no-commit-id", "--name-only", "-r", sha)
        if rc != 0:
            return "skip", "history: git diff-tree failed (%s)" % err.strip()[:80]
        touched = [line for line in out.splitlines() if line in LEGACY_FILES]
        where = "the commit that added skills.manifest.json (%s)" % sha[:10]
    if touched:
        return "bad", "history: %s changed legacy file(s): %s" % (where, ", ".join(sorted(touched)))
    return "ok", "history: %s changed no legacy file" % where


def write_file(root, rel, text):
    full = os.path.join(root, rel)
    os.makedirs(os.path.dirname(full), exist_ok=True)
    with open(full, "w", encoding="utf-8") as handle:
        handle.write(text)


def commit_all(root, message):
    git(root, "add", "-A")
    rc, _, err = git(root, "-c", "user.name=t", "-c", "user.email=t@example.invalid", "-c", "commit.gpgsign=false",
                     "-c", "core.hooksPath=" + os.devnull, "commit", "-q", "-m", message)
    if rc != 0:
        raise RuntimeError("git commit failed: %s" % err.strip()[:120])


def throwaway(manifest_commit, edit_in_commit=False, edit_dirty=False, single_commit=False):
    """A repository holding every legacy file, in the shape asked for; the verdict of legacy_untouched() on it."""
    root = tempfile.mkdtemp()
    try:
        git(root, "init", "-q")
        for rel in LEGACY_FILES:
            write_file(root, rel, "v1\n")
        if single_commit:
            write_file(root, MANIFEST, "{}\n")
            commit_all(root, "one")
        else:
            commit_all(root, "base")
            if edit_in_commit:
                write_file(root, "bin/skill-manager", "v2\n")
            if manifest_commit:
                write_file(root, MANIFEST, "{}\n")
                commit_all(root, "manifest")
            elif edit_dirty:
                write_file(root, "bin/skill-manager", "v2\n")
        return legacy_untouched(root)
    finally:
        shutil.rmtree(root, ignore_errors=True)


SCENARIOS = [
    ("the commit that adds the manifest touches only the manifest", dict(manifest_commit=True), "ok", ""),
    ("the commit that adds the manifest also edits a legacy file", dict(manifest_commit=True, edit_in_commit=True), "bad", "bin/skill-manager"),
    ("an uncommitted manifest beside clean legacy files", dict(manifest_commit=False), "ok", ""),
    ("an uncommitted manifest beside a legacy file edited in the work tree", dict(manifest_commit=False, edit_dirty=True), "bad", "bin/skill-manager"),
    ("a manifest that arrives in a root commit is a skip, never a pass", dict(manifest_commit=True, single_commit=True), "skip", "")]


def history(repo):
    say(*legacy_untouched(repo))
    for name, kwargs, verdict, fragment in SCENARIOS:
        try:
            got, text = throwaway(**kwargs)
        except (OSError, RuntimeError) as exc:
            say("bad", "history self-check \"%s\": cannot build its repository: %s" % (name, exc))
            continue
        if got == verdict and fragment in text:
            say("ok", "history self-check: %s -> %s" % (name, verdict))
        else:
            say("bad", "history self-check: %s wants %s naming '%s', got %s: %s" % (name, verdict, fragment, got, text))


# ── the legacy plugin-autoinstall.md is found in history, and the lookup goes RED when it is not there ──────
GEN = ("<!-- BEGIN GENERATED skills.manifest part=auto-install flavour=ask -->\n| Slack | slack | `hmd skills install slack` |\n"
       "<!-- END GENERATED skills.manifest -->\n")
# (what it shows, the commits of the doc as (subject, the text it commits; None deletes the doc), whether the lookup is made in a depth-1
# clone of that repository, the verdict, what the verdict names: the subject of the commit read, or a part of the failure)
DOC_SCENARIOS = [
    ("the newest revision with no generated block is read, not the oldest",
     [("legacy 1", "rows 1\n"), ("legacy 2", "rows 2\n"), ("generated 1", GEN)], False, "ok", "legacy 2"),
    ("every generated revision after it is passed over, not only the newest",
     [("legacy 1", "rows 1\n"), ("generated 1", GEN + "a\n"), ("generated 2", GEN + "b\n"), ("generated 3", GEN + "c\n")], False, "ok", "legacy 1"),
    ("a deletion in between holds no text and is passed over",
     [("legacy 1", "rows 1\n"), ("deleted", None), ("generated 1", GEN)], False, "ok", "legacy 1"),
    ("a doc that was never generated is its own legacy text", [("legacy 1", "rows 1\n")], False, "ok", "legacy 1"),
    ("a doc generated from its first commit has no legacy revision", [("generated 1", GEN)], False, "bad", "without a generated block"),
    ("a shallow clone has no revision before the generated one",
     [("legacy 1", "rows 1\n"), ("generated 1", GEN)], True, "bad", "this clone is shallow"),
    ("a repository with no commit has no history to read", [], False, "bad", "git cannot read it")]


def doc_lookup(steps, shallow):
    """('ok', the subject of the commit legacy_doc() reads) or ('bad', why it cannot), on a throwaway repository with one commit per step."""
    roots = [tempfile.mkdtemp()]
    try:
        git(roots[0], "init", "-q")
        for subject, text in steps:
            if text is None:
                os.remove(os.path.join(roots[0], DOC))
            else:
                write_file(roots[0], DOC, text)
            commit_all(roots[0], subject)
        where = roots[0]
        if shallow:
            where = tempfile.mkdtemp()
            roots.append(where)
            rc, _, err = git(roots[0], "clone", "-q", "--depth", "1", "file://" + roots[0], where)
            if rc != 0:
                raise RuntimeError("git clone failed: %s" % err.strip()[:120])
        try:
            commit = legacy_doc(where)[0]
        except Legacy as exc:
            return "bad", str(exc)
        return "ok", git(where, "log", "-1", "--format=%s", commit)[1].strip()
    finally:
        for path in roots:
            shutil.rmtree(path, ignore_errors=True)


def legacydoc(repo):
    try:
        say("ok", "legacy doc: %s read as of %s, the last commit before it was generated from %s" % (DOC, legacy_doc(repo)[0][:10], MANIFEST))
    except Legacy as exc:
        say("bad", "legacy doc: %s" % exc)
    for name, steps, shallow, verdict, fragment in DOC_SCENARIOS:
        try:
            got, text = doc_lookup(steps, shallow)
        except (OSError, RuntimeError) as exc:
            say("bad", "legacy doc self-check \"%s\": cannot build its repository: %s" % (name, exc))
            continue
        if got == verdict and fragment in text:
            say("ok", "legacy doc self-check: %s -> %s" % (name, verdict))
        else:
            say("bad", "legacy doc self-check: %s wants %s naming '%s', got %s: %s" % (name, verdict, fragment, got, text))


# ── D. every check goes RED on a one-fact defect ───────────────────────────────────────
def step(node, key):
    """One step of a path: a key, an index, or ("id", x) for the entry of that id in a list."""
    if isinstance(key, tuple):
        return next(item for item in node if item.get("id") == key[1])
    return node[key]


def setp(doc, path, value):
    node = doc
    for key in path[:-1]:
        node = step(node, key)
    node[path[-1]] = value


def delp(doc, path):
    node = doc
    for key in path[:-1]:
        node = step(node, key)
    del node[path[-1]]


def E(ident):
    return ("id", ident)


def drop_entry(doc, ident):
    doc["entries"].remove(step(doc["entries"], E(ident)))


def swap_entries(doc, first, second):
    entries = doc["entries"]
    i, j = (entries.index(step(entries, E(ident))) for ident in (first, second))
    entries[i], entries[j] = entries[j], entries[i]


def edit(src, rel, old, new):
    text = src.text(rel)
    if old not in text:
        raise ValueError("%r is no longer in %s: update this mutant" % (old[:60], rel))
    return src.with_over({rel: text.replace(old, new, 1)})


def edit_function(src, rel, name, old, new):
    text = src.text(rel)
    body = function_text(text, name)
    if old not in body:
        raise ValueError("%r is no longer in %s of %s: update this mutant" % (old[:60], name, rel))
    return src.with_over({rel: text.replace(body, body.replace(old, new, 1), 1)})


def edit_json(src, rel, change):
    data = json.loads(src.text(rel))
    change(data)
    return src.with_over({rel: json.dumps(data)})


GHOST = {"id": "ghost", "kind": "plugin", "ref": "ghost@claude-plugins-official", "marketplace": "claude-plugins-official", "install": True,
         "tier": "detected", "why": "ghost", "legacy": [{"mechanism": "heimdall-skills.json", "path": "on_demand"}]}
NEW_SKILL = {"name": "newskill", "repo": "owner/newskill", "description": "d", "keywords": ["k"], "category": "c"}
SLACK_ROW = "| Slack / notifications | slack | `claude plugins install slack@claude-plugins-official` |\n"
SLACK_MID = "| User mentions Slack / notifications mid-conversation | `slack` |\n"
MCP_RULE = "&& _try_install \"mcp-server-dev\"\n"
PRE = "preinstall_plugins"
SOURCES = "hmd_marketplace_source"

# (what changes, the group that must fire, the change to the manifest)
MANIFEST_MUTANTS = [
    ("an entry is dropped", "plugins", lambda d: drop_entry(d, "ralph-loop")),
    ("an entry with no legacy source is added", "plugins", lambda d: d["entries"].append(copy.deepcopy(GHOST))),
    ("an entry is listed twice", "plugins", lambda d: d["entries"].append(copy.deepcopy(step(d["entries"], E("slack"))))),
    ("an activation-only plugin becomes installable", "plugins", lambda d: setp(d, ["entries", E("design-for-ai"), "install"], True)),
    ("a ref moves to another marketplace", "plugins", lambda d: setp(d, ["entries", E("seo"), "ref"], "seo@heimdall-marketplace")),
    ("a marketplace source is edited", "marketplaces", lambda d: setp(d, ["marketplaces", "heimdall-marketplace", "source"], "randomittin/other")),
    ("a marketplace is dropped", "marketplaces", lambda d: delp(d, ["marketplaces", "heimdall-marketplace"])),
    ("a tier is changed", "tiers", lambda d: setp(d, ["entries", E("superpowers"), "tier"], "detected")),
    ("the retired plugin is filed under on_demand", "tiers", lambda d: setp(d, ["entries", E("caveman"), "tier"], "on_demand")),
    ("an activate block is dropped", "activation", lambda d: delp(d, ["entries", E("playwright"), "activate"])),
    ("a permanent plugin stops being permanent", "activation", lambda d: setp(d, ["entries", E("superpowers"), "activate", "permanent"], False)),
    ("the permanent plugins swap places", "activation", lambda d: swap_entries(d, "caveman", "superpowers")),
    ("a detection glob is dropped", "detection_rules", lambda d: delp(d, ["detection_rules", "frontend", "files", 6])),
    ("a detection rule lists its entries in another order", "detection_rules", lambda d: d["detection_rules"]["frontend"]["entries"].reverse()),
    ("the detection rules change places", "detection_rules", lambda d: setp(d, ["detection_rules"], dict(reversed(list(d["detection_rules"].items()))))),
    ("a prompt ERE loses an alternative", "triggers", lambda d: setp(d, ["entries", E("slack"), "triggers", "prompt_ere"], "slack|notification")),
    ("two preinstall rules swap their order", "triggers",
     lambda d: (setp(d, ["entries", E("frontend-design"), "triggers", "order"], 2), setp(d, ["entries", E("devops-toolkit"), "triggers", "order"], 1))),
    ("a file trigger is dropped", "triggers", lambda d: delp(d, ["entries", E("database-toolkit"), "triggers", "files", 1])),
    ("a contains_any word is dropped", "triggers", lambda d: delp(d, ["entries", E("frontend-design"), "triggers", "files", 0, "contains_any", 3])),
    ("an entry loses its file triggers", "triggers", lambda d: delp(d, ["entries", E("devops-toolkit"), "triggers", "files"])),
    ("a trigger appears where the legacy code has none", "triggers", lambda d: setp(d, ["entries", E("playwright"), "triggers"], {"order": 9, "prompt_ere": "e2e"})),
    ("a github skill is dropped", "github", lambda d: drop_entry(d, "godogen")),
    ("a keyword is dropped", "github", lambda d: delp(d, ["entries", E("claude-ads"), "keywords", 7])),
    ("a repo is edited", "github", lambda d: setp(d, ["entries", E("godogen"), "repo"], "htdt/other")),
    ("keyword_skills changes order", "github", lambda d: d["keyword_skills"].reverse()),
    ("a bundled skill is dropped", "bundled", lambda d: drop_entry(d, "stacks")),
    ("a legacy pointer is dropped", "pointers", lambda d: delp(d, ["entries", E("playwright"), "legacy", 0])),
    ("a legacy pointer points nowhere", "pointers",
     lambda d: step(d["entries"], E("code-review"))["legacy"].append({"mechanism": "heimdall-skills.json", "path": "detection.nowhere"})),
    ("a legacy pointer is renumbered", "pointers", lambda d: setp(d, ["entries", E("devops-toolkit"), "legacy", 0, "path"], "prompt rule 9"))]

# (what changes in a LEGACY file, the group that must fire, the change); the manifest stays as it is
LEGACY_MUTANTS = [
    ("heimdall-skills.json names one more permanent plugin", "plugins",
     lambda s: edit_json(s, CONFIG, lambda d: d["permanent"].append("extra@claude-plugins-official"))),
    ("heimdall-skills.json: a detection rule gains a glob", "detection_rules",
     lambda s: edit_json(s, CONFIG, lambda d: d["detection"]["docs"]["files"].append("README.md"))),
    ("heimdall-skills.json: an on_demand plugin goes", "plugins", lambda s: edit_json(s, CONFIG, lambda d: d["on_demand"].pop())),
    ("skills-registry.json gains a skill", "github", lambda s: edit_json(s, REGISTRY, lambda d: d["skills"].append(NEW_SKILL))),
    ("skills-registry.json: a keyword is renamed", "github", lambda s: edit_json(s, REGISTRY, lambda d: d["skills"][0]["keywords"].__setitem__(0, "uix"))),
    ("bin/heimdall: a prompt rule's ERE is edited", "triggers",
     lambda s: edit_function(s, LAUNCHER, PRE, "'slack|notification|webhook'", "'slack|notification'")),
    ("bin/heimdall: a ninth prompt rule", "plugins",
     lambda s: edit_function(s, LAUNCHER, PRE, MCP_RULE, MCP_RULE + "  echo \"$prompt_lower\" | grep -qE 'billing|invoice' && _try_install \"billing-toolkit\"\n")),
    ("bin/heimdall: a file rule's path is renamed", "triggers", lambda s: edit_function(s, LAUNCHER, PRE, "ormconfig.json", "ormconfig.yaml")),
    ("bin/heimdall: the package.json words change", "triggers",
     lambda s: edit_function(s, LAUNCHER, PRE, "react\\|vue\\|angular\\|svelte", "react\\|vue\\|angular")),
    ("bin/heimdall: the first-run marketplace changes", "marketplaces",
     lambda s: edit_function(s, LAUNCHER, "first_run_setup", "hmd_marketplace_add heimdall-marketplace first-run", "hmd_marketplace_add other-marketplace first-run")),
    ("bin/heimdall: preinstall_plugins disappears", "legacy", lambda s: edit(s, LAUNCHER, "preinstall_plugins() {", "preinstall_plugins_gone() {")),
    ("bin/lib/install-receipt.sh: a marketplace source changes", "marketplaces",
     lambda s: edit_function(s, RECEIPT, SOURCES, "\"randomittin/heimdall-marketplace\"", "\"randomittin/other-marketplace\"")),
    ("bin/lib/install-receipt.sh: a marketplace is allow-listed", "marketplaces",
     lambda s: edit_function(s, RECEIPT, SOURCES, "    *)", "    extra) printf '%s' \"owner/extra\" ;;\n    *)")),
    ("skills/ gains a bundled skill", "bundled", lambda s: s.with_over(bundled=s.bundled() + ["newskill"])),
    ("plugin-autoinstall.md: a row joins the auto-install table", "plugins",
     lambda s: edit(s, DOC, SLACK_ROW, SLACK_ROW + "| Billing / payments | billing | `claude plugins install billing@claude-plugins-official` |\n")),
    ("plugin-autoinstall.md: a row joins the mid-task table", "pointers", lambda s: edit(s, DOC, SLACK_MID, SLACK_MID + "| Reading robots.txt | `seo` |\n"))]


def mutants(repo, path):
    src = Source(repo)
    try:
        with open(path, encoding="utf-8") as handle:
            doc = json.load(handle)
    except (OSError, ValueError) as exc:
        say("bad", "mutants: cannot read %s: %s" % (path, exc))
        return
    base = problems(src, doc)
    dirty = [group for group in GROUPS if base[group]]
    if dirty:
        say("bad", "mutants: the unmutated manifest already fails (%s), so a mutant proves nothing" % ", ".join(dirty))
        return
    for side, table in (("manifest", MANIFEST_MUTANTS), ("legacy", LEGACY_MUTANTS)):
        for name, group, change in table:
            trial = copy.deepcopy(doc)
            try:
                if side == "manifest":
                    change(trial)
                    fired = problems(src, trial)
                else:
                    fired = problems(change(src), trial)
            except (KeyError, IndexError, StopIteration, ValueError, TypeError, AttributeError, Legacy) as exc:
                say("bad", "%s mutant \"%s\" could not be built (%s: %s)" % (side, name, type(exc).__name__, exc))
                continue
            if fired[group]:
                say("ok", "%s mutant \"%s\": caught by the %s check" % (side, name, group))
            else:
                say("bad", "%s mutant \"%s\": the %s check did not fire (fired: %s)" % (side, name, group, [g for g in GROUPS if fired[g]] or "nothing"))


COMMANDS = {"transcription": (transcription, 2), "legacydoc": (legacydoc, 1), "history": (history, 1), "mutants": (mutants, 2)}

if __name__ == "__main__":
    command = COMMANDS.get(sys.argv[1]) if len(sys.argv) > 1 else None
    if command is None or len(sys.argv) != 2 + command[1]:
        sys.stderr.write(__doc__)
        sys.exit(2)
    command[0](*sys.argv[2:])
PYEOF

# ── the proofs ──────────────────────────────────────────────────────────────────────
report() {  # stdin: "verdict<TAB>text" lines from check.py
  local verdict text
  while IFS=$'\t' read -r verdict text; do
    [ -n "$verdict" ] || continue
    case "$verdict" in
      ok)   ok "$text" ;;
      skip) skip "$text" ;;
      *)    bad "$text" ;;
    esac
  done
}
run_check() {  # LABEL, then the check.py arguments
  local label="$1" out rc
  shift
  out="$("$PY" -I -B "$WORK/check.py" "$@" 2>&1)"; rc=$?
  if [ "$rc" -ne 0 ]; then
    bad "$label: check.py $1 broke (rc=$rc): ${out:0:500}"
    return
  fi
  report <<<"$out"
}

# A. the validator
OUT="$("$PY" -I "$VALIDATOR" validate "$MANIFEST" 2>&1)"; RC=$?
if [ "$RC" -eq 0 ] && [[ "$OUT" == "ok skills.manifest/1 ("* ]]; then
  ok "A: the validator accepts skills.manifest.json ($OUT)"
else
  bad "A: the validator does not accept skills.manifest.json (rc=$RC): ${OUT:0:400}"
fi

# B. the legacy doc and the transcription, C. history, D. mutants
run_check B legacydoc "$REPO"
run_check B transcription "$REPO" "$MANIFEST"
run_check C history "$REPO"
run_check D mutants "$REPO" "$MANIFEST"

echo "--------------------------------------------------------------------"
[ "$SKIP" -eq 0 ] || printf '%d check(s) skipped: a skip is printed above with its reason and is never counted as a pass\n' "$SKIP"
printf 'skills-manifest-transcription: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
