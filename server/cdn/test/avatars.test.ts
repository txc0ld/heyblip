import {
  env,
  createExecutionContext,
  waitOnExecutionContext,
} from "cloudflare:test";
import { describe, it, expect, beforeEach } from "vitest";
import worker from "../src/index";

type WorkerEnv = typeof env;

const TEST_JWT_SECRET = "test-jwt-secret";
const ORIGIN = "http://localhost";

// Minimum valid JPEG: SOI marker + EOI marker (0xFFD8FF...FFD9). Most
// validators only check the 3-byte magic prefix; this satisfies both and
// keeps the fixtures small.
const MINIMAL_JPEG = new Uint8Array([0xff, 0xd8, 0xff, 0xe0, 0x00, 0xd9]);

beforeEach(async () => {
  // Wipe the R2 bucket between tests so state doesn't leak between cases.
  const objects = await env.AVATARS.list();
  for (const obj of objects.objects) {
    await env.AVATARS.delete(obj.key);
  }
});

describe("OPTIONS preflight", () => {
  it("returns 204 with CORS headers", async () => {
    const res = await fetchWorker("OPTIONS", "/avatars/upload");
    expect(res.status).toBe(204);
    expect(res.headers.get("Access-Control-Allow-Origin")).toBe("*");
    expect(res.headers.get("Access-Control-Allow-Methods")).toContain("POST");
    expect(res.headers.get("Access-Control-Allow-Headers")).toContain(
      "Authorization"
    );
  });
});

describe("GET /health", () => {
  it("returns 200 with ok status", async () => {
    const res = await fetchWorker("GET", "/health");
    expect(res.status).toBe(200);
    const body = (await res.json()) as { status: string };
    expect(body.status).toBe("ok");
  });
});

describe("Unknown paths", () => {
  it("GET /foo returns 404", async () => {
    const res = await fetchWorker("GET", "/foo");
    expect(res.status).toBe(404);
  });

  it("POST /bar returns 404", async () => {
    const res = await fetchWorker("POST", "/bar");
    expect(res.status).toBe(404);
  });
});

describe("POST /avatars/upload — authentication", () => {
  it("returns 401 when Authorization header is missing", async () => {
    const formData = new FormData();
    formData.set("avatar", new File([MINIMAL_JPEG], "a.jpg", { type: "image/jpeg" }));
    const res = await fetchWorker("POST", "/avatars/upload", { body: formData });
    expect(res.status).toBe(401);
  });

  it("returns 401 for a malformed bearer token", async () => {
    const formData = new FormData();
    formData.set("avatar", new File([MINIMAL_JPEG], "a.jpg", { type: "image/jpeg" }));
    const res = await fetchWorker("POST", "/avatars/upload", {
      body: formData,
      headers: { Authorization: "Bearer not.a.jwt" },
    });
    expect(res.status).toBe(401);
  });

  it("returns 401 for an expired JWT", async () => {
    const token = await signJWT(
      { sub: "alice", npk: "npk-alice", iat: 0, exp: 1 }, // long-expired
      TEST_JWT_SECRET
    );
    const formData = new FormData();
    formData.set("avatar", new File([MINIMAL_JPEG], "a.jpg", { type: "image/jpeg" }));
    const res = await fetchWorker("POST", "/avatars/upload", {
      body: formData,
      headers: { Authorization: `Bearer ${token}` },
    });
    expect(res.status).toBe(401);
  });

  it("returns 401 when the JWT signature is wrong", async () => {
    const token = await signJWT(freshClaims("alice"), "different-secret");
    const formData = new FormData();
    formData.set("avatar", new File([MINIMAL_JPEG], "a.jpg", { type: "image/jpeg" }));
    const res = await fetchWorker("POST", "/avatars/upload", {
      body: formData,
      headers: { Authorization: `Bearer ${token}` },
    });
    expect(res.status).toBe(401);
  });
});

describe("POST /avatars/upload — validation", () => {
  it("returns 400 when Content-Type is not multipart/form-data", async () => {
    const token = await signJWT(freshClaims("alice"), TEST_JWT_SECRET);
    const res = await fetchWorker("POST", "/avatars/upload", {
      body: JSON.stringify({ not: "multipart" }),
      headers: {
        Authorization: `Bearer ${token}`,
        "Content-Type": "application/json",
      },
    });
    expect(res.status).toBe(400);
  });

  it("returns 400 when avatar field is missing", async () => {
    const token = await signJWT(freshClaims("alice"), TEST_JWT_SECRET);
    const formData = new FormData();
    formData.set("other", "unrelated");
    const res = await fetchWorker("POST", "/avatars/upload", {
      body: formData,
      headers: { Authorization: `Bearer ${token}` },
    });
    expect(res.status).toBe(400);
  });

  it("returns 400 when the uploaded file is not a JPEG", async () => {
    const token = await signJWT(freshClaims("alice"), TEST_JWT_SECRET);
    // PNG magic bytes — should fail the JPEG magic check.
    const pngBytes = new Uint8Array([0x89, 0x50, 0x4e, 0x47]);
    const formData = new FormData();
    formData.set("avatar", new File([pngBytes], "a.png", { type: "image/png" }));
    const res = await fetchWorker("POST", "/avatars/upload", {
      body: formData,
      headers: { Authorization: `Bearer ${token}` },
    });
    expect(res.status).toBe(400);
  });

  it("returns 413 when the uploaded file exceeds MAX_AVATAR_BYTES", async () => {
    // Build an oversized-looking payload by claiming >2MB. Miniflare honours
    // Content-Length so a single Uint8Array is sufficient.
    const oversize = new Uint8Array(2 * 1024 * 1024 + 1);
    oversize[0] = 0xff;
    oversize[1] = 0xd8;
    oversize[2] = 0xff;

    const token = await signJWT(freshClaims("alice"), TEST_JWT_SECRET);
    const formData = new FormData();
    formData.set("avatar", new File([oversize], "big.jpg", { type: "image/jpeg" }));
    const res = await fetchWorker("POST", "/avatars/upload", {
      body: formData,
      headers: { Authorization: `Bearer ${token}` },
    });
    expect(res.status).toBe(413);
  });
});

