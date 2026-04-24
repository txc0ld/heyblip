import {
  env,
  createExecutionContext,
  waitOnExecutionContext,
} from "cloudflare:test";
import { describe, it, expect, beforeEach, vi } from "vitest";

type MockUser = {
  id: string;
  username: string;
  noise_public_key: Uint8Array;
};
type StoredPrefs = {
  user_id: string;
  dm_enabled: boolean;
  friend_requests_enabled: boolean;
  group_mentions_enabled: boolean;
  voice_notes_enabled: boolean;
  quiet_hours_start_utc: number | null;
  quiet_hours_end_utc: number | null;
  utc_offset_seconds: number;
  muted_channels: unknown;
  muted_friends: unknown;
};

vi.mock("@neondatabase/serverless", () => ({
  neon: () => {
    const g = globalThis as any;
    g.__prefsMockUsers ??= [] as MockUser[];
    g.__prefsMockPrefs ??= [] as StoredPrefs[];

    const users = g.__prefsMockUsers as MockUser[];
    const prefs = g.__prefsMockPrefs as StoredPrefs[];

    const bytesEqual = (a: Uint8Array, b: Uint8Array): boolean => {
      if (a.length !== b.length) return false;
      for (let i = 0; i < a.length; i += 1) {
        if (a[i] !== b[i]) return false;
      }
      return true;
    };

    const query = async (strings: TemplateStringsArray, ...values: unknown[]) => {
      const normalized = strings.join("?").replace(/\s+/g, " ").trim().toLowerCase();

      if (normalized.includes("select id from users where noise_public_key =")) {
        const key = values[0] as Uint8Array;
        const u = users.find((x) => bytesEqual(x.noise_public_key, key));
        return u ? [{ id: u.id }] : [];
      }

      if (normalized.startsWith("insert into notification_prefs")) {
        const [
          userId,
          dmEnabled,
          friendRequestsEnabled,
          groupMentionsEnabled,
          voiceNotesEnabled,
          quietStart,
          quietEnd,
          utcOffsetSeconds,
          mutedChannels,
          mutedFriends,
        ] = values as [
          string,
          boolean,
          boolean,
          boolean,
          boolean,
          number | null,
          number | null,
          number,
          string,
          string,
        ];
        const existing = prefs.find((p) => p.user_id === userId);
        const row: StoredPrefs = {
          user_id: userId,
          dm_enabled: dmEnabled,
          friend_requests_enabled: friendRequestsEnabled,
          group_mentions_enabled: groupMentionsEnabled,
          voice_notes_enabled: voiceNotesEnabled,
          quiet_hours_start_utc: quietStart,
          quiet_hours_end_utc: quietEnd,
          utc_offset_seconds: utcOffsetSeconds,
          muted_channels: JSON.parse(String(mutedChannels)),
          muted_friends: JSON.parse(String(mutedFriends)),
        };
        if (existing) {
          Object.assign(existing, row);
        } else {
          prefs.push(row);
        }
        return [];
      }

      if (normalized === "select 1") return [{ "?column?": 1 }];

      throw new Error(`Unhandled mock SQL (prefs): ${normalized}`);
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

function g(): any {
  return globalThis as any;
}
function reset(): void {
  g().__prefsMockUsers = [];
  g().__prefsMockPrefs = [];
}

function base64(bytes: Uint8Array): string {
  let s = "";
  for (const b of bytes) s += String.fromCharCode(b);
  return btoa(s);
}

function seedUser(): { user: MockUser; authHeader: string } {
  const noisePublicKey = crypto.getRandomValues(new Uint8Array(32));
  const u: MockUser = {
    id: crypto.randomUUID(),
    username: "alice",
    noise_public_key: noisePublicKey,
  };
  (g().__prefsMockUsers as MockUser[]).push(u);
  return { user: u, authHeader: `Bearer ${base64(noisePublicKey)}` };
}

async function post(body: Record<string, unknown>, authHeader?: string): Promise<Response> {
  const headers: Record<string, string> = { "Content-Type": "application/json" };
  if (authHeader) headers.Authorization = authHeader;
  const req = new Request("http://localhost/v1/users/notification-prefs", {
    method: "POST",
    headers,
    body: JSON.stringify(body),
  });
  const ctx = createExecutionContext();
  const res = await worker.fetch(req, env as any, ctx);
  await waitOnExecutionContext(ctx);
  return res;
}

beforeEach(() => {
  reset();
  (env as any).DATABASE_URL = "postgres://test";
  (env as any).CORS_ORIGIN = "http://localhost:3000";
});

describe("POST /v1/users/notification-prefs", () => {
  it("rejects unauthenticated requests", async () => {
    const res = await post({ dmEnabled: false });
    expect(res.status).toBe(401);
  });

  it("inserts preferences on happy path", async () => {
    const { authHeader } = seedUser();
    const res = await post(
      {
        dmEnabled: false,
        friendRequestsEnabled: true,
        groupMentionsEnabled: true,
        voiceNotesEnabled: true,
        quietHoursStartUtc: 1320, // 22:00 UTC
        quietHoursEndUtc: 420, // 07:00 UTC
        utcOffsetSeconds: 0,
        mutedChannels: [{ channelId: "channel-1", until: null }],
        mutedFriends: [{ peerIdHex: "aa".repeat(8), until: null }],
      },
      authHeader
    );
    expect(res.status).toBe(200);
    expect(await res.json()).toEqual({ updated: true });

    const prefs = (globalThis as any).__prefsMockPrefs as StoredPrefs[];
    expect(prefs).toHaveLength(1);
    expect(prefs[0].dm_enabled).toBe(false);
    expect(prefs[0].muted_channels).toEqual([{ channelId: "channel-1", until: null }]);
    expect(prefs[0].muted_friends).toEqual([{ peerIdHex: "aa".repeat(8), until: null }]);
  });

  it("upserts on second call (updates existing row)", async () => {
    const { authHeader } = seedUser();
    await post({ dmEnabled: false }, authHeader);
    await post({ dmEnabled: true, groupMentionsEnabled: false }, authHeader);

    const prefs = (globalThis as any).__prefsMockPrefs as StoredPrefs[];
    expect(prefs).toHaveLength(1);
    expect(prefs[0].dm_enabled).toBe(true);
    expect(prefs[0].group_mentions_enabled).toBe(false);
  });

  it("rejects invalid minute-of-day bounds", async () => {
    const { authHeader } = seedUser();
    const res = await post(
      { quietHoursStartUtc: 1500, quietHoursEndUtc: 0, utcOffsetSeconds: 0 },
      authHeader
    );
    expect(res.status).toBe(400);
  });

  it("ignores an unknown 'sosEnabled' field — SOS is not toggleable", async () => {
    const { authHeader } = seedUser();
    const res = await post({ dmEnabled: true, sosEnabled: false } as any, authHeader);
    expect(res.status).toBe(200);
    const prefs = (globalThis as any).__prefsMockPrefs as StoredPrefs[];
    // SOS isn't a column; we just make sure the extra field is silently dropped.
    expect(prefs[0]).not.toHaveProperty("sos_enabled");
  });

  it("drops mutedFriends entries with bad hex", async () => {
    const { authHeader } = seedUser();
    await post(
      {
        dmEnabled: true,
        mutedFriends: [
          { peerIdHex: "not-hex", until: null },
          { peerIdHex: "bb".repeat(8), until: null },
        ],
      },
      authHeader
    );
    const prefs = (globalThis as any).__prefsMockPrefs as StoredPrefs[];
    expect(prefs[0].muted_friends).toEqual([{ peerIdHex: "bb".repeat(8), until: null }]);
  });
});
