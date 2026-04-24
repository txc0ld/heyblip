import { describe, it, expect, beforeEach, vi } from "vitest";
import { sendApns } from "../src/apns/client";
import { _resetCacheForTests } from "../src/apns/jwt";
import type { Env } from "../src/index";

async function makeEnv(): Promise<Env> {
  const pair = await crypto.subtle.generateKey(
    { name: "ECDSA", namedCurve: "P-256" },
    true,
    ["sign", "verify"]
  );
  const pkcs8 = await crypto.subtle.exportKey("pkcs8", pair.privateKey);
  const b64 = btoa(String.fromCharCode(...new Uint8Array(pkcs8)));
  return {
    APNS_KEY_ID: "KEYID0001",
    APNS_TEAM_ID: "TEAM0001",
    APNS_PRIVATE_KEY: b64,
    APNS_BUNDLE_ID_PROD: "au.heyblip.Blip",
    APNS_BUNDLE_ID_DEBUG: "au.heyblip.Blip.debug",
  } as unknown as Env;
}

interface FetchCall {
  url: string;
  init: RequestInit;
}

function stubFetchSequence(responses: Array<Response | (() => Response | Promise<Response>)>): {
  calls: FetchCall[];
  restore: () => void;
} {
  const calls: FetchCall[] = [];
  const original = globalThis.fetch;
  let i = 0;
  const mocked = vi.fn(async (url: any, init?: any) => {
    calls.push({ url: String(url), init: init ?? {} });
    const next = responses[Math.min(i, responses.length - 1)];
    i += 1;
    return typeof next === "function" ? await (next as any)() : next;
  });
  (globalThis as any).fetch = mocked as any;
  return {
    calls,
    restore: () => {
      (globalThis as any).fetch = original;
    },
  };
}

function makeResponse(
  status: number,
  body: unknown = "",
  headers: Record<string, string> = {}
): Response {
  const payload = typeof body === "string" ? body : JSON.stringify(body);
  return new Response(payload, {
    status,
    headers: { "content-type": "application/json", ...headers },
  });
}

