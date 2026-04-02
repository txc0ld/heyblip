# Blip Binary Protocol Specification

**Version:** 1.0
**Status:** Authoritative cross-platform contract
**Byte order:** All multi-byte integers are big-endian (network byte order)
**Target implementors:** iOS (Swift), Android (Kotlin)

---

## 1. Packet Structure

Every Blip packet on the wire has the following layout:

```
+-------------------+  offset 0
|  Header (16 B)    |
+-------------------+  offset 16
|  Sender ID (8 B)  |  always present
+-------------------+  offset 24
| Recipient ID (8 B)|  only if hasRecipient flag is set
+-------------------+  offset 24 or 32
|  Payload (var)     |  length defined by PayloadLength in header
+-------------------+
| Signature (64 B)  |  only if hasSignature flag is set
+-------------------+
```

---

## 2. Packet Header (16 bytes)

| Offset | Size | Field         | Type   | Description                                                |
|--------|------|---------------|--------|------------------------------------------------------------|
| 0      | 1    | Version       | UInt8  | Protocol version. Currently `0x01`.                        |
| 1      | 1    | Type          | UInt8  | Message type enum (see Section 4).                         |
| 2      | 1    | TTL           | UInt8  | Hop count remaining, valid range 0-7.                      |
| 3      | 8    | Timestamp     | UInt64 | Milliseconds since Unix epoch, big-endian.                 |
| 11     | 1    | Flags         | UInt8  | Bitmask of packet flags (see Section 3).                   |
| 12     | 4    | PayloadLength | UInt32 | Length of the payload section in bytes, big-endian.         |

**Total header:** 16 bytes, fixed.

---

## 3. Flags Bitmask

The Flags byte at header offset 11 is a bitmask with the following bit definitions:

| Bit | Mask   | Name          | Description                                        |
|-----|--------|---------------|----------------------------------------------------|
| 0   | `0x01` | hasRecipient  | Recipient ID (8 bytes) follows the Sender ID.      |
| 1   | `0x02` | hasSignature  | 64-byte Ed25519 signature is appended after payload.|
| 2   | `0x04` | isCompressed  | Payload is zlib-compressed (see Section 9).        |
| 3   | `0x08` | hasRoute      | Routing hint is included in the payload.           |
| 4   | `0x10` | isReliable    | Store-and-forward delivery requested.              |
| 5   | `0x20` | isPriority    | Priority packet (organizer broadcast or SOS).      |

**Common flag combinations:**

| Use case                       | Flags value |
|--------------------------------|-------------|
| Addressed + signed + reliable  | `0x13`      |
| Broadcast + signed             | `0x02`      |
| SOS priority                   | `0x32`      |

---

## 4. Message Types

All type values are single-byte identifiers stored in the header Type field.

### 4.1 Core Messaging

| Hex    | Name            | Description                                                  |
|--------|-----------------|--------------------------------------------------------------|
| `0x01` | announce        | Peer introduction (TLV-encoded: username, keys, capabilities, neighbor list). Avatar thumbnail sent separately via `0x22` after Noise handshake completes. |
| `0x02` | meshBroadcast   | Public location channel message.                             |
| `0x03` | leave           | Peer departing the mesh.                                     |

### 4.2 Encryption

| Hex    | Name            | Description                                                  |
|--------|-----------------|--------------------------------------------------------------|
| `0x10` | noiseHandshake  | Noise XX handshake init or response message.                 |
| `0x11` | noiseEncrypted  | All private payloads. First byte of decrypted payload is the encrypted sub-type (see Section 5). |

### 4.3 Data Transfer

| Hex    | Name            | Description                                                  |
|--------|-----------------|--------------------------------------------------------------|
| `0x20` | fragment        | Large message fragment (see Section 7).                      |
| `0x21` | syncRequest     | GCS (Golomb-Coded Set) filter for message reconciliation.    |
| `0x22` | fileTransfer    | Binary file payload (e.g., avatar thumbnails).               |
| `0x23` | pttAudio        | Real-time push-to-talk audio chunk (Opus).                   |

### 4.4 Event

| Hex    | Name              | Description                                                |
|--------|-------------------|------------------------------------------------------------|
| `0x30` | orgAnnouncement   | Event organizer broadcast (must be signed with organizer key). |
| `0x31` | channelUpdate     | Location channel metadata update.                          |

### 4.5 Medical / SOS

