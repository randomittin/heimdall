#!/usr/bin/env bash
# setup-bot.sh — stand up (or wire in) the Heimdall maintainer's DEDICATED PR-BOT as a
# GitHub App. This is the clean, no-user-seat, auto-scoped, revocable identity RJ chose:
# the maintainer opens PRs AS THE APP (never as the operator's personal account), scoped
# to Contents + Issues + Pull requests write on the target repo(s) — NEVER main, NEVER merge.
#
# RUN BY THE OPERATOR (RJ) on his own machine. The agent never runs this. Secret
# discipline mirrors deploy/cloud-run/deploy-maintainer.sh: the App private key is read
# from a FILE and streamed to the 0600 store / gcloud STDIN — NEVER echoed, NEVER an
# argv element, NEVER logged. No `set -x`. The minted verify token is captured into a
# shell var and never printed.
#
# TWO MODES:
#   (plan — default)  print the App MANIFEST + create-App URL + the exact PERMISSIONS to
#                     grant + the install-on-target-repo-only step + the verify step.
#                     Needs NO creds. `--dry-run` is the same, explicitly executing nothing.
#   --configure       you ALREADY created the App + installed it: pass its --app-id,
#                     --installation-id, and --private-key-file; this VERIFIES the creds by
#                     minting a test installation token via bin/heimdall-gh-app-token, then
#                     writes them to a 0600 store (default ~/.heimdall/gh-app.env) — or, with
#                     --cloud, to Google Secret Manager. Idempotent.
#
# Usage:
#   deploy/github-app/setup-bot.sh [--dry-run] [--repo <owner/name>]
#   deploy/github-app/setup-bot.sh --configure --app-id <N> --installation-id <N> \
#       --private-key-file <path.pem> [--repo <owner/name>] \
#       [--cloud --project <gcp-project>] [--store <path>] [--dry-run]
set -euo pipefail

DRY=0; CONFIGURE=0; CLOUD=0
APP_ID=""; INSTALL_ID=""; KEY_FILE=""; REPO=""; PROJECT="heimdall-cp-prod"
STORE=""
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
MINT="$ROOT/bin/heimdall-gh-app-token"
DEFAULT_STORE="$HOME/.heimdall/gh-app.env"
KEY_STORE="$HOME/.heimdall/gh-app-private-key.pem"
RUNTIME_SA="heimdall-cp-runtime@${PROJECT}.iam.gserviceaccount.com"
KEY_SECRET="heimdall-gh-app-private-key"

usage() { sed -n '/^# Usage:/,/\[--store <path>\] \[--dry-run\]/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }
while [ $# -gt 0 ]; do case "$1" in
  --dry-run)          DRY=1; shift ;;
  --configure)        CONFIGURE=1; shift ;;
  --cloud)            CLOUD=1; shift ;;
  --app-id)           APP_ID="${2:?}"; shift 2 ;;
  --installation-id)  INSTALL_ID="${2:?}"; shift 2 ;;
  --private-key-file) KEY_FILE="${2:?}"; shift 2 ;;
  --repo)             REPO="${2:?}"; shift 2 ;;
  --project)          PROJECT="${2:?}"; RUNTIME_SA="heimdall-cp-runtime@${PROJECT}.iam.gserviceaccount.com"; shift 2 ;;
  --store)            STORE="${2:?}"; shift 2 ;;
  -h|--help)          usage; exit 0 ;;
  *) echo "unknown arg: $1" >&2; usage >&2; exit 2 ;;
esac; done
[ -n "$STORE" ] || STORE="$DEFAULT_STORE"

say()  { printf '\033[36m▸ %s\033[0m\n' "$*"; }
warn() { printf '\033[33m! %s\033[0m\n' "$*" >&2; }
die()  { printf '\033[31m✗ %s\033[0m\n' "$*" >&2; exit 1; }
run()  { if [ "$DRY" = 1 ]; then printf '  \033[90m$ %s\033[0m\n' "$*"; else "$@"; fi; }

# ── the App manifest (the permissions the App is created with) ────────────────
# GitHub App PERMISSIONS to grant — and ONLY these:
#   • Contents: Read and write      — push the heimdall/* fix branch (+ read repo code).
#   • Actions: Read                 — SEE CI/workflow-run failures (read-only; forward-compat
#                                    for auto-fixing CI). Workflow-FILE edits need Workflows:write
#                                    (deferred — a per-team opt-in gate, off by default).
#   • Issues: Read and write        — READ the issue queue (the connector's work source),
#                                     comment "resolved by #N" + close the resolved issue.
#   • Pull requests: Read and write — open the PR (+ post the proof receipt comment).
#   • Metadata: Read-only           — mandatory baseline for any App (auto).
# DENY everything else. In particular: NO Administration (so the App can NOT edit branch
# protection or repo settings), NO Workflows/Actions (no CI mutation — supply-chain safety),
# NO Commit statuses / Checks (the gate runs tests LOCALLY; it never reads CI status),
# NO Members, NO Deployments.
print_manifest() {
  local name="heimdall-pr-bot"
  cat <<MANIFEST
{
  "name": "$name",
  "url": "https://github.com/randomittin/heimdall",
  "public": false,
  "default_permissions": {
    "contents": "write",
    "issues": "write",
    "pull_requests": "write",
    "actions": "read",
    "metadata": "read"
  },
  "default_events": []
}
MANIFEST
}

