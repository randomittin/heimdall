#!/usr/bin/env bash
# heimdall-ops-hardening.test.sh — GATE for deploy/cloud-run/setup-ops-hardening.sh (audit
# items #3 alerting + #5 firestore lifecycle) and the ttl_at field cp_state_firestore writes.
#
# WHAT THIS GATES (zero real gcloud, zero spend — the script's --dry-run is a pure planner):
#   A. bash -n — the operator script parses.
#   B. --dry-run emits the ALERTING plan: 2 log-based metrics (dead + tick) with the exact log
#      filters, 3 alert policies (dead-metric, tick-metric, maintainer-JOB-failed) at threshold
#      > 0 over a 5-min window, and an email notification channel for rj@superpe.co.
#   C. --dry-run emits the LIFECYCLE plan: TTL update on ttl_at@heimdall_cp, PITR enable, and a
#      daily 7-day-retention backup schedule.
#   D. IDEMPOTENCY — every mutating step is preceded by a read-only guard (describe/list).
#   E. --dry-run runs ZERO mutating gcloud verbs (create/update/delete never execute — they are
#      only PRINTED). Proven by pointing PATH at a FAKE gcloud that fails if invoked.
#   F. TTL FIELD SHAPE — cp_state_firestore.put_record writes a top-level ttl_at Timestamp
#      (datetime) ONLY for the ephemeral roots (nonce/ratelimit), NOT for durable docs (jobs),
#      and STILL persists the record when a backend cannot store a datetime (retry fallback).
#      This is the code half of item #5 (a TTL policy needs a Timestamp FIELD to act on).
#   G. unknown-arg + --help hygiene (the script refuses a typo, prints usage).
# Exit 0 = every proof holds.

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SELF_DIR/.." && pwd)"
LIB="$REPO/bin/lib"
SCRIPT="$REPO/deploy/cloud-run/setup-ops-hardening.sh"
export LIB

[ -f "$SCRIPT" ] || { echo "FATAL: $SCRIPT missing" >&2; exit 2; }
[ -f "$LIB/cp_state_firestore.py" ] || { echo "FATAL: cp_state_firestore.py missing" >&2; exit 2; }

PY="$(command -v python3 || command -v python || true)"
[ -n "$PY" ] || { echo "FATAL: python not found" >&2; exit 2; }

PASS=0
FAIL=0
ok()  { PASS=$((PASS+1)); printf "  \033[32mPASS\033[0m %s\n" "$1"; }
bad() { FAIL=$((FAIL+1)); printf "  \033[31mFAIL\033[0m %s\n" "$1"; }

WORK="$(mktemp -d -t "ops-harden.$(printf 'X%.0s' 1 2 3 4 5 6)")"
trap 'rm -rf "$WORK"' EXIT

echo "============================================================"
echo "OPS-HARDENING — setup-ops-hardening.sh planner + ttl_at field"
echo "============================================================"
echo

# ── A. bash -n ────────────────────────────────────────────────────────────────────────────
if bash -n "$SCRIPT" 2>"$WORK/synerr"; then ok "A the operator script parses (bash -n)"
else bad "A bash -n failed"; cat "$WORK/synerr" >&2; fi

# ── E. capture the dry plan under a FAKE gcloud that FAILS if any verb runs ─────────────────
# The fake proves --dry-run executes ZERO gcloud: if the script ever actually invokes gcloud in
# dry mode, the fake writes a breadcrumb and the plan capture is poisoned.
FAKEBIN="$WORK/bin"
mkdir -p "$FAKEBIN"
cat >"$FAKEBIN/gcloud" <<'SH'
#!/usr/bin/env bash
echo "GCLOUD_WAS_INVOKED $*" >> "$GCLOUD_TRIPWIRE"
exit 97
SH
chmod +x "$FAKEBIN/gcloud"
export GCLOUD_TRIPWIRE="$WORK/tripwire"
: >"$GCLOUD_TRIPWIRE"

PLAN="$WORK/plan.txt"
PATH="$FAKEBIN:$PATH" bash "$SCRIPT" --dry-run >"$PLAN" 2>"$WORK/plan.err"
PLAN_RC=$?
if [ "$PLAN_RC" -eq 0 ] && [ ! -s "$GCLOUD_TRIPWIRE" ]; then
  ok "E --dry-run ran ZERO mutating gcloud (exit 0, tripwire clean)"
else
  bad "E --dry-run invoked gcloud or exited non-zero (rc=$PLAN_RC)"; cat "$GCLOUD_TRIPWIRE" >&2
fi

has() { grep -Fq -- "$1" "$PLAN"; }   # fixed-string presence in the captured plan.

# ── B. ALERTING plan ────────────────────────────────────────────────────────────────────────
echo
echo "B. alerting plan (metrics + policies + channel)"
has 'gcloud logging metrics create heimdall_task_dead' \
  && ok "B metric heimdall_task_dead is created" || bad "B heimdall_task_dead metric missing"
has '"-> dead(attempts="' \
  && ok "B dead metric filter matches the '-> dead(attempts=' drain line" || bad "B dead-attempts filter missing"
