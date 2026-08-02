#!/usr/bin/env bash
# deploy-maintainer.sh — one-shot deploy of the Heimdall maintainer (Arch A local runner,
# Arch B Cloud Run Job, or hybrid). RUN BY THE OPERATOR on their own machine: it uses YOUR
# gcloud creds + an interactive `claude setup-token`. The agent never runs this.
#
# Secret discipline (the #1 correctness bar): tokens are read with `read -rs` (never echoed,
# never in argv, never logged); cloud secrets are piped to gcloud via STDIN (--data-file=-),
# never a temp file. No `set -x`. Never `echo`/`printf` a token variable.
#
# Usage:
#   deploy-maintainer.sh --repo <owner/repo> [--local|--cloud|--hybrid] [--dry-run] \
#                        [--project <id>] [--region <r>] [--max <N>] [--cron "<expr>"] \
#                        [--schedule "<cron>"]
#   RECOMMENDED bot identity — a GitHub App (no user seat, auto-scoped, revocable, PRs
#   from the App; per-cycle 1-hour installation tokens minted by bin/heimdall-gh-app-token):
#     [--gh-app --gh-app-id <N> --gh-app-installation-id <N> --gh-app-key-file <path.pem>]
#     Provisions HEIMDALL_GH_APP_* (Arch A: a 0600 key file + env; Arch B: Secret Manager +
#     Job env). The static HEIMDALL_PR_BOT_TOKEN (a fine-grained PAT) stays the FALLBACK
#     when --gh-app is omitted. See deploy/github-app/setup-bot.sh to create the App.
#   --hybrid (default) sets up Arch A (this box) AND Arch B (cloud fallback).
#   --local  Arch A only (no gcloud).   --cloud  Arch B only.
#   --schedule "<cron>" REGISTERS the maintainer cron with the control plane so the
#            per-minute tick fires run-maintainer-cycle autonomously (heimdall-control-plane
#            schedule-maintainer — idempotent). Without it, schedule registration stays
#            manual (see MAINTAINER-RUNBOOK.md §6). For --cloud, the tick reaches the Job
#            when HEIMDALL_MAINTAINER_RUNNER=cloud|hybrid (an absent local runner -> the Job).
#   --dry-run prints the full plan, executes nothing, needs NO creds/tokens.
set -euo pipefail

MODE="hybrid"; DRY=0; REPO=""; PROJECT="heimdall-cp-prod"; REGION="us-central1"
MAXN="3"; CRON="*/30 * * * *"; SCHEDULE=""
GH_APP=0; GH_APP_ID=""; GH_APP_INSTALL_ID=""; GH_APP_KEY_FILE=""
JOB="heimdall-maintainer-job"
GH_APP_KEY_SECRET="heimdall-gh-app-private-key"
RUNTIME_SA="heimdall-cp-runtime@${PROJECT}.iam.gserviceaccount.com"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
LOOP="$ROOT/bin/heimdall-maintain-loop"
CP_CLI="$ROOT/bin/heimdall-control-plane"
YAML="${HEIMDALL_MAINTAINER_JOB_YAML:-$HERE/heimdall-maintainer-job.yaml}"
ENVFILE="$HOME/.heimdall/maintainer.env"
GH_APP_KEY_STORE="$HOME/.heimdall/gh-app-private-key.pem"

usage() { sed -n '2,28p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }
while [ $# -gt 0 ]; do case "$1" in
  --local|--cloud|--hybrid) MODE="${1#--}"; shift ;;
  --dry-run) DRY=1; shift ;;
  --repo) REPO="${2:?}"; shift 2 ;;
  --project) PROJECT="${2:?}"; shift 2 ;;
  --region) REGION="${2:?}"; shift 2 ;;
  --max) MAXN="${2:?}"; shift 2 ;;
  --cron) CRON="${2:?}"; shift 2 ;;
  --schedule) SCHEDULE="${2:?}"; shift 2 ;;
  --gh-app) GH_APP=1; shift ;;
  --gh-app-id) GH_APP_ID="${2:?}"; shift 2 ;;
  --gh-app-installation-id) GH_APP_INSTALL_ID="${2:?}"; shift 2 ;;
  --gh-app-key-file) GH_APP_KEY_FILE="${2:?}"; shift 2 ;;
  -h|--help) usage; exit 0 ;;
  *) echo "unknown arg: $1" >&2; usage >&2; exit 2 ;;
