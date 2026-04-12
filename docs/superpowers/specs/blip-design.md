# Blip — Design Specification

**Version:** 1.0
**Date:** 2026-03-28
**Status:** Approved
**Platform:** iOS 16.0+ / macOS 13.0+ (iOS-first, Android planned)

---

## 1. Product Overview

### 1.1 What is Blip?

Blip is a Bluetooth mesh chat application designed for events and large gatherings where mobile reception is unreliable. Every user's device becomes a node in a self-forming mesh network, relaying messages between peers via Bluetooth Low Energy (BLE). WiFi and cellular act as automatic fallbacks when available.

### 1.2 Core value proposition

"Chat at events, even without signal."

- No accounts, no servers required for core messaging
- Messages relay through other users' devices automatically
- End-to-end encrypted — relay nodes cannot read messages
- Works with zero internet connectivity
- Scales from 50 people at a campfire to 100,000 at Glastonbury

### 1.3 Target platforms

| Platform | Version | Build system | Status |
|---|---|---|---|
| iOS | 16.0+ | Xcode + XcodeGen / SPM | Primary (this spec) |
| macOS | 13.0+ | Same codebase (universal) | Primary (this spec) |
| Android | 8.0+ (API 26) | TBD | Planned, full protocol compat |

### 1.4 Monetization

Message-based monetization with free tier:

| Tier | Messages | Price |
|---|---|---|
| Free | 10 (on signup) | $0.00 |
| Starter | 10 | $0.99 |
| Social | 25 | $1.99 |
| Event | 50 | $3.99 |
| Squad | 100 | $5.99 |
| Season Pass | 1000 | $29.99 |
| Unlimited | Subscription (monthly/seasonal) | TBD |

**What counts as a message:** 1 text, 1 voice note, 1 image, or 1 PTT session = 1 message. Location channel broadcasts, friend requests/accepts, delivery/read receipts = free. Receiving messages = always free. Organizer announcements = always free.

**Subscribers** receive a subtle accent ring on their avatar.

---

## 2. Architecture

### 2.1 System architecture

```
+-----------------------------------------------------+
|                   Blip App                      |
|  +-----------------------------------------------+  |
|  |              SwiftUI Views                     |  |
|  |  Chat - DMs - Groups - Channels - Map - PTT   |  |
|  +----------------------+------------------------+  |
|                         |                            |
|  +----------------------v------------------------+  |
|  |           ChatViewModel (MVVM)                 |  |
|  |  Message routing - Channel mgmt - State        |  |
|  +------+------------+-------------+-------------+  |
|         |            |             |                 |
|  +------v--+ +------v------+ +---v-----------+     |
|  | Crypto  | |  Protocol   | |  Persistence  |     |
|  | Package | |  Package    | |  (SwiftData)  |     |
|  |         | |             | |               |     |
|  |Noise XX | |Packets      | |Messages       |     |
|  |Ed25519  | |Fragments    | |Peers          |     |
|  |Keychain | |Bloom/GCS    | |Channels       |     |
|  |         | |Compression  | |Message Packs  |     |
|  +---------+ +-------------+ +---------------+     |
|         |           |                                |
|  +------v-----------v----------------------------+  |
|  |         Transport Layer (Protocol)             |  |
|  |  +---------+  +----------+  +--------------+  |  |
|  |  |   BLE   |  |  WiFi    |  |   Cellular   |  |  |
|  |  |  Mesh   |  |  Direct  |  |  (WebSocket) |  |  |
|  |  |(primary)|  |(fallback)|  |  (fallback)  |  |  |
|  |  +---------+  +----------+  +--------------+  |  |
|  +------------------------------------------------+  |
+------------------------------------------------------+
```

### 2.2 Approach

Pure Swift with modular Swift packages. SwiftUI for all UI. MVVM pattern. No shared cross-platform core — the binary protocol specification is the cross-platform contract. Android will implement the same spec in Kotlin for full interoperability.

### 2.3 Swift packages

| Package | Responsibility |
|---|---|
| `BlipProtocol` | Binary packet format, serialization, Bloom filters, GCS sync, fragmentation, compression, padding |
| `BlipMesh` | BLE central/peripheral, peer discovery, gossip routing, store-and-forward, transport abstraction, congestion control |
| `BlipCrypto` | Noise XX handshake, Ed25519 signing, key management (Keychain), replay protection |

### 2.4 Lightweight backend (minimal server-side)

A thin backend is required for four specific functions. Everything else is P2P.

| Service | Purpose | Implementation |
|---|---|---|
| Phone verification | SMS OTP for identity confirmation | Twilio Verify API or Firebase Auth |
| Event manifest | JSON list of registered events, stages, schedules | Static JSON on GitHub Pages / CDN |
| StoreKit validation | Server-side receipt verification for IAP | Lightweight API (Cloudflare Workers / Vercel Edge) |
| Push notifications | Wake app for internet-side messages when backgrounded | APNs via lightweight relay |

**Design principle:** The backend is stateless where possible, zero-knowledge about message content, and the app functions fully without it (except phone verification and IAP).

---

## 3. Identity & Accounts

### 3.1 Identity model

- Username-based identity with phone number verification
- Cryptographic keypair generated on first launch
- No email, no social login, no password

### 3.2 Key generation (first launch)

| Key | Algorithm | Storage | Purpose |
|---|---|---|---|
| Noise static key | Curve25519 | iOS Keychain | E2E encryption (Noise XX handshake) |
| Signing key | Ed25519 | iOS Keychain | Packet authentication |
| Peer ID | SHA256(Noise public key), first 8 bytes | Derived | Network identifier |

### 3.3 User profile

| Field | Required | Public | Storage |
|---|---|---|---|
| Username | Yes | Yes | SwiftData + announced on mesh |
| Display name | No | Yes | SwiftData + announced on mesh |
| Phone number | Yes | **Never** | Keychain (raw), SwiftData (hash only) |
| Profile picture | No | Yes (thumbnail) | SwiftData (thumbnail 64x64 + full-res cached) |
| Bio | No | Yes | SwiftData (140 chars max) |
| Noise public key | Auto | Yes (in announcements) | Keychain |
| Signing public key | Auto | Yes (in announcements) | Keychain |

### 3.4 Phone verification

- SMS OTP via Twilio Verify (or Firebase Auth)
- Phone number stored as `SHA256(phone + app_salt)` in SwiftData
- Raw phone number stored ONLY in Keychain for re-verification
- Phone hash shared during friend requests for mutual verification
- Phone number NEVER displayed in UI, NEVER sent in plaintext over mesh

### 3.5 Account recovery

- **Keychain backup via iCloud Keychain:** Keys survive device migration if user has iCloud Keychain enabled
- **Manual backup:** Settings > Export Recovery Kit — generates encrypted backup of keypair (password-protected, AES-256-GCM)
- **New device without backup:** New keypair generated, re-verify phone number, friends see "Username has a new device" — must re-accept to re-establish Noise sessions
- **No server-side key storage.** Ever.

---

## 4. Chat System

### 4.1 Chat modes

| Mode | Description | Encryption | Persistence |
|---|---|---|---|
| DM | 1-on-1 private messages | Noise XX E2E | Forever on device, 2hr mesh relay cache |
| Group | Invite-only group chat | Sender Key E2E (see 4.5) | Forever on device, 30min mesh relay cache |
| Location channel | Auto-joined by proximity/geohash | Signed but not encrypted (public) | 24hr on device, 5min mesh relay cache |
| Stage channel | Event-specific, auto-joined by geofence | Signed but not encrypted (public) | Duration of event, 5min mesh relay cache |
| Lost & Found | Per-event public channel | Signed but not encrypted | Duration of event |
| Emergency | Medical/SOS channel | Encrypted to medical responders only | Event + 24hr, then hard delete |

### 4.2 Media types