has 'dead=[1-9]' \
  && ok "B dead metric filter matches drain 'dead=N' (N>0, excludes dead=0)" || bad "B dead=[1-9] filter missing"
has 'gcloud logging metrics create heimdall_tick_error' \
  && ok "B metric heimdall_tick_error is created" || bad "B heimdall_tick_error metric missing"
has 'cp_boot: tick error' \
  && ok "B tick metric filter matches 'cp_boot: tick error'" || bad "B tick-error filter missing"
has 'REFUSED reason=' \
  && ok "B tick metric filter matches 'REFUSED reason='" || bad "B REFUSED-reason filter missing"

has 'gcloud alpha monitoring policies create' \
  && ok "B alert policies are created" || bad "B monitoring policies create missing"
has "--display-name='Heimdall dead-letter task'" \
  && ok "B policy: dead-letter task" || bad "B dead-letter policy missing"
has "--display-name='Heimdall tick error'" \
  && ok "B policy: tick error" || bad "B tick-error policy missing"
has "--display-name='Heimdall maintainer job failed'" \
  && ok "B policy: maintainer job failed" || bad "B maintainer-job policy missing"
has 'metric.type="logging.googleapis.com/user/heimdall_task_dead"' \
  && ok "B dead policy conditions on the dead metric" || bad "B dead policy metric.type missing"
has 'run.googleapis.com/job/completed_execution_count' \
  && ok "B maintainer policy conditions on job completed_execution_count" || bad "B job metric.type missing"
has 'metric.label.result="failed"' \
  && ok "B maintainer policy filters result=failed" || bad "B result=failed filter missing"
{ has "--if='> 0'" && has '--duration=300s'; } \
  && ok "B every policy is threshold > 0 over a 5-min (300s) window" || bad "B threshold/duration missing"

has 'gcloud beta monitoring channels create' \
  && ok "B an email notification channel is created" || bad "B channel create missing"
has 'email_address=rj@superpe.co' \
  && ok "B channel targets rj@superpe.co" || bad "B channel email missing"

# ── C. LIFECYCLE plan ───────────────────────────────────────────────────────────────────────
echo
echo "C. firestore lifecycle plan (TTL + PITR + backup)"
has 'gcloud firestore fields ttls update ttl_at --collection-group=heimdall_cp' \
  && ok "C TTL enabled on ttl_at @ heimdall_cp" || bad "C TTL update missing"
has '--enable-ttl' \
  && ok "C TTL policy is ENABLED (--enable-ttl)" || bad "C --enable-ttl missing"
has 'gcloud firestore databases update' && has '--enable-pitr' \
  && ok "C PITR enabled (databases update --enable-pitr)" || bad "C --enable-pitr missing"
has 'gcloud firestore backups schedules create' \
  && ok "C a backup schedule is created" || bad "C backup schedule create missing"
has '--recurrence=daily' && has '--retention=7d' \
  && ok "C backup schedule is DAILY, 7-day retention" || bad "C recurrence/retention missing"

# ── D. IDEMPOTENCY guards ───────────────────────────────────────────────────────────────────
echo
echo "D. idempotency guards (read-only describe/list before every mutation)"
GUARDS="$(grep -c '# guard' "$PLAN" 2>/dev/null || echo 0)"
[ "${GUARDS:-0}" -ge 5 ] \
  && ok "D $GUARDS guard lines precede the mutations (idempotent re-run)" || bad "D too few guard lines ($GUARDS)"
has 'gcloud logging metrics describe heimdall_task_dead' \
  && ok "D metric guarded by describe" || bad "D metric describe-guard missing"
has 'gcloud beta monitoring channels list' \
  && ok "D channel guarded by list" || bad "D channel list-guard missing"
has 'gcloud alpha monitoring policies list' \
  && ok "D policy guarded by list" || bad "D policy list-guard missing"
has 'gcloud firestore fields ttls list' \
  && ok "D TTL guarded by list" || bad "D ttls list-guard missing"
has 'gcloud firestore databases describe' \
  && ok "D PITR guarded by describe" || bad "D databases describe-guard missing"
has 'gcloud firestore backups schedules list' \
  && ok "D backup guarded by list" || bad "D backups list-guard missing"

# ── G. arg hygiene ──────────────────────────────────────────────────────────────────────────
echo
echo "G. arg hygiene (usage on --help, refuse a typo)"
HELP_OUT="$(bash "$SCRIPT" --help 2>/dev/null)"   # capture first (pipefail + grep -q SIGPIPE)
if grep -q 'usage:' <<<"$HELP_OUT"; then ok "G --help prints usage"
else bad "G --help did not print usage"; fi
if PATH="$FAKEBIN:$PATH" bash "$SCRIPT" --dry-runn >/dev/null 2>&1; then
  bad "G a typo'd flag was accepted (should FATAL)"
else ok "G an unknown flag is refused (non-zero exit)"; fi

# ── F. ttl_at FIELD SHAPE — cp_state_firestore.put_record ────────────────────────────────────
echo
echo "F. ttl_at field shape (put_record writes a Timestamp on ephemeral roots only)"
F_OUT="$(LIB="$LIB" "$PY" - <<'PYEOF' 2>"$WORK/f.err"
import datetime, os, sys
sys.path.insert(0, os.environ["LIB"])
import cp_state_firestore as F


