#!/usr/bin/env python3
"""skills_render_doc -- render the plugin auto-install tables and the injected-prompt line from skills.manifest.json. Stdlib only.

    skills_render_doc.py [--manifest M] [--flavour auto|ask] --part auto-install|mid-task|prompt     print one rendering
    skills_render_doc.py [--manifest M] --check FILE        is every generated block of FILE current?
    skills_render_doc.py [--manifest M] --write FILE        bring every generated block of FILE up to date, in place

WHAT IT RENDERS (docs/superpowers/plans/2026-11-12-3x-m1-skill-registry.md, T4.4): the text an agent reads to decide what to install.
  auto-install  the "Plugin auto-install map" table of skills/heimdall/references/plugin-autoinstall.md:  domain | plugin | install command
  mid-task      its "Mid-Task Plugin Discovery" table:                                                    signal | plugin
  prompt        the one line of the launcher's injected prompt (bin/heimdall, `ALSO install plugins, ...`) that names three plugins and the
                command that installs each

FROM THE MANIFEST: which entries get a row and in what order (the `plugin-autoinstall.md` pointers in legacy[]: "auto-install map row N",
"mid-task signal row N"), the plugin id, the install ref, and the order of the prompt line's three plugins (triggers.order). A pointer this
module cannot place, a row for an entry that is not an install:true plugin, a gap or a repeat in the row numbers: exit 3, never a skipped row.

THE TEXT THE MANIFEST DOES NOT HOLD. skills.manifest.json (schema 1) has no slot for the domain a row is filed under, the signal that sends an
agent to a plugin or the words of the prompt line, so they live below as DOMAIN, SIGNALS and PROMPT_READS, copied from the doc and the launcher
(the same arrangement as skills_resolver.EXT_DOMAIN). They are keyed by entry id; an entry with a row and no text here is exit 3, never a guess.

FLAVOURS, the same rows for the two consent regimes of the 3.x skill registry:
  auto  today's text, byte for byte: the install command is `claude plugins install <ref>`. What the launcher tells a user whose consent is
        auto or who was there before the registry (INV-S7: nothing about their sessions changes).
  ask   the install command is `hmd skills install <id>`, which asks before it installs (exit 3 = consent required). The mid-task table has no
        command in it, so it reads the same in both flavours.

GENERATED BLOCKS. A doc holds a rendering between two marker lines, each alone on its line:
    <!-- BEGIN GENERATED skills.manifest part=auto-install flavour=ask -->
    ...                                   everything between the markers is the rendering; --write replaces it
    <!-- END GENERATED skills.manifest -->
`part=` is required, `flavour=` defaults to auto. A doc may hold any number of blocks; the prose around them is never touched. --check
compares each block line for line (a trailing space is drift) and names every stale one; --write leaves a current block as it is and replaces
the file atomically, keeping its mode.

Exit: 0 printed, current or written; 1 --check found a stale block; 2 usage; 3 an input cannot be read or is invalid (the manifest, the doc, a
marker: reason on stderr, nothing on stdout). A doc with no generated block is exit 3, not a pass: nothing was checked.
"""
import argparse
import contextlib
import os
import re
import stat
import sys
import tempfile

sys.dont_write_bytecode = True  # read-only library import: no .pyc may appear in the plugin directory
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))  # python3 -I keeps the script's directory off sys.path
import skills_manifest  # noqa: E402

DEFAULT_MANIFEST = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "skills.manifest.json"))
EXIT_STALE, EXIT_INPUT = 1, 3
FLAVOURS = ("auto", "ask")
PARTS = ("auto-install", "mid-task", "prompt")

POINTER_MECHANISM = "plugin-autoinstall.md"
POINTER_RE = re.compile(r"^(auto-install map|mid-task signal) row ([1-9][0-9]*)$")
BEGIN_PREFIX = "<!-- BEGIN GENERATED skills.manifest"
BEGIN_RE = re.compile(r"^<!-- BEGIN GENERATED skills\.manifest((?: [a-z]+=[a-z-]+)*) -->$")
END_MARKER = "<!-- END GENERATED skills.manifest -->"

