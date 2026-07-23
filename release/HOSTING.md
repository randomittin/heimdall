# runheimdall.dev/install — which redirect artifact to apply

The vanity URL `https://runheimdall.dev/install` is a **302** (temporary redirect)
to the pinned release tag's raw `install.sh`:

```
https://raw.githubusercontent.com/randomittin/heimdall/<TAG>/install.sh
```

302, not 301 — the target tag moves every release, so the redirect must never be
cached as permanent. `release/sync-release.sh <TAG>` keeps both artifacts below
pointed at the current tag; deploy whichever one matches the host.

## Where runheimdall.dev is actually served from

**`runheimdall.dev` is a Netlify site whose publish source is the SEPARATE repo
`randomittin/heimdall-site` (checked out locally at `/Users/rj/Downloads/heimdall-site`),
NOT this plugin repo.** The live landing page (`/`) is `heimdall-site/index.html`;
this repo contains no HTML. Confirmed by response header `cache-status: "Netlify Edge"`
and by the served `<title>` existing only in `heimdall-site`.

Consequence: the `/_redirects` and `/vercel.json` files in THIS repo are correct
and version-controlled, but they are never part of the runheimdall.dev deploy, so
they do nothing on their own. **The live vanity `/install` redirect lives in the
site repo at `heimdall-site/netlify.toml`** (`[[redirects]]` block, `/install` → the
pinned `<TAG>` raw `install.sh`, `status = 302`, `force = true`). Bump that tag on
each release in lockstep with the artifacts here.

The artifacts below remain in this repo as the canonical, sync-release-maintained
source of truth for the redirect target (tag + 302 mapping); copy the current
target into `heimdall-site/netlify.toml` when it changes.

| Host | File | Notes |
| --- | --- | --- |
| **Netlify (live)** | `heimdall-site/netlify.toml` | Actual deployed redirect. `[[redirects]]` `/install` → `<TAG>` raw, `status = 302`, `force = true`. |
| **Vercel (if repointed)** | `/vercel.json` (repo root) | `redirects[].permanent = false` ⇒ 307/302 temporary. Vercel reads `vercel.json` at the deploy root. |
| **Netlify (if this repo were the source)** | `/_redirects` (repo root) | The explicit trailing `302` overrides Netlify's 301 default. Place at the publish dir root. |

Pick the file for the live host; the others are harmless but unused. If
`runheimdall.dev` is ever repointed to serve some other way (Cloudflare Pages reads
`_redirects` too; a plain nginx/Caddy host needs a hand-written rule), mirror the
same `/install → <TAG> raw URL`, **302** mapping there and update this table.

## Verify after deploy

```
curl -sI https://runheimdall.dev/install
# HTTP/2 302
# location: https://raw.githubusercontent.com/randomittin/heimdall/<TAG>/install.sh
```

DNS and hosting deploys are RJ-EXECUTED — see `release/publish-checklist.md` step 4.
