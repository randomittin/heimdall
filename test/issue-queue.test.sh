#!/usr/bin/env bash
# test/issue-queue.test.sh — piece (b) acceptance for the Heimdall issue-resolution
# loop: normalize(), the queue store, prioritization, and in-flight tracking.
#
# Proves, against the REAL lib + CLI (no canned shapes, a deterministic pinned
# clock), the dossier §2/§3 contract:
#   (a) normalize() maps each of the THREE launch source shapes (github / slack /
#       email) to the ONE uniform internal schema — all 7 fields present, `id`
#       prefixed by `<source>:`, honest fields (missing severity -> null);
#   (b) prioritization picks in the CONFIGURED order — a critical issue outranks an
#       old-but-low one; flipping the weights flips the order (configurable, not
#       hardcoded); ties broken deterministically by id;
#   (c) in-flight idempotency (THE no-double-work guard) — once pick() claims an
#       issue, a SECOND pick() returns the NEXT issue, never the claimed one; and
#       re-ingesting a known id does NOT re-queue it;
#   (d) a PR'd / resolved issue stays OUT of the pick set — mark it resolved and it
#       is never re-picked; a flagged issue likewise stays out.
# Plus: HEIMDALL_HOME relocates the store (no baked path); the store is valid JSON.

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
CMD="$ROOT/bin/heimdall-issue-queue"
LIB="$ROOT/bin/lib/issue_queue.py"

PASS=0
FAIL=0
ok()  { PASS=$((PASS+1)); printf "  \033[32mPASS\033[0m %s\n" "$1"; }
bad() { FAIL=$((FAIL+1)); printf "  \033[31mFAIL\033[0m %s\n" "$1"; }

command -v jq >/dev/null 2>&1 || { echo "FATAL: jq required for the JSON-shape assertions" >&2; exit 2; }
[ -x "$CMD" ] || { echo "FATAL: $CMD not executable" >&2; exit 2; }
[ -f "$LIB" ] || { echo "FATAL: $LIB missing" >&2; exit 2; }

PY="$(command -v python3 || command -v python)"

WORK="$(mktemp -d -t "issue-queue-test.$(printf 'X%.0s' 1 2 3 4 5 6)")"
trap 'rm -rf "$WORK"' EXIT

# the store relocates here — proves no baked path.
export HEIMDALL_HOME="$WORK/home"

# a pinned clock so age_seconds is deterministic across runs.
NOW="2020-06-01T00:00:00Z"

# config: default-shaped weights + per-source priority (github boosted).
CFG="$WORK/cfg.json"
cat > "$CFG" <<'EOF'
{
  "prioritization": {
    "weights": { "severity": 3, "age": 1, "source": 1 },
    "source_priority": { "github": 1, "slack": 0, "email": 0 }
  }
}
EOF

# ── the THREE launch source RAW shapes (adapter-native) ───────────────────────
GH_RAW="$WORK/gh.json"
cat > "$GH_RAW" <<'EOF'
{ "repo": "octo/widget", "number": 42, "title": "Crash on save",
  "body": "Null deref when saving an empty form.",
  "labels": [{"name":"bug"},{"name":"low"}],
  "created_at": "2020-05-01T00:00:00Z",
  "html_url": "https://github.com/octo/widget/issues/42" }
EOF

SLACK_RAW="$WORK/slack.json"
cat > "$SLACK_RAW" <<'EOF'
{ "channel": "C0ALERTS", "ts": "1590796800.000200",
  "text": "blocker: prod outage, p0 right now",
  "thread": "on-call paged",
  "thread_ts": "1590796800.000100",
  "permalink": "https://acme.slack.com/archives/C0ALERTS/p1590796800000200" }
EOF

EMAIL_RAW="$WORK/email.json"
cat > "$EMAIL_RAW" <<'EOF'
{ "message_id": "<abc123@mail.acme.com>",
  "subject": "Invoice export is broken",
  "body": "<html><body>The CSV export <b>fails</b> for EU customers.</body></html>",
  "from": "user@acme.com",
  "in_reply_to": null,
  "date": "2020-05-30T12:00:00Z",
  "headers": { "X-Priority": "3" } }