DOMAIN = {
    "frontend-design": "Frontend / UI / React / CSS",
    "seo": "SEO / meta tags / sitemap",
    "mcp-server-dev": "MCP / tool server",
    "api-design": "API design / OpenAPI",
    "database-toolkit": "Database / SQL / schema",
    "devops-toolkit": "Docker / K8s / deploy",
    "security-scanner": "Security / auth / OWASP",
    "slack": "Slack / notifications",
}
SIGNALS = {  # one text per mid-task row an entry has, in row order
    "frontend-design": ("Reading a `package.json` with React/Vue/Angular", "Touching `.css`/`.scss`/`tailwind.config`"),
    "devops-toolkit": ("Reading `Dockerfile`/`docker-compose`/`k8s` manifests",),
    "database-toolkit": ("Seeing SQL files / Prisma / Sequelize / TypeORM",),
    "api-design": ("Reading OpenAPI/Swagger specs",),
    "security-scanner": ("Finding auth/JWT/OAuth code",),
    "seo": ("Touching SEO meta tags / robots.txt / sitemap",),
    "mcp-server-dev": ("Finding `.mcp.json` or MCP server code",),
    "slack": ("User mentions Slack / notifications mid-conversation",),
}
PROMPT_READS = {"frontend-design": "React/Vue/CSS", "devops-toolkit": "Dockerfile/k8s", "database-toolkit": "SQL/ORM"}
PROMPT_LINE = {  # %s is the three `Read X → `command`.` clauses
    "auto": ("ALSO install plugins, only from the listed marketplace: %s If an install fails say \"install failed, continuing without <name>\" "
             "and go on — never retry through another marketplace, never pass --yes."),
    "ask": ("ALSO install plugins through the consent gate, only from the listed marketplace: %s Exit code 3 means consent required: ask the "
            "user, and re-run with --yes only after they agree. If an install fails say \"install failed, continuing without <name>\" and go on "
            "— never retry through another marketplace."),
}


class RenderError(Exception):
    """An input cannot be read or is not valid; str(error) is the reason (exit 3)."""


# ── the renderings ──
def doc_rows(doc, table):
    """[(row number, entry)] of one plugin-autoinstall.md table in row order, from the `plugin-autoinstall.md` pointers of legacy[]."""
    rows = []
    for entry in doc["entries"]:
        for item in entry["legacy"]:
            if item["mechanism"] != POINTER_MECHANISM:
                continue
            match = POINTER_RE.match(item["path"])
            if not match:
                raise RenderError("%s: unknown %s pointer %r (want 'auto-install map row N' or 'mid-task signal row N')"
                                  % (entry["id"], POINTER_MECHANISM, item["path"]))
            if match.group(1) == table:
                rows.append((int(match.group(2)), entry))
    rows.sort(key=lambda row: row[0])
    numbers = [number for number, _ in rows]
    if not rows or numbers != list(range(1, len(rows) + 1)):
        raise RenderError("%s: row numbers must be 1..N, each once (the manifest has %s)" % (table, numbers or "none"))
    return rows


def plugin_row(entry, what):
    if entry["kind"] != "plugin":
        raise RenderError("%s: %s is not a plugin entry" % (what, entry["id"]))
    if entry["install"] is not True:
        raise RenderError("%s: %s is install:false, and a doc row would tell the agent to install it" % (what, entry["id"]))


def display_text(table, entry, what):
    if entry["id"] not in table:
        raise RenderError("%s: no display text for %s (skills_render_doc.py holds the words the manifest does not)" % (what, entry["id"]))
    return table[entry["id"]]


def install_command(entry, flavour):
    if flavour == "ask":
        return "hmd skills install " + entry["id"]
    return "claude plugins install " + entry["ref"]


def render_auto_install(doc, flavour):
    lines = ["| Domain detected | Plugin needed | Install command |", "|---|---|---|"]
    seen = set()
    for number, entry in doc_rows(doc, "auto-install map"):
        what = "auto-install map row %d" % number
        plugin_row(entry, what)
        if entry["id"] in seen:
            raise RenderError("%s: %s has more than one auto-install map row" % (what, entry["id"]))
        seen.add(entry["id"])
        lines.append("| %s | %s | `%s` |" % (display_text(DOMAIN, entry, what), entry["id"], install_command(entry, flavour)))
    return lines


