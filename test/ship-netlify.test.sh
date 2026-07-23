#!/usr/bin/env bash
#
# ship-netlify.test.sh — acceptance for release/sync-release.sh's Netlify-site sync.
#
#   bash test/ship-netlify.test.sh    (exit 0 = all cases pass)
#
# runheimdall.dev/install is a 302 served by Netlify from the SEPARATE
# randomittin/heimdall-site repo (heimdall-site/netlify.toml). Its pinned <TAG>
# drifts unless bumped every ship. release/sync-release.sh now bumps it in lockstep.
# This proves, WITHOUT touching the real plugin repo or the real site, that sync:
#
#   1. rewrites netlify.toml's /install `to` URL tag to the release tag, and the
#      sha256 in the comment to the SAME digest it bakes into the npx wrapper
#      (reused, never recomputed divergently);
#   2. commits ONLY netlify.toml and PUSHES origin main (Netlify auto-deploy);
#   3. is IDEMPOTENT — re-running the same tag makes no new commit;
#   4. WARNs and CONTINUES (exit 0, no die) when the site checkout is ABSENT,
#      printing the exact manual bump+push;
#   5. DIES (non-zero) when a present netlify.toml has no /install redirect — the
#      assertion CAN fail (R6: a check that cannot fail proves nothing).
#
# Hermetic: sync-release.sh is copied into a throwaway fake plugin repo with the
# minimal artifacts it requires, so a real (non-dry) run — including the site
# commit+push — never mutates the developer's working tree. The fake site pushes to
# a local bare remote, so case 2 needs no network.
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SELF_DIR/.." && pwd)"
SYNC_SRC="$REPO/release/sync-release.sh"

