#!/usr/bin/env bash
# test/heimdall-telemetry.test.sh — acceptance test for the Pre-Merge Corpus (PMR)
# T0 telemetry: the `pmr_v1` emission (bin/lib/pmr_corpus.py), the `hmd telemetry`
# command set (bin/heimdall-telemetry-corpus + the bin/heimdall router case), the
# local outcome observer, and the hard privacy/brand-safety FALSIFIERS (spec
# heimdall-premerge-corpus-spec.md §1/§2/§3/§5.1).
#
# Every assertion is runnable against the REAL library + REAL CLI (no network, no
# ingest route — step 1 is emit-locally only). Sections:
#
#   (A) PMR EMITTED WITH EXACT T0 SHAPE — a projection of a real SI-2 attestation
#       record lands in the local spool with the exact pmr_v1 keys + ZERO source /
#       path leak (grep the emitted record: no path string, no source line).
#   (B) ZERO-CONTENT CARDINAL FALSIFIER — a real path / a source line planted into
#       the emission input -> emission BLOCKED + ALARMED, nothing written to spool.
#   (C) SECRET-SCAN-BEFORE-SEND — a credential planted into the emission input ->
#       BLOCKED before it can be queued to send, alarmed.
#   (D) OFF HONORED — `hmd telemetry off` -> a gate eval writes ZERO PMR.
#   (E) PURGE ROUND-TRIP — `hmd telemetry purge` empties the spool AND records a
#       deletion request keyed by team_id_hash (deletion actually deletes).
#   (F) CONSENT VERSION STAMPED — every emitted record carries the consent version.
#   (G) .gitignore IDEMPOTENCY — heimdall-team's public-repo team.json gitignore
#       append lands the block AT MOST ONCE even when team.json is TRACKED (the
#       private->public flip that `git check-ignore` misses).
#   (H) OUTCOME OBSERVER — the local pmr_outcome path records a merged sha + hunk
#       map client-side, detects a revert overlap, and only booleans/buckets leave.
#   (R) ROUTER — `hmd telemetry status` routes through bin/heimdall to the engine.
#
# Exit 0 = every executed assertion passed. Non-zero = a regression.

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
LIB="$ROOT/bin/lib/pmr_corpus.py"
CLI="$ROOT/bin/heimdall-telemetry-corpus"
HMD="$ROOT/bin/heimdall"
TEAM="$ROOT/bin/heimdall-team"

PY="$(command -v python3 || command -v python || true)"
[ -n "$PY" ] || { echo "FATAL: python not found" >&2; exit 2; }
[ -f "$LIB" ] || { echo "FATAL: $LIB missing" >&2; exit 2; }
[ -x "$CLI" ] || { echo "FATAL: $CLI not executable" >&2; exit 2; }

PASS=0
FAIL=0
ok()  { PASS=$((PASS+1)); printf "  \033[32mPASS\033[0m %s\n" "$1"; }
bad() { FAIL=$((FAIL+1)); printf "  \033[31mFAIL\033[0m %s\n" "$1"; }

WORK="$(mktemp -d -t "hmd-telemetry-test.$(printf 'q%.0s' 1 2 3 4 5 6)")"
trap 'rm -rf "$WORK"' EXIT

