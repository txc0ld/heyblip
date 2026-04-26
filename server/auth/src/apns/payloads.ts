/**
 * APNs payload factory.
 *
 * Builds the `{ apsPayload, headers }` tuple for each push type. All mapping
 * tables (title/body/sound/interruption-level/apns-push-type/apns-priority/
 * apns-expiration/apns-collapse-id) live here — the client is dumb, the
 * factory is the spec.
 */

export type PushType =
  | "friend_request"
  | "friend_accept"
  | "dm"
  | "group_message"
  | "group_mention"
  | "voice_note"
  | "sos"
  | "silent_badge_sync";

export interface BuildPayloadInput {
  type: PushType;
  senderUsername: string | null;
  channelName: string | null;
  threadId: string | null;
  senderPeerIdHex: string | null;
  badgeCount: number;
  deeplink: string | null;
}

export interface ApsAlert {
  title: string;
  body: string;
}

export interface ApsPayload {
  aps: {
    alert?: ApsAlert | null;
    badge?: number;
    sound?: string | null;
    "thread-id"?: string;
    "mutable-content"?: number;
    "interruption-level"?: "passive" | "active" | "time-sensitive" | "critical";
    "content-available"?: number;
  };
  blip: {
    type: PushType;
    threadId: string | null;
    senderPeerIdHex: string | null;
    senderUsername: string | null;
    deeplink: string | null;
    badgeCount: number;
  };
}

export interface ApnsHeaders {
  "apns-push-type": "alert" | "background";
  "apns-priority": "10" | "5";
  "apns-expiration": string;
  "apns-collapse-id"?: string;
}

export interface BuildPayloadOutput {
  apsPayload: ApsPayload;
  headers: ApnsHeaders;
}

const DEFAULT_DISPLAY = "Someone";

function strings(type: PushType, senderUsername: string | null, channelName: string | null): ApsAlert | null {
  const sender = senderUsername ?? null;
  const channel = channelName ?? null;
  switch (type) {
    case "friend_request":
      return {
        title: "Friend request",
        body: `${sender ?? DEFAULT_DISPLAY} wants to connect`,
      };
    case "friend_accept":
      return {
        title: "Friend request accepted",
        body: `${sender ?? DEFAULT_DISPLAY} accepted your friend request`,
      };
    case "dm":
      return {
        title: sender ?? "New message",
        body: "Sent you a message",
      };
    case "group_message":
      return {
        title: channel ?? "New message",
        body: `${sender ?? DEFAULT_DISPLAY} sent a message`,
      };
    case "group_mention":
      return {
        title: channel ?? "Mention",
        body: `${sender ?? DEFAULT_DISPLAY} mentioned you`,
      };
    case "voice_note":
      return {
        title: sender ?? "New voice note",
        body: "Sent a voice note",
      };
    case "sos":
      return {
        title: "Emergency nearby",
        body: "Someone nearby needs help",
      };
    case "silent_badge_sync":
      return null;
  }
}

function sound(type: PushType): string | null {
  if (type === "sos") return "sos_critical.caf";
  if (type === "silent_badge_sync") return null;
  return "default";
}

function interruptionLevel(
  type: PushType
): "passive" | "active" | "time-sensitive" | "critical" | null {
  switch (type) {
    case "friend_request":
    case "friend_accept":
      return "passive";
    case "dm":
    case "group_message":
    case "voice_note":
      return "active";
    case "group_mention":
      return "time-sensitive";
    case "sos":
      return "critical";
    case "silent_badge_sync":
      return null;
  }
}

function headersFor(type: PushType, threadId: string | null): ApnsHeaders {
  switch (type) {
    case "friend_request":
    case "friend_accept":
      return {
        "apns-push-type": "alert",
        "apns-priority": "10",
        "apns-expiration": "86400",
      };
    case "dm":
      return {
        "apns-push-type": "alert",
        "apns-priority": "10",
        "apns-expiration": "3600",
        ...(threadId ? { "apns-collapse-id": `dm:${threadId}` } : {}),
      };
    case "group_message":
      return {
        "apns-push-type": "alert",
        "apns-priority": "10",
        "apns-expiration": "3600",
        ...(threadId ? { "apns-collapse-id": `group:${threadId}` } : {}),
      };
    case "group_mention":
    case "voice_note":
      return {
        "apns-push-type": "alert",
        "apns-priority": "10",
        "apns-expiration": "3600",
      };
    case "sos":
      return {
        "apns-push-type": "alert",
        "apns-priority": "10",
        "apns-expiration": "0",
      };
    case "silent_badge_sync":
      return {
        "apns-push-type": "background",
        "apns-priority": "5",
        "apns-expiration": "0",
      };
  }
}

export function buildPayload(input: BuildPayloadInput): BuildPayloadOutput {
  const { type, threadId, senderPeerIdHex, senderUsername, badgeCount, deeplink } = input;
  const alert = strings(type, senderUsername, input.channelName);
  const snd = sound(type);
  const level = interruptionLevel(type);
  const headers = headersFor(type, threadId);

  const isSilent = type === "silent_badge_sync";

  const aps: ApsPayload["aps"] = {};

  if (isSilent) {
    aps.alert = null;
    aps.sound = null;
    aps["content-available"] = 1;
    aps.badge = badgeCount;
  } else {
    if (alert) aps.alert = alert;
    aps.badge = badgeCount;
    if (snd) aps.sound = snd;
    aps["mutable-content"] = 1;
  }

  if (threadId) {
    aps["thread-id"] = threadId;
  }
  if (level) {
    aps["interruption-level"] = level;
  }

  const apsPayload: ApsPayload = {
    aps,
    blip: {
      type,
      threadId,
      senderPeerIdHex,
      senderUsername,
      deeplink,
      badgeCount,
    },
  };

  return { apsPayload, headers };
}

/**
 * Build the default deeplink URL for a push based on type + threadId. Returns
 * null when the combination doesn't map to a canonical route — iOS falls back
 * to the app root in that case.
 */
export function defaultDeeplink(
  type: PushType,
  threadId: string | null,
  senderPeerIdHex: string | null
): string | null {
  switch (type) {
    case "dm":
    case "group_message":
    case "group_mention":
    case "voice_note":
      return threadId ? `blip://channel/${threadId}` : null;
    case "friend_request":
    case "friend_accept":
      return senderPeerIdHex ? `blip://friend/${senderPeerIdHex}` : null;
    case "sos":
      return threadId ? `blip://sos/${threadId}` : null;
    case "silent_badge_sync":
      return null;
  }
}
