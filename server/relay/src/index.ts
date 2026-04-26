/**
 * Blip zero-knowledge WebSocket relay server.
 *
 * Entry point: handles WebSocket upgrade at /ws, validates auth,
 * derives PeerID, and forwards the connection to a RelayRoom Durable Object.
 */
import { DurableObject } from "cloudflare:workers";
import * as Sentry from "@sentry/cloudflare";
import { bytesToHex, PUBLIC_KEY_LENGTH, PEER_ID_LENGTH, type Env, type PeerIDHex } from "./types";
import { RelayRoom as RelayRoomImpl } from "./relay-room";

let warnedAboutMissingSentryDsn = false;

/**
 * Build Sentry options from env. Returns an empty object when SENTRY_DSN is
 * absent so the SDK initialises in disabled mode and the Worker boots cleanly
 * even before the project is provisioned.
 */
export function sentryOptions(env: Env) {
  if (!env.SENTRY_DSN) {
    if (!warnedAboutMissingSentryDsn) {
      console.warn("[relay] SENTRY_DSN not configured — error reporting disabled");
      warnedAboutMissingSentryDsn = true;
    }
    return {};
  }
  return {
    dsn: env.SENTRY_DSN,
    environment: env.ENVIRONMENT ?? "development",
    tracesSampleRate: 0.1,
    sendDefaultPii: false,
    beforeSend(event: Sentry.ErrorEvent): Sentry.ErrorEvent | null {
      // Strip Authorization header — carries Bearer JWTs / legacy Noise keys.
      const headers = event.request?.headers as Record<string, string> | undefined;
      if (headers) {
        delete headers["authorization"];
        delete headers["Authorization"];
      }
      if (typeof event.request?.data === "string") {
        event.request.data = scrubJwts(event.request.data);
      }
      return event;
    },
  };
}

function scrubJwts(input: string): string {
  return input.replace(/eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+/g, "<jwt>");
}

/**
 * Thin proxy that adapts the plain `RelayRoomImpl` (which `implements DurableObject`
 * and is constructed directly by the unit tests with a mocked state) into a subclass
 * of the real `DurableObject` base, so Sentry's `instrumentDurableObjectWithSentry`
 * can initialise the SDK inside the DO isolate and capture any thrown error.
 *
 * All DO lifecycle methods are delegated 1:1 — no behaviour change.
 */
class RelayRoomProxy extends DurableObject<Env> {
  private readonly impl: RelayRoomImpl;

  constructor(state: DurableObjectState, env: Env) {
    super(state, env);
    this.impl = new RelayRoomImpl(state, env);
  }

  fetch(request: Request): Promise<Response> {
    return this.impl.fetch(request);
  }

  webSocketMessage(ws: WebSocket, message: string | ArrayBuffer): Promise<void> {
    return this.impl.webSocketMessage(ws, message);
  }

  webSocketClose(ws: WebSocket, code: number, reason: string, wasClean: boolean): void {
    return this.impl.webSocketClose(ws, code, reason, wasClean);
  }

  webSocketError(ws: WebSocket, error: unknown): void {
    return this.impl.webSocketError(ws, error);
  }

  alarm(): Promise<void> {
    return this.impl.alarm();
  }
}

export const RelayRoom = Sentry.instrumentDurableObjectWithSentry(sentryOptions, RelayRoomProxy);

interface JWTPayload {
  sub: string;
  npk: string;
  iat: number;
  exp: number;
}

interface RelayAuthContext {
  peerIdHex: PeerIDHex;
  noisePublicKey: Uint8Array;
  noisePublicKeyBase64: string;
  claims?: JWTPayload;
  source: "jwt" | "legacy";
}

class RelayAuthError extends Error {
  constructor(
    readonly status: number,
    message: string,
    readonly closeCode?: number
  ) {
    super(message);
  }
}

/** Single global Durable Object room — all peers connect to the same instance. */
const ROOM_ID_NAME = "global-relay";
const textEncoder = new TextEncoder();

