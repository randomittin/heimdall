#!/usr/bin/env bash
# setup-ops-hardening.sh — THE IDEMPOTENT OPERATOR for prod-readiness items #3 (alerting)
# and #5 (Firestore data-lifecycle: TTL + PITR + backup).
#
# WHAT THIS IS. A one-shot, RE-RUNNABLE sequencer RJ runs under his OWN already-authenticated
# gcloud shell against project heimdall-cp-prod. It closes the two "no-code, minutes-of-work"
# gaps from docs/analysis/prod-readiness-audit-2026-07-06.md:
#
#   #3 ALERTING (§3d — today a dead task pages NOBODY):
#     • log-based metric  heimdall_task_dead   — cp_boot drain "-> dead(attempts=" / "dead=[1-9]"
#     • log-based metric  heimdall_tick_error  — "cp_boot: tick error" / "drain…ERROR" / "REFUSED reason="
#     • alert policy on each metric (threshold > 0 over a 5-min window)
#     • alert policy on maintainer-JOB execution failures
#       (run.googleapis.com/job/completed_execution_count, result="failed")
#     • an email notification channel (rj@superpe.co), created-if-absent, wired to every policy
#
#   #5 DATA LIFECYCLE (§4 — PITR DISABLED, no TTL, no backup — a bad write is unrecoverable):
#     • Firestore TTL policy on the `ttl_at` field of collection group heimdall_cp. That field
#       is written ONLY on the ephemeral doc families (nonce + ratelimit) by cp_state_firestore
#       (_TTL_ELIGIBLE_ROOTS) — durable job/approval docs carry NO ttl_at, so the ONE policy
#       reaps only the safe-to-expire docs and never a job log. (heimdall_cp is a single flat
#       collection: TTL discriminates by the field's PRESENCE, not by collection.)
#     • PITR enabled (7-day recovery window).
#     • a DAILY backup schedule, 7-day retention.
#
# IDEMPOTENT. Every step GUARDS on a read-only describe/list before it mutates: an existing
# metric is UPDATEd not re-created; an existing channel/policy/backup-schedule is REUSED; an
# already-enabled TTL/PITR is left alone. Re-running is a no-op.
#
# --dry-run (aka --plan / --check). Prints EVERY command it would run — with real flags — and
# executes ZERO mutating gcloud (no auth, no spend, no side effects). This is the review mode
# and the shape test/heimdall-ops-hardening.test.sh asserts against.
#
# THIS SCRIPT NEVER RUNS THE MAINTAINER TICK OR ANY DISPATCH — it only touches monitoring +
# firestore admin surfaces. No secret value ever appears (there are none here). set -x is NEVER
# enabled.

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── config (every value overridable from the env; defaults match the audit §0) ────────────
PROJECT_ID="${PROJECT_ID:-heimdall-cp-prod}"
REGION="${REGION:-us-central1}"
DATABASE="${DATABASE:-(default)}"
MAINTAINER_JOB="${MAINTAINER_JOB:-heimdall-maintainer-job}"
NOTIF_EMAIL="${NOTIF_EMAIL:-rj@superpe.co}"

# Firestore lifecycle knobs.
COLLECTION_GROUP="${COLLECTION_GROUP:-heimdall_cp}"   # the flat root collection (HEIMDALL_FIRESTORE_ROOT)
TTL_FIELD="${TTL_FIELD:-ttl_at}"                      # the top-level Timestamp cp_state_firestore writes
BACKUP_RETENTION="${BACKUP_RETENTION:-7d}"

# Alerting names.
METRIC_DEAD="${METRIC_DEAD:-heimdall_task_dead}"
METRIC_TICK="${METRIC_TICK:-heimdall_tick_error}"

# The log filters (single-quoted below — they contain double quotes only, never a single quote).
# heimdall_task_dead: a task went to the dead-letter bucket. Matches the maintainer-runner line
# "… -> dead(attempts=N)" AND the cp_boot drain-cycle line "… dead=N" with N in 1-9 (dead=0 is
# the healthy steady state and MUST NOT fire).
METRIC_DEAD_FILTER='resource.type="cloud_run_revision" AND (textPayload:"-> dead(attempts=" OR textPayload=~"dead=[1-9]")'
# heimdall_tick_error: the per-minute clock faulted, a drain errored, or a dispatch was refused.
METRIC_TICK_FILTER='resource.type="cloud_run_revision" AND textPayload=~"cp_boot: tick error|drain.*ERROR|REFUSED reason="'

