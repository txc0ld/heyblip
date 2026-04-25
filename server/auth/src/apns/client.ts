/**
 * APNs HTTP/2 client.
 *
 * Cloudflare Workers' `fetch` speaks HTTP/2 to APNs natively. We build the
 * URL from `sandbox`, set the right topic/priority headers, and POST the
 * JSON envelope. Retries 429/503 with exponential backoff + jitter (max 3
 * attempts). 400 BadDeviceToken / 410 bubble back to the caller as a purge
 * signal.
 */
import * as Sentry from "@sentry/cloudflare";
import type { Env } from "../index";
import { getApnsJwt, invalidateApnsJwt } from "./jwt";

const PROD_HOST = "api.push.apple.com";
const SANDBOX_HOST = "api.sandbox.push.apple.com";
const MAX_RETRY_ATTEMPTS = 3;
const BASE_BACKOFF_MS = 500;

export interface SendApnsInput {
  token: string;
  payload: unknown;
  headers: Readonly<Record<string, string | undefined>>;
  sandbox: boolean;
  apnsId: string;
}

export interface SendApnsResult {
  status: number;
  reason?: string;
  apnsId: string;
  /** True when the caller must delete the device token (400 BadDeviceToken/410). */
  purgeToken?: boolean;
  /** True when auth failed (403) — caller should nullify the JWT cache. */
  authFailure?: boolean;
}

function apnsHost(env: Env, sandbox: boolean): string {
  return sandbox ? SANDBOX_HOST : PROD_HOST;
}

function apnsTopic(env: Env, sandbox: boolean): string {
  return sandbox
    ? (env.APNS_BUNDLE_ID_DEBUG ?? "au.heyblip.Blip.debug")
    : (env.APNS_BUNDLE_ID_PROD ?? "au.heyblip.Blip");
}

function jitter(ms: number): number {
  // ±25% jitter
  const range = ms * 0.25;
  return ms + (Math.random() * 2 - 1) * range;
}

function delay(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, Math.max(0, Math.floor(ms))));
}

async function parseReason(response: Response): Promise<string | undefined> {
  try {
    const text = await response.clone().text();
    if (!text) return undefined;
    const parsed = JSON.parse(text) as { reason?: unknown };
    return typeof parsed.reason === "string" ? parsed.reason : undefined;
  } catch {
    return undefined;
  }
}

/**
 * POST a push to APNs. Handles retries for 429/503; caller maps 200/400/410/
 * 403/other-errors.
 */
export async function sendApns(env: Env, input: SendApnsInput): Promise<SendApnsResult> {
  const url = `https://${apnsHost(env, input.sandbox)}/3/device/${input.token}`;
  const topic = apnsTopic(env, input.sandbox);

  let lastStatus = 0;
  let lastReason: string | undefined;

  for (let attempt = 1; attempt <= MAX_RETRY_ATTEMPTS; attempt += 1) {
    const jwt = await getApnsJwt(env);
    const headers: Record<string, string> = {
      authorization: `bearer ${jwt}`,
      "apns-topic": topic,
      "apns-id": input.apnsId,
      "content-type": "application/json",
    };
    for (const [key, value] of Object.entries(input.headers)) {
      if (typeof value === "string") headers[key] = value;
    }

    const response = await fetch(url, {
      method: "POST",
      headers,
      body: JSON.stringify(input.payload),
    });

    const status = response.status;
    const apnsId = response.headers.get("apns-id") ?? input.apnsId;

    if (status === 200) {
      return { status, apnsId };
    }

    const reason = await parseReason(response);
    lastStatus = status;
    lastReason = reason;

    if (status === 400 && reason === "BadDeviceToken") {
      return { status, reason, apnsId, purgeToken: true };
    }
    if (status === 410) {
      return { status, reason: reason ?? "Unregistered", apnsId, purgeToken: true };
    }
    if (status === 403) {
      // Auth token rejected — invalidate cached JWT, capture to Sentry, don't retry.
      invalidateApnsJwt();
      try {
        Sentry.captureMessage("APNs 403 — JWT rejected", {
          level: "fatal",
          tags: { provider: "apns", "apns.reason": reason ?? "unknown", route: "apns.send" },
        });
      } catch {
        // Sentry must not break the push path.
      }
      return { status, reason, apnsId, authFailure: true };
    }

    if ((status === 429 || status === 503) && attempt < MAX_RETRY_ATTEMPTS) {
      const backoff = jitter(BASE_BACKOFF_MS * Math.pow(2, attempt - 1));
      await delay(backoff);
      continue;
    }

    // Other 4xx/5xx — return as-is.
    return { status, reason, apnsId };
  }

  return { status: lastStatus, reason: lastReason, apnsId: input.apnsId };
}
