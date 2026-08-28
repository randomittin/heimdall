# OmniRoute local patches

`/Users/rj/omniroute` is **not hmd code and not a repo of its own**. It is a
third-party source checkout of `github.com/diegosouzapw/OmniRoute` v3.8.51,
pinned at commit `d82b68274c75c14d258b4898a34edc25d9712b87`, used as the local
fallback gateway (`.heimdall/fallback.json` -> `http://127.0.0.1:20128`).

It has no `.git`. **Do not `git init` it.** A fresh history over vendored code
fabricates provenance, makes a local patch indistinguishable from upstream, and
destroys the one property this repo's audits actually depend on: the ability to
diff the working tree against the pinned upstream commit. The pin is the
provenance; a new repo would erase it.

That property is load-bearing. Every OmniRoute security claim in
`docs/analysis/` is asserted *"at commit `d82b682`"* --
`2026-08-25-omniroute-credential-isolation.md` scopes its Tier-1 conclusion to
that exact SHA. Any edit to the checkout that is not recorded here silently
invalidates those analyses, because a future reader diffing against upstream
would find changes nobody declared. So: **patch files live here, in hmd, under
version control.** The checkout stays disposable and re-derivable
(re-clone at the pin, re-apply this directory).

## Applying

    cd /Users/rj/omniroute
    git apply -p1 /Users/rj/Downloads/heimdall/patches/omniroute/*.patch

`git apply` works in a non-git directory. Verified to apply cleanly against a
pristine `d82b682` copy of the touched file.

## 0001 -- wsPath: add missing `resolveLiveWsUrl` / `sanitizeLiveWsPort`

**Upstream is broken at the pinned commit.** `src/hooks/useLiveDashboard.ts:16`
imports `resolveLiveWsUrl` and `sanitizeLiveWsPort` from
`src/shared/utils/wsPath.ts`, which exports neither. Any production build fails:

    Error: Export sanitizeLiveWsPort doesn't exist in target module

Confirmed against upstream, not inferred: the raw file at `d82b682` is
byte-identical (2426 B) to this checkout before the patch and also lacks both
functions. The checkout is pristine -- the defect is upstream's.

`next dev` never surfaced it because it compiles routes on demand and that route
was never requested, so the gateway ran for a long time on a tree that could not
be built. This is why it was only found when moving the launchd service off
`npm run dev` onto a real `build` + `start`.

The contract was NOT invented here. Upstream ships
`tests/unit/live-ws-url-11331.test.ts`, which fully specifies both functions
(upstream issue #11331: a `LIVE_WS_PORT` override never reaching a prebuilt
image, because `NEXT_PUBLIC_*` is inlined at build time). The implementation is
written to that existing test -- 11/11 pass, no test modified. Upstream appears
to have landed the test and the call sites without the implementation.

**Worth upstreaming.** This is a genuine bug in `diegosouzapw/OmniRoute`, not a
local customization, and carrying it as a local patch forever is the worse
outcome. Until then this file is what keeps the divergence honest.