| Hex    | Name               | Description                                               |
|--------|--------------------|-----------------------------------------------------------|
| `0x40` | sosAlert           | Emergency alert: severity byte + fuzzy geohash location.  |
| `0x41` | sosAccept          | Medical responder claims the alert.                       |
| `0x42` | sosPreciseLocation | GPS coordinates encrypted to medical responders only.     |
| `0x43` | sosResolve         | Alert closed / resolved.                                  |
| `0x44` | sosNearbyAssist    | Proximity nudge to nearby peers to assist.                |

### 4.6 Location Sharing

| Hex    | Name             | Description                                                 |
|--------|------------------|-------------------------------------------------------------|
| `0x50` | locationShare    | Encrypted GPS/geohash sent to a specific friend.            |
| `0x51` | locationRequest  | "Where are you?" nudge to a friend.                         |
| `0x52` | proximityPing    | "I'm nearby" trigger broadcast.                             |
| `0x53` | iAmHereBeacon    | Dropped pin with label, shareable.                          |

---

## 5. Encrypted Sub-Types

When a packet has type `0x11` (noiseEncrypted), the first byte of the **decrypted** payload identifies the semantic content:

### 5.1 Messaging

| Hex    | Name              | Description                                                |
|--------|-------------------|------------------------------------------------------------|
| `0x01` | privateMessage    | DM text content.                                           |
| `0x02` | groupMessage      | Group chat text content.                                   |
| `0x03` | deliveryAck       | Delivery acknowledgement for a message ID.                 |
| `0x04` | readReceipt       | Read receipt for a message ID.                             |
| `0x05` | voiceNote         | Opus-encoded audio data.                                   |
| `0x06` | imageMessage      | Compressed JPEG/HEIF image.                                |
| `0x07` | friendRequest     | Friend request with username + phone hash.                 |
| `0x08` | friendAccept      | Friend accept with phone hash confirmation.                |
| `0x09` | typingIndicator   | Recipient should show typing dots.                         |
| `0x0A` | messageDelete     | Request to delete a previously sent message by ID.         |
| `0x0B` | messageEdit       | Edited content for a previously sent message by ID.        |

### 5.2 Profile

| Hex    | Name              | Description                                                |
|--------|-------------------|------------------------------------------------------------|
| `0x10` | profileRequest    | Request full-resolution profile picture.                   |
| `0x11` | profileResponse   | Full-resolution profile picture data.                      |

### 5.3 Group Management

| Hex    | Name                   | Description                                           |
|--------|------------------------|-------------------------------------------------------|
| `0x12` | groupKeyDistribution   | Sender key wrapped in the pairwise Noise session.     |
| `0x13` | groupMemberAdd         | Admin adds a member, triggers key distribution.       |
| `0x14` | groupMemberRemove      | Admin removes a member, triggers key rotation.        |
| `0x15` | groupAdminChange       | Ownership or admin transfer.                          |

### 5.4 Reputation

| Hex    | Name       | Description                                                      |
|--------|------------|------------------------------------------------------------------|
| `0x16` | blockVote  | Hashed user ID for mesh-level reputation (sent to direct peers). |

---

## 6. Variable Fields

| Field        | Size     | Condition                                                         |
|--------------|----------|-------------------------------------------------------------------|
| Sender ID    | 8 bytes  | Always present. SHA256(Noise public key)[0:8].                    |
| Recipient ID | 8 bytes  | Present only when `hasRecipient` (bit 0) is set. Broadcast address: `0xFFFFFFFFFFFFFFFF`. |
| Payload      | Variable | Length defined by the PayloadLength header field.                  |
| Signature    | 64 bytes | Present only when `hasSignature` (bit 1) is set. Ed25519 signature over the entire packet excluding the TTL field (offset 2, 1 byte) and the signature itself. |

### 6.1 Peer ID Derivation

```
PeerID = SHA256(noise_static_public_key)[0:8]   // first 8 bytes
```

### 6.2 Broadcast Address

```
0xFF 0xFF 0xFF 0xFF 0xFF 0xFF 0xFF 0xFF
```

### 6.3 Signature Scope

The Ed25519 signature covers:

- Header bytes 0-1 (Version + Type)
- Header bytes 3-15 (Timestamp + Flags + PayloadLength) -- skips TTL at offset 2
- Sender ID
- Recipient ID (if present)
- Payload

