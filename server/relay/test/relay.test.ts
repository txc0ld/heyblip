import { env, createExecutionContext, waitOnExecutionContext } from "cloudflare:test";
import { describe, it, expect, afterEach, beforeEach, vi } from "vitest";
import worker, { parseAuthHeader, derivePeerIdHex, validateAuthorizationHeader } from "../src/index";
import { extractRecipient, RelayRoom, hexToSyntheticUUID } from "../src/relay-room";
import {
  HEADER_SIZE,
  PEER_ID_LENGTH,
  FLAG_HAS_RECIPIENT,
  OFFSET_FLAGS,
  OFFSET_SENDER_ID,
  OFFSET_RECIPIENT_ID,
  bytesToHex,
  type Env,
  type PeerIDHex,
} from "../src/types";

// --- Helpers ---

function randomPublicKey(): Uint8Array {
  const key = new Uint8Array(32);
  crypto.getRandomValues(key);
  return key;
}

function toBase64(bytes: Uint8Array): string {
  let binary = "";
  for (let i = 0; i < bytes.length; i++) {
    binary += String.fromCharCode(bytes[i]);
  }
  return btoa(binary);
}

function toBase64Url(bytes: Uint8Array): string {
  return toBase64(bytes).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/g, "");
}

async function signJWT(payload: Record<string, unknown>, secret: string): Promise<string> {
  const header = { alg: "HS256", typ: "JWT" };
  const encodedHeader = toBase64Url(new TextEncoder().encode(JSON.stringify(header)));
  const encodedPayload = toBase64Url(new TextEncoder().encode(JSON.stringify(payload)));
  const signingInput = `${encodedHeader}.${encodedPayload}`;
  const key = await crypto.subtle.importKey(
    "raw",
    new TextEncoder().encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"]
  );
  const signature = await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(signingInput));
  return `${signingInput}.${toBase64Url(new Uint8Array(signature))}`;
}

async function derivePeerIdBytes(publicKey: Uint8Array): Promise<Uint8Array> {
  const hash = await crypto.subtle.digest("SHA-256", publicKey);
  return new Uint8Array(hash).slice(0, PEER_ID_LENGTH);
}

function hexToPeerID(hex: string): Uint8Array {
  const bytes = new Uint8Array(hex.length / 2);
  for (let i = 0; i < hex.length; i += 2) {
    bytes[i / 2] = Number.parseInt(hex.slice(i, i + 2), 16);
  }
  return bytes;
}

function buildPacket(opts: {
  senderPeerId: Uint8Array;
  recipientPeerId?: Uint8Array;
  payload?: Uint8Array;
}): Uint8Array {
  const hasRecipient = !!opts.recipientPeerId;
  const payload = opts.payload ?? new Uint8Array([0x48, 0x65, 0x6c, 0x6c, 0x6f]);
  const flags = hasRecipient ? FLAG_HAS_RECIPIENT : 0;
  const size =
    HEADER_SIZE +
    PEER_ID_LENGTH +
    (hasRecipient ? PEER_ID_LENGTH : 0) +
    payload.length;

  const buf = new Uint8Array(size);
  const view = new DataView(buf.buffer);

  buf[0] = 0x01;
  buf[1] = 0x01;
  buf[2] = 3;
  view.setBigUint64(3, BigInt(Date.now()), false);
  buf[OFFSET_FLAGS] = flags;
  view.setUint32(12, payload.length, false);
  buf.set(opts.senderPeerId, OFFSET_SENDER_ID);

  let payloadOffset = OFFSET_SENDER_ID + PEER_ID_LENGTH;
  if (hasRecipient && opts.recipientPeerId) {
    buf.set(opts.recipientPeerId, OFFSET_RECIPIENT_ID);
    payloadOffset = OFFSET_RECIPIENT_ID + PEER_ID_LENGTH;
  }

  buf.set(payload, payloadOffset);
  return buf;
}

function makeUpgradeRequest(publicKey: Uint8Array): Request {
  return new Request("https://relay.heyblip.au/ws", {
    headers: {
      Upgrade: "websocket",
      Authorization: `Bearer ${toBase64(publicKey)}`,
    },
  });
}

// Track open WebSockets for cleanup.
const openSockets: WebSocket[] = [];

afterEach(() => {
  for (const ws of openSockets) {
    try { ws.close(1000, "test cleanup"); } catch { /* already closed */ }
  }
  openSockets.length = 0;
});

beforeEach(() => {
  (env as Record<string, unknown>).JWT_SECRET = "relay-test-secret";
  // Most tests use legacy base64 auth for convenience (bypassing JWT). That
  // path is now gated behind an explicit env flag to prevent it slipping into
  // production. Enable it unconditionally for the test suite; dedicated tests
  // below clear it to verify the guardrail.
  (env as Record<string, unknown>).ALLOW_LEGACY_AUTH = "1";
});

async function connectPeer(key: Uint8Array): Promise<WebSocket> {
  const req = makeUpgradeRequest(key);
  const ctx = createExecutionContext();
  const res = await worker.fetch(req, env, ctx);
  await waitOnExecutionContext(ctx);
  expect(res.status).toBe(101);
  const ws = res.webSocket!;
  ws.accept();
  openSockets.push(ws);
  return ws;
}

function collectBinaryMessages(ws: WebSocket): ArrayBuffer[] {
  const messages: ArrayBuffer[] = [];
  ws.addEventListener("message", (event: MessageEvent) => {
    if (event.data instanceof ArrayBuffer) {
      messages.push(event.data);
    }
  });
  return messages;
}

type QueueEntry = { data: number[]; storedAt: number };

class FakeStorage {
  private entries = new Map<string, unknown>();
  private alarm: number | null = null;

  seed(entries: Array<[string, unknown]>): void {
    this.entries = new Map(entries);
  }

  async list<T = unknown>(options?: { prefix?: string; limit?: number }): Promise<Map<string, T>> {
    const prefix = options?.prefix ?? "";
    const limit = options?.limit;
    const filtered = [...this.entries.entries()]
      .filter(([key]) => key.startsWith(prefix))
      .sort(([left], [right]) => left.localeCompare(right));

    const sliced = typeof limit === "number" ? filtered.slice(0, limit) : filtered;
    return new Map(sliced) as Map<string, T>;
  }

  async delete(key: string): Promise<boolean> {
    return this.entries.delete(key);
  }

  async get<T = unknown>(key: string): Promise<T | undefined> {
    const value = this.entries.get(key);
    if (value === undefined) return undefined;
    // Storage round-trips values as structured clones, so callers can't leak
    // local mutations back into storage.
    return structuredClone(value) as T;
  }

  async put<T = unknown>(key: string, value: T): Promise<void> {
    this.entries.set(key, structuredClone(value));
  }

  async getAlarm(): Promise<number | null> {
    return this.alarm;
  }

  setAlarm(when: number): void {
    this.alarm = when;
  }

  async transaction<T>(closure: (txn: FakeStorage) => Promise<T>): Promise<T> {
    // In the real DO runtime transactions are fully serialized against the
    // single-threaded event loop. This fake runs the closure directly against
    // `this` so mutations are immediately visible — matches the semantics of
    // the DO transaction for our tests (no rollback on thrown error).
    return await closure(this);
  }

  has(key: string): boolean {
    return this.entries.has(key);
  }

  keys(): string[] {
    return [...this.entries.keys()].sort();
  }

  allEntries(): Map<string, unknown> {
    return new Map(this.entries);
  }
}

function makeRelayRoom(storage: FakeStorage): RelayRoom {
  // Minimal hibernation API stubs so handleSession (acceptWebSocket) and
  // post-hibernation rebuild (getWebSockets/getTags) work in unit tests.
  const wsTagMap = new Map<WebSocket, string[]>();
  const state = {
    storage,
    acceptWebSocket(ws: WebSocket, tags: string[] = []): void {
      ws.accept(); // mirrors real CF hibernation API which accepts the socket internally
      wsTagMap.set(ws, tags);
    },
    getWebSockets(tag?: string): WebSocket[] {
      if (tag === undefined) return [...wsTagMap.keys()];
      return [...wsTagMap.entries()]
        .filter(([, tags]) => tags.includes(tag))
        .map(([ws]) => ws);
    },
    getTags(ws: WebSocket): string[] {
      return wsTagMap.get(ws) ?? [];
    },
  } as unknown as DurableObjectState;

  return new RelayRoom(state, {
    AUTH_PUSH_URL: "http://localhost/push",
    INTERNAL_API_KEY: "test-key",
  } as unknown as Env);
}

function queuedPacketEntry(storedAt: number): QueueEntry {
  return {
    data: [0x01, 0x02, 0x03],
    storedAt,
  };
}

// --- Unit Tests: Auth Validation ---

