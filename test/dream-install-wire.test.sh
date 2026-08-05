#!/usr/bin/env bash
# test/dream-install-wire.test.sh — the AUTO-INSTALL + AUTO-UPDATE wiring for the nightly
# /dream schedule.
#
# Two things this proves:
#   PART 1  A normal `hmd install` / install.sh run AUTO-INSTALLS the nightly /dream
#           LaunchAgent (com.heimdall.dream) via install.sh's ensure_dream_schedule —
#           idempotent, macOS-gated, opt-out-honoring, and NON-FATAL.
#   PART 2  heimdall-autoupdate RE-ASSERTS that schedule post-update (reassert_dream_schedule)
#           so the nightly job self-heals to the CURRENT code across upgrades, and the plist
#           points at the STABLE installed dream bin (never a version-frozen path).
#
# Hermetic + PRIVILEGE-FREE (mirrors heimdall-dream-schedule.test.sh): the LaunchAgents dir
# and log path are redirected to a throwaway tmp dir, `launchctl` is SHIMMED, and `uname` is
# shimmed (via PATH) for the non-Darwin case. No root, no real agent loaded.
#
# install.sh / heimdall-autoupdate are `source`d with their documented TEST SEAMS
# (HEIMDALL_INSTALL_SOURCE_ONLY / HEIMDALL_AUTOUPDATE_SOURCE_ONLY) so the pure helpers can be
# unit-tested WITHOUT running a real network install or hitting the releases API. Those seams
# are unset in every production path, so the `main "$@"` / dispatch contracts are unchanged.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
INSTALL_SH="$ROOT/install.sh"
UPDATER="$ROOT/bin/heimdall-autoupdate"
SCHED="$ROOT/bin/heimdall-dream-schedule"
DREAM="$ROOT/bin/heimdall-dream"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf "  \033[32mPASS\033[0m %s\n" "$1"; }
bad() { FAIL=$((FAIL+1)); printf "  \033[31mFAIL\033[0m %s\n" "$1"; }

[ -f "$INSTALL_SH" ] || { echo "FATAL: install.sh missing: $INSTALL_SH" >&2; exit 2; }
[ -x "$UPDATER" ]    || { echo "FATAL: updater missing: $UPDATER" >&2; exit 2; }
[ -x "$SCHED" ]      || { echo "FATAL: schedule helper missing: $SCHED" >&2; exit 2; }
[ -x "$DREAM" ]      || { echo "FATAL: dream bin missing: $DREAM" >&2; exit 2; }

echo "── dream-install-wire ──"

# ── 0. syntax ──────────────────────────────────────────────────────────────────
bash -n "$INSTALL_SH" && ok "bash -n install.sh"            || bad "install.sh syntax error"
bash -n "$UPDATER"    && ok "bash -n bin/heimdall-autoupdate" || bad "autoupdate syntax error"

# ── 1. STATIC grep proofs (the wiring exists, gated + non-fatal) ─────────────────
if grep -q 'ensure_dream_schedule "\$PLUGIN_DIR"' "$INSTALL_SH" \
   && grep -q 'heimdall-dream-schedule' "$INSTALL_SH"; then
  ok "1 install.sh calls ensure_dream_schedule + the schedule helper"
else
  bad "1 install.sh does NOT wire ensure_dream_schedule"
fi
if grep -q 'HEIMDALL_NO_DREAM_SCHEDULE' "$INSTALL_SH"; then
  ok "1 install.sh honors the HEIMDALL_NO_DREAM_SCHEDULE opt-out"
else
  bad "1 install.sh missing the opt-out gate"
fi
if grep -q '"\$(uname -s 2>/dev/null)" = "Darwin"' "$INSTALL_SH"; then
  ok "1 install.sh is macOS-gated (uname = Darwin)"
else
  bad "1 install.sh not macOS-gated"
fi
if grep -qF '▸ nightly /dream scheduled (03:00) — disable: heimdall-dream-schedule uninstall' "$INSTALL_SH"; then
  ok "1 install.sh announces the schedule + disable hint"
else
  bad "1 install.sh missing the announce line"
fi
if grep -q 'reassert_dream_schedule' "$UPDATER" \
   && grep -q 'heimdall-dream-schedule' "$UPDATER"; then
  ok "1 heimdall-autoupdate re-asserts the schedule post-update"
else
  bad "1 heimdall-autoupdate does NOT re-assert the schedule"
fi

# ── shared hermetic fixtures ─────────────────────────────────────────────────────
WORK="$(mktemp -d -t "dream-wire.$(printf 'X%.0s' 1 2 3 4 5 6)")"
trap 'rm -rf "$WORK"' EXIT

