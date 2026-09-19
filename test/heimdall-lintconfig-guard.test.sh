#!/usr/bin/env bash
# test/heimdall-lintconfig-guard.test.sh
#
# Proof for bin/heimdall-lintconfig-guard -- the PreToolUse gate that refuses
# agent edits to linter / formatter / typechecker config (the cheapest way to
# make "Lint clean (zero warnings)" go green without fixing anything).
#
# The properties asserted head-on:
#   1. It DENIES a positive match on every tool shape it is wired to
#      (Write, Edit, MultiEdit, Bash write idioms), with the exact deny
#      contract: {"error": ...} JSON on stdout, reason on stderr, exit 2.
#   2. It matches the BASENAME, never a substring -- prose about a config is
#      not the config.
#   3. It reads a shell command for WRITE idioms only -- `cat ruff.toml` is a
#      read and passes.
#   4. pyproject.toml is section-aware: [project] edits pass, [tool.ruff]
#      edits do not.
#   5. FAIL-OPEN on plumbing: empty stdin, malformed JSON, unknown tool, no
#      jq on PATH -- every one exits 0 silently.
#   6. The operator override HMD_ALLOW_LINTCONFIG_EDIT=1 allows, exit 0.
#
# Every case runs in a temp dir, so this test never touches a real config.

set -u

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GUARD="$REPO/bin/heimdall-lintconfig-guard"

PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; }

TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT
WORK="$TMPROOT/work"
mkdir -p "$WORK/src" "$WORK/packages/web"
cd "$WORK" || exit 1

OUT="$TMPROOT/out"
ERR="$TMPROOT/err"

# run_guard <json-payload> [env assignments...]  -> echoes exit code
run_guard() {
  local payload="$1"; shift
  printf '%s' "$payload" | env "$@" "$GUARD" 1>"$OUT" 2>"$ERR"
  printf '%s' "$?"
}

payload_write() { jq -cn --arg p "$1" --arg c "$2" '{tool_name:"Write", tool_input:{file_path:$p, content:$c}}'; }
payload_edit()  { jq -cn --arg p "$1" --arg o "$2" --arg n "$3" '{tool_name:"Edit", tool_input:{file_path:$p, old_string:$o, new_string:$n}}'; }
payload_bash()  { jq -cn --arg c "$1" '{tool_name:"Bash", tool_input:{command:$c}}'; }

# A deny must be: exit 2, valid JSON with a non-empty .error on stdout, the
# override named in the message, and a non-empty stderr.
assert_denied() {
  local label="$1" rc="$2"
  if [ "$rc" = "2" ] \
     && jq -e '.error | type == "string" and length > 0' "$OUT" >/dev/null 2>&1 \
     && grep -q 'HMD_ALLOW_LINTCONFIG_EDIT=1' "$OUT" \
     && [ -s "$ERR" ]; then
    ok "$label"
  else
    bad "$label (rc=$rc stdout=$(head -c 120 "$OUT"))"
  fi
}

# An allow must be: exit 0 and NOTHING on stdout (a stray line would be fed
# to Claude Code as hook output).
assert_allowed() {
  local label="$1" rc="$2"
  if [ "$rc" = "0" ] && [ ! -s "$OUT" ]; then
    ok "$label"
  else
    bad "$label (rc=$rc stdout=$(head -c 120 "$OUT"))"
  fi
}

command -v jq >/dev/null 2>&1 || { echo "jq is required to run this test"; exit 1; }

echo "heimdall-lintconfig-guard"

# ── 1. Write to .eslintrc.json -> denied ────────────────────────────────────
rc="$(run_guard "$(payload_write "$WORK/.eslintrc.json" '{"rules":{"no-unused-vars":"off"}}')")"
assert_denied "1. Write .eslintrc.json is denied (exit 2, {\"error\":...} JSON)" "$rc"

# ── 2. Edit to biome.json -> denied ─────────────────────────────────────────
printf '{"linter":{"enabled":true}}\n' > "$WORK/biome.json"
rc="$(run_guard "$(payload_edit "$WORK/biome.json" '"enabled":true' '"enabled":false')")"
assert_denied "2. Edit biome.json is denied" "$rc"

# ── 3. Bash `echo x > ruff.toml` -> denied ──────────────────────────────────
rc="$(run_guard "$(payload_bash 'echo "ignore = [\"E501\"]" > ruff.toml')")"
assert_denied "3. Bash redirect into ruff.toml is denied" "$rc"

