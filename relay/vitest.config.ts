import { defineConfig } from "vitest/config";
import { cloudflareTest } from "@cloudflare/vitest-pool-workers";

export default defineConfig({
  test: {
    // Slow, seeded trace-diff suites run via `npm run test:trace` only.
    exclude: ["node_modules/**", "test/trace/**"],
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
