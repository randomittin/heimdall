# Heimdall release — publish checklist (RJ-EXECUTED)

One script (`release/sync-release.sh <TAG>`) prepares the working tree; the steps
below are the irreversible, human-executed acts. Tags are immutable — nothing here
moves an existing tag, and the checksum the wrapper bakes is the checksum the tag
holds. Do not delegate these to an agent.

## 0. Pre-flight gate (must all be true)

- [ ] **Every command block in the README was executed cold against the live release before this tag.**
- [ ] Alarm suite green; lint clean; gate corpus + falsify unaffected by these changes.
- [ ] You are on the commit you intend to tag (`git status` clean, right SHA).

## 1. Sync the working tree to the new tag

```
release/sync-release.sh vX.Y.Z --dry     # review the diff + assertions first
release/sync-release.sh vX.Y.Z           # apply: templates install.sh DEFAULT_REF,
                                         # vercel.json, _redirects, README tags,
                                         # and the npx wrapper version/url/sha256
```

The script asserts the redirect target, the npx wrapper, and the tag's install.sh
all resolve to byte-identical bytes (one sha256). If any assertion fails, STOP —
do not publish or tag.

- [ ] `sync-release.sh vX.Y.Z` exits 0 with "all artifacts resolve to … (sha256 …)".
- [ ] Review `git diff` — only the five artifacts changed; the wrapper sha256 is a real 64-hex digest, not the build sentinel.
- [ ] Commit the synced artifacts.

## 2. Create + push the tag (immutable — never re-point an existing one)

```
git tag vX.Y.Z <SHA>
git push origin vX.Y.Z
```

- [ ] Tag points at the committed, synced SHA.
- [ ] `raw.githubusercontent.com/randomittin/heimdall/vX.Y.Z/install.sh` now resolves
      and its sha256 equals the digest `sync-release.sh` printed.

## 2b. Attach the release manifest (the site's version-sync source)

`sync-release.sh` also wrote `.heimdall/release/release-manifest.json` (`tag`, `install_sha256`,
`install_url`, `minisig_url`): generated, ignored build output, not a tracked file. `release/ship.sh`
attaches it to the GitHub Release next to `install.sh.minisig`; the site's CI reads it
(`heimdall-site/gates/version-sync.sh` is the site-side check). By hand:

```
gh release upload vX.Y.Z .heimdall/release/release-manifest.json --clobber   # RJ-EXECUTED
curl -fsSL https://github.com/randomittin/heimdall/releases/latest/download/release-manifest.json | jq -e '.tag and .install_sha256'
```

- [ ] `release-manifest.json` is attached to the vX.Y.Z Release, and its `.tag` and `.install_sha256`
      match the digest `sync-release.sh` printed.

## 3. Publish the npx wrappers (TWO packages, one pin)

`release/ship.sh --dry-run` prints both (name, version, pinned tag + sha256, files, command)
before anything is published. `runhmd` is a new npm name: its first publish claims it.

```
cd packages/runheimdall
jq -e . package.json                     # version == X.Y.Z, sha256 is 64-hex, url has the tag
npm publish --access public              # RJ-EXECUTED — do not run from an agent
cd ../runhmd
jq -e . package.json                     # the SAME version, tag, url and sha256 as runheimdall
npm publish --access public              # RJ-EXECUTED — do not run from an agent
```

- [ ] `runheimdall@X.Y.Z` is live on npm, pinned to vX.Y.Z.
- [ ] `runhmd@X.Y.Z` is live on npm, pinned to the same vX.Y.Z and the same install.sh digest.
- [ ] The release you are publishing dispatches `hmd attack` (`ship.sh --dry-run` warns when it
      does not): `npx runhmd <path>` routes a bare path to it.

## 4. Point the vanity redirect at the new tag

Apply ONE redirect artifact depending on where `runheimdall.dev` is hosted (see
`release/HOSTING.md` for which file to use):

- **Vercel:** deploy with the synced `vercel.json` (302, `permanent: false`).
- **Netlify:** deploy with the synced `_redirects` (`/install … 302`).

- [ ] `curl -sI https://runheimdall.dev/install` returns `302` with `Location:` ==
      `https://raw.githubusercontent.com/randomittin/heimdall/vX.Y.Z/install.sh`.

## 5. Verify checksums match across all three doors (cold)

```
# a) redirect target
curl -fsSL https://runheimdall.dev/install | shasum -a 256

# b) raw pinned tag (what the redirect points to)
curl -fsSL https://raw.githubusercontent.com/randomittin/heimdall/vX.Y.Z/install.sh | shasum -a 256

# c) npx wrapper's baked checksum
npm view runheimdall@X.Y.Z dist.tarball   # or inspect package.json heimdall.sha256
```

- [ ] (a) == (b) == the wrapper's baked sha256 — byte-identical, no exceptions.
- [ ] `npx runheimdall` in a fresh HOME prints "verified install.sh (vX.Y.Z, …)" and installs.
- [ ] A skeptic's `curl … -o install.sh; less install.sh` reads the same bytes.

## What stays queued as RJ-EXECUTED (never an agent)

- `npm publish` of `runheimdall` and `runhmd` (step 3)
- DNS / hosting deploy of the 302 redirect (step 4)
- `git tag` creation + `git push origin vX.Y.Z` (step 2)