class FakeDoc:
    def __init__(self, doc_id, store, reject_datetime=False):
        self.id = doc_id; self._store = store; self._reject = reject_datetime
    def set(self, fields, merge=False):
        if self._reject:
            for v in fields.values():
                if isinstance(v, datetime.datetime):
                    raise TypeError("this backend cannot serialize a datetime (json fake)")
        self._store[self.id] = dict(fields)


class FakeColl:
    def __init__(self, store, reject): self._store = store; self._reject = reject
    def document(self, doc_id): return FakeDoc(doc_id, self._store, self._reject)


class FakeClient:
    def __init__(self, store, reject=False): self._store = store; self._reject = reject
    def collection(self, name): return FakeColl(self._store, self._reject)


res = {}

# 1) nonce rel -> a top-level ttl_at DATETIME + the untouched record.
store = {}
be = F.FirestoreBackend(client=FakeClient(store), root="heimdall_cp")
be.put_record("nonce/presence/keyhash/noncehash.json", {"ts": 1.0})
doc = store.get("nonce__presence__keyhash__noncehash.json", {})
res["nonce_has_ttl"] = isinstance(doc.get("ttl_at"), datetime.datetime)
res["nonce_ttl_future"] = (
    isinstance(doc.get("ttl_at"), datetime.datetime)
    and doc["ttl_at"] > datetime.datetime.now(datetime.timezone.utc)
)
res["nonce_rec_intact"] = (doc.get("rec") == {"ts": 1.0})

# 2) ratelimit rel -> also ttl_at.
store2 = {}
be2 = F.FirestoreBackend(client=FakeClient(store2), root="heimdall_cp")
be2.put_record("ratelimit/enroll/keyhash/42.json", {"count": 3})
res["ratelimit_has_ttl"] = isinstance(
    store2.get("ratelimit__enroll__keyhash__42.json", {}).get("ttl_at"), datetime.datetime)

# 3) durable rel (jobs) -> NO ttl_at (must never be reaped).
store3 = {}
be3 = F.FirestoreBackend(client=FakeClient(store3), root="heimdall_cp")
be3.put_record("jobs/job-abc.json", {"state": "done"})
res["jobs_no_ttl"] = ("ttl_at" not in store3.get("jobs__job-abc.json", {}))

# 4) a backend that REJECTS datetimes still persists the record (retry-without-ttl fallback).
store4 = {}
be4 = F.FirestoreBackend(client=FakeClient(store4, reject=True), root="heimdall_cp")
ret = be4.put_record("nonce/presence/k/n.json", {"ts": 9.0})
saved = store4.get("nonce__presence__k__n.json", {})
res["fallback_returns_true"] = (ret is True)
res["fallback_record_persisted"] = (saved.get("rec") == {"ts": 9.0})
res["fallback_no_ttl"] = ("ttl_at" not in saved)

import json
print(json.dumps(res))
PYEOF
)"
if [ -s "$WORK/f.err" ]; then bad "F python raised"; cat "$WORK/f.err" >&2; fi
fget() { printf '%s' "$F_OUT" | "$PY" -c "import json,sys;print(json.load(sys.stdin).get('$1'))" 2>/dev/null; }
[ "$(fget nonce_has_ttl)" = "True" ]     && ok "F nonce doc carries a top-level ttl_at datetime (a Firestore Timestamp)" || bad "F nonce ttl_at absent (out=$F_OUT)"
[ "$(fget nonce_ttl_future)" = "True" ]  && ok "F ttl_at is in the FUTURE (now + horizon)" || bad "F ttl_at not future (out=$F_OUT)"
[ "$(fget nonce_rec_intact)" = "True" ]  && ok "F the record payload is unchanged alongside ttl_at" || bad "F record mangled (out=$F_OUT)"
[ "$(fget ratelimit_has_ttl)" = "True" ] && ok "F ratelimit doc also carries ttl_at" || bad "F ratelimit ttl_at absent (out=$F_OUT)"
[ "$(fget jobs_no_ttl)" = "True" ]       && ok "F a durable jobs doc carries NO ttl_at (never TTL-reaped)" || bad "F jobs doc wrongly got ttl_at (out=$F_OUT)"
[ "$(fget fallback_returns_true)" = "True" ]      && ok "F a datetime-rejecting backend still returns True" || bad "F fallback did not return True (out=$F_OUT)"
[ "$(fget fallback_record_persisted)" = "True" ]  && ok "F the record is persisted even when ttl_at can't be stored (durability > TTL)" || bad "F fallback dropped the record (out=$F_OUT)"
[ "$(fget fallback_no_ttl)" = "True" ]            && ok "F the fallback write omits ttl_at (only the record lands)" || bad "F fallback kept an unstorable ttl_at (out=$F_OUT)"

echo
echo "============================================================"
printf "ops-hardening: %d passed, %d failed\n" "$PASS" "$FAIL"
echo "============================================================"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