esac; done

say()  { printf '\033[36m▸ %s\033[0m\n' "$*"; }
warn() { printf '\033[33m! %s\033[0m\n' "$*" >&2; }
die()  { printf '\033[31m✗ %s\033[0m\n' "$*" >&2; exit 1; }
# run: in --dry-run print the command (no secrets are ever in argv), else execute.
run()  { if [ "$DRY" = 1 ]; then printf '  \033[90m$ %s\033[0m\n' "$*"; else "$@"; fi; }
# show: print a PLAN/ANNOTATION line in --dry-run only; a no-op otherwise. Human-readable
# annotations like "(|| exists)" belong HERE, never inside an argv handed to `run` — feeding
# an annotated string to `run` in LIVE mode executed the whole string as ONE command name
# (`gcloud secrets create ... (|| exists): command not found`, the mksecret break). The real
# gcloud runs as a separate, clean-argv statement in the non-dry branch below.
show() { [ "$DRY" = 1 ] && printf '  \033[90m$ %s\033[0m\n' "$*"; return 0; }

# the ONE safe-crontab helper, shared with deploy/gce/provision-maintainer-vm.sh so the
# non-destructive read can never be fixed in one call site and left rotten in the other.
[ -r "$ROOT/bin/lib/crontab-safe.sh" ] || die "missing $ROOT/bin/lib/crontab-safe.sh (needed to install the maintainer cron safely)"
# shellcheck source=../../bin/lib/crontab-safe.sh
. "$ROOT/bin/lib/crontab-safe.sh"

# the ONE real-user predicate, shared with bin/heimdall-dream-schedule + bin/heimdall so the
# launchd and crontab directions of the SAME guard cannot drift apart. A second copy of this
# logic would drift, and a drifted guard is an unguarded one — hence one lib, two call sites.
[ -r "$ROOT/bin/lib/real-home.sh" ] || die "missing $ROOT/bin/lib/real-home.sh (needed to prove this is the real user's machine before touching its crontab)"
# shellcheck source=../../bin/lib/real-home.sh
. "$ROOT/bin/lib/real-home.sh"

[ -n "$REPO" ] || die "missing --repo <owner/repo>"
printf '%s' "$REPO" | grep -qE '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$' \
  || die "--repo must be <owner>/<name> (got: $REPO)"

echo
printf '\033[1m╔═ HEIMDALL MAINTAINER DEPLOY ═══════════════════════════╗\033[0m\n'
printf '\033[1m║\033[0m mode=%-8s repo=%-24s dry=%s\n' "$MODE" "$REPO" "$DRY"
printf '\033[1m║\033[0m The maintainer OPENS PRs via the scoped bot token\n'
printf '\033[1m║\033[0m (heimdall/* branches — NEVER pushes main, NEVER merges).\n'
printf '\033[1m║\033[0m A human merges. Your creds never leave this machine (Arch A)\n'
printf '\033[1m║\033[0m or your Secret Manager (Arch B).\n'
printf '\033[1m╚════════════════════════════════════════════════════════╝\033[0m\n'

