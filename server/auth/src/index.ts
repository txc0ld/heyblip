/**
 * FestiChat email verification worker.
 *
 * POST /send-code   — generate 6-digit code, send via Resend, store in KV
 * POST /verify-code — validate code against KV
 * GET  /health      — liveness check
 */
import { Resend } from "resend";

export interface Env {
  CODES: KVNamespace;
  RESEND_API_KEY: string;
  FROM_EMAIL: string;
  CODE_TTL_SECONDS: string;
  MAX_SENDS_PER_HOUR: string;
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

const CORS_HEADERS: Record<string, string> = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Methods": "POST, GET, OPTIONS",
  "Access-Control-Allow-Headers": "Content-Type",
};

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    if (request.method === "OPTIONS") {
      return new Response(null, { status: 204, headers: CORS_HEADERS });
    }

    const url = new URL(request.url);

    if (url.pathname === "/health") {
      return json({ status: "ok" }, 200);
    }

    if (request.method !== "POST") {
      return json({ error: "Method not allowed" }, 405);
    }

    switch (url.pathname) {
      case "/send-code":
        return handleSendCode(request, env);
      case "/verify-code":
        return handleVerifyCode(request, env);
      default:
        return json({ error: "Not found" }, 404);
    }
  },
};

// ─── Send Code ───────────────────────────────────────────────

async function handleSendCode(request: Request, env: Env): Promise<Response> {
  const body = await parseBody<{ email?: string }>(request);
  if (!body || !body.email) {
    return json({ error: "Missing email" }, 400);
  }

  const email = body.email.trim().toLowerCase();
  if (!isValidEmail(email)) {
    return json({ error: "Invalid email address" }, 400);
  }

  // Rate limit: max N sends per email per hour.
  const maxSends = parseInt(env.MAX_SENDS_PER_HOUR, 10) || 3;
  const rateLimited = await checkRateLimit(env, email, maxSends);
  if (rateLimited) {
    return json({ error: "Too many requests. Try again later." }, 429);
  }

  const code = generateCode();
  const ttl = parseInt(env.CODE_TTL_SECONDS, 10) || 600;

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

  // Send via Resend.
  const resend = new Resend(env.RESEND_API_KEY);
  const { error } = await resend.emails.send({
    from: env.FROM_EMAIL,
    to: email,
    subject: "FestiChat — Your verification code",
    html: emailTemplate(code),
  });

  if (error) {
    return json({ error: "Failed to send email" }, 502);
  }

  return json({ sent: true });
}

// ─── Verify Code ─────────────────────────────────────────────

async function handleVerifyCode(
  request: Request,
  env: Env
): Promise<Response> {
  const body = await parseBody<{ email?: string; code?: string }>(request);
  if (!body || !body.email || !body.code) {
    return json({ error: "Missing email or code" }, 400);
  }

  const email = body.email.trim().toLowerCase();
  const raw = await env.CODES.get(codeKey(email));

  if (!raw) {
    return json({ error: "Code expired or not found" }, 410);
  }

  const stored: StoredCode = JSON.parse(raw);

  if (stored.attempts >= MAX_VERIFY_ATTEMPTS) {
    await env.CODES.delete(codeKey(email));
    return json({ error: "Too many attempts. Request a new code." }, 429);
  }

  if (stored.code !== body.code.trim()) {
    stored.attempts += 1;
    const ttl = parseInt(env.CODE_TTL_SECONDS, 10) || 600;
    const elapsed = Math.floor((Date.now() - stored.createdAt) / 1000);
    const remaining = Math.max(ttl - elapsed, 60);
    await env.CODES.put(codeKey(email), JSON.stringify(stored), {
      expirationTtl: remaining,
    });
    return json({ error: "Incorrect code" }, 401);
  }

  // Code matches — delete it so it can't be reused.
  await env.CODES.delete(codeKey(email));

  return json({ verified: true });
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

async function parseBody<T>(request: Request): Promise<T | null> {
  try {
    return (await request.json()) as T;
  } catch {
    return null;
  }
}

function json(data: unknown, status = 200): Response {
  return new Response(JSON.stringify(data), {
    status,
    headers: { "Content-Type": "application/json", ...CORS_HEADERS },
  });
}

function emailTemplate(code: string): string {
  return `
    <div style="font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif; max-width: 400px; margin: 0 auto; padding: 40px 20px;">
      <h2 style="color: #6600FF; margin-bottom: 8px;">FestiChat</h2>
      <p style="color: #333; font-size: 16px; margin-bottom: 24px;">Your verification code is:</p>
      <div style="background: #F5F0FF; border-radius: 12px; padding: 24px; text-align: center; margin-bottom: 24px;">
        <span style="font-size: 32px; font-weight: 700; letter-spacing: 8px; color: #6600FF;">${code}</span>
      </div>
      <p style="color: #888; font-size: 13px;">This code expires in 10 minutes. If you didn't request this, you can ignore this email.</p>
    </div>
  `;
}
