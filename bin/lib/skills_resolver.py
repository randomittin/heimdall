#!/usr/bin/env python3
"""skills_resolver -- answer the legacy skill-selection questions from skills.manifest.json. Read-only, stdlib only.

    skills_resolver.py activate-set  --manifest M --project D
    skills_resolver.py status        --manifest M --project D [--settings S]
    skills_resolver.py preinstall    --manifest M --prompt-file P --project D
    skills_resolver.py keyword-match --manifest M --prompt-file P
    skills_resolver.py domain-skills --manifest M --domain X [--skills-dir DIR]
    skills_resolver.py gaps          --manifest M [--skills-dir DIR]
    skills_resolver.py detect        --manifest M --prompt-file P [--skills-dir DIR]
    skills_resolver.py detect-file   --manifest M --file F [--skills-dir DIR]

PASS-THROUGH (docs/superpowers/plans/2026-11-12-3x-m1-skill-registry.md, "Resolver design"). Every subcommand prints what the legacy code prints for
the same input, byte for byte, so a call site can swap its inline code for one call. The resolver answers; it never installs, never looks at what is
installed through the Claude CLI and never writes: the call sites keep their install mechanics, receipts and consent. test/skills-resolver-parity.test.sh
proves the equality against test/fixtures/skills-baseline/golden.json, the recorded answers of the unmodified legacy code.

  subcommand     replaces                                                   stdout
  activate-set   needed_plugins() of bin/lib/skill_restore.py               the plugin refs a project needs, sorted, one per line
  status         the inline python of `skill-manager status`                the PERMANENT / DETECTED / ON-DEMAND block
  preinstall     the prompt and file rules of preinstall_plugins()          plugin refs `name@marketplace`, one per line, in the order the
                 in bin/heimdall                                            legacy rules ran, duplicates kept (the call site cuts the name)
  keyword-match  the inline python of discover_skills() in bin/heimdall     `name|repo` lines, registry order
  domain-skills  find_skills_for_domain() of bin/discover-skills            `name|repo|installed or NOT INSTALLED|description`
  gaps | detect | detect-file                                               the stdout of `discover-skills gaps | detect | detect-file`

The legacy semantics are kept as they are, quirks included (plan, section C); fixing one is a later, separate behaviour change:
  - a prompt rule is an UNANCHORED search of the stored ERE in the lower-cased prompt, one line at a time (what `grep -E` does): `ui` fires on "build";
  - preinstall prints every match, a plugin once per rule that matched, so one plugin can appear twice (a prompt rule and a file rule);
  - a file trigger is an existence check (a regular file), plus a case-sensitive literal search when it names `contains_any`; several files of one
    entry are an OR, as `A || B && C` is `(A || B) && C` in the legacy shell;
  - activation globs are looked for at the top of the project, one directory down, then anywhere under src/ (python glob rules: `*` skips dotfiles);
  - a keyword matches as `\\b` + re.escape(keyword) + `\\b` in the lower-cased prompt; the lower-casing folds ASCII letters only, as `tr` does in the C locale.
One deliberate difference: a prompt is DATA here, read from a file. The legacy `discover-skills detect` pasted it into python source, where a prompt holding
''' or a backslash sequence broke the program; that defect is not part of the baseline (the matrix holds no such input) and is not reproduced.

THE TABLES THE MANIFEST DOES NOT HOLD. skills.manifest.json (schema 1) has no slot for the extension and content tables of `discover-skills detect-file`,
so they live below as EXT_DOMAIN and CONTENT_DOMAINS, copied from bin/discover-skills (ext_to_domain, detect_domain_from_content).

Exit: 0 answered; 1 the legacy command's own non-zero answer (`detect` of an empty prompt, `detect-file` of a missing file), its text on stdout as the
legacy script printed it; 2 usage; 3 the manifest or another input cannot be read or is invalid (reason on stderr, nothing on stdout).
A prompt file or settings file that is missing is exit 3, never an empty answer: a resolver that cannot answer must not look like one that found nothing.
"""
import argparse
import glob
import json
import os
import re
import string
import sys

sys.dont_write_bytecode = True  # read-only: importing the sibling module must not leave a .pyc in the plugin directory
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))  # python3 -I keeps the script's directory off sys.path
import skills_manifest  # noqa: E402

