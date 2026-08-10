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
grep -q 'gcloud run jobs replace' <<<"$OUT" && ok "prints Arch-B job replace plan" || bad "no job-replace in plan"
grep -q 'runner-beat --repo acme/widgets' <<<"$OUT" && ok "prints Arch-A runner-beat plan" || bad "no runner-beat"
grep -qi 'NEVER pushes main' <<<"$OUT" && ok "constraint banner present" || bad "no constraint banner"
grep -q 'nothing executed' <<<"$OUT" && ok "dry-run executes nothing" || bad "no dry-run marker"

# 2. missing/bad --repo rejected
bash "$S" --dry-run --hybrid 2>/dev/null; [ $? -ne 0 ] && ok "missing --repo rejected" || bad "missing repo accepted"
bash "$S" --dry-run --hybrid --repo not-a-slug 2>/dev/null; [ $? -ne 0 ] && ok "bad --repo slug rejected" || bad "bad slug accepted"

# 3. no token VALUE on stdout (dry-run prompts skipped; a fake token in env must not surface)
OUT2="$(OAUTH_TOKEN=SECRET-XYZ BOT_TOKEN=SECRET-XYZ bash "$S" --dry-run --cloud --repo acme/widgets 2>&1)"
grep -q 'SECRET-XYZ' <<<"$OUT2" && bad "token value leaked to stdout" || ok "no token value on stdout"

# 4. --local mode omits gcloud from the plan's Arch-A section start
OUT3="$(bash "$S" --dry-run --local --repo acme/widgets 2>&1)"; grep -q 'Arch A' <<<"$OUT3" && ok "local mode plans Arch A" || bad "local mode missing"

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
grep -q "missing 'docker'" <<<"$OUT5" && bad "cloud preflight still requires docker" || ok "cloud preflight requires NO docker"
grep -q 'Paste the CLAUDE_CODE_OAUTH_TOKEN' <<<"$OUT5" && bad "multi-tenant cloud STILL prompts for a token (setup-token leak hazard)" || ok "multi-tenant cloud prompts for NO token"
grep -q 'mint a ~1-year subscription token' <<<"$OUT5" && bad "multi-tenant cloud STILL runs claude setup-token (prints a live token)" || ok "multi-tenant cloud does NOT run claude setup-token"
grep -q 'legacy secret mint skipped' <<<"$OUT5" && ok "multi-tenant cloud prints the skip note (passed preflight, reached arch_b)" || bad "no multi-tenant skip note (did not reach arch_b past preflight)"
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
grep -q 'Paste the CLAUDE_CODE_OAUTH_TOKEN' <<<"$OUT7" && ok "legacy-mount manifest STILL prompts for tokens (single-tenant path preserved)" || bad "legacy-mount manifest did NOT prompt (auto-detect over-skipped)"
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

# 9. MACHINE-SCOPED SANDBOX GUARD — the dormant twin of the launchd incident.
#    `crontab` keys off the OS USER (getuid), NOT $HOME. A suite running under
#    HOME=$(mktemp -d) therefore believes it is sandboxed while `crontab <file>` rewrites
#    the DEVELOPER'S REAL crontab — the identical shape as the launchd bug that silently
#    repointed the live nightly job at an ephemeral agent worktree. arch_a must REFUSE
#    under a synthetic HOME, exit 4 (distinct from a failure), print the state word
#    `sandboxed`, and touch NOTHING — not even `crontab -l`, whose failure is precisely
#    how the destructive-read bug manifested.
#
#    HERMETIC: `crontab` is a RECORDING STUB and the PATH handed to the script under test
#    is "$SBX_STUB:/usr/bin:/bin" — /usr/bin/crontab is shadowed by the stub, so the real
#    crontab binary can never be invoked by any exercise below. Every invocation (READ and
#    INSTALL alike) is appended to $SBX_LOG, so "zero invocations" is a positive assertion
#    over a file rather than an absence of evidence.
RROOT="$(cd "$(dirname "$S")/../.." && pwd)"
SBX_STUB="$(mktemp -d)"; SBX_LOG="$SBX_STUB/crontab.invocations"; : > "$SBX_LOG"
for t in gh gcloud; do printf '#!/usr/bin/env bash\nexit 0\n' > "$SBX_STUB/$t"; chmod +x "$SBX_STUB/$t"; done
# `claude` is a RECORDING stub too: collect_secrets runs `claude setup-token`, which mints a
# ~1-year credential into the KEYCHAIN — account-scoped state $HOME does not isolate either.
# A sandboxed run must refuse BEFORE minting one, so the refusal has to precede collect_secrets.
CLAUDE_LOG="$SBX_STUB/claude.invocations"; : > "$CLAUDE_LOG"
cat > "$SBX_STUB/claude" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$CLAUDE_LOG"
exit 0
EOF
chmod +x "$SBX_STUB/claude"
cat > "$SBX_STUB/crontab" <<EOF
#!/usr/bin/env bash
# RECORDING STUB — logs EVERY invocation, the READ included. Never touches a real crontab.
if [ "\${1:-}" = "-l" ]; then
  printf 'READ\n' >> "$SBX_LOG"
  cat "$SBX_STUB/current.cron" 2>/dev/null
  exit 0
