#!/usr/bin/env bash
# test/skills-cli-read.test.sh -- bin/lib/skills_cli_read.py, the read side of `hmd skills` (3.x M1 plan, task T4.1).
#
#   hmd skills list [--json]    every manifest entry with its tier, whether it is installed here, its source and pin, and
#                               what the locks say (consent, state); the registry and consent modes on top
#   hmd skills why ID           the lock row's why, the manifest's legacy[] pointers and the install receipt lines; exit 1
#                               when ID is installed and no lock row explains it (the goal metric: 100% explained)
#   hmd skills lock [--verify]  adopt what is installed and nothing explains (state adopted, consent auto-legacy, rule
#                               adopted) and refresh a row whose version or commit moved; --verify reports exactly that
#                               and writes nothing
#
# THE CONTRACT UNDER TEST
#   A  list: text and --json; installed from `claude plugins list --json` and ~/.claude/skills; both locks merged; the
#      registry/consent modes; claude unavailable; the real manifest; the project defaults to the working directory
#   B  lock: adoption (rows, receipts, commit hash, machine scope only, mode 0600), idempotence, a row elsewhere explains
#   C  why: every row of a seeded lock resolves (100%), legacy[] and receipts are shown, exit 1 for an unexplained install,
#      4 for an unknown id, terminal escapes are stripped; after `lock` every install is explained
#   D  lock --verify names drift (plugin version, skill commit, both scopes) and unlocked installs and writes nothing; the
#      write mode then makes the verify pass
#   E  fail closed: corrupt or linked locks, an invalid manifest, bad usage: the right exit code, a reason, no traceback
#   F  the suite can go RED: five one-line breaks of the module are each caught by the check that guards them
#
# HERMETIC. HOME and HEIMDALL_HOME are throwaway directories; `claude` is a fake that can only answer `plugins list --json`
# (any other call exits 9 and is logged, so an install attempt would show); skill checkouts are local git repositories;
# no network. EXIT: 0 = every assertion passes; 1 = any FAIL.
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$REPO/bin/lib/skills_cli_read.py"
LOCKLIB="$REPO/bin/lib/skills_lock.py"
MANLIB="$REPO/bin/lib/skills_manifest.py"

PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); printf '  \033[32mPASS\033[0m %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  \033[31mFAIL\033[0m %s\n' "$1"; if [ -n "${2:-}" ]; then printf '       %s\n' "$2"; fi; }
t()   { if [ "$?" -eq 0 ]; then ok "$1"; else bad "$1" "${2:-}"; fi; }   # the verdict of the command just before it

echo "skills-cli-read"

command -v python3 >/dev/null 2>&1 || { echo "FATAL: python3 is required"; exit 1; }
command -v git >/dev/null 2>&1 || { echo "FATAL: git is required"; exit 1; }
if [ ! -f "$LIB" ]; then
  bad "0. bin/lib/skills_cli_read.py is missing"
  echo; echo "skills-cli-read: $PASS passed, $FAIL failed"
  exit 1
fi

# ── sandbox ──────────────────────────────────────────────────────────────────────────────────────────────────────
TMP="$(mktemp -d /tmp/test-skills-cli-read-XXXXXX)" || exit 1
trap 'chmod -R u+rwx "$TMP" 2>/dev/null; rm -rf "$TMP"' EXIT

# The REAL interpreter first on PATH (a version-manager shim costs ~0.4 s a call), then the fake claude.
REALPY="$(python3 -I -c 'import sys; print(sys.executable)' 2>/dev/null)"
if [ -z "$REALPY" ] || [ ! -x "$REALPY" ]; then echo "FATAL: no usable python3"; exit 1; fi
mkdir -p "$TMP/bin" "$TMP/mut"
ln -s "$REALPY" "$TMP/bin/python3"
cat >"$TMP/bin/claude" <<'SH'
#!/bin/sh
# fake claude: records its argv; answers `plugins list --json` from $FAKE_PLUGINS; nothing else is ever allowed
printf '%s\n' "$*" >>"$FAKE_LOG"
if [ "$1 $2 $3" = "plugins list --json" ]; then
  [ -z "${FAKE_CLAUDE_FAIL:-}" ] || { echo "claude: broken" >&2; exit 7; }
  cat "$FAKE_PLUGINS"
  exit 0
fi
exit 9
SH
chmod +x "$TMP/bin/claude"
PATH="$TMP/bin:$PATH"; export PATH

# A user's git configuration (templates, hooks, signing) must not reach the skill checkouts below.
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 GIT_TERMINAL_PROMPT=0
unset HMD_RUN_ID HMD_SKILLS_REGISTRY HMD_SKILLS_CONSENT HMD_SKILLS_LOCK_WAIT_S HMD_RECEIPTS_DIR FAKE_CLAUDE_FAIL CLI_LIB WORK_DIR

