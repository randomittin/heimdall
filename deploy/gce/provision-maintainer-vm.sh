#!/usr/bin/env bash
# provision-maintainer-vm.sh — "OpenClaw-in-cloud": a PERSISTENT GCE VM that runs the Heimdall
# maintainer, authenticated by an INTERACTIVE `claude` login done ON the VM (the login CODE is
# relayed to the operator's browser and pasted back on the VM) — NOT a pre-minted setup-token.
#
# WHY A VM (not a Cloud Run Job). Cloud Run Jobs are BATCH / non-interactive: there is no TTY to
# paste a login code into. An interactive `claude auth login` code-relay REQUIRES a persistent
# machine you SSH into. So this is Arch A (the operator's own box, MAINTAINER-RUNBOOK.md §2)
# RELOCATED onto a cloud VM: the VM holds the subscription creds (a portable Linux
# ~/.claude/.credentials.json), runs bin/heimdall-maintain-loop, and BEATS runner-liveness so the
# hybrid selector (bin/lib/cp_maintainer_runner.py) routes the maintainer cycle to it. RJ is a
# personal Max ($200) org with NO forceLoginMethod block, so subscription OAuth works headless.
#
# RUN BY THE OPERATOR (RJ) on his own machine with his gcloud creds. The agent never runs this.
# The OAuth login is INTERACTIVE + MANUAL: this script only PRINTS the relay steps — it never
# handles the OAuth secret. The bot token is prompted with `read -rs` and streamed to the VM over
# ssh STDIN (a pipe) into a 0600 env file — NEVER an argv/`--command` element, never echoed,
# never logged. No `set -x` (a trace would leak the token). Secret discipline mirrors
# deploy/cloud-run/deploy-maintainer.sh.
#
# TWO PHASES (the login is interactive, so it cannot be one command):
#
#   provision (default)          create the VM + install the toolchain, then PRINT the exact
#                                interactive login-relay commands for RJ to run himself.
#   install-maintainer --repo R  AFTER the login succeeds: write the 0600 env file on the VM
#                                (bot token over ssh stdin), clone the target repo, install the
#                                cron (runner-beat 1/min + bounded `run --max N` cycle), smoke.
#
# Usage:
#   provision-maintainer-vm.sh [provision] [--project <id>] [--zone <z>] [--vm <name>] \
#                              [--machine-type <t>] [--dry-run]
#   provision-maintainer-vm.sh install-maintainer --repo <owner/repo> [--project <id>] \
#                              [--zone <z>] [--vm <name>] [--max <N>] [--cron "<expr>"] \
#                              [--clone-path <dir>] [--dry-run]
#   --dry-run prints the FULL plan (create VM + startup script + login relay + install plan),
#             executes nothing, and needs NO gcloud/ssh/creds.
#
# The maintainer OPENS PRs via the scoped bot token on heimdall/* branches — it NEVER pushes
# main, NEVER merges. A HUMAN (RJ) merges.
set -euo pipefail

# ── defaults ─────────────────────────────────────────────────────────────────
CMD=""
PROJECT="heimdall-control-plane"
ZONE="us-central1-a"
VM="heimdall-maintainer-vm"
MACHINE_TYPE="e2-small"
REPO=""
MAXN="3"
CRON="*/30 * * * *"
CLONE_PATH=""
DRY=0

# The heimdall repo the VM clones to get bin/heimdall-maintain-loop + bin/lib on PATH. Public
# clone = the simplest reproducible path (no creds needed at startup); documented in the header.
HEIMDALL_REPO_URL="https://github.com/randomittin/heimdall.git"
HEIMDALL_DIR="/opt/heimdall"                    # where the toolchain clone lands on the VM
ENVFILE_REL=".heimdall/maintainer.env"          # 0600 env file, relative to the ssh user's HOME

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() { sed -n '/^# Usage:/,/executes nothing/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

# ── arg parse (the subcommand may appear in ANY position) ────────────────────
while [ $# -gt 0 ]; do case "$1" in
  provision|install-maintainer) CMD="$1"; shift ;;
  --project)      PROJECT="${2:?}";      shift 2 ;;
  --zone)         ZONE="${2:?}";         shift 2 ;;
  --vm)           VM="${2:?}";           shift 2 ;;
  --machine-type) MACHINE_TYPE="${2:?}"; shift 2 ;;
  --repo)         REPO="${2:?}";         shift 2 ;;
  --max)          MAXN="${2:?}";         shift 2 ;;
  --cron)         CRON="${2:?}";         shift 2 ;;
  --clone-path)   CLONE_PATH="${2:?}";   shift 2 ;;
  --dry-run)      DRY=1;                 shift ;;
  -h|--help)      usage; exit 0 ;;
  *) echo "unknown arg: $1" >&2; usage >&2; exit 2 ;;