# spool file count for a given corpus home.
spool_count() { ls "$1/telemetry/pmr/spool"/*.json 2>/dev/null | wc -l | tr -d ' '; }

# A real, SI-2-shaped job that emits a CLEAN pmr (two source files, one a test).
clean_job() {
  cat <<'JSON'
{"attestation":{"claims":{"file_count":2,"unit_count":3,
  "files":[{"path":"src/api/users.js","lang":"js"},
           {"path":"test/users.test.js","lang":"js"}]},
  "reuse":{"units_reusing":1,"suspected_duplicates":[{"duplicates":"foo"}]},
  "risk":{"flags":[{"code":"low-reuse"}]}},
 "ids":{"team_id":"team-abc","repo":"acme/widgets"},
 "diff":{"loc_added":40,"loc_deleted":5,"hunks":4},
 "agent":{"tool":"claude-code","model_family":"claude","version":"opus-4.8"},
 "verify":{"gates_run":["secret-scan","oracle","reuse"],"verdict":"deny",
   "retry_count":1,"time_to_green_s":42,"mutants_run":6,"survived":0,
   "bloat_budget_delta":3},
 "human":{"merged":false,"overridden":false,"override_latency_s":0},
 "env":{"os_class":"darwin","ci":false,"hmd_version":"2.0.16"}}
JSON
}

printf "\n=== heimdall-telemetry (PMR T0 corpus) acceptance ===\n"

# ─────────────────────────────────────────────────────────────────────────────
# (A) PMR EMITTED WITH EXACT T0 SHAPE + ZERO source/path leak.
# ─────────────────────────────────────────────────────────────────────────────
printf "\n[A] pmr_v1 emitted with exact T0 shape + zero source/path\n"
export HEIMDALL_CORPUS_HOME="$WORK/A"
EMIT_A="$(clean_job | "$CLI" emit)"
if printf '%s' "$EMIT_A" | grep -q '"emitted": *true'; then
  ok "(A1) emit reports emitted=true"
else
  bad "(A1) emit did not report emitted=true: $EMIT_A"
fi
REC_A="$(ls "$HEIMDALL_CORPUS_HOME/telemetry/pmr/spool"/*.json 2>/dev/null | head -1)"
if [ -n "$REC_A" ] && [ "$(spool_count "$HEIMDALL_CORPUS_HOME")" = "1" ]; then
  ok "(A2) exactly one record queued to the local spool"
else
  bad "(A2) spool did not contain exactly one record"
fi
# EXACT T0 shape — every spec §1 key present, projection correct.
SHAPE_A="$("$PY" - "$REC_A" <<'PYEOF'
import json, sys
r = json.load(open(sys.argv[1]))
def has(d, path):
    for k in path.split("."):
        if not isinstance(d, dict) or k not in d:
            return False
        d = d[k]
    return True
req = ["schema","consent_version","ids.pmr_id","ids.team_id_hash","ids.repo_class_hash",
       "when.ts","when.tz_bucket","agent.haid_class.tool","agent.haid_class.model_family",
       "agent.haid_class.version","change.files_touched","change.loc_added",
       "change.loc_deleted","change.hunks","change.langs","change.complexity_delta",
       "change.dep_graph_touch","change.test_files_touched","verify.gates_run",
       "verify.verdict","verify.deny_reasons","verify.retry_count","verify.time_to_green_s",
       "verify.falsify.mutants_run","verify.falsify.survived","verify.reuse.dup_candidates",
       "verify.reuse.reused","verify.bloat_budget_delta","human.merged","human.overridden",
       "human.override_latency_s","env.os_class","env.ci","env.hmd_version"]
missing = [p for p in req if not has(r, p)]
checks = [
    r.get("schema") == "pmr_v1",
    r["change"]["files_touched"] == 2,
    r["change"]["langs"] == ["js"],
    r["change"]["test_files_touched"] == 1,
    r["verify"]["verdict"] == "deny",
    r["verify"]["deny_reasons"] == ["low-reuse"],
    r["verify"]["reuse"]["reused"] is True,
    r["verify"]["reuse"]["dup_candidates"] == 1,
]
print("OK" if (not missing and all(checks)) else "BAD missing=%s checks=%s" % (missing, checks))
PYEOF
)"
if [ "$SHAPE_A" = "OK" ]; then
  ok "(A3) record carries the EXACT pmr_v1 T0 shape + correct projection"
else
  bad "(A3) shape/projection wrong: $SHAPE_A"
fi
# ZERO source/path leak — the emitted bytes carry no path, no source symbol.
if grep -nE 'users|src/|test/|\.js|def |function |=>|/' "$REC_A" >/dev/null 2>&1; then
  bad "(A4) LEAK: emitted record contains a path/source token"
  grep -nE 'users|src/|test/|\.js|def |function |=>|/' "$REC_A" | head
else
  ok "(A4) zero source/path leak in the emitted record (grep clean)"
fi

# ─────────────────────────────────────────────────────────────────────────────
# (B) ZERO-CONTENT CARDINAL FALSIFIER — plant a path / source line -> BLOCKED.
# ─────────────────────────────────────────────────────────────────────────────
printf "\n[B] zero-content cardinal falsifier (planted path / source line)\n"
export HEIMDALL_CORPUS_HOME="$WORK/B"
"$CLI" status >/dev/null   # materialize the home
B_BEFORE="$(spool_count "$HEIMDALL_CORPUS_HOME")"
# a REAL PATH planted into agent.version.
PATH_JOB='{"attestation":{"claims":{"file_count":0,"files":[]}},"ids":{"team_id":"t","repo":"r"},"agent":{"tool":"claude-code","version":"/Users/rj/secret/app/config.py"},"verify":{"verdict":"pass"}}'
B1="$(printf '%s' "$PATH_JOB" | "$CLI" emit 2>"$WORK/B1.err")"
if printf '%s' "$B1" | grep -q 'zero-content-blocked' \
   && grep -q 'PMR-ALARM' "$WORK/B1.err"; then
  ok "(B1) planted REAL PATH -> emission blocked + alarmed"
else
  bad "(B1) planted path was not blocked+alarmed: $B1 / $(cat "$WORK/B1.err")"
fi
# a SOURCE LINE planted into a deny_reason.
SRC_JOB='{"attestation":{"claims":{"file_count":0,"files":[]}},"ids":{"team_id":"t","repo":"r"},"verify":{"verdict":"deny","deny_reasons":["const x = (a, b) => { return a + b; }"]}}'
B2="$(printf '%s' "$SRC_JOB" | "$CLI" emit 2>"$WORK/B2.err")"
if printf '%s' "$B2" | grep -q 'zero-content-blocked' \
   && grep -q 'PMR-ALARM' "$WORK/B2.err"; then
  ok "(B2) planted SOURCE LINE -> emission blocked + alarmed"
else
  bad "(B2) planted source line was not blocked+alarmed: $B2"
fi
B_AFTER="$(spool_count "$HEIMDALL_CORPUS_HOME")"
if [ "$B_BEFORE" = "$B_AFTER" ]; then
  ok "(B3) blocked emissions wrote NOTHING to the spool (before=$B_BEFORE after=$B_AFTER)"
else
  bad "(B3) a blocked emission leaked into the spool (before=$B_BEFORE after=$B_AFTER)"
fi
if [ -s "$HEIMDALL_CORPUS_HOME/telemetry/pmr/alarms.ndjson" ]; then
  ok "(B4) a redacted alarm audit-trail was recorded"
else
  bad "(B4) no alarm audit-trail recorded"
fi

# ─────────────────────────────────────────────────────────────────────────────
# (C) SECRET-SCAN-BEFORE-SEND — plant a secret -> BLOCKED before queueing.
# ─────────────────────────────────────────────────────────────────────────────
printf "\n[C] secret-scan-before-send (planted credential)\n"
export HEIMDALL_CORPUS_HOME="$WORK/C"
"$CLI" status >/dev/null
C_BEFORE="$(spool_count "$HEIMDALL_CORPUS_HOME")"
# a GitHub PAT shape planted into agent.version (a single token — passes the
# zero-content check, so ONLY the secret-scan layer can catch it).
#
# ASSEMBLED AT RUNTIME (fixture-secret-convention case 2: gate-proof token). The
# scanner under test keys off ghp_[A-Za-z0-9]{36} (bin/lib/telemetry.py
# _SECRET_PATTERNS), so the value MUST match that shape when (C1) runs — but it
# must NOT exist as a contiguous literal in this file, or a working-tree gitleaks
# scan flags the fixture itself. Each fragment below is individually inert; only
# the concatenation is detector-shaped. Same pattern as test/selfscan.test.sh.
_GP_PRE="ghp_"; _GP_A="0123456789012345678"; _GP_B="90123456789012345"
PLANT_TOK="${_GP_PRE}${_GP_A}${_GP_B}"   # ghp_ + 36 chars, built here, never stored
SEC_JOB_TMPL='{"attestation":{"claims":{"file_count":0,"files":[]}},"ids":{"team_id":"t","repo":"r"},"agent":{"tool":"cursor","version":"@PLANT_TOK@"},"verify":{"verdict":"pass"}}'
SEC_JOB="${SEC_JOB_TMPL/@PLANT_TOK@/$PLANT_TOK}"
C1="$(printf '%s' "$SEC_JOB" | "$CLI" emit 2>"$WORK/C1.err")"
C_AFTER="$(spool_count "$HEIMDALL_CORPUS_HOME")"
if printf '%s' "$C1" | grep -q 'secret-detected-blocked' \
   && grep -q 'PMR-ALARM' "$WORK/C1.err" \
   && [ "$C_BEFORE" = "$C_AFTER" ]; then
  ok "(C1) planted SECRET -> blocked before queueing + alarmed, nothing written"
else
  bad "(C1) secret was not blocked before send: $C1 (before=$C_BEFORE after=$C_AFTER)"
fi

# ─────────────────────────────────────────────────────────────────────────────
# (D) OFF HONORED — off -> a gate eval writes ZERO PMR.
# ─────────────────────────────────────────────────────────────────────────────
printf "\n[D] off fully honored (zero emission when off)\n"
export HEIMDALL_CORPUS_HOME="$WORK/D"
"$CLI" off >/dev/null
D_BEFORE="$(spool_count "$HEIMDALL_CORPUS_HOME")"
D1="$(clean_job | "$CLI" emit)"
D_AFTER="$(spool_count "$HEIMDALL_CORPUS_HOME")"
if printf '%s' "$D1" | grep -q '"reason": *"disabled"' && [ "$D_BEFORE" = "$D_AFTER" ]; then
  ok "(D1) consent off -> emit is a no-op, ZERO PMR written"
else
  bad "(D1) off was not honored: $D1 (before=$D_BEFORE after=$D_AFTER)"
fi
# the env kill-switch is honored too.
D2="$(HEIMDALL_TELEMETRY=off bash -c "$(printf 'clean_job(){ cat <<J\n%s\nJ\n}; ' "$(clean_job)")" 2>/dev/null; clean_job | HEIMDALL_TELEMETRY=off "$CLI" emit)"
if printf '%s' "$D2" | grep -q '"reason": *"disabled"'; then
  ok "(D2) HEIMDALL_TELEMETRY=off env kill-switch honored"
else
  bad "(D2) env kill-switch not honored: $D2"
fi

# ─────────────────────────────────────────────────────────────────────────────
# (E) PURGE ROUND-TRIP — spool emptied + deletion request keyed by team_id_hash.
# ─────────────────────────────────────────────────────────────────────────────
printf "\n[E] purge round-trip (deletion actually deletes)\n"
export HEIMDALL_CORPUS_HOME="$WORK/E"
"$CLI" on >/dev/null
clean_job | "$CLI" emit >/dev/null
clean_job | "$CLI" emit >/dev/null
E_MID="$(spool_count "$HEIMDALL_CORPUS_HOME")"
PURGE="$("$CLI" purge --team-id team-abc)"
E_AFTER="$(spool_count "$HEIMDALL_CORPUS_HOME")"
DEL_DIR="$HEIMDALL_CORPUS_HOME/telemetry/pmr/deletions"
DEL_N="$(ls "$DEL_DIR"/*.json 2>/dev/null | wc -l | tr -d ' ')"
# the deletion request's team_id_hash must equal team_id_hash("team-abc").
EXPECT_TIH="$("$PY" -c "import sys;sys.path.insert(0,'$ROOT/bin/lib');import pmr_corpus as p;print(p.team_id_hash('team-abc'))")"
GOT_TIH="$("$PY" -c "import json,glob;print(json.load(open(glob.glob('$DEL_DIR/*.json')[0]))['team_id_hash'])" 2>/dev/null)"
if [ "$E_MID" = "2" ] && [ "$E_AFTER" = "0" ] && [ "$DEL_N" -ge 1 ] \
   && [ -n "$EXPECT_TIH" ] && [ "$EXPECT_TIH" = "$GOT_TIH" ]; then
  ok "(E1) purge emptied the spool (2->0) + recorded a deletion keyed by team_id_hash"
else
  bad "(E1) purge round-trip failed: mid=$E_MID after=$E_AFTER del=$DEL_N tih=$GOT_TIH want=$EXPECT_TIH"
fi

# ─────────────────────────────────────────────────────────────────────────────
# (F) CONSENT VERSION STAMPED on every emitted record.
# ─────────────────────────────────────────────────────────────────────────────
printf "\n[F] consent version stamped on every record\n"
export HEIMDALL_CORPUS_HOME="$WORK/F"
clean_job | "$CLI" emit >/dev/null
CV_CODE="$("$PY" -c "import sys;sys.path.insert(0,'$ROOT/bin/lib');import pmr_corpus as p;print(p.CONSENT_VERSION)")"
REC_F="$(ls "$HEIMDALL_CORPUS_HOME/telemetry/pmr/spool"/*.json | head -1)"
CV_REC="$("$PY" -c "import json,sys;print(json.load(open(sys.argv[1]))['consent_version'])" "$REC_F")"
if [ -n "$CV_CODE" ] && [ "$CV_CODE" = "$CV_REC" ]; then
  ok "(F1) record.consent_version == CONSENT_VERSION ($CV_CODE)"
else
  bad "(F1) consent version not stamped: code=$CV_CODE rec=$CV_REC"
fi

# ─────────────────────────────────────────────────────────────────────────────
# (G) .gitignore IDEMPOTENCY — the private->public flip that check-ignore misses.
# ─────────────────────────────────────────────────────────────────────────────
printf "\n[G] .gitignore idempotency (tracked team.json, public flip)\n"
[ -x "$TEAM" ] || { echo "FATAL: $TEAM not executable" >&2; exit 2; }
GIREPO="$WORK/gi-repo"
mkdir -p "$GIREPO/.heimdall"
( cd "$GIREPO" \
  && git init -q \
  && git config user.email t@t && git config user.name t \
  && printf '{"team_secret":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"}\n' > .heimdall/team.json \
  && git add -f .heimdall/team.json \
  && git commit -qm init )
# team.json is now TRACKED. Run the public-repo path 3x; the block must land ONCE.
( cd "$GIREPO" && for _ in 1 2 3; do HEIMDALL_FORCE_VISIBILITY=public "$TEAM" new --force >/dev/null 2>&1; done )
GI_PAT_COUNT="$(grep -cxF '.heimdall/team.json' "$GIREPO/.gitignore" 2>/dev/null || echo 0)"
GI_MARK_COUNT="$(grep -c 'heimdall team secret' "$GIREPO/.gitignore" 2>/dev/null || echo 0)"
if [ "$GI_PAT_COUNT" = "1" ] && [ "$GI_MARK_COUNT" = "1" ]; then
  ok "(G1) tracked team.json + public flip: gitignore block appended exactly once over 3 runs"
else
  bad "(G1) gitignore non-idempotent: pattern=$GI_PAT_COUNT marker=$GI_MARK_COUNT (want 1/1)"
fi

# ─────────────────────────────────────────────────────────────────────────────
# (H) OUTCOME OBSERVER — seed a commit, revert it, scan -> revert detected;
#     the outcome record carries only booleans/buckets/hashes.
# ─────────────────────────────────────────────────────────────────────────────
printf "\n[H] local outcome observer (pmr_outcome, client-side)\n"
export HEIMDALL_CORPUS_HOME="$WORK/H"
OREPO="$WORK/orepo"; mkdir -p "$OREPO"
( cd "$OREPO" && git init -q && git config user.email t@t && git config user.name t \
  && printf 'line1\nline2\nline3\n' > app.py && git add app.py && git commit -qm "feat: app" )
OJOB="$("$PY" -c "import json;print(json.dumps({'attestation':{'claims':{'file_count':1,'files':[{'path':'app.py','lang':'py'}]}},'ids':{'team_id':'t','repo':'$OREPO'},'verify':{'verdict':'pass'}}))")"
( cd "$OREPO" && printf '%s' "$OJOB" | "$CLI" emit >/dev/null )
( cd "$OREPO" && printf 'line1\nCHANGED\nline3\n' > app.py && git add app.py && git commit -qm "feat: change line2" )
OBS="$(cd "$OREPO" && "$CLI" observe --sha "$(git rev-parse HEAD)")"
( cd "$OREPO" && printf 'line1\nline2\nline3\n' > app.py && git add app.py && git commit -qm "Revert \"feat: change line2\"" )
SCAN="$(cd "$OREPO" && "$CLI" scan)"
if printf '%s' "$OBS" | grep -q '"observed": *true'; then
  ok "(H1) observer seeded the commit (merged sha hash recorded)"
else
  bad "(H1) observer did not seed: $OBS"
fi
REV="$(printf '%s' "$SCAN" | "$PY" -c "import json,sys;o=json.load(sys.stdin)['outcomes'][0];print(o['reverted_within']['7d'],o['reverted_within']['30d'])" 2>/dev/null)"
if [ "$REV" = "True True" ]; then
  ok "(H2) scan detected the revert overlap (reverted_within 7d & 30d)"
else
  bad "(H2) revert overlap not detected: $REV"
fi
OUT_REC="$(ls "$HEIMDALL_CORPUS_HOME/telemetry/pmr/outcome"/*.json 2>/dev/null | head -1)"
if [ -n "$OUT_REC" ] && ! grep -nE 'app|line|/|Revert|feat' "$OUT_REC" >/dev/null 2>&1; then
  ok "(H3) outcome record carries only booleans/buckets/hashes (no source/path/msg)"
else
  bad "(H3) outcome record leaked content or was absent"
fi

# ─────────────────────────────────────────────────────────────────────────────
# (R) ROUTER — `hmd telemetry status` routes through bin/heimdall.
# ─────────────────────────────────────────────────────────────────────────────
printf "\n[R] router: hmd telemetry -> engine\n"
export HEIMDALL_CORPUS_HOME="$WORK/R"
if [ -x "$HMD" ]; then
  RSTAT="$("$HMD" telemetry status 2>/dev/null | "$PY" -c "import json,sys;d=json.load(sys.stdin);print(d['schema'],d['enabled'])" 2>/dev/null)"
  if printf '%s' "$RSTAT" | grep -q 'pmr_status_v1'; then
    ok "(R1) hmd telemetry status routes to the PMR engine"
  else
    bad "(R1) router did not reach the engine: $RSTAT"
  fi
else
  bad "(R1) bin/heimdall not executable"
fi

# ─────────────────────────────────────────────────────────────────────────────
printf "\n=== RESULT: %d passed, %d failed ===\n" "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
