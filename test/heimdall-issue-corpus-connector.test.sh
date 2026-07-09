#!/usr/bin/env bash
# heimdall-issue-corpus-connector.test.sh — the Wave-3 falsifier belt for the
# SHADOW-PROPOSAL -> issue_queue CONNECTOR (bin/lib/connectors/corpus.py + the
# `source=corpus` normalize adapter in bin/lib/issue_queue.py). It feeds
# cp_issue_synth's shadow proposals into the EXISTING seeker/fixer issue_queue as
# a NEW source — reusing the queue machinery + the synth output, never re-deriving
# proposals. Each section is a RED-without-fix falsifier mapped to a decision /
# invariant in evals/oracles/issue-collection/INVARIANTS.md:
#
#   no-auto-file  RJ#2   a shadow proposal NEVER auto-creates a GitHub issue — the
#                        connector has NO auto-file call path; post_resolution +
#                        close_issue are inert no-ops (nothing is opened/enforced).
#   pending-only  RJ#2   the connector serves ONLY status=pending_review shadow
#                        proposals; a maintainer promotes out of band.
#   security      INV-F  a security-sensitive proposal NEVER enters the public
#                        queue (defense-in-depth at the source boundary), even
#                        though synth already excludes it before clustering.
#   normalize     §2     a proposal maps to the ONE internal schema as source=corpus,
#                        content-free (coded pattern only), url=None (never filed).
#
# stdlib python + bash only. Hermetic: pinned to a throwaway --home + a UNIQUE
# corpus namespace, so the isolated-store read is honest (its own root, never the
# control-plane store, on the SAME backend).

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
LIB="$ROOT/bin/lib"
export LIB ROOT
CONN="$LIB/connectors/corpus.py"
PY="$(command -v python3 || command -v python)"