# The alert-condition metric filters (monitoring, not logging).
POLICY_DEAD_FILTER='metric.type="logging.googleapis.com/user/'"${METRIC_DEAD}"'" AND resource.type="cloud_run_revision"'
POLICY_TICK_FILTER='metric.type="logging.googleapis.com/user/'"${METRIC_TICK}"'" AND resource.type="cloud_run_revision"'
POLICY_JOB_FILTER='metric.type="run.googleapis.com/job/completed_execution_count" AND resource.type="cloud_run_job" AND resource.label.job_name="'"${MAINTAINER_JOB}"'" AND metric.label.result="failed"'

# The alert threshold aggregation: sum the delta counter over the 5-min alignment window (double
# quotes only → single-quote wrappable). Threshold "> 0" over duration 300s == "any in 5 min".
POLICY_AGG='{"alignmentPeriod":"300s","perSeriesAligner":"ALIGN_SUM","crossSeriesReducer":"REDUCE_SUM"}'

# Populated by notification_channel(); consumed by every idempotent_policy().
CH=""

# ── mode ──────────────────────────────────────────────────────────────────────────────────
DRY=0
case "${1:-}" in
  ""|apply|--apply)         DRY=0 ;;
  --dry-run|--plan|--check) DRY=1 ;;
  -h|--help)
    printf 'usage: %s [--dry-run|--plan|--check]\n' "$0"
    printf '  (no arg) apply : GUARD then create/update each resource (idempotent, mutating)\n'
    printf '  --dry-run       : print every command, run ZERO mutating gcloud (no auth/spend)\n'
    exit 0 ;;
  *)
    printf 'FATAL unknown arg %q — use --dry-run/--plan/--check or no arg (apply)\n' "$1" >&2
    exit 2 ;;
esac

# ── output helpers ──────────────────────────────────────────────────────────────────────────
step() { printf '\n━━ %s\n' "$*"; }
note() { printf '      %s\n' "$*"; }
warn() { printf 'WARN  %s\n' "$*" >&2; }
plan() { printf '+ %s\n' "$*"; }   # a would-run command line (dry mode).

banner() {
  printf '════════════════════════════════════════════════════════════\n'
  if [ "$DRY" -eq 1 ]; then
    printf 'OPS-HARDENING PLAN (dry-run) — project=%s db=%s\n' "$PROJECT_ID" "$DATABASE"
    printf 'ZERO mutating gcloud runs. Review below, then re-run without --dry-run.\n'
  else
    printf 'OPS-HARDENING APPLY — project=%s db=%s\n' "$PROJECT_ID" "$DATABASE"
    printf 'Idempotent: each step guards before it mutates. Safe to re-run.\n'
  fi
  printf '════════════════════════════════════════════════════════════\n'
}

# ── #3a: email notification channel (created-if-absent) ─────────────────────────────────────
notification_channel() {
  step "notification channel (email ${NOTIF_EMAIL})"
  note "idempotent: reuse the existing email channel for this address, else create one"
  if [ "$DRY" -eq 1 ]; then
    plan "gcloud beta monitoring channels list --project=${PROJECT_ID} --filter='type=\"email\" AND labels.email_address=\"${NOTIF_EMAIL}\"' --format='value(name)'   # guard"
    plan "gcloud beta monitoring channels create --project=${PROJECT_ID} --display-name='Heimdall ops alerts (email)' --type=email --channel-labels=email_address=${NOTIF_EMAIL} --format='value(name)'"
    CH='<CHANNEL_ID>'
    note "(dry) downstream policies wire --notification-channels=${CH}"
    return
  fi
  CH="$(gcloud beta monitoring channels list --project="${PROJECT_ID}" \
        --filter="type=\"email\" AND labels.email_address=\"${NOTIF_EMAIL}\"" \
        --format='value(name)' 2>/dev/null | head -n1)"
  if [ -z "${CH}" ]; then
    CH="$(gcloud beta monitoring channels create --project="${PROJECT_ID}" \
          --display-name='Heimdall ops alerts (email)' --type=email \
          --channel-labels=email_address="${NOTIF_EMAIL}" --format='value(name)')"
    note "created channel: ${CH}"
  else
    note "reusing channel: ${CH}"
  fi
  [ -n "${CH}" ] || warn "no notification channel resolved — policies will be created WITHOUT a channel"
}