PASS=0; FAIL=0
ok()  { printf '  \033[32mPASS\033[0m %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAIL=$((FAIL+1)); }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/ship-netlify-test.XXXXXX")"
cleanup() { rm -rf "$WORK" 2>/dev/null || true; }
trap cleanup EXIT

echo "ship-netlify harness  sync=$SYNC_SRC"
echo "--------------------------------------------------------------------"

OLD_TAG="v0.0.1"
OLD_SHA="0000000000000000000000000000000000000000000000000000000000000000"
NEW_TAG="v9.9.9"
RAW="https://raw.githubusercontent.com/randomittin/heimdall"

# ── Build a throwaway fake PLUGIN repo carrying only what sync-release requires ─
make_fake_plugin() {  # $1 = dest dir
  local d="$1"
  mkdir -p "$d/release" "$d/packages/runheimdall" "$d/.claude-plugin"
  cp "$SYNC_SRC" "$d/release/sync-release.sh"
  printf '{"redirects":[{"source":"/install","destination":"%s/%s/install.sh","permanent":true}]}\n' \
    "$RAW" "$OLD_TAG" > "$d/vercel.json"
  printf '/install  %s/%s/install.sh  301\n' "$RAW" "$OLD_TAG" > "$d/_redirects"
  printf '# Heimdall\n\nInstall: %s/%s/install.sh\n' "$RAW" "$OLD_TAG" > "$d/README.md"
  printf '#!/usr/bin/env bash\ninstall() {\n  local DEFAULT_REF="%s"\n  echo "$DEFAULT_REF"\n}\n' "$OLD_TAG" > "$d/install.sh"
  printf '{"version":"0.0.1","heimdall":{"tag":"%s","installScriptUrl":"%s/%s/install.sh","sha256":"%s"}}\n' \
    "$OLD_TAG" "$RAW" "$OLD_TAG" "$OLD_SHA" > "$d/packages/runheimdall/package.json"
  printf '{"version":"0.0.1"}\n' > "$d/.claude-plugin/plugin.json"
}

# ── Build a fake heimdall-site repo (git, with a local bare remote to push to) ─
make_fake_site() {  # $1 = site dir, $2 = bare remote dir
  local site="$1" bare="$2"
  mkdir -p "$site"
  cat > "$site/netlify.toml" <<TOML
[build]
  publish = "."

# The tag below is PINNED and must be bumped on each Heimdall release. Current
# release: ${OLD_TAG} (install.sh sha256 ${OLD_SHA}).
[[redirects]]
  from = "/install"
  to = "${RAW}/${OLD_TAG}/install.sh"
  status = 302
  force = true
TOML
  git init -q "$site"
  git -C "$site" config user.email test@heimdall.local
  git -C "$site" config user.name "Heimdall Test"
  git -C "$site" add -A
  git -C "$site" commit -q -m "initial site"
  git -C "$site" branch -M main
  git init -q --bare "$bare"
  git -C "$site" remote add origin "$bare"
  git -C "$site" push -q -u origin main
}

netlify_to_tag() {  # $1 = netlify.toml -> echo the tag pinned in the /install `to` URL
  sed -nE 's|.*randomittin/heimdall/(v[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.]+)?)/install\.sh.*|\1|p' "$1" | head -1
}
netlify_comment_sha() {  # $1 = netlify.toml -> echo the sha256 noted in the comment
  sed -nE 's|.*install\.sh sha256 ([0-9a-f]{64}).*|\1|p' "$1" | head -1
}

# ── Case 1+2+3: present site — bump, commit, push, idempotent ────────────────
PLUG="$WORK/plugin1"; SITE="$WORK/site1"; BARE="$WORK/site1.git"
make_fake_plugin "$PLUG"
make_fake_site "$SITE" "$BARE"

C1="$WORK/c1.out"
HEIMDALL_SITE_DIR="$SITE" bash "$PLUG/release/sync-release.sh" "$NEW_TAG" >"$C1" 2>&1
c1_rc=$?

if [ "$c1_rc" -eq 0 ]; then ok "sync exits 0 with a present site"; else bad "sync exit=$c1_rc"; sed 's/^/    /' "$C1" >&2; fi

if [ "$(netlify_to_tag "$SITE/netlify.toml")" = "$NEW_TAG" ]; then
  ok "netlify.toml /install -> ${NEW_TAG} (tag bumped)"
else
  bad "netlify.toml tag not bumped (got '$(netlify_to_tag "$SITE/netlify.toml")')"
fi

# The sha the wrapper baked in == the sha written into netlify.toml's comment.
WRAP_SHA="$(jq -r '.heimdall.sha256' "$PLUG/packages/runheimdall/package.json")"
if [ -n "$WRAP_SHA" ] && [ "$WRAP_SHA" != "$OLD_SHA" ] \
   && [ "$(netlify_comment_sha "$SITE/netlify.toml")" = "$WRAP_SHA" ]; then
  ok "netlify.toml comment sha256 == wrapper sha256 (reused, not recomputed)"
else
  bad "netlify.toml sha mismatch (wrapper='$WRAP_SHA' comment='$(netlify_comment_sha "$SITE/netlify.toml")')"
fi

if git -C "$SITE" log -1 --pretty=%s | grep -Fxq "chore(netlify): pin /install -> ${NEW_TAG}"; then
  ok "site HEAD is the path-scoped 'chore(netlify): pin /install -> ${NEW_TAG}' commit"
else
  bad "expected chore(netlify) commit at site HEAD (got '$(git -C "$SITE" log -1 --pretty=%s)')"
fi

# Pushed: origin/main == local HEAD on the bare remote.
if [ "$(git -C "$SITE" rev-parse HEAD)" = "$(git -C "$SITE" rev-parse origin/main 2>/dev/null)" ]; then
  ok "site pushed to origin main (Netlify would auto-deploy)"
else
  bad "site was not pushed to origin main"
fi

COMMITS_AFTER_1="$(git -C "$SITE" rev-list --count HEAD)"

# Idempotent re-run: same tag -> no new commit.
C3="$WORK/c3.out"
HEIMDALL_SITE_DIR="$SITE" bash "$PLUG/release/sync-release.sh" "$NEW_TAG" >"$C3" 2>&1
COMMITS_AFTER_2="$(git -C "$SITE" rev-list --count HEAD)"
if [ "$COMMITS_AFTER_2" = "$COMMITS_AFTER_1" ] && grep -q 'already pinned' "$C3"; then
  ok "idempotent: re-running ${NEW_TAG} makes no new site commit"
else
  bad "re-run was not idempotent (commits $COMMITS_AFTER_1 -> $COMMITS_AFTER_2)"; sed 's/^/    /' "$C3" >&2
fi

# ── Case 4: absent site — WARN + manual hint, but sync still exits 0 ──────────
PLUG2="$WORK/plugin2"; make_fake_plugin "$PLUG2"
C4="$WORK/c4.out"
HEIMDALL_SITE_DIR="$WORK/does-not-exist" bash "$PLUG2/release/sync-release.sh" "$NEW_TAG" >"$C4" 2>&1
c4_rc=$?
if [ "$c4_rc" -eq 0 ]; then
  ok "absent site: sync exits 0 (a missing checkout does NOT fail the release)"
else
  bad "absent site made sync exit non-zero (rc=$c4_rc)"; sed 's/^/    /' "$C4" >&2
fi
if grep -q 'heimdall-site checkout not found' "$C4" \
   && grep -q "chore(netlify): pin /install -> ${NEW_TAG}" "$C4" \
   && grep -q 'git push origin main' "$C4"; then
  ok "absent site: prints the exact manual bump+push instructions"
else
  bad "absent site: manual hint missing/incomplete"; sed 's/^/    /' "$C4" >&2
fi

# ── Case 5: present-but-unpinnable netlify.toml -> DIE (assertion can fail) ───
PLUG3="$WORK/plugin3"; SITE3="$WORK/site3"; make_fake_plugin "$PLUG3"
mkdir -p "$SITE3"
# No [[redirects]] /install block at all — the assertion must NOT find the tag.
printf '[build]\n  publish = "."\n# no install redirect here\n' > "$SITE3/netlify.toml"
C5="$WORK/c5.out"
HEIMDALL_SITE_DIR="$SITE3" bash "$PLUG3/release/sync-release.sh" "$NEW_TAG" >"$C5" 2>&1
c5_rc=$?
if [ "$c5_rc" -ne 0 ] && grep -q 'ASSERT FAILED: netlify.toml /install -> tag target' "$C5"; then
  ok "unpinnable netlify.toml DIES non-zero (drift assertion can fail — R6)"
else
  bad "unpinnable netlify.toml did not hard-fail (rc=$c5_rc)"; sed 's/^/    /' "$C5" >&2
fi

echo ""
echo "ship-netlify.test.sh: $PASS passed, $FAIL failed."
[ "$FAIL" -eq 0 ] || exit 1
exit 0
