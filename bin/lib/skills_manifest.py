#!/usr/bin/env python3
"""skills_manifest -- load and validate skills.manifest.json, the one source of skill and plugin mappings.

    skills_manifest.py validate FILE

THE CONTRACT is docs/schemas/skills.manifest.v1.json (shape, enums, patterns) plus the cross-field rules that
file lists under `x-invariants` (SM1..SM13). This module enforces all of it with the stdlib alone and never reads
the schema file at run time, so a sandbox that copies bin/lib without docs/ still validates;
test/skills-manifest-schema.test.sh fails when the two disagree on the version, kinds, tiers, patterns or keys.

FAILS CLOSED. A file that cannot be read, is larger than MAX_BYTES, is not strict JSON (a duplicate key is an
error, never "the last one wins") or is not an object is rejected with a reason; so is every document with an
unknown key, a wrong type or a broken rule. validate() collects every reason it finds, never raises on a hostile
document, and the empty list is the only "valid". Every string quoted in a reason goes through _show(), which
escapes control characters, so a hostile manifest cannot write to the operator's terminal through its own errors.

Exit: 0 valid (`ok ...` on stdout); 1 invalid, unreadable or not JSON (one reason per line on stderr); 2 usage.

Python API (run with `python3 -I`, which keeps this directory off sys.path: put it there before importing):
  load(path) -> dict            strict JSON parse; raises ManifestError. It does NOT validate: call validate().
  validate(doc) -> list[str]    the reasons; [] == valid
"""
import json
import re
import sys

SCHEMA_VERSION = 1
MAX_BYTES = 1 << 20
KINDS = ("plugin", "github-skill", "bundled")
TIERS = ("bundled", "recommended", "detected", "on_demand", "community")

ID_PATTERN = r"[a-z0-9][a-z0-9._-]{0,63}"
PLUGIN_REF_PATTERN = ID_PATTERN + "@" + ID_PATTERN
OWNER_REPO_PATTERN = r"[A-Za-z0-9][A-Za-z0-9._-]*/[A-Za-z0-9][A-Za-z0-9._-]*"
PIN_PATTERN = r"[A-Za-z0-9][A-Za-z0-9._/-]*"
ID_RE = re.compile(ID_PATTERN)
PLUGIN_REF_RE = re.compile(PLUGIN_REF_PATTERN)
OWNER_REPO_RE = re.compile(OWNER_REPO_PATTERN)
PIN_RE = re.compile(PIN_PATTERN)
CONTROL_RE = re.compile(r"[\x00-\x1f\x7f]")
MAX_PATH_CHARS = 256

# The optional entry fields `pack` and `on_demand_paths` (lean core: SM12, SM13). A pack's sha256 is the FULL content hash
# a resolver compares a pack against, so a short, prefixed or upper-case spelling is rejected, never normalised.
PACK_NAME_PATTERN = "@" + ID_PATTERN + "/" + ID_PATTERN
PACK_VERSION_PATTERN = r"(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-[0-9A-Za-z.-]{1,32})?"
SHA256_PATTERN = r"[0-9a-f]{64}"
INSTALL_PATH_PATTERN = r"[A-Za-z0-9_][A-Za-z0-9._-]*(/[A-Za-z0-9_][A-Za-z0-9._-]*)*"
INSTALL_PATH_RE = re.compile(INSTALL_PATH_PATTERN)
PACK_KEYS = ("name", "version", "sha256", "paths")
PACK_FIELD_RULES = (  # the string fields of a pack: key, compiled pattern, what a valid value is
    ("name", re.compile(PACK_NAME_PATTERN), "@<scope>/<name> matching " + PACK_NAME_PATTERN),
    ("version", re.compile(PACK_VERSION_PATTERN),
     "MAJOR.MINOR.PATCH with an optional -prerelease, matching " + PACK_VERSION_PATTERN),
    ("sha256", re.compile(SHA256_PATTERN), "64 lowercase hex digits"),
)

TOP_REQUIRED = ("schema", "marketplaces", "entries")
TOP_OPTIONAL = ("detection_rules", "keyword_skills")
ENTRY_REQUIRED = ("id", "kind", "tier", "install", "why", "legacy")
ENTRY_OPTIONAL = ("ref", "marketplace", "activate", "triggers", "explicit_consent",
                  "repo", "keywords", "category", "description", "pack", "on_demand_paths")