PASS=0
FAIL=0
ok()  { printf '  \033[32mPASS\033[0m %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAIL=$((FAIL + 1)); }

[ -f "$CONN" ] || { echo "FATAL: connectors/corpus.py missing: $CONN" >&2; echo "RESULT: 0 passed, 1 failed"; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "== issue-corpus SHADOW-PROPOSAL connector falsifier belt =="

# ── no-auto-file (RJ#2), structural: no code path from the connector to opening a
#    GitHub issue. A shadow proposal is observe-only; the maintainer promotes it. ─
echo "-- no-auto-file (RJ decision 2) — structural --"
# Match a real CALL / IMPORT (syntax), not prose in a comment that DOCUMENTS the
# no-auto-file guarantee — a comment saying "never calls create_issue" must NOT
# trip the falsifier; an actual `something.create_issue(...)` call MUST.
if grep -qE "create_issue[[:space:]]*\(" "$CONN"; then
  bad "no-auto-file: connector has a real create_issue(...) call (an auto-file call path)"
else
  ok "no-auto-file: connector has NO create_issue(...) call path (FALSIFIER — never auto-opens)"
fi
if grep -qE "^[[:space:]]*(import|from)[[:space:]].*\bgithub\b" "$CONN"; then
  bad "no-auto-file: connector imports the github connector (an auto-file channel)"
else
  ok "no-auto-file: connector never imports the github connector"
fi

# ── pure normalize + _KIND_BY_SOURCE (the source=corpus adapter, §2) ────────────
echo "-- normalize (source=corpus, content-free) --"
DRIVER="$TMP/norm_driver.py"
cat >"$DRIVER" <<'PYEOF'
import json
import os
import sys

sys.path.insert(0, os.environ["LIB"])
import issue_queue as Q
import connectors.corpus  # noqa: F401  (self-registers "corpus")
import connectors

out = {}
out["corpus_in_map"] = "corpus" in Q._KIND_BY_SOURCE
out["registered"] = connectors.is_registered("corpus")

prop = {
    "schema_version": "shadow_issue_v1",
    "proposal_id": "shadow-iss-abc123",
    "created_ts": 1700000000.0,
    "status": "pending_review",
    "enforced": False,
    "pattern": {"error_class": "lint", "signature_hash": "deadbeefcafe",
                "hmd_version": "v2", "os_class": "mac", "command": "build"},
    "support": {"issues": 30, "teams": 12},
    "sample_issue_ids": ["iss-1", "iss-2"],
    "candidate": "SHADOW: 12 teams hit error_class=lint signature=deadbeefcafe ...",
}
iss = Q.normalize("corpus", prop)
out["src"] = iss["source"]
out["id"] = iss["id"]
out["id_prefixed"] = iss["id"].startswith("corpus:")
out["url"] = iss["links"]["url"]
out["sev"] = iss["priority_signal"]["severity"]
out["created_year"] = str(iss["created_at"])[:4]
out["ref_pid"] = iss["links"]["source_ref"].get("proposal_id")
# content-freeness: no filesystem path / no free text — the whole record is coded.
blob = json.dumps(iss)
out["no_slash_path"] = "/etc/" not in blob and "\\" not in blob
print(json.dumps(out))
PYEOF

OUT="$("$PY" "$DRIVER" 2>"$TMP/norm.err")"
if [ -z "$OUT" ]; then
  bad "normalize driver produced no output"; cat "$TMP/norm.err" >&2
else
  echo "  norm driver: $OUT"
  j() { printf '%s' "$OUT" | "$PY" -c "import json,sys;print(json.load(sys.stdin)$1)" 2>/dev/null; }
  [ "$(j "['corpus_in_map']")" = "True" ] \
    && ok "normalize: 'corpus' is a known source in _KIND_BY_SOURCE" \
    || bad "normalize: 'corpus' missing from _KIND_BY_SOURCE — out=$OUT"
  [ "$(j "['registered']")" = "True" ] \
    && ok "normalize: the corpus connector self-registers in the launch set" \
    || bad "normalize: corpus connector not registered — out=$OUT"
  [ "$(j "['src']")" = "corpus" ] && [ "$(j "['id_prefixed']")" = "True" ] \
    && ok "normalize: a proposal maps to source=corpus with a corpus: id" \
    || bad "normalize: proposal did not map to source=corpus — out=$OUT"
  [ "$(j "['url']")" = "None" ] \
    && ok "normalize: url is None (a shadow proposal is NEVER filed anywhere)" \
    || bad "normalize: a shadow proposal carried a url — out=$OUT"
  [ "$(j "['ref_pid']")" = "shadow-iss-abc123" ] \
    && ok "normalize: source_ref carries the proposal_id (the promotion handle)" \
    || bad "normalize: source_ref lost the proposal_id — out=$OUT"
  [ "$(j "['no_slash_path']")" = "True" ] \
    && ok "normalize: the normalized issue is content-free (coded pattern only)" \
    || bad "normalize: content leaked into the normalized issue — out=$OUT"
fi

# ── fetch: pending-only + INV-F security exclusion + no-auto-file behavior +
#    end-to-end ingest into the EXISTING queue as source=corpus ─────────────────
echo "-- fetch + security exclusion + queue round-trip --"
HOME_T="$TMP/store"; mkdir -p "$HOME_T"
FDRIVER="$TMP/fetch_driver.py"
cat >"$FDRIVER" <<'PYEOF'
import json
import os
import sys

sys.path.insert(0, os.environ["LIB"])
import connectors
import connectors.corpus  # noqa: F401
import cp_issue_synth as SYNTH
import issue_queue as Q

HOME = os.environ["HEIMDALL_HOME"]
backend = SYNTH._backend(HOME)     # the ISOLATED corpus-namespace proposal store
qrel = SYNTH._queue_rel()
out = {}


def prop(pid, ec="lint", status="pending_review"):
    return {
        "schema_version": "shadow_issue_v1",
        "proposal_id": pid,
        "created_ts": 1700000000.0,
        "status": status,
        "enforced": False,
        "pattern": {"error_class": ec, "signature_hash": "sig_" + pid,
                    "hmd_version": "v2", "os_class": "mac", "command": "build"},
        "support": {"issues": 30, "teams": 12},
        "sample_issue_ids": ["iss"],
        "candidate": "SHADOW: candidate to TRIAGE (not auto-opened).",
    }


# benign pending -> served; an auth (security) pending -> DROPPED (INV-F);
# a non-pending (already-promoted) -> DROPPED (pending-only).
backend.append_line(qrel, prop("benign1"), fsync=False)
backend.append_line(qrel, prop("sec1", ec="auth"), fsync=False)
backend.append_line(qrel, prop("promoted1", status="promoted"), fsync=False)
# a duplicate snapshot of the same benign proposal (re-run) -> deduped to one.
backend.append_line(qrel, prop("benign1"), fsync=False)

c = connectors.get("corpus")
c.configure({"active": True, "home": HOME})
out["active"] = c.health().get("active")

items = c.fetch_issues()
pids = sorted(i.get("proposal_id") for i in items)
out["pids"] = pids
out["all_pending"] = all(i.get("status") == "pending_review" for i in items)
out["sec_excluded"] = "sec1" not in pids
out["auth_in_blob"] = "auth" in json.dumps(items)
out["nonpending_excluded"] = "promoted1" not in pids
out["deduped"] = pids.count("benign1") == 1

# no-auto-file: writeback is an inert no-op — it NEVER opens/comments on a GitHub
# issue (there is no external source; a shadow proposal is promoted by a human).
pr = c.post_resolution({"proposal_id": "benign1"}, {"summary": "done", "pr_url": "http://x"})
ci = c.close_issue({"proposal_id": "benign1"})
out["post_ok"] = pr.get("ok")
out["close_ok"] = ci.get("ok")

# end-to-end: the fetched proposals normalize into the EXISTING queue as
# source=corpus, drained by the unchanged heimdall-issue-loop path.
issues = [Q.normalize("corpus", i) for i in items]
q = Q.IssueQueue(path=os.path.join(HOME, "queue.json"))
out["ingested"] = q.ingest_many(issues)
q.save()
out["queue_sources"] = sorted({v["source"] for v in q.data["issues"].values()})
print(json.dumps(out))
PYEOF

FOUT="$(env HEIMDALL_HOME="$HOME_T" HEIMDALL_CORPUS_NAMESPACE="heimdall_issue_connector_gate" \
  "$PY" "$FDRIVER" 2>"$TMP/fetch.err")"
if [ -z "$FOUT" ]; then
  bad "fetch driver produced no output"; cat "$TMP/fetch.err" >&2
else
  echo "  fetch driver: $FOUT"
  fj() { printf '%s' "$FOUT" | "$PY" -c "import json,sys;print(json.load(sys.stdin)$1)" 2>/dev/null; }

  [ "$(fj "['active']")" = "True" ] \
    && ok "fetch: a configured corpus connector is active (reads the local shadow store)" \
    || bad "fetch: connector inactive when configured — out=$FOUT"

  [ "$(fj "['pids']")" = "['benign1']" ] && [ "$(fj "['all_pending']")" = "True" ] \
    && ok "pending-only: the connector serves ONLY pending_review shadow proposals" \
    || bad "pending-only: served a non-pending / wrong proposal set — out=$FOUT"

  [ "$(fj "['sec_excluded']")" = "True" ] && [ "$(fj "['auth_in_blob']")" = "False" ] \
    && ok "security: a security_sensitive proposal NEVER enters the public queue (FALSIFIER — INV-F)" \
    || bad "security: a security proposal reached the queue — out=$FOUT"

  [ "$(fj "['nonpending_excluded']")" = "True" ] \
    && ok "pending-only: an already-promoted proposal is excluded from the feed" \
    || bad "pending-only: a promoted proposal was re-served — out=$FOUT"

  [ "$(fj "['deduped']")" = "True" ] \
    && ok "fetch: re-run duplicate snapshots dedupe by proposal_id" \
    || bad "fetch: duplicate proposal snapshots were not deduped — out=$FOUT"

  [ "$(fj "['post_ok']")" = "False" ] && [ "$(fj "['close_ok']")" = "False" ] \
    && ok "no-auto-file: post_resolution + close_issue are inert no-ops (FALSIFIER — never auto-opens)" \
    || bad "no-auto-file: writeback claimed success (an auto-file leak) — out=$FOUT"

  [ "$(fj "['ingested']")" = "1" ] && [ "$(fj "['queue_sources']")" = "['corpus']" ] \
    && ok "round-trip: fetched proposals ingest into the EXISTING queue as source=corpus" \
    || bad "round-trip: proposals did not land in the queue as source=corpus — out=$FOUT"
fi

echo
echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