describe("parseAuthHeader", () => {
  it("returns null for missing header", () => {
    expect(parseAuthHeader(null)).toBeNull();
  });

  it("returns null for non-Bearer auth", () => {
    expect(parseAuthHeader("Basic dGVzdDp0ZXN0")).toBeNull();
  });

  it("returns null for invalid base64", () => {
    expect(parseAuthHeader("Bearer !!!not-base64!!!")).toBeNull();
  });

  it("returns null for wrong key length (16 bytes)", () => {
    const shortKey = new Uint8Array(16);
    crypto.getRandomValues(shortKey);
    expect(parseAuthHeader(`Bearer ${toBase64(shortKey)}`)).toBeNull();
  });

  it("returns 32-byte key for valid token", () => {
    const key = randomPublicKey();
    const result = parseAuthHeader(`Bearer ${toBase64(key)}`);
    expect(result).not.toBeNull();
    expect(result!.length).toBe(32);
    expect(new Uint8Array(result!)).toEqual(key);
  });
});

describe("validateAuthorizationHeader", () => {
  it("accepts a valid JWT", async () => {
    const publicKey = randomPublicKey();
    const peerIdHex = await derivePeerIdHex(publicKey);
    const nowSeconds = Math.floor(Date.now() / 1000);
    const token = await signJWT({
        sub: peerIdHex,
        npk: toBase64(publicKey),
        iat: nowSeconds,
        exp: nowSeconds + 3600,
    }, "relay-test-secret");

    const auth = await validateAuthorizationHeader(`Bearer ${token}`, env);
    expect(auth.peerIdHex).toBe(peerIdHex);
    expect(auth.source).toBe("jwt");
  });
});

// --- Unit Tests: PeerID Derivation ---

describe("PeerID derivation", () => {
  it("produces correct SHA-256 truncation (16 hex chars)", async () => {
    const key = new Uint8Array(32); // all zeros
    const hex = await derivePeerIdHex(key);
    expect(hex.length).toBe(16);

    // Verify independently.
    const hash = await crypto.subtle.digest("SHA-256", key);
    const expected = bytesToHex(new Uint8Array(hash).slice(0, PEER_ID_LENGTH));
    expect(hex).toBe(expected);
  });

  it("different keys produce different PeerIDs", async () => {
    const key1 = randomPublicKey();
    const key2 = randomPublicKey();
    const id1 = await derivePeerIdHex(key1);
    const id2 = await derivePeerIdHex(key2);
    expect(id1).not.toBe(id2);
  });
});

// --- Unit Tests: Packet Recipient Extraction ---

describe("extractRecipient", () => {
  it("returns recipient hex for addressed packet", async () => {
    const sender = await derivePeerIdBytes(randomPublicKey());
    const recipient = await derivePeerIdBytes(randomPublicKey());
    const packet = buildPacket({ senderPeerId: sender, recipientPeerId: recipient });
    const result = extractRecipient(packet);
    expect(result).toBe(bytesToHex(recipient));
  });

  it("returns null for broadcast packet (no hasRecipient flag)", async () => {
    const sender = await derivePeerIdBytes(randomPublicKey());
    const packet = buildPacket({ senderPeerId: sender });
    expect(extractRecipient(packet)).toBeNull();
  });

  it("returns null for packet too short", () => {
    const tiny = new Uint8Array(10);
    expect(extractRecipient(tiny)).toBeNull();
  });
});

describe("RelayRoom drain retry behavior", () => {
  beforeEach(() => {
    vi.useFakeTimers();
  });

  afterEach(() => {
    vi.useRealTimers();
    vi.restoreAllMocks();
  });

  it("continues draining after a send failure and retries failed packets", async () => {
    const peerHex = "deadbeefcafebabe";
    const now = Date.now();
    const storage = new FakeStorage();
    storage.seed([
      [`q:${peerHex}:0001:a`, queuedPacketEntry(now)],
      [`q:${peerHex}:0002:b`, queuedPacketEntry(now)],
      [`q:${peerHex}:0003:c`, queuedPacketEntry(now)],
    ]);

    const room = makeRelayRoom(storage);
    const send = vi
      .fn<(payload: ArrayBuffer) => void>()
      .mockImplementationOnce(() => {
        throw new Error("socket hiccup");
      })
      .mockImplementation(() => {});
    const ws = { send } as unknown as WebSocket;
    const warnSpy = vi.spyOn(console, "warn").mockImplementation(() => {});

    (room as unknown as {
      peers: Map<PeerIDHex, WebSocket>;
    }).peers.set(peerHex, ws);

    await (room as unknown as {
      drainQueue(peerHex: PeerIDHex, ws: WebSocket): Promise<void>;
    }).drainQueue(peerHex, ws);

    expect(send).toHaveBeenCalledTimes(3);
    expect(storage.keys()).toEqual([`q:${peerHex}:0001:a`]);
    expect(
      (room as unknown as { drainRetryCount: Map<PeerIDHex, number> }).drainRetryCount.get(peerHex)
    ).toBe(1);
    expect(warnSpy).toHaveBeenCalledWith(
      `[relay] drainQueue: send failed for ${peerHex}, key=q:${peerHex}:0001:a — skipping`
    );
    expect(warnSpy).toHaveBeenCalledWith(
      `[relay] drainQueue: 1 packets failed for ${peerHex}, scheduling retry 1/3`
    );

    await vi.advanceTimersByTimeAsync(5000);

    expect(send).toHaveBeenCalledTimes(4);
    expect(storage.keys()).toEqual([]);
    expect(
      (room as unknown as { drainRetryCount: Map<PeerIDHex, number> }).drainRetryCount.has(peerHex)
    ).toBe(false);
  });

  it("caps retries at three and leaves failed packets queued", async () => {
    const peerHex = "0011223344556677";
    const now = Date.now();
    const storage = new FakeStorage();
    storage.seed([[`q:${peerHex}:0001:a`, queuedPacketEntry(now)]]);

    const room = makeRelayRoom(storage);
    const send = vi.fn<(payload: ArrayBuffer) => void>().mockImplementation(() => {
      throw new Error("still broken");
    });
    const ws = { send } as unknown as WebSocket;
    const warnSpy = vi.spyOn(console, "warn").mockImplementation(() => {});

    (room as unknown as {
      peers: Map<PeerIDHex, WebSocket>;
    }).peers.set(peerHex, ws);

    await (room as unknown as {
      drainQueue(peerHex: PeerIDHex, ws: WebSocket): Promise<void>;
    }).drainQueue(peerHex, ws);
    await vi.advanceTimersByTimeAsync(5000);
    await vi.advanceTimersByTimeAsync(10000);
    await vi.advanceTimersByTimeAsync(15000);

    expect(send).toHaveBeenCalledTimes(4);
    expect(storage.keys()).toEqual([`q:${peerHex}:0001:a`]);
    expect(
      (room as unknown as { drainRetryCount: Map<PeerIDHex, number> }).drainRetryCount.has(peerHex)
    ).toBe(false);
    expect(warnSpy).toHaveBeenCalledWith(
      `[relay] drainQueue: max retries reached for ${peerHex}, 1 packets remain queued for TTL expiry`
    );
  });

  it("cleans retry state when a peer is removed", () => {
    const peerHex = "8899aabbccddeeff";
    const storage = new FakeStorage();
    const room = makeRelayRoom(storage);
    const ws = { send: () => {} } as unknown as WebSocket;

    (room as unknown as {
      peers: Map<PeerIDHex, WebSocket>;
      wsToPeer: Map<WebSocket, PeerIDHex>;
      messageTimestamps: Map<PeerIDHex, number[]>;
      drainRetryCount: Map<PeerIDHex, number>;
    }).peers.set(peerHex, ws);
    (room as unknown as {
      peers: Map<PeerIDHex, WebSocket>;
      wsToPeer: Map<WebSocket, PeerIDHex>;
      messageTimestamps: Map<PeerIDHex, number[]>;
      drainRetryCount: Map<PeerIDHex, number>;
    }).wsToPeer.set(ws, peerHex);
    (room as unknown as {
      peers: Map<PeerIDHex, WebSocket>;
      wsToPeer: Map<WebSocket, PeerIDHex>;
      messageTimestamps: Map<PeerIDHex, number[]>;
      drainRetryCount: Map<PeerIDHex, number>;
    }).messageTimestamps.set(peerHex, [Date.now()]);
    (room as unknown as {
      peers: Map<PeerIDHex, WebSocket>;
      wsToPeer: Map<WebSocket, PeerIDHex>;
      messageTimestamps: Map<PeerIDHex, number[]>;
      drainRetryCount: Map<PeerIDHex, number>;
    }).drainRetryCount.set(peerHex, 2);

    (room as unknown as {
      removePeer(ws: WebSocket): void;
    }).removePeer(ws);

    expect(
      (room as unknown as { peers: Map<PeerIDHex, WebSocket> }).peers.has(peerHex)
    ).toBe(false);
    expect(
      (room as unknown as { wsToPeer: Map<WebSocket, PeerIDHex> }).wsToPeer.has(ws)
    ).toBe(false);
    expect(
      (room as unknown as { messageTimestamps: Map<PeerIDHex, number[]> }).messageTimestamps.has(peerHex)
    ).toBe(false);
    expect(
      (room as unknown as { drainRetryCount: Map<PeerIDHex, number> }).drainRetryCount.has(peerHex)
    ).toBe(false);
  });

  it("serializes concurrent drains for the same peer (BDEV-205)", async () => {
    // Regression test for the rapid disconnect/reconnect race that caused
    // duplicate packet delivery and double-deletes on the same storage keys.
    // Two scheduleDrain calls back-to-back must NOT both read+send the same
    // queued packets. The second drain should run after the first finishes,
    // and by then the storage will be empty.
    const peerHex = "ffeeddccbbaa9988";
    const now = Date.now();
    const storage = new FakeStorage();
    storage.seed([
      [`q:${peerHex}:0001:a`, queuedPacketEntry(now)],
      [`q:${peerHex}:0002:b`, queuedPacketEntry(now)],
      [`q:${peerHex}:0003:c`, queuedPacketEntry(now)],
    ]);

    const room = makeRelayRoom(storage);
    const send = vi.fn<(payload: ArrayBuffer) => void>().mockImplementation(() => {});
    const ws = { send } as unknown as WebSocket;

    (room as unknown as {
      peers: Map<PeerIDHex, WebSocket>;
    }).peers.set(peerHex, ws);

    // Fire two drains in rapid succession (simulating rapid reconnect).
    const first = (room as unknown as {
      scheduleDrain(peerHex: PeerIDHex, ws: WebSocket): Promise<void>;
    }).scheduleDrain(peerHex, ws);
    const second = (room as unknown as {
      scheduleDrain(peerHex: PeerIDHex, ws: WebSocket): Promise<void>;
    }).scheduleDrain(peerHex, ws);

    await Promise.all([first, second]);

    // Each queued packet must be sent exactly once, even though two drains
    // were scheduled concurrently.
    expect(send).toHaveBeenCalledTimes(3);
    expect(storage.keys()).toEqual([]);
  });

  it("does not deliver queued packets to a stale socket", async () => {
    // If the active socket for a peer gets replaced before a scheduled drain
    // runs (e.g. fast reconnect on a new socket), the original drain must
    // NOT send queued packets to the stale socket.
    const peerHex = "1122334455667788";
    const now = Date.now();
    const storage = new FakeStorage();
    storage.seed([[`q:${peerHex}:0001:a`, queuedPacketEntry(now)]]);

    const room = makeRelayRoom(storage);
    const sendOld = vi.fn<(payload: ArrayBuffer) => void>().mockImplementation(() => {});
    const oldWs = { send: sendOld } as unknown as WebSocket;
    const newWs = { send: () => {} } as unknown as WebSocket;

    (room as unknown as {
      peers: Map<PeerIDHex, WebSocket>;
    }).peers.set(peerHex, oldWs);

    // Schedule a drain for oldWs, then swap the active socket synchronously
    // before any microtask runs.
    const drain = (room as unknown as {
      scheduleDrain(peerHex: PeerIDHex, ws: WebSocket): Promise<void>;
    }).scheduleDrain(peerHex, oldWs);

    (room as unknown as {
      peers: Map<PeerIDHex, WebSocket>;
    }).peers.set(peerHex, newWs);

    await drain;

    // Old socket must not have received the queued packet.
    expect(sendOld).not.toHaveBeenCalled();
    // The packet must remain queued for the new socket's drain.
    expect(storage.keys()).toEqual([`q:${peerHex}:0001:a`]);
  });
});

