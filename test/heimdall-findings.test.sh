#!/usr/bin/env bash
#
# heimdall-findings.test.sh -- bin/heimdall-findings turns the "Release convergence" rules of CLAUDE.md into something a loop cannot skip.
#
#   bash test/heimdall-findings.test.sh    (exit 0 = all cases pass)
#
# THE DEFECT. 2.4.9 went through six fix -> finding -> fix rounds in one evening: the review was re-run on every fix and every MEDIUM finding was
# chased as if it blocked the release. The rules were written down (one review round per release, only BLOCKER/HIGH block, MEDIUM/LOW to the
# backlog) and prose did not hold. bin/heimdall-findings makes them mechanical:
#   review start --range <last release tag>..<head>   ONE round per release base; a second is refused (exit 3). HMD_REVIEW_AGAIN=1 overrides.
#   add --severity .. --title .. --where file:line    BLOCKER/HIGH stay open; MEDIUM/LOW are routed to .planning/BACKLOG.md under a dated
#                                                     "Deferred findings" heading and marked deferred
#   close <id> --commit <sha>  /  list [--open]  /  gate    gate exits non-zero (5) only while an open BLOCKER/HIGH exists for the current base
# and release/ship.sh runs the gate in its preflight: an open BLOCKER/HIGH refuses, MEDIUM/LOW never do, a repo with no store is unaffected.
#
# HOW IT IS PROVEN. Every case runs the REAL tool in a throwaway git repo (release tag v1.0.0, then commits). The ship cases copy the REAL
# release/ship.sh into a throwaway plugin-shaped repo: the preflight refuses on an open HIGH before anything is bumped, and a run that passes
# the gate is proven to have moved on by the refusal that comes LATER in the same preflight (`--version` equal to the current version: "nothing to
# bump"), so no bump, push or publish is ever reached; gh and gitleaks are stubs on PATH. A link anywhere on the way down (.heimdall, .heimdall/findings, the store file,
# .planning, .planning/BACKLOG.md) is refused with exit 4 and nothing outside the repo is touched.
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SELF_DIR/.." && pwd)"
FINDINGS="$REPO/bin/heimdall-findings"
SHIP="$REPO/release/ship.sh"

