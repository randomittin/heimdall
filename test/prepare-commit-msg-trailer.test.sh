#!/usr/bin/env bash
# test/prepare-commit-msg-trailer.test.sh — mechanical hmd co-author trailer.
#
# WHAT THIS GATES. `hmd init` generates .heimdall/hooks/prepare-commit-msg, which
# appends `Co-Authored-By: runhmd <318965969+runhmd@users.noreply.github.com>` to
# every commit message that doesn't already carry it (CLAUDE.md "Commit
# attribution"). This exists because prose alone failed: agents were told to add
# the trailer in every spawn prompt and still didn't (measured baseline: 55/81
# commits since 2026-08-18 had it, 26 did not) — the same class of gap that only a
# mechanical PreToolUse hook closed for "commit early" (bin/heimdall-wip-commit).
# This is that fix for attribution. The hook also STRIPS two things first (owner
# directive, 2026-08-20 — see CLAUDE.md "Commit attribution"): any Anthropic/model
# Co-Authored-By trailer, matched by email DOMAIN so a real human co-author is
# never caught by it; and any OLD-form hmd trailer (`hmd@runheimdall.dev`, retired
# when the `runhmd` GitHub account was created), matched by the exact old address
# so it never touches a different real teammate who might share the domain.
#
# WHY prepare-commit-msg AND NOT pre-commit/commit-msg. Verified empirically (not
# assumed): `git commit --no-verify` skips pre-commit and commit-msg but does NOT
# skip prepare-commit-msg. Agents in this repo commit with --no-verify (see
# bin/heimdall-wip-commit, CLAUDE.md "Pre-commit vs pre-push"), so any hook that
# --no-verify skips would never fire for the commits this feature most needs to
# reach. Section 5 below is the regression lock on this exact property.
#
# GUARANTEES PROVED (hermetic — own throwaway git repo per section, HOME
# redirected, no network):
#   1. INSTALL             — hmd init generates an executable, syntactically valid hook.
#   2/3. ADDED / NOT DUPLICATED — a plain commit gets the trailer appended; a
#                          commit that already carries it is left with exactly one.
#   4. MODEL TRAILER STRIPPED — an Anthropic/model Co-Authored-By (matched by
#                          @anthropic.com, never by the model's display name) is
#                          removed and the hmd trailer added in its place (owner
#                          directive, 2026-08-20 — CLAUDE.md "Commit attribution";
#                          REVERSES the "kept alongside" behavior this item used
#                          to describe).
#   4b. STRIPPED EVEN WHEN HMD ALREADY PRESENT — the strip is unconditional, not
#                          gated behind the idempotent-add check, so a message
#                          that already carries the hmd trailer still loses a
#                          stray model trailer alongside it.
#   5. --no-verify         — the trailer still lands under --no-verify (the whole
#                          reason this hook was chosen over pre-commit/commit-msg).
#   6. MERGE SAFE          — a real --no-ff merge commit keeps "Merge branch ..."
#                          and gains exactly one trailer.
#   7. SQUASH SAFE         — a squash-merge commit is handled the same way.
#   8. AMEND SAFE          — amending a commit that already has the trailer (added
#                          by this same hook) never duplicates it.
#   9. CHAINING            — a repo's own pre-existing prepare-commit-msg still
#                          runs, first; removing the chain pointer stops it (the
#                          falsifier proving the chain is real, not coincidental).
#  10. HMD_SKIP NOT CONSULTED — the trailer is added even under HMD_SKIP=1: an
#                          attribution trailer is not a quality gate.
#  11. FAIL OPEN           — no args, a nonexistent path, and an unwritable file
#                          with real content all exit 0, with the message (where it
#                          exists) byte-for-byte UNCHANGED. Malformed input must
#                          never be the reason a commit — or its content — is lost.
#  12. EMPTY-MESSAGE ABORT PATH PROTECTED — a comment-only message (what git shows
#                          before the user types anything) is left untouched, so a
#                          blank-to-abort commit still aborts.
#  13. NO TRAILING NEWLINE — a message with no final newline still gets exactly
#                          one well-formed trailer line, not a welded-together one.
#  14. HUMAN CO-AUTHOR PRESERVED — a real, non-model Co-Authored-By is never
#                          stripped: matching is by email domain, not by name, so
#                          a genuine human collaborator is never caught by it.
#  15. STRIPPING IS IDEMPOTENT — a second run over an already-stripped message
#                          changes nothing, byte-for-byte.
#  16. OLD-ADDRESS NORMALIZED — a message with the retired `hmd@runheimdall.dev`
#                          trailer ends up with the new `runhmd` GitHub-account
#                          trailer in its place, never both.
#  17. OLD+NEW BOTH PRESENT COLLAPSES TO ONE — a message that already has BOTH
#                          forms (e.g. hand-written) loses the old one and keeps
#                          exactly one trailer, the new one.
#  18. OLD-ADDRESS NORMALIZATION IS IDEMPOTENT — a second run over an
#                          already-normalized message changes nothing.
#  19. EXACT NEW ADDRESS PINNED — a hardcoded literal, independent of this
#                          suite's own $TRAILER variable, so a future edit that
#                          silently changes the address (in either the hook or
#                          this suite) fails instead of quietly agreeing with
#                          itself.
#
# FALSIFIABILITY (proof quoted in the implementing commit, not re-asserted here):
# the idempotency check (`grep -qiF "$TRAILER"`) was mutated to compare against a
# deliberately wrong string, which turned sections 3/8 red (duplicate trailers) —
# then reverted back to green. The strip step (section 4) has its own falsifier:
# ANTHROPIC_RE was mutated to an unmatchable pattern, which turned section 4 red
# (model trailer no longer stripped) — then reverted back to green. The
# old-address strip step (section 16/17) has the same falsifier shape:
# OLD_HMD_RE was mutated to an unmatchable pattern, which turned 16/17 red (old
# trailer no longer normalized away) — then reverted back to green. See the
# implementing commit message(s) for the exact PASS/FAIL counts both directions.
#
# NOT RETROACTIVE. History predating this hook is untouched by design — rewriting
# ~195 already-made commits would change every SHA (CLAUDE.md "Commit
# attribution"). This suite only proves the hook is correct GOING FORWARD. Same
# for the 2026-08-20 address rename: commits already made with the OLD
# `hmd@runheimdall.dev` trailer keep it, unrewritten; only new commits, and
# messages passed through the hook again, get normalized.
#
# EXIT: 0 = every proof holds; 1 = any FAIL.
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SELF_DIR/.." && pwd)"
BIN="$REPO/bin"
INIT_BIN="$BIN/heimdall-init"

