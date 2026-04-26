import { describe, it, expect } from "vitest";
import { buildPayload, defaultDeeplink } from "../src/apns/payloads";

describe("apns/payloads", () => {
  it("friend_request: passive interruption, 24h expiration, no collapse-id", () => {
    const { apsPayload, headers } = buildPayload({
      type: "friend_request",
      senderUsername: "alice",
      channelName: null,
      threadId: null,
      senderPeerIdHex: "aa".repeat(8),
      badgeCount: 1,
      deeplink: "blip://friend/aaaaaaaaaaaaaaaa",
    });

    expect(apsPayload.aps.alert).toEqual({
      title: "Friend request",
      body: "alice wants to connect",
    });
    expect(apsPayload.aps.badge).toBe(1);
    expect(apsPayload.aps.sound).toBe("default");
    expect(apsPayload.aps["mutable-content"]).toBe(1);
    expect(apsPayload.aps["interruption-level"]).toBe("passive");
    expect(headers["apns-push-type"]).toBe("alert");
    expect(headers["apns-priority"]).toBe("10");
    expect(headers["apns-expiration"]).toBe("86400");
    expect(headers["apns-collapse-id"]).toBeUndefined();
  });

  it("friend_accept: passive interruption, 24h expiration", () => {
    const { apsPayload, headers } = buildPayload({
      type: "friend_accept",
      senderUsername: "bob",
      channelName: null,
      threadId: null,
      senderPeerIdHex: null,
      badgeCount: 0,
      deeplink: null,
    });
    expect(apsPayload.aps.alert).toEqual({
      title: "Friend request accepted",
      body: "bob accepted your friend request",
    });
    expect(apsPayload.aps["interruption-level"]).toBe("passive");
    expect(headers["apns-expiration"]).toBe("86400");
  });

  it("dm: active, 1h, collapse-id dm:<threadId>", () => {
    const thread = "11111111-2222-3333-4444-555555555555";
    const { apsPayload, headers } = buildPayload({
      type: "dm",
      senderUsername: "carol",
      channelName: null,
      threadId: thread,
      senderPeerIdHex: null,
      badgeCount: 2,
      deeplink: null,
    });
    expect(apsPayload.aps.alert).toEqual({ title: "carol", body: "Sent you a message" });
    expect(apsPayload.aps["interruption-level"]).toBe("active");
    expect(apsPayload.aps["thread-id"]).toBe(thread);
    expect(headers["apns-expiration"]).toBe("3600");
    expect(headers["apns-collapse-id"]).toBe(`dm:${thread}`);
  });

  it("group_message: active, 1h, collapse-id group:<threadId>", () => {
    const thread = "aaa";
    const { apsPayload, headers } = buildPayload({
      type: "group_message",
      senderUsername: "dave",
      channelName: "Festival Crew",
      threadId: thread,
      senderPeerIdHex: null,
      badgeCount: 3,
      deeplink: null,
    });
    expect(apsPayload.aps.alert).toEqual({
      title: "Festival Crew",
      body: "dave sent a message",
    });
    expect(headers["apns-collapse-id"]).toBe(`group:${thread}`);
  });

  it("group_mention: time-sensitive, no collapse-id", () => {
    const { apsPayload, headers } = buildPayload({
      type: "group_mention",
      senderUsername: "eve",
      channelName: "Main",
      threadId: "t",
      senderPeerIdHex: null,
      badgeCount: 1,
      deeplink: null,
    });
    expect(apsPayload.aps["interruption-level"]).toBe("time-sensitive");
    expect(apsPayload.aps.alert?.title).toBe("Main");
    expect(headers["apns-collapse-id"]).toBeUndefined();
  });

  it("voice_note: active, no collapse-id", () => {
    const { apsPayload, headers } = buildPayload({
      type: "voice_note",
      senderUsername: "frank",
      channelName: null,
      threadId: "t",
      senderPeerIdHex: null,
      badgeCount: 1,
      deeplink: null,
    });
    expect(apsPayload.aps.alert).toEqual({ title: "frank", body: "Sent a voice note" });
    expect(apsPayload.aps["interruption-level"]).toBe("active");
    expect(headers["apns-collapse-id"]).toBeUndefined();
  });

  it("sos: critical, never-drop expiration, sos_critical.caf sound", () => {
    const { apsPayload, headers } = buildPayload({
      type: "sos",
      senderUsername: null,
      channelName: null,
      threadId: "sos-alert-uuid",
      senderPeerIdHex: null,
      badgeCount: 1,
      deeplink: null,
    });
    expect(apsPayload.aps.alert).toEqual({
      title: "Emergency nearby",
      body: "Someone nearby needs help",
    });
    expect(apsPayload.aps.sound).toBe("sos_critical.caf");
    expect(apsPayload.aps["interruption-level"]).toBe("critical");
    expect(headers["apns-expiration"]).toBe("0");
    expect(headers["apns-push-type"]).toBe("alert");
  });

  it("silent_badge_sync: content-available, null alert, background push-type", () => {
    const { apsPayload, headers } = buildPayload({
      type: "silent_badge_sync",
      senderUsername: null,
      channelName: null,
      threadId: null,
      senderPeerIdHex: null,
      badgeCount: 7,
      deeplink: null,
    });
    expect(apsPayload.aps.alert).toBeNull();
    expect(apsPayload.aps.sound).toBeNull();
    expect(apsPayload.aps["content-available"]).toBe(1);
    expect(apsPayload.aps.badge).toBe(7);
    expect(apsPayload.aps["mutable-content"]).toBeUndefined();
    expect(apsPayload.aps["interruption-level"]).toBeUndefined();
    expect(headers["apns-push-type"]).toBe("background");
    expect(headers["apns-priority"]).toBe("5");
  });

  it("falls back to 'Someone' when sender username is null", () => {
    const { apsPayload } = buildPayload({
      type: "friend_request",
      senderUsername: null,
      channelName: null,
      threadId: null,
      senderPeerIdHex: null,
      badgeCount: 1,
      deeplink: null,
    });
    expect(apsPayload.aps.alert?.body).toBe("Someone wants to connect");
  });

  it("defaultDeeplink: dm routes to blip://channel/<threadId>", () => {
    expect(defaultDeeplink("dm", "abc", null)).toBe("blip://channel/abc");
    expect(defaultDeeplink("friend_request", null, "ff".repeat(8))).toBe(`blip://friend/${"ff".repeat(8)}`);
    expect(defaultDeeplink("sos", "uuid", null)).toBe("blip://sos/uuid");
    expect(defaultDeeplink("silent_badge_sync", null, null)).toBeNull();
  });

  it("embeds blip envelope metadata", () => {
    const { apsPayload } = buildPayload({
      type: "dm",
      senderUsername: "grace",
      channelName: null,
      threadId: "thread-1",
      senderPeerIdHex: "cc".repeat(8),
      badgeCount: 2,
      deeplink: "blip://channel/thread-1",
    });
    expect(apsPayload.blip).toEqual({
      type: "dm",
      threadId: "thread-1",
      senderPeerIdHex: "cc".repeat(8),
      senderUsername: "grace",
      deeplink: "blip://channel/thread-1",
      badgeCount: 2,
    });
  });

  it("friend_request: blip envelope carries senderUsername for NSE enrichment", () => {
    const { apsPayload } = buildPayload({
      type: "friend_request",
      senderUsername: "tay",
      channelName: null,
      threadId: null,
      senderPeerIdHex: "aa".repeat(8),
      badgeCount: 1,
      deeplink: null,
    });
    expect(apsPayload.blip.senderUsername).toBe("tay");
  });

  it("friend_request: blip.senderUsername is null when sender is unknown", () => {
    const { apsPayload } = buildPayload({
      type: "friend_request",
      senderUsername: null,
      channelName: null,
      threadId: null,
      senderPeerIdHex: null,
      badgeCount: 1,
      deeplink: null,
    });
    expect(apsPayload.blip.senderUsername).toBeNull();
  });
});