LOWER = str.maketrans(string.ascii_uppercase, string.ascii_lowercase)
CHUNK = 1 << 16
HEAD_LINES = 50          # `head -50`
HEAD_BYTES = 1 << 20     # a bound on those 50 lines, not a behaviour: no real file comes near it
DASH, WARN, CHECK, DOT = "—", "⚠", "✔", "·"
EXIT_LEGACY, EXIT_USAGE, EXIT_INPUT = 1, 2, 3

EXT_DOMAIN = {"tsx": "design", "jsx": "design", "vue": "design", "svelte": "design", "css": "design", "scss": "design", "less": "design",
              "gd": "gamedev", "tscn": "gamedev", "tres": "gamedev", "mmd": "documentation", "mermaid": "documentation"}
CONTENT_DOMAINS = (
    ("design", r"tailwind|className.*flex|styled-component|@apply|css-in-js"),
    ("gamedev", r"extends Node|@onready|func _ready|GDScript"),
    ("documentation", r"mermaid|flowchart|sequenceDiagram|classDiagram|graph TD|graph LR"),
    ("marketing", r"meta.*description|sitemap|robots|canonical|og:title|schema.org"),
    ("knowledge", r"obsidian|vault|wiki|knowledge.base"),
)
# bytes patterns: re.IGNORECASE then folds ASCII only, like `grep -i` in the C locale; the first domain that matches wins
CONTENT_RES = tuple((domain, re.compile(pattern.encode("ascii"), re.IGNORECASE)) for domain, pattern in CONTENT_DOMAINS)


class ResolverError(Exception):
    """An input cannot be read or is not valid; str(error) is the reason (exit 3)."""


# ── what the questions need from a validated manifest, in manifest order ──
def _ref(item):
    if item.get("kind") != "plugin":
        raise ResolverError("entry %s is not a plugin: only plugins are activated or preinstalled" % item["id"])
    return item["ref"]


def _by_id(doc):
    return {item["id"]: item for item in doc["entries"]}


def permanent_refs(doc):
    return [_ref(item) for item in doc["entries"] if item.get("activate", {}).get("permanent") is True]


def detection_rules(doc):
    """[(rule name, file globs, plugin refs)], in the order the manifest lists the rules."""
    by_id = _by_id(doc)
    return [(name, rule["files"], [_ref(by_id[ident]) for ident in rule["entries"]]) for name, rule in doc.get("detection_rules", {}).items()]


def on_demand_refs(doc):
    return [_ref(item) for item in doc["entries"] if item["tier"] == "on_demand"]


def triggered_entries(doc):
    """The entries that have triggers, in the order the legacy rules ran (triggers.order)."""
    return sorted((item for item in doc["entries"] if "triggers" in item), key=lambda item: item["triggers"]["order"])


def registry_skills(doc):
    """The github-skill entries the keyword matcher reads, in registry order (keyword_skills)."""
    by_id = _by_id(doc)
    return [by_id[ident] for ident in doc.get("keyword_skills", [])]


# ── matching ──
def lowered(text):
    return text.translate(LOWER)


def grep_matches(ere, text):
    """`grep -E` reads a line at a time: is `ere` found anywhere in any line of `text`."""
    pattern = re.compile(ere)
    return any(pattern.search(line) for line in text.split("\n"))


def project_matches(project, pattern):
    """The legacy glob logic: `pattern` at the top of the project, one directory down, or anywhere below src/. The project path itself is
    escaped, so a directory named with a bracket still means that directory."""
    root = glob.escape(project)
    return bool(glob.glob(os.path.join(root, pattern))
                or glob.glob(os.path.join(root, "*", pattern))
                or glob.glob(os.path.join(root, "src", "**", pattern), recursive=True))


def file_contains_any(path, words):
    """`grep -q` of literal words in a file, read in chunks so a huge file costs no memory. Unreadable: no."""
    needles = [word.encode("utf-8") for word in words]
    keep = max(len(needle) for needle in needles) - 1
    tail = b""
    try:
        with open(path, "rb") as handle:
            for chunk in iter(lambda: handle.read(CHUNK), b""):
                window = tail + chunk
                if any(needle in window for needle in needles):
                    return True
                tail = window[-keep:] if keep else b""
    except OSError:
        return False
    return False


def file_trigger(project, rule):
    path = os.path.join(project, rule["path"])
    if not os.path.isfile(path):
        return False
    words = rule.get("contains_any")
    return True if words is None else file_contains_any(path, words)


