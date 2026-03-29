/**
 * FestiChat zero-knowledge WebSocket relay server.
 *
 * Entry point: handles WebSocket upgrade at /ws, validates auth,
 * derives PeerID, and forwards the connection to a RelayRoom Durable Object.
 */
import { bytesToHex, PUBLIC_KEY_LENGTH, PEER_ID_LENGTH, type Env, type PeerIDHex } from "./types";

export { RelayRoom } from "./relay-room";

/** Single global Durable Object room — all peers connect to the same instance. */
const ROOM_ID_NAME = "global-relay";

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url);

    if (url.pathname === "/health") {
      return new Response("ok", { status: 200 });
    }

    if (url.pathname !== "/ws") {
      return new Response("Not Found", { status: 404 });
    }

    const upgradeHeader = request.headers.get("Upgrade");
    if (!upgradeHeader || upgradeHeader.toLowerCase() !== "websocket") {
      return new Response("Expected WebSocket upgrade", { status: 426 });
    }

    // Validate Bearer token: base64-encoded Noise static public key.
    const authHeader = request.headers.get("Authorization");
    if (!authHeader || !authHeader.startsWith("Bearer ")) {
      return new Response("Unauthorized", { status: 401 });
    }

    const token = authHeader.slice("Bearer ".length);
    let publicKeyBytes: Uint8Array;
    try {
      publicKeyBytes = base64Decode(token);
    } catch {
      return new Response("Invalid auth token encoding", { status: 401 });
    }

    if (publicKeyBytes.length !== PUBLIC_KEY_LENGTH) {
      return new Response("Unauthorized", { status: 401 });
    }

    // Derive PeerID: SHA-256(publicKey)[0..8], hex-encoded.
    const hash = await crypto.subtle.digest("SHA-256", publicKeyBytes);
    const peerIdBytes = new Uint8Array(hash).slice(0, PEER_ID_LENGTH);
    const peerIdHex: PeerIDHex = bytesToHex(peerIdBytes);

    // Forward to the global relay room Durable Object.
    const roomId = env.RELAY_ROOM.idFromName(ROOM_ID_NAME);
    const room = env.RELAY_ROOM.get(roomId);

    // Pass PeerID via header to the Durable Object.
    const newHeaders = new Headers(request.headers);
    newHeaders.set("X-Derived-Peer-ID", peerIdHex);

    const doRequest = new Request(request.url, {
      method: request.method,
      headers: newHeaders,
    });

    return room.fetch(doRequest);
  },
};

/** Decode a base64 string to Uint8Array. */
export function base64Decode(encoded: string): Uint8Array {
  const binary = atob(encoded);
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) {
    bytes[i] = binary.charCodeAt(i);
  }
  return bytes;
}

/** Validate an Authorization header and return the public key bytes, or null. */
export function parseAuthHeader(header: string | null): Uint8Array | null {
  if (!header || !header.startsWith("Bearer ")) return null;
  const token = header.slice("Bearer ".length);
  try {
    const bytes = base64Decode(token);
    return bytes.length === PUBLIC_KEY_LENGTH ? bytes : null;
  } catch {
    return null;
  }
}

/** Derive PeerID hex from public key bytes. */
export async function derivePeerIdHex(publicKey: Uint8Array): Promise<PeerIDHex> {
  const hash = await crypto.subtle.digest("SHA-256", publicKey);
  return bytesToHex(new Uint8Array(hash).slice(0, PEER_ID_LENGTH));
}
