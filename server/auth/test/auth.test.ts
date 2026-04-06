import {
  env,
  createExecutionContext,
  waitOnExecutionContext,
} from "cloudflare:test";
import { describe, it, expect, beforeEach, vi } from "vitest";
vi.mock("@neondatabase/serverless", () => ({
  neon: () => async (strings: TemplateStringsArray, ...values: unknown[]) => {
    const users = ((globalThis as any).__blipAuthMockUsers ??= []) as MockUser[];
    const normalized = strings.join(" ").replace(/\s+/g, " ").trim().toLowerCase();

    if (normalized.includes("select id, noise_public_key, signing_public_key from users where noise_public_key =")) {
      const requestedKey = values[0] as Uint8Array;
      return users
        .filter((user) => user.noise_public_key && bytesEqual(user.noise_public_key, requestedKey))
        .map((user) => ({
          id: user.id,
          noise_public_key: user.noise_public_key,
          signing_public_key: user.signing_public_key,
        }));
    }

    if (normalized.includes("update users set") && normalized.includes("where email_hash =")) {
      const lastActiveAt = values[0] as string | null;
      const emailHash = values[1] as string;
      const user = users.find((candidate) => candidate.email_hash === emailHash);
      if (!user) {
        return [];
      }
      user.last_active_at = lastActiveAt;
      user.updated_at = new Date().toISOString();
      return [{
        id: user.id,
        is_verified: user.is_verified,
        message_balance: user.message_balance,
      }];
    }

    if (normalized.includes("select id, username, is_verified, message_balance, last_active_at, created_at from users where email_hash =")) {
      const emailHash = values[0] as string;
      const user = users.find((candidate) => candidate.email_hash === emailHash);
      return user ? [{
        id: user.id,
        username: user.username,
        is_verified: user.is_verified,
        message_balance: user.message_balance,
        last_active_at: user.last_active_at,
        created_at: user.created_at,
      }] : [];
    }

    if (normalized.includes("select id, username, is_verified, noise_public_key, signing_public_key, last_active_at from users where lower(username) = lower(")) {
      const username = String(values[0]).toLowerCase();
      const user = users.find((candidate) => candidate.username.toLowerCase() === username);
      return user ? [{
        id: user.id,
        username: user.username,
        is_verified: user.is_verified,
        noise_public_key: user.noise_public_key,
        signing_public_key: user.signing_public_key,
        last_active_at: user.last_active_at,
      }] : [];
    }

    throw new Error(`Unhandled mock SQL query: ${normalized}`);
  },
}));
import worker, {
  isValidEmailHash,
  signJWT,
  sanitizeRegisterBody,
  sanitizeSyncBody,
  verifyJWT,
} from "../src/index";

type WorkerEnv = typeof env;

interface MockUser {
  id: string;
  email_hash: string;
  username: string;
  is_verified: boolean;
  message_balance: number;
  last_active_at: string | null;
  created_at: string;
  updated_at: string;
  noise_public_key: Uint8Array | null;
  signing_public_key: Uint8Array | null;
}

