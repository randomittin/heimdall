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

# 6. --cloud preflight needs NO docker (image built + pinned upstream by arch-b; this script
#    only does jobs-replace + IAM + secret mint). Non-dry cloud run with fake claude/gh/gcloud
#    on PATH but docker ABSENT must PASS preflight — never die on "missing 'docker'".
#    AND, against the CURRENT MULTI-TENANT manifest (no cred secretKeyRefs), it must SKIP the
#    token prompts entirely: no `claude setup-token` (which prints a live ~1-year token!), no
#    OAuth/PAT prompt — just the multi-tenant skip note. (It then dies at the un-pinned digest
#    sentinel gate, ORTHOGONAL to the secret flow: the committed manifest pins the real digest
#    only at deploy time via deploy-arch-b.sh.) Falsifiable two ways: reintroducing
#    `need docker` re-adds the docker die; re-baking a cred secretKeyRef re-arms the prompts.
FAKEBIN="$(mktemp -d)"
for t in claude gh gcloud; do printf '#!/usr/bin/env bash\nexit 0\n' > "$FAKEBIN/$t"; chmod +x "$FAKEBIN/$t"; done
# docker is deliberately absent from FAKEBIN — it must NOT be required by cloud preflight.
OUT5="$(PATH="$FAKEBIN:/usr/bin:/bin" bash "$S" --cloud --repo acme/widgets </dev/null 2>&1)"; rc5=$?
printf '%s' "$OUT5" | grep -q "missing 'docker'" && bad "cloud preflight still requires docker" || ok "cloud preflight requires NO docker"
printf '%s' "$OUT5" | grep -q 'Paste the CLAUDE_CODE_OAUTH_TOKEN' && bad "multi-tenant cloud STILL prompts for a token (setup-token leak hazard)" || ok "multi-tenant cloud prompts for NO token"
printf '%s' "$OUT5" | grep -q 'mint a ~1-year subscription token' && bad "multi-tenant cloud STILL runs claude setup-token (prints a live token)" || ok "multi-tenant cloud does NOT run claude setup-token"
printf '%s' "$OUT5" | grep -q 'legacy secret mint skipped' && ok "multi-tenant cloud prints the skip note (passed preflight, reached arch_b)" || bad "no multi-tenant skip note (did not reach arch_b past preflight)"
rm -rf "$FAKEBIN"

# 7. FALSIFIER — a manifest that DOES mount the legacy cred secretKeyRefs (single-tenant path)
#    STILL prompts for the tokens. Build a temp manifest carrying heimdall-cc-oauth-token /
#    heimdall-pr-bot-token secretKeyRefs; a non-dry --cloud run against it must reach the OAuth
#    mint prompt (auto-detect keeps the legacy path intact when the mounts ARE present).
LEGYAML="$(mktemp)"; cp "$YAML" "$LEGYAML"
cat >> "$LEGYAML" <<'YML'
                - name: CLAUDE_CODE_OAUTH_TOKEN
                  valueFrom:
                    secretKeyRef:
                      name: heimdall-cc-oauth-token
                      key: latest
                - name: HEIMDALL_PR_BOT_TOKEN
                  valueFrom:
                    secretKeyRef:
                      name: heimdall-pr-bot-token
                      key: latest
YML
FB7="$(mktemp -d)"
for t in claude gh gcloud; do printf '#!/usr/bin/env bash\nexit 0\n' > "$FB7/$t"; chmod +x "$FB7/$t"; done
OUT7="$(PATH="$FB7:/usr/bin:/bin" HEIMDALL_MAINTAINER_JOB_YAML="$LEGYAML" bash "$S" --cloud --repo acme/widgets </dev/null 2>&1)"
printf '%s' "$OUT7" | grep -q 'Paste the CLAUDE_CODE_OAUTH_TOKEN' && ok "legacy-mount manifest STILL prompts for tokens (single-tenant path preserved)" || bad "legacy-mount manifest did NOT prompt (auto-detect over-skipped)"
rm -rf "$FB7"

# 8. CLEAN ARGV — the mksecret + iam-role helpers must invoke gcloud with a CLEAN argv; the
#    "(|| exists)" annotation is DISPLAY-ONLY and must NEVER reach the executed command (the
#    live break was `gcloud ... (|| exists): command not found`). Run non-dry --cloud against a
#    legacy manifest (real-looking digest so the full arch_b path runs) with a LOGGING fake
#    gcloud; assert the recorded argv is verbatim-clean and carries NO annotation token.
LEGYAML2="$(mktemp)"; sed 's/@sha256:REPLACE_WITH_DIGEST/@sha256:'"$(printf 'a%.0s' {1..64})"'/' "$LEGYAML" > "$LEGYAML2"
FB8="$(mktemp -d)"; ARGLOG="$(mktemp)"; : > "$ARGLOG"
for t in claude gh; do printf '#!/usr/bin/env bash\nexit 0\n' > "$FB8/$t"; chmod +x "$FB8/$t"; done
cat > "$FB8/gcloud" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$ARGLOG"
exit 0
EOF
chmod +x "$FB8/gcloud"
printf 'oauthval\nbotval\n' | PATH="$FB8:/usr/bin:/bin" HEIMDALL_MAINTAINER_JOB_YAML="$LEGYAML2" bash "$S" --cloud --repo acme/widgets >/dev/null 2>&1; rc8=$?
[ "$rc8" = 0 ] && ok "legacy full cloud path completes exit 0 (clean argv, no command-not-found)" || bad "legacy full cloud path rc=$rc8 (mksecret/iam broke)"
grep -qE '^secrets create heimdall-cc-oauth-token --replication-policy=automatic --project=heimdall-cp-prod$' "$ARGLOG" && ok "mksecret runs gcloud with CLEAN argv (secret create logged verbatim)" || bad "mksecret create argv missing/garbled"
grep -qE '^iam roles create heimdallJobRunner --project=heimdall-cp-prod --permissions=run\.jobs\.run$' "$ARGLOG" && ok "iam-role create runs gcloud with CLEAN argv (no annotation)" || bad "iam-role create argv missing/garbled"
grep -qE '\(\|\||exists\)' "$ARGLOG" && bad "annotation '(|| exists)' LEAKED into executed gcloud argv" || ok "no '(|| exists)' annotation in any executed gcloud argv"
rm -rf "$FB8" "$ARGLOG" "$LEGYAML" "$LEGYAML2"

echo "──────────"; echo "deploy-maintainer: $P passed, $F failed"
[ "$F" = 0 ] || exit 1
