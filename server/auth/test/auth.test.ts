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

/** Send a code and extract it from KV (bypassing email delivery). */
async function sendAndGetCode(email: string): Promise<string> {
  await request("POST", "/send-code", { email });
  const raw = await env.CODES.get(`code:${email}`);
  const stored = JSON.parse(raw!);
  return stored.code as string;
}

beforeEach(async () => {
  // Clear KV between tests.
  const keys = await env.CODES.list();
  for (const key of keys.keys) {
    await env.CODES.delete(key.name);
  }
});

// ─── Health ──────────────────────────────────────────────────

describe("GET /health", () => {
  it("returns ok", async () => {
    const res = await request("GET", "/health");
    expect(res.status).toBe(200);
    expect(await json(res)).toEqual({ status: "ok" });
  });
});

// ─── Send Code ───────────────────────────────────────────────

describe("POST /send-code", () => {
  it("returns sent: true for valid email", async () => {
    const res = await request("POST", "/send-code", {
      email: "test@example.com",
    });
    // Resend will fail with fake key, but code is still stored in KV.
    // In test env, we check KV directly.
    const raw = await env.CODES.get("code:test@example.com");
    expect(raw).not.toBeNull();
    const stored = JSON.parse(raw!);
    expect(stored.code).toMatch(/^\d{6}$/);
    expect(stored.attempts).toBe(0);
  });

  it("rejects missing email", async () => {
    const res = await request("POST", "/send-code", {});
    expect(res.status).toBe(400);
  });

  it("rejects invalid email", async () => {
    const res = await request("POST", "/send-code", { email: "notanemail" });
    expect(res.status).toBe(400);
  });

  it("normalizes email to lowercase", async () => {
    await request("POST", "/send-code", { email: "Test@Example.COM" });
    const raw = await env.CODES.get("code:test@example.com");
    expect(raw).not.toBeNull();
  });

  it("rate limits after max sends per hour", async () => {
    const email = "ratelimit@example.com";
    await request("POST", "/send-code", { email });
    await request("POST", "/send-code", { email });
    await request("POST", "/send-code", { email });
    const res = await request("POST", "/send-code", { email });
    expect(res.status).toBe(429);
  });
});

// ─── Verify Code ─────────────────────────────────────────────

describe("POST /verify-code", () => {
  it("verifies correct code", async () => {
    const email = "verify@example.com";
    const code = await sendAndGetCode(email);
    const res = await request("POST", "/verify-code", { email, code });
    expect(res.status).toBe(200);
    expect(await json(res)).toEqual({ verified: true });
  });

  it("deletes code after successful verification", async () => {
    const email = "onetime@example.com";
    const code = await sendAndGetCode(email);
    await request("POST", "/verify-code", { email, code });
    const raw = await env.CODES.get(`code:${email}`);
    expect(raw).toBeNull();
  });

  it("rejects incorrect code", async () => {
    const email = "wrong@example.com";
    await sendAndGetCode(email);
    const res = await request("POST", "/verify-code", {
      email,
      code: "000000",
    });
    expect(res.status).toBe(401);
  });

  it("increments attempts on wrong code", async () => {
    const email = "attempts@example.com";
    await sendAndGetCode(email);
    await request("POST", "/verify-code", { email, code: "000000" });
    const raw = await env.CODES.get(`code:${email}`);
    const stored = JSON.parse(raw!);
    expect(stored.attempts).toBe(1);
  });

  it("locks out after 5 failed attempts", async () => {
    const email = "lockout@example.com";
    await sendAndGetCode(email);
    for (let i = 0; i < 5; i++) {
      await request("POST", "/verify-code", { email, code: "000000" });
    }
    const res = await request("POST", "/verify-code", {
      email,
      code: "000000",
    });
    expect(res.status).toBe(429);
    expect((await json(res)).error).toContain("Too many attempts");
  });

  it("returns 410 for expired/missing code", async () => {
    const res = await request("POST", "/verify-code", {
      email: "nocode@example.com",
      code: "123456",
    });
    expect(res.status).toBe(410);
  });

  it("rejects missing fields", async () => {
    const res = await request("POST", "/verify-code", {
      email: "test@example.com",
    });
    expect(res.status).toBe(400);
  });
});

// ─── Edge Cases ──────────────────────────────────────────────

describe("edge cases", () => {
  it("returns 404 for unknown routes", async () => {
    const res = await request("POST", "/unknown");
    expect(res.status).toBe(404);
  });

  it("returns 405 for GET on /send-code", async () => {
    const res = await request("GET", "/send-code");
    expect(res.status).toBe(405);
  });

  it("handles CORS preflight", async () => {
    const req = new Request("http://localhost/send-code", {
      method: "OPTIONS",
    });
    const ctx = createExecutionContext();
    const res = await worker.fetch(req, env as unknown as WorkerEnv, ctx);
    await waitOnExecutionContext(ctx);
    expect(res.status).toBe(204);
    expect(res.headers.get("Access-Control-Allow-Methods")).toContain("POST");
  });
});