KIND_NEEDS = {"plugin": ("ref", "marketplace"),
              "github-skill": ("repo", "keywords", "category", "description")}
USAGE = "usage: skills_manifest.py validate FILE\n"


class ManifestError(Exception):
    """The manifest cannot be read or is not strict JSON; str(error) is the reason."""


def _once_per_key(pairs):
    found = {}
    for key, value in pairs:
        if key in found:
            raise ValueError("duplicate key %s" % _show(key))
        found[key] = value
    return found


def load(path):
    """Parse the manifest at `path` into a dict, or raise ManifestError. Parse only: call validate() for the contract."""
    try:
        with open(path, "rb") as handle:
            raw = handle.read(MAX_BYTES + 1)
    except OSError as exc:
        raise ManifestError("cannot read %s: %s" % (path, exc.strerror or exc))
    if len(raw) > MAX_BYTES:
        raise ManifestError("%s is larger than %d bytes" % (path, MAX_BYTES))
    try:
        doc = json.loads(raw.decode("utf-8"), object_pairs_hook=_once_per_key)
    except (ValueError, RecursionError) as exc:
        raise ManifestError("not valid JSON: %s" % exc)
    if not isinstance(doc, dict):
        raise ManifestError("top level must be a JSON object")
    return doc


def _show(value):
    """A short, safe rendering of an offending value: repr() escapes control characters, a container is named by
    its type (never walked) and a long string is cut."""
    if isinstance(value, (dict, list)):
        return type(value).__name__
    text = repr(value)
    return text if len(text) <= 60 else text[:57] + "..."


def _text(value):
    """A non-blank single-line string: a control character would corrupt one-line listings and a terminal."""
    return isinstance(value, str) and value.strip() != "" and CONTROL_RE.search(value) is None


def _relpath(value):
    """A project-relative path or glob: no leading slash and no '..' segment, so a manifest cannot point a file
    trigger outside the project."""
    return _text(value) and len(value) <= MAX_PATH_CHARS and not value.startswith("/") and ".." not in value.split("/")


def _reporter(errors, where):
    def fail(message):
        errors.append("%s: %s" % (where, message))
    return fail


def _scoped(fail, prefix):
    return lambda message: fail("%s %s" % (prefix, message))


def _object(value, fail, what):
    if isinstance(value, dict):
        return True
    fail((what + " must be an object").strip())
    return False


def _keys(obj, required, optional, fail):
    for key in required:
        if key not in obj:
            fail("missing required property '%s'" % key)
    for key in obj:
        if key not in required and key not in optional:
            fail("unexpected property %s" % _show(key))


def _check_marketplaces(value, errors):
    """Check the marketplaces table; return the names it lists (the allow-list install:true entries are held to)."""
    if not _object(value, _reporter(errors, "manifest"), "marketplaces"):
        return set()
    listed = set()
    for name, spec in value.items():
        fail = _reporter(errors, "marketplaces.%s" % _show(name))
        if ID_RE.fullmatch(name):
            listed.add(name)
        else:
            fail("name must match %s" % ID_PATTERN)
        if not _object(spec, fail, ""):
            continue
        _keys(spec, ("source",), ("pin",), fail)
        source, pin = spec.get("source"), spec.get("pin")
        if "source" in spec and not (isinstance(source, str) and OWNER_REPO_RE.fullmatch(source)):
            fail("source must be <owner>/<repo> (got %s)" % _show(source))
        if pin is not None and not (isinstance(pin, str) and PIN_RE.fullmatch(pin)):
            fail("pin must be null or a branch or tag name matching %s (got %s)" % (PIN_PATTERN, _show(pin)))
    return listed


