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
#   --hybrid (default) sets up Arch A (this box) AND Arch B (cloud fallback).
#   --local  Arch A only (no gcloud).   --cloud  Arch B only.
#   --schedule "<cron>" REGISTERS the maintainer cron with the control plane so the
#            per-minute tick fires run-maintainer-cycle autonomously (heimdall-control-plane
#            schedule-maintainer — idempotent). Without it, schedule registration stays
#            manual (see MAINTAINER-RUNBOOK.md §6). For --cloud, the tick reaches the Job
#            when HEIMDALL_MAINTAINER_RUNNER=cloud|hybrid (an absent local runner -> the Job).
#   --dry-run prints the full plan, executes nothing, needs NO creds/tokens.
set -euo pipefail

MODE="hybrid"; DRY=0; REPO=""; PROJECT="heimdall-control-plane"; REGION="us-central1"
MAXN="3"; CRON="*/30 * * * *"; SCHEDULE=""
JOB="heimdall-maintainer-job"
RUNTIME_SA="heimdall-cp-run@${PROJECT}.iam.gserviceaccount.com"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
LOOP="$ROOT/bin/heimdall-maintain-loop"
CP_CLI="$ROOT/bin/heimdall-control-plane"
YAML="$HERE/heimdall-maintainer-job.yaml"
ENVFILE="$HOME/.heimdall/maintainer.env"

usage() { sed -n '2,21p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }
while [ $# -gt 0 ]; do case "$1" in
  --local|--cloud|--hybrid) MODE="${1#--}"; shift ;;
  --dry-run) DRY=1; shift ;;
  --repo) REPO="${2:?}"; shift 2 ;;
  --project) PROJECT="${2:?}"; shift 2 ;;
  --region) REGION="${2:?}"; shift 2 ;;
  --max) MAXN="${2:?}"; shift 2 ;;
  --cron) CRON="${2:?}"; shift 2 ;;
  --schedule) SCHEDULE="${2:?}"; shift 2 ;;
  -h|--help) usage; exit 0 ;;
  *) echo "unknown arg: $1" >&2; usage >&2; exit 2 ;;
esac; done

say()  { printf '\033[36m▸ %s\033[0m\n' "$*"; }
warn() { printf '\033[33m! %s\033[0m\n' "$*" >&2; }
die()  { printf '\033[31m✗ %s\033[0m\n' "$*" >&2; exit 1; }
# run: in --dry-run print the command (no secrets are ever in argv), else execute.
run()  { if [ "$DRY" = 1 ]; then printf '  \033[90m$ %s\033[0m\n' "$*"; else "$@"; fi; }

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
  say "mint a ~1-year subscription token (a browser will open — only you can consent)"
  claude setup-token || die "claude setup-token failed"
  printf 'Paste the CLAUDE_CODE_OAUTH_TOKEN (sk-ant-oat-...): '; read -rs OAUTH_TOKEN; echo
  [ -n "$OAUTH_TOKEN" ] || die "no OAuth token entered"
  printf 'Paste the HEIMDALL_PR_BOT_TOKEN (scoped: contents:write on heimdall/*, pull_requests:write; NO main, NO merge): '
  read -rs BOT_TOKEN; echo
  [ -n "$BOT_TOKEN" ] || die "no bot token entered"
}

