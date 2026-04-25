import {
  env,
  createExecutionContext,
  waitOnExecutionContext,
} from "cloudflare:test";
import { describe, it, expect, beforeEach, vi } from "vitest";

type MockUser = {
  id: string;
  username: string;
  peer_id_hex: string | null;
  noise_public_key: Uint8Array | null;
};

type MockDeviceToken = {
  user_id: string;
  token: string;
  sandbox: boolean;
};

type MockPrefs = {
  user_id: string;
  dm_enabled: boolean;
  friend_requests_enabled: boolean;
  group_mentions_enabled: boolean;
  voice_notes_enabled: boolean;
  quiet_hours_start_utc: number | null;
  quiet_hours_end_utc: number | null;
  utc_offset_seconds: number;
  muted_channels: Array<{ channelId?: string; until?: string | null }>;
  muted_friends: Array<{ peerIdHex?: string; until?: string | null }>;
};

vi.mock("@neondatabase/serverless", () => ({
  neon: () => {
    const g = globalThis as any;
    g.__pushMockUsers ??= [] as MockUser[];
    g.__pushMockDevices ??= [] as MockDeviceToken[];
    g.__pushMockPrefs ??= [] as MockPrefs[];
    g.__pushPurgedTokens ??= [] as string[];

    const users = g.__pushMockUsers as MockUser[];
    const devices = g.__pushMockDevices as MockDeviceToken[];
    const prefs = g.__pushMockPrefs as MockPrefs[];
    const purged = g.__pushPurgedTokens as string[];

    const query = async (strings: TemplateStringsArray, ...values: unknown[]) => {
      const normalized = strings.join("?").replace(/\s+/g, " ").trim().toLowerCase();

      // Recipient + device_tokens left-join lookup
      if (
        normalized.includes("from users u") &&
        normalized.includes("left join device_tokens dt")
      ) {
        const peerIdHex = values[0] as string;
        const user = users.find((u) => u.peer_id_hex === peerIdHex);
        if (!user) return [];
        const userDevices = devices.filter((d) => d.user_id === user.id);
        if (userDevices.length === 0) {
          return [{ user_id: user.id, token: null, sandbox: false }];
        }
        return userDevices.map((d) => ({
          user_id: user.id,
          token: d.token,
          sandbox: d.sandbox,
        }));
      }

      if (normalized.includes("select username from users where peer_id_hex =")) {
        const peerIdHex = values[0] as string;
        const u = users.find((x) => x.peer_id_hex === peerIdHex);
        return u ? [{ username: u.username }] : [];
      }

      if (normalized.includes("from notification_prefs where user_id =")) {
        const userId = values[0] as string;
        const p = prefs.find((x) => x.user_id === userId);
        return p ? [p] : [];
      }

      if (normalized.includes("delete from device_tokens where token =")) {
        const token = values[0] as string;
        purged.push(token);
        const idx = devices.findIndex((d) => d.token === token);
        if (idx >= 0) devices.splice(idx, 1);
        return [];
      }

      if (normalized === "select 1") return [{ "?column?": 1 }];

      throw new Error(`Unhandled mock SQL (internal-push): ${normalized}`);
    };

    const sql = async (strings: TemplateStringsArray, ...values: unknown[]) =>
      query(strings, ...values);
    const transactionalSql = sql as typeof sql & {
      transaction: <T>(cb: (txSql: typeof sql) => Promise<T>) => Promise<T>;
    };
    transactionalSql.transaction = async <T>(cb: (txSql: typeof sql) => Promise<T>): Promise<T> =>
      cb(sql);
    return transactionalSql;
  },
}));

import worker from "../src/index";
import { _resetCacheForTests } from "../src/apns/jwt";

function g(): any {
  return globalThis as any;
}
function reset(): void {
  g().__pushMockUsers = [];
  g().__pushMockDevices = [];
  g().__pushMockPrefs = [];
  g().__pushPurgedTokens = [];
}

