# Blip: Decentralized Mesh Communication for Festivals and Large Gatherings

**Version:** 1.0
**Date:** March 2026

---

## Abstract

Blip is a mobile communication application that enables text messaging, voice notes, push-to-talk audio, location sharing, and emergency coordination at festivals and large gatherings -- environments where cellular infrastructure is routinely overwhelmed or entirely absent. By forming a self-organizing Bluetooth Low Energy (BLE) mesh network from attendees' smartphones, Blip creates a decentralized, zero-infrastructure communication fabric that scales from a campfire of 50 people to a major festival of 100,000 or more. All messages are end-to-end encrypted using the Noise Protocol Framework, relay nodes cannot read the content they forward, and the system operates with no accounts, no servers, and no persistent data collection. A lightweight medical emergency system enables festival-goers to summon help with precise GPS delivery to on-site medical teams, potentially saving lives when seconds matter.

---

## 1. Problem: Festival Connectivity

### 1.1 The Connectivity Gap

Music festivals, sporting events, protests, camping gatherings, and community celebrations share a common infrastructure failure: when tens of thousands of people congregate in a confined area, cellular networks collapse. Base station capacity is designed for the residential population density of an area, not for temporary concentrations of 10,000 to 200,000 people within a few square kilometers.

The result is predictable and universal:
- Text messages queue for minutes or never deliver.
- Voice calls fail to connect.
- Data services slow to unusable throughput.
- Maps, ride-sharing, and coordination apps become unreliable.
- Groups of friends lose contact with each other for hours.

### 1.2 The Coordination Problem

Beyond social messaging, the connectivity gap creates a safety problem. Large gatherings need:
- A way for groups to find each other in chaotic, noisy, poorly-lit environments.
- A reliable channel for medical emergencies -- heat stroke, dehydration, allergic reactions, injuries.
- Organizer-to-attendee communication for weather warnings, schedule changes, and safety alerts.

Existing solutions -- walkie-talkies, event apps dependent on WiFi, SMS-based group chats -- all fail under the same infrastructure constraints or require specialized hardware.

### 1.3 Design Constraints

A viable solution must satisfy hard constraints:
- **No infrastructure dependency:** The system must work with zero internet connectivity.
- **No specialized hardware:** It must run on ordinary smartphones already in attendees' pockets.
- **No accounts or sign-up friction:** Adoption at a festival happens in the moment or not at all.
- **Privacy by default:** In a post-Snowden era, users will not adopt communication tools that create surveillance opportunities.
- **Scalability across four orders of magnitude:** The same protocol must function for 50 people and 100,000 people, with graceful degradation rather than catastrophic failure.

---

## 2. Solution: BLE Mesh Communication

Blip turns every user's smartphone into a node in a self-forming BLE mesh network. Messages hop between phones, reaching recipients who may be hundreds of meters away through a chain of intermediate relays. No central server, no cellular connection, and no internet access is required for the core messaging experience.

### 2.1 Core Principles

- **Every phone is a router.** By installing the app, each user contributes relay capacity to the collective network.
- **Encryption is non-negotiable.** End-to-end encryption using the Noise Protocol Framework means relay nodes transport opaque ciphertext. Even if every intermediate phone were compromised, message content remains confidential.
- **The protocol is the product.** A rigorously specified binary protocol is the cross-platform contract. iOS and Android implementations are independent but fully interoperable at the byte level.
- **Complexity is hidden.** Users see a familiar chat interface. Mesh routing, handshakes, fragmentation, Bloom filters, and congestion control are entirely invisible.

### 2.2 Transport Stack

Blip uses a three-tier transport strategy with automatic failover:

1. **BLE Mesh (primary):** Always attempted first. Zero infrastructure required.
2. **WebSocket Relay (secondary):** When BLE cannot reach the recipient and internet is available, a zero-knowledge relay server forwards encrypted packets.
3. **Local Queue (tertiary):** When neither transport is available, messages are queued locally and delivered when connectivity returns.

---

## 3. Architecture: Four-Layer Protocol Stack