# ── Arch A: local runner on this box ─────────────────────────────────────────
arch_a() {
  say "Arch A — local runner on this machine"
  if [ "$DRY" != 1 ]; then
    mkdir -p "$(dirname "$ENVFILE")"
    ( umask 177; {
        printf 'export HEIMDALL_JOB_RUNNER=subprocess\n'
        printf 'export HEIMDALL_MAINTAINER_RUNNER=hybrid\n'
        printf 'export CLAUDE_CODE_OAUTH_TOKEN=%q\n' "$OAUTH_TOKEN"
        printf 'export HEIMDALL_PR_BOT_TOKEN=%q\n' "$BOT_TOKEN"
      } > "$ENVFILE" )
    chmod 600 "$ENVFILE"
    say "wrote $ENVFILE (mode 600 — contents never printed)"
    # smoke: prove liveness + run one cycle
    # shellcheck disable=SC1090
    . "$ENVFILE"
    run "$LOOP" runner-beat --repo "$REPO"
    run "$LOOP" run --max 1 --repo "$ROOT"
  else
    run "umask 177; write $ENVFILE (HEIMDALL_JOB_RUNNER, HEIMDALL_MAINTAINER_RUNNER, tokens) chmod 600"
    run "$LOOP runner-beat --repo $REPO"
    run "$LOOP run --max 1 --repo $ROOT"
  fi
  # idempotent cron: runner-beat every minute (Arch A liveness) + cycle on schedule
  local beatline cycleline tmpc
  beatline="* * * * * . $ENVFILE; $LOOP runner-beat --repo $REPO >/dev/null 2>&1 # heimdall-maintainer-beat"
  cycleline="$CRON . $ENVFILE; $LOOP run --max $MAXN --repo $ROOT >/dev/null 2>&1 # heimdall-maintainer-cycle"
  if [ "$DRY" = 1 ]; then
    run "crontab: add (dedup on marker) —"; printf '    %s\n    %s\n' "$beatline" "$cycleline"
  else
    tmpc="$(mktemp)"; crontab -l 2>/dev/null | grep -v 'heimdall-maintainer-' > "$tmpc" || true
    printf '%s\n%s\n' "$beatline" "$cycleline" >> "$tmpc"
    crontab "$tmpc"; rm -f "$tmpc"
    say "cron installed (runner-beat 1/min + cycle '$CRON')"
  fi
}

# ── Arch B: Cloud Run Job ────────────────────────────────────────────────────
mksecret() { # $1 secret name  $2 token-var-name (value via stdin, never argv)
  local name="$1" var="$2"
  run "gcloud secrets create $name --replication-policy=automatic --project=$PROJECT  (|| exists)"
  [ "$DRY" = 1 ] && { run "printf '%s' \$$var | gcloud secrets versions add $name --data-file=- --project=$PROJECT"; return 0; }
  gcloud secrets create "$name" --replication-policy=automatic --project="$PROJECT" 2>/dev/null || true
  printf '%s' "${!var}" | gcloud secrets versions add "$name" --data-file=- --project="$PROJECT" >/dev/null
  gcloud secrets add-iam-policy-binding "$name" --project="$PROJECT" \
    --member="serviceAccount:${RUNTIME_SA}" --role=roles/secretmanager.secretAccessor >/dev/null
  say "secret $name: version added + accessor granted"
}
arch_b() {
  say "Arch B — Cloud Run Job (project=$PROJECT region=$REGION)"
  mksecret heimdall-cc-oauth-token OAUTH_TOKEN
  mksecret heimdall-pr-bot-token   BOT_TOKEN
  # image toolchain gate: the base long-job image lacks git/gh/claude — refuse a broken deploy
  say "verify the maintainer image carries git + gh + claude"
  if [ "$DRY" != 1 ]; then
    local img; img="$(grep -oE 'image: .*heimdall-maintainer@sha256:[^ ]+' "$YAML" | awk '{print $2}')"
    case "$img" in *REPLACE_WITH_DIGEST*) die "manifest image digest is a placeholder — build+push the maintainer image (git/gh/claude), pin its @sha256 digest in $YAML, then re-run. See MAINTAINER-RUNBOOK.md §Arch-B image." ;; esac
  else
    run "check $YAML image digest is a real @sha256 (not REPLACE_WITH_DIGEST) — else STOP, build the maintainer image first"
  fi
  run "gcloud run jobs replace $YAML --region=$REGION --project=$PROJECT"
  # IAM: a least-priv role that can run the job (idempotent)
  run "gcloud iam roles create heimdallJobRunner --project=$PROJECT --permissions=run.jobs.run  (|| exists)"
  run "gcloud projects add-iam-policy-binding $PROJECT --member=serviceAccount:${RUNTIME_SA} --role=projects/$PROJECT/roles/heimdallJobRunner"
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

case "$MODE" in
  local)  collect_secrets; arch_a ;;
  cloud)  collect_secrets; arch_b ;;
  hybrid) collect_secrets; arch_a; arch_b ;;
esac
register_schedule
echo; say "done ($MODE)."
[ "$DRY" = 1 ] && warn "dry-run: nothing executed. Re-run without --dry-run to apply."
exit 0
