/**
 * Blip email verification worker.
 *
 * POST /v1/auth/challenge   — generate one-time Ed25519 registration nonce
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
  JWT_SECRET?: string;
  JWT_TTL_SECONDS?: string;
  JWT_EXPIRY_SECONDS?: string;
  JWT_REFRESH_GRACE_SECONDS?: string;
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
const MAX_CHALLENGES_PER_MINUTE = 3;
const CHALLENGE_RATE_LIMIT_WINDOW_SECONDS = 60;

interface RegisterBody {
  emailHash?: string;
  username?: string;
  createdAt?: string;
  isVerified?: boolean;
  noisePublicKey?: string;
  signingPublicKey?: string;
  challenge?: string;
  signature?: string;
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

interface TokenRequestBody {
  noisePublicKey?: string;
  timestamp?: string;
  signature?: string;
}

interface KeyUpdateBody {
  noisePublicKey?: string;
  signingPublicKey?: string;
}

export interface JWTPayload {
  sub: string;
  npk: string;
  iat: number;
  exp: number;
}

interface AuthContext {
  peerIdHex: string;
  noisePublicKey: Uint8Array;
  noisePublicKeyBase64: string;
  claims?: JWTPayload;
  source: "jwt" | "legacy";
}

class HTTPError extends Error {
  constructor(
    readonly status: number,
    message: string
  ) {
    super(message);
  }
}

const DEFAULT_JWT_EXPIRY_SECONDS = 3600;
const DEFAULT_REFRESH_GRACE_SECONDS = 300;
const TOKEN_TIMESTAMP_TOLERANCE_MS = 60_000;
const NOISE_PUBLIC_KEY_LENGTH = 32;
const ED25519_SIGNATURE_LENGTH = 64;

function corsHeaders(env: Env): Record<string, string> {
  return {
    "Access-Control-Allow-Origin": env.CORS_ORIGIN ?? "*",
    "Access-Control-Allow-Methods": "POST, GET, OPTIONS",
    "Access-Control-Allow-Headers": "Content-Type, Authorization",
    "X-Content-Type-Options": "nosniff",
    "X-Frame-Options": "DENY",
  };
}

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    if (request.method === "OPTIONS") {
      return new Response(null, { status: 204, headers: corsHeaders(env) });
    }

    const url = new URL(request.url);

    try {
      if (url.pathname === "/v1/auth/health") {
        return json({ status: "ok" }, 200, env);
      }

      // GET routes (besides health)
      if (request.method === "GET" && url.pathname.startsWith("/v1/users/lookup/")) {
          return handleLookupByUsername(request, url, env);
      }
      if (request.method === "GET" && url.pathname.startsWith("/v1/users/")) {
          return handleGetUser(request, url, env);
      }

      if (request.method !== "POST") {
        return json({ error: "Method not allowed" }, 405, env);
      }

      switch (url.pathname) {
        case "/v1/auth/challenge":
          return handleChallenge(request, env);
        case "/v1/auth/send-code":
          return handleSendCode(request, env);
        case "/v1/auth/verify-code":
          return handleVerifyCode(request, env);
        case "/v1/auth/token":
          return handleIssueToken(request, env);
        case "/v1/auth/refresh":
          return handleRefreshToken(request, env);
      case "/v1/users/register":
        return handleRegister(request, env);
      case "/v1/users/sync":
        return handleSync(request, env);
      case "/v1/users/keys":
        return handleKeys(request, env);
      case "/v1/receipts/verify":
        return handleReceiptVerify(request, env);
        default:
          return json({ error: "Not found" }, 404, env);
      }
    } catch (error) {
      if (error instanceof Response) {
        return error;
      }
      throw error;
    }
  },

  // Cron warmup: runs every 5 minutes to keep the Worker and Neon DB connection
  // warm, preventing cold-start timeouts (-1001) on real user requests.
  async scheduled(_event: ScheduledEvent, env: Env, ctx: ExecutionContext): Promise<void> {
    const sql = await getDb(env);
    if (sql) {
      ctx.waitUntil(sql`SELECT 1`.catch(() => {}));
    }
  },
};

// ─── Send Code ───────────────────────────────────────────────

async function handleChallenge(request: Request, env: Env): Promise<Response> {
  const ipAddress = request.headers.get("CF-Connecting-IP") ?? (env.DEV_BYPASS === "true" ? "dev-local" : null);
  if (!ipAddress) {
    return json({ error: "Unable to identify client" }, 400, env);
  }

  const rateLimited = await checkChallengeRateLimit(env, ipAddress);
  if (rateLimited) {
    return json({ error: "Too many requests. Try again later." }, 429, env);
  }

  const nonce = crypto.getRandomValues(new Uint8Array(32));
  const challenge = bufferToHex(nonce);

  await env.CODES.put(challengeKey(challenge), "1", {
    expirationTtl: 120,
  });

  return json({ challenge }, 200, env);
}

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
    if (!env.RESEND_API_KEY) {
      return json({ error: "Email service not configured" }, 503, env);
    }
    try {
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
    } catch (err: any) {
      return json({ error: "Failed to send email", detail: err?.message ?? String(err) }, 502, env);
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

async function checkChallengeRateLimit(env: Env, ipAddress: string): Promise<boolean> {
  const key = challengeRateKey(ipAddress);
  const raw = await env.CODES.get(key);
  const currentCount = raw ? parseInt(raw, 10) || 0 : 0;

  if (currentCount >= MAX_CHALLENGES_PER_MINUTE) {
    console.warn(`[auth] challenge rate limit hit for IP: ${ipAddress}`);
    return true;
  }

  await env.CODES.put(key, String(currentCount + 1), {
    expirationTtl: CHALLENGE_RATE_LIMIT_WINDOW_SECONDS,
  });
  return false;
}

// ─── Neon Database ──────────────────────────────────────────

async function getDb(env: Env) {
  if (!env.DATABASE_URL) {
    return null;
  }
  const { neon } = await import("@neondatabase/serverless");
  return neon(env.DATABASE_URL);
}

function getJWTSecret(env: Env): string | null {
  return env.JWT_SECRET && env.JWT_SECRET.length > 0 ? env.JWT_SECRET : null;
}

function getJWTExpirySeconds(env: Env): number {
  const parsed = Number.parseInt(env.JWT_TTL_SECONDS ?? env.JWT_EXPIRY_SECONDS ?? "", 10);
  return Number.isFinite(parsed) && parsed > 0 ? parsed : DEFAULT_JWT_EXPIRY_SECONDS;
}

function getJWTRefreshGraceSeconds(env: Env): number {
  const parsed = Number.parseInt(env.JWT_REFRESH_GRACE_SECONDS ?? "", 10);
  return Number.isFinite(parsed) && parsed >= 0 ? parsed : DEFAULT_REFRESH_GRACE_SECONDS;
}

function getBearerToken(header: string | null): string | null {
  if (!header || !header.startsWith("Bearer ")) {
    return null;
  }

  const token = header.slice("Bearer ".length).trim();
  return token.length === 0 ? null : token;
}

function base64Decode(encoded: string): Uint8Array {
  const binary = atob(encoded);
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i += 1) {
    bytes[i] = binary.charCodeAt(i);
  }
  return bytes;
}

function base64Encode(bytes: Uint8Array): string {
  let binary = "";
  for (const byte of bytes) {
    binary += String.fromCharCode(byte);
  }
  return btoa(binary);
}

function base64UrlEncode(bytes: Uint8Array): string {
  return base64Encode(bytes).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/g, "");
}

function base64UrlDecode(input: string): Uint8Array {
  const normalized = input.replace(/-/g, "+").replace(/_/g, "/");
  const padding = normalized.length % 4 === 0 ? "" : "=".repeat(4 - (normalized.length % 4));
  return base64Decode(normalized + padding);
}

function bytesToUtf8(bytes: Uint8Array): string {
  return new TextDecoder().decode(bytes);
}

function utf8ToBytes(value: string): Uint8Array {
  return new TextEncoder().encode(value);
}

async function importHMACKey(secret: string, usages: KeyUsage[]): Promise<CryptoKey> {
  return crypto.subtle.importKey(
    "raw",
    utf8ToBytes(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    usages
  );
}

export async function signJWT(payload: object, secret: string): Promise<string> {
  const header = { alg: "HS256", typ: "JWT" };
  const encodedHeader = base64UrlEncode(utf8ToBytes(JSON.stringify(header)));
  const encodedPayload = base64UrlEncode(utf8ToBytes(JSON.stringify(payload)));
  const signingInput = `${encodedHeader}.${encodedPayload}`;
  const key = await importHMACKey(secret, ["sign"]);
  const signature = await crypto.subtle.sign("HMAC", key, utf8ToBytes(signingInput));
  return `${signingInput}.${base64UrlEncode(new Uint8Array(signature))}`;
}

async function verifyJWTWithGrace(token: string, secret: string, graceSeconds = 0): Promise<JWTPayload | null> {
  const parts = token.split(".");
  if (parts.length !== 3) {
    return null;
  }

  const [encodedHeader, encodedPayload, encodedSignature] = parts;
  let header: { alg?: string; typ?: string };
  let payload: Partial<JWTPayload>;
  let signatureBytes: Uint8Array;

  try {
    header = JSON.parse(bytesToUtf8(base64UrlDecode(encodedHeader)));
    payload = JSON.parse(bytesToUtf8(base64UrlDecode(encodedPayload)));
    signatureBytes = base64UrlDecode(encodedSignature);
  } catch {
    return null;
  }

  if (header.alg !== "HS256" || header.typ !== "JWT") {
    return null;
  }

  const key = await importHMACKey(secret, ["verify"]);
  const signingInput = `${encodedHeader}.${encodedPayload}`;
  const isValid = await crypto.subtle.verify("HMAC", key, signatureBytes, utf8ToBytes(signingInput));
  if (!isValid) {
    return null;
  }

  if (
    typeof payload.sub !== "string" ||
    typeof payload.npk !== "string" ||
    typeof payload.iat !== "number" ||
    typeof payload.exp !== "number"
  ) {
    return null;
  }

  const nowSeconds = Math.floor(Date.now() / 1000);
  if (payload.exp + graceSeconds <= nowSeconds) {
    return null;
  }

  return {
    sub: payload.sub,
    npk: payload.npk,
    iat: payload.iat,
    exp: payload.exp,
  };
}

export async function verifyJWT(token: string, secret: string): Promise<JWTPayload | null> {
  return verifyJWTWithGrace(token, secret, 0);
}

export async function validateJWT(request: Request, env: Env): Promise<JWTPayload> {
  const secret = getJWTSecret(env);
  if (!secret) {
    throw new HTTPError(503, "JWT secret not configured");
  }

  const token = getBearerToken(request.headers.get("Authorization"));
  if (!token) {
    throw new HTTPError(401, "Unauthorized");
  }

  const claims = await verifyJWT(token, secret);
  if (!claims) {
    throw new HTTPError(401, "Unauthorized");
  }

  return claims;
}

async function derivePeerIdHex(noisePublicKey: Uint8Array): Promise<string> {
  const hash = await crypto.subtle.digest("SHA-256", noisePublicKey);
  return bufferToHex(new Uint8Array(hash).slice(0, 8));
}

function parseTimestamp(timestamp: string | undefined): Date | null {
  if (!timestamp) {
    return null;
  }

  const parsed = new Date(timestamp);
  return Number.isNaN(parsed.getTime()) ? null : parsed;
}

function bufferToUint8Array(buf: any): Uint8Array {
  if (buf instanceof Uint8Array) {
    return buf;
  }
  if (buf instanceof ArrayBuffer) {
    return new Uint8Array(buf);
  }
  if (ArrayBuffer.isView(buf)) {
    return new Uint8Array(buf.buffer, buf.byteOffset, buf.byteLength);
  }
  if (typeof buf === "string") {
    return utf8ToBytes(buf);
  }
  return new Uint8Array();
}

async function issueJWTForUser(noisePublicKey: Uint8Array, env: Env): Promise<{ token: string; expiresAt: string; claims: JWTPayload }> {
  const secret = getJWTSecret(env);
  if (!secret) {
    throw json({ error: "JWT secret not configured" }, 503, env);
  }

  const nowSeconds = Math.floor(Date.now() / 1000);
  const expirySeconds = getJWTExpirySeconds(env);
  const claims: JWTPayload = {
    sub: await derivePeerIdHex(noisePublicKey),
    npk: base64Encode(noisePublicKey),
    iat: nowSeconds,
    exp: nowSeconds + expirySeconds,
  };
  const token = await signJWT(claims, secret);
  return {
    token,
    expiresAt: new Date(claims.exp * 1000).toISOString(),
    claims,
  };
}

async function authContextFromJWTClaims(claims: JWTPayload): Promise<AuthContext> {
  let noisePublicKey: Uint8Array;
  try {
    noisePublicKey = base64Decode(claims.npk);
  } catch {
    throw new HTTPError(401, "Unauthorized");
  }

  if (noisePublicKey.length !== NOISE_PUBLIC_KEY_LENGTH) {
    throw new HTTPError(401, "Unauthorized");
  }

  const derivedPeerIdHex = await derivePeerIdHex(noisePublicKey);
  if (claims.sub !== derivedPeerIdHex) {
    throw new HTTPError(401, "Unauthorized");
  }

  return {
    peerIdHex: derivedPeerIdHex,
    noisePublicKey,
    noisePublicKeyBase64: claims.npk,
    claims,
    source: "jwt",
  };
}

async function authenticateRequest(request: Request, env: Env): Promise<AuthContext> {
  const token = getBearerToken(request.headers.get("Authorization"));
  if (!token) {
    throw new HTTPError(401, "Unauthorized");
  }

  if (token.includes(".")) {
    const claims = await validateJWT(request, env);
    return authContextFromJWTClaims(claims);
  }

  let noisePublicKey: Uint8Array;
  try {
    noisePublicKey = base64Decode(token);
  } catch {
    throw new HTTPError(401, "Unauthorized");
  }

  if (noisePublicKey.length !== NOISE_PUBLIC_KEY_LENGTH) {
    throw new HTTPError(401, "Unauthorized");
  }

  return {
    peerIdHex: await derivePeerIdHex(noisePublicKey),
    noisePublicKey,
    noisePublicKeyBase64: base64Encode(noisePublicKey),
    source: "legacy",
  };
}

// ─── Register User ──────────────────────────────────────────

async function handleRegister(request: Request, env: Env): Promise<Response> {
  const body = sanitizeRegisterBody(await parseBody<RegisterBody>(request));

  if (!body) {
    return json({ error: "Missing emailHash or username" }, 400, env);
  }
  const noiseKey = body.noisePublicKey ? hexToBytes(body.noisePublicKey) : null;
  const signingKey = body.signingPublicKey ? hexToBytes(body.signingPublicKey) : null;

  if (body.noisePublicKey && body.signingPublicKey) {
    if (!body.challenge || !body.signature) {
      return json({ error: "Missing challenge or signature" }, 400, env);
    }

    const storedChallenge = await env.CODES.get(challengeKey(body.challenge));
    if (!storedChallenge) {
      return json({ error: "Challenge expired or invalid" }, 401, env);
    }

    await env.CODES.delete(challengeKey(body.challenge));

    let signatureValid = false;
    try {
      const publicKey = await crypto.subtle.importKey(
        "raw",
        hexToBytes(body.signingPublicKey),
        { name: "Ed25519" },
        false,
        ["verify"]
      );
      signatureValid = await crypto.subtle.verify(
        "Ed25519",
        publicKey,
        hexToBytes(body.signature),
        hexToBytes(body.challenge)
      );
    } catch {
      signatureValid = false;
    }

    if (!signatureValid) {
      return json({ error: "Signature verification failed" }, 401, env);
    }
  }

  const sql = await getDb(env);
  if (!sql) {
    return json({ error: "Database not configured" }, 503, env);
  }

  // Registration upsert handles two re-registration scenarios:
  //
  // 1. Same device (same email_hash, same or updated username):
  //    → ON CONFLICT (email_hash) DO UPDATE — updates keys and username in place.
  //
  // 2. Reinstall / new device (new email_hash, same username):
  //    → The INSERT hits the username unique constraint (23505). We catch this and
  //      UPDATE the existing row by username, resetting is_verified to FALSE so the
  //      user must re-verify their email. This prevents a different person from
  //      silently stealing a username — they'd need access to the email to complete
  //      verification.
  try {
    const result = await sql`
      INSERT INTO users (email_hash, username, is_verified, created_at, noise_public_key, signing_public_key)
      VALUES (${body.emailHash}, ${body.username}, FALSE, ${body.createdAt}, ${noiseKey}, ${signingKey})
      ON CONFLICT (email_hash) DO UPDATE SET
        username = EXCLUDED.username,
        noise_public_key = COALESCE(EXCLUDED.noise_public_key, users.noise_public_key),
        signing_public_key = COALESCE(EXCLUDED.signing_public_key, users.signing_public_key),
        is_verified = FALSE,
        updated_at = NOW()
      RETURNING id
    `;
    return json({ userId: result[0]?.id }, 200, env);
  } catch (error: any) {
    const msg = error?.message ?? String(error);
    const code = error?.code ?? "";
    const constraint = error?.constraint ?? "";

    // Username conflict: reinstall with new email_hash — update existing row
    if (code === "23505" && (constraint.includes("username") || msg.includes("users_username_key"))) {
      try {
        const result = await sql`
          UPDATE users SET
            email_hash = ${body.emailHash},
            noise_public_key = COALESCE(${noiseKey}, noise_public_key),
            signing_public_key = COALESCE(${signingKey}, signing_public_key),
            is_verified = FALSE,
            updated_at = NOW()
          WHERE username = ${body.username}
          RETURNING id
        `;
        if (result.length === 0) {
          return json({ error: "Registration failed" }, 500, env);
        }
        return json({ userId: result[0]?.id }, 200, env);
      } catch (updateError: any) {
        console.error("[auth] handleRegister (username conflict update) error:", updateError);
        return json({ error: "Registration failed" }, 500, env);
      }
    }

    console.error("[auth] handleRegister error:", error);
    return json({ error: "Registration failed" }, 500, env);
  }
}

// ─── Session Tokens ─────────────────────────────────────────

async function handleIssueToken(request: Request, env: Env): Promise<Response> {
  const body = await parseBody<TokenRequestBody>(request);
  if (!body?.noisePublicKey || !body.timestamp || !body.signature) {
    return json({ error: "Missing noisePublicKey, timestamp, or signature" }, 400, env);
  }

  const timestamp = parseTimestamp(body.timestamp);
  if (!timestamp || Math.abs(Date.now() - timestamp.getTime()) > TOKEN_TIMESTAMP_TOLERANCE_MS) {
    return json({ error: "Timestamp outside allowed window" }, 400, env);
  }

  let noisePublicKey: Uint8Array;
  let signature: Uint8Array;
  try {
    noisePublicKey = base64Decode(body.noisePublicKey);
    signature = base64Decode(body.signature);
  } catch {
    return json({ error: "Invalid base64 in request" }, 400, env);
  }

  if (noisePublicKey.length !== NOISE_PUBLIC_KEY_LENGTH || signature.length !== ED25519_SIGNATURE_LENGTH) {
    return json({ error: "Invalid key or signature length" }, 400, env);
  }

  const sql = await getDb(env);
  if (!sql) {
    return json({ error: "Database not configured" }, 503, env);
  }

  try {
    const result = await sql`
      SELECT id, noise_public_key, signing_public_key
      FROM users
      WHERE noise_public_key = ${noisePublicKey}
    `;

    if (result.length === 0) {
      return json({ error: "User not found" }, 404, env);
    }

    const user = result[0];
    const signingPublicKey = bufferToUint8Array(user.signing_public_key);
    if (signingPublicKey.length === 0) {
      return json({ error: "User signing key not found" }, 404, env);
    }

    const key = await crypto.subtle.importKey(
      "raw",
      signingPublicKey,
      { name: "Ed25519" },
      false,
      ["verify"]
    );
    const isValid = await crypto.subtle.verify("Ed25519", key, signature, utf8ToBytes(body.timestamp));
    if (!isValid) {
      return json({ error: "Invalid signature" }, 401, env);
    }

    const session = await issueJWTForUser(noisePublicKey, env);
    return json({ token: session.token, expiresAt: session.expiresAt }, 200, env);
  } catch (error: any) {
    if (error instanceof HTTPError) {
      return json({ error: error.message }, error.status, env);
    }
    console.error("[auth] handleIssueToken error:", error);
    return json({ error: "Token issuance failed" }, 500, env);
  }
}

async function handleRefreshToken(request: Request, env: Env): Promise<Response> {
  const secret = getJWTSecret(env);
  if (!secret) {
    return json({ error: "JWT secret not configured" }, 503, env);
  }

  const token = getBearerToken(request.headers.get("Authorization"));
  if (!token) {
    return json({ error: "Unauthorized" }, 401, env);
  }

  const claims = await verifyJWTWithGrace(token, secret, getJWTRefreshGraceSeconds(env));
  if (!claims) {
    return json({ error: "Unauthorized" }, 401, env);
  }

  let noisePublicKey: Uint8Array;
  try {
    noisePublicKey = base64Decode(claims.npk);
  } catch {
    return json({ error: "Unauthorized" }, 401, env);
  }

  if (noisePublicKey.length !== NOISE_PUBLIC_KEY_LENGTH) {
    return json({ error: "Unauthorized" }, 401, env);
  }

  try {
    const session = await issueJWTForUser(noisePublicKey, env);
    return json({ token: session.token, expiresAt: session.expiresAt }, 200, env);
  } catch (error: any) {
    if (error instanceof HTTPError) {
      return json({ error: error.message }, error.status, env);
    }
    console.error("[auth] handleRefreshToken error:", error);
    return json({ error: "Token refresh failed" }, 500, env);
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
    const auth = await authenticateRequest(request, env);
    const result = await sql`
      UPDATE users SET
        last_active_at = COALESCE(${body.lastActiveAt ?? null}, last_active_at),
        updated_at = NOW()
      WHERE email_hash = ${body.emailHash}
        AND noise_public_key = ${auth.noisePublicKey}
      RETURNING id, is_verified, message_balance
    `;

    if (result.length === 0) {
      return json({ error: "User not found" }, 404, env);
    }

    return json({ synced: true, user: result[0] }, 200, env);
  } catch (error: any) {
    if (error instanceof HTTPError) {
      return json({ error: error.message }, error.status, env);
    }
    console.error("[auth] handleSync error:", error);
    return json({ error: "Sync failed" }, 500, env);
  }
}

// ─── Get User ───────────────────────────────────────────────

async function handleGetUser(request: Request, url: URL, env: Env): Promise<Response> {
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
    const auth = await authenticateRequest(request, env);
    const result = await sql`
      SELECT id, username, is_verified, message_balance, last_active_at, created_at
      FROM users
      WHERE email_hash = ${emailHash}
        AND noise_public_key = ${auth.noisePublicKey}
    `;

    if (result.length === 0) {
      return json({ error: "User not found" }, 404, env);
    }

    return json({ user: result[0] }, 200, env);
  } catch (error: any) {
    if (error instanceof HTTPError) {
      return json({ error: error.message }, error.status, env);
    }
    console.error("[auth] handleGetUser error:", error);
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

async function handleLookupByUsername(request: Request, url: URL, env: Env): Promise<Response> {
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
    await authenticateRequest(request, env);
    const result = await sql`
      SELECT id, username, is_verified, noise_public_key, signing_public_key, last_active_at
      FROM users WHERE LOWER(username) = LOWER(${username})
    `;

    if (result.length === 0) {
      return json({
        user: {
          id: null,
          username,
          isVerified: false,
          noisePublicKey: null,
          signingPublicKey: null,
          lastActiveAt: null,
        },
      }, 200, env);
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
  } catch (error: any) {
    if (error instanceof HTTPError) {
      return json({ error: error.message }, error.status, env);
    }
    console.error("[auth] handleLookupByUsername error:", error);
    return json({ error: "Lookup failed" }, 500, env);
  }
}

async function handleKeys(request: Request, env: Env): Promise<Response> {
  const body = await parseBody<KeyUpdateBody>(request);
  const noisePublicKey = isValidHexKey(body?.noisePublicKey) ? hexToBytes(body.noisePublicKey) : null;
  const signingPublicKey = isValidHexKey(body?.signingPublicKey) ? hexToBytes(body.signingPublicKey) : null;

  if (!noisePublicKey || !signingPublicKey) {
    return json({ error: "Missing noisePublicKey or signingPublicKey" }, 400, env);
  }

  const sql = await getDb(env);
  if (!sql) {
    return json({ error: "Database not configured" }, 503, env);
  }

  try {
    const auth = await authenticateRequest(request, env);
    const result = await sql`
      UPDATE users SET
        noise_public_key = ${noisePublicKey},
        signing_public_key = ${signingPublicKey},
        updated_at = NOW()
      WHERE noise_public_key = ${auth.noisePublicKey}
      RETURNING id
    `;

    if (result.length === 0) {
      return json({ error: "User not found" }, 404, env);
    }

    return json({ updated: true, userId: result[0]?.id }, 200, env);
  } catch (error: any) {
    if (error instanceof HTTPError) {
      return json({ error: error.message }, error.status, env);
    }
    console.error("[auth] handleKeys error:", error);
    return json({ error: "Key update failed" }, 500, env);
  }
}

function hexToBytes(hex: string): Uint8Array {
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

function challengeKey(challenge: string): string {
  return `challenge:${challenge}`;
}

function challengeRateKey(ipAddress: string): string {
  return `ratelimit:${ipAddress}`;
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
): {
  emailHash: string;
  username: string;
  createdAt: string;
  noisePublicKey?: string;
  signingPublicKey?: string;
  challenge?: string;
  signature?: string;
} | null {
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
    challenge: isValidChallenge(body.challenge) ? body.challenge : undefined,
    signature: isValidSignature(body.signature) ? body.signature : undefined,
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

function isValidChallenge(challenge: string | undefined): challenge is string {
  return typeof challenge === "string" && /^[a-f0-9]{64}$/i.test(challenge);
}

function isValidSignature(signature: string | undefined): signature is string {
  return typeof signature === "string" && /^[a-f0-9]{128}$/i.test(signature);
}