fi
printf 'INSTALL %s\n' "\$1" >> "$SBX_LOG"
cp "\$1" "$SBX_STUB/installed.cron"
exit 0
EOF
chmod +x "$SBX_STUB/crontab"
printf '0 3 * * * /usr/local/bin/backup-db.sh\n' > "$SBX_STUB/current.cron"

# 9a. SYNTHETIC HOME → the real crontab is NEVER touched. This is the assertion that
#     would have prevented the incident. --local drives arch_a with no gcloud needed.
SBX_HOME="$(mktemp -d)"
OUT9="$(printf 'oauthval\nbotval\n' | env -u HEIMDALL_REAL_HOME HOME="$SBX_HOME" \
  PATH="$SBX_STUB:/usr/bin:/bin" bash "$S" --local --repo acme/widgets 2>&1)"; rc9=$?
[ "$rc9" = 4 ] && ok "synthetic HOME: refused with the DISTINCT exit 4 (refusal, not failure)" \
  || bad "synthetic HOME: rc=$rc9 (expected 4 — operator cannot tell refusal from breakage)"
grep -q 'sandboxed' <<<"$OUT9" && ok "synthetic HOME: prints the state word 'sandboxed'" \
  || bad "synthetic HOME: no 'sandboxed' state word in output"
[ ! -s "$SBX_LOG" ] && ok "synthetic HOME: crontab invoked ZERO times — not even 'crontab -l'" \
  || bad "synthetic HOME: THE REAL CRONTAB WAS REACHED — $(tr '\n' ';' < "$SBX_LOG")"
[ ! -f "$SBX_STUB/installed.cron" ] && ok "synthetic HOME: no crontab content was written" \
  || bad "synthetic HOME: DESTRUCTIVE — a crontab was installed anyway"
[ ! -f "$SBX_HOME/.heimdall/maintainer.env" ] \
  && ok "synthetic HOME: refusal was TOTAL AND EARLY (no env file, no smoke cycle)" \
  || bad "synthetic HOME: side effects ran before the refusal (env file exists)"
grep -q 'passwd home' <<<"$OUT9" && ok "synthetic HOME: states WHY (passwd-home mismatch)" \
  || bad "synthetic HOME: refusal gives no diagnosable reason"
[ ! -s "$CLAUDE_LOG" ] \
  && ok "synthetic HOME: 'claude setup-token' NEVER ran (no ~1y keychain credential minted)" \
  || bad "synthetic HOME: claude was invoked before the refusal — $(tr '\n' ';' < "$CLAUDE_LOG")"

# 9b. --hybrid reaches arch_a too — the default MODE, so the plain-run path is covered.
: > "$SBX_LOG"; rm -f "$SBX_STUB/installed.cron"
SBX_HOME2="$(mktemp -d)"
OUT9H="$(printf 'oauthval\nbotval\n' | env -u HEIMDALL_REAL_HOME HOME="$SBX_HOME2" \
  PATH="$SBX_STUB:/usr/bin:/bin" bash "$S" --hybrid --repo acme/widgets 2>&1)"; rc9h=$?
[ "$rc9h" = 4 ] && ok "synthetic HOME (--hybrid, the DEFAULT mode): refused with exit 4" \
  || bad "synthetic HOME (--hybrid): rc=$rc9h (expected 4)"
[ ! -s "$SBX_LOG" ] && ok "synthetic HOME (--hybrid): crontab invoked ZERO times" \
  || bad "synthetic HOME (--hybrid): real crontab reached — $(tr '\n' ';' < "$SBX_LOG")"

# 9c. REAL OPERATOR → the cron entry STILL installs. That is the point of the guard: it
#     must refuse a sandbox WITHOUT refusing the operator. Driven through a fake ROOT so
#     the smoke `heimdall-maintain-loop` calls hit a stub instead of running a real
#     maintainer cycle (which opens PRs). HEIMDALL_REAL_HOME is real-home.sh's documented
#     test seam: it overrides ONLY the resolved passwd home, so the run self-identifies as
#     the real user while `crontab` still resolves to the stub on PATH.
FR="$(mktemp -d)"; mkdir -p "$FR/deploy/cloud-run" "$FR/bin/lib"
cp "$S" "$FR/deploy/cloud-run/deploy-maintainer.sh"; chmod +x "$FR/deploy/cloud-run/deploy-maintainer.sh"
cp "$RROOT/bin/lib/crontab-safe.sh" "$RROOT/bin/lib/real-home.sh" "$FR/bin/lib/"
LOOPLOG="$FR/loop.log"
cat > "$FR/bin/heimdall-maintain-loop" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$LOOPLOG"
exit 0
EOF
chmod +x "$FR/bin/heimdall-maintain-loop"
cmp -s "$S" "$FR/deploy/cloud-run/deploy-maintainer.sh" \
  && ok "positive branch runs a BYTE-IDENTICAL copy of the shipped script (cannot drift)" \
  || bad "positive-branch copy differs from the shipped script"
