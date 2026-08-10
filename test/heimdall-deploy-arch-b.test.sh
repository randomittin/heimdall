#!/usr/bin/env bash
# heimdall-deploy-arch-b.test.sh — proves deploy/cloud-run/deploy-arch-b.sh does ALL of
# Arch B as ONE command, statically + hermetically ($0, NO gcloud/docker/creds, no network):
#
#   A. SYNTAX: `bash -n` is clean on deploy-arch-b.sh AND deploy-maintainer.sh (both scripts).
#   B. DRY-RUN NEEDS NO CREDS: fake gcloud+docker shims that FAIL-on-invoke are prepended to
#      PATH; the --dry-run run must EXIT 0 and NEVER invoke either (the whole plan is printed).
#   C. FULL PLAN PRINTED, IN ORDER: AR create -> gcloud builds submit (Cloud Build, -f
#      Dockerfile.maintainer — NO local docker) -> digest resolve (image_summary.digest) ->
#      yaml @sha256 pin -> deploy-maintainer.sh --cloud -> jobs describe. The plan runs NO
#      local `docker build`/`docker push` (the deployability-without-docker guarantee).
#   D. PIN STEP IS PRESENT: the script backs up the yaml and seds the heimdall-maintainer@sha256
#      image line in place (grep-provable in the source).
#   E. REUSE, NOT DUPLICATE: the deploy step delegates to deploy-maintainer.sh --cloud; this
#      script handles NO token (no read -rs / no *_TOKEN var / no claude setup-token here).
#   F. BAD --repo REJECTED: a non `owner/name` value fails fast (nonzero) before any side effect.
#   G. NO SECRET ECHOED: no sk-ant / ghs token literal appears anywhere in the dry-run output.
#   H. DOCKERFILE TOOLCHAIN: Dockerfile.maintainer installs git + gh + the claude CLI + the
#      pinned python deps + the heimdall bins (grep-provable).
#
# Exit 0 = every proof holds. Nonzero = a proof failed (prints which).
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
CR="$ROOT/deploy/cloud-run"
ARCHB="$CR/deploy-arch-b.sh"
MAINT="$CR/deploy-maintainer.sh"
DOCKERFILE="$CR/Dockerfile.maintainer"
YAML="$CR/heimdall-maintainer-job.yaml"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf "  \033[32mPASS\033[0m %s\n" "$1"; }
bad() { FAIL=$((FAIL+1)); printf "  \033[31mFAIL\033[0m %s\n" "$1"; }

echo "== A. syntax: bash -n both scripts =="
bash -n "$ARCHB" 2>/dev/null && ok "deploy-arch-b.sh: bash -n clean" || bad "deploy-arch-b.sh: bash -n FAILED"
bash -n "$MAINT" 2>/dev/null && ok "deploy-maintainer.sh: bash -n clean" || bad "deploy-maintainer.sh: bash -n FAILED"

echo "== B. dry-run needs NO creds (fake gcloud/docker must never be invoked) =="
SHIMDIR="$(mktemp -d)"; SENTINEL="$SHIMDIR/invoked"
for tool in gcloud docker; do
  cat > "$SHIMDIR/$tool" <<SH
#!/usr/bin/env bash
echo "$tool INVOKED: \$*" >> "$SENTINEL"
exit 1
SH
  chmod +x "$SHIMDIR/$tool"
done
OUT="$(PATH="$SHIMDIR:$PATH" "$ARCHB" --repo acme/widgets --project heimdall-cp-prod --dry-run 2>&1)"; RC=$?
[ "$RC" = 0 ] && ok "dry-run exited 0 with no real gcloud/docker on PATH" || bad "dry-run exited $RC (expected 0)"
[ ! -f "$SENTINEL" ] && ok "dry-run invoked NEITHER gcloud NOR docker (no creds/side effects)" \
  || bad "dry-run INVOKED a real tool: $(cat "$SENTINEL" 2>/dev/null)"

echo "== C. the FULL Arch-B plan is printed, in order =="
has() { grep -qF "$1" <<<"$OUT" && ok "plan shows: $2" || bad "plan MISSING: $2"; }
hasre() { grep -qE "$1" <<<"$OUT" && ok "plan shows: $2" || bad "plan MISSING: $2"; }
hasre 'artifacts repositories create heimdall'                 "b. AR repo create (|| exists)"
has  'gcloud builds submit'                                    "c. Cloud Build submit (no local docker)"
has  'Dockerfile.maintainer'                                   "c. builds the maintainer Dockerfile via Cloud Build"
has  "image_summary.digest"                                    "d. digest resolve (image_summary.digest)"
hasre 'heimdall-maintainer@sha256:'                            "d. yaml image @sha256 pin target"
has  'deploy-maintainer.sh --cloud'                            "e. REUSE deploy-maintainer.sh --cloud"
hasre 'run jobs describe heimdall-maintainer-job'              "f. verify jobs describe"
# the docker->Cloud Build switch: the plan must NOT run a LOCAL docker build/push (falsifiable:
# a reverted script that shells out to `$ docker build`/`$ docker push` fails this).
if grep -qE '\$ docker (build|push)' <<<"$OUT"; then
  bad "c. plan still runs LOCAL docker build/push (must build on Cloud Build)"