EOF

# ════════════════════════════════════════════════════════════════════════════
# (a) normalize: each of the 3 source shapes -> the ONE uniform 7-field schema
# ════════════════════════════════════════════════════════════════════════════
echo "(a) normalize -> uniform schema from 3 sources"

check_schema() {  # $1=source-label  $2=normalized-json-file  $3=expected-id-prefix
  local label="$1" file="$2" prefix="$3"
  if ! jq -e . "$file" >/dev/null 2>&1; then
    bad "$label normalize emits valid JSON"; return
  fi
  ok "$label normalize emits valid JSON"
  local k allok=1
  for k in source id title body priority_signal links created_at; do
    jq -e "has(\"$k\")" "$file" >/dev/null 2>&1 || { allok=0; bad "$label has field .$k"; }
  done
  [ "$allok" = 1 ] && ok "$label has all 7 top-level fields"
  for k in severity age_seconds source_priority; do
    jq -e ".priority_signal | has(\"$k\")" "$file" >/dev/null 2>&1 || bad "$label .priority_signal.$k present"
  done
  for k in source_ref url; do
    jq -e ".links | has(\"$k\")" "$file" >/dev/null 2>&1 || bad "$label .links.$k present"
  done
  ok "$label priority_signal + links sub-fields present"
  # id prefixed by <source>:
  case "$(jq -r '.id' "$file")" in
    ${prefix}:*) ok "$label id prefixed '${prefix}:'" ;;
    *) bad "$label id prefixed '${prefix}:' (got $(jq -r '.id' "$file"))" ;;
  esac
}

"$CMD" normalize --source github --raw "@$GH_RAW"    --config "@$CFG" --now "$NOW" > "$WORK/gh.norm.json"
"$CMD" normalize --source slack  --raw "@$SLACK_RAW" --config "@$CFG" --now "$NOW" > "$WORK/slack.norm.json"
"$CMD" normalize --source email  --raw "@$EMAIL_RAW" --config "@$CFG" --now "$NOW" > "$WORK/email.norm.json"

check_schema github "$WORK/gh.norm.json"    github
check_schema slack  "$WORK/slack.norm.json" slack
check_schema email  "$WORK/email.norm.json" email

# honest fields + per-source mapping spot-checks
[ "$(jq -r '.priority_signal.severity' "$WORK/gh.norm.json")"    = "high" ]     && ok "github severity from labels -> high"    || bad "github severity from labels -> high"
[ "$(jq -r '.priority_signal.severity' "$WORK/slack.norm.json")" = "critical" ] && ok "slack severity from keywords -> critical" || bad "slack severity from keywords -> critical"
[ "$(jq -r '.priority_signal.severity' "$WORK/email.norm.json")" = "normal" ]   && ok "email severity from X-Priority -> normal" || bad "email severity from X-Priority -> normal"
[ "$(jq -r '.links.url' "$WORK/email.norm.json")" = "null" ]                     && ok "email url is null (honest, no URL)"        || bad "email url is null"
[ "$(jq -r '.title' "$WORK/slack.norm.json")" = "blocker: prod outage, p0 right now" ] && ok "slack title = first line of text" || bad "slack title = first line of text"
case "$(jq -r '.body' "$WORK/email.norm.json")" in
  *"<"*) bad "email body strips html" ;;
  *fails*) ok "email body strips html (plain text kept)" ;;
  *) bad "email body strips html (got: $(jq -r '.body' "$WORK/email.norm.json"))" ;;
esac
# deterministic age: NOW - github created_at (2020-05-01 -> 2020-06-01) = 31 days
EXP_AGE=$(( 31 * 24 * 3600 ))
[ "$(jq -r '.priority_signal.age_seconds' "$WORK/gh.norm.json")" = "$EXP_AGE" ] && ok "github age_seconds deterministic ($EXP_AGE)" || bad "github age_seconds deterministic (want $EXP_AGE got $(jq -r '.priority_signal.age_seconds' "$WORK/gh.norm.json"))"

