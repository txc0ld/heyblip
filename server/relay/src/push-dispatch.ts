/**
 * Push decision engine for the relay Durable Object.
 *
 * Responsibilities:
 *   - map BlipProtocol packet type bytes → coarse PushType tags the auth
 *     worker understands (zero-knowledge: we never inspect encrypted payload
 *     bytes, so all 0x11 noiseEncrypted traffic is reported as "dm")
 *   - enforce the per-(recipient, thread) cooldown (30s) with a carve-out for
 *     "sos" (bypass) and "silent_badge_sync" (separate 60s window)
 *   - defer the actual auth-worker callout by 500ms so an immediate drain can
 *     cancel it before fan-out happens ("don't push if delivered fast")
 *   - emit a single structured log line per decision so we can audit the
 *     push pipeline without ever logging packet bytes
 *
 * TODO(HEY-1321-follow-up): finer DM/group/voice-note routing would require
 * the iOS client to pass a plaintext "hint byte" in an unencrypted header
 * extension so the relay can differentiate EncryptedSubType without breaking
 * the zero-knowledge boundary. Not in scope for this PR.
 */

import * as Sentry from "@sentry/cloudflare";
import type { Env } from "./types";

// Mirrors BlipProtocol/MessageType. Keep these constants in sync with
// Packages/BlipProtocol/Sources/MessageType.swift — any drift will cause
// silent push misrouting.
export const PACKET_TYPE_ANNOUNCE = 0x01;
export const PACKET_TYPE_MESH_BROADCAST = 0x02;
export const PACKET_TYPE_NOISE_HANDSHAKE = 0x10;
export const PACKET_TYPE_NOISE_ENCRYPTED = 0x11;
export const PACKET_TYPE_FRAGMENT = 0x20;
export const PACKET_TYPE_SYNC_REQUEST = 0x21;
export const PACKET_TYPE_SOS_ALERT = 0x40;
export const PACKET_TYPE_LOCATION_SHARE = 0x50;
export const PACKET_TYPE_FRIEND_REQUEST = 0x60;
export const PACKET_TYPE_FRIEND_ACCEPT = 0x61;

export type PushType =
  | "friend_request"
  | "friend_accept"
  | "dm"
  | "group_message"
  | "group_mention"
  | "voice_note"
  | "sos"
  | "silent_badge_sync";

/**
 * Map a raw BlipProtocol packet type byte to the PushType the auth worker
 * should dispatch. Returns null for packet types we must never push on.
 *
 * NOTE: for 0x11 (noiseEncrypted) the relay cannot see the inner
 * EncryptedSubType (it's the first byte of the decrypted payload), so we
 * always tag as "dm". The iOS Notification Service Extension enriches from
 * its own App-Group cache and picks the right body/sound. Group muting still
 * works because the NSE consults `mutedChannels` before presenting.
 */
export function packetTypeToPushType(packetType: number): PushType | null {
  switch (packetType) {
    case PACKET_TYPE_NOISE_ENCRYPTED:
      return "dm";
    case PACKET_TYPE_SOS_ALERT:
      return "sos";
    case PACKET_TYPE_FRIEND_REQUEST:
      return "friend_request";
    case PACKET_TYPE_FRIEND_ACCEPT:
      return "friend_accept";
    // All remaining types (announce, meshBroadcast, noiseHandshake,
    // fragment, syncRequest, locationShare, and anything we don't recognise)
    // are silent. Fragments in particular MUST NOT push — the reassembled
    // packet is what triggers the push.
    default:
      return null;
  }
}

export interface PushPayload {
  recipientPeerIdHex: string;
  senderPeerIdHex: string | null;
  type: PushType;
  threadId: string | null;
  badgeCount: number;
  traceID?: string;
}

type ShouldPushDecision = "proceed" | "cooldown" | "unsupported_type";

type PendingTimer = {
  timer: ReturnType<typeof setTimeout>;
  payload: PushPayload;
};

