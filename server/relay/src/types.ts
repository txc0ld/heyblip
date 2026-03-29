/**
 * Blip relay server types.
 *
 * These mirror the binary protocol from Packet.swift — the relay only
 * reads enough of the header to extract the recipient PeerID for routing.
 */

/** Hex-encoded 8-byte PeerID string (16 hex chars). */
export type PeerIDHex = string;

/** Fixed header size in bytes. */
export const HEADER_SIZE = 16;

/** PeerID size in bytes. */
export const PEER_ID_LENGTH = 8;

/** Curve25519 public key size in bytes. */
export const PUBLIC_KEY_LENGTH = 32;

/**
 * Header byte offsets (from PacketSerializer.swift):
 *   0:     version  (UInt8)
 *   1:     type     (UInt8)
 *   2:     ttl      (UInt8)
 *   3-10:  timestamp (UInt64 big-endian)
 *   11:    flags    (UInt8)
 *   12-15: payloadLength (UInt32 big-endian)
 */
export const OFFSET_FLAGS = 11;
export const OFFSET_SENDER_ID = HEADER_SIZE; // 16
export const OFFSET_RECIPIENT_ID = HEADER_SIZE + PEER_ID_LENGTH; // 24

/** PacketFlags bit masks (from PacketFlags.swift). */
export const FLAG_HAS_RECIPIENT = 0x01;

/** Minimum packet size: header + sender PeerID. */
export const MIN_PACKET_SIZE = HEADER_SIZE + PEER_ID_LENGTH;

/** Minimum packet size with recipient: header + sender + recipient. */
export const MIN_ADDRESSED_PACKET_SIZE = HEADER_SIZE + PEER_ID_LENGTH + PEER_ID_LENGTH;

/** Env bindings for the Worker. */
export interface Env {
  RELAY_ROOM: DurableObjectNamespace;
}

/** Convert raw bytes to hex-encoded PeerID. */
export function bytesToHex(bytes: Uint8Array): PeerIDHex {
  let hex = "";
  for (let i = 0; i < bytes.length; i++) {
    hex += bytes[i].toString(16).padStart(2, "0");
  }
  return hex;
}