| Type | Format | Max size | Mesh transport | Crowd scaling |
|---|---|---|---|---|
| Text | UTF-8 | 4KB | Always | Always available |
| Voice note | Opus codec | 30s (15s in Event mode) | Gather + Event | Mega+: internet only |
| Image | JPEG/HEIF compressed | 500KB | Gather only | Event+: internet only |
| PTT audio | Opus 8-16kbps real-time | 30s session | Gather + Event | Mega+: internet only |

### 4.3 Message delivery states

```
composing -> queued -> sent -> delivered -> read
```

- `composing`: User is typing (typing indicator sent to recipient)
- `queued`: Message composed, waiting for transport
- `sent`: Message left the device onto mesh or internet
- `delivered`: Delivery ACK received from recipient device
- `read`: Read receipt received

### 4.4 Reply threading

Messages can be sent as replies to a specific earlier message via the `replyTo` relationship in the Message model. The UI displays the quoted original above the reply. Reply chains are flat (no nested threading) — all replies reference the root message.

### 4.5 Group encryption

Groups use a **Sender Key** scheme to avoid per-member fan-out:

1. When a user joins a group, they generate a random symmetric **sender key** (AES-256-GCM).
2. The sender key is distributed to each group member individually via their existing pairwise Noise session (one-time cost on join).
3. When sending a group message, the sender encrypts once with their sender key. All members decrypt with the same key.
4. Result: 1 encrypted packet per group message (not N-1), regardless of group size.

**Key rotation triggers:**
- A member leaves or is removed -> new sender key generated and distributed
- A member is blocked -> new sender key, excluded from distribution
- Every 100 messages -> automatic rotation for forward secrecy
- Admin role change -> no rotation needed (sender keys are per-member, not per-role)

**Group management packet types:**
- `groupKeyDistribution` (encrypted sub-type 0x12): sender key wrapped in pairwise Noise session
- `groupMemberAdd` (encrypted sub-type 0x13): admin adds member, triggers key distribution
- `groupMemberRemove` (encrypted sub-type 0x14): admin removes member, triggers key rotation
- `groupAdminChange` (encrypted sub-type 0x15): ownership/admin transfer

**Group size limits (tied to crowd-scale mode):**

| Crowd mode | Max group size | Rationale |
|---|---|---|
| Gather | 50 members | Plenty of bandwidth |
| Event | 30 members | Conserve relay capacity |
| Mega | 20 members | Text-only, keep traffic manageable |
| Massive | 10 members | Minimal mesh overhead |

Existing groups above the limit continue to function but cannot add new members until crowd density decreases.

**Congestion impact:** Since sender key encryption produces 1 packet per message (not N-1), group messages have the same mesh impact as DMs. The traffic shaping in Section 8 applies without modification.

### 4.7 Walkie-talkie (PTT)

- Floating button in DMs and group chats
- Hold to talk, release to send
- Visual: expanding concentric ring animation (sonar ripple) while held
- Audio: real-time Opus encoding, streamed via `pttAudio` packets
- Graceful degradation: real-time over BLE mesh -> voice note over internet -> queued voice note if offline
- Max duration: 30s (auto-stops with haptic warning at 25s)

---

## 5. Bluetooth Mesh Network

### 5.1 BLE configuration

| Parameter | Value |
|---|---|
| Service UUID | `FC000001-0000-1000-8000-00805F9B34FB` |
| Characteristic UUID | `FC000002-0000-1000-8000-00805F9B34FB` |
| Debug Service UUID | `FC000001-0000-1000-8000-00805F9B34FA` |
| Requested MTU | 517 bytes |
| Effective MTU | 512 bytes |

**Max payload per packet (exact arithmetic):**

| Configuration | Calculation | Max payload |
|---|---|---|
| Broadcast, signed | 512 - 16 (header) - 8 (sender) - 64 (sig) | **424 bytes** |
| Broadcast, unsigned | 512 - 16 - 8 | **488 bytes** |
| Addressed, signed | 512 - 16 - 8 (sender) - 8 (recipient) - 64 (sig) | **416 bytes** |
| Addressed, unsigned | 512 - 16 - 8 - 8 | **480 bytes** |

**Fragmentation threshold: 416 bytes** (worst case: addressed + signed). All payloads exceeding 416 bytes are fragmented regardless of flags, ensuring they fit in any packet configuration.

### 5.2 Dual-role operation

Every device operates as BOTH a BLE Central (scanner/client) and BLE Peripheral (advertiser/server) simultaneously. This is essential for mesh formation.

- **Central mode:** `CBCentralManager` scans for Blip service UUID, connects to discovered peripherals, subscribes to characteristic
- **Peripheral mode:** `CBPeripheralManager` advertises service UUID, accepts connections, notifies subscribers
- **State restoration:** Background BLE operation via `CBCentralManager` and `CBPeripheralManager` state restoration IDs

### 5.3 Peer discovery

1. Device advertises Blip service UUID via BLE peripheral
2. Central scans for that UUID, connects
3. On connection: exchange Announcement packets (TLV-encoded, must fit single packet ~488 bytes):
   - Username (max 32 bytes UTF-8)
   - Noise public key (32 bytes, Curve25519)
   - Ed25519 signing public key (32 bytes)
   - Capabilities flags (2 bytes)
   - Neighbor peer ID list (8 bytes x N, max 8 neighbors = 64 bytes)
   - Avatar hash (32 bytes SHA256 of thumbnail, for cache validation)
   - NOTE: Avatar thumbnail (~2-4KB) sent separately via `fileTransfer` (0x22) after Noise handshake completes, as it exceeds single-packet capacity
4. Noise XX handshake initiated for E2E channel
5. Peer added to local peer table

### 5.4 Connection management

- Max central connections: 6 (normal), 8 (bridge), 10 (medical)
- Max peripheral connections: same as central
- Peer selection: scored by RSSI (sweet spot -60 to -70dBm), diversity (different clusters preferred), stability (longer connections preferred), bridge status
- Evaluation interval: every 30 seconds
- Swap hysteresis: new peer must score 20%+ higher than worst current peer
- Connect timeout backoff: 120 seconds for recently timed-out peripherals
- Dynamic RSSI threshold: default -90dBm, relaxed to -92 in isolation

### 5.5 Gossip routing

1. Receive packet -> hash packet ID -> check multi-tier Bloom filter
2. If seen: discard
3. If new: add to Bloom filter, decrement TTL
4. If TTL > 0: relay to all connected peers except source
5. Relay probability modulated by crowd-scale mode and packet priority

### 5.6 Store-and-forward

| Content type | Mesh relay cache duration |
|---|---|
| DMs | 2 hours |
| Group messages | 30 minutes |
| Location/stage channels | 5 minutes |
| Organizer announcements | 1 hour |
| SOS alerts | Until resolved or event ends |
| Voice/images | Not cached on relay nodes (too large) |

### 5.7 Fragmentation

- Payloads > 416 bytes split into fragments (worst-case: addressed + signed packet)
- Fragment header: `fragmentID (4 bytes) + index (2 bytes) + total (2 bytes)`
- Max 128 concurrent fragment assemblies per peer
- Fragment lifetime: 30 seconds
- Fragment TTL: capped at 5 hops
- Relay jitter: 8-25ms random delay per fragment relay

### 5.8 GCS sync (Golomb-Coded Sets)

- Peers exchange compact GCS filters of recently-seen message IDs
- Missing messages requested and re-transmitted
- Max filter size: 400 bytes, target false positive rate: 1%
- Sync intervals: 15s for messages, 30s for fragments, 60s for file transfers

### 5.9 iOS background BLE behavior

iOS heavily restricts background BLE operations. The app must handle these constraints:

**Background scanning:**
- iOS controls scan intervals in background — typically 1-3 second scans every ~30 seconds (vs continuous in foreground)
- Can only scan for specific service UUIDs (already satisfied by our service UUID filter)
- Scanning continues indefinitely if the app has the `bluetooth-central` background mode

