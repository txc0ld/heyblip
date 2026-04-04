/**
 * RelayRoom Durable Object — maintains the set of connected peers
 * and routes binary protocol packets by recipient PeerID.
 *
 * Zero-knowledge: never decrypts, logs, or persists packet content.
 */
import {
  bytesToHex,
  HEADER_SIZE,
  PEER_ID_LENGTH,
  OFFSET_FLAGS,
  OFFSET_SENDER_ID,
  OFFSET_RECIPIENT_ID,
  FLAG_HAS_RECIPIENT,
  MIN_ADDRESSED_PACKET_SIZE,
  type PeerIDHex,
} from "./types";

/** Extract the recipient PeerID hex from a binary packet, or null if not routable. */
export function extractRecipient(data: Uint8Array): PeerIDHex | null {
  if (data.length < MIN_ADDRESSED_PACKET_SIZE) return null;
  const flags = data[OFFSET_FLAGS];
  if ((flags & FLAG_HAS_RECIPIENT) === 0) return null;
  const recipientBytes = data.slice(OFFSET_RECIPIENT_ID, OFFSET_RECIPIENT_ID + PEER_ID_LENGTH);
  return bytesToHex(recipientBytes);
}

/** Maximum allowed packet size (effectiveMTU from protocol spec). */
const MAX_PACKET_SIZE = 512;

/** Maximum messages per peer per second. */
const RATE_LIMIT_PER_SECOND = 100;

export class RelayRoom implements DurableObject {
  /** Connected peers indexed by hex PeerID. */
  private peers: Map<PeerIDHex, WebSocket> = new Map();

  /** Reverse lookup: WebSocket -> PeerID (for cleanup on close). */
  private wsToPeer: Map<WebSocket, PeerIDHex> = new Map();

  /** Per-peer message timestamps for rate limiting. */
  private messageTimestamps: Map<PeerIDHex, number[]> = new Map();

  /** Per-peer state blobs for GCS sync (opaque binary, no decryption). */
  private peerState: Map<PeerIDHex, { data: ArrayBuffer; updatedAt: number }> = new Map();

  /** Max state blob size (4 KB — GCS filters are small). */
  private static readonly MAX_STATE_SIZE = 4096;

  /** State TTL: 1 hour. Stale entries cleaned on access. */
  private static readonly STATE_TTL_MS = 3600_000;

  constructor(
    private readonly state: DurableObjectState,
    private readonly env: unknown
  ) {}

  async fetch(request: Request): Promise<Response> {
    const peerIdHex = request.headers.get("X-Derived-Peer-ID");
    if (!peerIdHex) {
      return new Response("Missing peer ID", { status: 400 });
    }

    // Handle state sync (non-WebSocket).
    const stateAction = request.headers.get("X-State-Action");
    if (stateAction === "put") {
      return this.handleStatePut(peerIdHex, request);
    }
    if (stateAction === "get") {
      return this.handleStateGet(peerIdHex, request);
    }

    const { 0: client, 1: server } = new WebSocketPair();

    this.handleSession(server, peerIdHex);

    return new Response(null, {
      status: 101,
      webSocket: client,
    });
  }

  // MARK: - State sync

  private async handleStatePut(peerIdHex: PeerIDHex, request: Request): Promise<Response> {
    const body = await request.arrayBuffer();
    if (body.byteLength > RelayRoom.MAX_STATE_SIZE) {
      return new Response("State too large", { status: 413 });
    }

    this.cleanStaleState();
    this.peerState.set(peerIdHex, { data: body, updatedAt: Date.now() });

    return new Response("ok", { status: 200 });
  }

