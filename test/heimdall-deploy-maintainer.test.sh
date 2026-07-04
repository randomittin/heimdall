#!/usr/bin/env bash
# deploy-maintainer.sh guard: --dry-run needs no creds + prints the plan; bad --repo rejected;
# no token VALUE ever reaches stdout (dry-run collects none); the constraint banner is present.
set -uo pipefail
S="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/deploy/cloud-run/deploy-maintainer.sh"
P=0; F=0; ok(){ P=$((P+1)); printf '  PASS %s\n' "$1"; }; bad(){ F=$((F+1)); printf '  FAIL %s\n' "$1"; }
[ -x "$S" ] || { echo "FATAL: $S not executable"; exit 2; }
bash -n "$S" || { echo "FATAL syntax"; exit 2; }

# 1. dry-run, hybrid, valid repo → exit 0, no creds, prints plan
OUT="$(bash "$S" --dry-run --hybrid --repo acme/widgets 2>&1)"; rc=$?
[ "$rc" = 0 ] && ok "dry-run hybrid exit 0 (no creds)" || bad "dry-run rc=$rc"
printf '%s' "$OUT" | grep -q 'gcloud run jobs replace' && ok "prints Arch-B job replace plan" || bad "no job-replace in plan"
printf '%s' "$OUT" | grep -q 'runner-beat --repo acme/widgets' && ok "prints Arch-A runner-beat plan" || bad "no runner-beat"
printf '%s' "$OUT" | grep -qi 'NEVER pushes main' && ok "constraint banner present" || bad "no constraint banner"
printf '%s' "$OUT" | grep -q 'nothing executed' && ok "dry-run executes nothing" || bad "no dry-run marker"

# 2. missing/bad --repo rejected
bash "$S" --dry-run --hybrid 2>/dev/null; [ $? -ne 0 ] && ok "missing --repo rejected" || bad "missing repo accepted"
bash "$S" --dry-run --hybrid --repo not-a-slug 2>/dev/null; [ $? -ne 0 ] && ok "bad --repo slug rejected" || bad "bad slug accepted"

# 3. no token VALUE on stdout (dry-run prompts skipped; a fake token in env must not surface)
OUT2="$(OAUTH_TOKEN=SECRET-XYZ BOT_TOKEN=SECRET-XYZ bash "$S" --dry-run --cloud --repo acme/widgets 2>&1)"
printf '%s' "$OUT2" | grep -q 'SECRET-XYZ' && bad "token value leaked to stdout" || ok "no token value on stdout"

# 4. --local mode omits gcloud from the plan's Arch-A section start
OUT3="$(bash "$S" --dry-run --local --repo acme/widgets 2>&1)"; printf '%s' "$OUT3" | grep -q 'Arch A' && ok "local mode plans Arch A" || bad "local mode missing"

# 5. the Job manifest PARSES + is MULTITENANT-SAFE: metadata.name is heimdall-maintainer-job,
#    HEIMDALL_CP_PKI_KEY(cp-pki-key) IS mounted, but the PER-TEAM CLAUDE_CODE_OAUTH_TOKEN and
#    HEIMDALL_PR_BOT_TOKEN are NOT baked into the base manifest (injected per-execution by the
#    dispatcher). Falsifiable: re-adding either fixed cred mount, or renaming the job, fails.
YAML="$(dirname "$S")/heimdall-maintainer-job.yaml"
python3 - "$YAML" <<'PY'
import sys, yaml
p = sys.argv[1]
try:
    doc = yaml.safe_load(open(p))
except Exception as e:
    print(f"  FAIL manifest does not parse as YAML: {e}"); sys.exit(3)
name = (doc.get("metadata") or {}).get("name")
env = doc["spec"]["template"]["spec"]["template"]["spec"]["containers"][0].get("env", [])
names = {e.get("name") for e in env}
rc = 0
def ok(m):  print(f"  PASS {m}")
def bad(m):
    global rc; rc = 1; print(f"  FAIL {m}")
(ok if name == "heimdall-maintainer-job" else bad)(f"manifest metadata.name == heimdall-maintainer-job (got {name!r})")
(ok if "HEIMDALL_CP_PKI_KEY" in names else bad)("manifest mounts HEIMDALL_CP_PKI_KEY (cp-pki-key)")
(bad if "CLAUDE_CODE_OAUTH_TOKEN" in names else ok)("manifest does NOT bake CLAUDE_CODE_OAUTH_TOKEN (per-team, dispatcher-injected)")
(bad if "HEIMDALL_PR_BOT_TOKEN" in names else ok)("manifest does NOT bake HEIMDALL_PR_BOT_TOKEN (per-team, dispatcher-injected)")
sys.exit(rc)
PY
[ $? -eq 0 ] && ok "manifest parses + multitenant-safe (name + PKI mounted, per-team creds NOT baked)" \
  || bad "manifest parse/multitenant assertions failed (see per-line PASS/FAIL above)"

echo "──────────"; echo "deploy-maintainer: $P passed, $F failed"
[ "$F" = 0 ] || exit 1
