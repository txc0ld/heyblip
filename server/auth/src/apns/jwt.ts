/**
 * APNs JWT provider.
 *
 * Signs ES256 JWTs for Apple Push Notifications using the .p8 key shipped as
 * `APNS_PRIVATE_KEY` (base64 of the PEM body, with/without BEGIN/END lines).
 * The signed JWT is cached in module state for 55 minutes (Apple accepts up
 * to 60 — 5-minute safety margin) so we're not re-signing on every push.
 */
import type { Env } from "../index";

const CACHE_TTL_MS = 55 * 60 * 1000;

interface CacheEntry {
  token: string;
  expiresAtMs: number;
  keyId: string;
  teamId: string;
}

let cache: CacheEntry | null = null;

/** Clears the in-memory JWT cache. Exported for tests. */
export function _resetCacheForTests(): void {
  cache = null;
}

function base64UrlEncode(bytes: Uint8Array): string {
  let binary = "";
  for (const byte of bytes) {
    binary += String.fromCharCode(byte);
  }
  return btoa(binary)
    .replace(/\+/g, "-")
    .replace(/\//g, "_")
    .replace(/=+$/g, "");
}

function utf8(value: string): Uint8Array {
  return new TextEncoder().encode(value);
}

function stripPemArmor(input: string): string {
  // Accept either the raw base64 body or a full PEM block with headers.
  return input
    .replace(/-----BEGIN [^-]+-----/g, "")
    .replace(/-----END [^-]+-----/g, "")
    .replace(/\s+/g, "");
}

function decodeBase64(b64: string): Uint8Array {
  const binary = atob(b64);
  const out = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i += 1) {
    out[i] = binary.charCodeAt(i);
  }
  return out;
}

async function importP8(privateKeyB64: string): Promise<CryptoKey> {
  const body = stripPemArmor(privateKeyB64);
  if (body.length === 0) {
    throw new Error("APNS_PRIVATE_KEY is empty");
  }

  // `APNS_PRIVATE_KEY` is documented as base64 of the .p8 *body* — which is
  // already base64 to begin with. So it might arrive as: (a) raw base64, or
  // (b) base64 of the base64 (double-wrapped). Try the straight decode first;
  // if that fails PKCS8 import we fall back to the double-wrapped form.
  const attempts: Uint8Array[] = [];
  try {
    attempts.push(decodeBase64(body));
  } catch {
    // ignore — first decode couldn't parse as base64 at all
  }
  try {
    // If the env var was `base64 the.p8` over a PEM base64 body, the decode
    // yields ASCII base64 bytes; re-decode to get DER.
    if (attempts.length > 0) {
      const asText = new TextDecoder().decode(attempts[0]);
      if (/^[A-Za-z0-9+/=\s]+$/.test(asText)) {
        attempts.push(decodeBase64(asText.replace(/\s+/g, "")));
      }
    }
  } catch {
    // ignore
  }

  let lastError: unknown = null;
  for (const der of attempts) {
    try {
      return await crypto.subtle.importKey(
        "pkcs8",
        der as unknown as ArrayBuffer,
        { name: "ECDSA", namedCurve: "P-256" },
        false,
        ["sign"]
      );
    } catch (err) {
      lastError = err;
    }
  }

  throw new Error(`APNS_PRIVATE_KEY is not a valid PKCS8 P-256 key: ${lastError}`);
}

/**
 * Returns a signed APNs JWT. Reuses the cached token for 55 minutes before
 * refreshing.
 */
export async function getApnsJwt(env: Env): Promise<string> {
  if (!env.APNS_PRIVATE_KEY || !env.APNS_KEY_ID || !env.APNS_TEAM_ID) {
    throw new Error("APNs credentials missing (APNS_PRIVATE_KEY/KEY_ID/TEAM_ID)");
  }

  const now = Date.now();
  if (
    cache &&
    cache.keyId === env.APNS_KEY_ID &&
    cache.teamId === env.APNS_TEAM_ID &&
    cache.expiresAtMs > now
  ) {
    return cache.token;
  }

  const nowSec = Math.floor(now / 1000);
  const header = { alg: "ES256", kid: env.APNS_KEY_ID, typ: "JWT" };
  const payload = { iss: env.APNS_TEAM_ID, iat: nowSec };

  const encodedHeader = base64UrlEncode(utf8(JSON.stringify(header)));
  const encodedPayload = base64UrlEncode(utf8(JSON.stringify(payload)));
  const signingInput = `${encodedHeader}.${encodedPayload}`;

  const key = await importP8(env.APNS_PRIVATE_KEY);
  const signature = await crypto.subtle.sign(
    { name: "ECDSA", hash: "SHA-256" },
    key,
    utf8(signingInput)
  );
  const encodedSignature = base64UrlEncode(new Uint8Array(signature));
  const token = `${signingInput}.${encodedSignature}`;

  cache = {
    token,
    expiresAtMs: now + CACHE_TTL_MS,
    keyId: env.APNS_KEY_ID,
    teamId: env.APNS_TEAM_ID,
  };
  return token;
}

/** Nulls out the cached JWT so the next push re-signs (used on APNs 403). */
export function invalidateApnsJwt(): void {
  cache = null;
}
