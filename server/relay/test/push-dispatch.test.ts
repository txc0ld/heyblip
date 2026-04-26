import { describe, it, expect, beforeEach, afterEach, vi } from "vitest";
import {
  PushDispatcher,
  packetTypeToPushType,
  PACKET_TYPE_ANNOUNCE,
  PACKET_TYPE_MESH_BROADCAST,
  PACKET_TYPE_NOISE_HANDSHAKE,
  PACKET_TYPE_NOISE_ENCRYPTED,
  PACKET_TYPE_FRAGMENT,
  PACKET_TYPE_SYNC_REQUEST,
  PACKET_TYPE_SOS_ALERT,
  PACKET_TYPE_LOCATION_SHARE,
  PACKET_TYPE_FRIEND_REQUEST,
  PACKET_TYPE_FRIEND_ACCEPT,
} from "../src/push-dispatch";
import type { Env } from "../src/types";

function makeEnv(): Env {
  return {
    INTERNAL_API_KEY: "test-key",
    AUTH_PUSH_URL: "https://auth.example/v1/internal/push",
  } as unknown as Env;
}

describe("packetTypeToPushType", () => {
  it("maps noiseEncrypted (0x11) → dm (zero-knowledge coarse tag)", () => {
    expect(packetTypeToPushType(PACKET_TYPE_NOISE_ENCRYPTED)).toBe("dm");
  });

  it("maps sosAlert (0x40) → sos", () => {
    expect(packetTypeToPushType(PACKET_TYPE_SOS_ALERT)).toBe("sos");
  });

  it("maps friendRequest (0x60) → friend_request", () => {
    expect(packetTypeToPushType(PACKET_TYPE_FRIEND_REQUEST)).toBe("friend_request");
  });

  it("maps friendAccept (0x61) → friend_accept", () => {
    expect(packetTypeToPushType(PACKET_TYPE_FRIEND_ACCEPT)).toBe("friend_accept");
  });

  it("maps noiseHandshake (0x10) → silent_badge_sync (BDEV-411)", () => {
    // Noise handshake msgs MUST trigger a silent push so the offline recipient
    // wakes up to complete the handshake. Without this, the first DM between
    // newly-accepted friends stalls indefinitely.
    expect(packetTypeToPushType(PACKET_TYPE_NOISE_HANDSHAKE)).toBe("silent_badge_sync");
  });

  it("returns null for fragment (reassembled packet triggers push)", () => {
    expect(packetTypeToPushType(PACKET_TYPE_FRAGMENT)).toBeNull();
  });

  it("returns null for syncRequest", () => {
    expect(packetTypeToPushType(PACKET_TYPE_SYNC_REQUEST)).toBeNull();
  });

  it("returns null for meshBroadcast", () => {
    expect(packetTypeToPushType(PACKET_TYPE_MESH_BROADCAST)).toBeNull();
  });

  it("returns null for announce", () => {
    expect(packetTypeToPushType(PACKET_TYPE_ANNOUNCE)).toBeNull();
  });

  it("returns null for locationShare", () => {
    expect(packetTypeToPushType(PACKET_TYPE_LOCATION_SHARE)).toBeNull();
  });

  it("returns null for unknown/reserved bytes", () => {
    expect(packetTypeToPushType(0xff)).toBeNull();
    expect(packetTypeToPushType(0x00)).toBeNull();
    expect(packetTypeToPushType(0x77)).toBeNull();
  });
});

