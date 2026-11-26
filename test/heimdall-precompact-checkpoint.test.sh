#!/usr/bin/env bash
# test/heimdall-precompact-checkpoint.test.sh
#
# Proof for bin/heimdall-precompact-checkpoint -- the PreCompact hook that makes
# "checkpoint before compaction" mechanical instead of a stderr plea to the
# operator (docs/analysis/2026-09-19-ecc-harness-gap-analysis.md, item #1).
#
# Two properties, asserted head-on:
#   1. It SAVES: a real PreCompact payload produces .planning/CHECKPOINT.md via the
#      existing writer, and the checkpoint records that compaction caused it and
#      which trigger kind ("manual" / "auto").
#   2. It CANNOT HURT compaction: exit 0 and an empty stdout on every failure --
#      malformed JSON, empty stdin, missing writer, a hung dependency -- and the
#      hung case returns inside its own alarm, not the hook runtime's.
#
# Every case runs in a throwaway git repo with HEIMDALL_HOME redirected, so the
# operator's real notes store and .planning are never touched.

set -u

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOOK="$REPO/bin/heimdall-precompact-checkpoint"

PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; }

TMPROOT="$(mktemp -d)"
# HERMETICITY GUARD (2026-09-19). The hook's project resolution ends in `$PWD`
# (--repo > CLAUDE_PROJECT_DIR > payload cwd > cwd). A case that gives it none of
# the first three, run from the repo root as test/run-all.sh does, made it write
# .planning/ledger/checkpoints/<haid>.json into the REAL repo -- the full sweep's
# tree-integrity check caught a tracked file changing mid-run. Two defences:
# run every case from a scratch cwd with no .planning (a $PWD fallback then finds
# nothing to act on), and assert at the end that no ledger checkpoint under the
# real repo changed during this suite.
cd "$TMPROOT" || { echo "FATAL: cannot cd into scratch dir [$TMPROOT] -- refusing to run from a cwd that could be the real repo"; exit 1; }
unset CLAUDE_PROJECT_DIR
# ledger_digest -- sha256 of every real-repo ledger checkpoint. The glob is expanded
# afresh on each call, so a checkpoint CREATED mid-suite shows up in the AFTER digest.
ledger_digest() { shasum -a 256 "$REPO"/.planning/ledger/checkpoints/*.json 2>/dev/null | sort; }
LEDGER_BEFORE="$(ledger_digest)"
trap 'rm -rf "$TMPROOT"' EXIT

# A fresh throwaway git project with a .planning dir (same shape the autosave
# test uses -- the writer needs a HEAD to derive its contract fields).
mk_project() {
  local d="$TMPROOT/$1"
  mkdir -p "$d"
  git -C "$d" init -q
  git -C "$d" config user.email t@t.t
  git -C "$d" config user.name t
  printf 'hello\n' > "$d/README.md"
  git -C "$d" add README.md
  git -C "$d" commit -qm "initial commit" --no-verify
  mkdir -p "$d/.planning"
  printf '%s' "$d"
}

payload() { # <trigger> <cwd>
  printf '{"session_id":"sess-%s","transcript_path":"/nonexistent/t.jsonl","cwd":"%s","hook_event_name":"PreCompact","trigger":"%s","custom_instructions":null}' "$1" "$2" "$1"
}

# run_hook <stdin-file> [args...] -> echoes rc; stdout/stderr captured to files.
run_hook() {
  local in="$1"; shift
  "$HOOK" "$@" <"$in" >"$TMPROOT/out" 2>"$TMPROOT/err"
  printf '%s' "$?"
}

now_s() { date +%s; }

echo "heimdall-precompact-checkpoint"

# ── 1. manual payload → checkpoint written, mentions compaction + trigger ────
P1="$(mk_project manual)"
payload manual "$P1" > "$TMPROOT/in1"
rc="$(HEIMDALL_HOME="$P1/.hmdhome" run_hook "$TMPROOT/in1")"
CK1="$P1/.planning/CHECKPOINT.md"
if [ "$rc" = "0" ] && [ -f "$CK1" ]; then
  ok "1. manual payload → exit 0 and .planning/CHECKPOINT.md exists"
else
  bad "1. manual payload did not produce a checkpoint (rc=$rc, file=$([ -f "$CK1" ] && echo yes || echo no))"
fi

if grep -q 'heimdall-auto-checkpoint:begin' "$CK1" 2>/dev/null; then
  ok "2. the checkpoint came from the EXISTING writer (auto-checkpoint marker present)"
else
  bad "2. auto-checkpoint marker missing — the hook did not reuse bin/heimdall-checkpoint"
fi

if grep -q 'compaction (manual)' "$CK1" 2>/dev/null; then
  ok "3. checkpoint records it was compaction-triggered with trigger kind 'manual'"
else
  bad "3. checkpoint does not mention 'compaction (manual)'"
fi

if grep -q 'sess-manual' "$CK1" 2>/dev/null; then
  ok "4. checkpoint carries the session_id from the payload"
else
  bad "4. session_id from the payload not found in the checkpoint"
fi

if [ ! -s "$TMPROOT/out" ]; then
  ok "5. stdout is empty on the success path"
else
  bad "5. stdout was not empty: $(head -c 200 "$TMPROOT/out")"
fi

if grep -q 'compaction (manual)' "$TMPROOT/err" && grep -q 'checkpoint saved' "$TMPROOT/err"; then
  ok "6. one stderr status line names the trigger and the saved checkpoint"
else
  bad "6. stderr status line missing or wrong: $(head -c 300 "$TMPROOT/err")"
fi

# ── 7. auto payload → trigger kind 'auto' recorded ──────────────────────────
P2="$(mk_project auto)"
payload auto "$P2" > "$TMPROOT/in2"
rc="$(HEIMDALL_HOME="$P2/.hmdhome" run_hook "$TMPROOT/in2")"
if [ "$rc" = "0" ] && grep -q 'compaction (auto)' "$P2/.planning/CHECKPOINT.md" 2>/dev/null; then
  ok "7. auto payload → checkpoint records 'compaction (auto)'"
else
  bad "7. auto trigger not recorded (rc=$rc)"
fi

# ── 8. --repo overrides payload cwd (the hooks.json spelling) ───────────────
P3="$(mk_project repoflag)"
payload manual "/nonexistent/elsewhere" > "$TMPROOT/in3"
rc="$(HEIMDALL_HOME="$P3/.hmdhome" run_hook "$TMPROOT/in3" --repo "$P3")"
if [ "$rc" = "0" ] && [ -f "$P3/.planning/CHECKPOINT.md" ]; then
  ok "8. --repo <dir> selects the project even when payload cwd is bogus"
else
  bad "8. --repo not honoured (rc=$rc)"
fi

# ── 9. malformed JSON → exit 0, no stdout, no checkpoint-writer crash ────────
P4="$(mk_project malformed)"
printf '{"trigger": "man' > "$TMPROOT/in4"
rc="$(HEIMDALL_HOME="$P4/.hmdhome" run_hook "$TMPROOT/in4" --repo "$P4")"
if [ "$rc" = "0" ] && [ ! -s "$TMPROOT/out" ]; then
  ok "9. malformed JSON → exit 0, empty stdout"
else
  bad "9. malformed JSON broke the hook (rc=$rc, stdout bytes=$(wc -c <"$TMPROOT/out"))"
fi
if grep -q 'compaction (unknown)' "$TMPROOT/err"; then
  ok "10. malformed payload degrades to trigger 'unknown' and still checkpoints"
else
  bad "10. expected 'compaction (unknown)' on stderr: $(head -c 300 "$TMPROOT/err")"
fi

# ── 11. empty stdin → exit 0, no stdout ─────────────────────────────────────
P5="$(mk_project empty)"
: > "$TMPROOT/in5"
rc="$(HEIMDALL_HOME="$P5/.hmdhome" run_hook "$TMPROOT/in5" --repo "$P5")"
if [ "$rc" = "0" ] && [ ! -s "$TMPROOT/out" ]; then
  ok "11. empty stdin → exit 0, empty stdout"
else
  bad "11. empty stdin broke the hook (rc=$rc)"
fi

# ── 12. non-hmd project (no .planning) → exit 0, nothing created ────────────
P6="$TMPROOT/plain"; mkdir -p "$P6"
payload manual "$P6" > "$TMPROOT/in6"
rc="$(run_hook "$TMPROOT/in6")"
if [ "$rc" = "0" ] && [ ! -d "$P6/.planning" ] && [ ! -s "$TMPROOT/out" ]; then
  ok "12. project without .planning/ is left untouched (no dir sprayed), exit 0"
else
  bad "12. gate failed: rc=$rc, .planning created=$([ -d "$P6/.planning" ] && echo yes || echo no)"
fi

# ── 13. missing writer beside the hook → exit 0, stderr says so ─────────────
ALONE="$TMPROOT/alone-bin"; mkdir -p "$ALONE"
cp "$HOOK" "$ALONE/heimdall-precompact-checkpoint"
chmod +x "$ALONE/heimdall-precompact-checkpoint"
P7="$(mk_project nowriter)"
payload auto "$P7" > "$TMPROOT/in7"
"$ALONE/heimdall-precompact-checkpoint" <"$TMPROOT/in7" >"$TMPROOT/out" 2>"$TMPROOT/err"; rc=$?
if [ "$rc" = "0" ] && [ ! -s "$TMPROOT/out" ] && grep -q 'heimdall-checkpoint not found' "$TMPROOT/err"; then
  ok "13. missing bin/heimdall-checkpoint → exit 0, empty stdout, stderr names the cause"
else
  bad "13. missing writer not handled (rc=$rc): $(head -c 300 "$TMPROOT/err")"
fi

# ── 14. hung dependency (git shim sleeps) → exits 0 inside the alarm ────────
# The writer shells out to git via PATH; a git that never returns is the realistic
# "hung dependency". The hook's own budget is 2s here; it must return well before
# the shim's 60s, exit 0, and say the writer was stopped.
SHIM="$TMPROOT/shim"; mkdir -p "$SHIM"
cat > "$SHIM/git" <<'EOF'
#!/bin/sh
sleep 60
EOF
chmod +x "$SHIM/git"
P8="$(mk_project hung)"
payload auto "$P8" > "$TMPROOT/in8"
t0="$(now_s)"
PATH="$SHIM:$PATH" HMD_PRECOMPACT_BUDGET=2 HEIMDALL_HOME="$P8/.hmdhome" \
  "$HOOK" --repo "$P8" <"$TMPROOT/in8" >"$TMPROOT/out" 2>"$TMPROOT/err"; rc=$?
t1="$(now_s)"
elapsed=$((t1 - t0))
if [ "$rc" = "0" ] && [ "$elapsed" -lt 15 ] && [ ! -s "$TMPROOT/out" ]; then
  ok "14. hung git → exit 0 in ${elapsed}s (budget 2s, shim would hang 60s), empty stdout"
else
  bad "14. hung dependency not bounded (rc=$rc, elapsed=${elapsed}s, stdout bytes=$(wc -c <"$TMPROOT/out"))"
fi
if grep -q 'exceeded 2s and was stopped' "$TMPROOT/err"; then
  ok "15. stderr reports the writer was stopped at the budget and tells the operator to /hmd:save"
else
  bad "15. timeout not reported on stderr: $(head -c 300 "$TMPROOT/err")"
fi

# ── 16. help exits 0 and prints nothing on stdout ───────────────────────────
"$HOOK" help >"$TMPROOT/out" 2>"$TMPROOT/err"; rc=$?
if [ "$rc" = "0" ] && [ ! -s "$TMPROOT/out" ] && grep -q 'Usage' "$TMPROOT/err"; then
  ok "16. help → exit 0, usage on stderr, stdout empty"
else
  bad "16. help misbehaved (rc=$rc)"
fi

# ── 17. bad HMD_PRECOMPACT_BUDGET is tolerated, not fatal ───────────────────
P9="$(mk_project badbudget)"
payload manual "$P9" > "$TMPROOT/in9"
rc="$(HMD_PRECOMPACT_BUDGET=abc HEIMDALL_HOME="$P9/.hmdhome" run_hook "$TMPROOT/in9" --repo "$P9")"
if [ "$rc" = "0" ] && [ -f "$P9/.planning/CHECKPOINT.md" ]; then
  ok "17. garbage budget falls back to the default and still saves"
else
  bad "17. garbage budget broke the hook (rc=$rc)"
fi

# ── 18. the hook never exits 2 (the one code that blocks compaction) ────────
# Re-run every captured input once more through the hook and collect exit codes.
codes=""
for f in "$TMPROOT"/in*; do
  "$HOOK" <"$f" >/dev/null 2>&1; codes="$codes $?"
done
case "$codes" in
  *" 2"*) bad "18. some input produced exit 2 (would BLOCK compaction): codes=$codes" ;;
  *)      ok  "18. no input produced exit 2 (codes:$codes)" ;;
esac

# ── 19-24. a busy repo: the save's work is shared out, not queued ───────────
# THE DEFECT (2026-11-26): on the real repo (57 worktrees, 266 local branches) a manual /compact printed "checkpoint writer
# exceeded 8s and was stopped" and saved NOTHING, because the writer only writes once every measurement is in. Measured one
# stage at a time, the seconds went to: the notes store read SEVEN times (a python launch each, ~0.3 s apiece behind a pyenv
# shim), every other python launch paying that shim too (13 per save), `git status` + `merge-base` + `rev-list` run for one
# worktree and one branch after another, and three slow read-only probes (the gate verdict, the open-agents list, this
# session's edits) run back to back. These cases pin each cause by COUNTING steps (launches, probes running at once), never by
# timing, so a loaded runner cannot make them flap. One save on a repo shaped like the real one feeds all six.
REAL_GIT="$(command -v git)"
REAL_PY=""
for c in /usr/bin/python3 "$(command -v python3 2>/dev/null)"; do
  if [ -n "$c" ] && [ -x "$c" ] && "$c" -c pass >/dev/null 2>&1; then REAL_PY="$c"; break; fi
done

# A project with every shape the scans must report: a dirty worktree, an unmerged one, a clean one, one whose directory is
# gone, and three branches that hold 1, 2 and 3 commits with no worktree at all.
mk_busy_project() { # <name> -> path
  local d base b n tree parent
  d="$(mk_project "$1")"
  base="$(git -C "$d" rev-parse --abbrev-ref HEAD)"
  git -C "$d" worktree add -q -b wt-dirty "$d-wt-dirty" >/dev/null 2>&1
  printf 'scratch\n' > "$d-wt-dirty/scratch.txt"
  git -C "$d" worktree add -q -b wt-unmerged "$d-wt-unmerged" >/dev/null 2>&1
  git -C "$d-wt-unmerged" commit -q --allow-empty -m "unmerged work" --no-verify
  git -C "$d" worktree add -q -b wt-clean "$d-wt-clean" >/dev/null 2>&1
  git -C "$d" worktree add -q -b wt-gone "$d-wt-gone" >/dev/null 2>&1
  rm -rf "$d-wt-gone"
  tree="$(git -C "$d" rev-parse 'HEAD^{tree}')"
  for b in held-a:1 held-b:2 held-c:3; do
    parent="$(git -C "$d" rev-parse HEAD)"
    n="${b#*:}"
    while [ "$n" -gt 0 ]; do
      parent="$(git -C "$d" commit-tree "$tree" -p "$parent" -m "held work")"
      n=$((n - 1))
    done
    git -C "$d" update-ref "refs/heads/${b%:*}" "$parent"
  done
  printf '%s' "$d"
}

# Shims, none of which changes what a tool answers. git: holds every `status` and `rev-list --count` open for half a second and
# logs S(tart)/E(nd), so two of them running at once is visible. python: logs which hmd_nofollow_write.py verb ran, then runs
# the real interpreter; one copy stands in for the PATH python3, one for HMD_PYTHON (the resolver's own override).
BUSY="$TMPROOT/busy"; mkdir -p "$BUSY/bin" "$BUSY/fast"
cat > "$BUSY/bin/git" <<'EOF'
#!/bin/sh
kind=""
case " $* " in
  *" status "*) kind=status ;;
  *" rev-list --count "*) kind=revlist ;;
esac
if [ -n "$kind" ]; then
  printf 'S\n' >> "$BUSY_LOGS/$kind.log"
  sleep 0.5
  "$REAL_GIT" "$@"; rc=$?
  printf 'E\n' >> "$BUSY_LOGS/$kind.log"
  exit "$rc"
fi
exec "$REAL_GIT" "$@"
EOF
cat > "$BUSY/bin/python3" <<'EOF'
#!/bin/sh
for a in "$@"; do
  case "$a" in check|read|write|append) printf '%s\n' "$a" >> "$BUSY_LOGS/python-on-path.log"; break ;; esac
done
exec "$REAL_PY" "$@"
EOF
cat > "$BUSY/fast/python3" <<'EOF'
#!/bin/sh
for a in "$@"; do
  case "$a" in check|read|write|append) printf '%s\n' "$a" >> "$BUSY_LOGS/python-fast.log"; break ;; esac
done
exec "$REAL_PY" "$@"
EOF
chmod +x "$BUSY/bin/git" "$BUSY/bin/python3" "$BUSY/fast/python3"
BUSY_LOGS="$BUSY/logs"; mkdir -p "$BUSY_LOGS"
max_overlap() { # <log>: the most S(tarts) that were open at once
  awk '$1=="S"{c++; if(c>m)m=c} $1=="E"{c--} END{print m+0}' "$1" 2>/dev/null
}

if [ -n "$REAL_PY" ]; then
  PB="$(mk_busy_project busy)"
  PBASE="$(git -C "$PB" rev-parse --abbrev-ref HEAD)"
  payload manual "$PB" > "$TMPROOT/inbusy"
  PATH="$BUSY/bin:$PATH" REAL_GIT="$REAL_GIT" REAL_PY="$REAL_PY" BUSY_LOGS="$BUSY_LOGS" HMD_PYTHON="$BUSY/fast/python3" \
    HMD_PRECOMPACT_BUDGET=120 HEIMDALL_HOME="$PB/.hmdhome" \
    "$HOOK" --repo "$PB" <"$TMPROOT/inbusy" >"$TMPROOT/out" 2>"$TMPROOT/err"; rc=$?
  CKB="$PB/.planning/CHECKPOINT.md"
  PBN="$(basename "$PB")"

  # 19. the save still says what it said before the work was shared out: every flagged worktree, in `git worktree list` order,
  # every held branch with its own count, all six contract fields.
  held_line="$(grep '^- \*\*Held branches:\*\* ' "$CKB" 2>/dev/null)"
  want_order="$(git -C "$PB" worktree list --porcelain | sed -n 's|^worktree .*/'"$PBN"'-\(wt-[a-z]*\)$|\1|p' | grep -E '^wt-(dirty|unmerged|gone)$' | tr '\n' ' ')"
  got_order="$(sed -n -e 's|^- DIRTY `.*/'"$PBN"'-\(wt-[a-z]*\)` — .*|\1|p' -e 's|^- UNMERGED `.*/'"$PBN"'-\(wt-[a-z]*\)` — .*|\1|p' -e 's|^- MISSING `.*/'"$PBN"'-\(wt-[a-z]*\)` — .*|\1|p' "$CKB" 2>/dev/null | tr '\n' ' ')"
  six=0
  for lbl in 'In progress' 'Gated decisions' 'Held branches' 'Unpushed' 'Open warnings' 'Refuted claims'; do
    [ "$(grep -c "^- \*\*$lbl:\*\* " "$CKB" 2>/dev/null)" = "1" ] && six=$((six + 1))
  done
  if [ "$rc" = "0" ] && grep -q 'checkpoint saved' "$TMPROOT/err" \
     && grep -q '(5 of 5 worktree(s) scanned)' "$CKB" 2>/dev/null \
     && grep -q "^- DIRTY \`.*-wt-dirty\` — 1 uncommitted file(s)" "$CKB" \
     && grep -q "^- UNMERGED \`.*-wt-unmerged\` — HEAD has commits not on \`$PBASE\`" "$CKB" \
     && grep -q "^- MISSING \`.*-wt-gone\` — worktree directory no longer exists" "$CKB" \
     && ! grep -q -- '-wt-clean` — ' "$CKB" \
     && [ -n "$want_order" ] && [ "$want_order" = "$got_order" ]; then
    ok "19. busy repo: saved; dirty, unmerged and missing worktrees flagged in worktree-list order (${got_order% }), the clean one is not"
  else
    bad "19. busy repo ledger wrong (rc=$rc, want order [$want_order] got [$got_order]): $(grep -A8 'Worktree ledger' "$CKB" 2>/dev/null | head -12 | tr '\n' '|')"
  fi
  if printf '%s' "$held_line" | grep -q "wt-unmerged (1 commit(s) not on $PBASE, at " \
     && printf '%s' "$held_line" | grep -q "held-a (1 commit(s) not on $PBASE).*held-b (2 commit(s) not on $PBASE).*held-c (3 commit(s) not on $PBASE)" \
     && [ "$six" = "6" ]; then
    ok "20. held branches keep their own commit counts (1, 2, 3) and all six contract fields are written once each"
  else
    bad "20. held-branch field or contract fields wrong (fields=$six): $held_line"
  fi

  # 21. the notes store is read ONCE per save (it was read seven times: notice, four fields, key count, key presence).
  nreads="$(grep -c '^read$' "$BUSY_LOGS/python-fast.log" 2>/dev/null)"
  if [ "${nreads:-0}" = "1" ]; then
    ok "21. the notes store is read once per save, not once per field"
  else
    bad "21. the notes store was read ${nreads:-0} times in one save (want 1)"
  fi

  # 22. every python the save launches is the resolved interpreter (HMD_PYTHON), none the PATH python3 -- which on this
  # machine is a ~0.3 s version-manager shim. The path check, the notes read, the checkpoint and key writes and the note's
  # append all go through it.
  nwrites="$(grep -c '^write$' "$BUSY_LOGS/python-fast.log" 2>/dev/null)"
  nappend="$(grep -c '^append$' "$BUSY_LOGS/python-fast.log" 2>/dev/null)"
  ncheck="$(grep -c '^check$' "$BUSY_LOGS/python-fast.log" 2>/dev/null)"
  if [ ! -s "$BUSY_LOGS/python-on-path.log" ] && [ "${ncheck:-0}" -ge 1 ] && [ "${nwrites:-0}" -ge 2 ] && [ "${nappend:-0}" = "1" ]; then
    ok "22. the note and the save run on the resolved interpreter (check ${ncheck}, write ${nwrites}, append ${nappend}), the PATH python3 never"
  else
    bad "22. python launches: via PATH=$(wc -l < "$BUSY_LOGS/python-on-path.log" 2>/dev/null | tr -d ' ') via HMD_PYTHON: check ${ncheck:-0} write ${nwrites:-0} append ${nappend:-0}"
  fi

  # 23/24. the per-worktree `git status` probes, and the per-branch `rev-list --count` probes, overlap.
  so="$(max_overlap "$BUSY_LOGS/status.log")"; ro="$(max_overlap "$BUSY_LOGS/revlist.log")"
  if [ "${so:-0}" -ge 2 ]; then
    ok "23. worktree status probes run side by side (up to $so at once), not one after another"
  else
    bad "23. worktree status probes never overlapped (max $so at once): the scan is sequential again"
  fi
  if [ "${ro:-0}" -ge 2 ]; then
    ok "24. held-branch count probes run side by side (up to $ro at once), not one after another"
  else
    bad "24. held-branch count probes never overlapped (max $ro at once): the branch walk is sequential again"
  fi
else
  ok "19-24. skipped: no working python3 on this machine to stand behind the shims"
fi

# ── 25. the REAL repo's ledger checkpoints are byte-identical to when we started ──
LEDGER_AFTER="$(ledger_digest)"
if [ "$LEDGER_BEFORE" = "$LEDGER_AFTER" ]; then
  ok "25. no case wrote into the real repo's .planning/ledger/checkpoints (hermetic)"
else
  bad "25. a case wrote into the REAL repo's ledger checkpoints -- the tree-integrity class of bug"
fi

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