/** 30 seconds between pushes per (recipient, thread). */
const COOLDOWN_MS = 30_000;
/** 60 seconds between silent_badge_sync pushes per recipient. */
const SILENT_SYNC_MIN_INTERVAL_MS = 60_000;
/** Delay before the auth-worker callout fires — gives drainQueue a chance to
 *  suppress the push if the peer reconnects immediately. */
const PUSH_SCHEDULE_DELAY_MS = 500;

function cooldownKey(recipientPeerIdHex: string, threadId: string | null): string {
  return `${recipientPeerIdHex}:${threadId ?? "*"}`;
}

function structuredLog(event: string, fields: Record<string, unknown>): void {
  console.log(
    JSON.stringify({
      event,
      timestamp: Date.now(),
      ...fields,
    })
  );
}

function traceLog(traceID: string, message: string): void {
  console.log(`[trace ${traceID}] ${message}`);
}

export class PushDispatcher {
  private readonly lastPushAt = new Map<string, number>();
  private readonly lastSilentSyncAt = new Map<string, number>();
  private readonly pending = new Map<string, PendingTimer>();

  constructor(
    private readonly env: Env,
    private readonly authPushUrl: string
  ) {}

  /**
   * Decide whether a push for `(recipient, thread, type)` should fire right
   * now. SOS always proceeds; silent_badge_sync uses its own 60s window;
   * everything else is per-(peer, thread) cooldown.
   *
   * This does NOT record the decision — call {@link markPushed} after a
   * successful fan-out.
   */
  shouldPush(
    recipientPeerIdHex: string,
    threadId: string | null,
    type: PushType,
    now: number
  ): ShouldPushDecision {
    if (type === "sos") {
      // SOS is life-safety — always bypass cooldown.
      return "proceed";
    }
    if (type === "silent_badge_sync") {
      const last = this.lastSilentSyncAt.get(recipientPeerIdHex) ?? 0;
      if (now - last < SILENT_SYNC_MIN_INTERVAL_MS) {
        return "cooldown";
      }
      return "proceed";
    }
    const key = cooldownKey(recipientPeerIdHex, threadId);
    const last = this.lastPushAt.get(key) ?? 0;
    if (now - last < COOLDOWN_MS) {
      return "cooldown";
    }
    return "proceed";
  }

  /** Record a successful push so subsequent calls respect the cooldown. */
  markPushed(
    recipientPeerIdHex: string,
    threadId: string | null,
    type: PushType,
    now: number
  ): void {
    if (type === "silent_badge_sync") {
      this.lastSilentSyncAt.set(recipientPeerIdHex, now);
      return;
    }
    if (type === "sos") {
      // SOS bypasses cooldown, but we still stamp the per-(peer, thread) key
      // so non-SOS traffic behaves sanely afterwards.
      this.lastPushAt.set(cooldownKey(recipientPeerIdHex, threadId), now);
      return;
    }
    this.lastPushAt.set(cooldownKey(recipientPeerIdHex, threadId), now);
  }

  /**
   * Schedule a push for `queueKey` after {@link PUSH_SCHEDULE_DELAY_MS}ms.
   * Returns immediately; the callout is fire-and-forget. A subsequent call
   * with the same `queueKey` replaces the pending timer.
   */
  schedulePush(queueKey: string, payload: PushPayload, delayMs: number = PUSH_SCHEDULE_DELAY_MS): void {
    // Drop any previous pending push for this key so we never fan out twice.
    this.cancelPendingForKey(queueKey);

    const timer = setTimeout(() => {
      this.pending.delete(queueKey);
      void this.dispatchNow(payload);
    }, delayMs);

    this.pending.set(queueKey, { timer, payload });
  }

  /** Cancel a pending timer for `queueKey`. Returns true if we cancelled one. */
  cancelPendingForKey(queueKey: string): boolean {
    const pending = this.pending.get(queueKey);
    if (!pending) return false;
    clearTimeout(pending.timer);
    this.pending.delete(queueKey);
    return true;
  }

