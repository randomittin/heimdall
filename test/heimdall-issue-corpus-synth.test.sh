#!/usr/bin/env bash
# heimdall-issue-corpus-synth.test.sh — the Wave-2 falsifier belt for the issue
# SHADOW-SYNTHESIS loop (bin/lib/cp_issue_synth.py). Mirrors the sections of
# test/heimdall-corpus-ingest.test.sh (the cp_corpus_synth precedent) and
# test/heimdall-issue-corpus-emit.test.sh. Each section is a RED-without-fix
# falsifier mapped to an invariant in evals/oracles/issue-collection/INVARIANTS.md:
#
#   k-anon-synth    INV-B  a signature cluster < 10 distinct teams => NEVER proposed
#                          (the k-anon floor is upheld THROUGH synth — no sub-k real
#                          signal is ever surfaced as a served candidate)
#   security-synth  INV-F  a security_sensitive signal => NEVER a synth candidate,
#                          at ANY team count (excluded before clustering)
#   isolation       INV-G  synth reads issues + writes proposals ONLY through the
#                          ISOLATED corpus namespace; no cross-namespace read path
#   shadow          RJ#2   every proposal is status=pending_review + enforced=False
#                          (SHADOW-first — this loop never auto-opens a GitHub issue)
#
# stdlib python + bash only. Hermetic: pinned to a throwaway --home + a UNIQUE
# corpus namespace, so the isolation proof is honest (its own root, never the
# control-plane store, on the SAME backend).

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
LIB="$ROOT/bin/lib"
export LIB ROOT
SYNTH="$LIB/cp_issue_synth.py"
PY="$(command -v python3 || command -v python)"

PASS=0
FAIL=0
ok()   { printf '  \033[32mPASS\033[0m %s\n' "$1"; PASS=$((PASS + 1)); }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAIL=$((FAIL + 1)); }