The signature does NOT cover:
- TTL (offset 2, 1 byte) -- because TTL changes as the packet is relayed
- The signature field itself

---

## 7. Fragmentation

Payloads exceeding 416 bytes (worst-case MTU: addressed + signed) are split into fragments.

### 7.1 Fragment Header (8 bytes)

| Offset | Size | Field      | Type   | Description                              |
|--------|------|------------|--------|------------------------------------------|
| 0      | 4    | FragmentID | Bytes  | Random 4-byte identifier for the group.  |
| 4      | 2    | Index      | UInt16 | 0-based fragment index, big-endian.      |
| 6      | 2    | Total      | UInt16 | Total fragment count, big-endian.        |

### 7.2 Fragment Packet

Fragment packets use message type `0x20` (fragment). The fragment header + fragment data constitute the payload of the enclosing packet.

### 7.3 Rules

| Parameter                      | Value              |
|--------------------------------|--------------------|
| Fragmentation threshold        | 416 bytes          |
| Max payload per fragment       | 408 bytes (416 - 8 byte fragment header) |
| Max concurrent assemblies      | 128 per peer       |
| Fragment lifetime              | 30 seconds         |
| Fragment TTL cap               | 5 hops             |
| Relay jitter per fragment      | 8-25 ms random     |

### 7.4 Assembly

The receiver collects fragments sharing the same FragmentID, indexed by their Index field. When all fragments (0 through Total-1) are received, the payload chunks are concatenated in index order to reconstruct the original payload. Expired or incomplete assemblies are discarded after 30 seconds. LRU eviction applies when the 128-assembly limit is reached.

---

## 8. Max Payload Sizes

| Configuration             | Calculation                    | Max Payload |
|---------------------------|--------------------------------|-------------|
| Broadcast, signed         | 512 - 16 - 8 - 64             | **424 bytes** |
| Broadcast, unsigned       | 512 - 16 - 8                  | **488 bytes** |
| Addressed, signed         | 512 - 16 - 8 - 8 - 64        | **416 bytes** |
| Addressed, unsigned       | 512 - 16 - 8 - 8              | **480 bytes** |

Effective BLE MTU: 512 bytes (requested 517, minus 5 bytes ATT overhead).

---

## 9. Compression Rules

Compression uses zlib (RFC 1950), applied to the payload before encryption or signing.

| Payload Size     | Action                                              |
|------------------|-----------------------------------------------------|
| < 100 bytes      | No compression.                                     |
| 100-256 bytes    | Compress; use compressed result only if smaller.     |
| > 256 bytes      | Always compress (zlib deflate).                      |
| Pre-compressed   | Skip (Opus audio, JPEG/HEIF images).                |

When compression is applied, set the `isCompressed` flag (bit 2, `0x04`) in the Flags byte.

On the receiving side, if `isCompressed` is set, decompress the payload with zlib inflate before processing.

---

## 10. Padding Rules

All packets are padded to block boundaries using PKCS#7-style padding for traffic analysis resistance.

### 10.1 Block Sizes

| Tier    | Boundary   |
|---------|------------|
| Tier 1  | 256 bytes  |
| Tier 2  | 512 bytes  |
| Tier 3  | 1024 bytes |
| Tier 4  | 2048 bytes |

For data exceeding 2048 bytes, pad to the next multiple of 256 bytes.

### 10.2 Padding Scheme

1. Compute the smallest block boundary that leaves between 1 and 256 bytes of padding.
2. All padding bytes have the same value: `padding_length mod 256` (0 means 256 bytes of padding).
3. The last byte of the padded data is always the padding indicator.

### 10.3 Unpadding

1. Read the last byte of the padded data.
2. If the value is 0, padding length is 256. Otherwise, padding length is the byte value.
3. Verify all padding bytes have the same value.
4. Strip the padding bytes to recover the original data.

---

## 11. BLE Configuration

| Parameter             | Value                                          |
|-----------------------|------------------------------------------------|
| Service UUID          | `FC000001-0000-1000-8000-00805F9B34FB`         |
| Characteristic UUID   | `FC000002-0000-1000-8000-00805F9B34FB`         |
| Debug Service UUID    | `FC000001-0000-1000-8000-00805F9B34FA`         |
| Requested MTU         | 517 bytes                                      |
| Effective MTU         | 512 bytes                                      |

### 11.1 Dual-Role Operation