# ── #3b: a log-based metric (create, or update if it already exists) ────────────────────────
idempotent_metric() {
  local name="$1" desc="$2" filter="$3"
  step "log-based metric: ${name}"
  note "idempotent: update the filter if the metric exists, else create it"
  if [ "$DRY" -eq 1 ]; then
    plan "gcloud logging metrics describe ${name} --project=${PROJECT_ID}   # guard"
    plan "gcloud logging metrics create ${name} --project=${PROJECT_ID} --description='${desc}' --log-filter='${filter}'"
    plan "gcloud logging metrics update ${name} --project=${PROJECT_ID} --log-filter='${filter}'   # (guard hit → update instead of create)"
    return
  fi
  if gcloud logging metrics describe "${name}" --project="${PROJECT_ID}" >/dev/null 2>&1; then
    gcloud logging metrics update "${name}" --project="${PROJECT_ID}" --log-filter="${filter}"
    note "updated existing metric ${name}"
  else
    gcloud logging metrics create "${name}" --project="${PROJECT_ID}" \
      --description="${desc}" --log-filter="${filter}"
    note "created metric ${name}"
  fi
}

# ── #3c: an alert policy (threshold > 0 over 5 min), created-if-absent ──────────────────────
idempotent_policy() {
  local disp="$1" cond="$2" filter="$3"
  step "alert policy: ${disp}"
  note "idempotent: skip create if a policy with this display name already exists"
  if [ "$DRY" -eq 1 ]; then
    plan "gcloud alpha monitoring policies list --project=${PROJECT_ID} --filter='displayName=\"${disp}\"' --format='value(name)'   # guard"
    plan "gcloud alpha monitoring policies create --project=${PROJECT_ID} --display-name='${disp}' --condition-display-name='${cond}' --condition-filter='${filter}' --if='> 0' --duration=300s --aggregation='${POLICY_AGG}' --combiner=OR --notification-channels=${CH}"
    return
  fi
  local existing
  existing="$(gcloud alpha monitoring policies list --project="${PROJECT_ID}" \
              --filter="displayName=\"${disp}\"" --format='value(name)' 2>/dev/null | head -n1)"
  if [ -n "${existing}" ]; then
    note "policy exists (${existing}) — skipping"
    return
  fi
  local chan_flag=()
  [ -n "${CH}" ] && chan_flag=(--notification-channels="${CH}")
  gcloud alpha monitoring policies create --project="${PROJECT_ID}" \
    --display-name="${disp}" --condition-display-name="${cond}" \
    --condition-filter="${filter}" --if='> 0' --duration=300s \
    --aggregation="${POLICY_AGG}" --combiner=OR "${chan_flag[@]}"
  note "created policy ${disp}"
}

# ── #5a: Firestore TTL on ttl_at (collection group heimdall_cp) ─────────────────────────────
firestore_ttl() {
  step "Firestore TTL — field ${TTL_FIELD}, collection group ${COLLECTION_GROUP}"
  note "single flat collection: expires ONLY docs carrying a ${TTL_FIELD} Timestamp (nonce + ratelimit);"
  note "job/approval/audit docs have no ${TTL_FIELD} and are NEVER touched (cp_state_firestore._TTL_ELIGIBLE_ROOTS)"
  if [ "$DRY" -eq 1 ]; then
    plan "gcloud firestore fields ttls list --database='${DATABASE}' --project=${PROJECT_ID} --format='value(name)'   # guard"
    plan "gcloud firestore fields ttls update ${TTL_FIELD} --collection-group=${COLLECTION_GROUP} --database='${DATABASE}' --enable-ttl --project=${PROJECT_ID}"
    return
  fi
  if gcloud firestore fields ttls list --database="${DATABASE}" --project="${PROJECT_ID}" \
       --format='value(name)' 2>/dev/null | grep -q "/${COLLECTION_GROUP}/fields/${TTL_FIELD}$"; then
    note "TTL already enabled on ${COLLECTION_GROUP}.${TTL_FIELD} — skipping"
  else
    gcloud firestore fields ttls update "${TTL_FIELD}" \
      --collection-group="${COLLECTION_GROUP}" --database="${DATABASE}" \
      --enable-ttl --project="${PROJECT_ID}"
    note "TTL enabled on ${COLLECTION_GROUP}.${TTL_FIELD}"
  fi
}

