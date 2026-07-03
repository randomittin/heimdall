#!/usr/bin/env bash
# test/heimdall-rr.test.sh — acceptance for `rr` (remote-run): the LOCAL→CLOUD
# maintainer handoff (bin/rr).
#
# HERMETIC: `gh` and `gcloud` are FAKE binaries on PATH (they only LOG their argv
# and echo canned shapes) and $HOME is a throwaway dir, so NOTHING here touches a
# live repo, a real VM, the network, or any credential. `rr` never handles a
# secret by design (the VM owns its creds), so no token is ever piped/echoed.
#
# FALSIFIABLE claims proven:
#   (1) SETUP        — `rr setup ...` writes ~/.heimdall/remote.json with the exact
#                      cloud-target shape (vm/zone/project/repo/mode).
#   (2) DRY-RUN PLAN — `rr "<task>" --dry-run` PRINTS the gh-issue-create plan AND
#                      the ssh maintainer-run plan, and EXECUTES nothing (fake gh +
#                      gcloud are never invoked — their argv logs stay empty).
#   (3) IDEMPOTENT   — a REAL dispatch whose derived title already has an OPEN
#                      maintainer issue does NOT re-file (gh issue create is never
#                      called); a DIFFERENT title DOES file (positive control).
#   (4) --issue N    — `rr --issue N --dry-run` SKIPS filing (no issue create) and
#                      still prints the dispatch-to-drain-#N plan.
#   (5) NO REMOTE    — a real cloud dispatch with NO remote.json FAILS CLOSED with a
#                      clear "run rr setup" message, and files NOTHING first.
#   (6) --local      — `rr --local --dry-run "<task>"` prints the LOCAL maintain-loop
#                      run path (clearly marked local, NOT cloud — no ssh).
#   (7) NO SECRET    — no token-shaped string is ever emitted on any surface.
#
# Mocks in the TEST are fine; production (bin/rr) has no stubs.

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
RR="$ROOT/bin/rr"

PASS=0
FAIL=0
ok()  { PASS=$((PASS+1)); printf "  \033[32mPASS\033[0m %s\n" "$1"; }
bad() { FAIL=$((FAIL+1)); printf "  \033[31mFAIL\033[0m %s\n" "$1"; }

PY="$(command -v python3 || command -v python)"
[ -f "$RR" ] || { echo "FATAL: $RR missing (implement bin/rr)" >&2; exit 1; }
[ -x "$RR" ] || { echo "FATAL: $RR not executable" >&2; exit 1; }

WORK="$(mktemp -d -t "heimdall-rr-test.$(printf 'X%.0s' 1 2 3 4 5 6)")"
trap 'rm -rf "$WORK"' EXIT

# ── isolate HOME (remote.json + dispatch log land under the throwaway home) ────
export HOME="$WORK/home"
mkdir -p "$HOME/.heimdall"

# ── fake gh + gcloud on PATH (log argv only; echo canned shapes) ───────────────
FAKEBIN="$WORK/bin"; mkdir -p "$FAKEBIN"
export GH_LOG="$WORK/gh.log"
export GCLOUD_LOG="$WORK/gcloud.log"
: > "$GH_LOG"; : > "$GCLOUD_LOG"

# FAKE_GH_ISSUES: the JSON the mock `gh issue list` returns (idempotency seam).
export FAKE_GH_ISSUES='[]'

cat > "$FAKEBIN/gh" <<'GHEOF'
#!/usr/bin/env bash
# MOCK gh — records argv, echoes canned shapes. NO network, NO creds.
printf '%s\n' "$*" >> "$GH_LOG"
sub="${1:-}"; shift || true
case "$sub" in
  issue)
    case "${1:-}" in
      list)   printf '%s' "${FAKE_GH_ISSUES:-[]}" ;;
      create) echo "https://github.com/acme/widget/issues/123" ;;
      *)      : ;;
    esac ;;
  pr)   echo "(mock) no open maintainer PRs" ;;
  auth) exit 0 ;;
  label) exit 0 ;;
  *)     : ;;
esac
GHEOF
chmod +x "$FAKEBIN/gh"

cat > "$FAKEBIN/gcloud" <<'GCEOF'
#!/usr/bin/env bash
# MOCK gcloud — records argv, echoes nothing meaningful, exit 0. NEVER a real SSH.
printf '%s\n' "$*" >> "$GCLOUD_LOG"
exit 0
GCEOF
chmod +x "$FAKEBIN/gcloud"

export PATH="$FAKEBIN:$PATH"

# ── (1) setup writes remote.json with the cloud-target shape ───────────────────
"$RR" setup --vm testvm --zone us-central1-a --project heimdall-test --repo acme/widget >/dev/null 2>&1
if [ -f "$HOME/.heimdall/remote.json" ]; then
  shape_ok=$("$PY" - "$HOME/.heimdall/remote.json" <<'PYEOF'
import json, sys
d = json.load(open(sys.argv[1]))
want = {"vm": "testvm", "zone": "us-central1-a",
        "project": "heimdall-test", "repo": "acme/widget", "mode": "vm"}
print("ok" if all(d.get(k) == v for k, v in want.items()) else "bad:%r" % d)
PYEOF
)
  if [ "$shape_ok" = "ok" ]; then
    ok "setup writes ~/.heimdall/remote.json with vm/zone/project/repo/mode"
  else
    bad "remote.json shape wrong ($shape_ok)"
  fi
else
  bad "setup did not write ~/.heimdall/remote.json"
fi

