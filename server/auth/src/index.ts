/**
 * Blip email verification worker.
 *
 * POST /v1/auth/send-code   — generate 6-digit code, send via Resend, store in KV
 * POST /v1/auth/verify-code — validate code against KV
 * GET  /v1/auth/health      — liveness check
 */
import { Resend } from "resend";

export interface Env {
  CODES: KVNamespace;
  RESEND_API_KEY: string;
  FROM_EMAIL: string;
  CODE_TTL_SECONDS: string;
  MAX_SENDS_PER_HOUR: string;
  /** Set to e.g. "https://heyblip.au" in production. Defaults to "*" for dev. */
  CORS_ORIGIN?: string;
  /** Set to "true" to skip Resend and use a fixed test code (000000). */
  DEV_BYPASS?: string;
  /** Neon Postgres connection string. Set via `wrangler secret put DATABASE_URL`. */
  DATABASE_URL?: string;
}

/** KV value stored alongside each code. */
interface StoredCode {
  code: string;
  attempts: number;
  createdAt: number;
}

/** KV value for per-email rate limiting. */
interface RateEntry {
  timestamps: number[];
}

const MAX_VERIFY_ATTEMPTS = 5;

interface RegisterBody {
  emailHash?: string;
  username?: string;
  createdAt?: string;
  isVerified?: boolean;
  noisePublicKey?: string;
  signingPublicKey?: string;
}

interface SyncBody {
  emailHash?: string;
  isVerified?: boolean;
  messageBalance?: number;
  lastActiveAt?: string;
}

interface ReceiptVerifyBody {
  transactionID?: string;
  productID?: string;
  originalID?: string;
  purchaseDate?: string;
  emailHash?: string;
  environment?: string;
}

function corsHeaders(env: Env): Record<string, string> {
  return {
    "Access-Control-Allow-Origin": env.CORS_ORIGIN ?? "*",
    "Access-Control-Allow-Methods": "POST, GET, OPTIONS",
    "Access-Control-Allow-Headers": "Content-Type",
  };
}

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    if (request.method === "OPTIONS") {
      return new Response(null, { status: 204, headers: corsHeaders(env) });
    }

    const url = new URL(request.url);

    if (url.pathname === "/v1/auth/health") {
      return json({ status: "ok" }, 200, env);
    }

    // GET routes (besides health)
    if (request.method === "GET" && url.pathname.startsWith("/v1/users/lookup/")) {
        return handleLookupByUsername(url, env);
    }
    if (request.method === "GET" && url.pathname.startsWith("/v1/users/")) {
        return handleGetUser(url, env);
    }

    if (request.method !== "POST") {
      return json({ error: "Method not allowed" }, 405, env);
    }

    switch (url.pathname) {
      case "/v1/auth/send-code":
        return handleSendCode(request, env);
      case "/v1/auth/verify-code":
        return handleVerifyCode(request, env);
      case "/v1/users/register":
        return handleRegister(request, env);
      case "/v1/users/sync":
        return handleSync(request, env);
      case "/v1/receipts/verify":
        return handleReceiptVerify(request, env);
      default:
        return json({ error: "Not found" }, 404, env);
    }
  },
};

// ─── Send Code ───────────────────────────────────────────────

async function handleSendCode(request: Request, env: Env): Promise<Response> {
  const body = await parseBody<{ email?: string }>(request);
  if (!body || !body.email) {
    return json({ error: "Missing email" }, 400, env);
  }

  const email = body.email.trim().toLowerCase();
  if (!isValidEmail(email)) {
    return json({ error: "Invalid email address" }, 400, env);
  }

  // Rate limit: max N sends per email per hour.
  const maxSends = parseInt(env.MAX_SENDS_PER_HOUR, 10) || 3;
  const rateLimited = await checkRateLimit(env, email, maxSends);
  if (rateLimited) {
    return json({ error: "Too many requests. Try again later." }, 429, env);
  }

  const devBypass = env.DEV_BYPASS === "true";
  const code = devBypass ? "000000" : generateCode();
  const ttl = parseInt(env.CODE_TTL_SECONDS, 10) || 600;

  // In dev bypass mode, skip Resend entirely — use code 000000.
  if (!devBypass) {
    const resend = new Resend(env.RESEND_API_KEY);
    const { error } = await resend.emails.send({
      from: env.FROM_EMAIL,
      to: email,
      subject: "Blip — Your verification code",
      html: emailTemplate(code),
    });

    if (error) {
      return json({ error: "Failed to send email" }, 502, env);
    }
  }

  // Store code in KV with TTL.
  const stored: StoredCode = {
    code,
    attempts: 0,
    createdAt: Date.now(),
  };
  await env.CODES.put(codeKey(email), JSON.stringify(stored), {
    expirationTtl: ttl,
  });

  // Record rate limit timestamp.
  await recordSend(env, email);

  return json({ sent: true }, 200, env);
}

