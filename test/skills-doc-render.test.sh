#!/usr/bin/env bash
#
# skills-doc-render.test.sh — the autoinstall doc renderer (3.x M1, T4.4).
#
# skills/heimdall/references/plugin-autoinstall.md carries two tables an agent reads (the auto-install map and the
# mid-task signals), and the launcher's injected prompt mirrors three of those rows in one hard-coded line. All of
# it is a rendering of skills.manifest.json, so bin/lib/skills_render_doc.py prints it from the manifest, writes it
# between `<!-- BEGIN GENERATED skills.manifest ... -->` markers and checks that a doc still holds what the manifest
# says. T5.1 (launcher) and T5.3 (the doc itself) wire it in; this suite proves the renderer alone.
#
# Proven here:
#   A. parity: the manifest's rendering (flavour auto, which is also the default) is today's text byte for byte:
#      the 8 rows of the auto-install map, the 9 rows of the mid-task table and the injected-prompt line. "Today's"
#      is a FROZEN copy below, not the live doc: T5.3 replaces the hand-written tables with generated blocks, and a
#      test that read the doc then would grade the renderer against its own output;
#   B. the ask flavour: install commands become `hmd skills install <id>` (exit 3 = consent required), nothing else
#      in the tables moves, and the prompt line stops naming `claude plugins install`;
#   C. --check: a doc whose blocks are current exits 0 in both flavours whatever the prose around them says; every
#      kind of drift (an edited cell, a lost row, an extra row, reordered rows, a trailing space, a block in the
#      wrong flavour, a changed prompt line) exits 1 and names the one stale block;
#   D. from the manifest: move a row pointer or change a ref and the rendering follows, and a doc rendered before
#      the change is stale;
#   E. --write: fills empty blocks, leaves the prose byte for byte, is idempotent, repairs a stale doc, keeps the
#      file mode and leaves no temp file behind;
#   F. fail closed (exit 3, reason on stderr, nothing on stdout, never a traceback): a manifest that cannot place a
#      row or has no display text for it, an invalid or missing manifest, a doc with a malformed marker or none;
#   G. a usage error exits 2.
#
# Hermetic: a throwaway WORK dir, no network, nothing outside it is read or written.
#
# Usage: test/skills-doc-render.test.sh      Exit 0 = every proof holds.
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SELF_DIR/.." && pwd)"
PASS=0; FAIL=0
ok()  { printf '  \033[32mPASS\033[0m %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAIL=$((FAIL + 1)); }

PY="$(command -v python3 || true)"
[ -n "$PY" ] || { echo "FATAL: python3 not found"; exit 2; }
# the real interpreter, not a version-manager shim (0.3-0.8 s a call, and this suite starts ~100 of them)
PYREAL="$("$PY" -I -c 'import sys; print(sys.executable)' 2>/dev/null)"
if [ -n "$PYREAL" ] && [ -x "$PYREAL" ]; then PY="$PYREAL"; fi

RENDER="$REPO/bin/lib/skills_render_doc.py"
VALIDATE="$REPO/bin/lib/skills_manifest.py"
MANIFEST="$REPO/skills.manifest.json"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# render ARGS... — one run of the renderer: stdout in $WORK/out, stderr in ERR, the exit code in RC.
render() { "$PY" -I "$RENDER" "$@" >"$WORK/out" 2>"$WORK/err"; RC=$?; ERR="$(cat "$WORK/err")"; }

same() {  # LABEL WANT-FILE — the last run exited 0, said nothing on stderr and printed WANT-FILE byte for byte
  if [ "$RC" -eq 0 ] && [ -z "$ERR" ] && cmp -s "$WORK/out" "$2"; then ok "$1"
  else bad "$1 (rc=$RC): $(diff "$2" "$WORK/out" 2>&1 | head -4 | cut -c1-200) ${ERR:0:200}"; fi
}

expect() {  # LABEL RC FRAGMENT — the last run exited RC, FRAGMENT is on stderr, stdout is empty, no traceback
  if [ "$RC" -eq "$2" ] && [[ "$ERR" == *"$3"* ]] && [[ "$ERR" != *Traceback* ]] && [ ! -s "$WORK/out" ]; then ok "$1"
  else bad "$1: wanted rc=$2 naming '$3' (rc=$RC, stdout $(wc -c <"$WORK/out" | tr -d ' ') bytes): ${ERR:0:300}"; fi
}

# ── today's text, frozen ─────────────────────────────────────────────────────────────
# Copied byte for byte from skills/heimdall/references/plugin-autoinstall.md (lines 15-24 and 45-55) and from the
# `ALSO install plugins` line of the PREAMBLE string in bin/heimdall (its \` and \" escapes undone: this is what the agent reads).
cat >"$WORK/today-auto-install.md" <<'EOF'
| Domain detected | Plugin needed | Install command |
|---|---|---|
| Frontend / UI / React / CSS | frontend-design | `claude plugins install frontend-design@claude-plugins-official` |
| SEO / meta tags / sitemap | seo | `claude plugins install seo@claude-plugins-official` |
| MCP / tool server | mcp-server-dev | `claude plugins install mcp-server-dev@claude-plugins-official` |
| API design / OpenAPI | api-design | `claude plugins install api-design@claude-plugins-official` |
| Database / SQL / schema | database-toolkit | `claude plugins install database-toolkit@claude-plugins-official` |
| Docker / K8s / deploy | devops-toolkit | `claude plugins install devops-toolkit@claude-plugins-official` |
| Security / auth / OWASP | security-scanner | `claude plugins install security-scanner@claude-plugins-official` |
| Slack / notifications | slack | `claude plugins install slack@claude-plugins-official` |
EOF
cat >"$WORK/today-mid-task.md" <<'EOF'
| Signal during execution | Install |
|---|---|
| Reading a `package.json` with React/Vue/Angular | `frontend-design` |
| Touching `.css`/`.scss`/`tailwind.config` | `frontend-design` |
| Reading `Dockerfile`/`docker-compose`/`k8s` manifests | `devops-toolkit` |
| Seeing SQL files / Prisma / Sequelize / TypeORM | `database-toolkit` |
| Reading OpenAPI/Swagger specs | `api-design` |
| Finding auth/JWT/OAuth code | `security-scanner` |
| Touching SEO meta tags / robots.txt / sitemap | `seo` |
| Finding `.mcp.json` or MCP server code | `mcp-server-dev` |
| User mentions Slack / notifications mid-conversation | `slack` |
EOF
cat >"$WORK/today-prompt.txt" <<'EOF'
ALSO install plugins, only from the listed marketplace: Read React/Vue/CSS → `claude plugins install frontend-design@claude-plugins-official`. Read Dockerfile/k8s → `claude plugins install devops-toolkit@claude-plugins-official`. Read SQL/ORM → `claude plugins install database-toolkit@claude-plugins-official`. If an install fails say "install failed, continuing without <name>" and go on — never retry through another marketplace, never pass --yes.
EOF

# A frozen copy that lost a line would make every parity proof below vacuous.
if [ "$(wc -l <"$WORK/today-auto-install.md" | tr -d ' ')" = 10 ] && [ "$(grep -c 'claude plugins install' "$WORK/today-auto-install.md")" = 8 ] \
   && [ "$(wc -l <"$WORK/today-mid-task.md" | tr -d ' ')" = 11 ] && [ "$(wc -l <"$WORK/today-prompt.txt" | tr -d ' ')" = 1 ]; then
  ok "A: the frozen copies hold the 8 auto-install rows, the 9 mid-task rows and the one prompt line"
else
  bad "A: a frozen copy of today's text is truncated"
fi

# ── A. parity with today ─────────────────────────────────────────────────────────────
render --part auto-install --flavour auto
same "A: auto-install map, flavour auto = today's 8 rows byte for byte" "$WORK/today-auto-install.md"
render --part auto-install
same "A: auto-install map, no --flavour = auto" "$WORK/today-auto-install.md"
render --manifest "$MANIFEST" --part auto-install
same "A: with no --manifest the repo's skills.manifest.json is the one rendered" "$WORK/today-auto-install.md"
render --part mid-task --flavour auto
same "A: mid-task table = today's 9 rows byte for byte" "$WORK/today-mid-task.md"
render --part prompt --flavour auto
same "A: injected-prompt line, flavour auto = today's bin/heimdall line byte for byte" "$WORK/today-prompt.txt"

# ── B. the ask flavour ───────────────────────────────────────────────────────────────
sed -E 's/`claude plugins install ([a-z0-9-]+)@claude-plugins-official`/`hmd skills install \1`/' "$WORK/today-auto-install.md" >"$WORK/want-ask-table.md"
if cmp -s "$WORK/want-ask-table.md" "$WORK/today-auto-install.md" || [ "$(grep -c 'hmd skills install' "$WORK/want-ask-table.md")" != 8 ]; then
  bad "B: the expected ask table was not derived (sed matched nothing)"
fi
render --part auto-install --flavour ask
same "B: ask auto-install map = today's rows with the consent-gated command" "$WORK/want-ask-table.md"
render --part mid-task --flavour ask
same "B: the mid-task table does not depend on the flavour" "$WORK/today-mid-task.md"
render --part prompt --flavour ask
PROMPT_ASK="$(cat "$WORK/out")"
INSTALLS="$(grep -o 'hmd skills install [a-z-]*' "$WORK/out" | tr '\n' ',')"
if [ "$RC" -eq 0 ] && [ -z "$ERR" ] && [ "$(wc -l <"$WORK/out" | tr -d ' ')" = 1 ] \
   && [ "$INSTALLS" = 'hmd skills install frontend-design,hmd skills install devops-toolkit,hmd skills install database-toolkit,' ] \
   && [[ "$PROMPT_ASK" == "ALSO install plugins"*"consent required"* ]] && [[ "$PROMPT_ASK" != *"claude plugins install"* ]]; then
  ok "B: ask prompt line is one line: three hmd skills install commands, consent required, no raw claude plugins install"
else
  bad "B: ask prompt line (rc=$RC): ${PROMPT_ASK:0:400} ${ERR:0:200}"
fi

# ── C. --check ───────────────────────────────────────────────────────────────────────
for flavour in auto ask; do
  for part in auto-install mid-task prompt; do
    "$PY" -I "$RENDER" --part "$part" --flavour "$flavour" >"$WORK/r-$part-$flavour.txt" 2>/dev/null \
      || bad "C: could not render $part ($flavour) for the fixture docs"
  done
done

make_doc() {  # FILE FLAVOUR [FILL] — prose around three blocks; FILL=empty leaves the block bodies empty
  local part
  {
    printf '# A doc\n\nprose before\n\n'
    for part in auto-install mid-task prompt; do
      printf '<!-- BEGIN GENERATED skills.manifest part=%s flavour=%s -->\n' "$part" "$2"
      [ "${3:-}" = empty ] || cat "$WORK/r-$part-$2.txt"
      printf '<!-- END GENERATED skills.manifest -->\n\nprose after %s\n\n' "$part"
    done
  } >"$1"
}
line_of() { grep -n -F -- "$2" "$1" | head -1 | cut -d: -f1; }  # FILE NEEDLE — 1-based line of the first match

stale() {  # LABEL FILE PART [RENDER-ARGS...] — --check exits 1 and names exactly one stale block, the one of PART
  local label="$1" file="$2" part="$3" n
  shift 3
  render "$@" --check "$file"
  n="$(grep -c 'stale:' "$WORK/err")"
  if [ "$RC" -eq 1 ] && [ "$n" -eq 1 ] && [[ "$ERR" == *"part=$part"* ]] && [[ "$ERR" == *"line $(line_of "$file" "part=$part")"* ]] \
     && [[ "$ERR" != *Traceback* ]] && [ ! -s "$WORK/out" ]; then
    ok "C: stale: $label"
  else
    bad "C: stale: $label wants rc=1 and one stale block part=$part at its BEGIN line (rc=$RC, $n stale): ${ERR:0:300}"
  fi
}

for flavour in auto ask; do
  make_doc "$WORK/fresh-$flavour.md" "$flavour"
  render --check "$WORK/fresh-$flavour.md"
  if [ "$RC" -eq 0 ] && [ -z "$ERR" ] && [[ "$(cat "$WORK/out")" == "ok $WORK/fresh-$flavour.md (3 generated blocks current)" ]]; then
    ok "C: a doc whose three blocks are current exits 0 ($flavour)"
  else
    bad "C: a current doc ($flavour) wants rc=0 and an ok line (rc=$RC): $(cat "$WORK/out") ${ERR:0:300}"
  fi
done

cp "$WORK/fresh-auto.md" "$WORK/prose.md"
{ printf 'a new paragraph\n\n'; cat "$WORK/fresh-auto.md"; printf '\nand a closing one, with | pipes and `ticks`\n'; } >"$WORK/prose.md"
render --check "$WORK/prose.md"
if [ "$RC" -eq 0 ]; then ok "C: prose outside the blocks may change freely"; else bad "C: prose outside the blocks made --check fail (rc=$RC): ${ERR:0:300}"; fi

sed 's#seo@claude-plugins-official#seo@elsewhere#' "$WORK/fresh-auto.md" >"$WORK/s-cell.md"
stale "an edited cell (the seo row's command)" "$WORK/s-cell.md" auto-install

grep -v -F 'User mentions Slack' "$WORK/fresh-auto.md" >"$WORK/s-lost.md"
stale "a row lost from the mid-task table" "$WORK/s-lost.md" mid-task

awk '/END GENERATED/ && !done { print "| Extra domain | extra | `claude plugins install extra@claude-plugins-official` |"; done = 1 } { print }' "$WORK/fresh-auto.md" >"$WORK/s-extra.md"
stale "an extra row at the end of the auto-install block" "$WORK/s-extra.md" auto-install

awk -v n="$(line_of "$WORK/fresh-auto.md" '| Frontend / UI')" 'NR == n { held = $0; next } NR == n + 1 { print; print held; next } { print }' "$WORK/fresh-auto.md" >"$WORK/s-order.md"
stale "two auto-install rows exchanged" "$WORK/s-order.md" auto-install

awk '/\| slack \|/ && !done { print $0 " "; done = 1; next } { print }' "$WORK/fresh-auto.md" >"$WORK/s-space.md"
stale "a trailing space on one row" "$WORK/s-space.md" auto-install

awk '/BEGIN GENERATED/ && /part=auto-install/ { sub(/flavour=auto/, "flavour=ask") } { print }' "$WORK/fresh-auto.md" >"$WORK/s-flavour.md"
stale "a block of auto text under a flavour=ask marker" "$WORK/s-flavour.md" auto-install

sed 's/never pass --yes/pass --yes/' "$WORK/fresh-auto.md" >"$WORK/s-prompt.md"
stale "a reworded prompt line" "$WORK/s-prompt.md" prompt

# ── D. from the manifest ─────────────────────────────────────────────────────────────
cat >"$WORK/mutate.py" <<'PYEOF'
"""mutate.py SRC DST OP ARGS... — copy the manifest SRC to DST with ONE change."""
import json
import sys

src, dst, op = sys.argv[1:4]
args = sys.argv[4:]
with open(src) as handle:
    doc = json.load(handle)
by_id = {entry["id"]: entry for entry in doc["entries"]}


def pointer_item(entry_id, path):
    for item in by_id[entry_id]["legacy"]:
        if item["mechanism"] == "plugin-autoinstall.md" and item["path"] == path:
            return item
    sys.exit("%s has no pointer %r" % (entry_id, path))


if op == "set-pointer":        # ID OLD NEW
    pointer_item(args[0], args[1])["path"] = args[2]
elif op == "swap-pointers":    # ID1 PATH1 ID2 PATH2
    first, second = pointer_item(args[0], args[1]), pointer_item(args[2], args[3])
    first["path"], second["path"] = second["path"], first["path"]
elif op == "add-pointer":      # ID PATH
    by_id[args[0]]["legacy"].append({"mechanism": "plugin-autoinstall.md", "path": args[1]})
elif op == "swap-orders":      # ID1 ID2 — exchange their triggers.order
    first, second = by_id[args[0]]["triggers"], by_id[args[1]]["triggers"]
    first["order"], second["order"] = second["order"], first["order"]
elif op == "set-ref":          # ID REF MARKETPLACE
    by_id[args[0]]["ref"], by_id[args[0]]["marketplace"] = args[1], args[2]
elif op == "drop-entry":       # ID
    doc["entries"] = [entry for entry in doc["entries"] if entry["id"] != args[0]]
elif op == "set-top":          # FIELD JSON
    doc[args[0]] = json.loads(args[1])
else:
    sys.exit("unknown op %s" % op)
with open(dst, "w") as handle:
    json.dump(doc, handle, indent=1)
PYEOF

mutate() {  # NAME OP ARGS... — $WORK/NAME.json = the real manifest with one change, and it must still be a VALID manifest
  local name="$1"; shift
  "$PY" -I "$WORK/mutate.py" "$MANIFEST" "$WORK/$name.json" "$@" \
    || { bad "fixture $name could not be built"; return 1; }
  "$PY" -I "$VALIDATE" validate "$WORK/$name.json" >/dev/null 2>&1 \
    || { bad "fixture $name is not a valid manifest, so rejecting it would prove nothing about the renderer"; return 1; }
}

if mutate swap swap-pointers frontend-design "auto-install map row 1" seo "auto-install map row 2"; then
  render --manifest "$WORK/swap.json" --part auto-install
  if [ "$RC" -eq 0 ] && [[ "$(sed -n 3p "$WORK/out")" == "| SEO / meta tags / sitemap | seo | "* ]] && [[ "$(sed -n 4p "$WORK/out")" == "| Frontend / UI / React / CSS | frontend-design | "* ]]; then
    ok "D: the rows follow the pointers: exchanging the row numbers of two entries exchanges their rows"
  else
    bad "D: exchanging two row numbers did not move the rows (rc=$RC): $(sed -n 3,4p "$WORK/out" | cut -c1-120)"
  fi
  stale "a doc rendered before the manifest moved a row" "$WORK/fresh-auto.md" auto-install --manifest "$WORK/swap.json"
fi

if mutate retag set-ref frontend-design frontend-design@heimdall-marketplace heimdall-marketplace; then
  render --manifest "$WORK/retag.json" --part auto-install --flavour auto
  if [ "$RC" -eq 0 ] && grep -q -F '`claude plugins install frontend-design@heimdall-marketplace`' "$WORK/out" \
     && ! grep -q -F 'frontend-design@claude-plugins-official' "$WORK/out"; then
    ok "D: the install command is the manifest's ref (a changed ref is a changed command)"
  else
    bad "D: a changed ref did not reach the install command (rc=$RC): $(sed -n 3p "$WORK/out" | cut -c1-160)"
  fi
  render --manifest "$WORK/retag.json" --part auto-install --flavour ask
  same "D: the ask flavour names the id, not the ref, so a ref change leaves it alone" "$WORK/r-auto-install-ask.txt"
fi

if mutate neworder swap-orders frontend-design devops-toolkit; then
  render --manifest "$WORK/neworder.json" --part prompt --flavour auto
  WANT='ALSO install plugins, only from the listed marketplace: Read Dockerfile/k8s → `claude plugins install devops-toolkit@claude-plugins-official`. Read React/Vue/CSS → `claude plugins install frontend-design@claude-plugins-official`. Read SQL/ORM → '
  if [ "$RC" -eq 0 ] && [[ "$(cat "$WORK/out")" == "$WANT"* ]]; then
    ok "D: the prompt line names its plugins in triggers.order"
  else
    bad "D: swapping two triggers.order values did not reorder the prompt line (rc=$RC): $(cut -c1-300 "$WORK/out")"
  fi
fi

# ── E. --write ───────────────────────────────────────────────────────────────────────
make_doc "$WORK/skeleton.md" auto empty
cp "$WORK/skeleton.md" "$WORK/skeleton.empty"
chmod 640 "$WORK/skeleton.md"
render --write "$WORK/skeleton.md"
if [ "$RC" -eq 0 ] && cmp -s "$WORK/skeleton.md" "$WORK/fresh-auto.md" && [[ "$(cat "$WORK/out")" == "wrote $WORK/skeleton.md (3 of 3 generated blocks changed)" ]]; then
  ok "E: --write fills three empty blocks and leaves every line of prose as it was"
else
  bad "E: --write on a skeleton (rc=$RC): $(cat "$WORK/out") ${ERR:0:200} $(diff "$WORK/fresh-auto.md" "$WORK/skeleton.md" 2>&1 | head -3 | cut -c1-160)"
fi
cp "$WORK/skeleton.md" "$WORK/skeleton.before"
render --write "$WORK/skeleton.md"
if [ "$RC" -eq 0 ] && cmp -s "$WORK/skeleton.md" "$WORK/skeleton.before" && [[ "$(cat "$WORK/out")" == "unchanged $WORK/skeleton.md (3 generated blocks current)" ]]; then
  ok "E: a second --write changes nothing"
else
  bad "E: a second --write (rc=$RC): $(cat "$WORK/out") ${ERR:0:200}"
fi
MODE="$("$PY" -I -c 'import os, sys; print(oct(os.stat(sys.argv[1]).st_mode & 0o777))' "$WORK/skeleton.md")"
# only a file that WAS rewritten says anything about the mode (a temp file is born 0600, the skeleton was 0640)
if [ "$MODE" = 0o640 ] && ! cmp -s "$WORK/skeleton.md" "$WORK/skeleton.empty"; then ok "E: the file mode survives the rewrite"; else bad "E: the mode of the rewritten file is $MODE, wanted 0o640 on a rewritten file"; fi

mkdir "$WORK/dir"
cp "$WORK/s-cell.md" "$WORK/dir/doc.md"
render --write "$WORK/dir/doc.md"
if [ "$RC" -eq 0 ] && cmp -s "$WORK/dir/doc.md" "$WORK/fresh-auto.md" && [ "$(ls -A "$WORK/dir")" = doc.md ]; then
  ok "E: --write repairs a stale block and leaves no temp file next to the doc"
else
  bad "E: --write on a stale doc (rc=$RC): ${ERR:0:200} dir holds: $(ls -A "$WORK/dir" | tr '\n' ' ')"
fi
make_doc "$WORK/ask-skeleton.md" ask empty
render --write "$WORK/ask-skeleton.md"
if [ "$RC" -eq 0 ] && cmp -s "$WORK/ask-skeleton.md" "$WORK/fresh-ask.md"; then
  ok "E: the flavour comes from each block's own marker"
else
  bad "E: --write of an ask skeleton (rc=$RC): ${ERR:0:200}"
fi

# ── F. fail closed ───────────────────────────────────────────────────────────────────
# the manifest side: every case is a VALID manifest (mutate checks), so the reason has to come from the renderer
mutate gap set-pointer slack "auto-install map row 8" "auto-install map row 10" && { render --manifest "$WORK/gap.json" --part auto-install
  expect "F: a gap in the row numbers is refused" 3 "row numbers must be 1..N"; }
mutate dup set-pointer seo "auto-install map row 2" "auto-install map row 1" && { render --manifest "$WORK/dup.json" --part auto-install
  expect "F: two entries on one row are refused" 3 "row numbers must be 1..N"; }
mutate badptr set-pointer frontend-design "auto-install map row 1" "table row 1" && { render --manifest "$WORK/badptr.json" --part mid-task
  expect "F: a plugin-autoinstall.md pointer it cannot place is refused, not skipped" 3 "unknown plugin-autoinstall.md pointer"; }
mutate off add-pointer caveman "auto-install map row 9" && { render --manifest "$WORK/off.json" --part auto-install
  expect "F: a row for an install:false entry is refused" 3 "caveman is install:false"; }
mutate kind add-pointer ui-ux-pro-max "auto-install map row 9" && { render --manifest "$WORK/kind.json" --part auto-install
  expect "F: a row for an entry that is not a plugin is refused" 3 "ui-ux-pro-max is not a plugin entry"; }
mutate notext add-pointer playwright "auto-install map row 9" && { render --manifest "$WORK/notext.json" --part auto-install
  expect "F: an entry with a row but no display text is refused, not guessed" 3 "no display text for playwright"; }
mutate twice add-pointer seo "auto-install map row 9" && { render --manifest "$WORK/twice.json" --part auto-install
  expect "F: one entry on two auto-install rows is refused" 3 "seo has more than one auto-install map row"; }
mutate sigs add-pointer seo "mid-task signal row 10" && { render --manifest "$WORK/sigs.json" --part mid-task
  expect "F: a mid-task row count that does not match the display texts is refused" 3 "seo has 2 mid-task signal rows"; }
mutate nodevops drop-entry devops-toolkit && { render --manifest "$WORK/nodevops.json" --part prompt
  expect "F: a prompt line whose plugin is not in the manifest is refused" 3 "no entry devops-toolkit"; }

"$PY" -I "$WORK/mutate.py" "$MANIFEST" "$WORK/schema2.json" set-top schema 2
render --manifest "$WORK/schema2.json" --part mid-task
expect "F: an invalid manifest is refused, with the validator's reason" 3 "is not a valid manifest"
render --manifest "$WORK/no-such-manifest.json" --part mid-task
expect "F: a missing manifest is refused" 3 "cannot read"
printf '{"schema": 1,\n' >"$WORK/torn.json"
render --manifest "$WORK/torn.json" --part mid-task
expect "F: a manifest that is not JSON is refused" 3 "not valid JSON"

# the doc side
doc_with() {  # NAME LINE... — a doc made of exactly these lines
  local name="$1"; shift
  printf '%s\n' "$@" >"$WORK/$name.md"
}
END='<!-- END GENERATED skills.manifest -->'
doc_with bare '<!-- BEGIN GENERATED skills.manifest -->' "$END"
render --check "$WORK/bare.md";       expect "F: a marker with no part= is refused" 3 "part=auto-install|mid-task|prompt"
doc_with badpart '<!-- BEGIN GENERATED skills.manifest part=nope -->' "$END"
render --check "$WORK/badpart.md";    expect "F: an unknown part is refused" 3 "part="
doc_with badflavour '<!-- BEGIN GENERATED skills.manifest part=mid-task flavour=loud -->' "$END"
render --check "$WORK/badflavour.md"; expect "F: an unknown flavour is refused" 3 "flavour="
doc_with twoparts '<!-- BEGIN GENERATED skills.manifest part=mid-task part=prompt -->' "$END"
render --check "$WORK/twoparts.md";   expect "F: a repeated attribute is refused" 3 "line 1"
doc_with garbled '<!-- BEGIN GENERATED skills.manifest part=mid-task and more -->' "$END"
render --check "$WORK/garbled.md";    expect "F: a marker with trailing junk is refused, not ignored" 3 "malformed"
doc_with noend '<!-- BEGIN GENERATED skills.manifest part=mid-task -->' 'a line'
render --check "$WORK/noend.md";      expect "F: a BEGIN with no END is refused" 3 "no END"
doc_with nobegin 'a line' "$END"
render --check "$WORK/nobegin.md";    expect "F: an END with no BEGIN is refused" 3 "without a BEGIN"
doc_with nested '<!-- BEGIN GENERATED skills.manifest part=mid-task -->' '<!-- BEGIN GENERATED skills.manifest part=prompt -->' "$END"
render --check "$WORK/nested.md";     expect "F: a BEGIN inside a block is refused" 3 "line 2"
doc_with none '# no markers here' 'just prose'
render --check "$WORK/none.md";       expect "F: a doc with no generated block is refused, not passed" 3 "no generated"
render --write "$WORK/none.md";       expect "F: --write refuses a doc with no block too" 3 "no generated"
render --check "$WORK/missing.md";    expect "F: a missing doc is refused" 3 "cannot read"
render --check "$WORK/dir";           expect "F: a directory is refused" 3 "cannot read"
printf '\xff\xfe not utf-8\n' >"$WORK/binary.md"
render --check "$WORK/binary.md";     expect "F: a doc that is not UTF-8 is refused" 3 "not UTF-8"

# ── G. usage ─────────────────────────────────────────────────────────────────────────
render;                                          expect "G: no mode is a usage error" 2 "usage:"
render --part nope;                              expect "G: an unknown part is a usage error" 2 "invalid choice"
render --check "$WORK/fresh-auto.md" --flavour ask; expect "G: --flavour with --check is a usage error (a block names its own flavour)" 2 "--flavour"
render --check "$WORK/fresh-auto.md" --write "$WORK/fresh-auto.md"; expect "G: --check and --write together are a usage error" 2 "not allowed with"

echo "--------------------------------------------------------------------"
printf 'skills-doc-render: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