**Background advertising:**
- Local name and service data are removed from advertisements by iOS
- Only the service UUID is advertised
- Other Blip devices can still discover via UUID, but the announcement packet exchange happens after connection (not during advertisement)

**State restoration recovery flow:**
1. App is suspended/terminated by iOS
2. BLE event occurs (peer connects, data received)
3. iOS relaunches app in background with restoration state
4. `AppDelegate` receives `willRestoreState` callback with peripheral/central state
5. App rebuilds peer table from restoration data + cached peer records in SwiftData
6. Existing Noise sessions resume from Keychain-backed cache (see Section 7.2)
7. GCS sync triggered immediately to reconcile missed messages

**Expected behavior:** In background, the app is a less active but still functional mesh participant. Message relay continues. Discovery is slower. The user's messages are still received and queued for notification. Foreground return triggers an immediate full scan + GCS sync burst.

### 5.10 Fallback transports

**WiFi Direct (v2, not in v1):** WiFi Direct peer discovery and data transfer is planned for v2. It offers higher bandwidth (~250 Mbps vs BLE's ~2 Mbps) and longer range (~200m vs ~50m) but requires explicit pairing on iOS (no background discovery). Marked as future enhancement.

**Cellular WebSocket (v1, basic):**
- WebSocket endpoint: `wss://relay.blip.app/ws`
- Authentication: Noise static public key sent as bearer token (no passwords, no accounts)
- Message format: identical binary protocol packets wrapped in WebSocket binary frames
- Server is a dumb relay — receives packets, forwards to connected peers based on recipient ID
- Server stores NOTHING — zero-knowledge relay. Messages not decryptable by server.
- Used when: BLE mesh has no path to recipient AND internet is available
- Handoff: `TransportCoordinator` checks BLE first (100ms timeout), then queues for WebSocket
- Reconnection: exponential backoff from 1s to 60s, max 10 attempts
- Server infrastructure: Cloudflare Workers with Durable Objects (WebSocket support, global edge)

**Transport priority:**
1. BLE mesh (always attempted first)
2. WebSocket relay (if BLE has no path and internet available)
3. Queue locally (if neither available, deliver when either becomes available)

### 5.11 Bloom filter false positive mitigation

The multi-tier Bloom filter (Section 8.7) has ~0.3% aggregate false positive rate. At high packet volumes, this means some legitimate packets are incorrectly discarded. Mitigation strategy:

**For non-SOS traffic:**
- Acceptable loss rate: < 0.5% of unique messages (within normal mesh loss expectations)
- GCS sync (Section 5.8) is the primary recovery mechanism — peers reconcile message IDs every 15 seconds, requesting any messages they missed
- Expected recovery latency: 15-30 seconds for most messages
- Double-hashing: each packet ID is hashed with two independent hash functions; both must match in the Bloom filter to be considered "seen" (reduces false positive rate to ~0.01% per tier)

**For SOS traffic:**
- Separate SOS Bloom filter (Section 8.9) with 10x lower density (fewer entries, much lower false positive rate)
- SOS packets include a monotonic sequence number per sender; if a gap is detected, the missing SOS is explicitly requested from the sender's neighbors
- Effective SOS false positive rate: < 0.001%

---

## 6. Binary Protocol Specification

### 6.1 Packet header (16 bytes)

| Offset | Size | Field | Description |
|---|---|---|---|
| 0 | 1 | Version | Protocol version (0x01) |
| 1 | 1 | Type | MessageType enum |
| 2 | 1 | TTL | Hop count, 0-7 |
| 3 | 8 | Timestamp | UInt64 milliseconds since epoch, big-endian |
| 11 | 1 | Flags | Bitmask (see below) |
| 12 | 4 | PayloadLength | UInt32, big-endian |

### 6.2 Flags bitmask

| Bit | Mask | Name | Description |
|---|---|---|---|
| 0 | 0x01 | hasRecipient | Recipient ID follows sender ID |
| 1 | 0x02 | hasSignature | 64-byte Ed25519 signature appended |
| 2 | 0x04 | isCompressed | Payload is zlib compressed |
| 3 | 0x08 | hasRoute | Routing hint included |
| 4 | 0x10 | isReliable | Store-and-forward requested |
| 5 | 0x20 | isPriority | Priority packet (organizer/SOS) |

### 6.3 Variable fields

| Field | Size | Condition |
|---|---|---|
| Sender ID | 8 bytes | Always present |
| Recipient ID | 8 bytes | If hasRecipient; `0xFFFFFFFFFFFFFFFF` = broadcast |
| Payload | Variable | Defined by Type field |
| Signature | 64 bytes | If hasSignature; Ed25519, excludes TTL from signed data |

### 6.4 Message types

```
-- Core messaging
0x01  announce            Peer introduction (TLV: username, keys, capabilities, neighbors)
                          NOTE: avatar thumbnail sent separately via 0x22 fileTransfer after handshake
0x02  meshBroadcast       Public location channel message
0x03  leave               Peer departing mesh

-- Encryption
0x10  noiseHandshake      Noise XX init/response
0x11  noiseEncrypted      All private payloads (see encrypted sub-types)

-- Data transfer
0x20  fragment            Large message fragment
0x21  syncRequest         GCS filter for reconciliation
0x22  fileTransfer        Binary file payload
0x23  pttAudio            Real-time push-to-talk chunk

-- Event
0x30  orgAnnouncement     Event organizer broadcast
0x31  channelUpdate       Location channel metadata

-- Medical/SOS
0x40  sosAlert            Priority: severity + fuzzy location
0x41  sosAccept           Responder claimed alert
0x42  sosPreciseLocation  GPS coords (encrypted to medical only)
0x43  sosResolve          Alert closed
0x44  sosNearbyAssist     Proximity nudge to nearby peers

-- Location sharing
0x50  locationShare       Encrypted GPS/geohash to specific friend
0x51  locationRequest     "Where are you?" nudge
0x52  proximityPing       "I'm nearby" trigger
0x53  iAmHereBeacon       Dropped pin with label
```

### 6.5 Encrypted sub-types (first byte of decrypted noiseEncrypted payload)

```
0x01  privateMessage      DM text
0x02  groupMessage        Group chat text
0x03  deliveryAck         Message delivered
0x04  readReceipt         Message read
0x05  voiceNote           Opus-encoded audio
0x06  imageMessage        Compressed image
0x07  friendRequest       Request with username + phone hash (only route for friend ops)
0x08  friendAccept        Accept with phone hash confirmation (only route for friend ops)
0x09  typingIndicator     Recipient should show typing dots
0x0A  messageDelete       Request to delete a sent message by ID
0x0B  messageEdit         Edited content for a sent message by ID
0x10  profileRequest      Request full-res profile picture
0x11  profileResponse     Full-res profile picture data
0x12  groupKeyDistribution  Sender key wrapped in pairwise Noise session
0x13  groupMemberAdd      Admin adds member
0x14  groupMemberRemove   Admin removes member
0x15  groupAdminChange    Ownership/admin transfer
0x16  blockVote           Hashed user ID for mesh-level reputation (sent to direct peers)
```

### 6.6 Packet padding

All packets padded to nearest block boundary using PKCS#7:
- 256, 512, 1024, or 2048 bytes
- Resists traffic analysis

### 6.7 Compression

| Payload size | Action |
|---|---|
| < 100 bytes | No compression |
| 100-256 bytes | Compress if smaller |
| > 256 bytes | Always compress (zlib level 6) |
| Pre-compressed (Opus/JPEG) | Skip |

### 6.8 Byte order

All multi-byte integers are big-endian (network byte order).

---

## 7. Cryptography

### 7.1 Noise Protocol

- Pattern: `Noise_XX_25519_ChaChaPoly_SHA256`
- XX pattern: mutual authentication, no pre-shared keys needed
- Three-message handshake: initiator ephemeral -> responder ephemeral + static -> initiator static
- Result: bidirectional transport ciphers with forward secrecy
- Re-keying: every 1000 messages or 1 hour, whichever comes first
- Replay protection: sliding window nonce (64-bit counter + 128-bit window)

### 7.2 Session resumption and caching

Noise XX requires a 3-message handshake, which is expensive for frequently dropped BLE connections. To mitigate:

- **Session cache:** Completed Noise sessions are cached in memory for 4 hours (keyed by peer ID). If a peer reconnects within this window, the existing cipher states resume without re-handshaking.
- **IK pattern upgrade:** For peers whose static key is already known (from a prior XX handshake), subsequent connections use `Noise_IK_25519_ChaChaPoly_SHA256` — a 2-message handshake that skips the responder's static key transmission. This saves one round-trip.
- **Session expiry:** Cached sessions expire after 4 hours or after the device enters Ultra-low battery mode. Expired sessions trigger a fresh XX handshake on next connection.
- **NoiseSession model updates:** Add `expiresAt: Date` (4 hours from establishment) and `peerStaticKeyKnown: Bool` (enables IK upgrade on reconnect).

### 7.3 Signing

- Algorithm: Ed25519
- Signed data: entire packet EXCLUDING TTL field (TTL changes during relay)
- All broadcast/public packets are signed for authenticity
- All encrypted packets are signed inside the Noise session

### 7.4 Phone hash

```
SHA256(phone_number_e164 + per_user_salt)
```

- `per_user_salt`: 32 random bytes generated on first launch, stored in Keychain
- Salt is exchanged inside the Noise-encrypted friend request payload (never in plaintext)
- Both sides compute `SHA256(their_phone + friend's_salt)` and compare with the hash received
- This prevents precomputed rainbow tables — each user's hash is unique even for the same phone number
- Computed locally on device
- Phone hash shared ONLY during friend request/accept (inside Noise-encrypted payload)
- Raw phone number never transmitted

### 7.5 Key storage

All keys stored in iOS Keychain with:
- `kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlock`
- Keychain access group for app extensions (share extension)
- iCloud Keychain sync eligible for device migration

---

## 8. Congestion Management & Scalability

### 8.1 Crowd-scale modes

The app auto-detects crowd density and adapts its entire operating profile.

**Detection:** Count unique peers seen in last 5 minutes (direct + announced neighbors). Smoothed with exponential moving average. 60-second hysteresis before mode switch.

| Mode | Peer estimate | Mesh features | Media on mesh |
|---|---|---|---|
| Gather | < 500 | Full features, relaxed relay | All media types |
| Event | 500 - 5,000 | Moderate throttle | Text + compressed voice (8kbps, 15s max) |
| Mega | 5,000 - 25,000 | Text-first, tight relay | Text only |
| Massive | 25,000 - 100,000+ | Text-only, aggressive clustering | Text only, all media internet-only |

### 8.2 Priority hierarchy

Priority 0 through 11, where 0 is highest:

| Priority | Traffic type | Congestion behavior |
|---|---|---|
| 0 | SOS / Medical emergency | NEVER throttled, NEVER dropped, ALWAYS relayed, ALWAYS TTL 7 |
| 1 | Organizer emergency broadcasts | Always relayed |
| 2 | Organizer announcements | High relay probability |
| 3 | Text DMs (addressed) | Efficient directed routing at scale |
| 4 | Text group messages | Relayed within member clusters |
| 5 | Friend requests/accepts | Small, one-time |
| 6 | Delivery/read receipts + location shares | Dropped first under load |
| 7 | Location channel broadcasts | Local cluster only |
| 8 | Sync/GCS reconciliation | Deferred under congestion |
| 9 | Voice notes on mesh | Gather/Event only |
| 10 | Images/files on mesh | Gather only |
| 11 | Profile picture requests | Lowest, internet-preferred |

### 8.3 Adaptive gossip

**Relay probability:**
```
P(relay) = base_probability x urgency_factor x freshness_factor x congestion_factor

base_probability:  1.0 (peers < 10), 0.7 (10-30), 0.4 (30-60), 0.2 (> 60)
urgency_factor:    3.0 (SOS), 2.0 (announcements), 1.0 (DMs), 0.5 (broadcasts)
freshness_factor:  1.0 (< 5s old), 0.5 (5-30s), 0.1 (> 30s)
congestion_factor: 1.0 (queue < 50%), 0.5 (50-80%), 0.2 (> 80%)

Capped at 1.0, floor at 0.05. SOS always 1.0 regardless.
```

**Dynamic TTL per crowd mode:**

| Type | Gather | Event | Mega | Massive |
|---|---|---|---|---|
| SOS | 7 | 7 | 7 | 7 |
| DM | 7 | 5 | 4 | 3 |
| Group | 5 | 4 | 3 | 2 |
| Broadcast | 5 | 3 | 2 | suppressed |
| Announcement | 7 | 6 | 5 | 5 |

### 8.4 Mesh topology segmentation

Devices self-organize into clusters of 20-60 peers based on RSSI proximity. Bridge nodes (connected to 2+ clusters) relay inter-cluster traffic selectively. Location broadcasts stay within their cluster.

### 8.5 Directed routing (Mega/Massive)

At large scale, DMs use directed routing instead of gossip:
- Announcement packets include neighbor peer ID lists
- Nodes build partial routing tables: "Peer X last seen via Peer Y"
- DMs route along known path (unicast over mesh)
- Fallback to gossip with reduced TTL if no path known
- Routing entries expire after 5 minutes

### 8.6 Traffic shaping

4-lane priority queue:
- Lane 0 (Critical): SOS, emergency — always first
- Lane 1 (High): DMs, friend requests — 60% of remaining bandwidth
- Lane 2 (Normal): Groups, channels — 30%
- Lane 3 (Low): Sync, profiles — 10%

Rate limiting: 20 packets/s inbound per peer, 15 packets/s outbound. Burst: 2x for 3 seconds.

Backpressure: queue > 80% stops relay traffic; queue > 95% drops Lane 3 entirely.

### 8.7 Multi-tier Bloom filter

| Tier | Window | Size | Purpose |
|---|---|---|---|
| Hot | Last 60 seconds | 4KB | Fastest check |
| Warm | Last 10 minutes | 16KB | Recent history |
| Cold | Last 2 hours | 64KB | Extended dedup |

Check order: Hot -> Warm -> Cold. Base false positive rate: ~0.1% per tier. With double-hashing mitigation (Section 5.11), effective rate: ~0.01% per tier (~0.03% aggregate).

### 8.8 Battery management

| Tier | Battery level | Scan on/off | Advertise interval | Relay |
|---|---|---|---|---|
| Performance | > 60% or charging | 5s/5s | 200ms | Full |
| Balanced | 30-60% | 4s/8s | 500ms | Full |
| Power saver | 10-30% | 3s/15s | 1000ms | Reduced |
| Ultra-low | < 10% | 2s/30s | 2000ms | Disabled |

### 8.9 SOS override rules

SOS packets at any crowd scale:
1. Skip normal Bloom filter (use separate SOS Bloom filter)
2. Skip relay probability (always relay)
3. Skip queue priority (jump to front of Lane 0)
4. Skip TTL reduction for first 3 hops
5. Relay on ALL connections simultaneously
6. Also send via internet if available (dual-path)

---

## 9. Event System

### 9.1 Event discovery

**Three modes (all coexist):**

1. **Registered:** Organizers submit event data via web form. Published to JSON manifest on CDN. App fetches daily.
2. **Auto-discovery:** 20+ mesh peers in geohash-6 area (~1.2km) without registered event -> auto-create ad-hoc location channel.
3. **Ad-hoc:** Any user creates a local channel. Visible to nearby mesh peers only.

### 9.2 Event data structure (JSON manifest)

```json
{
  "version": 12,
  "signature": "<Ed25519 signature of events array by Blip manifest signing key>",
  "events": [
    {
      "id": "uuid",
      "name": "Glastonbury 2026",
      "coordinates": { "lat": 51.0043, "lon": -2.5856 },
      "radiusMeters": 3000,
      "startDate": "2026-06-24",
      "endDate": "2026-06-28",
      "stageMapUrl": "https://cdn.blip.app/maps/glasto-2026.jpg",
      "organizerSigningKey": "<Ed25519 public key for this event's organizer>",
      "stages": [
        {
          "id": "uuid",
          "name": "Pyramid Stage",
          "coordinates": { "lat": 51.0048, "lon": -2.5862 },
          "schedule": [
            { "artist": "Bicep", "start": "2026-06-25T22:00Z", "end": "2026-06-25T23:30Z" }
          ]
        }
      ]
    }
  ]
}
```

### 9.3 Manifest and organizer authentication

**Manifest integrity:** The event JSON manifest is signed with the Blip manifest Ed25519 key. The corresponding public key is embedded in the app binary. The app verifies the signature before accepting any manifest update. A compromised CDN or DNS hijack cannot inject fake events.

**Organizer authentication:** Each registered event includes an `organizerSigningKey` in the manifest. Organizer announcement packets (0x30) MUST be signed with this key. Peers verify the signature against the manifest-provided key before displaying or relaying the announcement. Unsigned or incorrectly signed announcements are silently dropped. This prevents attackers from flooding the mesh with fake priority broadcasts.

### 9.4 Geofence behavior

- GPS check on launch + every 15 minutes while active
- Within 2km: prompt "Looks like you're at [Event]! Join?"
- One tap: Event tab appears, stage channels auto-populate
- Leave geofence: Event tab greys out, channels remain accessible but marked "Out of range"
- No persistent location tracking

### 9.5 Organizer capabilities

- Priority announcements (weather, schedule changes, safety) — signed with organizer key, verified by peers
- Stage channel configuration
- Stage map with tappable hotspots
- Schedule/lineup data
- Emergency broadcasts (high-TTL, high-priority) — signed and verified
- Aggregate stats only: approximate peer count, channel activity levels
- NO access to user messages, DMs, group chats, or individual identity

### 9.6 Event tab structure

- Stage map (interactive, with crowd pulse heatmap overlay, friend dots, meeting point pins)
- Announcements feed
- Emergency/SOS section
- Schedule with set time alerts
- Lost & Found channel
- Stage channels list

---

## 10. Medical Assistance System

### 10.1 SOS activation

**Persistent floating SOS pill** in top-right corner of every screen (subtle glass material, red accent on activation).

| Severity | Activation | Confirmation |
|---|---|---|
| Green (non-urgent) | Tap | Confirm button |
| Amber (urgent) | Tap | Slide to confirm (like iPhone power-off) |
| Red (critical) | Tap | Hold for 3 seconds with haptic escalation + countdown circle |

### 10.2 False activation safeguards

- Tiered confirmation (above) prevents accidental taps
- 10-second cancel window after send (alert silently withdrawn)
- 2+ false alarms in one event: simple drag-captcha added to amber/red
- No activation from lock screen or background
- Proximity sensor check: phone face-down/in-pocket blocks activation with "Pick up your phone to confirm"
- "Report for friend" requires typed description (3-word minimum)
- No PIN/password to send SOS — real emergencies must be fast
- No cooldown after legitimate alerts
- No account penalties for false alarms

### 10.3 GPS precision for SOS

**On Red SOS activation:**

1. Acquire precise GPS (target +-5m)
2. Broadcast SOS with fuzzy location (geohash-6) on mesh (public)
3. Send precise GPS encrypted ONLY to medical responder devices
4. Stream GPS updates every 5 seconds until resolved (dual-path: mesh + internet)

**GPS fallback chain:**
1. Precise GPS (+-5m)
2. WiFi-assisted location
3. BLE triangulation from 3+ peers with known GPS
4. Geohash-8 (+-40m)
5. Last-known location + timestamp

**Medical map accuracy indicators:**
- Solid pin = GPS lock (+-5m)
- Pulsing circle = estimated (+-40m)
- Dashed circle = last-known (stale)

### 10.4 Medical responder dashboard

Unlocked via organizer-issued rotating access code. Shows:
- Live map with SOS pins (MapKit overlay on event grounds)
- Active alerts sorted by severity then recency
- Per-alert: Accept, Navigate (walking directions), Resolve
- Response stats: resolved count, average response time

**Responder workflow:**
1. Alert appears with map pin + severity + elapsed time
2. Accept: claims alert, others see "Accepted by [callsign]"
3. Navigate: walking directions via MapKit to alert GPS pin
4. Resolve: close with status (treated, transported, false alarm)

**Live location streaming:** After Red SOS, user's GPS streams every 5 seconds to responders. Pin moves in real-time. Stops on resolution.

### 10.5 Nearby peer assistance

On Red alert: peers within 2 hops receive:
> "Someone nearby needs help. If you can see someone in distress, stay with them — medical team is on the way."

No precise location shared with general peers. Opt-out available in settings.

### 10.6 Privacy safeguards

- Users anonymous to medical responders by default
- Phone number never shared with medical team
- Precise GPS auto-deletes from responder devices after 24 hours
- Medical dashboard accessible only with organizer-issued rotating codes
- No persistent health data — alert history purged after event + 24 hours

---

## 11. Friend System & Location Sharing

### 11.1 Adding friends

- Search by username -> send friend request
- Friend request includes phone hash for mutual verification
- Both sides compute `SHA256(phone + salt)` and compare
- If hashes match: phone-verified badge shown on profile
- If no match: friend still added, but no verified badge

### 11.2 Friend finder (GPS)

**Map view** in Nearby tab showing friend locations on event map.

**Privacy controls (per-friend):**

| Setting | What friend sees |
|---|---|
| Precise | GPS dot on map, updated every 30s |
| Fuzzy (default) | Stage/area name only, no pin |
| Off | "Location hidden" |

**Location sharing protocol:**
- Priority 6 packets (low, doesn't compete with messages)
- Encrypted with Noise session (only the specific friend decrypts)
- ~48 bytes per update
- BLE mesh: every 30s (precise) or 60s (fuzzy)
- Mega/Massive modes: updates reduce to 60s/120s

**Features:**
- Proximity alert: "Jake is nearby!" when friend enters BLE range (~50m)
- "I'm here" beacon: drop labeled pin, share to friends/group, expires 30 minutes
- Navigate to friend: walking directions via pre-cached map tiles
- Breadcrumb trail (opt-in): friend's movement over last 2 hours, stored only locally, auto-deleted after 4 hours

---

## 12. Visual Design System

### 12.1 Typography

**Font family:** Plus Jakarta Sans

| Use | Weight | Size |
|---|---|---|
| Large titles | Bold | 34pt |
| Section headers | SemiBold | 22pt |
| Body / chat text | Regular | 17pt |
| Secondary / metadata | Regular | 13pt |
| Captions | Medium | 11pt |

### 12.2 Color system

**Dark theme:**

| Token | Value |
|---|---|
| background | `#000000` |
| text | `#FFFFFF` |
| muted text | `rgba(255, 255, 255, 0.5)` |
| border | `rgba(255, 255, 255, 0.08)` |
| card bg | `rgba(255, 255, 255, 0.02)` |
| hover | `rgba(255, 255, 255, 0.05)` |
| accent purple | `#6600FF` |

**Light theme:**

| Token | Value |
|---|---|
| background | `#FFFFFF` |
| text | `#000000` |
| muted text | `rgba(0, 0, 0, 0.5)` |
| border | `rgba(0, 0, 0, 0.08)` |
| card bg | `rgba(0, 0, 0, 0.02)` |
| hover | `rgba(0, 0, 0, 0.05)` |
| accent purple | `#6600FF` |

Theme follows system preference with manual override in settings.

### 12.3 Glassmorphism design language

- Primary surfaces: `.ultraThinMaterial` and `.regularMaterial` over gradient backgrounds
- Chat bubbles: translucent glass with 0.5pt white border at 20% opacity
- Cards/sheets: `.thickMaterial` with `cornerRadius(24)`
- Navigation bar: transparent with material blur
- Tab bar: custom floating glass material bar with accent glow on active tab

### 12.4 Animation system

**Page entrance:** Staggered reveal of elements — fade + translate, 0.3-0.6s, spring animation (`stiffness: 300, damping: 24`), 50ms stagger between cells.

**Chat animations:**
- Messages slide in with spring physics (yours from right, theirs from left)
- Typing indicator: 3 glass dots with sequential scale pulse (0.4s, 0.15s offset)
- Send button: morphs mic -> arrow with shape interpolation on text input
- Delivery checkmarks: fade-in with scale spring

**PTT animations:**
- Hold-to-talk: expanding concentric sonar rings
- Waveform: real-time audio amplitude bezier path
- Release: rings collapse, voice note bubble springs in

**Avatars:**
- Gradient ring border (friend = accent, nearby = green pulse)
- Scale + fade spring on first mesh discovery

**Transitions:**
- Matched geometry: chat list -> chat view
- Cross-fade tab content with matched geometry for shared elements
- Pull-to-refresh: spring with glass blur intensity change

**Micro-interactions:**
- Long-press message: context menu with haptic feedback
- Swipe to reply: rubber-band physics
- Unread badges: `.contentTransition(.numericText())`
- Connection banner: glass capsule slides down, auto-dismisses 3s

---

## 13. User Experience

### 13.1 Onboarding (3 screens)

1. **Welcome:** "Chat at events, even without signal" + animated gradient hero
2. **Create profile:** Username, phone (SMS OTP), optional avatar. Single screen.
3. **Permissions:** "Blip needs Bluetooth to connect with people nearby." One tap.

No mention of mesh, nodes, protocols, encryption, or transport. Ever.

### 13.2 Navigation (4 tabs)

| Tab | Content |
|---|---|
| Chats | DMs + group chats, sorted by recent, unread badges |
| Nearby | Location channels, nearby friends, mesh peer indicator ("X people nearby"), friend finder map |
| Event | Stage map + heatmap + friend dots + meeting pins, announcements, schedule, lost & found, stage channels (appears only when at/joined a event) |
| Profile | Username, avatar, friends list, message pack balance, settings, SOS history |

### 13.3 Invisible complexity

All technical details hidden from user:

| User sees | Reality |
|---|---|
| Green dot on friend | BLE peer discovered |
| "Nearby" badge | Geohash location channel auto-joined |
| Message sends | BLE mesh -> WiFi -> cellular (automatic) |
| Checkmarks | Encrypted ACK over mesh gossip |
| PTT button | Audio streaming via BLE |
| "No connection" banner | No peers, no internet — queued |
| Event in Discover | GPS matched organizer manifest |
| "3 friends nearby" | BLE discovery matched friend keys |
| "Huge crowd - text mode" | Massive mode activated by peer density |

### 13.4 Paywall UX

- Soft prompt: glass sheet slides up from bottom after free messages used
- Message stays composed in text field (never lost)
- One-tap StoreKit 2 purchase
- Balance shown subtly in Profile tab only
- Low balance nudge: "2 messages left" pill above text field, tappable

### 13.5 Accessibility

- Full VoiceOver support on all interactive elements
- Dynamic Type: all text scales with system font size preference
- Reduced Motion: respect `UIAccessibility.isReduceMotionEnabled` — disable all spring animations, staggered reveals, particle effects; use simple fades
- Minimum 44pt tap targets on all interactive elements
- High contrast mode: increase border opacity, reduce material transparency
- SOS button: extra-large tap target (minimum 60pt), VoiceOver priority

### 13.6 Message editing and deletion

- **Edit:** Sender can edit a message within 5 minutes of sending. Sends `messageEdit` encrypted sub-type (0x0B) with original message ID + new content. Recipient sees "edited" label. Original content not retained on recipient device.
- **Delete:** Sender can request deletion at any time. Sends `messageDelete` encrypted sub-type (0x0A) with message ID. Recipient device removes the message and shows "Message deleted" placeholder. Relay nodes cannot delete cached copies (encrypted, will expire naturally).
- **Delete for me:** User can locally delete any received message without notifying the sender.

### 13.7 Content moderation & App Store compliance

- Report button on every message (long-press -> Report)
- Report button on every profile (Profile sheet -> Report)
- Block user: immediately stops all message delivery from that user; blocked user's packets are silently dropped at the BLE level
- Reported content forwarded (with user consent) to a minimal abuse reporting endpoint for App Store compliance
- Apple App Store Review Guidelines 1.1, 1.2: abuse reporting and action mechanism present

**Mesh-level reputation (decentralized moderation):**
- When a user is blocked, the blocker's device gossips a lightweight `blockVote` (hashed user ID, no content) to direct peers
- Peers tally block votes via a local counter per user ID
- If a user accumulates block votes from 10+ distinct peers within a cluster: relay nodes in that cluster deprioritize (but do not drop) that user's non-SOS packets
- At 25+ block votes: relay nodes drop that user's broadcast/channel packets (DMs still relayed to preserve 1-on-1 communication)
- Block votes reset per event (no permanent reputation score)
- SOS packets are NEVER affected by block votes — safety overrides moderation

**Privacy nutrition labels:** Accurate App Store privacy disclosure. Data collected: phone number (verification only), approximate location (when in use), usage data (message counts for billing). Data NOT collected: message content, contacts, browsing history, precise location (except during SOS).

### 13.8 Offline message queue limits

- Maximum retry attempts per queued message: 50
- Maximum queue age: 24 hours (messages older than 24h are marked as failed and the user is notified)
- Maximum queue size: 500 messages (oldest failed messages evicted first if queue is full)
- User sees: "Message couldn't be delivered" with option to retry or delete

---

## 14. Data Model

### 14.1 SwiftData models

**User**
```
id: UUID
username: String (unique)
displayName: String?
phoneHash: String (SHA256)
noisePublicKey: Data (32 bytes)
signingPublicKey: Data (32 bytes)
avatarThumbnail: Data? (64x64 JPEG)
avatarFullRes: Data? (LRU evicted)
bio: String? (140 chars)
createdAt: Date
```

**Friend**
```
id: UUID
user: User
status: enum (pending, accepted, blocked)
phoneVerified: Bool
locationSharingEnabled: Bool
locationPrecision: enum (precise, fuzzy, off)
lastSeenLocation: GeoPoint?
lastSeenAt: Date?
nickname: String? (user-set override)
lastMessage: Message?
addedAt: Date
```

**Message**
```
id: UUID (deterministic: sender + timestamp + content hash)
sender: User
channel: Channel
type: enum (text, voiceNote, image, pttAudio)
encryptedPayload: Data
status: enum (composing, queued, sent, delivered, read)
replyTo: Message?
attachments: [Attachment]
fragmentID: UUID?
fragmentIndex: Int?
fragmentTotal: Int?
isRelayed: Bool
hopCount: Int
createdAt: Date
expiresAt: Date?
```

**Attachment**
```
id: UUID
message: Message
type: enum (image, voiceNote, pttRecording, profilePhoto)
thumbnail: Data?
fullData: Data? (LRU evicted)
sizeBytes: Int
mimeType: String
duration: TimeInterval? (audio only)
```

**Channel**
```
id: UUID
type: enum (dm, group, locationChannel, stageChannel, lostAndFound, emergency)
name: String?
memberships: [GroupMembership]
event: Event?
geohash: String?
pinnedMessages: [Message]
muteStatus: enum (unmuted, mutedTimed, mutedForever)
maxRetention: TimeInterval
isAutoJoined: Bool
createdAt: Date
lastActivityAt: Date
```

**GroupMembership**
```
id: UUID
user: User
channel: Channel
role: enum (member, admin, creator)
nickname: String?
muted: Bool
mutedUntil: Date?
joinedAt: Date
```

**Event**
```
id: UUID
name: String
coordinates: GeoPoint
radiusMeters: Double
startDate: Date
endDate: Date
stageMapImage: Data?
organizerSigningKey: Data (32 bytes, Ed25519 public key for verifying announcements offline)
stages: [Stage]
channels: [Channel]
manifestVersion: Int
```

**Stage**
```
id: UUID
name: String
event: Event
coordinates: GeoPoint
channel: Channel
schedule: [SetTime]
```

**SetTime**
```
id: UUID
artistName: String
stage: Stage
startTime: Date
endTime: Date
savedByUser: Bool
reminderSet: Bool
```

**MessagePack**
```
id: UUID
packType: enum (starter10, social25, event50, squad100, season1000, unlimited)
messagesRemaining: Int
purchaseDate: Date
transactionID: String
```

**MeetingPoint**
```
id: UUID
creator: User
channel: Channel
coordinates: GeoPoint
label: String
expiresAt: Date
```

**MeshPeer**
```
id: UUID
peerID: Data (8 bytes)
noisePublicKey: Data
signingPublicKey: Data
username: String?
rssi: Int
connectionState: enum (discovered, connecting, connected, disconnected)
lastSeenAt: Date
hopCount: Int
isRelaying: Bool
batteryTier: enum (performance, balanced, powerSaver, ultraLow)
```

**SOSAlert**
```
id: UUID
reporter: User
reportedFor: Friend?
severity: enum (green, amber, red)
preciseLocation: GeoPoint
fuzzyLocation: String (geohash-6)
message: String? (user-provided context, e.g. "Friend collapsed")
description: String? (required for "report for friend", 3-word minimum)
status: enum (active, accepted, enRoute, resolved)
acceptedBy: MedicalResponder?
acceptedAt: Date?
resolvedAt: Date?
resolution: enum (treatedOnSite, transported, falseAlarm, cancelled)?
falseAlarmCount: Int (per event, for throttling)
createdAt: Date
expiresAt: Date
```

**MedicalResponder**
```
id: UUID
user: User
event: Event
accessCodeHash: String
callsign: String
isOnDuty: Bool
activeAlert: SOSAlert?
responseCount: Int
avgResponseTime: TimeInterval
```

**FriendLocation**
```
id: UUID
friend: Friend
precisionLevel: enum (precise, fuzzy, off)
latitude: Double?
longitude: Double?
geohash: String?
areaName: String?
accuracy: Double
timestamp: Date
breadcrumbs: [BreadcrumbPoint]?
```

**BreadcrumbPoint**
```
latitude: Double
longitude: Double
timestamp: Date
```

**MessageQueue**
```
id: UUID
message: Message
attempts: Int (max 50)
maxAttempts: Int (default 50)
nextRetryAt: Date
expiresAt: Date (createdAt + 24 hours)
transport: enum (ble, wifi, cellular, any)
status: enum (queued, sending, failed, expired)
```

**CrowdPulse (transient)**
```
geohash: String
peerCount: Int
lastUpdated: Date
heatLevel: enum (quiet, moderate, busy, packed)
```

**NoiseSession (hybrid: metadata in Keychain, cipher states in memory)**
```
peerID: Data
handshakeComplete: Bool
peerStaticKeyKnown: Bool (enables IK pattern upgrade on reconnect, persisted to Keychain)
peerStaticKey: Data? (32 bytes, persisted to Keychain for IK upgrade)
establishedAt: Date (persisted to Keychain)
expiresAt: Date (establishedAt + 4 hours, persisted to Keychain)
messageCounter: UInt64 (memory-only, lost on termination)
rekeyAt: UInt64 (memory-only)
sendCipher: CipherState (memory-only, transient)
receiveCipher: CipherState (memory-only, transient)
```

NOTE: On app termination/restoration, cipher states are lost. If `peerStaticKeyKnown == true` and session not expired, a fast IK handshake (2 messages) re-establishes ciphers. If unknown or expired, full XX handshake (3 messages). This gives the benefit of session resumption without persisting cipher material to disk.

**GroupSenderKey**
```
id: UUID
channel: Channel (relationship)
memberPeerID: Data (8 bytes, the member who generated this key)
keyMaterial: Data (32 bytes, AES-256-GCM key — stored in Keychain)
messageCounter: UInt64 (nonce management, monotonically increasing)
rotationEpoch: Int (incremented on each key rotation)
createdAt: Date
```

NOTE: AES-256-GCM chosen over ChaChaPoly for sender keys because Apple's Secure Enclave and A-series chips provide hardware-accelerated AES, giving better performance for high-throughput group messages. ChaChaPoly remains the choice for Noise sessions where its constant-time software implementation benefits the handshake phase.

**UserPreferences**
```
id: UUID
theme: enum (system, light, dark)
defaultLocationSharing: enum (precise, fuzzy, off)
proximityAlertsEnabled: Bool
breadcrumbsEnabled: Bool
notificationsEnabled: Bool
pttMode: enum (holdToTalk, toggleTalk)
autoJoinNearbyChannels: Bool
crowdPulseVisible: Bool
friendFinderMapStyle: enum (satellite, standard, hybrid)
lastEventID: UUID?
```

### 14.2 Indexed fields

```
Message.createdAt                  -- chat scroll
Message.channel + createdAt        -- channel message loading
Message.status                     -- outbox queue
Channel.lastActivityAt             -- chat list sort
MeshPeer.lastSeenAt                -- stale peer cleanup
MeshPeer.connectionState           -- active peer count
Friend.status                      -- friend list filtering
MessageQueue.nextRetryAt           -- retry scheduling
SOSAlert.status + severity         -- medical dashboard
```

### 14.3 Storage budget

| Data | Size per unit | Retention |
|---|---|---|
| Text message | ~200 bytes | Forever |
| Voice note | ~15KB/s (Opus) | Forever |
| Image thumbnail | ~3KB | Forever |
| Image full-res | ~200KB | LRU, 500MB cache |
| Profile thumbnail | ~3KB | Forever |
| Mesh peer record | ~256 bytes | 24hr after last seen |
| Bloom filter (3-tier) | ~84KB total | Rolling |

App target: < 100MB base. Auto-evict media cache beyond 1GB with user prompt.

---

## 15. Project Structure

```
Blip/
|-- Blip.xcodeproj
|-- project.yml                          # XcodeGen spec
|
|-- App/
|   |-- BlipApp.swift               # @main entry
|   |-- AppDelegate.swift                # BLE state restoration
|   |-- Info.plist
|   |-- Assets.xcassets/
|   |   |-- AppIcon
|   |   |-- Colors/                      # Design tokens as named colors
|   |   |   |-- AccentPurple             # #6600FF
|   |   |   |-- Background
|   |   |   |-- CardBG
|   |   |   |-- MutedText
|   |   |   +-- Border
|   |   +-- Images/
|   +-- Entitlements/
|       +-- Blip.entitlements       # BLE, push, Keychain, IAP
|
|-- Sources/
|   |-- Views/
|   |   |-- Launch/
|   |   |   |-- SplashView.swift
|   |   |   +-- OnboardingFlow.swift
|   |   |-- Tabs/
|   |   |   |-- MainTabView.swift
|   |   |   |-- ChatsTab/
|   |   |   |   |-- ChatListView.swift
|   |   |   |   |-- ChatListCell.swift
|   |   |   |   |-- ChatView.swift
|   |   |   |   |-- MessageBubble.swift
|   |   |   |   |-- MessageInput.swift
|   |   |   |   |-- VoiceNotePlayer.swift
|   |   |   |   +-- ImageViewer.swift
|   |   |   |-- NearbyTab/
|   |   |   |   |-- NearbyView.swift
|   |   |   |   |-- NearbyPeerCard.swift
|   |   |   |   |-- LocationChannelList.swift
|   |   |   |   |-- FriendFinderMap.swift
|   |   |   |   +-- MeshParticleView.swift
|   |   |   |-- EventsTab/
|   |   |   |   |-- EventView.swift
|   |   |   |   |-- StageMapView.swift
|   |   |   |   |-- CrowdPulseOverlay.swift
|   |   |   |   |-- MeetingPointSheet.swift
|   |   |   |   |-- ScheduleView.swift
|   |   |   |   |-- SetTimeCell.swift
|   |   |   |   |-- AnnouncementFeed.swift
|   |   |   |   |-- LostAndFoundView.swift
|   |   |   |   +-- MedicalDashboard/
|   |   |   |       |-- MedicalDashboardView.swift
|   |   |   |       |-- AlertCard.swift
|   |   |   |       |-- ResponderMapView.swift
|   |   |   |       +-- AlertDetailSheet.swift
|   |   |   +-- ProfileTab/
|   |   |       |-- ProfileView.swift
|   |   |       |-- EditProfileView.swift
|   |   |       |-- AvatarCropView.swift
|   |   |       |-- FriendsListView.swift
|   |   |       |-- MessagePackStore.swift
|   |   |       +-- SettingsView.swift
|   |   |-- Shared/
|   |   |   |-- GlassCard.swift
|   |   |   |-- GradientBackground.swift
|   |   |   |-- SOSButton.swift
|   |   |   |-- SOSConfirmationSheet.swift
|   |   |   |-- ProfileSheet.swift
|   |   |   |-- AvatarView.swift
|   |   |   |-- StatusBadge.swift
|   |   |   |-- TypingIndicator.swift
|   |   |   |-- ConnectionBanner.swift
|   |   |   +-- PaywallSheet.swift
|   |   +-- Animations/
|   |       |-- StaggeredReveal.swift
|   |       |-- ScrollReveal.swift
|   |       |-- SpringConstants.swift
|   |       |-- RippleEffect.swift
|   |       |-- WaveformView.swift
|   |       +-- MorphingIcon.swift
|   |-- ViewModels/
|   |   |-- ChatViewModel.swift
|   |   |-- MeshViewModel.swift
|   |   |-- EventViewModel.swift
|   |   |-- ProfileViewModel.swift
|   |   |-- SOSViewModel.swift
|   |   |-- StoreViewModel.swift
|   |   |-- LocationViewModel.swift
|   |   +-- PTTViewModel.swift
|   |-- Models/
|   |   |-- (all SwiftData models from section 14)
|   +-- Services/
|       |-- MessageService.swift
|       |-- MessageRetryService.swift
|       |-- LocationService.swift
|       |-- NotificationService.swift
|       |-- AudioService.swift
|       |-- ImageService.swift
|       +-- PhoneVerificationService.swift
|
|-- Packages/
|   |-- BlipProtocol/
|   |   |-- Package.swift
|   |   +-- Sources/
|   |       |-- Packet.swift
|   |       |-- MessageType.swift
|   |       |-- PacketFlags.swift
|   |       |-- PacketSerializer.swift
|   |       |-- PacketValidator.swift
|   |       |-- FragmentAssembler.swift
|   |       |-- FragmentSplitter.swift
|   |       |-- BloomFilter.swift
|   |       |-- GCSFilter.swift
|   |       |-- TLVEncoder.swift
|   |       |-- Compression.swift
|   |       +-- Padding.swift
|   |-- BlipMesh/
|   |   |-- Package.swift
|   |   +-- Sources/
|   |       |-- Transport.swift
|   |       |-- BLEService.swift
|   |       |-- BLEConstants.swift
|   |       |-- PeerManager.swift
|   |       |-- GossipRouter.swift
|   |       |-- StoreForwardCache.swift
|   |       |-- AdaptiveRelay.swift
|   |       |-- PowerManager.swift
|   |       |-- CrowdScaleManager.swift
|   |       |-- ClusterManager.swift
|   |       |-- DirectedRouter.swift
|   |       |-- TrafficShaper.swift
|   |       |-- ReputationManager.swift        # Block vote tallying + relay deprioritization
|   |       |-- WiFiTransport.swift
|   |       |-- WebSocketTransport.swift
|   |       +-- TransportCoordinator.swift
|   +-- BlipCrypto/
|       |-- Package.swift
|       +-- Sources/
|           |-- KeyManager.swift
|           |-- NoiseHandshake.swift
|           |-- NoiseCipherState.swift
|           |-- NoiseSessionManager.swift   # Includes session caching + IK upgrade
|           |-- SenderKeyManager.swift      # Group sender key lifecycle + rotation
|           |-- Signer.swift
|           |-- PhoneHasher.swift
|           +-- ReplayProtection.swift
|
|-- Tests/
|   |-- ProtocolTests/
|   |-- MeshTests/
|   |-- CryptoTests/
|   +-- ViewModelTests/
|
|-- Resources/
|   |-- Fonts/
|   |   |-- PlusJakartaSans-Regular.ttf
|   |   |-- PlusJakartaSans-Medium.ttf
|   |   |-- PlusJakartaSans-SemiBold.ttf
|   |   +-- PlusJakartaSans-Bold.ttf
|   +-- Localization/
|       +-- en.lproj/Localizable.strings
|
+-- docs/
    |-- PROTOCOL.md
    +-- WHITEPAPER.md
```

### 15.1 Dependencies (3 total)

| Package | Purpose |
|---|---|
| CryptoKit (Apple, built-in) | Curve25519, ChaChaPoly, SHA256 |
| swift-sodium (libsodium wrapper) | Ed25519 signing |
| swift-opus (Opus codec wrapper) | Voice note + PTT audio encoding |

No UI dependencies. All SwiftUI native.

### 15.2 Capabilities (Entitlements)

- Background Modes: bluetooth-central, bluetooth-peripheral, audio
- Keychain Sharing
- In-App Purchase
- Push Notifications
- Location: When In Use

---

## 16. Simulation & Testing Targets

| Scenario | Delivery target | Latency target |
|---|---|---|
| 50 peers, normal | 100% | < 2s |
| 200 peers, moderate | > 95% | < 5s |
| 500 peers, heavy + voice | > 90% | < 8s |
| 1,000+ peers, stress | > 85% | < 15s |
| SOS at any scale | 100% to responders | < 5s |
| Network partition + rejoin | Sync within 30s | - |
| 100,000 peers, Massive mode | > 80% text delivery | < 20s |

---

## 17. Cross-Platform Compatibility Contract

The binary protocol specification (Section 6) is the single source of truth for all platforms. Any implementation (Swift, Kotlin, or future) that correctly produces and consumes the defined byte formats is compatible.

**Guaranteed identical across platforms:**
- Packet header layout and byte order
- BLE service and characteristic UUIDs
- Message type enum values
- Noise protocol parameters
- Ed25519 signing algorithm and exclusion rules
- Fragmentation format
- Bloom filter and GCS parameters
- Padding block sizes

**Platform-specific (not shared):**
- UI implementation
- Local persistence format
- Background execution strategy
- Battery management specifics

---

## 18. Future Considerations (Not in v1)

- Android app (same protocol, Kotlin implementation)
- Ticket integration
- In-app payments between users
- Music integration (Spotify/Apple Music)
- Gamification/badges
- Multi-language localization (beyond English)
- Widget / Live Activity for active event
- Apple Watch companion (mesh relay + SOS)
- Event organizer web dashboard (React)