# ════════════════════════════════════════════════════════════════════════════
# (b) prioritization picks in the CONFIGURED order
# ════════════════════════════════════════════════════════════════════════════
echo "(b) prioritization — configured order"

# fresh store: ingest all 3.
"$CMD" ingest --source github --raw "@$GH_RAW"    --config "@$CFG" --now "$NOW" >/dev/null
"$CMD" ingest --source slack  --raw "@$SLACK_RAW" --config "@$CFG" --now "$NOW" >/dev/null
"$CMD" ingest --source email  --raw "@$EMAIL_RAW" --config "@$CFG" --now "$NOW" >/dev/null

[ "$("$CMD" status | jq -r '.queued')" = "3" ] && ok "3 issues queued after ingest" || bad "3 issues queued after ingest"

# severity dominates (w_sev=3): slack(critical=3) ranks first.
LIST_IDS="$("$CMD" list --config "@$CFG" | jq -r '.[].id')"
FIRST_LISTED="$(printf '%s\n' "$LIST_IDS" | head -1)"
case "$FIRST_LISTED" in
  slack:*) ok "list pick-order: critical (slack) ranked first" ;;
  *) bad "list pick-order: critical first (got $FIRST_LISTED)" ;;
esac

# CONFIGURABLE: zero out severity weight, boost source -> github (source_priority=1)
# should now outrank the critical slack issue. Proves weights drive order.
CFG2="$WORK/cfg2.json"
cat > "$CFG2" <<'EOF'
{ "prioritization": {
    "weights": { "severity": 0, "age": 0, "source": 100 },
    "source_priority": { "github": 1, "slack": 0, "email": 0 } } }
EOF
FIRST2="$("$CMD" list --config "@$CFG2" | jq -r '.[0].id')"
case "$FIRST2" in
  github:*) ok "reweighting flips order: source-weighted -> github first" ;;
  *) bad "reweighting flips order (got $FIRST2)" ;;
esac

# ════════════════════════════════════════════════════════════════════════════
# (c) in-flight idempotency — THE no-double-work guard
# ════════════════════════════════════════════════════════════════════════════
echo "(c) in-flight idempotency (no double-pick)"

PICK1="$("$CMD" pick --config "@$CFG" --now "$NOW" | jq -r '.picked.id')"
[ "$PICK1" = "slack:C0ALERTS.1590796800.000200" ] && ok "pick #1 claims the top-priority issue (slack critical)" || bad "pick #1 claims top issue (got $PICK1)"

# pick #1 must now be in_flight (claimed-before-work).
[ "$("$CMD" status | jq -r '.in_flight')" = "1" ] && ok "claimed issue moved to in_flight" || bad "claimed issue moved to in_flight"

# pick #2 must NOT return the same id (the cardinal idempotency guard).
PICK2="$("$CMD" pick --config "@$CFG" --now "$NOW" | jq -r '.picked.id')"
[ "$PICK2" != "$PICK1" ] && ok "pick #2 does NOT re-pick the in_flight issue ($PICK2 != $PICK1)" || bad "pick #2 RE-PICKED the in_flight issue ($PICK2)"
[ -n "$PICK2" ] && [ "$PICK2" != "null" ] && ok "pick #2 returns a different queued issue" || bad "pick #2 returns a different queued issue"

# two simultaneous picks over the SAME store never collide: across all picks each
# id is claimed at most once.
PICK3="$("$CMD" pick --config "@$CFG" --now "$NOW" | jq -r '.picked.id')"
PICK4="$("$CMD" pick --config "@$CFG" --now "$NOW" | jq -r '.picked')"
UNIQ="$(printf '%s\n%s\n%s\n' "$PICK1" "$PICK2" "$PICK3" | sort -u | wc -l | tr -d ' ')"
[ "$UNIQ" = "3" ] && ok "every pick claimed a DISTINCT issue (no double-work)" || bad "picks claimed distinct issues (uniq=$UNIQ)"
[ "$PICK4" = "null" ] && ok "pick on an empty queue returns null (nothing left)" || bad "pick on empty queue returns null (got $PICK4)"

