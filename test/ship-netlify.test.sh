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
#   6. `sync-release.sh --no-site-commit` (how release/ship.sh calls it) rewrites
#      netlify.toml but commits and pushes NOTHING: the commit moves to ship.sh.
#
# And release/ship.sh's SITE PINS. sync-release runs at the bump, before any tag
# exists, so it can neither check a digest against the tag nor run the site's own
# checks (they fetch the tag and ask for the latest Release). Once the tag is pushed
# and the Release is published, ship.sh's release_site_pins re-renders every pin with
# the REAL bin/heimdall-render-version, commits the tracked files that carry them
# together with netlify.toml, runs the REAL bin/heimdall-repo-checks and pushes. The
# cases below run it against a throwaway site repo (a local bare origin) and prove:
#
#   7. every version pin and every install.sh sha256 is rewritten in every tracked
#      pin-bearing file, and unmarked history is left alone;
#   8. the digest is the sha256 of `git show <tag>:install.sh` — the fixture edits
#      install.sh AFTER the tag, so a digest taken from the working tree fails here;
#   9. ONE commit holds exactly the pin-bearing files plus netlify.toml (an
#      untracked package-lock.json stays untracked), and the site's checks run after
#      that commit and BEFORE the push, whose receipt the push gate accepts;
#  10. re-running is a no-op;
#  11. a pin that would end up with a different sha256 REFUSES (non-zero, loud):
#      nothing is committed, checked or pushed;
#  12. an edit of the site owner's that is not a pin, in a page the commit would
#      carry, REFUSES; red site checks leave the commit local and unpushed, and a
#      re-run pushes it once they are green; a site off main REFUSES before any file
#      is touched; an absent site WARNs and the ship continues;
#  13. the wiring: ship.sh calls it after the Release and before the npm publish, and
#      calls sync-release with --no-site-commit.
#
# Hermetic: sync-release.sh is copied into a throwaway fake plugin repo with the
# minimal artifacts it requires, so a real (non-dry) run — including the site
# commit+push — never mutates the developer's working tree. The fake site pushes to
# a local bare remote, so case 2 needs no network. Every site here lives under the
# throwaway directory; HEIMDALL_SITE_DIR is always set, so the real site is never read.
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SELF_DIR/.." && pwd)"
SYNC_SRC="$REPO/release/sync-release.sh"

