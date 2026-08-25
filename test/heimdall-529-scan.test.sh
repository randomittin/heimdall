#!/usr/bin/env bash
# test/heimdall-529-scan.test.sh — fixture-only coverage for bin/heimdall-529-scan,
# the READ-ONLY transcript scanner that turns Claude Code's own stable
# isApiErrorMessage/apiErrorStatus/error markers (see the tool's own header, and
# docs/analysis/2026-08-25-transcript-529-detection.md for how that marker was
# found and proven stable — 31/31 false positives from naive text search over
# the same corpus where the marker-based approach found the 2 real events) into
# pressure_control.py-compatible "overloaded_error"/"connection_reset" events.
#
# HERMETIC: every fixture is a hand-built .jsonl file under a throwaway mktemp
# work dir this script creates and reclaims itself — NEVER the operator's real
# ~/.claude/projects transcripts.
#
# FALSIFIABLE claims proven:
#   (1)  a transcript with no overload records yields count 0, exit 0.
#   (2)  a malformed JSON line is counted, never crashes the scan.
#   (3)  isApiErrorMessage+server_error+apiErrorStatus>=500 -> "overloaded_error".
#   (4)  isApiErrorMessage+server_error+apiErrorStatus=null -> "connection_reset".
#   (5)  rate_limit(429) and oauth_org_not_allowed(403) are NEVER counted —
#        counting them would corrupt the AIMD controller's pressure signal.
#   (6)  window/--since bounding is a REAL filter on the record's own timestamp,
#        not decoration: a stale record is excluded by a tight window and
#        included once --since is widened to cover it.
#   (7)  a missing transcripts directory fails open (count 0, exit 0).
#   (8)  an unreadable file is skipped and counted, never fatal.
#   (9)  a file whose mtime predates the cutoff is skipped WITHOUT being opened
#        (files_scanned stays 0) — proves work is bounded by file mtime, not
#        "scan everything, filter after" (the brief's explicit bounded-work ask).
#   (10) --strict turns a rejected --since into exit 2 with a message; without
#        --strict the same call is a silent no-op at exit 0 (never-fails).
#   (11) `where` is non-empty and deterministic for a given --repo.
#   (12) --json output is always valid, parseable JSON, even for an empty result.
#   (13) HMD_529_SCAN_WINDOW_SECS is a real default, not just documented.
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SELF_DIR/.." && pwd)"
CLI="$REPO/bin/heimdall-529-scan"

command -v jq >/dev/null 2>&1 || { echo "FATAL: jq required" >&2; exit 2; }
[ -x "$CLI" ] || { echo "FATAL: $CLI not executable" >&2; exit 2; }

