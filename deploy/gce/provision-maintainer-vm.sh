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
#                              [--machine-type <t>] [--private] [--dry-run]
#   provision-maintainer-vm.sh install-maintainer --repo <owner/repo> [--project <id>] \
#                              [--zone <z>] [--vm <name>] [--max <N>] [--cron "<expr>"] \
#                              [--clone-path <dir>] [--dry-run]
#   provision-maintainer-vm.sh verify [--project <id>] [--zone <z>] [--vm <name>] [--dry-run]
#
#   EGRESS (provision): default gives the VM an ephemeral EXTERNAL IP (fast, works immediately). An
#             egress-only VM with NO external IP and NO Cloud NAT has NO route to the internet, so
#             first-boot apt/npm/git ALL fail ("Network is unreachable") and nothing installs.
#             --private instead attaches NO external IP and sets up a Cloud Router + NAT for the
#             region (secure: no public IP on the VM). Trade-off: external IP = fast/simple;
#             --private = no public surface but needs the NAT (guarded/idempotent).
#   IAP:      provision idempotently ensures the allow-iap-ssh firewall (ingress tcp:22 from
#             35.235.240.0/20) + enables the compute/iap APIs + grants (or prints) the operator's
#             roles/iap.tunnelResourceAccessor so `ssh --tunnel-through-iap` works (the SSH 4033
#             'not authorized' the operator hit by hand is THIS missing setup).
#   verify:   SSHes in, checks the /var/log/heimdall-toolchain-ready marker + claude/git/gh/heimdall
#             on PATH; if the marker is ABSENT it RE-RUNS the startup script and re-checks (self-heal
#             — a transient/egress-fixed failure recovers WITHOUT recreating the VM).
#   --dry-run prints the FULL plan (egress + IAP + create VM + startup script + login relay + install
#             plan), executes nothing, and needs NO gcloud/ssh/creds.
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
PRIVATE=0

# The heimdall repo the VM clones to get bin/heimdall-maintain-loop + bin/lib on PATH. Public
# clone = the simplest reproducible path (no creds needed at startup); documented in the header.
HEIMDALL_REPO_URL="https://github.com/randomittin/heimdall.git"
HEIMDALL_DIR="/opt/heimdall"                    # where the toolchain clone lands on the VM
ENVFILE_REL=".heimdall/maintainer.env"          # 0600 env file, relative to the ssh user's HOME

# egress + IAP topology. REGION derives from ZONE (us-central1-a → us-central1) after arg parse.
# The VM sits on the 'default' network; --private routes egress through a Cloud Router + NAT (no
# external IP), else the VM gets an ephemeral external IP. IAP SSH needs a firewall opening tcp:22
# to Google's IAP forwarding range.
NETWORK="default"
ROUTER="heimdall-maintainer-router"             # Cloud Router (regional) for the --private NAT path
NAT="heimdall-maintainer-nat"                    # Cloud NAT config attached to the router
IAP_FW="allow-iap-ssh"                           # firewall rule name for IAP TCP-forwarding SSH
IAP_RANGE="35.235.240.0/20"                      # Google's fixed IAP source range

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() { sed -n '/^# Usage:/,/executes nothing/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

# ── arg parse (the subcommand may appear in ANY position) ────────────────────
while [ $# -gt 0 ]; do case "$1" in
  provision|install-maintainer|verify) CMD="$1"; shift ;;
  --project)      PROJECT="${2:?}";      shift 2 ;;
  --zone)         ZONE="${2:?}";         shift 2 ;;
  --vm)           VM="${2:?}";           shift 2 ;;
  --machine-type) MACHINE_TYPE="${2:?}"; shift 2 ;;
  --repo)         REPO="${2:?}";         shift 2 ;;
  --max)          MAXN="${2:?}";         shift 2 ;;
  --cron)         CRON="${2:?}";         shift 2 ;;
  --clone-path)   CLONE_PATH="${2:?}";   shift 2 ;;
  --private)      PRIVATE=1;             shift ;;
  --dry-run)      DRY=1;                 shift ;;
  -h|--help)      usage; exit 0 ;;
  *) echo "unknown arg: $1" >&2; usage >&2; exit 2 ;;
esac; done
[ -n "$CMD" ] || CMD="provision"
REGION="${ZONE%-*}"   # us-central1-a → us-central1 (Cloud Router + NAT are regional)

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

