import { describe, it, expect, beforeEach, afterEach, vi } from "vitest";
import { getApnsJwt, _resetCacheForTests, invalidateApnsJwt } from "../src/apns/jwt";
import type { Env } from "../src/index";

// Generate a real P-256 key once per test so the jwt module can import it as PKCS8.
async function generateTestEnv(): Promise<{
  env: Env;
  publicKey: CryptoKey;
}> {
  const pair = await crypto.subtle.generateKey(
    { name: "ECDSA", namedCurve: "P-256" },
    true,
    ["sign", "verify"]
  );
  const pkcs8 = await crypto.subtle.exportKey("pkcs8", pair.privateKey);
  const b64 = btoa(String.fromCharCode(...new Uint8Array(pkcs8)));

  const env = {
    APNS_KEY_ID: "ABC1234567",
    APNS_TEAM_ID: "TEAM000001",
    APNS_PRIVATE_KEY: b64,
  } as unknown as Env;

  return { env, publicKey: pair.publicKey };
}

function base64UrlDecode(input: string): Uint8Array {
  const normalized = input.replace(/-/g, "+").replace(/_/g, "/");
  const pad = normalized.length % 4 === 0 ? "" : "=".repeat(4 - (normalized.length % 4));
  const binary = atob(normalized + pad);
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i += 1) {
    bytes[i] = binary.charCodeAt(i);
  }
  return bytes;
}

function decodeJson(segment: string): any {
  return JSON.parse(new TextDecoder().decode(base64UrlDecode(segment)));
}

describe("apns/jwt", () => {
  beforeEach(() => {
    _resetCacheForTests();
    vi.useRealTimers();
  });

  afterEach(() => {
    vi.useRealTimers();
  });

  it("signs an ES256 JWT with the expected header and payload", async () => {
    const { env, publicKey } = await generateTestEnv();
    const token = await getApnsJwt(env);

    const [headerB64, payloadB64, signatureB64] = token.split(".");
    expect(headerB64).toBeTruthy();
    expect(payloadB64).toBeTruthy();
    expect(signatureB64).toBeTruthy();

    const header = decodeJson(headerB64);
    expect(header).toMatchObject({ alg: "ES256", typ: "JWT", kid: env.APNS_KEY_ID });

    const payload = decodeJson(payloadB64);
    expect(payload.iss).toBe(env.APNS_TEAM_ID);
    expect(typeof payload.iat).toBe("number");
    expect(Math.abs(payload.iat - Math.floor(Date.now() / 1000))).toBeLessThan(5);

    // Verify signature.
    const signingInput = new TextEncoder().encode(`${headerB64}.${payloadB64}`);
    const signature = base64UrlDecode(signatureB64);
    const valid = await crypto.subtle.verify(
      { name: "ECDSA", hash: "SHA-256" },
      publicKey,
      signature,
      signingInput
    );
    expect(valid).toBe(true);
  });

  it("reuses the cached JWT within the 55 minute window", async () => {
    const { env } = await generateTestEnv();
    const first = await getApnsJwt(env);
    const second = await getApnsJwt(env);
    expect(first).toBe(second);
  });

  it("refreshes after 55 minutes", async () => {
    vi.useFakeTimers();
    const startMs = new Date("2026-04-25T00:00:00Z").getTime();
    vi.setSystemTime(startMs);
    const { env } = await generateTestEnv();

    const first = await getApnsJwt(env);

    // Jump past 55 minutes.
    vi.setSystemTime(startMs + 56 * 60 * 1000);
    const second = await getApnsJwt(env);

    expect(first).not.toBe(second);
  });

  it("rejects malformed private keys", async () => {
    const env = {
      APNS_KEY_ID: "K",
      APNS_TEAM_ID: "T",
      APNS_PRIVATE_KEY: "Zm9vYmFy", // "foobar" — not a PKCS8 key
    } as unknown as Env;

    await expect(getApnsJwt(env)).rejects.toThrow(/PKCS8|key/i);
  });

  it("fails when credentials are missing", async () => {
    await expect(
      getApnsJwt({ APNS_KEY_ID: "", APNS_TEAM_ID: "", APNS_PRIVATE_KEY: "" } as unknown as Env)
    ).rejects.toThrow(/missing/);
  });

  it("invalidateApnsJwt clears the cache", async () => {
    const { env } = await generateTestEnv();
    const first = await getApnsJwt(env);
    invalidateApnsJwt();
    // sleep 1s worth of iat — if iat differs the token differs. Token bytes
    // include `iat` so any re-sign after a timer advance produces a new token.
    // Without advancing the clock a re-sign within the same second yields the
    // same header/payload and therefore the same token; only guarantee we have
    // is that the cache was emptied (next getApnsJwt runs the signing path
    // again). We assert by spying on crypto.subtle.sign.
    const signSpy = vi.spyOn(crypto.subtle, "sign");
    const second = await getApnsJwt(env);
    expect(signSpy).toHaveBeenCalled();
    expect(second).toBeTruthy();
    expect(second.split(".").length).toBe(3);
    expect(first.split(".").length).toBe(3);
    signSpy.mockRestore();
  });
});