describe("apns/client", () => {
  beforeEach(() => {
    _resetCacheForTests();
  });

  it("posts to api.push.apple.com in production mode with the prod topic", async () => {
    const env = await makeEnv();
    const { calls, restore } = stubFetchSequence([makeResponse(200, "", { "apns-id": "abc" })]);
    try {
      const result = await sendApns(env, {
        token: "DEVICETOKEN",
        payload: { aps: { alert: { title: "x", body: "y" }, badge: 1 } },
        headers: { "apns-push-type": "alert", "apns-priority": "10", "apns-expiration": "3600" },
        sandbox: false,
        apnsId: "my-uuid",
      });

      expect(result.status).toBe(200);
      expect(calls[0].url).toBe("https://api.push.apple.com/3/device/DEVICETOKEN");
      const headers = calls[0].init.headers as Record<string, string>;
      expect(headers["apns-topic"]).toBe("au.heyblip.Blip");
      expect(headers["apns-push-type"]).toBe("alert");
      expect(headers["apns-id"]).toBe("my-uuid");
      expect(headers.authorization).toMatch(/^bearer /);
    } finally {
      restore();
    }
  });

  it("posts to sandbox host with debug topic when sandbox=true", async () => {
    const env = await makeEnv();
    const { calls, restore } = stubFetchSequence([makeResponse(200)]);
    try {
      await sendApns(env, {
        token: "TOK",
        payload: {},
        headers: { "apns-push-type": "alert", "apns-priority": "10", "apns-expiration": "0" },
        sandbox: true,
        apnsId: "u",
      });
      expect(calls[0].url).toBe("https://api.sandbox.push.apple.com/3/device/TOK");
      const headers = calls[0].init.headers as Record<string, string>;
      expect(headers["apns-topic"]).toBe("au.heyblip.Blip.debug");
    } finally {
      restore();
    }
  });

  it("returns purgeToken=true for 400 BadDeviceToken", async () => {
    const env = await makeEnv();
    const { restore } = stubFetchSequence([makeResponse(400, { reason: "BadDeviceToken" })]);
    try {
      const result = await sendApns(env, {
        token: "T",
        payload: {},
        headers: { "apns-push-type": "alert", "apns-priority": "10", "apns-expiration": "0" },
        sandbox: false,
        apnsId: "id",
      });
      expect(result.status).toBe(400);
      expect(result.purgeToken).toBe(true);
      expect(result.reason).toBe("BadDeviceToken");
    } finally {
      restore();
    }
  });

  it("returns purgeToken=true for 410 Unregistered", async () => {
    const env = await makeEnv();
    const { restore } = stubFetchSequence([makeResponse(410, { reason: "Unregistered" })]);
    try {
      const result = await sendApns(env, {
        token: "T",
        payload: {},
        headers: { "apns-push-type": "alert", "apns-priority": "10", "apns-expiration": "0" },
        sandbox: false,
        apnsId: "id",
      });
      expect(result.status).toBe(410);
      expect(result.purgeToken).toBe(true);
    } finally {
      restore();
    }
  });

  it("flags 403 as authFailure and does not retry", async () => {
    const env = await makeEnv();
    const { calls, restore } = stubFetchSequence([makeResponse(403, { reason: "InvalidProviderToken" })]);
    try {
      const result = await sendApns(env, {
        token: "T",
        payload: {},
        headers: { "apns-push-type": "alert", "apns-priority": "10", "apns-expiration": "0" },
        sandbox: false,
        apnsId: "id",
      });
      expect(result.status).toBe(403);
      expect(result.authFailure).toBe(true);
      expect(calls).toHaveLength(1);
    } finally {
      restore();
    }
  });

  it("retries 429 up to the max-attempts boundary and then succeeds", async () => {
    const env = await makeEnv();
    const { calls, restore } = stubFetchSequence([
      makeResponse(429, { reason: "TooManyRequests" }),
      makeResponse(429, { reason: "TooManyRequests" }),
      makeResponse(200),
    ]);
    try {
      // Speed up backoff waits.
      vi.spyOn(global, "setTimeout").mockImplementation((cb: any) => {
        cb();
        return 0 as unknown as ReturnType<typeof setTimeout>;
      });

      const result = await sendApns(env, {
        token: "T",
        payload: {},
        headers: { "apns-push-type": "alert", "apns-priority": "10", "apns-expiration": "0" },
        sandbox: false,
        apnsId: "id",
      });
      expect(result.status).toBe(200);
      expect(calls).toHaveLength(3);
    } finally {
      vi.restoreAllMocks();
      restore();
    }
  });

  it("returns final 429 status after retries are exhausted", async () => {
    const env = await makeEnv();
    const { calls, restore } = stubFetchSequence([
      makeResponse(429, { reason: "TooManyRequests" }),
      makeResponse(429, { reason: "TooManyRequests" }),
      makeResponse(429, { reason: "TooManyRequests" }),
    ]);
    try {
      vi.spyOn(global, "setTimeout").mockImplementation((cb: any) => {
        cb();
        return 0 as unknown as ReturnType<typeof setTimeout>;
      });
      const result = await sendApns(env, {
        token: "T",
        payload: {},
        headers: { "apns-push-type": "alert", "apns-priority": "10", "apns-expiration": "0" },
        sandbox: false,
        apnsId: "id",
      });
      expect(result.status).toBe(429);
      expect(calls).toHaveLength(3);
    } finally {
      vi.restoreAllMocks();
      restore();
    }
  });

  it("echoes apns-id from the response header when provided", async () => {
    const env = await makeEnv();
    const { restore } = stubFetchSequence([makeResponse(200, "", { "apns-id": "server-id-123" })]);
    try {
      const result = await sendApns(env, {
        token: "T",
        payload: {},
        headers: { "apns-push-type": "alert", "apns-priority": "10", "apns-expiration": "0" },
        sandbox: false,
        apnsId: "client-id",
      });
      expect(result.apnsId).toBe("server-id-123");
    } finally {
      restore();
    }
  });
});