# resolve the active gcloud account WITHOUT spending creds in --dry-run: honor an env override
# (HEIMDALL_ACTIVE_ACCOUNT — used by tests + operators), else query gcloud ONLY in real mode.
active_account() {
  if [ -n "${HEIMDALL_ACTIVE_ACCOUNT:-}" ]; then printf '%s' "$HEIMDALL_ACTIVE_ACCOUNT"; return 0; fi
  [ "$DRY" = 1 ] && return 0
  gcloud config get-value account 2>/dev/null | grep -v '^(unset)$' || true
}

# preflight the active account: a service account (…gserviceaccount.com, e.g. a CI SA) CANNOT
# enable APIs / edit IAM / create firewalls on most projects — this exact thing bit the operator.
# WARN loudly so they gcloud auth login as a human owner BEFORE the guarded steps PERMISSION_DENY.
preflight_account() {
  local acct; acct="$(active_account)"
  [ -n "$acct" ] || return 0
  case "$acct" in
    *.gserviceaccount.com)
      warn "active account '$acct' is a SERVICE ACCOUNT — the API-enable / IAM / firewall steps"
      warn "  below will likely PERMISSION_DENIED. Run 'gcloud auth login' as a HUMAN OWNER first,"
      warn "  then re-run. (A CI service account cannot self-grant project IAM.)" ;;
  esac
}

# enable the APIs provision needs (compute + IAP). Guarded: a PERMISSION_DENIED (e.g. a CI SA) is a
# WARN, not fatal — they may already be enabled, and the operator is told how to fix it.
ensure_apis() {
  say "a1. ensure required APIs enabled (compute, iap)"
  if [ "$DRY" = 1 ]; then
    run "gcloud services enable compute.googleapis.com iap.googleapis.com --project=$PROJECT"
    return 0
  fi
  gcloud services enable compute.googleapis.com iap.googleapis.com --project="$PROJECT" \
    || warn "could not enable compute/iap APIs — the active account may lack serviceusage.services.enable. If it is a CI service account, 'gcloud auth login' as a human owner. (Continuing — they may already be on.)"
}

# ensure the IAP SSH firewall: ingress tcp:22 from Google's IAP range on the VM's network. WITHOUT
# it, 'ssh --tunnel-through-iap' cannot reach the VM. Idempotent (describe || create).
ensure_iap_firewall() {
  say "a2. ensure IAP SSH firewall '$IAP_FW' (ingress tcp:22 from $IAP_RANGE on '$NETWORK')"
  if [ "$DRY" = 1 ]; then
    run "gcloud compute firewall-rules describe $IAP_FW --project=$PROJECT  # (|| create below)"
    run "gcloud compute firewall-rules create $IAP_FW --project=$PROJECT --network=$NETWORK --direction=INGRESS --action=ALLOW --rules=tcp:22 --source-ranges=$IAP_RANGE  # IAP TCP-forwarding SSH"
    return 0
  fi
  if gcloud compute firewall-rules describe "$IAP_FW" --project="$PROJECT" >/dev/null 2>&1; then
    say "  firewall '$IAP_FW' already present"
  else
    gcloud compute firewall-rules create "$IAP_FW" --project="$PROJECT" \
      --network="$NETWORK" --direction=INGRESS --action=ALLOW \
      --rules=tcp:22 --source-ranges="$IAP_RANGE" \
      || warn "could not create firewall '$IAP_FW' — active account may lack compute.firewalls.create. If a CI SA, 'gcloud auth login' as a human owner."
  fi
}

# ensure the operator can USE the IAP tunnel (roles/iap.tunnelResourceAccessor). The SSH 4033 'not
# authorized' the operator hit was THIS missing grant. The script attempts it, but the grant needs
# project-IAM-admin — on failure it prints the exact command for the user to run themselves.
ensure_iap_iam() {
  local acct member; acct="$(active_account)"
  say "a3. ensure IAP tunnel access (roles/iap.tunnelResourceAccessor) for the operator"
  if [ "$DRY" = 1 ]; then
    run "gcloud projects add-iam-policy-binding $PROJECT --member=user:<your-account> --role=roles/iap.tunnelResourceAccessor  # needs project-IAM-admin"
    warn "  if 'ssh --tunnel-through-iap' fails with 4033 'not authorized', run that grant as an owner."
    return 0
  fi
  [ -n "$acct" ] || { warn "  could not resolve the active account — skipping the IAP IAM grant."; return 0; }
  member="user:$acct"; case "$acct" in *.gserviceaccount.com) member="serviceAccount:$acct";; esac
  if gcloud projects add-iam-policy-binding "$PROJECT" --member="$member" --role=roles/iap.tunnelResourceAccessor >/dev/null 2>&1; then
    say "  granted roles/iap.tunnelResourceAccessor to $acct"
  else
    warn "  could not grant roles/iap.tunnelResourceAccessor to $member (needs project-IAM-admin)."
    warn "  If 'ssh --tunnel-through-iap' fails with 4033 'not authorized', run YOURSELF as an owner:"
    warn "    gcloud projects add-iam-policy-binding $PROJECT --member=$member --role=roles/iap.tunnelResourceAccessor"
  fi
}