SHIM="$WORK/mock-launchctl"; STATE="$WORK/loaded"; CALLS="$WORK/calls"
cat > "$SHIM" <<EOF
#!/usr/bin/env bash
echo "\$@" >> "$CALLS"
case "\$1" in
  load|bootstrap)  : > "$STATE"; exit 0 ;;
  unload|bootout)  rm -f "$STATE"; exit 0 ;;
  list)            if [ -n "\${2:-}" ]; then [ -f "$STATE" ] && exit 0 || exit 1; fi; [ -f "$STATE" ] && echo "-	0	com.heimdall.dream"; exit 0 ;;
  print)           [ -f "$STATE" ] && exit 0 || exit 1 ;;
  *)               exit 0 ;;
esac
EOF
chmod +x "$SHIM"

# uname shim (PATH-injected) → forces a non-Darwin verdict for the "skips cleanly" case.
UBIN="$WORK/ubin"; mkdir -p "$UBIN"
printf '#!/usr/bin/env bash\necho Linux\n' > "$UBIN/uname"; chmod +x "$UBIN/uname"

LA="$WORK/LaunchAgents"; LOG="$WORK/logs/dream.log"
PLIST="$LA/com.heimdall.dream.plist"
HMDHOME="$WORK/home"

# ── CANONICAL vs EPHEMERAL plugin trees ──────────────────────────────────────────
# The register path refuses a command path inside a LINKED git worktree (the incident:
# a nightly job pinned to .claude/worktrees/agent-<id>, a tree that is later reaped).
# $ROOT is the MAIN worktree for a human and a LINKED worktree for an agent, so driving
# the wiring from $ROOT would make this suite's verdict depend on WHO ran it. These two
# checkouts of one commit hold byte-identical bins and differ only in worktree-ness —
# which makes §2/§3/§7 deterministic and gives §9 a clean control.
#
# Both paths are PHYSICAL (pwd -P). mktemp hands back /var/folders/..., but /var is a
# symlink to /private/var, and the updater canonicalizes its own location through
# `readlink -f` — so a logical fixture path makes §7 compare /var/... against
# /private/var/... and fail for a reason that has nothing to do with the schedule.
CANON="$WORK/canonical"; EPHEM="$WORK/ephemeral"
mkdir -p "$CANON/bin/lib"
CANON="$(cd "$CANON" && pwd -P)"
cp "$SCHED" "$CANON/bin/heimdall-dream-schedule"
cp "$DREAM" "$CANON/bin/heimdall-dream"
cp "$ROOT/bin/lib/real-home.sh" "$CANON/bin/lib/real-home.sh"
# tcc-paths.sh supplies the protected-path predicate the register path gates its own
# artifacts on. It fails SAFE when undefined (refuse, exit 6), so a fixture missing this
# file does not degrade — it stops installing entirely.
cp "$ROOT/bin/lib/tcc-paths.sh" "$CANON/bin/lib/tcc-paths.sh"
# The runner is ProgramArguments[0] — the register path stages it outside the repo, so a
# checkout without it cannot install (by design: a plist pointing at a program that does
# not exist is the silent-death mode this whole change exists to end).
cp "$ROOT/bin/heimdall-dream-runner" "$CANON/bin/heimdall-dream-runner"
# A real COPY of the updater, never a symlink: it resolves its own PLUGIN_DIR from
# BASH_SOURCE through readlink -f, so a link would point §7 straight back at $ROOT.
cp "$UPDATER" "$CANON/bin/heimdall-autoupdate"
chmod +x "$CANON/bin/heimdall-dream-schedule" "$CANON/bin/heimdall-dream" \
         "$CANON/bin/heimdall-dream-runner" "$CANON/bin/heimdall-autoupdate"
git -C "$CANON" init -q
git -C "$CANON" add -A >/dev/null 2>&1
git -C "$CANON" -c user.email=t@t -c user.name=t commit -qm fixture >/dev/null 2>&1
git -C "$CANON" worktree add --detach -q "$EPHEM" >/dev/null 2>&1
EPHEM="$(cd "$EPHEM" 2>/dev/null && pwd -P || printf '%s' "$EPHEM")"

DREAM_CANON="$CANON/bin/heimdall-dream"
UPDATER_CANON="$CANON/bin/heimdall-autoupdate"

if [ -d "$CANON/.git" ] && [ -f "$EPHEM/.git" ] && [ -x "$EPHEM/bin/heimdall-dream-schedule" ]; then
  ok "1 fixture: CANON is the main worktree, EPHEM is a linked worktree of the same commit"