PASS=0; FAIL=0
ok()  { printf '  \033[32mPASS\033[0m %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAIL=$((FAIL+1)); }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/hmd-529-scan-test.XXXXXX")"
trap 'chmod -R u+w "$WORK" 2>/dev/null || true; rm -rf "$WORK"' EXIT

case_dir() { local d="$WORK/case-$1"; mkdir -p "$d"; printf '%s' "$d"; }
now_ts()   { python3 -c "from datetime import datetime, timezone; print(datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%S.%f')[:-3]+'Z')"; }
scan_json() { python3 "$CLI" scan --dir "$1" --json "${@:2}"; }

echo "heimdall-529-scan harness"
echo "--------------------------------------------------------------------"

# ── 1. no overload records -> zero, exit 0 ──────────────────────────────────
D="$(case_dir 1)"; NOW="$(now_ts)"
cat > "$D/session.jsonl" <<EOF
{"type":"user","sessionId":"s1","timestamp":"$NOW","message":{"role":"user","content":"hi"}}
{"type":"assistant","sessionId":"s1","timestamp":"$NOW","message":{"role":"assistant","content":"hello"}}
EOF
out="$(scan_json "$D")"; rc=$?
count="$(printf '%s' "$out" | jq -r '.count')"
[ "$rc" -eq 0 ] && [ "$count" = "0" ] && ok "1. transcript with no overload records -> count 0, exit 0" \
  || bad "1. rc=$rc count='$count' out=$out"

# ── 2. malformed line does not crash the scan ───────────────────────────────
D="$(case_dir 2)"; NOW="$(now_ts)"
cat > "$D/session.jsonl" <<EOF
{"type":"user","sessionId":"s2","timestamp":"$NOW","message":{"role":"user","content":"hi"}}
this is not json {{{
{"type":"assistant","sessionId":"s2","timestamp":"$NOW","message":{"role":"assistant","content":"ok"}}
EOF
out="$(scan_json "$D" 2>"$D/err.log")"; rc=$?
malformed="$(printf '%s' "$out" | jq -r '.lines_malformed')"
[ "$rc" -eq 0 ] && [ "$malformed" -ge 1 ] && [ -z "$(grep -i traceback "$D/err.log")" ] \
  && ok "2. malformed JSON line -> counted, no crash/traceback, exit 0" \
  || bad "2. rc=$rc malformed='$malformed' err='$(cat "$D/err.log")'"

# ── 3. real 529 -> overloaded_error ──────────────────────────────────────────
D="$(case_dir 3)"; NOW="$(now_ts)"
cat > "$D/session.jsonl" <<EOF
{"type":"assistant","model":"<synthetic>","isApiErrorMessage":true,"apiErrorStatus":529,"error":"server_error","sessionId":"s3","requestId":"r1","timestamp":"$NOW"}
EOF
out="$(scan_json "$D")"
count="$(printf '%s' "$out" | jq -r '.count')"
kind="$(printf '%s' "$out" | jq -r '.events[0].kind')"
[ "$count" = "1" ] && [ "$kind" = "overloaded_error" ] && ok "3. isApiErrorMessage+server_error+status=529 -> overloaded_error" \
  || bad "3. count='$count' kind='$kind'"

# ── 4. null-status server_error -> connection_reset ──────────────────────────
D="$(case_dir 4)"; NOW="$(now_ts)"
cat > "$D/session.jsonl" <<EOF
{"type":"assistant","model":"<synthetic>","isApiErrorMessage":true,"apiErrorStatus":null,"error":"server_error","sessionId":"s4","requestId":"r2","timestamp":"$NOW"}
EOF
out="$(scan_json "$D")"
count="$(printf '%s' "$out" | jq -r '.count')"
kind="$(printf '%s' "$out" | jq -r '.events[0].kind')"
[ "$count" = "1" ] && [ "$kind" = "connection_reset" ] && ok "4. isApiErrorMessage+server_error+status=null -> connection_reset" \
  || bad "4. count='$count' kind='$kind'"

# ── 5. rate_limit(429) and oauth_org_not_allowed(403) are excluded ──────────
D="$(case_dir 5)"; NOW="$(now_ts)"
cat > "$D/session.jsonl" <<EOF
{"type":"assistant","model":"<synthetic>","isApiErrorMessage":true,"apiErrorStatus":429,"error":"rate_limit","sessionId":"s5","requestId":"r3","timestamp":"$NOW"}
{"type":"assistant","model":"<synthetic>","isApiErrorMessage":true,"apiErrorStatus":403,"error":"oauth_org_not_allowed","sessionId":"s5","requestId":"r4","timestamp":"$NOW"}
EOF
out="$(scan_json "$D")"
count="$(printf '%s' "$out" | jq -r '.count')"
[ "$count" = "0" ] && ok "5. rate_limit/429 and oauth_org_not_allowed/403 are NOT counted as overload events" \
  || bad "5. count='$count' (expected 0) out=$out"

# ── 6. window/since bounding is a real record-timestamp filter ──────────────
D="$(case_dir 6)"
cat > "$D/session.jsonl" <<EOF
{"type":"assistant","model":"<synthetic>","isApiErrorMessage":true,"apiErrorStatus":529,"error":"server_error","sessionId":"s6","requestId":"r5","timestamp":"2020-01-01T00:00:00.000Z"}
EOF
count_narrow="$(python3 "$CLI" scan --dir "$D" --window-secs 60 --json | jq -r '.count')"
count_wide="$(python3 "$CLI" scan --dir "$D" --since 2019-01-01T00:00:00Z --json | jq -r '.count')"
[ "$count_narrow" = "0" ] && [ "$count_wide" = "1" ] && ok "6. a 2020 record is excluded by a 60s window, included by --since 2019" \
  || bad "6. narrow='$count_narrow' wide='$count_wide'"

# ── 7. missing transcripts directory -> zero, exit 0 (fail open) ────────────
out="$(scan_json "$WORK/does-not-exist-529")"; rc=$?
count="$(printf '%s' "$out" | jq -r '.count')"
[ "$rc" -eq 0 ] && [ "$count" = "0" ] && ok "7. missing --dir -> count 0, exit 0 (never crashes on absent transcripts dir)" \
  || bad "7. rc=$rc count='$count'"

# ── 8. unreadable file is skipped, not fatal ─────────────────────────────────
D="$(case_dir 8)"; NOW="$(now_ts)"
cat > "$D/session.jsonl" <<EOF
{"type":"assistant","model":"<synthetic>","isApiErrorMessage":true,"apiErrorStatus":529,"error":"server_error","sessionId":"s8","requestId":"r6","timestamp":"$NOW"}
EOF
chmod 000 "$D/session.jsonl"
if [ "$(id -u)" = "0" ]; then
  ok "8. skipped (running as root, chmod 000 has no effect to test against)"
else
  out="$(scan_json "$D" 2>"$D/err.log")"; rc=$?
  unreadable="$(printf '%s' "$out" | jq -r '.files_unreadable')"
  count="$(printf '%s' "$out" | jq -r '.count')"
  [ "$rc" -eq 0 ] && [ "$unreadable" -ge 1 ] && [ "$count" = "0" ] \
    && ok "8. an unreadable file is skipped and counted, never a crash" \
    || bad "8. rc=$rc unreadable='$unreadable' count='$count'"
fi

# ── 9. stale file (by mtime) is skipped WITHOUT being opened (bounded work) ─
D="$(case_dir 9)"
cat > "$D/session.jsonl" <<EOF
{"type":"assistant","model":"<synthetic>","isApiErrorMessage":true,"apiErrorStatus":529,"error":"server_error","sessionId":"s9","requestId":"r7","timestamp":"$(now_ts)"}
EOF
python3 -c "import os; old=946684800.0; os.utime('$D/session.jsonl', (old, old))"  # 2000-01-01
out="$(python3 "$CLI" scan --dir "$D" --window-secs 60 --json)"
skipped="$(printf '%s' "$out" | jq -r '.files_skipped_stale')"
scanned="$(printf '%s' "$out" | jq -r '.files_scanned')"
count="$(printf '%s' "$out" | jq -r '.count')"
[ "$skipped" = "1" ] && [ "$scanned" = "0" ] && [ "$count" = "0" ] \
  && ok "9. a file whose mtime predates the cutoff is skipped unopened (files_scanned stays 0)" \
  || bad "9. skipped='$skipped' scanned='$scanned' count='$count'"

# ── 10. --strict: bad --since exits 2 with a message; without it, silent 0 ──
D="$(case_dir 10)"
out="$(python3 "$CLI" scan --dir "$WORK" --since not-a-date 2>"$D/err-nonstrict.log")"; rc_nonstrict=$?
python3 "$CLI" --strict scan --dir "$WORK" --since not-a-date >"$D/out-strict.log" 2>"$D/err-strict.log"
rc_strict=$?
[ "$rc_nonstrict" -eq 0 ] && [ -z "$out" ] && [ "$rc_strict" -eq 2 ] && [ -s "$D/err-strict.log" ] \
  && ok "10. bad --since: exit 0 + silent by default, exit 2 + stderr message under --strict" \
  || bad "10. rc_nonstrict=$rc_nonstrict out='$out' rc_strict=$rc_strict err='$(cat "$D/err-strict.log")'"

# ── 11. `where` is non-empty and deterministic for a given --repo ───────────
w1="$(python3 "$CLI" --repo "$REPO" where)"
w2="$(python3 "$CLI" --repo "$REPO" where)"
[ -n "$w1" ] && [ "$w1" = "$w2" ] && ok "11. where is non-empty and deterministic for the same --repo ($w1)" \
  || bad "11. w1='$w1' w2='$w2'"

# ── 12. --json output is always valid, parseable JSON ────────────────────────
D="$(case_dir 12)"
out="$(scan_json "$D")"
if printf '%s' "$out" | python3 -c "import json,sys; json.load(sys.stdin)" 2>"$D/err.log"; then
  ok "12. --json output is always valid JSON, even for an empty result"
else
  bad "12. json.load failed: $(cat "$D/err.log")"
fi

# ── 13. HMD_529_SCAN_WINDOW_SECS is a real default, not just documented ─────
D="$(case_dir 13)"
cat > "$D/session.jsonl" <<EOF
{"type":"assistant","model":"<synthetic>","isApiErrorMessage":true,"apiErrorStatus":529,"error":"server_error","sessionId":"s13","requestId":"r8","timestamp":"2020-01-01T00:00:00.000Z"}
EOF
count_env="$(HMD_529_SCAN_WINDOW_SECS=60 python3 "$CLI" scan --dir "$D" --json | jq -r '.count')"
[ "$count_env" = "0" ] && ok "13. HMD_529_SCAN_WINDOW_SECS=60 (no --window-secs flag) still excludes the 2020 record" \
  || bad "13. count_env='$count_env' (expected 0)"

echo "--------------------------------------------------------------------"
printf 'heimdall-529-scan: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