# ensure Cloud NAT so a --private (no-external-IP) VM still has internet egress at first boot: a
# Cloud Router + NAT for the region/network. Idempotent (describe || create). ONLY for --private.
ensure_cloud_nat() {
  say "a4. ensure Cloud NAT egress (router '$ROUTER' + NAT '$NAT' in $REGION on '$NETWORK')"
  if [ "$DRY" = 1 ]; then
    run "gcloud compute routers describe $ROUTER --region=$REGION --project=$PROJECT  # (|| create below)"
    run "gcloud compute routers create $ROUTER --network=$NETWORK --region=$REGION --project=$PROJECT"
    run "gcloud compute routers nats describe $NAT --router=$ROUTER --region=$REGION --project=$PROJECT  # (|| create below)"
    run "gcloud compute routers nats create $NAT --router=$ROUTER --region=$REGION --project=$PROJECT --auto-allocate-nat-external-ips --nat-all-subnet-ip-ranges  # Cloud NAT egress for the no-external-IP VM"
    return 0
  fi
  if gcloud compute routers describe "$ROUTER" --region="$REGION" --project="$PROJECT" >/dev/null 2>&1; then
    say "  router '$ROUTER' already present"
  else
    gcloud compute routers create "$ROUTER" --network="$NETWORK" --region="$REGION" --project="$PROJECT" \
      || warn "  could not create router '$ROUTER' (permission?)"
  fi
  if gcloud compute routers nats describe "$NAT" --router="$ROUTER" --region="$REGION" --project="$PROJECT" >/dev/null 2>&1; then
    say "  NAT '$NAT' already present"
  else
    gcloud compute routers nats create "$NAT" --router="$ROUTER" --region="$REGION" --project="$PROJECT" \
      --auto-allocate-nat-external-ips --nat-all-subnet-ip-ranges \
      || warn "  could not create NAT '$NAT' (permission?)"
  fi
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
# Idempotent + RE-RUNNABLE: 'provision-maintainer-vm.sh verify' re-invokes this via
# 'google_metadata_script_runner startup' to self-heal a partial/egress-failed first boot WITHOUT
# recreating the VM. ALL output tees to /var/log/heimdall-toolchain.log; the ready marker
# (/var/log/heimdall-toolchain-ready) is written ONLY after every step succeeds.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

# tee ALL output (stdout+stderr) to a durable log so a failed boot is diagnosable after the fact.
exec > >(tee -a /var/log/heimdall-toolchain.log) 2>&1
echo "=== heimdall toolchain install \$(date -u +%FT%TZ) (pid \$\$) ==="

# a partial prior run may have left a stale marker — drop it so it reflects THIS run's success only.
rm -f /var/log/heimdall-toolchain-ready

# retry a network-facing command. apt/curl/npm/pip/git fail transiently, and fail HARD if the VM
# had no egress at first boot — the exact break this fixes. 5 tries, 10s backoff.
retry() {
  local n=0
  until "\$@"; do
    n=\$((n+1))
    [ "\$n" -ge 5 ] && { echo "GAVE UP after \$n tries: \$*" >&2; return 1; }
    echo "retry \$n/5: \$* (sleep 10)" >&2
    sleep 10
  done
}

# system toolchain: git (branches/stages fixes), python3 (durable state backend), cron (the
# maintainer schedule + runner-beat), curl/gnupg/ca-certificates (fetch the gh + node keyrings).
retry apt-get update
apt-get install --no-install-recommends -y \\
    bash git ca-certificates curl gnupg python3 python3-pip cron

# GitHub CLI (gh) — the maintainer OPENS PRs with it — from GitHub's OFFICIAL apt repo.
mkdir -p -m 755 /etc/apt/keyrings
retry curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \\
    -o /etc/apt/keyrings/githubcli-archive-keyring.gpg
chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg
echo "deb [arch=\$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \\
    > /etc/apt/sources.list.d/github-cli.list
retry apt-get update
apt-get install --no-install-recommends -y gh

# Node.js 20 LTS (for npm) + the claude CLI — the SAME package/method as install.sh.
retry bash -c 'curl -fsSL https://deb.nodesource.com/setup_20.x | bash -'
apt-get install --no-install-recommends -y nodejs
retry npm install -g @anthropic-ai/claude-code

# Control-plane runtime deps — pins IDENTICAL to deploy/cloud-run/Dockerfile.maintainer.
retry pip3 install --no-cache-dir --break-system-packages \\
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
  retry git clone --depth 1 "$HEIMDALL_REPO_URL" "$HEIMDALL_DIR"
fi
chmod -R a+rx "$HEIMDALL_DIR/bin" || true
echo 'export PATH="$HEIMDALL_DIR/bin:\$PATH"' > /etc/profile.d/heimdall.sh
chmod 644 /etc/profile.d/heimdall.sh

# write the ready marker ONLY after EVERY tool verifies — 'verify' greps this to decide self-heal.
git --version && gh --version && claude --version && python3 -c 'import google.cloud.firestore' \\
  && touch /var/log/heimdall-toolchain-ready \\
  && echo "heimdall maintainer VM toolchain ready" \\
  || { echo "TOOLCHAIN INCOMPLETE — marker NOT written; 'verify' will re-run this script" >&2; exit 1; }
STARTUP
}