// --- Integration Tests: HTTP Endpoints ---

describe("HTTP endpoints", () => {
  it("returns 404 for non-/ws paths", async () => {
    const req = new Request("https://relay.heyblip.au/other");
    const ctx = createExecutionContext();
    const res = await worker.fetch(req, env, ctx);
    await waitOnExecutionContext(ctx);
    expect(res.status).toBe(404);
  });

  it("returns 426 for /ws without Upgrade header", async () => {
    const key = randomPublicKey();
    const req = new Request("https://relay.heyblip.au/ws", {
      headers: { Authorization: `Bearer ${toBase64(key)}` },
    });
    const ctx = createExecutionContext();
    const res = await worker.fetch(req, env, ctx);
    await waitOnExecutionContext(ctx);
    expect(res.status).toBe(426);
  });

  it("returns 200 for /health", async () => {
    const req = new Request("https://relay.heyblip.au/health");
    const ctx = createExecutionContext();
    const res = await worker.fetch(req, env, ctx);
    await waitOnExecutionContext(ctx);
    expect(res.status).toBe(200);
  });

  it("rejects missing Authorization", async () => {
    const req = new Request("https://relay.heyblip.au/ws", {
      headers: { Upgrade: "websocket" },
    });
    const ctx = createExecutionContext();
    const res = await worker.fetch(req, env, ctx);
    await waitOnExecutionContext(ctx);
    expect(res.status).toBe(401);
  });

  it("rejects invalid key length", async () => {
    const shortKey = new Uint8Array(16);
    const req = new Request("https://relay.heyblip.au/ws", {
      headers: {
        Upgrade: "websocket",
        Authorization: `Bearer ${toBase64(shortKey)}`,
      },
    });
    const ctx = createExecutionContext();
    const res = await worker.fetch(req, env, ctx);
    await waitOnExecutionContext(ctx);
    expect(res.status).toBe(401);
  });

  it("upgrades to WebSocket with valid 32-byte key", async () => {
    const key = randomPublicKey();
    const ws = await connectPeer(key);
    expect(ws).toBeDefined();
  });
});

// --- Integration Tests: Packet Routing ---

describe("Packet routing", () => {
  it("routes a packet from peer A to peer B", async () => {
    const keyA = randomPublicKey();
    const keyB = randomPublicKey();
    const peerIdA = await derivePeerIdBytes(keyA);
    const peerIdB = await derivePeerIdBytes(keyB);

    const wsA = await connectPeer(keyA);
    const wsB = await connectPeer(keyB);
    const messagesB = collectBinaryMessages(wsB);

    await new Promise((r) => setTimeout(r, 50));

    const payload = new Uint8Array([0xDE, 0xAD, 0xBE, 0xEF]);
    const packet = buildPacket({
      senderPeerId: peerIdA,
      recipientPeerId: peerIdB,
      payload,
    });

    wsA.send(packet.buffer);
    await new Promise((r) => setTimeout(r, 100));

    expect(messagesB.length).toBe(1);
    expect(new Uint8Array(messagesB[0])).toEqual(packet);
  });

  it("silently drops packets for unknown recipient", async () => {
    const keyA = randomPublicKey();
    const peerIdA = await derivePeerIdBytes(keyA);
    const fakePeerId = new Uint8Array(8);
    crypto.getRandomValues(fakePeerId);

    const wsA = await connectPeer(keyA);
    await new Promise((r) => setTimeout(r, 50));

    const packet = buildPacket({
      senderPeerId: peerIdA,
      recipientPeerId: fakePeerId,
    });

    const errors: Event[] = [];
    wsA.addEventListener("error", (e) => errors.push(e));

    wsA.send(packet.buffer);
    await new Promise((r) => setTimeout(r, 100));

    expect(errors.length).toBe(0);
  });

  it("broadcasts non-addressed packets to other peers", async () => {
    const keyA = randomPublicKey();
    const keyB = randomPublicKey();
    const peerIdA = await derivePeerIdBytes(keyA);

    const wsA = await connectPeer(keyA);
    const wsB = await connectPeer(keyB);
    const messagesB = collectBinaryMessages(wsB);

    await new Promise((r) => setTimeout(r, 50));

    const packet = buildPacket({ senderPeerId: peerIdA });
    wsA.send(packet.buffer);
    await new Promise((r) => setTimeout(r, 100));

    expect(messagesB.length).toBe(1);
    expect(new Uint8Array(messagesB[0])).toEqual(packet);
  });

  it("preserves binary packet integrity exactly", async () => {
    const keyA = randomPublicKey();
    const keyB = randomPublicKey();
    const peerIdA = await derivePeerIdBytes(keyA);
    const peerIdB = await derivePeerIdBytes(keyB);

    const wsA = await connectPeer(keyA);
    const wsB = await connectPeer(keyB);
    const messagesB = collectBinaryMessages(wsB);

    await new Promise((r) => setTimeout(r, 50));

    const largePayload = new Uint8Array(256);
    crypto.getRandomValues(largePayload);
    const packet = buildPacket({
      senderPeerId: peerIdA,
      recipientPeerId: peerIdB,
      payload: largePayload,
    });

    wsA.send(packet.buffer);
    await new Promise((r) => setTimeout(r, 100));

    expect(messagesB.length).toBe(1);
    const received = new Uint8Array(messagesB[0]);
    expect(received.length).toBe(packet.length);
    for (let i = 0; i < packet.length; i++) {
      expect(received[i]).toBe(packet[i]);
    }
  });
});

// --- Integration Tests: Disconnect & Concurrency ---