  /**
   * Fire the auth-worker callout now, respecting cooldowns. Safe to call
   * directly for out-of-band pushes (silent_badge_sync on reconnect).
   */
  async dispatchNow(payload: PushPayload): Promise<void> {
    const traceID = payload.traceID ?? crypto.randomUUID();
    const now = Date.now();
    const decision = this.shouldPush(
      payload.recipientPeerIdHex,
      payload.threadId,
      payload.type,
      now
    );
    if (decision === "cooldown") {
      traceLog(
        traceID,
        `push suppressed reason=cooldown type=${payload.type} recipient=${payload.recipientPeerIdHex} thread=${payload.threadId ?? "-"}`
      );
      structuredLog("push.suppressed", {
        reason: "cooldown",
        recipientPeerIdHex: payload.recipientPeerIdHex,
        type: payload.type,
        threadId: payload.threadId,
        traceID,
      });
      return;
    }

    this.markPushed(payload.recipientPeerIdHex, payload.threadId, payload.type, now);

    // Compose the body — never include packet bytes or any decrypted content.
    const body: Record<string, unknown> = {
      recipientPeerIdHex: payload.recipientPeerIdHex,
      senderPeerIdHex: payload.senderPeerIdHex,
      type: payload.type,
      threadId: payload.threadId,
      badgeCount: payload.badgeCount,
    };

    try {
      traceLog(
        traceID,
        `env.AUTH.fetch /v1/internal/push type=${payload.type} recipient=${payload.recipientPeerIdHex} thread=${payload.threadId ?? "-"}`
      );
      const init: RequestInit = {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          "X-Internal-Key": this.env.INTERNAL_API_KEY,
          "X-Trace-ID": traceID,
        },
        body: JSON.stringify(body),
      };
      // Prefer the Service Binding when configured. workers.dev →
      // workers.dev cross-Worker fetches over the public URL are blocked by
      // Cloudflare with `error code: 1042`; the Service Binding routes the
      // request inside the edge without going over the network.
      const resp = this.env.AUTH
        ? await this.env.AUTH.fetch(this.authPushUrl, init)
        : await fetch(this.authPushUrl, init);
      if (!resp.ok) {
        traceLog(
          traceID,
          `env.AUTH.fetch non-OK status=${resp.status} type=${payload.type} recipient=${payload.recipientPeerIdHex}`
        );
        structuredLog("push.internal_fetch_failed", {
          recipientPeerIdHex: payload.recipientPeerIdHex,
          type: payload.type,
          status: resp.status,
          traceID,
        });
        Sentry.captureMessage("Relay push trigger returned non-OK status", {
          level: "warning",
          tags: { component: "push-dispatch", operation: "push_trigger" },
          extra: { status: resp.status, recipientPeerIdHex: payload.recipientPeerIdHex },
        });
        return;
      }
      traceLog(
        traceID,
        `push dispatched type=${payload.type} recipient=${payload.recipientPeerIdHex} badge=${payload.badgeCount}`
      );
      structuredLog("push.dispatched", {
        recipientPeerIdHex: payload.recipientPeerIdHex,
        type: payload.type,
        threadId: payload.threadId,
        badgeCount: payload.badgeCount,
        hasSender: payload.senderPeerIdHex !== null,
        traceID,
      });
    } catch (error) {
      traceLog(
        traceID,
        `env.AUTH.fetch error type=${payload.type} recipient=${payload.recipientPeerIdHex} error=${error instanceof Error ? error.message : String(error)}`
      );
      structuredLog("push.internal_fetch_failed", {
        recipientPeerIdHex: payload.recipientPeerIdHex,
        type: payload.type,
        error: error instanceof Error ? error.message : String(error),
        traceID,
      });
      Sentry.captureException(error, {
        tags: { component: "push-dispatch", operation: "push_trigger" },
        extra: { recipientPeerIdHex: payload.recipientPeerIdHex },
      });
      // Fire-and-forget — never break packet queuing on auth-worker outage.
    }
  }
}