# ── the remote self-heal verify script (checks the toolchain; re-runs startup if the marker is gone) ──
# Runs ON the VM over ssh. If the ready marker or any tool is missing, it RE-RUNS the first-boot
# startup via google_metadata_script_runner and re-checks — a transient/egress-fixed failure heals
# WITHOUT recreating the VM. Single-quoted heredoc: this body is verbatim (no host-side expansion).
emit_verify_script() {
  cat <<'VERIFY'
set -uo pipefail
[ -f /etc/profile.d/heimdall.sh ] && . /etc/profile.d/heimdall.sh
tools_ok() {
  [ -f /var/log/heimdall-toolchain-ready ] || return 1
  command -v claude                 >/dev/null 2>&1 || return 1
  command -v git                    >/dev/null 2>&1 || return 1
  command -v gh                     >/dev/null 2>&1 || return 1
  command -v heimdall-maintain-loop >/dev/null 2>&1 || return 1
  claude --version                  >/dev/null 2>&1 || return 1
}
if tools_ok; then
  echo "VERIFY-OK: /var/log/heimdall-toolchain-ready present; claude/git/gh/heimdall on PATH"
  claude --version
else
  echo "VERIFY: toolchain-ready marker or a tool is MISSING — RE-RUNNING the startup script (self-heal)"
  sudo google_metadata_script_runner startup || true
  [ -f /etc/profile.d/heimdall.sh ] && . /etc/profile.d/heimdall.sh
  if tools_ok; then
    echo "VERIFY-OK: toolchain healed after re-running startup"
    claude --version
  else
    echo "VERIFY-FAIL: toolchain still not ready after the startup re-run — see /var/log/heimdall-toolchain.log" >&2
    exit 1
  fi
fi
VERIFY
}

