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
pinned `<TAG>` raw `install.sh`, `status = 302`, `force = true`).

### Automated — `release/sync-release.sh` (and therefore `release/ship.sh`) bumps it

Bumping that pinned `<TAG>` (and the `sha256` noted in the file's comment) is **no
longer a manual step**. `release/sync-release.sh <TAG>` now rewrites
`heimdall-site/netlify.toml` in lockstep with the in-repo artifacts, using the SAME
tag and the SAME `install.sh` sha256 it bakes into the npx wrapper (never recomputed
divergently), then commits **only** `netlify.toml` (`chore(netlify): pin /install ->
v<tag>`) and `git push origin main` so Netlify auto-deploys. It is idempotent
(re-running the same tag is a no-op) and asserts the rewritten `to` URL tag byte-equals
the release tag before writing — a mismatch is a real drift bug and hard-fails.

**Locating the site checkout.** `sync-release.sh` finds `heimdall-site` via, in order:

1. the `HEIMDALL_SITE_DIR` environment override (point it anywhere), else
2. the sibling `../heimdall-site` relative to this plugin repo root, else
3. the known local checkout `/Users/rj/Downloads/heimdall-site`.

**WARN-fallback (a missing site never fails a release).** If none of those resolve —
or the found directory is not a git repo, or the `git push` fails (offline / no
creds) — `sync-release.sh` **WARNs and continues the plugin release**; it prints the
exact manual bump + `git commit` + `git push origin main` to run by hand. A missing
site checkout must never block a plugin ship, so this path is a soft warning, not a
`die`. (By contrast, a *present* but unpinnable `netlify.toml` — no `/install`
redirect — IS a hard failure.)

The in-repo artifacts below remain the canonical, sync-release-maintained source of
truth for the redirect target (tag + 302 mapping); `sync-release.sh` mirrors the
current target into `heimdall-site/netlify.toml` automatically.

| Host | File | Notes |
| --- | --- | --- |
| **Netlify (live)** | `heimdall-site/netlify.toml` | Actual deployed redirect. `[[redirects]]` `/install` → `<TAG>` raw, `status = 302`, `force = true`. **Auto-bumped + pushed by `release/sync-release.sh`** (override its location with `HEIMDALL_SITE_DIR`; WARN-fallback if absent). |
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
