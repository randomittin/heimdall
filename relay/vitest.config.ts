import { defineConfig } from "vitest/config";
import { cloudflareTest } from "@cloudflare/vitest-pool-workers";

export default defineConfig({
  test: {
    // Slow, seeded trace-diff suites run via `npm run test:trace` only.
    // scripts/** is a plain-Node `node --test` suite (fake-hmd.mjs and its
    // lib/ modules need real filesystem/network access, which
    // @cloudflare/vitest-pool-workers' workerd runtime doesn't provide --
    // same reasoning as check-no-logged-urls.mjs). Vitest's default include
    // glob (`**/*.test.mjs`) would otherwise also collect
    // scripts/__tests__/fake-hmd.test.mjs and fail to run it (its `test`
    // import is node:test's, not vitest's).
    exclude: ["node_modules/**", "test/trace/**", "scripts/**"],
  },
  plugins: [
    cloudflareTest({
      wrangler: { configPath: "./wrangler.toml" },
      miniflare: {
        // Test-only placeholder — never a real secret, never committed
        // outside this obviously-fake, self-describing string. Production
        // and local-dev secrets come from `wrangler secret put` / `.dev.vars`
        // respectively (see README.md), never from this file.
        bindings: {
          RELAY_SIGNING_SECRET: "test-only-relay-signing-secret-not-real",
          // src/session.ts's KEEPALIVE_INTERVAL_MS default is 20s — far
          // longer than a test should sit waiting. The Workers runtime
          // gives no hook to advance its own timers (vitest's fake timers
          // don't reach workerd's event loop), so the interval is a real
          // binding and the suite drives it at 1s instead. Production and
          // local dev declare no such binding and run on the 20s default.
          RELAY_KEEPALIVE_MS: "1000",
          // src/session.ts's MAX_STREAM_LIFETIME_MS default is 10 minutes —
          // the bound that stops an orphaned stream outliving a deploy, and
          // far longer than a test should sit waiting. Same constraint as
          // the keepalive above (workerd's timers are real), so the suite
          // drives it at 8s: comfortably longer than the longest stream any
          // other test holds open (~2.6s, the keepalive-reconnect test) and
          // short enough to observe twice inside one test's budget.
          RELAY_STREAM_MAX_LIFETIME_MS: "8000",
          // src/session.ts arms a storage-reclamation alarm on every Durable Object it touches. The
          // per-IP throttle buckets and the per-GitHub-id code indexes fall due about two minutes
          // after their last request, and a spec file runs about two minutes in storage that is not
          // reset between tests -- so the first of hundreds of them falls due as a file ends. A due
          // alarm wakes its object through the runner's module import, ahead of the running test: 481
          // of them (~85% buckets) stalled the runner ~214 s in test/code-pair.spec.ts (longest
          // stretch 101 s), at a pairing window of 60 s and of 360 s alike. A floor of an hour keeps
          // those two kinds past the life of a run. It is applied to them alone (session.ts's
          // armPerCallerPurgeAlarm): a session's alarm is 5 to 7 minutes out, and a sign-in record's
          // is asserted to the second (github-oauth.spec.ts), so both keep the schedule the code gives
          // them. The specs that exercise the purge call runDurableObjectAlarm, which needs no due
          // alarm. Production and local dev bind nothing.
          RELAY_PURGE_MIN_DELAY_MS: "3600000",
          // Pair-by-session-code config (src/code-pair.ts's codePairingConfig): all three
          // must be set or every code-pairing route answers 503. Test-only placeholders on
          // the same terms as RELAY_SIGNING_SECRET above -- obviously fake, never a real
          // credential. The client id here is NOT the project's real (public) one in
          // wrangler.toml: test/code-pair.spec.ts's fake GitHub checks the id the relay puts
          // in the URL and the Basic auth it sends against whatever this binding says.
          GITHUB_CLIENT_ID: "Iv-test-client-id-not-real",
          GITHUB_CLIENT_SECRET: "test-only-github-client-secret-not-real",
          RELAY_IDENTITY_SECRET: "test-only-relay-identity-secret-not-real",
          // The seam src/github.ts reads: every GitHub call goes to this origin. The suite
          // answers it itself (test/code-pair-helpers.ts's FakeGitHub), so no test ever
          // reaches the real api.github.com. Production and local dev bind nothing.
          GITHUB_API_BASE: "https://github-api.test",
          // The same seam for GitHub's web origin (src/github.ts's githubWebOrigin): the authorize
          // redirect and the token exchange of the browser sign-in go here, and the suite answers
          // it itself (test/github-oauth-helpers.ts's FakeGitHubWeb). Production binds nothing.
          GITHUB_WEB_BASE: "https://github-web.test",
          // The browser sign-in's own switch (src/github-oauth.ts's oauthWebConfig), on for the
          // suite so its four routes exist. wrangler.toml ships it "0": the specs that need it off
          // hand the Worker an env of their own, as the config-gate block of code-pair.spec.ts does.
          GITHUB_OAUTH_WEB: "1",
        },
      },
    }),
  ],
});
