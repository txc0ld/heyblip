import { defineWorkersConfig } from "@cloudflare/vitest-pool-workers/config";

export default defineWorkersConfig({
  test: {
    poolOptions: {
      workers: {
        wrangler: { configPath: "./wrangler.toml" },
        miniflare: {
          r2Buckets: ["AVATARS"],
          bindings: {
            JWT_SECRET: "test-jwt-secret",
            DATABASE_URL: "postgresql://test",
            INTERNAL_API_KEY: "test-internal-api-key",
            CORS_ORIGIN: "*",
            MAX_AVATAR_BYTES: "2097152",
          },
        },
      },
    },
  },
});