describe("Disconnect cleanup", () => {
  it("removes peer from map on close — subsequent send is dropped", async () => {
    const keyA = randomPublicKey();
    const keyB = randomPublicKey();
    const peerIdA = await derivePeerIdBytes(keyA);
    const peerIdB = await derivePeerIdBytes(keyB);

    const wsA = await connectPeer(keyA);
    const wsB = await connectPeer(keyB);

    await new Promise((r) => setTimeout(r, 50));

    // Close B, remove from our tracking so afterEach doesn't double-close.
    wsB.close(1000, "bye");
    openSockets.splice(openSockets.indexOf(wsB), 1);
    await new Promise((r) => setTimeout(r, 100));

    // Send from A to B — should silently drop.
    const packet = buildPacket({
      senderPeerId: peerIdA,
      recipientPeerId: peerIdB,
    });
    const errors: Event[] = [];
    wsA.addEventListener("error", (e) => errors.push(e));
    wsA.send(packet.buffer);
    await new Promise((r) => setTimeout(r, 100));

    expect(errors.length).toBe(0);
  });
});

describe("relay logging", () => {
  it("logs WebSocket upgrade requests and state sync requests", async () => {
    const peerHex = "aaaaaaaaaaaaaaaa";
    const storage = new FakeStorage();
    const room = makeRelayRoom(storage);
    const infoSpy = vi.spyOn(console, "info").mockImplementation(() => {});

    const upgradeResponse = await room.fetch(new Request("https://relay.heyblip.au/ws", {
      headers: {
        "X-Derived-Peer-ID": peerHex,
      },
    }));
    const stateResponse = await room.fetch(new Request("https://relay.heyblip.au/state", {
      headers: {
        "X-Derived-Peer-ID": peerHex,
        "X-State-Action": "get",
      },
    }));

    expect(upgradeResponse.status).toBe(101);
    expect(stateResponse.status).toBe(404);
    expect(infoSpy).toHaveBeenCalledWith(
      `[relay] WebSocket upgrade request from peer ${peerHex}`
    );
    expect(infoSpy).toHaveBeenCalledWith(
      `[relay] state get for peer ${peerHex}`
    );
    expect(infoSpy).toHaveBeenCalledWith(
      `[relay] peer ${peerHex} connected (1 peers now online)`
    );
    infoSpy.mockRestore();
  });

  it("logs when closing a replaced socket throws", () => {
    const peerHex = "0011223344556677";
    const storage = new FakeStorage();
    const room = makeRelayRoom(storage);
    const existing = {
      close: vi.fn(() => {
        throw new Error("already closed");
      }),
    } as unknown as WebSocket;
    const replacement = {
      accept: vi.fn(),
      send: vi.fn(),
      addEventListener: vi.fn(),
    } as unknown as WebSocket;
    const infoSpy = vi.spyOn(console, "info").mockImplementation(() => {});

    (room as unknown as {
      peers: Map<PeerIDHex, WebSocket>;
      wsToPeer: Map<WebSocket, PeerIDHex>;
      handleSession(ws: WebSocket, peerIdHex: PeerIDHex): void;
    }).peers.set(peerHex, existing);
    (room as unknown as {
      peers: Map<PeerIDHex, WebSocket>;
      wsToPeer: Map<WebSocket, PeerIDHex>;
      handleSession(ws: WebSocket, peerIdHex: PeerIDHex): void;
    }).wsToPeer.set(existing, peerHex);

    (room as unknown as {
      handleSession(ws: WebSocket, peerIdHex: PeerIDHex): void;
    }).handleSession(replacement, peerHex);

    expect(infoSpy).toHaveBeenCalledWith(
      `[relay] peer ${peerHex} reconnected - replacing existing socket`
    );
    expect(infoSpy).toHaveBeenCalledWith(
      `[relay] close on replaced socket for peer ${peerHex} failed (already closed)`
    );
    expect(infoSpy).toHaveBeenCalledWith(
      `[relay] peer ${peerHex} connected (1 peers now online)`
    );
    infoSpy.mockRestore();
  });

  it("logs when a peer is rate limited", () => {
    const senderPeerHex = "5555555555555555";
    const storage = new FakeStorage();
    const room = makeRelayRoom(storage);
    const senderWs = {} as WebSocket;
    const warnSpy = vi.spyOn(console, "warn").mockImplementation(() => {});
    const packet = buildPacket({ senderPeerId: hexToPeerID(senderPeerHex) });

    (room as unknown as {
      wsToPeer: Map<WebSocket, PeerIDHex>;
      messageTimestamps: Map<PeerIDHex, number[]>;
      handleMessage(senderWs: WebSocket, event: MessageEvent): void;
    }).wsToPeer.set(senderWs, senderPeerHex);
    (room as unknown as {
      wsToPeer: Map<WebSocket, PeerIDHex>;
      messageTimestamps: Map<PeerIDHex, number[]>;
      handleMessage(senderWs: WebSocket, event: MessageEvent): void;
    }).messageTimestamps.set(
      senderPeerHex,
      Array.from({ length: 100 }, () => Date.now())
    );

    (room as unknown as {
      handleMessage(senderWs: WebSocket, event: MessageEvent): void;
    }).handleMessage(senderWs, { data: packet.buffer } as MessageEvent);

    expect(warnSpy).toHaveBeenCalledWith(
      `[relay] rate limit hit for peer ${senderPeerHex} - packet dropped`
    );
    warnSpy.mockRestore();
  });

  it("logs the peer ID when broadcast delivery fails", () => {
    const senderPeerHex = "1111111111111111";
    const recipientPeerHex = "2222222222222222";
    const storage = new FakeStorage();
    const room = makeRelayRoom(storage);
    const senderWs = {} as WebSocket;
    const failingPeerWs = {
      send: vi.fn(() => {
        throw new Error("boom");
      }),
    } as unknown as WebSocket;
    const warnSpy = vi.spyOn(console, "warn").mockImplementation(() => {});
    const packet = buildPacket({ senderPeerId: hexToPeerID(senderPeerHex) });

    (room as unknown as {
      peers: Map<PeerIDHex, WebSocket>;
      wsToPeer: Map<WebSocket, PeerIDHex>;
      handleMessage(senderWs: WebSocket, event: MessageEvent): void;
    }).peers.set(senderPeerHex, senderWs);
    (room as unknown as {
      peers: Map<PeerIDHex, WebSocket>;
      wsToPeer: Map<WebSocket, PeerIDHex>;
      handleMessage(senderWs: WebSocket, event: MessageEvent): void;
    }).peers.set(recipientPeerHex, failingPeerWs);
    (room as unknown as {
      peers: Map<PeerIDHex, WebSocket>;
      wsToPeer: Map<WebSocket, PeerIDHex>;
      handleMessage(senderWs: WebSocket, event: MessageEvent): void;
    }).wsToPeer.set(senderWs, senderPeerHex);
    (room as unknown as {
      peers: Map<PeerIDHex, WebSocket>;
      wsToPeer: Map<WebSocket, PeerIDHex>;
      handleMessage(senderWs: WebSocket, event: MessageEvent): void;
    }).wsToPeer.set(failingPeerWs, recipientPeerHex);

    (room as unknown as {
      handleMessage(senderWs: WebSocket, event: MessageEvent): void;
    }).handleMessage(senderWs, { data: packet.buffer } as MessageEvent);

    expect(warnSpy).toHaveBeenCalledWith(
      `[relay] broadcast send failed for peer ${recipientPeerHex}, removing:`,
      expect.any(Error)
    );
    warnSpy.mockRestore();
  });

  it("logs the recipient when addressed delivery fails", () => {
    const senderPeerHex = "3333333333333333";
    const recipientPeerHex = "4444444444444444";
    const storage = new FakeStorage();
    const room = makeRelayRoom(storage);
    const senderWs = {} as WebSocket;
    const failingRecipientWs = {
      send: vi.fn(() => {
        throw new Error("boom");
      }),
    } as unknown as WebSocket;
    const warnSpy = vi.spyOn(console, "warn").mockImplementation(() => {});
    const packet = buildPacket({
      senderPeerId: hexToPeerID(senderPeerHex),
      recipientPeerId: hexToPeerID(recipientPeerHex),
    });

    (room as unknown as {
      peers: Map<PeerIDHex, WebSocket>;
      wsToPeer: Map<WebSocket, PeerIDHex>;
      handleMessage(senderWs: WebSocket, event: MessageEvent): void;
    }).peers.set(senderPeerHex, senderWs);
    (room as unknown as {
      peers: Map<PeerIDHex, WebSocket>;
      wsToPeer: Map<WebSocket, PeerIDHex>;
      handleMessage(senderWs: WebSocket, event: MessageEvent): void;
    }).peers.set(recipientPeerHex, failingRecipientWs);
    (room as unknown as {
      peers: Map<PeerIDHex, WebSocket>;
      wsToPeer: Map<WebSocket, PeerIDHex>;
      handleMessage(senderWs: WebSocket, event: MessageEvent): void;
    }).wsToPeer.set(senderWs, senderPeerHex);
    (room as unknown as {
      peers: Map<PeerIDHex, WebSocket>;
      wsToPeer: Map<WebSocket, PeerIDHex>;
      handleMessage(senderWs: WebSocket, event: MessageEvent): void;
    }).wsToPeer.set(failingRecipientWs, recipientPeerHex);

    (room as unknown as {
      handleMessage(senderWs: WebSocket, event: MessageEvent): void;
    }).handleMessage(senderWs, { data: packet.buffer } as MessageEvent);

    expect(warnSpy).toHaveBeenCalledWith(
      `[relay] addressed send failed for recipient ${recipientPeerHex}, removing and queuing:`,
      expect.any(Error)
    );
    warnSpy.mockRestore();
  });

  it("logs when a peer is removed", () => {
    const peerHex = "6666666666666666";
    const storage = new FakeStorage();
    const room = makeRelayRoom(storage);
    const ws = {} as WebSocket;
    const infoSpy = vi.spyOn(console, "info").mockImplementation(() => {});

    (room as unknown as {
      peers: Map<PeerIDHex, WebSocket>;
      wsToPeer: Map<WebSocket, PeerIDHex>;
      removePeer(ws: WebSocket): void;
    }).peers.set(peerHex, ws);
    (room as unknown as {
      peers: Map<PeerIDHex, WebSocket>;
      wsToPeer: Map<WebSocket, PeerIDHex>;
      removePeer(ws: WebSocket): void;
    }).wsToPeer.set(ws, peerHex);

    (room as unknown as {
      removePeer(ws: WebSocket): void;
    }).removePeer(ws);

    expect(infoSpy).toHaveBeenCalledWith(
      `[relay] peer ${peerHex} removed (0 peers remaining)`
    );
    infoSpy.mockRestore();
  });
});