# ── preflight ────────────────────────────────────────────────────────────────
need() { command -v "$1" >/dev/null 2>&1 || die "missing '$1' — $2"; }
say "preflight ($MODE)"
[ -x "$LOOP" ] || die "bin/heimdall-maintain-loop not found/executable at $LOOP"
if [ "$DRY" != 1 ]; then
  need claude "install Claude Code (https://claude.com/claude-code)"
  need gh "install GitHub CLI (https://cli.github.com)"
  if [ "$MODE" != "local" ]; then
    need gcloud "install the Google Cloud SDK"
    # NO docker here: this script never builds locally. Arch B's image is built + pushed +
    # digest-pinned UPSTREAM by deploy-arch-b.sh (via docker/Cloud Build on the operator box),
    # and --cloud mode only does `gcloud run jobs replace` + IAM + secret mint against that
    # already-pinned image (the manifest-digest gate below refuses an un-pinned sentinel).
    # Requiring docker here falsely blocked the arch-b -> deploy-maintainer.sh --cloud handoff.
    gcloud auth print-access-token >/dev/null 2>&1 || die "run: gcloud auth login"
  fi
fi

# ── secrets (interactive, never echoed) ──────────────────────────────────────
OAUTH_TOKEN=""; BOT_TOKEN=""
collect_secrets() {
  [ "$DRY" = 1 ] && { warn "dry-run: skipping token prompts"; return 0; }
  if [ "$PROMPT_TOKENS" != 1 ]; then
    # multi-tenant + cloud-only: the shared base Job mounts NO per-team creds (injected at
    # dispatch), so no token is requested and `claude setup-token` is NEVER invoked here.
    say "multi-tenant: per-team creds injected at dispatch — legacy secret mint skipped"
    return 0
  fi
  say "mint a ~1-year subscription token (a browser will open — only you can consent)"
  claude setup-token || die "claude setup-token failed"
  printf 'Paste the CLAUDE_CODE_OAUTH_TOKEN (sk-ant-oat-...): '; read -rs OAUTH_TOKEN; echo
  [ -n "$OAUTH_TOKEN" ] || die "no OAuth token entered"
  if [ "$GH_APP" = 1 ]; then
    # RECOMMENDED: a GitHub App bot identity. The App id + installation id come from
    # args; the private key from a file (never prompted — a PEM is multi-line). The
    # static PAT becomes an OPTIONAL fallback (press Enter to skip).
    [ -n "$GH_APP_ID" ] && [ -n "$GH_APP_INSTALL_ID" ] \
      || die "--gh-app needs --gh-app-id <N> and --gh-app-installation-id <N>"
    [ -f "$GH_APP_KEY_FILE" ] \
      || die "--gh-app needs --gh-app-key-file <path.pem> (an existing App private key)"
    say "GitHub App PR-bot: id=$GH_APP_ID install=$GH_APP_INSTALL_ID (per-cycle 1h tokens; no user seat)"
    printf 'Optional static HEIMDALL_PR_BOT_TOKEN fallback (press Enter to skip): '
    read -rs BOT_TOKEN; echo
  else
    printf 'Paste the HEIMDALL_PR_BOT_TOKEN (scoped: contents:write on heimdall/*, issues:write, pull_requests:write; NO main, NO merge): '
    read -rs BOT_TOKEN; echo
    [ -n "$BOT_TOKEN" ] || die "no bot token entered"
  fi
}