# ── PHASE 1 — provision the VM + print the interactive login relay ───────────
phase_provision() {
  local egress_desc
  if [ "$PRIVATE" = 1 ]; then egress_desc="Cloud NAT (--private: NO external IP, egress via router/NAT)"
  else egress_desc="ephemeral EXTERNAL IP (default: fast, works immediately)"; fi

  echo
  printf '\033[1m╔═ HEIMDALL MAINTAINER VM — PHASE 1 (provision) ═════════╗\033[0m\n'
  printf '\033[1m║\033[0m project=%-20s zone=%s\n' "$PROJECT" "$ZONE"
  printf '\033[1m║\033[0m vm=%-24s type=%s\n' "$VM" "$MACHINE_TYPE"
  printf '\033[1m║\033[0m egress=%s\n' "$egress_desc"
  printf '\033[1m║\033[0m (an egress-only VM with NO external IP and NO Cloud NAT has\n'
  printf '\033[1m║\033[0m  NO internet route — apt/npm/git ALL fail at first boot.)\n'
  printf '\033[1m║\033[0m The maintainer OPENS PRs via the scoped bot token on\n'
  printf '\033[1m║\033[0m heimdall/* branches — NEVER pushes main, NEVER merges.\n'
  printf '\033[1m║\033[0m A human (RJ) merges. The subscription creds are minted by\n'
  printf '\033[1m║\033[0m an INTERACTIVE claude login done ON the VM (relayed below).\n'
  printf '\033[1m╚════════════════════════════════════════════════════════╝\033[0m\n'

  preflight
  preflight_account            # WARN loudly if the active account is a service account.

  # a0. enable APIs + IAP firewall + IAP IAM (idempotent/guarded). The operator hit SSH 4033 'not
  #     authorized' doing this by hand — provision now sets it up. --private also needs Cloud NAT.
  ensure_apis
  ensure_iap_firewall
  ensure_iap_iam
  [ "$PRIVATE" = 1 ] && ensure_cloud_nat   # no-external-IP VMs need Cloud NAT for egress.

  # a. guarded create — describe || create (idempotent). Default gives the VM an ephemeral EXTERNAL
  #    IP so first-boot apt/npm/git have internet egress; --private omits it and routes egress via
  #    Cloud NAT (set up above). SSH always reaches the VM over IAP (no public *ingress* either way).
  say "a. ensure VM '$VM' in $ZONE (describe || create) — egress via $egress_desc"
  local startup_file
  if [ "$DRY" = 1 ]; then
    run "gcloud compute instances describe $VM --zone=$ZONE --project=$PROJECT  # (|| create below)"
    if [ "$PRIVATE" = 1 ]; then
      run "gcloud compute instances create $VM --zone=$ZONE --project=$PROJECT --machine-type=$MACHINE_TYPE --image-family=debian-12 --image-project=debian-cloud --network=$NETWORK --no-address --metadata-from-file startup-script=<generated>  # NO external IP — egress via Cloud NAT '$NAT'; SSH via IAP"
    else
      run "gcloud compute instances create $VM --zone=$ZONE --project=$PROJECT --machine-type=$MACHINE_TYPE --image-family=debian-12 --image-project=debian-cloud --network=$NETWORK --metadata-from-file startup-script=<generated>  # ephemeral EXTERNAL IP (internet egress); SSH via IAP"
    fi
    echo
    say "   startup-script the VM runs on first boot (installs git + gh + node20/claude + python deps):"
    emit_startup_script | sed 's/^/    /'
    echo
  else
    if gcloud compute instances describe "$VM" --zone="$ZONE" --project="$PROJECT" >/dev/null 2>&1; then
      say "  VM '$VM' already exists — leaving it in place (re-run 'verify' to heal the toolchain)"
    else
      startup_file="$(mktemp)"
      emit_startup_script > "$startup_file"
      local -a create_args
      create_args=( gcloud compute instances create "$VM"
        --zone="$ZONE" --project="$PROJECT"
        --machine-type="$MACHINE_TYPE"
        --image-family=debian-12 --image-project=debian-cloud
        --network="$NETWORK" )
      [ "$PRIVATE" = 1 ] && create_args+=( --no-address )   # egress via Cloud NAT instead
      create_args+=( --metadata-from-file "startup-script=$startup_file" )
      "${create_args[@]}"
      rm -f "$startup_file"
      say "  VM created ($egress_desc). First-boot toolchain install takes a few minutes."
      say "  Confirm with: $(basename "${BASH_SOURCE[0]}") verify --vm $VM --zone $ZONE --project $PROJECT"
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

# ── VERIFY — SSH in, check the toolchain, self-heal a missing marker by re-running startup ────
phase_verify() {
  echo
  printf '\033[1m╔═ HEIMDALL MAINTAINER VM — VERIFY (self-healing toolchain) ═╗\033[0m\n'
  printf '\033[1m║\033[0m vm=%-24s zone=%s\n' "$VM" "$ZONE"
  printf '\033[1m║\033[0m Checks /var/log/heimdall-toolchain-ready + claude/git/gh/heimdall\n'
  printf '\033[1m║\033[0m on PATH. If the marker is ABSENT, RE-RUNS the startup script and\n'
  printf '\033[1m║\033[0m re-checks — a transient/egress-fixed failure heals, NO recreate.\n'
  printf '\033[1m╚═══════════════════════════════════════════════════════════╝\033[0m\n'

  preflight
  local vscript; vscript="$(emit_verify_script)"
  say "SSH in over IAP and verify the toolchain; self-heal if the ready marker is missing."
  if [ "$DRY" = 1 ]; then
    run "gcloud compute ssh $VM --zone $ZONE --project $PROJECT --tunnel-through-iap --command <verify-script>"
    echo
    say "   remote verify script (checks the marker; re-runs 'google_metadata_script_runner startup' if absent):"
    printf '%s\n' "$vscript" | sed 's/^/    /'
    echo
    warn "dry-run: nothing executed, no creds used. Re-run without --dry-run to verify the live VM."
    return 0
  fi
  gcloud compute ssh "$VM" --zone "$ZONE" --project "$PROJECT" --tunnel-through-iap --command "$vscript"
  say "verify complete — see the VERIFY-OK / VERIFY-FAIL line above."
}

case "$CMD" in
  provision)          phase_provision ;;
  install-maintainer) phase_install_maintainer ;;
  verify)             phase_verify ;;
  *) die "unknown command: $CMD" ;;
esac
exit 0