# ── #5b: PITR (7-day point-in-time recovery) ────────────────────────────────────────────────
firestore_pitr() {
  step "Firestore PITR (point-in-time recovery)"
  if [ "$DRY" -eq 1 ]; then
    plan "gcloud firestore databases describe --database='${DATABASE}' --project=${PROJECT_ID} --format='value(pointInTimeRecoveryEnablement)'   # guard"
    plan "gcloud firestore databases update --database='${DATABASE}' --enable-pitr --project=${PROJECT_ID}"
    return
  fi
  local pitr
  pitr="$(gcloud firestore databases describe --database="${DATABASE}" --project="${PROJECT_ID}" \
          --format='value(pointInTimeRecoveryEnablement)' 2>/dev/null)"
  if [ "${pitr}" = "POINT_IN_TIME_RECOVERY_ENABLED" ]; then
    note "PITR already enabled — skipping"
  else
    gcloud firestore databases update --database="${DATABASE}" --enable-pitr --project="${PROJECT_ID}"
    note "PITR enabled"
  fi
}

# ── #5c: daily backup schedule (7-day retention) ────────────────────────────────────────────
firestore_backup() {
  step "Firestore daily backup schedule (retention ${BACKUP_RETENTION})"
  if [ "$DRY" -eq 1 ]; then
    plan "gcloud firestore backups schedules list --database='${DATABASE}' --project=${PROJECT_ID} --format=json   # guard"
    plan "gcloud firestore backups schedules create --database='${DATABASE}' --recurrence=daily --retention=${BACKUP_RETENTION} --project=${PROJECT_ID}"
    return
  fi
  if gcloud firestore backups schedules list --database="${DATABASE}" --project="${PROJECT_ID}" \
       --format=json 2>/dev/null | grep -q 'dailyRecurrence'; then
    note "a daily backup schedule already exists — skipping"
  else
    gcloud firestore backups schedules create --database="${DATABASE}" \
      --recurrence=daily --retention="${BACKUP_RETENTION}" --project="${PROJECT_ID}"
    note "daily backup schedule created (retention ${BACKUP_RETENTION})"
  fi
}

main() {
  banner
  # #3 ALERTING — channel first (its id wires into every policy).
  notification_channel
  idempotent_metric "${METRIC_DEAD}" \
    "Heimdall: a control-plane task hit the dead-letter bucket (cp_boot drain dead>0)" \
    "${METRIC_DEAD_FILTER}"
  idempotent_metric "${METRIC_TICK}" \
    "Heimdall: per-minute tick error / drain error / dispatch refusal" \
    "${METRIC_TICK_FILTER}"
  idempotent_policy "Heimdall dead-letter task" \
    "dead tasks > 0 in 5 min" "${POLICY_DEAD_FILTER}"
  idempotent_policy "Heimdall tick error" \
    "tick/drain errors > 0 in 5 min" "${POLICY_TICK_FILTER}"
  idempotent_policy "Heimdall maintainer job failed" \
    "maintainer job failed executions > 0 in 5 min" "${POLICY_JOB_FILTER}"
  # #5 DATA LIFECYCLE.
  firestore_ttl
  firestore_pitr
  firestore_backup

  step "DONE"
  if [ "$DRY" -eq 1 ]; then
    note "plan complete — re-run without --dry-run (under an authenticated gcloud) to apply"
  else
    note "ops hardening applied — verify: gcloud logging metrics list; gcloud alpha monitoring policies list; gcloud firestore fields ttls list"
  fi
}

main