: > "$SBX_LOG"; rm -f "$SBX_STUB/installed.cron"; : > "$CLAUDE_LOG"
POS_HOME="$(mktemp -d)"
OUT9P="$(printf 'oauthval\nbotval\n' | env HOME="$POS_HOME" HEIMDALL_REAL_HOME="$POS_HOME" \
  PATH="$SBX_STUB:/usr/bin:/bin" bash "$FR/deploy/cloud-run/deploy-maintainer.sh" \
  --local --repo acme/widgets 2>&1)"; rc9p=$?
[ "$rc9p" = 0 ] && ok "real operator: deploy completes exit 0 (guard does NOT block a real install)" \
  || bad "real operator: rc=$rc9p — the guard BLOCKED a legitimate install: $(printf '%s' "$OUT9P" | tail -3 | tr '\n' ' ')"
grep -q '^INSTALL ' "$SBX_LOG" && ok "real operator: the crontab install DID run" \
  || bad "real operator: no crontab install recorded — the deploy silently did nothing"
grep -q 'heimdall-maintainer-beat' "$SBX_STUB/installed.cron" 2>/dev/null \
  && ok "real operator: runner-beat entry written to the crontab" \
  || bad "real operator: runner-beat entry MISSING from the installed crontab"
grep -q 'heimdall-maintainer-cycle' "$SBX_STUB/installed.cron" 2>/dev/null \
  && ok "real operator: cycle entry written to the crontab" \
  || bad "real operator: cycle entry MISSING from the installed crontab"
grep -q 'backup-db.sh' "$SBX_STUB/installed.cron" 2>/dev/null \
  && ok "real operator: the unrelated job was PRESERVED (safe-replace still applies)" \
  || bad "real operator: an unrelated crontab job was LOST"
grep -q 'setup-token' "$CLAUDE_LOG" \
  && ok "real operator: 'claude setup-token' STILL runs (the mint path is untouched)" \
  || bad "real operator: setup-token no longer runs — the guard broke the token mint"

# 9d. The guard must not OVER-fire: --dry-run needs no creds, touches nothing, and must
#     still print the cron plan under a synthetic HOME (an over-guard is churn that hides
#     real ones). Falsifiable: gating dry-run too turns these three RED.
: > "$SBX_LOG"
DRY_HOME="$(mktemp -d)"
OUT9D="$(env -u HEIMDALL_REAL_HOME HOME="$DRY_HOME" PATH="$SBX_STUB:/usr/bin:/bin" \
  bash "$S" --dry-run --hybrid --repo acme/widgets </dev/null 2>&1)"; rc9d=$?
[ "$rc9d" = 0 ] && ok "--dry-run under a synthetic HOME still exits 0 (guard does not over-fire)" \
  || bad "--dry-run under a synthetic HOME rc=$rc9d (the guard over-fired)"
grep -q 'crontab: add (dedup on marker)' <<<"$OUT9D" \
  && ok "--dry-run still prints the cron plan under a synthetic HOME" \
  || bad "--dry-run no longer prints the cron plan"
[ ! -s "$SBX_LOG" ] && ok "--dry-run invoked crontab ZERO times" \
  || bad "--dry-run invoked crontab: $(tr '\n' ';' < "$SBX_LOG")"

# 9e. NO DRIFT — the guard must REUSE bin/lib/real-home.sh, never re-implement it. A second
#     copy of the passwd lookup would drift from the launchd side, and a drifted guard is an
#     unguarded one. Falsifiable: inlining a getpwuid/dscl lookup here turns the third RED.
grep -q 'bin/lib/real-home.sh' "$S" && ok "sources the SHARED real-home lib (one definition)" \
  || bad "does not source bin/lib/real-home.sh"
grep -q 'heimdall_home_is_real' "$S" && ok "gates on the SHARED heimdall_home_is_real predicate" \
  || bad "never calls heimdall_home_is_real"
[ "$(grep -c 'getpwuid\|NFSHomeDirectory' "$S")" = 0 ] \
  && ok "carries NO second copy of the passwd lookup (cannot drift from real-home.sh)" \
  || bad "re-implements the passwd lookup locally — it WILL drift from real-home.sh"

rm -rf "$SBX_STUB" "$SBX_HOME" "$SBX_HOME2" "$FR" "$POS_HOME" "$DRY_HOME"

echo "──────────"; echo "deploy-maintainer: $P passed, $F failed"
[ "$F" = 0 ] || exit 1
