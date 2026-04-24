import {
  env,
  createExecutionContext,
  waitOnExecutionContext,
} from "cloudflare:test";
import { describe, it, expect, beforeEach, vi } from "vitest";

// Badge clear uses the legacy base64 auth (noise pubkey as bearer) so we don't
// need the DB — but the handler imports neon via `getDb` from auth context?
// Actually handleBadgeClear does NOT hit the DB; only authenticateRequest is
// called. Legacy auth does no DB calls. So we don't need a mock here — but
// `getDb` is only reached via `neon()` import inside handleInternalPush etc.
// `authenticateRequest` does not open a SQL client.

import worker from "../src/index";

function base64(bytes: Uint8Array): string {
  let s = "";
  for (const b of bytes) s += String.fromCharCode(b);
  return btoa(s);
}

interface FetchCall {
  url: string;
  init: RequestInit;
}

function stubFetch(
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

async function post(
  body: Record<string, unknown>,
  authHeader?: string
): Promise<Response> {
  const headers: Record<string, string> = { "Content-Type": "application/json" };
  if (authHeader) headers.Authorization = authHeader;
  const req = new Request("http://localhost/v1/badge/clear", {
    method: "POST",
    headers,
    body: JSON.stringify(body),
  });
  const ctx = createExecutionContext();
  const res = await worker.fetch(req, env as any, ctx);
  await waitOnExecutionContext(ctx);
  return res;
}

function makeAuthHeader(): string {
  const noisePublicKey = crypto.getRandomValues(new Uint8Array(32));
  return `Bearer ${base64(noisePublicKey)}`;
}

beforeEach(() => {
  (env as any).INTERNAL_API_KEY = "test-internal-key";
  (env as any).RELAY_INTERNAL_URL = "https://relay.example.test";
  (env as any).CORS_ORIGIN = "http://localhost:3000";
});

describe("POST /v1/badge/clear", () => {
  it("rejects without JWT/auth", async () => {
    const res = await post({ all: true });
    expect(res.status).toBe(401);
  });

  it("forwards threadId to relay with X-Internal-Key and returns relay response", async () => {
    const auth = makeAuthHeader();
    const { calls, restore } = stubFetch(
      () => new Response(JSON.stringify({ badgeCount: 4 }), { status: 200 })
    );
    try {
      const res = await post({ threadId: "thread-1", all: false }, auth);
      expect(res.status).toBe(200);
      expect(await res.json()).toEqual({ cleared: true, badgeCount: 4 });
      expect(calls).toHaveLength(1);
      expect(calls[0].url).toBe("https://relay.example.test/internal/badge/clear");
      const headers = calls[0].init.headers as Record<string, string>;
      expect(headers["X-Internal-Key"]).toBe("test-internal-key");
      const body = JSON.parse((calls[0].init.body as string) ?? "{}");
      expect(body.threadId).toBe("thread-1");
      expect(body.all).toBe(false);
      expect(typeof body.peerIdHex).toBe("string");
      expect(body.peerIdHex).toHaveLength(16);
    } finally {
      restore();
    }
  });

  it("forwards all=true clear request", async () => {
    const auth = makeAuthHeader();
    const { calls, restore } = stubFetch(
      () => new Response(JSON.stringify({ badgeCount: 0 }), { status: 200 })
    );
    try {
      const res = await post({ all: true }, auth);
      expect(res.status).toBe(200);
      expect(await res.json()).toEqual({ cleared: true, badgeCount: 0 });
      const body = JSON.parse((calls[0].init.body as string) ?? "{}");
      expect(body.all).toBe(true);
      expect(body.threadId).toBeNull();
    } finally {
      restore();
    }
  });

  it("rejects when both threadId and all are provided", async () => {
    const auth = makeAuthHeader();
    const { calls, restore } = stubFetch(() => new Response("", { status: 200 }));
    try {
      const res = await post({ threadId: "t", all: true }, auth);
      expect(res.status).toBe(400);
      expect(calls).toHaveLength(0);
    } finally {
      restore();
    }
  });

  it("rejects when neither threadId nor all are provided", async () => {
    const auth = makeAuthHeader();
    const { calls, restore } = stubFetch(() => new Response("", { status: 200 }));
    try {
      const res = await post({}, auth);
      expect(res.status).toBe(400);
      expect(calls).toHaveLength(0);
    } finally {
      restore();
    }
  });

  it("propagates relay non-2xx failures", async () => {
    const auth = makeAuthHeader();
    const { restore } = stubFetch(
      () => new Response(JSON.stringify({ error: "nope" }), { status: 500 })
    );
    try {
      const res = await post({ all: true }, auth);
      expect(res.status).toBe(500);
    } finally {
      restore();
    }
  });
});