esac; done
[ -n "$CMD" ] || CMD="provision"

say()  { printf '\033[36m▸ %s\033[0m\n' "$*"; }
warn() { printf '\033[33m! %s\033[0m\n' "$*" >&2; }
die()  { printf '\033[31m✗ %s\033[0m\n' "$*" >&2; exit 1; }
# run: in --dry-run print the command (NO secret is ever an argv here), else execute it.
run()  { if [ "$DRY" = 1 ]; then printf '  \033[90m$ %s\033[0m\n' "$*"; else "$@"; fi; }

# validate a repo slug (owner/name, no shell metacharacters) — the same gate the §1 allowlist uses.
valid_repo() { printf '%s' "$1" | grep -qE '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$'; }

# ── preflight (creds only when NOT dry-run) ──────────────────────────────────
preflight() {
  need() { command -v "$1" >/dev/null 2>&1 || die "missing '$1' — $2"; }
  [ "$DRY" = 1 ] && return 0
  need gcloud "install the Google Cloud SDK (https://cloud.google.com/sdk)"
  gcloud auth print-access-token >/dev/null 2>&1 || die "run: gcloud auth login"
}

# ── the VM startup script (installs the full toolchain the maintainer shells out to) ──
# Runs AS ROOT on first boot. Installs git + gh + node20 + the claude CLI + python3 with the
# EXACT pinned deps from deploy/cloud-run/Dockerfile.maintainer, clones the heimdall repo to
# /opt/heimdall, and puts its bins on PATH for every login shell via /etc/profile.d. No creds are
# baked in — the interactive `claude` login (relayed to RJ's browser) provides the subscription
# auth AFTER boot, and the bot token is written by phase 2 over ssh stdin.
emit_startup_script() {
  cat <<STARTUP
#!/usr/bin/env bash
# Heimdall maintainer VM — first-boot toolchain install (git + gh + node20/claude + python deps).
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

# system toolchain: git (branches/stages fixes), python3 (durable state backend), cron (the
# maintainer schedule + runner-beat), curl/gnupg/ca-certificates (fetch the gh + node keyrings).
apt-get update
apt-get install --no-install-recommends -y \\
    bash git ca-certificates curl gnupg python3 python3-pip cron

# GitHub CLI (gh) — the maintainer OPENS PRs with it — from GitHub's OFFICIAL apt repo.
mkdir -p -m 755 /etc/apt/keyrings
curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \\
    -o /etc/apt/keyrings/githubcli-archive-keyring.gpg
chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg
echo "deb [arch=\$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \\
    > /etc/apt/sources.list.d/github-cli.list
apt-get update
apt-get install --no-install-recommends -y gh

# Node.js 20 LTS (for npm) + the claude CLI — the SAME package/method as install.sh.
curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
apt-get install --no-install-recommends -y nodejs
npm install -g @anthropic-ai/claude-code

# Control-plane runtime deps — pins IDENTICAL to deploy/cloud-run/Dockerfile.maintainer.
pip3 install --no-cache-dir --break-system-packages \\
    "cryptography==42.0.8" \\
    "google-cloud-firestore==2.16.1" \\
    "google-cloud-run==0.10.19"

# Clone the heimdall repo (public — the simplest reproducible path, no creds at boot) and put its
# bins on PATH for every login shell. NB: we export the DIRECTORY on PATH (not per-bin symlinks):
# heimdall-maintain-loop resolves its bin/lib RELATIVE to its own dir, so a symlink elsewhere
# would break that resolution. Idempotent: pull if the clone already exists.
if [ -d "$HEIMDALL_DIR/.git" ]; then
  git -C "$HEIMDALL_DIR" pull --ff-only || true
else
  git clone --depth 1 "$HEIMDALL_REPO_URL" "$HEIMDALL_DIR"
fi
chmod -R a+rx "$HEIMDALL_DIR/bin" || true
echo 'export PATH="$HEIMDALL_DIR/bin:\$PATH"' > /etc/profile.d/heimdall.sh
chmod 644 /etc/profile.d/heimdall.sh

# a marker the operator can grep to confirm the toolchain landed.
git --version && gh --version && claude --version && python3 -c 'import google.cloud.firestore' \\
  && touch /var/log/heimdall-toolchain-ready
echo "heimdall maintainer VM toolchain ready"
STARTUP
}

