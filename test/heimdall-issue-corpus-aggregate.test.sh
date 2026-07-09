#!/usr/bin/env bash
# heimdall-issue-corpus-aggregate.test.sh — the Wave-2 falsifier belt for the
# k-anon ISSUE AGGREGATION module (bin/lib/cp_issue_aggregate.py). Mirrors the
# sections of test/heimdall-corpus-ingest.test.sh. Each section is a RED-without-
# fix falsifier mapped to an invariant in evals/oracles/issue-collection/
# INVARIANTS.md:
#
#   k-anon     INV-B  a signature bucket seen by < 10 distinct teams => SUPPRESSED
#                     (no metrics, only the marker); >= 10 => SERVED. Per-bucket.
#   security   INV-F  a security_sensitive record NEVER enters the public aggregate
#                     — excluded regardless of k / team count (no bucket, no metrics).
#   isolation  INV-G  the aggregate reads ONLY the isolated corpus namespace, per-
#                     team partitioned; a control-plane record NEVER surfaces, and
#                     the aggregate lands in a keyspace DISJOINT from control-plane.
#
# stdlib python + bash only. Hermetic: every read/write is pinned to a throwaway
# --home and a UNIQUE corpus namespace so the isolation proof is honest.

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
LIB="$ROOT/bin/lib"
export LIB ROOT
PY="$(command -v python3 || command -v python)"