# ── fixtures and helpers ─────────────────────────────────────────────────────────────────────────────────────────
MANIFEST="$TMP/skills.manifest.json"
cat >"$MANIFEST" <<'JSON'
{
  "schema": 1,
  "marketplaces": {"claude-plugins-official": {"source": "anthropics/claude-plugins-official", "pin": null}},
  "entries": [
    {"id": "superpowers", "kind": "plugin", "ref": "superpowers@claude-plugins-official", "marketplace": "claude-plugins-official",
     "install": true, "tier": "recommended", "why": "Core workflow skills",
     "legacy": [{"mechanism": "heimdall-skills.json", "path": "permanent"}, {"mechanism": "bin/heimdall:first_run_setup", "path": "install superpowers"}]},
    {"id": "frontend-design", "kind": "plugin", "ref": "frontend-design@claude-plugins-official", "marketplace": "claude-plugins-official",
     "install": true, "tier": "recommended", "why": "UI and frontend work gets design guidance",
     "triggers": {"prompt_ere": "react|css", "order": 1},
     "legacy": [{"mechanism": "bin/heimdall:preinstall_plugins", "path": "prompt rule 1"}]},
    {"id": "seo", "kind": "plugin", "ref": "seo@claude-plugins-official", "marketplace": "claude-plugins-official",
     "install": true, "tier": "recommended", "why": "SEO work gets SEO tooling",
     "triggers": {"prompt_ere": "seo|sitemap", "order": 2},
     "legacy": [{"mechanism": "bin/heimdall:preinstall_plugins", "path": "prompt rule 4"}]},
    {"id": "ui-ux-pro-max", "kind": "github-skill", "repo": "nextlevelbuilder/ui-ux-pro-max-skill", "install": true, "tier": "detected",
     "why": "Offered when a prompt matches its design keywords", "keywords": ["ui", "ux"], "category": "design",
     "description": "Professional UI/UX design skill",
     "legacy": [{"mechanism": "skills-registry.json", "path": "skills[0]"}]},
    {"id": "heimdall", "kind": "bundled", "ref": "skills/heimdall", "install": false, "tier": "bundled",
     "why": "The orchestrator skill; ships in-tree with hmd and is never installed",
     "legacy": [{"mechanism": "skills/", "path": "skills/heimdall/SKILL.md"}]}
  ]
}
JSON
printf '{"schema": 2}\n' >"$TMP/invalid.manifest.json"
PM="claude-plugins-official"
SP="superpowers@$PM"; FD="frontend-design@$PM"