# ── The Arch-A sandbox guard (fail-safe, self-detecting) ─────────────────────
#
# WHY THE LOCAL RUNNER NEEDS THIS. `crontab` keys off the OS USER (getuid), NOT $HOME.
# That is the IDENTICAL failure shape as the launchd incident that silently repointed the
# developer's live nightly job at an ephemeral agent worktree: a harness that sets
# HOME=$(mktemp -d) isolates the FILESYSTEM but not the crontab spool, so `crontab <file>`
# still rewrites the REAL user's crontab and `crontab -l` still reads it. Arch A is by
# definition "a runner on THIS box", so every side effect in arch_a is machine-scoped.
#
# IT DOES NOT TRUST THE CALLER. heimdall_home_is_real compares $HOME against the PASSWD
# DATABASE, a source $HOME cannot influence, so a synthetic HOME self-identifies with ZERO
# cooperation from whoever spawned the run. An env-var opt-out only works if every future
# caller remembers it — one forgot, and that is exactly how the incident happened. This is
# the floor underneath that, for the caller who forgets.
#
# REFUSAL IS TOTAL AND EARLY: it returns before the env file, before the smoke cycle, and
# before ANY crontab call — not even `crontab -l`, whose failure is how the destructive
# read bug manifested. Exit 4 is distinct from a real failure (die → 1) and prints the
# state word `sandboxed`, mirroring heimdall-dream-schedule's exit 4 and the word install.sh
# renders for it, so an operator (or a CI check) can tell REFUSAL from BREAKAGE.
#
# Fail safe at every unknown: if the predicate is somehow undefined, "don't know" answers NO.
require_real_crontab_owner() {
  # --dry-run executes nothing, so there is nothing to refuse.
  if [ "$DRY" = 1 ]; then return 0; fi
  if type heimdall_home_is_real >/dev/null 2>&1 && heimdall_home_is_real; then return 0; fi
  printf '\033[33m! sandboxed — refusing to install the maintainer cron.\033[0m\n' >&2
  printf '  $HOME (%s) is not this user'"'"'s passwd home (%s), so `crontab` would rewrite\n' \
    "${HOME:-<unset>}" "$(heimdall_real_user_home)" >&2
  printf '  the REAL user'"'"'s crontab — it keys off the OS user, which $HOME does not isolate.\n' >&2
  printf '  Nothing was written: no crontab read, no crontab install, no env file.\n' >&2
  printf '  Re-run as the real user, or use --dry-run to see the plan.\n' >&2
  exit 4
}