// ─── Verify Code ─────────────────────────────────────────────

async function handleVerifyCode(
  request: Request,
  env: Env
): Promise<Response> {
  const body = await parseBody<{ email?: string; code?: string }>(request);
  if (!body || !body.email || !body.code) {
    return json({ error: "Missing email or code" }, 400, env);
  }

  const email = body.email.trim().toLowerCase();
  const raw = await env.CODES.get(codeKey(email));

  if (!raw) {
    return json({ error: "Code expired or not found" }, 410, env);
  }

  const stored: StoredCode = JSON.parse(raw);

  if (stored.attempts >= MAX_VERIFY_ATTEMPTS) {
    await env.CODES.delete(codeKey(email));
    // Clear rate limit so user can immediately request a fresh code.
    await env.CODES.delete(rateKey(email));
    return json({ error: "Too many attempts. Request a new code." }, 429, env);
  }

  if (stored.code !== body.code.trim()) {
    stored.attempts += 1;
    const ttl = parseInt(env.CODE_TTL_SECONDS, 10) || 600;
    const elapsed = Math.floor((Date.now() - stored.createdAt) / 1000);
    const remaining = Math.max(ttl - elapsed, 60);
    await env.CODES.put(codeKey(email), JSON.stringify(stored), {
      expirationTtl: remaining,
    });
    return json({ error: "Incorrect code" }, 401, env);
  }

  // Code matches — delete it so it can't be reused.
  await env.CODES.delete(codeKey(email));

  return json({ verified: true }, 200, env);
}

// ─── Rate Limiting ───────────────────────────────────────────

async function checkRateLimit(
  env: Env,
  email: string,
  maxSends: number
): Promise<boolean> {
  const raw = await env.CODES.get(rateKey(email));
  if (!raw) return false;

  const entry: RateEntry = JSON.parse(raw);
  const oneHourAgo = Date.now() - 3600_000;
  const recent = entry.timestamps.filter((t) => t > oneHourAgo);
  return recent.length >= maxSends;
}

async function recordSend(env: Env, email: string): Promise<void> {
  const raw = await env.CODES.get(rateKey(email));
  const entry: RateEntry = raw ? JSON.parse(raw) : { timestamps: [] };
  const oneHourAgo = Date.now() - 3600_000;

  entry.timestamps = entry.timestamps.filter((t) => t > oneHourAgo);
  entry.timestamps.push(Date.now());

  await env.CODES.put(rateKey(email), JSON.stringify(entry), {
    expirationTtl: 3600,
  });
}

// ─── Neon Database ──────────────────────────────────────────

async function getDb(env: Env) {
  if (!env.DATABASE_URL) {
    return null;
  }
  const { neon } = await import("@neondatabase/serverless");
  return neon(env.DATABASE_URL);
}

// ─── Register User ──────────────────────────────────────────