Every device operates simultaneously as:
- **BLE Central** (scanner/client): discovers and connects to other Blip peripherals.
- **BLE Peripheral** (advertiser/server): advertises the service UUID and accepts connections.

### 11.2 Connection Limits

| Mode     | Max Central | Max Peripheral |
|----------|-------------|----------------|
| Normal   | 6           | 6              |
| Bridge   | 8           | 8              |
| Medical  | 10          | 10             |

### 11.3 State Restoration IDs

| Role       | Restoration ID                    |
|------------|-----------------------------------|
| Central    | `com.blip.ble.central`       |
| Peripheral | `com.blip.ble.peripheral`    |

---

## 12. Gossip Routing

### 12.1 Routing Algorithm

1. Receive packet.
2. Compute packet identifier: `sender_id (8B) + timestamp (8B) + type (1B) + payload_prefix (16B)`.
3. Check multi-tier Bloom filter. If seen: discard as duplicate.
4. If new: insert into Bloom filter, decrement TTL.
5. If TTL > 0: relay to all connected peers except the source.
6. Relay probability modulated by crowd density, packet urgency, freshness, and congestion.

### 12.2 SOS Override Rules

SOS packets (`0x40`-`0x44`) receive special treatment at any crowd density:

1. Use a separate SOS Bloom filter (10x lower density, <0.001% false positive rate).
2. Always relay (skip probability check).
3. Jump to front of the critical queue (Lane 0).
4. Skip TTL reduction for the first 3 hops (TTL 7, 6, 5 are not decremented).
5. Relay on all connections simultaneously.
6. Also send via internet (WebSocket) if available (dual-path delivery).

### 12.3 Relay Probability Formula

```
P(relay) = base_probability * urgency_factor * freshness_factor * congestion_factor

base_probability:  1.0 (peers < 10), 0.7 (10-30), 0.4 (30-60), 0.2 (> 60)
urgency_factor:    3.0 (SOS), 2.0 (announcements), 1.0 (DMs), 0.5 (broadcasts)
freshness_factor:  1.0 (< 5s old), 0.5 (5-30s), 0.1 (> 30s)
congestion_factor: 1.0 (queue < 50%), 0.5 (50-80%), 0.2 (> 80%)

Result capped at 1.0, floor at 0.05.
SOS always 1.0 regardless of formula.
```

### 12.4 Multi-Tier Bloom Filter

| Tier | Window        | Size  | Expected Elements | Purpose           |
|------|---------------|-------|-------------------|-------------------|
| Hot  | Last 60s      | 4 KB  | 500               | Fastest check     |
| Warm | Last 10 min   | 16 KB | 5,000             | Recent history    |
| Cold | Last 2 hours  | 64 KB | 50,000            | Extended dedup    |

Check order: Hot -> Warm -> Cold. Double-hashing reduces effective false-positive rate to ~0.01% per tier (~0.03% aggregate).

---

## 13. Cryptography Reference

| Component              | Algorithm / Pattern                          |
|------------------------|----------------------------------------------|
| Handshake              | Noise_XX_25519_ChaChaPoly_SHA256             |
| Session upgrade        | Noise_IK_25519_ChaChaPoly_SHA256 (known key) |
| AEAD cipher            | ChaChaPoly (ChaCha20-Poly1305)               |
| Key agreement          | Curve25519 ECDH                              |
| Signing                | Ed25519                                      |
| Hashing                | SHA-256                                      |
| Key derivation         | HKDF-SHA256                                  |
| Session cache TTL      | 4 hours                                      |
| Rekey trigger           | Every 1000 messages or 1 hour               |
| Replay protection      | Sliding window: 64-bit counter + 128-bit window |
| Nonce format           | 96-bit: 4 zero bytes + 8-byte LE counter     |
| Group encryption       | AES-256-GCM with per-sender Sender Key       |

---

## 14. Announcement Packet TLV Layout

The announce packet (`0x01`) payload is TLV-encoded. The packet must fit in a single BLE transmission (~488 bytes for broadcast, signed).

| Field             | Size         | Description                                |
|-------------------|--------------|--------------------------------------------|
| Username          | 1 + N bytes  | Length-prefixed UTF-8 string (max 32 bytes).|
| Noise public key  | 32 bytes     | Curve25519 static public key.              |
| Signing public key| 32 bytes     | Ed25519 public key.                        |
| Capabilities      | 2 bytes      | Feature flags bitmask.                     |
| Neighbor list     | 8 * N bytes  | PeerIDs of connected neighbors (max 8).    |
| Avatar hash       | 32 bytes     | SHA-256 of avatar thumbnail for cache validation. |