async function setValidApnsKey(): Promise<void> {
  const pair = await crypto.subtle.generateKey(
    { name: "ECDSA", namedCurve: "P-256" },
    true,
    ["sign", "verify"]
  );
  const pkcs8 = await crypto.subtle.exportKey("pkcs8", pair.privateKey);
  (env as any).APNS_PRIVATE_KEY = btoa(String.fromCharCode(...new Uint8Array(pkcs8)));
  (env as any).APNS_KEY_ID = "KEYID0001";
  (env as any).APNS_TEAM_ID = "TEAM0001";
  (env as any).APNS_BUNDLE_ID_PROD = "au.heyblip.Blip";
  (env as any).APNS_BUNDLE_ID_DEBUG = "au.heyblip.Blip.debug";
}

function seedUser(username: string, peerIdHex: string): MockUser {
  const user: MockUser = {
    id: crypto.randomUUID(),
    username,
    peer_id_hex: peerIdHex,
    noise_public_key: crypto.getRandomValues(new Uint8Array(32)),
  };
  (g().__pushMockUsers as MockUser[]).push(user);
  return user;
}
function seedDevice(userId: string, token: string, sandbox = false): MockDeviceToken {
  const d: MockDeviceToken = { user_id: userId, token, sandbox };
  (g().__pushMockDevices as MockDeviceToken[]).push(d);
  return d;
}
function seedPrefs(userId: string, overrides: Partial<MockPrefs> = {}): MockPrefs {
  const p: MockPrefs = {
    user_id: userId,
    dm_enabled: true,
    friend_requests_enabled: true,
    group_mentions_enabled: true,
    voice_notes_enabled: true,
    quiet_hours_start_utc: null,
    quiet_hours_end_utc: null,
    utc_offset_seconds: 0,
    muted_channels: [],
    muted_friends: [],
    ...overrides,
  };
  (g().__pushMockPrefs as MockPrefs[]).push(p);
  return p;
}

interface FetchCall {
  url: string;
  init: RequestInit;
}

function stubApnsFetch(
  responder: (call: FetchCall) => Response | Promise<Response>
): { calls: FetchCall[]; restore: () => void } {
  const calls: FetchCall[] = [];
  const original = globalThis.fetch;
  (globalThis as any).fetch = vi.fn(async (url: any, init?: any) => {
    const call: FetchCall = { url: String(url), init: init ?? {} };
    calls.push(call);
    return await responder(call);
  });
  return {
    calls,
    restore: () => {
      (globalThis as any).fetch = original;
    },
  };
}

async function postInternalPush(body: Record<string, unknown>): Promise<Response> {
  const req = new Request("http://localhost/v1/internal/push", {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "X-Internal-Key": "test-internal-key",
    },
    body: JSON.stringify(body),
  });
  const ctx = createExecutionContext();
  const res = await worker.fetch(req, env as any, ctx);
  await waitOnExecutionContext(ctx);
  return res;
}

beforeEach(async () => {
  reset();
  _resetCacheForTests();
  (env as any).DATABASE_URL = "postgres://test";
  (env as any).INTERNAL_API_KEY = "test-internal-key";
  await setValidApnsKey();
});