The Blip architecture is organized into four layers, each implemented as an independent Swift package (with equivalent Kotlin modules planned for Android).

### Layer 1: Transport (`BlipMesh`)

The transport layer manages all physical communication channels:
- **BLE dual-role operation:** Every device simultaneously acts as a BLE Central (scanner) and Peripheral (advertiser). This bidirectional capability is essential for mesh formation.
- **Peer discovery and connection management:** Devices discover each other via the Blip BLE service UUID, establish connections, and exchange announcement packets containing public keys and capabilities.
- **Gossip routing:** Packets propagate through the mesh via a gossip protocol with probabilistic relay, Bloom filter deduplication, and TTL-based hop limiting.
- **Store-and-forward caching:** Packets for unreachable peers are cached with content-type-specific durations (2 hours for DMs, 30 minutes for groups, 5 minutes for channels).
- **WebSocket fallback:** An encrypted relay channel over standard internet when BLE cannot reach the destination.

### Layer 2: Protocol (`BlipProtocol`)

The protocol layer defines the binary wire format:
- **16-byte fixed header** with version, type, TTL, timestamp, flags, and payload length.
- **24 message types** spanning core messaging, encryption, data transfer, festival operations, medical emergencies, and location sharing.
- **Fragmentation and reassembly** for payloads exceeding the 416-byte BLE MTU limit.
- **Zlib compression** with size-aware policies (skip for small payloads, conditional for medium, mandatory for large).
- **PKCS#7-style padding** to block boundaries (256, 512, 1024, 2048 bytes) for traffic analysis resistance.

### Layer 3: Cryptography (`BlipCrypto`)

The cryptography layer provides:
- **Noise XX handshake** for mutual authentication and key agreement using Curve25519.
- **ChaChaPoly (ChaCha20-Poly1305) AEAD** for symmetric encryption with forward secrecy.
- **Ed25519 signing** for packet authenticity on public broadcasts.
- **Session caching** for 4 hours, with IK pattern upgrade for peers with known static keys (reducing the handshake from 3 messages to 2).
- **Automatic re-keying** every 1,000 messages or 1 hour.
- **Replay protection** via sliding-window nonce tracking.

### Layer 4: Application

The application layer implements the user-facing experience:
- **SwiftUI views** with MVVM architecture.
- **SwiftData persistence** for messages, channels, peers, and user profiles.
- **Message service** coordinating send/receive flows across transport and crypto layers.
- **Festival integration** with geofenced auto-discovery, organizer announcements, and stage scheduling.

---

## 4. Mesh Networking

### 4.1 Gossip Routing

Blip uses epidemic (gossip) routing as its primary message propagation strategy. The algorithm is simple and robust:

1. A node receives a packet from a peer.
2. It hashes the packet's identifying fields and checks a multi-tier Bloom filter.
3. If the packet has been seen before, it is silently discarded (deduplication).
4. If new, the packet is inserted into the Bloom filter, the TTL is decremented, and the packet is relayed to all connected peers except the source.
5. Relay probability is modulated by crowd density, packet urgency, freshness, and outbound queue congestion.

This approach tolerates network partitions, node mobility, and unpredictable topologies. Messages find paths through the mesh organically.

### 4.2 Clustering

As crowd density increases, the mesh self-organizes into clusters of 20 to 60 peers based on BLE signal proximity (RSSI). Bridge nodes -- devices connected to two or more clusters -- relay inter-cluster traffic selectively. Location channel broadcasts are confined to their originating cluster, reducing unnecessary traffic propagation.

### 4.3 Directed Routing at Scale

At Mega (5,000-25,000 peers) and Massive (25,000-100,000+) crowd densities, gossip routing becomes inefficient for addressed messages. Blip switches to directed routing for DMs:

- Announcement packets include neighbor peer ID lists.
- Nodes build partial routing tables: "Peer X was last seen via Peer Y."
- DMs are forwarded along known paths (unicast over mesh) instead of flooded via gossip.
- Routing entries expire after 5 minutes to accommodate crowd mobility.
- Gossip with reduced TTL serves as the fallback when no directed path is known.