def _check_legacy(entry, fail):
    if "legacy" not in entry:
        return
    legacy = entry["legacy"]
    if not (isinstance(legacy, list) and legacy):
        fail("legacy must be a non-empty array (every mapping keeps a pointer to the legacy mechanism it came from)")
        return
    for n, item in enumerate(legacy):
        where = "legacy[%d]" % n
        if not _object(item, fail, where):
            continue
        _keys(item, ("mechanism", "path"), (), _scoped(fail, where + ":"))
        for field in ("mechanism", "path"):
            if field in item and not _text(item[field]):
                fail("%s.%s must be a non-empty single-line string" % (where, field))


def _check_source(entry, fail, listed):
    """ref, marketplace and install: an install:true plugin installs from the marketplace its ref names, and that
    marketplace must be one the manifest lists."""
    kind, install = entry.get("kind"), entry.get("install")
    ref, market = entry.get("ref"), entry.get("marketplace")
    ref_ok = market_ok = False
    if "ref" in entry:
        if kind == "plugin":
            ref_ok = isinstance(ref, str) and PLUGIN_REF_RE.fullmatch(ref) is not None
            if not ref_ok:
                fail("ref must be <plugin>@<marketplace> matching %s (got %s)" % (PLUGIN_REF_PATTERN, _show(ref)))
        elif not _text(ref):
            fail("ref must be a non-empty single-line string")
    if "marketplace" in entry:
        if kind == "plugin":
            market_ok = isinstance(market, str) and ID_RE.fullmatch(market) is not None
            if not market_ok:
                fail("marketplace must match %s (got %s)" % (ID_PATTERN, _show(market)))
        elif market is not None:
            fail("marketplace must be null or absent unless kind is plugin (got %s)" % _show(market))
    if ref_ok and market_ok:
        ref_market = ref.rsplit("@", 1)[1]
        if ref_market != market:
            fail("ref %s names marketplace %s but marketplace is %s" % (_show(ref), _show(ref_market), _show(market)))
        elif install is True and market not in listed:
            fail("marketplace %s is not listed in marketplaces (install:true needs a listed marketplace)" % _show(market))


def _check_activate(act, fail, detects):
    if not _object(act, fail, "activate"):
        return
    _keys(act, ("permanent", "detect"), (), _scoped(fail, "activate:"))
    if "permanent" in act and not isinstance(act["permanent"], bool):
        fail("activate.permanent must be a boolean (got %s)" % _show(act["permanent"]))
    if "detect" in act:
        rules = act["detect"]
        if isinstance(rules, list) and all(isinstance(rule, str) and ID_RE.fullmatch(rule) for rule in rules):
            detects.extend((fail, rule) for rule in rules)
        else:
            fail("activate.detect must be an array of detection rule names matching %s" % ID_PATTERN)


def _check_prompt_ere(ere, fail):
    if not (isinstance(ere, str) and ere):
        fail("triggers.prompt_ere must be a non-empty string")
        return
    try:
        pattern = re.compile(ere)
    except (re.error, RecursionError, OverflowError) as exc:
        fail("triggers.prompt_ere does not compile: %s" % _show(str(exc)))
        return
    if pattern.search(""):
        fail("triggers.prompt_ere matches the empty string (it would fire on every prompt)")


def _check_file_trigger(item, where, fail):
    if not _object(item, fail, where):
        return
    _keys(item, ("path",), ("contains_any",), _scoped(fail, where + ":"))
    if "path" in item and not _relpath(item["path"]):
        fail("%s.path must be a relative path without '..' (got %s)" % (where, _show(item["path"])))
    if "contains_any" in item:
        words = item["contains_any"]
        if not (isinstance(words, list) and words and all(_text(word) for word in words)):
            fail("%s.contains_any must be a non-empty array of non-empty single-line strings" % where)


def _check_triggers(trig, fail, index, orders):
    if not _object(trig, fail, "triggers"):
        return
    _keys(trig, ("order",), ("prompt_ere", "files"), _scoped(fail, "triggers:"))
    if "order" in trig:
        order = trig["order"]
        if not (type(order) is int and order >= 1):
            fail("triggers.order must be a positive integer (got %s)" % _show(order))
        elif order in orders:
            fail("duplicate triggers.order %d (also entries[%d])" % (order, orders[order]))
        else:
            orders[order] = index
    if "prompt_ere" in trig:
        _check_prompt_ere(trig["prompt_ere"], fail)
    if "files" in trig:
        files = trig["files"]
        if not isinstance(files, list):
            fail("triggers.files must be an array")
        else:
            for n, item in enumerate(files):
                _check_file_trigger(item, "triggers.files[%d]" % n, fail)