# ── Arch A: local runner on this box ─────────────────────────────────────────
arch_a() {
  say "Arch A — local runner on this machine"
  # BEFORE any machine-scoped side effect. Placed inside arch_a (not at the dispatch) so a
  # future caller of arch_a cannot route around it.
  require_real_crontab_owner
  if [ "$DRY" != 1 ]; then
    mkdir -p "$(dirname "$ENVFILE")"
    if [ "$GH_APP" = 1 ]; then
      # copy the App private key to a 0600 store the env file points at (never inline a
      # multi-line PEM into the env file). HEIMDALL_GH_APP_PRIVATE_KEY_FILE feeds the minter.
      ( umask 177; cp "$GH_APP_KEY_FILE" "$GH_APP_KEY_STORE" ); chmod 600 "$GH_APP_KEY_STORE"
    fi
    ( umask 177; {
        printf 'export HEIMDALL_JOB_RUNNER=subprocess\n'
        printf 'export HEIMDALL_MAINTAINER_RUNNER=hybrid\n'
        # DRIVE REAL FIXES: the loop's fix slot invokes `claude -p` to write edits only
        # when this is set (bug #20 — without it the cycle runs but produces an EMPTY diff).
        printf 'export HEIMDALL_FIX_WITH_CLAUDE=1\n'
        printf 'export CLAUDE_CODE_OAUTH_TOKEN=%q\n' "$OAUTH_TOKEN"
        if [ "$GH_APP" = 1 ]; then
          printf 'export HEIMDALL_GH_APP_ID=%q\n' "$GH_APP_ID"
          printf 'export HEIMDALL_GH_APP_INSTALLATION_ID=%q\n' "$GH_APP_INSTALL_ID"
          printf 'export HEIMDALL_GH_APP_PRIVATE_KEY_FILE=%q\n' "$GH_APP_KEY_STORE"
        fi
        # the static PAT is written only when present (App creds are the primary path).
        [ -n "$BOT_TOKEN" ] && printf 'export HEIMDALL_PR_BOT_TOKEN=%q\n' "$BOT_TOKEN"
      } > "$ENVFILE" )
    chmod 600 "$ENVFILE"
    say "wrote $ENVFILE (mode 600 — contents never printed)"
    # smoke: prove liveness + run one cycle
    # shellcheck disable=SC1090
    . "$ENVFILE"
    run "$LOOP" runner-beat --repo "$REPO"
    run "$LOOP" run --max 1 --repo "$ROOT"
  else
    if [ "$GH_APP" = 1 ]; then
      run "umask 177; cp <App key.pem> $GH_APP_KEY_STORE chmod 600"
      run "umask 177; write $ENVFILE (HEIMDALL_JOB_RUNNER, HEIMDALL_MAINTAINER_RUNNER, CLAUDE_CODE_OAUTH_TOKEN, HEIMDALL_GH_APP_ID, HEIMDALL_GH_APP_INSTALLATION_ID, HEIMDALL_GH_APP_PRIVATE_KEY_FILE, [static HEIMDALL_PR_BOT_TOKEN fallback]) chmod 600"
    else
      run "umask 177; write $ENVFILE (HEIMDALL_JOB_RUNNER, HEIMDALL_MAINTAINER_RUNNER, tokens) chmod 600"
    fi
    run "$LOOP runner-beat --repo $REPO"
    run "$LOOP run --max 1 --repo $ROOT"
  fi
  # idempotent cron: runner-beat every minute (Arch A liveness) + cycle on schedule
  local beatline cycleline
  beatline="* * * * * . $ENVFILE; $LOOP runner-beat --repo $REPO >/dev/null 2>&1 # heimdall-maintainer-beat"
  cycleline="$CRON . $ENVFILE; $LOOP run --max $MAXN --repo $ROOT >/dev/null 2>&1 # heimdall-maintainer-cycle"
  if [ "$DRY" = 1 ]; then
    run "crontab: add (dedup on marker) —"; printf '    %s\n    %s\n' "$beatline" "$cycleline"
  else
    # safe replace: aborts (changing NOTHING) if `crontab -l` fails for any reason other than
    # "no crontab exists", and backs the current crontab up to a timestamped file first.
    heimdall_crontab_install 'heimdall-maintainer-' "$beatline" "$cycleline" \
      || die "could not install the maintainer cron — your crontab was NOT modified (see the error above)."
    say "cron installed (runner-beat 1/min + cycle '$CRON')"
  fi
}