describe("Multiple concurrent connections", () => {
  it("routes between 4 peers simultaneously", async () => {
    const keys = Array.from({ length: 4 }, () => randomPublicKey());
    const peerIds = await Promise.all(keys.map((k) => derivePeerIdBytes(k)));
    const sockets = await Promise.all(keys.map((k) => connectPeer(k)));

    await new Promise((r) => setTimeout(r, 50));

    const messages: ArrayBuffer[][] = keys.map(() => []);
    sockets.forEach((ws, i) => {
      ws.addEventListener("message", (event: MessageEvent) => {
        if (event.data instanceof ArrayBuffer) {
          messages[i].push(event.data);
        }
      });
    });

    // Peer 0 -> Peer 2
    const p02 = buildPacket({
      senderPeerId: peerIds[0],
      recipientPeerId: peerIds[2],
      payload: new Uint8Array([0x00, 0x02]),
    });
    sockets[0].send(p02.buffer);

    // Peer 1 -> Peer 3
    const p13 = buildPacket({
      senderPeerId: peerIds[1],
      recipientPeerId: peerIds[3],
      payload: new Uint8Array([0x01, 0x03]),
    });
    sockets[1].send(p13.buffer);

    // Peer 3 -> Peer 0
    const p30 = buildPacket({
      senderPeerId: peerIds[3],
      recipientPeerId: peerIds[0],
      payload: new Uint8Array([0x03, 0x00]),
    });
    sockets[3].send(p30.buffer);

    await new Promise((r) => setTimeout(r, 150));

    expect(messages[0].length).toBe(1);
    expect(new Uint8Array(messages[0][0])).toEqual(p30);
    expect(messages[1].length).toBe(0);
    expect(messages[2].length).toBe(1);
    expect(new Uint8Array(messages[2][0])).toEqual(p02);
    expect(messages[3].length).toBe(1);
    expect(new Uint8Array(messages[3][0])).toEqual(p13);
  });
});

describe("Legacy auth guardrail", () => {
  it("rejects base64 public key auth when ALLOW_LEGACY_AUTH is unset", async () => {
    const previous = (env as Record<string, unknown>).ALLOW_LEGACY_AUTH;
    delete (env as Record<string, unknown>).ALLOW_LEGACY_AUTH;
    try {
      const key = randomPublicKey();
      const req = new Request("https://relay.heyblip.au/ws", {
        headers: {
          Upgrade: "websocket",
          Authorization: `Bearer ${toBase64(key)}`,
        },
      });
      const ctx = createExecutionContext();
      const res = await worker.fetch(req, env, ctx);
      await waitOnExecutionContext(ctx);
      expect(res.status).toBe(401);
      expect(await res.text()).toBe("Legacy auth disabled");
    } finally {
      if (previous !== undefined) {
        (env as Record<string, unknown>).ALLOW_LEGACY_AUTH = previous;
      }
    }
  });

  it("accepts a valid JWT even when ALLOW_LEGACY_AUTH is unset", async () => {
    const previous = (env as Record<string, unknown>).ALLOW_LEGACY_AUTH;
    delete (env as Record<string, unknown>).ALLOW_LEGACY_AUTH;
    try {
      const publicKey = randomPublicKey();
      const peerIdHex = await derivePeerIdHex(publicKey);
      const nowSeconds = Math.floor(Date.now() / 1000);
      const token = await signJWT(
        {
          sub: peerIdHex,
          npk: toBase64(publicKey),
          iat: nowSeconds,
          exp: nowSeconds + 3600,
        },
        "relay-test-secret"
      );

      const auth = await validateAuthorizationHeader(`Bearer ${token}`, env);
      expect(auth.peerIdHex).toBe(peerIdHex);
      expect(auth.source).toBe("jwt");
    } finally {
      if (previous !== undefined) {
        (env as Record<string, unknown>).ALLOW_LEGACY_AUTH = previous;
      }
    }
  });
});

describe("Echo suppression (by PeerID, not by WebSocket identity)", () => {
  // Regression: when a sender rapidly disconnects and reconnects mid-broadcast
  // loop, the peer map's WebSocket for that PeerID changes. Comparing
  // `peerWs === senderWs` would then fail to suppress the echo and deliver
  // the sender's own packet back to its new connection. Keying suppression
  // by the packet's sender PeerID hex fixes that.
  it("does not echo a broadcast back to a reconnected sender", () => {
    const senderPeerHex = "cafebabe01020304";
    const otherPeerHex = "0102030405060708";
    const storage = new FakeStorage();
    const room = makeRelayRoom(storage);

    const reconnectedSenderSend = vi.fn<(payload: ArrayBuffer) => void>();
    const reconnectedSenderWs = { send: reconnectedSenderSend } as unknown as WebSocket;
    const otherSend = vi.fn<(payload: ArrayBuffer) => void>();
    const otherWs = { send: otherSend } as unknown as WebSocket;

    // The ORIGINAL sender socket the broadcast came from. The peer has since
    // reconnected with a different socket, so this one is not in `peers`.
    const originalSenderWs = {} as WebSocket;

    const packet = buildPacket({ senderPeerId: hexToPeerID(senderPeerHex) });

    (room as unknown as {
      peers: Map<PeerIDHex, WebSocket>;
      wsToPeer: Map<WebSocket, PeerIDHex>;
      handleMessage(senderWs: WebSocket, event: MessageEvent): void;
    }).peers.set(senderPeerHex, reconnectedSenderWs);
    (room as unknown as {
      peers: Map<PeerIDHex, WebSocket>;
      wsToPeer: Map<WebSocket, PeerIDHex>;
      handleMessage(senderWs: WebSocket, event: MessageEvent): void;
    }).peers.set(otherPeerHex, otherWs);
    (room as unknown as {
      peers: Map<PeerIDHex, WebSocket>;
      wsToPeer: Map<WebSocket, PeerIDHex>;
      handleMessage(senderWs: WebSocket, event: MessageEvent): void;
    }).wsToPeer.set(originalSenderWs, senderPeerHex);

    (room as unknown as {
      handleMessage(senderWs: WebSocket, event: MessageEvent): void;
    }).handleMessage(originalSenderWs, { data: packet.buffer } as MessageEvent);

    // Other peer receives the broadcast — but the reconnected sender does NOT.
    expect(otherSend).toHaveBeenCalledTimes(1);
    expect(reconnectedSenderSend).not.toHaveBeenCalled();
  });

  it("delivers broadcasts to every peer except the sender by PeerID", () => {
    const senderPeerHex = "aaaaaaaaaaaaaaaa";
    const peerBHex = "bbbbbbbbbbbbbbbb";
    const peerCHex = "cccccccccccccccc";
    const storage = new FakeStorage();
    const room = makeRelayRoom(storage);

    const senderSend = vi.fn<(payload: ArrayBuffer) => void>();
    const senderWs = { send: senderSend } as unknown as WebSocket;
    const bSend = vi.fn<(payload: ArrayBuffer) => void>();
    const bWs = { send: bSend } as unknown as WebSocket;
    const cSend = vi.fn<(payload: ArrayBuffer) => void>();
    const cWs = { send: cSend } as unknown as WebSocket;

    const packet = buildPacket({ senderPeerId: hexToPeerID(senderPeerHex) });

    (room as unknown as {
      peers: Map<PeerIDHex, WebSocket>;
      wsToPeer: Map<WebSocket, PeerIDHex>;
      handleMessage(senderWs: WebSocket, event: MessageEvent): void;
    }).peers.set(senderPeerHex, senderWs);
    (room as unknown as {
      peers: Map<PeerIDHex, WebSocket>;
    }).peers.set(peerBHex, bWs);
    (room as unknown as {
      peers: Map<PeerIDHex, WebSocket>;
    }).peers.set(peerCHex, cWs);
    (room as unknown as {
      wsToPeer: Map<WebSocket, PeerIDHex>;
    }).wsToPeer.set(senderWs, senderPeerHex);

    (room as unknown as {
      handleMessage(senderWs: WebSocket, event: MessageEvent): void;
    }).handleMessage(senderWs, { data: packet.buffer } as MessageEvent);

    expect(senderSend).not.toHaveBeenCalled();
    expect(bSend).toHaveBeenCalledTimes(1);
    expect(cSend).toHaveBeenCalledTimes(1);
  });
});