PASS=0; FAIL=0
ok()  { printf '  \033[32mPASS\033[0m %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAIL=$((FAIL+1)); }

if ! command -v jq >/dev/null 2>&1 || ! command -v git >/dev/null 2>&1 || ! command -v python3 >/dev/null 2>&1; then
  echo "FATAL: jq, git and python3 are required" >&2; exit 2
fi

# shellcheck source=lib/private-tmp.sh disable=SC1091
. "$SELF_DIR/lib/private-tmp.sh" && hmd_private_tmp heimdall-findings || exit 1
WORK="$HMD_PRIVATE_TMP"

# Nothing from the developer's git configuration or environment may reach the throwaway repos.
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR GIT_PREFIX HMD_REVIEW_AGAIN \
      GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null

# ── helpers ───────────────────────────────────────────────────────────────────
OUT=""; RC=0
show() { printf '%s\n' "$OUT" | tail -n 8 | sed 's/^/      | /' >&2; }
# fnd <dir> <args...> -- run the tool from <dir>; its output (both streams) lands in OUT, its exit status in RC
fnd() { local d="$1"; shift; OUT="$(cd "$d" && "$FINDINGS" "$@" 2>&1)"; RC=$?; }
rc_is()  { if [ "$RC" -eq "$2" ]; then ok "$1 (exit $RC)"; else bad "$1: wanted exit $2, got $RC"; show; fi; }
say()    { case "$OUT" in *"$2"*) ok "$1: says '$2'" ;; *) bad "$1: the output lacks '$2'"; show ;; esac; }
no_say() { case "$OUT" in *"$2"*) bad "$1: the output must not say '$2'"; show ;; *) ok "$1: does not say '$2'" ;; esac; }
count_in() { grep -c -E -- "$1" "$2" 2>/dev/null || true; }          # <extended regex> <file> -> number of matching lines
heading_above() { awk -v pat="$2" 'index($0, pat) && !done { print last; done = 1 } /^#/ { last = $0 }' "$1"; }   # <file> <text> -> the heading the first line holding <text> sits under
is() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1: wanted '$3', got '$2'"; fi; }
first_store() { local f; for f in "$1"/.heimdall/findings/*.ndjson; do printf '%s' "$f"; return 0; done; return 1; }   # <repo> -> the path of its first store file
count_entries() { find "$1" -mindepth 1 2>/dev/null | wc -l | tr -d ' '; }                                          # <dir> -> how many entries it holds

# mkrepo <dir> -- a repo whose last release is the tag v1.0.0, with two commits after it and a BACKLOG.md that already holds text
mkrepo() {
  local d="$1"
  { mkdir -p "$d" && git init -q "$d" 2>/dev/null && git -C "$d" symbolic-ref HEAD refs/heads/main \
    && git -C "$d" config user.email "t@example.com" && git -C "$d" config user.name "T" && git -C "$d" config commit.gpgsign false \
    && printf '.heimdall/\n' > "$d/.gitignore" && printf 'one\n' > "$d/f.txt" \
    && git -C "$d" add -A && git -C "$d" commit -q -m "chore: v1.0.0" && git -C "$d" tag v1.0.0 \
    && mkdir -p "$d/.planning" && printf '# BACKLOG\n\n## 2026-10-14: an older section\n\n- [ ] an older item\n' > "$d/.planning/BACKLOG.md" \
    && printf 'two\n' >> "$d/f.txt" && git -C "$d" add -A && git -C "$d" commit -q -m "feat: two" \
    && printf 'three\n' >> "$d/f.txt" && git -C "$d" commit -q -am "feat: three"; } \
    || { echo "FATAL: could not build the fixture repo $d" >&2; exit 2; }
}

# ── [1] review start: ONE round per release base ──────────────────────────────
echo "[1] review start: one round per release base"
R="$WORK/r"; mkrepo "$R"
fnd "$R" gate;                                  rc_is "gate with no store at all" 0; say "no store" "gate not applied"
fnd "$WORK" gate;                               rc_is "gate outside any repository" 2; say "no repo" "not inside a git work tree"
fnd "$R" gate --repo "$WORK/nope";              rc_is "--repo that is no directory" 2
fnd "$R" review start --range "v1.0.0";         rc_is "a range with no .." 2
fnd "$R" review start --range "v1.0.0...HEAD";  rc_is "a three-dot range" 2
fnd "$R" review start --range "..HEAD";         rc_is "a range with no base" 2
fnd "$R" list;                                  rc_is "list with no store" 0; say "empty list" "no findings recorded for v1.0.0"
N="$WORK/notag"; mkrepo "$N"; git -C "$N" tag -d v1.0.0 >/dev/null
fnd "$N" gate;                                  rc_is "gate in a repo with no release tag" 0; say "no tag" "no release tag"
fnd "$N" list;                                  rc_is "list in a repo with no release tag" 0
fnd "$N" add --severity HIGH --title t --where w:1; rc_is "add in a repo with no release tag has no base to record against" 2; say "no tag" "no release tag"
fnd "$R" review start --range "nope..HEAD";     rc_is "a base that is no commit" 2
fnd "$R" review start --range "HEAD..v1.0.0";   rc_is "a range that runs backwards" 2; say "backwards" "is not an ancestor"
fnd "$R" review start --range "HEAD~1..HEAD";   rc_is "a base that is not the last release tag" 2; say "narrow base" "v1.0.0"
if [ -z "$(ls -A "$R/.heimdall" 2>/dev/null)" ]; then ok "the refused starts wrote nothing"; else bad "a refused start wrote something under .heimdall"; fi
fnd "$R" review start --range "v1.0.0..HEAD";   rc_is "the first review of the base" 0
fnd "$R" review start --range "v1.0.0..HEAD";   rc_is "a SECOND review of the same base is refused" 3
say "second review" "already reviewed for v1.0.0"
say "second review" "fixes are proven by their own RED→GREEN tests, not re-review"
HMD_REVIEW_AGAIN=0 fnd "$R" review start --range "v1.0.0..HEAD"; rc_is "HMD_REVIEW_AGAIN=0 is not the override" 3
HMD_REVIEW_AGAIN=yes fnd "$R" review start --range "v1.0.0..HEAD"; rc_is "HMD_REVIEW_AGAIN=yes is not the override" 3
HMD_REVIEW_AGAIN=1 fnd "$R" review start --range "v1.0.0..HEAD"; rc_is "HMD_REVIEW_AGAIN=1 records another round" 0; say "override" "round 2"
fnd "$R" review start --range "v1.0.0..HEAD";   rc_is "the override covers one call, not the base" 3

# ── [2] add: BLOCKER/HIGH stay open, MEDIUM/LOW go to the backlog ─────────────
echo "[2] add: routing"
BL="$R/.planning/BACKLOG.md"; cp "$BL" "$WORK/backlog.before"; BEFORE_BYTES="$(wc -c < "$WORK/backlog.before" | tr -d ' ')"
fnd "$R" add --severity HIGH --title "unsafe temp file" --where "bin/x.sh:12";   rc_is "add HIGH" 0; say "add HIGH" "F1"
is "a HIGH finding is not routed to the backlog" "$(cmp -s "$WORK/backlog.before" "$BL" && echo same || echo changed)" same
fnd "$R" add --severity HIGH --title "unsafe temp file" --where "bin/x.sh:12";   rc_is "the same HIGH again" 0; say "dedup" "already recorded as F1"
fnd "$R" add --severity BLOCKER --title "data loss on resume" --where "lib/y.py:5" --source security-bot; rc_is "add BLOCKER" 0; say "add BLOCKER" "F2"
fnd "$R" add --severity MEDIUM --title "slow path in the report" --where "bin/z:40";  rc_is "add MEDIUM" 0; say "add MEDIUM" "F3"
fnd "$R" add --severity low --title "typo in a help line" --where "bin/z:41" --source agent; rc_is "add low (any case)" 0
is "MEDIUM is one bullet in the backlog" "$(count_in 'MEDIUM: slow path in the report' "$BL")" 1
is "LOW is one bullet in the backlog" "$(count_in 'LOW: typo in a help line' "$BL")" 1
is "one dated Deferred findings heading holds both" "$(count_in '^## Deferred findings \([0-9]{4}-[0-9]{2}-[0-9]{2}\)$' "$BL")" 1
case "$(heading_above "$BL" "slow path in the report")" in "## Deferred findings ("*) ok "the MEDIUM bullet sits under the Deferred findings heading" ;; *) bad "the MEDIUM bullet is not under a Deferred findings heading" ;; esac
is "the text that was there is untouched (the tool only appends)" "$(head -c "$BEFORE_BYTES" "$BL" | cmp -s - "$WORK/backlog.before" && echo same || echo changed)" same
is "no HIGH or BLOCKER line reached the backlog" "$(count_in 'unsafe temp file|data loss on resume' "$BL")" 0
fnd "$R" add --severity MEDIUM --title "slow path in the report" --where "bin/z:40";  rc_is "the same MEDIUM again" 0; say "dedup MEDIUM" "already recorded as F3"
is "a repeated MEDIUM adds no second bullet" "$(count_in 'slow path in the report' "$BL")" 1
fnd "$R" add --severity MEDIUM --title $'two\n## Injected heading' --where "a:1";  rc_is "a title with a newline and a heading in it" 0
is "a newline in a title is collapsed: one bullet line holds the whole title" "$(count_in 'MEDIUM: two ## Injected heading' "$BL")" 1
is "the injected text is not a heading" "$(count_in '^#+ .*Injected' "$BL")" 0
printf '\n## A human section\n\n- [ ] a human item\n' >> "$BL"
fnd "$R" add --severity LOW --title "after the human section" --where "a:2"; rc_is "a LOW after a human section" 0
is "a new dated heading is opened below the human section" "$(count_in '^## Deferred findings \(' "$BL")" 2
case "$(heading_above "$BL" "after the human section")" in "## Deferred findings ("*) ok "the late bullet is under a Deferred findings heading, not the human section" ;; *) bad "the late bullet landed under another section" ;; esac
fnd "$R" add --severity URGENT --title t --where w;       rc_is "an unknown severity" 2
fnd "$R" add --severity HIGH --title "   " --where w;      rc_is "a blank title" 2
fnd "$R" add --severity HIGH --title t;                    rc_is "no --where" 2
fnd "$R" add --severity HIGH --title t --where w --source oracle; rc_is "an unknown source" 2

# ── [3] list, gate, close ─────────────────────────────────────────────────────
echo "[3] list / gate / close"
fnd "$R" list --open
rc_is "list --open" 0; say "open list" "unsafe temp file"; say "open list" "data loss on resume"
no_say "open list" "slow path in the report"; no_say "open list" "typo in a help line"
fnd "$R" list; rc_is "list" 0; say "list" "deferred"; say "list" "security-bot"; say "list" "slow path in the report"
fnd "$R" gate; rc_is "gate is RED while a HIGH and a BLOCKER are open" 5; say "red gate" "unsafe temp file"; say "red gate" "data loss on resume"
HEAD_SHA="$(git -C "$R" rev-parse HEAD)"
fnd "$R" close F9 --commit "$HEAD_SHA";       rc_is "close an id that does not exist" 2
fnd "$R" close F1 --commit "deadbeef";        rc_is "close with a commit that is not one" 2
fnd "$R" close F1;                              rc_is "close with no --commit" 2
fnd "$R" close banana --commit "$HEAD_SHA";   rc_is "close with an id that is not an id" 2
fnd "$R" gate; rc_is "a refused close leaves the gate RED" 5
fnd "$R" close F1 --commit "$HEAD_SHA";       rc_is "close F1 with a real commit" 0
fnd "$R" close F1 --commit "$HEAD_SHA";       rc_is "closing F1 again with the same commit is idempotent" 0
fnd "$R" close F1 --commit "$(git -C "$R" rev-parse HEAD~1)"; rc_is "closing F1 again with ANOTHER commit is refused" 2
fnd "$R" gate; rc_is "gate stays RED while the BLOCKER is open" 5; no_say "red gate" "unsafe temp file"; say "red gate" "data loss on resume"
fnd "$R" close F2 --commit "$HEAD_SHA";       rc_is "close the BLOCKER" 0
fnd "$R" gate; rc_is "gate is GREEN with only deferred findings left" 0; say "green gate" "no open BLOCKER/HIGH"
fnd "$R" list --open; no_say "open list after the closes" "F1"; no_say "open list after the closes" "F2"
fnd "$R" list; say "list" "closed"; say "list" "${HEAD_SHA:0:12}"
fnd "$R" close F3 --commit "$HEAD_SHA";       rc_is "a deferred MEDIUM can be closed once its fix is written" 0
fnd "$R" add --severity HIGH --title "found late" --where "q:1"; rc_is "a HIGH found after the round" 0
fnd "$R" gate; rc_is "gate RED again for the late HIGH" 5
git -C "$R" tag v1.1.0
fnd "$R" gate; rc_is "gate is about the CURRENT release base: after a new release tag the old base's open HIGH does not apply" 0; say "new base" "gate not applied"
fnd "$R" add --severity HIGH --title "next release finding" --where "q:2"; rc_is "findings of the next release get their own store" 0
git -C "$R" tag -d v1.1.0 >/dev/null
fnd "$R" gate; rc_is "with the old base current again its HIGH blocks again" 5; say "old base" "found late"; no_say "old base" "next release finding"
fnd "$WORK" gate --repo "$R"; rc_is "--repo names the repository from anywhere" 5; say "--repo" "found late"
C="$WORK/corrupt"; mkrepo "$C"; fnd "$C" add --severity HIGH --title seed --where w:1; rc_is "corrupt-store fixture: a store" 0
printf 'garbage that is not json\n' >> "$(first_store "$C")"
fnd "$C" gate; rc_is "a corrupt store is never read as empty: gate exits non-zero" 1; say "corrupt gate" "corrupt"
fnd "$C" list; rc_is "a corrupt store: list fails too" 1
fnd "$C" add --severity HIGH --title t --where w:2; rc_is "a corrupt store: add fails too" 1

# ── [4] a link anywhere on the way down is refused, nothing outside is touched ─
echo "[4] links are refused (exit 4)"
mkdir -p "$WORK/out-a" "$WORK/out-b"
L="$WORK/lnk-a"; mkrepo "$L"; mkdir -p "$L/.heimdall"; ln -s "$WORK/out-a" "$L/.heimdall/findings"
fnd "$L" add --severity HIGH --title t --where w:1; rc_is "add through a symlinked .heimdall/findings" 4
fnd "$L" gate;                                       rc_is "gate through a symlinked findings dir is refused, never green" 4
fnd "$L" list;                                       rc_is "list through a symlinked findings dir" 4
fnd "$L" review start --range "v1.0.0..HEAD";        rc_is "review start through a symlinked findings dir" 4
is "nothing was written through the findings link" "$(count_entries "$WORK/out-a")" 0
L="$WORK/lnk-b"; mkrepo "$L"; ln -s "$WORK/out-b" "$L/.heimdall"
fnd "$L" add --severity HIGH --title t --where w:1; rc_is "add through a symlinked .heimdall" 4
is "nothing was written through the .heimdall link" "$(count_entries "$WORK/out-b")" 0
L="$WORK/lnk-c"; mkrepo "$L"; fnd "$L" add --severity HIGH --title seed --where w:1; rc_is "seed a store" 0
LSTORE="$(first_store "$L")"; rm -f "$LSTORE"
printf 'keep me\n' > "$WORK/out-c.txt"; ln -s "$WORK/out-c.txt" "$LSTORE"
fnd "$L" add --severity HIGH --title t --where w:1; rc_is "add through a symlinked store file" 4
fnd "$L" gate;                                       rc_is "gate through a symlinked store file" 4
is "the file the store link points at is untouched" "$(cat "$WORK/out-c.txt")" "keep me"
rm -f "$LSTORE"; ln -s "$WORK/dangling-target" "$LSTORE"
fnd "$L" add --severity HIGH --title t --where w:1; rc_is "add through a DANGLING store link" 4
if [ ! -e "$WORK/dangling-target" ]; then ok "a dangling link's target was not created"; else bad "a dangling link's target was created through the link"; fi
L="$WORK/lnk-f"; mkrepo "$L"; mkdir -p "$L/.heimdall/findings/$(git -C "$L" rev-parse 'v1.0.0^{commit}').ndjson"
fnd "$L" gate; rc_is "gate when the store's name is a directory, not a regular file" 4
L="$WORK/lnk-d"; mkrepo "$L"; printf 'keep me too\n' > "$WORK/out-d.md"; rm -f "$L/.planning/BACKLOG.md"; ln -s "$WORK/out-d.md" "$L/.planning/BACKLOG.md"
fnd "$L" add --severity MEDIUM --title "routed through a link" --where w:1; rc_is "a MEDIUM whose BACKLOG.md is a symlink is refused" 4
is "the file the BACKLOG link points at is untouched" "$(cat "$WORK/out-d.md")" "keep me too"
fnd "$L" list; no_say "refused routing" "routed through a link"
L="$WORK/lnk-e"; mkrepo "$L"; mkdir -p "$WORK/out-e"; rm -rf "$L/.planning"; ln -s "$WORK/out-e" "$L/.planning"
fnd "$L" add --severity LOW --title "routed through a link" --where w:1; rc_is "a LOW whose .planning is a symlink is refused" 4
is "nothing was written through the .planning link" "$(count_entries "$WORK/out-e")" 0

# ── [5] one store per repository, shared by every worktree ────────────────────
echo "[5] worktrees share the store"
W="$WORK/wt"; git -C "$R" worktree add -q "$W" -b wt-branch 2>/dev/null || { echo "FATAL: git worktree add failed" >&2; exit 2; }
fnd "$W" add --severity HIGH --title "found from a worktree" --where "w:1"; rc_is "add from a linked worktree" 0
fnd "$R" list --open; say "main checkout sees it" "found from a worktree"
if [ ! -e "$W/.heimdall" ]; then ok "nothing was written under the worktree's own .heimdall"; else bad "the worktree got its own .heimdall"; fi
fnd "$W" add --severity MEDIUM --title "deferred from a worktree" --where "w:2"; rc_is "a MEDIUM from a worktree" 0
is "its backlog line went to the main checkout's BACKLOG.md" "$(count_in 'deferred from a worktree' "$BL")" 1
is "and the worktree's copy is untouched" "$(count_in 'deferred from a worktree' "$W/.planning/BACKLOG.md")" 0

# ── [6] the agent instructions point at the tool ──────────────────────────────
echo "[6] agent docs"
for f in agents/heimdall.md agents/reviewer.md; do
  if grep -q 'heimdall-findings add' "$REPO/$f"; then ok "$f tells reviewers to record findings with heimdall-findings add"; else bad "$f does not mention heimdall-findings add"; fi
done
if grep -q 'heimdall-findings list --open' "$REPO/agents/heimdall.md"; then ok "agents/heimdall.md spawns fix agents from heimdall-findings list --open"; else bad "agents/heimdall.md does not mention heimdall-findings list --open"; fi

# ── [7] release/ship.sh refuses on an open HIGH, before anything is bumped ────
echo "[7] release script preflight"
STUB="$WORK/stub"; mkdir -p "$STUB"
printf '#!/usr/bin/env bash\nexit 0\n' > "$STUB/gh"; cp "$STUB/gh" "$STUB/gitleaks"; chmod +x "$STUB/gh" "$STUB/gitleaks"

# mkship <dir> <manifest version> -- a repo shaped like the plugin repo as far as the release preflight reads it: the real release script, the findings tool,
# the last release tagged v9.9.9, a change after it, and a green FULL sweep receipt for HEAD (the check that comes right before the findings gate).
mkship() {
  local d="$1" ver="$2"
  { mkdir -p "$d/release" "$d/bin/lib" "$d/.claude-plugin" \
    && cp "$SHIP" "$d/release/ship.sh" && cp "$FINDINGS" "$d/bin/heimdall-findings" \
    && cp "$REPO/bin/lib/hmd_findings.py" "$REPO/bin/lib/hmd_nofollow_write.py" "$d/bin/lib/" \
    && printf '#!/usr/bin/env bash\necho "- a change"\n' > "$d/bin/generate-changelog" \
    && chmod +x "$d/release/ship.sh" "$d/bin/heimdall-findings" "$d/bin/generate-changelog" \
    && printf '.heimdall/\n' > "$d/.gitignore" \
    && jq -n '{name:"heimdall", version:"9.9.9"}' > "$d/.claude-plugin/plugin.json" \
    && git init -q "$d" 2>/dev/null && git -C "$d" symbolic-ref HEAD refs/heads/main \
    && git -C "$d" config user.email "t@example.com" && git -C "$d" config user.name "T" && git -C "$d" config commit.gpgsign false \
    && git -C "$d" add -A && git -C "$d" commit -q -m "chore: initial" && git -C "$d" tag v9.9.9 \
    && printf 'echo feature\n' > "$d/bin/feature.sh" && git -C "$d" add -A && git -C "$d" commit -q -m "feat: a change" \
    && git -C "$d" remote add origin "$d.nowhere.git"; } || { echo "FATAL: could not build the ship fixture $d" >&2; exit 2; }
  if [ "$ver" != "9.9.9" ]; then   # the bump commit of a release whose tag was never made
    { jq -n --arg v "$ver" '{name:"heimdall", version:$v}' > "$d/.claude-plugin/plugin.json" \
      && git -C "$d" commit -q -am "chore(release): v$ver"; } || { echo "FATAL: could not make the bump commit in $d" >&2; exit 2; }
  fi
  { mkdir -p "$d.home/receipts" \
    && jq -n --arg repo "$(git -C "$d" rev-parse --show-toplevel)" --arg head "$(git -C "$d" rev-parse HEAD)" \
         '{finished_at:"2026-10-21T00:00:00Z", repo:$repo, head_sha:$head, tree_clean:true, exit_code:0, kind:"full", suites_total:1, suites_passed:1, suites_failed:0}' \
         > "$d.home/receipts/last-full-green.json"; } || { echo "FATAL: could not write the receipt for $d" >&2; exit 2; }
}
# run_ship <dir> <ship args...> -- output in <dir>.out, status in SRC
SRC=0
run_ship() {
  local d="$1"; shift
  ( cd "$d" && PATH="$STUB:$PATH" HEIMDALL_HOME="$d.home" TMPDIR="$WORK" bash release/ship.sh "$@" ) > "$d.out" 2>&1; SRC=$?
}
ship_says()    { if grep -Fq -- "$2" "$S.out"; then ok "$1: says '$2'"; else bad "$1: the run does not say '$2'"; tail -n 8 "$S.out" | sed 's/^/      | /' >&2; fi; }
ship_no_say()  { if grep -Fq -- "$2" "$S.out"; then bad "$1: the run must not say '$2'"; tail -n 8 "$S.out" | sed 's/^/      | /' >&2; else ok "$1: does not say '$2'"; fi; }

S="$WORK/ship"; mkship "$S" 9.9.9
SHIP_HEAD="$(git -C "$S" rev-parse HEAD)"
fnd "$S" review start --range "v9.9.9..HEAD"; rc_is "ship fixture: the one review round" 0
fnd "$S" add --severity HIGH --title "unsafe temp file" --where "bin/x.sh:12"; rc_is "ship fixture: an open HIGH" 0
fnd "$S" add --severity MEDIUM --title "slow report" --where "bin/z:40";       rc_is "ship fixture: a MEDIUM beside it" 0
# `--version 9.9.9` is the current version: a run that gets past the gate dies on "nothing to bump" later in the same preflight, before anything is bumped
run_ship "$S" --no-npm --version 9.9.9
if [ "$SRC" -ne 0 ]; then ok "an open HIGH: the release script refuses (exit $SRC)"; else bad "an open HIGH did not stop the release script"; fi
ship_says "open HIGH" "findings gate"; ship_says "open HIGH" "unsafe temp file"; ship_no_say "open HIGH" "slow report"; ship_no_say "open HIGH" "nothing to bump"
is "the refused run bumped nothing" "$(git -C "$S" rev-parse HEAD)" "$SHIP_HEAD"
fnd "$S" close F1 --commit "$SHIP_HEAD"; rc_is "ship fixture: close the HIGH" 0
run_ship "$S" --no-npm --version 9.9.9
ship_says "closed HIGH, MEDIUM still deferred" "no open BLOCKER/HIGH"; ship_says "closed HIGH, MEDIUM still deferred" "nothing to bump"
ship_no_say "closed HIGH, MEDIUM still deferred" "findings gate is not green"

S="$WORK/ship-nostore"; mkship "$S" 9.9.9
run_ship "$S" --no-npm --version 9.9.9
ship_says "no store for the base" "gate not applied"; ship_says "no store for the base" "nothing to bump"; ship_no_say "no store for the base" "findings gate is not green"

S="$WORK/ship-ro"; mkship "$S" 9.9.10
fnd "$S" add --severity BLOCKER --title "tag made over a blocker" --where "bin/x.sh:1"; rc_is "release-only fixture: an open BLOCKER" 0
run_ship "$S" --release-only
if [ "$SRC" -ne 0 ]; then ok "an open BLOCKER: --release-only, which would create the tag, refuses (exit $SRC)"; else bad "--release-only created a release over an open BLOCKER"; fi
ship_says "release-only" "tag made over a blocker"
if git -C "$S" rev-parse -q --verify refs/tags/v9.9.10 >/dev/null 2>&1; then bad "--release-only made the tag over an open BLOCKER"; else ok "no tag was made"; fi

echo ""
echo "heimdall-findings.test.sh: $PASS passed, $FAIL failed."
[ "$FAIL" -eq 0 ]
