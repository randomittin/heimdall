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
        },
      },
    }),
  ],
});