def render_mid_task(doc, flavour):
    lines = ["| Signal during execution | Install |", "|---|---|"]
    rows = doc_rows(doc, "mid-task signal")
    used = {}
    for number, entry in rows:
        what = "mid-task signal row %d" % number
        plugin_row(entry, what)
        texts = display_text(SIGNALS, entry, what)
        have = sum(1 for _, other in rows if other["id"] == entry["id"])
        if have != len(texts):
            raise RenderError("%s: %s has %d mid-task signal rows but skills_render_doc.py holds %d signal texts for it"
                              % (what, entry["id"], have, len(texts)))
        index = used.get(entry["id"], 0)
        used[entry["id"]] = index + 1
        lines.append("| %s | `%s` |" % (texts[index], entry["id"]))
    return lines


def render_prompt(doc, flavour):
    by_id = {entry["id"]: entry for entry in doc["entries"]}
    reads = []
    for entry_id, words in PROMPT_READS.items():
        if entry_id not in by_id:
            raise RenderError("prompt: the manifest has no entry %s" % entry_id)
        plugin_row(by_id[entry_id], "prompt")
        order = by_id[entry_id].get("triggers", {}).get("order")
        if order is None:
            raise RenderError("prompt: %s has no triggers.order to place it by" % entry_id)
        reads.append((order, by_id[entry_id], words))
    reads.sort(key=lambda read: read[0])
    clauses = " ".join("Read %s → `%s`." % (words, install_command(entry, flavour)) for _, entry, words in reads)
    return [PROMPT_LINE[flavour] % clauses]


RENDERERS = {"auto-install": render_auto_install, "mid-task": render_mid_task, "prompt": render_prompt}


# ── generated blocks in a doc ──
def marker_attributes(text, number):
    found = {}
    for pair in text.split():
        key, value = pair.split("=", 1)
        if key not in ("part", "flavour") or key in found:
            raise RenderError("line %d: unknown or repeated marker attribute %s" % (number, key))
        found[key] = value
    part, flavour = found.get("part"), found.get("flavour", "auto")
    if part not in PARTS:
        raise RenderError("line %d: a BEGIN marker needs part=%s" % (number, "|".join(PARTS)))
    if flavour not in FLAVOURS:
        raise RenderError("line %d: flavour= is one of %s" % (number, "|".join(FLAVOURS)))
    return part, flavour


def find_blocks(lines):
    """[(index of BEGIN, index of END, part, flavour)] for every generated block of a doc; any marker out of place is an error."""
    blocks, opened = [], None
    for index, line in enumerate(lines):
        number = index + 1
        if line.startswith(BEGIN_PREFIX):
            match = BEGIN_RE.match(line)
            if not match:
                raise RenderError("line %d: malformed BEGIN marker (want %s part=... [flavour=...] -->)" % (number, BEGIN_PREFIX))
            if opened is not None:
                raise RenderError("line %d: a BEGIN marker inside the block opened at line %d" % (number, opened[0] + 1))
            opened = (index,) + marker_attributes(match.group(1), number)
        elif line == END_MARKER:
            if opened is None:
                raise RenderError("line %d: an END marker without a BEGIN" % number)
            blocks.append((opened[0], index, opened[1], opened[2]))
            opened = None
    if opened is not None:
        raise RenderError("line %d: a BEGIN marker with no END" % (opened[0] + 1))
    if not blocks:
        raise RenderError("no generated block (<!-- BEGIN GENERATED skills.manifest part=... -->) in the document")
    return blocks


def check(doc, path, text):
    lines = text.split("\n")
    blocks = find_blocks(lines)
    stale = [block for block in blocks if lines[block[0] + 1:block[1]] != RENDERERS[block[2]](doc, block[3])]
    for begin, _, part, flavour in stale:
        sys.stderr.write("skills_render_doc: stale: %s line %d: part=%s flavour=%s\n" % (path, begin + 1, part, flavour))
    if stale:
        sys.stderr.write("skills_render_doc: %d of %d generated blocks are out of date; run: skills_render_doc.py --write %s\n"
                         % (len(stale), len(blocks), path))
        return EXIT_STALE
    emit("ok %s (%d generated blocks current)\n" % (path, len(blocks)))
    return 0