async function request(
  method: string,
  path: string,
  body?: Record<string, unknown>,
  headers: Record<string, string> = {}
): Promise<Response> {
  const init: RequestInit = {
    method,
    headers: { "Content-Type": "application/json", ...headers },
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

function bytesToHex(data: BufferSource): string {
  const bytes = data instanceof ArrayBuffer ? new Uint8Array(data) : new Uint8Array(data.buffer, data.byteOffset, data.byteLength);
  return Array.from(bytes)
    .map((byte) => byte.toString(16).padStart(2, "0"))
    .join("");
}

function hexToBytes(hex: string): Uint8Array {
  const bytes = new Uint8Array(hex.length / 2);
  for (let i = 0; i < hex.length; i += 2) {
    bytes[i / 2] = parseInt(hex.substring(i, i + 2), 16);
  }
  return bytes;
}

function bytesEqual(left: Uint8Array, right: Uint8Array): boolean {
  if (left.length !== right.length) {
    return false;
  }

  for (let i = 0; i < left.length; i += 1) {
    if (left[i] !== right[i]) {
      return false;
    }
  }

  return true;
}

function base64Encode(bytes: Uint8Array): string {
  let binary = "";
  for (const byte of bytes) {
    binary += String.fromCharCode(byte);
  }
  return btoa(binary);
}

function mockUsers(): MockUser[] {
  return (((globalThis as any).__blipAuthMockUsers ??= []) as MockUser[]);
}

function resetMockUsers(): void {
  mockUsers().length = 0;
}

async function seedAuthUser(username = "alice"): Promise<{
  user: MockUser;
  noisePublicKey: Uint8Array;
  signingPrivateKey: CryptoKey;
}> {
  const noisePublicKey = crypto.getRandomValues(new Uint8Array(32));
  const signingKeyPair = await crypto.subtle.generateKey("Ed25519", true, ["sign", "verify"]);
  const signingPublicKey = new Uint8Array(await crypto.subtle.exportKey("raw", signingKeyPair.publicKey));
  const now = new Date().toISOString();

  const user: MockUser = {
    id: crypto.randomUUID(),
    email_hash: "a".repeat(64),
    username,
    is_verified: true,
    message_balance: 5,
    last_active_at: now,
    created_at: now,
    updated_at: now,
    noise_public_key: noisePublicKey,
    signing_public_key: signingPublicKey,
  };

  mockUsers().push(user);
  return { user, noisePublicKey, signingPrivateKey: signingKeyPair.privateKey };
}

async function issueTimestampSignature(privateKey: CryptoKey, timestamp: string): Promise<string> {
  const signature = await crypto.subtle.sign("Ed25519", privateKey, new TextEncoder().encode(timestamp));
  return base64Encode(new Uint8Array(signature));
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
  (env as Record<string, unknown>).DEV_BYPASS = "false";
  (env as Record<string, unknown>).JWT_SECRET = "test-jwt-secret";
  (env as Record<string, unknown>).JWT_EXPIRY_SECONDS = "3600";
  (env as Record<string, unknown>).JWT_REFRESH_GRACE_SECONDS = "300";
  delete (env as Record<string, unknown>).DATABASE_URL;
  resetMockUsers();
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

  it("sends code successfully in DEV_BYPASS mode", async () => {
    (env as Record<string, unknown>).DEV_BYPASS = "true";
    const res = await request("POST", "/v1/auth/send-code", {
      email: "test@example.com",
    });
    expect(res.status).toBe(200);
    expect(await json(res)).toEqual({ sent: true });
    // Code should be stored with bypass code
    const raw = await env.CODES.get("code:test@example.com");
    expect(raw).not.toBeNull();
    const stored = JSON.parse(raw!);
    expect(stored.code).toBe("000000");
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

describe("POST /v1/auth/challenge", () => {
  it("returns a one-time 32-byte challenge and stores it in KV", async () => {
    const res = await request("POST", "/v1/auth/challenge", {});
    expect(res.status).toBe(200);

    const body = await json(res);
    const challenge = body.challenge;
    expect(typeof challenge).toBe("string");
    expect(challenge).toMatch(/^[a-f0-9]{64}$/i);

    const stored = await env.CODES.get(`challenge:${challenge as string}`);
    expect(stored).toBe("1");
  });

  it("allows requests under the per-IP limit", async () => {
    for (let attempt = 0; attempt < 5; attempt += 1) {
      const res = await request(
        "POST",
        "/v1/auth/challenge",
        {},
        { "CF-Connecting-IP": "203.0.113.10" }
      );
      expect(res.status).toBe(200);
    }

    const storedCount = await env.CODES.get("ratelimit:203.0.113.10");
    expect(storedCount).toBe("5");
  });

  it("blocks requests once the per-IP limit is reached", async () => {
    for (let attempt = 0; attempt < 5; attempt += 1) {
      const res = await request(
        "POST",
        "/v1/auth/challenge",
        {},
        { "CF-Connecting-IP": "203.0.113.20" }
      );
      expect(res.status).toBe(200);
    }

    const blocked = await request(
      "POST",
      "/v1/auth/challenge",
      {},
      { "CF-Connecting-IP": "203.0.113.20" }
    );
    expect(blocked.status).toBe(429);
    expect(await json(blocked)).toEqual({
      error: "Too many requests. Try again later.",
    });
  });

  it("tracks different IPs independently", async () => {
    for (let attempt = 0; attempt < 5; attempt += 1) {
      const res = await request(
        "POST",
        "/v1/auth/challenge",
        {},
        { "CF-Connecting-IP": "203.0.113.30" }
      );
      expect(res.status).toBe(200);
    }

    const blocked = await request(
      "POST",
      "/v1/auth/challenge",
      {},
      { "CF-Connecting-IP": "203.0.113.30" }
    );
    expect(blocked.status).toBe(429);

    const otherIP = await request(
      "POST",
      "/v1/auth/challenge",
      {},
      { "CF-Connecting-IP": "203.0.113.31" }
    );
    expect(otherIP.status).toBe(200);
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

describe("POST /v1/users/register challenge verification", () => {
  it("rejects key registration without challenge and signature", async () => {
    const res = await request("POST", "/v1/users/register", {
      emailHash: "a".repeat(64),
      username: "alice",
      noisePublicKey: "1".repeat(64),
      signingPublicKey: "2".repeat(64),
    });

    expect(res.status).toBe(400);
    expect((await json(res)).error).toContain("Missing challenge or signature");
  });

  it("rejects key registration with an invalid or expired challenge", async () => {
    const res = await request("POST", "/v1/users/register", {
      emailHash: "a".repeat(64),
      username: "alice",
      noisePublicKey: "1".repeat(64),
      signingPublicKey: "2".repeat(64),
      challenge: "3".repeat(64),
      signature: "4".repeat(128),
    });

    expect(res.status).toBe(401);
    expect((await json(res)).error).toContain("Challenge expired or invalid");
  });

  it("verifies a valid signature before touching the database", async () => {
    const challengeResponse = await request("POST", "/v1/auth/challenge", {});
    const challengeBody = await json(challengeResponse);
    const challenge = challengeBody.challenge as string;

    const keyPair = await crypto.subtle.generateKey("Ed25519", true, ["sign", "verify"]);
    const publicKey = await crypto.subtle.exportKey("raw", keyPair.publicKey);
    const signature = await crypto.subtle.sign("Ed25519", keyPair.privateKey, hexToBytes(challenge));

    const res = await request("POST", "/v1/users/register", {
      emailHash: "a".repeat(64),
      username: "alice",
      noisePublicKey: "1".repeat(64),
      signingPublicKey: bytesToHex(publicKey),
      challenge,
      signature: bytesToHex(signature),
    });

    expect(res.status).toBe(503);
    expect((await json(res)).error).toContain("Database not configured");

    const storedChallenge = await env.CODES.get(`challenge:${challenge}`);
    expect(storedChallenge).toBeNull();
  });
});

describe("JWT session tokens", () => {
  it("issues a token for a valid signed timestamp", async () => {
    (env as Record<string, unknown>).DATABASE_URL = "mock://db";
    const { noisePublicKey, signingPrivateKey } = await seedAuthUser();
    const timestamp = new Date().toISOString();
    const signature = await issueTimestampSignature(signingPrivateKey, timestamp);

    const res = await request("POST", "/v1/auth/token", {
      noisePublicKey: base64Encode(noisePublicKey),
      timestamp,
      signature,
    });

    expect(res.status).toBe(200);
    const body = await json(res);
    expect(typeof body.token).toBe("string");
    expect(typeof body.expiresAt).toBe("string");

    const claims = await verifyJWT(body.token as string, "test-jwt-secret");
    expect(claims?.npk).toBe(base64Encode(noisePublicKey));
    expect(typeof claims?.sub).toBe("string");
  });

  it("rejects token issuance with an invalid signature", async () => {
    (env as Record<string, unknown>).DATABASE_URL = "mock://db";
    const { noisePublicKey } = await seedAuthUser();

    const res = await request("POST", "/v1/auth/token", {
      noisePublicKey: base64Encode(noisePublicKey),
      timestamp: new Date().toISOString(),
      signature: base64Encode(crypto.getRandomValues(new Uint8Array(64))),
    });

    expect(res.status).toBe(401);
  });

  it("rejects token issuance with an expired timestamp", async () => {
    (env as Record<string, unknown>).DATABASE_URL = "mock://db";
    const { noisePublicKey, signingPrivateKey } = await seedAuthUser();
    const timestamp = new Date(Date.now() - 120_000).toISOString();
    const signature = await issueTimestampSignature(signingPrivateKey, timestamp);

    const res = await request("POST", "/v1/auth/token", {
      noisePublicKey: base64Encode(noisePublicKey),
      timestamp,
      signature,
    });

    expect(res.status).toBe(400);
  });

  it("refreshes a valid token", async () => {
    const noisePublicKey = crypto.getRandomValues(new Uint8Array(32));
    const claims = {
      sub: "1122334455667788",
      npk: base64Encode(noisePublicKey),
      iat: Math.floor(Date.now() / 1000),
      exp: Math.floor(Date.now() / 1000) + 1200,
    };
    const token = await signJWT(claims, "test-jwt-secret");

    const res = await request("POST", "/v1/auth/refresh", undefined, {
      Authorization: `Bearer ${token}`,
    });

    expect(res.status).toBe(200);
    const body = await json(res);
    const refreshed = await verifyJWT(body.token as string, "test-jwt-secret");
    expect(refreshed?.npk).toBe(claims.npk);
    expect((refreshed?.exp ?? 0)).toBeGreaterThan(claims.exp);
  });

  it("refreshes an expired token within the grace window", async () => {
    const nowSeconds = Math.floor(Date.now() / 1000);
    const token = await signJWT({
      sub: "1122334455667788",
      npk: base64Encode(crypto.getRandomValues(new Uint8Array(32))),
      iat: nowSeconds - 4000,
      exp: nowSeconds - 60,
    }, "test-jwt-secret");

    const res = await request("POST", "/v1/auth/refresh", undefined, {
      Authorization: `Bearer ${token}`,
    });

    expect(res.status).toBe(200);
  });

  it("rejects refresh when the token is past the grace window", async () => {
    const nowSeconds = Math.floor(Date.now() / 1000);
    const token = await signJWT({
      sub: "1122334455667788",
      npk: base64Encode(crypto.getRandomValues(new Uint8Array(32))),
      iat: nowSeconds - 5000,
      exp: nowSeconds - 400,
    }, "test-jwt-secret");

    const res = await request("POST", "/v1/auth/refresh", undefined, {
      Authorization: `Bearer ${token}`,
    });

    expect(res.status).toBe(401);
  });
});

describe("protected endpoints", () => {
  it("allows a protected endpoint with a valid JWT", async () => {
    (env as Record<string, unknown>).DATABASE_URL = "mock://db";
    const { user, noisePublicKey, signingPrivateKey } = await seedAuthUser();
    const timestamp = new Date().toISOString();
    const signature = await issueTimestampSignature(signingPrivateKey, timestamp);
    const tokenResponse = await request("POST", "/v1/auth/token", {
      noisePublicKey: base64Encode(noisePublicKey),
      timestamp,
      signature,
    });
    const tokenBody = await json(tokenResponse);
    const token = tokenBody.token as string;

    const res = await request("GET", `/v1/users/${user.email_hash}`, undefined, {
      Authorization: `Bearer ${token}`,
    });

    expect(res.status).toBe(200);
  });

  it("rejects a protected endpoint with no JWT", async () => {
    (env as Record<string, unknown>).DATABASE_URL = "mock://db";
    await seedAuthUser();

    const res = await request("GET", "/v1/users/lookup/alice");
    expect(res.status).toBe(401);
  });

  it("rejects a protected endpoint with an expired JWT", async () => {
    (env as Record<string, unknown>).DATABASE_URL = "mock://db";
    await seedAuthUser();
    const nowSeconds = Math.floor(Date.now() / 1000);
    const token = await signJWT({
      sub: "1122334455667788",
      npk: base64Encode(crypto.getRandomValues(new Uint8Array(32))),
      iat: nowSeconds - 3600,
      exp: nowSeconds - 1,
    }, "test-jwt-secret");

    const res = await request("GET", "/v1/users/lookup/alice", undefined, {
      Authorization: `Bearer ${token}`,
    });

    expect(res.status).toBe(401);
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

describe("input hardening", () => {
  it("validates email-hash format", () => {
    expect(isValidEmailHash("a".repeat(64))).toBe(true);
    expect(isValidEmailHash("not-a-hash")).toBe(false);
  });

  it("sanitizes registration payloads and strips privileged fields", () => {
    expect(
      sanitizeRegisterBody({
        emailHash: "A".repeat(64),
        username: "  alice  ",
        isVerified: true,
        challenge: "c".repeat(64),
        signature: "d".repeat(128),
      })
    ).toEqual({
      emailHash: "a".repeat(64),
      username: "alice",
      createdAt: expect.any(String),
      challenge: "c".repeat(64),
      signature: "d".repeat(128),
    });
  });

  it("sanitizes sync payloads and ignores privileged fields", () => {
    expect(
      sanitizeSyncBody({
        emailHash: "B".repeat(64),
        isVerified: true,
        messageBalance: 999,
        lastActiveAt: "2026-03-30T00:00:00Z",
      })
    ).toEqual({
      emailHash: "b".repeat(64),
      lastActiveAt: "2026-03-30T00:00:00Z",
    });
  });

  it("fails receipt verification closed", async () => {
    const res = await request("POST", "/v1/receipts/verify", {
      transactionID: "tx-1",
      productID: "com.blip.social25",
    });
    expect(res.status).toBe(501);
    expect((await json(res)).error).toContain("not configured");
  });
});
