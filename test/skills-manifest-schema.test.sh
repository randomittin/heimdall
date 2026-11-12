#!/usr/bin/env bash
#
# skills-manifest-schema.test.sh — skills.manifest v1: the contract file and its validator
# (3.x M1, T0.3).
#
# skills.manifest.json is to become the ONE source of skill and plugin mappings (it replaces
# heimdall-skills.json, skills-registry.json and plugin-autoinstall.md; those three stay
# authoritative while the flag skills.registry is off). Whatever reads it has to be able to trust
# its shape, so it has a contract — docs/schemas/skills.manifest.v1.json — and
# bin/lib/skills_manifest.py enforces it. The validator fails CLOSED: what it cannot positively
# accept is rejected, with the reason on stderr and never a traceback.
#
# Proven here:
#   A. the valid fixture is accepted (exit 0);
#   B. variants that are still valid are accepted — every tier, a community entry that is
#      install:false or carries explicit_consent, the optional parts left out — so a rule is never
#      "reject more than it should";
#   C. for every rule there is a corrupted copy of the fixture that differs in ONE thing; it is
#      rejected (exit 1), a reason line names that rule, and the output is no traceback. A rule that
#      stops firing therefore turns its own case red, and the exit code alone never carries a case;
#   D. malformed input fails closed: a missing, oversized, non-JSON or over-nested file, duplicate
#      object keys, a top level that is not an object;
#   E. a usage error exits 2;
#   F. the schema file and the validator state the same contract (version, kinds, tiers, patterns,
#      key sets). The validator never reads the schema file at run time, so this is what keeps the
#      two one contract.
#
# Hermetic: a throwaway WORK dir, no network, nothing outside it is read or written.
#
# Usage: test/skills-manifest-schema.test.sh      Exit 0 = every proof holds.
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SELF_DIR/.." && pwd)"
PASS=0; FAIL=0
ok()  { printf '  \033[32mPASS\033[0m %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAIL=$((FAIL + 1)); }

PY="$(command -v python3 || true)"
[ -n "$PY" ] || { echo "FATAL: python3 not found"; exit 2; }

VALIDATOR="$REPO/bin/lib/skills_manifest.py"
SCHEMA="$REPO/docs/schemas/skills.manifest.v1.json"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# One validator run over $WORK/<name>.json -> OUT (stdout and stderr together) and RC.
run_validator() { OUT="$("$PY" -I "$VALIDATOR" validate "$WORK/$1.json" 2>&1)"; RC=$?; }

accept() {  # NAME — $WORK/NAME.json must validate
  run_validator "$1"
  if [ "$RC" -eq 0 ] && [[ "$OUT" == "ok skills.manifest/1"* ]]; then
    ok "accepted: $1"
  else
    bad "accepted: $1 (rc=$RC): ${OUT:0:300}"
  fi
}

reject() {  # NAME FRAGMENT — exit 1, a reason naming FRAGMENT, no traceback
  run_validator "$1"
  if [ "$RC" -eq 1 ] && [[ "$OUT" == *"$2"* ]] && [[ "$OUT" != *Traceback* ]]; then
    ok "rejected: $1 -> $2"
  else
    bad "rejected: $1 wants exit 1 naming '$2' (rc=$RC): ${OUT:0:300}"
  fi
}

# ── A. the valid fixture: the real manifest in miniature ─────────────────────────────
# Six entries, one of each shape: two install:true plugins with prompt and file triggers, an
# activation-only plugin from an unlisted marketplace (legacy caveman@caveman / design-for-ai@rtd),
# a github skill, a bundled skill and a community entry.
cat > "$WORK/valid.json" <<'JSON'
{
  "schema": 1,
  "marketplaces": {
    "claude-plugins-official": {"source": "anthropics/claude-plugins-official", "pin": null},
    "heimdall-marketplace": {"source": "randomittin/heimdall-marketplace", "pin": "v1.2.0"}
  },
  "entries": [
    {
      "id": "frontend-design",
      "kind": "plugin",
      "ref": "frontend-design@claude-plugins-official",
      "marketplace": "claude-plugins-official",
      "install": true,
      "tier": "recommended",
      "why": "UI/frontend work gets design guidance",
      "activate": {"permanent": false, "detect": ["frontend"]},
      "triggers": {
        "prompt_ere": "react|vue|angular|css|responsive|ui|frontend|component",
        "files": [{"path": "package.json", "contains_any": ["react", "vue", "angular", "svelte"]}],
        "order": 1
      },
      "legacy": [
        {"mechanism": "heimdall-skills.json", "path": "detection.frontend"},
        {"mechanism": "plugin-autoinstall.md", "path": "table row 1"},
        {"mechanism": "bin/heimdall:preinstall_plugins", "path": "rule 1"}
      ]
    },
    {
      "id": "devops-toolkit",
      "kind": "plugin",
      "ref": "devops-toolkit@claude-plugins-official",
      "marketplace": "claude-plugins-official",
      "install": true,
      "tier": "recommended",
      "why": "Docker, Kubernetes and CI/CD work gets devops tooling",
      "triggers": {
        "prompt_ere": "docker|k8s|kubernetes|deploy|ci.?cd|pipeline",
        "files": [{"path": "Dockerfile"}, {"path": "docker-compose.yml"}],
        "order": 2
      },
      "legacy": [{"mechanism": "bin/heimdall:preinstall_plugins", "path": "rule 2"}]
    },
    {
      "id": "design-for-ai",
      "kind": "plugin",
      "ref": "design-for-ai@rtd",
      "marketplace": "rtd",
      "install": false,
      "tier": "detected",
      "why": "Activation-only: paused unless the project has frontend files; hmd never installs it",
      "activate": {"permanent": false, "detect": ["frontend"]},
      "legacy": [{"mechanism": "heimdall-skills.json", "path": "detection.frontend"}]
    },
    {
      "id": "ui-ux-pro-max",
      "kind": "github-skill",
      "repo": "nextlevelbuilder/ui-ux-pro-max-skill",
      "install": true,
      "tier": "detected",
      "why": "Design prompts match its keywords",
      "keywords": ["ui", "ux", "landing page", "responsive"],
      "category": "design",
      "description": "Professional UI/UX design skill for React, Tailwind, and responsive frontends",
      "legacy": [{"mechanism": "skills-registry.json", "path": "skills[0]"}]
    },
    {
      "id": "heimdall",
      "kind": "bundled",
      "ref": "skills/heimdall",
      "install": false,
      "tier": "bundled",
      "why": "Ships in-tree with hmd; never installed",
      "legacy": [{"mechanism": "skills/", "path": "skills/heimdall/SKILL.md"}]
    },
    {
      "id": "community-demo",
      "kind": "plugin",
      "ref": "community-demo@heimdall-marketplace",
      "marketplace": "heimdall-marketplace",
      "install": false,
      "tier": "community",
      "why": "Reserved tier: never auto-suggested",
      "legacy": [{"mechanism": "test fixture", "path": "n/a"}]
    }
  ],
  "detection_rules": {
    "frontend": {
      "files": ["*.tsx", "*.jsx", "tailwind.config.*"],
      "entries": ["frontend-design", "design-for-ai"]
    }
  },
  "keyword_skills": ["ui-ux-pro-max"]
}
JSON

run_validator valid
if [ "$RC" -eq 0 ] && [ "$OUT" = "ok skills.manifest/1 (6 entries)" ]; then
  ok "A: the valid fixture is accepted ($OUT)"
else
  bad "A: the valid fixture was not accepted (rc=$RC): ${OUT:0:400}"
fi

# ── the case tables ─────────────────────────────────────────────────────────────────
# One line per case:  NAME @@ python that mutates the fixture @@ expected reason fragment
# `d` is the parsed fixture, `E` its entries by id. A case changes exactly one thing, and the same
# fixture is the base of all of them, so a rejection can only come from that one change.
cat > "$WORK/accepts.txt" <<'TABLE'
minimal-manifest @@ del d["detection_rules"]; del d["keyword_skills"]; del E["frontend-design"]["activate"]; del E["design-for-ai"]["activate"]
community-with-explicit-consent @@ E["community-demo"]["install"] = True; E["community-demo"]["explicit_consent"] = True
tier-bundled @@ E["design-for-ai"]["tier"] = "bundled"
tier-on_demand @@ E["design-for-ai"]["tier"] = "on_demand"
marketplace-without-pin @@ del d["marketplaces"]["claude-plugins-official"]["pin"]
github-skill-with-null-marketplace @@ E["ui-ux-pro-max"]["marketplace"] = None
empty-keyword-skills @@ d["keyword_skills"] = []
TABLE

cat > "$WORK/rejects.txt" <<'TABLE'
schema-version-2 @@ d["schema"] = 2 @@ schema must be the integer 1
schema-true @@ d["schema"] = True @@ schema must be the integer 1
schema-float @@ d["schema"] = 1.0 @@ schema must be the integer 1
top-level-extra-key @@ d["extra"] = 1 @@ unexpected property 'extra'
marketplaces-not-an-object @@ d["marketplaces"] = [] @@ marketplaces must be an object
marketplace-name-malformed @@ d["marketplaces"]["Bad Name"] = {"source": "a/b"} @@ name must match
marketplace-source-is-a-url @@ d["marketplaces"]["claude-plugins-official"]["source"] = "https://evil.example/x.git" @@ source must be <owner>/<repo>
marketplace-pin-looks-like-an-option @@ d["marketplaces"]["heimdall-marketplace"]["pin"] = "--flag" @@ pin must be null or
entries-empty @@ d["entries"] = [] @@ entries must be a non-empty array
entry-not-an-object @@ d["entries"].append("oops") @@ entries[6]: must be an object
entry-extra-key @@ E["frontend-design"]["tiers"] = "x" @@ unexpected property 'tiers'
tier-unknown @@ E["frontend-design"]["tier"] = "mandatory" @@ tier 'mandatory' is not one of
kind-unknown @@ E["heimdall"]["kind"] = "extension" @@ kind 'extension' is not one of
install-not-a-boolean @@ E["frontend-design"]["install"] = "yes" @@ install must be a boolean
why-multiline @@ E["frontend-design"]["why"] = "two\nlines" @@ why must be a non-empty single-line string
duplicate-id @@ E["devops-toolkit"]["id"] = "frontend-design" @@ duplicate entry id 'frontend-design'
legacy-empty @@ E["frontend-design"]["legacy"] = [] @@ legacy must be a non-empty array
legacy-missing @@ del E["design-for-ai"]["legacy"] @@ missing required property 'legacy'
legacy-pointer-incomplete @@ E["frontend-design"]["legacy"] = [{"mechanism": "heimdall-skills.json"}] @@ legacy[0]: missing required property 'path'
plugin-without-ref @@ del E["devops-toolkit"]["ref"] @@ plugin entries need 'ref'
plugin-marketplace-null @@ E["devops-toolkit"]["marketplace"] = None @@ marketplace must match
ref-names-another-marketplace @@ E["devops-toolkit"]["ref"] = "devops-toolkit@heimdall-marketplace" @@ names marketplace 'heimdall-marketplace' but marketplace is 'claude-plugins-official'
install-from-unlisted-marketplace @@ E["devops-toolkit"]["ref"] = "devops-toolkit@unlisted"; E["devops-toolkit"]["marketplace"] = "unlisted" @@ marketplace 'unlisted' is not listed in marketplaces
marketplace-on-a-bundled-entry @@ E["heimdall"]["marketplace"] = "claude-plugins-official" @@ marketplace must be null or absent unless kind is plugin
github-skill-without-repo @@ del E["ui-ux-pro-max"]["repo"] @@ github-skill entries need 'repo'
repo-is-not-owner-slash-repo @@ E["ui-ux-pro-max"]["repo"] = "--upload-pack=touch /tmp/x" @@ repo must be <owner>/<repo>
keywords-empty @@ E["ui-ux-pro-max"]["keywords"] = [] @@ keywords must be a non-empty array
community-install-without-consent @@ E["community-demo"]["install"] = True @@ community entries must have install:false or explicit_consent:true
explicit-consent-not-a-boolean @@ E["community-demo"]["explicit_consent"] = "yes" @@ explicit_consent must be a boolean
bundled-install @@ E["heimdall"]["install"] = True @@ bundled entries ship in-tree: install must be false
prompt-ere-does-not-compile @@ E["frontend-design"]["triggers"]["prompt_ere"] = "react|(" @@ triggers.prompt_ere does not compile
prompt-ere-matches-the-empty-string @@ E["frontend-design"]["triggers"]["prompt_ere"] = "react|" @@ matches the empty string
triggers-without-order @@ del E["frontend-design"]["triggers"]["order"] @@ triggers: missing required property 'order'
order-not-positive @@ E["frontend-design"]["triggers"]["order"] = 0 @@ triggers.order must be a positive integer
duplicate-order @@ E["devops-toolkit"]["triggers"]["order"] = 1 @@ duplicate triggers.order 1
file-trigger-path-escapes-up @@ E["frontend-design"]["triggers"]["files"][0]["path"] = "../secrets" @@ must be a relative path without '..'
file-trigger-path-is-absolute @@ E["frontend-design"]["triggers"]["files"][0]["path"] = "/etc/passwd" @@ must be a relative path without '..'
file-trigger-contains-any-empty @@ E["frontend-design"]["triggers"]["files"][0]["contains_any"] = [] @@ contains_any must be a non-empty array
activate-without-detect @@ del E["frontend-design"]["activate"]["detect"] @@ activate: missing required property 'detect'
activate-unknown-rule @@ E["frontend-design"]["activate"]["detect"] = ["ghost-rule"] @@ activate.detect names unknown detection rule 'ghost-rule'
detection-rule-without-files @@ d["detection_rules"]["frontend"]["files"] = [] @@ files must be a non-empty array
detection-rule-unknown-entry @@ d["detection_rules"]["frontend"]["entries"].append("ghost") @@ entries names unknown entry id 'ghost'
keyword-skill-is-not-a-github-skill @@ d["keyword_skills"] = ["frontend-design"] @@ is not a github-skill entry id
keyword-skills-not-an-array @@ d["keyword_skills"] = "ui-ux-pro-max" @@ keyword_skills must be an array of github-skill entry ids
detection-rule-path-escapes-up @@ d["detection_rules"]["frontend"]["files"] = ["../*.tsx"] @@ files must be a non-empty array of relative globs without '..'
detection-rule-entries-empty @@ d["detection_rules"]["frontend"]["entries"] = [] @@ entries must be a non-empty array of entry ids
detection-rule-name-malformed @@ d["detection_rules"]["Bad Rule"] = {"files": ["*.x"], "entries": ["frontend-design"]} @@ name must match
detection-rules-not-an-object @@ d["detection_rules"] = [] @@ detection_rules must be an object
activate-not-an-object @@ E["frontend-design"]["activate"] = "yes" @@ activate must be an object
activate-permanent-not-a-boolean @@ E["frontend-design"]["activate"]["permanent"] = "no" @@ activate.permanent must be a boolean
activate-detect-not-an-array @@ E["frontend-design"]["activate"]["detect"] = "frontend" @@ activate.detect must be an array of detection rule names
triggers-not-an-object @@ E["frontend-design"]["triggers"] = [] @@ triggers must be an object
triggers-files-not-an-array @@ E["frontend-design"]["triggers"]["files"] = "package.json" @@ triggers.files must be an array
file-trigger-not-an-object @@ E["frontend-design"]["triggers"]["files"][0] = "package.json" @@ triggers.files[0] must be an object
file-trigger-without-path @@ del E["frontend-design"]["triggers"]["files"][0]["path"] @@ triggers.files[0]: missing required property 'path'
prompt-ere-empty @@ E["frontend-design"]["triggers"]["prompt_ere"] = "" @@ triggers.prompt_ere must be a non-empty string
plugin-ref-without-marketplace @@ E["devops-toolkit"]["ref"] = "devops-toolkit" @@ ref must be <plugin>@<marketplace>
bundled-ref-blank @@ E["heimdall"]["ref"] = "" @@ ref must be a non-empty single-line string
id-malformed @@ E["devops-toolkit"]["id"] = "Bad_ID" @@ id must match
github-skill-without-category @@ del E["ui-ux-pro-max"]["category"] @@ github-skill entries need 'category'
category-blank @@ E["ui-ux-pro-max"]["category"] = " " @@ category must be a non-empty single-line string
description-blank @@ E["ui-ux-pro-max"]["description"] = "" @@ description must be a non-empty single-line string
legacy-not-an-array @@ E["frontend-design"]["legacy"] = {"mechanism": "x", "path": "y"} @@ legacy must be a non-empty array
legacy-item-not-an-object @@ E["frontend-design"]["legacy"] = ["x"] @@ legacy[0] must be an object
legacy-mechanism-blank @@ E["frontend-design"]["legacy"][0]["mechanism"] = "" @@ legacy[0].mechanism must be a non-empty single-line string
marketplace-spec-not-an-object @@ d["marketplaces"]["rtd"] = "x" @@ marketplaces.'rtd': must be an object
marketplace-without-source @@ del d["marketplaces"]["claude-plugins-official"]["source"] @@ missing required property 'source'
TABLE

cat > "$WORK/driver.py" <<'PYEOF'
import copy
import json
import sys

work = sys.argv[1]
with open(work + "/valid.json") as handle:
    valid = json.load(handle)
for table in ("accepts", "rejects"):
    with open("%s/%s.txt" % (work, table)) as lines:
        for line in lines:
            line = line.rstrip("\n")
            if not line:
                continue
            name, code = line.split(" @@ ")[:2]
            d = copy.deepcopy(valid)
            E = {entry["id"]: entry for entry in d["entries"]}
            exec(code)
            with open("%s/%s.json" % (work, name), "w") as out:
                json.dump(d, out)
PYEOF
if "$PY" -I "$WORK/driver.py" "$WORK"; then
  ok "fixtures: every case of the tables built from the one valid fixture"
else
  bad "fixtures: could not build the cases from the tables"
fi

# ── B. still valid ──────────────────────────────────────────────────────────────────
while IFS= read -r line; do
  [ -n "$line" ] || continue
  accept "${line%% @@ *}"
done < "$WORK/accepts.txt"

# ── C. one rule, one corrupted copy ─────────────────────────────────────────────────
while IFS= read -r line; do
  [ -n "$line" ] || continue
  reject "${line%% @@ *}" "${line##* @@ }"
done < "$WORK/rejects.txt"

# ── D. malformed input fails closed ─────────────────────────────────────────────────
printf '{"schema": 1, "entries": [' > "$WORK/not-json.json"
printf '[]' > "$WORK/top-level-array.json"
"$PY" -I -c 'import sys; sys.stdout.write("[" * 100000)' > "$WORK/over-nested.json"
"$PY" -I -c 'import sys; sys.stdout.write("[" + " " * 1048577 + "]")' > "$WORK/oversized.json"
"$PY" -I -c '
import sys
text = open(sys.argv[1]).read()
doubled = text.replace("\"schema\": 1,", "\"schema\": 1, \"schema\": 1,", 1)
assert doubled != text
open(sys.argv[2], "w").write(doubled)
' "$WORK/valid.json" "$WORK/duplicate-key.json"
reject does-not-exist "cannot read"
reject not-json "not valid JSON"
reject top-level-array "top level must be a JSON object"
reject over-nested "not valid JSON"
reject oversized "is larger than 1048576 bytes"
reject duplicate-key "duplicate key 'schema'"

# ── E. usage errors ─────────────────────────────────────────────────────────────────
OUT="$("$PY" -I "$VALIDATOR" 2>&1)"; RC=$?
if [ "$RC" -eq 2 ] && [[ "$OUT" == usage:* ]]; then ok "E: no arguments -> usage, exit 2"; else bad "E: no arguments (rc=$RC): ${OUT:0:200}"; fi
OUT="$("$PY" -I "$VALIDATOR" validate 2>&1)"; RC=$?
if [ "$RC" -eq 2 ] && [[ "$OUT" == usage:* ]]; then ok "E: validate without a file -> usage, exit 2"; else bad "E: validate without a file (rc=$RC): ${OUT:0:200}"; fi
OUT="$("$PY" -I "$VALIDATOR" lint "$WORK/valid.json" 2>&1)"; RC=$?
if [ "$RC" -eq 2 ] && [[ "$OUT" == usage:* ]]; then ok "E: an unknown subcommand -> usage, exit 2"; else bad "E: unknown subcommand (rc=$RC): ${OUT:0:200}"; fi

# ── F. the schema file and the validator are one contract ───────────────────────────
if grep -q '"schema"' "$SCHEMA" 2>/dev/null; then
  ok "F: docs/schemas/skills.manifest.v1.json exists and declares \"schema\""
else
  bad "F: docs/schemas/skills.manifest.v1.json is missing or does not declare \"schema\""
fi
cat > "$WORK/drift.py" <<'PYEOF'
import json
import re
import sys

sys.path.insert(0, sys.argv[1])
import skills_manifest as m


def patterns(node):
    if isinstance(node, dict):
        if isinstance(node.get("pattern"), str):
            yield node["pattern"]
        for value in node.values():
            yield from patterns(value)
    elif isinstance(node, list):
        for value in node:
            yield from patterns(value)


with open(sys.argv[2]) as handle:
    schema = json.load(handle)
defs = schema["$defs"]
entry = defs["entry"]
pairs = [
    ("the schema version", schema["properties"]["schema"]["const"], m.SCHEMA_VERSION),
    ("the kinds", entry["properties"]["kind"]["enum"], list(m.KINDS)),
    ("the tiers", entry["properties"]["tier"]["enum"], list(m.TIERS)),
    ("the id pattern", defs["id"]["pattern"], "^" + m.ID_PATTERN + "$"),
    ("the plugin ref pattern", defs["pluginRef"]["pattern"], "^" + m.PLUGIN_REF_PATTERN + "$"),
    ("the owner/repo pattern", defs["ownerRepo"]["pattern"], "^" + m.OWNER_REPO_PATTERN + "$"),
    ("the pin pattern", defs["pin"]["pattern"], "^" + m.PIN_PATTERN + "$"),
    ("the top-level keys", sorted(schema["properties"]), sorted(m.TOP_REQUIRED + m.TOP_OPTIONAL)),
    ("the required top-level keys", sorted(schema["required"]), sorted(m.TOP_REQUIRED)),
    ("the entry keys", sorted(entry["properties"]), sorted(m.ENTRY_REQUIRED + m.ENTRY_OPTIONAL)),
    ("the required entry keys", sorted(entry["required"]), sorted(m.ENTRY_REQUIRED)),
    ("rejecting unknown top-level keys", schema.get("additionalProperties"), False),
    ("rejecting unknown entry keys", entry.get("additionalProperties"), False),
]
for what, in_file, in_code in pairs:
    if in_file == in_code:
        print("ok\tthe schema file and the validator agree on " + what)
    else:
        print("bad\t%s differ: the schema file says %r, the validator says %r" % (what, in_file, in_code))
broken = []
for pattern in patterns(schema):
    try:
        re.compile(pattern)
    except re.error as exc:
        broken.append("%r (%s)" % (pattern, exc))
if broken:
    print("bad\tthe schema holds a pattern that does not compile: " + "; ".join(broken))
else:
    print("ok\tevery pattern in the schema file compiles")
PYEOF
DRIFT="$("$PY" -I -B "$WORK/drift.py" "$REPO/bin/lib" "$SCHEMA" 2>&1)"; RC=$?
if [ "$RC" -ne 0 ]; then
  bad "F: the schema file could not be compared with the validator (rc=$RC): ${DRIFT:0:400}"
else
  while IFS=$'\t' read -r verdict what; do
    if [ "$verdict" = ok ]; then ok "F: $what"; else bad "F: $what"; fi
  done <<<"$DRIFT"
fi

echo "--------------------------------------------------------------------"
printf 'skills-manifest-schema: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