describe("PushDispatcher.shouldPush", () => {
  let dispatcher: PushDispatcher;
  const now = 1_700_000_000_000;

  beforeEach(() => {
    dispatcher = new PushDispatcher(makeEnv(), "https://auth.example/v1/internal/push");
  });

  it("proceeds on first push for a (peer, thread)", () => {
    expect(dispatcher.shouldPush("peer1", "thread-a", "dm", now)).toBe("proceed");
  });

  it("enters cooldown within 30s for same (peer, thread)", () => {
    dispatcher.markPushed("peer1", "thread-a", "dm", now);
    expect(dispatcher.shouldPush("peer1", "thread-a", "dm", now + 10_000)).toBe("cooldown");
    expect(dispatcher.shouldPush("peer1", "thread-a", "dm", now + 29_999)).toBe("cooldown");
  });

  it("proceeds for same peer on a DIFFERENT thread inside the window", () => {
    dispatcher.markPushed("peer1", "thread-a", "dm", now);
    expect(dispatcher.shouldPush("peer1", "thread-b", "dm", now + 5_000)).toBe("proceed");
  });

  it("proceeds after the 30s window elapses", () => {
    dispatcher.markPushed("peer1", "thread-a", "dm", now);
    expect(dispatcher.shouldPush("peer1", "thread-a", "dm", now + 30_001)).toBe("proceed");
  });

  it("SOS bypasses cooldown entirely (even mid-window)", () => {
    dispatcher.markPushed("peer1", "thread-a", "sos", now);
    expect(dispatcher.shouldPush("peer1", "thread-a", "sos", now + 100)).toBe("proceed");
    expect(dispatcher.shouldPush("peer1", "thread-a", "sos", now + 15_000)).toBe("proceed");
  });

  it("silent_badge_sync uses its own 60s window (not the DM cooldown)", () => {
    dispatcher.markPushed("peer1", null, "silent_badge_sync", now);

    // Inside 60s — suppressed.
    expect(dispatcher.shouldPush("peer1", null, "silent_badge_sync", now + 30_000)).toBe("cooldown");
    expect(dispatcher.shouldPush("peer1", null, "silent_badge_sync", now + 59_999)).toBe("cooldown");

    // After 60s — proceeds.
    expect(dispatcher.shouldPush("peer1", null, "silent_badge_sync", now + 60_001)).toBe("proceed");
  });

  it("silent_badge_sync and regular DM cooldowns are independent", () => {
    dispatcher.markPushed("peer1", null, "silent_badge_sync", now);
    // A DM push on any thread is not blocked by a silent sync stamp.
    expect(dispatcher.shouldPush("peer1", "thread-a", "dm", now + 1_000)).toBe("proceed");

    dispatcher.markPushed("peer2", "thread-x", "dm", now);
    // A silent sync is not blocked by a DM stamp.
    expect(dispatcher.shouldPush("peer2", null, "silent_badge_sync", now + 1_000)).toBe("proceed");
  });
});

describe("PushDispatcher.dispatchNow", () => {
  const authUrl = "https://auth.example/v1/internal/push";

  beforeEach(() => {
    vi.restoreAllMocks();
  });

  afterEach(() => {
    vi.restoreAllMocks();
  });

  it("POSTs the locked body to the auth worker with the internal key", async () => {
    const dispatcher = new PushDispatcher(makeEnv(), authUrl);
    const fetchSpy = vi
      .spyOn(globalThis, "fetch")
      .mockResolvedValue(new Response("ok", { status: 200 }));

    await dispatcher.dispatchNow({
      recipientPeerIdHex: "aaaa",
      senderPeerIdHex: "bbbb",
      type: "dm",
      threadId: "bbbb",
      badgeCount: 3,
      traceID: "trace-123",
    });

    expect(fetchSpy).toHaveBeenCalledTimes(1);
    const [url, init] = fetchSpy.mock.calls[0];
    expect(url).toBe(authUrl);
    expect(init?.method).toBe("POST");
    expect((init?.headers as Record<string, string>)["X-Internal-Key"]).toBe("test-key");
    expect((init?.headers as Record<string, string>)["Content-Type"]).toBe("application/json");
    expect((init?.headers as Record<string, string>)["X-Trace-ID"]).toBe("trace-123");
    const body = JSON.parse(init?.body as string);
    expect(body).toEqual({
      recipientPeerIdHex: "aaaa",
      senderPeerIdHex: "bbbb",
      type: "dm",
      threadId: "bbbb",
      badgeCount: 3,
    });
  });

  it("does not throw on auth worker failure (logged + Sentry-captured only)", async () => {
    const dispatcher = new PushDispatcher(makeEnv(), authUrl);
    vi.spyOn(globalThis, "fetch").mockRejectedValue(new Error("network down"));

    await expect(
      dispatcher.dispatchNow({
        recipientPeerIdHex: "aaaa",
        senderPeerIdHex: "bbbb",
        type: "dm",
        threadId: "bbbb",
        badgeCount: 1,
      })
    ).resolves.toBeUndefined();
  });

  it("is suppressed by the cooldown and skips the fetch entirely", async () => {
    const dispatcher = new PushDispatcher(makeEnv(), authUrl);
    const fetchSpy = vi
      .spyOn(globalThis, "fetch")
      .mockResolvedValue(new Response("ok", { status: 200 }));

    await dispatcher.dispatchNow({
      recipientPeerIdHex: "aaaa",
      senderPeerIdHex: "bbbb",
      type: "dm",
      threadId: "bbbb",
      badgeCount: 1,
    });
    // Second call inside cooldown window — suppressed, no fetch.
    await dispatcher.dispatchNow({
      recipientPeerIdHex: "aaaa",
      senderPeerIdHex: "bbbb",
      type: "dm",
      threadId: "bbbb",
      badgeCount: 2,
    });

    expect(fetchSpy).toHaveBeenCalledTimes(1);
  });
});

