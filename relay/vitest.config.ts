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
        },
      },
    }),
  ],
});
