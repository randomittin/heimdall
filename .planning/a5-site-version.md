# A5 — site version unification (patch instructions, NOT applied here)

**Scope note.** This file is the required deliverable for the SITE half of version
unification. Per the A5 task, `/Users/rj/Downloads/heimdall-site` is NOT edited by this
agent — the changes below are handed off as an exact patch for whoever owns that repo.

## The drift

`.claude-plugin/plugin.json` `.version` is the single source of version truth. The site
carries **stale hard-pinned fallbacks** that disagree with it:

| Surface | File:line | Current (stale) | Should track |
|---|---|---|---|
| Meta pin | `index.html:6` | `content="v2.2.2"` | `v<plugin.json .version>` |
| Meta pin | `proof.html:6` | `content="v2.2.2"` | same |
| Meta pin | `growth.html:6` | `content="v2.2.2"` | same |
| Meta pin | `team.html:6` | `content="v2.2.2"` | same |
| JS fallback | `version.js:32` | `: 'v2.2.2';` | same |
| JS fallback | `index.html:397` | `\|\| 'v2.2.2';` | same |
| JS fallback | `team.html:328` | `\|\| 'v2.2.2';` | same |

At time of writing plugin.json is at **2.2.6**, so every one of these should read
**`v2.2.6`**.

### Why it matters even though the site live-fetches

`version.js` fetches the latest GitHub Release tag at runtime and stamps it into the DOM, so
a fresh visitor with network + an un-throttled GitHub API sees the correct tag regardless.
But the pin is the **fallback shown before/without that fetch**: GitHub allows only 60
unauthenticated API calls/hour/IP, and on any throttle, offline load, CORS hiccup, or parse
error `version.js` deliberately keeps the pinned `<meta>`/JS-literal applied and never
throws. So the stale `v2.2.2` is exactly what a throttled or offline visitor sees. It is a
real, visible version surface — it just degrades quietly, which is why it drifted unnoticed.

## The fix — two parts

### Part 1 (mechanical, do now): re-pin the 7 sites to the current version

Set every occurrence to the current plugin.json version (`v2.2.6` today):

```bash
cd /Users/rj/Downloads/heimdall-site
VER="$(jq -r .version /Users/rj/Downloads/heimdall/.claude-plugin/plugin.json)"   # 2.2.6
TAG="v$VER"
# meta pins
sed -i '' -E "s/(name=\"heimdall-version\" content=\")v[0-9]+\.[0-9]+\.[0-9]+(\")/\1${TAG}\2/" \
  index.html proof.html growth.html team.html
# JS fallbacks (version.js + the two inline copies)
sed -i '' -E "s/('v)[0-9]+\.[0-9]+\.[0-9]+(')/\1${VER#v}\2/g; s/(v)[0-9]+\.[0-9]+\.[0-9]+(')/\1${VER}\2/g" \
  version.js index.html team.html
```

(Review the diff — the two sed passes above are written for the exact current literals;
adjust if the surrounding code moved.)

### Part 2 (durable): generate the pin so it can't drift again

Add a tiny generator to the SITE repo that stamps the fallback from Heimdall's plugin.json,
mirroring `bin/heimdall-render-version` in the plugin repo. Suggested
`heimdall-site/bin/stamp-version`:

```sh
#!/usr/bin/env bash
# stamp-version — pin the site's version fallbacks from the plugin's plugin.json.
set -euo pipefail
SITE="$(cd "$(dirname "$0")/.." && pwd)"
MANIFEST="${HEIMDALL_MANIFEST:-$SITE/../heimdall/.claude-plugin/plugin.json}"
VER="$(jq -r '.version' "$MANIFEST")"; TAG="v$VER"
printf '%s' "$VER" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$' || { echo "bad version: $VER" >&2; exit 1; }
for f in index.html proof.html growth.html team.html; do
  sed -i '' -E "s/(name=\"heimdall-version\" content=\")v[0-9]+\.[0-9]+\.[0-9]+(\")/\1${TAG}\2/" "$SITE/$f"
done
sed -i '' -E "s/(: ')v?[0-9]+\.[0-9]+\.[0-9]+(';)/\1${TAG}\2/" "$SITE/version.js"
echo "stamped site to $TAG"
```

Then run it in the site's release/deploy step (or a pre-commit hook) so a plugin version bump
propagates to the site fallback automatically. The runtime GitHub-API fetch stays as-is; this
only keeps the *fallback* honest.

## Conformance hook (optional, site repo)

If the site repo wants the same red-on-drift guarantee the plugin has, add a test that reads
`plugin.json .version` and asserts every `heimdall-version` meta + JS fallback equals `vX.Y.Z`
— the site-side mirror of `heimdall/test/version-drift.test.sh`. The plugin repo cannot gate
the site because it does not own those files; this is the wiring point for that.

## Verification (after applying Part 1)

```bash
cd /Users/rj/Downloads/heimdall-site
grep -rn 'heimdall-version\|v2\.2\.' index.html proof.html growth.html team.html version.js
# expect: every version literal == the current plugin.json version, no v2.2.2 remaining
```
