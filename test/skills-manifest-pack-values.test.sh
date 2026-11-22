#!/usr/bin/env bash
#
# skills-manifest-pack-values.test.sh — the VALUES skills.manifest.json carries in its `pack` and `on_demand_paths` fields
# (lean-core plan T3.3, docs/superpowers/plans/2026-11-12-3x-lean-core.md). The RULES for the two fields (SM12, SM13: shape,
# patterns, bundled entries only) are proven in test/skills-manifest-pack.test.sh; this suite proves the DATA is right.
#
#   stacks          carries the pack bin/heimdall-pack-build builds from skills/stacks. pack.name and pack.version are the ones the
#                   build writes into the pack's hmd.skill.yaml; pack.sha256 is the content hash the build prints (`build`, `hash`
#                   and the sha256 of the SHA256SUMS the build writes all say the same); pack.paths is skills/stacks.
#                   The hash is a PIN: change a byte under skills/stacks, or the builder's constants, and this suite goes red until
#                   the pin is renewed (bin/heimdall-pack-build hash, into skills.manifest.json; PACK_VERSION by hand when a
#                   consumer should notice the change).
#   designmatch     on_demand_paths = its skill directory AND its command (commands/designmatch.md): the command is useless without
#                   the skill, so the manifest declares the two as one unit.
#   mac-deep-clean, system-health, self-improve     on_demand_paths = their skill directory.
# All five stay kind bundled, tier bundled, install false (nothing is installed: the bundled copy is still the fallback);
# every path the manifest names exists in the tree; and the five are exactly the skills bin/lib/lean_sparse.sh leaves out of a
# lean tree, each listed under skills/<id>: nothing is dropped without a route back, and the core skill (heimdall) has none.
#
# Proven in this order (one in-process driver builds the stacks pack twice at most and checks every case; the CLI runs once):
#   A. the real skills.manifest.json validates;
#   B. every value above holds on the real manifest and the real tree;
#   C. the suite can go RED: one-field breaks of the manifest, of the stacks source and of the lean list, each turning the check
#      that guards it red (exemplar: test/skills-manifest-pack.test.sh, section F).
#
# Hermetic: a throwaway WORK dir, no network, nothing outside it is written (the real tree is only read).
# bash 3.2 compatible.
#
# Usage: test/skills-manifest-pack-values.test.sh      Exit 0 = every proof holds.
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SELF_DIR/.." && pwd)"
VALIDATOR="$REPO/bin/lib/skills_manifest.py"
MANIFEST="$REPO/skills.manifest.json"
STACKS_SRC="$REPO/skills/stacks"
PASS=0; FAIL=0
ok()  { printf '  \033[32mPASS\033[0m %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAIL=$((FAIL + 1)); }

# The real interpreter, not a version-manager wrapper: this suite starts python a handful of times.
PY="$(python3 -I -c 'import sys; print(sys.executable)' 2>/dev/null)"
[ -x "${PY:-}" ] || { echo "FATAL: python3 not found"; exit 2; }
[ -f "$VALIDATOR" ] || { echo "FATAL: $VALIDATOR missing"; exit 1; }
[ -d "$STACKS_SRC" ] || { echo "FATAL: $STACKS_SRC missing"; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# ── the driver: the expected values, one check per property, the mutants; one TSV line per verdict ─────────────────────
# usage: driver.py REPO WORK STACKS_SRC. A check returns None when the property holds, else why not; it may raise (a field a
# mutant removed): that is a failed check, never a crash.
cat > "$WORK/driver.py" <<'PYEOF'
import copy
import hashlib
import os
import re
import shutil
import subprocess
import sys

repo, work, stacks_src = sys.argv[1:4]
sys.path.insert(0, os.path.join(repo, "bin", "lib"))
import skills_manifest as m

BUILDER = os.path.join(repo, "bin", "heimdall-pack-build")
LEAN_SPARSE = os.path.join(repo, "bin", "lib", "lean_sparse.sh")
MANIFEST = os.path.join(repo, "skills.manifest.json")

PACK_PATHS = ["skills/stacks"]
ON_DEMAND = {
    "designmatch": ["skills/designmatch", "commands/designmatch.md"],
    "mac-deep-clean": ["skills/mac-deep-clean"],
    "system-health": ["skills/system-health"],
    "self-improve": ["skills/self-improve"],
}
FIVE = ["stacks"] + sorted(ON_DEMAND)


def run_builder(*args):
    done = subprocess.run([sys.executable, "-I", "-B", BUILDER] + list(args), stdout=subprocess.PIPE,
                          stderr=subprocess.PIPE, universal_newlines=True)
    if done.returncode != 0:
        raise RuntimeError("heimdall-pack-build %s exited %d: %s" % (args[0], done.returncode, done.stderr.strip()[:200]))
    return done.stdout.strip()


_BUILT = {}


def built(src):
    """What a build of the stacks source SRC says about itself: the hash `build` and `hash` print, the sha256 of the SHA256SUMS
    it writes, and the id and version it writes into hmd.skill.yaml. One build per source."""
    if src not in _BUILT:
        out = os.path.join(work, "pack-%d" % len(_BUILT))
        printed = run_builder("build", "--out", out, "--src", src)
        hashed = run_builder("hash", "--src", src)
        with open(os.path.join(out, "SHA256SUMS"), "rb") as handle:
            sums = hashlib.sha256(handle.read()).hexdigest()
        with open(os.path.join(out, "hmd.skill.yaml")) as handle:
            yaml = dict(line.split(": ", 1) for line in handle.read().splitlines() if re.match(r"(id|version): ", line))
        _BUILT[src] = {"printed": printed, "hashed": hashed, "sums": sums, "id": yaml["id"], "version": yaml["version"]}
    return _BUILT[src]


def lean_on_demand():
    """The skill ids bin/lib/lean_sparse.sh leaves out of a lean tree: its LSP_ON_DEMAND line."""
    with open(LEAN_SPARSE) as handle:
        found = re.findall(r'^LSP_ON_DEMAND="([^"]*)"$', handle.read(), re.M)
    if len(found) != 1:
        raise RuntimeError('lean_sparse.sh has %d LSP_ON_DEMAND="..." lines, want exactly one' % len(found))
    return found[0].split()


def entry(doc, ident):
    for item in doc["entries"]:
        if item.get("id") == ident:
            return item
    raise LookupError("no entry with id %r" % ident)


def paths_of(item):
    return list(item["pack"]["paths"] if "pack" in item else []) + list(item.get("on_demand_paths", []))


def check_validates(doc, src, lean):
    reasons = m.validate(doc)
    return "; ".join(reasons[:3]) if reasons else None


def check_pack_name(doc, src, lean):
    got, want = entry(doc, "stacks")["pack"]["name"], "@" + built(src)["id"]
    return None if got == want else "the manifest says %r, the build's hmd.skill.yaml says %r" % (got, want)


def check_pack_version(doc, src, lean):
    got, want = entry(doc, "stacks")["pack"]["version"], built(src)["version"]
    return None if got == want else "the manifest says %r, the build's hmd.skill.yaml says %r" % (got, want)


def check_pack_sha256(doc, src, lean):
    got = entry(doc, "stacks")["pack"]["sha256"]
    made = built(src)
    differ = [what for what, value in (("build", made["printed"]), ("hash", made["hashed"]), ("SHA256SUMS", made["sums"]))
              if value != got]
    if not differ:
        return None
    return "the manifest pins %s, the build gives %s (%s differ); renew the pin with bin/heimdall-pack-build hash" \
        % (got, made["printed"], ", ".join(differ))


def check_pack_paths(doc, src, lean):
    got = entry(doc, "stacks")["pack"]["paths"]
    return None if got == PACK_PATHS else "pack.paths is %r, want %r" % (got, PACK_PATHS)


def on_demand_check(ident):
    def check(doc, src, lean):
        got = entry(doc, ident).get("on_demand_paths")
        return None if got == ON_DEMAND[ident] else "on_demand_paths is %r, want %r" % (got, ON_DEMAND[ident])
    return check


def check_stays_bundled(doc, src, lean):
    wrong = []
    for ident in FIVE:
        item = entry(doc, ident)
        have = (item.get("kind"), item.get("tier"), item.get("install"))
        if have != ("bundled", "bundled", False):
            wrong.append("%s is kind %r tier %r install %r" % (ident, have[0], have[1], have[2]))
    return "; ".join(wrong) or None


def check_paths_exist(doc, src, lean):
    missing = [path for item in doc["entries"] for path in paths_of(item) if not os.path.exists(os.path.join(repo, path))]
    return "named in the manifest, absent from the tree: %s" % ", ".join(missing) if missing else None


def check_lean_sparse(doc, src, lean):
    dropped = sorted(lean if lean is not None else lean_on_demand())
    routed = {item["id"]: paths_of(item) for item in doc["entries"] if "pack" in item or "on_demand_paths" in item}
    problems = []
    if sorted(routed) != dropped:
        problems.append("lean_sparse.sh leaves out %s, the manifest gives %s a route back" % (dropped, sorted(routed)))
    for ident in sorted(routed):
        if "skills/" + ident not in routed[ident]:
            problems.append("%s does not list skills/%s" % (ident, ident))
    return "; ".join(problems) or None


CHECKS = [
    ("validates", check_validates),
    ("stacks-pack-name", check_pack_name),
    ("stacks-pack-version", check_pack_version),
    ("stacks-pack-sha256", check_pack_sha256),
    ("stacks-pack-paths", check_pack_paths),
] + [("on-demand-" + ident, on_demand_check(ident)) for ident in sorted(ON_DEMAND)] + [
    ("stays-bundled", check_stays_bundled),
    ("paths-exist", check_paths_exist),
    ("agree-with-lean-sparse", check_lean_sparse),
]


def verdicts(doc, src, lean=None):
    """{check name: None when it holds, else why not}."""
    found = {}
    for name, check in CHECKS:
        try:
            found[name] = check(doc, src, lean)
        except Exception as exc:
            found[name] = "raised %s: %s" % (type(exc).__name__, exc)
    return found


def report(name, problem):
    print("%s\t%s\t%s" % ("bad" if problem else "ok", name, ascii(problem) if problem else "-"))


real = m.load(MANIFEST)
for name, problem in verdicts(real, stacks_src).items():
    report("holds-" + name, problem)


# Each mutant changes exactly one thing: a field of the manifest (code, run on a copy), the stacks source, or the lean list.
def edited_source():
    """A copy of the stacks source with one byte added to one pack: the tree changed, the manifest did not."""
    target = os.path.join(work, "stacks-edited")
    shutil.copytree(stacks_src, target)
    with open(os.path.join(target, "fastapi", "PACK.md"), "ab") as handle:
        handle.write(b"\n")
    return target


MUTANTS = [
    ("sha-one-digit-off", "stacks-pack-sha256", 'E["stacks"]["pack"]["sha256"] = ("0" if SHA[0] != "0" else "1") + SHA[1:]'),
    ("sha-uppercased", "validates", 'E["stacks"]["pack"]["sha256"] = SHA.upper()'),
    ("version-bumped", "stacks-pack-version", 'E["stacks"]["pack"]["version"] = "1.0.1"'),
    ("name-changed", "stacks-pack-name", 'E["stacks"]["pack"]["name"] = "@runhmd/stack"'),
    ("pack-dropped", "stacks-pack-sha256", 'del E["stacks"]["pack"]'),
    ("pack-path-typo", "paths-exist", 'E["stacks"]["pack"]["paths"] = ["skills/stack"]'),
    ("designmatch-command-dropped", "on-demand-designmatch", 'E["designmatch"]["on_demand_paths"] = ["skills/designmatch"]'),
    ("designmatch-command-renamed", "paths-exist", 'E["designmatch"]["on_demand_paths"][1] = "commands/design-match.md"'),
    ("self-improve-without-a-route-back", "agree-with-lean-sparse", 'del E["self-improve"]["on_demand_paths"]'),
    ("core-skill-made-on-demand", "agree-with-lean-sparse", 'E["heimdall"]["on_demand_paths"] = ["skills/heimdall"]'),
    ("tier-changed", "stays-bundled", 'E["mac-deep-clean"]["tier"] = "on_demand"'),
    ("stacks-source-edited", "stacks-pack-sha256", "SRC = edited_source()"),
    ("lean-sparse-leaves-out-another-skill", "agree-with-lean-sparse", 'LEAN = lean_on_demand() + ["heimdall"]'),
]

for name, expected, code in MUTANTS:
    label = "mutant-%s-turns-%s-red" % (name, expected)
    try:
        doc = copy.deepcopy(real)
        scope = {"E": {item["id"]: item for item in doc["entries"]}, "SHA": entry(real, "stacks")["pack"]["sha256"],
                 "SRC": stacks_src, "LEAN": None, "edited_source": edited_source, "lean_on_demand": lean_on_demand}
        exec(code, scope)
        found = verdicts(doc, scope["SRC"], scope["LEAN"])
    except Exception as exc:
        report(label, "the mutant could not be built: %s: %s" % (type(exc).__name__, exc))
        continue
    report(label, None if found[expected] else "SURVIVED: %s still holds" % expected)
PYEOF

# ── A. the real manifest validates ─────────────────────────────────────────────────────────────────────────────────────
OUT="$("$PY" -I "$VALIDATOR" validate "$MANIFEST" 2>&1)"; RC=$?
if [ "$RC" -eq 0 ] && [[ "$OUT" == "ok skills.manifest/1 ("* ]]; then
  ok "A: the real skills.manifest.json validates ($OUT)"
else
  bad "A: the real skills.manifest.json does not validate (rc=$RC): ${OUT:0:300}"
fi

# ── B, C. every value on the real manifest and tree, then the mutants ──────────────────────────────────────────────────
if "$PY" -I -B "$WORK/driver.py" "$REPO" "$WORK" "$STACKS_SRC" >"$WORK/driver.out" 2>"$WORK/driver.err"; then
  CASES=0; MUTANTS=0; CAUGHT=0
  while IFS=$'\t' read -r verdict name detail; do
    [ -n "$verdict" ] || continue
    CASES=$((CASES + 1))
    case "$name" in
      mutant-*) MUTANTS=$((MUTANTS + 1)); if [ "$verdict" = ok ]; then CAUGHT=$((CAUGHT + 1)); fi ;;
    esac
    if [ "$verdict" = ok ]; then ok "$name"; else bad "$name: $detail"; fi
  done <"$WORK/driver.out"
  if [ "$CASES" -ge 25 ]; then ok "the driver ran $CASES cases (at least 25: a truncated table must not read as a pass)"; else bad "the driver ran only $CASES cases (want at least 25)"; fi
  echo "  falsifiability score $CAUGHT/$MUTANTS"
  if [ "$MUTANTS" -ge 13 ] && [ "$CAUGHT" -eq "$MUTANTS" ]; then
    ok "C: every mutant is caught (score $CAUGHT/$MUTANTS, at least 13)"
  else
    bad "C: a mutant survived or could not be built (score $CAUGHT/$MUTANTS, want all and at least 13)"
  fi
else
  bad "the case driver crashed: $(tail -n 5 "$WORK/driver.err")"
fi

echo "--------------------------------------------------------------------"
printf 'skills-manifest-pack-values: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