async function handleRegister(request: Request, env: Env): Promise<Response> {
  const body = sanitizeRegisterBody(await parseBody<RegisterBody>(request));

  if (!body) {
    return json({ error: "Missing emailHash or username" }, 400, env);
  }

  const sql = await getDb(env);
  if (!sql) {
    return json({ error: "Database not configured" }, 503, env);
  }

  const noiseKey = body.noisePublicKey ? hexToBuffer(body.noisePublicKey) : null;
  const signingKey = body.signingPublicKey ? hexToBuffer(body.signingPublicKey) : null;

  try {
    const result = await sql`
      INSERT INTO users (email_hash, username, is_verified, created_at, noise_public_key, signing_public_key)
      VALUES (${body.emailHash}, ${body.username}, FALSE, ${body.createdAt}, ${noiseKey}, ${signingKey})
      ON CONFLICT (email_hash) DO UPDATE SET
        username = EXCLUDED.username,
        noise_public_key = COALESCE(EXCLUDED.noise_public_key, users.noise_public_key),
        signing_public_key = COALESCE(EXCLUDED.signing_public_key, users.signing_public_key),
        updated_at = NOW()
      RETURNING id
    `;
    return json({ userId: result[0]?.id }, 201, env);
  } catch (error: any) {
    if (error.message?.includes("users_username_key")) {
      return json({ error: "Username already taken" }, 409, env);
    }
    return json({ error: "Registration failed" }, 500, env);
  }
}

// ─── Sync User ──────────────────────────────────────────────

async function handleSync(request: Request, env: Env): Promise<Response> {
  const body = sanitizeSyncBody(await parseBody<SyncBody>(request));

  if (!body) {
    return json({ error: "Missing emailHash" }, 400, env);
  }

  const sql = await getDb(env);
  if (!sql) {
    return json({ error: "Database not configured" }, 503, env);
  }

  try {
    const result = await sql`
      UPDATE users SET
        last_active_at = COALESCE(${body.lastActiveAt ?? null}, last_active_at),
        updated_at = NOW()
      WHERE email_hash = ${body.emailHash}
      RETURNING id, is_verified, message_balance
    `;

    if (result.length === 0) {
      return json({ error: "User not found" }, 404, env);
    }

    return json({ synced: true, user: result[0] }, 200, env);
  } catch {
    return json({ error: "Sync failed" }, 500, env);
  }
}

// ─── Get User ───────────────────────────────────────────────

async function handleGetUser(url: URL, env: Env): Promise<Response> {
  const parts = url.pathname.split("/");
  const emailHash = parts[parts.length - 1];

  if (!emailHash || emailHash === "users") {
    return json({ error: "Missing emailHash" }, 400, env);
  }

  const sql = await getDb(env);
  if (!sql) {
    return json({ error: "Database not configured" }, 503, env);
  }

  try {
    const result = await sql`
      SELECT id, username, is_verified, message_balance, last_active_at, created_at
      FROM users WHERE email_hash = ${emailHash}
    `;

    if (result.length === 0) {
      return json({ error: "User not found" }, 404, env);
    }

    return json({ user: result[0] }, 200, env);
  } catch {
    return json({ error: "Lookup failed" }, 500, env);
  }
}

// ─── Receipt Verification ───────────────────────────────────

async function handleReceiptVerify(request: Request, env: Env): Promise<Response> {
  const body = await parseBody<ReceiptVerifyBody>(request);

  if (!body || !body.transactionID || !body.productID) {
    return json({ error: "Missing transactionID or productID" }, 400, env);
  }

  return json({ error: "Receipt verification is not configured" }, 501, env);
}

function getMessageCredits(productID: string): number {
  const credits: Record<string, number> = {
    "com.blip.starter10": 10,
    "com.blip.social25": 25,
    "com.blip.festival50": 50,
    "com.blip.squad100": 100,
    "com.blip.season1000": 1000,
  };
  return credits[productID] ?? 0;
}

// ─── Lookup by Username ─────────────────────────────────────

async function handleLookupByUsername(url: URL, env: Env): Promise<Response> {
  const parts = url.pathname.split("/");
  const username = parts[parts.length - 1];

  if (!username || username === "lookup") {
    return json({ error: "Missing username" }, 400, env);
  }

  const sql = await getDb(env);
  if (!sql) {
    return json({ error: "Database not configured" }, 503, env);
  }

  try {
    const result = await sql`
      SELECT id, username, is_verified, noise_public_key, signing_public_key, last_active_at
      FROM users WHERE LOWER(username) = LOWER(${username})
    `;

    if (result.length === 0) {
      return json({ error: "User not found" }, 404, env);
    }

    const row = result[0];
    return json({
      user: {
        id: row.id,
        username: row.username,
        isVerified: row.is_verified,
        noisePublicKey: row.noise_public_key ? bufferToHex(row.noise_public_key) : null,
        signingPublicKey: row.signing_public_key ? bufferToHex(row.signing_public_key) : null,
        lastActiveAt: row.last_active_at,
      },
    }, 200, env);
  } catch {
    return json({ error: "Lookup failed" }, 500, env);
  }
}