describe("POST /v1/internal/push — new body shape", () => {
  it("delivers a dm push and returns sent:1", async () => {
    const sender = seedUser("alice", "aa".repeat(8));
    const recipient = seedUser("bob", "bb".repeat(8));
    seedDevice(recipient.id, "device-token-1");

    const { calls, restore } = stubApnsFetch(() => new Response("", { status: 200 }));
    try {
      const res = await postInternalPush({
        recipientPeerIdHex: recipient.peer_id_hex,
        senderPeerIdHex: sender.peer_id_hex,
        type: "dm",
        threadId: "channel-uuid",
        badgeCount: 3,
      });

      expect(res.status).toBe(200);
      expect(await res.json()).toEqual({ sent: 1, failed: 0, suppressed: 0, purged: 0 });
      expect(calls).toHaveLength(1);
      expect(calls[0].url).toBe("https://api.push.apple.com/3/device/device-token-1");

      const sent = JSON.parse((calls[0].init.body as string) ?? "{}");
      expect(sent.aps.alert).toEqual({ title: "alice", body: "Sent you a message" });
      expect(sent.aps.badge).toBe(3);
      expect(sent.aps["thread-id"]).toBe("channel-uuid");
      expect(sent.blip.badgeCount).toBe(3);
      expect(sent.blip.type).toBe("dm");
    } finally {
      restore();
    }
  });

  it("routes sandbox devices to the sandbox host + debug topic", async () => {
    const sender = seedUser("alice", "aa".repeat(8));
    const recipient = seedUser("bob", "bb".repeat(8));
    seedDevice(recipient.id, "sandbox-token", true);

    const { calls, restore } = stubApnsFetch(() => new Response("", { status: 200 }));
    try {
      await postInternalPush({
        recipientPeerIdHex: recipient.peer_id_hex,
        senderPeerIdHex: sender.peer_id_hex,
        type: "dm",
        threadId: null,
        badgeCount: 1,
      });
      expect(calls[0].url).toContain("api.sandbox.push.apple.com");
      const headers = calls[0].init.headers as Record<string, string>;
      expect(headers["apns-topic"]).toBe("au.heyblip.Blip.debug");
    } finally {
      restore();
    }
  });

  it("uses 'Someone' when sender username is missing", async () => {
    const recipient = seedUser("bob", "bb".repeat(8));
    seedDevice(recipient.id, "t");

    const { calls, restore } = stubApnsFetch(() => new Response("", { status: 200 }));
    try {
      await postInternalPush({
        recipientPeerIdHex: recipient.peer_id_hex,
        senderPeerIdHex: "ee".repeat(8),
        type: "friend_request",
        threadId: null,
        badgeCount: 1,
      });
      const body = JSON.parse((calls[0].init.body as string) ?? "{}");
      expect(body.aps.alert.body).toBe("Someone wants to connect");
    } finally {
      restore();
    }
  });

  it("suppresses dm pushes when dmEnabled is false", async () => {
    const sender = seedUser("alice", "aa".repeat(8));
    const recipient = seedUser("bob", "bb".repeat(8));
    seedDevice(recipient.id, "t");
    seedPrefs(recipient.id, { dm_enabled: false });

    const { calls, restore } = stubApnsFetch(() => new Response("", { status: 200 }));
    try {
      const res = await postInternalPush({
        recipientPeerIdHex: recipient.peer_id_hex,
        senderPeerIdHex: sender.peer_id_hex,
        type: "dm",
        threadId: "t",
        badgeCount: 1,
      });
      expect(res.status).toBe(200);
      expect(await res.json()).toEqual({ sent: 0, failed: 0, suppressed: 1, purged: 0 });
      expect(calls).toHaveLength(0);
    } finally {
      restore();
    }
  });

  it("suppresses when threadId is in muted_channels (no until)", async () => {
    const sender = seedUser("alice", "aa".repeat(8));
    const recipient = seedUser("bob", "bb".repeat(8));
    seedDevice(recipient.id, "t");
    seedPrefs(recipient.id, {
      muted_channels: [{ channelId: "noisy", until: null }],
    });

    const { calls, restore } = stubApnsFetch(() => new Response("", { status: 200 }));
    try {
      const res = await postInternalPush({
        recipientPeerIdHex: recipient.peer_id_hex,
        senderPeerIdHex: sender.peer_id_hex,
        type: "group_message",
        threadId: "noisy",
        badgeCount: 1,
      });
      const body = await res.json();
      expect(body).toEqual({ sent: 0, failed: 0, suppressed: 1, purged: 0 });
      expect(calls).toHaveLength(0);
    } finally {
      restore();
    }
  });

  it("suppresses when sender is in muted_friends", async () => {
    const sender = seedUser("alice", "aa".repeat(8));
    const recipient = seedUser("bob", "bb".repeat(8));
    seedDevice(recipient.id, "t");
    seedPrefs(recipient.id, {
      muted_friends: [{ peerIdHex: sender.peer_id_hex ?? "", until: null }],
    });

    const { calls, restore } = stubApnsFetch(() => new Response("", { status: 200 }));
    try {
      const res = await postInternalPush({
        recipientPeerIdHex: recipient.peer_id_hex,
        senderPeerIdHex: sender.peer_id_hex,
        type: "dm",
        threadId: "t",
        badgeCount: 1,
      });
      expect(await res.json()).toEqual({ sent: 0, failed: 0, suppressed: 1, purged: 0 });
      expect(calls).toHaveLength(0);
    } finally {
      restore();
    }
  });

  it("suppresses via quiet hours (wrap-around)", async () => {
    const sender = seedUser("alice", "aa".repeat(8));
    const recipient = seedUser("bob", "bb".repeat(8));
    seedDevice(recipient.id, "t");
    // Compute prefs that guarantee "now" is within quiet hours.
    const nowUtcMinute = Math.floor((Date.now() / 60_000) % 1440);
    const start = (nowUtcMinute - 60 + 1440) % 1440;
    const end = (nowUtcMinute + 60) % 1440;
    seedPrefs(recipient.id, {
      quiet_hours_start_utc: start,
      quiet_hours_end_utc: end,
      utc_offset_seconds: 0,
    });

    const { calls, restore } = stubApnsFetch(() => new Response("", { status: 200 }));
    try {
      const res = await postInternalPush({
        recipientPeerIdHex: recipient.peer_id_hex,
        senderPeerIdHex: sender.peer_id_hex,
        type: "dm",
        threadId: "x",
        badgeCount: 1,
      });
      expect(await res.json()).toEqual({ sent: 0, failed: 0, suppressed: 1, purged: 0 });
      expect(calls).toHaveLength(0);
    } finally {
      restore();
    }
  });

  it("never suppresses SOS even when quiet hours + dm disabled", async () => {
    const sender = seedUser("alice", "aa".repeat(8));
    const recipient = seedUser("bob", "bb".repeat(8));
    seedDevice(recipient.id, "t");
    const nowUtcMinute = Math.floor((Date.now() / 60_000) % 1440);
    seedPrefs(recipient.id, {
      dm_enabled: false,
      quiet_hours_start_utc: (nowUtcMinute - 60 + 1440) % 1440,
      quiet_hours_end_utc: (nowUtcMinute + 60) % 1440,
      muted_friends: [{ peerIdHex: sender.peer_id_hex ?? "", until: null }],
    });

    const { calls, restore } = stubApnsFetch(() => new Response("", { status: 200 }));
    try {
      const res = await postInternalPush({
        recipientPeerIdHex: recipient.peer_id_hex,
        senderPeerIdHex: sender.peer_id_hex,
        type: "sos",
        threadId: "sos-1",
        badgeCount: 1,
      });
      expect(await res.json()).toEqual({ sent: 1, failed: 0, suppressed: 0, purged: 0 });
      expect(calls).toHaveLength(1);
    } finally {
      restore();
    }
  });

  it("purges tokens on 410 Unregistered within the request", async () => {
    const sender = seedUser("alice", "aa".repeat(8));
    const recipient = seedUser("bob", "bb".repeat(8));
    seedDevice(recipient.id, "dead-token");

    const { restore } = stubApnsFetch(
      () => new Response(JSON.stringify({ reason: "Unregistered" }), { status: 410 })
    );
    try {
      const res = await postInternalPush({
        recipientPeerIdHex: recipient.peer_id_hex,
        senderPeerIdHex: sender.peer_id_hex,
        type: "dm",
        threadId: "x",
        badgeCount: 1,
      });
      expect(await res.json()).toEqual({ sent: 0, failed: 0, suppressed: 0, purged: 1 });
      expect(g().__pushPurgedTokens).toContain("dead-token");
    } finally {
      restore();
    }
  });

  it("silent_badge_sync uses content-available + background push-type", async () => {
    const recipient = seedUser("bob", "bb".repeat(8));
    seedDevice(recipient.id, "t");

    const { calls, restore } = stubApnsFetch(() => new Response("", { status: 200 }));
    try {
      await postInternalPush({
        recipientPeerIdHex: recipient.peer_id_hex,
        senderPeerIdHex: null,
        type: "silent_badge_sync",
        threadId: null,
        badgeCount: 9,
      });
      const headers = calls[0].init.headers as Record<string, string>;
      expect(headers["apns-push-type"]).toBe("background");
      expect(headers["apns-priority"]).toBe("5");
      const body = JSON.parse((calls[0].init.body as string) ?? "{}");
      expect(body.aps["content-available"]).toBe(1);
      expect(body.aps.alert).toBeNull();
      expect(body.aps.badge).toBe(9);
      expect(body.blip.badgeCount).toBe(9);
    } finally {
      restore();
    }
  });

  it("returns 200 with empty counts when recipient has no device tokens", async () => {
    const sender = seedUser("alice", "aa".repeat(8));
    const recipient = seedUser("bob", "bb".repeat(8));
    void sender;
    void recipient;

    const { restore } = stubApnsFetch(() => new Response("", { status: 200 }));
    try {
      const res = await postInternalPush({
        recipientPeerIdHex: recipient.peer_id_hex,
        senderPeerIdHex: sender.peer_id_hex,
        type: "dm",
        threadId: "x",
        badgeCount: 1,
      });
      expect(res.status).toBe(200);
      expect(await res.json()).toEqual({ sent: 0, failed: 0, suppressed: 0, purged: 0 });
    } finally {
      restore();
    }
  });

  it("rejects without X-Internal-Key", async () => {
    const req = new Request("http://localhost/v1/internal/push", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ recipientPeerIdHex: "x", type: "dm" }),
    });
    const ctx = createExecutionContext();
    const res = await worker.fetch(req, env as any, ctx);
    await waitOnExecutionContext(ctx);
    expect(res.status).toBe(401);
  });
});