describe("Undersized packet guard", () => {
  it("drops 16-byte frames before sender-ID extraction", async () => {
    // A 16-byte frame satisfies the old `HEADER_SIZE` check but doesn't
    // contain a full sender PeerID (bytes 16..23). The hardened guard now
    // rejects anything smaller than MIN_PACKET_SIZE (header + sender).
    const keyA = randomPublicKey();
    const keyB = randomPublicKey();

    const wsA = await connectPeer(keyA);
    const wsB = await connectPeer(keyB);
    const messagesB = collectBinaryMessages(wsB);

    await new Promise((r) => setTimeout(r, 50));

    const headerOnly = new Uint8Array(16);
    wsA.send(headerOnly.buffer);
    await new Promise((r) => setTimeout(r, 100));

    expect(messagesB.length).toBe(0);
  });
});

describe("Packet size validation", () => {
  it("drops oversized packets (> 512 bytes)", async () => {
    const keyA = randomPublicKey();
    const keyB = randomPublicKey();
    const peerIdA = await derivePeerIdBytes(keyA);
    const peerIdB = await derivePeerIdBytes(keyB);

    const wsA = await connectPeer(keyA);
    const wsB = await connectPeer(keyB);
    const messagesB = collectBinaryMessages(wsB);

    await new Promise((r) => setTimeout(r, 50));

    // Build an oversized packet (600-byte payload → well over 512 total).
    const oversized = buildPacket({
      senderPeerId: peerIdA,
      recipientPeerId: peerIdB,
      payload: new Uint8Array(600),
    });

    wsA.send(oversized.buffer);
    await new Promise((r) => setTimeout(r, 100));

    // Peer B should NOT have received the oversized packet.
    expect(messagesB.length).toBe(0);
  });

  it("drops undersized packets (< 16 bytes)", async () => {
    const keyA = randomPublicKey();
    const keyB = randomPublicKey();
    const peerIdB = await derivePeerIdBytes(keyB);

    const wsA = await connectPeer(keyA);
    const wsB = await connectPeer(keyB);
    const messagesB = collectBinaryMessages(wsB);

    await new Promise((r) => setTimeout(r, 50));

    // Send a tiny packet (only 10 bytes).
    const tiny = new Uint8Array(10);
    wsA.send(tiny.buffer);
    await new Promise((r) => setTimeout(r, 100));

    expect(messagesB.length).toBe(0);
  });
});

// --- Push dispatch integration (HEY-1321) ---

/** Build a packet of a specific BlipProtocol MessageType. */
function buildTypedPacket(opts: {
  type: number;
  senderPeerId: Uint8Array;
  recipientPeerId: Uint8Array;
  payload?: Uint8Array;
}): Uint8Array {
  const payload = opts.payload ?? new Uint8Array([0xAA]);
  const size =
    HEADER_SIZE +
    PEER_ID_LENGTH + // sender
    PEER_ID_LENGTH + // recipient
    payload.length;
  const buf = new Uint8Array(size);
  const view = new DataView(buf.buffer);
  buf[0] = 0x01; // version
  buf[1] = opts.type; // TYPE byte — this is what push-dispatch reads
  buf[2] = 3; // ttl
  view.setBigUint64(3, BigInt(Date.now()), false);
  buf[OFFSET_FLAGS] = FLAG_HAS_RECIPIENT;
  view.setUint32(12, payload.length, false);
  buf.set(opts.senderPeerId, OFFSET_SENDER_ID);
  buf.set(opts.recipientPeerId, OFFSET_RECIPIENT_ID);
  buf.set(payload, OFFSET_RECIPIENT_ID + PEER_ID_LENGTH);
  return buf;
}