PASS=0; FAIL=0
ok()  { printf '  \033[32mPASS\033[0m %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAIL=$((FAIL+1)); }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/ship-netlify-test.XXXXXX")"
[ -n "$WORK" ] || { echo "FATAL: WORK path empty (mktemp failed)" >&2; exit 2; }
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
  mkdir -p "$d/release" "$d/packages/runheimdall" "$d/packages/runhmd" "$d/.claude-plugin"
  cp "$SYNC_SRC" "$d/release/sync-release.sh"
  printf '{"redirects":[{"source":"/install","destination":"%s/%s/install.sh","permanent":true}]}\n' \
    "$RAW" "$OLD_TAG" > "$d/vercel.json"
  printf '/install  %s/%s/install.sh  301\n' "$RAW" "$OLD_TAG" > "$d/_redirects"
  printf '# Heimdall\n\nInstall: %s/%s/install.sh\n' "$RAW" "$OLD_TAG" > "$d/README.md"
  printf '#!/usr/bin/env bash\ninstall() {\n  local DEFAULT_REF="%s"\n  echo "$DEFAULT_REF"\n}\n' "$OLD_TAG" > "$d/install.sh"
  printf '{"version":"0.0.1","heimdall":{"tag":"%s","installScriptUrl":"%s/%s/install.sh","sha256":"%s"}}\n' \
    "$OLD_TAG" "$RAW" "$OLD_TAG" "$OLD_SHA" > "$d/packages/runheimdall/package.json"
  printf '{"version":"0.0.1","heimdall":{"tag":"%s","installScriptUrl":"%s/%s/install.sh","sha256":"%s","defaultCommand":"attack"}}\n' \
    "$OLD_TAG" "$RAW" "$OLD_TAG" "$OLD_SHA" > "$d/packages/runhmd/package.json"
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
  [ -n "$bare" ] || { echo "FATAL: bare path empty" >&2; exit 1; }
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

# Both npx wrappers carry the SAME pin: runhmd's package.json was re-pointed to the same tag,
# url and digest as runheimdall's, and keeps the fields sync does not own.
HMD_PKG="$PLUG/packages/runhmd/package.json"
if [ "$(jq -r '.heimdall.sha256' "$HMD_PKG")" = "$WRAP_SHA" ] \
   && [ "$(jq -r '.heimdall.tag' "$HMD_PKG")" = "$NEW_TAG" ] \
   && [ "$(jq -r '.heimdall.installScriptUrl' "$HMD_PKG")" = "$RAW/$NEW_TAG/install.sh" ] \
   && [ "$(jq -r '.version' "$HMD_PKG")" = "${NEW_TAG#v}" ] \
   && [ "$(jq -r '.heimdall.defaultCommand' "$HMD_PKG")" = "attack" ]; then
  ok "runhmd package.json re-pointed to the SAME tag/url/sha256 as runheimdall (and its other fields kept)"
else
  bad "runhmd package.json was not re-pointed in lockstep: $(jq -c '{version, heimdall}' "$HMD_PKG" 2>/dev/null)"
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

# ── Case 6: --no-site-commit — netlify.toml is rewritten, nothing is committed or pushed ──
PLUG4="$WORK/plugin4"; SITE4="$WORK/site4"; BARE4="$WORK/site4.git"
make_fake_plugin "$PLUG4"
make_fake_site "$SITE4" "$BARE4"
C6_HEAD="$(git -C "$SITE4" rev-parse HEAD)"
C6="$WORK/c6.out"
HEIMDALL_SITE_DIR="$SITE4" bash "$PLUG4/release/sync-release.sh" "$NEW_TAG" --no-site-commit >"$C6" 2>&1
c6_rc=$?
if [ "$c6_rc" -eq 0 ] && [ "$(netlify_to_tag "$SITE4/netlify.toml")" = "$NEW_TAG" ]; then
  ok "--no-site-commit: netlify.toml is still rewritten to ${NEW_TAG}"
else
  bad "--no-site-commit: rc=$c6_rc, netlify.toml tag '$(netlify_to_tag "$SITE4/netlify.toml")'"; sed 's/^/    /' "$C6" >&2
fi
if [ "$(git -C "$SITE4" rev-parse HEAD)" = "$C6_HEAD" ] \
   && [ "$(git -C "$BARE4" rev-parse refs/heads/main)" = "$C6_HEAD" ] \
   && git -C "$SITE4" status --porcelain | grep -q '^ M netlify.toml$' \
   && grep -q 'NOT committed' "$C6"; then
  ok "--no-site-commit: no site commit, no push; netlify.toml is left modified for ship.sh to commit with the pins"
else
  bad "--no-site-commit committed or pushed something, or did not say it deferred"; sed 's/^/    /' "$C6" >&2
fi

# ══ release/ship.sh's site pins ═══════════════════════════════════════════════════════════════════
SHIP="$REPO/release/ship.sh"
RENDER_SRC="$REPO/bin/heimdall-render-version"
CHECKS_SRC="$REPO/bin/heimdall-repo-checks"
for f in "$SHIP" "$RENDER_SRC" "$CHECKS_SRC"; do
  [ -f "$f" ] || { echo "FATAL: missing $f" >&2; exit 2; }
done
command -v python3 >/dev/null 2>&1 || { echo "FATAL: python3 is required (bin/heimdall-repo-checks)" >&2; exit 2; }

PIN_OLD_TAG="v9.9.8"; PIN_TAG="v9.9.9"
PIN_OLD_SHA="1111111111111111111111111111111111111111111111111111111111111111"
PIN_ZERO_SHA="0000000000000000000000000000000000000000000000000000000000000000"
PIN_FILES=(index.html llms-full.txt netlify.toml security.html team.html version.js)   # every file that carries a pin
PIN_DIGEST_FILES=(index.html llms-full.txt netlify.toml security.html)                  # the ones that carry the install.sh digest
PIN_COMMIT_FILES="index.html,llms-full.txt,netlify.toml,security.html,team.html,version.js"
PASS_CHECK="grep -q 'v9.9.9' index.html && grep -q 'v9.9.9' netlify.toml"

sha256_stdin() { if command -v sha256sum >/dev/null 2>&1; then sha256sum | awk '{print $1}'; else shasum -a 256 | awk '{print $1}'; fi; }

# make_released_plugin <dir> — a plugin repo whose release v9.9.9 is tagged, carrying the REAL renderer. install.sh is edited AFTER the tag,
# so the working tree's install.sh and the tag's differ: a digest taken from the working tree would be the wrong one.
make_released_plugin() {
  local d="$1" mb me bt='`'
  mb="$(sed -n "s/^MARK_BEGIN='\(.*\)'\$/\1/p" "$RENDER_SRC")"
  me="$(sed -n "s/^MARK_END='\(.*\)'\$/\1/p" "$RENDER_SRC")"
  [ -n "$mb" ] && [ -n "$me" ] || { echo "FATAL: cannot read the HEIMDALL:VERSION markers out of the renderer" >&2; exit 2; }
  mkdir -p "$d/bin" "$d/.claude-plugin" || exit 2
  cp "$RENDER_SRC" "$d/bin/heimdall-render-version" && chmod +x "$d/bin/heimdall-render-version" || exit 2
  printf '{"name":"heimdall","version":"9.9.9"}\n' > "$d/.claude-plugin/plugin.json"
  printf '9.9.9\n' > "$d/VERSION"
  {
    printf '# Fixture plugin\n\n%s\n[![Version](https://img.shields.io/badge/version-9.9.9-00d4ff?style=flat-square)](CHANGELOG.md)\n%s\n\n' "$mb" "$me"
    printf 'Install: curl -fsSL %s/v9.9.9/install.sh | bash <!-- HEIMDALL:PIN:TAG -->\n' "$RAW"
    printf 'Pinned to the %sv9.9.9%s tag.\n' "$bt" "$bt"
    printf 'Signature: https://github.com/randomittin/heimdall/releases/download/v9.9.9/install.sh.minisig\n'
  } > "$d/README.md"
  printf '#!/usr/bin/env bash\ninstall() {\n  local DEFAULT_REF="v9.9.9"\n}\n' > "$d/install.sh"
  git init -q "$d" && git -C "$d" config user.email test@heimdall.local && git -C "$d" config user.name "Heimdall Test" \
    && git -C "$d" config commit.gpgsign false || exit 2
  git -C "$d" add -A && git -C "$d" commit -q -m "chore(release): v9.9.9" && git -C "$d" tag v9.9.9 || exit 2
  printf '#!/usr/bin/env bash\ninstall() {\n  local DEFAULT_REF="v9.9.9"\n  echo edited after the release\n}\n' > "$d/install.sh"
  git -C "$d" commit -q -am "fix: a change after the release" || exit 2
}

# make_pin_site <site dir> <its bare origin> <the command of the site's one declared check> — heimdall-site as it sits between releases: every
# pin at v9.9.8, a check declaration committed, an untracked package-lock.json, and history (v1.0.0, v0.0.1) that is no pin.
make_pin_site() {
  local s="$1" bare="$2"
  mkdir -p "$s/.heimdall" || exit 2
  cat > "$s/index.html" <<EOF
<!doctype html>
<meta name="heimdall-version" content="$PIN_OLD_TAG"><!-- HEIMDALL:PIN:TAG -->
<span class="ver" data-hd-ver>$PIN_OLD_TAG</span> <!-- HEIMDALL:PIN:TAG -->
<!-- HEIMDALL:PIN:VERSION:BEGIN — rendered from plugin.json by bin/heimdall-render-version -->
{"softwareVersion": "${PIN_OLD_TAG#v}"}
<!-- HEIMDALL:PIN:END -->
<!-- HEIMDALL:PIN:TAG,SHA256:BEGIN — the tag and the digest are ONE unit -->
<code>curl -fsSL $RAW/$PIN_OLD_TAG/install.sh -o heimdall-install.sh
  &amp;&amp; echo "$PIN_OLD_SHA  heimdall-install.sh" | shasum -a 256 -c -
  &amp;&amp; bash heimdall-install.sh</code>
<!-- HEIMDALL:PIN:END -->
<p>The first release, v1.0.0, is history and no pin.</p>
EOF
  cat > "$s/security.html" <<EOF
<!doctype html>
<meta name="heimdall-version" content="$PIN_OLD_TAG"><!-- HEIMDALL:PIN:TAG -->
<!-- HEIMDALL:PIN:TAG,SHA256:BEGIN -->
<code>curl -fsSL $RAW/$PIN_OLD_TAG/install.sh -o heimdall-install.sh
  &amp;&amp; echo "$PIN_OLD_SHA  heimdall-install.sh" | shasum -a 256 -c -</code>
<!-- HEIMDALL:PIN:END -->
EOF
  cat > "$s/llms-full.txt" <<EOF
# runhmd
<!-- HEIMDALL:PIN:TAG,SHA256:BEGIN — rendered from plugin.json by bin/heimdall-render-version -->
curl -fsSL $RAW/$PIN_OLD_TAG/install.sh -o heimdall-install.sh
  && echo "$PIN_OLD_SHA  heimdall-install.sh" | shasum -a 256 -c -
Pinned to the \`$PIN_OLD_TAG\` tag and checked against the sha256 of that tag's install.sh.
<!-- HEIMDALL:PIN:END -->
Earlier releases, v1.0.0 among them, are no pin.
EOF
  printf '%s\n' "function pinnedTag() {" "  return 'v9.9.8'; // HEIMDALL:PIN:TAG" "}" > "$s/version.js"
  printf '%s\n' '<span class="ver">v9.9.8</span> <!-- HEIMDALL:PIN:TAG -->' '<p>Nothing else on this page is a pin.</p>' > "$s/team.html"
  cat > "$s/netlify.toml" <<EOF
[build]
  publish = "."

# HEIMDALL:PIN:TAG,SHA256:BEGIN — rendered from plugin.json by bin/heimdall-render-version
# The tag below is pinned. Current release: $PIN_OLD_TAG
# (install.sh sha256 $PIN_OLD_SHA).
[[redirects]]
  from = "/install"
  to = "$RAW/$PIN_OLD_TAG/install.sh"
  status = 302
  force = true
# HEIMDALL:PIN:END
EOF
  printf 'Site notes. v0.0.1 is only history here.\n' > "$s/CLAUDE.md"
  printf '.heimdall/receipts/\n' > "$s/.gitignore"
  printf '{"schema":1,"checks":[{"name":"pins","cmd":"%s"}]}\n' "$3" > "$s/.heimdall/repo-checks.json"
  git init -q "$s" && git -C "$s" config user.email test@heimdall.local && git -C "$s" config user.name "Heimdall Test" \
    && git -C "$s" config commit.gpgsign false || exit 2
  git -C "$s" add -- .gitignore .heimdall/repo-checks.json CLAUDE.md index.html security.html llms-full.txt version.js team.html netlify.toml || exit 2
  git -C "$s" commit -q -m "initial site at $PIN_OLD_TAG" && git -C "$s" branch -M main || exit 2
  git init -q --bare "$bare" && git -C "$s" remote add origin "$bare" && git -C "$s" push -q -u origin main || exit 2
  printf '{"lockfileVersion":3}\n' > "$s/package-lock.json"   # untracked, as in the real site
}

# The REAL bin/heimdall-repo-checks behind a recorder: what the site's HEAD and its origin hold at the moment the checks run.
PROBE="$WORK/repo-checks-probe"
cat > "$PROBE" <<'PROBE_SH'
#!/usr/bin/env bash
repo=""; prev=""
for a in "$@"; do
  if [ "$prev" = "--repo" ]; then repo="$a"; fi
  prev="$a"
done
{
  printf 'args=%s\n' "$*"
  printf 'site_head=%s\n' "$(git -C "$repo" rev-parse HEAD)"
  printf 'bare_main=%s\n' "$(git -C "$PROBE_BARE" rev-parse refs/heads/main)"
} >> "$PROBE_LOG"
exec "$PROBE_REAL" "$@"
PROBE_SH
chmod +x "$PROBE"

# The REAL renderer, then a digest of the WRONG bytes written into the security page: what a renderer that hashed the wrong file would leave behind.
RENDER_WRONG="$WORK/render-wrong-sha"
cat > "$RENDER_WRONG" <<'WRONG_SH'
#!/usr/bin/env bash
"$WRONG_REAL" "$@" || exit $?
if [ "$#" -eq 0 ]; then
  sed -E -i.bak 's/[0-9a-f]{64}/0000000000000000000000000000000000000000000000000000000000000000/' "$HEIMDALL_SITE_DIR/security.html" \
    && rm -f "$HEIMDALL_SITE_DIR/security.html.bak"
fi
WRONG_SH
chmod +x "$RENDER_WRONG"

# run_site_pins <plugin> <site> <bare> <out> [renderer] — release_site_pins v9.9.9 as ship.sh runs it: sourced through the SHIP_SOURCE_ONLY seam,
# in the plugin repo, errexit on. The checks and the renderer are the ones above; HEIMDALL_SITE_DIR is always set, so the real site is never read.
run_site_pins() {
  local plug="$1" site="$2" bare="$3" out="$4" renderer="${5:-}"
  case "$site" in "$WORK"/*) ;; *) echo "FATAL: a site outside the throwaway directory: $site" >&2; exit 2 ;; esac
  rm -f "$out" "$out.probe"
  (
    cd "$plug" || exit 99
    # shellcheck disable=SC1090
    SHIP_SOURCE_ONLY=1 . "$SHIP"
    # shellcheck disable=SC2034 # read by the sourced ship.sh (release_site_pins locates the plugin repo through it)
    REPO_ROOT="$plug"
    export HEIMDALL_SITE_DIR="$site" SHIP_REPO_CHECKS="$PROBE" PROBE_BARE="$bare" PROBE_LOG="$out.probe" PROBE_REAL="$CHECKS_SRC"
    export WRONG_REAL="$plug/bin/heimdall-render-version"
    [ -z "$renderer" ] || export SHIP_RENDERER="$renderer"
    release_site_pins "$PIN_TAG"
  ) >"$out" 2>&1
}

site_head() { git -C "$1" rev-parse HEAD; }
bare_main() { git -C "$1" rev-parse refs/heads/main; }
tail_out() { sed 's/^/    /' "$1" >&2; }

# site_pins_are_current <site> — what is wrong with the pins, or nothing: every pin-bearing file carries the release and none the previous one,
# the digest pages carry the TAG's sha256 and not the old one nor the working tree's, and unmarked history is untouched.
site_pins_are_current() {
  local s="$1" f missing=""
  for f in "${PIN_FILES[@]}"; do
    grep -Fq "$PIN_TAG" "$s/$f" || missing="$missing $f(no $PIN_TAG)"
    if grep -Fq "$PIN_OLD_TAG" "$s/$f"; then missing="$missing $f(still $PIN_OLD_TAG)"; fi
  done
  for f in "${PIN_DIGEST_FILES[@]}"; do
    grep -Fq "$WANT" "$s/$f" || missing="$missing $f(not the tag's digest)"
    if grep -Fq "$PIN_OLD_SHA" "$s/$f"; then missing="$missing $f(still the old digest)"; fi
    if grep -Fq "$WORKTREE_SHA" "$s/$f"; then missing="$missing $f(the WORKING TREE's digest)"; fi
  done
  grep -Fq '"softwareVersion": "9.9.9"' "$s/index.html" || missing="$missing index.html(softwareVersion)"
  grep -Fq 'The first release, v1.0.0, is history' "$s/index.html" || missing="$missing index.html(history rewritten)"
  grep -Fq 'v1.0.0 among them' "$s/llms-full.txt" || missing="$missing llms-full.txt(history rewritten)"
  [ -z "$missing" ] || { printf '%s' "$missing"; return 1; }
}

# ── Cases 7-9: the pins land, correct, in ONE commit that holds only what it should, checked before the push ──
PIN_PLUG="$WORK/pin-plugin"; make_released_plugin "$PIN_PLUG"
WANT="$(git -C "$PIN_PLUG" show "$PIN_TAG:install.sh" | sha256_stdin)"
WORKTREE_SHA="$(sha256_stdin < "$PIN_PLUG/install.sh")"
[ -n "$WANT" ] && [ "$WANT" != "$WORKTREE_SHA" ] \
  || { echo "FATAL: the fixture's working-tree install.sh must differ from the tag's, or a digest taken from the working tree would pass" >&2; exit 2; }

PIN_SITE1="$WORK/pin-site1"; PIN_BARE1="$WORK/pin-site1.git"
make_pin_site "$PIN_SITE1" "$PIN_BARE1" "$PASS_CHECK"
S1_HEAD0="$(site_head "$PIN_SITE1")"; S1_BARE0="$(bare_main "$PIN_BARE1")"
run_site_pins "$PIN_PLUG" "$PIN_SITE1" "$PIN_BARE1" "$WORK/s1.out"
s1_rc=$?
S1_HEAD1="$(site_head "$PIN_SITE1")"

if [ "$s1_rc" -eq 0 ]; then ok "release_site_pins exits 0 on a site at the previous release"; else bad "release_site_pins exit=$s1_rc"; tail_out "$WORK/s1.out"; fi

if why="$(site_pins_are_current "$PIN_SITE1")"; then
  ok "every version pin and every install.sh sha256 is rewritten (tag, bare version, JSON-LD, region pins, inline pins, netlify.toml); history untouched"
  ok "the pinned digest is the sha256 of 'git show v9.9.9:install.sh', not of the working tree's install.sh (which differs)"
else
  bad "pins are not current:$why"; tail_out "$WORK/s1.out"
fi

if [ "$(git -C "$PIN_SITE1" rev-parse "$S1_HEAD1^")" = "$S1_HEAD0" ] \
   && [ "$(git -C "$PIN_SITE1" diff-tree --no-commit-id --name-only -r HEAD | sort | paste -sd, -)" = "$PIN_COMMIT_FILES" ]; then
  ok "ONE commit holds exactly the pin-bearing files plus netlify.toml: $PIN_COMMIT_FILES"
else
  bad "the site commit is not one commit of exactly the pin files: $(git -C "$PIN_SITE1" diff-tree --no-commit-id --name-only -r HEAD | paste -sd, -)"
fi
if git -C "$PIN_SITE1" status --porcelain | grep -Fxq '?? package-lock.json' \
   && ! git -C "$PIN_SITE1" ls-files --error-unmatch package-lock.json >/dev/null 2>&1; then
  ok "the untracked package-lock.json was neither staged nor committed"
else
  bad "package-lock.json was staged or committed"
fi
if git -C "$PIN_SITE1" log -1 --format=%B | grep -Fxq 'Co-Authored-By: runhmd <318965969+runhmd@users.noreply.github.com>' \
   && git -C "$PIN_SITE1" log -1 --format=%s | grep -Fq "chore: pin site to $PIN_TAG"; then
  ok "the commit is 'chore: pin site to $PIN_TAG ...' and carries the runhmd trailer"
else
  bad "unexpected commit message: $(git -C "$PIN_SITE1" log -1 --format=%B)"
fi
if [ -z "$(git -C "$PIN_PLUG" status --porcelain)" ]; then ok "the plugin repo was left untouched (the renderer rewrote nothing there)"; else bad "the plugin repo was modified: $(git -C "$PIN_PLUG" status --porcelain)"; fi

# The checks ran ONCE, on the committed head, while the origin still held the old head; the push came after, and the push gate accepts the receipt.
PIN_SITE1_REAL="$(cd "$PIN_SITE1" && pwd)"   # ship.sh hands the checks the normalized path ($TMPDIR ends in a slash, so $WORK holds a //)
if [ "$(grep -c '^args=' "$WORK/s1.out.probe" 2>/dev/null)" = "1" ] \
   && grep -Fxq "args=run --repo $PIN_SITE1_REAL" "$WORK/s1.out.probe" \
   && grep -Fxq "site_head=$S1_HEAD1" "$WORK/s1.out.probe" \
   && grep -Fxq "bare_main=$S1_BARE0" "$WORK/s1.out.probe"; then
  ok "'heimdall-repo-checks run --repo <site>' ran once, after the commit and BEFORE the push"
else
  bad "the site's checks did not run exactly once between the commit and the push"; cat "$WORK/s1.out.probe" >&2 2>/dev/null
fi
if [ "$S1_HEAD1" != "$S1_HEAD0" ] && [ "$(bare_main "$PIN_BARE1")" = "$S1_HEAD1" ]; then ok "the pin commit was pushed to the site's origin main"; else bad "the pin commit was not pushed"; fi
if "$CHECKS_SRC" status --repo "$PIN_SITE1" --pushes "$S1_HEAD1" >/dev/null 2>&1; then
  ok "the receipt is GREEN and bound to the pushed commit: exactly what the push gate asks"
else
  bad "the push gate would not accept the site's receipt for $S1_HEAD1"
fi

# ── Case 10: idempotent — a re-run commits, checks and pushes nothing ──
S1_COUNT="$(git -C "$PIN_SITE1" rev-list --count HEAD)"
run_site_pins "$PIN_PLUG" "$PIN_SITE1" "$PIN_BARE1" "$WORK/s1b.out"
s1b_rc=$?
if [ "$s1b_rc" -eq 0 ] && [ "$(git -C "$PIN_SITE1" rev-list --count HEAD)" = "$S1_COUNT" ] \
   && [ ! -e "$WORK/s1b.out.probe" ] && grep -q 'already pins' "$WORK/s1b.out"; then
  ok "idempotent: re-running makes no commit and runs no checks"
else
  bad "re-run was not a no-op (rc=$s1b_rc, commits $S1_COUNT -> $(git -C "$PIN_SITE1" rev-list --count HEAD))"; tail_out "$WORK/s1b.out"
fi

# ── Case 11: a pin that would end up with a different sha256 REFUSES, loudly, before anything is committed, checked or pushed ──
PIN_SITE2="$WORK/pin-site2"; PIN_BARE2="$WORK/pin-site2.git"
make_pin_site "$PIN_SITE2" "$PIN_BARE2" "$PASS_CHECK"
S2_HEAD0="$(site_head "$PIN_SITE2")"; S2_BARE0="$(bare_main "$PIN_BARE2")"
run_site_pins "$PIN_PLUG" "$PIN_SITE2" "$PIN_BARE2" "$WORK/s2.out" "$RENDER_WRONG"
s2_rc=$?
if [ "$s2_rc" -eq 1 ] && grep -Fq "security.html pins install.sh sha256 $PIN_ZERO_SHA" "$WORK/s2.out" \
   && grep -Fq "$PIN_TAG holds $WANT" "$WORK/s2.out"; then
  ok "a digest that is not the tag's install.sh sha256 REFUSES (exit 1) and names the file, the wrong digest and the right one"
else
  bad "a wrong digest did not refuse as required (rc=$s2_rc)"; tail_out "$WORK/s2.out"
fi
if [ "$(site_head "$PIN_SITE2")" = "$S2_HEAD0" ] && [ "$(bare_main "$PIN_BARE2")" = "$S2_BARE0" ] && [ ! -e "$WORK/s2.out.probe" ]; then
  ok "the refusal committed nothing, ran no site checks and pushed nothing"
else
  bad "a refused wrong-digest run still committed, checked or pushed"
fi

# ── Case 12: the other refusals — an edit that is not a pin, red site checks, a site off main — and an absent site ──
PIN_SITE3="$WORK/pin-site3"; PIN_BARE3="$WORK/pin-site3.git"
make_pin_site "$PIN_SITE3" "$PIN_BARE3" "$PASS_CHECK"
printf '<p>draft headline, not ready</p>\n' >> "$PIN_SITE3/team.html"
S3_HEAD0="$(site_head "$PIN_SITE3")"; S3_BARE0="$(bare_main "$PIN_BARE3")"
run_site_pins "$PIN_PLUG" "$PIN_SITE3" "$PIN_BARE3" "$WORK/s3.out"
s3_rc=$?
if [ "$s3_rc" -eq 1 ] && grep -Fq 'team.html differs from HEAD in more than version numbers and sha256 digests' "$WORK/s3.out" \
   && [ "$(site_head "$PIN_SITE3")" = "$S3_HEAD0" ] && [ "$(bare_main "$PIN_BARE3")" = "$S3_BARE0" ] && [ ! -e "$WORK/s3.out.probe" ]; then
  ok "the site owner's own edit of a page is NOT carried into the pin commit: refused, nothing committed or pushed"
else
  bad "an unrelated edit in a pin-bearing page was not refused (rc=$s3_rc)"; tail_out "$WORK/s3.out"
fi

PIN_SITE4="$WORK/pin-site4"; PIN_BARE4="$WORK/pin-site4.git"
make_pin_site "$PIN_SITE4" "$PIN_BARE4" "false"
S4_HEAD0="$(site_head "$PIN_SITE4")"; S4_BARE0="$(bare_main "$PIN_BARE4")"
run_site_pins "$PIN_PLUG" "$PIN_SITE4" "$PIN_BARE4" "$WORK/s4.out"
s4_rc=$?
if [ "$s4_rc" -eq 1 ] && grep -Fq 'NOT pushing' "$WORK/s4.out" && [ "$(bare_main "$PIN_BARE4")" = "$S4_BARE0" ] \
   && [ "$(site_head "$PIN_SITE4")" != "$S4_HEAD0" ] && [ -e "$WORK/s4.out.probe" ]; then
  ok "red site checks: REFUSES (exit 1), the commit stays local, nothing is pushed"
else
  bad "red site checks did not stop the push (rc=$s4_rc)"; tail_out "$WORK/s4.out"
fi
# The site's owner fixes the check; the re-run finds nothing to commit, but the local commits are unpushed: it checks and pushes them.
printf '{"schema":1,"checks":[{"name":"pins","cmd":"%s"}]}\n' "$PASS_CHECK" > "$PIN_SITE4/.heimdall/repo-checks.json"
git -C "$PIN_SITE4" commit -q -am "fix: the check" || exit 2
S4_HEAD1="$(site_head "$PIN_SITE4")"
run_site_pins "$PIN_PLUG" "$PIN_SITE4" "$PIN_BARE4" "$WORK/s4b.out"
s4b_rc=$?
if [ "$s4b_rc" -eq 0 ] && [ "$(bare_main "$PIN_BARE4")" = "$S4_HEAD1" ] && [ "$(site_head "$PIN_SITE4")" = "$S4_HEAD1" ] \
   && "$CHECKS_SRC" status --repo "$PIN_SITE4" --pushes "$S4_HEAD1" >/dev/null 2>&1; then
  ok "re-run after the fix: the unpushed commits are checked (green) and pushed"
else
  bad "the re-run did not push the unpushed commits (rc=$s4b_rc)"; tail_out "$WORK/s4b.out"
fi

PIN_SITE5="$WORK/pin-site5"; PIN_BARE5="$WORK/pin-site5.git"
make_pin_site "$PIN_SITE5" "$PIN_BARE5" "$PASS_CHECK"
git -C "$PIN_SITE5" checkout -q -b feature || exit 2
run_site_pins "$PIN_PLUG" "$PIN_SITE5" "$PIN_BARE5" "$WORK/s5.out"
s5_rc=$?
if [ "$s5_rc" -eq 1 ] && grep -Fq 'is on feature, not on main' "$WORK/s5.out" \
   && [ "$(git -C "$PIN_SITE5" status --porcelain)" = '?? package-lock.json' ]; then
  ok "a site off main REFUSES before any file is touched"
else
  bad "a site on a feature branch was not refused cleanly (rc=$s5_rc)"; tail_out "$WORK/s5.out"
fi

run_site_pins "$PIN_PLUG" "$WORK/no-such-site" "$WORK/no-such-site.git" "$WORK/s6.out"
s6_rc=$?
if [ "$s6_rc" -eq 0 ] && grep -Fq 'NOT pinned' "$WORK/s6.out" && grep -Fq 'release/ship.sh --release-only' "$WORK/s6.out"; then
  ok "an absent site WARNs, says how to finish, and the ship continues (exit 0)"
else
  bad "an absent site did not WARN-and-continue (rc=$s6_rc)"; tail_out "$WORK/s6.out"
fi

# ── Case 13: the wiring — after the Release, before npm; sync-release is told to leave the site commit to ship.sh ──
# shellcheck disable=SC2016 # the arguments are literal source lines of ship.sh: "$TAG", "$sync" and the like are text to find, not expansions
check_wiring() {
  local l_manifest l_site l_npm l_failed l_ro_manifest l_ro_site
  line_of() { grep -nFx -- "$1" "$SHIP" | head -1 | cut -d: -f1; }   # the first line that is exactly this text
  l_manifest="$(line_of '  publish_release_manifest "$TAG"')"
  l_site="$(line_of '  ( release_site_pins "$TAG" ) || SITE_PIN_FAILED=1')"
  l_npm="$(line_of '    publish_npm_all "$NEW_VERSION"')"
  l_failed="$(grep -nF 'die "the site pin step FAILED' "$SHIP" | head -1 | cut -d: -f1)"
  if [ -n "$l_manifest" ] && [ -n "$l_site" ] && [ -n "$l_npm" ] && [ -n "$l_failed" ] \
     && [ "$l_manifest" -lt "$l_site" ] && [ "$l_site" -lt "$l_npm" ] && [ "$l_npm" -lt "$l_failed" ]; then
    ok "ship.sh pins the site after the Release (line $l_site > $l_manifest), before npm ($l_npm), and reports a site failure last ($l_failed)"
  else
    bad "ship.sh's site step is mis-ordered (manifest=$l_manifest site=$l_site npm=$l_npm failed=$l_failed)"
  fi
  l_ro_manifest="$(line_of '  publish_release_manifest "$TAG" "$TMP_DIR/tagged/install.sh"')"
  l_ro_site="$(line_of '  release_site_pins "$TAG"')"
  if [ -n "$l_ro_manifest" ] && [ -n "$l_ro_site" ] && [ "$l_ro_manifest" -lt "$l_ro_site" ]; then
    ok "--release-only re-pins the site too, after the Release (line $l_ro_site > $l_ro_manifest)"
  else
    bad "--release-only does not pin the site after the Release (manifest=$l_ro_manifest site=$l_ro_site)"
  fi
  if grep -Fq 'bash "$sync" "$tag" --no-site-commit' "$SHIP"; then
    ok "ship.sh runs sync-release.sh with --no-site-commit"
  else
    bad "ship.sh does not pass --no-site-commit to sync-release.sh"
  fi
}
check_wiring

echo ""
echo "ship-netlify.test.sh: $PASS passed, $FAIL failed."
[ "$FAIL" -eq 0 ] || exit 1
exit 0