# post-commit (installed alongside prepare-commit-msg by the same `hmd init` call)
# shells the REAL heimdall-presence beat. Pin the default control-plane URL to a
# dead local port so a fresh/undecided HOME under this test can never reach prod.
. "$REPO/test/lib/net-default-guard.sh"

[ -x "$INIT_BIN" ] || { echo "FATAL: missing/!exec $INIT_BIN" >&2; exit 2; }
command -v git >/dev/null 2>&1 || { echo "FATAL: git not found" >&2; exit 2; }
command -v awk >/dev/null 2>&1 || { echo "FATAL: awk not found" >&2; exit 2; }

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf "  \033[32mPASS\033[0m %s\n" "$1"; }
bad() { FAIL=$((FAIL+1)); printf "  \033[31mFAIL\033[0m %s\n" "$1"; [ -n "${2:-}" ] && printf '        %s\n' "$2" >&2; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/hmd-pcm.XXXXXX")"
cleanup() { rm -rf "$WORK" 2>/dev/null || true; }
trap cleanup EXIT
export HOME="$WORK/home"; mkdir -p "$HOME/.heimdall"
export HEIMDALL_NO_TEAM_AUTOSHARE=1

TRAILER='Co-Authored-By: runhmd <318965969+runhmd@users.noreply.github.com>'
OLD_TRAILER='Co-Authored-By: hmd <hmd@runheimdall.dev>'

gitcfg() { git -C "$1" config user.email dev@example.com; git -C "$1" config user.name Dev; }
newrepo() { mkdir -p "$1"; git -C "$1" init -q; gitcfg "$1"; }
hmdinit() { ( cd "$1" && "$INIT_BIN" --no-cursor-statusline >/dev/null 2>&1 ); }
trailer_count_commit() { git -C "$1" log -1 --format=%B 2>/dev/null | grep -Fc "$TRAILER"; }
trailer_count_file() { grep -Fc "$TRAILER" "$1" 2>/dev/null; }

echo "════════════════════════════════════════════════════════════════"
echo "prepare-commit-msg — mechanical hmd co-author trailer"
echo "════════════════════════════════════════════════════════════════"

# ══════════════════════════════════════════════════════════════════════════════
# 1. INSTALL
# ══════════════════════════════════════════════════════════════════════════════
R1="$WORK/r1"; newrepo "$R1"; hmdinit "$R1"
HOOK1="$R1/.heimdall/hooks/prepare-commit-msg"
[ -x "$HOOK1" ] && ok "1a prepare-commit-msg installed and executable" || bad "1a missing/not executable" "$HOOK1"
bash -n "$HOOK1" 2>"$WORK/synerr.txt" && ok "1b generated hook is syntactically valid bash" || bad "1b bash -n failed" "$(cat "$WORK/synerr.txt" 2>/dev/null)"

# ══════════════════════════════════════════════════════════════════════════════
# 2/3. ADDED WHEN ABSENT, then NOT DUPLICATED WHEN ALREADY PRESENT
# ══════════════════════════════════════════════════════════════════════════════
R2="$WORK/r2"; newrepo "$R2"; hmdinit "$R2"
printf 'one\n' > "$R2/f.txt"; git -C "$R2" add f.txt
git -C "$R2" commit -q -m "first commit" >/dev/null 2>&1
[ "$(trailer_count_commit "$R2")" = "1" ] && ok "2a trailer appended to a plain commit" || bad "2a trailer not exactly once" "count=$(trailer_count_commit "$R2")"
git -C "$R2" log -1 --format=%s | grep -qF "first commit" && ok "2b subject preserved" || bad "2b subject lost"

printf 'two\n' > "$R2/g.txt"; git -C "$R2" add g.txt
git -C "$R2" commit -q -m "second commit" -m "$TRAILER" >/dev/null 2>&1
[ "$(trailer_count_commit "$R2")" = "1" ] && ok "3a trailer NOT duplicated when author already included it" || bad "3a duplicated" "count=$(trailer_count_commit "$R2")"

# ══════════════════════════════════════════════════════════════════════════════
# 4. MODEL/ANTHROPIC TRAILER STRIPPED — hmd trailer added in its place
# ══════════════════════════════════════════════════════════════════════════════
R4="$WORK/r4"; newrepo "$R4"; hmdinit "$R4"
printf 'x\n' > "$R4/f.txt"; git -C "$R4" add f.txt
git -C "$R4" commit -q -m "add feature" -m "Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>" >/dev/null 2>&1
BODY4="$(git -C "$R4" log -1 --format=%B)"
printf '%s' "$BODY4" | grep -qF "anthropic.com" && bad "4a model trailer NOT stripped" "$BODY4" || ok "4a model trailer stripped"
printf '%s' "$BODY4" | grep -qF "$TRAILER" && ok "4b hmd trailer added in its place" || bad "4b hmd trailer missing" "$BODY4"
[ "$(trailer_count_commit "$R4")" = "1" ] && ok "4c hmd trailer exactly once" || bad "4c count wrong" "count=$(trailer_count_commit "$R4")"
git -C "$R4" log -1 --format=%s | grep -qF "add feature" && ok "4d subject preserved after strip" || bad "4d subject lost"

# ══════════════════════════════════════════════════════════════════════════════
# 4b. MODEL TRAILER STRIPPED EVEN WHEN THE HMD TRAILER IS ALREADY PRESENT TOO —
#     the strip must not be gated behind the idempotent-add check (bin/heimdall-init
#     write_prepare_commit_msg: strip is step 4, add-skip is step 5, unconditionally
#     in that order)
# ══════════════════════════════════════════════════════════════════════════════
R4B="$WORK/r4b"; newrepo "$R4B"; hmdinit "$R4B"
printf 'x\n' > "$R4B/f.txt"; git -C "$R4B" add f.txt
git -C "$R4B" commit -q -m "add feature" -m "Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
$TRAILER" >/dev/null 2>&1
BODY4B="$(git -C "$R4B" log -1 --format=%B)"
printf '%s' "$BODY4B" | grep -qF "anthropic.com" && bad "4b1 model trailer NOT stripped when hmd trailer already present" "$BODY4B" || ok "4b1 model trailer stripped even though hmd trailer was already present"
[ "$(trailer_count_commit "$R4B")" = "1" ] && ok "4b2 only hmd trailer remains, exactly once" || bad "4b2 count wrong" "count=$(trailer_count_commit "$R4B")"

# ══════════════════════════════════════════════════════════════════════════════
# 5. --no-verify STILL GETS THE TRAILER (the reason this hook was chosen at all)
# ══════════════════════════════════════════════════════════════════════════════
R5="$WORK/r5"; newrepo "$R5"; hmdinit "$R5"
printf 'x\n' > "$R5/f.txt"; git -C "$R5" add f.txt
git -C "$R5" commit -q --no-verify -m "no-verify commit" >/dev/null 2>&1
[ "$(trailer_count_commit "$R5")" = "1" ] && ok "5 trailer present under --no-verify" || bad "5 trailer missing under --no-verify" "count=$(trailer_count_commit "$R5")"

# ══════════════════════════════════════════════════════════════════════════════
# 6. MERGE COMMIT SAFE
# ══════════════════════════════════════════════════════════════════════════════
R6="$WORK/r6"; newrepo "$R6"
printf 'base\n' > "$R6/base.txt"; git -C "$R6" add base.txt; git -C "$R6" commit -q -m "base" --no-verify >/dev/null 2>&1
BASE6="$(git -C "$R6" symbolic-ref --short HEAD)"
hmdinit "$R6"
git -C "$R6" checkout -q -b feature6
printf 'feat\n' > "$R6/feat.txt"; git -C "$R6" add feat.txt; git -C "$R6" commit -q -m "add feat" >/dev/null 2>&1
git -C "$R6" checkout -q "$BASE6"
printf 'main\n' > "$R6/main.txt"; git -C "$R6" add main.txt; git -C "$R6" commit -q -m "add main" >/dev/null 2>&1
git -C "$R6" merge -q --no-ff --no-edit feature6 >/dev/null 2>&1
BODY6="$(git -C "$R6" log -1 --format=%B)"
printf '%s' "$BODY6" | grep -qi "Merge branch" && ok "6a merge commit message intact" || bad "6a merge text lost" "$BODY6"
[ "$(trailer_count_commit "$R6")" = "1" ] && ok "6b trailer added to merge commit exactly once" || bad "6b count wrong" "count=$(trailer_count_commit "$R6")"

# ══════════════════════════════════════════════════════════════════════════════
# 7. SQUASH MESSAGE SAFE
# ══════════════════════════════════════════════════════════════════════════════
R7="$WORK/r7"; newrepo "$R7"
printf 'base\n' > "$R7/base.txt"; git -C "$R7" add base.txt; git -C "$R7" commit -q -m "base" --no-verify >/dev/null 2>&1
BASE7="$(git -C "$R7" symbolic-ref --short HEAD)"
hmdinit "$R7"
git -C "$R7" checkout -q -b feature7
printf 'feat\n' > "$R7/feat.txt"; git -C "$R7" add feat.txt; git -C "$R7" commit -q -m "add feat" >/dev/null 2>&1
git -C "$R7" checkout -q "$BASE7"
git -C "$R7" merge -q --squash feature7 >/dev/null 2>&1
git -C "$R7" commit -q --no-edit >/dev/null 2>&1
BODY7="$(git -C "$R7" log -1 --format=%B)"
printf '%s' "$BODY7" | grep -qi "add feat" && ok "7a squash message content preserved" || bad "7a squash text lost/unexpected" "$BODY7"
[ "$(trailer_count_commit "$R7")" = "1" ] && ok "7b trailer added to squash commit exactly once" || bad "7b count wrong" "count=$(trailer_count_commit "$R7")"

# ══════════════════════════════════════════════════════════════════════════════
# 8. AMEND SAFE — never duplicates a trailer this same hook already added
# ══════════════════════════════════════════════════════════════════════════════
R8="$WORK/r8"; newrepo "$R8"; hmdinit "$R8"
printf 'x\n' > "$R8/f.txt"; git -C "$R8" add f.txt
git -C "$R8" commit -q -m "amend me" >/dev/null 2>&1
[ "$(trailer_count_commit "$R8")" = "1" ] && ok "8pre trailer present before amend (precondition)" || bad "8pre trailer missing before amend" "count=$(trailer_count_commit "$R8")"
git -C "$R8" commit -q --amend --no-edit --allow-empty >/dev/null 2>&1
[ "$(trailer_count_commit "$R8")" = "1" ] && ok "8 amend does not duplicate an existing trailer" || bad "8 duplicated on amend" "count=$(trailer_count_commit "$R8")"

# ══════════════════════════════════════════════════════════════════════════════
# 9. CHAINING — a pre-existing prepare-commit-msg still runs, first + falsifier
# ══════════════════════════════════════════════════════════════════════════════
R9="$WORK/r9"; newrepo "$R9"
mkdir -p "$R9/.git/hooks"
MARKER9="$R9/.prior-hook-marker"
cat > "$R9/.git/hooks/prepare-commit-msg" <<EOF
#!/usr/bin/env bash
echo fired >> "$MARKER9"
exit 0
EOF
chmod +x "$R9/.git/hooks/prepare-commit-msg"
hmdinit "$R9"
printf 'x\n' > "$R9/f.txt"; git -C "$R9" add f.txt
git -C "$R9" commit -q -m "chained commit" >/dev/null 2>&1
[ -f "$MARKER9" ] && ok "9a pre-existing prepare-commit-msg still runs (chained)" || bad "9a prior hook never fired"
[ "$(trailer_count_commit "$R9")" = "1" ] && ok "9b hmd trailer still added on top of the chain" || bad "9b trailer missing after chaining" "count=$(trailer_count_commit "$R9")"
rm -f "$MARKER9"
git -C "$R9" config --unset heimdall.prevHooksPath
printf 'y\n' > "$R9/f2.txt"; git -C "$R9" add f2.txt
git -C "$R9" commit -q -m "unchained commit" >/dev/null 2>&1
[ ! -f "$MARKER9" ] && ok "9c falsifier: no prevHooksPath -> prior hook does not run" || bad "9c prior hook fired without a chain pointer"
[ "$(trailer_count_commit "$R9")" = "1" ] && ok "9d trailer still added with chaining removed" || bad "9d trailer missing" "count=$(trailer_count_commit "$R9")"

# ══════════════════════════════════════════════════════════════════════════════
# 10. HMD_SKIP IS NOT CONSULTED — attribution is not a gate
# ══════════════════════════════════════════════════════════════════════════════
R10="$WORK/r10"; newrepo "$R10"; hmdinit "$R10"
printf 'x\n' > "$R10/f.txt"; git -C "$R10" add f.txt
HMD_SKIP=1 git -C "$R10" commit -q -m "skip test" >/dev/null 2>&1
[ "$(trailer_count_commit "$R10")" = "1" ] && ok "10 trailer added even under HMD_SKIP=1" || bad "10 trailer missing under HMD_SKIP" "count=$(trailer_count_commit "$R10")"

# ══════════════════════════════════════════════════════════════════════════════
# 11. FAIL OPEN — malformed input never blocks, never loses content
# ══════════════════════════════════════════════════════════════════════════════
R11="$WORK/r11"; newrepo "$R11"; hmdinit "$R11"
HOOK11="$R11/.heimdall/hooks/prepare-commit-msg"

( cd "$R11" && "$HOOK11" ); RC=$?
[ "$RC" = "0" ] && ok "11a no args at all -> exit 0" || bad "11a nonzero exit with no args" "rc=$RC"

( cd "$R11" && "$HOOK11" "$R11/does-not-exist.txt" ); RC=$?
[ "$RC" = "0" ] && ok "11b nonexistent message file -> exit 0" || bad "11b nonzero exit" "rc=$RC"

RO="$R11/readonly-msg.txt"
printf 'Subject line only\n' > "$RO"
BEFORE="$(cat "$RO")"
chmod 444 "$RO"
( cd "$R11" && "$HOOK11" "$RO" ); RC=$?
chmod 644 "$RO"
AFTER="$(cat "$RO")"
[ "$RC" = "0" ] && ok "11c unwritable message file -> exit 0" || bad "11c nonzero exit" "rc=$RC"
[ "$BEFORE" = "$AFTER" ] && ok "11d unwritable message file content byte-for-byte unchanged" || bad "11d content changed" "before=[$BEFORE] after=[$AFTER]"

# ══════════════════════════════════════════════════════════════════════════════
# 12. PROTECT THE EMPTY-MESSAGE ABORT PATH — comment-only message untouched
# ══════════════════════════════════════════════════════════════════════════════
CMTONLY="$R11/comment-only.txt"
cat > "$CMTONLY" <<'MSG'
# Please enter the commit message for your changes. Lines starting
# with '#' will be ignored, and an empty message aborts the commit.
#
# On branch main
# nothing to commit, working tree clean
MSG
BEFORE12="$(cat "$CMTONLY")"
( cd "$R11" && "$HOOK11" "$CMTONLY" ); RC=$?
AFTER12="$(cat "$CMTONLY")"
[ "$RC" = "0" ] && ok "12a comment-only message -> exit 0" || bad "12a nonzero exit" "rc=$RC"
[ "$BEFORE12" = "$AFTER12" ] && ok "12b comment-only message left untouched (abort path protected)" || bad "12b comment-only message was mutated"

# ══════════════════════════════════════════════════════════════════════════════
# 13. NO TRAILING NEWLINE — handled without corrupting the subject line
# ══════════════════════════════════════════════════════════════════════════════
NONL="$R11/no-trailing-newline.txt"
printf 'Subject with no trailing newline' > "$NONL"
( cd "$R11" && "$HOOK11" "$NONL" ); RC=$?
[ "$RC" = "0" ] && ok "13a no-trailing-newline message -> exit 0" || bad "13a nonzero exit" "rc=$RC"
[ "$(trailer_count_file "$NONL")" = "1" ] && ok "13b trailer added exactly once" || bad "13b count wrong" "count=$(trailer_count_file "$NONL")"
head -1 "$NONL" | grep -qF "Subject with no trailing newline" && ok "13c original subject line intact, not welded to the trailer" || bad "13c subject line corrupted" "$(head -1 "$NONL")"

# ══════════════════════════════════════════════════════════════════════════════
# 14. HUMAN CO-AUTHOR PRESERVED — a non-model Co-Authored-By is NEVER stripped
#     (the negative case: matching by email DOMAIN must not catch a real person)
# ══════════════════════════════════════════════════════════════════════════════
R14="$WORK/r14"; newrepo "$R14"; hmdinit "$R14"
printf 'x\n' > "$R14/f.txt"; git -C "$R14" add f.txt
git -C "$R14" commit -q -m "pair on feature" -m "Co-Authored-By: Jane Collaborator <jane@example.com>" >/dev/null 2>&1
BODY14="$(git -C "$R14" log -1 --format=%B)"
printf '%s' "$BODY14" | grep -qF "Co-Authored-By: Jane Collaborator <jane@example.com>" && ok "14a human co-author preserved" || bad "14a human co-author stripped" "$BODY14"
printf '%s' "$BODY14" | grep -qF "$TRAILER" && ok "14b hmd trailer still added alongside the human co-author" || bad "14b hmd trailer missing" "$BODY14"
[ "$(printf '%s\n' "$BODY14" | grep -c '^Co-Authored-By:')" = "2" ] && ok "14c exactly two co-author trailers total (human + hmd)" || bad "14c wrong trailer count" "$(printf '%s\n' "$BODY14" | grep '^Co-Authored-By:')"

# ══════════════════════════════════════════════════════════════════════════════
# 15. STRIPPING IS IDEMPOTENT — a second hook run over an already-clean message
#     changes nothing (byte-for-byte), and never re-duplicates the hmd trailer
# ══════════════════════════════════════════════════════════════════════════════
R15="$WORK/r15"; newrepo "$R15"; hmdinit "$R15"
HOOK15="$R15/.heimdall/hooks/prepare-commit-msg"
printf 'x\n' > "$R15/f.txt"; git -C "$R15" add f.txt
git -C "$R15" commit -q -m "add feature" -m "Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>" >/dev/null 2>&1
MSG15="$R15/replay-msg.txt"
git -C "$R15" log -1 --format=%B > "$MSG15"
BEFORE15="$(cat "$MSG15")"
( cd "$R15" && "$HOOK15" "$MSG15" ); RC=$?
AFTER15="$(cat "$MSG15")"
[ "$RC" = "0" ] && ok "15a second run over an already-stripped message exits 0" || bad "15a nonzero exit" "rc=$RC"
[ "$BEFORE15" = "$AFTER15" ] && ok "15b second run changes nothing, byte-for-byte" || bad "15b content changed on replay" "before=[$BEFORE15] after=[$AFTER15]"
[ "$(trailer_count_file "$MSG15")" = "1" ] && ok "15c hmd trailer still exactly once after replay" || bad "15c count wrong" "count=$(trailer_count_file "$MSG15")"

# ══════════════════════════════════════════════════════════════════════════════
# 16. OLD-ADDRESS NORMALIZED — Co-Authored-By: hmd <hmd@runheimdall.dev> (retired
#     2026-08-20 when the `runhmd` GitHub account replaced it) becomes the new
#     trailer, never both (CLAUDE.md "Commit attribution")
# ══════════════════════════════════════════════════════════════════════════════
R16="$WORK/r16"; newrepo "$R16"; hmdinit "$R16"
printf 'x\n' > "$R16/f.txt"; git -C "$R16" add f.txt
git -C "$R16" commit -q -m "add feature" -m "$OLD_TRAILER" >/dev/null 2>&1
BODY16="$(git -C "$R16" log -1 --format=%B)"
printf '%s' "$BODY16" | grep -qF "runheimdall.dev" && bad "16a old-address trailer NOT normalized away" "$BODY16" || ok "16a old-address trailer normalized away"
printf '%s' "$BODY16" | grep -qF "$TRAILER" && ok "16b new trailer present in its place" || bad "16b new trailer missing" "$BODY16"
[ "$(trailer_count_commit "$R16")" = "1" ] && ok "16c new trailer exactly once" || bad "16c count wrong" "count=$(trailer_count_commit "$R16")"
git -C "$R16" log -1 --format=%s | grep -qF "add feature" && ok "16d subject preserved after normalization" || bad "16d subject lost"

# ══════════════════════════════════════════════════════════════════════════════
# 17. OLD+NEW BOTH ALREADY PRESENT — collapses to exactly one trailer (the new
#     one); "must not end up with two hmd lines" (explicit requirement)
# ══════════════════════════════════════════════════════════════════════════════
R17="$WORK/r17"; newrepo "$R17"; hmdinit "$R17"
printf 'x\n' > "$R17/f.txt"; git -C "$R17" add f.txt
git -C "$R17" commit -q -m "add feature" -m "$OLD_TRAILER
$TRAILER" >/dev/null 2>&1
BODY17="$(git -C "$R17" log -1 --format=%B)"
printf '%s' "$BODY17" | grep -qF "runheimdall.dev" && bad "17a old-address trailer NOT removed when new one already present too" "$BODY17" || ok "17a old-address trailer removed even though new one was already present"
[ "$(printf '%s\n' "$BODY17" | grep -c '^Co-Authored-By:')" = "1" ] && ok "17b exactly one Co-Authored-By line total, never two hmd lines" || bad "17b wrong trailer line count" "$(printf '%s\n' "$BODY17" | grep '^Co-Authored-By:')"

# ══════════════════════════════════════════════════════════════════════════════
# 18. OLD-ADDRESS NORMALIZATION IS IDEMPOTENT — a second run over an
#     already-normalized message changes nothing, byte-for-byte
# ══════════════════════════════════════════════════════════════════════════════
R18="$WORK/r18"; newrepo "$R18"; hmdinit "$R18"
HOOK18="$R18/.heimdall/hooks/prepare-commit-msg"
printf 'x\n' > "$R18/f.txt"; git -C "$R18" add f.txt
git -C "$R18" commit -q -m "add feature" -m "$OLD_TRAILER" >/dev/null 2>&1
MSG18="$R18/replay-msg.txt"
git -C "$R18" log -1 --format=%B > "$MSG18"
BEFORE18="$(cat "$MSG18")"
( cd "$R18" && "$HOOK18" "$MSG18" ); RC=$?
AFTER18="$(cat "$MSG18")"
[ "$RC" = "0" ] && ok "18a second run over an already-normalized message exits 0" || bad "18a nonzero exit" "rc=$RC"
[ "$BEFORE18" = "$AFTER18" ] && ok "18b second run changes nothing, byte-for-byte" || bad "18b content changed on replay" "before=[$BEFORE18] after=[$AFTER18]"
[ "$(trailer_count_file "$MSG18")" = "1" ] && ok "18c new trailer still exactly once after replay" || bad "18c count wrong" "count=$(trailer_count_file "$MSG18")"

# ══════════════════════════════════════════════════════════════════════════════
# 19. EXACT NEW ADDRESS PINNED — hardcoded literal, independent of this suite's
#     own $TRAILER variable, so a silent drift in either the hook or this suite
#     fails instead of quietly agreeing with itself
# ══════════════════════════════════════════════════════════════════════════════
PINNED='Co-Authored-By: runhmd <318965969+runhmd@users.noreply.github.com>'
R19="$WORK/r19"; newrepo "$R19"; hmdinit "$R19"
HOOK19="$R19/.heimdall/hooks/prepare-commit-msg"
grep -qF "$PINNED" "$HOOK19" && ok "19a generated hook's own source pins the exact new address" || bad "19a hook source does not contain the pinned literal" "$(grep -n 'TRAILER=' "$HOOK19")"
printf 'x\n' > "$R19/f.txt"; git -C "$R19" add f.txt
git -C "$R19" commit -q -m "pin test" >/dev/null 2>&1
BODY19="$(git -C "$R19" log -1 --format=%B)"
printf '%s' "$BODY19" | grep -qF "$PINNED" && ok "19b commit trailer matches the exact pinned literal" || bad "19b commit trailer does not match pinned literal" "$BODY19"

# ─────────────────────────────────────────────────────────────────────────────
echo "════════════════════════════════════════════════════════════════"
printf "TOTAL: %d passed, %d failed\n" "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