Avatar thumbnail (~2-4 KB) is sent separately via `fileTransfer` (`0x22`) after Noise handshake completion, as it exceeds single-packet capacity.

---

## 15. Store-and-Forward Cache Durations

| Content Type         | Cache Duration       |
|----------------------|----------------------|
| DMs                  | 2 hours              |
| Group messages       | 30 minutes           |
| Location channels    | 5 minutes            |
| Stage channels       | 5 minutes            |
| Organizer broadcasts | 1 hour               |
| SOS alerts           | Until resolved       |
| Voice/images         | Not cached (too large)|

---

## 16. Priority Hierarchy

| Priority | Traffic Type              | Congestion Behavior                    |
|----------|---------------------------|----------------------------------------|
| 0        | SOS / Medical emergency   | Never throttled, never dropped         |
| 1        | Organizer emergency       | Always relayed                         |
| 2        | Organizer announcements   | High relay probability                 |
| 3        | Text DMs (addressed)      | Efficient directed routing at scale    |
| 4        | Text group messages       | Relayed within member clusters         |
| 5        | Friend requests/accepts   | Small, one-time                        |
| 6        | Receipts + location shares| Dropped first under load               |
| 7        | Location channel broadcasts| Local cluster only                    |
| 8        | Sync/GCS reconciliation   | Deferred under congestion              |
| 9        | Voice notes on mesh       | Gather/Event modes only             |
| 10       | Images/files on mesh      | Gather mode only                       |
| 11       | Profile picture requests  | Lowest, internet-preferred             |

### Traffic Shaping Queues

| Lane | Name     | Traffic Types                      | Bandwidth Share |
|------|----------|------------------------------------|-----------------|
| 0    | Critical | SOS, emergency                     | Always first    |
| 1    | High     | DMs, friend requests               | 60% remaining   |
| 2    | Normal   | Groups, channels                   | 30% remaining   |
| 3    | Low      | Sync, profiles                     | 10% remaining   |

Rate limits: 20 packets/s inbound per peer, 15 packets/s outbound. Burst: 2x for 3 seconds.

---

## 17. Crowd-Scale Modes

| Mode    | Peer Estimate  | TTL (DM) | TTL (Group) | TTL (Broadcast) | TTL (SOS) |
|---------|----------------|----------|-------------|-----------------|-----------|
| Gather  | < 500          | 7        | 5           | 5               | 7         |
| Event| 500-5,000      | 5        | 4           | 3               | 7         |
| Mega    | 5,000-25,000   | 4        | 3           | 2               | 7         |
| Massive | 25,000-100,000+| 3        | 2           | suppressed      | 7         |

Detection: count unique peers seen in the last 5 minutes (direct + announced neighbors), smoothed with exponential moving average. 60-second hysteresis before mode switch.

---

## 18. Implementation Notes for Android/Kotlin

1. **Byte order:** All `putShort()`, `putInt()`, `putLong()` calls on `ByteBuffer` must use `ByteOrder.BIG_ENDIAN`.
2. **ChaChaPoly:** Use `javax.crypto.Cipher` with `ChaCha20-Poly1305` (API 28+) or Tink/Bouncy Castle for older APIs.
3. **Curve25519:** Use `java.security.KeyPairGenerator` with `XDH` (API 33+) or the Tink library.
4. **Ed25519:** Use `java.security.KeyPairGenerator` with `Ed25519` (API 33+) or Bouncy Castle.
5. **Bloom filter:** Implement the double-hashing scheme using `MessageDigest.getInstance("SHA-256")`. First 8 bytes = h1, next 8 bytes = h2.
6. **BLE:** Android BLE has a 517-byte MTU negotiation limit. Request MTU 517; effective payload after GATT overhead is 512 bytes.
7. **Background BLE:** Use `ForegroundService` with `FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE` for reliable background mesh operation.
8. **Zlib:** Use `java.util.zip.Deflater` (level 6) and `java.util.zip.Inflater`.
9. **Noise protocol:** The `noise-java` library or a manual implementation following the Noise Protocol Framework specification will both work.
10. **Padding:** The PKCS#7-like scheme is straightforward to implement with `Arrays.fill()` for padding bytes.