RC=0; OUT=""; ERR=""
cli() {  # cli ARGS... -> RC, OUT, ERR; the module is $CLI_LIB (a broken copy in section F), else the real one
  OUT="$(python3 -I "${CLI_LIB:-$LIB}" "$@" 2>"$TMP/stderr" </dev/null)"; RC=$?
  ERR="$(cat "$TMP/stderr")"
  return "$RC"
}
contains() { grep -qF -- "$2" <<<"$1"; }
# j EXPR -> EXPR evaluated with d = the JSON in $OUT and e = its entries by id. EXPR is always a literal written in THIS
# file, which is why eval is safe here: it is the shortest way to ask a document one question per assertion.
j()     { printf '%s' "$OUT" | python3 -I -c 'import json, sys
d = json.load(sys.stdin)
e = {x["id"]: x for x in d.get("entries", [])}
print(eval(sys.argv[1]))' "$1"; }
lockj() { python3 -I -c 'import json, sys
d = json.load(open(sys.argv[1]))
def row(i): return next(r for r in d["entries"] if r["id"] == i)
print(eval(sys.argv[2]))' "$1" "$2"; }   # lockj FILE EXPR: d = the lock, row(id) = one of its rows
lockids() { python3 -I -c 'import json, sys
print(" ".join(r["id"] for p in sys.argv[1:] for r in json.load(open(p))["entries"]))' "$@"; }   # every id of the given locks
sha()    { python3 -I -c 'import hashlib, sys; print(hashlib.sha256(open(sys.argv[1], "rb").read()).hexdigest())' "$1"; }
modeof() { python3 -I -c 'import os, sys; print(oct(os.stat(sys.argv[1]).st_mode & 0o777)[2:])' "$1"; }
field()  { awk -v id="$1" -v n="$2" '$1 == id { print $n; exit }' <<<"$OUT"; }   # column N of the table row of ID
check()  { [ "$(j "$1")" = "$2" ]; }
lockcheck() { [ "$(lockj "$1" "$2")" = "$3" ]; }

fresh() {  # fresh NAME: a clean HOME, HEIMDALL_HOME, project, fake claude and call log
  local d="$TMP/env.$1"
  rm -rf "$d"; mkdir -p "$d/home/.claude/skills" "$d/proj"
  HOME="$d/home"; HEIMDALL_HOME="$d/home/.heimdall"; PROJ="$d/proj"
  FAKE_PLUGINS="$d/plugins.json"; FAKE_LOG="$d/claude.log"
  export HOME HEIMDALL_HOME FAKE_PLUGINS FAKE_LOG
  : >"$FAKE_LOG"; printf '[]\n' >"$FAKE_PLUGINS"
  MLOCK="$HEIMDALL_HOME/skills.lock"; PLOCK="$PROJ/.planning/skills.lock"
}
plugins() {  # plugins ID=VERSION...: what the fake `claude plugins list --json` prints
  python3 -I -c 'import json, sys
json.dump([{"id": a.split("=")[0], "version": a.split("=")[1], "scope": "user", "enabled": True} for a in sys.argv[2:]],
          open(sys.argv[1], "w"), indent=2)' "$FAKE_PLUGINS" "$@"
}
gitc() { local dir="$1"; shift; git -C "$dir" -c user.name=t -c user.email=t@example.invalid -c commit.gpgsign=false "$@"; }
mkskill() {  # mkskill NAME [git]: a skill directory; `git` makes it a one-commit checkout
  local dir="$HOME/.claude/skills/$1"
  mkdir -p "$dir"; printf '# %s\n' "$1" >"$dir/SKILL.md"
  if [ "${2:-}" = git ]; then git -C "$dir" init -q && git -C "$dir" add SKILL.md && gitc "$dir" commit -q -m one; fi
}
commit2() {  # commit2 NAME: move the checkout to a new commit
  local dir="$HOME/.claude/skills/$1"
  printf 'two\n' >>"$dir/SKILL.md"; git -C "$dir" add SKILL.md && gitc "$dir" commit -q -m two
}
headsha() { git -C "$HOME/.claude/skills/$1" rev-parse HEAD; }
lockrec() {  # lockrec ARGS...: seed a lock through the lock library's own CLI
  python3 -I "$LOCKLIB" record "$@" >/dev/null 2>"$TMP/lockrec.err" || bad "seed: skills_lock.py record $*" "$(cat "$TMP/lockrec.err")"
}
seed_project_fd() {  # seed_project_fd [VERSION]: the project says frontend-design was installed by a prompt rule
  lockrec --scope project --project-dir "$PROJ" --id frontend-design --state installed --kind plugin --ref "$FD" \
    --version "${1:-5.0.7}" --source anthropics/claude-plugins-official --consent prompt --rule prompt_ere --evidence react \
    --via prompt-preinstall --run run-1 --manifest "$MANIFEST"
}
seed_receipts() {
  mkdir -p "$HEIMDALL_HOME/receipts"
  cat >"$HEIMDALL_HOME/receipts/installs-run-9.ndjson" <<'EOF'
{"ts":"2026-11-12T09:00:00Z","run":"run-9","kind":"plugin","name":"frontend-design@claude-plugins-official","version":"5.0.7","source":"anthropics/claude-plugins-official","pin":"none","result":"ok","via":"prompt-preinstall"}
{"ts":"2026-11-12T09:00:01Z","run":"run-9","kind":"plugin","name":"seo@claude-plugins-official","version":"unknown","source":"anthropics/claude-plugins-official","pin":"none","result":"failed","via":"prompt-preinstall","detail":"boom","note":"install failed, continuing without seo@claude-plugins-official"}
{"ts":"2026-11-12T09:00:02Z","run":"run-9","kind":"skill","name":"ui-ux-pro-max","version":"abcdef123456","source":"github.com/nextlevelbuilder/ui-ux-pro-max-skill","pin":"none","result":"ok","via":"discover_skills"}
this line is not json
EOF
}
only_reads() {  # the fake claude log holds nothing but `plugins list --json`: nothing here ever installs or changes anything
  [ -z "$(grep -vx 'plugins list --json' "$FAKE_LOG")" ]
}

python3 -I "$MANLIB" validate "$MANIFEST" >/dev/null 2>"$TMP/stderr"
t "0. the fixture manifest is a valid skills.manifest/1" "$(cat "$TMP/stderr")"

# ── A. list ──────────────────────────────────────────────────────────────────────────────────────────────────────
echo "A. list"
fresh a
plugins "$SP=5.0.7" "$FD=5.0.7" "thirdparty@somemkt=1.0.0"
mkskill ui-ux-pro-max git
seed_project_fd
lockrec --scope machine --id superpowers --state adopted --kind plugin --ref "$SP" --version 5.0.7 \
  --source anthropics/claude-plugins-official --consent auto-legacy --rule adopted --via hmd-skills-lock --run run-1 --manifest "$MANIFEST"
LOCK_M="$(sha "$MLOCK")"; LOCK_P="$(sha "$PLOCK")"
cli list --json --project-dir "$PROJ" --manifest "$MANIFEST"
[ "$RC" -eq 0 ]; t "A1. list --json exits 0" "rc=$RC err=$ERR"
check '[x["id"] for x in d["entries"]]' "['superpowers', 'frontend-design', 'seo', 'ui-ux-pro-max', 'heimdall']"
t "A2. one entry per manifest entry, in manifest order" "$OUT"
check '(d["registry"], d["consent"])' "('off', 'ask')"; t "A3. the registry and consent modes are flagged (defaults off, ask)"
check '[e[i]["installed"] for i in e]' "[True, True, False, True, None]"
t "A4. installed comes from claude plugins list and ~/.claude/skills; a bundled entry is null (ships in-tree)"
check '(e["frontend-design"]["tier"], e["frontend-design"]["source"], e["frontend-design"]["pin"], e["frontend-design"]["ref"])' \
  "('recommended', 'anthropics/claude-plugins-official', 'none', 'frontend-design@claude-plugins-official')"
t "A5. tier, source, pin and ref are the manifest's"
check '(e["frontend-design"]["consent"], e["frontend-design"]["lock_state"], e["frontend-design"]["lock_scope"])' "('prompt', 'installed', 'project')"
t "A6. the project lock row shows as consent and lock state"
check '(e["superpowers"]["consent"], e["superpowers"]["lock_state"], e["superpowers"]["lock_scope"])' "('auto-legacy', 'adopted', 'machine')"
t "A7. the machine lock row shows too (both locks are merged)"
check '(e["seo"]["consent"], e["seo"]["lock_state"], e["seo"]["lock_scope"])' "(None, None, None)"; t "A8. an entry no lock mentions has no consent and no lock state"
check '(e["ui-ux-pro-max"]["kind"], e["ui-ux-pro-max"]["source"], e["ui-ux-pro-max"]["ref"], e["heimdall"]["source"])' \
  "('github-skill', 'github.com/nextlevelbuilder/ui-ux-pro-max-skill', 'nextlevelbuilder/ui-ux-pro-max-skill', 'bundled')"
t "A9. a github skill's source is github.com/<repo>; a bundled entry's is bundled"
cli list --project-dir "$PROJ" --manifest "$MANIFEST"
[ "$RC" -eq 0 ] && grep -qx 'registry: off  consent: ask' <<<"$OUT"; t "A10. the text table opens with the modes" "$OUT"
[ "$(field frontend-design 4)/$(field frontend-design 7)/$(field frontend-design 8)/$(field seo 4)/$(field heimdall 4)" = "yes/prompt/installed(project)/no/n/a" ]
t "A11. text columns: installed, consent, lock(scope); no for a missing entry, n/a for a bundled one" "$OUT"
HMD_SKILLS_REGISTRY=on HMD_SKILLS_CONSENT=allowlist cli list --json --project-dir "$PROJ" --manifest "$MANIFEST"
check '(d["registry"], d["consent"])' "('on', 'allowlist')"; t "A12. the modes follow the environment, as the launcher reads them"
[ "$(sha "$MLOCK")" = "$LOCK_M" ] && [ "$(sha "$PLOCK")" = "$LOCK_P" ] && only_reads
t "A13. list never writes a lock and never calls claude for anything but plugins list --json" "$(cat "$FAKE_LOG")"
FAKE_CLAUDE_FAIL=1 cli list --json --project-dir "$PROJ" --manifest "$MANIFEST"
[ "$RC" -eq 0 ] && check '(e["superpowers"]["installed"], e["ui-ux-pro-max"]["installed"])' "(None, True)" && contains "$ERR" "plugins list"
t "A14. claude failing: list still answers, plugin presence is unknown (null), skills still checked, one reason on stderr" "rc=$RC err=$ERR"
cd "$PROJ" || exit 1
cli list --json --manifest "$MANIFEST"
cd "$REPO" || exit 1
check 'e["frontend-design"]["lock_state"]' installed; t "A15. the project defaults to the working directory"
cli list --json --project-dir "$PROJ"
[ "$RC" -eq 0 ] && check 'len(d["entries"])' "$(python3 -I -c 'import json, sys; print(len(json.load(open(sys.argv[1]))["entries"]))' "$REPO/skills.manifest.json")"
t "A16. the manifest defaults to the repo's own skills.manifest.json" "rc=$RC err=$ERR"

# ── B. lock: adoption ────────────────────────────────────────────────────────────────────────────────────────────
echo "B. lock"
fresh b
plugins "$SP=5.0.7" "$FD=5.0.7" "thirdparty@somemkt=1.0.0"
mkskill ui-ux-pro-max git; mkskill my-own-skill
seed_receipts
cli lock --project-dir "$PROJ" --manifest "$MANIFEST"
[ "$RC" -eq 0 ]; t "B1. lock exits 0" "rc=$RC err=$ERR"
N=0; for id in superpowers frontend-design thirdparty ui-ux-pro-max my-own-skill; do contains "$OUT" "adopted $id" && N=$((N + 1)); done
[ "$N" -eq 5 ]; t "B2. it says it adopted each of the five installs" "$OUT"
python3 -I "$LOCKLIB" verify --scope machine >/dev/null 2>"$TMP/stderr"; t "B3. the machine lock it wrote is a valid skills.lock/1" "$(cat "$TMP/stderr")"
lockcheck "$MLOCK" 'sorted(r["id"] for r in d["entries"])' "['frontend-design', 'my-own-skill', 'superpowers', 'thirdparty', 'ui-ux-pro-max']"
t "B4. one row per install; nothing for an entry that is not installed (seo) or ships in-tree (heimdall)"
lockcheck "$MLOCK" '(row("superpowers")["kind"], row("superpowers")["state"], row("superpowers")["consent"], row("superpowers")["why"]["rule"], row("superpowers")["why"]["entry"])' \
  "('plugin', 'adopted', 'auto-legacy', 'adopted', 'superpowers')"; t "B5. a pre-existing plugin is state adopted, consent auto-legacy, why.rule adopted"
lockcheck "$MLOCK" '(row("superpowers")["version"], row("superpowers")["source"], row("superpowers")["pin"], row("superpowers")["content_hash"], row("superpowers")["why"]["via"])' \
  "('5.0.7', 'anthropics/claude-plugins-official', 'none', None, 'hmd-skills-lock')"; t "B6. version from the CLI, source and pin from the manifest's marketplace, no hash for a plugin"
lockcheck "$MLOCK" 'row("frontend-design")["why"]["via"]' prompt-preinstall; t "B7. the install receipt supplies how it was installed (via)"
lockcheck "$MLOCK" '(row("thirdparty")["ref"], row("thirdparty")["source"], row("thirdparty")["why"]["entry"])' "('thirdparty@somemkt', 'somemkt', 'thirdparty')"
t "B8. a plugin outside the manifest is adopted too, with its marketplace as source"
SHA="$(headsha ui-ux-pro-max)"
lockcheck "$MLOCK" '(row("ui-ux-pro-max")["kind"], row("ui-ux-pro-max")["content_hash"], row("ui-ux-pro-max")["version"], row("ui-ux-pro-max")["source"], row("ui-ux-pro-max")["why"]["via"])' \
  "('github-skill', '$SHA', '${SHA:0:12}', 'github.com/nextlevelbuilder/ui-ux-pro-max-skill', 'discover_skills')"
t "B9. a skill checkout is recorded at its git commit (hash, 12-char version), source from the manifest, via from its receipt"
lockcheck "$MLOCK" '(row("my-own-skill")["kind"], row("my-own-skill")["version"], row("my-own-skill")["content_hash"], row("my-own-skill")["source"])' \
  "('github-skill', 'unknown', None, 'unknown')"; t "B10. a skill directory that is not a git checkout is adopted with version unknown and no hash"
lockcheck "$MLOCK" 'd["manifest_sha256"]' "$(sha "$MANIFEST")"; t "B11. the lock is written against the manifest that was read"
[ "$(modeof "$MLOCK")" = 600 ] && [ ! -e "$PLOCK" ]; t "B12. the machine lock is 0600 and no project lock was created (the project does not need every plugin on the machine)"
only_reads; t "B13. lock only ever ran claude plugins list --json" "$(cat "$FAKE_LOG")"
BEFORE="$(sha "$MLOCK")"
cli lock --project-dir "$PROJ" --manifest "$MANIFEST"
[ "$RC" -eq 0 ] && [ "$(sha "$MLOCK")" = "$BEFORE" ] && contains "$OUT" "nothing to do"; t "B14. a second run changes nothing: same bytes, says so" "$OUT"
fresh b2
plugins "$FD=5.0.7"
seed_project_fd
cli lock --project-dir "$PROJ" --manifest "$MANIFEST"
[ "$RC" -eq 0 ] && [ ! -e "$MLOCK" ] && contains "$OUT" "nothing to do"; t "B15. an install the project lock already explains is not adopted a second time" "rc=$RC out=$OUT err=$ERR"
fresh b3
plugins "dup@a=1.0.0" "dup@b=2.0.0" "bad name@a=1.0.0"
cli lock --project-dir "$PROJ" --manifest "$MANIFEST"
[ "$RC" -eq 0 ] && lockcheck "$MLOCK" 'sorted(r["id"] for r in d["entries"])' "['dup@a', 'dup@b']" && contains "$ERR" "cannot be recorded"
t "B16. two plugins with one name are recorded under their full names; an id a lock cannot hold is skipped with a reason, not fatally" "rc=$RC out=$OUT err=$ERR"

# ── C. why ───────────────────────────────────────────────────────────────────────────────────────────────────────
echo "C. why"
fresh c
plugins "$SP=5.0.7" "$FD=5.0.7" "thirdparty@somemkt=1.0.0"
mkskill my-own-skill
seed_receipts
seed_project_fd
lockrec --scope project --project-dir "$PROJ" --id seo --state suggested --kind plugin --ref "seo@$PM" --rule prompt_ere --evidence seo --via prompt-suggest --manifest "$MANIFEST"
lockrec --scope machine --id superpowers --state installed --kind plugin --ref "$SP" --version 5.0.7 --consent auto-legacy --rule first-run --via first-run --manifest "$MANIFEST"
lockrec --scope machine --id "$PM" --state installed --kind marketplace --source anthropics/claude-plugins-official --rule first-run --via first-run --manifest "$MANIFEST"
TOTAL=0; EXPLAINED=0
for id in $(lockids "$PLOCK" "$MLOCK"); do
  TOTAL=$((TOTAL + 1))
  cli why "$id" --project-dir "$PROJ" --manifest "$MANIFEST"
  if [ "$RC" -eq 0 ] && contains "$OUT" "lock[" && contains "$OUT" "rule="; then EXPLAINED=$((EXPLAINED + 1)); fi
done
[ "$TOTAL" -eq 4 ] && [ "$EXPLAINED" -eq "$TOTAL" ]; t "C1. why resolves 100% of the rows in a seeded lock ($EXPLAINED of $TOTAL; a plugin, a suggestion, two machine rows, one a marketplace)"
cli why frontend-design --project-dir "$PROJ" --manifest "$MANIFEST"
[ "$RC" -eq 0 ] && contains "$OUT" "lock[project]: state=installed consent=prompt" && contains "$OUT" "rule=prompt_ere evidence=react via=prompt-preinstall run=run-1"
t "C2. the lock row's why: state, consent, rule, evidence, via, run" "$OUT"
contains "$OUT" "legacy: bin/heimdall:preinstall_plugins (prompt rule 1)"; t "C3. the manifest entry's legacy[] pointers are shown" "$OUT"
contains "$OUT" "receipt: installs-run-9.ndjson 2026-11-12T09:00:00Z plugin frontend-design@claude-plugins-official ok via=prompt-preinstall"
t "C4. and the install receipt lines for it (a malformed receipt line is skipped)" "$OUT"
cli why "$PM" --project-dir "$PROJ" --manifest "$MANIFEST"
[ "$RC" -eq 0 ] && contains "$OUT" "marketplace $PM" && contains "$OUT" "source=anthropics/claude-plugins-official"; t "C5. a marketplace row is explained from the manifest's marketplaces table" "$OUT"
cli why "$SP" --project-dir "$PROJ" --manifest "$MANIFEST"
[ "$RC" -eq 0 ] && contains "$OUT" "lock[machine]: state=installed"; t "C6. a plugin can be asked for by its full ref" "$OUT"
for id in thirdparty "thirdparty@somemkt" my-own-skill; do
  cli why "$id" --project-dir "$PROJ" --manifest "$MANIFEST"
  [ "$RC" -eq 1 ] && contains "$ERR" "hmd skills lock"; t "C7. why $id: installed here, no lock row => exit 1, and it says how to fix it" "rc=$RC err=$ERR"
done
cli why ui-ux-pro-max --project-dir "$PROJ" --manifest "$MANIFEST"
[ "$RC" -eq 0 ] && contains "$OUT" "no lock row" && contains "$OUT" "not installed" && contains "$OUT" "legacy: skills-registry.json (skills[0])"
t "C8. a manifest entry that is not installed and has no row is not an error: exit 0, with the manifest's account" "rc=$RC out=$OUT"
cli why heimdall --project-dir "$PROJ" --manifest "$MANIFEST"
[ "$RC" -eq 0 ] && contains "$OUT" "tier bundled"; t "C9. a bundled entry ships in-tree and is never unexplained" "$OUT"
cli why nosuchthing --project-dir "$PROJ" --manifest "$MANIFEST"
[ "$RC" -eq 4 ] && contains "$ERR" "nosuchthing"; t "C10. an id that is in no lock, no manifest and not installed => exit 4" "rc=$RC err=$ERR"
cli lock --project-dir "$PROJ" --manifest "$MANIFEST" >/dev/null
GAPS=0; for id in thirdparty my-own-skill superpowers frontend-design; do cli why "$id" --project-dir "$PROJ" --manifest "$MANIFEST"; [ "$RC" -eq 0 ] || GAPS=$((GAPS + 1)); done
[ "$GAPS" -eq 0 ]; t "C11. after hmd skills lock every install on the machine is explained (the goal metric)"
cat >"$HEIMDALL_HOME/receipts/installs-run-10.ndjson" <<'EOF'
{"ts":"2026-11-12T09:30:00Z","run":"run-10","kind":"plugin","name":"frontend-design@claude-plugins-official","version":"5.0.7","source":"x","pin":"none","result":"ok","via":"\u001b[31mred\u009b2J"}
EOF
cli why frontend-design --project-dir "$PROJ" --manifest "$MANIFEST"
[ "$RC" -eq 0 ] && contains "$OUT" "installs-run-10.ndjson" && ! printf '%s' "$OUT" | LC_ALL=C grep -q "$(printf '\033')"
t "C12. a terminal escape in a receipt field is shown as ?, never sent to the terminal" "$(printf '%s' "$OUT" | LC_ALL=C tr -c ' -~\n' '#' | tail -n 3)"
mkdir -p "$TMP/alt-receipts"
printf '%s\n' '{"ts":"2026-11-12T11:00:00Z","run":"alt","kind":"skill","name":"ui-ux-pro-max","version":"abc1234","source":"github.com/x/y","pin":"none","result":"ok","via":"alt-dir"}' \
  >"$TMP/alt-receipts/installs-alt.ndjson"
HMD_RECEIPTS_DIR="$TMP/alt-receipts" cli why ui-ux-pro-max --project-dir "$PROJ" --manifest "$MANIFEST"
[ "$RC" -eq 0 ] && contains "$OUT" "receipt: installs-alt.ndjson 2026-11-12T11:00:00Z skill ui-ux-pro-max ok via=alt-dir" && ! contains "$OUT" "installs-run-9.ndjson"
t "C13. HMD_RECEIPTS_DIR moves the receipts, as install-receipt.sh reads it" "$OUT"
for n in 10 11 12 13 14 15 16 17 18 19 20; do
  printf '{"ts":"2026-11-12T10:%s:00Z","run":"r%s","kind":"plugin","name":"seo@claude-plugins-official","version":"unknown","source":"x","pin":"none","result":"failed","via":"prompt-preinstall"}\n' "$n" "$n"
done >"$HEIMDALL_HOME/receipts/installs-run-11.ndjson"
cli why seo --project-dir "$PROJ" --manifest "$MANIFEST"
[ "$RC" -eq 0 ] && [ "$(grep -c '^receipt: ' <<<"$OUT")" -eq 10 ] && contains "$OUT" "... 2 older receipt lines not shown"
t "C14. twelve receipt lines for one id: the newest ten are shown and the rest are counted" "$OUT"
only_reads; t "C15. why only ever ran claude plugins list --json" "$(cat "$FAKE_LOG")"

# ── D. lock --verify ─────────────────────────────────────────────────────────────────────────────────────────────
echo "D. lock --verify"
fresh d
plugins "$SP=5.0.7" "$FD=5.0.7"
mkskill ui-ux-pro-max git
seed_project_fd 5.0.6
cli lock --verify --project-dir "$PROJ" --manifest "$MANIFEST"
[ "$RC" -eq 1 ] && contains "$OUT" "drift frontend-design [project]" && contains "$OUT" "5.0.6" && contains "$OUT" "5.0.7"; t "D1. --verify names the drifted id, its scope, and both versions; exit 1" "rc=$RC out=$OUT"
contains "$OUT" "unlocked superpowers" && contains "$OUT" "unlocked ui-ux-pro-max"; t "D2. and the installs no lock explains" "$OUT"
[ ! -e "$MLOCK" ] && lockcheck "$PLOCK" 'row("frontend-design")["version"]' 5.0.6; t "D3. --verify wrote nothing: no machine lock, the project row still 5.0.6"
cli lock --project-dir "$PROJ" --manifest "$MANIFEST"
[ "$RC" -eq 0 ] && contains "$OUT" "refreshed frontend-design [project]" && contains "$OUT" "adopted superpowers" && contains "$OUT" "adopted ui-ux-pro-max"; t "D4. lock refreshes the drifted row and adopts the rest" "rc=$RC out=$OUT err=$ERR"
lockcheck "$PLOCK" '(row("frontend-design")["version"], row("frontend-design")["state"], row("frontend-design")["why"]["rule"])' "('5.0.7', 'installed', 'prompt_ere')"
t "D5. a refresh moves the version only: the state and the rule that triggered the install stay"
cli lock --verify --project-dir "$PROJ" --manifest "$MANIFEST"
[ "$RC" -eq 0 ] && contains "$OUT" "verify: ok"; t "D6. afterwards --verify passes" "rc=$RC out=$OUT"
plugins "$SP=5.0.8" "$FD=5.0.7" "extra@somemkt=2.0.0"
commit2 ui-ux-pro-max
B1="$(sha "$MLOCK")"; B2="$(sha "$PLOCK")"
cli lock --verify --project-dir "$PROJ" --manifest "$MANIFEST"
[ "$RC" -eq 1 ] && contains "$OUT" "drift superpowers [machine]" && contains "$OUT" "5.0.8" && contains "$OUT" "drift ui-ux-pro-max [machine]" && contains "$OUT" "unlocked extra"
t "D7. plugin version drift, skill commit drift and a new unlocked plugin are each named" "rc=$RC out=$OUT"
! contains "$OUT" "drift frontend-design"; t "D8. a row that still matches is not reported" "$OUT"
[ "$(sha "$MLOCK")" = "$B1" ] && [ "$(sha "$PLOCK")" = "$B2" ]; t "D9. --verify left both locks byte for byte as they were"
cli lock --project-dir "$PROJ" --manifest "$MANIFEST"
[ "$RC" -eq 0 ] && contains "$OUT" "refreshed superpowers [machine]" && contains "$OUT" "refreshed ui-ux-pro-max [machine]" && contains "$OUT" "adopted extra"; t "D10. lock refreshes both and adopts the new plugin" "rc=$RC out=$OUT"
lockcheck "$MLOCK" '(row("superpowers")["version"], row("ui-ux-pro-max")["content_hash"] == "'"$(headsha ui-ux-pro-max)"'")' "('5.0.8', True)"; t "D11. the rows now hold the installed version and commit"
cli lock --verify --project-dir "$PROJ" --manifest "$MANIFEST"
[ "$RC" -eq 0 ] && contains "$OUT" "verify: ok"; t "D12. and --verify passes again" "rc=$RC out=$OUT"
only_reads; t "D13. nothing but claude plugins list --json was ever run" "$(cat "$FAKE_LOG")"
fresh d2
mkskill ui-ux-pro-max git
SHA="$(headsha ui-ux-pro-max)"
lockrec --scope machine --id ui-ux-pro-max --state installed --kind github-skill --ref nextlevelbuilder/ui-ux-pro-max-skill \
  --content-hash "${SHA:0:12}" --source github.com/nextlevelbuilder/ui-ux-pro-max-skill --consent explicit --rule explicit \
  --via hmd-skills-install --manifest "$MANIFEST"
cli lock --verify --project-dir "$PROJ" --manifest "$MANIFEST"
[ "$RC" -eq 0 ] && contains "$OUT" "verify: ok"; t "D14. a row that holds an abbreviated commit still matches the full one" "rc=$RC out=$OUT"
commit2 ui-ux-pro-max
cli lock --verify --project-dir "$PROJ" --manifest "$MANIFEST"
[ "$RC" -eq 1 ] && contains "$OUT" "drift ui-ux-pro-max [machine]: commit ${SHA:0:12}"; t "D15. a new commit is drift, named with the commit the lock holds" "rc=$RC out=$OUT"

# ── E. fail closed ───────────────────────────────────────────────────────────────────────────────────────────────
echo "E. fail closed"
fresh e
plugins "$SP=5.0.7"
mkdir -p "$HEIMDALL_HOME"; printf '{bad' >"$MLOCK"
BEFORE="$(sha "$MLOCK")"
for cmd in "list" "list --json" "why superpowers" "lock" "lock --verify"; do
  # shellcheck disable=SC2086
  cli $cmd --project-dir "$PROJ" --manifest "$MANIFEST"
  [ "$RC" -eq 3 ] && [ -n "$ERR" ] && ! contains "$ERR" Traceback && [ "$(printf '%s\n' "$ERR" | wc -l | tr -d ' ')" -le 2 ]; t "E1. a corrupt machine lock: '$cmd' exits 3 with a reason, no traceback" "rc=$RC err=$ERR"
done
[ "$(sha "$MLOCK")" = "$BEFORE" ]; t "E2. and the corrupt lock was not touched"
rm -f "$MLOCK"; mkdir -p "$PROJ/.planning"; ln -s "$TMP/nowhere" "$PLOCK"
cli list --project-dir "$PROJ" --manifest "$MANIFEST"
[ "$RC" -eq 3 ] && contains "$ERR" "symbolic link"; t "E3. a project lock that is a symbolic link is refused (a cloned repo supplies it)" "rc=$RC err=$ERR"
rm -f "$PLOCK"
cli list --project-dir "$PROJ" --manifest "$TMP/invalid.manifest.json"
[ "$RC" -eq 3 ] && ! contains "$ERR" Traceback; t "E4. an invalid manifest: exit 3" "rc=$RC err=$ERR"
cli list --project-dir "$PROJ" --manifest "$TMP/missing.json"
[ "$RC" -eq 3 ] && contains "$ERR" "missing.json"; t "E5. a missing manifest: exit 3, naming it" "rc=$RC err=$ERR"
for args in "" "why" "list --nope" "bogus" "why a|b"; do
  # shellcheck disable=SC2086
  cli $args
  [ "$RC" -eq 2 ] && ! contains "$ERR" Traceback; t "E6. bad usage '$args': exit 2" "rc=$RC err=$ERR"
done
[ -z "$(ls "$PROJ/.planning" 2>/dev/null)" ] && [ ! -e "$MLOCK" ]; t "E7. no failure left a lock behind"

# ── F. the suite can go RED ──────────────────────────────────────────────────────────────────────────────────────
echo "F. the checks go RED on a broken module"
mutate() {  # mutate NAME SED-EXPRESSION: $TMP/mut/NAME/skills_cli_read.py is the module with one line broken
  local d="$TMP/mut/$1"
  mkdir -p "$d"
  cp "$REPO"/bin/lib/skills_{lock,manifest,config}.py "$d/"
  sed -e "$2" "$LIB" >"$d/skills_cli_read.py"
  ! cmp -s "$LIB" "$d/skills_cli_read.py"
}
red() {  # red LABEL PROPERTY SED-EXPRESSION: PROPERTY holds for the module and fails for the module with that one line broken
  local label="$1" prop="$2" expr="$3" real broken
  CLI_LIB=""; "$prop"; real=$?
  if ! mutate "$label" "$expr"; then bad "F. $label: the break did not change the module"; return; fi
  CLI_LIB="$TMP/mut/$label/skills_cli_read.py"; "$prop"; broken=$?
  CLI_LIB=""
  if [ "$real" -eq 0 ] && [ "$broken" -ne 0 ]; then ok "F. $label: holds for the module, goes RED on the break"; else bad "F. $label" "module=$real broken=$broken"; fi
}
prop_adopts() {
  fresh m1; plugins "$SP=5.0.7"
  cli lock --project-dir "$PROJ" --manifest "$MANIFEST" >/dev/null
  [ "$(lockj "$MLOCK" 'row("superpowers")["state"]')" = adopted ]
}
prop_why_unexplained() {
  fresh m2; plugins "$SP=5.0.7"
  cli why superpowers --project-dir "$PROJ" --manifest "$MANIFEST" >/dev/null
  [ "$RC" -eq 1 ]
}
prop_detects_drift() {
  fresh m3; plugins "$SP=5.0.7"
  cli lock --project-dir "$PROJ" --manifest "$MANIFEST" >/dev/null
  plugins "$SP=5.0.8"
  cli lock --verify --project-dir "$PROJ" --manifest "$MANIFEST" >/dev/null
  [ "$RC" -eq 1 ]
}
prop_strips_escapes() {
  fresh m4; plugins "$FD=5.0.7"; seed_project_fd
  mkdir -p "$HEIMDALL_HOME/receipts"
  printf '%s\n' '{"ts":"2026-11-12T09:30:00Z","run":"r","kind":"plugin","name":"frontend-design@claude-plugins-official","version":"5.0.7","source":"x","pin":"none","result":"ok","via":"\u001b[31mred"}' \
    >"$HEIMDALL_HOME/receipts/installs-r.ndjson"
  cli why frontend-design --project-dir "$PROJ" --manifest "$MANIFEST" >/dev/null
  ! printf '%s' "$OUT" | LC_ALL=C grep -q "$(printf '\033')"
}
prop_verify_readonly() {
  fresh m5; plugins "$SP=5.0.7"
  cli lock --project-dir "$PROJ" --manifest "$MANIFEST" >/dev/null
  plugins "$SP=5.0.8"
  local before; before="$(sha "$MLOCK")"
  cli lock --verify --project-dir "$PROJ" --manifest "$MANIFEST" >/dev/null
  [ "$(sha "$MLOCK")" = "$before" ]
}
red "adopted-state"    prop_adopts           's/^ADOPTED = "adopted"$/ADOPTED = "installed"/'
red "unexplained-exit" prop_why_unexplained  's/^EXIT_UNEXPLAINED = 1/EXIT_UNEXPLAINED = 0/'
red "drift-compare"    prop_detects_drift    's/^    return known(have) and known(want) and have != want$/    return False/'
red "escape-strip"     prop_strips_escapes   's/^    return "".join("?" if .*$/    return str(value)/'
red "verify-writes"    prop_verify_readonly  's/^    if args.verify:$/    if False:/'

echo
echo "skills-cli-read: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