### 4.4 Bloom Filter Deduplication

A multi-tier Bloom filter prevents packet loops and redundant processing:

| Tier | Time Window | Size  | False Positive Rate |
|------|-------------|-------|---------------------|
| Hot  | 60 seconds  | 4 KB  | ~0.01%              |
| Warm | 10 minutes  | 16 KB | ~0.01%              |
| Cold | 2 hours     | 64 KB | ~0.01%              |

Double-hashing (two independent SHA-256-derived hash functions) reduces the effective false positive rate to approximately 0.03% aggregate. The separate SOS Bloom filter with 10x lower density achieves less than 0.001% false positives for emergency traffic.

### 4.5 Adaptive Congestion Control

The gossip relay probability adapts in real time:

```
P(relay) = base * urgency * freshness * congestion
```

Each factor responds to different network conditions, and their product is clamped between 0.05 (floor) and 1.0 (ceiling). Emergency traffic always relays at probability 1.0 regardless of conditions.

A four-lane priority queue ensures critical traffic is never starved:
- Lane 0 (Critical): SOS and emergencies -- always processed first.
- Lane 1 (High): DMs and friend requests -- 60% of remaining bandwidth.
- Lane 2 (Normal): Groups and channels -- 30%.
- Lane 3 (Low): Sync, profiles, file transfers -- 10%.

---

## 5. Security

### 5.1 Noise XX Handshake

Blip uses `Noise_XX_25519_ChaChaPoly_SHA256` for all private communication channels. The XX pattern provides mutual authentication without pre-shared keys -- both parties learn and verify each other's long-term static keys during the handshake itself.

The three-message exchange:
1. Initiator sends ephemeral public key.
2. Responder sends ephemeral public key, performs DH operations (ee, es), and sends encrypted static key.
3. Initiator sends encrypted static key, performs DH (se).

The result is bidirectional transport ciphers with forward secrecy: compromising a party's long-term key after the handshake does not reveal past session traffic.

### 5.2 End-to-End Encryption

Every private message (DMs, group chats, friend operations, location shares) is encrypted inside the Noise transport channel. The encrypted payload (packet type `0x11`) is opaque to all relay nodes. Only the intended recipient, who shares the Noise session, can decrypt the content.

Group messages use a Sender Key scheme: each group member generates a symmetric AES-256-GCM key, distributes it to other members via their pairwise Noise sessions, and encrypts group messages once with their sender key. This produces O(1) ciphertext per group message regardless of group size.

### 5.3 Privacy Protections

- **No accounts:** Identity is a locally-generated Curve25519 keypair. No email, no password, no server-side identity.
- **Phone number privacy:** Phone numbers are stored as salted SHA-256 hashes. The raw number is stored only in the iOS Keychain. Phone hashes are shared only during friend request/accept flows, inside encrypted channels. Phone numbers are never transmitted in plaintext.
- **Traffic analysis resistance:** All packets are padded to block boundaries (256, 512, 1024, 2048 bytes). An observer cannot determine message length from packet size.
- **No metadata collection:** The relay server (WebSocket fallback) is a zero-knowledge forwarder. It stores nothing, logs nothing, and cannot decrypt traffic.
- **Key rotation:** Automatic re-keying every 1,000 messages or 1 hour provides forward secrecy within sessions.

---

## 6. Festival Integration

### 6.1 Festival Discovery

Blip supports three modes of festival awareness:

1. **Registered festivals:** Organizers submit festival data via a web form. A signed JSON manifest is published to a CDN and fetched daily by the app. The manifest is signed with a Blip Ed25519 key embedded in the app binary, preventing CDN compromise from injecting fake festivals.

2. **Auto-discovery:** When 20 or more mesh peers are detected within a geohash-6 area (~1.2 km) without a registered festival, the app auto-creates an ad-hoc location channel.

3. **Ad-hoc channels:** Any user can create a local channel visible to nearby mesh peers.

### 6.2 Organizer Tools