else
  bad "1 fixture not built (CANON/.git dir=$([ -d "$CANON/.git" ] && echo yes || echo no), EPHEM/.git file=$([ -f "$EPHEM/.git" ] && echo yes || echo no))"
fi

# Run ensure_dream_schedule (from install.sh) in an isolated subshell, print its state word.
# $1 = plugin_dir; remaining args = extra `export`s (e.g. an opt-out or PATH override).
run_ensure() {
  local plugin_dir="$1"; shift
  ( set +e
    export HEIMDALL_LAUNCH_AGENTS_DIR="$LA" HEIMDALL_DREAM_LOG="$LOG" LAUNCHCTL="$SHIM" \
           HEIMDALL_INSTALL_SOURCE_ONLY=1 "$@"
    source "$INSTALL_SH"
    ensure_dream_schedule "$plugin_dir" )
}

# ── 2. install-wire SCHEDULES on macOS (real uname=Darwin here) + encodes the argv ─
rm -f "$PLIST"; : > "$CALLS"
S="$(run_ensure "$CANON")"
if [ "$S" = "scheduled" ] && [ -f "$PLIST" ]; then
  ok "2 install-wire registers the nightly LaunchAgent (state=scheduled, plist written)"
else
  bad "2 install-wire did not schedule (state='$S', plist? $( [ -f "$PLIST" ] && echo yes || echo no))"
fi
if grep -q "<string>$DREAM_CANON</string>" "$PLIST" 2>/dev/null \
   && grep -q "<string>$CANON</string>" "$PLIST" 2>/dev/null \
   && grep -q "<string>run</string>" "$PLIST" 2>/dev/null \
   && grep -q "<string>--overnight</string>" "$PLIST" 2>/dev/null; then
  ok "2 plist encodes 'heimdall-dream --repo <installed-checkout> run --overnight' (stable bin path)"
else
  bad "2 plist ProgramArguments wrong / not pointed at the installed checkout"
fi
grep -q "^load" "$CALLS" 2>/dev/null \
  && ok "2 install-wire loaded the agent via launchctl" \
  || bad "2 launchctl load not invoked"

# ── 3. IDEMPOTENT — a second install-wire leaves exactly ONE plist ───────────────
S2="$(run_ensure "$CANON")"
N="$(find "$LA" -name 'com.heimdall.dream.plist' | wc -l | tr -d ' ')"
if [ "$S2" = "scheduled" ] && [ "$N" = "1" ]; then
  ok "3 re-running install-wire is idempotent (exactly ONE plist, no duplicate)"
else
  bad "3 install-wire not idempotent (state='$S2', plist count=$N)"
fi

# ── 4. OPT-OUT — HEIMDALL_NO_DREAM_SCHEDULE=1 skips, touches nothing ─────────────
rm -f "$PLIST"; : > "$CALLS"
S="$(run_ensure "$CANON" HEIMDALL_NO_DREAM_SCHEDULE=1)"
if [ "$S" = "optout" ] && [ ! -f "$PLIST" ] && [ ! -s "$CALLS" ]; then
  ok "4 opt-out (HEIMDALL_NO_DREAM_SCHEDULE=1) skips: no plist, no launchctl call"
else
  bad "4 opt-out not honored (state='$S', plist? $( [ -f "$PLIST" ] && echo yes || echo no))"
fi

# ── 5. NON-DARWIN — a Linux/headless box skips cleanly, non-fatal (rc 0) ─────────
rm -f "$PLIST"; : > "$CALLS"
S="$(run_ensure "$CANON" PATH="$UBIN:$PATH")"; rc=$?
if [ "$rc" -eq 0 ] && [ "$S" = "unsupported" ] && [ ! -f "$PLIST" ]; then
  ok "5 non-Darwin skips cleanly (state=unsupported, rc=0, no plist — never fails install)"
else
  bad "5 non-Darwin not skipped cleanly (rc=$rc state='$S')"
fi

# ── 6. NON-FATAL — a missing schedule helper degrades to 'skipped', rc 0 ─────────
S="$(run_ensure "$WORK/no-such-plugin-dir")"; rc=$?
if [ "$rc" -eq 0 ] && [ "$S" = "skipped" ]; then
  ok "6 missing schedule helper → state=skipped, rc=0 (best-effort, never aborts install)"
else
  bad "6 missing helper not handled gracefully (rc=$rc state='$S')"
fi