def write(doc, path, text):
    lines = text.split("\n")
    blocks = find_blocks(lines)
    changed = 0
    for begin, end, part, flavour in reversed(blocks):  # last first: a body that grows or shrinks moves only the lines below it
        wanted = RENDERERS[part](doc, flavour)
        if lines[begin + 1:end] != wanted:
            lines[begin + 1:end] = wanted
            changed += 1
    if not changed:
        emit("unchanged %s (%d generated blocks current)\n" % (path, len(blocks)))
        return 0
    replace_file(path, "\n".join(lines))
    emit("wrote %s (%d of %d generated blocks changed)\n" % (path, changed, len(blocks)))
    return 0


# ── inputs and outputs ──
def load_manifest(path):
    try:
        doc = skills_manifest.load(path)
    except skills_manifest.ManifestError as exc:
        raise RenderError(str(exc))
    reasons = skills_manifest.validate(doc)
    if reasons:
        raise RenderError("%s is not a valid manifest:\n  %s" % (path, "\n  ".join(reasons[:10])))
    return doc


def read_doc(path):
    try:
        with open(path, "rb") as handle:
            raw = handle.read(skills_manifest.MAX_BYTES + 1)
    except OSError as exc:
        raise RenderError("cannot read %s: %s" % (path, exc.strerror or exc))
    if len(raw) > skills_manifest.MAX_BYTES:
        raise RenderError("%s is larger than %d bytes" % (path, skills_manifest.MAX_BYTES))
    try:
        return raw.decode("utf-8")
    except UnicodeDecodeError:
        raise RenderError("%s is not UTF-8" % path)


def replace_file(path, text):
    """Swap `path` (through a symlink, if it is one) for `text` in one rename, with the mode it had; a failure leaves it as it was."""
    target = os.path.realpath(path)
    temp = None
    try:
        mode = stat.S_IMODE(os.stat(target).st_mode)
        handle, temp = tempfile.mkstemp(prefix=".skills_render_doc.", dir=os.path.dirname(target))
        with os.fdopen(handle, "wb") as out:
            out.write(text.encode("utf-8"))
        os.chmod(temp, mode)
        os.replace(temp, target)
    except OSError as exc:
        if temp:
            with contextlib.suppress(OSError):
                os.unlink(temp)
        raise RenderError("cannot write %s: %s" % (path, exc.strerror or exc))


def emit(text):
    sys.stdout.buffer.write(text.encode("utf-8", "surrogateescape"))  # UTF-8 whatever the locale (the prompt line holds an arrow and a dash); a path argv carried as raw bytes goes back as it came
    sys.stdout.flush()


def build_parser():
    parser = argparse.ArgumentParser(prog="skills_render_doc.py", allow_abbrev=False,
                                     description="Render the plugin auto-install tables and the injected-prompt line from skills.manifest.json.")
    parser.add_argument("--manifest", default=DEFAULT_MANIFEST, metavar="M", help="the skills.manifest.json to render (default: the repo's)")
    parser.add_argument("--flavour", choices=FLAVOURS, help="with --part: auto (today's text, the default) or ask (consent-gated commands)")
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--part", choices=PARTS, help="print one rendering on stdout")
    mode.add_argument("--check", metavar="FILE", help="exit 1 when a generated block of FILE is stale")
    mode.add_argument("--write", metavar="FILE", help="rewrite every generated block of FILE in place")
    return parser


def main(argv):
    parser = build_parser()
    args = parser.parse_args(argv)  # a usage error exits 2 on its own
    if args.flavour and not args.part:
        parser.error("--flavour goes with --part (a generated block names its own flavour)")
    try:
        doc = load_manifest(args.manifest)
        if args.part:
            emit("\n".join(RENDERERS[args.part](doc, args.flavour or "auto")) + "\n")
            return 0
        path = args.check if args.check is not None else args.write
        text = read_doc(path)
        return check(doc, path, text) if args.check is not None else write(doc, path, text)
    except RenderError as exc:
        sys.stderr.write("skills_render_doc: %s\n" % exc)
        return EXIT_INPUT


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