def _check_install_paths(paths, what, fail):
    """pack.paths and on_demand_paths: tree paths that end up in a sparse-checkout command, so each is ONE literal path
    (no glob, no option-like or hidden segment, never the whole tree) on top of the SM10 rule (relative, no '..', one
    line, at most MAX_PATH_CHARS)."""
    if not (isinstance(paths, list) and paths):
        fail("%s must be a non-empty array of install paths" % what)
        return
    for n, path in enumerate(paths):
        if not (_relpath(path) and INSTALL_PATH_RE.fullmatch(path)):
            fail("%s[%d] must be a literal tree path matching %s, at most %d characters (got %s)"
                 % (what, n, INSTALL_PATH_PATTERN, MAX_PATH_CHARS, _show(path)))


def _check_pack(pack, fail):
    """pack: exactly {name, version, sha256, paths}; the content hash is pinned in full, never abbreviated."""
    if not _object(pack, fail, "pack"):
        return
    _keys(pack, PACK_KEYS, (), _scoped(fail, "pack:"))
    for key, regex, wanted in PACK_FIELD_RULES:
        value = pack.get(key)
        if key in pack and not (isinstance(value, str) and regex.fullmatch(value)):
            fail("pack.%s must be %s (got %s)" % (key, wanted, _show(value)))
    if "paths" in pack:
        _check_install_paths(pack["paths"], "pack.paths", fail)


def _check_entry(index, entry, ctx):
    ident = entry.get("id") if isinstance(entry, dict) else None
    where = "entries[%d]" % index
    if isinstance(ident, str):
        where += " " + _show(ident)
    fail = _reporter(ctx["errors"], where)
    if not _object(entry, fail, ""):
        return
    _keys(entry, ENTRY_REQUIRED, ENTRY_OPTIONAL, fail)
    kind, tier, install = entry.get("kind"), entry.get("tier"), entry.get("install")
    if "id" in entry:
        if not (isinstance(ident, str) and ID_RE.fullmatch(ident)):
            fail("id must match %s (got %s)" % (ID_PATTERN, _show(ident)))
        elif ident in ctx["ids"]:
            fail("duplicate entry id %s (also entries[%d])" % (_show(ident), ctx["ids"][ident][0]))
        else:
            ctx["ids"][ident] = (index, kind)
    if "kind" in entry and kind not in KINDS:
        fail("kind %s is not one of %s" % (_show(kind), "|".join(KINDS)))
    if "tier" in entry and tier not in TIERS:
        fail("tier %s is not one of %s" % (_show(tier), "|".join(TIERS)))
    if "install" in entry and not isinstance(install, bool):
        fail("install must be a boolean (got %s)" % _show(install))
    if "why" in entry and not _text(entry["why"]):
        fail("why must be a non-empty single-line string")
    _check_legacy(entry, fail)
    known_kind = kind if kind in KINDS else None
    for field in KIND_NEEDS.get(known_kind, ()):
        if field not in entry:
            fail("%s entries need '%s'" % (kind, field))
    _check_source(entry, fail, ctx["listed"])
    if "repo" in entry and not (isinstance(entry["repo"], str) and OWNER_REPO_RE.fullmatch(entry["repo"])):
        fail("repo must be <owner>/<repo> (got %s)" % _show(entry["repo"]))
    if "keywords" in entry:
        words = entry["keywords"]
        if not (isinstance(words, list) and words and all(_text(word) for word in words)):
            fail("keywords must be a non-empty array of non-empty single-line strings")
    for field in ("category", "description"):
        if field in entry and not _text(entry[field]):
            fail("%s must be a non-empty single-line string" % field)
    if "explicit_consent" in entry and not isinstance(entry["explicit_consent"], bool):
        fail("explicit_consent must be a boolean (got %s)" % _show(entry["explicit_consent"]))
    if tier == "community" and install is True and entry.get("explicit_consent") is not True:
        fail("community entries must have install:false or explicit_consent:true")
    if (kind == "bundled" or tier == "bundled") and install is True:
        fail("bundled entries ship in-tree: install must be false")
    for field in ("pack", "on_demand_paths"):
        if field in entry and kind != "bundled":
            fail("%s is only allowed on bundled entries, which ship in-tree (kind is %s)" % (field, _show(kind)))
    if "pack" in entry:
        _check_pack(entry["pack"], fail)
    if "on_demand_paths" in entry:
        _check_install_paths(entry["on_demand_paths"], "on_demand_paths", fail)
    if "activate" in entry:
        _check_activate(entry["activate"], fail, ctx["detects"])
    if "triggers" in entry:
        _check_triggers(entry["triggers"], fail, index, ctx["orders"])