print_plan() {
  echo
  printf '\033[1m╔═ HEIMDALL PR-BOT — GitHub App setup plan ══════════════╗\033[0m\n'
  printf '\033[1m║\033[0m The maintainer opens PRs AS THIS APP (a distinct bot\n'
  printf '\033[1m║\033[0m identity — NEVER the operator'\''s personal account), on\n'
  printf '\033[1m║\033[0m heimdall/* branches only. It NEVER pushes main, NEVER\n'
  printf '\033[1m║\033[0m merges. A human merges. RJ holds the App private key.\n'
  printf '\033[1m╚════════════════════════════════════════════════════════╝\033[0m\n'
  echo

  say "1. Create the GitHub App (personal or org — your choice):"
  echo "     • Personal: https://github.com/settings/apps/new"
  echo "     • Org:      https://github.com/organizations/<ORG>/settings/apps/new"
  echo "   You can paste this MANIFEST (Apps → new → 'from manifest') to pre-fill it:"
  print_manifest | sed 's/^/     /'
  echo

  say "2. Grant EXACTLY these repository PERMISSIONS — and nothing more:"
  echo "     • Contents: Read and write      → push the heimdall/* fix branch (+ read code)"
  echo "     • Actions: Read                 → see CI/workflow-run failures (read-only)"
  echo "     • Issues: Read and write        → READ the issue queue + comment/close resolved"
  echo "     • Pull requests: Read and write → open the PR + post the proof receipt"
  echo "     • Metadata: Read-only           → mandatory baseline (auto-selected)"
  echo "   DENIED (do NOT grant): no Administration (cannot touch branch protection or"
  echo "     repo settings), no Workflows/Actions (no CI mutation), no Commit statuses/Checks"
  echo "     (the gate runs tests locally; it never reads CI status), no Members, no"
  echo "     Deployments, no merge permission beyond what a human review gate allows."
  echo

  say "3. Install the App on the TARGET REPO(S) ONLY (never 'All repositories'):"
  echo "     App → Install App → pick your account/org → 'Only select repositories'"
  echo "     → choose ${REPO:-<owner/repo>}. This bounds the installation's scope to that repo."
  echo

  say "4. Server-side 'never push main, never merge' backstop (recommended):"
  echo "     Add a branch protection rule on 'main' requiring a PR + review, and do NOT"
  echo "     allow the App to bypass it. Combined with NO Administration permission, the"
  echo "     App can neither push main directly nor self-merge — a human merges."
  echo

  say "5. Collect the three creds GitHub shows you after create+install:"
  echo "     • App ID           (Settings → your App → 'App ID')"
  echo "     • A private key    (Settings → your App → 'Generate a private key' → .pem)"
  echo "     • Installation ID  (the number in the install URL .../installations/<ID>)"
  echo

  say "6. Wire them in + VERIFY by minting a test installation token:"
  echo "     deploy/github-app/setup-bot.sh --configure \\"
  echo "       --app-id <N> --installation-id <N> --private-key-file <path.pem> \\"
  echo "       --repo ${REPO:-<owner/repo>}   # add --cloud --project <p> for Secret Manager"
  echo "   That runs '$MINT' with your creds; a 201 (a real token minted) confirms the"
  echo "   App ID + private key + installation id all line up. The token is discarded."
  echo
  say "The maintainer then mints a FRESH 1-hour installation token PER CYCLE (App tokens"
  say "expire hourly) and exports it as HEIMDALL_PR_BOT_TOKEN — issue_pr opens the PR as"
  say "the App bot, unchanged."
  [ "$DRY" = 1 ] && warn "dry-run: nothing executed, no creds used."
}

