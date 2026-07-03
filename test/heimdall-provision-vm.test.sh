#!/usr/bin/env bash
# heimdall-provision-vm.test.sh — proves deploy/gce/provision-maintainer-vm.sh provisions the
# persistent maintainer VM (OpenClaw-in-cloud) as TWO interactive phases, statically +
# hermetically ($0, NO gcloud/ssh/creds, no network):
#
#   A. SYNTAX: `bash -n` is clean on provision-maintainer-vm.sh.
#   B. PHASE 1 DRY-RUN NEEDS NO CREDS: fake gcloud+ssh shims that FAIL-on-invoke are prepended to
#      PATH; `--dry-run provision` must EXIT 0 and NEVER invoke either (the whole plan is printed).
#   C. PHASE 1 PLAN: the create-VM plan (instances create · e2-small · Debian · startup-script)
#      is printed, AND the interactive login-relay steps (ssh --tunnel-through-iap ·
#      `claude auth login` · paste the code back · `claude -p "ok"` verify · creds persist at
#      ~/.claude/.credentials.json).
#   D. PHASE 2 PLAN: `install-maintainer --dry-run --repo x/y` prints the 0600 env-file plan
#      (HEIMDALL_JOB_RUNNER=subprocess · HEIMDALL_MAINTAINER_RUNNER=hybrid · chmod 600) and the
#      cron/timer plan (runner-beat every minute + `heimdall-maintain-loop run --max`).
#   E. BAD --repo REJECTED: a non `owner/name` value fails fast (nonzero) before any side effect.
#   F. NO SECRET ECHOED: no token literal appears in EITHER phase's dry-run output, INCLUDING a
#      fake HEIMDALL_PR_BOT_TOKEN placed in the env (it must never reach stdout).
#   G. SECRET-SAFE BY SOURCE: the bot token is prompted with `read -rs`, crosses to the VM via
#      ssh STDIN (a pipe), NEVER an argv/`--command` element; no `echo $..TOKEN`; no `set -x`.
#
# Exit 0 = every proof holds. Nonzero = a proof failed (prints which).
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
S="$ROOT/deploy/gce/provision-maintainer-vm.sh"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf "  \033[32mPASS\033[0m %s\n" "$1"; }
bad() { FAIL=$((FAIL+1)); printf "  \033[31mFAIL\033[0m %s\n" "$1"; }

[ -x "$S" ] || { echo "FATAL: $S not found/executable"; exit 2; }

echo "== A. syntax: bash -n =="
bash -n "$S" 2>/dev/null && ok "provision-maintainer-vm.sh: bash -n clean" || bad "provision-maintainer-vm.sh: bash -n FAILED"

# fake gcloud + ssh shims that record + FAIL if ever invoked (dry-run must touch neither).
SHIMDIR="$(mktemp -d)"; SENTINEL="$SHIMDIR/invoked"
for tool in gcloud ssh; do
  cat > "$SHIMDIR/$tool" <<SH
#!/usr/bin/env bash
echo "$tool INVOKED: \$*" >> "$SENTINEL"
exit 1
SH
  chmod +x "$SHIMDIR/$tool"
done

echo "== B. phase 1 (provision) dry-run needs NO creds =="
P1="$(PATH="$SHIMDIR:$PATH" "$S" --dry-run provision 2>&1)"; RC=$?
[ "$RC" = 0 ] && ok "dry-run provision exited 0 with no real gcloud/ssh on PATH" || bad "dry-run provision exited $RC (expected 0)"
[ ! -f "$SENTINEL" ] && ok "dry-run provision invoked NEITHER gcloud NOR ssh (no creds/side effects)" \
  || bad "dry-run provision INVOKED a real tool: $(cat "$SENTINEL" 2>/dev/null)"

echo "== C. phase 1 plan: create-VM + interactive login relay =="
has1() { printf '%s' "$P1" | grep -qF "$1" && ok "phase1 shows: $2" || bad "phase1 MISSING: $2"; }
hasre1(){ printf '%s' "$P1" | grep -qE "$1" && ok "phase1 shows: $2" || bad "phase1 MISSING: $2"; }
hasre1 'compute instances (describe|create)'          "guarded VM create (describe || create)"
has1  'e2-small'                                       "e2-small machine type"
hasre1 'image-family debian|debian-1[0-9]|ubuntu'      "Debian/Ubuntu image"
hasre1 'startup-script'                                "startup script attached"
has1  'tunnel-through-iap'                             "login relay: ssh via IAP tunnel"
hasre1 'claude auth login|^ *claude *$| claude *(#|$)' "login relay: run claude / claude auth login on the VM"
hasre1 'paste'                                         "login relay: paste the code back on the VM"
has1  'claude -p'                                      "login relay: claude -p verify liveness"
has1  '.claude/.credentials.json'                      "creds persist at ~/.claude/.credentials.json on the VM"
# the startup toolchain the VM installs
hasre1 '@anthropic-ai/claude-code'                     "startup installs the claude CLI"
hasre1 '\bgh\b|githubcli'                              "startup installs gh"
hasre1 '\bgit\b'                                       "startup installs git"
hasre1 'node|nodejs|setup_20'                          "startup installs node20"