# ── (2) dry-run task prints gh + ssh plan, executes NOTHING ────────────────────
: > "$GH_LOG"; : > "$GCLOUD_LOG"
out2="$("$RR" --dry-run "fix the flaky test" 2>&1)"
plan_gh=0;  echo "$out2" | grep -q "gh issue create" && plan_gh=1
echo "$out2" | grep -q -- "--label maintainer" || plan_gh=0
plan_run=0; echo "$out2" | grep -q "heimdall-maintain-loop run" && plan_run=1
plan_ssh=0; echo "$out2" | grep -q "compute ssh" && plan_ssh=1
if [ "$plan_gh" = 1 ] && [ "$plan_run" = 1 ] && [ "$plan_ssh" = 1 ]; then
  ok "dry-run prints the gh-issue-create + ssh maintainer-run plan"
else
  bad "dry-run plan incomplete (gh=$plan_gh run=$plan_run ssh=$plan_ssh)"
fi
if [ ! -s "$GH_LOG" ] && [ ! -s "$GCLOUD_LOG" ]; then
  ok "dry-run EXECUTES nothing (fake gh + gcloud never invoked)"
else
  bad "dry-run executed a command (gh_log=$(wc -c <"$GH_LOG") gcloud_log=$(wc -c <"$GCLOUD_LOG"))"
fi

# ── (3) idempotent: an existing OPEN maintainer issue is NOT re-filed ──────────
: > "$GH_LOG"; : > "$GCLOUD_LOG"
export FAKE_GH_ISSUES='[{"number":77,"title":"make the widget blue"}]'
"$RR" "make the widget blue" >/dev/null 2>&1 || true
if grep -q "issue list" "$GH_LOG" && ! grep -q "issue create" "$GH_LOG"; then
  ok "idempotent — existing open issue reused, gh issue create NOT called"
else
  bad "idempotency failed (list=$(grep -c 'issue list' "$GH_LOG") create=$(grep -c 'issue create' "$GH_LOG"))"
fi
if grep -q "compute ssh" "$GCLOUD_LOG"; then
  ok "idempotent path still DISPATCHES the maintainer (ssh invoked)"
else
  bad "idempotent path did not dispatch (no ssh)"
fi
# positive control: a DIFFERENT title DOES file
: > "$GH_LOG"
"$RR" "make the widget red" >/dev/null 2>&1 || true
if grep -q "issue create" "$GH_LOG"; then
  ok "positive control — a NEW title DOES file a fresh issue"
else
  bad "positive control failed — a new title was not filed"
fi

# ── (4) --issue N --dry-run skips filing, still dispatches to drain #N ──────────
: > "$GH_LOG"; : > "$GCLOUD_LOG"
out4="$("$RR" --issue 42 --dry-run 2>&1)"
if ! echo "$out4" | grep -q "gh issue create"; then
  ok "--issue N skips filing (no gh issue create in the plan)"
else
  bad "--issue N still printed a gh issue create"
fi
if echo "$out4" | grep -q "compute ssh" && echo "$out4" | grep -q "42"; then
  ok "--issue N dispatches the maintainer to drain #42"
else
  bad "--issue N did not print the drain-#42 dispatch plan"
fi
if [ ! -s "$GH_LOG" ] && [ ! -s "$GCLOUD_LOG" ]; then
  ok "--issue N --dry-run executes nothing"
else
  bad "--issue N --dry-run executed a command"
fi

# ── (5) no remote.json + real dispatch → fail closed, file NOTHING ─────────────
: > "$GH_LOG"; : > "$GCLOUD_LOG"
rm -f "$HOME/.heimdall/remote.json"
err5="$("$RR" "some task with no remote" 2>&1)" && rc5=0 || rc5=$?
if [ "${rc5:-0}" -ne 0 ] && echo "$err5" | grep -qi "rr setup"; then
  ok "no remote.json → fail-closed with a clear 'rr setup' message"
else
  bad "no-remote did not fail closed with the setup hint (rc=$rc5): $err5"
fi
if [ ! -s "$GH_LOG" ]; then
  ok "no-remote fails BEFORE filing (no gh issue create)"
else
  bad "no-remote filed an issue before failing (leak): $(cat "$GH_LOG")"
fi

# ── (6) --local --dry-run prints the LOCAL run path (not cloud) ────────────────
out6="$("$RR" --local --dry-run "do the thing locally" 2>&1)"
if echo "$out6" | grep -q "heimdall-maintain-loop run" && echo "$out6" | grep -qi "local"; then
  ok "--local prints the local maintain-loop run path (marked local)"
else
  bad "--local did not print the local run path"
fi
if ! echo "$out6" | grep -q "compute ssh"; then
  ok "--local does NOT dispatch to the cloud (no ssh)"
else
  bad "--local printed a cloud ssh dispatch"
fi

# ── (7) no secret ever echoed on any surface ───────────────────────────────────
allout="$(
  "$RR" --dry-run "another task" 2>&1
  "$RR" setup --vm v2 --zone z2 --project p2 2>&1
  "$RR" --issue 9 --dry-run 2>&1
)"
if echo "$allout" | grep -qE 'gh[ps]_[A-Za-z0-9]{8,}|CLAUDE_CODE_OAUTH_TOKEN=[^ ]|BOT_TOKEN=[A-Za-z0-9]'; then
  bad "a token-shaped string leaked into rr output"
else
  ok "no secret is ever echoed (rr never handles creds — the VM owns them)"
fi

echo
echo "════════════════════════════════════════════════════════════════════════════"
printf "rr: \033[32m%d passed\033[0m, " "$PASS"
if [ "$FAIL" -gt 0 ]; then
  printf "\033[31m%d failed\033[0m\n" "$FAIL"
  exit 1
fi
printf "%d failed\n" "$FAIL"
echo "ALL GREEN — setup · dry-run plan · idempotent · --issue · fail-closed · --local · secret-safe"