def installed(skills_dir, item):
    return os.path.isdir(os.path.join(skills_dir, item["id"]))


# ── the answers ──
def needed_plugins(doc, project):
    needed = set(permanent_refs(doc))
    for _name, patterns, refs in detection_rules(doc):
        if any(project_matches(project, pattern) for pattern in patterns):
            needed.update(refs)
    return sorted(needed)


def status_text(doc, project, enabled):
    def switch(ref, on, off):
        return on if enabled.get(ref, True) else off

    lines = ["PERMANENT:"]
    lines += ["  %s  %s" % (switch(ref, "on", "OFF"), ref) for ref in permanent_refs(doc)]
    lines += ["", "DETECTED:"]
    for name, patterns, refs in detection_rules(doc):
        mark = CHECK if any(project_matches(project, pattern) for pattern in patterns) else DOT
        lines.append("  %s %s: %s" % (mark, name, ", ".join("%s(%s)" % (ref, switch(ref, "on", "off")) for ref in refs)))
    lines += ["", "ON-DEMAND:"]
    lines += ["  %s  %s" % (switch(ref, "on", "off"), ref) for ref in on_demand_refs(doc)]
    return "\n".join(lines) + "\n"


def preinstall(doc, prompt, project):
    text = lowered(prompt)
    ordered = triggered_entries(doc)
    refs = [_ref(item) for item in ordered if "prompt_ere" in item["triggers"] and grep_matches(item["triggers"]["prompt_ere"], text)]
    refs += [_ref(item) for item in ordered if any(file_trigger(project, rule) for rule in item["triggers"].get("files", []))]
    return refs


def keyword_matches(doc, prompt):
    text = lowered(prompt)
    return [item for item in registry_skills(doc) if any(re.search(r"\b" + re.escape(word) + r"\b", text) for word in item["keywords"])]


def detect(doc, prompt, skills_dir):
    if prompt == "":
        return EXIT_LEGACY, "Usage: discover-skills detect <prompt or description>\n"
    lines = []
    for item in keyword_matches(doc, prompt):
        if not installed(skills_dir, item):
            lines.append("MISSING: %s (%s) %s %s" % (item["id"], item["repo"], DASH, item["description"]))
            lines.append("  Install: discover-skills install %s" % item["id"])
    return 0, "\n".join(lines or ["No skill gaps detected."]) + "\n"


def gaps(doc, skills_dir):
    missing = [item for item in registry_skills(doc) if not installed(skills_dir, item)]
    lines = ["Skill gaps (not installed):", ""]
    for item in missing:
        lines.append("  %s %-25s %s" % (WARN, item["id"], item["description"]))
        lines.append("    Install: discover-skills install %s" % item["id"])
    lines += ["", "  %d skill(s) not installed." % len(missing)] if missing else ["  All registry skills installed!"]
    return "\n".join(lines) + "\n"


def content_domain(path):
    try:
        with open(path, "rb") as handle:
            head = handle.read(HEAD_BYTES)
    except OSError:
        return None
    lines = head.split(b"\n")[:HEAD_LINES]
    for domain, pattern in CONTENT_RES:
        if any(pattern.search(line) for line in lines):
            return domain
    return None


def detect_file(doc, path, skills_dir):
    if not os.path.isfile(path):
        return EXIT_LEGACY, "File not found: %s\n" % path
    domain = EXT_DOMAIN.get(path.rsplit(".", 1)[-1]) or content_domain(path)  # ${path##*.}: the whole path when it has no dot
    if domain is None:
        return 0, "No skill domain detected for %s\n" % path
    lines = ["Domain detected: %s (from %s)" % (domain, path)]
    skills = [item for item in registry_skills(doc) if item["category"] == domain]
    if skills:
        lines += ["", "Relevant skills:"]
        for item in skills:
            if installed(skills_dir, item):
                lines.append("  %s %s %s %s" % (CHECK, item["id"], DASH, item["description"]))
            else:
                lines.append("  %s %s %s %s" % (WARN, item["id"], DASH, item["description"]))
                lines.append("    Install: discover-skills install %s" % item["id"])
    return 0, "\n".join(lines) + "\n"


# ── inputs ──
def load_manifest(path):
    try:
        doc = skills_manifest.load(path)
    except skills_manifest.ManifestError as exc:
        raise ResolverError(str(exc))
    reasons = skills_manifest.validate(doc)
    if reasons:
        raise ResolverError("%s is not a valid manifest:\n  %s" % (path, "\n  ".join(reasons[:10])))
    return doc