describe("POST /avatars/upload — success", () => {
  it("stores the JPEG in R2 and returns the CDN URL", async () => {
    const token = await signJWT(freshClaims("alice"), TEST_JWT_SECRET);
    const formData = new FormData();
    formData.set("avatar", new File([MINIMAL_JPEG], "a.jpg", { type: "image/jpeg" }));

    const res = await fetchWorker("POST", "/avatars/upload", {
      body: formData,
      headers: { Authorization: `Bearer ${token}` },
    });

    expect(res.status).toBe(200);
    const body = (await res.json()) as { url: string };
    expect(body.url).toBe(`${ORIGIN}/avatars/alice.jpg`);

    const stored = await env.AVATARS.get("alice.jpg");
    expect(stored).not.toBeNull();
    const storedBytes = new Uint8Array(await stored!.arrayBuffer());
    expect(Array.from(storedBytes)).toEqual(Array.from(MINIMAL_JPEG));
    expect(stored!.httpMetadata?.contentType).toBe("image/jpeg");
  });

  it("overwrites an existing avatar on second upload", async () => {
    const token = await signJWT(freshClaims("alice"), TEST_JWT_SECRET);

    for (let i = 0; i < 2; i += 1) {
      const formData = new FormData();
      formData.set("avatar", new File([MINIMAL_JPEG], "a.jpg", { type: "image/jpeg" }));
      const res = await fetchWorker("POST", "/avatars/upload", {
        body: formData,
        headers: { Authorization: `Bearer ${token}` },
      });
      expect(res.status).toBe(200);
    }

    const list = await env.AVATARS.list();
    expect(list.objects.length).toBe(1);
  });
});

describe("GET /avatars/:id.jpg", () => {
  it("returns the stored JPEG with the right headers", async () => {
    await env.AVATARS.put("alice.jpg", MINIMAL_JPEG, {
      httpMetadata: { contentType: "image/jpeg" },
    });

    const res = await fetchWorker("GET", "/avatars/alice.jpg");
    expect(res.status).toBe(200);
    expect(res.headers.get("Content-Type")).toBe("image/jpeg");
    expect(res.headers.get("Cache-Control")).toContain("public");

    const bytes = new Uint8Array(await res.arrayBuffer());
    expect(Array.from(bytes)).toEqual(Array.from(MINIMAL_JPEG));
  });

  it("returns 404 for an unknown avatar id", async () => {
    const res = await fetchWorker("GET", "/avatars/nobody.jpg");
    expect(res.status).toBe(404);
  });

  it("does not match paths with invalid characters", async () => {
    const res = await fetchWorker("GET", "/avatars/not%20allowed.jpg");
    expect(res.status).toBe(404);
  });
});

// MARK: - Helpers

interface RequestOptions {
  body?: BodyInit;
  headers?: Record<string, string>;
}

async function fetchWorker(
  method: string,
  path: string,
  opts: RequestOptions = {}
): Promise<Response> {
  const init: RequestInit = { method };
  if (opts.body !== undefined) init.body = opts.body;
  if (opts.headers) init.headers = opts.headers;

  const req = new Request(`${ORIGIN}${path}`, init);
  const ctx = createExecutionContext();
  const res = await worker.fetch(req, env as unknown as WorkerEnv, ctx);
  await waitOnExecutionContext(ctx);
  return res;
}

function freshClaims(sub: string): {
  sub: string;
  npk: string;
  iat: number;
  exp: number;
} {
  const now = Math.floor(Date.now() / 1000);
  return { sub, npk: `npk-${sub}`, iat: now, exp: now + 3600 };
}

async function signJWT(
  claims: Record<string, string | number>,
  secret: string
): Promise<string> {
  const header = base64UrlEncode(
    new TextEncoder().encode(JSON.stringify({ alg: "HS256", typ: "JWT" }))
  );
  const payload = base64UrlEncode(
    new TextEncoder().encode(JSON.stringify(claims))
  );
  const signingInput = `${header}.${payload}`;

  const key = await crypto.subtle.importKey(
    "raw",
    new TextEncoder().encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"]
  );
  const signature = new Uint8Array(
    await crypto.subtle.sign(
      "HMAC",
      key,
      new TextEncoder().encode(signingInput)
    )
  );
  return `${signingInput}.${base64UrlEncode(signature)}`;
}

function base64UrlEncode(bytes: Uint8Array): string {
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}