# ── 7. POST-UPDATE RE-ASSERT — heimdall-autoupdate re-registers the schedule ─────
rm -f "$PLIST"; : > "$CALLS"
( set +e
  export HEIMDALL_LAUNCH_AGENTS_DIR="$LA" HEIMDALL_DREAM_LOG="$LOG" LAUNCHCTL="$SHIM" \
         HEIMDALL_HOME="$HMDHOME" HEIMDALL_AUTOUPDATE_SOURCE_ONLY=1
  source "$UPDATER_CANON"
  reassert_dream_schedule ) ; rc=$?
if [ "$rc" -eq 0 ] && [ -f "$PLIST" ] && grep -q "^load" "$CALLS" 2>/dev/null; then
  ok "7 post-update reassert_dream_schedule re-registers + loads the nightly agent (rc=0)"
else
  bad "7 post-update re-assert did not register (rc=$rc, plist? $( [ -f "$PLIST" ] && echo yes || echo no))"
fi
# the re-assert plist points at the current installed dream bin (stays current across updates)
grep -q "<string>$DREAM_CANON</string>" "$PLIST" 2>/dev/null \
  && ok "7 re-asserted plist points at the current installed dream bin (never version-frozen)" \
  || bad "7 re-asserted plist does not point at the installed dream bin"

# ── 8. RE-ASSERT honors the opt-out too ──────────────────────────────────────────
rm -f "$PLIST"; : > "$CALLS"
( set +e
  export HEIMDALL_LAUNCH_AGENTS_DIR="$LA" HEIMDALL_DREAM_LOG="$LOG" LAUNCHCTL="$SHIM" \
         HEIMDALL_HOME="$HMDHOME" HEIMDALL_AUTOUPDATE_SOURCE_ONLY=1 HEIMDALL_NO_DREAM_SCHEDULE=1
  source "$UPDATER_CANON"
  reassert_dream_schedule ) ; rc=$?
if [ "$rc" -eq 0 ] && [ ! -f "$PLIST" ]; then
  ok "8 post-update re-assert honors HEIMDALL_NO_DREAM_SCHEDULE (skips, rc=0, no plist)"
else
  bad "8 re-assert ignored the opt-out (rc=$rc, plist? $( [ -f "$PLIST" ] && echo yes || echo no))"
fi

# ── 9. EPHEMERAL CHECKOUT — install-wire refuses, and SAYS which refusal it was ──
#
# THE INCIDENT. An agent ran a real install from an agent worktree with a GENUINE $HOME.
# Every existing gate passed — opt-out unset, macOS, launchctl present, real passwd home
# — and install.sh happily registered a nightly job pointing at
# .claude/worktrees/agent-<id>/bin/heimdall-dream. That worktree was reaped; the job has
# pointed at nothing ever since, silently.
#
# The state word matters as much as the refusal. 'sandboxed', 'ephemeral' and 'skipped'
# are three different operator actions (fix your HOME / re-run from the main checkout /
# something actually broke). Collapsing the new case into 'skipped' would hide from the
# NEXT agent exactly why the schedule is missing — which is how a silent outage lasts.
rm -f "$PLIST"; : > "$CALLS"
S="$(run_ensure "$EPHEM")"; rc=$?
if [ "$rc" -eq 0 ] && [ "$S" = "ephemeral" ]; then
  ok "9 install-wire maps the worktree refusal to state=ephemeral (rc=0, non-fatal)"
else
  bad "9 wrong state for an ephemeral checkout (state='$S', rc=$rc — want 'ephemeral')"
fi
if [ ! -f "$PLIST" ] && [ ! -s "$CALLS" ]; then
  ok "9 install-wire from a linked worktree: no plist, launchctl NEVER called (the incident assertion)"
else
  bad "9 EPHEMERAL GUARD FAILED via install-wire (plist? $( [ -f "$PLIST" ] && echo yes || echo no), calls=$(tr '\n' ' ' < "$CALLS" 2>/dev/null))"
fi
if grep -q "5) printf 'ephemeral'" "$INSTALL_SH"; then
  ok "9 install.sh maps the helper's distinct exit 5 to its own state word"
else
  bad "9 install.sh does not map exit 5 → ephemeral"
fi
if grep -qF 'ephemeral checkout' "$INSTALL_SH"; then
  ok "9 install.sh renders the ephemeral refusal in words, not as a bare 'skipped'"
else
  bad "9 install.sh has no operator-facing wording for the ephemeral refusal"
fi

echo ""
echo "── dream-install-wire: $PASS passed, $FAIL failed ──"
[ "$FAIL" -eq 0 ] || exit 1