# ── 4. Bash `cat ruff.toml` (read-only) -> allowed ──────────────────────────
rc="$(run_guard "$(payload_bash 'cat ruff.toml')")"
assert_allowed "4. Bash read of ruff.toml is allowed" "$rc"

# ── 5. Write to src/app.ts -> allowed ───────────────────────────────────────
rc="$(run_guard "$(payload_write "$WORK/src/app.ts" 'export const x = 1;')")"
assert_allowed "5. Write src/app.ts is allowed" "$rc"

# ── 6. Basename rule: notes-about-tsconfig.md -> allowed ────────────────────
rc="$(run_guard "$(payload_write "$WORK/notes-about-tsconfig.md" '# why strict mode')")"
assert_allowed "6. Write notes-about-tsconfig.md is allowed (basename, not substring)" "$rc"
rc="$(run_guard "$(payload_bash 'echo history >> docs/eslintrc-history.txt')")"
assert_allowed "6b. Bash redirect into eslintrc-history.txt is allowed (basename rule)" "$rc"

# ── 7. Operator override -> allowed, exit 0 ─────────────────────────────────
rc="$(run_guard "$(payload_write "$WORK/.eslintrc.json" '{}')" HMD_ALLOW_LINTCONFIG_EDIT=1)"
assert_allowed "7. HMD_ALLOW_LINTCONFIG_EDIT=1 allows the same Write, exit 0" "$rc"
# Only the exact value 1 is the override; "0", "true", "" are not.
rc="$(run_guard "$(payload_write "$WORK/.eslintrc.json" '{}')" HMD_ALLOW_LINTCONFIG_EDIT=0)"
assert_denied "7b. HMD_ALLOW_LINTCONFIG_EDIT=0 is not an override" "$rc"

# ── 8. Empty stdin -> exit 0 ────────────────────────────────────────────────
rc="$(run_guard '')"
assert_allowed "8. empty stdin exits 0 silently" "$rc"

# ── 9-11. FAIL-OPEN on the other plumbing gaps ──────────────────────────────
rc="$(run_guard 'this is not json')"
assert_allowed "9. malformed JSON exits 0 silently" "$rc"

rc="$(run_guard '{"tool_name":"Read","tool_input":{"file_path":".eslintrc.json"}}')"
assert_allowed "10. an unknown/unwired tool (Read) exits 0 even on a protected path" "$rc"