def read_prompt(path):
    try:
        with open(path, "rb") as handle:
            return handle.read().decode("utf-8", "replace")
    except OSError as exc:
        raise ResolverError("cannot read the prompt file %s: %s" % (path, exc.strerror or exc))


def read_enabled(path):
    """The enabledPlugins map of a settings.json; a file that is not there means no plugin is switched off."""
    if not os.path.exists(path):
        return {}
    try:
        with open(path, "rb") as handle:
            data = json.loads(handle.read().decode("utf-8"))
    except (OSError, ValueError, RecursionError) as exc:
        raise ResolverError("cannot read the settings file %s: %s" % (path, getattr(exc, "strerror", None) or exc))
    enabled = data.get("enabledPlugins", {}) if isinstance(data, dict) else None
    if not isinstance(enabled, dict):
        raise ResolverError("the settings file %s must be an object whose enabledPlugins is an object" % path)
    return enabled


def skills_dir_of(args):
    return args.skills_dir or os.path.expanduser("~/.claude/skills")


# ── the command line ──
def cmd_activate_set(doc, args):
    return 0, "".join(ref + "\n" for ref in needed_plugins(doc, args.project))


def cmd_status(doc, args):
    return 0, status_text(doc, args.project, read_enabled(args.settings or os.path.expanduser("~/.claude/settings.json")))


def cmd_preinstall(doc, args):
    return 0, "".join(ref + "\n" for ref in preinstall(doc, read_prompt(args.prompt_file), args.project))


def cmd_keyword_match(doc, args):
    return 0, "".join("%s|%s\n" % (item["id"], item["repo"]) for item in keyword_matches(doc, read_prompt(args.prompt_file)))


def cmd_domain_skills(doc, args):
    skills_dir = skills_dir_of(args)
    return 0, "".join("%s|%s|%s|%s\n" % (item["id"], item["repo"], "installed" if installed(skills_dir, item) else "NOT INSTALLED",
                                         item["description"])
                      for item in registry_skills(doc) if item["category"] == args.domain)


def cmd_gaps(doc, args):
    return 0, gaps(doc, skills_dir_of(args))


def cmd_detect(doc, args):
    return detect(doc, read_prompt(args.prompt_file), skills_dir_of(args))


def cmd_detect_file(doc, args):
    return detect_file(doc, args.file, skills_dir_of(args))


def add_command(commands, name, handler, required=(), optional=()):
    parser = commands.add_parser(name, allow_abbrev=False)
    parser.add_argument("--manifest", required=True, metavar="M", help="the skills.manifest.json to answer from")
    for option in required:
        parser.add_argument("--" + option, required=True)
    for option in optional:
        parser.add_argument("--" + option)
    parser.set_defaults(handler=handler)


def build_parser():
    parser = argparse.ArgumentParser(prog="skills_resolver.py", allow_abbrev=False,
                                     description="Answer the legacy skill-selection questions from skills.manifest.json (read-only).")
    commands = parser.add_subparsers(dest="command", required=True, metavar="COMMAND")
    add_command(commands, "activate-set", cmd_activate_set, required=("project",))
    add_command(commands, "status", cmd_status, required=("project",), optional=("settings",))
    add_command(commands, "preinstall", cmd_preinstall, required=("prompt-file", "project"))
    add_command(commands, "keyword-match", cmd_keyword_match, required=("prompt-file",))
    add_command(commands, "domain-skills", cmd_domain_skills, required=("domain",), optional=("skills-dir",))
    add_command(commands, "gaps", cmd_gaps, optional=("skills-dir",))
    add_command(commands, "detect", cmd_detect, required=("prompt-file",), optional=("skills-dir",))
    add_command(commands, "detect-file", cmd_detect_file, required=("file",), optional=("skills-dir",))
    return parser


def emit(text):
    sys.stdout.buffer.write(text.encode("utf-8", "surrogateescape"))  # UTF-8 whatever the locale: the legacy scripts printed UTF-8
    sys.stdout.flush()


def main(argv):
    args = build_parser().parse_args(argv)  # a usage error exits 2 on its own
    try:
        code, text = args.handler(load_manifest(args.manifest), args)
    except ResolverError as exc:
        sys.stderr.write("skills_resolver: %s\n" % exc)
        return EXIT_INPUT
    emit(text)
    return code


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