Festival organizers receive a signing keypair published in the manifest. Their capabilities include:
- Priority announcements (weather, schedule changes, safety alerts) that are cryptographically signed and verified by all peers before display or relay.
- Stage channel configuration and scheduling data.
- Interactive stage maps with crowd density heatmap overlays.
- Aggregate statistics only (approximate peer count, channel activity). Organizers have no access to user messages, DMs, group chats, or individual identity.

### 6.3 Location Channels

Proximity-based public channels that users auto-join when entering a geographic area. Messages are signed for authenticity but not encrypted (they are public). Channel broadcasts are confined to the local cluster to minimize mesh traffic.

---

## 7. Medical Safety: The SOS System

### 7.1 Design Philosophy

At a festival with 50,000 attendees and limited cellular connectivity, a medical emergency -- heat stroke, severe dehydration, allergic anaphylaxis, a fall -- can become fatal if the victim cannot summon help. Blip's SOS system is designed to deliver medical assistance requests reliably, even when the cellular network is completely unavailable.

### 7.2 Activation Flow

A persistent SOS button is visible on every screen of the app. Activation uses a tiered confirmation model to balance urgency against false alarms:

| Severity | Confirmation Required                                    |
|----------|----------------------------------------------------------|
| Green    | Single tap to confirm.                                   |
| Amber    | Slide to confirm (similar to iPhone power-off).          |
| Red      | Hold for 3 seconds with haptic escalation and countdown. |

### 7.3 Delivery Guarantees

SOS packets receive the highest possible priority in the mesh:
- They bypass the normal Bloom filter and use a dedicated SOS filter with ultra-low false positive rates.
- They always relay at probability 1.0 regardless of congestion.
- They skip TTL reduction for the first 3 hops, extending their reach.
- They are sent simultaneously via BLE mesh and internet (if available).
- They jump to the front of the critical outbound queue.

### 7.4 GPS Precision

On Red SOS activation:
1. The app acquires precise GPS (target accuracy 5 meters).
2. A fuzzy location (geohash-6, ~1.2 km precision) is broadcast publicly on the mesh.
3. Precise GPS coordinates are encrypted and sent only to registered medical responder devices.
4. GPS updates stream every 5 seconds until the alert is resolved.

A fallback chain (WiFi location, BLE triangulation, geohash-8, last-known location) ensures that some location data is always available even if GPS is degraded.

### 7.5 Medical Responder Dashboard

On-site medical teams access a dedicated dashboard (unlocked via organizer-issued rotating access codes) that displays:
- A live map with SOS pins colored by severity.
- Active alerts sorted by severity then recency.
- Accept/Navigate/Resolve workflow per alert.
- Response statistics (resolved count, average response time).

### 7.6 False Alarm Safeguards

- Tiered confirmation prevents accidental activation.
- A 10-second cancel window allows immediate withdrawal after send.
- After 2 or more false alarms at one festival, additional confirmation friction is added.
- No activation from lock screen or background.
- Proximity sensor check blocks activation when the phone is face-down or in a pocket.

### 7.7 Privacy

- Users are anonymous to medical responders by default.
- Phone numbers are never shared with the medical team.
- Precise GPS auto-deletes from responder devices after 24 hours.
- Alert history is purged after the festival plus 24 hours.

---

## 8. Scalability

Blip adapts its operating profile dynamically based on crowd density, measured by counting unique peers seen in the last 5 minutes.

### 8.1 Crowd-Scale Modes

| Mode     | Peer Estimate   | Media on Mesh                   | Key Adaptations                     |
|----------|-----------------|----------------------------------|--------------------------------------|
| Gather   | < 500           | Text, voice, images, PTT         | Full features, relaxed relay         |
| Festival | 500-5,000       | Text + compressed voice (8kbps)  | Moderate throttle, reduced TTL       |
| Mega     | 5,000-25,000    | Text only                        | Directed routing for DMs, tight relay|
| Massive  | 25,000-100,000+ | Text only, all media internet-only| Aggressive clustering, minimal gossip|

### 8.2 Graceful Degradation

