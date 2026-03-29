import { env, createExecutionContext, waitOnExecutionContext } from "cloudflare:test";
import { describe, it, expect, afterEach } from "vitest";
import worker, { parseAuthHeader, derivePeerIdHex } from "../src/index";
import { extractRecipient } from "../src/relay-room";
import {
  HEADER_SIZE,
  PEER_ID_LENGTH,
  FLAG_HAS_RECIPIENT,
  OFFSET_FLAGS,
  OFFSET_SENDER_ID,
  OFFSET_RECIPIENT_ID,
  bytesToHex,
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

async function derivePeerIdBytes(publicKey: Uint8Array): Promise<Uint8Array> {
  const hash = await crypto.subtle.digest("SHA-256", publicKey);
  return new Uint8Array(hash).slice(0, PEER_ID_LENGTH);
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

  it("does not route broadcast packets", async () => {
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

    expect(messagesB.length).toBe(0);
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