describe("PushDispatcher.schedulePush + cancelPendingForKey", () => {
  beforeEach(() => {
    vi.useFakeTimers();
  });

  afterEach(() => {
    vi.useRealTimers();
    vi.restoreAllMocks();
  });

  it("schedulePush fires after the delay; cancelPendingForKey suppresses it", async () => {
    const dispatcher = new PushDispatcher(
      makeEnv(),
      "https://auth.example/v1/internal/push"
    );
    const fetchSpy = vi
      .spyOn(globalThis, "fetch")
      .mockResolvedValue(new Response("ok", { status: 200 }));

    dispatcher.schedulePush("queue-key-1", {
      recipientPeerIdHex: "aaaa",
      senderPeerIdHex: "bbbb",
      type: "dm",
      threadId: "bbbb",
      badgeCount: 1,
    }, 500);

    // Cancel before the 500ms timer fires — no fetch should ever occur.
    const cancelled = dispatcher.cancelPendingForKey("queue-key-1");
    expect(cancelled).toBe(true);

    await vi.advanceTimersByTimeAsync(1_000);
    expect(fetchSpy).not.toHaveBeenCalled();
  });

  it("schedulePush fires the fetch if not cancelled in time", async () => {
    const dispatcher = new PushDispatcher(
      makeEnv(),
      "https://auth.example/v1/internal/push"
    );
    const fetchSpy = vi
      .spyOn(globalThis, "fetch")
      .mockResolvedValue(new Response("ok", { status: 200 }));

    dispatcher.schedulePush("queue-key-2", {
      recipientPeerIdHex: "aaaa",
      senderPeerIdHex: "bbbb",
      type: "dm",
      threadId: "bbbb",
      badgeCount: 1,
    }, 500);

    await vi.advanceTimersByTimeAsync(600);
    expect(fetchSpy).toHaveBeenCalledTimes(1);
  });

  it("cancelPendingForKey on unknown key is a no-op", () => {
    const dispatcher = new PushDispatcher(
      makeEnv(),
      "https://auth.example/v1/internal/push"
    );
    expect(dispatcher.cancelPendingForKey("never-scheduled")).toBe(false);
  });

  it("scheduling twice on the same key replaces the previous timer", async () => {
    const dispatcher = new PushDispatcher(
      makeEnv(),
      "https://auth.example/v1/internal/push"
    );
    const fetchSpy = vi
      .spyOn(globalThis, "fetch")
      .mockResolvedValue(new Response("ok", { status: 200 }));

    dispatcher.schedulePush("queue-key-3", {
      recipientPeerIdHex: "aaaa",
      senderPeerIdHex: "bbbb",
      type: "dm",
      threadId: "bbbb",
      badgeCount: 1,
    }, 500);
    dispatcher.schedulePush("queue-key-3", {
      recipientPeerIdHex: "aaaa",
      senderPeerIdHex: "bbbb",
      type: "dm",
      threadId: "bbbb",
      badgeCount: 5, // newer badge count
    }, 500);

    await vi.advanceTimersByTimeAsync(600);
    expect(fetchSpy).toHaveBeenCalledTimes(1);
    const body = JSON.parse(fetchSpy.mock.calls[0][1]?.body as string);
    expect(body.badgeCount).toBe(5);
  });
});