describe("POST /v1/internal/push — legacy body compatibility", () => {
  it("accepts the old `pushType` + `content-available` shape and maps it", async () => {
    const sender = seedUser("alice", "aa".repeat(8));
    const recipient = seedUser("bob", "bb".repeat(8));
    seedDevice(recipient.id, "t");

    const logSpy = vi.spyOn(console, "log").mockImplementation(() => {});
    const { calls, restore } = stubApnsFetch(() => new Response("", { status: 200 }));
    try {
      const res = await postInternalPush({
        recipientPeerIdHex: recipient.peer_id_hex,
        senderPeerIdHex: sender.peer_id_hex,
        pushType: 0x60, // friend_request in legacy numbering
        "content-available": 0,
      });
      expect(res.status).toBe(200);
      const sent = JSON.parse((calls[0].init.body as string) ?? "{}");
      expect(sent.blip.type).toBe("friend_request");
      // Verify legacy log fired
      const legacyCalls = logSpy.mock.calls.filter((c) => {
        try {
          return JSON.parse(String(c[0])).event === "push.legacy_body";
        } catch {
          return false;
        }
      });
      expect(legacyCalls.length).toBeGreaterThanOrEqual(1);
    } finally {
      logSpy.mockRestore();
      restore();
    }
  });

  it("legacy `content-available=1` maps to silent_badge_sync", async () => {
    const sender = seedUser("alice", "aa".repeat(8));
    const recipient = seedUser("bob", "bb".repeat(8));
    seedDevice(recipient.id, "t");

    const { calls, restore } = stubApnsFetch(() => new Response("", { status: 200 }));
    try {
      await postInternalPush({
        recipientPeerIdHex: recipient.peer_id_hex,
        senderPeerIdHex: sender.peer_id_hex,
        pushType: 0,
        "content-available": 1,
      });
      const headers = calls[0].init.headers as Record<string, string>;
      expect(headers["apns-push-type"]).toBe("background");
    } finally {
      restore();
    }
  });
});