# ── PHASE 1 — provision the VM + print the interactive login relay ───────────
phase_provision() {
  echo
  printf '\033[1m╔═ HEIMDALL MAINTAINER VM — PHASE 1 (provision) ═════════╗\033[0m\n'
  printf '\033[1m║\033[0m project=%-20s zone=%s\n' "$PROJECT" "$ZONE"
  printf '\033[1m║\033[0m vm=%-24s type=%s\n' "$VM" "$MACHINE_TYPE"
  printf '\033[1m║\033[0m The maintainer OPENS PRs via the scoped bot token on\n'
  printf '\033[1m║\033[0m heimdall/* branches — NEVER pushes main, NEVER merges.\n'
  printf '\033[1m║\033[0m A human (RJ) merges. The subscription creds are minted by\n'
  printf '\033[1m║\033[0m an INTERACTIVE claude login done ON the VM (relayed below).\n'
  printf '\033[1m╚════════════════════════════════════════════════════════╝\033[0m\n'

  preflight

  # a. guarded create — describe || create (idempotent). Egress-only: no inbound rule is added
  #    (SSH reaches the VM over IAP, which needs NO public ingress). Startup script attached via
  #    --metadata-from-file so the toolchain installs on first boot.
  say "a. ensure VM '$VM' in $ZONE (describe || create)"
  local startup_file
  if [ "$DRY" = 1 ]; then
    run "gcloud compute instances describe $VM --zone=$ZONE --project=$PROJECT  # (|| create below)"
    run "gcloud compute instances create $VM --zone=$ZONE --project=$PROJECT --machine-type=$MACHINE_TYPE --image-family=debian-12 --image-project=debian-cloud --no-address --metadata-from-file startup-script=<generated>  # egress-only (no --address; SSH via IAP)"
    echo
    say "   startup-script the VM runs on first boot (installs git + gh + node20/claude + python deps):"
    emit_startup_script | sed 's/^/    /'
    echo
  else
    if gcloud compute instances describe "$VM" --zone="$ZONE" --project="$PROJECT" >/dev/null 2>&1; then
      say "  VM '$VM' already exists — leaving it in place"
    else
      startup_file="$(mktemp)"
      emit_startup_script > "$startup_file"
      gcloud compute instances create "$VM" \
        --zone="$ZONE" --project="$PROJECT" \
        --machine-type="$MACHINE_TYPE" \
        --image-family=debian-12 --image-project=debian-cloud \
        --no-address \
        --metadata-from-file "startup-script=$startup_file"
      rm -f "$startup_file"
      say "  VM created. First-boot toolchain install takes a few minutes."
    fi
  fi

  # b. print the interactive login relay (the script CANNOT paste the code — RJ does this).
  echo
  say "b. INTERACTIVE login relay — run these YOURSELF (the script cannot paste the code):"
  cat <<RELAY
    # 1. wait for the toolchain (a few min after create), then SSH in over the IAP tunnel:
    gcloud compute ssh $VM --zone $ZONE --project $PROJECT --tunnel-through-iap
    #    (verify the toolchain landed:  ls -l /var/log/heimdall-toolchain-ready )

    # 2. on the VM, start the interactive login — headless Linux can't open a browser, so
    #    claude PRINTS a URL + CODE instead:
    claude          # (or:  claude auth login )  → prints a URL and a login CODE

    # 3. open that URL in YOUR OWN browser, sign in with your personal Max subscription,
    #    copy the code it shows, and PASTE it back at the prompt on the VM.

    # 4. verify the subscription auth works headless:
    claude -p "ok" --          # should print a normal reply on your subscription (not a 401)
RELAY
  echo
  say "   The creds now PERSIST on the VM at ~/.claude/.credentials.json (a portable OAuth file)."
  say "   Personal Max, no org forceLoginMethod block → subscription OAuth authorizes headless runs."
  echo
  say "NEXT: once 'claude -p \"ok\"' succeeds, run PHASE 2:"
  say "   $(basename "${BASH_SOURCE[0]}") install-maintainer --repo <owner/repo> --project $PROJECT --zone $ZONE --vm $VM"
  [ "$DRY" = 1 ] && warn "dry-run: nothing executed, no creds used. Re-run without --dry-run to apply."
}

