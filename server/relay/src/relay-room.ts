/**
 * RelayRoom Durable Object — maintains the set of connected peers
 * and routes binary protocol packets by recipient PeerID.
 *
 * Zero-knowledge: never decrypts, logs, or persists packet content.
 *
 * WebSocket Hibernation API: the DO uses this.state.acceptWebSocket() so
 * Cloudflare can hibernate it between events without evicting it. peerIdHex
 * is stored as a WebSocket tag so it survives hibernation and can be
 * recovered via this.state.getTags(ws) on wake-up.
 */
import * as Sentry from "@sentry/cloudflare";
import {
  bytesToHex,
  HEADER_SIZE,
  PEER_ID_LENGTH,
  OFFSET_TYPE,
  OFFSET_FLAGS,
  OFFSET_SENDER_ID,
  OFFSET_RECIPIENT_ID,
  FLAG_HAS_RECIPIENT,
  MIN_ADDRESSED_PACKET_SIZE,
  MIN_PACKET_SIZE,
  type PeerIDHex,
  type Env,
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

/** Store-and-forward: max queued packets per peer. */
const MAX_QUEUED_PER_PEER = 50;

/** Store-and-forward: queue TTL (1 hour). */
const QUEUE_TTL_MS = 3600_000;

/** Storage key prefix for queued packets. */
const QUEUE_PREFIX = "q:";

export class RelayRoom implements DurableObject {
  /** Connected peers indexed by hex PeerID. Rebuilt lazily after hibernation. */
  private peers: Map<PeerIDHex, WebSocket> = new Map();

  /** Reverse lookup: WebSocket -> PeerID (for cleanup on close). Rebuilt lazily. */
  private wsToPeer: Map<WebSocket, PeerIDHex> = new Map();

  /** Per-peer message timestamps for rate limiting. */
  private messageTimestamps: Map<PeerIDHex, number[]> = new Map();

  /**
   * In-progress drain promise per peer. New drains chain after the existing one
   * instead of running concurrently. This prevents duplicate packet delivery and
   * double-deletes on the same storage keys when a peer rapidly disconnects and
   * reconnects (BDEV-205).
   */
  private drainInProgress: Map<PeerIDHex, Promise<void>> = new Map();

  /** Per-peer retry counter to cap drain retries at 3. */
  private drainRetryCount: Map<PeerIDHex, number> = new Map();

  /** Per-peer state blobs for GCS sync (opaque binary, no decryption). */
  private peerState: Map<PeerIDHex, { data: ArrayBuffer; updatedAt: number }> = new Map();

  /** Max state blob size (4 KB — GCS filters are small). */
  private static readonly MAX_STATE_SIZE = 4096;

  /** State TTL: 1 hour. Stale entries cleaned on access. */
  private static readonly STATE_TTL_MS = 3600_000;

  private lastPushSentAt: Map<string, number> = new Map();
  private readonly PUSH_COOLDOWN_MS = 30_000; // 30 seconds between pushes per recipient

  constructor(
    private readonly state: DurableObjectState,
    private readonly env: Env
  ) {}

  async fetch(request: Request): Promise<Response> {
    const peerIdHex = request.headers.get("X-Derived-Peer-ID");
    if (!peerIdHex) {
      return new Response("Missing peer ID", { status: 400 });
    }

    // Handle state sync (non-WebSocket).
    const stateAction = request.headers.get("X-State-Action");
    if (stateAction) {
      console.info(`[relay] state ${stateAction} for peer ${peerIdHex}`);
    } else {
      console.info(`[relay] WebSocket upgrade request from peer ${peerIdHex}`);
    }
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
    // Hibernation API: DO can sleep between events without being evicted by
    // Cloudflare. peerIdHex is stored as a tag so it survives hibernation and
    // is recovered via this.state.getTags(ws) in webSocketMessage/Close/Error.
    this.state.acceptWebSocket(ws, [peerIdHex]);

    // Register this peer.
    // If a peer reconnects, close the old socket.
    const existing = this.peers.get(peerIdHex);
    if (existing) {
      console.info(`[relay] peer ${peerIdHex} reconnected - replacing existing socket`);
      this.wsToPeer.delete(existing);
      try {
        existing.close(1000, "replaced");
      } catch {
        console.info(`[relay] close on replaced socket for peer ${peerIdHex} failed (already closed)`);
      }
      this.lastPushSentAt.delete(peerIdHex);
    }

    this.peers.set(peerIdHex, ws);
    this.wsToPeer.set(ws, peerIdHex);

    // Send "connected" text frame to confirm the connection (matches iOS client expectation).
    ws.send("connected");
    console.info(`[relay] peer ${peerIdHex} connected (${this.peers.size} peers now online)`);

    // Drain any store-and-forward packets queued while this peer was offline.
    // Serialized via scheduleDrain so concurrent drains for the same peer
    // (rapid disconnect/reconnect) cannot duplicate-deliver or double-delete.
    // drainInProgress is in-memory; after hibernation wake-up it is empty and
    // the drain re-runs from DO storage state, which is correct.
    this.scheduleDrain(peerIdHex, ws);

    // Message/close/error events are handled by the hibernation API methods
    // below (webSocketMessage, webSocketClose, webSocketError) — no addEventListener.
  }

  // MARK: - Hibernation API event handlers

  async webSocketMessage(ws: WebSocket, message: string | ArrayBuffer): Promise<void> {
    // Ignore text frames (only binary protocol packets are expected).
    if (typeof message === "string") return;

    const peerIdHex = this.peerIdForSocket(ws);
    if (!peerIdHex) return;

    // Defer message processing until any in-progress drain settles, preserving
    // the ordering guarantee from the previous addEventListener approach.
    const drain = this.drainInProgress.get(peerIdHex) ?? Promise.resolve();
    await drain;

    if (!this.wsToPeer.has(ws)) return; // Peer was removed while drain ran.

    const data = message instanceof ArrayBuffer
      ? new Uint8Array(message)
      : new Uint8Array(message as ArrayBuffer);

    this.handleMessageData(ws, peerIdHex, data);
  }

  webSocketClose(ws: WebSocket, _code: number, _reason: string, _wasClean: boolean): void {
    this.removePeer(ws);
  }

  webSocketError(ws: WebSocket, _error: unknown): void {
    this.removePeer(ws);
  }

  // MARK: - Message routing

  /** Shim so existing unit tests calling handleMessage(ws, MessageEvent) continue to work. */
  private handleMessage(senderWs: WebSocket, event: MessageEvent): void {
    if (typeof event.data === "string") return;
    const peerIdHex = this.peerIdForSocket(senderWs);
    if (!peerIdHex) return;
    const data = event.data instanceof ArrayBuffer
      ? new Uint8Array(event.data)
      : new Uint8Array(event.data as ArrayBuffer);
    this.handleMessageData(senderWs, peerIdHex, data);
  }

  private handleMessageData(senderWs: WebSocket, senderPeerIdHex: PeerIDHex, data: Uint8Array): void {
    if (data.length < MIN_PACKET_SIZE || data.length > MAX_PACKET_SIZE) {
      return;
    }

    // Per-peer rate limiting.
    const now = Date.now();
    const timestamps = this.messageTimestamps.get(senderPeerIdHex) ?? [];
    const recentTimestamps = timestamps.filter(t => now - t < 1000);
    if (recentTimestamps.length >= RATE_LIMIT_PER_SECOND) {
      console.warn(`[relay] rate limit hit for peer ${senderPeerIdHex} - packet dropped`);
      return;
    }
    recentTimestamps.push(now);
    this.messageTimestamps.set(senderPeerIdHex, recentTimestamps);

    // Verify the sender PeerID in the packet matches the authenticated connection.
    const packetSenderHex = bytesToHex(
      data.slice(OFFSET_SENDER_ID, OFFSET_SENDER_ID + PEER_ID_LENGTH)
    );
    if (packetSenderHex !== senderPeerIdHex) {
      console.warn(
        `Sender mismatch: packet=${packetSenderHex} connection=${senderPeerIdHex} — dropping`
      );
      return;
    }

    const recipientHex = extractRecipient(data);

    // Rebuild peers Map if the DO woke up from hibernation before any routing.
    this.rebuildPeersIfNeeded();

    if (!recipientHex) {
      // No recipient — broadcast to all *other* peers by PeerID hex, not by
      // WebSocket object identity. A sender that rapidly disconnects and
      // reconnects gets a new socket stored in `this.peers[senderPeerIdHex]`
      // before this broadcast loop runs; comparing `peerWs === senderWs`
      // would then fail to suppress the echo and deliver the sender's own
      // packet back to its new connection. Keying by hex fixes that.
      for (const [peerHex, peerWs] of this.peers) {
        if (peerHex === packetSenderHex) continue;
        try {
          // Allocate an independent ArrayBuffer per recipient. `data.buffer.slice(0)`
          // returns a slice of the underlying ArrayBuffer (not the view region) and
          // can leave recipients sharing memory; `new Uint8Array(data)` allocates a
          // fresh buffer and copies only the view's bytes.
          peerWs.send(new Uint8Array(data).buffer);
        } catch (err) {
          const failedPeer = this.wsToPeer.get(peerWs) ?? "unknown";
          console.warn(`[relay] broadcast send failed for peer ${failedPeer}, removing:`, err);
          Sentry.captureException(err, {
            tags: { component: "relay-room", operation: "broadcast_send" },
            extra: { failedPeer },
          });
          this.removePeer(peerWs);
        }
      }
      return;
    }

    // Addressed packet — try direct delivery. Allocate a fresh buffer rather
    // than sharing `data.buffer` with the handler's view, which prevents
    // aliasing issues when the same bytes are later queued for offline
    // delivery (queuePacket copies `Array.from(data)` but direct sends would
    // otherwise hand the WebSocket the raw view buffer).
    const recipientWs = this.peers.get(recipientHex);
    if (recipientWs) {
      try {
        recipientWs.send(new Uint8Array(data).buffer);
        return;
      } catch (err) {
        console.warn(`[relay] addressed send failed for recipient ${recipientHex}, removing and queuing:`, err);
        Sentry.captureException(err, {
          tags: { component: "relay-room", operation: "addressed_send" },
          extra: { recipientHex },
        });
        this.removePeer(recipientWs);
      }
    }

    // Recipient not connected — store for later delivery.
    this.queuePacket(recipientHex, data);
  }

  // MARK: - Hibernation helpers

  /**
   * Recover peerIdHex for a WebSocket. Checks the in-memory Map first; falls
   * back to hibernation tags after a wake-up where Maps were reset.
   */
  private peerIdForSocket(ws: WebSocket): PeerIDHex | undefined {
    const cached = this.wsToPeer.get(ws);
    if (cached) return cached;

    // After hibernation, in-memory Maps are empty. Recover from stored tags.
    const tags = this.state.getTags(ws);
    const peerHex = tags[0] as PeerIDHex | undefined;
    if (peerHex) {
      this.peers.set(peerHex, ws);
      this.wsToPeer.set(ws, peerHex);
    }
    return peerHex;
  }

  /**
   * Rebuild peers/wsToPeer Maps from hibernation state if they are empty.
   * Called before any broadcast or addressed send to ensure all connected
   * peers are visible after a hibernation wake-up.
   */
  private rebuildPeersIfNeeded(): void {
    if (this.peers.size > 0) return;
    for (const ws of this.state.getWebSockets()) {
      const tags = this.state.getTags(ws);
      const peerHex = tags[0] as PeerIDHex | undefined;
      if (peerHex && !this.peers.has(peerHex)) {
        this.peers.set(peerHex, ws);
        this.wsToPeer.set(ws, peerHex);
      }
    }
  }

  // MARK: - Store-and-forward queue

  /** Queue a packet for offline delivery. Bounded by MAX_QUEUED_PER_PEER. */
  private async queuePacket(recipientHex: PeerIDHex, data: Uint8Array): Promise<void> {
    const storedAt = Date.now();
    const queuePrefix = `${QUEUE_PREFIX}${recipientHex}:`;
    const key = `${queuePrefix}${storedAt}:${crypto.randomUUID().slice(0, 12)}`;

    // Keep queue insertion and cap enforcement atomic so bursts do not exceed the cap.
    await this.state.storage.transaction(async (txn) => {
      await txn.put(key, {
        data: Array.from(data), // Serialize as number[] for DO storage.
        storedAt,
      });

      const allKeys = await txn.list({ prefix: queuePrefix });
      if (allKeys.size > MAX_QUEUED_PER_PEER) {
        const sorted = [...allKeys.keys()].sort();
        const toDelete = sorted.slice(0, allKeys.size - MAX_QUEUED_PER_PEER);
        for (const staleKey of toDelete) {
          await txn.delete(staleKey);
        }
      }
    });

    // Alarm scheduling stays outside the transaction because alarms are managed on storage.
    const existingAlarm = await this.state.storage.getAlarm();
    if (!existingAlarm) {
      this.state.storage.setAlarm(storedAt + QUEUE_TTL_MS);
    }

    // Extract sender PeerID and packet type from header
    const senderHex = bytesToHex(data.slice(OFFSET_SENDER_ID, OFFSET_SENDER_ID + PEER_ID_LENGTH));
    const packetType = data[OFFSET_TYPE];
    // Fire-and-forget push trigger — don't await (don't block queuing)
    this.triggerPush(recipientHex, senderHex, packetType).catch(() => {});
  }

  /**
   * Schedule a drain for `peerHex`, chaining it after any in-progress drain for
   * the same peer. Per-peer drain serialization is the core BDEV-205 fix:
   * concurrent drains on rapid reconnect would otherwise read the same storage
   * keys, send the same packets twice, and double-delete.
   */
  private scheduleDrain(peerHex: PeerIDHex, ws: WebSocket): Promise<void> {
    const previous = this.drainInProgress.get(peerHex) ?? Promise.resolve();
    const chained = previous
      .catch(() => {
        // Don't let a previous drain error block the next one.
      })
      .then(async () => {
        // The peer may have disconnected (or been replaced) while waiting for
        // the previous drain to finish. Only drain if this socket is still the
        // active one for this peer.
        if (this.peers.get(peerHex) !== ws) return;
        await this.drainQueue(peerHex, ws);
      });

    this.drainInProgress.set(peerHex, chained);

    // Clear the map entry once this drain settles, but only if it's still the
    // current one (a newer drain may already have replaced it).
    void chained.finally(() => {
      if (this.drainInProgress.get(peerHex) === chained) {
        this.drainInProgress.delete(peerHex);
      }
    });

    return chained;
  }

  /**
   * Drain queued packets for a connected peer. Always invoked via scheduleDrain
   * so concurrent calls for the same peer are serialized. Sent packets are
   * deleted from storage after the loop; unsent packets stay queued so they can
   * be retried on the next drain or expire via TTL.
   */
  private async drainQueue(peerHex: PeerIDHex, ws: WebSocket): Promise<void> {
    const entries = await this.state.storage.list({ prefix: `${QUEUE_PREFIX}${peerHex}:` });
    if (entries.size === 0) return;

    const now = Date.now();
    const keysToDelete: string[] = [];
    const failedKeys: string[] = [];

    for (const [key, value] of entries) {
      const entry = value as { data: number[]; storedAt: number };

      // Skip expired packets.
      if (now - entry.storedAt > QUEUE_TTL_MS) {
        keysToDelete.push(key);
        continue;
      }

      try {
        const packet = new Uint8Array(entry.data);
        ws.send(packet.buffer);
        keysToDelete.push(key);
      } catch (err) {
        console.warn(`[relay] drainQueue: send failed for ${peerHex}, key=${key} — skipping`);
        Sentry.captureException(err, {
          tags: { component: "relay-room", operation: "drain_send" },
          extra: { peerHex, queueKey: key },
        });
        failedKeys.push(key);
        continue;
      }
    }

    // Clean up delivered/expired entries. Packets that failed to send remain
    // queued so they can be retried on the next drain or expire via TTL.
    for (const key of keysToDelete) {
      await this.state.storage.delete(key);
    }

    if (failedKeys.length === 0) {
      this.drainRetryCount.delete(peerHex);
      return;
    }

    const attempt = (this.drainRetryCount.get(peerHex) ?? 0) + 1;
    if (attempt <= 3) {
      this.drainRetryCount.set(peerHex, attempt);
      console.warn(
        `[relay] drainQueue: ${failedKeys.length} packets failed for ${peerHex}, scheduling retry ${attempt}/3`
      );
      setTimeout(() => {
        const currentWs = this.peers.get(peerHex);
        if (currentWs) {
          void this.scheduleDrain(peerHex, currentWs);
        }
      }, 5000 * attempt);
    } else {
      console.warn(
        `[relay] drainQueue: max retries reached for ${peerHex}, ${failedKeys.length} packets remain queued for TTL expiry`
      );
      Sentry.captureMessage("drainQueue exhausted retries", {
        level: "error",
        tags: { component: "relay-room", operation: "drain_exhausted" },
        extra: { peerHex, remainingPackets: failedKeys.length },
      });
      this.drainRetryCount.delete(peerHex);
    }
  }

  private async triggerPush(recipientHex: string, senderHex: string, packetType?: number): Promise<void> {
    const now = Date.now();
    const lastSent = this.lastPushSentAt.get(recipientHex) ?? 0;
    if (now - lastSent < this.PUSH_COOLDOWN_MS) return;

    this.lastPushSentAt.set(recipientHex, now);

    try {
      const resp = await fetch(this.env.AUTH_PUSH_URL, {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          'X-Internal-Key': this.env.INTERNAL_API_KEY,
        },
        body: JSON.stringify({
          recipientPeerIdHex: recipientHex,
          senderPeerIdHex: senderHex,
          pushType: packetType,
        }),
      });
      if (!resp.ok) {
        console.error(`[relay] Push trigger failed: ${resp.status}`);
        Sentry.captureMessage("Relay push trigger returned non-OK status", {
          level: "warning",
          tags: { component: "relay-room", operation: "push_trigger" },
          extra: { status: resp.status, recipientHex },
        });
      }
    } catch (error) {
      console.error(`[relay] Push trigger error: ${error}`);
      Sentry.captureException(error, {
        tags: { component: "relay-room", operation: "push_trigger" },
        extra: { recipientHex },
      });
      // Fire-and-forget — don't break packet queuing
    }
  }

  /** Periodic cleanup of expired queued packets. Called by DO alarm. */
  async alarm(): Promise<void> {
    const allEntries = await this.state.storage.list({ prefix: QUEUE_PREFIX });
    const now = Date.now();
    let deleted = 0;
    for (const [key, value] of allEntries) {
      const entry = value as { data: number[]; storedAt: number };
      if (now - entry.storedAt > QUEUE_TTL_MS) {
        await this.state.storage.delete(key);
        deleted++;
      }
    }
    // Schedule next cleanup if there are still queued items.
    const remaining = await this.state.storage.list({ prefix: QUEUE_PREFIX, limit: 1 });
    if (remaining.size > 0) {
      this.state.storage.setAlarm(Date.now() + QUEUE_TTL_MS);
    }
  }

  private removePeer(ws: WebSocket): void {
    const peerIdHex = this.wsToPeer.get(ws);
    if (peerIdHex) {
      const remainingPeers = this.peers.get(peerIdHex) === ws ? this.peers.size - 1 : this.peers.size;
      console.info(`[relay] peer ${peerIdHex} removed (${remainingPeers} peers remaining)`);
      // Only remove from peers if this ws is still the registered one
      // (handles race with reconnection replacing the socket).
      if (this.peers.get(peerIdHex) === ws) {
        this.peers.delete(peerIdHex);
      }
      this.wsToPeer.delete(ws);
      this.messageTimestamps.delete(peerIdHex);
      this.drainRetryCount.delete(peerIdHex);
    }
  }
}