echo "== D. phase 2 plan: install-maintainer env-file + timer =="
P2="$(PATH="$SHIMDIR:$PATH" "$S" install-maintainer --dry-run --repo acme/widgets 2>&1)"; RC2=$?
[ "$RC2" = 0 ] && ok "install-maintainer dry-run exited 0" || bad "install-maintainer dry-run exited $RC2 (expected 0)"
[ ! -f "$SENTINEL" ] && ok "phase 2 dry-run invoked no real gcloud/ssh" || bad "phase 2 dry-run INVOKED a real tool: $(cat "$SENTINEL" 2>/dev/null)"
has2() { printf '%s' "$P2" | grep -qF "$1" && ok "phase2 shows: $2" || bad "phase2 MISSING: $2"; }
hasre2(){ printf '%s' "$P2" | grep -qE "$1" && ok "phase2 shows: $2" || bad "phase2 MISSING: $2"; }
has2  'HEIMDALL_JOB_RUNNER=subprocess'                 "env: HEIMDALL_JOB_RUNNER=subprocess"
has2  'HEIMDALL_MAINTAINER_RUNNER=hybrid'              "env: HEIMDALL_MAINTAINER_RUNNER=hybrid"
hasre2 'maintainer.env'                                "writes the maintainer env file"
hasre2 'chmod 600|umask 177|umask 0*177'               "env file is 0600 (owner-only)"
hasre2 'runner-beat'                                   "cron/timer: runner-beat liveness"
hasre2 'heimdall-maintain-loop run --max|maintain-loop run --max' "cron/timer: bounded run --max cycle"
hasre2 'tunnel-through-iap'                             "phase 2 reaches the VM over IAP ssh"

echo "== E. a bad --repo is rejected (fail-closed) =="
if "$S" install-maintainer --dry-run --repo not-a-slug >/dev/null 2>&1; then
  bad "E accepted a malformed --repo (must reject non owner/name)"
else
  ok "E rejected malformed --repo before any side effect"
fi

echo "== F. no secret literal echoed in EITHER phase (incl. a fake token in env) =="
# a fake bot token placed in the env must NEVER reach stdout on either phase's dry-run.
PF1="$(HEIMDALL_PR_BOT_TOKEN=SECRET-XYZ PATH="$SHIMDIR:$PATH" "$S" --dry-run provision 2>&1)"
PF2="$(HEIMDALL_PR_BOT_TOKEN=SECRET-XYZ PATH="$SHIMDIR:$PATH" "$S" install-maintainer --dry-run --repo acme/widgets 2>&1)"
if printf '%s%s' "$PF1" "$PF2" | grep -q 'SECRET-XYZ'; then
  bad "F a fake bot-token value leaked to stdout"
else
  ok "F no fake token value on stdout in either phase"
fi
if printf '%s%s' "$P1" "$P2" | grep -qE 'sk-ant-(oat|api)|ghs-[A-Za-z0-9]|ghp_[A-Za-z0-9]'; then
  bad "F a token-shaped literal appeared in the plan output"
else
  ok "F no sk-ant / ghs / ghp token literal anywhere in the plans"
fi

echo "== G. secret-safe BY SOURCE (read -rs · stdin pipe · no echo · no set -x) =="
grep -qE 'read -rs|read -r -s' "$S" && ok "G bot token prompted with read -rs (never echoed)" || bad "G no read -rs for the bot token"
grep -qE '^[[:space:]]*set -x' "$S" && bad "G contains set -x (would leak the token to a trace)" || ok "G no set -x anywhere"
if grep -qE 'echo[[:space:]]+"?\$\{?[A-Z_]*TOKEN' "$S"; then
  bad "G a bare echo of a *_TOKEN variable to stdout was found"
else
  ok "G no bare echo of a token variable"
fi
# the token must cross to the VM on STDIN (a pipe into ssh), NOT as an argv/--command element.
grep -qE 'ssh_write_envfile|env_stdin|\| *(run +)?gcloud compute ssh|BOT_TOKEN[^\n]*\| *gcloud' "$S" \
  && ok "G token reaches the VM via ssh STDIN (pipe), not argv" \
  || bad "G no stdin-pipe path for the token to the VM (must not be an argv element)"

echo
echo "provision-vm: $PASS passed, $FAIL failed"
rm -rf "$SHIMDIR"
[ "$FAIL" -eq 0 ] || exit 1