# ── phase 2 helper — write the 0600 env file on the VM, token over ssh STDIN ─
# The bot token NEVER appears as an argv/--command element: it is streamed into the ssh session's
# STDIN (a pipe), where a remote `cat > envfile` under `umask 177` writes it 0600. In --dry-run
# NO token is prompted or transmitted — only the shape of the plan is printed.
ssh_write_envfile() {
  local remote_cmd
  # the remote side: create ~/.heimdall (0700), write the env file from stdin under a 0600 umask.
  remote_cmd="umask 177; mkdir -p \"\$HOME/.heimdall\"; chmod 700 \"\$HOME/.heimdall\"; cat > \"\$HOME/$ENVFILE_REL\"; chmod 600 \"\$HOME/$ENVFILE_REL\""
  if [ "$DRY" = 1 ]; then
    say "   write the 0600 env file on the VM (bot token streamed over ssh STDIN — never argv):"
    printf '  \033[90m$ printf %%s <envfile-with-HEIMDALL_PR_BOT_TOKEN> | gcloud compute ssh %s --zone %s --project %s --tunnel-through-iap --command %s\033[0m\n' \
      "$VM" "$ZONE" "$PROJECT" "'$remote_cmd'"
    echo "      env file contents (token line value redacted):"
    printf '        export HEIMDALL_JOB_RUNNER=subprocess\n'
    printf '        export HEIMDALL_MAINTAINER_RUNNER=hybrid\n'
    printf '        export HEIMDALL_PR_BOT_TOKEN=****\n'
    return 0
  fi
  # real path: prompt the token silently, then PIPE the full env-file body into ssh stdin.
  local BOT_TOKEN=""
  printf 'Paste the HEIMDALL_PR_BOT_TOKEN (scoped: contents:write on heimdall/*, pull_requests:write; NO main, NO merge): '
  read -rs BOT_TOKEN; echo
  [ -n "$BOT_TOKEN" ] || die "no bot token entered"
  # printf is a shell BUILTIN — the token never crosses an argv of any child process; it goes
  # only onto the pipe into ssh's stdin. %q-quote so a token with metacharacters survives sourcing.
  printf 'export HEIMDALL_JOB_RUNNER=subprocess\nexport HEIMDALL_MAINTAINER_RUNNER=hybrid\nexport HEIMDALL_PR_BOT_TOKEN=%q\n' "$BOT_TOKEN" \
    | gcloud compute ssh "$VM" --zone "$ZONE" --project "$PROJECT" --tunnel-through-iap \
        --command "$remote_cmd"
  BOT_TOKEN=""   # drop it from this shell immediately.
  say "   wrote ~/$ENVFILE_REL on the VM (mode 600 — contents never printed here)."
}