describe("Push dispatch in queuePacket / drainQueue", () => {
  beforeEach(() => {
    vi.useFakeTimers();
  });

  afterEach(() => {
    vi.useRealTimers();
    vi.restoreAllMocks();
  });

  it("queuePacket schedules push after 500ms delay and includes bumped badge count", async () => {
    const senderHex = "aaaaaaaaaaaaaaaa";
    const recipientHex = "bbbbbbbbbbbbbbbb";
    const storage = new FakeStorage();
    const room = makeRelayRoom(storage);

    const fetchSpy = vi
      .spyOn(globalThis, "fetch")
      .mockResolvedValue(new Response("ok", { status: 200 }));

    const packet = buildTypedPacket({
      type: 0x11, // noiseEncrypted → "dm"
      senderPeerId: hexToPeerID(senderHex),
      recipientPeerId: hexToPeerID(recipientHex),
    });

    await (room as unknown as {
      queuePacket(recipientHex: string, data: Uint8Array): Promise<void>;
    }).queuePacket(recipientHex, packet);

    // Let the microtask queue drain so enqueuePush completes (bump + schedule).
    await vi.advanceTimersByTimeAsync(10);
    expect(fetchSpy).not.toHaveBeenCalled();

    // Advance past the 500ms schedule window → push fires.
    await vi.advanceTimersByTimeAsync(600);
    expect(fetchSpy).toHaveBeenCalledTimes(1);

    const body = JSON.parse(fetchSpy.mock.calls[0][1]?.body as string);
    expect(body.recipientPeerIdHex).toBe(recipientHex);
    expect(body.senderPeerIdHex).toBe(senderHex);
    expect(body.type).toBe("dm");
    expect(body.threadId).toBe("AAAAAAAA-AAAA-AAAA-0000-000000000000"); // BDEV-441: synthetic UUID from senderHex
    expect(body.badgeCount).toBe(1);
  });

  it("does not push for fragment / meshBroadcast / announce / syncRequest / locationShare", async () => {
    const senderHex = "0000aaaa11112222";
    const recipientHex = "3333444455556666";
    const storage = new FakeStorage();
    const room = makeRelayRoom(storage);

    const fetchSpy = vi
      .spyOn(globalThis, "fetch")
      .mockResolvedValue(new Response("ok", { status: 200 }));

    // 0x10 (noiseHandshake) is intentionally absent — see the next test.
    // It now triggers silent_badge_sync so the offline recipient wakes up
    // to complete the handshake. (BDEV-411.)
    for (const type of [0x20, 0x02, 0x01, 0x21, 0x50]) {
      const packet = buildTypedPacket({
        type,
        senderPeerId: hexToPeerID(senderHex),
        recipientPeerId: hexToPeerID(recipientHex),
      });
      await (room as unknown as {
        queuePacket(recipientHex: string, data: Uint8Array): Promise<void>;
      }).queuePacket(recipientHex, packet);
    }
    await vi.advanceTimersByTimeAsync(1_000);
    expect(fetchSpy).not.toHaveBeenCalled();
  });

  it("pushes silent_badge_sync for noiseHandshake to wake offline recipient (BDEV-411)", async () => {
    const senderHex = "0000aaaa11112222";
    const recipientHex = "3333444455556666";
    const storage = new FakeStorage();
    const room = makeRelayRoom(storage);

    const fetchSpy = vi
      .spyOn(globalThis, "fetch")
      .mockResolvedValue(new Response("ok", { status: 200 }));

    const packet = buildTypedPacket({
      type: 0x10, // PACKET_TYPE_NOISE_HANDSHAKE
      senderPeerId: hexToPeerID(senderHex),
      recipientPeerId: hexToPeerID(recipientHex),
    });
    await (room as unknown as {
      queuePacket(recipientHex: string, data: Uint8Array): Promise<void>;
    }).queuePacket(recipientHex, packet);

    // Drain the schedule window so the dispatcher fires.
    await vi.advanceTimersByTimeAsync(600);
    expect(fetchSpy).toHaveBeenCalledTimes(1);

    const body = JSON.parse(fetchSpy.mock.calls[0][1]?.body as string);
    expect(body.recipientPeerIdHex).toBe(recipientHex);
    expect(body.type).toBe("silent_badge_sync");
  });

  it("drainQueue within 500ms cancels the scheduled push (drained_fast)", async () => {
    const senderHex = "cafe000000000001";
    const recipientHex = "beef000000000002";
    const storage = new FakeStorage();
    const room = makeRelayRoom(storage);

    const fetchSpy = vi
      .spyOn(globalThis, "fetch")
      .mockResolvedValue(new Response("ok", { status: 200 }));
    const logSpy = vi.spyOn(console, "log").mockImplementation(() => {});

    const packet = buildTypedPacket({
      type: 0x11,
      senderPeerId: hexToPeerID(senderHex),
      recipientPeerId: hexToPeerID(recipientHex),
    });

    await (room as unknown as {
      queuePacket(recipientHex: string, data: Uint8Array): Promise<void>;
    }).queuePacket(recipientHex, packet);
    await vi.advanceTimersByTimeAsync(10);

    // Recipient "reconnects" immediately — drain the queue.
    const sendSpy = vi.fn();
    const ws = { send: sendSpy } as unknown as WebSocket;
    (room as unknown as { peers: Map<string, WebSocket> }).peers.set(recipientHex, ws);
    await (room as unknown as {
      drainQueue(peerHex: string, ws: WebSocket): Promise<void>;
    }).drainQueue(recipientHex, ws);

    // Advance past the 500ms window — push MUST NOT fire.
    await vi.advanceTimersByTimeAsync(1_000);
    expect(fetchSpy).not.toHaveBeenCalled();
    expect(sendSpy).toHaveBeenCalledTimes(1);

    const drainedFastLogs = logSpy.mock.calls.filter(
      ([arg]) => typeof arg === "string" && arg.includes('"reason":"drained_fast"')
    );
    expect(drainedFastLogs.length).toBeGreaterThanOrEqual(1);
  });

  it("SOS bypasses cooldown even if a recent DM push was fired to the same peer", async () => {
    const senderHex = "a1a1a1a1a1a1a1a1";
    const recipientHex = "b2b2b2b2b2b2b2b2";
    const storage = new FakeStorage();
    const room = makeRelayRoom(storage);

    const fetchSpy = vi
      .spyOn(globalThis, "fetch")
      .mockResolvedValue(new Response("ok", { status: 200 }));

    // First: a DM push lands successfully.
    const dmPacket = buildTypedPacket({
      type: 0x11,
      senderPeerId: hexToPeerID(senderHex),
      recipientPeerId: hexToPeerID(recipientHex),
    });
    await (room as unknown as {
      queuePacket(recipientHex: string, data: Uint8Array): Promise<void>;
    }).queuePacket(recipientHex, dmPacket);
    await vi.advanceTimersByTimeAsync(600);
    expect(fetchSpy).toHaveBeenCalledTimes(1);

    // Seconds later — an SOS from the same sender. Within the 30s DM cooldown
    // window, but SOS must bypass.
    const sosPacket = buildTypedPacket({
      type: 0x40,
      senderPeerId: hexToPeerID(senderHex),
      recipientPeerId: hexToPeerID(recipientHex),
    });
    await (room as unknown as {
      queuePacket(recipientHex: string, data: Uint8Array): Promise<void>;
    }).queuePacket(recipientHex, sosPacket);
    await vi.advanceTimersByTimeAsync(600);

    expect(fetchSpy).toHaveBeenCalledTimes(2);
    const sosBody = JSON.parse(fetchSpy.mock.calls[1][1]?.body as string);
    expect(sosBody.type).toBe("sos");
  });

  it("cooldown is per-(peer, thread) — different sender → different thread → proceeds", async () => {
    const recipientHex = "c3c3c3c3c3c3c3c3";
    const sender1 = "1111111111111111";
    const sender2 = "2222222222222222";
    const storage = new FakeStorage();
    const room = makeRelayRoom(storage);

    const fetchSpy = vi
      .spyOn(globalThis, "fetch")
      .mockResolvedValue(new Response("ok", { status: 200 }));

    const p1 = buildTypedPacket({
      type: 0x11,
      senderPeerId: hexToPeerID(sender1),
      recipientPeerId: hexToPeerID(recipientHex),
    });
    const p2 = buildTypedPacket({
      type: 0x11,
      senderPeerId: hexToPeerID(sender2),
      recipientPeerId: hexToPeerID(recipientHex),
    });

    await (room as unknown as {
      queuePacket(recipientHex: string, data: Uint8Array): Promise<void>;
    }).queuePacket(recipientHex, p1);
    await vi.advanceTimersByTimeAsync(600);

    await (room as unknown as {
      queuePacket(recipientHex: string, data: Uint8Array): Promise<void>;
    }).queuePacket(recipientHex, p2);
    await vi.advanceTimersByTimeAsync(600);

    expect(fetchSpy).toHaveBeenCalledTimes(2);

    // Second push for sender1 within 30s — should be suppressed by cooldown.
    const p1b = buildTypedPacket({
      type: 0x11,
      senderPeerId: hexToPeerID(sender1),
      recipientPeerId: hexToPeerID(recipientHex),
    });
    await (room as unknown as {
      queuePacket(recipientHex: string, data: Uint8Array): Promise<void>;
    }).queuePacket(recipientHex, p1b);
    await vi.advanceTimersByTimeAsync(600);
    expect(fetchSpy).toHaveBeenCalledTimes(2); // no new fetch
  });

  it("badge count increments across multiple pushable packets", async () => {
    const senderHex = "d4d4d4d4d4d4d4d4";
    const recipientHex = "e5e5e5e5e5e5e5e5";
    const storage = new FakeStorage();
    const room = makeRelayRoom(storage);

    vi.spyOn(globalThis, "fetch")
      .mockResolvedValue(new Response("ok", { status: 200 }));

    // Queue three DM packets — each bump should increment the ledger total
    // even if the push itself is suppressed by cooldown.
    for (let i = 0; i < 3; i++) {
      const packet = buildTypedPacket({
        type: 0x11,
        senderPeerId: hexToPeerID(senderHex),
        recipientPeerId: hexToPeerID(recipientHex),
      });
      await (room as unknown as {
        queuePacket(recipientHex: string, data: Uint8Array): Promise<void>;
      }).queuePacket(recipientHex, packet);
      // Give enqueuePush's microtasks time to run.
      await vi.advanceTimersByTimeAsync(10);
    }

    const row = await storage.get<{ total: number }>(`unread:${recipientHex}`);
    expect(row?.total).toBe(3);
  });

  it("auth callout failure does not break packet queuing", async () => {
    const senderHex = "f6f6f6f6f6f6f6f6";
    const recipientHex = "f7f7f7f7f7f7f7f7";
    const storage = new FakeStorage();
    const room = makeRelayRoom(storage);

    vi.spyOn(globalThis, "fetch").mockRejectedValue(new Error("auth worker down"));

    const packet = buildTypedPacket({
      type: 0x11,
      senderPeerId: hexToPeerID(senderHex),
      recipientPeerId: hexToPeerID(recipientHex),
    });

    await expect(
      (room as unknown as {
        queuePacket(recipientHex: string, data: Uint8Array): Promise<void>;
      }).queuePacket(recipientHex, packet)
    ).resolves.toBeUndefined();

    await vi.advanceTimersByTimeAsync(1_000);

    // Packet was still queued in storage, even though push failed.
    expect(storage.keys().some((k) => k.startsWith(`q:${recipientHex}:`))).toBe(true);
  });
});