export default Sentry.withSentry(sentryOptions, {
  async fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url);

    // Cross-tier trace ID (BDEV-403). Read the iOS client's X-Trace-ID so a
    // single request stitches across in-app debug overlay, wrangler tail,
    // and Sentry. If absent (server-to-server calls), mint one.
    const traceID = request.headers.get("X-Trace-ID") ?? crypto.randomUUID();
    Sentry.setTag("trace_id", traceID);
    console.log(`[trace ${traceID}] ${request.method} ${url.pathname}`);

    if (url.pathname === "/health") {
      return new Response("ok", { status: 200 });
    }

    // Badge-clear callout from the iOS client path (via auth or directly).
    // Authenticated via the shared INTERNAL_API_KEY rather than a JWT — this
    // endpoint is only invoked server-to-server by the auth worker (and in
    // tests). The body identifies the peer; no user session is involved.
    if (url.pathname === "/internal/badge/clear" && request.method === "POST") {
      const providedKey = request.headers.get("X-Internal-Key");
      if (!env.INTERNAL_API_KEY || providedKey !== env.INTERNAL_API_KEY) {
        return new Response("Unauthorized", { status: 401 });
      }
      let body: { peerIdHex?: string; threadId?: string; all?: boolean };
      try {
        body = await request.json();
      } catch {
        return new Response("Invalid JSON", { status: 400 });
      }
      if (!body.peerIdHex || typeof body.peerIdHex !== "string") {
        return new Response("Missing peerIdHex", { status: 400 });
      }
      if (!body.all && !body.threadId) {
        return new Response("Must provide threadId or all", { status: 400 });
      }
      const roomId = env.RELAY_ROOM.idFromName(ROOM_ID_NAME);
      const room = env.RELAY_ROOM.get(roomId);
      const forward = new Request(
        new URL("/internal/badge/clear", request.url).toString(),
        {
          method: "POST",
          headers: {
            "Content-Type": "application/json",
            "X-Internal-Key": env.INTERNAL_API_KEY,
            "X-Derived-Peer-ID": body.peerIdHex,
            "X-State-Action": "badge-clear",
          },
          body: JSON.stringify({ threadId: body.threadId, all: body.all }),
        }
      );
      return room.fetch(forward);
    }

    // State sync endpoints (GCS reconciliation).
    if (url.pathname === "/state" && (request.method === "PUT" || request.method === "GET")) {
      try {
        const auth = await validateAuthorizationHeader(request.headers.get("Authorization"), env);
        return forwardToRelayRoom(request, env, auth.peerIdHex, auth.noisePublicKeyBase64, request.method === "PUT" ? "put" : "get");
      } catch (error) {
        if (error instanceof RelayAuthError) {
          return new Response(error.message, { status: error.status });
        }
        Sentry.captureException(error, {
          tags: { route: "state", operation: "authorize" },
        });
        return new Response("Unauthorized", { status: 401 });
      }
    }

    if (url.pathname !== "/ws") {
      return new Response("Not Found", { status: 404 });
    }

    const upgradeHeader = request.headers.get("Upgrade");
    if (!upgradeHeader || upgradeHeader.toLowerCase() !== "websocket") {
      return new Response("Expected WebSocket upgrade", { status: 426 });
    }

    try {
      const auth = await validateAuthorizationHeader(request.headers.get("Authorization"), env);
      return forwardToRelayRoom(request, env, auth.peerIdHex, auth.noisePublicKeyBase64);
    } catch (error) {
      if (error instanceof RelayAuthError && error.closeCode != null) {
        return closeWebSocketImmediately(error.closeCode, error.message);
      }
      if (error instanceof RelayAuthError) {
        return new Response(error.message, { status: error.status });
      }
      Sentry.captureException(error, {
        tags: { route: "ws", operation: "authorize" },
      });
      return new Response("Unauthorized", { status: 401 });
    }
  },
});

function forwardToRelayRoom(
  request: Request,
  env: Env,
  peerIdHex: PeerIDHex,
  noisePublicKeyBase64: string,
  stateAction?: "put" | "get"
): Response {
  const roomId = env.RELAY_ROOM.idFromName(ROOM_ID_NAME);
  const room = env.RELAY_ROOM.get(roomId);

  const newHeaders = new Headers(request.headers);
  newHeaders.set("X-Derived-Peer-ID", peerIdHex);
  newHeaders.set("X-Authenticated-Noise-Key", noisePublicKeyBase64);
  if (stateAction) {
    newHeaders.set("X-State-Action", stateAction);
  }

  return room.fetch(new Request(request.url, {
    method: request.method,
    headers: newHeaders,
    body: request.method === "PUT" ? request.body : null,
  }));
}

function closeWebSocketImmediately(closeCode: number, reason: string): Response {
  const { 0: client, 1: server } = new WebSocketPair();
  server.accept();
  server.close(closeCode, reason);
  return new Response(null, {
    status: 101,
    webSocket: client,
  });
}

function getJWTSecret(env: Env): string | null {
  return env.JWT_SECRET && env.JWT_SECRET.length > 0 ? env.JWT_SECRET : null;
}

function getBearerToken(header: string | null): string | null {
  if (!header || !header.startsWith("Bearer ")) {
    return null;
  }

  const token = header.slice("Bearer ".length).trim();
  return token.length > 0 ? token : null;
}

