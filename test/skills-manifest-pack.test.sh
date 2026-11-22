#!/usr/bin/env bash
#
# skills-manifest-pack.test.sh — skills.manifest v1: the optional `pack` and `on_demand_paths` entry fields
# (lean-core plan T2.3, docs/superpowers/plans/2026-11-12-3x-lean-core.md; invariants: .planning/lean-core/INVARIANTS.md).
#
# A lean install leaves some in-tree skills out of the working tree and adds them on request (`git sparse-checkout add`);
# a skill can also ship as a hash-pinned pack whose copy the resolver prefers while the hash matches (INV-L4, INV-L5).
# Both are DATA the manifest has to be able to carry before anything reads it, so bin/lib/skills_manifest.py learns two
# optional entry fields and fails CLOSED on them, like on every other field:
#   pack             {name, version, sha256, paths[]}: the in-tree content as a pack. name is @<scope>/<name>, version
#                    is MAJOR.MINOR.PATCH with an optional -prerelease, sha256 is the full content hash (64 lowercase
#                    hex digits, no prefix, no truncation), paths are the tree paths the pack covers; nothing else is
#                    allowed inside it
#   on_demand_paths  [path, ...]: the tree paths `add` brings into a sparse checkout on request
# Both kinds of path end up in a sparse-checkout command, so each one is a literal tree path (no glob, no leading '-', no
# hidden or '.' segment, no '..', not absolute), and both fields belong to `bundled` entries, the ones that ship in-tree.
#
# Proven here (an in-process driver runs one validate() per case; a few CLI runs prove the exit codes and the text):
#   A. optional: a manifest that uses neither field is valid, so is every legal shape of them, and the real
#      skills.manifest.json still validates (nothing the `full` profile reads changes: INV-L1);
#   B. for every rule there is a corrupted copy of the one valid fixture that differs in ONE thing; it is rejected and a
#      reason names that rule, so a rule that stops firing turns its own case red;
#   C. hostile values (wrong types, control characters, a huge string) never raise and never put a control character
#      into a reason: the operator's terminal is not writable through a manifest;
#   D. the CLI: exit 0 / 1, one reason per line on stderr, no traceback, nothing the terminal would act on;
#   E. docs/schemas/skills.manifest.v1.json and the validator state the same contract for the new fields;
#   F. the suite can go RED: one-line breaks of the validator, each turning the case that guards it red
#      (exemplar: test/skills-lock.test.sh, section H).
#
# Hermetic: a throwaway WORK dir, no network, nothing outside it is written (the real manifest is only read).
# bash 3.2 compatible.
#
# Usage: test/skills-manifest-pack.test.sh      Exit 0 = every proof holds.
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SELF_DIR/.." && pwd)"
VALIDATOR="$REPO/bin/lib/skills_manifest.py"
SCHEMA="$REPO/docs/schemas/skills.manifest.v1.json"
PASS=0; FAIL=0
ok()  { printf '  \033[32mPASS\033[0m %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAIL=$((FAIL + 1)); }

# The real interpreter, not a version-manager wrapper: this suite starts python a few dozen times.
PY="$(python3 -I -c 'import sys; print(sys.executable)' 2>/dev/null)"
[ -x "${PY:-}" ] || { echo "FATAL: python3 not found"; exit 2; }
[ -f "$VALIDATOR" ] || { echo "FATAL: $VALIDATOR missing"; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/mut"

# ── the case driver: one valid fixture, the case tables, the hostile battery; one TSV line per verdict ─────────────────
# usage: driver.py LIBDIR WORKDIR [fixtures]. LIBDIR holds the skills_manifest.py under test (the real one, or a mutant);
# `fixtures` also writes the three manifests the CLI cases below run on. Every case changes exactly one thing of BASE.
cat > "$WORK/driver.py" <<'PYEOF'
import copy
import json
import re
import sys

libdir, work = sys.argv[1], sys.argv[2]
sys.path.insert(0, libdir)
import skills_manifest as m

SHA = "0123456789abcdef" * 4
LEGACY = [{"mechanism": "skills/", "path": "skills/x/SKILL.md"}]
BASE = {
    "schema": 1,
    "marketplaces": {"claude-plugins-official": {"source": "anthropics/claude-plugins-official", "pin": None}},
    "entries": [
        {"id": "stacks", "kind": "bundled", "ref": "skills/stacks", "install": False, "tier": "bundled",
         "why": "Stack knowledge packs; ships in-tree, never installed", "legacy": LEGACY,
         "pack": {"name": "@runhmd/stacks", "version": "1.0.0", "sha256": SHA, "paths": ["skills/stacks"]}},
        {"id": "designmatch", "kind": "bundled", "ref": "skills/designmatch", "install": False, "tier": "bundled",
         "why": "Visual QA loop; ships in-tree, never installed", "legacy": LEGACY,
         "on_demand_paths": ["skills/designmatch", "commands/designmatch.md"]},
        {"id": "frontend-design", "kind": "plugin", "ref": "frontend-design@claude-plugins-official",
         "marketplace": "claude-plugins-official", "install": True, "tier": "recommended",
         "why": "UI work gets design guidance", "legacy": LEGACY},
        {"id": "ui-ux-pro-max", "kind": "github-skill", "repo": "nextlevelbuilder/ui-ux-pro-max-skill",
         "install": True, "tier": "detected", "why": "Design prompts match its keywords", "keywords": ["ui"],
         "category": "design", "description": "UI/UX design skill", "legacy": LEGACY},
    ],
}
CONTROL = re.compile(r"[\x00-\x1f\x7f]")

# S stacks (bundled, has a pack), D designmatch (bundled, has on_demand_paths), P a plugin entry, G a github-skill entry.
ACCEPTS = [
    ("fixture-stacks-pack-designmatch-on-demand", ""),
    ("neither-field-used", 'del S["pack"]; del D["on_demand_paths"]'),
    ("pack-and-on-demand-on-one-entry", 'S["on_demand_paths"] = ["skills/stacks"]'),
    ("pack-beside-another-tier", 'S["tier"] = "on_demand"'),
    ("version-with-a-prerelease", 'S["pack"]["version"] = "1.2.3-rc.1"'),
    ("version-0-0-0", 'S["pack"]["version"] = "0.0.0"'),
    ("name-with-dot-dash-digit", 'S["pack"]["name"] = "@run-hmd.x/stacks-2"'),
    ("several-paths", 'S["pack"]["paths"] = ["skills/stacks", "skills/stacks/fastapi/PACK.md", "bin/stack-pack"]'),
    ("path-characters-dot-underscore-dash", 'S["pack"]["paths"] = ["_a/b-c/d.e/f_g"]'),
    ("path-of-exactly-256-characters", 'S["pack"]["paths"] = ["/".join(["a" * 63] * 3 + ["a" * 64])]'),
]

REJECTS = [
    # the pack object: closed, every key required
    ("pack-null", 'S["pack"] = None', "pack must be an object"),
    ("pack-a-list", 'S["pack"] = []', "pack must be an object"),
    ("pack-empty", 'S["pack"] = {}', "pack: missing required property 'name'"),
    ("pack-without-version", 'del S["pack"]["version"]', "pack: missing required property 'version'"),
    ("pack-without-sha256", 'del S["pack"]["sha256"]', "pack: missing required property 'sha256'"),
    ("pack-without-paths", 'del S["pack"]["paths"]', "pack: missing required property 'paths'"),
    ("pack-extra-key", 'S["pack"]["url"] = "https://x.example/p.tgz"', "pack: unexpected property 'url'"),
    # pack.name
    ("name-unscoped", 'S["pack"]["name"] = "stacks"', "pack.name must be @<scope>/<name>"),
    ("name-without-package", 'S["pack"]["name"] = "@runhmd/"', "pack.name must be"),
    ("name-without-scope", 'S["pack"]["name"] = "@/stacks"', "pack.name must be"),
    ("name-uppercase", 'S["pack"]["name"] = "@runhmd/Stacks"', "pack.name must be"),
    ("name-three-parts", 'S["pack"]["name"] = "@runhmd/stacks/x"', "pack.name must be"),
    ("name-scope-too-long", 'S["pack"]["name"] = "@" + "a" * 65 + "/stacks"', "pack.name must be"),
    ("name-trailing-newline", 'S["pack"]["name"] = "@runhmd/stacks\\n"', "pack.name must be"),
    ("name-not-a-string", 'S["pack"]["name"] = 7', "pack.name must be"),
    # pack.version
    ("version-two-parts", 'S["pack"]["version"] = "1.0"', "pack.version must be MAJOR.MINOR.PATCH"),
    ("version-v-prefix", 'S["pack"]["version"] = "v1.0.0"', "pack.version must be"),
    ("version-leading-zero", 'S["pack"]["version"] = "01.0.0"', "pack.version must be"),
    ("version-build-metadata", 'S["pack"]["version"] = "1.0.0+build.5"', "pack.version must be"),
    ("version-empty-prerelease", 'S["pack"]["version"] = "1.0.0-"', "pack.version must be"),
    ("version-fullwidth-digits", 'S["pack"]["version"] = "\\uff11.\\uff10.\\uff10"', "pack.version must be"),
    ("version-trailing-newline", 'S["pack"]["version"] = "1.0.0\\n"', "pack.version must be"),
    ("version-a-number", 'S["pack"]["version"] = 1.0', "pack.version must be"),
    # pack.sha256: the full hash, nothing shorter, nothing prefixed
    ("sha256-uppercase", 'S["pack"]["sha256"] = SHA.upper()', "pack.sha256 must be"),
    ("sha256-63-digits", 'S["pack"]["sha256"] = SHA[:-1]', "pack.sha256 must be"),
    ("sha256-65-digits", 'S["pack"]["sha256"] = SHA + "0"', "pack.sha256 must be"),
    ("sha256-prefixed", 'S["pack"]["sha256"] = "sha256:" + SHA', "pack.sha256 must be"),
    ("sha256-not-hex", 'S["pack"]["sha256"] = "g" * 64', "pack.sha256 must be"),
    ("sha256-trailing-newline", 'S["pack"]["sha256"] = SHA + "\\n"', "pack.sha256 must be"),
    ("sha256-null", 'S["pack"]["sha256"] = None', "pack.sha256 must be"),
    ("sha256-a-number", 'S["pack"]["sha256"] = 0', "pack.sha256 must be"),
    # pack.paths: a non-empty array of literal tree paths
    ("paths-empty", 'S["pack"]["paths"] = []', "pack.paths must be a non-empty array"),
    ("paths-null", 'S["pack"]["paths"] = None', "pack.paths must be a non-empty array"),
    ("paths-a-string", 'S["pack"]["paths"] = "skills/stacks"', "pack.paths must be a non-empty array"),
    ("path-not-a-string", 'S["pack"]["paths"] = ["skills/stacks", 3]', "pack.paths[1] must be a literal tree path"),
    ("path-escapes-up", 'S["pack"]["paths"] = ["../x"]', "pack.paths[0] must be a literal tree path"),
    ("path-escapes-up-in-the-middle", 'S["pack"]["paths"] = ["skills/../../x"]', "pack.paths[0] must be"),
    ("path-absolute", 'S["pack"]["paths"] = ["/etc/passwd"]', "pack.paths[0] must be"),
    ("path-looks-like-an-option", 'S["pack"]["paths"] = ["--stdin"]', "pack.paths[0] must be"),
    ("path-segment-looks-like-an-option", 'S["pack"]["paths"] = ["skills/-x"]', "pack.paths[0] must be"),
    ("path-is-a-glob", 'S["pack"]["paths"] = ["skills/*"]', "pack.paths[0] must be"),
    ("path-is-the-whole-tree", 'S["pack"]["paths"] = ["."]', "pack.paths[0] must be"),
    ("path-dot-segment", 'S["pack"]["paths"] = ["skills/./stacks"]', "pack.paths[0] must be"),
    ("path-hidden-segment", 'S["pack"]["paths"] = [".git/config"]', "pack.paths[0] must be"),
    ("path-trailing-slash", 'S["pack"]["paths"] = ["skills/stacks/"]', "pack.paths[0] must be"),
    ("path-empty-segment", 'S["pack"]["paths"] = ["skills//stacks"]', "pack.paths[0] must be"),
    ("path-empty", 'S["pack"]["paths"] = [""]', "pack.paths[0] must be"),
    ("path-negation", 'S["pack"]["paths"] = ["!skills/stacks"]', "pack.paths[0] must be"),
    ("path-backslash", 'S["pack"]["paths"] = ["skills" + chr(92) + "stacks"]', "pack.paths[0] must be"),
    ("path-with-a-space", 'S["pack"]["paths"] = ["skills/my stacks"]', "pack.paths[0] must be"),
    ("path-non-ascii", 'S["pack"]["paths"] = ["skills/st\\u00e4cks"]', "pack.paths[0] must be"),
    ("path-control-character", 'S["pack"]["paths"] = ["skills/\\x1b[31mstacks"]', "pack.paths[0] must be"),
    ("path-trailing-newline", 'S["pack"]["paths"] = ["skills/stacks\\n"]', "pack.paths[0] must be"),
    ("path-257-characters", 'S["pack"]["paths"] = ["/".join(["a" * 63] * 3 + ["a" * 65])]', "pack.paths[0] must be"),
    # on_demand_paths: the same paths, the same array rule
    ("on-demand-empty", 'D["on_demand_paths"] = []', "on_demand_paths must be a non-empty array"),
    ("on-demand-null", 'D["on_demand_paths"] = None', "on_demand_paths must be a non-empty array"),
    ("on-demand-a-string", 'D["on_demand_paths"] = "skills/designmatch"', "on_demand_paths must be a non-empty array"),
    ("on-demand-path-not-a-string", 'D["on_demand_paths"] = [None]', "on_demand_paths[0] must be a literal tree path"),
    ("on-demand-path-escapes-up", 'D["on_demand_paths"] = ["skills/designmatch", "../x"]', "on_demand_paths[1] must be a literal tree path"),
    ("on-demand-path-absolute", 'D["on_demand_paths"] = ["/etc"]', "on_demand_paths[0] must be"),
    ("on-demand-path-glob", 'D["on_demand_paths"] = ["commands/*.md"]', "on_demand_paths[0] must be"),
    # only in-tree content: the two fields belong to bundled entries
    ("pack-on-a-plugin", 'P["pack"] = copy.deepcopy(S["pack"])', "pack is only allowed on bundled entries"),
    ("pack-on-a-github-skill", 'G["pack"] = copy.deepcopy(S["pack"])', "pack is only allowed on bundled entries"),
    ("on-demand-on-a-plugin", 'P["on_demand_paths"] = ["skills/x"]', "on_demand_paths is only allowed on bundled entries"),
    ("on-demand-on-a-github-skill", 'G["on_demand_paths"] = ["skills/x"]', "on_demand_paths is only allowed on bundled entries"),
    # the new fields relax nothing that was already a rule
    ("bundled-install-still-rejected", 'S["install"] = True', "bundled entries ship in-tree: install must be false"),
]

# One value that is invalid for every target below, per row: the validator must say so, never raise, and never let a
# control character into a reason.
BATTERY = [None, True, False, 0, 1, 1.5, "", " ", {}, {"a": 1}, "x" * 100000, "\x00", "a\nb", "\u202e", "\x1b[2J",
           [[]], [None], [{}], [True]]
TARGETS = [("S", ("pack",)), ("S", ("pack", "name")), ("S", ("pack", "version")), ("S", ("pack", "sha256")),
           ("S", ("pack", "paths")), ("S", ("pack", "paths", 0)), ("D", ("on_demand_paths",)),
           ("D", ("on_demand_paths", 1))]
HOSTILE = ('S["pack"]["name"] = "@runhmd/\\x1b[2Jstacks"; S["pack"]["version"] = "1.0.0\\r\\n"; '
           'S["pack"]["paths"] = ["a\\r\\nb\\x1b]0;pwned\\x07", "\\u202e/x"]; '
           'D["on_demand_paths"] = ["skills/\\x1b[31mdesignmatch"]')


def build(code):
    doc = copy.deepcopy(BASE)
    by_id = {entry["id"]: entry for entry in doc["entries"]}
    scope = {"d": doc, "S": by_id["stacks"], "D": by_id["designmatch"], "P": by_id["frontend-design"],
             "G": by_id["ui-ux-pro-max"], "SHA": SHA, "copy": copy}
    exec(code, scope)
    return doc


def validate(doc):
    """(reasons, raised): what validate() said about doc, and the exception text if it raised."""
    try:
        return m.validate(doc), None
    except Exception as exc:
        return [], "%s: %s" % (type(exc).__name__, exc)


def report(name, problem):
    print("%s\t%s\t%s" % ("bad" if problem else "ok", name, ascii(problem) if problem else "-"))


for name, code in ACCEPTS:
    reasons, raised = validate(build(code))
    report("accepts-" + name, raised or (reasons[:3] if reasons else None))

for name, code, fragment in REJECTS:
    reasons, raised = validate(build(code))
    if raised:
        report("rejects-" + name, "raised " + raised)
    elif not any(fragment in reason for reason in reasons):
        report("rejects-" + name, "no reason names %r; got %r" % (fragment, reasons[:3]))
    else:
        report("rejects-" + name, None)

for owner, path in TARGETS:
    problems = []
    for value in BATTERY:
        doc = copy.deepcopy(BASE)
        node = {entry["id"]: entry for entry in doc["entries"]}[{"S": "stacks", "D": "designmatch"}[owner]]
        for key in path[:-1]:
            node = node[key]
        node[path[-1]] = value
        reasons, raised = validate(doc)
        shown = ascii(value)[:24]
        if raised:
            problems.append("%s raised %s" % (shown, raised))
        elif not reasons:
            problems.append("%s was accepted" % shown)
        elif any(CONTROL.search(reason) for reason in reasons):
            problems.append("%s: a reason carries a control character" % shown)
    label = path[0] + "".join("[%d]" % key if isinstance(key, int) else "." + key for key in path[1:])
    report("hostile-" + label, "; ".join(problems[:3]) if problems else None)

if len(sys.argv) > 3:
    for name, code in (("valid", ""), ("bad-sha256", 'S["pack"]["sha256"] = SHA.upper()'), ("hostile", HOSTILE)):
        with open("%s/%s.json" % (work, name), "w") as out:
            json.dump(build(code), out)
PYEOF

# ── A, B, C: every case of the tables and the battery, against the real validator ──────────────────────────────────────
if "$PY" -I -B "$WORK/driver.py" "$REPO/bin/lib" "$WORK" fixtures >"$WORK/driver.out" 2>"$WORK/driver.err"; then
  CASES=0
  while IFS=$'\t' read -r verdict name detail; do
    [ -n "$verdict" ] || continue
    CASES=$((CASES + 1))
    if [ "$verdict" = ok ]; then ok "$name"; else bad "$name: $detail"; fi
  done <"$WORK/driver.out"
  if [ "$CASES" -ge 84 ]; then ok "the driver ran $CASES cases (at least 84: a truncated table must not read as a pass)"; else bad "the driver ran only $CASES cases (want at least 84)"; fi
else
  bad "the case driver crashed: $(tail -n 5 "$WORK/driver.err")"
fi

# ── A. the real manifest still validates ───────────────────────────────────────────────────────────────────────────────
OUT="$("$PY" -I "$VALIDATOR" validate "$REPO/skills.manifest.json" 2>&1)"; RC=$?
if [ "$RC" -eq 0 ] && [[ "$OUT" == "ok skills.manifest/1 ("* ]]; then
  ok "A: the real skills.manifest.json validates ($OUT)"
else
  bad "A: the real skills.manifest.json no longer validates (rc=$RC): ${OUT:0:300}"
fi

# ── D. the CLI ─────────────────────────────────────────────────────────────────────────────────────────────────────────
OUT="$("$PY" -I "$VALIDATOR" validate "$WORK/valid.json" 2>&1)"; RC=$?
if [ "$RC" -eq 0 ] && [ "$OUT" = "ok skills.manifest/1 (4 entries)" ]; then
  ok "D: a manifest with a pack and on_demand_paths is accepted ($OUT)"
else
  bad "D: a manifest with a pack and on_demand_paths (rc=$RC): ${OUT:0:300}"
fi

OUT="$("$PY" -I "$VALIDATOR" validate "$WORK/bad-sha256.json" 2>&1)"; RC=$?
if [ "$RC" -eq 1 ] && [[ "$OUT" == *"pack.sha256 must be 64 lowercase hex digits"* ]] && [[ "$OUT" != *Traceback* ]] \
   && [ "$(printf '%s\n' "$OUT" | wc -l | tr -d ' ')" -eq 1 ]; then
  ok "D: a bad sha256 is exit 1 with exactly one reason line"
else
  bad "D: a bad sha256 wants exit 1 and one reason line (rc=$RC): ${OUT:0:300}"
fi

OUT="$("$PY" -I "$VALIDATOR" validate "$WORK/hostile.json" 2>&1)"; RC=$?
if [ "$RC" -eq 1 ] && [[ "$OUT" != *Traceback* ]] && [[ "$OUT" == *'\x1b'* ]] \
   && [[ "$OUT" != *$'\033'* ]] && [[ "$OUT" != *$'\r'* ]] && [[ "$OUT" != *$'\a'* ]]; then
  ok "D: control characters in a hostile manifest come back escaped (no ESC, CR or BEL reaches the terminal)"
else
  bad "D: a hostile manifest wants exit 1 and escaped control characters (rc=$RC): $(printf '%s' "${OUT:0:300}" | od -c | head -n 6)"
fi

# ── E. the schema file and the validator are one contract for the new fields ───────────────────────────────────────────
cat > "$WORK/drift.py" <<'PYEOF'
import json
import sys

sys.path.insert(0, sys.argv[1])
import skills_manifest as m

with open(sys.argv[2]) as handle:
    schema = json.load(handle)
defs = schema["$defs"]
entry = defs["entry"]
pack = defs["pack"]
pairs = [
    ("the pack name pattern", defs["packName"]["pattern"], "^" + m.PACK_NAME_PATTERN + "$"),
    ("the pack version pattern", defs["packVersion"]["pattern"], "^" + m.PACK_VERSION_PATTERN + "$"),
    ("the sha256 pattern", defs["sha256"]["pattern"], "^" + m.SHA256_PATTERN + "$"),
    ("the install path pattern", defs["installPath"]["pattern"], "^" + m.INSTALL_PATH_PATTERN + "$"),
    ("the path length cap", defs["installPath"]["maxLength"], m.MAX_PATH_CHARS),
    ("the pack keys", sorted(pack["properties"]), sorted(m.PACK_KEYS)),
    ("the required pack keys", sorted(pack["required"]), sorted(m.PACK_KEYS)),
    ("rejecting unknown pack keys", pack.get("additionalProperties"), False),
    ("the type of each pack field", [pack["properties"][key]["$ref"] for key in ("name", "version", "sha256")],
     ["#/$defs/packName", "#/$defs/packVersion", "#/$defs/sha256"]),
    ("the paths of a pack", [pack["properties"]["paths"]["minItems"], pack["properties"]["paths"]["items"]["$ref"]],
     [1, "#/$defs/installPath"]),
    ("the pack field of an entry", entry["properties"]["pack"]["$ref"], "#/$defs/pack"),
    ("the on_demand_paths field of an entry",
     [entry["properties"]["on_demand_paths"]["minItems"], entry["properties"]["on_demand_paths"]["items"]["$ref"]],
     [1, "#/$defs/installPath"]),
    ("the entry keys (the comparison test/skills-manifest-schema.test.sh makes, so this change is proven here)",
     sorted(entry["properties"]), sorted(m.ENTRY_REQUIRED + m.ENTRY_OPTIONAL)),
    ("the invariants SM12 and SM13",
     sorted(item["id"] for item in schema["x-invariants"] if item["id"] in ("SM12", "SM13")), ["SM12", "SM13"]),
]
for what, in_file, in_code in pairs:
    if in_file == in_code:
        print("ok\tthe schema file and the validator agree on " + what)
    else:
        print("bad\t%s differ: the schema file says %r, the validator says %r" % (what, in_file, in_code))
PYEOF
DRIFT="$("$PY" -I -B "$WORK/drift.py" "$REPO/bin/lib" "$SCHEMA" 2>&1)"; RC=$?
if [ "$RC" -ne 0 ]; then
  bad "E: the schema file could not be compared with the validator (rc=$RC): $(printf '%s\n' "$DRIFT" | tail -n 3)"
else
  while IFS=$'\t' read -r verdict what; do
    if [ "$verdict" = ok ]; then ok "E: $what"; else bad "E: $what"; fi
  done <<<"$DRIFT"
fi

# ── F. the suite can go RED: a copy of the validator with one line broken must turn the named case red ─────────────────
echo "F. falsifiability"
MUT_TOTAL=0
MUT_CAUGHT=0
mutant() {  # mutant NAME CASE OLD NEW: a copy of the validator with OLD (found exactly once) replaced by NEW must turn CASE red
  local name="$1" case_name="$2"
  MUT_TOTAL=$((MUT_TOTAL + 1))
  mkdir -p "$WORK/mut/$name"
  if ! "$PY" -I - "$VALIDATOR" "$WORK/mut/$name/skills_manifest.py" "$3" "$4" 2>"$WORK/mutate.err" <<'PYEOF'
import sys
source, target, old, new = sys.argv[1:5]
text = open(source).read()
if text.count(old) != 1:
    sys.exit("the anchor is found %d times, want exactly once: %r" % (text.count(old), old))
open(target, "w").write(text.replace(old, new))
PYEOF
  then
    bad "F. mutant $name could not be built: $(cat "$WORK/mutate.err")"
  elif ! "$PY" -I -B "$WORK/driver.py" "$WORK/mut/$name" "$WORK" >"$WORK/mut/$name/out" 2>"$WORK/mut/$name/err"; then
    bad "F. mutant $name made the driver crash instead of turning $case_name red: $(tail -n 2 "$WORK/mut/$name/err")"
  elif grep -q -F "$(printf 'bad\t%s\t' "$case_name")" "$WORK/mut/$name/out"; then
    MUT_CAUGHT=$((MUT_CAUGHT + 1)); ok "F. mutant $name turns $case_name red"
  else
    bad "F. mutant $name SURVIVED: $case_name still passes"
  fi
}
mutant sha-any-length      rejects-sha256-63-digits           'SHA256_PATTERN = r"[0-9a-f]{64}"' 'SHA256_PATTERN = r"[0-9a-f]{1,64}"'
mutant sha-unanchored      rejects-sha256-65-digits           'regex.fullmatch(value)' 'regex.match(value)'
mutant version-zeros       rejects-version-leading-zero       'PACK_VERSION_PATTERN = r"(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-[0-9A-Za-z.-]{1,32})?"' 'PACK_VERSION_PATTERN = r"[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]{1,32})?"'
mutant name-unscoped       rejects-name-unscoped              'PACK_NAME_PATTERN = "@" + ID_PATTERN + "/" + ID_PATTERN' 'PACK_NAME_PATTERN = "(@" + ID_PATTERN + "/)?" + ID_PATTERN'
mutant pack-extra-keys     rejects-pack-extra-key             'PACK_KEYS, (), _scoped(fail, "pack:")' 'PACK_KEYS, ("url",), _scoped(fail, "pack:")'
mutant paths-optional      rejects-pack-without-paths         'PACK_KEYS, (), _scoped(fail, "pack:")' 'PACK_KEYS[:3], ("paths",), _scoped(fail, "pack:")'
mutant empty-paths         rejects-paths-empty                'if not (isinstance(paths, list) and paths):' 'if not isinstance(paths, list):'
mutant glob-paths          rejects-path-is-a-glob             'INSTALL_PATH_PATTERN = r"[A-Za-z0-9_][A-Za-z0-9._-]*(/[A-Za-z0-9_][A-Za-z0-9._-]*)*"' 'INSTALL_PATH_PATTERN = r"[^ ]+"'
mutant no-length-cap       rejects-path-257-characters        'MAX_PATH_CHARS = 256' 'MAX_PATH_CHARS = 4096'
mutant raw-values          'hostile-pack.paths[0]'            'MAX_PATH_CHARS, _show(path)))' 'MAX_PATH_CHARS, path))'
mutant any-kind            rejects-pack-on-a-plugin           'if field in entry and kind != "bundled":' 'if False:'
mutant on-demand-unchecked rejects-on-demand-path-escapes-up  '_check_install_paths(entry["on_demand_paths"], "on_demand_paths", fail)' 'None'
mutant pack-unchecked      rejects-sha256-uppercase           '_check_pack(entry["pack"], fail)' 'None'
echo "  falsifiability score $MUT_CAUGHT/$MUT_TOTAL"
if [ "$MUT_CAUGHT" -eq "$MUT_TOTAL" ] && [ "$MUT_TOTAL" -ge 12 ]; then
  ok "F. every mutant of the validator is caught (score $MUT_CAUGHT/$MUT_TOTAL, at least 12)"
else
  bad "F. a mutant of the validator survived or could not be built (score $MUT_CAUGHT/$MUT_TOTAL, want all and at least 12)"
fi

echo "--------------------------------------------------------------------"
printf 'skills-manifest-pack: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