PASS=0
FAIL=0
ok()  { printf '  \033[32mPASS\033[0m %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAIL=$((FAIL + 1)); }

ROOT_T="$(mktemp -d -t issue-agg.XXXXXX)"
HOME_T="$ROOT_T/home"
mkdir -p "$HOME_T"
trap 'rm -rf "$ROOT_T"' EXIT

export HEIMDALL_HOME="$HOME_T"
# A unique corpus namespace so the cross-namespace isolation proof is honest — the
# issue store lands under its OWN root, never the control-plane store, same backend.
export HEIMDALL_CORPUS_NAMESPACE="heimdall_corpus_issue_agg_gate"

echo "== issue-corpus AGGREGATE falsifier belt (Wave 2) =="

[ -f "$LIB/cp_issue_aggregate.py" ] || { echo "cp_issue_aggregate.py missing: $LIB"; }

DRIVER="$ROOT_T/driver.py"
cat >"$DRIVER" <<'PYEOF'
import json
import os
import sys

sys.path.insert(0, os.environ["LIB"])
import cp_issue_aggregate as AGG
import cp_state
import issue_corpus
import pmr_corpus

HOME = os.environ["HEIMDALL_HOME"]
NS = pmr_corpus.corpus_namespace()
K = issue_corpus.ISSUE_K_ANONYMITY_MIN  # 10
out = {}


def rec(team, sig="sigA", ec="lint", ver="v2", oscls="mac", cmd="verify", sec=False):
    """A closed-schema issue_v1 record as it lands post-ingest (flat team_id_hash
    stamped server-side, plus the nested ids the aggregate must also tolerate)."""
    return {"schema": "issue_v1", "consent_version": "c1",
            "team_id_hash": team,
            "ids": {"issue_id": "i-" + team + "-" + sig, "team_id_hash": team,
                    "repo_class_hash": "rc"},
            "when": {"ts": "t", "tz_bucket": "u"},
            "signal": {"error_class": ec, "signature_hash": sig, "gate": "lint",
                       "phase": "verify", "command": cmd, "severity": "error"},
            "env": {"os_class": oscls, "ci": False, "hmd_version": ver},
            "security_sensitive": sec}


# ── INV-B: k-anon signature-bucket suppression (per bucket) ──
# A signature bucket seen by exactly K distinct teams -> PUBLISHED.
at_k = AGG.compute_issue_aggregates([rec("t%03d" % i, sig="S_atk") for i in range(K)])
sig_at_k = at_k["dimensions"]["by_signature"]
key_at_k = [k for k in sig_at_k if "S_atk" in k][0]
b_at_k = sig_at_k[key_at_k]
out["b_at_k_suppressed"] = bool(b_at_k.get("suppressed"))
out["b_at_k_has_metrics"] = "n" in b_at_k and not b_at_k.get("suppressed")
out["b_at_k_teams"] = b_at_k.get("teams")

# A signature bucket seen by K-1 distinct teams -> SUPPRESSED (no metrics, marker only).
below = AGG.compute_issue_aggregates([rec("t%03d" % i, sig="S_below") for i in range(K - 1)])
key_below = [k for k in below["dimensions"]["by_signature"] if "S_below" in k][0]
b_below = below["dimensions"]["by_signature"][key_below]
out["b_below_suppressed"] = bool(b_below.get("suppressed"))
out["b_below_has_metrics"] = "n" in b_below
out["b_below_teams"] = b_below.get("teams")
out["b_below_reason"] = b_below.get("reason")

# The rare-signature edge (ONE team, ONE hash) MUST suppress.
rare = AGG.compute_issue_aggregates([rec("only-team", sig="S_rare")])
key_rare = [k for k in rare["dimensions"]["by_signature"] if "S_rare" in k][0]
out["b_rare_suppressed"] = bool(rare["dimensions"]["by_signature"][key_rare].get("suppressed"))

# PER-BUCKET: in ONE rollup a big signature (K teams) publishes while a small one
# (3 teams) is suppressed — the gate is per-cell, not global.
mixed = ([rec("t%03d" % i, sig="S_big") for i in range(K)]
         + [rec("t%03d" % i, sig="S_small") for i in range(3)])
mx = AGG.compute_issue_aggregates(mixed)
kb = [k for k in mx["dimensions"]["by_signature"] if "S_big" in k][0]
ks = [k for k in mx["dimensions"]["by_signature"] if "S_small" in k][0]
out["b_mixed_big_suppressed"] = bool(mx["dimensions"]["by_signature"][kb].get("suppressed"))
out["b_mixed_small_suppressed"] = bool(mx["dimensions"]["by_signature"][ks].get("suppressed"))


# ── INV-F: a security_sensitive record NEVER enters the public aggregate ──
# K distinct teams share a security signature — enough to clear k-anon — yet because
# it is security_sensitive it must be EXCLUDED entirely: no bucket, no metrics.
sec_records = [rec("t%03d" % i, sig="S_secret", ec="auth", sec=True) for i in range(K)]
benign = [rec("t%03d" % i, sig="S_ok", ec="lint") for i in range(K)]
fsec = AGG.compute_issue_aggregates(sec_records + benign)
sig_keys = list(fsec["dimensions"]["by_signature"].keys())
blob = json.dumps(fsec)
out["f_secret_bucket_present"] = any("S_secret" in k for k in sig_keys)
out["f_ok_bucket_present"] = any("S_ok" in k for k in sig_keys)
out["f_secret_hash_in_output"] = "S_secret" in blob
out["f_excluded_security"] = fsec.get("excluded_security")
out["f_total_issues"] = fsec.get("total_issues")   # only the K benign counted
out["f_auth_class_in_output"] = "auth" in blob


# ── INV-G: store-namespace isolation (issue keyspace disjoint from control-plane) ──
# Write K team partitions THROUGH the aggregate's own backend (the isolated corpus
# namespace, issues/<team>/issues.ndjson) so the read path is proven end-to-end.
for i in range(K):
    team = "gteam%03d" % i
    AGG._backend(HOME).append_line(AGG._issue_rel(team), rec(team, sig="S_store"))
# Plant an OPS/presence record in the CONTROL-PLANE namespace (namespace=None).
cp_backend = cp_state.get_backend(home=HOME)
cp_backend.append_line("presence/acme/dev.ndjson", {"online": True, "marker": "OPSDATA_ctrlplane"})

all_issues = AGG.all_issues(home=HOME)
out["g_read_count"] = len(all_issues)
out["g_ops_marker_in_issues"] = any("OPSDATA_ctrlplane" in json.dumps(r) for r in all_issues)

# The aggregate's backend must NOT resolve a control-plane rel, and vice-versa.
corp_backend = AGG._backend(HOME)
out["g_corpus_reads_ctrlplane"] = corp_backend.read_lines("presence/acme/dev.ndjson")
out["g_ctrlplane_reads_issues"] = cp_backend.read_lines(AGG._issue_rel("gteam000"))
out["g_corpus_root"] = corp_backend.path("").rstrip("/").split("/")[-1]
out["g_ctrlplane_root"] = cp_backend.path("").rstrip("/").split("/")[-1]

# run_daily_aggregate reads the store, folds it, stores + reads back the aggregate.
agg = AGG.run_daily_aggregate(home=HOME)
out["g_run_total_teams"] = agg.get("total_teams")
store_key = [k for k in agg["dimensions"]["by_signature"] if "S_store" in k][0]
out["g_run_store_published"] = not agg["dimensions"]["by_signature"][store_key].get("suppressed")
latest = AGG.latest_aggregate(home=HOME)
out["g_latest_matches"] = bool(latest) and latest.get("total_teams") == agg.get("total_teams")
# The stored aggregate must never carry a control-plane marker.
out["g_ops_marker_in_aggregate"] = "OPSDATA_ctrlplane" in json.dumps(latest or {})

print(json.dumps(out))
PYEOF

OUT="$("$PY" "$DRIVER" 2>"$ROOT_T/err")"
if [ -z "$OUT" ]; then
  bad "driver produced no output (see stderr)"; cat "$ROOT_T/err" >&2
  echo; echo "RESULT: $PASS passed, $FAIL failed"; exit 1
fi
echo "  driver: $OUT"
echo

j() { printf '%s' "$OUT" | "$PY" -c "import json,sys;print(json.load(sys.stdin)$1)" 2>/dev/null; }

echo "-- INV-B k-anon signature-bucket suppression --"
[ "$(j "['b_at_k_suppressed']")" = "False" ] && [ "$(j "['b_at_k_has_metrics']")" = "True" ] \
  && ok "INV-B: a signature bucket with >= 10 distinct teams is PUBLISHED (metrics served)" \
  || bad "INV-B: a >= 10-team signature bucket was suppressed — out=$OUT"

[ "$(j "['b_below_suppressed']")" = "True" ] && [ "$(j "['b_below_has_metrics']")" = "False" ] \
  && [ "$(j "['b_below_reason']")" = "k_anonymity" ] \
  && ok "INV-B: a signature bucket with < 10 distinct teams is SUPPRESSED (no metrics, k_anonymity marker)" \
  || bad "INV-B: a < 10-team bucket served its metrics (k-anon broken) — out=$OUT"

[ "$(j "['b_rare_suppressed']")" = "True" ] \
  && ok "INV-B: the rare-signature edge (one team, one hash) SUPPRESSES" \
  || bad "INV-B: a rare one-team signature was not suppressed — out=$OUT"

[ "$(j "['b_mixed_big_suppressed']")" = "False" ] && [ "$(j "['b_mixed_small_suppressed']")" = "True" ] \
  && ok "INV-B: the gate is PER BUCKET — a big signature publishes while a small one is suppressed in one rollup" \
  || bad "INV-B: the per-bucket k-anon gate did not hold — out=$OUT"

echo
echo "-- INV-F security-sensitive excluded from the public aggregate --"
[ "$(j "['f_secret_bucket_present']")" = "False" ] && [ "$(j "['f_secret_hash_in_output']")" = "False" ] \
  && ok "INV-F: a security_sensitive signature (even with >= 10 teams) NEVER appears as a published bucket (FALSIFIER)" \
  || bad "INV-F: a security_sensitive bucket reached the public aggregate — out=$OUT"

[ "$(j "['f_ok_bucket_present']")" = "True" ] && [ "$(j "['f_excluded_security']")" = "10" ] \
  && [ "$(j "['f_total_issues']")" = "10" ] \
  && ok "INV-F: the benign bucket still publishes; the 10 security records are counted excluded, not folded" \
  || bad "INV-F: security exclusion mis-counted or over-blocked benign — out=$OUT"

echo
echo "-- INV-G store-namespace isolation (no cross-tenant / cross-namespace read) --"
[ "$(j "['g_read_count']")" = "10" ] && [ "$(j "['g_ops_marker_in_issues']")" = "False" ] \
  && ok "INV-G: all_issues reads the 10 per-team partitions and NEVER surfaces the control-plane ops marker" \
  || bad "INV-G: the issue read path leaked a control-plane record — out=$OUT"

[ "$(j "['g_corpus_reads_ctrlplane']")" = "[]" ] && [ "$(j "['g_ctrlplane_reads_issues']")" = "[]" ] \
  && ok "INV-G: the corpus backend can NEVER resolve a control-plane rel, and vice-versa (FALSIFIER)" \
  || bad "INV-G: a namespace leaked (cross-namespace read path) — out=$OUT"

CROOT="$(j "['g_corpus_root']")"; CPROOT="$(j "['g_ctrlplane_root']")"
[ -n "$CROOT" ] && [ -n "$CPROOT" ] && [ "$CROOT" != "$CPROOT" ] \
  && ok "INV-G: disjoint on-disk roots: corpus=$CROOT vs control-plane=$CPROOT" \
  || bad "INV-G: the corpus + control-plane share a root — corpus=$CROOT cp=$CPROOT"

[ "$(j "['g_run_total_teams']")" = "10" ] && [ "$(j "['g_run_store_published']")" = "True" ] \
  && [ "$(j "['g_latest_matches']")" = "True" ] && [ "$(j "['g_ops_marker_in_aggregate']")" = "False" ] \
  && ok "INV-G: run_daily_aggregate folds the isolated store, stores+reads back latest, never carries ops data" \
  || bad "INV-G: the daily aggregate round-trip failed or leaked — out=$OUT"

echo
echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
