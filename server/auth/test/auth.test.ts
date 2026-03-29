import {
  env,
  createExecutionContext,
  waitOnExecutionContext,
} from "cloudflare:test";
import { describe, it, expect, beforeEach } from "vitest";
import worker from "../src/index";

type WorkerEnv = typeof env;

async function request(
  method: string,
  path: string,
  body?: Record<string, unknown>
): Promise<Response> {
  const init: RequestInit = {
    method,
    headers: { "Content-Type": "application/json" },
  };
  if (body) init.body = JSON.stringify(body);

  const req = new Request(`http://localhost${path}`, init);
  const ctx = createExecutionContext();
  const res = await worker.fetch(req, env as unknown as WorkerEnv, ctx);
  await waitOnExecutionContext(ctx);
  return res;
}

async function json(res: Response): Promise<Record<string, unknown>> {
  return (await res.json()) as Record<string, unknown>;
}

// ─── Test helpers ────────────────────────────────────────────

/**
 * Simulate a successful send by writing a code directly to KV.
 * (Resend fails with fake API key in tests, and code is now stored
 *  AFTER email send succeeds, so we bypass the send endpoint.)
 */
async function seedCode(email: string): Promise<string> {
  const array = new Uint32Array(1);
  crypto.getRandomValues(array);
  const code = String(array[0] % 1_000_000).padStart(6, "0");

  const stored = JSON.stringify({
    code,
    attempts: 0,
    createdAt: Date.now(),
  });
  await env.CODES.put(`code:${email}`, stored, { expirationTtl: 600 });
  return code;
}

beforeEach(async () => {
  const keys = await env.CODES.list();
  for (const key of keys.keys) {
    await env.CODES.delete(key.name);
  }
});

// ─── Health ──────────────────────────────────────────────────

describe("GET /v1/auth/health", () => {
  it("returns ok", async () => {
    const res = await request("GET", "/v1/auth/health");
    expect(res.status).toBe(200);
    expect(await json(res)).toEqual({ status: "ok" });
  });
});

// ─── Send Code ───────────────────────────────────────────────

describe("POST /v1/auth/send-code", () => {
  it("rejects missing email", async () => {
    const res = await request("POST", "/v1/auth/send-code", {});
    expect(res.status).toBe(400);
  });

  it("rejects invalid email", async () => {
    const res = await request("POST", "/v1/auth/send-code", {
      email: "notanemail",
    });
    expect(res.status).toBe(400);
  });

  it("returns 502 when Resend fails (fake API key)", async () => {
    const res = await request("POST", "/v1/auth/send-code", {
      email: "test@example.com",
    });
    // With fake API key, Resend returns an error -> 502
    expect(res.status).toBe(502);
    // Code should NOT be stored since email failed
    const raw = await env.CODES.get("code:test@example.com");
    expect(raw).toBeNull();
  });

  it("rate limits after max sends per hour", async () => {
    const email = "ratelimit@example.com";
    // Seed rate limit entries directly (since Resend fails in tests)
    const entry = JSON.stringify({
      timestamps: [Date.now(), Date.now(), Date.now()],
    });
    await env.CODES.put(`rate:${email}`, entry, { expirationTtl: 3600 });

    const res = await request("POST", "/v1/auth/send-code", { email });
    expect(res.status).toBe(429);
  });
});

// ─── Verify Code ─────────────────────────────────────────────

describe("POST /v1/auth/verify-code", () => {
  it("verifies correct code", async () => {
    const email = "verify@example.com";
    const code = await seedCode(email);
    const res = await request("POST", "/v1/auth/verify-code", { email, code });
    expect(res.status).toBe(200);
    expect(await json(res)).toEqual({ verified: true });
  });

  it("deletes code after successful verification", async () => {
    const email = "onetime@example.com";
    const code = await seedCode(email);
    await request("POST", "/v1/auth/verify-code", { email, code });
    const raw = await env.CODES.get(`code:${email}`);
    expect(raw).toBeNull();
  });

  it("rejects incorrect code", async () => {
    const email = "wrong@example.com";
    await seedCode(email);
    const res = await request("POST", "/v1/auth/verify-code", {
      email,
      code: "000000",
    });
    expect(res.status).toBe(401);
  });

  it("increments attempts on wrong code", async () => {
    const email = "attempts@example.com";
    await seedCode(email);
    await request("POST", "/v1/auth/verify-code", { email, code: "000000" });
    const raw = await env.CODES.get(`code:${email}`);
    const stored = JSON.parse(raw!);
    expect(stored.attempts).toBe(1);
  });

  it("locks out after 5 failed attempts", async () => {
    const email = "lockout@example.com";
    await seedCode(email);
    for (let i = 0; i < 5; i++) {
      await request("POST", "/v1/auth/verify-code", { email, code: "000000" });
    }
    const res = await request("POST", "/v1/auth/verify-code", {
      email,
      code: "000000",
    });
    expect(res.status).toBe(429);
    expect((await json(res)).error).toContain("Too many attempts");
  });

  it("clears rate limit on lockout so user can request fresh code", async () => {
    const email = "lockout-recovery@example.com";
    await seedCode(email);
    // Seed a rate entry
    const entry = JSON.stringify({ timestamps: [Date.now(), Date.now()] });
    await env.CODES.put(`rate:${email}`, entry, { expirationTtl: 3600 });

    // 5 wrong attempts bring stored.attempts to 5
    for (let i = 0; i < 5; i++) {
      await request("POST", "/v1/auth/verify-code", { email, code: "000000" });
    }

    // 6th attempt hits the lockout branch (attempts >= 5), which clears rate
    await request("POST", "/v1/auth/verify-code", { email, code: "000000" });

    // Rate entry should now be cleared
    const rateRaw = await env.CODES.get(`rate:${email}`);
    expect(rateRaw).toBeNull();
  });

  it("returns 410 for expired/missing code", async () => {
    const res = await request("POST", "/v1/auth/verify-code", {
      email: "nocode@example.com",
      code: "123456",
    });
    expect(res.status).toBe(410);
  });

  it("rejects missing fields", async () => {
    const res = await request("POST", "/v1/auth/verify-code", {
      email: "test@example.com",
    });
    expect(res.status).toBe(400);
  });
});

// ─── Edge Cases ──────────────────────────────────────────────

describe("edge cases", () => {
  it("returns 404 for unknown routes", async () => {
    const res = await request("POST", "/v1/auth/unknown");
    expect(res.status).toBe(404);
  });

  it("returns 404 for old non-prefixed routes", async () => {
    const res = await request("POST", "/send-code");
    expect(res.status).toBe(404);
  });

  it("returns 405 for GET on /v1/auth/send-code", async () => {
    const res = await request("GET", "/v1/auth/send-code");
    expect(res.status).toBe(405);
  });

  it("handles CORS preflight", async () => {
    const req = new Request("http://localhost/v1/auth/send-code", {
      method: "OPTIONS",
    });
    const ctx = createExecutionContext();
    const res = await worker.fetch(req, env as unknown as WorkerEnv, ctx);
    await waitOnExecutionContext(ctx);
    expect(res.status).toBe(204);
    expect(res.headers.get("Access-Control-Allow-Methods")).toContain("POST");
  });
});