# ── Arch B: Cloud Run Job ────────────────────────────────────────────────────
mksecret() { # $1 secret name  $2 token-var-name (value via stdin, never argv)
  local name="$1" var="$2"
  show "gcloud secrets create $name --replication-policy=automatic --project=$PROJECT  (|| exists)"
  [ "$DRY" = 1 ] && { run "printf '%s' \$$var | gcloud secrets versions add $name --data-file=- --project=$PROJECT"; return 0; }
  gcloud secrets create "$name" --replication-policy=automatic --project="$PROJECT" 2>/dev/null || true
  printf '%s' "${!var}" | gcloud secrets versions add "$name" --data-file=- --project="$PROJECT" >/dev/null
  gcloud secrets add-iam-policy-binding "$name" --project="$PROJECT" \
    --member="serviceAccount:${RUNTIME_SA}" --role=roles/secretmanager.secretAccessor >/dev/null
  say "secret $name: version added + accessor granted"
}
mksecret_file() { # $1 secret name  $2 file path (streamed via --data-file, never argv)
  local name="$1" file="$2"
  show "gcloud secrets create $name --replication-policy=automatic --project=$PROJECT  (|| exists)"
  [ "$DRY" = 1 ] && { run "gcloud secrets versions add $name --data-file=<App key.pem> --project=$PROJECT"; return 0; }
  gcloud secrets create "$name" --replication-policy=automatic --project="$PROJECT" 2>/dev/null || true
  gcloud secrets versions add "$name" --data-file="$file" --project="$PROJECT" >/dev/null
  gcloud secrets add-iam-policy-binding "$name" --project="$PROJECT" \
    --member="serviceAccount:${RUNTIME_SA}" --role=roles/secretmanager.secretAccessor >/dev/null
  say "secret $name: version added + accessor granted"
}
arch_b() {
  say "Arch B — Cloud Run Job (project=$PROJECT region=$REGION)"
  if [ "$MINT_LEGACY" = 1 ]; then
    mksecret heimdall-cc-oauth-token OAUTH_TOKEN
    # the static PAT secret is the fallback — created in dry-run (shape) or when a PAT was entered.
    if [ "$DRY" = 1 ] || [ -n "$BOT_TOKEN" ]; then
      mksecret heimdall-pr-bot-token   BOT_TOKEN
    fi
  else
    say "multi-tenant: per-team creds injected at dispatch — legacy secret mint skipped"
  fi
  if [ "$GH_APP" = 1 ]; then
    # RECOMMENDED bot identity — the App private key as a secret; App id + installation id
    # as (non-secret) Job env. The Job mints a fresh 1h installation token per cycle.
    mksecret_file "$GH_APP_KEY_SECRET" "$GH_APP_KEY_FILE"
    say "GitHub App PR-bot (recommended): wire the maintainer Job with —"
    printf '  \033[90m--set-secrets="HEIMDALL_GH_APP_PRIVATE_KEY=%s:latest"\033[0m\n' "$GH_APP_KEY_SECRET"
    printf '  \033[90m--set-env-vars="HEIMDALL_GH_APP_ID=%s,HEIMDALL_GH_APP_INSTALLATION_ID=%s"\033[0m\n' "$GH_APP_ID" "$GH_APP_INSTALL_ID"
  fi
  # image toolchain gate: the base long-job image lacks git/gh/claude — refuse a broken deploy
  say "verify the maintainer image carries git + gh + claude"
  if [ "$DRY" != 1 ]; then
    local img; img="$(grep -oE 'image: .*heimdall-maintainer@sha256:[^ ]+' "$YAML" | awk '{print $2}')"
    case "$img" in *REPLACE_WITH_DIGEST*) die "manifest image digest is a placeholder — build+push the maintainer image (git/gh/claude), pin its @sha256 digest in $YAML, then re-run. See MAINTAINER-RUNBOOK.md §Arch-B image." ;; esac
  else
    run "check $YAML image digest is a real @sha256 (not REPLACE_WITH_DIGEST) — else STOP, build the maintainer image first"
  fi
  show "gcloud run jobs replace $YAML --region=$REGION --project=$PROJECT"
  [ "$DRY" = 1 ] || gcloud run jobs replace "$YAML" --region="$REGION" --project="$PROJECT"
  # IAM: a least-priv role that can run the job (idempotent)
  show "gcloud iam roles create heimdallJobRunner --project=$PROJECT --permissions=run.jobs.run  (|| exists)"
  [ "$DRY" = 1 ] || gcloud iam roles create heimdallJobRunner --project="$PROJECT" --permissions=run.jobs.run >/dev/null 2>&1 || true
  show "gcloud projects add-iam-policy-binding $PROJECT --member=serviceAccount:${RUNTIME_SA} --role=projects/$PROJECT/roles/heimdallJobRunner --condition=None"
  [ "$DRY" = 1 ] || gcloud projects add-iam-policy-binding "$PROJECT" --member="serviceAccount:${RUNTIME_SA}" --role="projects/$PROJECT/roles/heimdallJobRunner" --condition=None >/dev/null
  say "cloud job '$JOB' deployed. Hybrid tick fires it when your box is down."
  if [ -z "$SCHEDULE" ]; then
    warn "schedule registration (per-minute tick fires run-maintainer-cycle): pass --schedule \"<cron>\" to register it now (heimdall-control-plane schedule-maintainer), or see MAINTAINER-RUNBOOK.md §6."
  fi
}