else
  ok "c. plan runs NO local docker build/push (Cloud Build only — deployable without docker)"
fi
# ordering: Cloud Build submit precedes digest-pin precedes deploy precedes verify
order_ok=1
cb=$(grep -n 'gcloud builds submit' <<<"$OUT" | head -1 | cut -d: -f1)
pin=$(grep -n 'image_summary.digest' <<<"$OUT" | head -1 | cut -d: -f1)
dep=$(grep -n 'deploy-maintainer.sh --cloud' <<<"$OUT" | head -1 | cut -d: -f1)
ver=$(grep -n 'run jobs describe' <<<"$OUT" | head -1 | cut -d: -f1)
[ -n "$cb" ] && [ -n "$pin" ] && [ -n "$dep" ] && [ -n "$ver" ] \
  && [ "$cb" -lt "$pin" ] && [ "$pin" -lt "$dep" ] && [ "$dep" -lt "$ver" ] || order_ok=0
[ "$order_ok" = 1 ] && ok "plan order: cloud-build < digest-pin < deploy < verify" || bad "plan steps out of order (cb=$cb pin=$pin dep=$dep ver=$ver)"

echo "== D. the yaml digest-pin step is present in the source =="
grep -qE 'cp "\$YAML" "\$\{YAML\}\.bak"' "$ARCHB" && ok "D backs up the manifest before pinning" || bad "D no manifest backup before pin"
grep -qE "sed -i.*\-E .*\\\$\{IMAGE_NAME\}@sha256:" "$ARCHB" && ok "D seds the heimdall-maintainer@sha256 image line in place" || bad "D no in-place @sha256 sed pin"

echo "== E. reuses deploy-maintainer.sh --cloud; handles NO secret here =="
grep -qE '"\$DEPLOY_MAINTAINER" "\$\{DM_ARGS\[@\]\}"' "$ARCHB" && ok "E delegates deploy to deploy-maintainer.sh" || bad "E does not delegate to deploy-maintainer.sh"
if grep -qE 'read -rs|read -r -s|CLAUDE_CODE_OAUTH_TOKEN|HEIMDALL_PR_BOT_TOKEN|ANTHROPIC_API_KEY|setup-token|_TOKEN=' "$ARCHB"; then
  bad "E deploy-arch-b.sh handles token material (must live ONLY in deploy-maintainer.sh)"
else
  ok "E deploy-arch-b.sh contains NO token handling (secret logic stays in deploy-maintainer.sh)"
fi

echo "== F. a bad --repo is rejected (fail-closed) =="
if "$ARCHB" --repo not-a-slug --dry-run >/dev/null 2>&1; then
  bad "F accepted a malformed --repo (must reject non owner/name)"
else
  ok "F rejected malformed --repo before any side effect"
fi

echo "== G. no secret literal echoed in the dry-run output =="
if grep -qE 'sk-ant-(oat|api)|ghs-[A-Za-z0-9]' <<<"$OUT"; then
  bad "G a token-shaped literal appeared in the plan output"
else
  ok "G no sk-ant / ghs token literal anywhere in the dry-run plan"
fi

echo "== H. Dockerfile.maintainer toolchain (git + gh + claude + python deps + heimdall) =="
dgrep() { grep -qE "$1" "$DOCKERFILE" && ok "Dockerfile: $2" || bad "Dockerfile MISSING: $2"; }
dgrep 'install .*-y[^\n]* git|-y \\\n *bash \\\n *git|^ *git \\\\?$| git '   "installs git"
grep -qE '\bgit\b' "$DOCKERFILE" && grep -qE 'install .*gh|apt-get install .*-y gh| gh \\?$|githubcli' "$DOCKERFILE" && ok "Dockerfile: installs gh (GitHub CLI)" || bad "Dockerfile MISSING: gh"
dgrep '@anthropic-ai/claude-code'                              "installs the claude CLI (npm @anthropic-ai/claude-code)"
dgrep 'google-cloud-firestore==2.16.1'                         "pins google-cloud-firestore (runtime dep)"
dgrep 'cryptography==42.0.8'                                    "pins cryptography (Ed25519 backend)"
dgrep 'COPY bin/ /app/bin/'                                    "copies the heimdall bins onto the image"
dgrep 'claude --version'                                       "build-time toolchain gate (claude --version)"
dgrep 'pip install .*pytest|pytest==[0-9]'                     "installs the base test toolchain (pytest) — SI-2 gate runs a repo's tests (bug #24)"
dgrep 'import pytest|pytest --version'                         "build-time gate proves pytest is present"

echo
echo "deploy-arch-b: $PASS passed, $FAIL failed"
rm -rf "$SHIMDIR"
[ "$FAIL" -eq 0 ] || exit 1