def _check_detection_rules(value, ctx):
    """Check detection_rules; return the rule names (what activate.detect may name)."""
    errors = ctx["errors"]
    if not _object(value, _reporter(errors, "manifest"), "detection_rules"):
        return set()
    names = set()
    for name, rule in value.items():
        fail = _reporter(errors, "detection_rules.%s" % _show(name))
        if ID_RE.fullmatch(name):
            names.add(name)
        else:
            fail("name must match %s" % ID_PATTERN)
        if not _object(rule, fail, ""):
            continue
        _keys(rule, ("files", "entries"), (), fail)
        files, members = rule.get("files"), rule.get("entries")
        if "files" in rule and not (isinstance(files, list) and files and all(_relpath(path) for path in files)):
            fail("files must be a non-empty array of relative globs without '..'")
        if "entries" in rule:
            if not (isinstance(members, list) and members and all(isinstance(member, str) for member in members)):
                fail("entries must be a non-empty array of entry ids")
            else:
                for member in members:
                    if member not in ctx["ids"]:
                        fail("entries names unknown entry id %s" % _show(member))
    return names


def _check_keyword_skills(value, ctx, fail):
    if not isinstance(value, list):
        fail("keyword_skills must be an array of github-skill entry ids")
        return
    for n, name in enumerate(value):
        found = ctx["ids"].get(name) if isinstance(name, str) else None
        if found is None or found[1] != "github-skill":
            fail("keyword_skills[%d] %s is not a github-skill entry id" % (n, _show(name)))


def validate(doc):
    """Return the reasons `doc` is not a valid manifest (an empty list means valid). Never raises on a hostile doc."""
    errors = []
    fail = _reporter(errors, "manifest")
    if not isinstance(doc, dict):
        fail("top level must be a JSON object")
        return errors
    _keys(doc, TOP_REQUIRED, TOP_OPTIONAL, fail)
    if "schema" in doc and not (type(doc["schema"]) is int and doc["schema"] == SCHEMA_VERSION):
        fail("schema must be the integer %d (got %s)" % (SCHEMA_VERSION, _show(doc["schema"])))
    listed = _check_marketplaces(doc["marketplaces"], errors) if "marketplaces" in doc else set()
    ctx = {"errors": errors, "listed": listed, "ids": {}, "orders": {}, "detects": []}
    if "entries" in doc:
        if isinstance(doc["entries"], list) and doc["entries"]:
            for index, entry in enumerate(doc["entries"]):
                _check_entry(index, entry, ctx)
        else:
            fail("entries must be a non-empty array")
    rules = _check_detection_rules(doc["detection_rules"], ctx) if "detection_rules" in doc else set()
    for report, rule in ctx["detects"]:
        if rule not in rules:
            report("activate.detect names unknown detection rule %s" % _show(rule))
    if "keyword_skills" in doc:
        _check_keyword_skills(doc["keyword_skills"], ctx, fail)
    return errors


def main(argv):
    if len(argv) != 2 or argv[0] != "validate":
        sys.stderr.write(USAGE)
        return 2
    try:
        doc = load(argv[1])
    except ManifestError as exc:
        sys.stderr.write("%s\n" % exc)
        return 1
    reasons = validate(doc)
    if reasons:
        sys.stderr.write("\n".join(reasons) + "\n")
        return 1
    sys.stdout.write("ok skills.manifest/%d (%d entries)\n" % (SCHEMA_VERSION, len(doc["entries"])))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
