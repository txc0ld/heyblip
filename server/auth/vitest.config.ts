import { defineWorkersConfig } from "@cloudflare/vitest-pool-workers/config";

export default defineWorkersConfig({
  test: {
    poolOptions: {
      workers: {
        wrangler: { configPath: "./wrangler.toml" },
        miniflare: {
          kvNamespaces: ["CODES"],
          bindings: {
            RESEND_API_KEY: "re_test_fake_key",
            FROM_EMAIL: "verify@festichat.app",
            CODE_TTL_SECONDS: "600",
            MAX_SENDS_PER_HOUR: "3",
          },
        },
      },
    },
  },
});