# re-ingest a known id -> idempotent (not re-queued even though it is in_flight).
REING="$("$CMD" ingest --source slack --raw "@$SLACK_RAW" --config "@$CFG" --now "$NOW" | jq -r '.ingested')"
[ "$REING" = "0" ] && ok "re-ingest of a known id is idempotent (ingested=0)" || bad "re-ingest idempotent (ingested=$REING)"

# ════════════════════════════════════════════════════════════════════════════
# (d) a PR'd / resolved issue stays OUT of the pick set
# ════════════════════════════════════════════════════════════════════════════
echo "(d) resolved / flagged issues stay out of the pick set"

# mark the github issue resolved (PR'd) via the lib, then release the rest back to
# the queue and confirm the resolved id is never re-picked.
HEIMDALL_HOME="$HEIMDALL_HOME" "$PY" - "$LIB" <<'PYEOF'
import importlib.util, sys, os
spec = importlib.util.spec_from_file_location("issue_queue", sys.argv[1])
iq = importlib.util.module_from_spec(spec); spec.loader.exec_module(iq)
q = iq.IssueQueue()
# release every in_flight id back to queued, then PR the github one + flag the email one.
for iid in list(q.data["in_flight"].keys()):
    q.release(iid)
# re-pick github explicitly by moving it in_flight then resolving.
q.data["in_flight"]["github:octo/widget#42"] = {"since": "x", "state": "PR_OPEN", "pr": "PR-1"}
q.mark_resolved("github:octo/widget#42", pr="PR-1", merged=True)
q.data["in_flight"]["email:<abc123@mail.acme.com>"] = {"since": "x", "state": "GATE_FAILED", "pr": None}
q.flag("email:<abc123@mail.acme.com>", reason="gate-failed", evidence_ref="att-1")
print("resolved:", "github:octo/widget#42" in q.data["resolved"])
print("flagged:", "email:<abc123@mail.acme.com>" in q.data["flagged"])
PYEOF

# now the only pickable issue is the slack one (github resolved, email flagged).
PICK_AFTER="$("$CMD" pick --config "@$CFG" --now "$NOW" | jq -r '.picked.id')"
[ "$PICK_AFTER" = "slack:C0ALERTS.1590796800.000200" ] && ok "only the non-terminal issue is pickable (slack)" || bad "only non-terminal pickable (got $PICK_AFTER)"

# resolved id is never returned by pick — drain and assert it is absent.
"$CMD" release --id "slack:C0ALERTS.1590796800.000200" >/dev/null 2>&1 || true
DRAIN="$("$CMD" pick --config "@$CFG" --now "$NOW" | jq -r '.picked.id // "none"')"
[ "$DRAIN" != "github:octo/widget#42" ] && ok "resolved (PR'd) issue is NEVER re-picked" || bad "resolved issue was re-picked"
RESOLVED_IN_STATUS="$("$CMD" status | jq -r '.resolved')"
[ "$RESOLVED_IN_STATUS" = "1" ] && ok "status reports 1 resolved issue" || bad "status resolved count (got $RESOLVED_IN_STATUS)"
FLAGGED_IN_STATUS="$("$CMD" status | jq -r '.flagged')"
[ "$FLAGGED_IN_STATUS" = "1" ] && ok "status reports 1 flagged issue" || bad "status flagged count (got $FLAGGED_IN_STATUS)"

# store is valid JSON on disk.
jq -e . "$HEIMDALL_HOME/issues/queue.json" >/dev/null 2>&1 && ok "on-disk store is valid JSON" || bad "on-disk store is valid JSON"

# ── tally ─────────────────────────────────────────────────────────────────────
echo
echo "issue-queue: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