# ── register the maintainer cron with the control plane (the tick fires it) ───
# When --schedule is given, register an ALLOWLISTED run-maintainer-cycle schedule via the
# control-plane verb so the per-minute tick fires it autonomously — IDEMPOTENT (same repo+cron
# updates in place, never duplicates). For --cloud, the tick must reach the Cloud Run Job when
# no local runner beats: HEIMDALL_MAINTAINER_RUNNER=cloud|hybrid selects CloudRunJobRunner. The
# schedule store is the control plane's (set HEIMDALL_STATE_BACKEND=firestore + project for a
# cloud control plane). No token is handled here — the schedule carries only typed scalars.
register_schedule() {
  [ -n "$SCHEDULE" ] || return 0
  say "register the maintainer cron '$SCHEDULE' with the control plane (tick fires run-maintainer-cycle)"
  [ -x "$CP_CLI" ] || die "heimdall-control-plane not found/executable at $CP_CLI"
  if [ "$MODE" = cloud ]; then
    if [ "$DRY" = 1 ]; then
      run "export HEIMDALL_MAINTAINER_RUNNER=cloud  # absent local runner -> tick uses the Cloud Run Job"
    else
      export HEIMDALL_MAINTAINER_RUNNER=cloud
      say "HEIMDALL_MAINTAINER_RUNNER=cloud (an absent local runner routes the tick to the Cloud Run Job)"
    fi
    warn "ensure the deployed control-plane SERVICE runs with HEIMDALL_MAINTAINER_RUNNER=cloud|hybrid so its tick reaches the Job (MAINTAINER-RUNBOOK.md §6)."
  fi
  run "$CP_CLI" schedule-maintainer --repo "$REPO" --cron "$SCHEDULE" --max "$MAXN"
}

# ── legacy single-tenant secret auto-detect ──────────────────────────────────
# The base Job manifest either MOUNTS the single-tenant secrets (heimdall-cc-oauth-token /
# heimdall-pr-bot-token via secretKeyRef) — the LEGACY path where the operator mints them —
# or it does NOT (MULTI-TENANT: the dispatcher injects per-team creds per execution). We only
# prompt for + mint those legacy secrets when the manifest actually references them. This
# stops a multi-tenant --cloud deploy from running `claude setup-token` (which prints a live
# ~1-year token to the terminal) and prompting for creds that the shared Job never mounts.
LEGACY_MANIFEST=0
if [ -f "$YAML" ] && grep -qE 'heimdall-cc-oauth-token|heimdall-pr-bot-token' "$YAML"; then
  LEGACY_MANIFEST=1
fi
# arch_b mints the legacy secrets only when the cloud manifest actually mounts them.
MINT_LEGACY=0
case "$MODE" in cloud|hybrid) [ "$LEGACY_MANIFEST" = 1 ] && MINT_LEGACY=1 ;; esac
# collect_secrets prompts when a consumer needs the tokens at deploy time: the Arch-A local
# runner (local/hybrid) always needs the OAuth token; a GitHub App identity (--gh-app) is an
# explicit opt-in; and arch_b needs them only when it will mint the legacy cloud secrets. A
# cloud-only deploy against a multi-tenant manifest needs NO token — nothing is minted here.
PROMPT_TOKENS=0
case "$MODE" in
  local|hybrid) PROMPT_TOKENS=1 ;;
  cloud) { [ "$MINT_LEGACY" = 1 ] || [ "$GH_APP" = 1 ]; } && PROMPT_TOKENS=1 ;;
esac

case "$MODE" in
  local)  collect_secrets; arch_a ;;
  cloud)  collect_secrets; arch_b ;;
  hybrid) collect_secrets; arch_a; arch_b ;;
esac
register_schedule
echo; say "done ($MODE)."
[ "$DRY" = 1 ] && warn "dry-run: nothing executed. Re-run without --dry-run to apply."
exit 0