# ── --configure: verify the creds, then persist them 0600 / to Secret Manager ─
verify_creds() {
  [ -n "$APP_ID" ]     || die "--configure needs --app-id <N>"
  [ -n "$INSTALL_ID" ] || die "--configure needs --installation-id <N>"
  [ -n "$KEY_FILE" ]   || die "--configure needs --private-key-file <path.pem>"
  # a dry-run only PREVIEWS the plan — don't require the real key/minter to be present yet.
  [ "$DRY" = 1 ] || [ -f "$KEY_FILE" ] || die "private key file not found: $KEY_FILE"
  [ "$DRY" = 1 ] || [ -x "$MINT" ]     || die "missing the token minter: $MINT"

  say "verify — mint a test installation token via heimdall-gh-app-token (no token printed)"
  if [ "$DRY" = 1 ]; then
    run "HEIMDALL_GH_APP_ID=$APP_ID HEIMDALL_GH_APP_INSTALLATION_ID=$INSTALL_ID HEIMDALL_GH_APP_PRIVATE_KEY_FILE=<key.pem> $MINT >/dev/null"
    return 0
  fi
  # the key path is env-only; the minted token is captured + discarded (never echoed).
  local TESTTOK=""
  TESTTOK="$(HEIMDALL_GH_APP_ID="$APP_ID" \
             HEIMDALL_GH_APP_INSTALLATION_ID="$INSTALL_ID" \
             HEIMDALL_GH_APP_PRIVATE_KEY_FILE="$KEY_FILE" \
             "$MINT")" || die "verify failed — the App ID / private key / installation id do not mint a token (see the error above)"
  [ -n "$TESTTOK" ] || die "verify failed — the minter returned an empty token"
  TESTTOK=""
  say "verify OK — the creds mint a live installation token."
}

configure_local() {
  say "persist creds to the 0600 local store ($STORE) + key ($KEY_STORE)"
  if [ "$DRY" = 1 ]; then
    run "umask 177; mkdir -p ~/.heimdall; cp <key.pem> $KEY_STORE (chmod 600)"
    run "write $STORE (HEIMDALL_GH_APP_ID, HEIMDALL_GH_APP_INSTALLATION_ID, HEIMDALL_GH_APP_PRIVATE_KEY_FILE=$KEY_STORE) chmod 600"
    return 0
  fi
  ( umask 177
    mkdir -p "$(dirname "$STORE")"
    chmod 700 "$(dirname "$STORE")" 2>/dev/null || true
    cp "$KEY_FILE" "$KEY_STORE"
    chmod 600 "$KEY_STORE"
    {
      printf 'export HEIMDALL_GH_APP_ID=%q\n' "$APP_ID"
      printf 'export HEIMDALL_GH_APP_INSTALLATION_ID=%q\n' "$INSTALL_ID"
      printf 'export HEIMDALL_GH_APP_PRIVATE_KEY_FILE=%q\n' "$KEY_STORE"
    } > "$STORE"
  )
  chmod 600 "$STORE"
  say "wrote $STORE + $KEY_STORE (mode 600 — contents never printed)."
  say "Source it in the maintainer's shell/env: . $STORE"
}

configure_cloud() {
  say "persist creds to Google Secret Manager (project=$PROJECT)"
  command -v gcloud >/dev/null 2>&1 || die "missing 'gcloud' — install the Google Cloud SDK"
  if [ "$DRY" = 1 ]; then
    run "gcloud secrets create $KEY_SECRET --replication-policy=automatic --project=$PROJECT  (|| exists)"
    run "gcloud secrets versions add $KEY_SECRET --data-file=<key.pem> --project=$PROJECT"
    run "gcloud secrets add-iam-policy-binding $KEY_SECRET --member=serviceAccount:$RUNTIME_SA --role=roles/secretmanager.secretAccessor --project=$PROJECT"
    echo "     then wire the maintainer Job with:"
    echo "       --set-secrets=\"HEIMDALL_GH_APP_PRIVATE_KEY=$KEY_SECRET:latest\""
    echo "       --set-env-vars=\"HEIMDALL_GH_APP_ID=$APP_ID,HEIMDALL_GH_APP_INSTALLATION_ID=$INSTALL_ID\""
    return 0
  fi
  gcloud secrets create "$KEY_SECRET" --replication-policy=automatic --project="$PROJECT" 2>/dev/null || true
  # the PEM is streamed from the FILE directly — never an argv, never echoed.
  gcloud secrets versions add "$KEY_SECRET" --data-file="$KEY_FILE" --project="$PROJECT" >/dev/null
  gcloud secrets add-iam-policy-binding "$KEY_SECRET" --project="$PROJECT" \
    --member="serviceAccount:${RUNTIME_SA}" --role=roles/secretmanager.secretAccessor >/dev/null
  say "secret $KEY_SECRET: version added + accessor granted to $RUNTIME_SA."
  say "Wire the maintainer Job (App ID + installation id are non-secret env, key is a secret):"
  echo "   --set-secrets=\"HEIMDALL_GH_APP_PRIVATE_KEY=$KEY_SECRET:latest\""
  echo "   --set-env-vars=\"HEIMDALL_GH_APP_ID=$APP_ID,HEIMDALL_GH_APP_INSTALLATION_ID=$INSTALL_ID\""
}

if [ "$CONFIGURE" = 1 ]; then
  verify_creds
  if [ "$CLOUD" = 1 ]; then configure_cloud; else configure_local; fi
  echo; say "done — the maintainer can now mint per-cycle App installation tokens."
  [ "$DRY" = 1 ] && warn "dry-run: nothing executed, no creds used. Re-run without --dry-run to apply."
else
  print_plan
fi
exit 0