/** Decode a base64 string to Uint8Array. */
export function base64Decode(encoded: string): Uint8Array {
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

function base64UrlDecode(input: string): Uint8Array {
  const normalized = input.replace(/-/g, "+").replace(/_/g, "/");
  const padding = normalized.length % 4 === 0 ? "" : "=".repeat(4 - (normalized.length % 4));
  return base64Decode(normalized + padding);
}

async function importHMACKey(secret: string, usages: KeyUsage[]): Promise<CryptoKey> {
  return crypto.subtle.importKey(
    "raw",
    textEncoder.encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    usages
  );
}

async function verifyJWT(token: string, secret: string): Promise<{ claims: JWTPayload | null; expired: boolean }> {
  const parts = token.split(".");
  if (parts.length !== 3) {
    return { claims: null, expired: false };
  }

  const [encodedHeader, encodedPayload, encodedSignature] = parts;
  let header: { alg?: string; typ?: string };
  let payload: Partial<JWTPayload>;
  let signatureBytes: Uint8Array;

  try {
    header = JSON.parse(new TextDecoder().decode(base64UrlDecode(encodedHeader)));
    payload = JSON.parse(new TextDecoder().decode(base64UrlDecode(encodedPayload)));
    signatureBytes = base64UrlDecode(encodedSignature);
  } catch {
    return { claims: null, expired: false };
  }

  if (header.alg !== "HS256" || header.typ !== "JWT") {
    return { claims: null, expired: false };
  }

  const key = await importHMACKey(secret, ["verify"]);
  const signingInput = `${encodedHeader}.${encodedPayload}`;
  const isValid = await crypto.subtle.verify("HMAC", key, signatureBytes, textEncoder.encode(signingInput));
  if (!isValid) {
    return { claims: null, expired: false };
  }

  if (
    typeof payload.sub !== "string" ||
    typeof payload.npk !== "string" ||
    typeof payload.iat !== "number" ||
    typeof payload.exp !== "number"
  ) {
    return { claims: null, expired: false };
  }

  const nowSeconds = Math.floor(Date.now() / 1000);
  if (payload.exp <= nowSeconds) {
    return { claims: null, expired: true };
  }

  return {
    claims: {
      sub: payload.sub,
      npk: payload.npk,
      iat: payload.iat,
      exp: payload.exp,
    },
    expired: false,
  };
}

/** Validate an Authorization header and return the raw legacy public key bytes, or null. */
export function parseAuthHeader(header: string | null): Uint8Array | null {
  const token = getBearerToken(header);
  if (!token || token.includes(".")) {
    return null;
  }

  try {
    const bytes = base64Decode(token);
    return bytes.length === PUBLIC_KEY_LENGTH ? bytes : null;
  } catch {
    return null;
  }
}

export async function validateAuthorizationHeader(header: string | null, env: Env): Promise<RelayAuthContext> {
  const token = getBearerToken(header);
  if (!token) {
    throw new RelayAuthError(401, "Unauthorized");
  }

  if (token.includes(".")) {
    const secret = getJWTSecret(env);
    if (!secret) {
      Sentry.captureMessage("JWT_SECRET missing — relay cannot authenticate peers", {
        level: "fatal",
        tags: { route: "relay", failure: "jwt_secret_missing" },
      });
      throw new RelayAuthError(503, "JWT secret not configured");
    }

    const { claims, expired } = await verifyJWT(token, secret);
    if (expired) {
      // Expired tokens are high-volume (every peer whose client sat idle past
      // TTL); sample to avoid flooding the Sentry quota.
      if (Math.random() < 0.1) {
        Sentry.captureMessage("Relay JWT expired", {
          level: "info",
          tags: { route: "relay", failure: "jwt_expired" },
        });
      }
      throw new RelayAuthError(401, "Token expired", 4001);
    }
    if (!claims) {
      if (Math.random() < 0.1) {
        Sentry.captureMessage("Relay JWT verify failed", {
          level: "warning",
          tags: { route: "relay", failure: "jwt_invalid" },
        });
      }
      throw new RelayAuthError(401, "Unauthorized");
    }

    const noisePublicKey = base64Decode(claims.npk);
    if (noisePublicKey.length !== PUBLIC_KEY_LENGTH) {
      throw new RelayAuthError(401, "Unauthorized");
    }

    const derivedPeerIdHex = await derivePeerIdHex(noisePublicKey);
    if (derivedPeerIdHex !== claims.sub) {
      throw new RelayAuthError(401, "Unauthorized");
    }

    return {
      peerIdHex: claims.sub,
      noisePublicKey,
      noisePublicKeyBase64: claims.npk,
      claims,
      source: "jwt",
    };
  }

  // Legacy auth (raw base64 Noise public key as bearer) has no expiry or
  // rotation — it's strictly a dev convenience. Production deployments must
  // unset `ALLOW_LEGACY_AUTH` so every session goes through the JWT path.
  if (!env.ALLOW_LEGACY_AUTH) {
    throw new RelayAuthError(401, "Legacy auth disabled");
  }

  const publicKeyBytes = parseAuthHeader(header);
  if (!publicKeyBytes) {
    throw new RelayAuthError(401, "Unauthorized");
  }

  return {
    peerIdHex: await derivePeerIdHex(publicKeyBytes),
    noisePublicKey: publicKeyBytes,
    noisePublicKeyBase64: base64Encode(publicKeyBytes),
    source: "legacy",
  };
}

/** Derive PeerID hex from public key bytes. */
export async function derivePeerIdHex(publicKey: Uint8Array): Promise<PeerIDHex> {
  const hash = await crypto.subtle.digest("SHA-256", publicKey);
  return bytesToHex(new Uint8Array(hash).slice(0, PEER_ID_LENGTH));
}
