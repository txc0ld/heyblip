/**
 * Blip CDN avatar worker.
 *
 * POST /avatars/upload  — authenticated multipart upload, stores in R2
 * GET  /avatars/:id.jpg — public avatar read from R2
 * GET  /manifests/*     — static event manifests (passthrough to existing assets)
 * GET  /health          — liveness check
 */

export interface Env {
  AVATARS: R2Bucket;
  JWT_SECRET?: string;
  CORS_ORIGIN?: string;
  MAX_AVATAR_BYTES?: string;
}

interface JWTPayload {
  sub: string;
  npk: string;
  iat: number;
  exp: number;
}

const DEFAULT_MAX_AVATAR_BYTES = 2 * 1024 * 1024; // 2MB

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url);
    const corsHeaders = getCorsHeaders(env);

    if (request.method === "OPTIONS") {
      return new Response(null, { status: 204, headers: corsHeaders });
    }

    try {
      if (request.method === "POST" && url.pathname === "/avatars/upload") {
        return await handleAvatarUpload(request, env, corsHeaders);
      }

      const avatarMatch = url.pathname.match(/^\/avatars\/([a-zA-Z0-9_-]+)\.jpg$/);
      if (request.method === "GET" && avatarMatch) {
        return await handleAvatarGet(avatarMatch[1], env, corsHeaders);
      }

      if (request.method === "GET" && url.pathname === "/health") {
        return jsonResponse({ status: "ok" }, 200, corsHeaders);
      }

      return jsonResponse({ error: "Not found" }, 404, corsHeaders);
    } catch (err) {
      if (err instanceof HTTPError) {
        return jsonResponse({ error: err.message }, err.status, corsHeaders);
      }
      return jsonResponse({ error: "Internal server error" }, 500, corsHeaders);
    }
  },
};

// MARK: - Handlers

async function handleAvatarUpload(
  request: Request,
  env: Env,
  corsHeaders: Record<string, string>
): Promise<Response> {
  const claims = await validateJWT(request, env);
  const userId = claims.sub;

  const contentType = request.headers.get("Content-Type") ?? "";
  if (!contentType.includes("multipart/form-data")) {
    throw new HTTPError(400, "Expected multipart/form-data");
  }

  const formData = await request.formData();
  const file = formData.get("avatar");

  if (!file || !(file instanceof File)) {
    throw new HTTPError(400, "Missing avatar file");
  }

  const maxBytes = Number.parseInt(env.MAX_AVATAR_BYTES ?? "", 10) || DEFAULT_MAX_AVATAR_BYTES;
  if (file.size > maxBytes) {
    throw new HTTPError(413, `Avatar exceeds ${maxBytes} byte limit`);
  }

  const imageData = await file.arrayBuffer();

  // Validate JPEG magic bytes
  const header = new Uint8Array(imageData.slice(0, 3));
  if (header[0] !== 0xff || header[1] !== 0xd8 || header[2] !== 0xff) {
    throw new HTTPError(400, "Invalid JPEG file");
  }

  const key = `${userId}.jpg`;

  await env.AVATARS.put(key, imageData, {
    httpMetadata: {
      contentType: "image/jpeg",
      cacheControl: "public, max-age=3600",
    },
  });

  const avatarURL = `${new URL(request.url).origin}/avatars/${userId}.jpg`;

  return jsonResponse({ url: avatarURL }, 200, corsHeaders);
}

async function handleAvatarGet(
  userId: string,
  env: Env,
  corsHeaders: Record<string, string>
): Promise<Response> {
  const key = `${userId}.jpg`;
  const object = await env.AVATARS.get(key);

  if (!object) {
    return jsonResponse({ error: "Avatar not found" }, 404, corsHeaders);
  }

  const headers = new Headers(corsHeaders);
  headers.set("Content-Type", "image/jpeg");
  headers.set("Cache-Control", "public, max-age=3600");
  headers.set("ETag", object.httpEtag);

  return new Response(object.body, { status: 200, headers });
}

// MARK: - JWT Verification

class HTTPError extends Error {
  constructor(
    public status: number,
    message: string
  ) {
    super(message);
  }
}

async function validateJWT(request: Request, env: Env): Promise<JWTPayload> {
  const secret = env.JWT_SECRET;
  if (!secret || secret.length === 0) {
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

async function verifyJWT(token: string, secret: string): Promise<JWTPayload | null> {
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
  const isValid = await crypto.subtle.verify(
    "HMAC",
    key,
    signatureBytes,
    utf8ToBytes(signingInput)
  );
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
  if (payload.exp <= nowSeconds) {
    return null;
  }

  return {
    sub: payload.sub,
    npk: payload.npk,
    iat: payload.iat,
    exp: payload.exp,
  };
}

// MARK: - Helpers

function getBearerToken(header: string | null): string | null {
  if (!header || !header.startsWith("Bearer ")) {
    return null;
  }
  const token = header.slice("Bearer ".length).trim();
  return token.length === 0 ? null : token;
}

function getCorsHeaders(env: Env): Record<string, string> {
  const origin = env.CORS_ORIGIN ?? "*";
  return {
    "Access-Control-Allow-Origin": origin,
    "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
    "Access-Control-Allow-Headers": "Content-Type, Authorization",
    "Access-Control-Max-Age": "86400",
  };
}

function jsonResponse(
  body: Record<string, unknown>,
  status: number,
  extraHeaders: Record<string, string> = {}
): Response {
  const headers = new Headers(extraHeaders);
  headers.set("Content-Type", "application/json");
  return new Response(JSON.stringify(body), { status, headers });
}

function base64Decode(encoded: string): Uint8Array {
  const binary = atob(encoded);
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i += 1) {
    bytes[i] = binary.charCodeAt(i);
  }
  return bytes;
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