Rather than failing catastrophically, Blip progressively sheds features as crowd density increases:
- Voice notes move from mesh to internet-only.
- Images move from mesh to internet-only.
- Broadcast TTLs decrease.
- Gossip relay probability decreases.
- DMs switch from gossip to directed unicast routing.
- Location broadcasts are confined to local clusters.

At every scale, text DMs and SOS alerts remain fully functional on the mesh.

### 8.3 Battery Management

Mesh participation is adjusted based on battery level:

| Battery Level | Scan Duty Cycle | Relay Behavior |
|---------------|-----------------|----------------|
| > 60%         | 5s on / 5s off  | Full relay     |
| 30-60%        | 4s on / 8s off  | Full relay     |
| 10-30%        | 3s on / 15s off | Reduced relay  |
| < 10%         | 2s on / 30s off | Relay disabled |

---

## 9. Monetization

Blip uses a message-based monetization model with a free tier:

| Tier          | Messages | Price   |
|---------------|----------|---------|
| Free          | 10       | $0.00   |
| Starter       | 10       | $0.99   |
| Social        | 25       | $1.99   |
| Festival      | 50       | $3.99   |
| Squad         | 100      | $5.99   |
| Season Pass   | 1,000    | $29.99  |
| Unlimited     | Subscription | TBD |

**What counts as a message:** One text, one voice note, one image, or one PTT session equals one message. Location broadcasts, friend operations, delivery/read receipts, and receiving messages are always free. Organizer announcements are always free.

This model aligns monetization with value delivered: users pay for the messages they send, not for access to infrastructure. The free tier ensures that receiving messages and emergency features are universally available.

---

## 10. Future Work

### 10.1 WiFi Direct Transport (v2)

WiFi Direct offers approximately 125x the bandwidth of BLE (250 Mbps vs 2 Mbps) and 4x the range (200m vs 50m). Integration as a secondary transport layer would dramatically improve media delivery in Gather and Festival modes. The primary challenge on iOS is that WiFi Direct requires explicit user pairing and cannot operate in background discovery mode.

### 10.2 Android Implementation

The binary protocol specification serves as the cross-platform contract. An Android (Kotlin) implementation using the same packet format, cryptographic primitives, and routing algorithms will achieve full interoperability with iOS clients at the byte level. Android's more permissive background BLE policies may enable even more reliable mesh participation.

### 10.3 Mesh Analytics for Organizers

Aggregate, privacy-preserving mesh telemetry could provide festival organizers with crowd flow heatmaps, stage popularity metrics, and real-time density alerts -- all derived from mesh topology data without accessing any message content or individual identity.

### 10.4 Offline Maps and Navigation

Pre-cached vector map tiles for festival grounds would enable peer-to-peer walking directions, meeting point navigation, and stage-to-stage routing without any internet dependency.

### 10.5 Multi-Hop Voice Streaming

Real-time voice streaming over multi-hop BLE mesh is technically feasible but challenging due to latency accumulation. Research into low-latency codec configurations (Opus at 8 kbps with 20ms frames) and priority-lane routing may enable reliable PTT over 2-3 hops in Gather mode.

### 10.6 Interoperability with Emergency Services

Integration with national emergency dispatch systems (e.g., 911/112 relay) would allow SOS alerts to reach professional emergency services when festival medical teams are overwhelmed. This requires regulatory coordination and is a longer-term goal.

---

## Conclusion

Blip demonstrates that reliable, secure, and scalable communication at large gatherings does not require cellular infrastructure. By leveraging the BLE radios already present in every smartphone, applying rigorous cryptographic protocols, and adapting dynamically to crowd density, Blip transforms a connectivity problem into a cooperative solution where every attendee's device strengthens the network for everyone.

The system's four-layer architecture -- transport, protocol, cryptography, and application -- provides clean separation of concerns and a binary protocol specification that serves as a language-agnostic contract for cross-platform implementation. The medical SOS system addresses a genuine safety need with reliability guarantees that exceed what degraded cellular networks can offer.

Blip is not a replacement for cellular infrastructure. It is a complement that fills the gap where infrastructure fails, using the devices people already carry and the proximity they already share.