function hexToBuffer(hex: string): Uint8Array {
  const bytes = new Uint8Array(hex.length / 2);
  for (let i = 0; i < hex.length; i += 2) {
    bytes[i / 2] = parseInt(hex.substring(i, i + 2), 16);
  }
  return bytes;
}

function bufferToHex(buf: any): string {
  if (buf instanceof Uint8Array || buf instanceof ArrayBuffer) {
    return Array.from(new Uint8Array(buf)).map(b => b.toString(16).padStart(2, "0")).join("");
  }
  if (typeof buf === "string") return buf;
  return "";
}

function isValidHexKey(key: string | undefined): key is string {
  return typeof key === "string" && /^[a-f0-9]{64}$/i.test(key);
}

// ─── Helpers ─────────────────────────────────────────────────

function codeKey(email: string): string {
  return `code:${email}`;
}

function rateKey(email: string): string {
  return `rate:${email}`;
}

function generateCode(): string {
  const array = new Uint32Array(1);
  crypto.getRandomValues(array);
  return String(array[0] % 1_000_000).padStart(6, "0");
}

function isValidEmail(email: string): boolean {
  return /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email);
}

export function isValidEmailHash(emailHash: string): boolean {
  return /^[a-f0-9]{64}$/i.test(emailHash);
}

export function sanitizeRegisterBody(
  body: RegisterBody | null
): { emailHash: string; username: string; createdAt: string; noisePublicKey?: string; signingPublicKey?: string } | null {
  if (!body?.emailHash || !body.username) {
    return null;
  }

  const emailHash = body.emailHash.trim().toLowerCase();
  const username = body.username.trim();

  if (!emailHash || !username || !isValidEmailHash(emailHash)) {
    return null;
  }

  return {
    emailHash,
    username,
    createdAt: body.createdAt ?? new Date().toISOString(),
    noisePublicKey: isValidHexKey(body.noisePublicKey) ? body.noisePublicKey : undefined,
    signingPublicKey: isValidHexKey(body.signingPublicKey) ? body.signingPublicKey : undefined,
  };
}

export function sanitizeSyncBody(
  body: SyncBody | null
): { emailHash: string; lastActiveAt: string | null } | null {
  if (!body?.emailHash) {
    return null;
  }

  const emailHash = body.emailHash.trim().toLowerCase();
  if (!isValidEmailHash(emailHash)) {
    return null;
  }

  return {
    emailHash,
    lastActiveAt: body.lastActiveAt ?? null,
  };
}

async function parseBody<T>(request: Request): Promise<T | null> {
  try {
    return (await request.json()) as T;
  } catch {
    return null;
  }
}

function json(data: unknown, status = 200, env?: Env): Response {
  const cors = env ? corsHeaders(env) : { "Access-Control-Allow-Origin": "*", "Access-Control-Allow-Methods": "POST, GET, OPTIONS", "Access-Control-Allow-Headers": "Content-Type" };
  return new Response(JSON.stringify(data), {
    status,
    headers: { "Content-Type": "application/json", ...cors },
  });
}

function emailTemplate(code: string): string {
  return `
    <div style="font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif; max-width: 400px; margin: 0 auto; padding: 40px 20px;">
      <h2 style="color: #6600FF; margin-bottom: 8px;">Blip</h2>
      <p style="color: #333; font-size: 16px; margin-bottom: 24px;">Your verification code is:</p>
      <div style="background: #F5F0FF; border-radius: 12px; padding: 24px; text-align: center; margin-bottom: 24px;">
        <span style="font-size: 32px; font-weight: 700; letter-spacing: 8px; color: #6600FF;">${code}</span>
      </div>
      <p style="color: #888; font-size: 13px;">This code expires in 10 minutes. If you didn't request this, you can ignore this email.</p>
    </div>
  `;
}