# ── PHASE 2 — install the maintainer schedule on the VM (post-login) ─────────
phase_install_maintainer() {
  [ -n "$REPO" ] || die "install-maintainer needs --repo <owner/repo>"
  valid_repo "$REPO" || die "--repo must be <owner>/<name> (got: $REPO)"
  [ -n "$CLONE_PATH" ] || CLONE_PATH="\$HOME/heimdall-work/${REPO#*/}"
  local loop="$HEIMDALL_DIR/bin/heimdall-maintain-loop"
  local envfile="\$HOME/$ENVFILE_REL"

  echo
  printf '\033[1m╔═ HEIMDALL MAINTAINER VM — PHASE 2 (install-maintainer) ═╗\033[0m\n'
  printf '\033[1m║\033[0m repo=%-24s max=%s\n' "$REPO" "$MAXN"
  printf '\033[1m║\033[0m vm=%-24s zone=%s\n' "$VM" "$ZONE"
  printf '\033[1m║\033[0m Runs AFTER the interactive claude login succeeds on the VM.\n'
  printf '\033[1m╚════════════════════════════════════════════════════════╝\033[0m\n'

  preflight

  # a. the 0600 env file (bot token over ssh stdin — never argv).
  say "a. write the maintainer env file on the VM (HEIMDALL_JOB_RUNNER=subprocess, HEIMDALL_MAINTAINER_RUNNER=hybrid, bot token)"
  ssh_write_envfile

  # b. clone the target repo on the VM (public clone; a private repo needs gh auth pre-set on the VM).
  say "b. clone the target repo on the VM (the DIR the loop's 'run --max' drains against)"
  local clone_cmd="git clone https://github.com/$REPO.git $CLONE_PATH 2>/dev/null || git -C $CLONE_PATH pull --ff-only || true"
  run gcloud compute ssh "$VM" --zone "$ZONE" --project "$PROJECT" --tunnel-through-iap \
      --command "$clone_cmd"

  # c. install the cron (idempotent, dedup on the heimdall-maintainer- marker): runner-beat every
  #    minute (Arch-A liveness so the hybrid selector picks THIS box) + bounded run --max cycle.
  say "c. install the maintainer cron on the VM (runner-beat 1/min + bounded run --max cycle)"
  local beatline cycleline cron_cmd
  beatline="* * * * * . $envfile; $loop runner-beat --repo $REPO --runner-id \$(hostname) >/dev/null 2>&1 # heimdall-maintainer-beat"
  cycleline="$CRON . $envfile; $loop run --max $MAXN --repo $CLONE_PATH >/dev/null 2>&1 # heimdall-maintainer-cycle"
  # the remote side rewrites crontab, stripping any prior heimdall-maintainer- lines first (dedup),
  # then appends the two fresh lines — so a re-run never stacks duplicates.
  cron_cmd="tmp=\$(mktemp); crontab -l 2>/dev/null | grep -v 'heimdall-maintainer-' > \"\$tmp\" || true; printf '%s\n%s\n' '$beatline' '$cycleline' >> \"\$tmp\"; crontab \"\$tmp\"; rm -f \"\$tmp\""
  run gcloud compute ssh "$VM" --zone "$ZONE" --project "$PROJECT" --tunnel-through-iap \
      --command "$cron_cmd"
  if [ "$DRY" = 1 ]; then
    echo "      cron lines installed on the VM:"
    printf '        %s\n        %s\n' "$beatline" "$cycleline"
  fi

  # d. smoke: one runner-beat (proves the liveness beat reaches the control plane) + a claude -p
  #    liveness check (proves the interactive login's subscription auth still works headless).
  say "d. smoke — one runner-beat + a 'claude -p ok' liveness check on the VM"
  local smoke_cmd=". $envfile; $loop runner-beat --repo $REPO --runner-id \$(hostname); claude -p \"ok\" --"
  run gcloud compute ssh "$VM" --zone "$ZONE" --project "$PROJECT" --tunnel-through-iap \
      --command "$smoke_cmd"

  echo
  say "done — the maintainer runs on the VM: runner-beat 1/min + 'run --max $MAXN' on '$CRON'."
  say "The hybrid selector routes the cycle to THIS VM while its beat is fresh; it OPENS PRs on"
  say "heimdall/* branches only. RJ merges."
  [ "$DRY" = 1 ] && warn "dry-run: nothing executed, no creds/token used. Re-run without --dry-run to apply."
}

case "$CMD" in
  provision)          phase_provision ;;
  install-maintainer) phase_install_maintainer ;;
  *) die "unknown command: $CMD" ;;
esac
exit 0