[ -f "$SYNTH" ] || { echo "FATAL: cp_issue_synth.py missing: $SYNTH" >&2; echo "RESULT: 0 passed, 1 failed"; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "== issue-corpus SHADOW-SYNTH falsifier belt =="

# ── the PURE synthesis fold (INV-B / INV-F / shadow), one JSON line ─────────────
DRIVER="$TMP/pure_driver.py"
cat >"$DRIVER" <<'PYEOF'
import json
import os
import sys

sys.path.insert(0, os.environ["LIB"])
import cp_issue_synth as SYNTH

out = {}


def issue(team, sig, ec="lint", sec=False, iid=None):
    """An INGESTED issue_v1 (nested ids.team_id_hash — the server-stamped shape)."""
    return {
        "schema": "issue_v1",
        "consent_version": "c1",
        "ids": {"issue_id": iid or ("iss-%s-%s" % (team, sig)),
                "team_id_hash": team, "repo_class_hash": "rc"},
        "when": {"ts": "t", "tz_bucket": "u"},
        "signal": {"error_class": ec, "signature_hash": sig, "gate": "lint",
                   "phase": "verify", "command": "build", "severity": "error"},
        "env": {"os_class": "mac", "ci": False, "hmd_version": "v2"},
        "security_sensitive": sec,
    }


# Cluster A — a benign signature seen by 12 DISTINCT teams -> MUST be proposed.
big = [issue("t%02d" % i, "sigA", ec="lint") for i in range(12)]
# Cluster B — a rare signature seen by 3 DISTINCT teams -> MUST be suppressed (INV-B).
rare = [issue("t%02d" % i, "sigB", ec="style") for i in range(3)]
# Cluster C — a SECURITY-sensitive signature seen by 15 DISTINCT teams -> MUST NEVER
# be proposed regardless of the (over-threshold) team count (INV-F).
sec = [issue("t%02d" % i, "sigC", ec="auth", sec=True) for i in range(15)]

props = SYNTH.synthesize_proposals(big + rare + sec)
blob = json.dumps(props)

out["n_proposals"] = len(props)
out["a_proposed"] = any(p.get("pattern", {}).get("signature_hash") == "sigA" for p in props)
out["b_in_blob"] = "sigB" in blob                       # rare signature must NOT surface
out["c_in_blob"] = "sigC" in blob                       # security signature must NOT surface
out["auth_in_blob"] = "auth" in blob                    # security error_class must NOT surface
out["all_pending"] = all(p.get("status") == "pending_review" for p in props)
out["none_enforced"] = all(p.get("enforced") is False for p in props)
# A served proposal carries ONLY the coded pattern + counts + sample handles — NEVER
# the underlying records (which would re-expose sub-threshold real data downstream).
out["no_records_key"] = all("records" not in p for p in props)
out["no_team_hash_leak"] = "team_id_hash" not in blob
if props:
    a = next(p for p in props if p["pattern"]["signature_hash"] == "sigA")
    out["a_teams"] = a.get("support", {}).get("teams")
    out["a_support_keys"] = sorted(a.get("support", {}).keys())
    out["a_has_candidate"] = bool(a.get("candidate"))

# Sub-floor boundary: a cluster with EXACTLY k-1 teams suppresses, EXACTLY k publishes.
K = SYNTH.min_teams()
at_k = SYNTH.synthesize_proposals([issue("k%02d" % i, "sigK") for i in range(K)])
below = SYNTH.synthesize_proposals([issue("k%02d" % i, "sigK") for i in range(K - 1)])
out["k"] = K
out["at_k_proposed"] = len(at_k) == 1
out["below_k_proposed"] = len(below) != 0

print(json.dumps(out))
PYEOF

OUT="$("$PY" "$DRIVER" 2>"$TMP/pure.err")"
if [ -z "$OUT" ]; then
  bad "pure driver produced no output"; cat "$TMP/pure.err" >&2
  echo; echo "RESULT: $PASS passed, $((FAIL + 1)) failed"; exit 1
fi
echo "  pure driver: $OUT"
j() { printf '%s' "$OUT" | "$PY" -c "import json,sys;print(json.load(sys.stdin)$1)" 2>/dev/null; }

echo "-- k-anon-synth (INV-B) --"
[ "$(j "['at_k_proposed']")" = "True" ] && [ "$(j "['a_proposed']")" = "True" ] \
  && ok "k-anon-synth: a >= 10-team signature cluster IS proposed (not over-suppressed)" \
  || bad "k-anon-synth: a well-supported cluster was NOT proposed — out=$OUT"

[ "$(j "['below_k_proposed']")" = "False" ] && [ "$(j "['b_in_blob']")" = "False" ] \
  && ok "k-anon-synth: a < 10-team signature cluster is NEVER proposed (FALSIFIER — INV-B through synth)" \
  || bad "k-anon-synth: a sub-k cluster surfaced as a proposal — out=$OUT"

[ "$(j "['no_records_key']")" = "True" ] && [ "$(j "['no_team_hash_leak']")" = "True" ] \
  && ok "k-anon-synth: a proposal carries ONLY coded pattern + counts (no records, no team hashes)" \
  || bad "k-anon-synth: a proposal embedded the underlying records / team hashes — out=$OUT"

echo "-- security-synth (INV-F) --"
[ "$(j "['c_in_blob']")" = "False" ] && [ "$(j "['auth_in_blob']")" = "False" ] \
  && ok "security-synth: a security_sensitive signal is NEVER a synth candidate, even with 15 teams (FALSIFIER)" \
  || bad "security-synth: a security signal reached a synth proposal — out=$OUT"

echo "-- shadow (RJ decision 2) --"
[ "$(j "['all_pending']")" = "True" ] && [ "$(j "['none_enforced']")" = "True" ] \
  && ok "shadow: every proposal is status=pending_review + enforced=False (never auto-opened)" \
  || bad "shadow: a proposal was not pending_review / enforced=False — out=$OUT"

# ── isolation + store round-trip (INV-G), mirrors corpus-ingest S5 ──────────────
echo "-- isolation + round-trip (INV-G) --"
HOME_T="$TMP/iso"; mkdir -p "$HOME_T"
ISO="$TMP/iso_driver.py"
cat >"$ISO" <<'PYEOF'
import json
import os
import sys

sys.path.insert(0, os.environ["LIB"])
import cp_issue_synth as SYNTH
import cp_state
import pmr_corpus

HOME = os.environ["HEIMDALL_HOME"]
NS = pmr_corpus.corpus_namespace()
out = {}

backend = SYNTH._backend(HOME)   # the ISOLATED corpus-namespace backend

# Land 11 DISTINCT-team issues of ONE signature directly in the isolated issue store
# (the shape cp_issue_ingest writes: issues/<team_hash>/issues.ndjson).
for i in range(11):
    team = "team%02d" % i
    rec = {"schema": "issue_v1", "ids": {"issue_id": "iss-%d" % i, "team_id_hash": team,
           "repo_class_hash": "rc"}, "when": {"ts": "t", "tz_bucket": "u"},
           "signal": {"error_class": "lint", "signature_hash": "sigISO", "gate": "lint",
                      "phase": "verify", "command": "build", "severity": "error"},
           "env": {"os_class": "mac", "ci": False, "hmd_version": "v2"},
           "security_sensitive": False}
    backend.append_line(SYNTH._issues_rel(team), rec, fsync=False)

summary = SYNTH.run_synthesis(home=HOME)
proposals = SYNTH.list_proposals(HOME)
out["read_issues"] = summary.get("issues_read")
out["proposals_written"] = summary.get("proposals")
out["queue_len"] = len(proposals)
out["queue_pending"] = all(p.get("status") == "pending_review" for p in proposals)

# ISOLATION: plant a control-plane presence rel; the synth (corpus-namespace) backend
# must NEVER resolve it, and the control-plane backend must NEVER resolve the proposal
# queue (disjoint keyspaces on the SAME backend).
cp_backend = cp_state.get_backend(home=HOME)                       # namespace=None -> control-plane
cp_backend.append_line("presence/acme/dev.ndjson", {"marker": "OPSDATA_ctrlplane"})
out["synth_reads_ctrlplane"] = backend.read_lines("presence/acme/dev.ndjson")
out["ctrlplane_reads_queue"] = cp_backend.read_lines(SYNTH._queue_rel())
# The corpus root collection differs from the control-plane root (different keyspaces).
out["synth_root"] = backend.path("").rstrip("/").split("/")[-1]
out["ctrlplane_root"] = cp_backend.path("").rstrip("/").split("/")[-1]

print(json.dumps(out))
PYEOF

ISOOUT="$(env HEIMDALL_HOME="$HOME_T" HEIMDALL_CORPUS_NAMESPACE="heimdall_issue_synth_gate" \
  "$PY" "$ISO" 2>"$TMP/iso.err")"
if [ -z "$ISOOUT" ]; then
  bad "isolation driver produced no output"; cat "$TMP/iso.err" >&2
else
  echo "  iso driver: $ISOOUT"
  ij() { printf '%s' "$ISOOUT" | "$PY" -c "import json,sys;print(json.load(sys.stdin)$1)" 2>/dev/null; }

  [ "$(ij "['read_issues']")" = "11" ] && [ "$(ij "['queue_len']")" = "1" ] \
    && [ "$(ij "['queue_pending']")" = "True" ] \
    && ok "round-trip: run_synthesis reads the isolated issue store + writes ONE pending proposal" \
    || bad "round-trip: synthesis did not round-trip through the isolated store — out=$ISOOUT"

  [ "$(ij "['synth_reads_ctrlplane']")" = "[]" ] \
    && ok "isolation: the synth (corpus-namespace) backend can NEVER resolve a control-plane rel (INV-G)" \
    || bad "isolation: the synth backend READ a control-plane rel (namespace leak) — out=$ISOOUT"

  [ "$(ij "['ctrlplane_reads_queue']")" = "[]" ] \
    && ok "isolation: the control-plane backend can NEVER resolve the proposal queue (FALSIFIER)" \
    || bad "isolation: the control-plane backend READ the corpus proposal queue — out=$ISOOUT"

  SROOT="$(ij "['synth_root']")"; CPROOT="$(ij "['ctrlplane_root']")"
  [ -n "$SROOT" ] && [ -n "$CPROOT" ] && [ "$SROOT" != "$CPROOT" ] \
    && ok "isolation: disjoint on-disk roots (synth=$SROOT vs control-plane=$CPROOT)" \
    || bad "isolation: synth + control-plane share a root — synth=$SROOT cp=$CPROOT"
fi

echo
echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
