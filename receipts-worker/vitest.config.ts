import { defineConfig } from "vitest/config";
import { cloudflareTest } from "@cloudflare/vitest-pool-workers";

// Every credential in this suite is generated HERE, once per test run, and handed to the Worker
// as a miniflare binding: nothing below is a committed key, and nothing is written to disk. The
// Worker gets the public half (RECEIPT_PUBKEYS) and the SHA-256 of the API token
// (API_TOKEN_SHA256S) exactly as production does; the suite gets the signing seed and the token
// itself through the TEST_* bindings, which no real environment has.

const hex = (bytes: Uint8Array): string => Array.from(bytes, (b) => b.toString(16).padStart(2, "0")).join("");
const b64 = (bytes: Uint8Array): string => btoa(String.fromCharCode(...bytes));

const pair = (await crypto.subtle.generateKey({ name: "Ed25519" }, true, ["sign", "verify"])) as CryptoKeyPair;
const publicRaw = new Uint8Array(await crypto.subtle.exportKey("raw", pair.publicKey));
const pkcs8 = new Uint8Array(await crypto.subtle.exportKey("pkcs8", pair.privateKey));
const seed = pkcs8.slice(pkcs8.length - 32);
const apiToken = hex(crypto.getRandomValues(new Uint8Array(32)));
const tokenDigest = hex(new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(apiToken))));

export default defineConfig({
  test: {
    exclude: ["node_modules/**"],
  },
  plugins: [
    cloudflareTest({
      wrangler: { configPath: "./wrangler.toml" },
      miniflare: {
        bindings: {
          RECEIPT_PUBKEYS: `# runhmd receipt test key, generated for this run\n${b64(publicRaw)}\n`,
          API_TOKEN_SHA256S: tokenDigest,
          PUBLIC_BASE_URL: "https://receipts.test",
          CTA_URL: "https://receipts.test/request-cloud-access",
          TEST_SIGNING_SEED_B64: b64(seed),
          TEST_API_TOKEN: apiToken,
        },
      },
    }),
  ],
});