# No jq on PATH: a symlink farm of every other binary, minus jq.
FAKEBIN="$TMPROOT/fakebin"; mkdir -p "$FAKEBIN"
for d in /usr/bin /bin; do
  for f in "$d"/*; do
    b="$(basename "$f")"
    [ "$b" = "jq" ] && continue
    [ -e "$FAKEBIN/$b" ] || ln -s "$f" "$FAKEBIN/$b" 2>/dev/null
  done
done
printf '%s' "$(payload_write "$WORK/.eslintrc.json" '{}')" \
  | env -i PATH="$FAKEBIN" HOME="$TMPROOT" bash "$GUARD" 1>"$OUT" 2>"$ERR"; rc=$?
if command -v jq >/dev/null 2>&1 && [ ! -x "$FAKEBIN/jq" ]; then
  assert_allowed "11. missing jq exits 0 silently (fail-open on plumbing)" "$rc"
else
  bad "11. could not build a jq-less PATH for the test"
fi

# ── 12-15. The rest of the protected set, on every tool shape ───────────────
for f in tsconfig.json packages/web/tsconfig.build.json .prettierrc prettier.config.js \
         eslint.config.mjs .editorconfig .shellcheckrc .golangci.yml rustfmt.toml \
         clippy.toml mypy.ini pyrightconfig.json .ruff.toml; do
  rc="$(run_guard "$(payload_write "$WORK/$f" 'x')")"
  [ "$rc" = "2" ] || bad "12. Write $f should be denied (rc=$rc)"
done
ok "12. every named config basename is denied on Write (incl. nested tsconfig.build.json)"

rc="$(run_guard "$(jq -cn --arg p "$WORK/tsconfig.json" '{tool_name:"MultiEdit", tool_input:{file_path:$p, edits:[{old_string:"a",new_string:"b"}]}}')")"
assert_denied "13. MultiEdit on tsconfig.json is denied" "$rc"

rc="$(run_guard "$(payload_bash 'cat fix.json | tee -a .prettierrc')")"
assert_denied "14a. Bash tee into .prettierrc is denied" "$rc"
rc="$(run_guard "$(payload_bash "sed -i '' 's/strict/loose/' packages/web/tsconfig.build.json")")"
assert_denied "14b. Bash sed -i on a nested tsconfig.build.json is denied" "$rc"
rc="$(run_guard "$(payload_bash 'perl -pi -e s/x/y/ .shellcheckrc')")"
assert_denied "14c. Bash perl -pi on .shellcheckrc is denied" "$rc"
rc="$(run_guard "$(payload_bash 'rm -f .golangci.yml && go build ./...')")"
assert_denied "14d. Bash rm of .golangci.yml is denied" "$rc"
rc="$(run_guard "$(payload_bash 'mv biome.json biome.json.bak')")"
assert_denied "14e. Bash mv of biome.json is denied" "$rc"
rc="$(run_guard "$(payload_bash 'npm run lint 2>/dev/null; cat > src/out.txt <<EOF
hello
EOF
echo done >&2')")"
assert_allowed "15a. Bash with 2>/dev/null, >&2 and a heredoc into src/ is allowed" "$rc"
rc="$(run_guard "$(payload_bash 'sed -n 1,20p ruff.toml; grep -n rules .eslintrc.json; diff tsconfig.json tsconfig.base.json')")"
assert_allowed "15b. Bash sed -n / grep / diff over configs (reads) is allowed" "$rc"
rc="$(run_guard "$(payload_bash 'npx eslint --print-config src/app.ts > /tmp/effective.json')")"
assert_allowed "15c. Bash redirect into a non-config file is allowed" "$rc"

# ── 16-19. pyproject.toml is section-aware ──────────────────────────────────
PYPROJECT="$WORK/pyproject.toml"
cat > "$PYPROJECT" <<'EOF'
[project]
name = "demo"
version = "1.0.0"
dependencies = ["requests>=2.31"]

[tool.ruff]
line-length = 88
select = ["E", "F"]

[tool.ruff.lint]
ignore = []

[tool.pytest.ini_options]
testpaths = ["tests"]
EOF

rc="$(run_guard "$(payload_edit "$PYPROJECT" 'version = "1.0.0"' 'version = "1.1.0"')")"
assert_allowed "16. Edit pyproject.toml [project] version is allowed" "$rc"

rc="$(run_guard "$(payload_edit "$PYPROJECT" 'ignore = []' 'ignore = ["E501", "F401"]')")"
assert_denied "17a. Edit pyproject.toml inside [tool.ruff.lint] is denied" "$rc"
rc="$(run_guard "$(payload_edit "$PYPROJECT" 'testpaths = ["tests"]' 'testpaths = ["tests"]

[tool.mypy]
ignore_errors = true')")"
assert_denied "17b. Edit pyproject.toml that adds a [tool.mypy] table is denied" "$rc"
rc="$(run_guard "$(payload_edit "$PYPROJECT" 'select = ["E", "F"]

[tool.ruff.lint]
ignore = []

[tool.pytest.ini_options]' 'select = ["E"]

[tool.pytest.ini_options]')")"
assert_denied "17c. Edit whose old_string starts in [tool.ruff] and runs past it is denied" "$rc"

# Write: protected tables byte-identical, [project] changed -> allowed.
NEWBODY="$(sed 's/version = "1.0.0"/version = "2.0.0"/' "$PYPROJECT")"
rc="$(run_guard "$(payload_write "$PYPROJECT" "$NEWBODY")")"
assert_allowed "18. Write pyproject.toml with identical [tool.ruff*] tables is allowed" "$rc"
NEWBODY="$(sed 's/line-length = 88/line-length = 400/' "$PYPROJECT")"
rc="$(run_guard "$(payload_write "$PYPROJECT" "$NEWBODY")")"
assert_denied "19a. Write pyproject.toml changing [tool.ruff] line-length is denied" "$rc"
rc="$(run_guard "$(payload_write "$WORK/packages/web/pyproject.toml" '[tool.ruff]
ignore = ["ALL"]')")"
assert_denied "19b. Write a NEW nested pyproject.toml carrying [tool.ruff] is denied" "$rc"
rc="$(run_guard "$(payload_write "$WORK/packages/web/pyproject.toml" '[project]
name = "sub"')")"
assert_allowed "19c. Write a NEW pyproject.toml with no linter table is allowed" "$rc"
rc="$(run_guard "$(payload_bash "sed -i '' 's/88/400/' pyproject.toml")")"
assert_denied "19d. Bash sed -i into pyproject.toml is denied (opaque shell write)" "$rc"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