  private handleStateGet(requesterPeerIdHex: PeerIDHex, request: Request): Response {
    this.cleanStaleState();

    // Return the requesting peer's own state, or a specific peer's state via query param.
    const url = new URL(request.url);
    const targetPeer = url.searchParams.get("peer") ?? requesterPeerIdHex;

    const entry = this.peerState.get(targetPeer);
    if (!entry) {
      return new Response(null, { status: 404 });
    }

    return new Response(entry.data, {
      status: 200,
      headers: {
        "Content-Type": "application/octet-stream",
        "X-Updated-At": String(entry.updatedAt),
      },
    });
  }

  private cleanStaleState(): void {
    const now = Date.now();
    for (const [peer, entry] of this.peerState) {
      if (now - entry.updatedAt > RelayRoom.STATE_TTL_MS) {
        this.peerState.delete(peer);
      }
    }
  }

  private handleSession(ws: WebSocket, peerIdHex: PeerIDHex): void {
    ws.accept();

    // Register this peer.
    // If a peer reconnects, close the old socket.
    const existing = this.peers.get(peerIdHex);
    if (existing) {
      this.wsToPeer.delete(existing);
      try {
        existing.close(1000, "replaced");
      } catch {
        // Already closed — ignore.
      }
    }

    this.peers.set(peerIdHex, ws);
    this.wsToPeer.set(ws, peerIdHex);

    // Send "connected" text frame to confirm the connection (matches iOS client expectation).
    ws.send("connected");

    ws.addEventListener("message", (event: MessageEvent) => {
      this.handleMessage(ws, event);
    });

    ws.addEventListener("close", () => {
      this.removePeer(ws);
    });

    ws.addEventListener("error", () => {
      this.removePeer(ws);
    });
  }

  private handleMessage(senderWs: WebSocket, event: MessageEvent): void {
    // Only handle binary packets.
    if (typeof event.data === "string") {
      return;
    }

    const data =
      event.data instanceof ArrayBuffer
        ? new Uint8Array(event.data)
        : new Uint8Array((event.data as ArrayBuffer));

    // Drop undersized or oversized packets.
    if (data.length < HEADER_SIZE || data.length > MAX_PACKET_SIZE) {
      return;
    }

    // Per-peer rate limiting.
    const senderPeerIdHex = this.wsToPeer.get(senderWs);
    if (senderPeerIdHex) {
      const now = Date.now();
      const timestamps = this.messageTimestamps.get(senderPeerIdHex) ?? [];
      const recentTimestamps = timestamps.filter(t => now - t < 1000);
      if (recentTimestamps.length >= RATE_LIMIT_PER_SECOND) {
        return; // Rate limited — drop silently.
      }
      recentTimestamps.push(now);
      this.messageTimestamps.set(senderPeerIdHex, recentTimestamps);
    }

    // Verify the sender PeerID in the packet matches the authenticated connection.
    if (senderPeerIdHex) {
      const packetSenderHex = bytesToHex(
        data.slice(OFFSET_SENDER_ID, OFFSET_SENDER_ID + PEER_ID_LENGTH)
      );
      if (packetSenderHex !== senderPeerIdHex) {
        console.warn(
          `Sender mismatch: packet=${packetSenderHex} connection=${senderPeerIdHex} — dropping`
        );
        return;
      }
    }

    const recipientHex = extractRecipient(data);
    if (!recipientHex) return; // Not routable — silently drop.

    const recipientWs = this.peers.get(recipientHex);
    if (!recipientWs) return; // Recipient not connected — silently drop.

    // Forward the raw binary packet unchanged.
    try {
      recipientWs.send(data.buffer);
    } catch {
      // Recipient disconnected — clean up.
      this.removePeer(recipientWs);
    }
  }

  private removePeer(ws: WebSocket): void {
    const peerIdHex = this.wsToPeer.get(ws);
    if (peerIdHex) {
      // Only remove from peers if this ws is still the registered one
      // (handles race with reconnection replacing the socket).
      if (this.peers.get(peerIdHex) === ws) {
        this.peers.delete(peerIdHex);
      }
      this.wsToPeer.delete(ws);
      this.messageTimestamps.delete(peerIdHex);
    }
  }
}