describe("Silent badge sync on reconnect", () => {
  beforeEach(() => {
    vi.useFakeTimers();
  });

  afterEach(() => {
    vi.useRealTimers();
    vi.restoreAllMocks();
  });

  it("fires silent_badge_sync when peer reconnects after >5 min AND has queued packets", async () => {
    const peerHex = "7a7a7a7a7a7a7a7a";
    const storage = new FakeStorage();
    const room = makeRelayRoom(storage);

    const fetchSpy = vi
      .spyOn(globalThis, "fetch")
      .mockResolvedValue(new Response("ok", { status: 200 }));

    // Seed a queued packet + a non-zero badge so the sync has something to wake.
    storage.seed([
      [`q:${peerHex}:0001:a`, { data: [0x01, 0x02], storedAt: Date.now() }],
      [`unread:${peerHex}`, { total: 5, byThread: { "x": 5 }, updatedAt: Date.now() }],
    ]);

    // Simulate peer was last seen 6 minutes ago.
    (room as unknown as {
      lastDisconnectedAt: Map<string, number>;
    }).lastDisconnectedAt.set(peerHex, Date.now() - 6 * 60_000);

    (room as unknown as {
      maybeFireReconnectSilentSync(peerIdHex: string): void;
    }).maybeFireReconnectSilentSync(peerHex);

    // The work is deferred via a microtask chain — let it settle.
    await vi.advanceTimersByTimeAsync(50);

    expect(fetchSpy).toHaveBeenCalledTimes(1);
    const body = JSON.parse(fetchSpy.mock.calls[0][1]?.body as string);
    expect(body.type).toBe("silent_badge_sync");
    expect(body.senderPeerIdHex).toBeNull();
    expect(body.badgeCount).toBe(5);
  });

  it("does NOT fire silent_badge_sync if peer was offline < 5 min", async () => {
    const peerHex = "8b8b8b8b8b8b8b8b";
    const storage = new FakeStorage();
    const room = makeRelayRoom(storage);

    const fetchSpy = vi
      .spyOn(globalThis, "fetch")
      .mockResolvedValue(new Response("ok", { status: 200 }));

    storage.seed([
      [`unread:${peerHex}`, { total: 3, byThread: { "x": 3 }, updatedAt: Date.now() }],
    ]);

    // 2 minutes — below the 5-minute threshold.
    (room as unknown as {
      lastDisconnectedAt: Map<string, number>;
    }).lastDisconnectedAt.set(peerHex, Date.now() - 2 * 60_000);

    (room as unknown as {
      maybeFireReconnectSilentSync(peerIdHex: string): void;
    }).maybeFireReconnectSilentSync(peerHex);

    await vi.advanceTimersByTimeAsync(50);
    expect(fetchSpy).not.toHaveBeenCalled();
  });

  it("does NOT fire silent_badge_sync if nothing is queued AND badge is zero", async () => {
    const peerHex = "9c9c9c9c9c9c9c9c";
    const storage = new FakeStorage();
    const room = makeRelayRoom(storage);

    const fetchSpy = vi
      .spyOn(globalThis, "fetch")
      .mockResolvedValue(new Response("ok", { status: 200 }));

    // No queued packets, no unread row. First-ever reconnect (offlineFor = Infinity).
    (room as unknown as {
      maybeFireReconnectSilentSync(peerIdHex: string): void;
    }).maybeFireReconnectSilentSync(peerHex);

    await vi.advanceTimersByTimeAsync(50);
    expect(fetchSpy).not.toHaveBeenCalled();
  });
});

describe("/internal/badge/clear", () => {
  beforeEach(() => {
    vi.useFakeTimers();
  });

  afterEach(() => {
    vi.useRealTimers();
    vi.restoreAllMocks();
  });

  it("wipes the ledger with all=true and returns 0", async () => {
    const peerHex = "aabbccddeeff0011";
    const storage = new FakeStorage();
    const room = makeRelayRoom(storage);

    // Seed an unread row for the peer and mark the peer as connected so the
    // "multi-device fanout" branch triggers a silent_badge_sync.
    storage.seed([
      [`unread:${peerHex}`, { total: 7, byThread: { "x": 7 }, updatedAt: Date.now() }],
    ]);
    const ws = { send: vi.fn() } as unknown as WebSocket;
    (room as unknown as { peers: Map<string, WebSocket> }).peers.set(peerHex, ws);

    const fetchSpy = vi
      .spyOn(globalThis, "fetch")
      .mockResolvedValue(new Response("ok", { status: 200 }));

    const req = new Request("https://relay.heyblip.au/internal/badge/clear", {
      method: "POST",
      headers: {
        "X-Derived-Peer-ID": peerHex,
        "X-State-Action": "badge-clear",
        "X-Internal-Key": "test-key",
        "Content-Type": "application/json",
      },
      body: JSON.stringify({ all: true }),
    });
    const res = await room.fetch(req);

    expect(res.status).toBe(200);
    const body = await res.json() as { cleared: boolean; badgeCount: number };
    expect(body).toEqual({ cleared: true, badgeCount: 0 });

    // Row was wiped.
    expect(storage.has(`unread:${peerHex}`)).toBe(false);

    // Silent sync to multi-device fanout was dispatched.
    await vi.advanceTimersByTimeAsync(10);
    expect(fetchSpy).toHaveBeenCalledTimes(1);
    const pushBody = JSON.parse(fetchSpy.mock.calls[0][1]?.body as string);
    expect(pushBody.type).toBe("silent_badge_sync");
    expect(pushBody.badgeCount).toBe(0);
  });

  it("clears by threadId and leaves other threads intact", async () => {
    const peerHex = "112233445566aabb";
    const storage = new FakeStorage();
    const room = makeRelayRoom(storage);

    storage.seed([
      [`unread:${peerHex}`, {
        total: 5,
        byThread: { "thread-a": 2, "thread-b": 3 },
        updatedAt: Date.now(),
      }],
    ]);

    const req = new Request("https://relay.heyblip.au/internal/badge/clear", {
      method: "POST",
      headers: {
        "X-Derived-Peer-ID": peerHex,
        "X-State-Action": "badge-clear",
        "X-Internal-Key": "test-key",
        "Content-Type": "application/json",
      },
      body: JSON.stringify({ threadId: "thread-a" }),
    });
    const res = await room.fetch(req);
    expect(res.status).toBe(200);
    const body = await res.json() as { cleared: boolean; badgeCount: number };
    expect(body.badgeCount).toBe(3);

    const row = await storage.get<{ total: number; byThread: Record<string, number> }>(
      `unread:${peerHex}`
    );
    expect(row?.total).toBe(3);
    expect(row?.byThread).toEqual({ "thread-b": 3 });
  });

  it("rejects missing X-Internal-Key via the top-level worker route", async () => {
    const ctx = createExecutionContext();
    const res = await worker.fetch(
      new Request("https://relay.heyblip.au/internal/badge/clear", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ peerIdHex: "deadbeefcafebabe", all: true }),
      }),
      env,
      ctx
    );
    await waitOnExecutionContext(ctx);
    expect(res.status).toBe(401);
  });

  it("rejects mismatched X-Internal-Key", async () => {
    const ctx = createExecutionContext();
    (env as Record<string, unknown>).INTERNAL_API_KEY = "correct-key";
    try {
      const res = await worker.fetch(
        new Request("https://relay.heyblip.au/internal/badge/clear", {
          method: "POST",
          headers: {
            "Content-Type": "application/json",
            "X-Internal-Key": "wrong-key",
          },
          body: JSON.stringify({ peerIdHex: "deadbeefcafebabe", all: true }),
        }),
        env,
        ctx
      );
      await waitOnExecutionContext(ctx);
      expect(res.status).toBe(401);
    } finally {
      delete (env as Record<string, unknown>).INTERNAL_API_KEY;
    }
  });

  it("rejects body missing both threadId and all", async () => {
    const peerHex = "ccddccddccddccdd";
    const storage = new FakeStorage();
    const room = makeRelayRoom(storage);

    const req = new Request("https://relay.heyblip.au/internal/badge/clear", {
      method: "POST",
      headers: {
        "X-Derived-Peer-ID": peerHex,
        "X-State-Action": "badge-clear",
        "X-Internal-Key": "test-key",
        "Content-Type": "application/json",
      },
      body: JSON.stringify({}),
    });
    const res = await room.fetch(req);
    expect(res.status).toBe(400);
  });
});

// BDEV-441: blip.threadId must be a valid UUID string for iOS NotificationRouter
describe("hexToSyntheticUUID", () => {
  it("formats a 16-char PeerID hex as a UUID with trailing zeros", () => {
    const result = hexToSyntheticUUID("deadbeefcafebabe");
    expect(result).toBe("DEADBEEF-CAFE-BABE-0000-000000000000");
  });

  it("produces a string parseable by UUID(uuidString:) — correct format", () => {
    const uuid = hexToSyntheticUUID("a1b2c3d4e5f60708");
    // Must match UUID regex: 8-4-4-4-12 uppercase hex groups separated by dashes
    expect(uuid).toMatch(/^[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}$/);
  });

  it("is stable — same input always produces the same UUID", () => {
    const hex = "be90abcd12345678";
    expect(hexToSyntheticUUID(hex)).toBe(hexToSyntheticUUID(hex));
  });

  it("is reversible — first 16 chars of stripped UUID equal the original hex", () => {
    const senderHex = "deadbeefcafebabe";
    const uuid = hexToSyntheticUUID(senderHex);
    const stripped = uuid.replace(/-/g, "").toLowerCase().slice(0, 16);
    expect(stripped).toBe(senderHex);
  });

  it("DM push payload threadId is a valid UUID (regression: was bare PeerID hex)", async () => {
    // The relay sends threadId = hexToSyntheticUUID(senderHex) for dm pushes.
    // Verify the resulting string parses as a UUID — iOS UUID(uuidString:) rejects
    // bare 16-char hex like "a1b2c3d4e5f60708", which caused BDEV-441 routing failure.
    const senderHex = "a1b2c3d4e5f60708";
    const threadId = hexToSyntheticUUID(senderHex);

    // iOS UUID(uuidString:) accepts exactly this format: 8-4-4-4-12
    const uuidPattern = /^[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}$/;
    expect(threadId).toMatch(uuidPattern);

    // And iOS recovers senderHex from the UUID by stripping dashes and taking first 16 chars
    const recovered = threadId.replace(/-/g, "").toLowerCase().slice(0, 16);
    expect(recovered).toBe(senderHex);
  });
});
